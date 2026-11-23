-- Pure native evolution eligibility and candidate planning.
-- Source: the retail ROM GetMonEvolution (ordered slot scan, first match wins) composed
-- with the existing Experience/MonStats/Personality owners. Level, trade, and
-- bag-item uses each answer only their own trigger family; the day/night
-- held items answer level-up only. World-gated methods never open: no HeartGold or
-- SoulSilver location maps to them. Planning copies everything it stages and
-- never mutates its input; publication belongs to the caller.

local U32 = require("libs.codec.src.U32")
local Experience = require("libs.mons.src.gen4.Experience")
local MonStats = require("libs.mons.src.gen4.MonStats")
local Personality = require("libs.mons.src.gen4.Personality")

---@class Evolution
local Evolution = {}

local FRIENDSHIP_THRESHOLD = 220
local PARTY_MAX = 6
local SPARE_BALL_KEY = "POKE_BALL"
local NINJASK_METHOD = "level_ninjask"
local SHEDINJA_METHOD = "level_shedinja"
local SHEDINJA_SPECIES = "SHEDINJA"

local KNOWN_METHODS = {
  friendship = true,
  friendship_day = true,
  friendship_night = true,
  level = true,
  trade = true,
  trade_item = true,
  stone = true,
  level_atk_gt_def = true,
  level_atk_eq_def = true,
  level_atk_lt_def = true,
  level_pid_lo = true,
  level_pid_hi = true,
  level_ninjask = true,
  level_shedinja = true,
  beauty = true,
  stone_male = true,
  stone_female = true,
  item_day = true,
  item_night = true,
  has_move = true,
  other_party_mon = true,
  level_male = true,
  level_female = true,
  coronet = true,
  eterna = true,
  route217 = true,
}

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

---@param mon table<string, unknown>
local function checkMon(mon)
  assert(type(mon) == "table", "evolution checks read a mon record")
  assert(type(mon.species) == "string", "evolution checks read the species key")
  assert(type(mon.form) == "number", "evolution checks read the form index")
  assert(type(mon.personality) == "number" and mon.personality % 1 == 0, "evolution checks read the personality")
  assert(type(mon.experience) == "number", "evolution checks read experience")
  assert(type(mon.moves) == "table", "evolution checks read the move set")
end

---@param mon table<string, unknown>
---@param catalog table<string, unknown>
---@return integer
local function monLevel(mon, catalog)
  local species = catalog:species(mon.species)
  return Experience.level(catalog:growthCurve(species.growthCurve), mon.experience)
end

---@param mon table<string, unknown>
---@param catalog table<string, unknown>
---@return string
local function monGender(mon, catalog)
  local species = catalog:species(mon.species)
  return Personality.gender(species.genderRatio, mon.personality)
end

---@param mon table<string, unknown>
---@return integer
local function friendshipOf(mon)
  local friendship = assert(mon.friendship, "bond slots read friendship")
  assert(type(friendship) == "number", "bond slots read numeric friendship")
  return friendship
end

---@param mon table<string, unknown>
---@return integer
local function beautyOf(mon)
  local contest = assert(mon.contest, "beauty slots read contest values")
  assert(type(contest) == "table", "beauty slots read the contest record")
  local beauty = assert(contest.beauty, "beauty slots read contest beauty")
  assert(type(beauty) == "number", "beauty slots read numeric beauty")
  return beauty --[[@as integer]]
end

---@param mon table<string, unknown>
---@param move unknown
---@return boolean
local function knowsMove(mon, move)
  for _, entry in ipairs(mon.moves) do
    if type(entry) == "table" and entry.move == move then
      return true
    end
  end
  return false
end

---@param context table<string, unknown>
---@param species unknown
---@return boolean
local function partyHas(context, species)
  local party = assert(context.party, "party slots read the party facts")
  assert(type(party) == "table", "party facts form an array")
  for _, member in ipairs(party) do
    if type(member) == "table" and member.species == species then
      return true
    end
  end
  return false
end

---@param slot table<string, unknown>
---@param level integer
---@return boolean
local function levelReached(slot, level)
  local at = assert(slot.level, "level slots carry their level")
  assert(type(at) == "number", "level slots carry a numeric level")
  return at <= level
end

---@param mon table<string, unknown>
---@return integer
local function pidHighHalf(mon)
  -- Retail compares pid_hi % 10 against 5 with
  -- pid_hi = (pid >> 16) & 0xFFFF. Personalities stay below 2^32, so the
  -- shift already fits in 16 bits and the mask is an identity; the
  -- division below matches the retail half-word exactly.
  return math.floor(mon.personality / U32.HALF_BASE) % 10
end

---@param method unknown
local function checkKnownMethod(method)
  assert(KNOWN_METHODS[method] == true, "evolution slots carry a known native method: " .. tostring(method))
end

-- Level-up answers the native EVOCTX_LEVELUP family: bonds, plain and
-- conditional level slots, beauty, held day/night items, known moves, and
-- party species. The shed side-product slot never matches on its own; the
-- source reports its method without a target; the extra is built after the
-- evolution completes by shedSideProduct. Stone and trade slots never answer here.
---@param slot table<string, unknown>
---@param mon table<string, unknown>
---@param context table<string, unknown>
---@param catalog table<string, unknown>
---@param level integer
---@return boolean
local function matchesLevel(slot, mon, context, catalog, level)
  local method = slot.method
  if method == "friendship" then
    return friendshipOf(mon) >= FRIENDSHIP_THRESHOLD
  elseif method == "friendship_day" then
    return context.timeOfDay == "day" and friendshipOf(mon) >= FRIENDSHIP_THRESHOLD
  elseif method == "friendship_night" then
    return context.timeOfDay == "night" and friendshipOf(mon) >= FRIENDSHIP_THRESHOLD
  elseif method == "level" then
    return levelReached(slot, level)
  elseif method == "level_male" then
    return levelReached(slot, level) and monGender(mon, catalog) == "male"
  elseif method == "level_female" then
    return levelReached(slot, level) and monGender(mon, catalog) == "female"
  elseif method == "level_atk_gt_def" then
    if not levelReached(slot, level) then
      return false
    end
    local facts = MonStats.derive(mon, catalog)
    return facts.attack > facts.defense
  elseif method == "level_atk_eq_def" then
    if not levelReached(slot, level) then
      return false
    end
    local facts = MonStats.derive(mon, catalog)
    return facts.attack == facts.defense
  elseif method == "level_atk_lt_def" then
    if not levelReached(slot, level) then
      return false
    end
    local facts = MonStats.derive(mon, catalog)
    return facts.attack < facts.defense
  elseif method == "level_pid_lo" then
    return levelReached(slot, level) and pidHighHalf(mon) % 10 < 5
  elseif method == "level_pid_hi" then
    return levelReached(slot, level) and pidHighHalf(mon) % 10 >= 5
  elseif method == NINJASK_METHOD then
    return levelReached(slot, level)
  elseif method == SHEDINJA_METHOD then
    return false
  elseif method == "beauty" then
    local threshold = assert(slot.threshold, "beauty slots carry their threshold")
    assert(type(threshold) == "number", "beauty slots carry a numeric threshold")
    return beautyOf(mon) >= threshold
  elseif method == "item_day" then
    return mon.heldItem == slot.item and context.timeOfDay == "day"
  elseif method == "item_night" then
    return mon.heldItem == slot.item and context.timeOfDay == "night"
  elseif method == "has_move" then
    return knowsMove(mon, slot.move)
  elseif method == "other_party_mon" then
    return partyHas(context, slot.species)
  elseif method == "coronet" or method == "eterna" or method == "route217" then
    -- Retail opens these only when the caller passes the slot method back
    -- as the map evolution method; HGSS map headers always yield EVO_NONE,
    -- so they stay shut in both games.
    return false
  end
  checkKnownMethod(method)
  return false
end

-- Bag-item use answers the native item family: retail handles
-- EVOCTX_ITEM_CHECK and EVOCTX_ITEM_USE in one shared case, so a single
-- item trigger kind covers both. Only plain and gendered stones answer,
-- each requiring its own item; retail reports an internal method_ret of 0
-- on this path, so the staged reason stays method-keyed. Level, trade,
-- held-item, and world slots never answer here.
---@param slot table<string, unknown>
---@param mon table<string, unknown>
---@param catalog table<string, unknown>
---@param usedItem string
---@return boolean
local function matchesItemUse(slot, mon, catalog, usedItem)
  local method = slot.method
  if method == "stone" then
    return slot.item == usedItem
  elseif method == "stone_male" then
    return slot.item == usedItem and monGender(mon, catalog) == "male"
  elseif method == "stone_female" then
    return slot.item == usedItem and monGender(mon, catalog) == "female"
  end
  checkKnownMethod(method)
  return false
end

-- Trading answers the native EVOCTX_TRADE family only: unconditional trade
-- plus held-item trade. Every other slot never answers here.
---@param slot table<string, unknown>
---@param mon table<string, unknown>
---@return boolean
local function matchesTrade(slot, mon)
  local method = slot.method
  if method == "trade" then
    return true
  elseif method == "trade_item" then
    return mon.heldItem == slot.item
  end
  checkKnownMethod(method)
  return false
end

-- Validates the shared trigger context and resolves the ordered form slots
-- with the trigger facts the matchers need. blockers (the marked baby
-- form, the held blocker outside bag-item use) resolve here so every
-- entry point answers them identically. Retail keys the held gate off the
-- held item's hold-no-evolve effect identity; the item catalog carries no
-- such identity for the blocker, so the check stays keyed on the
-- source-named item, with the single source-named trade-evolving species
-- exempt, in this one place.
---@param mon table<string, unknown>
---@param context table<string, unknown>
---@param catalog table<string, unknown>
---@return table<integer, table<string, unknown>>? ordered form slots, nil while a blocker holds
---@return string? trigger kind, nil while a blocker holds
---@return integer? derived level for level triggers
---@return string? used item for item triggers
local function triggerSlots(mon, context, catalog)
  checkMon(mon)
  assert(type(context) == "table", "evolution checks read a trigger context")
  assert(catalog ~= nil, "evolution checks read a catalog")
  local trigger = assert(context.trigger, "evolution checks read the trigger facts")
  assert(type(trigger) == "table", "evolution trigger facts form a record")
  local kind = trigger.kind
  assert(kind == "level" or kind == "item" or kind == "trade", "evolution triggers name their kind")
  if mon.species == "PICHU" and mon.form == 1 then
    return nil
  end
  if kind ~= "item" and mon.species ~= "KADABRA" then
    local heldItem = assert(mon.heldItem, "evolution checks read the held-item key")
    if heldItem ~= "NONE" then
      local behavior = catalog:item(heldItem).heldBehavior
      if type(behavior) == "table" and behavior.key == "prevents_evolution" then
        return nil
      end
    end
  end
  local form = catalog:form(mon.species, mon.form)
  local slots = assert(form.evolutions, "evolution checks read the ordered form slots")
  assert(type(slots) == "table", "evolution slots form an array")
  local level = nil
  if kind == "level" then
    level = monLevel(mon, catalog)
  end
  local usedItem = nil
  if kind == "item" then
    usedItem = trigger.item
    assert(type(usedItem) == "string" and usedItem ~= "", "item uses name their item")
  end
  return slots, kind, level, usedItem
end

---@param slot table<string, unknown>
---@param mon table<string, unknown>
---@param context table<string, unknown>
---@param catalog table<string, unknown>
---@param kind string
---@param level integer?
---@param usedItem string?
---@return boolean matched
local function slotMatches(slot, mon, context, catalog, kind, level, usedItem)
  assert(type(slot) == "table", "evolution slots are records")
  -- Composed methods are namespaced slots carrying their own callable
  -- predicate, evaluated once in source order; native methods dispatch
  -- through the exact matchers below. A composed predicate may throw,
  -- and the failure propagates with the input untouched.
  local custom = slot.matches
  if type(custom) == "function" and KNOWN_METHODS[slot.method] == nil then
    return custom(mon, context, catalog, slot) == true
  elseif kind == "level" then
    return matchesLevel(slot, mon, context, catalog, assert(level, "level checks derive the level"))
  elseif kind == "item" then
    return matchesItemUse(slot, mon, catalog, assert(usedItem, "item uses name their item"))
  end
  return matchesTrade(slot, mon)
end

-- Returns the first matching evolution slot in source order, or nil when
-- nothing matches. The marked baby form never evolves. The blocker held
-- item stops level and trade checks but never bag-item use, except for
-- one trade-evolving species that still answers level and trade checks
-- while holding it.
---@param mon table<string, unknown>
---@param context table<string, unknown>
---@param catalog table<string, unknown>
---@return table<string, unknown>?
function Evolution.check(mon, context, catalog)
  local slots, kind, level, usedItem = triggerSlots(mon, context, catalog)
  if slots == nil then
    return nil
  end
  assert(type(kind) == "string", "triggers name their kind")
  for _, slot in ipairs(slots) do
    if slotMatches(slot, mon, context, catalog, kind, level, usedItem) then
      return slot
    end
  end
  return nil
end

-- Applies the nickname policy to a private copy: custom names survive onto
-- the evolved mon while default naming follows the new species.
---@param monAfter table<string, unknown>
---@param monBefore table<string, unknown>
---@return table<string, unknown>
function Evolution.applyNamePolicy(monAfter, monBefore)
  assert(type(monAfter) == "table", "naming stages the evolved mon")
  assert(type(monBefore) == "table", "naming reads the pre-evolution mon")
  local staged = copyValue(monAfter)
  assert(type(staged) == "table", "naming copies the evolved mon")
  if monBefore.nickname ~= nil then
    assert(type(monBefore.nickname) == "string", "custom names stay strings")
    staged.nickname = monBefore.nickname
  else
    staged.nickname = nil
  end
  return staged
end

-- Computes the post-evolution learning set with retail cursor semantics
-- (pokemon.c MonTryLearnMoveOnLevelUp as driven by evolution_scene.c
-- EVO_STATE_TRY_LEARN_MOVE with its cursor starting at 0): only the
-- staged target form's learnset entries whose level equals the current
-- level are offered, in learnset order, without repeats. Lower-level
-- entries are never revisited after evolution, even when still unknown.
-- The level derives from the staged experience through the target
-- species' growth curve; planning never changes experience, so this is
-- the unchanged current level. This is the single shared implementation:
-- the visual flow calls back into it instead of keeping its own copy.
---@param staged table<string, unknown>
---@param catalog table<string, unknown>
---@return table<integer, table<string, unknown>>
function Evolution.learningOpportunities(staged, catalog)
  assert(type(staged) == "table", "evolution learning reads the staged mon")
  assert(type(staged.species) == "string", "evolution learning reads the staged species")
  assert(type(staged.form) == "number", "evolution learning reads the staged form")
  assert(type(staged.experience) == "number", "evolution learning reads staged experience")
  assert(type(staged.moves) == "table", "evolution learning reads the staged move set")
  assert(catalog ~= nil, "evolution learning reads a catalog")
  local species = catalog:species(staged.species)
  local level = Experience.level(catalog:growthCurve(species.growthCurve), staged.experience)
  local targetForm = catalog:form(staged.species, staged.form)
  local learnset = assert(targetForm.levelUpMoves, "evolution learning reads the target learnset")
  assert(type(learnset) == "table", "target learnsets form an array")
  local opportunities = {}
  local queued = {}
  for _, entry in ipairs(learnset) do
    assert(type(entry) == "table", "learnset entries are records")
    if entry.level == level and not knowsMove(staged, entry.move) and not queued[entry.move] then
      queued[entry.move] = true
      opportunities[#opportunities + 1] = { level = entry.level, move = entry.move }
    end
  end
  return opportunities
end

-- Builds the shed side product from the finished Ninjask, after its
-- post-evolution learning: a copy of the final mon with the source reset
-- list applied (evolution_scene.c EvolutionScene_ApplyEvolutionEffects).
-- Needs a free party slot and a Poké Ball in the bag; returns nil without
-- either, otherwise the new mon and the one-ball inventory delta.
---@param finalMon table<string, unknown>
---@param context table<string, unknown>
---@param catalog table<string, unknown>
---@return table<string, unknown>? sideProduct
---@return table<string, unknown>? inventoryDelta
function Evolution.shedSideProduct(finalMon, context, catalog)
  checkMon(finalMon)
  assert(type(context) == "table", "side products read a trigger context")
  assert(catalog ~= nil, "side products read a catalog")
  local party = assert(context.party, "side products read the party facts")
  assert(type(party) == "table", "party facts form an array")
  local inventory = assert(context.inventory, "side products read the inventory facts")
  assert(type(inventory) == "table", "inventory facts form a record")
  if #party >= PARTY_MAX or (inventory[SPARE_BALL_KEY] or 0) < 1 then
    return nil
  end
  local extra = copyValue(finalMon)
  assert(type(extra) == "table", "side products copy the evolved mon")
  local beforeMaxHp = MonStats.derive(finalMon, catalog).maxHp
  extra.species = SHEDINJA_SPECIES
  extra.form = 0
  local abilities = assert(catalog:form(SHEDINJA_SPECIES, 0).abilities, "side products read the target abilities")
  assert(type(abilities) == "table", "target abilities form an array")
  extra.ability = abilities[Personality.abilitySlot(#abilities, extra.personality)]
  extra.origin.ball = SPARE_BALL_KEY
  extra.heldItem = "NONE"
  extra.markings = 0
  extra.ribbons = { ds1 = 0, gba = 0, ds2 = 0 }
  extra.shinyLeaves = 0
  extra.mood = 0
  extra.nickname = nil
  extra.mail = {}
  extra.capsule = { id = 0, seals = {} }
  local condition = assert(extra.condition, "side products carry the condition record")
  assert(type(condition) == "table", "side products carry the condition record")
  condition.effects = {}
  condition.currentHp =
    MonStats.adjustHpForMaxChange(beforeMaxHp, MonStats.derive(extra, catalog).maxHp, condition.currentHp)
  return extra, { item = SPARE_BALL_KEY, delta = -1 }
end

-- Stages the full candidate result for one authoritative slot. Experience
-- is untouched, health follows the shared maximum adjustment, ability
-- follows the personality slot of the new form, and consumed held items
-- (trade, day-gated, night-gated) clear to barehanded. The input is never
-- mutated.
---@param mon table<string, unknown>
---@param slot table<string, unknown>
---@param catalog table<string, unknown>
---@return table<string, unknown>
local function stageSlot(mon, slot, catalog)
  local monBefore = copyValue(mon)
  assert(type(monBefore) == "table", "planning copies the pre-evolution mon")
  local staged = copyValue(mon)
  assert(type(staged) == "table", "planning copies the evolved mon")
  staged.species = slot.target
  staged.form = slot.form
  local targetForm = catalog:form(slot.target, slot.form)
  local abilities = assert(targetForm.abilities, "planning reads the target abilities")
  assert(type(abilities) == "table", "target abilities form an array")
  staged.ability = abilities[Personality.abilitySlot(#abilities, mon.personality)]
  local beforeFacts = MonStats.derive(monBefore, catalog)
  local afterFacts = MonStats.derive(staged, catalog)
  local condition = assert(staged.condition, "planning carries the condition record")
  assert(type(condition) == "table", "planning carries the condition record")
  local beforeCondition = assert(monBefore.condition, "planning reads the pre-evolution condition")
  assert(type(beforeCondition) == "table", "planning reads the pre-evolution condition")
  condition.currentHp = MonStats.adjustHpForMaxChange(beforeFacts.maxHp, afterFacts.maxHp, beforeCondition.currentHp)
  local monAfter = Evolution.applyNamePolicy(staged, monBefore)
  -- Retail clears the held item for held-item trade plus the day- and
  -- night-gated evolutions; stone evolutions via bag use leave it alone.
  if slot.method == "trade_item" or slot.method == "item_day" or slot.method == "item_night" then
    monAfter.heldItem = "NONE"
  end
  return {
    monBefore = monBefore,
    monAfter = monAfter,
    inventoryDeltas = {},
    learningOpportunities = Evolution.learningOpportunities(monAfter, catalog),
    canCancel = slot.method ~= "trade" and slot.method ~= "trade_item",
    reason = slot.method,
  }
end

-- Stages the full candidate result for the first matching slot, or nil when
-- nothing matches.
---@param mon table<string, unknown>
---@param context table<string, unknown>
---@param catalog table<string, unknown>
---@return table<string, unknown>?
function Evolution.plan(mon, context, catalog)
  local slot = Evolution.check(mon, context, catalog)
  if slot == nil then
    return nil
  end
  return stageSlot(mon, slot, catalog)
end

return Evolution
