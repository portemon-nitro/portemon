-- Shared scaffolding for radio broadcast program scenarios: a synthetic
-- twelve-show catalog validated through the real asset schema, an
-- injectable civil clock, a recording message formatter that detects
-- caller-side mutation of its original lines, and a completion-controlled
-- radio audio stand-in implementing the published radio audio method
-- surface (start/stop/pause/resume/latch/liveness). The stand-in models
-- natural handle completion explicitly so scenarios can prove jingle and
-- commercial transitions follow facade completion instead of hardcoded
-- durations. No ROM data and no broadcast prose enter the repository.

local LocalClock = require("game.src.LocalClock")

---@class PokegearBroadcastFixture
local Fixture = {}

-- Proposed semantic identities for the twelve native broadcast programs,
-- in source program order. The scheduling and lifecycle behaviors are the
-- locked contract; these spellings are the proposal the dispatcher adopts.
Fixture.SHOW_KEY_LIST = {
  "radio.music",
  "radio.talk",
  "radio.search-party",
  "radio.serial-drama",
  "radio.buena",
  "radio.trainer-profiles",
  "radio.town-people",
  "radio.poke-flute",
  "radio.unown",
  "radio.rocket",
  "radio.mahogany",
  "radio.commercial",
}

Fixture.SHOW_KEYS = {
  music = "radio.music",
  talk = "radio.talk",
  searchParty = "radio.search-party",
  serialDrama = "radio.serial-drama",
  buena = "radio.buena",
  trainerProfiles = "radio.trainer-profiles",
  townPeople = "radio.town-people",
  pokeFlute = "radio.poke-flute",
  unown = "radio.unown",
  rocket = "radio.rocket",
  mahogany = "radio.mahogany",
  commercial = "radio.commercial",
}

-- Physical tuned-station identities whose show never depends on the hour.
Fixture.FIXED_STATION_SHOWS = {
  [0] = "radio.music",
  [1] = "radio.talk",
  [4] = "radio.poke-flute",
  [5] = "radio.unown",
  [6] = "radio.rocket",
  [7] = "radio.mahogany",
}

-- Loads a broadcast module that does not exist yet at this baseline. The
-- failure names the missing behavior instead of surfacing as a suite load
-- error, so the pre-implementation red stays attributable.
---@param moduleName string
---@param missingMessage string
---@return table
function Fixture.requireFeature(moduleName, missingMessage)
  local ok, mod = pcall(require, moduleName)
  if not ok then
    error(missingMessage, 0)
  end
  assert(type(mod) == "table", missingMessage)
  return mod --[[@as table]]
end

---@param path string
---@return table<string, unknown>
local function visualRef(path)
  return { image = path, width = 32, height = 32, anchorX = 0, anchorY = 0 }
end

-- Synthetic companion manifest carrying all twelve broadcast programs.
-- Section shapes mirror the validated asset family; callers validate the
-- result through the real asset schema so scenarios borrow only genuine
-- semantic references.
---@return table<string, unknown>
function Fixture.fixtureManifest()
  local shows = {}
  for _, key in ipairs(Fixture.SHOW_KEY_LIST) do
    shows[#shows + 1] = { key = key }
  end
  return {
    schema = "g4-pokegear-assets-v2",
    skins = { 0, 1, 2, 3, 4, 5 },
    shell = { foreground = visualRef("assets/generated/pokegear/shell-foreground-skin-0.png") },
    configure = { panel = visualRef("assets/generated/pokegear/configure-panel.png") },
    phone = { panel = visualRef("assets/generated/pokegear/phone-panel.png") },
    map = { base = visualRef("assets/generated/pokegear/map-base.png") },
    fly = { base = visualRef("assets/generated/pokegear/fly-base.png") },
    radio = { dial = visualRef("assets/generated/pokegear/radio-dial.png") },
    catalog = {
      contacts = {
        { key = "custom.elm", sortWeight = 10 },
        { key = "custom.mom", sortWeight = 20 },
      },
      contactOrder = { "custom.elm", "custom.mom" },
      callDefinitions = {},
      callTriggers = {},
      rematches = {},
      gifts = {},
      momPurchases = {},
      locations = {
        { key = "custom.route-32" },
        { key = "custom.route-33" },
        { key = "custom.route-34" },
        { key = "custom.route-35" },
        { key = "custom.route-36" },
        { key = "custom.route-37" },
      },
      flypoints = {},
      regionMap = require("tests.support.PokegearRegionMapFixture").build(),
      reception = {},
      shows = shows,
      radioEffects = {},
    },
    text = {},
    sequences = {},
  }
end

---@param record table<string, unknown>
---@return { catalog: table<string, unknown> }
function Fixture.catalogRefs(record)
  assert(type(record) == "table" and type(record.catalog) == "table", "fixture refs read the validated catalog")
  return { catalog = record.catalog }
end

-- Injectable civil clock over a caller-owned cell: scenarios advance or
-- rewind host-independent civil time by writing cell.now, and the program
-- under test can only observe those explicit samples.
---@param moment table<string, integer>
---@return { cell: { now: table<string, integer> }, clock: LocalClock }
function Fixture.newCivilCell(moment)
  local cell = {
    now = {
      year = moment.year,
      month = moment.month,
      day = moment.day,
      hour = moment.hour,
      minute = moment.minute,
      second = moment.second,
    },
  }
  local clock = LocalClock.new(function()
    local now = cell.now
    return {
      year = now.year,
      month = now.month,
      day = now.day,
      hour = now.hour,
      minute = now.minute,
      second = now.second,
    }
  end)
  return { cell = cell, clock = clock }
end

---@param cell table<string, integer>
---@param moment table<string, integer>
function Fixture.setCivil(cell, moment)
  cell.now = {
    year = moment.year,
    month = moment.month,
    day = moment.day,
    hour = moment.hour,
    minute = moment.minute,
    second = moment.second,
  }
end

-- Recording message formatter. Returned lines render their numeric bank
-- and entry identities as text, so scenarios can trace exact message
-- selection and draw order without any broadcast prose in the repository.
-- Every issued line is snapshotted at return; verifyIntact proves later
-- that read and draw paths never mutated the original lines in place.
---@return table<string, unknown>
function Fixture.newMessageLog()
  local log = {
    requests = {},
    issued = {},
    pristine = {},
  }
  ---@param bankId integer
  ---@param entryId integer
  ---@param params table<string, unknown>|nil
  ---@return table<string, unknown>
  function log:line(bankId, entryId, params)
    assert(
      type(bankId) == "number" and type(entryId) == "number",
      "broadcast message requests carry numeric bank and entry identities"
    )
    local requests = assert(self.requests, "message log records every request")
    requests[#requests + 1] = { bank = bankId, entry = entryId, params = params }
    local text = { text = "bank " .. bankId .. " entry " .. entryId, tokens = {} }
    local issued = assert(self.issued, "message log tracks every issued line")
    issued[#issued + 1] = text
    local pristine = assert(self.pristine, "message log snapshots every issued line")
    pristine[#pristine + 1] = { text = text.text, tokens = {} }
    return text
  end
  ---@return integer
  function log:requestCount()
    return #assert(self.requests, "message log counts its requests")
  end
  function log:verifyIntact()
    local issued = assert(self.issued, "message integrity compares every issued line")
    local pristine = assert(self.pristine, "message integrity keeps every snapshot")
    assert(#issued == #pristine, "message integrity compares every issued line")
    for index, text in ipairs(issued) do
      assert(type(text) == "table", "issued broadcast lines stay records")
      local want = pristine[index]
      assert(text.text == want.text, "read paths must not mutate the original broadcast line")
      local tokens = text.tokens
      assert(type(tokens) == "table" and next(tokens) == nil, "read paths must not mutate original line tokens")
    end
  end
  return log
end

-- Completion-controlled stand-in for the published radio audio surface.
-- Latch and liveness stay separate exactly like the real facade: stopping
-- clears the latch at once while pausing retains it, and natural
-- completion silences playback while the latch survives. Scenarios hold
-- completion back to prove transitions wait on the facade, then release it
-- with complete().
---@return table<string, unknown>
function Fixture.newAudioStandIn()
  local audio = {
    calls = {},
    latch = nil,
    playing = false,
    paused = false,
  }
  ---@param sequenceKey integer|string
  ---@return boolean
  function audio:playRadio(sequenceKey)
    local calls = assert(self.calls, "audio stand-in records every radio call")
    calls[#calls + 1] = { op = "play", key = sequenceKey }
    self.latch = sequenceKey
    self.playing = true
    self.paused = false
    return true
  end
  ---@param _fadeFrames integer?
  function audio:stopRadio(_fadeFrames)
    local calls = assert(self.calls, "audio stand-in records every radio call")
    calls[#calls + 1] = { op = "stop" }
    self.latch = nil
    self.playing = false
    self.paused = false
  end
  function audio:pauseRadio()
    local calls = assert(self.calls, "audio stand-in records every radio call")
    calls[#calls + 1] = { op = "pause" }
    self.paused = true
  end
  function audio:resumeRadio()
    local calls = assert(self.calls, "audio stand-in records every radio call")
    calls[#calls + 1] = { op = "resume" }
    self.paused = false
  end
  ---@return integer|string|nil
  function audio:currentRadioSequence()
    return self.latch
  end
  ---@return boolean
  function audio:radioIsPlaying()
    return self.latch ~= nil and self.playing == true and self.paused ~= true
  end
  -- Models natural handle completion: playback goes silent while the latch
  -- survives, exactly like the real facade after a finite sequence ends.
  function audio:complete()
    self.playing = false
  end
  ---@return integer
  function audio:playCallCount()
    local count = 0
    for _, call in ipairs(assert(self.calls, "audio stand-in counts its start calls")) do
      if call.op == "play" then
        count = count + 1
      end
    end
    return count
  end
  ---@return table<integer, table<string, unknown>>
  function audio:playCalls()
    local starts = {}
    for _, call in ipairs(assert(self.calls, "audio stand-in lists its start calls")) do
      if call.op == "play" then
        starts[#starts + 1] = call
      end
    end
    return starts
  end
  return audio
end

-- Dex predicate standing in for the player-profile national-dex fact until
-- the production composition wires the real profile owner. Consultations
-- are recorded so scenarios can prove the unlock gates were actually read.
---@param hasNational boolean
---@return table<string, unknown>
function Fixture.newDexReader(hasNational)
  local dex = { national = hasNational, consultations = 0 }
  ---@return boolean
  function dex:hasNationalDex()
    self.consultations = assert(self.consultations, "dex reader counts its consultations") + 1
    return self.national == true
  end
  return dex
end

-- Bag predicate exposing the real bag service's lookup surface over an
-- explicit presence set. The production composition supplies the live bag;
-- scenarios use this to model owned and missing key items deterministically.
---@param present table<string, boolean>
---@return table<string, unknown>
function Fixture.newBagReader(present)
  local bag = { present = present, consultations = {} }
  ---@param itemKey string
  ---@param quantity integer?
  ---@return boolean
  function bag:has(itemKey, quantity)
    local consultations = assert(self.consultations, "bag reader records every lookup")
    consultations[#consultations + 1] = { key = itemKey, quantity = quantity }
    local owned = assert(self.present, "bag reader reads its presence set")
    return owned[itemKey] == true
  end
  ---@param itemKey string
  ---@return integer
  function bag:quantity(itemKey)
    local owned = assert(self.present, "bag reader reads its presence set")
    if owned[itemKey] == true then
      return 1
    end
    return 0
  end
  return bag
end

return Fixture
