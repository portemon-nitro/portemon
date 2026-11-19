-- Script composition contracts : production uses generated vanilla resources,
-- ordinary map intents derive their ids from source identity, explicit
-- test-owned overrides retain precedence, and unsupported generated nodes
-- remain scheduler faults.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local ScriptCacheFixture = require("tests.support.ScriptCacheFixture")
local ScriptOverrides = require("libs.assets.src.ScriptOverrides")
local Registry = require("libs.script.src.Registry")
local Composition = require("libs.script.src.Composition")
local ScriptLoader = require("libs.script.src.ScriptLoader")
local Bindings = require("libs.hgss.src.script.Bindings")
local TaskRegistry = require("libs.script.src.TaskRegistry")
local Scheduler = require("libs.script.src.Scheduler")
local FakeServices = require("tests.support.script.FakeServices")
local RepoFs = require("libs.storage.src.RepoFs")
local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")
local S = require("gen4.script")

local T = {
  metadata = { tags = { "script", "composition", "vanilla" } },
  tests = {},
}
local GENERATION = string.rep("a", 40)

local PRODUCTION_IDS = {
  "demo.signpost",
  "elms_lab.elm",
  "vanilla.hgss.scr_seq.0842.script_017",
}

local function productionFs()
  return RepoFs.new(love.filesystem.getSourceBaseDirectory())
end

local function generatedResource(id)
  return S.script({ api = 1, id = id, steps = { S.stop() } })
end

local function cacheWithScripts(files)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local scripts = {}
  for id, steps in pairs(files) do
    scripts[#scripts + 1] = { id = id, steps = steps }
  end
  ScriptCacheFixture.writeSingleMember(cache, GENERATION, "synthetic-script-cache", scripts)
  return cache
end

local function overrideFs(files)
  local ids = {}
  for id in pairs(files) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  local manifest = "return {"
  for _, id in ipairs(ids) do
    manifest = manifest .. string.format(" %q,", id)
  end
  manifest = manifest .. " }\n"
  return {
    read = function(_, path)
      if path == ScriptOverrides.MANIFEST then
        return manifest
      end
      local id = path:match("^data/scripts/overrides/(.+)%.lua$")
      return id and files[id] or nil
    end,
  }
end

function T.tests.production_registry_keeps_vanilla_generated_resources_outside_its_overrides()
  local registry = Registry.new()
  for _, id in ipairs(PRODUCTION_IDS) do
    registry:installBase(id, generatedResource(id), "generated")
  end

  -- Every checked-in override loads, and none replaces a covered vanilla resource.
  local installed = ScriptLoader.installOverrides(registry, productionFs())
  for _, id in ipairs(installed) do
    for _, productionId in ipairs(PRODUCTION_IDS) do
      Assert.isTrue(id ~= productionId, "production overrides leave " .. productionId .. " generated")
    end
  end
  for _, id in ipairs(PRODUCTION_IDS) do
    local resource = assert(registry:base(id))
    Assert.isFalse(resource.metadata ~= nil and resource.metadata.override == true)
  end
end

function T.tests.map_intents_match_the_compiler_canonical_id()
  local expected = "vanilla.hgss.scr_seq.0842.script_001"
  Assert.equal(ScriptCompiler.publicId(842, 1), expected)

  local bindings = Bindings.new()
  local intent = {
    kind = "object",
    mapId = 60,
    scriptBankId = 842,
    scriptId = 2,
    playerFacing = "north",
    object = { actorId = "map:60:object:1", objectEventId = 1, spriteId = 1 },
  }
  local hit = assert(bindings:resolveIntent(intent, intent.playerFacing), "map intent must resolve mechanically")
  Assert.equal(hit.scriptId, expected)
  Assert.equal(hit.trigger.scriptId, expected)
end

function T.tests.zero_raw_script_id_resolves_to_the_inert_interaction()
  local bindings = Bindings.new()
  local intent = {
    kind = "background",
    mapId = 60,
    scriptBankId = 842,
    scriptId = 0,
    playerFacing = "north",
    background = { eventIndex = 0, type = 1, direction = 4 },
  }
  local resolved = assert(bindings:resolveIntent(intent, intent.playerFacing))
  Assert.equal(resolved.scriptId, "runtime.inert_interaction")
end

function T.tests.synthetic_override_keeps_explicit_precedence()
  local id = "test.generated.script"
  local generated = cacheWithScripts({
    [id] = "S.stop()",
  })
  local withoutOverride = ScriptLoader.buildRegistry(generated, overrideFs({}))
  Assert.equal(assert(withoutOverride:base(id)).steps[1].op, "stop")

  local withOverride = ScriptLoader.buildRegistry(
    generated,
    overrideFs({
      [id] = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = "'
        .. id
        .. '", steps = { S.yieldTick() } }\n',
    })
  )
  Assert.equal(assert(withOverride:base(id)).steps[1].op, "yield_tick")
end

function T.tests.malformed_override_loads_without_authoring_validation_and_fails_at_the_compiler_boundary()
  local content =
    'local S = require("gen4.script")\nreturn S.script { api = 1, id = "test.deferred_validation", steps = { S.setVar({}) } }\n'
  local resource = ScriptLoader.loadOverride("test.deferred_validation", content, requireOverride)
  Assert.equal(resource.id, "test.deferred_validation")
  local valid, validateErr = S.validate(resource)
  Assert.isNil(valid, "explicit authoring validation still diagnoses the malformed override")
  Assert.notNil(validateErr)
  Assert.equal(validateErr.code, "SCRIPT_SCHEMA_INVALID")
  local Compiler = require("libs.script.src.Compiler")
  local graph, compileErr = Compiler.compile(resource, { allowNext = false })
  Assert.isNil(graph, "malformed content still fails at the compiler boundary")
  Assert.notNil(compileErr)
  Assert.equal(compileErr.code, "SCRIPT_SCHEMA_INVALID")
end

function T.tests.generated_unsupported_node_is_a_scheduler_fault()
  local id = "vanilla.hgss.scr_seq.0842.script_016"
  local cache = cacheWithScripts({
    [id] = 'S.unsupported({ command = 999, originalName = "SyntheticUnsupported" })',
  })
  local registry = ScriptLoader.buildRegistry(cache, productionFs())
  local composition = Composition.new(registry)
  local services = FakeServices.new()
  services.signpost = {
    setSourceAppearance = function() end,
    setCommand = function() end,
    isCommandIdle = function()
      return true
    end,
  }
  local scheduler = Scheduler.new({
    services = services,
    taskRegistry = TaskRegistry.new(),
    resolveComposition = function(scriptId)
      return composition:effective(scriptId)
    end,
  })
  local composed = assert(composition:effective(id))
  local instanceId = scheduler:createForeground(composed, nil, 100)
  scheduler:step(100, nil)

  local fault = assert(services.events:eventFor("script.error", instanceId))
  Assert.equal(fault.code, "SCRIPT_UNSUPPORTED_REACHABLE")
  Assert.equal(fault.context.scriptId, id)
  Assert.isNil(scheduler:foregroundEnvironmentId(), "unsupported execution must release foreground ownership")
  Assert.equal(#scheduler:instances(), 0, "faulted root must be cleaned up")
  Assert.equal(#scheduler:tasks(), 0, "unsupported execution must not leave tasks behind")
end

return T
