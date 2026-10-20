-- A minimal generated Ho-Oh appearance definition: the model keys and clip
-- ids the field scene resolves, without geometry or textures.

local HoOhAppearanceFixture = {}

---@return table<string, unknown>
function HoOhAppearanceFixture.definition()
  local clips = {
    "bell.rise.joint",
    "bell.rise.pattern",
    "bell.rise.srt",
    "bell.shimmer.joint",
    "bell.shimmer.srt",
    "corner_bells.srt",
    "bird.joint",
    "bird.color",
    "bird.pattern",
  }
  local animations = {}
  for index, id in ipairs(clips) do
    animations[index] = { id = id, frameCount = 10 }
  end
  local models = { { key = "field-effect:ho-oh-appearance:bellRising", animations = animations } }
  for _, shot in ipairs({ "first", "second" }) do
    for variant = 0, 2 do
      models[#models + 1] = {
        key = "field-effect:ho-oh-appearance:cinematic." .. shot .. "." .. variant,
        animations = { { id = "cinematic." .. shot .. "." .. variant .. ".trs", frameCount = shot == "first" and 141 or 206 } },
      }
    end
  end
  return { models = models }
end

return HoOhAppearanceFixture
