-- The standalone Town map and Fly destination selector: the region map's
-- world, cursor, and selection without the gear shell, tab strip, zoom, or
-- markings. Fly confirms one visited flypoint through the source's
-- "Fly / Quit" menu and reports it by its semantic key with its operation
-- identity; the view-only Town map never settles a destination. Follows
-- the retail ROM's Fly map. World motion
-- lives in MapWorld, location and flypoint queries in MapLocations. Pure
-- module: no love, no I/O.

local MapLocations = require("game.hgss.src.pokegear.map.MapLocations")
local MapWorld = require("game.hgss.src.pokegear.map.MapWorld")
local MapProjection = require("game.hgss.src.pokegear.MapProjection")

---@class FlyMapController
---@field _mode string "townMap" or "fly"
---@field _operationId string the owning operation identity echoed in the terminal
---@field _context table<string, unknown> the source-normalized map context
---@field _destinations table<integer, string> the permitted semantic flypoint keys
---@field _assets table<string, unknown> the borrowed compiled asset family
---@field _catalog table<string, unknown> the borrowed compiled catalog
---@field _messages table<string, unknown>? text resolvers; absent views carry no text
---@field _locations MapLocations
---@field _world MapWorld
---@field _facts table<string, unknown>
---@field _region integer the player's source region
---@field _selection table<string, unknown>? the selected location
---@field _flyDestination integer? the highlighted flypoint index
---@field _menu table<string, unknown>? the open Fly/Quit menu
---@field _touch { held: boolean, x: number, y: number }
---@field _effect fun(sequence: string)? source UI sound effect boundary
---@field _touchNew boolean
---@field _patches table<integer, table<string, integer>>
---@field _terminal table<string, unknown>?
---@field _disposed boolean
local FlyMapController = {}
FlyMapController.__index = FlyMapController

-- Hit rects as {top, bottom, left, right}, half open (source IN:209-285): the
-- map opening and the Close button.
local MAP_RECT = { 16, 144, 40, 224 }
local CLOSE_RECT = { 152, 184, 194, 254 }

-- Menu geometry in tiles (source M9270:1083-1097 and touchscreen_list_menu.c):
-- the two entries sit in a three-row-pitch frame at row four.
local MENU_ITEMS = { "fly", "quit" }
local MENU_ROW = 4
local MENU_WIDTH = 4

---@param rect integer[]
---@param x number
---@param y number
---@return boolean
local function inRect(rect, x, y)
  return x >= rect[3] and x < rect[4] and y >= rect[1] and y < rect[2]
end

---@class FlyMapController.Options
---@field mode string "townMap" or "fly"
---@field operationId string
---@field context table<string, unknown>? the source-normalized map context, absent for a view-only map
---@field destinations string[]? the permitted semantic flypoint keys
---@field assets table<string, unknown> the borrowed compiled asset family
---@field facts table<string, unknown> flypointVisited(index)
---@field messages table<string, unknown>? text resolvers: region(name), landmark(entry), flavor(entry), flyPrompt(landmark), close(), menuLabel(index)
---@field effect fun(sequence: string)? source UI sound effect boundary

---@param opts FlyMapController.Options
---@return FlyMapController
function FlyMapController.new(opts)
  assert(type(opts) == "table", "the fly selector requires its options")
  assert(opts.mode == "townMap" or opts.mode == "fly", "the fly selector opens in a known mode")
  assert(
    type(opts.operationId) == "string" and opts.operationId ~= "",
    "the fly selector carries its operation identity"
  )
  assert(type(opts.assets) == "table", "the fly selector borrows its asset family")
  assert(
    type(opts.facts) == "table" and type(opts.facts.flypointVisited) == "function",
    "the fly selector reads its flags"
  )
  assert(opts.effect == nil or type(opts.effect) == "function", "the fly sound boundary must be a function")
  local catalog = opts.assets.catalog
  assert(type(catalog) == "table" and type(catalog.regionMap) == "table", "the fly selector borrows its source tables")
  local destinations = {}
  for index, key in ipairs(opts.destinations or {}) do
    assert(type(key) == "string" and key ~= "", "fly destinations name semantic flypoint keys")
    destinations[index] = key
  end
  local context = opts.context
  assert(
    context == nil
      or (
        type(context.matrixX) == "number"
        and type(context.matrixY) == "number"
        and type(context.unlockLevel) == "number"
      ),
    "the map context carries matrix facts and its progression tier"
  )
  local unlock = context ~= nil and math.max(0, math.min(2, context.unlockLevel --[[@as number]])) or 0
  -- The fly entry never knows the Sinjoh or S.S. Aqua maps, so those stay hidden.
  local locations = MapLocations.new({ regionMap = catalog.regionMap, unlock = unlock, fieldMap = "" })
  local matrix = { x = 0, y = 0 }
  if context ~= nil then
    matrix = MapProjection.contextCell({
      matrixX = context.matrixX,
      matrixY = context.matrixY,
      explicitX = context.explicitX,
      explicitY = context.explicitY,
      lastExterior = context.lastExterior,
      specialSpawn = context.specialSpawn,
      special = context.specialMode,
    })
  end
  local self = setmetatable({
    _mode = opts.mode,
    _operationId = opts.operationId,
    _context = context or {},
    _destinations = destinations,
    _assets = opts.assets,
    _catalog = catalog,
    _messages = opts.messages,
    _facts = opts.facts,
    _locations = locations,
    _region = MapLocations.regionOf(matrix.x, matrix.y),
    _world = MapWorld.new({ kind = "fly", unlock = unlock, matrix = matrix }),
    _touch = { held = false, x = 0, y = 0 },
    _effect = opts.effect,
    _touchNew = false,
    _terminal = nil,
    _disposed = false,
  }, FlyMapController)
  self._patches = locations:worldPatches(opts.facts.flypointVisited)
  self:_select()
  return self
end

---@param x integer matrix column
---@param y integer matrix row
---@return table<string, unknown>? the first visited flypoint covering a matrix cell
---@return integer? index one-based table index
function FlyMapController:_flypointAt(x, y)
  for index, flypoint in ipairs(self._locations:flypoints()) do
    if
      x >= flypoint.x
      and y >= flypoint.y
      and x < flypoint.x + flypoint.width
      and y < flypoint.y + flypoint.height
      and self._facts.flypointVisited(flypoint.flypoint) == true
    then
      return flypoint, index
    end
  end
  return nil, nil
end

-- Selects the world cell under the cursor: a flypoint highlights its
-- destination when the region test passes, any other cell selects its
-- location (source ov101_021EA8A8).
function FlyMapController:_select()
  local cell = self._world.cell
  if self._mode == "townMap" then
    self._selection = self._locations:select(cell.x, cell.y)
    return
  end
  local flypoint, index = self:_flypointAt(cell.x, cell.y - 2)
  if flypoint == nil then
    self._selection = self._locations:select(cell.x, cell.y)
    self._flyDestination = nil
    return
  end
  self._selection = self._locations:byMapId(flypoint.nameMapId)
  if self._flyDestination ~= index then
    self._flyDestination = nil
    if MapLocations.regionAllowed(flypoint.nameMapId, cell.x, cell.y - 2, self._region) then
      self._flyDestination = index
    end
  end
end

---@return table<string, unknown>? flypoint a destination the cursor confirms, by its warp map
function FlyMapController:_confirmable()
  local cell = self._world.cell
  local flypoint = self:_flypointAt(cell.x, cell.y - 2)
  if flypoint == nil then
    return nil
  end
  if not MapLocations.regionAllowed(flypoint.warpMapId, cell.x, cell.y - 2, self._region) then
    return nil
  end
  return flypoint
end

-- The semantic key of the flypoint's warp map, when the catalog names one
-- the field move permits.
---@param flypoint table<string, unknown>
---@return string? key
function FlyMapController:_keyFor(flypoint)
  for _, entry in ipairs(self._catalog.locations) do
    if type(entry) == "table" and entry.mapRef == flypoint.warpMapId and type(entry.flypoint) == "string" then
      for _, permitted in ipairs(self._destinations) do
        if permitted == entry.flypoint then
          return entry.flypoint
        end
      end
    end
  end
  return nil
end

-- The source UI tones on the fly card: opening the destination menu,
-- cancelling, and touching the map. Menu choices settle silently behind
-- the opening tone, and gated input never reaches these handlers.
local DECIDE_SOUND = "SEQ_SE_GS_GEARDECIDE"
local CANCEL_SOUND = "SEQ_SE_GS_GEARCANCEL"
local MAP_TOUCH_SOUND = "SEQ_SE_GS_GEARMAPTOUCH"

---@param self FlyMapController
---@param sequence string
local function playEffect(self, sequence)
  if self._effect ~= nil then
    self._effect(sequence)
  end
end

function FlyMapController:_openMenu()
  local flypoint = self:_confirmable()
  if flypoint == nil then
    return
  end
  local pointX = self._touch.held and self._touch.x or self._world.cursorX
  local column = math.floor((pointX - self._world.frame.centerX) / 8)
  self._menu = {
    flypoint = flypoint,
    cursor = 0,
    x = (column >= 8 and column <= 15) and 3 or 11,
  }
  playEffect(self, DECIDE_SOUND)
end

---@param choice integer zero-based menu entry
function FlyMapController:_chooseMenu(choice)
  local menu = self._menu --[[@as table<string, unknown>]]
  self._menu = nil
  if choice ~= 0 then
    return
  end
  local key = self:_keyFor(menu.flypoint --[[@as table<string, unknown>]])
  if key ~= nil then
    self._terminal = { kind = "destination", operationId = self._operationId, flypointKey = key }
  end
end

---@param event table<string, unknown>
function FlyMapController:_pointer(event)
  local touch = self._touch
  if event.type == "pointer_down" then
    touch.held, touch.x, touch.y = true, event.x, event.y
    self._touchNew = true
  elseif event.type == "pointer_move" then
    if touch.held then
      touch.x, touch.y = event.x, event.y
    end
  else
    touch.held = false
    if type(event.x) == "number" then
      touch.x, touch.y = event.x, event.y
    end
  end
end

-- Fresh touches resolve on rect-hit alone: the source MAIN_1 pixel gate
-- only trims a 1-2px chrome border inside these rects, and no
-- input-time framebuffer owner exists to sample, so the rects stay the
-- intentional approximation.
function FlyMapController:_touchDown()
  local world = self._world
  local touch = self._touch
  if self._menu ~= nil then
    local menu = self._menu --[[@as table<string, unknown>]]
    for index = 0, #MENU_ITEMS - 1 do
      local rect = {
        (MENU_ROW + 1) * 8 + 24 * index,
        (MENU_ROW + 1) * 8 + 24 * index + 16,
        (menu.x + 1) * 8,
        (menu.x + 1 + MENU_WIDTH) * 8,
      }
      if inRect(rect, touch.x, touch.y) then
        self:_chooseMenu(index)
        return
      end
    end
    -- Taps outside the menu frame settle nothing: the source list menu
    -- reports no input there, so the menu stays open for a real choice.
    return
  end
  if inRect(CLOSE_RECT, touch.x, touch.y) then
    self._terminal = { kind = "cancelled", operationId = self._operationId }
    playEffect(self, CANCEL_SOUND)
  elseif inRect(MAP_RECT, touch.x, touch.y) then
    local x, y = world:cellFromTouch(touch.x, touch.y)
    world:selectCell(x, y)
    self:_select()
    playEffect(self, MAP_TOUCH_SOUND)
    if self._mode == "fly" and self:_confirmable() ~= nil then
      self:_openMenu()
      return
    end
    world:beginDrag(touch.x, touch.y)
  end
end

-- One fixed tick: input settles at most one terminal result, an open menu
-- owns its keys, keys and new touches wait while the cursor tween or a
-- touch drag owns the world, and the world tween advances. A settled
-- selector ignores further input, so repeats never publish a second operation.
---@param events table<integer, table<string, unknown>>
function FlyMapController:updateFixed(events)
  assert(not self._disposed, "a disposed fly selector steps nothing")
  assert(type(events) == "table", "the fly selector steps an event list")
  if self._terminal ~= nil then
    return
  end
  local world = self._world
  local up, down, left, right = false, false, false, false
  self._touchNew = false
  -- The source ignores keys and new touches while the cursor tween runs
  -- and while a touch drag owns the map (fly_map.c gates keys on
  -- draggingMarking/cursorMoving and new touches while dragging; the
  -- drag and the two-tick tween each settle first), so a menu never
  -- opens and nothing cancels mid-motion. Pointer tracking still runs
  -- while gated so the drag anchor never goes stale.
  local gated = world:dragging() or world:busy()
  for _, event in ipairs(events) do
    if self._terminal ~= nil then
      return
    end
    local kind = event.type
    if kind == "pointer_down" or kind == "pointer_move" or kind == "pointer_up" or kind == "pointer_cancel" then
      self:_pointer(event)
    elseif gated then
      -- ignored until the tween or drag settles
    elseif kind == "cancel" then
      if self._menu ~= nil then
        self._menu = nil
        playEffect(self, CANCEL_SOUND)
      else
        self._terminal = { kind = "cancelled", operationId = self._operationId }
        playEffect(self, CANCEL_SOUND)
        return
      end
    elseif kind == "confirm" then
      if self._menu ~= nil then
        self:_chooseMenu((self._menu --[[@as table<string, unknown>]]).cursor --[[@as integer]])
      elseif self._mode == "fly" then
        self:_openMenu()
      end
    elseif kind == "navigate" then
      local direction = event.direction
      if self._menu ~= nil then
        local menu = self._menu --[[@as table<string, unknown>]]
        if direction == "up" or direction == "down" then
          menu.cursor = (menu.cursor + (direction == "down" and 1 or #MENU_ITEMS - 1)) % #MENU_ITEMS
        end
      else
        up = up or direction == "up"
        down = down or direction == "down"
        left = left or direction == "left"
        right = right or direction == "right"
      end
    end
  end
  if self._terminal ~= nil then
    return
  end
  if world:dragging() then
    world:stepDrag(self._touch.held, self._touch.x, self._touch.y)
    world:tick()
    return
  end
  if world:busy() then
    world:tick()
    return
  end
  if self._touchNew then
    self:_touchDown()
  end
  if world:dragging() then
    world:stepDrag(self._touch.held, self._touch.x, self._touch.y)
  end
  if self._menu == nil and (up or down or left or right) and not world:busy() then
    local moved = world:moveSelection(up, down, left, right)
    if moved ~= nil then
      world:beginMove(moved)
      self:_select()
    end
  end
  world:tick()
end

-- Reads back the one terminal result, or nil while the selection is live.
-- The result stays readable until the owner disposes the selector.
---@return table<string, unknown>?
function FlyMapController:takeResult()
  return self._terminal
end

-- The highlight tile copies of the selected location's map (Town map only).
---@return table<integer, table<string, integer>>
function FlyMapController:_highlight()
  local highlight = {}
  local selection = self._selection
  if selection == nil or self._mode ~= "townMap" then
    return highlight
  end
  for _, location in ipairs(self._locations:all()) do
    if location.mapId == selection.mapId then
      local overlay = location.overlay
      if overlay.width * overlay.height > 0 then
        local destX, destY = location.x, location.y
        if overlay.width * overlay.height >= 9 then
          destX, destY = destX - 1, destY - 1
        end
        highlight[#highlight + 1] = {
          srcX = overlay.srcX,
          srcY = overlay.srcY,
          destX = destX,
          destY = destY,
          width = overlay.width,
          height = overlay.height,
        }
      end
    end
  end
  return highlight
end

-- The visited flypoints as screen-space indicators: the rectangle centre of
-- each, with the source availability and selection state.
---@return table<integer, table<string, unknown>>
function FlyMapController:_indicators()
  local indicators = {}
  if self._mode ~= "fly" then
    return indicators
  end
  local world = self._world
  for index, flypoint in ipairs(self._locations:flypoints()) do
    if self._facts.flypointVisited(flypoint.flypoint) == true then
      local x, y = world:screenOf(8 * flypoint.x + flypoint.width * 4, 8 * (flypoint.y + 2) + flypoint.height * 4)
      local state = "unavailable"
      if self._flyDestination == index then
        state = "selected"
      elseif MapLocations.regionAllowed(flypoint.warpMapId, flypoint.x, flypoint.y, self._region) then
        state = "available"
      end
      indicators[#indicators + 1] = { x = x, y = y, state = state }
    end
  end
  return indicators
end

---@return table<string, unknown> the information panel
function FlyMapController:_panel()
  local world = self._world
  local selection = self._selection
  local messages = self._messages
  local panel = { markers = {}, words = {}, previewFrame = false }
  if messages ~= nil then
    panel.region = messages.region(MapLocations.regionName(world.cell.x, world.cell.y))
    if selection ~= nil then
      panel.landmark = messages.landmark(selection.sectionEntry)
      if self._mode == "fly" then
        panel.flavor = messages.flavor(selection.flavorEntry)
      end
    end
  end
  if selection ~= nil and self._mode == "fly" then
    panel.previewFrame = selection.previewBlock ~= 0
    panel.previewBlock = selection.previewBlock ~= 0 and selection.previewBlock - 1 or 0
    -- The source info pane shares the gear card's marking and rematch
    -- icon: the readers are optional, so entries without panel owners
    -- keep the previous bare panel.
    local rematchOnMap = self._facts.rematchOnMap
    if type(rematchOnMap) == "function" then
      panel.battleIcon = rematchOnMap(selection.mapId) == true
    end
    local markingFor = self._facts.markingFor
    if type(markingFor) == "function" and messages ~= nil then
      local saved = markingFor(selection.mapSymbol)
      if type(saved) == "table" and type(saved.icons) == "table" and type(saved.words) == "table" then
        for index = 1, 4 do
          panel.markers[index] = saved.icons[index] ~= false and saved.icons[index] or nil
          panel.words[index] = saved.words[index] ~= false and messages.word(saved.words[index]) or nil
        end
      end
    end
  end
  return panel
end

---@return table<string, unknown> the presentation snapshot
function FlyMapController:status()
  local world = self._world
  local menu = self._menu
  local messages = self._messages
  local prompt, closeLabel, menuLabels = nil, nil, nil
  if messages ~= nil then
    closeLabel = messages.close()
  end
  if self._mode == "fly" and messages ~= nil then
    local landmark = nil
    if menu ~= nil and self._selection ~= nil then
      landmark = messages.landmark(self._selection.sectionEntry)
    end
    prompt = messages.flyPrompt(landmark)
    menuLabels = { messages.menuLabel(0), messages.menuLabel(1) }
  end
  local view = {
    kind = self._mode,
    world = {
      ratio = world.ratio,
      scrollX = world.scrollX,
      scrollY = world.scrollY,
      affineX = world.affineX,
      affineY = world.affineY,
      xOffset = world.frame.xOffset,
    },
    patches = self._patches,
    highlight = self:_highlight(),
    cursor = { x = world.cursorX, y = world.cursorY, scale = 1 },
    player = {
      x = select(1, world:cellCentre(world.player.x, world.player.y)),
      y = select(2, world:cellCentre(world.player.x, world.player.y)),
      frame = self._context.playerGender == "female" and 2 or 1,
    },
    indicators = self:_indicators(),
    panel = self:_panel(),
    prompt = prompt,
    closeLabel = closeLabel,
    menu = menu ~= nil and { x = menu.x, cursor = menu.cursor, width = MENU_WIDTH, labels = menuLabels } or nil,
    closePressed = false,
  }
  local Renderer = require("libs.hgss.src.presentation.PokegearFlyMapRenderer")
  local fly = self._assets.fly
  local content = nil
  if type(fly) == "table" then
    local text = fly.textPalette
    local function pair(colors, foreground, shadow)
      return {
        foreground = assert(colors[foreground + 1], "the fly text palette carries its colors"),
        shadow = assert(colors[shadow + 1], "the fly text palette carries its colors"),
        background = { r = 0, g = 0, b = 0, a = 0 },
      }
    end
    content = {
      world = fly.world and fly.world.image,
      foreground = fly.foreground and fly.foreground.image,
      top = fly.top and fly.top.image,
      upper = fly.upper and fly.upper.image,
      previews = fly.previews and fly.previews.image,
      menuTiles = fly.menuTiles and fly.menuTiles.image,
      sprites = self._assets.map and self._assets.map.sprites,
      patches = self._patches,
      textColors = text and {
        upper = pair(text.upper, 1, 2),
        upperWord = pair(text.upper, 3, 4),
        prompt = pair(text.lower, 3, 2),
        close = pair(text.lower, 3, 1),
        menu = fly.menuPalette,
      } or nil,
    }
  end
  return {
    open = true,
    mode = self._mode,
    busy = false,
    dismissible = true,
    view = view,
    presentation = {
      content = content,
      render = Renderer.render,
      renderInformation = Renderer.renderInformation,
    },
  }
end

-- Idempotent release of the logical lifetime: the selector owns only its
-- terminal choice.
function FlyMapController:dispose()
  self._disposed = true
end

return FlyMapController
