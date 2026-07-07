--[[
jsonutil.lua - JSON helper for BookShare.

Tries KOReader's bundled JSON libraries first (rapidjson, then dkjson),
and falls back to a small built-in encoder/decoder that covers the
subset of JSON this plugin's protocol actually uses.
]]

local JsonUtil = {}

-- ---------------------------------------------------------------------------
-- Try bundled libraries first
-- ---------------------------------------------------------------------------
local ok_rapid, rapidjson = pcall(require, "rapidjson")
if ok_rapid and type(rapidjson) == "table" and rapidjson.encode then
    function JsonUtil.encode(t) return rapidjson.encode(t) end
    function JsonUtil.decode(s)
        local ok, res = pcall(rapidjson.decode, s)
        if ok then return res end
        return nil, res
    end
    return JsonUtil
end

local ok_dk, dkjson = pcall(require, "dkjson")
if ok_dk and type(dkjson) == "table" and dkjson.encode then
    function JsonUtil.encode(t) return dkjson.encode(t) end
    function JsonUtil.decode(s)
        local res, _, err = dkjson.decode(s)
        if res ~= nil then return res end
        return nil, err
    end
    return JsonUtil
end

-- ---------------------------------------------------------------------------
-- Fallback: minimal original implementation
-- ---------------------------------------------------------------------------

local escape_map = {
    ["\""] = "\\\"", ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function escape_str(s)
    return (s:gsub("[%z\1-\31\\\"]", function(c)
        return escape_map[c] or string.format("\\u%04x", c:byte())
    end))
end

local function is_array(t)
    -- Treat as array if keys are 1..n integers. Empty tables encode as [].
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
        n = n + 1
    end
    return n == #t
end

local function encode_value(v)
    local tv = type(v)
    if v == nil then
        return "null"
    elseif tv == "boolean" then
        return v and "true" or "false"
    elseif tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        return string.format("%.14g", v)
    elseif tv == "string" then
        return "\"" .. escape_str(v) .. "\""
    elseif tv == "table" then
        local parts = {}
        if is_array(v) then
            for _, item in ipairs(v) do
                parts[#parts + 1] = encode_value(item)
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            for k, item in pairs(v) do
                parts[#parts + 1] = "\"" .. escape_str(tostring(k)) .. "\":" .. encode_value(item)
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

function JsonUtil.encode(t)
    return encode_value(t)
end

-- Decoder: simple recursive descent parser.
local function decode_error(str, pos, msg)
    return nil, string.format("JSON error at %d: %s", pos, msg)
end

local parse_value  -- forward declaration

local function skip_ws(str, pos)
    local _, e = str:find("^[ \t\r\n]*", pos)
    return e + 1
end

local function parse_string(str, pos)
    -- pos points at opening quote
    local out = {}
    local i = pos + 1
    while i <= #str do
        local c = str:sub(i, i)
        if c == "\"" then
            return table.concat(out), i + 1
        elseif c == "\\" then
            local nxt = str:sub(i + 1, i + 1)
            if nxt == "u" then
                local hex = str:sub(i + 2, i + 5)
                local code = tonumber(hex, 16)
                if not code then return decode_error(str, i, "bad unicode escape") end
                -- Encode code point as UTF-8 (BMP only; good enough here)
                if code < 0x80 then
                    out[#out + 1] = string.char(code)
                elseif code < 0x800 then
                    out[#out + 1] = string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
                else
                    out[#out + 1] = string.char(0xE0 + math.floor(code / 0x1000),
                        0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
                end
                i = i + 6
            else
                local unesc = { ["\""] = "\"", ["\\"] = "\\", ["/"] = "/",
                    b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
                local rep = unesc[nxt]
                if not rep then return decode_error(str, i, "bad escape") end
                out[#out + 1] = rep
                i = i + 2
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return decode_error(str, pos, "unterminated string")
end

local function parse_number(str, pos)
    local num_str = str:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
    local num = tonumber(num_str)
    if not num then return decode_error(str, pos, "bad number") end
    return num, pos + #num_str
end

local function parse_array(str, pos)
    local arr = {}
    pos = skip_ws(str, pos + 1)
    if str:sub(pos, pos) == "]" then return arr, pos + 1 end
    while true do
        local val
        val, pos = parse_value(str, pos)
        if type(pos) ~= "number" then return nil, pos end
        arr[#arr + 1] = val
        pos = skip_ws(str, pos)
        local c = str:sub(pos, pos)
        if c == "]" then return arr, pos + 1 end
        if c ~= "," then return decode_error(str, pos, "expected , or ]") end
        pos = skip_ws(str, pos + 1)
    end
end

local function parse_object(str, pos)
    local obj = {}
    pos = skip_ws(str, pos + 1)
    if str:sub(pos, pos) == "}" then return obj, pos + 1 end
    while true do
        if str:sub(pos, pos) ~= "\"" then return decode_error(str, pos, "expected key") end
        local key
        key, pos = parse_string(str, pos)
        if type(pos) ~= "number" then return nil, pos end
        pos = skip_ws(str, pos)
        if str:sub(pos, pos) ~= ":" then return decode_error(str, pos, "expected :") end
        pos = skip_ws(str, pos + 1)
        local val
        val, pos = parse_value(str, pos)
        if type(pos) ~= "number" then return nil, pos end
        obj[key] = val
        pos = skip_ws(str, pos)
        local c = str:sub(pos, pos)
        if c == "}" then return obj, pos + 1 end
        if c ~= "," then return decode_error(str, pos, "expected , or }") end
        pos = skip_ws(str, pos + 1)
    end
end

parse_value = function(str, pos)
    pos = skip_ws(str, pos)
    local c = str:sub(pos, pos)
    if c == "{" then return parse_object(str, pos)
    elseif c == "[" then return parse_array(str, pos)
    elseif c == "\"" then return parse_string(str, pos)
    elseif c == "t" and str:sub(pos, pos + 3) == "true" then return true, pos + 4
    elseif c == "f" and str:sub(pos, pos + 4) == "false" then return false, pos + 5
    elseif c == "n" and str:sub(pos, pos + 3) == "null" then return nil, pos + 4
    else return parse_number(str, pos) end
end

function JsonUtil.decode(s)
    if type(s) ~= "string" then return nil, "not a string" end
    local val, pos_or_err = parse_value(s, 1)
    if type(pos_or_err) ~= "number" then
        return nil, pos_or_err
    end
    return val
end

return JsonUtil
