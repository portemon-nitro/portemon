-- The summary-screen value projection: one fresh immutable facts record
-- per build over the live mon service. Every displayed value is read
-- from the current mon record, the service derivation, or the shared
-- catalogs; the projection copies nothing it cannot name and mutates
-- nothing it borrows. Shiny leaves stay a six-bit observation: bits 0..4
-- select five independent badges, bit 5 selects the crown and suppresses
-- every leaf. Pure module: no love, no I/O.

local Mon = require("libs.mons.src.Mon")
local Experience = require("libs.mons.src.gen4.Experience")
local MonCache = require("libs.assets.src.MonCache")
local PartyScreenTheme = require("libs.hgss.src.ui.PartyScreenTheme")
local Personality = require("libs.mons.src.gen4.Personality")

---@class SummaryModel
local SummaryModel = {}

SummaryModel.WRAP_WIDTH_CHARS = 38
SummaryModel.LEAF_COUNT = 5
SummaryModel.CROWN_BIT = 32

-- Splits text into word-aware lines of at most widthChars characters: a
-- conservative layout hint for scroll decisions. Measured pagination owns
-- the drawn truth; this estimate never shortens or invents content.
---@param text string
---@param widthChars integer
---@return string[]
function SummaryModel.wrapLines(text, widthChars)
  assert(type(text) == "string", "wrapping needs the source text")
  assert(
    type(widthChars) == "number" and widthChars % 1 == 0 and widthChars >= 1,
    "wrapping needs a positive character width"
  )
  local lines = {}
  local line = ""
  for word in text:gmatch("%S+") do
    local candidate = line == "" and word or (line .. " " .. word)
    if #candidate <= widthChars then
      line = candidate
    else
      if line ~= "" then
        lines[#lines + 1] = line
      end
      line = word
    end
  end
  if line ~= "" then
    lines[#lines + 1] = line
  end
  if #lines == 0 then
    lines[1] = ""
  end
  return lines
end

---@param mask integer
---@return { leaves: boolean[], crown: boolean }
local function projectLeaves(mask)
  assert(
    type(mask) == "number" and mask % 1 == 0 and mask >= 0 and mask < 64,
    "shiny leaves stay a six-bit observation"
  )
  local crown = math.floor(mask / SummaryModel.CROWN_BIT) % 2 == 1
  local leaves = {}
  for index = 0, SummaryModel.LEAF_COUNT - 1 do
    leaves[index + 1] = not crown and math.floor(mask / (2 ^ index)) % 2 == 1
  end
  return { leaves = leaves, crown = crown }
end

---@param basePp integer
---@param ppUps integer
---@return integer
local function maxPp(basePp, ppUps)
  return basePp + math.floor(basePp * ppUps / 5)
end

---@param catalog MonCatalog
---@param entry table<string, unknown>
---@return table<string, unknown>
local function projectMove(catalog, entry)
  local key = assert(entry.move, "stored move entries carry their key")
  assert(type(key) == "string", "stored move keys are strings")
  local definition = catalog:move(key)
  local basePp = assert(definition.basePp, "catalog moves carry base power points")
  assert(type(basePp) == "number", "base power points are numeric")
  local pp = assert(entry.pp, "stored move entries carry current power points")
  assert(type(pp) == "number", "current power points are numeric")
  local ppUps = assert(entry.ppUps, "stored move entries carry power-point ups")
  assert(type(ppUps) == "number", "power-point ups are numeric")
  return {
    key = key,
    name = assert(definition.name, "catalog moves carry a display name"),
    moveType = assert(definition.moveType, "catalog moves carry a type"),
    category = assert(definition.category, "catalog moves carry a category"),
    pp = pp,
    maxPp = maxPp(basePp, ppUps),
    power = assert(definition.power, "catalog moves carry power"),
    accuracy = assert(definition.accuracy, "catalog moves carry accuracy"),
    description = assert(definition.description, "catalog moves carry a description"),
  }
end

---@param catalog MonCatalog
---@param moves table[]
---@return table[]
local function projectMoves(catalog, moves)
  local projected = {}
  for _, entry in ipairs(moves) do
    projected[#projected + 1] = projectMove(catalog, entry)
  end
  return projected
end

---@param service HgssMonService the live mon service
---@param slot0 integer
---@return table<string, unknown>?
local function eggFacts(service, slot0)
  local mon = service:partyMon(slot0)
  if not mon.isEgg then
    return nil
  end
  local egg = assert(mon.egg, "eggs carry their origin record")
  local met = assert(mon.met, "eggs carry their met record")
  return {
    location = assert(egg.location, "eggs carry their location"),
    date = egg.date,
    metLocation = assert(met.location, "eggs carry their met location"),
    metLevel = assert(met.level, "eggs carry their met level"),
  }
end

-- Builds one immutable facts record for the mon in zero-based slot0:
-- header identity, derived battle facts, catalog text, whole move
-- entries, and the six-bit leaf observation. Eggs suppress battle,
-- experience, and move detail. Reading never writes the domain.
---@param service HgssMonService the live mon service (partyCount/partyRevision/partyMon/derive/catalog)
---@param slot0 integer
---@return table<string, unknown>
function SummaryModel.build(service, slot0)
  assert(type(service) == "table", "the summary needs the live mon service")
  assert(type(service.partyCount) == "function", "the summary needs the party count")
  assert(type(service.partyRevision) == "function", "the summary needs the party revision")
  assert(type(service.partyMon) == "function", "the summary needs party reads")
  assert(type(service.derive) == "function", "the summary needs the derived-stat projection")
  assert(type(service.catalog) == "function", "the summary needs the mon catalog")
  assert(
    type(slot0) == "number" and slot0 % 1 == 0 and slot0 >= 0 and slot0 < service:partyCount(),
    "the summary needs an occupied party slot"
  )
  local catalog = service:catalog()
  local mon = service:partyMon(slot0)
  local mask = assert(mon.shinyLeaves, "stored mons carry their leaf mask")
  assert(type(mask) == "number", "leaf masks are numeric")
  local species = catalog:species(assert(mon.species, "stored mons carry their species"))
  local form = catalog:form(mon.species, assert(mon.form, "stored mons carry their form"))
  local origin = assert(mon.origin, "stored mons carry their origin")
  local trainerId = assert(origin.trainerId, "origins carry the trainer identity")
  local personality = assert(mon.personality, "stored mons carry their personality")
  local gender = Personality.gender(assert(species.genderRatio, "catalog species carry a gender ratio"), personality)
  local shiny = Personality.shiny(trainerId, personality)
  local abilityKey = assert(mon.ability, "stored mons carry their ability")
  assert(type(abilityKey) == "string", "ability keys are strings")
  local ability = catalog:ability(abilityKey)
  local heldItem = assert(mon.heldItem, "stored mons carry their held item")
  assert(type(heldItem) == "string", "held item keys are strings")
  local heldItemName = nil
  if heldItem ~= "NONE" then
    heldItemName = assert(catalog:item(heldItem).name, "held items carry a display name")
  end
  local condition = assert(mon.condition, "stored mons carry their condition")
  local types = {}
  for _, typeKey in ipairs(assert(form.types, "catalog forms carry types")) do
    types[#types + 1] = typeKey
  end
  local facts = {
    revision = service:partyRevision(),
    slot = slot0,
    slotCount = service:partyCount(),
    isEgg = mon.isEgg == true,
    displayName = Mon.displayName(mon, catalog),
    speciesName = assert(species.name, "catalog species carry a display name"),
    gender = gender,
    shiny = shiny,
    types = types,
    otName = assert(origin.trainerName, "origins carry the trainer name"),
    otVisibleId = trainerId % 65536,
    nature = Personality.nature(personality),
    ability = abilityKey,
    abilityName = assert(ability.name, "catalog abilities carry a display name"),
    abilityDescription = assert(ability.description, "catalog abilities carry a description"),
    heldItem = heldItem,
    heldItemName = heldItemName,
    status = PartyScreenTheme.statusKey(
      assert(condition.status, "conditions carry status bits"),
      assert(condition.currentHp, "conditions carry current health")
    ),
    currentHp = condition.currentHp,
    leaves = projectLeaves(mask),
    portraitSelector = nil,
    iconKey = MonCache.iconSelector(mon.species, mon.form, mon.isEgg == true),
    stats = nil,
    experience = nil,
    expToNext = nil,
    moves = {},
    egg = nil,
    level = nil,
    maxHp = nil,
    bodyLineEstimate = 0,
  }
  if facts.isEgg then
    facts.egg = eggFacts(service, slot0)
    return facts
  end
  local derived = service:derive(mon)
  facts.level = assert(derived.level, "derivation carries the level")
  facts.maxHp = assert(derived.maxHp, "derivation carries maximum health")
  facts.stats = {
    attack = assert(derived.attack, "derivation carries attack"),
    defense = assert(derived.defense, "derivation carries defense"),
    speed = assert(derived.speed, "derivation carries speed"),
    specialAttack = assert(derived.specialAttack, "derivation carries special attack"),
    specialDefense = assert(derived.specialDefense, "derivation carries special defense"),
  }
  local experience = assert(mon.experience, "stored mons carry experience")
  assert(type(experience) == "number", "experience is numeric")
  facts.experience = experience
  if facts.level < 100 then
    local curve = catalog:growthCurve(assert(species.growthCurve, "catalog species carry a growth curve"))
    facts.expToNext = Experience.expFor(curve, facts.level + 1) - experience
  end
  facts.moves = projectMoves(catalog, assert(mon.moves, "stored mons carry their moves"))
  local portraitGender = gender
  if portraitGender == "genderless" then
    portraitGender = "male"
  end
  facts.portraitSelector = MonCache.portraitSelector(mon.species, mon.form, portraitGender, shiny)
  facts.bodyLineEstimate = #SummaryModel.wrapLines(facts.abilityDescription, SummaryModel.WRAP_WIDTH_CHARS)
  return facts
end

return SummaryModel
