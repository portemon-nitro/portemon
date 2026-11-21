-- Worker source-close barrier: the close-context control owns the owned
-- source reader, and a reader that fails to close must never be
-- acknowledged as closed. The production run loop is driven with scripted
-- channels; the first job installs a throwing reader, then the barrier
-- control must surface the failure without a closure acknowledgement.

local Assert = require("tests.support.Assert")
local ArtifactState = require("romdump.src.build.ArtifactState")
local FakeCache = require("tests.support.FakeCache")
local ResidentArtifactFixture = require("tests.support.ResidentArtifactFixture")

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

-- An optional store lets a scenario drive the production reader against the
-- same in-memory tree its own cache access already published into.
local function fakeLove(sharedBackend)
  local backend = sharedBackend or FakeCache.new()
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

-- Every dispatched job carries the controller's attempt identity and its
-- declared dependency closure. These fixture generations own no committed
-- prerequisites, so each job reads an empty, closed dependency view.
local dispatchSequence = 0
local function asDispatched(value)
  if
    type(value) ~= "table"
    or type(value.kind) ~= "string"
    or type(value.jobKey) ~= "string"
    or type(value.versionId) ~= "string"
    or type(value.generationId) ~= "string"
    or value.sizeClass == nil
  then
    return value
  end
  if value.dispatchId == nil then
    dispatchSequence = dispatchSequence + 1
    value.dispatchId = dispatchSequence
  end
  if value.dependencies == nil then
    value.dependencies = {
      sourceId = "base:" .. value.generationId,
      artifacts = ArtifactState.new(value.generationId),
      entries = {},
    }
  end
  return value
end

local function scriptedChannel(messages)
  local pending = {}
  for _, message in ipairs(messages) do
    pending[#pending + 1] = asDispatched(message)
  end
  local channel = {}
  function channel:push(value)
    pending[#pending + 1] = asDispatched(value)
    return true
  end
  function channel:pop()
    if #pending == 0 then
      return nil
    end
    return asDispatched(table.remove(pending, 1))
  end
  function channel:demand()
    local value = self:pop()
    assert(value ~= nil, "the worker demanded beyond its scripted controls")
    return value
  end
  function channel:getCount()
    return #pending
  end
  function channel:queueFront(value)
    table.insert(pending, 1, asDispatched(value))
    return true
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

-- A compiled job asks the pool for its shared source and only compiles once
-- the matching supply arrives: the controller dispatches uncompiled work, so
-- the worker owns no local reuse decision.
function T.missing_source_asks_the_pool_and_compiles_after_its_supply()
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
  Assert.equal(#received, 2, "the job asks first, then reports")
  Assert.equal(received[1].status, "source-needed", "the job emits its typed pool request")
  Assert.equal(received[1].jobKey, "field-font:global", "the request names its job")
  Assert.equal(received[2].status, "prepared", "the job compiles after its supply")
  Assert.isTrue(sourceOpened, "compilation opens the supplied source lazily")
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

-- A missing source suspends only its own job behind a typed pool request: the
-- worker names the exact worker and job that need source bytes and waits for
-- the matching pool reply instead of opening the ROM itself. The input channel
-- stands in for the pool: it injects the matching supply the moment the worker
-- asks, so the suspended job continues through the ordinary staging path, and
-- the second job reuses the installed source view without asking again.
function T.missing_source_suspends_the_job_and_reuses_one_supply()
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
    for _, entry in ipairs(pending) do
      asDispatched(entry)
    end
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
      -- The persisted binding dangles at a removed file: the worker must ask
      -- the pool rather than the path.
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
    Assert.equal(#sourceRequests, 1, "the worker asks for its source exactly once")
    local request = sourceRequests[1]
    Assert.equal(request.workerId, 1, "the request names its worker")
    Assert.equal(request.jobKey, "map:60", "the request names the job that needs source bytes")
    Assert.equal(request.versionId, versionId, "the request names its version")
    Assert.equal(request.generationId, generation, "the request names its generation")
    Assert.equal(request.epoch, 1, "the request names its epoch")
    local requestIndex, terminalIndex = nil, nil
    local prepared = 0
    for index, message in ipairs(received) do
      if message == request then
        requestIndex = index
      end
      if type(message) == "table" and (message.jobKey == "map:60" or message.jobKey == "map:61") then
        if message.status == "prepared" then
          prepared = prepared + 1
        elseif message.status ~= "source-needed" then
          terminalIndex = index
        end
        if message.jobKey == "map:61" and message.status == "prepared" then
          terminalIndex = index
        end
      end
    end
    Assert.equal(prepared, 2, "both jobs continue through staging on the one supply")
    Assert.notNil(requestIndex, "the source request reaches the pool channel")
    Assert.notNil(terminalIndex, "the suspended job reports exactly once after its supply")
    Assert.isTrue(
      (terminalIndex or 0) > (requestIndex or 0),
      "the miss reports nothing terminal before its supply arrives"
    )
    Assert.equal(#openCalls, 1, "the installed source view serves every job without reopening")
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

-- A compilation failure carries its cause back to the pool instead of
-- reporting bare status: the pool can only surface what the completion
-- carries, so a dropped cause settles the milestone as the generic
-- "worker failed" fault with no clue about the original throw.
function T.compile_failures_carry_their_cause_to_the_pool()
  local CompilerWorker = require("romdump.src.build.CompilerWorker")
  local Errors = require("libs.errors.src.Errors")
  local RomFs = require("romdump.src.source.RomFs")
  local untyped = {
    kind = "map",
    key = "62",
    jobKey = "map:62",
    versionId = "heartgold",
    generationId = "compile-cause-generation",
    epoch = 1,
    stageName = "cause-stage-untyped",
    sizeClass = "normal",
    payload = { mapId = 62 },
    producerFingerprint = "producer",
  }
  local typed = {
    kind = "map",
    key = "63",
    jobKey = "map:63",
    versionId = "heartgold",
    generationId = "compile-cause-generation",
    epoch = 1,
    stageName = "cause-stage-typed",
    sizeClass = "normal",
    payload = { mapId = 63 },
    producerFingerprint = "producer",
  }
  -- The second job reuses the source view the first job installed: same
  -- version and generation never ask the pool twice, so no second supply
  -- is scripted. A stray supply here would be consumed as a job.
  local input = scriptedChannel({ untyped, pooledSupply(untyped), typed, { kind = "stop" } })
  local resultsChannel, received = recordingChannel()
  local realOpen = RomFs.open
  RomFs.open = function(_)
    return { close = function(_) end }
  end
  local realExecute = CompilerWorker.execute
  CompilerWorker.execute = function(executeJob, _)
    if executeJob.key == "62" then
      error("synthetic untyped boom")
    end
    error(Errors.new("BAG_SOURCE_INVALID", "bag synthetic boom", { role = "upper-base" }))
  end
  local runOk, runErr = withLove(fakeLove(), function()
    return pcall(CompilerWorker.run, 1, input, resultsChannel)
  end)
  RomFs.open = realOpen
  CompilerWorker.execute = realExecute
  Assert.isTrue(runOk, "the driven worker loop resolves: " .. tostring(runErr))
  Assert.equal(#received, 3, "the miss asks once, then each failed job reports")
  local untypedTerminal, typedTerminal = nil, nil
  for _, message in ipairs(received) do
    if message.jobKey == "map:62" and message.status ~= "source-needed" then
      untypedTerminal = message
    elseif message.jobKey == "map:63" and message.status ~= "source-needed" then
      typedTerminal = message
    end
  end
  Assert.notNil(untypedTerminal, "the untyped failure reports exactly once")
  Assert.equal(untypedTerminal.status, "failed", "a throwing compilation stays terminal")
  Assert.equal(type(untypedTerminal.error), "string", "an untyped throw travels as plain data")
  Assert.isTrue(
    untypedTerminal.error:find("synthetic untyped boom", 1, true) ~= nil,
    "the failure keeps the compile message: " .. untypedTerminal.error
  )
  Assert.isTrue(
    untypedTerminal.error:lower():find("traceback", 1, true) ~= nil,
    "the failure keeps the throw-site trace: " .. untypedTerminal.error
  )
  Assert.notNil(typedTerminal, "the typed failure reports exactly once")
  Assert.equal(typedTerminal.status, "failed", "a typed compilation failure stays terminal")
  Assert.equal(
    type(typedTerminal.error),
    "table",
    "a typed failure travels as a plain table, got: " .. tostring(typedTerminal.error)
  )
  Assert.isNil(getmetatable(typedTerminal.error), "the typed cause carries no metatable across the channel")
  Assert.equal(typedTerminal.error.code, "BAG_SOURCE_INVALID", "the cause keeps its error code")
  Assert.isTrue(
    tostring(typedTerminal.error.message):find("bag synthetic boom", 1, true) ~= nil,
    "the cause keeps its message"
  )
  Assert.equal(type(typedTerminal.error.traceback), "string", "the typed cause keeps the throw-site trace")
end

-- A cache backend failure carries its cause the same way: the receipt read
-- runs behind an xpcall boundary too, so its infrastructure message must
-- reach the pool instead of collapsing to the generic fault.

-- A generation owns its own compiled output: the same job asked for under a
-- newer generation asks for its source again instead of settling as reuse, and
-- generated publication never reaches user saves or mods.
function T.new_generation_rebuilds_the_job_and_leaves_saves_untouched()
  local CompilerWorker = require("romdump.src.build.CompilerWorker")
  local CacheFs = require("libs.storage.src.CacheFs")
  local ArtifactState = require("romdump.src.build.ArtifactState")
  local RomFs = require("romdump.src.source.RomFs")
  local versionId = "heartgold"
  local earlierGeneration = "generation-one"
  local selectedGeneration = "generation-two"
  local savePath = "saves/heartgold/slot-1.lua"
  local saveLogical = "return { playTime = 3600 }\n"
  local modPath = "mods/hard-mode/info.lua"
  local modLogical = "return { name = 'hard mode' }\n"
  local backend = FakeCache.new()
  backend:write(savePath, saveLogical)
  backend:write(modPath, modLogical)

  local cache = CacheFs.forVersion(versionId, backend)
  cache:write("data/generated/maps/0007/terrain.lua", "return { earlier = true }\n")

  local sourceRequests = {}
  local reported = {}
  local sourceOpens = 0
  withLove(fakeLove(backend), function()
    local job = {
      kind = "map",
      key = "7",
      jobKey = "map:7",
      versionId = versionId,
      generationId = selectedGeneration,
      epoch = 2,
      stageName = "map-stage",
      sizeClass = "normal",
      payload = { mapId = 7 },
      producerFingerprint = "producer",
    }
    local input = scriptedChannel({ job, { kind = "stop" } })
    local resultsChannel = scriptedChannel({})
    local push = resultsChannel.push
    function resultsChannel:push(value)
      reported[#reported + 1] = value
      if type(value) == "table" and value.status == "source-needed" then
        sourceRequests[#sourceRequests + 1] = value
        input:queueFront(pooledSupply(value))
      end
      return push(self, value)
    end
    local realOpen = RomFs.open
    RomFs.open = function()
      sourceOpens = sourceOpens + 1
      return { close = function(_) end }
    end
    local realExecute = CompilerWorker.execute
    CompilerWorker.execute = function(executeJob)
      return { stageName = executeJob.stageName, result = { marker = "fresh" } }
    end
    local completed, runErr = pcall(CompilerWorker.run, 1, input, resultsChannel)
    RomFs.open = realOpen
    CompilerWorker.execute = realExecute
    Assert.isTrue(completed, "the driven worker loop resolves: " .. tostring(runErr))

    Assert.equal(
      cache:read("data/generated/maps/0007/terrain.lua"),
      "return { earlier = true }\n",
      "the earlier generation's bytes stay in place until the replacement publishes"
    )
  end)

  Assert.equal(#sourceRequests, 1, "a new generation asks for its source exactly once")
  Assert.equal(sourceRequests[1].generationId, selectedGeneration, "the request names the selected generation")
  Assert.equal(sourceOpens, 1, "the job compiles from a freshly supplied source")
  local terminal = {}
  for _, message in ipairs(reported) do
    if
      type(message) == "table"
      and message.jobKey == "map:7"
      and (message.status == "reused" or message.status == "prepared" or message.status == "failed")
    then
      terminal[#terminal + 1] = message
    end
  end
  Assert.equal(#terminal, 1, "the job reports exactly one terminal result")
  Assert.equal(terminal[1].status, "prepared", "the newer generation compiles its own output")

  Assert.isNil(cache:read(savePath), "a generated cache root never reaches a save")
  Assert.isNil(cache:read(modPath), "a generated cache root never reaches a mod")
  Assert.equal(backend:read(savePath), saveLogical, "generated publication leaves user saves untouched")
  Assert.equal(backend:read(modPath), modLogical, "generated publication leaves mods untouched")
end

-- A real 2D atlas family runs end to end through the worker: the field-font
-- source phase stages its definitions and defers every atlas as one image
-- packet, the low-priority continuation encodes those RGBA rows into the same
-- private output, and the parent seals once with its PNGs. While the images are
-- pending the packet carries no PNG and the parent is not sealed.
function T.real_atlas_producer_defers_its_pngs_until_the_continuation_writes_them()
  local CompilerWorker = require("romdump.src.build.CompilerWorker")
  local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
  local FieldFontSourceFixture = require("tests.support.FieldFontSourceFixture")
  local RomFs = require("romdump.src.source.RomFs")
  local CacheFs = require("libs.storage.src.CacheFs")

  local hostLove = assert(rawget(_G, "love"), "the suite runs under the host runtime")
  local backend = FakeCache.new()
  local loveHost = fakeLove(backend)
  loveHost.data = hostLove.data
  local versionId = "heartgold"
  local generation = "deferred-png-real-producer-generation"
  local romFs = assert(FieldFontSourceFixture.build())
  romFs.close = function() end
  local cacheFs = CacheFs.forVersion(versionId, backend)
  local imagePaths = {}
  for _, fontId in ipairs(FieldFontCache.REQUIRED_FONT_IDS) do
    imagePaths[#imagePaths + 1] = FieldFontCache.atlasPath(fontId)
    imagePaths[#imagePaths + 1] = FieldFontCache.maskAtlasPath(fontId)
    imagePaths[#imagePaths + 1] = FieldFontCache.focusIndicatorsPath(fontId)
  end
  local sourceJob = {
    kind = "field-font",
    key = "global",
    jobKey = "field-font:global",
    versionId = versionId,
    generationId = generation,
    epoch = 1,
    sizeClass = "normal",
    payload = {},
    producerFingerprint = "producer",
  }
  asDispatched(sourceJob)
  local input = scriptedChannel({ sourceJob, pooledSupply(sourceJob) })
  local resultsChannel, received = recordingChannel()
  local imagePacket, continuationSent, entriesBeforeContinuation
  local realDemand = input.demand
  input.demand = function(self)
    if self:getCount() > 0 then
      return self:pop()
    end
    if continuationSent then
      return { kind = "stop" }
    end
    local parent
    for _, message in ipairs(received) do
      if message.jobKey == sourceJob.jobKey and message.status == "images-pending" then
        parent = message
      end
    end
    Assert.notNil(parent, "the real producer reports its pending image packet before any continuation")
    imagePacket = parent
    local stagedPaths = {}
    for _, entry in ipairs(parent.entries) do
      stagedPaths[entry.path] = true
    end
    entriesBeforeContinuation = stagedPaths
    continuationSent = true
    return {
      kind = "encode-png",
      workerId = 1,
      dispatchId = sourceJob.dispatchId,
      parentKind = sourceJob.kind,
      key = sourceJob.key,
      jobKey = sourceJob.jobKey,
      versionId = sourceJob.versionId,
      generationId = sourceJob.generationId,
      epoch = sourceJob.epoch,
      dependencies = sourceJob.dependencies,
      pending = {
        generationId = generation,
        epoch = 1,
        kind = sourceJob.kind,
        key = sourceJob.key,
        jobKey = sourceJob.jobKey,
        marker = parent.marker,
        ownedRoots = parent.ownedRoots,
        sharedPaths = parent.sharedPaths,
        entries = parent.entries,
        images = parent.images,
      },
    }
  end
  local realOpen = RomFs.open
  RomFs.open = function()
    return romFs
  end
  local runOk, runErr
  withLove(loveHost, function()
    runOk, runErr = pcall(CompilerWorker.run, 1, input, resultsChannel)
  end)
  RomFs.open = realOpen
  input.demand = realDemand
  Assert.isTrue(runOk, "the driven worker loop resolves: " .. tostring(runErr))
  Assert.isTrue(continuationSent, "the worker asked for its continuation after the parent deferred its images")
  Assert.equal(#imagePacket.images, 9, "the field-font family defers three images for each of its three fonts")
  Assert.isNil(imagePacket.entries ~= nil and imagePacket.entries[1] and nil, "no payload travels as an argument")
  for _, path in ipairs(imagePaths) do
    Assert.isNil(entriesBeforeContinuation[path], "no PNG is staged before the continuation: " .. path)
  end
  local sealedReply = nil
  for _, message in ipairs(received) do
    if message.jobKey == sourceJob.jobKey and message.status == "prepared" then
      sealedReply = message
    end
  end
  Assert.notNil(sealedReply, "the continuation seals the parent exactly once")
  Assert.equal(sealedReply.dispatchId, sourceJob.dispatchId, "the sealed reply answers the parent attempt")
  local sealedPaths = {}
  for _, entry in ipairs(sealedReply.entries) do
    sealedPaths[entry.path] = entry
  end
  for _, path in ipairs(imagePaths) do
    local entry = assert(sealedPaths[path], "the sealed parent carries the deferred PNG: " .. path)
    Assert.equal(entry.data:getString():sub(1, 4), "\137PNG", "the continuation writes one plain PNG: " .. path)
  end
  for _, entry in ipairs(sealedReply.entries) do
    Assert.isNil(entry.path:find("%.rgba$"), "the sealed output holds no persistent RGBA file: " .. entry.path)
  end
  ResidentArtifactFixture.mirror(cacheFs, sealedReply)
  for _, path in ipairs(imagePaths) do
    Assert.notNil(cacheFs:read(path), "the published generation carries the deferred PNG: " .. path)
  end
end

return { tests = T }
