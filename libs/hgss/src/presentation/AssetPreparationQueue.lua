-- One persistent presentation preparation worker behind a two-priority
-- request queue. Cache I/O, mesh decode/validation/upload packing, image
-- CPU decode, and private image-derivative classification run on the worker
-- thread; the main thread only resolves cache paths, polls non-blocking (or
-- waits where its caller already requires a synchronous result), and realizes
-- prepared payloads into GPU objects it owns. Demand requests dispatch ahead
-- of queued prefetch requests, but a running worker job is never preempted.
-- Channel messages stay flat; bulk memory crosses as love Data/ImageData
-- userdata.

---@class AssetPreparationQueue
---@field _cacheFs table<string, unknown>
---@field _versionId string
---@field _request table<string, unknown>
---@field _reply table<string, unknown>
---@field _worker table<string, unknown>
---@field _tokens table<integer, table<string, unknown>>
---@field _demand integer[]
---@field _prefetch integer[]
---@field _inflight table<string, integer> identical queued-or-running job key to owning primary token
---@field _forwarded table<integer, integer> dispatched token to promoted owner after a running primary is cancelled
---@field _workerBusyToken integer?
---@field _workerFailure string?
---@field _nextToken integer
---@field _released boolean
---@field _joined boolean
---@field _readyPayloadLimit integer upper bound on ready-but-unclaimed payload bytes
---@field _readyPayloadBytes integer currently held ready-but-unclaimed payload bytes
local AssetPreparationQueue = {}
AssetPreparationQueue.__index = AssetPreparationQueue

local WORKER_MODULE = "libs.hgss.src.presentation.asset_preparation_worker"

-- The literal thread entry: install the explicitly supplied development
-- search path when required (checkout runs, where the worker file is not
-- visible to the thread otherwise), then resolve the worker module through
-- the packaged require path and enter its channel loop. Packaged builds
-- resolve the module from the source archive; no checkout file is read.
local BOOTSTRAP = string.format(
  [[
local requestChannel, replyChannel, developmentPath = ...
if type(developmentPath) == "string" and developmentPath ~= "" then
  package.path = developmentPath
end
local Worker = require(%q)
Worker.run(requestChannel, replyChannel)
]],
  WORKER_MODULE
)

local VALID_KINDS = { mesh = true, image = true, ["image-derivative"] = true, ["audio-sample"] = true }
local VALID_PRIORITIES = { demand = true, prefetch = true }

-- Default ceiling for completed-but-unclaimed payload bytes held on the
-- main thread. Prefetch dispatch pauses while the ceiling is reached so an
-- over-cap prediction cannot spike transient RAM; demand work still
-- dispatches so actual gameplay never starves behind prefetch.
local DEFAULT_READY_PAYLOAD_LIMIT = 8 * 1024 * 1024

-- Upper bound between worker-liveness probes while a synchronous wait blocks
-- on the reply channel.
local WAIT_HEALTH_PROBE_SECONDS = 0.05

---@class AssetPreparationQueueOptions
---@field thread table<string, unknown>? injectable love.thread-shaped namespace (defaults to the global one)
---@field workerSource unknown? worker entry point override, passed to the thread constructor
---@field readyPayloadByteLimit integer? ceiling for ready-but-unclaimed payload bytes

-- cacheFs resolves and confines every logical path on the main thread before
-- dispatch; the worker only ever sees the confined save-relative path.
---@param cacheFs table<string, unknown>
---@param options AssetPreparationQueueOptions?
---@return AssetPreparationQueue
function AssetPreparationQueue.new(cacheFs, options)
  assert(cacheFs and cacheFs.resolve, "AssetPreparationQueue requires a CacheFs-shaped object")
  assert(
    type(cacheFs.versionId) == "string" and cacheFs.versionId ~= "",
    "AssetPreparationQueue requires a versioned CacheFs"
  )
  options = options or {}
  local threadHost = options.thread or (love and love.thread)
  assert(threadHost and threadHost.newChannel and threadHost.newThread, "AssetPreparationQueue requires love.thread")
  local requestChannel = threadHost.newChannel()
  local replyChannel = threadHost.newChannel()
  local workerSource = options.workerSource
  if workerSource == nil then
    workerSource = BOOTSTRAP
  end
  local worker = threadHost.newThread(workerSource)
  local readyLimit = options.readyPayloadByteLimit or DEFAULT_READY_PAYLOAD_LIMIT
  assert(
    type(readyLimit) == "number" and readyLimit >= 0,
    "AssetPreparationQueue ready payload bound must be a non-negative byte count"
  )
  local self = setmetatable({
    _cacheFs = cacheFs,
    _versionId = cacheFs.versionId,
    _request = requestChannel,
    _reply = replyChannel,
    _worker = worker,
    _tokens = {},
    _demand = {},
    _prefetch = {},
    _inflight = {},
    _forwarded = {},
    _workerBusyToken = nil,
    _workerFailure = nil,
    _nextToken = 0,
    _released = false,
    _joined = false,
    _readyPayloadLimit = readyLimit,
    _readyPayloadBytes = 0,
  }, AssetPreparationQueue)
  worker:start(requestChannel, replyChannel, package.path)
  return self
end

-- Drop an already-cancelled head entry; cancellation removes queued tokens
-- eagerly, so this only guards against stale references.
---@param pending integer[]
---@return integer?
function AssetPreparationQueue:_shiftLive(pending)
  while #pending > 0 do
    local token = table.remove(pending, 1)
    if self._tokens[token] then
      return token
    end
  end
  return nil
end

-- Dispatch one job while the worker is physically idle, choosing queued
-- demand work before queued prefetch work. While ready-but-unclaimed
-- payloads reach the transient ceiling, prefetch dispatch pauses and demand
-- still flows. Physical idleness is authoritative:
-- a token cancelled after dispatch keeps occupying the worker until its late
-- reply (or the worker's death) frees the slot.
function AssetPreparationQueue:_dispatch()
  if self._released or self._workerFailure ~= nil or self._workerBusyToken ~= nil then
    return
  end
  local token = self:_shiftLive(self._demand)
  if token == nil and self._readyPayloadBytes < self._readyPayloadLimit then
    token = self:_shiftLive(self._prefetch)
  end
  if token == nil then
    return
  end
  local record = assert(self._tokens[token], "dispatched an unknown preparation token")
  record.state = "running"
  self._workerBusyToken = token
  self._request:push({
    op = "prepare",
    token = token,
    kind = record.kind,
    path = record.path,
    versionId = self._versionId,
    logicalPath = record.logicalPath,
  })
end

-- Best-effort byte size for one absorbed payload, so the transient
-- ready-but-unclaimed ceiling stays honest across payload kinds. Unknown
-- shapes count zero rather than blocking the bound.
---@param kind string
---@param payload table<string, unknown>
---@return integer
function AssetPreparationQueue:_payloadByteSize(kind, payload)
  if kind == "audio-sample" then
    if type(payload.size) == "number" and payload.size >= 0 then
      return math.floor(payload.size)
    end
    local data = payload.byteData
    if type(data) == "table" or type(data) == "userdata" then
      local ok, size = pcall(function()
        return (data --[[@as { getSize: fun(self: table): integer }]]):getSize()
      end)
      if ok and type(size) == "number" and size >= 0 then
        return math.floor(size)
      end
    end
    return 0
  end
  local total = 0
  for _, field in ipairs({ "indexData", "paletteData", "vertexData", "imageData" }) do
    local data = payload[field]
    if type(data) == "string" then
      total = total + #data
    elseif type(data) == "table" or type(data) == "userdata" then
      local ok, size = pcall(function()
        local sized = data --[[@as { getSize: fun(self: table): integer }]]
        if type(sized.getSize) == "function" then
          return sized:getSize()
        end
        return 0
      end)
      if ok and type(size) == "number" and size > 0 then
        total = total + math.floor(size)
      elseif type(data.getString) == "function" then
        local stringOk, bytes = pcall(function()
          return (data --[[@as { getString: fun(self: table): string }]]):getString()
        end)
        if stringOk and type(bytes) == "string" then
          total = total + #bytes
        end
      end
    end
  end
  return total
end

-- Releases one token's accounted ready payload bytes exactly once.
---@param record table<string, unknown>
function AssetPreparationQueue:_forgetReadyPayload(record)
  local accounted = record.payloadBytes --[[@as integer?]]
  if type(accounted) == "number" and accounted > 0 then
    record.payloadBytes = 0
    self._readyPayloadBytes = self._readyPayloadBytes - accounted
    if self._readyPayloadBytes < 0 then
      self._readyPayloadBytes = 0
    end
  end
end

-- Retunes the transient ready-payload ceiling. Already-held payloads stay
-- transferable; the new bound only gates further prefetch dispatch.
---@param limit integer
function AssetPreparationQueue:setReadyPayloadByteLimit(limit)
  assert(type(limit) == "number" and limit >= 0, "ready payload bound must be a non-negative byte count")
  self._readyPayloadLimit = limit
end

-- Record an unexpected worker exit exactly once: every still-live queued or
-- running token fails with the terminal cause while already-ready payloads
-- stay transferable. The queue never restarts the worker.
---@param cause string?
function AssetPreparationQueue:_enterTerminalFailure(cause)
  if self._workerFailure ~= nil then
    return
  end
  if cause == nil then
    cause = "worker exited without an error"
  end
  self._workerFailure = "asset preparation worker stopped: " .. tostring(cause)
  for _, record in pairs(self._tokens) do
    if record.state == "queued" or record.state == "running" or record.state == "linked" then
      record.state = "failed"
      record.failure = self._workerFailure
      record.link = nil
    end
  end
  self._demand = {}
  self._prefetch = {}
  self._inflight = {}
  self._forwarded = {}
  self._workerBusyToken = nil
end

-- Detect an unexpected worker exit after draining replies. Thread hosts
-- without an isRunning probe stay usable; a production LÖVE Thread reporting
-- a stopped worker terminalizes the queue.
function AssetPreparationQueue:_checkWorkerHealth()
  if self._released or self._workerFailure ~= nil then
    return
  end
  local worker = self._worker
  if type(worker.isRunning) ~= "function" then
    return
  end
  local ok, running = pcall(function()
    return worker:isRunning()
  end)
  if ok and running then
    return
  end
  if not ok then
    self:_enterTerminalFailure(running)
    return
  end
  local cause = nil
  if type(worker.getError) == "function" then
    local _, workerError = pcall(function()
      return worker:getError()
    end)
    cause = workerError
  end
  self:_enterTerminalFailure(cause)
end

-- Absorb one worker reply: free the matching physical slot first (even when
-- the logical token was cancelled and no longer exists), then publish or
-- discard the logical result. Replacement dispatch is left to the public
-- operation that observes the freed slot. Already resolved tokens are never
-- overwritten by late replies. A reply for a cancelled primary fans out to
-- the promoted follower through the forwarding table instead.
---@param response unknown
function AssetPreparationQueue:_absorb(response)
  if type(response) ~= "table" then
    return
  end
  if self._workerBusyToken == response.token then
    self._workerBusyToken = nil
  end
  local token = self._forwarded[response.token]
  if token ~= nil then
    self._forwarded[response.token] = nil
    if self._workerBusyToken == token then
      self._workerBusyToken = nil
    end
  else
    token = response.token
  end
  local record = self._tokens[token]
  if record == nil then
    return
  end
  if record.state ~= "queued" and record.state ~= "running" then
    return
  end
  if response.ok then
    self:_publishOk(record, response)
  else
    record.state = "failed"
    record.failure = response.error
  end
  self:_detachFollowers(token, record, response)
end

---@param record table<string, unknown>
---@param response table<string, unknown>
function AssetPreparationQueue:_publishOk(record, response)
  record.state = "ready"
  if record.kind == "audio-sample" then
    record.payload = {
      byteData = response.byteData,
      size = response.size,
      path = response.path,
    }
    record.payloadBytes = self:_payloadByteSize(record.kind, record.payload)
    self._readyPayloadBytes = self._readyPayloadBytes + (record.payloadBytes or 0)
    return
  end
  if record.kind == "image-derivative" then
    record.payload = {
      sourceHash = response.sourceHash,
      pixelHash = response.pixelHash,
      width = response.width,
      height = response.height,
      kind = response.representation,
      colors = response.colors,
      indexData = response.indexData,
      paletteData = response.paletteData,
    }
    record.payloadBytes = self:_payloadByteSize(record.kind, record.payload)
    self._readyPayloadBytes = self._readyPayloadBytes + (record.payloadBytes or 0)
    return
  end
  record.payload = {
    vertexData = response.vertexData,
    indexData = response.indexData,
    vertexCount = response.vertexCount,
    indexCount = response.indexCount,
    indexType = response.indexType,
    centerX = response.centerX,
    centerY = response.centerY,
    centerZ = response.centerZ,
    minX = response.minX,
    maxX = response.maxX,
    minY = response.minY,
    maxY = response.maxY,
    minZ = response.minZ,
    maxZ = response.maxZ,
    imageData = response.imageData,
  }
  record.payloadBytes = self:_payloadByteSize(record.kind, record.payload)
  self._readyPayloadBytes = self._readyPayloadBytes + (record.payloadBytes or 0)
end

-- Detach every follower linked to a settled primary: each follower
-- observes the same outcome through its own payload copy, so take-once
-- and cancellation semantics stay per-token while the worker ran once.
---@param primary integer settled primary token
---@param record table<string, unknown> settled primary record
---@param response table<string, unknown> worker reply behind the outcome
function AssetPreparationQueue:_detachFollowers(primary, record, response)
  local key = record.kind .. "\0" .. record.path
  if self._inflight[key] == primary then
    self._inflight[key] = nil
  end
  for _, otherRecord in pairs(self._tokens) do
    if otherRecord.link == primary then
      otherRecord.link = nil
      if response.ok then
        self:_publishOk(otherRecord, response)
      else
        otherRecord.state = "failed"
        otherRecord.failure = response.error
      end
    end
  end
end

-- Upgrade a queued job to demand priority without dispatching it again.
-- A running job is never preempted; the upgrade only affects list order.
---@param primary integer owning primary token
function AssetPreparationQueue:_ensureDemand(primary)
  local record = self._tokens[primary]
  if record == nil or record.priority == "demand" or record.state ~= "queued" then
    return
  end
  record.priority = "demand"
  for _, pending in ipairs({ self._demand, self._prefetch }) do
    for index, queued in ipairs(pending) do
      if queued == primary then
        table.remove(pending, index)
        break
      end
    end
  end
  self._demand[#self._demand + 1] = primary
end

-- Drain every pending worker reply without blocking.
function AssetPreparationQueue:_drain()
  while true do
    local response = self._reply:pop()
    if response == nil then
      return
    end
    self:_absorb(response)
  end
end

---@param kind "mesh"|"image"|"image-derivative"|"audio-sample"
---@param logicalPath string
---@param priority "demand"|"prefetch"
---@return integer
function AssetPreparationQueue:request(kind, logicalPath, priority)
  assert(not self._released, "asset preparation queue is released")
  assert(VALID_KINDS[kind], "unknown preparation kind " .. tostring(kind))
  assert(VALID_PRIORITIES[priority], "unknown preparation priority " .. tostring(priority))
  assert(type(logicalPath) == "string", "preparation path is required")
  self:_drain()
  self:_checkWorkerHealth()
  if self._workerFailure ~= nil then
    error(self._workerFailure, 0)
  end
  local resolved = self._cacheFs:resolve(logicalPath)
  local key = kind .. "\0" .. resolved
  self._nextToken = self._nextToken + 1
  local token = self._nextToken
  -- An identical queued-or-running job runs once: the duplicate links to
  -- it and observes the shared outcome through its own token, so
  -- per-frame re-requests never stack duplicate worker decodes.
  local primary = self._inflight[key]
  local primaryRecord = primary ~= nil and self._tokens[primary] or nil
  if primaryRecord ~= nil and (primaryRecord.state == "queued" or primaryRecord.state == "running") then
    self._tokens[token] = {
      kind = kind,
      logicalPath = logicalPath,
      path = resolved,
      priority = priority,
      state = "linked",
      link = primary,
    }
    if priority == "demand" then
      self:_ensureDemand(primary)
    end
    self:_dispatch()
    return token
  end
  self._tokens[token] =
    { kind = kind, logicalPath = logicalPath, path = resolved, priority = priority, state = "queued" }
  self._inflight[key] = token
  if priority == "demand" then
    self._demand[#self._demand + 1] = token
  else
    self._prefetch[#self._prefetch + 1] = token
  end
  self:_dispatch()
  return token
end

-- Non-blocking state probe; never transfers the payload. Returns "pending",
-- "ready", or "failed" plus the worker's failure cause for failed work.
---@param token integer
---@return string, string?
function AssetPreparationQueue:poll(token)
  local record = self._tokens[token]
  assert(record, "unknown preparation token")
  self:_drain()
  self:_checkWorkerHealth()
  self:_dispatch()
  record = self._tokens[token]
  assert(record, "unknown preparation token")
  if record.state == "ready" then
    return "ready"
  end
  if record.state == "failed" then
    return "failed", record.failure
  end
  return "pending"
end

-- Transfer a ready payload exactly once. Unknown, pending, failed, or
-- already-transferred tokens fail loudly instead of reviving work.
---@param token integer
---@return table<string, unknown>
function AssetPreparationQueue:take(token)
  local record = self._tokens[token]
  assert(record, "unknown preparation token")
  self:_drain()
  self:_dispatch()
  record = self._tokens[token]
  assert(record, "unknown preparation token")
  assert(record.state == "ready", "preparation result is not ready")
  self:_forgetReadyPayload(record)
  self._tokens[token] = nil
  return assert(record.payload, "ready preparation has no payload")
end

-- Drop logical interest; a running job is not preempted and its late result
-- is discarded when it returns. The physical slot stays occupied until that
-- reply (or the worker's death) frees it, so cancellation never fabricates
-- worker idleness and priority is decided at the next physical dispatch.
---@param token integer
function AssetPreparationQueue:cancel(token)
  local record = assert(self._tokens[token], "unknown preparation token")
  self:_forgetReadyPayload(record)
  self._tokens[token] = nil
  for _, pending in ipairs({ self._demand, self._prefetch }) do
    for index, queued in ipairs(pending) do
      if queued == token then
        table.remove(pending, index)
        break
      end
    end
  end
  if record.link ~= nil then
    return
  end
  -- A cancelled primary hands its job to its oldest follower instead of
  -- abandoning the shared work: the worker runs once either way.
  local key = record.kind .. "\0" .. record.path
  if self._inflight[key] ~= token then
    return
  end
  self._inflight[key] = nil
  local heir = nil
  for other, otherRecord in pairs(self._tokens) do
    if otherRecord.link == token and (heir == nil or other < heir) then
      heir = other
    end
  end
  if heir == nil then
    return
  end
  local heirRecord = assert(self._tokens[heir], "promoted follower is missing")
  heirRecord.link = nil
  self._inflight[key] = heir
  for _, otherRecord in pairs(self._tokens) do
    if otherRecord.link == token then
      otherRecord.link = heir
    end
  end
  if record.state == "running" then
    heirRecord.state = "running"
    self._forwarded[token] = heir
    self._workerBusyToken = heir
  else
    heirRecord.state = "queued"
    if heirRecord.priority == "demand" then
      self._demand[#self._demand + 1] = heir
    else
      self._prefetch[#self._prefetch + 1] = heir
    end
  end
end

-- Upgrade a queued prefetch token to demand without dispatching it again:
-- the same token keeps its identity and outranks later prefetch work at the
-- next physical dispatch. Idempotent for demand, running, ready, or failed
-- tokens; unknown or already-released tokens fail loudly. A running token is
-- never re-dispatched. Promotion itself never dispatches; the next poll,
-- wait, or request performs the replacement dispatch.
---@param token integer
---@param priority "demand"
function AssetPreparationQueue:promote(token, priority)
  assert(priority == "demand", "unknown preparation priority " .. tostring(priority))
  local record = self._tokens[token]
  assert(record, "unknown preparation token")
  if record.link ~= nil then
    self:_ensureDemand(record.link)
    return
  end
  if record.state ~= "queued" or record.priority == "demand" then
    return
  end
  record.priority = "demand"
  for index, queued in ipairs(self._prefetch) do
    if queued == token then
      table.remove(self._prefetch, index)
      break
    end
  end
  self._demand[#self._demand + 1] = token
end

-- Block efficiently until one token's payload is transferred, absorbing any
-- unrelated token results along the way. Only synchronous callers whose path
-- already requires the result may wait; staged work polls instead.
---@param token integer
---@return table<string, unknown>
function AssetPreparationQueue:wait(token)
  assert(self._tokens[token], "unknown preparation token")
  while true do
    self:_drain()
    self:_checkWorkerHealth()
    self:_dispatch()
    local record = self._tokens[token]
    assert(record, "unknown preparation token")
    if record.state == "ready" then
      self:_forgetReadyPayload(record)
      self._tokens[token] = nil
      return assert(record.payload, "ready preparation has no payload")
    end
    if record.state == "failed" then
      error("asset preparation failed for " .. tostring(record.logicalPath) .. ": " .. tostring(record.failure), 0)
    end
    local response = self._reply:demand(WAIT_HEALTH_PROBE_SECONDS)
    if response ~= nil then
      self:_absorb(response)
      self:_dispatch()
    end
  end
end

-- Stop accepting work, drop every outstanding token, ask the worker to stop
-- after its current job, join it, and discard unclaimed payloads.
-- Idempotent: the worker is joined exactly once.
function AssetPreparationQueue:release()
  if self._released then
    return
  end
  self._released = true
  self._tokens = {}
  self._demand = {}
  self._prefetch = {}
  self._inflight = {}
  self._forwarded = {}
  self._workerBusyToken = nil
  self._readyPayloadBytes = 0
  pcall(function()
    self._request:push({ op = "shutdown" })
  end)
  if not self._joined then
    self._joined = true
    self._worker:wait()
  end
  while self._reply:pop() ~= nil do
  end
end

return AssetPreparationQueue
