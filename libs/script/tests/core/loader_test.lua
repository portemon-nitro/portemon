-- ScriptLoader tests (the script override system): generated bases load from
-- the compiled script cache, checked-in overrides under
-- `data/scripts/overrides/<id>.lua` override the script with the same id (or
-- introduce it when no base exists), the override layer beats the generated
-- base, and malformed override files fail loudly instead of silently keeping
-- the base.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local Errors = require("libs.errors.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local LuaWriter = require("libs.codec.src.LuaWriter")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptLoader = require("libs.script.src.ScriptLoader")
local ScriptOverrides = require("libs.assets.src.ScriptOverrides")
local ScriptSave = require("libs.script.src.ScriptSave")
local Sha256 = require("libs.script.src.Sha256")

local T = {}
local GENERATION = string.rep("a", 40)
local MARKER = "script-cache-v4:rom-sha:dep-sha"

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "expected a raised error")
  local errorObject = err --[[@as Errors.Error]]
  Assert.equal(errorObject.code, code)
end

-- A fake cache carrying a two-resource script class (the index schema and
-- script file shapes match the compiled cache writer).
local function scriptCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local resources = {
    { id = "vanilla.hgss.scr_seq.0842.script_001", member = 0, scriptIndex = 0 },
    { id = "new_bark.lab_sign", member = 0, scriptIndex = 1 },
  }
  cache:writeLua(ScriptCache.activeIndexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = GENERATION,
    marker = MARKER,
  })
  cache:write(ScriptCache.markerPath(), MARKER)
  cache:write(ScriptCache.generationMarkerPath(GENERATION), MARKER)
  cache:writeLua(ScriptCache.generationIndexPath(GENERATION), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = GENERATION,
    marker = MARKER,
    resources = {
      resources[1],
      resources[2],
    },
  })
  cache:write(
    ScriptCache.scriptPath(GENERATION, 0, resources[1].id),
    'local S = require("gen4.script")\nreturn S.script { api = 1, id = "vanilla.hgss.scr_seq.0842.script_001", steps = { S.stop() } }\n'
  )
  cache:write(
    ScriptCache.scriptPath(GENERATION, 0, resources[2].id),
    'local S = require("gen4.script")\nreturn S.script { api = 1, id = "new_bark.lab_sign", steps = { S.say { message = "msg.hgss.0543.00097" }, S.stop() } }\n'
  )
  return cache
end

-- A read-shaped filesystem for the override tree: the manifest and the
-- override files. `manifestText` overrides the derived manifest when the
-- test needs a malformed one.
local function overrideFs(files, manifestText)
  files = files or {}
  if manifestText == nil then
    local manifest = {}
    for name in pairs(files) do
      local id = name:match("^(.*)%.lua$")
      if id ~= nil then
        manifest[#manifest + 1] = id
      end
    end
    table.sort(manifest)
    manifestText = "return {\n"
    for _, id in ipairs(manifest) do
      manifestText = manifestText .. "  " .. string.format("%q", id) .. ",\n"
    end
    manifestText = manifestText .. "}\n"
  end
  return {
    read = function(_, path)
      if path == ScriptOverrides.MANIFEST then
        return manifestText
      end
      for name, content in pairs(files) do
        if path == "data/scripts/overrides/" .. name then
          return content
        end
      end
      return nil
    end,
  }
end

local function requireShim(name)
  if name == "gen4.script" then
    return require("gen4.script")
  end
  error("unexpected require in override chunk: " .. name)
end

-- 1. Generated bases install from the cache index and files.
T["generated bases load from the script cache"] = function()
  local Registry = require("libs.script.src.Registry")
  local registry = Registry.new()
  ScriptLoader.installGenerated(registry, scriptCache(), requireShim)
  Assert.notNil(registry:base("new_bark.lab_sign"))
  Assert.notNil(registry:base("vanilla.hgss.scr_seq.0842.script_001"))
  Assert.isNil(registry:base("vanilla.hgss.scr_seq.0842.script_002"))
end

-- 2. An override file replaces the script with the same id, and beats the
-- generated base.
T["override replaces the base script with the same id"] = function()
  local Registry = require("libs.script.src.Registry")
  local registry = Registry.new()
  ScriptLoader.installGenerated(registry, scriptCache(), requireShim)
  local fs = overrideFs({
    ["new_bark.lab_sign.lua"] = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = "new_bark.lab_sign", steps = { S.noop(), S.stop() } }\n',
  })
  local ids = ScriptLoader.installOverrides(registry, fs, requireShim)
  Assert.deepEqual(ids, { "new_bark.lab_sign" })
  local base = assert(registry:base("new_bark.lab_sign"))
  Assert.equal(base.steps[1].op, "noop", "the override wins over the generated base")
end

-- 2b. The override manifest is evaluated in the same restricted environment
-- as resource chunks: a manifest relying on a global must fail loudly
-- instead of loading through the ordinary global environment.
T["override manifest runs in the restricted environment"] = function()
  local Registry = require("libs.script.src.Registry")
  local registry = Registry.new()
  local fs = overrideFs({
    ["elms_lab.elm.lua"] = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = "elms_lab.elm", steps = { S.stop() } }\n',
  }, 'return { string.lower("ELMS_LAB.ELM") }\n')
  throwsCode("SCRIPT_LOAD_FAILED", function()
    ScriptLoader.installOverrides(registry, fs, requireShim)
  end)
end

-- 3. An override may introduce an id with no generated base (the curated
-- Elm replacement pattern).
T["override introduces an id without a base"] = function()
  local Registry = require("libs.script.src.Registry")
  local registry = Registry.new()
  ScriptLoader.installGenerated(registry, scriptCache(), requireShim)
  local fs = overrideFs({
    ["elms_lab.elm.lua"] = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = "elms_lab.elm", steps = { S.stop() } }\n',
  })
  ScriptLoader.installOverrides(registry, fs, requireShim)
  Assert.notNil(registry:base("elms_lab.elm"))
end

-- 4. An override whose file id disagrees with the resource id fails loudly.
T["override id mismatch is a hard error"] = function()
  local Registry = require("libs.script.src.Registry")
  local registry = Registry.new()
  local fs = overrideFs({
    ["elms_lab.elm.lua"] = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = "other.id", steps = { S.stop() } }\n',
  })
  throwsCode("SCRIPT_LOAD_FAILED", function()
    ScriptLoader.installOverrides(registry, fs, requireShim)
  end)
end

-- 5. An override that fails authoring validation still installs: strict
-- diagnosis is authoring-only, so the malformed resource fails at the
-- compiler boundary instead of failing the load.
T["invalid override installs and fails at the compiler boundary"] = function()
  local Compiler = require("libs.script.src.Compiler")
  local Registry = require("libs.script.src.Registry")
  local registry = Registry.new()
  local fs = overrideFs({
    ["elms_lab.elm.lua"] = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = "elms_lab.elm", steps = { S.setVar {  } } }\n',
  })
  local ids = ScriptLoader.installOverrides(registry, fs, requireShim)
  Assert.deepEqual(ids, { "elms_lab.elm" })
  local resource = assert(registry:base("elms_lab.elm"))
  local graph, compileErr = Compiler.compile(resource, { allowNext = false })
  Assert.isNil(graph, "a malformed override must fail where it is used")
  Assert.notNil(compileErr)
  Assert.equal(compileErr.code, "SCRIPT_SCHEMA_INVALID")
end

-- 6. buildRegistry composes the full pipeline and the effective composition
-- resolves the override.
T["buildRegistry composes the override"] = function()
  local Composition = require("libs.script.src.Composition")
  local registry = ScriptLoader.buildRegistry(
    scriptCache(),
    overrideFs({
      ["new_bark.lab_sign.lua"] = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = "new_bark.lab_sign", steps = { S.noop(), S.stop() } }\n',
    }),
    requireShim
  ) --[[@as Registry]]
  local composition = Composition.new(registry)
  local effective = assert(composition:effective("new_bark.lab_sign"))
  Assert.equal(effective.entries[1].operation, "base")
  Assert.equal(effective.entries[1].graph.nodes[effective.entries[1].graph.entry].op, "noop")
end

-- 7. buildRegistry passes the injected require through to the generated
-- cache files too: a require the allowlist would reject is observable.
T["buildRegistry injects require for generated files"] = function()
  local calls = {}
  local injected = function(name)
    calls[#calls + 1] = name
    return requireShim(name)
  end
  local registry = ScriptLoader.buildRegistry(scriptCache(), overrideFs({}), injected)
  Assert.notNil(registry:base("new_bark.lab_sign"))
  Assert.isTrue(#calls > 0, "the injected require ran for the generated files")
end

-- A cache whose generated script fails validation (the shape the compiled
-- cache writer can never emit, but a hand-tampered file could).
local function invalidScriptCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(ScriptCache.activeIndexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = GENERATION,
    marker = MARKER,
  })
  cache:write(ScriptCache.markerPath(), MARKER)
  cache:write(ScriptCache.generationMarkerPath(GENERATION), MARKER)
  cache:writeLua(ScriptCache.generationIndexPath(GENERATION), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = GENERATION,
    marker = MARKER,
    resources = { { id = "invalid.script", member = 0, scriptIndex = 0 } },
  })
  cache:write(
    ScriptCache.scriptPath(GENERATION, 0, "invalid.script"),
    'local S = require("gen4.script")\nreturn S.script { api = 1, id = "invalid.script", steps = { S.setVar { } } }\n'
  )
  return cache
end

-- 8. A lazy build decodes nothing until first use: no script file is read
-- at build time, and base() reads exactly its own file.
T["lazy build reads no script files until first use"] = function()
  local cache = scriptCache()
  local originalRead = cache.backend.read
  local scriptReads = 0
  cache.backend.read = function(self, path)
    if path:find("/scripts/", 1, true) then
      scriptReads = scriptReads + 1
    end
    return originalRead(self, path)
  end
  local registry = ScriptLoader.buildRegistry(cache, overrideFs({}), requireShim, { lazy = true })
  Assert.equal(scriptReads, 0, "a lazy build must not read any script file")
  Assert.notNil(registry:base("new_bark.lab_sign"))
  Assert.equal(scriptReads, 1, "base() reads exactly its own file")
end

-- 8b. The lazy trust policy: a generated script decodes on first use
-- without semantic validation (producer-validated before publication), so
-- even schema-invalid content resolves at the access point and fails only
-- where it is actually used.
T["lazy build trusts generated content on first use"] = function()
  local registry = ScriptLoader.buildRegistry(invalidScriptCache(), overrideFs({}), requireShim, { lazy = true })
  local base = assert(registry:base("invalid.script"))
  Assert.equal(base.id, "invalid.script")
end

-- 8c. The legacy validation toggle is accepted but inert on the lazy path:
-- published content resolves identically whether or not a caller passes it.
T["lazy build ignores the legacy validation toggle"] = function()
  local plain = ScriptLoader.buildRegistry(invalidScriptCache(), overrideFs({}), requireShim, { lazy = true })
  local toggled = ScriptLoader.buildRegistry(invalidScriptCache(), overrideFs({}), requireShim, {
    lazy = true,
    validateGenerated = false,
  })
  Assert.equal(assert(plain:base("invalid.script")).id, assert(toggled:base("invalid.script")).id)
end

-- 8d. The eager path trusts generated content the same way: a
-- schema-invalid resource installs instead of failing the build.
T["eager build trusts generated content by default"] = function()
  local registry = ScriptLoader.buildRegistry(invalidScriptCache(), overrideFs({}), requireShim)
  Assert.equal(assert(registry:base("invalid.script")).id, "invalid.script")
end

-- 8e. The lazy path never skips the checked-in override layer: overrides
-- install eagerly on every boot and fail at the composition boundary, not
-- at build time.
T["lazy build installs overrides eagerly without build-time validation"] = function()
  local Composition = require("libs.script.src.Composition")
  local registry = ScriptLoader.buildRegistry(
    scriptCache(),
    overrideFs({
      ["bad.override.lua"] = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = "bad.override", steps = { S.setVar { } } }\n',
    }),
    requireShim,
    { lazy = true }
  )
  Assert.notNil(registry:base("bad.override"))
  local composition = Composition.new(registry)
  throwsCode("SCRIPT_SCHEMA_INVALID", function()
    composition:effective("bad.override")
  end)
end

-- 9. An index without the resources array is malformed generated data, never
-- an empty registry: installGenerated fails before installing anything.
T["index without resources fails before any install"] = function()
  local Registry = require("libs.script.src.Registry")
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(ScriptCache.activeIndexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = GENERATION,
    marker = MARKER,
  })
  cache:write(ScriptCache.markerPath(), MARKER)
  cache:write(ScriptCache.generationMarkerPath(GENERATION), MARKER)
  cache:writeLua(ScriptCache.generationIndexPath(GENERATION), { schema = ScriptCache.INDEX_SCHEMA })
  local registry = Registry.new()
  throwsCode("SCRIPT_LOAD_FAILED", function()
    ScriptLoader.installGenerated(registry, cache, requireShim)
  end)
  Assert.deepEqual(registry:ids(), {}, "no bases are installed from a malformed index")
end

-- 9b. The lazy build path applies the same strict index rule.
T["lazy build rejects an index without resources"] = function()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(ScriptCache.activeIndexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = GENERATION,
    marker = MARKER,
  })
  cache:write(ScriptCache.markerPath(), MARKER)
  cache:write(ScriptCache.generationMarkerPath(GENERATION), MARKER)
  cache:writeLua(ScriptCache.generationIndexPath(GENERATION), { schema = ScriptCache.INDEX_SCHEMA })
  throwsCode("SCRIPT_LOAD_FAILED", function()
    ScriptLoader.buildRegistry(cache, overrideFs({}), requireShim, { lazy = true })
  end)
end

-- A generated cache whose index entries carry the published canonical hash
-- of each decoded resource. The hash stays generated-cache provenance
-- metadata: the loader installs membership from the index and decodes
-- bodies on demand.
local HASHED_FILES = {
  ["vanilla.hgss.scr_seq.0842.script_001"] = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = "vanilla.hgss.scr_seq.0842.script_001", steps = { S.stop() } }\n',
  ["new_bark.lab_sign"] = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = "new_bark.lab_sign", steps = { S.say { message = "msg.hgss.0543.00097" }, S.stop() } }\n',
}

local HASHED_OVERRIDE =
  'local S = require("gen4.script")\nreturn S.script { api = 1, id = "new_bark.lab_sign", steps = { S.noop(), S.stop() } }\n'

local function builtinScripts()
  local S = require("gen4.script")
  return {
    all = function()
      return {
        ["test.builtin.ping"] = S.script({ api = 1, id = "test.builtin.ping", steps = { S.stop() } }),
      }
    end,
  }
end

-- `order` optionally reorders the index entries to prove the registry
-- identity does not depend on index enumeration order.
local function hashedCache(order)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local ids = {}
  for id in pairs(HASHED_FILES) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  for _, id in ipairs(ids) do
    cache:write(ScriptCache.scriptPath(GENERATION, 0, id), HASHED_FILES[id])
  end
  local entries = {}
  for index, id in ipairs(ids) do
    local resource = assert(ScriptLoader.loadGeneratedFrom(cache, GENERATION, 0, id, requireShim))
    entries[#entries + 1] = {
      id = id,
      member = 0,
      scriptIndex = index - 1,
      resourceHash = Sha256.hex(LuaWriter.encode(resource)),
    }
  end
  if order == "reversed" then
    local reversed = {}
    for index = #entries, 1, -1 do
      reversed[#reversed + 1] = entries[index]
    end
    entries = reversed
  end
  cache:writeLua(ScriptCache.activeIndexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = GENERATION,
    marker = MARKER,
  })
  cache:write(ScriptCache.markerPath(), MARKER)
  cache:write(ScriptCache.generationMarkerPath(GENERATION), MARKER)
  cache:writeLua(ScriptCache.generationIndexPath(GENERATION), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = GENERATION,
    marker = MARKER,
    resources = entries,
  })
  return cache
end

local function hashedOverrideFs()
  return overrideFs({ ["new_bark.lab_sign.lua"] = HASHED_OVERRIDE })
end

-- Count generated body reads through the cache backend from here on.
local function countScriptReads(cache)
  local reads = 0
  local originalRead = cache.backend.read
  cache.backend.read = function(self, path)
    if path:find("/scripts/", 1, true) then
      reads = reads + 1
    end
    return originalRead(self, path)
  end
  return function()
    return reads
  end
end

-- 10. A lazy build from published index hashes reads no generated body:
-- membership comes from the index, content decodes on first access, and
-- the override layer still wins without touching the generated file.
T["lazy build from published hashes decodes on demand"] = function()
  local cache = hashedCache()
  local scriptReads = countScriptReads(cache)
  local registry = ScriptLoader.buildRegistry(cache, hashedOverrideFs(), requireShim, {
    lazy = true,
    builtins = builtinScripts(),
  })
  Assert.equal(scriptReads(), 0, "building from published hashes must not read generated bodies")
  Assert.deepEqual(registry:ids(), {
    "new_bark.lab_sign",
    "test.builtin.ping",
    "vanilla.hgss.scr_seq.0842.script_001",
  })
  local base = assert(registry:base("new_bark.lab_sign"))
  Assert.equal(base.steps[1].op, "noop", "the override wins over the generated base")
  Assert.equal(scriptReads(), 0, "the override wins without reading the generated body")
  local generated = assert(registry:base("vanilla.hgss.scr_seq.0842.script_001"))
  Assert.equal(generated.id, "vanilla.hgss.scr_seq.0842.script_001")
  Assert.equal(generated.steps[1].op, "stop")
  Assert.equal(scriptReads(), 1, "first generated access reads exactly its own file")
end

-- 10b. Index enumeration order does not change resolved content: the same
-- resources resolve identically from a reversed index.
T["index order does not change resolved content"] = function()
  local forward = ScriptLoader.buildRegistry(hashedCache(), hashedOverrideFs(), requireShim, {
    lazy = true,
    builtins = builtinScripts(),
  })
  local reversed = ScriptLoader.buildRegistry(hashedCache("reversed"), hashedOverrideFs(), requireShim, {
    lazy = true,
    builtins = builtinScripts(),
  })
  Assert.deepEqual(reversed:ids(), forward:ids())
  for _, id in ipairs(forward:ids()) do
    Assert.equal(LuaWriter.encode(assert(reversed:base(id))), LuaWriter.encode(assert(forward:base(id))))
  end
end

-- 10c. Saves carry no registry identity: a current bucket validates with
-- no digest context under either lazy or eager construction.
T["saves validate without digests under either registry construction"] = function()
  local bucket = function()
    return {
      schema = ScriptSave.SCHEMA_NAME,
      capturedAtSimulationTick = 0,
      nextEnvironmentId = 0,
      nextInstanceId = 0,
      nextTaskId = 0,
      environments = {},
      instances = {},
      tasks = {},
    }
  end
  ScriptLoader.buildRegistry(hashedCache(), hashedOverrideFs(), requireShim, {
    lazy = true,
    builtins = builtinScripts(),
  })
  Assert.isNil(ScriptSave.validate(bucket(), {}), "a current bucket needs no digest context")
  ScriptLoader.buildRegistry(hashedCache(), hashedOverrideFs(), requireShim, {
    builtins = builtinScripts(),
  })
  Assert.isNil(ScriptSave.validate(bucket(), {}), "a current bucket needs no digest context")
end

-- 10d. A built registry exposes no aggregate digest surface: construction
-- ends at install and seal, with nothing to seed or query.
T["built registry exposes no digest surface"] = function()
  local registry = ScriptLoader.buildRegistry(hashedCache(), hashedOverrideFs(), requireShim, {
    lazy = true,
    builtins = builtinScripts(),
  })
  local surface = registry --[[@as table<string, unknown>]]
  Assert.isNil(surface["fingerprint"])
  Assert.isNil(surface["cacheScriptHash"])
  Assert.isNil(surface["restoreFingerprint"])
end

-- Generated script resources are producer-validated before publication,
-- so runtime decoding must route by pinned cache identity and script id
-- without rerunning the full semantic validator. The counter fails while
-- the loader still validates generated content.
T["script_loader trusts published generated resources without semantic validation"] = function()
  local Validator = require("libs.script.src.Validator")
  local Registry = require("libs.script.src.Registry")
  local calls = 0
  local original = Validator.validate
  rawset(Validator, "validate", function(...)
    calls = calls + 1
    return original(...)
  end)
  local ok, resource = pcall(function()
    return ScriptLoader.loadGeneratedFrom(scriptCache(), GENERATION, 0, "new_bark.lab_sign", requireShim)
  end)
  local registry = nil
  local installErr = nil
  if ok then
    registry = Registry.new()
    local installOk, err = pcall(ScriptLoader.installGenerated, registry, scriptCache(), requireShim)
    if not installOk then
      ok, installErr = false, err
    end
  end
  rawset(Validator, "validate", original)
  if not ok then
    error(installErr or resource, 0)
  end
  Assert.notNil(resource, "a published generated resource must decode through the runtime loader")
  Assert.equal(resource.id, "new_bark.lab_sign")
  local base = assert(registry:base("new_bark.lab_sign"))
  Assert.equal(base.id, "new_bark.lab_sign")
  Assert.equal(base.steps[1].op, "say")
  Assert.deepEqual(registry:ids(), {
    "new_bark.lab_sign",
    "vanilla.hgss.scr_seq.0842.script_001",
  })
  Assert.equal(calls, 0, "runtime generated loading must not rerun the semantic validator")
end

-- No replacement surface: ordinary loading must behave identically
-- whether or not a caller passes the old validation toggles, and strict
-- override diagnostics stay owned by direct validator coverage rather than
-- requiring game-runtime validation.
T["script_loader exposes no replacement validation surface; overrides stay authoring-owned"] = function()
  local Validator = require("libs.script.src.Validator")
  local knownEntryPoints = {
    loadGenerated = true,
    loadGeneratedFrom = true,
    installGenerated = true,
    loadOverride = true,
    installOverrides = true,
    buildRegistry = true,
  }
  for key in pairs(ScriptLoader) do
    Assert.isTrue(knownEntryPoints[key] == true, "no new runtime validation entry point: " .. tostring(key))
  end
  local function tryEagerBuild(opts)
    return pcall(ScriptLoader.buildRegistry, invalidScriptCache(), overrideFs({}), requireShim, opts)
  end
  local defaultOk = tryEagerBuild(nil)
  local toggleOk = tryEagerBuild({ validateGenerated = false })
  Assert.equal(
    defaultOk,
    toggleOk,
    "ordinary loading must not change behavior through a validation toggle"
  )
  Assert.isTrue(defaultOk, "published-path loading trusts its fixtures without semantic validation")
  local S = requireShim("gen4.script")
  local malformed = S.script({ api = 1, id = "bad.override", steps = { S.setVar({}) } })
  local valid, validateErr = Validator.validate(malformed)
  Assert.isNil(valid, "authoring coverage still diagnoses a malformed override directly")
  Assert.notNil(validateErr, "the direct validator failure carries the strict diagnostic")
end

-- 9c. An explicitly empty resources array is schema-legal and installs
-- nothing: an empty script corpus must not fail the load.
T["empty resources array installs zero bases"] = function()
  local Registry = require("libs.script.src.Registry")
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(ScriptCache.activeIndexPath(), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = GENERATION,
    marker = MARKER,
  })
  cache:write(ScriptCache.markerPath(), MARKER)
  cache:write(ScriptCache.generationMarkerPath(GENERATION), MARKER)
  cache:writeLua(ScriptCache.generationIndexPath(GENERATION), {
    schema = ScriptCache.INDEX_SCHEMA,
    generation = GENERATION,
    marker = MARKER,
    resources = {},
  })
  local registry = Registry.new()
  ScriptLoader.installGenerated(registry, cache, requireShim)
  Assert.deepEqual(registry:ids(), {})
end

-- A trusted override executes with the standard Lua libraries and a
-- host-provided module: math/string helpers plus a second trusted import
-- produce an id-matching DSL resource that still compiles; the same module
-- fails the restricted generated load, which sees neither host modules nor
-- standard libraries.
T["trusted override executes with standard libraries and a host-provided module"] = function()
  local Compiler = require("libs.script.src.Compiler")
  local helper = {
    word = "hello",
    pauseTicks = function()
      return 3
    end,
  }
  local trustedRequire = function(name)
    if name == "gen4.script" then
      return require("gen4.script")
    end
    if name == "trusted.helper" then
      return helper
    end
    error("unexpected require in trusted override: " .. name)
  end
  local content = table.concat({
    'local S = require("gen4.script")',
    'local helper = require("trusted.helper")',
    'local label = string.upper(helper.word) .. tostring(math.floor(2.7))',
    'assert(label == "HELLO2")',
    'return S.script { api = 1, id = "trusted.demo", steps = { S.say { message = "msg.hgss.0543.00097" }, S.stop() } }',
    "",
  }, "\n")
  local resource = ScriptLoader.loadOverride("trusted.demo", content, trustedRequire)
  Assert.equal(resource.id, "trusted.demo")
  local graph = assert(Compiler.compile(resource, { allowNext = false }))
  Assert.equal(graph.scriptId, "trusted.demo")
  local cache = scriptCache()
  cache:write(ScriptCache.scriptPath(GENERATION, 0, "trusted.demo"), content)
  local generated, loadErr = ScriptLoader.loadGeneratedFrom(cache, GENERATION, 0, "trusted.demo")
  Assert.isNil(generated, "the restricted generated load must reject host modules and standard libraries")
  Assert.notNil(loadErr)
end

-- An override-driven typed async task survives a snapshot/restore boundary:
-- the trusted override computes its wait from a host module, runs to the
-- same completion tick across capture/restore, and closure or coroutine
-- task state is still rejected by save validation.
T["override-driven typed task survives snapshot restore while closures stay unsavable"] = function()
  local Registry = require("libs.script.src.Registry")
  local Composition = require("libs.script.src.Composition")
  local TaskRegistry = require("libs.script.src.TaskRegistry")
  local Scheduler = require("libs.script.src.Scheduler")
  local ScriptSave = require("libs.script.src.ScriptSave")
  local WaitTicksTask = require("libs.script.src.tasks.WaitTicksTask")
  local FakeServices = require("tests.support.script.FakeServices")
  local helper = {
    pauseTicks = function()
      return 2
    end,
  }
  local trustedRequire = function(name)
    if name == "gen4.script" then
      return require("gen4.script")
    end
    if name == "trusted.helper" then
      return helper
    end
    error("unexpected require in trusted override: " .. name)
  end
  local content = table.concat({
    'local S = require("gen4.script")',
    'local helper = require("trusted.helper")',
    'local ticks = math.floor(helper.pauseTicks())',
    'return S.script { api = 1, id = "trusted.save_demo", steps = { S.waitTicks { ticks = ticks }, S.stop() } }',
    "",
  }, "\n")
  local resource = ScriptLoader.loadOverride("trusted.save_demo", content, trustedRequire)
  local services = FakeServices.new()
  local registry = Registry.new()
  registry:installBase(resource.id, resource, "override")
  local composition = Composition.new(registry)
  local taskRegistry = TaskRegistry.new()
  taskRegistry:register("wait_ticks", 1, WaitTicksTask)
  local resolvers = {
    resolveTask = function(taskType, version)
      return taskRegistry:resolve(taskType, version)
    end,
    resolveComposition = function(id)
      return composition:effective(id)
    end,
  }
  local function buildScheduler()
    return Scheduler.new({
      semantics = require("libs.hgss.src.script.RuntimeValues"),
      services = services,
      taskRegistry = taskRegistry,
      resolveComposition = function(id)
        return composition:effective(id)
      end,
    })
  end
  local function runToCompletion(scheduler, fromTick)
    local tick = fromTick
    while scheduler:foregroundEnvironmentId() ~= nil do
      scheduler:step(tick, nil)
      tick = tick + 1
      Assert.isTrue(tick - fromTick < 100, "the typed task must complete")
    end
    return tick - 1
  end
  local composed = assert(composition:effective("trusted.save_demo"))
  local plain = buildScheduler()
  plain:createForeground(composed, nil, 100)
  local plainDone = runToCompletion(plain, 100)
  local interrupted = buildScheduler()
  interrupted:createForeground(composed, nil, 100)
  interrupted:step(100, nil)
  local bucket = ScriptSave.capture(interrupted, 100)
  Assert.isNil(ScriptSave.validate(bucket, resolvers))
  local resumed = buildScheduler()
  ScriptSave.restore(bucket, resumed, 100)
  Assert.equal(runToCompletion(resumed, 101), plainDone)
  for _, bad in ipairs({ function() end, coroutine.create(function() end) }) do
    bucket.tasks[1].state = bad
    local stateErr = ScriptSave.validate(bucket, resolvers)
    Assert.notNil(stateErr, "closure task state must not validate")
    Assert.equal(stateErr.code, "SCRIPT_TASK_UNSERIALIZABLE")
  end
end

return { tests = T }
