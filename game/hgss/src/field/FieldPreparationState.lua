local DevScreenLayout = require("game.hgss.src.ui.DevScreenLayout")

-- Pending field-entry ownership for Continue and the New Game handoff.
-- It tracks three independent readiness interests instead of one global
-- gate: entry planning, the static field runtime, and the entry target
-- location. Continue loads its saved record on the first update without
-- waiting for either closure, then demands its target location through
-- the borrowed metadata-only loader as soon as entry planning is ready,
-- even while the static runtime is still pending. New Game derives and
-- demands its target the same way, and both entries transfer to the
-- already-composed field exactly once, only when the target and the
-- runtime are both ready. A factory that returns no loader latches a
-- visible failed phase carrying its diagnostic; any other failure raises
-- directly: no invalid candidate or save is repaired or published, and
-- preparation owns no error presentation beyond the latched diagnostic.
-- Cancellation remains available while pending and publishes nothing.

---@class FieldPreparationOptions
---@field kind "continue"|"newgame"
---@field saveId string? Continue only: the catalog-visible save to load on the first update
---@field candidate table<string, unknown>? New Game only: the finalized Oak candidate
---@field versionId string selected game version, carried for diagnostics
---@field derivedAssets table<string, function> semantic derived-asset host
---@field saveStore table<string, unknown>? Continue only: the normalizing save store
---@field createLoader fun(): (table<string, unknown>?, string?) loader factory owned by the HGSS composition; a nil loader latches a visible failure
---@field enterField fun(record: table<string, unknown>, extraOptions: table<string, unknown>?) ownership transfer
---@field onCancel fun()? return to the owning menu

---@class FieldPreparationState
---@field kind string
---@field saveId string?
---@field candidate table<string, unknown>?
---@field versionId string
---@field derivedAssets table<string, function>
---@field saveStore table<string, unknown>?
---@field createLoader fun(): (table<string, unknown>?, string?)
---@field loader table<string, unknown>? retained planning loader, built once planning is ready
---@field enterField fun(record: table<string, unknown>, extraOptions: table<string, unknown>?)
---@field onCancel fun()?
---@field phase "assets"|"location"|"done"|"failed"
---@field error string? latched loader-unavailability diagnostic, set only in the failed phase
---@field planningReady boolean entry planning observed ready
---@field runtimeReady boolean static field runtime observed ready
---@field loadAttempted boolean Continue only: the one-shot save load already ran
---@field record table<string, unknown>?
---@field target { idOrSymbol: integer|string, fieldX: integer, fieldZ: integer }?
---@field transferred boolean
---@field cancelled boolean
local FieldPreparationState = {}
FieldPreparationState.__index = FieldPreparationState

---@param options FieldPreparationOptions
---@return FieldPreparationState
function FieldPreparationState.new(options)
  assert(type(options) == "table", "field preparation requires its composition")
  assert(options.kind == "continue" or options.kind == "newgame", "field preparation kind is continue or newgame")
  assert(type(options.versionId) == "string" and options.versionId ~= "", "field preparation requires a versionId")
  assert(type(options.derivedAssets) == "table", "field preparation requires the derived-asset host")
  assert(type(options.createLoader) == "function", "field preparation requires its metadata-only loader factory")
  assert(type(options.enterField) == "function", "field preparation requires its field transfer")
  if options.kind == "continue" then
    assert(type(options.saveId) == "string" and options.saveId ~= "", "Continue preparation requires a saveId")
    assert(type(options.saveStore) == "table", "Continue preparation requires the save store")
  else
    assert(type(options.candidate) == "table", "New Game preparation requires the finalized candidate")
  end
  return setmetatable({
    kind = options.kind,
    saveId = options.saveId,
    candidate = options.candidate,
    versionId = options.versionId,
    derivedAssets = options.derivedAssets,
    saveStore = options.saveStore,
    createLoader = options.createLoader,
    loader = nil,
    enterField = options.enterField,
    onCancel = options.onCancel,
    phase = "assets",
    planningReady = false,
    runtimeReady = false,
    loadAttempted = false,
    record = nil,
    target = nil,
    transferred = false,
    cancelled = false,
  }, FieldPreparationState)
end

---@param name string milestone interest to observe
---@param kind string "planning"|"runtime"
function FieldPreparationState:_pollMilestone(name, kind)
  -- The semantic host is a plain function table (dot calls, no self).
  -- Repeating the required interest re-affirms it; the host answers with
  -- current readiness, so a pending prerequisite is simply observed again
  -- on the next update. A reported failure raises directly.
  local ready, failure = self.derivedAssets.requestMilestone(name, "required")
  if failure ~= nil then
    error(failure, 0)
  end
  if ready then
    if kind == "planning" then
      self.planningReady = true
    else
      self.runtimeReady = true
    end
  end
end

function FieldPreparationState:_ensureLoader()
  -- The planning loader is legal once entry planning is ready: build it
  -- exactly once, then reuse the retained loader for every later update.
  -- A factory that yields no loader reports an unavailable world: latch
  -- the visible failed phase with its diagnostic and never rebuild. A
  -- factory that raises keeps raising directly.
  if self.loader ~= nil or self.phase == "failed" then
    return
  end
  local factory = assert(self.createLoader, "field preparation requires its metadata-only loader factory")
  local loader, failure = factory()
  if loader == nil then
    self.phase = "failed"
    self.error = failure or "field preparation loader is unavailable"
    return
  end
  self.loader = loader
end

function FieldPreparationState:_loadContinue()
  -- The normalized store record carries its own destination: one direct
  -- load on the first update, independent of closure readiness, with no
  -- retry and no semantic revalidation beyond the destination envelope.
  self.loadAttempted = true
  local store = assert(self.saveStore, "Continue preparation requires the save store")
  local saveId = assert(self.saveId, "Continue preparation requires a saveId")
  local record = store.load(store, saveId)
  if record == nil then
    error("save could not be loaded: " .. tostring(saveId), 0)
  end
  if type(record.mapId) ~= "number" or type(record.fieldX) ~= "number" or type(record.fieldZ) ~= "number" then
    error("loaded save carries no field location: " .. tostring(saveId), 0)
  end
  self.record = record
  self.target = { idOrSymbol = record.mapId, fieldX = record.fieldX, fieldZ = record.fieldZ }
end

function FieldPreparationState:_planNewGameTarget()
  local candidate = assert(self.candidate, "New Game preparation requires the finalized candidate")
  local location = candidate.location
  if type(location) ~= "table" or type(location.mapSymbol) ~= "string" then
    error("finalized candidate carries no map location", 0)
  end
  if type(location.fieldX) ~= "number" or type(location.fieldZ) ~= "number" then
    error("finalized candidate carries no local field position", 0)
  end
  -- A new game's location is local to its map; the loader converts it to
  -- the same global domain normal loading uses.
  local loader = assert(self.loader, "target planning requires the retained planning loader")
  local position = loader:globalPosition(location.mapSymbol, location.fieldX, location.fieldZ)
  self.record = candidate
  self.target = { idOrSymbol = location.mapSymbol, fieldX = position.x, fieldZ = position.z }
  self.phase = "location"
end

function FieldPreparationState:_pollGeometry()
  local target = assert(self.target, "geometry demand requires its target")
  local loader = assert(self.loader, "geometry demand requires the retained planning loader")
  local ready, failure = loader:requestLocation(target.idOrSymbol, target.fieldX, target.fieldZ, "required")
  if failure ~= nil then
    error(failure, 0)
  end
  if not ready then
    return
  end
  if not self.runtimeReady then
    -- Either entry demands its destination while the runtime is still
    -- pending, but the transfer waits until both closures are ready.
    return
  end
  local record = assert(self.record, "field transfer requires its record")
  if self.kind == "newgame" then
    self.enterField(record, { initialFadeIn = true })
  else
    self.enterField(record)
  end
  self.transferred = true
  self.phase = "done"
end

function FieldPreparationState:update(_)
  if self.transferred or self.cancelled or self.phase == "done" or self.phase == "failed" then
    return
  end
  if self.kind == "continue" and not self.loadAttempted then
    self:_loadContinue()
  end
  if not self.planningReady then
    self:_pollMilestone("field-planning", "planning")
  end
  if not self.runtimeReady then
    self:_pollMilestone("field-runtime", "runtime")
  end
  if self.loader == nil then
    -- The loader needs entry planning, and for Continue the loaded
    -- record: neither entry waits for the static runtime to start
    -- destination work.
    local canBuild = self.planningReady and (self.kind ~= "continue" or self.record ~= nil)
    if not canBuild then
      return
    end
    self:_ensureLoader()
    if self.phase == "failed" then
      return
    end
  end
  if self.target == nil then
    if self.kind == "continue" then
      return
    end
    self:_planNewGameTarget()
  end
  if self.phase ~= "location" then
    self.phase = "location"
  end
  self:_pollGeometry()
end

function FieldPreparationState:draw()
  local lg = love.graphics
  local margin, line = DevScreenLayout.MARGIN, DevScreenLayout.LINE_HEIGHT
  if self.phase == "failed" then
    lg.setColor(1, 1, 1)
    lg.print("Field entry failed.", margin, margin)
    lg.setColor(0.7, 0.7, 0.75)
    lg.print(tostring(self.error), margin, margin + line)
    lg.print("Press escape to cancel.", margin, margin + 2 * line)
    return
  end
  lg.setColor(1, 1, 1)
  lg.print("Preparing field entry...", margin, margin)
  lg.setColor(0.7, 0.7, 0.75)
  lg.print("Phase: " .. self.phase, margin, margin + line)
  lg.print("Press escape to cancel.", margin, margin + 2 * line)
end

---@param key string
function FieldPreparationState:keypressed(key, _, _)
  if key == "escape" and not self.transferred and not self.cancelled then
    self.cancelled = true
    if self.onCancel then
      self.onCancel()
    end
  end
end

function FieldPreparationState:dispose()
  -- Cancellation or replacement never publishes a save or leaks the pending
  -- entry: the candidate stays with its task and the payload with its
  -- store; only this state's references are dropped. The borrowed loader
  -- stays with its owner; this state acquires no entries through it.
  self.cancelled = true
  self.candidate = nil
  self.record = nil
  self.target = nil
  self.createLoader = nil
  self.loader = nil
end

return FieldPreparationState
