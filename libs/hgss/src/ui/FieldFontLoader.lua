-- Loads the compiled dialogue font definition for runtime text layout. This
-- deliberately owns no atlas or graphics objects; presentation loads those
-- separately when it creates the dialogue renderer. The definition is a
-- trusted published artifact: the loader checks presence and the current
-- schema identity, and the producer pipeline plus explicit audit own the full
-- contract (color bands, atlas geometry, mask atlas, focus frames). Consumers
-- assert the fields they actually read at their own use sites.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")

local FieldFontLoader = {}

---@param cacheFs CacheFs
---@param fontId integer?
---@return FieldFontDef
function FieldFontLoader.load(cacheFs, fontId)
  assert(cacheFs and cacheFs.loadLua, "FieldFontLoader requires a CacheFs-shaped object")
  fontId = fontId or 0
  local path = FieldFontCache.defPath(fontId)
  local definition = cacheFs:loadLua(path)
  if type(definition) ~= "table" or definition.schema ~= FieldFontCache.SCHEMA then
    Errors.raise(
      FieldErrors.FONT_DEF_MISSING,
      "no " .. FieldFontCache.SCHEMA .. " definition at " .. path,
      { fontId = fontId, path = path }
    )
  end
  return definition --[[@as FieldFontDef]]
end

return FieldFontLoader
