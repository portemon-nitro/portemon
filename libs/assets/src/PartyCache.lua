-- Readiness and paths for the derived party presentation cache. The party
-- class is one independently rebuildable derived class (manifest, panel/
-- sprite images, navigation/text/numeric/badge records, registration
-- markers): changing the party compilers must not disturb the raw ROM dump
-- or any other compiled class. A class is ready only when the completion
-- marker matches exactly and the manifest plus every referenced artifact is
-- present with the expected schema, so a partial build never reads as
-- complete. Species icons stay in the mon class; the party manifest
-- references no icon pixels.
-- Paths are cache-relative; all IO goes through a CacheFs.

---@class PartyCache
local PartyCache = {}

local Contract = require("libs.assets.src.DerivedAssetContract")
local PartyAssetSchema = require("libs.assets.src.PartyAssetSchema")

PartyCache.FORMAT = Contract.party.cacheFormat
PartyCache.SCHEMA = Contract.party.schema

local DATA_DIR = "data/generated/party"
local ASSET_DIR = "assets/generated/party"

function PartyCache.dir()
  return DATA_DIR
end
function PartyCache.assetDir()
  return ASSET_DIR
end
function PartyCache.manifestPath()
  return DATA_DIR .. "/manifest.lua"
end
function PartyCache.provenancePath()
  return DATA_DIR .. "/provenance.lua"
end
function PartyCache.markerPath()
  return DATA_DIR .. "/complete"
end

function PartyCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", PartyCache.FORMAT, romSha1, depHash)
end

-- Every cache-relative path the manifest references.
---@param manifest table<string, unknown>
---@return string[]
function PartyCache.referencedPaths(manifest)
  PartyAssetSchema.assertManifest(manifest)
  local paths = {}
  local function addVisual(visual)
    assert(type(visual) == "table", "party manifest visual is malformed")
    assert(type(visual.image) == "string", "party manifest visual carries one realized image")
    paths[#paths + 1] = visual.image
  end
  local function addAnimated(animated)
    assert(type(animated) == "table" and type(animated.frames) == "table", "party animated visual is malformed")
    for _, frame in ipairs(animated.frames) do
      addVisual(frame)
    end
  end
  local typed = manifest --[[@as table<string, unknown>]]
  local panels = typed.panels --[[@as table[] ]]
  for _, panel in ipairs(panels) do
    local chrome = (panel --[[@as table<string, unknown>]]).chrome --[[@as table<string, unknown>]]
    for _, visual in pairs(chrome) do
      addVisual(visual)
    end
  end
  local visuals = typed.visuals --[[@as table<string, unknown>]]
  local function addSequences(group)
    local sequences = (group --[[@as table<string, unknown>]]).sequences --[[@as table[] ]]
    for _, animated in ipairs(sequences) do
      addAnimated(animated)
    end
  end
  addSequences(visuals.cursor)
  addSequences(visuals.balls)
  addSequences(visuals.buttons)
  addSequences(visuals.held)
  local status = visuals.status --[[@as table<string, unknown>]]
  for _, name in ipairs({ "paralysis", "freeze", "sleep", "poison", "burn", "faint" }) do
    addVisual(status[name])
  end
  addAnimated(visuals.feedback)
  addVisual(visuals.backdropMain)
  addVisual(visuals.backdropSub)
  addVisual(visuals.detailSub)
  addVisual(visuals.decoration)
  addVisual(visuals.auxPanel)
  local hpBars = visuals.hpBars --[[@as table<string, unknown>]]
  addVisual(hpBars.green)
  addVisual(hpBars.yellow)
  addVisual(hpBars.red)
  local menu = typed.contextMenu --[[@as table<string, unknown>]]
  local menuFrames = menu.frames --[[@as table<string, table<string, unknown>>]]
  for _, shape in ipairs({ "standard", "cancel" }) do
    local group = menuFrames[shape]
    for _, state in ipairs({ "raised", "selected", "pressed" }) do
      addVisual(group[state])
    end
  end
  local glyphs = typed.numberGlyphs --[[@as table<string, unknown>]]
  local digits = glyphs.digits --[[@as table[] ]]
  for _, digit in ipairs(digits) do
    addVisual(digit)
  end
  addVisual(glyphs.slash)
  addVisual(glyphs.level)
  local leaves = typed.shinyLeaves --[[@as table<string, unknown>]]
  addAnimated(leaves.leaves)
  addAnimated(leaves.crown)
  return paths
end

-- True only when the marker is exact, the manifest loads with the expected
-- schema, and every referenced artifact is present.
function PartyCache.isReady(cacheFs, expectedMarker)
  local marker = cacheFs:read(PartyCache.markerPath())
  if
    type(marker) ~= "string"
    or type(expectedMarker) ~= "string"
    or marker ~= expectedMarker
    or marker:sub(1, #PartyCache.FORMAT + 1) ~= PartyCache.FORMAT .. ":"
  then
    return false
  end
  local manifest = cacheFs:loadLua(PartyCache.manifestPath())
  if not PartyAssetSchema.isValidManifest(manifest) then
    return false
  end
  local provenance = cacheFs:loadLua(PartyCache.provenancePath())
  if
    type(provenance) ~= "table"
    or provenance.cacheFormat ~= PartyCache.FORMAT
    or provenance.schema ~= PartyCache.SCHEMA
  then
    return false
  end
  local ok, paths = pcall(PartyCache.referencedPaths, manifest)
  if not ok then
    return false
  end
  for _, path in ipairs(paths) do
    if not cacheFs:exists(path, "file") then
      return false
    end
  end
  return true
end

function PartyCache.validateManifest(manifest)
  return PartyAssetSchema.assertManifest(manifest)
end

-- Trusted runtime load: presence plus the current schema identity is
-- sufficient. Whole-manifest validation stays with the producer writers,
-- schema tests, and explicit audit (see isReady/referencedPaths).
function PartyCache.loadManifest(cacheFs)
  local manifest = cacheFs:loadLua(PartyCache.manifestPath())
  assert(type(manifest) == "table" and manifest.schema == PartyCache.SCHEMA, "party manifest is unavailable")
  return manifest
end

return PartyCache
