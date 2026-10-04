-- Translates the audited field-bag overlay tables into canonical pane
-- rectangles and pocket-indexed animation states. The source geometry lives
-- in romdump/src/config/BagSources.lua; this module owns the translation
-- and the structural validation (exactly eight tabs, six slots, eight
-- states, every rectangle inside its 256x192 pane) so malformed producer
-- data fails here with an attributed error instead of reaching the schema.
-- Pure module: no love dependency, no I/O.

local Errors = require("libs.errors.src.Errors")

---@class BagPresentationCompiler
local BagPresentationCompiler = {}

BagPresentationCompiler.ERROR = {
  GEOMETRY_INVALID = "BAG_GEOMETRY_INVALID",
}

BagPresentationCompiler.PANE_WIDTH = 256
BagPresentationCompiler.PANE_HEIGHT = 192

local function isIntegral(value)
  return type(value) == "number" and value % 1 == 0
end

local function checkRect(value, what)
  if
    type(value) ~= "table"
    or not isIntegral(value.x)
    or not isIntegral(value.y)
    or not isIntegral(value.width)
    or not isIntegral(value.height)
    or value.x < 0
    or value.y < 0
    or value.width <= 0
    or value.height <= 0
    or value.x + value.width > BagPresentationCompiler.PANE_WIDTH
    or value.y + value.height > BagPresentationCompiler.PANE_HEIGHT
  then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, what .. " is not a pane-fitting rectangle", {})
  end
  return { x = value.x, y = value.y, width = value.width, height = value.height }
end

local function checkPoint(value, what)
  if
    type(value) ~= "table"
    or not isIntegral(value.x)
    or not isIntegral(value.y)
    or value.x < 0
    or value.y < 0
    or value.x > BagPresentationCompiler.PANE_WIDTH
    or value.y > BagPresentationCompiler.PANE_HEIGHT
  then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, what .. " is not a pane-fitting point", {})
  end
  return { x = value.x, y = value.y }
end

local function checkTextBox(value, what)
  local fields = {
    x = true,
    y = true,
    width = true,
    height = true,
    fontId = true,
    textX = true,
    textY = true,
    alignment = true,
    paletteRole = true,
  }
  if type(value) ~= "table" then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, what .. " is malformed", {})
  end
  for key in pairs(value) do
    if not fields[key] then
      Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, what .. " has an unknown field", {})
    end
  end
  for key in pairs(fields) do
    if value[key] == nil then
      Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, what .. " is incomplete", {})
    end
  end
  local rect = checkRect(value, what)
  for _, key in ipairs({ "fontId", "textX", "textY" }) do
    if not isIntegral(value[key]) or value[key] < 0 then
      Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, what .. "." .. key .. " is invalid", {})
    end
  end
  if value.alignment ~= "left" and value.alignment ~= "center" and value.alignment ~= "right" then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, what .. ".alignment is invalid", {})
  end
  if type(value.paletteRole) ~= "string" or value.paletteRole == "" then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, what .. ".paletteRole is invalid", {})
  end
  return {
    x = rect.x,
    y = rect.y,
    width = rect.width,
    height = rect.height,
    fontId = value.fontId,
    textX = value.textX,
    textY = value.textY,
    alignment = value.alignment,
    paletteRole = value.paletteRole,
  }
end

-- Fixed-count source collections carry the audited control cardinalities
-- (eight tabs, six slots, ...). Every repeated table-plus-count guard goes
-- through this single check so the counts stay at this producer boundary.
---@param value unknown
---@param expected integer
---@param what string
---@return unknown[]
local function checkCollection(value, expected, what)
  if type(value) ~= "table" or #value ~= expected then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, what, {})
  end
  assert(type(value) == "table")
  return value
end

-- Ordered copy for collections whose transformation really is identical
-- (rectangle or point copies). Record assembly with different semantic
-- fields stays explicit at the caller.
---@param collection unknown[]
---@param mapOne fun(item: unknown, index: integer): unknown
---@return unknown[]
local function mapList(collection, mapOne)
  local out = {}
  for index, item in ipairs(collection) do
    out[index] = mapOne(item, index)
  end
  return out
end

-- The candidate and parent records are validated with checkRect before this
-- runs; the four-edge comparison itself lives here only.
---@param inner { x: number, y: number, width: number, height: number }
---@param outer { x: number, y: number, width: number, height: number }
---@param what string
local function checkContained(inner, outer, what)
  if
    inner.x < outer.x
    or inner.y < outer.y
    or inner.x + inner.width > outer.x + outer.width
    or inner.y + inner.height > outer.y + outer.height
  then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, what, {})
  end
end

-- Translate the source tab/slot/cursor/readout/overlay tables into the
-- manifest-ready geometry record.
---@param config table<string, unknown>
---@return table<string, unknown>
function BagPresentationCompiler.compileGeometry(config)
  assert(type(config) == "table" and type(config.geometry) == "table", "compileGeometry requires a source config")
  local geometry = config.geometry
  local tabSource = checkCollection(geometry.tabs, 8, "bag geometry must carry exactly eight pocket tabs")
  local slotSource = checkCollection(geometry.slots, 6, "bag geometry must carry exactly six item slots")
  local tabs = mapList(tabSource, function(tab, index)
    return checkRect(tab, "pocket tab " .. index)
  end)
  local placements =
    checkCollection(config.itemIconCenters, 6, "bag source config must carry exactly six item-icon placements")
  local slots = {}
  for index, slot in ipairs(slotSource) do
    if type(slot) ~= "table" then
      Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "item slot " .. index .. " is malformed", {})
    end
    local full = checkRect(slot.rect, "item slot " .. index)
    local window = checkRect(slot.textRect, "item slot " .. index .. " text window")
    checkContained(window, full, "item slot " .. index .. " text window escapes its touch rect")
    slots[index] = {
      rect = full,
      textRect = window,
      iconCenter = checkPoint(placements[index], "item slot " .. index .. " icon center"),
      nameAt = checkPoint(slot.nameAt, "item slot " .. index .. " name anchor"),
      quantityAt = checkPoint(slot.quantityAt, "item slot " .. index .. " quantity anchor"),
    }
  end
  local cursor = geometry.cursorAnchor
  if type(cursor) ~= "table" then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "bag geometry carries no cursor anchor", {})
  end
  for _, field in ipairs({ "size", "y", "xBase", "xStep", "count" }) do
    if type(cursor[field]) ~= "number" or cursor[field] % 1 ~= 0 or cursor[field] < 0 then
      Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "cursor anchor field " .. field .. " is invalid", {})
    end
  end
  if cursor.origin ~= "center" then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "cursor anchor origin must be center", {})
  end
  local countReadout = geometry.countReadout
  if type(countReadout) ~= "table" then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "bag geometry carries no count readout", {})
  end
  local actionSource = checkCollection(geometry.actionSlots, 4, "bag geometry must carry exactly four action slots")
  local actionSlots = {}
  for index, slot in ipairs(actionSource) do
    if type(slot) ~= "table" then
      Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "action slot " .. index .. " is malformed", {})
    end
    actionSlots[index] = {
      center = checkPoint(slot.center, "action slot " .. index .. " center"),
      textRect = checkRect(slot.textRect, "action slot " .. index .. " text window"),
      hitRect = checkRect(slot.hitRect, "action slot " .. index .. " hit rect"),
    }
  end
  local digitSource =
    checkCollection(geometry.quantityDigits, 3, "bag geometry must carry exactly three quantity digits")
  local quantityDigits = mapList(digitSource, function(digit, index)
    return checkRect(digit, "quantity digit " .. index)
  end)
  local controlSource =
    checkCollection(geometry.quantityControls, 6, "bag geometry must carry exactly six quantity controls")
  local quantityControls = {}
  local expectedControls = {
    { delta = 100, role = "increment" },
    { delta = 10, role = "increment" },
    { delta = 1, role = "increment" },
    { delta = -100, role = "decrement" },
    { delta = -10, role = "decrement" },
    { delta = -1, role = "decrement" },
  }
  for index, control in ipairs(controlSource) do
    local expected = expectedControls[index]
    if type(control) ~= "table" or control.delta ~= expected.delta or control.role ~= expected.role then
      Errors.raise(
        BagPresentationCompiler.ERROR.GEOMETRY_INVALID,
        "quantity control " .. index .. " has the wrong role",
        {}
      )
    end
    quantityControls[index] = {
      delta = control.delta,
      role = control.role,
      center = checkPoint(control.center, "quantity control " .. index .. " center"),
      hitRect = checkRect(control.hitRect, "quantity control " .. index .. " hit rect"),
    }
  end
  if type(geometry.quantityConfirm) ~= "table" then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "bag geometry carries no quantity confirm", {})
  end
  local quantityConfirm = {
    center = checkPoint(geometry.quantityConfirm.center, "quantity confirm center"),
    hitRect = checkRect(geometry.quantityConfirm.hitRect, "quantity confirm hit rect"),
    labelAt = checkPoint(geometry.quantityConfirm.labelAt, "quantity confirm label"),
  }
  local quantityCancelHitRect = checkRect(geometry.quantityCancelHitRect, "quantity cancel hit rect")
  local quantityCancelLabelAt = checkPoint(geometry.quantityCancelLabelAt, "quantity cancel label")
  local cancelSource = geometry.cancel
  if type(cancelSource) ~= "table" then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "bag geometry carries no cancel affordance", {})
  end
  local cancelRect = checkRect(cancelSource.rect, "cancel")
  local cancelText = checkRect(cancelSource.textRect, "cancel text window")
  checkContained(cancelText, cancelRect, "cancel text window escapes its button rect")
  if type(cancelSource.labelRect) ~= "table" then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "bag geometry carries no cancel label area", {})
  end
  local cancelLabel = checkRect(cancelSource.labelRect, "cancel label area")
  checkContained(cancelLabel, cancelRect, "cancel label area escapes its button rect")
  local focusSource = config.focusTargets
  if type(focusSource) ~= "table" then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "bag source config carries no focus targets", {})
  end
  local focusTabSource = checkCollection(focusSource.tabs, 8, "focus targets must carry exactly eight tabs")
  local focusItemSource = checkCollection(focusSource.items, 6, "focus targets must carry exactly six items")
  local focusActionSource = checkCollection(focusSource.actions, 4, "focus targets must carry exactly four actions")
  local focusTabs = mapList(focusTabSource, function(target, index)
    return checkPoint(target, "tab focus target " .. index)
  end)
  local focusItems = mapList(focusItemSource, function(target, index)
    return checkPoint(target, "item focus target " .. index)
  end)
  local focusActions = mapList(focusActionSource, function(target, index)
    return checkPoint(target, "action focus target " .. index)
  end)
  local focus = {
    tabs = focusTabs,
    items = focusItems,
    cancel = checkPoint(focusSource.cancel, "cancel focus target"),
    actions = focusActions,
  }
  local saleSource = config.saleQuantity
  if type(saleSource) ~= "table" then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "bag source config carries no sale geometry", {})
  end
  local saleDigits = mapList(
    checkCollection(saleSource.digits, 2, "sale must carry exactly two digits"),
    function(digit, index)
      return checkRect(digit, "sale digit " .. index)
    end
  )
  local saleExpectedControls = {
    { delta = 10, role = "increment" },
    { delta = 1, role = "increment" },
    { delta = -10, role = "decrement" },
    { delta = -1, role = "decrement" },
  }
  local saleControls = {}
  for index, control in ipairs(checkCollection(saleSource.controls, 4, "sale must carry exactly four controls")) do
    local expected = saleExpectedControls[index]
    if type(control) ~= "table" or control.delta ~= expected.delta or control.role ~= expected.role then
      Errors.raise(
        BagPresentationCompiler.ERROR.GEOMETRY_INVALID,
        "sale control " .. index .. " has the wrong role",
        {}
      )
    end
    saleControls[index] = {
      delta = control.delta,
      role = control.role,
      center = checkPoint(control.center, "sale control " .. index .. " center"),
      hitRect = checkRect(control.hitRect, "sale control " .. index .. " hit rect"),
    }
  end
  local function saleButton(button, what)
    if type(button) ~= "table" or (button.visualState ~= "confirm" and button.visualState ~= "cancel") then
      Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, what .. " has no source visual state", {})
    end
    return {
      visualState = button.visualState,
      center = checkPoint(button.center, what .. " center"),
      hitRect = checkRect(button.hitRect, what .. " hit rect"),
      labelAt = checkPoint(button.labelAt, what .. " label"),
    }
  end
  local prompt = saleSource.compactPrompt
  if type(prompt) ~= "table" or prompt.shapeParam ~= 0 or prompt.initialCursorPos ~= 0 then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "sale prompt must be the compact YES prompt", {})
  end
  if not isIntegral(prompt.x) or not isIntegral(prompt.y) or prompt.x < 0 or prompt.y < 0 then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "sale prompt position is invalid", {})
  end
  if not isIntegral(saleSource.pressTicks) or saleSource.pressTicks <= 0 then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "sale press ticks must be positive", {})
  end
  local sale = {
    pressTicks = saleSource.pressTicks,
    digits = saleDigits,
    controls = saleControls,
    confirm = saleButton(saleSource.confirm, "sale confirm"),
    cancel = saleButton(saleSource.cancel, "sale cancel"),
    selectedItem = {
      iconCenter = checkPoint(saleSource.selectedItem.iconCenter, "sale selected-item icon center"),
      textRect = checkRect(saleSource.selectedItem.textRect, "sale selected-item text window"),
      nameAt = checkPoint(saleSource.selectedItem.nameAt, "sale selected-item name anchor"),
      quantityAt = checkPoint(saleSource.selectedItem.quantityAt, "sale selected-item quantity anchor"),
    },
    money = checkTextBox(saleSource.money, "sale money text box"),
    total = checkTextBox(saleSource.total, "sale total text box"),
    compactPrompt = {
      x = prompt.x * 8,
      y = prompt.y * 8,
      shape = "compact",
      initialSelection = "yes",
    },
  }
  return {
    tabs = tabs,
    slots = slots,
    focus = focus,
    cursor = {
      size = cursor.size,
      anchorY = cursor.y,
      anchorXBase = cursor.xBase,
      anchorXStep = cursor.xStep,
      anchorCount = cursor.count,
      origin = cursor.origin,
    },
    pageIndicator = {
      rect = checkRect(countReadout.rect, "count readout"),
      textAt = checkPoint(countReadout.textAt, "count readout text"),
    },
    cancel = { rect = cancelRect, textRect = cancelText, labelRect = cancelLabel },
    descriptionFrame = checkRect(geometry.descriptionFrame, "description frame"),
    descriptionText = checkRect(geometry.descriptionText, "description text"),
    actionSlots = actionSlots,
    quantityDigits = quantityDigits,
    quantityControls = quantityControls,
    quantityConfirm = quantityConfirm,
    quantityCancelHitRect = quantityCancelHitRect,
    quantityCancelLabelAt = quantityCancelLabelAt,
    sale = sale,
  }
end

-- Name one pose and one pattern clip per pocket state. The names resolve
-- against the compiled hero clips by semantic name; opaque member identities
-- never leave producer code.
---@param config table<string, unknown>
---@return table<string, unknown>
function BagPresentationCompiler.compileStates(config)
  assert(type(config) == "table" and type(config.hero) == "table", "compileStates requires a source config")
  local states = config.hero.states
  if type(states) ~= "table" or #states ~= 8 then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "bag hero must carry exactly eight pocket states", {})
  end
  local out = {}
  for index, state in ipairs(states) do
    if type(state) ~= "table" or type(state.pocket) ~= "string" or state.pocket == "" then
      Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "hero state " .. index .. " is malformed", {})
    end
    out[index] = {
      pocket = state.pocket,
      pose = "pocket." .. state.pocket .. ".pose",
      pattern = "pocket." .. state.pocket .. ".pattern",
    }
  end
  return out
end

-- Publish the audited global material registers in manifest-ready
-- semantic form. The source facts are raw RGB555 words from the setup
-- immediates; each register normalizes to its 0..31 channel triple here
-- so no RGB555 packing reaches the runtime manifest.
---@param config table<string, unknown>
---@return table<string, unknown>
function BagPresentationCompiler.compileMaterials(config)
  assert(type(config) == "table" and type(config.presentation) == "table", "compileMaterials requires a source config")
  local materials = config.presentation.materials
  if type(materials) ~= "table" then
    Errors.raise(BagPresentationCompiler.ERROR.GEOMETRY_INVALID, "bag presentation carries no material registers", {})
  end
  for key in pairs(materials) do
    if key ~= "diffuse" and key ~= "ambient" and key ~= "specular" and key ~= "emission" then
      Errors.raise(
        BagPresentationCompiler.ERROR.GEOMETRY_INVALID,
        "bag material register " .. tostring(key) .. " is not audited",
        {}
      )
    end
  end
  local out = {}
  for _, register in ipairs({ "diffuse", "ambient", "specular", "emission" }) do
    local word = materials[register]
    if type(word) ~= "number" or word % 1 ~= 0 or word < 0 or word > 0x7FFF then
      Errors.raise(
        BagPresentationCompiler.ERROR.GEOMETRY_INVALID,
        "bag material register " .. register .. " is not an RGB555 word",
        {}
      )
    end
    out[register] = {
      r = word % 32,
      g = math.floor(word / 32) % 32,
      b = math.floor(word / 1024) % 32,
    }
  end
  return out
end

return BagPresentationCompiler
