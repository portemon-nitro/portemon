-- Script runtime coverage for the dex operations: semantic nodes
-- evaluate their operands, call exactly one named operation on the
-- injected dex or mon service, and write the source result convention
-- to the result variable. Counts exclude species outside the explicit
-- display sets, evaluation selects its band and gendered message with
-- the music value written before an aliased message value, grants
-- publish the owner before their compatibility writes, the specialized
-- form operations restage through the mon service, and the two
-- source-wait commands yield one tick while the rest continue. A
-- missing service is an attributed fault, never a silent skip. Uses
-- the small synthetic mon/catalog fixtures; no ROM, GPU, or product
-- cache is touched.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Errors = require("libs.errors.src.Errors")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PokedexDexFixture = require("libs.hgss.tests.mons.pokedex_dex_fixture")
local PokedexKnowledge = require("libs.hgss.src.mons.PokedexKnowledge")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")
local ScriptErrors = require("libs.script.src.errors")
local S = require("gen4.script")

local T = {}

local SERVICE_MODULE = "game.hgss.src.pokedex.PokedexScriptService"

local function requireScriptService()
  local ok, service = pcall(require, SERVICE_MODULE)
  Assert.isTrue(ok, "the field script composition owns the dex count and grant service")
  return assert(service)
end

local function openWorld(seed, profileGender)
  local monCatalog = PokedexDexFixture.makeCatalog()
  local pokedexCatalog = PokedexDexFixture.buildPokedexCatalog()
  local owner = PokedexKnowledge.new(PokedexDexFixture.refs(monCatalog, pokedexCatalog))
  local ScriptService = requireScriptService()
  local profile = CatalogFixture.profile()
  profile.gender = profileGender or 0
  local eventState = FieldEventState.new()
  local service = ScriptService.new({
    dex = owner,
    catalog = pokedexCatalog,
    profile = profile,
    eventState = eventState,
  })
  local mons = HgssMonService.new({
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
  return {
    monCatalog = monCatalog,
    pokedexCatalog = pokedexCatalog,
    owner = owner,
    service = service,
    mons = mons,
    eventState = eventState,
    profile = profile,
  }
end

local function runWith(world, vars)
  local stored = vars or {}
  local host = {
    vars = stored,
    getVar = function(self, id)
      return self.vars[id]
    end,
    setVar = function(self, id, value)
      self.vars[id] = value
    end,
  }
  return {
    instance = { scriptId = "test.dex", locals = {}, textArgs = {} },
    services = { mons = world.mons, pokedex = world.service, world = host },
    semantics = RuntimeValues,
  }
end

local function var(id)
  return { value = "var", id = id }
end

local function seedHistory(world)
  world.owner
    :prepareChanges({
      caught = { "CHIKORITA", "EEVEE", "CUSTOM_IN", "CUSTOM_OUT_A", "CUSTOM_OUT_B" },
    })
    :publish()
end

function T.counts_follow_explicit_display_membership()
  local world = openWorld(0xC001)
  seedHistory(world)
  local run = runWith(world)
  local cases = {
    { mode = "johto", kind = "seen", expected = 2 },
    { mode = "johto", kind = "caught", expected = 2 },
    { mode = "national", kind = "seen", expected = 3 },
    { mode = "national", kind = "caught", expected = 3 },
  }
  for _, case in ipairs(cases) do
    local outcome = Runtime.executeNode({
      op = "pokedex_count",
      mode = case.mode,
      kind = case.kind,
      result = var("VAR_RESULT"),
    }, run)
    Assert.equal(outcome, Runtime.OUTCOME_CONTINUE, case.mode .. " " .. case.kind .. " continues the same tick")
    Assert.equal(
      run.services.world.vars.VAR_RESULT,
      case.expected,
      case.mode .. " " .. case.kind .. " counts explicit members without outsiders"
    )
  end
end

function T.evaluation_selects_bands_and_the_complete_message()
  local world = openWorld(0xC002)
  local run = runWith(world)
  Assert.equal(
    Runtime.executeNode({
      op = "pokedex_evaluate",
      mode = "johto",
      result = var("VAR_RESULT"),
      musicResult = var("VAR_MUSIC"),
    }, run),
    Runtime.OUTCOME_CONTINUE,
    "evaluation continues the same tick"
  )
  Assert.equal(run.services.world.vars.VAR_RESULT, 10, "an empty set reads the first band message")
  Assert.equal(run.services.world.vars.VAR_MUSIC, 1, "an incomplete set reads the incomplete music")

  world.owner:prepareChanges({ caught = { "CHIKORITA", "CUSTOM_IN" } }):publish()
  Assert.equal(
    Runtime.executeNode({
      op = "pokedex_evaluate",
      mode = "johto",
      result = var("VAR_RESULT"),
      musicResult = var("VAR_MUSIC"),
    }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(run.services.world.vars.VAR_RESULT, 11, "a complete set reads the male complete message")
  Assert.equal(run.services.world.vars.VAR_MUSIC, 2, "a complete set reads the complete music")
end

function T.evaluation_selects_the_female_complete_message()
  local world = openWorld(0xC003, 1)
  world.owner:prepareChanges({ caught = { "CHIKORITA", "CUSTOM_IN" } }):publish()
  local run = runWith(world)
  Runtime.executeNode({
    op = "pokedex_evaluate",
    mode = "johto",
    result = var("VAR_RESULT"),
    musicResult = var("VAR_MUSIC"),
  }, run)
  Assert.equal(run.services.world.vars.VAR_RESULT, 12, "a complete set reads the female complete message")
  Assert.equal(run.services.world.vars.VAR_MUSIC, 2, "a complete set reads the complete music")
end

function T.evaluation_writes_music_before_an_aliased_message()
  local world = openWorld(0xC004)
  world.owner:prepareChanges({ caught = { "CHIKORITA", "CUSTOM_IN" } }):publish()
  local run = runWith(world)
  Runtime.executeNode({
    op = "pokedex_evaluate",
    mode = "johto",
    result = var("VAR_SHARED"),
    musicResult = var("VAR_SHARED"),
  }, run)
  Assert.equal(run.services.world.vars.VAR_SHARED, 11, "an aliased output keeps the message value written last")
end

function T.completion_checks_read_the_explicit_sets()
  local world = openWorld(0xC005)
  seedHistory(world)
  local run = runWith(world)
  Runtime.executeNode({ op = "pokedex_complete", mode = "johto", result = var("VAR_JOHTO") }, run)
  Runtime.executeNode({ op = "pokedex_complete", mode = "national", result = var("VAR_NATIONAL") }, run)
  Assert.equal(run.services.world.vars.VAR_JOHTO, 1, "the johto set completes from its own members")
  Assert.equal(run.services.world.vars.VAR_NATIONAL, 0, "outsiders never counterfeit the national set")
end

function T.grant_publishes_before_the_story_notification()
  local world = openWorld(0xC006)
  local seenAtNotify = nil
  world.eventState:subscribe(function(change)
    if change.kind == "flag" and change.id == 107 then
      seenAtNotify = world.owner:hasPokedex()
    end
  end)
  local run = runWith(world)
  Assert.equal(Runtime.executeNode({ op = "has_pokedex", result = var("VAR_HAS") }, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(run.services.world.vars.VAR_HAS, 0, "the dex starts locked")
  Assert.equal(
    Runtime.executeNode({ op = "give_pokedex" }, run),
    Runtime.OUTCOME_CONTINUE,
    "the grant continues the same tick"
  )
  Assert.isTrue(world.owner:hasPokedex(), "the grant enables the owner")
  Assert.isTrue(seenAtNotify, "listeners observe the completed grant at notification time")
  Assert.isTrue(world.eventState:isFlagSet(107), "the grant writes the story compatibility flag")
  Runtime.executeNode({ op = "has_pokedex", result = var("VAR_HAS") }, run)
  Assert.equal(run.services.world.vars.VAR_HAS, 1, "the query observes the grant")

  world.eventState:clearFlag(107)
  Assert.isTrue(world.owner:hasPokedex(), "a generic story clear never revokes the owner")
end

function T.national_enable_syncs_the_profile_and_check_reads_the_owner()
  local world = openWorld(0xC007)
  local run = runWith(world)
  Runtime.executeNode({ op = "national_pokedex", action = "check", result = var("VAR_CHECK") }, run)
  Assert.equal(run.services.world.vars.VAR_CHECK, 0, "the check reads false before enabling")
  Assert.equal(
    Runtime.executeNode({ op = "national_pokedex", action = "enable", result = var("VAR_ENABLE") }, run),
    Runtime.OUTCOME_CONTINUE,
    "the enable continues the same tick"
  )
  Assert.equal(run.services.world.vars.VAR_ENABLE, 0, "the enable reports the source zero result")
  Assert.isTrue(world.owner:hasNationalDex(), "the enable publishes the owner flag")
  Assert.isTrue(world.profile.nationalDex, "the enable synchronizes the profile compatibility value")
  Runtime.executeNode({ op = "national_pokedex", action = "check", result = var("VAR_CHECK") }, run)
  Assert.equal(run.services.world.vars.VAR_CHECK, 1, "the check reads the enabled owner")

  local failure = Assert.throws(function()
    Runtime.executeNode({ op = "national_pokedex", action = "conquer", result = var("VAR_BAD") }, run)
  end)
  Assert.isTrue(Errors.is(failure), "an unknown national action is a structured script error")
end

function T.form_detection_enables_only_its_owner_flag()
  local world = openWorld(0xC008)
  local run = runWith(world)
  Assert.equal(
    Runtime.executeNode({ op = "enable_pokedex_form_detection" }, run),
    Runtime.OUTCOME_CONTINUE,
    "form detection continues the same tick"
  )
  Assert.isTrue(world.owner:canDetectForms(), "form detection enables its owner flag")
  Assert.isFalse(world.owner:hasPokedex(), "form detection grants no dex ownership")
end

function T.unown_alphabet_counts_caught_letters_only()
  local world = openWorld(0xC009)
  local run = runWith(world)
  for _, variant in ipairs({ 0, 5, 26, 27 }) do
    local descriptor = world.owner:describe(
      PokedexDexFixture.makeMon(world.monCatalog, { species = "UNOWN", form = variant, personality = variant })
    )
    world.owner:prepareChanges({ observations = { { kind = "caught", specimen = descriptor } } }):publish()
  end
  Assert.equal(
    Runtime.executeNode({ op = "caught_unown_count", result = var("VAR_COUNT") }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(run.services.world.vars.VAR_COUNT, 2, "the count ignores the two non-alphabet variants")
  Assert.equal(
    Runtime.executeNode({ op = "caught_all_unown_letters", result = var("VAR_ALL") }, run),
    Runtime.OUTCOME_YIELD_TICK,
    "the alphabet check yields one tick"
  )
  Assert.equal(run.services.world.vars.VAR_ALL, 0, "missing letters fail the alphabet check")

  for variant = 0, 25 do
    local descriptor = world.owner:describe(
      PokedexDexFixture.makeMon(world.monCatalog, { species = "UNOWN", form = variant, personality = 1000 + variant })
    )
    world.owner:prepareChanges({ observations = { { kind = "caught", specimen = descriptor } } }):publish()
  end
  Runtime.executeNode({ op = "caught_unown_count", result = var("VAR_COUNT") }, run)
  Assert.equal(run.services.world.vars.VAR_COUNT, 26, "the count reaches all twenty-six letters")
  Runtime.executeNode({ op = "caught_all_unown_letters", result = var("VAR_ALL") }, run)
  Assert.equal(run.services.world.vars.VAR_ALL, 1, "the full alphabet passes")
end

function T.synthetic_seen_and_query_execute_through_the_mon_service()
  local world = openWorld(0xC010)
  local run = runWith(world)
  local callsBefore = world.mons:capture().rng.calls
  Assert.equal(
    Runtime.executeNode({ op = "observe_species", species = "SPINDA" }, run),
    Runtime.OUTCOME_CONTINUE,
    "synthetic observation continues the same tick"
  )
  Assert.equal(world.mons:capture().rng.calls, callsBefore + 4, "synthetic observation runs the normal creation draws")
  Assert.equal(world.mons:partyCount(), 0, "synthetic observation inserts no party mon")
  Assert.isTrue(world.owner:isSeen("SPINDA"), "synthetic observation records the sighting")
  Assert.isFalse(world.owner:isCaught("SPINDA"), "synthetic observation records no capture")
  local queryBefore = world.mons:capture().rng.calls
  Assert.equal(
    Runtime.executeNode({ op = "has_seen_species", species = "SPINDA", result = var("VAR_SEEN") }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(run.services.world.vars.VAR_SEEN, 1, "the query observes the recorded sighting")
  Assert.equal(world.mons:capture().rng.calls, queryBefore, "the query consumes no generator draws")
end

function T.specialized_form_operations_execute_through_the_mon_service()
  local world = openWorld(0xC011)
  local factory = CatalogFixture.makeFactory(0xC011, world.monCatalog)
  local record = factory:createNormal({
    species = "DEOXYS",
    level = 20,
    form = 0,
    profile = CatalogFixture.profile(),
    ball = "POKE_BALL",
    location = 7,
    terrain = 4,
    date = CatalogFixture.metDate(),
    personality = 5,
  })
  Assert.isTrue(world.mons:addMon(record), "the setup mon enters the party structurally")
  local run = runWith(world)
  Assert.equal(
    Runtime.executeNode({ op = "set_party_deoxys_form", form = 2 }, run),
    Runtime.OUTCOME_YIELD_TICK,
    "the Deoxys change yields one tick after completing"
  )
  Assert.equal(world.mons:partyMon(0).form, 2, "the matching mon takes the requested form")
  Assert.isTrue(world.owner:isCaught("DEOXYS"), "the specialized change registers the species")
end

local function assertUnwired(node)
  local bare = {
    instance = { scriptId = "test.dex", locals = {}, textArgs = {} },
    services = {},
    semantics = RuntimeValues,
  }
  local ok, failure = pcall(Runtime.executeNode, node, bare)
  Assert.isFalse(ok, "an unwired dex operation never silently succeeds")
  if Errors.is(failure) then
    Assert.equal(failure.code, ScriptErrors.SCRIPT_SERVICE_MISSING, "the fault names the missing service")
  else
    Assert.isTrue(
      string.find(tostring(failure), "no runtime handler", 1, true) ~= nil,
      "without the operation surface the node stays explicitly unhandled"
    )
  end
end

function T.missing_services_fault_with_attribution()
  assertUnwired({ op = "pokedex_count", mode = "johto", kind = "seen", result = var("VAR_X") })
  assertUnwired({ op = "observe_species", species = "SPINDA" })
end

function T.constructors_expose_the_closed_operation_vocabulary()
  Assert.equal(
    S.pokedexCount({ mode = "johto", kind = "seen", result = var("VAR_RESULT") }).op,
    "pokedex_count",
    "the count constructor names its operation"
  )
  Assert.equal(S.givePokedex().op, "give_pokedex", "the grant constructor names its operation")
  Assert.equal(
    S.enablePokedexFormDetection().op,
    "enable_pokedex_form_detection",
    "the form-detection constructor names its operation"
  )
  Assert.equal(
    S.updateRotomForm({ slot = 0, defaultMoveSlot = 0, unused = 0, form = 1 }).op,
    "update_rotom_form",
    "the Rotom constructor names its operation"
  )
  local ok, err = S.validate(S.script({
    api = 1,
    id = "test.dex vocabulary",
    steps = {
      S.pokedexCount({ mode = "national", kind = "caught", result = var("VAR_RESULT"), bogus = 1 }),
    },
  }))
  Assert.isNil(ok, "unknown operation fields fail strict validation")
  Assert.isTrue(Errors.is(err), "strict validation reports a structured error")
  local modeOk, modeErr = S.validate(S.script({
    api = 1,
    id = "test.dex mode",
    steps = {
      S.pokedexCount({ mode = "kanto", kind = "seen", result = var("VAR_RESULT") }),
    },
  }))
  Assert.isNil(modeOk, "an illegal dex mode fails strict validation")
  Assert.isTrue(Errors.is(modeErr), "strict validation reports a structured error")
end

return { tests = T }
