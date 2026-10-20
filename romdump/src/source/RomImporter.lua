-- First-run import orchestration and state machine. Two roles:
--
--   * RomImporter.isReady(versionId) -- the cheap source-binding readiness
--     contract the boot flow depends on. It never opens the ROM or reads
--     large resources: a strict persisted binding suffices, and the actual
--     source bytes are opened lazily on the first genuine cache miss.
--
--   * An interactive/headless importer driving validation inside a
--     coroutine: validate the ROM fully (NdsRom.open: size, SHA-1, header,
--     game code) BEFORE any cache mutation, then atomically record the
--     source binding, yielding periodically so the UI stays responsive.
--     Nothing is extracted: derived caches compile directly from the
--     user-owned ROM on demand. The validated bytes stay available exactly
--     once through takeVerifiedSource for the controller handoff; every
--     other terminal path releases the source and a single GC is run.
--
-- Progress is monotonic by construction (ordered phase fractions). All
-- love coupling is confined to the default `now` clock, the shared-buffer
-- conversion, and the lazy draw helper.

local GameVersion = require("romdump.src.source.GameVersion")
local CacheFs = require("libs.storage.src.CacheFs")
local RomBinding = require("romdump.src.source.RomBinding")
local RomSource = require("romdump.src.source.RomSource")
local NdsRom = require("romdump.src.source.NdsRom")
local Errors = require("libs.errors.src.Errors")

---@class RomImporter
---@field state string
---@field progress number?
---@field private _onComplete (fun(versionId: string, report: table<string, unknown>?): nil)?
---@field private _versions table<string, unknown>?
---@field private _cacheFactory (fun(versionId: string): table<string, unknown>)?
---@field private _now (fun(): number)?
---@field private _expectedVersionId string? edition required by a targeted import
---@field private _verified table<string, unknown>? one-shot validated buffer for the controller handoff
local RomImporter = {}
RomImporter.__index = RomImporter

-- The importer's state vocabulary, shared by the UI/runner consumers so the
-- raw state strings have one owner.
RomImporter.STATES = {
  IDLE = "idle",
  READING = "reading",
  VERIFYING = "verifying",
  REGISTERING = "registering",
  COMPLETE = "complete",
  ERROR = "error",
}

local IMPORT_ERROR_CODES = {
  BUSY = "IMPORT_BUSY",
  NOT_NDS = "IMPORT_NOT_NDS",
}

-- `versions` lets the importer verify readiness against an injected catalog in
-- tests; production callers (boot flow, batch CLI, test runner) use the
-- default GameVersion. Readiness is the strict persisted source binding
-- only: the registered file is never opened here, so a moved ROM never
-- blocks an installed cache and actual bytes load lazily on a real miss.
function RomImporter.isReady(versionId, cache, versions)
  local catalog = versions or GameVersion
  local info
  if type(catalog.info) == "function" then
    local ok, result = pcall(catalog.info, versionId)
    if ok and type(result) == "table" then
      info = result
    end
  elseif type(catalog.VERSIONS) == "table" then
    info = catalog.VERSIONS[versionId]
  end
  if not info then
    return false
  end
  cache = cache or CacheFs.forVersion(versionId)
  local binding = RomBinding.read(cache, versionId, versions)
  return binding ~= nil
end

-- Yield roughly every 8ms of work during validation and registration.
local YIELD_INTERVAL = 0.008

local function defaultNow()
  if love and love.timer then
    return love.timer.getTime()
  end
  return 0
end

-- opts: { onComplete=, versions=, cacheFactory=, now= }. All optional;
-- tests inject a synthetic version catalog, a FakeCache-backed cacheFactory, and
-- a static `now` (which disables yielding, so one update() runs to completion).
function RomImporter.new(opts)
  opts = opts or {}
  local expectedVersionId = opts.expectedVersionId
  if expectedVersionId ~= nil then
    assert(GameVersion.VERSIONS[expectedVersionId], "unknown expected game version")
  end
  return setmetatable({
    _onComplete = opts.onComplete,
    _versions = opts.versions or GameVersion,
    _cacheFactory = opts.cacheFactory or function(id)
      return CacheFs.forVersion(id)
    end,
    _now = opts.now or defaultNow,
    _expectedVersionId = expectedVersionId,
    state = RomImporter.STATES.IDLE,
    progress = 0,
  }, RomImporter)
end

function RomImporter:status()
  return {
    state = self.state,
    versionId = self._versionId,
    displayName = self._displayName,
    sourceName = self._sourceName,
    progress = self.progress or 0,
    stage = self._stage,
    stageLabel = self._stageLabel,
    detail = self._detail,
    report = self._report,
    error = self._error,
    errorCode = self._errorCode,
  }
end

function RomImporter:isBusy()
  local s = RomImporter.STATES
  return self.state == s.READING or self.state == s.VERIFYING or self.state == s.REGISTERING
end

-- The importer owns its state-machine invariant: the start APIs accept every
-- state that is not an in-flight import (idle, complete, and error all
-- restart), and reject new requests while busy without touching the active
-- import.
function RomImporter:_requireNotBusy()
  if self:isBusy() then
    Errors.raise(IMPORT_ERROR_CODES.BUSY, "an import is already in progress", { state = self.state })
  end
end

function RomImporter:_fail(err)
  if self._source then
    self._source:release()
  end
  self._source, self._co, self._verified = nil, nil, nil
  self._error = err
  self._errorCode = Errors.is(err) and err.code or nil
  self.state = RomImporter.STATES.ERROR
  collectgarbage("collect")
end

function RomImporter:_complete(report)
  -- The string source is released, but the validated bytes stay available
  -- exactly once through takeVerifiedSource for the controller handoff.
  if self._source then
    self._source:release()
  end
  self._source, self._co = nil, nil
  self._report = report
  self.progress = 1
  self.state = RomImporter.STATES.COMPLETE
  collectgarbage("collect")
end

---@async
function RomImporter:_onProgress(p)
  self._stage = p.stage
  self._stageLabel = p.stageLabel
  self._detail = p.detail
  self.progress = p.overall
  local now = (self._now --[[@as fun(): number]])()
  if now - (self._lastYield or 0) >= YIELD_INTERVAL then
    self._lastYield = now
    coroutine.yield()
  end
end

-- Hand the validated buffer to the controller exactly once. The import
-- already converted the retained string into the one immutable shared
-- buffer before completion; the first take wraps it in a borrowed view,
-- and later takes (or takes before completion and takes after a failure)
-- answer nil. The bytes never enter the generated cache: only the binding
-- is persisted.
---@return table<string, unknown>? borrowed-source view over the shared buffer
function RomImporter:takeVerifiedSource()
  local verified = self._verified
  if type(verified) ~= "table" or type(verified.byteData) ~= "userdata" then
    return nil
  end
  self._verified = nil
  return RomSource.fromByteData(verified.byteData, verified.displayName)
end

-- Build the coroutine that validates then registers. Kept off the frame
-- thread so update() can spread the work; validation completes before any
-- cache write, and re-registering the same canonical ROM preserves every
-- receipt, asset, and save. A failed validation or registration leaves the
-- previous binding and all derived data untouched.
function RomImporter:_beginWork()
  local source = self._source
  self._co = coroutine.create(function()
    self.state = RomImporter.STATES.VERIFYING
    self._lastYield = (self._now --[[@as fun(): number]])()
    self:_onProgress({ stage = "verifying", stageLabel = "Verifying ROM", overall = 0.25 })
    local rom, err = NdsRom.open(source, self._versions --[[@as table]])
    if not rom then
      return self:_fail(err)
    end

    local info = rom:versionInfo()
    if self._expectedVersionId ~= nil and info.id ~= self._expectedVersionId then
      return self:_fail(
        Errors.new(
          "ROM_VERSION_MISMATCH",
          "selected ROM does not match the requested game version",
          { expectedVersionId = self._expectedVersionId, actualVersionId = info.id }
        )
      )
    end
    self._versionId = info.id
    self._displayName = info.displayName
    self._sourceName = source:displayName()
    local cache = (self._cacheFactory --[[@as fun(versionId: string): table]])(info.id)

    self.state = RomImporter.STATES.REGISTERING
    self:_onProgress({ stage = "registering", stageLabel = "Registering source", overall = 0.6 })
    local origin = source:origin()
    -- A dropped filename is only a candidate location: reopen that exact
    -- path (and member) and keep it solely when the same canonical bytes
    -- answer. Any failure degrades to an ephemeral registration; the
    -- dropped bytes themselves already validated above. The short-lived
    -- verification source is released before the session buffer exists.
    local candidate
    if type(source.reopenCandidatePath) == "function" then
      candidate = source:reopenCandidatePath()
    end
    if type(candidate) == "string" and candidate ~= "" then
      local reopenOptions
      if origin.kind == "zip" and type(origin.zipEntry) == "string" then
        reopenOptions = { zipEntry = origin.zipEntry }
      end
      local ok, durable = pcall(function()
        local reopened = RomSource.fromPath(candidate, reopenOptions)
        if not reopened then
          return false
        end
        local check = NdsRom.open(reopened, self._versions --[[@as table]])
        local same = check ~= nil
          and reopened:origin().kind == origin.kind
          and check:versionInfo().id == info.id
          and check:versionInfo().sha1 == info.sha1
        if check then
          check:release()
        else
          reopened:release()
        end
        return same
      end)
      if ok and durable then
        origin.path = candidate
      end
    end
    local recorded, recordErr = RomBinding.record(cache, rom, {
      kind = origin.kind,
      path = origin.path,
      displayName = origin.displayName,
      zipEntry = origin.zipEntry,
    }, self._versions)
    if not recorded then
      return self:_fail(recordErr)
    end
    self:_onProgress({ stage = "registering", stageLabel = "Registering source", overall = 0.9 })
    local bytes, readErr = source:read(0, source:size())
    if bytes == nil then
      return self:_fail(readErr)
    end
    local byteData = love.data.newByteData(bytes)
    bytes = nil
    -- The validated cartridge wrapper is discarded here; the single
    -- terminal release below owns the string exactly once.
    self._verified = { byteData = byteData, displayName = origin.displayName }
    return self:_complete({
      sha1 = info.sha1,
      kind = origin.kind,
      path = origin.path,
      displayName = origin.displayName,
      zipEntry = origin.zipEntry,
    })
  end)
end

-- Start from an already-opened RomSource (used by tests and the start* helpers).
function RomImporter:startSource(source)
  self:_requireNotBusy()
  assert(source, "startSource requires a RomSource")
  self._source = source
  self._sourceName = source:displayName()
  self._verified = nil
  self._versionId, self._displayName = nil, nil
  self._report, self._error, self._errorCode = nil, nil, nil
  self._stage, self._stageLabel, self._detail = nil, nil, nil
  self._completeFired = false
  self.progress = 0
  self.state = RomImporter.STATES.READING
  self:_beginWork()
end

function RomImporter:startPath(path)
  self:_requireNotBusy()
  local source, err = RomSource.fromPath(path)
  if not source then
    return self:_fail(err)
  end
  return self:startSource(source)
end

function RomImporter:startDroppedFile(droppedFile)
  self:_requireNotBusy()
  local source, err = RomSource.fromDroppedFile(droppedFile)
  if not source then
    return self:_fail(err)
  end
  return self:startSource(source)
end

-- Drop handler with a friendly extension guard. Accepts a
-- raw .nds or a .zip containing one.
function RomImporter:filedropped(droppedFile)
  self:_requireNotBusy()
  local name = droppedFile:getFilename() or ""
  if not name:lower():match("%.nds$") and not name:lower():match("%.zip$") then
    return self:_fail(
      Errors.new(IMPORT_ERROR_CODES.NOT_NDS, "dropped file is not a .nds or .zip ROM: " .. name, { name = name })
    )
  end
  self:startDroppedFile(droppedFile)
end

-- Resume the import coroutine one slice. Safe to call in any state. Fires
-- onComplete exactly once, outside the coroutine, on reaching "complete".
function RomImporter:update()
  local co = self._co
  if co and coroutine.status(co) ~= "dead" then
    local ok, err = coroutine.resume(co)
    if not ok and self.state ~= RomImporter.STATES.ERROR then
      self:_fail(err)
    end
  end
  if self.state == RomImporter.STATES.COMPLETE and not self._completeFired then
    self._completeFired = true
    if self._onComplete then
      self._onComplete(self._versionId, self._report)
    end
  end
end

return RomImporter
