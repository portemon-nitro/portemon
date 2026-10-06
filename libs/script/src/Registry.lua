-- Script resource registry : owns the vanilla base
-- definitions (generated transcripts plus overrides). The override layer
-- wins over the generated transcript; the composition layer folds the
-- winning base into the effective chain. Base layers may be
-- installed as deferred placeholders (installBaseDeferred) that decode
-- through an injected resource loader on first access, so a boot never
-- needs to decode the whole generated corpus. The registry is sealed after load: the public
-- install surface raises once sealed, while on-demand decode of pending
-- bases through the private `_load` memoization stays live.
-- Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

---@class Registry
---@field private _bases table<string, table<string, unknown>> id -> layer -> script
---@field private _version integer
---@field private _sealed boolean
---@field private _loadResource fun(id: string, layer: string): table<string, unknown>|nil, unknown?|nil
local Registry = {}
Registry.__index = Registry

-- Sentinel for a base layer whose resource is not decoded yet.
local PENDING = {}

-- Vanilla base layers : the checked-in `data/scripts/overrides` layer
-- (every script named by the override manifest) sits above the generated
-- transcript. The effective base selection happens here so the composition
-- layer only ever sees one base definition.
local BASE_LAYERS = { builtin = 1, generated = 2, override = 3 }

local VANILLA_OWNER = { kind = "vanilla", id = "base", api = 1 }

---@param opts table<string, unknown>|nil { loadResource: fun(id: string, layer: string): table<string, unknown>|nil, unknown?|nil }
---@return Registry
function Registry.new(opts)
  opts = opts or {}
  return setmetatable({
    _bases = {},
    _version = 0,
    _sealed = false,
    _loadResource = opts.loadResource,
  }, Registry)
end

-- Seal the registry after load: the public install surface raises from here
-- on, so cached compositions can never describe stale data. Sealing is
-- one-way; on-demand decode of pending bases through the private `_load`
-- memoization stays live.
function Registry:seal()
  self._sealed = true
end

---@param id string
function Registry:_assertMutable(id)
  if self._sealed then
    Errors.raise(
      ScriptErrors.SCRIPT_REGISTRY_SEALED,
      "the script registry is sealed; installs must happen before load finishes",
      { scriptId = id }
    )
  end
end

function Registry:_hasBase(id)
  return self._bases[id] ~= nil and next(self._bases[id]) ~= nil
end

-- Install a vanilla base definition. `layer` is "generated" or "override";
-- override wins over the generated transcript. Installing the same layer
-- twice is a hard duplicate error.
---@param id string
---@param script table<string, unknown>
---@param layer string
---@return table<string, unknown>
function Registry:installBase(id, script, layer)
  self:_assertMutable(id)
  assert(type(id) == "string" and id ~= "", "script id required")
  assert(type(script) == "table", "base script must be a table")
  assert(BASE_LAYERS[layer] ~= nil, "base layer must be generated or override")
  self:_installLayer(id, layer, script)
  return script
end

---@param id string
---@param script table<string, unknown>
function Registry:installBuiltin(id, script)
  self:_assertMutable(id)
  assert(type(id) == "string" and id ~= "", "script id required")
  assert(type(script) == "table", "base script must be a table")
  self:_installLayer(id, "builtin", script)
end

-- Record a base layer whose resource is not decoded yet; `base` resolves it
-- through the registry's resource loader on first access. Same duplicate
-- rules as installBase.
---@param id string
---@param layer string
function Registry:installBaseDeferred(id, layer)
  self:_assertMutable(id)
  assert(type(id) == "string" and id ~= "", "script id required")
  assert(BASE_LAYERS[layer] ~= nil, "base layer must be generated or override")
  self:_installLayer(id, layer, PENDING)
end

function Registry:_installLayer(id, layer, value)
  local layers = self._bases[id]
  if layers == nil then
    layers = {}
    self._bases[id] = layers
  end
  if layers[layer] ~= nil then
    local context = { scriptId = id, layer = layer, owner = VANILLA_OWNER }
    ---@cast context Errors.Context
    Errors.raise(ScriptErrors.SCRIPT_DUPLICATE_ID, "duplicate base definition for " .. id, context)
  end
  layers[layer] = value
  self._version = self._version + 1
end

-- Decode a pending layer through the resource loader and memoize it in the
-- slot; the loader is wired at construction, so its absence is a programming
-- fault, and a loader failure is a hard load error.
---@param id string
---@param layer string
---@return table<string, unknown>
function Registry:_load(id, layer)
  local loader = assert(self._loadResource, "registry has no resource loader for deferred base " .. id)
  local resource, err = loader(id, layer)
  if resource == nil then
    local context = { scriptId = id, layer = layer, cause = err and err.context or nil }
    ---@cast context Errors.Context
    Errors.raise(
      ScriptErrors.SCRIPT_LOAD_FAILED,
      "deferred base is unavailable: " .. id .. " (" .. tostring(err and err.message or "?") .. ")",
      context
    )
  end
  ---@cast resource table<string, unknown>
  self._bases[id][layer] = resource
  return resource
end

-- The effective base resource: override over generated. A deferred layer
-- decodes on first access and is memoized.
---@param id string
---@return table<string, unknown>?
function Registry:base(id)
  local layers = self._bases[id]
  if not layers then
    return nil
  end
  local layer = layers.override and "override" or layers.generated and "generated" or layers.builtin and "builtin"
  if not layer then
    return nil
  end
  local script = layers[layer]
  if script == PENDING then
    script = self:_load(id, layer)
  end
  return script
end

-- All ids with any installed base, sorted.
---@return string[]
function Registry:ids()
  local out = {}
  for id, layers in pairs(self._bases) do
    if next(layers) ~= nil then
      out[#out + 1] = id
    end
  end
  table.sort(out)
  return out
end

-- A monotonic mutation counter; the composition cache keys on it.
---@return integer
function Registry:version()
  return self._version
end

return Registry
