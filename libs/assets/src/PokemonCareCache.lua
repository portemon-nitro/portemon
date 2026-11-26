-- Paths and readiness for the independently generated Day Care care family:
-- the source PMS egg-species table, the personal egg-move list, and the source
-- incense pairs, plus the hatch application's own generated presentation with
-- its staged images. Each payload is one strict record; readiness proves both
-- persisted payloads still satisfy their schemas. Runtime never reads the ROM.

---@class PokemonCareCache
local PokemonCareCache = {}

local Contract = require("libs.assets.src.DerivedAssetContract")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local PokemonCareAssetSchema = require("libs.assets.src.PokemonCareAssetSchema")

PokemonCareCache.FORMAT = Contract.pokemonCare.cacheFormat
PokemonCareCache.CATALOG_SCHEMA = Contract.pokemonCare.catalogSchema
PokemonCareCache.HATCH_SCHEMA = Contract.pokemonCare.hatchSchema
PokemonCareCache.TRADE_SCHEMA = Contract.pokemonCare.tradeSchema
PokemonCareCache.REMINDER_SCHEMA = Contract.pokemonCare.reminderSchema

local DATA_DIR = "data/generated/pokemon-care"
local HATCH_DIR = DATA_DIR .. "/hatch"
local TRADE_DIR = DATA_DIR .. "/trade"
local REMINDER_DIR = DATA_DIR .. "/reminder"

function PokemonCareCache.dir()
  return DATA_DIR
end

function PokemonCareCache.catalogPath()
  return DATA_DIR .. "/catalog.lua"
end

-- The hatch presentation's own directory: its manifest and every staged image
-- it references live under this one owned root.
function PokemonCareCache.hatchDir()
  return HATCH_DIR
end

function PokemonCareCache.hatchManifestPath()
  return HATCH_DIR .. "/manifest.lua"
end

-- The trade presentation's own directory and manifest. Its staged backdrops
-- live under the same owned root.
function PokemonCareCache.tradeDir()
  return TRADE_DIR
end

function PokemonCareCache.tradeManifestPath()
  return TRADE_DIR .. "/manifest.lua"
end

-- The reminder presentation's own directory and manifest.
---@return string
function PokemonCareCache.reminderDir()
  return REMINDER_DIR
end

---@return string
function PokemonCareCache.reminderManifestPath()
  return REMINDER_DIR .. "/manifest.lua"
end

-- The trade scene's compiled Poke Ball model assets: content-addressed
-- geometry and texture files under the same owned trade root.
---@param sha1 string
---@return string
function PokemonCareCache.tradeGeometryPath(sha1)
  return TRADE_DIR .. "/geometry/" .. sha1 .. ".g4mesh"
end

-- One trade layer's palette-index plane (one byte per pixel), staged beside
-- the resolved surface it belongs to.
---@param role string layer role
---@return string
function PokemonCareCache.tradeIndexPath(role)
  assert(type(role) == "string" and role ~= "", "a trade layer names its role")
  return TRADE_DIR .. "/" .. role .. ".indices.r8"
end

---@param sha1 string
---@return string
function PokemonCareCache.tradeTexturePath(sha1)
  return TRADE_DIR .. "/textures/" .. sha1 .. ".png"
end

-- Every staged image the hatch manifest references, in a stable order so the
-- presentation lease requests the same set on every open.
---@param manifest table<string, unknown>
---@return string[] paths
function PokemonCareCache.referencedHatchPaths(manifest)
  assert(type(manifest) == "table", "hatch paths require the manifest")
  local paths = {}
  local seen = {}
  local function add(path)
    assert(type(path) == "string" and path ~= "", "hatch images carry their staged path")
    if not seen[path] then
      seen[path] = true
      paths[#paths + 1] = path
    end
  end
  local background = assert(manifest.background) --[[@as table]]
  add(assert(background.image) --[[@as string]])
  for _, groupKey in ipairs({ "egg", "bars" }) do
    local group = assert(manifest[groupKey]) --[[@as table]]
    local frames = assert(group.frames) --[[@as table]]
    for _, frame in ipairs(frames) do
      add(assert(frame.image) --[[@as string]])
    end
  end
  local particles = assert(manifest.particles) --[[@as table]]
  for _, variant in ipairs({ "egg", "manaphy" }) do
    local set = assert(particles[variant]) --[[@as table]]
    local textures = assert(set.textures) --[[@as table]]
    for _, texture in ipairs(textures) do
      add(assert(texture.image) --[[@as string]])
    end
  end
  table.sort(paths)
  return paths
end

-- Every staged surface the trade manifest references, in a stable order so the
-- presentation lease requests the same set on every open.
---@param manifest table<string, unknown>
---@return string[] paths
function PokemonCareCache.referencedTradePaths(manifest)
  assert(type(manifest) == "table", "trade paths require the manifest")
  local scenes = assert(manifest.scenes) --[[@as table]]
  local paths = {}
  local seen = {}
  local function add(path)
    assert(type(path) == "string" and path ~= "", "trade surfaces carry their staged path")
    if not seen[path] then
      seen[path] = true
      paths[#paths + 1] = path
    end
  end
  for _, phase in ipairs({ "send", "depart", "recede", "exchange", "approach", "arrive", "receive" }) do
    local scene = assert(scenes[phase], "the trade manifest carries its " .. phase .. " scene") --[[@as table]]
    for _, layer in
      ipairs(assert(scene.layers, "the trade scene carries its layers") --[[@as table[] ]])
    do
      if layer.variants ~= nil then
        for _, key in ipairs({ "day", "evening", "night" }) do
          local variant = assert(layer.variants[key], "the layered surface carries its " .. key .. " bank") --[[@as table]]
          add(assert(variant.image) --[[@as string]])
        end
      else
        add(assert(layer.image) --[[@as string]])
      end
    end
  end
  local sprites = assert(manifest.sprites, "the trade manifest carries its sprite sheets") --[[@as table]]
  for _, sheetKey in ipairs({ "effect" }) do
    local sheet = assert(sprites[sheetKey], "the trade manifest carries its " .. sheetKey .. " sheet") --[[@as table]]
    for _, sequence in
      ipairs(assert(sheet.sequences, "the trade sprite sheet carries its sequences") --[[@as table[] ]])
    do
      for _, frame in
        ipairs(assert(sequence.frames, "the trade sprite sequence carries its frames") --[[@as table[] ]])
      do
        if frame.blank ~= true then
          add(assert(frame.image) --[[@as string]])
        end
      end
    end
  end
  table.sort(paths)
  return paths
end

-- Every file the trade bundle stages: the surfaces and sprite frames the
-- presentation requests, plus the compiled Poke Ball model's own content
-- addressed geometry and textures (the model pool reads those directly, so the
-- presentation lease never requests them as images).
---@param manifest table<string, unknown>
---@return string[]
function PokemonCareCache.tradeStagedPaths(manifest)
  local paths = PokemonCareCache.referencedTradePaths(manifest)
  local seen = {}
  for _, path in ipairs(paths) do
    seen[path] = true
  end
  for _, phase in ipairs({ "send", "depart", "recede", "exchange", "approach", "arrive", "receive" }) do
    local scene = assert(manifest.scenes[phase], "the trade manifest carries its " .. phase .. " scene") --[[@as table]]
    for _, layer in
      ipairs(assert(scene.layers, "the trade scene carries its layers") --[[@as table[] ]])
    do
      local indexPath = layer.indices
      if indexPath ~= nil and not seen[indexPath] then
        seen[indexPath] = true
        paths[#paths + 1] = indexPath
      end
    end
  end
  local balloon = assert(manifest.balloon, "the trade manifest carries its balloon") --[[@as table]]
  for _, path in
    ipairs(ModelAsset.referencedPaths(assert(balloon.model --[[@as table<string, unknown>]])))
  do
    if not seen[path] then
      seen[path] = true
      paths[#paths + 1] = path
    end
  end
  table.sort(paths)
  return paths
end

-- Every staged surface the reminder manifest references, in a stable order so
-- the presentation lease requests the same set on every open.
---@param manifest table<string, unknown>
---@return string[] paths
function PokemonCareCache.referencedReminderPaths(manifest)
  assert(type(manifest) == "table", "reminder paths require the manifest")
  local paths = {}
  for _, key in ipairs({ "main", "sub", "buttons" }) do
    local surface = assert(manifest[key], "the reminder manifest carries its " .. key .. " surface") --[[@as table]]
    paths[#paths + 1] = assert(surface.image, "the reminder surface carries its staged image") --[[@as string]]
  end
  table.sort(paths)
  return paths
end

function PokemonCareCache.markerPath()
  return DATA_DIR .. "/complete"
end

---@param versionRomSha1 string
---@param dependencyHash string
---@return string
function PokemonCareCache.marker(versionRomSha1, dependencyHash)
  return string.format("%s:%s:%s", PokemonCareCache.FORMAT, versionRomSha1, dependencyHash)
end

---@param cacheFs CacheFs
---@param expectedMarker string
---@return boolean
function PokemonCareCache.isReady(cacheFs, expectedMarker)
  if type(expectedMarker) ~= "string" or cacheFs:read(PokemonCareCache.markerPath()) ~= expectedMarker then
    return false
  end
  local ok, catalog = pcall(cacheFs.loadLua, cacheFs, PokemonCareCache.catalogPath())
  if not ok then
    return false
  end
  if not PokemonCareAssetSchema.isValidCatalog(catalog) then
    return false
  end
  local manifestOk, manifest = pcall(cacheFs.loadLua, cacheFs, PokemonCareCache.hatchManifestPath())
  if not manifestOk then
    return false
  end
  if not PokemonCareAssetSchema.isValidHatchManifest(manifest) then
    return false
  end
  local tradeOk, trade = pcall(cacheFs.loadLua, cacheFs, PokemonCareCache.tradeManifestPath())
  if not tradeOk then
    return false
  end
  if not PokemonCareAssetSchema.isValidTradeManifest(trade) then
    return false
  end
  local reminderOk, reminder = pcall(cacheFs.loadLua, cacheFs, PokemonCareCache.reminderManifestPath())
  if not reminderOk then
    return false
  end
  return PokemonCareAssetSchema.isValidReminderManifest(reminder)
end

-- Trusted runtime load: presence plus the current schema identity is
-- sufficient. Whole-catalog validation stays with the producer writer, schema
-- tests, and explicit audit (see isReady).
-- Trusted runtime load of the hatch presentation manifest. Presence plus the
-- current schema identity is sufficient; whole-manifest validation stays with
-- the producer writer and schema tests.
---@param cacheFs CacheFs
---@return table<string, unknown>
function PokemonCareCache.loadHatchManifest(cacheFs)
  local manifest = cacheFs:loadLua(PokemonCareCache.hatchManifestPath())
  assert(
    type(manifest) == "table" and manifest.schema == PokemonCareCache.HATCH_SCHEMA,
    "the hatch presentation manifest is unavailable"
  )
  return manifest
end

---@param cacheFs CacheFs
---@return table<string, unknown>
function PokemonCareCache.loadTradeManifest(cacheFs)
  local manifest = cacheFs:loadLua(PokemonCareCache.tradeManifestPath())
  assert(
    type(manifest) == "table" and manifest.schema == PokemonCareCache.TRADE_SCHEMA,
    "the trade presentation manifest is unavailable"
  )
  return manifest
end

---@param cacheFs CacheFs
---@return table<string, unknown>
function PokemonCareCache.loadReminderManifest(cacheFs)
  local manifest = cacheFs:loadLua(PokemonCareCache.reminderManifestPath())
  assert(
    type(manifest) == "table" and manifest.schema == PokemonCareCache.REMINDER_SCHEMA,
    "the reminder presentation manifest is unavailable"
  )
  return manifest
end

---@param cacheFs CacheFs
---@return table<string, unknown>
function PokemonCareCache.loadCatalog(cacheFs)
  local catalog = cacheFs:loadLua(PokemonCareCache.catalogPath())
  assert(
    type(catalog) == "table" and catalog.schema == PokemonCareCache.CATALOG_SCHEMA,
    "the Day Care care catalog is unavailable"
  )
  return catalog
end

return PokemonCareCache
