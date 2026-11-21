-- Field script platform construction: the game builds its registry,
-- composition, and task registry directly from the production owners. The
-- registry installs lazily, so construction reads no member bundles; first
-- use decodes exactly its own member.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local Composition = require("libs.script.src.Composition")
local FakeCache = require("tests.support.FakeCache")
local HgssScript = require("libs.hgss.src.script.Composition")
local ScriptCacheFixture = require("tests.support.ScriptCacheFixture")
local ScriptLoader = require("libs.script.src.ScriptLoader")
local ScriptOverrides = require("libs.assets.src.ScriptOverrides")
local TaskRegistry = require("libs.script.src.TaskRegistry")

local T = {}
local GENERATION = string.rep("a", 40)
local MARKER = "script-cache-v4:rom-sha:dep-sha"

local SCRIPT_ID = "new_bark.lab_sign"

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

local function scriptCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  ScriptCacheFixture.writeSingleMember(cache, GENERATION, MARKER, { { id = SCRIPT_ID, steps = "S.stop()" } })
  return cache
end

-- Count generated member-bundle reads through the cache backend from here on.
local function countScriptReads(cache)
  local reads = 0
  local originalRead = cache.backend.read
  cache.backend.read = function(self, path)
    if path:find("/generations/", 1, true) then
      reads = reads + 1
    end
    return originalRead(self, path)
  end
  return function()
    return reads
  end
end

-- The exact direct construction the game performs: lazy registry from the
-- published cache plus builtins, composition over it, and the production
-- task registry.
local function construct(cache, fs)
  local registry = ScriptLoader.buildRegistry(cache, fs, nil, {
    lazy = true,
    builtins = HgssScript.builtins(),
  })
  local composition = Composition.new(registry)
  local taskRegistry = HgssScript.registerTasks(TaskRegistry.new())
  return registry, composition, taskRegistry
end

T["construction reads no generated bodies and first use decodes one body"] = function()
  local cache = scriptCache()
  local fs = overrideFs()
  local scriptReads = countScriptReads(cache)
  local registry, composition = construct(cache, fs)
  Assert.equal(scriptReads(), 0, "construction must not decode generated bodies")
  Assert.notNil(registry:base(SCRIPT_ID))
  Assert.equal(scriptReads(), 1, "first use decodes exactly its own body")
  Assert.notNil(composition:effective(SCRIPT_ID), "the composition serves the lazily loaded script")
end

T["construction registers the production task set"] = function()
  local cache = scriptCache()
  local _, _, taskRegistry = construct(cache, overrideFs())
  Assert.notNil(taskRegistry:resolve("wait_ticks", 1), "the production task set resolves wait_ticks")
  Assert.notNil(
    taskRegistry:resolve("elevator_anim", 1),
    "the production task set resolves the source elevator animation"
  )
  Assert.notNil(
    taskRegistry:resolve("gym_mechanism", 1),
    "the production task set resolves the blocking gym mechanism ride"
  )
end

return { tests = T }
