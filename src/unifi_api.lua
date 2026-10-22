-- Minimal HTTPS client for the UniFi Protect Integration API (local, API key).
-- UniFi consoles use a self-signed certificate, so verification is disabled.

local socket = require "cosock.socket"
local ssl = require "cosock.ssl"
local json = require "st.json"
local log = require "log"

local M = {}

M.BASE = "/proxy/protect/integration"
M.EVENTS_WS = "/proxy/protect/integration/v1/subscribe/events"

local TIMEOUT = 10

--- Open a TLS connection to host:port.
function M.tls_connect(host, port, timeout)
  local sock, err = socket.tcp()
  if not sock then return nil, "tcp: " .. tostring(err) end
  sock:settimeout(timeout or TIMEOUT)
  local ok, cerr = sock:connect(host, port or 443)
  if not ok then
    sock:close()
    return nil, "connect: " .. tostring(cerr)
  end
  sock:setoption("keepalive", true)
  local tls, werr = ssl.wrap(sock, {
    mode = "client",
    protocol = "any",
    verify = "none",
    options = "all",
  })
  if not tls then
    sock:close()
    return nil, "tls wrap: " .. tostring(werr)
  end
  local hs, herr = tls:dohandshake()
  if not hs then
    tls:close()
    return nil, "tls handshake: " .. tostring(herr)
  end
  return tls
end

--- Perform one HTTPS request. Returns status, body (string), err.
function M.request(host, api_key, method, path, body_tbl)
  local sock, err = M.tls_connect(host, 443)
  if not sock then return nil, nil, err end

  local body = body_tbl and json.encode(body_tbl) or nil
  local lines = {
    string.format("%s %s HTTP/1.1", method, path),
    "Host: " .. host,
    "User-Agent: smartthings-edge-unifi-protect-local",
    "Accept: application/json",
    "X-API-KEY: " .. api_key,
    "Connection: close",
  }
  if body then
    table.insert(lines, "Content-Type: application/json")
    table.insert(lines, "Content-Length: " .. #body)
  end
  local req = table.concat(lines, "\r\n") .. "\r\n\r\n" .. (body or "")

  local sent, serr = sock:send(req)
  if not sent then
    sock:close()
    return nil, nil, "send: " .. tostring(serr)
  end

  local function fail(msg)
    sock:close()
    return nil, nil, msg
  end

  -- status line and headers, line by line
  local line, rerr = sock:receive("*l")
  if not line then return fail("receive status: " .. tostring(rerr)) end
  local status = tonumber(line:match("^HTTP/%d%.?%d?%s+(%d+)"))
  if not status then return fail("malformed status line: " .. line:sub(1, 80)) end
  local headers = {}
  while true do
    line, rerr = sock:receive("*l")
    if not line then return fail("receive headers: " .. tostring(rerr)) end
    if line == "" then break end
    local k, v = line:match("^([^:]+):%s*(.-)%s*$")
    if k then headers[k:lower()] = v end
  end

  -- body
  local parts = {}
  if (headers["transfer-encoding"] or ""):lower():find("chunked", 1, true) then
    while true do
      line, rerr = sock:receive("*l")
      if not line then return fail("receive chunk size: " .. tostring(rerr)) end
      local size = tonumber(line:match("^%s*(%x+)"), 16)
      if not size then return fail("bad chunk size") end
      if size == 0 then break end
      local data, cerr, partial = sock:receive(size)
      if not data then return fail("receive chunk: " .. tostring(cerr) .. " " .. tostring(partial and #partial)) end
      table.insert(parts, data)
      sock:receive("*l") -- CRLF after each chunk
    end
  elseif headers["content-length"] then
    local len = tonumber(headers["content-length"]) or 0
    if len > 0 then
      local data, cerr = sock:receive(len)
      if not data then return fail("receive body: " .. tostring(cerr)) end
      table.insert(parts, data)
    end
  else
    local data, _, partial = sock:receive("*a")
    table.insert(parts, data or partial or "")
  end
  sock:close()
  return status, table.concat(parts)
end

--- Request and decode JSON. Returns decoded table or nil, err.
function M.json_request(host, api_key, method, path, body_tbl)
  local status, body, err = M.request(host, api_key, method, M.BASE .. path, body_tbl)
  if not status then return nil, err end
  if status == 401 or status == 403 then
    return nil, "unauthorized (HTTP " .. status .. "): check the API key", status
  end
  if status < 200 or status >= 300 then
    return nil, "HTTP " .. status .. ": " .. tostring(body):sub(1, 200), status
  end
  if body == nil or body == "" then return {}, nil, status end
  local ok, decoded = pcall(json.decode, body)
  if not ok or decoded == nil then
    return nil, "invalid JSON: " .. tostring(body):sub(1, 200), status
  end
  return decoded, nil, status
end

function M.get_info(host, api_key)
  return M.json_request(host, api_key, "GET", "/v1/meta/info")
end

function M.get_cameras(host, api_key)
  return M.json_request(host, api_key, "GET", "/v1/cameras")
end

--- Get (or create) the RTSPS stream URL for a camera and quality.
function M.get_stream_url(host, api_key, camera_id, quality)
  local path = "/v1/cameras/" .. camera_id .. "/rtsps-stream"
  local streams, err = M.json_request(host, api_key, "GET", path)
  if streams and type(streams[quality]) == "string" then
    return streams[quality]
  end
  if err then log.warn("[unifi] get rtsps-stream failed: " .. tostring(err)) end
  local created, cerr = M.json_request(host, api_key, "POST", path, { qualities = { quality } })
  if created and type(created[quality]) == "string" then
    return created[quality]
  end
  return nil, cerr or "no stream URL returned"
end

--- Convert the RTSPS URL (port 7441, SRTP) into plain RTSP (port 7447) when wanted.
function M.stream_url_variant(url, secure, host)
  if not url then return nil end
  if secure then return url end
  local path = url:match("^rtsps://[^/]+(/[^?]*)")
  if not path then return url end
  local h = url:match("^rtsps://([^:/]+)") or host
  return string.format("rtsp://%s:7447%s", h, path)
end

return M
