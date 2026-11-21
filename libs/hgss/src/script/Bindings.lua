-- Runtime interaction bindings derive ordinary map script identities from
-- the generated map's script bank and raw source script id. The raw id is
-- one-based; the shared project formatter receives the zero-based index.
-- A std-script sentinel (one that addresses a global scr_seq member
-- unrelated to the map's own bank) arrives already canonicalized to its
-- public id by the field-map producer, so a string intent script id is
-- passed through rather than re-derived.
--
-- A raw id at or above the lowest standard-script group threshold
-- (include/constants/std_script.h::_std_misc, 2000) is such a sentinel and is
-- never a map-bank index: the source picks a global scr_seq bank for it by
-- threshold (src/script_manager.c::sScriptBankMapping) and only ids below the
-- first threshold address the current map's own bank. This module therefore
-- never derives a map-bank identity from a sentinel; whether the composition
-- carries the global script is the interaction client's answer.

local Errors = require("libs.errors.src.Errors")
local ScriptIdentity = require("libs.assets.src.ScriptIdentity")

---@class Bindings
---@field mons HgssMonService|nil the live HGSS mon service, injected by game composition
local Bindings = {}
Bindings.__index = Bindings
Bindings.CANONICAL_INERT_SCRIPT = "runtime.inert_interaction"

-- The lowest standard-script group threshold. Every group in
-- include/constants/std_script.h sits at or above it, so a raw interaction
-- script id at or above this value addresses a global standard script.
Bindings.STANDARD_SCRIPT_MINIMUM = 2000

local INVALID_INTENT = "SCRIPT_BINDING_INVALID_INTENT"

---@param opts { mons: HgssMonService|nil }?
---@return Bindings
function Bindings.new(opts)
  opts = opts or {}
  return setmetatable({ mons = opts.mons }, Bindings)
end

---@param intent table<string, unknown> InteractionIntent
---@return string|nil
local function scriptIdFor(intent)
  local rawScriptId = intent.scriptId
  if type(rawScriptId) == "string" then
    if rawScriptId == "" then
      Errors.raise(
        INVALID_INTENT,
        "interactable intent has an empty already-resolved script id",
        { mapId = intent.mapId }
      )
    end
    return rawScriptId
  end
  if rawScriptId == 0 then
    return Bindings.CANONICAL_INERT_SCRIPT
  end
  if type(rawScriptId) ~= "number" or math.floor(rawScriptId) ~= rawScriptId or rawScriptId < 0 then
    Errors.raise(
      INVALID_INTENT,
      "interaction raw script id must be a non-negative integer",
      { mapId = intent.mapId, scriptBankId = intent.scriptBankId, rawScriptId = rawScriptId }
    )
  end
  if rawScriptId >= Bindings.STANDARD_SCRIPT_MINIMUM then
    -- A standard-script sentinel has no map-bank identity.
    return nil
  end
  local scriptBankId = intent.scriptBankId
  if type(scriptBankId) ~= "number" or math.floor(scriptBankId) ~= scriptBankId or scriptBankId < 0 then
    Errors.raise(
      INVALID_INTENT,
      "interactable intent has no valid script bank id",
      { mapId = intent.mapId, scriptBankId = scriptBankId, rawScriptId = rawScriptId }
    )
  end
  return ScriptIdentity.formatVanilla(scriptBankId, rawScriptId - 1)
end

-- Build the trigger descriptor for an object intent.
---@param intent table<string, unknown> InteractionIntent
---@param scriptId string
---@param playerFacing string
---@return table<string, unknown>
function Bindings.objectTrigger(intent, scriptId, playerFacing)
  assert(intent.kind == "object", "object trigger requires an object intent")
  assert(intent.object ~= nil, "object intent identity required")
  return {
    kind = "object",
    mapId = intent.mapId,
    objectId = intent.object.actorId,
    scriptId = scriptId,
    selfActor = intent.object.actorId,
    playerFacing = playerFacing,
    backgroundId = nil,
    sourceFieldX = intent.sourceFieldX,
    sourceFieldZ = intent.sourceFieldZ,
    targetFieldX = intent.targetFieldX,
    targetFieldZ = intent.targetFieldZ,
  }
end

-- Build the trigger descriptor for a background intent.
---@param intent table<string, unknown> InteractionIntent
---@param scriptId string
---@param playerFacing string
---@return table<string, unknown>
function Bindings.backgroundTrigger(intent, scriptId, playerFacing)
  assert(intent.kind == "background", "background trigger requires a background intent")
  assert(intent.background ~= nil, "background intent identity required")
  return {
    kind = "background",
    mapId = intent.mapId,
    objectId = nil,
    scriptId = scriptId,
    selfActor = nil,
    playerFacing = playerFacing,
    backgroundId = intent.background.eventIndex,
    sourceFieldX = intent.sourceFieldX,
    sourceFieldZ = intent.sourceFieldZ,
    targetFieldX = intent.targetFieldX,
    targetFieldZ = intent.targetFieldZ,
  }
end

---@param intent table<string, unknown> InteractionIntent
---@param scriptId string
---@param playerFacing string
---@return table<string, unknown>
function Bindings.coordinateTrigger(intent, scriptId, playerFacing)
  assert(intent.kind == "coordinate", "coordinate trigger requires a coordinate intent")
  return {
    kind = "coordinate",
    mapId = intent.mapId,
    coordinateId = intent.coordinateId,
    scriptId = scriptId,
    playerFacing = playerFacing,
    sourceFieldX = intent.sourceFieldX,
    sourceFieldZ = intent.sourceFieldZ,
    targetFieldX = intent.targetFieldX,
    targetFieldZ = intent.targetFieldZ,
    objectId = nil,
    selfActor = nil,
    backgroundId = nil,
  }
end

-- Whether one intent addresses a global standard script rather than the current
-- map's own script bank. Such an intent has no map-bank identity.
---@param intent table<string, unknown> InteractionIntent
---@return boolean
function Bindings:isStandardScriptIntent(intent)
  local rawScriptId = intent.scriptId
  return type(rawScriptId) == "number" and rawScriptId >= Bindings.STANDARD_SCRIPT_MINIMUM
end

-- Resolve one interaction intent into a trigger descriptor plus its generated
-- script id. Raw source script id zero is the noninteractive marker.
---@param intent table<string, unknown> InteractionIntent
---@param playerFacing string
---@return table<string, unknown>|nil { trigger, scriptId }
function Bindings:resolveIntent(intent, playerFacing)
  local kind = intent.kind
  if kind ~= "object" and kind ~= "background" and kind ~= "coordinate" then
    return nil
  end
  local scriptId = scriptIdFor(intent)
  if scriptId == nil then
    return nil
  end
  local trigger = kind == "object" and Bindings.objectTrigger(intent, scriptId, playerFacing)
    or kind == "background" and Bindings.backgroundTrigger(intent, scriptId, playerFacing)
    or Bindings.coordinateTrigger(intent, scriptId, playerFacing)
  return { trigger = trigger, scriptId = scriptId }
end

return Bindings
