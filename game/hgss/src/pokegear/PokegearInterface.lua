-- The gear companion's host placement and pointer contract: two semantic
-- panes (information above or left of controls), five fixed strip slots with
-- rounded-cell hit masks, and one shared render/input pair per display
-- configuration. Every resolver returns the same slot geometry for drawing
-- and hit testing through its plan content. Holds no gameplay state; an
-- outside press is offered as dismissal only when the current view is
-- explicitly dismissible.

local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local PokegearRenderer = require("libs.hgss.src.presentation.PokegearRenderer")

---@class PokegearInterface
local PokegearInterface = {}

PokegearInterface.PANE_WIDTH = 256
PokegearInterface.PANE_HEIGHT = 192

local INFORMATION_NATIVE = { id = "information", width = 256, height = 192 }
local CONTROLS_NATIVE = { id = "controls", width = 256, height = 192 }

-- Five fixed strip slots: centers x32/80/128/176/230 at y176 with touch
-- bands y160..192. Five positions select four cards: the opening position
-- holds the phone card and the trailing positions repeat the final card, so
-- every position stays live and masked cards stay blank in place without
-- ever repacking the strip.
local SLOT_TABS = { "phone", "configure", "radio", "map", "map" }
local SLOT_BANDS = {
  { x0 = 8, x1 = 56 },
  { x0 = 56, x1 = 104 },
  { x0 = 104, x1 = 152 },
  { x0 = 152, x1 = 200 },
  { x0 = 206, x1 = 254 },
}
local STRIP_TOP = 160
local STRIP_BOTTOM = 192
local CORNER_RADIUS = 8

local ZERO_CROP = { left = 0, right = 0, top = 0, bottom = 0 }
local CONTROLS_PROTECTED = { x = 0, y = 160, width = 256, height = 32 }
local INFORMATION_PROTECTED = { x = 8, y = 8, width = 240, height = 176 }

-- One strip slot in source-local controls coordinates, paired with the card
-- it selects. Rectangle entry alone never selects: the rounded source cells
-- leave their rect corners transparent.
---@param band { x0: integer, x1: integer }
---@param x number
---@param y number
---@return boolean inside
local function inSlot(band, x, y)
  if y < STRIP_TOP or y >= STRIP_BOTTOM or x < band.x0 or x >= band.x1 then
    return false
  end
  local innerX0 = band.x0 + CORNER_RADIUS
  local innerX1 = band.x1 - CORNER_RADIUS
  local innerY0 = STRIP_TOP + CORNER_RADIUS
  local innerY1 = STRIP_BOTTOM - CORNER_RADIUS
  local nearestX = x < innerX0 and innerX0 or (x > innerX1 and innerX1 or x)
  local nearestY = y < innerY0 and innerY0 or (y > innerY1 and innerY1 or y)
  local dx = x - nearestX
  local dy = y - nearestY
  return dx * dx + dy * dy <= CORNER_RADIUS * CORNER_RADIUS
end

---@param slots { tab: string, rect: table<string, number> }[]
---@param x number
---@param y number
---@return string? tab
local function slotTabAt(slots, x, y)
  for index, band in ipairs(SLOT_BANDS) do
    if inSlot(band, x, y) then
      return slots[index].tab
    end
  end
  return nil
end

---@return { tab: string, rect: table<string, number> }[]
local function stripSlots()
  local slots = {}
  for index, band in ipairs(SLOT_BANDS) do
    slots[index] = {
      tab = SLOT_TABS[index],
      rect = { x = band.x0, y = STRIP_TOP, width = band.x1 - band.x0, height = STRIP_BOTTOM - STRIP_TOP },
    }
  end
  return slots
end

---@param node unknown
---@return string? path
local function firstImage(node)
  if type(node) ~= "table" then
    return nil
  end
  assert(type(node) == "table", "asset scans read record nodes")
  local record = node --[[@as table<string, unknown>]]
  if type(record.image) == "string" then
    return record.image --[[@as string]]
  end
  local frames = record.frames
  if type(frames) == "table" then
    assert(type(frames) == "table", "asset scans read animation frames")
    local frameList = frames --[[@as table]]
    local first = frameList[1]
    if type(first) == "table" and type(first.image) == "string" then
      return first.image
    end
    return nil
  end
  local keys = {}
  for key in pairs(record) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, key in ipairs(keys) do
    local found = firstImage(record[key])
    if found ~= nil then
      return found
    end
  end
  return nil
end

-- Resolves one compiled visual to its image path: a direct visual record,
-- the current skin entry of a skin-keyed section, or the deterministic
-- first visual of a single-skin section. Missing graphics fail here, before
-- any plan publishes.
---@param node unknown
---@param skin integer
---@param what string
---@return string path
local function skinPath(node, skin, what)
  assert(type(node) == "table", "the companion render needs its " .. what .. " visuals")
  assert(type(node) == "table", "visual resolution reads the " .. what .. " section")
  local record = node --[[@as table<string, unknown>]]
  if type(record.image) == "string" then
    return record.image --[[@as string]]
  end
  for _, key in ipairs({ skin, 0 }) do
    local entry = record[key]
    if type(entry) == "table" and type(entry.image) == "string" then
      return entry.image
    end
  end
  local fallback = firstImage(record)
  assert(fallback ~= nil, "the companion render needs its " .. what .. " visuals")
  return assert(fallback, "the companion render needs its " .. what .. " visuals")
end

---@param section unknown
---@return string? path
local function optionalPath(section)
  if section == nil then
    return nil
  end
  return firstImage(section)
end

-- The shared plan payload: fixed strip slots plus the resolved compiled
-- image paths behind the current skin, so pane-local drawing and hit
-- testing consume the same record.
---@param assets table<string, unknown>
---@param skin integer
---@return table<string, unknown>
local function shellContent(assets, skin)
  assert(type(assets.shell) == "table", "the companion render needs its shell visuals")
  assert(type(assets.configure) == "table", "the companion render needs its setup visuals")
  local shell = assets.shell --[[@as table<string, unknown>]]
  local configure = assets.configure --[[@as table<string, unknown>]]
  local childVisuals = {}
  for _, tab in ipairs({ "configure", "radio", "map", "phone" }) do
    local section = assets[tab]
    if type(section) == "table" then
      childVisuals[tab] = firstImage(section)
    end
  end
  return {
    slots = stripSlots(),
    shellForeground = skinPath(shell.foreground or shell, skin, "shell"),
    shellInformation = skinPath(shell.information or shell, skin, "shell information"),
    childVisuals = childVisuals,
    configureForeground = optionalPath(configure.foreground or configure.panel) or childVisuals.configure,
    configurePatch = optionalPath(configure.patch),
  }
end

-- The controls-pane input edge: a strip tap selects its card on release, so
-- a resize, focus loss, or drag that cancels the held press never fires a
-- stale selection and the initiating press never selects twice. An outside
-- press dismisses only a dismissible view; every other logical event
-- travels to the shell unchanged.
---@param event table<string, unknown> session-inverted logical input
---@param view table<string, unknown> the shell snapshot behind this resolution
---@param plan ApplicationPlan
---@return table<string, unknown>? the shell event, or nil when consumed
local function mapControlsInput(event, view, plan)
  if event.type == "pointer_down" and event.outside == true then
    if view.dismissible == true then
      return { type = "dismiss" }
    end
    return nil
  end
  if type(event.x) ~= "number" or type(event.y) ~= "number" then
    return event
  end
  local content = assert(plan.content, "the companion plan carries its slot geometry")
  assert(type(content) == "table" and type(content.slots) == "table", "the companion plan carries its slots")
  local slots = content.slots --[[@as table]]
  local tab = slotTabAt(slots, event.x, event.y)
  if tab == nil then
    return event
  end
  if event.type == "pointer_up" then
    return { type = "select_tab", tab = tab, x = event.x, y = event.y }
  end
  return nil
end

---@param resources table<string, unknown> borrowed host collaborators
---@param view table<string, unknown> the shell snapshot
---@param plan ApplicationPlan
local function renderGear(resources, view, plan)
  PokegearRenderer.draw(resources, view, plan)
end

---@param placement table<string, unknown>
---@return table<string, unknown>
local function copyPlacement(placement)
  assert(type(placement) == "table", "pair plans carry resolved placements")
  return placement
end

-- One matched two-pane plan over helper-fitted placements: information is
-- never interactive, controls always is.
---@param geometry ApplicationLayout.Geometry
---@param inputKey string
---@param assets table<string, unknown>
---@param skin integer
---@return ApplicationPlan
local function pairPlan(geometry, inputKey, assets, skin)
  local information = copyPlacement(assert(geometry.placements[INFORMATION_NATIVE.id], "a pair places information"))
  local controls = copyPlacement(assert(geometry.placements[CONTROLS_NATIVE.id], "a pair places controls"))
  return {
    panes = {
      { id = INFORMATION_NATIVE.id, placement = information, interactive = false },
      { id = CONTROLS_NATIVE.id, placement = controls, interactive = true },
    },
    frames = geometry.frames or {},
    content = shellContent(assets, skin),
    inputKey = inputKey,
    render = renderGear,
    mapInput = mapControlsInput,
  }
end

---@param assets table<string, unknown>
---@param skin integer
---@param inputKey string
---@return ApplicationPlan a valid inactive plan: no panes, no targets, dismissal still deliverable
local function inactivePlan(assets, skin, inputKey)
  return {
    panes = {},
    frames = {},
    content = shellContent(assets, skin),
    inputKey = inputKey,
    render = renderGear,
    mapInput = mapControlsInput,
  }
end

---@param view table<string, unknown>
---@return table<string, unknown> assets
---@return integer skin
local function resolveInputs(view)
  local assets = assert(view.assets, "companion resolution needs its borrowed asset family")
  assert(type(assets) == "table", "companion resolution borrows its asset family")
  local skin = view.skin
  assert(type(skin) == "number" and skin % 1 == 0 and skin >= 0 and skin <= 5, "companion resolution needs its skin")
  return assets, --[[@as table<string, unknown>]]
    skin
end

-- One-display fractional fallback: the complete pair envelope drawn with
-- fractional downscale and zero crop, so every control stays reachable
-- below unit scale. Origins stay exact so the pointer inverse matches the
-- drawn target.
---@param context ApplicationLayout.Context
---@param horizontal boolean
---@param inputKey string
---@param assets table<string, unknown>
---@param skin integer
---@return ApplicationPlan
local function fractionalPair(context, horizontal, inputKey, assets, skin)
  local primary = assert(context.primary, "fractional pair resolution requires its primary surface")
  local usable = ApplicationLayout.usableBounds(primary.surface)
  if usable == nil then
    return inactivePlan(assets, skin, inputKey)
  end
  local envelopeWidth = horizontal and 512 or 256
  local envelopeHeight = horizontal and 192 or 384
  local scale = math.min(usable.width / envelopeWidth, usable.height / envelopeHeight)
  assert(scale > 0, "fractional pair resolution requires drawable space")
  local originX = usable.x + (usable.width - envelopeWidth * scale) / 2
  local originY = usable.y + (usable.height - envelopeHeight * scale) / 2
  local infoRect, controlsRect
  if horizontal then
    infoRect = { x = 0, y = 0, width = 256, height = 192 }
    controlsRect = { x = 256, y = 0, width = 256, height = 192 }
  else
    infoRect = { x = 0, y = 0, width = 256, height = 192 }
    controlsRect = { x = 0, y = 192, width = 256, height = 192 }
  end
  local function placement(rect)
    return {
      frame = {
        x = originX + rect.x * scale,
        y = originY + rect.y * scale,
        width = rect.width * scale,
        height = rect.height * scale,
      },
      origin = { x = originX + rect.x * scale, y = originY + rect.y * scale },
      scale = scale,
      logicalWidth = rect.width,
      logicalHeight = rect.height,
    }
  end
  return {
    panes = {
      { id = INFORMATION_NATIVE.id, placement = placement(infoRect), interactive = false },
      { id = CONTROLS_NATIVE.id, placement = placement(controlsRect), interactive = true },
    },
    frames = {},
    content = shellContent(assets, skin),
    inputKey = inputKey,
    render = renderGear,
    mapInput = mapControlsInput,
  }
end

-- Physical dual: information fullscreen on the world surface, controls
-- fullscreen on the auxiliary surface, with zero overdraw so the edge
-- strip survives.
---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan
function PokegearInterface.dualDisplay(context, view)
  local assets, skin = resolveInputs(view)
  local geometry = ApplicationLayout.nativeDual(context, INFORMATION_NATIVE, CONTROLS_NATIVE, {
    upper = { maxOverdraw = ZERO_CROP, protectedRect = INFORMATION_PROTECTED },
    lower = { maxOverdraw = ZERO_CROP, protectedRect = CONTROLS_PROTECTED },
  })
  local information = geometry.placements[INFORMATION_NATIVE.id]
  local controls = geometry.placements[CONTROLS_NATIVE.id]
  if information == nil or controls == nil then
    return inactivePlan(assets, skin, "pokegear-dual-inactive")
  end
  return pairPlan(geometry, "pokegear-dual", assets, skin)
end

-- Wide single display: information left of controls at one shared integer
-- scale with no synthetic gap, fractionally downscaled only below 1x.
---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan
function PokegearInterface.wide(context, view)
  local assets, skin = resolveInputs(view)
  local geometry = ApplicationLayout.sideBySide(context, INFORMATION_NATIVE, CONTROLS_NATIVE, {})
  if geometry == nil then
    return fractionalPair(context, true, "pokegear-wide", assets, skin)
  end
  return pairPlan(geometry, "pokegear-wide", assets, skin)
end

-- Tall single display: information above controls, same fitting rules.
---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan
function PokegearInterface.tall(context, view)
  local assets, skin = resolveInputs(view)
  local geometry = ApplicationLayout.stacked(context, INFORMATION_NATIVE, CONTROLS_NATIVE, {})
  if geometry == nil then
    return fractionalPair(context, false, "pokegear-tall", assets, skin)
  end
  return pairPlan(geometry, "pokegear-tall", assets, skin)
end

-- Near-native single display: the stacked pair, a deliberate local
-- exception to single-pane near-native defaults, because phone speech and
-- radio text live on the other source surface.
---@param context ApplicationLayout.Context
---@param view table<string, unknown>
---@return ApplicationPlan
function PokegearInterface.nativeLike(context, view)
  local assets, skin = resolveInputs(view)
  local geometry = ApplicationLayout.stacked(context, INFORMATION_NATIVE, CONTROLS_NATIVE, {})
  if geometry == nil then
    return fractionalPair(context, false, "pokegear-native", assets, skin)
  end
  return pairPlan(geometry, "pokegear-native", assets, skin)
end

-- The bound default resolver set: one function per display configuration.
---@return table<string, fun(context: ApplicationLayout.Context, view: table<string, unknown>): ApplicationPlan>
function PokegearInterface.defaults()
  return {
    dualDisplay = PokegearInterface.dualDisplay,
    nativeLike = PokegearInterface.nativeLike,
    wide = PokegearInterface.wide,
    tall = PokegearInterface.tall,
  }
end

return PokegearInterface
