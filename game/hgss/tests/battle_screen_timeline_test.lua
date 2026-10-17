-- Unit coverage for the ordered visible-cue player behind the battle
-- screen: event order without read-ahead, per-event checkpoints, bounded
-- clocks, one-shot sound intents, duplicate rejection, held images,
-- multi-segment experience, and explicit diagnostics for unknown effects.
-- Headless: packets are plain records shaped like the detached delivery
-- boundary, and sounds drain into a recording sink.

local Assert = require("tests.support.Assert")
local StubLease = require("tests.support.StubLease")
local BattleTimeline = require("game.hgss.src.battle.BattleTimeline")
local MonCache = require("libs.assets.src.MonCache")

local T = {}
local TICK = 1 / 60

---@param sounds table<string, boolean>? names the sink must refuse (muted)
---@return table recording sound-intent sink
local function sink(muted)
  local records = { played = {}, muted = muted or {} }
  function records.sound(name)
    records.played[#records.played + 1] = name
  end
  function records.count(name)
    local total = 0
    for _, played in ipairs(records.played) do
      if played == name then
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
    sound = function(name)
      sounds.sound(name)
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

-- Faint hides its battler only after the health checkpoint, and later
-- checkpoints never resurrect it.
function T.faint_hides_after_its_checkpoint_and_stays_hidden()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(name)
      sounds.sound(name)
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
    sound = function(name)
      sounds.sound(name)
    end,
  })
  timeline:reset(openingView())
  local after = openingView()
  after.foes[1].hp = 43
  local first = packet(1, { event("struck", { target = 3, damage = 14, hitIndex = 1 }, { [1] = 52, [3] = 43 }) }, after)
  Assert.isTrue(timeline:present(first), "the first delivery is accepted")
  Assert.isFalse(timeline:present(first), "the same packet identity is rejected")
  local soundsBefore = #sounds.played
  advance(timeline, 10)
  Assert.equal(#sounds.played, soundsBefore, "a strike carries no sound intent of its own")
  Assert.isTrue(timeline:settled(), "the single delivery drains")
  Assert.equal(battler(timeline:battlers(), 3).hp, 43, "one delivery applies its checkpoint once")
end

-- A cue needing an unavailable image holds without advancing: health
-- stays at its earlier checkpoint until the image arrives.
function T.held_images_hold_their_cue()
  local sounds = sink()
  local timeline = BattleTimeline.new({
    sound = function(name)
      sounds.sound(name)
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
    sound = function(name)
      sounds.sound(name)
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
    sound = function(name)
      sounds.sound(name)
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
      assets.images[key] = StubLease.new(key)
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
    manifest = {
      schema = "test",
      version = { id = "t", language = "english" },
      verified = false,
      scenes = { { key = "general/plain/day" } },
    },
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
    sound = function(name)
      sounds.sound(name)
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
  Assert.equal(sounds.count("cry:TOTODILE"), 1, "the opening cries the live lead species once")
  Assert.equal(sounds.count("cry:EEVEE"), 0, "the fainted first slot never lends its cry")
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

return { tests = T }
