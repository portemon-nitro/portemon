-- Test-owned composition of the real producer output path. A test that needs a
-- published artifact builds one PreparedArtifact, runs the production family
-- stage into it, seals it, and mirrors the sealed bytes into its own physical
-- cache so payload assertions keep reading what the stage produced. No
-- alternative writer, stage filesystem, or receipt file exists here: every
-- entry comes from the artifact the production code sealed.

local ArtifactState = require("romdump.src.build.ArtifactState")
local PngEncoder = require("romdump.src.digest.PngEncoder")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")

local ResidentArtifactFixture = {}

ResidentArtifactFixture.GENERATION = "resident-artifact-fixture-generation"

-- One open artifact for a job, wired to the caller's cache as its read-only
-- dependency reader.
---@param cacheFs table<string, unknown> physical test cache serving dependency reads
---@param kind string
---@param key string
---@param generationId string?
---@param facts ArtifactState?
---@return PreparedArtifact
function ResidentArtifactFixture.new(cacheFs, kind, key, generationId, facts)
  assert(cacheFs and cacheFs.versionId, "artifact fixture requires a cache filesystem")
  return PreparedArtifact.new({
    cacheFs = cacheFs,
    facts = facts,
    generationId = generationId or ResidentArtifactFixture.GENERATION,
    epoch = 1,
    kind = kind,
    key = key,
    jobKey = kind .. ":" .. key,
  })
end

-- Mirror a sealed artifact's output into the caller's physical cache. The
-- bytes are the sealed ones; nothing is re-encoded or re-derived.
---@param artifact PreparedArtifact
---@param cacheFs table<string, unknown>? defaults to the artifact's own dependency reader
---@return PreparedArtifact.Sealed
function ResidentArtifactFixture.materialize(artifact, cacheFs)
  local sealed = artifact:sealed()
  ResidentArtifactFixture.mirror(cacheFs or artifact:cacheFs(), sealed)
  return sealed
end

-- Mirror an already sealed record into a cache: the shape a caller has after
-- running a job through `ArtifactJobs.execute`.
---@param cacheFs table<string, unknown>
---@param sealed PreparedArtifact.Sealed
function ResidentArtifactFixture.mirror(cacheFs, sealed)
  for _, entry in ipairs(sealed.entries) do
    cacheFs:write(entry.path, entry.data)
  end
end

-- Seal one artifact without publishing it anywhere: the caller owns the sealed
-- bytes, exactly like a worker handing its result to the controller.
---@param cacheFs table<string, unknown> read-only dependency reader
---@param kind string
---@param key string
---@param stage fun(artifact: PreparedArtifact): string
---@param generationId string?
---@return string marker
---@return PreparedArtifact.Sealed sealed
function ResidentArtifactFixture.seal(cacheFs, kind, key, stage, generationId)
  local artifact = ResidentArtifactFixture.new(cacheFs, kind, key, generationId)
  local marker = stage(artifact)
  ResidentArtifactFixture.encodeDeferredImages(artifact)
  return marker, artifact:finishSuccess({ marker = marker })
end

-- Publish one artifact through the production stage function: build the
-- private output, run `stage(artifact) -> marker`, seal it, and mirror the
-- sealed entries into the caller's cache. The sealed record is returned so a
-- caller can commit the completion fact the controller would commit.
---@param cacheFs table<string, unknown>
---@param kind string
---@param key string
---@param stage fun(artifact: PreparedArtifact): string
---@param generationId string?
---@return string marker
---@return PreparedArtifact.Sealed sealed
function ResidentArtifactFixture.publish(cacheFs, kind, key, stage, generationId)
  local artifact = ResidentArtifactFixture.new(cacheFs, kind, key, generationId)
  local marker = stage(artifact)
  ResidentArtifactFixture.encodeDeferredImages(artifact)
  local sealed = artifact:finishSuccess({ marker = marker })
  ResidentArtifactFixture.materialize(artifact, cacheFs)
  return marker, sealed
end

-- Commit one sealed artifact's completion fact into the caller's fact map
-- through the production prepare/commit pair. The controller commits bytes and
-- fact together, so a fixture that publishes an artifact commits its fact too.
---@param facts ArtifactState
---@param sealed PreparedArtifact.Sealed
---@param dependencyKeys string[]? already committed canonical job keys the artifact read
---@return ArtifactState.Fact
function ResidentArtifactFixture.commitFact(facts, sealed, dependencyKeys)
  local record = ArtifactState.prepareFact(sealed, dependencyKeys or {}, facts)
  ArtifactState.commitFact(facts, record)
  return record
end

-- The production worker's deferred PNG continuation, run inline: every
-- pending RGBA row becomes one PNG written into the artifact's private output.
---@param artifact PreparedArtifact
function ResidentArtifactFixture.encodeDeferredImages(artifact)
  for _, image in ipairs(artifact:pendingImages()) do
    artifact:write(image.relativePath, PngEncoder.encode(image.width, image.height, image.rgba:getString()))
  end
end

return ResidentArtifactFixture
