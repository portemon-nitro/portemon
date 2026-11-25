-- The field's ordered daily dispatcher and its lottery owner over fake owners:
-- the source day order of src/field_time_events.c::FieldSystem_HandleDaysPassed,
-- the lottery arithmetic of src/sys_vars.c, the traversal of
-- src/scrcmd_lottery.c and the infection decay of src/pokemon.c. Every vector
-- below is the native rule: five trailing decimal digits of the low trainer-ID
-- halfword, party before boxes, the first strictly greatest match per
-- container, the retail setter's double low halfword write, the two linear
-- values of the source roll, and the exact draw count of one day application.

local Assert = require("tests.support.Assert")
local FieldDailyEvents = require("game.hgss/src/field/FieldDailyEvents")
local FieldEventState = require("libs.hgss/src/field/FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local ScriptErrors = require("libs.script.src.errors")
local U32 = require("libs.codec.src.U32")

local T = { tests = {} }

local FLAGS = FieldScriptSymbols.flagsByName
local VARS = FieldScriptSymbols.variablesByName
local DAILY_FLAG_BASE = 0xAA0
local DAILY_FLAG_COUNT = 192
local LOTO_MULTIPLIER = 1103515245
local LOTO_INCREMENT = 12345
local SLOTS_PER_BOX = 30

-- The observation every day application reads: one civil sample, and the
-- calendar report that already stepped the saved daily seed.
local SAMPLE = { year = 2000, month = 3, day = 6, hour = 9, minute = 30, second = 0 }
local SEED = 123456789

---@param overrides table<string, unknown>?
---@return table<string, unknown>
local function mon(overrides)
  local record = {
    species = "PIDGEY",
    isEgg = false,
    pokerus = 0,
    origin = { trainerId = 0 },
  }
  for key, value in pairs(overrides or {}) do
    record[key] = value
  end
  return record
end

-- A fake canonical mon service: party slots answer by zero-based index, boxes
-- hold sparse slots, and one prepared change publishes every staged party slot
-- through exactly one publish call.
---@param options { party: table[]?, boxes: table[]?, pokerus: integer[]? }
---@return table
local function fakeMons(options)
  local party = options.party or {}
  local boxes = options.boxes or {}
  local service = { publishes = 0, preparations = 0, staged = {} }
  function service:partyCount()
    return #party
  end
  function service:partyMon(slot0)
    return assert(party[slot0 + 1], "the fixture names an occupied party slot")
  end
  function service:partyRevision()
    return self.publishes
  end
  function service:boxCount()
    return #boxes
  end
  function service:boxMon(box, slot)
    local record = boxes[box + 1]
    return record and record[slot] or nil
  end
  function service:preparePartyChanges(_, updates)
    self.preparations = self.preparations + 1
    self.staged = updates
    return {
      changed = #updates > 0,
      isCurrent = function()
        return true
      end,
      publish = function()
        self.publishes = self.publishes + 1
        for _, update in ipairs(updates) do
          party[update.slot + 1] = update.mon
        end
      end,
    }
  end
  return service
end

-- One recorded day application: the world store is the canonical event state,
-- and every borrowed owner records the call it received in source order.
---@param options table<string, unknown>?
---@return { events: FieldDailyEvents, world: table, order: string[], draws: string[], state: table, mons: table, mart: table, calls: table }
local function harness(options)
  options = options or {}
  local world = FieldEventState.new(options.events)
  local random = options.random or { values = {}, index = 0 }
  local order = {}
  local draws = {}
  local state = {
    dailyGroupSeed = options.seed or SEED,
  }
  function state:readDailyIdentity()
    return { dailyGroupSeed = self.dailyGroupSeed, outbreakSeed = 0, daySerial = 0 }
  end
  local mart = {
    dates = {},
  }
  function mart:processDate(date)
    order[#order + 1] = "mart"
    self.dates[#self.dates + 1] = date
    return { weekday = 0, dayOrdinal = 1 }
  end
  local function takeDraw(label)
    order[#order + 1] = label
    draws[#draws + 1] = label
    random.index = random.index + 1
    local value = random.values[random.index]
    assert(value ~= nil, "the fixture scripts every draw the owner takes")
    return value
  end
  -- PhoneCallPersistentState_BlackBeltKenji_UpdateWaitDays: a covering wait only
  -- decrements, and an overdue one takes the source reroll draw.
  local calls = { advanced = {}, waitDays = options.waitDays or 0 }
  function calls:advanceDays(days)
    order[#order + 1] = "kenji"
    self.advanced[#self.advanced + 1] = days
    if self.waitDays >= days then
      self.waitDays = self.waitDays - days
      return
    end
    self.waitDays = takeDraw("kenji-wait") % 6 + 1
  end
  local preparedRandom = {
    lc = function(_, label)
      return takeDraw(label)
    end,
  }
  local mons = options.mons or fakeMons({})
  local events = FieldDailyEvents.new({
    world = world,
    state = state,
    mons = mons,
    mart = mart,
    calls = calls,
    random = preparedRandom,
    regrowApricorns = function(date)
      order[#order + 1] = "apricorn"
      mart.apricornDate = date
      return true
    end,
  })
  return {
    events = events,
    world = world,
    order = order,
    draws = draws,
    state = state,
    mons = mons,
    mart = mart,
    calls = calls,
  }
end

---@param rig table
---@param days integer
local function applyDay(rig, days)
  FieldDailyEvents.apply({ dailyEvents = rig.events }, SAMPLE, {
    dayAdvance = days,
    minuteAdvance = 0,
    backward = false,
  })
end

---@param rig table
local function setDailyFlags(rig)
  for offset = 0, DAILY_FLAG_COUNT - 1 do
    rig.world:setFlag(DAILY_FLAG_BASE + offset)
  end
end

---@param rig table
---@return integer remaining
local function countDailyFlags(rig)
  local remaining = 0
  for offset = 0, DAILY_FLAG_COUNT - 1 do
    if rig.world:isFlagSet(DAILY_FLAG_BASE + offset) then
      remaining = remaining + 1
    end
  end
  return remaining
end

---@param lotoId integer
---@param party table[]
---@param boxes table[]?
---@return { position: integer, count: integer, kind: integer }
local function search(lotoId, party, boxes)
  local rig = harness({ mons = fakeMons({ party = party, boxes = boxes or {} }) })
  return rig.events:searchLotoId(lotoId)
end

-- Five trailing decimal digits, including leading zeros, always read from the
-- low halfword of the stored trainer identity; eggs never match.
function T.tests.the_lottery_search_compares_five_trailing_digits_of_the_low_ot_half()
  Assert.deepEqual(
    { search(12345, { mon({ origin = { trainerId = 12345 } }) }) },
    { { position = 0, count = 5, kind = 0 } },
    "the five trailing digits of the low halfword match completely"
  )
  Assert.deepEqual(
    { search(12345, { mon({ origin = { trainerId = 0x12340000 + 2345 } }) }) },
    { { position = 0, count = 4, kind = 0 } },
    "only the low halfword is compared, and its shared trailing digits count"
  )
  Assert.deepEqual(
    { search(12345, { mon({ origin = { trainerId = 0x30390000 + 1 } }) }) },
    { { position = 0, count = 0, kind = 0 } },
    "a high halfword alone never matches"
  )
  Assert.deepEqual({ search(0, {}) }, { { position = 0, count = 0, kind = 0 } }, "an empty search matches nothing")
  Assert.deepEqual(
    { search(0, { mon({ origin = { trainerId = 0 } }) }) },
    { { position = 0, count = 5, kind = 0 } },
    "leading zeros count as matched digits"
  )
  Assert.deepEqual(
    { search(7, { mon({ origin = { trainerId = 7 } }) }) },
    { { position = 0, count = 5, kind = 0 } },
    "a short identity still fills five digit positions"
  )
  Assert.deepEqual(
    { search(100, { mon({ origin = { trainerId = 0 } }) }) },
    { { position = 0, count = 2, kind = 0 } },
    "the comparison stops at the first differing trailing digit"
  )
  Assert.deepEqual(
    { search(12345, { mon({ isEgg = true, origin = { trainerId = 12345 } }) }) },
    { { position = 0, count = 0, kind = 0 } },
    "an egg never matches"
  )
  local ok, failure = pcall(function()
    search(-1, {})
  end)
  Assert.isFalse(ok, "a negative lottery identity is not a source value")
  Assert.equal(failure.code, ScriptErrors.SCRIPT_INVALID_REFERENCE, "the search reports its reference fault")
end

-- Party first, then every box in source order, each container keeping its first
-- strictly greatest match; an equal party and box score chooses the party, and
-- a box result reports box * 30 + slot. The lottery identity is 12345, so its
-- trailing digits are 5, then 4, then 3, and so on.
function T.tests.the_lottery_search_reads_party_before_boxes_and_keeps_the_first_greatest()
  local party = {
    mon({ origin = { trainerId = 2345 } }),
    mon({ isEgg = true, origin = { trainerId = 12345 } }),
    mon({ origin = { trainerId = 45 } }),
    mon({ origin = { trainerId = 345 } }),
  }
  local boxes = {
    [1] = {
      [0] = mon({ origin = { trainerId = 45 } }),
      [5] = mon({ origin = { trainerId = 345 } }),
    },
    [2] = {
      [1] = mon({ origin = { trainerId = 12345 } }),
      [29] = mon({ origin = { trainerId = 12345 } }),
    },
  }
  Assert.deepEqual(
    search(12345, party, boxes),
    { position = 1 * SLOTS_PER_BOX + 1, count = 5, kind = 1 },
    "a strictly better box result answers with its first match and its box kind"
  )
  Assert.deepEqual(
    search(12345, party, { [1] = { [5] = mon({ origin = { trainerId = 45 } }) } }),
    { position = 0, count = 4, kind = 0 },
    "a better party match answers with its own slot"
  )
  Assert.deepEqual(
    search(12345, { mon({ origin = { trainerId = 345 } }) }, { [1] = { [0] = mon({ origin = { trainerId = 345 } }) } }),
    { position = 0, count = 3, kind = 0 },
    "an equal party and box score chooses the party"
  )
  Assert.deepEqual(
    search(
      12345,
      { mon({ origin = { trainerId = 45 } }), mon({ origin = { trainerId = 345 } }) },
      { [1] = { [0] = mon({ origin = { trainerId = 45 } }) } }
    ),
    { position = 1, count = 3, kind = 0 },
    "the first strictly greatest party match keeps its slot"
  )
  Assert.deepEqual(
    search(12345, {}, {
      [1] = {
        [0] = mon({ origin = { trainerId = 45 } }),
        [5] = mon({ origin = { trainerId = 345 } }),
        [7] = mon({ origin = { trainerId = 345 } }),
      },
    }),
    { position = 5, count = 3, kind = 1 },
    "a later equal box match never replaces the first"
  )
  Assert.deepEqual(
    search(12345, { mon({ isEgg = true, origin = { trainerId = 12345 } }) }, {}),
    { position = 0, count = 0, kind = 0 },
    "an egg-only party reports no match"
  )
end

-- One elapsed day applies the source order with exactly two linear values and
-- no lottery draw: the party infection decays through one prepared change, the
-- daily seed's linear step writes only the low halfword, and the shared daily
-- variable and the password set take the two draws in that order.
function T.tests.a_positive_day_applies_the_source_order_and_both_daily_draws()
  local mons = fakeMons({
    party = {
      mon({ pokerus = 0x53 }),
      mon({ pokerus = 0x03 }),
      mon({ pokerus = 0x57 }),
      mon({ pokerus = 0x10 }),
    },
  })
  local rig = harness({ mons = mons, waitDays = 4, random = { values = { 4, 33 }, index = 0 } })
  rig.world:setVar(VARS.VAR_LOTO_NUMBER_LO, 0)
  rig.world:setVar(VARS.VAR_LOTO_NUMBER_HI, 0xABCD)
  rig.world:setVar(VARS.VAR_UNK_4041, 1)
  rig.world:setVar(VARS.VAR_BUENAS_PASSWORD_SET, 3)
  setDailyFlags(rig)

  applyDay(rig, 1)

  Assert.equal(countDailyFlags(rig), 0, "the source daily block is cleared")
  Assert.isFalse(rig.world:isFlagSet(FLAGS.FLAG_DAILY_KURT_MAKING_BALLS), "the daily block covers the ball-making flag")
  Assert.equal(mons.preparations, 1, "the infection decay stages exactly one party change")
  Assert.equal(mons.publishes, 1, "the staged party change publishes once")
  Assert.equal(#mons.staged, 3, "only infected slots take part in the change")
  Assert.equal(mons:partyMon(0).pokerus, 0x52, "a covered day decrements the remaining infection days")
  Assert.equal(mons:partyMon(1).pokerus, 0x02, "a covered day decrements every infected slot")
  Assert.equal(mons:partyMon(2).pokerus, 0x56, "the strain bits survive the decrement")
  Assert.equal(mons:partyMon(3).pokerus, 0x10, "the immune marker is not an infection")

  local rolled = U32.add(U32.mul(SEED, LOTO_MULTIPLIER), LOTO_INCREMENT)
  Assert.equal(
    rig.world:getVar(VARS.VAR_LOTO_NUMBER_LO),
    math.floor(rolled / 0x10000),
    "the daily lottery number is the high half of the source linear step"
  )
  Assert.equal(rig.world:getVar(VARS.VAR_LOTO_NUMBER_HI), 0xABCD, "the setter leaves the high variable untouched")
  Assert.equal(rig.world:getVar(VARS.VAR_UNK_4041), 4 % 98 + 2, "the shared daily variable takes the first draw")
  Assert.equal(
    rig.world:getVar(VARS.VAR_BUENAS_PASSWORD_SET),
    (33 % 30 + 1) % 30,
    "the password set steps past the value its own draw would repeat"
  )
  Assert.deepEqual(rig.draws, { "daily-var4041", "daily-password-set" }, "one day takes two labelled linear values")
  Assert.equal(#rig.calls.advanced, 1, "the errand wait advances once")
  Assert.equal(rig.calls.advanced[1], 1, "the errand wait advances by the elapsed day")
  Assert.equal(rig.calls.waitDays, 3, "a covering errand wait decrements")
  Assert.equal(#rig.mart.dates, 1, "the athlete purchases are processed once")
  Assert.equal(rig.mart.dates[1], SAMPLE, "the athlete purchase pass reads the one observed sample")
  Assert.equal(rig.mart.apricornDate, SAMPLE, "the Apricorn pass reads the one observed sample")
  Assert.deepEqual(
    rig.order,
    { "daily-var4041", "apricorn", "kenji", "mart", "daily-password-set" },
    "the day work runs in the source order around the two linear values"
  )
end

-- A multi-day jump clears every remaining infection day, turns a fully elapsed
-- infection into the immune marker, and rerolls an overdue errand between the
-- shared daily variable and the password set.
function T.tests.a_multi_day_jump_clears_infection_and_rerolls_the_errand_between_the_draws()
  local mons = fakeMons({
    party = { mon({ pokerus = 0x57 }), mon({ pokerus = 0x52 }), mon({ pokerus = 0x02 }) },
  })
  local rig = harness({ mons = mons, waitDays = 1, random = { values = { 96, 4, 29 }, index = 0 } })
  rig.world:setVar(VARS.VAR_BUENAS_PASSWORD_SET, 29 % 30)

  applyDay(rig, 5)

  Assert.equal(mons:partyMon(0).pokerus, 0x50, "a jump beyond four days clears the infection days")
  Assert.equal(mons:partyMon(1).pokerus, 0x50, "a jump beyond the remaining days clears them")
  Assert.equal(mons:partyMon(2).pokerus, 0x10, "a fully elapsed infection becomes the immune marker")
  Assert.deepEqual(
    rig.draws,
    { "daily-var4041", "kenji-wait", "daily-password-set" },
    "the overdue errand reroll sits between the shared variable and the password set"
  )
  Assert.equal(rig.world:getVar(VARS.VAR_UNK_4041), 96 % 98 + 2, "the shared variable takes the first draw")
  Assert.equal(
    rig.world:getVar(VARS.VAR_BUENAS_PASSWORD_SET),
    (29 % 30 + 1) % 30,
    "the password set takes the third draw and steps past the stored set"
  )
  Assert.equal(rig.calls.waitDays, 4 % 6 + 1, "the errand wait takes the second draw")
end

-- Save_VarsFlags_RollLotoId: the low linear value first and the high one second,
-- both landing in the low halfword through the retail setter.
function T.tests.the_lottery_set_draws_low_then_high_and_writes_the_low_variable_twice()
  local rig = harness({ random = { values = { 0x1234, 0xABCD }, index = 0 } })
  rig.world:setVar(VARS.VAR_LOTO_NUMBER_HI, 0x0F0F)
  rig.events:rollLotoId()
  Assert.deepEqual(rig.draws, { "lottery-id-lo", "lottery-id-hi" }, "the roll takes the low value then the high one")
  Assert.equal(
    rig.world:getVar(VARS.VAR_LOTO_NUMBER_LO),
    0xABCD,
    "the high half overwrites the low half through the second setter write"
  )
  Assert.equal(rig.world:getVar(VARS.VAR_LOTO_NUMBER_HI), 0x0F0F, "the high variable keeps its previous value")
  Assert.equal(rig.events:lotoId(), 0x0F0F0000 + 0xABCD, "the saved identity reads both stored halfwords")
end

-- A same-day or backward observation applies no day work and takes no draw.
function T.tests.a_same_day_or_backward_observation_applies_no_day_work()
  local rig = harness({})
  setDailyFlags(rig)
  rig.world:setVar(VARS.VAR_UNK_4041, 7)
  FieldDailyEvents.apply({ dailyEvents = rig.events }, SAMPLE, { dayAdvance = 0, minuteAdvance = 12, backward = false })
  FieldDailyEvents.apply({ dailyEvents = rig.events }, SAMPLE, { dayAdvance = 0, minuteAdvance = 0, backward = true })
  Assert.equal(countDailyFlags(rig), DAILY_FLAG_COUNT, "neither observation clears a daily flag")
  Assert.equal(rig.world:getVar(VARS.VAR_UNK_4041), 7, "neither observation rewrites the shared variable")
  Assert.deepEqual(rig.draws, {}, "neither observation takes a linear value")
  Assert.deepEqual(rig.calls.advanced, {}, "neither observation advances the errand wait")
  Assert.deepEqual(rig.mart.dates, {}, "neither observation processes the athlete purchases")
end

-- An owner that cannot perform its ordered work terminates the application
-- before the first mutation, and the shared daily seed the observation already
-- stepped is not applied twice.
function T.tests.an_owner_that_cannot_process_the_day_terminates_before_any_mutation()
  local rig = harness({})
  setDailyFlags(rig)
  rig.world:setVar(VARS.VAR_LOTO_NUMBER_LO, 0)
  rig.world:setVar(VARS.VAR_LOTO_NUMBER_HI, 0x1234)
  rig.world:setVar(VARS.VAR_UNK_4041, 1)
  rig.mart.processDate = nil
  local ok, failure = pcall(function()
    applyDay(rig, 1)
  end)
  Assert.isFalse(ok, "the application terminates when a required owner cannot process the day")
  Assert.notNil(failure, "the failure carries its diagnostic")
  Assert.equal(countDailyFlags(rig), DAILY_FLAG_COUNT, "no daily flag is cleared before the failure")
  Assert.equal(rig.world:getVar(VARS.VAR_LOTO_NUMBER_LO), 0, "no lottery number is written before the failure")
  Assert.equal(rig.world:getVar(VARS.VAR_LOTO_NUMBER_HI), 0x1234, "the high lottery variable is untouched")
  Assert.equal(rig.world:getVar(VARS.VAR_UNK_4041), 1, "the shared variable is untouched")
  Assert.deepEqual(rig.draws, {}, "no linear value is taken before the failure")
  Assert.deepEqual(rig.calls.advanced, {}, "the errand wait is untouched")
end

return { tests = T.tests }
