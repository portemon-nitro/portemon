-- Synthetic whole script-cache builder for producer-integration tests: builds retail-shape
-- scr_seq member bytes, plans the generation through the real producer,
-- compiles one member through the compile session, and publishes members and
-- the generation summary through the worker preparation.
--
-- The fixture never supplies generated payloads itself: every staged byte comes
-- from ScriptCompiler and ScriptCacheWriter.

local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local Narc = require("libs.nds.src.nitro.Narc")
local NarcBuilder = require("tests.support.NarcBuilder")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
local ScriptCacheWriter = require("romdump.src.digest.script.ScriptCacheWriter")
local ScriptCompileSession = require("romdump.src.digest.script.ScriptCompileSession")
local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")
local ResidentArtifactFixture = require("tests.support.ResidentArtifactFixture")

local ScriptCacheBuildFixture = {}

local ROM_SHA = "rom-sha"
local ARCHIVE_PATH = "scr_seq.narc"

---@return CacheFs
function ScriptCacheBuildFixture.cache()
  return CacheFs.forVersion("heartgold", FakeCache.new())
end

-- One synthetic RomFs over an ordered scr_seq NARC: source member ids are the
-- array positions.
---@param memberBytes string[]
---@return RomFs
function ScriptCacheBuildFixture.romFs(memberBytes)
  local archiveBytes = NarcBuilder.build(memberBytes)
  local archive = assert(Narc.open(archiveBytes, "synthetic scripts"))
  return {
    version = function()
      return "heartgold"
    end,
    metadata = function()
      return { sha1 = ROM_SHA }
    end,
    resolvedNarc = function(_, alias)
      assert(alias == "field_scripts", "unexpected NARC alias: " .. tostring(alias))
      return { symbol = "scr_seq", alias = "field_scripts", narcId = 1, fileId = 7, path = ARCHIVE_PATH }
    end,
    read = function(_, fileId)
      assert(fileId == 7, "unexpected ROM file id: " .. tostring(fileId))
      return archiveBytes
    end,
    openNarc = function(_, alias)
      assert(alias == "field_scripts", "unexpected NARC alias: " .. tostring(alias))
      return archive
    end,
  } --[[@as RomFs]]
end

-- A generation identity is the producer's dependency hash; the fixture injects
-- the hash so one generation keeps a stable 40-digit key across reruns.
---@param romFs RomFs
---@param generationKey string
---@return table<string, unknown>
function ScriptCacheBuildFixture.plan(romFs, generationKey)
  return ScriptCompiler.plan(romFs, "synthetic-producer", {
    sha1hex = function()
      return string.rep("c", 40)
    end,
    hashLua = function()
      return generationKey
    end,
  })
end

---@param romFs RomFs
---@param plan table<string, unknown>
---@param memberId integer
---@return table<string, unknown>
function ScriptCacheBuildFixture.compileMember(romFs, plan, memberId)
  local session = assert(ScriptCompileSession.new(romFs, plan, {
    sha1hex = function()
      return string.rep("c", 40)
    end,
    hashLua = function()
      return plan.generationKey
    end,
  }))
  local compiled = assert(session:compileMember(memberId))
  session:close()
  return compiled
end

local function preparation(cache, outerGeneration, key, stageName)
  return PreparedArtifact.new({
    cacheFs = cache,
    generationId = outerGeneration,
    epoch = 1,
    kind = "script-member",
    key = key,
    jobKey = "script-member:" .. key,
    stageName = stageName,
  })
end

---@param cache CacheFs
---@param outerGeneration string
---@param plan table<string, unknown>
---@param compiledMember table<string, unknown>
---@param stageName string
function ScriptCacheBuildFixture.publishMember(cache, outerGeneration, plan, compiledMember, stageName)
  local key = tostring(compiledMember.memberId)
  local artifact = preparation(cache, outerGeneration, key, stageName)
  local marker = assert(ScriptCacheWriter.stageMember(artifact, plan, compiledMember))
  artifact:finishSuccess({ marker = marker })
  assert(ResidentArtifactFixture.materialize(artifact))
end

---@param cache CacheFs
---@param outerGeneration string
---@param plan table<string, unknown>
---@param stageName string
function ScriptCacheBuildFixture.publishSummary(cache, outerGeneration, plan, stageName)
  local artifact = preparation(cache, outerGeneration, "global", stageName)
  local marker = assert(ScriptCacheWriter.stageSummary(artifact, plan))
  artifact:finishSuccess({ marker = marker })
  assert(ResidentArtifactFixture.materialize(artifact))
end

-- Compile and publish every planned nonempty member of one synthetic
-- generation, then activate it through the summary.
---@param romFs RomFs
---@param generationKey string
---@param outerGeneration string
---@param stagePrefix string
---@return table<string, unknown> plan, CacheFs cache, table<integer, table<string, unknown>> compiled
function ScriptCacheBuildFixture.publishGeneration(romFs, generationKey, outerGeneration, stagePrefix)
  local plan = ScriptCacheBuildFixture.plan(romFs, generationKey)
  local cache = ScriptCacheBuildFixture.cache()
  local compiled = {}
  for _, memberPlan in ipairs(plan.members) do
    local memberId = memberPlan.memberId
    local member = ScriptCacheBuildFixture.compileMember(romFs, plan, memberId)
    compiled[memberId] = member
    ScriptCacheBuildFixture.publishMember(
      cache,
      outerGeneration,
      plan,
      member,
      stagePrefix .. "-member-" .. tostring(memberId)
    )
  end
  ScriptCacheBuildFixture.publishSummary(cache, outerGeneration, plan, stagePrefix .. "-summary")
  return plan, cache, compiled
end

-- Cache-relative paths of every published file in the version cache, sorted.
---@param cache CacheFs
---@return string[]
function ScriptCacheBuildFixture.allFiles(cache)
  local backend = cache.backend --[[@as table]]
  local prefix = cache:prefix()
  local paths = {}
  for path in pairs(backend.files) do
    if path:sub(1, #prefix) == prefix then
      paths[#paths + 1] = path:sub(#prefix + 1)
    end
  end
  table.sort(paths)
  return paths
end

-- Cache-relative paths of every published file below one cache-relative
-- directory, sorted.
---@param cache CacheFs
---@param directory string
---@return string[]
function ScriptCacheBuildFixture.filesUnder(cache, directory)
  local backend = cache.backend --[[@as table]]
  local prefix = cache:prefix() .. directory .. "/"
  local paths = {}
  for path in pairs(backend.files) do
    if path:sub(1, #prefix) == prefix then
      paths[#paths + 1] = path:sub(#cache:prefix() + 1)
    end
  end
  table.sort(paths)
  return paths
end

---@param cache CacheFs
---@param relativePath string
---@return string
function ScriptCacheBuildFixture.fileName(relativePath)
  return relativePath:match("([^/]+)$")
end

return ScriptCacheBuildFixture
