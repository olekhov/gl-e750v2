-- UCI compatibility shim for eco Lua 5.4 runtime.
-- eco.uci:get() returns {[1]=value} instead of string.

local eco_uci = require("eco.uci")
local M = {}
local cursor_mt = {}
cursor_mt.__index = cursor_mt

function cursor_mt:get(config, section, option)
    local result = self._c:get(config, section, option)
    if type(result) == "table" then
        if result[1] ~= nil then return result[1] end
        return result
    end
    return result
end

function cursor_mt:set(config, section, option, value)
    local ok = self._c:set(config, section, option, value)
    if not ok then
        os.execute(string.format(
            "uci -q set '%s.%s.%s=%s'", config, section, option, tostring(value)))
    end
end

function cursor_mt:commit(config) self._c:commit(config) end
function cursor_mt:foreach(config, stype, cb) self._c:foreach(config, stype, cb) end
function cursor_mt:close() if self._c.close then self._c:close() end end

function M.cursor()
    return setmetatable({ _c = eco_uci.cursor() }, cursor_mt)
end

return M
