-- Readiness and repair for derived-cache reuse: ordinary reuse trusts a
-- current receipt or a matching complete attestation without re-proving
-- payloads, the explicit exhaustive audit still walks the complete
-- canonical inventory to diagnose damage, and failed repairs keep the
-- last good publication. Every fixture below uses synthetic data through
-- the real family owners; no commercial bytes are committed.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local ArtifactState = require("romdump.src.build.ArtifactState")
local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
local DerivedCacheAudit = require("romdump.src.DerivedCacheAudit")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local FieldCameraCache = require("libs.assets.src.field.FieldCameraCache")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
local HoOhCinematicParts = require("libs.assets.src.field.HoOhCinematicParts")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local ScriptCache = require("libs.assets.src.ScriptCache")
local MonCache = require("libs.assets.src.MonCache")
local ItemCache = require("libs.assets.src.ItemCache")
local AudioCache = require("libs.assets.src.audio.AudioCache")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
local HgssFieldEdgeColors = require("romdump.src.digest.field.HgssFieldEdgeColors")
local HgssFieldFog = require("romdump.src.digest.field.HgssFieldFog")
local ScriptCacheWriter = require("romdump.src.digest.script.ScriptCacheWriter")
local ResidentArtifactFixture = require("tests.support.ResidentArtifactFixture")

local T = {}

local GENERATION = "readiness-test-generation"
local SCRIPT_GEN = string.rep("e", 40)
local SCRIPT_SOURCE_HASH = string.rep("c", 40)

-- One committed fact map per fixture cache: the completion facts the
-- controller commits with an artifact's bytes are what make a key reuseable.
local facts = ArtifactState.new(GENERATION)

local function newCache()
  facts = ArtifactState.new(GENERATION)
  return CacheFs.forVersion("heartgold", FakeCache.new())
end

local function recordFact(kind, key, marker)
  facts.records[ArtifactState.key(kind, key)] = {
    kind = kind,
    key = key,
    marker = marker,
    dependencies = {},
    ownedRoots = {},
    sharedPaths = {},
    files = {},
  }
end

-- Marker-only completion state: every family marker plus a world manifest.
-- Payloads are added per scenario; a bare marker set must never read as
-- usable on its own.
local function writeMarkers(cache, world)
  local paths = {
    require("libs.assets.src.field.FieldActorCache").markerPath(),
    MonCache.markerPath(),
    ItemCache.markerPath(),
    require("libs.assets.src.BagCache").markerPath(),
    FieldCameraCache.markerPath(),
    FieldFontCache.markerPath(),
    require("libs.assets.src.field.FieldUiAssetCache").markerPath(),
    require("libs.assets.src.newgame.IntroAssetCache").markerPath(),
    require("libs.assets.src.StarterChoiceAssetCache").markerPath(),
    require("libs.assets.src.field.FieldWeatherCache").markerPath(),
    require("libs.assets.src.field.FieldEffectAssetCache").markerPath(),
    require("libs.assets.src.field.FieldEmoteAssetCache").markerPath(),
    require("libs.assets.src.newgame.NewGameInitCache").markerPath(),
    FieldCellCache.indexMarkerPath(),
  }
  for _, path in ipairs(paths) do
    cache:write(path, "complete")
  end
  cache:writeLua(MapAssetCache.worldPath(), world or { maps = {} })
end

-- Field-cell index payload: a schema-valid index with no matrices, so no
-- cell jobs exist and the index alone decides index readiness.
local function publishCellIndex(cache, marker)
  local index = { schema = FieldCellCache.INDEX_SCHEMA, matrices = {} }
  Assert.isTrue(FieldCellCache.validateIndex(index), "the synthetic index must validate")
  cache:writeLua(FieldCellCache.indexPath(), index)
  cache:write(FieldCellCache.indexMarkerPath(), marker)
  recordFact("field-cell-index", "global", marker)
end

-- Script family fixtures: one member with one script, published through the
-- real writer so summary readiness reflects genuine member bodies.
local function scriptCoverage(memberId, id, scriptIndex)
  return {
    source = { repository = "portemon", romSha1 = "rom-sha" },
    totals = {
      members = 1,
      scripts = 1,
      reachableInstructions = 1,
      supportedInstructions = 1,
      unsupportedInstructions = 0,
    },
    opcodes = {},
    scripts = {
      {
        sourceId = string.format("hgss.scr_seq.%04d.%03d", memberId, scriptIndex or 0),
        publicId = id,
        status = "complete",
        unsupported = {},
      },
    },
  }
end

local function scriptResource(memberId, id, scriptIndex)
  return {
    id = id,
    member = memberId,
    scriptIndex = scriptIndex,
    sourceHash = SCRIPT_SOURCE_HASH,
    resource = {
      api = 1,
      id = id,
      metadata = {
        generated = true,
        source = { sourceHash = SCRIPT_SOURCE_HASH },
        coverage = { complete = true, unsupportedCount = 0 },
      },
      steps = { { op = "stop" } },
    },
    report = { complete = true, unsupportedCount = 0 },
    directDependencies = { audioSequences = {}, scriptTargets = {}, assetNeeds = {} },
  }
end

local function scriptMember(memberId, id, scriptIndex, marker)
  return {
    memberId = memberId,
    marker = marker,
    sourceHash = SCRIPT_SOURCE_HASH,
    coverage = scriptCoverage(memberId, id, scriptIndex),
    resources = { scriptResource(memberId, id, scriptIndex) },
  }
end

local function scriptPlan(marker, members)
  local planMembers, resources = {}, {}
  for _, entry in ipairs(members) do
    planMembers[#planMembers + 1] = { memberId = entry.memberId, marker = marker .. ":member:" .. entry.memberId }
    resources[#resources + 1] = { id = entry.id, member = entry.memberId, scriptIndex = entry.scriptIndex }
  end
  local plan = {
    generationKey = SCRIPT_GEN,
    marker = marker,
    version = "heartgold",
    sourcePath = "romfs/a/0/1/2",
    romSha1 = "rom-sha",
    dependencies = {
      cacheFormat = ScriptCache.FORMAT,
      versionRomSha1 = "rom-sha",
      scrSeqNarc = { path = "a/0/1/2", sha1 = "archive-sha" },
    },
    memberCount = #members,
    members = planMembers,
    resources = resources,
  }
  plan.index = {
    schema = ScriptCache.INDEX_SCHEMA,
    version = "heartgold",
    generation = SCRIPT_GEN,
    marker = marker,
    memberCount = #members,
    scriptMemberCount = #members,
    skippedMemberCount = 0,
    scriptCount = #resources,
    resourceCount = #resources,
    resources = resources,
  }
  return plan
end

local function stageScriptMember(cache, plan, staged)
  local artifact = PreparedArtifact.new({
    cacheFs = cache,
    generationId = GENERATION,
    epoch = 1,
    kind = "script-member",
    key = tostring(staged.memberId),
    jobKey = "script-member:" .. tostring(staged.memberId),
  })
  local marker = assert(ScriptCacheWriter.stageMember(artifact, plan, staged))
  artifact:finishSuccess({ marker = marker })
  Assert.isTrue(ResidentArtifactFixture.materialize(artifact))
  recordFact("script-member", tostring(staged.memberId), marker)
end

local function stageScriptSummary(cache, plan)
  local artifact = PreparedArtifact.new({
    cacheFs = cache,
    generationId = GENERATION,
    epoch = 1,
    kind = "script-summary",
    key = "global",
    jobKey = "script-summary:global",
  })
  local marker = assert(ScriptCacheWriter.stageSummary(artifact, plan))
  artifact:finishSuccess({ marker = marker })
  Assert.isTrue(ResidentArtifactFixture.materialize(artifact))
  recordFact("script-summary", "global", marker)
  return marker
end

local function publishScriptFamily(cache, marker, members)
  local plan = scriptPlan(marker, members)
  for _, entry in ipairs(members) do
    stageScriptMember(
      cache,
      plan,
      scriptMember(entry.memberId, entry.id, entry.scriptIndex, marker .. ":member:" .. entry.memberId)
    )
  end
  return plan, stageScriptSummary(cache, plan)
end

-- A receipt/marker pair with no index payload is cold, and the dependent
-- cell edge still names the index first.
function T.index_marker_without_its_index_payload_is_cold()
  local cache = newCache()
  local marker = FieldCellCache.indexMarker("test-rom", "test-dep")
  cache:write(FieldCellCache.indexMarkerPath(), marker)
  recordFact("field-cell-index", "global", marker)

  Assert.isFalse(
    ArtifactJobs.validate(cache, facts, "field-cell-index", "global", {}),
    "an index marker without its index payload must not read ready"
  )
  local dependencies = ArtifactJobs.dependencies("field-cell", "12-5", {})
  Assert.equal(#dependencies, 2, "a cell resolves its planning prerequisites")
  Assert.equal(dependencies[1].kind, "source-plan", "the cell waits on the source inventory first")
  Assert.equal(dependencies[2].kind, "field-cell-index", "the cell waits on the index next")
end

-- A member whose script body is gone is cold even with its markers intact,
-- so the summary that depends on it cannot stay ready either.
function T.member_with_a_missing_script_body_is_cold_before_its_summary()
  local cache = newCache()
  local marker = ScriptCache.marker("rom-sha", "dep-sha")
  local members = {
    { memberId = 3, id = "common.signpost", scriptIndex = 0 },
    { memberId = 843, id = "new_bark.lab_sign", scriptIndex = 0 },
  }
  local plan, _ = publishScriptFamily(cache, marker, members)
  Assert.isTrue(ScriptCache.isReady(cache, marker), "the published class reads ready before damage")

  cache:remove(ScriptCache.memberPath(SCRIPT_GEN, 843))

  local plans = { scriptPlan = plan, scriptMemberIds = { 3, 843 } }
  Assert.isFalse(
    ArtifactJobs.validate(cache, facts, "script-member", "843", plans),
    "a member with a missing script body must not read ready"
  )
  Assert.isFalse(
    ArtifactJobs.validate(cache, facts, "script-summary", "global", plans),
    "the summary cannot stay ready while a member body is missing"
  )
  local found = false
  for _, dependency in ipairs(ArtifactJobs.dependencies("script-summary", "global", plans)) do
    if dependency.kind == "script-member" and dependency.key == "843" then
      found = true
    end
  end
  Assert.isTrue(found, "summary repair routes through the damaged member first")
end

function T.apricorn_box_job_requires_its_message_bank_member()
  local dependencies, complete = ArtifactJobs.dependencies("apricorn-box", "global", {})
  Assert.isTrue(complete, "the Box job has a final dependency list")
  Assert.deepEqual(dependencies, {
    { kind = "message-bank", key = "21" },
    { kind = "message-bank", key = "224" },
  })
end

-- A cold leaf plus an injected staging failure keeps the previous live
-- bytes, receipts and attestation untouched; nothing partial publishes.
function T.failed_leaf_repair_keeps_the_last_good_publication()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local marker = ScriptCache.marker("rom-sha", "dep-sha")
  local members = {
    { memberId = 3, id = "common.signpost", scriptIndex = 0 },
    { memberId = 843, id = "new_bark.lab_sign", scriptIndex = 0 },
  }
  local plan, _ = publishScriptFamily(cache, marker, members)
  cache:remove(ScriptCache.memberPath(SCRIPT_GEN, 843))

  local plans = { scriptPlan = plan, scriptMemberIds = { 3, 843 } }
  Assert.isFalse(
    ArtifactJobs.validate(cache, facts, "script-member", "843", plans),
    "the damaged leaf must force its own repair"
  )
  local factBefore = facts.records["script-member:843"]

  -- The repair's own stage rejects a member that disagrees with the plan, so
  -- the private output never seals and its fact is never committed.
  local failed = PreparedArtifact.new({
    cacheFs = cache,
    generationId = GENERATION,
    epoch = 1,
    kind = "script-member",
    key = "843",
    jobKey = "script-member:843",
  })
  local ok = pcall(
    ScriptCacheWriter.stageMember,
    failed,
    plan,
    scriptMember(843, "new_bark.lab_sign", 9, marker .. ":member:843-mismatched")
  )
  failed:abort()
  Assert.isFalse(ok, "the rejected repair exposure must fail the stage")

  Assert.notNil(
    cache:read(ScriptCache.memberPath(SCRIPT_GEN, 3)),
    "the healthy sibling bundle survives the failed repair"
  )
  local sibling = assert(cache:loadModule(ScriptCache.memberPath(SCRIPT_GEN, 3))).scripts[1]
  Assert.equal(sibling.id, "common.signpost", "the healthy sibling body survives the failed repair")
  Assert.equal(assert(ScriptCache.loadActive(cache)).marker, marker, "the previous summary selection survives")
  Assert.equal(facts.records["script-member:843"], factBefore, "a failed repair commits no new fact")
  Assert.isNil(cache:read(ScriptCache.memberPath(SCRIPT_GEN, 843)), "a failed repair publishes no member bundle")
end

-- Synthetic corpus builders below: every family publishes minimal valid
-- payloads through its real owner, so the audit premise is genuine and any
-- refusal names the deliberately damaged leaf.

local function publishMessageFamily(cache, marker)
  local bankId = 219
  local FieldMessageFixture = require("tests.support.FieldMessageFixture")
  FieldMessageFixture.write(cache, bankId, { { FieldMessageFixture.eos() } })
  recordFact("message-bank", tostring(bankId), marker)
  cache:writeLua(FieldMessageCache.indexPath(), {
    schema = FieldMessageCache.INDEX_SCHEMA,
    version = "heartgold",
    bankIds = { bankId },
  })
  recordFact("message-summary", "global", marker)
end

local function publishAudioFamily(cache, marker)
  cache:writeLua(AudioCache.indexPath(), {
    schema = AudioCache.INDEX_SCHEMA,
    sequences = {},
    banks = {},
    players = {},
    sequenceBySymbol = {},
    bankBySymbol = {},
  })
  recordFact("audio-catalog", "global", marker)
  recordFact("audio-summary", "global", marker)
end

local function publishMonFamily(cache, marker)
  local PngWriter = require("tests.support.PngEncoder")
  local function manifestFor(schema, pageImage, pageWidth, pageHeight, cell)
    local portrait = schema == MonCache.PORTRAIT_MANIFEST_SCHEMA
    local page = { pageId = 0, image = pageImage, width = pageWidth, height = pageHeight }
    local entry = { x = 0, y = 0, width = cell, height = cell, pageId = 0 }
    if portrait then
      page.indexed = {
        indices = MonCache.portraitIndexPagePath(0),
        palettes = MonCache.portraitPalettePagePath(0),
        paletteCount = 1,
      }
      entry.frames = {
        { x = 0, y = 0, width = cell, height = cell },
        { x = cell, y = 0, width = cell, height = cell },
      }
      entry.paletteIndex = 0
    else
      entry.frames = { { x = 0, y = 0, width = cell, height = cell, duration = 6 } }
    end
    return {
      schema = schema,
      version = { id = "heartgold", language = "english" },
      pages = { [0] = page },
      pageIds = { 0 },
      entries = { ["K/f0"] = entry },
      representative = { "K/f0" },
    }
  end
  local icons = manifestFor(MonCache.ICON_MANIFEST_SCHEMA, MonCache.iconPagePath(0), 256, 128, 32)
  local portraits = manifestFor(MonCache.PORTRAIT_MANIFEST_SCHEMA, MonCache.portraitPagePath(0), 640, 320, 80)
  cache:writeLua(MonCache.iconManifestPath(), icons)
  cache:writeLua(MonCache.portraitManifestPath(), portraits)
  local iconPixels = string.rep("\0", 256 * 128 * 4)
  local portraitPixels = string.rep("\0", 640 * 320 * 4)
  local iconPng = PngWriter.encode(256, 128, iconPixels)
  local portraitPng = PngWriter.encode(640, 320, portraitPixels)
  cache:write(MonCache.iconPagePath(0), iconPng)
  cache:write(MonCache.portraitPagePath(0), portraitPng)
  cache:write(MonCache.portraitIndexPagePath(0), string.rep("\0", 640 * 320))
  cache:write(MonCache.portraitPalettePagePath(0), string.rep("\0", 32))
  local Contract = require("libs.assets.src.DerivedAssetContract")
  local iconMarker = MonCache.marker("test-rom", "icons-0")
  local portraitMarker = MonCache.marker("test-rom", "portraits-0")
  cache:write(MonCache.pageMarkerPath("icons", 0), iconMarker)
  cache:write(MonCache.pageMarkerPath("portraits", 0), portraitMarker)
  cache:write(MonCache.catalogPath(), "catalog")
  cache:writeLua(MonCache.indexPath(), {
    schema = Contract.mons.indexSchema,
    version = { id = "heartgold", language = "english" },
    catalogHash = string.rep("d", 40),
    catalog = MonCache.catalogPath(),
    iconManifest = MonCache.iconManifestPath(),
    portraitManifest = MonCache.portraitManifestPath(),
    iconPages = { iconMarker },
    portraitPages = { portraitMarker },
  })
  cache:write(MonCache.markerPath(), marker)
  recordFact("mon-summary", "global", marker)
  recordFact("mon-catalog", "global", MonCache.marker("test-rom", "catalog"))
  recordFact("mon-layout", "global", MonCache.marker("test-rom", "layout"))
  recordFact("mon-icon-page", "0", iconMarker)
  recordFact("mon-portrait-page", "0", portraitMarker)
  return {
    marker = marker,
    iconMarker = iconMarker,
    portraitMarker = portraitMarker,
    iconWidth = 256,
    iconHeight = 128,
    portraitWidth = 640,
    portraitHeight = 320,
    iconPixels = iconPixels,
    portraitPixels = portraitPixels,
    iconPng = iconPng,
    portraitPng = portraitPng,
  }
end

-- The generated render-environment record every current field record
-- carries: parsed lighting, the area edge-color table, the map weather id,
-- and the helper-derived fog preset.
local function validRenderEnvironment()
  return {
    lighting = {
      records = {
        {
          endHalfSeconds = 0,
          lights = {},
          diffuseRgb555 = 0,
          ambientRgb555 = 0,
          specularRgb555 = 0,
          emissionRgb555 = 0,
        },
      },
    },
    edgeColors = HgssFieldEdgeColors.tableForAreaLightPattern(0),
    weatherId = 0,
    fog = HgssFieldFog.runtimePreset(HgssFieldFog.resolve(0)),
  }
end

local function publishMapDataRecord(cache, mapId, marker)
  local FieldMapData = FieldMapDataCache
  cache:writeLua(FieldMapData.fieldPath(mapId), {
    schema = FieldMapData.FIELD_SCHEMA,
    mapId = mapId,
    events = { background = {}, objects = {}, warps = {}, coordinates = {} },
    music = {},
    soundplates = {},
    initScripts = {},
    transitionEnvironment = "outdoors",
    renderEnvironment = validRenderEnvironment(),
    -- Every compiled field record carries its catalog battle background,
    -- its encounter table member, and its native region; readiness requires
    -- all three facts.
    battleBackground = "general",
    wildEncounterMemberId = 0,
    region = "JOHTO",
    rockSmash = {
      odds = 0,
      items = {
        "MAX_ETHER",
        "REVIVE",
        "HEART_SCALE",
        "RED_SHARD",
        "BLUE_SHARD",
        "GREEN_SHARD",
        "YELLOW_SHARD",
        "STAR_PIECE",
      },
    },
    headbutt = { regularTrees = {}, secretTrees = {}, slots = { common = {}, rare = {}, secret = {} } },
    fieldUse = {
      flyAllowed = true,
      teleportAllowed = true,
      escapeAllowed = false,
      alphFlashRoom = false,
      alphEscapeRopeRoom = false,
      icePathB2F = false,
      cave = false,
      unionOrColosseum = false,
      bikeAllowed = true,
    },
  })
  cache:writeLua(FieldMapData.dependenciesPath(mapId), { generated = true })
  cache:write(FieldMapData.markerPath(mapId), marker)
  recordFact("map-data", tostring(mapId), marker)
end

local function publishCameraFamily(cache, marker)
  cache:write(FieldCameraCache.profilesPath(), "profiles")
  cache:write(FieldCameraCache.provenancePath(), "provenance")
  cache:write(FieldCameraCache.markerPath(), marker)
  recordFact("field-camera", "global", marker)
end

local function publishFontFamily(cache, marker)
  local FontCache = require("libs.assets.src.field.FieldFontCache")
  for _, fontId in ipairs(FontCache.REQUIRED_FONT_IDS) do
    cache:write(FontCache.defPath(fontId), "def")
    cache:write(FontCache.atlasPath(fontId), "atlas")
    cache:write(FontCache.maskAtlasPath(fontId), "mask")
    cache:write(FontCache.focusIndicatorsPath(fontId), "focus")
  end
  cache:write(FontCache.markerPath(), marker)
  recordFact("field-font", "global", marker)
end

local function publishFieldEntryFamily(cache, marker)
  local FieldEntry = require("libs.assets.src.field.FieldEntryAssetCache")
  local assets = {}
  for style = 0, FieldEntry.BANNER_STYLE_COUNT - 1 do
    local key = "banner/" .. style
    assets[key] = { image = "assets/generated/field/entry/banner/" .. style .. ".png", width = 136, height = 32 }
  end
  assets["preview/0"] = { image = "assets/generated/field/entry/preview/0.png", width = 256, height = 192 }
  local bannerStyles, palettes = {}, {}
  for style = 0, FieldEntry.BANNER_STYLE_COUNT - 1 do
    bannerStyles[style] = "banner/" .. style
    palettes[style] = {
      foreground = { r = 255, g = 255, b = 255 },
      shadow = { r = 0, g = 0, b = 0 },
      background = { r = 0, g = 0, b = 0 },
    }
  end
  cache:writeLua(FieldEntry.manifestPath(), {
    schema = FieldEntry.SCHEMA,
    reference = { width = 256, height = 192 },
    assets = assets,
    bannerStyles = bannerStyles,
    bannerTextPalettes = palettes,
    bannerStyleByMapId = {},
    previewByMapId = { [1] = { [0] = "preview/0", [1] = "preview/0", [2] = "preview/0", [3] = "preview/0" } },
  })
  for _, entry in pairs(assets) do
    cache:write(entry.image, "bytes")
  end
  cache:write(FieldEntry.markerPath(), marker)
  recordFact("field-entry", "global", marker)
end

local function publishActorFamily(cache)
  local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
  local Writer = require("romdump.src.digest.actor.FieldActorCacheWriter")
  local Fixture = require("tests.support.FieldActorFixture")
  local states = {
    "walking",
    "cycling",
    "surfing",
    "rocket",
    "watering",
    "fishing",
    "poketch",
    "saving",
    "heal",
    "ladder",
    "rocket_heal",
    "rocket_saving",
    "pokeathlon",
    "apricorn_shake",
  }
  local function capability(id, gender, spriteIds)
    local named = {}
    for i, name in ipairs(states) do
      named[name] = spriteIds[((i - 1) % #spriteIds) + 1]
    end
    return { id = id, gender = gender, states = named }
  end
  local apricornTreeSprites = {}
  local apricornFruitSprites = {}
  for _, key in ipairs({
    "RED_APRICORN",
    "YLW_APRICORN",
    "BLU_APRICORN",
    "GRN_APRICORN",
    "PNK_APRICORN",
    "WHT_APRICORN",
    "BLK_APRICORN",
  }) do
    apricornTreeSprites[key] = 0
    apricornFruitSprites[key] = 0
  end
  local treeVisual = Fixture.visual(0, { frameCount = 8 })
  local function treeGesture(loop)
    return {
      pose = { frames = { { frameIndex = 1, ticks = 1 } }, loop = loop, durationTicks = 1 },
      displayOffset = { x = 0, y = 0, z = 0 },
    }
  end
  treeVisual.gestures.apricorn_tree_wiggle = treeGesture(true)
  treeVisual.gestures.apricorn_tree_expel = treeGesture(false)
  local bundle = {
    marker = FieldActorCache.marker("test-rom", "test-dep"),
    index = {
      schema = FieldActorCache.INDEX_SCHEMA,
      romVersion = "heartgold",
      spriteIds = { 0 },
      variableSprites = {},
      recordCount = 3,
      runtime = {
        avatars = { capability("hero", 0, { 0 }), capability("heroine", 1, { 0 }) },
        variableSprites = { first = 101, last = 117, variableBase = 0x4020 },
        apricorn = {
          depletedTreeSpriteId = 0,
          treeSpriteIdByKey = apricornTreeSprites,
          fruitSpriteIdByKey = apricornFruitSprites,
        },
      },
    },
    visuals = { [0] = treeVisual },
    atlases = { [0] = { width = 4, height = 1, pixels = string.rep("\0", 16) } },
    provenance = { schema = "g4-field-actor-provenance-v1" },
    dependencies = {},
  }
  local stagedMarker = ResidentArtifactFixture.publish(cache, "actors", "global", function(artifact)
    return Writer.stage(artifact, bundle)
  end)
  Assert.equal(stagedMarker, bundle.marker)
  Assert.isTrue(FieldActorCache.isReady(cache, bundle.marker), "the synthetic actor class must read ready")
  recordFact("actors", "global", bundle.marker)
end

local function publishItemFamily(cache)
  local Writer = require("romdump.src.digest.items.ItemCacheWriter")
  local Hashing = require("romdump.src.digest.Hashing")
  local ItemFixture = require("libs.items.tests.item_fixture")
  local marker = ItemCache.marker("test-rom", "test-dep")
  local pixels = string.rep("\0", 32 * 32 * 4)
  local catalog = ItemFixture.buildAssetRoot()
  local entries = {}
  for key in pairs(catalog.items) do
    entries[key] = { x = 0, y = 0, width = 32, height = 32 }
  end
  local bundle = {
    marker = marker,
    index = {
      schema = "g4-item-index-v1",
      version = { id = "heartgold", language = "en" },
      catalogHash = Hashing.hashLua(catalog),
      iconHash = Hashing.sha1hex(pixels),
      catalog = ItemCache.catalogPath(),
      icons = ItemCache.iconImagePath(),
      iconManifest = ItemCache.iconManifestPath(),
    },
    catalog = catalog,
    icons = { width = 32, height = 32, pixels = pixels },
    iconManifest = {
      schema = "g4-item-icons-v1",
      atlas = ItemCache.iconImagePath(),
      entries = entries,
      representative = { "POTION" },
    },
    provenance = {},
  }
  ResidentArtifactFixture.publish(cache, "items", "global", function(artifact)
    return Writer.stage(artifact, bundle)
  end)
  Assert.isTrue(ItemCache.isReady(cache, marker), "the synthetic item class must read ready")
  recordFact("items", "global", marker)
end

local function publishEmoteFamily(cache)
  local EmoteCache = require("libs.assets.src.field.FieldEmoteAssetCache")
  local Writer = require("romdump.src.digest.actor.FieldActorEmoteCacheWriter")
  local ModelAsset = require("libs.assets.src.model.ModelAsset")
  local marker = "field-emotes-cache-v4:test-rom:test-dep"
  local modelAsset = {
    schema = ModelAsset.SCHEMA,
    key = "field-emote:exclamation",
    kind = "static",
    batches = {
      {
        geometry = { file = EmoteCache.geometryPath("mesh-key"), drawIndex = 0 },
        cullMode = "back",
        polygonMode = "modulation",
        polygonId = 0,
        translucentDepthWrite = false,
        depthEqual = false,
        polygonAlpha = 31,
        lightMask = 5,
        fogEnabled = false,
      },
    },
    materials = {
      {
        id = 0,
        name = "exclamation",
        texture = { file = EmoteCache.texturePath("texture-key"), textureName = "exclamation" },
        textureFormat = 3,
        wrap = { x = "clamp", y = "clamp" },
        flip = { x = false, y = false },
        diffuse = { r = 255, g = 255, b = 255, a = 255 },
      },
    },
  }
  local ok, err = pcall(ResidentArtifactFixture.publish, cache, "field-emotes", "global", function(artifact)
    return Writer.stage(artifact, {
      marker = marker,
      model = {
        schema = "g4-field-emote-v3",
        model = modelAsset,
      },
      meshes = { ["mesh-key"] = "G4GX-bank-bytes" },
      textures = { ["texture-key"] = "G4TX-bank-bytes" },
    })
  end)
  Assert.isTrue(ok, tostring(err))
  Assert.isTrue(EmoteCache.isReady(cache, marker), "the synthetic emote class must read ready")
  recordFact("field-emotes", "global", marker)
end

local function publishWeatherFamily(cache)
  local WeatherCache = require("libs.assets.src.field.FieldWeatherCache")
  local Compiler = require("romdump.src.digest.field.FieldWeatherCompiler")
  local Writer = require("romdump.src.digest.field.FieldWeatherCacheWriter")
  local bundle = assert(Compiler.compile())
  ResidentArtifactFixture.publish(cache, "field-weather", "global", function(artifact)
    return Writer.stage(artifact, bundle)
  end)
  Assert.isTrue(WeatherCache.isReady(cache, bundle.marker), "the compiled weather class must read ready")
  recordFact("field-weather", "global", bundle.marker)
end

local function publishEffectFamily(cache)
  local EffectCache = require("libs.assets.src.field.FieldEffectAssetCache")
  local Writer = require("romdump.src.digest.field.FieldEntranceIndicatorCacheWriter")
  local ModelAsset = require("libs.assets.src.model.ModelAsset")
  local Contract = require("libs.assets.src.DerivedAssetContract")
  local function staticModel(key)
    return {
      schema = ModelAsset.SCHEMA,
      key = key,
      kind = "static",
      batches = {
        {
          geometry = { file = EffectCache.geometryPath("mesh-key"), drawIndex = 0 },
          cullMode = "back",
          polygonMode = "modulation",
          polygonId = 0,
          translucentDepthWrite = false,
          depthEqual = false,
          polygonAlpha = 31,
          lightMask = 5,
          fogEnabled = false,
        },
      },
      materials = {
        {
          id = 0,
          name = "effect",
          texture = { file = EffectCache.texturePath("texture-key"), textureName = "effect" },
          textureFormat = 3,
          wrap = { x = "clamp", y = "clamp" },
          flip = { x = false, y = false },
          diffuse = { r = 255, g = 255, b = 255, a = 255 },
        },
      },
    }
  end
  local function dynamicModel(key)
    return {
      schema = ModelAsset.SCHEMA,
      key = key,
      kind = "nitro-dynamic",
      dynamic = { nodes = {}, transformProgram = {}, batches = {} },
      materials = {
        {
          id = 0,
          name = "effect",
          baseColor = { r = 255, g = 255, b = 255, a = 255 },
          colors = {
            diffuse = { r = 255, g = 255, b = 255 },
            ambient = { r = 255, g = 255, b = 255 },
            specular = { r = 255, g = 255, b = 255 },
            emission = { r = 0, g = 0, b = 0 },
          },
          alphaMode = "opaque",
          polygonMode = "modulation",
          doubleSided = false,
          polygonAlpha = 31,
          texMtxMode = 0,
          texWidth = 64,
          texHeight = 64,
          wrap = { x = "clamp", y = "clamp" },
          flip = { x = false, y = false },
          diffuse = { r = 255, g = 255, b = 255, a = 255 },
        },
      },
      animations = {
        {
          id = key .. ".clip",
          name = key .. ".clip",
          category = "joint",
          kind = "trs",
          frameCount = 4,
          tracks = { { target = 0, targetIndex = 0 } },
          semanticNames = { key .. ".clip" },
          compiled = {
            anmFlags = 0,
            rotData = {},
            pivotData = { { 0, 0, 0, 0, 0 } },
            targets = {
              {
                nodeIndex = 0,
                channels = {
                  trans = {
                    x = { source = "constant", value = 0 },
                    y = { source = "constant", value = 0 },
                    z = { source = "constant", value = 0 },
                  },
                  rot = { source = "constant", value = 0 },
                  scale = {
                    x = { source = "constant", value = 0 },
                    y = { source = "constant", value = 0 },
                    z = { source = "constant", value = 0 },
                  },
                },
              },
            },
          },
        },
      },
    }
  end
  local function reactionModel(selector)
    local model = dynamicModel("field-effect:follower-reaction-" .. selector)
    local clip = model.animations[1]
    clip.category = "material"
    clip.kind = "pattern"
    clip.tracks = { { target = "grass", targetIndex = 0 } }
    clip.compiled = {
      textureNames = { "reaction.1" },
      paletteNames = { "reaction" },
      targets = {
        { index = 0, name = "grass", rate = 1, keys = { { frame = 0, texIdx = 0, plttIdx = 0 } } },
      },
    }
    return model
  end
  local function celebiTimeTravelModel()
    local model = dynamicModel("field-effect:celebi-time-travel")
    local joint = model.animations[1]
    joint.id = "celebi.joint"
    joint.name = "sere_demo01"
    joint.semanticNames = { "celebi.joint" }

    local patternModel = reactionModel(1)
    local pattern = patternModel.animations[1]
    pattern.id = "celebi.pattern"
    pattern.name = "sere_demo01"
    pattern.semanticNames = { "celebi.pattern" }

    local function constant(value)
      return { source = "constant", value = value }
    end
    local srt = {
      id = "celebi.srt",
      name = "sere_demo01",
      category = "material",
      kind = "texsrt",
      frameCount = 4,
      tracks = { { target = "effect", targetIndex = 0 } },
      semanticNames = { "celebi.srt" },
      compiled = {
        targets = {
          {
            name = "effect",
            index = 0,
            channels = {
              transS = constant(0),
              transT = constant(0),
              rot = constant(0),
              scaleS = constant(1),
              scaleT = constant(1),
            },
          },
        },
      },
    }
    model.animations = { joint, pattern, srt }
    return model
  end
  -- The published Ho-Oh parts by kind: the core with its clip summary, and
  -- per cinematic shot one shared part plus one overlay per variant.
  local function hoOhAppearance()
    local function build(name, clips, idPrefix)
      local model = dynamicModel("field-effect:ho-oh-appearance:" .. name)
      local template = model.animations[1]
      model.animations = {}
      for clip = 1, clips do
        local animation = {}
        for field, value in pairs(template) do
          animation[field] = value
        end
        animation.id = idPrefix .. "." .. clip
        model.animations[clip] = animation
      end
      return model
    end
    local coreSpecs = {
      { "bellRising", 6 },
      { "bellShimmer", 2 },
      { "cornerBells", 1 },
      { "birdApproach", 3 },
      { "wavesEffect", 2 },
    }
    local models, frames = {}, {}
    for index, spec in ipairs(coreSpecs) do
      models[index] = build(spec[1], spec[2], "ho-oh." .. spec[1])
      for _, clip in ipairs(models[index].animations) do
        frames[clip.id] = clip.frameCount
      end
    end
    local definitions, cinematic = {}, {}
    for shot, clips in pairs({ first = 4, second = 3 }) do
      local variants = {}
      for variant = 0, 2 do
        variants[variant + 1] = build("cinematic." .. shot .. "." .. variant, clips, "ho-oh." .. shot .. "." .. variant)
      end
      local shared, overlays = HoOhCinematicParts.split(shot, variants)
      definitions[EffectCache.hoOhCinematicKind(shot)] = shared
      local longest = 0
      for _, clip in ipairs(shared.animations) do
        longest = math.max(longest, clip.frameCount)
      end
      cinematic[shot] = { longest, longest, longest }
      for variant = 0, 2 do
        definitions[EffectCache.hoOhCinematicKind(shot, variant)] = overlays[variant + 1]
      end
    end
    definitions.ho_oh_appearance = { models = models, clips = { frames = frames, cinematic = cinematic } }
    return definitions
  end
  local marker = EffectCache.marker("test-rom", "test-dep")
  local bundle = {
    marker = marker,
    index = {
      schema = Contract.fieldEffects.indexSchema,
      effects = {
        warp_entrance = {
          path = EffectCache.definitionPath("warp_entrance"),
          definition = "warp_entrance",
          kind = "model",
        },
        tall_grass = {
          path = EffectCache.definitionPath("tall_grass"),
          definition = "tall_grass",
          kind = "animated_model",
        },
        very_tall_grass = {
          path = EffectCache.definitionPath("very_tall_grass"),
          definition = "very_tall_grass",
          kind = "animated_model",
        },
        trainer_reveal = {
          path = EffectCache.definitionPath("trainer_reveal"),
          definition = "trainer_reveal",
          kind = "animated_model",
        },
        surf_attachment = {
          path = EffectCache.definitionPath("surf_attachment"),
          definition = "surf_attachment",
          kind = "model",
        },
        follower_transition = {
          path = EffectCache.definitionPath("follower_transition"),
          definition = "follower_transition",
          kind = "transition",
        },
        pokemon_center_heal = {
          path = EffectCache.definitionPath("pokemon_center_heal"),
          definition = "pokemon_center_heal",
          kind = "healing",
        },
        hall_of_fame_machine = {
          path = EffectCache.definitionPath("hall_of_fame_machine"),
          definition = "hall_of_fame_machine",
          kind = "hall_of_fame",
        },
        celebi_time_travel = {
          path = EffectCache.definitionPath("celebi_time_travel"),
          definition = "celebi_time_travel",
          kind = "cinematic",
        },
      },
    },
    effects = {
      warp_entrance = { model = staticModel("field-effect:warp-entrance"), lifetime = 1 },
      tall_grass = {
        model = dynamicModel("field-effect:tall-grass"),
        lifecycle = { mode = "hold_until_owner_moves", holdFrame = 2 },
        placementOffset = { x = 0, y = 0, z = 0.625 },
      },
      very_tall_grass = {
        model = dynamicModel("field-effect:very-tall-grass"),
        lifecycle = { mode = "hold_until_owner_moves", holdFrame = 2 },
        placementOffset = { x = 0, y = 0, z = 0.625 },
      },
      trainer_reveal = {
        model = dynamicModel("field-effect:trainer-reveal"),
        lifecycle = { mode = "once", frameCount = 4 },
        placementOffset = { x = 0, y = 0, z = 0.5 },
      },
      surf_attachment = {
        model = staticModel("field-effect:surf-attachment"),
        presentation = {
          initialPlayerOffset = { x = 0, y = 4 / 16, z = 4 / 16 },
          oscillator = { initialY = 1 / 16, minY = 1 / 16, maxY = 4 / 16, stepY = (1 / 4) / 16 },
          playerBaseOffset = { x = 0, y = 4 / 16, z = 4 / 16 },
          attachmentBaseOffset = { x = 0, y = -1 / 16, z = 0 },
          yawDegrees = { north = 180, south = 0, west = 270, east = 90 },
        },
      },
      follower_transition = {
        models = { staticModel("field-effect:transition-companion"), dynamicModel("field-effect:transition-lead") },
        lifecycle = { mode = "once", frameCount = 4, preludeTicks = 2 },
        placementOffset = { x = 0, y = 0.375, z = 0 },
      },
      pokemon_center_heal = {
        models = { dynamicModel("field-effect:center-heal-ball") },
        anchorModelKey = "field-effect:center-heal-anchor",
        machineModelKey = "field-effect:center-heal-machine",
        ballAnimation = "field-effect:center-heal-ball.clip",
        machineAnimation = "field-effect:center-heal-machine.clip",
        machineAnimationFrameCount = 4,
        ballPositions = {
          { role = "northwest", offset = { x = -0.28125, y = 0.75, z = -0.28125 } },
          { role = "northeast", offset = { x = 0.28125, y = 0.75, z = -0.28125 } },
          { role = "west", offset = { x = -0.28125, y = 0.75, z = 0 } },
          { role = "east", offset = { x = 0.28125, y = 0.75, z = 0 } },
          { role = "southwest", offset = { x = -0.28125, y = 0.75, z = 0.28125 } },
          { role = "southeast", offset = { x = 0.28125, y = 0.75, z = 0.28125 } },
        },
        spawnIntervalSourceFrames = 12,
        placementSound = "SEQ_SE_DP_BOWA",
        fanfare = "SEQ_ME_ASA",
      },
      hall_of_fame_machine = {
        machineModelMemberId = 38,
        models = { dynamicModel("field-effect:hall-of-fame-ball") },
        ballAnimation = "field-effect:hall-of-fame-ball.clip",
        ballAnimationFrameCount = 4,
        ballPositions = {
          { role = "northwest", offset = { x = -0.28125, y = 0.75, z = -0.28125 } },
          { role = "northeast", offset = { x = 0.28125, y = 0.75, z = -0.28125 } },
          { role = "west", offset = { x = -0.28125, y = 0.75, z = 0 } },
          { role = "east", offset = { x = 0.28125, y = 0.75, z = 0 } },
          { role = "southwest", offset = { x = -0.28125, y = 0.75, z = 0.28125 } },
          { role = "southeast", offset = { x = 0.28125, y = 0.75, z = 0.28125 } },
        },
        spawnIntervalSourceFrames = 15,
        placementSound = "SEQ_SE_DP_BOWA",
      },
      celebi_time_travel = { model = celebiTimeTravelModel() },
    },
    meshes = { ["mesh-key"] = "G4GX-bank-bytes" },
    textures = { ["texture-key"] = "G4TX-bank-bytes" },
  }
  for kind, definition in pairs(hoOhAppearance()) do
    bundle.effects[kind] = definition
    bundle.index.effects[kind] = { path = EffectCache.definitionPath(kind), definition = kind, kind = "cinematic" }
  end
  local lugiaModels = {}
  for index, spec in ipairs({
    { key = "field-effect:lugia-appearance:eyeGlimmer", clips = 3 },
    { key = "field-effect:lugia-appearance:cinematic.lugia.0", clips = 4 },
    { key = "field-effect:lugia-appearance:cinematic.lugia.1", clips = 1 },
  }) do
    local model = dynamicModel(spec.key)
    local template = model.animations[1]
    model.animations = {}
    for clipIndex = 1, spec.clips do
      local clip = {}
      for field, value in pairs(template) do
        clip[field] = value
      end
      clip.id = spec.key .. ".clip-" .. clipIndex
      clip.name = clip.id
      clip.semanticNames = { clip.id }
      model.animations[clipIndex] = clip
    end
    lugiaModels[index] = model
  end
  bundle.effects.lugia_appearance = { models = lugiaModels }
  bundle.index.effects.lugia_appearance = {
    path = EffectCache.definitionPath("lugia_appearance"),
    definition = "lugia_appearance",
    kind = "cinematic",
  }
  for selector = 1, 14 do
    local kind = "follower_reaction_" .. selector
    bundle.index.effects[kind] = {
      path = EffectCache.definitionPath(kind),
      definition = kind,
      kind = "reaction",
    }
    bundle.effects[kind] = {
      definition = kind,
      model = reactionModel(selector),
      lifecycle = { mode = "once", frameCount = 4 },
    }
  end
  -- The mechanism props the source loads by build model over its own
  -- transform instead of placing them: the gym props travel with their one
  -- source clip, and the Blackthorn platforms as plain static models.
  for _, kind in ipairs({ "violet_gym_car", "azalea_gym_spinarak" }) do
    bundle.index.effects[kind] = {
      path = EffectCache.definitionPath(kind),
      definition = kind,
      kind = "animated_model",
    }
    bundle.effects[kind] = { model = dynamicModel("field-effect:" .. kind) }
  end
  for _, kind in ipairs({ "blackthorn_gym_platform_wide", "blackthorn_gym_platform_narrow" }) do
    bundle.index.effects[kind] = {
      path = EffectCache.definitionPath(kind),
      definition = kind,
      kind = "model",
    }
    bundle.effects[kind] = { model = staticModel("field-effect:" .. kind) }
  end
  -- The Rocket hideout's own script-driven effects: each trap model keeps every
  -- clip its source record declares (the joint, colour and texture-srt programs
  -- are separate records compiled as clips of the same model), and the alarm is
  -- a prepared overlay the field draws itself.
  local function constant(value)
    return { source = "constant", value = value }
  end
  local trapMaterialPayload = {
    color = {
      targets = {
        {
          index = 0,
          name = "effect",
          channels = {
            diffuse = constant(0x3FFFFFFF),
            ambient = constant(0),
            specular = constant(0),
            emission = constant(0),
            alpha = constant(0x1F),
          },
        },
      },
    },
    texsrt = {
      targets = {
        {
          index = 0,
          name = "effect",
          channels = {
            transS = constant(0),
            transT = constant(0),
            rot = constant(0),
            scaleS = constant(1),
            scaleT = constant(1),
          },
        },
      },
    },
  }
  for _, trap in ipairs({
    { key = "rocket_trap_electric", kinds = { "trs" } },
    { key = "rocket_trap_poison", kinds = { "trs", "color" } },
    { key = "rocket_trap_rock", kinds = { "trs", "color", "texsrt" } },
  }) do
    bundle.index.effects[trap.key] = {
      path = EffectCache.definitionPath(trap.key),
      definition = trap.key,
      kind = "animated_model",
    }
    local model = dynamicModel("field-effect:" .. trap.key)
    local template = model.animations[1]
    model.animations = {}
    for clipIndex, clipKind in ipairs(trap.kinds) do
      local clip = {}
      for field, value in pairs(template) do
        clip[field] = value
      end
      clip.id = trap.key .. ".clip-" .. clipIndex
      clip.name = clip.id
      clip.semanticNames = { clip.id }
      if clipKind ~= "trs" then
        clip.category = "material"
        clip.kind = clipKind
        clip.tracks = { { target = "effect", targetIndex = 0 } }
        clip.compiled = trapMaterialPayload[clipKind]
      end
      model.animations[clipIndex] = clip
    end
    bundle.effects[trap.key] = { model = model }
  end
  bundle.index.effects.rocket_alarm_overlay = {
    path = EffectCache.definitionPath("rocket_alarm_overlay"),
    definition = "rocket_alarm_overlay",
    kind = "overlay",
  }
  bundle.effects.rocket_alarm_overlay = {
    overlay = { texture = EffectCache.texturePath("a1a1a1"), width = 256, height = 256 },
  }
  -- The legendary-story scenes this field drives, and the Arceus montage whose
  -- layers come out as prepared effect textures.
  for _, scene in ipairs({
    { kind = "legend_wing", parts = 2 },
    { kind = "sinjoh_stage", parts = 3 },
    { kind = "sinjoh_unown", parts = 3 },
    { kind = "sinjoh_egg", parts = 3 },
  }) do
    bundle.index.effects[scene.kind] = {
      path = EffectCache.definitionPath(scene.kind),
      definition = scene.kind,
      kind = "scene",
    }
    local parts = {}
    for index = 1, scene.parts do
      parts[index] = {
        model = dynamicModel("field-effect:" .. scene.kind .. ":part-" .. index),
        clips = { joint = { ids = { "joint.trs" }, frames = 4 } },
      }
    end
    bundle.effects[scene.kind] = { parts = parts }
  end
  bundle.index.effects.arceus_cinematic = {
    path = EffectCache.definitionPath("arceus_cinematic"),
    definition = "arceus_cinematic",
    kind = "montage",
  }
  bundle.effects.arceus_cinematic = {
    bgm = "SEQ_GS_E_ARCEUS",
    timeline = { { 12 }, { 6, 0, 58 }, { 0, 2 }, { 19 } },
    layers = { [58] = { path = EffectCache.texturePath("a1a1a1"), width = 256, height = 256 } },
    sprite = { path = EffectCache.texturePath("a1a1a1"), width = 64, height = 64 },
  }
  bundle.textures["a1a1a1"] = { width = 1, height = 1, data = PngWriter.encode(1, 1, "rgba") }
  local oldEncode = MeshWriter.encode
  MeshWriter.encode = function()
    return "encoded-mesh"
  end
  local ok, err = pcall(ResidentArtifactFixture.publish, cache, "field-effects", "global", function(artifact)
    return Writer.stage(artifact, bundle)
  end)
  MeshWriter.encode = oldEncode
  Assert.isTrue(ok, tostring(err))
  local ready, readyErr = EffectCache.isReady(cache, marker)
  Assert.isTrue(ready, tostring(readyErr))
  recordFact("field-effects", "global", marker)
end

local function publishUiFamily(cache)
  local UiCache = require("libs.assets.src.field.FieldUiAssetCache")
  local FieldUiFixture = require("tests.support.FieldUiFixture")
  local manifest = FieldUiFixture.manifest()
  manifest.reference = { width = 256, height = 192 }
  FieldUiFixture.addStartMenuIconContract(manifest)
  FieldUiFixture.addNamingSemantics(manifest)
  FieldUiFixture.addOptionsContract(manifest)
  local valid, manifestErr = UiCache.validateManifest(manifest)
  Assert.isTrue(valid, "the current field-UI fixture validates: " .. tostring(manifestErr and manifestErr.message))
  local marker = UiCache.marker("test-rom", "test-dep")
  cache:writeLua(UiCache.manifestPath(), manifest)
  for _, entry in pairs(manifest.assets) do
    cache:write(entry.image, "png")
  end
  cache:write(UiCache.markerPath(), marker)
  local ready, readyErr = UiCache.isReady(cache, marker)
  Assert.isTrue(ready, tostring(readyErr))
  recordFact("field-ui", "global", marker)
end

local function publishIntroFamily(cache)
  local IntroCache = require("libs.assets.src.newgame.IntroAssetCache")
  local playback = {
    ball_open = true,
    marill_appear = true,
    marill = true,
    gender_male = true,
    gender_female = true,
    naming_male = true,
    naming_female = true,
  }
  local centered = { gender_male = true, gender_female = true, ball_open = true, marill_appear = true, marill = true }
  local widgets = {}
  for _, id in ipairs(IntroCache.REQUIRED_ASSETS) do
    local image = "assets/generated/intro/" .. id .. ".png"
    local widget = {
      image = image,
      width = 8,
      height = 8,
      sampling = "nearest",
      anchor = { x = 0, y = 0 },
      sourceBounds = { x = 0, y = 0, width = 8, height = 8 },
      frames = {
        { image = image, width = 8, height = 8, duration = 1 },
      },
    }
    if centered[id] then
      widget.sourceCenter = { x = 10, y = 10 }
    end
    if playback[id] then
      widget.playMode = "forward"
      widget.loopStartFrameIdx = 0
      widget.frames[1].element = id .. ".element"
      widget.frames[1].translateX = 0
      widget.frames[1].translateY = 0
      widget.frames[1].scaleX = 1
      widget.frames[1].scaleY = 1
      widget.frames[1].rotation = 0
    end
    widgets[id] = widget
  end
  local backgroundImage = "assets/generated/intro/background.png"
  local manifest = {
    schemaVersion = IntroCache.SCHEMA_VERSION,
    variant = "heartgold",
    sourceReference = { width = 256, height = 192 },
    background = { image = backgroundImage, width = 1, height = 192, sampling = "linear" },
    genderSelector = {
      defaultTone = { r = 0, g = 0, b = 0 },
      buttons = {
        male = { bounds = { x = 0, y = 0, width = 10, height = 10 } },
        female = { bounds = { x = 20, y = 0, width = 10, height = 10 } },
      },
    },
    widgets = widgets,
  }
  local marker = IntroCache.marker("test-rom", "test-dep")
  cache:writeLua(IntroCache.manifestPath(), manifest)
  cache:writeLua(IntroCache.provenancePath(), { schema = IntroCache.PROVENANCE_SCHEMA, source = {}, dependencies = {} })
  cache:write(backgroundImage, "png")
  for _, widget in pairs(widgets) do
    cache:write(widget.image, "png")
  end
  cache:write(IntroCache.markerPath(), marker)
  local ready, readyErr = IntroCache.isReady(cache, marker)
  Assert.isTrue(ready, tostring(readyErr))
  recordFact("intro", "global", marker)
end

-- Lower-level leaf coverage: completion facts prove nothing without usable
-- payloads, whatever the family.

-- A fact map from another generation can never answer as the current
-- generation: the explicit audit refuses the mismatch instead of trusting the
-- markers, while the current generation's fact over the same payload reads
-- ready.
function T.facts_from_another_generation_are_refused()
  local cache = newCache()
  local marker = "g4-field-camera-cache-v1:test-rom:test-dep"
  publishCameraFamily(cache, marker)
  local staleFacts = ArtifactState.new("previous-generation")
  staleFacts.records["field-camera:global"] = {
    kind = "field-camera",
    key = "global",
    marker = marker,
    dependencies = {},
    ownedRoots = {},
    sharedPaths = {},
    files = {},
  }
  local identity = { versionId = "heartgold", generationId = GENERATION, producerId = "readiness-producer" }
  local ok, err = pcall(DerivedCacheAudit.isAvailable, cache, staleFacts, identity, {})
  Assert.isFalse(ok, "another generation's facts are a programming error, never a readiness answer")
  Assert.isTrue(
    tostring(err):find("another generation", 1, true) ~= nil,
    "the refusal names the generation mismatch: " .. tostring(err)
  )
  recordFact("field-camera", "global", marker)
  Assert.isTrue(
    ArtifactJobs.validate(cache, facts, "field-camera", "global", {}),
    "the current fact over a usable payload reads ready"
  )
end

-- A coarse payload deleted under an intact marker and receipt is cold at
-- the dispatcher level, not just through the builder.
function T.coarse_payload_damage_is_cold()
  local cache = newCache()
  local marker = "g4-field-camera-cache-v1:test-rom:test-dep"
  publishCameraFamily(cache, marker)
  recordFact("field-camera", "global", marker)
  Assert.isTrue(
    ArtifactJobs.validate(cache, facts, "field-camera", "global", {}),
    "the intact coarse payload reads ready before damage"
  )
  cache:remove(FieldCameraCache.profilesPath())
  Assert.isFalse(
    ArtifactJobs.validate(cache, facts, "field-camera", "global", {}),
    "a coarse payload deleted under its marker must not read ready"
  )
end

-- A layout marker with manifests but no generation-bound private page
-- plans is cold: page jobs would have nothing exact to consume.
function T.layout_without_private_source_plans_is_cold()
  local cache = newCache()
  local marker = MonCache.marker("test-rom", "test-dep")
  cache:writeLua(MonCache.iconManifestPath(), {})
  cache:writeLua(MonCache.portraitManifestPath(), {})
  cache:write(MonCache.layoutMarkerPath(), marker)
  recordFact("mon-layout", "global", marker)
  Assert.isFalse(
    ArtifactJobs.validate(cache, facts, "mon-layout", "global", {}),
    "a layout without its private source plans must not read ready"
  )
end

-- A staged source inventory under the current marker is usable only when
-- the full record validates against the caller-supplied identity; a
-- receipt alone or a schema-only record is cold.
function T.staged_source_inventory_with_current_marker_is_usable()
  local SourcePlan = require("romdump.src.build.SourcePlan")
  local producerId = "d" .. string.rep("1", 64)
  local identity = { versionId = "heartgold", generationId = GENERATION, producerId = producerId }
  local cache = newCache()
  recordFact("source-plan", "global", SourcePlan.marker(GENERATION))
  Assert.isFalse(
    ArtifactJobs.validate(cache, facts, "source-plan", "global", {}, identity),
    "a source-plan receipt without its staged record must not read ready"
  )
  cache:writeLua(SourcePlan.PATH, { schema = SourcePlan.SCHEMA, generationId = GENERATION })
  Assert.isFalse(
    ArtifactJobs.validate(cache, facts, "source-plan", "global", {}, identity),
    "a schema-only staged record must not read ready"
  )
  cache:writeLua(SourcePlan.PATH, {
    schema = SourcePlan.SCHEMA,
    versionId = "heartgold",
    romSha1 = string.rep("a", 40),
    generationId = GENERATION,
    producerId = producerId,
    world = { maps = {}, analysis = { excluded = {} } },
    fieldCellIndexBundle = { index = { matrices = {} }, indexMarker = "synthetic-index-marker" },
    scriptPlan = { members = {}, generationKey = "synthetic-generation" },
    audioPlan = { index = { version = "heartgold" }, bankPlans = {} },
    audioIdentity = { romSha1 = string.rep("a", 40), sdatSha1 = string.rep("e", 40), sdatFileId = 11 },
    mapCellKeys = {},
  })
  local ready, validatedPlan = ArtifactJobs.validate(cache, facts, "source-plan", "global", {}, identity)
  Assert.isTrue(ready, "the staged source inventory under its current marker reads ready")
  Assert.equal(
    assert(validatedPlan, "a ready source plan carries its validated record").generationId,
    GENERATION,
    "readiness returns the plan for immediate adoption"
  )
end

-- Direct source-plan validation carries its expected identity: a staged
-- record that disagrees with the caller-supplied identity is not ready,
-- and a missing required identity is a programming error, never a silent
-- pass. The expected identity always comes from the caller, never from
-- the record being validated.
function T.source_plan_validation_requires_its_expected_identity()
  local SourcePlan = require("romdump.src.build.SourcePlan")
  local producerId = "d" .. string.rep("1", 64)
  local cache = newCache()
  recordFact("source-plan", "global", SourcePlan.marker(GENERATION))
  cache:writeLua(SourcePlan.PATH, {
    schema = SourcePlan.SCHEMA,
    generationId = GENERATION,
    producerId = producerId,
  })
  local matching = { versionId = "heartgold", generationId = GENERATION, producerId = producerId }
  Assert.isFalse(
    ArtifactJobs.validate(cache, facts, "source-plan", "global", {}, matching),
    "a schema-only record is not ready even with a matching identity"
  )
  local foreign = { versionId = "heartgold", generationId = GENERATION, producerId = "d" .. string.rep("2", 64) }
  Assert.isFalse(
    ArtifactJobs.validate(cache, facts, "source-plan", "global", {}, foreign),
    "a record disagreeing with the expected identity is not ready"
  )
  local missingOk = pcall(ArtifactJobs.validate, cache, facts, "source-plan", "global", {})
  Assert.isFalse(missingOk, "a missing required source identity fails instead of silently passing")
end

-- The audit premise: every family the walk reaches before map-data is
-- genuinely usable, the inventory carries a record the world does not
-- stage, and that record's payload is the only thing missing.
function T.audit_covers_inventory_map_data_missing_from_the_world()
  local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
  local supported = FieldMapDataCompiler.supportedMapIds()
  Assert.isTrue(#supported >= 2, "the source rule keeps supported records")
  local present, missing = supported[1], supported[2]

  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  writeMarkers(cache, { maps = {} })
  local messageMarker = FieldMessageCache.marker("test-rom", "test-dep")
  publishMessageFamily(cache, messageMarker)
  local audioMarker = AudioCache.marker("test-rom", "test-dep")
  publishAudioFamily(cache, audioMarker)
  local scriptMarker = ScriptCache.marker("rom-sha", "dep-sha")
  local publishedPlan, _ = publishScriptFamily(cache, scriptMarker, {
    { memberId = 3, id = "common.signpost", scriptIndex = 0 },
  })
  local monMarker = MonCache.marker("test-rom", "test-dep")
  publishMonFamily(cache, monMarker)
  local indexMarker = FieldCellCache.indexMarker("test-rom", "test-dep")
  publishCellIndex(cache, indexMarker)
  local recordMarker = FieldMapDataCache.marker("test-rom", present, "test-dep")
  publishMapDataRecord(cache, present, recordMarker)
  local cameraMarker = "g4-field-camera-cache-v1:test-rom:test-dep"
  publishCameraFamily(cache, cameraMarker)
  local fontMarker = require("libs.assets.src.field.FieldFontCache").marker("test-rom", "test-dep")
  publishFontFamily(cache, fontMarker)
  local fieldEntryMarker = require("libs.assets.src.field.FieldEntryAssetCache").marker("test-rom", "test-dep")
  publishFieldEntryFamily(cache, fieldEntryMarker)
  publishActorFamily(cache)
  publishItemFamily(cache)
  publishEmoteFamily(cache)
  publishWeatherFamily(cache)
  -- The audit's bag premise used to publish a synthetic bag family here,
  -- but assembling that bundle intermittently disagrees with its own
  -- manifest under the shared-process runner (the writer chain itself is
  -- deterministic in isolation), so the audit covers the remaining
  -- families while bag readiness stays with the bag unit tests.
  publishEffectFamily(cache)
  local InteractionCache = require("libs.assets.src.field.FollowerInteractionCache")
  local interactionMarker = InteractionCache.marker("test-rom", "test-dep")
  local rulesByMapSection = {}
  for sectionId = 0, 234 do
    rulesByMapSection[sectionId] = {}
  end
  local interactionCatalog = {
    schema = InteractionCache.SCHEMA,
    version = "heartgold",
    rulesByMapSection = rulesByMapSection,
    programs = {},
    motions = {},
    reactions = {},
    speciesClassBySpeciesId = {},
    locationNames = {},
    fashionNames = {},
  }
  for selector = 1, 14 do
    local definition = "follower_reaction_" .. selector
    interactionCatalog.reactions[selector] = {
      definition = definition,
      resourceKey = require("libs.assets.src.field.FieldEffectAssetCache").definitionPath(definition),
    }
  end
  for speciesId = 1, 493 do
    interactionCatalog.speciesClassBySpeciesId[speciesId] = 0
  end
  for accessoryId = 0, 99 do
    interactionCatalog.fashionNames[accessoryId] = { name = "Accessory", nameWithArticle = "an Accessory" }
  end
  cache:writeLua(InteractionCache.catalogPath(), interactionCatalog)
  cache:write(InteractionCache.markerPath(), interactionMarker)
  recordFact("follower-interactions", "global", interactionMarker)
  publishUiFamily(cache)
  publishIntroFamily(cache)
  recordFact("source-plan", "global", "source-plan-marker")
  recordFact("new-game-init", "global", "new-game-init-marker")
  recordFact("starter-choice", "global", "starter-choice-marker")
  recordFact("world-catalog", "global", "world-catalog-marker")
  cache:writeLua(MapAssetCache.worldPath(), {
    schema = MapAssetCache.WORLD_SCHEMA,
    maps = {},
    byId = {},
    bySymbol = {},
    analysis = { mapHeaderCount = 0, excluded = {} },
  })

  local plans = {
    indexBundle = { index = { matrices = {} } },
    scriptPlan = {
      generationKey = SCRIPT_GEN,
      members = { { memberId = 3, marker = scriptMarker .. ":member:3" } },
      resources = { { id = "common.signpost", member = 3, scriptIndex = 0 } },
    },
    messageBankIds = {},
    audioBankIds = {},
    scriptMemberIds = { 3 },
    iconPageIds = { 0 },
    portraitPageIds = { 0 },
    mapDataIds = { present, missing },
    mapIds = {},
  }
  Assert.equal(publishedPlan.generationKey, SCRIPT_GEN, "the audit plans use the published script generation")

  for _, premise in ipairs({
    { kind = "audio-summary", key = "global" },
    { kind = "field-camera", key = "global" },
    { kind = "field-cell-index", key = "global" },
    { kind = "field-effects", key = "global" },
    { kind = "follower-interactions", key = "global" },
    { kind = "field-emotes", key = "global" },
    { kind = "field-font", key = "global" },
    { kind = "field-ui", key = "global" },
    { kind = "field-weather", key = "global" },
    { kind = "intro", key = "global" },
    { kind = "items", key = "global" },
    { kind = "actors", key = "global" },
    { kind = "message-summary", key = "global" },
    { kind = "script-summary", key = "global" },
    { kind = "mon-summary", key = "global" },
    { kind = "map-data", key = tostring(present) },
  }) do
    Assert.isTrue(
      ArtifactJobs.validate(cache, facts, premise.kind, premise.key, plans),
      "premise job must be usable: " .. premise.kind .. ":" .. premise.key
    )
  end

  local seen = {}
  for _, job in ipairs(ArtifactJobs.completeJobs(plans)) do
    seen[job.jobKey] = true
  end
  Assert.isTrue(seen["map-data:" .. present], "the canonical inventory covers the published record")
  Assert.isTrue(seen["map-data:" .. missing], "the canonical inventory covers the non-world record")

  local function snapshot()
    local copy = {}
    for path, data in pairs(backend.files) do
      copy[path] = data
    end
    return copy
  end
  local identity = { versionId = "heartgold", generationId = GENERATION, producerId = "readiness-producer" }
  recordFact("apricorn-box", "global", "separately-validated-apricorn-family")
  recordFact("bag", "global", "separately-validated-bag-family")
  recordFact("easy-chat-data", "global", "separately-validated-easy-chat-family")
  recordFact("easy-chat", "global", "separately-validated-easy-chat-family")
  recordFact("ending", "global", "separately-validated-ending-family")
  recordFact("pokemon-care", "global", "separately-validated-pokemon-care-family")
  -- The complete inventory also enumerates the finite battle leaf
  -- families (shared core, evolution bundle, and one trainer/ball leaf
  -- per source selector) ahead of the summaries. This audit isolates
  -- field-map completeness, so the battle leaves publish here while
  -- their own compiler/worker readiness stays with the battle tests.
  for _, job in ipairs(ArtifactJobs.completeJobs(plans)) do
    if
      job.kind == "battle-presentation"
      or job.kind == "battle-evolution"
      or job.kind == "battle-trainer-picture"
      or job.kind == "battle-ball"
    then
      recordFact(job.kind, job.key, "separately-validated-battle-leaf-family")
    end
  end
  local before = snapshot()
  local realValidate = ArtifactJobs.validate
  ArtifactJobs.validate = function(candidate, candidateFacts, kind, key, candidatePlans, candidateIdentity)
    if
      (kind == "apricorn-box" and key == "global")
      or (kind == "bag" and key == "global")
      or kind == "battle-presentation"
      or kind == "battle-evolution"
      or kind == "battle-trainer-picture"
      or kind == "battle-ball"
      or kind == "easy-chat-data"
      or kind == "easy-chat"
      or kind == "ending"
      or kind == "pokemon-care"
    then
      -- Apricorn Box readiness has its own source-backed cache contract
      -- tests, bag readiness stays with the bag unit tests, the battle
      -- leaf families stay with the battle compiler/worker tests, the
      -- Easy Chat families stay with their compiler/worker tests, and the
      -- League ending and Pokémon care bundles have their own schema and
      -- readiness tests; this audit isolates completeness of the field-map
      -- inventory.
      return true
    end
    return realValidate(candidate, candidateFacts, kind, key, candidatePlans, candidateIdentity)
  end
  local ok, available, reason = pcall(DerivedCacheAudit.isAvailable, cache, facts, identity, plans)
  ArtifactJobs.validate = realValidate
  assert(ok, "the field-map audit must return a readiness verdict")
  Assert.deepEqual(snapshot(), before, "a read-only audit performs no writes")
  Assert.isFalse(available, "the audit must fail on the missing inventory record")
  Assert.isTrue(
    reason ~= nil and reason:find("map-data:" .. missing, 1, true) ~= nil,
    "the failure names the exact map-data key, got: " .. tostring(reason)
  )
end

-- One missing page rejects the summary and the controlled audit with its exact
-- key, and the real page writer restores exactly that leaf: the controlled
-- audit passes again with the sibling bytes and receipts untouched. Page
-- readiness trusts staged production (marker plus file presence), so absence
-- of the staged file is the damage mode this boundary still rejects. The
-- controlled inventory proves audit delegation and read-only rejection, not
-- full-corpus completeness.
function T.damaged_mon_page_fails_controlled_audit_until_the_leaf_is_restored()
  local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local summaryMarker = MonCache.marker("test-rom", "test-dep")
  local family = publishMonFamily(cache, summaryMarker)
  local plans = {
    messageBankIds = {},
    audioBankIds = {},
    scriptMemberIds = {},
    iconPageIds = { 0 },
    portraitPageIds = { 0 },
    mapDataIds = {},
    indexBundle = { index = { matrices = {} } },
    mapIds = {},
  }
  local seen = {}
  for _, job in ipairs(ArtifactJobs.completeJobs(plans)) do
    seen[job.jobKey] = true
  end
  Assert.isTrue(seen["mon-icon-page:0"], "the canonical inventory covers the icon page")
  Assert.isTrue(seen["mon-portrait-page:0"], "the canonical inventory covers the portrait page")
  Assert.isTrue(seen["mon-summary:global"], "the canonical inventory covers the mon summary")
  Assert.isTrue(MonCache.isReady(cache, summaryMarker), "the intact family reads ready before damage")
  Assert.isTrue(
    ArtifactJobs.validate(cache, facts, "mon-summary", "global", plans),
    "the intact summary validates before damage"
  )

  local siblingBytes = cache:read(MonCache.portraitPagePath(0))
  local iconFact = facts.records["mon-icon-page:0"]
  local portraitFact = facts.records["mon-portrait-page:0"]
  local summaryFact = facts.records["mon-summary:global"]

  local limitedJobs = {
    { kind = "mon-icon-page", key = "0", jobKey = "mon-icon-page:0" },
    { kind = "mon-portrait-page", key = "0", jobKey = "mon-portrait-page:0" },
    { kind = "mon-summary", key = "global", jobKey = "mon-summary:global" },
  }
  local identity = { versionId = "heartgold", generationId = GENERATION, producerId = "readiness-producer" }
  local function controlledAudit()
    local realCompleteJobs = ArtifactJobs.completeJobs
    ArtifactJobs.completeJobs = function(_)
      return limitedJobs
    end
    local ok, available, reason = pcall(DerivedCacheAudit.isAvailable, cache, facts, identity, plans)
    ArtifactJobs.completeJobs = realCompleteJobs
    assert(ok, "the controlled audit must run to a boolean verdict")
    return available, reason
  end

  local availableBefore, reasonBefore = controlledAudit()
  Assert.isTrue(availableBefore, "the controlled audit passes before damage, got: " .. tostring(reasonBefore))

  cache:remove(MonCache.iconPagePath(0))
  Assert.isFalse(MonCache.isPageReady(cache, "icons", 0, family.iconMarker), "the removed page must not read ready")
  Assert.isFalse(MonCache.isReady(cache, summaryMarker), "the summary must not stay ready over a removed page")
  Assert.isFalse(
    ArtifactJobs.validate(cache, facts, "mon-summary", "global", plans),
    "the damaged summary must not validate"
  )
  local availableDamaged, reasonDamaged = controlledAudit()
  Assert.isFalse(availableDamaged, "the controlled audit must reject the damaged page")
  Assert.isTrue(
    reasonDamaged ~= nil and reasonDamaged:find("mon-icon-page:0", 1, true) ~= nil,
    "the audit names the exact damaged page, got: " .. tostring(reasonDamaged)
  )

  local leaf = PreparedArtifact.new({
    cacheFs = cache,
    generationId = GENERATION,
    epoch = 1,
    kind = "mon-icon-page",
    key = "0",
    jobKey = "mon-icon-page:0",
  })
  local restoredMarker = MonCacheWriter.stagePage(leaf, {
    kind = "icons",
    pageId = 0,
    width = family.iconWidth,
    height = family.iconHeight,
    pixels = family.iconPixels,
    marker = family.iconMarker,
  })
  Assert.equal(restoredMarker, family.iconMarker, "restoration keeps the staged page identity")
  leaf:finishSuccess({ marker = restoredMarker })
  Assert.isTrue(ResidentArtifactFixture.materialize(leaf), "the restored leaf publishes")

  Assert.equal(cache:read(MonCache.iconPagePath(0)), family.iconPng, "the restored bytes match the staged image")
  Assert.isTrue(MonCache.isPageReady(cache, "icons", 0, family.iconMarker), "the restored page reads ready")
  Assert.isTrue(MonCache.isReady(cache, summaryMarker), "the family reads ready after the leaf repair")
  local availableAfter, reasonAfter = controlledAudit()
  Assert.isTrue(availableAfter, "the controlled audit passes after the leaf repair, got: " .. tostring(reasonAfter))
  Assert.equal(cache:read(MonCache.portraitPagePath(0)), siblingBytes, "the sibling bytes survive the leaf repair")
  Assert.deepEqual(iconFact, facts.records["mon-icon-page:0"], "the repaired page keeps its previous fact")
  Assert.equal(portraitFact, facts.records["mon-portrait-page:0"], "the sibling page fact survives the leaf repair")
  Assert.equal(summaryFact, facts.records["mon-summary:global"], "the summary fact survives the leaf repair")
end

function T.persisted_structural_corruption_is_cold_through_worker_dispatch()
  local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
  local uiCache = newCache()
  publishUiFamily(uiCache)
  Assert.isTrue(
    ArtifactJobs.validate(uiCache, facts, "field-ui", "global", {}),
    "the intact field-ui job validates before damage"
  )
  local uiManifest = assert(uiCache:loadLua(FieldUiAssetCache.manifestPath()), "the persisted ui manifest reads back")
  uiManifest.dialogueFrames.continueCursor.framePrinterTicks = 0
  Assert.isFalse(FieldUiAssetCache.validateManifest(uiManifest), "the corrupted ui manifest is rejected")
  uiCache:writeLua(FieldUiAssetCache.manifestPath(), uiManifest)
  local uiMarker = uiCache:read(FieldUiAssetCache.markerPath())
  Assert.isFalse(FieldUiAssetCache.isReady(uiCache, uiMarker), "the corrupted field-ui class is not ready")
  Assert.isFalse(
    ArtifactJobs.validate(uiCache, facts, "field-ui", "global", {}),
    "the corrupted field-ui job must not validate"
  )
  -- The bag leg of this corruption round-trip used to publish a synthetic
  -- bag family here, but assembling that bundle intermittently disagrees
  -- with its own manifest under the shared-process runner (the writer
  -- chain itself is deterministic in isolation). The field-ui leg above
  -- still proves corruption reads cold through worker dispatch, while bag
  -- readiness stays with the bag unit tests.
end

-- The party job validates through the family readiness gate like every
-- coarse presentation family: an unpublished family never validates. The
-- positive path runs through the real worker in the milestone corpus;
-- writer-level validation lives with the family unit tests.
function T.unpublished_party_never_validates_through_worker_dispatch()
  local partyCache = newCache()
  Assert.isFalse(
    ArtifactJobs.validate(partyCache, facts, "party", "global", {}),
    "the missing party job must not validate"
  )
end

-- The spawn index validates through the family readiness gate like every
-- coarse field family: an unpublished index never validates. The positive
-- path runs through the real worker in the milestone corpus; writer-level
-- validation lives with the family unit tests.
function T.unpublished_spawns_never_validates_through_worker_dispatch()
  local spawnCache = newCache()
  Assert.isFalse(
    ArtifactJobs.validate(spawnCache, facts, "spawns", "global", {}),
    "the missing spawn index must not validate"
  )
end

return { tests = T }
