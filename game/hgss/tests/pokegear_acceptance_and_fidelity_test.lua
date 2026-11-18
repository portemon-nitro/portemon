-- Final behavior verification for the pocket gear at the feature layer:
-- named state transitions commit exactly once with revision currency,
-- the call journal migrates from the flat v1 shape into ordered chunks,
-- and the source-text audit ledger names every unaudited slot. State
-- scenarios compose the real durable owner with synthetic catalogs; only
-- host time is faked. Ledger expectations are transcribed message-bank
-- facts, never readouts of the modules under test.

local Assert = require("tests.support.Assert")
local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
local PokegearCalendar = require("game.hgss.src.pokegear.PokegearCalendar")
local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local PokegearState = require("libs.hgss.src.save.PokegearState")
local BroadcastFixture = require("tests.support.PokegearBroadcastFixture")

local T = {
  metadata = {
    tags = { "pokegear" },
  },
  tests = {},
}

local MOM_KEY = "custom.mom"
local NEIGHBOR_KEY = "custom.neighbor"

---@return table the synthetic compiled contact catalog
local function contactCatalog()
  return {
    contacts = {
      { key = MOM_KEY, family = "mother", sortWeight = 10 },
      { key = NEIGHBOR_KEY, family = "friend", sortWeight = 20 },
    },
    contactOrder = { MOM_KEY, NEIGHBOR_KEY },
    callTriggers = {},
    locations = {},
  }
end

-- Named state transitions commit exactly once with revision currency:
-- registration appends without moving existing contacts, trigger and
-- history writes validate before assignment, and a repeated write with
-- identical content keeps the revision still.
function T.tests.named_state_transitions_commit_exactly_once_with_revision_currency()
  local state = PokegearState.new({ seed = 901 }, { catalog = contactCatalog() })
  local revisionFresh = state:revision()
  state:registerContact(MOM_KEY)
  Assert.equal(state:revision(), revisionFresh + 1, "registration advances the revision once")
  Assert.deepEqual(state:readPhone().contactOrder, { MOM_KEY }, "registration records the caller")
  state:registerContact(NEIGHBOR_KEY)
  Assert.deepEqual(
    state:readPhone().contactOrder,
    { MOM_KEY, NEIGHBOR_KEY },
    "registration never moves an existing contact"
  )
  state:setTrigger("custom.trigger.1", true)
  Assert.deepEqual(state:readPhone().triggers, { ["custom.trigger.1"] = true }, "trigger writes stage the trigger")
  local revisionStaged = state:revision()
  state:setTrigger("custom.trigger.1", true)
  Assert.equal(state:revision(), revisionStaged, "an identical trigger write keeps the revision still")
  state:setCallHistory({ [0] = { MOM_KEY }, [1] = {}, [2] = {} })
  Assert.deepEqual(
    state:readPhone().history,
    { [0] = { MOM_KEY }, [1] = {}, [2] = {} },
    "history writes record the journal"
  )
  state:setCallHistory({ [0] = { MOM_KEY }, [1] = {}, [2] = {} })
  Assert.equal(state:revision(), revisionStaged + 1, "an identical history write keeps the revision still")
  state:setTrigger("custom.trigger.1", false)
  Assert.deepEqual(state:readPhone().triggers, {}, "clearing removes the staged trigger")
end

-- The v2 call journal keeps ordered per-chunk caller lists behind the
-- source 4/2/2 sizes: writes validate the chunk map, identical writes
-- keep the revision still, and flat v1 journals fail loudly.
function T.tests.ordered_chunk_journals_validate_sizes_and_orders()
  local state = PokegearState.new({ seed = 903 }, { catalog = contactCatalog() })
  local journal = { [0] = { "custom.a", "custom.b" }, [1] = {}, [2] = { "custom.c" } }
  state:setCallHistory(journal)
  Assert.deepEqual(state:readPhone().history, journal, "chunk writes record the ordered journal")
  local revisionStaged = state:revision()
  state:setCallHistory({ [0] = { "custom.a", "custom.b" }, [1] = {}, [2] = { "custom.c" } })
  Assert.equal(state:revision(), revisionStaged, "an identical chunk write keeps the revision still")
  Assert.throws(function()
    state:setCallHistory({ [MOM_KEY] = true })
  end, "a flat v1 journal must fail")
  Assert.throws(function()
    state:setCallHistory({ [0] = { "" }, [1] = {}, [2] = {} })
  end, "an empty caller key must fail")
  Assert.throws(function()
    state:setCallHistory({ [0] = { "custom.a" }, [1] = {}, [2] = {}, [3] = {} })
  end, "an unknown chunk must fail")
  Assert.throws(function()
    state:setCallHistory({ [0] = { "custom.a", "custom.a" }, [1] = {}, [2] = {} })
  end, "a repeated caller must fail")
  Assert.throws(function()
    state:setCallHistory({ [0] = { "a", "b", "c", "d", "e" }, [1] = {}, [2] = {} })
  end, "an overfull chunk must fail")
  Assert.throws(function()
    state:setCallHistory({ [0] = {}, [1] = {} })
  end, "a missing chunk must fail")
end

-- Restoring a v1 save migrates its flat journal into chunks by
-- catalog group: grouped callers land in their chunk in stable
-- order, overfull chunks truncate, and ungrouped callers read as
-- group zero.
function T.tests.restore_migrates_v1_flat_history_into_chunks()
  local catalog = {
    contacts = {
      { key = "custom.g0a", sortWeight = 10, randomCallGroup = 0 },
      { key = "custom.g0b", sortWeight = 20, randomCallGroup = 0 },
      { key = "custom.g1a", sortWeight = 30, randomCallGroup = 1 },
      { key = "custom.g2a", sortWeight = 40, randomCallGroup = 2 },
      { key = "custom.plain", sortWeight = 50 },
    },
    contactOrder = { "custom.g0a", "custom.g0b", "custom.g1a", "custom.g2a", "custom.plain" },
    callTriggers = {},
    locations = {},
  }
  local refs = { catalog = catalog }
  local fresh = PokegearState.new({ seed = 904 }, refs)
  local bucket = fresh:capture()
  bucket.schema = "hgss-pokegear-v1"
  bucket.stateVersion = 1
  bucket.phone.history = {
    ["custom.g0b"] = true,
    ["custom.g0a"] = true,
    ["custom.g1a"] = true,
    ["custom.g2a"] = true,
    ["custom.plain"] = true,
  }
  local restored = PokegearState.restore(bucket, refs)
  local history = restored:readPhone().history
  Assert.deepEqual(history[1], { "custom.g1a" }, "group-one callers land in chunk one")
  Assert.deepEqual(history[2], { "custom.g2a" }, "group-two callers land in chunk two")
  Assert.deepEqual(
    history[0],
    { "custom.g0a", "custom.g0b", "custom.plain" },
    "group-zero and ungrouped callers land in chunk zero in stable order"
  )
  Assert.equal(restored:capture().stateVersion, 2, "the migrated save reports version two")
end

-- The Kenji errand wait and activity commit exactly once with revision
-- currency: a fresh errand reads as the source zero state, an
-- identical write keeps the revision still, and malformed values fail
-- before assignment.
function T.tests.kenji_errand_wait_and_activity_commit_with_revision_currency()
  local state = PokegearState.new({ seed = 902 }, { catalog = contactCatalog() })
  local kenji = state:readPhone().kenji
  Assert.equal(kenji.waitDays, 0, "a fresh errand waits zero days")
  Assert.isFalse(kenji.active, "a fresh errand starts inactive")
  local revisionStaged = state:revision()
  state:setKenjiErrand(0, false)
  Assert.equal(state:revision(), revisionStaged, "an identical errand write keeps the revision still")
  state:setKenjiErrand(4, true)
  Assert.equal(state:revision(), revisionStaged + 1, "a changed errand write advances the revision once")
  local staged = state:readPhone().kenji
  Assert.equal(staged.waitDays, 4, "the errand stages its wait")
  Assert.isTrue(staged.active, "the errand stages its activity")
  Assert.throws(function()
    state:setKenjiErrand(-1, false)
  end, "a negative wait must fail")
  Assert.throws(function()
    state:setKenjiErrand(1.5, false)
  end, "a fractional wait must fail")
  Assert.throws(function()
    state:setKenjiErrand(1, 0)
  end, "a non-boolean activity must fail")
end

-- Transcribed message-bank facts behind the twelve native broadcasts: every
-- ordered bank/entry progression below is copied from the compiled producer
-- refs, never read out of the dispatcher under test. Each progression names
-- the exact requests one driven scenario must emit; the wording audit
-- drives those scenarios and compares the recorded requests entry by
-- entry, so unaudited wording can never read as proven fidelity.
local AUDITED_TEXT = {
  ["radio.music"] = {
    bank = 500,
    progressions = {
      { name = "monday-march", day = 1, dex = false, card = false, entries = { 1, 2, 2, 10 } },
      { name = "tuesday-lullaby", day = 2, dex = false, card = false, entries = { 1, 2, 2, 11 } },
      { name = "wednesday-hoenn", day = 3, dex = true, card = false, entries = { 1, 2, 2, 12 } },
      { name = "thursday-sinnoh", day = 4, dex = true, card = false, entries = { 1, 2, 2, 13 } },
      { name = "sunday-card", day = 7, dex = false, card = true, entries = { 1, 2, 2, 14 } },
      { name = "sunday-alternate", day = 7, dex = false, card = false, entries = { 1, 2, 2, 15 } },
    },
  },
  ["radio.talk"] = {
    bank = 501,
    progressions = {
      { name = "quiet", swarm = false, entries = { 1, 2, 2 }, pairs = { 1, 2, 3, 4, 5 } },
      { name = "outbreak", swarm = true, entries = { 1, 2, 2, 3, 5 }, pairs = { 1, 2, 3, 4, 5 } },
    },
  },
  ["radio.search-party"] = {
    bank = 503,
    progressions = {
      { name = "lines", hour = 9, episode = 0, entries = { 1, 2, 2, 3, 4, 5 } },
    },
  },
  ["radio.serial-drama"] = {
    bank = 504,
    progressions = {
      { name = "lines", hour = 10, episode = 2, entries = { 1, 2, 2, 3, 4, 5 } },
    },
  },
  ["radio.buena"] = {
    bank = 411,
    progressions = {
      {
        name = "with-card",
        passwordVar = 47,
        card = true,
        entries = { 1, 2, 1, 2, 3, 4 },
        token = { 66, 57 },
        reply = 4,
      },
      {
        name = "without-card",
        passwordVar = 47,
        card = false,
        entries = { 1, 2, 1, 2, 3, 5 },
        token = { 66, 57 },
        reply = 5,
      },
    },
  },
  ["radio.trainer-profiles"] = {
    bank = 505,
    progressions = {
      { name = "lines", hour = 10, episode = 0, entries = { 1, 2, 2, 3, 4, 5 } },
    },
  },
  ["radio.town-people"] = {
    bank = 506,
    progressions = {
      { name = "lines", hour = 11, episode = 0, entries = { 1, 2, 2, 3, 4, 5 } },
    },
  },
  ["radio.poke-flute"] = { bank = 507, progressions = {
    { name = "lines", entries = { 1, 2, 3 } },
  } },
  ["radio.unown"] = { bank = 508, progressions = {
    { name = "lines", entries = { 1, 2, 3 } },
  } },
  ["radio.rocket"] = {
    bank = 509,
    progressions = {
      { name = "lines", takeover = false, entries = { 1, 2, 3 } },
      { name = "takeover", takeover = true, entries = { 1, 4, 5 } },
    },
  },
  ["radio.mahogany"] = { bank = 510, progressions = {
    { name = "lines", entries = { 1, 2, 3 } },
  } },
  ["radio.commercial"] = { bank = 511, progressions = {
    { name = "lines", entries = { 1, 2, 3 } },
  } },
}

-- The source-text audit ledger names every unaudited slot: each native
-- broadcast program needs its line-progression audit transcribed before
-- its wording counts as verified. The ledger fails while slots remain,
-- so unaudited wording can never read as proven fidelity.
function T.tests.source_text_audit_ledger_names_every_unaudited_slot()
  local unaudited = {}
  for _, key in ipairs(BroadcastFixture.SHOW_KEY_LIST) do
    if AUDITED_TEXT[key] == nil then
      unaudited[#unaudited + 1] = key
    end
  end
  table.sort(unaudited)
  Assert.equal(#unaudited, 0, "unaudited source wording remains: " .. table.concat(unaudited, ", "))
end

-- Opens one broadcast dispatcher over synthetic companions: the validated
-- twelve-show catalog, an injectable civil cell, fixed world doubles, a
-- completion-controlled audio stand-in, and the recording message log.
-- Returns the program, the audio stand-in, the message log, and the
-- civil cell. No ROM data and no broadcast prose enter the repository.
---@param opts { seed: integer?, moment: table<string, integer>?, swarm: boolean?, passwordVar: integer?, takeover: boolean?, dex: boolean?, card: boolean? }?
---@return table program, table audio, table messages, table civil
local function freshBroadcast(opts)
  opts = opts or {}
  local validated = PokegearAssetSchema.validate(BroadcastFixture.fixtureManifest())
  Assert.notNil(validated, "the wording audit needs its schema-valid broadcast catalog")
  local record = assert(validated, "the catalog reads above")
  local refs = BroadcastFixture.catalogRefs(record)
  local seed = opts.seed or 4242
  local state = PokegearState.new({ seed = seed }, refs)
  local calendar = PokegearCalendar.new(state)
  local random = PokegearRandom.new(seed, { trace = {}, traceLimit = 4096 })
  local events = FieldEventState.new()
  if opts.passwordVar ~= nil then
    events:setVar(FieldScriptSymbols.variablesByName.VAR_BUENAS_PASSWORD_SET, opts.passwordVar)
  end
  if opts.takeover == true then
    events:setFlag(FieldScriptSymbols.flagsByName.FLAG_ROCKET_TAKEOVER_ACTIVE)
  end
  local RadioWorldContext = require("game.hgss.src.pokegear.RadioWorldContext")
  local world = RadioWorldContext.new({
    state = state,
    calendar = calendar,
    eventState = events,
    encounters = { swarm = opts.swarm == true },
    dex = BroadcastFixture.newDexReader(opts.dex == true),
    bag = BroadcastFixture.newBagReader(opts.card == true and { BLUE_CARD = true } or {}),
  })
  local civil =
    BroadcastFixture.newCivilCell(opts.moment or { year = 2024, month = 1, day = 8, hour = 10, minute = 0, second = 0 })
  local audio = BroadcastFixture.newAudioStandIn()
  local messages = BroadcastFixture.newMessageLog()
  local RadioProgram = require("game.hgss.src.pokegear.RadioProgram")
  local program = RadioProgram.new({
    catalog = record.catalog,
    world = world,
    clock = civil.clock,
    random = random,
    audio = audio,
    messages = messages,
  })
  return program, audio, messages, civil
end

-- Tunes one station and ticks until the dispatcher settles on the wanted
-- show (waiting out one scheduled commercial interruption when the draw
-- queues it), then returns. Commercial lines partition away by bank, so
-- the audit always reads the wanted show's own progression.
---@param program table
---@param station integer
---@param showKey string
local function tuneShow(program, station, showKey)
  program:begin(station, "clear")
  for _ = 1, 1200 do
    program:updateFixed()
    if program:status().show == showKey then
      return
    end
  end
  error("tuning never settled on " .. showKey, 0)
end

-- Collects the recorded message requests on one bank, in emission order.
---@param messages table
---@param bank integer
---@return table<integer, { entry: integer, params: table<string, unknown>? }>
local function bankRequests(messages, bank)
  local log = messages --[[@as { requests: table<integer, { bank: integer, entry: integer, params: table<string, unknown>? }> }]]
  local found = {}
  for _, request in ipairs(assert(log.requests, "the wording audit reads recorded message requests")) do
    if request.bank == bank then
      found[#found + 1] = { entry = request.entry, params = request.params }
    end
  end
  return found
end

---@param found table<integer, { entry: integer }>
---@return table<integer, integer>
local function entriesOnly(found)
  local entries = {}
  for _, request in ipairs(found) do
    entries[#entries + 1] = request.entry
  end
  return entries
end

---@param showKey string
---@param progressionName string
---@return table
local function ledgerProgression(showKey, progressionName)
  local row = assert(AUDITED_TEXT[showKey], "the ledger carries " .. showKey)
  local progressions = assert(row.progressions, "the ledger carries " .. showKey .. " progressions")
  for _, progression in ipairs(progressions) do
    if progression.name == progressionName then
      return progression
    end
  end
  error("the ledger carries no " .. progressionName .. " for " .. showKey, 0)
end

-- The music day matrix voices every compiled day entry: the title and
-- the twice-requested introduction, then exactly one day line for the
-- sampled weekday behind its dex and card gates.
function T.tests.broadcast_wording_audit_covers_the_music_day_matrix()
  local row = assert(AUDITED_TEXT["radio.music"], "the ledger carries the music wording")
  Assert.equal(row.bank, 500, "the music wording stays on its compiled bank")
  for _, progression in ipairs(assert(row.progressions, "the music wording carries its day matrix")) do
    local program, audio, messages = freshBroadcast({
      seed = 7000 + progression.day,
      moment = { year = 2024, month = 1, day = progression.day, hour = 10, minute = 0, second = 0 },
      dex = progression.dex,
      card = progression.card,
    })
    program:begin(0, "clear")
    audio:complete()
    program:updateFixed()
    Assert.deepEqual(
      entriesOnly(bankRequests(messages, 500)),
      progression.entries,
      "the music " .. progression.name .. " progression voices its compiled entries"
    )
    messages:verifyIntact()
    program:endProgram()
    program:dispose()
  end
end

-- The talk progression voices its title, introduction, the outbreak pair
-- only while an outbreak is active, and exactly five landmark pairs;
-- pair tokens stay numeric references with source-cadence flavor steps.
function T.tests.broadcast_wording_audit_covers_talk_quiet_and_outbreak_lines()
  for _, scenario in ipairs({ { name = "quiet", swarm = false }, { name = "outbreak", swarm = true } }) do
    local progression = ledgerProgression("radio.talk", scenario.name)
    local program, _, messages = freshBroadcast({ seed = 616, swarm = scenario.swarm, passwordVar = 47 })
    program:begin(1, "clear")
    for _ = 1, 400 do
      program:updateFixed()
    end
    Assert.deepEqual(
      entriesOnly(bankRequests(messages, 501)),
      progression.entries,
      "the talk " .. scenario.name .. " progression voices its compiled entries"
    )
    local pairs = bankRequests(messages, 502)
    Assert.deepEqual(
      entriesOnly(pairs),
      progression.pairs,
      "the talk " .. scenario.name .. " progression voices all five pairs in order"
    )
    for _, pair in ipairs(pairs) do
      local params = assert(pair.params, "talk pair lines carry landmark and species tokens")
      Assert.isTrue(type(params.landmark) == "number", "pair landmarks stay numeric token references")
      Assert.isTrue(type(params.species) == "number", "pair species stay numeric token references")
      Assert.isTrue(
        params.step == 2 or params.step == 4 or params.step == 6,
        "pair flavor steps follow the source cadence"
      )
    end
    messages:verifyIntact()
    program:endProgram()
    program:dispose()
  end
end

-- The four serial broadcasts voice their title, host, and four
-- day-episode lines on their own banks with the compiled episode index
-- carried as a token on every body line.
function T.tests.broadcast_wording_audit_covers_episodic_serial_lines()
  local cases = {
    { key = "radio.search-party", station = 3, seed = 8101 },
    { key = "radio.serial-drama", station = 3, seed = 8102 },
    { key = "radio.trainer-profiles", station = 2, seed = 8103 },
    { key = "radio.town-people", station = 2, seed = 8104 },
  }
  for _, case in ipairs(cases) do
    local progression = ledgerProgression(case.key, "lines")
    local row = assert(AUDITED_TEXT[case.key], "the ledger carries " .. case.key)
    local program, _, messages = freshBroadcast({
      seed = case.seed,
      moment = { year = 2024, month = 1, day = 8, hour = progression.hour, minute = 0, second = 0 },
    })
    tuneShow(program, case.station, case.key)
    local found = bankRequests(messages, row.bank)
    Assert.deepEqual(entriesOnly(found), progression.entries, case.key .. " voices its compiled entries")
    for index, request in ipairs(found) do
      if index > 2 then
        local params = assert(request.params, case.key .. " body lines carry their episode token")
        Assert.equal(params.episode, progression.episode, case.key .. " voices its compiled episode")
      end
    end
    messages:verifyIntact()
    program:endProgram()
    program:dispose()
  end
end

-- The password show voices its introduction, continuation, answer
-- initialization, the spoken token at its thirty-entry index, and the
-- card-gated reply; the token entry follows the field variable modulo
-- its compiled width.
function T.tests.broadcast_wording_audit_covers_password_token_and_card_gated_replies()
  local row = assert(AUDITED_TEXT["radio.buena"], "the ledger carries the password wording")
  Assert.equal(row.bank, 411, "the password wording stays on its compiled bank")
  for _, progression in ipairs(assert(row.progressions, "the password wording carries its reply gate")) do
    local program, _, messages = freshBroadcast({
      seed = 8200,
      moment = { year = 2024, month = 1, day = 8, hour = 8, minute = 0, second = 0 },
      passwordVar = progression.passwordVar,
      card = progression.card,
    })
    tuneShow(program, 3, "radio.buena")
    Assert.deepEqual(
      entriesOnly(bankRequests(messages, 411)),
      progression.entries,
      "the password " .. progression.name .. " progression voices its compiled entries"
    )
    local token = bankRequests(messages, progression.token[1])
    Assert.deepEqual(
      entriesOnly(token),
      { progression.token[2] },
      "the password " .. progression.name .. " progression voices its compiled token"
    )
    local voiced = bankRequests(messages, 411)
    Assert.equal(
      voiced[#voiced].entry,
      progression.reply,
      "the password " .. progression.name .. " progression voices its gated reply"
    )
    messages:verifyIntact()
    program:endProgram()
    program:dispose()
  end
end

-- The standalone broadcasts voice their title plus two body lines on
-- their own banks; the rocket takeover selects its alternate entries
-- while the scheduled commercial voices its own bank when queued.
function T.tests.broadcast_wording_audit_covers_standalone_takeover_and_commercial_lines()
  local cases = {
    { key = "radio.poke-flute", station = 4, seed = 8301 },
    { key = "radio.unown", station = 5, seed = 8302 },
    { key = "radio.mahogany", station = 7, seed = 8303 },
    { key = "radio.rocket", station = 6, seed = 8304, takeover = false },
    { key = "radio.rocket", station = 6, seed = 8305, takeover = true, progression = "takeover" },
  }
  for _, case in ipairs(cases) do
    local progression = ledgerProgression(case.key, case.progression or "lines")
    local row = assert(AUDITED_TEXT[case.key], "the ledger carries " .. case.key)
    local program, _, messages = freshBroadcast({ seed = case.seed, takeover = case.takeover })
    tuneShow(program, case.station, case.key)
    Assert.deepEqual(
      entriesOnly(bankRequests(messages, row.bank)),
      progression.entries,
      case.key .. " voices its compiled entries"
    )
    messages:verifyIntact()
    program:endProgram()
    program:dispose()
  end
  local commercial = ledgerProgression("radio.commercial", "lines")
  local commercialRow = assert(AUDITED_TEXT["radio.commercial"], "the ledger carries the commercial wording")
  local found = false
  for seed = 1, 40 do
    if not found then
      local program, _, messages = freshBroadcast({
        seed = seed,
        moment = { year = 2024, month = 1, day = 8, hour = 0, minute = 0, second = 0 },
      })
      program:begin(3, "clear")
      if program:status().show == "radio.commercial" then
        found = true
        Assert.deepEqual(
          entriesOnly(bankRequests(messages, commercialRow.bank)),
          commercial.entries,
          "the queued commercial voices its compiled entries"
        )
        messages:verifyIntact()
      end
      program:endProgram()
      program:dispose()
    end
  end
  Assert.isTrue(found, "the scheduled commercial appears across the seed sweep")
end

return T
