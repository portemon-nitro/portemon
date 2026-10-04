-- Semantic mon records. The authoritative runtime representation is the
-- readable g4-mon-v2 record; derivable values (level, nature, gender,
-- shininess, maximum stats) are never stored and unknown fields fail, so a
-- persisted record cannot contradict its own personality, identity, or
-- experience. Validation returns an owned canonical copy and never repairs
-- malformed data. Pure domain module: derivations come from the catalog and
-- the generation helpers.

local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")
local Validate = require("libs.assets.src.Validate")
local Experience = require("libs.mons.src.gen4.Experience")
local MonsErrors = require("libs.mons.src.errors")
local Moves = require("libs.mons.src.gen4.Moves")
local Mail = require("libs.mons.src.gen4.Mail")
local Personality = require("libs.mons.src.gen4.Personality")
local Stats = require("libs.mons.src.gen4.Stats")

---@class Mon
local Mon = {}

Mon.SCHEMA = "g4-mon-v2"
Mon.LEGACY_SCHEMA = "g4-mon-v1"
Mon.NICKNAME_CAPACITY = 11
Mon.OT_NAME_CAPACITY = 8
Mon.SHINY_LEAVES_MAX = 63

local TOP_FIELDS = {
  schema = true,
  species = true,
  form = true,
  personality = true,
  experience = true,
  friendship = true,
  ability = true,
  heldItem = true,
  markings = true,
  evs = true,
  contest = true,
  moves = true,
  ivs = true,
  isEgg = true,
  nickname = true,
  ribbons = true,
  fatefulEncounter = true,
  shinyLeaves = true,
  egg = true,
  met = true,
  origin = true,
  pokerus = true,
  mood = true,
  condition = true,
  capsule = true,
  mail = true,
}

local CONTEST_KEYS = { "cool", "beauty", "cute", "smart", "tough", "sheen" }
local MOVE_FIELDS = { move = true, pp = true, ppUps = true }
local RIBBON_FIELDS = { ds1 = true, gba = true, ds2 = true }
local EGG_FIELDS = { location = true, date = true }
local MET_FIELDS = { location = true, date = true, level = true, terrain = true }
local ORIGIN_FIELDS = {
  trainerId = true,
  trainerName = true,
  trainerGender = true,
  game = true,
  ball = true,
  language = true,
}
local CONDITION_FIELDS = { status = true, currentHp = true }
local CAPSULE_FIELDS = { id = true, seals = true }
local SEAL_FIELDS = { x = true, y = true, graphic = true }
local DATE_FIELDS = { year = true, month = true, day = true }

---@param record table<string, unknown>
---@param allowed table<string, boolean>
---@param what string
local function checkKeys(record, allowed, what)
  for key in pairs(record) do
    if allowed[key] == nil then
      MonsErrors.raise(MonsErrors.RECORD_INVALID, what .. " carries unknown field " .. tostring(key), {})
    end
  end
end

---@param value unknown
---@param allowed table<string, boolean>
---@param what string
local function checkRecord(value, allowed, what)
  if type(value) ~= "table" then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, what .. " must be a record", {})
  end
  checkKeys(value, allowed, what)
end

---@param value unknown
---@param lo integer
---@param hi integer
---@param what string
local function checkIntRange(value, lo, hi, what)
  if type(value) ~= "number" or value % 1 ~= 0 or value < lo or value > hi then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, what .. " must be an integer in " .. lo .. ".." .. hi, {})
  end
end

---@param value unknown
---@param what string
local function checkU8(value, what)
  checkIntRange(value, 0, 255, what)
end

---@param value unknown
---@param what string
local function checkU16(value, what)
  checkIntRange(value, 0, 65535, what)
end

---@param value unknown
---@param what string
local function checkU32(value, what)
  checkIntRange(value, 0, 4294967295, what)
end

---@param text unknown
---@param charmap table<string, integer>
---@param capacity integer
---@param what string
---@return integer
local function checkText(text, charmap, capacity, what)
  if type(text) ~= "string" then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, what .. " must be a string", {})
  end
  local glyphs = 0
  for glyph in Utf8Glyphs.iter(text) do
    if charmap[glyph] == nil then
      MonsErrors.raise(MonsErrors.RECORD_INVALID, what .. " carries an unencodable glyph", {})
    end
    glyphs = glyphs + 1
  end
  if glyphs + 1 > capacity then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, what .. " exceeds its glyph capacity", {})
  end
  return glyphs
end

---@param date unknown
---@param what string
local function checkDate(date, what)
  checkRecord(date, DATE_FIELDS, what)
  checkIntRange(date.year, 2000, 2255, what .. ".year")
  checkIntRange(date.month, 1, 12, what .. ".month")
  checkIntRange(date.day, 1, 31, what .. ".day")
end

---@param value unknown
---@return unknown
local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copyValue(item)
  end
  return out
end

-- Maximum power points for a move: base value plus one fifth per power-point
-- up, at most Moves.MAX_PP_UPS ups.
---@param definition table<string, unknown>
---@return integer
local function maxPp(definition)
  return definition.basePp + Moves.MAX_PP_UPS * math.floor(definition.basePp / 5)
end

---@param moves unknown
---@param catalog MonCatalog
local function checkMoves(moves, catalog)
  if not Validate.isArray(moves) or #moves > Moves.MAX_SLOTS then
    MonsErrors.raise(
      MonsErrors.RECORD_INVALID,
      "moves must be an array of at most " .. Moves.MAX_SLOTS .. " entries",
      {}
    )
  end
  local seen = {}
  for index, entry in ipairs(moves) do
    checkRecord(entry, MOVE_FIELDS, "move entry " .. index)
    local definition = catalog:move(entry.move)
    if seen[entry.move] then
      MonsErrors.raise(MonsErrors.RECORD_INVALID, "duplicate move " .. entry.move, { move = entry.move })
    end
    seen[entry.move] = true
    checkIntRange(entry.pp, 0, maxPp(definition), "move entry " .. index .. " power points")
    checkIntRange(entry.ppUps, 0, Moves.MAX_PP_UPS, "move entry " .. index .. " power-point ups")
  end
end

---@param origin unknown
---@param context table<string, unknown>
---@param catalog MonCatalog
local function checkOrigin(origin, context, catalog)
  checkRecord(origin, ORIGIN_FIELDS, "origin record")
  checkU32(origin.trainerId, "trainer id")
  checkText(origin.trainerName, context.charmap, Mon.OT_NAME_CAPACITY, "trainer name")
  checkIntRange(origin.trainerGender, 0, 1, "trainer gender")
  if context.games == nil or context.games[origin.game] == nil then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "unknown game " .. tostring(origin.game), {})
  end
  if type(origin.ball) ~= "string" then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "unknown ball " .. tostring(origin.ball), {})
  end
  if not catalog:item(origin.ball).isBall then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "unknown ball " .. tostring(origin.ball), {})
  end
  if context.languages == nil or context.languages[origin.language] == nil then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "unknown language " .. tostring(origin.language), {})
  end
end

---@param condition unknown
---@param maxHp integer
local function checkCondition(condition, maxHp)
  checkRecord(condition, CONDITION_FIELDS, "condition record")
  checkU32(condition.status, "status condition")
  checkIntRange(condition.currentHp, 0, maxHp, "current health")
end

---@param record table<string, unknown>
---@param context table<string, unknown>
---@return table<string, unknown>
function Mon.validate(record, context)
  assert(type(context) == "table", "mon validation requires a context")
  assert(context.catalog ~= nil, "mon validation requires a catalog")
  assert(type(context.charmap) == "table", "mon validation requires a charmap")
  checkRecord(record, TOP_FIELDS, "mon")
  local catalog = context.catalog

  if record.schema ~= Mon.SCHEMA then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "mon schema must be " .. Mon.SCHEMA, {})
  end

  local species = catalog:species(record.species)
  local form = catalog:form(record.species, record.form)
  checkU32(record.personality, "personality")
  checkU32(record.experience, "experience")
  local curve = catalog:growthCurve(species.growthCurve)
  if record.experience > curve[Stats.MAX_LEVEL] then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "experience exceeds the level-" .. Stats.MAX_LEVEL .. " entry", {})
  end
  local level = Experience.level(curve, record.experience)

  checkU8(record.friendship, "friendship")
  catalog:ability(record.ability)
  local permitted = false
  for _, key in ipairs(form.abilities) do
    if key == record.ability then
      permitted = true
    end
  end
  if not permitted then
    MonsErrors.raise(
      MonsErrors.RECORD_INVALID,
      "ability " .. record.ability .. " is not permitted by the selected form",
      { ability = record.ability }
    )
  end
  if type(record.heldItem) ~= "string" then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "unknown held item " .. tostring(record.heldItem), {})
  end
  catalog:item(record.heldItem)
  checkU8(record.markings, "markings")

  checkRecord(
    record.evs,
    { hp = true, attack = true, defense = true, speed = true, specialAttack = true, specialDefense = true },
    "effort values"
  )
  local evTotal = 0
  for _, key in ipairs(Stats.STAT_KEYS) do
    checkU8(record.evs[key], "effort value " .. key)
    evTotal = evTotal + record.evs[key]
  end
  if evTotal > Stats.EV_TOTAL_CAP then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "effort value total exceeds " .. Stats.EV_TOTAL_CAP, {})
  end

  checkRecord(
    record.contest,
    { cool = true, beauty = true, cute = true, smart = true, tough = true, sheen = true },
    "contest values"
  )
  for _, key in ipairs(CONTEST_KEYS) do
    checkU8(record.contest[key], "contest value " .. key)
  end

  checkMoves(record.moves, catalog)

  checkRecord(
    record.ivs,
    { hp = true, attack = true, defense = true, speed = true, specialAttack = true, specialDefense = true },
    "individual values"
  )
  for _, key in ipairs(Stats.STAT_KEYS) do
    checkIntRange(record.ivs[key], 0, 31, "individual value " .. key)
  end

  if type(record.isEgg) ~= "boolean" then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "egg flag must be a boolean", {})
  end
  if record.nickname ~= nil then
    checkText(record.nickname, context.charmap, Mon.NICKNAME_CAPACITY, "nickname")
  end

  checkRecord(record.ribbons, RIBBON_FIELDS, "ribbons")
  checkU32(record.ribbons.ds1, "ribbon field ds1")
  checkU32(record.ribbons.gba, "ribbon field gba")
  checkIntRange(record.ribbons.ds2, 0, 9007199254740991, "ribbon field ds2")

  if type(record.fatefulEncounter) ~= "boolean" then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "fateful-encounter flag must be a boolean", {})
  end
  checkIntRange(record.shinyLeaves, 0, Mon.SHINY_LEAVES_MAX, "shiny leaves")

  checkRecord(record.egg, EGG_FIELDS, "egg record")
  checkU16(record.egg.location, "egg location")
  if record.egg.date ~= nil then
    checkDate(record.egg.date, "egg date")
  end

  checkRecord(record.met, MET_FIELDS, "met record")
  checkU16(record.met.location, "met location")
  checkDate(record.met.date, "met date")
  checkIntRange(record.met.level, 1, Stats.MAX_LEVEL, "met level")
  checkU8(record.met.terrain, "met terrain")

  checkOrigin(record.origin, context, catalog)

  checkU8(record.pokerus, "pokerus")
  checkIntRange(record.mood, -128, 127, "mood")

  local nature = Personality.nature(record.personality)
  local derived = Stats.calculate(form.baseStats, record.ivs, record.evs, level, nature)
  local maxHp = derived.hp
  if record.species == "SHEDINJA" then
    maxHp = 1
  end
  checkCondition(record.condition, maxHp)

  checkRecord(record.capsule, CAPSULE_FIELDS, "capsule record")
  checkU8(record.capsule.id, "capsule id")
  if not Validate.isArray(record.capsule.seals) or #record.capsule.seals > 8 then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "capsule seals must be an array of at most eight entries", {})
  end
  for index, seal in ipairs(record.capsule.seals) do
    checkRecord(seal, SEAL_FIELDS, "capsule seal " .. index)
    checkU8(seal.x, "capsule seal x")
    checkU8(seal.y, "capsule seal y")
    checkU8(seal.graphic, "capsule seal graphic")
  end

  local canonical = copyValue(record)
  canonical.mail = Mail.validate(record.mail, context)
  return canonical
end

---@param record table<string, unknown>
---@return table<string, unknown>
function Mon.migrateV1(record)
  assert(type(record) == "table" and record.schema == Mon.LEGACY_SCHEMA, "Mon.migrateV1 requires a v1 record")
  local migrated = copyValue(record)
  migrated.schema = Mon.SCHEMA
  migrated.mail = Mail.validate(migrated.mail)
  return migrated
end

---@param record table<string, unknown>
---@param catalog MonCatalog
---@return string
function Mon.displayName(record, catalog)
  assert(type(record) == "table", "display name requires a mon record")
  assert(catalog ~= nil, "display name requires a catalog")
  if record.nickname ~= nil then
    return record.nickname
  end
  return catalog:species(record.species).name
end

return Mon
