-- Version-scoped retirement of superseded derived-cache data. One narrow
-- producer-side owner for reclaiming unreachable content-addressed shared
-- files only after every canonical job proves its current receipt plus its matching shared-reference
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
