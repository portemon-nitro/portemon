-- Evaluates normalized HGSS follower-interaction rules against live field state.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")

---@class FollowerInteractionEngine
---@field catalog table<string, unknown>
---@field mons HgssMonService
---@field items ItemCatalog
---@field fashionCase FashionCaseState
---@field actors FieldActorManager
---@field followingMon FollowingMonController
---@field runtimeMap RuntimeFieldMap
---@field player ScriptPlayerFacade
---@field clock LocalClock
---@field world FollowerInteractionWorld
local FollowerInteractionEngine = {}
FollowerInteractionEngine.__index = FollowerInteractionEngine

---@class FollowerEffectAnchor
---@field fieldX integer
---@field fieldZ integer
---@field worldY number
---@field cellKey string?
---@field sourceSurfaceId integer?

---@class FollowerInteractionRng
---@field chance fun(self: FollowerInteractionRng, numerator: integer, denominator: integer): boolean

---@class FollowerInteractionWorld
---@field rng FollowerInteractionRng
---@field isFlagSet fun(self: FollowerInteractionWorld, flagId: integer): boolean

local NATURE_CLASS = { 4, 5, 4, 4, 1, 4, 3, 2, 1, 2, 5, 6, 3, 1, 1, 3, 6, 3, 5, 6, 2, 2, 1, 3, 6 }
local TYPE_CLASS = { 1, 7, 10, 8, 9, 13, 12, 14, 17, 0, 2, 3, 5, 4, 11, 6, 15, 16 }
local POCK_CLASS = { items = 4, medicine = 2, balls = 1, tmhm = 7, berries = 6, mail = 5, battle_items = 3 }
local CLASS_BY_STAT = { power = 1, skill = 3, speed = 5, jump = 4, stamina = 2 }
local PERFORMANCE_ORDER = { "power", "skill", "speed", "jump", "stamina" }
local FOLLOWER_SCAN_ORDER = { "power", "stamina", "jump", "skill", "speed" }
local NATURE_MODIFIERS = {
  { 10, 0, 0, 0, -10 },
  { 35, -35, 0, 0, 0 },
  { 35, 0, 0, 0, -35 },
  { 35, 0, 0, -35, 0 },
  { 35, 0, -35, 0, 0 },
  { -35, 35, 0, 0, 0 },
  { 0, 10, 0, -10, 0 },
  { 0, 35, 0, 0, -35 },
  { 0, 35, 0, -35, 0 },
  { 0, 35, -35, 0, 0 },
  { -35, 0, 0, 0, 35 },
  { 0, -35, 0, 0, 35 },
  { 0, 0, -10, 0, 10 },
  { 0, 0, 0, -35, 35 },
  { 0, 0, -35, 0, 35 },
  { -35, 0, 0, 35, 0 },
  { 0, -35, 0, 35, 0 },
  { 0, 0, 0, 35, -35 },
  { -10, 0, 0, 10, 0 },
  { 0, 0, -35, 35, 0 },
  { -35, 0, 35, 0, 0 },
  { 0, -35, 35, 0, 0 },
  { 0, 0, 35, 0, -35 },
  { 0, 0, 35, -35, 0 },
  { 0, -10, 10, 0, 0 },
}

local function statusClass(status)
  if status == 0 then
    return 1
  end
  if math.floor(status / 8) % 2 == 1 or math.floor(status / 128) % 2 == 1 then
    return 5
  end
  if status % 8 ~= 0 then
    return 8
  end
  if status == 0x10 then
    return 2
  end
  if status == 0x20 then
    return 3
  end
  if status == 0x40 then
    return 4
  end
  return 8
end

local function rangeClass(value, limits)
  for i, upper in ipairs(limits) do
    if value >= upper then
      return i
    end
  end
  return #limits + 1
end

local function selectorMatches(kind, expected, actual, context)
  if expected == 0 then
    return true
  end
  if kind == "friendshipClass" then
    if expected == 9 then
      return context.friendship >= 90
    end
    if expected == 10 then
      return context.friendship < 60
    end
  elseif kind == "moodClass" then
    if expected == 9 then
      return context.mood >= 0
    end
    if expected == 10 then
      return context.mood < 0
    end
  elseif kind == "statusClass" and expected == 7 then
    return actual ~= 1
  elseif kind == "heldItemClass" and expected == 9 then
    return actual ~= 8
  elseif kind == "speciesClass" then
    if expected == 250 then
      return actual <= 19
    end
    if expected == 251 then
      return actual <= 130
    end
    if expected == 252 then
      return actual >= 140 and actual <= 149
    end
    if expected == 253 then
      return actual >= 160
    end
    if expected == 254 then
      return actual >= 220
    end
  elseif kind == "nearbyObjectClass" then
    return expected == 5 and actual >= 5 or actual == expected
  elseif kind == "hiddenItemClass" then
    return expected == 4 and actual >= 4 or actual == expected
  elseif kind == "specialSpriteClass" then
    return false
  elseif kind == "leafClass" then
    return math.floor((context.shinyLeaves or 0) / (2 ^ (expected - 1))) % 2 == 0
  end
  return expected == actual
end

local function partnerCell(runtimeMap, partnerState)
  local localX, localZ =
    partnerState.fieldX - runtimeMap.coordinateOrigin.x, partnerState.fieldZ - runtimeMap.coordinateOrigin.z
  return runtimeMap.collision:getLocal(localX, localZ)
end

function FollowerInteractionEngine.new(opts)
  assert(type(opts) == "table" and type(opts.catalog) == "table", "interaction catalog is required")
  for _, key in ipairs({ "mons", "items", "world", "actors", "followingMon", "runtimeMap", "player", "clock" }) do
    assert(opts[key] ~= nil, "interaction engine requires " .. key)
  end
  return setmetatable({
    catalog = opts.catalog,
    mons = opts.mons,
    items = opts.items,
    fashionCase = opts.fashionCase,
    world = opts.world,
    actors = opts.actors,
    followingMon = opts.followingMon,
    runtimeMap = opts.runtimeMap,
    player = opts.player,
    clock = opts.clock,
  }, FollowerInteractionEngine)
end

function FollowerInteractionEngine:_pokeathlonClass(mon, civilDate)
  local catalog = self.mons:catalog()
  local species = catalog:species(mon.species)
  if species.nativeId == 494 or species.nativeId == 495 then
    return nil
  end
  local form = catalog:form(mon.species, mon.form or 0)
  local performance = assert(form.performance, "mon form has no Pokéathlon performance")
  local nature = (mon.personality or 0) % 25
  local modifiers = assert(NATURE_MODIFIERS[nature + 1])
  local stats = {}
  for arrayIndex, stat in ipairs(PERFORMANCE_ORDER) do
    local performanceIndex = arrayIndex - 1
    local data = assert(performance[stat], "Pokéathlon performance stat is missing")
    local digit = math.floor((mon.personality or 0) / (10 ^ performanceIndex)) % 10
    local dateDigit = (digit + (civilDate.day + (7 - performanceIndex)) * (civilDate.day + (performanceIndex + 3))) % 10
    -- Retail adds the party-slot Aprijuice modifier to the daily score before
    -- star conversion; Portemon does not model that party-extra state, so this
    -- path uses modifier zero.
    local dailyMod = modifiers[arrayIndex] + 2 * dateDigit - 9
    local deltaStars = dailyMod <= -120 and -4
      or dailyMod <= -80 and -3
      or dailyMod <= -40 and -2
      or dailyMod <= -15 and -1
      or dailyMod <= 14 and 0
      or dailyMod <= 39 and 1
      or dailyMod <= 79 and 2
      or dailyMod <= 119 and 3
      or 4
    stats[stat] = math.max(data.min, math.min(data.max, data.base + deltaStars))
  end
  local bestStars, bestStat = -math.huge, nil
  for _, stat in ipairs(FOLLOWER_SCAN_ORDER) do
    if stats[stat] > bestStars then
      bestStars, bestStat = stats[stat], stat
    end
  end
  return CLASS_BY_STAT[assert(bestStat)]
end

function FollowerInteractionEngine:_context(leadSlot)
  local mon = assert(self.mons:partyMon(leadSlot), "living lead mon is missing")
  local derived = self.mons:partyMonDerived(leadSlot)
  local item = mon.heldItem ~= nil and mon.heldItem ~= "NONE" and self.items:item(mon.heldItem) or nil
  local time = self.clock:nowLocal()
  local partnerId = assert(self.followingMon:partnerActorId(), "partner actor is unavailable")
  local partner = assert(self.actors:getById(partnerId), "partner actor is unavailable")
  local partnerState = partner.numericState and partner:numericState() or {}
  local playerPosition = self.player:position()
  local playerX, playerZ = playerPosition.fieldX, playerPosition.fieldZ
  local nearby = 0
  for _, actor in ipairs(self.actors:actorsOf(self.runtimeMap.mapId)) do
    local id = actor.objectEventId
    local state = actor.numericState and actor:numericState() or {}
    if id ~= 0xFD and id ~= 0xFF then
      if
        actor.spriteId ~= 0x54
        and actor.spriteId ~= 0x55
        and actor.spriteId ~= 0x56
        and math.abs(state.fieldX - playerX) <= 1
        and math.abs(state.fieldZ - playerZ) <= 1
      then
        nearby = nearby + 1
      end
    end
  end
  local background = assert(self.runtimeMap.fieldData.events.background, "current map background events are missing")
  local hidden = 0
  for _, event in ipairs(background) do
    if event.type == 2 and event.hiddenItemFlagId and not self.world:isFlagSet(event.hiddenItemFlagId) then
      hidden = hidden + 1
    end
  end
  local cell = partnerCell(self.runtimeMap, partnerState)
  local friendship = self.mons:monFriendship(leadSlot)
  local mood = mon.mood or 0
  local nature = self.mons:monNature(leadSlot)
  local gender = self.mons:monGender(leadSlot)
  local type1, type2 = self.mons:monTypes(leadSlot)
  local hpPercent = math.floor((mon.condition.currentHp * 100) / derived.maxHp)
  local heldClass = item and POCK_CLASS[item.pocket] or 8
  local species = self.mons:catalog():species(mon.species)
  local speciesClass =
    assert(self.catalog.speciesClassBySpeciesId[species.nativeId], "follower species class is missing")
  local criteria = {
    heldItemClass = heldClass,
    hpClass = hpPercent == 100 and 1 or hpPercent >= 75 and 2 or hpPercent >= 50 and 3 or hpPercent >= 25 and 4 or 5,
    statusClass = statusClass(mon.condition.status),
    friendshipClass = rangeClass(friendship, { 255, 200, 150, 90, 60, 30, 1 }),
    friendship = friendship,
    moodClass = mood >= 127 and 1
      or mood >= 100 and 2
      or mood >= 50 and 3
      or mood >= 30 and 4
      or mood > -30 and 5
      or mood > -50 and 6
      or mood > -127 and 7
      or 8,
    mood = mood,
    genderClass = gender == 0 and 1 or 2,
    natureClass = assert(NATURE_CLASS[nature + 1]),
    leafClass = mon.shinyLeaves or 0,
    shinyLeaves = mon.shinyLeaves or 0,
    speciesClass = speciesClass,
    specialSpriteClass = 0,
    nearbyObjectClass = nearby,
    hiddenItemClass = hidden,
    hiddenItemCount = hidden,
    weatherClass = assert(self.runtimeMap.effectiveWeatherId, "current runtime weather is required") == 0 and 1
      or self.runtimeMap.effectiveWeatherId == 1 and 3
      or 0,
    timeClass = time.hour <= 3 and 1 or time.hour <= 9 and 2 or time.hour <= 16 and 3 or time.hour <= 19 and 4 or 5,
    facingClass = ({ east = 1, west = 2, north = 3, south = 4 })[partner.facing],
    typeClass = 0,
    pokeathlonClass = self:_pokeathlonClass(mon, time),
    levelClass = (derived.level or self.mons:scriptMonLevel(leadSlot)) <= 47 and 4
      or (derived.level or self.mons:scriptMonLevel(leadSlot)) <= 52 and 6
      or 5,
    encounterClass = 0,
    mapId = self.runtimeMap.mapId,
    metatileBehaviorId = cell.behavior,
  }
  criteria.type1Class = TYPE_CLASS[type1 + 1] or 0
  criteria.type2Class = TYPE_CLASS[type2 + 1] or 0
  criteria.typeClass = criteria.type1Class
  criteria.encounterClass = MetatileBehavior.canGenerateWalkingEncounters(cell.behavior) and 1 or 2
  return criteria
end

function FollowerInteractionEngine:select()
  local leadSlot = self.mons:leadAliveSlot()
  if leadSlot == nil then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "follower interaction requires a living party mon", {})
  end
  local context = self:_context(leadSlot)
  local section = self.runtimeMap.mapSectionNativeId
  local rules = self.catalog.rulesByMapSection[section]
  if rules == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_INVALID_REFERENCE,
      "interaction rules for map section are missing",
      { section = section }
    )
  end
  rules = assert(rules)
  for _, rule in ipairs(rules) do
    if self.world.rng:chance(rule.percentage, 100) then
      if rule.requiredFlagId == nil or self.world:isFlagSet(rule.requiredFlagId) then
        local matches = true
        for kind, expected in pairs(rule.criteria) do
          if not matches then
            break
          elseif kind == "mapId" then
            if expected ~= context[kind] then
              matches = false
              break
            end
          elseif kind == "metatileBehaviorId" then
            if expected ~= 0 and expected ~= context[kind] then
              matches = false
              break
            end
          elseif kind == "specialSpriteClass" then
            if expected ~= 0 then
              matches = false
              break
            end
          elseif kind == "typeClass" then
            if expected ~= 0 and expected ~= context.type1Class and expected ~= context.type2Class then
              matches = false
              break
            end
          elseif not selectorMatches(kind, expected, context[kind], context) then
            matches = false
            break
          end
        end
        if matches then
          return { leadSlot = leadSlot, programId = rule.interactionId }
        end
      end
    end
  end
  return nil
end

function FollowerInteractionEngine:partnerMetatileBehavior()
  local actorId = assert(self.followingMon:partnerActorId(), "partner actor is unavailable")
  local partner = assert(self.actors:getById(actorId), "partner actor is unavailable")
  local partnerState = assert(partner:numericState(), "partner actor state is unavailable")
  return partnerCell(self.runtimeMap, partnerState).behavior
end

---@return FollowerEffectAnchor
function FollowerInteractionEngine:partnerEffectAnchor()
  local actorId = assert(self.followingMon:partnerActorId(), "partner actor is unavailable")
  local partner = assert(self.actors:getById(actorId), "partner actor is unavailable")
  local state = assert(partner:numericState(), "partner actor state is unavailable")
  assert(state.hasWorldPosition == 1, "partner actor world position is unavailable")
  local anchor = {
    fieldX = state.fieldX,
    fieldZ = state.fieldZ,
    worldY = state.worldY,
  }
  local cellKey = partner.cellKey
  local sourceSurfaceId = partner:getSourceSurfaceId()
  if cellKey ~= nil and sourceSurfaceId ~= nil then
    anchor.cellKey = cellKey
    anchor.sourceSurfaceId = sourceSurfaceId
  end
  return anchor
end

function FollowerInteractionEngine:program(programId)
  return assert(self.catalog.programs[programId], "interaction program is missing")
end

function FollowerInteractionEngine:motion(motionId)
  return assert(self.catalog.motions[motionId], "interaction motion is missing")
end

function FollowerInteractionEngine:reaction(selector)
  return assert(self.catalog.reactions[selector], "interaction reaction is missing")
end

function FollowerInteractionEngine:bindings(leadSlot)
  local mon = assert(self.mons:partyMon(leadSlot))
  local species = self.mons:catalog():species(mon.species)
  local item = mon.heldItem ~= nil and mon.heldItem ~= "NONE" and self.items:item(mon.heldItem) or nil
  local section = self.runtimeMap.mapSectionNativeId
  local location = assert(self.catalog.locationNames[section], "interaction location name is missing")
  return {
    [0] = mon.nickname or species.name,
    [1] = species.name,
    [2] = self.player:name(),
    [3] = location,
    [4] = item and item.name or "",
  }
end

function FollowerInteractionEngine:ignoresMotionVerticalOffset(leadSlot)
  local mon = assert(self.mons:partyMon(leadSlot))
  local speciesId = self.mons:catalog():species(mon.species).nativeId
  return speciesId == 50 or speciesId == 51
end

function FollowerInteractionEngine:applyDeltas(leadSlot, friendship, mood)
  self.mons:applyFollowerInteractionDeltas(leadSlot, friendship, mood)
end

function FollowerInteractionEngine:reward(leadSlot, reward)
  if reward.kind == "fashion" then
    local accessoryId = reward.selector - 1
    local outcome = assert(self.fashionCase):tryAdd(accessoryId)
    return {
      outcome = outcome and "added" or "full",
      plain = self.catalog.fashionNames[accessoryId].name,
      article = self.catalog.fashionNames[accessoryId].nameWithArticle,
    }
  end
  local result = self.mons:tryGiveShinyLeaf(leadSlot, reward.selector)
  if result == true or result == "new" then
    return { outcome = "new" }
  end
  return { outcome = "duplicate" }
end

return FollowerInteractionEngine
