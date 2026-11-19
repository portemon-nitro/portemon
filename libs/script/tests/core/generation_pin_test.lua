-- Runtime generation-pinning contract: a registry keeps the active selection
-- observed at construction even when a later generation is activated.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptCacheFixture = require("tests.support.ScriptCacheFixture")
local ScriptOverrides = require("libs.assets.src.ScriptOverrides")
local ScriptLoader = require("libs.script.src.ScriptLoader")

local T = {}

local SCRIPT_ID = "vanilla.test.generation_pin"
local GENERATION_A = string.rep("a", 40)
local GENERATION_B = string.rep("b", 40)

-- Each generation compiles distinct step bodies for the same logical id, so
-- the bytes a pinned registry serves identify its generation.
local function scriptSteps(generation)
  return 'S.playSound { sound = "SEQ_' .. generation .. '" }, S.stop()'
end

local function writeSelection(cache, generation, marker)
  ScriptCacheFixture.writeSingleMember(cache, generation, marker, {
    { id = SCRIPT_ID, steps = scriptSteps(generation) },
  })
end

local function servedGeneration(resource)
  return resource.steps[1].sound
end

local function overrideFs()
  return {
    read = function(_, path)
      if path == ScriptOverrides.MANIFEST then
        return "return {}\n"
      end
      return nil
    end,
  }
end

function T.registry_pins_the_generation_seen_before_activation()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  writeSelection(cache, GENERATION_A, "marker-a")

  local oldRegistry = ScriptLoader.buildRegistry(cache, overrideFs(), nil, { lazy = true })
  writeSelection(cache, GENERATION_B, "marker-b")

  local oldResource = assert(oldRegistry:base(SCRIPT_ID))
  Assert.equal(
    servedGeneration(oldResource),
    "SEQ_" .. GENERATION_A,
    "a running registry must remain pinned to generation A"
  )

  local newRegistry = ScriptLoader.buildRegistry(cache, overrideFs(), nil, { lazy = true })
  local newResource = assert(newRegistry:base(SCRIPT_ID))
  Assert.equal(servedGeneration(newResource), "SEQ_" .. GENERATION_B, "a later registry observes generation B")
  Assert.isTrue(
    servedGeneration(oldResource) ~= servedGeneration(newResource),
    "generation activation changes the resolved resource generation"
  )
  local oldAgain = assert(oldRegistry:base(SCRIPT_ID))
  Assert.equal(servedGeneration(oldAgain), "SEQ_" .. GENERATION_A, "repeat access stays pinned to generation A")
end

-- The pinned member lookup carries the indexed source identity, so a resolved
-- generated resource keeps the identity its node ids are built from.
function T.resolved_generated_resource_carries_its_indexed_source_identity()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  writeSelection(cache, GENERATION_A, "marker-a")
  local registry = ScriptLoader.buildRegistry(cache, overrideFs(), nil, { lazy = true })
  local resource = assert(registry:base(SCRIPT_ID))
  Assert.equal(resource.metadata.generated, true)
  Assert.equal(resource.metadata.source.member, 0)
  Assert.equal(resource.metadata.source.scriptIndex, 0)
end

return { tests = T }
