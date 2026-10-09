-- Owns one copied raw mon candidate until the editor explicitly applies it.

local Errors = require("libs.errors.src.Errors")
local Mon = require("libs.mons.src.Mon")
local Moves = require("libs.mons.src.gen4.Moves")
local NativeLegality = require("libs.mons.src.gen4.NativeLegality")
local Experience = require("libs.mons.src.gen4.Experience")
local Personality = require("libs.mons.src.gen4.Personality")
local Stats = require("libs.mons.src.gen4.Stats")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")

---@class SaveEditorMonDraftOptions
---@field mode "edit"|"add"
---@field slot0 integer?
---@field basePartyRevision integer
---@field record table<string, unknown>
---@field context table<string, unknown>
---@field creationCandidate table<string, unknown>?

---@class SaveEditorMonProjection
---@field level integer?
---@field nature integer?
---@field gender string?
---@field shiny boolean?
---@field stats table<string, integer>?

---@class SaveEditorMonDraft
---@field private _mode "edit"|"add"
---@field private _slot0 integer?
---@field private _basePartyRevision integer
---@field private _record table<string, unknown>
---@field private _initial table<string, unknown>
---@field private _context table<string, unknown>
---@field private _creationCandidate table<string, unknown>?
---@field private _revision integer
---@field private _projectionCache { revision: integer, value: SaveEditorMonProjection }?
local SaveEditorMonDraft = {}
SaveEditorMonDraft.__index = SaveEditorMonDraft

local UINT8_MAX = 255
local UINT16_MAX = 65535
local UINT32_MAX = 4294967295
local MAX_MOVES = 4

local SCALAR_TYPES = {
  species = "string",
  form = "u8",
  nickname = "optional_string",
  personality = "u32",
  experience = "u32",
  friendship = "u8",
  ability = "string",
  heldItem = "string",
  currentHp = "u32",
}

local ORIGIN_FIELDS = {
  trainerId = "u32",
  trainerName = "string",
  trainerGender = "gender",
  game = "string",
  ball = "string",
  language = "string",
}

local MET_FIELDS = {
  location = "u16",
  level = "level",
  terrain = "u8",
  year = "year",
  month = "month",
  day = "day",
}

local STAT_FIELDS = {
  hp = true,
  attack = true,
  defense = true,
  speed = true,
  specialAttack = true,
  specialDefense = true,
}

---@param value unknown
---@return unknown
local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, item in pairs(value) do
    result[key] = copy(item)
  end
  return result
end

---@param left unknown
---@param right unknown
---@return boolean
local function equal(left, right)
  if type(left) ~= type(right) then
    return false
  end
  if type(left) ~= "table" then
    return left == right
  end
  for key, value in pairs(left) do
    if not equal(value, right[key]) then
      return false
    end
  end
  for key in pairs(right) do
    if left[key] == nil then
      return false
    end
  end
  return true
end

---@param value unknown
---@param kind string
---@return boolean
local function hasPrimitiveType(value, kind)
  if kind == "string" then
    return type(value) == "string"
  elseif kind == "optional_string" then
    return value == nil or type(value) == "string"
  elseif kind == "gender" then
    return type(value) == "number" and value % 1 == 0 and (value == 0 or value == 1)
  elseif kind == "level" then
    return type(value) == "number" and value % 1 == 0 and value >= 1 and value <= Stats.MAX_LEVEL
  elseif kind == "year" then
    return type(value) == "number" and value % 1 == 0 and value >= 2000 and value <= 2255
  elseif kind == "month" then
    return type(value) == "number" and value % 1 == 0 and value >= 1 and value <= 12
  elseif kind == "day" then
    return type(value) == "number" and value % 1 == 0 and value >= 1 and value <= 31
  end
  local maximum = kind == "u8" and UINT8_MAX or kind == "u16" and UINT16_MAX or UINT32_MAX
  return type(value) == "number" and value % 1 == 0 and value >= 0 and value <= maximum
end

---@param record table<string, unknown>
---@return table<string, unknown>
local function condition(record)
  return record.condition --[[@as table<string, unknown>]]
end

local projectRecord

-- Current derived maximum HP through the draft projection, or nil while the
-- candidate cannot project (another field still needs correction). Callers
-- skip health adjustment in that case instead of clamping from guessed stats.
---@param record table<string, unknown>
---@param context table<string, unknown>
---@return integer?
local function projectedMaxHp(record, context)
  local projection = projectRecord(record, context)
  if projection.stats == nil then
    return nil
  end
  return projection.stats.hp
end

---@param fieldId string
---@return string?
local function dateField(fieldId)
  if fieldId == "year" or fieldId == "month" or fieldId == "day" then
    return fieldId
  end
  return nil
end

---@param options SaveEditorMonDraftOptions
---@return SaveEditorMonDraft
function SaveEditorMonDraft.new(options)
  assert(type(options) == "table", "mon draft options are required")
  assert(options.mode == "edit" or options.mode == "add", "mon draft mode must be edit or add")
  assert(options.mode == "add" or (type(options.slot0) == "number" and options.slot0 % 1 == 0 and options.slot0 >= 0))
  assert(
    type(options.basePartyRevision) == "number"
      and options.basePartyRevision % 1 == 0
      and options.basePartyRevision >= 0,
    "base party revision must be a non-negative integer"
  )
  assert(type(options.record) == "table", "mon draft requires a record")
  assert(
    type(options.context) == "table" and type(options.context.catalog) == "table",
    "mon draft requires a mon context"
  )
  local record = copy(options.record) --[[@as table<string, unknown>]]
  return setmetatable({
    _mode = options.mode,
    _slot0 = options.slot0,
    _basePartyRevision = options.basePartyRevision,
    _record = record,
    _initial = copy(record),
    _context = options.context,
    _creationCandidate = copy(options.creationCandidate),
    _revision = 0,
    _projectionCache = nil,
  }, SaveEditorMonDraft)
end

---@return integer
function SaveEditorMonDraft:revision()
  return self._revision
end

function SaveEditorMonDraft:_changed()
  self._revision = self._revision + 1
  self._projectionCache = nil
end

---@return table<string, unknown>
function SaveEditorMonDraft:record()
  return copy(self._record) --[[@as table<string, unknown>]]
end

---@return "edit"|"add"
function SaveEditorMonDraft:mode()
  return self._mode
end

---@return integer?
function SaveEditorMonDraft:slot0()
  return self._slot0
end

---@return integer
function SaveEditorMonDraft:basePartyRevision()
  return self._basePartyRevision
end

---@return table<string, unknown>?
function SaveEditorMonDraft:creationCandidate()
  return copy(self._creationCandidate) --[[@as table<string, unknown>?]]
end

---@param record table<string, unknown>
---@param context table<string, unknown>
---@param oldMaxHp integer?
local function refreshHp(record, context, oldMaxHp)
  local values = record.condition
  if type(values) ~= "table" then
    return
  end
  local currentHp = values.currentHp
  if type(currentHp) ~= "number" or currentHp % 1 ~= 0 then
    return
  end
  local newMaxHp = projectedMaxHp(record, context)
  if oldMaxHp == nil or newMaxHp == nil then
    return
  end
  if currentHp < 0 or currentHp > oldMaxHp then
    return
  end
  values.currentHp = HgssMonService.adjustHpForMaxChange(oldMaxHp, newMaxHp, currentHp)
end

---@param context table<string, unknown>
---@param speciesKey string
---@return table<string, unknown>?
local function catalogSpecies(context, speciesKey)
  local ok, species = pcall(context.catalog.species, context.catalog, speciesKey)
  if not ok then
    if Errors.is(species) then
      return nil
    end
    error(species, 0)
  end
  return species
end

---@param form table<string, unknown>
---@param personality integer
---@return string?
local function fallbackAbility(form, personality)
  local abilities = form.abilities
  if type(abilities) ~= "table" or #abilities == 0 then
    return nil
  end
  if #abilities > 2 then
    return abilities[1]
  end
  return abilities[Personality.abilitySlot(#abilities, personality)]
end

---@param record table<string, unknown>
---@param form table<string, unknown>
---@return boolean
local function abilityPermitted(record, form)
  for _, key in ipairs(form.abilities) do
    if key == record.ability then
      return true
    end
  end
  return false
end

---@param fieldId string
---@param value unknown
---@return boolean
function SaveEditorMonDraft:setScalar(fieldId, value)
  if fieldId == "experience" then
    return self:setExperience(value)
  end
  local kind = SCALAR_TYPES[fieldId]
  if kind == nil or not hasPrimitiveType(value, kind) then
    return false
  end
  if fieldId == "currentHp" then
    if type(self._record.condition) ~= "table" then
      return false
    end
    local values = condition(self._record)
    if values[fieldId] ~= value then
      values[fieldId] = value
      self:_changed()
    end
  else
    if self._record[fieldId] ~= value then
      self._record[fieldId] = value
      self:_changed()
    end
  end
  return true
end

-- Level is represented solely by canonical cumulative EXP: the threshold of
-- the requested level on the current growth curve.
---@param level integer
---@return boolean
function SaveEditorMonDraft:setLevel(level)
  if type(level) ~= "number" or level % 1 ~= 0 or level < 1 or level > Stats.MAX_LEVEL then
    return false
  end
  local species = catalogSpecies(self._context, self._record.species)
  if species == nil then
    return false
  end
  local ok, curve = pcall(self._context.catalog.growthCurve, self._context.catalog, species.growthCurve)
  if not ok then
    if Errors.is(curve) then
      return false
    end
    error(curve, 0)
  end
  local threshold = Experience.expFor(curve, level)
  if self._record.experience == threshold then
    return true
  end
  local oldMaxHp = projectedMaxHp(self._record, self._context)
  self._record.experience = threshold
  refreshHp(self._record, self._context, oldMaxHp)
  self:_changed()
  return true
end

-- Direct EXP edits keep health coherent; beyond the level-100 entry the
-- candidate stays invalid until corrected.
---@param value unknown
---@return boolean
function SaveEditorMonDraft:setExperience(value)
  if not hasPrimitiveType(value, "u32") then
    return false
  end
  local species = catalogSpecies(self._context, self._record.species)
  if species == nil then
    return false
  end
  if self._record.experience == value then
    return true
  end
  local oldMaxHp = projectedMaxHp(self._record, self._context)
  self._record.experience = value
  refreshHp(self._record, self._context, oldMaxHp)
  self:_changed()
  return true
end

-- Species edits preserve exact numeric EXP and repair form/ability validity
-- for the new species while keeping health coherent.
---@param speciesKey string
---@return boolean
function SaveEditorMonDraft:setSpecies(speciesKey)
  if type(speciesKey) ~= "string" then
    return false
  end
  local species = catalogSpecies(self._context, speciesKey)
  if species == nil then
    return false
  end
  local formIds = {}
  for formId in pairs(species.forms) do
    formIds[#formIds + 1] = formId
  end
  if #formIds == 0 then
    return false
  end
  table.sort(formIds)
  local record = self._record
  local old = { species = record.species, form = record.form, ability = record.ability }
  local oldMaxHp = projectedMaxHp(record, self._context)
  record.species = speciesKey
  local formKept = false
  for _, formId in ipairs(formIds) do
    if formId == record.form then
      formKept = true
      break
    end
  end
  if not formKept then
    record.form = formIds[1]
  end
  local formOk, form = pcall(self._context.catalog.form, self._context.catalog, speciesKey, record.form)
  if not formOk then
    if Errors.is(form) then
      record.species, record.form, record.ability = old.species, old.form, old.ability
      return false
    end
    error(form, 0)
  end
  if not abilityPermitted(record, form) then
    local repaired = fallbackAbility(form, record.personality)
    if repaired == nil then
      record.species, record.form, record.ability = old.species, old.form, old.ability
      return false
    end
    record.ability = repaired
  end
  if record.species == old.species and record.form == old.form and record.ability == old.ability then
    return true
  end
  refreshHp(record, self._context, oldMaxHp)
  self:_changed()
  return true
end

---@param formId integer
---@return boolean
function SaveEditorMonDraft:setForm(formId)
  if type(formId) ~= "number" or formId % 1 ~= 0 then
    return false
  end
  local formOk, form = pcall(self._context.catalog.form, self._context.catalog, self._record.species, formId)
  if not formOk then
    if Errors.is(form) then
      return false
    end
    error(form, 0)
  end
  if self._record.form == formId and abilityPermitted(self._record, form) then
    return true
  end
  local oldForm, oldAbility = self._record.form, self._record.ability
  local oldMaxHp = projectedMaxHp(self._record, self._context)
  self._record.form = formId
  if not abilityPermitted(self._record, form) then
    local repaired = fallbackAbility(form, self._record.personality)
    if repaired == nil then
      self._record.form = oldForm
      self._record.ability = oldAbility
      return false
    end
    self._record.ability = repaired
  end
  refreshHp(self._record, self._context, oldMaxHp)
  self:_changed()
  return true
end

---@param stat string
---@param value unknown
---@return boolean
function SaveEditorMonDraft:setIV(stat, value)
  if not STAT_FIELDS[stat] or not hasPrimitiveType(value, "u8") or value > 31 then
    return false
  end
  if self._record.ivs[stat] == value then
    return true
  end
  local oldMaxHp
  if stat == "hp" then
    oldMaxHp = projectedMaxHp(self._record, self._context)
  end
  self._record.ivs[stat] = value
  if stat == "hp" then
    refreshHp(self._record, self._context, oldMaxHp)
  end
  self:_changed()
  return true
end

---@param stat string
---@param value unknown
---@return boolean
function SaveEditorMonDraft:setEV(stat, value)
  if not STAT_FIELDS[stat] or not hasPrimitiveType(value, "u8") then
    return false
  end
  if self._record.evs[stat] == value then
    return true
  end
  local total = value
  for key, current in pairs(self._record.evs) do
    if key ~= stat then
      total = total + current
    end
  end
  if total > Stats.EV_TOTAL_CAP then
    return false
  end
  local oldMaxHp
  if stat == "hp" then
    oldMaxHp = projectedMaxHp(self._record, self._context)
  end
  self._record.evs[stat] = value
  if stat == "hp" then
    refreshHp(self._record, self._context, oldMaxHp)
  end
  self:_changed()
  return true
end

-- Move components stay mutually coherent: replacing a move resets its
-- allowance, PP never exceeds the current allowance, and lowering PP Ups
-- clamps current PP down to the new maximum.
---@param slot0 integer
---@param component string
---@param value unknown
---@return boolean
function SaveEditorMonDraft:setMove(slot0, component, value)
  if type(slot0) ~= "number" or slot0 % 1 ~= 0 or slot0 < 0 or slot0 >= #self._record.moves then
    return false
  end
  local move = self._record.moves[slot0 + 1]
  if component == "move" then
    if type(value) ~= "string" then
      return false
    end
    local ok, definition = pcall(self._context.catalog.move, self._context.catalog, value)
    if not ok then
      if Errors.is(definition) then
        return false
      end
      error(definition, 0)
    end
    if move.move == value then
      return true
    end
    move.move, move.ppUps, move.pp = value, 0, definition.basePp
    self:_changed()
    return true
  end
  local ok, definition = pcall(self._context.catalog.move, self._context.catalog, move.move)
  if not ok then
    if Errors.is(definition) then
      return false
    end
    error(definition, 0)
  end
  if component == "pp" then
    if not hasPrimitiveType(value, "u8") then
      return false
    end
    if value > Moves.maxPp(definition.basePp, move.ppUps) then
      return false
    end
    if move.pp == value then
      return true
    end
    move.pp = value
    self:_changed()
    return true
  end
  if component == "ppUps" then
    if not hasPrimitiveType(value, "u8") or value > 3 then
      return false
    end
    if move.ppUps == value then
      return true
    end
    move.ppUps = value
    move.pp = math.min(move.pp, Moves.maxPp(definition.basePp, value))
    self:_changed()
    return true
  end
  return false
end

---@param moveKey string
---@return boolean
function SaveEditorMonDraft:addMove(moveKey)
  if type(moveKey) ~= "string" or #self._record.moves >= MAX_MOVES then
    return false
  end
  local ok, definition = pcall(self._context.catalog.move, self._context.catalog, moveKey)
  if not ok then
    if Errors.is(definition) then
      return false
    end
    error(definition, 0)
  end
  self._record.moves[#self._record.moves + 1] = { move = moveKey, pp = definition.basePp, ppUps = 0 }
  self:_changed()
  return true
end

---@param fieldId string
---@param value unknown
---@return boolean
function SaveEditorMonDraft:setOrigin(fieldId, value)
  local kind = ORIGIN_FIELDS[fieldId]
  if kind == nil or not hasPrimitiveType(value, kind) then
    return false
  end
  if self._record.origin[fieldId] ~= value then
    self._record.origin[fieldId] = value
    self:_changed()
  end
  return true
end

---@param fieldId string
---@param value unknown
---@return boolean
function SaveEditorMonDraft:setMet(fieldId, value)
  local kind = MET_FIELDS[fieldId]
  if kind == nil or not hasPrimitiveType(value, kind) then
    return false
  end
  local dateKey = dateField(fieldId)
  if dateKey then
    if self._record.met.date[dateKey] ~= value then
      self._record.met.date[dateKey] = value
      self:_changed()
    end
  else
    if self._record.met[fieldId] ~= value then
      self._record.met[fieldId] = value
      self:_changed()
    end
  end
  return true
end

---@param record table<string, unknown>
---@param context table<string, unknown>
---@return SaveEditorMonProjection
projectRecord = function(record, context)
  local projection = {}
  local species, form
  if type(record.species) == "string" then
    local ok, result = pcall(context.catalog.species, context.catalog, record.species)
    if ok then
      species = result
    elseif not Errors.is(result) then
      error(result, 0)
    end
  end
  if species ~= nil and type(record.form) == "number" and record.form % 1 == 0 then
    local ok, result = pcall(context.catalog.form, context.catalog, record.species, record.form)
    if ok then
      form = result
    elseif not Errors.is(result) then
      error(result, 0)
    end
  end

  local curve
  if species ~= nil then
    local ok, result = pcall(context.catalog.growthCurve, context.catalog, species.growthCurve)
    if ok then
      curve = result
    elseif not Errors.is(result) then
      error(result, 0)
    end
  end
  if curve ~= nil and hasPrimitiveType(record.experience, "u32") and record.experience <= curve[Stats.MAX_LEVEL] then
    projection.level = Experience.level(curve, record.experience)
  end

  local personalityValid = hasPrimitiveType(record.personality, "u32")
  if personalityValid then
    projection.nature = Personality.nature(record.personality)
    if species ~= nil then
      projection.gender = Personality.gender(species.genderRatio, record.personality)
    end
    local origin = record.origin
    if type(origin) == "table" and hasPrimitiveType(origin.trainerId, "u32") then
      projection.shiny = Personality.shiny(origin.trainerId, record.personality)
    end
  end

  local ivs, evs = record.ivs, record.evs
  local validStats = form ~= nil
    and projection.level ~= nil
    and projection.nature ~= nil
    and type(ivs) == "table"
    and type(evs) == "table"
  if validStats then
    local evTotal = 0
    for _, stat in ipairs(Stats.STAT_KEYS) do
      if not hasPrimitiveType(ivs[stat], "u8") or ivs[stat] > 31 or not hasPrimitiveType(evs[stat], "u8") then
        validStats = false
        break
      end
      evTotal = evTotal + evs[stat]
    end
    if evTotal > Stats.EV_TOTAL_CAP then
      validStats = false
    end
  end
  if validStats then
    projection.stats = Stats.calculate(form.baseStats, ivs, evs, projection.level, projection.nature)
    if record.species == "SHEDINJA" then
      projection.stats.hp = 1
    end
  end
  return projection
end

---@param record table<string, unknown>
---@param context table<string, unknown>
---@return SaveEditorMonProjection
function SaveEditorMonDraft.projectRecord(record, context)
  assert(type(record) == "table", "raw mon record is required")
  assert(type(context) == "table" and type(context.catalog) == "table", "mon projection context is required")
  return projectRecord(record, context)
end

---@return SaveEditorMonProjection
function SaveEditorMonDraft:projection()
  if self._projectionCache and self._projectionCache.revision == self._revision then
    return copy(self._projectionCache.value) --[[@as SaveEditorMonProjection]]
  end
  local projection = projectRecord(self._record, self._context)
  self._projectionCache = {
    revision = self._revision,
    value = copy(projection) --[[@as SaveEditorMonProjection]],
  }
  return projection
end

---@return table<string, unknown>?, Errors.Error?
function SaveEditorMonDraft:validate()
  local ok, canonical = pcall(Mon.validate, self._record, self._context)
  if not ok then
    if Errors.is(canonical) then
      return nil, canonical
    end
    error(canonical, 0)
  end
  local legal, legalityError = pcall(NativeLegality.project, canonical, self._context)
  if not legal then
    if Errors.is(legalityError) then
      return nil, legalityError
    end
    error(legalityError, 0)
  end
  return canonical, nil
end

---@return boolean
function SaveEditorMonDraft:isDirty()
  return not equal(self._record, self._initial)
end

return SaveEditorMonDraft
