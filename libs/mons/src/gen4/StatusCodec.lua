-- Native Generation-IV party-status word conversion
-- (pret/pokeheartgold include/constants/pokemon.h MON_STATUS_*): the low
-- three bits carry remaining sleep turns, poison, burn, freeze, paralysis,
-- and toxic occupy one bit each, and bits 8..11 carry the toxic turn
-- counter. Decode maps every supported word to the persistent condition
-- records the canonical mon stores, keeping sleep duration and the
-- poisoned/toxic distinction instead of flattening them into a boolean.
-- Project maps those records back to the exact word. Unsupported
-- combinations fail explicitly instead of guessing a status, and custom or
-- battle-transient effects never encode to a native word. Pure bit
-- mapping: no catalog, no generator, no mutation.

local MonsErrors = require("libs.mons.src.errors")
local Validate = require("libs.assets.src.Validate")

---@class StatusCodec
local StatusCodec = {}

StatusCodec.VERSION = 1

-- Word layout at the pinned source version.
local POISON = 0x8
local BURN = 0x10
local FREEZE = 0x20
local PARALYSIS = 0x40
local TOXIC = 0x80
local KNOWN_BITS = 0xFFF

---@alias StatusCodec.Effect { key: string, version: integer, state: table<string, integer> }

local NATIVE_KEYS = {
  sleep = true,
  poison = true,
  burn = true,
  freeze = true,
  paralysis = true,
  toxic = true,
}

---@param code string
---@param message string
local function fail(code, message)
  MonsErrors.raise(code, message, {})
end

---@param value unknown
---@return boolean
local function isU32(value)
  return type(value) == "number" and value % 1 == 0 and value >= 0 and value <= 4294967295
end

---@param word integer
---@return integer
local function sleepTurns(word)
  return word % 8
end

---@param word integer
---@param bit integer
---@return boolean
local function hasBit(word, bit)
  return math.floor(word / bit) % 2 == 1
end

---@param word integer
---@return integer
local function toxicCounter(word)
  return math.floor(word / 256) % 16
end

-- Decodes a native status word into persistent condition records. Health
-- is the empty list. Every recognized word round-trips through project;
-- clashing majors, a counter without toxic, and unknown high bits fail.
---@param word integer
---@return StatusCodec.Effect[]
function StatusCodec.decode(word)
  if not isU32(word) then
    fail(MonsErrors.CODEC_INVALID, "status word must be an unsigned 32-bit integer")
  end
  assert(type(word) == "number", "status word validated above")
  if word > KNOWN_BITS then
    fail(MonsErrors.CODEC_INVALID, "status word carries unsupported bits")
  end
  local sleeping = sleepTurns(word) ~= 0
  local poisoned = hasBit(word, POISON)
  local burned = hasBit(word, BURN)
  local frozen = hasBit(word, FREEZE)
  local paralyzed = hasBit(word, PARALYSIS)
  local toxic = hasBit(word, TOXIC)
  local counter = toxicCounter(word)
  local majors = 0
  for _, present in ipairs({ sleeping, poisoned, burned, frozen, paralyzed, toxic }) do
    if present then
      majors = majors + 1
    end
  end
  if majors > 1 then
    fail(MonsErrors.CODEC_INVALID, "status word combines exclusive major statuses")
  end
  if counter ~= 0 and not toxic then
    fail(MonsErrors.CODEC_INVALID, "status counter requires toxic")
  end
  if sleeping then
    return { { key = "sleep", version = StatusCodec.VERSION, state = { turns = sleepTurns(word) } } }
  end
  if poisoned then
    return { { key = "poison", version = StatusCodec.VERSION, state = {} } }
  end
  if burned then
    return { { key = "burn", version = StatusCodec.VERSION, state = {} } }
  end
  if frozen then
    return { { key = "freeze", version = StatusCodec.VERSION, state = {} } }
  end
  if paralyzed then
    return { { key = "paralysis", version = StatusCodec.VERSION, state = {} } }
  end
  if toxic then
    return { { key = "toxic", version = StatusCodec.VERSION, state = { counter = counter } } }
  end
  return {}
end

---@param key string
---@param state table<string, unknown>
---@param code string
local function checkNativeState(key, state, code)
  if type(state) ~= "table" then
    fail(code, "condition " .. key .. " carries no typed state")
  end
  assert(type(state) == "table", "condition state validated above")
  if key == "sleep" then
    local turns = state.turns
    if type(turns) ~= "number" or turns % 1 ~= 0 or turns < 1 or turns > 7 then
      fail(code, "sleep duration must be an integer in 1..7")
    end
    for name in pairs(state) do
      if name ~= "turns" then
        fail(code, "sleep state carries unknown field " .. tostring(name))
      end
    end
    return
  end
  if key == "toxic" then
    local counter = state.counter
    if type(counter) ~= "number" or counter % 1 ~= 0 or counter < 0 or counter > 15 then
      fail(code, "toxic counter must be an integer in 0..15")
    end
    for name in pairs(state) do
      if name ~= "counter" then
        fail(code, "toxic state carries unknown field " .. tostring(name))
      end
    end
    return
  end
  for name in pairs(state) do
    fail(code, "condition " .. key .. " carries unknown state field " .. tostring(name))
  end
end

---@param effect table<string, unknown>
---@param code string
local function checkEffectShape(effect, code)
  if type(effect) ~= "table" then
    fail(code, "persistent condition must be a record")
  end
  assert(type(effect) == "table", "persistent condition validated above")
  local key = effect.key
  if type(key) ~= "string" or NATIVE_KEYS[key] == nil then
    fail(code, "unknown persistent condition " .. tostring(key))
  end
  assert(type(key) == "string", "persistent condition key validated above")
  if effect.version ~= StatusCodec.VERSION then
    fail(code, "condition " .. key .. " carries an unsupported state version")
  end
  checkNativeState(key, effect.state --[[@as table<string, unknown>]], code)
end

-- Validates one persistent condition record against the native vocabulary.
-- Custom mechanics and battle-transient state (substitute, confusion, stat
-- stages, and anything else outside the native persistent set) fail here
-- so they can never enter a canonical record.
---@param effect table<string, unknown>
function StatusCodec.checkEffect(effect)
  checkEffectShape(effect, MonsErrors.RECORD_INVALID)
end

---@param effects unknown
---@return StatusCodec.Effect[]
local function checkEffectList(effects)
  if not Validate.isArray(effects) then
    fail(MonsErrors.RECORD_INVALID, "persistent conditions must be an array")
  end
  assert(type(effects) == "table", "persistent conditions validated above")
  return effects --[[@as StatusCodec.Effect[] ]]
end

-- Projects persistent condition records back to the native status word.
-- Health (the empty list) projects to zero. Records outside the native
-- persistent vocabulary fail at the representability boundary instead of
-- borrowing a spare bit. Never mutates its input.
---@param effects StatusCodec.Effect[]
---@return integer
function StatusCodec.project(effects)
  local list = checkEffectList(effects)
  if #list == 0 then
    return 0
  end
  if #list > 1 then
    fail(MonsErrors.LEGALITY_INVALID, "combined persistent conditions have no single native word")
  end
  local effect = list[1]
  if type(effect) ~= "table" or type(effect.key) ~= "string" then
    fail(MonsErrors.RECORD_INVALID, "persistent condition must be a record")
  end
  assert(type(effect) == "table" and type(effect.key) == "string", "persistent condition validated above")
  if NATIVE_KEYS[effect.key] == nil then
    MonsErrors.raise(
      MonsErrors.LEGALITY_INVALID,
      "condition " .. effect.key .. " has no native status encoding",
      { identity = effect.key, field = "condition" }
    )
  end
  checkEffectShape(effect, MonsErrors.LEGALITY_INVALID)
  local state = assert(effect.state) --[[@as table<string, integer>]]
  if effect.key == "sleep" then
    return assert(state.turns) --[[@as integer]]
  end
  if effect.key == "poison" then
    return POISON
  end
  if effect.key == "burn" then
    return BURN
  end
  if effect.key == "freeze" then
    return FREEZE
  end
  if effect.key == "paralysis" then
    return PARALYSIS
  end
  assert(effect.key == "toxic", "persistent condition key validated above")
  return TOXIC + assert(state.counter) --[[@as integer]] * 256
end

return StatusCodec
