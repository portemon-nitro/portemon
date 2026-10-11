-- Shared stateless checks for the generated field-UI manifest.
local Errors = require("libs.errors.src.Errors")
local Validate = require("libs.assets.src.Validate")

local MANIFEST_INVALID = "FIELD_UI_MANIFEST_INVALID"
local RECT_FIELDS = { "x", "y", "width", "height" }
local RGB_CHANNELS = { "r", "g", "b" }

---@param message string
---@param context Errors.Context?
---@noreturn
local function reject(message, context)
  Errors.raise(MANIFEST_INVALID, message, context)
end

local function checkInteger(value, minimum, maximum, message, context)
  local valid
  if minimum == 0 and maximum == nil then
    valid = Validate.isNonNegativeInteger(value)
  else
    valid = type(value) == "number"
      and value % 1 == 0
      and (minimum == nil or value >= minimum)
      and (maximum == nil or value <= maximum)
  end
  if not valid then
    reject(message, context)
  end
end

local function checkByteColor(color, nilMessage, shapeMessage, channelMessage, context, channelKey)
  if color == nil then
    reject(nilMessage, context)
  end
  if type(color) ~= "table" then
    reject(shapeMessage, context)
  end
  for _, channel in ipairs(RGB_CHANNELS) do
    local value = color[channel]
    if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > 255 then
      if channelKey ~= nil then
        local failure = { [channelKey] = channel }
        for key, entry in pairs(context) do
          failure[key] = entry
        end
        reject(channelMessage, failure)
      end
      reject(channelMessage, context)
    end
  end
end

-- Single scalar gate: every integral domain in this validator funnels
-- through here. Unbounded non-negative integers reuse the shared predicate;
-- any other bound stays explicit per domain.

local function checkRect(rect, what, limitWidth, limitHeight, outsideMessage, outsideContext)
  if type(rect) ~= "table" then
    reject(what .. " must be a rectangle", { what = what })
  end
  for _, field in ipairs(RECT_FIELDS) do
    checkInteger(rect[field], 0, nil, what .. " " .. field .. " must be a non-negative integer", {
      what = what,
      field = field,
    })
  end
  if rect.width == 0 or rect.height == 0 then
    reject(what .. " must be non-empty", { what = what })
  end
  if rect.x + rect.width > limitWidth or rect.y + rect.height > limitHeight then
    reject(outsideMessage, outsideContext)
  end
end

-- Rejects unless `color` carries integral byte RGB channels. An absent
-- slot reports `nilMessage`; a present-but-misshapen slot reports
-- `shapeMessage`; a bad channel reports `channelMessage`. `context`
-- carries the fixed diagnostic fields and gains the failing channel under
-- `channelKey` when one is named.

local function checkAtlasRect(rect, atlases, atlasKey, what)
  local atlas = atlases[atlasKey]
  local message = what .. " escapes its atlas " .. atlasKey
  local context = { what = what, atlas = atlasKey }
  if atlas == nil then
    reject(message, context)
  else
    checkRect(rect, what, atlas.width, atlas.height, message, context)
  end
end

local function checkStrip(rect, atlases, atlasKey, what, width)
  checkAtlasRect(rect, atlases, atlasKey, what)
  if rect.width ~= width or rect.height ~= 8 then
    reject(what .. " must be the " .. width .. "x8 HGSS strip", {
      what = what,
      width = rect.width,
      height = rect.height,
    })
  end
end

local function checkPalette16(palette, what, extraContext)
  if type(palette) ~= "table" then
    reject(what .. " must be a table", {})
  end
  local function context(slot)
    local merged = { slot = slot }
    if extraContext ~= nil then
      for key, value in pairs(extraContext) do
        merged[key] = value
      end
    end
    return merged
  end
  for slot = 0, 15 do
    local missing = what .. " slot " .. slot .. " is missing"
    checkByteColor(
      palette[slot],
      missing,
      missing,
      what .. " slot " .. slot .. " must have byte RGB",
      context(slot),
      "component"
    )
  end
  for slot in pairs(palette) do
    checkInteger(slot, 0, 15, what .. " has an invalid slot", context(slot))
  end
end

-- Rejects unless `t` has exactly `count` pairs. The generated manifest names
-- several fixed-size tables (retail row/context/position counts, navigation
-- direction sets, per-record field sets); this is their single shared arity
-- gate instead of a repeated counting loop per call site.

local function demandDenseSequence(t, message, context)
  local count = 0
  for _ in pairs(t) do
    count = count + 1
  end
  if count == 0 or count ~= #t then
    reject(message, context)
  end
  return count
end

-- Rejects unless `palette` carries exactly slots 0..15, each an integral
-- byte-RGB color. Dialogue frames, the standard Yes/No frame, and every
-- signpost type share this exact 16-slot palette shape. `extraContext`
-- fields (such as the owning frame/type) are merged into every reported
-- diagnostic alongside the failing slot.

local function demandCount(t, count, message, context)
  local actual = 0
  for _ in pairs(t) do
    actual = actual + 1
  end
  if actual ~= count then
    reject(message, context)
  end
end

-- A rect must be an exact HGSS strip (`width` x 8) inside its atlas.
-- Dialogue/signpost frames are the 18-tile 144x8 row; wayfinding rects
-- are validated separately as 48x32 final surfaces. The atlas-bound check
-- additionally proves the rect is addressable in its PNG.

local function checkFrameOffset(offset, message, context)
  if
    type(offset) ~= "table"
    or type(offset.x) ~= "number"
    or offset.x % 1 ~= 0
    or type(offset.y) ~= "number"
    or offset.y % 1 ~= 0
  then
    reject(message, context)
  end
end

-- Rejects unless `t` is a dense, non-empty array (no holes, no non-integer
-- keys). Returns its length. Animation frame lists and per-frame icon
-- parts share this shape.

local function checkSpriteVisual(visual, atlases, what)
  if type(visual) ~= "table" then
    reject(what .. " must be a table", { what = what })
  end
  if type(visual.asset) ~= "string" or atlases[visual.asset] == nil then
    reject(what .. " must reference an indexed asset", { what = what })
  end
  checkAtlasRect(visual.rect, atlases, visual.asset, what .. " rect")
  checkFrameOffset(visual.offset, what .. " must carry an integral frame offset", { what = what })
end

-- One generated frame offset: a signed integral pair. A frame may extend
-- left/up of its source anchor, so only integrality is required here.

local function isSignedInteger(value)
  return type(value) == "number" and value % 1 == 0 and value ~= math.huge and value ~= -math.huge
end

local function checkSignedPoint(point, message)
  if type(point) ~= "table" or not isSignedInteger(point.x) or not isSignedInteger(point.y) then
    reject(message, {})
  end
end

-- One signed integral coordinate: icon parts and Pokemon anchors may extend
-- left/up of their source origin, so only finite integrality is required.

local function checkCanonicalPoint(point, what)
  if
    type(point) ~= "table"
    or not Validate.isNonNegativeInteger(point.x)
    or not Validate.isNonNegativeInteger(point.y)
  then
    reject(what .. " must be a canonical integer point", { what = what })
  end
end

return {
  MANIFEST_INVALID = MANIFEST_INVALID,
  RECT_FIELDS = RECT_FIELDS,
  checkInteger = checkInteger,
  checkRect = checkRect,
  checkAtlasRect = checkAtlasRect,
  checkStrip = checkStrip,
  checkPalette16 = checkPalette16,
  demandDenseSequence = demandDenseSequence,
  demandCount = demandCount,
  checkSpriteVisual = checkSpriteVisual,
  checkFrameOffset = checkFrameOffset,
  checkSignedPoint = checkSignedPoint,
  isSignedInteger = isSignedInteger,
  checkCanonicalPoint = checkCanonicalPoint,
  reject = reject,
}
