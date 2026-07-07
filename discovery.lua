--[[
discovery.lua - LAN peer discovery over UDP broadcast.

Responder: listens on DISCOVERY_PORT for the magic string and replies
with a small JSON blob (device name + HTTP port). Runs on the same
UIManager polling pattern as the HTTP server. Only active while
sharing is enabled.

Scanner: broadcasts the magic string and collects replies for a couple
of seconds. Blocking, so callers should show an InfoMessage first.
]]

local UIManager = require("ui/uimanager")
local logger = require("logger")
local socket = require("socket")
local JsonUtil = require("jsonutil")

local Discovery = {
    DISCOVERY_PORT = 8134,
    MAGIC = "KOREADER_BOOKSHARE_V1",
    running = false,
    udp = nil,
    poll_scheduled = false,
    get_reply_info = function() return { name = "KOReader", port = 8135 } end,
}

local POLL_INTERVAL = 1.0

local function poll()
    Discovery.poll_scheduled = false
    if not Discovery.running or not Discovery.udp then return end

    while true do
        local data, ip, port = Discovery.udp:receivefrom()
        if not data then break end
        if data == Discovery.MAGIC then
            local info = Discovery.get_reply_info()
            local reply = JsonUtil.encode({
                app = "bookshare",
                name = info.name,
                port = info.port,
            })
            Discovery.udp:sendto(reply, ip, port)
            logger.dbg("BookShare: answered discovery from", ip)
        end
    end

    Discovery.poll_scheduled = true
    UIManager:scheduleIn(POLL_INTERVAL, poll)
end

function Discovery.configure(opts)
    Discovery.get_reply_info = opts.get_reply_info or Discovery.get_reply_info
end

function Discovery.start()
    if Discovery.running then return true end
    local udp = socket.udp()
    if not udp then return false, "could not create UDP socket" end
    udp:settimeout(0)
    local ok, err = udp:setsockname("0.0.0.0", Discovery.DISCOVERY_PORT)
    if not ok then
        logger.warn("BookShare: discovery bind failed:", err)
        pcall(function() udp:close() end)
        return false, err
    end
    Discovery.udp = udp
    Discovery.running = true
    if not Discovery.poll_scheduled then
        Discovery.poll_scheduled = true
        UIManager:scheduleIn(POLL_INTERVAL, poll)
    end
    return true
end

function Discovery.stop()
    if Discovery.udp then
        pcall(function() Discovery.udp:close() end)
    end
    Discovery.udp = nil
    Discovery.running = false
    UIManager:unschedule(poll)
    Discovery.poll_scheduled = false
end

--- Broadcast and collect peers. Blocks for ~total_wait seconds.
--- Returns array of { name = ..., port = ..., ip = ... }.
function Discovery.scan(total_wait)
    total_wait = total_wait or 2.0
    local udp = socket.udp()
    if not udp then return {} end
    udp:setsockname("0.0.0.0", 0)
    udp:setoption("broadcast", true)
    udp:settimeout(0.25)

    -- Send a few broadcasts in case one gets dropped.
    for _ = 1, 3 do
        udp:sendto(Discovery.MAGIC, "255.255.255.255", Discovery.DISCOVERY_PORT)
    end

    local peers, seen = {}, {}
    local deadline = socket.gettime() + total_wait
    while socket.gettime() < deadline do
        local data, ip = udp:receivefrom()
        if data and ip and not seen[ip] then
            local info = JsonUtil.decode(data)
            if type(info) == "table" and info.app == "bookshare" and info.port then
                seen[ip] = true
                peers[#peers + 1] = {
                    name = info.name or ip,
                    port = tonumber(info.port),
                    ip = ip,
                }
            end
        end
    end
    udp:close()
    return peers
end

return Discovery
