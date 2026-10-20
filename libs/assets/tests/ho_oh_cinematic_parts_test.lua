-- The Ho-Oh cinematic shot is stored once for its three time-of-day variants:
-- a shared part (animations and materials without the strings that differ per
-- variant) plus one overlay per variant. Splitting is lossless and refuses
-- variants that differ in anything but those strings.

local Assert = require("tests.support.Assert")
local HoOhCinematicParts = require("libs.assets.src.field.HoOhCinematicParts")

local T = {}

local function descriptor(variant)
  return {
    key = "field-effect:ho-oh-appearance:cinematic.first." .. variant,
    kind = "nitro-dynamic",
    schema = "g4-model-v1",
    memberId = 10 + variant,
    materials = {
      {
        id = 0,
        name = "m0",
        texture = "assets/tex" .. variant,
        wrap = { x = "repeat", y = "clamp" },
        variants = { { texture = "assets/alt" .. variant, frame = 1 }, { texture = "assets/alt" .. variant .. "b", frame = 2 } },
      },
      { id = 1, name = "m1" },
    },
    dynamic = { batches = { { geometry = "assets/geo" .. variant, lightMask = variant } }, nodes = { { index = 0 } } },
    animations = {
      {
        id = "cinematic.first." .. variant .. ".trs",
        name = "ho_s02_" .. variant,
        semanticNames = { "cinematic.first." .. variant .. ".trs" },
        category = "joint",
        kind = "trs",
        frameCount = 135,
        compiled = { pivotData = { { 1, 2, 3, 4, 5 } }, targets = { { nodeIndex = 0 } } },
      },
      {
        id = "cinematic.first." .. variant .. ".color",
        name = "ho_s02_c" .. variant,
        semanticNames = { "cinematic.first." .. variant .. ".color" },
        category = "material",
        kind = "color",
        frameCount = 141,
        compiled = { frames = { 1, 2, 3 } },
      },
    },
  }
end

local function variants()
  return { descriptor(0), descriptor(1), descriptor(2) }
end

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = copy(v)
  end
  return out
end

function T.split_then_merge_reproduces_every_variant_descriptor()
  local models = variants()
  local shared, overlays = HoOhCinematicParts.split("first", models)
  Assert.equal(#overlays, 3)
  for variant = 0, 2 do
    Assert.deepEqual(HoOhCinematicParts.merge(shared, overlays[variant + 1]), models[variant + 1], "variant " .. variant)
  end
end

function T.shared_part_carries_no_per_variant_strings()
  local shared = HoOhCinematicParts.split("first", variants())
  Assert.equal(shared.shot, "first")
  Assert.equal(shared.kind, "nitro-dynamic")
  for _, clip in ipairs(shared.animations) do
    Assert.isNil(clip.id)
    Assert.isNil(clip.name)
    Assert.isNil(clip.semanticNames)
    Assert.notNil(clip.compiled)
    Assert.notNil(clip.frameCount)
  end
  for _, material in ipairs(shared.materials) do
    Assert.isNil(material.texture)
    for _, entry in ipairs(material.variants or {}) do
      Assert.isNil(entry.texture)
      Assert.notNil(entry.frame)
    end
  end
  local fields = shared --[[@as table]]
  Assert.isNil(fields.dynamic)
  Assert.isNil(fields.key)
end

function T.overlay_carries_what_differs_per_variant()
  local models = variants()
  local _, overlays = HoOhCinematicParts.split("first", models)
  local overlay = overlays[2]
  Assert.equal(overlay.shot, "first")
  Assert.equal(overlay.variant, 1)
  Assert.equal(overlay.key, models[2].key)
  Assert.equal(overlay.memberId, models[2].memberId)
  Assert.deepEqual(overlay.dynamic, models[2].dynamic)
  Assert.equal(overlay.clipStrings[1].name, "ho_s02_1")
  Assert.equal(overlay.materialTextures[1].texture, "assets/tex1")
  Assert.isNil(overlay.materialTextures[2].texture)
end

function T.split_rejects_variants_that_differ_beyond_the_stripped_strings()
  local models = variants()
  models[3].animations[1].frameCount = 136
  local err = Assert.throws(function()
    HoOhCinematicParts.split("first", models)
  end, "a variant that differs in animation data cannot share a part")
  Assert.equal(err.code, "FIELD_EFFECT_SOURCE_INVALID")
  models = variants()
  models[2].materials[1].wrap.x = "clamp"
  Assert.throws(function()
    HoOhCinematicParts.split("first", models)
  end, "a variant that differs in material data cannot share a part")
end

function T.merge_leaves_the_shared_part_untouched()
  local shared, overlays = HoOhCinematicParts.split("first", variants())
  local before = copy(shared)
  HoOhCinematicParts.merge(shared, overlays[1])
  HoOhCinematicParts.merge(shared, overlays[3])
  Assert.deepEqual(shared, before)
end

function T.merge_rejects_an_overlay_for_a_different_clip_or_material_count()
  local shared, overlays = HoOhCinematicParts.split("first", variants())
  local shortClips = copy(overlays[1])
  shortClips.clipStrings[2] = nil
  Assert.throws(function()
    HoOhCinematicParts.merge(shared, shortClips)
  end, "overlay clip count must match the shared part")
  local shortMaterials = copy(overlays[1])
  shortMaterials.materialTextures[2] = nil
  Assert.throws(function()
    HoOhCinematicParts.merge(shared, shortMaterials)
  end, "overlay material count must match the shared part")
  local wrongShot = copy(overlays[1])
  wrongShot.shot = "second"
  Assert.throws(function()
    HoOhCinematicParts.merge(shared, wrongShot)
  end, "overlay shot must match the shared part")
end

return { tests = T }
