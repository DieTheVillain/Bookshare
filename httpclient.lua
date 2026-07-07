--[[
httpclient.lua - Client side: talk to a friend's BookShare server.

Uses LuaSocket's socket.http (bundled with KOReader) with ltn12 sinks.
All calls are blocking; main.lua shows an InfoMessage and repaints
before invoking anything here.
]]

local socket = require("socket")
local http = require("socket.http")
local ltn12 = require("ltn12")
local JsonUtil = require("jsonutil")

local Client = {}

local LIST_TIMEOUT = 5

local function with_timeout(timeout, fn)
    local previous = http.TIMEOUT
    http.TIMEOUT = timeout
    local ok, a, b, c = pcall(fn)
    http.TIMEOUT = previous
    if not ok then return nil, a end
    return a, b, c
end

--- GET /ping - returns { name = ..., version = ... } or nil, err.
function Client.ping(ip, port)
    local body = {}
    local res, code = with_timeout(4, function()
        return http.request{
            url = string.format("http://%s:%d/ping", ip, port),
            sink = ltn12.sink.table(body),
        }
    end)
    if not res or code ~= 200 then
        return nil, "no response (" .. tostring(code) .. ")"
    end
    local info = JsonUtil.decode(table.concat(body))
    if type(info) ~= "table" or info.app ~= "bookshare" then
        return nil, "not a BookShare device"
    end
    return info
end

--- GET /list - returns { name = ..., books = { {id,name,size,folder}... } }
--- or nil, err. err == "unauthorized" means the friend code was rejected.
--- Retries a few times: Kindle Wi-Fi power-save often eats the first
--- packets of a fresh connection, so one attempt is not a fair test.
local LIST_ATTEMPTS = 3

function Client.list(ip, port, friend_code)
    local last_err
    for attempt = 1, LIST_ATTEMPTS do
        local body = {}
        local res, code = with_timeout(LIST_TIMEOUT, function()
            return http.request{
                url = string.format("http://%s:%d/list", ip, port),
                headers = { ["x-bookshare-code"] = friend_code },
                sink = ltn12.sink.table(body),
            }
        end)
        if code == 401 then return nil, "unauthorized" end
        if res and code == 200 then
            local data = JsonUtil.decode(table.concat(body))
            if type(data) == "table" and type(data.books) == "table" then
                return data
            end
            last_err = "malformed reply"
        else
            last_err = "connection failed (" .. tostring(code) .. ")"
        end
        if attempt < LIST_ATTEMPTS then socket.sleep(0.7) end
    end
    return nil, last_err
end

--- Strip anything path-like or hostile from a filename we got over the wire.
local function sanitize_filename(name)
    name = tostring(name or "book")
    name = name:gsub("[/\\]", "_"):gsub("%z", ""):gsub("^%.+", "_")
    if name == "" then name = "book" end
    return name
end

--- Avoid clobbering an existing file: "Foo.epub" -> "Foo (2).epub".
local function unique_path(dir, filename)
    local lfs = require("libs/libkoreader-lfs")
    local stem, ext = filename:match("^(.*)(%.[^%.]+)$")
    if not stem then stem, ext = filename, "" end
    local candidate = dir .. "/" .. filename
    local n = 2
    while lfs.attributes(candidate) do
        candidate = string.format("%s/%s (%d)%s", dir, stem, n, ext)
        n = n + 1
    end
    return candidate
end

--- Work out where a download should land. Returns final_path, tmp_path.
--- The actual transfer is handled by asyncdownload.lua so the UI never
--- blocks; this just owns the filename hygiene.
function Client.preparePaths(dest_dir, book_name)
    local filename = sanitize_filename(book_name)
    local final_path = unique_path(dest_dir, filename)
    return final_path, final_path .. ".bookshare-part"
end

--- Best-effort local IP (for showing the user, not for binding).
function Client.getLocalIP()
    local udp = socket.udp()
    if not udp then return nil end
    udp:setpeername("8.8.8.8", 53)
    local ip = udp:getsockname()
    udp:close()
    return ip
end

return Client
