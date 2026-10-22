-- Effect artifacts own their decoded resource payloads and stage them before publication.

local Assert = require("tests.support.Assert")
local T = {}

function T.stage_effect_owns_and_writes_each_decoded_resource_payload()
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local files = {}
  local owned = {}
  local artifact = {
    stageFs = function()
      return {
        write = function(_, path, bytes)
          files[path] = bytes
        end,
        writeLua = function(_, path, value)
          files[path] = value
        end,
      }
    end,
    addOwnedRoot = function(_, path)
      owned[path] = true
    end,
  }
  local payloadPath = "data/generated/battle/resources/scene/chars.lua"
  local payload = { format = "nitro-char-4bpp-v1", bytes = "decoded" }
  local effect = {
    key = "TACKLE",
    schema = "test",
    catalogIdentity = "test-catalog",
    program = { entry = "main", instructions = {}, subprograms = {}, taskKinds = {} },
    dependencies = { "battle/scene/chars" },
    resources = {
      ["battle/scene/chars"] = {
        kind = "character",
        contentIdentity = string.rep("a", 40),
        payload = payloadPath,
      },
    },
    resourcePayloads = { [payloadPath] = payload },
    requiredContext = {},
  }

  compiler.stageEffect(artifact, effect, "marker")

  Assert.equal(files[payloadPath], payload, "decoded resource payload is staged as its own artifact root")
  Assert.isTrue(owned[payloadPath], "artifact cleanup owns the staged resource payload")
end

function T.stage_effect_rejects_unreferenced_payloads()
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local stage = { write = function() end, writeLua = function() end }
  local artifact = {
    stageFs = function()
      return stage
    end,
    addOwnedRoot = function() end,
  }
  local effect = {
    key = "TACKLE",
    resources = { ["battle/texture/chars"] = { payload = "data/generated/battle/resources/chars.lua" } },
    resourcePayloads = {
      ["data/generated/battle/resources/chars.lua"] = { bytes = "decoded" },
      ["data/generated/battle/resources/orphan.lua"] = { bytes = "unreferenced" },
    },
  }

  local ok = pcall(compiler.stageEffect, artifact, effect, "marker")

  Assert.isFalse(ok, "every staged payload must belong to a semantic resource descriptor")
end

return { tests = T }
