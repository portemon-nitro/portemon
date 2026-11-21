-- Next boot from a saved snapshot: one plain ZIP supplies the whole resident
-- generated set, its small manifest is validated before any payload buffer is
-- allocated, every listed member is hydrated once, and a damaged candidate is
-- rejected whole so the ordinary rebuild/source route runs instead of a
-- partial or looping boot. A partial snapshot keeps its honest coverage: the
-- boot may reuse what it proves and must still produce the rest.
--
-- The snapshot is saved through the production archive writer and read back
-- through the archive owner's boot reader (see tests/support/SnapshotBootFixture
-- for the boot-side convention this suite fixes). Each scenario owns a private
-- generated-cache root, so no scenario reads or writes a real prepared cache.

local Assert = require("tests.support.Assert")
local LuaWriter = require("libs.codec.src.LuaWriter")
local SnapshotArchive = require("tests.support.SnapshotArchive")
local SnapshotBootFixture = require("tests.support.SnapshotBootFixture")
local ZipBuilder = require("tests.support.ZipBuilder")

local T = {}

local SCENE_PATH = "data/generated/field/30/scene.lua"
local SCRIPT_PATH = "data/generated/scripts/30.lua"
local ATLAS_PATH = "assets/generated/field/30/atlas.png"
local ATLAS_BYTES = "PNG-ATLAS-PAYLOAD-FOR-FIELD-30"
local MISSING_PATH = "data/generated/audio/summary/1.lua"

local function rootFor(name)
  return "boot-probe-" .. name
end

-- One small closed graph: a map artifact publishing its scene plus a shared
-- atlas, and a dependent script artifact that publishes the same atlas.
local function completeCut(identity)
  return {
    generationId = identity.generationId,
    identity = identity,
    epoch = 1,
    sequence = 12,
    entries = {
      SnapshotBootFixture.blob(identity, SCENE_PATH, "return { mapId = 30 }\n"),
      SnapshotBootFixture.blob(identity, SCRIPT_PATH, "return { script = 30 }\n"),
      SnapshotBootFixture.blob(identity, ATLAS_PATH, ATLAS_BYTES),
    },
    artifacts = {
      {
        kind = "map",
        key = "30",
        marker = "map-ready",
        dependencies = {},
        ownedRoots = { "data/generated/field/30" },
        sharedPaths = { ATLAS_PATH },
        files = { SCENE_PATH, ATLAS_PATH },
      },
      {
        kind = "script",
        key = "main",
        marker = "script-ready",
        dependencies = { "map:30" },
        ownedRoots = { "data/generated/scripts/30.lua" },
        sharedPaths = { ATLAS_PATH },
        files = { SCRIPT_PATH, ATLAS_PATH },
      },
    },
    milestones = { "bootstrap", "field" },
    firstPlay = true,
    complete = true,
  }
end

-- The same graph cut short: only the map's scene is proven, so the snapshot
-- must never claim completeness for the rest of the corpus.
local function partialCut(identity)
  return {
    generationId = identity.generationId,
    identity = identity,
    epoch = 1,
    sequence = 5,
    entries = {
      SnapshotBootFixture.blob(identity, SCENE_PATH, "return { mapId = 30 }\n"),
    },
    artifacts = {
      {
        kind = "map",
        key = "30",
        marker = "map-ready",
        dependencies = {},
        ownedRoots = { "data/generated/field/30" },
        sharedPaths = {},
        files = { SCENE_PATH },
      },
    },
    milestones = {},
    firstPlay = false,
    complete = false,
  }
end

local function payloadsOf(cut)
  local payloads = {}
  for _, entry in ipairs(cut.entries) do
    payloads[entry.path] = entry.data:getString()
  end
  return payloads
end

---@param map table<string, unknown>
---@return string[] sortedKeys
local function sortedKeys(map)
  local keys = {}
  for key in pairs(map) do
    keys[#keys + 1] = tostring(key)
  end
  table.sort(keys)
  return keys
end

local function assertServedBytes(candidate, payloads, label)
  local served = SnapshotBootFixture.bytes(candidate)
  Assert.deepEqual(
    sortedKeys(served),
    sortedKeys(payloads),
    label .. ": the snapshot serves exactly its covered paths"
  )
  for path, expected in pairs(payloads) do
    Assert.equal(served[path], expected, label .. ": the served bytes are the saved member bytes: " .. path)
  end
end

-- One private generated-cache root per scenario, removed whatever happens.
local function withRoot(root, body)
  local ok, err = pcall(body)
  SnapshotBootFixture.releaseWriters()
  SnapshotBootFixture.removeRoot(root)
  if not ok then
    error(err, 0)
  end
end

-- A complete matching snapshot hydrates into the whole resident set before the
-- boot proceeds: exact identity, sequence and completion facts, one immutable
-- reference per member with its checked size and derived cache identity, and
-- bytes that stay readable after the saved archive is gone.
function T.a_complete_snapshot_hydrates_into_resident_bytes()
  local root = rootFor("complete")
  local identity = SnapshotBootFixture.identity()
  local cut = completeCut(identity)
  local payloads = payloadsOf(cut)
  withRoot(root, function()
    SnapshotBootFixture.save(root, cut)

    local candidate = SnapshotBootFixture.open(root, identity)
    Assert.notNil(candidate, "a complete matching snapshot must hydrate for the next boot")
    local hydrated = assert(candidate)
    Assert.deepEqual(hydrated.identity, identity, "the hydrated snapshot carries the exact cache identity")
    Assert.equal(hydrated.sequence, 12, "the hydrated snapshot carries the sequence it was captured at")
    Assert.equal(hydrated.complete, true, "a complete snapshot admits the offline boot")
    Assert.equal(hydrated.firstPlay, true, "the captured first-play fact travels with its own cut")
    Assert.deepEqual(
      SnapshotArchive.sorted(hydrated.milestones or {}),
      { "bootstrap", "field" },
      "the captured milestones travel with their own cut"
    )

    local entries = SnapshotBootFixture.entries(hydrated)
    Assert.equal(#entries, 3, "every saved member is hydrated, and nothing else")
    assertServedBytes(hydrated, payloads, "complete snapshot")
    for _, reference in ipairs(entries) do
      local expected = assert(payloads[reference.path], "the snapshot serves only saved members: " .. reference.path)
      Assert.equal(reference.size, #expected, "the reference reports the checked member size: " .. reference.path)
      Assert.equal(
        reference.sourceId,
        "base:" .. tostring(identity.generationId),
        "the reference names the base store that owns its bytes: " .. reference.path
      )
      Assert.equal(
        reference.contentId,
        tostring(identity.generationId) .. "\0" .. reference.path,
        "the reference carries its source-independent content identity: " .. reference.path
      )
    end

    local artifacts = SnapshotBootFixture.artifacts(hydrated)
    Assert.deepEqual(
      sortedKeys(artifacts),
      { "map:30", "script:main" },
      "the hydrated snapshot carries exactly the captured artifact facts, each under its canonical job key"
    )
    local map = assert(artifacts["map:30"], "the hydrated snapshot carries the map completion fact")
    Assert.equal(map.marker, "map-ready", "the artifact keeps its completion marker")
    Assert.deepEqual(SnapshotArchive.sorted(map.dependencies or {}), {}, "the artifact keeps its dependency facts")
    Assert.deepEqual(
      SnapshotArchive.sorted(map.ownedRoots or {}),
      { "data/generated/field/30" },
      "the artifact keeps its owned roots"
    )
    Assert.deepEqual(
      SnapshotArchive.sorted(map.sharedPaths or {}),
      { ATLAS_PATH },
      "the artifact keeps the payload it shares"
    )
    Assert.deepEqual(
      SnapshotArchive.sorted(map.files or {}),
      { ATLAS_PATH, SCENE_PATH },
      "the hydrated artifact names its published payloads by logical path, not by a manifest index"
    )
    local script = assert(artifacts["script:main"], "the hydrated snapshot carries the dependent artifact fact")
    Assert.deepEqual(
      SnapshotArchive.sorted(script.dependencies or {}),
      { "map:30" },
      "the dependent artifact keeps its canonical dependency"
    )

    -- The saved archive is input only: the hydrated bytes survive its loss.
    Assert.isTrue(love.filesystem.remove(root .. "/cache.zip"), "the scenario removes the saved archive")
    assertServedBytes(hydrated, payloads, "complete snapshot after the archive is gone")
  end)
end

-- A partial snapshot hydrates only what it proves and says so: the boot reuses
-- the covered artifact and must still produce the uncovered one.
function T.a_partial_snapshot_hydrates_only_its_covered_work()
  local root = rootFor("partial")
  local identity = SnapshotBootFixture.identity()
  local cut = partialCut(identity)
  local payloads = payloadsOf(cut)
  withRoot(root, function()
    SnapshotBootFixture.save(root, cut)

    local candidate = SnapshotBootFixture.open(root, identity)
    Assert.notNil(candidate, "a partial snapshot still hydrates the coverage it proves")
    local hydrated = assert(candidate)
    Assert.equal(hydrated.sequence, 5, "the partial snapshot carries its own captured sequence")
    Assert.equal(hydrated.complete, false, "a partial snapshot never claims the whole corpus")
    Assert.equal(hydrated.firstPlay, false, "an unfinished cut carries no first-play fact it did not prove")
    Assert.deepEqual(
      SnapshotArchive.sorted(hydrated.milestones or {}),
      {},
      "an unfinished cut proves no milestone"
    )

    assertServedBytes(hydrated, payloads, "partial snapshot")
    local served = SnapshotBootFixture.bytes(hydrated)
    Assert.isNil(served[MISSING_PATH], "a payload the cut never captured is not served from the snapshot")
    Assert.isNil(served[SCRIPT_PATH], "the uncovered dependent artifact stays uncovered")

    local artifacts = SnapshotBootFixture.artifacts(hydrated)
    Assert.notNil(artifacts["map:30"], "the covered artifact fact is retained for the boot")
    Assert.isNil(artifacts["script:main"], "an artifact outside the captured closure is not claimed as done")
  end)
end

-- Every material kind of damage rejects the whole candidate with a typed cause
-- and exposes no partial hydration; restoring the saved bytes makes the same
-- root boot again, so the rejection belongs to the damage and not the scenario.
function T.a_damaged_snapshot_yields_no_candidate()
  local root = rootFor("damaged")
  local identity = SnapshotBootFixture.identity()
  withRoot(root, function()
    SnapshotBootFixture.save(root, completeCut(identity))
    local goodBytes, rawIndex = SnapshotBootFixture.canonical(root)
    goodBytes = assert(goodBytes)
    local _, members = SnapshotArchive.read(root)
    members = assert(members, "the saved snapshot is readable before the scenario damages it")

    ---@param label string
    ---@param damaged string
    local function assertRejected(label, damaged)
      Assert.isTrue(damaged ~= goodBytes, label .. ": the damaged archive differs from the saved one")
      SnapshotBootFixture.writeCanonical(root, damaged)
      local candidate, failure = SnapshotBootFixture.open(root, identity)
      Assert.isNil(candidate, label .. ": a damaged snapshot installs nothing")
      Assert.equal(type(failure), "table", label .. ": the rejection carries a typed cause")
      local reason = assert(failure)
      Assert.isTrue(
        type(reason.code) == "string" and reason.code ~= "",
        label .. ": the rejection names its cause code"
      )
      Assert.isTrue(
        type(reason.message) == "string" and reason.message ~= "",
        label .. ": the rejection carries a readable message"
      )
      SnapshotBootFixture.writeCanonical(root, goodBytes)
      Assert.notNil(
        SnapshotBootFixture.open(root, identity),
        label .. ": the same root boots again once its saved bytes are restored"
      )
    end

    ---@param mutate fun(parsed: table): nil
    ---@return string rebuilt archive bytes carrying the mutated manifest
    local function rebuild(mutate)
      local parsed = SnapshotArchive.parseIndex(assert(rawIndex))
      mutate(parsed)
      local files = { { name = "cache-index.lua", data = assert(LuaWriter.encode(parsed)) } }
      for _, entry in ipairs(parsed.entries) do
        -- A manifest row whose member is absent stays absent: index validity is
        -- what this rebuild changes, and rejection must happen before payload
        -- buffers are allocated.
        if members[entry.path] ~= nil then
          files[#files + 1] = { name = entry.path, data = members[entry.path] }
        end
      end
      return ZipBuilder.build(files)
    end

    local function sortEntries(parsed)
      table.sort(parsed.entries, function(left, right)
        return left.path < right.path
      end)
    end

    -- One member's stored bytes no longer match its recorded checksum.
    local at = assert(goodBytes:find(ATLAS_BYTES, 1, true), "the stored png payload is addressable in the archive")
    assertRejected("flipped member byte", goodBytes:sub(1, at + 4) .. "X" .. goodBytes:sub(at + 6))

    -- One manifest row declares a size the member does not have.
    assertRejected("declared size mismatch", rebuild(function(parsed)
      for _, entry in ipairs(parsed.entries) do
        if entry.path == SCENE_PATH then
          entry.uncompressedSize = entry.uncompressedSize + 1
          return
        end
      end
      error("the manifest lists the scene member")
    end))

    -- The manifest lists the same logical path twice.
    assertRejected("duplicate manifest row", rebuild(function(parsed)
      parsed.entries[#parsed.entries + 1] = {
        path = parsed.entries[1].path,
        uncompressedSize = parsed.entries[1].uncompressedSize,
        unsignedCrc32 = parsed.entries[1].unsignedCrc32,
      }
      sortEntries(parsed)
    end))

    -- The manifest names a path outside the generated roots.
    assertRejected("path outside the generated roots", rebuild(function(parsed)
      parsed.entries[#parsed.entries + 1] = {
        path = "data/generated/../../escape.lua",
        uncompressedSize = 1,
        unsignedCrc32 = 0,
      }
      sortEntries(parsed)
    end))

    -- The container itself is truncated.
    assertRejected("truncated central directory", goodBytes:sub(1, #goodBytes - 40))

    -- The manifest describes another generation.
    assertRejected("stale generation identity", rebuild(function(parsed)
      parsed.identity.romSha1 = string.rep("d", 40)
    end))
  end)
end

-- The snapshot a boot may use is chosen honestly: a leftover backup holds the
-- last recoverable archive, while an orphan temporary is never a candidate.
function T.a_boot_prefers_the_backup_and_never_boots_an_orphan_temporary()
  local root = rootFor("recovery")
  local identity = SnapshotBootFixture.identity()
  withRoot(root, function()
    SnapshotBootFixture.save(root, completeCut(identity))
    local savedBytes = assert(SnapshotBootFixture.canonical(root))
    Assert.isTrue(love.filesystem.remove(root .. "/cache.zip"), "the canonical archive moves aside")
    Assert.isTrue(love.filesystem.write(root .. "/cache.zip.bak", savedBytes), "the backup holds the last snapshot")
    Assert.isTrue(
      love.filesystem.write(root .. "/cache.zip.new", "not a zip at all"),
      "a stray unfinished temporary is present"
    )

    local candidate = SnapshotBootFixture.open(root, identity)
    Assert.notNil(candidate, "a boot with no canonical archive still uses the recoverable backup")
    local recovered = assert(candidate)
    Assert.equal(recovered.sequence, 12, "the recovered snapshot is the last completed cut")
    Assert.equal(
      SnapshotBootFixture.bytes(recovered)[ATLAS_PATH],
      ATLAS_BYTES,
      "the recovered snapshot serves the bytes the backup kept"
    )

    Assert.isTrue(love.filesystem.remove(root .. "/cache.zip.bak"), "the backup is removed for the second boot")
    Assert.isNil(
      SnapshotBootFixture.open(root, identity),
      "an unfinished temporary is never booted as a snapshot"
    )
  end)
end

return { tests = T }
