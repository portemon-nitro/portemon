-- Paired source-plan geometry for the four PC Storage modes.

local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local NativeDisplay = require("libs.ui.src.NativeDisplay")

local StorageInterface = {}
local UPPER = { id = "upper", width = NativeDisplay.WIDTH, height = NativeDisplay.HEIGHT }
local LOWER = { id = "lower", width = NativeDisplay.WIDTH, height = NativeDisplay.HEIGHT }
local ZERO_CROP = { left = 0, right = 0, top = 0, bottom = 0 }

local function geometry(view, partyTouchTargets)
  local mode = assert(view.mode, "Storage plans carry the retail mode")
  assert(mode >= 0 and mode <= 3, "Storage plans use one of four retail modes")
  local modeGeometry = {
    mode = mode,
    party = { x = 8, y = 24, columns = 1, rows = 6 },
    box = { x = 80, y = 16, columns = 6, rows = 5 },
    carry = mode == 2,
    item = mode == 3,
  }
  local slots = {}
  for slot = 0, 29 do
    local column, row = slot % 6, math.floor(slot / 6)
    local rect = { x = 80 + column * 28, y = 16 + row * 28, width = 24, height = 24 }
    slots[#slots + 1] = { rect = rect, target = { kind = "box", slot = slot } }
  end
  local visibleParty = {}
  for slot = 0, 5 do
    visibleParty[#visibleParty + 1] = {
      rect = { x = 8, y = 24 + slot * 24, width = 64, height = 20 },
      target = { kind = "party", slot = slot },
    }
  end
  local editorChoices = {}
  local editor = view.editor
  if editor ~= nil and editor.kind == "markings" then
    for bit = 0, 5 do
      editorChoices[#editorChoices + 1] = {
        rect = { x = 120 + bit * 8, y = 8, width = 8, height = 8 },
        target = { type = "marking_choice", id = bit },
      }
    end
  elseif editor ~= nil and editor.kind == "wallpaper" then
    local unlocks = assert(view.wallpaperUnlocks, "Storage plans carry wallpaper unlocks")
    local current = assert(view.wallpaperId, "Storage plans carry the current wallpaper")
    for choice = 0, 23 do
      local column, row = choice % 4, math.floor(choice / 4)
      local storedId = choice < 16 and choice or choice + 16
      local unlocked = choice < 16 or unlocks[choice - 15] == true
      if unlocked and storedId ~= current then
        editorChoices[#editorChoices + 1] = {
          rect = { x = 37 + column * 46, y = 20 + row * 24, width = 44, height = 20 },
          target = { type = "wallpaper_choice", id = choice },
        }
      end
    end
  end
  return modeGeometry,
    {
      boxSlots = slots,
      partySlots = partyTouchTargets and visibleParty or {},
      editorChoices = editorChoices,
    }
end

local function noRender() end

local function noMap() end

local function mapInput(event, _, plan)
  if event.type ~= "pointer_down" then
    return event
  end
  for _, hit in ipairs(plan.content.hitRegions.editorChoices) do
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
  return event
end

local function renderPlan(resources, snapshot, resolved)
  local renderer = assert(resources.storageRenderer, "Storage rendering borrows its renderer")
  for _, pane in ipairs(resolved.panes) do
    renderer:drawPane(snapshot, resources, pane.id, pane.placement, #resolved.panes == 1)
  end
end

local function plan(manifest, panes, frames, view, partyTouchTargets)
  local modeGeometry, hitRegions = geometry(view, partyTouchTargets)
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
    return plan(manifest, { { id = "lower", placement = lower, interactive = true } }, resolved.frames, view, true)
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
