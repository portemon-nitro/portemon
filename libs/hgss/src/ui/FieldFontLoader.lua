-- Loads the compiled dialogue font definition for runtime text layout. This
-- deliberately owns no atlas or graphics objects; presentation loads those
-- separately when it creates the dialogue renderer. A loaded definition must
-- satisfy the v5 asset contract before presentation construction: the seven
-- color bands over a positive base-band stride, an atlas tall enough for every
-- band, a named semantic glyph mask atlas path, and the four 24x32 focus frames
-- with four ordered palette-slot/rect records each. It delegates schema
-- validation to the generated asset owner before presentation construction.

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
  local valid, reason = FieldFontCache.validateDefinition(definition --[[@as table]])
  if not valid then
    Errors.raise(
      FieldErrors.FONT_DEF_INVALID,
      FieldFontCache.SCHEMA .. " definition at " .. path .. " is malformed: " .. reason,
      { fontId = fontId, path = path, reason = reason }
    )
  end
  return definition --[[@as FieldFontDef]]
end

return FieldFontLoader
