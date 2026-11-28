-- Cianwood's source rebinding is compiled into the target model definition:
-- source 174's record slots become target-owned clips on 173, and source
-- 175's slot 0 receives its exact event identity. Runtime code never attaches
-- a foreign clip or depends on 174 having a map placement.

local Assert = require("tests.support.Assert")

local T = {}

local MODULES = {
  "libs.nds.src.nitro.g3d.Nsbmd",
  "libs.nds.src.nitro.g3d.Nsbtx",
  "romdump.src.digest.model.DynamicModelCompiler",
  "romdump.src.digest.model.ModelAssetCompiler",
  "romdump.src.digest.model.MapPropAnimCompiler",
  "romdump.src.digest.map.BuildingModelCompiler",
}

local function narc(readMember, memberCount)
  return {
    readMember = function(_, memberId)
      return assert(readMember(memberId), "missing narc member " .. tostring(memberId))
    end,
    memberCount = function()
      return memberCount
    end,
  }
end

local function sourceClip(id)
  return { id = id, name = id, source = { memberId = id } }
end

local function placement(index, memberId)
  return {
    index = index,
    modelMemberId = memberId,
    position = { x = 0, y = 0, z = 0 },
    rotation = { x = 0, y = 0, z = 0 },
    scale = { width = 1, height = 1, length = 1 },
  }
end

function T.cianwood_source_records_are_prebound_to_their_target_definitions()
  local saved = {}
  for _, name in ipairs(MODULES) do
    saved[name] = package.loaded[name]
  end
  local compiledAnimations = {}
  package.loaded["libs.nds.src.nitro.g3d.Nsbmd"] = {
    decode = function()
      return { models = { { name = "building" } } }
    end,
  }
  package.loaded["libs.nds.src.nitro.g3d.Nsbtx"] = {
    decode = function()
      return {}
    end,
  }
  package.loaded["romdump.src.digest.model.ModelAssetCompiler"] = {
    compileModel = function()
      error("every Cianwood fixture model is animated")
    end,
  }
  package.loaded["romdump.src.digest.model.DynamicModelCompiler"] = {
    compile = function(...)
      local args = { ... }
      local animResult, memberId = args[4], args[6]
      compiledAnimations[memberId] = animResult.clips
      return {
        schema = "g4-model-v1",
        memberId = memberId,
        kind = "nitro-dynamic",
        dynamic = { nodes = {}, transformProgram = {}, batches = {} },
        materials = {},
        animations = animResult.clips,
      }, {}
    end,
  }
  package.loaded["romdump.src.digest.model.MapPropAnimCompiler"] = {
    compile = function(_, _, opts)
      local byMember = {
        [173] = { "water_own" },
        [174] = { "fall_a", "fall_b" },
        [175] = { "winch0", "winch1" },
      }
      local clips = {}
      for _, id in ipairs(assert(byMember[opts.memberId])) do
        clips[#clips + 1] = sourceClip(id)
      end
      return { clips = clips }
    end,
  }
  package.loaded["romdump.src.digest.map.BuildingModelCompiler"] = nil

  local ok, err = pcall(function()
    local Compiler = require("romdump.src.digest.map.BuildingModelCompiler")
    local archives = {
      area_build_config = narc(function()
        return string.char(2, 0, 173, 0, 175, 0)
      end, 32),
      interior_build_models = narc(function(memberId)
        return "model:" .. tostring(memberId)
      end, 176),
      building_textures = narc(function()
        return "textures"
      end, 32),
      interior_build_anim_list = narc(function(memberId)
        return "anim:" .. tostring(memberId)
      end, 176),
      build_anim = narc(function()
        error("the mocked animation compiler reads no resource bytes")
      end, 1),
    }
    local romFs = {
      openNarc = function(_, alias)
        return assert(archives[alias], "unexpected archive " .. tostring(alias))
      end,
    }
    local result = Compiler.compile(romFs, { areaType = "indoor", buildingTexturePackId = 31 }, {
      buildings = {
        placement(0, 173),
        placement(1, 175),
      },
    }, { meshes = {}, textures = {} })

    local water, winch
    for _, descriptor in pairs(result.models) do
      if descriptor.memberId == 173 then
        water = descriptor
      elseif descriptor.memberId == 175 then
        winch = descriptor
      end
    end
    local waterIds, winchIds = {}, {}
    for _, clip in ipairs(assert(water).animations) do
      waterIds[#waterIds + 1] = clip.id
    end
    for _, clip in ipairs(assert(winch).animations) do
      winchIds[#winchIds + 1] = clip.id
    end
    Assert.deepEqual(waterIds, {
      "water_own",
      "cianwood.water.1.fall_a",
      "cianwood.water.2.fall_b",
    }, "173 keeps its own record and owns exact copies of 174's two record slots")
    Assert.deepEqual(winchIds, {
      "cianwood.winch.0.winch0",
      "winch1",
    }, "175 identifies only source record 0 for the winch event")
    Assert.deepEqual(compiledAnimations[173], assert(water).animations, "dynamic assembly sees the bound clips")
    Assert.equal(compiledAnimations[174], nil, "the unplaced source model is not independently published")
  end)

  for _, name in ipairs(MODULES) do
    package.loaded[name] = saved[name]
  end
  Assert.isTrue(ok, tostring(err))
end

function T.matching_member_ids_in_the_outdoor_archive_are_not_rebound()
  local saved = {}
  for _, name in ipairs(MODULES) do
    saved[name] = package.loaded[name]
  end
  package.loaded["libs.nds.src.nitro.g3d.Nsbmd"] = {
    decode = function()
      return { models = { { name = "building" } } }
    end,
  }
  package.loaded["libs.nds.src.nitro.g3d.Nsbtx"] = {
    decode = function()
      return {}
    end,
  }
  package.loaded["romdump.src.digest.model.ModelAssetCompiler"] = {
    compileModel = function()
      error("every outdoor fixture model is animated")
    end,
  }
  local seenIds = {}
  package.loaded["romdump.src.digest.model.DynamicModelCompiler"] = {
    compile = function(...)
      local args = { ... }
      local animResult, memberId = args[4], args[6]
      local ids = {}
      for _, clip in ipairs(animResult.clips) do
        ids[#ids + 1] = clip.id
      end
      seenIds[memberId] = ids
      return {
        schema = "g4-model-v1",
        memberId = memberId,
        kind = "nitro-dynamic",
        dynamic = { nodes = {}, transformProgram = {}, batches = {} },
        materials = {},
        animations = animResult.clips,
      }, {}
    end,
  }
  package.loaded["romdump.src.digest.model.MapPropAnimCompiler"] = {
    compile = function(_, _, opts)
      local byMember = {
        [173] = { "water_own" },
        [174] = { "fall_a", "fall_b" },
        [175] = { "winch0", "winch1" },
      }
      local clips = {}
      for _, id in ipairs(assert(byMember[opts.memberId])) do
        clips[#clips + 1] = sourceClip(id)
      end
      return { clips = clips }
    end,
  }
  package.loaded["romdump.src.digest.map.BuildingModelCompiler"] = nil

  local ok, err = pcall(function()
    local Compiler = require("romdump.src.digest.map.BuildingModelCompiler")
    local archives = {
      area_build_config = narc(function()
        return string.char(2, 0, 173, 0, 175, 0)
      end, 32),
      exterior_build_models = narc(function(memberId)
        return "model:" .. tostring(memberId)
      end, 176),
      building_textures = narc(function()
        return "textures"
      end, 32),
      exterior_build_anim_list = narc(function(memberId)
        return "anim:" .. tostring(memberId)
      end, 176),
      build_anim = narc(function()
        error("the mocked animation compiler reads no resource bytes")
      end, 1),
    }
    local romFs = {
      openNarc = function(_, alias)
        return assert(archives[alias], "unexpected archive " .. tostring(alias))
      end,
    }
    Compiler.compile(romFs, { areaType = "outdoor", buildingTexturePackId = 31 }, {
      buildings = {
        placement(0, 173),
        placement(1, 175),
      },
    }, { meshes = {}, textures = {} })
    Assert.deepEqual(seenIds[173], { "water_own" }, "outdoor 173 keeps only its own record")
    Assert.deepEqual(seenIds[175], { "winch0", "winch1" }, "outdoor 175 keeps its unprefixed records")
  end)

  for _, name in ipairs(MODULES) do
    package.loaded[name] = saved[name]
  end
  Assert.isTrue(ok, tostring(err))
end

return { tests = T }
