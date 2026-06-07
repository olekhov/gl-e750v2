-- iwinfo stub for eco (Lua 5.4) runtime.
-- iwinfo.so is Lua 5.1 ABI — incompatible with eco.
-- In vanilla OpenWrt the MCU script only calls iwinfo inside mwan3/gl-kmwan
-- branches that never execute, so returning nil is safe.
local M = {}
function M.info(iface) return nil end
function M.type(iface) return nil end
return M
