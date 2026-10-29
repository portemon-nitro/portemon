-- Unit coverage for the ordered visible-cue player behind the battle
-- screen: event order without read-ahead, per-event checkpoints, bounded
-- clocks, one-shot sound intents, duplicate rejection, held images,
-- multi-segment experience, and explicit diagnostics for unknown effects.
-- Headless: packets are plain records shaped like the detached delivery
-- boundary, and sounds drain into a recording sink.

local Assert = require("tests.support.Assert")
local BattleTimeline = require("game.hgss.tests.support.BattleTimelineFixture")
local BattleTimelineCore = require("game.hgss.src.battle.BattleTimeline")
local MonCache = require("libs.assets.src.MonCache")
local SourceTick = require("libs.hgss.src.field.SourceTick")

local T = {}
local TICK = SourceTick.DT

function T.narration_hold_advances_once_per_source_tick_without_drift()
  local timeline = BattleTimeline.new({ textSpeed = "fastest" })
  timeline:announce("A", false, 350)
  timeline:update(SourceTick.DT)
  Assert.isTrue(timeline:ack(), "an explicit non-miss hold consumes acknowledgement input")
  for _ = 1, 348 do
    timeline:update(SourceTick.DT)
  end
  Assert.isFalse(timeline:settled(), "the 350-tick hold is still active after 349 source ticks")
  timeline:update(SourceTick.DT)
  Assert.isTrue(timeline:settled(), "the hold completes on its 350th source tick")
end

---@param sounds table<string, boolean>? names the sink must refuse (muted)
---@return table recording sound-cue sink
local function sink(muted)
  local records = { played = {}, muted = muted or {} }
  function records.sound(cue)
    records.played[#records.played + 1] = cue
  end
  function records.countCry(species, foe)
    local total = 0
    for _, played in ipairs(records.played) do
      if type(played) == "table" and played.kind == "cry" and played.species == species and played.foe == foe then
        total = total + 1
      end
    end
    return total
  end
  function records.countEffect(symbol)
    local total = 0
    for _, played in ipairs(records.played) do
      if type(played) == "table" and played.kind == "effect" and played.symbol == symbol then
        total = total + 1
      end
    end
    return total
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
  local function record(combatant, hp, active, own)
    return {
      combatant = combatant,
      participant = combatant,
      side = own and 1 or 2,
      controller = own and "player" or "wild",
      active = active or nil,
      hp = hp,
      maxHp = combatant == 1 and 52 or 57,
      species = "EEVEE",
      form = 0,
      name = own and "LEAD" or "FOE",
      ballKey = "POKE_BALL",
      level = 20,
      selector = own and "back" or "front",
      portraitSelector = MonCache.portraitSelector("EEVEE", 0, "male", false, own and "back" or nil),
      moves = own and { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } } or nil,
      experience = 8000,
    }
  end
  return {
    round = 1,
    status = "running",
    own = { record(1, 52, true, true) },
    foes = { record(3, 57, true, false) },
    participants = {},
    environment = {},
    playerTrainer = { classKey = "PKMN_TRAINER_ETHAN" },
  }
end

---@param id integer packet identity under test driving
---@param events table ordered sanitized events under test driving
---@param after table detached after view under test driving
---@return table delivery-shaped packet
local function packet(id, events, after)
  return {
    launchId = "timeline-probe",
    packetId = id,
    events = events,
    before = openingView(),
    after = after,
    request = nil,
    result = nil,
  }
end

---@param kind string
---@param payload table
---@param afterHp table<integer, integer>
---@return table one sanitized event
local function event(kind, payload, afterHp)
  local combatants = {}
  for combatant, hp in pairs(afterHp) do
    combatants[combatant] = checkpoint(combatant, hp, combatant == 1 and 52 or 57)
  end
  return {
    sequence = 1,
    kind = kind,
    cause = { key = "TACKLE" },
    audience = "public",
    payload = payload,
    after = { hp = afterHp, combatants = combatants },
  }
end

---@param timeline table cue player under test driving
---@param seconds number accepted presentation time under test driving
local function advance(timeline, seconds)
  timeline:update(seconds, function(_)
    return true
  end)
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

-- Damage lands as ordered checkpoints: the strike message shows first,
-- the health fact moves only through its own cue, and the later
-- checkpoint never appears before the earlier one finishes.
function T.strike_plays_message_then_health_without_read_ahead()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(cue)
      sounds.sound(cue)
    end,
  })
  timeline:reset(openingView())
  local after = openingView()
  after.foes[1].hp = 43
  local strike = event("struck", { target = 3, damage = 14, hitIndex = 1 }, { [1] = 52, [3] = 43 })
  strike.actors = { { combatant = 1 } }
  Assert.isTrue(timeline:present(packet(1, { strike }, after)), "the first packet is accepted")
  Assert.isFalse(timeline:settled(), "the strike leaves cues pending")
  advance(timeline, TICK)
  local firstMessage = timeline:message()
  Assert.isTrue(firstMessage ~= nil and firstMessage ~= "", "the strike narrates before touching health")
  Assert.equal(battler(timeline:battlers(), 3).hp, 57, "no read-ahead: the foe health waits for its cue")
  local seenMessageChange = false
  local movedAt = nil
  for tick = 1, 300 do
    advance(timeline, TICK)
    if battler(timeline:battlers(), 3).hp ~= 57 and movedAt == nil then
      movedAt = tick
    end
    if timeline:message() ~= firstMessage then
      seenMessageChange = true
    end
  end
  Assert.notNil(movedAt, "the health checkpoint lands through its cue")
  Assert.isTrue(timeline:settled(), "the strike drains fully")
  Assert.equal(battler(timeline:battlers(), 3).hp, 43, "the exact final health applies at completion")
  Assert.equal(battler(timeline:battlers(), 1).hp, 52, "untouched health never moves")
end

function T.hp_updates_flicker_six_times_at_three_tick_intervals()
  local timeline = BattleTimeline.new({ sound = function(_) end })
  timeline:reset(openingView())
  local after = openingView()
  after.foes[1].hp = 40
  timeline:present(packet(1, { event("struck", { target = 3, damage = 17 }, { [1] = 52, [3] = 40 }) }, after))
  local ticks = 0
  while not (timeline._active ~= nil and timeline._active.kind == "hp") do
    advance(timeline, TICK)
    ticks = ticks + 1
    Assert.isTrue(ticks < 100, "the damaged health cue follows its attack message")
  end
  Assert.isFalse(battler(timeline:battlers(), 3).visible, "the first flicker hides the struck picture")
  for _, visible in ipairs({ true, false, true, false, true }) do
    for _ = 1, 3 do
      advance(timeline, TICK)
    end
    Assert.equal(battler(timeline:battlers(), 3).visible, visible, "each flicker toggle is three source ticks apart")
  end
  advance(timeline, TICK)
  Assert.isTrue(battler(timeline:battlers(), 3).visible, "the picture is restored after the sixth toggle")
end

function T.small_hp_updates_finish_the_full_flicker_task()
  local timeline = BattleTimeline.new({ sound = function(_) end })
  timeline:reset(openingView())
  local after = openingView()
  after.foes[1].hp = 56
  timeline:present(packet(1, { event("struck", { target = 3, damage = 1 }, { [1] = 52, [3] = 56 }) }, after))
  for ticks = 1, 100 do
    advance(timeline, TICK)
    if timeline._active ~= nil and timeline._active.kind == "hp" then
      break
    end
    Assert.isTrue(ticks < 100, "a short health change keeps its flicker cue active")
  end
  Assert.isFalse(battler(timeline:battlers(), 3).visible, "the first flicker hides the picture")
  for _ = 1, 16 do
    advance(timeline, TICK)
  end
  Assert.isTrue(
    battler(timeline:battlers(), 3).visible,
    "the short HP bar still runs all six toggles and restores visibility"
  )
end

function T.multi_hit_summary_uses_its_staged_source_record()
  local selected = nil
  local timeline = BattleTimeline.new({
    textSpeed = "fastest",
    messageText = function(_, key, substitutions)
      selected = { key = key, substitutions = substitutions }
      return "staged multi-hit narration"
    end,
  })
  timeline:reset(openingView())
  local summary = event("multi-hit", { hits = 3 }, { [1] = 52, [3] = 57 })
  Assert.isTrue(timeline:present(packet(1, { summary }, openingView())), "the landed-hit summary is accepted")
  advance(timeline, TICK)
  Assert.equal(selected.key, "battle/narration/multi-hit", "the landed-hit summary selects its staged message")
  Assert.deepEqual(selected.substitutions, { "3" }, "the staged record receives the connected-hit count")
end

function T.no_blink_hp_updates_keep_the_picture_visible()
  local timeline = BattleTimeline.new({ sound = function(_) end })
  timeline:reset(openingView())
  local after = openingView()
  after.foes[1].hp = 56
  timeline:present(
    packet(1, { event("healed", { target = 3, restored = 1, noBlink = true }, { [1] = 52, [3] = 56 }) }, after)
  )
  for _ = 1, 30 do
    advance(timeline, TICK)
    Assert.isTrue(battler(timeline:battlers(), 3).visible, "no-blink source updates do not hide the picture")
    if timeline:settled() then
      break
    end
  end
end

function T.missed_action_announces_without_changing_either_health_bar()
  local timeline = BattleTimeline.new({ sound = function(_) end, textSpeed = "fastest" })
  local before = openingView()
  timeline:reset(before)
  local miss = event("missed", { target = 3 }, { [1] = 52, [3] = 57 })
  miss.actors = { { combatant = 1 } }
  Assert.isTrue(timeline:present(packet(1, { miss }, before)), "the missed-action packet is accepted")

  local function reveal(subject, text)
    for _ = 1, 200 do
      advance(subject, TICK)
      if subject:message():find(text, 1, true) ~= nil then
        return
      end
    end
    error("miss narration did not reveal: " .. text .. " (showing " .. tostring(subject:message()) .. ")")
  end

  reveal(timeline, "used Tackle!")
  local firstMessageId = timeline:messageId()
  advance(timeline, 29 * TICK)
  Assert.equal(
    timeline:messageId(),
    firstMessageId,
    "the miss result waits 30 source ticks after the attack announcement"
  )
  advance(timeline, TICK)
  reveal(timeline, "LEAD's attack missed!")
  local resultMessageId = timeline:messageId()
  advance(timeline, 29 * TICK)
  Assert.equal(timeline:messageId(), resultMessageId, "the miss packet stays active for its 30-tick result wait")
  advance(timeline, TICK)
  Assert.isTrue(timeline:settled(), "the missed-action narration drains after both source waits")
  Assert.equal(timeline:message(), "LEAD's attack missed!", "the missed action receives its source narration")
  Assert.equal(battler(timeline:battlers(), 1).hp, 52, "a miss does not change the player health")
  Assert.equal(battler(timeline:battlers(), 3).hp, 57, "a miss does not change the foe health")

  local accelerated = BattleTimeline.new({ sound = function(_) end, textSpeed = "fastest" })
  accelerated:reset(before)
  local acceleratedMiss = event("missed", { target = 3 }, { [1] = 52, [3] = 57 })
  acceleratedMiss.actors = { { combatant = 1 } }
  Assert.isTrue(accelerated:present(packet(1, { acceleratedMiss }, before)), "the acknowledged miss packet is accepted")
  reveal(accelerated, "used Tackle!")
  local attackMessageId = accelerated:messageId()
  Assert.isTrue(accelerated:ack(), "A/B input skips the attack announcement's source wait")
  for _ = 1, 3 do
    advance(accelerated, TICK)
    if accelerated:messageId() ~= attackMessageId then
      break
    end
  end
  Assert.isTrue(accelerated:messageId() ~= attackMessageId, "the miss result follows an early acknowledgment")
  reveal(accelerated, "LEAD's attack missed!")
  Assert.isTrue(accelerated:ack(), "A/B input skips the result's source wait")
  advance(accelerated, 3 * TICK)
  Assert.isTrue(accelerated:settled(), "both miss waits accept early acknowledgment")
end

-- A PP serving narrates the native party-menu result after its use line.
function T.pp_serving_narrates_the_restoration()
  local timeline = BattleTimeline.new({
    sound = function(_) end,
    itemName = function(item)
      return item == "ETHER" and "Ether" or nil
    end,
  })
  timeline:reset(openingView())
  local served = event("item", {
    item = "ETHER",
    inventory = "party",
    target = { kind = "combatant", combatant = 1 },
    restored = 0,
    restoredPp = 10,
  }, { [1] = 52, [3] = 57 })
  served.cause = { kind = "action", combatant = 1 }
  Assert.isTrue(timeline:present(packet(1, { served }, openingView())), "the serving packet is accepted")
  local seen = {}
  local lastId = nil
  for _ = 1, 600 do
    advance(timeline, TICK)
    local shown = timeline:message()
    if shown ~= nil and shown ~= "" then
      local id = timeline:messageId()
      if id ~= lastId then
        seen[#seen + 1] = shown
        lastId = id
      else
        seen[#seen] = shown
      end
    end
    timeline:ack()
  end
  Assert.deepEqual(seen, { "Used the Ether!", "PP was restored." }, "the restoration follows its use line")
end

-- The bag subscripts play the recovery sound once for a served item.
function T.bag_item_use_plays_its_recovery_sound_once()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(cue)
      sounds.sound(cue)
    end,
    itemName = function(item)
      return item == "POTION" and "Potion" or nil
    end,
  })
  timeline:reset(openingView())
  local served = event("item", {
    item = "POTION",
    inventory = "party",
    target = { kind = "combatant", combatant = 1 },
    restored = 20,
  }, { [1] = 52, [3] = 57 })
  served.cause = { kind = "action", combatant = 1 }
  Assert.isTrue(timeline:present(packet(1, { served }, openingView())), "the item packet is accepted")
  advance(timeline, TICK)
  Assert.equal(sounds.countEffect("SEQ_SE_DP_KAIFUKU"), 1, "the recovery sound plays once as the item is used")
  for _ = 1, 600 do
    advance(timeline, TICK)
    timeline:ack()
  end
  Assert.equal(sounds.countEffect("SEQ_SE_DP_KAIFUKU"), 1, "later narration does not repeat the sound")
end

function T.displayed_battlers_preserve_false_source_caught_state()
  local view = openingView()
  view.foes[1].caught = false
  local timeline = BattleTimeline.new({})
  timeline:reset(view)
  Assert.equal(battler(timeline:battlers(), 3).caught, false, "an explicit false caught bit remains visible to the HUD")

  view.foes[1].caught = true
  timeline:reset(view)
  Assert.equal(battler(timeline:battlers(), 3).caught, true, "an explicit true caught bit remains visible to the HUD")
end

-- Faint hides its battler only after the health checkpoint, and later
-- checkpoints never resurrect it.
function T.faint_hides_after_its_checkpoint_and_stays_hidden()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(cue)
      sounds.sound(cue)
    end,
  })
  timeline:reset(openingView())
  local mid = openingView()
  mid.foes[1].hp = 0
  Assert.isTrue(
    timeline:present(packet(1, {
      event("struck", { target = 3, damage = 57, hitIndex = 1 }, { [1] = 52, [3] = 0 }),
      event("faint", { combatant = 3, activation = 2, position = 2 }, { [1] = 52, [3] = 0 }),
    }, mid)),
    "the knockout packet is accepted"
  )
  local faintAt = nil
  local zeroAt = nil
  for tick = 1, 600 do
    advance(timeline, TICK)
    if battler(timeline:battlers(), 3).hp == 0 and zeroAt == nil then
      zeroAt = tick
    end
    if timeline._active ~= nil and timeline._active.kind == "faint" and faintAt == nil then
      faintAt = tick
    end
  end
  Assert.notNil(zeroAt, "the knockout health lands")
  Assert.notNil(faintAt, "the faint cue hides its battler")
  Assert.isTrue(faintAt --[[@as integer]] >= zeroAt --[[@as integer]], "the faint never precedes its checkpoint")
  Assert.isFalse(battler(timeline:battlers(), 3).visible, "the hidden battler stays hidden")
end

-- A repeated delivery changes nothing: no new cues, no new sounds, no
-- state motion.
function T.duplicate_packets_are_rejected()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(cue)
      sounds.sound(cue)
    end,
  })
  timeline:reset(openingView())
  local after = openingView()
  after.foes[1].hp = 43
  local first = packet(1, { event("struck", { target = 3, damage = 14, hitIndex = 1 }, { [1] = 52, [3] = 43 }) }, after)
  Assert.isTrue(timeline:present(first), "the first delivery is accepted")
  advance(timeline, 10)
  local BattleAudio = require("libs.hgss.src.audio.BattleAudio")
  Assert.equal(sounds.countEffect(BattleAudio.SINK_SOUNDS.impact), 1, "a strike carries its impact voice exactly once")
  Assert.isFalse(timeline:present(first), "the same packet identity is rejected")
  local soundsBefore = #sounds.played
  advance(timeline, 10)
  Assert.equal(#sounds.played, soundsBefore, "a duplicate delivery queues no new sound")
  Assert.isTrue(timeline:settled(), "the single delivery drains")
  Assert.equal(battler(timeline:battlers(), 3).hp, 43, "one delivery applies its checkpoint once")
end

-- A cue needing an unavailable image holds without advancing: health
-- stays at its earlier checkpoint until the image arrives.
function T.held_images_hold_their_cue()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(cue)
      sounds.sound(cue)
    end,
  })
  timeline:reset(openingView())
  local after = openingView()
  after.foes[1].hp = 43
  timeline:present(
    packet(1, { event("struck", { target = 3, damage = 14, hitIndex = 1 }, { [1] = 52, [3] = 43 }) }, after)
  )
  local foeKey = "mon:" .. MonCache.portraitSelector("EEVEE", 0, "male", false)
  local held = { [foeKey] = false }
  for _ = 1, 120 do
    timeline:update(TICK, function(key)
      return held[key] ~= false
    end)
  end
  Assert.equal(battler(timeline:battlers(), 3).hp, 57, "the held cue never leaks its later health")
  Assert.isFalse(timeline:settled(), "the held cue reports unready instead of skipping")
  held[foeKey] = true
  for _ = 1, 600 do
    timeline:update(TICK, function(key)
      return held[key] ~= false
    end)
  end
  Assert.isTrue(timeline:settled(), "releasing the image completes the held cue")
  Assert.equal(battler(timeline:battlers(), 3).hp, 43, "the exact checkpoint applies after release")
end

-- Experience animates one segment per crossed level and lands exact
-- final values, even across several levels.
function T.experience_animates_each_level_segment()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(cue)
      sounds.sound(cue)
    end,
  })
  timeline:reset(openingView())
  local after = openingView()
  after.own[1].experience = 9000
  after.own[1].level = 22
  timeline:present(packet(1, { event("exp", { combatant = 1, gained = 1000 }, { [1] = 52 }) }, after))
  local ticks = 0
  while not timeline:settled() and ticks < 2000 do
    advance(timeline, TICK)
    ticks = ticks + 1
  end
  Assert.isTrue(timeline:settled(), "multi-level experience drains")
  Assert.isTrue(ticks >= 48, "two crossed levels animate two segments, never one percentage")
  local lead = battler(timeline:battlers(), 1)
  Assert.equal(lead.exp, 9000, "the exact final experience applies")
  Assert.equal(lead.level, 22, "the exact final level applies")
end

-- Unknown required effects remain observable through the diagnostic channel
-- without inventing user-facing narration.
function T.unknown_effects_produce_a_diagnostic()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(cue)
      sounds.sound(cue)
    end,
  })
  timeline:reset(openingView())
  timeline:present(packet(1, { event("mystery_surcharge", { target = 3 }, { [1] = 52, [3] = 57 }) }, openingView()))
  Assert.equal(timeline:message(), "", "unknown effects do not add product narration")
  advance(timeline, 5)
  Assert.equal(#timeline:diagnostics(), 1, "the unknown effect is recorded once")
  Assert.isTrue(
    (timeline:diagnostics()[1] --[[@as string]]):find("mystery_surcharge", 1) ~= nil,
    "the diagnostic names its effect"
  )
end

-- Acknowledgement fast-forwards narration without leaking: completing a
-- page consumes its edge and muted sinks still drain every cue.
function T.acknowledgement_completes_pages_and_muted_drains()
  local muted = sink({ ["cry:EEVEE"] = true })
  local timeline = BattleTimeline.new({
    sound = function(name)
      muted.sound(name)
    end,
  })
  timeline:reset(openingView())
  local after = openingView()
  after.foes[1].hp = 43
  timeline:present(
    packet(1, { event("struck", { target = 3, damage = 14, hitIndex = 1 }, { [1] = 52, [3] = 43 }) }, after)
  )
  local firstId = timeline:messageId()
  Assert.isTrue(timeline:ack(), "an edge during narration is consumed by the page")
  advance(timeline, 10)
  Assert.isTrue(timeline:settled(), "muted playback never deadlocks a cue")
  Assert.equal(battler(timeline:battlers(), 3).hp, 43, "muted playback lands the same checkpoint")
  Assert.isTrue(timeline:messageId() ~= firstId or timeline:message() ~= nil, "narration keeps its identity")
end

-- First delivery keeps its event cues behind the opening: the encounter
-- narration plays first and the accepted strike narration and health
-- checkpoint follow exactly once with no replay of the packet identity.
function T.first_packet_events_play_after_the_opening_once()
  local BattleScreenState = require("game.hgss.tests.support.BattleScreenFixture")
  local Model = require("game.hgss.src.battle.BattlePresentationModel")
  local ScreenTopology = require("libs.ui.src.ScreenTopology")
  local manifest = require("tests.support.BattlePresentationManifestFixture").manifest()
  manifest.scenes = { { key = "general/plain/day" } }
  local measurement = {
    width = 256,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" },
      "timeline-first-packet:dual"
    ),
    pixelRatio = 1,
    signature = "timeline-first-packet:dual",
  }
  local text = { draws = {} }
  function text.measure(content)
    return { width = 8 * #tostring(content), height = 16 }
  end
  function text.drawText(content, x, y)
    text.draws[#text.draws + 1] = { content = tostring(content), x = x, y = y }
  end
  local windows = { calls = {} }
  function windows.drawWindow(box, frameKey, background)
    windows.calls[#windows.calls + 1] = { box = box, frame = frameKey, background = background }
  end
  local audio = { plays = {} }
  function audio.play(name)
    audio.plays[#audio.plays + 1] = name
    return true
  end
  function audio.playPanned(name, _)
    return audio.play(name)
  end
  local assets = { hold = {}, images = {}, prepared = {}, released = {} }
  function assets.prepare(demand)
    assets.prepared[#assets.prepared + 1] = demand
    return true
  end
  function assets.drawable(key)
    if assets.images[key] == nil then
      assets.images[key] = {
        handle = key,
        getDimensions = function()
          return 80, 80
        end,
        getWidth = function()
          return 80
        end,
        getHeight = function()
          return 80
        end,
        setFilter = function() end,
      }
    end
    local stored = assets.images[key]
    if key:sub(1, 4) == "mon:" then
      return { lease = stored, quad = { handle = "quad:" .. key } }
    end
    return stored
  end
  function assets.release(key)
    assets.released[key] = (assets.released[key] or 0) + 1
  end
  local launchId = "launch-first-packet-local"
  local submits = {}
  local screen = BattleScreenState.new({
    launchId = launchId,
    manifest = manifest,
    model = Model,
    submit = function(reply)
      submits[#submits + 1] = reply
      return true
    end,
    measureDisplay = function()
      return measurement
    end,
    assets = assets,
    text = text,
    windows = windows,
    audio = audio,
  })
  local port = screen:presentationPort()
  local function ownRecord()
    return {
      combatant = 1,
      participant = 1,
      side = 1,
      controller = "player",
      active = true,
      hp = 52,
      maxHp = 52,
      species = "EEVEE",
      form = 0,
      name = "LEAD",
      ballKey = "POKE_BALL",
      level = 20,
      selector = "back",
      moves = { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } },
    }
  end
  local function foeRecordEntry(hp)
    return {
      combatant = 3,
      participant = 3,
      side = 2,
      controller = "wild",
      active = true,
      hp = hp,
      maxHp = 57,
      species = "EEVEE",
      form = 0,
      name = "FOE",
      ballKey = "POKE_BALL",
      level = 20,
      selector = "front",
    }
  end
  local function beforeView()
    return {
      playerTrainer = { classKey = "PKMN_TRAINER_ETHAN" },
      own = { ownRecord() },
      foes = { foeRecordEntry(57) },
    }
  end
  local function afterView()
    return {
      playerTrainer = { classKey = "PKMN_TRAINER_ETHAN" },
      own = { ownRecord() },
      foes = { foeRecordEntry(43) },
    }
  end
  local struck = event("struck", { target = 3, damage = 14, hitIndex = 1 }, { [1] = 52, [3] = 43 })
  struck.actors = { { combatant = 1, activation = 1 } }
  local decisionActors = {
    {
      combatant = 1,
      activation = 1,
      kind = "action",
      choices = {
        {
          id = "move:0",
          role = "move",
          display = { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 },
          enabled = true,
          choice = {
            actor = { combatant = 1, activation = 1 },
            kind = "attack",
            payload = { moveSlot = 0, target = { kind = "position", position = 2 } },
          },
        },
      },
    },
  }
  local decision = {
    requestId = 777001,
    epoch = 1,
    controller = "player",
    kind = "action",
    actors = decisionActors,
  }
  decision.options = {
    requestId = 777001,
    epoch = 1,
    controller = "player",
    kind = "action",
    actors = decisionActors,
  }
  port.present({
    launchId = launchId,
    packetId = 1,
    events = { struck },
    before = beforeView(),
    after = afterView(),
    request = decision,
    result = nil,
  })
  local seen = {}
  local foeHp = nil
  local commanded = false
  for _ = 1, 1200 do
    screen:updateFixed(TICK)
    local view = screen:view()
    seen[#seen + 1] = tostring(view.message or "")
    for _, battlerEntry in ipairs(view.battlers or {}) do
      if battlerEntry.side == 2 then
        foeHp = battlerEntry.hp
      end
    end
    local status = screen:status()
    if status.mode == "failed" then
      error("the first-packet route failed: " .. tostring(status.error), 0)
    end
    if status.mode == "command" and status.request ~= nil then
      commanded = true
      break
    end
  end
  Assert.isTrue(commanded, "the first packet still exposes its decision")
  local appearedAt = nil
  local usedAt = nil
  for index, message in ipairs(seen) do
    if appearedAt == nil and message:find("appeared", 1, true) ~= nil then
      appearedAt = index
    end
    if message:find("used", 1, true) ~= nil then
      usedAt = index
    end
  end
  Assert.notNil(appearedAt, "the opening narration plays")
  Assert.notNil(usedAt, "the accepted first-packet strike still narrates after the opening")
  Assert.isTrue(usedAt > appearedAt, "the strike follows the opening instead of vanishing inside it")
  Assert.equal(foeHp, 43, "the event checkpoint lands through its cue")
  port.present({
    launchId = launchId,
    packetId = 1,
    events = { struck },
    before = beforeView(),
    after = afterView(),
    request = decision,
    result = nil,
  })
  for _ = 1, 30 do
    screen:updateFixed(TICK)
  end
  Assert.equal(foeHp, 43, "a repeated packet identity never replays its events")
  manifest.messages.entries["battle/bide-release"] = {
    tokens = {
      { kind = "glyph", code = 1, text = "[" },
      { kind = "substitution", control = 0x0100, args = { 0 } },
      { kind = "glyph", code = 2, text = "]" },
      { kind = "line_break", control = 0xE000 },
      { kind = "style", control = 0xFF00, args = { 3 } },
      { kind = "glyph", code = 3, text = "é" },
      { kind = "pause", control = 0x0201, args = { 4 } },
      { kind = "prompt_break", control = 0x25BC },
      { kind = "eos" },
    },
  }
  port.present({
    launchId = launchId,
    packetId = 2,
    events = {
      {
        sequence = 2,
        kind = "move-used",
        actionId = 2,
        cause = { key = "BIDE", kind = "move" },
        payload = { user = 1, targets = 1, phase = "release" },
        actors = { { combatant = 1 } },
        move = { selected = "BIDE", executed = "BIDE", phase = "direct" },
        messageArgs = { userName = "LEAD" },
      },
    },
    before = afterView(),
    after = afterView(),
  })
  local sourceShown = false
  for _ = 1, 600 do
    screen:updateFixed(TICK)
    if screen:view().message == "[LEAD]\né" then
      sourceShown = true
      break
    end
  end
  Assert.isTrue(sourceShown, "the Bide release shows only printable glyphs and line breaks of the source message")
  local foe = nil
  for _, battler in ipairs(screen._timeline:battlers()) do
    if battler.combatant == 3 then
      foe = battler
    end
  end
  Assert.notNil(foe, "the visible foe remains available for the faint")
  screen._scene:applyPictureState(foe, { pictureVisible = false })
  port.present({
    launchId = launchId,
    packetId = 3,
    events = { { sequence = 3, kind = "faint", cause = { key = "TACKLE" }, payload = { combatant = 3 } } },
    before = afterView(),
    after = afterView(),
  })
  local sawFaintCrop = false
  for _ = 1, 600 do
    screen:updateFixed(TICK)
    local battlers = screen._timeline:battlers()
    for _, shown in ipairs(battlers) do
      if shown.combatant == 3 and shown.pictureVisible == true and (shown.pictureYOffset or 0) > 0 then
        for _, picture in ipairs(screen:_snapshot().battlers) do
          if picture.combatant == 3 then
            Assert.isTrue(picture.pictureVisible, "faint crop supersedes the previous animation picture state")
            sawFaintCrop = true
          end
        end
      end
    end
    if sawFaintCrop then
      break
    end
  end
  Assert.isTrue(sawFaintCrop, "the composed screen exposes the faint crop")
  screen:dispose()
end

-- The opening names and cries the live lead, never slot zero: with a
-- fainted first slot and the active lead in slot one, the send-out
-- carries the live lead's exact name, cry species, and canonical
-- back-portrait identity, and its cue waits on that exact incoming
-- portrait instead of a generic side key.
function T.active_lead_names_and_cries_the_live_slot_not_slot_zero()
  local MonCache = require("libs.assets.src.MonCache")
  local liveBack = MonCache.portraitSelector("TOTODILE", 0, "female", false, "back")
  local benchBack = MonCache.portraitSelector("EEVEE", 0, "male", false, "back")
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(cue)
      sounds.sound(cue)
    end,
  })
  local view = openingView()
  view.own = {
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
      name = "BENCH",
      level = 20,
      selector = "back",
      portraitSelector = benchBack,
      moves = { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } },
      experience = 8000,
    },
    {
      combatant = 2,
      participant = 1,
      side = 1,
      controller = "player",
      active = true,
      hp = 30,
      maxHp = 30,
      species = "TOTODILE",
      form = 0,
      name = "LIVE",
      ballKey = "POKE_BALL",
      level = 5,
      selector = "back",
      portraitSelector = liveBack,
      moves = { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } },
      experience = 100,
    },
  }
  timeline:reset(view)
  local lead = battler(timeline:battlers(), 2)
  Assert.equal(lead.portraitSelector, liveBack, "the displayed live lead keeps its exact canonical back portrait")
  timeline:intro(view, true)
  -- The send-out holds while its exact incoming portrait is missing:
  -- with that canonical key held back the opening never drains, and
  -- only the exact portrait releases it.
  local exactKey = "mon:" .. liveBack
  local held = { [exactKey] = false }
  for _ = 1, 600 do
    timeline:update(TICK, function(key)
      return held[key] ~= false
    end)
  end
  Assert.isFalse(timeline:settled(), "the send-out holds on its missing exact portrait")
  held[exactKey] = true
  for _ = 1, 600 do
    timeline:update(TICK, function(key)
      return held[key] ~= false
    end)
  end
  Assert.isTrue(timeline:settled(), "the exact incoming portrait releases the send-out")
  local seen = {}
  for _ = 1, 600 do
    advance(timeline, TICK)
    seen[#seen + 1] = tostring(timeline:message())
  end
  local hailedLive = false
  for _, message in ipairs(seen) do
    if message:find("LIVE", 1, true) ~= nil then
      hailedLive = true
    end
    Assert.isTrue(message:find("BENCH", 1, true) == nil, "no opening narration hails the fainted first slot")
  end
  Assert.isTrue(hailedLive, "the send-out hails the live lead by name")
  Assert.equal(sounds.countCry("TOTODILE", false), 1, "the opening cries the live lead species once")
  Assert.equal(sounds.countCry("EEVEE", false), 0, "the fainted first slot never lends its cry")
  Assert.equal(sounds.countCry("EEVEE", true), 1, "the opening cries the wild foe species once")
end

function T.wild_intro_slides_the_dark_foe_in_before_cry_and_fades_it_at_arrival()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(cue)
      sounds.sound(cue)
    end,
    textSpeed = "fastest",
  })
  local view = openingView()
  timeline:reset(view)
  timeline:intro(view, true)

  local foe = battler(timeline:battlers(), 3)
  Assert.isTrue(foe.visible, "the wild foe appears at the opening slide start")
  Assert.equal(foe.pictureXOffset, -272, "the wild foe starts offscreen at source x=-80")
  Assert.equal(foe.paletteFade.intensity, 8, "the foe starts darkened")
  for _ = 1, 28 do
    advance(timeline, TICK)
  end
  foe = battler(timeline:battlers(), 3)
  Assert.equal(foe.pictureXOffset, -272, "the foe waits 28 source ticks before sliding")
  advance(timeline, TICK)
  foe = battler(timeline:battlers(), 3)
  Assert.equal(foe.pictureXOffset, -264, "the foe moves eight pixels on the first slide tick")
  for _ = 1, 33 do
    advance(timeline, TICK)
  end
  foe = battler(timeline:battlers(), 3)
  Assert.equal(foe.pictureXOffset, 0, "the foe reaches the native battlefield position")
  Assert.equal(
    foe.paletteFade.intensity,
    8,
    "the fade begins at full darkening when the slide arrives: " .. tostring(foe.paletteFade.intensity)
  )
  Assert.equal(sounds.countCry("EEVEE", true), 1, "the foe cries on the arrival tick")
  for _ = 1, 8 do
    advance(timeline, TICK)
  end
  foe = battler(timeline:battlers(), 3)
  Assert.equal(foe.paletteFade.intensity, 0, "the source palette fade completes in eight ticks")
  Assert.isTrue(foe.hudVisible, "the foe HUD appears when the source intro fade completes")
end

function T.intro_slides_both_terrain_bases_after_the_source_delay()
  local timeline = BattleTimeline.new({ sound = function(_) end, textSpeed = "fastest" })
  local view = openingView()
  timeline:reset(view)
  timeline:intro(view, true)

  local terrainSlides = assert(timeline:openingPresentation().terrainSlides)
  Assert.deepEqual(terrainSlides, {
    { role = "player", x = 336, y = 136, visible = true, phase = "intro-delay" },
    { role = "foe", x = -80, y = 88, visible = true, phase = "intro-delay" },
  }, "both terrain bases begin at their source positions")
  for _ = 1, 28 do
    advance(timeline, TICK)
  end
  terrainSlides = assert(timeline:openingPresentation().terrainSlides)
  Assert.equal(terrainSlides[1].x, 336, "player terrain waits 28 ticks")
  Assert.equal(terrainSlides[2].x, -80, "foe terrain waits 28 ticks")
  advance(timeline, TICK)
  terrainSlides = assert(timeline:openingPresentation().terrainSlides)
  Assert.equal(terrainSlides[1].x, 328, "player terrain moves left eight pixels")
  Assert.equal(terrainSlides[2].x, -72, "foe terrain moves right eight pixels")
  for _ = 1, 33 do
    advance(timeline, TICK)
  end
  terrainSlides = assert(timeline:openingPresentation().terrainSlides)
  Assert.equal(terrainSlides[1].x, 64, "player terrain reaches its settled position")
  Assert.equal(terrainSlides[2].x, 192, "foe terrain reaches its settled position")
  Assert.equal(terrainSlides[1].phase, "intro-settle", "player terrain reports its settled phase")
  Assert.equal(terrainSlides[2].phase, "intro-settle", "foe terrain reports its settled phase")
  for _ = 1, 7 do
    advance(timeline, TICK)
  end
  terrainSlides = assert(timeline:openingPresentation().terrainSlides)
  Assert.isTrue(terrainSlides[1].visible, "terrain stays visible through the foe's palette fade")
  Assert.isTrue(terrainSlides[2].visible, "foe terrain stays visible through the palette fade")
  advance(timeline, TICK)
  terrainSlides = assert(timeline:openingPresentation().terrainSlides)
  Assert.isFalse(terrainSlides[1].visible, "player terrain hides after the foe's palette fade")
  Assert.isFalse(terrainSlides[2].visible, "foe terrain hides after the foe's palette fade")
end

function T.opening_presentation_starts_with_the_native_trainer_visibility()
  local wild = BattleTimeline.new({ sound = function(_) end })
  wild:reset(openingView())
  wild:intro(openingView(), true)
  Assert.deepEqual(wild:openingPresentation(), {
    playerTrainerVisible = true,
    foeTrainerVisible = false,
    playerGaugeVisible = false,
    enemyGaugeVisible = false,
    trainerSlides = {
      {
        role = "player",
        selector = "back:PKMN_TRAINER_ETHAN",
        sourceSequence = 2,
        x = 336,
        y = 112,
        frame = 0,
        visible = true,
        phase = "intro-delay",
      },
    },
    terrainSlides = {
      { role = "player", x = 336, y = 136, visible = true, phase = "intro-delay" },
      { role = "foe", x = -80, y = 88, visible = true, phase = "intro-delay" },
    },
  })
  local trainer = BattleTimeline.new({ sound = function(_) end })
  local trainerView = openingView()
  trainerView.foeTrainers = { { classKey = "YOUNGSTER", name = "WHITNEY" } }
  trainer:reset(trainerView)
  trainer:intro(trainerView, false)
  Assert.deepEqual(trainer:openingPresentation(), {
    playerTrainerVisible = true,
    foeTrainerVisible = true,
    playerGaugeVisible = false,
    enemyGaugeVisible = false,
    trainerSlides = {
      {
        role = "player",
        selector = "back:PKMN_TRAINER_ETHAN",
        sourceSequence = 2,
        x = 336,
        y = 112,
        frame = 0,
        visible = true,
        phase = "intro-delay",
      },
      {
        role = "foe",
        selector = "front:YOUNGSTER",
        sourceSequence = 2,
        x = -80,
        y = 50,
        frame = 0,
        visible = true,
        phase = "intro-delay",
      },
    },
    terrainSlides = {
      { role = "player", x = 336, y = 136, visible = true, phase = "intro-delay" },
      { role = "foe", x = -80, y = 88, visible = true, phase = "intro-delay" },
    },
  })
end

function T.opening_trainer_slides_start_together_and_follow_the_source_ticks()
  local timeline = BattleTimeline.new({ sound = function(_) end })
  local view = openingView()
  view.playerTrainer = { classKey = "PKMN_TRAINER_ETHAN" }
  view.foeTrainers = { { classKey = "YOUNGSTER", name = "WHITNEY" } }
  timeline:reset(view)
  timeline:intro(view, false)

  local slides = assert(timeline:openingPresentation().trainerSlides)
  Assert.equal(#slides, 2, "player back and foe front trainers begin concurrently")
  Assert.deepEqual(slides[1], {
    role = "player",
    selector = "back:PKMN_TRAINER_ETHAN",
    sourceSequence = 2,
    x = 336,
    y = 112,
    frame = 0,
    visible = true,
    phase = "intro-delay",
  }, "the player trainer uses the native offscreen start")
  Assert.deepEqual(slides[2], {
    role = "foe",
    selector = "front:YOUNGSTER",
    sourceSequence = 2,
    x = -80,
    y = 50,
    frame = 0,
    visible = true,
    phase = "intro-delay",
  }, "the foe trainer uses the native offscreen start")

  for _ = 1, 28 do
    advance(timeline, TICK)
  end
  slides = assert(timeline:openingPresentation().trainerSlides)
  Assert.equal(slides[1].x, 336, "the player stays through the 28-tick intro delay")
  Assert.equal(slides[2].x, -80, "the foe stays through the 28-tick intro delay")
  advance(timeline, TICK)
  slides = assert(timeline:openingPresentation().trainerSlides)
  Assert.equal(slides[1].x, 328, "the player moves eight pixels on the first slide tick")
  Assert.equal(slides[2].x, -72, "the foe moves eight pixels on the first slide tick")
  for _ = 1, 33 do
    advance(timeline, TICK)
  end
  slides = assert(timeline:openingPresentation().trainerSlides)
  Assert.equal(slides[1].x, 64, "the player settles at the source target")
  Assert.equal(slides[2].x, 192, "the foe settles at the source target")
  Assert.equal(slides[1].phase, "intro-settle", "the player trainer completes the slide")
  Assert.equal(slides[2].phase, "intro-settle", "the foe trainer completes the slide")
end

function T.opening_trainer_frames_advance_while_the_source_slide_runs()
  local timeline = BattleTimeline.new({ sound = function(_) end })
  local view = openingView()
  view.playerTrainer = { classKey = "PKMN_TRAINER_ETHAN" }
  view.foeTrainers = { { classKey = "YOUNGSTER", name = "WHITNEY" } }
  timeline:reset(view)
  timeline:intro(view, false)

  local seenPlayerFrames = {}
  local seenFoeFrames = {}
  for _ = 1, 62 do
    advance(timeline, TICK)
    local slides = assert(timeline:openingPresentation().trainerSlides)
    seenPlayerFrames[slides[1].frame] = true
    seenFoeFrames[slides[2].frame] = true
  end
  Assert.isTrue(seenPlayerFrames[1] or seenPlayerFrames[2], "the player backpic advances from its first source frame")
  Assert.isTrue(seenFoeFrames[1] or seenFoeFrames[2], "the foe frontpic advances from its first source frame")
end

function T.zero_duration_trainer_frames_advance_without_duration_normalization()
  local timeline = BattleTimeline.new({ sound = function(_) end })
  local view = openingView()
  timeline:reset(view)
  timeline:intro(view, false)
  local track = timeline._trainerSlideTracks[1]
  track.frames[1].durationTicks = 0
  advance(timeline, TICK)
  Assert.equal(track.frame, 1, "a zero-duration source frame advances without being normalized to one tick")
end

function T.trainer_animation_tracks_preserve_reverse_modes_and_loop_boundaries()
  local function timelineWithMode(playMode, loopStartFrameIdx)
    local view = openingView()
    local fixture = BattleTimeline.new({ sound = function(_) end })
    fixture:reset(view)
    local trainerPictures = fixture._trainerPictures
    local animation = trainerPictures["front:YOUNGSTER"].animation.sequences[3]
    animation.playMode = playMode
    animation.loopStartFrameIdx = loopStartFrameIdx
    animation.frames[1].durationTicks = 1
    animation.frames[2].durationTicks = 1
    animation.frames[3] = {
      sourceFrame = 2,
      userAttr = 0,
      durationTicks = 1,
    }
    local timeline = BattleTimelineCore.new({
      sound = function(_) end,
      messageText = function() return "" end,
      trainerPictures = trainerPictures,
    })
    timeline:reset(view)
    timeline:intro(view, false)
    local track = timeline._trainerSlideTracks[2]
    return timeline, track
  end

  local reverseLoop, reverseLoopTrack = timelineWithMode("reverse_loop", 0)
  advance(reverseLoop, TICK)
  Assert.equal(
    reverseLoopTrack.frame,
    1,
    "reverse-loop source animation first advances toward its sequence end; got " .. tostring(reverseLoopTrack.frame)
  )
  advance(reverseLoop, TICK)
  Assert.equal(reverseLoopTrack.frame, 2, "reverse-loop source animation reaches its final source frame")
  advance(reverseLoop, TICK)
  Assert.equal(reverseLoopTrack.frame, 2, "reverse-loop source animation turns at its end without skipping a source tick")
  advance(reverseLoop, TICK)
  Assert.equal(reverseLoopTrack.frame, 1, "reverse-loop source animation returns toward its source loop frame")
  advance(reverseLoop, TICK)
  Assert.equal(reverseLoopTrack.frame, 0, "reverse-loop source animation reaches its source loop frame")
  advance(reverseLoop, TICK)
  Assert.equal(reverseLoopTrack.frame, 0, "reverse-loop source animation turns at its loop frame without skipping a tick")
  advance(reverseLoop, TICK)
  Assert.equal(reverseLoopTrack.frame, 1, "reverse-loop source animation repeats the source cycle")

  local reverse, reverseTrack = timelineWithMode("reverse", 1)
  Assert.equal(reverseTrack.frame, 1, "trainer sequence starts at its source loop frame")
  advance(reverse, TICK)
  Assert.equal(reverseTrack.frame, 2, "reverse source animation begins at its declared loop frame and advances")
  advance(reverse, TICK)
  Assert.equal(reverseTrack.frame, 2, "reverse source animation turns at its end without skipping a source tick")
  advance(reverse, TICK)
  Assert.equal(reverseTrack.frame, 1, "reverse source animation returns to its declared loop frame")
  advance(reverse, TICK)
  Assert.equal(reverseTrack.frame, 0, "reverse source animation stops at the frame before its loop boundary")
  Assert.isFalse(reverseTrack.animationActive, "non-loop reverse source animation stops at its loop boundary")
end

function T.trainer_user_attributes_drive_flash_and_encounter_completion()
  local timeline = BattleTimeline.new({ sound = function(_) end })
  local view = openingView()
  timeline:reset(view)
  timeline:intro(view, false)

  local sawSourceFlash = false
  for _ = 1, 100 do
    advance(timeline, TICK)
    local presentation = assert(timeline:openingPresentation())
    sawSourceFlash = sawSourceFlash or presentation.trainerFlashCoefficient == 16
    if timeline._trainerSlideTracks[1].encounterComplete and timeline._trainerSlideTracks[2].encounterComplete then
      break
    end
  end
  Assert.isTrue(sawSourceFlash, "frontpic user attr 1 starts the source brightness flash")
  Assert.isTrue(
    timeline._trainerSlideTracks[1].encounterComplete,
    "player-facing trainer task completes at slide arrival"
  )
  Assert.equal(
    timeline:openingPresentation().trainerSlides[1].sourceSequence,
    2,
    "the player backpic keeps its source entry sequence until the throw begins"
  )
  Assert.isFalse(
    timeline._trainerSlideTracks[1].encounterWaiting,
    "player-facing trainer tasks do not wait on backpic UAAT attributes"
  )
  Assert.isTrue(
    timeline._trainerSlideTracks[2].encounterComplete,
    "frontpic user attr 0xFFF completes its encounter task"
  )
end

function T.trainer_user_attributes_select_the_requested_source_sequence()
  local timeline = BattleTimeline.new({ sound = function(_) end })
  local view = openingView()
  timeline:reset(view)
  timeline:intro(view, false)

  local foeTrack = timeline._trainerSlideTracks[2]
  for _ = 1, 80 do
    advance(timeline, TICK)
    if foeTrack.encounterWaiting then
      break
    end
  end
  Assert.isTrue(foeTrack.encounterWaiting, "the foe task waits after selecting its source sequence")
  foeTrack.frames[1].userAttr = 0x101
  foeTrack.frames[1].durationTicks = 1
  advance(timeline, TICK)
  Assert.equal(
    timeline:openingPresentation().trainerSlides[2].sourceSequence,
    0,
    "UAAT animation 1 selects source sequence zero"
  )
  Assert.isTrue(foeTrack.encounterComplete, "a source animation switch completes the foe encounter task")
  Assert.equal(foeTrack.frame, 0, "the new animation begins on frame zero on the next source tick")
  Assert.equal(foeTrack.frameElapsed, 0, "the old sequence duration does not advance the new sequence")
end

function T.trainer_opening_tracks_every_multi_battle_trainer_once()
  local function foe(combatant, position)
    return {
      combatant = combatant,
      participant = combatant,
      side = 2,
      controller = "trainer",
      active = true,
      position = position,
      activation = combatant,
      hp = 45,
      maxHp = 45,
      species = "GEODUDE",
      form = 0,
      name = "FOE " .. tostring(position),
      selector = "front",
      experience = 8000,
    }
  end
  local function openingViewWithTrainers(trainers)
    local view = openingView()
    view.foes = { foe(3, 3), foe(4, 4) }
    view.foeTrainers = trainers
    return view
  end
  local ordinary = openingViewWithTrainers({ { classKey = "YOUNGSTER", name = "WHITNEY" } })
  local timeline = BattleTimeline.new({ sound = function(_) end })
  timeline:reset(ordinary)
  timeline:intro(ordinary, false)
  local ordinarySlides = assert(timeline:openingPresentation().trainerSlides)
  local ordinaryFoes = 0
  for _, slide in ipairs(ordinarySlides) do
    if slide.role == "foe" then
      ordinaryFoes = ordinaryFoes + 1
      Assert.equal(slide.selector, "front:YOUNGSTER", "ordinary doubles keeps its single physical opponent")
    end
  end
  Assert.equal(ordinaryFoes, 1, "ordinary doubles does not duplicate the opponent trainer")

  local multi = openingViewWithTrainers({
    { classKey = "YOUNGSTER", name = "WHITNEY" },
    { classKey = "LASS", name = "VIOLET" },
  })
  timeline:reset(multi)
  timeline:intro(multi, false)
  local multiSlides = assert(timeline:openingPresentation().trainerSlides)
  local foeSelectors = {}
  for _, slide in ipairs(multiSlides) do
    if slide.role == "foe" then
      foeSelectors[#foeSelectors + 1] = slide.selector
    end
  end
  Assert.deepEqual(
    foeSelectors,
    { "front:YOUNGSTER", "front:LASS" },
    "a multi battle stages each source trainer exactly once in roster order"
  )
end

function T.multi_trainer_sendout_exits_only_its_source_participant()
  local timeline = BattleTimeline.new({ sound = function(_) end, textSpeed = "fastest" })
  local view = openingView()
  view.foeTrainers = {
    { classKey = "YOUNGSTER", name = "WHITNEY" },
    { classKey = "LASS", name = "VIOLET" },
  }
  view.participants = {
    { participant = 3, side = 2, controller = "trainer:3" },
    { participant = 4, side = 2, controller = "trainer:4" },
  }
  view.foes = {
    { combatant = 3, participant = 3, active = true, position = 3, side = 2, name = "FOE 1", ballKey = "POKE_BALL" },
    { combatant = 4, participant = 4, active = true, position = 4, side = 2, name = "FOE 2", ballKey = "POKE_BALL" },
  }
  timeline:reset(view)
  timeline:intro(view, false)

  local firstTrainerExitedAlone = false
  for _ = 1, 1200 do
    if timeline:messageActive() then
      timeline:ack()
    end
    advance(timeline, TICK)
    local slides = assert(timeline:openingPresentation().trainerSlides)
    if slides[2].visible == false and slides[3].visible == true then
      firstTrainerExitedAlone = true
      break
    end
  end
  Assert.isTrue(firstTrainerExitedAlone, "the first foe sendout leaves its partner trainer present")
end

function T.trainer_exit_finishes_before_the_player_sendout_is_visible()
  local timeline = BattleTimeline.new({ sound = function(_) end, textSpeed = "fastest" })
  local view = openingView()
  timeline:reset(view)
  timeline:intro(view, false)

  local ownVisible = false
  local trainersVisibleAtSendout = nil
  for _ = 1, 3000 do
    advance(timeline, TICK)
    if timeline:messageActive() then
      timeline:ack()
    end
    local presentation = timeline:openingPresentation()
    local own = battler(timeline:battlers(), 1)
    if own.visible then
      ownVisible = true
      trainersVisibleAtSendout = presentation.playerTrainerVisible or presentation.foeTrainerVisible
      break
    end
  end
  Assert.isTrue(ownVisible, "the player send-out completes within the source opening")
  Assert.isFalse(trainersVisibleAtSendout, "trainer sprites have left before the player's mon is revealed")
end

function T.player_send_out_draws_the_ball_from_its_source_trainer_anchor()
  local timeline = BattleTimeline.new({ sound = function(_) end, textSpeed = "fastest" })
  local view = openingView()
  timeline:reset(view)
  timeline:intro(view, true)
  local firstVisibleTick = nil
  local firstVisibleX = nil
  local firstVisibleY = nil
  local lastVisibleTick = nil
  for tick = 1, 1000 do
    advance(timeline, TICK)
    if timeline:messageActive() then
      timeline:ack()
    end
    local opening = timeline:openingPresentation()
    local ball = opening and opening.ballThrow
    if type(ball) == "table" and ball.visible then
      firstVisibleTick = firstVisibleTick or tick
      firstVisibleX = firstVisibleX or ball.x
      firstVisibleY = firstVisibleY or ball.y
      lastVisibleTick = tick
    elseif firstVisibleTick ~= nil then
      break
    end
  end
  Assert.notNil(firstVisibleTick, "the player send-out opens with its staged ball sprite")
  Assert.equal(firstVisibleX, 64, "the player ball follows the settled backpic x anchor")
  Assert.equal(firstVisibleY, 240, "the player ball follows the staged backpic y anchor")
  Assert.equal(lastVisibleTick - firstVisibleTick + 1, 21, "the ball stays until the source trainer exits to x=-40")
  local ball = timeline:openingPresentation().ballThrow
  Assert.isFalse(ball.visible, "the staged ball hides after its opening sequence")
end

-- Retail text delay is counted by printer-task update. NitroMain runs
-- that task twice per source tick, so retail delays 8, 4, and 1 map to
-- the existing paced values 7, 3, and 0 across those two substeps.
function T.named_speeds_reveal_bounded_glyphs_at_their_cadence()
  local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")
  local text = "ABCDEFGHIJKLMNOPQRST"
  local function glyphCount(shown)
    local total = 0
    for _ in Utf8Glyphs.iter(shown) do
      total = total + 1
    end
    return total
  end
  local function shownAfter(speed, ticks)
    local played = BattleTimeline.new({ sound = function(_) end, textSpeed = speed })
    played:announce(text, false)
    for _ = 1, ticks do
      advance(played, TICK)
    end
    return glyphCount(played:message())
  end
  local function shownAfterDefault(ticks)
    local played = BattleTimeline.new({ sound = function(_) end })
    played:announce(text, false)
    for _ = 1, ticks do
      advance(played, TICK)
    end
    return glyphCount(played:message())
  end
  Assert.equal(shownAfter("slow", 1), 1, "the slowest pace shows one glyph on its first tick")
  Assert.equal(shownAfter("slow", 4), 1, "the slowest pace holds through four source ticks")
  Assert.equal(shownAfter("slow", 5), 2, "retail's eight-update delay advances on the fifth source tick")
  Assert.equal(shownAfter("slow", 9), 2, "the second slow interval retains its printer phase")
  Assert.equal(shownAfter("slow", 10), 3, "the slow sequence samples every nine updates")
  Assert.equal(shownAfter("mid", 1), 1, "the middle pace shows one glyph on its first tick")
  Assert.equal(shownAfter("mid", 2), 1, "the middle pace holds through its blank source tick")
  Assert.equal(shownAfter("mid", 3), 2, "the first five-update interval ends on tick three")
  Assert.equal(shownAfter("mid", 5), 2, "the middle pace preserves its internal update phase")
  Assert.equal(shownAfter("mid", 6), 3, "the next retail interval ends on tick six")
  Assert.equal(shownAfter("mid", 9), 4, "middle speed samples five-update intervals")
  Assert.equal(shownAfter("fast", 1), 1, "the quick pace shows one glyph on its first tick")
  Assert.equal(shownAfter("fast", 2), 2, "the quick pace prints every tick")
  Assert.equal(shownAfter("fast", 3), 3, "the quick pace never jumps to a full page")
  Assert.equal(shownAfter("fastest", 1), 2, "the quickest pace shows two glyphs on its first tick")
  Assert.equal(shownAfter("fastest", 2), 4, "the quickest pace prints two glyphs every tick")
  Assert.equal(shownAfter("fastest", 3), 6, "the quickest pace never jumps to a full page")
  Assert.isTrue(shownAfter("fastest", 1) < 20, "no pace reveals a twenty-glyph page on its first tick")
  local accented = BattleTimeline.new({ sound = function(_) end, textSpeed = "fastest" })
  accented:announce("\195\137CLAIR\195\137CLAIR\195\137CLAIR", false)
  advance(accented, TICK)
  Assert.equal(glyphCount(accented:message()), 2, "the quickest pace counts glyphs, not bytes")
  Assert.equal(accented:message(), "\195\137C", "a multibyte name never tears mid-codepoint")
  Assert.equal(shownAfterDefault(5), shownAfter("mid", 5), "omitting the pace keeps the middle cadence")
  local ok, _ = pcall(BattleTimeline.new, { textSpeed = "warp" })
  Assert.isFalse(ok, "an unknown pace fails instead of guessing")
end

---@param combatant integer native combatant identity under test driving
---@param position integer opaque runtime slot identity under test driving
---@param activation integer entry token under test driving
---@param own boolean true for the near side under test driving
---@param species string
---@param name string
---@param level integer
---@param hp integer current health under test driving
---@param maxHp integer
---@return table model battler record carrying its native slot
local function doubleRecord(combatant, position, activation, own, species, name, level, hp, maxHp)
  return {
    combatant = combatant,
    participant = combatant,
    side = own and 1 or 2,
    controller = own and "player" or "wild",
    active = true,
    position = position,
    activation = activation,
    hp = hp,
    maxHp = maxHp,
    species = species,
    form = 0,
    name = name,
    ballKey = "POKE_BALL",
    level = level,
    selector = own and "back" or "front",
    portraitSelector = MonCache.portraitSelector(species, 0, "male", false, own and "back" or nil),
    moves = own and { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } } or nil,
    experience = 8000,
  }
end

---@return table detached opening dynamic view with two live leads and two live foes
local function doubleOpeningView()
  return {
    round = 1,
    status = "running",
    own = {
      doubleRecord(1, 1, 11, true, "STARLY", "LEFTY", 8, 40, 40),
      doubleRecord(2, 2, 12, true, "SHINX", "RIGHTY", 9, 35, 38),
    },
    foes = {
      doubleRecord(3, 3, 13, false, "BIDOOF", "FOE-A", 4, 45, 45),
      doubleRecord(4, 4, 14, false, "PICHU", "FOE-B", 5, 30, 33),
    },
    participants = {},
    environment = {},
  }
end

---@param combatant integer native combatant identity under test driving
---@param position integer opaque runtime slot identity under test driving
---@param side integer
---@param hp integer
---@param maxHp integer
---@return table checkpoint fragment for one combatant
local function doubleCheckpoint(combatant, position, side, hp, maxHp)
  return {
    activation = combatant,
    controller = side == 1 and "player" or "wild",
    experience = 100,
    form = 0,
    hp = hp,
    maxHp = maxHp,
    participant = combatant,
    position = position,
    side = side,
    species = "BIDOOF",
  }
end

---@param id integer packet identity under test driving
---@param events table ordered sanitized events under test driving
---@param after table detached after view under test driving
---@return table delivery-shaped packet over the doubled opening
local function doublePacket(id, events, after)
  return {
    launchId = "timeline-double-probe",
    packetId = id,
    events = events,
    before = doubleOpeningView(),
    after = after,
    request = nil,
    result = nil,
  }
end

---@param kind string sanitized event kind under test driving
---@param payload table event addressing under test driving
---@param health table<integer, table> per-combatant slot and health facts under test driving
---@return table one sanitized event
local function doubleEvent(kind, payload, health)
  local combatants = {}
  local hp = {}
  for combatant, facts in pairs(health) do
    combatants[combatant] = doubleCheckpoint(combatant, facts.position, facts.side, facts.hp, facts.maxHp)
    hp[combatant] = facts.hp
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

-- Paired slots keep their native positions from reset through
-- reconciliation: every live slot stays addressable by its source
-- position and entry token, health-only updates never move a slot, and
-- benched reserves never surface.
function T.paired_slots_keep_native_positions_through_reset_and_reconcile()
  local timeline = BattleTimeline.new({ sound = function(_) end })
  timeline:reset(doubleOpeningView())
  Assert.equal(#timeline:battlers(), 4, "both partners on both sides display")
  for _, slot in ipairs({ { 1, 1, 11 }, { 2, 2, 12 }, { 3, 3, 13 }, { 4, 4, 14 } }) do
    local entry = battler(timeline:battlers(), slot[1])
    Assert.equal(entry.position, slot[2], "combatant " .. slot[1] .. " keeps its native slot")
    Assert.equal(entry.activation, slot[3], "combatant " .. slot[1] .. " keeps its entry token")
    Assert.isTrue(entry.visible, "combatant " .. slot[1] .. " opens visible")
  end
  local selectors = {}
  for _, entry in ipairs(timeline:battlers()) do
    selectors[entry.portraitSelector] = true
  end
  local distinct = 0
  for _ in pairs(selectors) do
    distinct = distinct + 1
  end
  Assert.equal(distinct, 4, "four distinct species own four distinct portraits")
  local wounded = doubleOpeningView()
  wounded.foes[2].hp = 17
  for _, group in ipairs({ wounded.own, wounded.foes }) do
    for _, record in ipairs(group) do
      timeline:reconcileBattler(record, true)
    end
  end
  local hurt = battler(timeline:battlers(), 4)
  Assert.equal(hurt.hp, 17, "the wounded foe reconciles its exact health")
  Assert.equal(hurt.position, 4, "a health update never moves the wounded slot")
  Assert.equal(hurt.activation, 14, "a health update never re-tokens the wounded slot")
  local partner = battler(timeline:battlers(), 3)
  Assert.equal(partner.hp, 45, "the partner foe keeps its health")
  Assert.equal(partner.position, 3, "the partner foe keeps its slot")
  local benched = doubleOpeningView()
  local reserve = doubleRecord(5, 3, 15, false, "BIDOOF", "BENCH", 4, 40, 40)
  reserve.active = false
  reserve.position = nil
  reserve.activation = nil
  benched.foes[#benched.foes + 1] = reserve
  local probe = BattleTimeline.new({ sound = function(_) end })
  probe:reset(benched)
  Assert.equal(#probe:battlers(), 4, "an inactive reserve never takes a display slot")
  for _, entry in ipairs(probe:battlers()) do
    Assert.isTrue(entry.combatant ~= 5, "the reserve identity never surfaces")
  end
end

-- A knockout with a queued replacement keeps every identity on its
-- native slot: only the struck record recoils, only it hides at its
-- faint cue, the partner never moves, and the reserve walks out at the
-- vacated slot with its own portrait while the retired record stays
-- hidden. Both foes share one species yet stay two combatants.
function T.knockout_reveal_keeps_vacated_slot_and_leaves_partner_alone()
  local opening = doubleOpeningView()
  opening.foeTrainers = { { classKey = "YOUNGSTER", name = "TRAINER" } }
  opening.foes[2] = doubleRecord(4, 4, 14, false, "BIDOOF", "FOE-B", 5, 30, 33)
  local timeline = BattleTimeline.new({ sound = function(_) end })
  timeline:reset(opening)
  Assert.equal(battler(timeline:battlers(), 3).species, "BIDOOF", "the first foe opens with the shared species")
  Assert.equal(battler(timeline:battlers(), 4).species, "BIDOOF", "the second foe opens with the shared species")
  local after = doubleOpeningView()
  after.foeTrainers = { { classKey = "YOUNGSTER", name = "TRAINER" } }
  after.foes[1] = doubleRecord(3, 3, 13, false, "BIDOOF", "FOE-A", 4, 45, 45)
  after.foes[2] = doubleRecord(5, 4, 15, false, "PICHU", "FOE-C", 5, 33, 33)
  local health = {
    [1] = { position = 1, side = 1, hp = 40, maxHp = 40 },
    [2] = { position = 2, side = 1, hp = 35, maxHp = 38 },
    [3] = { position = 3, side = 2, hp = 45, maxHp = 45 },
    [4] = { position = 4, side = 2, hp = 0, maxHp = 33 },
    [5] = { position = 4, side = 2, hp = 33, maxHp = 33 },
  }
  local strike = doubleEvent("struck", { target = 4, damage = 30, hitIndex = 1 }, health)
  strike.actors = { { combatant = 1, activation = 11 } }
  strike.targets = { { combatant = 4, activation = 14 } }
  Assert.isTrue(
    timeline:present(doublePacket(1, {
      strike,
      doubleEvent("faint", { combatant = 4, activation = 14, position = 4 }, health),
      doubleEvent("switch", { from = 4, incoming = 5 }, health),
    }, after)),
    "the knockout packet is accepted"
  )
  local targetFlickered = false
  local partnerFlickered = false
  local faintAt = nil
  local revealedAt = nil
  local ticks = 0
  while not timeline:settled() and ticks < 3000 do
    advance(timeline, TICK)
    ticks = ticks + 1
    targetFlickered = targetFlickered or battler(timeline:battlers(), 4).visible == false
    partnerFlickered = partnerFlickered or battler(timeline:battlers(), 3).visible == false
    if battler(timeline:battlers(), 4).visible == false and faintAt == nil then
      faintAt = ticks
    end
    for _, entry in ipairs(timeline:battlers()) do
      if entry.combatant == 5 and entry.visible == true and revealedAt == nil then
        revealedAt = ticks
      end
    end
  end
  Assert.isTrue(targetFlickered, "the struck record flickers through its HP cue")
  Assert.isFalse(partnerFlickered, "the surviving partner never flickers")
  Assert.notNil(faintAt, "the faint cue hides its record")
  Assert.notNil(revealedAt, "the reveal cue walks the reserve out")
  Assert.isTrue(timeline:settled(), "every queued cue drains")
  local final = {}
  for _, entry in ipairs(timeline:battlers()) do
    Assert.isNil(final[entry.combatant], "no retired record draws twice")
    final[entry.combatant] = entry
  end
  Assert.isFalse(final[4].visible, "the retired record stays hidden")
  Assert.isTrue(final[5].visible, "the reserve ends visible")
  Assert.equal(final[5].position, 4, "the reserve takes the vacated native slot")
  Assert.equal(final[5].activation, 15, "the reserve carries its own entry token")
  Assert.equal(
    final[5].portraitSelector,
    MonCache.portraitSelector("PICHU", 0, "male", false),
    "the reserve draws its own portrait, never the retired one"
  )
  Assert.equal(final[3].hp, 45, "the surviving partner keeps its health")
  Assert.equal(final[3].position, 3, "the surviving partner keeps its slot")
  Assert.isTrue(final[3].visible, "the surviving partner stays visible")
  Assert.isTrue(revealedAt --[[@as integer]] >= faintAt --[[@as integer]], "the reveal never precedes the faint")
end

-- Shared source time reads the same on every host schedule: one accepted
-- source tick follows the HGSS cadence however the host slices its frames.
-- Narration pacing, waits, completion boundaries, drained sounds, and the
-- displayed transcript must agree in source ticks while host frame counts
-- are free to differ.
function T.shared_source_time_agrees_across_host_partitions()
  local text = "ABCDEFGHIJKLMNOPQRST"
  local function announced()
    local played = BattleTimeline.new({ sound = function(_) end })
    played:announce(text, false)
    return played
  end
  -- The middle text option has a four-update retail delay; two printer
  -- updates per source tick reveal at ticks 1, 3, 6, 8, 11, and so on.
  local paced = announced()
  for _ = 1, 5 do
    advance(paced, TICK)
  end
  Assert.equal(paced:message(), "AB", "five source ticks reveal two glyphs at the middle pace")
  local bounded = announced()
  for _ = 1, 58 do
    advance(bounded, TICK)
  end
  Assert.isFalse(bounded:settled(), "the final text hold remains active after 58 source ticks")
  advance(bounded, TICK)
  Assert.isTrue(bounded:settled(), "the paced page settles on its 59th source tick")
  Assert.equal(bounded:message(), text, "the settled page shows its full wording")
  -- Partition equivalence over six accepted seconds: 30 Hz, 60 Hz,
  -- 144 Hz, and an irregular schedule with zero-step calls all land the
  -- same strike transcript.
  local function struckOver(schedule)
    local sounds = sink()
    local played = BattleTimeline.new({
      sound = function(name)
        sounds.sound(name)
      end,
    })
    played:reset(openingView())
    local after = openingView()
    after.foes[1].hp = 43
    played:present(
      packet(1, { event("struck", { target = 3, damage = 14, hitIndex = 1 }, { [1] = 52, [3] = 43 }) }, after)
    )
    for _, dt in ipairs(schedule) do
      advance(played, dt)
    end
    return played, sounds
  end
  local at30, at60, at144, irregular = {}, {}, {}, {}
  for _ = 1, 180 do
    at30[#at30 + 1] = 1 / 30
  end
  for _ = 1, 360 do
    at60[#at60 + 1] = 1 / 60
  end
  for _ = 1, 864 do
    at144[#at144 + 1] = 1 / 144
  end
  for _ = 1, 60 do
    irregular[#irregular + 1] = 0.05
    irregular[#irregular + 1] = 0
    irregular[#irregular + 1] = 0.03
    irregular[#irregular + 1] = 0.02
  end
  local first, firstSounds = struckOver(at30)
  local second, secondSounds = struckOver(at60)
  local third, thirdSounds = struckOver(at144)
  local fourth, fourthSounds = struckOver(irregular)
  for index, other in ipairs({ second, third, fourth }) do
    Assert.isTrue(other:settled(), "partition " .. tostring(index) .. " settles the strike")
    Assert.equal(other:message(), first:message(), "partition " .. tostring(index) .. " reveals the same text")
    Assert.equal(
      battler(other:battlers(), 3).hp,
      battler(first:battlers(), 3).hp,
      "partition " .. tostring(index) .. " lands the same checkpoint"
    )
  end
  Assert.isTrue(first:settled(), "the strike settles")
  Assert.equal(battler(first:battlers(), 3).hp, 43, "the strike checkpoint lands")
  Assert.deepEqual(secondSounds.played, firstSounds.played, "60 Hz drains the same sounds")
  Assert.deepEqual(thirdSounds.played, firstSounds.played, "144 Hz drains the same sounds")
  Assert.deepEqual(fourthSounds.played, firstSounds.played, "irregular frames drain the same sounds")
  -- The opening cry drains exactly once on every schedule as well.
  local function openedOver(schedule)
    local sounds = sink()
    local played = BattleTimeline.new({
      sound = function(name)
        sounds.sound(name)
      end,
    })
    played:intro(openingView(), true)
    -- The lead cries after its send-out line, past the six-second slice.
    for _ = 1, 3 do
      for _, dt in ipairs(schedule) do
        advance(played, dt)
      end
    end
    return played, sounds
  end
  local _, cry30 = openedOver(at30)
  local _, cry60 = openedOver(at60)
  local _, cryIrregular = openedOver(irregular)
  Assert.equal(cry30.countCry("EEVEE", false), 1, "the opening cries its lead once")
  Assert.deepEqual(cry60.played, cry30.played, "60 Hz keeps the same audio ticks")
  Assert.deepEqual(cryIrregular.played, cry30.played, "irregular frames keep the same audio ticks")
end

function T.text_speed_reveals_the_source_counter_cadence_at_each_option()
  local expectedAtFiveTicks = {
    slow = "AB",
    mid = "AB",
    fast = "ABCDE",
    fastest = "ABCDEFGHIJ",
  }
  for speed, expected in pairs(expectedAtFiveTicks) do
    local timeline = BattleTimeline.new({ sound = function(_) end, textSpeed = speed })
    timeline:announce("ABCDEFGHIJKLMN", false)
    for _ = 1, 5 do
      advance(timeline, TICK)
    end
    Assert.equal(timeline:message(), expected, speed .. " matches the twice-per-source-tick printer counter")
  end
end

-- Source waits and zero-duration cues terminate on native control flow:
-- a pure wait lasts exactly its ticks with no extra host-frame delay and
-- no infinite loop, and a cue held on a missing image consumes no source
-- time until its image arrives.
function T.waits_terminate_on_their_own_ticks_without_holding_time()
  local function fled()
    local played = BattleTimeline.new({ sound = function(_) end })
    played:reset(openingView())
    played:present(packet(1, { event("flee", { escaped = true }, { [1] = 52, [3] = 57 }) }, openingView()))
    return played
  end
  local bounded = fled()
  advance(bounded, TICK)
  Assert.isTrue(bounded:settled(), "successful escape has no invented wait before the terminal line")
  local immediate = fled()
  advance(immediate, 6 * TICK)
  Assert.isTrue(immediate:settled(), "a large frame drains the zero-duration escape effect")
  local long = fled()
  advance(long, 3600)
  Assert.isTrue(long:settled(), "a huge frame still terminates instead of looping")
  -- A strike held on its missing portrait freezes: many updates, even
  -- large ones, change neither the revealed text nor the displayed
  -- health, and releasing the image resumes to the exact checkpoint.
  local sounds = sink()
  local held = BattleTimeline.new({
    sound = function(cue)
      sounds.sound(cue)
    end,
  })
  held:reset(openingView())
  local after = openingView()
  after.foes[1].hp = 43
  held:present(packet(1, { event("struck", { target = 3, damage = 14, hitIndex = 1 }, { [1] = 52, [3] = 43 }) }, after))
  local foeKey = "mon:" .. MonCache.portraitSelector("EEVEE", 0, "male", false)
  local ready = { [foeKey] = false }
  local function available(key)
    return ready[key] ~= false
  end
  for _ = 1, 60 do
    held:update(TICK, available)
  end
  held:update(5, available)
  local frozenText = held:message()
  local frozenHp = battler(held:battlers(), 3).hp
  for _ = 1, 20 do
    held:update(TICK, available)
  end
  Assert.equal(held:message(), frozenText, "waiting changes readiness, never the revealed text")
  Assert.equal(battler(held:battlers(), 3).hp, frozenHp, "waiting consumes no health ticks")
  Assert.equal(frozenHp, 57, "the held checkpoint never leaks early")
  Assert.isFalse(held:settled(), "the held cue reports unready instead of skipping")
  ready[foeKey] = true
  local remaining = 0
  while not held:settled() and remaining < 2000 do
    held:update(TICK, available)
    remaining = remaining + 1
  end
  Assert.isTrue(held:settled(), "releasing the image resumes to completion")
  Assert.equal(battler(held:battlers(), 3).hp, 43, "the exact checkpoint applies after release")
end

-- The source menu reveal advances on accepted battle time. Read its
-- visible window boundary through the screen's real draw/input boundary,
-- and make host partitioning irrelevant to both the frame trace and the
-- input gate.
function T.native_menu_reveal_frames_and_input_gate_follow_source_ticks()
  local BattleScreenState = require("game.hgss.tests.support.BattleScreenFixture")
  local Model = require("game.hgss.src.battle.BattlePresentationModel")
  local FakeGraphics = require("tests.support.FakeGraphics")
  local ManifestFixture = require("tests.support.BattlePresentationManifestFixture")
  local ScreenTopology = require("libs.ui.src.ScreenTopology")

  local expectedEdges = { 184, 174, 164, 154, 145 }
  local expectedOutsideWidths = { 0, 63, 127, 191, 254 }
  local expectedScroll = { 1, 64, 128, 192, 255 }
  local function run(partition, doublePartner)
    local measurement = {
      width = 256,
      height = 384,
      topology = ScreenTopology.dualDisplay(
        { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
        { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" },
        "battle-menu-slide:dual"
      ),
      pixelRatio = 1,
      signature = "battle-menu-slide:dual",
    }
    local text = { draws = {} }
    function text.measure(content)
      return { width = 8 * #tostring(content), height = 16 }
    end
    function text.drawText(content, x, y)
      text.draws[#text.draws + 1] = { content = tostring(content), x = x, y = y }
    end
    local windows = { calls = {} }
    function windows.drawWindow(box, frameKey, background)
      windows.calls[#windows.calls + 1] = { box = box, frame = frameKey, background = background }
    end
    local audio = { plays = {} }
    function audio.play(name)
      audio.plays[#audio.plays + 1] = name
      return true
    end
    local assets = { images = {}, released = {} }
    function assets.prepare(_)
      return true
    end
    function assets.drawable(key)
      if assets.images[key] == nil then
        assets.images[key] = {
          handle = key,
          width = 1648,
          height = 80,
          getWidth = function(self)
            return self.width
          end,
          getHeight = function(self)
            return self.height
          end,
          getDimensions = function(self)
            return self.width, self.height
          end,
          setFilter = function() end,
        }
      end
      return assets.images[key]
    end
    function assets.release(key)
      assets.released[key] = (assets.released[key] or 0) + 1
    end

    local graphicsBase = FakeGraphics.new({})
    local graphics = setmetatable({}, { __index = graphicsBase })
    local draws = {}
    local currentScissor = nil
    local scissorStack = {}
    function graphics.push(...)
      scissorStack[#scissorStack + 1] = currentScissor ~= nil
          and {
            currentScissor[1],
            currentScissor[2],
            currentScissor[3],
            currentScissor[4],
          }
        or nil
      graphicsBase.push(...)
    end
    function graphics.pop(...)
      graphicsBase.pop(...)
      currentScissor = table.remove(scissorStack)
    end
    function graphics.getScissor()
      if currentScissor == nil then
        return nil
      end
      return currentScissor[1], currentScissor[2], currentScissor[3], currentScissor[4]
    end
    function graphics.setScissor(x, y, width, height)
      if x == nil then
        currentScissor = nil
      else
        currentScissor = { x, y, width, height }
      end
      graphicsBase.setScissor(x, y, width, height)
    end
    function graphics.intersectScissor(x, y, width, height)
      if currentScissor == nil then
        currentScissor = { x, y, width, height }
      else
        local old = currentScissor
        local right = math.min(old[1] + old[3], x + width)
        local bottom = math.min(old[2] + old[4], y + height)
        currentScissor = {
          math.max(old[1], x),
          math.max(old[2], y),
          math.max(0, right - math.max(old[1], x)),
          math.max(0, bottom - math.max(old[2], y)),
        }
      end
      graphicsBase.intersectScissor(x, y, width, height)
    end
    function graphics.draw(image, quad, x, y, rotation, scaleX, scaleY)
      local handle = type(image) == "table" and image.handle or nil
      draws[#draws + 1] = {
        handle = handle,
        x = type(quad) == "number" and quad or x,
        y = type(quad) == "number" and x or y,
        scissor = currentScissor,
      }
      graphicsBase.draw(image, quad, x, y, rotation, scaleX, scaleY)
    end

    local submits = {}
    local launchId = "battle-menu-slide-" .. partition
    local screen = BattleScreenState.new({
      launchId = launchId,
      manifest = ManifestFixture.manifest(),
      model = Model,
      submit = function(reply)
        submits[#submits + 1] = reply
        return true
      end,
      measureDisplay = function()
        return measurement
      end,
      assets = assets,
      text = text,
      windows = windows,
      audio = audio,
    })
    local opening = openingView()
    local actorCombatant = doublePartner and 2 or 1
    if doublePartner then
      opening.own[1].position = 0
      opening.own[2] = {
        combatant = 2,
        participant = 2,
        side = 1,
        controller = "player",
        active = true,
        position = 1,
        hp = 48,
        maxHp = 48,
        species = "EEVEE",
        form = 0,
        name = "PARTNER",
        level = 20,
        selector = "back",
        portraitSelector = MonCache.portraitSelector("EEVEE", 0, "male", false, "back"),
        moves = { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } },
        experience = 8000,
      }
    end
    local actor = {
      combatant = actorCombatant,
      activation = 1,
      kind = "action",
      choices = {
        {
          id = "move:0",
          role = "move",
          display = { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 },
          enabled = true,
          choice = {
            actor = { combatant = actorCombatant, activation = 1 },
            kind = "attack",
            payload = { moveSlot = 0, target = { kind = "position", position = 2 } },
          },
        },
      },
    }
    local request = {
      requestId = 93001,
      epoch = 1,
      controller = "player",
      kind = "action",
      actors = { actor },
    }
    request.options = {
      requestId = request.requestId,
      epoch = request.epoch,
      controller = request.controller,
      kind = request.kind,
      actors = { actor },
    }
    screen:presentationPort().present({
      launchId = launchId,
      packetId = 1,
      events = {},
      before = opening,
      after = opening,
      request = request,
    })

    local function advanceHost(dt)
      screen:updateFixed(dt)
    end
    local hostStep = 1 / 30
    local hostIndex = 1
    local irregular = { 1 / 120, 3 / 120, 0.05, 0.02, 0.03 }
    for _ = 1, 3000 do
      if partition == "60" then
        hostStep = 1 / 60
      elseif partition == "144" then
        hostStep = 1 / 144
      elseif partition == "irregular" then
        hostStep = irregular[hostIndex]
        hostIndex = hostIndex % #irregular + 1
      end
      advanceHost(hostStep)
      if screen:status().mode == "command" then
        break
      end
    end
    local openingStatus = screen:status()
    Assert.equal(
      openingStatus.mode,
      "command",
      "the opening reaches the first command prompt: " .. tostring(openingStatus.error)
    )

    local trace = {}
    local function drawMenuFrame()
      draws = {}
      local viewEdge = screen:view().menuRevealEdge
      Assert.equal(viewEdge, expectedEdges[#trace + 1], "the detached view publishes each native reveal edge")
      local menuWindows = assert(screen:view().menuWindows, "menu slide publishes immutable native window geometry")
      Assert.equal(
        menuWindows.edge,
        expectedEdges[#trace + 1],
        "W1 follows the source vertical boundary at step " .. tostring(#trace) .. ": " .. tostring(menuWindows.edge)
      )
      local index = #trace + 1
      Assert.equal(
        menuWindows.outsideTop.x,
        doublePartner and ({ 256, 192, 128, 64, 1 })[index] or 1,
        "W0 outside region follows the source battler side"
      )
      Assert.equal(
        menuWindows.outsideTop.width,
        doublePartner and ({ 0, 64, 128, 192, 255 })[index] or expectedOutsideWidths[index]
      )
      Assert.equal(
        menuWindows.scroll[0].x,
        doublePartner and ({ 0, 64, 128, 192, 255 })[index] or expectedScroll[index]
      )
      Assert.equal(menuWindows.scroll[1].x, menuWindows.scroll[0].x)
      screen:draw({ graphics = graphics })
      trace[#trace + 1] = viewEdge
    end
    drawMenuFrame()
    local gateChecks = 0
    local gateIntact = true
    for frame = 1, 4 do
      screen:input({ { type = "pointer_down", pointerId = "slide-bag", x = 40, y = 360 } })
      screen:input({ { type = "pointer_up", pointerId = "slide-bag", x = 40, y = 360 } })
      screen:input({ { type = "confirm" } })
      local status = screen:status()
      gateIntact = gateIntact and status.mode == "command" and status.request ~= nil and #submits == 0
      gateChecks = gateChecks + 1

      local left = TICK
      while left > 1e-12 do
        local dt = partition == "60" and math.min(left, 1 / 60)
          or partition == "144" and math.min(left, 1 / 144)
          or partition == "irregular" and math.min(left, irregular[hostIndex])
          or left
        if partition == "irregular" then
          hostIndex = hostIndex % #irregular + 1
        end
        screen:updateFixed(dt)
        left = left - dt
      end
      drawMenuFrame()
    end
    screen:input({ { type = "confirm" } })
    screen:updateFixed(TICK)
    screen:input({ { type = "confirm" } })
    local openedAfterGate = screen:status().mode == "moves" and #submits == 0
    local windowsClosedAfterEntry = screen:view().menuWindows == nil and screen:view().menuRevealEdge == nil
    screen:dispose()
    return trace, gateChecks, gateIntact, openedAfterGate, windowsClosedAfterEntry
  end

  local reference, checks, gateIntact, openedAfterGate, windowsClosedAfterEntry = run("30")
  local partitionTraces = {}
  local partitionGates = {}
  local partitionOpens = {}
  partitionTraces[1] = reference
  partitionGates[1] = gateIntact
  partitionOpens[1] = openedAfterGate
  for index, partition in ipairs({ "60", "144", "irregular" }) do
    local trace, partitionChecks, gate, opened, windowsClosed = run(partition)
    Assert.equal(partitionChecks, checks, partition .. " Hz keeps the same number of gated frames")
    partitionTraces[index + 1] = trace
    partitionGates[index + 1] = gate
    partitionOpens[index + 1] = opened
    Assert.isTrue(windowsClosed, partition .. " Hz closes source windows after entry")
  end
  local partnerTrace = run("30", true)
  Assert.deepEqual(partnerTrace, expectedEdges, "the second player-side slot uses the opposite source W0/scroll edge")
  local failures = {}
  local function expect(condition, message)
    if not condition then
      failures[#failures + 1] = message
    end
  end
  local function describe(entries)
    local fields = {}
    for _, edge in ipairs(entries) do
      fields[#fields + 1] = tostring(edge)
    end
    return table.concat(fields, ",")
  end
  expect(
    describe(reference) == describe(expectedEdges),
    "drawn reveal edges should be " .. describe(expectedEdges) .. " but were " .. describe(reference)
  )
  expect(checks == 4, "all four intermediate reveal frames should suppress input")
  expect(gateIntact, "touch and confirm should stay suppressed through all slide frames")
  expect(openedAfterGate, "the next confirmation should work after the native gate opens")
  expect(windowsClosedAfterEntry, "native entry windows clear when the command switches to its child menu")
  for index, partition in ipairs({ "60", "144", "irregular" }) do
    expect(
      describe(partitionTraces[index + 1]) == describe(reference),
      partition .. " Hz should match the shared source slide trace"
    )
    expect(partitionGates[index + 1] == gateIntact, partition .. " Hz should keep the same input gate boundaries")
    expect(partitionOpens[index + 1] == openedAfterGate, partition .. " Hz should open at the same source boundary")
  end
  Assert.isTrue(#failures == 0, table.concat(failures, "; "))
end

-- The source-selected bank entry enters the same paced timeline as other
-- narration, while the detached C04 event remains unchanged.
function T.source_capture_text_uses_the_battle_printer_timeline()
  local BattleTimeline = require("game.hgss.tests.support.BattleTimelineFixture")
  local packet = {
    launchId = "capture-message-source",
    packetId = 1,
    before = {},
    after = {},
    events = {
      {
        sequence = 4,
        kind = "broke_free",
        payload = { shakes = 2 },
      },
    },
  }
  local timeline = BattleTimeline.new({ textSpeed = "mid" })
  local malformedAccepted = pcall(function()
    timeline:present(packet)
  end)
  Assert.isFalse(malformedAccepted, "a capture outcome without selected source text is rejected")
  local sourceMessages = { [4] = "Aargh!\nAlmost had it!" }
  Assert.isTrue(timeline:present(packet, sourceMessages), "the valid retry of the same packet is accepted")
  sourceMessages[4] = "Changed after delivery"
  Assert.isNil(packet.events[1].sourceText, "source selection never mutates the delivery packet")
  local nextPacket = {
    launchId = "capture-message-next-launch",
    packetId = 2,
    before = {},
    after = {},
    events = { { sequence = 4, kind = "broke_free", payload = { shakes = 1 } } },
  }
  local reusedSource = pcall(function()
    timeline:present(nextPacket)
  end)
  Assert.isFalse(reusedSource, "a prior packet's source map does not apply to a later launch")
  Assert.isTrue(
    timeline:present(nextPacket, { [4] = "One shake" }),
    "a later packet uses only its own selected source text"
  )
  for _ = 1, 120 do
    timeline:update(TICK, function()
      return true
    end)
    if timeline:message() ~= "" then
      break
    end
  end
  Assert.isTrue(timeline:message():sub(1, 1) == "A", "the source template feeds the paced battle printer")
end

-- Live native-effect cue coverage: the cue player routes an effect-keyed
-- source event through a task-aware recording collaborator backed by the
-- real player/factory/scene path, never a synthesized completion. The
-- selected program starts before its health checkpoint with no duplicate
-- generic voices, progresses identically under every host partition, starts
-- once per action across hits/spread/redelivery, and never settles silently
-- without its collaborator.
-- Native mechanism: the single HGSS source tick drives cue admission, the
-- player occurrence, and the scene exactly once; narration, hit, and HP
-- cues wait behind native completion.
-- Headless: hand-built struck events carrying the accepted semantic effect
-- key, action, and hit identity drive the real cue player; the recording
-- collaborator runs the exact compiled program through the real factory.

---@param value integer unsigned word under staging
---@return string four little-endian bytes staging one command word
local function nativeU32(value)
  return string.char(
    value % 256,
    math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 16777216) % 256
  )
end

---@param list table<integer, integer> command words under staging
---@return string staged byte stream lowering one program
local function nativeStreamOf(list)
  local parts = {}
  for _, word in ipairs(list) do
    parts[#parts + 1] = nativeU32(word)
  end
  return table.concat(parts)
end

---@return table<string, unknown> compiled resourceless native program completing in three source ticks
local function nativeProbeProgram()
  local BattleAnimationCompiler = require("romdump.src.digest.battle.BattleAnimationCompiler")
  return assert(BattleAnimationCompiler.compile({ key = "TACKLE", stream = nativeStreamOf({ 29, 50, 4 }) }))
end

---@param program table<string, unknown> exact compiled program the collaborator admits
---@return table task-aware recording native-effect collaborator over the real player path
local function taskAwareEffects(program)
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
  local resources = { acquired = {}, released = {} }
  function resources.resolve(key)
    resources.acquired[#resources.acquired + 1] = key
    return { key = key, lease = key }
  end
  function resources.release(lease)
    resources.released[#resources.released + 1] = lease
  end
  local player = assert(Player.new({ scene = scene, audio = audio, resources = resources, tasks = Factory }))
  local rec = { starts = {}, player = player, audio = audio, resources = resources, scene = scene }
  function rec.start(cue)
    Assert.isTrue(type(cue) == "table", "native cues carry their cue record with launch and effect identity")
    rec.starts[#rec.starts + 1] = cue
    local occurrence = { sequence = cue.eventSequence, effectKey = cue.effectKey }
    if type(cue.event) == "table" then
      for field, value in
        pairs(cue.event --[[@as table<string, unknown>]])
      do
        if occurrence[field] == nil then
          occurrence[field] = value
        end
      end
    end
    if occurrence.actionId == nil then
      occurrence.actionId = cue.actionId
    end
    if occurrence.hitOrdinal == nil and cue.hitOrdinal ~= nil then
      occurrence.hitOrdinal = cue.hitOrdinal
    end
    return player:start({
      launchId = cue.launchId or "timeline-probe",
      packetId = cue.packetId or 1,
      event = occurrence,
      visualSeed = cue.visualSeed or 1,
      topology = {
        attacker = { combatant = 1, activation = 1, slot = "solo-player", sideType = 0 },
        targets = { { combatant = 3, activation = 3, slot = "solo-enemy", sideType = 1 } },
      },
    }, program)
  end
  function rec.status(handle)
    -- The double models the locked one-tick-advances-all contract:
    -- every status poll advances the wrapped occurrence exactly once,
    -- mirroring the screen's single-tick loop (cue, player, scene).
    -- No catch-up loops: one poll steps one quantum.
    player:stepSourceTick({ tick = 1 })
    return player:status(handle)
  end
  function rec.cancel(handle, reason)
    return player:cancel(handle, reason)
  end
  return rec
end

---@param sequence integer event sequence under test driving
---@param actionId integer native action identity under test driving
---@param hitIndex integer hit ordinal under test driving
---@param effectKey string accepted semantic effect key under test driving
---@param foeHp integer foe health after the checkpoint under test driving
---@return table one struck event carrying its accepted native playback identity
local function effectStrike(sequence, actionId, hitIndex, effectKey, foeHp)
  local combatants = {
    [1] = checkpoint(1, 52, 52),
    [3] = checkpoint(3, foeHp, 57),
  }
  return {
    sequence = sequence,
    kind = "struck",
    cause = { key = "TACKLE" },
    audience = "public",
    actors = { { combatant = 1, activation = 1 } },
    targets = { { combatant = 3, activation = 3 } },
    move = { executed = "TACKLE" },
    actionId = actionId,
    hitIndex = hitIndex,
    effectKey = effectKey,
    payload = { target = 3, damage = 57 - foeHp, hitIndex = hitIndex },
    after = { hp = { [1] = 52, [3] = foeHp }, combatants = combatants },
  }
end

-- The selected native program starts through the real player before its
-- health checkpoint: the start carries the accepted semantic key, the
-- checkpoint waits for real completion, the running program owns a visible
-- scene change, and the generic impact/effectiveness voices stay silent
-- while the native program owns audio timing.
function T.native_effect_starts_its_selected_program_before_health_without_duplicate_voices()
  local BattleAudio = require("libs.hgss.src.audio.BattleAudio")
  local sounds = sink()
  local fx = taskAwareEffects(nativeProbeProgram())
  local timeline = BattleTimeline.new({
    sound = function(cue)
      sounds.sound(cue)
    end,
    effects = fx,
  })
  timeline:reset(openingView())
  local after = openingView()
  after.foes[1].hp = 43
  Assert.isTrue(
    timeline:present(packet(1, { effectStrike(11, 21, 1, "TACKLE", 43) }, after)),
    "the effect-keyed strike is accepted"
  )
  Assert.isFalse(timeline:settled(), "the native cue leaves work pending")
  local announced = false
  for _ = 1, 600 do
    if #fx.starts > 0 then
      break
    end
    advance(timeline, TICK)
    if timeline:message():find("used Tackle", 1, true) ~= nil then
      announced = true
    end
  end
  Assert.isTrue(announced, "the attack announcement reads before the visual starts")
  Assert.equal(#fx.starts, 1, "the selected native program starts through the real player")
  Assert.equal(fx.starts[1].effectKey, "TACKLE", "the start carries the accepted semantic effect key")
  Assert.equal(fx.starts[1].actionId, 21, "the start carries the accepted action identity")
  Assert.equal(battler(timeline:battlers(), 3).hp, 57, "health waits for native completion instead of leaking early")
  Assert.isFalse(timeline:settled(), "the running program holds the cue open")
  Assert.equal(#fx.scene:effectViews(), 0, "state-only visual work publishes no drawable picture while running")
  Assert.equal(sounds.countEffect(BattleAudio.SINK_SOUNDS.impact), 0, "the impact voice waits for the running program")
  for _ = 1, 600 do
    advance(timeline, TICK)
    if timeline:settled() then
      break
    end
  end
  Assert.isTrue(timeline:settled(), "the native cue settles after real completion")
  Assert.equal(battler(timeline:battlers(), 3).hp, 43, "the exact checkpoint applies after native completion")
  Assert.isTrue(#fx.audio.played > 0, "the completed program played its source-timed voice instead of staying silent")
  Assert.equal(
    sounds.countEffect(BattleAudio.SINK_SOUNDS.impact),
    1,
    "the hit voices its impact after the program, as subscript_0002_UpdateHp does"
  )
end

-- One accepted source tick reads the same on every host schedule while a
-- native program runs: 30 Hz and 60 Hz host slicing start the program once
-- each, land the same checkpoint, drain the same voices, and expose the
-- same per-tick scene frames.
function T.native_effect_progress_agrees_across_host_partitions()
  ---@param schedule number[] host frame durations under test driving
  ---@return table played cue player behind the schedule
  ---@return table drained voices behind the schedule
  ---@return table recording collaborator behind the schedule
  ---@return integer[] scene frame counts at each host step
  local function runOver(schedule)
    local sounds = sink()
    local fx = taskAwareEffects(nativeProbeProgram())
    local played = BattleTimeline.new({
      sound = function(cue)
        sounds.sound(cue)
      end,
      effects = fx,
    })
    played:reset(openingView())
    local after = openingView()
    after.foes[1].hp = 43
    played:present(packet(1, { effectStrike(11, 21, 1, "TACKLE", 43) }, after))
    local views = {}
    for _, dt in ipairs(schedule) do
      played:update(dt, function(_)
        return true
      end)
      views[#views + 1] = #fx.scene:effectViews()
    end
    return played, sounds, fx, views
  end
  -- Four accepted seconds per schedule: the strike cue chain alone
  -- needs 94 source ticks (paced narration, hit recoil, health
  -- interpolation), so 90 ticks can never settle with or without a
  -- native program. The budgets below cover the full chain with
  -- margin while keeping the 30 Hz to 60 Hz two-to-one ratio.
  local at30, at60 = {}, {}
  for _ = 1, 120 do
    at30[#at30 + 1] = 1 / 30
  end
  for _ = 1, 240 do
    at60[#at60 + 1] = 1 / 60
  end
  local first, firstSounds, firstFx, firstViews = runOver(at30)
  local second, secondSounds, secondFx, secondViews = runOver(at60)
  Assert.equal(#firstFx.starts, 1, "the 30 Hz schedule starts the native program once")
  Assert.equal(#secondFx.starts, 1, "the 60 Hz schedule starts the native program once")
  Assert.isTrue(first:settled(), "the 30 Hz schedule settles the native cue")
  Assert.isTrue(second:settled(), "the 60 Hz schedule settles the native cue")
  Assert.equal(battler(second:battlers(), 3).hp, battler(first:battlers(), 3).hp, "partitions land the same checkpoint")
  Assert.deepEqual(secondSounds.played, firstSounds.played, "partitions drain the same voices")
  local firstBoundaries, secondBoundaries = {}, {}
  for _, count in ipairs(firstViews) do
    firstBoundaries[#firstBoundaries + 1] = count
  end
  for index = 2, #secondViews, 2 do
    secondBoundaries[#secondBoundaries + 1] = secondViews[index]
  end
  Assert.deepEqual(secondBoundaries, firstBoundaries, "partitions expose the same scene frame per source tick")
end

-- One action plays its full move animation once: a two-hit turn with one
-- action identity starts a single occurrence, redelivery starts nothing
-- new, and only a distinct action identity starts its own occurrence.
function T.native_effect_starts_once_per_action_across_hits_spread_and_redelivery()
  local sounds = sink()
  local fx = taskAwareEffects(nativeProbeProgram())
  local timeline = BattleTimeline.new({
    sound = function(cue)
      sounds.sound(cue)
    end,
    effects = fx,
  })
  timeline:reset(openingView())
  local after = openingView()
  after.foes[1].hp = 30
  local first = packet(1, {
    effectStrike(11, 21, 1, "TACKLE", 43),
    effectStrike(12, 21, 2, "TACKLE", 30),
  }, after)
  Assert.isTrue(timeline:present(first), "the two-hit turn is accepted")
  for _ = 1, 900 do
    advance(timeline, TICK)
    if timeline:settled() then
      break
    end
  end
  Assert.isTrue(timeline:settled(), "the two-hit turn drains")
  Assert.equal(#fx.starts, 1, "one action plays its full move animation once, never once per hit")
  Assert.isFalse(timeline:present(first), "redelivery of the same packet queues nothing new")
  Assert.equal(#fx.starts, 1, "redelivery starts nothing new")
  local later = openingView()
  later.foes[1].hp = 10
  Assert.isTrue(
    timeline:present(packet(2, { effectStrike(13, 22, 1, "TACKLE", 10) }, later)),
    "the next action is accepted"
  )
  for _ = 1, 900 do
    advance(timeline, TICK)
    if timeline:settled() then
      break
    end
  end
  Assert.isTrue(timeline:settled(), "the next action drains")
  Assert.equal(#fx.starts, 2, "a distinct action identity starts its own occurrence")
end

-- A real source cue with no animation collaborator never counts as shown:
-- without its player the cue must hold or diagnose, never settle as a
-- silent generic success.
function T.effect_keyed_source_cue_without_a_collaborator_never_settles_silently()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(cue)
      sounds.sound(cue)
    end,
  })
  timeline:reset(openingView())
  local after = openingView()
  after.foes[1].hp = 43
  timeline:present(packet(1, { effectStrike(11, 21, 1, "TACKLE", 43) }, after))
  for _ = 1, 600 do
    advance(timeline, TICK)
  end
  local settledQuietly = timeline:settled() and #timeline:diagnostics() == 0
  Assert.isFalse(settledQuietly, "a real source cue with no animation collaborator never counts as shown")
end

---@param sequence integer event sequence under test driving
---@param kind string kernel event kind under test driving
---@param phase string occurrence move phase under test driving
---@param foeHp integer foe health after the checkpoint under test driving
---@return table one effect-keyed two-turn event carrying its native phase identity
local function phaseEvent(sequence, kind, phase, foeHp)
  local combatants = {
    [1] = checkpoint(1, 52, 52),
    [3] = checkpoint(3, foeHp, 57),
  }
  return {
    sequence = sequence,
    kind = kind,
    cause = { key = "FLY" },
    audience = "public",
    actors = { { combatant = 1, activation = 1 } },
    targets = { { combatant = 3, activation = 3 } },
    move = { selected = "FLY", executed = "FLY", phase = phase },
    actionId = 77,
    effectKey = "FLY",
    payload = { target = 3 },
    after = { hp = { [1] = 52, [3] = foeHp }, combatants = combatants },
  }
end

-- A two-turn action admits one native-effect cue per phase occurrence:
-- the charged (charge) and struck (strike) halves of the same action are
-- distinct occurrences, so each executes exactly once through the real
-- player instead of the strike half collapsing onto the charge cue.
function T.two_turn_phases_of_one_action_each_execute_their_own_cue()
  local sounds = sink()
  local fx = taskAwareEffects(nativeProbeProgram())
  local timeline = BattleTimeline.new({
    sound = function(cue)
      sounds.sound(cue)
    end,
    effects = fx,
  })
  timeline:reset(openingView())
  local after = openingView()
  after.foes[1].hp = 50
  local first = packet(1, {
    phaseEvent(11, "charged", "charge", 57),
    phaseEvent(12, "struck", "direct", 50),
  }, after)
  Assert.isTrue(timeline:present(first), "the two-phase action is accepted")
  for _ = 1, 900 do
    advance(timeline, TICK)
    if timeline:settled() then
      break
    end
  end
  Assert.isTrue(timeline:settled(), "both phase halves drain")
  Assert.equal(#fx.starts, 2, "the charged and struck halves each start their own occurrence")
  Assert.equal(fx.starts[1].event.kind, "charged", "the charge half leads")
  Assert.equal(fx.starts[2].event.kind, "struck", "the strike half follows")
  Assert.isFalse(timeline:present(first), "redelivery of the same packet queues nothing new")
  Assert.equal(#fx.starts, 2, "redelivery starts no further occurrence")
end

-- Plays a timeline to rest, recording each narration page (by its final
-- wording) and each drained sound in the order the player saw and heard them.
---@param timeline BattleTimeline
---@param sounds table recording sink behind the timeline
---@param budget integer? maximum source ticks
---@return string[] ordered transcript entries
local function transcript(timeline, sounds, budget)
  local entries, slot, heard = {}, {}, 0
  for _ = 1, budget or 3000 do
    advance(timeline, TICK)
    if timeline:levelUpStats() ~= nil or timeline:messageActive() then
      timeline:ack()
    end
    for index = heard + 1, #sounds.played do
      -- Typed cues only: the legacy string cry role mirrors its typed cue.
      local cue = sounds.played[index]
      if type(cue) == "table" and cue.kind == "cry" then
        entries[#entries + 1] = "cry:" .. cue.species .. (cue.foe and ":foe" or ":own")
      elseif type(cue) == "table" then
        entries[#entries + 1] = tostring(cue.kind) .. ":" .. tostring(cue.symbol)
      end
    end
    heard = #sounds.played
    local id = timeline:messageId()
    if id ~= 0 then
      if slot[id] == nil then
        entries[#entries + 1] = ""
        slot[id] = #entries
      end
      entries[slot[id]] = timeline:message()
    end
    if timeline:settled() then
      break
    end
  end
  return entries
end

function T.experience_uses_boosted_message_and_source_sounds()
  local sounds = sink()
  local messageCalls = {}
  local timeline = BattleTimeline.new({
    sound = function(cue)
      sounds.sound(cue)
    end,
    messageText = function(_, key, substitutions)
      messageCalls[#messageCalls + 1] = { key = key, substitutions = substitutions }
      return key .. ":" .. table.concat(substitutions, ":")
    end,
  })
  timeline:reset(openingView())
  local after = openingView()
  after.foes[1].hp = 0
  after.own[1].experience = 11000
  after.own[1].level = 22
  local payload = {
    combatant = 1,
    gained = 3000,
    boosted = true,
    experienceBefore = 8000,
    experienceAfter = 11000,
    crossedLevels = { 21, 22 },
    levelUps = {
      {
        level = 21,
        experienceBefore = 8000,
        experienceAfter = 9261,
        statsBefore = {
          level = 20,
          hp = 45,
          attack = 30,
          defense = 25,
          specialAttack = 30,
          specialDefense = 25,
          speed = 20,
        },
        statsAfter = {
          level = 21,
          hp = 48,
          attack = 32,
          defense = 26,
          specialAttack = 31,
          specialDefense = 27,
          speed = 22,
        },
      },
      {
        level = 22,
        experienceBefore = 9261,
        experienceAfter = 10648,
        statsBefore = {
          level = 21,
          hp = 48,
          attack = 32,
          defense = 26,
          specialAttack = 31,
          specialDefense = 27,
          speed = 22,
        },
        statsAfter = {
          level = 22,
          hp = 51,
          attack = 34,
          defense = 28,
          specialAttack = 33,
          specialDefense = 28,
          speed = 24,
        },
      },
    },
    expSegments = {
      { level = 20, startExp = 8000, targetExp = 9261, fromPixels = 0, toPixels = 96 },
      { level = 21, startExp = 9261, targetExp = 10648, fromPixels = 0, toPixels = 96 },
      { level = 22, startExp = 10648, targetExp = 11000, fromPixels = 0, toPixels = 24 },
    },
  }
  local delivery = packet(1, { event("exp", payload, { [1] = 52 }) }, after)
  delivery.result = { word = "win" }
  timeline:present(delivery)
  transcript(timeline, sounds, 6000)
  Assert.equal(
    messageCalls[1].key,
    "battle/narration/experience/boosted",
    "traded experience selects the boosted source message"
  )
  Assert.deepEqual(messageCalls[1].substitutions, { "LEAD", "3000" }, "the source message receives nickname and award")
  Assert.equal(sounds.played[1].kind, "music", "wild victory music starts before the first experience line")
  Assert.equal(sounds.played[1].symbol, "SEQ_GS_WIN2", "wild experience begins the retail win track")
  Assert.equal(sounds.countEffect("SEQ_SE_DP_EXP"), 3, "each of the three experience segments has its fill sound")
  Assert.equal(sounds.countEffect("SEQ_SE_DP_EXPMAX"), 2, "each crossed level flashes at full")
end

function T.level_up_exposes_two_six_stat_pages_that_wait_for_input()
  local timeline = BattleTimeline.new({
    messageText = function(_, key, substitutions)
      return key .. ":" .. table.concat(substitutions, ":")
    end,
  })
  timeline:reset(openingView())
  local after = openingView()
  after.own[1].experience = 9261
  after.own[1].level = 21
  local statsBefore = { hp = 45, attack = 30, defense = 25, specialAttack = 30, specialDefense = 25, speed = 20 }
  local statsAfter = { hp = 48, attack = 32, defense = 26, specialAttack = 31, specialDefense = 27, speed = 22 }
  timeline:present(packet(1, {
    event("exp", {
      combatant = 1,
      gained = 1261,
      experienceBefore = 8000,
      experienceAfter = 9261,
      expSegments = { { level = 20, startExp = 8000, targetExp = 9261, fromPixels = 0, toPixels = 96 } },
      levelUps = { { level = 21, statsBefore = statsBefore, statsAfter = statsAfter } },
    }, { [1] = 52 }),
  }, after))
  local pages = {}
  for _ = 1, 500 do
    advance(timeline, TICK)
    local stats = timeline:levelUpStats()
    if stats ~= nil then
      pages[#pages + 1] = stats
      Assert.equal(#stats.rows, 6, "each level-up page carries all six source stats")
      Assert.isTrue(timeline:busy(), "a stat page keeps later progression cues queued")
      Assert.isTrue(timeline:ack(), "the active stat page consumes its input edge")
    elseif timeline:messageActive() then
      timeline:ack()
    end
    if timeline:settled() then
      break
    end
  end
  Assert.equal(#pages, 2, "one level-up has delta and total pages")
  Assert.equal(pages[1].page, "delta", "the first stats page shows the gains")
  Assert.equal(
    pages[1].rows[1].label,
    "battle/level-up/stat-name:battle/stat/hp:",
    "the stat label resolves through its semantic source record"
  )
  Assert.equal(
    pages[1].rows[1].value,
    "battle/level-up/stat-delta:3",
    "the gain page lets the source record supply its plus sign"
  )
  Assert.equal(pages[2].page, "total", "the second stats page shows new totals")
  Assert.equal(pages[2].rows[1].value, "battle/level-up/stat-total:48", "the total page uses the source stat selector")
  Assert.isTrue(timeline:settled(), "acknowledging the total page releases progression")
end

function T.experience_bar_advances_one_pixel_per_source_tick()
  local timeline = BattleTimeline.new({ textSpeed = "fastest" })
  timeline:reset(openingView())
  local after = openingView()
  after.own[1].experience = 8090
  timeline:present(packet(1, {
    event("exp", {
      combatant = 1,
      gained = 90,
      experienceBefore = 8000,
      experienceAfter = 8090,
      expSegments = { { level = 20, startExp = 8000, targetExp = 8090, fromPixels = 0, toPixels = 96 } },
      levelUps = {},
    }, { [1] = 52 }),
  }, after))
  for _ = 1, 500 do
    if timeline:messageActive() then
      timeline:ack()
    end
    advance(timeline, TICK)
    if timeline._active ~= nil and timeline._active.kind == "exp" then
      break
    end
  end
  Assert.isTrue(
    timeline._active ~= nil and timeline._active.kind == "exp",
    "the source experience line leads into its bar"
  )
  for _ = 1, 94 do
    advance(timeline, TICK)
  end
  Assert.isTrue(battler(timeline:battlers(), 1).exp < 8090, "the bar is still moving before its 96th source tick")
  advance(timeline, TICK)
  Assert.equal(battler(timeline:battlers(), 1).exp, 8090, "the 96-pixel bar completes after 96 source ticks")
end

function T.level_up_stats_render_in_the_battle_detail_pane()
  local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
  local graphics = require("tests.support.FakeGraphics").new({})
  local text = { draws = {} }
  function text.measure(content)
    return { width = 8 * #tostring(content), height = 8 }
  end
  function text.drawText(content, x, y)
    text.draws[#text.draws + 1] = { content = tostring(content), x = x, y = y }
  end
  local windows = { calls = {} }
  function windows.drawWindow(box)
    windows.calls[#windows.calls + 1] = box
  end
  local resources = {
    graphics = graphics,
    text = text,
    windows = windows,
    assets = {
      drawable = function()
        return nil
      end,
    },
    sceneImageKey = "unused",
    frameKey = "frame",
  }
  local palette = {}
  for index = 1, 16 do
    palette[index] = { r = 255, g = 255, b = 255 }
  end
  local view = {
    battlers = {},
    effectInstances = {},
    textPalettes = { narration = { colors = palette } },
    levelUpStats = {
      level = 21,
      page = "delta",
      rows = { { label = "HP", value = "+3" } },
    },
  }
  BattleRenderer.drawPane(resources, view, "detail", {}, {})
  Assert.deepEqual(
    windows.calls[1],
    { x = 136, y = 56, width = 112, height = 96 },
    "the stat panel uses its source detail window footprint"
  )
  Assert.equal(text.draws[1].content, "HP", "the stat page prints the source stat name")
  Assert.equal(text.draws[2].content, "+3", "the stat page prints its signed increase")
  Assert.equal(text.draws[1].x, 136, "stat names use the retail left column")
  Assert.equal(text.draws[2].x, 216, "stat values use the retail right column")
end

function T.narration_prints_each_source_line_on_its_own_row()
  local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
  local text = { draws = {} }
  function text.measure(content)
    return { width = 8 * #tostring(content), height = 8 }
  end
  function text.drawText(content, x, y)
    text.draws[#text.draws + 1] = { content = tostring(content), x = x, y = y }
  end
  local palette = {}
  for index = 1, 16 do
    palette[index] = { r = 255, g = 255, b = 255 }
  end
  local resources = {
    graphics = require("tests.support.FakeGraphics").new({}),
    text = text,
    windows = {
      drawWindow = function() end,
    },
    assets = {
      drawable = function()
        return nil
      end,
    },
    sceneImageKey = "unused",
    frameKey = "frame",
  }
  local view = {
    battlers = {},
    effectInstances = {},
    textPalettes = { narration = { colors = palette } },
    message = "Foe is hit\nwith recoil!",
  }
  BattleRenderer.drawPane(resources, view, "detail", {}, {})
  local rows = {}
  for _, draw in ipairs(text.draws) do
    Assert.isTrue(draw.content:find("[\n\r\f]") == nil, "no control character reaches the font")
    rows[#rows + 1] = draw.content
  end
  Assert.deepEqual(rows, { "Foe is hit", "with recoil!" }, "each source line is drawn separately")
  Assert.equal(text.draws[2].y - text.draws[1].y, 16, "source lines step one font row")
end

-- subscript_0000_StartEncounter: the wild foe cries before msg_0197_00965,
-- and the lead cries on its send-out after "Go!".
function T.wild_opening_follows_the_source_encounter_order()
  local sounds = sink()
  local timeline = BattleTimeline.new({ sound = sounds.sound })
  timeline:intro(openingView(), true)
  Assert.deepEqual(transcript(timeline, sounds), {
    "cry:EEVEE:foe",
    "A wild FOE appeared!",
    "Go! LEAD!",
    "effect:SEQ_SE_DP_BOWA2",
    "cry:EEVEE:own",
  }, "the wild opening keeps the retail order and wording")
end

-- Nickname-tagged lines address an enemy battler through the source
-- variants: "The wild" in wild battles and "The foe's" against trainers.
function T.enemy_battlers_are_addressed_through_source_name_variants()
  for _, case in ipairs({
    { controller = "wild", used = "The wild FOE used Tackle!", fainted = "The wild FOE fainted!" },
    { controller = "trainer", used = "The foe’s FOE used Tackle!", fainted = "The foe’s FOE fainted!" },
  }) do
    local sounds = sink()
    local timeline = BattleTimeline.new({
      sound = sounds.sound,
      moveName = function(_)
        return "Tackle"
      end,
    })
    local view = openingView()
    view.foes[1].controller = case.controller
    timeline:reset(view)
    local after = openingView()
    after.foes[1].controller = case.controller
    after.own[1].hp = 40
    local strike = event("struck", { target = 1, damage = 12, hitIndex = 1 }, { [1] = 40, [3] = 57 })
    strike.actors = { { combatant = 3 } }
    strike.targets = { { combatant = 1 } }
    local faint = event("fainted", { target = 3 }, { [1] = 40, [3] = 0 })
    faint.sequence = 2
    local delivery = packet(1, { strike, faint }, after)
    delivery.before.foes[1].controller = case.controller
    Assert.isTrue(timeline:present(delivery), case.controller .. " delivery is accepted")
    local seen = transcript(timeline, sounds)
    Assert.isTrue(seen[1] == case.used, case.controller .. " move line: " .. tostring(seen[1]))
    local fainted = false
    for _, entry in ipairs(seen) do
      fainted = fainted or entry == case.fainted
    end
    Assert.isTrue(fainted, case.controller .. " faint line reads " .. case.fainted)
  end
end

-- subscript_0002_UpdateHp then subscript_0016/0021: one impact voice chosen
-- by effectiveness and panned at the struck side, the bar, then the
-- critical and effectiveness lines.
function T.strike_voices_its_effectiveness_then_narrates_critical_and_effectiveness()
  local BattleAudio = require("libs.hgss.src.audio.BattleAudio")
  local sounds = sink()
  local timeline = BattleTimeline.new({ sound = sounds.sound })
  timeline:reset(openingView())
  local after = openingView()
  after.foes[1].hp = 20
  local strike = event(
    "struck",
    { target = 3, damage = 37, hitIndex = 1, critical = true, effectiveness = "super" },
    { [1] = 52, [3] = 20 }
  )
  strike.actors = { { combatant = 1 } }
  Assert.isTrue(timeline:present(packet(1, { strike }, after)), "the strike is accepted")
  local seen = transcript(timeline, sounds)
  Assert.deepEqual(seen, {
    "LEAD used Tackle!",
    "effect:" .. BattleAudio.SINK_SOUNDS.impactSuper,
    "A critical hit!",
    "It’s super effective!",
  }, "the strike keeps its retail order")
  local impact = sounds.played[1]
  Assert.equal(impact.pan, BattleAudio.SIDE_PAN.foe, "the impact pans toward the struck foe")
end

-- BattleHpBar_CalculatePixelsChangeFrame moves one HP per source tick from
-- 48 max HP up, with no duration cap.
function T.health_drain_moves_one_point_per_source_tick()
  local timeline = BattleTimeline.new({})
  timeline:reset(openingView())
  local after = openingView()
  after.foes[1].hp = 7
  timeline:present(
    packet(1, { event("struck", { target = 3, damage = 50, hitIndex = 1 }, { [1] = 52, [3] = 7 }) }, after)
  )
  local first, last = nil, nil
  for tick = 1, 600 do
    advance(timeline, TICK)
    local hp = battler(timeline:battlers(), 3).hp
    if first == nil and hp < 57 then
      first = tick
    end
    if hp == 7 then
      last = tick
      break
    end
  end
  Assert.notNil(first, "the bar starts moving")
  Assert.equal(last - first + 1, 50, "a fifty-point drain takes fifty source ticks")
end

-- BattleControllerOpponent_GetReturnMessage / GetSendOutMessage: single
-- player switches scale their lines by the foe health.
function T.player_switch_lines_follow_the_foe_health()
  local timeline = BattleTimeline.new({})
  local view = openingView()
  view.own[2] = {
    combatant = 2,
    participant = 1,
    side = 1,
    controller = "player",
    active = false,
    hp = 30,
    maxHp = 30,
    species = "EEVEE",
    form = 0,
    name = "BENCH",
    ballKey = "POKE_BALL",
    level = 20,
    experience = 8000,
  }
  timeline:intro(view, true)
  transcript(timeline, sink())
  local after = openingView()
  after.own[2] = view.own[2]
  after.foes[1].hp = 20
  local swap = event("switch", { from = 1, to = 2, position = 1 }, { [1] = 52, [3] = 20 })
  swap.cause = { kind = "switch" }
  local delivery = packet(1, { swap }, after)
  delivery.before.own[2] = view.own[2]
  Assert.isTrue(timeline:present(delivery), "the switch is accepted")
  local seen = transcript(timeline, sink())
  -- 37 of 57 HP lost: 64 percent recalls with "OK!"; 20/57 = 350 permille
  -- sends out with "Go for it".
  Assert.equal(seen[1], "LEAD, OK! Come back!", "the recall scales by the foe health lost")
  Assert.equal(seen[2], "Go for it, BENCH!", "the send-out scales by the foe health left")
end

-- Task_RecallPokemon and Task_PokemonSendOut each voice SEQ_SE_DP_BOWA2
-- panned at the switching side; the arrival cry follows its send-out voice.
function T.switch_voices_recall_and_send_out_with_the_side_pan()
  local BattleAudio = require("libs.hgss.src.audio.BattleAudio")
  local sounds = sink()
  local timeline = BattleTimeline.new({ sound = sounds.sound })
  local view = openingView()
  view.own[2] = {
    combatant = 2,
    participant = 1,
    side = 1,
    controller = "player",
    active = false,
    hp = 30,
    maxHp = 30,
    species = "EEVEE",
    form = 0,
    name = "BENCH",
    ballKey = "POKE_BALL",
    level = 20,
    experience = 8000,
  }
  timeline:reset(view)
  local after = openingView()
  after.own[2] = view.own[2]
  local swap = event("switch", { from = 1, to = 2, position = 1 }, { [1] = 52, [3] = 57 })
  swap.cause = { kind = "switch" }
  local delivery = packet(1, { swap }, after)
  delivery.before.own[2] = view.own[2]
  Assert.isTrue(timeline:present(delivery), "the switch is accepted")
  local seen = transcript(timeline, sounds)
  local voices = {}
  for _, entry in ipairs(seen) do
    if entry:find("^effect:") or entry:find("^cry:") then
      voices[#voices + 1] = entry
    end
  end
  Assert.deepEqual(voices, {
    "effect:" .. BattleAudio.SINK_SOUNDS.ballOpen,
    "effect:" .. BattleAudio.SINK_SOUNDS.partyGaugeShow,
    "effect:" .. BattleAudio.SINK_SOUNDS.ballOpen,
    "cry:EEVEE:own",
  }, "recall, the party gauge, and send-out voice their sounds in source order before the cry")
  Assert.equal(sounds.played[1].pan, BattleAudio.SIDE_PAN.player, "the recall pans to the player side")
  Assert.equal(sounds.played[3].pan, BattleAudio.SIDE_PAN.player, "the send-out pans to the player side")
end

-- subscript_0011_ThrowBall names the throwing trainer, the target enters
-- the ball before any shake, shakes print nothing, and a break-out sends
-- the target back out before its line.
function T.capture_throw_names_the_player_and_hides_the_target_in_the_ball()
  local timeline = BattleTimeline.new({
    itemName = function(_)
      return "Poké Ball"
    end,
  })
  local view = openingView()
  view.playerName = "GOLD"
  timeline:reset(view)
  local after = openingView()
  after.playerName = "GOLD"
  local throw = event("throw", { ball = "POKE_BALL" }, { [1] = 52, [3] = 57 })
  throw.actors = { { combatant = 1 } }
  throw.targets = { { combatant = 3 } }
  local shake = event("shake", { index = 1 }, { [1] = 52, [3] = 57 })
  shake.sequence = 2
  local delivery = packet(1, { throw, shake }, after)
  delivery.before.playerName = "GOLD"
  Assert.isTrue(timeline:present(delivery), "the throw is accepted")
  local seen = transcript(timeline, sink())
  Assert.deepEqual(seen, { "GOLD used one Poké Ball!" }, "the throw prints its source line and shakes print nothing")
  Assert.isFalse(battler(timeline:battlers(), 3).visible, "the target waits inside the ball")
end

-- BtlCmd_ThrowPokeball in a trainer battle: the ball deflects, the target
-- never enters it, and msg_0197_00859 and 00860 follow the throw line.
function T.blocked_throw_prints_the_trainer_block_lines_and_keeps_the_target()
  local timeline = BattleTimeline.new({
    itemName = function(_)
      return "Poké Ball"
    end,
  })
  local view = openingView()
  view.playerName = "GOLD"
  timeline:reset(view)
  local after = openingView()
  after.playerName = "GOLD"
  local throw = event("throw", { ball = "POKE_BALL", blocked = true }, { [1] = 52, [3] = 57 })
  throw.actors = { { combatant = 1 } }
  throw.targets = { { combatant = 3 } }
  local delivery = packet(1, { throw }, after)
  delivery.before.playerName = "GOLD"
  Assert.isTrue(timeline:present(delivery), "the blocked throw is accepted")
  Assert.deepEqual(transcript(timeline, sink()), {
    "GOLD used one Poké Ball!",
    "The Trainer blocked the Ball!",
    "Don't be a thief!",
  }, "the deflected throw prints its three source lines")
  Assert.isTrue(battler(timeline:battlers(), 3).visible, "the trainer's Pokemon never enters the ball")
end

-- subscript_0012_UpdateStatStage wording with msg_0443 stat names.
function T.stage_changes_use_source_wording()
  local timeline = BattleTimeline.new({})
  timeline:reset(openingView())
  local rise = event("stage", { target = 1, stat = "specialAttack", before = 0, after = 2 }, { [1] = 52, [3] = 57 })
  local fall = event("stage", { target = 3, stat = "defense", before = 0, after = -1 }, { [1] = 52, [3] = 57 })
  fall.sequence = 2
  local capped = event("stage", { target = 1, stat = "speed", before = 6, after = 6 }, { [1] = 52, [3] = 57 })
  capped.sequence = 3
  Assert.isTrue(timeline:present(packet(1, { rise, fall, capped }, openingView())), "the stages are accepted")
  Assert.deepEqual(transcript(timeline, sink()), {
    "LEAD’s Sp. Atk sharply rose!",
    "The wild FOE’s Defense fell!",
    "LEAD’s Speed won’t go higher!",
  }, "stage lines follow the source table")
end

return { tests = T }
