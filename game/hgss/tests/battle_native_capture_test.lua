-- Frozen acceptance for complete capture presentation through the cue
-- player: the incoming arc, the staged opening, the ground bounce, the
-- source-table wobbles, and the success click/fade or the mode-1
-- breakout play the exact ball choreography facts (trajectory, cells,
-- offsets, rotation, sounds, completion joins, native wording) supplied
-- by the mechanics, never recomputed or inferred in the renderer. Native
-- mechanism: battle_command.c Task_GetPokemon with
-- battle_anim_ball.c capture states and the asm row tables; the
-- mechanics-owned throw/shake/outcome events
-- (libs/battle/src/gen4/Capture.lua execute) select the wobble rows.
-- Headless: kernel-shaped capture events drive the real cue player, a
-- real BattleBallParticles instance with staged stub sets, and the
-- recording sound sink; no dump capability is needed.

local Assert = require("tests.support.Assert")
local BattleBallParticles = require("game.hgss.src.battle.BattleBallParticles")
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

---@return table detached dynamic view with a live lead and a catchable foe
local function openingView()
  local function entry(combatant, own)
    return {
      combatant = combatant,
      participant = combatant,
      side = own and 1 or 2,
      controller = own and "player" or "wild",
      active = true,
      position = combatant,
      activation = combatant,
      hp = own and 52 or 20,
      maxHp = own and 52 or 57,
      species = "EEVEE",
      form = 0,
      name = own and "LEAD" or "FOE",
      level = own and 20 or 4,
      selector = own and "back" or "front",
      moves = own and { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } } or nil,
      experience = 8000,
    }
  end
  return {
    round = 1,
    status = "running",
    own = { entry(1, true) },
    foes = { entry(3, false) },
    participants = {},
  }
end

---@param sequence integer
---@return table kernel-shaped throw event naming its ball identity
local function throwEvent(sequence)
  return {
    sequence = sequence,
    kind = "throw",
    cause = { key = "CAPTURE" },
    audience = "public",
    actors = { { combatant = 1 } },
    targets = { { combatant = 3 } },
    payload = { user = 1, ball = "POKE_BALL", target = 3 },
    after = { hp = { [1] = 52, [3] = 20 } },
  }
end

---@param sequence integer
---@param index integer authoritative one-based shake ordinal
---@return table kernel-shaped shake event
local function shakeEvent(sequence, index)
  return {
    sequence = sequence,
    kind = "shake",
    cause = { key = "CAPTURE" },
    audience = "public",
    actors = { { combatant = 1 } },
    targets = { { combatant = 3 } },
    payload = { index = index },
    after = { hp = { [1] = 52, [3] = 20 } },
  }
end

---@return table kernel-shaped successful outcome event
local function caughtEvent()
  return {
    sequence = 5,
    kind = "caught",
    cause = { key = "CAPTURE" },
    audience = "public",
    actors = { { combatant = 1 } },
    targets = { { combatant = 3 } },
    payload = { shakes = 3 },
    after = { hp = { [1] = 52, [3] = 20 } },
  }
end

---@param id integer
---@return table delivery-shaped successful capture packet
local function caughtPacket(id)
  return {
    launchId = "capture-probe",
    packetId = id,
    events = { throwEvent(1), shakeEvent(2, 1), shakeEvent(3, 2), shakeEvent(4, 3), caughtEvent() },
    before = openingView(),
    after = openingView(),
    request = nil,
    result = nil,
  }
end

---@param timeline table cue player under test driving with staged ball art
local function stageBallArt(timeline)
  local function frames(ballKey)
    return {
      frames = {
        { drawableKey = "cell:" .. ballKey .. ":0", durationTicks = 2 },
        { drawableKey = "cell:" .. ballKey .. ":1", durationTicks = 2 },
        { drawableKey = "cell:" .. ballKey .. ":2", durationTicks = 2 },
      },
    }
  end
  timeline._ballOpening = frames
  timeline._ballThrow = frames
end

---@return table stub resolver with instantly retiring empty sets
local function particleResolver()
  local function set()
    return { emitters = {}, textures = {} }
  end
  local particles = { seal = set(), burst = set(), genericBurst = set(), clickEmitter = 0, burstStartTick = 3 }
  return {
    particles = function()
      return particles
    end,
    has = function()
      return true
    end,
    texture = function()
      return { name = "texture" }
    end,
  }
end

---@param timeline table cue player under driving
---@return table driven particle owner joined to the timeline
local function driveParticles(timeline)
  local owner = BattleBallParticles.new({ splRandomState = { state = 0 } })
  local res = particleResolver()
  timeline:setParticleIdleProbe(function()
    return owner:isIdle()
  end)
  return {
    owner = owner,
    step = function()
      owner:step(timeline:takeBallParticleStarts(), timeline:queuedParticleBalls(), res)
    end,
    failures = function()
      return owner:failures()
    end,
  }
end

---@param timeline table cue player under test driving
---@param driver table particle driver behind the joins
---@param budget integer maximum source ticks before giving up
local function drive(timeline, driver, budget)
  for _ = 1, budget do
    timeline:update(TICK, function(_)
      return true
    end)
    driver.step()
    if timeline:settled() then
      break
    end
  end
end

---@param timeline table cue player under driving
---@param driver table particle driver behind the joins
---@param ready fun(): boolean phase predicate under waiting
---@param budget integer maximum source ticks before giving up
---@return boolean true when the phase arrived in budget
local function waitFor(timeline, driver, ready, budget)
  for _ = 1, budget do
    if ready() then
      return true
    end
    timeline:update(TICK, function(_)
      return true
    end)
    driver.step()
  end
  return ready()
end

---@param sounds table recorded sound intents
---@param symbol string awaited sound symbol
---@return boolean true when the symbol voiced
local function voiced(sounds, symbol)
  for _, cue in ipairs(sounds.played) do
    if type(cue) == "table" and cue.symbol == symbol then
      return true
    end
  end
  return false
end

---@param timeline table cue player under inspection
---@return table current ball sprite snapshot
local function ballOf(timeline)
  local presentation = timeline:openingPresentation()
  assert(presentation ~= nil and presentation.ballThrow ~= nil, "the capture actor publishes its ball")
  return presentation.ballThrow
end

---@param sounds table recorded sound intents
---@return string[] effect symbols in play order, cries excluded
local function symbols(sounds)
  local order = {}
  for _, cue in ipairs(sounds.played) do
    if type(cue) == "table" and cue.kind ~= "cry" then
      order[#order + 1] = cue.symbol
    end
  end
  return order
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

function T.incoming_arc_lands_before_the_open()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(name)
      sounds.sound(name)
    end,
  })
  stageBallArt(timeline)
  timeline:reset(openingView())
  local driver = driveParticles(timeline)
  Assert.isTrue(timeline:present(caughtPacket(1)), "the capture packet is accepted")
  -- The arc starts off screen and lands at the foe before any open
  -- sound: the kind-15/16/17 flight precedes BOWA4.
  Assert.isTrue(
    waitFor(timeline, driver, function()
      return voiced(sounds, "SEQ_SE_DP_BOWA4")
    end, 3000),
    "the open voices after the arc"
  )
  local landed = ballOf(timeline)
  Assert.equal(landed.x, 192, "the arc lands at the foe x")
  Assert.equal(landed.y, 56, "the arc lands at the foe y")
  Assert.equal(landed.rotation, 0, "the finished arc resets its spin")
  local order = symbols(sounds)
  Assert.equal(order[1], "SEQ_SE_DP_NAGERU", "the throw voices first")
  Assert.equal(order[2], "SEQ_SE_DP_BOWA4", "the open voices second")
end

function T.open_runs_cells_burst_and_entry_barrier()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(name)
      sounds.sound(name)
    end,
  })
  stageBallArt(timeline)
  timeline:reset(openingView())
  local driver = driveParticles(timeline)
  Assert.isTrue(timeline:present(caughtPacket(1)), "the capture packet is accepted")
  -- The open voices BOWA4 and bursts at the landing: the foe stays
  -- outside the ball for the native 23 frames after the open starts.
  Assert.isTrue(
    waitFor(timeline, driver, function()
      return voiced(sounds, "SEQ_SE_DP_BOWA4")
    end, 3000),
    "the open voices at the arc end"
  )
  local foeOutTicks = 0
  for _ = 1, 120 do
    timeline:update(TICK, function(_)
      return true
    end)
    driver.step()
    foeOutTicks = foeOutTicks + 1
    if not battler(timeline:battlers(), 3).visible then
      break
    end
  end
  Assert.isTrue(battler(timeline:battlers(), 3).visible == false, "the target enters the ball")
  Assert.isTrue(foeOutTicks >= 23, "the target enters no earlier than 23 frames after the open starts")
  Assert.isTrue(#driver.owner:systems() == 0, "the opening burst retired before the fall")
end

function T.bounce_runs_source_rows_and_returns()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(name)
      sounds.sound(name)
    end,
  })
  stageBallArt(timeline)
  timeline:reset(openingView())
  local driver = driveParticles(timeline)
  Assert.isTrue(timeline:present(caughtPacket(1)), "the capture packet is accepted")
  -- From the entry anchor the yellow flash (12) and the drop (11)
  -- precede the 21-tick bounce at the resting spot.
  Assert.isTrue(
    waitFor(timeline, driver, function()
      return not battler(timeline:battlers(), 3).visible
    end, 3000),
    "the target enters the ball"
  )
  for _ = 1, 12 + 11 do
    timeline:update(TICK, function(_)
      return true
    end)
    driver.step()
  end
  local rest = ballOf(timeline)
  Assert.equal(rest.x, 192, "the bounce plays at the resting x")
  local restY = rest.y
  local lowest = restY
  local before = #sounds.played
  for _ = 1, 21 do
    timeline:update(TICK, function(_)
      return true
    end)
    driver.step()
    local at = ballOf(timeline)
    lowest = math.min(lowest, at.y)
  end
  local settledBall = ballOf(timeline)
  Assert.equal(settledBall.y, restY, "the applied bounce rows sum back to the resting spot")
  Assert.isTrue(lowest < restY, "the bounce leaves the resting height")
  Assert.equal(settledBall.rotation, 0, "the bounce resets rotation")
  local bounces = 0
  for index = before + 1, #sounds.played do
    local cue = sounds.played[index]
    if type(cue) == "table" and cue.symbol ~= nil and cue.symbol:match("^SEQ_SE_DP_KON") then
      bounces = bounces + 1
    end
  end
  Assert.equal(bounces, 5, "the bounce voices its five source sounds")
end

function T.shakes_run_source_rows_with_rotation_reset()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(name)
      sounds.sound(name)
    end,
  })
  stageBallArt(timeline)
  timeline:reset(openingView())
  local driver = driveParticles(timeline)
  Assert.isTrue(timeline:present(caughtPacket(1)), "the capture packet is accepted")
  -- Reach the first wobble from the entry anchor: flash (12), drop
  -- (11), and the 21-tick bounce.
  Assert.isTrue(
    waitFor(timeline, driver, function()
      return not battler(timeline:battlers(), 3).visible
    end, 3000),
    "the target enters the ball"
  )
  for _ = 1, 12 + 11 + 21 do
    timeline:update(TICK, function(_)
      return true
    end)
    driver.step()
  end
  -- Each row runs its 14-tick lead plus its applied updates plus one
  -- with exactly one BOWA, returns to rest, and resets its rotation;
  -- the command holds 12 ticks after every completed wobble. The wobble
  -- visibly leaves the resting x mid-row: the renderer samples the same
  -- published ball, so a static ball here means no shake on screen.
  for row, length in ipairs({ 21, 21, 26 }) do
    local before = #symbols(sounds)
    local lowest, highest = 192, 192
    for _ = 1, length do
      timeline:update(TICK, function(_)
        return true
      end)
      driver.step()
      local at = ballOf(timeline)
      lowest = math.min(lowest, at.x)
      highest = math.max(highest, at.x)
    end
    Assert.isTrue(lowest < 192 or highest > 192, "wobble " .. row .. " visibly leaves the resting x")
    local at = ballOf(timeline)
    Assert.equal(at.x, 192, "wobble " .. row .. " returns to the resting x")
    Assert.equal(at.rotation, 0, "wobble " .. row .. " resets its rotation")
    local bowas = 0
    for index = before + 1, #symbols(sounds) do
      if symbols(sounds)[index] == "SEQ_SE_DP_BOWA" then
        bowas = bowas + 1
      end
    end
    Assert.equal(bowas, 1, "wobble " .. row .. " voices exactly one shake sound")
    for _ = 1, 12 do
      timeline:update(TICK, function(_)
        return true
      end)
      driver.step()
    end
  end
end

function T.success_plays_click_fade_lifecycle()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(name)
      sounds.sound(name)
    end,
  })
  stageBallArt(timeline)
  timeline:reset(openingView())
  local driver = driveParticles(timeline)
  Assert.isTrue(timeline:present(caughtPacket(1)), "the capture packet is accepted")
  drive(timeline, driver, 3000)
  Assert.isTrue(timeline:settled(), "the full capture sequence drains")
  local order = symbols(sounds)
  local getting, fanfare = nil, nil
  for index, symbol in ipairs(order) do
    if symbol == "SEQ_SE_DP_GETTING" and getting == nil then
      getting = index
    end
    if symbol == "SEQ_ME_POKEGET" and fanfare == nil then
      fanfare = index
    end
  end
  Assert.isTrue(getting ~= nil, "the click voices its getting sound")
  Assert.isTrue(fanfare ~= nil, "the catch voices its jingle")
  Assert.isTrue(getting < fanfare, "Gotcha voices only after the click retires")
  local endBall = ballOf(timeline)
  Assert.isFalse(endBall.visible, "the caught ball fades from the field")
  Assert.isFalse(battler(timeline:battlers(), 3).visible, "the caught target stays inside the ball")
  Assert.isTrue(battler(timeline:battlers(), 1).visible, "the thrower stays displayed")
end

function T.capture_choreography_emits_its_ordered_audio_intents()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(name)
      sounds.sound(name)
    end,
  })
  stageBallArt(timeline)
  timeline:reset(openingView())
  local driver = driveParticles(timeline)
  Assert.isTrue(timeline:present(caughtPacket(1)), "the capture packet is accepted")
  drive(timeline, driver, 3000)
  Assert.deepEqual(symbols(sounds), {
    "SEQ_SE_DP_NAGERU",
    "SEQ_SE_DP_BOWA4",
    "SEQ_SE_DP_KON",
    "SEQ_SE_DP_KON",
    "SEQ_SE_DP_KON2",
    "SEQ_SE_DP_KON3",
    "SEQ_SE_DP_KON4",
    "SEQ_SE_DP_BOWA",
    "SEQ_SE_DP_BOWA",
    "SEQ_SE_DP_BOWA",
    "SEQ_SE_DP_GETTING",
    "SEQ_ME_POKEGET",
  }, "throw, open, ground bounces, one wobble per shake, click, then the jingle")
end

function T.capture_effect_join_holds_until_retirement()
  local timeline = BattleTimeline.new({})
  stageBallArt(timeline)
  timeline:reset(openingView())
  -- A particle owner that never retires holds the capture at its
  -- joins: no Gotcha, no fade, no settle.
  local stuck = BattleBallParticles.new({ splRandomState = { state = 0 } })
  local res = particleResolver()
  timeline:setParticleIdleProbe(function()
    return false
  end)
  Assert.isTrue(timeline:present(caughtPacket(1)), "the capture packet is accepted")
  for _ = 1, 1500 do
    timeline:update(TICK, function(_)
      return true
    end)
    stuck:step(timeline:takeBallParticleStarts(), timeline:queuedParticleBalls(), res)
    if timeline:settled() then
      break
    end
  end
  Assert.isFalse(timeline:settled(), "a running effect never reports successful completion")
  Assert.isTrue(#stuck:failures() == 0, "a running effect is not a staging failure")
end

function T.missing_required_effects_fail_instead_of_vanishing()
  local timeline = BattleTimeline.new({})
  stageBallArt(timeline)
  timeline:reset(openingView())
  -- A resolver that never stages the ball records the required bursts
  -- as staging failures instead of completing the capture silently.
  local owner = BattleBallParticles.new({ splRandomState = { state = 0 } })
  local res = particleResolver()
  res.particles = function()
    return nil
  end
  timeline:setParticleIdleProbe(function()
    return owner:isIdle()
  end)
  Assert.isTrue(timeline:present(caughtPacket(1)), "the capture packet is accepted")
  for _ = 1, 1500 do
    timeline:update(TICK, function(_)
      return true
    end)
    owner:step(timeline:takeBallParticleStarts(), timeline:queuedParticleBalls(), res)
    if timeline:settled() then
      break
    end
  end
  local failed = owner:failures()
  Assert.isTrue(#failed >= 1, "the missing required effects are recorded")
  Assert.equal(failed[1].reason, "missing-particles", "the failure names its staging loss")
end

function T.breakout_runs_mode1_with_generic_burst()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(name)
      sounds.sound(name)
    end,
  })
  stageBallArt(timeline)
  timeline:reset(openingView())
  local driver = driveParticles(timeline)
  local packet = {
    launchId = "capture-breakout-probe",
    packetId = 1,
    events = {
      throwEvent(1),
      shakeEvent(2, 1),
      {
        sequence = 3,
        kind = "broke_free",
        cause = { key = "CAPTURE" },
        audience = "public",
        actors = { { combatant = 1 } },
        targets = { { combatant = 3 } },
        payload = { shakes = 1 },
        after = { hp = { [1] = 52, [3] = 20 } },
      },
    },
    before = openingView(),
    after = openingView(),
    request = nil,
    result = nil,
  }
  Assert.isTrue(
    timeline:present(packet, { [3] = "Oh no! It broke free!" }),
    "the breakout retry carrying its selected source text is accepted"
  )
  drive(timeline, driver, 3000)
  Assert.isTrue(timeline:settled(), "the breakout sequence drains")
  Assert.isTrue(battler(timeline:battlers(), 3).visible, "the breakout reveals its target")
  Assert.isFalse(ballOf(timeline).visible, "the breakout retires its ball")
  local order = symbols(sounds)
  local open = nil
  for index, symbol in ipairs(order) do
    if symbol == "SEQ_SE_DP_BOWA2" and open == nil then
      open = index
    end
  end
  Assert.isTrue(open ~= nil, "the breakout voices the send-out ball sound")
end

function T.breakout_outcome_requires_its_selected_source_text()
  local timeline = BattleTimeline.new({})
  local packet = {
    launchId = "capture-breakout-probe",
    packetId = 1,
    events = {
      {
        sequence = 7,
        kind = "broke_free",
        cause = { key = "CAPTURE" },
        audience = "public",
        payload = { shakes = 1 },
        after = { hp = { [1] = 52, [3] = 20 } },
      },
    },
    before = openingView(),
    after = openingView(),
    request = nil,
    result = nil,
  }
  Assert.isFalse(
    pcall(function()
      timeline:present(packet)
    end),
    "a breakout without its selected source wording is rejected"
  )
  Assert.isTrue(
    timeline:present(packet, { [7] = "Oh no! It broke free!" }),
    "the retry carrying its selected wording is accepted"
  )
end

function T.blocked_throws_still_deflect_off_trainer_targets()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(name)
      sounds.sound(name)
    end,
  })
  stageBallArt(timeline)
  timeline:reset(openingView())
  local driver = driveParticles(timeline)
  local packet = {
    launchId = "capture-blocked-probe",
    packetId = 1,
    events = {
      {
        sequence = 1,
        kind = "throw",
        cause = { key = "CAPTURE" },
        audience = "public",
        actors = { { combatant = 1 } },
        targets = { { combatant = 3 } },
        payload = { user = 1, ball = "POKE_BALL", target = 3, blocked = true },
        after = { hp = { [1] = 52, [3] = 20 } },
      },
    },
    before = openingView(),
    after = openingView(),
    request = nil,
    result = nil,
  }
  Assert.isTrue(timeline:present(packet), "the blocked throw is accepted")
  drive(timeline, driver, 3000)
  Assert.isTrue(timeline:settled(), "the deflection drains")
  Assert.deepEqual(symbols(sounds), {
    "SEQ_SE_DP_NAGERU",
    "SEQ_SE_DP_KON",
  }, "the deflection arcs, bounces off, and voices its sound")
  Assert.isTrue(battler(timeline:battlers(), 3).visible, "the defended target stays out")
end

return { tests = T }
