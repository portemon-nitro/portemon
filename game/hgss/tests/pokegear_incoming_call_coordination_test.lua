-- Incoming call coordination while the gear stays closed: whole-minute
-- eligibility with the first offline delta ignored, source trigger
-- selection ahead of the random gate, exact inclusive random boundaries
-- with labelled draw traces, acceptance as the single clearing boundary
-- (event triggers clear, ordinary calls record history, expiry and failed
-- acquisition consume nothing), strict second-exact expiry with
-- backward-time protection, and nonstacking repeat tones without render
-- driven draws. Every expectation replays the companion random streams
-- independently and recomputes the source residues outside the behaviour
-- under test. No derived assets are required. No ROM data is required.

local Assert = require("tests.support.Assert")
local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
local PokegearCalendar = require("game.hgss.src.pokegear.PokegearCalendar")
local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
local PokegearState = require("libs.hgss.src.save.PokegearState")
local PhoneRewards = require("game.hgss.src.pokegear.PhoneRewards")
local PhoneWorldContext = require("game.hgss.src.pokegear.PhoneWorldContext")

local T = {
  metadata = {
    tags = { "pokegear" },
  },
  tests = {},
}

-- Loads the incoming-call coordinator that does not exist yet at this
-- baseline. The failure names the missing behaviour instead of surfacing
-- as a suite load error, so the pre-implementation red stays attributable.
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

local MOM_KEY = "custom.mom"
local TRAINER_KEY = "custom.trainer-plain"
local MOM_TRIGGER = PhoneRewards.MOM_GIFT_TRIGGER

---@param path string
---@return table
local function visualRef(path)
  return { image = path, width = 32, height = 32, anchorX = 0, anchorY = 0 }
end

---@param key string
---@param name string
---@param weight integer
---@return table
local function contactRecord(key, name, weight, family)
  return { key = key, name = name, sortWeight = weight, family = family }
end

-- The durable trigger facts the coordinator selects from. Each record
-- carries the trigger key, its owning contact, and the source call kind:
-- kind 3 is an event trigger that clears at acceptance, kind 0 is an
-- ordinary callback. The record shape is the proposal the coordinator
-- adopts; the clearing and history behaviour below is the locked contract.
---@param key string
---@param contact string
---@param kind integer
---@param slot integer?
---@param clearOnPickup boolean?
---@return table
local function triggerRecord(key, contact, kind, slot, clearOnPickup)
  slot = slot or (key == MOM_TRIGGER and 12 or 13)
  if clearOnPickup == nil then
    clearOnPickup = slot == 12
  end
  return { key = key, contact = contact, kind = kind, slot = slot, clearOnPickup = clearOnPickup }
end

-- Synthetic companion catalog validated through the real asset schema, so
-- the coordinator borrows only genuine semantic references.
---@param contacts table[]
---@param triggers table[]
---@return table
local function fixtureManifest(contacts, triggers)
  local order = {}
  for _, contact in ipairs(contacts) do
    order[#order + 1] = contact.key
  end
  return {
    schema = "g4-pokegear-assets-v3",
    skins = { 0, 1, 2, 3, 4, 5 },
    shell = { foreground = visualRef("assets/generated/pokegear/shell-foreground-skin-0.png") },
    configure = { panel = visualRef("assets/generated/pokegear/configure-panel.png") },
    phone = { panel = visualRef("assets/generated/pokegear/phone-panel.png") },
    map = { base = visualRef("assets/generated/pokegear/map-base.png") },
    fly = { base = visualRef("assets/generated/pokegear/fly-base.png") },
    radio = { dial = visualRef("assets/generated/pokegear/radio-dial.png") },
    catalog = {
      contacts = contacts,
      contactOrder = order,
      callDefinitions = {},
      callTriggers = triggers,
      rematches = {},
      gifts = {},
      momPurchases = {},
      locations = {
        { key = "custom.new-bark" },
      },
      flypoints = {},
      regionMap = require("tests.support.PokegearRegionMapFixture").build(),
      reception = {},
      shows = {},
      radioEffects = {},
    },
    text = {},
    sequences = {},
  }
end

-- One civil sample on a fixed morning that never crosses an hour or day
-- boundary, so expectations need no date arithmetic.
---@param minute integer
---@param second integer?
---@return table<string, integer>
local function moment(minute, second)
  return { year = 2024, month = 1, day = 8, hour = 10, minute = minute, second = second or 0 }
end

-- The stable field opportunity: a quiet map, settled movement, and no
-- higher-priority owner claiming the tick.
---@param overrides table<string, unknown>?
---@return table<string, unknown>
local function opportunityArgs(overrides)
  local args = {
    mapKey = "custom.new-bark-town",
    movementState = "none",
    higherPriorityClaimed = false,
  }
  for key, value in pairs(overrides or {}) do
    args[key] = value
  end
  return args
end

-- The recording ring-tone boundary: every play attempt is logged with its
-- sequence identity, playback latches until completed, and cuts are
-- counted so the tests can prove an already-playing effect is never cut.
---@param stuck boolean? when true the sequence never completes on its own
---@return table
local function ringAudio(stuck)
  local audio = { plays = {}, playing = false, stops = 0, stuck = stuck == true }
  ---@param sequence string
  function audio:playRing(sequence)
    self.plays[#self.plays + 1] = sequence
    self.playing = true
  end
  function audio:isRingPlaying()
    return self.playing == true
  end
  function audio:completeRing()
    if not self.stuck then
      self.playing = false
    end
  end
  ---@return integer
  function audio:playCount()
    return #self.plays
  end
  function audio:stopRing()
    self.stops = self.stops + 1
  end
  return audio
end

-- The recording application host: opening records its request and hands
-- back a stable handle without enforcing a lease, so state-side
-- acceptance effects stay separable from host entry.
---@return table
local function recordingHost()
  local host = { opens = {}, results = {} }
  ---@param args table<string, unknown>
  ---@return table
  function host:open(args)
    assert(type(args) == "table", "companion opens carry their request record")
    self.opens[#self.opens + 1] = args
    return { id = #self.opens }
  end
  function host:result(handle)
    return self.results[handle.id]
  end
  function host:isActive()
    return false
  end
  return host
end

-- A host whose acquisition always fails, standing in for a busy or torn
-- down companion lease behind the real open surface.
---@return table
local function failingHost()
  return {
    open = function()
      error("companion host acquisition failed: test-injected busy lease", 0)
    end,
    result = function() return nil end,
    isActive = function()
      return false
    end,
  }
end

-- A fresh coordinator over real companion providers: validated catalog,
-- durable state with registered contacts and preset triggers, calendar,
-- traced random streams, a sparse world context, and recording
-- audio/host boundaries. Only the coordinator itself is the behaviour
-- under test. The host is fixed at construction; acceptance names only
-- its parent owner.
---@param seed integer
---@param opts { contacts: table[]?, triggers: table[]?, setTriggers: string[]?, audio: table?, host: table? }?
---@return table providers without the coordinator
local function freshProviders(seed, opts)
  local setup = opts or {}
  local contacts = setup.contacts
    or {
      contactRecord(MOM_KEY, "MOM", 10, "mother"),
      contactRecord(TRAINER_KEY, "JACE", 20, "trainer"),
    }
  local record = PokegearAssetSchema.validate(fixtureManifest(contacts, setup.triggers or {}))
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  record.catalog.callPermissions = {
    [9000] = { incoming = true, outgoing = true },
  }
  local state = PokegearState.new({ seed = seed }, { catalog = record.catalog })
  for _, contact in ipairs(contacts) do
    state:registerContact(contact.key)
  end
  for _, key in ipairs(setup.setTriggers or {}) do
    state:setTrigger(key, true)
  end
  local trace = {}
  local random = PokegearRandom.new(seed, { trace = trace, traceLimit = 4096 })
  local host = setup.host or recordingHost()
  local audio = setup.audio or ringAudio(false)
  return {
    state = state,
    calendar = PokegearCalendar.new(state),
    random = random,
    trace = trace,
    record = record,
    host = host,
    audio = audio,
    world = PhoneWorldContext.new({
      state = state,
      catalog = record.catalog,
      runtime = { session = { currentMap = { mapId = 9000 } } },
      flags = {},
    }),
  }
end

-- A fresh coordinator over the providers above. Only the coordinator
-- itself is the behaviour under test. The host is fixed at construction;
-- acceptance names only its parent owner.
---@param seed integer
---@param opts { contacts: table[]?, triggers: table[]?, setTriggers: string[]?, audio: table?, host: table? }?
---@return table
local function freshCoordinator(seed, opts)
  local IncomingCalls = requireFeature(
    "game.hgss.src.pokegear.IncomingCalls",
    "incoming calls have no field coordinator yet: minute eligibility, source draws, and the pending-caller handshake cannot run"
  )
  local providers = freshProviders(seed, opts)
  providers.calls = IncomingCalls.new({
    state = providers.state,
    catalog = providers.record.catalog,
    calendar = providers.calendar,
    random = providers.random,
    world = providers.world,
    host = providers.host,
    audio = providers.audio,
  })
  return providers
end

-- Drives one full eligibility cycle: the opening sample, the first
-- ten-minute delta the offline guard ignores, and the second ten-minute
-- delta that accumulates to the threshold.
---@param calls table
local function driveEligible(calls)
  calls:onFieldClock(moment(0))
  calls:onFieldClock(moment(10))
  calls:onFieldClock(moment(20))
end

-- Scans deterministic seeds once for every residue the gate scenarios
-- need. Labels never perturb stream values, so throwaway probes predict
-- the exact draws the coordinator will make at each seed.
---@return table<string, integer>
local function scanSeeds()
  local found = {}
  local edges = { 499, 500, 799, 800 }
  local edgesLeft = #edges
  for seed = 1, 100000 do
    local probe = PokegearRandom.new(seed)
    local gate = probe:mt("probe") % 100
    local category = probe:lc("probe") % 1000
    if found.fail51 == nil and gate == 51 then
      found.fail51 = seed
    end
    if found.pass50cat0 == nil and gate == 50 and category < 500 then
      found.pass50cat0 = seed
    end
    if gate <= 50 then
      for _, edge in ipairs(edges) do
        if found[edge] == nil and category == edge then
          found[edge] = seed
          edgesLeft = edgesLeft - 1
        end
      end
    end
    if found.fail51 ~= nil and found.pass50cat0 ~= nil and edgesLeft == 0 then
      break
    end
  end
  Assert.notNil(found.fail51, "the seed scan finds the 51 gate residue")
  Assert.notNil(found.pass50cat0, "the seed scan finds a passing gate inside category zero")
  for _, edge in ipairs(edges) do
    Assert.notNil(found[edge], "the seed scan finds category residue " .. edge)
  end
  return found --[[@as table<string, integer>]]
end

-- Replays the companion streams independently: labels never perturb
-- values, so a fresh instance at the same seed predicts every draw.
---@param seed integer
---@return integer gateMt, integer categoryLc, integer pickMt
local function replayDraws(seed)
  local replay = PokegearRandom.new(seed)
  local gateMt = replay:mt("independent")
  local categoryLc = replay:lc("independent")
  local pickMt = replay:mt("independent")
  return gateMt, categoryLc, pickMt
end

-- Asserts the trace carries exactly the expected stream sequence with
-- non-empty labels and source-width values.
---@param trace table<integer, table<string, unknown>>
---@param streams string[]
---@param why string
local function checkTrace(trace, streams, why)
  Assert.equal(#trace, #streams, why .. ": the draw count matches")
  for index, stream in ipairs(streams) do
    local entry = trace[index]
    Assert.notNil(entry, why .. ": draw " .. index .. " is recorded")
    assert(entry ~= nil, "draw recorded above")
    Assert.equal(entry.stream, stream, why .. ": draw " .. index .. " uses the " .. stream .. " stream")
    Assert.isTrue(type(entry.label) == "string" and entry.label ~= "", why .. ": draw " .. index .. " carries a label")
    if stream == "lc" then
      Assert.isTrue(
        type(entry.value) == "number" and entry.value >= 0 and entry.value <= 65535,
        why .. ": draw " .. index .. " keeps the source 16-bit width"
      )
    else
      Assert.isTrue(
        type(entry.value) == "number" and entry.value >= 0 and entry.value <= 4294967295,
        why .. ": draw " .. index .. " keeps the source 32-bit width"
      )
    end
  end
end

-- Recursively searches a detached state projection for a contact key,
-- either as a key or as a value, without assuming the journal shape.
---@param node unknown
---@param key string
---@return boolean
local function projectionMentions(node, key)
  if type(node) ~= "table" then
    return node == key
  end
  for k, v in pairs(node) do
    if k == key or projectionMentions(v, key) then
      return true
    end
  end
  return false
end

-- Counts the Mersenne draws in a trace: the random gate path draws them,
-- the trigger path must draw none.
---@param trace table<integer, table<string, unknown>>
---@return integer
local function countMtDraws(trace)
  local count = 0
  for _, entry in ipairs(trace) do
    if entry.stream == "mt" then
      count = count + 1
    end
  end
  return count
end

-- Eligibility waits for ten whole minutes, the first offline delta is
-- ignored, triggered callers win without touching the random gate, the
-- ordinary gate passes exactly 0..50, categories split exactly at
-- 500/800, and polling draws nothing.
function T.tests.incoming_calls_wait_for_ten_whole_minutes_then_follow_exact_source_draws()
  -- Minutes, the offline guard, and trigger-first selection with a
  -- labelled trace: nine minutes stay silent, the first ten-minute delta
  -- is ignored, and the second accumulates to the threshold, where the
  -- single pending trigger is chosen with one labelled linear draw and
  -- no Mersenne draw at all.
  do
    local rig = freshCoordinator(4242, {
      setTriggers = { MOM_TRIGGER },
      triggers = { triggerRecord(MOM_TRIGGER, MOM_KEY, 3) },
    })
    local calls = rig.calls
    calls:onFieldClock(moment(0))
    calls:onOpportunity(opportunityArgs())
    Assert.isFalse(calls:notification(), "zero elapsed minutes never ring")
    Assert.equal(#rig.trace, 0, "an ineligible evaluation draws nothing")
    calls:onFieldClock(moment(9))
    calls:onOpportunity(opportunityArgs())
    Assert.isFalse(calls:notification(), "nine elapsed minutes never ring")
    Assert.equal(#rig.trace, 0, "nine minutes still draw nothing")
    calls:onFieldClock(moment(10))
    calls:onOpportunity(opportunityArgs())
    local view = calls:notification()
    Assert.notNil(view, "ten live minutes reach the threshold and ring")
    assert(type(view) == "table", "ringing publishes its caller view")
    Assert.equal(view.contactKey, MOM_KEY, "the pending trigger selects its owning caller")
    checkTrace(rig.trace, { "lc" }, "trigger selection")
    local expectedPick = PokegearRandom.new(4242):lc("independent")
    Assert.equal(rig.trace[1].value, expectedPick, "the trigger pick matches the independent linear replay")
    -- Polling the view draws nothing and changes nothing.
    local randomBefore = rig.random:capture()
    local first = calls:notification()
    local second = calls:notification()
    local third = calls:notification()
    Assert.deepEqual(second, first, "repeated polls report the identical view")
    Assert.deepEqual(third, first, "a third poll still reports the identical view")
    Assert.deepEqual(rig.random:capture(), randomBefore, "polling the notification draws no randomness")
    Assert.equal(#rig.trace, 1, "polling the notification records no draw")
    calls:dispose()
  end

  local seeds = scanSeeds()

  -- The ordinary gate fails exactly above the inclusive boundary and
  -- resets the cooldown: residue 51 draws once, stays silent, refuses to
  -- re-evaluate after nine more minutes, and evaluates again only once
  -- the reset ten minutes have passed.
  do
    local rig = freshCoordinator(seeds.fail51, { contacts = { contactRecord(TRAINER_KEY, "JACE", 20, "trainer") } })
    local calls = rig.calls
    driveEligible(calls)
    calls:onOpportunity(opportunityArgs())
    Assert.isFalse(calls:notification(), "gate residue 51 never rings")
    checkTrace(rig.trace, { "mt" }, "failed gate")
    Assert.equal(rig.trace[1].value % 100, 51, "the failed draw carries residue 51")
    calls:onFieldClock(moment(29))
    calls:onOpportunity(opportunityArgs())
    Assert.isFalse(calls:notification(), "nine minutes after a failure stay silent")
    Assert.equal(#rig.trace, 1, "the reset cooldown draws nothing before ten minutes")
    calls:onFieldClock(moment(30))
    calls:onOpportunity(opportunityArgs())
    Assert.isTrue(#rig.trace >= 2, "the reset ten minutes evaluate again with fresh draws")
    Assert.equal(rig.trace[1].value % 100, 51, "the first draw stays the recorded failure")
    calls:dispose()
  end

  -- The ordinary gate passes exactly at the inclusive boundary: residue
  -- 50 inside category zero rings the lone candidate, and every draw
  -- matches the independent replay with the original pick arithmetic.
  do
    local rig = freshCoordinator(seeds.pass50cat0, { contacts = { contactRecord(TRAINER_KEY, "JACE", 20, "trainer") } })
    local calls = rig.calls
    driveEligible(calls)
    calls:onOpportunity(opportunityArgs())
    local view = calls:notification()
    Assert.notNil(view, "gate residue 50 inside category zero rings")
    assert(type(view) == "table", "ringing publishes its caller view")
    Assert.equal(view.contactKey, TRAINER_KEY, "the lone eligible caller is picked exactly")
    checkTrace(rig.trace, { "mt", "lc", "mt" }, "random selection")
    local gateMt, categoryLc, pickMt = replayDraws(seeds.pass50cat0)
    Assert.equal(rig.trace[1].value, gateMt, "the gate draw matches the independent replay")
    Assert.equal(rig.trace[2].value, categoryLc, "the category draw matches the independent replay")
    Assert.equal(rig.trace[3].value, pickMt, "the pick draw matches the independent replay")
    Assert.equal(gateMt % 100, 50, "the passing draw carries residue 50")
    Assert.isTrue(categoryLc % 1000 < 500, "the category draw falls below 500")
    Assert.equal(math.floor((pickMt % (1 * 100)) / 100), 0, "the original pick form selects index zero of one")
    calls:dispose()
  end

  -- Category boundaries hold on both sides: 499 rings inside category
  -- zero while 500, 799, and 800 stay silent in higher categories, and
  -- neither ringing nor silence evaluates again without fresh minutes.
  for _, edge in ipairs({ 499, 500, 799, 800 }) do
    local rig = freshCoordinator(seeds[edge], { contacts = { contactRecord(TRAINER_KEY, "JACE", 20, "trainer") } })
    local calls = rig.calls
    driveEligible(calls)
    calls:onOpportunity(opportunityArgs())
    local categoryDraw = nil
    for _, entry in ipairs(rig.trace) do
      if entry.stream == "lc" then
        categoryDraw = entry.value
      end
    end
    Assert.notNil(categoryDraw, "residue " .. edge .. " draws its category")
    assert(type(categoryDraw) == "number", "category draw recorded above")
    Assert.equal(categoryDraw % 1000, edge, "the category draw carries residue " .. edge)
    if edge == 499 then
      local view = calls:notification()
      Assert.notNil(view, "residue 499 stays inside category zero and rings")
      assert(type(view) == "table", "ringing publishes its caller view")
      Assert.equal(view.contactKey, TRAINER_KEY, "residue 499 picks the lone candidate")
      checkTrace(rig.trace, { "mt", "lc", "mt" }, "category zero selection")
      calls:onOpportunity(opportunityArgs())
      Assert.equal(#rig.trace, 3, "an active ring never re-evaluates")
      Assert.deepEqual(calls:notification(), view, "an active ring keeps its view")
    else
      Assert.isFalse(calls:notification(), "residue " .. edge .. " leaves category zero and stays silent")
      checkTrace(rig.trace, { "mt", "lc" }, "empty category selection")
      calls:onOpportunity(opportunityArgs())
      Assert.equal(#rig.trace, 2, "an empty category draws nothing again without fresh minutes")
    end
    calls:dispose()
  end
end

-- Accepting a call is the single clearing boundary: an ordinary incoming
-- records history without touching triggers, an event trigger survives
-- expiry and failed acquisition, and success clears the trigger before
-- any dialogue runs.
function T.tests.accepting_a_call_acknowledges_only_a_successful_terminal_result()
  requireFeature(
    "game.hgss.src.pokegear.IncomingCalls",
    "incoming calls have no field coordinator yet: acceptance cannot clear triggers or record ordinary history"
  )
  local seeds = scanSeeds()

  -- The ordinary random incoming records history at acceptance: the
  -- pass-seed ring names the plain caller, polls hold still, and
  -- accepting files history without setting or clearing any trigger.
  do
    local rig = freshCoordinator(seeds.pass50cat0, { contacts = { contactRecord(TRAINER_KEY, "JACE", 20, "trainer") } })
    local calls = rig.calls
    driveEligible(calls)
    calls:onOpportunity(opportunityArgs())
    local ordinary = calls:notification()
    Assert.notNil(ordinary, "the passing gate rings the ordinary caller")
    assert(type(ordinary) == "table", "ringing publishes its caller view")
    Assert.equal(ordinary.contactKey, TRAINER_KEY, "the ordinary ring names the plain caller")
    Assert.deepEqual(calls:notification(), ordinary, "polling holds the ordinary view still")
    Assert.deepEqual(calls:notification(), ordinary, "a third poll still holds the ordinary view still")
    local handle = calls:accept("field:test-parent")
    Assert.equal(#rig.host.opens, 1, "acceptance enters the companion host exactly once")
    Assert.isFalse(projectionMentions(rig.state:readPhone().history, TRAINER_KEY), "live calls do not consume history")
    Assert.deepEqual(rig.state:readPhone().triggers, {}, "the ordinary acceptance sets no trigger")
    Assert.isFalse(calls:notification(), "acceptance ends the ordinary ring")
    rig.host.results[handle.id] = { contact = TRAINER_KEY, error = "native page failed" }
    local retry = calls:notification()
    Assert.notNil(retry, "a failed call restores its ordinary opportunity")
    Assert.isFalse(projectionMentions(rig.state:readPhone().history, TRAINER_KEY), "a failed call stays out of history")
    calls:accept("field:test-parent")
    local retryHandle = { id = 2 }
    rig.host.results[retryHandle.id] = { contact = TRAINER_KEY }
    Assert.isFalse(calls:notification(), "a successful terminal call clears the retry ring")
    Assert.isTrue(projectionMentions(rig.state:readPhone().history, TRAINER_KEY), "success records ordinary history")
    calls:dispose()
  end

  -- The pending event trigger wins over a passing random gate without
  -- drawing it: the opportunity rings the trigger owner on the same
  -- pass seed that rang the plain caller above.
  do
    local rig = freshCoordinator(seeds.pass50cat0, {
      setTriggers = { MOM_TRIGGER },
      triggers = { triggerRecord(MOM_TRIGGER, MOM_KEY, 3) },
    })
    local calls = rig.calls
    driveEligible(calls)
    calls:onOpportunity(opportunityArgs())
    local event = calls:notification()
    Assert.notNil(event, "the pending event trigger rings on the passing seed")
    assert(type(event) == "table", "ringing publishes its caller view")
    Assert.equal(event.contactKey, MOM_KEY, "triggered flags are considered before the random gate")
    Assert.equal(countMtDraws(rig.trace), 0, "the triggered selection draws no random gate")
    calls:dispose()
  end

  -- Expiry consumes nothing: thirty-one seconds end the ring while the
  -- trigger stays set, history stays free of the caller, and polls hold.
  do
    local rig = freshCoordinator(4242, {
      setTriggers = { MOM_TRIGGER },
      triggers = { triggerRecord(MOM_TRIGGER, MOM_KEY, 3) },
    })
    local calls = rig.calls
    driveEligible(calls)
    calls:onOpportunity(opportunityArgs())
    local event = calls:notification()
    Assert.notNil(event, "the event trigger rings for the expiry check")
    calls:onFieldClock(moment(20))
    calls:onFieldClock(moment(20, 30))
    Assert.deepEqual(calls:notification(), event, "exactly thirty seconds still ring")
    calls:onFieldClock(moment(20, 31))
    Assert.isFalse(calls:notification(), "thirty-one seconds expire the ring")
    Assert.isTrue(
      rig.state:readPhone().triggers[MOM_TRIGGER] == true,
      "expiry never consumes the pending event trigger"
    )
    Assert.isFalse(
      projectionMentions(rig.state:readPhone().history, MOM_KEY),
      "expiry records no ordinary history for the event caller"
    )
    Assert.isFalse(calls:notification(), "polling after expiry stays silent")
    calls:dispose()
  end

  -- Failed acquisition consumes nothing: accepting through a failing
  -- host raises, the trigger stays set, history stays clean, and the
  -- surviving trigger rings again after fresh minutes.
  do
    local rig = freshCoordinator(4242, {
      setTriggers = { MOM_TRIGGER },
      triggers = { triggerRecord(MOM_TRIGGER, MOM_KEY, 3) },
      host = failingHost(),
    })
    local calls = rig.calls
    driveEligible(calls)
    calls:onOpportunity(opportunityArgs())
    local event = calls:notification()
    Assert.notNil(event, "the event trigger rings for the failure check")
    assert(type(event) == "table", "ringing publishes its caller view")
    Assert.equal(event.contactKey, MOM_KEY, "the failure check rings the event owner")
    Assert.throws(function()
      calls:accept("field:test-parent")
    end, "accepting through a failing host must fail")
    Assert.isTrue(
      rig.state:readPhone().triggers[MOM_TRIGGER] == true,
      "failed acquisition never consumes the pending event trigger"
    )
    Assert.isFalse(projectionMentions(rig.state:readPhone().history, MOM_KEY), "failed acquisition records no history")
    local afterFailure = calls:notification()
    if afterFailure == false then
      calls:onFieldClock(moment(30))
      calls:onOpportunity(opportunityArgs())
      afterFailure = calls:notification()
    end
    Assert.notNil(afterFailure, "the trigger survives acquisition failure and rings again")
    assert(type(afterFailure) == "table", "ringing publishes its caller view")
    Assert.equal(afterFailure.contactKey, MOM_KEY, "the surviving trigger still names its owner")
    calls:dispose()
  end

  -- Event triggers with an external clear policy are cleared only after
  -- the host reports a successful terminal conversation.
  do
    local rig = freshCoordinator(4242, {
      setTriggers = { "custom.clear-event" },
      triggers = { triggerRecord("custom.clear-event", MOM_KEY, 3, 1, false) },
    })
    local calls = rig.calls
    driveEligible(calls)
    calls:onOpportunity(opportunityArgs())
    Assert.notNil(calls:notification(), "the event trigger rings for the success check")
    local handle = calls:accept("field:test-parent")
    Assert.isTrue(
      rig.state:readPhone().triggers["custom.clear-event"] == true,
      "acceptance leaves event trigger state untouched until success"
    )
    rig.host.results[handle.id] = { contact = MOM_KEY }
    Assert.isFalse(calls:notification(), "successful terminal dialogue ends the event ring")
    Assert.isFalse(
      rig.state:readPhone().triggers["custom.clear-event"] == true,
      "successful event dialogue clears the trigger at result acknowledgement"
    )
    calls:dispose()
  end
end

-- Ringing obeys strict second bounds with backward-time protection and
-- repeats its tone without stacking: exactly thirty seconds still ring,
-- thirty-one and sixty-one end the ring, a backward sample preserves it,
-- the first repeat attempt names its source sequence, a stuck sequence
-- never stacks, the thirty-tick counter resets, stopping freezes the
-- tone, and the clock alone never starts a new ring.
function T.tests.ringing_expires_on_strict_second_bounds_with_nonstacking_repeat_tones()
  requireFeature(
    "game.hgss.src.pokegear.IncomingCalls",
    "incoming calls have no field coordinator yet: expiry bounds and repeat tones cannot run"
  )

  -- Exactly thirty seconds still ring; thirty-one expire without
  -- consuming the trigger.
  do
    local rig = freshCoordinator(4242, {
      setTriggers = { MOM_TRIGGER },
      triggers = { triggerRecord(MOM_TRIGGER, MOM_KEY, 3) },
    })
    local calls = rig.calls
    driveEligible(calls)
    calls:onOpportunity(opportunityArgs())
    Assert.notNil(calls:notification(), "the event trigger rings for the bounds check")
    calls:onFieldClock(moment(20))
    calls:onFieldClock(moment(20, 30))
    local view = calls:notification()
    Assert.notNil(view, "exactly thirty seconds still ring")
    assert(type(view) == "table", "ringing publishes its caller view")
    Assert.equal(view.contactKey, MOM_KEY, "the thirtieth second still names the event owner")
    calls:onFieldClock(moment(20, 31))
    Assert.isFalse(calls:notification(), "thirty-one seconds expire the ring")
    Assert.isTrue(
      rig.state:readPhone().triggers[MOM_TRIGGER] == true,
      "expiry at thirty-one seconds never consumes the trigger"
    )
    calls:dispose()
  end

  -- A backward sample preserves the ring and corrupts nothing: the early
  -- return keeps it alive, and the later bound still expires it.
  do
    local rig = freshCoordinator(4242, {
      setTriggers = { MOM_TRIGGER },
      triggers = { triggerRecord(MOM_TRIGGER, MOM_KEY, 3) },
    })
    local calls = rig.calls
    driveEligible(calls)
    calls:onOpportunity(opportunityArgs())
    Assert.notNil(calls:notification(), "the event trigger rings for the backward check")
    calls:onFieldClock(moment(20))
    calls:onFieldClock(moment(15))
    local kept = calls:notification()
    Assert.notNil(kept, "a backward sample preserves the active ring")
    assert(type(kept) == "table", "ringing publishes its caller view")
    Assert.equal(kept.contactKey, MOM_KEY, "the preserved ring still names the event owner")
    calls:onFieldClock(moment(20, 31))
    Assert.isFalse(calls:notification(), "the bound still expires after the backward sample")
    Assert.isTrue(rig.state:readPhone().triggers[MOM_TRIGGER] == true, "the backward path never consumes the trigger")
    calls:dispose()
  end

  -- Sixty-one seconds reset the ring without consuming the trigger and
  -- without inventing history.
  do
    local rig = freshCoordinator(4242, {
      setTriggers = { MOM_TRIGGER },
      triggers = { triggerRecord(MOM_TRIGGER, MOM_KEY, 3) },
    })
    local calls = rig.calls
    driveEligible(calls)
    calls:onOpportunity(opportunityArgs())
    Assert.notNil(calls:notification(), "the event trigger rings for the over-minute check")
    calls:onFieldClock(moment(20))
    calls:onFieldClock(moment(21, 1))
    Assert.isFalse(calls:notification(), "sixty-one seconds reset the ring")
    Assert.isTrue(
      rig.state:readPhone().triggers[MOM_TRIGGER] == true,
      "the over-minute reset never consumes the trigger"
    )
    Assert.isFalse(
      projectionMentions(rig.state:readPhone().history, MOM_KEY),
      "the over-minute reset records no history"
    )
    calls:dispose()
  end

  -- A stuck sequence never stacks: forty task ticks attempt the tone
  -- exactly once under its source identity even as the trigger re-rings,
  -- and the coordinator never cuts an already-playing effect.
  do
    local audio = ringAudio(true)
    local rig = freshCoordinator(4242, {
      setTriggers = { MOM_TRIGGER },
      triggers = { triggerRecord(MOM_TRIGGER, MOM_KEY, 3) },
      audio = audio,
    })
    local calls = rig.calls
    driveEligible(calls)
    calls:onOpportunity(opportunityArgs())
    Assert.notNil(calls:notification(), "the event trigger rings for the stuck-tone check")
    for tick = 1, 40 do
      calls:onFieldClock(moment(20, tick))
      calls:onOpportunity(opportunityArgs())
    end
    Assert.equal(audio:playCount(), 1, "a stuck sequence is attempted exactly once across forty ticks")
    Assert.equal(audio.plays[1], "PHONE1", "the repeat attempt names the source ring sequence")
    Assert.equal(audio.stops, 0, "stopping never cuts an already-playing effect")
    calls:dispose()
  end

  -- A completing sequence repeats on the thirty-tick counter without
  -- ever playing every tick: the attempts stay bounded with a second one
  -- inside the window, expiry freezes the tone, the silent clock starts
  -- no new ring, and fresh minutes re-arm the tone.
  do
    local audio = ringAudio(false)
    local rig = freshCoordinator(4242, {
      setTriggers = { MOM_TRIGGER },
      triggers = { triggerRecord(MOM_TRIGGER, MOM_KEY, 3) },
      audio = audio,
    })
    local calls = rig.calls
    driveEligible(calls)
    calls:onOpportunity(opportunityArgs())
    Assert.notNil(calls:notification(), "the event trigger rings for the repeat-tone check")
    for tick = 0, 30 do
      calls:onFieldClock(moment(20, tick))
      calls:onOpportunity(opportunityArgs())
      audio:completeRing()
    end
    Assert.isTrue(audio:playCount() >= 2, "the thirty-tick counter resets with a second attempt in the window")
    Assert.isTrue(audio:playCount() <= 6, "the counter spaces attempts instead of playing every tick")
    Assert.equal(audio.plays[1], "PHONE1", "the opening attempt names the source ring sequence")
    calls:onFieldClock(moment(20, 31))
    Assert.isFalse(calls:notification(), "expiry ends the tone window")
    local frozen = audio:playCount()
    for second = 32, 41 do
      calls:onFieldClock(moment(20, second))
    end
    Assert.equal(audio:playCount(), frozen, "the silent clock after expiry schedules no tone")
    Assert.isFalse(calls:notification(), "the silent clock after expiry starts no new ring")
    Assert.equal(audio.stops, 0, "expiry never cuts an already-playing effect")
    calls:onFieldClock(moment(30))
    calls:onOpportunity(opportunityArgs())
    local rearmed = calls:notification()
    Assert.notNil(rearmed, "fresh minutes re-arm the unconsumed trigger")
    calls:onOpportunity(opportunityArgs())
    audio:completeRing()
    Assert.isTrue(audio:playCount() > frozen, "the re-armed ring resumes its tone")
    calls:dispose()
  end
end

return T
