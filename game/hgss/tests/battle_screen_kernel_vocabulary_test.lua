-- Kernel-vocabulary coverage for the visible-cue player: every public
-- kernel event kind the native session actually emits receives an
-- intentional presentation (narration, health motion, or an explicit
-- silent accounting treatment) instead of the unknown-effect placeholder.
-- Synthetic packets use the real kernel payload shapes; the closing
-- scenario drives a real runtime and screen through an ordinary turn.

local Assert = require("tests.support.Assert")
local BattleTimeline = require("game.hgss.src.battle.BattleTimeline")

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
  return {
    sequence = 1,
    kind = kind,
    cause = { key = "TACKLE" },
    audience = "public",
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
  timeline:present(packet(1, { event("missed", { target = 3 }, { [1] = 52, [3] = 57 }) }))
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
  timeline:present(
    packet(1, { event("tick", { combatant = 1, key = "poison", amount = 6 }, { [1] = 46, [3] = 57 }) })
  )
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

function T.forcing_and_item_moves_hit_their_target()
  local timeline = BattleTimeline.new({})
  timeline:reset(openingView())
  local roar = event("switch-intent", { target = 1 }, { [1] = 52, [3] = 57 })
  roar.cause = { key = "ROAR" }
  local trick = event("item-intent", { target = 1 }, { [1] = 52, [3] = 57 })
  trick.cause = { key = "TRICK" }
  timeline:present(packet(1, { roar, trick }))
  local messages = collectMessages(timeline)
  Assert.isTrue(messages:find("LEAD", 1, true) ~= nil, "the intents name their target: " .. messages)
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

---@param record table<string, unknown> full mon-domain record under test preparation
---@return table<string, unknown> the same record striking with the requested moves
local function movesOnly(record, moves)
  record.moves = moves
  return record --[[@as table<string, unknown>]]
end

---@param species string catalog species key under test preparation
---@param level integer battle level under test preparation
---@param seed integer fixed generator state under test preparation
---@return table full mon-domain record
local function vocabularyFoe(species, level, seed)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(seed, catalog)
  return movesOnly(factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level })), {
    { move = "TAIL_WHIP", pp = 30, ppUps = 0 },
  })
end

---@param spec table lead/reserve description under test preparation
---@return table live party owner holding the described pair
local function vocabularyParty(leadSpec, reserveSpec)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  local Lcrng = require("libs.mons.src.gen4.Lcrng")
  local MonsSave = require("libs.mons.src.MonsSave")
  local Party = require("libs.mons.src.Party")
  local catalog = CatalogFixture.makeCatalog()
  local owner = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x22222222):capture()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
    mapSection = 7,
    date = CatalogFixture.metDate(),
  })
  for _, member in ipairs({ leadSpec, reserveSpec }) do
    local factory = CatalogFixture.makeFactory(member.seed, catalog)
    local record =
      movesOnly(factory:createNormal(CatalogFixture.normalRequest({ species = member.species, level = member.level })), {
        { move = "TACKLE", pp = 35, ppUps = 0 },
      })
    Assert.isTrue(owner:addMon(record), "the vocabulary path needs its live party member")
  end
  return owner
end

-- A real wild battle end to end through the real cue player: every
-- kernel event kind the turn actually emits receives an intentional
-- presentation, so ordinary play never types out the placeholder.
function T.ordinary_production_turns_never_show_the_placeholder()
  local HgssBagService = require("libs.hgss.src.items.HgssBagService")
  local ItemFixture = require("libs.items.tests.item_fixture")
  local ScenarioFactory = require("libs.hgss.src.battle.HgssBattleScenarioFactory")
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local BattleRuntime = require("game.hgss.src.battle.BattleRuntime")
  local party = vocabularyParty(
    { species = "EEVEE", level = 12, seed = 0x11111111 },
    { species = "EEVEE", level = 12, seed = 0x22222222 }
  )
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local launch = {
    id = "launch-kernel-vocabulary",
    kind = "wild",
    payload = {
      attemptId = "launch-kernel-vocabulary-attempt",
      species = "EEVEE",
      form = 0,
      level = 5,
      personality = 1,
      ability = "RUN_AWAY",
    },
  }
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launch.id .. "-attempt", mon = vocabularyFoe("EEVEE", 5, 0x33333333) },
    { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  local record = { packets = {} }
  local port = {
    enter = function(_plan)
      return true
    end,
    present = function(packet)
      record.packets[#record.packets + 1] = packet
    end,
    ready = function()
      return true
    end,
    leave = function(_plan)
      return true
    end,
    dispose = function() end,
  }
  local battle = BattleRuntime.new({
    request = launch,
    scenario = scenario,
    party = party,
    bag = bag,
    presentation = port,
    seed = 0x12345678,
  })
  for _ = 1, 1200 do
    battle:update()
    local current = battle:status()
    Assert.isTrue(current.phase ~= "failed", "the vocabulary battle never fails")
    if current.phase == "running" and current.request ~= nil then
      local addressed = assert(current.request.actors[1], "every vocabulary decision addresses its combatant")
      local ok, err = battle:submit(SessionFixture.replyFor(current.request, {
        SessionFixture.attackChoice(addressed, 0, SessionFixture.positionTarget(2)),
      }))
      Assert.isTrue(ok, "the vocabulary lead keeps striking: " .. tostring(err))
    end
    if current.phase == "complete" then
      break
    end
  end
  Assert.isTrue(#record.packets > 0, "the vocabulary battle delivers packets")
  local seenKinds = {}
  for _, packetRecord in ipairs(record.packets) do
    for _, event in ipairs(packetRecord.events) do
      seenKinds[event.kind] = true
    end
  end
  Assert.isTrue(seenKinds["struck"] == true, "the vocabulary battle really strikes")
  Assert.isTrue(seenKinds["move-used"] == true, "the foe really uses its stage move")
  Assert.isTrue(seenKinds["stage"] == true, "the stage move really stages")
  local timeline = BattleTimeline.new({})
  timeline:reset(record.packets[1].before)
  local messages = {}
  local last = nil
  for _, packetRecord in ipairs(record.packets) do
    Assert.isTrue(timeline:present(packetRecord), "every production packet plays once")
    for _ = 1, 3600 do
      local current = timeline:message()
      if current ~= "" and current ~= last then
        messages[#messages + 1] = current
        last = current
      end
      if timeline:settled() then
        break
      end
      timeline:update(TICK, function(_)
        return true
      end)
    end
    Assert.isTrue(timeline:settled(), "every production packet drains")
  end
  local shown = table.concat(messages, "\n")
  Assert.isTrue(
    shown:find("unrepresentable", 1, true) == nil,
    "ordinary production narration never shows the placeholder: " .. shown
  )
  Assert.equal(#timeline:diagnostics(), 0, "ordinary production events record no diagnostics")
end

return { tests = T }
