-- Native trainer parties: every party-member shape (plain, custom moves, held
-- item, both) materializes exact identity, level, moves, items, friendship,
-- and stats; rival selection follows the saved name and story branch; the
-- surrounding battle stream is untouched by generation; and templates
-- without native numeric inputs build only through a declared generation
-- policy. Vectors are fixed here from the native trainer layout; nothing is
-- produced by the modules under test.

local Assert = require("tests.support.Assert")
local BattleRng = require("libs.battle.src.gen4.BattleRng")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local ItemFixture = require("libs.items.tests.item_fixture")

local CATALOG_MODULE = "libs.hgss.src.battle.HgssTrainerCatalog"
local FACTORY_MODULE = "libs.hgss.src.battle.HgssTrainerFactory"

local T = {}

local FIXED_SEED = 287454020

---@param name string module path under test
---@param behavior string observable behavior the module owns
---@return table the loaded module
local function requirePresent(name, behavior)
  local ok, loaded = pcall(require, name)
  Assert.isTrue(ok, "missing trainer behavior: " .. behavior .. " (" .. name .. ")")
  assert(loaded ~= nil, "the trainer module loads")
  return loaded --[[@as table]]
end

---@param seed integer
---@return table labeled native stream recording every draw site
local function spyStream(seed)
  local inner = BattleRng.new(seed)
  local labels = {}
  local stream = {}
  function stream:nextU16(label, cause)
    labels[#labels + 1] = label
    return inner:nextU16(label, cause)
  end
  function stream:capture()
    return inner:capture()
  end
  function stream:drawLabels()
    local out = {}
    for index, label in ipairs(labels) do
      out[index] = label
    end
    return out
  end
  return stream
end

---@param overrides table<string, unknown>|nil
---@return table<string, unknown> native-identity member template
local function plainMember(overrides)
  local member = {
    species = "CHIKORITA",
    form = 0,
    level = 5,
    difficulty = 3,
    heldItem = "NONE",
    moves = nil,
    friendship = 70,
    identityPolicy = "native_pid",
    identityParams = { genderOverride = 0, abilityOverride = 0, capsule = 0 },
  }
  for key, value in pairs(overrides or {}) do
    member[key] = value
  end
  return member
end

---@param trainers table<string, table> trainer records keyed by trainer key
---@param programs table<string, table>|nil selection programs keyed by program key
---@return table compiled catalog input honoring the producer schema
local function compiledInput(trainers, programs)
  return { trainers = trainers, programs = programs or {} }
end

---@param key string|integer
---@param party table[]
---@param extra table<string, unknown>|nil
---@return table<string, unknown> catalog trainer record
local function trainerRecord(key, party, extra)
  local record = {
    key = key,
    trainerClass = 2,
    nameReference = { trainerIndex = 8 },
    party = party,
    aiPasses = {},
    doubleBattle = false,
    items = {},
  }
  for field, value in pairs(extra or {}) do
    record[field] = value
  end
  return record
end

---@param catalog table immutable trainer catalog under test
---@param trainerKey string
---@param stream table
---@param extra table<string, unknown>|nil
---@return table build context in source field order
local function buildContext(catalog, trainerKey, stream, extra)
  local context = {
    catalog = catalog,
    trainerKey = trainerKey,
    playerProfile = { name = "GOLD", id = 12345 },
    rivalName = "SILVER",
    rng = stream,
  }
  for key, value in pairs(extra or {}) do
    context[key] = value
  end
  return context
end

-- The shared synthetic domain catalog extended with the
-- disappointment-driven move, so learnsets, power points, and validation
-- resolve through real domain facts.
---@return table mon catalog with the vector moves and forms
local function vectorMonCatalog()
  local MonCatalog = require("libs.mons.src.MonCatalog")
  local root = CatalogFixture.buildAssetRoot()
  root.moves.FRUSTRATION = {
    nativeId = 218,
    name = "Frustration",
    description = "A spiteful attack.",
    effect = 0,
    category = "physical",
    power = 102,
    moveType = "normal",
    accuracy = 100,
    basePp = 20,
    effectChance = 0,
    range = 0,
    priority = 0,
    flags = 0,
    unknownC = 0,
    contestType = 0,
  }
  return MonCatalog.new(root, ItemFixture.makeCatalog())
end

---@return table domain validation context for the vector catalog
local function vectorContext(monCatalog)
  return {
    catalog = monCatalog,
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
  }
end

-- Test plumbing for the materializer under test: every build threads the
-- real domain catalog and creation context, so generation proves its
-- domain records instead of shape-only projections.
---@param trainerCatalog table immutable trainer catalog under test
---@param monCatalog table domain mon catalog behind generated records
---@return table the party materializer under test
local function vectorFactory(trainerCatalog, monCatalog)
  local Factory = require(FACTORY_MODULE)
  return Factory.new({
    catalog = trainerCatalog,
    monCatalog = monCatalog,
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    game = "heartgold",
    language = "english",
  })
end

---@param mon table built party mon under test
---@param label string
local function assertProjectable(mon, label)
  local Mon = require("libs.mons.src.Mon")
  Assert.equal(mon.schema, Mon.SCHEMA, label .. " carries the domain schema")
  Assert.isTrue(type(mon.species) == "string" and mon.species ~= "", label .. " carries a species key")
  Assert.isTrue(type(mon.personality) == "number", label .. " carries a personality value")
  Assert.isTrue(
    mon.personality >= 0 and mon.personality <= 4294967295,
    label .. " personality fits an unsigned 32-bit value"
  )
  local ivs = assert(mon.ivs, label .. " carries individual values")
  for _, stat in ipairs({ "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }) do
    Assert.equal(ivs[stat], 0, label .. " " .. stat .. " maps the template difficulty through floor(difficulty*31/255) to 0")
  end
  local condition = assert(mon.condition, label .. " carries its battle condition")
  Assert.isTrue(
    type(condition.currentHp) == "number" and condition.currentHp >= 1,
    label .. " enters with positive health"
  )
  Assert.isTrue(type(mon.moves) == "table" and #mon.moves >= 1, label .. " carries domain move entries")
  for _, entry in ipairs(mon.moves) do
    Assert.isTrue(type(entry.move) == "string" and entry.move ~= "", label .. " move entries name move keys")
    Assert.isTrue(type(entry.pp) == "number" and entry.pp >= 1, label .. " move entries carry power points")
  end
end

-- Plain members resolve their initial learnset, carry no held item, and
-- echo the template friendship onto validated domain records.
function T.plain_members_materialize_identity_level_learned_moves_and_stats()
  local Catalog = requirePresent(CATALOG_MODULE, "immutable trainer templates resolve runtime content keys")
  requirePresent(FACTORY_MODULE, "source trainer generation builds native parties")
  local Mon = require("libs.mons.src.Mon")
  local MonStats = require("libs.mons.src.gen4.MonStats")
  Assert.isTrue(type(Catalog.new) == "function", "the catalog constructs from validated producer data")
  Assert.isTrue(type(Catalog.trainer) == "function", "the catalog exposes trainer templates")
  local monCatalog = vectorMonCatalog()
  local catalog = Catalog.new(compiledInput({
    [8] = trainerRecord("youngster", { plainMember(), plainMember({ species = "TOTODILE", level = 6 }) }),
  }))
  local factory = vectorFactory(catalog, monCatalog)
  Assert.isTrue(type(factory.build) == "function", "the factory builds whole parties")
  Assert.isTrue(type(factory.buildNativeMon) == "function", "the factory builds single native mons")
  local party = factory:build(buildContext(catalog, 8, spyStream(FIXED_SEED)))
  local mons = assert(party.mons, "built parties carry their ordered mons")
  Assert.equal(#mons, 2, "the party keeps its ordered slots")
  Assert.equal(mons[1].species, "CHIKORITA", "the first slot keeps its species identity")
  Assert.equal(mons[2].species, "TOTODILE", "the second slot keeps its species identity")
  Assert.equal(MonStats.derive(mons[1], monCatalog).level, 5, "the first slot keeps its level")
  Assert.equal(MonStats.derive(mons[2], monCatalog).level, 6, "the second slot keeps its level")
  for index, mon in ipairs(mons) do
    local ok = pcall(Mon.validate, mon, vectorContext(monCatalog))
    Assert.isTrue(ok, "slot " .. index .. " validates against the domain catalog")
    assertProjectable(mon, "slot " .. index)
    Assert.equal(mon.heldItem, "NONE", "plain members carry no held item")
    Assert.equal(mon.friendship, 70, "template friendship survives generation")
  end
  Assert.deepEqual(
    mons[1].moves,
    { { move = "TACKLE", pp = 35, ppUps = 0 }, { move = "GROWL", pp = 40, ppUps = 0 } },
    "plain members resolve their native initial learnset with catalog power points"
  )
end

-- All four party shapes preserve their exact move and item records,
-- including the zero-friendship edge that powers full-strength
-- disappointment-driven moves and the full-friendship edge behind
-- affection-driven moves.
function T.custom_moves_and_held_items_survive_all_party_shapes()
  local Catalog = requirePresent(CATALOG_MODULE, "immutable trainer templates resolve runtime content keys")
  requirePresent(FACTORY_MODULE, "source trainer generation builds native parties")
  local monCatalog = vectorMonCatalog()
  local catalog = Catalog.new(compiledInput({
    [9] = trainerRecord("shaped", {
      plainMember(),
      plainMember({
        species = "TOTODILE",
        level = 5,
        moves = { "SCRATCH", "LEER", "WATER_GUN", "TACKLE" },
      }),
      plainMember({ species = "EEVEE", level = 4, heldItem = "SITRUS_BERRY" }),
      plainMember({
        species = "TOTODILE",
        level = 5,
        heldItem = "SITRUS_BERRY",
        friendship = 0,
        moves = { "SCRATCH", "LEER", "WATER_GUN", "TACKLE" },
      }),
    }, { nameReference = { trainerIndex = 9 } }),
  }))
  local factory = vectorFactory(catalog, monCatalog)
  local party = factory:build(buildContext(catalog, 9, spyStream(FIXED_SEED)))
  local mons = assert(party.mons, "built parties carry their ordered mons")
  Assert.equal(#mons, 4, "every party shape occupies its ordered slot")
  Assert.isTrue(#mons[2].moves == 4, "custom moves keep all four slots")
  Assert.deepEqual(
    mons[2].moves,
    {
      { move = "SCRATCH", pp = 35, ppUps = 0 },
      { move = "LEER", pp = 30, ppUps = 0 },
      { move = "WATER_GUN", pp = 25, ppUps = 0 },
      { move = "TACKLE", pp = 35, ppUps = 0 },
    },
    "custom moves survive in source order with catalog power points"
  )
  Assert.equal(mons[2].heldItem, "NONE", "moves-only members carry no held item")
  Assert.equal(mons[3].heldItem, "SITRUS_BERRY", "item-only members keep their held item")
  Assert.deepEqual(
    mons[3].moves,
    { { move = "TACKLE", pp = 35, ppUps = 0 }, { move = "TAIL_WHIP", pp = 30, ppUps = 0 } },
    "item-only members still resolve their native initial learnset"
  )
  Assert.deepEqual(
    mons[4].moves,
    {
      { move = "SCRATCH", pp = 35, ppUps = 0 },
      { move = "LEER", pp = 30, ppUps = 0 },
      { move = "WATER_GUN", pp = 25, ppUps = 0 },
      { move = "TACKLE", pp = 35, ppUps = 0 },
    },
    "combined members keep custom moves in source order"
  )
  Assert.equal(mons[4].heldItem, "SITRUS_BERRY", "combined members keep their held item")
  Assert.equal(mons[4].friendship, 0, "the zero-friendship edge survives generation")
  local loyal = plainMember({
    species = "EEVEE",
    level = 5,
    friendship = 255,
    moves = { "TACKLE", "GROWL", "TAIL_WHIP", "QUICK_ATTACK" },
  })
  local single = factory:buildNativeMon(loyal, buildContext(catalog, 9, spyStream(FIXED_SEED)))
  Assert.equal(single.friendship, 255, "the full-friendship edge survives generation")
end

-- Gender and ability overrides, alternate forms, and capsule facts land on
-- the built mon exactly as the template declares them.
function T.gender_ability_form_and_capsule_overrides_apply()
  local Catalog = requirePresent(CATALOG_MODULE, "immutable trainer templates resolve runtime content keys")
  requirePresent(FACTORY_MODULE, "source trainer generation builds native parties")
  local Mon = require("libs.mons.src.Mon")
  local Personality = require("libs.mons.src.gen4.Personality")
  local monCatalog = vectorMonCatalog()
  local catalog = Catalog.new(compiledInput({
    [10] = trainerRecord("overridden", {
      plainMember({
        species = "EEVEE",
        identityParams = { genderOverride = 1, abilityOverride = 1, capsule = 7 },
        form = 0,
      }),
      plainMember({ species = "EEVEE", form = 1 }),
    }, { nameReference = { trainerIndex = 10 } }),
  }))
  local factory = vectorFactory(catalog, monCatalog)
  local party = factory:build(buildContext(catalog, 10, spyStream(FIXED_SEED)))
  local mons = assert(party.mons, "built parties carry their ordered mons")
  for index, mon in ipairs(mons) do
    local ok = pcall(Mon.validate, mon, vectorContext(monCatalog))
    Assert.isTrue(ok, "slot " .. index .. " validates against the domain catalog")
  end
  Assert.equal(
    Personality.gender(monCatalog:species("EEVEE").genderRatio, mons[1].personality),
    "male",
    "the gender override selects male"
  )
  Assert.equal(mons[1].ability, "RUN_AWAY", "the ability override selects the first slot")
  Assert.equal(mons[1].capsule.id, 7, "the capsule fact survives generation")
  Assert.deepEqual(mons[1].capsule.seals, {}, "generated capsules carry no seals")
  Assert.equal(mons[2].form, 1, "the alternate form survives generation")
end

-- Rival parties follow the saved rival name and the story branch instead of
-- a fixed roster: the name stays an indirection and each branch deals its
-- own ordered party.
function T.rival_selection_follows_the_saved_name_and_story_branch()
  local Catalog = requirePresent(CATALOG_MODULE, "immutable trainer templates resolve runtime content keys")
  requirePresent(FACTORY_MODULE, "source trainer generation builds native parties")
  local monCatalog = vectorMonCatalog()
  local catalog = Catalog.new(compiledInput({
    [27] = trainerRecord("rival", {
      plainMember({ species = "CHIKORITA", level = 5 }),
    }, {
      trainerClass = 23,
      nameReference = { rival = true },
      variants = {
        elm = { party = { plainMember({ species = "CHIKORITA", level = 5 }) } },
        finals = { party = { plainMember({ species = "TOTODILE", level = 38 }) } },
      },
    }),
  }))
  local factory = vectorFactory(catalog, monCatalog)
  local early = factory:build(buildContext(catalog, 27, spyStream(FIXED_SEED), { storyVariant = "elm" }))
  Assert.equal(early.name, "SILVER", "the rival name resolves from the save profile")
  Assert.equal(early.mons[1].species, "CHIKORITA", "the early branch deals its ordered party")
  local late = factory:build(buildContext(catalog, 27, spyStream(FIXED_SEED), { storyVariant = "finals" }))
  Assert.equal(late.name, "SILVER", "the name indirection holds across branches")
  Assert.equal(late.mons[1].species, "TOTODILE", "the late branch deals its ordered party")
  local renamed = factory:build(
    buildContext(catalog, 27, spyStream(FIXED_SEED), { storyVariant = "elm", rivalName = "GARY" })
  )
  Assert.equal(renamed.name, "GARY", "renaming the rival flows through the indirection")
end

-- Generation saves and restores the surrounding battle stream: the
-- position is bit-identical afterwards, and rebuilding from the same seed
-- reproduces every personality and individual value exactly.
function T.generation_leaves_the_surrounding_random_stream_untouched()
  local Catalog = requirePresent(CATALOG_MODULE, "immutable trainer templates resolve runtime content keys")
  requirePresent(FACTORY_MODULE, "source trainer generation builds native parties")
  local monCatalog = vectorMonCatalog()
  local catalog = Catalog.new(compiledInput({
    [8] = trainerRecord("falkner", {
      plainMember(),
      plainMember({
        species = "TOTODILE",
        level = 7,
        difficulty = 5,
        heldItem = "SITRUS_BERRY",
        moves = { "SCRATCH", "LEER", "WATER_GUN", "TACKLE" },
      }),
    }),
  }))
  local factory = vectorFactory(catalog, monCatalog)
  local stream = spyStream(FIXED_SEED)
  local before = stream:capture()
  local first = factory:build(buildContext(catalog, 8, stream))
  Assert.deepEqual(stream:capture(), before, "generation restores the surrounding stream position")
  local second = factory:build(buildContext(catalog, 8, spyStream(FIXED_SEED)))
  local firstMons = assert(first.mons, "built parties carry their ordered mons")
  local secondMons = assert(second.mons, "rebuilt parties carry their ordered mons")
  Assert.equal(#firstMons, #secondMons, "rebuilds keep the same slot count")
  for index, mon in ipairs(firstMons) do
    Assert.equal(mon.personality, secondMons[index].personality, "slot " .. index .. " replays its personality")
    Assert.deepEqual(mon.ivs, secondMons[index].ivs, "slot " .. index .. " replays its individual values")
    Assert.deepEqual(mon.moves, secondMons[index].moves, "slot " .. index .. " replays its moves")
  end
end

-- Templates without native numeric inputs cannot borrow the native formula
-- silently: they build only through a declared semantic policy, and the
-- native path rejects them loudly.
function T.templates_without_native_inputs_require_a_declared_policy()
  local Catalog = requirePresent(CATALOG_MODULE, "immutable trainer templates resolve runtime content keys")
  requirePresent(FACTORY_MODULE, "source trainer generation builds native parties")
  local Mon = require("libs.mons.src.Mon")
  local monCatalog = vectorMonCatalog()
  local catalog = Catalog.new(compiledInput({
    [11] = trainerRecord("custom", {}),
  }))
  local factory = vectorFactory(catalog, monCatalog)
  local declared = {
    species = "EEVEE",
    level = 10,
    identityPolicy = "gift_birth",
    moves = { "TACKLE", "GROWL", "TAIL_WHIP", "QUICK_ATTACK" },
    heldItem = "SITRUS_BERRY",
    friendship = 120,
  }
  local built = factory:buildNativeMon(declared, buildContext(catalog, 11, spyStream(FIXED_SEED)))
  Assert.equal(built.species, "EEVEE", "the declared policy builds the requested species")
  Assert.equal(built.heldItem, "SITRUS_BERRY", "the declared policy keeps the declared item")
  local ok = pcall(Mon.validate, built, vectorContext(monCatalog))
  Assert.isTrue(ok, "the declared policy still yields a valid domain record")
  local bare = { species = "EEVEE", level = 10 }
  Assert.throws(function()
    factory:buildNativeMon(bare, buildContext(catalog, 11, spyStream(FIXED_SEED)))
  end, "native generation without native inputs or a declared policy fails")
end

-- Native-source integration: the compiled dump catalog loads through the
-- runtime catalog with every party shape, the rival indirection, and native
-- order intact. A missing dump fails loudly instead of skipping.
function T.compiled_native_trainers_expose_every_party_shape(context)
  local GameVersion = require("romdump.src.source.GameVersion")
  local RomImporter = require("romdump.src.source.RomImporter")
  local ready = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      ready[#ready + 1] = versionId
    end
  end
  Assert.isTrue(#ready > 0, "the native trainer integration needs a ready dump in the private cache")
  assert(context ~= nil, "the runner provides a test context")
  local Catalog = requirePresent(CATALOG_MODULE, "immutable trainer templates resolve runtime content keys")
  local Compiler = require("romdump.src.digest.battle.TrainerCatalogCompiler")
  local seenShapes = {}
  local seenRival = false
  for _, versionId in ipairs(ready) do
    local RomFs = require("romdump.src.source.RomFs")
    local romFs = assert(RomFs.open(versionId))
    local compiled = assert(Compiler.compileFromDump(romFs, { versionId = versionId }))
    romFs:close()
    local catalog = Catalog.new(compiled)
    local order = Catalog.order and Catalog.order(catalog) or nil
    local keys = {}
    if order ~= nil then
      keys = order
    else
      for key in pairs(compiled.trainers) do
        keys[#keys + 1] = key
      end
      table.sort(keys)
    end
    Assert.isTrue(#keys > 0, versionId .. " carries trainer records")
    for _, key in ipairs(keys) do
      local template = Catalog.trainer(catalog, key)
      Assert.notNil(template, versionId .. " trainer " .. tostring(key) .. " loads")
      local record = assert(template, "the template loads")
      Assert.isTrue(type(record.party) == "table" and #record.party > 0, "parties keep ordered members")
      for _, member in ipairs(record.party) do
        local shape = (member.moves ~= nil and "moves" or "plain") .. "+" .. (member.heldItem ~= "NONE" and "item" or "noitem")
        seenShapes[shape] = true
      end
      if record.nameReference ~= nil and record.nameReference.rival == true then
        seenRival = true
        local resolved = Catalog.resolveName and Catalog.resolveName(catalog, key, { rivalName = "SILVER" })
        if resolved ~= nil then
          Assert.equal(resolved, "SILVER", "the rival indirection resolves from the save name")
        end
      end
    end
  end
  for _, shape in ipairs({ "plain+noitem", "moves+noitem", "plain+item", "moves+item" }) do
    Assert.isTrue(seenShapes[shape] == true, "the native catalog exercises party shape " .. shape)
  end
  Assert.isTrue(seenRival, "the native catalog carries the rival indirection")
end

-- Source-exact trainer vectors below. Every literal is fixed here from the
-- native trainer-party layout (numeric species, class, difficulty, and
-- override nibbles combined through the unsigned generator exactly as the
-- native party builder does); nothing is produced by the modules under
-- test. The mon catalog is the shared synthetic domain catalog extended
-- with the disappointment-driven move, so learnsets, power points, and
-- validation resolve through real domain facts.

---@param party table[] ordered member templates
---@param extra table<string, unknown>|nil
---@return table<string, unknown> catalog trainer record with a numeric class
local function numericTrainerRecord(party, extra)
  local record = {
    trainerClass = 2,
    nameReference = { trainerIndex = 8 },
    party = party,
    aiPasses = {},
    doubleBattle = false,
    items = {},
  }
  for field, value in pairs(extra or {}) do
    record[field] = value
  end
  return record
end

---@param overrides table<string, unknown>|nil
---@return table<string, unknown> native-identity member template with numeric facts
local function vectorMember(overrides)
  local member = {
    species = "CHIKORITA",
    form = 0,
    level = 5,
    difficulty = 3,
    heldItem = "NONE",
    moves = nil,
    friendship = 70,
    identityPolicy = "native_pid",
    identityParams = { genderOverride = 0, abilityOverride = 0, capsule = 0 },
  }
  for key, value in pairs(overrides or {}) do
    member[key] = value
  end
  return member
end

-- A field runtime reduced to its battle-request composition: the live
-- party snapshots empty, the world state carries no battle, and the
-- trainer catalog/materializer are the composed runtime fields the
-- launch path resolves through.
---@param fields table<string, unknown> runtime fields backing the launch
---@return table field runtime fake carrying the trainer composition
local function fieldLaunchRuntime(fields)
  local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
  local runtime = setmetatable({
    monService = {
      partyCount = function()
        return 0
      end,
    },
    bagService = nil,
    scripts = { worldState = { rng = {} } },
    battleRuntime = nil,
  }, FieldRuntime)
  for key, value in pairs(fields) do
    runtime[key] = value
  end
  return runtime
end

-- A native trainer launch carries only its numeric identity: the launch
-- path resolves the compiled template, materializes every member into a
-- valid domain record, and shapes the detached scenario without any
-- caller-authored party.
function T.numeric_trainer_launches_resolve_their_compiled_party_into_the_scenario()
  local Catalog = requirePresent(CATALOG_MODULE, "immutable trainer templates resolve runtime content keys")
  requirePresent(FACTORY_MODULE, "source trainer generation builds native parties")
  local Mon = require("libs.mons.src.Mon")
  local MonStats = require("libs.mons.src.gen4.MonStats")
  local monCatalog = vectorMonCatalog()
  local trainerCatalog = Catalog.new({
    trainers = {
      [8] = numericTrainerRecord({
        vectorMember(),
        vectorMember({
          species = "TOTODILE",
          level = 7,
          difficulty = 5,
          moves = { "SCRATCH", "LEER", "WATER_GUN", "TACKLE" },
        }),
      }),
    },
    programs = {},
  })
  local runtime = fieldLaunchRuntime({
    monCatalog = monCatalog,
    _trainerCatalog = trainerCatalog,
    _trainerFactory = vectorFactory(trainerCatalog, monCatalog),
  })
  local scenario = runtime:_scenarioForRequest({ kind = "trainer", payload = { trainer = 8 } })
  Assert.equal(scenario.kind, "trainer", "the launch shapes a trainer scenario")
  local roster = assert(scenario.participants[2], "the enemy side fields its trainer").roster
  Assert.equal(#roster, 2, "both compiled slots reach the scenario in order")
  local first = assert(roster[1].mon, "the lead slot carries its materialized record")
  local second = assert(roster[2].mon, "the second slot carries its materialized record")
  Assert.equal(first.species, "CHIKORITA", "the lead slot keeps its compiled species")
  Assert.equal(second.species, "TOTODILE", "the second slot keeps its compiled species")
  Assert.equal(MonStats.derive(first, monCatalog).level, 5, "the lead slot keeps its compiled level")
  Assert.equal(MonStats.derive(second, monCatalog).level, 7, "the second slot keeps its compiled level")
  for index, mon in ipairs({ first, second }) do
    local ok, canonical = pcall(Mon.validate, mon, vectorContext(monCatalog))
    Assert.isTrue(ok, "slot " .. index .. " materializes a valid domain record")
    Assert.equal(canonical.schema, Mon.SCHEMA, "slot " .. index .. " carries the domain schema")
  end
  local trainer = assert(scenario.trainer, "the scenario retains its trainer metadata")
  local entry = assert(trainer[1] or trainer, "the trainer metadata names its entry")
  local identity = entry.id or entry.trainer or scenario.participants[2].controller
  Assert.isTrue(identity == 8 or identity == "trainer:8", "the native identity survives resolution")
end

-- Unknown trainer identities fail during launch preparation with the
-- missing identity named: no generic party stands in, and no battle
-- lifetime starts.
function T.unknown_trainer_identities_fail_before_a_battle_starts()
  local Catalog = requirePresent(CATALOG_MODULE, "immutable trainer templates resolve runtime content keys")
  requirePresent(FACTORY_MODULE, "source trainer generation builds native parties")
  local monCatalog = vectorMonCatalog()
  local trainerCatalog = Catalog.new({
    trainers = {
      [8] = numericTrainerRecord({ vectorMember() }),
    },
    programs = {},
  })
  local runtime = fieldLaunchRuntime({
    monCatalog = monCatalog,
    _trainerCatalog = trainerCatalog,
    _trainerFactory = vectorFactory(trainerCatalog, monCatalog),
  })
  local ok, err = pcall(runtime._scenarioForRequest, runtime, {
    kind = "trainer",
    payload = { trainer = 9999 },
  })
  Assert.isFalse(ok, "an unknown trainer identity fails preparation")
  local message = tostring(err)
  Assert.isTrue(message:find("9999", 1, true) ~= nil, "the failure names the missing identity")
  Assert.isTrue(
    message:lower():find("unknown", 1, true) ~= nil,
    "the failure reports an unknown trainer rather than a missing party"
  )
  Assert.isNil(runtime.battleRuntime, "no battle lifetime starts for an unknown trainer")
end

-- Native party generation follows the source formula exactly: the seed
-- sums difficulty, level, numeric species, and trainer identity; the
-- generator advances once per trainer-class index; the personality
-- combines the final generator output with the class/override selector;
-- individual values spread the difficulty uniformly; plain members learn
-- their native initial moveset; custom moves keep source order with
-- catalog power points; held items, forms, and capsule facts survive;
-- and the disappointment-driven move forces zero friendship.
function T.native_generation_follows_the_source_seed_and_identity_formula()
  local Catalog = requirePresent(CATALOG_MODULE, "immutable trainer templates resolve runtime content keys")
  requirePresent(FACTORY_MODULE, "source trainer generation builds native parties")
  local Mon = require("libs.mons.src.Mon")
  local MonStats = require("libs.mons.src.gen4.MonStats")
  local monCatalog = vectorMonCatalog()
  local context = vectorContext(monCatalog)
  local shedinja = vectorMember({ species = "SHEDINJA", level = 4, difficulty = 0 })
  shedinja.friendship = nil
  local trainerCatalog = Catalog.new({
    trainers = {
      [8] = numericTrainerRecord({
        vectorMember(),
        vectorMember({
          species = "TOTODILE",
          level = 7,
          difficulty = 5,
          heldItem = "SITRUS_BERRY",
          moves = { "SCRATCH", "LEER", "WATER_GUN", "TACKLE" },
        }),
        shedinja,
      }),
      [9] = numericTrainerRecord(
        {
          vectorMember({
            species = "EEVEE",
            level = 6,
            difficulty = 200,
            heldItem = "SITRUS_BERRY",
            identityParams = { genderOverride = 1, abilityOverride = 1, capsule = 7 },
          }),
          vectorMember({
            species = "EEVEE",
            form = 1,
            level = 10,
            difficulty = 255,
            heldItem = "NONE",
            friendship = 255,
            moves = { "FRUSTRATION", "TACKLE" },
            identityParams = { genderOverride = 2, abilityOverride = 2, capsule = 0 },
          }),
        },
        { trainerClass = 1, nameReference = { trainerIndex = 9 } }
      ),
    },
    programs = {},
  })
  local factory = vectorFactory(trainerCatalog, monCatalog)
  local stream = spyStream(FIXED_SEED)
  local before = stream:capture()
  local party = factory:build(buildContext(trainerCatalog, 8, stream))
  local mons = assert(party.mons, "built parties carry their ordered mons")
  Assert.deepEqual(stream:capture(), before, "generation leaves the surrounding stream untouched")
  Assert.equal(#mons, 3, "every compiled slot materializes in order")

  local expectedPersonalities = { 10761096, 4099464, 693640 }
  local expectedLevels = { 5, 7, 4 }
  local expectedMaxHp = { 19, 24, 1 }
  for index, mon in ipairs(mons) do
    local ok, canonical = pcall(Mon.validate, mon, context)
    Assert.isTrue(ok, "slot " .. index .. " validates against the domain catalog")
    Assert.equal(mon.personality, expectedPersonalities[index], "slot " .. index .. " matches its source personality")
    local derived = MonStats.derive(canonical, monCatalog)
    Assert.equal(derived.level, expectedLevels[index], "slot " .. index .. " keeps its compiled level")
    Assert.equal(mon.condition.currentHp, expectedMaxHp[index], "slot " .. index .. " enters at full health")
    Assert.equal(derived.maxHp, expectedMaxHp[index], "slot " .. index .. " derives its native maximum")
  end

  local derivedOne = MonStats.derive(mons[1], monCatalog)
  Assert.deepEqual(
    { derivedOne.attack, derivedOne.defense, derivedOne.speed, derivedOne.specialAttack, derivedOne.specialDefense },
    { 9, 9, 9, 9, 12 },
    "the lead slot derives its native stats"
  )
  Assert.deepEqual(
    mons[1].moves,
    { { move = "TACKLE", pp = 35, ppUps = 0 }, { move = "GROWL", pp = 40, ppUps = 0 } },
    "plain members learn their native initial moveset with catalog power points"
  )
  Assert.deepEqual(
    mons[2].moves,
    {
      { move = "SCRATCH", pp = 35, ppUps = 0 },
      { move = "LEER", pp = 30, ppUps = 0 },
      { move = "WATER_GUN", pp = 25, ppUps = 0 },
      { move = "TACKLE", pp = 35, ppUps = 0 },
    },
    "custom moves keep source order with catalog power points"
  )
  Assert.equal(mons[2].heldItem, "SITRUS_BERRY", "the held item survives generation")
  Assert.equal(mons[1].friendship, 70, "template friendship survives without the disappointment move")
  Assert.equal(mons[3].friendship, 255, "an absent template friendship defaults to full")

  local femaleParty = factory:build(buildContext(trainerCatalog, 9, spyStream(FIXED_SEED)))
  local femaleMons = assert(femaleParty.mons, "the second trainer materializes its ordered mons")
  Assert.equal(#femaleMons, 2, "both female-class slots materialize")
  Assert.equal(femaleMons[1].personality, 6918688, "the override slot matches its source personality")
  Assert.equal(femaleMons[2].personality, 9586461, "the disappointment slot matches its source personality")
  for index, mon in ipairs(femaleMons) do
    local ok = pcall(Mon.validate, mon, context)
    Assert.isTrue(ok, "female-class slot " .. index .. " validates against the domain catalog")
  end
  Assert.deepEqual(
    femaleMons[1].moves,
    { { move = "TACKLE", pp = 35, ppUps = 0 }, { move = "TAIL_WHIP", pp = 30, ppUps = 0 } },
    "item-only members still learn their native initial moveset"
  )
  Assert.equal(femaleMons[1].heldItem, "SITRUS_BERRY", "the item-only member keeps its held item")
  Assert.equal(femaleMons[1].ability, "RUN_AWAY", "the ability override selects the first slot")
  Assert.equal(femaleMons[2].ability, "ADAPTABILITY", "the second override selects the second slot")
  Assert.equal(femaleMons[2].form, 1, "the alternate form survives generation")
  Assert.equal(femaleMons[1].capsule.id, 7, "the capsule fact survives generation")
  Assert.deepEqual(
    femaleMons[2].moves,
    { { move = "FRUSTRATION", pp = 20, ppUps = 0 }, { move = "TACKLE", pp = 35, ppUps = 0 } },
    "the disappointment custom moves keep source order"
  )
  Assert.equal(femaleMons[2].friendship, 0, "the disappointment-driven move forces zero friendship")
  local femaleDerived = MonStats.derive(femaleMons[2], monCatalog)
  Assert.equal(femaleDerived.level, 10, "the disappointment slot keeps its compiled level")
  Assert.equal(femaleDerived.maxHp, 34, "the disappointment slot derives its native maximum")

  local replayed = factory:build(buildContext(trainerCatalog, 8, spyStream(FIXED_SEED)))
  local replayedMons = assert(replayed.mons, "rebuilt parties carry their ordered mons")
  for index, mon in ipairs(mons) do
    Assert.equal(mon.personality, replayedMons[index].personality, "slot " .. index .. " replays its personality")
    Assert.deepEqual(mon.ivs, replayedMons[index].ivs, "slot " .. index .. " replays its individual values")
    Assert.deepEqual(mon.moves, replayedMons[index].moves, "slot " .. index .. " replays its moves")
  end
end

-- Dump-backed materialization: real compiled trainers resolve through the
-- runtime catalog and materialize valid domain parties whose ordered
-- levels and class match the compiled record exactly; rebuilding under a
-- renamed rival replays every personality, proving the name indirection
-- never enters the party seed. A missing dump fails loudly instead of
-- skipping.
function T.dump_backed_trainers_materialize_ordered_parties_matching_the_compiled_record(context)
  local GameVersion = require("romdump.src.source.GameVersion")
  local RomImporter = require("romdump.src.source.RomImporter")
  local ready = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      ready[#ready + 1] = versionId
    end
  end
  Assert.isTrue(#ready > 0, "trainer materialization needs a ready dump in the private cache")
  assert(context ~= nil, "the runner provides a test context")
  local Catalog = requirePresent(CATALOG_MODULE, "immutable trainer templates resolve runtime content keys")
  local Factory = requirePresent(FACTORY_MODULE, "source trainer generation builds native parties")
  local Mon = require("libs.mons.src.Mon")
  local MonStats = require("libs.mons.src.gen4.MonStats")
  local MonCatalog = require("libs.mons.src.MonCatalog")
  local MonCatalogCompiler = require("romdump.src.digest.mons.MonCatalogCompiler")
  local MonSources = require("romdump.src.config.MonSources")
  local Compiler = require("romdump.src.digest.battle.TrainerCatalogCompiler")
  for _, versionId in ipairs(ready) do
    local RomFs = require("romdump.src.source.RomFs")
    local romFs = assert(RomFs.open(versionId))
    local compiled = assert(Compiler.compileFromDump(romFs, { versionId = versionId }))
    local monRoot = assert(MonCatalogCompiler.compileCatalog(romFs, { versionId = versionId }))
    romFs:close()
    local monCatalog = MonCatalog.new(monRoot, ItemFixture.makeCatalog())
    local domain = {
      catalog = monCatalog,
      charmap = CatalogFixture.CHARMAP,
      games = CatalogFixture.GAMES,
      languages = CatalogFixture.LANGUAGES,
    }
    local catalog = Catalog.new(compiled)
    local factory = Factory.new({
      catalog = catalog,
      monCatalog = monCatalog,
      charmap = CatalogFixture.CHARMAP,
      games = CatalogFixture.GAMES,
      languages = CatalogFixture.LANGUAGES,
      game = versionId,
      language = MonSources.versionLanguages[versionId],
    })
    local keys = {}
    for key in pairs(compiled.trainers) do
      keys[#keys + 1] = key
    end
    table.sort(keys)
    Assert.isTrue(#keys > 0, versionId .. " carries trainer records")
    local samples = {}
    for _, key in ipairs(keys) do
      if #samples < 3 then
        samples[#samples + 1] = key
      end
    end
    local rivalKey = nil
    for _, key in ipairs(keys) do
      local template = Catalog.trainer(catalog, key)
      if template ~= nil and template.nameReference ~= nil and template.nameReference.rival == true then
        rivalKey = key
        break
      end
    end
    if rivalKey ~= nil then
      samples[#samples + 1] = rivalKey
    end
    for _, key in ipairs(samples) do
      local template = assert(Catalog.trainer(catalog, key), versionId .. " trainer " .. key .. " loads")
      local bundle = factory:build({ trainerKey = key, rivalName = "SILVER", rng = spyStream(FIXED_SEED) })
      Assert.equal(bundle.trainerClass, template.trainerClass, "trainer " .. key .. " keeps its native class")
      local mons = assert(bundle.mons, "trainer " .. key .. " materializes its ordered mons")
      Assert.equal(#mons, #template.party, "trainer " .. key .. " keeps every ordered slot")
      for index, mon in ipairs(mons) do
        local ok = pcall(Mon.validate, mon, domain)
        Assert.isTrue(ok, "trainer " .. key .. " slot " .. index .. " validates")
        Assert.equal(
          MonStats.derive(mon, monCatalog).level,
          template.party[index].level,
          "trainer " .. key .. " slot " .. index .. " keeps its compiled level"
        )
      end
      if template.nameReference ~= nil and template.nameReference.rival == true then
        local renamed = factory:build({ trainerKey = key, rivalName = "GARY", rng = spyStream(FIXED_SEED) })
        local renamedMons = assert(renamed.mons, "the renamed rival keeps its ordered mons")
        Assert.equal(renamed.name, "GARY", "the rival name stays an indirection")
        for index, mon in ipairs(mons) do
          Assert.equal(
            mon.personality,
            renamedMons[index].personality,
            "the rival seed ignores the display name"
          )
        end
      end
    end
  end
end

return { tests = T }
