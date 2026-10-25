-- Broadcast source fidelity against the owned dump: the compiled pokegear
-- family carries all twelve native program lifecycles, music selects exact
-- weekday tracks behind the national-dex and card unlocks with jingle
-- completion gating the music start, and every native show runs a real
-- setup/print/teardown vector with source message references, draw order,
-- effect writes, and commercial return. Track and message identities are
-- asserted as semantic keys and numeric bank/entry references, never as
-- copied broadcast prose or raw dump bytes. A missing dump reports a skip,
-- never a pass, through the declared dump capability.

local Assert = require("tests.support.Assert")
local RomSuite = require("tests.rom.support.RomSuite")
local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
local PokegearState = require("libs.hgss.src.save.PokegearState")
local PokegearCalendar = require("game.hgss.src.pokegear.PokegearCalendar")
local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local EncounterSave = require("libs.hgss.src.save.EncounterSave")
local Fixture = require("tests.support.PokegearBroadcastFixture")

local T = {}

local COMMERCIAL_KEY = "radio.commercial"
local MUSIC_KEY = "radio.music"
local MONDAY_BASE = { year = 2024, month = 1, day = 1, hour = 10, minute = 0, second = 0 }

-- Source message identities for the password broadcast: the spoken
-- password token lives in field bank 66 at entry 40 plus the password-set
-- variable modulo 30, and the card-gated reply uses bank 411 entries 4/5.
local PASSWORD_TOKEN_BANK = 66
local PASSWORD_TOKEN_BASE = 40
local BUENA_REPLY_BANK = 411
local BUENA_REPLY_WITH_CARD = 4
local BUENA_REPLY_WITHOUT_CARD = 5

---@param romFs table<string, unknown>
---@param versionId string
---@return table<string, unknown>
local function compileCatalog(romFs, versionId)
  local loaded, PokegearAssetCompiler = pcall(require, "romdump.src.digest.ui.PokegearAssetCompiler")
  Assert.isTrue(loaded, "the pokegear family compiler must be published before the broadcast closure can be proven")
  assert(type(PokegearAssetCompiler) == "table", "the family compiler loads above")
  local bundle = PokegearAssetCompiler.compile(romFs, versionId)
  local compiled = assert(bundle, versionId .. " must compile the pokegear family")
  local manifest = assert(compiled.manifest, versionId .. " must publish its pokegear manifest")
  Assert.notNil(PokegearAssetSchema.validate(manifest), versionId .. " publishes a schema-valid broadcast catalog")
  local catalog = assert(manifest.catalog, versionId .. " publishes its broadcast catalog")
  return catalog --[[@as table<string, unknown>]]
end

---@param catalog table<string, unknown>
local function checkTwelveShowClosure(catalog)
  assert(type(catalog) == "table" and type(catalog.shows) == "table", "the broadcast catalog carries its show table")
  local shows = catalog.shows
  assert(type(shows) == "table", "the show table reads above")
  Assert.equal(#shows, 12, "the compiled family carries all twelve native broadcast programs")
  local keys = {}
  for _, show in ipairs(shows) do
    keys[show.key] = true
  end
  for _, key in ipairs(Fixture.SHOW_KEY_LIST) do
    Assert.isTrue(keys[key] == true, "the compiled family covers broadcast program " .. key)
  end
end

---@param catalog table<string, unknown>
---@param opts table<string, unknown>
---@return table<string, unknown> program, table<string, unknown> audio, table<string, unknown> messages, table<string, unknown> world, table<string, unknown> events, { cell: { now: table<string, integer> }, clock: LocalClock }
local function freshProgram(catalog, opts)
  local seed = assert(opts.seed, "broadcast scenarios start from an explicit seed")
  assert(type(seed) == "number", "broadcast seeds stay unsigned integers")
  local state = PokegearState.new({ seed = seed }, { catalog = catalog })
  local calendar = PokegearCalendar.new(state)
  local random = PokegearRandom.new(seed, { trace = {}, traceLimit = 8192 })
  local events = FieldEventState.new()
  if opts.passwordVar ~= nil then
    assert(type(opts.passwordVar) == "number", "the password fact stays numeric")
    events:setVar(FieldScriptSymbols.variablesByName.VAR_BUENAS_PASSWORD_SET, opts.passwordVar)
  end
  local RadioWorldContext = Fixture.requireFeature(
    "game.hgss.src.pokegear.RadioWorldContext",
    "broadcast world facts have no shared projection yet: programs cannot read dex, card, swarm, or password facts"
  )
  local encounters = EncounterSave.restore(nil, { species = {}, maps = {} })
  if opts.swarmActive == true then
    local bucket = EncounterSave.initial()
    bucket.swarm = true
    encounters = EncounterSave.restore(bucket, { species = {}, maps = {} })
  end
  local world = RadioWorldContext.new({
    state = state,
    calendar = calendar,
    eventState = events,
    encounters = encounters,
    dex = Fixture.newDexReader(opts.nationalDex == true),
    bag = Fixture.newBagReader(opts.blueCard == true and { BLUE_CARD = true } or {}),
  })
  local civil = Fixture.newCivilCell(opts.moment or MONDAY_BASE)
  local audio = Fixture.newAudioStandIn()
  local messages = Fixture.newMessageLog()
  local RadioProgram = Fixture.requireFeature(
    "game.hgss.src.pokegear.RadioProgram",
    "broadcast programs have no dispatcher yet: no tuned station can start a native show"
  )
  local program = RadioProgram.new({
    catalog = catalog,
    world = world,
    clock = civil.clock,
    random = random,
    audio = audio,
    messages = messages,
  })
  return program, audio, messages, world, events, civil
end

-- Advances until the audio stand-in records its nth start call, proving the
-- program waited on facade completion rather than a hardcoded duration.
---@param program table<string, unknown>
---@param audio table<string, unknown>
---@param count integer
---@param budget integer
---@param what string
local function pollPlayCalls(program, audio, count, budget, what)
  for _ = 1, budget do
    program:updateFixed()
    if audio:playCallCount() >= count then
      return
    end
  end
  error("broadcast audio never reached " .. what, 0)
end

-- Tunes one station and waits out any scheduled commercial interruption so
-- vector assertions always observe the tuned station's own show.
---@param program table<string, unknown>
---@param station integer
---@param signal string
---@return string show, integer commercials
local function tuneSettled(program, station, signal)
  local commercials = 0
  program:begin(station, signal)
  for _ = 1, 1500 do
    program:updateFixed()
    local status = program:status()
    if status.show == COMMERCIAL_KEY then
      commercials = commercials + 1
    else
      return status.show, commercials
    end
  end
  error("tuning never settled back to its station show", 0)
end

---@param dayOffset integer
---@return table<string, integer>
local function matrixMoment(dayOffset)
  return {
    year = MONDAY_BASE.year,
    month = MONDAY_BASE.month,
    day = MONDAY_BASE.day + dayOffset,
    hour = MONDAY_BASE.hour,
    minute = MONDAY_BASE.minute,
    second = MONDAY_BASE.second,
  }
end

-- Runs the music program from tune-in through its first actual music start
-- for one weekday/unlock combination and returns the latched music key.
---@param catalog table<string, unknown>
---@param dayOffset integer
---@param nationalDex boolean
---@param blueCard boolean
---@param seed integer
---@return integer|string
local function startMusic(catalog, dayOffset, nationalDex, blueCard, seed)
  local program, audio, messages, _, _, _ = freshProgram(catalog, {
    seed = seed,
    nationalDex = nationalDex,
    blueCard = blueCard,
    moment = matrixMoment(dayOffset),
  })
  program:begin(0, "clear")
  pollPlayCalls(program, audio, 1, 400, "the tune-in jingle")
  Assert.isTrue(messages:requestCount() >= 1, "the intro prints before any music starts")
  for _ = 1, 200 do
    program:updateFixed()
  end
  Assert.equal(audio:playCallCount(), 1, "the music start waits on jingle completion instead of a hardcoded duration")
  audio:complete()
  pollPlayCalls(program, audio, 2, 800, "the first actual music start")
  local latch = audio:currentRadioSequence()
  Assert.notNil(latch, "the first music start latches its sequence")
  Assert.isTrue(audio:radioIsPlaying(), "the latched music is playing after its start")
  program:endProgram()
  program:dispose()
  return assert(latch, "the music latch reads above")
end

function T.broadcast_music_selects_weekday_tracks_behind_dex_and_card_unlocks(romFs, versionId)
  Fixture.requireFeature(
    "game.hgss.src.pokegear.RadioProgram",
    "broadcast programs have no dispatcher yet: the music weekday matrix cannot start"
  )
  local catalog = compileCatalog(romFs, versionId)
  checkTwelveShowClosure(catalog)

  Assert.equal(
    PokegearCalendar.weekday({ year = 2024, month = 1, day = 1, hour = 10, minute = 0, second = 0 }),
    0,
    "the weekday matrix anchors on Monday 2024-01-01"
  )

  local track = {}
  local seedBase = 50000
  for dayOffset = 0, 6 do
    track[dayOffset] = {}
    for _, nationalDex in ipairs({ false, true }) do
      for _, blueCard in ipairs({ false, true }) do
        local seed = seedBase + dayOffset * 4 + (nationalDex and 2 or 0) + (blueCard and 1 or 0)
        track[dayOffset][tostring(nationalDex) .. tostring(blueCard)] =
          startMusic(catalog, dayOffset, nationalDex, blueCard, seed)
      end
    end
  end
  local function key(dayOffset, nationalDex, blueCard)
    return track[dayOffset][tostring(nationalDex) .. tostring(blueCard)]
  end

  -- Weekday identities: Monday and Friday share March, Tuesday and
  -- Saturday share Lullaby, ungated midweek days fall back to those same
  -- tracks, and Sunday without the card falls back to March.
  Assert.equal(key(0, false, false), key(4, false, false), "Monday and Friday share the March track")
  Assert.equal(key(1, false, false), key(5, false, false), "Tuesday and Saturday share the Lullaby track")
  Assert.equal(key(2, false, false), key(0, false, false), "Wednesday without the dex falls back to March")
  Assert.equal(key(3, false, false), key(1, false, false), "Thursday without the dex falls back to Lullaby")
  Assert.equal(key(6, false, false), key(0, false, false), "Sunday without the card falls back to March")

  -- Unlock gates: the dex opens Hoenn on Wednesday and Sinnoh on
  -- Thursday, and the card opens the Sunday selection.
  Assert.isTrue(key(2, true, false) ~= key(2, false, false), "Wednesday Hoenn stays gated by the national dex")
  Assert.isTrue(key(3, true, false) ~= key(3, false, false), "Thursday Sinnoh stays gated by the national dex")
  Assert.isTrue(key(6, false, true) ~= key(6, false, false), "Sunday selection stays gated by the card item")

  -- Determinism: repeating one combination replays the same selection.
  Assert.equal(
    startMusic(catalog, 0, false, false, seedBase),
    key(0, false, false),
    "repeating a weekday combination replays the same track"
  )

  -- The card selection draws from a bounded table, not a constant and not
  -- an open-ended shuffle: thirty seeds visit more than one entry and at
  -- most twenty-five.
  local picked = {}
  local distinct = 0
  for seed = 1, 30 do
    local choice = startMusic(catalog, 6, false, true, 60000 + seed)
    if picked[choice] == nil then
      picked[choice] = true
      distinct = distinct + 1
    end
  end
  Assert.isTrue(distinct > 1, "the card selection varies instead of repeating one constant")
  Assert.isTrue(distinct <= 25, "the card selection stays inside its bounded source table")
end

-- Runs one show through setup, print, and teardown on a fresh program and
-- returns its requested message references plus its title. Non-music shows
-- must reach print quiescence; music asserts latch and playback instead.
---@param catalog table<string, unknown>
---@param station integer
---@param hour integer
---@param opts table<string, unknown>
---@param seed integer
---@return table<integer, string> refs, string|nil title, string show
local function deepVector(catalog, station, hour, opts, seed)
  local moment = { year = 2024, month = 1, day = 8, hour = hour, minute = 0, second = 0 }
  local program, audio, messages, _, _, _ = freshProgram(catalog, {
    seed = seed,
    nationalDex = opts.nationalDex == true,
    blueCard = opts.blueCard == true,
    swarmActive = opts.swarmActive == true,
    passwordVar = opts.passwordVar,
    moment = moment,
  })
  local show = tuneSettled(program, station, "clear")
  if show == MUSIC_KEY then
    pollPlayCalls(program, audio, 1, 600, "the music program start")
    audio:complete()
    pollPlayCalls(program, audio, 2, 800, "the latched music")
    Assert.isTrue(audio:radioIsPlaying(), "the music vector leaves its sequence playing")
  else
    for _ = 1, 600 do
      program:updateFixed()
    end
    local first = messages:requestCount()
    Assert.isTrue(first > 0, "the " .. show .. " vector requests its source messages")
    for _ = 1, 600 do
      program:updateFixed()
    end
    Assert.equal(messages:requestCount(), first, "the " .. show .. " vector completes instead of printing forever")
  end
  local title = program:status().title
  local refs = {}
  for _, request in ipairs(messages.requests) do
    refs[#refs + 1] = "bank " .. request.bank .. " entry " .. request.entry
  end
  program:endProgram()
  program:dispose()
  return refs, title, show
end

---@param refs table<integer, string>
---@return table<string, boolean>
local function refSet(refs)
  local set = {}
  for _, ref in ipairs(refs) do
    set[ref] = true
  end
  return set
end

function T.every_native_show_runs_a_real_program_vector_and_returns_from_commercials(romFs, versionId)
  Fixture.requireFeature(
    "game.hgss.src.pokegear.RadioProgram",
    "broadcast programs have no dispatcher yet: no native show can run its program vector"
  )
  local catalog = compileCatalog(romFs, versionId)
  checkTwelveShowClosure(catalog)

  -- Coverage sweep on one program: every non-commercial native show must be
  -- reachable through tuned stations and executable hours.
  local program, _, _, _, _, civil = freshProgram(catalog, { seed = 9182 })
  local reached = {}
  local hourOf = {}
  local commercialSightings = 0
  for _, station in ipairs({ 0, 1, 4, 5, 6, 7 }) do
    Fixture.setCivil(civil.cell, { year = 2024, month = 1, day = 8, hour = 10, minute = 0, second = 0 })
    local show, commercials = tuneSettled(program, station, "clear")
    reached[show] = true
    commercialSightings = commercialSightings + commercials
    program:endProgram()
  end
  for _, station in ipairs({ 2, 3 }) do
    for hour = 0, 23 do
      Fixture.setCivil(civil.cell, { year = 2024, month = 1, day = 8, hour = hour, minute = 0, second = 0 })
      local show, commercials = tuneSettled(program, station, "clear")
      reached[show] = true
      if hourOf[show] == nil then
        hourOf[show] = hour
      end
      commercialSightings = commercialSightings + commercials
      program:endProgram()
    end
  end
  program:dispose()
  for _, key in ipairs(Fixture.SHOW_KEY_LIST) do
    if key ~= COMMERCIAL_KEY then
      Assert.isTrue(reached[key] == true, "native show " .. key .. " is reachable on the real catalog")
    end
  end

  -- Deep vectors: every reachable show runs its own messages to completion.
  local vectors = {}
  local function vector(show, station, hour, opts, seed)
    local refs, title, settled = deepVector(catalog, station, hour, opts, seed)
    Assert.equal(settled, show, "the deep run tunes the intended show")
    Assert.isTrue(#refs > 0, "the " .. show .. " vector requests its source messages")
    vectors[show] = { refs = refs, title = title }
  end
  vector(MUSIC_KEY, 0, 10, {}, 101)
  vector("radio.talk", 1, 10, { swarmActive = true }, 102)
  vector("radio.poke-flute", 4, 10, {}, 103)
  vector("radio.unown", 5, 10, {}, 104)
  vector("radio.rocket", 6, 10, {}, 105)
  vector("radio.mahogany", 7, 10, {}, 106)
  vector("radio.trainer-profiles", 2, hourOf["radio.trainer-profiles"], {}, 107)
  vector("radio.town-people", 2, hourOf["radio.town-people"], {}, 108)
  vector("radio.search-party", 3, hourOf["radio.search-party"], {}, 109)
  vector("radio.serial-drama", 3, hourOf["radio.serial-drama"], {}, 110)
  vector("radio.buena", 3, hourOf["radio.buena"], { blueCard = true, passwordVar = 47 }, 111)

  -- No show is substituted with generic chatter: every vector's message
  -- reference set is distinct.
  local shows = {}
  for show in pairs(vectors) do
    shows[#shows + 1] = show
  end
  for i = 1, #shows do
    for j = i + 1, #shows do
      local a, b = refSet(vectors[shows[i]].refs), refSet(vectors[shows[j]].refs)
      local same = true
      for ref in pairs(a) do
        if b[ref] == nil then
          same = false
        end
      end
      for ref in pairs(b) do
        if a[ref] == nil then
          same = false
        end
      end
      Assert.isTrue(not same, "shows " .. shows[i] .. " and " .. shows[j] .. " run distinct message vectors")
    end
  end

  -- Talk announces an outbreak only when one is active: the same seed and
  -- hour request strictly more, strictly covering references while active.
  local activeRefs, activeTitle, activeShow = deepVector(catalog, 1, 10, { swarmActive = true }, 112)
  local idleRefs, _, idleShow = deepVector(catalog, 1, 10, {}, 112)
  Assert.equal(activeShow, "radio.talk", "the outbreak run tunes the talk show")
  Assert.equal(idleShow, "radio.talk", "the quiet run tunes the talk show")
  local active, idle = refSet(activeRefs), refSet(idleRefs)
  Assert.isTrue(#activeRefs > #idleRefs, "an active outbreak adds announcement references")
  for ref in pairs(idle) do
    Assert.isTrue(active[ref] == true, "the outbreak run keeps every quiet-run reference " .. ref)
  end
  local repeatRefs, _, _ = deepVector(catalog, 1, 10, { swarmActive = true }, 112)
  Assert.deepEqual(repeatRefs, activeRefs, "the talk vector is deterministic for one seed and hour")
  Assert.notNil(activeTitle, "the talk vector presents its title")

  -- Buena reports the shared daily password identity: bank 66 entry
  -- 40 plus the password-set variable modulo 30, with the card-gated
  -- reply, and the heard flag only after the introduction.
  local buenaHour = hourOf["radio.buena"]
  local buenaMoment = { year = 2024, month = 1, day = 8, hour = buenaHour, minute = 0, second = 0 }
  local buenaProgram, _, buenaMessages, _, buenaEvents, _ = freshProgram(catalog, {
    seed = 113,
    blueCard = true,
    passwordVar = 47,
    moment = buenaMoment,
  })
  Assert.equal(
    buenaEvents:isFlagSet(FieldScriptSymbols.flagsByName.FLAG_DAILY_HEARD_BUENAS_PASSWORD),
    false,
    "merely owning the password fact never marks it heard"
  )
  buenaProgram:begin(3, "clear")
  for _ = 1, 10 do
    buenaProgram:updateFixed()
  end
  Assert.equal(
    buenaEvents:isFlagSet(FieldScriptSymbols.flagsByName.FLAG_DAILY_HEARD_BUENAS_PASSWORD),
    false,
    "tuning and the title alone never mark the password heard"
  )
  local heardTick = nil
  for _ = 1, 1200 do
    buenaProgram:updateFixed()
    if buenaEvents:isFlagSet(FieldScriptSymbols.flagsByName.FLAG_DAILY_HEARD_BUENAS_PASSWORD) then
      heardTick = true
      break
    end
  end
  Assert.isTrue(heardTick == true, "the password counts heard only past the introduction")
  local withCard = refSet((function()
    local refs = {}
    for _, request in ipairs(buenaMessages.requests) do
      refs[#refs + 1] = "bank " .. request.bank .. " entry " .. request.entry
    end
    return refs
  end)())
  local token = "bank " .. PASSWORD_TOKEN_BANK .. " entry " .. (PASSWORD_TOKEN_BASE + (47 % 30))
  Assert.isTrue(withCard[token] == true, "the password broadcast voices token " .. token)
  local reply = "bank " .. BUENA_REPLY_BANK .. " entry " .. BUENA_REPLY_WITH_CARD
  Assert.isTrue(withCard[reply] == true, "the card reply voices bank 411 entry 4")
  Assert.equal(
    buenaEvents:getVar(FieldScriptSymbols.variablesByName.VAR_BLUE_CARD_POINTS),
    0,
    "listening never awards card points"
  )
  buenaProgram:endProgram()
  buenaProgram:dispose()
  local plainRefs, _, _ = deepVector(catalog, 3, buenaHour, { passwordVar = 47 }, 114)
  local plainReply = "bank " .. BUENA_REPLY_BANK .. " entry " .. BUENA_REPLY_WITHOUT_CARD
  Assert.isTrue(refSet(plainRefs)[plainReply] == true, "the cardless reply voices bank 411 entry 5")

  -- Commercials preempt once and return to the tuned station with its
  -- episode intact; rapid retuning never leaves two programs advancing.
  local hunted = false
  for seed = 201, 204 do
    for _, station in ipairs({ 2, 3 }) do
      for hour = 0, 23 do
        if not hunted then
          local hunt, _, _, _, _, _ = freshProgram(catalog, {
            seed = seed,
            moment = { year = 2024, month = 1, day = 8, hour = hour, minute = 0, second = 0 },
          })
          hunt:begin(station, "clear")
          local preTitle = nil
          local preempted = false
          for _ = 1, 900 do
            hunt:updateFixed()
            local status = hunt:status()
            if status.show == COMMERCIAL_KEY then
              preempted = true
              break
            end
            if status.title ~= nil then
              preTitle = status.title
            end
          end
          if preempted then
            hunted = true
            local returned = false
            for _ = 1, 1000 do
              hunt:updateFixed()
              if hunt:status().show ~= COMMERCIAL_KEY then
                returned = true
                break
              end
            end
            Assert.isTrue(returned, "a queued commercial returns to the tuned station")
            if preTitle ~= nil then
              Assert.equal(hunt:status().title, preTitle, "the commercial return resumes the same episode")
            end
            local encore = false
            for _ = 1, 400 do
              hunt:updateFixed()
              if hunt:status().show == COMMERCIAL_KEY then
                encore = true
              end
            end
            Assert.isFalse(encore, "a queued commercial takes precedence exactly once")
          end
          hunt:endProgram()
          hunt:dispose()
        end
      end
    end
  end
  Assert.isTrue(hunted or commercialSightings > 0, "scheduled commercials appear across the station and hour sweep")

  local retune, _, _, _, _, _ = freshProgram(catalog, { seed = 999 })
  retune:begin(0, "clear")
  for _ = 1, 20 do
    retune:updateFixed()
  end
  retune:begin(1, "clear")
  for _ = 1, 20 do
    retune:updateFixed()
  end
  retune:begin(4, "clear")
  for _ = 1, 20 do
    retune:updateFixed()
  end
  Assert.equal(retune:status().show, "radio.poke-flute", "rapid retuning leaves one advancing program")
  retune:endProgram()
  retune:dispose()

  -- Ordinary music survives program teardown: ending the music program
  -- never stops its surviving sequence.
  local musicProgram, musicAudio, _, _, _, _ = freshProgram(catalog, { seed = 1001 })
  musicProgram:begin(0, "clear")
  pollPlayCalls(musicProgram, musicAudio, 1, 600, "the teardown music start")
  musicAudio:complete()
  pollPlayCalls(musicProgram, musicAudio, 2, 800, "the latched teardown music")
  musicProgram:endProgram()
  Assert.isTrue(musicAudio:radioIsPlaying(), "ending a music program leaves its surviving sequence playing")
  Assert.notNil(musicAudio:currentRadioSequence(), "ending a music program keeps its sequence latch")
  musicAudio:stopRadio()
  musicProgram:dispose()
end

function T.compiled_reception_sets_carry_the_source_channel_maps(romFs, versionId)
  local catalog = compileCatalog(romFs, versionId)
  local reception = assert(catalog.reception, versionId .. " publishes its compiled reception sets")
  assert(type(reception) == "table", "the reception sets read as a record")
  Assert.equal(#reception.alph, 5, "the compiled family carries the five listed Alph maps")
  Assert.equal(#reception.mahogany, 17, "the compiled family carries the seventeen listed Mahogany maps")
  Assert.equal(#reception.forbidden, 34, "the compiled family carries the thirty-four signal-free maps")
  Assert.equal(reception.alph[1], "MAP_RUINS_OF_ALPH_UNDERGROUND_HALL", "the compiled Alph set opens in source order")
  Assert.equal(
    reception.mahogany[9],
    "MAP_TEAM_ROCKET_HEADQUARTERS_B1F",
    "the compiled Mahogany set keeps its Rocket HQ members"
  )
  Assert.equal(
    reception.forbidden[18],
    "MAP_SAFARI_ZONE_01",
    "the compiled forbidden set keeps its Safari Zone members"
  )
end

local suite = RomSuite.fromFacts(T)
return suite
