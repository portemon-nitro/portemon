-- A minimal generated Lugia reveal definition: the model keys and clip ids
-- the field scene resolves, without geometry or textures.

local LugiaAppearanceFixture = {}

---@return table<string, unknown>
function LugiaAppearanceFixture.definition()
  local eyeAnimations = {
    { id = "eye.color", frameCount = 61 },
    { id = "eye.pattern", frameCount = 61 },
    { id = "eye.joint", frameCount = 61 },
  }
  local lugiaAnimations = {
    { id = "lugia.joint", frameCount = 246 },
    { id = "lugia.color", frameCount = 246 },
    { id = "lugia.srt", frameCount = 246 },
    { id = "lugia.pattern", frameCount = 246 },
  }
  return {
    models = {
      { key = "field-effect:lugia-appearance:eyeGlimmer", animations = eyeAnimations },
      { key = "field-effect:lugia-appearance:cinematic.lugia.0", animations = lugiaAnimations },
      {
        key = "field-effect:lugia-appearance:cinematic.lugia.1",
        animations = { { id = "lugia.far.joint", frameCount = 246 } },
      },
    },
  }
end

return LugiaAppearanceFixture
