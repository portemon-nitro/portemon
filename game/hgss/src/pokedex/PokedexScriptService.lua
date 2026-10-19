-- Semantic dex count, rating, grant, and alphabet adapter over the single
-- authoritative dex knowledge owner. The script runtime calls exactly one
-- named method per operation; the adapter owns no persistent state and
-- retains no flag, count, or history cache. World and profile
-- compatibility writes happen only through the completed semantic grants,
-- after the owner already published. Game-side leaf: never imported by
-- libs/script.

local Errors = require("libs.errors.src.Errors")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local ScriptErrors = require("libs.script.src.errors")

---@class PokedexScriptService
---@field private _dex table<string, unknown> borrowed authoritative dex knowledge
---@field private _catalog table<string, unknown> borrowed generated dex catalog behind counts and evaluation
---@field private _profile table<string, unknown> borrowed player profile behind gender and national compatibility
---@field private _eventState table<string, unknown> borrowed field event state behind story compatibility
local PokedexScriptService = {}
PokedexScriptService.__index = PokedexScriptService

local KINDS = { seen = true, caught = true }

---@param value unknown
---@param what string
---@return string
local function checkMode(value, what)
  if value ~= "johto" and value ~= "national" then
    Errors.raise(ScriptErrors.SCRIPT_SCHEMA_INVALID, what .. " reads johto or national mode", { mode = value })
  end
  assert(value == "johto" or value == "national", "dex mode validated")
  return value --[[@as string]]
end

---@param args table<string, unknown>
---@return PokedexScriptService
function PokedexScriptService.new(args)
  assert(type(args) == "table", "dex script service requires its owners")
  local dex = assert(args.dex, "dex script service requires dex knowledge")
  local catalog = assert(args.catalog, "dex script service requires the generated dex catalog")
  local profile = assert(args.profile, "dex script service requires the player profile")
  local eventState = assert(args.eventState, "dex script service requires the field event state")
  assert(type(dex) == "table", "dex script service borrows dex knowledge")
  assert(type(catalog) == "table", "dex script service borrows the generated dex catalog")
  assert(type(profile) == "table", "dex script service borrows the player profile")
  assert(type(eventState) == "table", "dex script service borrows the field event state")
  assert(type(dex.countSeen) == "function", "dex script service needs the seen count")
  assert(type(dex.countCaught) == "function", "dex script service needs the caught count")
  assert(type(dex.prepareChanges) == "function", "dex script service needs staged grants")
  assert(type(eventState.setFlag) == "function", "dex script service needs the story flag write")
  return setmetatable({
    _dex = dex,
    _catalog = catalog,
    _profile = profile,
    _eventState = eventState,
  }, PokedexScriptService)
end

-- Counts explicit display members only, never species outside the
-- generated order sets. Consumes no generator draws.
---@param mode string "johto" or "national"
---@param kind string "seen" or "caught"
---@return integer
function PokedexScriptService:count(mode, kind)
  checkMode(mode, "dex counts")
  if KINDS[kind] ~= true then
    Errors.raise(ScriptErrors.SCRIPT_SCHEMA_INVALID, "dex counts read seen or caught kind", { kind = kind })
  end
  if kind == "seen" then
    return self._dex:countSeen(mode)
  end
  return self._dex:countCaught(mode)
end

-- Source evaluation: counts caught members of the explicit completion
-- set, checks completion independently through the owner, and selects
-- the generated band or gendered complete message with its music. An
-- explicitly authored custom set with a larger incomplete count clamps
-- to the final incomplete band.
---@param mode string "johto" or "national"
---@return integer messageId, integer musicId
function PokedexScriptService:evaluate(mode)
  checkMode(mode, "dex evaluation")
  local catalog = self._catalog
  local sets = assert(catalog.completionSets, "the generated catalog carries its completion sets")
  local required = assert(sets[mode], "the generated catalog carries the evaluated completion set")
  local caught = 0
  for _, key in ipairs(required) do
    if self._dex:isCaught(key) then
      caught = caught + 1
    end
  end
  local evaluation = assert(catalog.evaluation, "the generated catalog carries its evaluation policy")
  local policy = assert(evaluation[mode], "the generated catalog carries the evaluated rating bands")
  local complete = mode == "johto" and self._dex:isJohtoDexComplete() or self._dex:isNationalDexComplete()
  if complete then
    local done = assert(policy.complete, "the evaluation policy carries its complete messages")
    if self._profile.gender == 1 then
      return done.femaleMessageId, policy.completeMusicId
    end
    return done.maleMessageId, policy.completeMusicId
  end
  local bands = assert(policy.bands, "the evaluation policy carries its incomplete bands")
  local selected = bands[#bands]
  for _, band in ipairs(bands) do
    if caught <= band.max then
      selected = band
      break
    end
  end
  assert(selected ~= nil, "the evaluation policy carries at least one band")
  return selected.messageId, policy.incompleteMusicId
end

---@return boolean
function PokedexScriptService:hasPokedex()
  return self._dex:hasPokedex() == true
end

-- Semantic dex grant: publishes the owner before writing story flag 107
-- last, so synchronous flag listeners observe the completed grant. A
-- repeated grant repairs the story flag without rewriting history, and
-- a generic story clear never revokes the owner.
function PokedexScriptService:givePokedex()
  local prep = self._dex:prepareChanges({ flags = { dexEnabled = true } })
  assert(prep.isCurrent(), "dex changed during the pokedex grant")
  prep.publish()
  local flags = FieldScriptSymbols.flagsByName
  self._eventState:setFlag(assert(flags.FLAG_GOT_POKEDEX, "the dex grant writes its story flag"))
end

---@param mode string "johto" or "national"
---@return boolean
function PokedexScriptService:isComplete(mode)
  checkMode(mode, "dex completion")
  if mode == "johto" then
    return self._dex:isJohtoDexComplete() == true
  end
  return self._dex:isNationalDexComplete() == true
end

-- Enables only the form-detection owner flag.
function PokedexScriptService:enableFormDetection()
  local prep = self._dex:prepareChanges({ flags = { canDetectForms = true } })
  assert(prep.isCurrent(), "dex changed during form-detection enable")
  prep.publish()
end

-- National dex flag action: enable publishes the owner flag and
-- synchronizes the profile compatibility value with no yield between
-- the stores, reporting the source zero result; check reads the owner
-- as the source boolean convention.
---@param action string "enable" or "check"
---@return integer
function PokedexScriptService:nationalAction(action)
  if action == "enable" then
    local prep = self._dex:prepareChanges({ flags = { nationalDex = true } })
    assert(prep.isCurrent(), "dex changed during national enable")
    prep.publish()
    self._profile.nationalDex = true
    return 0
  end
  if action == "check" then
    return self._dex:hasNationalDex() and 1 or 0
  end
  Errors.raise(ScriptErrors.SCRIPT_SCHEMA_INVALID, "national dex action is enable or check", { action = action })
  error("unreachable", 0)
end

-- Counts caught alphabet letters only: variants 26 and 27 never
-- substitute for missing ordinary letters.
---@return integer
function PokedexScriptService:caughtUnownCount()
  local count = 0
  for _, id in ipairs(self._dex:caughtVariants("UNOWN")) do
    if id >= 0 and id <= 25 then
      count = count + 1
    end
  end
  return count
end

---@return boolean true when all twenty-six caught letters are present
function PokedexScriptService:caughtAllUnownLetters()
  local present = {}
  for _, id in ipairs(self._dex:caughtVariants("UNOWN")) do
    present[id] = true
  end
  for id = 0, 25 do
    if present[id] ~= true then
      return false
    end
  end
  return true
end

return PokedexScriptService
