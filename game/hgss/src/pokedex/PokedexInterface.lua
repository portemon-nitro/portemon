-- Shared draw/input placement for the field Pokedex: the complete browser
-- layout family and the registration layout over the same plan mechanics.
-- Dual, wide, and tall preserve both original 256x192 panels at integer
-- scale; the single-display nativeLike case is the complete compact
-- arrangement with all fifteen grid cells and the selected species
-- information visible together. Interface definitions are immutable;
-- sessions own captures. Measure and path lookups never allocate GPU
-- objects, and mapInput never touches mutable game state.

local ApplicationLayout = require("libs.ui.src.ApplicationLayout")

---@class PokedexInterface
local PokedexInterface = {}

local NATIVE_WIDTH = 256
local NATIVE_HEIGHT = 192

local INFORMATION_NATIVE = { id = "information", width = NATIVE_WIDTH, height = NATIVE_HEIGHT }
local CONTROLS_NATIVE = { id = "controls", width = NATIVE_WIDTH, height = NATIVE_HEIGHT }
local REGISTRATION_NATIVE = { id = "registration", width = NATIVE_WIDTH, height = NATIVE_HEIGHT }
local REGISTRATION_TOUCH_NATIVE = { id = "registrationTouch", width = NATIVE_WIDTH, height = NATIVE_HEIGHT }

-- Compact footer buttons: half-open rectangles in the 256x24 footer strip.
local COMPACT_FOOTER = {
  { id = "page-prev", x = 0, width = 24 },
  { id = "page-next", x = 24, width = 24 },
  { id = "cover", x = 48, width = 48 },
  { id = "search", x = 96, width = 48 },
  { id = "cry", x = 144, width = 32 },
  { id = "language", x = 176, width = 40 },
  { id = "exit", x = 216, width = 40 },
}

-- Compact cover footer: SEARCH, OPEN, EXIT thirds.
local COMPACT_COVER_FOOTER = {
  { id = "search", x = 0, width = 80 },
  { id = "open", x = 80, width = 96 },
  { id = "exit", x = 176, width = 80 },
}

-- Compact entry tabs: four 64px tabs across the footer.
local COMPACT_TABS = { "area", "size", "forms", "return" }

---@param x number
---@param y number
---@param rect { x: number, y: number, width: number, height: number }
---@return boolean
local function containsPoint(x, y, rect)
  return x >= rect.x and y >= rect.y and x < rect.x + rect.width and y < rect.y + rect.height
end

---@param placement table<string, unknown> validated pane placement
---@return { x: number, y: number, width: number, height: number } logical pane extent
local function paneRect(placement)
  local frame = assert(placement.frame, "browser panes carry their frame")
  assert(type(frame) == "table", "browser pane frames stay records")
  local origin = placement.origin or frame
  assert(type(origin) == "table", "browser pane origins stay records")
  return {
    x = origin.x,
    y = origin.y,
    width = placement.logicalWidth or frame.width,
    height = placement.logicalHeight or frame.height,
  }
end

---@param plan table<string, unknown> resolved application plan
---@param x number logical x
---@param y number logical y
---@return string? pane id behind the logical point
local function paneAt(plan, x, y)
  local panes = assert(plan.panes, "browser plans carry their panes")
  assert(type(panes) == "table", "browser panes stay a list")
  for index = #panes, 1, -1 do
    local pane = panes[index]
    if type(pane) == "table" and pane.interactive and type(pane.placement) == "table" then
      local rect = paneRect(pane.placement)
      if containsPoint(x, y, rect) then
        return pane.id
      end
    end
  end
  return nil
end

-- Renders the prepared browser bundle through the one shared renderer.
-- The browser prepared view carries the detached projection, the
-- committed assets, and the private compact record.
---@param resources table<string, unknown> borrowed draw resources with the renderer
---@param preparedView table<string, unknown> { view, assets, compact }
---@param plan table<string, unknown> the resolved application plan
local function renderBrowser(resources, preparedView, plan)
  local renderer = assert(resources.renderer, "browser drawing borrows its shared renderer")
  assert(type(renderer.drawBrowser) == "function", "browser drawing reaches the shared renderer")
  renderer:drawBrowser({
    view = assert(preparedView.view, "browser draws carry their projection"),
    assets = assert(preparedView.assets, "browser draws carry their committed bundle"),
    compact = preparedView.compact,
  }, plan)
end

-- Maps one logical pointer edge to the finite browser commands. Unknown
-- regions and hidden compact controls map to nothing; host-only
-- inspection and size presentation stay distinct from model commands.
---@param event table<string, unknown> logical pointer event in pane space
---@param view table<string, unknown> detached projection selecting the page
---@param plan table<string, unknown> the resolved application plan
---@return table<string, unknown>? finite model or host command
local function mapBrowserInput(event, view, plan)
  if event.type ~= "pointer_down" or type(event.x) ~= "number" or type(event.y) ~= "number" then
    return nil
  end
  local paneId = paneAt(plan, event.x, event.y)
  if paneId == nil then
    return nil
  end
  local rect = nil
  for _, pane in ipairs(plan.panes) do
    if type(pane) == "table" and pane.id == paneId and type(pane.placement) == "table" then
      rect = paneRect(pane.placement)
    end
  end
  if rect == nil then
    return nil
  end
  local x, y = event.x - rect.x, event.y - rect.y
  local page = view.page
  if paneId == "information" then
    if page == "cover" then
      return { type = "confirm" }
    end
    if x >= 8 and x < 88 and y >= 32 and y < 112 then
      return { type = "inspect" }
    end
    return nil
  end
  if paneId ~= "controls" then
    return nil
  end
  if y >= 168 then
    if page == "cover" then
      for _, button in ipairs(COMPACT_COVER_FOOTER) do
        if x >= button.x and x < button.x + button.width then
          if button.id == "open" then
            return { type = "confirm" }
          elseif button.id == "exit" then
            return { type = "cancel" }
          else
            return { type = "activate", action = button.id }
          end
        end
      end
      return nil
    end
    if page == "area" or page == "size" or page == "forms" or page == "return" then
      local slot = math.floor(x / 64)
      local tab = COMPACT_TABS[slot + 1]
      if tab ~= nil then
        return { type = "activate", action = "entry-tab", value = tab }
      end
      return nil
    end
    for _, button in ipairs(COMPACT_FOOTER) do
      if x >= button.x and x < button.x + button.width then
        if button.id == "exit" then
          return { type = "cancel" }
        end
        return { type = "activate", action = button.id }
      end
    end
    return nil
  end
  if page == "grid" or page == "results" then
    if x < 160 and y >= 16 and y < 136 then
      local column = math.floor(x / 32)
      local row = math.floor((y - 16) / 40)
      if column >= 0 and column < 5 and row >= 0 and row < 3 then
        return { type = "activate", action = "grid-slot", value = row * 5 + column }
      end
    end
    return nil
  end
  return nil
end

---@param geometry table<string, unknown>? layout geometry with placements by pane id
---@param paneIds string[] ordered pane identities, later panes hit-test first
---@param interactive boolean
---@return { id: string, placement: table<string, unknown>, interactive: boolean }[] plan panes
local function panesFrom(geometry, paneIds, interactive)
  assert(type(geometry) == "table", "browser geometry resolves its placements")
  local placements = assert(geometry.placements, "browser geometry carries its placements")
  assert(type(placements) == "table", "browser placements stay a record")
  local panes = {}
  for _, id in ipairs(paneIds) do
    local placement = assert(placements[id], "browser geometry places pane " .. id)
    panes[#panes + 1] = { id = id, placement = placement, interactive = interactive }
  end
  return panes
end

---@param panes table<string, unknown>[] resolved plan panes
---@param inputKey string stable input-geometry identity
---@return table<string, unknown> complete application plan
local function browserPlan(panes, inputKey)
  return {
    panes = panes,
    frames = {},
    content = {},
    inputKey = inputKey,
    render = renderBrowser,
    mapInput = mapBrowserInput,
  }
end

local function mapUnavailableInput()
  return nil
end

-- The unavailable plan below the minimum compact size: no interactive
-- controls and no pointer mapping, so hidden content can never activate.
---@param inputKey string
---@return table<string, unknown> complete application plan
local function unavailablePlan(inputKey)
  return {
    panes = {},
    frames = {},
    content = { unavailable = true },
    inputKey = inputKey,
    render = renderBrowser,
    mapInput = mapUnavailableInput,
  }
end

---@param measurement table<string, unknown> fresh host facts
---@return boolean true when the display cannot fit the compact arrangement
local function belowMinimum(measurement)
  local width = measurement.width
  local height = measurement.height
  if type(width) == "number" and type(height) == "number" then
    return width < NATIVE_WIDTH or height < NATIVE_HEIGHT
  end
  return false
end

-- Builds the compact information plus controls panes over the single
-- 256x192 surface: the information region carries the grid, portrait,
-- and metadata while the footer strip carries the finite buttons.
---@return { information: table<string, unknown>, controls: table<string, unknown> } placements
local function compactPlacements()
  local information = {
    frame = { x = 0, y = 0, width = NATIVE_WIDTH, height = 168 },
    origin = { x = 0, y = 0 },
    scale = 1,
    logicalWidth = NATIVE_WIDTH,
    logicalHeight = 168,
  }
  local controls = {
    frame = { x = 0, y = 168, width = NATIVE_WIDTH, height = 24 },
    origin = { x = 0, y = 168 },
    scale = 1,
    logicalWidth = NATIVE_WIDTH,
    logicalHeight = 24,
  }
  return { information = information, controls = controls }
end

---@param view table<string, unknown> detached projection selecting the page
---@return string input-geometry identity for the browser plan
local function browserInputKey(view)
  local page = view.page
  if type(page) ~= "string" then
    page = "cover"
  end
  local compact = view.compact
  local inspect = "closed"
  local size = "weight"
  if type(compact) == "table" then
    if compact.inspect == true then
      inspect = "open"
    end
    if compact.size == "height" then
      size = "height"
    end
  end
  return "pokedex-browser:" .. page .. ":" .. inspect .. ":" .. size
end

-- Resolves one browser plan for the paired native configuration: both
-- original 256x192 panels at integer scale through the shared pair
-- helpers, falling back to the compact arrangement when the pair cannot
-- fit and to the unavailable plan below the minimum size.
---@param context table<string, unknown> layout context with the selected surfaces
---@param measurement table<string, unknown> fresh host facts
---@param upper table<string, unknown> information native pane
---@param lower table<string, unknown> controls native pane
---@param pair fun(context: table<string, unknown>, upper: table<string, unknown>, lower: table<string, unknown>): table<string, unknown>?
---@param view table<string, unknown> detached projection owning the page and compact record
---@return table<string, unknown> complete application plan
local function pairedBrowserPlan(context, measurement, upper, lower, pair, view)
  if belowMinimum(measurement) then
    return unavailablePlan(browserInputKey(view) .. ":unavailable")
  end
  local geometry = pair(context, upper, lower)
  if geometry == nil then
    local placements = compactPlacements()
    return browserPlan({
      { id = "information", placement = placements.information, interactive = true },
      { id = "controls", placement = placements.controls, interactive = true },
    }, browserInputKey(view) .. ":compact-fallback")
  end
  return browserPlan(panesFrom(geometry, { "information", "controls" }, true), browserInputKey(view) .. ":paired")
end

-- Renders the prepared registration bundle through the one shared
-- renderer. The registration prepared view carries the terminal card
-- projection and the committed card bundle.
---@param resources table<string, unknown> borrowed draw resources with the renderer
---@param preparedView table<string, unknown> { view, assets }
---@param plan table<string, unknown> the resolved application plan
local function renderRegistration(resources, preparedView, plan)
  local renderer = assert(resources.renderer, "registration drawing borrows its shared renderer")
  assert(type(renderer.drawRegistration) == "function", "registration drawing reaches the shared renderer")
  renderer:drawRegistration({
    view = assert(preparedView.view, "registration draws carry their card projection"),
    assets = assert(preparedView.assets, "registration draws carry their committed bundle"),
  }, plan)
end

-- Either registration pane turns a fresh pointer-down into one touch
-- edge; there is no matched-release requirement and no other pointer
-- shape maps.
---@param event table<string, unknown> logical pointer event in pane space
---@return table<string, unknown>? one fresh touch edge
local function mapRegistrationInput(event)
  if event.type ~= "pointer_down" then
    return nil
  end
  return { type = "touch_new", pointerId = event.pointerId }
end

---@param panes table<string, unknown>[] resolved plan panes
---@param inputKey string stable input-geometry identity
---@return table<string, unknown> complete application plan
local function registrationPlan(panes, inputKey)
  return {
    panes = panes,
    frames = {},
    content = {},
    inputKey = inputKey,
    render = renderRegistration,
    mapInput = mapRegistrationInput,
  }
end

---@param overrides table<string, fun(context: table<string, unknown>, view: table<string, unknown>): table<string, unknown>>? per-case resolver replacements
---@return { dualDisplay: fun(context: table<string, unknown>, view: table<string, unknown>): table<string, unknown>, nativeLike: fun(context: table<string, unknown>, view: table<string, unknown>): table<string, unknown>, wide: fun(context: table<string, unknown>, view: table<string, unknown>): table<string, unknown>, tall: fun(context: table<string, unknown>, view: table<string, unknown>): table<string, unknown> }
function PokedexInterface.browser(overrides)
  ---@param context table<string, unknown>
  ---@param view table<string, unknown>
  ---@return table<string, unknown> complete application plan
  local function dualDisplay(context, view)
    local measurement = assert(context.measurement, "browser plans measure their display")
    return pairedBrowserPlan(context, measurement, INFORMATION_NATIVE, CONTROLS_NATIVE, function(inner, upper, lower)
      return ApplicationLayout.nativeDual(inner, upper, lower)
    end, view)
  end
  ---@param context table<string, unknown>
  ---@param view table<string, unknown>
  ---@return table<string, unknown> complete application plan
  local function wide(context, view)
    local measurement = assert(context.measurement, "browser plans measure their display")
    return pairedBrowserPlan(context, measurement, INFORMATION_NATIVE, CONTROLS_NATIVE, function(inner, upper, lower)
      return ApplicationLayout.sideBySide(inner, upper, lower)
    end, view)
  end
  ---@param context table<string, unknown>
  ---@param view table<string, unknown>
  ---@return table<string, unknown> complete application plan
  local function tall(context, view)
    local measurement = assert(context.measurement, "browser plans measure their display")
    return pairedBrowserPlan(context, measurement, INFORMATION_NATIVE, CONTROLS_NATIVE, function(inner, upper, lower)
      return ApplicationLayout.stacked(inner, upper, lower)
    end, view)
  end
  ---@param context table<string, unknown>
  ---@param view table<string, unknown>
  ---@return table<string, unknown> complete application plan
  local function nativeLike(context, view)
    local measurement = assert(context.measurement, "browser plans measure their display")
    assert(type(view) == "table", "browser plans place their projection")
    local _ = context
    if belowMinimum(measurement) then
      return unavailablePlan(browserInputKey(view) .. ":unavailable")
    end
    local placements = compactPlacements()
    return browserPlan({
      { id = "information", placement = placements.information, interactive = true },
      { id = "controls", placement = placements.controls, interactive = true },
    }, browserInputKey(view) .. ":compact")
  end
  local interfaces = { dualDisplay = dualDisplay, nativeLike = nativeLike, wide = wide, tall = tall }
  if overrides ~= nil then
    assert(type(overrides) == "table", "interface overrides arrive as a record")
    for key, resolver in pairs(overrides) do
      assert(
        key == "dualDisplay" or key == "nativeLike" or key == "wide" or key == "tall",
        "interface overrides replace a known case"
      )
      assert(type(resolver) == "function", "interface overrides replace whole render and input pairs")
      interfaces[key] = resolver
    end
  end
  return interfaces
end

---@param overrides table<string, fun(context: table<string, unknown>, view: table<string, unknown>): table<string, unknown>>? per-case resolver replacements
---@return { dualDisplay: fun(context: table<string, unknown>, view: table<string, unknown>): table<string, unknown>, nativeLike: fun(context: table<string, unknown>, view: table<string, unknown>): table<string, unknown>, wide: fun(context: table<string, unknown>, view: table<string, unknown>): table<string, unknown>, tall: fun(context: table<string, unknown>, view: table<string, unknown>): table<string, unknown> }
function PokedexInterface.registration(overrides)
  ---@param context table<string, unknown>
  ---@param view table<string, unknown>
  ---@return table<string, unknown> complete application plan
  local function dualDisplay(context, view)
    local measurement = assert(context.measurement, "registration plans measure their display")
    local _ = view
    if belowMinimum(measurement) then
      return unavailablePlan("pokedex-registration:unavailable")
    end
    local geometry = ApplicationLayout.nativeDual(context, REGISTRATION_NATIVE, REGISTRATION_TOUCH_NATIVE)
    if geometry == nil then
      return unavailablePlan("pokedex-registration:unavailable")
    end
    return registrationPlan(
      panesFrom(geometry, { "registration", "registrationTouch" }, true),
      "pokedex-registration:paired"
    )
  end
  ---@param context table<string, unknown>
  ---@param view table<string, unknown>
  ---@return table<string, unknown> complete application plan
  local function wide(context, view)
    local measurement = assert(context.measurement, "registration plans measure their display")
    local _ = view
    if belowMinimum(measurement) then
      return unavailablePlan("pokedex-registration:unavailable")
    end
    local geometry = ApplicationLayout.sideBySide(context, REGISTRATION_NATIVE, REGISTRATION_TOUCH_NATIVE)
    if geometry == nil then
      return unavailablePlan("pokedex-registration:unavailable")
    end
    return registrationPlan(
      panesFrom(geometry, { "registration", "registrationTouch" }, true),
      "pokedex-registration:paired"
    )
  end
  ---@param context table<string, unknown>
  ---@param view table<string, unknown>
  ---@return table<string, unknown> complete application plan
  local function tall(context, view)
    local measurement = assert(context.measurement, "registration plans measure their display")
    local _ = view
    if belowMinimum(measurement) then
      return unavailablePlan("pokedex-registration:unavailable")
    end
    local geometry = ApplicationLayout.stacked(context, REGISTRATION_NATIVE, REGISTRATION_TOUCH_NATIVE)
    if geometry == nil then
      return unavailablePlan("pokedex-registration:unavailable")
    end
    return registrationPlan(
      panesFrom(geometry, { "registration", "registrationTouch" }, true),
      "pokedex-registration:paired"
    )
  end
  ---@param context table<string, unknown>
  ---@param view table<string, unknown>
  ---@return table<string, unknown> complete application plan
  local function nativeLike(context, view)
    local measurement = assert(context.measurement, "registration plans measure their display")
    local _ = view
    if belowMinimum(measurement) then
      return unavailablePlan("pokedex-registration:unavailable")
    end
    -- The compact card keeps the full 256x192 pane: the opaque cover
    -- owns the whole single display, not the browser footer split.
    local placement = {
      frame = { x = 0, y = 0, width = NATIVE_WIDTH, height = NATIVE_HEIGHT },
      origin = { x = 0, y = 0 },
      scale = 1,
      logicalWidth = NATIVE_WIDTH,
      logicalHeight = NATIVE_HEIGHT,
    }
    return registrationPlan(
      { { id = "registration", placement = placement, interactive = true } },
      "pokedex-registration:compact"
    )
  end
  local interfaces = { dualDisplay = dualDisplay, nativeLike = nativeLike, wide = wide, tall = tall }
  if overrides ~= nil then
    assert(type(overrides) == "table", "interface overrides arrive as a record")
    for key, resolver in pairs(overrides) do
      assert(
        key == "dualDisplay" or key == "nativeLike" or key == "wide" or key == "tall",
        "interface overrides replace a known case"
      )
      assert(type(resolver) == "function", "interface overrides replace whole render and input pairs")
      interfaces[key] = resolver
    end
  end
  return interfaces
end

return PokedexInterface
