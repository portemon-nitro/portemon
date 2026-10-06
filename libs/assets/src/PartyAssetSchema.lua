-- Authoritative validation for the generated party presentation class.
-- The manifest carries the canonical 256x192 panes, six slotted panels
-- pairing chrome variants with text/HP subrectangles, message/context
-- windows, cursor/ball/held/status/feedback visuals with source timing,
-- shared icon-animation expectations, dpad/touch navigation tables,
-- lowered bank-300 text, source numeric glyphs, and Shiny Leaf/crown badge
-- frames. Producer writers, schema tests, and explicit audit call these
-- validators, so no second interpretation of the shapes exists. Runtime
-- trusts published artifacts and must not duplicate this validation. Unknown fields, wrong
-- pane sizes, out-of-bounds geometry, wrong slot/digit/anchor cardinality,
-- non-integral timing, and leaked source identities fail loudly. Modded
-- frame counts, sizes, and palettes stay valid. Love-free and
-- filesystem-free.

local Validate = require("libs.assets.src.Validate")
local SchemaCheck = require("libs.assets.src.SchemaCheck")

---@class PartyAssetSchema
local PartyAssetSchema = {}

PartyAssetSchema.SCHEMA = "g4-party-presentation-v6"
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

local REQUIRED_RUNTIME_TEMPLATES = {
  "chooseMon",
  "moveTarget",
  "giveTarget",
  "useTarget",
  "teachTarget",
  "itemAction",
  "takeNoItem",
  "bagFull",
  "switchHeldPrompt",
  "switchHeldResult",
  "giveHeldItem",
}

local function fail(message, context)
  SchemaCheck.fail("PARTY_MANIFEST_INVALID", message, context)
end

local function checkKeys(record, allowed, context, what)
  SchemaCheck.checkKeys(record, allowed, context, "PARTY_MANIFEST_INVALID", what)
  for key in pairs(record) do
    if SOURCE_KEYS[key] == true then
      fail(what .. " leaks source identity " .. tostring(key), context)
    end
  end
end

local function checkInt(value, context, what)
  SchemaCheck.checkInteger(value, context, "PARTY_MANIFEST_INVALID", what)
end

local function checkPoint(value, context, what)
  if type(value) ~= "table" then
    fail(what .. " must be a record", context)
  end
  checkKeys(value, { x = true, y = true }, context, what)
  checkInt(value.x, context, what .. ".x")
  checkInt(value.y, context, what .. ".y")
end

local function checkPanePoint(value, context, what)
  checkPoint(value, context, what)
  if
    value.x < 0
    or value.x >= PartyAssetSchema.PANE_WIDTH
    or value.y < 0
    or value.y >= PartyAssetSchema.PANE_HEIGHT
  then
    fail(what .. " escapes the canonical pane", context)
  end
end

local function checkDetailPoint(value, context, what)
  checkPoint(value, context, what)
  if value.x < 0 or value.x > 255 or value.y < 0 or value.y > 255 then
    fail(what .. " escapes the detail surface", context)
  end
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

local function checkTextRole(value, context, what)
  if type(value) ~= "table" then
    fail(what .. " must be a record", context)
  end
  checkKeys(value, { foreground = true, shadow = true, background = true }, context, what)
  checkColor(value.foreground, context, what .. ".foreground")
  checkColor(value.shadow, context, what .. ".shadow")
  checkColor(value.background, context, what .. ".background")
end

local function checkIconTimeline(value, context, what)
  if type(value) ~= "table" then
    fail(what .. " must be a record", context)
  end
  if type(value.loopFrom) ~= "number" or value.loopFrom % 1 ~= 0 then
    fail(what .. ".loopFrom must be an integer", context)
  end
  if PLAYBACKS[value.playback] == nil then
    fail(what .. ".playback must be static, loop or once", context)
  end
  local frames = #value
  if frames == 0 then
    fail(what .. " carries no frames", context)
  end
  if value.loopFrom < 1 or value.loopFrom > frames then
    fail(what .. ".loopFrom must address a frame", context)
  end
  for key in pairs(value) do
    if type(key) == "string" and key ~= "loopFrom" and key ~= "playback" then
      fail(what .. " carries an unknown field " .. key, context)
    end
    if SOURCE_KEYS[key] == true then
      fail(what .. " leaks source identity " .. tostring(key), context)
    end
    if type(key) == "number" and (key < 1 or key > frames or key % 1 ~= 0) then
      fail(what .. " carries a non-contiguous frame", context)
    end
  end
  for index = 1, frames do
    local frame = value[index]
    local where = what .. "[" .. index .. "]"
    if type(frame) ~= "table" then
      fail(where .. " must be a record", context)
    end
    checkKeys(frame, { iconFrame = true, durationTicks = true, translateX = true, translateY = true }, context, where)
    if frame.iconFrame ~= 1 and frame.iconFrame ~= 2 then
      fail(where .. ".iconFrame must address the two icon frames", context)
    end
    if type(frame.durationTicks) ~= "number" or frame.durationTicks % 1 ~= 0 or frame.durationTicks <= 0 then
      fail(where .. ".durationTicks must be a positive integer", context)
    end
    for _, axis in ipairs({ "translateX", "translateY" }) do
      if type(frame[axis]) ~= "number" or frame[axis] % 1 ~= 0 then
        fail(where .. "." .. axis .. " must be an integer", context)
      end
    end
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

local function checkSequenceGroup(value, context, what, minimumSequences)
  if type(value) ~= "table" then
    fail(what .. " must be a record", context)
  end
  checkKeys(value, { sequences = true }, context, what)
  if not Validate.isArray(value.sequences) or #value.sequences < minimumSequences then
    fail(what .. " must contain at least " .. minimumSequences .. " contiguous sequences", context)
  end
  for index, sequence in ipairs(value.sequences) do
    checkAnimated(sequence, context, what .. ".sequences[" .. index .. "]")
  end
end

local function checkPanel(value, context, what, cursorSequenceCount)
  if type(value) ~= "table" then
    fail(what .. " must be a record", context)
  end
  checkKeys(value, {
    origin = true,
    size = true,
    iconAnchor = true,
    ballAnchor = true,
    heldAnchor = true,
    capsuleAnchor = true,
    statusRect = true,
    cursorSequence = true,
    chrome = true,
    text = true,
    hp = true,
    compat = true,
  }, context, what)
  checkPanePoint(value.origin, context, what .. ".origin")
  checkPanePoint(value.iconAnchor, context, what .. ".iconAnchor")
  checkPanePoint(value.ballAnchor, context, what .. ".ballAnchor")
  checkPanePoint(value.heldAnchor, context, what .. ".heldAnchor")
  checkPanePoint(value.capsuleAnchor, context, what .. ".capsuleAnchor")
  checkRect(value.statusRect, context, what .. ".statusRect")
  checkInt(value.cursorSequence, context, what .. ".cursorSequence")
  if value.cursorSequence < 1 or value.cursorSequence > cursorSequenceCount then
    fail(what .. ".cursorSequence must address a cursor sequence", context)
  end
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
  local chrome = value.chrome --[[@as table<string, unknown>]]
  local chromeNames = { "normal", "selected", "fainted", "selectedFainted", "switchSelection" }
  local chromeKeys = { normal = true, selected = true, fainted = true, selectedFainted = true, switchSelection = true }
  checkKeys(chrome, chromeKeys, context, what .. ".chrome")
  for _, name in ipairs(chromeNames) do
    local visual = chrome[name]
    checkVisual(visual, context, what .. ".chrome." .. name)
    if visual.width ~= 128 or visual.height ~= 48 then
      fail(what .. ".chrome." .. name .. " must be 128x48", context)
    end
  end
  if type(value.text) ~= "table" then
    fail(what .. ".text must be a record", context)
  end
  checkKeys(value.text, { name = true, level = true, gender = true }, context, what .. ".text")
  checkRect(value.text.name, context, what .. ".text.name")
  checkRect(value.text.level, context, what .. ".text.level")
  checkPanePoint(value.text.gender, context, what .. ".text.gender")
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

local function checkMenuEntry(value, context, what, count, lateral)
  if type(value) ~= "table" then
    fail(what .. " must be a record", context)
  end
  checkKeys(value, {
    textRect = true,
    frameRect = true,
    frameShape = true,
    style = true,
    touch = true,
    up = true,
    down = true,
    left = true,
    right = true,
  }, context, what)
  checkRect(value.textRect, context, what .. ".textRect")
  checkRect(value.frameRect, context, what .. ".frameRect")
  if value.frameShape ~= "standard" and value.frameShape ~= "cancel" then
    fail(what .. ".frameShape must be standard or cancel", context)
  end
  if type(value.style) ~= "string" or value.style == "" then
    fail(what .. ".style must name its text/fill style", context)
  end
  checkTouchRect(value.touch, context, what .. ".touch")
  for _, direction in ipairs({ "up", "down" }) do
    if value[direction] ~= nil then
      checkInt(value[direction], context, what .. "." .. direction)
      if value[direction] < 1 or value[direction] > count then
        fail(what .. "." .. direction .. " must address a semantic entry", context)
      end
    end
  end
  for _, direction in ipairs({ "left", "right" }) do
    if lateral then
      if value[direction] == nil then
        fail(what .. "." .. direction .. " keeps the source lateral relation", context)
      end
      checkInt(value[direction], context, what .. "." .. direction)
      if value[direction] < 1 or value[direction] > count then
        fail(what .. "." .. direction .. " must address a semantic entry", context)
      end
    elseif value[direction] ~= nil then
      fail(what .. "." .. direction .. " has no source lateral relation", context)
    end
  end
end

local function checkMenuSection(value, context, what, minCount, maxCount, lateral)
  if type(value) ~= "table" then
    fail(what .. " must be a record", context)
  end
  for count = minCount, maxCount do
    local layout = value[count]
    if layout == nil then
      layout = value[tostring(count)]
    end
    if type(layout) ~= "table" then
      fail(what .. " lacks its " .. count .. "-entry layout", context)
    end
    if not Validate.isArray(layout) or #layout ~= count then
      fail(what .. "[" .. count .. "] must carry one record per entry", context)
    end
    for index, entry in ipairs(layout) do
      checkMenuEntry(entry, context, what .. "[" .. count .. "][" .. index .. "]", count, lateral)
    end
  end
  for key in pairs(value) do
    local count = nil
    if type(key) == "number" then
      count = key
    elseif type(key) == "string" and key:match("^%d+$") ~= nil then
      count = tonumber(key)
    else
      fail(what .. " carries an unknown count " .. tostring(key), context)
    end
    if count < minCount or count > maxCount then
      fail(what .. " carries an unsupported count " .. tostring(key), context)
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
    controls = true,
    detail = true,
    windows = true,
    visuals = true,
    iconAnimations = true,
    contextMenu = true,
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
  if type(root.controls) ~= "table" then
    fail("manifest.controls must be a record", {})
  end
  local controls = root.controls --[[@as table<string, unknown>]]
  checkKeys(controls, { cancel = true }, {}, "manifest.controls")
  if type(controls.cancel) ~= "table" then
    fail("manifest.controls.cancel must be a record", {})
  end
  local cancel = controls.cancel --[[@as table<string, unknown>]]
  checkKeys(cancel, { anchor = true, label = true, textRect = true, align = true }, {}, "manifest.controls.cancel")
  checkPanePoint(cancel.anchor, {}, "manifest.controls.cancel.anchor")
  if type(cancel.label) ~= "string" or cancel.label == "" then
    fail("manifest.controls.cancel.label must be display text", {})
  end
  checkRect(cancel.textRect, {}, "manifest.controls.cancel.textRect")
  if cancel.align ~= "center" then
    fail("manifest.controls.cancel.align must keep the center-alignment contract", {})
  end
  if type(root.detail) ~= "table" then
    fail("manifest.detail must be a record", {})
  end
  local detail = root.detail --[[@as table<string, unknown>]]
  checkKeys(detail, {
    iconAnchor = true,
    statusAnchor = true,
    nicknameTextOrigin = true,
    heldItemTextOrigin = true,
  }, {}, "manifest.detail")
  checkDetailPoint(detail.iconAnchor, {}, "manifest.detail.iconAnchor")
  checkDetailPoint(detail.statusAnchor, {}, "manifest.detail.statusAnchor")
  checkDetailPoint(detail.nicknameTextOrigin, {}, "manifest.detail.nicknameTextOrigin")
  checkDetailPoint(detail.heldItemTextOrigin, {}, "manifest.detail.heldItemTextOrigin")
  if type(root.windows) ~= "table" then
    fail("manifest.windows must be a record", {})
  end
  checkKeys(root.windows, { browse = true, context = true, action = true, prompt = true }, {}, "manifest.windows")
  local windows = root.windows --[[@as table<string, unknown>]]
  checkRect(windows.browse, {}, "manifest.windows.browse")
  checkRect(windows.context, {}, "manifest.windows.context")
  checkRect(windows.action, {}, "manifest.windows.action")
  checkPanePoint(windows.prompt, {}, "manifest.windows.prompt")
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
    hpBars = true,
  }, {}, "manifest.visuals")
  checkSequenceGroup(visuals.cursor, {}, "manifest.visuals.cursor", 1)
  local cursorSequenceCount = #(visuals.cursor --[[@as table<string, unknown>]]).sequences --[[@as table[] ]]
  for slot = 1, PartyAssetSchema.SLOT_COUNT do
    checkPanel((root.panels --[[@as table[] ]])[slot], {}, "manifest.panels[" .. slot .. "]", cursorSequenceCount)
  end
  checkSequenceGroup(visuals.balls, {}, "manifest.visuals.balls", 2)
  checkSequenceGroup(visuals.buttons, {}, "manifest.visuals.buttons", 2)
  checkSequenceGroup(visuals.held, {}, "manifest.visuals.held", 3)
  if type(visuals.status) ~= "table" then
    fail("manifest.visuals.status must be a record", {})
  end
  local status = visuals.status --[[@as table<string, unknown>]]
  local statusNames = { "paralysis", "freeze", "sleep", "poison", "burn", "faint" }
  local statusKeys = {}
  for _, name in ipairs(statusNames) do
    statusKeys[name] = true
  end
  checkKeys(status, statusKeys, {}, "manifest.visuals.status")
  for _, name in ipairs(statusNames) do
    local visual = status[name]
    checkVisual(visual, {}, "manifest.visuals.status." .. name)
    if visual.width ~= 24 or visual.height ~= 8 then
      fail("manifest.visuals.status." .. name .. " must be 24x8", {})
    end
  end
  checkAnimated(visuals.feedback, {}, "manifest.visuals.feedback", true)
  checkVisual(visuals.backdropMain, {}, "manifest.visuals.backdropMain")
  checkVisual(visuals.backdropSub, {}, "manifest.visuals.backdropSub")
  checkVisual(visuals.detailSub, {}, "manifest.visuals.detailSub")
  checkVisual(visuals.decoration, {}, "manifest.visuals.decoration")
  checkVisual(visuals.auxPanel, {}, "manifest.visuals.auxPanel")
  if type(visuals.hpBars) ~= "table" then
    fail("manifest.visuals.hpBars must be a record", {})
  end
  local hpBars = visuals.hpBars --[[@as table<string, unknown>]]
  checkKeys(hpBars, { green = true, yellow = true, red = true }, {}, "manifest.visuals.hpBars")
  for _, color in ipairs({ "green", "yellow", "red" }) do
    local visual = hpBars[color]
    checkVisual(visual, {}, "manifest.visuals.hpBars." .. color)
    if visual.width ~= 48 or visual.height ~= 4 then
      fail("manifest.visuals.hpBars." .. color .. " must be 48x4", {})
    end
  end
  if type(root.iconAnimations) ~= "table" then
    fail("manifest.iconAnimations must be a record", {})
  end
  local icons = root.iconAnimations --[[@as table<string, unknown>]]
  checkKeys(icons, { sequences = true }, {}, "manifest.iconAnimations")
  if type(icons.sequences) ~= "table" or #icons.sequences ~= 6 then
    fail("manifest.iconAnimations.sequences must carry six timelines", {})
  end
  for index, timeline in
    ipairs(icons.sequences --[[@as table[] ]])
  do
    checkIconTimeline(timeline, {}, "manifest.iconAnimations.sequences[" .. index .. "]")
  end
  if type(root.contextMenu) ~= "table" then
    fail("manifest.contextMenu must be a record", {})
  end
  local contextMenu = root.contextMenu --[[@as table<string, unknown>]]
  checkKeys(contextMenu, {
    topLevel = true,
    subcontext = true,
    textRoles = true,
    frames = true,
  }, {}, "manifest.contextMenu")
  checkMenuSection(contextMenu.topLevel, {}, "manifest.contextMenu.topLevel", 2, 8, true)
  checkMenuSection(contextMenu.subcontext, {}, "manifest.contextMenu.subcontext", 2, 5, false)
  if type(contextMenu.textRoles) ~= "table" then
    fail("manifest.contextMenu.textRoles must be a record", {})
  end
  local textRoles = contextMenu.textRoles --[[@as table<string, unknown>]]
  checkKeys(textRoles, { command = true, field = true, cancel = true }, {}, "manifest.contextMenu.textRoles")
  for _, name in ipairs({ "command", "field", "cancel" }) do
    local roleValue = textRoles[name]
    if type(roleValue) ~= "table" then
      fail("manifest.contextMenu.textRoles." .. name .. " must be a record", {})
    end
    local typed = roleValue --[[@as table<string, unknown>]]
    checkKeys(typed, { raised = true, depressed = true }, {}, "manifest.contextMenu.textRoles." .. name)
    checkTextRole(typed.raised, {}, "manifest.contextMenu.textRoles." .. name .. ".raised")
    checkTextRole(typed.depressed, {}, "manifest.contextMenu.textRoles." .. name .. ".depressed")
  end
  if type(contextMenu.frames) ~= "table" then
    fail("manifest.contextMenu.frames must be a record", {})
  end
  local frames = contextMenu.frames --[[@as table<string, unknown>]]
  checkKeys(frames, { standard = true, cancel = true }, {}, "manifest.contextMenu.frames")
  local frameShapes = {
    standard = { width = 128, height = 32 },
    cancel = { width = 56, height = 40 },
  }
  for _, shape in ipairs({ "standard", "cancel" }) do
    local group = frames[shape]
    if type(group) ~= "table" then
      fail("manifest.contextMenu.frames." .. shape .. " must be a record", {})
    end
    local typed = group --[[@as table<string, unknown>]]
    checkKeys(typed, { raised = true, selected = true, pressed = true }, {}, "manifest.contextMenu.frames." .. shape)
    local size = frameShapes[shape]
    for _, state in ipairs({ "raised", "selected", "pressed" }) do
      local visual = typed[state]
      checkVisual(visual, {}, "manifest.contextMenu.frames." .. shape .. "." .. state)
      if visual.width ~= size.width or visual.height ~= size.height then
        fail(
          "manifest.contextMenu.frames." .. shape .. "." .. state .. " must be " .. size.width .. "x" .. size.height,
          {}
        )
      end
    end
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
  checkKeys(text, { labels = true, templates = true, roles = true, messageRole = true }, {}, "manifest.text")
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
  local labels = text.labels --[[@as table<string, unknown>]]
  if type(labels.male) ~= "string" or labels.male == "" then
    fail("manifest.text.labels.male must be display text", {})
  end
  if type(labels.female) ~= "string" or labels.female == "" then
    fail("manifest.text.labels.female must be display text", {})
  end
  if type(text.roles) ~= "table" then
    fail("manifest.text.roles must be a record", {})
  end
  local roles = text.roles --[[@as table<string, unknown>]]
  checkKeys(roles, { ordinary = true, male = true, female = true }, {}, "manifest.text.roles")
  checkTextRole(roles.ordinary, {}, "manifest.text.roles.ordinary")
  checkTextRole(roles.male, {}, "manifest.text.roles.male")
  checkTextRole(roles.female, {}, "manifest.text.roles.female")
  checkTextRole(text.messageRole, {}, "manifest.text.messageRole")
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
  for _, name in ipairs(REQUIRED_RUNTIME_TEMPLATES) do
    if text.templates[name] == nil then
      fail("manifest.text.templates." .. name .. " is required", {})
    end
  end
  if type(root.numberGlyphs) ~= "table" then
    fail("manifest.numberGlyphs must be a record", {})
  end
  local glyphs = root.numberGlyphs --[[@as table<string, unknown>]]
  checkKeys(
    glyphs,
    { advance = true, height = true, digits = true, slash = true, level = true, placement = true },
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
  if type(glyphs.placement) ~= "table" then
    fail("manifest.numberGlyphs.placement must be a record", {})
  end
  local placement = glyphs.placement --[[@as table<string, unknown>]]
  checkKeys(
    placement,
    { level = true, current = true, slash = true, max = true },
    {},
    "manifest.numberGlyphs.placement"
  )
  checkPoint(placement.level, {}, "manifest.numberGlyphs.placement.level")
  checkPoint(placement.current, {}, "manifest.numberGlyphs.placement.current")
  checkPoint(placement.slash, {}, "manifest.numberGlyphs.placement.slash")
  checkPoint(placement.max, {}, "manifest.numberGlyphs.placement.max")
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
