-- Kernel-vocabulary coverage for the visible-cue player: every public
-- kernel event kind the native session actually emits receives an
-- intentional presentation (narration, health motion, or an explicit
-- silent accounting treatment) instead of the unknown-effect placeholder.
-- Synthetic packets use the real kernel payload shapes through the real
-- cue player; end-to-end production delivery is owned by the live screen
-- suite with its real completion.

local Assert = require("tests.support.Assert")
local BattleTimeline = require("game.hgss.tests.support.BattleTimelineFixture")

local T = {}

local TICK = 1 / 60

---@param combatant integer
---@param hp integer
---@param maxHp integer
---@return table checkpoint fragment for one combatant
local function checkpoint(combatant, hp, maxHp)
  return {
    activation = combatant,
    controller = combatant == 1 and "player" or "wild",
    experience = 100,
    form = 0,
    hp = hp,
    maxHp = maxHp,
    participant = combatant,
    position = combatant,
    side = combatant == 1 and 1 or 2,
    species = "EEVEE",
  }
end

---@return table detached dynamic view with a full-health player lead and foe
local function openingView()
  local function record(combatant, hp, own)
    return {
      combatant = combatant,
      participant = combatant == 3 and 2 or combatant,
      side = own and 1 or 2,
      controller = own and "player" or "wild",
      active = true,
      hp = hp,
      maxHp = combatant == 1 and 52 or 57,
      species = "EEVEE",
      form = 0,
      name = own and "LEAD" or "FOE",
      level = 20,
      selector = own and "back" or "front",
      moves = own and { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } } or nil,
      experience = 8000,
    }
  end
  return {
    round = 1,
    status = "running",
    own = { record(1, 52, true) },
    foes = { record(3, 57, false) },
    participants = {},
    environment = {},
  }
end

---@param id integer packet identity under test driving
---@param events table ordered sanitized events under test driving
---@param after table detached after view under test driving
---@return table delivery-shaped packet
local function packet(id, events, after)
  return {
    launchId = "vocabulary-probe",
    packetId = id,
    events = events,
    before = openingView(),
    after = after or openingView(),
    request = nil,
    result = nil,
  }
end

---@param kind string kernel event kind under test driving
---@param payload table kernel payload under test driving
---@param afterHp table<integer, integer>? checkpoint health by combatant
---@return table one sanitized event
local function event(kind, payload, afterHp)
  local combatants = {}
  local hp = {}
  for combatant, health in pairs(afterHp or {}) do
    combatants[combatant] = checkpoint(combatant, health, combatant == 1 and 52 or 57)
    hp[combatant] = health
  end
  -- Synthetic emissions carry the same identity facts production
  -- does: the actor behind the cause and the targeted battler resolve
  -- through the event-time views at selection.
  local user = payload.user or payload.combatant
  local target = payload.target or payload.combatant
  return {
    sequence = 1,
    kind = kind,
    cause = { key = "TACKLE" },
    audience = "public",
    actors = { { combatant = type(user) == "number" and user or 1 } },
    targets = { { combatant = type(target) == "number" and target or 3 } },
    payload = payload,
    after = { hp = hp, combatants = combatants },
  }
end

---@param timeline table cue player under test driving
local function drain(timeline)
  for _ = 1, 600 do
    if timeline:settled() then
      return
    end
    timeline:update(TICK, function(_)
      return true
    end)
  end
  error("the cue player never settled", 0)
end

---@param timeline table cue player under test driving
---@return string every narration page shown while draining, joined
local function collectMessages(timeline)
  local seen = {}
  local last = nil
  for _ = 1, 600 do
    local current = timeline:message()
    if current ~= "" and current ~= last then
      seen[#seen + 1] = current
      last = current
    end
    if timeline:settled() then
      return table.concat(seen, "\n")
    end
    timeline:update(TICK, function(_)
      return true
    end)
  end
  error("the cue player never settled", 0)
end

---@param timeline table cue player under test driving
---@param text string forbidden narration fragment
local function assertNoPlaceholder(timeline, text)
  for _, note in ipairs(timeline:diagnostics()) do
    Assert.isTrue(note:find(text, 1, true) == nil, "no diagnostic escapes for ordinary events: " .. tostring(note))
  end
end

function T.missed_attack_narrates_a_miss()
  local timeline = BattleTimeline.new({})
  timeline:reset(openingView())
  local missed = event("missed", { target = 3 }, { [1] = 52, [3] = 57 })
  missed.actors = { { combatant = 1 } }
  timeline:present(packet(1, { missed }))
  local messages = collectMessages(timeline)
  Assert.isTrue(messages:find("miss", 1, true) ~= nil, "a missed attack narrates its miss: " .. messages)
  Assert.isTrue(
    messages:find("unrepresentable", 1, true) == nil,
    "a missed attack never shows the placeholder: " .. messages
  )
  assertNoPlaceholder(timeline, "missed")
end

function T.status_infliction_narrates_its_condition()
  local timeline = BattleTimeline.new({})
  timeline:reset(openingView())
  timeline:present(packet(1, { event("status", { target = 3, key = "poison" }, { [1] = 52, [3] = 57 }) }))
  local messages = collectMessages(timeline)
  Assert.isTrue(messages:find("FOE", 1, true) ~= nil, "the condition names its battler: " .. messages)
  Assert.isTrue(
    messages:find("unrepresentable", 1, true) == nil,
    "a condition never shows the placeholder: " .. messages
  )
  assertNoPlaceholder(timeline, "status")
end

function T.healing_moves_health_without_placeholder()
  local timeline = BattleTimeline.new({})
  local hurt = openingView()
  hurt.own[1].hp = 20
  timeline:reset(hurt)
  timeline:present(packet(1, { event("healed", { target = 1, restored = 10 }, { [1] = 30, [3] = 57 }) }))
  drain(timeline)
  local shown = nil
  for _, battler in ipairs(timeline:battlers()) do
    if battler.combatant == 1 then
      shown = battler
    end
  end
  Assert.notNil(shown, "the healed battler still plays")
  Assert.equal(shown.hp, 30, "healing animates toward its checkpoint")
  assertNoPlaceholder(timeline, "healed")
end

function T.residual_tick_damages_with_a_message()
  local timeline = BattleTimeline.new({})
  timeline:reset(openingView())
  timeline:present(packet(1, { event("tick", { combatant = 1, key = "poison", amount = 6 }, { [1] = 46, [3] = 57 }) }))
  local messages = collectMessages(timeline)
  Assert.isTrue(messages:find("LEAD", 1, true) ~= nil, "residual damage names its battler: " .. messages)
  Assert.isTrue(
    messages:find("unrepresentable", 1, true) == nil,
    "residual damage never shows the placeholder: " .. messages
  )
  local shown = nil
  for _, battler in ipairs(timeline:battlers()) do
    if battler.combatant == 1 then
      shown = battler
    end
  end
  Assert.notNil(shown, "the damaged battler still plays")
  Assert.equal(shown.hp, 46, "residual damage animates toward its checkpoint")
  assertNoPlaceholder(timeline, "tick")
end

function T.self_inflicted_faint_hides_its_battler()
  local timeline = BattleTimeline.new({})
  timeline:reset(openingView())
  timeline:present(packet(1, { event("fainted", { target = 1 }, { [1] = 0, [3] = 57 }) }))
  local messages = collectMessages(timeline)
  Assert.isTrue(messages:find("LEAD", 1, true) ~= nil, "the faint names its battler: " .. messages)
  Assert.isTrue(
    messages:find("unrepresentable", 1, true) == nil,
    "a self-inflicted faint never shows the placeholder: " .. messages
  )
  local shown = nil
  for _, battler in ipairs(timeline:battlers()) do
    if battler.combatant == 1 then
      shown = battler
    end
  end
  Assert.notNil(shown, "the fainted battler still plays")
  Assert.isFalse(shown.visible, "a self-inflicted faint hides its battler")
  assertNoPlaceholder(timeline, "fainted")
end

function T.replacement_switch_reveals_its_arrival()
  local timeline = BattleTimeline.new({})
  timeline:reset(openingView())
  local after = openingView()
  after.own = {
    {
      combatant = 1,
      participant = 1,
      side = 1,
      controller = "player",
      active = false,
      hp = 0,
      maxHp = 52,
      species = "EEVEE",
      form = 0,
      name = "LEAD",
      level = 20,
      selector = "back",
      moves = { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } },
      experience = 8000,
    },
    {
      combatant = 2,
      participant = 1,
      side = 1,
      controller = "player",
      active = true,
      hp = 40,
      maxHp = 40,
      species = "EEVEE",
      form = 0,
      name = "RESERVE",
      level = 18,
      selector = "back",
      moves = { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } },
      experience = 7000,
    },
  }
  timeline:present(packet(1, { event("switch", { position = 1, from = 1, to = 2 }, { [1] = 0, [3] = 57 }) }, after))
  drain(timeline)
  -- The screen reconciles against timeline order, which the reveal cue
  -- already extended with the arrival.
  local known = {}
  for _, id in ipairs(timeline:order()) do
    known[id] = true
  end
  for _, group in ipairs({ after.own, after.foes }) do
    for _, record in ipairs(group) do
      timeline:reconcileBattler(record, known[record.combatant] == true)
    end
  end
  drain(timeline)
  local states = {}
  for _, battler in ipairs(timeline:battlers()) do
    states[battler.combatant] = battler.visible
  end
  Assert.isFalse(states[1], "the departed battler stays hidden")
  Assert.isTrue(states[2] == true, "the replacement reveals once its cue drains")
  assertNoPlaceholder(timeline, "switch")
end

function T.accounting_events_stay_silent()
  local timeline = BattleTimeline.new({})
  timeline:reset(openingView())
  timeline:present(packet(1, {
    event("acknowledge", {}, { [1] = 52, [3] = 57 }),
    event("join", { position = 1, combatant = 2, activation = 9 }, { [1] = 52, [3] = 57 }),
  }))
  drain(timeline)
  Assert.equal(timeline:message(), "", "accounting events narrate nothing")
  Assert.equal(#timeline:diagnostics(), 0, "accounting events record no diagnostics")
end

function T.status_gate_block_and_release_narrate_their_moment()
  local timeline = BattleTimeline.new({})
  timeline:reset(openingView())
  timeline:present(packet(1, {
    event("status-gate", { combatant = 3, key = "paralysis", outcome = "blocked" }, { [1] = 52, [3] = 57 }),
    event("status-gate", { combatant = 3, key = "sleep", outcome = "woke" }, { [1] = 52, [3] = 57 }),
  }))
  local messages = collectMessages(timeline)
  Assert.isTrue(messages:find("paralyzed", 1, true) ~= nil, "the gate names its block: " .. messages)
  Assert.isTrue(messages:find("woke up", 1, true) ~= nil, "the release narrates: " .. messages)
  assertNoPlaceholder(timeline, "status-gate")
end

function T.forcing_and_item_intents_stay_silent_until_their_result()
  local timeline = BattleTimeline.new({})
  timeline:reset(openingView())
  local roar = event("switch-intent", { target = 1 }, { [1] = 52, [3] = 57 })
  roar.cause = { key = "ROAR" }
  local trick = event("item-intent", { target = 1 }, { [1] = 52, [3] = 57 })
  trick.cause = { key = "TRICK" }
  timeline:present(packet(1, { roar, trick }))
  local messages = collectMessages(timeline)
  Assert.equal(messages, "", "intent narration belongs to the following source result")
  assertNoPlaceholder(timeline, "intent")
end

function T.broken_substitutes_narrate()
  local timeline = BattleTimeline.new({})
  timeline:reset(openingView())
  timeline:present(packet(1, { event("substitute-broke", { target = 3 }, { [1] = 52, [3] = 57 }) }))
  local messages = collectMessages(timeline)
  Assert.isTrue(messages:find("substitute", 1, true) ~= nil, "the break narrates: " .. messages)
  assertNoPlaceholder(timeline, "substitute")
end

function T.move_use_announces_its_user()
  local timeline = BattleTimeline.new({})
  timeline:reset(openingView())
  local used = event("move-used", { user = 3 }, { [1] = 52, [3] = 57 })
  used.cause = { key = "TAIL_WHIP" }
  timeline:present(packet(1, { used }))
  local messages = collectMessages(timeline)
  Assert.isTrue(messages:find("FOE", 1, true) ~= nil, "the move use names its user: " .. messages)
  Assert.isTrue(
    messages:find("unrepresentable", 1, true) == nil,
    "a move use never shows the placeholder: " .. messages
  )
  assertNoPlaceholder(timeline, "move-used")
end

return { tests = T }
