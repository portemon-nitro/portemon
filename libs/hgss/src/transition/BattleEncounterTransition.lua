-- Owns one prepared source-selected encounter transition until its native task ends.

local BattleEncounterSelector = require("libs.hgss.src.transition.BattleEncounterSelector")
local Errors = require("libs.errors.src.Errors")

---@class BattleEncounterTransition
---@field _manifest table<string, unknown>
---@field _cacheFs BattleEncounterTransition.CacheFs
---@field _battleAssets BattleEncounterTransition.BattleAssets
---@field _sceneKey string
---@field _audioOperations BattleEncounterTransition.AudioOperations
---@field _effectFactory fun(route: table<string, unknown>, resources: table<string, unknown>, context: BattleEncounterSelector.Context): BattleEncounterTransition.Effect
---@field _phase string
---@field _selection BattleEncounterSelector.Selection?
---@field _resources table<string, unknown>?
---@field _effect BattleEncounterTransition.Effect?
---@field _error unknown
---@field _complete boolean
local BattleEncounterTransition = {}
BattleEncounterTransition.__index = BattleEncounterTransition

---@class BattleEncounterTransition.CacheFs
---@field loadLua fun(self: BattleEncounterTransition.CacheFs, path: string): table<string, unknown>?, string?

---@class BattleEncounterTransition.BattleAssets
---@field requestBattleScene fun(sceneKey: string, urgency: string): boolean?, string?

---@class BattleEncounterTransition.AudioOperations
---@field emit fun(self: BattleEncounterTransition.AudioOperations, operation: table<string, unknown>)

---@class BattleEncounterTransition.Effect
---@field start fun(self: BattleEncounterTransition.Effect)
---@field stepSourceTick fun(self: BattleEncounterTransition.Effect): boolean?
---@field frame fun(self: BattleEncounterTransition.Effect): table<string, unknown>
---@field dispose fun(self: BattleEncounterTransition.Effect)
---@field acceptFieldLayers fun(self: BattleEncounterTransition.Effect, layers: table<string, unknown>)?

---@class BattleEncounterTransition.Options
---@field manifest table<string, unknown> validated presentation manifest
---@field cacheFs BattleEncounterTransition.CacheFs staged CacheFs reader
---@field battleAssets BattleEncounterTransition.BattleAssets typed scene demand host
---@field sceneKey string selected battle scene key whose receipt owns global transition payloads
---@field audioOperations BattleEncounterTransition.AudioOperations typed battle audio operation sink
---@field effectFactory fun(route: table<string, unknown>, resources: table<string, unknown>, context: BattleEncounterSelector.Context): BattleEncounterTransition.Effect source family constructor

---@param options BattleEncounterTransition.Options
---@return BattleEncounterTransition
function BattleEncounterTransition.new(options)
  assert(options and type(options.manifest) == "table", "battle transition requires its staged manifest")
  assert(options.cacheFs and options.cacheFs.loadLua, "battle transition requires staged resource access")
  assert(
    options.battleAssets and type(options.battleAssets.requestBattleScene) == "function",
    "battle transition requires its generation-scoped scene demand host"
  )
  assert(
    type(options.sceneKey) == "string" and options.sceneKey ~= "",
    "battle transition requires its selected scene key"
  )
  assert(options.audioOperations and options.audioOperations.emit, "battle transition requires the typed audio sink")
  assert(type(options.effectFactory) == "function", "battle transition requires native effect families")
  return setmetatable({
    _manifest = options.manifest,
    _cacheFs = options.cacheFs,
    _battleAssets = options.battleAssets,
    _sceneKey = options.sceneKey,
    _audioOperations = options.audioOperations,
    _effectFactory = options.effectFactory,
    _phase = "new",
    _selection = nil,
    _resources = nil,
    _effect = nil,
    _error = nil,
    _complete = false,
  }, BattleEncounterTransition)
end

---@param context BattleEncounterSelector.Context immutable semantic launch context
---@return "pending"|"ready"
function BattleEncounterTransition:prepare(context)
  assert(self._phase == "new" or self._phase == "pending", "battle transition prepares once and resumes while pending")
  self._phase = "preparing"
  local ok, result = pcall(function()
    local selection = self._selection or BattleEncounterSelector.resolve(self._manifest.transitions, context)
    self._selection = selection
    local ready, demandError = self._battleAssets.requestBattleScene(self._sceneKey, "required")
    if demandError ~= nil then
      Errors.raise(
        "BATTLE_TRANSITION_RESOURCE_UNAVAILABLE",
        "selected transition resources are not globally published",
        {
          route = selection.routeKey,
          scene = self._sceneKey,
          cause = demandError,
        }
      )
    end
    if ready ~= true then
      self._phase = "pending"
      return "pending"
    end
    local resources = {}
    local resourceDescriptors = assert(self._manifest.resources, "manifest carries staged resource descriptors")
    for _, resourceKey in ipairs(selection.route.resources) do
      local descriptor = resourceDescriptors[resourceKey]
      if type(descriptor) ~= "table" or type(descriptor.path) ~= "string" then
        Errors.raise("BATTLE_TRANSITION_RESOURCE_UNAVAILABLE", "selected transition resource is not staged", {
          resource = resourceKey,
          route = selection.routeKey,
        })
      end
      local value, loadError = self._cacheFs:loadLua(descriptor.path)
      if value == nil then
        Errors.raise("BATTLE_TRANSITION_RESOURCE_UNAVAILABLE", "selected transition resource could not be loaded", {
          resource = resourceKey,
          route = selection.routeKey,
          cause = loadError,
        })
      end
      resources[resourceKey] = value
    end
    self._selection = selection
    self._resources = resources
    return "ready"
  end)
  if not ok then
    self._phase = "failed"
    self._error = result
    error(result, 0)
  end
  if result == "pending" then
    return "pending"
  end
  self._phase = "ready"
  return "ready"
end

---@return "running"
function BattleEncounterTransition:start()
  assert(self._phase == "ready", "battle transition starts after successful preparation")
  local selection = assert(self._selection)
  local ok, result = pcall(function()
    self._effect = self._effectFactory(selection.route, assert(self._resources), selection.context)
    assert(
      self._effect
        and self._effect.start
        and self._effect.stepSourceTick
        and self._effect.frame
        and self._effect.dispose,
      "native transition effect provides its lifecycle"
    )
    self._audioOperations:emit({ kind = "start-battle-music", role = selection.musicRole })
    self._effect:start()
  end)
  if not ok then
    self._phase = "failed"
    self._error = result
    self:_disposeEffect()
    error(result, 0)
  end
  self._phase = "running"
  return "running"
end

function BattleEncounterTransition:stepSourceTick()
  assert(self._phase == "running", "only a running transition advances source time")
  local ok, done = pcall(self._effect.stepSourceTick, self._effect)
  if not ok then
    self._phase = "failed"
    self._error = done
    self:_disposeEffect()
    error(done, 0)
  end
  if done then
    self._complete = true
    self._phase = "complete"
    self:_disposeEffect()
  end
end

---@param layers table<string, unknown> fresh launch-owned native field planes
function BattleEncounterTransition:acceptFieldLayers(layers)
  assert(self._phase == "running", "source field layers belong to a running transition")
  local effect = assert(self._effect, "running transition retains its source family")
  if effect.acceptFieldLayers ~= nil then
    effect:acceptFieldLayers(layers)
  end
end

---@return table<string, unknown> read-only source family frame description
function BattleEncounterTransition:frame()
  if self._phase == "running" then
    return self._effect:frame()
  end
  return { phase = self._phase }
end

---@return {phase: string, complete: boolean, error: unknown, routeKey: string?}
function BattleEncounterTransition:status()
  return {
    phase = self._phase,
    complete = self._complete,
    error = self._error,
    routeKey = self._selection and self._selection.routeKey or nil,
  }
end

function BattleEncounterTransition:dispose()
  self:_disposeEffect()
  self._resources = nil
  if self._phase ~= "failed" and self._phase ~= "complete" then
    self._phase = "disposed"
  end
end

function BattleEncounterTransition:_disposeEffect()
  if self._effect ~= nil then
    local effect = assert(self._effect, "disposed effect detaches while owned")
    self._effect = nil
    effect:dispose()
  end
end

return BattleEncounterTransition
