-- Lazy registry tests: deferred base layers decode through the registry's
-- resource loader on first access, presence semantics (ids/duplicates) work
-- without decoding, and construction performs no digest work. No gameplay
-- pass decodes the corpus or publishes snapshots.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local LuaWriter = require("libs.codec.src.LuaWriter")
local ScriptCacheFixture = require("tests.support.ScriptCacheFixture")
local ScriptLoader = require("libs.script.src.ScriptLoader")
local ScriptOverrides = require("libs.assets.src.ScriptOverrides")
local Registry = require("libs.script.src.Registry")

local T = {}
local GENERATION = string.rep("a", 40)
local MARKER = "script-cache-v4:rom-sha:dep-sha"

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "expected a raised error")
  Assert.equal((err --[[@as Errors.Error]]).code, code)
end

-- A cache whose script class is complete: one member bundle per member and
-- the single active index over it.
local function scriptCache(files)
  files = files
    or {
      ["new_bark.lab_sign"] = "S.stop()",
      ["vanilla.hgss.scr_seq.0842.script_001"] = "S.stop()",
    }
  local scripts = {}
  for id, steps in pairs(files) do
    scripts[#scripts + 1] = { id = id, steps = steps }
  end
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  ScriptCacheFixture.writeSingleMember(cache, GENERATION, MARKER, scripts)
  return cache
end

-- A read-shaped filesystem for the override tree: the manifest and the
-- override files.
local function overrideFs(files)
  files = files or {}
  local manifest = {}
  for name in pairs(files) do
    local id = name:match("^(.*)%.lua$")
    if id ~= nil then
      manifest[#manifest + 1] = id
    end
  end
  table.sort(manifest)
  local manifestText = "return {\n"
  for _, id in ipairs(manifest) do
    manifestText = manifestText .. "  " .. string.format("%q", id) .. ",\n"
  end
  manifestText = manifestText .. "}\n"
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
  error("unexpected require in script chunk: " .. name)
end

-- The real deferred generated layer over the fixture cache: the selected
-- registry owns the single per-member memo, and a member-bundle read is the
-- observable decode.
local function lazyRegistry(cache, overrideFiles)
  local reads = 0
  local originalRead = cache.backend.read
  cache.backend.read = function(self, path)
    if path:find("/generations/", 1, true) then
      reads = reads + 1
    end
    return originalRead(self, path)
  end
  local registry = ScriptLoader.buildRegistry(cache, overrideFs(overrideFiles), requireShim, { lazy = true })
  return registry, function()
    return reads
  end
end

-- 1. A deferred base decodes through the registry on first access and is
-- memoized: both ids of the shared member decode from one bundle read.
T["deferred base decodes through the loader once"] = function()
  local registry, reads = lazyRegistry(scriptCache())
  Assert.isNil(registry:base("unknown.id"))
  local resource = assert(registry:base("new_bark.lab_sign"))
  Assert.equal(resource.id, "new_bark.lab_sign")
  Assert.equal(reads(), 1, "first access reads the member bundle once")
  Assert.notNil(registry:base("new_bark.lab_sign"))
  Assert.equal(reads(), 1, "the decoded base is memoized")
  Assert.equal(assert(registry:base("vanilla.hgss.scr_seq.0842.script_001")).id, "vanilla.hgss.scr_seq.0842.script_001")
  Assert.equal(reads(), 1, "two ids of one member share the registry's single memo")
end

T["builtin base is available without generated data"] = function()
  local registry = Registry.new()
  local builtin = { id = "runtime.inert_interaction" }
  registry:installBuiltin(builtin.id, builtin)
  Assert.equal(registry:base(builtin.id), builtin)
end

-- 2. Presence works without decoding: ids never touch the member bundles.
T["presence semantics never decode"] = function()
  local registry, reads = lazyRegistry(scriptCache())
  Assert.deepEqual(registry:ids(), { "new_bark.lab_sign", "vanilla.hgss.scr_seq.0842.script_001" })
  Assert.isNil(registry:base("unknown.id"))
  Assert.equal(reads(), 0)
end

-- 3. Deferred layers obey the same duplicate rules as installBase.
T["deferred layers detect duplicates"] = function()
  local registry = Registry.new()
  registry:installBaseDeferred("dup.id", "generated")
  throwsCode("SCRIPT_DUPLICATE_ID", function()
    registry:installBaseDeferred("dup.id", "generated")
  end)
  throwsCode("SCRIPT_DUPLICATE_ID", function()
    registry:installBase("dup.id", {}, "generated")
  end)
end

-- 4. The override layer beats a deferred generated layer without reading
-- the generated bundle.
T["resolved layers beat a pending generated layer"] = function()
  local registry, reads = lazyRegistry(scriptCache(), {
    ["new_bark.lab_sign.lua"] = 'local S = require("gen4.script")\nreturn S.script { api = 1, id = "new_bark.lab_sign", steps = { S.noop(), S.stop() } }\n',
  })
  local resource = assert(registry:base("new_bark.lab_sign"))
  Assert.equal(resource.steps[1].op, "noop", "the override wins over the pending generated base")
  Assert.equal(reads(), 0, "the override wins without reading the generated bundle")
end

-- 5. A failing loader surfaces as a load error at first access.
T["loader failure raises a load error"] = function()
  local registry = Registry.new({
    loadResource = function()
      return nil
    end,
  })
  registry:installBaseDeferred("broken.id", "generated")
  throwsCode("SCRIPT_LOAD_FAILED", function()
    registry:base("broken.id")
  end)
end

-- 6. A lazy registry built by the loader resolves the same bases as the
-- eager build: identity comes from the decoded resources themselves, and
-- construction decodes nothing either way the caller can observe here.
T["lazy and eager builds resolve identical bases"] = function()
  local eager = ScriptLoader.buildRegistry(scriptCache(), overrideFs(), requireShim)
  local lazy = ScriptLoader.buildRegistry(scriptCache(), overrideFs(), requireShim, { lazy = true })
  Assert.deepEqual(lazy:ids(), eager:ids())
  for _, id in ipairs(eager:ids()) do
    Assert.equal(LuaWriter.encode(assert(lazy:base(id))), LuaWriter.encode(assert(eager:base(id))))
  end
end

-- 7. A sealed registry still decodes pending bases on demand: the seal
-- gates installs, not first access.
T["sealed registry decodes pending bases on demand"] = function()
  local registry, reads = lazyRegistry(scriptCache())
  registry:seal()
  Assert.equal(reads(), 0, "construction decodes nothing")
  Assert.equal(assert(registry:base("new_bark.lab_sign")).id, "new_bark.lab_sign")
  Assert.equal(reads(), 1, "first access decodes only its own member")
  throwsCode("SCRIPT_REGISTRY_SEALED", function()
    registry:installBase("late.id", { id = "late.id" }, "generated")
  end)
end

-- 8. The registry owns no aggregate digest surface: layer ownership,
-- deferred loading, sealing, and the mutation version are the whole
-- contract, so there is nothing to seed or query.
T["registry owns no aggregate digest surface"] = function()
  local registry = Registry.new()
  local surface = registry --[[@as table<string, unknown>]]
  Assert.isNil(surface["fingerprint"])
  Assert.isNil(surface["cacheScriptHash"])
  Assert.isNil(surface["restoreFingerprint"])
end

-- 13. buildRegistry returns a sealed registry: the post-load registry is
-- immutable during gameplay.
T["buildRegistry returns a sealed registry"] = function()
  local registry = ScriptLoader.buildRegistry(scriptCache(), overrideFs(), requireShim, { lazy = true })
  throwsCode("SCRIPT_REGISTRY_SEALED", function()
    registry:installBase("late.id", { id = "late.id" }, "generated")
  end)
end

local HO_OH = "field-effect:ho_oh_appearance"

local function resource(id, steps, needs)
  return { kind = "field_script", api = 1, id = id, steps = steps, needs = needs }
end

function T.override_asset_needs_come_from_the_override_resource()
  local registry = Registry.new()
  registry:installBase("a.b", resource("a.b", { { op = "stop" } }), "generated")
  registry:installBase("a.b", resource("a.b", { { op = "legend_cutscene_bell_begin" }, { op = "stop" } }), "override")
  Assert.deepEqual(registry:overrideAssetNeeds("a.b"), { HO_OH })
end

function T.generated_only_id_has_no_override_asset_needs()
  local registry = Registry.new()
  registry:installBase("a.b", resource("a.b", { { op = "legend_cutscene_bell_begin" } }), "generated")
  Assert.isNil(registry:overrideAssetNeeds("a.b"))
  Assert.isNil(registry:overrideAssetNeeds("unknown.id"))
end

function T.override_that_drops_a_need_reports_an_empty_list()
  local registry = Registry.new()
  registry:installBase("a.b", resource("a.b", { { op = "legend_cutscene_bell_begin" } }), "generated")
  registry:installBase("a.b", resource("a.b", { { op = "stop" } }), "override")
  Assert.deepEqual(registry:overrideAssetNeeds("a.b"), {})
end

function T.override_needs_hint_is_honored()
  local registry = Registry.new()
  registry:installBase("a.b", resource("a.b", { { op = "stop" } }, { { kind = "custom", id = "thing" } }), "override")
  Assert.deepEqual(registry:overrideAssetNeeds("a.b"), { "custom:thing" })
end

function T.deferred_override_is_decoded_to_report_its_needs()
  local registry = Registry.new({
    loadResource = function(id)
      return resource(id, { { op = "legend_cinematic", destination = 0 } })
    end,
  })
  registry:installBaseDeferred("a.b", "override")
  Assert.deepEqual(registry:overrideAssetNeeds("a.b"), { HO_OH })
end

function T.override_asset_needs_are_memoized_until_the_registry_mutates()
  local registry = Registry.new()
  local override = resource("a.b", { { op = "legend_cutscene_bell_begin" } })
  registry:installBase("a.b", override, "override")
  Assert.deepEqual(registry:overrideAssetNeeds("a.b"), { HO_OH })
  override.steps = { { op = "stop" } }
  Assert.deepEqual(registry:overrideAssetNeeds("a.b"), { HO_OH }, "unchanged registry serves the memo")
  registry:installBase("c.d", resource("c.d", { { op = "stop" } }), "generated")
  Assert.deepEqual(registry:overrideAssetNeeds("a.b"), {}, "a mutation recomputes")
end

return { tests = T }
