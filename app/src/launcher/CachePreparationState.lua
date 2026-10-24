-- Concrete quiescence/boot-source progress state for the app shell. It pumps
-- no compilation itself: normal App updates keep the source session moving
-- while this state waits, displays concrete progress or failure, and
-- transfers exactly once on readiness. A disposed or stale state never
-- fires its completion callback.

local CacheFs = require("libs.storage.src.CacheFs")
local HgssLoadingPresentation = require("libs.hgss.src.ui.HgssLoadingPresentation")
local ImportState = require("app.src.launcher.ImportState")

-- Structural loading contract shared with the startup owner receiving the
-- transfer: the animated stage plus optional pair adoption. Declared first
-- so the state class below keeps the binding to the module table.
---@class BootLoadingPresentation
---@field adoptGeneratedAssets fun(self: BootLoadingPresentation, cacheFs: unknown): boolean, unknown?
---@field update fun(self: BootLoadingPresentation, dt: number?)
---@field draw fun(self: BootLoadingPresentation, status: unknown?)
---@field resize fun(self: BootLoadingPresentation, width: number, height: number)
---@field dispose fun(self: BootLoadingPresentation)

---@class CachePreparationOptions
---@field kind "quiescence"|"boot-source"
---@field epoch integer selected source epoch guarded against stale completion
---@field service table<string, function> the process cache service, required
---@field barrier integer? quiescence only: the exact source-close barrier token
---@field pendingImportName string? quiescence only: sanitized received filename shown while draining
---@field versionId string? boot-source only: the selected game version shown in the blocked instruction
---@field mismatch string? boot-source only: wrong-version diagnostic shown while staying blocked
---@field pairIndex integer? boot-source only: the selected-epoch walking pair 1..32
---@field freshImport boolean? boot-source only: cold first import holds its card until the pair is drawable
---@field importStatus { state: string?, progress: number?, versionId: string?, displayName: string?, sourceName: string? }? cold only: frozen verified importer snapshot behind the card
---@field importReceipt string? cold only: received filename shown on the retained card
---@field isCurrent fun(epoch: integer): boolean owner liveness: the epoch is still selected
---@field onReady fun() exactly-once transfer on readiness
---@field onCancel fun() return to the owning selection

---@class CachePreparationState
---@field kind string
---@field epoch integer
---@field service table<string, function>
---@field barrier integer?
---@field pendingImportName string?
---@field versionId string?
---@field mismatch string?
---@field pairIndex integer?
---@field freshImport boolean
---@field importStatus { state: string?, progress: number?, versionId: string?, displayName: string?, sourceName: string? }?
---@field importReceipt string?
---@field sourceDetail unknown? boot-source only: last typed source-required detail
---@field isCurrent fun(epoch: integer): boolean
---@field onReady fun()
---@field onCancel fun()
---@field tick integer
---@field fired boolean
---@field dead boolean
---@field error unknown?
---@field loading BootLoadingPresentation? boot-source only: the owned themed presentation
---@field bootAdmitted boolean boot-source only: the gate answered ready for this epoch
---@field walkerReady boolean boot-source only: the selected pair job answered ready
---@field artFailure unknown? cold only: adoption failure held visibly on the card
---@field artFailureOrigin "worker"|"adoption"|nil selected-pair failure provenance: terminal worker record versus retryable local adoption
---@field transferred boolean whether takeLoading detached the owned presentation
---@field released boolean whether the owned presentation was already released
---@field _receiptPainted string? quiescence only: pending filename actually drawn
--- Ownership note: `transferred` (no underscore) is the single detach flag.
---@field _importView ImportState? cold only: the retained compact import card
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

---@return number width
---@return number height current drawable size, safe before the first love frame
local function drawableSize()
  if love ~= nil and love.graphics ~= nil and type(love.graphics.getDimensions) == "function" then
    local ok, width, height = pcall(love.graphics.getDimensions)
    if ok and type(width) == "number" and type(height) == "number" and width > 0 and height > 0 then
      return width, height
    end
  end
  return 800, 600
end

---@param pairIndex unknown
---@return boolean whether the value names a selectable walking pair
local function validPairIndex(pairIndex)
  return type(pairIndex) == "number" and pairIndex % 1 == 0 and pairIndex >= 1 and pairIndex <= 32
end

---@param service table<string, function> the process cache service
---@return boolean whether the service answers the selected-pair interest
local function serviceSupportsWalker(service)
  return type(service.request) == "function" and type(service.observe) == "function"
end

---@param options CachePreparationOptions
---@return CachePreparationState
function CachePreparationState.new(options)
  assert(type(options) == "table", "cache preparation requires its composition")
  assert(options.kind == "quiescence" or options.kind == "boot-source", "cache preparation kind is required")
  assert(
    type(options.epoch) == "number" and options.epoch % 1 == 0 and options.epoch >= 0,
    "cache preparation epoch must be a non-negative integer"
  )
  assert(type(options.isCurrent) == "function", "cache preparation requires its liveness check")
  assert(type(options.onReady) == "function", "cache preparation requires its transfer")
  assert(type(options.service) == "table", "cache preparation requires the process cache service")
  if options.kind == "quiescence" then
    assert(
      type(options.barrier) == "number" and options.barrier % 1 == 0 and options.barrier >= 1,
      "quiescence preparation requires its exact barrier token"
    )
    assert(
      options.pendingImportName == nil or type(options.pendingImportName) == "string",
      "quiescence pending filename must be a string"
    )
  else
    assert(options.pendingImportName == nil, "only the quiescence wait names a pending import")
  end
  if options.kind == "boot-source" then
    assert(
      options.versionId == nil or type(options.versionId) == "string",
      "boot-source preparation version must be a string"
    )
    assert(
      options.mismatch == nil or type(options.mismatch) == "string",
      "boot-source preparation mismatch must be a string"
    )
    assert(
      options.pairIndex == nil or validPairIndex(options.pairIndex),
      "boot-source walking pair must be an integer 1..32"
    )
    assert(
      options.freshImport == nil or type(options.freshImport) == "boolean",
      "cold first import must be a boolean when present"
    )
    if options.freshImport == true then
      assert(validPairIndex(options.pairIndex), "a cold first import must name its selected walking pair")
    end
  end
  -- The themed stage is installed at selection, before any controller
  -- reply: the first visible warm frame already animates, and the cold
  -- card keeps this same presentation ready for its later adoption.
  local bootLoading = nil
  if options.kind == "boot-source" then
    local width, height = drawableSize()
    bootLoading = HgssLoadingPresentation.new({
      versionId = options.versionId,
      pairIndex = options.pairIndex,
      width = width,
      height = height,
    })
  end
  local self = setmetatable({
    kind = options.kind,
    epoch = options.epoch,
    service = options.service,
    barrier = options.barrier,
    versionId = options.versionId,
    mismatch = options.mismatch,
    pairIndex = options.pairIndex,
    freshImport = options.freshImport == true,
    importStatus = options.importStatus,
    importReceipt = options.importReceipt,
    sourceDetail = nil,
    isCurrent = options.isCurrent,
    onReady = options.onReady,
    onCancel = options.onCancel,
    tick = 0,
    fired = false,
    dead = false,
    error = nil,
    loading = bootLoading,
    bootAdmitted = false,
    walkerReady = false,
    artFailure = nil,
    artFailureOrigin = nil,
    transferred = false,
    released = false,
    pendingImportName = options.pendingImportName,
    _receiptPainted = nil,
    _importView = nil,
  }, CachePreparationState)
  if options.kind == "boot-source" and self.freshImport then
    self._importView = self:_coldImportView()
  end
  return self
end

-- The retained compact card for a cold first import: a frozen verified
-- importer snapshot behind the same ImportState drawing the launcher used
-- before admission, plus the selected artwork wait once verified.
---@return ImportState
function CachePreparationState:_coldImportView()
  local snapshot = self.importStatus
  if type(snapshot) ~= "table" then
    snapshot = { state = "complete", progress = 1 }
  end
  local viewImporter = {
    status = function()
      return snapshot
    end,
    isBusy = function()
      return false
    end,
    filedropped = function() end,
  }
  local view = ImportState.new(viewImporter, nil)
  local receipt = self.importReceipt
  if type(receipt) ~= "string" or receipt == "" then
    receipt = type(snapshot.sourceName) == "string" and snapshot.sourceName or nil
  end
  if type(receipt) == "string" and receipt ~= "" then
    view:markReceived(receipt)
  end
  return view
end

function CachePreparationState:_fire()
  if self.fired or self.dead then
    return
  end
  self.fired = true
  self.onReady()
end

-- Releases the owned presentation exactly once. A detached presentation
-- belongs to the transfer target and is never touched here.
function CachePreparationState:_releaseLoading()
  if self.transferred or self.released then
    return
  end
  self.released = true
  local loading = self.loading
  self.loading = nil
  if loading ~= nil then
    loading:dispose()
  end
end

-- Adoption of the selected pair once its keyed worker job is ready. Both
-- warm and cold boots treat the adopted pair as a handoff precondition:
-- a pending job holds the transfer, and a failure latches visibly with a
-- retry path instead of abandoning the sprites.
---@return boolean adopted
---@return unknown? failure
function CachePreparationState:_adoptSelectedPair()
  local loading = assert(self.loading, "boot-source preparation owns its presentation")
  local cacheOk, cacheFs = pcall(CacheFs.forVersion, self.versionId)
  if not cacheOk then
    return false, cacheFs
  end
  return loading:adoptGeneratedAssets(cacheFs)
end

function CachePreparationState:_pollWalker()
  -- An admitted boot transfers only once the selected pair is adopted: the
  -- pair is a required demand on both warm and cold paths, a pending job
  -- simply holds the transfer, and each failure kind latches visibly with
  -- only its truthful remedy. A terminal worker record never heals under
  -- the same epoch, so the worker latch stops every identical re-request
  -- until Escape/reselection mints a fresh epoch. A failed local adoption
  -- stops every automatic re-attempt until one explicit R authorizes one
  -- new attempt against the already-ready worker record.
  if self.artFailureOrigin ~= nil then
    return
  end
  local cold = self.freshImport
  if self.pairIndex ~= nil and serviceSupportsWalker(self.service) then
    -- Demand the selected pair early, even while the source gate is still
    -- blocked, so the worker compiles during the wait. Only the readiness
    -- observation, the GPU adoption, and the transfer below wait for the
    -- admitted gate; the demand itself never does.
    self.service:request(self.epoch, {
      requestKind = "startup-walker",
      pairIndex = self.pairIndex,
      urgency = "required",
    })
    if not self.bootAdmitted then
      return
    end
    local ready, failure = self.service:observe(self.epoch, {
      requestKind = "startup-walker",
      pairIndex = self.pairIndex,
    })
    if ready == true then
      self.walkerReady = true
      local adopted, adoptFailure = self:_adoptSelectedPair()
      if adopted then
        self.artFailure = nil
        self.artFailureOrigin = nil
        self:_fire()
        return
      end
      self.artFailure = adoptFailure
      self.artFailureOrigin = "adoption"
      return
    end
    if failure ~= nil then
      self.artFailure = failure
      self.artFailureOrigin = "worker"
      return
    end
    return
  end
  if not cold then
    self:_fire()
  end
end

function CachePreparationState:_pollBootSource()
  -- The boot gate owns no compilation policy: readiness means the full
  -- corpus already attests current or its exact source is pinned below
  -- the controller. Source-required stays blocked with its typed detail,
  -- a genuine controller failure latches as a boot error, and a stale
  -- epoch resolves through the liveness guard without firing. The
  -- selected pair is demanded early, even while blocked, so the worker
  -- compiles during the wait; only adoption and transfer wait for the
  -- admitted gate, and the pair answer and, on a cold import, its GPU
  -- adoption are separate facts after that.
  local service = assert(self.service, "boot-source preparation requires the process cache service")
  local statusOk, status, detail = pcall(service.bootSourceStatus, service, self.epoch)
  if not statusOk then
    self.error = status
    return
  end
  if status == "ready" then
    self.bootAdmitted = true
    self:_pollWalker()
  elseif status == "source-required" then
    -- A blocked boot still demands its selected pair early while the
    -- matching-ROM remedy stays visible: the demand never transfers, and
    -- adoption still waits for admission below.
    self.sourceDetail = detail
    self:_pollWalker()
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
  if self.fired or self.dead then
    return
  end
  self.tick = self.tick + 1
  local liveOk, live = pcall(self.isCurrent, self.epoch)
  if not liveOk or not live then
    self.dead = true
    return
  end
  if self.kind == "boot-source" and self.loading ~= nil and not self.transferred then
    self.loading:update(dt)
  end
  if self.error ~= nil then
    return
  end
  if self.kind == "boot-source" then
    self:_pollBootSource()
  else
    self:_pollQuiescence()
  end
end

function CachePreparationState:draw()
  local lg = love.graphics
  local width, height = lg.getDimensions()
  lg.setColor(0.055, 0.09, 0.13, 1)
  lg.rectangle("fill", 0, 0, width, height)
  -- A warm boot-source wait keeps its animated stage even after the gate
  -- fails: the error overlays the loader instead of replacing it, so the
  -- first visible frame stays themed while the failure stays actionable.
  -- Quiescence and a cold first import keep the legacy error screen, whose
  -- escape path returns to selection with a new epoch.
  if self.error ~= nil and not (self.kind == "boot-source" and not self.freshImport) then
    lg.setColor(1, 0.5, 0.5)
    lg.print("Cache preparation failed:", 24, 24)
    lg.printf(tostring(self.error), 24, 48, lg.getWidth() - 48)
    lg.setColor(0.7, 0.7, 0.75)
    lg.print("Press escape to return.", 24, 96)
    return
  end
  if self.kind == "boot-source" then
    self:_drawBootSource()
    return
  end
  lg.setColor(1, 1, 1)
  lg.print("Waiting for source readers to drain...", 24, 24)
  -- A file received while the barrier is pending is acknowledged on this
  -- same wait: the name below is a receipt, never a readiness claim, and
  -- its paint is the fact the shell's import ordering waits for.
  self._receiptPainted = nil
  if type(self.pendingImportName) == "string" and self.pendingImportName ~= "" then
    lg.print("File received " .. self.pendingImportName, 24, 48)
    self._receiptPainted = self.pendingImportName
  end
  lg.setColor(0.7, 0.7, 0.75)
  lg.print("Press escape to cancel.", 24, 72)
end

-- Fact for the shell's import ordering: the pending filename counts as
-- painted only once this wait actually rendered it.
---@return string? the pending filename painted by the latest draw, or nil
function CachePreparationState:paintedReceipt()
  return self._receiptPainted
end

function CachePreparationState:_drawBootSource()
  -- A cold first import stays on its compact card until the selected pair
  -- is genuinely drawable. An ordinary warm boot instead paints the live
  -- themed stage from its first frame and overlays only a compact
  -- matching-ROM instruction while the source gate stays blocked.
  if self.freshImport then
    assert(self._importView ~= nil, "a cold first import retains its import card")
    self._importView:draw({
      stage = "artwork",
      failure = self.artFailure,
      retryable = self.artFailureOrigin == "adoption",
    })
    return
  end
  local loading = assert(self.loading, "boot-source preparation owns its presentation")
  loading:draw()
  if self.error ~= nil then
    local lg = love.graphics
    lg.setColor(1, 0.5, 0.5, 1)
    lg.print("Cache preparation failed:", 24, 24)
    lg.printf(tostring(self.error), 24, 48, lg.getWidth() - 48)
    lg.setColor(0.7, 0.7, 0.75)
    lg.print("Press escape to return.", 24, 96)
    return
  end
  -- A failed selected pair holds the transfer with its own actionable
  -- remedy: the failure and its retry key read beside the animating stage
  -- instead of replacing it, so recovery stays visible while nothing
  -- half-adopted ever leaves the wait.
  if self.artFailure ~= nil then
    local lg = love.graphics
    lg.setColor(1, 0.65, 0.5, 1)
    lg.print("Selected pair unavailable.", 24, 24)
    local reason = bootReasonText(self.artFailure)
    if reason ~= nil then
      lg.printf(reason, 24, 48, lg.getWidth() - 48)
    end
    lg.setColor(0.7, 0.78, 0.8, 1)
    -- Only a latched local adoption failure can run again in this epoch:
    -- a terminal worker record offers Escape/reselection alone and never
    -- advertises a retry the service cannot perform.
    if self.artFailureOrigin == "adoption" then
      lg.print("Press R to retry the selected pair.", 24, 96)
      lg.print("Press escape to cancel.", 24, 120)
    else
      lg.print("Press escape to reselect.", 24, 96)
    end
    return
  end
  -- An admitted gate draws only the themed stage while ordinary pair work
  -- is still pending: transitional frames carry no internal copy. The
  -- matching-ROM remedy below is reserved for a genuinely blocked boot,
  -- which keeps it visible from the first frame while the stage animates
  -- underneath it; the typed reason joins once the gate replies.
  if self.bootAdmitted then
    return
  end
  local lg = love.graphics
  lg.setColor(0.94, 0.94, 0.9, 1)
  lg.print("Provide the matching " .. bootVersionLabel(self.versionId) .. " ROM", 24, 24)
  lg.setColor(0.7, 0.78, 0.8, 1)
  local line = 48
  if self.mismatch ~= nil then
    lg.print(self.mismatch, 24, line)
    line = line + 24
  end
  -- The remedy stays visible beside any reported reason: a blocked boot
  -- always tells the player how to supply the matching file.
  lg.print("Drop your .nds or .zip file onto this window.", 24, line)
  line = line + 24
  local reason = bootReasonText(self.sourceDetail)
  if reason ~= nil then
    lg.print(reason, 24, line)
    line = line + 24
  end
  lg.print("Press escape to cancel.", 24, line)
end

-- Detaches and returns the one owned presentation. Legal only after the
-- boot gate answered ready and, on a cold first import, after the selected
-- pair was adopted; exactly once. The old state never disposes detached
-- art: ownership moves to the transfer target with this call.
---@return BootLoadingPresentation the live loading presentation
function CachePreparationState:takeLoading()
  assert(self.kind == "boot-source", "only the boot-source wait owns a transferable presentation")
  assert(not self.transferred, "the loading presentation was already transferred")
  assert(self.fired, "the loading presentation is not ready for transfer")
  local loading = assert(self.loading, "the loading presentation is no longer owned here")
  self.transferred = true
  return loading
end

function CachePreparationState:resize(width, height)
  if self.kind == "boot-source" and self.loading ~= nil and not self.transferred then
    self.loading:resize(width, height)
  end
end

---@param key string
function CachePreparationState:keypressed(key, _, _)
  if self.fired or self.dead then
    return
  end
  if key == "escape" then
    self.dead = true
    self:_releaseLoading()
    self.onCancel()
  elseif key == "r" and self.artFailureOrigin == "adoption" then
    -- Bounded retry: one new local adoption attempt against the
    -- already-ready worker record on the next admitted update, without
    -- re-verifying the source or reopening the terminal worker record. R
    -- is a no-op for terminal worker failures and at all other times.
    self.artFailure = nil
    self.artFailureOrigin = nil
  end
end

function CachePreparationState:filedropped(_)
  -- A replacement dropped while waiting stays queued behind quiescence;
  -- reentering import here would retire the selection under the wait.
end

function CachePreparationState:dispose()
  self.dead = true
  self._receiptPainted = nil
  self:_releaseLoading()
end

return CachePreparationState
