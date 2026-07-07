--[[
main.lua - BookShare plugin for KOReader.

Share ebooks between two KOReader devices on the same Wi-Fi network.
Each device generates a friend code; exchange codes with a friend and
each of you can browse and download from the folders the other has
chosen to share.

Menu lives under: Tools -> Book Share
]]

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local PathChooser = require("ui/widget/pathchooser")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local AsyncDownload = require("asyncdownload")
local Client = require("httpclient")
local Discovery = require("discovery")
local FriendCode = require("friendcode")
local Server = require("httpserver")

local DEFAULT_PORT = 8135

local BookShare = WidgetContainer:extend{
    name = "bookshare",
    is_doc_only = false,
}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function BookShare:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/bookshare.lua")

    -- First run: mint a friend code.
    if not self.settings:readSetting("my_code") then
        self.settings:saveSetting("my_code", FriendCode.normalize(FriendCode.generate()))
        self.settings:flush()
    end

    -- Re-inject callbacks every init so the singleton server keeps
    -- working when KOReader swaps between FileManager and Reader.
    Server.configure{
        get_auth_code = function() return self.settings:readSetting("my_code") end,
        get_shared_folders = function() return self.settings:readSetting("shared_folders") or {} end,
        get_device_name = function() return self:getDeviceName() end,
    }
    Discovery.configure{
        get_reply_info = function()
            return { name = self:getDeviceName(), port = self:getPort() }
        end,
    }

    -- Restore server state after a KOReader restart.
    if self.settings:readSetting("sharing_enabled") and not Server.isRunning() then
        if NetworkMgr:isConnected() then
            self:startSharing(true)
        end
    end

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function BookShare:onDispatcherRegisterActions()
    Dispatcher:registerAction("bookshare_toggle", {
        category = "none",
        event = "BookShareToggle",
        title = _("Toggle Book Share server"),
        general = true,
    })
end

function BookShare:onBookShareToggle()
    if Server.isRunning() then
        self:stopSharing()
        UIManager:show(InfoMessage:new{ text = _("Book sharing stopped."), timeout = 2 })
    else
        self:ensureOnline(function() self:startSharing() end)
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Settings helpers
-- ---------------------------------------------------------------------------

function BookShare:getPort()
    return tonumber(self.settings:readSetting("port")) or DEFAULT_PORT
end

function BookShare:getDeviceName()
    local name = self.settings:readSetting("device_name")
    if name and name ~= "" then return name end
    return (Device.model or "KOReader")
end

function BookShare:getDownloadDir()
    local dir = self.settings:readSetting("download_dir")
    if dir and lfs.attributes(dir, "mode") == "directory" then return dir end
    -- Default: <home>/From Friends, created on demand.
    local home = G_reader_settings:readSetting("home_dir")
        or DataStorage:getDataDir()
    local target = home .. "/From Friends"
    if lfs.attributes(target, "mode") ~= "directory" then
        lfs.mkdir(target)
    end
    return target
end

function BookShare:getFriends()
    return self.settings:readSetting("friends") or {}
end

function BookShare:saveFriends(friends)
    self.settings:saveSetting("friends", friends)
    self.settings:flush()
end

function BookShare:ensureOnline(callback)
    if NetworkMgr:isConnected() then
        callback()
        return
    end
    -- Newer KOReader: turn on Wi-Fi, then rerun. Older: just prompt.
    if NetworkMgr.willRerunWhenOnline then
        NetworkMgr:willRerunWhenOnline(callback)
    else
        UIManager:show(InfoMessage:new{
            text = _("Wi-Fi is off. Please enable Wi-Fi and try again."),
        })
    end
end

-- ---------------------------------------------------------------------------
-- Sharing (server) control
-- ---------------------------------------------------------------------------

--- Kindle firmware ships iptables rules that drop unsolicited inbound
--- traffic, which blocks both our TCP server and UDP discovery. KOReader
--- runs as root on Kindle, so we can open our ports while sharing is on.
--- Delete-then-insert keeps the rules idempotent across toggles/crashes.
local FIREWALL_RULES = {
    { proto = "tcp", port = nil },  -- HTTP port, filled in at runtime
    { proto = "udp", port = Discovery.DISCOVERY_PORT },
}

function BookShare:openKindleFirewall()
    if not Device:isKindle() then return end
    FIREWALL_RULES[1].port = self:getPort()
    for _idx, rule in ipairs(FIREWALL_RULES) do
        pcall(os.execute, string.format(
            "iptables -D INPUT -p %s --dport %d -j ACCEPT 2>/dev/null",
            rule.proto, rule.port))
        pcall(os.execute, string.format(
            "iptables -I INPUT -p %s --dport %d -j ACCEPT 2>/dev/null",
            rule.proto, rule.port))
    end
    logger.info("BookShare: opened Kindle firewall ports")
end

function BookShare:closeKindleFirewall()
    if not Device:isKindle() then return end
    FIREWALL_RULES[1].port = self:getPort()
    for _idx, rule in ipairs(FIREWALL_RULES) do
        pcall(os.execute, string.format(
            "iptables -D INPUT -p %s --dport %d -j ACCEPT 2>/dev/null",
            rule.proto, rule.port))
    end
end

function BookShare:startSharing(silent)
    local folders = self.settings:readSetting("shared_folders") or {}
    if #folders == 0 and not silent then
        UIManager:show(InfoMessage:new{
            text = _("No shared folders yet. Add at least one folder under Sharing → Shared folders."),
        })
        return
    end

    local ok, err = Server.start(self:getPort())
    if not ok then
        UIManager:show(InfoMessage:new{
            text = T(_("Could not start sharing: %1"), tostring(err)),
        })
        return
    end
    Discovery.start()
    self:openKindleFirewall()
    self.settings:saveSetting("sharing_enabled", true)
    self.settings:flush()

    if not silent then
        local ip = Client.getLocalIP() or _("unknown")
        UIManager:show(InfoMessage:new{
            text = T(_("Sharing is on.\n\nDevice: %1\nAddress: %2:%3\n\nKeep Wi-Fi enabled while your friend browses. Tip: enable “Keep Wi-Fi on” in KOReader's network settings, and note that the device must stay awake during transfers."),
                self:getDeviceName(), ip, self:getPort()),
        })
    end
end

function BookShare:stopSharing()
    Server.stop()
    Discovery.stop()
    self:closeKindleFirewall()
    self.settings:saveSetting("sharing_enabled", false)
    self.settings:flush()
end

-- ---------------------------------------------------------------------------
-- Friend management
-- ---------------------------------------------------------------------------

function BookShare:showMyCode()
    local code = FriendCode.format(self.settings:readSetting("my_code"))
    UIManager:show(ConfirmBox:new{
        text = T(_("Your friend code:\n\n%1\n\nGive this to a friend so they can browse your shared folders. Anyone with this code can download from your shared folders while sharing is on."), code),
        ok_text = _("Close"),
        cancel_text = _("Regenerate"),
        cancel_callback = function()
            UIManager:show(ConfirmBox:new{
                text = _("Regenerate your friend code?\n\nFriends using your current code will lose access until you give them the new one."),
                ok_text = _("Regenerate"),
                ok_callback = function()
                    self.settings:saveSetting("my_code",
                        FriendCode.normalize(FriendCode.generate()))
                    self.settings:flush()
                    self:showMyCode()
                end,
            })
        end,
    })
end

function BookShare:addFriend()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Add friend"),
        fields = {
            { text = "", hint = _("Friend's name") },
            { text = "", hint = _("Friend code (XXXX-XXXX-XXXX-XXXX)") },
        },
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Add"),
                is_enter_default = true,
                callback = function()
                    local fields = dialog:getFields()
                    local name = fields[1] and fields[1]:gsub("^%s+", ""):gsub("%s+$", "")
                    local code = FriendCode.normalize(fields[2] or "")
                    if not name or name == "" then
                        UIManager:show(InfoMessage:new{ text = _("Please enter a name.") })
                        return
                    end
                    if not code then
                        UIManager:show(InfoMessage:new{
                            text = _("That doesn't look like a valid friend code. It should be 16 characters, like K7Q2-M9XP-4RTA-BC3D."),
                        })
                        return
                    end
                    local friends = self:getFriends()
                    friends[#friends + 1] = { name = name, code = code }
                    self:saveFriends(friends)
                    UIManager:close(dialog)
                    UIManager:show(InfoMessage:new{
                        text = T(_("Added %1."), name), timeout = 2,
                    })
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function BookShare:manageFriends()
    local friends = self:getFriends()
    if #friends == 0 then
        UIManager:show(InfoMessage:new{ text = _("No friends added yet.") })
        return
    end
    local items = {}
    for i, friend in ipairs(friends) do
        items[#items + 1] = {
            text = string.format("%s  (%s)", friend.name, FriendCode.format(friend.code)),
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = T(_("Remove %1 from your friends?"), friend.name),
                    ok_text = _("Remove"),
                    ok_callback = function()
                        table.remove(friends, i)
                        self:saveFriends(friends)
                        UIManager:close(self.friends_menu)
                    end,
                })
            end,
        }
    end
    self.friends_menu = Menu:new{
        title = _("Friends (tap to remove)"),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        onMenuSelect = function(menu_self, item)
            if item.callback then
                local ok, cb_err = pcall(item.callback)
                if not ok then
                    logger.warn("BookShare: menu callback error:", cb_err)
                    UIManager:show(InfoMessage:new{
                        text = T(_("BookShare error: %1"), tostring(cb_err)),
                    })
                end
            end
        end,
    }
    UIManager:show(self.friends_menu)
end

-- ---------------------------------------------------------------------------
-- Shared folder management
-- ---------------------------------------------------------------------------

function BookShare:addSharedFolder()
    local start_path = G_reader_settings:readSetting("home_dir") or "/"
    local chooser = PathChooser:new{
        title = _("Choose a folder to share"),
        select_directory = true,
        select_file = false,
        path = start_path,
        onConfirm = function(path)
            local folders = self.settings:readSetting("shared_folders") or {}
            for _idx, existing in ipairs(folders) do
                if existing == path then
                    UIManager:show(InfoMessage:new{ text = _("Already shared.") })
                    return
                end
            end
            folders[#folders + 1] = path
            self.settings:saveSetting("shared_folders", folders)
            self.settings:flush()
            UIManager:show(InfoMessage:new{
                text = T(_("Now sharing:\n%1"), path), timeout = 2,
            })
        end,
    }
    UIManager:show(chooser)
end

function BookShare:getSharedFoldersMenu()
    local items = {
        {
            text = _("＋ Add a folder"),
            keep_menu_open = true,
            callback = function() self:addSharedFolder() end,
        },
    }
    local folders = self.settings:readSetting("shared_folders") or {}
    for i, folder in ipairs(folders) do
        items[#items + 1] = {
            text = folder,
            keep_menu_open = true,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = T(_("Stop sharing this folder?\n\n%1"), folder),
                    ok_text = _("Stop sharing"),
                    ok_callback = function()
                        table.remove(folders, i)
                        self.settings:saveSetting("shared_folders", folders)
                        self.settings:flush()
                    end,
                })
            end,
        }
    end
    return items
end

-- ---------------------------------------------------------------------------
-- Browse & download flow
-- ---------------------------------------------------------------------------

--- Show a blocking-operation notice and force a repaint so the user
--- sees it before we do synchronous network work.
function BookShare:withNotice(text, fn)
    local notice = InfoMessage:new{ text = text }
    UIManager:show(notice)
    UIManager:forceRePaint()
    UIManager:nextTick(function()
        local ok, err = pcall(fn)
        UIManager:close(notice)
        if not ok then
            logger.warn("BookShare:", err)
            UIManager:show(InfoMessage:new{
                text = T(_("Something went wrong: %1"), tostring(err)),
            })
        end
    end)
end

function BookShare:browseFriendLibrary()
    local friends = self:getFriends()
    if #friends == 0 then
        UIManager:show(InfoMessage:new{
            text = _("Add a friend first (Friends → Add friend)."),
        })
        return
    end

    -- One friend: skip the picker.
    if #friends == 1 then
        self:ensureOnline(function() self:connectToFriend(friends[1]) end)
        return
    end

    local items = {}
    for _idx, friend in ipairs(friends) do
        items[#items + 1] = {
            text = friend.name,
            callback = function()
                UIManager:close(self.pick_friend_menu)
                self:ensureOnline(function() self:connectToFriend(friend) end)
            end,
        }
    end
    self.pick_friend_menu = Menu:new{
        title = _("Whose library?"),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        onMenuSelect = function(menu_self, item)
            if item.callback then
                local ok, cb_err = pcall(item.callback)
                if not ok then
                    logger.warn("BookShare: menu callback error:", cb_err)
                    UIManager:show(InfoMessage:new{
                        text = T(_("BookShare error: %1"), tostring(cb_err)),
                    })
                end
            end
        end,
    }
    UIManager:show(self.pick_friend_menu)
end

function BookShare:connectToFriend(friend)
    -- Try the last known address first, then fall back to a LAN scan.
    self:withNotice(T(_("Looking for %1's device…"), friend.name), function()
        if friend.last_ip and friend.last_port then
            local data = Client.list(friend.last_ip, friend.last_port, friend.code)
            if data then
                self:showFriendBooks(friend, friend.last_ip, friend.last_port, data)
                return
            end
        end

        local peers = Discovery.scan(2.0)
        if #peers == 0 then
            self:promptManualIP(friend)
            return
        end

        -- Try each discovered peer with this friend's code until one accepts.
        local rejected = false
        for _idx, peer in ipairs(peers) do
            local data, err = Client.list(peer.ip, peer.port, friend.code)
            if data then
                self:rememberFriendAddress(friend, peer.ip, peer.port)
                self:showFriendBooks(friend, peer.ip, peer.port, data)
                return
            elseif err == "unauthorized" then
                rejected = true
            end
        end

        if rejected then
            UIManager:show(InfoMessage:new{
                text = T(_("Found a device, but %1's code was rejected. Double-check the code they gave you (Friends → Manage friends)."), friend.name),
            })
        else
            self:promptManualIP(friend)
        end
    end)
end

function BookShare:rememberFriendAddress(friend, ip, port)
    local friends = self:getFriends()
    for _idx, f in ipairs(friends) do
        if f.code == friend.code then
            f.last_ip, f.last_port = ip, port
        end
    end
    self:saveFriends(friends)
    friend.last_ip, friend.last_port = ip, port
end

--- Accept "192.168.1.23", "192.168.1.23:8135", or "http://192.168.1.23:8135/".
--- Returns host, port (port may be nil if not embedded in the input).
local function parse_address(input)
    local s = tostring(input or ""):gsub("%s", "")
    s = s:gsub("^[Hh][Tt][Tt][Pp][Ss]?://", ""):gsub("/.*$", "")
    local host, port = s:match("^(.-):(%d+)$")
    if host and host ~= "" then return host, tonumber(port) end
    if s == "" then return nil end
    return s, nil
end

function BookShare:promptManualIP(friend)
    local dialog
    dialog = InputDialog:new{
        title = T(_("Couldn't find %1 automatically"), friend.name),
        description = _("Make sure their sharing is on and you're on the same Wi-Fi. Or enter their IP address (shown on their device when sharing starts):"),
        input = friend.last_ip or "",
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Connect"),
                is_enter_default = true,
                callback = function()
                    local ip, embedded_port = parse_address(dialog:getInputText())
                    UIManager:close(dialog)
                    if not ip then return end
                    local port = embedded_port or self:getPort()
                    self:withNotice(_("Connecting…"), function()
                        local data, err = Client.list(ip, port, friend.code)
                        if data then
                            self:rememberFriendAddress(friend, ip, port)
                            self:showFriendBooks(friend, ip, port, data)
                        elseif err == "unauthorized" then
                            UIManager:show(InfoMessage:new{
                                text = _("Connected, but the friend code was rejected. Double-check the code."),
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = T(_("Couldn't connect: %1"), tostring(err)),
                            })
                        end
                    end)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function human_size(bytes)
    bytes = tonumber(bytes) or 0
    if bytes >= 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    elseif bytes >= 1024 then
        return string.format("%.0f KB", bytes / 1024)
    end
    return bytes .. " B"
end

function BookShare:showFriendBooks(friend, ip, port, data)
    local books = data.books or {}
    if #books == 0 then
        UIManager:show(InfoMessage:new{
            text = T(_("%1 isn't sharing any books right now."), friend.name),
        })
        return
    end

    table.sort(books, function(a, b)
        return tostring(a.name):lower() < tostring(b.name):lower()
    end)

    local items = {}
    for _idx, book in ipairs(books) do
        items[#items + 1] = {
            text = string.format("%s  ·  %s", book.name, human_size(book.size)),
            mandatory = book.folder,
            keep_menu_open = true,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = T(_("Download “%1” (%2) from %3?"),
                        book.name, human_size(book.size), friend.name),
                    ok_text = _("Download"),
                    ok_callback = function()
                        self:downloadBook(friend, ip, port, book)
                    end,
                })
            end,
        }
    end

    self.books_menu = Menu:new{
        title = T(_("%1's shared books (%2)"), data.name or friend.name, #books),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        onMenuSelect = function(menu_self, item)
            if item.callback then
                local ok, cb_err = pcall(item.callback)
                if not ok then
                    logger.warn("BookShare: menu callback error:", cb_err)
                    UIManager:show(InfoMessage:new{
                        text = T(_("BookShare error: %1"), tostring(cb_err)),
                    })
                end
            end
        end,
    }
    UIManager:show(self.books_menu)
end

function BookShare:downloadBook(friend, ip, port, book)
    local final_path, tmp_path = Client.preparePaths(self:getDownloadDir(), book.name)

    local progress = InfoMessage:new{
        text = T(_("Downloading %1\n0%% of %2"), book.name, human_size(book.size)),
    }
    UIManager:show(progress)
    local last_pct = 0

    local function show_progress(pct)
        UIManager:close(progress)
        progress = InfoMessage:new{
            text = T(_("Downloading %1\n%2%% of %3"),
                book.name, pct, human_size(book.size)),
        }
        UIManager:show(progress)
    end

    AsyncDownload.start{
        ip = ip,
        port = port,
        code = friend.code,
        book_id = book.id,
        tmp_path = tmp_path,
        on_progress = function(got, total)
            if not total or total == 0 then return end
            local pct = math.floor(got * 100 / total)
            -- E-ink friendly: repaint at most every 20%.
            if pct - last_pct >= 20 then
                last_pct = pct
                show_progress(pct)
            end
        end,
        on_success = function()
            UIManager:close(progress)
            local ok, rename_err = os.rename(tmp_path, final_path)
            if not ok then
                os.remove(tmp_path)
                UIManager:show(InfoMessage:new{
                    text = T(_("Download finished but could not save file: %1"),
                        tostring(rename_err)),
                })
                return
            end
            UIManager:show(ConfirmBox:new{
                text = T(_("Saved to:\n%1\n\nOpen it now?"), final_path),
                ok_text = _("Open"),
                cancel_text = _("Later"),
                ok_callback = function()
                    local ReaderUI = require("apps/reader/readerui")
                    ReaderUI:showReader(final_path)
                end,
            })
        end,
        on_failure = function(msg)
            UIManager:close(progress)
            UIManager:show(InfoMessage:new{
                text = T(_("Download failed: %1"), tostring(msg)),
            })
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Misc settings dialogs
-- ---------------------------------------------------------------------------

function BookShare:setDeviceName()
    local dialog
    dialog = InputDialog:new{
        title = _("Device name (what friends see)"),
        input = self:getDeviceName(),
        buttons = {{
            { text = _("Cancel"), id = "close",
              callback = function() UIManager:close(dialog) end },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local name = dialog:getInputText()
                    if name and name ~= "" then
                        self.settings:saveSetting("device_name", name)
                        self.settings:flush()
                    end
                    UIManager:close(dialog)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function BookShare:setDownloadDir()
    local chooser = PathChooser:new{
        title = _("Choose download folder"),
        select_directory = true,
        select_file = false,
        path = self:getDownloadDir(),
        onConfirm = function(path)
            self.settings:saveSetting("download_dir", path)
            self.settings:flush()
        end,
    }
    UIManager:show(chooser)
end

-- ---------------------------------------------------------------------------
-- Main menu
-- ---------------------------------------------------------------------------

function BookShare:addToMainMenu(menu_items)
    menu_items.bookshare = {
        text = _("Book Share"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return self:getMenuTable()
        end,
    }
end

function BookShare:getMenuTable()
    return {
        {
            text = _("Share my books"),
            checked_func = function() return Server.isRunning() end,
            callback = function()
                if Server.isRunning() then
                    self:stopSharing()
                else
                    self:ensureOnline(function() self:startSharing() end)
                end
            end,
        },
        {
            text = _("Browse a friend's library"),
            callback = function() self:browseFriendLibrary() end,
        },
        {
            text = _("My friend code"),
            keep_menu_open = true,
            callback = function() self:showMyCode() end,
            separator = true,
        },
        {
            text = _("Sharing"),
            sub_item_table_func = function()
                return {
                    {
                        text = _("Shared folders"),
                        sub_item_table_func = function()
                            return self:getSharedFoldersMenu()
                        end,
                    },
                    {
                        text_func = function()
                            return T(_("Device name: %1"), self:getDeviceName())
                        end,
                        keep_menu_open = true,
                        callback = function() self:setDeviceName() end,
                    },
                }
            end,
        },
        {
            text = _("Friends"),
            sub_item_table_func = function()
                return {
                    {
                        text = _("Add friend"),
                        keep_menu_open = true,
                        callback = function() self:addFriend() end,
                    },
                    {
                        text = _("Manage friends"),
                        keep_menu_open = true,
                        callback = function() self:manageFriends() end,
                    },
                }
            end,
        },
        {
            text_func = function()
                return T(_("Download folder: %1"), self:getDownloadDir())
            end,
            keep_menu_open = true,
            callback = function() self:setDownloadDir() end,
        },
    }
end

return BookShare
