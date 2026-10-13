-- Version-scoped retirement of superseded derived-cache data. One narrow
-- producer-side owner for two one-time operations: converting already-digested
-- generated files to their canonical compact physical form without recompiling
-- them and removing the superseded extracted source dump only when the
-- remaining cache stays usable or a matching original source is verified, and
-- reclaiming unreachable content-addressed shared files only after every
-- canonical job proves its current receipt plus its matching shared-reference
-- sidecar while no reader or worker is active. Saves, mods, other versions,
-- staging areas, and unknown files are never traversed. Every destructive
-- step is gated on full proof; any uncertainty skips the destructive pass and
-- reports its reason, leaving gameplay on the current cache untouched.

local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
local ArtifactState = require("romdump.src.build.ArtifactState")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
local StorageErrors = require("libs.storage.src.errors")

local CacheMaintenance = {}

-- Filesystems that can host the retirement pass expose the full maintenance
-- capability set. Anything narrower (in particular a test double) must skip
-- the pass: maintenance never mistakes a partial double for a version cache.
local MAINTENANCE_METHODS = {
  "recoverPublication",
  "getDirectoryItems",
  "getInfo",
  "transcode",
  "remove",
  "removeTree",
  "writeLua",
  "replace",
  "loadLua",
  "read",
  "exists",
}

---@param cacheFs unknown
---@return boolean
function CacheMaintenance.canMaintain(cacheFs)
  if type(cacheFs) ~= "table" then
    return false
  end
  ---@cast cacheFs table<string, unknown>
  if type(cacheFs.versionId) ~= "string" then
    return false
  end
  for _, method in ipairs(MAINTENANCE_METHODS) do
    if type(cacheFs[method]) ~= "function" then
      return false
    end
  end
  return true
end

CacheMaintenance.MIGRATION_MARKER = "data/generated/storage-migrated.lua"
CacheMaintenance.MIGRATION_SCHEMA = 1
CacheMaintenance.PHYSICAL_FORMAT = 1

local MARKER_WRITING_PATH = "data/generated/storage-migrated.next.lua"

-- Exact historical source-only paths removed after a safe migration. The
-- generated parents stay: they carry real digested outputs.
local LEGACY_TREES = { "romfs", "system" }
local LEGACY_FILES = {
  "data/generated/rom_metadata.lua",
  "data/generated/romfs_index.lua",
  "data/generated/overlay_index.lua",
  "rom-dump.complete",
}

-- Version-root entries migration never walks into. The source binding stays
-- readable so a later miss can ask for its ROM; saves and mods are user data.
local EXCLUDED_TOP_DIRS = {
  romfs = true,
  system = true,
  mods = true,
  saves = true,
  staging = true,
}

-- The only shared roots collection may delete from: every exact root current
-- producers register through shared-file publication. Map geometry, map
-- textures, model descriptors, audio samples, and sample metadata each carry
-- hashed content-addressed basenames; anything else on disk is preserved.
local KNOWN_SHARED_ROOTS = {
  "assets/generated/maps/geometry",
  "assets/generated/maps/textures",
  "data/generated/models",
  "data/generated/audio/samples",
  "data/generated/audio/sample-metadata",
}

---@param marker unknown
---@return boolean
local function isMigrationComplete(marker)
  if type(marker) ~= "table" then
    return false
  end
  ---@cast marker table<string, unknown>
  local count = 0
  for _ in pairs(marker) do
    count = count + 1
  end
  return count == 2
    and marker.schema == CacheMaintenance.MIGRATION_SCHEMA
    and marker.physicalFormat == CacheMaintenance.PHYSICAL_FORMAT
end

---@param name string
---@return boolean
local function isScratchName(name)
  return name:find(".__g4", 1, true) ~= nil
end

---@param cacheFs CacheFs
---@param directory string
---@param out string[]
local function walkGenerated(cacheFs, directory, out)
  local items = cacheFs:getDirectoryItems(directory)
  assert(type(items) == "table", "migration walk requires its directory listing")
  for _, name in ipairs(items) do
    if not isScratchName(name) then
      local path = directory == "" and name or directory .. "/" .. name
      if directory == "" and (EXCLUDED_TOP_DIRS[name] or name == "rom-dump.complete") then
        -- Never traversed here: raw dump trees, user data, staging, and the
        -- legacy marker, which is removed only through the gate below.
      else
        local info = cacheFs:getInfo(path)
        assert(info ~= nil, "migration walk lost a listed path: " .. path)
        if info.type == "directory" then
          walkGenerated(cacheFs, path, out)
        elseif path ~= CacheMaintenance.MIGRATION_MARKER and path ~= MARKER_WRITING_PATH then
          out[#out + 1] = path
        end
      end
    end
  end
end

---@param cacheFs CacheFs
---@param files string[]
---@return integer
local function physicalBytes(cacheFs, files)
  local total = 0
  for _, path in ipairs(files) do
    local info = cacheFs:getInfo(path)
    if info ~= nil and type(info.size) == "number" then
      total = total + info.size
    end
  end
  return total
end

-- Convert every eligible generated file to its canonical physical form and,
-- once conversion and the usability gate both pass, remove the superseded
-- source dump and record completion last. Any conversion fault surfaces with
-- the dump retained and no marker; a blocked gate retains the dump, reports
-- why, and writes no marker. A run that finds a valid marker converts
-- nothing.
---@param versionId string
---@param cacheFs CacheFs
---@param eligibility { completeCacheUsable: boolean, verifiedReopenableSource: boolean }
---@return { changedCount: integer, bytesBefore: integer, bytesAfter: integer, rawRemoved: boolean, blockedReason?: string }
function CacheMaintenance.migrateLegacy(versionId, cacheFs, eligibility)
  assert(type(versionId) == "string" and versionId ~= "", "migration requires a version")
  assert(cacheFs ~= nil and cacheFs.versionId == versionId, "migration requires the matching version cache")
  assert(type(eligibility) == "table", "migration requires its source eligibility")
  cacheFs:recoverPublication()
  cacheFs:remove(MARKER_WRITING_PATH)
  if isMigrationComplete(cacheFs:loadLua(CacheMaintenance.MIGRATION_MARKER)) then
    return { changedCount = 0, bytesBefore = 0, bytesAfter = 0, rawRemoved = false }
  end
  local files = {}
  if cacheFs:getInfo("") ~= nil then
    walkGenerated(cacheFs, "", files)
  end
  table.sort(files)
  local bytesBefore = physicalBytes(cacheFs, files)
  local changedCount = 0
  for _, path in ipairs(files) do
    if cacheFs:transcode(path) == "changed" then
      changedCount = changedCount + 1
    end
  end
  local bytesAfter = physicalBytes(cacheFs, files)
  if eligibility.completeCacheUsable ~= true and eligibility.verifiedReopenableSource ~= true then
    return {
      changedCount = changedCount,
      bytesBefore = bytesBefore,
      bytesAfter = bytesAfter,
      rawRemoved = false,
      blockedReason = "legacy source dump retained: no complete usable cache and no verified reopenable source",
    }
  end
  for _, tree in ipairs(LEGACY_TREES) do
    cacheFs:removeTree(tree)
  end
  for _, path in ipairs(LEGACY_FILES) do
    cacheFs:remove(path)
  end
  cacheFs:writeLua(MARKER_WRITING_PATH, {
    schema = CacheMaintenance.MIGRATION_SCHEMA,
    physicalFormat = CacheMaintenance.PHYSICAL_FORMAT,
  })
  cacheFs:replace(MARKER_WRITING_PATH, CacheMaintenance.MIGRATION_MARKER)
  return {
    changedCount = changedCount,
    bytesBefore = bytesBefore,
    bytesAfter = bytesAfter,
    rawRemoved = true,
  }
end

---@param path string
---@return string? shared root the path lives strictly inside
local function sharedRootFor(path)
  for _, root in ipairs(KNOWN_SHARED_ROOTS) do
    if path:sub(1, #root + 1) == root .. "/" then
      local rest = path:sub(#root + 2)
      if rest ~= "" and not rest:find("/", 1, true) then
        return root
      end
    end
  end
  return nil
end

---@param root string
---@param name string
---@return boolean
local function isHashedSharedName(root, name)
  if root == "assets/generated/maps/geometry" then
    return name:match("^[0-9a-fA-F]+%.g4mesh$") ~= nil and #name == 40 + #".g4mesh"
  end
  if root == "assets/generated/maps/textures" then
    return name:match("^[0-9a-fA-F]+%.png$") ~= nil and #name == 40 + #".png"
  end
  if root == "data/generated/models" or root == "data/generated/audio/sample-metadata" then
    return name:match("^[%w][%w%.%-_]*%.lua$") ~= nil
  end
  if root == "data/generated/audio/samples" then
    return name:match("^[%w][%w%.%-_]*%.pcm16le$") ~= nil
  end
  return false
end

---@param path string
---@return boolean
local function isCollectableSharedPath(path)
  local root = sharedRootFor(path)
  if root == nil then
    return false
  end
  return isHashedSharedName(root, path:sub(#root + 2))
end

---@param cacheFs CacheFs
---@param generationId string
---@param kind string
---@param key string
---@return table<string, unknown>? sidecar record
---@return string? skip reason when the proof is absent or invalid
local function readValidSidecar(cacheFs, generationId, kind, key)
  local pathOk, pathOrErr = pcall(PreparedArtifact.sidecarPath, kind, key)
  if not pathOk then
    return nil, "shared proof path is not provable for " .. kind .. ":" .. key
  end
  local record, loadErr = cacheFs:loadLua(pathOrErr)
  if record == nil then
    if type(loadErr) == "table" and loadErr.code == StorageErrors.CACHE_FILE_MISSING then
      return nil, "shared proof is missing for " .. kind .. ":" .. key
    end
    return nil, "shared proof is malformed for " .. kind .. ":" .. key
  end
  local valid, reason =
    PreparedArtifact.validateSidecarRecord(record, { generationId = generationId, kind = kind, key = key })
  if not valid then
    return nil, "shared proof is not current for " .. kind .. ":" .. key .. ": " .. tostring(reason)
  end
  ---@cast record table<string, unknown>
  return record, nil
end

---@param publishedPlans table<string, unknown>
---@return { kind: string, key: string, jobKey: string }[]
local function drainRoster(publishedPlans)
  local iterate = ArtifactJobs.completeIterator(publishedPlans)
  local roster = {}
  while true do
    local job = iterate()
    if job == nil then
      break
    end
    assert(type(job) == "table", "complete roster carries no job")
    assert(type(job.kind) == "string" and job.kind ~= "", "complete roster job carries no kind")
    assert(type(job.key) == "string" and job.key ~= "", "complete roster job carries no key")
    roster[#roster + 1] = job
  end
  assert(#roster > 0, "complete roster is empty")
  return roster
end

---@param cacheFs CacheFs
---@param root string
---@param out string[]
local function listSharedFiles(cacheFs, root, out)
  local info = cacheFs:getInfo(root)
  if info == nil then
    return
  end
  assert(info.type == "directory", "shared root is not a directory: " .. root)
  local function walk(directory)
    local items = cacheFs:getDirectoryItems(directory)
    assert(type(items) == "table", "shared collection requires its directory listing")
    for _, name in ipairs(items) do
      local path = directory .. "/" .. name
      local entry = cacheFs:getInfo(path)
      assert(entry ~= nil, "shared collection lost a listed path: " .. path)
      if entry.type == "directory" then
        walk(path)
      elseif entry.type == "file" then
        out[#out + 1] = path
      end
    end
  end
  walk(root)
end

---@param reason string
---@return { status: string, reason: string }
local function skipped(reason)
  return { status = "skipped", reason = reason }
end

-- Reclaim unreachable shared files only after the entire canonical roster
-- proves its current receipt plus its matching sidecar with no active
-- readers or workers. Any missing, stale, or malformed proof, any
-- unexpected reference, any partial roster, or any enumeration fault skips
-- the whole pass with zero deletes. Deletion faults surface and leave the
-- remaining candidates for retry; collection is never reported done after
-- an incomplete removal.
---@param cacheFs CacheFs
---@param identity { generationId: string }
---@param publishedPlans table<string, unknown>
---@param quiescent boolean
---@return { status: string, reason?: string, removedCount?: integer, reclaimedBytes?: integer }
function CacheMaintenance.collectShared(cacheFs, identity, publishedPlans, quiescent)
  assert(cacheFs ~= nil and cacheFs.versionId ~= nil, "shared collection requires a version cache")
  if quiescent ~= true then
    return skipped("shared collection requires a quiescent cache: readers or workers are active")
  end
  if type(identity) ~= "table" or type(identity.generationId) ~= "string" or identity.generationId == "" then
    return skipped("shared collection requires its current generation identity")
  end
  if type(publishedPlans) ~= "table" then
    return skipped("shared collection requires its validated published plans")
  end
  local generationId = identity.generationId
  local rosterOk, rosterOrErr = pcall(drainRoster, publishedPlans)
  if not rosterOk then
    return skipped("complete job roster is not provable: " .. tostring(rosterOrErr))
  end
  local roster = assert(rosterOrErr, "proven roster must be present") --[[@as { kind: string, key: string, jobKey: string }[] ]]
  local live = {}
  for _, job in ipairs(roster) do
    local receiptOk, receipt, receiptReason = pcall(ArtifactState.read, cacheFs, generationId, job.kind, job.key)
    if not receiptOk then
      return skipped("receipt proof is not readable for " .. job.kind .. ":" .. job.key)
    end
    if receipt == nil then
      return skipped("receipt is not current for " .. job.kind .. ":" .. job.key .. ": " .. tostring(receiptReason))
    end
    local sidecar, sidecarReason = readValidSidecar(cacheFs, generationId, job.kind, job.key)
    if sidecar == nil then
      return skipped(assert(sidecarReason, "sidecar rejection must name its reason"))
    end
    local paths = assert(sidecar.paths, "validated sidecar carries its paths") --[[@as string[] ]]
    for _, path in ipairs(paths) do
      if type(path) ~= "string" or not isCollectableSharedPath(path) then
        return skipped("shared proof references an unexpected path for " .. job.kind .. ":" .. job.key)
      end
      live[path] = true
    end
  end
  local candidates = {}
  local listOk, listErr = pcall(function()
    for _, root in ipairs(KNOWN_SHARED_ROOTS) do
      listSharedFiles(cacheFs, root, candidates)
    end
  end)
  if not listOk then
    return skipped("shared roots are not enumerable: " .. tostring(listErr))
  end
  table.sort(candidates)
  local removedCount, reclaimedBytes = 0, 0
  for _, path in ipairs(candidates) do
    if not live[path] and isCollectableSharedPath(path) then
      local info = cacheFs:getInfo(path)
      local size = (info ~= nil and type(info.size) == "number") and info.size or 0
      cacheFs:remove(path)
      removedCount = removedCount + 1
      reclaimedBytes = reclaimedBytes + size
    end
  end
  return { status = "collected", removedCount = removedCount, reclaimedBytes = reclaimedBytes }
end

return CacheMaintenance
