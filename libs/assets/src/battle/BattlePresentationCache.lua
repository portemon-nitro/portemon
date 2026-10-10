-- Readiness and paths for the derived battle presentation class. The
-- global manifest stages apart from scenes: one lazy scene artifact owns
-- the exact composed source scene for one context, while portrait pages
-- stay owned by the mon class and audio banks by the audio class. A launch
-- demand names exactly its scene, its portrait selectors, and its audio
-- roles/banks/cries; readiness means every named artifact validates for
-- the staged files, never mere marker presence. Paths are cache-relative;
-- all IO goes through a CacheFs. No ROM handle is retained and no LOVE
-- image is allocated to report readiness.
--
-- The background/terrain/time key lists below are the runtime-owned
-- semantic scene selectors behind demand construction. The producer owns
-- the archive/member mapping behind them and never leaks it here.

---@class BattlePresentationCache
local BattlePresentationCache = {}

local Contract = require("libs.assets.src.DerivedAssetContract")
local BattlePresentationSchema = require("libs.assets.src.battle.BattlePresentationSchema")
local MonAssetSchema = require("libs.assets.src.MonAssetSchema")
local MonCache = require("libs.assets.src.MonCache")
local PngWriter = require("libs.assets.src.PngWriter")

BattlePresentationCache.MANIFEST_SCHEMA = Contract.battlePresentation.schema
BattlePresentationCache.SCENE_SCHEMA = Contract.battlePresentation.sceneSchema

local DATA_DIR = "data/generated/battle"
local ASSET_DIR = "assets/generated/battle"

BattlePresentationCache.BACKGROUNDS = {
  "general",
  "ocean",
  "city",
  "forest",
  "mountain",
  "snow",
  "building_1",
  "building_2",
  "building_3",
  "cave_1",
  "cave_2",
  "cave_3",
  "will",
  "koga",
  "bruno",
  "karen",
  "lance",
  "distortion_world",
}

BattlePresentationCache.TERRAINS = {
  "plain",
  "sand",
  "grass",
  "puddle",
  "mountain",
  "cave",
  "snow",
  "water",
  "ice",
  "building",
  "great_marsh",
  "unknown",
  "will",
  "koga",
  "bruno",
  "karen",
  "lance",
  "distortion_world",
}

BattlePresentationCache.TIMES = { "day", "evening", "night" }

---@return string
function BattlePresentationCache.dir()
  return DATA_DIR
end

---@return string
function BattlePresentationCache.assetDir()
  return ASSET_DIR
end

---@return string cache-relative staged global manifest path
function BattlePresentationCache.manifestPath()
  return DATA_DIR .. "/battle_presentation.lua"
end

---@return string cache-relative producer provenance path
function BattlePresentationCache.provenancePath()
  return DATA_DIR .. "/battle_presentation_provenance.lua"
end

---@return string cache-relative global completion marker path
function BattlePresentationCache.markerPath()
  return DATA_DIR .. "/battle_presentation.complete"
end

---@param name string staged slice name without extension
---@return string cache-relative staged slice image path
function BattlePresentationCache.globalImagePath(name)
  assert(type(name) == "string" and name ~= "", "global image name is required")
  assert(name:find("/", 1, true) == nil, "global image names stay flat: " .. name)
  return ASSET_DIR .. "/" .. name .. ".png"
end

---@param sceneKey string semantic scene key
---@return string file-safe scene file stem
local function sceneStem(sceneKey)
  assert(type(sceneKey) == "string" and sceneKey ~= "", "scene keys are non-empty strings")
  local stem, slashes = sceneKey:gsub("/", "-")
  assert(slashes == 2, "scene keys join background, terrain, and time: " .. sceneKey)
  return stem
end

---@param sceneKey string semantic scene key
---@return string cache-relative staged scene record path
function BattlePresentationCache.scenePath(sceneKey)
  return DATA_DIR .. "/scenes/" .. sceneStem(sceneKey) .. ".lua"
end

---@param sceneKey string semantic scene key
---@return string cache-relative staged scene image path
function BattlePresentationCache.sceneImagePath(sceneKey)
  return ASSET_DIR .. "/scenes/" .. sceneStem(sceneKey) .. ".png"
end

---@param sceneKey string semantic scene key
---@return string cache-relative scene completion marker path
function BattlePresentationCache.sceneMarkerPath(sceneKey)
  return DATA_DIR .. "/scenes/" .. sceneStem(sceneKey) .. ".complete"
end

---@param romSha1 string
---@param depHash string
---@return string
function BattlePresentationCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", Contract.battlePresentation.cacheFormat, romSha1, depHash)
end

---@param background string
---@param terrain string
---@param time string
---@return string canonical semantic scene key
function BattlePresentationCache.sceneKey(background, terrain, time)
  return background .. "/" .. terrain .. "/" .. time
end

local backgroundSet = {}
for _, background in ipairs(BattlePresentationCache.BACKGROUNDS) do
  backgroundSet[background] = true
end

local terrainSet = {}
for _, terrain in ipairs(BattlePresentationCache.TERRAINS) do
  terrainSet[terrain] = true
end

local timeSet = {}
for _, time in ipairs(BattlePresentationCache.TIMES) do
  timeSet[time] = true
end

---@param key string
---@return { background: string, terrain: string, time: string }|nil
function BattlePresentationCache.parseSceneKey(key)
  if type(key) ~= "string" then
    return nil
  end
  local background, terrain, time = key:match("^([^/]+)/([^/]+)/([^/]+)$")
  if background == nil or backgroundSet[background] == nil then
    return nil
  end
  if terrain == nil or terrainSet[terrain] == nil then
    return nil
  end
  if time == nil or timeSet[time] == nil then
    return nil
  end
  return { background = background, terrain = terrain, time = time }
end

---@param key string
---@return boolean
function BattlePresentationCache.validateSceneKey(key)
  return BattlePresentationCache.parseSceneKey(key) ~= nil
end

-- Every ordinary background/terrain/time combination in deterministic
-- order: backgrounds, then terrains, then times.
---@return { key: string, background: string, terrain: string, time: string }[]
function BattlePresentationCache.sceneInventory()
  local inventory = {}
  for _, background in ipairs(BattlePresentationCache.BACKGROUNDS) do
    for _, terrain in ipairs(BattlePresentationCache.TERRAINS) do
      for _, time in ipairs(BattlePresentationCache.TIMES) do
        inventory[#inventory + 1] = {
          key = background .. "/" .. terrain .. "/" .. time,
          background = background,
          terrain = terrain,
          time = time,
        }
      end
    end
  end
  return inventory
end

-- The planning manifest behind demand construction on an unstaged cache:
-- the scene inventory without dump-verified roles. Only a staged manifest
-- proves roles; planning data never reads as ready.
---@param versionId string
---@return { schema: string, version: { id: string, language: string }, verified: boolean, scenes: { key: string, background: string, terrain: string, time: string }[] } planning manifest
local function planningManifest(versionId)
  assert(type(versionId) == "string" and versionId ~= "", "planning requires a version identity")
  return {
    schema = BattlePresentationCache.MANIFEST_SCHEMA,
    version = { id = versionId, language = "en" },
    verified = false,
    scenes = BattlePresentationCache.sceneInventory(),
  }
end

-- Trusted runtime load: the staged manifest when it validates, else the
-- planning inventory so demands stay constructible before staging. Staged
-- roles never fall back to planning data silently: the verified flag tells
-- them apart.
---@param cacheFs CacheFs
---@return { schema: string, version: { id: string, language: string }, verified: boolean, scenes: { key: string, background: string, terrain: string, time: string }[], audioRoles?: { wild: string, trainer: string, rival: string, select: string, narrationBank: integer, cries: string } } global or planning manifest
function BattlePresentationCache.load(cacheFs)
  assert(cacheFs ~= nil, "presentation loading requires a cache filesystem")
  local staged = cacheFs:loadLua(BattlePresentationCache.manifestPath())
  if type(staged) == "table" then
    local ok = pcall(BattlePresentationSchema.assertManifest, staged)
    if ok then
      return staged
    end
  end
  return planningManifest(assert(cacheFs.versionId, "presentation loading requires a versioned cache"))
end

-- Load one staged scene record: the record must validate and name exactly
-- the requested key. A missing record is pending, never a fallback scene.
---@param cacheFs CacheFs
---@param sceneKey string
---@return { schema: string, key: string, background: string, terrain: string, time: string, canvasWidth: integer, canvasHeight: integer, viewport: { x: integer, y: integer, width: integer, height: integer }, imagePath: string }|nil scene record
---@return unknown|nil reason
function BattlePresentationCache.loadScene(cacheFs, sceneKey)
  assert(cacheFs ~= nil, "scene loading requires a cache filesystem")
  if BattlePresentationCache.parseSceneKey(sceneKey) == nil then
    return nil, "unknown battle scene key: " .. tostring(sceneKey)
  end
  local record, loadErr = cacheFs:loadLua(BattlePresentationCache.scenePath(sceneKey))
  if record == nil then
    return nil, loadErr or ("no staged battle scene for " .. sceneKey)
  end
  local ok, schemaErr = pcall(BattlePresentationSchema.assertScene, record)
  if not ok then
    return nil, schemaErr
  end
  assert(record ~= nil, "the staged scene carries its record")
  if record.key ~= sceneKey then
    return nil, "staged battle scene names " .. tostring(record.key) .. ", not " .. sceneKey
  end
  return record
end

---@param selectors unknown
---@return string[]|nil sorted deduplicated portrait selectors
---@return string|nil reason
local function checkSelectors(selectors)
  if type(selectors) ~= "table" or #selectors == 0 then
    return nil, "a battle demand requires its portrait selectors"
  end
  local seen = {}
  for _, selector in ipairs(selectors) do
    if type(selector) ~= "string" or selector == "" then
      return nil, "portrait selectors must be non-empty strings"
    end
    if selector:match("^([^/]+)/") == nil then
      return nil, "portrait selector has no species key: " .. selector
    end
    seen[selector] = true
  end
  local pages = {}
  for selector in pairs(seen) do
    pages[#pages + 1] = selector
  end
  table.sort(pages)
  return pages
end

---@param roles string[] adopted role symbols to resolve
---@param audioPlan { index?: { sequences?: { bankId?: integer }[], sequenceBySymbol?: table<string, integer> } }|nil adopted normalized audio membership
---@return integer[] resolved audio bank identities
local function resolveBanks(roles, audioPlan)
  if type(audioPlan) ~= "table" or type(audioPlan.index) ~= "table" then
    return {}
  end
  local index = audioPlan.index
  assert(index ~= nil, "audio membership carries its sequence index")
  if type(index.sequences) ~= "table" or type(index.sequenceBySymbol) ~= "table" then
    return {}
  end
  assert(index.sequences ~= nil and index.sequenceBySymbol ~= nil, "audio sequences carry their lookup")
  local seen, banks = {}, {}
  for _, role in ipairs(roles) do
    local sequenceId = index.sequenceBySymbol[role]
    local entry = type(sequenceId) == "number" and index.sequences[sequenceId] or nil
    if type(entry) == "table" and type(entry.bankId) == "number" then
      if not seen[entry.bankId] then
        seen[entry.bankId] = true
        banks[#banks + 1] = entry.bankId
      end
    end
  end
  table.sort(banks)
  return banks
end

-- Build the exact deduplicated demand for one battle context: the single
-- inventoried scene, the sorted portrait selectors, and the audio
-- roles/banks/cries the launch reaches. Returns whether all planning
-- prerequisites are known: a planning manifest yields a shapely but
-- incomplete demand, never readiness.
---@param manifest { scenes: { key: string }[], verified?: boolean, audioRoles?: { wild?: string, trainer?: string, rival?: string, select?: string } } global or planning manifest
---@param context { background: string, terrain: string, time: string }
---@param portraitSelectors string[]
---@param audioPlan { index?: { sequences?: { bankId?: integer }[], sequenceBySymbol?: table<string, integer> } }|nil adopted normalized audio membership
---@return { scenes: string[], pages: string[], audio: { roles: string[], banks: integer[], cries: string[] } }|nil demand
---@return unknown|nil second value is the planning-complete flag or the rejection reason
function BattlePresentationCache.requirements(manifest, context, portraitSelectors, audioPlan)
  if type(manifest) ~= "table" or type(manifest.scenes) ~= "table" then
    return nil, "battle demands require a manifest with its scene inventory"
  end
  if type(context) ~= "table" then
    return nil, "battle demands require their background, terrain, and time"
  end
  local wanted = BattlePresentationCache.sceneKey(context.background, context.terrain, context.time)
  local resolved = nil
  for _, entry in ipairs(manifest.scenes) do
    if type(entry) == "table" and entry.key == wanted then
      resolved = entry.key
      break
    end
  end
  if resolved == nil then
    return nil, "unknown battle context: " .. tostring(wanted)
  end
  local pages, pagesErr = checkSelectors(portraitSelectors)
  if pages == nil then
    return nil, pagesErr
  end
  local roles = {}
  if manifest.verified == true and type(manifest.audioRoles) == "table" then
    for _, role in ipairs({ "wild", "trainer", "rival", "select" }) do
      if type(manifest.audioRoles[role]) == "string" then
        roles[#roles + 1] = manifest.audioRoles[role]
      end
    end
  end
  local cries, seenCries = {}, {}
  for _, selector in ipairs(pages) do
    local species = selector:match("^([^/]+)")
    assert(species ~= nil, "portrait selectors carry their species key")
    local cry = "cry:" .. species
    if not seenCries[cry] then
      seenCries[cry] = true
      cries[#cries + 1] = cry
    end
  end
  table.sort(cries)
  local demand = {
    scenes = { resolved },
    pages = pages,
    audio = { roles = roles, banks = resolveBanks(roles, audioPlan), cries = cries },
  }
  local ok = pcall(BattlePresentationSchema.assertDemand, demand)
  if not ok then
    return nil, "battle demand construction failed its own validation"
  end
  return demand, manifest.verified == true
end

---@param cacheFs CacheFs
---@param demand { scenes: string[], pages: string[], audio: { roles: string[], banks: integer[], cries: string[] } } exact launch demand
---@return boolean true only when every named artifact validates
function BattlePresentationCache.isReady(cacheFs, demand)
  assert(cacheFs ~= nil, "readiness requires a cache filesystem")
  if not pcall(BattlePresentationSchema.assertDemand, demand) then
    return false
  end
  assert(demand ~= nil, "the demand carries its members")
  local staged = cacheFs:loadLua(BattlePresentationCache.manifestPath())
  if type(staged) ~= "table" or not pcall(BattlePresentationSchema.assertManifest, staged) then
    return false
  end
  assert(staged ~= nil, "the staged manifest carries its roles")
  local stagedRoles = {}
  for _, role in ipairs({ "wild", "trainer", "rival", "select" }) do
    stagedRoles[staged.audioRoles[role]] = true
  end
  for _, role in ipairs(demand.audio.roles) do
    if not stagedRoles[role] then
      return false
    end
  end
  for _, sceneKey in ipairs(demand.scenes) do
    local record, _ = BattlePresentationCache.loadScene(cacheFs, sceneKey)
    if record == nil then
      return false
    end
    local bytes = cacheFs:read(BattlePresentationCache.sceneImagePath(sceneKey))
    if type(bytes) ~= "string" or #bytes ~= PngWriter.encodedSize(record.canvasWidth, record.canvasHeight) then
      return false
    end
  end
  local portraits = cacheFs:loadLua(MonCache.portraitManifestPath())
  if type(portraits) ~= "table" or not pcall(MonAssetSchema.assertPortraitManifest, portraits) then
    return false
  end
  assert(portraits ~= nil, "the staged portrait manifest carries its entries")
  local index = cacheFs:loadLua(MonCache.indexPath())
  if type(index) ~= "table" or not pcall(MonAssetSchema.assertIndex, index) then
    return false
  end
  assert(index ~= nil, "the staged mon index carries its page markers")
  for _, selector in ipairs(demand.pages) do
    local entry = portraits.entries[selector]
    if type(entry) ~= "table" or type(entry.pageId) ~= "number" then
      return false
    end
    local marker = index.portraitPages[entry.pageId + 1]
    if type(marker) ~= "string" or not MonCache.isPageReady(cacheFs, "portraits", entry.pageId, marker) then
      return false
    end
  end
  return true
end

-- True only when the global marker is exact and the staged manifest still
-- satisfies its schema. Page and scene stages never satisfy this alone.
---@param cacheFs CacheFs
---@param expectedMarker string
---@return boolean
function BattlePresentationCache.isGlobalReady(cacheFs, expectedMarker)
  if cacheFs:read(BattlePresentationCache.markerPath()) ~= expectedMarker then
    return false
  end
  local staged = cacheFs:loadLua(BattlePresentationCache.manifestPath())
  return type(staged) == "table" and pcall(BattlePresentationSchema.assertManifest, staged)
end

-- True only when the scene marker is exact and the staged scene record
-- names exactly the requested key with its complete staged image.
---@param cacheFs CacheFs
---@param sceneKey string
---@param expectedMarker string
---@return boolean
function BattlePresentationCache.isSceneReady(cacheFs, sceneKey, expectedMarker)
  if cacheFs:read(BattlePresentationCache.sceneMarkerPath(sceneKey)) ~= expectedMarker then
    return false
  end
  local record, _ = BattlePresentationCache.loadScene(cacheFs, sceneKey)
  if record == nil then
    return false
  end
  local bytes = cacheFs:read(BattlePresentationCache.sceneImagePath(sceneKey))
  return type(bytes) == "string" and #bytes == PngWriter.encodedSize(record.canvasWidth, record.canvasHeight)
end

return BattlePresentationCache
