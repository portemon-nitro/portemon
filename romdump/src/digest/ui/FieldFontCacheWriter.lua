-- Persists a compiled field-font bundle through the shared staged
-- publication primitive: the provenance record, the font definition Lua, and
-- the three generated images (composited glyph atlas, semantic glyph mask
-- atlas, and focus indicators) are written into a disposable staging root,
-- readback-validated there, and only then is the completed stage published
-- with the marker last. A compiled image record defers its PNG encode and
-- write to the owning job's low-priority continuation in the same stage; a
-- direct write encodes it here. Staging and validation are one step;
-- publication happens outside that step's error handler, so a publish failure
-- never triggers writer-level stage cleanup that could delete the last
-- remaining copy of the previous artifact.

local Errors = require("libs.errors.src.Errors")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local PngEncoder = require("romdump.src.digest.PngEncoder")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")

local FieldFontCacheWriter = {}

function FieldFontCacheWriter.isReady(cacheFs, marker)
  return FieldFontCache.isReady(cacheFs, marker)
end

---@param image { width: integer, height: integer, pixels: string }
---@return string
local function encodeImage(image)
  return PngEncoder.encode(image.width, image.height, image.pixels)
end

---@param stage table<string, unknown>
---@param bundle table<string, unknown>
---@param present fun(path: string): boolean
local function writeDefinitions(stage, bundle, present)
  stage:writeLua(FieldFontCache.provenancePath(), {
    schema = "g4-field-font-provenance-v1",
    dependencies = bundle.dependencies,
  })
  for _, fontId in ipairs(FieldFontCache.REQUIRED_FONT_IDS) do
    local font = assert(bundle.fonts[fontId], "font bundle is missing required font " .. fontId)
    stage:writeLua(FieldFontCache.defPath(fontId), font.font)
    local def = stage:loadLua(FieldFontCache.defPath(fontId))
    if type(def) ~= "table" or def.schema ~= FieldFontCache.SCHEMA or def.fontId ~= fontId then
      Errors.raise("FIELD_FONT_CACHE_READBACK_FAILED", "font def readback failed", { fontId = fontId })
    end
    if not present(FieldFontCache.atlasPath(fontId)) then
      Errors.raise("FIELD_FONT_CACHE_READBACK_FAILED", "font atlas readback failed", { fontId = fontId })
    end
    if not present(FieldFontCache.maskAtlasPath(fontId)) then
      Errors.raise("FIELD_FONT_CACHE_READBACK_FAILED", "font mask atlas readback failed", { fontId = fontId })
    end
    if not present(FieldFontCache.focusIndicatorsPath(fontId)) then
      Errors.raise("FIELD_FONT_CACHE_READBACK_FAILED", "font focus-indicator readback failed", { fontId = fontId })
    end
  end
  stage:write(FieldFontCache.markerPath(), bundle.marker)
end

-- The staged images are not written yet: their continuation owns those files,
-- so readback accepts the pending registration instead.
local function deferImages(artifact, bundle)
  for _, fontId in ipairs(FieldFontCache.REQUIRED_FONT_IDS) do
    local font = assert(bundle.fonts[fontId], "font bundle is missing required font " .. fontId)
    artifact:deferImage(FieldFontCache.atlasPath(fontId), font.atlas.width, font.atlas.height, font.atlas.pixels)
    artifact:deferImage(
      FieldFontCache.maskAtlasPath(fontId),
      font.maskAtlas.width,
      font.maskAtlas.height,
      font.maskAtlas.pixels
    )
    artifact:deferImage(
      FieldFontCache.focusIndicatorsPath(fontId),
      font.focusIndicators.width,
      font.focusIndicators.height,
      font.focusIndicators.pixels
    )
  end
end

---@param artifact PreparedArtifact
---@param bundle table<string, unknown>
---@return string
function FieldFontCacheWriter.stage(artifact, bundle)
  assert(artifact and artifact.stageFs, "field-font staging requires a PreparedArtifact")
  assert(bundle and bundle.marker and bundle.fonts, "stage requires a font bundle")
  for _, fontId in ipairs(FieldFontCache.REQUIRED_FONT_IDS) do
    local font = assert(bundle.fonts[fontId], "font bundle is missing required font " .. fontId)
    assert(font.font.schema == FieldFontCache.SCHEMA, "font def schema mismatch")
  end
  artifact:addOwnedRoot(FieldFontCache.assetDir())
  artifact:addOwnedRoot(FieldFontCache.dir())
  deferImages(artifact, bundle)
  writeDefinitions(artifact:stageFs(), bundle, function(path)
    return artifact:hasDeferredImage(path) or artifact:stageFs():exists(path, "file")
  end)
  return bundle.marker
end

function FieldFontCacheWriter.write(cacheFs, bundle)
  assert(bundle and bundle.marker and bundle.fonts, "write requires a font bundle")
  for _, fontId in ipairs(FieldFontCache.REQUIRED_FONT_IDS) do
    local font = assert(bundle.fonts[fontId], "font bundle is missing required font " .. fontId)
    assert(font.font.schema == FieldFontCache.SCHEMA, "font def schema mismatch")
  end
  local tx = ArtifactPublisher.begin(cacheFs, "field-font", {
    FieldFontCache.assetDir(),
    FieldFontCache.dir(),
  })
  local stage = tx.stage
  local ok, err = pcall(function()
    for _, fontId in ipairs(FieldFontCache.REQUIRED_FONT_IDS) do
      local font = assert(bundle.fonts[fontId], "font bundle is missing required font " .. fontId)
      stage:write(FieldFontCache.atlasPath(fontId), encodeImage(font.atlas))
      stage:write(FieldFontCache.maskAtlasPath(fontId), encodeImage(font.maskAtlas))
      stage:write(FieldFontCache.focusIndicatorsPath(fontId), encodeImage(font.focusIndicators))
    end
    writeDefinitions(stage, bundle, function(path)
      return stage:exists(path, "file")
    end)
  end)
  if not ok then
    tx:abort()
    error(err, 0)
  end
  tx:publish()
  return true
end

return FieldFontCacheWriter
