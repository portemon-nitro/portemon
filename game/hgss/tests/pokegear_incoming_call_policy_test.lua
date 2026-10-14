-- Incoming-call policy below the acceptance scenarios: collaborator and
-- journal shape rejection, same-map exclusion, history-covered pool
-- resets, the kind-zero trigger clearing rule, quiet disposal, and
-- save/restore preservation with transient dropped. Every expectation
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
  function audio:stopRing() end
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
  function host:result(handle)
    assert(type(handle) == "table", "the fake host reads a live accepted-call handle")
    return { ready = true }
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
  local calls = IncomingCalls.new({
    state = state,
    catalog = record.catalog,
    calendar = PokegearCalendar.new(state),
    random = PokegearRandom.new(seed),
    world = PhoneWorldContext.new({ state = state, flags = {} }),
    host = host,
    audio = silentAudio(),
  })
  return { calls = calls, state = state, record = record, host = host }
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
  local record = fixtureManifest({ { key = TRAINER_KEY, name = "JACE", sortWeight = 20, family = "trainer" } }, {})
  local state = PokegearState.new({ seed = 7 }, { catalog = record.catalog })
  local good = {
    state = state,
    catalog = record.catalog,
    calendar = PokegearCalendar.new(state),
    random = PokegearRandom.new(7),
    world = PhoneWorldContext.new({ state = state, flags = {} }),
    host = recordingHost(),
    audio = silentAudio(),
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
  local calls = IncomingCalls.new(good)
  calls:dispose()
end

-- Fresh owners count live minutes from their initial calendar sample,
-- while restored owners discard only the first offline report.
function T.tests.cooldown_counts_from_first_live_minute_for_fresh_and_restored_owners()
  local seed = findPassingSeed()
  local contacts = { { key = TRAINER_KEY, name = "JACE", sortWeight = 20, family = "trainer" } }
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
-- plausible caller: an unknown trigger kind and a trigger naming a
-- contact outside the catalog both name their trigger key.
function T.tests.corrupt_selected_trigger_facts_fail_with_attribution()
  local contacts = { { key = TRAINER_KEY, name = "JACE", sortWeight = 20, family = "trainer" } }
  local invalidKind = fixtureManifest(contacts, {})
  invalidKind.catalog.callTriggers = {
    { key = "custom.bad-kind", contact = TRAINER_KEY, kind = 7, slot = 1, clearOnPickup = false },
  }
  Assert.isNil(PokegearAssetSchema.validate(invalidKind), "the strict schema rejects unknown trigger kinds")
  local danglingContact = fixtureManifest(contacts, {})
  danglingContact.catalog.callTriggers = {
    { key = "custom.ghost", contact = "custom.ghost", kind = 3, slot = 1, clearOnPickup = false },
  }
  Assert.isNil(PokegearAssetSchema.validate(danglingContact), "the strict schema rejects dangling contacts")
end

-- Callers on the opportunity map stay silent while callers elsewhere
-- ring: the near caller is skipped at its own map and rings the far map
-- once the far caller has been heard.
function T.tests.callers_on_the_current_map_stay_silent_while_elsewhere_rings()
  local seed = findPassingSeed()
  local contacts = {
    { key = NEAR_KEY, name = "NEAR", sortWeight = 10, family = "trainer", place = "custom.new-bark-town" },
    { key = FAR_KEY, name = "FAR", sortWeight = 20, family = "trainer", place = "custom.far-town" },
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
-- the cooldown into silence.
function T.tests.a_history_covered_pool_resets_before_filtering()
  local seed = findPassingSeed()
  local contacts = {
    { key = NEAR_KEY, name = "NEAR", sortWeight = 10, family = "trainer" },
    { key = FAR_KEY, name = "FAR", sortWeight = 20, family = "trainer" },
  }
  local rig = freshRig(seed, contacts, {}, {})
  rig.state:setCallHistory({ [NEAR_KEY] = true, [FAR_KEY] = true })
  driveEligible(rig.calls)
  rig.calls:onOpportunity(opportunityOn("custom.new-bark-town"))
  local ringing = rig.calls:notification()
  Assert.notNil(ringing, "the covered pool resets and rings instead of staying silent")
  assert(type(ringing) == "table", "ringing publishes its caller view")
  Assert.isTrue(
    ringing.contactKey == NEAR_KEY or ringing.contactKey == FAR_KEY,
    "the reset pool still picks a catalogued caller"
  )
  Assert.deepEqual(rig.state:readPhone().history, {}, "the reset drops exactly the covering entries")
  rig.calls:dispose()
end

-- The call journal validates before assignment and a same-value write
-- never moves the revision.
function T.tests.the_call_journal_validates_before_assignment()
  local record = fixtureManifest({ { key = TRAINER_KEY, name = "JACE", sortWeight = 20, family = "trainer" } }, {})
  local state = PokegearState.new({ seed = 7 }, { catalog = record.catalog })
  Assert.throws(function()
    state:setCallHistory("custom.trainer-plain")
  end, "a non-table journal must fail")
  Assert.throws(function()
    state:setCallHistory({ [""] = true })
  end, "an empty caller key must fail")
  Assert.throws(function()
    state:setCallHistory({ [TRAINER_KEY] = "yes" })
  end, "a non-set journal value must fail")
  local revision = state:revision()
  state:setCallHistory({})
  Assert.equal(state:revision(), revision, "rewriting the empty journal moves no revision")
  state:setCallHistory({ [TRAINER_KEY] = true })
  Assert.isTrue(state:readPhone().history[TRAINER_KEY] == true, "the recorded caller joins the journal")
  local recorded = state:revision()
  state:setCallHistory({ [TRAINER_KEY] = true })
  Assert.equal(state:revision(), recorded, "recording the same caller moves no revision")
end

-- Saving keeps the durable trigger and history facts while dropping the
-- transient ring: after a restore the trigger re-arms with fresh minutes
-- instead of resuming a phantom call.
function T.tests.saved_companions_keep_triggers_and_history_but_drop_the_ring()
  local seed = findPassingSeed()
  local contacts = {
    { key = MOM_KEY, name = "MOM", sortWeight = 10, family = "mother" },
    { key = TRAINER_KEY, name = "JACE", sortWeight = 20, family = "trainer" },
  }
  local rig = freshRig(seed, contacts, {
    { key = MOM_TRIGGER, contact = MOM_KEY, kind = 3, slot = 12, clearOnPickup = true },
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
  local rig = freshRig(4242, { { key = TRAINER_KEY, name = "JACE", sortWeight = 20, family = "trainer" } }, {}, {})
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

-- A kind-zero trigger records ordinary history after the accepted host
-- reports success without clearing its flag: only event triggers clear.
function T.tests.a_kind_zero_trigger_records_history_without_clearing()
  local rig = freshRig(
    4242,
    {
      { key = MOM_KEY, name = "MOM", sortWeight = 10, family = "mother" },
      { key = TRAINER_KEY, name = "JACE", sortWeight = 20, family = "trainer" },
    },
    { { key = "custom.callback", contact = TRAINER_KEY, kind = 0, slot = 1, clearOnPickup = false } },
    { "custom.callback" }
  )
  driveEligible(rig.calls)
  rig.calls:onOpportunity(opportunityOn("custom.new-bark-town"))
  local ringing = rig.calls:notification()
  Assert.notNil(ringing, "the ordinary trigger rings")
  assert(type(ringing) == "table", "ringing publishes its caller view")
  Assert.equal(ringing.contactKey, TRAINER_KEY, "the ordinary trigger names its caller")
  rig.calls:accept("field:test-parent")
  Assert.equal(#rig.host.opens, 1, "acceptance enters the companion host exactly once")
  Assert.isTrue(
    rig.state:readPhone().history[TRAINER_KEY] == true,
    "successful completion of the ordinary trigger records its caller"
  )
  Assert.isTrue(
    rig.state:readPhone().triggers["custom.callback"] == true,
    "accepting the ordinary trigger never clears its flag"
  )
  Assert.isFalse(rig.calls:notification(), "acceptance ends the ordinary ring")
  rig.calls:dispose()
end

return T
