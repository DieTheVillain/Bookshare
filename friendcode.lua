--[[
friendcode.lua - Friend code generation and normalization.

A friend code is 80 bits of randomness rendered as 16 characters of
Crockford base32 (no I, L, O, U), grouped as XXXX-XXXX-XXXX-XXXX.

The code doubles as the bearer token that authorizes a friend to read
your shared library, so treat it like a house key: only give it to
people you actually want browsing your shared folders.
]]

local FriendCode = {}

local ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

local function random_bytes(n)
    local f = io.open("/dev/urandom", "rb")
    if f then
        local data = f:read(n)
        f:close()
        if data and #data == n then return data end
    end
    -- Weak fallback (should never be needed on Kindle/desktop Linux)
    math.randomseed(os.time() + math.floor((os.clock() % 1) * 1e6))
    local out = {}
    for i = 1, n do out[i] = string.char(math.random(0, 255)) end
    return table.concat(out)
end

--- Generate a new code like "K7Q2-M9XP-4RTA-BC3D".
function FriendCode.generate()
    local bytes = random_bytes(10)  -- 80 bits -> exactly 16 base32 chars
    local bits, bit_count = 0, 0
    local chars = {}
    for i = 1, #bytes do
        bits = bits * 256 + bytes:byte(i)
        bit_count = bit_count + 8
        while bit_count >= 5 do
            bit_count = bit_count - 5
            local idx = math.floor(bits / 2 ^ bit_count) % 32
            chars[#chars + 1] = ALPHABET:sub(idx + 1, idx + 1)
        end
    end
    local code = table.concat(chars)
    return code:sub(1, 4) .. "-" .. code:sub(5, 8) .. "-"
        .. code:sub(9, 12) .. "-" .. code:sub(13, 16)
end

--- Normalize user input: uppercase, strip separators, map lookalikes.
--- Returns the canonical 16-char string, or nil if it can't be one.
function FriendCode.normalize(input)
    if type(input) ~= "string" then return nil end
    local s = input:upper():gsub("[%s%-_%.]", "")
    s = s:gsub("O", "0"):gsub("[IL]", "1"):gsub("U", "V")
    if #s ~= 16 then return nil end
    for i = 1, 16 do
        if not ALPHABET:find(s:sub(i, i), 1, true) then return nil end
    end
    return s
end

--- Pretty-print a canonical code with dashes for display.
function FriendCode.format(canonical)
    if not canonical or #canonical ~= 16 then return canonical or "" end
    return canonical:sub(1, 4) .. "-" .. canonical:sub(5, 8) .. "-"
        .. canonical:sub(9, 12) .. "-" .. canonical:sub(13, 16)
end

--- Constant-ish time comparison of two normalized codes.
function FriendCode.matches(a, b)
    a, b = FriendCode.normalize(a), FriendCode.normalize(b)
    if not a or not b then return false end
    local diff = 0
    for i = 1, 16 do
        if a:byte(i) ~= b:byte(i) then diff = diff + 1 end
    end
    return diff == 0
end

return FriendCode
