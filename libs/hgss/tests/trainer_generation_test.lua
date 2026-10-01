-- Native trainer parties: every party-member shape (plain, custom moves, held
-- item, both) materializes exact identity, level, moves, items, friendship,
-- and stats; rival selection follows the saved name and story branch; the
-- surrounding battle stream is untouched by generation; and templates
-- without native numeric inputs build only through a declared generation
-- policy. Vectors are fixed here from the native trainer layout; nothing is
-- produced by the modules under test.

local Assert = require("tests.support.Assert")
local BattleRng = require("libs.battle.src.gen4.BattleRng")

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

---@param moves string[]
---@param item string
---@return table<string, unknown> member template with custom moves and a held item
local function customMember(moves, item)
  return plainMember({
    species = "CYNDAQUIL",
    level = 7,
    difficulty = 5,
    heldItem = item,
    moves = moves,
    friendship = 0,
  })
end

---@param trainers table<string, table> trainer records keyed by trainer key
---@param programs table<string, table>|nil selection programs keyed by program key
---@return table compiled catalog input honoring the producer schema
local function compiledInput(trainers, programs)
  return { trainers = trainers, programs = programs or {} }
end

---@param key string
---@param party table[]
---@param extra table<string, unknown>|nil
---@return table<string, unknown> catalog trainer record
local function trainerRecord(key, party, extra)
  local record = {
    key = key,
    trainerClass = "YOUNGSTER",
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

---@param mon table built party mon under test
---@param label string
local function assertProjectable(mon, label)
  Assert.isTrue(type(mon.species) == "string" and mon.species ~= "", label .. " carries a species key")
  Assert.isTrue(type(mon.level) == "number" and mon.level >= 1, label .. " carries a level")
  Assert.isTrue(type(mon.personality) == "number", label .. " carries a personality value")
  Assert.isTrue(
    mon.personality >= 0 and mon.personality <= 4294967295,
    label .. " personality fits an unsigned 32-bit value"
  )
  local ivs = assert(mon.ivs, label .. " carries individual values")
  for _, stat in ipairs({ "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }) do
    Assert.equal(ivs[stat], 0, label .. " " .. stat .. " maps the template difficulty through floor(difficulty*31/255) to 0")
  end
  local stats = assert(mon.stats, label .. " carries battle stats")
  for _, stat in ipairs({ "hp", "attack", "defense", "speed", "specialAttack", "specialDefense" }) do
    Assert.isTrue(type(stats[stat]) == "number" and stats[stat] >= 1, label .. " stat " .. stat .. " is positive")
  end
end

-- Plain members resolve their initial learnset, carry no held item, and
-- echo the template friendship onto byte-projectable records.
function T.plain_members_materialize_identity_level_learned_moves_and_stats()
  local Catalog = requirePresent(CATALOG_MODULE, "immutable trainer templates resolve runtime content keys")
  local Factory = requirePresent(FACTORY_MODULE, "source trainer generation builds native parties")
  Assert.isTrue(type(Catalog.new) == "function", "the catalog constructs from validated producer data")
  Assert.isTrue(type(Catalog.trainer) == "function", "the catalog exposes trainer templates")
  local catalog = Catalog.new(compiledInput({
    falkner = trainerRecord("falkner", { plainMember(), plainMember({ species = "PIDGEY", level = 6 }) }),
  }))
  local factory = Factory.new({ catalog = catalog })
  Assert.isTrue(type(factory.build) == "function", "the factory builds whole parties")
  Assert.isTrue(type(factory.buildNativeMon) == "function", "the factory builds single native mons")
  local party = factory:build(buildContext(catalog, "falkner", spyStream(FIXED_SEED)))
  local mons = assert(party.mons, "built parties carry their ordered mons")
  Assert.equal(#mons, 2, "the party keeps its ordered slots")
  Assert.equal(mons[1].species, "CHIKORITA", "the first slot keeps its species identity")
  Assert.equal(mons[1].level, 5, "the first slot keeps its level")
  Assert.equal(mons[2].species, "PIDGEY", "the second slot keeps its species identity")
  Assert.equal(mons[2].level, 6, "the second slot keeps its level")
  for index, mon in ipairs(mons) do
    assertProjectable(mon, "slot " .. index)
    Assert.equal(mon.heldItem, "NONE", "plain members carry no held item")
    Assert.equal(mon.friendship, 70, "template friendship survives generation")
    Assert.isTrue(type(mon.moves) == "table" and #mon.moves >= 1, "plain members resolve initial-learnset moves")
    for _, move in ipairs(mon.moves) do
      Assert.isTrue(type(move) == "string" and move ~= "", "resolved moves name move keys")
    end
  end
end

-- All four party shapes preserve their exact move and item records,
-- including the zero-friendship edge that powers full-strength
-- disappointment-driven moves and the full-friendship edge behind
-- affection-driven moves.
function T.custom_moves_and_held_items_survive_all_party_shapes()
  local Catalog = requirePresent(CATALOG_MODULE, "immutable trainer templates resolve runtime content keys")
  local Factory = requirePresent(FACTORY_MODULE, "source trainer generation builds native parties")
  local catalog = Catalog.new(compiledInput({
    shaped = trainerRecord("shaped", {
      plainMember(),
      plainMember({ species = "TOTODILE", level = 5, moves = { "SCRATCH", "LEER", "RAGE", "WATER_GUN" } }),
      plainMember({ species = "SENTRET", level = 4, heldItem = "ORAN_BERRY" }),
      customMember({ "EMBER", "LEER", "SMOKESCREEN", "TACKLE" }, "ORAN_BERRY"),
    }),
  }))
  local factory = Factory.new({ catalog = catalog })
  local party = factory:build(buildContext(catalog, "shaped", spyStream(FIXED_SEED)))
  local mons = assert(party.mons, "built parties carry their ordered mons")
  Assert.equal(#mons, 4, "every party shape occupies its ordered slot")
  Assert.isTrue(#mons[2].moves == 4, "custom moves keep all four slots")
  Assert.deepEqual(
    mons[2].moves,
    { "SCRATCH", "LEER", "RAGE", "WATER_GUN" },
    "custom moves survive in source order"
  )
  Assert.equal(mons[2].heldItem, "NONE", "moves-only members carry no held item")
  Assert.equal(mons[3].heldItem, "ORAN_BERRY", "item-only members keep their held item")
  Assert.isTrue(#mons[3].moves >= 1, "item-only members still resolve learnset moves")
  Assert.deepEqual(
    mons[4].moves,
    { "EMBER", "LEER", "SMOKESCREEN", "TACKLE" },
    "combined members keep custom moves in source order"
  )
  Assert.equal(mons[4].heldItem, "ORAN_BERRY", "combined members keep their held item")
  Assert.equal(mons[4].friendship, 0, "the zero-friendship edge survives generation")
  local loyal = customMember({ "TACKLE", "GROWL", "TAIL_WHIP", "LEER" }, "NONE")
  loyal.friendship = 255
  local single = factory:buildNativeMon(loyal, buildContext(catalog, "shaped", spyStream(FIXED_SEED)))
  Assert.equal(single.friendship, 255, "the full-friendship edge survives generation")
end

-- Gender and ability overrides, alternate forms, and capsule facts land on
-- the built mon exactly as the template declares them.
function T.gender_ability_form_and_capsule_overrides_apply()
  local Catalog = requirePresent(CATALOG_MODULE, "immutable trainer templates resolve runtime content keys")
  local Factory = requirePresent(FACTORY_MODULE, "source trainer generation builds native parties")
  local catalog = Catalog.new(compiledInput({
    overridden = trainerRecord("overridden", {
      plainMember({
        species = "EEVEE",
        identityParams = { genderOverride = 1, abilityOverride = 1, capsule = 7 },
        form = 0,
      }),
      plainMember({ species = "SHELLOS", form = 1 }),
    }),
  }))
  local factory = Factory.new({ catalog = catalog })
  local party = factory:build(buildContext(catalog, "overridden", spyStream(FIXED_SEED)))
  local mons = assert(party.mons, "built parties carry their ordered mons")
  Assert.equal(mons[1].gender, "male", "the gender override selects male")
  Assert.equal(mons[1].abilitySlot, 1, "the ability override selects the first slot")
  Assert.equal(mons[1].capsule, 7, "the capsule fact survives generation")
  Assert.equal(mons[2].form, 1, "the alternate form survives generation")
end

-- Rival parties follow the saved rival name and the story branch instead of
-- a fixed roster: the name stays an indirection and each branch deals its
-- own ordered party.
function T.rival_selection_follows_the_saved_name_and_story_branch()
  local Catalog = requirePresent(CATALOG_MODULE, "immutable trainer templates resolve runtime content keys")
  local Factory = requirePresent(FACTORY_MODULE, "source trainer generation builds native parties")
  local catalog = Catalog.new(compiledInput({
    rival = trainerRecord("rival", {
      plainMember({ species = "CHIKORITA", level = 5 }),
    }, {
      trainerClass = "RIVAL",
      nameReference = { rival = true },
      variants = {
        elm = { party = { plainMember({ species = "CHIKORITA", level = 5 }) } },
        finals = { party = { plainMember({ species = "MEGANIUM", level = 38 }) } },
      },
    }),
  }))
  local factory = Factory.new({ catalog = catalog })
  local early = factory:build(buildContext(catalog, "rival", spyStream(FIXED_SEED), { storyVariant = "elm" }))
  Assert.equal(early.name, "SILVER", "the rival name resolves from the save profile")
  Assert.equal(early.mons[1].species, "CHIKORITA", "the early branch deals its ordered party")
  local late = factory:build(buildContext(catalog, "rival", spyStream(FIXED_SEED), { storyVariant = "finals" }))
  Assert.equal(late.name, "SILVER", "the name indirection holds across branches")
  Assert.equal(late.mons[1].species, "MEGANIUM", "the late branch deals its ordered party")
  local renamed = factory:build(
    buildContext(catalog, "rival", spyStream(FIXED_SEED), { storyVariant = "elm", rivalName = "GARY" })
  )
  Assert.equal(renamed.name, "GARY", "renaming the rival flows through the indirection")
end

-- Generation saves and restores the surrounding battle stream: the
-- position is bit-identical afterwards, and rebuilding from the same seed
-- reproduces every personality and individual value exactly.
function T.generation_leaves_the_surrounding_random_stream_untouched()
  local Catalog = requirePresent(CATALOG_MODULE, "immutable trainer templates resolve runtime content keys")
  local Factory = requirePresent(FACTORY_MODULE, "source trainer generation builds native parties")
  local catalog = Catalog.new(compiledInput({
    falkner = trainerRecord("falkner", {
      plainMember(),
      customMember({ "SCRATCH", "LEER", "RAGE", "WATER_GUN" }, "ORAN_BERRY"),
    }),
  }))
  local factory = Factory.new({ catalog = catalog })
  local stream = spyStream(FIXED_SEED)
  local before = stream:capture()
  local first = factory:build(buildContext(catalog, "falkner", stream))
  Assert.deepEqual(stream:capture(), before, "generation restores the surrounding stream position")
  local second = factory:build(buildContext(catalog, "falkner", spyStream(FIXED_SEED)))
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
  local Factory = requirePresent(FACTORY_MODULE, "source trainer generation builds native parties")
  local catalog = Catalog.new(compiledInput({
    custom = trainerRecord("custom", {}),
  }))
  local factory = Factory.new({ catalog = catalog })
  local declared = {
    species = "PIKACHU",
    level = 10,
    identityPolicy = "gift_birth",
    moves = { "THUNDERSHOCK", "GROWL", "TAIL_WHIP", "QUICK_ATTACK" },
    heldItem = "LIGHT_BALL",
    friendship = 120,
  }
  local built = factory:buildNativeMon(declared, buildContext(catalog, "custom", spyStream(FIXED_SEED)))
  Assert.equal(built.species, "PIKACHU", "the declared policy builds the requested species")
  Assert.equal(built.heldItem, "LIGHT_BALL", "the declared policy keeps the declared item")
  local bare = { species = "PIKACHU", level = 10 }
  Assert.throws(function()
    factory:buildNativeMon(bare, buildContext(catalog, "custom", spyStream(FIXED_SEED)))
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

return { tests = T }
