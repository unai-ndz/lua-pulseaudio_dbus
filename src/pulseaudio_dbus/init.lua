--[[
  Copyright 2017 Stefano Mazzucco

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
]]

--[[--
  Control audio devices using the
  [pulseaudio DBus interface](https://www.freedesktop.org/wiki/Software/PulseAudio/Documentation/Developer/Clients/DBus/).

  For this to work, you need the line
  `load-module module-dbus-protocol`
  in `/etc/pulse/default.pa`
  or `~/.config/pulse/default.pa`

  @module pulseaudio_dbus

  @usage
  pulse = require("pulseaudio_dbus")
  address = pulse.get_address()
  connection = pulse.get_connection(address)
  core = pulse.get_core(connection)
  sink = pulse.get_device(connection, core:get_sinks()[1])
  sink:set_muted(true)
  sink:toggle_muted()
  assert(not sink:is_muted())
  sink:set_volume_percent({75}) -- sets the volume to 75%

  @license Apache License, version 2.0
  @author Stefano Mazzucco <stefano AT curso DOT re>
  @copyright 2017 Stefano Mazzucco
]]

local proxy = require("dbus_proxy")
local lgi =  require("lgi")
local DBusConnectionFlags = lgi.Gio.DBusConnectionFlags


local function _update_table(from_t, to_t)
  for k, v in pairs(from_t) do
    assert(to_t[k] == nil, "Cannot override attribute " .. k)
    to_t[k] = v
  end
end


local pulse = {}

local function get_volume_percent(self)
  local volume = self:get_volume()

  local base = self.BaseVolume
  if not base then -- This is a stream
    base = pulse.get_device(self.connection, self.Device).BaseVolume
  end

  local volume_percent = {}
  for i, v in ipairs(volume) do
    volume_percent[i] = math.ceil(v / base * 100)
  end

  return volume_percent
end

local function set_volume_percent(self, value)
  local base = self.BaseVolume
  if not base then -- This is a stream
    base = pulse.get_device(self.connection, self.Device).BaseVolume
  end

  local volume = {}
  for i, v in ipairs(value) do
    volume[i] = v * base / 100
  end
  self:set_volume(volume)
end

local function volume_up(self, step, max)
  local volume_step = step or self.volume_step
  local volume_max = max or self.volume_max
  local volume = get_volume_percent(self)
  local up
  for i, v in ipairs(volume) do
    up = v + volume_step
    if up > volume_max then
      volume[i] = volume_max
    elseif up > 100 and volume[i] < 100 and volume_max > 100 then
      volume[i] = 100
    else
      volume[i] = up
    end
  end
  set_volume_percent(self, volume)
end

local function volume_down(self, step)
  local volume_step = step or self.volume_step
  local volume = get_volume_percent(self)
  local down
  for i, v in ipairs(volume) do
    down = v - volume_step
    if down < 100 and volume[i] > 100 then
      volume[i] = 100
    elseif down >= 0 then
      volume[i] = down
    else
      volume[i] = 0
    end
  end
  set_volume_percent(self, volume)
end

local function toggle_muted(self)
  local muted = self:is_muted()
  self:set_muted(not muted)
  return self:is_muted()
end

local server_props = {
  bus=proxy.Bus.SESSION,
  name="org.PulseAudio1",
  path="/org/pulseaudio/server_lookup1",
  interface="org.PulseAudio.ServerLookup1"
}

--- Get the pulseaudio DBus address
-- @return a string representing the pulseaudio
-- [DBus address](https://dbus.freedesktop.org/doc/dbus-tutorial.html#addresses).
function pulse.get_address()
  local server = proxy.Proxy:new(server_props)
  return server.Address
end

--- Get a [monitored Proxy](https://stefano-m.github.io/lua-dbus_proxy/#monitored.new)
-- for the pulseaudio DBus server
-- @tparam[opt] function callback passed to the monitored proxy
-- @return monitored proxy object
-- @usage
-- function init(address)
--   connection = pulse.get_connection(address)
--   core = pulse.get_core(connection)
-- end
--
-- proxy = pulse.get_monitored_proxy(function(proxy, appeared)
--   if appeared then
--     init(proxy.Address)
--   end
-- end)
function pulse.get_monitored_proxy(callback)
  return proxy.monitored.new(server_props, callback)
end

--- Get a connection to the pulseaudio server
-- @tparam string address DBus address
-- @tparam[opt] boolean dont_assert whether we should *not* assert that the
-- connection is closed.
-- @return an `lgi.Gio.DBusConnection` to the pulseaudio server
-- @see pulse.get_address
function pulse.get_connection(address, dont_assert)

  local bus = lgi.Gio.DBusConnection.new_for_address_sync(
                     address,
                     DBusConnectionFlags.AUTHENTICATION_CLIENT)

  if not dont_assert then
    assert(not bus.closed,
           string.format("Bus from '%s' is closed!", address))
  end

  return bus
end

--- Pulseaudio
-- [core server functionality](https://www.freedesktop.org/wiki/Software/PulseAudio/Documentation/Developer/Clients/DBus/Core/)
-- @type Core
pulse.Core = {}

--- Get all currently available sinks.
-- Note the the `Sinks` property may not be up-to-date.
-- @return array of all available object path sinks
function pulse.Core:get_sinks()
  return self:Get("org.PulseAudio.Core1", "Sinks")
end

--- Get all currently available cards.
-- Note the the `Cards` property may not be up-to-date.
-- @return array of all available object path cards
function pulse.Core:get_cards()
    return self:Get("org.PulseAudio.Core1", "Cards")
end

--- Get all currently available sources.
-- Note the the `Sources` property may not be up-to-date.
-- @return array of all available object path sources
function pulse.Core:get_sources()
    return self:Get("org.PulseAudio.Core1", "Sources")
end

--- Get all currently available playback streams.
-- Note that the `PlaybackStreams` property may not be up-to-date.
-- @return array of all available object path playback streams
function pulse.Core:get_playback_streams()
  return self:Get("org.PulseAudio.Core1", "PlaybackStreams")
end

--- Get all currently available record streams.
-- Note that the `RecordStreams` property may not be up-to-date.
-- @return array of all available object path record streams
function pulse.Core:get_record_streams()
  return self:Get("org.PulseAudio.Core1", "RecordStreams")
end

--- Get the current fallback sink object path
-- @return fallback sink object path (may not be up-to-date)
-- @return nil if no falback sink is set
-- @see pulse.Core:set_fallback_sink
function pulse.Core:get_fallback_sink()
  return self:Get("org.PulseAudio.Core1", "FallbackSink")
end

--- Set the current fallback sink object path
-- @tparam string value fallback sink object path
-- @see pulse.Core:get_fallback_sink
function pulse.Core:set_fallback_sink(value)
  self:Set("org.PulseAudio.Core1",
           "FallbackSink",
           lgi.GLib.Variant("o", value))
  self.FallbackSink = {signature="o", value=value}
end

--- Get the current fallback source object path
-- @return fallback source object path
-- @return nil if no fallback source is set
-- @see pulse.Core:set_fallback_source
function pulse.Core:get_fallback_source()
  return self:Get("org.PulseAudio.Core1", "FallbackSource")
end

--- Set the current fallback source object path
-- @tparam string value fallback source object path
-- @see pulse.Core:get_fallback_source
function pulse.Core:set_fallback_source(value)
  self:Set("org.PulseAudio.Core1",
           "FallbackSource",
           lgi.GLib.Variant("o", value))
  self.FallbackSource = {signature="o", value=value}
end

--- Get the pulseaudio [core object](https://www.freedesktop.org/wiki/Software/PulseAudio/Documentation/Developer/Clients/DBus/Core/)
-- @tparam lgi.Gio.DBusConnection connection DBus connection to the
-- pulseaudio server
-- @return the pulseaudio core object that allows you to access the
-- various sound devices
function pulse.get_core(connection)
  local core = proxy.Proxy:new(
    {
      bus=connection,
      name=nil, -- nil, because bus is *not* a message bus.
      path="/org/pulseaudio/core1",
      interface="org.PulseAudio.Core1"
    }
  )

  _update_table(pulse.Core, core)

  return core
end

--- Pulseaudio
-- [Stream](https://www.freedesktop.org/wiki/Software/PulseAudio/Documentation/Developer/Clients/DBus/Stream/)
-- Use @{pulse.get_stream} to obtain a stream object.
-- @type Stream
pulse.Stream = {}

--- Get the volume of the stream.
-- You could also use the `Stream.Volume` field, but it's not guaranteed
-- to be in sync with the actual changes.
-- @return the volume of the stream as an array of numbers
-- (one number) per channel
-- @see pulse.Stream:get_volume_percent
-- @see pulse.Device:get_volume
function pulse.Stream:get_volume()
  return self:Get("org.PulseAudio.Core1.Stream", "Volume")
end

--- Get the volume of the stream as a percentage.
-- @return the volume of the stream as an array of numbers
-- (one number) per channel
-- @see pulse.Stream:get_volume
-- @see pulse.Device:get_volume_percent
function pulse.Stream:get_volume_percent()
  return get_volume_percent(self)
end

--- Set the volume of the stream on each channel.
-- You could also use the `Stream.Volume` field, but it's not guaranteed
-- to be in sync with the actual changes.
-- @tparam table value an array with the value of the volume.
-- If the array contains only one element, its value will be set
-- for all channels.
-- @see pulse.Stream:set_volume_percent
-- @see pulse.Device:set_volume
function pulse.Stream:set_volume(value)
  self:Set("org.PulseAudio.Core1.Stream",
           "Volume",
           lgi.GLib.Variant("au", value))
  self.Volume = {signature="au", value=value}
end

--- Set the volume of the stream as a percentage on each channel.
-- @tparam table value an array with the value of the volume.
-- If the array contains only one element, its value will be set
-- for all channels.
-- @see pulse.Stream:set_volume
-- @see pulse.Device:set_volume_percent
function pulse.Stream:set_volume_percent(value)
  return set_volume_percent(self, value)
end

--- Step up the volume (percentage) by an amount equal to `volume_step`.
-- @tparam[opt] number volume_step The volume step in % (defaults to `self.volume_step`)
-- @tparam[opt] number volume_max The maximum volume in % (defaults to `self.volume_max`)
-- Calling this function will never set the volume above `volume_max`
-- @see pulse.Stream:volume_down
-- @see pulse.Device:volume_up
function pulse.Stream:volume_up(volume_step, volume_max)
  return volume_up(self, volume_step, volume_max)
end

--- Step down the volume (percentage) by an amount equal to `volume_step`.
-- @tparam[opt] number volume_step The volume step in % (defaults to `self.volume_step`)
-- Calling this function will never set the volume below zero (which is,
-- by the way, an error).
-- @see pulse.Stream:volume_up
-- @see pulse.Device:volume_down
function pulse.Stream:volume_down(volume_step)
  return volume_down(self, volume_step)
end

--- Get whether the stream is muted.
-- @return a boolean value that indicates whether the stream is muted.
-- @see pulse.Stream:toggle_muted
-- @see pulse.Stream:set_muted
-- @see pulse.Device:is_muted
function pulse.Stream:is_muted()
  return self:Get("org.PulseAudio.Core1.Stream", "Mute")
end

--- Set the muted state of the stream.
-- @tparam boolean value whether the stream should be muted
-- You could also use the `Stream.Mute` field, but it's not guaranteed
-- to be in sync with the actual changes.
-- @see pulse.Stream:is_muted
-- @see pulse.Stream:toggle_muted
-- @see pulse.Device:set_muted
function pulse.Stream:set_muted(value)
  self:Set("org.PulseAudio.Core1.Stream",
           "Mute",
           lgi.GLib.Variant("b", value))
  self.Mute = {signature="b", value=value}
end

--- Toggle the muted state of the stream.
-- @return a boolean value that indicates whether the stream is muted.
-- @see pulse.Stream:set_muted
-- @see pulse.Stream:is_muted
-- @see pulse.Device:toggle_muted
function pulse.Stream:toggle_muted()
  return toggle_muted(self)
end

--- Get the pulseaudio [Stream](https://www.freedesktop.org/wiki/Software/PulseAudio/Documentation/Developer/Clients/DBus/Stream/)
-- @tparam lgi.Gio.DBusConnection connection DBus connection to the
-- pulseaudio server
-- @tparam string streampath The stream object path as a string
-- @tparam[opt] number volume_step The volume step in % (defaults to 5)
-- @tparam[opt] number volume_max The maximum volume in % (defaults to 150)
-- @return A new Stream object
function pulse.get_stream(connection, streampath, volume_step, volume_max)
  local stream = proxy.Proxy:new(
    {
      bus=connection,
      name=nil, -- nil, because bus is *not* a message bus.
      path=streampath,
      interface="org.PulseAudio.Core1.Stream"
    }
  )

  stream.volume_step = volume_step or 5
  stream.volume_max = volume_max or 150

  _update_table(pulse.Stream, stream)

  return stream
end

--- Pulseaudio
-- [Device](https://www.freedesktop.org/wiki/Software/PulseAudio/Documentation/Developer/Clients/DBus/Device/). <br>
-- Use @{pulse.get_device} to obtain a device object.
-- @type Device
pulse.Device = {}

-- https://www.freedesktop.org/wiki/Software/PulseAudio/Documentation/Developer/Clients/DBus/Enumerations/
local device_states = {
  "running",  -- the device is being used by at least one non-corked stream.
  "idle",     -- the device is active, but no non-corked streams are connected to it.
  "suspended" -- the device is not in use and may be currently closed.
}

--- Get the current state of the device. This can be one of:
--
-- - "running": the device is being used by at least one non-corked stream.
-- - "idle": the device is active, but no non-corked streams are connected to it.
-- - "suspended": the device is not in use and may be currently closed.
-- @return the device state as a string
function pulse.Device:get_state()
  local current_state =  self:Get("org.PulseAudio.Core1.Device",
                                  "State")
  return device_states[current_state + 1]
end

--- Get the volume of the device.
-- You could also use the `Device.Volume` field, but it's not guaranteed
-- to be in sync with the actual changes.
-- @return the volume of the device as an array of numbers
-- (one number) per channel
-- @see pulse.Device:get_volume_percent
-- @see pulse.Stream:get_volume
function pulse.Device:get_volume()
  return self:Get("org.PulseAudio.Core1.Device",
                  "Volume")
end

--- Get the volume of the device as a percentage.
-- @return the volume of the device as an array of numbers
-- (one number) per channel
-- @see pulse.Device:get_volume
-- @see pulse.Stream:get_volume_percent
function pulse.Device:get_volume_percent()
  return get_volume_percent(self)
end

--- Set the volume of the device on each channel.
-- You could also use the `Device.Volume` field, but it's not guaranteed
-- to be in sync with the actual changes.
-- @tparam table value an array with the value of the volume.
-- If the array contains only one element, its value will be set
-- for all channels.
-- @see pulse.Device:set_volume_percent
-- @see pulse.Stream:set_volume
function pulse.Device:set_volume(value)
  self:Set("org.PulseAudio.Core1.Device",
           "Volume",
           lgi.GLib.Variant("au", value))
  self.Volume = {signature="au", value=value}
end

--- Set the volume of the device as a percentage on each channel.
-- @tparam table value an array with the value of the volume.
-- If the array contains only one element, its value will be set
-- for all channels.
-- @see pulse.Device:set_volume
-- @see pulse.Stream:set_volume_percent
function pulse.Device:set_volume_percent(value)
  return set_volume_percent(self, value)
end

--- Step up the volume (percentage) by an amount equal to `volume_step`.
-- @tparam[opt] number volume_step The volume step in % (defaults to `self.volume_step`)
-- @tparam[opt] number volume_max The maximum volume in % (defaults to `self.volume_max`)
-- Calling this function will never set the volume above `volume_max`
-- @see pulse.Device:volume_down
-- @see pulse.Stream:volume_up
function pulse.Device:volume_up(volume_step, volume_max)
  return volume_up(self, volume_step, volume_max)
end

--- Step down the volume (percentage) by an amount equal to `volume_step`.
-- @tparam[opt] number volume_step The volume step in % (defaults to `self.volume_step`)
-- Calling this function will never set the volume below zero (which is,
-- by the way, an error).
-- @see pulse.Device:volume_up
-- @see pulse.Stream:volume_down
function pulse.Device:volume_down(volume_step)
  return volume_down(self, volume_step)
end

--- Get whether the device is muted.
-- @return a boolean value that indicates whether the device is muted.
-- @see pulse.Device:toggle_muted
-- @see pulse.Device:set_muted
-- @see pulse.Stream:is_muted
function pulse.Device:is_muted()
  return self:Get("org.PulseAudio.Core1.Device",
                  "Mute")
end

--- Set the muted state of the device.
-- @tparam boolean value whether the device should be muted
-- You could also use the `Device.Mute` field, but it's not guaranteed
-- to be in sync with the actual changes.
-- @see pulse.Device:is_muted
-- @see pulse.Device:toggle_muted
-- @see pulse.Stream:set_muted
function pulse.Device:set_muted(value)
  self:Set("org.PulseAudio.Core1.Device",
           "Mute",
           lgi.GLib.Variant("b", value))
  self.Mute = {signature="b", value=value}
end

--- Toggle the muted state of the device.
-- @return a boolean value that indicates whether the device is muted.
-- @see pulse.Device:set_muted
-- @see pulse.Device:is_muted
-- @see pulse.Stream:toggle_muted
function pulse.Device:toggle_muted()
  return toggle_muted(self)
end

--- Get the current active port object path
-- @return the active port object path
-- @return nil if no active port is set
-- @see pulse.Device:set_active_port
function pulse.Device:get_active_port()
  return self:Get("org.PulseAudio.Device", "ActivePort")
end

--- Set the active port object path
-- @tparam string value port object path
-- @see pulse.Device:get_active_port
function pulse.Device:set_active_port(value)
  self:Set("org.PulseAudio.Core1.Device",
           "ActivePort",
           lgi.GLib.Variant("o", value))
  self.ActivePort = {signature="o", value=value}
end

--- Get an DBus proxy object to a pulseaudio
-- [Device](https://www.freedesktop.org/wiki/Software/PulseAudio/Documentation/Developer/Clients/DBus/Device/). <br>
-- Setting a property will be reflected on the pulseaudio device.
-- Trying to set other properties will result in an error.
-- @tparam lgi.Gio.DBusConnection connection The connection to pulseaudio
-- @tparam string path The device object path as a string
-- @tparam[opt] number volume_step The volume step in % (defaults to 5)
-- @tparam[opt] number volume_max The maximum volume in % (defaults to 150)
-- @return A new Device object
-- @see pulse.get_connection
-- @see pulse.get_core
-- @usage
-- -- get a pulseaudio sink (e.g. audio output)
-- sink = pulse.get_device(connection, core:get_sinks()[1])
-- -- get a pulseaudio source (e.g. microphone)
-- source = pulse.get_device(connection, core:get_sources([1]))
function pulse.get_device(connection, path, volume_step, volume_max)
  local device = proxy.Proxy:new(
    {
      bus=connection,
      name=nil,
      path=path,
      interface="org.PulseAudio.Core1.Device"
    }
  )

  device.volume_step = volume_step or 5
  device.volume_max = volume_max or 150

  _update_table(pulse.Device, device)

  return device
end

--- Pulseaudio
-- [DevicePort](https://www.freedesktop.org/wiki/Software/PulseAudio/Documentation/Developer/Clients/DBus/DevicePort/). <br>
-- Use @{pulse.get_port} to obtain a port object.
-- @type Port
pulse.Port = {}

--- Get the pulseaudio [DevicePort](https://www.freedesktop.org/wiki/Software/PulseAudio/Documentation/Developer/Clients/DBus/DevicePort/)
-- @tparam lgi.Gio.DBusConnection connection DBus connection to the
-- pulseaudio server
-- @tparam string path The port object path as a string
-- @return A new DevicePort object
function pulse.get_port(connection, path)
    local port = proxy.Proxy:new(
    {
        bus=connection,
        name=nil,
        path=path,
        interface="org.PulseAudio.Core1.DevicePort"
    }
    )

    _update_table(pulse.Port, port)

    return port
end

return pulse
