-- Startup cache contracts keep loader and title output bounded and separate.

local Assert = require("tests.support.Assert")
local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
local ArtifactState = require("romdump.src.build.ArtifactState")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local StartupAssetCache = require("libs.assets.src.StartupAssetCache")
local StartupAssetContract = require("libs.assets.src.DerivedAssetContract")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")

local T = {}

function T.startup_families_are_closed_global_artifacts()
  Assert.isTrue(ArtifactState.KINDS["startup-loader"] == true, "startup-loader is a known family")
  Assert.equal(ArtifactState.path("startup-loader", "1"), "data/generated/jobs/startup-loader/1.lua")
  Assert.equal(ArtifactState.path("startup-loader", "32"), "data/generated/jobs/startup-loader/32.lua")
  Assert.isFalse(pcall(ArtifactState.path, "startup-loader", "global"), "startup-loader rejects the legacy global key")
  Assert.isFalse(pcall(ArtifactState.path, "startup-loader", "0"), "startup-loader keys start at one")
  Assert.isFalse(pcall(ArtifactState.path, "startup-loader", "33"), "startup-loader keys end at thirty-two")
  Assert.isTrue(pcall(ArtifactJobs.sizeClass, "startup-loader"), "startup-loader has a worker descriptor")
  Assert.isTrue(ArtifactState.KINDS["startup-title"] == true, "startup-title is a known family")
  Assert.equal(ArtifactState.path("startup-title", "global"), "data/generated/jobs/startup-title/global.lua")
  Assert.isFalse(pcall(ArtifactState.path, "startup-title", "1"), "startup-title rejects numeric selectors")
  Assert.isTrue(pcall(ArtifactJobs.sizeClass, "startup-title"), "startup-title has a worker descriptor")
end

function T.startup_jobs_are_present_in_the_full_corpus_iterator()
  local jobs = ArtifactJobs.completeIterator({
    messageBankIds = {},
    audioBankIds = {},
    scriptMemberIds = {},
    iconPageIds = {},
    portraitPageIds = {},
    mapDataIds = {},
    mapIds = {},
    indexBundle = { index = { matrices = {} } },
  })
  local found = {}
  while true do
    local job = jobs()
    if job == nil then
      break
    end
    if job.kind == "startup-loader" then
      found[job.kind] = (found[job.kind] or 0) + 1
    elseif job.kind == "startup-title" then
      found[job.kind] = job.key == "global"
    end
  end
  Assert.isNil(found["startup-loader"], "the selected walking pair never joins the eager corpus sweep")
  Assert.deepEqual(found, { ["startup-title"] = true })
end

function T.startup_manifests_have_fixed_versioned_paths()
  local ok, StartupAssetCache = pcall(require, "libs.assets.src.StartupAssetCache")
  Assert.isTrue(ok, "strict startup manifest reader exists")
  Assert.equal(StartupAssetCache.walkerPath(5), "data/generated/startup/loader/pairs/5.lua")
  Assert.equal(StartupAssetCache.titlePath(), "data/generated/startup/title.lua")
end

function T.walker_manifest_requires_its_generated_atlas_files()
  local visual = {
    render = { kind = "atlas", frameWidth = 1, frameHeight = 1, frameCount = 2 },
    pivot = { x = 0.5, y = 1 },
    directions = {
      east = { walk = { frames = { { frameIndex = 1, ticks = 1 }, { frameIndex = 2, ticks = 1 } } } },
    },
  }
  local manifest = {
    schema = StartupAssetContract.startupWalker.schema,
    versionId = "heartgold",
    generationId = "generation-a",
    pairIndex = 5,
    hero = { atlasPath = "assets/generated/startup/loader/pairs/5/hero.png", visual = visual },
    follower = {
      speciesId = 25,
      atlasPath = "assets/generated/startup/loader/pairs/5/follower.png",
      visual = visual,
    },
  }
  local cacheFs = {
    loadLua = function()
      return manifest
    end,
    exists = function()
      return false
    end,
  }
  local loaded, err = StartupAssetCache.loadWalker(cacheFs, 5)
  Assert.isNil(loaded)
  Assert.notNil(err, "a walking pair with missing atlas files is not ready")
end

-- The visual startup scopes own no audio membership even beside an
-- adopted plan: only the optional audio roster resolves banks from it.
function T.title_visual_scopes_ignore_adopted_audio_membership()
  local plan = {
    audioPlan = {
      index = {
        version = "heartgold",
        sequences = {
          [41] = { bankId = 7 },
          [42] = { bankId = 8 },
          [43] = { bankId = 7 },
        },
        sequenceBySymbol = {
          SEQ_GS_TITLE = 43,
          SEQ_GS_POKEMON_THEME = 41,
          SEQ_SE_DP_SELECT = 42,
        },
      },
    },
  }
  do
    local dependencies, complete = ArtifactJobs.dependencies("startup-title", "global", plan)
    Assert.isTrue(complete, "startup-title stays final beside an adopted audio plan")
    Assert.deepEqual(dependencies, {}, "startup-title keeps no audio prerequisite")
  end
  do
    local dependencies, complete = ArtifactJobs.dependencies("startup-loader", "5", plan)
    Assert.isTrue(complete, "startup-loader stays final beside an adopted audio plan")
    Assert.deepEqual(dependencies, {}, "startup-loader keeps no audio prerequisite")
  end
  Assert.deepEqual(ArtifactJobs.startupTitleJobs(), { { kind = "startup-title", key = "global" } })
  local roster, resolved = ArtifactJobs.startupAudioJobs(plan.audioPlan)
  Assert.isTrue(resolved, "the optional audio roster resolves from the adopted index")
  local found = {}
  for _, member in ipairs(roster) do
    found[member.kind .. ":" .. member.key] = true
  end
  Assert.isTrue(found["audio-bank:7"], "theme bank is included")
  Assert.isTrue(found["audio-bank:8"], "menu select bank is included")
  Assert.isTrue(found["audio-bank:250"], "HeartGold cry bank is included")
end

function T.startup_writer_owns_disjoint_roots_and_stages_manifest_last()
  local StartupCacheWriter = require("romdump.src.digest.startup.StartupCacheWriter")
  local writes, roots = {}, {}
  local stage = {
    write = function(_, path, bytes)
      writes[#writes + 1] = { path = path, bytes = bytes }
    end,
    writeLua = function(_, path, record)
      writes[#writes + 1] = { path = path, record = record }
    end,
    loadLua = function(_, path)
      for _, write in ipairs(writes) do
        if write.path == path then
          return write.record
        end
      end
    end,
    exists = function(_, path, kind)
      Assert.equal(kind, "file")
      for _, write in ipairs(writes) do
        if write.path == path then
          return true
        end
      end
      return false
    end,
  }
  local artifact = {
    stageFs = function()
      return stage
    end,
    addOwnedRoot = function(_, path)
      roots[#roots + 1] = path
    end,
  }
  local function pairVisual(frameWidth, frameHeight)
    return {
      render = { kind = "atlas", frameWidth = frameWidth, frameHeight = frameHeight, frameCount = 2 },
      pivot = { x = 0.5, y = 1 },
      directions = {
        east = { walk = { frames = { { frameIndex = 1, ticks = 1 }, { frameIndex = 2, ticks = 1 } } } },
      },
    }
  end
  local heroPixels = string.char(200, 180, 120, 255) .. string.char(0, 0, 0, 0)
  local followerPixels = string.char(200, 180, 120, 255) .. string.char(0, 0, 0, 0)
  local bundle = {
    manifest = {
      schema = "g4-startup-walker-v1",
      versionId = "heartgold",
      pairIndex = 5,
      hero = {
        atlasPath = "assets/generated/startup/loader/pairs/5/hero.png",
        visual = pairVisual(1, 1),
      },
      follower = {
        speciesId = 25,
        atlasPath = "assets/generated/startup/loader/pairs/5/follower.png",
        visual = pairVisual(1, 1),
      },
    },
    atlases = {
      ["assets/generated/startup/loader/pairs/5/hero.png"] = { width = 2, height = 1, pixels = heroPixels },
      ["assets/generated/startup/loader/pairs/5/follower.png"] = { width = 2, height = 1, pixels = followerPixels },
    },
    dependencies = { versionId = "heartgold" },
    sourceHash = "source-hash",
  }
  Assert.isTrue(pcall(StartupCacheWriter.stageLoader, artifact, bundle, "generation-a", 5))
  Assert.equal(#roots, 2, "one manifest file and one pair directory are owned")
  local rootSet = {}
  for _, path in ipairs(roots) do
    rootSet[path] = true
  end
  Assert.isTrue(rootSet["data/generated/startup/loader/pairs/5.lua"])
  Assert.isTrue(rootSet["assets/generated/startup/loader/pairs/5"])
  Assert.isNil(rootSet["assets/generated/startup/loader"], "staging one pair never owns the shared loader root")
  Assert.equal(writes[#writes].path, StartupAssetCache.walkerPath(5), "manifest is the last staged file")
  Assert.equal(writes[#writes].record.generationId, "generation-a")
end

function T.title_writer_stages_compiler_files()
  local StartupCacheWriter = require("romdump.src.digest.startup.StartupCacheWriter")
  local ModelAsset = require("libs.assets.src.model.ModelAsset")
  local writes = {}
  local stage = {
    write = function(_, path, bytes)
      writes[#writes + 1] = { path = path, bytes = bytes }
    end,
    writeLua = function(_, path, record)
      writes[#writes + 1] = { path = path, record = record }
    end,
    loadLua = function(_, path)
      for _, write in ipairs(writes) do
        if write.path == path then
          return write.record
        end
      end
    end,
  }
  local artifact = {
    stageFs = function()
      return stage
    end,
    addOwnedRoot = function() end,
  }
  local meshData = {
    getSize = function()
      return 10
    end,
  }
  local bundle = {
    manifest = {
      schema = StartupAssetContract.startupTitle.schema,
      versionId = "heartgold",
      kind = "animated-title",
      legendary = "ho-oh",
      crySpeciesId = 250,
      sequence = "SEQ_GS_POKEMON_THEME",
      menuSelectSequence = "SEQ_SE_DP_SELECT",
      model = {
        schema = ModelAsset.SCHEMA,
        key = "startup-title:test",
        kind = "static",
        batches = {},
        materials = {},
      },
      clips = {
        joint = { category = "joint", kind = "trs", compiled = {}, tracks = { {} } },
        srt = { category = "material", kind = "texsrt", compiled = {}, tracks = { {} } },
        color = { category = "material", kind = "color", compiled = {}, tracks = { {} } },
        pattern = { category = "material", kind = "pattern", compiled = {}, tracks = { {} } },
      },
      surfaces = {},
      sparkle = {},
      timeline = {},
    },
    files = { ["assets/generated/startup/title/geometry/test.g4mesh"] = meshData },
  }
  local staged = pcall(StartupCacheWriter.stageTitle, artifact, bundle, "generation-a")
  Assert.isFalse(staged, "strict readback rejects a hollow title bundle after staging its files")
  Assert.equal(writes[1].path, "assets/generated/startup/title/geometry/test.g4mesh")
  Assert.isTrue(writes[1].bytes == meshData, "finalized Love Data is staged without copying")
  Assert.equal(writes[#writes].path, StartupAssetCache.titlePath())
end

function T.title_stage_write_failure_keeps_the_previous_live_output()
  local StartupCacheWriter = require("romdump.src.digest.startup.StartupCacheWriter")
  local backend = FakeCache.new()
  local cacheFs = CacheFs.forVersion("heartgold", backend)
  local liveAsset = "assets/generated/startup/title/previous.g4mesh"
  local titlePath = StartupAssetCache.titlePath()
  local receiptPath = ArtifactState.path("startup-title", "global")
  cacheFs:write(liveAsset, "previous mesh")
  cacheFs:writeLua(titlePath, { generationId = "previous-generation" })
  cacheFs:writeLua(receiptPath, { generationId = "previous-generation", marker = "previous" })

  local originalWrite = backend.write
  local stagedWrites = 0
  backend.write = function(self, path, bytes)
    stagedWrites = stagedWrites + 1
    if stagedWrites == 2 then
      error("injected staged binary write failure")
    end
    return originalWrite(self, path, bytes)
  end
  local artifact = PreparedArtifact.new({
    cacheFs = cacheFs,
    generationId = "current-generation",
    epoch = 1,
    kind = "startup-title",
    key = "global",
    jobKey = "startup-title:global",
    stageName = "title-write-failure",
  })
  local ok, failure = pcall(StartupCacheWriter.stageTitle, artifact, {
    manifest = { versionId = "heartgold" },
    files = {
      ["assets/generated/startup/title/first.g4mesh"] = "first",
      ["assets/generated/startup/title/second.g4mesh"] = "second",
    },
  }, "current-generation")
  Assert.isFalse(ok, "the injected stage write fails: " .. tostring(failure))
  Assert.equal(
    stagedWrites,
    2,
    "the failure is injected on the second staged write; observed " .. stagedWrites .. ": " .. tostring(failure)
  )
  Assert.isFalse(artifact:stageFs():exists(titlePath, "file"), "a failed family stage has no title manifest")
  Assert.isFalse(artifact:stageFs():exists(receiptPath, "file"), "a failed family stage has no receipt")
  Assert.equal(cacheFs:read(liveAsset), "previous mesh", "the previous live asset remains intact")
  Assert.equal(cacheFs:loadLua(titlePath).generationId, "previous-generation", "the previous live title remains intact")
  Assert.equal(cacheFs:loadLua(receiptPath).marker, "previous", "the previous readiness receipt remains intact")
end

function T.title_manifest_requires_all_model_assets_under_its_owned_root()
  local path = "assets/generated/startup/title/geometry/missing.g4mesh"
  local manifest = {
    schema = StartupAssetContract.startupTitle.schema,
    versionId = "heartgold",
    generationId = "generation-a",
    kind = "animated-title",
    legendary = "ho-oh",
    crySpeciesId = 250,
    sequence = "SEQ_GS_POKEMON_THEME",
    menuSelectSequence = "SEQ_SE_DP_SELECT",
    model = {
      schema = require("libs.assets.src.model.ModelAsset").SCHEMA,
      key = "startup-title:test",
      kind = "nitro-dynamic",
      dynamic = {
        nodes = {
          {
            index = 0,
            name = "root",
            matrixStackIndex = 0,
            translation = { x = 0, y = 0, z = 0 },
            rotation = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
            scale = { x = 1, y = 1, z = 1 },
            transZero = true,
            rotZero = true,
            scaleOne = true,
          },
        },
        transformProgram = { name = "root", nodes = {}, commands = {} },
        batches = {
          {
            id = "draw0.seg0",
            drawIndex = 0,
            segmentIndex = 0,
            nodeIndex = 0,
            materialIndex = 0,
            transformMode = "static",
            positionSource = "draw",
            geometry = path,
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
      },
      animations = {},
      materials = {},
    },
    clips = {
      joint = { category = "joint", kind = "trs", compiled = {}, tracks = { {} } },
      srt = { category = "material", kind = "texsrt", compiled = {}, tracks = { {} } },
      color = { category = "material", kind = "color", compiled = {}, tracks = { {} } },
      pattern = { category = "material", kind = "pattern", compiled = {}, tracks = { {} } },
    },
    surfaces = {},
    sparkle = {},
    timeline = {},
  }
  local cacheFs = {
    loadLua = function()
      return manifest
    end,
    exists = function(_, checkedPath, kind)
      Assert.equal(kind, "file")
      Assert.equal(checkedPath, path)
      return false
    end,
  }
  local loaded, err = StartupAssetCache.loadTitle(cacheFs, "heartgold")
  Assert.isNil(loaded)
  Assert.notNil(err, "a missing model mesh is not a ready title asset")
end

function T.title_manifest_rejects_source_ids_before_runtime_validation()
  local manifest = {
    schema = StartupAssetContract.startupTitle.schema,
    versionId = "heartgold",
    generationId = "generation-a",
    memberId = 25,
  }
  local loaded, err = StartupAssetCache.loadTitle({
    loadLua = function()
      return manifest
    end,
  }, "heartgold")
  Assert.isNil(loaded)
  Assert.notNil(err, "source member identity cannot cross into the runtime manifest")
end

-- The visual startup scopes publish from their own compiled artifacts: no
-- source inventory or audio bank is a prerequisite of either visual job.
function T.startup_visual_dependencies_are_empty_and_final()
  do
    local dependencies, complete = ArtifactJobs.dependencies("startup-title", "global", {})
    Assert.isTrue(complete, "startup-title resolves without adopted plans")
    Assert.deepEqual(dependencies, {}, "startup-title carries no prerequisite jobs")
  end
  do
    local dependencies, complete = ArtifactJobs.dependencies("startup-loader", "5", {})
    Assert.isTrue(complete, "startup-loader resolves without adopted plans")
    Assert.deepEqual(dependencies, {}, "startup-loader carries no prerequisite jobs")
  end
  Assert.deepEqual(ArtifactJobs.startupLoaderJobs(5), { { kind = "startup-loader", key = "5" } })
  Assert.deepEqual(ArtifactJobs.startupTitleJobs(), { { kind = "startup-title", key = "global" } })
end

-- The optional audio closure resolves exactly the opening theme, title theme,
-- menu effect, and legendary cry banks from the adopted index, independent
-- of either visual milestone.
function T.startup_audio_closure_resolves_only_its_required_banks()
  local plan = {
    index = {
      version = "heartgold",
      sequences = { [41] = { bankId = 7 }, [42] = { bankId = 8 }, [43] = { bankId = 9 } },
      sequenceBySymbol = { SEQ_GS_TITLE = 43, SEQ_GS_POKEMON_THEME = 41, SEQ_SE_DP_SELECT = 42 },
    },
  }
  local ok, jobs, complete = pcall(ArtifactJobs.startupAudioJobs, plan)
  Assert.isTrue(ok, "the optional audio roster is independently requestable")
  if ok then
    Assert.isTrue(complete, "the adopted index finalizes the optional roster")
    local set = {}
    for _, job in ipairs(assert(jobs, "a finalized roster lists its jobs")) do
      set[job.kind .. ":" .. job.key] = true
    end
    for _, member in ipairs({
      "source-plan:global",
      "audio-catalog:global",
      "audio-bank:7",
      "audio-bank:8",
      "audio-bank:9",
      "audio-bank:250",
    }) do
      Assert.isTrue(set[member] == true, "the optional roster carries " .. member)
    end
    Assert.isNil(set["startup-title:global"], "no visual job joins the optional roster")
    Assert.isNil(set["startup-loader:global"], "no visual job joins the optional roster")
  end
  local pendingOk, pendingJobs, pendingComplete = pcall(ArtifactJobs.startupAudioJobs, nil)
  Assert.isTrue(pendingOk, "the optional roster stays requestable before adoption")
  if pendingOk then
    Assert.isFalse(pendingComplete, "the optional roster stays unresolved before adoption")
    local pendingSet = {}
    for _, job in ipairs(assert(pendingJobs, "an unresolved roster still lists its owners")) do
      pendingSet[job.kind .. ":" .. job.key] = true
    end
    Assert.isTrue(pendingSet["source-plan:global"] == true, "the unresolved roster keeps its source owner")
    Assert.isTrue(pendingSet["audio-catalog:global"] == true, "the unresolved roster keeps the catalog")
  end
end

-- A shared theme/menu bank appears once beside the edition cry bank, and a
-- missing theme symbol fails the optional roster with its own name.
function T.startup_audio_closure_dedupes_shared_banks_and_names_missing_symbols()
  local shared = {
    index = {
      version = "soulsilver",
      sequences = { [41] = { bankId = 7 } },
      sequenceBySymbol = { SEQ_GS_TITLE = 41, SEQ_GS_POKEMON_THEME = 41, SEQ_SE_DP_SELECT = 41 },
    },
  }
  local ok, jobs, complete = pcall(ArtifactJobs.startupAudioJobs, shared)
  Assert.isTrue(ok, "the optional audio roster is independently requestable")
  if ok then
    Assert.isTrue(complete, "a shared bank still finalizes the optional roster")
    local banks = {}
    for _, job in ipairs(assert(jobs, "a finalized roster lists its jobs")) do
      if job.kind == "audio-bank" then
        banks[#banks + 1] = job.key
      end
    end
    Assert.equal(#banks, 2, "the shared bank appears once beside the cry bank")
    local set = {}
    for _, key in ipairs(banks) do
      set[key] = true
    end
    Assert.isTrue(set["7"] == true, "the shared bank is present")
    Assert.isTrue(set["249"] == true, "the soulsilver cry bank is present")
    local missing = {
      index = {
        version = "heartgold",
        sequences = { [43] = { bankId = 9 } },
        sequenceBySymbol = { SEQ_GS_TITLE = 43 },
      },
    }
    local missingOk, missingErr = pcall(ArtifactJobs.startupAudioJobs, missing)
    Assert.isFalse(missingOk, "a missing theme symbol fails the optional roster")
    Assert.isTrue(
      tostring(missingErr):find("SEQ_GS_POKEMON_THEME", 1, true) ~= nil,
      "the failure names its missing symbol: " .. tostring(missingErr)
    )
  end
end

local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, child in pairs(value) do
    out[deepCopy(key)] = deepCopy(child)
  end
  return out
end

-- A minimal nitro-dynamic descriptor with no referenced files: an
-- untextured material and no batches, so the title reader checks only the
-- descriptor shape and never a staged mesh.
local function titleModel(key)
  return {
    schema = ModelAsset.SCHEMA,
    key = key,
    kind = "nitro-dynamic",
    dynamic = { nodes = {}, transformProgram = {}, batches = {} },
    materials = {
      {
        id = 0,
        name = "wall",
        baseColor = { r = 255, g = 255, b = 255, a = 255 },
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
        colors = {
          diffuse = { r = 255, g = 255, b = 255 },
          ambient = { r = 255, g = 255, b = 255 },
          specular = { r = 255, g = 255, b = 255 },
          emission = { r = 0, g = 0, b = 0 },
        },
      },
    },
    animations = {},
  }
end

local function titleTrsClip(id)
  return {
    id = id,
    name = "titleMotion",
    category = "joint",
    kind = "trs",
    frameCount = 8,
    tracks = { { target = 0, targetIndex = 0 } },
    semanticNames = {},
    compiled = {
      anmFlags = 0,
      rotData = { { control = 0x0024, a = 4096, b = 0 } },
      pivotData = { { 4096, 0, 0, 0, 0 } },
      targets = {
        {
          nodeIndex = 0,
          channels = {
            trans = {
              x = { source = "model" },
              y = { source = "model" },
              z = { source = "model" },
            },
            rot = {
              source = "curve",
              rate = 1,
              limit = 8,
              storage = "fx16",
              keys = { 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000, 0x8000 },
            },
            scale = {
              x = { source = "model" },
              y = { source = "model" },
              z = { source = "model" },
            },
          },
        },
      },
    },
  }
end

local function titleTexsrtClip(id)
  return {
    id = id,
    name = "titleTex",
    category = "material",
    kind = "texsrt",
    frameCount = 4,
    tracks = { { target = "wall", targetIndex = 0 } },
    semanticNames = {},
    compiled = {
      targets = {
        {
          index = 0,
          name = "wall",
          channels = {
            transS = { source = "constant", value = 0 },
            transT = { source = "constant", value = 0 },
            rot = { source = "constant", value = 0x10000000 },
            scaleS = { source = "constant", value = 0x1000 },
            scaleT = { source = "constant", value = 0x1000 },
          },
        },
      },
    },
  }
end

local function titleColorClip(id)
  return {
    id = id,
    name = "titleColor",
    category = "material",
    kind = "color",
    frameCount = 4,
    tracks = { { target = "wall", targetIndex = 0 } },
    semanticNames = {},
    compiled = {
      targets = {
        {
          index = 0,
          name = "wall",
          channels = {
            diffuse = { source = "constant", value = 0x7FFF },
            ambient = { source = "constant", value = 0x4210 },
            specular = { source = "constant", value = 0 },
            emission = { source = "constant", value = 0x001F },
            alpha = { source = "constant", value = 31 },
          },
        },
      },
    },
  }
end

local function titlePatternClip(id)
  return {
    id = id,
    name = "titlePattern",
    category = "material",
    kind = "pattern",
    frameCount = 4,
    tracks = { { target = "wall", targetIndex = 0 } },
    semanticNames = {},
    compiled = {
      textureNames = { "titleTex" },
      paletteNames = {},
      targets = {
        {
          name = "wall",
          index = 0,
          rate = 1,
          keys = { { frame = 0, texIdx = 0, plttIdx = 0xFF } },
        },
      },
    },
  }
end

local function titlePromptTokens(text)
  local tokens = { { kind = "style", control = FieldMessageText.ALN_CENTER } }
  for index = 1, #text do
    tokens[#tokens + 1] = { kind = "glyph", text = text:sub(index, index) }
  end
  return tokens
end

local function titleSurface(image)
  return { image = image, width = 256, height = 192, sourceHash = string.rep("a", 40) }
end

-- A complete playable synthetic title: every structural check passes under
-- the current reader, so timing variations of this fixture isolate exactly
-- the reader's timing contract.
local function validTitleManifest()
  return {
    schema = StartupAssetContract.startupTitle.schema,
    versionId = "heartgold",
    generationId = "test-generation",
    kind = "animated-title",
    legendary = "ho-oh",
    crySpeciesId = 250,
    sequence = "SEQ_GS_POKEMON_THEME",
    menuSelectSequence = "SEQ_SE_DP_SELECT",
    model = titleModel("startup-title:test"),
    clips = {
      joint = titleTrsClip("startup-title:joint"),
      srt = titleTexsrtClip("startup-title:srt"),
      color = titleColorClip("startup-title:color"),
      pattern = titlePatternClip("startup-title:pattern"),
    },
    surfaces = {
      editionLogo = titleSurface("assets/generated/startup/title/edition-logo.png"),
      subscreenLower = titleSurface("assets/generated/startup/title/subscreen-lower.png"),
    },
    sparkle = {
      model = titleModel("startup-title:sparkle"),
      clips = {
        joint = titleTrsClip("startup-title:sparkle-joint"),
        pattern = titlePatternClip("startup-title:sparkle-pattern"),
      },
    },
    timeline = {
      camera = {
        start = { position = { 0, 65, 72 }, target = { 0, 90, 0 } },
        target = { -2, 124, -38 },
        endPosition = { 625, 152, 256 },
        points = {
          { position = { 180, 177, 301 }, durationSeconds = 10 },
          { position = { 335, -293, 296 }, durationSeconds = 5 },
          { position = { 180, 177, 301 }, durationSeconds = 5 },
          { position = { 625, 152, 256 }, durationSeconds = 10 },
        },
        movement = { unitsPerFrame = 5, tolerance = 1, waitFramesPerSecond = 30 },
      },
      animation = { startFrame = 0, framesPerUpdate = 1 },
      titleReveal = { delayFrames = 3, durationFrames = 32 },
      start = { initialDelayFrames = 30, activeDurationFrames = 2340 },
      glow = { fadeInSteps = 61, fadeOutSteps = 61, pauseFrames = 21, color = { 12, 12, 12 } },
      attachments = {
        model = { framesPerUpdate = 1, endFrame = "wrap-to-zero" },
        sparkle = { framesPerUpdate = 1, endFrame = "wrap-to-zero" },
      },
    },
    prompt = {
      text = "TOUCH TO START",
      alignment = "center",
      tokens = titlePromptTokens("TOUCH TO START"),
      color = {
        foreground = 1,
        shadow = 1,
        background = 0,
        foregroundRgb = { 27 / 31, 8 / 31, 0 },
        shadowRgb = { 27 / 31, 8 / 31, 0 },
      },
      flash = {
        initialDelayFrames = 30,
        initialPhaseFrame = 30,
        cycleFrames = 45,
        visibleFrames = 30,
        hiddenFrames = 15,
      },
    },
    projection = {
      nitroHalfAngleIndex = 0xB60,
      sourceAspect = { width = 4, height = 3 },
      sourceNear = 0,
      sourceFar = 0.5,
    },
    lighting = {
      records = {
        {
          endHalfSeconds = 43200,
          lights = {
            {
              enabled = true,
              colorRgb555 = 31 + 31 * 32 + 31 * 1024,
              color = { 1, 1, 1 },
              vectorFx12 = { 0, 4096, 0 },
              direction = { 0, 1, 0 },
            },
            {
              enabled = true,
              colorRgb555 = 31 + 31 * 32 + 31 * 1024,
              color = { 1, 1, 1 },
              vectorFx12 = { 0, 4096, 0 },
              direction = { 0, 1, 0 },
            },
            {
              enabled = false,
              colorRgb555 = 0,
              color = { 0, 0, 0 },
              vectorFx12 = { 0, 0, 0 },
              direction = { 0, 0, 0 },
            },
            {
              enabled = false,
              colorRgb555 = 0,
              color = { 0, 0, 0 },
              vectorFx12 = { 0, 0, 0 },
              direction = { 0, 0, 0 },
            },
          },
          diffuseRgb555 = 31 + 31 * 32 + 31 * 1024,
          ambientRgb555 = 10 + 10 * 32 + 10 * 1024,
          specularRgb555 = 0,
          emissionRgb555 = 0,
        },
      },
    },
  }
end

local function titleCacheFs(manifest, missingPath)
  return {
    loadLua = function()
      return manifest
    end,
    exists = function(_, path)
      return path ~= missingPath
    end,
  }
end

-- The generated title contract is structural and playable: corrected source
-- timing stays valid instead of freezing one sample of retail constants.
function T.title_reader_accepts_corrected_playable_timing()
  local baseline, baselineErr = StartupAssetCache.loadTitle(titleCacheFs(validTitleManifest(), nil), "heartgold")
  Assert.notNil(baseline, "the baseline playable title loads: " .. tostring(baselineErr))
  local varied = deepCopy(validTitleManifest())
  varied.timeline.camera.movement = { unitsPerFrame = 7, tolerance = 2, waitFramesPerSecond = 60 }
  varied.timeline.camera.points[1] = { position = { 181, 177, 301 }, durationSeconds = 12 }
  varied.timeline.camera.points[2].durationSeconds = 6
  varied.timeline.animation = { startFrame = 0, framesPerUpdate = 2 }
  varied.timeline.titleReveal = { delayFrames = 5, durationFrames = 40 }
  varied.timeline.start = { initialDelayFrames = 45, activeDurationFrames = 1200 }
  varied.timeline.glow = { fadeInSteps = 30, fadeOutSteps = 30, pauseFrames = 10, color = { 200, 100, 50 } }
  varied.timeline.attachments.model.framesPerUpdate = 2
  varied.timeline.attachments.sparkle.framesPerUpdate = 2
  varied.prompt.flash =
    { initialDelayFrames = 10, initialPhaseFrame = 5, cycleFrames = 60, visibleFrames = 40, hiddenFrames = 20 }
  local loaded, err = StartupAssetCache.loadTitle(titleCacheFs(varied, nil), "heartgold")
  Assert.notNil(loaded, "corrected playable timing stays valid: " .. tostring(err))
end

-- Relaxed timing never means relaxed structure: negative counts, missing
-- files, and mismatched prompt tokens stay invalid.
function T.title_reader_rejects_malformed_structure()
  local negative = deepCopy(validTitleManifest())
  negative.timeline.start.activeDurationFrames = -5
  local negativeLoaded, negativeErr = StartupAssetCache.loadTitle(titleCacheFs(negative, nil), "heartgold")
  Assert.isNil(negativeLoaded, "a negative frame count is not playable")
  Assert.notNil(negativeErr, "a negative frame count reports its cause")

  local missing = validTitleManifest()
  local missingImage = missing.surfaces.editionLogo.image
  local missingLoaded, missingErr = StartupAssetCache.loadTitle(titleCacheFs(missing, missingImage), "heartgold")
  Assert.isNil(missingLoaded, "a missing surface image is not a ready title")
  Assert.notNil(missingErr, "a missing surface image reports its cause")

  local mismatched = deepCopy(validTitleManifest())
  mismatched.prompt.tokens = titlePromptTokens("TOUCH TO BEGIN")
  local mismatchedLoaded, mismatchedErr = StartupAssetCache.loadTitle(titleCacheFs(mismatched, nil), "heartgold")
  Assert.isNil(mismatchedLoaded, "mismatched prompt tokens are not a ready title")
  Assert.notNil(mismatchedErr, "mismatched prompt tokens report their cause")
end

-- The title schema versions its shape: a pre-change bundle without the
-- source projection/lighting records, with the retired third surface, or
-- with unlit lighting is not a ready title.
function T.title_reader_rejects_pre_change_and_unlit_manifests()
  local stale = deepCopy(validTitleManifest())
  stale.schema = "g4-startup-title-v1"
  local staleLoaded, staleErr = StartupAssetCache.loadTitle(titleCacheFs(stale, nil), "heartgold")
  Assert.isNil(staleLoaded, "a pre-change title schema is not a ready title")
  Assert.notNil(staleErr, "a pre-change title schema reports its cause")

  local decorated = deepCopy(validTitleManifest())
  decorated.surfaces.subscreenDecor = titleSurface("assets/generated/startup/title/subscreen-decor.png")
  local decoratedLoaded, decoratedErr = StartupAssetCache.loadTitle(titleCacheFs(decorated, nil), "heartgold")
  Assert.isNil(decoratedLoaded, "a retired third title surface is not a ready title")
  Assert.notNil(decoratedErr, "a retired third title surface reports its cause")

  local unlit = deepCopy(validTitleManifest())
  unlit.lighting = nil
  local unlitLoaded, unlitErr = StartupAssetCache.loadTitle(titleCacheFs(unlit, nil), "heartgold")
  Assert.isNil(unlitLoaded, "a title without its lighting record is not a ready title")
  Assert.notNil(unlitErr, "a title without its lighting record reports its cause")

  local dark = deepCopy(validTitleManifest())
  for _, light in ipairs(dark.lighting.records[1].lights) do
    light.enabled = false
  end
  local darkLoaded, darkErr = StartupAssetCache.loadTitle(titleCacheFs(dark, nil), "heartgold")
  Assert.isNil(darkLoaded, "a title with no enabled light is not a ready title")
  Assert.notNil(darkErr, "a title with no enabled light reports its cause")

  local flat = deepCopy(validTitleManifest())
  flat.projection = nil
  local flatLoaded, flatErr = StartupAssetCache.loadTitle(titleCacheFs(flat, nil), "heartgold")
  Assert.isNil(flatLoaded, "a title without its source projection is not a ready title")
  Assert.notNil(flatErr, "a title without its source projection reports its cause")
end

-- The start-prompt ink is the edition retail text palette, not an
-- interchangeable tint: HeartGold RGB(27, 8, 0) and SoulSilver
-- RGB(0, 28, 31) as 0..1 floats, with the shadow pass reusing the
-- foreground ink.
function T.title_reader_pins_the_edition_prompt_palette()
  local manifest = validTitleManifest()
  Assert.near(manifest.prompt.color.foregroundRgb[1], 27 / 31, 1e-9, "heartgold prompt red is the retail ink")
  Assert.near(manifest.prompt.color.foregroundRgb[2], 8 / 31, 1e-9, "heartgold prompt green is the retail ink")
  Assert.near(manifest.prompt.color.foregroundRgb[3], 0, 1e-9, "heartgold prompt blue is the retail ink")
  Assert.deepEqual(
    manifest.prompt.color.shadowRgb,
    manifest.prompt.color.foregroundRgb,
    "the shadow pass reuses the foreground ink"
  )
  local baseline, baselineErr = StartupAssetCache.loadTitle(titleCacheFs(deepCopy(manifest), nil), "heartgold")
  Assert.notNil(baseline, "the edition prompt ink loads: " .. tostring(baselineErr))

  local swapped = deepCopy(manifest)
  swapped.prompt.color.foregroundRgb = { 0, 28 / 31, 1 }
  swapped.prompt.color.shadowRgb = { 0, 28 / 31, 1 }
  local swappedLoaded, swappedErr = StartupAssetCache.loadTitle(titleCacheFs(swapped, nil), "heartgold")
  Assert.isNil(swappedLoaded, "the other edition prompt ink is not a ready heartgold title")
  Assert.notNil(swappedErr, "the other edition prompt ink reports its cause")

  local missing = deepCopy(manifest)
  missing.prompt.color.foregroundRgb = nil
  missing.prompt.color.shadowRgb = nil
  local missingLoaded, missingErr = StartupAssetCache.loadTitle(titleCacheFs(missing, nil), "heartgold")
  Assert.isNil(missingLoaded, "a title without its prompt ink is not a ready title")
  Assert.notNil(missingErr, "a title without its prompt ink reports its cause")
end

-- One selected walking pair is a canonical 32-way choice: indices 1..16
-- name Ethan with each of the sixteen followers in fixed order, 17..32
-- name Lyra with the same order, and the inverse maps back exactly.
function T.startup_pair_choice_covers_both_heroes_and_sixteen_followers()
  Assert.isTrue(
    type(StartupAssetCache.walkerChoice) == "function",
    "the startup cache owns the canonical 32-choice pair map"
  )
  Assert.isTrue(type(StartupAssetCache.walkerIndex) == "function", "the startup cache inverts the 32-choice pair map")
  local species = { 1, 4, 7, 152, 155, 158, 252, 255, 258, 387, 390, 393, 133, 25, 143, 183 }
  for index = 1, 32 do
    local choice = StartupAssetCache.walkerChoice(index)
    local ordinal = (index - 1) % 16 + 1
    local heroId = index <= 16 and "ethan" or "lyra"
    Assert.equal(choice.heroId, heroId, "pair " .. index .. " names its hero")
    Assert.equal(choice.followerSpeciesId, species[ordinal], "pair " .. index .. " names its follower species")
    Assert.equal(
      StartupAssetCache.walkerIndex(choice.heroId, choice.followerSpeciesId),
      index,
      "pair " .. index .. " round-trips through the inverse map"
    )
  end
  for _, badIndex in ipairs({ 0, 33, 1.5, "1" }) do
    local ok, _ = pcall(StartupAssetCache.walkerChoice, badIndex)
    Assert.isFalse(ok, "pair index " .. tostring(badIndex) .. " is rejected")
  end
  local unknownOk, _ = pcall(StartupAssetCache.walkerIndex, "ethan", 999999)
  Assert.isFalse(unknownOk, "an unknown follower species inverts to no pair")
  local heroOk, _ = pcall(StartupAssetCache.walkerIndex, "red", 1)
  Assert.isFalse(heroOk, "an unknown hero inverts to no pair")
end

local function startupPairVisual(frameWidth, frameHeight)
  return {
    render = { kind = "atlas", frameWidth = frameWidth, frameHeight = frameHeight, frameCount = 2 },
    pivot = { x = 0.5, y = 1 },
    directions = {
      east = {
        walk = {
          frames = {
            { frameIndex = 1, ticks = 1 },
            { frameIndex = 2, ticks = 3 },
          },
        },
      },
    },
  }
end

local function startupPairManifest(pairIndex, versionId)
  return {
    schema = "g4-startup-walker-v1",
    versionId = versionId,
    generationId = "generation-a",
    pairIndex = pairIndex,
    hero = {
      atlasPath = "assets/generated/startup/loader/pairs/" .. pairIndex .. "/hero.png",
      visual = startupPairVisual(16, 24),
    },
    follower = {
      speciesId = 25,
      atlasPath = "assets/generated/startup/loader/pairs/" .. pairIndex .. "/follower.png",
      visual = startupPairVisual(12, 20),
    },
  }
end

-- Keyed pair readiness is isolated per selection: numeric pair keys address
-- their own receipt and manifest roots, the legacy global key addresses
-- nothing, and only the manifest matching the requested pair validates.
function T.startup_pair_receipts_are_keyed_and_isolated()
  Assert.equal(ArtifactState.path("startup-loader", "1"), "data/generated/jobs/startup-loader/1.lua")
  Assert.equal(ArtifactState.path("startup-loader", "32"), "data/generated/jobs/startup-loader/32.lua")
  Assert.isFalse(
    pcall(ArtifactState.path, "startup-loader", "global"),
    "the legacy global key no longer addresses a walking pair"
  )
  Assert.isFalse(pcall(ArtifactState.path, "startup-loader", "0"), "pair keys start at one")
  Assert.isFalse(pcall(ArtifactState.path, "startup-loader", "33"), "pair keys end at thirty-two")
  Assert.isTrue(type(StartupAssetCache.walkerPath) == "function", "the startup cache owns the per-pair manifest path")
  Assert.equal(StartupAssetCache.walkerPath(5), "data/generated/startup/loader/pairs/5.lua")
  Assert.isTrue(type(StartupAssetCache.loadWalker) == "function", "the startup cache reads one strict pair manifest")
  local manifest = startupPairManifest(5, "heartgold")
  local cacheFs = {
    loadLua = function()
      return manifest
    end,
    exists = function()
      return true
    end,
  }
  local loaded, loadErr = StartupAssetCache.loadWalker(cacheFs, 5)
  Assert.notNil(loaded, "the strict pair manifest loads: " .. tostring(loadErr))
  Assert.equal(loaded.pairIndex, 5, "the loaded pair carries its selection")
  Assert.equal(loaded.follower.speciesId, 25, "the loaded pair names its follower species")
  local wrongPair, wrongErr = StartupAssetCache.loadWalker(cacheFs, 6)
  Assert.isNil(wrongPair, "a manifest for another pair never authorizes this pair")
  Assert.notNil(wrongErr, "the wrong-pair manifest reports its cause")
  local missingFs = {
    loadLua = function()
      return manifest
    end,
    exists = function()
      return false
    end,
  }
  local missing, missingErr = StartupAssetCache.loadWalker(missingFs, 5)
  Assert.isNil(missing, "a pair with missing atlas files is not ready")
  Assert.notNil(missingErr, "the missing atlas reports its cause")
  local legacyFs = {
    loadLua = function()
      return { schema = StartupAssetContract.startupLoader.schema, versionId = "heartgold" }
    end,
    exists = function()
      return true
    end,
  }
  local legacy, legacyErr = StartupAssetCache.loadWalker(legacyFs, 5)
  Assert.isNil(legacy, "the legacy global manifest never reads as a pair")
  Assert.notNil(legacyErr, "the legacy manifest reports its cause")
end

-- The pair reader rejects invalid selections, stale editions, and pivot or
-- clip defects without touching the cache.
function T.startup_pair_reader_rejects_invalid_selection_and_defects()
  for _, badIndex in ipairs({ 0, 33, 1.5, "5" }) do
    Assert.isFalse(pcall(StartupAssetCache.loadWalker, {}, badIndex), "pair " .. tostring(badIndex) .. " is rejected")
    Assert.isFalse(pcall(StartupAssetCache.walkerPath, badIndex), "pair path " .. tostring(badIndex) .. " is rejected")
  end
  local manifest = startupPairManifest(5, "heartgold")
  local badPivot = startupPairManifest(5, "heartgold")
  badPivot.hero.visual.pivot = { x = 0, y = 0 }
  local pivotFs = {
    loadLua = function()
      return badPivot
    end,
    exists = function()
      return true
    end,
  }
  local rejected, rejectErr = StartupAssetCache.loadWalker(pivotFs, 5)
  Assert.isNil(rejected, "a manifest without the source bottom-center pivot is rejected")
  Assert.notNil(rejectErr, "the pivot defect reports its cause")
end

-- Staging one pair never touches its siblings: the writer owns only its
-- manifest and pair directory, and no staged file escapes its pair root.
function T.startup_pair_writer_preserves_sibling_pairs()
  local StartupCacheWriter = require("romdump.src.digest.startup.StartupCacheWriter")
  local function stagePairWrites(pairIndex)
    local writes, roots = {}, {}
    local stage = {
      write = function(_, path, bytes)
        writes[#writes + 1] = { path = path, bytes = bytes }
      end,
      writeLua = function(_, path, record)
        writes[#writes + 1] = { path = path, record = record }
      end,
      loadLua = function(_, path)
        for _, write in ipairs(writes) do
          if write.path == path then
            return write.record
          end
        end
      end,
      exists = function(_, path, kind)
        for _, write in ipairs(writes) do
          if write.path == path then
            return true
          end
        end
        return false
      end,
    }
    local artifact = {
      stageFs = function()
        return stage
      end,
      addOwnedRoot = function(_, path)
        roots[#roots + 1] = path
      end,
    }
    local pixels = string.char(200, 180, 120, 255) .. string.char(0, 0, 0, 0)
    local bundle = {
      manifest = {
        schema = "g4-startup-walker-v1",
        versionId = "heartgold",
        pairIndex = pairIndex,
        hero = {
          atlasPath = "assets/generated/startup/loader/pairs/" .. pairIndex .. "/hero.png",
          visual = startupPairVisual(1, 1),
        },
        follower = {
          speciesId = 25,
          atlasPath = "assets/generated/startup/loader/pairs/" .. pairIndex .. "/follower.png",
          visual = startupPairVisual(1, 1),
        },
      },
      atlases = {
        ["assets/generated/startup/loader/pairs/" .. pairIndex .. "/hero.png"] = {
          width = 2,
          height = 1,
          pixels = pixels,
        },
        ["assets/generated/startup/loader/pairs/" .. pairIndex .. "/follower.png"] = {
          width = 2,
          height = 1,
          pixels = pixels,
        },
      },
      dependencies = { versionId = "heartgold" },
    }
    Assert.isTrue(pcall(StartupCacheWriter.stageLoader, artifact, bundle, "generation-a", pairIndex))
    return writes, roots
  end
  local writes5, roots5 = stagePairWrites(5)
  local writes6, roots6 = stagePairWrites(6)
  for _, write in ipairs(writes5) do
    Assert.isNil(write.path:find("pairs/6", 1, true), "staging pair 5 never writes sibling pair 6 files")
  end
  for _, write in ipairs(writes6) do
    Assert.isNil(write.path:find("pairs/5", 1, true), "staging pair 6 never writes sibling pair 5 files")
  end
  local rootSet5 = {}
  for _, root in ipairs(roots5) do
    rootSet5[root] = true
  end
  Assert.isTrue(rootSet5["data/generated/startup/loader/pairs/5.lua"], "pair 5 owns its manifest")
  Assert.isTrue(rootSet5["assets/generated/startup/loader/pairs/5"], "pair 5 owns its directory")
  Assert.isNil(rootSet5["data/generated/startup/loader/pairs/6.lua"], "pair 5 never owns its sibling manifest")
  Assert.isNil(rootSet5["assets/generated/startup/loader"], "pair 5 never owns the shared loader root")
  Assert.isTrue(
    StartupAssetCache.walkerPath(5) ~= StartupAssetCache.walkerPath(6),
    "sibling pairs address distinct manifests"
  )
  Assert.isTrue(
    ArtifactState.path("startup-loader", "5") ~= ArtifactState.path("startup-loader", "6"),
    "sibling pairs address distinct receipts"
  )
end

-- An atlas without transparent pixels is malformed: the writer fails the
-- stage instead of publishing an opaque square.
function T.startup_pair_writer_rejects_opaque_atlases()
  local StartupCacheWriter = require("romdump.src.digest.startup.StartupCacheWriter")
  local writes = {}
  local stage = {
    write = function(_, path, bytes)
      writes[#writes + 1] = { path = path, bytes = bytes }
    end,
    writeLua = function(_, path, record)
      writes[#writes + 1] = { path = path, record = record }
    end,
    loadLua = function(_, path)
      for _, write in ipairs(writes) do
        if write.path == path then
          return write.record
        end
      end
    end,
    exists = function(_, path, kind)
      for _, write in ipairs(writes) do
        if write.path == path then
          return true
        end
      end
      return false
    end,
  }
  local artifact = {
    stageFs = function()
      return stage
    end,
    addOwnedRoot = function() end,
  }
  local opaque = string.rep(string.char(200, 180, 120, 255), 2)
  local bundle = {
    manifest = {
      schema = "g4-startup-walker-v1",
      versionId = "heartgold",
      pairIndex = 5,
      hero = {
        atlasPath = "assets/generated/startup/loader/pairs/5/hero.png",
        visual = startupPairVisual(1, 1),
      },
      follower = {
        speciesId = 25,
        atlasPath = "assets/generated/startup/loader/pairs/5/follower.png",
        visual = startupPairVisual(1, 1),
      },
    },
    atlases = {
      ["assets/generated/startup/loader/pairs/5/hero.png"] = { width = 2, height = 1, pixels = opaque },
      ["assets/generated/startup/loader/pairs/5/follower.png"] = { width = 2, height = 1, pixels = opaque },
    },
    dependencies = { versionId = "heartgold" },
  }
  Assert.isFalse(pcall(StartupCacheWriter.stageLoader, artifact, bundle, "generation-a", 5))
end

-- The five opening-movie scenes form one closed numeric family beside the
-- walking pair and title scopes: each scene addresses its own receipt and
-- manifest, and no other key shape is routable.
function T.opening_scene_family_is_a_closed_numeric_kind()
  Assert.isTrue(
    type(StartupAssetCache.openingScenePath) == "function",
    "the startup cache addresses one opening scene manifest per scene"
  )
  for sceneNumber = 1, 5 do
    Assert.equal(
      StartupAssetCache.openingScenePath(sceneNumber),
      "data/generated/startup/opening/" .. tostring(sceneNumber) .. ".lua",
      "scene " .. sceneNumber .. " owns its versioned manifest path"
    )
  end
  for _, badScene in ipairs({ 0, 6, 1.5, "1", "global" }) do
    Assert.isFalse(
      pcall(StartupAssetCache.openingScenePath, badScene),
      "scene " .. tostring(badScene) .. " addresses no opening manifest"
    )
  end
end

-- The previous generation-three record stays frozen as the legacy fixture
-- below: the strict reader never validates it as current. New and migrated
-- fixtures build on the current contract instead.
local OPENING_SCHEMA = "g4-startup-opening-scene-v3"

local CURRENT_OPENING_SCHEMA = "g4-startup-opening-scene-v4"

local function openingLayer(engine, bgSlot, image)
  return {
    bgSlot = bgSlot,
    priority = bgSlot,
    image = image,
    variants = {},
    width = 256,
    height = 192,
    sourceHash = string.rep("a", 40),
    initialVisible = true,
  }
end

local function openingClip(root, name)
  return {
    id = root .. "/sprites/" .. name .. ".png",
    bank = "synthetic",
    sequence = 0,
    frameCount = 2,
    frames = {
      { x = 0, y = 0, width = 8, height = 8, offsetX = 0, offsetY = 0, duration = 4 },
      { x = 8, y = 0, width = 8, height = 8, offsetX = 1, offsetY = 0, duration = 4 },
    },
  }
end

local function openingEvents(sceneNumber, root)
  local clip = root .. "/sprites/clip0.png"
  if sceneNumber == 1 then
    return {
      { op = "setScreenMapping", stepId = "copyright", atStepTick = 0, mainPhysical = "lower" },
      {
        op = "setLayer",
        stepId = "copyright",
        atStepTick = 0,
        engine = "main",
        bgSlot = 0,
        image = root .. "/main-bg.png",
        visible = true,
        priority = 0,
      },
      {
        op = "setLayer",
        stepId = "copyright",
        atStepTick = 0,
        engine = "sub",
        bgSlot = 0,
        image = root .. "/sub-bg.png",
        visible = true,
        priority = 0,
      },
      { op = "setBlend", stepId = "fades", atStepTick = 0, effect = "blend-copyright", ticks = 60, from = 32, to = 31 },
      { op = "waitTicks", stepId = "setup", atStepTick = 0, ticks = 20 },
      { op = "enableSkip", stepId = "setup", atStepTick = 20 },
      { op = "waitTicks", stepId = "logo", atStepTick = 0, ticks = 110 },
      {
        op = "setSpriteClip",
        stepId = "logo",
        atStepTick = 0,
        instanceId = "hero",
        engine = "main",
        x = 128,
        y = 96,
        drawOrder = 1,
        clipId = clip,
      },
      {
        op = "spriteVisible",
        stepId = "logo",
        atStepTick = 0,
        instanceId = "hero",
        engine = "main",
        x = 128,
        y = 96,
        drawOrder = 1,
        visible = true,
      },
      { op = "finish", stepId = "logo", atStepTick = 110 },
    }
  elseif sceneNumber == 5 then
    return {
      { op = "setScreenMapping", stepId = "wipe", atStepTick = 0, mainPhysical = "lower" },
      { op = "circleWipe", stepId = "wipe", atStepTick = 0, mode = "in", ticks = 18, effect = "wipe-in" },
      { op = "waitEffects", stepId = "scroll", atStepTick = 0, effects = { "wipe-in" } },
      {
        op = "setScroll",
        stepId = "scroll",
        atStepTick = 0,
        engine = "main",
        bgSlot = 1,
        dx = 0,
        dy = -64,
        ticks = 73,
        direction = "up",
      },
      { op = "waitTicks", stepId = "wait", atStepTick = 0, ticks = 20 },
      { op = "setFade", stepId = "fade", atStepTick = 0, kind = "white", ticks = 50, effect = "fade-white" },
      { op = "waitEffects", stepId = "fade", atStepTick = 0, effects = { "fade-white" } },
      { op = "finish", stepId = "fade", atStepTick = 0 },
    }
  end
  return {
    { op = "setScreenMapping", stepId = "open", atStepTick = 0, mainPhysical = "upper" },
    {
      op = "setLayer",
      stepId = "open",
      atStepTick = 0,
      engine = "main",
      bgSlot = 0,
      image = root .. "/main-bg.png",
      visible = true,
      priority = 0,
    },
    { op = "finish", stepId = "open", atStepTick = 10 },
  }
end

local function openingSteps(sceneNumber)
  if sceneNumber == 1 then
    return {
      { id = "copyright", events = { 1, 2, 3 }, ["until"] = { kind = "duration", ticks = 30 } },
      { id = "fades", events = { 4 }, ["until"] = { kind = "effect", effect = "blend-copyright" } },
      { id = "setup", events = { 5, 6 }, ["until"] = { kind = "duration", ticks = 20 } },
      { id = "logo", events = { 7, 8, 9, 10 }, ["until"] = { kind = "duration", ticks = 110 } },
    }
  elseif sceneNumber == 5 then
    return {
      { id = "wipe", events = { 1, 2 }, ["until"] = { kind = "duration", ticks = 18 } },
      { id = "scroll", events = { 3, 4 }, ["until"] = { kind = "duration", ticks = 73 } },
      { id = "wait", events = { 5 }, ["until"] = { kind = "duration", ticks = 20 } },
      { id = "fade", events = { 6, 7, 8 }, ["until"] = { kind = "effect", effect = "fade-white" } },
    }
  end
  return { { id = "open", events = { 1, 2, 3 }, ["until"] = { kind = "duration", ticks = 10 } } }
end

local function validOpeningManifest(sceneNumber, versionId)
  local root = "assets/generated/startup/opening/" .. tostring(sceneNumber)
  local manifest = {
    schema = OPENING_SCHEMA,
    versionId = versionId,
    generationId = "test-generation",
    sceneNumber = sceneNumber,
    sourceTickRate = 30,
    layers = {
      main = { openingLayer("main", 0, root .. "/main-bg.png") },
      sub = { openingLayer("sub", 0, root .. "/sub-bg.png") },
    },
    spriteClips = { openingClip(root, "clip0") },
    models = {},
    particles = { seed = 0, emitters = {} },
    timeline = { steps = openingSteps(sceneNumber), events = openingEvents(sceneNumber, root) },
    assets = {
      [root .. "/main-bg.png"] = true,
      [root .. "/sub-bg.png"] = true,
      [root .. "/sprites/clip0.png"] = true,
    },
  }
  if sceneNumber == 4 then
    manifest.particles = {
      seed = 0,
      emitters = {
        { id = 0, group = "water" },
        { id = 1, group = "water" },
        { id = 2, group = "water" },
        { id = 3, group = "fire" },
        { id = 4, group = "fire" },
        { id = 5, group = "fire" },
        { id = 6, group = "grass" },
        { id = 7, group = "grass" },
        { id = 8, group = "grass" },
      },
    }
  end
  return manifest
end

-- A complete synthetic opening scene in the current shape: the legacy
-- record above only covers the retired grammar, so current-contract checks
-- build from it and repair the blend and wipe operands that changed.
local function validCurrentOpeningManifest(sceneNumber, versionId)
  local manifest = validOpeningManifest(sceneNumber, versionId)
  manifest.schema = CURRENT_OPENING_SCHEMA
  if sceneNumber == 1 then
    manifest.timeline.events[4] = {
      op = "setBlend",
      stepId = "fades",
      atStepTick = 0,
      engine = "main",
      firstMask = 1,
      secondMask = 32,
      direction = 1,
      ticks = 60,
      effect = "blend-copyright",
    }
  elseif sceneNumber == 5 then
    manifest.timeline.events[2] = {
      op = "circleWipe",
      stepId = "wipe",
      atStepTick = 0,
      engine = "main",
      kind = 0,
      ticks = 18,
      effect = "wipe-in",
    }
    manifest.timeline.events[4].direction = nil
  end
  return manifest
end

local function openingCacheFs(manifest, missingPath)
  return {
    loadLua = function()
      return manifest
    end,
    exists = function(_, path)
      return path ~= missingPath
    end,
  }
end

-- A complete synthetic opening scene reads ready: its schema, edition,
-- scene key, frame rate, closed event grammar, and referenced files all
-- validate under the current reader.
function T.opening_scene_reader_loads_a_complete_synthetic_bundle()
  Assert.isTrue(
    type(StartupAssetCache.loadOpeningScene) == "function",
    "the startup cache reads one strict opening scene bundle"
  )
  for sceneNumber = 1, 5 do
    local manifest = validCurrentOpeningManifest(sceneNumber, "heartgold")
    local loaded, err = StartupAssetCache.loadOpeningScene(openingCacheFs(manifest, nil), sceneNumber, "heartgold")
    Assert.notNil(loaded, "scene " .. sceneNumber .. " reads ready: " .. tostring(err))
    Assert.equal(loaded.sceneNumber, sceneNumber, "scene " .. sceneNumber .. " reads back under its own key")
  end
end

-- The reader rejects stale editions, wrong scenes, missing files, broken
-- grammar, source identity leakage, and unsupported particle records
-- without touching the cache.
function T.opening_scene_reader_rejects_mismatched_and_malformed_bundles()
  Assert.isTrue(
    type(StartupAssetCache.loadOpeningScene) == "function",
    "the startup cache reads one strict opening scene bundle"
  )
  local manifest = validCurrentOpeningManifest(4, "heartgold")
  for _, badScene in ipairs({ 0, 6, 1.5, "4" }) do
    Assert.isFalse(
      pcall(StartupAssetCache.loadOpeningScene, openingCacheFs(manifest, nil), badScene, "heartgold"),
      "scene " .. tostring(badScene) .. " is rejected"
    )
  end
  local wrongScene, wrongSceneErr = StartupAssetCache.loadOpeningScene(openingCacheFs(manifest, nil), 2, "heartgold")
  Assert.isNil(wrongScene, "a manifest for another scene never authorizes this scene")
  Assert.notNil(wrongSceneErr, "the wrong-scene manifest reports its cause")
  local staleEdition, staleEditionErr =
    StartupAssetCache.loadOpeningScene(openingCacheFs(manifest, nil), 4, "soulsilver")
  Assert.isNil(staleEdition, "one edition manifest never reads as the other edition")
  Assert.notNil(staleEditionErr, "the stale edition reports its cause")
  local missingImage = manifest.layers.main[1].image
  local missing, missingErr = StartupAssetCache.loadOpeningScene(openingCacheFs(manifest, missingImage), 4, "heartgold")
  Assert.isNil(missing, "a scene with missing layer art is not ready")
  Assert.notNil(missingErr, "the missing art reports its cause")
  local badOp = deepCopy(manifest)
  badOp.timeline.events[1].op = "launchFireworks"
  local rejectedOp, rejectedOpErr = StartupAssetCache.loadOpeningScene(openingCacheFs(badOp, nil), 4, "heartgold")
  Assert.isNil(rejectedOp, "an event outside the closed movie grammar is rejected")
  Assert.notNil(rejectedOpErr, "the unknown op reports its cause")
  local badOperand = deepCopy(manifest)
  badOperand.timeline.events[1].atStepTick = -1
  local rejectedOperand, rejectedOperandErr =
    StartupAssetCache.loadOpeningScene(openingCacheFs(badOperand, nil), 4, "heartgold")
  Assert.isNil(rejectedOperand, "a negative source tick is rejected")
  Assert.notNil(rejectedOperandErr, "the bad operand reports its cause")
  local leakedSource = deepCopy(manifest)
  leakedSource.memberId = 25
  local leaked, leakedErr = StartupAssetCache.loadOpeningScene(openingCacheFs(leakedSource, nil), 4, "heartgold")
  Assert.isNil(leaked, "source member identity cannot cross into the runtime manifest")
  Assert.notNil(leakedErr, "the leaked source identity reports its cause")
  local badEmitter = deepCopy(manifest)
  badEmitter.particles.emitters[1] = { id = 9, group = "water" }
  local rejectedEmitter, rejectedEmitterErr =
    StartupAssetCache.loadOpeningScene(openingCacheFs(badEmitter, nil), 4, "heartgold")
  Assert.isNil(rejectedEmitter, "an emitter outside the nine source emitters is rejected")
  Assert.notNil(rejectedEmitterErr, "the unsupported emitter reports its cause")
  local escapedRoot = deepCopy(manifest)
  escapedRoot.layers.main[1].image = "assets/generated/startup/opening/2/main-bg.png"
  local escaped, escapedErr = StartupAssetCache.loadOpeningScene(openingCacheFs(escapedRoot, nil), 4, "heartgold")
  Assert.isNil(escaped, "a scene never references a sibling scene asset root")
  Assert.notNil(escapedErr, "the escaped asset root reports its cause")
end

-- The strict reader breaks the legacy record instead of aliasing it, and it
-- binds every effect wait, clip reference, screen mapping, and clock to the
-- closed step-clocked grammar.
function T.opening_scene_reader_enforces_the_strict_versioned_contract()
  Assert.isTrue(
    type(StartupAssetCache.loadOpeningScene) == "function",
    "the startup cache reads one strict opening scene bundle"
  )
  local manifest = validCurrentOpeningManifest(1, "heartgold")
  local stale = deepCopy(manifest)
  stale.schema = "g4-startup-opening-scene-v1"
  local staleRead, staleErr = StartupAssetCache.loadOpeningScene(openingCacheFs(stale, nil), 1, "heartgold")
  Assert.isNil(staleRead, "a legacy scene record never validates")
  Assert.notNil(staleErr, "the stale schema reports its cause")
  local unstarted = deepCopy(manifest)
  unstarted.timeline.events[1] = {
    op = "waitEffects",
    stepId = "copyright",
    atStepTick = 0,
    effects = { "no-such-effect" },
  }
  local badWait, badWaitErr = StartupAssetCache.loadOpeningScene(openingCacheFs(unstarted, nil), 1, "heartgold")
  Assert.isNil(badWait, "an effect wait on nothing started never validates")
  Assert.notNil(badWaitErr, "the unstarted wait reports its cause")
  local unknownClip = deepCopy(manifest)
  for _, event in ipairs(unknownClip.timeline.events) do
    if event.op == "setSpriteClip" then
      event.clipId = "assets/generated/startup/opening/1/sprites/ghost.png"
    end
  end
  local badClip, badClipErr = StartupAssetCache.loadOpeningScene(openingCacheFs(unknownClip, nil), 1, "heartgold")
  Assert.isNil(badClip, "a sprite event pointing outside the compiled clips never validates")
  Assert.notNil(badClipErr, "the unknown clip reports its cause")
  local parallelClock = deepCopy(manifest)
  parallelClock.timeline.events[1].atTick = 0
  local badClock, badClockErr = StartupAssetCache.loadOpeningScene(openingCacheFs(parallelClock, nil), 1, "heartgold")
  Assert.isNil(badClock, "a parallel global clock never validates")
  Assert.notNil(badClockErr, "the parallel clock reports its cause")
  local retiredRoles = deepCopy(manifest)
  retiredRoles.timeline.events[1] =
    { op = "setScreenRoles", stepId = "copyright", atStepTick = 0, upper = "main", lower = "sub" }
  local badRoles, badRolesErr = StartupAssetCache.loadOpeningScene(openingCacheFs(retiredRoles, nil), 1, "heartgold")
  Assert.isNil(badRoles, "the retired engine-role event never validates")
  Assert.notNil(badRolesErr, "the retired screen roles report their cause")
  local badMapping = deepCopy(manifest)
  badMapping.timeline.events[1].mainPhysical = "sideways"
  local badRole, badRoleErr = StartupAssetCache.loadOpeningScene(openingCacheFs(badMapping, nil), 1, "heartgold")
  Assert.isNil(badRole, "a scene with a bad physical role never validates")
  Assert.notNil(badRoleErr, "the bad physical role reports its cause")
end

-- Staging one opening scene owns only its manifest and scene directory,
-- stages the manifest last, and never touches a sibling scene.
function T.opening_scene_writer_preserves_sibling_scenes()
  local ok, OpeningMovieCacheWriter = pcall(require, "romdump.src.digest.startup.OpeningMovieCacheWriter")
  Assert.isTrue(
    ok and type(OpeningMovieCacheWriter.stageScene) == "function",
    "the opening scene writer stages one numbered scene"
  )
  local function stageSceneWrites(sceneNumber)
    local writes, roots = {}, {}
    local stage = {
      write = function(_, path, bytes)
        writes[#writes + 1] = { path = path, bytes = bytes }
      end,
      writeLua = function(_, path, record)
        writes[#writes + 1] = { path = path, record = record }
      end,
      loadLua = function(_, path)
        for _, write in ipairs(writes) do
          if write.path == path then
            return write.record
          end
        end
      end,
      exists = function(_, path)
        for _, write in ipairs(writes) do
          if write.path == path then
            return true
          end
        end
        return false
      end,
    }
    local artifact = {
      stageFs = function()
        return stage
      end,
      addOwnedRoot = function(_, path)
        roots[#roots + 1] = path
      end,
    }
    local root = "assets/generated/startup/opening/" .. tostring(sceneNumber)
    local manifest = validCurrentOpeningManifest(sceneNumber, "heartgold")
    local bundle = {
      manifest = manifest,
      files = {
        [root .. "/main-bg.png"] = "main",
        [root .. "/sub-bg.png"] = "sub",
        [root .. "/sprites/clip0.png"] = "clip",
      },
      dependencies = { versionId = "heartgold" },
    }
    Assert.isTrue(pcall(OpeningMovieCacheWriter.stageScene, artifact, bundle, "generation-a", sceneNumber))
    return writes, roots
  end
  local writes2, roots2 = stageSceneWrites(2)
  local writes4 = stageSceneWrites(4)
  for _, write in ipairs(writes2) do
    Assert.isNil(write.path:find("/opening/4/", 1, true), "staging scene 2 never writes sibling scene 4 files")
  end
  for _, write in ipairs(writes4) do
    Assert.isNil(write.path:find("/opening/2/", 1, true), "staging scene 4 never writes sibling scene 2 files")
  end
  local rootSet = {}
  for _, root in ipairs(roots2) do
    rootSet[root] = true
  end
  Assert.isTrue(rootSet["data/generated/startup/opening/2.lua"], "scene 2 owns its manifest")
  Assert.isTrue(rootSet["assets/generated/startup/opening/2"], "scene 2 owns its directory")
  Assert.isNil(rootSet["data/generated/startup/opening/4.lua"], "scene 2 never owns its sibling manifest")
  Assert.isNil(rootSet["assets/generated/startup/opening"], "scene 2 never owns the shared opening root")
  Assert.equal(writes2[#writes2].path, StartupAssetCache.openingScenePath(2), "scene 2 stages its manifest last")
end

-- A failed scene stage preserves its previous good output: the live
-- manifest, receipt, and sibling scenes stay intact.
function T.opening_scene_staged_failure_keeps_the_previous_live_output()
  local ok, OpeningMovieCacheWriter = pcall(require, "romdump.src.digest.startup.OpeningMovieCacheWriter")
  Assert.isTrue(
    ok and type(OpeningMovieCacheWriter.stageScene) == "function",
    "the opening scene writer stages one numbered scene"
  )
  local backend = FakeCache.new()
  local cacheFs = CacheFs.forVersion("heartgold", backend)
  local goodGeneration = "previous-generation"
  local function seedScene(sceneNumber)
    local root = "assets/generated/startup/opening/" .. tostring(sceneNumber)
    cacheFs:write(root .. "/main-bg.png", "previous art")
    cacheFs:write(root .. "/sub-bg.png", "previous art")
    cacheFs:write(root .. "/sprites/clip0.png", "previous clip")
    cacheFs:writeLua(StartupAssetCache.openingScenePath(sceneNumber), {
      schema = OPENING_SCHEMA,
      generationId = goodGeneration,
      sceneNumber = sceneNumber,
    })
    cacheFs:writeLua(ArtifactState.path("opening-scene", tostring(sceneNumber)), {
      generationId = goodGeneration,
      marker = "previous",
    })
  end
  seedScene(4)
  seedScene(2)
  local manifestPath = StartupAssetCache.openingScenePath(4)
  local receiptPath = ArtifactState.path("opening-scene", "4")
  local originalWrite = backend.write
  local stagedWrites = 0
  backend.write = function(self, path, bytes)
    stagedWrites = stagedWrites + 1
    if stagedWrites == 2 then
      error("injected opening scene staged write failure", 0)
    end
    return originalWrite(self, path, bytes)
  end
  local root = "assets/generated/startup/opening/4"
  local bundle = {
    manifest = validCurrentOpeningManifest(4, "heartgold"),
    files = {
      [root .. "/main-bg.png"] = "first",
      [root .. "/sub-bg.png"] = "second",
      [root .. "/sprites/clip0.png"] = "third",
    },
  }
  local artifact = PreparedArtifact.new({
    cacheFs = cacheFs,
    generationId = "current-generation",
    epoch = 1,
    kind = "opening-scene",
    key = "4",
    jobKey = "opening-scene:4",
    stageName = "opening-scene-4-failure",
  })
  local stageOk, failure = pcall(OpeningMovieCacheWriter.stageScene, artifact, bundle, "current-generation", 4)
  backend.write = originalWrite
  Assert.isFalse(stageOk, "the injected staged failure fails the scene 4 restage: " .. tostring(failure))
  Assert.isFalse(artifact:stageFs():exists(manifestPath, "file"), "a failed scene stage publishes no manifest")
  Assert.isFalse(artifact:stageFs():exists(receiptPath, "file"), "a failed scene stage publishes no receipt")
  Assert.equal(
    cacheFs:loadLua(manifestPath).generationId,
    goodGeneration,
    "the previous good scene 4 manifest remains intact"
  )
  Assert.equal(cacheFs:loadLua(receiptPath).marker, "previous", "the previous good scene 4 receipt remains intact")
  Assert.equal(
    cacheFs:read("assets/generated/startup/opening/4/main-bg.png"),
    "previous art",
    "the previous good scene 4 art remains intact"
  )
  Assert.equal(
    cacheFs:loadLua(StartupAssetCache.openingScenePath(2)).generationId,
    goodGeneration,
    "the sibling scene 2 package remains intact"
  )
end

-- The five opening scenes are independently requestable beside the walker
-- and title scopes: the corpus sweep enumerates exactly five bounded keys,
-- and each scene resolves without prerequisites.
function T.opening_scene_jobs_are_bounded_to_five_keys()
  local jobs = ArtifactJobs.completeIterator({
    messageBankIds = {},
    audioBankIds = {},
    scriptMemberIds = {},
    iconPageIds = {},
    portraitPageIds = {},
    mapDataIds = {},
    mapIds = {},
    indexBundle = { index = { matrices = {} } },
  })
  local found = {}
  while true do
    local job = jobs()
    if job == nil then
      break
    end
    if job.kind == "opening-scene" then
      found[job.key] = true
    end
  end
  for sceneNumber = 1, 5 do
    Assert.isTrue(
      found[tostring(sceneNumber)] == true,
      "the corpus sweep enumerates scene " .. sceneNumber .. " as a bounded key"
    )
  end
  Assert.deepEqual(found, { ["1"] = true, ["2"] = true, ["3"] = true, ["4"] = true, ["5"] = true })
end

-- The opening scene scope publishes from its own compiled artifact: no
-- source inventory or audio bank is a prerequisite of any scene job.
function T.opening_scene_dependencies_are_empty_and_final()
  for sceneNumber = 1, 5 do
    local dependencies, complete = ArtifactJobs.dependencies("opening-scene", tostring(sceneNumber), {})
    Assert.isTrue(complete, "scene " .. sceneNumber .. " resolves without adopted plans")
    Assert.deepEqual(dependencies, {}, "scene " .. sceneNumber .. " carries no prerequisite jobs")
  end
end

-- The generation-three opening bundle carries explicit per-slot plane state,
-- engine-local window records with plane masks, a town-stage stop limited to
-- the town scene, and manual window overrides. These synthetic fixtures pin
-- the strict reader contract without touching a ROM.
local OPENING_SCHEMA_V3 = "g4-startup-opening-scene-v4"

local function openingLayerV3(engine, bgSlot, image, visible)
  return {
    bgSlot = bgSlot,
    priority = bgSlot,
    image = image,
    variants = {},
    width = 256,
    height = 192,
    sourceHash = string.rep("b", 40),
    initialVisible = visible,
  }
end

local function openingWindowEvent(stepId, atStepTick, overrides)
  local record = {
    op = "window",
    stepId = stepId,
    atStepTick = atStepTick,
    engine = "sub",
    from = { x1 = 255, y1 = 0, x2 = 255, y2 = 192 },
    to = { x1 = 0, y1 = 0, x2 = 255, y2 = 192 },
    ticks = 10,
    insideMask = 30,
    outsideMask = 28,
  }
  for key, value in pairs(overrides or {}) do
    if value == false and (key == "effect") then
      record[key] = nil
    else
      record[key] = value
    end
  end
  return record
end

local function validOpeningManifestV3(sceneNumber, versionId)
  local root = "assets/generated/startup/opening/" .. tostring(sceneNumber)
  local manifest = {
    schema = OPENING_SCHEMA_V3,
    versionId = versionId,
    generationId = "test-generation",
    sceneNumber = sceneNumber,
    sourceTickRate = 30,
    layers = {
      main = { openingLayerV3("main", 0, root .. "/main-bg.png", true) },
      sub = { openingLayerV3("sub", 0, root .. "/sub-bg.png", false) },
    },
    spriteClips = { openingClip(root, "clip0") },
    models = {},
    particles = { seed = 0, emitters = {} },
    timeline = { steps = openingSteps(3), events = openingEvents(3, root) },
    assets = {
      [root .. "/main-bg.png"] = true,
      [root .. "/sub-bg.png"] = true,
      [root .. "/sprites/clip0.png"] = true,
    },
  }
  -- The generic scene-3-shaped program owns every event below; scenes that
  -- carry no model stop reference it from a step the timeline covers.
  manifest.timeline = { steps = openingSteps(3), events = openingEvents(3, root) }
  if sceneNumber == 3 then
    manifest.models = {
      {
        descriptor = {},
        clips = { { frameCount = 4 }, { frameCount = 6 } },
      },
      {
        descriptor = {},
        clips = { { frameCount = 4 }, { frameCount = 6 } },
      },
      {
        descriptor = {},
        clips = { { frameCount = 4 }, { frameCount = 6 } },
      },
    }
  end
  return manifest
end

local function appendStepEventV3(manifest, stepId, event)
  event.stepId = stepId
  manifest.timeline.events[#manifest.timeline.events + 1] = event
  for _, step in ipairs(manifest.timeline.steps) do
    if step.id == stepId then
      step.events[#step.events + 1] = #manifest.timeline.events
      return #manifest.timeline.events
    end
  end
  error("synthetic v3 step is missing: " .. tostring(stepId), 0)
end

function T.opening_scene_reader_requires_initial_plane_state()
  local manifest = validOpeningManifestV3(3, "heartgold")
  local loaded, err = StartupAssetCache.loadOpeningScene(openingCacheFs(manifest, nil), 3, "heartgold")
  Assert.notNil(loaded, "a bundle with explicit plane state reads ready: " .. tostring(err))
  local missing = deepCopy(manifest)
  missing.layers.sub[1].initialVisible = nil
  local rejected, missingErr = StartupAssetCache.loadOpeningScene(openingCacheFs(missing, nil), 3, "heartgold")
  Assert.isNil(rejected, "a layer without plane state is not ready")
  Assert.notNil(missingErr, "the missing plane state reports its cause")
  local vague = deepCopy(manifest)
  vague.layers.main[1].initialVisible = "yes"
  local badVisible, badVisibleErr =
    StartupAssetCache.loadOpeningScene(openingCacheFs(vague, nil), 3, "heartgold")
  Assert.isNil(badVisible, "a non-boolean plane state is not ready")
  Assert.notNil(badVisibleErr, "the malformed plane state reports its cause")
  local stale = deepCopy(manifest)
  stale.schema = "g4-startup-opening-scene-v2"
  local staleRead, staleErr = StartupAssetCache.loadOpeningScene(openingCacheFs(stale, nil), 3, "heartgold")
  Assert.isNil(staleRead, "the previous generation-two record never validates")
  Assert.notNil(staleErr, "the stale schema reports its cause")
end

function T.opening_scene_reader_accepts_engine_window_records()
  local manifest = validOpeningManifestV3(4, "heartgold")
  manifest.particles = {
    seed = 0,
    emitters = {
      { id = 0, group = "water" },
      { id = 1, group = "water" },
      { id = 2, group = "water" },
      { id = 3, group = "fire" },
      { id = 4, group = "fire" },
      { id = 5, group = "fire" },
      { id = 6, group = "grass" },
      { id = 7, group = "grass" },
      { id = 8, group = "grass" },
    },
  }
  appendStepEventV3(manifest, "open", openingWindowEvent("open", 0))
  local loaded, err = StartupAssetCache.loadOpeningScene(openingCacheFs(manifest, nil), 4, "heartgold")
  Assert.notNil(loaded, "an engine window record reads ready: " .. tostring(err))
  local legacy = deepCopy(manifest)
  legacy.timeline.events[#legacy.timeline.events] = {
    op = "window",
    stepId = "open",
    atStepTick = 0,
    target = "lower",
    kind = "narrow-y",
  }
  local legacyRead, legacyErr = StartupAssetCache.loadOpeningScene(openingCacheFs(legacy, nil), 4, "heartgold")
  Assert.isNil(legacyRead, "the retired target/kind window shape never validates")
  Assert.notNil(legacyErr, "the retired window shape reports its cause")
  local badMask = deepCopy(manifest)
  badMask.timeline.events[#badMask.timeline.events].insideMask = 32
  local badMaskRead, badMaskErr = StartupAssetCache.loadOpeningScene(openingCacheFs(badMask, nil), 4, "heartgold")
  Assert.isNil(badMaskRead, "a window mask outside the five plane bits never validates")
  Assert.notNil(badMaskErr, "the bad mask reports its cause")
  local badRect = deepCopy(manifest)
  badRect.timeline.events[#badRect.timeline.events].from = { x1 = 0, y1 = 0, x2 = 256, y2 = 192 }
  local badRectRead, badRectErr = StartupAssetCache.loadOpeningScene(openingCacheFs(badRect, nil), 4, "heartgold")
  Assert.isNil(badRectRead, "a window endpoint outside the source display never validates")
  Assert.notNil(badRectErr, "the bad endpoint reports its cause")
  local permanent = deepCopy(manifest)
  permanent.timeline.events[#permanent.timeline.events].ticks = 0
  permanent.timeline.events[#permanent.timeline.events].effect = "window-stuck"
  local permanentRead, permanentErr =
    StartupAssetCache.loadOpeningScene(openingCacheFs(permanent, nil), 4, "heartgold")
  Assert.isNil(permanentRead, "an immediate window assignment schedules no permanent wait")
  Assert.notNil(permanentErr, "the zero-duration effect reports its cause")
  local immediate = deepCopy(manifest)
  immediate.timeline.events[#immediate.timeline.events].ticks = 0
  immediate.timeline.events[#immediate.timeline.events].from =
    { x1 = 70, y1 = 64, x2 = 185, y2 = 192 }
  immediate.timeline.events[#immediate.timeline.events].to = { x1 = 70, y1 = 64, x2 = 185, y2 = 192 }
  local immediateRead, immediateErr =
    StartupAssetCache.loadOpeningScene(openingCacheFs(immediate, nil), 4, "heartgold")
  Assert.notNil(immediateRead, "an immediate window assignment reads ready: " .. tostring(immediateErr))
end

function T.opening_scene_reader_restricts_the_town_stop_to_the_town_scene()
  local manifest = validOpeningManifestV3(3, "heartgold")
  appendStepEventV3(manifest, "open", { op = "setModelVisible", atStepTick = 0, visible = false })
  local loaded, err = StartupAssetCache.loadOpeningScene(openingCacheFs(manifest, nil), 3, "heartgold")
  Assert.notNil(loaded, "the town scene ends its town drawing: " .. tostring(err))
  local elsewhere = validOpeningManifestV3(4, "heartgold")
  elsewhere.particles = manifest.particles
  appendStepEventV3(elsewhere, "open", { op = "setModelVisible", atStepTick = 0, visible = false })
  local badScene, badSceneErr = StartupAssetCache.loadOpeningScene(openingCacheFs(elsewhere, nil), 4, "heartgold")
  Assert.isNil(badScene, "only the town scene stops its town drawing")
  Assert.notNil(badSceneErr, "the misplaced town stop reports its cause")
  local vague = deepCopy(manifest)
  vague.timeline.events[#vague.timeline.events].visible = "no"
  local badVisible, badVisibleErr = StartupAssetCache.loadOpeningScene(openingCacheFs(vague, nil), 3, "heartgold")
  Assert.isNil(badVisible, "a non-boolean town stop is not ready")
  Assert.notNil(badVisibleErr, "the malformed town stop reports its cause")
end

function T.opening_scene_reader_accepts_manual_window_overrides_and_visibility()
  local manifest = validOpeningManifestV3(3, "heartgold")
  appendStepEventV3(manifest, "open", {
    op = "setWindowSecondary",
    atStepTick = 0,
    engine = "sub",
    rect = { x1 = 70, y1 = 64, x2 = 185, y2 = 192 },
    insideMask = 29,
  })
  appendStepEventV3(manifest, "open", { op = "setWindowVisible", atStepTick = 0, engine = "sub", visible = true })
  local loaded, err = StartupAssetCache.loadOpeningScene(openingCacheFs(manifest, nil), 3, "heartgold")
  Assert.notNil(loaded, "manual window records read ready: " .. tostring(err))
  local badOverride = deepCopy(manifest)
  badOverride.timeline.events[#badOverride.timeline.events - 1].insideMask = 64
  local badRead, badErr = StartupAssetCache.loadOpeningScene(openingCacheFs(badOverride, nil), 3, "heartgold")
  Assert.isNil(badRead, "a manual override outside the five plane bits never validates")
  Assert.notNil(badErr, "the bad override mask reports its cause")
  local vague = deepCopy(manifest)
  vague.timeline.events[#vague.timeline.events].visible = 1
  local vagueRead, vagueErr = StartupAssetCache.loadOpeningScene(openingCacheFs(vague, nil), 3, "heartgold")
  Assert.isNil(vagueRead, "a non-boolean window visibility is not ready")
  Assert.notNil(vagueErr, "the malformed visibility reports its cause")
end

-- The generation session exposes one numeric opening scene demand that
-- admits exactly scenes 1..5.
function T.opening_scene_session_request_validates_its_scene_number()
  local ok, InteractiveCacheBuild = pcall(require, "romdump.src.build.InteractiveCacheBuild")
  Assert.isTrue(
    ok and type(InteractiveCacheBuild.requestOpeningScene) == "function",
    "the generation session demands one numbered opening scene"
  )
  local session = setmetatable({ retired = false }, { __index = InteractiveCacheBuild })
  for _, badScene in ipairs({ 0, 6, 2.5, "4" }) do
    local callOk, callErr = pcall(session.requestOpeningScene, session, badScene, "required")
    Assert.isFalse(callOk, "scene " .. tostring(badScene) .. " is rejected before any cache work")
    Assert.isTrue(
      tostring(callErr):find("1..5", 1, true) ~= nil,
      "the rejection names the valid scene range: " .. tostring(callErr)
    )
  end
end

-- The generated opening scene identity the producer and the strict reader
-- agree on: full native surfaces with per-image extents, instant and
-- continuous scroll modes, and per-engine blend and wipe operands.
local NATIVE_OPENING_SCHEMA = "g4-startup-opening-scene-v4"

local function typedOpeningManifest()
  local manifest = validOpeningManifest(1, "heartgold")
  manifest.schema = NATIVE_OPENING_SCHEMA
  local root = "assets/generated/startup/opening/1"
  manifest.layers.main[1].variants = {
    { image = root .. "/main-bg-alt.png", width = 512, height = 512 },
  }
  manifest.assets[root .. "/main-bg-alt.png"] = true
  manifest.timeline.events[4] = {
    op = "setBlend",
    stepId = "fades",
    atStepTick = 0,
    engine = "main",
    firstMask = 1,
    secondMask = 32,
    direction = 1,
    ticks = 60,
    effect = "blend-copyright",
  }
  local function appendLogoEvent(event)
    manifest.timeline.events[#manifest.timeline.events + 1] = event
    local steps = manifest.timeline.steps
    steps[#steps].events[#steps[#steps].events + 1] = #manifest.timeline.events
  end
  appendLogoEvent({
    op = "setScroll",
    stepId = "logo",
    atStepTick = 0,
    engine = "main",
    bgSlot = 0,
    dx = 0,
    dy = 320,
    ticks = 0,
  })
  appendLogoEvent({
    op = "setScroll",
    stepId = "logo",
    atStepTick = 0,
    engine = "main",
    bgSlot = 2,
    dx = 0,
    dy = 64,
    ticks = -1,
  })
  appendLogoEvent({
    op = "circleWipe",
    stepId = "logo",
    atStepTick = 0,
    engine = "main",
    kind = 0,
    ticks = 18,
    effect = "wipe-typed",
  })
  return manifest
end

local function typedOpeningFiles(root)
  return {
    [root .. "/main-bg.png"] = "main art",
    [root .. "/sub-bg.png"] = "sub art",
    [root .. "/main-bg-alt.png"] = "alternate art",
    [root .. "/sprites/clip0.png"] = "clip",
  }
end

-- A complete bundle in the native shape reads ready: typed alternates,
-- instant and continuous scrolls, per-engine blends, and engine wipes.
function T.opening_scene_reader_loads_the_native_typed_bundle()
  local manifest = typedOpeningManifest()
  local loaded, err = StartupAssetCache.loadOpeningScene(openingCacheFs(manifest, nil), 1, "heartgold")
  Assert.notNil(loaded, "the native typed scene reads ready: " .. tostring(err))
  Assert.equal(loaded.schema, NATIVE_OPENING_SCHEMA, "the loaded scene carries the native schema")
  local variant = loaded.layers.main[1].variants[1]
  Assert.equal(variant.width, 512, "the alternate keeps its own native width")
  Assert.equal(variant.height, 512, "the alternate keeps its own native height")
end

-- The previous record shape never reads as current, and malformed typed
-- records fail with a cause: bare-path alternates, missing alternate extents,
-- out-of-range durations, fractional deltas, oversized plane masks,
-- unknown wipe kinds, and cross-scene images.
function T.opening_scene_reader_rejects_legacy_and_malformed_typed_records()
  local root = "assets/generated/startup/opening/1"
  local legacy, legacyErr =
    StartupAssetCache.loadOpeningScene(openingCacheFs(validOpeningManifest(1, "heartgold"), nil), 1, "heartgold")
  Assert.isNil(legacy, "the previous record shape never validates as current")
  Assert.notNil(legacyErr, "the legacy shape reports its cause")
  local cases = {}
  local bareVariant = deepCopy(typedOpeningManifest())
  bareVariant.layers.main[1].variants = { root .. "/main-bg-alt.png" }
  cases[#cases + 1] = { manifest = bareVariant, label = "a bare-path alternate" }
  local missingExtent = deepCopy(typedOpeningManifest())
  missingExtent.layers.main[1].variants = { { image = root .. "/main-bg-alt.png", width = 512 } }
  cases[#cases + 1] = { manifest = missingExtent, label = "an alternate without its own height" }
  local negativeDuration = deepCopy(typedOpeningManifest())
  negativeDuration.timeline.events[#negativeDuration.timeline.events - 2].ticks = -2
  cases[#cases + 1] = { manifest = negativeDuration, label = "a scroll below the continuous mode" }
  local fractionalDelta = deepCopy(typedOpeningManifest())
  fractionalDelta.timeline.events[#fractionalDelta.timeline.events - 2].dx = 1.5
  cases[#cases + 1] = { manifest = fractionalDelta, label = "a fractional scroll delta" }
  local oversizedMask = deepCopy(typedOpeningManifest())
  oversizedMask.timeline.events[4].firstMask = 64
  cases[#cases + 1] = { manifest = oversizedMask, label = "a plane mask outside six bits" }
  local unknownKind = deepCopy(typedOpeningManifest())
  unknownKind.timeline.events[#unknownKind.timeline.events].kind = 7
  cases[#cases + 1] = { manifest = unknownKind, label = "a wipe kind outside its set" }
  local escapedImage = deepCopy(typedOpeningManifest())
  escapedImage.timeline.events[2].image = "assets/generated/startup/opening/2/main-bg.png"
  cases[#cases + 1] = { manifest = escapedImage, label = "a layer pointing outside its scene root" }
  for _, case in ipairs(cases) do
    local rejected, reason = StartupAssetCache.loadOpeningScene(openingCacheFs(case.manifest, nil), 1, "heartgold")
    Assert.isNil(rejected, case.label .. " never validates")
    Assert.notNil(reason, case.label .. " reports its cause")
  end
end

-- Staging a typed bundle publishes its effect operands atomically: the
-- staged package reads back with its masks, direction, and wipe kind,
-- and a failed replacement preserves the previous good publication.
function T.opening_scene_writer_publishes_typed_bundles_atomically()
  local ok, OpeningMovieCacheWriter = pcall(require, "romdump.src.digest.startup.OpeningMovieCacheWriter")
  Assert.isTrue(
    ok and type(OpeningMovieCacheWriter.stageScene) == "function",
    "the opening scene writer stages one numbered scene"
  )
  local backend = FakeCache.new()
  local cacheFs = CacheFs.forVersion("heartgold", backend)
  local root = "assets/generated/startup/opening/1"
  local manifest = typedOpeningManifest()
  manifest.generationId = "typed-generation"
  local artifact = PreparedArtifact.new({
    cacheFs = cacheFs,
    generationId = "typed-generation",
    epoch = 1,
    kind = "opening-scene",
    key = "1",
    jobKey = "opening-scene:1",
    stageName = "opening-scene-1-typed",
  })
  local marker, stageErr =
    OpeningMovieCacheWriter.stageScene(artifact, { manifest = manifest, files = typedOpeningFiles(root) }, "typed-generation", 1)
  Assert.notNil(marker, "the typed scene stages its numbered package: " .. tostring(stageErr))
  artifact:finishSuccess({ marker = marker })
  Assert.isTrue(
    artifact:publish({
      generationId = "typed-generation",
      epoch = 1,
      kind = "opening-scene",
      key = "1",
      jobKey = "opening-scene:1",
      stageName = "opening-scene-1-typed",
    }),
    "the typed scene publishes its numbered package"
  )
  local loaded, loadErr = StartupAssetCache.loadOpeningScene(cacheFs, 1, "heartgold")
  Assert.notNil(loaded, "the staged typed scene reads back ready: " .. tostring(loadErr))
  local blend = nil
  for _, event in ipairs(loaded.timeline.events) do
    if event.op == "setBlend" then
      blend = event
    end
  end
  Assert.notNil(blend, "the staged scene keeps its engine blend")
  Assert.equal(blend.firstMask, 1, "the staged blend keeps its first plane mask")
  Assert.equal(blend.secondMask, 32, "the staged blend keeps its second plane mask")
  Assert.equal(blend.direction, 1, "the staged blend keeps its source direction")
  local liveManifest = cacheFs:loadLua(StartupAssetCache.openingScenePath(1))
  local liveReceipt = cacheFs:loadLua(ArtifactState.path("opening-scene", "1"))
  local broken = deepCopy(manifest)
  broken.assets[root .. "/main-bg-alt.png"] = nil
  local brokenArtifact = PreparedArtifact.new({
    cacheFs = cacheFs,
    generationId = "broken-generation",
    epoch = 1,
    kind = "opening-scene",
    key = "1",
    jobKey = "opening-scene:1",
    stageName = "opening-scene-1-broken",
  })
  local brokenOk, brokenErr = pcall(
    OpeningMovieCacheWriter.stageScene,
    brokenArtifact,
    { manifest = broken, files = typedOpeningFiles(root) },
    "broken-generation",
    1
  )
  Assert.isFalse(brokenOk, "the corrupt replacement fails the scene restage: " .. tostring(brokenErr))
  Assert.deepEqual(
    cacheFs:loadLua(StartupAssetCache.openingScenePath(1)),
    liveManifest,
    "a failed restage preserves its previous good manifest"
  )
  Assert.deepEqual(
    cacheFs:loadLua(ArtifactState.path("opening-scene", "1")),
    liveReceipt,
    "a failed restage preserves its previous good receipt"
  )
end

-- A layer change may point at any image its own slot owns: the staged base
-- image or one of its typed alternates both resolve, while an alternate
-- that duplicates the base image leaves the slot ambiguous and never
-- validates.
function T.opening_scene_reader_resolves_owned_variant_images_through_layer_changes()
  local root = "assets/generated/startup/opening/1"
  local manifest = typedOpeningManifest()
  manifest.timeline.events[2].image = root .. "/main-bg-alt.png"
  local loaded, err = StartupAssetCache.loadOpeningScene(openingCacheFs(manifest, nil), 1, "heartgold")
  Assert.notNil(loaded, "a layer change pointing at an owned alternate reads ready: " .. tostring(err))
  local shadowed = deepCopy(manifest)
  shadowed.layers.main[1].variants = {
    { image = root .. "/main-bg.png", width = 512, height = 512 },
  }
  local rejected, reason =
    StartupAssetCache.loadOpeningScene(openingCacheFs(shadowed, nil), 1, "heartgold")
  Assert.isNil(rejected, "an alternate shadowing its own base image never validates")
  Assert.notNil(reason, "the ambiguous slot image reports its cause")
end

return { tests = T }
