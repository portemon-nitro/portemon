-- Test helper: save one consistent cut with the production archive writer and
-- read the resulting snapshot back the way the next boot would. The suites that
-- own next-boot behavior share this helper so the snapshot they save and the
-- bytes they hydrate are the production ones, not a reimplementation.
--
-- The archive owner's snapshot command and its boot reader are internal to the
-- producing pair of modules, so this helper fixes the boot side: `open(root,
-- identity)` takes the generated-cache root (normally the selected version
-- directory) plus the selected generation identity and answers either the
-- fully hydrated candidate or nil plus a typed {code, message} cause. A
-- candidate whose manifest identity differs from the caller's is not a
-- candidate, and a rejected read never exposes a partial one.
--
-- A candidate carries the fields the cache index declares plus resident
-- payload references: sequence, identity, complete, firstPlay, milestones,
-- artifacts, and one immutable reference per member with path, size, Data,
-- sourceId and contentId. Readers that accept either a path-keyed map or a
-- sorted array of those references are normalized here so a suite asserts the
-- served bytes, not the container the owner chose.

local Assert = require("tests.support.Assert")

local SnapshotBootFixture = {}

-- Test-owned writer entry: the production archive worker runs unchanged in its
-- own Lua state; only the development search path has to cross the boundary.
local WRITER_THREAD = [[
local control, reply, settings = ...
if type(settings.packagePath) == "string" and settings.packagePath ~= "" then
  package.path = settings.packagePath
end
pcall(require, "love.filesystem")
pcall(require, "love.data")
pcall(require, "love.timer")
local ok, failure = xpcall(function()
  local CacheArchive = require("romdump.src.build.CacheArchive")
  CacheArchive.run(control, reply)
end, debug.traceback)
if not ok then
  reply:push({ op = "worker-error", message = tostring(failure) })
end
]]

local activeProbes = {}

---@param text string
---@return string first meaningful line of a failure text
local function firstLine(text)
  return (tostring(text):match("[^\n]+") or tostring(text))
end

local function archiveModule()
  local ok, archive = pcall(require, "romdump.src.build.CacheArchive")
  Assert.isTrue(
    ok and archive ~= nil and type(archive.open) == "function" and type(archive.run) == "function",
    "no resident generated-cache owner exists to save and hydrate a saved snapshot: " .. firstLine(archive)
  )
  return archive --[[@as table]]
end

-- The identity a snapshot of the selected generation carries: the controller
-- derives it from the selected version, so a scenario that installs a
-- snapshot into a live selection has to carry that same identity.
---@param versionId string? selected version id, heartgold by default
---@return table<string, unknown> the identity a snapshot of this generation carries
function SnapshotBootFixture.identity(versionId)
  local selected = versionId or "heartgold"
  local DerivedCacheState = require("romdump.src.DerivedCacheState")
  local DerivedCacheVersions = require("romdump.src.config.DerivedCacheVersions")
  local GameVersion = require("romdump.src.source.GameVersion")
  return assert(DerivedCacheState.currentForSelection({
    versionId = selected,
    romSha1 = GameVersion.info(selected).sha1,
    producerId = "r" .. tostring(DerivedCacheVersions[selected]),
  }))
end

---@param identity table<string, unknown>
---@param path string logical generated path
---@param text string member bytes
---@return table<string, unknown> immutable payload reference for one cut member
function SnapshotBootFixture.blob(identity, path, text)
  local generationId = assert(identity.generationId, "the fixture identity carries its generation")
  return {
    path = path,
    data = assert(love.data.newByteData(text), "a cut needs real Data buffers"),
    size = #text,
    sourceId = "base:" .. generationId,
    contentId = generationId .. "\0" .. path,
  }
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

---@param root string generated-cache root the archive is saved under
---@return table<string, unknown> writer probe with its channels and thread
function SnapshotBootFixture.startWriter(root)
  archiveModule()
  local host = assert(love.thread, "saving a snapshot needs real thread channels")
  local probe = {
    root = root,
    control = host.newChannel(),
    reply = host.newChannel(),
  }
  probe.thread = assert(host.newThread(WRITER_THREAD))
  local started, startError = pcall(function()
    probe.thread:start(probe.control, probe.reply, { packagePath = package.path })
  end)
  Assert.isTrue(started, "the snapshot writer Lua state starts: " .. tostring(startError))
  activeProbes[#activeProbes + 1] = probe
  return probe
end

---@param probe table<string, unknown>
function SnapshotBootFixture.stopWriter(probe)
  pcall(function()
    probe.control:push({ op = "stop", versionId = probe.root })
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
  for index, active in ipairs(activeProbes) do
    if active == probe then
      table.remove(activeProbes, index)
      break
    end
  end
end

-- Release every writer this helper started, whatever a scenario did to its
-- own state, so no Lua state can park the run.
function SnapshotBootFixture.releaseWriters()
  for _, probe in ipairs(activeProbes) do
    SnapshotBootFixture.stopWriter(probe)
  end
  activeProbes = {}
end

---@param probe table<string, unknown>
---@return table<string, unknown> the writer's acknowledgement of the cut
function SnapshotBootFixture.awaitAck(probe)
  local deadline = love.timer.getTime() + 40
  while love.timer.getTime() < deadline do
    local packet = awaitValue(probe.reply, 5)
    if packet == nil then
      break
    end
    if packet.op == "snapshot-persisted" or packet.op == "snapshot-failed" then
      return packet
    end
    Assert.isTrue(
      packet.op ~= "worker-error",
      "the snapshot writer reports through its acknowledgement: " .. firstLine(packet.message)
    )
  end
  Assert.isTrue(false, "the snapshot writer never acknowledged the cut it was handed")
  return {}
end

---@param root string generated-cache root to save the cut under
---@param cut table<string, unknown> one already consistent cut
---@return table<string, unknown> the persisted acknowledgement
function SnapshotBootFixture.save(root, cut)
  local probe = SnapshotBootFixture.startWriter(root)
  local ok, result = pcall(function()
    cut.op = "snapshot"
    cut.versionId = root
    probe.control:push(cut)
    local ack = SnapshotBootFixture.awaitAck(probe)
    Assert.equal(ack.op, "snapshot-persisted", "the fixture snapshot persists before a boot reads it")
    Assert.equal(ack.sequence, cut.sequence, "the fixture snapshot persists its captured sequence")
    -- The writer promotes its output with a rename, so the reading process
    -- has to touch the directory before it lists the new canonical name.
    love.filesystem.getInfo(root .. "/cache.zip")
    return ack
  end)
  SnapshotBootFixture.stopWriter(probe)
  if not ok then
    SnapshotBootFixture.removeRoot(root)
    error(result, 0)
  end
  return result
end

---@param root string
function SnapshotBootFixture.removeRoot(root)
  require("tests.support.SnapshotArchive").removeTree(root)
end

---@param root string generated-cache root
---@param identity table<string, unknown> selected generation identity
---@return table<string, unknown>? candidate the hydrated snapshot
---@return table<string, unknown>? failure typed rejection cause
function SnapshotBootFixture.open(root, identity)
  local archive = archiveModule()
  local ok, candidate, failure = pcall(archive.open, root, identity)
  Assert.isTrue(ok, "reading a saved snapshot must not raise: " .. tostring(candidate))
  return candidate, failure
end

---@param value unknown
---@return boolean whether the value looks like one resident payload reference
local function isReference(value)
  return type(value) == "table" and type(value.path) == "string" and value.data ~= nil
end

-- Resident payload references of one candidate, with the installation
-- identity every committed entry carries: a hydrated reference knows its
-- bytes and path, and the install packet that carries it mints the source and
-- content identity exactly like the controller does.
---@param candidate table<string, unknown>
---@return table<string, unknown>[] sorted resident payload references
function SnapshotBootFixture.entries(candidate)
  local listed = candidate.entries or {}
  local identity = type(candidate.identity) == "table" and candidate.identity or nil
  local generationId = identity ~= nil and identity.generationId or candidate.generationId
  local references = {}
  for key, value in pairs(listed) do
    local reference
    if isReference(value) then
      reference = value
    elseif type(key) == "string" then
      reference = { path = key, data = value }
    end
    if reference ~= nil then
      if reference.sourceId == nil and type(generationId) == "string" then
        reference.sourceId = "base:" .. generationId
      end
      if reference.contentId == nil and type(generationId) == "string" then
        reference.contentId = generationId .. "\0" .. reference.path
      end
      references[#references + 1] = reference
    end
  end
  table.sort(references, function(left, right)
    return left.path < right.path
  end)
  return references
end

---@param candidate table<string, unknown>
---@return table<string, table<string, unknown>> artifact facts by canonical job key
function SnapshotBootFixture.artifacts(candidate)
  local listed = candidate.artifacts or {}
  local byKey = {}
  for _, artifact in pairs(listed) do
    if type(artifact) == "table" and type(artifact.kind) == "string" and artifact.key ~= nil then
      byKey[artifact.kind .. ":" .. tostring(artifact.key)] = artifact
    end
  end
  return byKey
end

---@param candidate table<string, unknown>
---@return table<string, string> served member bytes by logical path
function SnapshotBootFixture.bytes(candidate)
  local served = {}
  for _, reference in ipairs(SnapshotBootFixture.entries(candidate)) do
    served[reference.path] = assert(reference.data:getString(), "a resident payload is readable: " .. reference.path)
  end
  return served
end

local mounts = 0

-- One installation sequence as the controller publishes it: a private begin,
-- bounded entry parts, then the commit that carries only the small semantic
-- completion facts. A boot installation is the initial one for its epoch.
---@param service table<string, unknown> cache service under boot
---@param installation { epoch: integer, identity: table<string, unknown>, sequence: integer, initial: boolean?, entries: table[], milestones: table[]?, firstPlay: boolean?, complete: boolean? }
function SnapshotBootFixture.install(service, installation)
  local entries = installation.entries or {}
  service:injectReply({
    op = "cache-install-begin",
    epoch = installation.epoch,
    generationId = installation.identity.generationId,
    sequence = installation.sequence,
    initial = installation.initial == true,
    identity = installation.identity,
    entryCount = #entries,
  })
  local part, index = 1, 1
  while index <= #entries do
    local slice = {}
    for position = index, math.min(index + 127, #entries) do
      slice[#slice + 1] = entries[position]
    end
    service:injectReply({
      op = "cache-install-entries",
      epoch = installation.epoch,
      generationId = installation.identity.generationId,
      sequence = installation.sequence,
      part = part,
      entries = slice,
    })
    index = index + #slice
    part = part + 1
  end
  service:injectReply({
    op = "cache-install-commit",
    epoch = installation.epoch,
    generationId = installation.identity.generationId,
    sequence = installation.sequence,
    milestones = installation.milestones or {},
    firstPlay = installation.firstPlay == true,
    complete = installation.complete == true,
  })
end

-- The initial installation a real selection streams before it emits any
-- terminal observation: one empty sequence for the epoch, carrying whatever
-- completion facts a scenario scripts.
---@param service table<string, unknown> cache service under test
---@param epoch integer selected epoch
---@param facts { versionId: string?, identity: table<string, unknown>?, milestones: table[]?, firstPlay: boolean?, complete: boolean? }?
function SnapshotBootFixture.installBoot(service, epoch, facts)
  facts = facts or {}
  SnapshotBootFixture.install(service, {
    epoch = epoch,
    identity = facts.identity or SnapshotBootFixture.identity(facts.versionId),
    sequence = 1,
    initial = true,
    entries = {},
    milestones = facts.milestones,
    firstPlay = facts.firstPlay,
    complete = facts.complete,
  })
end

---@param root string generated-cache root
---@return string? archiveBytes the canonical snapshot bytes
---@return string? indexText the raw manifest member text
function SnapshotBootFixture.canonical(root)
  local path = root .. "/cache.zip"
  if love.filesystem.getInfo(path) == nil then
    return nil, nil
  end
  local bytes = assert(love.filesystem.read(path), "the canonical snapshot must be readable")
  mounts = mounts + 1
  local mountedAs = "boot-fixture-" .. tostring(mounts)
  local fileData = assert(love.filesystem.newFileData(bytes, "boot-fixture-" .. tostring(mounts) .. ".zip"))
  Assert.isTrue(love.filesystem.mount(fileData, mountedAs), "the saved snapshot must be a mountable zip")
  local indexText = love.filesystem.read(mountedAs .. "/cache-index.lua")
  love.filesystem.unmount(mountedAs)
  return bytes, indexText
end

---@param root string generated-cache root
---@param bytes string archive bytes to install as the canonical snapshot
function SnapshotBootFixture.writeCanonical(root, bytes)
  love.filesystem.createDirectory(root)
  Assert.isTrue(love.filesystem.write(root .. "/cache.zip", bytes), "the scenario writes the snapshot it boots")
end

---@param path string
---@return string member bytes
function SnapshotBootFixture.readFile(path)
  return assert(love.filesystem.read(path), "the fixture file must be readable: " .. path)
end

return SnapshotBootFixture
