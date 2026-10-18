-- Pinned HGSS signpost window command catalog: the five MAPSIGNCOMMAND_*
-- values (0..4) opcodes 57/58 decode (`MAPSIGNCOMMAND_NOP`..`HIDE`; the
-- retail ROM's signpost handler dispatches the same five commands). The script
-- corpus itself carries these values: SetSignpostAction 3/2/4 and the
-- std_signpost sequence rely on the exact numbering. Pure data; no love
-- dependency.

local M = {
  schema = 1,
  byCode = {
    [0] = { sourceName = "MAPSIGNCOMMAND_NOP", semantic = "nop" },
    [1] = { sourceName = "MAPSIGNCOMMAND_SHOW", semantic = "show" },
    [2] = { sourceName = "MAPSIGNCOMMAND_WIPE_OUT", semantic = "wipe_out" },
    [3] = { sourceName = "MAPSIGNCOMMAND_WIPE_IN", semantic = "wipe_in" },
    [4] = { sourceName = "MAPSIGNCOMMAND_HIDE", semantic = "hide" },
  },
}

-- The semantic command enum string (nop/show/wipe_out/wipe_in/hide) for a
-- raw MAPSIGNCOMMAND_* code, or nil when the code is not one of the five
-- pinned commands. Unknown codes are malformed source at lowering; nothing
-- ever defaults to nop.
---@param code unknown
---@return string|nil
function M.semanticName(code)
  local entry = M.byCode[code]
  if type(entry) ~= "table" then
    return nil
  end
  return entry.semantic
end

return M
