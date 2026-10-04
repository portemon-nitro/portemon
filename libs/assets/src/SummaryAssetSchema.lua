-- Authoritative validation for the generated summary presentation class.
-- The manifest carries the canonical 256x192 panes, the three native
-- groups with their main/sub variants, semantic windows, realized visuals,
-- sprite roles, touch hitboxes, lowered text, palette roles, bar rules,
-- picture timelines with exact termination, ribbon definitions,
-- performance tables, dex mapping, memo records, sounds, and transitions.
-- Every loader, producer writer, and test calls these validators, so no
-- second interpretation of the shapes exists. Unknown fields, wrong pane
-- sizes, missing groups, non-integral timing, non-finite geometry, and
-- leaked source identities fail loudly. Love-free and filesystem-free.

local SchemaCheck = require("libs.assets.src.SchemaCheck")
local Validate = require("libs.assets.src.Validate")

---@class SummaryAssetSchema
local SummaryAssetSchema = {}

SummaryAssetSchema.SCHEMA = "g4-summary-manifest-v1"
SummaryAssetSchema.PANE_WIDTH = 256
SummaryAssetSchema.PANE_HEIGHT = 192

local CODE = "SUMMARY_MANIFEST_INVALID"

-- Producer-only identities that must never reach the runtime manifest.
-- Source archive, bank, and message identities stop at the compiler
-- boundary; the manifest carries semantic roles and cache paths only.
local SOURCE_KEYS = {
  narcId = true,
  bank = true,
  bankId = true,
  messageBank = true,
  messageId = true,
}

local GROUP_NAMES = { info = true, skills = true, performance = true }

local SEGMENT_KINDS = {
  text = true,
  species = true,
  nickname = true,
  otName = true,
  landmark = true,
  ability = true,
  move = true,
  item = true,
  month = true,
  number = true,
  idNumber = true,
  expToNext = true,
  expPoints = true,
  color = true,
  lineBreak = true,
}

local function fail(message, context)
  SchemaCheck.fail(CODE, message, context)
end

local function checkKeys(record, allowed, context, what)
  SchemaCheck.checkKeys(record, allowed, context, CODE, what)
  for key in pairs(record) do
    if SOURCE_KEYS[key] == true then
      fail(what .. " leaks source identity " .. tostring(key), context)
    end
  end
end

local function checkInt(value, context, what)
  SchemaCheck.checkInteger(value, context, CODE, what)
end

local function checkFinite(value, context, what)
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
    fail(what .. " must be a finite number", context)
  end
end

local function checkImagePath(value, context, what)
  if type(value) ~= "string" or value == "" then
    fail(what .. " must be a cache path", context)
  end
  if value:sub(1, #"assets/generated/summary/") ~= "assets/generated/summary/" then
    fail(what .. " must live in the summary family", context)
  end
end

local function checkPaneRect(value, context, what)
  if type(value) ~= "table" then
    fail(what .. " must be a record", context)
  end
  checkKeys(value, { x = true, y = true, width = true, height = true }, context, what)
  for _, axis in ipairs({ "x", "y", "width", "height" }) do
    if type(value[axis]) ~= "number" or value[axis] % 1 ~= 0 or value[axis] < 0 then
      fail(what .. "." .. axis .. " must be a non-negative integer", context)
    end
  end
  if value.width == 0 or value.height == 0 then
    fail(what .. " must have positive dimensions", context)
  end
  if
    value.x + value.width > SummaryAssetSchema.PANE_WIDTH or value.y + value.height > SummaryAssetSchema.PANE_HEIGHT
  then
    fail(what .. " escapes the canonical pane", context)
  end
end

local function checkVisual(value, context, what)
  if type(value) ~= "table" then
    fail(what .. " must be a record", context)
  end
  checkKeys(value, { image = true, width = true, height = true, offset = true }, context, what)
  checkImagePath(value.image, context, what .. ".image")
  for _, axis in ipairs({ "width", "height" }) do
    if type(value[axis]) ~= "number" or value[axis] % 1 ~= 0 or value[axis] <= 0 then
      fail(what .. "." .. axis .. " must be a positive integer", context)
    end
  end
  if value.offset ~= nil then
    if type(value.offset) ~= "table" then
      fail(what .. ".offset must be a record", context)
    end
    checkKeys(value.offset, { x = true, y = true }, context, what .. ".offset")
    checkInt(value.offset.x, context, what .. ".offset.x")
    checkInt(value.offset.y, context, what .. ".offset.y")
  end
end

local function checkPaletteBlend(value, context, what)
  if type(value) ~= "table" then
    fail(what .. " must be a record", context)
  end
  checkKeys(value, { target = true, coefficient = true }, context, what)
  if type(value.target) ~= "table" then
    fail(what .. ".target must be a record", context)
  end
  checkKeys(value.target, { r = true, g = true, b = true }, context, what .. ".target")
  for _, channel in ipairs({ "r", "g", "b" }) do
    local component = value.target[channel]
    if type(component) ~= "number" or component % 1 ~= 0 or component < 0 or component > 31 then
      fail(what .. ".target." .. channel .. " must be a 5-bit component", context)
    end
  end
  checkInt(value.coefficient, context, what .. ".coefficient")
end

local function checkSample(value, context, what)
  if type(value) ~= "table" then
    fail(what .. " must be a record", context)
  end
  checkKeys(value, {
    durationTicks = true,
    frameIndex = true,
    offsetX = true,
    offsetY = true,
    scaleX = true,
    scaleY = true,
    rotationTurns = true,
    visible = true,
    paletteBlend = true,
  }, context, what)
  if type(value.durationTicks) ~= "number" or value.durationTicks % 1 ~= 0 or value.durationTicks <= 0 then
    fail(what .. ".durationTicks must be a positive integer", context)
  end
  if type(value.frameIndex) ~= "number" or value.frameIndex % 1 ~= 0 or value.frameIndex < 0 then
    fail(what .. ".frameIndex must be a non-negative integer", context)
  end
  for _, field in ipairs({ "offsetX", "offsetY", "scaleX", "scaleY", "rotationTurns" }) do
    checkFinite(value[field], context, what .. "." .. field)
  end
  if type(value.visible) ~= "boolean" then
    fail(what .. ".visible must be a boolean", context)
  end
  if value.paletteBlend ~= nil then
    checkPaletteBlend(value.paletteBlend, context, what .. ".paletteBlend")
  end
end

local function checkPicture(value, context, what)
  if type(value) ~= "table" then
    fail(what .. " must be a record", context)
  end
  checkKeys(value, {
    portrait = true,
    visual = true,
    cryDelayTicks = true,
    samples = true,
    terminal = true,
    loopFrom = true,
    placement = true,
  }, context, what)
  local hasPortrait = value.portrait ~= nil
  local hasVisual = value.visual ~= nil
  if hasPortrait == hasVisual then
    fail(what .. " carries exactly one of a portrait selector or a family visual", context)
  end
  if hasPortrait and (type(value.portrait) ~= "string" or value.portrait == "") then
    fail(what .. ".portrait must name its portrait selector", context)
  end
  if hasVisual then
    checkImagePath(value.visual, context, what .. ".visual")
  end
  checkInt(value.cryDelayTicks, context, what .. ".cryDelayTicks")
  if value.cryDelayTicks < 0 then
    fail(what .. ".cryDelayTicks must be non-negative", context)
  end
  if type(value.samples) ~= "table" or not Validate.isArray(value.samples) or #value.samples == 0 then
    fail(what .. " carries no samples", context)
  end
  for index, sample in ipairs(value.samples) do
    checkSample(sample, context, what .. ".samples[" .. index .. "]")
  end
  local hasTerminal = value.terminal ~= nil
  local hasLoop = value.loopFrom ~= nil
  if hasTerminal == hasLoop then
    fail(what .. " ends exactly once, by holding its terminal state or by naming its cycle", context)
  end
  if hasTerminal and type(value.terminal) ~= "table" then
    fail(what .. ".terminal must be a record", context)
  end
  if hasLoop then
    checkInt(value.loopFrom, context, what .. ".loopFrom")
    if value.loopFrom < 1 or value.loopFrom > #value.samples then
      fail(what .. ".loopFrom must address a sample", context)
    end
  end
  if value.placement ~= nil then
    if type(value.placement) ~= "table" then
      fail(what .. ".placement must be a record", context)
    end
    checkKeys(value.placement, { offsetX = true, offsetY = true }, context, what .. ".placement")
    checkInt(value.placement.offsetX, context, what .. ".placement.offsetX")
    checkInt(value.placement.offsetY, context, what .. ".placement.offsetY")
  end
end

local function checkSegment(value, context, what)
  if type(value) ~= "table" then
    fail(what .. " must be a record", context)
  end
  checkKeys(value, { kind = true, value = true, color = true, flow = true, field = true }, context, what)
  if SEGMENT_KINDS[value.kind] == nil then
    fail(what .. ".kind is outside the text vocabulary", context)
  end
  if value.kind == "lineBreak" then
    if value.flow ~= nil and value.flow ~= "prompt" and value.flow ~= "page" then
      fail(what .. ".flow must be prompt or page", context)
    end
  elseif value.flow ~= nil then
    fail(what .. ".flow belongs to line breaks only", context)
  end
  if value.value ~= nil and type(value.value) ~= "string" then
    fail(what .. ".value must be text", context)
  end
  if value.color ~= nil then
    checkInt(value.color, context, what .. ".color")
  end
  if value.field ~= nil then
    checkInt(value.field, context, what .. ".field")
    if value.field < 0 then
      fail(what .. ".field must be non-negative", context)
    end
  end
end

local function checkTemplate(value, context, what)
  if type(value) ~= "table" then
    fail(what .. " must be a record", context)
  end
  checkKeys(value, { segments = true, alignment = true }, context, what)
  if type(value.segments) ~= "table" or #value.segments == 0 then
    fail(what .. " carries no segments", context)
  end
  for index, segment in ipairs(value.segments) do
    checkSegment(segment, context, what .. ".segments[" .. index .. "]")
  end
  if value.alignment ~= nil and value.alignment ~= "center" and value.alignment ~= "right" then
    fail(what .. ".alignment must be center or right", context)
  end
end

local function checkColor(value, context, what)
  if type(value) ~= "table" then
    fail(what .. " must be a record", context)
  end
  checkKeys(value, { r = true, g = true, b = true, a = true }, context, what)
  for _, channel in ipairs({ "r", "g", "b" }) do
    if type(value[channel]) ~= "number" or value[channel] % 1 ~= 0 or value[channel] < 0 or value[channel] > 255 then
      fail(what .. "." .. channel .. " must be a byte", context)
    end
  end
  if value.a ~= nil then
    if type(value.a) ~= "number" or value.a % 1 ~= 0 or value.a < 0 or value.a > 255 then
      fail(what .. ".a must be a byte", context)
    end
  end
end

local function checkRibbonEntry(value, context, what)
  if type(value) ~= "table" then
    fail(what .. " must be a record", context)
  end
  checkKeys(value, {
    key = true,
    bitGroup = true,
    bit = true,
    name = true,
    description = true,
    special = true,
    art = true,
  }, context, what)
  if type(value.key) ~= "string" or value.key == "" then
    fail(what .. ".key must name the ribbon", context)
  end
  if value.bitGroup ~= "ds1" and value.bitGroup ~= "gba" and value.bitGroup ~= "ds2" then
    fail(what .. ".bitGroup must be ds1, gba, or ds2", context)
  end
  checkInt(value.bit, context, what .. ".bit")
  if value.bit < 0 or value.bit > 31 then
    fail(what .. ".bit must address a boxed bit", context)
  end
  if type(value.name) ~= "string" or value.name == "" then
    fail(what .. ".name must reference its name template", context)
  end
  if type(value.description) ~= "string" or value.description == "" then
    fail(what .. ".description must reference its description template", context)
  end
  if value.special ~= nil then
    checkInt(value.special, context, what .. ".special")
    if value.special < 0 then
      fail(what .. ".special must be non-negative", context)
    end
  end
  if type(value.art) ~= "table" then
    fail(what .. ".art must be a record", context)
  end
  checkKeys(value.art, { image = true, width = true, height = true, palette = true }, context, what .. ".art")
  checkImagePath(value.art.image, context, what .. ".art.image")
  for _, axis in ipairs({ "width", "height" }) do
    if type(value.art[axis]) ~= "number" or value.art[axis] % 1 ~= 0 or value.art[axis] <= 0 then
      fail(what .. ".art." .. axis .. " must be a positive integer", context)
    end
  end
  checkInt(value.art.palette, context, what .. ".art.palette")
  if value.art.palette < 0 then
    fail(what .. ".art.palette must be non-negative", context)
  end
end

local function checkStatRow(value, context, what)
  if type(value) ~= "table" then
    fail(what .. " must be a record", context)
  end
  checkKeys(value, { base = true, lo = true, hi = true }, context, what)
  for _, field in ipairs({ "base", "lo", "hi" }) do
    checkInt(value[field], context, what .. "." .. field)
  end
end

---@param manifest table<string, unknown>
function SummaryAssetSchema.assertManifest(manifest)
  if type(manifest) ~= "table" then
    fail("the summary manifest must be a record", {})
  end
  local root = manifest --[[@as table<string, unknown>]]
  checkKeys(root, {
    schema = true,
    paneSize = true,
    groups = true,
    windows = true,
    visuals = true,
    sprites = true,
    hitboxes = true,
    text = true,
    palettes = true,
    bars = true,
    pictures = true,
    ribbons = true,
    performance = true,
    dexNumbers = true,
    memo = true,
    sounds = true,
    transitions = true,
  }, {}, "manifest")
  if root.schema ~= SummaryAssetSchema.SCHEMA then
    fail("the summary manifest carries schema " .. tostring(root.schema), {})
  end
  if type(root.paneSize) ~= "table" then
    fail("manifest.paneSize must be a record", {})
  end
  local paneSize = root.paneSize --[[@as table<string, unknown>]]
  checkKeys(paneSize, { width = true, height = true }, {}, "manifest.paneSize")
  if paneSize.width ~= SummaryAssetSchema.PANE_WIDTH or paneSize.height ~= SummaryAssetSchema.PANE_HEIGHT then
    fail("manifest.paneSize must be the canonical 256x192 pane", {})
  end
  if type(root.groups) ~= "table" then
    fail("manifest.groups must be a record", {})
  end
  local groups = root.groups --[[@as table<string, unknown>]]
  checkKeys(groups, GROUP_NAMES, {}, "manifest.groups")
  for name in pairs(GROUP_NAMES) do
    local group = groups[name]
    if type(group) ~= "table" then
      fail("manifest.groups." .. name .. " must be a record", {})
    end
    local typed = group --[[@as table<string, unknown>]]
    if type(typed.main) ~= "table" then
      fail("manifest.groups." .. name .. ".main must be a record", {})
    end
    if type(typed.sub) ~= "table" then
      fail("manifest.groups." .. name .. ".sub must be a record", {})
    end
  end
  if type(root.windows) ~= "table" then
    fail("manifest.windows must be a record", {})
  end
  for name, window in
    pairs(root.windows --[[@as table<string, unknown>]])
  do
    local what = "manifest.windows." .. tostring(name)
    if type(window) ~= "table" then
      fail(what .. " must be a record", {})
    end
    local typed = window --[[@as table<string, unknown>]]
    checkKeys(typed, { pane = true, rect = true, palette = true }, {}, what)
    if typed.pane ~= "main" and typed.pane ~= "sub" then
      fail(what .. ".pane must name a native pane", {})
    end
    checkPaneRect(typed.rect, {}, what .. ".rect")
    checkInt(typed.palette, {}, what .. ".palette")
    if
      typed.palette --[[@as integer]]
      < 0
    then
      fail(what .. ".palette must be non-negative", {})
    end
  end
  if type(root.visuals) ~= "table" then
    fail("manifest.visuals must be a record", {})
  end
  for name, visual in
    pairs(root.visuals --[[@as table<string, unknown>]])
  do
    checkVisual(visual, {}, "manifest.visuals." .. tostring(name))
  end
  if type(root.sprites) ~= "table" then
    fail("manifest.sprites must be a record", {})
  end
  for name, sprite in
    pairs(root.sprites --[[@as table<string, unknown>]])
  do
    local what = "manifest.sprites." .. tostring(name)
    if type(sprite) ~= "table" then
      fail(what .. " must be a record", {})
    end
    local typed = sprite --[[@as table<string, unknown>]]
    checkKeys(typed, { visual = true, anchor = true, order = true }, {}, what)
    if type(typed.visual) ~= "string" or typed.visual == "" then
      fail(what .. ".visual must name its visual", {})
    end
    if type(typed.anchor) ~= "table" then
      fail(what .. ".anchor must be a record", {})
    end
    local anchor = typed.anchor --[[@as table<string, unknown>]]
    checkKeys(anchor, { x = true, y = true }, {}, what .. ".anchor")
    checkInt(anchor.x, {}, what .. ".anchor.x")
    checkInt(anchor.y, {}, what .. ".anchor.y")
    checkInt(typed.order, {}, what .. ".order")
  end
  if type(root.hitboxes) ~= "table" then
    fail("manifest.hitboxes must be a record", {})
  end
  local hitboxes = root.hitboxes --[[@as table<string, unknown>]]
  checkKeys(hitboxes, { touch = true }, {}, "manifest.hitboxes")
  -- Touch targets are required content: native pointer control resolves
  -- through this set, so a family without hitboxes must not validate.
  -- Rows and cells stay separate boxes so blank-cell ineligibility
  -- remains representable to the consumer.
  if
    type(hitboxes.touch) ~= "table" or next(hitboxes.touch --[[@as table]]) == nil
  then
    fail("manifest.hitboxes.touch carries no touch target", {})
  end
  for name, box in
    pairs(hitboxes.touch --[[@as table<string, unknown>]])
  do
    local what = "manifest.hitboxes.touch." .. tostring(name)
    if type(box) ~= "table" then
      fail(what .. " must be a record", {})
    end
    local typed = box --[[@as table<string, unknown>]]
    checkKeys(typed, { top = true, bottom = true, left = true, right = true }, {}, what)
    for _, edge in ipairs({ "top", "bottom", "left", "right" }) do
      if type(typed[edge]) ~= "number" or typed[edge] % 1 ~= 0 or typed[edge] < 0 or typed[edge] > 255 then
        fail(what .. "." .. edge .. " must be a byte", {})
      end
    end
    local typedTop = typed.top --[[@as integer]]
    local typedBottom = typed.bottom --[[@as integer]]
    local typedLeft = typed.left --[[@as integer]]
    local typedRight = typed.right --[[@as integer]]
    if typedTop >= typedBottom or typedBottom > SummaryAssetSchema.PANE_HEIGHT then
      fail(what .. " has inverted vertical bounds", {})
    end
    local right = typedRight == 0 and SummaryAssetSchema.PANE_WIDTH or typedRight
    if typedLeft >= right or right > SummaryAssetSchema.PANE_WIDTH then
      fail(what .. " has inverted horizontal bounds", {})
    end
  end
  if type(root.text) ~= "table" then
    fail("manifest.text must be a record", {})
  end
  local text = root.text --[[@as table<string, unknown>]]
  checkKeys(text, { labels = true, templates = true, roles = true }, {}, "manifest.text")
  if text.labels ~= nil then
    if type(text.labels) ~= "table" then
      fail("manifest.text.labels must be a record", {})
    end
    for name, label in
      pairs(text.labels --[[@as table<string, unknown>]])
    do
      if type(label) ~= "string" or label == "" then
        fail("manifest.text.labels." .. tostring(name) .. " must be display text", {})
      end
    end
  end
  if text.templates ~= nil then
    if type(text.templates) ~= "table" then
      fail("manifest.text.templates must be a record", {})
    end
    for name, template in
      pairs(text.templates --[[@as table<string, unknown>]])
    do
      checkTemplate(template, {}, "manifest.text.templates." .. tostring(name))
    end
  end
  if text.roles ~= nil then
    if type(text.roles) ~= "table" then
      fail("manifest.text.roles must be a record", {})
    end
    for name, role in
      pairs(text.roles --[[@as table<string, unknown>]])
    do
      local what = "manifest.text.roles." .. tostring(name)
      if type(role) ~= "table" then
        fail(what .. " must be a record", {})
      end
      local typed = role --[[@as table<string, unknown>]]
      checkKeys(typed, { foreground = true, shadow = true, background = true }, {}, what)
      checkColor(typed.foreground, {}, what .. ".foreground")
      checkColor(typed.shadow, {}, what .. ".shadow")
      checkColor(typed.background, {}, what .. ".background")
    end
  end
  if type(root.palettes) ~= "table" then
    fail("manifest.palettes must be a record", {})
  end
  local palettes = root.palettes --[[@as table<string, unknown>]]
  checkKeys(palettes, { banks = true }, {}, "manifest.palettes")
  if palettes.banks ~= nil then
    if type(palettes.banks) ~= "table" then
      fail("manifest.palettes.banks must be a record", {})
    end
    for name, bank in
      pairs(palettes.banks --[[@as table<string, unknown>]])
    do
      local what = "manifest.palettes.banks." .. tostring(name)
      if type(bank) ~= "table" then
        fail(what .. " must be a record", {})
      end
      if not Validate.isArray(bank) or #bank == 0 then
        fail(what .. " carries no colors", {})
      end
      for index, color in
        ipairs(bank --[[@as table[] ]])
      do
        checkColor(color, {}, what .. "[" .. index .. "]")
      end
    end
  end
  if type(root.bars) ~= "table" then
    fail("manifest.bars must be a record", {})
  end
  local bars = root.bars --[[@as table<string, unknown>]]
  checkKeys(bars, { hp = true, exp = true }, {}, "manifest.bars")
  -- Bar rules are required content: read-only facts project the gauge
  -- fill through the health and experience lengths, so a family missing
  -- either track must not validate.
  for _, name in ipairs({ "hp", "exp" }) do
    local bar = bars[name]
    if bar == nil then
      fail("manifest.bars." .. name .. " carries no bar rule", {})
    end
    local what = "manifest.bars." .. name
    if type(bar) ~= "table" then
      fail(what .. " must be a record", {})
    end
    local typed = bar --[[@as table<string, unknown>]]
    checkKeys(typed, { length = true, colors = true, empty = true, full = true }, {}, what)
    checkInt(typed.length, {}, what .. ".length")
    if
      typed.length --[[@as integer]]
      <= 0
    then
      fail(what .. ".length must be positive", {})
    end
    if type(typed.colors) ~= "table" then
      fail(what .. ".colors must be a record", {})
    end
    for colorName, color in
      pairs(typed.colors --[[@as table<string, unknown>]])
    do
      checkColor(color, {}, what .. ".colors." .. tostring(colorName))
    end
    checkVisual(typed.empty, {}, what .. ".empty")
    checkVisual(typed.full, {}, what .. ".full")
  end
  if type(root.pictures) ~= "table" then
    fail("manifest.pictures must be a record", {})
  end
  for name, picture in
    pairs(root.pictures --[[@as table<string, unknown>]])
  do
    checkPicture(picture, {}, "manifest.pictures." .. tostring(name))
  end
  if type(root.ribbons) ~= "table" then
    fail("manifest.ribbons must be a record", {})
  end
  local ribbons = root.ribbons --[[@as table<string, unknown>]]
  checkKeys(
    ribbons,
    { entries = true, initialSpecialDescriptions = true, descriptionChoices = true },
    {},
    "manifest.ribbons"
  )
  if ribbons.entries ~= nil then
    if type(ribbons.entries) ~= "table" then
      fail("manifest.ribbons.entries must be a record", {})
    end
    if Validate.isArray(ribbons.entries) then
      for index, entry in
        ipairs(ribbons.entries --[[@as table[] ]])
      do
        checkRibbonEntry(entry, {}, "manifest.ribbons.entries[" .. index .. "]")
      end
    elseif
      next(ribbons.entries --[[@as table<string, unknown>]]) ~= nil
    then
      fail("manifest.ribbons.entries must be an array", {})
    end
  end
  if ribbons.initialSpecialDescriptions ~= nil and type(ribbons.initialSpecialDescriptions) ~= "table" then
    fail("manifest.ribbons.initialSpecialDescriptions must be a record", {})
  end
  if ribbons.descriptionChoices ~= nil then
    if type(ribbons.descriptionChoices) ~= "table" then
      fail("manifest.ribbons.descriptionChoices must be a record", {})
    end
    local choices = ribbons.descriptionChoices --[[@as table<string, unknown>]]
    checkKeys(choices, { base = true, slots = true }, {}, "manifest.ribbons.descriptionChoices")
    checkInt(choices.base, {}, "manifest.ribbons.descriptionChoices.base")
    if type(choices.slots) ~= "table" or not Validate.isArray(choices.slots) then
      fail("manifest.ribbons.descriptionChoices.slots must be an array", {})
    end
    for index, slot in
      ipairs(choices.slots --[[@as table[] ]])
    do
      checkInt(slot, {}, "manifest.ribbons.descriptionChoices.slots[" .. index .. "]")
    end
  end
  if type(root.performance) ~= "table" then
    fail("manifest.performance must be a record", {})
  end
  local performance = root.performance --[[@as table<string, unknown>]]
  checkKeys(performance, { forms = true, natureModifiers = true, zeroAprijuice = true }, {}, "manifest.performance")
  if performance.forms ~= nil then
    if type(performance.forms) ~= "table" then
      fail("manifest.performance.forms must be a record", {})
    end
    for name, form in
      pairs(performance.forms --[[@as table<string, unknown>]])
    do
      local what = "manifest.performance.forms." .. tostring(name)
      if type(form) ~= "table" then
        fail(what .. " must be a record", {})
      end
      local typed = form --[[@as table<string, unknown>]]
      checkKeys(typed, { power = true, stamina = true, skill = true, jump = true, speed = true }, {}, what)
      for _, stat in ipairs({ "power", "stamina", "skill", "jump", "speed" }) do
        checkStatRow(typed[stat], {}, what .. "." .. stat)
      end
    end
  end
  if performance.natureModifiers ~= nil then
    if type(performance.natureModifiers) ~= "table" then
      fail("manifest.performance.natureModifiers must be a record", {})
    end
    local modifiers = performance.natureModifiers --[[@as table[] ]]
    if Validate.isArray(modifiers) then
      if #modifiers ~= 25 then
        fail("manifest.performance.natureModifiers must carry twenty-five natures", {})
      end
      for nature, row in ipairs(modifiers) do
        local what = "manifest.performance.natureModifiers[" .. nature .. "]"
        if type(row) ~= "table" then
          fail(what .. " must be a record", {})
        end
        local typed = row --[[@as table<string, unknown>]]
        checkKeys(typed, { power = true, skill = true, speed = true, jump = true, stamina = true }, {}, what)
        for _, stat in ipairs({ "power", "skill", "speed", "jump", "stamina" }) do
          checkInt(typed[stat], {}, what .. "." .. stat)
        end
      end
    elseif
      next(modifiers --[[@as table<string, unknown>]]) ~= nil
    then
      fail("manifest.performance.natureModifiers must be an array", {})
    end
  end
  if performance.zeroAprijuice ~= nil then
    if type(performance.zeroAprijuice) ~= "table" then
      fail("manifest.performance.zeroAprijuice must be a record", {})
    end
    local zero = performance.zeroAprijuice --[[@as table<string, unknown>]]
    checkKeys(
      zero,
      { power = true, stamina = true, skill = true, jump = true, speed = true },
      {},
      "manifest.performance.zeroAprijuice"
    )
    for _, stat in ipairs({ "power", "stamina", "skill", "jump", "speed" }) do
      checkInt(zero[stat], {}, "manifest.performance.zeroAprijuice." .. stat)
      if zero[stat] ~= 0 then
        fail("manifest.performance.zeroAprijuice." .. stat .. " must be zero", {})
      end
    end
  end
  if type(root.dexNumbers) ~= "table" then
    fail("manifest.dexNumbers must be a record", {})
  end
  for name, numbers in
    pairs(root.dexNumbers --[[@as table<string, unknown>]])
  do
    local what = "manifest.dexNumbers." .. tostring(name)
    if type(numbers) ~= "table" then
      fail(what .. " must be a record", {})
    end
    local typed = numbers --[[@as table<string, unknown>]]
    checkKeys(typed, { national = true, regional = true }, {}, what)
    checkInt(typed.national, {}, what .. ".national")
    if
      typed.national --[[@as integer]]
      <= 0
    then
      fail(what .. ".national must be positive", {})
    end
    checkInt(typed.regional, {}, what .. ".regional")
    if
      typed.regional --[[@as integer]]
      < 0
    then
      fail(what .. ".regional must be non-negative", {})
    end
  end
  if type(root.memo) ~= "table" then
    fail("manifest.memo must be a record", {})
  end
  local memo = root.memo --[[@as table<string, unknown>]]
  checkKeys(memo, {
    conditions = true,
    months = true,
    landmarks = true,
    characteristics = true,
    flavors = true,
    eggWatch = true,
  }, {}, "manifest.memo")
  if memo.conditions ~= nil then
    if type(memo.conditions) ~= "table" then
      fail("manifest.memo.conditions must be a record", {})
    end
    for name, condition in
      pairs(memo.conditions --[[@as table<string, unknown>]])
    do
      local what = "manifest.memo.conditions." .. tostring(name)
      if type(condition) ~= "table" then
        fail(what .. " must be a record", {})
      end
      local typed = condition --[[@as table<string, unknown>]]
      checkKeys(typed, {
        template = true,
        nature = true,
        date = true,
        characteristic = true,
        flavor = true,
        eggWatch = true,
      }, {}, what)
      if type(typed.template) ~= "string" or typed.template == "" then
        fail(what .. ".template must reference its template", {})
      end
      for _, line in ipairs({ "nature", "date", "characteristic", "flavor", "eggWatch" }) do
        checkInt(typed[line], {}, what .. "." .. line)
        if
          typed[line] --[[@as integer]]
          < 0
        then
          fail(what .. "." .. line .. " must be non-negative", {})
        end
      end
    end
  end
  for _, section in ipairs({ "months", "landmarks", "flavors", "eggWatch" }) do
    local list = memo[section]
    if list ~= nil and type(list) ~= "table" then
      fail("manifest.memo." .. section .. " must be a record", {})
    end
  end
  if memo.characteristics ~= nil and type(memo.characteristics) ~= "table" then
    fail("manifest.memo.characteristics must be a record", {})
  end
  -- Calibrated absences: sounds and transitions validate empty. The
  -- overlay resolves both at its state call sites and no
  -- generated-family consumer reads these sections, so emptiness is the
  -- documented complete state. The closed keys and per-entry shape
  -- validators stay so a future populated section validates.
  if type(root.sounds) ~= "table" then
    fail("manifest.sounds must be a record", {})
  end
  for name, sound in
    pairs(root.sounds --[[@as table<string, unknown>]])
  do
    local what = "manifest.sounds." .. tostring(name)
    if type(sound) ~= "table" then
      fail(what .. " must be a record", {})
    end
    checkKeys(sound --[[@as table<string, unknown>]], { effect = true }, {}, what)
  end
  if type(root.transitions) ~= "table" then
    fail("manifest.transitions must be a record", {})
  end
  for name, transition in
    pairs(root.transitions --[[@as table<string, unknown>]])
  do
    local what = "manifest.transitions." .. tostring(name)
    if type(transition) ~= "table" then
      fail(what .. " must be a record", {})
    end
    checkKeys(transition --[[@as table<string, unknown>]], { durationTicks = true }, {}, what)
    checkInt(transition.durationTicks, {}, what .. ".durationTicks")
    if
      transition.durationTicks --[[@as integer]]
      <= 0
    then
      fail(what .. ".durationTicks must be positive", {})
    end
  end
  local seen = {}
  local function scanKeys(value, what)
    if type(value) ~= "table" or seen[value] then
      return
    end
    seen[value] = true
    for key, child in pairs(value) do
      if SOURCE_KEYS[key] == true then
        fail(what .. " leaks source identity " .. tostring(key), {})
      end
      scanKeys(child, what .. "." .. tostring(key))
    end
  end
  scanKeys(root, "manifest")
end

---@param manifest unknown
---@return boolean
function SummaryAssetSchema.isValidManifest(manifest)
  local ok = pcall(SummaryAssetSchema.assertManifest, manifest)
  return ok
end

return SummaryAssetSchema
