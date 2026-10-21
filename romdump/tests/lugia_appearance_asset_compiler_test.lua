-- The Whirl Islands compiler must emit the eye glimmer and Lugia cinematic
-- roles with the exact model keys, clip ids, and provenance the runtime
-- scene resolves.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")

local T = { tests = {} }

local function compileWith(memberBytes, animationFormat, openNames)
  local modules = {
    ["libs.nds.src.nitro.g3d.Nsbmd"] = {
      decode = function(bytes)
        assert(bytes == "model" or bytes == "lzmodel")
        return { models = { { name = "legend", materials = {} } }, embeddedTextures = { textures = {}, palettes = {} } }
      end,
    },
    ["libs.nds.src.nitro.g3d.NitroAnimation"] = {
      decode = function(bytes)
        return {
          format = animationFormat[bytes],
          bytes = bytes,
          animations = { { name = "source-" .. bytes, resource = {} } },
        }
      end,
    },
    ["romdump.src.digest.model.MapPropAnimCompiler"] = {
      compileDecoded = function(decoded, options)
        local kinds = { NSBCA = "trs", NSBMA = "color", NSBTP = "pattern", NSBTA = "texsrt" }
        return {
          id = options.id,
          name = options.name,
          category = decoded.format == "NSBCA" and "joint" or "material",
          kind = kinds[decoded.format],
          semanticNames = options.semanticNames,
          frameCount = 4,
          tracks = { { target = options.name } },
          source = options.source,
          compiled = { targets = {} },
        }
      end,
    },
    ["romdump.src.digest.model.DynamicModelCompiler"] = {
      compile = function(_, _, _, animations, context, memberId, textureOutput, meshOutput)
        textureOutput.texture = { pixels = "pixel" }
        meshOutput.mesh = {}
        return {
          schema = "g4-model-v5",
          kind = "nitro-dynamic",
          dynamic = { batches = { { geometry = "assets/generated/maps/geometry/mesh.g4mesh" } } },
          materials = { { texture = "assets/generated/maps/textures/texture.png", variants = {} } },
          animations = animations.clips,
        }, {}
      end,
    },
    ["libs.assets.src.model.ModelAsset"] = {
      validate = function(descriptor)
        Assert.equal(descriptor.kind, "nitro-dynamic")
      end,
    },
    ["romdump.src.digest.Hashing"] = {
      sha1hex = function(bytes)
        return "sha-" .. bytes
      end,
    },
    ["romdump.src.digest.Lz11"] = {
      decode = function(bytes)
        assert(bytes == "lzmodel" or bytes:sub(1, 2) == "lz")
        if bytes == "lzmodel" then
          return "model"
        end
        return bytes
      end,
    },
  }
  local previous = {}
  local compilerName = "romdump.src.digest.field.LugiaAppearanceAssetCompiler"
  previous[compilerName] = package.loaded[compilerName]
  package.loaded[compilerName] = nil
  local coreName = "romdump.src.digest.field.LegendAppearanceCompiler"
  previous[coreName] = package.loaded[coreName]
  package.loaded[coreName] = nil
  for name, module in pairs(modules) do
    previous[name] = package.loaded[name]
    package.loaded[name] = module
  end
  local archive = {
    memberCount = function()
      return 100
    end,
    readMember = function(_, memberId)
      return memberBytes[memberId]
    end,
  }
  local ok, result = pcall(function()
    return require("romdump.src.digest.field.LugiaAppearanceAssetCompiler").compile({
      openNarc = function(_, name)
        openNames[#openNames + 1] = name
        return archive
      end,
    })
  end)
  for name in pairs(modules) do
    package.loaded[name] = previous[name]
  end
  package.loaded[compilerName] = previous[compilerName]
  package.loaded[coreName] = previous[coreName]
  return ok, result
end

local function lugiaMembers()
  return {
    [28] = "model",
    [29] = "lzcolor",
    [30] = "lzpattern",
    [31] = "lzjoint",
    [0] = "lzmodel",
    [1] = "lzjoint",
    [2] = "lzcolor",
    [3] = "lzsrt",
    [4] = "lzpattern",
    [5] = "lzmodel",
    [6] = "lzjoint",
  }
end

local function lugiaFormats()
  return { lzjoint = "NSBCA", lzcolor = "NSBMA", lzpattern = "NSBTP", lzsrt = "NSBTA" }
end

T.tests["compiles the eye glimmer and Lugia cinematic with their ordered roles"] = function()
  local openNames = {}
  local ok, compiled = compileWith(lugiaMembers(), lugiaFormats(), openNames)
  Assert.isTrue(ok, tostring(compiled))
  Assert.deepEqual(openNames, { "NARC_demo_legend", "NARC_a_2_4_4" })
  local models = assert(compiled.definition.models)
  Assert.equal(#models, 3, "the definition keeps each Lugia source model separate")
  Assert.equal(models[1].key, "field-effect:lugia-appearance:eyeGlimmer")
  Assert.deepEqual(
    { models[1].animations[1].id, models[1].animations[2].id, models[1].animations[3].id },
    { "eye.color", "eye.pattern", "eye.joint" }
  )
  Assert.equal(models[2].key, "field-effect:lugia-appearance:cinematic.lugia.0")
  Assert.deepEqual(
    {
      models[2].animations[1].id,
      models[2].animations[2].id,
      models[2].animations[3].id,
      models[2].animations[4].id,
    },
    { "lugia.joint", "lugia.color", "lugia.srt", "lugia.pattern" }
  )
  Assert.equal(models[3].key, "field-effect:lugia-appearance:cinematic.lugia.1")
  Assert.equal(models[3].animations[1].id, "lugia.far.joint")
  for _, model in ipairs(models) do
    for _, clip in ipairs(model.animations) do
      Assert.isNil(clip.source, "the runtime descriptor omits physical source identity")
    end
  end
  Assert.isNil(compiled.definition.leaves, "the Lugia reveal has no leaf overlay")
end

T.tests["rejects a Lugia source member with the wrong Nitro animation format"] = function()
  local members = lugiaMembers()
  members[30] = "lzjoint"
  local formats = lugiaFormats()
  formats.lzjoint = "NSBCA"
  local ok, err = compileWith(members, { lzjoint = "NSBCA", lzcolor = "NSBMA", lzpattern = "NSBCA", lzsrt = "NSBTA" }, {})
  Assert.isFalse(ok)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "FIELD_EFFECT_SOURCE_INVALID")
  Assert.equal(err.context.archive, "NARC_demo_legend")
  Assert.equal(err.context.memberId, 30)
  Assert.equal(err.context.expectedFormat, "NSBTP")
end

return T
