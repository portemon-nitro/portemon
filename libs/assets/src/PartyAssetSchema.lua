-- Authoritative validation for the generated party presentation class.
-- The manifest carries the canonical 256x192 panes, six slotted panels
-- pairing chrome variants with text/HP subrectangles, message/context
-- windows, cursor/ball/held/status/feedback visuals with source timing,
-- shared icon-animation expectations, dpad/touch navigation tables,
-- lowered bank-300 text, source numeric glyphs, and Shiny Leaf/crown badge
-- frames. Every loader, producer writer, and test calls these validators,
-- so no second interpretation of the shapes exists. Unknown fields, wrong
-- pane sizes, out-of-bounds geometry, wrong slot/digit/anchor cardinality,
-- non-integral timing, and leaked source identities fail loudly. Modded
-- frame counts, sizes, and palettes stay valid. Love-free and
-- filesystem-free.

local Errors = require("libs.errors.src.Errors")

---@class PartyAssetSchema
local PartyAssetSchema = {}

PartyAssetSchema.SCHEMA = "g4-party-presentation-v1"
PartyAssetSchema.PANE_WIDTH = 256
PartyAssetSchema.PANE_HEIGHT = 192
PartyAssetSchema.SLOT_COUNT = 6
PartyAssetSchema.DIGIT_COUNT = 10
PartyAssetSchema.LEAF_COUNT = 5

-- Producer-only identities that must never reach the runtime manifest.
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

local PLAYBACKS = { static = true, loop = true, once = true }
local SEGMENT_KINDS = {
  text = true,
  item = true,
  quantity = true,
  name = true,
  move = true,
  color = true,
  lineBreak = true,
}

local function fail(message, context)
  Errors.raise("PARTY_MANIFEST_INVALID", message, context or {})
end

local function checkKeys(record, allowed, context, what)
  for key in pairs(record) do
    if allowed[key] == nil then
      fail(what .. " carries an unknown field " .. tostring(key), context)
    end
    if SOURCE_KEYS[key] == true then
      fail(what .. " leaks source identity " .. tostring(key), context)
    end
  end
end

local function checkInt(value, context, what)
  if type(value) ~= "number" or value % 1 ~= 0 then
    fail(what .. " must be an integer", context)
  end
end

local function checkPoint(value, context, what)
  if type(value) ~= "table" then
    fail(what .. " must be a record", context)
  end
  checkKeys(value, { x = true, y = true }, context, what)
  checkInt(value.x, context, what .. ".x")
  checkInt(value.y, context, what .. ".y")
end

local function checkRect(value, context, what)
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
  if value.x + value.width > PartyAssetSchema.PANE_WIDTH or value.y + value.height > PartyAssetSchema.PANE_HEIGHT then
    fail(what .. " escapes the canonical pane", context)
  end
end

local function checkVisual(value, context, what)
  if type(value) ~= "table" then
    fail(what .. " must be a record", context)
  end
  checkKeys(value, { image = true, width = true, height = true }, context, what)
  if type(value.image) ~= "string" or value.image == "" then
    fail(what .. ".image must be a cache path", context)
  end
  if value.image:sub(1, #"assets/generated/party/") ~= "assets/generated/party/" then
    fail(what .. ".image must live in the party family", context)
  end
  for _, axis in ipairs({ "width", "height" }) do
    if type(value[axis]) ~= "number" or value[axis] % 1 ~= 0 or value[axis] <= 0 then
      fail(what .. "." .. axis .. " must be a positive integer", context)
    end
  end
end

local function checkFrame(value, context, what)
  if type(value) ~= "table" then
    fail(what .. " must be a record", context)
  end
  checkKeys(value, { image = true, width = true, height = true, offset = true, durationTicks = true }, context, what)
  checkVisual({ image = value.image, width = value.width, height = value.height }, context, what)
  if value.offset ~= nil then
    checkPoint(value.offset, context, what .. ".offset")
  end
  if type(value.durationTicks) ~= "number" or value.durationTicks % 1 ~= 0 or value.durationTicks <= 0 then
    fail(what .. ".durationTicks must be a positive integer", context)
  end
end

local function checkAnimated(value, context, what, allowHide)
  if type(value) ~= "table" then
    fail(what .. " must be a record", context)
  end
  local allowed = { frames = true, loopFrom = true, playback = true, hideAtFrame = true }
  checkKeys(value, allowed, context, what)
  if type(value.frames) ~= "table" or #value.frames == 0 then
    fail(what .. " carries no frames", context)
  end
  for index, frame in ipairs(value.frames) do
    checkFrame(frame, context, what .. ".frames[" .. index .. "]")
  end
  checkInt(value.loopFrom, context, what .. ".loopFrom")
  if value.loopFrom < 1 or value.loopFrom > #value.frames then
    fail(what .. ".loopFrom must address a frame", context)
  end
  if PLAYBACKS[value.playback] == nil then
    fail(what .. ".playback must be static, loop or once", context)
  end
  if value.hideAtFrame ~= nil and allowHide ~= true then
    fail(what .. ".hideAtFrame belongs to feedback only", context)
  end
  if value.hideAtFrame ~= nil then
    checkInt(value.hideAtFrame, context, what .. ".hideAtFrame")
    if value.hideAtFrame < 1 or value.hideAtFrame > #value.frames + 1 then
      fail(what .. ".hideAtFrame must address a frame boundary", context)
    end
  end
end

local function checkSequenceGroup(value, context, what)
  if type(value) ~= "table" then
    fail(what .. " must be a record", context)
  end
  checkKeys(value, { sequences = true }, context, what)
  if type(value.sequences) ~= "table" or #value.sequences == 0 then
    fail(what .. " carries no sequences", context)
  end
  for index, sequence in ipairs(value.sequences) do
    checkAnimated(sequence, context, what .. ".sequences[" .. index .. "]")
  end
end

local function checkPanel(value, context, what)
  if type(value) ~= "table" then
    fail(what .. " must be a record", context)
  end
  checkKeys(value, { origin = true, size = true, chrome = true, text = true, hp = true, compat = true }, context, what)
  checkPoint(value.origin, context, what .. ".origin")
  if type(value.size) ~= "table" then
    fail(what .. ".size must be a record", context)
  end
  checkKeys(value.size, { width = true, height = true }, context, what .. ".size")
  if value.size.width ~= 128 or value.size.height ~= 48 then
    fail(what .. ".size must be the canonical 128x48 panel", context)
  end
  if type(value.chrome) ~= "table" then
    fail(what .. ".chrome must be a record", context)
  end
  local variants = 0
  for name, visual in pairs(value.chrome) do
    checkVisual(visual, context, what .. ".chrome." .. tostring(name))
    variants = variants + 1
  end
  if variants == 0 then
    fail(what .. ".chrome carries no variant", context)
  end
  if type(value.text) ~= "table" then
    fail(what .. ".text must be a record", context)
  end
  checkKeys(value.text, { name = true, level = true }, context, what .. ".text")
  checkRect(value.text.name, context, what .. ".text.name")
  checkRect(value.text.level, context, what .. ".text.level")
  if type(value.hp) ~= "table" then
    fail(what .. ".hp must be a record", context)
  end
  checkKeys(value.hp, { bar = true, number = true }, context, what .. ".hp")
  checkRect(value.hp.bar, context, what .. ".hp.bar")
  checkRect(value.hp.number, context, what .. ".hp.number")
  checkRect(value.compat, context, what .. ".compat")
end

local function checkTouchRect(value, context, what)
  if type(value) ~= "table" then
    fail(what .. " must be a record", context)
  end
  checkKeys(value, { top = true, bottom = true, left = true, right = true }, context, what)
  for _, edge in ipairs({ "top", "bottom", "left", "right" }) do
    if type(value[edge]) ~= "number" or value[edge] % 1 ~= 0 or value[edge] < 0 or value[edge] > 255 then
      fail(what .. "." .. edge .. " must be a byte", context)
    end
  end
  if value.top >= value.bottom or value.bottom > PartyAssetSchema.PANE_HEIGHT then
    fail(what .. " has inverted vertical bounds", context)
  end
  local right = value.right == 0 and PartyAssetSchema.PANE_WIDTH or value.right
  if value.left >= right or right > PartyAssetSchema.PANE_WIDTH then
    fail(what .. " has inverted horizontal bounds", context)
  end
end

local function checkDpadRow(value, context, what)
  if type(value) ~= "table" then
    fail(what .. " must be a record", context)
  end
  checkKeys(value, {
    left = true,
    top = true,
    width = true,
    height = true,
    up = true,
    down = true,
    leftNeighbor = true,
    rightNeighbor = true,
  }, context, what)
  for _, axis in ipairs({ "left", "top", "width", "height", "up", "down", "leftNeighbor", "rightNeighbor" }) do
    if type(value[axis]) ~= "number" or value[axis] % 1 ~= 0 or value[axis] < 0 or value[axis] > 255 then
      fail(what .. "." .. axis .. " must be a byte", context)
    end
  end
end

local function checkSegment(value, context, what)
  if type(value) ~= "table" then
    fail(what .. " must be a record", context)
  end
  checkKeys(value, { kind = true, value = true, color = true, flow = true }, context, what)
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
end

---@param manifest table<string, unknown>
function PartyAssetSchema.assertManifest(manifest)
  if type(manifest) ~= "table" then
    fail("the party manifest must be a record", {})
  end
  local root = manifest --[[@as table<string, unknown>]]
  checkKeys(root, {
    schema = true,
    panes = true,
    panels = true,
    windows = true,
    visuals = true,
    iconAnimations = true,
    navigation = true,
    hitboxes = true,
    text = true,
    numberGlyphs = true,
    shinyLeaves = true,
  }, {}, "manifest")
  if root.schema ~= PartyAssetSchema.SCHEMA then
    fail("the party manifest carries schema " .. tostring(root.schema), {})
  end
  if type(root.panes) ~= "table" then
    fail("manifest.panes must be a record", {})
  end
  checkKeys(root.panes, { main = true, sub = true }, {}, "manifest.panes")
  for _, pane in ipairs({ "main", "sub" }) do
    local record = (root.panes --[[@as table<string, unknown>]])[pane]
    if type(record) ~= "table" then
      fail("manifest.panes." .. pane .. " must be a record", {})
    end
    local sized = record --[[@as table<string, unknown>]]
    if sized.width ~= PartyAssetSchema.PANE_WIDTH or sized.height ~= PartyAssetSchema.PANE_HEIGHT then
      fail("manifest.panes." .. pane .. " must be the canonical 256x192 pane", {})
    end
  end
  if type(root.panels) ~= "table" or #root.panels ~= PartyAssetSchema.SLOT_COUNT then
    fail("manifest.panels must carry six slots", {})
  end
  for slot = 1, PartyAssetSchema.SLOT_COUNT do
    checkPanel((root.panels --[[@as table[] ]])[slot], {}, "manifest.panels[" .. slot .. "]")
  end
  if type(root.windows) ~= "table" then
    fail("manifest.windows must be a record", {})
  end
  checkKeys(root.windows, { message = true, context = true }, {}, "manifest.windows")
  checkRect((root.windows --[[@as table<string, unknown>]]).message, {}, "manifest.windows.message")
  checkRect((root.windows --[[@as table<string, unknown>]]).context, {}, "manifest.windows.context")
  if type(root.visuals) ~= "table" then
    fail("manifest.visuals must be a record", {})
  end
  local visuals = root.visuals --[[@as table<string, unknown>]]
  checkKeys(visuals, {
    cursor = true,
    balls = true,
    buttons = true,
    held = true,
    status = true,
    feedback = true,
    backdropMain = true,
    backdropSub = true,
    detailSub = true,
    decoration = true,
    auxPanel = true,
  }, {}, "manifest.visuals")
  checkSequenceGroup(visuals.cursor, {}, "manifest.visuals.cursor")
  checkSequenceGroup(visuals.balls, {}, "manifest.visuals.balls")
  checkSequenceGroup(visuals.buttons, {}, "manifest.visuals.buttons")
  checkSequenceGroup(visuals.held, {}, "manifest.visuals.held")
  if type(visuals.status) ~= "table" then
    fail("manifest.visuals.status must be a record", {})
  end
  local status = visuals.status --[[@as table<string, unknown>]]
  checkKeys(status, { frames = true }, {}, "manifest.visuals.status")
  if type(status.frames) ~= "table" or #status.frames ~= 7 then
    fail("manifest.visuals.status.frames must carry seven state frames", {})
  end
  for index, visual in
    ipairs(status.frames --[[@as table[] ]])
  do
    checkVisual(visual, {}, "manifest.visuals.status.frames[" .. index .. "]")
  end
  checkAnimated(visuals.feedback, {}, "manifest.visuals.feedback", true)
  checkVisual(visuals.backdropMain, {}, "manifest.visuals.backdropMain")
  checkVisual(visuals.backdropSub, {}, "manifest.visuals.backdropSub")
  checkVisual(visuals.detailSub, {}, "manifest.visuals.detailSub")
  checkVisual(visuals.decoration, {}, "manifest.visuals.decoration")
  checkVisual(visuals.auxPanel, {}, "manifest.visuals.auxPanel")
  if type(root.iconAnimations) ~= "table" then
    fail("manifest.iconAnimations must be a record", {})
  end
  local icons = root.iconAnimations --[[@as table<string, unknown>]]
  checkKeys(
    icons,
    { periods = true, replacementDurations = true, replacementShift = true },
    {},
    "manifest.iconAnimations"
  )
  if type(icons.periods) ~= "table" or #icons.periods ~= 6 then
    fail("manifest.iconAnimations.periods must carry six periods", {})
  end
  for index, period in
    ipairs(icons.periods --[[@as table[] ]])
  do
    if type(period) ~= "number" or period % 1 ~= 0 or period <= 0 then
      fail("manifest.iconAnimations.periods[" .. index .. "] must be a positive integer", {})
    end
  end
  if type(icons.replacementDurations) ~= "table" or #icons.replacementDurations ~= 3 then
    fail("manifest.iconAnimations.replacementDurations must carry three durations", {})
  end
  if type(icons.replacementShift) ~= "table" or #icons.replacementShift ~= 3 then
    fail("manifest.iconAnimations.replacementShift must carry three shifts", {})
  end
  if type(root.navigation) ~= "table" then
    fail("manifest.navigation must be a record", {})
  end
  local navigation = root.navigation --[[@as table<string, unknown>]]
  checkKeys(navigation, { dpad = true }, {}, "manifest.navigation")
  if type(navigation.dpad) ~= "table" then
    fail("manifest.navigation.dpad must be a record", {})
  end
  local dpad = navigation.dpad --[[@as table<string, unknown>]]
  checkKeys(dpad, { default = true, alternate = true, union = true, contest = true }, {}, "manifest.navigation.dpad")
  for _, variant in ipairs({ "default", "alternate", "union", "contest" }) do
    local rows = dpad[variant]
    if type(rows) ~= "table" or #rows ~= 8 then
      fail("manifest.navigation.dpad." .. variant .. " must carry eight boxes", {})
    end
    for index, row in
      ipairs(rows --[[@as table[] ]])
    do
      checkDpadRow(row, {}, "manifest.navigation.dpad." .. variant .. "[" .. index .. "]")
    end
  end
  if type(root.hitboxes) ~= "table" then
    fail("manifest.hitboxes must be a record", {})
  end
  local hitboxes = root.hitboxes --[[@as table<string, unknown>]]
  checkKeys(hitboxes, { touch = true }, {}, "manifest.hitboxes")
  if type(hitboxes.touch) ~= "table" then
    fail("manifest.hitboxes.touch must be a record", {})
  end
  local touch = hitboxes.touch --[[@as table<string, unknown>]]
  checkKeys(touch, { default = true, alternate = true, context = true }, {}, "manifest.hitboxes.touch")
  for _, variant in ipairs({ "default", "alternate", "context" }) do
    local rects = touch[variant]
    if type(rects) ~= "table" or #rects == 0 then
      fail("manifest.hitboxes.touch." .. variant .. " carries no hitbox", {})
    end
    for index, rectValue in
      ipairs(rects --[[@as table[] ]])
    do
      checkTouchRect(rectValue, {}, "manifest.hitboxes.touch." .. variant .. "[" .. index .. "]")
    end
  end
  if type(root.text) ~= "table" then
    fail("manifest.text must be a record", {})
  end
  local text = root.text --[[@as table<string, unknown>]]
  checkKeys(text, { labels = true, templates = true }, {}, "manifest.text")
  if type(text.labels) ~= "table" or type(text.templates) ~= "table" then
    fail("manifest.text carries no label/template records", {})
  end
  for name, label in
    pairs(text.labels --[[@as table<string, unknown>]])
  do
    if type(label) ~= "string" or label == "" then
      fail("manifest.text.labels." .. tostring(name) .. " must be display text", {})
    end
  end
  for name, template in
    pairs(text.templates --[[@as table<string, unknown>]])
  do
    if type(template) ~= "table" or type(template.segments) ~= "table" or #template.segments == 0 then
      fail("manifest.text.templates." .. tostring(name) .. " carries no segments", {})
    end
    for index, segment in
      ipairs(template.segments --[[@as table[] ]])
    do
      checkSegment(segment, {}, "manifest.text.templates." .. tostring(name) .. ".segments[" .. index .. "]")
    end
  end
  if type(root.numberGlyphs) ~= "table" then
    fail("manifest.numberGlyphs must be a record", {})
  end
  local glyphs = root.numberGlyphs --[[@as table<string, unknown>]]
  checkKeys(
    glyphs,
    { advance = true, height = true, digits = true, slash = true, level = true },
    {},
    "manifest.numberGlyphs"
  )
  for _, axis in ipairs({ "advance", "height" }) do
    if type(glyphs[axis]) ~= "number" or glyphs[axis] % 1 ~= 0 or glyphs[axis] <= 0 then
      fail("manifest.numberGlyphs." .. axis .. " must be a positive integer", {})
    end
  end
  if type(glyphs.digits) ~= "table" or #glyphs.digits ~= PartyAssetSchema.DIGIT_COUNT then
    fail("manifest.numberGlyphs.digits must carry ten glyphs", {})
  end
  for index, digit in
    ipairs(glyphs.digits --[[@as table[] ]])
  do
    checkVisual(digit, {}, "manifest.numberGlyphs.digits[" .. index .. "]")
  end
  checkVisual(glyphs.slash, {}, "manifest.numberGlyphs.slash")
  checkVisual(glyphs.level, {}, "manifest.numberGlyphs.level")
  if type(root.shinyLeaves) ~= "table" then
    fail("manifest.shinyLeaves must be a record", {})
  end
  local leaves = root.shinyLeaves --[[@as table<string, unknown>]]
  checkKeys(leaves, {
    anchors = true,
    crownAnchor = true,
    leafSequence = true,
    crownSequence = true,
    paletteBank = true,
    leaves = true,
    crown = true,
  }, {}, "manifest.shinyLeaves")
  if type(leaves.anchors) ~= "table" or #leaves.anchors ~= PartyAssetSchema.LEAF_COUNT then
    fail("manifest.shinyLeaves.anchors must carry five anchors", {})
  end
  for index, anchor in
    ipairs(leaves.anchors --[[@as table[] ]])
  do
    checkPoint(anchor, {}, "manifest.shinyLeaves.anchors[" .. index .. "]")
  end
  checkPoint(leaves.crownAnchor, {}, "manifest.shinyLeaves.crownAnchor")
  for _, field in ipairs({ "leafSequence", "crownSequence", "paletteBank" }) do
    checkInt(leaves[field], {}, "manifest.shinyLeaves." .. field)
  end
  checkAnimated(leaves.leaves, {}, "manifest.shinyLeaves.leaves")
  checkAnimated(leaves.crown, {}, "manifest.shinyLeaves.crown")
end

---@param manifest unknown
---@return boolean
function PartyAssetSchema.isValidManifest(manifest)
  local ok = pcall(PartyAssetSchema.assertManifest, manifest)
  return ok
end

return PartyAssetSchema
