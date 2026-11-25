-- Live-service query and bounded-mutation coverage: every named script
-- operation reads exact zero-based state through the aggregate, writes
-- source result conventions, mutates through the aggregate exactly once,
-- and fails explicitly on invalid identities or slots.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Errors = require("libs.errors.src.Errors")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local MonCatalog = require("libs.mons.src.MonCatalog")
local Party = require("libs.mons.src.Party")

local T = {}

local function openService(catalog, seed, opts)
  opts = opts or {}
  return HgssMonService.new({
    catalog = catalog,
    bucket = opts.bucket or MonsSave.capture(Party.new():capture(), Lcrng.new(seed):capture()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
    mapSection = opts.mapSection,
    date = opts.date,
    dateProvider = opts.dateProvider,
  })
end

local function gift(service, species, overrides)
  local request = {
    species = species,
    level = 5,
    heldItem = "NONE",
    form = 0,
    location = 7,
    date = CatalogFixture.metDate(),
  }
  for key, value in pairs(overrides or {}) do
    request[key] = value
  end
  return service:giveMon(request)
end

local function twoMonService(seed, opts)
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, seed or 0xAAAAAAAA, opts)
  Assert.isTrue(gift(service, "CHIKORITA"), "setup gift must enter the party")
  Assert.isTrue(gift(service, "TOTODILE"), "setup gift must enter the party")
  return catalog, service
end

local function formTypeCatalog(types)
  local root = CatalogFixture.buildAssetRoot()
  root.species.EEVEE.forms[1].types = types
  root.species.EEVEE.forms[1].abilities = { "RUN_AWAY", "ADAPTABILITY" }
  return MonCatalog.new(root, CatalogFixture.makeItemCatalog())
end

function T.counts_observe_the_live_party()
  local _, service = twoMonService()
  Assert.equal(service:partyCount(), 2)
  Assert.equal(service:partyCountNotEgg(), 2)
  Assert.equal(service:partyCountEgg(), 0)
  Assert.equal(service:countAliveMons(), 2)
  Assert.equal(service:countAliveMons(6), 2, "the party size excludes nothing")
  Assert.equal(service:countAliveMons(0), 1, "the excluded slot leaves the count")
  Assert.equal(service:partyCountAtOrBelowLevel(5), 2)
  Assert.equal(service:partyCountAtOrBelowLevel(4), 0)
  Assert.equal(service:countSpecies("CHIKORITA"), 1)
  Assert.equal(service:countSpecies("EEVEE"), 0)
end

function T.nickname_mutation_publishes_one_slot_and_survives_capture()
  local catalog, service = twoMonService()
  local revision = service:partyRevision()
  local untouched = service:partyMon(1)
  service:setNickname(0, "LEAF")
  Assert.equal(service:partyRevision(), revision + 1)
  Assert.equal(service:partyMon(0).nickname, "LEAF")
  Assert.deepEqual(service:partyMon(1), untouched)
  local restored = openService(catalog, 0xAAAAAAAA, { bucket = service:capture() })
  Assert.equal(restored:partyMon(0).nickname, "LEAF")
end

-- ScrCmd_PlayerHasSpecies answers for a non-egg member of one native species
-- identity: the source compares the raw species value and never counts eggs.
function T.player_has_species_answers_for_non_egg_members_only()
  local catalog, service = twoMonService()
  local chikorita = catalog:species("CHIKORITA").nativeId
  local totodile = catalog:species("TOTODILE").nativeId
  Assert.isTrue(service:scriptPlayerHasSpecies(chikorita), "the party's own species answers true")
  Assert.isTrue(service:scriptPlayerHasSpecies("TOTODILE"), "the semantic key answers the same query")
  Assert.isFalse(service:scriptPlayerHasSpecies(catalog:species("EEVEE").nativeId), "an absent species answers false")

  local egg = service:partyMon(0)
  egg.isEgg = true
  local preparation, stale = service:preparePartyChanges(service:partyRevision(), { { slot = 0, mon = egg } })
  Assert.isNil(stale, "the fixture stages the egg")
  assert(preparation).publish()
  Assert.isFalse(service:scriptPlayerHasSpecies(chikorita), "an egg never answers its own species")
  Assert.isTrue(service:scriptPlayerHasSpecies(totodile), "the other member still answers")
end

function T.searches_report_zero_based_slots_or_nothing()
  local _, service = twoMonService()
  Assert.equal(service:partySlotWithSpecies("CHIKORITA"), 0)
  Assert.equal(service:partySlotWithSpecies("TOTODILE"), 1)
  Assert.isNil(service:partySlotWithSpecies("EEVEE"), "absent species report nothing")
  Assert.equal(service:partySlotWithMove("TACKLE"), 0, "both starters open with tackle")
  Assert.isNil(service:partySlotWithMove("CUT"), "absent moves report nothing")
  local nature = service:monNature(1)
  Assert.equal(service:partySlotWithNature(nature), 1, "nature search finds the owning slot")
  Assert.isNil(service:partySlotWithFatefulEncounter(), "no setup mon is fateful")
end

function T.held_item_queries_include_eggs_and_exact_matches()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x44444444)
  local factory = CatalogFixture.makeFactory(0x55555555, catalog)
  local egg = factory:createNormal({
    species = "EEVEE",
    level = 5,
    form = 0,
    profile = CatalogFixture.profile(),
    ball = "POKE_BALL",
    location = 7,
    terrain = 4,
    date = CatalogFixture.metDate(),
  })
  egg.isEgg = true
  egg.heldItem = "SITRUS_BERRY"
  Assert.isTrue(service:addMon(egg), "the item-carrying egg enters the party")

  local other = factory:createNormal({
    species = "CHIKORITA",
    level = 5,
    form = 0,
    profile = CatalogFixture.profile(),
    ball = "POKE_BALL",
    location = 7,
    terrain = 4,
    date = CatalogFixture.metDate(),
  })
  other.heldItem = "POKE_BALL"
  Assert.isTrue(service:addMon(other), "the nonmatching mon enters the party")

  Assert.isTrue(service:partyHasHeldItem(158), "an egg-held item satisfies the query")
  Assert.isFalse(service:partyHasHeldItem(3), "an absent held item does not satisfy the query")
end

function T.reads_derive_identity_values_without_storing_them()
  local catalog, service = twoMonService()
  Assert.equal(service:partyMonSpecies(0), catalog:species("CHIKORITA").nativeId)
  Assert.equal(service:partyMonSpecies(1), catalog:species("TOTODILE").nativeId)
  Assert.isTrue(service:partyMonIsMine(0), "player-created mons are owned")
  Assert.isFalse(service:partyMonIsMine(9), "out-of-range ownership reads report false")
  local nature = service:monNature(0)
  Assert.isTrue(nature >= 0 and nature <= 24, "nature derives into 0..24")
  Assert.isTrue(service:monGender(0) == 0 or service:monGender(0) == 1, "starter gender is binary")
  Assert.equal(service:monForm(0), 0)
  Assert.equal(service:monFriendship(0), 70, "friendship opens at the species base")
  Assert.equal(service:monRibbonCount(0), 0)
  Assert.equal(service:partyRibbonCount(), 0)
  Assert.isFalse(service:partyHasPokerus(), "fresh mons carry no pokerus")
  Assert.isTrue(service:partyLegal(), "created mons pass native legality")
  Assert.isFalse(service:hasKyogreGroudon(), "the fixture party holds no cover mascot")
  Assert.equal(service:monMove(0, 0), catalog:move("TACKLE").nativeId)
  Assert.equal(service:countMonMoves(0), 2, "the starter opens with two level-up moves")
end

function T.script_type_queries_project_semantic_keys_to_native_ids()
  local cases = {
    { "normal", 0 },
    { "mystery", 9 },
    { "dark", 17 },
  }
  for _, case in ipairs(cases) do
    local catalog = formTypeCatalog({ case[1], case[1] })
    local service = openService(catalog, 0xA1000000 + case[2])
    Assert.isTrue(gift(service, "EEVEE", { form = 1 }), "the typed form enters the party")
    local type1, type2 = service:monTypes(0)
    Assert.equal(type1, case[2], "type one uses the native Gen-IV projection")
    Assert.equal(type2, case[2], "type two uses the native Gen-IV projection")
  end
end

function T.script_queries_leave_party_revision_unchanged()
  local catalog = formTypeCatalog({ "fire", "dark" })
  local service = openService(catalog, 0xA2000000)
  Assert.isTrue(gift(service, "EEVEE", { form = 1, heldItem = "SITRUS_BERRY" }))
  local revision = service:partyRevision()
  service:monTypes(0)
  service:scriptMonLevel(0)
  Assert.isTrue(service:partyHasHeldItem(158))
  Assert.equal(service:partyRevision(), revision, "direct mon queries do not publish a party mutation")
end

function T.bounded_mutations_clamp_and_bump_revision_once()
  local _, service = twoMonService()
  local revision = service:partyRevision()
  Assert.equal(service:monAddFriendship(0, 200), 255, "friendship clamps at the top")
  Assert.equal(service:partyRevision(), revision + 1, "the mutation bumps the revision once")
  Assert.equal(service:monSubFriendship(0, 255), 0, "friendship clamps at the bottom")
  Assert.equal(service:monAddContestValue(0, 0, 255), 255, "contest values clamp at the top")
  Assert.equal(service:monContestValue(0, 0), 255)
  service:setMove(0, 0, "CUT")
  Assert.equal(service:partyMon(0).moves[1].move, "CUT")
  service:deleteMove(0, 0)
  for _, entry in ipairs(service:partyMon(0).moves) do
    Assert.isTrue(entry.move ~= "CUT", "the deleted move is gone")
  end
end

function T.invalid_operations_fail_without_mutation()
  local _, service = twoMonService()
  local revision = service:partyRevision()
  local ok, err = pcall(function()
    return gift(service, "MISSINGNO")
  end)
  Assert.isFalse(ok, "unknown species fail explicitly")
  Assert.isTrue(Errors.is(err))
  Assert.equal(service:partyCount(), 2, "the failed gift adds nothing")
  Assert.equal(service:partyRevision(), revision, "the failed gift bumps no revision")
  local countErr = Assert.throws(function()
    service:countAliveMons(9)
  end)
  Assert.isTrue(Errors.is(countErr))
  Assert.throws(function()
    service:setMove(9, 0, "CUT")
  end)
  Assert.throws(function()
    service:setMove(0, 9, "CUT")
  end)
  Assert.throws(function()
    service:setMove(0, 0, "MISSINGMOVE")
  end)
  Assert.equal(service:partyRevision(), revision, "failed mutations bump no revision")
end

function T.gifts_accept_native_identities_and_default_ability_sentinels()
  local catalog, service = twoMonService(0xBBBBBBBB)
  Assert.isTrue(
    gift(service, 152, { heldItem = 0, ability = 0 }),
    "native identities resolve and zero keeps the default ability"
  )
  local mon = service:partyMon(2)
  Assert.equal(mon.species, "CHIKORITA")
  Assert.equal(mon.heldItem, "NONE")
  Assert.equal(mon.ability, catalog:form("CHIKORITA", 0).abilities[1])
  Assert.isTrue(gift(service, "EEVEE", { ability = 0xFFFF }), "the all-bits ability sentinel keeps the default ability")
end

function T.native_item_identities_resolve_through_the_catalog_alone()
  local catalog = CatalogFixture.makeCatalog()
  local service = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0xEEEEEEEE):capture()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    -- Independently maintained runtime maps disagree with the catalog about
    -- the same semantic item; creation still resolves the generated
    -- identity because nothing consults these maps.
    items = { NONE = 0, SITRUS_BERRY = 999 },
    balls = { POKE_BALL = 999 },
    mapSection = 7,
    date = CatalogFixture.metDate(),
  })
  Assert.isTrue(
    service:giveMon({
      species = "CHIKORITA",
      level = 5,
      heldItem = 158,
      form = 0,
      location = 7,
      date = CatalogFixture.metDate(),
    }),
    "a native item identity resolves without runtime tables"
  )
  Assert.equal(service:partyMon(0).heldItem, "SITRUS_BERRY", "the generated catalog names the native identity")
end

function T.gifts_resolve_context_location_and_date_from_the_service()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xCCCCCCCC, {
    mapSection = function()
      return 11
    end,
    dateProvider = function()
      return CatalogFixture.metDate()
    end,
  })
  Assert.isTrue(service:giveMon({ species = "CHIKORITA", level = 5 }), "context supplies section and date")
  local mon = service:partyMon(0)
  Assert.equal(mon.met.location, 11, "creation resolves the current map section first")
  Assert.equal(mon.met.terrain, 24, "script gifts use the source encounter type")
end

function T.return_loan_removes_through_the_aggregate()
  local _, service = twoMonService()
  local revision = service:partyRevision()
  local removed = service:returnLoanMon(0)
  Assert.equal(removed.species, "CHIKORITA")
  Assert.equal(service:partyCount(), 1)
  Assert.equal(service:partyMon(0).species, "TOTODILE")
  Assert.equal(service:partyRevision(), revision + 1)
  Assert.throws(function()
    service:returnLoanMon(5)
  end)
end

function T.add_mon_validates_and_reports_full_parties()
  local _, service = twoMonService()
  local extra = service:partyMon(0)
  Assert.isTrue(service:addMon(extra), "a legal mon enters with room")
  Assert.isTrue(service:addMon(extra))
  Assert.isTrue(service:addMon(extra))
  Assert.isTrue(service:addMon(extra))
  Assert.equal(service:partyCount(), 6)
  Assert.isFalse(service:addMon(extra), "the seventh mon reports false without storage")
  local broken = service:partyMon(0)
  broken.species = "MISSINGNO"
  Assert.throws(function()
    service:addMon(broken)
  end)
end

function T.heal_party_restores_full_health()
  local _, service = twoMonService()
  local revision = service:partyRevision()
  service:healParty()
  for slot = 0, 1 do
    local mon = service:partyMon(slot)
    Assert.deepEqual(mon.condition.effects, {}, "conditions clear")
    Assert.isTrue(mon.condition.currentHp > 0, "health is full")
  end
  Assert.equal(service:partyRevision(), revision + 2, "each restored mon is one owned mutation")
end

function T.heal_party_restores_pp_to_max()
  local catalog, service = twoMonService()
  local Moves = require("libs.mons.src.gen4.Moves")
  for slot = 0, 1 do
    local mon = service:partyMon(slot)
    Assert.isTrue(#mon.moves > 0, "setup mon carries a move")
    mon.moves[1].pp = 0
    if slot == 1 then
      mon.moves[1].ppUps = 2
    end
    mon.condition.currentHp = 1
    local staged, reason = service:preparePartyChanges(service:partyRevision(), { { slot = slot, mon = mon } })
    Assert.notNil(staged, "setup depletion must prepare: " .. tostring(reason))
    staged.publish()
  end
  service:healParty()
  for slot = 0, 1 do
    local mon = service:partyMon(slot)
    for _, entry in ipairs(mon.moves) do
      local expected = Moves.maxPp(catalog:move(entry.move).basePp, entry.ppUps)
      Assert.equal(entry.pp, expected, "healed move restores to max PP")
    end
  end
end

function T.derived_display_values_come_from_the_service_owners()
  local _, service = twoMonService()
  local derived = service:partyMonDerived(0)
  Assert.equal(derived.level, 5, "gifted starters open at level five")
  Assert.isTrue(derived.maxHp > 0, "max HP derives positive at level five")
  local mon = service:partyMon(0)
  Assert.equal(mon.condition.currentHp, derived.maxHp, "fresh mons open at full health")
  Assert.throws(function()
    service:partyMonDerived(9)
  end, "derived reads outside the party fail")
end

-- The capsule confirmation clears the ball capsule and its seals in one
-- party revision, pinned to the revision it was asked about, and an empty
-- capsule answers no change.
function T.remove_capsule_clears_the_ball_capsule_once()
  local _, service = twoMonService()
  local revision = service:partyRevision()
  local mon = service:partyMon(0)
  mon.capsule = { id = 5, seals = { { x = 1, y = 2, graphic = 3 } } }
  local prepared = assert(service:preparePartyChanges(revision, { { slot = 0, mon = mon } }))
  prepared.publish()
  local current = service:partyRevision()
  Assert.isTrue(service:removeCapsule(0, current), "a present capsule changes")
  Assert.equal(service:partyMon(0).capsule.id, 0)
  Assert.equal(#service:partyMon(0).capsule.seals, 0)
  Assert.equal(service:partyRevision(), current + 1, "the removal publishes one revision")
  Assert.isFalse(service:removeCapsule(0, service:partyRevision()), "an empty capsule reports no change")
  Assert.throws(function()
    service:removeCapsule(0, service:partyRevision() + 1)
  end, "a stale confirmation is refused before any change")
end

-- The source form sanitizer returns a detached canonical copy and never
-- publishes; a species the three source updaters do not own keeps its own form.
-- The Rotom/Giratina/Shaymin normalization itself is exercised through the real
-- Day Care script by the feature acceptance suite.
function T.ordinary_form_mon_is_a_detached_source_sanitize()
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0xBBBBBBBB)
  Assert.isTrue(gift(service, "EEVEE", { form = 1 }), "setup gift enters the party")
  Assert.equal(service:partyMon(0).form, 1)
  local revision = service:partyRevision()
  local sanitized = service:ordinaryFormMon(service:partyMon(0))
  Assert.equal(sanitized.form, 1, "a species outside the source updaters keeps its own form")
  Assert.equal(sanitized.ability, catalog:form("EEVEE", 1).abilities[1], "the alternate form keeps its own ability")
  Assert.equal(service:partyRevision(), revision, "sanitize never publishes")
  sanitized.species = "TOTODILE"
  Assert.equal(service:partyMon(0).species, "EEVEE", "the returned record is detached")
  local ordinary = service:partyMon(0)
  ordinary.form = 0
  local prepared = assert(service:preparePartyChanges(service:partyRevision(), { { slot = 0, mon = ordinary } }))
  prepared.publish()
  Assert.deepEqual(service:ordinaryFormMon(service:partyMon(0)), service:partyMon(0), "an ordinary form comes back unchanged")
end

-- ScrCmd_CountAliveMonsAndPC adds every stored PC box mon to the party count.
function T.stored_mon_count_covers_the_pc_boxes()
  local _, service = twoMonService()
  Assert.equal(service:storedMonCount(), 0, "an empty PC stores nothing")
  local mon = service:partyMon(0)
  mon.capsule = { id = 0, seals = {} }
  local prepared = assert(service:preparePcChanges({
    partyRevision = service:partyRevision(),
    boxRevision = service:boxRevision(),
  }, { boxUpdates = { { box = 0, slot = 0, mon = mon } } }))
  prepared.publish()
  Assert.equal(service:storedMonCount(), 1, "one stored mon counts once")
  Assert.equal(service:countAliveMons() + service:storedMonCount(), 3, "the care screen count adds both owners")
end

return { tests = T }
