-- Frozen acceptance for the animation and text-speed options through the
-- cue player: mechanics stay identical with effects on or off, the
-- disabled path keeps its native waits and essential visual updates
-- including the Transform exception, and print pacing never changes
-- mechanics or effect task duration. Native mechanism: the
-- move-animation option handling with its animation-suppression flag and
-- the explicit Transform allowance, where the disabled path still runs
-- the native wait subscript instead of skipping
-- (BtlCmd_PlayMoveAnimation in src/battle/battle_command.c). Headless:
-- hand-built delivery-shaped packets drive the real cue player under two
-- print pacings; no dump capability is needed. The setup guards below are
-- green on the current boundary; the appearance and player gates stay red
-- until the native playback lands.

local Assert = require("tests.support.Assert")
local BattleTimeline = require("game.hgss.src.battle.BattleTimeline")

local T = {}
local TICK = 1 / 30

---@param value integer unsigned word under staging
---@return string four little-endian bytes staging one command word
local function optionU32(value)
  return string.char(
    value % 256,
    math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 16777216) % 256
  )
end

---@param list table<integer, integer> command words under staging
---@return string staged byte stream lowering one program
local function optionStreamOf(list)
  local parts = {}
  for _, word in ipairs(list) do
    parts[#parts + 1] = optionU32(word)
  end
  return table.concat(parts)
end

---@return table<string, unknown> compiled resourceless native program completing in three source ticks
local function optionProbeProgram()
  local BattleAnimationCompiler = require("romdump.src.digest.battle.BattleAnimationCompiler")
  return assert(BattleAnimationCompiler.compile({ key = "TACKLE", stream = optionStreamOf({ 29, 50, 4 }) }))
end

---@param program table<string, unknown> exact compiled program the collaborator admits
---@return table task-aware recording native-effect collaborator over the real player path
local function optionTaskAwareEffects(program)
  local Player = require("libs.hgss.src.presentation.BattleAnimationPlayer")
  local Factory = require("libs.hgss.src.presentation.BattleEffectTasks")
  local BattleScene = require("libs.hgss.src.presentation.BattleScene")
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  local audio = { played = {} }
  function audio.play(name)
    audio.played[#audio.played + 1] = name
  end
  function audio.stop(_name) end
  function audio.isFinished(_name)
    return true
  end
  local resources = {}
  function resources.resolve(key)
    return { key = key, lease = key }
  end
  function resources.release(_lease) end
  local player = assert(Player.new({ scene = scene, audio = audio, resources = resources, tasks = Factory }))
  local rec = { starts = {}, player = player, audio = audio, scene = scene }
  function rec.status(handle)
    -- The double models the locked one-tick-advances-all contract:
    -- every status poll advances the wrapped occurrence exactly once,
    -- mirroring the screen's single-tick loop (cue, player, scene).
    -- No catch-up loops: one poll steps one quantum.
    player:stepSourceTick({ tick = 1 })
    return player:status(handle)
  end
  function rec.start(cue)
    Assert.isTrue(type(cue) == "table", "native cues carry their cue record with launch and effect identity")
    rec.starts[#rec.starts + 1] = cue
    return player:start({
      launchId = cue.launchId or "animation-option-probe",
      packetId = cue.packetId or 1,
      event = type(cue.event) == "table" and cue.event
        or { sequence = cue.eventSequence, actionId = cue.actionId, effectKey = cue.effectKey },
      visualSeed = cue.visualSeed or 1,
      topology = {
        attacker = { combatant = 1, activation = 1, slot = "solo-player", sideType = 0 },
        targets = { { combatant = 3, activation = 3, slot = "solo-enemy", sideType = 1 } },
      },
    }, program)
  end
  function rec.cancel(handle, reason)
    return player:cancel(handle, reason)
  end
  return rec
end

---@param sequence integer event sequence under test driving
---@param effectKey string accepted semantic effect key under test driving
---@param damage integer dealt damage under test driving
---@param foeHp integer foe health after the checkpoint under test driving
---@return table one struck event carrying its accepted native playback identity
local function optionStrikeEvent(sequence, effectKey, damage, foeHp)
  return {
    sequence = sequence,
    kind = "struck",
    cause = { key = "TACKLE" },
    audience = "public",
    actors = { { combatant = 1 } },
    targets = { { combatant = 3 } },
    move = { executed = "TACKLE" },
    actionId = 31,
    hitIndex = 1,
    effectKey = effectKey,
    payload = { target = 3, damage = damage },
    after = { hp = { [1] = 52, [3] = foeHp } },
  }
end

---@return table detached dynamic view with a live lead and a foe
local function openingView()
  local function entry(combatant, species, name, own)
    return {
      combatant = combatant,
      participant = combatant,
      side = own and 1 or 2,
      controller = own and "player" or "wild",
      active = true,
      position = combatant,
      activation = combatant,
      hp = own and 52 or 57,
      maxHp = own and 52 or 57,
      species = species,
      form = 0,
      name = name,
      level = 20,
      selector = own and "back" or "front",
      moves = own and { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } } or nil,
      experience = 8000,
    }
  end
  return {
    round = 1,
    status = "running",
    own = { entry(1, "EEVEE", "LEAD", true) },
    foes = { entry(3, "GEODUDE", "FOE", false) },
    participants = {},
  }
end

---@param id integer
---@param events table
---@return table delivery-shaped packet under test driving
local function packet(id, events)
  local after = openingView()
  after.foes[1].hp = 43
  return {
    launchId = "animation-option-probe",
    packetId = id,
    events = events,
    before = openingView(),
    after = after,
    request = nil,
    result = nil,
  }
end

---@return table one sanitized strike event under test driving
local function strikeEvent()
  return {
    sequence = 1,
    kind = "struck",
    cause = { key = "TACKLE" },
    audience = "public",
    actors = { { combatant = 1 } },
    targets = { { combatant = 3 } },
    move = { executed = "TACKLE" },
    payload = { target = 3, damage = 14 },
    after = { hp = { [1] = 52, [3] = 43 } },
  }
end

---@param timeline table cue player under test driving
---@param budget integer maximum source ticks before giving up
local function drain(timeline, budget)
  for _ = 1, budget do
    timeline:update(TICK, function(_)
      return true
    end)
    if timeline:settled() then
      break
    end
  end
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

function T.print_pacing_changes_presentation_without_touching_mechanics()
  local slow = BattleTimeline.new({ textSpeed = "slow" })
  slow:reset(openingView())
  Assert.isTrue(slow:present(packet(1, { strikeEvent() })), "the slow-paced packet is accepted")
  drain(slow, 3000)
  local hurried = BattleTimeline.new({ textSpeed = "fastest" })
  hurried:reset(openingView())
  Assert.isTrue(hurried:present(packet(1, { strikeEvent() })), "the hurried packet is accepted")
  drain(hurried, 3000)
  Assert.isTrue(slow:settled(), "the slow-paced strike drains")
  Assert.isTrue(hurried:settled(), "the hurried strike drains")
  Assert.equal(
    battler(slow:battlers(), 3).hp,
    battler(hurried:battlers(), 3).hp,
    "print pacing never changes the applied checkpoint"
  )
  Assert.equal(battler(slow:battlers(), 3).hp, 43, "the exact final health applies under both pacings")
end

function T.transform_updates_the_displayed_appearance()
  local timeline = BattleTimeline.new({})
  timeline:reset(openingView())
  Assert.isTrue(
    timeline:present(packet(1, {
      {
        sequence = 1,
        kind = "transformed",
        cause = { key = "TRANSFORM" },
        audience = "public",
        actors = { { combatant = 3 } },
        targets = { { combatant = 3 } },
        payload = { target = 3, copiedFrom = 1 },
        after = { hp = { [1] = 52, [3] = 57 } },
      },
    })),
    "the transform packet is accepted"
  )
  drain(timeline, 3000)
  Assert.isTrue(timeline:settled(), "the transform drains fully")
  Assert.equal(
    battler(timeline:battlers(), 3).species,
    "EEVEE",
    "the transformed battler displays the copied appearance, even with effects suppressed"
  )
end

function T.effect_execution_runs_through_the_animation_player()
  -- The execution half runs the exact compiled program through the real
  -- player, factory, and scene: the run stays alive past its first source
  -- tick, owns a visible frame change, then completes and retires cleanly.
  local Player = require("libs.hgss.src.presentation.BattleAnimationPlayer")
  local Factory = require("libs.hgss.src.presentation.BattleEffectTasks")
  local BattleScene = require("libs.hgss.src.presentation.BattleScene")
  local program = optionProbeProgram()
  for _, kind in
    ipairs(program.taskKinds --[[@as table<integer, string>]])
  do
    Assert.isTrue(Factory.supportsKind(kind), "the live run admits only real factory bodies: " .. tostring(kind))
  end
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  local audio = { played = {} }
  function audio.play(name)
    audio.played[#audio.played + 1] = name
  end
  function audio.stop(_name) end
  function audio.isFinished(_name)
    return true
  end
  local resources = {}
  function resources.resolve(key)
    return { key = key, lease = key }
  end
  function resources.release(_lease) end
  local player = assert(Player.new({ scene = scene, audio = audio, resources = resources, tasks = Factory }))
  local handle = assert(
    player:start({
      launchId = "animation-option-probe",
      packetId = 1,
      event = { sequence = 1, actionId = 31, effectKey = "TACKLE" },
      visualSeed = 4242,
      topology = {
        attacker = { combatant = 1, activation = 1, slot = "solo-player", sideType = 0 },
        targets = { { combatant = 3, activation = 3, slot = "solo-enemy", sideType = 1 } },
      },
    }, program),
    "the player admits the selected native program"
  )
  player:stepSourceTick({ tick = 1 })
  local held = player:status(handle)
  Assert.isTrue(held ~= "complete" and held ~= "failed", "the source-timed run stays alive past its first tick")
  Assert.equal(#scene:effectViews(), 0, "state-only visual work publishes no drawable picture while running")
  for _ = 1, 120 do
    if player:status(handle) == "complete" then
      break
    end
    player:stepSourceTick({ tick = 1 })
  end
  Assert.equal(player:status(handle), "complete", "the native run reaches its own completion")
  Assert.isTrue(#audio.played > 0, "the completed run played its source-timed voice instead of staying silent")
  -- The wiring half routes an effect-keyed strike through the cue player
  -- into that same real run: the start carries the accepted key with no
  -- duplicate generic impact voice, and the checkpoint waits for
  -- completion.
  local BattleAudio = require("libs.hgss.src.audio.BattleAudio")
  local sounds = { played = {} }
  function sounds.sound(cue)
    sounds.played[#sounds.played + 1] = cue
  end
  function sounds.countEffect(symbol)
    local total = 0
    for _, played in ipairs(sounds.played) do
      if type(played) == "table" and played.kind == "effect" and played.symbol == symbol then
        total = total + 1
      end
    end
    return total
  end
  local fx = optionTaskAwareEffects(optionProbeProgram())
  local timeline = BattleTimeline.new({
    sound = function(cue)
      sounds.sound(cue)
    end,
    effects = fx,
  })
  timeline:reset(openingView())
  Assert.isTrue(
    timeline:present(packet(1, { optionStrikeEvent(1, "TACKLE", 14, 43) })),
    "the effect-keyed strike is accepted"
  )
  -- The attack announcement plays before the visual admits, so the
  -- start waits behind the narrated use instead of firing at once.
  for _ = 1, 300 do
    if #fx.starts > 0 then
      break
    end
    drain(timeline, 1)
  end
  Assert.equal(#fx.starts, 1, "the strike starts its selected program through the cue player")
  Assert.equal(fx.starts[1].effectKey, "TACKLE", "the cue start carries the accepted semantic effect key")
  Assert.equal(
    sounds.countEffect(BattleAudio.SINK_SOUNDS.impact),
    0,
    "the native program owns impact timing: no duplicate generic voice"
  )
  Assert.equal(battler(timeline:battlers(), 3).hp, 57, "health waits for native completion instead of leaking early")
  drain(timeline, 3000)
  Assert.isTrue(timeline:settled(), "the native strike settles after real completion")
  Assert.equal(battler(timeline:battlers(), 3).hp, 43, "the exact checkpoint applies after native completion")
end

-- A strike with move identity but no damage still runs its selected
-- native program without moving any health fact: no-damage visuals route
-- by source effect identity, never by HP delta.
function T.no_damage_strike_still_runs_its_selected_program()
  local sounds = { played = {} }
  function sounds.sound(cue)
    sounds.played[#sounds.played + 1] = cue
  end
  local fx = optionTaskAwareEffects(optionProbeProgram())
  local timeline = BattleTimeline.new({
    sound = function(cue)
      sounds.sound(cue)
    end,
    effects = fx,
  })
  timeline:reset(openingView())
  Assert.isTrue(
    timeline:present(packet(1, { optionStrikeEvent(2, "TACKLE", 0, 57) })),
    "the no-damage strike is accepted"
  )
  for _ = 1, 300 do
    if #fx.starts > 0 then
      break
    end
    drain(timeline, 1)
  end
  Assert.equal(#fx.starts, 1, "the no-damage visual still starts its selected program")
  Assert.equal(fx.starts[1].effectKey, "TACKLE", "the no-damage start carries the accepted semantic effect key")
  drain(timeline, 3000)
  Assert.isTrue(timeline:settled(), "the no-damage visual drains")
  Assert.equal(battler(timeline:battlers(), 3).hp, 57, "no health fact moves without damage")
  Assert.equal(battler(timeline:battlers(), 1).hp, 52, "the attacker health never moves either")
end

-- A Transform event carrying its source effect runs natively and still
-- applies the copied appearance: essential visual updates are never
-- silenced, even on paths where optional artwork is suppressed.
function T.transformed_appearance_applies_through_the_native_effect()
  local sounds = { played = {} }
  function sounds.sound(cue)
    sounds.played[#sounds.played + 1] = cue
  end
  local fx = optionTaskAwareEffects(optionProbeProgram())
  local timeline = BattleTimeline.new({
    sound = function(cue)
      sounds.sound(cue)
    end,
    effects = fx,
  })
  timeline:reset(openingView())
  Assert.isTrue(
    timeline:present(packet(1, {
      {
        sequence = 3,
        kind = "transformed",
        cause = { key = "TRANSFORM" },
        audience = "public",
        actors = { { combatant = 3 } },
        targets = { { combatant = 3 } },
        actionId = 33,
        effectKey = "TRANSFORM",
        payload = { target = 3, copiedFrom = 1 },
        after = { hp = { [1] = 52, [3] = 57 } },
      },
    })),
    "the transform packet is accepted"
  )
  for _ = 1, 300 do
    if #fx.starts > 0 then
      break
    end
    drain(timeline, 1)
  end
  Assert.equal(#fx.starts, 1, "the transform starts its selected native effect")
  Assert.equal(fx.starts[1].effectKey, "TRANSFORM", "the transform start carries its accepted effect key")
  drain(timeline, 3000)
  Assert.isTrue(timeline:settled(), "the transform drains fully")
  Assert.equal(
    battler(timeline:battlers(), 3).species,
    "EEVEE",
    "the transformed battler displays the copied appearance through the native effect"
  )
end

return { tests = T }
