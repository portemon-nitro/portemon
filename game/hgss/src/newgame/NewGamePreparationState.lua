-- Pending New Game ownership between the Main Menu intent and Oak
-- composition. It requests the semantic New Game intro milestone plus the
-- field-planning and field-runtime milestones as required, then transfers
-- to the already-registered ready callback exactly once. Planning is
-- required because Oak eagerly stages the opening bedroom entry at
-- composition, and that entry reads the world catalog planning publishes:
-- gating on the intro alone lets Oak compose while the world is still
-- pending and fails the handoff. Runtime is required because the field
-- installs directly behind the handoff with no second preparation
-- screen, and field construction eagerly reads runtime families such as
-- the summary manifest. A reported failure raises directly: this state owns no error
-- presentation of its own. Cancellation remains available while pending and
-- returns to the menu without composing Oak or reserving a candidate; it
-- never retires the selected generation's compiled output.
--
-- The visible frame is the shared edition-themed walking stage from
-- creation. The selected pair is decorative only: its keyed demand is
-- polled with near urgency, a cosmetic failure never blocks the semantic
-- intro gate, and one genuine loader draw is required before an otherwise
-- ready transfer so interactive entry always paints its stage.

local CacheFs = require("libs.storage.src.CacheFs")
local HgssLoadingPresentation = require("libs.hgss.src.ui.HgssLoadingPresentation")

---@class NewGamePreparationOptions
---@field versionId string selected game version, carried for the decorative stage
---@field startupPairIndex integer selected 1..32 walking pair, decorative only
---@field derivedAssets table<string, function> semantic derived-asset host
---@field onReady fun() compose the New Game candidate and Oak intro
---@field onCancel fun()? return to the owning menu
---@field displayContext DisplayContext? host topology and safe-area provider

---@class NewGamePreparationState
---@field versionId string
---@field startupPairIndex integer
---@field derivedAssets table<string, function>
---@field onReady fun()?
---@field onCancel fun()?
---@field phase "pending"|"done"
---@field progress { state: string, ready: integer, total: integer|nil, failure: unknown }?
---@field fired boolean
---@field cancelled boolean
---@field loading table<string, unknown>? owned themed stage, released once on transfer/cancel/dispose
---@field loaderArtObserved boolean
---@field loaderArtFailure unknown?
---@field drawObserved boolean one genuine loader draw while actually active
local NewGamePreparationState = {}
NewGamePreparationState.__index = NewGamePreparationState

---@param options NewGamePreparationOptions
---@return NewGamePreparationState
function NewGamePreparationState.new(options)
  assert(type(options) == "table", "New Game preparation requires its composition")
  assert(type(options.versionId) == "string" and options.versionId ~= "", "New Game preparation requires a versionId")
  assert(
    type(options.startupPairIndex) == "number"
      and options.startupPairIndex % 1 == 0
      and options.startupPairIndex >= 1
      and options.startupPairIndex <= 32,
    "New Game preparation requires the selected walking pair 1..32"
  )
  assert(type(options.derivedAssets) == "table", "New Game preparation requires the derived-asset host")
  assert(type(options.onReady) == "function", "New Game preparation requires its ready transfer")
  if options.onCancel ~= nil then
    assert(type(options.onCancel) == "function", "New Game preparation cancellation must be a function")
  end
  return setmetatable({
    versionId = options.versionId,
    startupPairIndex = options.startupPairIndex,
    derivedAssets = options.derivedAssets,
    onReady = options.onReady,
    onCancel = options.onCancel,
    phase = "pending",
    progress = nil,
    fired = false,
    cancelled = false,
    loading = HgssLoadingPresentation.new({
      versionId = options.versionId,
      pairIndex = options.startupPairIndex,
      width = love.graphics.getWidth(),
      height = love.graphics.getHeight(),
      displayContext = options.displayContext,
    }),
    loaderArtObserved = false,
    loaderArtFailure = nil,
    drawObserved = false,
  }, NewGamePreparationState)
end

function NewGamePreparationState:_releaseLoading()
  if self.loading ~= nil then
    self.loading:dispose()
    self.loading = nil
  end
end

function NewGamePreparationState:_pollLoaderArt()
  if self.loaderArtObserved or self.loading == nil then
    return
  end
  -- The loading cover is decorative: any failure in this whole sequence
  -- latches once as a cosmetic diagnostic and never blocks or cancels the
  -- required intro below. A pending shared demand stays retryable.
  -- The selected pair stays local to the presentation lookup below.
  local observed, ready, failure = pcall(self.derivedAssets.requestStartupWalker, "near")
  if not observed then
    self.loaderArtFailure = ready
    self.loaderArtObserved = true
    return
  end
  if failure ~= nil then
    self.loaderArtFailure = failure
    self.loaderArtObserved = true
    return
  end
  if ready ~= true then
    return
  end
  local adopted, adoptedResult, adoptionError = pcall(function()
    return self.loading:adoptGeneratedAssets(CacheFs.forVersion(self.versionId))
  end)
  self.loaderArtObserved = true
  if not adopted then
    self.loaderArtFailure = adoptedResult
  elseif not adoptedResult then
    self.loaderArtFailure = adoptionError
  end
end

function NewGamePreparationState:update(dt)
  if self.loading ~= nil then
    self.loading:update(dt or 0)
  end
  if self.fired or self.cancelled or self.phase == "done" then
    return
  end
  self:_pollLoaderArt()
  -- The semantic host is a plain function table (dot calls, no self).
  -- All three milestones gate the transfer: the intro covers Oak assets,
  -- planning covers the world catalog the staged bedroom entry reads,
  -- and runtime covers the families field construction eagerly loads
  -- behind the handoff, which installs the field directly.
  local introReady, introFailure = self.derivedAssets.requestMilestone("new-game-intro", "required")
  local planningReady, planningFailure = self.derivedAssets.requestMilestone("field-planning", "required")
  local runtimeReady, runtimeFailure = self.derivedAssets.requestMilestone("field-runtime", "required")
  -- Progress is a read-only observation of the same milestones: it never
  -- enrolls work and never substitutes for the readiness requests above.
  -- The bar aggregates both closures; an unknown denominator on either
  -- side carries no fraction.
  local introProgress = self.derivedAssets.milestoneStatus("new-game-intro")
  local planningProgress = self.derivedAssets.milestoneStatus("field-planning")
  local runtimeProgress = self.derivedAssets.milestoneStatus("field-runtime")
  assert(type(introProgress) == "table", "derived-asset progress is unavailable")
  assert(type(planningProgress) == "table", "derived-asset progress is unavailable")
  assert(type(runtimeProgress) == "table", "derived-asset progress is unavailable")
  local readyCount = (type(introProgress.ready) == "number" and introProgress.ready or 0)
    + (type(planningProgress.ready) == "number" and planningProgress.ready or 0)
    + (type(runtimeProgress.ready) == "number" and runtimeProgress.ready or 0)
  local totalCount = nil
  if
    type(introProgress.total) == "number"
    and type(planningProgress.total) == "number"
    and type(runtimeProgress.total) == "number"
  then
    totalCount = introProgress.total + planningProgress.total + runtimeProgress.total
  end
  self.progress = {
    state = (introReady and planningReady and runtimeReady) and "ready" or "pending",
    ready = readyCount,
    total = totalCount,
    failure = introFailure or planningFailure or runtimeFailure,
  }
  if introFailure ~= nil then
    error(introFailure, 0)
  end
  if planningFailure ~= nil then
    error(planningFailure, 0)
  end
  if runtimeFailure ~= nil then
    error(runtimeFailure, 0)
  end
  if introReady and planningReady and runtimeReady then
    -- One genuine loader frame precedes the transfer: an otherwise ready
    -- entry never skips its visible stage. This latches only successful
    -- readiness, never readiness itself, and never delays requirement
    -- polling above.
    if not self.drawObserved then
      return
    end
    -- The ready transfer composes the candidate and Oak; a failure there
    -- is composition behavior and raises directly. The latch is set
    -- before the call so a reentrant update cannot transfer twice.
    self.fired = true
    self.phase = "done"
    local transfer = assert(self.onReady, "New Game preparation requires its ready transfer")
    transfer()
    self:_releaseLoading()
  end
end

function NewGamePreparationState:draw()
  local loading = self.loading
  if loading == nil then
    return
  end
  local fraction = nil
  local snapshot = self.progress
  if type(snapshot) == "table" and type(snapshot.total) == "number" and snapshot.total > 0 then
    local ready = type(snapshot.ready) == "number" and snapshot.ready or 0
    if ready < 0 then
      ready = 0
    end
    if ready > snapshot.total then
      ready = snapshot.total
    end
    fraction = ready / snapshot.total
  end
  loading:draw({ message = "Preparing your adventure", fraction = fraction, artFailure = self.loaderArtFailure })
  if not self.fired and not self.cancelled and self.phase ~= "done" then
    self.drawObserved = true
  end
end

function NewGamePreparationState:resize(width, height)
  if self.loading ~= nil then
    self.loading:resize(width, height)
  end
end

---@param key string
function NewGamePreparationState:keypressed(key, _, _)
  if key == "escape" and not self.fired and not self.cancelled then
    self.cancelled = true
    self:_releaseLoading()
    if self.onCancel then
      self.onCancel()
    end
  end
end

function NewGamePreparationState:dispose()
  -- Cancellation or replacement never composes Oak or reserves a
  -- candidate: only this state's references are dropped. The borrowed host
  -- stays with its owner; registered cache interest is non-preemptive and
  -- stays available for a later attempt.
  self.cancelled = true
  self:_releaseLoading()
  self.onReady = nil
  self.onCancel = nil
end

return NewGamePreparationState
