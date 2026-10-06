-- Empty mons buckets for production-composition tests. Buckets carry no
-- catalog identity: the live mon service restores them against the
-- generated catalog at runtime. Fakes build the required bucket through
-- this helper instead of synthesizing one.

local CacheFs = require("libs.storage.src.CacheFs")
local MonCache = require("libs.assets.src.MonCache")
local MonCatalog = require("libs.mons.src.MonCatalog")
local ItemCache = require("libs.assets.src.ItemCache")
local ItemCatalog = require("libs.items.src.ItemCatalog")
local MonsSave = require("libs.mons.src.MonsSave")

local MonBucket = {}

-- One load of the version catalog pair behind mon and item composition.
-- Callers share the returned catalogs instead of parsing cache files per
-- call site.
---@param versionId string
---@return MonCatalog, ItemCatalog
function MonBucket.openCatalogs(versionId)
  local cacheFs = CacheFs.forVersion(versionId)
  local items = ItemCatalog.new(ItemCache.loadCatalog(cacheFs))
  return MonCatalog.new(MonCache.loadCatalog(cacheFs), items), items
end

---@param versionId string
---@param seedU32 integer?
---@return table
function MonBucket.emptyForVersion(versionId, seedU32)
  assert(type(versionId) == "string", "empty buckets are version-scoped")
  return MonsSave.empty(seedU32 or 7)
end

return MonBucket
