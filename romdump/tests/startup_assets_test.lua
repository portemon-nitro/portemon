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
  for _, kind in ipairs({ "startup-loader", "startup-title" }) do
    Assert.isTrue(ArtifactState.KINDS[kind] == true, kind .. " is a known family")
    Assert.equal(ArtifactState.path(kind, "global"), "data/generated/jobs/" .. kind .. "/global.lua")
    Assert.isFalse(pcall(ArtifactState.path, kind, "1"), kind .. " rejects numeric selectors")
    Assert.isTrue(pcall(ArtifactJobs.sizeClass, kind), kind .. " has a worker descriptor")
  end
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
    if job.kind == "startup-loader" or job.kind == "startup-title" then
      found[job.kind] = job.key == "global"
    end
  end
  Assert.deepEqual(found, { ["startup-loader"] = true, ["startup-title"] = true })
end

function T.startup_manifests_have_fixed_versioned_paths()
  local ok, StartupAssetCache = pcall(require, "libs.assets.src.StartupAssetCache")
  Assert.isTrue(ok, "strict startup manifest reader exists")
  Assert.equal(StartupAssetCache.loaderPath(), "data/generated/startup/loader.lua")
  Assert.equal(StartupAssetCache.titlePath(), "data/generated/startup/title.lua")
end

function T.loader_manifest_requires_its_generated_backdrop_file()
  local manifest = {
    schema = StartupAssetContract.startupLoader.schema,
    versionId = "heartgold",
    generationId = "generation-a",
    heroes = {
      ethan = {
        atlasPath = "assets/generated/startup/loader/ethan.png",
        visual = {
          render = { kind = "atlas", frameWidth = 1, frameHeight = 1, frameCount = 2 },
          directions = {
            east = {
              walk = {
                frames = {
                  { frameIndex = 1, ticks = 1 },
                  { frameIndex = 2, ticks = 1 },
                },
              },
            },
          },
        },
      },
      lyra = {
        atlasPath = "assets/generated/startup/loader/lyra.png",
        visual = {
          render = { kind = "atlas", frameWidth = 1, frameHeight = 1, frameCount = 2 },
          directions = {
            east = {
              walk = {
                frames = {
                  { frameIndex = 1, ticks = 1 },
                  { frameIndex = 2, ticks = 1 },
                },
              },
            },
          },
        },
      },
    },
    followers = {
      {
        speciesId = 1,
        atlasPath = "assets/generated/startup/loader/f1.png",
        visual = {
          render = { kind = "atlas", frameWidth = 1, frameHeight = 1, frameCount = 2 },
          directions = {
            east = {
              walk = {
                frames = {
                  { frameIndex = 1, ticks = 1 },
                  { frameIndex = 2, ticks = 1 },
                },
              },
            },
          },
        },
      },
      {
        speciesId = 2,
        atlasPath = "assets/generated/startup/loader/f2.png",
        visual = {
          render = { kind = "atlas", frameWidth = 1, frameHeight = 1, frameCount = 2 },
          directions = {
            east = {
              walk = {
                frames = {
                  { frameIndex = 1, ticks = 1 },
                  { frameIndex = 2, ticks = 1 },
                },
              },
            },
          },
        },
      },
      {
        speciesId = 3,
        atlasPath = "assets/generated/startup/loader/f3.png",
        visual = {
          render = { kind = "atlas", frameWidth = 1, frameHeight = 1, frameCount = 2 },
          directions = {
            east = {
              walk = {
                frames = {
                  { frameIndex = 1, ticks = 1 },
                  { frameIndex = 2, ticks = 1 },
                },
              },
            },
          },
        },
      },
      {
        speciesId = 4,
        atlasPath = "assets/generated/startup/loader/f4.png",
        visual = {
          render = { kind = "atlas", frameWidth = 1, frameHeight = 1, frameCount = 2 },
          directions = {
            east = {
              walk = {
                frames = {
                  { frameIndex = 1, ticks = 1 },
                  { frameIndex = 2, ticks = 1 },
                },
              },
            },
          },
        },
      },
    },
    backdrop = { kind = "authored", width = 256, height = 192 },
  }
  local cacheFs = {
    loadLua = function()
      return manifest
    end,
    exists = function()
      return true
    end,
  }
  local loaded, err = StartupAssetCache.loadLoader(cacheFs)
  Assert.isNil(loaded)
  Assert.notNil(err, "a backdrop without its generated image path is invalid")
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
        },
        sequenceBySymbol = {
          SEQ_GS_POKEMON_THEME = 41,
          SEQ_SE_DP_SELECT = 42,
        },
      },
    },
  }
  for _, kind in ipairs({ "startup-loader", "startup-title" }) do
    local dependencies, complete = ArtifactJobs.dependencies(kind, "global", plan)
    Assert.isTrue(complete, kind .. " stays final beside an adopted audio plan")
    Assert.deepEqual(dependencies, {}, kind .. " keeps no audio prerequisite")
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
  local bundle = {
    manifest = {
      schema = "g4-startup-loader-v1",
      versionId = "heartgold",
      generationId = "generation-a",
      heroes = {
        ethan = {
          atlasPath = "assets/generated/startup/loader/hero-ethan.png",
          visual = {
            render = { kind = "atlas", frameWidth = 1, frameHeight = 1, frameCount = 2 },
            directions = {
              east = {
                walk = {
                  frames = {
                    { frameIndex = 1, ticks = 1 },
                    { frameIndex = 2, ticks = 1 },
                  },
                },
              },
            },
          },
        },
        lyra = {
          atlasPath = "assets/generated/startup/loader/hero-lyra.png",
          visual = {
            render = { kind = "atlas", frameWidth = 1, frameHeight = 1, frameCount = 2 },
            directions = {
              east = {
                walk = {
                  frames = {
                    { frameIndex = 1, ticks = 1 },
                    { frameIndex = 2, ticks = 1 },
                  },
                },
              },
            },
          },
        },
      },
      followers = {
        {
          speciesId = 1,
          atlasPath = "assets/generated/startup/loader/follower-1.png",
          visual = {
            render = { kind = "atlas", frameWidth = 1, frameHeight = 1, frameCount = 2 },
            directions = {
              east = {
                walk = {
                  frames = {
                    { frameIndex = 1, ticks = 1 },
                    { frameIndex = 2, ticks = 1 },
                  },
                },
              },
            },
          },
        },
        {
          speciesId = 2,
          atlasPath = "assets/generated/startup/loader/follower-2.png",
          visual = {
            render = { kind = "atlas", frameWidth = 1, frameHeight = 1, frameCount = 2 },
            directions = {
              east = {
                walk = {
                  frames = {
                    { frameIndex = 1, ticks = 1 },
                    { frameIndex = 2, ticks = 1 },
                  },
                },
              },
            },
          },
        },
        {
          speciesId = 3,
          atlasPath = "assets/generated/startup/loader/follower-3.png",
          visual = {
            render = { kind = "atlas", frameWidth = 1, frameHeight = 1, frameCount = 2 },
            directions = {
              east = {
                walk = {
                  frames = {
                    { frameIndex = 1, ticks = 1 },
                    { frameIndex = 2, ticks = 1 },
                  },
                },
              },
            },
          },
        },
        {
          speciesId = 4,
          atlasPath = "assets/generated/startup/loader/follower-4.png",
          visual = {
            render = { kind = "atlas", frameWidth = 1, frameHeight = 1, frameCount = 2 },
            directions = {
              east = {
                walk = {
                  frames = {
                    { frameIndex = 1, ticks = 1 },
                    { frameIndex = 2, ticks = 1 },
                  },
                },
              },
            },
          },
        },
      },
      backdrop = { kind = "authored", width = 256, height = 192 },
    },
    atlases = {
      ["assets/generated/startup/loader/hero-ethan.png"] = { width = 1, height = 1, pixels = "rgba" },
      ["assets/generated/startup/loader/hero-lyra.png"] = { width = 1, height = 1, pixels = "rgba" },
      ["assets/generated/startup/loader/follower-1.png"] = { width = 1, height = 1, pixels = "rgba" },
      ["assets/generated/startup/loader/follower-2.png"] = { width = 1, height = 1, pixels = "rgba" },
      ["assets/generated/startup/loader/follower-3.png"] = { width = 1, height = 1, pixels = "rgba" },
      ["assets/generated/startup/loader/follower-4.png"] = { width = 1, height = 1, pixels = "rgba" },
    },
    backdrop = { width = 256, height = 192, pixels = string.rep("\0", 256 * 192 * 4) },
    dependencies = { versionId = "heartgold" },
    sourceHash = "source-hash",
  }
  Assert.isTrue(pcall(StartupCacheWriter.stageLoader, artifact, bundle, "generation-a"))
  Assert.equal(#roots, 2, "one manifest file and one asset directory are owned")
  local rootSet = {}
  for _, path in ipairs(roots) do
    rootSet[path] = true
  end
  Assert.isTrue(rootSet["data/generated/startup/loader.lua"])
  Assert.isTrue(rootSet["assets/generated/startup/loader"])
  Assert.equal(writes[#writes].path, StartupAssetCache.loaderPath(), "manifest is the last staged file")
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
      schema = "g4-startup-title-v1",
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
    schema = "g4-startup-title-v1",
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
  for _, kind in ipairs({ "startup-loader", "startup-title" }) do
    local dependencies, complete = ArtifactJobs.dependencies(kind, "global", {})
    Assert.isTrue(complete, kind .. " resolves without adopted plans")
    Assert.deepEqual(dependencies, {}, kind .. " carries no prerequisite jobs")
  end
  Assert.deepEqual(ArtifactJobs.startupLoaderJobs(), { { kind = "startup-loader", key = "global" } })
  Assert.deepEqual(ArtifactJobs.startupTitleJobs(), { { kind = "startup-title", key = "global" } })
end

-- The optional audio closure resolves exactly the title theme, menu effect,
-- and legendary cry banks from the adopted index, independent of either
-- visual milestone.
function T.startup_audio_closure_resolves_only_its_required_banks()
  local plan = {
    index = {
      version = "heartgold",
      sequences = { [41] = { bankId = 7 }, [42] = { bankId = 8 } },
      sequenceBySymbol = { SEQ_GS_POKEMON_THEME = 41, SEQ_SE_DP_SELECT = 42 },
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
      sequenceBySymbol = { SEQ_GS_POKEMON_THEME = 41, SEQ_SE_DP_SELECT = 41 },
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
    local missing = { index = { version = "heartgold", sequences = {}, sequenceBySymbol = {} } }
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
      subscreenDecor = titleSurface("assets/generated/startup/title/subscreen-decor.png"),
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
      color = { foreground = 1, shadow = 1, background = 0 },
      flash = {
        initialDelayFrames = 30,
        initialPhaseFrame = 30,
        cycleFrames = 45,
        visibleFrames = 30,
        hiddenFrames = 15,
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

return { tests = T }
