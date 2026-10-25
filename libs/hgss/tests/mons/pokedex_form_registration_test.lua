-- Specialized form registration through the live party service: the
-- Deoxys operation restages every matching party mon with its new form
-- and records their final specimens in party order, while the Rotom
-- operation performs the full appliance-move replacement, ability, and
-- stat update before registering the selected specimen. The generic
-- form assignment changes only the form and records nothing, and a
-- failed specialized change publishes neither party nor history. Uses
-- the small synthetic mon/catalog fixtures extended with distinct form
-- stats and the appliance moves so recalculation stays observable; no
-- ROM, GPU, or product cache is touched.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local Errors = require("libs.errors.src.Errors")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PokedexDexFixture = require("libs.hgss.tests.mons.pokedex_dex_fixture")
local PokedexKnowledge = require("libs.hgss.src.mons.PokedexKnowledge")

local T = {}

local function statSet(hp, attack, defense, speed, specialAttack, specialDefense)
  return {
    hp = hp,
    attack = attack,
    defense = defense,
    speed = speed,
    specialAttack = specialAttack,
    specialDefense = specialDefense,
  }
end

local function moveEntry(nativeId, basePp)
  return {
    nativeId = nativeId,
    name = "move-" .. nativeId,
    description = "fixture appliance move",
    effect = 0,
    category = "special",
    power = 80,
    moveType = "electric",
    accuracy = 100,
    basePp = basePp,
    effectChance = 0,
    range = 0,
    priority = 0,
    flags = 0,
    unknownC = 0,
    contestType = 0,
  }
end

-- The fixture root clones one template across forms, which would hide a
-- missed stat/ability recalculation behind identical values. Distinct
-- per-form stats and abilities keep the specialized update observable.
local function formationRoot()
  local root = PokedexDexFixture.buildMonRoot()
  root.moves.OVERHEAT = moveEntry(315, 5)
  root.moves.HYDRO_PUMP = moveEntry(56, 5)
  root.moves.BLIZZARD = moveEntry(59, 5)
  root.moves.AIR_SLASH = moveEntry(403, 15)
  root.moves.LEAF_STORM = moveEntry(437, 5)
  root.moves.THUNDER_SHOCK = moveEntry(84, 30)
  local deoxysStats = {
    statSet(50, 95, 90, 90, 95, 90),
    statSet(50, 180, 20, 150, 180, 20),
    statSet(50, 70, 160, 90, 70, 160),
    statSet(50, 95, 90, 180, 95, 90),
  }
  local deoxysAbilities = { "PRESSURE", "STATIC", "OVERGROW", "TORRENT" }
  root.abilities.PRESSURE = { nativeId = 46, name = "Pressure", description = "Pressure" }
  for form = 0, 3 do
    root.species.DEOXYS.forms[form].baseStats = deoxysStats[form + 1]
    root.species.DEOXYS.forms[form].abilities = { deoxysAbilities[form + 1] }
  end
  local rotomStats = {
    statSet(50, 65, 107, 86, 105, 107),
    statSet(50, 65, 107, 86, 130, 107),
    statSet(50, 65, 107, 86, 130, 107),
    statSet(50, 65, 107, 86, 130, 107),
    statSet(50, 65, 107, 86, 130, 107),
    statSet(50, 65, 107, 86, 130, 107),
  }
  local rotomAbilities = { "STATIC", "OVERGROW", "TORRENT", "RUN_AWAY", "ADAPTABILITY", "WONDER_GUARD" }
  for form = 0, 5 do
    root.species.ROTOM.forms[form].baseStats = rotomStats[form + 1]
    root.species.ROTOM.forms[form].abilities = { rotomAbilities[form + 1] }
  end
  return root
end

local function openWorld(seed)
  local root = formationRoot()
  local monCatalog = PokedexDexFixture.makeCatalog(root)
  local owner = PokedexKnowledge.new(PokedexDexFixture.refs(monCatalog, PokedexDexFixture.buildPokedexCatalog()))
  local service = HgssMonService.new({
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
  local factory = CatalogFixture.makeFactory(seed, monCatalog)
  return { root = root, monCatalog = monCatalog, owner = owner, service = service, factory = factory }
end

local function admit(world, fields)
  local record = world.factory:createNormal({
    species = fields.species,
    level = fields.level or 20,
    form = fields.form or 0,
    profile = CatalogFixture.profile(),
    ball = "POKE_BALL",
    location = 7,
    terrain = 4,
    date = CatalogFixture.metDate(),
    personality = fields.personality,
  })
  if fields.moves ~= nil then
    record.moves = fields.moves
  end
  if fields.currentHp ~= nil then
    record.condition.currentHp = fields.currentHp
  end
  Assert.isTrue(world.service:addMon(record), "setup mons enter the party structurally")
  return record
end

local function moveOf(mon, slot1)
  local entry = assert(mon.moves[slot1], "the moveset carries slot " .. slot1)
  return { move = entry.move, pp = entry.pp, ppUps = entry.ppUps }
end

local function requireSpecialized(service)
  Assert.isTrue(
    type(service.setPartyDeoxysForm) == "function",
    "the specialized Deoxys change restages matching mons and registers them"
  )
  Assert.isTrue(
    type(service.updateRotomForm) == "function",
    "the specialized Rotom change restages the selected mon and registers it"
  )
end

function T.deoxys_change_restages_every_match_in_party_order()
  local world = openWorld(0xD501)
  requireSpecialized(world.service)
  admit(world, { species = "DEOXYS", form = 0, personality = 11 })
  admit(world, { species = "CHIKORITA", personality = 0 })
  admit(world, { species = "DEOXYS", form = 1, personality = 22 })
  local beforeAttack = {
    world.service:derive(world.service:partyMon(0)).attack,
    world.service:derive(world.service:partyMon(2)).attack,
  }
  local partyRevision = world.service:partyRevision()
  local dexRevision = world.owner:revision()

  world.service:setPartyDeoxysForm(2)

  local first = world.service:partyMon(0)
  local middle = world.service:partyMon(1)
  local last = world.service:partyMon(2)
  Assert.equal(first.form, 2, "the first matching mon takes the requested form")
  Assert.equal(last.form, 2, "the later matching mon takes the requested form")
  Assert.equal(middle.form, 0, "non-matching mons keep their form")
  Assert.equal(middle.species, "CHIKORITA", "non-matching mons keep their species")
  Assert.equal(first.personality, 11, "party order keeps each match on its own slot")
  Assert.equal(last.personality, 22, "party order keeps each match on its own slot")
  Assert.isTrue(world.service:derive(first).attack ~= beforeAttack[1], "the first mon recalculates its stats")
  Assert.isTrue(world.service:derive(last).attack ~= beforeAttack[2], "the later mon recalculates its stats")
  Assert.equal(first.ability, "OVERGROW", "the first mon selects the new form ability")
  Assert.equal(last.ability, "OVERGROW", "the later mon selects the new form ability")
  Assert.isTrue(world.owner:isCaught("DEOXYS"), "the specialized change registers the species")
  Assert.deepEqual(
    world.owner:caughtVariants("DEOXYS"),
    {},
    "ordered policies without caught memory keep no caught list"
  )
  Assert.deepEqual(
    world.owner:observedVariants("DEOXYS"),
    { 2 },
    "the staged final specimens register their new logical variant"
  )
  Assert.equal(world.service:partyRevision(), partyRevision + 1, "one party mutation covers every match")
  Assert.equal(world.owner:revision(), dexRevision + 1, "one history mutation covers every match")
end

function T.deoxys_change_without_a_match_is_a_noop()
  local world = openWorld(0xD502)
  requireSpecialized(world.service)
  admit(world, { species = "CHIKORITA", personality = 0 })
  local partyRevision = world.service:partyRevision()
  local dexRevision = world.owner:revision()

  world.service:setPartyDeoxysForm(3)

  Assert.equal(world.service:partyMon(0).form, 0, "the party is untouched without a match")
  Assert.equal(world.service:partyRevision(), partyRevision, "no match publishes no party mutation")
  Assert.isFalse(world.owner:isCaught("DEOXYS"), "no match records no capture")
  Assert.equal(world.owner:revision(), dexRevision, "no match publishes no history")
end

function T.generic_form_assignment_records_no_history()
  local world = openWorld(0xD503)
  admit(world, { species = "EEVEE", form = 0, personality = 11 })
  local dexRevision = world.owner:revision()

  world.service:setMonForm(0, 1)

  Assert.equal(world.service:partyMon(0).form, 1, "the generic assignment still changes the form")
  Assert.isFalse(world.owner:isSeen("EEVEE"), "the generic assignment records no sighting")
  Assert.isFalse(world.owner:isCaught("EEVEE"), "the generic assignment records no capture")
  Assert.equal(world.owner:revision(), dexRevision, "the generic assignment publishes no history")
end

function T.rotom_change_replaces_the_first_appliance_move()
  local world = openWorld(0xD504)
  requireSpecialized(world.service)
  admit(world, {
    species = "ROTOM",
    form = 0,
    personality = 33,
    moves = {
      { move = "HYDRO_PUMP", pp = 2, ppUps = 1 },
      { move = "TACKLE", pp = 35, ppUps = 0 },
    },
  })
  local beforeSpecialAttack = world.service:derive(world.service:partyMon(0)).specialAttack

  world.service:updateRotomForm(0, 0, 0, 1)

  local mon = world.service:partyMon(0)
  Assert.equal(mon.form, 1, "the mon takes the requested appliance form")
  Assert.deepEqual(
    moveOf(mon, 1),
    { move = "OVERHEAT", pp = 5, ppUps = 0 },
    "the first appliance move is replaced at base power points without boosts"
  )
  Assert.deepEqual(moveOf(mon, 2), { move = "TACKLE", pp = 35, ppUps = 0 }, "ordinary moves survive the appliance swap")
  Assert.equal(mon.ability, "OVERGROW", "the mon selects the new form ability")
  Assert.isTrue(world.service:derive(mon).specialAttack ~= beforeSpecialAttack, "the mon recalculates its stats")
  Assert.isTrue(world.owner:isCaught("ROTOM"), "the specialized change registers the species")
end

function T.rotom_change_deletes_later_appliance_moves_and_compacts()
  local world = openWorld(0xD505)
  requireSpecialized(world.service)
  admit(world, {
    species = "ROTOM",
    form = 0,
    personality = 44,
    moves = {
      { move = "OVERHEAT", pp = 5, ppUps = 3 },
      { move = "HYDRO_PUMP", pp = 5, ppUps = 0 },
      { move = "TACKLE", pp = 35, ppUps = 0 },
    },
  })

  world.service:updateRotomForm(0, 0, 0, 2)

  local mon = world.service:partyMon(0)
  Assert.equal(mon.form, 2, "the mon takes the requested appliance form")
  Assert.deepEqual(
    moveOf(mon, 1),
    { move = "HYDRO_PUMP", pp = 5, ppUps = 0 },
    "the first appliance slot carries the requested move without boosts"
  )
  Assert.deepEqual(
    moveOf(mon, 2),
    { move = "TACKLE", pp = 35, ppUps = 0 },
    "later appliance moves are deleted and the moveset compacts"
  )
  Assert.isNil(mon.moves[3], "no trailing empty slot survives compaction")
end

function T.rotom_change_uses_the_default_slot_when_full_and_repairs_an_empty_set()
  local world = openWorld(0xD506)
  requireSpecialized(world.service)
  admit(world, {
    species = "ROTOM",
    form = 0,
    personality = 55,
    moves = {
      { move = "TACKLE", pp = 35, ppUps = 0 },
      { move = "GROWL", pp = 40, ppUps = 0 },
      { move = "SCRATCH", pp = 35, ppUps = 0 },
      { move = "LEER", pp = 30, ppUps = 0 },
    },
  })

  world.service:updateRotomForm(0, 1, 0, 3)

  local mon = world.service:partyMon(0)
  Assert.deepEqual(
    moveOf(mon, 2),
    { move = "BLIZZARD", pp = 5, ppUps = 0 },
    "a full moveset gains its appliance move through the default slot"
  )
  Assert.equal(mon.moves[1].move, "TACKLE", "the other full-moveset slots survive")
  Assert.equal(#mon.moves, 4, "the moveset stays at four slots")
end

function T.rotom_return_to_base_repairs_an_emptied_moveset()
  local world = openWorld(0xD507)
  requireSpecialized(world.service)
  admit(world, {
    species = "ROTOM",
    form = 1,
    personality = 66,
    moves = {
      { move = "OVERHEAT", pp = 5, ppUps = 0 },
    },
  })

  world.service:updateRotomForm(0, 0, 0, 0)

  local mon = world.service:partyMon(0)
  Assert.equal(mon.form, 0, "the mon returns to its base form")
  Assert.deepEqual(
    moveOf(mon, 1),
    { move = "THUNDER_SHOCK", pp = 30, ppUps = 0 },
    "an emptied moveset is repaired with the base move at base power points"
  )
  Assert.isNil(mon.moves[2], "the repaired moveset carries exactly one move")
end

function T.rotom_change_on_a_non_rotom_registers_without_mutating()
  local world = openWorld(0xD508)
  requireSpecialized(world.service)
  local before = admit(world, {
    species = "CHIKORITA",
    personality = 0,
    moves = {
      { move = "TACKLE", pp = 35, ppUps = 0 },
      { move = "GROWL", pp = 40, ppUps = 0 },
    },
  })

  world.service:updateRotomForm(0, 0, 0, 1)

  local mon = world.service:partyMon(0)
  Assert.equal(mon.form, before.form, "a non-Rotom keeps its form")
  Assert.deepEqual(mon.moves, before.moves, "a non-Rotom keeps its moveset")
  Assert.isTrue(world.owner:isCaught("CHIKORITA"), "the caller still registers the unchanged specimen")
end

function T.rotom_change_keeps_a_fainted_mon_fainted()
  local world = openWorld(0xD509)
  requireSpecialized(world.service)
  admit(world, {
    species = "ROTOM",
    form = 0,
    personality = 77,
    currentHp = 0,
    moves = {
      { move = "TACKLE", pp = 35, ppUps = 0 },
    },
  })
  local beforeMax = world.service:derive(world.service:partyMon(0)).maxHp

  world.service:updateRotomForm(0, 0, 0, 4)

  local mon = world.service:partyMon(0)
  Assert.equal(mon.condition.currentHp, 0, "the form change never revives a fainted mon")
  Assert.isTrue(beforeMax > 0, "setup starts from a positive maximum")
end

function T.invalid_specialized_changes_fail_atomically()
  local world = openWorld(0xD510)
  requireSpecialized(world.service)
  admit(world, {
    species = "ROTOM",
    form = 0,
    personality = 88,
    moves = {
      { move = "TACKLE", pp = 35, ppUps = 0 },
      { move = "GROWL", pp = 40, ppUps = 0 },
      { move = "SCRATCH", pp = 35, ppUps = 0 },
      { move = "LEER", pp = 30, ppUps = 0 },
    },
  })
  local partyRevision = world.service:partyRevision()
  local dexRevision = world.owner:revision()

  local badForm = Assert.throws(function()
    world.service:updateRotomForm(0, 0, 0, 9)
  end)
  Assert.isTrue(Errors.is(badForm), "an illegal appliance form is a structured service error")
  local badSlot = Assert.throws(function()
    world.service:updateRotomForm(0, 9, 0, 1)
  end)
  Assert.isTrue(Errors.is(badSlot), "an unusable default slot is a structured service error")

  local mon = world.service:partyMon(0)
  Assert.equal(mon.form, 0, "failed changes keep the form")
  Assert.equal(mon.moves[2].move, "GROWL", "failed changes keep the moveset")
  Assert.isFalse(world.owner:isCaught("ROTOM"), "failed changes record no capture")
  Assert.equal(world.service:partyRevision(), partyRevision, "failed changes publish no party mutation")
  Assert.equal(world.owner:revision(), dexRevision, "failed changes publish no history")
end

return { tests = T }
