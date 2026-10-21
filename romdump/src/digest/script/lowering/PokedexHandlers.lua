-- Dex script lowering: the seventeen in-scope source commands become the
-- thirteen semantic dex operations. Literal mode and action bytes
-- normalize to their semantic enums here; evaluated operands keep
-- variable reads symbolic through varRef, and result operands ride the
-- output variable reference. The Rotom spare operand rides through for
-- the runtime to evaluate and discard. No node carries a native opcode.

local Errors = require("libs.errors.src.Errors")
local Operands = require("romdump.src.digest.script.lowering.Operands")

---@class PokedexHandlers
local PokedexHandlers = {}

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function PokedexHandlers.countJohtoDexSeen(ins)
  return {
    op = "pokedex_count",
    mode = "johto",
    kind = "seen",
    result = Operands.varRef(ins.operands[1]),
  }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function PokedexHandlers.countJohtoDexOwned(ins)
  return {
    op = "pokedex_count",
    mode = "johto",
    kind = "caught",
    result = Operands.varRef(ins.operands[1]),
  }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function PokedexHandlers.countNationalDexSeen(ins)
  return {
    op = "pokedex_count",
    mode = "national",
    kind = "seen",
    result = Operands.varRef(ins.operands[1]),
  }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function PokedexHandlers.countNationalDexOwned(ins)
  return {
    op = "pokedex_count",
    mode = "national",
    kind = "caught",
    result = Operands.varRef(ins.operands[1]),
  }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function PokedexHandlers.getDexEvalResult(ins)
  local mode = Operands.operandValue(ins.operands[1])
  return {
    op = "pokedex_evaluate",
    mode = mode == 0 and "johto" or "national",
    result = Operands.varRef(ins.operands[2]),
    musicResult = Operands.varRef(ins.operands[3]),
  }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function PokedexHandlers.checkPokedex(ins)
  return { op = "has_pokedex", result = Operands.varRef(ins.operands[1]) }
end

---@param _ unknown unused
---@return table<string, unknown>
function PokedexHandlers.givePokedex(_)
  return { op = "give_pokedex" }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function PokedexHandlers.checkJohtoDexComplete(ins)
  return { op = "pokedex_complete", mode = "johto", result = Operands.varRef(ins.operands[1]) }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function PokedexHandlers.checkNationalDexComplete(ins)
  return { op = "pokedex_complete", mode = "national", result = Operands.varRef(ins.operands[1]) }
end

---@param _ unknown unused
---@return table<string, unknown>
function PokedexHandlers.enablePokedexFormDetection(_)
  return { op = "enable_pokedex_form_detection" }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function PokedexHandlers.natDexFlagAction(ins)
  local action = Operands.operandValue(ins.operands[1])
  if action == 1 then
    return { op = "national_pokedex", action = "enable", result = Operands.varRef(ins.operands[2]) }
  end
  if action == 2 then
    return { op = "national_pokedex", action = "check", result = Operands.varRef(ins.operands[2]) }
  end
  Errors.raise("SCRIPT_UNKNOWN_NATIONAL_ACTION", "NatDexFlagAction names a known action selector", {
    sourceOffset = ins.offset,
    opcode = ins.opcode,
    action = action,
  })
  error("unreachable", 0)
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function PokedexHandlers.setPartyDeoxysForm(ins)
  return { op = "set_party_deoxys_form", form = Operands.varRef(ins.operands[1]) }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function PokedexHandlers.countUnownLettersRegistered(ins)
  return { op = "caught_unown_count", result = Operands.varRef(ins.operands[1]) }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function PokedexHandlers.updateRotomForm(ins)
  return {
    op = "update_rotom_form",
    slot = Operands.varRef(ins.operands[1]),
    defaultMoveSlot = Operands.varRef(ins.operands[2]),
    unused = Operands.varRef(ins.operands[3]),
    form = Operands.varRef(ins.operands[4]),
  }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function PokedexHandlers.setMonSeenFlag(ins)
  return { op = "observe_species", species = Operands.varRef(ins.operands[1]) }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function PokedexHandlers.checkMonSeen(ins)
  return {
    op = "has_seen_species",
    species = Operands.varRef(ins.operands[1]),
    result = Operands.varRef(ins.operands[2]),
  }
end

---@param ins table<string, unknown> decoded instruction record
---@return table<string, unknown>
function PokedexHandlers.checkSeenAllLetterUnown(ins)
  return { op = "caught_all_unown_letters", result = Operands.varRef(ins.operands[1]) }
end

return PokedexHandlers
