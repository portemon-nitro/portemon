-- Shared Bag manifest checks backed by the one schema error contract.
local SchemaCheck = require("libs.assets.src.SchemaCheck")
local Validate = require("libs.assets.src.Validate")
local Checks = {}

local SOURCE_KEYS = {
  narcId = true,
  memberId = true,
  fileId = true,
  bgPriority = true,
  layer = true,
  cell = true,
  animIndex = true,
  paletteSlot = true,
  oam = true,
  template = true,
}

function Checks.reject(message, context)
  SchemaCheck.fail("BAG_MANIFEST_INVALID", message, context)
end

function Checks.checkKeys(record, allowed, context, what)
  SchemaCheck.checkKeys(record, allowed, context, "BAG_MANIFEST_INVALID", what)
end

function Checks.checkRecord(value, allowed, context, what, noun)
  SchemaCheck.checkRecord(value, allowed, context, "BAG_MANIFEST_INVALID", what, noun)
end

function Checks.checkInteger(value, context, what, minimum, maximum, expectation)
  SchemaCheck.checkInteger(value, context, "BAG_MANIFEST_INVALID", what, minimum, maximum, expectation)
end

function Checks.checkFixedArray(value, expected, context, message)
  if not Validate.isArray(value) or #value ~= expected then
    Checks.reject(message, context)
  end
end

function Checks.checkRect(value, context, what, paneWidth, paneHeight)
  Checks.checkRecord(value, { x = true, y = true, width = true, height = true }, context, what)
  for _, axis in ipairs({ "x", "y", "width", "height" }) do
    Checks.checkInteger(value[axis], context, what .. "." .. axis, 0, nil, "a non-negative integer")
  end
  if value.width == 0 or value.height == 0 then
    Checks.reject(what .. " must have positive dimensions", context)
  end
  if value.x + value.width > paneWidth or value.y + value.height > paneHeight then
    Checks.reject(what .. " escapes the canonical pane", context)
  end
end

function Checks.checkPoint(value, context, what, paneWidth, paneHeight)
  Checks.checkRecord(value, { x = true, y = true }, context, what)
  for _, axis in ipairs({ "x", "y" }) do
    Checks.checkInteger(value[axis], context, what .. "." .. axis, 0, nil, "a non-negative integer")
  end
  if value.x > paneWidth or value.y > paneHeight then
    Checks.reject(what .. " escapes the canonical pane", context)
  end
end

function Checks.checkImageFields(value, context, what)
  if type(value.image) ~= "string" or value.image == "" then
    Checks.reject(what .. ".image must be a non-empty path", context)
  end
  for _, axis in ipairs({ "width", "height" }) do
    Checks.checkInteger(value[axis], context, what .. "." .. axis, 1, nil, "a positive integer")
  end
end

function Checks.checkImage(value, context, what)
  Checks.checkRecord(value, { image = true, width = true, height = true }, context, what)
  Checks.checkImageFields(value, context, what)
end

function Checks.checkOffset(value, context, what)
  Checks.checkRecord(value, { x = true, y = true }, context, what)
  for _, axis in ipairs({ "x", "y" }) do
    if type(value[axis]) ~= "number" or value[axis] % 1 ~= 0 then
      Checks.reject(what .. "." .. axis .. " must be an integer", context)
    end
  end
end

function Checks.checkVisual(value, context, what)
  Checks.checkRecord(
    value,
    { image = true, width = true, height = true, offset = true },
    context,
    what,
    "a semantic visual"
  )
  Checks.checkImageFields(value, context, what)
  if value.offset ~= nil then
    Checks.checkOffset(value.offset, context, what .. ".offset")
  end
end

function Checks.checkFinite(value, context, what)
  if type(value) ~= "number" or value ~= value or value >= math.huge or value <= -math.huge then
    Checks.reject(what .. " must be a finite number", context)
  end
end

function Checks.checkNoSourceIdentities(value, context, what)
  if type(value) ~= "table" then
    if type(value) == "string" and value:find("NARC_", 1, true) ~= nil then
      Checks.reject(what .. " carries a source archive symbol", context)
    end
    return
  end
  for key, item in pairs(value) do
    if SOURCE_KEYS[key] then
      Checks.reject(what .. " carries a source identity field " .. tostring(key), context)
    end
    Checks.checkNoSourceIdentities(item, context, what .. "." .. tostring(key))
  end
end

return Checks
