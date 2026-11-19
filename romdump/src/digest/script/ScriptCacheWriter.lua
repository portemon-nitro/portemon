-- Persists the derived script class through worker-owned prepared stages:
-- each member job stages exactly one readable Lua bundle for its own source
-- archive member into a private stage, readback-validated there, and only the
-- controller publishes it, so a private repair of an already selected
-- generation never mutates live files. A final summary job proves every
-- planned member is current in the live cache, joins each published bundle's
-- compact dependency facts and coverage record exactly once, and stages the
-- single active index plus the one aggregate coverage report in one
-- transaction. Staging and validation are one step; publication happens
-- outside that step's error handler, so a publish failure never triggers
-- writer-level stage cleanup that could delete the last remaining copy of the
-- previous artifact.

local AssetNeeds = require("libs.script.src.AssetNeeds")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local Coverage = require("romdump.src.digest.script.Coverage")
local Errors = require("libs.errors.src.Errors")
local LuaEmitter = require("romdump.src.digest.script.LuaEmitter")
local Validate = require("libs.assets.src.Validate")

local ScriptCacheWriter = {}

---@param cacheFs CacheFs
---@param marker string
---@return boolean
function ScriptCacheWriter.isReady(cacheFs, marker)
  return ScriptCache.isReady(cacheFs, marker)
end

local function memberFor(plan, memberId)
  for _, member in ipairs(plan.members) do
    if member.memberId == memberId then
      return member
    end
  end
  Errors.raise("SCRIPT_MEMBER_INVALID", "unknown planned script member: " .. tostring(memberId), {
    memberId = memberId,
  })
end

-- The planned resources of one member in source script order.
---@param plan table<string, unknown>
---@param memberId integer
---@return { id: string, member: integer, scriptIndex: integer }[]
local function plannedScripts(plan, memberId)
  local planned = {}
  for _, entry in ipairs(plan.resources) do
    if entry.member == memberId then
      planned[#planned + 1] = entry
    end
  end
  table.sort(planned, function(a, b)
    return a.scriptIndex < b.scriptIndex
  end)
  return planned
end

-- True when the value is a sorted unique array of non-empty strings (the
-- shape of every persisted dependency list, so identical inputs always
-- encode identically and duplicates can never mask a missing edge).
local function isSortedUniqueStrings(value)
  if not Validate.isArray(value) then
    return false
  end
  local previous
  for _, entry in ipairs(value) do
    if type(entry) ~= "string" or entry == "" then
      return false
    end
    if previous ~= nil and previous >= entry then
      return false
    end
    previous = entry
  end
  return true
end

-- A sorted unique list whose entries are all `kind:id` asset need keys.
local function isAssetNeedKeys(value)
  if not isSortedUniqueStrings(value) then
    return false
  end
  for _, key in ipairs(value) do
    if not pcall(AssetNeeds.parse, key) then
      return false
    end
  end
  return true
end

-- One member's coverage record must describe exactly the planned scripts of
-- that member.
---@param plan table<string, unknown>
---@param memberId integer
---@param coverage unknown
local function validateCoverage(plan, memberId, coverage)
  local context = { memberId = memberId }
  local function invalid(message)
    Errors.raise("SCRIPT_MEMBER_COVERAGE_INVALID", message, context)
  end
  local expected = plannedScripts(plan, memberId)
  if type(coverage) ~= "table" then
    invalid("script member coverage is malformed")
  end
  if type(coverage.source) ~= "table" then
    invalid("script member coverage source is missing")
  end
  if type(coverage.totals) ~= "table" then
    invalid("script member coverage totals are missing")
  end
  if coverage.totals.members ~= 1 then
    invalid("script member coverage must describe one member")
  end
  if coverage.totals.scripts ~= #expected then
    invalid("script member coverage script count mismatch")
  end
  if type(coverage.opcodes) ~= "table" then
    invalid("script member coverage opcodes are missing")
  end
  if type(coverage.scripts) ~= "table" or #coverage.scripts ~= #expected then
    invalid("script member coverage scripts are invalid")
  end
  local expectedById = {}
  for _, entry in ipairs(expected) do
    expectedById[entry.id] = entry
  end
  local seen = {}
  for _, entry in ipairs(coverage.scripts) do
    if type(entry) ~= "table" or type(entry.publicId) ~= "string" then
      invalid("script member coverage identity is invalid")
    end
    if seen[entry.publicId] then
      invalid("script member coverage contains a duplicate resource")
    end
    local planned = expectedById[entry.publicId]
    if type(planned) ~= "table" then
      invalid("script member coverage resource is not in the plan")
    end
    local sourceId = string.format("hgss.scr_seq.%04d.%03d", memberId, planned.scriptIndex)
    if entry.sourceId ~= sourceId then
      invalid("script member coverage source identity mismatch")
    end
    seen[entry.publicId] = true
  end
end

-- The compiler-supplied dependency facts are mandatory staging input: the
-- writer validates and emits them but never recomputes them, so a compiler
-- contract defect fails loudly instead of hiding behind a repaired member.
local function isDependencyFacts(value)
  return type(value) == "table"
    and isSortedUniqueStrings(value.audioSequences)
    and isSortedUniqueStrings(value.scriptTargets)
    and isAssetNeedKeys(value.assetNeeds)
end

local function validateMember(plan, member)
  local planned = memberFor(plan, member.memberId)
  if member.marker ~= planned.marker then
    Errors.raise("SCRIPT_MEMBER_INVALID", "script member marker mismatch", { memberId = member.memberId })
  end
  if type(member.coverage) ~= "table" then
    Errors.raise("SCRIPT_MEMBER_INVALID", "script member coverage is missing", { memberId = member.memberId })
  end
  local expected = plannedScripts(plan, member.memberId)
  if #expected ~= #member.resources then
    Errors.raise("SCRIPT_MEMBER_INVALID", "script member resource count mismatch", { memberId = member.memberId })
  end
  local seen = {}
  for _, entry in ipairs(member.resources) do
    if type(entry.id) ~= "string" or seen[entry.id] then
      Errors.raise("SCRIPT_MEMBER_INVALID", "script member resource identity is invalid", {
        memberId = member.memberId,
      })
    end
    seen[entry.id] = true
    local found
    for _, candidate in ipairs(expected) do
      if candidate.id == entry.id and candidate.scriptIndex == entry.scriptIndex then
        found = candidate
        break
      end
    end
    if found == nil then
      Errors.raise("SCRIPT_MEMBER_INVALID", "script member resource is not in the plan", {
        memberId = member.memberId,
        id = entry.id,
      })
    end
    if type(entry.resource) ~= "table" or entry.resource.id ~= entry.id then
      Errors.raise("SCRIPT_MEMBER_INVALID", "script member resource is malformed", {
        memberId = member.memberId,
        id = entry.id,
      })
    end
    if not isDependencyFacts(entry.directDependencies) then
      Errors.raise("SCRIPT_MEMBER_INVALID", "script member resource dependency metadata is missing", {
        memberId = member.memberId,
        id = entry.id,
      })
    end
  end
  validateCoverage(plan, member.memberId, member.coverage)
end

-- A published member bundle must hold exactly the planned resources in source
-- order, each carrying the generated discriminator, its compact direct
-- dependency facts and the member coverage record. Returns true, or nil plus
-- the cause.
---@param plan table<string, unknown>
---@param memberId integer
---@param bundle unknown
---@return true|nil
---@return string|nil
local function checkMemberBundle(plan, memberId, bundle)
  if type(bundle) ~= "table" or bundle.schema ~= ScriptCache.MEMBER_SCHEMA then
    return nil, "script member " .. tostring(memberId) .. " bundle is not current"
  end
  if not Validate.isArray(bundle.scripts) then
    return nil, "script member " .. tostring(memberId) .. " bundle has no script array"
  end
  local expected = plannedScripts(plan, memberId)
  if #bundle.scripts ~= #expected then
    return nil, "script member " .. tostring(memberId) .. " bundle script count mismatch"
  end
  if type(bundle.direct) ~= "table" then
    return nil, "script member " .. tostring(memberId) .. " bundle has no dependency facts"
  end
  for position, planned in ipairs(expected) do
    local script = bundle.scripts[position]
    if type(script) ~= "table" or script.id ~= planned.id then
      return nil, "script member " .. tostring(memberId) .. " bundle resource identity mismatch"
    end
    if type(script.metadata) ~= "table" or script.metadata.generated ~= true then
      return nil, "script member " .. tostring(memberId) .. " bundle resource is not a generated base"
    end
    if not isDependencyFacts(bundle.direct[planned.scriptIndex]) then
      return nil, "script member " .. tostring(memberId) .. " bundle dependency facts are unusable"
    end
  end
  local coverageOk, coverageErr = pcall(validateCoverage, plan, memberId, bundle.coverage)
  if not coverageOk then
    return nil, "script member " .. tostring(memberId) .. " bundle coverage is unusable: " .. tostring(coverageErr)
  end
  return true
end

-- Read one published member bundle once: the module must parse under the
-- restricted generated environment and satisfy its planned shape.
---@param cacheFs CacheFs
---@param plan table<string, unknown>
---@param memberId integer
---@return table<string, unknown>|nil
---@return string|nil
local function readMemberBundle(cacheFs, plan, memberId)
  local ok, bundle = pcall(cacheFs.loadModule, cacheFs, ScriptCache.memberPath(plan.generationKey, memberId))
  if not ok then
    return nil, "script member " .. tostring(memberId) .. " bundle is unreadable: " .. tostring(bundle)
  end
  local valid, reason = checkMemberBundle(plan, memberId, bundle)
  if not valid then
    return nil, reason
  end
  return bundle --[[@as table<string, unknown>]]
end

-- A staging handle is a worker-owned preparation, never a live cache: the
-- member writer rejects anything without a private stage before any file
-- write, so an active generation can never be edited in place.
local function assertArtifact(artifact, operation)
  if
    type(artifact) ~= "table"
    or type(artifact.stageFs) ~= "function"
    or type(artifact.cacheFs) ~= "function"
    or type(artifact.addOwnedRoot) ~= "function"
  then
    Errors.raise("SCRIPT_MEMBER_INVALID", operation .. " requires a PreparedArtifact", {})
  end
end

-- The one staging step every member entry point shares: validate the compiled
-- payload against the plan, emit the whole member once, write that one bundle
-- into the given stage filesystem, and prove it reads back with the current
-- identity. Never touches a sibling member or the live cache.
local function persistMember(stage, plan, member)
  validateMember(plan, member)
  local path = ScriptCache.memberPath(plan.generationKey, member.memberId)
  stage:removeTree(path)
  stage:write(path, LuaEmitter.emitMember(member))
  local bundle = stage:loadModule(path)
  local valid, reason = checkMemberBundle(plan, member.memberId, bundle)
  if not valid then
    Errors.raise("SCRIPT_MEMBER_READBACK_FAILED", tostring(reason), { memberId = member.memberId })
  end
  return member.marker
end

-- Stage one compiled member through a caller-owned prepared artifact: the
-- stage owns exactly this member's bundle, so member jobs never overlap and a
-- private repair of an already selected generation never touches live files.
-- Publication stays with the caller; a stage failure leaves the previous live
-- member untouched once the caller aborts the disposable stage.
---@param artifact PreparedArtifact
---@param plan { generationKey: string, marker: string, version: string, sourcePath: string, romSha1: string, dependencies: table<string, unknown>, memberCount: integer, members: unknown[], resources: unknown[], skippedMembers: integer[]|nil, index: table<string, unknown>|nil }
---@param member { memberId: integer, marker: string, coverage: table<string, unknown>, resources: unknown[] }
---@return string
function ScriptCacheWriter.stageMember(artifact, plan, member)
  assertArtifact(artifact, "stageMember")
  assert(type(plan) == "table" and type(member) == "table", "stageMember requires a plan and member")
  artifact:addOwnedRoot(ScriptCache.memberPath(plan.generationKey, member.memberId))
  return persistMember(artifact:stageFs(), plan, member)
end

local function orderedMembers(plan)
  local ordered = {}
  for _, member in ipairs(plan.members) do
    ordered[#ordered + 1] = member
  end
  table.sort(ordered, function(a, b)
    return a.memberId < b.memberId
  end)
  return ordered
end

local function checkPlan(plan)
  assert(type(plan) == "table" and type(plan.generationKey) == "string", "script generation plan is required")
  assert(
    type(plan.marker) == "string" and type(plan.members) == "table",
    "script generation plan identity is incomplete"
  )
  local skippedMembers = plan.skippedMembers or {}
  assert(type(plan.resources) == "table", "script generation resources are missing")
  assert(plan.memberCount == #plan.members + #skippedMembers, "script generation member coverage is incomplete")
  local expectedIndex = {
    schema = ScriptCache.INDEX_SCHEMA,
    version = plan.version,
    generation = plan.generationKey,
    marker = plan.marker,
    memberCount = plan.memberCount,
    scriptMemberCount = #plan.members,
    skippedMemberCount = #skippedMembers,
    scriptCount = #plan.resources,
    resourceCount = #plan.resources,
    resources = {},
  }
  for _, entry in ipairs(plan.resources) do
    expectedIndex.resources[#expectedIndex.resources + 1] = {
      id = entry.id,
      member = entry.member,
      scriptIndex = entry.scriptIndex,
    }
  end
  if plan.index ~= nil then
    assert(plan.index.schema == expectedIndex.schema, "script generation index schema mismatch")
    for _, key in ipairs({
      "version",
      "generation",
      "marker",
      "memberCount",
      "scriptMemberCount",
      "skippedMemberCount",
      "scriptCount",
      "resourceCount",
    }) do
      assert(plan.index[key] == expectedIndex[key], "script generation plan identity mismatch: " .. key)
    end
    assert(
      type(plan.index.resources) == "table" and #plan.index.resources == #expectedIndex.resources,
      "script generation resource plan mismatch"
    )
    for index, entry in ipairs(expectedIndex.resources) do
      local actual = plan.index.resources[index]
      assert(
        type(actual) == "table"
          and actual.id == entry.id
          and actual.member == entry.member
          and actual.scriptIndex == entry.scriptIndex,
        "script generation resource plan identity mismatch"
      )
    end
  end
  return expectedIndex
end

-- The transitive union of per-script symbol sets over the script-target
-- graph (a fixed point, so cycles converge), aggregated per member as sorted
-- unique arrays keyed by decimal member id. Members with no symbols carry an
-- explicit empty array.
---@param plan table<string, unknown>
---@param memberOf table<string, integer> member id by resource id
---@param resourceIds string[] sorted resource ids
---@param directById table<string, string[]> direct symbols by resource id
---@param directTargets table<string, string[]> direct script targets by resource id
---@return table<string, string[]>
local function memberClosure(plan, memberOf, resourceIds, directById, directTargets)
  local closure = {}
  for _, id in ipairs(resourceIds) do
    local seen = {}
    for _, symbol in ipairs(directById[id]) do
      seen[symbol] = true
    end
    closure[id] = seen
  end
  local changed = true
  while changed do
    changed = false
    for _, id in ipairs(resourceIds) do
      local seen = closure[id]
      for _, target in ipairs(directTargets[id]) do
        for symbol in pairs(closure[target]) do
          if seen[symbol] == nil then
            seen[symbol] = true
            changed = true
          end
        end
      end
    end
  end
  local byMember = {}
  for _, member in ipairs(orderedMembers(plan)) do
    byMember[tostring(member.memberId)] = {}
  end
  for _, id in ipairs(resourceIds) do
    local union = byMember[tostring(memberOf[id])]
    for symbol in pairs(closure[id]) do
      union[symbol] = true
    end
  end
  for key, union in pairs(byMember) do
    local list = {}
    for symbol in pairs(union) do
      list[#list + 1] = symbol
    end
    table.sort(list)
    byMember[key] = list
  end
  return byMember
end

-- Join every planned resource's embedded direct dependency facts into the
-- generation index and its transitive per-member closures: each current
-- member bundle must describe exactly its planned resources, so the published
-- index describes precisely the current member bodies with no missing, extra,
-- or duplicate records, and every declared cross-script target must resolve
-- to a planned resource before a deterministic fixed point unions each
-- resource's direct audio with its targets' closures (cycles converge because
-- iteration only grows sets over a sorted resource order), aggregated per
-- member as sorted unique arrays keyed by decimal member id.
local function joinMemberMetadata(plan, expectedIndex, bundles, coverageRecords)
  local directAudio, directNeeds, directTargets, memberOf = {}, {}, {}, {}
  for _, entry in ipairs(plan.resources) do
    memberOf[entry.id] = entry.member
  end
  for _, member in ipairs(orderedMembers(plan)) do
    local bundle = bundles[member.memberId]
    for _, entry in ipairs(plannedScripts(plan, member.memberId)) do
      local direct = bundle.direct[entry.scriptIndex]
      directAudio[entry.id] = direct.audioSequences
      directNeeds[entry.id] = direct.assetNeeds
      directTargets[entry.id] = direct.scriptTargets
    end
    coverageRecords[#coverageRecords + 1] = bundle.coverage
  end
  local resourceIds = {}
  for _, entry in ipairs(plan.resources) do
    resourceIds[#resourceIds + 1] = entry.id
  end
  table.sort(resourceIds)
  for _, id in ipairs(resourceIds) do
    for _, target in ipairs(directTargets[id]) do
      if memberOf[target] == nil then
        Errors.raise("SCRIPT_SUMMARY_INCOMPLETE", "script summary refuses an unknown script target: " .. target, {
          generation = plan.generationKey,
          id = id,
        })
      end
    end
  end
  expectedIndex.memberAudioSequences = memberClosure(plan, memberOf, resourceIds, directAudio, directTargets)
  expectedIndex.memberAssetNeeds = memberClosure(plan, memberOf, resourceIds, directNeeds, directTargets)
end

-- Proves one planned member is usable in the live cache: its bundle reads
-- back under the current member schema with the planned resources in source
-- order, their generated discriminator, their compact dependency facts and
-- its coverage record. This is the same proof the generation summary demands
-- of every member before staging, exposed so readiness checks cannot drift
-- from it.
---@param cacheFs CacheFs
---@param plan { generationKey: string, members: unknown[], resources: unknown[] }
---@param memberId integer|string
---@return boolean
---@return string|nil
function ScriptCacheWriter.isMemberReady(cacheFs, plan, memberId)
  assert(cacheFs and cacheFs.read and cacheFs.loadLua, "script member readiness requires a cache filesystem")
  assert(type(plan) == "table", "script member readiness requires the generation plan")
  local id = assert(tonumber(memberId), "script member readiness requires a member identity") --[[@as integer]]
  local found, member = pcall(memberFor, plan, id)
  if not found or type(member) ~= "table" then
    return false, "unknown planned script member: " .. tostring(memberId)
  end
  local bundle, reason = readMemberBundle(cacheFs, plan, id)
  if bundle == nil then
    return false, reason
  end
  return true
end

-- The one staging step every summary entry point shares: prove every planned
-- member is current in the live cache, read each published bundle once to
-- join its dependency facts and coverage record, then write the single active
-- index and the one aggregate coverage report into the stage. Member bundles
-- are never staged here, so the summary cannot erase independently published
-- members.
local function persistSummary(stage, liveFs, plan)
  local expectedIndex = checkPlan(plan)
  local missing = {}
  local bundles = {}
  for _, member in ipairs(orderedMembers(plan)) do
    local bundle = readMemberBundle(liveFs, plan, member.memberId)
    if bundle == nil then
      missing[#missing + 1] = member.memberId
    else
      bundles[member.memberId] = bundle
    end
  end
  if #missing > 0 then
    Errors.raise("SCRIPT_SUMMARY_INCOMPLETE", "script summary refuses incomplete member coverage", {
      generation = plan.generationKey,
      missingMemberIds = missing,
    })
  end
  local coverageRecords = {}
  joinMemberMetadata(plan, expectedIndex, bundles, coverageRecords)
  local report = Coverage.markdown(Coverage.aggregate(coverageRecords))
  stage:writeLua(ScriptCache.activeIndexPath(), expectedIndex)
  stage:write(ScriptCache.coverageReportPath(), report)
  local stagedIndex = stage:loadLua(ScriptCache.activeIndexPath())
  if
    type(stagedIndex) ~= "table"
    or stagedIndex.schema ~= ScriptCache.INDEX_SCHEMA
    or stagedIndex.generation ~= plan.generationKey
    or stagedIndex.marker ~= plan.marker
  then
    Errors.raise("SCRIPT_SUMMARY_READBACK_FAILED", "script summary index readback failed", {
      generation = plan.generationKey,
    })
  end
  local stagedReport = stage:read(ScriptCache.coverageReportPath())
  if type(stagedReport) ~= "string" or stagedReport == "" then
    Errors.raise("SCRIPT_SUMMARY_READBACK_FAILED", "script summary coverage readback failed", {
      generation = plan.generationKey,
    })
  end
  return plan.marker
end

-- Stage the generation summary through a caller-owned prepared artifact: the
-- stage owns exactly the active selection directory, never the member
-- bundles. Publication stays with the caller; a summary failure leaves the
-- previous active selection usable for its old identity.
---@param artifact PreparedArtifact
---@param plan { generationKey: string, marker: string, version: string, sourcePath: string, romSha1: string, dependencies: table<string, unknown>, memberCount: integer, members: unknown[], resources: unknown[], skippedMembers: integer[]|nil, index: table<string, unknown>|nil }
---@return string
function ScriptCacheWriter.stageSummary(artifact, plan)
  assertArtifact(artifact, "stageSummary")
  assert(type(plan) == "table", "stageSummary requires a generation plan")
  artifact:addOwnedRoot(ScriptCache.activeDir())
  return persistSummary(artifact:stageFs(), artifact:cacheFs(), plan)
end

-- Publish the generation summary straight into the live cache for the batch
-- build. Refuses while any planned member is unpublished; raises like every
-- other writer boundary.
---@param cacheFs CacheFs
---@param plan { generationKey: string, marker: string, version: string, sourcePath: string, romSha1: string, dependencies: table<string, unknown>, memberCount: integer, members: unknown[], resources: unknown[], skippedMembers: integer[]|nil, index: table<string, unknown>|nil }
---@return string
function ScriptCacheWriter.writeSummary(cacheFs, plan)
  assert(cacheFs and cacheFs.writeLua, "writeSummary requires a cache")
  assert(type(plan) == "table" and type(plan.generationKey) == "string", "writeSummary requires a generation plan")
  local tx = ArtifactPublisher.begin(cacheFs, "scripts", {
    ScriptCache.activeDir(),
  })
  local ok, result = pcall(persistSummary, tx.stage, cacheFs, plan)
  if not ok then
    tx:abort()
    error(result, 0)
  end
  tx:publish()
  return result
end

-- Retire superseded script generation directories. Only exact lowercase
-- hexadecimal generation directory names that are verified directories are
-- eligible; the protected active generation, unknown names, plain files,
-- and anything outside the generations root survive. A failed listing
-- propagates instead of reading as an empty directory.
---@param name string
---@return boolean
local function isRetirableGenerationName(name)
  return type(name) == "string" and #name == 40 and name:match("^[0-9a-f]+$") ~= nil
end

function ScriptCacheWriter.cleanupGenerations(cacheFs, keepSet)
  local protected = {}
  for generation in pairs(keepSet or {}) do
    protected[generation] = true
  end
  local active = cacheFs:loadLua(ScriptCache.activeIndexPath())
  if type(active) == "table" and type(active.generation) == "string" then
    protected[active.generation] = true
  end
  local names = cacheFs:getDirectoryItems(ScriptCache.generationsDir())
  for _, generation in ipairs(names) do
    if not protected[generation] and isRetirableGenerationName(generation) then
      local info = cacheFs:getInfo(ScriptCache.generationDir(generation))
      if info ~= nil and info.type == "directory" then
        cacheFs:removeTree(ScriptCache.generationDir(generation))
      end
    end
  end
  return true
end

return ScriptCacheWriter
