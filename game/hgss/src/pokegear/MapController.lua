-- The gear region-map card: map mode with the source's scrolling, zoom,
-- touch drag, location selection and information panel, and the marking
-- mode with its timed fade and panel slides. Follows the retail ROM's Pokegear map
-- application. World
-- motion lives in MapWorld, location queries in MapLocations, and the
-- slot editor in MarkingMode; this controller sequences them, persists
-- committed markings, and publishes the detached view the renderer draws.
-- Live roamer and contact inputs are sampled once at creation. Pure
-- module: no love, no I/O.

local Errors = require("libs.errors.src.Errors")
local MapLocations = require("game.hgss.src.pokegear.map.MapLocations")
local MapProjection = require("game.hgss.src.pokegear.MapProjection")
local MapWorld = require("game.hgss.src.pokegear.map.MapWorld")
local MarkingMode = require("game.hgss.src.pokegear.map.MarkingMode")
local ScriptErrors = require("libs.script.src.errors")

---@class MapController
---@field _state table<string, unknown> the borrowed durable companion owner
---@field _assets table<string, unknown> the borrowed compiled asset family
---@field _catalog table<string, unknown> the borrowed compiled catalog
---@field _context table<string, unknown> the source-normalized map context
---@field _messages table<string, unknown> resolves region, landmark, flavor, and word text
---@field _facts table<string, unknown> flypoint flags and contact facts
---@field _locations MapLocations
---@field _world MapWorld
---@field _selection table<string, unknown>? the selected location
---@field _mode string "map" or "marking"
---@field _marking MarkingMode? the open marking editor
---@field _session MapWorld.Snapshot? the world saved while marking
---@field _transition table<string, unknown>? the running mode transition
---@field _touch { held: boolean, x: number, y: number }
---@field _markingsPressed boolean
---@field _wordEntry table<string, unknown>
---@field _wordOutbox table<string, unknown>?
---@field _wordPending table<string, unknown>?
---@field _consumed table<string, boolean>
---@field _operations integer
---@field _unlock integer
---@field _rematch table<integer, boolean> rematch and gift facts sampled per map
---@field _phoneProjection fun(location: string): table<integer, table<string, unknown>>
---@field _effect fun(sequence: string)? source UI sound effect boundary
---@field _touchNew boolean
---@field _patches table<integer, table<string, integer>>
---@field _roamers table<integer, table<string, unknown>>
---@field _ticks integer
---@field _disposed boolean
local MapController = {}
MapController.__index = MapController

-- Hit rects as {top, bottom, left, right}, half open (source
-- ov101_021EBA44): the two buttons beside the map and the map opening.
local MARKINGS_RECT = { 16, 64, 216, 248 }
local ZOOM_RECT = { 88, 152, 216, 248 }
local MAP_RECT = { 8, 152, 8, 200 }

-- Mode transition lengths in ticks (source substates; the brightness fade
-- runs six steps of one tick).
local FADE_TICKS = 6
local PANEL_STEPS = 4
local TOP_STEP = 32
local BOTTOM_STEP = 28
local BOTTOM_OFFSET = 112
local TOP_OFFSET = 128

-- Source roamer slots by species key (Raikou, Entei, Latias, Latios).
local ROAMER_SPECIES = { RAIKOU = 0, ENTEI = 1, LATIAS = 2, LATIOS = 3 }

---@param rect integer[]
---@param x number
---@param y number
---@return boolean
local function inRect(rect, x, y)
  return x >= rect[3] and x < rect[4] and y >= rect[1] and y < rect[2]
end

---@param value number
---@param low number
---@param high number
---@return number
local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

---@class MapController.Options
---@field state table<string, unknown> the durable companion owner
---@field assets table<string, unknown> the borrowed compiled asset family
---@field mapContext table<string, unknown> the source-normalized map context
---@field messages table<string, unknown> text resolvers: region(name), landmark(mapId), flavor(entry), word(key)
---@field facts table<string, unknown> flypointVisited(index) and the contact facts
---@field phoneProjection fun(location: string): table<integer, table<string, unknown>> the shared contact availability query
---@field roamerProjection table<integer, table<string, unknown>> the creation-time roamer snapshot
---@field wordEntry table<string, unknown> the narrow word-selector handoff
---@field switched boolean? true when the card opens from another tab
---@field effect fun(sequence: string)? source UI sound effect boundary

---@param opts MapController.Options
---@return MapController
function MapController.new(opts)
  assert(type(opts) == "table", "the region map requires its options")
  assert(
    type(opts.state) == "table"
      and type(opts.state.capture) == "function"
      and type(opts.state.setMarking) == "function"
      and type(opts.state.setPreference) == "function"
      and type(opts.state.readPreferences) == "function",
    "the region map requires the durable companion owner"
  )
  assert(type(opts.assets) == "table", "the region map requires its compiled asset family")
  local context = assert(opts.mapContext, "the region map requires its normalized map context")
  assert(
    type(context.fieldMap) == "string"
      and type(context.matrixX) == "number"
      and type(context.matrixY) == "number"
      and type(context.unlockLevel) == "number"
      and type(context.playerGender) == "string",
    "the region map context carries field, matrix, tier, and gender facts"
  )
  assert(type(opts.messages) == "table", "the region map resolves its text through the message resolvers")
  assert(
    type(opts.facts) == "table" and type(opts.facts.flypointVisited) == "function",
    "the region map reads its flags"
  )
  assert(type(opts.phoneProjection) == "function", "the region map reads contacts through the shared phone query")
  assert(type(opts.roamerProjection) == "table", "the region map samples roamers once at creation")
  local wordEntry = opts.wordEntry
  assert(type(wordEntry) == "table", "the region map requires its word-entry handoff")
  for _, method in ipairs({ "open", "step", "result", "cancel" }) do
    assert(type(wordEntry[method]) == "function", "the word-entry handoff needs " .. method)
  end
  assert(opts.effect == nil or type(opts.effect) == "function", "the region map sound boundary must be a function")
  local catalog = opts.assets.catalog
  assert(type(catalog) == "table" and type(catalog.regionMap) == "table", "the region map borrows its source tables")
  local unlock = math.floor(clamp(context.unlockLevel, 0, 2))
  local locations = MapLocations.new({ regionMap = catalog.regionMap, unlock = unlock, fieldMap = context.fieldMap })
  local self = setmetatable({
    _state = opts.state,
    _assets = opts.assets,
    _catalog = catalog,
    _context = context,
    _messages = opts.messages,
    _facts = opts.facts,
    _phoneProjection = opts.phoneProjection,
    _locations = locations,
    _mode = "map",
    _touch = { held = false, x = 0, y = 0 },
    _markingsPressed = false,
    _wordEntry = wordEntry,
    _effect = opts.effect,
    _consumed = {},
    _operations = 0,
    _ticks = 0,
    _disposed = false,
    _unlock = unlock,
    _rematch = {},
  }, MapController)
  local cell = self:_playerCell()
  local preferences = opts.state:readPreferences()
  assert(type(preferences) == "table", "the region map reads its saved preferences")
  self._world = MapWorld.new({
    kind = "gear",
    unlock = unlock,
    matrix = cell,
    zoomed = preferences.mapZoomed == true,
  })
  self._roamers = self:_sampleRoamers(opts.roamerProjection)
  self._patches = locations:worldPatches(opts.facts.flypointVisited)
  self._selection = locations:select(self._world.cell.x, self._world.cell.y)
  if opts.switched == true then
    self._transition = { kind = "arrive", t = 0 }
  end
  return self
end

---@return { x: integer, y: integer } the player matrix cell, without the source row offset
function MapController:_playerCell()
  local context = self._context
  local record = nil
  for _, entry in ipairs(self._catalog.locations) do
    if type(entry) == "table" and (entry.fieldMap == context.fieldMap or entry.location == context.fieldMap) then
      record = entry
      break
    end
  end
  if record == nil then
    Errors.raise(
      ScriptErrors.FEATURE_UNAVAILABLE,
      "the region map has no source location for " .. context.fieldMap,
      { map = context.fieldMap }
    )
  end
  assert(type(record) == "table", "the region map resolves its compiled location")
  local explicitX, explicitY = context.explicitX, context.explicitY
  if explicitX == nil and explicitY == nil then
    explicitX, explicitY = record.explicitX, record.explicitY
  end
  local special = context.specialMode
  if special == nil and type(record.special) == "string" then
    special = record.special
  end
  if explicitX == 0 and explicitY == 0 and context.lastExterior == nil and context.specialSpawn == nil then
    Errors.raise(
      ScriptErrors.FEATURE_UNAVAILABLE,
      "the region map has no proven exterior position for " .. context.fieldMap,
      { map = context.fieldMap }
    )
  end
  return MapProjection.contextCell({
    matrixX = context.matrixX,
    matrixY = context.matrixY,
    explicitX = explicitX,
    explicitY = explicitY,
    lastExterior = context.lastExterior,
    specialSpawn = context.specialSpawn,
    special = special,
  })
end

-- Keeps the roamers that are roaming and sit on a visible location, with the
-- source roamer slot of their species.
---@param projection table<integer, table<string, unknown>>
---@return table<integer, table<string, unknown>>
function MapController:_sampleRoamers(projection)
  local roamers = {}
  for _, roamer in ipairs(projection) do
    assert(type(roamer) == "table", "the roamer snapshot carries records")
    local slot = ROAMER_SPECIES[
      roamer.species --[[@as integer]]
    ]
    if roamer.lifecycle == "roaming" and slot ~= nil then
      local mapId = nil
      for _, entry in ipairs(self._catalog.locations) do
        if type(entry) == "table" and (entry.key == roamer.location or entry.mapRef == roamer.location) then
          mapId = entry.mapRef
          break
        end
      end
      local location = mapId ~= nil and self._locations:byMapId(mapId) or nil
      if location ~= nil then
        roamers[#roamers + 1] = { slot = slot, location = location }
      end
    end
  end
  table.sort(roamers, function(a, b)
    return a.slot < b.slot
  end)
  return roamers
end

---@return boolean true when the selected location may open markings
function MapController:_mayMark()
  local selection = self._selection
  return selection ~= nil
    and selection.mapSymbol ~= "MAP_SINJOH_RUINS_EXTERIOR"
    and selection.mapSymbol ~= "MAP_SS_AQUA_1F"
end

---@param symbol string
---@return MarkingMode.Marking? the saved marking
function MapController:_savedMarking(symbol)
  local bucket = self._state:capture()
  assert(type(bucket) == "table" and type(bucket.markings) == "table", "the region map reads its markings")
  local stored = bucket.markings[symbol]
  if type(stored) ~= "table" then
    return nil
  end
  return stored --[[@as MarkingMode.Marking]]
end

-- Commits one marking mutation, removing emptied records.
---@param symbol string
---@param marking MarkingMode.Marking
function MapController:_commitMarking(symbol, marking)
  local empty = true
  for index = 1, 4 do
    if marking.icons[index] ~= false or marking.words[index] ~= false then
      empty = false
      break
    end
  end
  self._state:setMarking(symbol, (not empty) and marking or nil)
end

---@param mapId integer
---@return boolean whether a contact on that map has a rematch or a gift waiting
function MapController:_hasRematchOrGift(mapId)
  local known = self._rematch[mapId]
  if known ~= nil then
    return known
  end
  known = self:_findRematchOrGift(mapId)
  self._rematch[mapId] = known
  return known
end

---@param mapId integer
---@return boolean
function MapController:_findRematchOrGift(mapId)
  for _, entry in ipairs(self._catalog.locations) do
    if type(entry) == "table" and entry.mapRef == mapId and type(entry.key) == "string" then
      local ok, found = pcall(self._phoneProjection, entry.key)
      assert(ok, "contact markers follow the shared phone query")
      if type(found) == "table" then
        for _, marker in ipairs(found) do
          if marker.ready == true or marker.gift ~= nil then
            return true
          end
        end
      end
    end
  end
  return false
end

-- The source UI tones on the gear map card: opening the editor,
-- touching the map, zooming with its directional tones, and the mode
-- change. B in map mode belongs to the shell's app-switch zone, and Y
-- tab switches belong to the shell chrome, so neither plays here.
local DECIDE_SOUND = "SEQ_SE_GS_GEARDECIDE"
local CURSOR_SOUND = "SEQ_SE_GS_GEARCURSOR"
local MAP_TOUCH_SOUND = "SEQ_SE_GS_GEARMAPTOUCH"
local ZOOM_SOUND = "SEQ_SE_GS_GEARXBUTTON"
local UNZOOM_SOUND = "SEQ_SE_GS_XBUTTON_SYUKUSHOU"

---@param self MapController
---@param sequence string
local function playEffect(self, sequence)
  if self._effect ~= nil then
    self._effect(sequence)
  end
end

function MapController:_beginMarking()
  if not self:_mayMark() or self._world:busy() then
    return
  end
  self._markingsPressed = true
  self._session = self._world:snapshot()
  self._transition = { kind = "enter", t = 0 }
  playEffect(self, DECIDE_SOUND)
end

function MapController:_toggleZoom()
  if self._world:busy() then
    return
  end
  self._world:toggleZoom()
  self._state:setPreference("mapZoomed", self._world.zoomed)
  if self._world.zoomed then
    playEffect(self, ZOOM_SOUND)
  else
    playEffect(self, UNZOOM_SOUND)
  end
end

---@param event table<string, unknown>
function MapController:_pointer(event)
  local touch = self._touch
  if event.type == "pointer_down" then
    touch.held, touch.x, touch.y = true, event.x, event.y
    self._touchNew = true
  elseif event.type == "pointer_move" then
    if touch.held then
      touch.x, touch.y = event.x, event.y
    end
  elseif event.type == "pointer_up" or event.type == "pointer_cancel" then
    touch.held = false
    if type(event.x) == "number" then
      touch.x, touch.y = event.x, event.y
    end
  end
end

-- A fresh touch: the markings or zoom button, or a map selection that
-- begins a drag (source ov101_021EBA44). The source refines rect hits
-- with a MAIN_1 framebuffer pixel check; the rects already bound the
-- openings to a 1-2px border, and no input-time framebuffer owner exists
-- to sample, so rect-hit stays the intentional approximation.
function MapController:_touchDown()
  local world = self._world
  local touch = self._touch
  if world:zooming() then
    return
  end
  if inRect(MARKINGS_RECT, touch.x, touch.y) then
    world:placeCursor()
    self:_beginMarking()
  elseif inRect(ZOOM_RECT, touch.x, touch.y) then
    world:placeCursor()
    self:_toggleZoom()
  elseif inRect(MAP_RECT, touch.x, touch.y) then
    local x, y = world:cellFromTouch(touch.x, touch.y)
    world:selectCell(x, y)
    self._selection = self._locations:select(x, y)
    world:beginDrag(touch.x, touch.y)
    playEffect(self, MAP_TOUCH_SOUND)
  end
end

-- Mode transition keyframes: the lower-screen fade, the upper panel slide
-- offset, and the lower panel slide offset at a transition tick.
---@param transition table<string, unknown>
---@return table<string, unknown> frame
local function transitionFrame(transition)
  local t = transition.t --[[@as integer]]
  local kind = transition.kind
  if kind == "arrive" then
    return {
      content = "map",
      fade = 0,
      top = clamp(TOP_OFFSET - TOP_STEP * t, 0, TOP_OFFSET),
      bottom = 0,
      done = t >= PANEL_STEPS,
    }
  elseif kind == "enter" then
    if t <= 1 + FADE_TICKS then
      return {
        content = "map",
        fade = clamp((t - 1) / FADE_TICKS, 0, 1),
        top = TOP_STEP * clamp(t - 1, 0, PANEL_STEPS),
        bottom = 0,
      }
    end
    local base = 1 + FADE_TICKS + 1
    if t <= base + FADE_TICKS then
      return {
        content = "marking",
        fade = clamp(1 - (t - base) / FADE_TICKS, 0, 1),
        top = TOP_OFFSET,
        bottom = BOTTOM_OFFSET,
      }
    end
    local slideStart = base + FADE_TICKS + 1
    local step = clamp(t - slideStart, 0, PANEL_STEPS)
    return {
      content = "marking",
      fade = 0,
      top = TOP_OFFSET,
      bottom = BOTTOM_OFFSET - BOTTOM_STEP * step,
      done = t >= slideStart + PANEL_STEPS,
    }
  end
  -- exit
  if t <= PANEL_STEPS then
    return { content = "marking", fade = 0, top = TOP_OFFSET, bottom = BOTTOM_STEP * t }
  end
  if t <= PANEL_STEPS + FADE_TICKS then
    return {
      content = "marking",
      fade = clamp((t - PANEL_STEPS) / FADE_TICKS, 0, 1),
      top = TOP_OFFSET,
      bottom = BOTTOM_OFFSET,
    }
  end
  local base = PANEL_STEPS + FADE_TICKS + 1
  local step = clamp(t - base, 0, PANEL_STEPS)
  return {
    content = "map",
    fade = clamp(1 - (t - base) / FADE_TICKS, 0, 1),
    top = TOP_OFFSET - TOP_STEP * step,
    bottom = 0,
    done = t >= base + FADE_TICKS,
  }
end

function MapController:_advanceTransition()
  local transition = self._transition --[[@as table<string, unknown>]]
  transition.t = transition.t + 1
  local frame = transitionFrame(transition)
  if transition.kind == "enter" and frame.content == "marking" and self._marking == nil then
    self._marking = MarkingMode.new({
      marking = self:_savedMarking(self._selection.mapSymbol --[[@as string]]),
      wordSlot = transition.wordSlot,
      effect = self._effect,
    })
    self._mode = "marking"
    playEffect(self, CURSOR_SOUND)
  elseif transition.kind == "exit" and frame.content == "map" and self._mode == "marking" then
    self._mode = "map"
    self._marking = nil
    self._markingsPressed = false
    if self._session ~= nil then
      self._world:restore(self._session)
      self._session = nil
    end
    playEffect(self, CURSOR_SOUND)
  end
  if frame.done == true then
    self._transition = nil
  end
end

---@param result string
---@param slot integer?
function MapController:_markingResult(result, slot)
  if result == "exit" then
    self._transition = { kind = "exit", t = 0 }
  elseif result == "word" then
    self:_requestWord(slot --[[@as integer]])
  end
end

-- Pends one typed word request for the open location; the external selector
-- answers through acceptWordResult and the card returns to marking mode.
---@param slot integer zero-based word slot
function MapController:_requestWord(slot)
  if self._wordPending ~= nil then
    return
  end
  self._operations = self._operations + 1
  local request = {
    mapSymbol = (self._selection --[[@as table<string, unknown>]]).mapSymbol,
    slot = slot + 1,
    oldWord = false,
    operationId = "map-word-" .. tostring(self._operations),
    session = self._world:snapshot(),
  }
  self._wordPending = request
  self._wordOutbox = request
end

-- Takes the pending word request for the external selector, exactly once.
---@return table<string, unknown>? the typed request, or nil when no edit is pending
function MapController:takeWordRequest()
  local request = self._wordOutbox
  self._wordOutbox = nil
  return request
end

-- Applies the external selector result to its edit: a selected word writes
-- once, a cancellation keeps the old word, and either way the card returns to
-- its marking mode. Unknown or consumed operation identities fail without
-- touching the markings.
---@param answer { operationId: string, result: table<string, unknown> }
function MapController:acceptWordResult(answer)
  assert(type(answer) == "table" and type(answer.operationId) == "string", "word answers name their operation")
  assert(type(answer.result) == "table", "word answers carry the selector result")
  if self._consumed[answer.operationId] == true then
    error("a replayed word result edits nothing: " .. answer.operationId, 0)
  end
  local pending = self._wordPending
  if pending == nil or pending.operationId ~= answer.operationId then
    error("a stale word result edits nothing: " .. tostring(answer.operationId), 0)
  end
  local result = answer.result
  if result.cancelled ~= true then
    assert(
      type(result.word) == "string" and result.word:match("^[0-9]+$") ~= nil,
      "selected words carry decimal identities"
    )
    local marking = self._marking --[[@as MarkingMode]]
    marking:applyWord(pending.slot - 1, result.word --[[@as string]])
    marking:takeEdited()
    self:_commitMarking(pending.mapSymbol, marking:marking())
  end
  self._wordPending, self._wordOutbox = nil, nil
  self._consumed[answer.operationId] = true
end

-- One fixed tick: a running transition gates input, marking mode consumes
-- its events, and map mode routes keys, buttons, and touch to the world.
---@param events table<integer, table<string, unknown>>
function MapController:updateFixed(events)
  assert(not self._disposed, "a disposed region map steps nothing")
  assert(type(events) == "table", "the region map input must be an event list")
  self._ticks = self._ticks + 1
  if self._transition ~= nil then
    self:_advanceTransition()
    return
  end
  if self._wordPending ~= nil then
    for _, event in ipairs(events) do
      if event.type == "cancel" then
        self._wordPending, self._wordOutbox = nil, nil
      end
    end
    return
  end
  if self._mode == "marking" then
    local marking = self._marking --[[@as MarkingMode]]
    local result, slot = marking:updateFixed(events)
    if marking:takeEdited() then
      self:_commitMarking(
        (self._selection --[[@as table<string, unknown>]]).mapSymbol --[[@as string]],
        marking:marking()
      )
    end
    if result ~= nil then
      self:_markingResult(result, slot)
    end
    return
  end
  local up, down, left, right, confirm, zoom = false, false, false, false, false, false
  self._touchNew = false
  for _, event in ipairs(events) do
    local kind = event.type
    if kind == "navigate" then
      local direction = event.direction
      up = up or direction == "up"
      down = down or direction == "down"
      left = left or direction == "left"
      right = right or direction == "right"
    elseif kind == "confirm" then
      confirm = true
    elseif kind == "menu" then
      zoom = true
    elseif kind == "pointer_down" or kind == "pointer_move" or kind == "pointer_up" or kind == "pointer_cancel" then
      self:_pointer(event)
    end
  end
  local world = self._world
  if zoom then
    self:_toggleZoom()
  end
  if confirm then
    self:_beginMarking()
    if self._transition ~= nil then
      return
    end
  end
  -- A fresh touch waits while the cursor or zoom tween runs: the source
  -- ignores new touches until the tween settles.
  if self._touchNew and not world:busy() then
    self:_touchDown()
    if self._transition ~= nil then
      return
    end
  end
  if world:dragging() then
    world:stepDrag(self._touch.held, self._touch.x, self._touch.y)
  end
  if (up or down or left or right) and not world:busy() then
    local moved = world:moveSelection(up, down, left, right)
    if moved ~= nil then
      world:beginMove(moved)
      self._selection = self._locations:select(world.cell.x, world.cell.y)
    end
  end
  world:tick()
end

---@return integer skin the saved skin
function MapController:_skin()
  local preferences = self._state:readPreferences()
  local skin = type(preferences) == "table" and preferences.skin or 0
  return type(skin) == "number" and math.floor(skin) or 0
end

-- The world-attached sprites at their screen positions: the cursor, the
-- player, the roamers, and a dot on every location with a marking.
---@return table<string, unknown>
function MapController:_sprites()
  local world = self._world
  local scale = world.ratio
  local sprites = { hasMarkings = {}, roamers = {} }
  local gender = self._context.playerGender
  local px, py = world:cellCentre(world.player.x, world.player.y)
  sprites.player = { x = px, y = py, frame = gender == "female" and 2 or 1 }
  sprites.cursor = { x = world.cursorX, y = world.cursorY, scale = scale }
  for _, roamer in ipairs(self._roamers) do
    local location = roamer.location
    local x, y = world:cellCentre(location.x, location.y, location.objXOffset, location.objYOffset)
    sprites.roamers[#sprites.roamers + 1] = { x = x, y = y, frame = roamer.slot + 1 }
  end
  local bucket = self._state:capture()
  local markings = type(bucket) == "table" and bucket.markings or {}
  for _, location in ipairs(self._locations:all()) do
    if markings[location.mapSymbol] ~= nil then
      local x, y = world:cellCentre(location.x, location.y, location.objXOffset, location.objYOffset)
      sprites.hasMarkings[#sprites.hasMarkings + 1] = { x = x, y = y }
    end
  end
  return sprites
end

-- The highlight tile copies for every location sharing the selected map.
---@return table<integer, table<string, integer>>
function MapController:_highlight()
  local highlight = {}
  local selection = self._selection
  if selection == nil or self._mode ~= "map" then
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

-- The information panel for the selection: region, landmark, flavor text,
-- preview block, the rematch icon, and the saved marking.
---@return table<string, unknown>
function MapController:_panel()
  local world = self._world
  local selection = self._selection
  local key = table.concat({
    selection ~= nil and selection.mapSymbol or "-",
    MapLocations.regionName(world.cell.x, world.cell.y),
    tostring(self._state:revision()),
  }, "|")
  if self._panelCache ~= nil and self._panelCache.key == key then
    return self._panelCache.panel
  end
  local messages = self._messages
  local panel = {
    region = messages.region(MapLocations.regionName(world.cell.x, world.cell.y)),
    markers = {},
    words = {},
    previewFrame = false,
  }
  if selection ~= nil then
    panel.landmark = messages.landmark(selection.sectionEntry)
    panel.flavor = messages.flavor(selection.flavorEntry)
    panel.previewFrame = selection.previewBlock ~= 0
    panel.previewBlock = selection.previewBlock ~= 0 and selection.previewBlock - 1 or 0
    panel.battleIcon = self:_hasRematchOrGift(selection.mapId)
    local saved = self:_savedMarking(selection.mapSymbol)
    if saved ~= nil then
      for index = 1, 4 do
        panel.markers[index] = saved.icons[index] ~= false and saved.icons[index] or nil
        panel.words[index] = saved.words[index] ~= false and messages.word(saved.words[index]) or nil
      end
    end
  end
  self._panelCache = { key = key, panel = panel }
  return panel
end

-- The resolved image paths behind the saved skin, plus the sprite sets.
---@return table<string, unknown>
function MapController:_planContent()
  local skin = self:_skin()
  local map = assert(self._assets.map, "the region map borrows its visuals")
  local function path(section)
    local node = section
    if type(node) ~= "table" then
      return nil
    end
    local entry = node[skin]
    return type(entry) == "table" and entry.image or nil
  end
  local function pair(colors, foreground, shadow)
    return {
      foreground = assert(colors[foreground + 1], "the map text palette carries its colors"),
      shadow = assert(colors[shadow + 1], "the map text palette carries its colors"),
      -- Palette index zero is the transparent key of the window bitmap.
      background = { r = 0, g = 0, b = 0, a = 0 },
    }
  end
  local text = assert(map.textPalette[skin], "the map carries its skin text palette")
  return {
    skin = skin,
    textColors = {
      upper = pair(text.upper, 1, 2),
      upperWord = pair(text.upper, 3, 4),
      lower = pair(text.lower, 1, 2),
      word = pair(map.wordPalette, 3, 4),
    },
    foreground = path(map.foreground),
    world = path(map.world),
    markingPanel = path(map.markingPanel),
    markingBackdrop = path(map.markingBackdrop),
    upper = path(map.upper),
    previews = path(map.previews),
    sprites = map.sprites,
    patches = self._patches,
  }
end

---@return table<string, unknown> the presentation snapshot the shell routes on
function MapController:status()
  local world = self._world
  local frame = self._transition ~= nil and transitionFrame(self._transition) or nil
  local mode = frame ~= nil and frame.content or self._mode
  local view = {
    mode = mode,
    cell = { x = world.cell.x, y = world.cell.y },
    playerCell = { x = world.player.x, y = world.player.y },
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
    sprites = self:_sprites(),
    buttons = {
      markings = self._markingsPressed and "pressed" or (self:_mayMark() and "normal" or "disabled"),
      zoom = world.zoomed and "zoomed" or "unzoomed",
    },
    panel = self:_panel(),
    topSlide = frame ~= nil and frame.top or 0,
    bottomSlide = frame ~= nil and frame.bottom or 0,
    fade = frame ~= nil and frame.fade or 0,
  }
  if mode == "marking" and self._marking ~= nil then
    local marking = self._marking:view()
    marking.landmark = self._selection ~= nil and self._messages.landmark(self._selection.sectionEntry) or nil
    for _, slot in ipairs(marking.slots) do
      if slot.kind == "word" and slot.word ~= false then
        slot.text = self._messages.word(slot.word)
      end
    end
    view.marking = marking
  end
  local presentation = {
    content = self:_planContent(),
  }
  local Renderer = require("libs.hgss.src.presentation.PokegearMapRenderer")
  presentation.render = Renderer.render
  presentation.renderInformation = Renderer.renderInformation
  return {
    open = true,
    tab = "map",
    busy = self._wordPending ~= nil or self._transition ~= nil,
    dismissible = self._transition == nil,
    nestedCancel = mode == "marking" or self._wordPending ~= nil or self._transition ~= nil,
    stripHidden = mode == "marking",
    view = view,
    presentation = presentation,
  }
end

-- The region map never closes itself: the shell owns dismissal.
---@return nil
function MapController:takeResult()
  return nil
end

-- Idempotent release of the logical lifetime. Committed markings already
-- live in the borrowed state owner.
function MapController:dispose()
  self._wordOutbox, self._wordPending = nil, nil
  self._transition = nil
  self._disposed = true
end

return MapController
