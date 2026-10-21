-- A minimal generated Ho-Oh core record: the clip summary the field scene
-- reads, without model data.

local HoOhAppearanceFixture = {}

---@return table<string, unknown>
function HoOhAppearanceFixture.core()
  local frames = {}
  for _, id in ipairs({
    "bell.rise.joint",
    "bell.rise.pattern",
    "bell.rise.srt",
    "bell.shimmer.joint",
    "bell.shimmer.srt",
    "corner_bells.srt",
    "bird.joint",
    "bird.color",
    "bird.pattern",
  }) do
    frames[id] = 10
  end
  return {
    models = {},
    clips = { frames = frames, cinematic = { first = { 141, 141, 141 }, second = { 206, 206, 206 } } },
  }
end

---@return table<string, unknown>
function HoOhAppearanceFixture.definition()
  local core = HoOhAppearanceFixture.core()
  local models = {}
  for id, frameCount in pairs(core.clips.frames) do
    models[#models + 1] = {
      key = "field-effect:ho-oh-appearance:" .. id,
      animations = { { id = id, frameCount = frameCount } },
    }
  end
  for shot, variants in pairs(core.clips.cinematic) do
    for variant, frameCount in ipairs(variants) do
      models[#models + 1] = {
        key = "field-effect:ho-oh-appearance:cinematic." .. shot .. "." .. (variant - 1),
        animations = { { id = shot .. ".joint", frameCount = frameCount } },
      }
    end
  end
  return { models = models }
end

return HoOhAppearanceFixture
