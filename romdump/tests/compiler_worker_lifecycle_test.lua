-- Worker source-close barrier: the close-context control owns the owned
-- source reader, and a reader that fails to close must never be
-- acknowledged as closed. The production run loop is driven with scripted
-- channels; the first job installs a throwing reader, then the barrier
-- control must surface the failure without a closure acknowledgement.

local Assert = require("tests.support.Assert")
local FakeCache = require("tests.support.FakeCache")

local T = {}

local function withLove(fakeLove, fn)
  local previous = rawget(_G, "love")
  rawset(_G, "love", fakeLove)
  local ok, result = pcall(fn)
  rawset(_G, "love", previous)
  if not ok then
    error(result, 0)
  end
  return result
end

local function fakeLove()
  local backend = FakeCache.new()
  return {
    filesystem = {
      write = function(path, data)
        return backend:write(path, data)
      end,
      read = function(path)
        return backend:read(path)
      end,
      getInfo = function(path)
        return backend:getInfo(path)
      end,
      createDirectory = function(path)
        return backend:createDirectory(path)
      end,
      remove = function(path)
        return backend:remove(path)
      end,
      getDirectoryItems = function(path)
        return backend:getDirectoryItems(path)
      end,
    },
    timer = {
      getTime = function()
        return 0
      end,
    },
  }
end

local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")

-- One borrowed pool buffer for scripted supplies: the worker borrows it by
-- reference after its typed request, exactly like a pool-owned buffer. The
-- ROM reader itself stays stubbed in these scenarios, so the bytes are
-- never parsed here.
local function supplyBytes()
  return hostLove.data.newByteData("scripted pooled source")
end

---@param job table<string, unknown> dispatched job the supply answers
local function pooledSupply(job)
  return {
    kind = "source-supplied",
    workerId = 1,
    jobKey = job.jobKey,
    versionId = job.versionId,
    generationId = job.generationId,
    epoch = job.epoch,
    romByteData = supplyBytes(),
  }
end

local function scriptedChannel(messages)
  local pending = {}
  for _, message in ipairs(messages) do
    pending[#pending + 1] = message
  end
  local channel = {}
  function channel:push(value)
    pending[#pending + 1] = value
    return true
  end
  function channel:pop()
    if #pending == 0 then
      return nil
    end
    return table.remove(pending, 1)
  end
  function channel:demand()
    local value = self:pop()
    assert(value ~= nil, "the worker demanded beyond its scripted controls")
    return value
  end
  function channel:getCount()
    return #pending
  end
  return channel
end

local function recordingChannel()
  local received = {}
  local channel = scriptedChannel({})
  local push = channel.push
  function channel:push(value)
    received[#received + 1] = value
    return push(self, value)
  end
  return channel, received
end

-- A current-generation receipt settles the job as reused without reading
-- the payload or opening ROM source: the receipt is the ordinary warm
-- reuse authority, so an absent payload never blocks reuse.
function T.current_receipt_reuses_without_payload_or_source()
  local CompilerWorker = require("romdump.src.build.CompilerWorker")
  local CacheFs = require("libs.storage.src.CacheFs")
  local ArtifactState = require("romdump.src.build.ArtifactState")
  local RomFs = require("romdump.src.source.RomFs")
  local generation = "receipt-trust-generation"
  local input = scriptedChannel({
    {
      kind = "field-font",
      key = "global",
      jobKey = "field-font:global",
      versionId = "heartgold",
      generationId = generation,
      epoch = 1,
      stageName = "font-stage",
      sizeClass = "normal",
      payload = {},
      producerFingerprint = "producer",
    },
    { kind = "stop" },
  })
  local resultsChannel, received = recordingChannel()
  local sourceOpened = false
  local realOpen = RomFs.open
  RomFs.open = function(_)
    sourceOpened = true
    error("receipt reuse must not open ROM source")
  end
  local runOk, runErr = withLove(fakeLove(), function()
    local cacheFs = CacheFs.forVersion("heartgold")
    cacheFs:writeLua(ArtifactState.path("field-font", "global"), {
      schema = ArtifactState.RECEIPT_SCHEMA,
      generationId = generation,
      kind = "field-font",
      key = "global",
      marker = "receipt-trust-marker",
    })
    -- No payload is published: reuse proves receipt identity only.
    return pcall(CompilerWorker.run, 1, input, resultsChannel)
  end)
  RomFs.open = realOpen
  Assert.isTrue(runOk, "the driven worker loop resolves: " .. tostring(runErr))
  Assert.equal(#received, 1, "the reused job reports once")
  Assert.equal(received[1].status, "reused", "a current receipt reuses without payload validation")
  Assert.isFalse(sourceOpened, "receipt reuse opens no ROM source")
end

-- A missing current receipt falls through to ordinary compilation: trust
-- never turns absence into readiness. The miss first asks the pool for its
-- shared source and only compiles once the matching supply arrives.
function T.missing_receipt_compiles_through_the_producer_path()
  local CompilerWorker = require("romdump.src.build.CompilerWorker")
  local RomFs = require("romdump.src.source.RomFs")
  local job = {
    kind = "field-font",
    key = "global",
    jobKey = "field-font:global",
    versionId = "heartgold",
    generationId = "compile-fallback-generation",
    epoch = 1,
    stageName = "font-stage",
    sizeClass = "normal",
    payload = {},
    producerFingerprint = "producer",
  }
  local input = scriptedChannel({ job, pooledSupply(job), { kind = "stop" } })
  local resultsChannel, received = recordingChannel()
  local sourceOpened = false
  local realOpen = RomFs.open
  RomFs.open = function(_)
    sourceOpened = true
    return { close = function(_) end }
  end
  local realExecute = CompilerWorker.execute
  CompilerWorker.execute = function(_, _)
    return { stageName = "font-stage", result = { marker = "fresh-marker" } }
  end
  local runOk, runErr = withLove(fakeLove(), function()
    return pcall(CompilerWorker.run, 1, input, resultsChannel)
  end)
  RomFs.open = realOpen
  CompilerWorker.execute = realExecute
  Assert.isTrue(runOk, "the driven worker loop resolves: " .. tostring(runErr))
  Assert.equal(#received, 2, "the miss asks first, then the compiled job reports")
  Assert.equal(received[1].status, "source-needed", "the miss emits its typed pool request")
  Assert.equal(received[1].jobKey, "field-font:global", "the request names its job")
  Assert.equal(received[2].status, "prepared", "a missing receipt compiles after its supply")
  Assert.isTrue(sourceOpened, "compilation opens the supplied source lazily")
end

-- A receipt file that cannot be parsed or evaluated as Lua proves nothing,
-- so the job falls through to ordinary compilation exactly like a missing
-- receipt: damaged trust metadata never becomes readiness and never fails
-- the job by itself.
function T.damaged_receipt_lua_compiles_through_the_producer_path()
  local CompilerWorker = require("romdump.src.build.CompilerWorker")
  local CacheFs = require("libs.storage.src.CacheFs")
  local ArtifactState = require("romdump.src.build.ArtifactState")
  local RomFs = require("romdump.src.source.RomFs")
  local damages = {
    { label = "parse damage", rawLua = "return { this is not valid receipt lua !!!" },
    { label = "evaluation damage", rawLua = "return undefined_global()" },
  }
  for _, damage in ipairs(damages) do
    local job = {
      kind = "field-font",
      key = "global",
      jobKey = "field-font:global",
      versionId = "heartgold",
      generationId = "damaged-receipt-generation",
      epoch = 1,
      stageName = "font-stage",
      sizeClass = "normal",
      payload = {},
      producerFingerprint = "producer",
    }
    local input = scriptedChannel({ job, pooledSupply(job), { kind = "stop" } })
    local resultsChannel, received = recordingChannel()
    local sourceOpened = false
    local realOpen = RomFs.open
    RomFs.open = function(_)
      sourceOpened = true
      return { close = function(_) end }
    end
    local realExecute = CompilerWorker.execute
    CompilerWorker.execute = function(_, _)
      return { stageName = "font-stage", result = { marker = "fresh-marker" } }
    end
    local runOk, runErr = withLove(fakeLove(), function()
      local cacheFs = CacheFs.forVersion("heartgold")
      assert(cacheFs:write(ArtifactState.path("field-font", "global"), damage.rawLua))
      return pcall(CompilerWorker.run, 1, input, resultsChannel)
    end)
    RomFs.open = realOpen
    CompilerWorker.execute = realExecute
    Assert.isTrue(runOk, "the driven worker loop resolves: " .. tostring(runErr))
    Assert.equal(#received, 2, "the miss asks first, then the compiled job reports (" .. damage.label .. ")")
    Assert.equal(received[1].status, "source-needed", "the miss emits its typed pool request")
    Assert.equal(received[2].status, "prepared", "a damaged receipt compiles after its supply (" .. damage.label .. ")")
    Assert.isTrue(sourceOpened, "compilation opens the supplied source lazily (" .. damage.label .. ")")
  end
end

-- A receipt the backend reports present but cannot read is an
-- infrastructure failure, not unusable metadata: the job fails without
-- opening ROM source as a recovery fallback.
function T.unreadable_receipt_backend_failure_stays_terminal()
  local CompilerWorker = require("romdump.src.build.CompilerWorker")
  local CacheFs = require("libs.storage.src.CacheFs")
  local ArtifactState = require("romdump.src.build.ArtifactState")
  local RomFs = require("romdump.src.source.RomFs")
  local input = scriptedChannel({
    {
      kind = "field-font",
      key = "global",
      jobKey = "field-font:global",
      versionId = "heartgold",
      generationId = "backend-failure-generation",
      epoch = 1,
      stageName = "font-stage",
      sizeClass = "normal",
      payload = {},
      producerFingerprint = "producer",
    },
    { kind = "stop" },
  })
  local resultsChannel, received = recordingChannel()
  local sourceOpened = false
  local realOpen = RomFs.open
  RomFs.open = function(_)
    sourceOpened = true
    return { close = function(_) end }
  end
  local realExecute = CompilerWorker.execute
  CompilerWorker.execute = function(_, _)
    error("a backend receipt failure must not reach compilation")
  end
  local hosted = fakeLove()
  local runOk, runErr = withLove(hosted, function()
    local cacheFs = CacheFs.forVersion("heartgold")
    cacheFs:writeLua(ArtifactState.path("field-font", "global"), {
      schema = ArtifactState.RECEIPT_SCHEMA,
      generationId = "backend-failure-generation",
      kind = "field-font",
      key = "global",
      marker = "receipt-trust-marker",
    })
    local receiptFullPath = cacheFs:resolve(ArtifactState.path("field-font", "global"))
    local realRead = hosted.filesystem.read
    hosted.filesystem.read = function(path)
      if path == receiptFullPath then
        return nil, "injected receipt read failure"
      end
      return realRead(path)
    end
    return pcall(CompilerWorker.run, 1, input, resultsChannel)
  end)
  RomFs.open = realOpen
  CompilerWorker.execute = realExecute
  Assert.isTrue(runOk, "the driven worker loop resolves: " .. tostring(runErr))
  Assert.equal(#received, 1, "the failed job reports once")
  Assert.equal(received[1].status, "failed", "a backend receipt read failure stays terminal")
  Assert.isFalse(sourceOpened, "a backend failure never opens ROM source as a fallback")
end

function T.failed_source_close_emits_no_closure_acknowledgement()
  local CompilerWorker = require("romdump.src.build.CompilerWorker")
  local RomFs = require("romdump.src.source.RomFs")
  local job = {
    kind = "map",
    key = "60",
    jobKey = "map:60",
    versionId = "heartgold",
    generationId = "close-generation",
    epoch = 1,
    stageName = "close-stage",
    sizeClass = "normal",
    payload = { mapId = 60 },
    producerFingerprint = "producer",
  }
  local input = scriptedChannel({
    job,
    pooledSupply(job),
    { kind = "close-context", closeToken = "barrier-1" },
    { kind = "stop" },
  })
  local resultsChannel, received = recordingChannel()
  local realOpen = RomFs.open
  RomFs.open = function(_)
    return {
      close = function(_)
        error("synthetic source close failure")
      end,
    }
  end
  local runOk = withLove(fakeLove(), function()
    return pcall(CompilerWorker.run, 1, input, resultsChannel)
  end)
  RomFs.open = realOpen
  Assert.isTrue(runOk ~= nil, "the driven worker loop resolves")
  Assert.isTrue(#received >= 2, "the installing job asks and reports before the barrier")
  Assert.equal(received[1].status, "source-needed", "the miss emits its typed pool request")
  local terminal = nil
  for _, message in ipairs(received) do
    if message.jobKey == "map:60" and message.status ~= "source-needed" then
      terminal = message
    end
  end
  Assert.notNil(terminal, "the installing job reports exactly once after its supply")
  Assert.equal(terminal.status, "failed", "the job installing the throwing reader fails instead of compiling")
  local acknowledgements = 0
  for _, message in ipairs(received) do
    if message.status == "context-closed" then
      acknowledgements = acknowledgements + 1
    end
  end
  Assert.equal(acknowledgements, 0, "a failed source close emits no closure acknowledgement")
end

-- A mismatched pool reply never settles the suspended job: a wrong-epoch
-- supply is rejected without effect and the wait continues until the exact
-- matching buffer arrives, which then travels into the compile by
-- reference as the identical userdata object.
function T.mismatched_pool_reply_is_rejected_until_the_matching_supply_arrives()
  local CompilerWorker = require("romdump.src.build.CompilerWorker")
  local RomFs = require("romdump.src.source.RomFs")
  local job = {
    kind = "map",
    key = "61",
    jobKey = "map:61",
    versionId = "heartgold",
    generationId = "protocol-generation",
    epoch = 1,
    stageName = "map-stage",
    sizeClass = "normal",
    payload = { mapId = 61 },
    producerFingerprint = "producer",
  }
  local buffer = supplyBytes()
  local wrongEpoch = pooledSupply(job)
  wrongEpoch.epoch = 2
  wrongEpoch.romByteData = supplyBytes()
  local matching = pooledSupply(job)
  matching.romByteData = buffer
  local input = scriptedChannel({ job, wrongEpoch, matching, { kind = "stop" } })
  local resultsChannel, received = recordingChannel()
  local openedSources = {}
  local realOpen = RomFs.open
  RomFs.open = function(_, source)
    openedSources[#openedSources + 1] = source
    return { close = function(_) end }
  end
  local realExecute = CompilerWorker.execute
  CompilerWorker.execute = function(_, _)
    return { stageName = "map-stage", result = { marker = "fresh-marker" } }
  end
  local runOk, runErr = withLove(fakeLove(), function()
    return pcall(CompilerWorker.run, 1, input, resultsChannel)
  end)
  RomFs.open = realOpen
  CompilerWorker.execute = realExecute
  Assert.isTrue(runOk, "the driven worker loop resolves: " .. tostring(runErr))
  Assert.equal(#received, 2, "the miss asks once and reports once after its matching supply")
  Assert.equal(received[1].status, "source-needed", "the miss emits its typed pool request")
  Assert.equal(received[2].status, "prepared", "the matching supply continues through staging")
  Assert.equal(#openedSources, 1, "only the matching supply opens the source")
  Assert.isTrue(openedSources[1]:byteData() == buffer, "the compile borrows the identical buffer object, never a copy")
end

-- A pool-reported source failure settles the suspended job as failed with
-- the typed cause instead of compiling: the miss reports nothing terminal
-- before its reply, and compilation never runs without source bytes.
function T.pool_reported_source_failure_fails_the_job_with_its_typed_cause()
  local CompilerWorker = require("romdump.src.build.CompilerWorker")
  local RomFs = require("romdump.src.source.RomFs")
  local job = {
    kind = "map",
    key = "61",
    jobKey = "map:61",
    versionId = "heartgold",
    generationId = "unavailable-generation",
    epoch = 1,
    stageName = "map-stage",
    sizeClass = "normal",
    payload = { mapId = 61 },
    producerFingerprint = "producer",
  }
  local input = scriptedChannel({
    job,
    {
      kind = "source-unavailable",
      workerId = 1,
      jobKey = "map:61",
      versionId = "heartgold",
      generationId = "unavailable-generation",
      epoch = 1,
      error = { code = "ROM_SOURCE_REQUIRED", message = "the uncached asset needs its ROM", context = {} },
    },
    { kind = "stop" },
  })
  local resultsChannel, received = recordingChannel()
  local realOpen = RomFs.open
  RomFs.open = function(_)
    error("an unavailable source must never open")
  end
  local realExecute = CompilerWorker.execute
  CompilerWorker.execute = function(_, _)
    error("an unavailable source must never compile")
  end
  local runOk, runErr = withLove(fakeLove(), function()
    return pcall(CompilerWorker.run, 1, input, resultsChannel)
  end)
  RomFs.open = realOpen
  CompilerWorker.execute = realExecute
  Assert.isTrue(runOk, "the driven worker loop resolves: " .. tostring(runErr))
  Assert.equal(#received, 2, "the miss asks once and fails once on its typed reply")
  Assert.equal(received[1].status, "source-needed", "the miss emits its typed pool request")
  Assert.equal(received[2].status, "failed", "the unavailable reply fails the suspended job")
  Assert.equal(received[2].jobKey, "map:61", "the failure names its job")
  Assert.equal(type(received[2].error), "table", "the failure carries its typed cause")
  Assert.equal(received[2].error.code, "ROM_SOURCE_REQUIRED", "the cause keeps its source-required code")
end

-- A missing current receipt suspends only its own job behind a typed pool
-- request: the worker names the exact worker and job that need source bytes
-- and waits for the matching pool reply instead of opening the ROM itself.
-- A receipt hit on the same worker still reuses with no source traffic at
-- all, even when the persisted binding points at a file that no longer
-- exists. The input channel stands in for the pool: it injects the matching
-- supply the moment the worker asks, so the suspended job can continue
-- through the ordinary staging path.
function T.receipt_miss_asks_the_pool_for_source_and_suspends_the_job()
  local CompilerWorker = require("romdump.src.build.CompilerWorker")
  local CacheFs = require("libs.storage.src.CacheFs")
  local ArtifactState = require("romdump.src.build.ArtifactState")
  local RomFs = require("romdump.src.source.RomFs")
  local RomSource = require("romdump.src.source.RomSource")
  local NdsBuilder = require("tests.support.NdsBuilder")
  local DumpFixture = require("tests.support.DumpFixture")
  local GameVersion = require("romdump.src.source.GameVersion")
  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  local versionId = "synthworker"
  local generation = "pool-request-generation"
  local spec = DumpFixture.spec()
  spec.gameCode = "IXPW"
  local data = NdsBuilder.build(spec)
  local sha1 = RomSource.fromString(data):sha1()
  local saved = GameVersion.VERSIONS[versionId]
  GameVersion.VERSIONS[versionId] = {
    id = versionId,
    label = "Synthetic",
    displayName = "Synthetic Cartridge",
    sha1 = sha1,
    gameCode = "IXPW",
    expectedSize = #data,
  }
  local bodyOk, bodyErr = pcall(function()
    local function mapJob(key, mapId)
      return {
        kind = "map",
        key = key,
        jobKey = "map:" .. key,
        versionId = versionId,
        generationId = generation,
        epoch = 1,
        stageName = "map-stage",
        sizeClass = "normal",
        payload = { mapId = mapId },
        producerFingerprint = "producer",
      }
    end
    local pending = { mapJob("60", 60), mapJob("61", 61), { kind = "stop" } }
    local input = {}
    function input:push(value)
      pending[#pending + 1] = value
      return true
    end
    function input:pop()
      if #pending == 0 then
        return nil
      end
      return table.remove(pending, 1)
    end
    function input:demand()
      local value = self:pop()
      assert(value ~= nil, "the worker demanded beyond its scripted controls")
      return value
    end
    function input:getCount()
      return #pending
    end
    function input:queueFront(value)
      table.insert(pending, 1, value)
    end
    local received = {}
    local sourceRequests = {}
    local resultsChannel = {}
    function resultsChannel:push(value)
      received[#received + 1] = value
      if type(value) == "table" and value.status == "source-needed" then
        sourceRequests[#sourceRequests + 1] = value
        input:queueFront({
          kind = "source-supplied",
          workerId = value.workerId,
          jobKey = value.jobKey,
          versionId = value.versionId,
          generationId = value.generationId,
          epoch = value.epoch,
          romByteData = self.supplyBuffer,
        })
      end
      return true
    end
    function resultsChannel:pop()
      return nil
    end
    function resultsChannel:demand()
      error("the result channel is push-only in this scenario")
    end
    function resultsChannel:getCount()
      return 0
    end
    local openCalls = {}
    local realOpen = RomFs.open
    RomFs.open = function(first, second)
      openCalls[#openCalls + 1] = { first = first, second = second }
      return realOpen(first, second)
    end
    local realExecute = CompilerWorker.execute
    CompilerWorker.execute = function(_)
      return { stageName = "map-stage", result = { marker = "fresh-marker" } }
    end
    local backend = FakeCache.new()
    local fake = {
      filesystem = {
        write = function(path, content)
          return backend:write(path, content)
        end,
        read = function(path)
          return backend:read(path)
        end,
        getInfo = function(path)
          return backend:getInfo(path)
        end,
        createDirectory = function(path)
          return backend:createDirectory(path)
        end,
        remove = function(path)
          return backend:remove(path)
        end,
        getDirectoryItems = function(path)
          return backend:getDirectoryItems(path)
        end,
      },
      timer = {
        getTime = function()
          return 0
        end,
      },
      data = hostLove.data,
    }
    local summary = withLove(fake, function()
      resultsChannel.supplyBuffer = hostLove.data.newByteData(data)
      local cacheFs = CacheFs.forVersion(versionId)
      cacheFs:writeLua(ArtifactState.path("map", "60"), {
        schema = ArtifactState.RECEIPT_SCHEMA,
        generationId = generation,
        kind = "map",
        key = "60",
        marker = "receipt-trust-marker",
      })
      -- The persisted binding dangles at a removed file: reuse must never
      -- consult it, and the miss must ask the pool rather than the path.
      cacheFs:writeLua("rom-source.lua", {
        schema = 1,
        versionId = versionId,
        romSha1 = sha1,
        kind = "nds",
        path = "/nonexistent/synthetic.nds",
        displayName = "synthetic.nds",
        zipEntry = false,
      })
      local completed, runErr = pcall(CompilerWorker.run, 1, input, resultsChannel)
      if completed then
        return "ok"
      end
      return "run failed: " .. tostring(runErr)
    end)
    RomFs.open = realOpen
    CompilerWorker.execute = realExecute
    Assert.equal(summary, "ok", "the worker suspends the miss behind a pool supply instead of failing it: " .. summary)
    Assert.isTrue(#received >= 1, "the driven worker reports its jobs")
    Assert.equal(received[1].status, "reused", "the receipt hit reuses without source traffic")
    Assert.equal(#sourceRequests, 1, "the miss emits exactly one typed source request")
    local request = sourceRequests[1]
    Assert.equal(request.workerId, 1, "the request names its worker")
    Assert.equal(request.jobKey, "map:61", "the request names its job")
    Assert.equal(request.versionId, versionId, "the request names its version")
    Assert.equal(request.generationId, generation, "the request names its generation")
    Assert.equal(request.epoch, 1, "the request names its epoch")
    local requestIndex, terminalIndex = nil, nil
    for index, message in ipairs(received) do
      if message == request then
        requestIndex = index
      end
      if
        type(message) == "table"
        and message.jobKey == "map:61"
        and (message.status == "reused" or message.status == "prepared" or message.status == "failed")
      then
        terminalIndex = index
        Assert.equal(message.status, "prepared", "the supplied job continues through staging")
      end
    end
    Assert.notNil(requestIndex, "the source request reaches the pool channel")
    Assert.notNil(terminalIndex, "the suspended job reports exactly once after its supply")
    Assert.isTrue(
      (terminalIndex or 0) > (requestIndex or 0),
      "the miss reports nothing terminal before its supply arrives"
    )
    Assert.equal(#openCalls, 1, "only the genuine miss opens source, never the receipt hit")
    local only = openCalls[1]
    Assert.equal(only.first, versionId, "the source open names its version")
    Assert.equal(type(only.second), "table", "the miss opens a direct source, never the dump")
    Assert.equal(
      type(only.second) == "table" and type(only.second.read) == "function" and type(only.second.sha1) == "function",
      true,
      "the direct open carries a readable source view"
    )
  end)
  GameVersion.VERSIONS[versionId] = saved
  if not bodyOk then
    error(bodyErr, 0)
  end
end

return { tests = T }
