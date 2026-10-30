-- UniFi Protect Local: SmartThings Edge driver
-- Uses the official UniFi Protect Integration API with a local API key.
-- Controller (LAN device) holds the settings; cameras are EDGE_CHILD devices.

local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local cosock = require "cosock"
local socket = require "cosock.socket"
local json = require "st.json"
local log = require "log"

local api = require "unifi_api"
local config_server = require "config_server"
local ok_cfg, local_config = pcall(require, "local_config")
if not ok_cfg or type(local_config) ~= "table" then local_config = {} end
local lustre = require "lustre"
local CloseCode = require "lustre.frame.close".CloseCode

local WebSocket = lustre.WebSocket
local LustreConfig = lustre.Config
local Message = lustre.Message

local SMART_COMPONENTS = { person = "person", vehicle = "vehicle", animal = "animal" }
-- which capability each component carries
local COMPONENT_KIND = {
  main = "motion", person = "motion", vehicle = "motion", animal = "motion",
  sound = "sound", smoke = "smoke", co = "co",
}
local RESYNC_INTERVAL = 600 -- seconds between camera list refreshes
local WS_KEEPALIVE = 60     -- seconds between websocket pings

-- Per-controller runtime state, keyed by controller device id
local states = {}

local function get_state(ctrl)
  local s = states[ctrl.id]
  if not s then
    s = { gen = 0, ws = nil, events = {}, active = {}, shown = {}, tokens = {}, cameras = {} }
    states[ctrl.id] = s
  end
  return s
end

local function is_child(device)
  return device.parent_assigned_child_key ~= nil
end

local function clean_host(h)
  return (tostring(h or ""):gsub("%s", ""):gsub("^https?://", ""):gsub("/.*$", ""):gsub(":%d+$", ""))
end

local function clean_key(k)
  k = tostring(k or ""):gsub("%s", "")
  if k == "none" then k = "" end
  return k
end

local function prefs(ctrl)
  local p = ctrl.preferences or {}
  -- 1. app settings, 2. hub settings page, 3. local_config.lua (always as a pair)
  local host, key = clean_host(p.host), clean_key(p.apiKey)
  if key == "" then
    local fkey = clean_key(ctrl:get_field("cfg_key"))
    if fkey ~= "" then
      host, key = clean_host(ctrl:get_field("cfg_host")), fkey
    elseif clean_key(local_config.api_key) ~= "" then
      key = clean_key(local_config.api_key)
      if clean_host(local_config.host) ~= "" then host = clean_host(local_config.host) end
    end
  end
  return {
    host = host,
    key = key,
    timeout = tonumber(p.eventTimeout) or 60,
    hold = tonumber(p.motionHold) or 0,
    video = p.enableVideo == true,
    quality = p.videoQuality or "medium",
    secure = p.videoSecure == true,
  }
end

local function find_child(driver, ctrl, camera_id)
  for _, d in ipairs(driver:get_devices()) do
    if d.parent_device_id == ctrl.id and d.parent_assigned_child_key == camera_id then
      return d
    end
  end
end

local function looks_like_doorbell(cam)
  local name = string.lower(tostring(cam.name or ""))
  if name:find("doorbell", 1, true) or name:find("deurbel", 1, true) then return true end
  if cam.hasPackageCamera == true then return true end
  -- doorbells carry an lcdMessage object; other cameras send null
  local lcd = cam.lcdMessage
  if type(lcd) == "table" and lcd ~= json.null then
    local mt = getmetatable(lcd)
    if not (mt and mt.__tojson) then return true end
  end
  return false
end

-- Profiles of v1 (unifi-*) are kept unchanged for existing devices: the hub
-- refuses a driver update that changes a profile in use. New profiles use the
-- upl- prefix and existing devices are migrated to them.
local function wanted_profile(is_doorbell, audio, video)
  return (is_doorbell and "upl-doorbell" or "upl-camera")
    .. (audio and "-audio" or "") .. (video and "-video" or "")
end

local function has_audio_detection(cam)
  local ff = type(cam.featureFlags) == "table" and cam.featureFlags or {}
  local t = ff.smartDetectAudioTypes
  return type(t) == "table" and t ~= json.null and #t > 0
end

local function excluded_list(ctrl)
  local ex = ctrl:get_field("excluded")
  if type(ex) ~= "table" then ex = {} end
  return ex
end

local emit_led -- defined below
local function emit_stream(child)
  local url = child:get_field("stream_url")
  if url and child:supports_capability_by_id("videoStream") then
    local ok, err = pcall(function()
      child:emit_event(capabilities.videoStream.stream({ InHomeURL = url, OutHomeURL = url }))
    end)
    if not ok then log.warn("[unifi] could not emit stream: " .. tostring(err)) end
  end
end

---------------------------------------------------------------------------
-- Detection state handling
---------------------------------------------------------------------------

local function state_event(kind, active)
  if kind == "sound" then
    return active and capabilities.soundSensor.sound.detected() or capabilities.soundSensor.sound.not_detected()
  elseif kind == "smoke" then
    return active and capabilities.smokeDetector.smoke.detected() or capabilities.smokeDetector.smoke.clear()
  elseif kind == "co" then
    return active and capabilities.carbonMonoxideDetector.carbonMonoxide.detected()
      or capabilities.carbonMonoxideDetector.carbonMonoxide.clear()
  end
  return active and capabilities.motionSensor.motion.active() or capabilities.motionSensor.motion.inactive()
end

local function emit_state(child, comp, active)
  local component = child.profile.components[comp]
  if not component then return end
  child:emit_component_event(component, state_event(COMPONENT_KIND[comp] or "motion", active))
end

local function key2(t, a, b)
  t[a] = t[a] or {}
  return t[a]
end

local function show(driver, ctrl, cam_id, comp, active)
  local s = get_state(ctrl)
  local shown = key2(s.shown, cam_id)
  if shown[comp] == active then return end
  shown[comp] = active
  local child = find_child(driver, ctrl, cam_id)
  if child then emit_state(child, comp, active) end
end

local function deactivate(driver, ctrl, cam_id, comp, ev_id)
  local s = get_state(ctrl)
  local per_cam = s.active[cam_id]
  if not per_cam or not per_cam[comp] or not per_cam[comp][ev_id] then return end
  per_cam[comp][ev_id] = nil
  if next(per_cam[comp]) ~= nil then return end
  local hold = prefs(ctrl).hold
  if hold > 0 and COMPONENT_KIND[comp] == "motion" then
    -- occupancy hold: stay active a while unless a new detection arrives
    local tokens = key2(s.tokens, cam_id)
    local tok = tokens[comp] or 0
    driver:call_with_delay(hold, function()
      local still_empty = not s.active[cam_id] or next(s.active[cam_id][comp] or {}) == nil
      if (key2(s.tokens, cam_id)[comp] or 0) == tok and still_empty then
        show(driver, ctrl, cam_id, comp, false)
      end
    end, "unifi hold")
  else
    show(driver, ctrl, cam_id, comp, false)
  end
end

local function activate(driver, ctrl, cam_id, comp, ev_id)
  local s = get_state(ctrl)
  s.active[cam_id] = s.active[cam_id] or {}
  local per_cam = s.active[cam_id]
  per_cam[comp] = per_cam[comp] or {}
  if per_cam[comp][ev_id] then return end
  per_cam[comp][ev_id] = true
  local tokens = key2(s.tokens, cam_id)
  tokens[comp] = (tokens[comp] or 0) + 1
  show(driver, ctrl, cam_id, comp, true)
  -- safety reset in case the end of the event never arrives
  local timeout = prefs(ctrl).timeout
  driver:call_with_delay(timeout, function()
    deactivate(driver, ctrl, cam_id, comp, ev_id)
  end, "unifi detection timeout")
end

local function components_for(ev)
  local comps = {}
  if ev.type == "motion" then
    table.insert(comps, "main")
  elseif ev.type == "smartDetectZone" or ev.type == "smartDetectLine" then
    for t in pairs(ev.smart) do
      if SMART_COMPONENTS[t] then table.insert(comps, SMART_COMPONENTS[t]) end
    end
  elseif ev.type == "smartAudioDetect" then
    table.insert(comps, "sound")
    if ev.smart.alrmSmoke or ev.smart.smoke_cmonx then table.insert(comps, "smoke") end
    if ev.smart.alrmCmonx or ev.smart.smoke_cmonx then table.insert(comps, "co") end
  end
  return comps
end

local function handle_ring(driver, ctrl, cam_id)
  local child = find_child(driver, ctrl, cam_id)
  if not child then
    log.warn("[unifi] ring for unknown camera " .. tostring(cam_id))
    return
  end
  log.info("[unifi] doorbell ring: " .. child.label)
  if child:supports_capability_by_id("button") then
    child:emit_event(capabilities.button.button.pushed({ state_change = true }))
  else
    -- camera turned out to be a doorbell: switch profile, then deliver the push
    child:set_field("is_doorbell", true, { persist = true })
    child:try_update_metadata({ profile = wanted_profile(true, child:get_field("has_audio") == true, prefs(ctrl).video) })
    driver:call_with_delay(3, function()
      local c = find_child(driver, ctrl, cam_id)
      if c and c:supports_capability_by_id("button") then
        c:emit_event(capabilities.button.button.pushed({ state_change = true }))
      end
    end, "unifi delayed ring")
  end
end

local function handle_event_message(driver, ctrl, data)
  local item = data.item
  if type(item) ~= "table" or item.modelKey ~= "event" or not item.id then return end
  local s = get_state(ctrl)
  local action = data.type
  local ev = s.events[item.id]

  if action == "add" then
    ev = { type = item.type, device = item.device, smart = {}, ts = os.time() }
    if type(item.smartDetectTypes) == "table" then
      for _, t in ipairs(item.smartDetectTypes) do ev.smart[t] = true end
    end
    s.events[item.id] = ev
    log.debug(string.format("[unifi] event add %s on %s", tostring(ev.type), tostring(ev.device)))

    if ev.type == "ring" then
      handle_ring(driver, ctrl, ev.device)
      return
    end
    for _, comp in ipairs(components_for(ev)) do
      activate(driver, ctrl, ev.device, comp, item.id)
    end
    if item["end"] ~= nil and type(item["end"]) == "number" then
      -- already finished: keep it active briefly so routines can see it
      local id = item.id
      driver:call_with_delay(5, function()
        for _, comp in ipairs(components_for(ev)) do deactivate(driver, ctrl, ev.device, comp, id) end
      end, "unifi short event")
    end

  elseif action == "update" then
    if not ev then return end
    if type(item.smartDetectTypes) == "table" then
      for _, t in ipairs(item.smartDetectTypes) do ev.smart[t] = true end
      -- newly added types (e.g. vehicle joins person): activate their components
      if item["end"] == nil or type(item["end"]) ~= "number" then
        for _, comp in ipairs(components_for(ev)) do
          activate(driver, ctrl, ev.device, comp, item.id)
        end
      end
    end
    if item["end"] ~= nil and type(item["end"]) == "number" then
      for _, comp in ipairs(components_for(ev)) do
        deactivate(driver, ctrl, ev.device, comp, item.id)
      end
    end

  elseif action == "remove" then
    if ev then
      for _, comp in ipairs(components_for(ev)) do
        deactivate(driver, ctrl, ev.device, comp, item.id)
      end
      s.events[item.id] = nil
    end
  end
end

local function prune_events(ctrl)
  local s = get_state(ctrl)
  local cutoff = os.time() - 3600
  for id, ev in pairs(s.events) do
    if ev.ts < cutoff then s.events[id] = nil end
  end
end

---------------------------------------------------------------------------
-- Camera sync
---------------------------------------------------------------------------

emit_led = function(child)
  local led = child:get_field("led_on")
  local component = child.profile.components["led"]
  if type(led) == "boolean" and component then
    child:emit_component_event(component, led and capabilities.switch.switch.on() or capabilities.switch.switch.off())
  end
end

local function sync_cameras(driver, ctrl)
  local p = prefs(ctrl)
  local s = get_state(ctrl)
  s.last_sync = os.time()
  local cams, err = api.get_cameras(p.host, p.key)
  if not cams then
    log.warn("[unifi] could not get cameras: " .. tostring(err))
    return false
  end
  for _, cam in ipairs(cams) do
    if type(cam) == "table" and cam.id then
      s.cameras[cam.id] = cam
      local child = find_child(driver, ctrl, cam.id)
      s.pending = s.pending or {}
      local audio = has_audio_detection(cam)
      if not child and excluded_list(ctrl)[cam.id] then
        log.debug("[unifi] skipping removed camera " .. tostring(cam.name))
      elseif not child and (s.pending[cam.id] or 0) > os.time() - 60 then
        log.debug("[unifi] creation pending for " .. tostring(cam.name))
      elseif not child then
        s.pending[cam.id] = os.time()
        local doorbell = looks_like_doorbell(cam)
        log.info(string.format("[unifi] creating device for %s (doorbell=%s)", tostring(cam.name), tostring(doorbell)))
        driver:try_create_device({
          type = "EDGE_CHILD",
          label = cam.name or ("UniFi camera " .. cam.id),
          profile = wanted_profile(doorbell, audio, p.video),
          manufacturer = "Ubiquiti",
          model = "UniFi Protect camera",
          vendor_provided_label = cam.name or "UniFi camera",
          parent_device_id = ctrl.id,
          parent_assigned_child_key = cam.id,
        })
      else
        local doorbell = child:get_field("is_doorbell")
        if doorbell == nil then
          doorbell = looks_like_doorbell(cam)
          child:set_field("is_doorbell", doorbell, { persist = true })
        end
        child:set_field("has_audio", audio, { persist = true })
        local has_button = child:supports_capability_by_id("button")
        local has_video = child:supports_capability_by_id("videoStream")
        local has_sound = child:supports_capability_by_id("soundSensor")
        local has_led = child:supports_capability_by_id("switch")
        if has_button ~= doorbell or has_video ~= p.video or has_sound ~= audio or not has_led then
          log.info("[unifi] updating profile of " .. child.label)
          child:try_update_metadata({ profile = wanted_profile(doorbell, audio, p.video) })
        end
        if cam.state == "CONNECTED" then child:online() else child:offline() end

        -- status LED
        local led = type(cam.ledSettings) == "table" and cam.ledSettings.isEnabled
        if type(led) == "boolean" and child:get_field("led_on") ~= led then
          child:set_field("led_on", led, { persist = true })
          emit_led(child)
        end

        if p.video then
          local url, serr = api.get_stream_url(p.host, p.key, cam.id, p.quality)
          if url then
            url = api.stream_url_variant(url, p.secure, p.host)
            child:set_field("stream_url", url, { persist = true })
            emit_stream(child)
          else
            log.warn("[unifi] no stream for " .. child.label .. ": " .. tostring(serr))
          end
        end
      end
    end
  end
  return true
end

---------------------------------------------------------------------------
-- Connection loop
---------------------------------------------------------------------------

local function open_events_ws(host, key)
  local sock, err = api.tls_connect(host, 443, 10)
  if not sock then return nil, err end
  local config = LustreConfig.default():keep_alive(WS_KEEPALIVE):header("X-API-KEY", key)
  local ws = WebSocket.client(sock, api.EVENTS_WS, config)
  local ok, herr = ws:client_handshake_and_start(host, 443)
  if not ok then
    sock:close()
    return nil, "websocket: " .. tostring(herr)
  end
  return ws
end

local function close_ws(s)
  if s.ws then
    local ws = s.ws
    s.ws = nil
    pcall(function() ws:close(CloseCode.normal(), "reconnect") end)
  end
end

local function set_children_offline(driver, ctrl)
  for _, d in ipairs(driver:get_devices()) do
    if d.parent_device_id == ctrl.id then d:offline() end
  end
end

local function run(driver, ctrl, gen)
  local s = get_state(ctrl)
  local backoff = 5
  while s.gen == gen do
    local p = prefs(ctrl)
    if p.host == "" or p.key == "" then
      log.warn("[unifi] controller not configured: set Console IP address and API key in the app settings, or open "
        .. tostring(s.settings_url or "the settings page (press Refresh on the UniFi Protect device to open it for 15 minutes)"))
      ctrl:offline()
      socket.sleep(60)
      goto continue
    end

    local info, err = api.get_info(p.host, p.key)
    local ws
    if info then
      log.info("[unifi] connected to UniFi Protect " .. tostring(info.applicationVersion or ""))
      sync_cameras(driver, ctrl)
      ws, err = open_events_ws(p.host, p.key)
    end

    if not ws then
      log.error("[unifi] connection failed: " .. tostring(err))
      ctrl:offline()
      set_children_offline(driver, ctrl)
      socket.sleep(backoff)
      backoff = math.min(backoff * 2, 300)
    else
      s.ws = ws
      ctrl:online()
      backoff = 5
      log.info("[unifi] event stream open")
      while s.gen == gen do
        local ready, _, serr = socket.select({ ws }, nil, 60)
        if ready and ready[1] then
          local msg, rerr = ws:receive()
          if rerr then
            log.warn("[unifi] event stream closed: " .. tostring(rerr))
            break
          end
          if msg and msg.type == Message.TEXT then
            local ok, data = pcall(json.decode, msg.data)
            if ok and type(data) == "table" then
              local hok, herr = pcall(handle_event_message, driver, ctrl, data)
              if not hok then log.error("[unifi] event handling error: " .. tostring(herr)) end
            end
          end
        elseif serr and serr ~= "timeout" then
          log.warn("[unifi] select error: " .. tostring(serr))
          break
        end
        if ws.state ~= "Active" then
          log.warn("[unifi] event stream no longer active (" .. tostring(ws.state) .. ")")
          break
        end
        if os.time() - (s.last_sync or 0) > RESYNC_INTERVAL then
          prune_events(ctrl)
          sync_cameras(driver, ctrl)
        end
      end
      if s.ws == ws then close_ws(s) end
      if s.gen == gen then
        ctrl:offline()
        socket.sleep(backoff)
      end
    end
    ::continue::
  end
end

local function start(driver, ctrl)
  local s = get_state(ctrl)
  s.gen = s.gen + 1
  local gen = s.gen
  close_ws(s)
  cosock.spawn(function()
    local ok, err = pcall(run, driver, ctrl, gen)
    if not ok then log.error("[unifi] connection task crashed: " .. tostring(err)) end
  end, "unifi-protect " .. ctrl.id)
end

---------------------------------------------------------------------------
-- Lifecycle and capability handlers
---------------------------------------------------------------------------

local function child_init(driver, child)
  -- start every detection component in its idle state
  local ctrl = child:get_parent_device()
  if ctrl and states[ctrl.id] then states[ctrl.id].shown[child.parent_assigned_child_key] = {} end
  for comp in pairs(child.profile.components) do
    if COMPONENT_KIND[comp] then emit_state(child, comp, false) end
  end
  emit_led(child)
  if child:supports_capability_by_id("button") then
    child:emit_event(capabilities.button.supportedButtonValues({ "pushed" }, { visibility = { displayed = false } }))
    child:emit_event(capabilities.button.numberOfButtons({ value = 1 }, { visibility = { displayed = false } }))
  end
  emit_stream(child)
end

local function hub_ip(driver)
  local ok, ip = pcall(function() return driver.environment_info.hub_ipv4 end)
  return (ok and ip) or "<hub-ip>"
end

-- The settings page is never open for more than SETTINGS_WINDOW seconds: after the driver starts
-- without an API key, or after a Refresh of the controller. Then it closes again, configured or not,
-- so nobody on the LAN can change the settings unnoticed.
local SETTINGS_WINDOW = 900

local function settings_needed(ctrl)
  return prefs(ctrl).key == ""
end

local function close_settings_page(ctrl, why)
  local s = states[ctrl.id]
  if not (s and s.settings_srv) then return end
  s.settings_srv.stop()
  s.settings_srv, s.settings_url = nil, nil
  if why then log.info("[unifi] settings page closed (" .. why .. "). Press Refresh on the UniFi Protect device to open it for 15 minutes.") end
end

local function schedule_settings_check(driver, ctrl)
  local s = get_state(ctrl)
  if s.settings_check then return end
  s.settings_check = true
  driver:call_with_delay(30, function()
    local st = states[ctrl.id]
    if not st then return end
    st.settings_check = false
    if not st.settings_srv then return end
    if os.time() < (st.settings_until or 0) then
      schedule_settings_check(driver, ctrl)
    else
      close_settings_page(ctrl, settings_needed(ctrl) and "15 minutes passed" or "configured")
    end
  end, "unifi settings check")
end

local function open_settings_page(driver, ctrl)
  local s = get_state(ctrl)
  s.settings_until = os.time() + SETTINGS_WINDOW
  local how = "open for 15 minutes"
  if not s.settings_srv then
    local okc, srv, err = pcall(config_server.start, {
      get_status = function()
        local p = prefs(ctrl)
        local text
        if p.key == "" then text = "not configured"
        elseif s.ws then text = "connected to " .. p.host
        else text = "not connected (check IP address and API key)" end
        return { text = text, host = p.host }
      end,
      on_save = function(host, key)
        log.info("[unifi] settings saved via settings page, connecting to " .. host)
        ctrl:set_field("cfg_host", host, { persist = true })
        ctrl:set_field("cfg_key", key, { persist = true })
        -- close soon after a save instead of waiting for the full window
        local st = states[ctrl.id]
        if st then st.settings_until = os.time() + 60 end
        start(driver, ctrl)
      end,
    })
    if not okc or not srv then
      log.warn("[unifi] could not start settings page: " .. tostring(okc and err or srv))
      return
    end
    s.settings_srv = srv
    s.settings_url = string.format("http://%s:%d/", hub_ip(driver), srv.port)
  end
  log.info("[unifi] settings page: " .. s.settings_url .. " (" .. how .. ")")
  schedule_settings_check(driver, ctrl)
end

local function device_init(driver, device)
  if is_child(device) then
    child_init(driver, device)
  else
    if settings_needed(device) then
      open_settings_page(driver, device)
    else
      log.info("[unifi] settings page closed (configured). Press Refresh on the UniFi Protect device to open it for 15 minutes.")
    end
    start(driver, device)
  end
end

local function device_added(driver, device)
  if is_child(device) then
    child_init(driver, device)
    local ctrl = device:get_parent_device()
    if ctrl then
      -- pick up doorbell detection and video for the new device
      cosock.spawn(function() sync_cameras(driver, ctrl) end, "unifi sync")
    end
  end
end

local function info_changed(driver, device, event, args)
  if is_child(device) then
    -- profile changed (e.g. became doorbell or video toggled)
    child_init(driver, device)
    return
  end
  local old = (args and args.old_st_store and args.old_st_store.preferences) or {}
  local new = device.preferences or {}
  if old.host ~= new.host or old.apiKey ~= new.apiKey then
    log.info("[unifi] connection settings changed, reconnecting")
    start(driver, device)
  elseif new.readdRemoved == true and old.readdRemoved ~= true then
    log.info("[unifi] re-adding removed cameras")
    device:set_field("excluded", {}, { persist = true })
    get_state(device).pending = {}
    cosock.spawn(function() sync_cameras(driver, device) end, "unifi re-add")
  elseif old.enableVideo ~= new.enableVideo or old.videoQuality ~= new.videoQuality
      or old.videoSecure ~= new.videoSecure then
    cosock.spawn(function() sync_cameras(driver, device) end, "unifi video sync")
  end
end

local discovery_done = false

local function device_removed(driver, device)
  if is_child(device) then
    -- remember the removal so the camera does not come back on the next sync
    local ctrl = device:get_parent_device()
    if ctrl then
      local ex = excluded_list(ctrl)
      ex[device.parent_assigned_child_key] = true
      ctrl:set_field("excluded", ex, { persist = true })
      log.info("[unifi] camera removed, will not be re-added: " .. tostring(device.label))
    end
  else
    discovery_done = false
    close_settings_page(device)
    local s = get_state(device)
    s.gen = s.gen + 1
    close_ws(s)
    states[device.id] = nil
  end
end

local function handle_refresh(driver, device)
  if is_child(device) then
    local ctrl = device:get_parent_device()
    if ctrl then cosock.spawn(function() sync_cameras(driver, ctrl) end, "unifi refresh") end
  else
    open_settings_page(driver, device)
    start(driver, device)
  end
end

local function handle_led(driver, device, command)
  if command.component ~= "led" then return end
  local on = command.command == "on"
  local ctrl = device:get_parent_device()
  if not ctrl then return end
  local p = prefs(ctrl)
  local _, err = api.json_request(p.host, p.key, "PATCH", "/v1/cameras/" .. device.parent_assigned_child_key,
    { ledSettings = { isEnabled = on } })
  if err then
    log.warn("[unifi] could not switch LED of " .. device.label .. ": " .. tostring(err))
    emit_led(device) -- show the real state again
    return
  end
  device:set_field("led_on", on, { persist = true })
  emit_led(device)
end

local function handle_start_stream(driver, device)
  emit_stream(device)
end

local function handle_stop_stream(driver, device)
  -- nothing to stop: the stream lives on the UniFi console
end

local function discovery(driver, _, should_continue)
  for _, d in ipairs(driver:get_devices()) do
    if not is_child(d) then
      log.info("[unifi] controller already exists")
      return
    end
  end
  if discovery_done then return end
  discovery_done = true
  log.info("[unifi] creating UniFi Protect controller")
  driver:try_create_device({
    type = "LAN",
    device_network_id = "unifi-protect-local-" .. tostring(os.time()),
    label = "UniFi Protect",
    profile = "unifi-controller",
    manufacturer = "Ubiquiti",
    model = "UniFi Protect controller",
    vendor_provided_label = "UniFi Protect",
  })
end

local capability_handlers = {
  [capabilities.refresh.ID] = {
    [capabilities.refresh.commands.refresh.NAME] = handle_refresh,
  },
  [capabilities.switch.ID] = {
    [capabilities.switch.commands.on.NAME] = handle_led,
    [capabilities.switch.commands.off.NAME] = handle_led,
  },
}
-- videoStream is optional: never let a missing definition stop the driver
local vs_ok, vs_err = pcall(function()
  capability_handlers[capabilities.videoStream.ID] = {
    [capabilities.videoStream.commands.startStream.NAME] = handle_start_stream,
    [capabilities.videoStream.commands.stopStream.NAME] = handle_stop_stream,
  }
end)
if not vs_ok then log.warn("[unifi] videoStream capability unavailable: " .. tostring(vs_err)) end

local driver = Driver("unifi-protect-local", {
  discovery = discovery,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    infoChanged = info_changed,
    removed = device_removed,
  },
  capability_handlers = capability_handlers,
})

log.info("[unifi] UniFi Protect Local driver starting (v2.8.1)")
driver:run()
