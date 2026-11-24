-- Private background entry for interactive ROM import. The render thread never
-- owns ROM file reads, archive traversal, cartridge hashing, compression, or
-- managed publication: this module runs the existing validation owner in a
-- dedicated love.thread worker and reports back over channels. Main-thread code
-- must treat this module as an opaque bootstrap: only RomImporter drives it.

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

-- In-memory backend for the direct importer's existing registration path. The
-- worker shares no persistent cache handle with the game thread; this record
-- is private validation staging and is never published as an external binding.
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
  local prepared
  local temporaryPath
  local ok, failure = pcall(function()
    local RomImporter = require("romdump.src.source.RomImporter")
    local RomSource = require("romdump.src.source.RomSource")
    local RomArchive = require("romdump.src.source.RomArchive")
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

    if
      request.kind ~= "path"
      and request.kind ~= "drop"
      and request.kind ~= "dropBytes"
      and request.kind ~= "temporary"
    then
      failRequest("ROM_IMPORT_REQUEST_INVALID", "background import request has no usable source", {})
      return
    end

    local versions = catalogFromEntries(request.catalog)
    if request.kind == "temporary" then
      temporaryPath = assert(request.path)
    end
    local staging = memoryBackend()
    local function cacheFactory(versionId)
      return CacheFs.forVersion(versionId, staging)
    end

    -- Cooperative cancellation polled at safe boundaries only. It discards
    -- a matching cancel packet without consuming a matching commit, which
    -- stays queued for the publication gate's blocking demand.
    local committed = false
    local function cancelRequested()
      local popped, packet = pcall(function()
        return inbox:pop()
      end)
      if not popped or packet == nil then
        return false
      end
      if type(packet) == "table" and packet.id == id and packet.op == "cancel" then
        return true
      end
      pcall(function()
        inbox:push(packet)
      end)
      return false
    end

    local importer = RomImporter.new({
      versions = versions,
      cacheFactory = cacheFactory,
      now = workerNow,
      expectedVersionId = request.expectedVersionId,
    })

    -- A cancel already queued before the expensive source open ends the
    -- worker before any file read, so a retired session never prolongs
    -- its physical read.
    if cancelRequested() then
      return
    end

    -- The game thread observes this before the source opens: while the
    -- worker is stalled inside its first read, the receipt card above must
    -- stay drawable.
    answer({ kind = "status", state = "reading", progress = 0, stage = "opening" })

    local started, startErr
    if request.kind == "path" then
      started, startErr = pcall(importer.startPath, importer, request.path)
    elseif request.kind == "drop" then
      started, startErr = pcall(importer.startDroppedFile, importer, request.file)
    elseif request.kind == "temporary" then
      local physicalPath = assert(love.filesystem.getSaveDirectory()) .. "/" .. assert(temporaryPath)
      started, startErr = pcall(importer.startPath, importer, physicalPath)
    else
      started, startErr = pcall(function()
        local requestedName = request.name
        local name = "dropped file"
        if type(requestedName) == "string" then
          name = tostring(requestedName)
        end
        local rawBytes = request.bytes
        assert(type(rawBytes) == "string", "memory drop requires its bytes")
        local bytes = tostring(rawBytes)
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
    -- A cancel that arrived during the blocking open stops the worker
    -- before further verification without publishing anything.
    if not committed and cancelRequested() then
      return
    end

    local lastState, lastProgress = nil, nil
    local function reportStatus(force)
      local snapshot = importer:status()
      if snapshot.state == RomImporter.STATES.COMPLETE then
        return
      end
      local progress = math.min(0.9, snapshot.progress or 0)
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
      if not committed and cancelRequested() then
        return
      end
      importer:update()
      reportStatus(false)
      workerSleep(0)
    end

    if importer.state == RomImporter.STATES.ERROR then
      local snapshot = importer:status()
      if snapshot.errorCode == "IMPORT_CANCELED" then
        return
      end
      failRequest(
        snapshot.errorCode or "ROM_IMPORT_FAILED",
        Errors.format(snapshot.error),
        Errors.is(snapshot.error) and snapshot.error.context or {}
      )
      return
    end

    local snapshot = importer:status()
    local view = importer:takeVerifiedSource()
    assert(view ~= nil, "a completed import hands its verified source once")
    local byteDataOk, byteData = pcall(view.byteData, view)
    pcall(view.release, view)
    assert(byteDataOk and type(byteData) == "userdata", "a completed import shares its verified buffer")
    local versionInfo = assert(versions.info(snapshot.versionId), "verified import has a catalog identity")

    answer({ kind = "status", state = "registering", progress = 0.9, stage = "publishing", stageLabel = "Saving ROM" })
    prepared, startErr = RomArchive.prepare(versionInfo, byteData, versions)
    if prepared == nil then
      local err = startErr
      local typedErr = Errors.is(err) and err or nil
      ---@cast typedErr Errors.Error?
      failRequest(
        typedErr and typedErr.code or "ROM_ARCHIVE_WRITE_FAILED",
        Errors.format(err),
        typedErr and typedErr.context or {}
      )
      return
    end
    if cancelRequested() then
      return
    end

    answer({ kind = "validated" })
    local reply = inbox:demand()
    if not (type(reply) == "table" and reply.id == id and reply.op == "commit") then
      Errors.raise("IMPORT_CANCELED", "the import was superseded before publication", { id = id })
    end
    committed = true

    local published, publishError = RomArchive.publish(prepared)
    if not published then
      local err = publishError
      local typedErr = Errors.is(err) and err or nil
      ---@cast typedErr Errors.Error?
      failRequest(
        typedErr and typedErr.code or "ROM_ARCHIVE_PUBLISH_FAILED",
        Errors.format(err),
        typedErr and typedErr.context or {}
      )
      return
    end
    answer({
      kind = "complete",
      versionId = snapshot.versionId,
      report = snapshot.report,
      sourceName = snapshot.sourceName,
      displayName = snapshot.displayName,
      byteData = byteData,
    })
  end)
  if prepared ~= nil then
    pcall(require("romdump.src.source.RomArchive").discard, prepared)
  end
  if temporaryPath ~= nil then
    pcall(love.filesystem.remove, temporaryPath)
  end
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
