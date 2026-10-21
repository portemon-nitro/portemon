-- Explicit acquisition receipt through the live party service: building a
-- preview, inserting through the generic party operation, or assigning a
-- form never records history, while receiving a valid non-egg mon
-- publishes the party append and its caught fact together. Egg receipt
-- enters the party only, and a full-party gift still consumes its
-- creation draws while publishing neither party nor history.
-- The real starter task receives its confirmed prebuilt candidate once
-- without rerolling, and the synthetic seen operation records its
-- generated specimen facts without inserting a party mon. Uses the small
-- synthetic mon/catalog fixtures; no ROM, GPU, or product cache is
-- touched.

local Assert = require("tests.support.Assert")
local BoxCodec = require("libs.mons.src.gen4.BoxCodec")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Errors = require("libs.errors.src.Errors")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PokedexDexFixture = require("libs.hgss.tests.mons.pokedex_dex_fixture")
local PokedexKnowledge = require("libs.hgss.src.mons.PokedexKnowledge")

local T = {}

local TASK_MODULE = "libs.hgss.src.script.tasks.ChooseStarterTask"
local TRIO = { "CHIKORITA", "TOTODILE", "EEVEE" }

local function openOwner()
  local monCatalog = PokedexDexFixture.makeCatalog()
  local pokedexCatalog = PokedexDexFixture.buildPokedexCatalog()
  local owner = PokedexKnowledge.new(PokedexDexFixture.refs(monCatalog, pokedexCatalog))
  return owner, monCatalog
end

local function openService(monCatalog, seed, owner)
  return HgssMonService.new({
    catalog = monCatalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(seed):capture()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
    mapSection = 7,
    date = CatalogFixture.metDate(),
    dex = owner,
  })
end

local function openServiceFromBucket(monCatalog, bucket, owner)
  return HgssMonService.new({
    catalog = monCatalog,
    bucket = bucket,
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
    mapSection = 7,
    date = CatalogFixture.metDate(),
    dex = owner,
  })
end

local function giftRequest(species)
  return {
    species = species,
    level = 5,
    heldItem = "NONE",
    form = 0,
    location = 7,
    date = CatalogFixture.metDate(),
  }
end

local function boxedBytes(monCatalog, mon)
  return BoxCodec.encode(mon, CatalogFixture.domainContext(monCatalog))
end

local function requireReceipt(service)
  Assert.isTrue(
    type(service.receiveMon) == "function",
    "explicit receipt publishes the admitted mon and its caught fact together"
  )
end

function T.previews_and_structural_mutation_record_no_history()
  local owner, monCatalog = openOwner()
  local service = openService(monCatalog, 0x11111111, owner)
  local revision = owner:revision()

  local preview = service:buildStarter("CHIKORITA")
  Assert.equal(service:partyCount(), 0, "a built preview never enters the party")
  Assert.isFalse(owner:isSeen("CHIKORITA"), "a built preview never records a sighting")
  Assert.isFalse(owner:isCaught("CHIKORITA"), "a built preview never records a capture")

  local factory = CatalogFixture.makeFactory(0x22222222, monCatalog)
  local inserted = factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE" }))
  Assert.isTrue(service:addMon(inserted), "the structural insertion enters the party")
  Assert.isFalse(owner:isSeen("TOTODILE"), "a generic insertion never records a sighting")
  Assert.isFalse(owner:isCaught("TOTODILE"), "a generic insertion never records a capture")

  service:setMonForm(0, 0)
  Assert.isFalse(owner:isSeen("TOTODILE"), "a generic form assignment never records a sighting")
  Assert.isFalse(owner:isCaught("TOTODILE"), "a generic form assignment never records a capture")
  Assert.equal(owner:revision(), revision, "structural paths never advance the history revision")
  Assert.notNil(preview, "the preview build stays usable beside the party")
end

function T.successful_non_egg_receipt_publishes_party_and_caught_together()
  local owner, monCatalog = openOwner()
  local service = openService(monCatalog, 0x33333333, owner)
  requireReceipt(service)
  local callsBefore = service:capture().rng.calls
  local partyRevision = service:partyRevision()
  local dexRevision = owner:revision()

  local factory = CatalogFixture.makeFactory(0x44444444, monCatalog)
  local admitted = factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA", personality = 0 }))
  Assert.isTrue(service:receiveMon(admitted), "a valid non-egg receipt succeeds")
  Assert.equal(service:partyCount(), 1, "receipt appends the exact admitted mon")
  Assert.equal(
    boxedBytes(monCatalog, service:partyMon(0)),
    boxedBytes(monCatalog, admitted),
    "receipt publishes the admitted instance without rerolling"
  )
  Assert.isTrue(owner:isCaught("CHIKORITA"), "receipt records the caught fact")
  Assert.isTrue(owner:isSeen("CHIKORITA"), "a caught fact also records the sighting")
  Assert.deepEqual(
    owner:observedGenders("CHIKORITA"),
    { "female" },
    "receipt records the admitted specimen's actual gender"
  )
  Assert.equal(service:partyRevision(), partyRevision + 1, "receipt publishes one party mutation")
  Assert.equal(owner:revision(), dexRevision + 1, "receipt publishes one history mutation")
  Assert.equal(service:capture().rng.calls, callsBefore, "receipt itself consumes no generator draws")
end

function T.egg_receipt_enters_the_party_without_history()
  local owner, monCatalog = openOwner()
  local service = openService(monCatalog, 0x55555555, owner)
  requireReceipt(service)

  local egg = PokedexDexFixture.makeMon(monCatalog, { species = "CHIKORITA", personality = 0, isEgg = true })
  Assert.isTrue(service:receiveMon(egg), "an egg receipt still enters the party")
  Assert.equal(service:partyCount(), 1, "the egg is appended")
  Assert.isFalse(owner:isSeen("CHIKORITA"), "an egg records no sighting")
  Assert.isFalse(owner:isCaught("CHIKORITA"), "an egg records no capture")
end

function T.full_party_gift_consumes_creation_draws_without_publishing()
  local owner, monCatalog = openOwner()
  local service = openService(monCatalog, 0x66666666, owner)
  for _ = 1, Party.MAX do
    Assert.isTrue(service:giveMon(giftRequest("CHIKORITA")), "setup gifts fill the party")
  end
  local callsBefore = service:capture().rng.calls
  local partyRevision = service:partyRevision()
  local dexRevision = owner:revision()

  Assert.isFalse(service:giveMon(giftRequest("TOTODILE")), "the seventh gift reports the source failure result")
  Assert.equal(service:partyCount(), Party.MAX, "a full party never overflows into storage")
  Assert.equal(service:partyRevision(), partyRevision, "the discarded gift publishes no party mutation")
  Assert.equal(service:capture().rng.calls, callsBefore + 4, "creation draws precede the insertion result")
  Assert.isFalse(owner:isSeen("TOTODILE"), "the discarded gift records no sighting")
  Assert.isFalse(owner:isCaught("TOTODILE"), "the discarded gift records no capture")
  Assert.equal(owner:revision(), dexRevision, "the discarded gift publishes no history")
end

local function requireTask()
  local ok, task = pcall(require, TASK_MODULE)
  Assert.isTrue(ok, "the starter task owns candidate generation and selected publication")
  return assert(task)
end

local function providerFor(species)
  return {
    resolve = function()
      return { species[1], species[2], species[3] }
    end,
  }
end

local function modalHost()
  local host = { opened = 0, closed = 0, done = false, index = nil }
  function host:open(_)
    self.opened = self.opened + 1
  end
  function host:close()
    self.closed = self.closed + 1
  end
  function host:status()
    if self.done then
      return { done = true, index = self.index }
    end
    if self.opened > self.closed then
      return { done = false }
    end
    return nil
  end
  function host:finish(index)
    self.done = true
    self.index = index
  end
  function host:handleInput(events)
    assert(type(events) == "table", "the choice host requires the event batch")
  end
  return host
end

local function taskCtx(service, host)
  return {
    services = {
      mons = service,
      starterProvider = providerFor(TRIO),
      starterChoice = host,
      starterBalls = { placeStarterBalls = function() end },
    },
    input = { uiEvents = {} },
    instance = { scriptId = "receipt-starter-fixture" },
  }
end

function T.confirmed_starter_candidate_is_received_exactly_once()
  local owner, monCatalog = openOwner()
  local task = requireTask()
  local service = openService(monCatalog, 0x77777777, owner)
  local host = modalHost()
  local ctx = taskCtx(service, host)
  local state = task.create({ node = { op = "choose_starter" } }, ctx)
  for _ = 1, 4 do
    task.poll(state, ctx)
    if host.opened >= 1 then
      break
    end
  end
  local candidateBytes = {}
  for index, candidate in ipairs(state.candidates) do
    candidateBytes[index] = boxedBytes(monCatalog, candidate)
  end
  local callsBefore = service:capture().rng.calls

  host:finish(1)
  local outcome = task.poll(state, ctx)
  Assert.isTrue(outcome.complete, "the confirmed choice completes")
  Assert.equal(service:partyCount(), 1, "the selection is inserted exactly once")
  Assert.equal(
    boxedBytes(monCatalog, service:partyMon(0)),
    candidateBytes[2],
    "the inserted mon is the confirmed prebuilt candidate"
  )
  Assert.equal(service:capture().rng.calls, callsBefore, "confirmation never rerolls the candidate")
  Assert.isTrue(owner:isCaught("TOTODILE"), "the confirmed candidate records its caught fact")
  Assert.isFalse(owner:isSeen("CHIKORITA"), "unconfirmed candidates record no sighting")
  Assert.isFalse(owner:isCaught("EEVEE"), "unconfirmed candidates record no capture")

  local repeatOutcome = task.poll(state, ctx)
  Assert.isTrue(repeatOutcome.complete, "a finished task stays complete")
  Assert.equal(service:partyCount(), 1, "a finished task never inserts twice")
end

function T.resumed_confirmation_around_save_still_receives_once()
  local owner, monCatalog = openOwner()
  local task = requireTask()
  local service = openService(monCatalog, 0x9ABCDEF0, owner)
  local host = modalHost()
  local ctx = taskCtx(service, host)
  local state = task.create({ node = { op = "choose_starter" } }, ctx)
  for _ = 1, 4 do
    task.poll(state, ctx)
    if host.opened >= 1 then
      break
    end
  end
  local candidateBytes = boxedBytes(monCatalog, state.candidates[3])
  local savedBucket = service:capture()
  local savedCalls = savedBucket.rng.calls
  local dexRevision = owner:revision()

  local restoredService = openServiceFromBucket(monCatalog, savedBucket, owner)
  local restoredHost = modalHost()
  local restoredCtx = taskCtx(restoredService, restoredHost)
  local waiting = task.poll(state, restoredCtx)
  Assert.isFalse(waiting.complete, "the resumed choice waits for confirmation")
  Assert.equal(restoredService:partyCount(), 0, "resume publishes nothing early")
  Assert.isFalse(owner:isCaught("EEVEE"), "resume records nothing early")

  restoredHost:finish(2)
  local outcome = task.poll(state, restoredCtx)
  Assert.isTrue(outcome.complete, "the resumed choice completes on confirmation")
  Assert.equal(restoredService:partyCount(), 1, "the resumed selection is inserted exactly once")
  Assert.equal(
    boxedBytes(monCatalog, restoredService:partyMon(0)),
    candidateBytes,
    "the resumed insert matches the pre-save candidate"
  )
  Assert.isTrue(owner:isCaught("EEVEE"), "the resumed confirmation records its caught fact")
  Assert.equal(owner:revision(), dexRevision + 1, "the resumed confirmation publishes one history mutation")
end

function T.synthetic_seen_records_generated_facts_without_insertion()
  local owner, monCatalog = openOwner()
  local service = openService(monCatalog, 0xAAAAAAAA, owner)
  Assert.isTrue(
    type(service.markSpeciesSeen) == "function",
    "synthetic observation records the generated specimen facts"
  )
  Assert.isTrue(type(service.hasSeenSpecies) == "function", "the seen query answers without generating")
  local callsBefore = service:capture().rng.calls

  service:markSpeciesSeen("SPINDA")
  Assert.equal(service:partyCount(), 0, "synthetic observation inserts no party mon")
  Assert.equal(service:capture().rng.calls, callsBefore + 4, "synthetic observation runs the normal creation draws")
  Assert.isTrue(owner:isSeen("SPINDA"), "synthetic observation records the sighting")
  Assert.isFalse(owner:isCaught("SPINDA"), "synthetic observation records no capture")
  Assert.deepEqual(owner:caughtLanguages("SPINDA"), {}, "synthetic observation records no language")
  Assert.equal(#owner:observedGenders("SPINDA"), 1, "synthetic observation records the generated gender")
  Assert.notNil(owner:firstPersonality("SPINDA"), "synthetic observation keeps the first Spinda personality")

  local queryBefore = service:capture().rng.calls
  Assert.isTrue(service:hasSeenSpecies("SPINDA"), "the seen query answers true after observation")
  Assert.isFalse(service:hasSeenSpecies("UNOWN"), "the seen query answers false without observation")
  Assert.equal(service:capture().rng.calls, queryBefore, "the seen query consumes no generator draws")
end

function T.invalid_receipt_inputs_fail_before_publication()
  local owner, monCatalog = openOwner()
  local service = openService(monCatalog, 0xBBBBBBBB, owner)
  requireReceipt(service)
  local partyRevision = service:partyRevision()
  local dexRevision = owner:revision()
  local err = Assert.throws(function()
    service:receiveMon({ bogus = true })
  end)
  Assert.isTrue(Errors.is(err), "an invalid receipt is a structured service error")
  Assert.equal(service:partyCount(), 0, "an invalid receipt appends nothing")
  Assert.equal(service:partyRevision(), partyRevision, "an invalid receipt publishes no party mutation")
  Assert.equal(owner:revision(), dexRevision, "an invalid receipt publishes no history")
end

return { tests = T }
