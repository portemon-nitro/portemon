-- Paired source-plan geometry for the four PC Storage modes.

local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local NativeDisplay = require("libs.ui.src.NativeDisplay")
local PcStorageGeometry = require("libs.hgss.src.ui.PcStorageGeometry")

local StorageInterface = {}
local UPPER = { id = "upper", width = NativeDisplay.WIDTH, height = NativeDisplay.HEIGHT }
local LOWER = { id = "lower", width = NativeDisplay.WIDTH, height = NativeDisplay.HEIGHT }
local ZERO_CROP = { left = 0, right = 0, top = 0, bottom = 0 }

local function geometry(view)
  local mode = assert(view.mode, "Storage plans carry the retail mode")
  assert(mode >= 0 and mode <= 3, "Storage plans use one of four retail modes")
  local modeGeometry = {
    mode = mode,
    party = view.tray ~= "closed" and {
      x = PcStorageGeometry.PARTY_TRAY_ORIGINS[view.tray].x,
      y = PcStorageGeometry.PARTY_TRAY_ORIGINS[view.tray].y,
      columns = 2,
      rows = 3,
    } or nil,
    box = {
      x = PcStorageGeometry.boxSlotRect(0).x,
      y = PcStorageGeometry.boxSlotRect(0).y,
      columns = PcStorageGeometry.BOX_COLUMNS,
      rows = PcStorageGeometry.BOX_ROWS,
    },
    carry = mode == 2,
    item = mode == 3,
  }
  local slots = {}
  for slot = 0, 29 do
    slots[#slots + 1] = { rect = PcStorageGeometry.boxSlotRect(slot), target = { kind = "box", slot = slot } }
  end
  local visibleParty = {}
  if view.tray ~= "closed" then
    for slot = 0, 5 do
      visibleParty[#visibleParty + 1] = {
        rect = PcStorageGeometry.partySlotRect(slot, view.tray),
        target = { kind = "party", slot = slot },
      }
    end
  end
  local editorChoices = {}
  local editor = view.editor
  if editor ~= nil and editor.kind == "markings" then
    for bit = 0, 5 do
      editorChoices[#editorChoices + 1] = {
        rect = PcStorageGeometry.markingRect(bit),
        target = { type = "marking_choice", id = bit },
      }
    end
  elseif editor ~= nil and editor.kind == "wallpaper" then
    local pageStart = editor.selected - editor.selected % PcStorageGeometry.WALLPAPER_PAGE_SIZE
    for slot = 0, PcStorageGeometry.WALLPAPER_PAGE_SIZE - 1 do
      editorChoices[#editorChoices + 1] = {
        rect = PcStorageGeometry.wallpaperSlotRect(slot),
        target = { type = "wallpaper_choice", id = pageStart + slot },
      }
    end
    editorChoices[#editorChoices + 1] =
      { rect = PcStorageGeometry.WALLPAPER_ARROW_RECTS.left, target = { type = "wallpaper_page", delta = -1 } }
    editorChoices[#editorChoices + 1] =
      { rect = PcStorageGeometry.WALLPAPER_ARROW_RECTS.right, target = { type = "wallpaper_page", delta = 1 } }
    editorChoices[#editorChoices + 1] =
      { rect = PcStorageGeometry.WALLPAPER_CONFIRM_RECT, target = { type = "submit" } }
    editorChoices[#editorChoices + 1] = { rect = PcStorageGeometry.WALLPAPER_CANCEL_RECT, target = { type = "cancel" } }
  end
  -- Deposit mode only hit-tests the party tray until a deposit asks where.
  local boxTouchable = editor == nil and (view.mode ~= 0 or view.carry ~= nil)
  local menuButtons, controls = {}, {}
  if editor == nil and view.menu ~= nil then
    local count = #view.menu.actions
    for index, action in ipairs(view.menu.actions) do
      menuButtons[#menuButtons + 1] = {
        rect = PcStorageGeometry.actionButtonRect(count, index - 1),
        target = { type = "action", action = action },
      }
    end
  end
  if view.message ~= nil and view.message.yesNo then
    controls[#controls + 1] = { rect = PcStorageGeometry.YES_RECT, target = { type = "confirm" } }
    controls[#controls + 1] = { rect = PcStorageGeometry.NO_RECT, target = { type = "cancel" } }
  end
  for _, button in ipairs(PcStorageGeometry.bottomButtons(view)) do
    controls[#controls + 1] = { rect = button.rect, target = button.target }
  end
  if editor == nil then
    if view.carry == nil and view.menu == nil then
      controls[#controls + 1] = { rect = PcStorageGeometry.BOX_TITLE_RECT, target = { type = "box_title" } }
    end
    controls[#controls + 1] =
      { rect = PcStorageGeometry.BOX_ARROW_RECTS.left, target = { type = "navigate", direction = "left" } }
    controls[#controls + 1] =
      { rect = PcStorageGeometry.BOX_ARROW_RECTS.right, target = { type = "navigate", direction = "right" } }
  end
  return modeGeometry,
    {
      boxSlots = boxTouchable and slots or {},
      partySlots = editor == nil and visibleParty or {},
      editorChoices = editorChoices,
      menuButtons = menuButtons,
      controls = controls,
    }
end

local function noRender() end

local function noMap() end

local function mapInput(event, _, plan)
  if event.type == "pointer_move" or event.type == "pointer_up" or event.type == "pointer_scroll" then
    return nil
  end
  if event.type ~= "pointer_down" then
    return event
  end
  for _, hit in ipairs(plan.content.hitRegions.editorChoices) do
    local rect = hit.rect
    if event.x >= rect.x and event.x < rect.x + rect.width and event.y >= rect.y and event.y < rect.y + rect.height then
      return hit.target
    end
  end
  for _, hit in ipairs(plan.content.hitRegions.menuButtons) do
    local rect = hit.rect
    if event.x >= rect.x and event.x < rect.x + rect.width and event.y >= rect.y and event.y < rect.y + rect.height then
      return hit.target
    end
  end
  for _, hit in ipairs(plan.content.hitRegions.controls) do
    local rect = hit.rect
    if event.x >= rect.x and event.x < rect.x + rect.width and event.y >= rect.y and event.y < rect.y + rect.height then
      return hit.target
    end
  end
  for _, hit in ipairs(plan.content.hitRegions.boxSlots) do
    local rect = hit.rect
    if event.x >= rect.x and event.x < rect.x + rect.width and event.y >= rect.y and event.y < rect.y + rect.height then
      return { type = "storage_target", target = hit.target }
    end
  end
  for _, hit in ipairs(plan.content.hitRegions.partySlots) do
    local rect = hit.rect
    if event.x >= rect.x and event.x < rect.x + rect.width and event.y >= rect.y and event.y < rect.y + rect.height then
      return { type = "storage_target", target = hit.target }
    end
  end
  if event.outside == true then
    return { type = "cancel" }
  end
  return nil
end

local function renderPlan(resources, snapshot, resolved)
  local renderer = assert(resources.storageRenderer, "Storage rendering borrows its renderer")
  for _, pane in ipairs(resolved.panes) do
    renderer:drawPane(snapshot, resources, pane.id, pane.placement)
  end
end

local function plan(manifest, panes, frames, view)
  local modeGeometry, hitRegions = geometry(view)
  return {
    panes = panes,
    frames = frames or {},
    content = {
      mode = view.mode,
      wallpaperMap = manifest.storage.geometry.wallpaperMap,
      modeGeometry = modeGeometry,
      hitRegions = hitRegions,
      editor = view.editor,
    },
    inputKey = "pc-storage",
    render = renderPlan,
    mapInput = mapInput,
  }
end

function StorageInterface.defaults(manifest)
  assert(type(manifest) == "table" and type(manifest.storage) == "table", "Storage interface needs its manifest")
  local storage = manifest.storage
  assert(
    type(storage.geometry) == "table" and type(storage.geometry.wallpaperMap) == "table",
    "Storage source geometry is present"
  )
  local interfaces = {}
  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@return ApplicationPlan
  local function dualDisplay(context, view)
    local layout = ApplicationLayout.nativeDual(context, UPPER, LOWER, { lower = { maxOverdraw = ZERO_CROP } })
    local upper, lower = layout.placements.upper, layout.placements.lower
    if upper == nil or lower == nil then
      return {
        panes = {},
        frames = {},
        content = {},
        render = noRender,
        mapInput = noMap,
        inputKey = "pc-storage-inactive",
      }
    end
    return plan(manifest, {
      { id = "upper", placement = upper, interactive = false },
      { id = "lower", placement = lower, interactive = true },
    }, layout.frames, view)
  end
  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@return ApplicationPlan
  local function nativeLike(context, view)
    local resolved = ApplicationLayout.coverOrFrame(context, LOWER, { maxOverdraw = ZERO_CROP })
    local lower = resolved.placements.lower
    if lower == nil then
      return {
        panes = {},
        frames = {},
        content = {},
        render = noRender,
        mapInput = noMap,
        inputKey = "pc-storage-inactive",
      }
    end
    return plan(manifest, { { id = "lower", placement = lower, interactive = true } }, resolved.frames, view)
  end
  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@return ApplicationPlan
  local function wide(context, view)
    local resolved = ApplicationLayout.sideBySide(context, UPPER, LOWER, { lower = { maxOverdraw = ZERO_CROP } })
    if resolved == nil then
      return nativeLike(context, view)
    end
    local upper, lower = resolved.placements.upper, resolved.placements.lower
    if upper == nil or lower == nil then
      return nativeLike(context, view)
    end
    return plan(manifest, {
      { id = "upper", placement = upper, interactive = false },
      { id = "lower", placement = lower, interactive = true },
    }, resolved.frames, view)
  end
  ---@param context ApplicationLayout.Context
  ---@param view table<string, unknown>
  ---@return ApplicationPlan
  local function tall(context, view)
    local resolved = ApplicationLayout.stacked(context, UPPER, LOWER, { lower = { maxOverdraw = ZERO_CROP } })
    if resolved == nil then
      return nativeLike(context, view)
    end
    local upper, lower = resolved.placements.upper, resolved.placements.lower
    if upper == nil or lower == nil then
      return nativeLike(context, view)
    end
    return plan(manifest, {
      { id = "upper", placement = upper, interactive = false },
      { id = "lower", placement = lower, interactive = true },
    }, resolved.frames, view)
  end
  interfaces.dualDisplay = dualDisplay
  interfaces.nativeLike = nativeLike
  interfaces.wide = wide
  interfaces.tall = tall
  return interfaces
end

return StorageInterface
