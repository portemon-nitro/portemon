-- Private background entry for interactive ROM import. The render thread never
-- owns ROM file reads, archive traversal, cartridge hashing, or source
-- registration: this module runs the authoritative RomImporter sequence in a
-- dedicated love.thread worker and reports back over channels. It implements
-- no validation of its own; every check below reuses the existing importer,
-- source, cartridge, and binding owners. Main-thread code must treat this
-- module as an opaque bootstrap: only RomImporter drives it.

local RomImportWorker = {}

-- Single-shot code bootstrap for love.thread.newThread on the game thread.
-- The development search path is installed explicitly because worker states
-- do not inherit it. The worker receives its request over an inbox channel
-- and answers over a reply channel; both are handed to the thread entry as
-- start arguments alongside the search path.
local function bootstrapSource()
  return [[
local developmentPath, inbox, outbox = ...
if type(developmentPath) == "string" and developmentPath ~= "" then
  package.path = developmentPath
end
pcall(require, "love.thread")
pcall(require, "love.filesystem")
pcall(require, "love.data")
pcall(require, "love.timer")
local Worker = require("romdump.src.source.RomImportWorker")
Worker.run(inbox, outbox)
]]
end

---@return string code bootstrap for the background import thread entry
function RomImportWorker.bootstrap()
  return bootstrapSource()
end

-- In-memory backend staging the worker's decided binding. The worker state
-- shares no filesystem cache handle with the game thread, so registration
-- runs against this ephemeral staging; the decided binding record travels
-- back over the channel and the game thread publishes those exact bytes
-- through its configured cache. Only the backend methods the version cache
-- exercises are implemented.
---@return table<string, table<string, unknown>> memory backend with files/dirs maps
local function memoryBackend()
  local files = {}
  local dirs = {}
  local backend = {}
  function backend:write(path, data)
    files[path] = data
    return true
  end
  function backend:read(path)
    return files[path]
  end
  function backend:getInfo(path)
    if files[path] ~= nil then
      local value = files[path]
      local size = 0
      if type(value) == "string" then
        size = #value
      elseif type(value.getSize) == "function" then
        size = value:getSize()
      end
      return { type = "file", size = size }
    end
    if dirs[path] then
      return { type = "directory" }
    end
    local prefix = path .. "/"
    for key in pairs(files) do
      if key:sub(1, #prefix) == prefix then
        return { type = "directory" }
      end
    end
    for key in pairs(dirs) do
      if key:sub(1, #prefix) == prefix then
        return { type = "directory" }
      end
    end
    return nil
  end
  function backend:createDirectory(path)
    dirs[path] = true
    return true
  end
  function backend:remove(path)
    files[path] = nil
    dirs[path] = nil
    return true
  end
  function backend:replace(sourcePath, destinationPath)
    if files[sourcePath] ~= nil then
      files[destinationPath] = files[sourcePath]
      files[sourcePath] = nil
      return true
    end
    if dirs[sourcePath] then
      dirs[destinationPath] = true
      dirs[sourcePath] = nil
      local prefix = sourcePath .. "/"
      for key, value in pairs(files) do
        if key:sub(1, #prefix) == prefix then
          files[destinationPath .. key:sub(#prefix + 1)] = value
          files[key] = nil
        end
      end
      return true
    end
    return nil, "missing staged source: " .. tostring(sourcePath)
  end
  return backend
end

-- Rebuild the version catalog the cartridge was verified against from plain
-- record entries. Only channel-safe record data crosses into the worker, so
-- the game thread snapshots its catalog before starting the thread and the
-- worker restores the lookup functions the cartridge parser needs.
---@param entries table<integer, table<string, unknown>> plain version records
---@return table<string, function> catalog answering info/forSha1/forGameCode
local function catalogFromEntries(entries)
  local records = {}
  if type(entries) == "table" then
    for _, entry in ipairs(entries) do
      if type(entry) == "table" and type(entry.id) == "string" then
        records[#records + 1] = entry
      end
    end
  end
  local function info(id)
    for _, entry in ipairs(records) do
      if entry.id == id then
        return entry
      end
    end
    return nil
  end
  local function forSha1(hexSha1)
    local wanted = string.lower(tostring(hexSha1))
    for _, entry in ipairs(records) do
      if type(entry.sha1) == "string" and entry.sha1:lower() == wanted then
        return entry
      end
    end
    return nil
  end
  local function forGameCode(gameCode)
    for _, entry in ipairs(records) do
      if entry.gameCode == gameCode then
        return entry
      end
    end
    return nil
  end
  return {
    info = info,
    forSha1 = forSha1,
    forGameCode = forGameCode,
  }
end

-- Copy only channel-safe scalars out of an error context so typed failures
-- survive the trip back without carrying live objects.
---@param context unknown
---@return table<string, unknown> plain context copy
local function plainContext(context)
  local function copy(value, depth)
    if depth <= 0 then
      return nil
    end
    local kind = type(value)
    if kind == "string" or kind == "number" or kind == "boolean" then
      return value
    end
    if kind ~= "table" then
      return nil
    end
    local out = {}
    for key, item in pairs(value) do
      if type(key) == "string" or type(key) == "number" then
        local part = copy(item, depth - 1)
        if part ~= nil then
          out[key] = part
        end
      end
    end
    return out
  end
  local copied = copy(context, 4)
  if type(copied) == "table" then
    return copied
  end
  return {}
end

-- Bounded worker clock: yields the validation coroutine roughly every 8ms of
-- work, matching the interactive importer's slicing without depending on a
-- host frame.
---@return number seconds
local function workerNow()
  if love ~= nil and love.timer ~= nil and type(love.timer.getTime) == "function" then
    return love.timer.getTime()
  end
  return os.clock()
end

-- Sleep without a host frame dependency. A zero sleep still yields the
-- worker thread to the scheduler between validation slices.
---@param seconds number
local function workerSleep(seconds)
  if love ~= nil and love.timer ~= nil and type(love.timer.sleep) == "function" then
    pcall(love.timer.sleep, seconds)
  end
end

-- Run one background import to a terminal state. Only RomImporter drives
-- this; the game thread never calls it directly.
---@param inbox table<string, function>|userdata request/control channel (game thread pushes)
---@param outbox table<string, function>|userdata status/result channel (game thread pops)
function RomImportWorker.run(inbox, outbox)
  -- Latched before any fallible work below: even an unexpected failure must
  -- still answer the live session, since an id-less packet would read as a
  -- stale late packet and die silent.
  local latchedId = {}
  local ok, failure = pcall(function()
    local RomImporter = require("romdump.src.source.RomImporter")
    local RomSource = require("romdump.src.source.RomSource")
    local RomBinding = require("romdump.src.source.RomBinding")
    local CacheFs = require("libs.storage.src.CacheFs")
    local Errors = require("libs.errors.src.Errors")

    assert(type(inbox) == "table" or type(inbox) == "userdata", "background import requires its request channel")
    assert(type(outbox) == "table" or type(outbox) == "userdata", "background import requires its reply channel")
    local request = inbox:demand()
    assert(type(request) == "table", "background import requires its request packet")
    local id = assert(request.id, "background import request requires its session id")
    latchedId.id = id

    local function answer(packet)
      packet.id = id
      outbox:push(packet)
    end

    local function failRequest(code, message, context)
      answer({ kind = "error", errorCode = code, message = message, context = plainContext(context) })
    end

    if request.kind ~= "path" and request.kind ~= "drop" and request.kind ~= "dropBytes" then
      failRequest("ROM_IMPORT_REQUEST_INVALID", "background import request has no usable source", {})
      return
    end

    local versions = catalogFromEntries(request.catalog)
    local staging = memoryBackend()
    local function cacheFactory(versionId)
      return CacheFs.forVersion(versionId, staging)
    end

    -- The registration gate: after canonical verification and the reopen
    -- proof, and directly before the binding write, the worker announces
    -- the validated version and waits for the game thread's explicit
    -- commit or cancel for this session. A cancel raises out of the
    -- validation coroutine so nothing is recorded; the game thread already
    -- retired the session and discards everything that follows.
    local function registerGate()
      answer({ kind = "validated" })
      local reply = inbox:demand()
      if type(reply) == "table" and reply.id == id and reply.op == "commit" then
        return
      end
      Errors.raise("IMPORT_CANCELED", "the import was superseded before registration", { id = id })
    end

    local importer = RomImporter.new({
      versions = versions,
      cacheFactory = cacheFactory,
      now = workerNow,
      expectedVersionId = request.expectedVersionId,
      registerGate = registerGate,
    })

    -- The game thread observes this before the source opens: while the
    -- worker is stalled inside its first read, the receipt card above must
    -- stay drawable.
    answer({ kind = "status", state = "reading", progress = 0, stage = "opening" })

    local started, startErr
    if request.kind == "path" then
      started, startErr = pcall(importer.startPath, importer, request.path)
    elseif request.kind == "drop" then
      started, startErr = pcall(importer.startDroppedFile, importer, request.file)
    else
      started, startErr = pcall(function()
        local name = type(request.name) == "string" and request.name or "dropped file"
        local bytes = assert(type(request.bytes) == "string" and request.bytes, "memory drop requires its bytes")
        local source
        if name:lower():match("%.zip$") then
          source = assert(RomSource.fromZipData(bytes, name, versions))
        else
          source = RomSource.fromString(bytes, name)
        end
        importer:startSource(source)
      end)
    end
    if not started then
      ---@type unknown
      local err = startErr
      if Errors.is(err) then
        failRequest(err.code, err.message, err.context)
      else
        failRequest("ROM_IMPORT_START_FAILED", tostring(err), {})
      end
      return
    end

    local lastState, lastProgress = nil, nil
    local function reportStatus(force)
      local snapshot = importer:status()
      local progress = snapshot.progress or 0
      if not force and snapshot.state == lastState and progress == lastProgress then
        return
      end
      lastState, lastProgress = snapshot.state, progress
      answer({
        kind = "status",
        state = snapshot.state,
        progress = progress,
        stage = snapshot.stage,
        stageLabel = snapshot.stageLabel,
        detail = snapshot.detail,
      })
    end

    reportStatus(true)
    while importer.state ~= RomImporter.STATES.COMPLETE and importer.state ~= RomImporter.STATES.ERROR do
      importer:update()
      reportStatus(false)
      workerSleep(0)
    end

    if importer.state == RomImporter.STATES.COMPLETE then
      local snapshot = importer:status()
      local view = importer:takeVerifiedSource()
      assert(view ~= nil, "a completed import hands its verified source once")
      local byteDataOk, byteData = pcall(view.byteData, view)
      pcall(view.release, view)
      assert(byteDataOk and type(byteData) == "userdata", "a completed import shares its verified buffer")
      local cache = cacheFactory(snapshot.versionId)
      local binding = assert(cache:loadLua(RomBinding.PATH))
      answer({
        kind = "complete",
        versionId = snapshot.versionId,
        report = snapshot.report,
        sourceName = snapshot.sourceName,
        displayName = snapshot.displayName,
        binding = binding,
        byteData = byteData,
      })
      return
    end

    local snapshot = importer:status()
    if snapshot.errorCode == "IMPORT_CANCELED" then
      return
    end
    local message = Errors.format(snapshot.error)
    failRequest(
      snapshot.errorCode or "ROM_IMPORT_FAILED",
      message,
      Errors.is(snapshot.error) and snapshot.error.context or {}
    )
  end)
  if not ok and latchedId.id ~= nil then
    pcall(function()
      if type(outbox) == "table" or type(outbox) == "userdata" then
        outbox:push({
          id = latchedId.id,
          kind = "error",
          errorCode = "ROM_IMPORT_WORKER_FAILED",
          message = tostring(failure),
          context = {},
        })
      end
    end)
  end
end

return RomImportWorker
