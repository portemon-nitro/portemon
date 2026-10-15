-- Native radio broadcast dispatch and retained-line purity: tuned physical
-- stations resolve to the executable hour schedules (fixed stations always,
-- one station alternating two shows by even/odd hour, one cycling three
-- shows by hour modulo three), a half-printed show never switches merely
-- because the host hour changed, and repeated reads plus same-station
-- signal changes draw no randomness, advance no episode, and never mutate
-- the original message lines. Only source print ticks generate new display
-- lines. All expectations use synthetic data and independent hour
-- arithmetic, never the dispatcher as its own oracle.

local Assert = require("tests.support.Assert")
local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
local PokegearState = require("libs.hgss.src.save.PokegearState")
local PokegearCalendar = require("game.hgss.src.pokegear.PokegearCalendar")
local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local Fixture = require("tests.support.PokegearBroadcastFixture")

local T = {
  metadata = {
    tags = { "pokegear" },
  },
  tests = {},
}

local COMMERCIAL_KEY = "radio.commercial"

---@param record table<string, unknown>
---@return table<string, unknown>
local function checkCatalog()
  local validated = PokegearAssetSchema.validate(Fixture.fixtureManifest())
  Assert.notNil(validated, "the synthetic broadcast catalog must validate through the asset schema")
  return assert(validated, "scenario setup keeps the validated catalog")
end

---@param seed integer
---@return table<string, unknown> program, table<string, unknown> audio, table<string, unknown> messages, table<string, unknown> random, { cell: { now: table<string, integer> }, clock: LocalClock }
local function freshProgram(seed)
  local record = checkCatalog()
  local refs = Fixture.catalogRefs(record)
  local state = PokegearState.new({ seed = seed }, refs)
  local calendar = PokegearCalendar.new(state)
  local random = PokegearRandom.new(seed, { trace = {}, traceLimit = 4096 })
  local events = FieldEventState.new()
  local RadioWorldContext = Fixture.requireFeature(
    "game.hgss.src.pokegear.RadioWorldContext",
    "broadcast world facts have no shared projection yet: programs cannot read dex, card, swarm, or password facts"
  )
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
  local RadioProgram = Fixture.requireFeature(
    "game.hgss.src.pokegear.RadioProgram",
    "broadcast programs have no dispatcher yet: no tuned station can start a native show"
  )
  local program = RadioProgram.new({
    catalog = record.catalog,
    world = world,
    clock = civil.clock,
    random = random,
    audio = audio,
    messages = messages,
  })
  return program, audio, messages, random, civil
end

-- Tunes one station and waits out any scheduled commercial interruption so
-- schedule assertions always observe the tuned station's own show. Returns
-- the settled show key.
---@param program table<string, unknown>
---@param station integer
---@param signal string
---@return string
local function tuneSettled(program, station, signal)
  program:begin(station, signal)
  for _ = 1, 1200 do
    program:updateFixed()
    local status = program:status()
    if status.show ~= COMMERCIAL_KEY then
      return status.show
    end
  end
  error("tuning never settled back to its station show", 0)
end

function T.tests.tuned_stations_follow_executable_hour_schedules_and_hold_mid_broadcast()
  local program, _, _, _, civil = freshProgram(4242)
  local fixed = Fixture.FIXED_STATION_SHOWS

  local alternating = {}
  local cycling = {}
  for hour = 0, 23 do
    Fixture.setCivil(civil.cell, { year = 2024, month = 1, day = 8, hour = hour, minute = 0, second = 0 })
    for station = 0, 7 do
      local show = tuneSettled(program, station, "clear")
      if fixed[station] ~= nil then
        Assert.equal(
          show,
          fixed[station],
          "station " .. station .. " keeps its fixed show at hour " .. hour
        )
      elseif station == 2 then
        alternating[hour] = show
      elseif station == 3 then
        cycling[hour] = show
      end
    end
    local status = program:status()
    Assert.isTrue(type(status.show) == "string", "the running show identity is a semantic key, not the station index")
  end

  -- Station 2 alternates exactly two shows by even/odd hour.
  local pair = {}
  for hour = 0, 23 do
    pair[alternating[hour]] = true
  end
  local pairCount = 0
  for _ in pairs(pair) do
    pairCount = pairCount + 1
  end
  Assert.equal(pairCount, 2, "the alternating station covers exactly two shows across the day")
  for hour = 0, 23 do
    Assert.equal(
      alternating[hour],
      alternating[(hour + 2) % 24],
      "the alternating station repeats every two hours at hour " .. hour
    )
    Assert.isTrue(
      alternating[hour] ~= alternating[(hour + 1) % 24],
      "the alternating station switches on consecutive hours at hour " .. hour
    )
  end

  -- Station 3 cycles exactly three shows with period three.
  local triple = {}
  for hour = 0, 23 do
    triple[cycling[hour]] = true
  end
  local tripleCount = 0
  for _ in pairs(triple) do
    tripleCount = tripleCount + 1
  end
  Assert.equal(tripleCount, 3, "the cycling station covers exactly three shows across the day")
  for hour = 0, 23 do
    Assert.equal(
      cycling[hour],
      cycling[(hour + 3) % 24],
      "the cycling station repeats every three hours at hour " .. hour
    )
    Assert.isTrue(
      cycling[hour] ~= cycling[(hour + 1) % 24],
      "the cycling station switches on consecutive hours at hour " .. hour
    )
  end

  -- A half-printed show holds across a host hour change and only resamples
  -- at its own re-evaluation point: retuning after the boundary follows the
  -- new hour while the running show never switched mid-print.
  Fixture.setCivil(civil.cell, { year = 2024, month = 1, day = 8, hour = 1, minute = 0, second = 0 })
  local before = tuneSettled(program, 3, "clear")
  for _ = 1, 60 do
    program:updateFixed()
  end
  Fixture.setCivil(civil.cell, { year = 2024, month = 1, day = 8, hour = 3, minute = 0, second = 0 })
  for _ = 1, 60 do
    program:updateFixed()
  end
  Assert.equal(
    program:status().show,
    before,
    "a half-printed show never switches merely because the host hour changed"
  )
  program:endProgram()
  local after = tuneSettled(program, 3, "clear")
  Assert.equal(after, cycling[3], "retuning after the boundary follows the new hour schedule")
  Assert.isTrue(after ~= before, "hours 1 and 3 sit on different cycle residues")
  program:endProgram()
  program:dispose()
end

function T.tests.retained_lines_survive_repeated_reads_and_weak_signal_without_new_draws()
  local program, _, messages, random, _ = freshProgram(777)
  local show = tuneSettled(program, 1, "weak")
  Assert.equal(show, Fixture.SHOW_KEYS.talk, "the weak-signal scenario listens to the multi-line talk show")
  for _ = 1, 300 do
    program:updateFixed()
  end
  messages:verifyIntact()

  local snapshot = random:capture()
  local title = program:status().title
  local body = program:status().body
  local requestCount = messages:requestCount()
  Assert.isTrue(title ~= nil, "the talk show has printed its title before the read sequence")

  -- Repeated reads between ticks change nothing observable.
  for _ = 1, 25 do
    local reread = program:status()
    Assert.deepEqual(reread.body, body, "repeated reads retain identical display lines")
    Assert.equal(reread.title, title, "repeated reads advance no episode")
    Assert.equal(reread.show, show, "repeated reads keep the running show")
  end
  Assert.deepEqual(random:capture(), snapshot, "repeated reads draw no randomness")
  Assert.equal(messages:requestCount(), requestCount, "only print ticks generate display lines, never reads")
  messages:verifyIntact()

  -- A same-station signal change never restarts the show.
  program:setSignal("clear")
  Assert.equal(program:status().show, show, "changing signal on the same station never restarts the show")
  Assert.equal(program:status().title, title, "changing signal advances no episode")
  local clearBody = program:status().body
  for _ = 1, 25 do
    Assert.deepEqual(program:status().body, clearBody, "clear-signal reads stay retained")
  end
  Assert.deepEqual(random:capture(), snapshot, "signal changes draw no randomness")

  -- Weak reception corrupts only the retained display copy.
  program:setSignal("weak")
  local weakBody = program:status().body
  Assert.isTrue(
    #weakBody == #clearBody,
    "weak reception keeps the line count while corrupting the display copy"
  )
  local differs = false
  for index, line in ipairs(weakBody) do
    if line ~= clearBody[index] then
      differs = true
    end
  end
  Assert.isTrue(differs, "weak reception visibly corrupts at least one retained display line")
  for _ = 1, 25 do
    Assert.deepEqual(program:status().body, weakBody, "weak-signal reads stay retained")
  end
  Assert.deepEqual(random:capture(), snapshot, "weak-signal reads draw no randomness")
  Assert.equal(program:status().title, title, "reception changes advance no episode")
  messages:verifyIntact()

  program:endProgram()
  program:dispose()
end

return T
