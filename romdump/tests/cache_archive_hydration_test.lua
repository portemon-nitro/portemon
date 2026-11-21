-- Next-boot input: a snapshot the writer produced hydrates back into the
-- committed payloads and facts of its own cut, a candidate from another
-- generation is refused, and a damaged archive hydrates nothing. The seeded
-- archive comes from the real writer worker, so this exercises the format the
-- writer emits rather than a test-owned encoder.
local Assert = require("tests.support.Assert")
local SnapshotArchive = require("tests.support.SnapshotArchive")

local T = {}

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
local function snapshotCommand(versionId, gen, sequence, flush)
  return {
    op = "snapshot",
    versionId = versionId,
    generationId = gen.generationId,
    epoch = 1,
    sequence = sequence,
    identity = gen,
    entries = {
      blob(gen, "data/generated/field/30/scene.lua", "return { mapId = 30 }\n"),
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

local function writeSnapshot(versionId, gen, sequence)
  local CacheArchive = require("romdump.src.build.CacheArchive")
  local host = love.thread
  local control = assert(host.newChannel())
  local reply = assert(host.newChannel())
  local thread = assert(host.newThread(CacheArchive.bootstrap()))
  thread:start(control, reply, package.path)
  control:push(snapshotCommand(versionId, gen, sequence, false))
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

function T.hydration_round_trips_and_rejects_damage()
  local CacheArchive = require("romdump.src.build.CacheArchive")
  local gen = identity()
  local versionId = "archive-probe-hydrate"
  SnapshotArchive.removeTree(versionId)
  writeSnapshot(versionId, gen, 9)

  local hydration, failure = CacheArchive.open(versionId, gen)
  Assert.isNil(failure, "a valid snapshot hydrates: " .. tostring(failure and failure.message))
  Assert.equal(hydration.sequence, 9, "the hydrated sequence travels")
  Assert.deepEqual(hydration.identity, gen, "the hydrated identity matches")
  Assert.equal(#hydration.entries, 2, "both payloads hydrate")
  Assert.equal(hydration.entries[1].path, "assets/generated/field/30/atlas.png", "entries keep manifest order")
  Assert.equal(hydration.entries[2].data:getString(), "return { mapId = 30 }\n", "the member keeps its bytes")
  Assert.equal(hydration.entries[2].size, 22, "the member reports its size")
  Assert.equal(#hydration.artifacts, 1, "one artifact hydrates")
  Assert.deepEqual(hydration.artifacts[1].files, {
    "assets/generated/field/30/atlas.png",
    "data/generated/field/30/scene.lua",
  }, "the artifact's numeric file references become paths")
  Assert.deepEqual(hydration.milestones, { "bootstrap" }, "milestone facts hydrate")
  Assert.isTrue(hydration.firstPlay, "first play hydrates")
  Assert.isTrue(hydration.complete, "completeness hydrates")

  -- Every hydration in this process mounts its own archive: a repeat of the
  -- same candidate still serves its members instead of an empty mount.
  local again, againFailure = CacheArchive.open(versionId, gen)
  Assert.isNil(againFailure, "a repeated hydration of the same candidate serves it: " .. tostring(againFailure and againFailure.message))
  Assert.equal(#assert(again).entries, 2, "a repeated hydration serves every member")

  local otherGeneration = assert(identity())
  otherGeneration = {
    versionId = otherGeneration.versionId,
    generationId = otherGeneration.generationId .. "-other",
    producerId = otherGeneration.producerId,
    romSha1 = otherGeneration.romSha1,
  }
  local wrong, wrongFailure = CacheArchive.open(versionId, otherGeneration)
  Assert.isNil(wrong, "a snapshot from another generation is refused")
  Assert.notNil(wrongFailure, "the refusal carries a cause")

  local canonical = versionId .. "/cache.zip"
  local bytes = assert(love.filesystem.read(canonical))
  local damaged = bytes:sub(1, -40) .. string.rep("Z", 20) .. bytes:sub(-20)
  assert(love.filesystem.write(canonical, damaged))
  local refused, damageFailure = CacheArchive.open(versionId, gen)
  Assert.isNil(refused, "a damaged snapshot hydrates nothing")
  Assert.notNil(damageFailure, "the refusal carries a typed cause")
  Assert.isTrue(damageFailure.code ~= nil, "the cause is a typed error")

  SnapshotArchive.removeTree(versionId)
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

  local first, firstFailure = CacheArchive.open(versionId, gen)
  Assert.isNil(
    firstFailure,
    "the first hydration serves its archive: " .. tostring(firstFailure and firstFailure.message)
  )
  Assert.equal(#assert(first).entries, 2, "the first hydration serves every member")

  package.loaded["romdump.src.build.CacheArchive"] = nil
  local nextStateArchive = require("romdump.src.build.CacheArchive")
  package.loaded["romdump.src.build.CacheArchive"] = CacheArchive
  Assert.isTrue(nextStateArchive ~= CacheArchive, "the second state owns a distinct module instance")

  local second, secondFailure = nextStateArchive.open(versionId, gen)
  Assert.isNil(
    secondFailure,
    "a second hydration state serves the same archive: " .. tostring(secondFailure and secondFailure.message)
  )
  local hydrated = assert(second)
  Assert.equal(hydrated.sequence, 14, "the second state keeps the sequence")
  Assert.equal(#hydrated.entries, 2, "the second state serves every member")
  Assert.equal(hydrated.entries[2].path, "data/generated/field/30/scene.lua", "the second state keeps manifest order")
  Assert.equal(
    hydrated.entries[2].data:getString(),
    "return { mapId = 30 }\n",
    "the second state keeps the member bytes"
  )

  SnapshotArchive.removeTree(versionId)
end

-- Little-endian ZIP field readers for the structural assertions below.
local function u16(bytes, position)
  local first, second = bytes:byte(position + 1, position + 2)
  return first + second * 256
end
local function u32(bytes, position)
  local a, b, c, d = bytes:byte(position + 1, position + 4)
  return a + b * 256 + c * 65536 + d * 16777216
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
