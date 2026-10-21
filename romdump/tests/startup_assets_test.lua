-- Startup cache contracts keep loader and title output bounded and separate.

local Assert = require("tests.support.Assert")
local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
local ArtifactState = require("romdump.src.build.ArtifactState")
local StartupAssetCache = require("libs.assets.src.StartupAssetCache")
local StartupAssetContract = require("libs.assets.src.DerivedAssetContract")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
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

function T.title_audio_dependencies_wait_for_and_use_the_adopted_plan()
  local unresolved, complete = ArtifactJobs.dependencies("startup-title", "global", {})
  Assert.isFalse(complete, "title audio dependencies are unresolved before audio planning")
  local unresolvedSet = {}
  for _, dependency in ipairs(unresolved) do
    unresolvedSet[dependency.kind .. ":" .. dependency.key] = true
  end
  Assert.isTrue(unresolvedSet["source-plan:global"], "title waits for an admitted source plan")
  Assert.isTrue(unresolvedSet["audio-catalog:global"], "title waits for the normalized audio index")

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
  local dependencies, resolved = ArtifactJobs.dependencies("startup-title", "global", plan)
  Assert.isTrue(resolved, "title audio dependencies resolve from the adopted index")
  local found = {}
  for _, dependency in ipairs(dependencies) do
    found[dependency.kind .. ":" .. dependency.key] = true
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

return { tests = T }
