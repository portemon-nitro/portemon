-- Pairs Photo Album art and hit regions in its native 256x192 surface.

local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local NativeDisplay = require("libs.ui.src.NativeDisplay")

local PhotoAlbumInterface = {}
local DISPLAY = { id = "album", width = NativeDisplay.WIDTH, height = NativeDisplay.HEIGHT }
local ZERO_CROP = { left = 0, right = 0, top = 0, bottom = 0 }
local VIEWPORT = { x = 4, y = 3, width = 248, height = 185 }
-- Slot hit boxes are the first twelve source rectangles in overlay_109.s
-- ov109_021E7A18, grouped as four columns by three rows.
local GRID_X = { 32, 80, 136, 184 }
local GRID_Y = { 12, 52, 92 }

local function controlsFor(view)
  local controls = {}
  if view.phase == "list" or view.phase == "move_target" then
    for index, entry in ipairs(view.visiblePhotos or {}) do
      local column = ((index - 1) % 4) + 1
      local row = math.floor((index - 1) / 4) + 1
      controls[#controls + 1] = {
        target = "photo",
        slot = entry.slot,
        rect = { x = GRID_X[column], y = GRID_Y[row], width = 40, height = 32 },
        selected = entry.slot == view.selectedSlot,
      }
    end
  elseif view.phase == "actions" then
    for index, action in ipairs({ "view", "delete", "move", "cancel" }) do
      controls[#controls + 1] = {
        target = "action",
        action = action,
        label = string.upper(action),
        rect = { x = 52, y = 88 + (index - 1) * 28, width = 152, height = 24 },
        selected = action == view.selectedAction,
      }
    end
  elseif view.phase == "delete_confirm" then
    for index, choice in ipairs({ "yes", "no" }) do
      controls[#controls + 1] = {
        target = "delete-choice",
        choice = choice,
        label = string.upper(choice),
        rect = { x = 64 + (index - 1) * 72, y = 128, width = 64, height = 24 },
        selected = choice == view.deleteChoice,
      }
    end
  elseif view.phase == "viewer" then
    local index
    for slotIndex, slot in ipairs(view.occupiedSlots) do
      if slot == view.selectedSlot then
        index = slotIndex
        break
      end
    end
    controls[#controls + 1] = {
      target = "viewer",
      action = "previous",
      sprite = "previous",
      enabled = index ~= nil and index > 1,
      rect = { x = 80, y = 24, width = 16, height = 32 },
    }
    controls[#controls + 1] = {
      target = "viewer",
      action = "next",
      sprite = "next",
      enabled = index ~= nil and index < #view.occupiedSlots,
      rect = { x = 160, y = 24, width = 16, height = 32 },
    }
    controls[#controls + 1] = {
      target = "viewer",
      action = "back",
      label = "EXIT",
      sprite = "back",
      rect = { x = 194, y = 162, width = 60, height = 26 },
    }
  end
  return controls
end

local function render(resources, view, plan)
  local renderer = assert(resources.photoAlbumRenderer, "Photo Album presentation borrows its renderer")
  renderer:draw(view, plan, resources)
end

local function mapInput(event, _, plan)
  if event.type ~= "pointer_down" or event.outside == true then
    return event
  end
  for _, control in ipairs(plan.controls) do
    if control.enabled ~= false and LayoutGeometry.containsPoint(control.rect, event.x, event.y) then
      if control.target == "photo" then
        return { type = "activate", target = "photo", slot = control.slot }
      end
      if control.target == "action" then
        return { type = "activate", target = "action", action = control.action }
      end
      if control.target == "delete-choice" then
        return { type = "activate", target = "delete-choice", choice = control.choice }
      end
      return { type = "activate", target = "viewer", action = control.action }
    end
  end
  return nil
end

local function plan(manifest, geometry, view)
  local pane = geometry.placements[DISPLAY.id]
  return {
    panes = pane and { { id = DISPLAY.id, placement = pane, interactive = true } } or {},
    frames = geometry.frames or {},
    content = manifest.photoAlbum,
    photoViewport = VIEWPORT,
    controls = controlsFor(view),
    inputKey = "photo-album",
    render = render,
    mapInput = mapInput,
  }
end

function PhotoAlbumInterface.defaults(manifest)
  assert(type(manifest) == "table" and type(manifest.photoAlbum) == "table", "Photo Album assets are required")
  local interfaces = {}
  ---@param context table<string, unknown>
  ---@param view table<string, unknown>
  ---@return table<string, unknown>
  local function nativeLike(context, view)
    return plan(manifest, ApplicationLayout.coverOrFrame(context, DISPLAY, { maxOverdraw = ZERO_CROP }), view)
  end
  ---@param context table<string, unknown>
  ---@param view table<string, unknown>
  ---@return table<string, unknown>
  local function fit(context, view)
    return nativeLike(context, view)
  end
  interfaces.dualDisplay = fit
  interfaces.nativeLike = nativeLike
  interfaces.wide = fit
  interfaces.tall = fit
  return interfaces
end

return PhotoAlbumInterface
