-- Resumable in-battle reward work. Native anchor: pret/pokeheartgold
-- src/battle/battle_command.c Task_GetExp (per-recipient experience and
-- effort, level-up stat recalculation with active-data reload, ordered
-- learn prompts that suspend the battle until each decision is consumed).
-- Experience and effort land once when the work opens; learning then
-- suspends the battle recipient by recipient. Free slots fill silently,
-- full sets wait on an explicit replace/decline reply, stale replies hold
-- the same continuation with no new effects, and restoring from a copied
-- frame completes identically without ever awarding twice. Recipients that
-- gain a level join the evolution-eligibility set for the post-battle
-- owner; nothing evolves mid-battle and no live party is touched.

local BattleErrors = require("libs.battle.src.errors")
local Effort = require("libs.battle.src.gen4.Effort")
local Experience = require("libs.mons.src.gen4.Experience")
local LevelProgression = require("libs.mons.src.gen4.LevelProgression")
local MonStats = require("libs.mons.src.gen4.MonStats")

---@class Progression
local Progression = {}

local EV_STAT_KEYS = { "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }

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

---@param value unknown
---@return boolean
local function isPositiveInt(value)
  return type(value) == "number" and value % 1 == 0 and value >= 1
end

---@param value unknown
---@return boolean
local function isNonNegativeInt(value)
  return type(value) == "number" and value % 1 == 0 and value >= 0
end

---@param mon table<string, unknown>
---@return integer
local function currentHealth(mon)
  if type(mon.hp) == "number" then
    assert(mon.hp % 1 == 0 and mon.hp >= 0, "battle-owned health stays a non-negative integer")
    return mon.hp
  end
  local condition = mon.condition
  assert(type(condition) == "table", "reward work reads current health from the battle copy or its condition")
  assert(
    type(condition.currentHp) == "number" and condition.currentHp % 1 == 0 and condition.currentHp >= 0,
    "condition health stays a non-negative integer"
  )
  return condition.currentHp
end

---@param mon table<string, unknown>
---@param catalog table<string, unknown>
---@return integer
local function currentLevel(mon, catalog)
  local species = catalog:species(mon.species)
  return Experience.level(catalog:growthCurve(species.growthCurve), mon.experience)
end

---@param mon table<string, unknown>
---@param move string
---@return boolean
local function knowsMove(mon, move)
  for _, entry in ipairs(mon.moves) do
    if type(entry) == "table" and entry.move == move then
      return true
    end
  end
  return false
end

---@param evAward table<string, unknown>
---@return table<string, integer>
local function normalizeEvAward(evAward)
  assert(type(evAward) == "table", "reward entries carry an effort award record")
  local normalized = { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 }
  for key, value in pairs(evAward) do
    local known = false
    for _, stat in ipairs(EV_STAT_KEYS) do
      if key == stat then
        known = true
        break
      end
    end
    assert(known, "effort awards name only the six native stats")
    assert(isNonNegativeInt(value), "effort awards stay non-negative integers")
    normalized[key] = value
  end
  return normalized
end

---@param input table<string, unknown>
local function checkStartInput(input)
  assert(type(input) == "table", "reward work opens from an input record")
  assert(type(input.defeated) == "table", "reward work names the defeated entry")
  assert(isPositiveInt(input.defeated.combatant), "reward work names the defeated combatant")
  assert(isPositiveInt(input.defeated.activation), "reward work pins the defeated entry token")
  assert(type(input.entries) == "table", "reward work reads the recipient entry array")
  assert(input.catalog ~= nil, "reward work needs a catalog for levels, stats, and base power points")
  for index, entry in ipairs(input.entries) do
    assert(type(entry) == "table", "reward entries are records")
    assert(isPositiveInt(entry.combatant), "reward entry " .. index .. " names its combatant")
    assert(type(entry.mon) == "table", "reward entry " .. index .. " carries its battle-owned mon")
    assert(isNonNegativeInt(entry.expAward), "reward entry " .. index .. " carries a non-negative experience award")
    normalizeEvAward(entry.evAward)
  end
end

---@param mon table<string, unknown>
---@return table<string, { move: string, pp: integer, ppUps: integer }>
local function slotViews(mon)
  assert(type(mon.moves) == "table", "learning prompts read the move set")
  local views = {}
  for _, entry in ipairs(mon.moves) do
    assert(type(entry) == "table", "move slots are records")
    views[#views + 1] = { move = entry.move, pp = entry.pp, ppUps = entry.ppUps }
  end
  return views
end

--- Opens reward work for one knockout: experience and effort land exactly
--- once per eligible entry, levels resolve with ordered learning chances,
--- and living health tracks the recalculated maximum the way the source
--- stat recalculation does. The frame carries every cursor needed to
--- finish; the flow carries the detached battle-owned mons.
---@param input table<string, unknown>
---@return { flow: table<string, unknown>, frame: table<string, unknown> }
function Progression.start(input)
  checkStartInput(input)
  local catalog = input.catalog
  local mons = {}
  local recipients = {}
  local evolutionEligible = {}
  for index, entry in ipairs(input.entries) do
    local mon = copyValue(entry.mon)
    assert(type(mon) == "table", "reward entries detach their mon")
    local health = currentHealth(mon)
    local level = currentLevel(mon, catalog)
    local eligible = mon.isEgg ~= true and health > 0 and level < 100
    local applied = 0
    local crossed = {}
    local opportunities = {}
    local maxHpBefore = MonStats.derive(mon, catalog).maxHp
    local maxHpAfter = maxHpBefore
    if eligible then
      local result = LevelProgression.award(mon, entry.expAward, catalog)
      mon = result.mon
      applied = entry.expAward
      crossed = result.crossedLevels
      opportunities = result.learningOpportunities
      maxHpAfter = result.maxHpAfter
      mon.evs = Effort.apply(mon.evs, normalizeEvAward(entry.evAward), {
        fainted = false,
        isEgg = false,
        level = level,
      })
      mon.hp = MonStats.adjustHpForMaxChange(maxHpBefore, maxHpAfter, health)
      if #crossed > 0 then
        evolutionEligible[#evolutionEligible + 1] = entry.combatant
      end
    end
    mons[#mons + 1] = mon
    recipients[#recipients + 1] = {
      combatant = entry.combatant,
      monIndex = index,
      opportunities = opportunities,
      cursor = 1,
      touched = false,
      expAward = applied,
      maxHpBefore = maxHpBefore,
      maxHpAfter = maxHpAfter,
    }
  end
  local defeated = { combatant = input.defeated.combatant, activation = input.defeated.activation }
  local flow = { mons = mons, catalog = catalog, evolutionEligible = evolutionEligible }
  local frame =
    { kind = "progression", defeated = defeated, recipients = recipients, recipientIndex = 1, pending = nil }
  return { flow = flow, frame = frame }
end

---@param opportunity unknown
---@param what string
local function checkOpportunity(opportunity, what)
  assert(type(opportunity) == "table", what .. " carries learning chances")
  assert(isPositiveInt(opportunity.level), what .. " learning chances name their level")
  assert(type(opportunity.move) == "string" and opportunity.move ~= "", what .. " learning chances name a move")
end

--- Validates a reward frame without mutating it.
---@param frame table<string, unknown>
---@return table<string, unknown>
function Progression.validateFrame(frame)
  assert(type(frame) == "table", "reward frames are records")
  assert(frame.kind == "progression", "reward frames carry the progression identity")
  assert(type(frame.defeated) == "table", "reward frames name the defeated entry")
  assert(isPositiveInt(frame.defeated.combatant), "reward frames name the defeated combatant")
  assert(isPositiveInt(frame.defeated.activation), "reward frames pin the defeated entry token")
  assert(type(frame.recipients) == "table", "reward frames carry the recipient array")
  for index, recipient in ipairs(frame.recipients) do
    local what = "reward recipient " .. index
    assert(type(recipient) == "table", what .. " is a record")
    assert(isPositiveInt(recipient.combatant), what .. " names its combatant")
    assert(isPositiveInt(recipient.monIndex), what .. " names its battle-owned mon")
    assert(type(recipient.opportunities) == "table", what .. " carries learning chances")
    for _, opportunity in ipairs(recipient.opportunities) do
      checkOpportunity(opportunity, what)
    end
    assert(
      isPositiveInt(recipient.cursor) and recipient.cursor <= #recipient.opportunities + 1,
      what .. " names the learning cursor within its chances"
    )
    assert(type(recipient.touched) == "boolean", what .. " records whether its facts were reported")
    assert(isNonNegativeInt(recipient.expAward), what .. " records its landed experience")
    assert(isPositiveInt(recipient.maxHpBefore), what .. " records its previous maximum")
    assert(isPositiveInt(recipient.maxHpAfter), what .. " records its recalculated maximum")
  end
  assert(
    isPositiveInt(frame.recipientIndex) and frame.recipientIndex <= #frame.recipients + 1,
    "reward frames name the recipient cursor within their recipients"
  )
  if frame.pending ~= nil then
    assert(type(frame.pending) == "table", "reward prompts are records")
    assert(isPositiveInt(frame.pending.combatant), "reward prompts name their recipient")
    assert(type(frame.pending.move) == "string" and frame.pending.move ~= "", "reward prompts name a move")
  end
  return frame
end

---@param flow table<string, unknown>
local function checkFlow(flow)
  assert(type(flow) == "table", "reward steps read the flow")
  assert(type(flow.mons) == "table", "reward steps read the battle-owned mons")
  assert(flow.catalog ~= nil, "reward steps need the flow catalog for base power points")
end

---@param recipient table<string, unknown>
---@return table<string, unknown>
local function copyRecipient(recipient)
  return {
    combatant = recipient.combatant,
    monIndex = recipient.monIndex,
    opportunities = recipient.opportunities,
    cursor = recipient.cursor,
    touched = recipient.touched,
    expAward = recipient.expAward,
    maxHpBefore = recipient.maxHpBefore,
    maxHpAfter = recipient.maxHpAfter,
  }
end

---@param mon table<string, unknown>
---@param combatant integer
---@param move string
---@return table<string, unknown>
local function learningRequest(mon, combatant, move)
  return {
    kind = "learn_move",
    combatant = combatant,
    incomingMove = move,
    currentMoves = slotViews(mon),
    canDecline = true,
  }
end

--- Validates a matched learning reply, returning the decided action and,
--- for replacements, the validated zero-based slot. Anything else is a
--- typed input error with no state touched.
---@param reply table<string, unknown>
---@return string, integer?
local function checkReply(reply)
  local decision = reply.decision
  if decision ~= "replace" and decision ~= "decline" then
    error(BattleErrors.input("learning replies decide replace or decline", { decision = decision }))
  end
  assert(type(decision) == "string", "learning replies decide replace or decline")
  if decision == "decline" then
    return decision, nil
  end
  local slot = reply.slot
  if type(slot) ~= "number" or slot % 1 ~= 0 then
    error(BattleErrors.input("replacements name a zero-based move slot", { slot = slot }))
  end
  assert(type(slot) == "number", "replacement slots validate before use")
  return decision, slot
end

--- Advances reward work: reports each recipient facts once, fills free
--- slots silently, and otherwise pauses on the ordered learning prompt
--- until its decision is consumed. A consumed decision lands exactly
--- once; a missing or mismatched reply holds the same continuation with
--- no new effects.
---@param flow table<string, unknown>
---@param frame table<string, unknown>
---@param reply table<string, unknown>?
---@return table<string, unknown>
function Progression.step(flow, frame, reply)
  checkFlow(flow)
  Progression.validateFrame(frame)
  local catalog = flow.catalog
  local recipients = {}
  for _, recipient in ipairs(frame.recipients) do
    recipients[#recipients + 1] = copyRecipient(recipient)
  end
  local defeated = { combatant = frame.defeated.combatant, activation = frame.defeated.activation }
  local events = {}
  local index = frame.recipientIndex
  local pending = nil
  if frame.pending ~= nil then
    pending = { combatant = frame.pending.combatant, move = frame.pending.move }
  end

  local function monFor(recipient)
    local mon = flow.mons[recipient.monIndex]
    assert(type(mon) == "table", "reward recipients name a battle-owned mon")
    return mon
  end

  local function reportFacts(recipient)
    if recipient.touched then
      return
    end
    recipient.touched = true
    events[#events + 1] = { kind = "exp", combatant = recipient.combatant, gained = recipient.expAward }
    events[#events + 1] = {
      kind = "stats",
      combatant = recipient.combatant,
      maxHpBefore = recipient.maxHpBefore,
      maxHpAfter = recipient.maxHpAfter,
    }
  end

  if pending ~= nil then
    local recipient = recipients[index]
    assert(recipient ~= nil, "an outstanding prompt names a live recipient")
    assert(recipient.combatant == pending.combatant, "an outstanding prompt names its recipient")
    if type(reply) == "table" and reply.combatant == pending.combatant then
      local decision, slot = checkReply(reply)
      local mon = monFor(recipient)
      if decision == "replace" then
        assert(slot ~= nil, "replacements validated their slot")
        if slot >= #mon.moves then
          error(BattleErrors.input("replacements name a held zero-based move slot", { slot = slot }))
        end
        flow.mons[recipient.monIndex] = LevelProgression.replace(mon, slot, pending.move, catalog)
        events[#events + 1] = { kind = "learn", combatant = recipient.combatant, move = pending.move }
      else
        LevelProgression.decline(mon, pending.move)
        events[#events + 1] = { kind = "declined", combatant = recipient.combatant, move = pending.move }
      end
      recipient.cursor = recipient.cursor + 1
      pending = nil
    end
  end

  local request = nil
  if pending == nil then
    while index <= #recipients do
      local recipient = recipients[index]
      local mon = monFor(recipient)
      while
        recipient.cursor <= #recipient.opportunities and knowsMove(mon, recipient.opportunities[recipient.cursor].move)
      do
        recipient.cursor = recipient.cursor + 1
      end
      reportFacts(recipient)
      if recipient.cursor > #recipient.opportunities then
        index = index + 1
      elseif #mon.moves < 4 then
        local opportunity = recipient.opportunities[recipient.cursor]
        local filled = LevelProgression.learn(mon, opportunity.move, catalog)
        assert(filled.applied, "a free slot accepts the learned move")
        flow.mons[recipient.monIndex] = filled.mon
        events[#events + 1] = { kind = "learn", combatant = recipient.combatant, move = opportunity.move }
        recipient.cursor = recipient.cursor + 1
      else
        local opportunity = recipient.opportunities[recipient.cursor]
        pending = { combatant = recipient.combatant, move = opportunity.move }
        request = learningRequest(mon, recipient.combatant, opportunity.move)
        break
      end
    end
  else
    local recipient = recipients[index]
    request = learningRequest(monFor(recipient), recipient.combatant, pending.move)
  end

  local done = request == nil
  local settled = {
    kind = "progression",
    defeated = defeated,
    recipients = recipients,
    recipientIndex = index,
    pending = pending,
  }
  return { done = done, events = events, frame = settled, flow = flow, request = request }
end

return Progression
