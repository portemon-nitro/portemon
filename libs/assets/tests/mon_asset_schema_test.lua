-- Mon asset schema contract: strict shapes for forms, catalogs, indexes,
-- and presentation manifests. Rejections name unknown fields, dangling
-- references, and out-of-range values; the boolean predicates mirror the
-- raising validators.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")

local T = {}

local function schema()
  return require("libs.assets.src.MonAssetSchema")
end

local function validForm()
  return {
    baseStats = { hp = 45, attack = 49, defense = 65, speed = 45, specialAttack = 49, specialDefense = 65 },
    types = { "grass" },
    abilities = { "OVERGROW" },
    tmhm = { "TOXIC" },
    levelUpMoves = { { level = 1, move = "TACKLE" } },
    evolutions = { { method = "level", level = 16, target = "BAYLEEF", form = 0 } },
    icon = "CHIKORITA/f0",
    portrait = "CHIKORITA/f0/male/plain",
    follower = { visualId = 20153, size = 4, objectParam = 1024 },
    performance = {
      power = { base = 3, min = 2, max = 5 },
      skill = { base = 3, min = 2, max = 5 },
      speed = { base = 3, min = 2, max = 5 },
      jump = { base = 3, min = 2, max = 5 },
      stamina = { base = 3, min = 2, max = 5 },
    },
  }
end

function T.forms_require_valid_pokeathlon_performance()
  local MonAssetSchema = schema()
  local missing = validForm()
  missing.performance = nil
  Assert.isFalse(MonAssetSchema.isValidForm(missing, {}))
  local badRange = validForm()
  badRange.performance.power.base = 6
  badRange.performance.power.max = 5
  Assert.isFalse(MonAssetSchema.isValidForm(badRange, {}))
  local badValue = validForm()
  badValue.performance.stamina.min = 8
  Assert.isFalse(MonAssetSchema.isValidForm(badValue, {}))
end

function T.only_source_unindexable_reserved_forms_may_omit_performance()
  local MonAssetSchema = schema()
  local reserved = validForm()
  reserved.performance = nil
  Assert.isTrue(MonAssetSchema.isValidForm(reserved, { speciesId = 494 }))
  Assert.isTrue(MonAssetSchema.isValidForm(reserved, { speciesId = 495 }))
  Assert.isFalse(MonAssetSchema.isValidForm(reserved, { speciesId = 493 }))
  Assert.isFalse(MonAssetSchema.isValidForm(reserved, {}))
end

function T.valid_forms_pass_andpredicates_mirror_validators()
  local MonAssetSchema = schema()
  Assert.isTrue(MonAssetSchema.assertForm(validForm(), {}))
  Assert.isTrue(MonAssetSchema.isValidForm(validForm(), {}))
end

function T.forms_reject_unknown_fields_and_bad_values()
  local MonAssetSchema = schema()
  local unknown = validForm()
  unknown.narcId = 7
  Assert.isFalse(MonAssetSchema.isValidForm(unknown, {}))
  local err = Assert.throws(function()
    MonAssetSchema.assertForm(unknown, {})
  end)
  Assert.isTrue(Errors.is(err))
  local badStats = validForm()
  badStats.baseStats.hp = 1000
  Assert.isFalse(MonAssetSchema.isValidForm(badStats, {}))
  local badOrder = validForm()
  badOrder.tmhm = { "CUT", "TOXIC" }
  Assert.isTrue(MonAssetSchema.isValidForm(badOrder, {}))
  local unsorted = validForm()
  unsorted.tmhm = { "TOXIC", "BULLET_SEED" }
  Assert.isFalse(MonAssetSchema.isValidForm(unsorted, {}))
  local noFollower = validForm()
  noFollower.follower = nil
  Assert.isTrue(MonAssetSchema.isValidForm(noFollower, {}))
end

local function catalogWith(species, moves, abilities, growthCurves)
  return {
    schema = "g4-mon-catalog-v4",
    version = { id = "heartgold", language = "english" },
    species = species,
    moves = moves,
    abilities = abilities,
    growthCurves = growthCurves,
  }
end

local function zeroCurves()
  local curves = {}
  for _, key in ipairs({
    "medium_fast",
    "erratic",
    "fluctuating",
    "medium_slow",
    "fast",
    "slow",
    "unused_6",
    "unused_7",
  }) do
    local curve = {}
    for level = 1, 100 do
      curve[level] = 0
    end
    curves[key] = curve
  end
  return curves
end

local function validSpecies()
  return {
    CHIKORITA = {
      nativeId = 152,
      name = "CHIKORITA",
      growthCurve = "medium_slow",
      baseFriendship = 70,
      genderRatio = 31,
      eggCycles = 20,
      eggGroups = { "monster", "grass" },
      catchRate = 45,
      baseExpYield = 64,
      evYield = { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 1 },
      heldItems = { common = { item = "NONE", nativeId = 0 }, rare = { item = "NONE", nativeId = 0 } },
      color = 3,
      flip = false,
      forms = { [0] = validForm() },
    },
    BAYLEEF = {
      nativeId = 153,
      name = "BAYLEEF",
      growthCurve = "medium_slow",
      baseFriendship = 70,
      genderRatio = 31,
      eggCycles = 20,
      eggGroups = { "monster", "grass" },
      catchRate = 45,
      baseExpYield = 142,
      evYield = { hp = 0, attack = 0, defense = 1, speed = 0, specialAttack = 0, specialDefense = 1 },
      heldItems = { common = { item = "NONE", nativeId = 0 }, rare = { item = "NONE", nativeId = 0 } },
      color = 3,
      flip = false,
      forms = { [0] = validForm() },
    },
  }
end

local function validMoves()
  return {
    NONE = {
      nativeId = 0,
      name = "-",
      description = "",
      effect = 0,
      category = "physical",
      power = 0,
      moveType = "normal",
      accuracy = 0,
      basePp = 0,
      effectChance = 0,
      range = 0,
      priority = 0,
      flags = 0,
      unknownC = 0,
      contestType = 0,
    },
    TACKLE = {
      nativeId = 33,
      name = "Tackle",
      description = "Charges the foe.",
      effect = 0,
      category = "physical",
      power = 35,
      moveType = "normal",
      accuracy = 95,
      basePp = 35,
      effectChance = 0,
      range = 0,
      priority = 0,
      flags = 115,
      unknownC = 5,
      contestType = 4,
    },
    TOXIC = {
      nativeId = 92,
      name = "Toxic",
      description = "Badly poisons the foe.",
      effect = 3,
      category = "status",
      power = 0,
      moveType = "poison",
      accuracy = 85,
      basePp = 10,
      effectChance = 100,
      range = 0,
      priority = 0,
      flags = 0,
      unknownC = 0,
      contestType = 3,
    },
    CUT = {
      nativeId = 15,
      name = "Cut",
      description = "Cuts the foe.",
      effect = 0,
      category = "physical",
      power = 50,
      moveType = "normal",
      accuracy = 95,
      basePp = 30,
      effectChance = 0,
      range = 0,
      priority = 0,
      flags = 0,
      unknownC = 0,
      contestType = 4,
    },
    BULLET_SEED = {
      nativeId = 331,
      name = "Bullet Seed",
      description = "Shoots seeds.",
      effect = 0,
      category = "physical",
      power = 10,
      moveType = "grass",
      accuracy = 100,
      basePp = 30,
      effectChance = 0,
      range = 0,
      priority = 0,
      flags = 0,
      unknownC = 0,
      contestType = 4,
    },
  }
end

local function validAbilities()
  return {
    NONE = { nativeId = 0, name = " -", description = " -" },
    OVERGROW = { nativeId = 65, name = "Overgrow", description = "Powers up Grass." },
  }
end

local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, item in pairs(value) do
    copy[deepCopy(key)] = deepCopy(item)
  end
  return copy
end

local function validIconManifest()
  return {
    schema = "g4-mon-icon-manifest-v2",
    version = { id = "heartgold", language = "english" },
    pages = {
      [0] = { pageId = 0, image = "assets/generated/mon/icons/0.png", width = 256, height = 128 },
    },
    pageIds = { 0 },
    entries = {
      ["CHIKORITA/f0"] = {
        x = 0,
        y = 0,
        width = 32,
        height = 32,
        frames = { { x = 0, y = 0, width = 32, height = 32, duration = 8 } },
        pageId = 0,
      },
    },
    representative = { "CHIKORITA/f0" },
  }
end

local function validPortraitManifest()
  local manifest = validIconManifest()
  manifest.schema = "g4-mon-portrait-manifest-v2"
  manifest.pages[0].image = "assets/generated/mon/portraits/0.png"
  manifest.pages[0].width = 640
  manifest.pages[0].height = 320
  return manifest
end

function T.catalogs_resolve_every_cross_reference()
  local MonAssetSchema = schema()
  local catalog = catalogWith(validSpecies(), validMoves(), validAbilities(), zeroCurves())
  -- BAYLEEF's placeholder form references CHIKORITA's moves; point it at
  -- nothing dangling: the shared validForm already resolves.
  Assert.isTrue(MonAssetSchema.assertCatalog(catalog))
  Assert.isTrue(MonAssetSchema.isValidCatalog(catalog))
end

function T.catalogs_reject_dangling_references_and_duplicates()
  local MonAssetSchema = schema()
  local species = validSpecies()
  species.CHIKORITA.forms[0].abilities = { "BOGUS" }
  Assert.isFalse(MonAssetSchema.isValidCatalog(catalogWith(species, validMoves(), validAbilities(), zeroCurves())))
  local moves = validMoves()
  moves.BOGUS = validMoves().TACKLE
  moves.BOGUS.nativeId = 33
  Assert.isFalse(MonAssetSchema.isValidCatalog(catalogWith(validSpecies(), moves, validAbilities(), zeroCurves())))
  local noBase = validSpecies()
  noBase.CHIKORITA.forms = {}
  Assert.isFalse(MonAssetSchema.isValidCatalog(catalogWith(noBase, validMoves(), validAbilities(), zeroCurves())))
end

function T.catalogs_reject_broken_identities_references_and_bounds()
  local MonAssetSchema = schema()
  local duplicated = validSpecies()
  duplicated.BAYLEEF.nativeId = 152
  Assert.isFalse(MonAssetSchema.isValidCatalog(catalogWith(duplicated, validMoves(), validAbilities(), zeroCurves())))
  local err = Assert.throws(function()
    MonAssetSchema.assertCatalog(catalogWith(duplicated, validMoves(), validAbilities(), zeroCurves()))
  end)
  Assert.isTrue(Errors.is(err))
  local badMachine = validSpecies()
  badMachine.CHIKORITA.forms[0].tmhm = { "BOGUS_MOVE" }
  Assert.isFalse(MonAssetSchema.isValidCatalog(catalogWith(badMachine, validMoves(), validAbilities(), zeroCurves())))
  local badLearnset = validSpecies()
  badLearnset.CHIKORITA.forms[0].levelUpMoves = { { level = 5, move = "BOGUS_MOVE" } }
  Assert.isFalse(MonAssetSchema.isValidCatalog(catalogWith(badLearnset, validMoves(), validAbilities(), zeroCurves())))
  local badTarget = validSpecies()
  badTarget.CHIKORITA.forms[0].evolutions = { { method = "level", level = 16, target = "BOGUS", form = 0 } }
  Assert.isFalse(MonAssetSchema.isValidCatalog(catalogWith(badTarget, validMoves(), validAbilities(), zeroCurves())))
  local badEvolutionMove = validSpecies()
  badEvolutionMove.CHIKORITA.forms[0].evolutions =
    { { method = "has_move", move = "BOGUS_MOVE", target = "BAYLEEF", form = 0 } }
  Assert.isFalse(
    MonAssetSchema.isValidCatalog(catalogWith(badEvolutionMove, validMoves(), validAbilities(), zeroCurves()))
  )
  local badEvolutionSpecies = validSpecies()
  badEvolutionSpecies.CHIKORITA.forms[0].evolutions =
    { { method = "other_party_mon", species = "BOGUS", target = "BAYLEEF", form = 0 } }
  Assert.isFalse(
    MonAssetSchema.isValidCatalog(catalogWith(badEvolutionSpecies, validMoves(), validAbilities(), zeroCurves()))
  )
  local regressed = zeroCurves()
  regressed.medium_slow[50] = 5
  regressed.medium_slow[51] = 3
  Assert.isFalse(MonAssetSchema.isValidCatalog(catalogWith(validSpecies(), validMoves(), validAbilities(), regressed)))
  local badStats = validSpecies()
  badStats.CHIKORITA.forms[0].baseStats.hp = 300
  Assert.isFalse(MonAssetSchema.isValidCatalog(catalogWith(badStats, validMoves(), validAbilities(), zeroCurves())))
  local badCurve = validSpecies()
  badCurve.CHIKORITA.growthCurve = "bogus"
  Assert.isFalse(MonAssetSchema.isValidCatalog(catalogWith(badCurve, validMoves(), validAbilities(), zeroCurves())))
  -- Learnset order is positional source data, so an unsorted listing still validates.
  local positional = validSpecies()
  positional.CHIKORITA.forms[0].levelUpMoves = { { level = 5, move = "TACKLE" }, { level = 1, move = "TOXIC" } }
  Assert.isTrue(MonAssetSchema.assertCatalog(catalogWith(positional, validMoves(), validAbilities(), zeroCurves())))
end

function T.manifests_require_entries_and_resolving_representatives()
  local MonAssetSchema = schema()
  local manifest = {
    schema = "g4-mon-icon-manifest-v2",
    version = { id = "heartgold", language = "english" },
    pages = {
      [0] = { pageId = 0, image = "assets/generated/mon/icons/0.png", width = 256, height = 128 },
    },
    pageIds = { 0 },
    entries = {
      ["CHIKORITA/f0"] = {
        x = 0,
        y = 0,
        width = 32,
        height = 32,
        frames = { { x = 0, y = 0, width = 32, height = 32, duration = 8 } },
        pageId = 0,
      },
    },
    representative = { "CHIKORITA/f0" },
  }
  Assert.isTrue(MonAssetSchema.assertIconManifest(manifest))
  Assert.isTrue(MonAssetSchema.isValidIconManifest(manifest))
  local dangling = {
    schema = "g4-mon-icon-manifest-v2",
    version = { id = "heartgold", language = "english" },
    pages = manifest.pages,
    pageIds = manifest.pageIds,
    entries = manifest.entries,
    representative = { "MISSING/f0" },
  }
  Assert.isFalse(MonAssetSchema.isValidIconManifest(dangling))
  local escaped = {
    schema = "g4-mon-icon-manifest-v2",
    version = { id = "heartgold", language = "english" },
    pages = manifest.pages,
    pageIds = manifest.pageIds,
    entries = {
      ["CHIKORITA/f0"] = {
        x = 224,
        y = 96,
        width = 32,
        height = 32,
        frames = { { x = 224, y = 96, width = 64, height = 32, duration = 8 } },
        pageId = 0,
      },
    },
    representative = { "CHIKORITA/f0" },
  }
  Assert.isFalse(MonAssetSchema.isValidIconManifest(escaped))
  local portrait = {
    schema = "g4-mon-portrait-manifest-v2",
    version = { id = "heartgold", language = "english" },
    pages = {
      [0] = { pageId = 0, image = "assets/generated/mon/portraits/0.png", width = 640, height = 320 },
    },
    pageIds = { 0 },
    entries = manifest.entries,
    representative = { "CHIKORITA/f0" },
  }
  Assert.isTrue(MonAssetSchema.assertPortraitManifest(portrait))
  Assert.isFalse(MonAssetSchema.isValidPortraitManifest(manifest))
end

function T.index_binds_the_catalog_hash_to_one_marker_per_page()
  local MonAssetSchema = schema()
  local index = {
    schema = "g4-mon-index-v2",
    version = { id = "heartgold", language = "english" },
    catalogHash = string.rep("a", 40),
    catalog = "data/generated/mon/catalog.lua",
    iconManifest = "data/generated/mon/icons.lua",
    portraitManifest = "data/generated/mon/portraits.lua",
    iconPages = { "icon-marker-0" },
    portraitPages = { "portrait-marker-0" },
  }
  Assert.isTrue(MonAssetSchema.assertIndex(index))
  Assert.isTrue(MonAssetSchema.isValidIndex(index))
  local legacy = {
    schema = "g4-mon-index-v1",
    version = { id = "heartgold", language = "english" },
    catalogHash = string.rep("a", 40),
    catalog = "data/generated/mon/catalog.lua",
    iconManifest = "data/generated/mon/icons.lua",
    portraitManifest = "data/generated/mon/portraits.lua",
    iconPages = { "icon-marker-0" },
    portraitPages = { "portrait-marker-0" },
  }
  Assert.isFalse(MonAssetSchema.isValidIndex(legacy))
  local empty = {
    schema = "g4-mon-index-v2",
    version = { id = "heartgold", language = "english" },
    catalogHash = string.rep("a", 40),
    catalog = "data/generated/mon/catalog.lua",
    iconManifest = "data/generated/mon/icons.lua",
    portraitManifest = "data/generated/mon/portraits.lua",
    iconPages = {},
    portraitPages = { "portrait-marker-0" },
  }
  Assert.isFalse(MonAssetSchema.isValidIndex(empty))
end

function T.atlas_manifests_reject_broken_page_identity()
  local MonAssetSchema = schema()
  Assert.isTrue(MonAssetSchema.assertIconManifest(validIconManifest()))
  Assert.isTrue(MonAssetSchema.assertPortraitManifest(validPortraitManifest()))
  -- Page identity is zero-based: a manifest keyed from one is rejected on both validators.
  local oneBased = validIconManifest()
  oneBased.pages = {
    [1] = { pageId = 1, image = "assets/generated/mon/icons/1.png", width = 256, height = 128 },
  }
  oneBased.pageIds = { 1 }
  oneBased.entries["CHIKORITA/f0"].pageId = 1
  Assert.isFalse(MonAssetSchema.isValidIconManifest(oneBased))
  oneBased.schema = "g4-mon-portrait-manifest-v2"
  Assert.isFalse(MonAssetSchema.isValidPortraitManifest(oneBased))
  -- A page record must carry its own key.
  local mismatched = validIconManifest()
  mismatched.pages[0].pageId = 1
  Assert.isFalse(MonAssetSchema.isValidIconManifest(mismatched))
  -- The page inventory is dense and ordered from zero.
  local reordered = validIconManifest()
  reordered.pages[1] = { pageId = 1, image = "assets/generated/mon/icons/1.png", width = 256, height = 128 }
  reordered.pageIds = { 1, 0 }
  Assert.isFalse(MonAssetSchema.isValidIconManifest(reordered))
  reordered.pageIds = { 0, 0 }
  Assert.isFalse(MonAssetSchema.isValidIconManifest(reordered))
  -- Every representative selector must resolve to a validated entry.
  local danglingPortrait = validPortraitManifest()
  danglingPortrait.representative = { "MISSING/f0" }
  Assert.isFalse(MonAssetSchema.isValidPortraitManifest(danglingPortrait))
  local err = Assert.throws(function()
    MonAssetSchema.assertPortraitManifest(danglingPortrait)
  end)
  Assert.isTrue(Errors.is(err))
end

function T.atlas_manifests_reject_broken_frames_and_rectangles()
  local MonAssetSchema = schema()
  local function rejectsBoth(mutator)
    local icon = validIconManifest()
    mutator(icon)
    Assert.isFalse(MonAssetSchema.isValidIconManifest(icon))
    local portrait = validPortraitManifest()
    mutator(portrait)
    Assert.isFalse(MonAssetSchema.isValidPortraitManifest(portrait))
  end
  rejectsBoth(function(manifest)
    manifest.entries["CHIKORITA/f0"].frames = {}
  end)
  rejectsBoth(function(manifest)
    manifest.entries["CHIKORITA/f0"].frames = nil
  end)
  rejectsBoth(function(manifest)
    manifest.entries["CHIKORITA/f0"].frames[1].duration = 0
  end)
  rejectsBoth(function(manifest)
    manifest.entries["CHIKORITA/f0"].frames[1].duration = -2
  end)
  -- An entry rectangle escaping its page is rejected even when it matches its first frame.
  rejectsBoth(function(manifest)
    local entry = manifest.entries["CHIKORITA/f0"]
    entry.x = 700
    entry.frames[1].x = 700
  end)
  -- A frame escaping its page is rejected while the entry itself stays inside.
  rejectsBoth(function(manifest)
    manifest.entries["CHIKORITA/f0"].frames[1].x = 700
  end)
  -- The entry rectangle must match its first frame when both stay inside the page.
  rejectsBoth(function(manifest)
    manifest.entries["CHIKORITA/f0"].x = 64
  end)
  -- A frame without a duration is a still, so it still validates on both validators.
  local stillIcon = validIconManifest()
  stillIcon.entries["CHIKORITA/f0"].frames[1].duration = nil
  Assert.isTrue(MonAssetSchema.assertIconManifest(stillIcon))
  local stillPortrait = validPortraitManifest()
  stillPortrait.entries["CHIKORITA/f0"].frames[1].duration = nil
  Assert.isTrue(MonAssetSchema.assertPortraitManifest(stillPortrait))
end

function T.validation_leaves_fixtures_untouched_across_calls()
  local MonAssetSchema = schema()
  local catalog = catalogWith(validSpecies(), validMoves(), validAbilities(), zeroCurves())
  local icon = validIconManifest()
  local portrait = validPortraitManifest()
  local catalogBefore = deepCopy(catalog)
  local iconBefore = deepCopy(icon)
  local portraitBefore = deepCopy(portrait)
  Assert.isTrue(MonAssetSchema.assertCatalog(catalog))
  Assert.isTrue(MonAssetSchema.isValidCatalog(catalog))
  Assert.isTrue(MonAssetSchema.assertIconManifest(icon))
  Assert.isTrue(MonAssetSchema.assertPortraitManifest(portrait))
  Assert.deepEqual(catalog, catalogBefore, "catalog")
  Assert.deepEqual(icon, iconBefore, "icon")
  Assert.deepEqual(portrait, portraitBefore, "portrait")
  -- A failed fixture never poisons later calls on the good fixtures.
  local badCatalog = deepCopy(catalog)
  badCatalog.species.CHIKORITA.forms[0].abilities = { "BOGUS" }
  Assert.isFalse(MonAssetSchema.isValidCatalog(badCatalog))
  Assert.isTrue(MonAssetSchema.isValidCatalog(catalog))
  Assert.isTrue(MonAssetSchema.isValidIconManifest(icon))
  -- Mutating one manifest never affects its validated sibling.
  local badIcon = deepCopy(icon)
  badIcon.representative = { "MISSING/f0" }
  Assert.isFalse(MonAssetSchema.isValidIconManifest(badIcon))
  Assert.isTrue(MonAssetSchema.isValidPortraitManifest(portrait))
end

function T.catalog_relationship_failures_report_the_catalog_error()
  local MonAssetSchema = schema()
  local function rejectsWithCatalogError(build, code)
    local catalog = catalogWith(validSpecies(), validMoves(), validAbilities(), zeroCurves())
    build(catalog)
    Assert.isFalse(MonAssetSchema.isValidCatalog(catalog))
    local err = Assert.throws(function()
      MonAssetSchema.assertCatalog(catalog)
    end)
    Assert.isTrue(Errors.is(err))
    Assert.equal(err.code, code or "MON_CATALOG_INVALID", "code")
  end
  rejectsWithCatalogError(function(catalog)
    catalog.species.BAYLEEF.nativeId = 152
  end)
  rejectsWithCatalogError(function(catalog)
    catalog.species.CHIKORITA.forms[0].abilities = { "BOGUS" }
  end)
  rejectsWithCatalogError(function(catalog)
    catalog.species.CHIKORITA.forms[0].tmhm = { "BOGUS_MOVE" }
  end)
  rejectsWithCatalogError(function(catalog)
    catalog.species.CHIKORITA.forms[0].levelUpMoves = { { level = 1, move = "BOGUS_MOVE" } }
  end)
  rejectsWithCatalogError(function(catalog)
    catalog.species.CHIKORITA.forms[0].evolutions = { { method = "level", level = 16, target = "BOGUS", form = 0 } }
  end)
  rejectsWithCatalogError(function(catalog)
    catalog.species.CHIKORITA.forms[0].evolutions =
      { { method = "has_move", move = "BOGUS_MOVE", target = "BAYLEEF", form = 0 } }
  end)
  rejectsWithCatalogError(function(catalog)
    catalog.species.CHIKORITA.forms[0].evolutions =
      { { method = "other_party_mon", species = "BOGUS", target = "BAYLEEF", form = 0 } }
  end)
  rejectsWithCatalogError(function(catalog)
    catalog.growthCurves.medium_slow[50] = 5
    catalog.growthCurves.medium_slow[51] = 3
  end)
  rejectsWithCatalogError(function(catalog)
    catalog.species.CHIKORITA.forms[0].baseStats.hp = 300
  end, "MON_FORM_INVALID")
  rejectsWithCatalogError(function(catalog)
    catalog.species.CHIKORITA.growthCurve = "bogus"
  end)
end

function T.atlas_geometry_failures_report_the_manifest_error()
  local MonAssetSchema = schema()
  local function rejectsOnBoth(mutator)
    local icon = validIconManifest()
    mutator(icon)
    Assert.isFalse(MonAssetSchema.isValidIconManifest(icon))
    local iconErr = Assert.throws(function()
      MonAssetSchema.assertIconManifest(icon)
    end)
    Assert.isTrue(Errors.is(iconErr))
    Assert.equal(iconErr.code, "MON_MANIFEST_INVALID", "code")
    local portrait = validPortraitManifest()
    mutator(portrait)
    Assert.isFalse(MonAssetSchema.isValidPortraitManifest(portrait))
    local portraitErr = Assert.throws(function()
      MonAssetSchema.assertPortraitManifest(portrait)
    end)
    Assert.isTrue(Errors.is(portraitErr))
    Assert.equal(portraitErr.code, "MON_MANIFEST_INVALID", "code")
  end
  rejectsOnBoth(function(manifest)
    manifest.pages = {
      [1] = { pageId = 1, image = "assets/generated/mon/icons/1.png", width = 256, height = 128 },
    }
    manifest.pageIds = { 1 }
    manifest.entries["CHIKORITA/f0"].pageId = 1
  end)
  rejectsOnBoth(function(manifest)
    manifest.pages[0].pageId = 1
  end)
  rejectsOnBoth(function(manifest)
    manifest.pages[1] = { pageId = 1, image = "assets/generated/mon/icons/1.png", width = 256, height = 128 }
    manifest.pageIds = { 1, 0 }
  end)
  rejectsOnBoth(function(manifest)
    manifest.entries["CHIKORITA/f0"].frames = {}
  end)
  rejectsOnBoth(function(manifest)
    manifest.entries["CHIKORITA/f0"].frames[1].duration = 0
  end)
  rejectsOnBoth(function(manifest)
    local entry = manifest.entries["CHIKORITA/f0"]
    entry.x = 700
    entry.frames[1].x = 700
  end)
  rejectsOnBoth(function(manifest)
    manifest.entries["CHIKORITA/f0"].frames[1].x = 700
  end)
  rejectsOnBoth(function(manifest)
    manifest.representative = { "MISSING/f0" }
  end)
end

return { tests = T }
