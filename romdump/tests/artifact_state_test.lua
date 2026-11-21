-- Committed artifact facts and the private artifact output they certify: the
-- canonical job identity owns one in-memory record, the record travels with
-- the bytes it describes, and a candidate fact is validated against the
-- already committed dependency closure before anything becomes visible.

local Assert = require("tests.support.Assert")
local ArtifactState = require("romdump.src.build.ArtifactState")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")

local T = {}

local GENERATION = "artifact-facts-test-generation"
local EPOCH = 1

local function newFacts()
  return ArtifactState.new(GENERATION)
end

local function commitMarkerFact(facts, kind, key, marker, dependencies)
  local record = ArtifactState.prepareFact({
    kind = kind,
    key = key,
    marker = marker,
    ownedRoots = {},
    sharedPaths = {},
    entries = {},
  }, dependencies or {}, facts)
  ArtifactState.commitFact(facts, record)
  return record
end

-- The canonical key vocabulary is the only way a fact is addressed: a global
-- family, a decimal member selector, and the field-cell pair are all valid,
-- while an unknown kind, a bare integer cell, or a path-shaped key is not.
function T.canonical_keys_are_the_only_fact_identity()
  Assert.equal(ArtifactState.key("field-camera", "global"), "field-camera:global", "a global family keys by name")
  Assert.equal(ArtifactState.key("message-bank", "219"), "message-bank:219", "a bank keys by its decimal id")
  Assert.equal(ArtifactState.key("field-cell", "11-4"), "field-cell:11-4", "a cell keeps its matrix/index pair")

  Assert.isTrue(pcall(ArtifactState.validateKey, "battle-ball", "POKE_BALL"), "a ball keeps its class key")
  Assert.isFalse(pcall(ArtifactState.validateKey, "battle-ball", "poke_ball"), "a ball key is upper case")
  Assert.isFalse(pcall(ArtifactState.validateKey, "field-cell", "4"), "a bare integer never addresses a cell")
  Assert.isFalse(pcall(ArtifactState.validateKey, "message-bank", "../escape"), "a key is never a path")
  Assert.isFalse(pcall(ArtifactState.validateKey, "not-a-family", "global"), "an unknown kind is refused")
  Assert.isFalse(pcall(ArtifactState.validateKey, "pc", "4"), "pc artifacts own only the global key")
end

-- A fresh map carries its generation and no records; a foreign generation is
-- a different map, so the same key never reads across generations.
function T.maps_are_generation_scoped()
  local first = newFacts()
  local second = ArtifactState.new("another-generation")
  Assert.equal(first.generationId, GENERATION)
  commitMarkerFact(first, "field-camera", "global", "camera-ready")
  Assert.notNil(ArtifactState.read(first, "field-camera", "global"), "the committing map holds its record")
  Assert.isNil(ArtifactState.read(second, "field-camera", "global"), "another generation sees nothing")
  Assert.isNil(ArtifactState.read(first, "field-weather", "global"), "an uncommitted job reads absent")
end

-- Committing is order-insensitive for independent jobs but never invents a
-- dependency: a parent whose declared prerequisite is uncommitted is refused
-- before any record changes.
function T.preparation_requires_the_committed_dependency_closure()
  local facts = newFacts()
  Assert.throws(function()
    ArtifactState.prepareFact({
      kind = "message-summary",
      key = "global",
      marker = "summary-ready",
      ownedRoots = {},
      sharedPaths = {},
      entries = {},
    }, { "message-bank:219" }, facts)
  end, "a parent cannot commit before its declared child")

  commitMarkerFact(facts, "message-bank", "219", "bank-ready")
  local record = ArtifactState.prepareFact({
    kind = "message-summary",
    key = "global",
    marker = "summary-ready",
    ownedRoots = { "data/generated/messages" },
    sharedPaths = {},
    entries = { { path = "data/generated/messages/index.lua" } },
  }, { "message-bank:219" }, facts)
  Assert.deepEqual(record.dependencies, { "message-bank:219" }, "the closure is recorded sorted")
  Assert.deepEqual(record.ownedRoots, { "data/generated/messages" }, "owned roots are recorded sorted")
  Assert.deepEqual(record.files, { "data/generated/messages/index.lua" }, "payload files are recorded sorted")

  ArtifactState.commitFact(facts, record)
  Assert.equal(
    ArtifactState.read(facts, "message-summary", "global").marker,
    "summary-ready",
    "the committed record is the one the lookup returns"
  )
  Assert.throws(function()
    ArtifactState.commitFact(facts, record)
  end, "a committed identity is never written twice")
end

-- A zero-file artifact is legal (a summary over committed jobs owns no payload
-- of its own), and duplicate entries are a preparation failure.
function T.zero_file_artifacts_are_legal_and_duplicates_are_not()
  local facts = newFacts()
  local record = commitMarkerFact(facts, "audio-summary", "global", "audio-ready")
  Assert.deepEqual(record.files, {}, "a completion-only artifact carries no files")
  Assert.throws(function()
    ArtifactState.prepareFact({
      kind = "party",
      key = "global",
      marker = "party-ready",
      ownedRoots = {},
      sharedPaths = {},
      entries = { { path = "data/generated/party/manifest.lua" }, { path = "data/generated/party/manifest.lua" } },
    }, {}, facts)
  end, "one path cannot be listed twice")
  Assert.throws(function()
    ArtifactState.prepareFact({
      kind = "party",
      key = "global",
      marker = "",
      ownedRoots = {},
      sharedPaths = {},
      entries = {},
    }, {}, facts)
  end, "a fact without a marker proves nothing")
end

local function newArtifact(kind, key, facts)
  return PreparedArtifact.new({
    cacheFs = { versionId = "heartgold", resolveAsset = function() end },
    facts = facts,
    generationId = GENERATION,
    epoch = EPOCH,
    kind = kind,
    key = key,
    jobKey = kind .. ":" .. key,
  })
end

-- The private output map is the producer's whole working surface: writes stay
-- invisible to every other owner until the artifact seals, and the seal
-- carries exactly those bytes under the job's ownership declarations.
function T.private_output_seals_into_the_transported_entries()
  local artifact = newArtifact("party", "global", newFacts())
  artifact:addOwnedRoot("data/generated/party")
  artifact:addSharedFile("assets/generated/shared/panel.png")
  artifact:write("data/generated/party/manifest.lua", "return {}\n")
  artifact:writeLua("data/generated/party/provenance.lua", { schema = "provenance" })
  artifact:write("assets/generated/shared/panel.png", "PNGDATA")

  Assert.equal(artifact:read("data/generated/party/manifest.lua"), "return {}\n", "a written string reads back")
  Assert.deepEqual(
    artifact:loadLua("data/generated/party/provenance.lua"),
    { schema = "provenance" },
    "a written Lua record loads back"
  )
  Assert.isTrue(artifact:exists("data/generated/party", "directory"), "a written file implies its directory")
  Assert.deepEqual(
    artifact:getDirectoryItems("data/generated/party"),
    { "manifest.lua", "provenance.lua" },
    "immediate children list sorted"
  )

  local sealed = artifact:finishSuccess({ marker = "party-ready" })
  Assert.equal(sealed.marker, "party-ready", "the seal carries the marker")
  Assert.deepEqual(sealed.ownedRoots, { "data/generated/party" }, "owned roots travel with the seal")
  Assert.deepEqual(sealed.sharedPaths, { "assets/generated/shared/panel.png" }, "shared paths travel with the seal")
  local paths = {}
  for index, entry in ipairs(sealed.entries) do
    paths[index] = entry.path
    Assert.equal(entry.size, entry.data:getSize(), "each entry reports its own size")
  end
  Assert.deepEqual(paths, {
    "assets/generated/shared/panel.png",
    "data/generated/party/manifest.lua",
    "data/generated/party/provenance.lua",
  }, "entries are sorted by logical path")
  Assert.throws(function()
    artifact:write("data/generated/party/late.lua", "return 1\n")
  end, "a sealed artifact accepts no further output")
end

-- Ownership declarations stay disjoint: roots never overlap, a shared file is
-- never owned, and a shared file never hides under an owned root.
function T.ownership_declarations_stay_disjoint()
  local artifact = newArtifact("field-camera", "global", newFacts())
  artifact:addOwnedRoot("data/generated/field")
  artifact:addOwnedRoot("data/generated/field")
  Assert.throws(function()
    artifact:addOwnedRoot("data/generated/field/30")
  end, "an overlapping root is refused")
  Assert.throws(function()
    artifact:addSharedFile("data/generated/field/30/atlas.png")
  end, "a shared file may not hide inside an owned root")
  artifact:addSharedFile("assets/generated/shared/atlas.png")
  Assert.throws(function()
    artifact:addOwnedRoot("assets/generated/shared")
  end, "an owned root may not swallow a shared file")
end

-- A deferred image keeps the artifact open: sealing without it fails, sealing
-- with an image outside the owned roots fails, and abort publishes nothing.
function T.deferred_images_must_be_staged_inside_the_owned_roots()
  local artifact = newArtifact("items", "global", newFacts())
  artifact:addOwnedRoot("assets/generated/item")
  artifact:deferImage("assets/generated/item/icons.png", 2, 2, string.rep("r", 2 * 2 * 4))
  Assert.equal(#artifact:pendingImages(), 1, "the pending image waits for its continuation")
  Assert.isTrue(artifact:hasDeferredImage("assets/generated/item/icons.png"), "the image is registered by path")
  Assert.throws(function()
    artifact:finishSuccess({ marker = "items-ready" })
  end, "an unwritten deferred image cannot seal")

  local escaping = newArtifact("items", "global", newFacts())
  escaping:addOwnedRoot("assets/generated/item")
  escaping:deferImage("assets/generated/other/icons.png", 2, 2, string.rep("r", 2 * 2 * 4))
  escaping:write("assets/generated/other/icons.png", "PNGDATA")
  Assert.throws(function()
    escaping:finishSuccess({ marker = "items-ready" })
  end, "a deferred image outside the owned roots cannot seal")

  local aborted = newArtifact("items", "global", newFacts())
  aborted:write("data/generated/item/marker.lua", "return 1\n")
  Assert.isTrue(aborted:abort(), "abort drops the private output")
  Assert.isNil(aborted:read("data/generated/item/marker.lua"), "aborted output is gone")
  Assert.throws(function()
    aborted:finishSuccess({ marker = "items-ready" })
  end, "an aborted artifact cannot seal")
end

-- A failure record crosses the transport as plain data, and a failed artifact
-- publishes nothing: its private output is released and no marker exists.
function T.failure_seals_a_transport_record_and_drops_output()
  local artifact = newArtifact("party", "global", newFacts())
  artifact:write("data/generated/party/manifest.lua", "return {}\n")
  local Errors = require("libs.errors.src.Errors")
  local record = artifact:finishFailure(
    Errors.new("PARTY_CACHE_BUNDLE_INVALID", "bad bundle", { path = "manifest" }),
    "trace"
  )
  Assert.equal(record.code, "PARTY_CACHE_BUNDLE_INVALID", "a typed cause keeps its code")
  Assert.equal(record.traceback, "trace", "the throw-site trace rides along")
  Assert.isNil(artifact:read("data/generated/party/manifest.lua"), "failed output is released")
  Assert.equal(artifact:status(), "failed", "the artifact records its failure")
  Assert.throws(function()
    artifact:finishSuccess({ marker = "party-ready" })
  end, "a failed artifact cannot seal success")
end

-- The pending PNG handoff resumes the same output: the continuation rebuilds
-- the artifact from its packet, writes the images, and seals once.
function T.pending_packets_resume_the_same_output()
  local artifact = newArtifact("items", "global", newFacts())
  artifact:addOwnedRoot("assets/generated/item")
  artifact:write("data/generated/item/manifest.lua", "return {}\n")
  artifact:deferImage("assets/generated/item/icons.png", 2, 2, string.rep("r", 2 * 2 * 4))
  local captured = artifact:captureOutput()
  local packet = {
    generationId = GENERATION,
    epoch = EPOCH,
    kind = "items",
    key = "global",
    jobKey = "items:global",
    marker = "items-ready",
    ownedRoots = captured.ownedRoots,
    sharedPaths = captured.sharedPaths,
    entries = captured.entries,
    images = artifact:pendingImages(),
  }

  local resumed = PreparedArtifact.fromPending(packet, {
    cacheFs = { versionId = "heartgold" },
    facts = newFacts(),
  })
  Assert.equal(resumed:read("data/generated/item/manifest.lua"), "return {}\n", "the resumed output keeps its bytes")
  Assert.equal(#resumed:pendingImages(), 1, "the resumed artifact still owns its pending image")
  resumed:write("assets/generated/item/icons.png", "PNGDATA")
  local sealed = resumed:finishSuccess({ marker = packet.marker })
  Assert.equal(sealed.marker, "items-ready", "the continuation seals the parent result")
end

-- A shared PNG whose bytes differ only in their encoder's deflate output is
-- the same content; any other difference is a real contradiction.
function T.shared_pngs_compare_by_decoded_content()
  local host = love
  local function png(compressed)
    return host.data.newByteData(compressed)
  end
  local left = png("same")
  local right = png("same")
  Assert.isTrue(PreparedArtifact.equalContent("assets/generated/a.png", left, right), "equal bytes compare equal")
  Assert.isFalse(
    PreparedArtifact.equalContent("assets/generated/a.png", png("left"), png("right")),
    "non-PNG bytes compare literally"
  )
end

return { tests = T }
