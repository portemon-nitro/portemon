-- Owns the saved Day Care facts read by native phone conversations.
local Errors = require("libs.errors.src.Errors")
local GameSaveErrors = require("libs.hgss.src.save.GameSaveErrors")
local Experience = require("libs.mons.src.gen4.Experience")
local Personality = require("libs.mons.src.gen4.Personality")

local DaycareState = {}
DaycareState.__index = DaycareState
DaycareState.SCHEMA = "hgss-daycare-v1"

local function invalid(message)
  Errors.raise(GameSaveErrors.GAME_SAVE_BUCKET_INVALID, message, { bucket = "daycare" })
end

local function integer(value, low, high)
  return type(value) == "number" and value % 1 == 0 and value >= low and value <= high
end

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, child in pairs(value) do
    result[key] = copy(child)
  end
  return result
end

local function exactKeys(value, allowed, what)
  for key in pairs(value) do
    if not allowed[key] then
      invalid(what .. " has an unknown field")
    end
  end
end

local function checkMon(mon, monCatalog)
  if type(mon) ~= "table" then
    invalid("Day Care mon must be an occupied slot or false")
  end
  exactKeys(mon, {
    species = true,
    nickname = true,
    personality = true,
    experience = true,
    steps = true,
    otId = true,
  }, "Day Care mon")
  if
    type(mon.species) ~= "string"
    or type(mon.nickname) ~= "string"
    or mon.nickname == ""
    or not integer(mon.personality, 0, 0xFFFFFFFF)
    or not integer(mon.experience, 0, 0xFFFFFFFF)
    or not integer(mon.steps, 0, 0xFFFFFFFF)
    or not integer(mon.otId, 0, 0xFFFFFFFF)
  then
    invalid("Day Care mon identity, personality, or growth facts are invalid")
  end
  if monCatalog ~= nil then
    monCatalog:species(mon.species)
  end
end

local function validate(snapshot, monCatalog)
  if type(snapshot) ~= "table" or snapshot.schema ~= DaycareState.SCHEMA then
    invalid("Day Care schema is invalid")
  end
  exactKeys(snapshot, { schema = true, mons = true, eggPid = true }, "Day Care state")
  if type(snapshot.mons) ~= "table" or not integer(snapshot.eggPid, 0, 0xFFFFFFFF) then
    invalid("Day Care slots or egg identity are invalid")
  end
  exactKeys(snapshot.mons, { [1] = true, [2] = true }, "Day Care slots")
  local mons = {}
  for slot = 1, 2 do
    local mon = snapshot.mons[slot]
    if mon ~= false then
      checkMon(mon, monCatalog)
      mons[slot] = copy(mon)
    else
      mons[slot] = false
    end
  end
  return { schema = DaycareState.SCHEMA, mons = mons, eggPid = snapshot.eggPid }
end

function DaycareState.empty()
  return setmetatable({ _bucket = { schema = DaycareState.SCHEMA, mons = { false, false }, eggPid = 0 } }, DaycareState)
end

function DaycareState.restore(snapshot, monCatalog)
  return setmetatable({ _bucket = validate(snapshot, monCatalog), _monCatalog = monCatalog }, DaycareState)
end

function DaycareState:capture()
  return copy(self._bucket)
end

local function compatible(first, second, monCatalog)
  local firstSpecies = monCatalog:species(first.species)
  local secondSpecies = monCatalog:species(second.species)
  local firstGender = Personality.gender(firstSpecies.genderRatio, first.personality)
  local secondGender = Personality.gender(secondSpecies.genderRatio, second.personality)
  local firstGroup = firstSpecies.eggGroups
  local secondGroup = secondSpecies.eggGroups
  if firstGroup[1] == "undiscovered" or secondGroup[1] == "undiscovered" then
    return 3
  end
  if firstGroup[1] == "ditto" and secondGroup[1] == "ditto" then
    return 3
  end
  if firstGroup[1] == "ditto" or secondGroup[1] == "ditto" then
    return first.otId == second.otId and 2 or 1
  end
  if firstGender == secondGender or firstGender == "genderless" or secondGender == "genderless" then
    return 3
  end
  local matchingGroup = false
  for _, group in ipairs(firstGroup) do
    if group ~= "undiscovered" and group ~= "ditto" then
      for _, otherGroup in ipairs(secondGroup) do
        if group == otherGroup then
          matchingGroup = true
        end
      end
    end
  end
  if not matchingGroup then
    return 3
  end
  if first.species == second.species then
    return first.otId == second.otId and 1 or 0
  end
  return first.otId == second.otId and 2 or 1
end

function DaycareState:phoneFacts(monCatalog)
  assert(type(monCatalog) == "table", "Day Care phone facts read the composed mon catalog")
  local mons = {}
  for slot = 1, 2 do
    local saved = self._bucket.mons[slot]
    if saved ~= false then
      local species = monCatalog:species(saved.species)
      local curve = monCatalog:growthCurve(species.growthCurve)
      local before = Experience.level(curve, saved.experience)
      local after = Experience.level(curve, saved.experience + saved.steps)
      mons[#mons + 1] = { nickname = saved.nickname, growth = after - before }
    end
  end
  local compatibility = nil
  if #mons == 2 then
    compatibility = compatible(self._bucket.mons[1], self._bucket.mons[2], monCatalog)
  end
  return { mons = mons, eggPid = self._bucket.eggPid, compatibility = compatibility }
end

return DaycareState
