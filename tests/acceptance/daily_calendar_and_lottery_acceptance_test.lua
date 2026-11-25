-- The field's one civil-clock report through production composition: the
-- real runtime samples its injected host clock once per update, and the
-- daily owners behind that report (the source daily flag range, the shared
-- daily seed, party Pokerus, the daily lottery number, variable 4041, the
-- Apricorn trees, Kenji's errand wait, the daily athlete purchases and the
-- radio password set) move only on a positive elapsed day. Same-day
-- updates and a same-day Continue never repeat them, a backward host
-- adjustment applies nothing, and a required owner that cannot perform its
-- ordered work terminates the field before any partial update instead of
-- replaying the consumed report. Only host audio, the wall clock and the
-- save root are boundaries; maps, scripts, state owners and the save store
-- stay production-owned, and the render trap stays active.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local CivilDate = require("libs.hgss.src.field.CivilDate")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local Journey = require("tests.support.PokegearJourneyFixture")
local LocalClock = require("game.src.LocalClock")
local MartSave = require("libs.hgss.src.save.MartSave")
local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
local U32 = require("libs.codec.src.U32")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "audio-bank:700",
      "audio-bank:702",
      "audio-bank:709",
      -- The town's streamed coverage reaches its own cells plus the same
      -- neighbor records the corridor journeys boot with.
      "map-data:31",
      "map-data:33",
      "map-data:34",
      "map-data:47",
      "map-data:48",
      "map-data:60",
      "map-data:61",
      "map-data:67",
      "map:33",
      "map:34",
      "map:60",
      "map:61",
      "map:67",
    },
    tags = { "field", "calendar", "daily", "save" },
  },
  tests = {},
}

local FLAGS = FieldScriptSymbols.flagsByName
local VARS = FieldScriptSymbols.variablesByName

-- The source's one contiguous daily flag block (DAILY_FLAG_BASE /
-- NUM_DAILY_FLAGS in the retail flag constants).
local DAILY_FLAG_BASE = 0xAA0
local DAILY_FLAG_LAST = 0xB5F
-- The source daily LCG behind Save_LCRNGAdvanceLotoID and the friend-group
-- seed recurrence Save_FriendGroup_AdvanceSeeds steps once per elapsed day.
local LOTO_MULTIPLIER = 1103515245
local LOTO_INCREMENT = 12345
local DAILY_SEED_MULTIPLIER = 1812433253
-- The town fixture's first passable cell, the same start the companion
-- journeys use.
local START = { fieldX = 10, fieldZ = 10, facing = "south" }

---@param moment table<string, integer>
---@return integer the proleptic Gregorian day ordinal the owners persist
local function dayOrdinal(moment)
  local ordinal = CivilDate.parts(moment)
  return ordinal
end

-- A save whose persisted daily work was last processed on the boot day:
-- one athlete purchase and two harvested Apricorn trees are still recorded
-- from that day, so a forward civil day must clear both.
---@param moment table<string, integer>
---@return table the Mart bucket the finalized game carries
local function yesterdayMartWork(moment)
  local ordinal = dayOrdinal(moment)
  local bucket = MartSave.empty()
  bucket.lastProcessedDay = ordinal
  bucket.dailyPurchasedMask = 1
  bucket.apricornDayOrdinal = ordinal
  bucket.apricornHarvestedMask = 5
  return bucket
end

---@param clock table mutable civil sample the injected host clock reads
---@param options table<string, unknown>?
---@param body fun(game: table)
local function withGame(clock, options, body)
  options = options or {}
  local harness = AcceptanceHarness.new()
  local createGame = harness.gameFactory
  harness.gameFactory = function(versionId, map)
    local game = createGame(versionId, map)
    game.location = {
      mapSymbol = Journey.TOWN,
      fieldX = START.fieldX,
      fieldZ = START.fieldZ,
      facing = START.facing,
    }
    if options.mart ~= nil then
      game.mart = options.mart
    end
    return game
  end
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = Journey.TOWN,
    save = "fresh",
    fieldOptions = {
      recordingScriptHosts = true,
      audioHost = "recording",
      localClock = LocalClock.new(function()
        return clock
      end),
    },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    body(game)
    Assert.equal(game:renderAttempts(), 0, "the daily clock journey stops before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

---@param game table
---@return table the live field world state
local function world(game)
  return assert(game.runtime.scripts and game.runtime.scripts.worldState, "the field owns its world state")
end

---@param game table
---@return table the borrowed companion owner
local function companion(game)
  return assert(game.runtime.pokegearState, "the field owns the companion state")
end

---@param game table
---@return table the live mon service
local function mons(game)
  return assert(game.runtime.monService, "the field owns its mon service")
end

---@param game table
---@return table the live mart service
local function mart(game)
  return assert(game.runtime.martService, "the field owns its mart service")
end

---@param game table
---@return integer the advanced shared daily seed the calendar persisted
local function dailySeed(game)
  return companion(game):readDailyIdentity().dailyGroupSeed
end

---@param game table
---@return integer how many linear draws the shared companion stream served
local function linearDraws(game)
  local snapshot = assert(game.runtime.pokegearRandom, "the field owns the companion draw pair"):capture()
  return assert(snapshot.lc, "the companion capture carries its linear stream").calls
end

-- A detached copy of the shared companion draw pair at the current stream
-- position, so a scenario can name the exact values the next draws serve
-- without advancing the live owner.
---@param game table
---@return table
local function drawProbe(game)
  local random = assert(game.runtime.pokegearRandom, "the field owns the companion draw pair")
  return PokegearRandom.restore(random:capture())
end

---@param game table
---@return table the persisted phone projection
local function phone(game)
  return assert(companion(game):readPhone(), "the companion owner projects its phone state")
end

---@param game table
---@return table the persisted Mart bucket
local function martRecord(game)
  return assert(mart(game):capture(), "the mart owner captures its persisted bucket")
end

---@param game table
---@param slot0 integer
---@return integer the saved Pokerus byte of one party slot
local function pokerus(game, slot0)
  return mons(game):partyMon(slot0).pokerus
end

---@param game table
---@param slot0 integer
---@param value integer
local function stagePokerus(game, slot0, value)
  local service = mons(game)
  local mon = service:partyMon(slot0)
  mon.pokerus = value
  local preparation, reason = service:preparePartyChanges(service:partyRevision(), { { slot = slot0, mon = mon } })
  Assert.isNil(reason, "the prepared party change stages cleanly")
  assert(preparation).publish()
end

---@param game table
---@param species string
local function gift(game, species)
  Assert.isTrue(
    mons(game):giveMon({ species = species, level = 5, form = 0, heldItem = "NONE" }),
    "the scenario's party member enters through the production mon service"
  )
end

---@param game table
---@param set boolean
---@param label string
local function assertDailyRange(game, set, label)
  for flagId = DAILY_FLAG_BASE, DAILY_FLAG_LAST do
    Assert.equal(world(game):isFlagSet(flagId), set, label .. ": daily flag " .. flagId)
  end
end

-- Every daily flag of the source block, plus one flag on each side of it and
-- an ordinary unrelated flag: a day change may touch only the block.
---@param game table
local function seedDailyWork(game)
  assertDailyRange(game, false, "a fresh save carries no daily work")
  for flagId = DAILY_FLAG_BASE, DAILY_FLAG_LAST do
    game:setWorldState({ flag = flagId })
  end
  game:setWorldState({ flag = DAILY_FLAG_BASE - 1 })
  game:setWorldState({ flag = DAILY_FLAG_LAST + 1 })
  game:setWorldState({ flag = FLAGS.FLAG_GOT_SAVE_BUTTON })
end

function T.tests.daily_owners_apply_once_per_positive_day_but_never_on_a_same_day_continue_or_backward_clock()
  local clock = { year = 2000, month = 1, day = 10, hour = 9, minute = 0, second = 0 }
  withGame(clock, { mart = yesterdayMartWork(clock) }, function(game)
    -- The first field sample only opens the persisted calendar checkpoint.
    local openingSeed = dailySeed(game)
    game:step()
    Assert.equal(dailySeed(game), openingSeed, "the opening sample keeps the shared daily seed")
    Assert.isFalse(mart(game):treeAvailable(0), "the saved day still records its harvested tree")
    Assert.equal(martRecord(game).dailyPurchasedMask, 1, "the saved day still records its athlete purchase")

    seedDailyWork(game)
    gift(game, "PIDGEY")
    gift(game, "RATTATA")
    gift(game, "HOPPIP")
    stagePokerus(game, 0, 0x53)
    stagePokerus(game, 1, 0x03)
    stagePokerus(game, 2, 0x57)
    companion(game):setKenjiErrand(4, true)
    game:setWorldState({ variable = VARS.VAR_LOTO_NUMBER_LO, value = 0 })
    game:setWorldState({ variable = VARS.VAR_LOTO_NUMBER_HI, value = 0xABCD })
    game:setWorldState({ variable = VARS.VAR_UNK_4041, value = 1 })
    -- The password set must replace a value the source draw would repeat.
    local probe = drawProbe(game)
    local dailyRandomizationDraw = probe:lc("daily randomization probe")
    local passwordDraw = probe:lc("daily password probe")
    local collidingPassword = passwordDraw % 30
    game:setWorldState({ variable = VARS.VAR_BUENAS_PASSWORD_SET, value = collidingPassword })

    local drawsBefore = linearDraws(game)
    local seedBefore = dailySeed(game)

    -- Same-day field updates repeat nothing the day already did.
    for _ = 1, 4 do
      game:step()
    end
    assertDailyRange(game, true, "a same-day update clears no daily flag")
    Assert.isTrue(world(game):isFlagSet(FLAGS.FLAG_GOT_SAVE_BUTTON), "a same-day update keeps an unrelated flag")
    Assert.equal(pokerus(game, 0), 0x53, "a same-day update decays no Pokerus days")
    Assert.equal(pokerus(game, 1), 0x03, "a same-day update decays no Pokerus days")
    Assert.equal(pokerus(game, 2), 0x57, "a same-day update decays no Pokerus days")
    Assert.equal(dailySeed(game), seedBefore, "a same-day update steps no shared daily seed")
    Assert.equal(world(game):getVar(VARS.VAR_LOTO_NUMBER_LO), 0, "a same-day update rolls no lottery number")
    Assert.equal(world(game):getVar(VARS.VAR_UNK_4041), 1, "a same-day update randomizes no shared variable")
    Assert.equal(
      world(game):getVar(VARS.VAR_BUENAS_PASSWORD_SET),
      collidingPassword,
      "a same-day update rotates no password"
    )
    Assert.equal(phone(game).kenji.waitDays, 4, "a same-day update advances no errand wait")
    Assert.equal(martRecord(game).dailyPurchasedMask, 1, "a same-day update resets no athlete purchase")
    Assert.isFalse(mart(game):treeAvailable(0), "a same-day update regrows no tree")
    Assert.equal(linearDraws(game), drawsBefore, "a same-day update consumes no draw")

    -- One positive elapsed day applies the whole daily block once.
    clock.day = 11
    game:step()
    assertDailyRange(game, false, "one elapsed civil day clears the daily flag block")
    Assert.isTrue(world(game):isFlagSet(DAILY_FLAG_BASE - 1), "the day clears nothing below the daily block")
    Assert.isTrue(world(game):isFlagSet(DAILY_FLAG_LAST + 1), "the day clears nothing above the daily block")
    Assert.isTrue(world(game):isFlagSet(FLAGS.FLAG_GOT_SAVE_BUTTON), "the day keeps an unrelated flag")

    Assert.equal(pokerus(game, 0), 0x52, "one elapsed day decrements the remaining infection days and keeps the strain")
    Assert.equal(pokerus(game, 1), 0x02, "one elapsed day decrements the remaining infection days")
    Assert.equal(pokerus(game, 2), 0x56, "one elapsed day decrements the remaining infection days")

    local seedAfter = dailySeed(game)
    Assert.equal(
      seedAfter,
      U32.add(U32.mul(seedBefore, DAILY_SEED_MULTIPLIER), 1),
      "one elapsed day steps the shared daily seed exactly once"
    )
    local rolledId = U32.add(U32.mul(seedAfter, LOTO_MULTIPLIER), LOTO_INCREMENT)
    Assert.equal(
      world(game):getVar(VARS.VAR_LOTO_NUMBER_LO),
      math.floor(rolledId / 0x10000),
      "the daily lottery number is the high half of the source LCG of the advanced seed"
    )
    Assert.equal(
      world(game):getVar(VARS.VAR_LOTO_NUMBER_HI),
      0xABCD,
      "the retail lottery setter writes the low variable twice and leaves the high variable untouched"
    )
    Assert.equal(
      world(game):getVar(VARS.VAR_UNK_4041),
      dailyRandomizationDraw % 98 + 2,
      "the shared daily variable takes the source randomization of the first daily draw"
    )
    Assert.equal(
      world(game):getVar(VARS.VAR_BUENAS_PASSWORD_SET),
      (collidingPassword + 1) % 30,
      "the daily password set steps past the value the source draw would repeat"
    )
    Assert.equal(linearDraws(game), drawsBefore + 2, "one elapsed day consumes exactly the source's two daily draws")

    local record = martRecord(game)
    Assert.equal(record.dailyPurchasedMask, 0, "one elapsed day resets the daily athlete purchases")
    Assert.equal(record.lastProcessedDay, dayOrdinal(clock), "the mart date owner processes the new day")
    Assert.isTrue(mart(game):treeAvailable(0), "one elapsed day regrows the harvested Apricorn trees")
    Assert.equal(phone(game).kenji.waitDays, 3, "one elapsed day advances Kenji's errand wait exactly once")
    Assert.isFalse(phone(game).kenji.active, "the advanced errand wait clears its active flag")

    -- A same-day Continue replays none of it from the persisted checkpoint.
    seedDailyWork(game)
    local continued = {
      seed = dailySeed(game),
      lotteryLow = world(game):getVar(VARS.VAR_LOTO_NUMBER_LO),
      lotteryHigh = world(game):getVar(VARS.VAR_LOTO_NUMBER_HI),
      variable4041 = world(game):getVar(VARS.VAR_UNK_4041),
      password = world(game):getVar(VARS.VAR_BUENAS_PASSWORD_SET),
      errandWait = phone(game).kenji.waitDays,
    }
    Journey.saveAndReload(game)
    for _ = 1, 3 do
      game:step()
    end
    assertDailyRange(game, true, "a same-day Continue keeps the daily flag block")
    Assert.equal(dailySeed(game), continued.seed, "Continue never steps the shared daily seed again")
    Assert.equal(
      world(game):getVar(VARS.VAR_LOTO_NUMBER_LO),
      continued.lotteryLow,
      "Continue never re-rolls the lottery"
    )
    Assert.equal(
      world(game):getVar(VARS.VAR_LOTO_NUMBER_HI),
      continued.lotteryHigh,
      "Continue never rewrites the high lottery variable"
    )
    Assert.equal(
      world(game):getVar(VARS.VAR_UNK_4041),
      continued.variable4041,
      "Continue never re-randomizes the shared variable"
    )
    Assert.equal(
      world(game):getVar(VARS.VAR_BUENAS_PASSWORD_SET),
      continued.password,
      "Continue never re-rotates the password"
    )
    Assert.equal(phone(game).kenji.waitDays, continued.errandWait, "Continue never advances the errand wait again")
    Assert.equal(pokerus(game, 0), 0x52, "Continue never decays the saved infection again")

    -- A backward host adjustment applies no day and no minute work.
    Assert.isTrue(mart(game):depleteTree(1), "the scenario harvests one regrown tree")
    clock.day = 10
    for _ = 1, 3 do
      game:step()
    end
    assertDailyRange(game, true, "a backward clock adjustment clears no daily flag")
    Assert.equal(pokerus(game, 0), 0x52, "a backward clock adjustment decays no infection")
    Assert.equal(pokerus(game, 1), 0x02, "a backward clock adjustment decays no infection")
    Assert.equal(dailySeed(game), continued.seed, "a backward clock adjustment steps no shared daily seed")
    Assert.equal(
      world(game):getVar(VARS.VAR_LOTO_NUMBER_LO),
      continued.lotteryLow,
      "a backward clock adjustment re-rolls no lottery"
    )
    Assert.equal(
      world(game):getVar(VARS.VAR_UNK_4041),
      continued.variable4041,
      "a backward clock adjustment re-randomizes nothing"
    )
    Assert.equal(
      world(game):getVar(VARS.VAR_BUENAS_PASSWORD_SET),
      continued.password,
      "a backward clock adjustment re-rotates no password"
    )
    Assert.equal(
      phone(game).kenji.waitDays,
      continued.errandWait,
      "a backward clock adjustment advances no errand wait"
    )
    Assert.isFalse(mart(game):treeAvailable(1), "a backward clock adjustment regrows no tree")
    Assert.equal(martRecord(game).dailyPurchasedMask, 0, "a backward clock adjustment resets no athlete purchase")
  end)
end

function T.tests.a_multi_day_jump_decays_pokerus_and_rerolls_kenji_between_the_daily_linear_draws()
  local clock = { year = 2000, month = 3, day = 1, hour = 9, minute = 0, second = 0 }
  withGame(clock, {}, function(game)
    game:step()
    gift(game, "PIDGEY")
    gift(game, "RATTATA")
    gift(game, "HOPPIP")
    stagePokerus(game, 0, 0x57)
    stagePokerus(game, 1, 0x52)
    stagePokerus(game, 2, 0x02)
    companion(game):setKenjiErrand(1, true)
    game:setWorldState({ variable = VARS.VAR_LOTO_NUMBER_LO, value = 0 })
    game:setWorldState({ variable = VARS.VAR_LOTO_NUMBER_HI, value = 0x1234 })
    game:setWorldState({ variable = VARS.VAR_UNK_4041, value = 1 })
    local probe = drawProbe(game)
    local dailyRandomizationDraw = probe:lc("daily randomization probe")
    local errandDraw = probe:lc("errand reroll probe")
    local passwordDraw = probe:lc("daily password probe")
    local collidingPassword = passwordDraw % 30
    game:setWorldState({ variable = VARS.VAR_BUENAS_PASSWORD_SET, value = collidingPassword })

    local drawsBefore = linearDraws(game)
    local seedBefore = dailySeed(game)

    clock.day = 6
    game:step()

    Assert.equal(
      pokerus(game, 0),
      0x50,
      "more than four elapsed days clear the remaining infection days and keep the strain"
    )
    Assert.equal(pokerus(game, 1), 0x50, "a jump beyond the remaining days clears them")
    Assert.equal(pokerus(game, 2), 0x10, "a fully elapsed infection becomes the source's immune marker")

    local steppedSeed = seedBefore
    for _ = 1, 5 do
      steppedSeed = U32.add(U32.mul(steppedSeed, DAILY_SEED_MULTIPLIER), 1)
    end
    Assert.equal(dailySeed(game), steppedSeed, "the shared daily seed steps once per elapsed day")
    local rolledId = U32.add(U32.mul(steppedSeed, LOTO_MULTIPLIER), LOTO_INCREMENT)
    Assert.equal(
      world(game):getVar(VARS.VAR_LOTO_NUMBER_LO),
      math.floor(rolledId / 0x10000),
      "the daily lottery number derives from the advanced seed through the source LCG"
    )
    Assert.equal(
      world(game):getVar(VARS.VAR_LOTO_NUMBER_HI),
      0x1234,
      "the second setter write leaves the high variable untouched"
    )
    Assert.equal(
      world(game):getVar(VARS.VAR_UNK_4041),
      dailyRandomizationDraw % 98 + 2,
      "the shared daily variable takes the first daily linear draw"
    )
    Assert.equal(
      phone(game).kenji.waitDays,
      errandDraw % 6 + 1,
      "the overdue errand wait rerolls with the second daily linear draw"
    )
    Assert.isFalse(phone(game).kenji.active, "the rerolled errand wait is no longer active")
    Assert.equal(
      world(game):getVar(VARS.VAR_BUENAS_PASSWORD_SET),
      (collidingPassword + 1) % 30,
      "the daily password set takes the third daily linear draw"
    )
    Assert.equal(
      linearDraws(game),
      drawsBefore + 3,
      "the multi-day jump consumes exactly the source's three daily draws"
    )
  end)
end

function T.tests.an_invalid_daily_owner_terminates_the_field_before_any_partial_update_and_never_retries_the_report()
  local clock = { year = 2000, month = 5, day = 20, hour = 9, minute = 0, second = 0 }
  withGame(clock, { mart = yesterdayMartWork(clock) }, function(game)
    game:step()
    seedDailyWork(game)
    gift(game, "PIDGEY")
    stagePokerus(game, 0, 0x53)
    companion(game):setKenjiErrand(4, true)
    game:setWorldState({ variable = VARS.VAR_LOTO_NUMBER_LO, value = 0 })
    game:setWorldState({ variable = VARS.VAR_LOTO_NUMBER_HI, value = 0xABCD })
    game:setWorldState({ variable = VARS.VAR_UNK_4041, value = 1 })
    game:setWorldState({ variable = VARS.VAR_BUENAS_PASSWORD_SET, value = 47 })

    local seedBefore = dailySeed(game)
    local service = mart(game)
    -- The mart service resolves its operations through its class, so an
    -- incomplete owner is a class method the day cannot reach.
    local MartService = assert(getmetatable(service), "the mart service carries its owner class")
    local processDate = MartService.processDate
    MartService.processDate = nil
    clock.day = 21
    local applied, failure = pcall(function()
      game:step()
    end)
    MartService.processDate = processDate
    Assert.isFalse(applied, "a required daily owner that cannot process the day terminates the field operation")
    Assert.notNil(failure, "the terminated field operation reports its diagnostic")

    -- The report was validated before any owner was mutated.
    assertDailyRange(game, true, "a terminated daily update clears no daily flag")
    Assert.equal(pokerus(game, 0), 0x53, "a terminated daily update decays no infection")
    Assert.equal(world(game):getVar(VARS.VAR_LOTO_NUMBER_LO), 0, "a terminated daily update rolls no lottery number")
    Assert.equal(
      world(game):getVar(VARS.VAR_LOTO_NUMBER_HI),
      0xABCD,
      "a terminated daily update rewrites no high lottery variable"
    )
    Assert.equal(world(game):getVar(VARS.VAR_UNK_4041), 1, "a terminated daily update randomizes no shared variable")
    Assert.equal(world(game):getVar(VARS.VAR_BUENAS_PASSWORD_SET), 47, "a terminated daily update rotates no password")
    Assert.equal(phone(game).kenji.waitDays, 4, "a terminated daily update advances no errand wait")
    Assert.equal(martRecord(game).dailyPurchasedMask, 1, "a terminated daily update resets no athlete purchase")

    -- The single observation consumed the day before the failure, so the
    -- advanced seed is applied exactly once and never replayed.
    Assert.equal(
      dailySeed(game),
      U32.add(U32.mul(seedBefore, DAILY_SEED_MULTIPLIER), 1),
      "the one clock observation steps the shared daily seed once"
    )
    for _ = 1, 3 do
      game:step()
    end
    assertDailyRange(game, true, "the consumed day report is never retried")
    Assert.equal(pokerus(game, 0), 0x53, "the consumed day report decays no infection later")
    Assert.equal(
      world(game):getVar(VARS.VAR_LOTO_NUMBER_LO),
      0,
      "the consumed day report rolls no lottery number later"
    )
    Assert.equal(world(game):getVar(VARS.VAR_UNK_4041), 1, "the consumed day report randomizes nothing later")
    Assert.equal(phone(game).kenji.waitDays, 4, "the consumed day report advances no errand wait later")
    Assert.equal(
      dailySeed(game),
      U32.add(U32.mul(seedBefore, DAILY_SEED_MULTIPLIER), 1),
      "the consumed day report never steps the shared daily seed again"
    )
  end)
end

return T
