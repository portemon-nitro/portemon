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
--
-- A disk-backed selected reference (one package member) adds the private
-- `source` prerequisite: its bytes are read exactly once on the same physical
-- worker, published into that same kernel, and only then may its graphical
-- decode dispatch with the borrowed Data. The source task and every compact
-- synchronous acquisition share one interest per source/content identity, so
-- cancellation of a dependent never duplicates or frees the physical read.

---@class AssetPreparationQueueOptions
---@field decoded ResidentAssetCache the selected epoch's decoded CPU owner
---@field thread table<string, unknown>? injectable love.thread-shaped namespace (defaults to the global one)
---@field workerSource unknown? worker entry point override, passed to the thread constructor
---@field readyPayloadByteLimit integer? ceiling for ready-but-unclaimed payload bytes
---@field workerSlots integer? executor slots the presentation policy allows now (default one)

---@class AssetPreparationQueueRecord
---@field token integer
---@field kind string
---@field path string generated file path
---@field selector ModelAsset.TextureReference? native bank texture/palette selector for g4tx
---@field data love.Data? generated payload handed to the worker, absent for a selected source read
---@field key string decoded-value identity in the shared CPU owner
---@field priority "demand"|"prefetch"
---@field state "queued"|"running"|"awaiting-source"|"linked"|"ready"|"failed"
---@field link integer? primary token this follower observes
---@field failure string?
---@field lease ResidentAssetCacheLease? this token's own borrow, until take/wait/cancel
---@field readyReserved boolean? true while its key holds one scheduling reservation
---@field stage ("source"|"decode")? whether this token still owes the source read or is the decode itself
---@field sourceKey string? selected source/content identity of a disk-backed request
---@field reference CacheFs.PackageRef? immutable selected member descriptor captured at request time
---@field inputLease ResidentAssetCacheLease? source bytes a queued decode continuation owns until dispatch
---@field physicalToken integer? the dispatched request that will carry this logical record's reply

---@class AssetPreparationQueueSourceLease
---@field value love.Data borrowed resident bytes
---@field release fun(self: AssetPreparationQueueSourceLease)

-- One selected source's pending physical read and the logical tokens waiting on
-- it. The owner token performed (or will perform) the read; every member needs
-- the one retained allocation but nothing else about the others.
---@class AssetPreparationQueueSourceInterest
---@field key string selected source/content identity
---@field reference CacheFs.PackageRef immutable selected member descriptor
---@field owner integer? token whose physical dispatch performs the read
---@field members table<integer, boolean> every logical token needing these bytes

-- One physical preparation worker: its own request channel plus the token it
-- is currently running. Every worker reports on the one shared reply channel,
-- so a late reply is matched to its physical token, never to a queue-global
-- busy marker.
---@class AssetPreparationQueueWorker
---@field thread table<string, unknown>
---@field request table<string, unknown>
---@field busyToken integer?

---@class AssetPreparationQueue
---@field private _cacheFs table<string, unknown>
---@field private _decoded ResidentAssetCache
---@field private _threadHost table<string, unknown>?
---@field private _workerSource unknown?
---@field private _reply table<string, unknown>?
---@field private _workers AssetPreparationQueueWorker[]
---@field private _workerSlots integer executor slots this queue may fill
---@field private _tokens table<integer, AssetPreparationQueueRecord>
---@field private _demand integer[]
---@field private _prefetch integer[]
---@field private _inflight table<string, integer> identical queued-or-running job key to owning primary token
---@field private _forwarded table<integer, integer> dispatched token to promoted owner after a running primary is cancelled
---@field private _workerFailure string?
---@field private _sourceInterests table<string, AssetPreparationQueueSourceInterest>
---@field private _decodeLeases table<integer, ResidentAssetCacheLease> source lease owned by one dispatched decode
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

local VALID_KINDS = { mesh = true, image = true, ["image-derivative"] = true, g4gx = true, g4tx = true, source = true }
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

-- One selected source is identified by its package source identity and the
-- resolved member identity, never by logical path alone: two packages (or two
-- epochs) may serve different bytes at the same path.
---@param reference CacheFs.PackageRef
---@return string
local function sourceIdentity(reference)
  return lengthPrefixedKey({ reference.sourceId, reference.contentId })
end

-- Every state in which a token still owes work: a queued decode waiting for the
-- worker, a dispatched job, or a source member that waits for another token's
-- read.
---@param record AssetPreparationQueueRecord?
---@return boolean
local function isUnsettled(record)
  if record == nil then
    return false
  end
  local state = record.state
  return state == "queued" or state == "running" or state == "awaiting-source"
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

-- Build the typed immutable value one selected-source completion publishes:
-- exactly the bytes the worker read, their real size, the same fixed metadata
-- charge as any other value, and one repeat-safe release. The shared kernel
-- therefore charges a package source once, however many consumers borrow it.
---@param data love.Data
---@param nativeBytes integer
---@return table<string, unknown>
local function typedSourceValue(data, nativeBytes)
  local released = false
  local value ---@type table<string, unknown>
  value = {
    kind = "source",
    payload = data,
    nativeBytes = nativeBytes,
    metadataChargeBytes = METADATA_VALUE_BYTES,
  }
  function value:release()
    if released then
      return
    end
    released = true
    local payload = self.payload --[[@as love.Data?]]
    self.payload = nil
    if payload ~= nil then
      payload:release()
    end
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
  local slots = options.workerSlots or 1
  assert(
    type(slots) == "number" and slots % 1 == 0 and slots >= 1,
    "AssetPreparationQueue worker slots must be a positive integer"
  )
  return setmetatable({
    _cacheFs = cacheFs,
    _decoded = decoded,
    _threadHost = options.thread,
    _workerSource = options.workerSource,
    _reply = nil,
    _workers = {},
    _workerSlots = slots,
    _tokens = {},
    _demand = {},
    _prefetch = {},
    _inflight = {},
    _forwarded = {},
    _workerFailure = nil,
    _sourceInterests = {},
    _decodeLeases = {},
    _nextToken = 0,
    _released = false,
    _joined = false,
    _readyPayloadLimit = readyLimit,
    _readyPayloadBytes = 0,
    _readyWeights = {},
    _readyTokens = {},
  }, AssetPreparationQueue)
end

-- Create one physical worker (its own request channel, the shared reply
-- channel) and start it. Construction of the queue starts nothing: the first
-- actual asynchronous dispatch creates the first worker, and further slots are
-- created only when the executor's slot budget is raised.
---@return AssetPreparationQueueWorker
function AssetPreparationQueue:_startWorker()
  local threadHost = self._threadHost
  if threadHost == nil then
    threadHost = love and love.thread
  end
  assert(threadHost and threadHost.newChannel and threadHost.newThread, "asset preparation requires love.thread")
  local workerSource = self._workerSource
  if workerSource == nil then
    workerSource = BOOTSTRAP
  end
  -- Request channel first: the reply channel is shared by every slot and is
  -- created once, on the first worker.
  local requestChannel = threadHost.newChannel()
  if self._reply == nil then
    self._reply = threadHost.newChannel()
  end
  local replyChannel = assert(self._reply, "asset preparation requires its shared reply channel")
  local thread = threadHost.newThread(workerSource)
  thread:start(requestChannel, replyChannel, package.path)
  local worker = { thread = thread, request = requestChannel, busyToken = nil }
  self._workers[#self._workers + 1] = worker
  return worker
end

-- Bound how many physical workers this executor may fill. A running job is
-- never preempted: lowering the bound only stops new dispatch onto the extra
-- slots, which stay idle (and joined) until the queue is released.
---@param slots integer
function AssetPreparationQueue:setWorkerSlots(slots)
  assert(
    type(slots) == "number" and slots % 1 == 0 and slots >= 1,
    "preparation worker slots must be a positive integer"
  )
  self._workerSlots = slots
  if not self._released then
    self:_dispatch()
  end
end

---@return integer physical workers this executor currently owns
function AssetPreparationQueue:workerSlotCount()
  return #self._workers
end

---@return integer slots this executor may fill
function AssetPreparationQueue:workerSlotBudget()
  return self._workerSlots
end

-- Physical jobs occupying a worker right now, whichever slot index runs
-- them. Cancelled-but-running tokens keep their occupancy until the late reply
-- frees it.
---@return integer
function AssetPreparationQueue:_activeWorkerCount()
  local active = 0
  for _, worker in ipairs(self._workers) do
    if worker.busyToken ~= nil then
      active = active + 1
    end
  end
  return active
end

-- Whether the executor may start one more job: total occupancy below the
-- budget plus an existing idle slot within it or room to grow. Occupancy is
-- counted across every physical worker, so lowering the budget while a
-- higher-index worker still runs never admits a second concurrent job. Asking
-- only when queued work exists keeps a raised budget from starting a thread
-- for nothing.
---@return boolean
function AssetPreparationQueue:_hasFreeSlot()
  if self:_activeWorkerCount() >= self._workerSlots then
    return false
  end
  for index, worker in ipairs(self._workers) do
    if index > self._workerSlots then
      break
    end
    if worker.busyToken == nil then
      return true
    end
  end
  return #self._workers < self._workerSlots
end

-- One free slot within the current budget: an existing idle worker, or a newly
-- started one while the budget still allows growth.
---@return AssetPreparationQueueWorker?
function AssetPreparationQueue:_freeSlot()
  for index, worker in ipairs(self._workers) do
    if index > self._workerSlots then
      break
    end
    if worker.busyToken == nil then
      return worker
    end
  end
  if #self._workers >= self._workerSlots then
    return nil
  end
  return self:_startWorker()
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

-- Dispatch work into every free physical slot, choosing queued demand work
-- before queued prefetch work. While ready-but-unclaimed payloads reach the
-- transient ceiling, prefetch dispatch pauses and demand still flows. A
-- running job is never preempted: a token cancelled after dispatch keeps
-- occupying its slot until its late reply (or the worker's death) frees it.
-- With one slot this is exactly the historical single-worker loop; the loader
-- policy raises the bound so independent scene sources overlap.
function AssetPreparationQueue:_dispatch()
  if self._released or self._workerFailure ~= nil then
    return
  end
  while self:_hasFreeSlot() do
    local token = self:_shiftLive(self._demand)
    if token == nil and self._readyPayloadBytes < self._readyPayloadLimit then
      token = self:_shiftLive(self._prefetch)
    end
    if token == nil then
      return
    end
    self:_start(assert(token))
  end
end

-- Hand one queued token to a free slot. The slot's busy token is the physical
-- identity its reply clears, whoever the logical owner becomes.
---@param token integer
function AssetPreparationQueue:_start(token)
  local record = assert(self._tokens[token], "dispatched an unknown preparation token")
  local slot = assert(self:_freeSlot(), "preparation dispatch found no free slot")
  record.state = "running"
  record.physicalToken = token
  slot.busyToken = token
  local job = { op = "prepare", token = token, path = record.path }
  if record.stage == "source" then
    local reference = assert(record.reference, "a source preparation job needs its selected reference")
    job.kind = "source"
    job.physicalPath = reference.physicalPath
    job.size = reference.size
    job.sourceId = reference.sourceId
    job.contentId = reference.contentId
  else
    job.kind = record.kind
    job.data = record.data
    job.selector = record.selector
    -- The dispatched decode owns its input source lease until its reply (or
    -- terminal worker failure): logical cancellation cannot return it early.
    if record.inputLease ~= nil then
      self._decodeLeases[token] = record.inputLease
      record.inputLease = nil
    end
  end
  slot.request:push(job)
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
-- running token fails with the terminal cause while already-ready payloads stay
-- transferable. Queued decode continuations give their input source leases back
-- immediately because no worker ever received them. A dispatched decode's input
-- lease instead stays with its physical job: any worker in this executor may
-- still be reading it, so ownership lasts until that job's late reply (which is
-- discarded without changing the failed token) or until the join in release().
-- The queue never restarts a worker.
---@param cause string?
function AssetPreparationQueue:_enterTerminalFailure(cause)
  if self._workerFailure ~= nil then
    return
  end
  if cause == nil then
    cause = "worker exited without an error"
  end
  self._workerFailure = "asset preparation worker stopped: " .. tostring(cause)

  local returnedLease = false
  for _, record in pairs(self._tokens) do
    if isUnsettled(record) or record.state == "linked" then
      record.state = "failed"
      record.failure = self._workerFailure
      record.link = nil
    end
    local lease = record.inputLease
    if lease ~= nil then
      record.inputLease = nil
      self._decoded:returnLease(lease)
      returnedLease = true
    end
  end
  if returnedLease then
    self._decoded:trim()
  end
  self._demand = {}
  self._prefetch = {}
  self._inflight = {}
  self._forwarded = {}
  self._sourceInterests = {}
  for _, worker in ipairs(self._workers) do
    worker.busyToken = nil
  end
end

-- Detect an unexpected worker exit after draining replies. A queue that never
-- dispatched work owns no worker and stays healthy. Any stopped worker
-- terminalizes the queue: the executor never restarts a worker and a partially
-- staffed one would silently honor the slot budget, so every unsettled token
-- fails with the terminal cause instead of waiting on a pool that lost capacity.
function AssetPreparationQueue:_checkWorkerHealth()
  if self._released or self._workerFailure ~= nil then
    return
  end
  for _, worker in ipairs(self._workers) do
    local thread = worker.thread
    if type(thread.isRunning) == "function" then
      local ok, running = pcall(function()
        return thread:isRunning()
      end)
      if not ok then
        self:_enterTerminalFailure(running)
        return
      end
      if not running then
        local cause = nil
        if type(thread.getError) == "function" then
          local _, workerError = pcall(function()
            return thread:getError()
          end)
          cause = workerError
        end
        self:_enterTerminalFailure(cause)
        return
      end
    end
  end
end

-- Insert a record into the pending list its priority names.
---@param record AssetPreparationQueueRecord
function AssetPreparationQueue:_enqueue(record)
  if record.priority == "demand" then
    self._demand[#self._demand + 1] = record.token
  else
    self._prefetch[#self._prefetch + 1] = record.token
  end
end

-- Remove one token from both pending lists; a stale reference can remain after
-- an earlier promotion, so both lists are swept.
---@param token integer
function AssetPreparationQueue:_removeQueued(token)
  for _, pending in ipairs({ self._demand, self._prefetch }) do
    for index, queued in ipairs(pending) do
      if queued == token then
        table.remove(pending, index)
        break
      end
    end
  end
end

-- Promote a graphical primary or a direct source token to demand work: a
-- source-stage request dispatches no job of its own, so the interest's owner
-- carries the priority.
---@param record AssetPreparationQueueRecord?
function AssetPreparationQueue:_promotePrimary(record)
  if record == nil then
    return
  end
  if record.stage == "source" and record.sourceKey ~= nil then
    local interest = self._sourceInterests[record.sourceKey]
    if interest ~= nil and interest.owner ~= nil then
      self:_ensureDemand(interest.owner)
    end
    return
  end
  self:_ensureDemand(record.token)
end

-- Drop one token's interest in a selected source. The physical read is never
-- preempted: a running read keeps its slot and reports to the successor, while
-- an undispatched read moves to the oldest remaining member. Returns the member
-- that inherited the physical reply, if any.
---@param record AssetPreparationQueueRecord
---@param preferredHeir integer? the cancelled primary's own decode successor, when it is a member
---@return integer?
function AssetPreparationQueue:_releaseSourceInterest(record, preferredHeir)
  local key = record.sourceKey
  if key == nil then
    return nil
  end
  local interest = self._sourceInterests[key]
  if interest == nil then
    return nil
  end
  interest.members[record.token] = nil
  if interest.owner ~= record.token then
    if next(interest.members) == nil then
      self._sourceInterests[key] = nil
    end
    return nil
  end
  local heir = nil
  if preferredHeir ~= nil and interest.members[preferredHeir] then
    heir = preferredHeir
  end
  if heir == nil then
    for memberToken in pairs(interest.members) do
      if heir == nil or memberToken < heir then
        heir = memberToken
      end
    end
  end
  if heir == nil then
    self._sourceInterests[key] = nil
    local physical = record.physicalToken
    if record.state == "running" and physical ~= nil and self._forwarded[physical] == record.token then
      self._forwarded[physical] = nil
    end
    return nil
  end
  interest.owner = heir
  local heirRecord = assert(self._tokens[heir], "promoted source member is missing")
  heirRecord.stage = "source"
  if record.state == "running" then
    local physical = record.physicalToken or record.token
    heirRecord.state = "running"
    heirRecord.physicalToken = physical
    self._forwarded[physical] = heir
  else
    heirRecord.state = "queued"
    self:_enqueue(heirRecord)
  end
  return heir
end

-- Publish one selected-source completion into the shared kernel and let every
-- surviving member continue: a direct source token becomes ready with its own
-- lease, and a graphical member becomes the decode primary (or links to the one
-- that is). Exactly one Data allocation is retained, and every decode member
-- borrows an input lease from it before its decode dispatches.
---@param record AssetPreparationQueueRecord
---@param response table<string, unknown>
function AssetPreparationQueue:_absorbSource(record, response)
  local sourceKey = assert(record.sourceKey, "a source preparation job is missing its identity")
  local interest = self._sourceInterests[sourceKey]
  if interest == nil then
    if response.ok and response.payload ~= nil then
      pcall(function()
        response.payload:release()
      end)
    end
    return
  end
  self._sourceInterests[sourceKey] = nil
  local members = {}
  for memberToken in pairs(interest.members) do
    members[#members + 1] = memberToken
  end
  table.sort(members)
  interest.members = {}
  if not response.ok then
    local failure = response.error
    for _, memberToken in ipairs(members) do
      local member = self._tokens[memberToken]
      if member ~= nil then
        member.state = "failed"
        member.failure = failure
        self:_forgetReadyPayload(member)
        if member.kind ~= "source" and self._inflight[member.key] == memberToken then
          self._inflight[member.key] = nil
        end
        for _, otherRecord in pairs(self._tokens) do
          if otherRecord.link == memberToken then
            otherRecord.link = nil
            otherRecord.state = "failed"
            otherRecord.failure = failure
          end
        end
      end
    end
    return
  end
  local data = assert(response.payload, "a prepared source reply carries its bytes") --[[@as love.Data]]
  local nativeBytes = data:getSize()
  assert(type(nativeBytes) == "number" and nativeBytes >= 0, "prepared source bytes must report their size")
  ---@cast nativeBytes integer
  local resident = self._decoded:find(sourceKey)
  local weight ---@type integer
  if resident ~= nil then
    weight = resident.nativeBytes + resident.metadataChargeBytes --[[@as integer]]
    pcall(function()
      data:release()
    end)
  else
    local value = typedSourceValue(data, nativeBytes)
    weight = value.nativeBytes + value.metadataChargeBytes --[[@as integer]]
    self._decoded:publish(sourceKey, value, weight)
  end
  for _, memberToken in ipairs(members) do
    local member = self._tokens[memberToken]
    if member ~= nil then
      member.stage = "decode"
      if member.kind == "source" then
        member.lease = self._decoded:borrow(sourceKey)
        member.state = "ready"
        self:_reserveReady(member, weight)
      else
        local primary = self._inflight[member.key]
        local primaryRecord = primary ~= nil and self._tokens[primary] or nil
        if primary ~= nil and primary ~= memberToken and isUnsettled(primaryRecord) then
          member.state = "linked"
          member.link = primary
        else
          self._inflight[member.key] = memberToken
          member.state = "queued"
          local lease = self._decoded:borrow(sourceKey)
          member.inputLease = lease
          member.data = lease.value.payload --[[@as love.Data]]
          self:_enqueue(member)
        end
      end
    end
  end
end

-- Absorb one worker reply: free the matching physical slot first (even when the
-- logical token was cancelled and no longer exists), return the physical
-- decode's input source lease, then publish or discard the logical result.
-- Replacement dispatch is left to the public operation that observes the freed
-- slot. Already resolved tokens are never overwritten by late replies. A reply
-- for a cancelled primary fans out to the promoted follower through the
-- forwarding table instead, and a source reply feeds every surviving member of
-- its interest.
---@param response unknown
function AssetPreparationQueue:_absorb(response)
  if type(response) ~= "table" then
    return
  end
  for _, worker in ipairs(self._workers) do
    if worker.busyToken == response.token then
      worker.busyToken = nil
      break
    end
  end
  local token = self._forwarded[response.token]
  if token ~= nil then
    self._forwarded[response.token] = nil
  else
    token = response.token
  end
  local physicalLease = self._decodeLeases[response.token]
  if physicalLease ~= nil then
    self._decodeLeases[response.token] = nil
    self._decoded:returnLease(physicalLease)
    self._decoded:trim()
  end
  local record = self._tokens[token]
  if record == nil then
    if response.kind == "source" and response.ok and response.payload ~= nil then
      local payload = response.payload --[[@as love.Data]]
      pcall(function()
        payload:release()
      end)
    end
    return
  end
  if record.stage == "source" then
    self:_absorbSource(record, response)
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

---@param kind "mesh"|"image"|"image-derivative"|"g4gx"|"g4tx"|"source"
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
  -- The immutable selected reference is resolved before keying: identity is
  -- the selected source's content identity, so a different epoch or a
  -- replaced payload can never be served from an older decode.
  local reference = assert(
    self._cacheFs:resolveAsset(file),
    "the generated artifact is absent from the installed view: " .. tostring(file)
  )
  if kind == "source" then
    assert(
      reference.data == nil and type(reference.physicalPath) == "string",
      "the source request kind reads a disk-backed selected member: " .. tostring(file)
    )
    return self:_requestSource(reference --[[@as CacheFs.PackageRef]], file, priority)
  end
  if reference.data == nil then
    return self:_requestSelectedDecode(
      kind --[[@as "mesh"|"image"|"image-derivative"|"g4gx"|"g4tx"]],
      file,
      selector,
      logicalPath,
      reference --[[@as CacheFs.PackageRef]],
      priority
    )
  end
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
      stage = "decode",
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
    stage = "decode",
  }
  -- An identical queued-or-running job runs once: the duplicate links to
  -- it and observes the shared outcome through its own token, so
  -- per-frame re-requests never stack duplicate worker decodes.
  local primary = self._inflight[key]
  local primaryRecord = primary ~= nil and self._tokens[primary] or nil
  if isUnsettled(primaryRecord) then
    record.state = "linked"
    record.link = primary
    self._tokens[token] = record
    if priority == "demand" then
      self:_promotePrimary(primaryRecord)
    end
    self:_dispatch()
    return token
  end
  self._tokens[token] = record
  self._inflight[key] = token
  self:_enqueue(record)
  self:_dispatch()
  return token
end

-- One direct selected-source request: an already retained allocation answers
-- with its own lease, and otherwise the token joins the one interest for that
-- source and reads it through the shared physical worker.
---@param reference CacheFs.PackageRef
---@param path string logical selected path
---@param priority "demand"|"prefetch"
---@return integer
function AssetPreparationQueue:_requestSource(reference, path, priority)
  local key = sourceIdentity(reference)
  self._nextToken = self._nextToken + 1
  local token = self._nextToken
  local resident = self._decoded:find(key)
  if resident ~= nil then
    local record = {
      token = token,
      kind = "source",
      path = path,
      key = key,
      priority = priority,
      state = "ready",
      stage = "decode",
      lease = self._decoded:borrow(key),
    }
    self._tokens[token] = record
    self:_reserveReady(record, resident.nativeBytes + resident.metadataChargeBytes --[[@as integer]])
    return token
  end
  local interest = self._sourceInterests[key]
  if interest == nil then
    interest = { key = key, reference = reference, owner = token, members = { [token] = true } }
    self._sourceInterests[key] = interest
    local record = {
      token = token,
      kind = "source",
      path = path,
      key = key,
      sourceKey = key,
      reference = reference,
      priority = priority,
      state = "queued",
      stage = "source",
    }
    self._tokens[token] = record
    self:_enqueue(record)
  else
    interest.members[token] = true
    self._tokens[token] = {
      token = token,
      kind = "source",
      path = path,
      key = key,
      sourceKey = key,
      reference = reference,
      priority = priority,
      state = "awaiting-source",
      stage = "source",
    }
    if priority == "demand" then
      self:_promotePrimary(self._tokens[token])
    end
  end
  self:_dispatch()
  return token
end

-- One graphical request over a disk-backed selected member. The source read is
-- a prerequisite of the decode: this token either owns it, joins its interest
-- as the decode primary or as a follower of a pending primary, or decodes
-- immediately from an allocation the shared owner already retains.
---@param kind "mesh"|"image"|"image-derivative"|"g4gx"|"g4tx"
---@param file string logical selected path
---@param selector string canonical decode selector
---@param logicalPath string|ModelAsset.TextureReference original request selector
---@param reference CacheFs.PackageRef
---@param priority "demand"|"prefetch"
---@return integer
function AssetPreparationQueue:_requestSelectedDecode(kind, file, selector, logicalPath, reference, priority)
  local key = lengthPrefixedKey({ reference.sourceId, reference.contentId, kind, selector })
  self._nextToken = self._nextToken + 1
  local token = self._nextToken
  local resident = self._decoded:find(key)
  if resident ~= nil then
    local record = {
      token = token,
      kind = kind,
      path = file,
      selector = type(logicalPath) == "table" and logicalPath or nil,
      key = key,
      priority = priority,
      state = "ready",
      stage = "decode",
      lease = self._decoded:borrow(key),
    }
    self._tokens[token] = record
    self:_reserveReady(record, resident.nativeBytes + resident.metadataChargeBytes --[[@as integer]])
    return token
  end
  local sourceKey = sourceIdentity(reference)
  local record = {
    token = token,
    kind = kind,
    path = file,
    selector = type(logicalPath) == "table" and logicalPath or nil,
    key = key,
    sourceKey = sourceKey,
    reference = reference,
    priority = priority,
    stage = "source",
  }
  local primary = self._inflight[key]
  local primaryRecord = primary ~= nil and self._tokens[primary] or nil
  if primaryRecord ~= nil and isUnsettled(primaryRecord) then
    record.state = "linked"
    record.link = primary
    if primaryRecord.stage == "source" then
      local interest = self._sourceInterests[primaryRecord.sourceKey]
      if interest ~= nil and interest.members[primary] then
        interest.members[token] = true
      else
        record.stage = "decode"
      end
    else
      record.stage = "decode"
    end
    self._tokens[token] = record
    if priority == "demand" then
      self:_promotePrimary(primaryRecord)
    end
    self:_dispatch()
    return token
  end
  self._inflight[key] = token
  local residentSource = self._decoded:find(sourceKey)
  if residentSource ~= nil then
    local lease = self._decoded:borrow(sourceKey)
    record.stage = "decode"
    record.state = "queued"
    record.inputLease = lease
    record.data = lease.value.payload --[[@as love.Data]]
    self._tokens[token] = record
    self:_enqueue(record)
    self:_dispatch()
    return token
  end
  local interest = self._sourceInterests[sourceKey]
  if interest == nil then
    interest = { key = sourceKey, reference = reference, owner = token, members = { [token] = true } }
    self._sourceInterests[sourceKey] = interest
    record.state = "queued"
    self._tokens[token] = record
    self:_enqueue(record)
  else
    interest.members[token] = true
    record.state = "awaiting-source"
    self._tokens[token] = record
    if priority == "demand" then
      self:_promotePrimary(record)
    end
  end
  self:_dispatch()
  return token
end

-- Non-blocking state probe; never transfers the lease. A cooperative consumer
-- that is actually blocked on this token promotes it first (see promote), so a
-- probe alone never changes scheduling: speculative observers keep their
-- prefetch priority. Returns "pending", "ready", or "failed" plus the worker's
-- failure cause for failed work.
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
-- ready token returns its own lease first; a still-queued decode continuation
-- gives its source lease back immediately unless a follower inherits it. Once a
-- decode has dispatched, its input source lease belongs to the physical task
-- and is returned only when that task settles.
---@param token integer
function AssetPreparationQueue:cancel(token)
  local record = assert(self._tokens[token], "unknown preparation token")
  self:_forgetReadyPayload(record)
  if self:_returnLease(record) then
    self._decoded:trim()
  end
  self:_removeQueued(token)
  self._tokens[token] = nil

  local decodePrimary = record.kind ~= "source" and record.key ~= nil and self._inflight[record.key] == token
  local heir = nil
  if decodePrimary then
    -- A cancelled primary hands its decode to its oldest follower instead of
    -- abandoning the shared work: the worker runs once either way.
    for other, otherRecord in pairs(self._tokens) do
      if otherRecord.link == token and (heir == nil or other < heir) then
        heir = other
      end
    end
    self._inflight[record.key] = heir
    if heir ~= nil then
      local heirRecord = assert(self._tokens[heir], "promoted follower is missing")
      heirRecord.link = nil
      for _, otherRecord in pairs(self._tokens) do
        if otherRecord.link == token then
          otherRecord.link = heir
        end
      end
    end
  end

  if record.stage == "source" then
    -- The source read is still pending: its interest succession decides which
    -- member accepts the reply, independently of the decode promotion above.
    self:_releaseSourceInterest(record, heir)
    return
  end

  local lease = record.inputLease
  if lease ~= nil then
    record.inputLease = nil
    if heir ~= nil and self._tokens[heir] ~= nil then
      self._tokens[heir].inputLease = lease
    else
      self._decoded:returnLease(lease)
      self._decoded:trim()
    end
  end

  if heir == nil then
    local physical = record.physicalToken
    if record.state == "running" and physical ~= nil and self._forwarded[physical] == token then
      self._forwarded[physical] = nil
    end
    return
  end
  local heirRecord = assert(self._tokens[heir], "promoted follower is missing")
  if record.state == "running" then
    local physical = record.physicalToken or token
    heirRecord.state = "running"
    heirRecord.physicalToken = physical
    self._forwarded[physical] = heir
  else
    heirRecord.state = "queued"
    self:_enqueue(heirRecord)
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
  local linked = record.link
  if linked ~= nil then
    self:_promotePrimary(self._tokens[linked])
    return
  end
  if record.stage == "source" then
    -- The source read dispatches no job of its own: its interest's owner
    -- carries the priority for every member.
    local interest = record.sourceKey ~= nil and self._sourceInterests[record.sourceKey] or nil
    if interest ~= nil then
      if interest.owner ~= nil then
        self:_ensureDemand(interest.owner)
      end
      return
    end
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
-- The awaited token is promoted to demand before the first dispatch: a blocking
-- caller is the strongest current need, so a speculative reservation can never
-- hold the resource it waits on queued behind the ready-payload ceiling.
---@param token integer
---@return ResidentAssetCacheLease
function AssetPreparationQueue:wait(token)
  assert(self._tokens[token], "unknown preparation token")
  self:promote(token, "demand")
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

-- Borrow one selected source for a compact runtime reader. Base resident
-- bytes are returned as the direct, thread-free lease the store already owns:
-- no kernel entry, no second native buffer and no charge. A disk-backed
-- selected member instead joins (or promotes) the one source interest for that
-- source/content identity, waits through the queue's bounded health-probe loop,
-- and wraps the transferred kernel lease: the shared owner charges the
-- allocation once and trims it exactly once on the final release. The caller's
-- public value is Data, never the decoded wrapper.
---@param reference ResidentCache.BlobRef|CacheFs.PackageRef
---@return AssetPreparationQueueSourceLease
function AssetPreparationQueue:acquireSource(reference)
  assert(not self._released, "asset preparation queue is released")
  assert(
    type(reference) == "table" and type(reference.sourceId) == "string",
    "source acquisition requires a resolved reference"
  )
  if reference.data ~= nil then
    local baseLease = { value = reference.data }
    ---@cast baseLease AssetPreparationQueueSourceLease
    function baseLease:release()
      if self.value == nil then
        return
      end
      self.value = nil
    end
    return baseLease
  end
  assert(
    type(reference.contentId) == "string"
      and type(reference.physicalPath) == "string"
      and type(reference.path) == "string"
      and type(reference.size) == "number",
    "disk source acquisition requires a resolved selected reference: " .. tostring(reference.path)
  )
  self:_drain()
  self:_checkWorkerHealth()
  if self._workerFailure ~= nil then
    error(self._workerFailure, 0)
  end
  local selected = reference --[[@as CacheFs.PackageRef]]
  local key = sourceIdentity(selected)
  local kernelLease ---@type ResidentAssetCacheLease?
  local resident = self._decoded:find(key)
  if resident ~= nil then
    kernelLease = self._decoded:borrow(key)
  else
    local token = self:_requestSource(selected, selected.path, "demand")
    self:promote(token, "demand")
    local ok, transferred = pcall(self.wait, self, token)
    if not ok then
      if self._tokens[token] ~= nil then
        self:cancel(token)
      end
      error(transferred, 0)
    end
    kernelLease = transferred
  end
  local decoded = self._decoded
  local transferredLease = assert(kernelLease, "source acquisition transfers its lease")
  local sourceLease = {
    value = assert(transferredLease.value).payload --[[@as love.Data]],
  }
  ---@cast sourceLease AssetPreparationQueueSourceLease
  function sourceLease:release()
    if self.value == nil then
      return
    end
    self.value = nil
    decoded:returnLease(kernelLease)
    decoded:trim()
  end
  return sourceLease
end

-- Stop accepting work, return leases for jobs the worker never received, ask
-- it to stop and join it, then return leases pinned by physical jobs and
-- discard unclaimed replies.
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
    local lease = record.inputLease
    if lease ~= nil then
      record.inputLease = nil
      self._decoded:returnLease(lease)
      returnedLease = true
    end
  end
  self._tokens = {}
  self._demand = {}
  self._prefetch = {}
  self._inflight = {}
  self._forwarded = {}
  self._sourceInterests = {}
  for _, worker in ipairs(self._workers) do
    worker.busyToken = nil
  end
  self._readyPayloadBytes = 0
  self._readyWeights = {}
  self._readyTokens = {}
  for _, worker in ipairs(self._workers) do
    pcall(function()
      worker.request:push({ op = "shutdown" })
    end)
  end
  if not self._joined then
    self._joined = true
    for _, worker in ipairs(self._workers) do
      worker.thread:wait()
    end
  end
  local replyChannel = self._reply
  if replyChannel ~= nil then
    while true do
      local response = replyChannel:pop()
      if response == nil then
        break
      end
      if type(response) == "table" and response.kind == "source" and response.ok and response.payload ~= nil then
        local payload = response.payload --[[@as love.Data]]
        pcall(function()
          payload:release()
        end)
      end
    end
  end
  for token, lease in pairs(self._decodeLeases) do
    self._decodeLeases[token] = nil
    self._decoded:returnLease(lease)
    returnedLease = true
  end
  if returnedLease then
    self._decoded:trim()
  end
end

return AssetPreparationQueue
