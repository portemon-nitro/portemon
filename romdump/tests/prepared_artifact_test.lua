-- The job-private artifact output: one writable memory map per job, sealed
-- once into the immutable entry list the controller publishes, with ownership
-- declarations, deferred PNG rows, and the dependency reader every producer
-- may consult read-only.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local PngEncoder = require("romdump.src.digest.PngEncoder")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")

local T = {}

local GENERATION = "prepared-artifact-test-generation"

local function dependencyReader()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua("data/generated/field/30/scene.lua", { mapId = 30 })
  return cache
end

local function newArtifact(kind, key, cacheFs)
  return PreparedArtifact.new({
    cacheFs = cacheFs or dependencyReader(),
    generationId = GENERATION,
    epoch = 1,
    kind = kind,
    key = key,
    jobKey = kind .. ":" .. key,
  })
end

-- Identity is validated before any output exists: a mismatched job key, an
-- unknown family, or an unsafe key never produces a writable artifact.
function T.identity_is_validated_before_any_output()
  Assert.throws(function()
    PreparedArtifact.new({
      cacheFs = dependencyReader(),
      generationId = GENERATION,
      epoch = 1,
      kind = "party",
      key = "global",
      jobKey = "party:other",
    })
  end, "a job key that contradicts its kind and key is refused")
  Assert.throws(function()
    newArtifact("not-a-family", "global")
  end, "an unknown family cannot own output")
  Assert.throws(function()
    newArtifact("message-bank", "../escape")
  end, "a path-shaped key cannot own output")
end

-- The dependency reader is read-only and separate: writing artifact output
-- never changes it, so no producer can publish through the view it reads.
function T.writes_never_touch_the_dependency_reader()
  local cache = dependencyReader()
  local artifact = newArtifact("field-camera", "global", cache)
  Assert.equal(artifact:cacheFs(), cache, "the artifact exposes the reader it was given")
  artifact:addOwnedRoot("data/generated/field/30/camera")
  artifact:write("data/generated/field/30/camera/manifest.lua", "return {}\n")
  Assert.equal(cache:read("data/generated/field/30/camera/manifest.lua"), nil, "the reader stays unchanged")
  Assert.deepEqual(cache:loadLua("data/generated/field/30/scene.lua"), { mapId = 30 }, "dependencies stay readable")
  Assert.equal(artifact:read("data/generated/field/30/camera/manifest.lua"), "return {}\n", "private output holds it")
end

-- A deferred image holds the artifact open until its continuation writes it,
-- and the seal then carries both the authored output and the encoded PNG.
function T.deferred_images_join_the_sealed_output()
  local artifact = newArtifact("items", "global")
  artifact:addOwnedRoot("assets/generated/item")
  artifact:deferImage("assets/generated/item/icons.png", 2, 2, string.rep("r", 2 * 2 * 4))
  local deferred = assert(artifact:pendingImages()[1], "the icon atlas is deferred")
  Assert.equal(deferred.width, 2, "the pending image carries its width")
  artifact:write(deferred.relativePath, PngEncoder.encode(deferred.width, deferred.height, deferred.rgba:getString()))
  artifact:write("data/generated/item/manifest.lua", "return {}\n")
  local sealed = artifact:finishSuccess({ marker = "items-ready" })
  local found = {}
  for _, entry in ipairs(sealed.entries) do
    found[entry.path] = entry.size
  end
  Assert.isTrue((found["assets/generated/item/icons.png"] or 0) > 0, "the encoded PNG is in the seal")
  Assert.equal(found["data/generated/item/manifest.lua"], 10, "authored output keeps its size")
end

-- A string output becomes one Data buffer once; a supplied Data buffer is
-- adopted, so the same immutable bytes travel by reference.
function T.strings_become_data_once_and_data_is_adopted()
  local artifact = newArtifact("party", "global")
  local supplied = assert(love.data.newByteData("PNGDATA"))
  artifact:write("assets/generated/party/panel.png", supplied)
  artifact:write("data/generated/party/manifest.lua", "return {}\n")
  Assert.equal(artifact:readData("assets/generated/party/panel.png"), supplied, "supplied Data is adopted as-is")
  artifact:addOwnedRoot("assets/generated/party")
  artifact:addOwnedRoot("data/generated/party")
  local sealed = artifact:finishSuccess({ marker = "party-ready" })
  for _, entry in ipairs(sealed.entries) do
    if entry.path == "assets/generated/party/panel.png" then
      Assert.equal(entry.data, supplied, "the seal carries the same buffer")
    end
  end
end

-- Overlapping completion ownership is refused before any output is written,
-- so two jobs can never claim the same bytes.
function T.ownership_conflicts_are_refused_before_output()
  local artifact = newArtifact("mon-layout", "global")
  artifact:addOwnedRoot("data/generated/mon/layout")
  Assert.throws(function()
    artifact:addOwnedRoot("data/generated/mon/layout/pages")
  end, "an overlapping root is refused")
  artifact:addSharedFile("assets/generated/shared/icon.png")
  Assert.throws(function()
    artifact:addOwnedRoot("assets/generated/shared")
  end, "an owned root may not swallow a declared shared file")
end

-- Aborting a stage discards only its private output; the dependency reader and
-- every other owner's bytes are untouched.
function T.abort_discards_only_private_output()
  local cache = dependencyReader()
  local artifact = newArtifact("party", "global", cache)
  artifact:addOwnedRoot("data/generated/party")
  artifact:write("data/generated/party/manifest.lua", "return {}\n")
  artifact:abort()
  Assert.isNil(artifact:read("data/generated/party/manifest.lua"), "aborted output is gone")
  Assert.deepEqual(cache:loadLua("data/generated/field/30/scene.lua"), { mapId = 30 }, "dependencies survive")
  Assert.throws(function()
    artifact:abort()
  end, "an aborted artifact cannot abort twice")
end

-- A failed stage keeps the cause as transport data and publishes nothing, so a
-- family validation failure never becomes visible output.
function T.failures_carry_their_cause_and_publish_nothing()
  local Errors = require("libs.errors.src.Errors")
  local artifact = newArtifact("field-camera", "global")
  artifact:addOwnedRoot("data/generated/field/30/camera")
  artifact:write("data/generated/field/30/camera/manifest.lua", "return {}\n")
  local record = artifact:finishFailure(Errors.new("FIELD_CAMERA_INVALID", "camera bundle is invalid", {}), "trace")
  Assert.equal(record.code, "FIELD_CAMERA_INVALID", "the cause keeps its code")
  Assert.equal(record.traceback, "trace", "the trace is retained")
  Assert.isNil(artifact:read("data/generated/field/30/camera/manifest.lua"), "failed output is dropped")
  Assert.throws(function()
    artifact:finishSuccess({ marker = "camera-ready" })
  end, "a failed stage cannot seal success")
end

-- The sealed result is required: a success without a marker proves nothing.
function T.success_requires_a_result_marker()
  local artifact = newArtifact("party", "global")
  artifact:write("data/generated/party/manifest.lua", "return {}\n")
  Assert.throws(function()
    artifact:finishSuccess({})
  end, "a missing marker cannot seal")
  Assert.throws(function()
    artifact:finishSuccess({ marker = "" })
  end, "an empty marker cannot seal")
end

return { tests = T }
