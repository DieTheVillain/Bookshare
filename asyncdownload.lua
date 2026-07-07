--[[
asyncdownload.lua - Non-blocking book download.

Instead of one long blocking http.request (which freezes the UI and
copes badly with Kindle Wi-Fi power-save stalls), this opens a raw TCP
socket, sends the GET, then pumps the response in chunks from a
UIManager-scheduled task. The UI stays live, progress can be shown,
and a napping Wi-Fi radio just slows the pump instead of blowing a
single big timeout.
]]

local UIManager = require("ui/uimanager")
local logger = require("logger")
local socket = require("socket")

local AsyncDownload = {}

local CHUNK = 65536
local PUMP_INTERVAL = 0.1        -- seconds between pump ticks
local MAX_READS_PER_TICK = 64    -- up to ~4 MB per tick when data is flowing
local STALL_TIMEOUT = 45         -- give power-save Wi-Fi plenty of rope

--- opts: ip, port, code, book_id, tmp_path,
---       on_progress(bytes_got, total_or_nil),
---       on_success(), on_failure(msg)
--- Callbacks fire from the UI event loop. Errors inside the pump are
--- caught and routed to on_failure instead of taking KOReader down.
function AsyncDownload.start(opts)
    local function fail(msg)
        logger.warn("BookShare: download failed:", msg)
        opts.on_failure(msg)
    end

    local sock = socket.tcp()
    if not sock then return fail("could not create socket") end
    sock:settimeout(6)
    local ok, cerr = sock:connect(opts.ip, opts.port)
    if not ok then
        pcall(function() sock:close() end)
        return fail("connect failed (" .. tostring(cerr) .. ")")
    end

    local request = string.format(
        "GET /get?id=%d HTTP/1.0\r\nHost: %s\r\nX-BookShare-Code: %s\r\nConnection: close\r\n\r\n",
        opts.book_id, opts.ip, opts.code)
    local sent, serr = sock:send(request)
    if not sent then
        pcall(function() sock:close() end)
        return fail("send failed (" .. tostring(serr) .. ")")
    end

    local f = io.open(opts.tmp_path, "wb")
    if not f then
        pcall(function() sock:close() end)
        return fail("cannot write to download folder")
    end

    sock:settimeout(0)  -- everything from here on is non-blocking

    local state = {
        buffer = "",
        in_body = false,
        content_length = nil,
        got = 0,
        last_activity = socket.gettime(),
        finished = false,
    }

    local function finish(success, msg)
        if state.finished then return end
        state.finished = true
        pcall(function() sock:close() end)
        pcall(function() f:close() end)
        if success then
            opts.on_success()
        else
            os.remove(opts.tmp_path)
            fail(msg)
        end
    end

    local function handle_chunk(chunk)
        state.last_activity = socket.gettime()
        if state.in_body then
            f:write(chunk)
            state.got = state.got + #chunk
            return
        end
        state.buffer = state.buffer .. chunk
        local head_end = state.buffer:find("\r\n\r\n", 1, true)
        if not head_end then
            if #state.buffer > 32768 then
                finish(false, "malformed response headers")
            end
            return
        end
        local head = state.buffer:sub(1, head_end - 1)
        local status = tonumber(head:match("^HTTP/%d%.%d%s+(%d+)"))
        state.content_length = tonumber(head:match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
        if status ~= 200 then
            finish(false, status == 401 and "friend code rejected"
                or ("server replied " .. tostring(status)))
            return
        end
        local body_start = state.buffer:sub(head_end + 4)
        state.buffer = ""
        state.in_body = true
        if #body_start > 0 then
            f:write(body_start)
            state.got = #body_start
        end
    end

    local function pump_inner()
        for _ = 1, MAX_READS_PER_TICK do
            local data, rerr, partial = sock:receive(CHUNK)
            local chunk = data or partial
            if chunk and #chunk > 0 then
                handle_chunk(chunk)
                if state.finished then return end
            end
            if state.in_body and state.content_length
                and state.got >= state.content_length then
                return finish(true)
            end
            if not data then
                if rerr == "closed" then
                    -- Server closed: complete if we got everything (or
                    -- length was unknown and we got something at all).
                    if state.in_body and state.got > 0
                        and (not state.content_length
                             or state.got >= state.content_length) then
                        return finish(true)
                    end
                    return finish(false, "connection closed mid-transfer")
                end
                break  -- timeout: no more data right now, come back later
            end
        end

        if socket.gettime() - state.last_activity > STALL_TIMEOUT then
            return finish(false, "transfer stalled")
        end
        if opts.on_progress then
            pcall(opts.on_progress, state.got, state.content_length)
        end
        UIManager:scheduleIn(PUMP_INTERVAL, function()
            if not state.finished then
                local pump_ok, pump_err = pcall(pump_inner)
                if not pump_ok then finish(false, tostring(pump_err)) end
            end
        end)
    end

    UIManager:scheduleIn(PUMP_INTERVAL, function()
        local pump_ok, pump_err = pcall(pump_inner)
        if not pump_ok then finish(false, tostring(pump_err)) end
    end)
end

return AsyncDownload
