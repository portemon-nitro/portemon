-- Shared source-operand normalization for script lowering handlers. Numeric
-- variable ranges follow the retail ROM's variable definitions, field actor
-- references follow the pinned scrcmd.h actor specials, and movement selectors
-- follow the source object-movement table.
local Errors = require("libs.errors.src.Errors")
local HgssObjectMovement = require("romdump.src.digest.field.HgssObjectMovement")

local Operands = {}

-- The pinned field direction table and scrcmd.h actor specials.
local ACTOR_REFERENCES = {
  directionByCode = { [0] = "north", [1] = "south", [2] = "west", [3] = "east" },
  stringSpecials = { obj_player = "player", obj_partner_poke = "partner" },
  numericSpecials = {
    [255] = "player",
    [253] = "partner",
    [241] = "camera_target",
  },
}

-- A variable-typed operand: symbols stay symbolic, numbers stay numbers.
---@param value unknown
---@return unknown
function Operands.operandValue(value)
  if type(value) == "table" then
    return value.raw
  end
  return value
end

-- Value-or-variable operand (ScriptGetVar semantics). The numeric ranges and
-- symbolic prefixes are grounded in the pinned vars.h definitions.
---@param value unknown
---@return unknown
function Operands.varRef(value)
  local raw = Operands.operandValue(value)
  if type(raw) == "number" then
    if (raw >= 0x4000 and raw < 0x4400) or (raw >= 0x8000 and raw < 0x8100) then
      return { value = "var", id = raw }
    end
    return raw
  end
  if raw:match("^VAR_") or raw:match("^SPECIAL_VAR_") then
    return { value = "var", id = raw }
  end
  return raw
end

-- A source direction operand as its semantic cardinal direction.
---@param value unknown
---@return unknown
function Operands.normalizeFacing(value)
  if type(value) ~= "number" then
    return value
  end
  local direction = ACTOR_REFERENCES.directionByCode[value]
  assert(direction ~= nil, "unknown direction code " .. tostring(value))
  return direction
end

-- A direction operand read through ScriptGetVar: the command returns the
-- variable's value, so a script variable stays a value reference while a
-- literal direction code is still the cardinal direction it names.
---@param value unknown
---@return unknown
function Operands.directionRef(value)
  local ref = Operands.varRef(value)
  if type(ref) == "table" then
    return ref
  end
  return Operands.normalizeFacing(ref)
end

-- A source object operand as an actor reference: literal ids, code variables,
-- the engine's last-interacted variable, and the pinned actor specials.
---@param value unknown
---@return table<string, unknown>
function Operands.actorRef(value)
  local raw = Operands.operandValue(value)
  local special
  if type(raw) == "number" then
    special = ACTOR_REFERENCES.numericSpecials[raw]
  elseif type(raw) == "string" then
    special = ACTOR_REFERENCES.stringSpecials[raw]
  end
  if special ~= nil then
    return { ref = "actor", special = special }
  end
  if type(raw) == "string" then
    if raw == "VAR_SPECIAL_LAST_TALKED" then
      -- The engine's last-interacted object variable spells the trigger's
      -- own actor: object commands read it through ScriptGetVar, so the
      -- decoded variable lowers to the semantic special instead of a
      -- literal id no live actor carries. (FieldScriptSymbols pins
      -- VAR_SPECIAL_LAST_TALKED to 0x800D; the decoder emits the name.)
      return { ref = "actor", special = "last_talked" }
    end
    if raw:match("^VAR_") then
      return { ref = "actor", mapIndex = { id = raw, value = "var" } }
    end
    return { ref = "actor", id = raw }
  end
  return { ref = "actor", mapIndex = raw }
end

-- The immediate object-movement selector of a two-operand object command as
-- its semantic movement key; an unknown selector is an attributed failure.
---@param ins table<string, unknown>
---@return string
function Operands.movementType(ins)
  local rawMovement = Operands.operandValue(ins.operands[2])
  local ok, movementType = pcall(HgssObjectMovement.semanticType, rawMovement)
  if not ok then
    Errors.raise("SCRIPT_UNKNOWN_OBJECT_MOVEMENT", "the object movement selector is invalid", {
      sourceOffset = ins.offset,
      opcode = ins.opcode,
      movement = rawMovement,
    })
  end
  return movementType
end

return Operands
