-- Script content loader for the game (the override system): installs the
-- generated transcript bases from the compiled script cache, then every
-- checked-in override listed in the override manifest (a file named
-- `<script-id>.lua` overrides the script with that id, or introduces the id
-- when no base exists, as with the curated Elm replacement). Generated content
-- is one readable Lua bundle per source script archive member: the active
-- index maps a logical id to its member and source slot, and a member is
-- evaluated once per selected registry the first time any of its scripts is
-- requested. The manifest is
-- the single source of override filenames: no directory enumeration at
-- runtime. Override files are ordinary `return S.script { ... }` modules
-- executed with normal Lua globals and the host require; the returned
-- resource must carry the exact id of its file and must compile on use.
-- Strict DSL validation is authoring-only (`gen4.script.validate`). The filesystem is
-- injected (`read`), so the loader is testable headless; the game passes an
-- io-backed repo filesystem for the override tree outside the LÖVE source
-- mount. Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")
local ScriptCache = require("libs.assets.src.ScriptCache")
local Validate = require("libs.assets.src.Validate")
local ScriptOverrides = require("libs.assets.src.ScriptOverrides")

local ScriptLoader = {}

---@alias ScriptSelection { generation: string, marker: string, index: table<string, unknown> }
-- The default restricted require for resource chunks: generated and override
-- modules may import gen4.script and nothing else. Callers that trust their
-- content may inject their own requireFn, but the default is an allowlist,
-- not the global require.
---@param name string
---@return unknown
local function defaultRequire(name)
  assert(name == "gen4.script", "script resource chunks may only require gen4.script")
  return require(name)
end

-- Execute one Lua resource chunk (`return S.script { ... }`) in the given
-- environment. Parse errors, runtime errors, and non-table results are hard
-- load faults attributed to the chunk path.
---@param content string
---@param chunkName string
---@param env table<string, unknown>
---@return table<string, unknown> resource
local function executeChunk(content, chunkName, env)
  local chunk, loadErr = loadstring(content, chunkName)
  if not chunk then
    Errors.raise(
      ScriptErrors.SCRIPT_LOAD_FAILED,
      "script module does not parse: " .. tostring(loadErr),
      { path = chunkName }
    )
  end
  chunk = chunk --[[@as function]]
  setfenv(chunk, env)
  local ok, resource = pcall(chunk)
  if not ok then
    Errors.raise(
      ScriptErrors.SCRIPT_LOAD_FAILED,
      "script module failed to load: " .. tostring(resource),
      { path = chunkName }
    )
  end
  if type(resource) ~= "table" then
    Errors.raise(ScriptErrors.SCRIPT_LOAD_FAILED, "script module must return a resource table", { path = chunkName })
  end
  return resource
end

-- Load one generated resource chunk in the minimal deterministic
-- environment: only `require` is visible, and the default require only
-- serves gen4.script.
---@param content string
---@param chunkName string
---@param requireFn function
---@return table<string, unknown> resource
local function loadResourceChunk(content, chunkName, requireFn)
  local env = { require = requireFn } --[[@as table]]
  return executeChunk(content, chunkName, env)
end

-- Load one checked-in override chunk under the trusted policy: normal Lua
-- globals stay visible and `require` is the repository/host configured
-- callback, so overrides may use standard libraries and additional trusted
-- modules. The returned value must still be a resource table; semantic DSL
-- validation is authoring-only (`gen4.script.validate`), never a runtime
-- gate: malformed resources fail at compile on use.
---@param content string
---@param chunkName string
---@param requireFn function
---@return table<string, unknown> resource
local function loadOverrideChunk(content, chunkName, requireFn)
  local env = setmetatable({ require = requireFn }, { __index = _G }) --[[@as table]]
  return executeChunk(content, chunkName, env)
end

-- One member bundle evaluator over a pinned generation: a member file is
-- read and evaluated the first time one of its scripts is requested, and the
-- evaluated bundle serves every later request for that member. The memo
-- belongs to the returned closure, so the selected registry owns its lifetime
-- and a new generation starts empty.
---@param cacheFs table<string, unknown> CacheFs-shaped
---@param generation string
---@param requireFn fun(name: string): unknown|nil defaults to the restricted gen4.script-only require
---@return fun(member: integer, scriptIndex: integer, id: string): table<string, unknown>|nil, Errors.Error?
local function memberResources(cacheFs, generation, requireFn)
  requireFn = requireFn or defaultRequire
  local members = {}
  ---@param member integer
  ---@return table<string, unknown>|nil, Errors.Error?
  local function bundleAt(member)
    local bundle = members[member]
    if bundle ~= nil then
      return bundle
    end
    local path = ScriptCache.memberPath(generation, member)
    local content = cacheFs:read(path)
    if content == nil then
      return nil,
        Errors.new(
          ScriptErrors.SCRIPT_LOAD_FAILED,
          "script cache member is unavailable",
          { member = member, path = path }
        )
    end
    local ok, loaded = pcall(loadResourceChunk, content --[[@as string]], path, requireFn)
    if not ok then
      return nil, loaded --[[@as Errors.Error]]
    end
    bundle = loaded --[[@as table]]
    if bundle.schema ~= ScriptCache.MEMBER_SCHEMA or not Validate.isArray(bundle.scripts) then
      return nil,
        Errors.new(
          ScriptErrors.SCRIPT_LOAD_FAILED,
          "script cache member bundle is malformed",
          { member = member, path = path }
        )
    end
    members[member] = bundle
    return bundle
  end
  ---@param member integer
  ---@param scriptIndex integer
  ---@param id string
  ---@return table<string, unknown>|nil, Errors.Error?
  local function resourceAt(member, scriptIndex, id)
    local bundle, err = bundleAt(member)
    if bundle == nil then
      return nil, err
    end
    local resource = bundle.scripts[scriptIndex + 1]
    if type(resource) ~= "table" then
      return nil,
        Errors.new(
          ScriptErrors.SCRIPT_LOAD_FAILED,
          "script cache member has no resource at the indexed source slot",
          { scriptId = id, member = member, scriptIndex = scriptIndex }
        )
    end
    if resource.id ~= id or type(resource.metadata) ~= "table" or resource.metadata.generated ~= true then
      return nil,
        Errors.new(
          ScriptErrors.SCRIPT_LOAD_FAILED,
          "script cache resource does not match its index entry",
          { scriptId = id, resourceId = resource.id }
        )
    end
    -- Lowered steps carry source offsets, and the DSL compiler derives the
    -- stable node identity of every generated step from the resource's source
    -- member and script slot. The bundle path and this index entry already own
    -- that identity, so it is attached here instead of being repeated for
    -- every script on disk.
    resource.metadata.source = { member = member, scriptIndex = scriptIndex }
    return resource
  end
  return resourceAt
end

-- Resolve one generated script from the pinned generation: read and evaluate
-- its member bundle, then take the script at its indexed source slot.
-- Generated resources are producer-validated before publication, so runtime
-- routes by pinned cache identity and script id without rerunning the
-- semantic validator. Returns the resource, or nil plus an Errors object on
-- any failure.
---@param cacheFs table<string, unknown> CacheFs-shaped
---@param generation string
---@param member integer
---@param scriptIndex integer
---@param id string
---@param requireFn fun(name: string): unknown|nil defaults to the restricted gen4.script-only require
---@return table<string, unknown>|nil, Errors.Error?
local function loadGeneratedAt(cacheFs, generation, member, scriptIndex, id, requireFn)
  return memberResources(cacheFs, generation, requireFn)(member, scriptIndex, id)
end

function ScriptLoader.loadGenerated(cacheFs, id, requireFn, opts)
  assert(
    opts and opts.generation ~= nil and opts.member ~= nil and opts.scriptIndex ~= nil,
    "generated script loading requires a pinned generation"
  )
  return loadGeneratedAt(cacheFs, opts.generation, opts.member, opts.scriptIndex, id, requireFn)
end

function ScriptLoader.loadGeneratedFrom(cacheFs, generation, member, scriptIndex, id, requireFn)
  return loadGeneratedAt(cacheFs, generation, member, scriptIndex, id, requireFn)
end

---@param cacheFs table<string, unknown> CacheFs-shaped
---@return ScriptSelection
local function loadSelection(cacheFs)
  local selection, selectionErr = ScriptCache.loadActive(cacheFs)
  if selection == nil then
    Errors.raise(ScriptErrors.SCRIPT_LOAD_FAILED, tostring(selectionErr), { path = ScriptCache.activeIndexPath() })
  end
  return assert(selection)
end

-- Load every generated base from the compiled script cache: the index maps
-- each logical id to its member bundle and source slot. A missing member or
-- an id mismatch is a hard load error (the cache readiness check already
-- gates the build, so a mismatch here is a real fault). With `opts.lazy`,
-- only the layer presence is installed (installBaseDeferred): the bundles
-- decode through the build's resource loader on first access, and installing
-- the index reads no payload.
---@param registry table<string, unknown> Registry
---@param cacheFs table<string, unknown> CacheFs-shaped
---@param requireFn? fun(name: string): unknown
---@param opts table<string, unknown>|nil { lazy: boolean?, builtins: table<string, unknown>|nil }
function ScriptLoader.installGenerated(registry, cacheFs, requireFn, opts)
  requireFn = requireFn or defaultRequire
  opts = opts or {}
  local selection = (opts.selection or loadSelection(cacheFs)) --[[@as ScriptSelection]]
  local index = selection.index
  if type(index) ~= "table" or index.schema ~= ScriptCache.INDEX_SCHEMA then
    Errors.raise(
      ScriptErrors.SCRIPT_LOAD_FAILED,
      "script cache index has an unknown schema",
      { path = ScriptCache.activeIndexPath(), schema = index and index.schema or nil }
    )
  end
  -- resources is the current schema's required array; a missing or malformed
  -- index must fail before any install, never become an empty registry. The
  -- rule matches the build-path readiness validator (ScriptCache.isReady).
  -- This checks only the index shape -- the member bundles still decode
  -- lazily on the deferred path.
  if not Validate.isArray(index.resources) then
    Errors.raise(
      ScriptErrors.SCRIPT_LOAD_FAILED,
      "script cache index resources are missing or malformed",
      { path = ScriptCache.activeIndexPath() }
    )
  end
  local resourceAt = memberResources(cacheFs, selection.generation, requireFn)
  for _, entry in ipairs(index.resources) do
    assert(type(entry.id) == "string" and entry.id ~= "", "script cache index entry id required")
    if opts.lazy then
      registry:installBaseDeferred(entry.id, "generated")
    else
      local resource, err
      resource, err = resourceAt(assert(entry.member), assert(entry.scriptIndex), entry.id)
      if resource == nil then
        local context = { scriptId = entry.id, cause = err and err.context or nil }
        ---@cast context Errors.Context
        Errors.raise(
          err and err.code or ScriptErrors.SCRIPT_LOAD_FAILED,
          err and err.message or "generated script failed to load",
          context
        )
      end
      registry:installBase(entry.id, resource, "generated")
    end
  end
end

-- Load one override file: `<id>.lua` returning an S.script resource whose id
-- must equal the file-derived id. The chunk runs under the trusted policy
-- (Lua globals plus the caller's require); only the file/resource id check
-- runs here. Semantic validation is authoring-only: a malformed resource
-- loads and fails at compile on use with the script id attached. Returns
-- the resource.
---@param id string
---@param content string
---@param requireFn function
---@return table<string, unknown> resource
function ScriptLoader.loadOverride(id, content, requireFn)
  local resource = loadOverrideChunk(content, ScriptOverrides.DIR .. "/" .. id .. ".lua", requireFn)
  if resource.id ~= id then
    Errors.raise(
      ScriptErrors.SCRIPT_LOAD_FAILED,
      "override file " .. id .. ".lua defines script " .. tostring(resource.id),
      { scriptId = id, resourceId = resource.id }
    )
  end
  return resource
end

-- Install every override named by the override manifest. Files are
-- `data/scripts/overrides/<id>.lua`; the manifest lists the exact ids (it is
-- regenerated with the overrides, so no directory enumeration happens at
-- runtime). The manifest is evaluated in the same restricted environment as
-- generated resource chunks; each override file runs under the trusted
-- policy instead. Returns the ids installed, sorted.
---@param registry table<string, unknown> Registry
---@param fs table<string, unknown> { read(path): string? }
---@param requireFn? fun(name: string): unknown
---@return string[]
function ScriptLoader.installOverrides(registry, fs, requireFn)
  requireFn = requireFn or defaultRequire
  local manifest, manifestErr = fs:read(ScriptOverrides.MANIFEST)
  if manifest == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_LOAD_FAILED,
      "override manifest is unavailable: " .. tostring(manifestErr and manifestErr.message or "?"),
      { path = ScriptOverrides.MANIFEST }
    )
  end
  local ids = loadResourceChunk(manifest --[[@as string]], ScriptOverrides.MANIFEST, requireFn)
  table.sort(ids)
  local installed = {}
  for _, id in ipairs(ids) do
    assert(type(id) == "string" and id ~= "", "override manifest ids must be strings")
    local path = ScriptOverrides.DIR .. "/" .. id .. ".lua"
    local content = fs:read(path)
    if content == nil then
      Errors.raise(ScriptErrors.SCRIPT_LOAD_FAILED, "override file is unreadable: " .. path, { scriptId = id })
    end
    local resource = ScriptLoader.loadOverride(id, content --[[@as string]], requireFn)
    registry:installBase(id, resource, "override")
    installed[#installed + 1] = id
  end
  return installed
end

-- Build a registry from the script cache plus the override directory. `fs`
-- must expose the repo `data/scripts/overrides` directory; the game passes an
-- io-backed repo filesystem (RepoFs) reading the checkout tree. With
-- `opts.lazy` the generated layer installs as deferred placeholders that
-- decode on first access through a loader closure over `cacheFs`.
-- The override layer is always loaded eagerly under the trusted policy: it is
-- hand-authored checked-in content, so the file/resource id check diagnoses
-- wiring mistakes at startup, while semantic mistakes fail at compile on
-- use; strict authoring lint stays available through gen4.script.validate.
-- The finished registry is sealed:
-- installs after load finish are rejected.
---@param cacheFs table<string, unknown> CacheFs-shaped
---@param fs table<string, unknown> directory-shaped filesystem for data/scripts/overrides
---@param requireFn function|nil defaults to the restricted gen4.script-only require
---@param opts table<string, unknown>|nil { lazy: boolean?, builtins: table<string, unknown>|nil }
---@return Registry registry, ScriptSelection selection
function ScriptLoader.buildRegistry(cacheFs, fs, requireFn, opts)
  opts = opts or {}
  requireFn = requireFn or defaultRequire
  local Registry = require("libs.script.src.Registry")
  local selection = loadSelection(cacheFs)
  local registry
  if opts.lazy then
    -- One member memo per built registry: the deferred layer holds no decoded
    -- payload, and the first request for any script of a member evaluates that
    -- member once for the lifetime of this registry.
    local resourceAt = memberResources(cacheFs, selection.generation, requireFn)
    local function loadResource(id, _)
      local entry
      for _, candidate in ipairs(selection.index.resources) do
        if candidate.id == id then
          entry = candidate
          break
        end
      end
      assert(entry ~= nil, "generated script is not in the pinned index: " .. id)
      local resource, err
      resource, err = resourceAt(assert(entry.member), assert(entry.scriptIndex), id)
      if resource == nil then
        local context = { scriptId = id, cause = err and err.context or nil }
        ---@cast context Errors.Context
        Errors.raise(
          err and err.code or ScriptErrors.SCRIPT_LOAD_FAILED,
          err and err.message or "generated script failed to load",
          context
        )
      end
      return resource
    end
    registry = Registry.new({
      loadResource = loadResource,
    })
  else
    registry = Registry.new()
  end
  if opts.builtins ~= nil then
    assert(type(opts.builtins.all) == "function", "script builtins require an all function")
    for id, script in pairs(opts.builtins.all()) do
      registry:installBuiltin(id, script)
    end
  end
  local installOpts = {}
  for key, value in pairs(opts) do
    installOpts[key] = value
  end
  installOpts.selection = selection
  ScriptLoader.installGenerated(registry, cacheFs, requireFn, installOpts)
  ScriptLoader.installOverrides(registry, fs, requireFn)
  -- Load finished: the registry is sealed so cached compositions can never
  -- describe stale data. On-demand decode of pending bases stays live
  -- through the gate.
  registry:seal()
  return registry, selection
end

return ScriptLoader
