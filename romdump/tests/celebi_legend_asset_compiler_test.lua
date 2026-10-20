local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")

local T = { tests = {} }

local function compileWith(memberBytes, animationFormat)
  local modules = {
    ["libs.nds.src.nitro.g3d.Nsbmd"] = {
      decode = function(bytes)
        assert(bytes == "model")
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
        return {
          id = options.id,
          name = options.name,
          category = decoded.format == "NSBCA" and "joint" or "material",
          kind = decoded.format == "NSBCA" and "trs" or (decoded.format == "NSBTP" and "pattern" or "texsrt"),
          semanticNames = options.semanticNames,
          frameCount = 4,
          tracks = { { target = options.name } },
          source = options.source,
          compiled = { targets = {} },
        }
      end,
    },
    ["romdump.src.digest.model.DynamicModelCompiler"] = {
      compile = function(model, decoded, textures, animations, context, memberId, textureOutput, meshOutput)
        Assert.equal(memberId, 75)
        Assert.equal(#animations.clips, 3)
        textureOutput.texture = { pixels = "pixel" }
        meshOutput.mesh = {}
        return {
          schema = "g4-model-v6",
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
        Assert.equal(#descriptor.animations, 3)
      end,
    },
  }
  local previous = {}
  local compilerName = "romdump.src.digest.field.CelebiTimeTravelAssetCompiler"
  previous[compilerName] = package.loaded[compilerName]
  package.loaded[compilerName] = nil
  for name, module in pairs(modules) do
    previous[name] = package.loaded[name]
    package.loaded[name] = module
  end
  local hashingName = "romdump.src.digest.Hashing"
  previous[hashingName] = package.loaded[hashingName]
  package.loaded[hashingName] = {
    sha1hex = function(bytes)
      return "sha-" .. bytes
    end,
  }
  local archive = {
    memberCount = function()
      return 100
    end,
    readMember = function(_, memberId)
      return memberBytes[memberId]
    end,
  }
  local ok, result = pcall(function()
    return require("romdump.src.digest.field.CelebiTimeTravelAssetCompiler").compile({
      openNarc = function(_, name)
        Assert.equal(name, "NARC_demo_legend")
        return archive
      end,
    })
  end)
  for name in pairs(modules) do
    package.loaded[name] = previous[name]
  end
  package.loaded[compilerName] = previous[compilerName]
  package.loaded[hashingName] = previous[hashingName]
  return ok, result
end

T.tests["compiles the original legend model with all ordered animation roles"] = function()
  local ok, compiled = compileWith({ [75] = "model", [76] = "joint", [78] = "pattern", [77] = "srt" }, {
    joint = "NSBCA",
    pattern = "NSBTP",
    srt = "NSBTA",
  })
  Assert.isTrue(ok, tostring(compiled))
  Assert.equal(compiled.definition.model.key, "field-effect:celebi-time-travel")
  Assert.deepEqual(
    { compiled.definition.model.animations[1].id, compiled.definition.model.animations[2].id, compiled.definition.model.animations[3].id },
    { "celebi.joint", "celebi.pattern", "celebi.srt" }
  )
  for _, clip in ipairs(compiled.definition.model.animations) do
    Assert.isNil(clip.source, "the runtime descriptor omits physical source identity")
  end
  Assert.deepEqual(compiled.memberHashes, {
    { memberId = 75, sha1 = "sha-model" },
    { memberId = 76, sha1 = "sha-joint" },
    { memberId = 78, sha1 = "sha-pattern" },
    { memberId = 77, sha1 = "sha-srt" },
  })
end

T.tests["rejects a source member with the wrong Nitro animation format"] = function()
  local ok, err = compileWith({ [75] = "model", [76] = "joint", [78] = "pattern", [77] = "srt" }, {
    joint = "NSBCA",
    pattern = "NSBCA",
    srt = "NSBTA",
  })
  Assert.isFalse(ok)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "FIELD_EFFECT_SOURCE_INVALID")
  Assert.equal(err.context.archive, "NARC_demo_legend")
  Assert.equal(err.context.memberId, 78)
  Assert.equal(err.context.expectedFormat, "NSBTP")
end

return T
