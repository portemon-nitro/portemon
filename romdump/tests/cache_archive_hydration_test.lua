-- Next-boot input: a snapshot the writer produced hydrates back into the
-- committed payloads and facts of its own cut, a candidate from another
-- generation is refused, and a damaged archive hydrates nothing. The seeded
-- archive comes from the real writer worker, so this exercises the format the
-- writer emits rather than a test-owned encoder. Ordinary hydration reads the
-- compressed archive as native Data, mounts it under a distinct name, and
-- trusts member shape and size without another Lua checksum walk.
local Assert = require("tests.support.Assert")
local LuaWriter = require("libs.codec.src.LuaWriter")
local SnapshotArchive = require("tests.support.SnapshotArchive")
local ZipBuilder = require("tests.support.ZipBuilder")

local T = {}
local INDEX_MEMBER_NAME = "cache-index.lua"

-- Little-endian ZIP field readers for the structural assertions below.
local function u16(bytes, position)
  local first, second = bytes:byte(position + 1, position + 2)
  return first + second * 256
end
local function u32(bytes, position)
  local a, b, c, d = bytes:byte(position + 1, position + 4)
  return a + b * 256 + c * 65536 + d * 16777216
end

local function compressionMethods(bytes)
  local eocd = bytes:find("PK\5\6", math.max(1, #bytes - 65558), true)
  assert(eocd, "the writer emits an end-of-central-directory record")
  local position = u32(bytes, eocd + 15) + 1
  local records = u16(bytes, eocd + 9)
  local methods = {}
  for _ = 1, records do
    Assert.equal(bytes:sub(position, position + 3), "PK\1\2", "the directory contains a central record")
    local nameLength = u16(bytes, position + 27)
    local extraLength = u16(bytes, position + 29)
    local commentLength = u16(bytes, position + 31)
    local name = bytes:sub(position + 46, position + 45 + nameLength)
    methods[name] = u16(bytes, position + 9)
    position = position + 46 + nameLength + extraLength + commentLength
  end
  return methods
end

local function identity()
  local DerivedCacheState = require("romdump.src.DerivedCacheState")
  return assert(DerivedCacheState.currentForSelection({
    versionId = "heartgold",
    romSha1 = string.rep("c", 40),
    producerId = "r3",
  }))
end

local function blob(gen, path, text)
  return {
    path = path,
    data = assert(love.data.newByteData(text)),
    size = #text,
    sourceId = "base:" .. gen.generationId,
    contentId = gen.generationId .. "\0" .. path,
  }
end

-- One captured cut with two payloads sharing an owned root, for both the
-- thread and the in-process flush path.
local function snapshotCommand(versionId, gen, sequence, flush, sceneText)
  return {
    op = "snapshot",
    versionId = versionId,
    generationId = gen.generationId,
    epoch = 1,
    sequence = sequence,
    identity = gen,
    entries = {
      blob(gen, "data/generated/field/30/scene.lua", sceneText or "return { mapId = 30 }\n"),
      blob(gen, "assets/generated/field/30/atlas.png", "PNGDATA"),
    },
    artifacts = {
      {
        kind = "map",
        key = "30",
        marker = "map-ready",
        dependencies = {},
        ownedRoots = { "data/generated/field/30" },
        sharedPaths = { "assets/generated/field/30/atlas.png" },
        files = { "data/generated/field/30/scene.lua", "assets/generated/field/30/atlas.png" },
      },
    },
    milestones = { "bootstrap" },
    firstPlay = true,
    complete = true,
    flush = flush == true,
  }
end

-- A bounded FIFO channel pair, as the in-process explicit flush uses.
local function newQueue()
  local values = {}
  local channel = {}
  function channel:push(value)
    values[#values + 1] = value
    return true
  end
  function channel:pop()
    if #values == 0 then
      return nil
    end
    return table.remove(values, 1)
  end
  function channel:demand()
    return channel:pop()
  end
  function channel:getCount()
    return #values
  end
  return channel
end

local function writeSnapshot(versionId, gen, sequence, sceneText)
  local CacheArchive = require("romdump.src.build.CacheArchive")
  local host = love.thread
  local control = assert(host.newChannel())
  local reply = assert(host.newChannel())
  local thread = assert(host.newThread(CacheArchive.bootstrap()))
  thread:start(control, reply, package.path)
  control:push(snapshotCommand(versionId, gen, sequence, false, sceneText))
  local deadline = love.timer.getTime() + 20
  local packet
  while love.timer.getTime() < deadline do
    packet = reply:pop()
    if packet ~= nil then
      break
    end
    love.timer.sleep(0.005)
  end
  control:push({ op = "stop" })
  for _ = 1, 400 do
    if not thread:isRunning() then
      break
    end
    love.timer.sleep(0.005)
  end
  Assert.equal(packet and packet.op, "snapshot-persisted", "seed snapshot persists")
end

local function releaseIfLive(data)
  if type(data) ~= "userdata" then
    return
  end
  local readable = pcall(function()
    return data:getSize()
  end)
  if readable then
    data:release()
  end
end

local function isReleased(data)
  return type(data) == "userdata" and not pcall(function()
    return data:getSize()
  end)
end

local function releaseHydration(hydration)
  if hydration == nil then
    return
  end
  for _, entry in ipairs(hydration.entries) do
    releaseIfLive(entry.data)
  end
end

-- Observe only the real host boundary used by hydration. Mounts, reads and
-- unmounts still execute in LÖVE; the trace retains their actual Data objects
-- so ownership can be checked after the call.
local function observeOpen(archive, versionId, expectedIdentity, fileName, options)
  options = options or {}
  local fs = love.filesystem
  local Zip32 = require("libs.codec.src.Zip32")
  local realRead, realMount = fs.read, fs.mount
  local realUnmount, realNewFileData = fs.unmount, fs.newFileData
  local realCrc32 = Zip32.crc32
  local trace = {
    archiveReads = {},
    mountedReads = {},
    members = {},
    mounts = {},
    unmounts = {},
    copies = 0,
    crcCalls = 0,
  }
  local liveMounts = {}

  fs.read = function(...)
    local first, second = ...
    local mode, path = first, second
    if path == nil then
      mode, path = nil, first
    end
    if type(path) == "string" and (path == versionId .. "/cache.zip" or path == versionId .. "/cache.zip.bak") then
      if options.failArchiveRead then
        trace.archiveReads[#trace.archiveReads + 1] = { mode = mode, path = path }
        return nil, "injected archive read failure"
      end
      local value, message = realRead(...)
      trace.archiveReads[#trace.archiveReads + 1] = { mode = mode, path = path, value = value }
      return value, message
    end
    if type(path) == "string" then
      local suffix = options.failMemberPath
      if mode == "data" and suffix ~= nil and path:sub(-#suffix) == suffix then
        trace.mountedReads[#trace.mountedReads + 1] = { path = path, acquired = false }
        return nil, "injected member read failure"
      end
      local value, message = realRead(...)
      local mounted = mode == "data"
        or path:sub(-#INDEX_MEMBER_NAME) == INDEX_MEMBER_NAME
        or path:find("/data/generated/", 1, true) ~= nil
        or path:find("/assets/generated/", 1, true) ~= nil
      if mounted then
        trace.mountedReads[#trace.mountedReads + 1] = { path = path, acquired = value ~= nil, mode = mode }
      end
      if mode == "data" and type(value) == "userdata" and path:sub(-#INDEX_MEMBER_NAME) ~= INDEX_MEMBER_NAME then
        trace.members[#trace.members + 1] = value
      end
      return value, message
    end
    return realRead(...)
  end
  fs.newFileData = function(...)
    trace.copies = trace.copies + 1
    return realNewFileData(...)
  end
  fs.mount = function(...)
    local data, archiveName, mountpoint = ...
    local record = {
      data = data,
      archiveName = archiveName,
      mountpoint = mountpoint,
      argumentCount = select("#", ...),
    }
    trace.mounts[#trace.mounts + 1] = record
    if options.failMount then
      return false
    end
    local mounted = realMount(...)
    if mounted then
      liveMounts[#liveMounts + 1] = record
    end
    return mounted
  end
  fs.unmount = function(archiveName)
    for _, mount in ipairs(trace.mounts) do
      local readable, result = pcall(function()
        return mount.data:getSize()
      end)
      mount.readableAtUnmount = readable
      mount.unmountReadResult = tostring(result)
    end
    local unmounted = realUnmount(archiveName)
    trace.unmounts[#trace.unmounts + 1] = { archiveName = archiveName, ok = unmounted == true }
    if unmounted then
      for index = #liveMounts, 1, -1 do
        local mount = liveMounts[index]
        local mountedName = type(mount.mountpoint) == "string" and mount.mountpoint .. ".zip" or mount.archiveName
        if mount.archiveName == archiveName or mountedName == archiveName then
          table.remove(liveMounts, index)
        end
      end
    end
    return unmounted
  end
  Zip32.crc32 = function(...)
    trace.crcCalls = trace.crcCalls + 1
    if options.raiseOnCrc then
      error("ordinary hydration invoked the member CRC walk", 0)
    end
    return realCrc32(...)
  end

  local ok, hydration, failure = pcall(archive.open, versionId, expectedIdentity, fileName)
  fs.read, fs.mount = realRead, realMount
  fs.unmount, fs.newFileData = realUnmount, realNewFileData
  Zip32.crc32 = realCrc32
  -- A deliberately failing spy can interrupt the owner before its normal
  -- cleanup. Finish that host cleanup without hiding what the trace observed.
  if not ok then
    for index = #liveMounts, 1, -1 do
      local mount = liveMounts[index]
      local mountedName = type(mount.mountpoint) == "string" and mount.mountpoint .. ".zip" or mount.archiveName
      pcall(realUnmount, mountedName)
      releaseIfLive(mount.data)
    end
    for _, read in ipairs(trace.archiveReads) do
      releaseIfLive(read.value)
    end
  end
  return {
    ok = ok,
    hydration = ok and hydration or nil,
    failure = ok and failure or nil,
    raised = not ok and tostring(hydration) or nil,
    trace = trace,
  }
end

local function nativeHydrationProblems(trace, expectedMemberCount)
  local problems = {}
  if #trace.archiveReads ~= 1 then
    problems[#problems + 1] = string.format("expected one compressed archive read, observed %d", #trace.archiveReads)
  else
    local read = trace.archiveReads[1]
    if read.mode ~= "data" then
      problems[#problems + 1] = "compressed archive read did not request Data"
    end
    local dataTypeOk, dataType = false, nil
    if type(read.value) == "userdata" then
      dataTypeOk, dataType = pcall(read.value.type, read.value)
    end
    if not dataTypeOk or dataType ~= "FileData" then
      problems[#problems + 1] = "compressed archive read did not return FileData"
    end
  end
  if trace.copies ~= 0 then
    problems[#problems + 1] = string.format("warm hydration copied the archive %d time(s)", trace.copies)
  end
  if #trace.mounts ~= 1 then
    problems[#problems + 1] = string.format("expected one native mount, observed %d", #trace.mounts)
  else
    local mount = trace.mounts[1]
    if mount.argumentCount ~= 3 then
      problems[#problems + 1] = "archive was not mounted through the named Data overload"
    end
    if type(mount.mountpoint) ~= "string" or mount.archiveName ~= mount.mountpoint .. ".zip" then
      problems[#problems + 1] = "mounted archive name does not extend its private namespace"
    end
    local read = trace.archiveReads[1]
    if read == nil or mount.data ~= read.value then
      problems[#problems + 1] = "mount did not retain the Data returned by the compressed read"
    end
    if mount.readableAtUnmount ~= true then
      problems[#problems + 1] = "compressed Data was not readable until unmount: " .. tostring(mount.unmountReadResult)
    end
    if type(mount.data) == "userdata" and not isReleased(mount.data) then
      problems[#problems + 1] = "compressed Data stayed live after unmount"
    end
  end
  if #trace.mountedReads ~= expectedMemberCount + 1 then
    problems[#problems + 1] = string.format(
      "expected one manifest read and %d member reads, observed %d reads",
      expectedMemberCount,
      #trace.mountedReads
    )
  end
  local seen = {}
  local declaredReads = 0
  local manifestReads = 0
  for _, read in ipairs(trace.mountedReads) do
    if seen[read.path] then
      problems[#problems + 1] = "a mounted member was read more than once: " .. read.path
    end
    seen[read.path] = true
    if read.path:sub(-#INDEX_MEMBER_NAME) == INDEX_MEMBER_NAME then
      manifestReads = manifestReads + 1
    else
      declaredReads = declaredReads + 1
      if read.mode ~= "data" then
        problems[#problems + 1] = "a declared member was not read directly as Data: " .. read.path
      end
    end
  end
  if manifestReads ~= 1 or declaredReads ~= expectedMemberCount then
    problems[#problems + 1] = string.format(
      "expected one manifest read and %d declared member reads, observed %d and %d",
      expectedMemberCount,
      manifestReads,
      declaredReads
    )
  end
  if #trace.unmounts ~= 1 or trace.unmounts[1].ok ~= true then
    problems[#problems + 1] = "the native archive mount was not released exactly once"
  elseif #trace.mounts == 1 and trace.unmounts[1].archiveName ~= trace.mounts[1].archiveName then
    problems[#problems + 1] = "unmount did not use the mounted archive name"
  end
  if trace.crcCalls ~= 0 then
    problems[#problems + 1] = string.format("warm hydration performed %d Lua CRC call(s)", trace.crcCalls)
  end
  return problems
end

local function finishObservation(observation)
  releaseHydration(observation.hydration)
  for _, member in ipairs(observation.trace.members) do
    releaseIfLive(member)
  end
  for _, read in ipairs(observation.trace.archiveReads) do
    releaseIfLive(read.value)
  end
  for _, mount in ipairs(observation.trace.mounts) do
    releaseIfLive(mount.data)
  end
end

-- Prove the pinned host's named Data mount independently of the production
-- reader: the same compressed FileData serves stored and deflated members and
-- stays alive until its archive name is unmounted.
function T.native_data_mount_round_trips_the_writer_archive()
  local gen = identity()
  local versionId = "archive-probe-native-data"
  local namespace = "archive-probe-native-data-mount"
  local sceneText = string.rep("return { mapId = 30 }\n", 64)
  SnapshotArchive.removeTree(versionId)
  Assert.isNil(love.filesystem.getInfo(namespace), "the native mount namespace starts unowned")
  writeSnapshot(versionId, gen, 17, sceneText)

  local compressed = assert(love.filesystem.read("data", versionId .. "/cache.zip"), "native archive read returns Data")
  Assert.equal(compressed:type(), "FileData", "the compressed input is native FileData")
  local archiveName = namespace .. ".zip"
  Assert.isTrue(
    love.filesystem.mount(compressed, archiveName, namespace),
    "named FileData mount succeeds on the pinned host"
  )
  local members = {}
  local ok, failure = pcall(function()
    local indexText = assert(love.filesystem.read(namespace .. "/cache-index.lua"), "the mounted manifest is readable")
    local index = SnapshotArchive.parseIndex(indexText)
    for _, entry in ipairs(index.entries) do
      local member = assert(
        love.filesystem.read("data", namespace .. "/" .. entry.path),
        "the mounted member reads directly as Data: " .. entry.path
      )
      Assert.equal(member:type(), "FileData", "the mounted member is FileData: " .. entry.path)
      members[#members + 1] = { data = member, bytes = member:getString(), size = member:getSize() }
    end
  end)
  local unmounted = love.filesystem.unmount(archiveName)
  for _, member in ipairs(members) do
    member.data:release()
  end
  Assert.isTrue(ok, "the native mount serves the writer archive: " .. tostring(failure))
  Assert.isTrue(unmounted, "the named native mount releases by archive name")
  compressed:release()
  Assert.isNil(love.filesystem.getInfo(namespace), "the native namespace is gone after unmount")
  Assert.equal(#members, 2, "the native mount serves both writer members")
  Assert.equal(members[1].bytes, "PNGDATA", "the stored member keeps its bytes")
  Assert.equal(members[2].bytes, sceneText, "the deflated member keeps its bytes")
  Assert.equal(members[2].size, #sceneText, "the deflated member reports its expanded size")
  SnapshotArchive.removeTree(versionId)
end

function T.hydration_round_trips_and_rejects_damage()
  local CacheArchive = require("romdump.src.build.CacheArchive")
  local gen = identity()
  local versionId = "archive-probe-hydrate"
  local sceneText = string.rep("return { mapId = 30, label = 'compressible-scene' }\n", 64)
  SnapshotArchive.removeTree(versionId)
  writeSnapshot(versionId, gen, 9, sceneText)

  local _, _, archiveBytes = SnapshotArchive.read(versionId)
  local methods = compressionMethods(assert(archiveBytes))
  Assert.equal(methods["assets/generated/field/30/atlas.png"], 0, "the PNG fixture exercises a stored member")
  Assert.equal(methods["data/generated/field/30/scene.lua"], 8, "the repeated Lua fixture exercises a deflated member")

  local function openAndCheck(label, expectedSequence, expectedScene, fileName)
    local observation = observeOpen(CacheArchive, versionId, gen, fileName)
    local hydration = observation.hydration
    local sceneBytes, sceneSize
    if hydration ~= nil then
      sceneBytes = hydration.entries[2].data:getString()
      sceneSize = hydration.entries[2].size
    end
    local problems = nativeHydrationProblems(observation.trace, 2)
    finishObservation(observation)
    Assert.isTrue(observation.ok, label .. " resolves through the real host: " .. tostring(observation.raised))
    Assert.isNil(
      observation.failure,
      label .. " hydrates: " .. tostring(observation.failure and observation.failure.message)
    )
    Assert.isTrue(#problems == 0, label .. ": " .. table.concat(problems, "; "))
    local hydrated = assert(hydration)
    Assert.equal(hydrated.sequence, expectedSequence, label .. " carries its captured sequence")
    Assert.deepEqual(hydrated.identity, gen, label .. " keeps the exact identity")
    Assert.equal(#hydrated.entries, 2, label .. " hydrates both payloads")
    Assert.equal(hydrated.entries[1].path, "assets/generated/field/30/atlas.png", label .. " keeps manifest order")
    Assert.equal(sceneBytes, expectedScene, label .. " keeps the member bytes")
    Assert.equal(sceneSize, #expectedScene, label .. " reports the member size")
    Assert.equal(#hydrated.artifacts, 1, label .. " hydrates one artifact")
    Assert.deepEqual(hydrated.artifacts[1].files, {
      "assets/generated/field/30/atlas.png",
      "data/generated/field/30/scene.lua",
    }, label .. " turns numeric file references into paths")
    Assert.deepEqual(hydrated.milestones, { "bootstrap" }, label .. " hydrates milestone facts")
    Assert.isTrue(hydrated.firstPlay, label .. " hydrates first play")
    Assert.isTrue(hydrated.complete, label .. " hydrates completeness")
    return hydrated, observation
  end

  local _, first = openAndCheck("canonical hydration", 9, sceneText)
  local _, repeated = openAndCheck("repeated hydration", 9, sceneText)
  Assert.isTrue(
    first.trace.mounts[1].mountpoint ~= repeated.trace.mounts[1].mountpoint,
    "repeated opens of one path use distinct native namespaces"
  )

  local newerScene = string.rep("return { mapId = 31, label = 'newer-cut' }\n", 64)
  writeSnapshot(versionId, gen, 10, newerScene)
  openAndCheck("replacement hydration", 10, newerScene)

  local otherGeneration = assert(identity())
  otherGeneration = {
    versionId = otherGeneration.versionId,
    generationId = otherGeneration.generationId .. "-other",
    producerId = otherGeneration.producerId,
    romSha1 = otherGeneration.romSha1,
  }
  local wrong, wrongFailure = CacheArchive.open(versionId, otherGeneration)
  Assert.isNil(wrong, "a snapshot from another generation is refused")
  Assert.equal(wrongFailure.code, "CACHE_ARCHIVE_SCHEMA_INVALID", "the generation refusal is typed")

  local canonical = versionId .. "/cache.zip"
  local bytes = assert(love.filesystem.read(canonical))
  Assert.isTrue(love.filesystem.remove(canonical), "the canonical archive moves aside")
  Assert.isTrue(love.filesystem.write(versionId .. "/cache.zip.bak", bytes), "the backup keeps the current cut")
  Assert.isTrue(love.filesystem.write(versionId .. "/cache.zip.new", "not a zip"), "an orphan temporary is present")
  local _, backup = openAndCheck("backup hydration", 10, newerScene)
  Assert.isTrue(
    backup.trace.archiveReads[1].path == versionId .. "/cache.zip.bak",
    "the recoverable open reads the backup rather than the orphan temporary"
  )
  Assert.isTrue(
    backup.trace.mounts[1].archiveName:sub(-4) == ".zip",
    "a backup still mounts under a native zip archive name"
  )

  Assert.isTrue(love.filesystem.write(canonical, bytes), "the damaged candidate is restored to the canonical path")
  local damaged = bytes:sub(1, -40) .. string.rep("Z", 20) .. bytes:sub(-20)
  assert(love.filesystem.write(canonical, damaged))
  local refused, damageFailure = CacheArchive.open(versionId, gen)
  Assert.isNil(refused, "a damaged snapshot hydrates nothing")
  Assert.equal(damageFailure.code, "CACHE_ARCHIVE_UNREADABLE", "the damage refusal is typed")

  SnapshotArchive.removeTree(versionId)
end

function T.warm_hydration_never_invokes_the_member_crc_spy()
  local CacheArchive = require("romdump.src.build.CacheArchive")
  local gen = identity()
  local versionId = "archive-probe-no-crc"
  SnapshotArchive.removeTree(versionId)
  writeSnapshot(versionId, gen, 15)
  local observation = observeOpen(CacheArchive, versionId, gen, nil, { raiseOnCrc = true })
  local crcCalls = observation.trace.crcCalls
  finishObservation(observation)
  Assert.isTrue(
    observation.ok,
    "ordinary hydration must not invoke the member CRC spy; observed "
      .. tostring(crcCalls)
      .. " call(s): "
      .. tostring(observation.raised)
  )
  Assert.equal(crcCalls, 0, "a valid warm read performs no Lua CRC traversal")
  Assert.isNil(observation.failure, "the CRC-free warm read returns its hydration")
  SnapshotArchive.removeTree(versionId)
end

-- A rejection after earlier members were acquired must release those members,
-- including a member whose own size check fails. A failed mount owns only its
-- input Data. Each case runs through the real mount/read owner with one host
-- boundary failure injected.
function T.failed_hydration_releases_every_acquired_buffer()
  local CacheArchive = require("romdump.src.build.CacheArchive")
  local gen = identity()
  local versionId = "archive-probe-failed-reads"
  local scenePath = "data/generated/field/30/scene.lua"
  SnapshotArchive.removeTree(versionId)
  writeSnapshot(versionId, gen, 16)
  local canonical = versionId .. "/cache.zip"
  local goodBytes = assert(love.filesystem.read(canonical))
  local parsed, members = SnapshotArchive.read(versionId)
  assert(parsed, "the saved snapshot is readable before the failure injection")
  for _, entry in ipairs(parsed.entries) do
    if entry.path == scenePath then
      entry.uncompressedSize = entry.uncompressedSize + 1
    end
  end
  local files = { { name = "cache-index.lua", data = assert(LuaWriter.encode(parsed)) } }
  for _, entry in ipairs(parsed.entries) do
    files[#files + 1] = { name = entry.path, data = assert(members[entry.path]) }
  end
  local wrongSizeBytes = ZipBuilder.build(files)
  local otherGeneration = assert(identity())
  otherGeneration = {
    versionId = otherGeneration.versionId,
    generationId = otherGeneration.generationId .. "-other",
    producerId = otherGeneration.producerId,
    romSha1 = otherGeneration.romSha1,
  }

  local problems = {}
  for _, case in ipairs({
    { name = "member read", options = { failMemberPath = scenePath }, bytes = goodBytes, unmounts = 1 },
    { name = "member size", options = {}, bytes = wrongSizeBytes, unmounts = 1 },
    {
      name = "generation",
      identity = otherGeneration,
      options = {},
      bytes = goodBytes,
      unmounts = 1,
      code = "CACHE_ARCHIVE_SCHEMA_INVALID",
    },
    { name = "mount", options = { failMount = true }, bytes = goodBytes, unmounts = 0 },
    { name = "archive read", options = { failArchiveRead = true }, bytes = goodBytes, unmounts = 0 },
  }) do
    assert(love.filesystem.write(canonical, case.bytes))
    local observation = observeOpen(CacheArchive, versionId, case.identity or gen, nil, case.options)
    if not observation.ok then
      problems[#problems + 1] = case.name
        .. " raised instead of returning a typed failure: "
        .. tostring(observation.raised)
    elseif observation.hydration ~= nil then
      problems[#problems + 1] = case.name .. " published a partial hydration"
    elseif
      type(observation.failure) ~= "table"
      or observation.failure.code ~= (case.code or "CACHE_ARCHIVE_UNREADABLE")
    then
      problems[#problems + 1] = case.name .. " did not return its expected typed failure"
    end
    if #observation.trace.unmounts ~= case.unmounts then
      problems[#problems + 1] = case.name .. " released an unexpected number of mounts"
    end
    for position, member in ipairs(observation.trace.members) do
      if not isReleased(member) then
        problems[#problems + 1] = string.format("%s left acquired member %d live", case.name, position)
      end
    end
    for _, mount in ipairs(observation.trace.mounts) do
      if not isReleased(mount.data) then
        problems[#problems + 1] = case.name .. " left its compressed input live"
      end
    end
    finishObservation(observation)
  end
  SnapshotArchive.removeTree(versionId)
  Assert.isTrue(#problems == 0, table.concat(problems, "; "))
end

-- The explicit flush runs the same writer loop over in-process channels: the
-- cut it wrote is closed and hydrates back exactly, which is what a CLI report
-- of success promises to the next process.
function T.in_process_flush_persists_one_hydratable_cut()
  local CacheArchive = require("romdump.src.build.CacheArchive")
  local gen = identity()
  local versionId = "archive-probe-flush"
  SnapshotArchive.removeTree(versionId)
  local control = newQueue()
  local reply = newQueue()
  control:push(snapshotCommand(versionId, gen, 12, true))
  control:push({ op = "stop" })
  CacheArchive.run(control, reply)
  local packet = reply:pop()
  Assert.equal(packet and packet.op, "snapshot-persisted", "the flushed cut persists")
  Assert.equal(packet.sequence, 12, "the acknowledgement names the flushed sequence")
  -- The next process reads the archive it finds on disk, so the assertion is
  -- made on those bytes rather than through this process's directory view.
  local index, members, bytes = SnapshotArchive.read(versionId)
  Assert.notNil(index, "the flushed snapshot is a readable archive")
  Assert.isTrue(#assert(bytes) > 0, "the flushed archive carries bytes")
  Assert.equal(index.sequence, 12, "the flushed sequence travels")
  Assert.equal(index.identity.generationId, gen.generationId, "the flushed cut names its generation")
  Assert.isTrue(index.complete, "the flushed cut keeps its completion fact")
  Assert.deepEqual(SnapshotArchive.memberPaths(index), {
    "assets/generated/field/30/atlas.png",
    "data/generated/field/30/scene.lua",
  }, "both payloads persist as members")
  Assert.equal(members["data/generated/field/30/scene.lua"], "return { mapId = 30 }\n", "a member keeps its bytes")
  SnapshotArchive.removeTree(versionId)
end

-- Every Lua state in one process loads its own copy of the snapshot module:
-- the controller thread hydrates after the game thread already did, so a
-- hydration must never depend on the mounts an earlier state left behind. The
-- module is reloaded here to take a second state's view of the same archive.
function T.a_second_hydration_state_serves_the_same_archive()
  local CacheArchive = require("romdump.src.build.CacheArchive")
  local gen = identity()
  local versionId = "archive-probe-second-state"
  SnapshotArchive.removeTree(versionId)
  writeSnapshot(versionId, gen, 14)

  local first = observeOpen(CacheArchive, versionId, gen)
  local firstCount = first.hydration and #first.hydration.entries or 0
  local firstProblems = nativeHydrationProblems(first.trace, 2)
  finishObservation(first)
  Assert.isTrue(first.ok, "the first hydration resolves: " .. tostring(first.raised))
  Assert.isNil(
    first.failure,
    "the first hydration serves its archive: " .. tostring(first.failure and first.failure.message)
  )
  Assert.equal(firstCount, 2, "the first hydration serves every member")
  Assert.isTrue(#firstProblems == 0, "first state: " .. table.concat(firstProblems, "; "))

  package.loaded["romdump.src.build.CacheArchive"] = nil
  local nextStateArchive = require("romdump.src.build.CacheArchive")
  package.loaded["romdump.src.build.CacheArchive"] = CacheArchive
  Assert.isTrue(nextStateArchive ~= CacheArchive, "the second state owns a distinct module instance")

  local second = observeOpen(nextStateArchive, versionId, gen)
  local hydrated = second.hydration
  local sequence = hydrated and hydrated.sequence
  local count = hydrated and #hydrated.entries or 0
  local path = hydrated and hydrated.entries[2].path
  local bytes = hydrated and hydrated.entries[2].data:getString()
  local secondProblems = nativeHydrationProblems(second.trace, 2)
  finishObservation(second)
  Assert.isTrue(second.ok, "the second hydration resolves: " .. tostring(second.raised))
  Assert.isNil(
    second.failure,
    "a second hydration state serves the same archive: " .. tostring(second.failure and second.failure.message)
  )
  Assert.isTrue(#secondProblems == 0, "second state: " .. table.concat(secondProblems, "; "))
  Assert.isTrue(
    first.trace.mounts[1].mountpoint ~= second.trace.mounts[1].mountpoint,
    "independent Lua states cannot alias a native mount namespace"
  )
  Assert.equal(sequence, 14, "the second state keeps the sequence")
  Assert.equal(count, 2, "the second state serves every member")
  Assert.equal(path, "data/generated/field/30/scene.lua", "the second state keeps manifest order")
  Assert.equal(bytes, "return { mapId = 30 }\n", "the second state keeps the member bytes")

  SnapshotArchive.removeTree(versionId)
end

-- The writer streams payloads in bounded pacing chunks. An entry larger than
-- one chunk must still be written exactly once: the emitted archive declares
-- its real central-directory offset and hydrates back to the same bytes.
function T.a_payload_larger_than_one_pacing_chunk_round_trips()
  local CacheArchive = require("romdump.src.build.CacheArchive")
  local gen = identity()
  local versionId = "archive-probe-large-entry"
  SnapshotArchive.removeTree(versionId)
  -- The writer paces at 256 KiB and stores PNG entries verbatim: an
  -- incompressible 600 KiB image spans several pacing chunks.
  local largePath = "assets/generated/field/31/atlas.png"
  local chunks = {}
  local seed = 12345
  for index = 1, 600000 do
    seed = (seed * 1103515245 + 12345) % 2147483648
    chunks[index] = string.char(seed % 256)
  end
  local largeBytes = table.concat(chunks)
  Assert.isTrue(#largeBytes > 2 * 262144, "the fixture payload spans several pacing chunks")
  local command = snapshotCommand(versionId, gen, 21, true)
  command.entries = {
    blob(gen, "assets/generated/field/30/atlas.png", "PNGDATA"),
    blob(gen, largePath, largeBytes),
  }
  command.artifacts[1].files = { "assets/generated/field/30/atlas.png", largePath }
  local control = newQueue()
  local reply = newQueue()
  control:push(command)
  control:push({ op = "stop" })
  CacheArchive.run(control, reply)
  Assert.equal(reply:pop().op, "snapshot-persisted", "the large cut persists")

  local index, members, bytes = SnapshotArchive.read(versionId)
  Assert.notNil(index, "the large snapshot is a readable archive")
  bytes = assert(bytes)
  Assert.equal(members[largePath], largeBytes, "the large member keeps every byte")
  local declared
  for _, entry in ipairs(index.entries) do
    if entry.path == largePath then
      declared = entry
    end
  end
  Assert.notNil(declared, "the manifest declares the large member")
  Assert.equal(declared.uncompressedSize, #largeBytes, "the declared size counts the payload once")

  -- The end-of-central-directory record must name the real directory start:
  -- a writer that repeats a chunked payload records an offset behind it.
  local eocd = bytes:find("PK\5\6", math.max(1, #bytes - 65558), true)
  Assert.notNil(eocd, "the archive carries its end-of-central-directory record")
  local directoryOffset = u32(bytes, eocd + 15)
  local directorySize = u32(bytes, eocd + 11)
  Assert.equal(
    bytes:sub(directoryOffset + 1, directoryOffset + 4),
    "PK\1\2",
    "the recorded directory offset names a real central-directory record"
  )
  local position = directoryOffset + 1
  local records = 0
  while bytes:sub(position, position + 3) == "PK\1\2" do
    local nameLength = u16(bytes, position + 27)
    local extraLength = u16(bytes, position + 29)
    local commentLength = u16(bytes, position + 31)
    records = records + 1
    position = position + 46 + nameLength + extraLength + commentLength
  end
  Assert.equal(records, #index.entries + 1, "every payload and the manifest own one directory record")
  Assert.equal(position, directoryOffset + directorySize + 1, "the directory size covers exactly those records")

  local hydration, failure = CacheArchive.open(versionId, gen)
  Assert.isNil(failure, "the large snapshot hydrates: " .. tostring(failure and failure.message))
  local hydrated = assert(hydration)
  local restored = nil
  for _, entry in ipairs(hydrated.entries) do
    if entry.path == largePath then
      restored = entry
    end
  end
  Assert.notNil(restored, "the large member hydrates")
  Assert.equal(restored.size, #largeBytes, "the hydrated member reports its full size")
  Assert.equal(restored.data:getString(), largeBytes, "the hydrated member keeps every byte")
  SnapshotArchive.removeTree(versionId)
end

return { tests = T }
