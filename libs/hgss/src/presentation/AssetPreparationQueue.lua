-- One persistent presentation preparation worker behind a two-priority
-- request queue, plus the shared decoded CPU ownership every consumer of its
-- results holds. Mesh decode/validation/upload packing, image CPU decode, and
-- private image-derivative classification run on the worker thread; the main
-- thread owns the results: it resolves the selected epoch's resident payload,
-- keys the request by source identity plus decode selector, publishes one
-- immutable typed value into the shared residency kernel, and hands every
-- surviving requester its own kernel lease over that value. Demand requests
-- dispatch ahead of queued prefetch requests, but a running worker job is never
-- preempted. Channel messages stay flat; bulk memory crosses as love
-- Data/ImageData, and no native pointer is ever serialized. The worker is
-- created on the first actual asynchronous dispatch, so compact base
-- acquisition (messages, collision, PCM) needs no thread host at all.

---@class AssetPreparationQueueOptions
---@field decoded ResidentAssetCache the selected epoch's decoded CPU owner
---@field thread table<string, unknown>? injectable love.thread-shaped namespace (defaults to the global one)
---@field workerSource unknown? worker entry point override, passed to the thread constructor
---@field readyPayloadByteLimit integer? ceiling for ready-but-unclaimed payload bytes

---@class AssetPreparationQueueRecord
---@field token integer
---@field kind string
---@field path string generated file path
---@field selector ModelAsset.TextureReference? native bank texture/palette selector for g4tx
---@field data love.Data immutable resident payload handed to the worker
---@field key string decoded-value identity in the shared CPU owner
---@field priority "demand"|"prefetch"
---@field state "queued"|"running"|"linked"|"ready"|"failed"
---@field link integer? primary token this follower observes
---@field failure string?
---@field lease ResidentAssetCacheLease? this token's own borrow, until take/wait/cancel
---@field readyReserved boolean? true while its key holds one scheduling reservation

---@class AssetPreparationQueueSourceLease
---@field value love.Data borrowed resident bytes
---@field release fun(self: AssetPreparationQueueSourceLease)

---@class AssetPreparationQueue
---@field private _cacheFs table<string, unknown>
---@field private _decoded ResidentAssetCache
---@field private _threadHost table<string, unknown>?
---@field private _workerSource unknown?
---@field private _request table<string, unknown>?
---@field private _reply table<string, unknown>?
---@field private _worker table<string, unknown>?
---@field private _tokens table<integer, AssetPreparationQueueRecord>
---@field private _demand integer[]
---@field private _prefetch integer[]
---@field private _inflight table<string, integer> identical queued-or-running job key to owning primary token
---@field private _forwarded table<integer, integer> dispatched token to promoted owner after a running primary is cancelled
---@field private _workerBusyToken integer?
---@field private _workerFailure string?
---@field private _nextToken integer
---@field private _released boolean
---@field private _joined boolean
---@field private _readyPayloadLimit integer upper bound on ready-but-unclaimed payload bytes
---@field private _readyPayloadBytes integer currently held ready-but-unclaimed payload bytes
---@field private _readyWeights table<string, integer> one scheduling reservation per ready payload key
---@field private _readyTokens table<string, integer> outstanding ready tokens per payload key
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

local VALID_KINDS = { mesh = true, image = true, ["image-derivative"] = true, g4gx = true, g4tx = true }
local VALID_PRIORITIES = { demand = true, prefetch = true }

-- Estimated per-value metadata charge: small immutable Lua descriptors, not
-- allocator accounting. A native model bank additionally carries one descriptor
-- per draw.
local METADATA_VALUE_BYTES = 128
local METADATA_DRAW_BYTES = 64

-- Default ceiling for completed-but-unclaimed payload bytes held on the
-- main thread. Prefetch dispatch pauses while the ceiling is reached so an
-- over-cap prediction cannot spike transient RAM; demand work still
-- dispatches so actual gameplay never starves behind prefetch. Several tokens
-- waiting on one decoded value count once.
local DEFAULT_READY_PAYLOAD_LIMIT = 8 * 1024 * 1024

-- Upper bound between worker-liveness probes while a synchronous wait blocks
-- on the reply channel.
local WAIT_HEALTH_PROBE_SECONDS = 0.05

-- A key component is length-prefixed, so opaque source/content identities may
-- embed any byte (the base store's content identity contains a NUL) without
-- making two different requests look equal.
---@param parts string[]
---@return string
local function lengthPrefixedKey(parts)
  local encoded = {}
  for index, part in ipairs(parts) do
    encoded[index] = #part .. ":" .. part
  end
  return table.concat(encoded, "|")
end

-- A selector component is a logical path or a selected texture/palette pair and
-- must be a plain string: embedded NUL bytes are a malformed selector, never an
-- identity.
---@param value unknown
---@param label string
---@return string
local function selectorString(value, label)
  assert(type(value) == "string" and value ~= "", label .. " must be a non-empty string")
  ---@cast value string
  assert(not value:find("\0", 1, true), label .. " must not embed a NUL byte")
  return value
end

-- Resolve one request into its generated file plus its canonical decode
-- selector. The selector names every output-affecting decode input, including an
-- explicit absent palette, and is independent of table iteration order.
---@param kind string
---@param logicalRef string|ModelAsset.TextureReference
---@return string file, string selector
local function canonicalRequest(kind, logicalRef)
  if type(logicalRef) == "string" then
    local path = selectorString(logicalRef, "preparation path")
    return path, path
  end
  assert(kind == "g4tx", "only a native texture request carries a decode selector")
  local file = selectorString(logicalRef.file, "native bank file")
  local textureName = selectorString(logicalRef.textureName, "native texture name")
  local paletteName = logicalRef.paletteName
  local paletteIdentity = "palette:absent"
  if paletteName ~= nil then
    paletteIdentity = "palette:" .. selectorString(paletteName, "native palette name")
  end
  return file, table.concat({ "bank", file, "texture:" .. textureName, paletteIdentity }, "\0")
end

-- The distinct buffers one decoded result owns. Mesh and image payloads own
-- their upload pixel/vertex buffers, a native bank owns each draw's pair, and a
-- shared draw buffer is counted once.
---@param kind string
---@param payload table<string, unknown>
---@return love.Data[]
local function ownedBuffers(kind, payload)
  local buffers = {}
  local seen = {}
  ---@param buffer love.Data?
  local function add(buffer)
    if buffer == nil or seen[buffer] then
      return
    end
    seen[buffer] = true
    buffers[#buffers + 1] = buffer
  end
  if kind == "g4gx" then
    for _, draw in
      ipairs(payload.draws --[[@as table[] ]])
    do
      add(draw.vertexData --[[@as love.Data]])
      add(draw.indexData --[[@as love.Data]])
    end
  else
    for _, field in ipairs({ "vertexData", "indexData", "paletteData", "imageData", "byteData" }) do
      add(payload[field] --[[@as love.Data?]])
    end
  end
  return buffers
end

-- The worker reply's decoded payload in its published shape. Each kind keeps the
-- fields its consumers already read; the requested kind, not the worker's
-- response alias, is what the value carries.
---@param kind string
---@param response table<string, unknown>
---@return table<string, unknown>
local function payloadFor(kind, response)
  if kind == "g4tx" or kind == "image-derivative" then
    assert(response.indexData ~= nil, "prepared image derivative carries no pixels")
    return {
      sourceHash = response.sourceHash,
      pixelHash = response.pixelHash,
      width = response.width,
      height = response.height,
      kind = response.representation,
      colors = response.colors,
      indexData = response.indexData,
      paletteData = response.paletteData,
    }
  end
  if kind == "g4gx" then
    assert(type(response.draws) == "table" and #response.draws > 0, "prepared native bank carries no draws")
    return { draws = response.draws }
  end
  if kind == "image" then
    assert(response.imageData ~= nil, "prepared image carries no image data")
    return { imageData = response.imageData }
  end
  assert(response.vertexData ~= nil and response.indexData ~= nil, "prepared mesh carries no upload buffers")
  return {
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
  }
end

-- Build the typed immutable value one completion publishes: the requested
-- kind, the decoded payload, its own native bytes, the estimated metadata
-- charge and one repeat-safe release that frees only those owned buffers.
---@param kind string
---@param response table<string, unknown>
---@return table<string, unknown>
local function typedValue(kind, response)
  local payload = payloadFor(kind, response)
  local buffers = ownedBuffers(kind, payload)
  local nativeBytes = 0
  for _, buffer in ipairs(buffers) do
    local size = buffer:getSize()
    assert(type(size) == "number" and size >= 0, "a prepared output must report its byte size")
    nativeBytes = nativeBytes + math.floor(size)
  end
  local metadataChargeBytes = METADATA_VALUE_BYTES
  if kind == "g4gx" then
    local draws = payload.draws --[[@as table[] ]]
    metadataChargeBytes = metadataChargeBytes + METADATA_DRAW_BYTES * #draws
  end
  local released = false
  local value ---@type table<string, unknown>
  value = {
    kind = kind,
    payload = payload,
    nativeBytes = nativeBytes,
    metadataChargeBytes = metadataChargeBytes,
  }
  function value:release()
    if released then
      return
    end
    released = true
    for _, buffer in ipairs(buffers) do
      buffer:release()
    end
    self.payload = nil
  end
  return value
end

-- cacheFs is the selected epoch's resident reader: each request resolves its
-- immutable payload reference on the main thread, and only that reference
-- crosses to the worker. Construction starts no worker.
---@param cacheFs table<string, unknown>
---@param options AssetPreparationQueueOptions
---@return AssetPreparationQueue
function AssetPreparationQueue.new(cacheFs, options)
  assert(cacheFs and cacheFs.resolveAsset, "AssetPreparationQueue requires a resident generated reader")
  assert(
    type(cacheFs.versionId) == "string" and cacheFs.versionId ~= "",
    "AssetPreparationQueue requires a versioned generated reader"
  )
  assert(type(options) == "table" and options.decoded ~= nil, "AssetPreparationQueue requires the shared decoded owner")
  local decoded = options.decoded
  assert(
    type(decoded.publish) == "function"
      and type(decoded.borrow) == "function"
      and type(decoded.returnLease) == "function"
      and type(decoded.trim) == "function",
    "AssetPreparationQueue requires a resident cache kernel as its decoded owner"
  )
  local readyLimit = options.readyPayloadByteLimit or DEFAULT_READY_PAYLOAD_LIMIT
  assert(
    type(readyLimit) == "number" and readyLimit >= 0,
    "AssetPreparationQueue ready payload bound must be a non-negative byte count"
  )
  return setmetatable({
    _cacheFs = cacheFs,
    _decoded = decoded,
    _threadHost = options.thread,
    _workerSource = options.workerSource,
    _request = nil,
    _reply = nil,
    _worker = nil,
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
    _readyWeights = {},
    _readyTokens = {},
  }, AssetPreparationQueue)
end

-- Create the worker's channels and thread on the first actual asynchronous
-- dispatch. Compact base acquisition and an unused queue therefore never start
-- a thread.
function AssetPreparationQueue:_ensureWorker()
  local requestChannel = self._request
  if requestChannel ~= nil then
    return requestChannel
  end
  local threadHost = self._threadHost
  if threadHost == nil then
    threadHost = love and love.thread
  end
  assert(threadHost and threadHost.newChannel and threadHost.newThread, "asset preparation requires love.thread")
  local createdChannel = threadHost.newChannel()
  local replyChannel = threadHost.newChannel()
  local workerSource = self._workerSource
  if workerSource == nil then
    workerSource = BOOTSTRAP
  end
  local worker = threadHost.newThread(workerSource)
  self._request = createdChannel
  self._reply = replyChannel
  self._worker = worker
  worker:start(createdChannel, replyChannel, package.path)
  return createdChannel
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
  self:_ensureWorker():push({
    op = "prepare",
    token = token,
    kind = record.kind,
    path = record.path,
    data = record.data,
    selector = record.selector,
  })
end

-- Retunes the transient ready-payload ceiling. Already-held payloads stay
-- transferable; the new bound only gates further prefetch dispatch.
---@param limit integer
function AssetPreparationQueue:setReadyPayloadByteLimit(limit)
  assert(type(limit) == "number" and limit >= 0, "ready payload bound must be a non-negative byte count")
  self._readyPayloadLimit = limit
end

-- One scheduling reservation per unique ready payload key, however many tokens
-- wait on it.
---@param record AssetPreparationQueueRecord
---@param weight integer
function AssetPreparationQueue:_reserveReady(record, weight)
  local key = record.key
  local outstanding = self._readyTokens[key]
  if outstanding == nil then
    self._readyTokens[key] = 1
    self._readyWeights[key] = weight
    self._readyPayloadBytes = self._readyPayloadBytes + weight
  else
    self._readyTokens[key] = outstanding + 1
  end
  record.readyReserved = true
end

-- Release one token's scheduling reservation exactly once.
---@param record AssetPreparationQueueRecord
function AssetPreparationQueue:_forgetReadyPayload(record)
  if not record.readyReserved then
    return
  end
  record.readyReserved = false
  local key = record.key
  local outstanding = self._readyTokens[key]
  if outstanding == nil then
    return
  end
  outstanding = outstanding - 1
  if outstanding <= 0 then
    self._readyTokens[key] = nil
    self._readyPayloadBytes = self._readyPayloadBytes - (self._readyWeights[key] or 0)
    self._readyWeights[key] = nil
    if self._readyPayloadBytes < 0 then
      self._readyPayloadBytes = 0
    end
  else
    self._readyTokens[key] = outstanding
  end
end

-- Return one token's decoded lease to the shared owner and trim its idle
-- entries. Reports whether a lease was actually returned.
---@param record AssetPreparationQueueRecord
---@return boolean
function AssetPreparationQueue:_returnLease(record)
  local lease = record.lease
  if lease == nil then
    return false
  end
  record.lease = nil
  self._decoded:returnLease(lease)
  return true
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

-- Detect an unexpected worker exit after draining replies. A queue that never
-- dispatched work owns no worker and stays healthy; a production LÖVE Thread
-- reporting a stopped worker terminalizes the queue.
function AssetPreparationQueue:_checkWorkerHealth()
  if self._released or self._workerFailure ~= nil then
    return
  end
  local worker = self._worker
  if worker == nil or type(worker.isRunning) ~= "function" then
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

-- Publish one validated completion into the shared decoded owner and give every
-- surviving requester its own lease over that single value. The publication,
-- the borrows and the trim happen here, in one non-yielding main-thread step, so
-- a published value is either shared by all surviving requesters or by none.
---@param record AssetPreparationQueueRecord
---@param response table<string, unknown>
function AssetPreparationQueue:_publishOk(record, response)
  local value = typedValue(record.kind, response)
  local weight = value.nativeBytes + value.metadataChargeBytes
  ---@cast weight integer
  self._decoded:publish(record.key, value, weight)
  local survivors = { record }
  for _, otherRecord in pairs(self._tokens) do
    if otherRecord.link == record.token then
      survivors[#survivors + 1] = otherRecord
    end
  end
  for _, survivor in ipairs(survivors) do
    survivor.lease = self._decoded:borrow(record.key)
    survivor.state = "ready"
    self:_reserveReady(survivor, weight)
  end
  self._decoded:trim()
end

-- Detach every follower linked to a settled primary: each follower observes the
-- same outcome through its own borrow, so take-once and cancellation semantics
-- stay per-token while the worker ran once.
---@param primary integer settled primary token
---@param record AssetPreparationQueueRecord settled primary record
---@param response table<string, unknown> worker reply behind the outcome
function AssetPreparationQueue:_detachFollowers(primary, record, response)
  local key = record.key
  if key ~= nil and self._inflight[key] == primary then
    self._inflight[key] = nil
  end
  for _, otherRecord in pairs(self._tokens) do
    if otherRecord.link == primary then
      otherRecord.link = nil
      if not response.ok then
        otherRecord.state = "failed"
        otherRecord.failure = response.error
        self:_forgetReadyPayload(otherRecord)
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
  local reply = self._reply
  if reply == nil then
    return
  end
  while true do
    local response = reply:pop()
    if response == nil then
      return
    end
    self:_absorb(response)
  end
end

---@param kind "mesh"|"image"|"image-derivative"|"g4gx"|"g4tx"
---@param logicalPath string|ModelAsset.TextureReference generated file path, or a native texture bank selector for g4tx
---@param priority "demand"|"prefetch"
---@return integer
function AssetPreparationQueue:request(kind, logicalPath, priority)
  assert(not self._released, "asset preparation queue is released")
  assert(VALID_KINDS[kind], "unknown preparation kind " .. tostring(kind))
  assert(VALID_PRIORITIES[priority], "unknown preparation priority " .. tostring(priority))
  assert(
    type(logicalPath) == "string" or (kind == "g4tx" and type(logicalPath) == "table"),
    "preparation path is required"
  )
  self:_drain()
  self:_checkWorkerHealth()
  if self._workerFailure ~= nil then
    error(self._workerFailure, 0)
  end
  local file, selector = canonicalRequest(kind, logicalPath)
  -- The immutable resident reference is resolved before keying: identity is
  -- the selected source's content identity, so a different epoch or a
  -- replaced payload can never be served from an older decode.
  local reference = assert(
    self._cacheFs:resolveAsset(file),
    "the generated artifact is absent from the installed view: " .. tostring(file)
  )
  local key = lengthPrefixedKey({ reference.sourceId, reference.contentId, kind, selector })
  self._nextToken = self._nextToken + 1
  local token = self._nextToken
  -- A decoded identity already resident in the shared owner answers
  -- immediately with its own lease: no worker job, no second charge.
  local resident = self._decoded:find(key)
  if resident ~= nil then
    local lease = self._decoded:borrow(key)
    self._tokens[token] = {
      token = token,
      kind = kind,
      path = file,
      selector = type(logicalPath) == "table" and logicalPath or nil,
      data = reference.data,
      key = key,
      priority = priority,
      state = "ready",
      lease = lease,
    }
    self:_reserveReady(self._tokens[token], resident.nativeBytes + resident.metadataChargeBytes --[[@as integer]])
    return token
  end
  local record = {
    token = token,
    kind = kind,
    path = file,
    selector = type(logicalPath) == "table" and logicalPath or nil,
    data = reference.data,
    key = key,
    priority = priority,
    state = "queued",
  }
  -- An identical queued-or-running job runs once: the duplicate links to
  -- it and observes the shared outcome through its own token, so
  -- per-frame re-requests never stack duplicate worker decodes.
  local primary = self._inflight[key]
  local primaryRecord = primary ~= nil and self._tokens[primary] or nil
  if primaryRecord ~= nil and (primaryRecord.state == "queued" or primaryRecord.state == "running") then
    record.state = "linked"
    record.link = primary
    self._tokens[token] = record
    if priority == "demand" then
      self:_ensureDemand(primary)
    end
    self:_dispatch()
    return token
  end
  self._tokens[token] = record
  self._inflight[key] = token
  if priority == "demand" then
    self._demand[#self._demand + 1] = token
  else
    self._prefetch[#self._prefetch + 1] = token
  end
  self:_dispatch()
  return token
end

-- Non-blocking state probe; never transfers the lease. Returns "pending",
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

-- Transfer a ready token's decoded lease exactly once. The taker owns that lease
-- until it returns it through the shared decoded owner and trims; the queue
-- keeps no interest afterwards. Unknown, pending, failed, or
-- already-transferred tokens fail loudly instead of reviving work.
---@param token integer
---@return ResidentAssetCacheLease
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
  return assert(record.lease, "ready preparation has no decoded lease")
end

-- Drop logical interest; a running job is not preempted and its late result
-- is discarded when it returns. The physical slot stays occupied until that
-- reply (or the worker's death) frees it, so cancellation never fabricates
-- worker idleness and priority is decided at the next physical dispatch. A
-- ready token returns its own lease first.
---@param token integer
function AssetPreparationQueue:cancel(token)
  local record = assert(self._tokens[token], "unknown preparation token")
  self:_forgetReadyPayload(record)
  if self:_returnLease(record) then
    self._decoded:trim()
  end
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
  local key = assert(record.key, "preparation record is missing its identity")
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

-- Block efficiently until one token's decoded lease is transferred, absorbing
-- any unrelated token results along the way. Only synchronous callers whose path
-- already requires the result may wait; staged work polls instead. Waiting
-- transfers exactly what take does, so a caller must never take afterwards.
---@param token integer
---@return ResidentAssetCacheLease
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
      return assert(record.lease, "ready preparation has no decoded lease")
    end
    if record.state == "failed" then
      error("asset preparation failed for " .. tostring(record.path) .. ": " .. tostring(record.failure), 0)
    end
    local response =
      assert(self._reply, "a pending preparation token needs its worker"):demand(WAIT_HEALTH_PROBE_SECONDS)
    if response ~= nil then
      self:_absorb(response)
      self:_dispatch()
    end
  end
end

-- Borrow one resident base source for a compact runtime reader: the returned
-- lease roots exactly the bytes the store owns and creates no kernel entry, so a
-- map, message bank or PCM sample costs no second native buffer and no charge
-- against the decoded CPU owner. Release is idempotent and never touches the
-- store's backing. Disk-backed sources extend this same boundary in the mod
-- source form.
---@param reference ResidentCache.BlobRef
---@return AssetPreparationQueueSourceLease
function AssetPreparationQueue:acquireSource(reference)
  assert(not self._released, "asset preparation queue is released")
  assert(
    type(reference) == "table" and reference.data ~= nil and type(reference.sourceId) == "string",
    "base source acquisition requires a resolved resident reference"
  )
  local lease = { value = reference.data }
  ---@cast lease AssetPreparationQueueSourceLease
  function lease:release()
    if self.value == nil then
      return
    end
    self.value = nil
  end
  return lease
end

-- Stop accepting work, return every still-held decoded lease, ask the worker to
-- stop after its current job, join it, and discard unclaimed replies.
-- Idempotent: the worker is created and joined at most once, and a queue that
-- never dispatched never creates one. The borrowed decoded owner is never
-- cleared here; its lifetime belongs to the selected runtime.
function AssetPreparationQueue:release()
  if self._released then
    return
  end
  self._released = true
  local returnedLease = false
  for _, record in pairs(self._tokens) do
    self:_forgetReadyPayload(record)
    if self:_returnLease(record) then
      returnedLease = true
    end
  end
  self._tokens = {}
  self._demand = {}
  self._prefetch = {}
  self._inflight = {}
  self._forwarded = {}
  self._workerBusyToken = nil
  self._readyPayloadBytes = 0
  self._readyWeights = {}
  self._readyTokens = {}
  if returnedLease then
    self._decoded:trim()
  end
  local requestChannel = self._request
  if requestChannel ~= nil then
    pcall(function()
      requestChannel:push({ op = "shutdown" })
    end)
  end
  if not self._joined then
    self._joined = true
    local worker = self._worker
    if worker ~= nil then
      worker:wait()
    end
  end
  local replyChannel = self._reply
  if replyChannel ~= nil then
    while replyChannel:pop() ~= nil do
    end
  end
end

return AssetPreparationQueue
