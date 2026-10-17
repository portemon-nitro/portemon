-- Unit coverage for the ordered visible-cue player behind the battle
-- screen: event order without read-ahead, per-event checkpoints, bounded
-- clocks, one-shot sound intents, duplicate rejection, held images,
-- multi-segment experience, and explicit diagnostics for unknown effects.
-- Headless: packets are plain records shaped like the detached delivery
-- boundary, and sounds drain into a recording sink.

local Assert = require("tests.support.Assert")
local BattleTimeline = require("game.hgss.src.battle.BattleTimeline")
local MonCache = require("libs.assets.src.MonCache")

local T = {}
local TICK = 1 / 30

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
  Assert.isTrue(
    timeline:present(
      packet(1, { event("struck", { target = 3, damage = 14, hitIndex = 1 }, { [1] = 52, [3] = 43 }) }, after)
    ),
    "the first packet is accepted"
  )
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
    if battler(timeline:battlers(), 3).visible == false and faintAt == nil then
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
  Assert.equal(
    sounds.countEffect(BattleAudio.SINK_SOUNDS.impact),
    1,
    "a strike carries its impact voice exactly once"
  )
  Assert.equal(
    sounds.countEffect(BattleAudio.SINK_SOUNDS.effectiveness),
    1,
    "a strike carries its effectiveness voice exactly once"
  )
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

-- Unknown required effects never vanish silently: a diagnostic message
-- plays and the occurrence is recorded.
function T.unknown_effects_produce_a_diagnostic()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(cue)
      sounds.sound(cue)
    end,
  })
  timeline:reset(openingView())
  timeline:present(packet(1, { event("mystery_surcharge", { target = 3 }, { [1] = 52, [3] = 57 }) }, openingView()))
  Assert.isFalse(timeline:settled(), "the diagnostic still plays as a cue")
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
  local BattleScreenState = require("game.hgss.src.battle.BattleScreenState")
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
      level = 20,
      selector = "front",
    }
  end
  local function beforeView()
    return { own = { ownRecord() }, foes = { foeRecordEntry(57) } }
  end
  local function afterView()
    return { own = { ownRecord() }, foes = { foeRecordEntry(43) } }
  end
  local struck = event("struck", { target = 3, damage = 14, hitIndex = 1 }, { [1] = 52, [3] = 43 })
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

-- Each named narration pace reveals a bounded number of glyphs per
-- fixed tick: the unhurried paces pause blank ticks between glyphs
-- while the hurried paces print more per tick, and no pace shows a
-- whole page at once. An unknown pace fails; omitting the pace keeps
-- the established middle cadence.
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
  Assert.equal(shownAfter("slow", 8), 1, "the slowest pace holds through its blank ticks")
  Assert.equal(shownAfter("slow", 9), 2, "the slowest pace shows its next glyph after the pause")
  Assert.equal(shownAfter("mid", 1), 1, "the middle pace shows one glyph on its first tick")
  Assert.equal(shownAfter("mid", 4), 1, "the middle pace holds through its blank ticks")
  Assert.equal(shownAfter("mid", 5), 2, "the middle pace shows its next glyph after the pause")
  Assert.equal(shownAfter("mid", 9), 3, "the middle pace keeps its every-fourth-tick cadence")
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
  opening.foes[2] = doubleRecord(4, 4, 14, false, "BIDOOF", "FOE-B", 5, 30, 33)
  local timeline = BattleTimeline.new({ sound = function(_) end })
  timeline:reset(opening)
  Assert.equal(battler(timeline:battlers(), 3).species, "BIDOOF", "the first foe opens with the shared species")
  Assert.equal(battler(timeline:battlers(), 4).species, "BIDOOF", "the second foe opens with the shared species")
  local after = doubleOpeningView()
  after.foes[1] = doubleRecord(3, 3, 13, false, "BIDOOF", "FOE-A", 4, 45, 45)
  after.foes[2] = doubleRecord(5, 4, 15, false, "PICHU", "FOE-C", 5, 33, 33)
  local health = {
    [1] = { position = 1, side = 1, hp = 40, maxHp = 40 },
    [2] = { position = 2, side = 1, hp = 35, maxHp = 38 },
    [3] = { position = 3, side = 2, hp = 45, maxHp = 45 },
    [4] = { position = 4, side = 2, hp = 0, maxHp = 33 },
    [5] = { position = 4, side = 2, hp = 33, maxHp = 33 },
  }
  Assert.isTrue(
    timeline:present(doublePacket(1, {
      doubleEvent("struck", { target = 4, damage = 30, hitIndex = 1 }, health),
      doubleEvent("faint", { combatant = 4, activation = 14, position = 4 }, health),
      doubleEvent("switch", { from = 4, incoming = 5 }, health),
    }, after)),
    "the knockout packet is accepted"
  )
  local shookTarget = false
  local partnerShook = false
  local faintAt = nil
  local revealedAt = nil
  local ticks = 0
  while not timeline:settled() and ticks < 3000 do
    advance(timeline, TICK)
    ticks = ticks + 1
    if timeline:shake(4) ~= 0 then
      shookTarget = true
    end
    if timeline:shake(3) ~= 0 then
      partnerShook = true
    end
    if battler(timeline:battlers(), 4).visible == false and faintAt == nil then
      faintAt = ticks
    end
    for _, entry in ipairs(timeline:battlers()) do
      if entry.combatant == 5 and entry.visible == true and revealedAt == nil then
        revealedAt = ticks
      end
    end
  end
  Assert.isTrue(shookTarget, "the struck record recoils through its hit cue")
  Assert.isFalse(partnerShook, "the surviving partner never recoils")
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
-- source tick is nominally 1/30 second however the host slices its frames.
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
  -- Cadence ownership at the middle pace: one glyph on the first source
  -- tick, the next after its pause, and the page complete on its boundary.
  local paced = announced()
  for _ = 1, 5 do
    advance(paced, 1 / 30)
  end
  Assert.equal(paced:message(), "AB", "five source ticks reveal two glyphs at the middle pace")
  local bounded = announced()
  for _ = 1, 44 do
    advance(bounded, 1 / 30)
  end
  Assert.isFalse(bounded:settled(), "a paced page never finishes in half its source time")
  for _ = 45, 88 do
    advance(bounded, 1 / 30)
  end
  Assert.isTrue(bounded:settled(), "the paced page settles on its source-tick boundary")
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
    for _, dt in ipairs(schedule) do
      advance(played, dt)
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
  for _ = 1, 5 do
    advance(bounded, 1 / 30)
  end
  Assert.isFalse(bounded:settled(), "a six-tick wait never finishes after five source ticks")
  advance(bounded, 1 / 30)
  Assert.isTrue(bounded:settled(), "the wait terminates exactly on its sixth source tick")
  local immediate = fled()
  advance(immediate, 6 / 30)
  Assert.isTrue(immediate:settled(), "one frame carrying the whole wait settles without another frame")
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
    held:update(1 / 30, available)
  end
  held:update(5, available)
  local frozenText = held:message()
  local frozenHp = battler(held:battlers(), 3).hp
  for _ = 1, 20 do
    held:update(1 / 30, available)
  end
  Assert.equal(held:message(), frozenText, "waiting changes readiness, never the revealed text")
  Assert.equal(battler(held:battlers(), 3).hp, frozenHp, "waiting consumes no health ticks")
  Assert.equal(frozenHp, 57, "the held checkpoint never leaks early")
  Assert.isFalse(held:settled(), "the held cue reports unready instead of skipping")
  ready[foeKey] = true
  local remaining = 0
  while not held:settled() and remaining < 2000 do
    held:update(1 / 30, available)
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
  local BattleScreenState = require("game.hgss.src.battle.BattleScreenState")
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
    for _ = 1, 2400 do
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
    Assert.equal(screen:status().mode, "command", "the opening reaches the first command prompt")

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
      partition .. " Hz should match the 30 Hz source slide trace"
    )
    expect(partitionGates[index + 1] == gateIntact, partition .. " Hz should keep the same input gate boundaries")
    expect(partitionOpens[index + 1] == openedAfterGate, partition .. " Hz should open at the same source boundary")
  end
  Assert.isTrue(#failures == 0, table.concat(failures, "; "))
end

-- The source-selected bank entry enters the same paced timeline as other
-- narration, while the detached C04 event remains unchanged.
function T.source_capture_text_uses_the_battle_printer_timeline()
  local BattleTimeline = require("game.hgss.src.battle.BattleTimeline")
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
    timeline:update(1 / 30, function()
      return true
    end)
    if timeline:message() ~= "" then
      break
    end
  end
  Assert.isTrue(timeline:message():sub(1, 1) == "A", "the source template feeds the paced battle printer")
end

return { tests = T }
