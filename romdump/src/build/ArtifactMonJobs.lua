-- Mon-family artifact jobs bind existing compilers and cache writers to the central worker protocol.
local ArtifactMonJobs = {}

---@param romFs table<string, unknown>
---@return table<string, unknown> catalog
local function compileCatalog(romFs)
  local MonCatalogCompiler = require("romdump.src.digest.mons.MonCatalogCompiler")
  local catalog, catalogErr = MonCatalogCompiler.compileCatalog(romFs)
  if catalog == nil then
    error(catalogErr, 0)
  end
  return catalog
end

---@param romFs table<string, unknown>
---@param catalog table<string, unknown>
---@return table<string, unknown> presentation
local function planPresentation(romFs, catalog)
  local MonPresentationCompiler = require("romdump.src.digest.mons.MonPresentationCompiler")
  local presentation, presentationErr = MonPresentationCompiler.plan(romFs, catalog)
  if presentation == nil then
    error(presentationErr, 0)
  end
  return presentation
end

---@param key string canonical decimal job key
---@param what string key label for diagnostics
---@return integer
local function canonicalKeyId(key, what)
  local id = assert(tonumber(key), what .. " is not canonical")
  assert(type(id) == "number" and id % 1 == 0, what .. " is not canonical")
  return id --[[@as integer]]
end

---@param artifact table<string, unknown>
---@param context table<string, unknown>
---@return string
local function executeMonCatalog(artifact, context)
  local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
  local romFs = assert(context.romFs, "mon catalog jobs require a source reader")
  local catalog = compileCatalog(romFs)
  local romSha1 = romFs:metadata().sha1
  return MonCacheWriter.stageCatalog(artifact, {
    catalog = catalog,
    marker = MonCacheWriter.catalogMarker(romSha1, catalog),
  })
end

local function executeMonLayout(artifact, context, generationId)
  local MonCache = require("libs.assets.src.MonCache")
  local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
  local romFs = assert(context.romFs, "mon layout jobs require a source reader")
  local cacheFs = assert(context.cacheFs, "mon layout jobs require a cache filesystem")
  assert(type(generationId) == "string" and generationId ~= "", "mon layout jobs require a generation")
  local catalog = MonCache.loadCatalog(cacheFs)
  local presentation = planPresentation(romFs, catalog)
  local romSha1 = romFs:metadata().sha1
  return MonCacheWriter.stageLayout(artifact, {
    icons = presentation.icons,
    portraits = presentation.portraits,
    marker = MonCacheWriter.layoutMarker(romSha1, presentation.icons, presentation.portraits),
    pagePlans = { iconPages = presentation.iconPages, portraitPages = presentation.portraitPages },
    generationId = generationId,
  })
end

---@param artifact table<string, unknown>
---@param context table<string, unknown>
---@param pageKind "icons"|"portraits"
---@param pageId integer
---@param generationId string
---@return string
local function executeMonPage(artifact, context, pageKind, pageId, generationId)
  local MonCache = require("libs.assets.src.MonCache")
  local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
  local MonPresentationCompiler = require("romdump.src.digest.mons.MonPresentationCompiler")
  local MonAssetSchema = require("libs.assets.src.MonAssetSchema")
  local romFs = assert(context.romFs, "mon page jobs require a source reader")
  local cacheFs = assert(context.cacheFs, "mon page jobs require a cache filesystem")
  assert(type(generationId) == "string" and generationId ~= "", "mon page jobs require a generation")
  local layoutMarker = cacheFs:read(MonCache.layoutMarkerPath())
  if type(layoutMarker) ~= "string" or layoutMarker == "" then
    error("mon page " .. pageKind .. "/" .. tostring(pageId) .. " has no published layout", 0)
  end
  local pagePlan, planReason = MonCacheWriter.loadPagePlan(cacheFs, generationId, pageKind, pageId, layoutMarker)
  if pagePlan == nil then
    error("mon page " .. pageKind .. "/" .. tostring(pageId) .. " has no source plan: " .. tostring(planReason), 0)
  end
  local manifestPath = pageKind == "icons" and MonCache.iconManifestPath() or MonCache.portraitManifestPath()
  local manifestOk, manifest = pcall(cacheFs.loadLua, cacheFs, manifestPath)
  if not manifestOk or type(manifest) ~= "table" then
    error("mon page " .. pageKind .. "/" .. tostring(pageId) .. " has no published manifest", 0)
  end
  if pageKind == "icons" then
    local valid, schemaErr = pcall(MonAssetSchema.assertIconManifest, manifest)
    if not valid then
      error(schemaErr, 0)
    end
  else
    local valid, schemaErr = pcall(MonAssetSchema.assertPortraitManifest, manifest)
    if not valid then
      error(schemaErr, 0)
    end
  end
  local page, pageErr = MonPresentationCompiler.compilePage(romFs, pageKind, pagePlan)
  if page == nil then
    error(pageErr, 0)
  end
  local marker = MonCacheWriter.pageMarker(romFs:metadata().sha1, pageKind, pageId, manifest)
  return MonCacheWriter.stagePage(artifact, {
    kind = pageKind,
    pageId = pageId,
    width = page.width,
    height = page.height,
    pixels = page.pixels,
    marker = marker,
  })
end

---@param artifact table<string, unknown>
---@param context table<string, unknown>
---@return string
local function executeMonSummary(artifact, context)
  local Hashing = require("romdump.src.digest.Hashing")
  local MonSources = require("romdump.src.config.MonSources")
  local MonCache = require("libs.assets.src.MonCache")
  local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
  local MonAssetSchema = require("libs.assets.src.MonAssetSchema")
  local romFs = assert(context.romFs, "mon summary jobs require a source reader")
  local cacheFs = assert(context.cacheFs, "mon summary jobs require a cache filesystem")
  local catalog = MonCache.loadCatalog(cacheFs)
  local icons = cacheFs:loadLua(MonCache.iconManifestPath())
  MonAssetSchema.assertIconManifest(icons)
  local portraits = cacheFs:loadLua(MonCache.portraitManifestPath())
  MonAssetSchema.assertPortraitManifest(portraits)
  assert(icons ~= nil and portraits ~= nil, "mon summary requires its published manifests")
  local iconMarkers, portraitMarkers = {}, {}
  for _, pageId in ipairs(icons.pageIds) do
    local marker = cacheFs:read(MonCache.pageMarkerPath("icons", pageId))
    if type(marker) ~= "string" or marker == "" then
      error("mon summary misses the staged icon page " .. tostring(pageId), 0)
    end
    iconMarkers[#iconMarkers + 1] = marker
  end
  for _, pageId in ipairs(portraits.pageIds) do
    local marker = cacheFs:read(MonCache.pageMarkerPath("portraits", pageId))
    if type(marker) ~= "string" or marker == "" then
      error("mon summary misses the staged portrait page " .. tostring(pageId), 0)
    end
    portraitMarkers[#portraitMarkers + 1] = marker
  end
  local index = MonCacheWriter.buildIndex(catalog.version, Hashing.hashLua(catalog), iconMarkers, portraitMarkers)
  return MonCacheWriter.stageSummary(artifact, index, {
    schema = "g4-mon-provenance-v1",
    source = MonSources.provenance,
    rom = { version = catalog.version.id, sha1 = romFs:metadata().sha1 },
  })
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateMonCatalog(check)
  local MonCache = require("libs.assets.src.MonCache")
  return MonCache.isCatalogReady(check.cacheFs, check.marker)
end

---@return { kind: string, key: string }[], boolean
local function dependenciesMonLayout()
  return { { kind = "mon-catalog", key = "global" } }, true
end

---@param artifact table<string, unknown>
---@param context table<string, unknown>
---@param job ArtifactJobs.Job
---@return string
local function executeMonLayoutJob(artifact, context, job)
  return executeMonLayout(artifact, context, assert(job.generationId, "mon layout jobs require a generation"))
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateMonLayout(check)
  local MonCache = require("libs.assets.src.MonCache")
  if not MonCache.isLayoutReady(check.cacheFs, check.marker) then
    return false
  end
  local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
  local ready, _ = MonCacheWriter.isLayoutSourceReady(check.cacheFs, check.generationId, check.marker)
  return ready == true
end

---@param plans ArtifactJobs.Plans
---@return { kind: string, key: string }[], boolean
local function dependenciesMonIconPage(_, plans)
  local deps = {
    { kind = "source-plan", key = "global" },
    { kind = "mon-layout", key = "global" },
  }
  if plans.iconPageIds == nil then
    return deps, false
  end
  return deps, true
end

---@param artifact table<string, unknown>
---@param context table<string, unknown>
---@param job ArtifactJobs.Job
---@return string
local function executeMonIconPage(artifact, context, job)
  return executeMonPage(
    artifact,
    context,
    "icons",
    canonicalKeyId(job.key, "page key"),
    assert(job.generationId, "mon page jobs require a generation")
  )
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateMonIconPage(check)
  local MonCache = require("libs.assets.src.MonCache")
  return MonCache.isPageReady(check.cacheFs, "icons", canonicalKeyId(check.key, "page key"), check.marker)
end

---@param plans ArtifactJobs.Plans
---@return { kind: string, key: string }[], boolean
local function dependenciesMonPortraitPage(_, plans)
  local deps = {
    { kind = "source-plan", key = "global" },
    { kind = "mon-layout", key = "global" },
  }
  if plans.portraitPageIds == nil then
    return deps, false
  end
  return deps, true
end

---@param artifact table<string, unknown>
---@param context table<string, unknown>
---@param job ArtifactJobs.Job
---@return string
local function executeMonPortraitPage(artifact, context, job)
  return executeMonPage(
    artifact,
    context,
    "portraits",
    canonicalKeyId(job.key, "page key"),
    assert(job.generationId, "mon page jobs require a generation")
  )
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateMonPortraitPage(check)
  local MonCache = require("libs.assets.src.MonCache")
  return MonCache.isPageReady(check.cacheFs, "portraits", canonicalKeyId(check.key, "page key"), check.marker)
end

---@param plans ArtifactJobs.Plans
---@return { kind: string, key: string }[], boolean
local function dependenciesMonSummary(_, plans)
  local deps = {
    { kind = "source-plan", key = "global" },
    { kind = "mon-catalog", key = "global" },
    { kind = "mon-layout", key = "global" },
  }
  if plans.iconPageIds == nil or plans.portraitPageIds == nil then
    return deps, false
  end
  for _, pageId in ipairs(plans.iconPageIds) do
    deps[#deps + 1] = { kind = "mon-icon-page", key = tostring(pageId) }
  end
  for _, pageId in ipairs(plans.portraitPageIds) do
    deps[#deps + 1] = { kind = "mon-portrait-page", key = tostring(pageId) }
  end
  return deps, true
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateMonSummary(check)
  local MonCache = require("libs.assets.src.MonCache")
  local cacheFs, plans, marker = check.cacheFs, check.plans, check.marker
  if not MonCache.isReady(cacheFs, marker) then
    return false
  end
  for _, pageId in ipairs(assert(plans.iconPageIds, "mon summary needs the icon pages")) do
    local pageKey = tostring(pageId)
    if
      not check.childReady("mon-icon-page", pageKey, function(childMarker)
        return MonCache.isPageReady(cacheFs, "icons", pageId, childMarker)
      end)
    then
      return false
    end
  end
  for _, pageId in ipairs(assert(plans.portraitPageIds, "mon summary needs the portrait pages")) do
    local pageKey = tostring(pageId)
    if
      not check.childReady("mon-portrait-page", pageKey, function(childMarker)
        return MonCache.isPageReady(cacheFs, "portraits", pageId, childMarker)
      end)
    then
      return false
    end
  end
  return true
end

ArtifactMonJobs.executeCatalog = executeMonCatalog
ArtifactMonJobs.executeLayout = executeMonLayoutJob
ArtifactMonJobs.executeIconPage = executeMonIconPage
ArtifactMonJobs.executePortraitPage = executeMonPortraitPage
ArtifactMonJobs.executeSummary = executeMonSummary
ArtifactMonJobs.validateCatalog = validateMonCatalog
ArtifactMonJobs.dependenciesLayout = dependenciesMonLayout
ArtifactMonJobs.validateLayout = validateMonLayout
ArtifactMonJobs.dependenciesIconPage = dependenciesMonIconPage
ArtifactMonJobs.validateIconPage = validateMonIconPage
ArtifactMonJobs.dependenciesPortraitPage = dependenciesMonPortraitPage
ArtifactMonJobs.validatePortraitPage = validateMonPortraitPage
ArtifactMonJobs.dependenciesSummary = dependenciesMonSummary
ArtifactMonJobs.validateSummary = validateMonSummary

return ArtifactMonJobs
