-- Region map annotation slots: icon drag operations keep source slot order,
-- capacity, and cleanup while word edits round-trip through the typed
-- selector handoff with session restore. A cancelled drag never publishes,
-- a successful swap or delete writes exactly once, blank records leave no
-- residue, the hundredth location fills the collection while the next one
-- fails, and markings survive a save round trip with explicit empty slots.

local Assert = require("tests.support.Assert")
local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
local PokegearState = require("libs.hgss.src.save.PokegearState")

local T = {
  metadata = {
    tags = { "pokegear" },
  },
  tests = {},
}

-- Loads a map module that does not exist yet at this baseline. The failure
-- names the missing behaviour instead of surfacing as a suite load error,
-- so the pre-implementation red stays attributable.
---@param moduleName string
---@param missingMessage string
---@return table
local function requireFeature(moduleName, missingMessage)
  local ok, mod = pcall(require, moduleName)
  if not ok then
    error(missingMessage, 0)
  end
  assert(type(mod) == "table", missingMessage)
  return mod --[[@as table]]
end

---@param path string
---@return table
local function visualRef(path)
  return { image = path, width = 32, height = 32, anchorX = 0, anchorY = 0 }
end

-- Synthetic companion catalog with two contacts and a 102-location region:
-- enough catalogued locations to fill the hundred-record collection and
-- prove the next write fails, validated through the real asset schema so
-- the scenarios borrow only genuine semantic references. The map section
-- carries one prepared foreground and upper plane per source skin behind
-- a shared world plane, like the compiled family, so the renderer suite
-- can prove per-skin chrome selection.
---@return table
local function fixtureManifest()
  local locations = {}
  for index = 1, 102 do
    locations[#locations + 1] = { key = string.format("test.place.%03d", index) }
  end
  local mapForeground, mapUpper = {}, {}
  for skin = 0, 5 do
    mapForeground[skin] = visualRef("assets/generated/pokegear/map-foreground-skin-" .. skin .. ".png")
    mapUpper[skin] = visualRef("assets/generated/pokegear/map-upper-skin-" .. skin .. ".png")
  end
  return {
    schema = "g4-pokegear-assets-v1",
    skins = { 0, 1, 2, 3, 4, 5 },
    shell = { foreground = visualRef("assets/generated/pokegear/shell-foreground-skin-0.png") },
    configure = { panel = visualRef("assets/generated/pokegear/configure-panel.png") },
    phone = { panel = visualRef("assets/generated/pokegear/phone-panel.png") },
    map = {
      base = visualRef("assets/generated/pokegear/map-base.png"),
      foreground = mapForeground,
      upper = mapUpper,
    },
    fly = { base = visualRef("assets/generated/pokegear/fly-base.png") },
    radio = { dial = visualRef("assets/generated/pokegear/radio-dial.png") },
    catalog = {
      contacts = {
        { key = "test.caller.falkner", sortWeight = 10 },
        { key = "test.caller.mom", sortWeight = 20 },
      },
      contactOrder = { "test.caller.falkner", "test.caller.mom" },
      callDefinitions = {},
      callTriggers = {},
      rematches = {},
      gifts = {},
      momPurchases = {},
      locations = locations,
      flypoints = {},
      reception = {},
      shows = {},
      radioEffects = {},
    },
    text = {},
    sequences = {},
  }
end

---@param record table
---@return table
local function catalogRefs(record)
  return { catalog = record.catalog }
end

-- Source-normalized map context for an outdoor main-matrix cell. Field
-- values stay synthetic; only the record shape follows the map contract.
---@return table
local function outdoorContext()
  return {
    fieldMap = "test.field.new-bark",
    location = "test.place.001",
    matrixX = 96,
    matrixY = 64,
    region = "johto",
    unlockLevel = 1,
    specialMode = nil,
    playerGender = "boy",
  }
end

-- Closed stub word selector through the typed handoff: the test drives
-- each outcome explicitly, so no real selector is required.
---@return table selector with scripted outcomes
local function stubWordEntry()
  local selector = { opened = {}, choice = nil, cancelled = false }
  function selector:open(request)
    assert(type(request) == "table", "the word request carries its typed fields")
    self.opened[#self.opened + 1] = request
  end
  function selector:step()
  end
  function selector:result()
    if self.cancelled then
      return { cancelled = true }
    end
    return self.choice
  end
  function selector:cancel()
    self.cancelled = true
  end
  function selector:choose(word)
    self.choice = { word = word }
    self.cancelled = false
  end
  function selector:reset()
    self.choice = nil
    self.cancelled = false
  end
  return selector
end

---@param params table
---@return table box { controller: table, state: table, record: table, wordEntry: table }
local function openMap(params)
  local MapController = requireFeature(
    "game.hgss.src.pokegear.MapController",
    "the region map has no controller yet: icon annotation slots, capacity, cleanup, and word handoff cannot persist"
  )
  local record = PokegearAssetSchema.validate(params.manifest or fixtureManifest())
  Assert.notNil(record, "the synthetic companion catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local state = params.state or PokegearState.new({ seed = 4177 }, catalogRefs(record))
  local wordEntry = params.wordEntry or stubWordEntry()
  local controller = MapController.new({
    state = state,
    assets = record,
    mapContext = params.mapContext or outdoorContext(),
    phoneProjection = params.phoneProjection or function(_)
      return {}
    end,
    roamerProjection = params.roamerProjection or {},
    wordEntry = wordEntry,
  })
  return { controller = controller, state = state, record = record, wordEntry = wordEntry }
end

---@param rect table
---@return number x
---@return number y
local function center(rect)
  assert(type(rect) == "table", "the published view carries hit rectangles")
  return rect.x + rect.width / 2, rect.y + rect.height / 2
end

-- Drags from one published rectangle to another through the shared
-- semantic pointer vocabulary.
---@param controller table
---@param from table
---@param to table
local function drag(controller, from, to)
  local x0, y0 = center(from)
  local x1, y1 = center(to)
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x0, y = y0 } })
  controller:updateFixed({ { type = "pointer_move", pointerId = "touch:1", x = x1, y = y1 } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x1, y = y1 } })
end

---@param controller table
---@param rect table
local function tap(controller, rect)
  local x, y = center(rect)
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = x, y = y } })
end

-- Enters the marking panel and returns its published hit regions. Both
-- required entrance completions must finish before the panel accepts a
-- drag; the test waits on the published transition, never on a count.
---@param controller table
---@return table panel
local function enterMarkings(controller)
  local view = assert(controller:status().view, "the map controller exports its detached view")
  local button = assert(view.markingsButton, "the map view publishes its markings entry")
  tap(controller, button)
  for _ = 1, 120 do
    local status = controller:status()
    local transition = status.transition
    if transition == nil or transition.completed == true then
      break
    end
    controller:updateFixed({})
  end
  local transition = controller:status().transition
  Assert.isTrue(transition == nil or transition.completed == true, "the marking entrance settles")
  local panel = assert(controller:status().view.markingPanel, "the entrance publishes the marking panel")
  assert(type(panel.pool) == "table", "the panel publishes its icon pool")
  assert(type(panel.icons) == "table", "the panel publishes its icon slots")
  assert(type(panel.words) == "table", "the panel publishes its word slots")
  assert(type(panel.trash) == "table", "the panel publishes its trash action")
  return panel
end

-- Icon drags keep source order, write exactly once, and clean up blank
-- records; the hundredth location fills the collection while the next
-- write fails; and markings survive a save round trip.
function T.tests.native_annotation_operations_persist_in_source_slot_order()
  local manifest = fixtureManifest()
  local box = openMap({ manifest = manifest })
  local controller, state = box.controller, box.state

  local panel = enterMarkings(controller)
  local revisionAtOpen = state:revision()

  -- A cancelled drag changes nothing: down on a pool icon, partway move,
  -- release on empty surface. No revision, no record.
  do
    local x0, y0 = center(panel.pool[1])
    controller:updateFixed({ { type = "pointer_down", pointerId = "touch:2", x = x0, y = y0 } })
    controller:updateFixed({ { type = "pointer_move", pointerId = "touch:2", x = x0 + 3, y = y0 + 3 } })
    controller:updateFixed({ { type = "cancel" } })
    Assert.equal(state:revision(), revisionAtOpen, "a cancelled drag publishes nothing")
    Assert.isNil(state:capture().markings["test.place.001"], "a cancelled drag stores no record")
  end

  -- Adding two pool icons lands them in slot order with one write each.
  drag(controller, panel.pool[3], panel.icons[2])
  Assert.equal(state:revision(), revisionAtOpen + 1, "one icon drop advances exactly one revision")
  drag(controller, panel.pool[1], panel.icons[1])
  Assert.equal(state:revision(), revisionAtOpen + 2, "a second icon drop advances one more revision")
  Assert.deepEqual(
    state:capture().markings["test.place.001"].icons,
    { 1, 3, false, false },
    "dropped icons keep source slot order"
  )

  -- Swapping two occupied slots exchanges exactly those values in one write.
  drag(controller, panel.icons[1], panel.icons[2])
  Assert.equal(state:revision(), revisionAtOpen + 3, "one swap advances exactly one revision")
  Assert.deepEqual(
    state:capture().markings["test.place.001"].icons,
    { 3, 1, false, false },
    "a swap exchanges exactly the dragged slots"
  )

  -- Deleting one slot clears only that slot in one write.
  drag(controller, panel.icons[1], panel.trash)
  Assert.equal(state:revision(), revisionAtOpen + 4, "one delete advances exactly one revision")
  Assert.deepEqual(
    state:capture().markings["test.place.001"].icons,
    { false, 1, false, false },
    "a delete clears exactly the dragged slot"
  )

  -- Emptying the last occupied slot removes the blank record entirely.
  drag(controller, panel.icons[2], panel.trash)
  Assert.isNil(state:capture().markings["test.place.001"], "an emptied record leaves no blank residue")

  -- Filling the collection through the real state owner holds exactly one
  -- hundred locations; the next write fails without moving the revision.
  local filled = 0
  for index = 1, 101 do
    local key = string.format("test.place.%03d", index)
    local ok = pcall(function()
      state:setMarking(key, { icons = { 2, false, false, false }, words = { false, false, false, false } })
    end)
    if ok then
      filled = filled + 1
    else
      Assert.equal(index, 101, "the hundred-and-first location is the first rejection")
    end
  end
  Assert.equal(filled, 100, "the collection holds exactly one hundred location records")
  local revisionAtFull = state:revision()
  local fullOk = pcall(function()
    state:setMarking("test.place.102", { icons = { 2, false, false, false }, words = { false, false, false, false } })
  end)
  Assert.isFalse(fullOk, "a write past capacity fails")
  Assert.equal(state:revision(), revisionAtFull, "a rejected write moves no revision")

  -- Save and reload preserve every record with explicit empty slots.
  local bucket = state:capture()
  local record = PokegearAssetSchema.validate(manifest)
  assert(record ~= nil, "synthetic catalog validated above")
  local revived = PokegearState.restore(bucket, catalogRefs(record))
  Assert.deepEqual(revived:capture().markings, bucket.markings, "all one hundred records survive the round trip")
  Assert.deepEqual(
    revived:capture().markings["test.place.001"].icons,
    { 2, false, false, false },
    "the reopened record keeps its icon slots with explicit empties"
  )
  Assert.deepEqual(
    revived:capture().markings["test.place.001"].words,
    { false, false, false, false },
    "the reopened record keeps its word slots with explicit empties"
  )
  controller:dispose()
end

-- Word edits round-trip through the typed selector handoff: a selection
-- applies once, a cancellation preserves the old word, a stale result
-- edits nothing, and pan, zoom, cursor, and mode restore on return.
function T.tests.word_editor_return_restores_the_map_session()
  local box = openMap({})
  local controller, state, wordEntry = box.controller, box.state, box.wordEntry

  state:setMarking("test.place.001", { icons = { 1, false, false, false }, words = { "7", false, false, false } })
  local panel = enterMarkings(controller)

  -- Panning the map and noting the session: cursor, zoom cells, pan, and
  -- marking mode all restore after the selector returns.
  local view = assert(controller:status().view, "the map view is published")
  local sessionBefore = {
    cursor = view.cursor,
    zoomCells = view.zoomCells,
    pan = view.pan ~= nil and { x = view.pan.x, y = view.pan.y } or nil,
    markingMode = controller:status().markingMode,
  }

  -- Selecting a new word applies exactly once through the typed handoff.
  tap(controller, panel.words[1])
  local request = controller:takeWordRequest()
  Assert.equal(request.locationKey, "test.place.001", "the word request names its location")
  Assert.equal(request.slot, 1, "the word request names its slot")
  Assert.equal(request.oldWord, "7", "the word request carries the current word")
  Assert.notNil(request.operationId, "the word request carries its operation identity")
  Assert.notNil(request.session, "the word request snapshots the map session")
  wordEntry:choose("23")
  controller:acceptWordResult({ operationId = request.operationId, result = wordEntry:result() })
  Assert.deepEqual(
    state:capture().markings["test.place.001"].words,
    { "23", false, false, false },
    "the selected word applies to its slot"
  )

  -- Cancelling a second edit preserves the old word and restores the map.
  tap(controller, panel.words[2])
  local second = controller:takeWordRequest()
  Assert.equal(second.oldWord, false, "an empty slot requests with the empty sentinel")
  wordEntry:reset()
  wordEntry:cancel()
  controller:acceptWordResult({ operationId = second.operationId, result = wordEntry:result() })
  Assert.deepEqual(
    state:capture().markings["test.place.001"].words,
    { "23", false, false, false },
    "a cancelled edit preserves the stored words"
  )

  -- A stale result edits nothing: neither an unknown operation nor an
  -- already-consumed one may touch a new location.
  local revisionBeforeStale = state:revision()
  Assert.throws(function()
    controller:acceptWordResult({ operationId = "stale-operation", result = { word = "41" } })
  end, "a stale word result fails")
  Assert.throws(function()
    controller:acceptWordResult({ operationId = request.operationId, result = { word = "41" } })
  end, "a replayed word result fails")
  Assert.equal(state:revision(), revisionBeforeStale, "stale results move no revision")
  Assert.isNil(state:capture().markings["test.place.002"], "a stale result edits no new location")

  -- The map session restores exactly after every return.
  local returned = assert(controller:status().view, "the map view returns with the selector")
  Assert.deepEqual(returned.cursor, sessionBefore.cursor, "the return restores the cursor")
  Assert.equal(returned.zoomCells, sessionBefore.zoomCells, "the return restores the zoom cells")
  Assert.deepEqual(
    returned.pan ~= nil and { x = returned.pan.x, y = returned.pan.y } or nil,
    sessionBefore.pan,
    "the return restores the pan"
  )
  Assert.equal(controller:status().markingMode, sessionBefore.markingMode, "the return restores the marking mode")
  controller:dispose()
end

-- Context cells resolve through the source coordinate roles: outdoor
-- main-matrix maps divide world coordinates by thirty-two, indoor maps
-- keep explicit header coordinates, zero-coordinate maps take the
-- last-exterior or special-spawn fallback, and special locations keep
-- their tabled coordinates. Missing fallbacks and scales fail loudly.
function T.tests.context_cells_follow_the_source_coordinate_roles()
  local MapProjection = requireFeature(
    "game.hgss.src.pokegear.MapProjection",
    "the region map has no projection owner yet: context cells cannot resolve"
  )
  local outdoor = MapProjection.contextCell({ matrixX = 695, matrixY = 397 })
  Assert.deepEqual(outdoor, { x = 21, y = 12 }, "outdoor columns divide world x by thirty-two")
  local indoor = MapProjection.contextCell({ matrixX = 0, matrixY = 0, explicitX = 11, explicitY = 5 })
  Assert.deepEqual(indoor, { x = 11, y = 5 }, "indoor cells keep their header coordinates")
  local fallback = MapProjection.contextCell({
    matrixX = 0,
    matrixY = 0,
    explicitX = 0,
    explicitY = 0,
    lastExterior = { x = 9, y = 21 },
  })
  Assert.deepEqual(fallback, { x = 9, y = 21 }, "zero-coordinate maps fall back to the last exterior")
  local spawn = MapProjection.contextCell({
    matrixX = 0,
    matrixY = 0,
    explicitX = 0,
    explicitY = 0,
    specialSpawn = { x = 4, y = 6 },
  })
  Assert.deepEqual(spawn, { x = 4, y = 6 }, "the special spawn backs up a missing exterior")
  Assert.throws(function()
    MapProjection.contextCell({ matrixX = 0, matrixY = 0, explicitX = 0, explicitY = 0 })
  end, "a zero-coordinate map without a fallback never invents a position")
  local special = MapProjection.contextCell({
    matrixX = 820,
    matrixY = 266,
    explicitX = 25,
    explicitY = 8,
    lastExterior = { x = 9, y = 21 },
    special = "mt-silver",
  })
  Assert.deepEqual(special, { x = 25, y = 8 }, "special locations keep their tabled coordinates")
  Assert.throws(function()
    MapProjection.contextCell({ matrixX = 0, matrixY = 0, special = "aqua" })
  end, "a special location without tabled coordinates fails")
  Assert.throws(function()
    MapProjection.forward({ x = 0, y = 0 }, { x = 0, y = 0 }, 15, { x = 0, y = 0, width = 256, height = 192 })
  end, "map scale stays a discrete eight or sixteen-pixel projection")
end

-- Forward and inverse transforms stay exact inverses over every
-- selectable cell at both discrete scales, extreme pans, and all host
-- panes, with source truncation on negative remainders, no selection
-- outside the world surface, and clamped pan and cursor bounds.
function T.tests.cell_transforms_agree_with_source_arithmetic()
  local MapProjection = requireFeature(
    "game.hgss.src.pokegear.MapProjection",
    "the region map has no projection owner yet: cell transforms cannot agree"
  )
  local panes = {
    { x = 0, y = 0, width = 256, height = 192 },
    { x = 0, y = 192, width = 256, height = 192 },
    { x = 0, y = 0, width = 256, height = 192 },
    { x = 128, y = 96, width = 256, height = 192 },
  }
  local pans = { { x = 0, y = 0 }, { x = -40, y = -24 }, { x = 248, y = 248 } }
  for _, pane in ipairs(panes) do
    for _, zoom in ipairs({ 8, 16 }) do
      local span = math.floor(512 / zoom)
      for _, pan in ipairs(pans) do
        for cy = 0, span - 1 do
          for cx = 0, span - 1 do
            local point = MapProjection.forward({ x = cx, y = cy }, pan, zoom, pane)
            local back = MapProjection.inverse(point, pan, zoom, pane)
            Assert.notNil(back, "every projected cell pointer-maps back")
            Assert.equal(back.x, cx, "the inverse keeps the column")
            Assert.equal(back.y, cy, "the inverse keeps the row")
          end
        end
      end
    end
  end
  local pane = panes[1]
  local back = MapProjection.inverse({ x = pane.x, y = pane.y }, { x = 3, y = 3 }, 8, pane)
  Assert.deepEqual(back, { x = 0, y = 0 }, "negative remainders truncate toward zero")
  Assert.isNil(
    MapProjection.inverse({ x = pane.x - 20, y = pane.y - 20 }, { x = 0, y = 0 }, 8, pane),
    "pointers above and left of the surface select nothing"
  )
  local clamped = MapProjection.clampPan({ x = 9000, y = -9000 }, 8, pane)
  Assert.equal(clamped.x, 256, "panning clamps to the surface edge")
  Assert.equal(clamped.y, -320, "panning clamps the negative edge symmetrically")
  local cursor = MapProjection.clampCursor({ x = 60, y = 70 }, 8, 1)
  Assert.equal(cursor.x, 27, "a stale pre-unlock cursor never selects the hidden region")
  Assert.equal(cursor.y, 63, "cursor rows clamp to the surface")
  local open = MapProjection.clampCursor({ x = 40, y = 10 }, 8, 3)
  Assert.deepEqual(open, { x = 40, y = 10 }, "the unlocked map keeps its selection")
  Assert.equal(MapProjection.tierOfColumn(27), 1, "Johto columns open first")
  Assert.equal(MapProjection.tierOfColumn(28), 2, "the Indigo approaches open next")
  Assert.equal(MapProjection.tierOfColumn(32), 3, "the rest of Kanto opens last")
end

-- Marker placement applies the source map Y offset and the
-- sprite-manager virtual-origin normalization exactly once, stably
-- across repeated opens.
function T.tests.marker_placement_applies_its_offsets_once()
  local MapProjection = requireFeature(
    "game.hgss.src.pokegear.MapProjection",
    "the region map has no projection owner yet: markers cannot place"
  )
  local pane = { x = 0, y = 0, width = 256, height = 192 }
  local first = MapProjection.markerPoint({ x = 25, y = 8 }, { x = 0, y = 0 }, 8, pane)
  local again = MapProjection.markerPoint({ x = 25, y = 8 }, { x = 0, y = 0 }, 8, pane)
  Assert.deepEqual(again, first, "repeated marker placement never drifts")
  Assert.equal(first.x - 25 * 8, -48, "marker columns normalize the virtual origin once")
  Assert.equal(first.y - 8 * 8, 2 - 48, "marker rows apply the Y offset and virtual origin once")
end

-- The zoom preference persists through the durable owner while drag and
-- editor snapshots stay transient.
function T.tests.zoom_preference_persists_while_edits_stay_transient()
  local box = openMap({})
  local controller, state = box.controller, box.state
  Assert.equal(controller:status().view.zoomCells, 8, "the map opens at eight-pixel cells")
  local view = assert(controller:status().view, "the map view is published")
  tap(controller, view.zoomButton)
  Assert.equal(controller:status().view.zoomCells, 16, "the zoom control doubles the cell size")
  Assert.equal(state:readPreferences().mapZoomed, true, "zoom persists as a preference")
  local revived = openMap({ manifest = box.record, state = state })
  Assert.equal(revived.controller:status().view.zoomCells, 16, "a reopened map keeps its zoom")
  revived.controller:dispose()
  tap(controller, controller:status().view.zoomButton)
  Assert.equal(controller:status().view.zoomCells, 8, "zooming back restores eight-pixel cells")
  controller:dispose()
end

-- Icon drops with identical content publish nothing: only a real slot
-- change advances the revision.
function T.tests.identical_icon_drops_publish_nothing()
  local box = openMap({})
  local controller, state = box.controller, box.state
  local panel = enterMarkings(controller)
  local revisionAtOpen = state:revision()
  drag(controller, panel.pool[2], panel.icons[1])
  Assert.equal(state:revision(), revisionAtOpen + 1, "one icon drop advances one revision")
  drag(controller, panel.pool[2], panel.icons[1])
  Assert.equal(state:revision(), revisionAtOpen + 1, "an identical drop publishes nothing")
  drag(controller, panel.icons[1], panel.icons[1])
  Assert.equal(state:revision(), revisionAtOpen + 1, "dropping a slot onto itself publishes nothing")
  controller:dispose()
end

-- Invalid selector results fail without touching marking state, and the
-- pending edit stays open for a valid answer or a cancellation.
function T.tests.invalid_word_results_fail_without_touching_state()
  local box = openMap({})
  local controller, state = box.controller, box.state
  state:setMarking("test.place.001", { icons = { 1, false, false, false }, words = { "7", false, false, false } })
  local panel = enterMarkings(controller)
  tap(controller, panel.words[1])
  local request = controller:takeWordRequest()
  Assert.notNil(request, "the word tap pends its request")
  local revisionBefore = state:revision()
  for _, bad in ipairs({ { word = "abc" }, { word = "" }, { word = 41 }, {} }) do
    Assert.throws(function()
      controller:acceptWordResult({ operationId = request.operationId, result = bad })
    end, "an invalid word result fails")
  end
  Assert.equal(state:revision(), revisionBefore, "invalid results move no revision")
  Assert.deepEqual(
    state:capture().markings["test.place.001"].words,
    { "7", false, false, false },
    "invalid results keep the old word"
  )
  Assert.isNil(controller:takeWordRequest(), "the failed edit stays pending without a second outbox")
  controller:acceptWordResult({ operationId = request.operationId, result = { cancelled = true } })
  Assert.deepEqual(
    state:capture().markings["test.place.001"].words,
    { "7", false, false, false },
    "cancelling after invalid answers preserves the word"
  )
  controller:dispose()
end

-- Keyboard and pointer keep separate interaction state: directional keys
-- walk the selection cursor while pointer drags pan without moving it,
-- and a pending word edit blocks map input until it resolves.
function T.tests.keyboard_and_pointer_keep_separate_state()
  local box = openMap({})
  local controller = box.controller
  local before = controller:status().view.cursor
  controller:updateFixed({ { type = "navigate", direction = "right" } })
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  local walked = controller:status().view.cursor
  Assert.deepEqual(walked, { x = before.x + 1, y = before.y + 1 }, "directional keys walk the cursor")
  local panBefore = controller:status().view.pan
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = 100, y = 60 } })
  controller:updateFixed({ { type = "pointer_move", pointerId = "touch:1", x = 120, y = 70 } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = 120, y = 70 } })
  local afterPan = controller:status().view.pan
  Assert.deepEqual(afterPan, { x = panBefore.x + 20, y = panBefore.y + 10 }, "a pointer drag pans the map")
  Assert.deepEqual(controller:status().view.cursor, walked, "panning never moves the cursor")
  controller:updateFixed({ { type = "confirm" } })
  for _ = 1, 120 do
    if controller:status().transition == nil then
      break
    end
    controller:updateFixed({})
  end
  Assert.equal(controller:status().markingMode, "marking", "confirming enters the marking panel")
  controller:dispose()
end

-- Locked tiers refuse selection while the unlocked map keeps it, and
-- reopening at a new tier re-masks without moving committed markings.
function T.tests.locked_tiers_refuse_selection_until_reopen()
  local manifest = fixtureManifest()
  local locked = openMap({ manifest = manifest })
  local controller = locked.controller
  local cursorBefore = controller:status().view.cursor
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = 240, y = 40 } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = 240, y = 40 } })
  Assert.deepEqual(
    controller:status().view.cursor,
    cursorBefore,
    "a tap on the hidden region selects nothing"
  )
  local masks = controller:status().view.maskRects
  Assert.equal(#masks, 2, "the locked map masks both hidden tiers")
  controller:dispose()
  local context = outdoorContext()
  context.unlockLevel = 3
  local open = openMap({ manifest = manifest, mapContext = context })
  Assert.deepEqual(open.controller:status().view.maskRects, {}, "the unlocked map masks nothing")
  open.controller:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = 240, y = 40 } })
  open.controller:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = 240, y = 40 } })
  Assert.deepEqual(
    open.controller:status().view.cursor,
    { x = 30, y = 5 },
    "the unlocked map selects its tapped cell"
  )
  open.controller:dispose()
end

-- Drags survive status reads and empty ticks, the panel stays open
-- across an app-switch-shaped pause, and committed markings outlive the
-- controller that wrote them.
function T.tests.drags_and_panels_survive_reads_and_reopen()
  local manifest = fixtureManifest()
  local box = openMap({ manifest = manifest })
  local controller, state, record = box.controller, box.state, box.record
  local panel = enterMarkings(controller)
  local revisionAtOpen = state:revision()
  local x0, y0 = center(panel.pool[4])
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:9", x = x0, y = y0 } })
  for _ = 1, 10 do
    controller:updateFixed({})
    controller:status()
  end
  local x1, y1 = center(panel.icons[3])
  controller:updateFixed({ { type = "pointer_move", pointerId = "touch:9", x = x1, y = y1 } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:9", x = x1, y = y1 } })
  Assert.equal(state:revision(), revisionAtOpen + 1, "a drag across reads still writes exactly once")
  Assert.deepEqual(
    state:capture().markings["test.place.001"].icons,
    { false, false, 4, false },
    "the drag lands in its slot"
  )
  for _ = 1, 50 do
    controller:updateFixed({})
  end
  Assert.notNil(controller:status().view.markingPanel, "the panel survives an app-switch pause")
  local bucket = state:capture()
  controller:dispose()
  local again = openMap({ manifest = manifest, state = PokegearState.restore(bucket, catalogRefs(record)) })
  local reopened = enterMarkings(again.controller)
  Assert.notNil(reopened, "the reopened map restores its panel")
  Assert.deepEqual(
    again.state:capture().markings["test.place.001"].icons,
    { false, false, 4, false },
    "committed markings outlive their controller"
  )
  again.controller:dispose()
end

-- Cancelling a pending word edit preserves the stored word and clears
-- the handoff without publishing.
function T.tests.cancelling_a_word_edit_preserves_state()
  local box = openMap({})
  local controller, state = box.controller, box.state
  state:setMarking("test.place.001", { icons = { 1, false, false, false }, words = { "7", false, false, false } })
  local panel = enterMarkings(controller)
  tap(controller, panel.words[1])
  local request = controller:takeWordRequest()
  Assert.notNil(request, "the word tap pends its request")
  Assert.equal(controller:status().busy, true, "a pending edit holds the card busy")
  local revisionBefore = state:revision()
  controller:updateFixed({ { type = "cancel" } })
  Assert.isNil(controller:takeWordRequest(), "cancelling clears the handoff")
  Assert.equal(state:revision(), revisionBefore, "cancelling a word edit publishes nothing")
  Assert.deepEqual(
    state:capture().markings["test.place.001"].words,
    { "7", false, false, false },
    "cancelling preserves the stored word"
  )
  Assert.equal(controller:status().busy, false, "the card releases its busy flag")
  controller:dispose()
end

-- Map initialization and contact markers come from their shared owners:
-- the field map resolves its compiled location, unknown maps fail
-- loudly, roamer cells resolve through their header reference, and the
-- contact query reports readiness and gifts without caching.
function T.tests.map_context_and_markers_come_from_shared_owners()
  local MapController = requireFeature(
    "game.hgss.src.pokegear.MapController",
    "the region map has no controller yet: shared-owner markers cannot project"
  )
  local PhoneWorldContext = require("game.hgss.src.pokegear.PhoneWorldContext")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic companion catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local state = PokegearState.new({ seed = 5150 }, catalogRefs(record))
  local worlds = PhoneWorldContext.new({ state = state })
  local catalog = {
    locations = {
      {
        key = "test.place.violet",
        fieldMap = "test.field.violet",
        mapRef = 11,
        matrix = { x = 497, y = 272 },
        location = "test.place.violet",
        section = "test.section.violet",
        region = "johto",
        flypoint = false,
      },
    },
  }
  local context = worlds:mapInit({
    mapSymbol = "test.field.violet",
    playerX = 497,
    playerY = 0,
    playerZ = 272,
    playerGender = "girl",
  }, catalog)
  Assert.equal(context.location, "test.place.violet", "the field map resolves its displayed location")
  Assert.equal(context.region, "johto", "the field map resolves its region")
  Assert.equal(context.unlockLevel, 1, "an unset tier starts in Johto")
  Assert.equal(context.playerGender, "girl", "the field read carries its gender")
  Assert.throws(function()
    worlds:mapInit({ mapSymbol = "test.field.nowhere", playerX = 0, playerZ = 0, playerGender = "boy" }, catalog)
  end, "a field map without compiled coverage fails loudly")
  state:setPreference("mapUnlockLevel", 2)
  local reopened = worlds:mapInit({
    mapSymbol = "test.field.violet",
    playerX = 497,
    playerZ = 272,
    playerGender = "girl",
  }, catalog)
  Assert.equal(reopened.unlockLevel, 2, "saved progression facts survive initialization")
  local markers = worlds:locationMarkers("test.place.violet", {
    rematchMarker = function(_, contact)
      if contact == "test.caller.ready" then
        return { tier = 2, ready = true }
      end
      return { tier = 2, ready = false }
    end,
  }, { ["test.caller.ready"] = "test.place.violet", ["test.caller.quiet"] = "test.place.violet" })
  Assert.equal(#markers, 1, "only staged contacts project")
  Assert.equal(markers[1].contact, "test.caller.ready", "the ready contact projects")
  local placed = MapController.new({
    state = state,
    assets = record,
    mapContext = {
      fieldMap = "test.field.violet",
      location = "test.place.violet",
      matrixX = 497,
      matrixY = 272,
      region = "johto",
      unlockLevel = 1,
      specialMode = nil,
      playerGender = "girl",
    },
    phoneProjection = function(_)
      return {}
    end,
    roamerProjection = {
      { key = "test.roamer.known", species = "test.raikou", location = 11, lifecycle = "roaming" },
      { key = "test.roamer.lost", species = "test.entei", location = 999, lifecycle = "roaming" },
    },
    wordEntry = stubWordEntry(),
  })
  local roamerMarkers = {}
  for _, marker in ipairs(placed:status().view.markers) do
    if marker.kind == "roamer" then
      roamerMarkers[#roamerMarkers + 1] = marker
    end
  end
  Assert.equal(#roamerMarkers, 2, "both active roamers project through the snapshot")
  for _, marker in ipairs(roamerMarkers) do
    Assert.isNil(marker.point, "fixture locations without header references place no roamer points")
  end
  placed:dispose()
end

-- The marking entrance gates input until both its fade and slide
-- completions finish.
function T.tests.marking_entrance_gates_until_both_completions()
  local box = openMap({})
  local controller = box.controller
  local view = assert(controller:status().view, "the map view is published")
  tap(controller, view.markingsButton)
  Assert.notNil(controller:status().transition, "the marking entrance runs a transition")
  local gated = controller:status()
  controller:updateFixed({ { type = "pointer_down", pointerId = "touch:2", x = 8, y = 8 } })
  controller:updateFixed({ { type = "pointer_up", pointerId = "touch:2", x = 8, y = 8 } })
  Assert.deepEqual(controller:status().view, gated.view, "entrance input changes no view state")
  Assert.isNil(controller:takeResult(), "gated input publishes no result")
  Assert.isNil(controller:status().view.markingPanel, "the panel stays hidden until both completions")
  for _ = 1, 120 do
    if controller:status().transition == nil then
      break
    end
    controller:updateFixed({})
  end
  Assert.isNil(controller:status().transition, "both entrance completions finish")
  Assert.notNil(controller:status().view.markingPanel, "the settled entrance publishes the marking panel")
  controller:dispose()
end

-- The renderer paints independent world, mask, sprite, information, and
-- marking layers from the snapshot, selecting each skin's own prepared
-- foreground and upper chrome unmodulated, with no host text boundary
-- required.
function T.tests.renderer_paints_independent_layers_per_skin()
  local PokegearMapRenderer = requireFeature(
    "libs.hgss.src.presentation.PokegearMapRenderer",
    "the region map has no renderer yet: layers cannot paint"
  )
  local FakeGraphics = require("tests.support.FakeGraphics").new
  local box = openMap({})
  local controller = box.controller
  local manifest = fixtureManifest()
  local images = {}
  local function collect(node)
    if type(node) ~= "table" then
      return
    end
    if type(node.image) == "string" then
      images[node.image] = {}
      return
    end
    for _, child in pairs(node) do
      collect(child)
    end
  end
  collect(manifest)
  local seen = {}
  for skin = 0, 5 do
    box.state:setPreference("skin", skin)
    local status = controller:status()
    local view = assert(status.view, "the map view is published")
    local content = assert(view.content, "the map view carries its resolved content")
    local graphics = FakeGraphics({})
    PokegearMapRenderer.draw({ graphics = graphics, images = images }, status, skin)
    Assert.isTrue(#graphics.draws > 0, "skin " .. skin .. " draws its world plane")
    Assert.isTrue(#graphics.rectangles > 0, "skin " .. skin .. " paints its layers")
    local first = graphics.draws[1]
    Assert.equal(first.image, images[content.world], "skin " .. skin .. " draws its resolved world plane first")
    Assert.deepEqual(
      first.color,
      { 1, 1, 1, 1 },
      "skin " .. skin .. " paints the world plane unmodulated"
    )
    local drawn = {}
    for _, draw in ipairs(graphics.draws) do
      drawn[draw.image] = true
    end
    Assert.isTrue(
      drawn[images[content.foreground]],
      "skin " .. skin .. " draws its own prepared foreground chrome"
    )
    Assert.isTrue(drawn[images[content.upper]], "skin " .. skin .. " draws its own prepared upper chrome")
    local digest = content.foreground .. "|" .. content.upper
    Assert.isNil(seen[digest], "skin " .. skin .. " selects its own prepared chrome")
    seen[digest] = skin
  end
  local open = FakeGraphics({})
  PokegearMapRenderer.draw({ graphics = open, images = images }, controller:status(), 0)
  local closedRects = #open.rectangles
  local panel = enterMarkings(controller)
  Assert.notNil(panel, "the marking panel opens")
  local painted = FakeGraphics({})
  PokegearMapRenderer.draw({ graphics = painted, images = images }, controller:status(), 0)
  Assert.isTrue(#painted.rectangles > closedRects, "the open panel paints its pool, slots, and trash")
  local textCalls = {}
  local text = {
    drawText = function(_, line, _, _)
      textCalls[#textCalls + 1] = line
    end,
  }
  local withText = FakeGraphics({})
  PokegearMapRenderer.draw({ graphics = withText, images = images, text = text }, controller:status(), 0)
  Assert.isTrue(#textCalls > 0, "the information windows draw their token text")
  local missing = controller:status()
  local missingView = assert(missing.view, "the map view is published")
  missingView.content = {}
  Assert.throws(function()
    PokegearMapRenderer.draw({ graphics = FakeGraphics({}), images = images }, missing, 0)
  end, "a companion without a world plane raises instead of inventing geography")
  controller:dispose()
end

return T
