--[[
httpserver.lua - Tiny HTTP/1.0 server for sharing books.

Design notes:
* Module-level singleton, so the server survives KOReader switching
  between the file manager and the reader (plugin instances get
  recreated on that switch, but required modules are cached).
* Non-blocking accept: the listening socket has a 0 timeout and gets
  polled via UIManager:scheduleIn(). Individual requests are handled
  synchronously with short socket timeouts; file transfers stream in
  chunks. A big download will briefly hog the UI thread - acceptable
  for v1, same tradeoff KOReader's calibre companion makes.
* Security: clients can never request a file by path. /list assigns
  each book an opaque numeric id, /get?id=N looks the id up in the
  snapshot generated for that same client. No path traversal surface.
* Auth: /list and /get require the device owner's friend code in the
  X-BookShare-Code header (or ?code= as a fallback for debugging).
]]

local UIManager = require("ui/uimanager")
local logger = require("logger")
local socket = require("socket")
local lfs = require("libs/libkoreader-lfs")
local JsonUtil = require("jsonutil")
local FriendCode = require("friendcode")

local Server = {
    running = false,
    tcp = nil,
    port = nil,
    poll_scheduled = false,
    -- Callbacks injected by main.lua (re-injected on every plugin init):
    get_auth_code = function() return nil end,
    get_shared_folders = function() return {} end,
    get_device_name = function() return "KOReader" end,
    -- Book snapshot: id -> absolute path. Rebuilt on every /list.
    book_index = {},
}

local POLL_INTERVAL = 0.75  -- seconds between accept() polls
local CHUNK_SIZE = 65536
local MAX_HEADER_LINES = 64

local EBOOK_EXTENSIONS = {
    epub = true, pdf = true, mobi = true, azw = true, azw3 = true,
    fb2 = true, djvu = true, cbz = true, cbr = true, txt = true,
    doc = true, docx = true, rtf = true, html = true, htm = true,
    md = true, zip = true, prc = true, chm = true, xps = true,
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function file_extension(path)
    return path:match("%.([%w]+)$")
end

local function basename(path)
    return path:match("([^/]+)$") or path
end

--- Walk shared folders (one level of recursion into subfolders) and
--- build a fresh { {id, name, size, folder} } list plus the id->path index.
local function scan_shared_folders(folders)
    local books, index = {}, {}
    local seen = {}

    local function add_file(fullpath, folder_label)
        if seen[fullpath] then return end
        local ext = file_extension(fullpath)
        if not ext or not EBOOK_EXTENSIONS[ext:lower()] then return end
        local attr = lfs.attributes(fullpath)
        if not attr or attr.mode ~= "file" then return end
        seen[fullpath] = true
        local id = #books + 1
        index[id] = fullpath
        books[#books + 1] = {
            id = id,
            name = basename(fullpath),
            size = attr.size or 0,
            folder = folder_label,
        }
    end

    local function scan_dir(dir, label, depth)
        if depth > 3 then return end  -- keep recursion sane
        local ok, iter, dir_obj = pcall(lfs.dir, dir)
        if not ok then return end
        for entry in iter, dir_obj do
            if entry ~= "." and entry ~= ".." and not entry:match("^%.") then
                local full = dir .. "/" .. entry
                local attr = lfs.attributes(full)
                if attr then
                    if attr.mode == "file" then
                        add_file(full, label)
                    elseif attr.mode == "directory" then
                        scan_dir(full, label .. "/" .. entry, depth + 1)
                    end
                end
            end
        end
    end

    for _, folder in ipairs(folders) do
        local clean = folder:gsub("/+$", "")
        scan_dir(clean, basename(clean), 1)
    end
    return books, index
end

local function url_decode(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

--- Parse "GET /get?id=3 HTTP/1.1" style request line + headers.
local function read_request(client)
    local request_line, err = client:receive("*l")
    if not request_line then return nil, err end
    local method, target = request_line:match("^(%u+)%s+(%S+)")
    if not method then return nil, "malformed request line" end

    local path, query_string = target:match("^([^%?]*)%??(.*)$")
    local query = {}
    for k, v in query_string:gmatch("([^&=]+)=([^&]*)") do
        query[url_decode(k)] = url_decode(v)
    end

    local headers = {}
    for _ = 1, MAX_HEADER_LINES do
        local line = client:receive("*l")
        if not line or line == "" then break end
        local k, v = line:match("^([^:]+):%s*(.*)$")
        if k then headers[k:lower()] = v end
    end

    return { method = method, path = path, query = query, headers = headers }
end

local function send_response(client, status, status_text, content_type, body, extra_headers)
    local head = {
        string.format("HTTP/1.0 %d %s", status, status_text),
        "Content-Type: " .. content_type,
        "Content-Length: " .. #body,
        "Connection: close",
        "Server: KOReader-BookShare/1",
    }
    for _, h in ipairs(extra_headers or {}) do head[#head + 1] = h end
    head[#head + 1] = ""
    head[#head + 1] = ""
    client:send(table.concat(head, "\r\n") .. body)
end

local function send_json(client, status, status_text, tbl)
    send_response(client, status, status_text, "application/json", JsonUtil.encode(tbl))
end

-- ---------------------------------------------------------------------------
-- Request handlers
-- ---------------------------------------------------------------------------

local function is_authorized(req)
    local presented = req.headers["x-bookshare-code"] or req.query.code
    local mine = Server.get_auth_code()
    if not mine or not presented then return false end
    return FriendCode.matches(presented, mine)
end

local function handle_ping(client)
    send_json(client, 200, "OK", {
        app = "bookshare",
        version = 1,
        name = Server.get_device_name(),
    })
end

local function handle_list(client, req)
    if not is_authorized(req) then
        send_json(client, 401, "Unauthorized", { error = "bad or missing friend code" })
        return
    end
    local books, index = scan_shared_folders(Server.get_shared_folders())
    Server.book_index = index
    send_json(client, 200, "OK", {
        name = Server.get_device_name(),
        books = books,
    })
end

local function handle_get(client, req)
    if not is_authorized(req) then
        send_json(client, 401, "Unauthorized", { error = "bad or missing friend code" })
        return
    end
    local id = tonumber(req.query.id)
    local path = id and Server.book_index[id]
    if not path then
        send_json(client, 404, "Not Found",
            { error = "unknown book id; call /list first" })
        return
    end
    local attr = lfs.attributes(path)
    local f = attr and io.open(path, "rb")
    if not f then
        send_json(client, 404, "Not Found", { error = "file no longer available" })
        return
    end

    local head = table.concat({
        "HTTP/1.0 200 OK",
        "Content-Type: application/octet-stream",
        "Content-Length: " .. attr.size,
        "Connection: close",
        "Server: KOReader-BookShare/1",
        "", "",
    }, "\r\n")
    client:send(head)

    -- Stream in chunks so we never hold a whole book in memory.
    client:settimeout(15)
    while true do
        local chunk = f:read(CHUNK_SIZE)
        if not chunk then break end
        local sent, send_err = client:send(chunk)
        if not sent then
            logger.warn("BookShare: send aborted:", send_err)
            break
        end
    end
    f:close()
end

local function handle_client(client)
    client:settimeout(3)
    local req, err = read_request(client)
    if not req then
        logger.dbg("BookShare: bad request:", err)
        client:close()
        return
    end

    if req.method ~= "GET" then
        send_json(client, 405, "Method Not Allowed", { error = "GET only" })
    elseif req.path == "/ping" then
        handle_ping(client)
    elseif req.path == "/list" then
        handle_list(client, req)
    elseif req.path == "/get" then
        handle_get(client, req)
    else
        send_json(client, 404, "Not Found", { error = "unknown endpoint" })
    end
    client:close()
end

-- ---------------------------------------------------------------------------
-- Poll loop
-- ---------------------------------------------------------------------------

local function poll()
    Server.poll_scheduled = false
    if not Server.running or not Server.tcp then return end

    -- Drain everything waiting right now, then go back to sleep.
    while true do
        local client = Server.tcp:accept()
        if not client then break end
        local ok, handler_err = pcall(handle_client, client)
        if not ok then
            logger.warn("BookShare: request handler error:", handler_err)
            pcall(function() client:close() end)
        end
    end

    Server.poll_scheduled = true
    UIManager:scheduleIn(POLL_INTERVAL, poll)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Inject/refresh callbacks. Called on every plugin init so the server
--- keeps working across FileManager <-> Reader switches.
function Server.configure(opts)
    Server.get_auth_code = opts.get_auth_code or Server.get_auth_code
    Server.get_shared_folders = opts.get_shared_folders or Server.get_shared_folders
    Server.get_device_name = opts.get_device_name or Server.get_device_name
end

function Server.start(port)
    if Server.running and Server.port == port then return true end
    Server.stop()

    local tcp, err = socket.bind("0.0.0.0", port)
    if not tcp then
        logger.warn("BookShare: could not bind port", port, err)
        return false, err
    end
    tcp:settimeout(0)  -- non-blocking accept
    Server.tcp = tcp
    Server.port = port
    Server.running = true

    if not Server.poll_scheduled then
        Server.poll_scheduled = true
        UIManager:scheduleIn(POLL_INTERVAL, poll)
    end
    logger.info("BookShare: server listening on port", port)
    return true
end

function Server.stop()
    if Server.tcp then
        pcall(function() Server.tcp:close() end)
    end
    Server.tcp = nil
    Server.running = false
    Server.port = nil
    UIManager:unschedule(poll)
    Server.poll_scheduled = false
end

function Server.isRunning()
    return Server.running
end

-- Exposed for tests and debugging (takes any object with the client
-- socket interface: receive/send/settimeout/close).
Server._handle_client = handle_client

return Server
