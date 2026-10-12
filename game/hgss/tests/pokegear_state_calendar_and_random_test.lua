-- Durable gear-companion state, civil calendar, and deterministic draws:
-- contact, gift, and map-marking facts survive a capture/restore round
-- trip; old saves migrate without invented history; field time advances in
-- whole civil minutes with local weekdays; labelled draws keep their source
-- widths across capture and restore. Companion cases pin reference
-- rejection, slot validation, candidate staleness, month boundaries,
-- snapshot validation, and the bounded diagnostic trace. All expectations
-- use synthetic data and independent arithmetic, never the behaviour under
-- test as its own oracle.

local Assert = require("tests.support.Assert")
local GameSave = require("libs.hgss.src.save.GameSave")
local LocalClock = require("game.src.LocalClock")

local T = {
  metadata = {
    tags = { "pokegear" },
  },
  tests = {},
}

-- Loads a companion module that does not exist yet at this baseline. The
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

local function visualRef(path)
  return { image = path, width = 32, height = 32, anchorX = 0, anchorY = 0 }
end

-- Synthetic companion catalog with two contacts and one marked location,
-- validated through the real asset schema so the state tests borrow only
-- genuine semantic references.
---@return table
local function fixtureManifest()
  return {
    schema = "g4-pokegear-assets-v1",
    skins = { 0, 1, 2, 3, 4, 5 },
    shell = { foreground = visualRef("assets/generated/pokegear/shell-foreground-skin-0.png") },
    configure = { panel = visualRef("assets/generated/pokegear/configure-panel.png") },
    phone = { panel = visualRef("assets/generated/pokegear/phone-panel.png") },
    map = { base = visualRef("assets/generated/pokegear/map-base.png") },
    fly = { base = visualRef("assets/generated/pokegear/fly-base.png") },
    radio = { dial = visualRef("assets/generated/pokegear/radio-dial.png") },
    catalog = {
      contacts = {
        { key = "custom.elm", family = "elm", sortWeight = 10 },
        { key = "custom.mom", family = "mother", sortWeight = 20 },
        { key = "custom.bill", family = "service", sortWeight = 30 },
      },
      contactOrder = { "custom.elm", "custom.mom", "custom.bill" },
      callDefinitions = {},
      callTriggers = {},
      rematches = {},
      gifts = {},
      momPurchases = {},
      locations = {
        { key = "custom.new-bark" },
      },
      flypoints = {},
      reception = {},
      shows = {},
      radioEffects = {},
    },
    text = {},
    sequences = {},
  }
end

---@param refs table
---@return table
local function catalogRefs(refs)
  return { catalog = refs.catalog }
end

-- A validated civil sample minted through the injectable host clock, so no
-- path under test can reach the real host time.
---@param moment table
---@return table
local function civilSample(moment)
  local clock = LocalClock.new(function()
    return {
      year = moment.year,
      month = moment.month,
      day = moment.day,
      hour = moment.hour,
      minute = moment.minute,
      second = moment.second,
    }
  end)
  return clock:nowLocal()
end

-- Independent Gregorian day serial (Howard Hinnant's days-from-civil), kept
-- outside the calendar implementation as the minute/day oracle.
---@param moment table
---@return integer
local function daySerial(moment)
  local year = moment.year
  if moment.month <= 2 then
    year = year - 1
  end
  local era = math.floor((year >= 0 and year or year - 399) / 400)
  local yearOfEra = year - era * 400
  local monthPrime = (moment.month + 9) % 12
  local dayOfYear = math.floor((153 * monthPrime + 2) / 5) + moment.day - 1
  local dayOfEra = yearOfEra * 365 + math.floor(yearOfEra / 4) - math.floor(yearOfEra / 100) + dayOfYear
  return era * 146097 + dayOfEra - 719468
end

---@param moment table
---@return integer
local function epochSeconds(moment)
  return daySerial(moment) * 86400 + moment.hour * 3600 + moment.minute * 60 + moment.second
end

---@param from table
---@param to table
---@return integer
local function wholeMinutes(from, to)
  return math.floor((epochSeconds(to) - epochSeconds(from)) / 60)
end

---@param moment table
---@param seconds integer
---@return table
local function shiftSeconds(moment, seconds)
  local total = epochSeconds(moment) + seconds
  local days = math.floor(total / 86400)
  local clock = total - days * 86400
  -- Invert the serial back through the civil calendar without host help.
  local serial = days + 719468
  local era = math.floor((serial >= 0 and serial or serial - 146096) / 146097)
  local dayOfEra = serial - era * 146097
  local yearOfEra = math.floor(
    (dayOfEra - math.floor(dayOfEra / 1460) + math.floor(dayOfEra / 36524) - math.floor(dayOfEra / 146096)) / 365
  )
  local year = yearOfEra + era * 400
  local dayOfYear = dayOfEra - (365 * yearOfEra + math.floor(yearOfEra / 4) - math.floor(yearOfEra / 100))
  local monthPrime = math.floor((5 * dayOfYear + 2) / 153)
  local day = dayOfYear - math.floor((153 * monthPrime + 2) / 5) + 1
  local month = monthPrime + 3
  if monthPrime >= 10 then
    month = monthPrime - 9
  end
  if month <= 2 then
    year = year + 1
  end
  return {
    year = year,
    month = month,
    day = day,
    hour = math.floor(clock / 3600),
    minute = math.floor((clock % 3600) / 60),
    second = clock % 60,
  }
end

function T.tests.contact_registration_round_trips_through_capture_and_stays_idempotent()
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearState = requireFeature(
    "libs.hgss.src.save.PokegearState",
    "phone contact state has no durable owner yet: registration, gifts, and markings cannot persist"
  )
  local state = PokegearState.new(nil, catalogRefs(record))
  Assert.deepEqual(state:readPhone().contactOrder, {}, "a fresh companion phone starts with no registered numbers")

  local revision = state:revision()
  state:registerContact("custom.elm")
  state:registerContact("custom.mom")
  state:registerContact("custom.elm")
  Assert.deepEqual(
    state:readPhone().contactOrder,
    { "custom.elm", "custom.mom" },
    "repeat registration keeps one entry in first-registered order"
  )
  Assert.equal(state:revision(), revision + 2, "only first-time registrations advance the revision")

  state:setContactReward("custom.elm", { item = "custom.potion", quantity = 1 })
  state:setMarking("custom.new-bark", {
    icons = { 1, 2, false, false },
    words = { "custom.word-a", false, false, false },
  })
  Assert.equal(state:revision(), revision + 4, "each successful mutation advances the revision exactly once")

  local ok, err = pcall(function()
    state:registerContact("custom.ghost")
  end)
  Assert.isFalse(ok, "an unknown contact reference must fail")
  Assert.notNil(
    tostring((type(err) == "table" and err.message) or err):find("custom.ghost", 1, true),
    "the unknown-contact failure must name the missing key"
  )
  Assert.equal(state:revision(), revision + 4, "a failed mutation leaves the revision alone")
  Assert.deepEqual(
    state:readPhone().contactOrder,
    { "custom.elm", "custom.mom" },
    "a failed registration leaves the contact order alone"
  )

  local bucket = state:capture()
  local revived = PokegearState.restore(bucket, catalogRefs(record))
  Assert.deepEqual(revived:capture(), bucket, "capture and restore preserve the exact bucket")
  Assert.deepEqual(
    revived:readPhone().contactOrder,
    { "custom.elm", "custom.mom" },
    "registered order survives capture and restore"
  )
  Assert.deepEqual(
    revived:capture().markings["custom.new-bark"],
    { icons = { 1, 2, false, false }, words = { "custom.word-a", false, false, false } },
    "four-slot markings survive capture and restore with explicit empty slots"
  )

  local unregistered = revived:capture()
  unregistered.contactOrder[#unregistered.contactOrder + 1] = "custom.bill"
  local restored = pcall(PokegearState.restore, unregistered, catalogRefs(record))
  Assert.isFalse(restored, "restoration rejects catalogued contacts that were never registered")
  local reordered = pcall(revived.setContactOrder, revived, { "custom.elm", "custom.mom", "custom.bill" })
  Assert.isFalse(reordered, "manual ordering rejects catalogued contacts that were never registered")

  local borrowed = revived:readPhone()
  borrowed.contactOrder[#borrowed.contactOrder + 1] = "custom.ghost"
  Assert.deepEqual(
    revived:readPhone().contactOrder,
    { "custom.elm", "custom.mom" },
    "mutating a borrowed projection leaves the owner alone"
  )
end

function T.tests.old_saves_keep_their_domains_and_gain_no_invented_contact_history()
  Assert.equal(
    GameSave.SCHEMA,
    "g4-game-save-v9",
    "the durable envelope must advance to v9 once the companion bucket migrates"
  )
  Assert.isTrue(type(GameSave.migrateV8) == "function", "v8 saves need an explicit migration into the companion bucket")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearState = requireFeature(
    "libs.hgss.src.save.PokegearState",
    "migrated saves have no companion bucket owner yet: old domains cannot gain the new state"
  )
  local EncounterSave = require("libs.hgss.src.save.EncounterSave")

  local party = { members = { { species = "custom.chikorita", level = 5 } } }
  local bag = { items = { { key = "custom.potion", quantity = 3 } } }
  local box = { boxes = {} }
  local world = { flags = { STORY_BEAT_RIVAL = true }, variables = { VAR_GEAR_PROGRESS = 2 } }
  local encounters = EncounterSave.initial()
  local v8 = {
    schema = "g4-game-save-v8",
    saveId = "test-gear-migration",
    versionId = "heartgold",
    playTimeSeconds = 3600,
    playerData = { profile = { name = "GOLD", money = 3000 } },
    world = world,
    party = party,
    bag = bag,
    box = box,
    encounters = encounters,
  }
  local migrated = GameSave.migrateV8(v8)
  Assert.equal(migrated.schema, "g4-game-save-v9", "migration advances the envelope to v9")
  Assert.deepEqual(migrated.playerData, v8.playerData, "migration preserves the player bucket exactly")
  Assert.deepEqual(migrated.world, world, "migration preserves world flags and variables exactly")
  Assert.deepEqual(migrated.party, party, "migration preserves the party exactly")
  Assert.deepEqual(migrated.bag, bag, "migration preserves the bag exactly")
  Assert.deepEqual(migrated.box, box, "migration preserves stored monsters exactly")
  Assert.deepEqual(migrated.encounters, encounters, "migration preserves encounter and roamer records exactly")
  Assert.isNil(v8.pokegear, "migration never mutates its source record")
  Assert.notNil(migrated.pokegear, "migration creates the new companion bucket")

  local gear = PokegearState.restore(migrated.pokegear, catalogRefs(record))
  Assert.deepEqual(
    gear:readPhone().contactOrder,
    {},
    "migration invents no optional numbers without acquisition evidence"
  )
  local cards = gear:capture().registeredCards or {}
  local carriesMap = false
  for key, value in pairs(cards) do
    if key == "map" or value == "map" then
      carriesMap = true
    end
  end
  Assert.isFalse(carriesMap, "migration leaves the map card unavailable without map-card evidence")

  local malformed = {
    schema = "hgss-pokegear-v1",
    stateVersion = 9999,
  }
  local ok, _ = pcall(function()
    PokegearState.restore(malformed, catalogRefs(record))
  end)
  Assert.isFalse(ok, "a malformed companion bucket must fail instead of resetting to defaults")
end

function T.tests.field_time_advances_in_whole_minutes_with_local_weekdays()
  local PokegearState = requireFeature(
    "libs.hgss.src.save.PokegearState",
    "field time has no calendar checkpoint owner yet: whole-minute and daily advances cannot persist"
  )
  local PokegearCalendar = requireFeature(
    "game.hgss.src.pokegear.PokegearCalendar",
    "field time has no civil calendar adapter yet: whole-minute checkpoints and local weekdays are unavailable"
  )
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")

  local function freshCalendar()
    local state = PokegearState.new(nil, catalogRefs(record))
    return PokegearCalendar.new(state)
  end

  -- Weekdays come from the local civil date alone: the host clock is
  -- replaced with a failure so any host reinterpretation surfaces loudly.
  local originalDate = os.date
  os.date = function()
    error("the calendar must not consult the host clock", 0)
  end
  local weekdayOk, weekdayErr = pcall(function()
    local leapThursday = civilSample({ year = 2024, month = 2, day = 29, hour = 12, minute = 0, second = 0 })
    local weekEarlier = civilSample({ year = 2024, month = 2, day = 22, hour = 12, minute = 0, second = 0 })
    local nextDay = civilSample({ year = 2024, month = 3, day = 1, hour = 12, minute = 0, second = 0 })
    local weekLater = civilSample({ year = 2024, month = 3, day = 7, hour = 12, minute = 0, second = 0 })
    Assert.equal(
      PokegearCalendar.weekday(leapThursday),
      PokegearCalendar.weekday(weekEarlier),
      "the leap-day Thursday matches the Thursday a week earlier"
    )
    Assert.equal(
      PokegearCalendar.weekday(leapThursday),
      PokegearCalendar.weekday(weekLater),
      "weekdays repeat every seven civil days"
    )
    Assert.isTrue(
      PokegearCalendar.weekday(leapThursday) ~= PokegearCalendar.weekday(nextDay),
      "adjacent civil days carry distinct weekdays"
    )
  end)
  os.date = originalDate
  if not weekdayOk then
    error(weekdayErr, 0)
  end

  -- Sub-minute remainders are kept, not dropped: thirty seconds advance
  -- nothing, and the following thirty-one seconds complete exactly one
  -- whole minute from the original checkpoint.
  do
    local calendar = freshCalendar()
    local base = { year = 2024, month = 2, day = 29, hour = 23, minute = 59, second = 30 }
    calendar:observeField(civilSample(base))
    local subminute = calendar:observeField(civilSample(shiftSeconds(base, 30)))
    Assert.equal(subminute.minuteAdvance, 0, "thirty seconds advance no whole minute")
    Assert.isFalse(subminute.backward, "forward samples never report backward time")
    local minute = calendar:observeField(civilSample(shiftSeconds(base, 61)))
    Assert.equal(minute.minuteAdvance, 1, "sixty-one seconds advance exactly one whole minute")
    Assert.equal(
      minute.minuteAdvance,
      wholeMinutes(base, shiftSeconds(base, 61)),
      "the checkpoint advance matches independent civil arithmetic"
    )
    local nextMinute = calendar:observeField(civilSample(shiftSeconds(base, 120)))
    Assert.equal(nextMinute.minuteAdvance, 1, "the discarded remainder carries into the next minute")
  end

  -- Midnight, leap-day, and year boundaries advance whole days.
  do
    local calendar = freshCalendar()
    local base = { year = 2024, month = 2, day = 29, hour = 23, minute = 59, second = 30 }
    calendar:observeField(civilSample(base))
    local crossed =
      calendar:observeField(civilSample({ year = 2024, month = 3, day = 1, hour = 0, minute = 0, second = 31 }))
    Assert.equal(crossed.minuteAdvance, 1, "sixty-one seconds across midnight advance one whole minute")
    Assert.equal(crossed.dayAdvance, 1, "the leap-day to March transition advances exactly one day")
  end
  do
    local calendar = freshCalendar()
    local base = { year = 1999, month = 12, day = 31, hour = 23, minute = 59, second = 0 }
    calendar:observeField(civilSample(base))
    local rolled =
      calendar:observeField(civilSample({ year = 2000, month = 1, day = 1, hour = 0, minute = 1, second = 0 }))
    Assert.equal(rolled.minuteAdvance, 2, "two minutes across the year boundary advance two whole minutes")
    Assert.equal(rolled.dayAdvance, 1, "the year rollover advances exactly one day")
  end

  -- Backward time rebases the checkpoint and adds no negative minutes.
  do
    local calendar = freshCalendar()
    local base = { year = 2024, month = 5, day = 6, hour = 12, minute = 0, second = 0 }
    calendar:observeField(civilSample(base))
    local backward = calendar:observeField(civilSample(shiftSeconds(base, -3600)))
    Assert.isTrue(backward.backward, "an earlier sample reports backward time")
    Assert.equal(backward.minuteAdvance, 0, "backward time adds no minutes")
    Assert.equal(backward.dayAdvance, 0, "backward time advances no days")
    local rebased = calendar:observeField(civilSample(shiftSeconds(base, -3600 + 61)))
    Assert.isFalse(rebased.backward, "time after the rebased checkpoint is forward again")
    Assert.equal(rebased.minuteAdvance, 1, "the rebased checkpoint measures whole minutes from the earlier sample")
  end

  -- A long suspension reports the full elapsed count at the adapter: the
  -- caller owns ignoring that backlog for ringing, never the calendar.
  do
    local calendar = freshCalendar()
    local base = { year = 2024, month = 1, day = 1, hour = 0, minute = 0, second = 0 }
    calendar:observeField(civilSample(base))
    local offline = calendar:observeField(civilSample(shiftSeconds(base, 3 * 86400 + 25 * 60)))
    Assert.equal(offline.dayAdvance, 3, "three days offline advance three whole days")
    Assert.equal(offline.minuteAdvance, 3 * 1440 + 25, "the adapter reports the full elapsed minutes")
  end

  -- Each whole-day advance steps the shared daily seed once per day through
  -- the source recurrence, and the outbreak seed follows the selected group.
  do
    local U32 = require("libs.codec.src.U32")
    local state = PokegearState.new(nil, catalogRefs(record))
    local calendar = PokegearCalendar.new(state)
    local before = state:readDailyIdentity()
    Assert.isTrue(
      type(before.dailyGroupSeed) == "number"
        and before.dailyGroupSeed % 1 == 0
        and before.dailyGroupSeed >= 0
        and before.dailyGroupSeed <= U32.MAX,
      "the daily group seed starts as an unsigned 32-bit seed"
    )
    local base = { year = 2024, month = 1, day = 1, hour = 0, minute = 0, second = 0 }
    calendar:observeField(civilSample(base))
    local advanced = calendar:observeField(civilSample(shiftSeconds(base, 86400 + 60)))
    Assert.equal(advanced.dayAdvance, 1, "one elapsed day advances the daily identity once")
    local after = state:readDailyIdentity()
    local expected = U32.add(U32.mul(before.dailyGroupSeed, 1812433253), 1)
    Assert.equal(after.dailyGroupSeed, expected, "the daily seed steps once through the source recurrence per day")
    Assert.equal(after.outbreakSeed, after.dailyGroupSeed, "the outbreak seed follows the selected group seed")
  end
end

function T.tests.labelled_draws_keep_source_widths_and_resume_after_capture()
  local PokegearRandom = requireFeature(
    "game.hgss.src.pokegear.PokegearRandom",
    "feature draws have no deterministic owner yet: labelled source-width draws cannot continue across capture"
  )
  local U32 = require("libs.codec.src.U32")

  -- Independent reference vectors, kept outside the implementation: the
  -- published MT19937 vector for seed 5489, and the first LCRandom draw
  -- from a zero seed (24691 advances to the upper 16 bits of zero).
  local referenceMt = PokegearRandom.new(5489)
  Assert.equal(
    referenceMt:mt("outbreak-pick"),
    3499211612,
    "mt draws match the published MT19937 reference vector for seed 5489"
  )
  local referenceLc = PokegearRandom.new(0)
  Assert.equal(referenceLc:lc("phone-gate"), 0, "lc draws keep the source 16-bit width from a zero seed")

  local function checkWidths(draws, label)
    for index, value in ipairs(draws) do
      Assert.isTrue(type(value) == "number" and value % 1 == 0, label .. " draw " .. index .. " stays integral")
    end
  end

  local first = PokegearRandom.new(12345)
  local second = PokegearRandom.new(12345)
  local firstLc, firstMt = {}, {}
  local secondLc, secondMt = {}, {}
  for step = 1, 8 do
    firstLc[step] = first:lc("phone-gate-" .. step)
    firstMt[step] = first:mt("radio-pick-" .. step)
    secondLc[step] = second:lc("phone-gate-" .. step)
    secondMt[step] = second:mt("radio-pick-" .. step)
  end
  checkWidths(firstLc, "lc")
  checkWidths(firstMt, "mt")
  for _, value in ipairs(firstLc) do
    Assert.isTrue(value >= 0 and value <= 65535, "lc draws stay inside sixteen bits")
  end
  for _, value in ipairs(firstMt) do
    Assert.isTrue(value >= 0 and value <= U32.MAX, "mt draws stay inside thirty-two bits")
  end
  Assert.deepEqual(secondLc, firstLc, "identical seeds replay identical labelled lc draws")
  Assert.deepEqual(secondMt, firstMt, "identical seeds replay identical labelled mt draws")

  -- Capture never draws: the continuation with an interleaved capture
  -- matches the uninterrupted policy sequence exactly.
  local uninterrupted = PokegearRandom.new(777)
  local expected = {}
  for step = 1, 6 do
    expected[step] = { lc = uninterrupted:lc("gate-" .. step), mt = uninterrupted:mt("pick-" .. step) }
  end
  local captured = PokegearRandom.new(777)
  local actual = {}
  for step = 1, 3 do
    actual[step] = { lc = captured:lc("gate-" .. step), mt = captured:mt("pick-" .. step) }
  end
  local snapshot = captured:capture()
  for step = 4, 6 do
    actual[step] = { lc = captured:lc("gate-" .. step), mt = captured:mt("pick-" .. step) }
  end
  Assert.deepEqual(actual, expected, "capturing midstream never advances either draw stream")

  local restored = PokegearRandom.restore(snapshot)
  local resumed = {}
  for step = 4, 6 do
    resumed[step] = { lc = restored:lc("gate-" .. step), mt = restored:mt("pick-" .. step) }
  end
  for step = 4, 6 do
    Assert.deepEqual(resumed[step], expected[step], "a restored snapshot continues the identical policy sequence")
  end
end

function T.tests.unknown_reference_keys_fail_by_name_without_moving_revision()
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearState = requireFeature(
    "libs.hgss.src.save.PokegearState",
    "phone contact state has no durable owner yet: registration, gifts, and markings cannot persist"
  )
  local state = PokegearState.new(nil, catalogRefs(record))
  local base = state:revision()

  ---@param fn fun()
  ---@param key string
  local function rejectsNaming(fn, key)
    local err = Assert.throws(fn, "a reference outside the catalog must fail")
    local message = tostring((type(err) == "table" and err.message) or err)
    Assert.notNil(message:find(key, 1, true), "the failure must name the missing key " .. key)
  end

  rejectsNaming(function()
    state:registerContact("custom.ghost")
  end, "custom.ghost")
  rejectsNaming(function()
    state:setMarking("custom.nowhere", { icons = { 1, false, false, false }, words = { false, false, false, false } })
  end, "custom.nowhere")
  rejectsNaming(function()
    state:setPreference("custom.unknown-knob", 1)
  end, "custom.unknown-knob")
  rejectsNaming(function()
    state:registerCard("custom.satellite")
  end, "custom.satellite")
  rejectsNaming(function()
    state:setContactReward("custom.ghost", { item = "custom.potion", quantity = 1 })
  end, "custom.ghost")
  rejectsNaming(function()
    state:setContactReward("custom.mom", { item = "custom.potion", quantity = 1 })
  end, "custom.mom")
  Assert.equal(state:revision(), base, "failed mutations leave the revision alone")
  Assert.deepEqual(state:readPhone().contactOrder, {}, "failed mutations register nothing")

  local triggerErr = Assert.throws(function()
    state:setTrigger("", true)
  end, "an empty trigger key must fail")
  Assert.notNil(tostring((type(triggerErr) == "table" and triggerErr.message) or triggerErr), "trigger failure carries a message")
  Assert.equal(state:revision(), base, "a failed trigger leaves the revision alone")
end

function T.tests.malformed_markings_and_rewards_are_rejected_without_moving_revision()
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearState = requireFeature(
    "libs.hgss.src.save.PokegearState",
    "phone contact state has no durable owner yet: registration, gifts, and markings cannot persist"
  )
  local state = PokegearState.new(nil, catalogRefs(record))
  state:registerContact("custom.elm")
  local base = state:revision()

  ---@param fn fun()
  local function rejects(fn)
    Assert.throws(fn, "a malformed slot or reward must fail")
  end

  rejects(function()
    state:setMarking("custom.new-bark", { icons = { 1, 2, 3 }, words = { false, false, false, false } })
  end)
  rejects(function()
    state:setMarking("custom.new-bark", { icons = { 10, false, false, false }, words = { false, false, false, false } })
  end)
  rejects(function()
    state:setMarking("custom.new-bark", { icons = { 0, false, false, false }, words = { false, false, false, false } })
  end)
  rejects(function()
    state:setMarking("custom.new-bark", { icons = { 1, false, false, false }, words = { "", false, false, false } })
  end)
  rejects(function()
    state:setMarking("custom.new-bark", { icons = { 1, false, false, false }, words = { 7, false, false, false } })
  end)
  rejects(function()
    state:setContactReward("custom.elm", { item = "custom.potion", quantity = 0 })
  end)
  rejects(function()
    state:setContactReward("custom.elm", { item = "custom.potion", quantity = 1.5 })
  end)
  rejects(function()
    state:setContactReward("custom.elm", { item = "", quantity = 1 })
  end)
  rejects(function()
    state:setContactReward("custom.elm", { item = "custom.potion" })
  end)
  rejects(function()
    state:setContactReward("custom.elm", { item = "custom.potion", quantity = 1, ribbon = true })
  end)
  Assert.equal(state:revision(), base, "rejected slots and rewards leave the revision alone")
  Assert.isNil(state:capture().markings["custom.new-bark"], "rejected markings store nothing")
end

function T.tests.stale_and_replayed_candidates_cannot_publish()
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearState = requireFeature(
    "libs.hgss.src.save.PokegearState",
    "phone contact state has no durable owner yet: registration, gifts, and markings cannot persist"
  )
  local state = PokegearState.new(nil, catalogRefs(record))
  local base = state:revision()

  local candidate = state:prepare(base, function(edit)
    edit:registerContact("custom.elm")
  end)
  Assert.isTrue(candidate.isCurrent, "a freshly prepared candidate is current")
  state:registerContact("custom.mom")
  Assert.throws(function()
    candidate.publish()
  end, "publishing after a concurrent mutation must fail")
  Assert.deepEqual(
    state:readPhone().contactOrder,
    { "custom.mom" },
    "a stale publication leaves the committed order alone"
  )
  Assert.equal(state:revision(), base + 1, "only the committed mutation advances the revision")

  local settled = state:revision()
  Assert.throws(function()
    state:prepare(settled, function(_)
      error("boom")
    end)
  end, "a throwing draft function must propagate")
  Assert.equal(state:revision(), settled, "a failed draft leaves the revision alone")
  Assert.throws(function()
    state:prepare(settled, function(edit)
      edit:registerContact("custom.ghost")
    end)
  end, "a draft with an unknown reference must fail before publication")
  Assert.equal(state:revision(), settled, "an invalid draft leaves the revision alone")

  local batched = state:prepare(state:revision(), function(edit)
    edit:registerContact("custom.elm")
    edit:setContactReward("custom.elm", { item = "custom.potion", quantity = 2 })
  end)
  Assert.isTrue(batched.isCurrent, "a candidate prepared at the live revision is current")
  batched.publish()
  Assert.deepEqual(
    state:readPhone().contactOrder,
    { "custom.mom", "custom.elm" },
    "one publication commits the whole batch"
  )
  Assert.equal(state:revision(), settled + 1, "one publication advances the revision exactly once")
  Assert.throws(function()
    batched.publish()
  end, "replaying a publication must fail")
  Assert.equal(state:revision(), settled + 1, "a replayed publication leaves the revision alone")

  local outdated = state:prepare(settled, function(edit)
    edit:registerContact("custom.elm")
  end)
  Assert.isFalse(outdated.isCurrent, "a candidate prepared at an old revision is not current")
  Assert.throws(function()
    outdated.publish()
  end, "publishing an outdated candidate must fail")
end

function T.tests.month_boundaries_advance_days_and_step_seeds_per_day()
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearState = requireFeature(
    "libs.hgss.src.save.PokegearState",
    "field time has no calendar checkpoint owner yet: whole-minute and daily advances cannot persist"
  )
  local PokegearCalendar = requireFeature(
    "game.hgss.src.pokegear.PokegearCalendar",
    "field time has no civil calendar adapter yet: whole-minute checkpoints and local weekdays are unavailable"
  )
  local U32 = require("libs.codec.src.U32")

  do
    local state = PokegearState.new(nil, catalogRefs(record))
    local calendar = PokegearCalendar.new(state)
    local base = { year = 2024, month = 4, day = 30, hour = 23, minute = 59, second = 30 }
    calendar:observeField(civilSample(base))
    local crossed = calendar:observeField(civilSample({ year = 2024, month = 5, day = 1, hour = 0, minute = 0, second = 31 }))
    Assert.equal(crossed.minuteAdvance, 1, "sixty-one seconds across the month boundary advance one whole minute")
    Assert.equal(crossed.dayAdvance, 1, "the April to May transition advances exactly one day")
    Assert.isTrue(
      PokegearCalendar.weekday(civilSample(base)) ~= PokegearCalendar.weekday(civilSample(shiftSeconds(base, 61))),
      "adjacent civil days across the month boundary carry distinct weekdays"
    )
  end

  do
    local state = PokegearState.new(nil, catalogRefs(record))
    local calendar = PokegearCalendar.new(state)
    local before = state:readDailyIdentity()
    local base = { year = 2024, month = 1, day = 1, hour = 0, minute = 0, second = 0 }
    calendar:observeField(civilSample(base))
    local advanced = calendar:observeField(civilSample(shiftSeconds(base, 3 * 86400 + 25 * 60)))
    Assert.equal(advanced.dayAdvance, 3, "three elapsed days advance the daily identity three times")
    local after = state:readDailyIdentity()
    local expected = before.dailyGroupSeed
    for _ = 1, 3 do
      expected = U32.add(U32.mul(expected, 1812433253), 1)
    end
    Assert.equal(after.dailyGroupSeed, expected, "each elapsed day steps the seed once through the recurrence")
    Assert.equal(after.outbreakSeed, after.dailyGroupSeed, "the outbreak seed follows the stepped group seed")
  end
end

function T.tests.restored_draw_snapshots_reject_malformed_state()
  local PokegearRandom = requireFeature(
    "game.hgss.src.pokegear.PokegearRandom",
    "feature draws have no deterministic owner yet: labelled source-width draws cannot continue across capture"
  )
  local snapshot = PokegearRandom.new(99):capture()
  Assert.equal(#snapshot.mt.state, 624, "capture carries the complete source state array")

  ---@param mutate fun(candidate: table)
  local function rejects(mutate)
    local candidate = PokegearRandom.new(99):capture()
    mutate(candidate)
    Assert.throws(function()
      PokegearRandom.restore(candidate)
    end, "a malformed snapshot must fail instead of drawing")
  end

  rejects(function(candidate)
    candidate.mt.state[624] = nil
  end)
  rejects(function(candidate)
    candidate.mt.index = 625
  end)
  rejects(function(candidate)
    candidate.lc.state = -1
  end)
  rejects(function(candidate)
    candidate.lc.calls = -1
  end)
  rejects(function(candidate)
    candidate.extra = true
  end)
end

function T.tests.labelled_trace_sink_stays_bounded_without_changing_draws()
  local PokegearRandom = requireFeature(
    "game.hgss.src.pokegear.PokegearRandom",
    "feature draws have no deterministic owner yet: labelled source-width draws cannot continue across capture"
  )
  local plain = PokegearRandom.new(4242)
  local trace = {}
  local traced = PokegearRandom.new(4242, { trace = trace, traceLimit = 4 })
  for step = 1, 6 do
    local plainLc, plainMt = plain:lc("gate-" .. step), plain:mt("pick-" .. step)
    Assert.equal(traced:lc("gate-" .. step), plainLc, "a traced lc draw matches the untraced draw")
    Assert.equal(traced:mt("pick-" .. step), plainMt, "a traced mt draw matches the untraced draw")
  end
  Assert.equal(#trace, 4, "the caller-owned trace stops at its bound")
  local oracle = PokegearRandom.new(4242)
  Assert.deepEqual(
    trace[1],
    { stream = "lc", label = "gate-1", value = oracle:lc("gate-1") },
    "the trace records the stream, label, and result of each draw"
  )
  Assert.equal(trace[1].stream, "lc", "the first traced entry names its stream")
  Assert.equal(trace[1].label, "gate-1", "the first traced entry names its label")
  Assert.equal(trace[2].stream, "mt", "labelled streams interleave in draw order")
end

return T
