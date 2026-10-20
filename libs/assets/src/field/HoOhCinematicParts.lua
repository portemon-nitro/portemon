-- Storage layout of one Ho-Oh cinematic shot. The three time-of-day variants
-- of a shot carry identical animation and material data except for strings
-- (clip ids/names, texture paths), so a shot is stored as one shared part
-- (animations and materials without those strings) plus one overlay per
-- variant (those strings, the variant's dynamic model, key and member id).
-- `split` is lossless and refuses variants that differ in anything else;
-- `merge` reassembles the full model descriptor a variant had before the split.
-- Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")

local HoOhCinematicParts = {}

local VARIANT_COUNT = 3
local CLIP_STRING_FIELDS = { "id", "name", "semanticNames" }

---@class HoOhCinematicParts.Shared
---@field shot string
---@field kind string
---@field schema string
---@field animations table[] clips without id, name, semanticNames
---@field materials table[] materials without texture paths

---@class HoOhCinematicParts.Overlay
---@field shot string
---@field variant integer
---@field key string
---@field memberId integer
---@field dynamic table<string, unknown>
---@field clipStrings table[] one { id, name, semanticNames } per shared clip
---@field materialTextures table[] one { texture, variants } per shared material

local function invalid(message, context)
  Errors.raise("FIELD_EFFECT_SOURCE_INVALID", message, context)
end

local function shallowCopy(value)
  local out = {}
  for k, v in pairs(value) do
    out[k] = v
  end
  return out
end

local function equalValues(a, b)
  if type(a) ~= type(b) then
    return false
  end
  if type(a) ~= "table" then
    return a == b
  end
  for k, v in pairs(a) do
    if not equalValues(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

local function strippedClips(model)
  local out = {}
  for index, clip in ipairs(model.animations) do
    local stripped = shallowCopy(clip)
    for _, field in ipairs(CLIP_STRING_FIELDS) do
      stripped[field] = nil
    end
    out[index] = stripped
  end
  return out
end

local function strippedMaterials(model)
  local out = {}
  for index, material in ipairs(model.materials) do
    local stripped = shallowCopy(material)
    stripped.texture = nil
    if material.variants ~= nil then
      stripped.variants = {}
      for variantIndex, entry in ipairs(material.variants) do
        local entryCopy = shallowCopy(entry)
        entryCopy.texture = nil
        stripped.variants[variantIndex] = entryCopy
      end
    end
    out[index] = stripped
  end
  return out
end

local function clipStrings(model)
  local out = {}
  for index, clip in ipairs(model.animations) do
    out[index] = { id = clip.id, name = clip.name, semanticNames = clip.semanticNames }
  end
  return out
end

local function materialTextures(model)
  local out = {}
  for index, material in ipairs(model.materials) do
    local entry = { texture = material.texture }
    if material.variants ~= nil then
      entry.variants = {}
      for variantIndex, variant in ipairs(material.variants) do
        entry.variants[variantIndex] = variant.texture
      end
    end
    out[index] = entry
  end
  return out
end

-- Splits the three variant descriptors of one shot (index 1 is variant 0).
---@param shot string
---@param models table[] full descriptors, variants 0..2
---@return HoOhCinematicParts.Shared shared
---@return HoOhCinematicParts.Overlay[] overlays
function HoOhCinematicParts.split(shot, models)
  assert(type(shot) == "string" and shot ~= "", "cinematic shot name is required")
  assert(#models == VARIANT_COUNT, "a cinematic shot has three variants")
  local first = models[1]
  local shared = {
    shot = shot,
    kind = first.kind,
    schema = first.schema,
    animations = strippedClips(first),
    materials = strippedMaterials(first),
  }
  local overlays = {}
  for index, model in ipairs(models) do
    if model.kind ~= shared.kind or model.schema ~= shared.schema then
      invalid("Ho-Oh cinematic variants differ in model kind or schema", { shot = shot, variant = index - 1 })
    end
    if not equalValues(strippedClips(model), shared.animations) then
      invalid("Ho-Oh cinematic variants differ in animation data", { shot = shot, variant = index - 1 })
    end
    if not equalValues(strippedMaterials(model), shared.materials) then
      invalid("Ho-Oh cinematic variants differ in material data", { shot = shot, variant = index - 1 })
    end
    overlays[index] = {
      shot = shot,
      variant = index - 1,
      key = model.key,
      memberId = model.memberId,
      dynamic = model.dynamic,
      clipStrings = clipStrings(model),
      materialTextures = materialTextures(model),
    }
  end
  return shared, overlays
end

-- Reassembles one variant's full model descriptor. The shared part is not
-- modified; deeper animation and dynamic data is shared by reference.
---@param shared HoOhCinematicParts.Shared
---@param overlay HoOhCinematicParts.Overlay
---@return table<string, unknown> descriptor
function HoOhCinematicParts.merge(shared, overlay)
  if overlay.shot ~= shared.shot then
    invalid("Ho-Oh cinematic overlay is for another shot", { shared = shared.shot, overlay = overlay.shot })
  end
  if #overlay.clipStrings ~= #shared.animations or #overlay.materialTextures ~= #shared.materials then
    invalid("Ho-Oh cinematic overlay does not match its shared part", { shot = shared.shot, variant = overlay.variant })
  end
  local animations = {}
  for index, clip in ipairs(shared.animations) do
    local merged = shallowCopy(clip)
    local strings = overlay.clipStrings[index]
    merged.id, merged.name, merged.semanticNames = strings.id, strings.name, strings.semanticNames
    animations[index] = merged
  end
  local materials = {}
  for index, material in ipairs(shared.materials) do
    local merged = shallowCopy(material)
    local textures = overlay.materialTextures[index]
    merged.texture = textures.texture
    if material.variants ~= nil then
      if textures.variants == nil or #textures.variants ~= #material.variants then
        invalid("Ho-Oh cinematic overlay does not match its material variants", {
          shot = shared.shot,
          variant = overlay.variant,
          material = index,
        })
      end
      merged.variants = {}
      for variantIndex, entry in ipairs(material.variants) do
        local entryCopy = shallowCopy(entry)
        entryCopy.texture = textures.variants[variantIndex]
        merged.variants[variantIndex] = entryCopy
      end
    end
    materials[index] = merged
  end
  return {
    key = overlay.key,
    kind = shared.kind,
    schema = shared.schema,
    memberId = overlay.memberId,
    materials = materials,
    dynamic = overlay.dynamic,
    animations = animations,
  }
end

return HoOhCinematicParts
