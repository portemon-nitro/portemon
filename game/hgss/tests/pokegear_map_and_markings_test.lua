-- The gear region map card: location selection and its information panel,
-- keyboard and touch motion, zoom with its persisted preference, the
-- marking mode's timed transitions and slot editing with exactly-once
-- persistence, and the typed word hand-off. Expectations come from the
-- source map application's rules (first covering location in table order,
-- the +2 row offset, two-tick cell moves, four-tick zooms, the marking
-- entrance timeline) over a small synthetic region map; no ROM data is read.

local Assert = require("tests.support.Assert")
local Fixture = require("tests.support.PokegearMapFixture")
local MapLocations = require("game.hgss.src.pokegear.map.MapLocations")
local MarkingMode = require("game.hgss.src.pokegear.map.MarkingMode")

local T = {
  metadata = { tags = { "pokegear" } },
  tests = {},
}

local tick = Fixture.tick

---@param controller table
---@return table view
local function view(controller)
  return assert(controller:status().view, "the map controller exports its detached view")
end

-- Ticks until the card is out of its mode transition, bounded.
---@param controller table
local function settle(controller)
  for _ = 1, 60 do
    if not controller:status().busy then
      return
    end
    controller:updateFixed({})
  end
  error("the map transition never settled", 0)
end

function T.tests.locations_resolve_in_table_order_with_hidden_ones_ending_the_search()
  local record = Fixture.record()
  local locations = MapLocations.new({ regionMap = record.catalog.regionMap, unlock = 2, fieldMap = "MAP_A" })
  Assert.equal(locations:locationAt(12, 10).mapSymbol, "MAP_A", "a cell inside a 2x2 location selects it")
  Assert.equal(locations:locationAt(13, 11).mapSymbol, "MAP_A", "its far corner selects it too")
  Assert.isNil(locations:locationAt(13, 12), "a cell just outside selects nothing")
  Assert.equal(locations:locationAt(14, 10).mapSymbol, "MAP_B", "the neighbouring map owns its own cell")
  -- Sinjoh Ruins sits first in the table and stays hidden away from its maps,
  -- so its covered cells select nothing rather than falling through.
  Assert.isNil(locations:locationAt(19, 2), "the hidden Sinjoh Ruins entry selects nothing")
  local at = MapLocations.new({
    regionMap = record.catalog.regionMap,
    unlock = 2,
    fieldMap = "MAP_SINJOH_RUINS_EXTERIOR",
  })
  Assert.equal(at:locationAt(19, 2).mapSymbol, "MAP_SINJOH_RUINS_EXTERIOR", "standing on the ruins reveals them")
  local johtoOnly = MapLocations.new({ regionMap = record.catalog.regionMap, unlock = 0, fieldMap = "MAP_A" })
  Assert.isNil(johtoOnly:select(30, 12), "Johto-only maps refuse every cell east of column twenty-one")
  Assert.equal(johtoOnly:select(12, 10).mapSymbol, "MAP_A", "Johto cells still select")
  Assert.equal(MapLocations.regionName(25, 10), "johto", "Mt. Silver's cell reads as Johto")
  Assert.equal(MapLocations.regionName(22, 10), "kanto", "columns past twenty-one read as Kanto")
  Assert.equal(MapLocations.regionOf(28, 6), MapLocations.REGION.INDIGO, "the Indigo Plateau cell is Indigo")
  Assert.isTrue(
    MapLocations.regionAllowed(30, 30, 5, MapLocations.REGION.KANTO),
    "Route 26 is always an allowed destination"
  )
  Assert.isFalse(
    MapLocations.regionAllowed(75, 5, 8, MapLocations.REGION.KANTO),
    "a Johto destination is refused from Kanto"
  )
end

function T.tests.the_card_opens_on_the_player_with_the_selection_panel()
  local box = Fixture.openMap()
  local v = view(box.controller)
  Assert.equal(v.mode, "map", "the card opens in map mode")
  Assert.equal(v.panel.region, "Johto", "the region follows the selected cell")
  Assert.equal(v.panel.landmark, "Landmark 41", "the landmark name resolves through its section entry")
  Assert.equal(v.panel.flavor, "Flavor 6\nsecond line", "the flavor text resolves through the location entry")
  Assert.isTrue(v.panel.previewFrame, "a location with a preview block shows the preview frame")
  Assert.equal(v.panel.previewBlock, 2, "the preview block is the source block minus one")
  Assert.equal(v.buttons.markings, "normal", "a selected location enables the markings button")
  Assert.equal(v.buttons.zoom, "unzoomed", "the card opens unzoomed")
  Assert.equal(#v.highlight, 1, "the selected map highlights its tiles")
  Assert.deepEqual(
    v.highlight[1],
    { srcX = 10, srcY = 30, destX = 11, destY = 9, width = 3, height = 3 },
    "a nine-tile overlay copies one cell up and left of the location"
  )
  Assert.deepEqual(
    v.sprites.player,
    { x = v.sprites.cursor.x, y = v.sprites.cursor.y, frame = 1 },
    "the player sits under the opening cursor"
  )
end

function T.tests.a_keyboard_move_selects_the_next_location_after_two_ticks()
  local box = Fixture.openMap()
  local before = view(box.controller).sprites.cursor.x
  box.controller:updateFixed({ { type = "navigate", direction = "right" } })
  box.controller:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(view(box.controller).panel.landmark, "Landmark 41", "a held direction mid-tween waits for the tween")
  tick(box.controller)
  local v = view(box.controller)
  Assert.equal(v.panel.landmark, "Landmark 41", "one cell east is still the two-by-two map")
  box.controller:updateFixed({ { type = "navigate", direction = "right" } })
  tick(box.controller, 2)
  Assert.equal(view(box.controller).panel.landmark, "Landmark 42", "two cells east selects the neighbouring map")
  Assert.isTrue(view(box.controller).sprites.cursor.x > before, "the cursor sprite moved east")
end

function T.tests.zoom_runs_four_ticks_and_persists_its_preference()
  local box = Fixture.openMap()
  box.controller:updateFixed({ { type = "menu" } })
  Assert.isTrue(box.controller:status().busy == false, "zoom is an animation, not a mode")
  local ratio = view(box.controller).world.ratio
  Assert.equal(ratio, 1.25, "the first tick scales a quarter")
  tick(box.controller, 3)
  Assert.equal(view(box.controller).world.ratio, 2, "four ticks finish the zoom")
  Assert.equal(view(box.controller).buttons.zoom, "zoomed", "the zoom button shows its zoomed art")
  Assert.isTrue(box.state:readPreferences().mapZoomed, "the zoom preference persists")
  local reopened = Fixture.openMap({ state = box.state, record = box.record })
  Assert.equal(view(reopened.controller).world.ratio, 2, "the card reopens zoomed")
end

function T.tests.touch_selects_a_cell_and_drags_the_map_without_moving_the_selection()
  local context = Fixture.context()
  context.matrixX = 20 * 32 + 8
  local box = Fixture.openMap({ mapContext = context })
  local v = view(box.controller)
  local cursor = v.sprites.cursor
  box.controller:updateFixed({ { type = "pointer_down", pointerId = "t", x = cursor.x + 16, y = cursor.y } })
  local selected = view(box.controller).sprites.cursor
  Assert.equal(selected.x, cursor.x + 16, "a touch moves the cursor to the touched cell centre")
  box.controller:updateFixed({ { type = "pointer_move", pointerId = "t", x = cursor.x + 16 + 12, y = cursor.y } })
  box.controller:updateFixed({ { type = "pointer_up", pointerId = "t", x = cursor.x + 16 + 12, y = cursor.y } })
  tick(box.controller, 3)
  Assert.isTrue(view(box.controller).world.scrollX < v.world.scrollX, "dragging right scrolls the world west")
  Assert.isTrue(
    view(box.controller).sprites.cursor.x > selected.x,
    "the cursor sprite travels with the world while the map drags"
  )
end

function T.tests.the_markings_button_is_disabled_without_a_location_and_for_the_ruins()
  local box = Fixture.openMap({
    mapContext = (function()
      local context = Fixture.context()
      context.matrixX, context.matrixY = 18 * 32, 8 * 32
      context.fieldMap = "MAP_A"
      return context
    end)(),
  })
  Assert.equal(view(box.controller).buttons.markings, "disabled", "an empty cell disables the markings button")
  box.controller:updateFixed({ { type = "confirm" } })
  Assert.isFalse(box.controller:status().busy, "entering markings does nothing without a location")
end

function T.tests.marking_mode_runs_its_timeline_and_edits_persist_exactly_once()
  local box = Fixture.openMap()
  local revision = box.state:revision()
  box.controller:updateFixed({ { type = "confirm" } })
  Assert.isTrue(box.controller:status().busy, "entering markings starts a transition")
  Assert.equal(view(box.controller).mode, "map", "the map stays until the swap tick")
  local sawFadeOut, sawMarking, slideStarted = false, false, false
  for _ = 1, 40 do
    tick(box.controller)
    local v = view(box.controller)
    if v.fade >= 1 then
      sawFadeOut = true
    end
    if v.mode == "marking" then
      sawMarking = true
      if v.bottomSlide == 112 then
        slideStarted = true
      end
    end
    if not box.controller:status().busy then
      break
    end
  end
  Assert.isTrue(sawFadeOut, "the lower screen fades fully out between the two modes")
  Assert.isTrue(sawMarking and slideStarted, "the panel starts hidden above its window and then slides in")
  Assert.equal(view(box.controller).bottomSlide, 0, "the slide ends fully shown")
  Assert.isTrue(box.controller:status().stripHidden, "marking mode hides the tab strip")
  Assert.equal(box.state:revision(), revision, "entering markings commits nothing")
  -- A first key press after touching only reveals the cursor; keys then walk
  -- the graph: A on the empty icon slot opens the pool, A again places icon 1.
  box.controller:updateFixed({ { type = "navigate", direction = "right" } })
  box.controller:updateFixed({ { type = "confirm" } })
  box.controller:updateFixed({ { type = "confirm" } })
  local marking = box.state:capture().markings.MAP_A
  Assert.notNil(marking, "placing an icon writes the location's marking")
  Assert.deepEqual(marking.icons, { 1, false, false, false }, "the first pool icon fills the first slot")
  local writes = box.state:revision()
  box.controller:updateFixed({ { type = "confirm" } })
  Assert.equal(box.state:revision(), writes, "placing the identical icon again publishes nothing")
  box.controller:updateFixed({ { type = "cancel" } })
  box.controller:updateFixed({ { type = "cancel" } })
  settle(box.controller)
  Assert.equal(view(box.controller).mode, "map", "Back returns to map mode")
  Assert.equal(view(box.controller).panel.markers[1], 1, "the panel shows the saved icon")
  Assert.equal(#view(box.controller).sprites.hasMarkings, 1, "the marked location carries a marking dot")
end

function T.tests.marking_slots_follow_the_key_graph_and_touch_drops()
  local mode = MarkingMode.new({
    marking = { icons = { 2, false, false, false }, words = { false, false, false, false } },
  })
  Assert.isNil(mode:view().cursor, "the key cursor stays hidden until a key is pressed")
  mode:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.deepEqual(
    { mode:view().cursor.x, mode:view().cursor.y },
    { 32, 32 },
    "the first key only reveals the cursor on the first slot"
  )
  mode:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.deepEqual(
    { mode:view().cursor.x, mode:view().cursor.y },
    { 32, 53 },
    "down from the first icon slot reaches the third slot's cursor spec"
  )
  -- Touch: drag the set icon from slot one to slot two; the icons swap with the empty target.
  mode:updateFixed({ { type = "pointer_down", x = 30, y = 30 } })
  Assert.equal(mode:view().drag.type, "set", "touching a set slot starts a slot drag")
  mode:updateFixed({ { type = "pointer_move", x = 135, y = 30 } })
  mode:updateFixed({ { type = "pointer_up", x = 135, y = 30 } })
  Assert.deepEqual(mode:marking().icons, { false, 2, false, false }, "dropping on another icon slot moves the icon")
  Assert.isTrue(mode:takeEdited(), "the swap reports one edit")
  -- Drop on the trash removes it.
  mode:updateFixed({ { type = "pointer_down", x = 135, y = 30 } })
  mode:updateFixed({ { type = "pointer_move", x = 70, y = 80 } })
  Assert.isTrue(mode:view().trashOpen, "hovering the trash opens its lid")
  mode:updateFixed({ { type = "pointer_up", x = 70, y = 80 } })
  Assert.deepEqual(mode:marking().icons, { false, false, false, false }, "dropping on the trash empties the slot")
  Assert.isTrue(mode:isEmpty(), "an emptied marking reports empty")
  -- Pool drag onto icon slot four.
  mode:updateFixed({ { type = "pointer_down", x = 60, y = 130 } })
  Assert.equal(mode:view().drag.type, "pool", "touching a pool icon starts a pool drag")
  mode:updateFixed({ { type = "pointer_up", x = 135, y = 55 } })
  Assert.deepEqual(mode:marking().icons, { false, false, false, 2 }, "dropping a pool icon fills the target slot")
end

function T.tests.a_word_edit_round_trips_through_the_typed_request()
  local box = Fixture.openMap()
  box.controller:updateFixed({ { type = "confirm" } })
  for _ = 1, 40 do
    tick(box.controller)
    if not box.controller:status().busy then
      break
    end
  end
  -- Reveal the cursor, move to word slot one, and ask for a word.
  box.controller:updateFixed({ { type = "navigate", direction = "right" } })
  box.controller:updateFixed({ { type = "navigate", direction = "right" } })
  box.controller:updateFixed({ { type = "confirm" } })
  local request = box.controller:takeWordRequest()
  Assert.notNil(request, "an empty word slot pends a typed request")
  assert(request ~= nil, "request checked above")
  Assert.equal(request.slot, 1, "the request names the one-based word slot")
  Assert.equal(request.mapSymbol, "MAP_A", "the request names the marked location")
  Assert.isNil(box.controller:takeWordRequest(), "a request is taken exactly once")
  Assert.isTrue(box.controller:status().busy, "the card waits for the selector")
  box.controller:acceptWordResult({ operationId = request.operationId, result = { word = "7" } })
  Assert.deepEqual(box.state:capture().markings.MAP_A.words, { "7", false, false, false }, "the chosen word persists")
  local ok = pcall(
    box.controller.acceptWordResult,
    box.controller,
    { operationId = request.operationId, result = { word = "8" } }
  )
  Assert.isFalse(ok, "a replayed result fails without editing")
  Assert.equal(box.state:capture().markings.MAP_A.words[1], "7", "the replay changed nothing")
end

function T.tests.live_roamers_appear_only_on_visible_locations()
  local box = Fixture.openMap({
    roamerProjection = {
      { key = "raikou", species = "RAIKOU", location = "test.place.a", lifecycle = "roaming" },
      { key = "entei", species = "ENTEI", location = "test.place.far", lifecycle = "roaming" },
      { key = "latias", species = "LATIAS", location = "test.place.a", lifecycle = "caught" },
    },
  })
  local roamers = view(box.controller).sprites.roamers
  Assert.equal(#roamers, 1, "only roaming roamers on a visible location draw")
  Assert.equal(roamers[1].frame, 1, "Raikou uses the first roamer frame")
end

function T.tests.a_contact_with_a_rematch_shows_the_panel_battle_icon()
  local box = Fixture.openMap({
    phoneProjection = function(location)
      if location == "test.place.a" then
        return { { contact = "test.caller.falkner", ready = true } }
      end
      return {}
    end,
  })
  Assert.isTrue(view(box.controller).panel.battleIcon, "a ready contact on the selected map shows the battle icon")
end

function T.tests.arriving_from_another_card_slides_the_panel_in()
  local box = Fixture.openMap({ switched = true })
  Assert.equal(view(box.controller).topSlide, 128, "the panel starts below the screen")
  tick(box.controller, 4)
  Assert.equal(view(box.controller).topSlide, 0, "four ticks bring it fully in")
  Assert.isFalse(box.controller:status().busy, "the arrival transition ends")
end

function T.tests.map_card_plays_its_source_tones()
  local effects = {}
  local function play(sequence)
    effects[#effects + 1] = sequence
  end
  local box = Fixture.openMap({ effect = play })
  -- Key motion across the region map is silent; only the cited actions answer.
  box.controller:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(#effects, 0, "cursor motion across the map plays nothing")
  tick(box.controller, 2)
  -- The X button zooms with its directional tones. The zoom tween runs
  -- four ticks outside the card busy flag, so the test ticks it out.
  box.controller:updateFixed({ { type = "menu" } })
  Assert.equal(effects[#effects], "SEQ_SE_GS_GEARXBUTTON", "zooming in plays the X tone")
  box.controller:updateFixed({ { type = "confirm" } })
  Assert.equal(#effects, 1, "a confirm during the zoom tween plays nothing")
  tick(box.controller, 6)
  box.controller:updateFixed({ { type = "menu" } })
  Assert.equal(effects[#effects], "SEQ_SE_GS_XBUTTON_SYUKUSHOU", "zooming out plays the unzoom tone")
  tick(box.controller, 6)
  -- A opens the marking editor with the decide tone; gated presses stay silent.
  box.controller:updateFixed({ { type = "confirm" } })
  Assert.equal(effects[#effects], "SEQ_SE_GS_GEARDECIDE", "opening markings plays the decide tone")
  box.controller:updateFixed({ { type = "confirm" } })
  Assert.equal(#effects, 3, "a confirm during the entrance transition plays nothing")
  settle(box.controller)
  Assert.equal(view(box.controller).mode, "marking", "the entrance settles in marking mode")
  Assert.equal(effects[#effects], "SEQ_SE_GS_GEARCURSOR", "the mode change plays the cursor tone")
  -- B leaves the editor with the cancel tone and the return plays the cursor tone.
  -- The editor opens in touch mode, so the first key only reveals the cursor.
  box.controller:updateFixed({ { type = "cancel" } })
  Assert.equal(view(box.controller).mode, "marking", "the first key only reveals the cursor")
  Assert.equal(effects[#effects], "SEQ_SE_GS_GEARCURSOR", "revealing plays nothing further")
  box.controller:updateFixed({ { type = "cancel" } })
  Assert.equal(effects[#effects], "SEQ_SE_GS_GEARCANCEL", "leaving markings plays the cancel tone")
  settle(box.controller)
  Assert.equal(view(box.controller).mode, "map", "the exit settles back in map mode")
  Assert.equal(effects[#effects], "SEQ_SE_GS_GEARCURSOR", "returning to the map plays the cursor tone")
  -- Touch on the map opening plays the touch tone.
  box.controller:updateFixed({ { type = "pointer_down", pointerId = "t", x = 100, y = 100 } })
  Assert.equal(effects[#effects], "SEQ_SE_GS_GEARMAPTOUCH", "touching the map plays the touch tone")
  box.controller:updateFixed({ { type = "pointer_up", pointerId = "t", x = 100, y = 100 } })
end

function T.tests.marking_edits_play_their_source_tones()
  local effects = {}
  local function play(sequence)
    effects[#effects + 1] = sequence
  end
  local mode = MarkingMode.new({
    marking = { icons = { false, false, false, false }, words = { false, false, false, false } },
    effect = play,
  })
  mode:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(#effects, 0, "revealing the key cursor plays nothing")
  mode:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(effects[#effects], "SEQ_SE_GS_GEARCURSOR", "key motion plays the cursor tone")
  mode:updateFixed({ { type = "confirm" } })
  Assert.equal(effects[#effects], "SEQ_SE_GS_GEARSEALGRAB", "grabbing the seal pool plays the grab tone")
  mode:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(effects[#effects], "SEQ_SE_GS_GEARCURSOR", "pool motion plays the cursor tone")
  mode:updateFixed({ { type = "confirm" } })
  Assert.equal(effects[#effects], "SEQ_SE_GS_GEARSEALHAMERU", "stamping the seal plays the stamp tone")
  mode:updateFixed({ { type = "cancel" } })
  Assert.equal(effects[#effects], "SEQ_SE_GS_GEARCANCEL", "cancelling the pool plays the cancel tone")
  mode:updateFixed({ { type = "confirm" } })
  Assert.equal(effects[#effects], "SEQ_SE_GS_GEARSEALGRAB", "grabbing a set seal plays the grab tone")
  mode:updateFixed({ { type = "confirm" } })
  Assert.equal(effects[#effects], "SEQ_SE_GS_GEARGOMIBAKO", "trashing the seal plays the trash tone")
  local before = #effects
  mode:updateFixed({ { type = "navigate", direction = "down" } })
  mode:updateFixed({ { type = "navigate", direction = "left" } })
  mode:updateFixed({ { type = "navigate", direction = "down" } })
  mode:updateFixed({ { type = "navigate", direction = "down" } })
  local anchored = #effects
  mode:updateFixed({ { type = "navigate", direction = "left" } })
  Assert.equal(#effects, anchored, "a blocked cursor step plays nothing")
  Assert.isTrue(anchored > before, "the walk to Back answers audibly")
  mode:updateFixed({ { type = "cancel" } })
  Assert.equal(effects[#effects], "SEQ_SE_GS_GEARCANCEL", "leaving the editor plays the cancel tone")
end

function T.tests.marking_touch_drags_play_their_source_tones()
  local effects = {}
  local function play(sequence)
    effects[#effects + 1] = sequence
  end
  local quiet = MarkingMode.new({
    marking = { icons = { false, false, false, false }, words = { false, false, false, false } },
    effect = play,
  })
  local result = select(1, quiet:updateFixed({ { type = "pointer_down", x = 80, y = 30 } }))
  Assert.equal(result, "word", "touching an empty word slot asks for a word")
  Assert.equal(#effects, 0, "asking for a word plays nothing")
  local mode = MarkingMode.new({
    marking = { icons = { 2, false, false, false }, words = { false, false, false, false } },
    effect = play,
  })
  mode:updateFixed({ { type = "pointer_down", x = 30, y = 30 } })
  Assert.equal(effects[#effects], "SEQ_SE_GS_GEARSEALGRAB", "touching a set slot grabs it audibly")
  mode:updateFixed({ { type = "pointer_move", x = 70, y = 80 } })
  mode:updateFixed({ { type = "pointer_up", x = 70, y = 80 } })
  Assert.equal(effects[#effects], "SEQ_SE_GS_GEARGOMIBAKO", "dropping on the trash plays the trash tone")
end

function T.tests.touch_waits_for_the_cursor_tween()
  local box = Fixture.openMap()
  box.controller:updateFixed({ { type = "navigate", direction = "right" } })
  box.controller:updateFixed({ { type = "pointer_down", pointerId = "t", x = 40, y = 16 } })
  Assert.deepEqual(
    view(box.controller).cell,
    { x = 13, y = 10 },
    "a touch during the cursor tween reselects nothing"
  )
  tick(box.controller, 2)
  box.controller:updateFixed({ { type = "pointer_down", pointerId = "t", x = 40, y = 16 } })
  Assert.isFalse(
    view(box.controller).cell.x == 13 and view(box.controller).cell.y == 10,
    "a touch once idle reselects the touched cell"
  )
end

return T
