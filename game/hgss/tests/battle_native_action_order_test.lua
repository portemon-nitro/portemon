-- Frozen acceptance for ordered native action playback through the cue
-- player: one action occurrence narrates its attack once however many
-- hits it lands, checkpoints apply in order, one-shot sounds never repeat
-- from polling, and the visual execution runs through the battle
-- animation player. Native mechanism: the controller tasks order attack
-- narration before per-hit updates while BtlCmd_Wait holds on outstanding
-- controller work rather than fixed host time
-- (src/battle/battle_command.c). Headless: hand-built delivery-shaped
-- packets drive the real cue player; no dump capability is needed. The
-- setup guards below are green on the current boundary; the ordering and
-- player gates stay red until the native playback lands.

local Assert = require("tests.support.Assert")
local BattlePresentationModel = require("game.hgss.src.battle.BattlePresentationModel")
local BattleTimeline = require("game.hgss.tests.support.BattleTimelineFixture")

local T = {}
local TICK = 1 / 30

---@return table recording sound-intent sink
local function sink()
  local records = { played = {} }
  function records.sound(name)
    records.played[#records.played + 1] = name
  end
  return records
end

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
  local function entry(combatant, hp, maxHp, own)
    return {
      combatant = combatant,
      participant = combatant,
      side = own and 1 or 2,
      controller = own and "player" or "wild",
      active = true,
      position = combatant,
      activation = combatant,
      hp = hp,
      maxHp = maxHp,
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
    own = { entry(1, 52, 52, true) },
    foes = { entry(3, 57, 57, false) },
    participants = {},
  }
end

---@param sequence integer
---@param foeHp integer foe health after this hit
---@return table one sanitized strike event for the shared attack occurrence
local function strikeEvent(sequence, foeHp)
  local combatants = {
    [1] = checkpoint(1, 52, 52),
    [3] = checkpoint(3, foeHp, 57),
  }
  return {
    sequence = sequence,
    kind = "struck",
    cause = { key = "TACKLE" },
    audience = "public",
    actors = { { combatant = 1 } },
    targets = { { combatant = 3 } },
    move = { executed = "TACKLE" },
    payload = { target = 3, damage = 14, hitIndex = sequence },
    after = { hp = { [1] = 52, [3] = foeHp }, combatants = combatants },
  }
end

---@param id integer
---@param events table
---@param foeHp integer final foe health for the after view
---@return table delivery-shaped action packet
local function actionPacket(id, events, foeHp)
  local after = openingView()
  after.foes[1].hp = foeHp
  return {
    launchId = "action-order-probe",
    packetId = id,
    events = events,
    before = openingView(),
    after = after,
    request = nil,
    result = nil,
  }
end

---@param timeline table cue player under test driving
---@return table ordered fully revealed narration texts
local function collectMessages(timeline)
  local seen = {}
  local texts = {}
  for _ = 1, 3000 do
    timeline:update(TICK, function(_)
      return true
    end)
    local id = timeline:messageId()
    if id ~= 0 and seen[id] == nil and timeline:ack() then
      seen[id] = true
      texts[#texts + 1] = timeline:message()
    end
    if timeline:settled() then
      break
    end
  end
  return texts
end

---@param texts table
---@param needle string
---@return integer occurrences of the needle across collected narration
local function countContaining(texts, needle)
  local total = 0
  for _, text in ipairs(texts) do
    if tostring(text):find(needle, 1, true) ~= nil then
      total = total + 1
    end
  end
  return total
end

---@param battlers table displayed battler facts under inspection
---@param combatant integer
---@return table the displayed facts for one combatant
local function battler(battlers, combatant)
  for _, entry in ipairs(battlers) do
    if entry.combatant == combatant then
      return entry
    end
  end
  error("no displayed battler " .. tostring(combatant), 0)
end

function T.single_strike_narrates_its_attack_once_then_moves_health()
  local timeline = BattleTimeline.new({})
  timeline:reset(openingView())
  Assert.isTrue(timeline:present(actionPacket(1, { strikeEvent(1, 43) }, 43)), "the strike packet is accepted")
  local texts = collectMessages(timeline)
  Assert.isTrue(timeline:settled(), "the strike drains fully")
  Assert.equal(countContaining(texts, "used Tackle"), 1, "the attack narration plays exactly once")
  Assert.equal(battler(timeline:battlers(), 3).hp, 43, "the exact final health applies at completion")
  Assert.equal(battler(timeline:battlers(), 1).hp, 52, "untouched health never moves")
end

function T.repeated_action_delivery_replays_nothing()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(name)
      sounds.sound(name)
    end,
  })
  timeline:reset(openingView())
  Assert.isTrue(timeline:present(actionPacket(1, { strikeEvent(1, 43) }, 43)), "the first packet is accepted")
  collectMessages(timeline)
  local played = #sounds.played
  Assert.isFalse(
    timeline:present(actionPacket(1, { strikeEvent(1, 43) }, 43)),
    "the repeated packet identity is rejected"
  )
  collectMessages(timeline)
  Assert.equal(#sounds.played, played, "polling and repeats emit no further one-shot sound")
end

function T.multi_hit_occurrence_narrates_its_attack_once()
  local timeline = BattleTimeline.new({})
  timeline:reset(openingView())
  Assert.isTrue(
    timeline:present(actionPacket(1, { strikeEvent(1, 43), strikeEvent(2, 30) }, 30)),
    "the two-hit packet is accepted"
  )
  local texts = collectMessages(timeline)
  Assert.isTrue(timeline:settled(), "both hits drain fully")
  Assert.equal(countContaining(texts, "used Tackle"), 1, "one attack occurrence narrates once across both hits")
  Assert.equal(battler(timeline:battlers(), 3).hp, 30, "both hit checkpoints apply in order")
end

function T.attack_animation_runs_through_the_animation_player()
  local ok, Player = pcall(require, "libs.hgss.src.presentation.BattleAnimationPlayer")
  Assert.isTrue(ok, "the battle animation player resolves through the presentation boundary")
  Assert.notNil(Player, "the animation player loads")
end

-- Strike narration precedes the visual through the real kernel session:
-- two genuine Tackle actions each announce once, each admits exactly one
-- visual only after its own announcement is readable, and neither hit
-- checkpoint moves ahead of its unfinished visual. The recording native
-- collaborator stays pending until the test releases each handle in turn,
-- so the trace proves per-action completion gating instead of a single
-- global hold.
local ORDER_KERNEL_FORMAT = "test:native-format"
local ORDER_KERNEL_SEED = 0x1BADB002

local function orderKernelExecutor()
  local SessionFixture = require("libs.battle.tests.session_fixture")
  return SessionFixture.requirePresent(
    "libs.battle.src.gen4.HgssSessionExecutor",
    "the private native lifecycle owns HGSS ruleset sessions"
  )
end

local function orderKernelContent()
  local ContentBuilder = require("libs.content.src.ContentBuilder")
  local BattleBehaviorBuilder = require("libs.battle.src.BattleBehaviorBuilder")
  local BattleContent = require("libs.battle.src.BattleContent")
  local NativeTypeChart = require("libs.battle.src.gen4.NativeTypeChart")
  local Executor = orderKernelExecutor()
  local builder = ContentBuilder.new()
  NativeTypeChart.install(builder, "strike-order-tests")
  local behaviors = BattleBehaviorBuilder.new()
  behaviors:registerRuleset(
    Executor.RULESET,
    { key = Executor.RULESET, chart = Executor.RULESET },
    "strike-order-tests"
  )
  behaviors:registerFormat(ORDER_KERNEL_FORMAT, { key = ORDER_KERNEL_FORMAT }, "strike-order-tests")
  return BattleContent.new(builder:freeze(), behaviors:freeze())
end

local function orderKernelMoveFacts()
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  return { TACKLE = CatalogFixture.makeCatalog():move("TACKLE") }
end

local function orderKernelSpeciesFacts(seeds)
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local catalog = CatalogFixture.makeCatalog()
  local facts = {}
  for _, seed in ipairs(seeds) do
    local mon = seed.mon
    local bucket = facts[mon.species] or {}
    facts[mon.species] = bucket
    bucket[mon.form] = {
      baseStats = catalog:form(mon.species, mon.form).baseStats,
      growthCurve = catalog:growthCurve(catalog:species(mon.species).growthCurve),
      types = { "normal" },
      levelUpMoves = {},
      baseExpYield = 100,
      evYield = {},
    }
  end
  return facts
end

local function orderTimelineView()
  return {
    own = {
      {
        combatant = 1,
        side = 1,
        controller = "alpha",
        active = true,
        position = 1,
        activation = 1,
        hp = 100,
        maxHp = 100,
        species = "EEVEE",
        form = 0,
        name = "LEAD",
        level = 20,
        moves = { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } },
      },
    },
    foes = {
      {
        combatant = 2,
        side = 2,
        controller = "beta",
        active = true,
        position = 2,
        activation = 2,
        hp = 100,
        maxHp = 100,
        species = "EEVEE",
        form = 0,
        name = "FOE",
        level = 20,
      },
    },
  }
end

function T.strike_announcement_precedes_visual_and_checkpoint()
  local SessionFixture = require("libs.battle.tests.session_fixture")
  local contracts = SessionFixture.sessionContracts()
  local content = orderKernelContent()
  local function scripted(id, seed)
    local entry = SessionFixture.combatant(id, seed)
    entry.mon.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
    return entry
  end
  local alpha = scripted(1, 11)
  local beta = scripted(2, 31)
  local Executor = orderKernelExecutor()
  local scenario = {
    ruleset = Executor.RULESET,
    format = ORDER_KERNEL_FORMAT,
    sides = { SessionFixture.side(1, { 1 }), SessionFixture.side(2, { 2 }) },
    participants = {
      SessionFixture.participant(1, 1, "alpha", { alpha }),
      SessionFixture.participant(2, 2, "beta", { beta }),
    },
    positions = {
      SessionFixture.position(1, 1, { 1 }, alpha.id),
      SessionFixture.position(2, 2, { 2 }, beta.id),
    },
    inventories = {},
    environment = { weather = "none" },
    random = { seed = ORDER_KERNEL_SEED },
    formatState = {},
    moveFacts = orderKernelMoveFacts(),
    speciesFacts = orderKernelSpeciesFacts({ alpha, beta }),
  }
  local session = contracts.Battle.newSession(scenario, content)
  local frame = SessionFixture.driveUntilSettled(session)
  Assert.equal(frame.status, "waiting", "the strike turn opens its decision batch")
  for _, request in ipairs(frame.request.requests) do
    local choices = {}
    for _, actor in ipairs(request.actors) do
      if request.controller == "alpha" then
        choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(2))
      else
        choices[#choices + 1] = SessionFixture.attackChoice(actor, 0, SessionFixture.positionTarget(1))
      end
    end
    local ok, err = session:submit(SessionFixture.replyFor(request, choices))
    Assert.isTrue(ok, "strike turn replies are accepted")
    Assert.isNil(err, "accepted strike replies carry no input error")
  end
  local events = {}
  for _ = 1, 64 do
    frame = session:advance()
    Assert.notNil(frame, "advance returns a battle frame")
    if frame.events ~= nil then
      for _, event in ipairs(frame.events) do
        events[#events + 1] = event
      end
    end
    if frame.status ~= "running" then
      break
    end
  end
  session:dispose()
  local struckByAction = {}
  for _, event in ipairs(events) do
    if event.kind == "struck" then
      Assert.equal(event.effectKey, "TACKLE", "the genuine hit selects its own visual route")
      struckByAction[event.actionId] = event
    end
  end
  local actionCount = 0
  for _ in pairs(struckByAction) do
    actionCount = actionCount + 1
  end
  Assert.equal(actionCount, 2, "both genuine strikes reach the presentation path")
  local targetOf = {}
  for actionId, event in pairs(struckByAction) do
    targetOf[actionId] = event.payload.target
  end
  local view = orderTimelineView()
  local started = {}
  local handles = {}
  local timeline = nil
  local effects = {
    start = function(cue)
      started[#started + 1] = { effectKey = cue.effectKey, actionId = cue.actionId, message = timeline:message() }
      local handle = { actionId = cue.actionId, phase = "pending" }
      handles[#handles + 1] = handle
      return handle
    end,
    status = function(handle)
      return handle.phase
    end,
    cancel = function(handle)
      handle.phase = "cancelled"
      return true
    end,
  }
  timeline = BattleTimeline.new({ effects = effects })
  timeline:reset(view)
  local packet = BattlePresentationModel.packet(
    view,
    { events = events },
    view,
    { launchId = "strike-order-probe", packetId = 1 }
  )
  Assert.isTrue(timeline:present(packet), "the genuine strike packet is accepted")
  local announcedAt = {}
  local startedAt = {}
  local startMessage = {}
  local initialHp = {}
  for _, entry in ipairs(timeline:battlers()) do
    initialHp[entry.combatant] = entry.hp
  end
  local function actorName(combatant)
    return combatant == 1 and "LEAD" or "FOE"
  end
  local tick = 0
  while tick < 3000 and #started < 1 do
    tick = tick + 1
    timeline:update(TICK, function(_)
      return true
    end)
    local message = timeline:message()
    for _, combatant in ipairs({ 1, 2 }) do
      if announcedAt[combatant] == nil and message:find(actorName(combatant) .. " used", 1, true) ~= nil then
        announcedAt[combatant] = tick
      end
    end
    for _, record in ipairs(started) do
      if startedAt[record.actionId] == nil then
        startedAt[record.actionId] = tick
        startMessage[record.actionId] = record.message
      end
    end
  end
  Assert.equal(#started, 1, "the first visual starts alone while its sibling waits")
  local firstAction = started[1].actionId
  local firstActor = struckByAction[firstAction].actors[1].combatant
  Assert.notNil(announcedAt[firstActor], "the first announcement reads before any visual")
  Assert.isTrue(
    announcedAt[firstActor] < startedAt[firstAction],
    "the first strike announcement precedes its visual start"
  )
  Assert.isTrue(
    type(startMessage[firstAction]) == "string" and startMessage[firstAction]:find("used", 1, true) ~= nil,
    "the first visual starts behind readable attack narration"
  )
  for _, entry in ipairs(timeline:battlers()) do
    Assert.equal(entry.hp, initialHp[entry.combatant], "no checkpoint advances ahead of the unfinished visual")
  end
  for _, handle in ipairs(handles) do
    if handle.actionId == firstAction then
      handle.phase = "complete"
    end
  end
  while tick < 6000 and #started < 2 do
    tick = tick + 1
    timeline:update(TICK, function(_)
      return true
    end)
    local message = timeline:message()
    for _, combatant in ipairs({ 1, 2 }) do
      if announcedAt[combatant] == nil and message:find(actorName(combatant) .. " used", 1, true) ~= nil then
        announcedAt[combatant] = tick
      end
    end
    for _, record in ipairs(started) do
      if startedAt[record.actionId] == nil then
        startedAt[record.actionId] = tick
        startMessage[record.actionId] = record.message
      end
    end
    for _, entry in ipairs(timeline:battlers()) do
      if entry.combatant ~= targetOf[firstAction] then
        Assert.equal(entry.hp, initialHp[entry.combatant], "the still-pending strike holds its own checkpoint")
      end
    end
  end
  Assert.equal(#started, 2, "the second action admits its own visual once released")
  local secondAction = started[1].actionId == firstAction and started[2].actionId or started[1].actionId
  local secondActor = struckByAction[secondAction].actors[1].combatant
  Assert.notNil(announcedAt[secondActor], "the second announcement reads before its visual")
  Assert.isTrue(
    announcedAt[secondActor] < startedAt[secondAction],
    "the second strike announcement precedes its visual start"
  )
  for _, handle in ipairs(handles) do
    handle.phase = "complete"
  end
  tick = 0
  while tick < 3000 and not timeline:settled() do
    tick = tick + 1
    timeline:update(TICK, function(_)
      return true
    end)
  end
  Assert.isTrue(timeline:settled(), "both strikes drain fully once their visuals complete")
  Assert.equal(#started, 2, "each genuine strike starts exactly one visual")
  local expectedHp = {}
  for _, event in ipairs(packet.events) do
    if type(event.after) == "table" and type(event.after.hp) == "table" then
      for combatant, hp in pairs(event.after.hp) do
        expectedHp[combatant] = hp
      end
    end
  end
  for _, entry in ipairs(timeline:battlers()) do
    if expectedHp[entry.combatant] ~= nil then
      Assert.equal(entry.hp, expectedHp[entry.combatant], "event checkpoints apply in order at completion")
    end
  end
end

---@param sequence integer event sequence ordinal under the shared action
---@param foeHp integer foe health after this hit
---@return table one production-shaped strike event for the shared two-hit action
local function visualStrike(sequence, foeHp)
  return {
    sequence = sequence,
    kind = "struck",
    cause = { key = "TACKLE", kind = "move" },
    audience = "public",
    actionId = 7,
    effectKey = "TACKLE",
    actors = { { combatant = 1 } },
    targets = { { combatant = 3 } },
    move = { selected = "TACKLE", executed = "TACKLE", phase = "direct" },
    payload = { target = 3, damage = 14, hitIndex = sequence },
    observation = { hp = { [1] = 52, [3] = foeHp } },
    after = { hp = { [1] = 52, [3] = foeHp } },
    visualSeed = sequence * 3 + 1,
  }
end

function T.move_use_and_strike_of_one_action_announce_only_once()
  for _, animations in ipairs({ true, false }) do
    local view = openingView()
    local starts = 0
    local timeline = BattleTimeline.new({
      effects = {
        start = function(_)
          starts = starts + 1
          return { phase = "complete" }
        end,
        status = function(handle)
          return handle.phase
        end,
      },
    })
    timeline:reset(view)
    local use = visualStrike(2, 43)
    use.kind = "move-used"
    use.payload = { user = 1, targets = 1 }
    local after = openingView()
    after.foes[1].hp = 43
    local packet = BattlePresentationModel.packet(view, { events = { visualStrike(1, 43), use } }, after, {
      launchId = "use-and-strike",
      packetId = 1,
    })
    if not animations then
      for _, event in ipairs(packet.events) do
        event.effectKey = nil
      end
    end
    Assert.isTrue(timeline:present(packet), "the action is accepted")
    local texts = collectMessages(timeline)
    Assert.isTrue(timeline:settled(), "the action drains")
    Assert.equal(countContaining(texts, "used Tackle"), 1, "the action announces only once")
    Assert.equal(starts, animations and 1 or 0, "the action respects the animation setting")
    Assert.equal(battler(timeline:battlers(), 3).hp, 43, "the strike updates the target's health")
  end
end

function T.bide_release_uses_selected_message_before_damage()
  local view = openingView()
  local timeline = BattleTimeline.new({
    effects = {
      start = function(_)
        return { phase = "complete" }
      end,
      status = function(handle)
        return handle.phase
      end,
    },
  })
  timeline:reset(view)
  local use = visualStrike(1, 57)
  use.kind = "move-used"
  use.cause.key = "BIDE"
  use.effectKey = "BIDE"
  use.move.selected = "BIDE"
  use.move.executed = "BIDE"
  use.payload = { user = 1, targets = 1, phase = "release" }
  local strike = visualStrike(2, 43)
  strike.cause.key = "BIDE"
  strike.effectKey = "BIDE"
  strike.move.selected = "BIDE"
  strike.move.executed = "BIDE"
  local packet = BattlePresentationModel.packet(view, { events = { use, strike } }, view, {
    launchId = "bide-release",
    packetId = 1,
  })
  Assert.isTrue(timeline:present(packet, { [1] = "source-release-text" }), "the Bide release is accepted")
  local texts = collectMessages(timeline)
  Assert.isTrue(timeline:settled(), "the release drains")
  Assert.equal(countContaining(texts, "source-release-text"), 1, "the selected source release message is shown once")
  Assert.equal(countContaining(texts, "used BIDE"), 0, "the release does not repeat the move-use announcement")
  Assert.equal(battler(timeline:battlers(), 3).hp, 43, "the stored damage follows the release")
end

function T.multi_hit_strike_announces_once_before_its_single_visual()
  local before = openingView()
  local after = openingView()
  after.foes[1].hp = 30
  local view = openingView()
  local started = {}
  local handles = {}
  local timeline = nil
  local effects = {
    start = function(cue)
      started[#started + 1] = { effectKey = cue.effectKey, actionId = cue.actionId, message = timeline:message() }
      local handle = { phase = "pending" }
      handles[#handles + 1] = handle
      return handle
    end,
    status = function(handle)
      return handle.phase
    end,
    cancel = function(handle)
      handle.phase = "cancelled"
      return true
    end,
  }
  timeline = BattleTimeline.new({ effects = effects })
  timeline:reset(view)
  local packet = BattlePresentationModel.packet(
    before,
    { events = { visualStrike(1, 43), visualStrike(2, 30) } },
    after,
    { launchId = "multi-hit-probe", packetId = 1 }
  )
  Assert.isTrue(timeline:present(packet), "the two-hit packet is accepted")
  local announcementTick = nil
  local startTick = nil
  local seen = {}
  local texts = {}
  local tick = 0
  while tick < 6000 and (not timeline:settled() or startTick == nil) do
    tick = tick + 1
    timeline:update(TICK, function(_)
      return true
    end)
    local id = timeline:messageId()
    if id ~= 0 and seen[id] == nil and timeline:ack() then
      seen[id] = true
      texts[#texts + 1] = timeline:message()
    end
    if announcementTick == nil and timeline:message():find("used Tackle", 1, true) ~= nil then
      announcementTick = tick
    end
    if #started > 0 then
      if startTick == nil then
        startTick = tick
      end
      for _, handle in ipairs(handles) do
        handle.phase = "complete"
      end
    else
      for _, entry in ipairs(timeline:battlers()) do
        if entry.combatant == 3 then
          Assert.equal(entry.hp, 57, "neither hit checkpoint advances ahead of the unfinished visual")
        end
      end
    end
  end
  Assert.notNil(announcementTick, "the shared attack announcement becomes readable")
  Assert.notNil(startTick, "the shared visual starts")
  Assert.isTrue(announcementTick < startTick, "the multi-hit announcement precedes its single visual")
  Assert.isTrue(
    started[1].message:find("used Tackle", 1, true) ~= nil,
    "the single visual starts behind its attack announcement"
  )
  Assert.isTrue(timeline:settled(), "both hits drain fully once the visual completes")
  Assert.equal(#started, 1, "the two-hit action starts exactly one visual")
  Assert.equal(battler(timeline:battlers(), 3).hp, 30, "both hit checkpoints apply in order")
  Assert.equal(countContaining(texts, "used Tackle"), 1, "the shared attack narrates exactly once")
end

-- One action split across two deliveries still plays one visual and
-- narrates once: the occurrence claim survives packet boundaries while
-- each delivery keeps its own checkpoint motion.
function T.split_action_across_packets_claims_one_visual_and_narrates_once()
  local before = openingView()
  local after = openingView()
  after.foes[1].hp = 30
  local view = openingView()
  local started = {}
  local handles = {}
  local timeline = nil
  local effects = {
    start = function(cue)
      started[#started + 1] = { effectKey = cue.effectKey, actionId = cue.actionId }
      local handle = { phase = "pending" }
      handles[#handles + 1] = handle
      return handle
    end,
    status = function(handle)
      return handle.phase
    end,
    cancel = function(handle)
      handle.phase = "cancelled"
      return true
    end,
  }
  timeline = BattleTimeline.new({ effects = effects })
  timeline:reset(view)
  local first = BattlePresentationModel.packet(
    before,
    { events = { visualStrike(1, 43) } },
    before,
    { launchId = "split-probe", packetId = 1 }
  )
  -- The split halves share one action identity with distinct sequences.
  first.events[1].actionId = 31
  Assert.isTrue(timeline:present(first), "the first half is accepted")
  local tick = 0
  while tick < 3000 and not timeline:settled() do
    tick = tick + 1
    timeline:update(TICK, function(_)
      return true
    end)
    for _, handle in ipairs(handles) do
      handle.phase = "complete"
    end
  end
  Assert.isTrue(timeline:settled(), "the first half drains fully")
  local second = BattlePresentationModel.packet(
    before,
    { events = { visualStrike(2, 30) } },
    after,
    { launchId = "split-probe", packetId = 2 }
  )
  second.events[1].actionId = 31
  Assert.isTrue(timeline:present(second), "the second half carries new checkpoints")
  local seen = {}
  local texts = {}
  tick = 0
  while tick < 3000 and not timeline:settled() do
    tick = tick + 1
    timeline:update(TICK, function(_)
      return true
    end)
    for _, handle in ipairs(handles) do
      handle.phase = "complete"
    end
    local id = timeline:messageId()
    if id ~= 0 and seen[id] == nil and timeline:ack() then
      seen[id] = true
      texts[#texts + 1] = timeline:message()
    end
  end
  Assert.isTrue(timeline:settled(), "the second half drains fully")
  Assert.equal(#started, 1, "the split action starts exactly one visual")
  Assert.equal(battler(timeline:battlers(), 3).hp, 30, "both halves move their checkpoints")
end

function T.repeated_move_in_later_round_announces_and_animates_again()
  local view = openingView()
  view.round = 1
  local started = 0
  local timeline = BattleTimeline.new({
    effects = {
      start = function(_)
        started = started + 1
        return { phase = "complete" }
      end,
      status = function(handle)
        return handle.phase
      end,
    },
  })
  timeline:reset(view)
  for round = 1, 2 do
    local before = openingView()
    before.round = round
    local after = openingView()
    -- The round-ending delivery may already expose the next round in
    -- its after view. Its event still belongs to the before round.
    after.round = round == 1 and 2 or round
    local strike = visualStrike(round, 43)
    local packet = BattlePresentationModel.packet(before, { events = { strike } }, after, {
      launchId = "repeat-move-probe",
      packetId = round,
    })
    Assert.isTrue(timeline:present(packet), "each turn's strike is accepted")
    local texts = collectMessages(timeline)
    Assert.equal(countContaining(texts, "used Tackle"), 1, "each turn announces its attack")
    Assert.isTrue(timeline:settled(), "each turn finishes playback")
  end
  Assert.equal(started, 2, "each turn plays its attack animation")
end

-- A mistyped source action identity claims nothing: the outcome still
-- narrates, a diagnostic names the rejection, and no visual is
-- assigned to another user's action.
function T.malformed_action_identity_is_rejected_without_assigning_the_visual()
  local view = openingView()
  local started = {}
  local timeline = BattleTimeline.new({
    start = function(cue)
      started[#started + 1] = { effectKey = cue.effectKey }
      return { phase = "complete" }
    end,
    status = function(handle)
      return handle.phase
    end,
    cancel = function(handle)
      handle.phase = "cancelled"
      return true
    end,
  })
  timeline:reset(view)
  local strike = visualStrike(1, 43)
  strike.actionId = {}
  Assert.isTrue(
    timeline:present({
      launchId = "malformed-probe",
      packetId = 1,
      events = { strike },
      before = view,
      after = view,
    }),
    "the malformed delivery is accepted for narration"
  )
  local tick = 0
  while tick < 3000 and not timeline:settled() do
    tick = tick + 1
    timeline:update(TICK, function(_)
      return true
    end)
  end
  Assert.isTrue(timeline:settled(), "narration drains without the rejected visual")
  Assert.equal(#started, 0, "the malformed identity starts no visual")
  local diagnosed = false
  for _, entry in ipairs(timeline:diagnostics()) do
    if tostring(entry):find("no usable action identity", 1, true) ~= nil then
      diagnosed = true
    end
  end
  Assert.isTrue(diagnosed, "the rejection is diagnosed instead of silent")
  Assert.isTrue(timeline:message():find("used Tackle", 1, true) ~= nil, "the outcome still narrates without its visual")
end

return { tests = T }
