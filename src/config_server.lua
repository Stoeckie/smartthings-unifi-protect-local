-- Small local web page on the hub to enter the console IP address and API key.
-- For users who cannot open the device settings in the SmartThings app.
-- Values are stored on the hub only (persistent device fields), never in the package.

local cosock = require "cosock"
local socket = require "cosock.socket"
local log = require "log"

local M = {}

local function url_decode(s)
  s = s:gsub("+", " ")
  s = s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
  return s
end

local function parse_form(body)
  local out = {}
  for pair in (body or ""):gmatch("[^&]+") do
    local k, v = pair:match("^([^=]*)=?(.*)$")
    if k then out[url_decode(k)] = url_decode(v or "") end
  end
  return out
end

local function html_escape(s)
  return (tostring(s or ""):gsub("[&<>\"']", {
    ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;",
  }))
end

local function page(title, inner)
  return [[<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>UniFi Protect Local</title>
<style>
body{font-family:system-ui,sans-serif;max-width:480px;margin:32px auto;padding:0 16px;color:#222}
h1{font-size:1.3em}label{display:block;margin-top:14px;font-weight:600}
input{width:100%;box-sizing:border-box;padding:8px;font-size:1em;margin-top:4px}
button{margin-top:18px;padding:10px 18px;font-size:1em}
.note{color:#666;font-size:.9em}.ok{color:#0a7d2c}.err{color:#b00020}
</style></head><body><h1>]] .. html_escape(title) .. "</h1>" .. inner .. "</body></html>"
end

local function form_page(status)
  return page("UniFi Protect Local", [[
<p class="note">Status: ]] .. html_escape(status.text) .. [[</p>
<form method="post" action="/save">
<label for="host">Console IP address</label>
<input id="host" name="host" value="]] .. html_escape(status.host) .. [[" placeholder="192.168.1.1" required>
<label for="key">API key</label>
<input id="key" name="key" type="password" autocomplete="off" placeholder="paste your local API key" required>
<p class="note">The key is stored on your SmartThings hub only and is never shown again.
IP address and key are always saved together.</p>
<button type="submit">Save and connect</button>
</form>]])
end

local function respond(client, code, body)
  local reason = ({ [200] = "OK", [400] = "Bad Request", [404] = "Not Found", [303] = "See Other" })[code] or "OK"
  local head = string.format(
    "HTTP/1.1 %d %s\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
    code, reason, #body)
  client:send(head .. body)
end

local function read_request(client)
  client:settimeout(5)
  local line, err = client:receive("*l")
  if not line then return nil, err end
  local method, path = line:match("^(%u+)%s+(%S+)")
  local headers = {}
  while true do
    local h = client:receive("*l")
    if not h or h == "" then break end
    local k, v = h:match("^([^:]+):%s*(.-)%s*$")
    if k then headers[k:lower()] = v end
  end
  local body = ""
  local len = tonumber(headers["content-length"] or "0") or 0
  if len > 0 and len < 4096 then body = client:receive(len) or "" end
  return { method = method, path = path, headers = headers, body = body }
end

local function valid_host(h)
  return #h > 0 and #h <= 253 and h:match("^[%w%.%-]+$") ~= nil
end

local function valid_key(k)
  return #k >= 8 and #k <= 256 and k:match("^[%w%-%._~+/=]+$") ~= nil
end

--- Start the settings page.
-- opts.get_status() -> { text = string, host = string }
-- opts.on_save(host, key) is called with validated values.
-- Returns the port number, or nil and an error.
function M.start(opts)
  local server, err = socket.tcp()
  if not server then return nil, err end
  local ok, berr = server:bind("*", 0) -- Edge only allows port 0 (random port)
  if not ok then return nil, "bind: " .. tostring(berr) end
  server:listen(4)
  local _, port = server:getsockname()

  cosock.spawn(function()
    while true do
      local client = server:accept()
      if client then
        cosock.spawn(function()
          local okh, herr = pcall(function()
            local req = read_request(client)
            if not req then return end
            if req.method == "GET" and (req.path == "/" or req.path:match("^/%?")) then
              respond(client, 200, form_page(opts.get_status()))
            elseif req.method == "POST" and req.path == "/save" then
              local form = parse_form(req.body)
              local host = (form.host or ""):gsub("%s", ""):gsub("^https?://", ""):gsub("/.*$", ""):gsub(":%d+$", "")
              local key = (form.key or ""):gsub("%s", "")
              if not valid_host(host) or not valid_key(key) then
                respond(client, 400, page("Not saved", '<p class="err">Please enter a valid IP address and API key.</p><p><a href="/">Back</a></p>'))
              else
                opts.on_save(host, key)
                respond(client, 200, page("Saved", '<p class="ok">Saved. The driver is connecting to ' .. html_escape(host) ..
                  '.</p><p>Check the UniFi Protect device in the SmartThings app in a minute.</p><p><a href="/">Back</a></p>'))
              end
            else
              respond(client, 404, page("Not found", '<p><a href="/">Settings</a></p>'))
            end
          end)
          if not okh then log.warn("[unifi] settings page error: " .. tostring(herr)) end
          client:close()
        end, "unifi settings client")
      end
    end
  end, "unifi settings server")

  return port
end

M._parse_form = parse_form
M._valid_host = valid_host
M._valid_key = valid_key

return M
