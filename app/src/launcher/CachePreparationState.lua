-- Concrete bootstrap/quiescence/first-play progress state for the app shell. It pumps
-- no compilation itself: normal App updates keep the source session moving
-- while this state waits, displays concrete progress or failure, and
-- transfers exactly once on readiness. A disposed or stale state never
-- fires its completion callback.

local ImportState = require("app.src.launcher.ImportState")
local CacheFs = require("libs.storage.src.CacheFs")
local HgssLoadingPresentation = require("libs.hgss.src.ui.HgssLoadingPresentation")

---@class CachePreparationOptions
---@field kind "bootstrap"|"quiescence"|"first-play"|"boot-source"
---@field epoch integer selected source epoch guarded against stale completion
---@field provisioner? table<string, function> bootstrap/first-play: the borrowed selected session host
---@field preparation? table<string, function> first-play only: the opaque HGSS demand object
---@field importContinuation? table<string, unknown> first-play fresh-import only: immutable captured import display facts
---@field service table<string, function>? quiescence/boot-source: the process cache service, required
---@field barrier integer? quiescence only: the exact source-close barrier token
---@field versionId string? boot-source only: the selected game version shown in the blocked instruction
---@field mismatch string? boot-source only: wrong-version diagnostic shown while staying blocked
---@field isCurrent fun(epoch: integer): boolean owner liveness: the epoch is still selected
---@field onReady fun() exactly-once transfer on readiness
---@field onCancel fun() return to the owning selection
---@field displayContext DisplayContext? host topology and safe-area provider

---@class CachePreparationState
---@field kind string
---@field epoch integer
---@field provisioner table<string, function>?
---@field preparation table<string, function>?
---@field importContinuation table<string, unknown>?
---@field service table<string, function>?
---@field barrier integer?
---@field versionId string?
---@field mismatch string?
---@field sourceDetail unknown? boot-source only: last typed source-required detail
---@field isCurrent fun(epoch: integer): boolean
---@field onReady fun()
---@field onCancel fun()
---@field tick integer
---@field fired boolean
---@field dead boolean
---@field error unknown?
---@field loading table<string, function>
---@field loaderArtObserved boolean
---@field loaderArtFailure unknown?
local CachePreparationState = {}
CachePreparationState.__index = CachePreparationState

local BOOT_VERSION_LABELS = {
  heartgold = "HeartGold",
  soulsilver = "SoulSilver",
}

---@param versionId string?
---@return string display label for the blocked boot instruction
local function bootVersionLabel(versionId)
  if type(versionId) == "string" and BOOT_VERSION_LABELS[versionId] ~= nil then
    return BOOT_VERSION_LABELS[versionId]
  end
  if type(versionId) == "string" and versionId ~= "" then
    return versionId
  end
  return "the selected game"
end

---@param detail unknown
---@return string? reason line for the blocked boot instruction
local function bootReasonText(detail)
  if type(detail) == "table" then
    if type(detail.message) == "string" and detail.message ~= "" then
      return "Reason: " .. detail.message
    end
    if type(detail.code) == "string" and detail.code ~= "" then
      return "Reason: " .. detail.code
    end
    return nil
  end
  if type(detail) == "string" and detail ~= "" then
    return "Reason: " .. detail
  end
  return nil
end

---@param options CachePreparationOptions
---@return CachePreparationState
function CachePreparationState.new(options)
  assert(type(options) == "table", "cache preparation requires its composition")
  assert(
    options.kind == "bootstrap"
      or options.kind == "quiescence"
      or options.kind == "first-play"
      or options.kind == "boot-source",
    "cache preparation kind is required"
  )
  assert(
    type(options.epoch) == "number" and options.epoch % 1 == 0 and options.epoch >= 0,
    "cache preparation epoch must be a non-negative integer"
  )
  assert(type(options.isCurrent) == "function", "cache preparation requires its liveness check")
  assert(type(options.onReady) == "function", "cache preparation requires its transfer")
  assert(type(options.onCancel) == "function", "cache preparation requires its cancellation")
  assert(
    options.importContinuation == nil or options.kind == "first-play",
    "the import continuation only applies to first-play preparation"
  )
  if options.kind == "bootstrap" then
    assert(type(options.provisioner) == "table", "bootstrap preparation requires the selected session host")
  elseif options.kind == "first-play" then
    assert(type(options.provisioner) == "table", "first-play preparation requires the selected session host")
    assert(
      type(options.preparation) == "table"
        and type(options.preparation.poll) == "function"
        and type(options.preparation.dispose) == "function",
      "first-play preparation requires its demand object"
    )
  elseif options.kind == "quiescence" then
    assert(type(options.service) == "table", "quiescence preparation requires the process cache service")
    assert(
      type(options.barrier) == "number" and options.barrier % 1 == 0 and options.barrier >= 1,
      "quiescence preparation requires its exact barrier token"
    )
  end
  if options.kind == "boot-source" then
    assert(type(options.service) == "table", "boot-source preparation requires the process cache service")
    assert(
      options.versionId == nil or type(options.versionId) == "string",
      "boot-source preparation version must be a string"
    )
    assert(
      options.mismatch == nil or type(options.mismatch) == "string",
      "boot-source preparation mismatch must be a string"
    )
  end
  local width, height = love.graphics.getDimensions()
  return setmetatable({
    kind = options.kind,
    epoch = options.epoch,
    provisioner = options.provisioner,
    preparation = options.preparation,
    importContinuation = options.importContinuation,
    service = options.service,
    barrier = options.barrier,
    versionId = options.versionId,
    mismatch = options.mismatch,
    sourceDetail = nil,
    isCurrent = options.isCurrent,
    onReady = options.onReady,
    onCancel = options.onCancel,
    tick = 0,
    fired = false,
    dead = false,
    error = nil,
    loading = HgssLoadingPresentation.new({
      purpose = "startup",
      versionId = options.versionId,
      width = width,
      height = height,
      displayContext = options.displayContext,
    }),
    loaderArtObserved = false,
    loaderArtFailure = nil,
  }, CachePreparationState)
end

function CachePreparationState:_pollLoaderArt()
  if self.loaderArtObserved or self.provisioner == nil or self.versionId == nil then
    return
  end
  if self.kind ~= "bootstrap" and self.kind ~= "first-play" then
    return
  end
  local host = assert(self.provisioner)
  local ok, ready, failure = pcall(host.requestMilestone, "startup-loader", "near")
  if not ok then
    self.loaderArtFailure = ready
    self.loaderArtObserved = true
    return
  end
  if failure ~= nil then
    self.loaderArtFailure = failure
    self.loaderArtObserved = true
  elseif ready then
    local cacheFs = CacheFs.forVersion(self.versionId)
    local adopted, adoptionError = self.loading:adoptGeneratedAssets(cacheFs)
    self.loaderArtObserved = true
    if not adopted then
      self.loaderArtFailure = adoptionError
    end
  end
end

function CachePreparationState:_fire()
  if self.fired or self.dead then
    return
  end
  self.fired = true
  self.onReady()
end

function CachePreparationState:_pollBootstrap()
  local host = assert(self.provisioner, "bootstrap preparation requires the selected session host")
  local ok, ready, failure = pcall(host.requestMilestone, "bootstrap", "required")
  if not ok then
    self.error = ready
    return
  end
  if failure ~= nil then
    self.error = failure
    return
  end
  -- A latched producer failure surfaces even when the milestone probe stays
  -- pending: the public host observation carries the recorded cause.
  local statusOk, statusErr = pcall(host.status)
  if not statusOk then
    self.error = statusErr
    return
  end
  if ready then
    self:_fire()
  end
end

function CachePreparationState:_pollFirstPlay()
  -- The opaque preparation object owns which closures constitute first
  -- play; the launcher only delegates readiness, latches failure, and
  -- fires the transfer. No milestone, map, or loader policy lives here.
  local preparation = assert(self.preparation, "first-play preparation requires its demand object")
  local ok, ready, failure = pcall(preparation.poll, preparation)
  if not ok then
    self.error = ready
    return
  end
  if failure ~= nil then
    self.error = failure
    return
  end
  if ready then
    self:_fire()
  end
end

function CachePreparationState:_pollBootSource()
  -- The boot gate owns no compilation policy: readiness means the full
  -- corpus already attests current or its exact source is pinned below
  -- the controller. Source-required stays blocked with its typed detail,
  -- a genuine controller failure latches as a boot error, and a stale
  -- epoch resolves through the liveness guard without firing.
  local service = assert(self.service, "boot-source preparation requires the process cache service")
  local statusOk, status, detail = pcall(service.bootSourceStatus, service, self.epoch)
  if not statusOk then
    self.error = status
    return
  end
  if status == "ready" then
    self:_fire()
  elseif status == "source-required" then
    self.sourceDetail = detail
  elseif status == "failed" then
    if type(detail) == "table" then
      self.error = detail.message or detail.code or "cache boot failed"
    elseif detail ~= nil then
      self.error = detail
    else
      self.error = "cache boot failed"
    end
  end
end

function CachePreparationState:_pollQuiescence()
  local service = assert(self.service, "quiescence preparation requires the process cache service")
  local barrier = assert(self.barrier, "quiescence preparation requires its exact barrier token")
  -- Only the exact acknowledged barrier transfers: a stale barrier, an
  -- empty queue, or elapsed time never counts as source closure, and raw
  -- import never starts past a recorded failure.
  local statusOk, status = pcall(service.barrierStatus, service, self.epoch, barrier)
  if not statusOk then
    error(status, 0)
  end
  if status == "ready" then
    self:_fire()
  elseif status == "failed" then
    self.error = "cache source closure failed"
  end
end

function CachePreparationState:update(dt)
  self.loading:update(dt or 0)
  if self.fired or self.dead then
    return
  end
  self.tick = self.tick + 1
  local liveOk, live = pcall(self.isCurrent, self.epoch)
  if not liveOk or not live then
    self.dead = true
    return
  end
  self:_pollLoaderArt()
  if self.error ~= nil then
    return
  end
  if self.kind == "bootstrap" then
    self:_pollBootstrap()
  elseif self.kind == "first-play" then
    self:_pollFirstPlay()
  elseif self.kind == "boot-source" then
    self:_pollBootSource()
  else
    self:_pollQuiescence()
  end
end

function CachePreparationState:_drawImportContinuation()
  local host = assert(self.provisioner, "first-play preparation requires the selected session host")
  local preparationStatus = nil
  local statusOk, status = pcall(host.status)
  if statusOk and type(status) == "table" then
    preparationStatus = status
  end
  ImportState.renderContinuation(self.importContinuation, preparationStatus, self.error)
end

function CachePreparationState:draw()
  local message = self.error and "Cache preparation failed"
    or self.kind == "boot-source" and "Waiting for the verified game source"
    or self.kind == "first-play" and "Preparing imported ROM for first play"
    or self.kind == "bootstrap" and "Preparing derived cache"
    or "Waiting for source readers to drain"
  self.loading:draw({ message = message, artFailure = self.loaderArtFailure })
  local lg = love.graphics
  if self.importContinuation ~= nil then
    self:_drawImportContinuation()
    return
  end
  if self.error ~= nil then
    lg.setColor(1, 0.5, 0.5)
    lg.print("Cache preparation failed:", 24, 24)
    lg.printf(tostring(self.error), 24, 48, lg.getWidth() - 48)
    lg.setColor(0.7, 0.7, 0.75)
    lg.print("Press escape to return.", 24, 96)
    return
  end
  lg.setColor(1, 1, 1)
  if self.kind == "boot-source" then
    -- Blocked boot instruction: names the selected game, tells the player
    -- how to supply its matching file, and carries the typed reason and
    -- any wrong-version diagnostic. This prompt exists only here, never
    -- during gameplay.
    lg.print("Preparing " .. bootVersionLabel(self.versionId) .. "...", 24, 24)
    lg.setColor(0.7, 0.7, 0.75)
    lg.print("Drop your matching .nds or .zip file onto this window to finish preparing.", 24, 48)
    local line = 72
    if self.mismatch ~= nil then
      lg.print(tostring(self.mismatch), 24, line)
      line = line + 24
    end
    local reason = bootReasonText(self.sourceDetail)
    if reason ~= nil then
      lg.print(reason, 24, line)
      line = line + 24
    end
    lg.print("Press escape to cancel.", 24, line)
    return
  end
  if self.kind == "first-play" then
    lg.print("Preparing imported ROM for first play...", 24, 24)
    local host = assert(self.provisioner, "first-play preparation requires the selected session host")
    local statusOk, status = pcall(host.status)
    if statusOk and type(status) == "table" then
      lg.setColor(0.7, 0.7, 0.75)
      lg.print(
        string.format("ready %d  queued %d  running %d", status.ready or 0, status.queued or 0, status.running or 0),
        24,
        48
      )
    end
  elseif self.kind == "bootstrap" then
    lg.print("Preparing derived cache...", 24, 24)
    local host = assert(self.provisioner, "bootstrap preparation requires the selected session host")
    local statusOk, status = pcall(host.status)
    if statusOk and type(status) == "table" then
      lg.setColor(0.7, 0.7, 0.75)
      lg.print(
        string.format(
          "bootstrap: %s  ready %d  queued %d  running %d",
          tostring(status.bootstrap),
          status.ready or 0,
          status.queued or 0,
          status.running or 0
        ),
        24,
        48
      )
    end
  else
    lg.print("Waiting for source readers to drain...", 24, 24)
  end
  lg.setColor(0.7, 0.7, 0.75)
  lg.print("Press escape to cancel.", 24, 72)
end

function CachePreparationState:resize(width, height)
  self.loading:resize(width, height)
end

---@param key string
function CachePreparationState:keypressed(key, _, _)
  if key == "escape" and not self.fired and not self.dead then
    self.dead = true
    self.onCancel()
  end
end

function CachePreparationState:filedropped(_)
  -- A replacement dropped while waiting stays queued behind quiescence;
  -- reentering import here would retire the selection under the wait.
end

function CachePreparationState:dispose()
  self.dead = true
  self.loading:dispose()
  -- The opaque first-play object is released exactly once; selection
  -- retirement stays authoritative for the provisioner lifetime.
  local preparation = self.preparation
  self.preparation = nil
  if preparation ~= nil and type(preparation.dispose) == "function" then
    preparation:dispose()
  end
end

return CachePreparationState
