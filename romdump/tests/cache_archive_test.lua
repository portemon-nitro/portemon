-- The background snapshot writer owns one plain ZIP per selected version: it
-- receives one already consistent cut of committed artifact bytes plus the
-- small completion facts, encodes that cut once through the real LÖVE
-- filesystem, and replaces the previous canonical archive through
-- cache.zip.new / cache.zip.bak. A successful write is trusted (nothing is
-- reopened or unzipped afterwards), a failed write leaves a recoverable
-- previous archive, and the writer never derives game completion, readiness,
-- or job identity itself.
--
-- The worker command vocabulary is internal to this pair of modules, so this
-- suite fixes it: `{ op = "snapshot", versionId, generationId, epoch, sequence,
-- identity, entries, artifacts, milestones, firstPlay, complete }` where
-- entries are the immutable BlobRefs of one cut and each artifact's `files` are
-- the logical paths it published (the writer turns them into the manifest's
-- numeric entry indexes). The answer is `{ op = "snapshot-persisted", ... }` or
-- `{ op = "snapshot-failed", ..., error = { code, message } }`, both carrying
-- the captured version/generation/epoch/sequence. `{ op = "stop" }` ends the
-- worker loop.
--
-- Every scenario composes the production writer in a real Lua state and
-- instruments only the host filesystem boundary it already writes through, so
-- the recorded trace is the archive's own I/O, not a reimplementation of it.

local Assert = require("tests.support.Assert")
local SnapshotArchive = require("tests.support.SnapshotArchive")

local T = {}

local VERSION_PREFIX = "archive-probe"

-- Test-owned worker entry: instrument the host filesystem in the writer's own
-- Lua state, then run the production archive worker unchanged.
local WRITER_THREAD = [[
local control, reply, trace, settings = ...
if type(settings.packagePath) == "string" and settings.packagePath ~= "" then
  package.path = settings.packagePath
end
pcall(require, "love.filesystem")
pcall(require, "love.data")
pcall(require, "love.timer")
local love = require("love")
local fs = love.filesystem

local failures = settings.failures or {}
local gated = settings.gated
local fired = {}

local function matches(spec, op, value)
  if spec.op ~= op then
    return false
  end
  if spec.pathContains ~= nil then
    if type(value) ~= "string" or value:find(spec.pathContains, 1, true) == nil then
      return false
    end
  end
  return true
end

local function nextFailure(op, value)
  for _, spec in ipairs(failures) do
    if matches(spec, op, value) then
      local count = (fired[spec] or 0) + 1
      fired[spec] = count
      if count <= (spec.times or 1) then
        return spec
      end
    end
  end
  return nil
end

local function record(op, path, destination)
  trace:push({ op = op, path = path, destination = destination })
  if gated ~= nil and not gated.done and matches(gated, op, path) then
    gated.done = true
    gated.arrived:push(op)
    gated.release:demand()
  end
end

-- A write handle whose write/close results the trace sees; every other File
-- member is forwarded to the real handle.
local function trackedFile(handle, path)
  return setmetatable({}, {
    __index = function(_, key)
      if key == "write" then
        return function(self, ...)
          record("write", path)
          if nextFailure("write", path) ~= nil then
            return false, "injected write failure"
          end
          local written, message = handle:write(...)
          if written then
            return self
          end
          return false, message
        end
      end
      if key == "close" then
        return function()
          record("close", path)
          if nextFailure("close", path) ~= nil then
            return false, "injected close failure"
          end
          return handle:close()
        end
      end
      local member = handle[key]
      if type(member) == "function" then
        return function(_, ...)
          return member(handle, ...)
        end
      end
      return member
    end,
  })
end

local function wrap(name, op, failureShape)
  local original = fs[name]
  if type(original) ~= "function" then
    return
  end
  fs[name] = function(first, ...)
    record(op, first)
    if nextFailure(op, first) ~= nil then
      if failureShape == "nilMessage" then
        return nil, "injected " .. op .. " failure"
      elseif failureShape == "falseMessage" then
        return false, "injected " .. op .. " failure"
      end
    end
    return original(first, ...)
  end
end

for _, entry in ipairs({
  { "write", "write", "falseMessage" },
  { "append", "write", "falseMessage" },
  { "createDirectory", "mkdir", "falseMessage" },
  { "remove", "remove", "falseMessage" },
  { "read", "read", "nilMessage" },
  { "newFileData", "read", "nilMessage" },
}) do
  wrap(entry[1], entry[2], entry[3])
end

local realNewFile = fs.newFile
if type(realNewFile) == "function" then
  fs.newFile = function(path, mode)
    record("open", path)
    if nextFailure("open", path) ~= nil then
      return nil, "injected open failure"
    end
    local handle, message = realNewFile(path, mode)
    if handle == nil then
      return nil, message
    end
    return trackedFile(handle, path)
  end
end

local realRename = os.rename
os.rename = function(source, destination)
  record("rename", source, destination)
  if nextFailure("rename", destination) ~= nil or nextFailure("rename", source) ~= nil then
    return false, "injected rename failure"
  end
  return realRename(source, destination)
end

local ok, failure = xpcall(function()
  local CacheArchive = require("romdump.src.build.CacheArchive")
  CacheArchive.run(control, reply)
end, debug.traceback)
if not ok then
  trace:push({ op = "worker-error", path = tostring(failure) })
end
]]

local function requireArchive()
  local ok, archive = pcall(require, "romdump.src.build.CacheArchive")
  Assert.isTrue(
    ok and archive ~= nil and type(archive.run) == "function" and type(archive.bootstrap) == "function",
    "no background snapshot writer exists to save the resident generated cache: " .. tostring(archive)
  )
  return archive --[[@as table]]
end

local GENERATION
local function generation()
  if GENERATION == nil then
    local DerivedCacheState = require("romdump.src.DerivedCacheState")
    GENERATION = assert(DerivedCacheState.currentForSelection({
      versionId = "heartgold",
      romSha1 = string.rep("c", 40),
      producerId = "r3",
    }))
  end
  return GENERATION
end

local function blob(path, text)
  local identity = generation()
  return {
    path = path,
    data = assert(love.data.newByteData(text), "the cut needs real Data buffers"),
    size = #text,
    sourceId = "base:" .. identity.generationId,
    contentId = identity.generationId .. "\0" .. path,
  }
end

local function versionFor(name)
  return VERSION_PREFIX .. "-" .. name
end

local function awaitValue(channel, seconds)
  local deadline = love.timer.getTime() + (seconds or 20)
  while love.timer.getTime() < deadline do
    local value = channel:pop()
    if value ~= nil then
      return value
    end
    love.timer.sleep(0.002)
  end
  return nil
end

-- One writer Lua state plus the channels this thread uses to hand it a cut and
-- to receive its own host-operations trace.
local function startWriter(options)
  local host = assert(love.thread, "the snapshot writer needs real thread channels")
  local probe = {
    versionId = options.versionId,
    control = host.newChannel(),
    reply = host.newChannel(),
    trace = host.newChannel(),
    gatedArrived = host.newChannel(),
    gatedRelease = host.newChannel(),
  }
  local gated = options.gated
  if gated ~= nil then
    gated.arrived = probe.gatedArrived
    gated.release = probe.gatedRelease
    gated.done = false
  end
  probe.thread = assert(host.newThread(WRITER_THREAD))
  local settings = { packagePath = package.path, failures = options.failures or {}, gated = gated }
  local started, startError = pcall(function()
    probe.thread:start(probe.control, probe.reply, probe.trace, settings)
  end)
  Assert.isTrue(started, "the snapshot writer Lua state starts: " .. tostring(startError))
  return probe
end

local function stopWriter(probe)
  pcall(function()
    probe.gatedRelease:push(true)
  end)
  pcall(function()
    probe.control:push({ op = "stop", versionId = probe.versionId })
  end)
  for _ = 1, 600 do
    if not probe.thread:isRunning() then
      break
    end
    love.timer.sleep(0.005)
  end
  if probe.thread:isRunning() then
    probe.thread:kill("the snapshot writer did not stop")
    probe.thread:wait()
  end
end

local function cutFor(options)
  return {
    op = "snapshot",
    versionId = options.versionId,
    generationId = options.identity.generationId,
    epoch = 1,
    sequence = options.sequence,
    identity = options.identity,
    entries = options.entries,
    artifacts = options.artifacts or {},
    milestones = options.milestones or {},
    firstPlay = options.firstPlay == true,
    complete = options.complete == true,
  }
end

local function awaitAck(probe, sequence)
  local deadline = love.timer.getTime() + 40
  while love.timer.getTime() < deadline do
    local packet = awaitValue(probe.reply, 5)
    if packet == nil then
      return nil
    end
    if
      (packet.op == "snapshot-persisted" or packet.op == "snapshot-failed")
      and (sequence == nil or packet.sequence == sequence)
    then
      return packet
    end
  end
  return nil
end

local function drainTrace(probe)
  local entries = {}
  while true do
    local entry = probe.trace:pop()
    if entry == nil then
      break
    end
    entries[#entries + 1] = entry
  end
  return entries
end

local function assertNoWorkerError(operations, label)
  for _, operation in ipairs(operations) do
    Assert.isTrue(
      operation.op ~= "worker-error",
      "the writer reports through its acknowledgement, not by raising: " .. label .. ": " .. tostring(operation.path)
    )
  end
end

local function artifactNamed(index, kind, key)
  for _, artifact in ipairs(index.artifacts) do
    if artifact.kind == kind and artifact.key == key then
      return artifact
    end
  end
  return nil
end

local function artifactFiles(index, artifact)
  local result = {}
  for _, position in ipairs(artifact.files) do
    result[#result + 1] = assert(index.entries[position], "an artifact file index names a listed entry").path
  end
  return SnapshotArchive.sorted(result)
end

-- The snapshot a next boot would find: the canonical archive when it exists,
-- otherwise the backup the last failed rotation left behind.
local function recoverableSnapshot(versionId)
  local index, members = SnapshotArchive.read(versionId)
  if index ~= nil then
    return index, members
  end
  return SnapshotArchive.read(versionId, "cache.zip.bak")
end

local SHARED_PATH = "assets/generated/field/30/atlas.png"

local function previousCut(versionId)
  return cutFor({
    versionId = versionId,
    identity = generation(),
    sequence = 3,
    entries = { blob("data/generated/field/29/scene.lua", "old scene") },
    artifacts = {
      {
        kind = "map",
        key = "29",
        marker = "old-ready",
        dependencies = {},
        ownedRoots = { "data/generated/field/29" },
        sharedPaths = {},
        files = { "data/generated/field/29/scene.lua" },
      },
    },
  })
end

local function newerCut(versionId)
  return cutFor({
    versionId = versionId,
    identity = generation(),
    sequence = 5,
    entries = { blob("assets/generated/field/30/atlas.png", "NEW") },
    artifacts = {
      {
        kind = "map",
        key = "30",
        marker = "new-ready",
        dependencies = {},
        ownedRoots = { "assets/generated/field/30" },
        sharedPaths = {},
        files = { "assets/generated/field/30/atlas.png" },
      },
    },
  })
end

-- Runs one writer-driven scenario and always releases the Lua state and the
-- private version namespace it owned, whatever the scenario outcome.
local function withWriter(options, body)
  local probe = startWriter(options)
  local ok, err = pcall(body, probe)
  stopWriter(probe)
  SnapshotArchive.removeTree(options.versionId)
  if not ok then
    error(err, 0)
  end
end

-- Writes the snapshot every rotation scenario starts from. The caller owns the
-- version namespace and removes it when its scenario is over.
local function seedPreviousSnapshot(versionId)
  local probe = startWriter({ versionId = versionId })
  local ok, err = pcall(function()
    probe.control:push(previousCut(versionId))
    Assert.notNil(awaitAck(probe, 3), "the previous snapshot must exist before this scenario changes it")
    local index = SnapshotArchive.read(versionId)
    Assert.equal(index.sequence, 3, "the previous snapshot is canonical")
  end)
  stopWriter(probe)
  if not ok then
    SnapshotArchive.removeTree(versionId)
    error(err, 0)
  end
end

-- One cut, one archive: the manifest carries the captured identity, sequence,
-- whole-artifact closure, and completion facts of that cut, every declared
-- member holds the committed bytes with its checked size and CRC, and a payload
-- two artifacts share is one physical entry rather than two.
function T.one_snapshot_carries_exactly_the_cut_it_was_given()
  requireArchive()
  local versionId = versionFor("cut")
  local identity = generation()
  local cut = cutFor({
    versionId = versionId,
    identity = identity,
    sequence = 7,
    entries = {
      blob("data/generated/field/30/scene.lua", "return { mapId = 30 }\n"),
      blob("data/generated/scripts/30.lua", "return { script = 30 }\n"),
      blob(SHARED_PATH, "PNGDATA"),
    },
    artifacts = {
      {
        kind = "map",
        key = "30",
        marker = "map-ready",
        dependencies = {},
        ownedRoots = { "data/generated/field/30" },
        sharedPaths = { SHARED_PATH },
        files = { "data/generated/field/30/scene.lua", SHARED_PATH },
      },
      {
        kind = "script",
        key = "main",
        marker = "script-ready",
        dependencies = { "map:30" },
        ownedRoots = { "data/generated/scripts/30.lua" },
        sharedPaths = { SHARED_PATH },
        files = { "data/generated/scripts/30.lua", SHARED_PATH },
      },
    },
    milestones = { "bootstrap" },
    firstPlay = true,
  })
  local payloads = {}
  for _, entry in ipairs(cut.entries) do
    payloads[entry.path] = entry.data:getString()
  end

  withWriter({ versionId = versionId }, function(probe)
    probe.control:push(cut)
    cut = nil
    local ack = assert(awaitAck(probe, 7), "the writer must acknowledge the captured sequence")
    Assert.equal(ack.op, "snapshot-persisted", "a successful write acknowledges persistence")
    Assert.equal(ack.sequence, 7, "the acknowledgement names the captured sequence")
    Assert.equal(ack.generationId, identity.generationId, "the acknowledgement names the captured generation")
    Assert.equal(ack.epoch, 1, "the acknowledgement names the captured epoch")
    assertNoWorkerError(drainTrace(probe), "successful write")

    local index, members = SnapshotArchive.read(versionId)
    Assert.notNil(index, "a successful write leaves one canonical archive")
    Assert.equal(index.schema, "portemon-cache-zip-v1", "the archive declares its own snapshot schema")
    Assert.deepEqual(index.identity, identity, "the manifest carries the exact derived-cache identity")
    Assert.equal(index.sequence, 7, "the manifest carries the captured sequence")
    Assert.equal(index.complete, false, "a cut that is not the exhaustive closure never claims completeness")
    Assert.equal(index.firstPlay, true, "the captured first-play fact travels with its own cut")
    Assert.deepEqual(index.milestones, { "bootstrap" }, "the captured milestones travel with their own cut")

    local paths = SnapshotArchive.memberPaths(index)
    Assert.equal(#paths, 3, "the manifest lists the committed payloads and not itself")
    Assert.deepEqual(
      SnapshotArchive.sorted(paths),
      SnapshotArchive.sorted({
        "data/generated/field/30/scene.lua",
        "data/generated/scripts/30.lua",
        SHARED_PATH,
      }),
      "the manifest lists exactly the cut's payloads"
    )
    Assert.equal(paths[1], "assets/generated/field/30/atlas.png", "manifest entries are sorted by path")
    Assert.isNil(members["cache-index.lua"], "the index is not one of its own entries")

    for _, entry in ipairs(index.entries) do
      local expected = assert(payloads[entry.path], "the manifest names only cut payloads: " .. entry.path)
      Assert.equal(members[entry.path], expected, "the member holds the committed bytes: " .. entry.path)
      Assert.equal(entry.uncompressedSize, #expected, "the manifest reports the checked size: " .. entry.path)
      Assert.equal(
        entry.unsignedCrc32,
        SnapshotArchive.crc32(expected),
        "the manifest reports the member's CRC: " .. entry.path
      )
    end

    Assert.equal(#index.artifacts, 2, "both committed artifacts are captured")
    local map = assert(artifactNamed(index, "map", "30"), "the map artifact is captured under its canonical key")
    Assert.equal(map.marker, "map-ready", "the artifact keeps its completion marker")
    Assert.deepEqual(SnapshotArchive.sorted(map.dependencies), {}, "the artifact keeps its dependency facts")
    Assert.deepEqual(
      SnapshotArchive.sorted(map.ownedRoots),
      { "data/generated/field/30" },
      "the artifact keeps its owned roots"
    )
    Assert.deepEqual(SnapshotArchive.sorted(map.sharedPaths), { SHARED_PATH }, "the artifact keeps its shared paths")
    Assert.deepEqual(
      artifactFiles(index, map),
      SnapshotArchive.sorted({
        "data/generated/field/30/scene.lua",
        SHARED_PATH,
      }),
      "the artifact's file indexes name its own published payloads"
    )

    local script = assert(artifactNamed(index, "script", "main"), "the dependent artifact is captured under its key")
    Assert.deepEqual(
      SnapshotArchive.sorted(script.dependencies),
      { "map:30" },
      "the dependent artifact keeps its canonical dependency"
    )
    Assert.deepEqual(
      artifactFiles(index, script),
      SnapshotArchive.sorted({
        "data/generated/scripts/30.lua",
        SHARED_PATH,
      }),
      "the dependent artifact names the payload both artifacts share"
    )

    local sharedRows = 0
    for _, entry in ipairs(index.entries) do
      if entry.path == SHARED_PATH then
        sharedRows = sharedRows + 1
      end
    end
    Assert.equal(sharedRows, 1, "a payload two artifacts share is one physical entry")
  end)
end

-- A captured fact may only depend on another artifact captured by the same
-- cut, and a declared shared path must resolve to one of the cut's payloads.
-- A cut that breaks either rule is refused as a persistence failure and leaves
-- no archive behind.
function T.a_cut_with_a_dangling_artifact_reference_is_refused()
  requireArchive()
  local generationId = generation()
  local path = "data/generated/field/30/scene.lua"
  for _, case in ipairs({
    { name = "dependency", dependencies = { "script:missing" }, sharedPaths = {} },
    { name = "shared", dependencies = {}, sharedPaths = { "assets/generated/field/30/missing.png" } },
  }) do
    local versionId = versionFor("dangling-" .. case.name)
    local cut = cutFor({
      versionId = versionId,
      identity = generationId,
      sequence = 2,
      entries = { blob(path, "return { mapId = 30 }\n") },
      artifacts = {
        {
          kind = "map",
          key = "30",
          marker = "map-ready",
          dependencies = case.dependencies,
          ownedRoots = { "data/generated/field/30" },
          sharedPaths = case.sharedPaths,
          files = { path },
        },
      },
    })
    withWriter({ versionId = versionId }, function(probe)
      probe.control:push(cut)
      local ack = assert(awaitAck(probe, 2), "the writer answers a refused cut")
      Assert.equal(ack.op, "snapshot-failed", "a dangling reference is a persistence failure: " .. case.name)
      Assert.isNil(SnapshotArchive.read(versionId), "a refused cut writes no archive: " .. case.name)
    end)
  end
end

-- A payload two artifacts publish as their own output rather than as a
-- declared shared file is still one logical path: the manifest keeps one entry
-- for it, both artifacts keep their own file references, and the payload
-- hydrates back as one member.
function T.an_owned_output_two_artifacts_publish_is_one_hydrated_entry()
  local CacheArchive = requireArchive()
  local versionId = versionFor("overlap")
  local identity = generation()
  local ownedPath = "data/generated/battle/resources/battle/animation/shared-record.lua"
  local cut = cutFor({
    versionId = versionId,
    identity = identity,
    sequence = 11,
    entries = { blob(ownedPath, "return { record = true }\n") },
    artifacts = {
      {
        kind = "battle-effect",
        key = "TACKLE",
        marker = "tackle-ready",
        dependencies = {},
        ownedRoots = { ownedPath },
        sharedPaths = {},
        files = { ownedPath },
      },
      {
        kind = "battle-effect",
        key = "SCRATCH",
        marker = "scratch-ready",
        dependencies = {},
        ownedRoots = { ownedPath },
        sharedPaths = {},
        files = { ownedPath },
      },
    },
  })

  withWriter({ versionId = versionId }, function(probe)
    probe.control:push(cut)
    cut = nil
    local ack = assert(awaitAck(probe, 11), "the writer must acknowledge the captured sequence")
    Assert.equal(ack.op, "snapshot-persisted", "both artifacts' payload persists")
    assertNoWorkerError(drainTrace(probe), "overlapping owned output")

    local index = assert(SnapshotArchive.read(versionId), "the write leaves one canonical archive")
    Assert.equal(#index.entries, 1, "an overlapping owned output is one manifest entry")
    Assert.equal(#index.artifacts, 2, "both artifacts are captured")
    for _, key in ipairs({ "TACKLE", "SCRATCH" }) do
      local artifact = assert(artifactNamed(index, "battle-effect", key), "the artifact is captured: " .. key)
      Assert.deepEqual(artifactFiles(index, artifact), { ownedPath }, "the artifact names its own payload: " .. key)
      Assert.deepEqual(
        SnapshotArchive.sorted(artifact.ownedRoots),
        { ownedPath },
        "the artifact keeps its owned root: " .. key
      )
      Assert.deepEqual(
        SnapshotArchive.sorted(artifact.sharedPaths),
        {},
        "the artifact declares no shared path: " .. key
      )
    end

    local hydration, failure = CacheArchive.open(versionId, identity)
    Assert.isNil(failure, "the snapshot hydrates: " .. tostring(failure and failure.message))
    local hydrated = assert(hydration)
    Assert.equal(#hydrated.entries, 1, "a next boot hydrates one entry per path")
    Assert.equal(hydrated.entries[1].path, ownedPath, "the hydrated entry is the shared logical path")
    Assert.equal(hydrated.entries[1].data:getString(), "return { record = true }\n", "the member keeps its bytes")
    Assert.equal(#hydrated.artifacts, 2, "both artifact facts hydrate")
    for _, artifact in ipairs(hydrated.artifacts) do
      Assert.deepEqual(artifact.files, { ownedPath }, "the hydrated artifact names the payload: " .. artifact.key)
    end
  end)
end

-- The next capture is the latest committed cut, never a replay of the previous
-- one, and a cut already handed to the writer stays whole after the sender
-- drops every reference to it: the archive's own ownership keeps the bytes
-- alive until the write settles.
function T.a_later_cut_replaces_the_previous_snapshot_and_owns_its_bytes()
  requireArchive()
  local versionId = versionFor("sequence")
  seedPreviousSnapshot(versionId)

  local probe = startWriter({
    versionId = versionId,
    gated = { op = "write", pathContains = "cache.zip.new" },
  })
  local ok, err = pcall(function()
    local latest = cutFor({
      versionId = versionId,
      identity = generation(),
      sequence = 5,
      entries = {
        blob("data/generated/field/30/scene.lua", "new scene"),
        blob("data/generated/field/30/atlas.png", "NEW"),
      },
      artifacts = {
        {
          kind = "map",
          key = "30",
          marker = "new-ready",
          dependencies = {},
          ownedRoots = { "data/generated/field/30" },
          sharedPaths = {},
          files = { "data/generated/field/30/scene.lua", "data/generated/field/30/atlas.png" },
        },
      },
      milestones = { "bootstrap", "field" },
      firstPlay = true,
    })
    probe.control:push(latest)
    latest = nil
    collectgarbage("collect")

    Assert.equal(
      awaitValue(probe.gatedArrived, 20),
      "write",
      "the writer reaches the payload write this scenario holds"
    )
    local previous = SnapshotArchive.read(versionId)
    Assert.equal(previous.sequence, 3, "a cut still being written is not the canonical archive yet")

    probe.gatedRelease:push(true)
    local ack = assert(awaitAck(probe, 5), "the later cut is acknowledged for its own sequence")
    Assert.equal(ack.op, "snapshot-persisted", "the later cut persists")
    assertNoWorkerError(drainTrace(probe), "later cut")

    local index, members = SnapshotArchive.read(versionId)
    Assert.equal(index.sequence, 5, "the canonical archive is the latest captured cut")
    Assert.deepEqual(
      SnapshotArchive.sorted(SnapshotArchive.memberPaths(index)),
      SnapshotArchive.sorted({
        "data/generated/field/30/scene.lua",
        "data/generated/field/30/atlas.png",
      }),
      "the latest cut's payloads replace the earlier cut's payloads"
    )
    Assert.isNil(members["data/generated/field/29/scene.lua"], "an earlier cut's payload is not carried forward")
    Assert.equal(members["data/generated/field/30/atlas.png"], "NEW", "the writer kept the bytes it was handed")
    Assert.equal(index.firstPlay, true, "the later cut's first-play fact replaces the earlier one")
    Assert.deepEqual(index.milestones, { "bootstrap", "field" }, "the later cut's milestones replace the earlier ones")
    Assert.isNil(
      love.filesystem.getInfo(versionId .. "/cache.zip.bak"),
      "a successful replacement leaves no backup behind"
    )
    Assert.isNil(
      love.filesystem.getInfo(versionId .. "/cache.zip.new"),
      "a successful replacement leaves no temporary behind"
    )
  end)
  stopWriter(probe)
  SnapshotArchive.removeTree(versionId)
  if not ok then
    error(err, 0)
  end
end

-- Success is trusted: the writer opens, writes, closes, and renames its own
-- output, and never reopens, reads, mounts, or otherwise validates it.
function T.a_successful_snapshot_is_written_once_and_never_read_back()
  requireArchive()
  local versionId = versionFor("trusted")
  seedPreviousSnapshot(versionId)

  local probe = startWriter({ versionId = versionId })
  local ok, err = pcall(function()
    drainTrace(probe)
    probe.control:push(cutFor({
      versionId = versionId,
      identity = generation(),
      sequence = 4,
      entries = { blob("data/generated/field/30/scene.lua", "new scene") },
      artifacts = {
        {
          kind = "map",
          key = "30",
          marker = "new-ready",
          dependencies = {},
          ownedRoots = { "data/generated/field/30" },
          sharedPaths = {},
          files = { "data/generated/field/30/scene.lua" },
        },
      },
    }))
    assert(awaitAck(probe, 4), "the replacement snapshot persists")
    local operations = drainTrace(probe)
    assertNoWorkerError(operations, "trusted write")

    local openedOutput, wroteOutput, closedOutput = false, false, false
    local renamedToBackup, renamedToCanonical = false, false
    local reads = {}
    for _, operation in ipairs(operations) do
      local path = type(operation.path) == "string" and operation.path or ""
      local destination = type(operation.destination) == "string" and operation.destination or ""
      if operation.op == "open" and path:find("cache.zip.new", 1, true) then
        openedOutput = true
      elseif operation.op == "write" and path:find("cache.zip.new", 1, true) then
        wroteOutput = true
      elseif operation.op == "close" and path:find("cache.zip.new", 1, true) then
        closedOutput = true
      elseif operation.op == "rename" then
        if path:find("cache.zip", 1, true) and destination:find("cache.zip.bak", 1, true) then
          renamedToBackup = true
        elseif path:find("cache.zip.new", 1, true) and destination:find("cache.zip", 1, true) then
          renamedToCanonical = true
        end
      elseif operation.op == "read" then
        if path:find("cache.zip", 1, true) then
          reads[#reads + 1] = "read " .. path
        end
      end
    end

    Assert.isTrue(openedOutput, "the writer creates its temporary output")
    Assert.isTrue(wroteOutput, "the writer streams the payloads into that output")
    Assert.isTrue(closedOutput, "the writer closes the output it just wrote")
    Assert.isTrue(renamedToBackup, "the previous canonical archive is moved aside before replacement")
    Assert.isTrue(renamedToCanonical, "the finished temporary becomes the canonical archive")
    Assert.equal(
      #reads,
      0,
      "a successful write never reopens or validates its own output: " .. table.concat(reads, ", ")
    )

    local index = SnapshotArchive.read(versionId)
    Assert.equal(index.sequence, 4, "the trusted write is the canonical archive")
  end)
  stopWriter(probe)
  SnapshotArchive.removeTree(versionId)
  if not ok then
    error(err, 0)
  end
end

-- A failure at any step of the rotation reports a persistence error through the
-- writer's own answer and leaves the previous snapshot recoverable: the
-- canonical archive, or the backup that still holds it, is readable.
local FAILURE_CASES = {
  { name = "output-open", failures = { { op = "open", pathContains = "cache.zip.new" } } },
  { name = "payload-write", failures = { { op = "write", pathContains = "cache.zip.new" } } },
  { name = "output-close", failures = { { op = "close", pathContains = "cache.zip.new" } } },
  { name = "backup-rename", failures = { { op = "rename", pathContains = "cache.zip.bak" } } },
  { name = "promotion-rename", failures = { { op = "rename", pathContains = "cache.zip.new" } } },
}

function T.a_failed_write_keeps_a_recoverable_previous_snapshot()
  requireArchive()
  for _, case in ipairs(FAILURE_CASES) do
    local versionId = versionFor("failure-" .. case.name)
    seedPreviousSnapshot(versionId)
    local probe = startWriter({ versionId = versionId, failures = case.failures })
    local ok, err = pcall(function()
      probe.control:push(newerCut(versionId))
      local ack = assert(awaitAck(probe, 5), "a failed write still answers the sequence it tried: " .. case.name)
      Assert.equal(ack.op, "snapshot-failed", "the writer reports a persistence error: " .. case.name)
      Assert.notNil(ack.error, "the persistence error is reported, not swallowed: " .. case.name)
      Assert.equal(ack.sequence, 5, "the failure names the captured sequence: " .. case.name)
      assertNoWorkerError(drainTrace(probe), "failure case " .. case.name)

      local recovered, members = recoverableSnapshot(versionId)
      Assert.notNil(recovered, "a failed rotation leaves a recoverable snapshot: " .. case.name)
      Assert.equal(recovered.sequence, 3, "the recoverable snapshot is the previous cut: " .. case.name)
      Assert.equal(
        members["data/generated/field/29/scene.lua"],
        "old scene",
        "the recoverable snapshot still carries the previous bytes: " .. case.name
      )
    end)
    stopWriter(probe)
    local after = recoverableSnapshot(versionId)
    SnapshotArchive.removeTree(versionId)
    if not ok then
      error(err, 0)
    end
    Assert.notNil(after, "the previous snapshot survives the writer's own cleanup: " .. case.name)
    Assert.equal(after.sequence, 3, "the previous snapshot is unchanged after cleanup: " .. case.name)
  end
end

-- A cut that cannot be encoded is a persistence error, not a truncated archive:
-- the assembled Zip32 record limits are checked, and the snapshot the previous
-- boot would have used keeps its exact bytes.
function T.an_unencodable_cut_fails_without_touching_the_previous_snapshot()
  requireArchive()
  local versionId = versionFor("bounds")
  seedPreviousSnapshot(versionId)
  local _, _, beforeBytes = SnapshotArchive.read(versionId)
  Assert.notNil(beforeBytes, "the previous snapshot exists before the oversized cut")

  local entries = {}
  for index = 1, 65535 do
    entries[index] = blob(string.format("data/generated/field/bulk/%05d.lua", index), "x")
  end
  local oversized = cutFor({
    versionId = versionId,
    identity = generation(),
    sequence = 6,
    entries = entries,
    artifacts = {
      {
        kind = "field",
        key = "bulk",
        marker = "bulk-ready",
        dependencies = {},
        ownedRoots = { "data/generated/field/bulk" },
        sharedPaths = {},
        files = { entries[1].path },
      },
    },
  })

  local probe = startWriter({ versionId = versionId })
  local ok, err = pcall(function()
    probe.control:push(oversized)
    oversized, entries = nil, nil
    collectgarbage("collect")
    local ack = assert(awaitAck(probe, 6), "an unencodable cut still answers the sequence it tried")
    Assert.equal(ack.op, "snapshot-failed", "a cut beyond the archive's record bounds is a persistence error")
    Assert.notNil(ack.error, "the persistence error names its cause instead of truncating the archive")
    assertNoWorkerError(drainTrace(probe), "oversized cut")

    local after, _, afterBytes = SnapshotArchive.read(versionId)
    Assert.notNil(after, "the previous canonical archive is still there")
    Assert.equal(after.sequence, 3, "the previous canonical archive was not replaced")
    Assert.isTrue(afterBytes == beforeBytes, "the previous archive keeps its exact bytes")
  end)
  stopWriter(probe)
  SnapshotArchive.removeTree(versionId)
  if not ok then
    error(err, 0)
  end
end

-- Leftover rotation material is never mistaken for the snapshot, and the only
-- recoverable archive is not deleted before a closed replacement exists.
function T.leftover_rotation_files_never_cost_the_only_recoverable_snapshot()
  requireArchive()
  local versionId = versionFor("leftovers")
  seedPreviousSnapshot(versionId)

  -- No canonical archive at all: the backup is the only recoverable snapshot,
  -- and a stray temporary is not valid input.
  local previousBytes = assert(love.filesystem.read(versionId .. "/cache.zip"))
  Assert.isTrue(love.filesystem.remove(versionId .. "/cache.zip"), "the canonical archive moves out of the way")
  Assert.isTrue(
    love.filesystem.write(versionId .. "/cache.zip.bak", previousBytes),
    "the backup holds the previous snapshot"
  )
  Assert.isTrue(love.filesystem.write(versionId .. "/cache.zip.new", "not a zip"), "a stray temporary is present")

  local probe = startWriter({ versionId = versionId })
  local ok, err = pcall(function()
    probe.control:push(newerCut(versionId))
    assert(awaitAck(probe, 5), "the leftover material does not block the new snapshot")
    local operations = drainTrace(probe)
    assertNoWorkerError(operations, "leftover material")
    local promoted = false
    for _, operation in ipairs(operations) do
      local path = type(operation.path) == "string" and operation.path or ""
      local destination = type(operation.destination) == "string" and operation.destination or ""
      if
        operation.op == "rename"
        and path:find("cache.zip.new", 1, true)
        and destination:find("cache.zip", 1, true)
      then
        promoted = true
      elseif operation.op == "remove" and path:find("cache.zip.bak", 1, true) and not promoted then
        Assert.isTrue(false, "the writer must not remove the only recoverable snapshot before a replacement exists")
      end
    end
    local index, members = SnapshotArchive.read(versionId)
    Assert.equal(index.sequence, 5, "the leftover temporary was overwritten by the real capture")
    Assert.equal(members["assets/generated/field/30/atlas.png"], "NEW", "the new snapshot carries the new cut")
    Assert.isNil(
      love.filesystem.getInfo(versionId .. "/cache.zip.new"),
      "the successful write leaves no temporary behind"
    )
  end)
  stopWriter(probe)
  SnapshotArchive.removeTree(versionId)
  if not ok then
    error(err, 0)
  end
end

return { tests = T }
