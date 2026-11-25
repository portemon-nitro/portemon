-- Incoming-call policy below the acceptance scenarios: collaborator and
-- journal shape rejection, same-map exclusion, history-covered pool
-- resets, the source launch boundary (a trigger launch clears its flag
-- and records no caller; a random launch records one), quiet disposal,
-- and save/restore preservation with transient dropped. Every expectation
-- replays the companion streams independently where draws matter. No
-- derived assets are required. No ROM data is required.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
local PokegearCalendar = require("game.hgss.src.pokegear.PokegearCalendar")
local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
local PokegearState = require("libs.hgss.src.save.PokegearState")
local PhoneWorldContext = require("game.hgss.src.pokegear.PhoneWorldContext")
local IncomingCalls = require("game.hgss.src.pokegear.IncomingCalls")

local T = {
  metadata = {
    tags = { "pokegear" },
  },
  tests = {},
}

local MOM_KEY = "custom.mom"
local TRAINER_KEY = "custom.trainer-plain"
local NEAR_KEY = "custom.trainer-near"
local FAR_KEY = "custom.trainer-far"
local MOM_TRIGGER = "mom.gift"

---@param path string
---@return table
local function visualRef(path)
  return { image = path, width = 32, height = 32, anchorX = 0, anchorY = 0 }
end

-- The required phone call-dim roles beside the panel stub: the suites
-- below never paint the phone, but the generated family identity
-- requires the dim roles on every validating manifest.
local function phoneDimSection()
  local section = {
    panel = visualRef("assets/generated/pokegear/phone-panel.png"),
    foregroundDim = {},
    foregroundDimChoice = {},
    dimShellForeground = {},
    listPaletteDim = {},
  }
  for skin = 0, 5 do
    local suffix = "-skin-" .. skin .. ".png"
    section.foregroundDim[skin] = visualRef("assets/generated/pokegear/phone-foreground-dim" .. suffix)
    section.foregroundDimChoice[skin] = visualRef("assets/generated/pokegear/phone-foreground-dim-choice" .. suffix)
    section.dimShellForeground[skin] = visualRef("assets/generated/pokegear/phone-dim-shell-foreground" .. suffix)
    local palette = {}
    for index = 1, 16 do
      palette[index] = { r = index, g = index, b = index }
    end
    section.listPaletteDim[skin] = palette
  end
  local dimSprites = {}
  for sequence = 1, 9 do
    dimSprites[sequence] = {
      frames = {
        {
          image = "assets/generated/pokegear/phone-sprite-dim-phone-" .. sequence .. "-1.png",
          width = 16,
          height = 16,
          anchorX = -8,
          anchorY = -8,
          duration = 1,
        },
      },
      playMode = "forward",
      loopStartFrameIdx = 0,
    }
  end
  section.spritesDim = { phone = dimSprites }
  return section
end

---@param manifest table<string, unknown>
---@return table
local function assertManifest(manifest)
  local record = PokegearAssetSchema.validate(manifest)
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  return record
end

---@param contacts table[]
---@param triggers table[]
---@return table
local function fixtureManifest(contacts, triggers)
  local order = {}
  for _, contact in ipairs(contacts) do
    order[#order + 1] = contact.key
  end
  return assertManifest({
    schema = "g4-pokegear-assets-v4",
    skins = { 0, 1, 2, 3, 4, 5 },
    shell = { foreground = visualRef("assets/generated/pokegear/shell-foreground-skin-0.png") },
    configure = { panel = visualRef("assets/generated/pokegear/configure-panel.png") },
    phone = phoneDimSection(),
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
  })
end

---@param minute integer
---@param second integer?
---@return table<string, integer>
local function moment(minute, second)
  return { year = 2024, month = 1, day = 8, hour = 10, minute = minute, second = second or 0 }
end

---@param mapKey string
---@return table<string, unknown>
local function opportunityOn(mapKey)
  return { mapKey = mapKey, movementState = "none", higherPriorityClaimed = false }
end

---@return table
local function silentAudio()
  local audio = { plays = {}, playing = false }
  function audio:playRing(sequence)
    self.plays[#self.plays + 1] = sequence
    self.playing = true
  end
  function audio:isRingPlaying()
    return self.playing == true
  end
  function audio:completeRing()
    self.playing = false
  end
  return audio
end

---@return table
local function recordingHost()
  local host = { opens = {} }
  function host:open(args)
    assert(type(args) == "table", "companion opens carry their request record")
    self.opens[#self.opens + 1] = args
    return { id = #self.opens }
  end
  function host:isActive()
    return false
  end
  return host
end

-- A coordinator over real companion providers with the given catalog
-- facts. Only the coordinator itself is the behaviour under test.
---@param seed integer
---@param contacts table[]
---@param triggers table[]
---@param setTriggers string[]
---@return table rig
local function freshRig(seed, contacts, triggers, setTriggers)
  local record = fixtureManifest(contacts, triggers)
  local state = PokegearState.new({ seed = seed }, { catalog = record.catalog })
  for _, contact in ipairs(contacts) do
    state:registerContact(contact.key)
  end
  for _, key in ipairs(setTriggers) do
    state:setTrigger(key, true)
  end
  local host = recordingHost()
  local audio = silentAudio()
  local scriptStarts = {}
  local calls = IncomingCalls.new({
    state = state,
    catalog = record.catalog,
    calendar = PokegearCalendar.new(state),
    random = PokegearRandom.new(seed),
    world = PhoneWorldContext.new({ state = state, flags = {} }),
    host = host,
    audio = audio,
    startCallScript = function()
      scriptStarts[#scriptStarts + 1] = true
      return "scene-" .. tostring(#scriptStarts)
    end,
    mapReceivesCalls = function()
      return true
    end,
  })
  return { calls = calls, state = state, record = record, host = host, audio = audio, scriptStarts = scriptStarts }
end

---@param calls table
local function driveEligible(calls)
  calls:onFieldClock(moment(0))
  calls:onFieldClock(moment(10))
  calls:onFieldClock(moment(20))
end

-- Scans one seed whose gate passes inside category zero, matching the
-- acceptance replay shape without reusing its exact seed.
---@return integer
local function findPassingSeed()
  for seed = 1, 100000 do
    local probe = PokegearRandom.new(seed)
    if probe:mt("probe") % 100 <= 50 and probe:lc("probe") % 1000 < 500 then
      return seed
    end
  end
  error("the seed scan finds no passing gate inside category zero", 0)
  return -1
end

-- Construction names its missing collaborators instead of staging a
-- half-owned coordinator.
function T.tests.incoming_call_construction_rejects_malformed_collaborators()
  local record = fixtureManifest(
    { { key = TRAINER_KEY, name = "JACE", sortWeight = 20, family = "trainer", entryType = 0, randomCallGroup = 0 } },
    {}
  )
  local state = PokegearState.new({ seed = 7 }, { catalog = record.catalog })
  local good = {
    state = state,
    catalog = record.catalog,
    calendar = PokegearCalendar.new(state),
    random = PokegearRandom.new(7),
    world = PhoneWorldContext.new({ state = state, flags = {} }),
    host = recordingHost(),
    audio = silentAudio(),
    startCallScript = function()
      return "scene-1"
    end,
    mapReceivesCalls = function()
      return true
    end,
  }
  Assert.throws(function()
    IncomingCalls.new({})
  end, "a missing state must fail")
  local broken = {}
  for key, value in pairs(good) do
    broken[key] = value
  end
  broken.audio = { playRing = true }
  Assert.throws(function()
    IncomingCalls.new(broken)
  end, "a malformed ring tone owner must fail")
  broken.audio = good.audio
  broken.host = {}
  Assert.throws(function()
    IncomingCalls.new(broken)
  end, "a malformed companion host must fail")
  broken.host = good.host
  broken.startCallScript = true
  Assert.throws(function()
    IncomingCalls.new(broken)
  end, "a missing scene-script starter must fail")
  local calls = IncomingCalls.new(good)
  calls:dispose()
end

-- The random pool only admits native pool caller types in the drawn
-- group: a mother-type contact never rings randomly, and a group-one
-- contact stays silent on a category-zero draw.
function T.tests.random_pool_admits_only_pool_types_in_the_drawn_group()
  local seed = findPassingSeed()
  local rig = freshRig(seed, {
    { key = MOM_KEY, name = "MOM", sortWeight = 10, family = "mother", entryType = 1, randomCallGroup = 0 },
    {
      key = "custom.trainer-late",
      name = "LATE",
      sortWeight = 20,
      family = "trainer",
      entryType = 0,
      randomCallGroup = 1,
    },
  }, {}, {})
  driveEligible(rig.calls)
  rig.calls:onOpportunity(opportunityOn("custom.new-bark-town"))
  Assert.isFalse(rig.calls:notification(), "no pool type in the drawn group stays silent")
  rig.calls:dispose()
end

-- A full recent-caller chunk stays bounded exactly like the source
-- SaveMisc add at launch: the candidate count captured at pick decides
-- whether the launch clears the chunk before recording or shifts its
-- oldest entry out.
function T.tests.full_chunks_clear_or_shift_instead_of_growing()
  local seed = findPassingSeed()
  -- Five group-zero candidates against a four-slot chunk: the pick leaves
  -- one uncovered caller, and the launch sees candidate count == size + 1
  -- so it clears the chunk before recording.
  local clearing = {
    { key = "custom.a", name = "A", sortWeight = 10, family = "trainer", entryType = 0, randomCallGroup = 0 },
    { key = "custom.b", name = "B", sortWeight = 20, family = "trainer", entryType = 0, randomCallGroup = 0 },
    { key = "custom.c", name = "C", sortWeight = 30, family = "trainer", entryType = 0, randomCallGroup = 0 },
    { key = "custom.d", name = "D", sortWeight = 40, family = "trainer", entryType = 0, randomCallGroup = 0 },
    { key = "custom.f", name = "F", sortWeight = 50, family = "trainer", entryType = 0, randomCallGroup = 0 },
    { key = "custom.e", name = "E", sortWeight = 60, family = "trainer", entryType = 0, randomCallGroup = 1 },
  }
  local rig = freshRig(seed, clearing, {}, {})
  rig.state:setCallHistory({
    [0] = { "custom.a", "custom.b", "custom.c", "custom.d" },
    [1] = { "custom.e" },
    [2] = {},
  })
  driveEligible(rig.calls)
  rig.calls:onOpportunity(opportunityOn("custom.new-bark-town"))
  Assert.notNil(rig.calls:notification(), "the uncovered caller rings")
  rig.calls:accept("field:test-parent")
  Assert.deepEqual(
    rig.state:readPhone().history,
    { [0] = { "custom.f" }, [1] = { "custom.e" }, [2] = {} },
    "the full chunk clears while the other chunk stays intact"
  )
  rig.calls:dispose()

  -- The shift branch needs a pool whose candidate count is not the chunk
  -- size plus one, so the launch keeps the chunk and drops its oldest
  -- recorded caller instead.
  local shifting = {
    { key = "custom.k1", name = "K1", sortWeight = 5, family = "trainer", entryType = 201, randomCallGroup = 0 },
    { key = "custom.k2", name = "K2", sortWeight = 6, family = "trainer", entryType = 201, randomCallGroup = 0 },
    { key = "custom.k3", name = "K3", sortWeight = 10, family = "trainer", entryType = 0, randomCallGroup = 0 },
    { key = "custom.k4", name = "K4", sortWeight = 20, family = "trainer", entryType = 0, randomCallGroup = 0 },
    { key = "custom.k5", name = "K5", sortWeight = 30, family = "trainer", entryType = 0, randomCallGroup = 0 },
  }
  local shiftingRig = freshRig(seed, shifting, {}, {})
  shiftingRig.state:setCallHistory({
    [0] = { "custom.k1", "custom.k2", "custom.k3", "custom.k4" },
    [1] = {},
    [2] = {},
  })
  driveEligible(shiftingRig.calls)
  shiftingRig.calls:onOpportunity(opportunityOn("custom.new-bark-town"))
  local ringing = shiftingRig.calls:notification()
  Assert.notNil(ringing, "the shifted pool still rings")
  assert(type(ringing) == "table", "ringing publishes its caller view")
  Assert.equal(ringing.contactKey, "custom.k5", "only the uncovered caller can ring")
  shiftingRig.calls:accept("field:test-parent")
  Assert.deepEqual(
    shiftingRig.state:readPhone().history[0],
    { "custom.k2", "custom.k3", "custom.k4", "custom.k5" },
    "the full chunk shifts its oldest caller out"
  )
  shiftingRig.calls:dispose()
end

-- The source candidate count is taken before the map exclusion, so a
-- same-map caller still counts toward the full-chunk decision: a chunk
-- holding the other four candidates stays whole at pick and clears only
-- when the launch records, instead of being wiped at pick.
function T.tests.the_candidate_count_covers_same_map_callers()
  local seed = findPassingSeed()
  local contacts = {
    { key = "custom.a", name = "A", sortWeight = 10, family = "trainer", entryType = 0, randomCallGroup = 0 },
    { key = "custom.b", name = "B", sortWeight = 20, family = "trainer", entryType = 0, randomCallGroup = 0 },
    { key = "custom.c", name = "C", sortWeight = 30, family = "trainer", entryType = 0, randomCallGroup = 0 },
    {
      key = "custom.d",
      name = "D",
      sortWeight = 40,
      family = "trainer",
      entryType = 0,
      randomCallGroup = 0,
      place = "custom.new-bark-town",
    },
    { key = "custom.e", name = "E", sortWeight = 50, family = "trainer", entryType = 0, randomCallGroup = 0 },
  }
  local rig = freshRig(seed, contacts, {}, {})
  rig.state:setCallHistory({ [0] = { "custom.a", "custom.b", "custom.c", "custom.d" }, [1] = {}, [2] = {} })
  driveEligible(rig.calls)
  rig.calls:onOpportunity(opportunityOn("custom.new-bark-town"))
  local ringing = rig.calls:notification()
  Assert.notNil(ringing, "the only off-map unrecorded caller rings")
  assert(type(ringing) == "table", "ringing publishes its caller view")
  Assert.equal(ringing.contactKey, "custom.e", "the same-map candidate never rings")
  Assert.deepEqual(
    rig.state:readPhone().history[0],
    { "custom.a", "custom.b", "custom.c", "custom.d" },
    "the pick alone leaves the chunk whole"
  )
  rig.calls:accept("field:test-parent")
  Assert.deepEqual(
    rig.state:readPhone().history[0],
    { "custom.e" },
    "the launch clears the covered chunk before recording"
  )
  rig.calls:dispose()
end

-- A fired trigger carries the source script identity into the host
-- request: trigger rings launch with isScriptedCall 3 and the
-- trigger's script, matching GearPhoneRingManager_SetCallerParams.
function T.tests.trigger_rings_carry_their_source_script_identity()
  local rig = freshRig(4242, {
    { key = MOM_KEY, name = "MOM", sortWeight = 10, family = "mother", entryType = 1, randomCallGroup = 0 },
  }, {
    { key = "custom.gift", contact = MOM_KEY, slot = 12, forcePickUp = false, callScriptID = 27 },
  }, { "custom.gift" })
  driveEligible(rig.calls)
  rig.calls:onOpportunity(opportunityOn("custom.new-bark-town"))
  Assert.notNil(rig.calls:notification(), "the scripted trigger rings")
  rig.calls:accept("field:test-parent")
  local request = assert(rig.host.opens[1], "acceptance opens the companion host").request
  Assert.equal(request.isScriptedCall, 3, "trigger calls launch scripted")
  Assert.equal(request.callScriptID, 27, "trigger calls carry their source script")
  rig.calls:dispose()
end

-- Only the Day-Care Man trigger requires a registered number: his ring
-- stays silent until registered, while other triggers ring for
-- unregistered callers exactly like the source pick rule.
function T.tests.only_the_daycare_man_trigger_requires_registration()
  local contacts = {
    { key = "custom.daycare-man", name = "MAN", sortWeight = 10, family = "daycare", id = 6 },
    { key = TRAINER_KEY, name = "JACE", sortWeight = 20, family = "trainer", entryType = 0, randomCallGroup = 0 },
  }
  local triggers = {
    { key = "custom.man-egg", contact = "custom.daycare-man", slot = 5, forcePickUp = false },
    { key = "custom.plain", contact = TRAINER_KEY, forcePickUp = false, slot = 6 },
  }
  local record = fixtureManifest(contacts, triggers)
  local state = PokegearState.new({ seed = 4242 }, { catalog = record.catalog })
  state:registerContact(TRAINER_KEY)
  state:setTrigger("custom.man-egg", true)
  state:setTrigger("custom.plain", true)
  local calls = IncomingCalls.new({
    state = state,
    catalog = record.catalog,
    calendar = PokegearCalendar.new(state),
    random = PokegearRandom.new(4242),
    world = PhoneWorldContext.new({ state = state, flags = {} }),
    host = recordingHost(),
    audio = silentAudio(),
    startCallScript = function()
      return "scene-test"
    end,
    mapReceivesCalls = function()
      return true
    end,
  })
  driveEligible(calls)
  calls:onOpportunity(opportunityOn("custom.new-bark-town"))
  local ringing = calls:notification()
  Assert.notNil(ringing, "the unregistered ordinary trigger still rings")
  assert(type(ringing) == "table", "ringing publishes its caller view")
  Assert.equal(ringing.contactKey, TRAINER_KEY, "the daycare-man trigger stays silent until registered")
  calls:dispose()
end

-- An expired ring quiets and restarts the whole manager: the view
-- clears after thirty-one live seconds and the reset cooldown refuses
-- an immediate re-ring.
function T.tests.an_expired_ring_quiets_and_restarts_the_cooldown()
  local seed = findPassingSeed()
  local contacts =
    { { key = TRAINER_KEY, name = "JACE", sortWeight = 20, family = "trainer", entryType = 0, randomCallGroup = 0 } }
  local rig = freshRig(seed, contacts, {}, {})
  driveEligible(rig.calls)
  rig.calls:onOpportunity(opportunityOn("custom.new-bark-town"))
  Assert.notNil(rig.calls:notification(), "the eligible call rings")
  rig.calls:onFieldClock(moment(20, 1))
  Assert.notNil(rig.calls:notification(), "the anchored ring still rings")
  rig.calls:onFieldClock(moment(20, 32))
  Assert.isFalse(rig.calls:notification(), "thirty-one live seconds expire the ring")
  rig.calls:onOpportunity(opportunityOn("custom.new-bark-town"))
  Assert.isFalse(rig.calls:notification(), "the reset cooldown refuses an instant re-ring")
  rig.calls:dispose()
end

-- A map whose header forbids incoming calls refuses every call before the
-- gate draw and every trigger, like the source TryStartCall: nothing rings,
-- the pending trigger keeps its flag, and a forced trigger does not start
-- its scene script either.
function T.tests.a_map_that_forbids_incoming_calls_stays_silent()
  local contacts =
    { { key = TRAINER_KEY, name = "JACE", sortWeight = 20, family = "trainer", entryType = 0, randomCallGroup = 0 } }
  local triggers = {
    { key = "custom.plain", contact = TRAINER_KEY, forcePickUp = false, slot = 6 },
    {
      key = "custom.forced",
      contact = TRAINER_KEY,
      slot = 7,
      callScriptID = 142,
      forcePickUp = true,
    },
  }
  local record = fixtureManifest(contacts, triggers)
  local state = PokegearState.new({ seed = 4242 }, { catalog = record.catalog })
  state:registerContact(TRAINER_KEY)
  state:setTrigger("custom.plain", true)
  local scriptStarts = 0
  local calls = IncomingCalls.new({
    state = state,
    catalog = record.catalog,
    calendar = PokegearCalendar.new(state),
    random = PokegearRandom.new(4242),
    world = PhoneWorldContext.new({ state = state, flags = {} }),
    host = recordingHost(),
    audio = silentAudio(),
    startCallScript = function()
      scriptStarts = scriptStarts + 1
      return "scene-covered"
    end,
    mapReceivesCalls = function()
      return false
    end,
  })
  driveEligible(calls)
  calls:onOpportunity(opportunityOn("custom.new-bark-town"))
  Assert.isFalse(calls:notification(), "a map without incoming coverage never rings")
  Assert.isFalse(calls:hasPendingCall(), "a silent map stages no caller")
  Assert.isTrue(state:readPhone().triggers["custom.plain"] == true, "the refused trigger keeps its flag")
  state:setTrigger("custom.forced", true)
  calls:onOpportunity(opportunityOn("custom.new-bark-town"))
  Assert.equal(scriptStarts, 0, "a map without incoming coverage starts no forced call script")
  Assert.isTrue(state:readPhone().triggers["custom.forced"] == true, "the refused forced trigger keeps its flag")
  calls:dispose()
end

-- The launch boundary restarts the eligibility clock: the source
-- gearRingingManagerReset runs when the app launch reads the caller
-- params, so an answered call cannot be followed by a re-ring inside the
-- next ten minutes. A scripted setup consumes the same boundary.
function T.tests.a_launch_restarts_the_eligibility_clock_exactly_once()
  local contacts =
    { { key = TRAINER_KEY, name = "JACE", sortWeight = 20, family = "trainer", entryType = 0, randomCallGroup = 0 } }
  local triggers = {
    { key = "custom.first", contact = TRAINER_KEY, forcePickUp = false, slot = 6 },
    { key = "custom.second", contact = TRAINER_KEY, forcePickUp = false, slot = 7 },
  }
  local rig = freshRig(4242, contacts, triggers, { "custom.first" })
  driveEligible(rig.calls)
  rig.calls:onOpportunity(opportunityOn("custom.new-bark-town"))
  Assert.notNil(rig.calls:notification(), "the eligible trigger rings")
  local request = rig.calls:takePendingCall()
  assert(type(request) == "table", "the launch consumes the ringing caller")
  Assert.isNil(rig.state:readPhone().triggers["custom.first"], "the launch clears the trigger flag")
  Assert.isFalse(rig.calls:notification(), "the consumed request leaves no window behind")

  -- A surviving trigger proves the clock, not silence, refuses the ring.
  rig.state:setTrigger("custom.second", true)
  rig.calls:onFieldClock(moment(29))
  rig.calls:onOpportunity(opportunityOn("custom.new-bark-town"))
  Assert.isFalse(rig.calls:notification(), "nine fresh minutes refuse the ring")
  rig.calls:onFieldClock(moment(39))
  rig.calls:onOpportunity(opportunityOn("custom.new-bark-town"))
  Assert.notNil(rig.calls:notification(), "ten fresh minutes ring the surviving trigger")

  -- A scripted setup consumes the same boundary: the manager refuses a
  -- second pending request while one waits, and the launch clears it.
  local scripted = freshRig(4242, contacts, triggers, {})
  scripted.calls:stageCall({ contact = TRAINER_KEY, isScriptedCall = 2, callScriptID = 0 })
  Assert.isTrue(scripted.calls:hasPendingCall(), "a scripted setup publishes its pending caller")
  Assert.throws(function()
    scripted.calls:stageCall({ contact = TRAINER_KEY, isScriptedCall = 2, callScriptID = 1 })
  end, "one pending call owns the phone line")
  local pending = scripted.calls:takePendingCall()
  assert(type(pending) == "table", "the launch consumes the scripted request")
  Assert.equal(pending.contactKey, TRAINER_KEY, "the scripted request names its caller")
  Assert.equal(pending.isScriptedCall, 2, "the scripted request carries its marker")
  Assert.equal(pending.callScriptID, 0, "the scripted request carries its script identity")
  -- A marker that is neither 3 nor 0 closes neither boundary half: a
  -- script setup carries no trigger and no chunk, so nothing moves.
  Assert.equal(#scripted.state:readPhone().history[0], 0, "a scripted launch records no recent caller")
  Assert.deepEqual(scripted.state:readPhone().triggers, {}, "a scripted launch clears no trigger")
  Assert.isFalse(scripted.calls:hasPendingCall(), "the consumed scripted request leaves nothing behind")
  Assert.isNil(scripted.calls:takePendingCall(), "the launch boundary consumes exactly once")
  scripted.calls:dispose()
  rig.calls:dispose()
end

-- A civil-day advance drives the Kenji errand exactly like the
-- source daily update: a covering wait decrements with the activity
-- cleared and the invitation kept, while an expired wait rolls a
-- fresh 1-6 day wait and clears the staged invitation and gift. The
-- field's daily dispatcher owns the day call, so the observation itself
-- never advances the errand.
function T.tests.a_civil_day_advance_drives_the_kenji_errand_wait()
  local KENJI_KEY = "custom.kenji"
  local contacts = {
    { key = KENJI_KEY, name = "KENJI", sortWeight = 20, family = "kenji", entryType = 0, randomCallGroup = 0 },
  }
  local rig = freshRig(4242, contacts, {}, {})
  rig.state:setKenjiErrand(3, true)
  rig.state:setRematch(KENJI_KEY, { stage = 1, wins = 0 })
  rig.state:setContactReward(KENJI_KEY, { item = "ITEM_PROTEIN", quantity = 1 })
  rig.calls:onFieldClock({ year = 2024, month = 1, day = 8, hour = 23, minute = 59, second = 0 })
  rig.calls:onFieldClock({ year = 2024, month = 1, day = 9, hour = 0, minute = 1, second = 0 })
  Assert.equal(rig.state:readPhone().kenji.waitDays, 3, "the observation alone advances no errand wait")
  rig.calls:advanceDays(1)
  local covered = rig.state:readPhone()
  Assert.equal(covered.kenji.waitDays, 2, "a covering wait decrements by the elapsed day")
  Assert.isFalse(covered.kenji.active, "the daily update always clears the activity flag")
  Assert.notNil(covered.rematches[KENJI_KEY], "a covering wait keeps the staged invitation")
  Assert.notNil(covered.contacts[KENJI_KEY].reward, "a covering wait keeps the staged gift")
  rig.state:setKenjiErrand(1, true)
  rig.calls:advanceDays(2)
  local expired = rig.state:readPhone()
  local reroll = expired.kenji.waitDays
  Assert.isTrue(reroll >= 1 and reroll <= 6, "an expired wait rolls a fresh one-to-six day wait")
  Assert.isFalse(expired.kenji.active, "an expired wait clears the activity flag")
  Assert.isNil(expired.rematches[KENJI_KEY], "an expired wait clears the staged invitation")
  Assert.isNil(expired.contacts[KENJI_KEY].reward, "an expired wait clears the staged gift")
  rig.calls:dispose()
end

-- Fresh owners count live minutes from their initial calendar sample,
-- while restored owners discard only the first offline report.
function T.tests.cooldown_counts_from_first_live_minute_for_fresh_and_restored_owners()
  local seed = findPassingSeed()
  local contacts =
    { { key = TRAINER_KEY, name = "JACE", sortWeight = 20, family = "trainer", entryType = 0, randomCallGroup = 0 } }
  local fresh = freshRig(seed, contacts, {}, {})
  fresh.calls:onFieldClock(moment(0))
  fresh.calls:onFieldClock(moment(9))
  fresh.calls:onOpportunity(opportunityOn("custom.new-bark-town"))
  Assert.isFalse(fresh.calls:notification(), "fresh play is not eligible before ten live minutes")
  fresh.calls:onFieldClock(moment(10))
  fresh.calls:onOpportunity(opportunityOn("custom.new-bark-town"))
  Assert.isTrue(type(fresh.calls:notification()) == "table", "fresh play is eligible at ten continuous live minutes")
  fresh.calls:dispose()

  local restoredSource = freshRig(seed, contacts, {}, {})
  local base = moment(0)
  restoredSource.calls:onFieldClock(base)
  local bucket = restoredSource.state:capture()
  local restoredState = PokegearState.restore(bucket, { catalog = restoredSource.record.catalog })
  local restoredCalendar = PokegearCalendar.new(restoredState)
  local observeCount = 0
  local observeField = restoredCalendar.observeField
  function restoredCalendar:observeField(sample)
    observeCount = observeCount + 1
    return observeField(self, sample)
  end
  local restored = IncomingCalls.new({
    state = restoredState,
    catalog = restoredSource.record.catalog,
    calendar = restoredCalendar,
    random = PokegearRandom.new(seed),
    world = PhoneWorldContext.new({ state = restoredState, flags = {} }),
    host = recordingHost(),
    audio = silentAudio(),
    startCallScript = function()
      return "scene-test"
    end,
    mapReceivesCalls = function()
      return true
    end,
  })
  local offline = { year = 2024, month = 1, day = 11, hour = 10, minute = 0, second = 0 }
  local calendarBeforeOffline = restoredState:readCalendar()
  local dailyBeforeOffline = restoredState:readDailyIdentity()
  restored:onFieldClock(offline)
  local calendarAfterOffline = restoredState:readCalendar()
  local dailyAfterOffline = restoredState:readDailyIdentity()
  Assert.equal(
    calendarAfterOffline.daySerial - calendarBeforeOffline.daySerial,
    3,
    "the restored calendar still processes three offline days"
  )
  Assert.deepEqual(
    calendarAfterOffline.checkpoint,
    offline,
    "the restored checkpoint still advances to the offline sample"
  )
  Assert.isTrue(
    dailyAfterOffline.dailyGroupSeed ~= dailyBeforeOffline.dailyGroupSeed,
    "the restored offline days still advance the persisted daily identity"
  )
  restored:onOpportunity(opportunityOn("custom.new-bark-town"))
  Assert.isFalse(restored:notification(), "restored offline minutes do not count toward call eligibility")
  Assert.equal(observeCount, 1, "one field clock tick observes the calendar once")
  Assert.deepEqual(restoredState:readCalendar(), calendarAfterOffline, "reading status does not advance the calendar")
  restored:onFieldClock({ year = 2024, month = 1, day = 11, hour = 10, minute = 9, second = 0 })
  restored:onOpportunity(opportunityOn("custom.new-bark-town"))
  Assert.isFalse(restored:notification(), "restored play needs ten live minutes after the offline sample")
  restored:onFieldClock({ year = 2024, month = 1, day = 11, hour = 10, minute = 10, second = 0 })
  restored:onOpportunity(opportunityOn("custom.new-bark-town"))
  Assert.isTrue(type(restored:notification()) == "table", "restored play is eligible after ten live minutes")
  restored:dispose()
  restoredSource.calls:dispose()

  -- A restored same-time opening sample still consumes the one-shot
  -- decision, so its next positive minute is counted.
  local sameTimeSource = freshRig(seed, contacts, {}, {})
  sameTimeSource.calls:onFieldClock(base)
  local sameTimeBucket = sameTimeSource.state:capture()
  local sameTimeState = PokegearState.restore(sameTimeBucket, { catalog = sameTimeSource.record.catalog })
  local sameTime = IncomingCalls.new({
    state = sameTimeState,
    catalog = sameTimeSource.record.catalog,
    calendar = PokegearCalendar.new(sameTimeState),
    random = PokegearRandom.new(seed),
    world = PhoneWorldContext.new({ state = sameTimeState, flags = {} }),
    host = recordingHost(),
    audio = silentAudio(),
    startCallScript = function()
      return "scene-test"
    end,
    mapReceivesCalls = function()
      return true
    end,
  })
  sameTime:onFieldClock(base)
  sameTime:onFieldClock(moment(1))
  sameTime:onFieldClock(moment(9))
  sameTime:onOpportunity(opportunityOn("custom.new-bark-town"))
  Assert.isFalse(sameTime:notification(), "the restored owner remains below ten after nine live minutes")
  sameTime:onFieldClock(moment(10))
  sameTime:onOpportunity(opportunityOn("custom.new-bark-town"))
  Assert.isTrue(type(sameTime:notification()) == "table", "the first live minute after a zero restored sample counts")
  sameTime:dispose()
  sameTimeSource.calls:dispose()

  -- A backward first report also consumes the opening decision; time
  -- after the calendar rebases is live and can fill the threshold.
  local backwardSource = freshRig(seed, contacts, {}, {})
  backwardSource.calls:onFieldClock(base)
  local backwardBucket = backwardSource.state:capture()
  local backwardState = PokegearState.restore(backwardBucket, { catalog = backwardSource.record.catalog })
  local backward = IncomingCalls.new({
    state = backwardState,
    catalog = backwardSource.record.catalog,
    calendar = PokegearCalendar.new(backwardState),
    random = PokegearRandom.new(seed),
    world = PhoneWorldContext.new({ state = backwardState, flags = {} }),
    host = recordingHost(),
    audio = silentAudio(),
    startCallScript = function()
      return "scene-test"
    end,
    mapReceivesCalls = function()
      return true
    end,
  })
  backward:onFieldClock({ year = 2024, month = 1, day = 8, hour = 9, minute = 59, second = 0 })
  backward:onFieldClock({ year = 2024, month = 1, day = 8, hour = 10, minute = 8, second = 0 })
  backward:onOpportunity(opportunityOn("custom.new-bark-town"))
  Assert.isFalse(backward:notification(), "backward time does not count toward eligibility before ten live minutes")
  backward:onFieldClock({ year = 2024, month = 1, day = 8, hour = 10, minute = 9, second = 0 })
  backward:onOpportunity(opportunityOn("custom.new-bark-town"))
  Assert.isTrue(type(backward:notification()) == "table", "ten minutes after a backward opening sample qualify exactly")
  backward:dispose()
  backwardSource.calls:dispose()
end

-- Corrupt selected facts fail with attribution instead of selecting a
-- plausible caller: a corrupt pickup flag and a trigger naming a contact
-- outside the catalog both fail their manifest and their trigger key.
function T.tests.corrupt_selected_trigger_facts_fail_with_attribution()
  local contacts =
    { { key = TRAINER_KEY, name = "JACE", sortWeight = 20, family = "trainer", entryType = 0, randomCallGroup = 0 } }
  local invalidPickup = fixtureManifest(contacts, {})
  invalidPickup.catalog.callTriggers = {
    { key = "custom.bad-kind", contact = TRAINER_KEY, slot = 1, forcePickUp = "yes" },
  }
  Assert.isNil(PokegearAssetSchema.validate(invalidPickup), "the strict schema rejects a non-boolean pickup flag")
  local danglingContact = fixtureManifest(contacts, {})
  danglingContact.catalog.callTriggers = {
    { key = "custom.ghost", contact = "custom.ghost", slot = 1, forcePickUp = false },
  }
  Assert.isNil(PokegearAssetSchema.validate(danglingContact), "the strict schema rejects dangling contacts")
end

-- Callers on the opportunity map stay silent while callers elsewhere
-- ring: the near caller is skipped at its own map and rings the far map
-- once the far caller has been heard.
function T.tests.callers_on_the_current_map_stay_silent_while_elsewhere_rings()
  local seed = findPassingSeed()
  local contacts = {
    {
      key = NEAR_KEY,
      name = "NEAR",
      sortWeight = 10,
      family = "trainer",
      entryType = 0,
      randomCallGroup = 0,
      place = "custom.new-bark-town",
    },
    {
      key = FAR_KEY,
      name = "FAR",
      sortWeight = 20,
      family = "trainer",
      entryType = 0,
      randomCallGroup = 0,
      place = "custom.far-town",
    },
  }
  local rig = freshRig(seed, contacts, {}, {})
  driveEligible(rig.calls)
  rig.calls:onOpportunity(opportunityOn("custom.new-bark-town"))
  local first = rig.calls:notification()
  Assert.notNil(first, "the far caller rings at the near map")
  assert(type(first) == "table", "ringing publishes its caller view")
  Assert.equal(first.contactKey, FAR_KEY, "the same-map caller is excluded from the pool")
  rig.calls:accept("field:test-parent")
  rig.calls:onFieldClock(moment(30))
  rig.calls:onOpportunity(opportunityOn("custom.far-town"))
  local second = rig.calls:notification()
  Assert.notNil(second, "the near caller rings at the far map")
  assert(type(second) == "table", "ringing publishes its caller view")
  Assert.equal(second.contactKey, NEAR_KEY, "leaving the caller map restores eligibility")
  rig.calls:dispose()
end

-- A pool fully covered by call history resets its covering entries
-- before filtering, so a heard pool can ring again instead of draining
-- the cooldown into silence. The reset writes at pick; the picked caller
-- lands in the journal only at the launch, like the source.
function T.tests.a_history_covered_pool_resets_before_filtering()
  local seed = findPassingSeed()
  local contacts = {
    { key = NEAR_KEY, name = "NEAR", sortWeight = 10, family = "trainer", entryType = 0, randomCallGroup = 0 },
    { key = FAR_KEY, name = "FAR", sortWeight = 20, family = "trainer", entryType = 0, randomCallGroup = 0 },
  }
  local rig = freshRig(seed, contacts, {}, {})
  rig.state:setCallHistory({ [0] = { NEAR_KEY, FAR_KEY }, [1] = {}, [2] = {} })
  driveEligible(rig.calls)
  rig.calls:onOpportunity(opportunityOn("custom.new-bark-town"))
  local ringing = rig.calls:notification()
  Assert.notNil(ringing, "the covered pool resets and rings instead of staying silent")
  assert(type(ringing) == "table", "ringing publishes its caller view")
  Assert.isTrue(
    ringing.contactKey == NEAR_KEY or ringing.contactKey == FAR_KEY,
    "the reset pool still picks a catalogued caller"
  )
  Assert.equal(#rig.state:readPhone().history[0], 0, "the pick alone records no caller")
  rig.calls:accept("field:test-parent")
  local journal = rig.state:readPhone().history
  Assert.equal(#journal[0], 1, "the launch records into the reset chunk")
  Assert.equal(journal[0][1], ringing.contactKey, "the reset pool records exactly its picked caller")
  rig.calls:dispose()
end

-- Saving keeps the durable trigger and history facts while dropping the
-- transient ring: after a restore the trigger re-arms with fresh minutes
-- instead of resuming a phantom call.
function T.tests.saved_companions_keep_triggers_and_history_but_drop_the_ring()
  local seed = findPassingSeed()
  local contacts = {
    { key = MOM_KEY, name = "MOM", sortWeight = 10, family = "mother" },
    { key = TRAINER_KEY, name = "JACE", sortWeight = 20, family = "trainer", entryType = 0, randomCallGroup = 0 },
  }
  local rig = freshRig(seed, contacts, {
    { key = MOM_TRIGGER, contact = MOM_KEY, slot = 12, forcePickUp = false },
  }, { MOM_TRIGGER })
  local random = PokegearRandom.new(seed)
  rig.calls = IncomingCalls.new({
    state = rig.state,
    catalog = rig.record.catalog,
    calendar = PokegearCalendar.new(rig.state),
    random = random,
    world = PhoneWorldContext.new({ state = rig.state, flags = {} }),
    host = rig.host,
    audio = silentAudio(),
    startCallScript = function()
      return "scene-test"
    end,
    mapReceivesCalls = function()
      return true
    end,
  })
  driveEligible(rig.calls)
  rig.calls:onOpportunity(opportunityOn("custom.new-bark-town"))
  Assert.notNil(rig.calls:notification(), "the event trigger rings before the save")
  local bucket = rig.state:capture()
  bucket.random = random:capture()
  local restored = PokegearState.restore(bucket, { catalog = rig.record.catalog })
  Assert.isTrue(restored:readPhone().triggers[MOM_TRIGGER] == true, "the restore keeps the pending trigger")
  local live = PokegearRandom.restore(bucket.random)
  local host = recordingHost()
  local returned = IncomingCalls.new({
    state = restored,
    catalog = rig.record.catalog,
    calendar = PokegearCalendar.new(restored),
    random = live,
    world = PhoneWorldContext.new({ state = restored, flags = {} }),
    host = host,
    audio = silentAudio(),
    startCallScript = function()
      return "scene-test"
    end,
    mapReceivesCalls = function()
      return true
    end,
  })
  Assert.isFalse(returned:notification(), "the restore drops the transient ring")
  returned:onFieldClock(moment(20))
  returned:onFieldClock(moment(30))
  returned:onFieldClock(moment(40))
  returned:onOpportunity(opportunityOn("custom.new-bark-town"))
  local rearmed = returned:notification()
  Assert.notNil(rearmed, "fresh minutes re-arm the surviving trigger after a reload")
  assert(type(rearmed) == "table", "ringing publishes its caller view")
  Assert.equal(rearmed.contactKey, MOM_KEY, "the re-armed ring still names the trigger owner")
  Assert.equal(#host.opens, 0, "re-arming opens no companion modal on its own")
  returned:dispose()
  rig.calls:dispose()
end

-- Accepting without a ring fails, disposal is idempotent, and disposed
-- coordinators stay quiet instead of acting on borrowed owners.
function T.tests.quiet_disposal_and_no_acceptance_without_a_ring()
  local rig = freshRig(
    4242,
    { { key = TRAINER_KEY, name = "JACE", sortWeight = 20, family = "trainer", entryType = 0, randomCallGroup = 0 } },
    {},
    {}
  )
  Assert.throws(function()
    rig.calls:accept("field:test-parent")
  end, "accepting without a ring must fail")
  rig.calls:dispose()
  rig.calls:dispose()
  Assert.isFalse(rig.calls:notification(), "a disposed coordinator stays quiet")
  Assert.throws(function()
    rig.calls:onFieldClock(moment(30))
  end, "a disposed coordinator takes no clock")
  Assert.throws(function()
    rig.calls:onOpportunity(opportunityOn("custom.new-bark-town"))
  end, "a disposed coordinator takes no opportunity")
end

-- The source launch boundary reads isScriptedCall, never a trigger
-- classification: a trigger launch (marker 3) clears the trigger it
-- launched and records no recent caller, exactly like
-- FieldSystem_InitPokegearArgs.
function T.tests.a_trigger_launch_clears_its_flag_and_records_no_caller()
  local rig = freshRig(4242, {
    { key = MOM_KEY, name = "MOM", sortWeight = 10, family = "mother" },
    { key = TRAINER_KEY, name = "JACE", sortWeight = 20, family = "trainer", entryType = 0, randomCallGroup = 0 },
  }, { { key = "custom.callback", contact = TRAINER_KEY, forcePickUp = false, slot = 1 } }, { "custom.callback" })
  driveEligible(rig.calls)
  rig.calls:onOpportunity(opportunityOn("custom.new-bark-town"))
  local ringing = rig.calls:notification()
  Assert.notNil(ringing, "the trigger rings")
  assert(type(ringing) == "table", "ringing publishes its caller view")
  Assert.equal(ringing.contactKey, TRAINER_KEY, "the trigger names its caller")
  rig.calls:accept("field:test-parent")
  Assert.equal(#rig.host.opens, 1, "acceptance enters the companion host exactly once")
  Assert.equal(rig.state:readPhone().triggers["custom.callback"], nil, "the launch clears its own trigger flag")
  local journal = rig.state:readPhone().history
  for chunk = 0, 2 do
    Assert.equal(#journal[chunk], 0, "a trigger launch records no recent caller in chunk " .. chunk)
  end
  Assert.isFalse(rig.calls:notification(), "acceptance ends the ring")
  rig.calls:dispose()
end

-- A forced trigger answers itself the way the source does: the caller
-- lands on the manager (so the caller window shows) and the field starts
-- the standard-bank call scene script, which is what rings and launches the
-- call. Nothing opens here, the manager starts no tone loop of its own, and
-- the trigger flag clears at the launch boundary rather than at the trigger.
function T.tests.a_forced_trigger_starts_the_source_call_scene_script()
  local rig = freshRig(4242, {
    { key = MOM_KEY, name = "MOM", sortWeight = 10, family = "mother" },
    { key = TRAINER_KEY, name = "JACE", sortWeight = 20, family = "trainer", entryType = 0, randomCallGroup = 0 },
  }, {
    {
      key = "custom.forced",
      contact = TRAINER_KEY,
      slot = 7,
      callScriptID = 142,
      forcePickUp = true,
    },
  }, { "custom.forced" })
  driveEligible(rig.calls)
  rig.calls:onOpportunity(opportunityOn("custom.new-bark-town"))
  Assert.equal(#rig.scriptStarts, 1, "a forced trigger starts the source call scene script")
  Assert.equal(#rig.host.opens, 0, "the trigger itself opens nothing")
  local notice = rig.calls:notification()
  assert(type(notice) == "table", "the forced caller window publishes while its scene script rings")
  Assert.equal(notice.contactKey, TRAINER_KEY, "the forced window names its caller")
  Assert.equal(#rig.audio.plays, 0, "the manager starts no tone loop behind a forced call")
  Assert.isTrue(
    rig.state:readPhone().triggers["custom.forced"] == true,
    "the forced trigger keeps its flag until the launch reads it"
  )
  local pending = rig.calls:takePendingCall()
  assert(type(pending) == "table", "the launch consumes the pending forced caller")
  Assert.equal(pending.contactKey, TRAINER_KEY, "the pending request names its caller")
  Assert.equal(pending.isScriptedCall, 3, "the pending request carries the scripted marker")
  Assert.equal(pending.callScriptID, 142, "the pending request carries the trigger script identity")
  Assert.isNil(rig.state:readPhone().triggers["custom.forced"], "the launch clears the trigger flag")
  Assert.isFalse(rig.calls:notification(), "the consumed request leaves no window behind")
  rig.calls:dispose()
end

return T
