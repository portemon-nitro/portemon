-- Radio tuner edges, shared music effects, opportunity-rate staging, save
-- migration, and runtime queries: exact rim resolution order on every
-- channel table, diagonal key motion with X-before-Y rim gating, presets
-- through the fixed center table on short tables, mid-session story and
-- signal changes without new input, same-station static without audio
-- restarts, the closed sequence-to-effect mapping including paused and
-- finished playback, native-ordered rate arithmetic with method gates, and
-- legacy music migration that preserves every other fact. Coordinates,
-- radii, and rate expectations below are transcribed from the native radio
-- hitbox tables, the native encounter-rate stage, and fixed generator
-- vectors; nothing is read out of the modules under test.

local Assert = require("tests.support.Assert")
local EncounterFixture = require("libs.hgss.tests.encounter_fixture")
local BroadcastFixture = require("tests.support.PokegearBroadcastFixture")
local Music = require("game.hgss.src.pokegear.radio.Music")
local Special = require("game.hgss.src.pokegear.radio.Special")

local T = {
  metadata = {
    tags = { "pokegear" },
  },
  tests = {},
}

-- Loads a feature module that does not exist yet at this baseline. The
-- failure names the missing behaviour instead of surfacing as a suite load
-- error, so the red stays attributable.
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

---@return table encounter service over the synthetic vector catalog
local function vectorService()
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local ItemFixture = require("libs.items.tests.item_fixture")
  local Catalog = EncounterFixture.requirePresent(
    "libs.hgss.src.encounters.HgssEncounterCatalog",
    "validated encounter-table lookup owns ordered slots"
  )
  local Service = EncounterFixture.requirePresent(
    "libs.hgss.src.encounters.HgssEncounterService",
    "encounter opportunity and retained preparation"
  )
  local WildMonFactory = EncounterFixture.requirePresent(
    "libs.hgss.src.encounters.WildMonFactory",
    "source wild identity and held-item generation"
  )
  return Service.new({
    catalog = Catalog.new(EncounterFixture.vectorCatalog()),
    wildFactory = WildMonFactory.new({
      catalog = CatalogFixture.makeCatalog(),
      items = ItemFixture.makeCatalog(),
      charmap = CatalogFixture.CHARMAP,
      games = CatalogFixture.GAMES,
      languages = CatalogFixture.LANGUAGES,
      game = "soulsilver",
      language = "english",
    }),
  })
end

---@param seed integer
---@return table program, table audio, table state, table record
local function freshProgram(seed)
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearCalendar = require("game.hgss.src.pokegear.PokegearCalendar")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
  local FieldEventState = require("libs.hgss.src.field.FieldEventState")
  local RadioProgram = require("game.hgss.src.pokegear.RadioProgram")
  local RadioWorldContext = require("game.hgss.src.pokegear.RadioWorldContext")
  local validated = PokegearAssetSchema.validate(BroadcastFixture.fixtureManifest())
  Assert.notNil(validated, "the synthetic broadcast catalog must validate through the asset schema")
  local record = assert(validated, "scenario setup keeps the validated catalog")
  local refs = BroadcastFixture.catalogRefs(record)
  local state = PokegearState.new({ seed = seed }, refs)
  local calendar = PokegearCalendar.new(state)
  local random = PokegearRandom.new(seed, { trace = {}, traceLimit = 8192 })
  local events = FieldEventState.new()
  local world = RadioWorldContext.new({
    state = state,
    calendar = calendar,
    eventState = events,
    encounters = { swarm = false },
    dex = BroadcastFixture.newDexReader(false),
    bag = BroadcastFixture.newBagReader({}),
  })
  local civil = BroadcastFixture.newCivilCell({ year = 2024, month = 1, day = 8, hour = 10, minute = 0, second = 0 })
  local audio = BroadcastFixture.newAudioStandIn()
  local messages = BroadcastFixture.newMessageLog()
  local program = RadioProgram.new({
    catalog = record.catalog,
    world = world,
    clock = civil.clock,
    random = random,
    audio = audio,
    messages = messages,
  })
  return program, audio, state, record
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
---@param map table<string, unknown>
---@param flags table<string, unknown>
---@return table box with controller, program, audio, state
local function openController(seed, map, flags)
  local Reception = requireFeature(
    "game.hgss.src.pokegear.RadioReception",
    "radio channel selection has no ordered reception policy yet: no map can choose its source channel table"
  )
  local Controller = requireFeature(
    "game.hgss.src.pokegear.RadioController",
    "radio tuning has no input owner yet: cursor motion, presets, drags, and station changes do nothing"
  )
  local program, audio, state, record = freshProgram(seed)
  local controller = Controller.new({
    state = state,
    catalog = record.catalog,
    program = program,
    reception = Reception,
    presentation = stubPresentation(),
    map = map,
    flags = flags,
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

function T.tests.tuned_music_tracks_resolve_their_gameplay_effect()
  local Effects = requireFeature(
    "game.hgss.src.pokegear.PokegearRadioEffects",
    "live broadcast music has no shared sequence-to-effect mapping yet: encounters cannot hear any tuned track"
  )
  Assert.equal(Effects.fromSequence(Music.MARCH_SEQUENCE), "march", "the march latch plays the march effect")
  Assert.equal(Effects.fromSequence(Music.LULLABY_SEQUENCE), "lullaby", "the lullaby latch plays the lullaby effect")
  Assert.equal(Effects.fromSequence(Music.HOENN_SEQUENCE), "hoenn", "the hoenn latch plays the hoenn effect")
  Assert.equal(Effects.fromSequence(Music.SINNOH_SEQUENCE), "sinnoh", "the sinnoh latch plays the sinnoh effect")
  Assert.equal(
    Effects.fromSequence(assert(Special.FLUTE_SEQUENCE, "the flute broadcast names its sequence")),
    "pokeflute",
    "the flute latch plays the flute effect"
  )
  Assert.equal(
    Effects.fromSequence(assert(Special.UNOWN_SEQUENCE, "the unown broadcast names its sequence")),
    "unown",
    "the unown latch plays the unown effect"
  )
  Assert.equal(Effects.fromSequence(Music.MARCH_SEQUENCE), "march", "effect reads are pure across calls")
end

function T.tests.gameboy_card_tracks_replay_their_counterpart_effects()
  local Effects = requireFeature(
    "game.hgss.src.pokegear.PokegearRadioEffects",
    "live broadcast music has no shared sequence-to-effect mapping yet: card tracks answer nothing"
  )
  Assert.equal(Effects.fromSequence("radio.music.card.21"), "march", "the twenty-first card replays march")
  Assert.equal(Effects.fromSequence("radio.music.card.22"), "lullaby", "the twenty-second card replays lullaby")
  for _, card in ipairs({ "radio.music.card.01", "radio.music.card.03", "radio.music.card.25" }) do
    Assert.equal(Effects.fromSequence(card), "none", card .. " carries no gameplay effect")
  end
end

function T.tests.unknown_and_missing_latches_read_as_no_effect()
  local Effects = requireFeature(
    "game.hgss.src.pokegear.PokegearRadioEffects",
    "live broadcast music has no shared sequence-to-effect mapping yet: silence has no answer"
  )
  Assert.equal(Effects.fromSequence(Music.JINGLE_SEQUENCE), "none", "the tune-in jingle plays no effect")
  Assert.equal(Effects.fromSequence(nil), "none", "an absent latch plays no effect")
  Assert.equal(Effects.fromSequence("radio.music.unknown-track"), "none", "an unknown latch plays no effect")
  Assert.equal(Effects.fromSequence(42), "none", "a numeric latch outside the semantic vocabulary plays no effect")
end

function T.tests.paused_and_finished_playback_keeps_the_latched_effect()
  local Effects = requireFeature(
    "game.hgss.src.pokegear.PokegearRadioEffects",
    "live broadcast music has no shared sequence-to-effect mapping yet: paused tracks answer nothing"
  )
  local audio = BroadcastFixture.newAudioStandIn()
  audio:playRadio(Music.MARCH_SEQUENCE)
  Assert.equal(Effects.fromSequence(audio:currentRadioSequence()), "march", "the playing latch reads march")
  audio:pauseRadio()
  Assert.isFalse(audio:radioIsPlaying(), "pausing silences playback")
  Assert.equal(Effects.fromSequence(audio:currentRadioSequence()), "march", "a paused latch keeps its effect")
  audio:resumeRadio()
  Assert.equal(Effects.fromSequence(audio:currentRadioSequence()), "march", "resuming keeps the effect")
  audio:complete()
  Assert.isFalse(audio:radioIsPlaying(), "a finished handle goes silent")
  Assert.equal(Effects.fromSequence(audio:currentRadioSequence()), "march", "a finished latch keeps its effect")
  audio:playRadio(Music.JINGLE_SEQUENCE)
  Assert.equal(Effects.fromSequence(audio:currentRadioSequence()), "none", "the jingle latch reads no effect")
  audio:stopRadio()
  Assert.isNil(audio:currentRadioSequence(), "stopping clears the audio latch")
  Assert.equal(Effects.fromSequence(audio:currentRadioSequence()), "none", "a stopped tuner reads no effect")
end

function T.tests.step_boost_thresholds_follow_the_native_count()
  local Rate = requireFeature(
    "libs.hgss.src.encounters.HgssEncounterRate",
    "the encounter opportunity has no transcribed rate-stage policy yet: step counts change no rate"
  )
  local function movement(overrides)
    local facts = { locomotion = "walk", veryTallGrass = false, radio = "none" }
    for key, value in pairs(overrides or {}) do
      facts[key] = value
    end
    return Rate.movementRate(facts)
  end
  Assert.equal(movement(), 20, "walking paces the native movement roll at twenty")
  Assert.equal(movement({ locomotion = "run" }), 40, "running skips the walking reduction")
  Assert.equal(movement({ locomotion = "cycle" }), 70, "cycling adds thirty to the base forty")
  Assert.equal(movement({ locomotion = "surf" }), 40, "surfing paces the base forty")
  Assert.equal(movement({ veryTallGrass = true }), 60, "very tall grass adds forty on foot")
  Assert.equal(movement({ locomotion = "run", veryTallGrass = true }), 80, "very tall grass adds forty running")
  Assert.equal(
    movement({ locomotion = "cycle", veryTallGrass = true }),
    80,
    "very tall grass replaces the cycling bonus"
  )
  local cases = {
    { steps = 0, want = 20 },
    { steps = 1, want = 20 },
    { steps = 2, want = 50 },
    { steps = 3, want = 60 },
    { steps = 4, want = 80 },
    { steps = 9, want = 80 },
  }
  for _, case in ipairs(cases) do
    Assert.equal(
      movement({ reverseTurnSteps = case.steps }),
      case.want,
      "walking with " .. case.steps .. " reverse-turn steps stages " .. case.want
    )
  end
end

function T.tests.music_shifts_movement_rates_by_twenty_five_points_before_the_cap()
  local Rate = requireFeature(
    "libs.hgss.src.encounters.HgssEncounterRate",
    "the encounter opportunity has no transcribed rate-stage policy yet: march and lullaby change no rate"
  )
  local function movement(overrides)
    local facts = { locomotion = "walk", veryTallGrass = false, radio = "none" }
    for key, value in pairs(overrides or {}) do
      facts[key] = value
    end
    return Rate.movementRate(facts)
  end
  Assert.equal(
    movement({ radio = "march" }),
    45,
    "march raises the walking movement rate by twenty-five points"
  )
  Assert.equal(
    movement({ radio = "lullaby" }),
    100,
    "lullaby overflows the walking movement rate onto the cap (native unsigned wrap)"
  )
  Assert.equal(
    movement({ locomotion = "run", radio = "march" }),
    65,
    "march raises the running movement rate by twenty-five points"
  )
  Assert.equal(
    movement({ locomotion = "surf", radio = "lullaby" }),
    15,
    "lullaby lowers the surfing movement rate by twenty-five points"
  )
  Assert.equal(
    movement({ locomotion = "cycle", radio = "march", reverseTurnSteps = 4 }),
    100,
    "the movement rate caps at one hundred"
  )
  Assert.equal(
    movement({ radio = "lullaby", reverseTurnSteps = 4 }),
    55,
    "turn steps apply before the music"
  )
end

function T.tests.music_never_reaches_fishing_or_rock_smash_attempts()
  -- The movement stage only paces land and water steps: fishing and rock
  -- smash attempts never draw a movement roll, so live music leaves
  -- their kind, reason, draw count, and mon identical to silence.
  local host = vectorService()
  local function signature(result, draws)
    local parts = { result.kind, tostring(result.reason), "draws" .. draws }
    if result.encounter ~= nil then
      local mon = result.encounter.mons[1].mon
      parts[#parts + 1] = tostring(mon.species)
      parts[#parts + 1] = "lv" .. tostring(mon.met.level)
    end
    return table.concat(parts, "/")
  end
  local function attempt(method, movement, mapId, modifiers, seed)
    local context = EncounterFixture.context({ mapId = mapId, method = method, movement = movement })
    context.modifiers = modifiers
    local stream = EncounterFixture.spyStream(seed)
    return signature(host:attempt(context, stream), stream:calls())
  end
  for _, seed in ipairs({ 0, 1, 3 }) do
    local silentFish = attempt(
      "fish",
      "fish",
      14,
      EncounterFixture.modifiers({ rod = "old_rod", radio = "none" }),
      seed
    )
    local silentRock = attempt(
      "rock_smash",
      "field_move",
      15,
      EncounterFixture.modifiers({ radio = "none" }),
      seed
    )
    for _, radio in ipairs({ "march", "lullaby" }) do
      Assert.equal(
        attempt("fish", "fish", 14, EncounterFixture.modifiers({ rod = "old_rod", radio = radio }), seed),
        silentFish,
        radio .. " leaves the fishing attempt untouched on seed " .. seed
      )
      Assert.equal(
        attempt("rock_smash", "field_move", 15, EncounterFixture.modifiers({ radio = radio }), seed),
        silentRock,
        radio .. " leaves the rock smash attempt untouched on seed " .. seed
      )
    end
  end
end

function T.tests.rate_facts_reject_malformed_input_and_stay_immutable()
  local Errors = require("libs.errors.src.Errors")
  local Rate = requireFeature(
    "libs.hgss.src.encounters.HgssEncounterRate",
    "the encounter opportunity has no transcribed rate-stage policy yet: fact validation is unowned"
  )
  local badFacts = {
    { veryTallGrass = false, radio = "none" },
    { locomotion = "swim", veryTallGrass = false, radio = "none" },
    { locomotion = "walk", veryTallGrass = false },
    { locomotion = "walk", veryTallGrass = "sometimes", radio = "none" },
    { locomotion = "walk", veryTallGrass = false, radio = "unova" },
    { locomotion = "walk", veryTallGrass = false, radio = "hoenn" },
    { locomotion = "walk", veryTallGrass = false, radio = "none", reverseTurnSteps = -1 },
    { locomotion = "walk", veryTallGrass = false, radio = "none", reverseTurnSteps = 2.5 },
  }
  for _, facts in ipairs(badFacts) do
    local err = Assert.throws(function()
      Rate.movementRate(facts)
    end, "malformed movement facts must fail")
    Assert.isTrue(Errors.is(err), "the rejection uses the structured error path")
    Assert.equal(assert(err).code, "ENCOUNTER_INVALID_INPUT", "the rejection names its contract")
  end
  local facts = { locomotion = "run", veryTallGrass = false, radio = "march", reverseTurnSteps = 2 }
  local first = Rate.movementRate(facts)
  Assert.equal(first, 95, "running with two reverse-turn steps under march stages ninety-five")
  Assert.deepEqual(
    facts,
    { locomotion = "run", veryTallGrass = false, radio = "march", reverseTurnSteps = 2 },
    "staging a rate never mutates its facts"
  )
  Assert.equal(Rate.movementRate(facts), first, "rate reads are pure across calls")
end

function T.tests.radio_stages_movement_while_intimidate_suppresses_selection()
  requireFeature(
    "libs.hgss.src.encounters.HgssEncounterRate",
    "the encounter opportunity has no transcribed rate-stage policy yet: modifier order is unowned"
  )
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local host = vectorService()
  EncounterFixture.pastGrace(host)
  local _ = CatalogFixture
  local lead = EncounterFixture.mon("TOTODILE", 10, 11)
  -- Silence refuses seed 1 at the movement roll (38 against the walking
  -- twenty) after a single draw, before intimidate ever stages.
  local silent = EncounterFixture.context({ mapId = 13, method = "grass", lead = lead })
  silent.modifiers = EncounterFixture.modifiers({ radio = "none", leadAbility = "intimidate" })
  local silentStream = EncounterFixture.spyStream(1)
  local silentResult = host:attempt(silent, silentStream)
  Assert.equal(silentResult.kind, "none", "silence misses seed 1 at the movement roll")
  Assert.equal(silentResult.reason, "no_opportunity", "the miss names its stage")
  Assert.equal(silentStream:calls(), 1, "a missed movement roll draws once")
  -- March paces the movement roll while the table rate stays whole:
  -- seed 1 passes movement (38 under forty-five) then misses the full
  -- table rate of 30 (roll 65) after two draws, never reaching the
  -- suppression check.
  local context = EncounterFixture.context({ mapId = 13, method = "grass", lead = lead })
  context.modifiers = EncounterFixture.modifiers({ radio = "march", leadAbility = "intimidate" })
  local stream = EncounterFixture.spyStream(1)
  local result = host:attempt(context, stream)
  Assert.equal(result.kind, "none", "march under intimidate misses seed 1 at the table roll")
  Assert.equal(result.reason, "no_opportunity", "the miss names its stage")
  Assert.equal(stream:calls(), 2, "a missed table roll draws twice")
  Assert.deepEqual(stream:labels(), { "movement", "opportunity" })
end

function T.tests.tuning_rims_prefer_clear_then_weak_then_silence()
  requireFeature(
    "game.hgss.src.pokegear.RadioReception",
    "radio channel selection has no ordered reception policy yet: rim points resolve nothing"
  )
  requireFeature(
    "game.hgss.src.pokegear.RadioController",
    "radio tuning has no input owner yet: rim points resolve nothing"
  )
  local johto = openController(31, mapFacts(), worldFlags())
  local rimPoints = {
    { x = 109, y = 76, station = 0, signal = 2 },
    { x = 108, y = 76, station = 0, signal = 1 },
    { x = 96, y = 123, station = 2, signal = 1 },
    { x = 96, y = 124, station = 255, signal = 0 },
  }
  for _, point in ipairs(rimPoints) do
    dragTo(johto, point.x, point.y)
    checkSelection(johto, point.station, point.signal, point.x, point.y)
  end
  local rocket = openController(32, mapFacts(), worldFlags({ rocketTakeover = true }))
  dragTo(rocket, 165, 92)
  checkSelection(rocket, 6, 2, 165, 92)
  dragTo(rocket, 167, 92)
  checkSelection(rocket, 6, 1, 167, 92)
  local alph = openController(33, mapFacts({ alph = true }), worldFlags())
  dragTo(alph, 131, 92)
  checkSelection(alph, 5, 2, 131, 92)
  dragTo(alph, 144, 92)
  checkSelection(alph, 255, 0, 144, 92)
  local expn =
    openController(34, mapFacts({ region = "kanto" }), worldFlags({ powerRestored = true, kantoExpansion = true }))
  dragTo(expn, 128, 51)
  checkSelection(expn, 4, 2, 128, 51)
end

function T.tests.diagonal_keys_move_x_first_with_independent_rim_gating()
  requireFeature(
    "game.hgss.src.pokegear.RadioController",
    "radio tuning has no input owner yet: diagonal keys move nothing"
  )
  local walk = openController(35, mapFacts(), worldFlags())
  -- A blocked horizontal axis never drags the free vertical one along: the
  -- cursor slides down the rim instead.
  dragTo(walk, 179, 100)
  checkSelection(walk, 255, 0, 179, 100)
  walk.controller:updateFixed({ { type = "navigate", direction = "up-right" } })
  checkSelection(walk, 255, 0, 179, 98)
  -- X moves before Y with the vertical check reading the updated
  -- horizontal position: this corner rounds differently than Y-first would.
  dragTo(walk, 77, 101)
  checkSelection(walk, 255, 0, 77, 101)
  walk.controller:updateFixed({ { type = "navigate", direction = "down-right" } })
  checkSelection(walk, 255, 0, 79, 103)
end

function T.tests.presets_snap_through_the_fixed_table_on_short_tables()
  requireFeature("game.hgss.src.pokegear.RadioController", "radio tuning has no input owner yet: presets snap nothing")
  local alph = openController(36, mapFacts({ alph = true }), worldFlags())
  alph.controller:updateFixed({ { type = "confirm" } })
  checkSelection(alph, 255, 0, 112, 76)
  alph.controller:updateFixed({ { type = "confirm" } })
  checkSelection(alph, 255, 0, 152, 76)
end

function T.tests.story_and_signal_changes_recompute_without_new_input()
  requireFeature(
    "game.hgss.src.pokegear.RadioController",
    "radio tuning has no input owner yet: mid-session changes recompute nothing"
  )
  local flags = worldFlags()
  local box = openController(37, mapFacts(), flags)
  dragTo(box, 152, 76)
  checkSelection(box, 1, 2, 152, 76)
  for _ = 1, 60 do
    box.controller:updateFixed({})
    box.program:updateFixed()
  end
  Assert.equal(box.program:status().show, "radio.talk", "the talk show runs before the story change")
  flags.rocketTakeover = true
  box.controller:updateFixed({})
  checkSelection(box, 6, 2, 152, 76)
  flags.rocketTakeover = false
  box.controller:updateFixed({})
  checkSelection(box, 1, 2, 152, 76)
  -- Losing reception mid-session tears down without new input: a map that
  -- forbids radio tunes nothing and latches nothing from a fresh open.
  local silent = openController(38, mapFacts({ allowsRadio = false }), worldFlags())
  dragTo(silent, 152, 76)
  checkSelection(silent, 255, 0, 152, 76)
  Assert.isNil(silent.program:status().show, "a map without reception tunes no show")
  Assert.isNil(silent.audio:currentRadioSequence(), "a map without reception latches nothing")
end

function T.tests.weak_to_weak_moves_keep_the_running_show_and_audio()
  requireFeature(
    "game.hgss.src.pokegear.RadioController",
    "radio tuning has no input owner yet: same-station moves restart nothing"
  )
  local box = openController(39, mapFacts(), worldFlags())
  box.controller:updateFixed({ { type = "confirm" } })
  checkSelection(box, 0, 2, 112, 76)
  for _ = 1, 60 do
    box.controller:updateFixed({})
    box.program:updateFixed()
  end
  Assert.equal(box.program:status().show, "radio.music", "the music show runs before the weak move")
  local playsBefore = box.audio:playCallCount()
  Assert.isTrue(playsBefore >= 1, "tuning the music show starts its audio")
  dragTo(box, 116, 76)
  checkSelection(box, 0, 1, 116, 76)
  dragTo(box, 117, 76)
  checkSelection(box, 0, 1, 117, 76)
  Assert.equal(box.program:status().show, "radio.music", "weak-to-weak moves keep the show")
  Assert.equal(box.audio:playCallCount(), playsBefore, "weak-to-weak moves never restart the audio")
end

function T.tests.new_capture_omits_the_obsolete_music_key()
  local EncounterSave = EncounterFixture.requirePresent(
    "libs.hgss.src.save.EncounterSave",
    "semantic encounter persistence owns the versioned bucket"
  )
  local RoamerState = EncounterFixture.requirePresent(
    "libs.hgss.src.encounters.HgssRoamerState",
    "stable roaming state owns persisted counters and roamer records"
  )
  local refs = EncounterFixture.refs()
  local legacy = {
    schema = "hgss-encounter-v1",
    stateVersion = 1,
    steps = 7,
    repelSteps = 3,
    swarm = true,
    radio = "hoenn",
    roamers = {
      raikou = {
        key = "raikou",
        stateVersion = 1,
        mon = { species = "EEVEE" },
        location = 11,
        lifecycle = "roaming",
        revision = 3,
      },
    },
  }
  local migrated = EncounterSave.capture(RoamerState.restore(legacy, refs))
  Assert.isNil(rawget(migrated, "radio"), "new captures omit the obsolete music key entirely")
  Assert.equal(migrated.stateVersion, EncounterSave.STATE_VERSION, "migration lands on the current version")
  Assert.equal(migrated.steps, 7, "migration preserves the step counter")
  Assert.equal(migrated.repelSteps, 3, "migration preserves the repel counter")
  Assert.equal(migrated.swarm, true, "migration preserves the swarm fact")
end

function T.tests.legacy_music_values_migrate_to_silence_without_authority()
  local EncounterSave = EncounterFixture.requirePresent(
    "libs.hgss.src.save.EncounterSave",
    "semantic encounter persistence owns the versioned bucket"
  )
  local Catalog = EncounterFixture.requirePresent(
    "libs.hgss.src.encounters.HgssEncounterCatalog",
    "validated encounter-table lookup owns ordered slots"
  )
  local refs = EncounterFixture.refs()
  for _, music in ipairs({ "hoenn", "sinnoh", "march" }) do
    local bucket = {
      schema = "hgss-encounter-v1",
      stateVersion = 1,
      steps = 0,
      repelSteps = 0,
      swarm = false,
      radio = music,
      roamers = {},
    }
    local valid = EncounterSave.validate(bucket, refs)
    Assert.equal(valid.radio, "none", "legacy music " .. music .. " migrates to silence")
  end
  local catalog = Catalog.new(EncounterFixture.vectorCatalog())
  local migrated = EncounterSave.validate({
    schema = "hgss-encounter-v1",
    stateVersion = 1,
    steps = 0,
    repelSteps = 0,
    swarm = false,
    radio = "hoenn",
    roamers = {},
  }, refs)
  local quiet = catalog:tableFor(11, { timeOfDay = "day", swarm = false, radio = migrated.radio, game = "soulsilver" })
  local silent = catalog:tableFor(11, { timeOfDay = "day", swarm = false, radio = "none", game = "soulsilver" })
  for slot = 1, 12 do
    Assert.equal(
      quiet.day[slot].species,
      silent.day[slot].species,
      "the migrated value reads exactly like silence in slot " .. slot
    )
  end
end

function T.tests.malformed_legacy_music_types_fail_instead_of_defaulting()
  local Errors = require("libs.errors.src.Errors")
  local EncounterSave = EncounterFixture.requirePresent(
    "libs.hgss.src.save.EncounterSave",
    "semantic encounter persistence owns the versioned bucket"
  )
  local refs = EncounterFixture.refs()
  for _, music in ipairs({ "", {} }) do
    local err = Assert.throws(function()
      EncounterSave.validate({
        schema = "hgss-encounter-v1",
        stateVersion = 1,
        steps = 0,
        repelSteps = 0,
        swarm = false,
        radio = music,
        roamers = {},
      }, refs)
    end, "a malformed legacy music value must fail")
    Assert.isTrue(Errors.is(err), "the rejection uses the structured error path")
    Assert.equal(assert(err).code, "ENCOUNTER_SAVE_INVALID", "the rejection names its contract")
  end
end

function T.tests.legacy_cold_load_starts_silent_at_the_dial_center()
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local EncounterSave = EncounterFixture.requirePresent(
    "libs.hgss.src.save.EncounterSave",
    "semantic encounter persistence owns the versioned bucket"
  )
  local RoamerState = EncounterFixture.requirePresent(
    "libs.hgss.src.encounters.HgssRoamerState",
    "stable roaming state owns persisted counters and roamer records"
  )
  local refs = EncounterFixture.refs()
  local initial = EncounterSave.initial()
  Assert.equal(initial.radio, "none", "the defined initial state carries no music")
  local state = RoamerState.restore(initial, refs)
  Assert.isNil(rawget(EncounterSave.capture(state), "radio"), "an empty capture carries no music key")
  local manifest = BroadcastFixture.fixtureManifest()
  local validated = PokegearAssetSchema.validate(manifest)
  Assert.notNil(validated, "the synthetic companion catalog must validate through the asset schema")
  local gear = PokegearState.new({ seed = 9 }, BroadcastFixture.catalogRefs(assert(validated, "catalog reads above")))
  Assert.deepEqual(
    gear:readPreferences().radioCursor,
    { x = 128, y = 128 },
    "a fresh tuner remembers the dial center, never a station"
  )
end

function T.tests.runtime_music_query_reads_the_audio_latch()
  local FieldRuntime = requireFeature(
    "game.hgss.src.field.FieldRuntime",
    "the field runtime has no radio music query yet: scripts cannot read the latch"
  )
  local function runtimeWith(latch)
    local audio = {
      latch = latch,
      currentRadioSequence = function(self)
        return self.latch
      end,
      radioIsPlaying = function(self)
        return self.latch ~= nil
      end,
    }
    return setmetatable({ audio = audio }, FieldRuntime)
  end
  local live = runtimeWith(Music.MARCH_SEQUENCE)
  Assert.isTrue(live:radioMusicIs("march"), "the query answers true while march is latched")
  Assert.isFalse(live:radioMusicIs("lullaby"), "the comparison is exact: other music answers false")
  local quiet = runtimeWith(nil)
  Assert.isFalse(quiet:radioMusicIs("march"), "a clear latch answers false")
  Assert.isTrue(quiet:radioMusicIs("none"), "a clear latch answers no effect")
  local headless = setmetatable({}, FieldRuntime)
  Assert.isFalse(headless:radioMusicIs("march"), "no audio reads as no effect")
  Assert.isTrue(headless:radioMusicIs("none"), "no audio answers no effect")
end

function T.tests.step_swarm_reads_the_encounter_owner_and_shared_seed()
  requireFeature(
    "game.hgss.src.field.FieldRuntime",
    "the field runtime has no outbreak composition yet: steps never swarm"
  )
  local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local RoamerState = EncounterFixture.requirePresent(
    "libs.hgss.src.encounters.HgssRoamerState",
    "stable roaming state owns persisted counters and roamer records"
  )
  local refs = EncounterFixture.refs()
  local manifest = BroadcastFixture.fixtureManifest()
  local validated = PokegearAssetSchema.validate(manifest)
  Assert.notNil(validated, "the synthetic companion catalog must validate through the asset schema")
  local gear = PokegearState.new({ seed = 5 }, BroadcastFixture.catalogRefs(assert(validated, "catalog reads above")))
  local swarming = RoamerState.new({ records = {}, species = refs.species, maps = refs.maps, swarm = true })
  local runtime = setmetatable({ roamerState = swarming, pokegearState = gear }, FieldRuntime)
  Assert.isTrue(runtime:_stepSwarmActive(), "an active outbreak with a shared seed swarms the step")
  local calm = RoamerState.new({ records = {}, species = refs.species, maps = refs.maps, swarm = false })
  local calmRuntime = setmetatable({ roamerState = calm, pokegearState = gear }, FieldRuntime)
  Assert.isFalse(calmRuntime:_stepSwarmActive(), "an inactive outbreak never swarms the step")
  local stateless = setmetatable({ roamerState = swarming }, FieldRuntime)
  Assert.isFalse(stateless:_stepSwarmActive(), "a missing companion identity never swarms the step")
end

return T
