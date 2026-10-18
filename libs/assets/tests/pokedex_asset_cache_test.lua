-- Independent publication of the two Pokedex generated scopes: the data
-- scope (semantic catalog) and the presentation scope (application
-- manifest) stage through non-overlapping owned files, publish through
-- the real prepared-artifact flow, read back ready under their own
-- markers, and a failed replacement of one scope preserves the prior
-- valid output of both scopes without emitting a false marker.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local MonCache = require("libs.assets.src.MonCache")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")

local T = {}

local GENERATION = "pokedex-cache-test-generation"

local function requireProduction()
  local loadedWriter, PokedexCacheWriter = pcall(require, "romdump.src.digest.ui.PokedexCacheWriter")
  Assert.isTrue(
    loadedWriter,
    "the pokedex staged cache writer must be published before independent publication can be proven"
  )
  local loadedCache, PokedexCache = pcall(require, "libs.assets.src.PokedexCache")
  Assert.isTrue(loadedCache, "the pokedex cache owner must be published before scope readiness can be proven")
  local loadedContract, DerivedAssetContract = pcall(require, "libs.assets.src.DerivedAssetContract")
  Assert.isTrue(
    loadedContract,
    "the derived asset contract must name the pokedex family before publication can be proven"
  )
  return assert(PokedexCacheWriter), assert(PokedexCache), assert(DerivedAssetContract)
end

local SPECIES_KEYS = { "custom.alpha", "custom.beta" }

local function ordinaryPolicy()
  return {
    kind = "ordinary",
    variants = { { id = 0, form = 0 } },
    defaultVariant = 0,
    rememberCaughtVariants = false,
    rememberFirstPersonality = false,
  }
end

local function measurementEntry(heightDm, weightHg)
  return {
    heightDm = heightDm,
    weightHg = weightHg,
    scale = { male = { trainer = 256, mon = 256 }, female = { trainer = 256, mon = 256 } },
    yOffset = { male = { trainer = 0, mon = 0 }, female = { trainer = 0, mon = 0 } },
  }
end

local function measurementProfile(heightDm, weightHg)
  local measurements = {}
  for _, key in ipairs(SPECIES_KEYS) do
    measurements[key] = measurementEntry(heightDm, weightHg)
  end
  return {
    measurements = measurements,
    sorts = {
      heaviest = { "custom.alpha", "custom.beta" },
      lightest = { "custom.beta", "custom.alpha" },
      tallest = { "custom.alpha", "custom.beta" },
      shortest = { "custom.beta", "custom.alpha" },
    },
  }
end

local function textBindings()
  return {
    ui = { bankId = 802 },
    entryByLanguage = {
      native = { nameBankId = 237, categoryBankId = 816, flavorBankId = 803 },
      japanese = { nameBankId = 822, categoryBankId = 828, flavorBankId = 810 },
      english = { nameBankId = 817, categoryBankId = 823, flavorBankId = 805 },
      french = { nameBankId = 818, categoryBankId = 824, flavorBankId = 806 },
      german = { nameBankId = 819, categoryBankId = 825, flavorBankId = 807 },
      italian = { nameBankId = 820, categoryBankId = 826, flavorBankId = 808 },
      spanish = { nameBankId = 821, categoryBankId = 827, flavorBankId = 809 },
    },
    measureByProfile = {
      base = { heightBankId = 815, weightBankId = 813 },
      giratina_origin = { heightBankId = 814, weightBankId = 812 },
    },
    registrationAnnouncement = { bankId = 197, messageId = 871 },
  }
end

local function fixtureCatalog()
  local species = {
    ["custom.alpha"] = { nationalNumber = 1, johtoNumber = 1, shape = "quadruped", formPolicy = ordinaryPolicy() },
    ["custom.beta"] = { nationalNumber = 2, johtoNumber = 2, shape = "quadruped", formPolicy = ordinaryPolicy() },
  }
  local sliderSteps = {}
  for step = 1, 152 do
    sliderSteps[step] = { heightDm = step - 1, weightHg = step - 1 }
  end
  sliderSteps[153] = { heightDm = 999, weightHg = 9999 }
  local function areaSet()
    return { outdoor = { "custom.route-29" }, dungeon = {} }
  end
  local habitats = {}
  for _, key in ipairs(SPECIES_KEYS) do
    habitats[key] = { morning = areaSet(), day = areaSet(), night = areaSet(), other = areaSet() }
  end
  local ordered = { "custom.alpha", "custom.beta" }
  return {
    schema = "g4-pokedex-catalog-v1",
    versionId = "heartgold",
    nativeLanguage = "english",
    species = species,
    dexOrders = { johto = ordered, national = ordered },
    completionSets = { johto = ordered, national = ordered },
    sortOrders = { alphabetical = ordered },
    measurementProfiles = { base = measurementProfile(45, 7500), giratina_origin = measurementProfile(69, 6500) },
    criteria = {
      letters = { a = ordered },
      types = { normal = ordered },
      shapes = { quadruped = ordered },
      areas = { johto = ordered, kanto = {}, unknown = {} },
    },
    sliderSteps = sliderSteps,
    areaGeometry = {
      ["custom.route-29"] = {
        kind = "outdoor",
        region = "johto",
        mapKey = "custom.route-29",
        name = { bankId = 1, messageId = 1 },
        rect = { x = 0, y = 0, width = 8, height = 8 },
        markerMask = {},
      },
      ["custom.dark-cave"] = {
        kind = "dungeon",
        region = "johto",
        mapKey = "custom.dark-cave",
        name = { bankId = 1, messageId = 2 },
        position = { x = 3, y = 4 },
      },
    },
    areaOrder = { "custom.route-29", "custom.dark-cave" },
    habitats = habitats,
    allAreaSets = { morning = areaSet(), day = areaSet(), night = areaSet(), other = areaSet() },
    evaluation = {
      johto = {
        bands = { { max = 1, messageId = 10 } },
        complete = { maleMessageId = 11, femaleMessageId = 12 },
        incompleteMusicId = 1,
        completeMusicId = 2,
      },
      national = {
        bands = { { max = 1, messageId = 10 } },
        complete = { maleMessageId = 11, femaleMessageId = 12 },
        incompleteMusicId = 1,
        completeMusicId = 2,
      },
    },
    textBindings = textBindings(),
  }
end

local REQUIRED_PAGES = {
  "cover",
  "grid",
  "results",
  "search.criteria",
  "search.order",
  "search.name",
  "search.type",
  "search.height",
  "search.weight",
  "search.area",
  "search.shape",
  "entry.area",
  "entry.size",
  "entry.forms",
  "entry.compare",
  "entry.return",
  "registration",
}

local function rgba(r, g, b, a)
  return { r = r, g = g, b = b, a = a }
end

local function fixtureManifest(catalog)
  local pages = {}
  for _, role in ipairs(REQUIRED_PAGES) do
    pages[role] = {
      backdrop = { information = rgba(0, 0, 0, 255), controls = rgba(16, 16, 16, 255) },
      backgrounds = {
        information = { { chrome = "panel", layer = 0, x = 0, y = 0, priority = 0, paletteGroup = "panel" } },
        controls = {},
      },
      cells = { "panel-cell" },
      sprites = { "panel-sprite" },
      windows = { "body-window" },
    }
  end
  local spindaRows = {}
  for _ = 1, 80 do
    spindaRows[#spindaRows + 1] = string.rep("0", 79) .. "1"
  end
  local pictures = { backYOffset = {} }
  pictures.backYOffset[MonCache.portraitSelector("custom.alpha", 0, "male", false, "back")] = 4
  return {
    schema = "g4-pokedex-assets-v1",
    versionId = "heartgold",
    fonts = { body = 0, header = 4 },
    pages = pages,
    chrome = { panel = { path = "assets/generated/pokedex/panel.png", width = 64, height = 64 } },
    cells = {
      ["panel-cell"] = {
        bounds = { x = 0, y = 0, width = 16, height = 16 },
        parts = {
          {
            chrome = "panel",
            source = { x = 0, y = 0, width = 16, height = 16 },
            x = 0,
            y = 0,
            flipX = false,
            flipY = false,
            priority = 0,
            paletteGroup = "panel",
          },
        },
      },
    },
    animations = {
      ["panel-idle"] = {
        frames = {
          { cell = "panel-cell", duration = 4, offsetX = 0, offsetY = 0, rotation = 0, scaleX = 1, scaleY = 1 },
        },
        loopFrom = 1,
        direction = "forward",
        once = false,
      },
    },
    windows = {
      ["body-window"] = {
        pane = "information",
        layer = 0,
        x = 0,
        y = 0,
        width = 128,
        height = 64,
        font = 0,
        foreground = rgba(255, 255, 255, 255),
        shadow = rgba(0, 0, 0, 255),
        background = rgba(0, 0, 0, 0),
        align = "left",
        paletteGroup = "panel",
      },
    },
    sprites = {
      ["panel-sprite"] = {
        pane = "information",
        animation = "panel-idle",
        x = 0,
        y = 0,
        priority = 0,
        drawPriority = 0,
        paletteGroup = "panel",
      },
    },
    pictures = pictures,
    footprints = { ["custom.alpha"] = { chrome = "panel", source = { x = 0, y = 0, width = 16, height = 16 } } },
    areaMaps = {
      johto = {
        role = "map",
        extent = { x = 0, y = 0, width = 256, height = 192 },
        scrollBounds = { x = 0, y = 0, width = 256, height = 192 },
        crop = { x = 56, y = 40, width = 200, height = 136 },
      },
      kanto = {
        role = "map",
        extent = { x = 0, y = 0, width = 256, height = 192 },
        scrollBounds = { x = 0, y = 0, width = 256, height = 192 },
        crop = { x = 56, y = 40, width = 200, height = 136 },
      },
    },
    spinda = {
      eligibility = { male = { frames = { spindaRows, spindaRows } } },
      replacementColors = {
        normal = { rgba(255, 0, 0, 255), rgba(0, 255, 0, 255), rgba(0, 0, 255, 255) },
        shiny = { rgba(255, 255, 0, 255), rgba(0, 255, 255, 255), rgba(255, 0, 255, 255) },
      },
      spots = { { x = 1, y = 2 }, { x = 3, y = 4 }, { x = 5, y = 6 }, { x = 7, y = 8 } },
      secondFrameXOffset = -14,
    },
    text = catalog.textBindings,
  }
end

local function stageScope(PokedexCacheWriter, cacheFs, kind, stageName, stageMethod, bundle)
  local artifact = PreparedArtifact.new({
    cacheFs = cacheFs,
    generationId = GENERATION,
    epoch = 1,
    kind = kind,
    key = "global",
    jobKey = kind .. ":global",
    stageName = stageName,
  })
  local marker = assert(PokedexCacheWriter[stageMethod](artifact, bundle))
  artifact:finishSuccess({ marker = marker })
  Assert.isTrue(
    artifact:publish({
      generationId = GENERATION,
      epoch = 1,
      kind = kind,
      key = "global",
      jobKey = kind .. ":global",
    }),
    kind .. " publication must succeed"
  )
  return marker
end

local function lateFailingBackend(writesBeforeFailure)
  local backend = FakeCache.new()
  local writes = 0
  local originalWrite = backend.write
  function backend:write(path, data)
    writes = writes + 1
    if writes > writesBeforeFailure then
      return nil, { code = "FIXTURE_IO", message = "fixture backend fails on a late image write" }
    end
    return originalWrite(self, path, data)
  end
  return backend
end

function T.separate_data_and_presentation_scopes_publish_and_read_independently()
  local PokedexCacheWriter, PokedexCache, DerivedAssetContract = requireProduction()
  Assert.deepEqual(
    DerivedAssetContract.pokedex,
    { cacheFormat = "pokedex-cache-v1", catalogSchema = "g4-pokedex-catalog-v1", schema = "g4-pokedex-assets-v1" },
    "the contract names the exact pokedex family identities"
  )
  Assert.equal(PokedexCache.dir(), "data/generated/pokedex", "the pokedex data directory is stable")
  Assert.equal(PokedexCache.assetDir(), "assets/generated/pokedex", "the pokedex asset directory is stable")
  Assert.isTrue(
    PokedexCache.catalogPath() ~= PokedexCache.manifestPath(),
    "the data catalog and presentation manifest stage at distinct paths"
  )
  Assert.isTrue(
    PokedexCache.dataMarkerPath() ~= PokedexCache.markerPath(),
    "the data and presentation markers stage at distinct paths"
  )
  Assert.isTrue(
    PokedexCache.provenancePath("data") ~= PokedexCache.provenancePath("presentation"),
    "the data and presentation provenance records stage at distinct paths"
  )
  local rejected = pcall(PokedexCache.provenancePath, "other")
  Assert.isFalse(rejected, "unknown provenance scopes must be rejected")

  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  local catalog = fixtureCatalog()
  local manifest = fixtureManifest(catalog)
  local assets = {}
  for _, path in ipairs(PokedexCache.referencedPaths(manifest)) do
    assets[path] = "payload:" .. path
  end
  local dataMarker = stageScope(PokedexCacheWriter, cacheFs, "pokedex-data", "data-stage", "stageData", {
    marker = "data-marker",
    catalog = catalog,
    assets = {},
    provenance = { staged = true },
  })
  local presentationMarker =
    stageScope(PokedexCacheWriter, cacheFs, "pokedex", "presentation-stage", "stagePresentation", {
      marker = "presentation-marker",
      manifest = manifest,
      assets = assets,
      provenance = { staged = true },
    })
  Assert.isTrue(
    PokedexCache.isDataReady(cacheFs, dataMarker),
    "the staged data scope must read ready under its own marker"
  )
  Assert.isTrue(
    PokedexCache.isReady(cacheFs, presentationMarker),
    "the staged presentation scope must read ready under its own marker"
  )
  Assert.equal(
    PokedexCache.loadCatalog(cacheFs).schema,
    "g4-pokedex-catalog-v1",
    "the loaded catalog keeps its schema identity"
  )
  Assert.equal(
    PokedexCache.loadManifest(cacheFs).schema,
    "g4-pokedex-assets-v1",
    "the loaded manifest keeps its schema identity"
  )
end

function T.failed_presentation_replacement_preserves_both_valid_scopes_without_false_markers()
  local PokedexCacheWriter, PokedexCache = requireProduction()

  local cacheFs = CacheFs.forVersion("heartgold", FakeCache.new())
  local catalog = fixtureCatalog()
  local firstData = stageScope(PokedexCacheWriter, cacheFs, "pokedex-data", "data-first", "stageData", {
    marker = "data-marker-first",
    catalog = catalog,
    assets = {},
    provenance = { staged = true },
  })
  local priorManifest = fixtureManifest(catalog)
  local priorAssets = {}
  for _, path in ipairs(PokedexCache.referencedPaths(priorManifest)) do
    priorAssets[path] = "payload:" .. path
  end
  local firstPresentation =
    stageScope(PokedexCacheWriter, cacheFs, "pokedex", "presentation-first", "stagePresentation", {
      marker = "presentation-marker-first",
      manifest = priorManifest,
      assets = priorAssets,
      provenance = { staged = true },
    })

  -- Replacing the data scope publishes new catalog bytes while the prior
  -- presentation stays valid: one scope never erases the other.
  local evolved = fixtureCatalog()
  evolved.versionId = "soulsilver"
  local secondData = stageScope(PokedexCacheWriter, cacheFs, "pokedex-data", "data-second", "stageData", {
    marker = "data-marker-second",
    catalog = evolved,
    assets = {},
    provenance = { staged = true },
  })
  Assert.isTrue(
    PokedexCache.isDataReady(cacheFs, secondData),
    "the replaced data scope must read ready under its new marker"
  )
  Assert.equal(
    PokedexCache.loadCatalog(cacheFs).versionId,
    "soulsilver",
    "the replaced data scope must serve its new catalog"
  )
  Assert.isTrue(
    PokedexCache.isReady(cacheFs, firstPresentation),
    "the data replacement must leave the prior presentation ready"
  )

  -- A presentation rebuild that fails on a late asset write reports
  -- failure, keeps the prior presentation readable, keeps the new data
  -- readable, and emits no completion marker for the failed scope.
  local failingFs = CacheFs.forVersion("heartgold", lateFailingBackend(2))
  local failingArtifact = PreparedArtifact.new({
    cacheFs = failingFs,
    generationId = GENERATION,
    epoch = 1,
    kind = "pokedex",
    key = "global",
    jobKey = "pokedex:global",
    stageName = "presentation-failed",
  })
  local replacementAssets = {}
  for _, path in ipairs(PokedexCache.referencedPaths(fixtureManifest(evolved))) do
    replacementAssets[path] = "payload:" .. path
  end
  local writeOk, writeResult = pcall(PokedexCacheWriter.stagePresentation, failingArtifact, {
    marker = "presentation-marker-failed",
    manifest = fixtureManifest(evolved),
    assets = replacementAssets,
    provenance = { staged = true },
  })
  Assert.isTrue(not (writeOk and writeResult), "a presentation rebuild failing on a late write must not report success")
  Assert.isTrue(
    PokedexCache.isReady(cacheFs, firstPresentation),
    "the failed presentation rebuild must preserve the prior presentation"
  )
  Assert.equal(
    PokedexCache.loadManifest(cacheFs).versionId,
    "heartgold",
    "the failed presentation rebuild must preserve the prior manifest bytes"
  )
  Assert.isTrue(
    PokedexCache.isDataReady(cacheFs, secondData),
    "the failed presentation rebuild must preserve the newly staged data scope"
  )
  Assert.isFalse(
    PokedexCache.isReady(cacheFs, "presentation-marker-failed"),
    "the failed presentation rebuild must not leave a usable false marker"
  )
  Assert.isTrue(firstData ~= nil, "the first data marker anchors the ownership check")
  local dataPaths = { [PokedexCache.catalogPath()] = true, [PokedexCache.dataMarkerPath()] = true }
  for _, path in ipairs(PokedexCache.referencedPaths(PokedexCache.loadManifest(cacheFs))) do
    Assert.isNil(dataPaths[path], "presentation assets must not overlap data ownership: " .. path)
  end
end

return { tests = T }
