-- Radio channel selection and exact tuner behavior: every map and story
-- condition resolves to its ordered source channel table, tuning
-- coordinates resolve to stations through paired clear/weak circles with
-- the native strict boundary, held keys move the cursor two source pixels
-- per update with per-axis circle gating, the preset key snaps through the
-- fixed center table even where the active table has fewer stations, touch
-- drags only follow inside the tuning circle, and station changes follow
-- the native lifecycle where a same-station signal change only alters
-- static, a changed station tears down and reopens, and leaving every
-- station closes the show with a music stop. All coordinates, radii,
-- station identities, and transition outcomes below are transcribed from
-- the native radio hitbox tables and station switch; nothing is read out
-- of the modules under test.

local Assert = require("tests.support.Assert")
local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
local PokegearState = require("libs.hgss.src.save.PokegearState")
local PokegearCalendar = require("game.hgss.src.pokegear.PokegearCalendar")
local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local RadioProgram = require("game.hgss.src.pokegear.RadioProgram")
local RadioWorldContext = require("game.hgss.src.pokegear.RadioWorldContext")
local Fixture = require("tests.support.PokegearBroadcastFixture")

local T = {
  metadata = {
    tags = { "pokegear" },
  },
  tests = {},
}

-- Loads a radio module that does not exist yet at this baseline. The
-- failure names the missing behaviour instead of surfacing as a suite load
-- error, so the pre-implementation red stays attributable.
---@param moduleName string
---@param missingMessage string
---@return table
local function requireFeature(moduleName, missingMessage)
  local ok, mod = pcall(require, moduleName)
  if not ok then
    error(missingMessage, 0)
  end
  assert(type(mod) == "table", missingMessage)
  return mod --[[@as table]]
end

---@param overrides table<string, unknown>?
---@return table<string, unknown> semantic map facts for channel selection
local function mapFacts(overrides)
  local facts = {
    key = "route-29",
    region = "johto",
    allowsRadio = true,
    alph = false,
    mahogany = false,
  }
  for key, value in pairs(overrides or {}) do
    facts[key] = value
  end
  return facts --[[@as table<string, unknown>]]
end

---@param overrides table<string, unknown>?
---@return table<string, unknown> story flags for channel selection
local function worldFlags(overrides)
  local flags = {
    powerRestored = false,
    kantoExpansion = false,
    hideoutCleared = false,
    rocketTakeover = false,
  }
  for key, value in pairs(overrides or {}) do
    flags[key] = value
  end
  return flags --[[@as table<string, unknown>]]
end

---@return table validated catalog, table refs
local function catalogAndRefs()
  local validated = PokegearAssetSchema.validate(Fixture.fixtureManifest())
  Assert.notNil(validated, "the synthetic broadcast catalog must validate through the asset schema")
  local record = assert(validated, "scenario setup keeps the validated catalog")
  return record, Fixture.catalogRefs(record)
end

---@return table presentation stub recording every call without drawing
local function stubPresentation()
  local stub = { calls = {} }
  return setmetatable(stub, {
    __index = function(holder, key)
      local seen = rawget(holder, "calls")
      local fn = function(...)
        seen[#seen + 1] = { method = key, args = { ... } }
      end
      rawset(holder, key, fn)
      return fn
    end,
  })
end

---@param seed integer
---@return table program, table audio, table messages, table state, table record
local function freshProgram(seed)
  local record = catalogAndRefs()
  local refs = Fixture.catalogRefs(record)
  local state = PokegearState.new({ seed = seed }, refs)
  local calendar = PokegearCalendar.new(state)
  local random = PokegearRandom.new(seed, { trace = {}, traceLimit = 8192 })
  local events = FieldEventState.new()
  local world = RadioWorldContext.new({
    state = state,
    calendar = calendar,
    eventState = events,
    encounters = { swarm = false },
    dex = Fixture.newDexReader(false),
    bag = Fixture.newBagReader({}),
  })
  local civil = Fixture.newCivilCell({ year = 2024, month = 1, day = 8, hour = 10, minute = 0, second = 0 })
  local audio = Fixture.newAudioStandIn()
  local messages = Fixture.newMessageLog()
  local program = RadioProgram.new({
    catalog = record.catalog,
    world = world,
    clock = civil.clock,
    random = random,
    audio = audio,
    messages = messages,
  })
  return program, audio, messages, state, record
end

---@param seed integer
---@param map table<string, unknown>
---@param flags table<string, unknown>
---@param effect fun(sequence: string)?
---@return table box with controller, program, audio, state
local function openController(seed, map, flags, effect)
  local Reception = requireFeature(
    "game.hgss.src.pokegear.RadioReception",
    "radio channel selection has no ordered reception policy yet: no map can choose its source channel table"
  )
  local Controller = requireFeature(
    "game.hgss.src.pokegear.RadioController",
    "radio tuning has no input owner yet: cursor motion, presets, drags, and station changes do nothing"
  )
  local program, audio, _, state, record = freshProgram(seed)
  local controller = Controller.new({
    state = state,
    catalog = record.catalog,
    program = program,
    reception = Reception,
    presentation = stubPresentation(),
    map = map,
    flags = flags,
    effect = effect,
  })
  return { controller = controller, program = program, audio = audio, state = state }
end

---@param box table
---@return integer station, integer signal, table cursor
local function selectionOf(box)
  local status = box.controller:status()
  assert(type(status) == "table", "the tuner publishes its selection")
  return assert(status.station, "the tuner names its station"),
    assert(status.signal, "the tuner names its signal"),
    assert(status.cursor, "the tuner names its cursor")
end

---@param box table
---@param station integer
---@param signal integer
---@param x integer
---@param y integer
local function checkSelection(box, station, signal, x, y)
  local actualStation, actualSignal, cursor = selectionOf(box)
  Assert.equal(actualStation, station, string.format("cursor (%d,%d) tunes station %s", x, y, tostring(station)))
  Assert.equal(actualSignal, signal, string.format("cursor (%d,%d) carries signal %s", x, y, tostring(signal)))
  Assert.equal(cursor.x, x, "the cursor keeps its horizontal position")
  Assert.equal(cursor.y, y, "the cursor keeps its vertical position")
end

-- Drags the cursor to one dial point: press at the cursor, move once,
-- release. The press lands exactly on the cursor so the drag always starts.
---@param box table
---@param x integer
---@param y integer
local function dragTo(box, x, y)
  local _, _, cursor = selectionOf(box)
  box.controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = cursor.x, y = cursor.y } })
  box.controller:updateFixed({ { type = "pointer_move", pointerId = "touch:1", x = x, y = y } })
  box.controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y } })
end

---@param box table
---@param direction string
---@param count integer
local function hold(box, direction, count)
  for _ = 1, count do
    box.controller:updateFixed({ { type = "navigate", direction = direction } })
  end
end

-- Advances both tick owners until the program settles on a scheduled show
-- past any one-shot commercial interruption.
---@param box table
---@param budget integer?
---@return string settled show key
local function settleShow(box, budget)
  for _ = 1, budget or 1500 do
    box.controller:updateFixed({})
    box.program:updateFixed()
    local show = box.program:status().show
    if show ~= nil and show ~= "radio.commercial" then
      return show
    end
  end
  error("the tuned station never settles on its scheduled show", 0)
end

function T.tests.tuning_selects_source_channels_and_resolves_exact_circular_boundaries()
  local Reception = requireFeature(
    "game.hgss.src.pokegear.RadioReception",
    "radio channel selection has no ordered reception policy yet: no map can choose its source channel table"
  )
  requireFeature(
    "game.hgss.src.pokegear.RadioController",
    "radio tuning has no input owner yet: cursor motion, presets, drags, and station changes do nothing"
  )

  -- Ordered channel priority: a map that forbids radio wins over every
  -- special set, Alph beats the takeover, Kanto branches on restored power
  -- and the expansion card before any takeover, Mahogany holds only while
  -- its hideout stands uncleared, and Johto falls back to the takeover.
  local receptionCases = {
    {
      map = mapFacts({ allowsRadio = false, alph = true }),
      flags = worldFlags({ rocketTakeover = true }),
      want = "none",
    },
    { map = mapFacts({ alph = true, mahogany = true }), flags = worldFlags({ rocketTakeover = true }), want = "alph" },
    {
      map = mapFacts({ key = "route-28", region = "kanto" }),
      flags = worldFlags({ powerRestored = true, kantoExpansion = true, rocketTakeover = true }),
      want = "kanto-expn",
    },
    {
      map = mapFacts({ key = "route-28", region = "kanto" }),
      flags = worldFlags({ powerRestored = false, rocketTakeover = true }),
      want = "none",
    },
    {
      map = mapFacts({ key = "route-28", region = "kanto" }),
      flags = worldFlags({ powerRestored = true }),
      want = "kanto",
    },
    {
      map = mapFacts({ key = "mahogany", mahogany = true }),
      flags = worldFlags({ rocketTakeover = true }),
      want = "mahogany",
    },
    {
      map = mapFacts({ key = "mahogany", mahogany = true }),
      flags = worldFlags({ hideoutCleared = true, rocketTakeover = true }),
      want = "rocket",
    },
    { map = mapFacts(), flags = worldFlags({ rocketTakeover = true }), want = "rocket" },
    { map = mapFacts(), flags = worldFlags(), want = "johto" },
  }
  for _, case in ipairs(receptionCases) do
    Assert.equal(
      Reception.forContext(case.map, case.flags),
      case.want,
      "channel priority resolves " .. tostring(case.map.key)
    )
  end
  local rejected = 0
  for _, bad in ipairs({ { map = nil, flags = worldFlags() }, { map = {}, flags = worldFlags() } }) do
    local ok = pcall(function()
      Reception.forContext(bad.map, bad.flags)
    end)
    if not ok then
      rejected = rejected + 1
    end
  end
  Assert.equal(rejected, 2, "missing map signal metadata is rejected instead of defaulting to a channel")

  -- Exact circular boundaries on the four-station table. Clear circles use
  -- radii 4 and weak circles 16/20/16/20; points exactly on a clear rim
  -- fall out to weak, and points exactly on a weak rim tune nothing.
  local johto = openController(11, mapFacts(), worldFlags())
  local johtoPoints = {
    { x = 112, y = 76, station = 0, signal = 2 },
    { x = 152, y = 76, station = 1, signal = 2 },
    { x = 96, y = 108, station = 2, signal = 2 },
    { x = 136, y = 116, station = 3, signal = 2 },
    { x = 116, y = 76, station = 0, signal = 1 },
    { x = 112, y = 72, station = 0, signal = 1 },
    { x = 115, y = 76, station = 0, signal = 2 },
    { x = 148, y = 76, station = 1, signal = 1 },
    { x = 152, y = 96, station = 255, signal = 0 },
    { x = 99, y = 108, station = 2, signal = 2 },
    { x = 96, y = 104, station = 2, signal = 1 },
    { x = 132, y = 76, station = 255, signal = 0 },
    { x = 128, y = 92, station = 255, signal = 0 },
    { x = 140, y = 116, station = 3, signal = 1 },
  }
  for _, point in ipairs(johtoPoints) do
    dragTo(johto, point.x, point.y)
    checkSelection(johto, point.station, point.signal, point.x, point.y)
  end

  -- Remaining tables: the expansion card adds the fourth station and the
  -- flute pair, Alph resolves every hit to the fifth station, Rocket and
  -- Mahogany resolve theirs, and a dead table tunes nothing anywhere.
  local expn =
    openController(12, mapFacts({ region = "kanto" }), worldFlags({ powerRestored = true, kantoExpansion = true }))
  dragTo(expn, 128, 48)
  checkSelection(expn, 4, 2, 128, 48)
  dragTo(expn, 128, 52)
  checkSelection(expn, 4, 1, 128, 52)
  dragTo(expn, 128, 56)
  checkSelection(expn, 255, 0, 128, 56)
  local alph = openController(13, mapFacts({ alph = true }), worldFlags())
  dragTo(alph, 128, 92)
  checkSelection(alph, 5, 2, 128, 92)
  dragTo(alph, 132, 92)
  checkSelection(alph, 5, 1, 132, 92)
  dragTo(alph, 128, 108)
  checkSelection(alph, 255, 0, 128, 108)
  local rocket = openController(14, mapFacts(), worldFlags({ rocketTakeover = true }))
  dragTo(rocket, 128, 92)
  checkSelection(rocket, 6, 2, 128, 92)
  dragTo(rocket, 166, 92)
  checkSelection(rocket, 6, 1, 166, 92)
  dragTo(rocket, 180, 92)
  checkSelection(rocket, 255, 0, 180, 92)
  local mahogany = openController(15, mapFacts({ key = "mahogany", mahogany = true }), worldFlags())
  dragTo(mahogany, 128, 92)
  checkSelection(mahogany, 7, 2, 128, 92)
  local silent = openController(16, mapFacts({ allowsRadio = false }), worldFlags())
  dragTo(silent, 112, 76)
  checkSelection(silent, 255, 0, 112, 76)
  dragTo(silent, 128, 92)
  checkSelection(silent, 255, 0, 128, 92)

  -- Presets snap through the fixed four-center table in order, starting
  -- from the third remembered button, and never filter to the active
  -- table: the fourth preset lands on empty air under Kanto.
  local presets = openController(17, mapFacts(), worldFlags())
  local presetTrail = {
    { x = 112, y = 76, station = 0, signal = 2 },
    { x = 152, y = 76, station = 1, signal = 2 },
    { x = 96, y = 108, station = 2, signal = 2 },
    { x = 136, y = 116, station = 3, signal = 2 },
    { x = 112, y = 76, station = 0, signal = 2 },
  }
  for _, preset in ipairs(presetTrail) do
    presets.controller:updateFixed({ { type = "confirm" } })
    checkSelection(presets, preset.station, preset.signal, preset.x, preset.y)
  end
  local shortTable = openController(18, mapFacts({ region = "kanto" }), worldFlags({ powerRestored = true }))
  shortTable.controller:updateFixed({ { type = "confirm" } })
  shortTable.controller:updateFixed({ { type = "confirm" } })
  shortTable.controller:updateFixed({ { type = "confirm" } })
  checkSelection(shortTable, 2, 2, 96, 108)
  shortTable.controller:updateFixed({ { type = "confirm" } })
  checkSelection(shortTable, 255, 0, 136, 116)

  -- Held keys move two source pixels per update with per-axis circle
  -- gating: motion stops at the tuning rim, each axis is checked
  -- separately with the updated horizontal position, and a blocked axis
  -- never drags the other one along.
  local walk = openController(19, mapFacts(), worldFlags())
  hold(walk, "right", 1)
  checkSelection(walk, 3, 1, 130, 128)
  hold(walk, "right", 40)
  checkSelection(walk, 255, 0, 165, 128)
  hold(walk, "up", 28)
  checkSelection(walk, 1, 1, 165, 72)
  hold(walk, "right", 10)
  checkSelection(walk, 255, 0, 175, 72)
  hold(walk, "right", 1)
  checkSelection(walk, 255, 0, 175, 72)
  hold(walk, "down", 14)
  checkSelection(walk, 255, 0, 175, 100)
  hold(walk, "right", 4)
  checkSelection(walk, 255, 0, 179, 100)
  hold(walk, "right", 1)
  checkSelection(walk, 255, 0, 179, 100)
  hold(walk, "down", 1)
  checkSelection(walk, 255, 0, 179, 102)

  -- Touch drags start only within eight source pixels of the cursor and
  -- follow only inside the tuning circle; anything else keeps the cursor.
  local touch = openController(20, mapFacts(), worldFlags())
  touch.controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = 136, y = 128 } })
  touch.controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = 136, y = 128 } })
  checkSelection(touch, 255, 0, 128, 128)
  dragTo(touch, 135, 128)
  checkSelection(touch, 3, 1, 135, 128)
  touch.controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = 135, y = 128 } })
  touch.controller:updateFixed({ { type = "pointer_move", pointerId = "touch:1", x = 200, y = 100 } })
  touch.controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = 200, y = 100 } })
  checkSelection(touch, 3, 1, 135, 128)

  -- Station lifecycle on a fresh tuner. The remembered cursor is not a
  -- playing station: nothing starts before input, and idle ticks tune
  -- nothing. A same-station signal change keeps the show and its audio
  -- while a changed station reopens, leaving every station closes the
  -- show with a stopped latch, cancel reports no close, and unloading
  -- persists the cursor.
  local live = openController(21, mapFacts(), worldFlags())
  local station, signal, cursor = selectionOf(live)
  Assert.equal(station, 255, "the remembered cursor starts tuned to no station")
  Assert.equal(signal, 0, "the remembered cursor starts with no signal")
  Assert.deepEqual({ x = cursor.x, y = cursor.y }, { x = 128, y = 128 }, "a fresh save remembers the dial center")
  Assert.isNil(live.program:status().show, "no show runs before input")
  Assert.equal(live.audio:playCallCount(), 0, "no audio starts before input")
  for _ = 1, 5 do
    live.controller:updateFixed({})
    live.program:updateFixed()
  end
  station = selectionOf(live)
  Assert.equal(station, 255, "idle ticks tune nothing")
  Assert.equal(live.audio:playCallCount(), 0, "idle ticks start no audio")

  live.controller:updateFixed({ { type = "confirm" } })
  checkSelection(live, 0, 2, 112, 76)
  Assert.equal(settleShow(live), "radio.music", "the first preset opens the music show")
  local playsBefore = live.audio:playCallCount()
  Assert.isTrue(playsBefore >= 1, "tuning the music show starts its audio")
  dragTo(live, 116, 76)
  checkSelection(live, 0, 1, 116, 76)
  Assert.equal(live.program:status().show, "radio.music", "a same-station signal change keeps the show")
  Assert.equal(live.audio:playCallCount(), playsBefore, "a same-station signal change never restarts the audio")
  dragTo(live, 112, 76)
  checkSelection(live, 0, 2, 112, 76)
  Assert.equal(live.program:status().show, "radio.music", "returning to clear keeps the same show")
  Assert.equal(live.audio:playCallCount(), playsBefore, "returning to clear restarts nothing")

  dragTo(live, 132, 76)
  checkSelection(live, 255, 0, 132, 76)
  Assert.isNil(live.program:status().show, "leaving every station closes the show")
  Assert.isNil(live.audio:currentRadioSequence(), "leaving every station clears the radio latch")
  Assert.isFalse(live.audio:radioIsPlaying(), "leaving every station stops playback")
  dragTo(live, 152, 76)
  checkSelection(live, 1, 2, 152, 76)
  Assert.equal(settleShow(live), "radio.talk", "the next station opens its own show")

  local latchBefore = live.audio:currentRadioSequence()
  local showBefore = live.program:status().show
  live.controller:updateFixed({ { type = "cancel" } })
  Assert.isNil(live.controller:takeResult(), "the back key returns focus without closing")
  Assert.equal(live.program:status().show, showBefore, "the back key keeps the running show")
  if latchBefore == nil then
    Assert.isNil(live.audio:currentRadioSequence(), "the back key keeps a clear latch clear")
  else
    Assert.equal(live.audio:currentRadioSequence(), latchBefore, "the back key keeps the audio latch")
  end

  dragTo(live, 96, 108)
  checkSelection(live, 2, 2, 96, 108)
  live.controller:dispose()
  Assert.deepEqual(
    live.state:readPreferences().radioCursor,
    { x = 96, y = 108 },
    "unloading persists the tuner position"
  )
end

function T.tests.radio_card_plays_its_source_tones()
  local effects = {}
  local function play(sequence)
    effects[#effects + 1] = sequence
  end
  local live = openController(31, mapFacts(), worldFlags(), play)
  live.controller:updateFixed({ { type = "cancel" } })
  Assert.equal(effects[#effects], "SEQ_SE_GS_GEARCANCEL", "the back key plays the cancel tone")
  Assert.isNil(live.controller:takeResult(), "the back key still closes nothing")
  live.controller:updateFixed({ { type = "confirm" } })
  Assert.equal(effects[#effects], "SEQ_SE_GS_GEARCURSOR", "stepping the preset plays the cursor tone")
  local walked = #effects
  live.controller:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(#effects, walked, "walking the dial plays no card tone")
  local cursor = live.controller:status().cursor
  live.controller:updateFixed(
    { { type = "pointer_down", pointerId = "t", x = cursor.x, y = cursor.y } }
  )
  Assert.equal(effects[#effects], "SEQ_SE_GS_GEARCURSOR", "touching the tuner plays the cursor tone")
  live.controller:updateFixed({ { type = "pointer_up", pointerId = "t", x = cursor.x, y = cursor.y } })
  Assert.equal(#effects, walked + 1, "releasing the drag plays nothing further")
  live.controller:dispose()
end

return T
