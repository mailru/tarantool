-- uuid.lua (internal file)

local ffi = require("ffi")
local buffer = require('buffer')
local builtin = ffi.C

ffi.cdef[[
struct tt_uuid {
    uint32_t time_low;
    uint16_t time_mid;
    uint16_t time_hi_and_version;
    uint8_t clock_seq_hi_and_reserved;
    uint8_t clock_seq_low;
    uint8_t node[6];
};

void
tt_uuid_create(struct tt_uuid *uu);
int
tt_uuid_from_string(const char *in, struct tt_uuid *uu);
void
tt_uuid_to_string(const struct tt_uuid *uu, char *out);
void
tt_uuid_bswap(struct tt_uuid *uu);
bool
tt_uuid_is_nil(const struct tt_uuid *uu);
bool
tt_uuid_is_equal(const struct tt_uuid *lhs, const struct tt_uuid *rhs);
extern const struct tt_uuid uuid_nil;
]]

local uuid_t = ffi.typeof('struct tt_uuid')
local UUID_STR_LEN = 36
local UUID_LEN = ffi.sizeof(uuid_t)
local uuid_stash = buffer.ffi_stash_new(uuid_t)
local uuid_stash_take = uuid_stash.take
local uuid_stash_put = uuid_stash.put

local uuid_str_stash =
    buffer.ffi_stash_new(string.format('char[%s]', UUID_STR_LEN + 1))
local uuid_str_stash_take = uuid_str_stash.take
local uuid_str_stash_put = uuid_str_stash.put

local uuid_tostring = function(uu)
    if not ffi.istype(uuid_t, uu) then
        return error('Usage: uuid:str()')
    end
    local strbuf = uuid_str_stash_take()
    builtin.tt_uuid_to_string(uu, strbuf)
    uu = ffi.string(strbuf, UUID_STR_LEN)
    uuid_str_stash_put(strbuf)
    return uu
end

local uuid_fromstr = function(str)
    if type(str) ~= 'string' then
        error("fromstr(str)")
    end
    local uu = ffi.new(uuid_t)
    local rc = builtin.tt_uuid_from_string(str, uu)
    if rc ~= 0 then
        return nil
    end
    return uu
end

local need_bswap = function(order)
    if order == nil or order == 'l' or order == 'h' or order == 'host' then
        return false
    elseif order == 'b' or order == 'n' or order == 'network' then
        return true
    else
        error('invalid byteorder, valid is l, b, h, n')
    end
end

local uuid_tobin = function(uu, byteorder)
    if not ffi.istype(uuid_t, uu) then
        return error('Usage: uuid:bin([byteorder])')
    end
    if need_bswap(byteorder) then
        local uuidbuf = uuid_stash_take()
        ffi.copy(uuidbuf, uu, UUID_LEN)
        builtin.tt_uuid_bswap(uuidbuf)
        uu = ffi.string(ffi.cast('char *', uuidbuf), UUID_LEN)
        uuid_stash_put(uuidbuf)
        return uu
    end
    return ffi.string(ffi.cast('char *', uu), UUID_LEN)
end

local uuid_frombin = function(bin, byteorder)
    if type(bin) ~= 'string' or #bin ~= UUID_LEN then
        error("frombin(bin, [byteorder])")
    end
    local uu = ffi.new(uuid_t)
    ffi.copy(uu, bin, UUID_LEN)
    if need_bswap(byteorder) then
        builtin.tt_uuid_bswap(uu)
    end
    return uu
end

local uuid_isnil = function(uu)
    if not ffi.istype(uuid_t, uu) then
        return error('Usage: uuid:isnil()')
    end
    return builtin.tt_uuid_is_nil(uu)
end

local uuid_eq = function(lhs, rhs)
    if not ffi.istype(uuid_t, rhs) then
        return false
    end
    if not ffi.istype(uuid_t, lhs) then
        return error('Usage: uuid == var')
    end
    return builtin.tt_uuid_is_equal(lhs, rhs)
end

local uuid_new = function()
    local uu = ffi.new(uuid_t)
    builtin.tt_uuid_create(uu)
    return uu
end

local uuid_new_bin = function(byteorder)
    local uuidbuf = uuid_stash_take()
    builtin.tt_uuid_create(uuidbuf)
    local res = uuid_tobin(uuidbuf, byteorder)
    uuid_stash_put(uuidbuf)
    return res
end
local uuid_new_str = function()
    local uuidbuf = uuid_stash_take()
    builtin.tt_uuid_create(uuidbuf)
    local res = uuid_tostring(uuidbuf)
    uuid_stash_put(uuidbuf)
    return res
end

local uuid_mt = {
    __tostring = uuid_tostring;
    __eq = uuid_eq;
    __index = {
        isnil = uuid_isnil;
        bin   = uuid_tobin;    -- binary host byteorder
        str   = uuid_tostring; -- RFC4122 string
    }
}

ffi.metatype(uuid_t, uuid_mt)

return setmetatable({
    NULL        = builtin.uuid_nil;
    new         = uuid_new;
    fromstr     = uuid_fromstr;
    frombin     = uuid_frombin;
    bin         = uuid_new_bin;   -- optimized shortcut for new():bin()
    str         = uuid_new_str;   -- optimized shortcut for new():str()
}, {
    __call = uuid_new; -- shortcut for new()
})
