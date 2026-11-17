-- Bounded native MailView write plan and mapped source controls. The
-- geometry follows the retail MailView exactly (mail_view.c): three 208x32
-- line windows, the Confirm/Cancel button pair, and the source half-open
-- touch rectangles with the BG2 character-pixel-1 rejection already baked
-- into the generated masks. The write screen shows the three sentence
-- windows with the source Confirm/Cancel labels and never draws the author
-- or the captured icons. TEXT also carries the read screen's author and
-- line anchors the Mailbox read leaf draws with.
-- No saved values, asset acquisition, or custody lives here: the plan
-- only places the native controls and projects raw input onto them.

local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local LogicalSurface = require("libs.ui.src.LogicalSurface")
local NativeDisplay = require("libs.ui.src.NativeDisplay")

local MailViewInterface = {}

local UPPER = { id = "upper", width = NativeDisplay.WIDTH, height = NativeDisplay.HEIGHT }
local LOWER = { id = "lower", width = NativeDisplay.WIDTH, height = NativeDisplay.HEIGHT }
local ZERO_CROP = { left = 0, right = 0, top = 0, bottom = 0 }

-- Source controls in cursor order: three line rows, then Confirm, then
-- Cancel. Touch rectangles are half-open; the keyboard cursor walks
-- positions 0..2 for lines, 3 for Confirm, 4 for Cancel.
MailViewInterface.CONTROLS = {
  { x = 24, y = 24, width = 208, height = 32 },
  { x = 24, y = 64, width = 208, height = 32 },
  { x = 24, y = 104, width = 208, height = 32 },
  { x = 24, y = 148, width = 64, height = 24 },
  { x = 160, y = 148, width = 64, height = 24 },
}

-- Source text anchors: the three line windows, the centered button
-- labels at local y=2, and the read author anchor.
MailViewInterface.TEXT = {
  lines = {
    { x = 24, y = 24, width = 208, height = 32 },
    { x = 24, y = 64, width = 208, height = 32 },
    { x = 24, y = 104, width = 208, height = 32 },
  },
  confirm = { x = 24, y = 160, width = 64, height = 16 },
  cancel = { x = 168, y = 160, width = 64, height = 16 },
  confirmLabel = { x = 24, y = 162 },
  cancelLabel = { x = 168, y = 162 },
  author = { x = 168, y = 161 },
}

local function copyRect(rect)
  return { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
end

---@param masks unknown
local function checkMasks(masks)
  assert(type(masks) == "table" and #masks == 5, "write mapping needs its five generated masks")
  for position, mask in ipairs(masks) do
    assert(type(mask) == "table", "write mask " .. position .. " is a record")
    assert(type(mask.rows) == "table" and #mask.rows == mask.height, "write mask rows match its height")
    for _, bits in ipairs(mask.rows) do
      assert(
        type(bits) == "string" and #bits == mask.width and bits:find("[^01]") == nil,
        "write mask rows are binary strings of exactly width characters"
      )
    end
  end
end

local function hitRect(rect, x, y)
  return x >= rect.x and x < rect.x + rect.width and y >= rect.y and y < rect.y + rect.height
end

-- Projects one native point onto the five cursor-ordered controls: the
-- half-open rectangle admits the touch, then the exact generated mask
-- bit admits the source pixel. Padding, outside points, and mask misses
-- map to nothing.
---@param masks table[]
---@param x number
---@param y number
---@return table<string, unknown>? action
local function mapControls(masks, x, y)
  for position, rect in ipairs(MailViewInterface.CONTROLS) do
    if hitRect(rect, x, y) then
      local mask = masks[position]
      local bit = mask.rows[y - rect.y + 1]:sub(x - rect.x + 1, x - rect.x + 1)
      if bit == "1" then
        if position <= 3 then
          return { type = "line", index = position, source = "touch" }
        elseif position == 4 then
          return { type = "confirm", source = "touch" }
        else
          return { type = "cancel", source = "touch" }
        end
      end
      return nil
    end
  end
  return nil
end

local function render(resources, view, plan)
  local graphics = assert(resources.graphics, "MailView drawing borrows the host graphics namespace")
  local renderer = assert(resources.mailboxRenderer, "MailView drawing borrows the shared stationery renderer")
  for _, pane in ipairs(plan.panes) do
    LogicalSurface.draw(graphics, pane.placement, function()
      renderer:drawMailPane(view, pane.id, resources)
    end)
  end
end

-- Maps one already-placed logical event: keys pass through for the
-- owner's modality handling, pointer presses project onto the source
-- controls, and everything else is consumed silently.
---@param event table<string, unknown>
---@param _ table<string, unknown> unused detached view
---@param plan table<string, unknown>
---@return table<string, unknown>?
local function mapInput(event, _, plan)
  if event.type == "pointer_cancel" then
    local copy = {}
    for key, value in pairs(event) do
      copy[key] = value
    end
    return copy
  end
  if event.type == "pointer_down" and event.outside == true then
    return nil
  end
  if event.type == "pointer_down" and type(event.x) == "number" and type(event.y) == "number" then
    local masks = assert(plan.masks, "write mapping needs its generated masks")
    return mapControls(masks, event.x, event.y)
  end
  if event.type == "pointer_move" or event.type == "pointer_up" or event.type == "pointer_scroll" then
    return nil
  end
  local copy = {}
  for key, value in pairs(event) do
    copy[key] = value
  end
  return copy
end

local function blankPlan()
  return {
    mode = "write",
    panes = {},
    frames = {},
    content = { panes = {} },
    inputKey = "mail-view-inactive",
    render = render,
    mapInput = mapInput,
  }
end

---@param geometry table<string, unknown>?
---@param view table<string, unknown>
---@return table<string, unknown>
local function planFromGeometry(geometry, view)
  if geometry == nil then
    return blankPlan()
  end
  local panes = {}
  for _, pane in ipairs({ "upper", "lower" }) do
    local placement = geometry.placements[pane]
    if placement ~= nil then
      panes[#panes + 1] = { id = pane, placement = placement, interactive = pane == "lower" }
    end
  end
  -- Unavailable space carries no interactive region: the plan disables
  -- input instead of mapping through a degenerate placement.
  local interactive = false
  for _, pane in ipairs(panes) do
    interactive = interactive or pane.interactive
  end
  if not interactive then
    return blankPlan()
  end
  local controls = {}
  for _, rect in ipairs(MailViewInterface.CONTROLS) do
    controls[#controls + 1] = copyRect(rect)
  end
  return {
    mode = "write",
    controls = controls,
    masks = view.hitMasks,
    panes = panes,
    frames = geometry.frames or {},
    content = { panes = panes, mode = "write" },
    inputKey = "mail-view",
    render = render,
    mapInput = mapInput,
  }
end

local function resolversFor(view)
  local function nativeLike(context, _)
    return planFromGeometry(ApplicationLayout.coverOrFrame(context, LOWER, { maxOverdraw = ZERO_CROP }), view)
  end
  local function dualDisplay(context, _)
    local geometry = ApplicationLayout.nativeDual(context, UPPER, LOWER, { lower = { maxOverdraw = ZERO_CROP } })
    return planFromGeometry(geometry, view)
  end
  local function wide(context, seen)
    local geometry = ApplicationLayout.sideBySide(context, UPPER, LOWER)
    if geometry == nil then
      return context.nativeLikeInterface(context, seen)
    end
    return planFromGeometry(geometry, view)
  end
  local function tall(context, seen)
    local geometry = ApplicationLayout.stacked(context, UPPER, LOWER)
    if geometry == nil then
      return context.nativeLikeInterface(context, seen)
    end
    return planFromGeometry(geometry, view)
  end
  return {
    dualDisplay = dualDisplay,
    nativeLike = nativeLike,
    wide = wide,
    tall = tall,
  }
end

-- Resolves the bounded native plan for one display: the main interaction
-- on the available interaction display (the physical bottom on dual DS,
-- beside the source backdrop on top) and the inactive plan when no
-- region fits. The view carries the generated write masks; no saved
-- values or asset handles are read.
---@param display table<string, unknown> current display facts
---@param view table<string, unknown> detached snapshot carrying the write hitMasks
---@return table<string, unknown> bounded application plan
function MailViewInterface.plan(display, view)
  assert(type(display) == "table", "MailView presentation needs display facts")
  assert(type(view) == "table", "MailView presentation needs its detached view")
  checkMasks(assert(view.hitMasks, "write mapping needs its generated masks"))
  local resolvers = resolversFor(view)
  local configuration = ApplicationLayout.classify(display, nil)
  local selection = ApplicationLayout.selectSurfaces(display)
  local context = {
    measurement = display,
    configuration = configuration,
    primary = selection.primary,
    secondary = selection.secondary,
    nativeLikeInterface = resolvers.nativeLike,
  }
  local resolve = assert(resolvers[configuration], "MailView needs its " .. tostring(configuration) .. " resolver")
  return resolve(context, view)
end

-- Projects one raw batch through the admitted interaction placement:
-- padding, outside points, and source mask misses never reach the owner.
-- Keys pass through for the owner's modality handling.
---@param plan table<string, unknown> resolved MailView plan
---@param rawEvents table[] host event batch
---@param hitMasks table[] five generated rect-local masks in cursor order
---@return table[] mapped semantic batch
function MailViewInterface.events(plan, rawEvents, hitMasks)
  assert(type(plan) == "table", "MailView input needs its resolved plan")
  assert(type(rawEvents) == "table", "MailView input needs an event batch")
  checkMasks(hitMasks)
  local interactive = nil
  for _, pane in ipairs(assert(plan.panes, "MailView input maps through the admitted placement")) do
    if pane.interactive then
      interactive = pane
      break
    end
  end
  local routed = {}
  for _, event in ipairs(rawEvents) do
    assert(type(event) == "table" and type(event.type) == "string", "MailView events need a type")
    if event.type == "pointer_cancel" then
      local copy = {}
      for key, value in pairs(event) do
        copy[key] = value
      end
      routed[#routed + 1] = copy
    elseif event.type == "pointer_down" or event.type == "touch" then
      if interactive ~= nil and type(event.x) == "number" and type(event.y) == "number" then
        local x, y = LayoutGeometry.hostToLogical(interactive.placement, event.x, event.y)
        if x ~= nil and y ~= nil then
          local action = mapControls(hitMasks, x, y)
          if action ~= nil then
            routed[#routed + 1] = action
          end
        end
      end
    elseif event.type == "pointer_up" or event.type == "pointer_move" or event.type == "pointer_scroll" then
      -- The source samples new presses only; motion and releases never act.
    else
      local copy = {}
      for key, value in pairs(event) do
        copy[key] = value
      end
      routed[#routed + 1] = copy
    end
  end
  return routed
end

return MailViewInterface
