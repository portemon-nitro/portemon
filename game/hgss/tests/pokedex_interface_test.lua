-- Shared draw/input placement for the field Pokedex: the complete browser
-- layout family and the registration layout over the same plan mechanics.
-- Interface definitions are immutable; assertions resolve real plans at
-- each supported size and map pointer geometry back to the finite browser
-- commands. No game state, renderer, GPU, ROM, or worker is touched.

local Assert = require("tests.support.Assert")
local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local INTERFACE_MODULE = "game.hgss.src.pokedex.PokedexInterface"

local T = {}

---@param behavior string missing interface behavior under test
---@return table the loaded shared interface owner
local function requirePresent(behavior)
  local ok, loaded = pcall(require, INTERFACE_MODULE)
  Assert.isTrue(ok, "missing shared draw/input interface owner: " .. behavior .. " (" .. INTERFACE_MODULE .. ")")
  assert(loaded ~= nil, "the shared interface module loads")
  return loaded --[[@as table]]
end

---@param class string layout class under test
---@return table<string, unknown> measured display facts for the class
local function measurementFor(class)
  if class == "dual" then
    return {
      width = 512,
      height = 384,
      topology = ScreenTopology.dualDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 256, height = 192 },
        touch = true,
        role = "world",
      }, {
        id = "lower",
        rect = { x = 0, y = 192, width = 256, height = 192 },
        touch = true,
        role = "auxiliary",
      }),
      pixelRatio = 1,
      signature = "pokedex-interface-test:dual",
    }
  end
  local width, height = 256, 192
  if class == "wide" then
    width, height = 512, 192
  elseif class == "tall" then
    width, height = 256, 384
  end
  return {
    width = width,
    height = height,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = width, height = height },
      touch = true,
      role = "world",
    }),
    pixelRatio = 1,
    signature = "pokedex-interface-test:" .. class,
  }
end

---@return table minimal browser view the plans can place
local function stubView()
  return {
    key = "view-generation",
    mode = "johto",
    page = "grid",
    selection = { species = "CHIKORITA" },
    counts = { seen = 2, caught = 2 },
  }
end

---@param plan table<string, unknown> resolved application plan
---@param paneId string browser pane identity
---@return table pane origin, number pane scale
local function paneOrigin(plan, paneId)
  for _, pane in ipairs(plan.panes or {}) do
    if type(pane) == "table" and pane.id == paneId then
      local placement = assert(pane.placement, "browser panes carry their placement")
      local origin = placement.origin or placement.frame
      return origin, placement.scale or 1
    end
  end
  error("the resolved plan carries no " .. paneId .. " pane", 0)
end

-- Builds one host-space pointer edge over a pane-local point: the
-- production session owns the host-to-local conversion, so the test
-- only adds the pane origin exactly like the host does.
---@param plan table<string, unknown> resolved application plan
---@param paneId string browser pane identity
---@param eventType string pointer edge type
---@param lx number pane-local x
---@param ly number pane-local y
---@param pointerId number|string stable pointer identity
---@return table host-space pointer event
local function hostTap(plan, paneId, eventType, lx, ly, pointerId)
  local origin, scale = paneOrigin(plan, paneId)
  return {
    type = eventType,
    x = origin.x + lx * scale,
    y = origin.y + ly * scale,
    pointerId = pointerId or 1,
  }
end


---@param view table<string, unknown> detached browser projection
---@return table<string, unknown> production-shaped session view with the private compact record
local function sessionView(view)
  local merged = { compact = { inspect = false, size = "weight" } }
  if type(view) == "table" then
    for key, value in pairs(view) do
      merged[key] = value
    end
    if type(merged.compact) ~= "table" then
      merged.compact = { inspect = false, size = "weight" }
    end
  end
  return merged
end

---@param view table<string, unknown> detached projection selecting the page
---@param page string page to project
---@return table<string, unknown> view on the requested page
local function viewOn(view, page)
  local moved = {}
  for key, value in pairs(view) do
    moved[key] = value
  end
  moved.page = page
  return moved
end

function T.browser_resolves_both_native_panes_in_every_paired_layout()
  local Interface = requirePresent("paired native pane placement")
  for _, class in ipairs({ "dual", "wide", "tall" }) do
    local set = Interface.browser()
    local session = ApplicationPresentation.new(set)
    local plan = session:resolve(measurementFor(class), sessionView(stubView()))
    Assert.notNil(plan, class .. " resolves a browser plan")
    local names = {}
    for _, pane in ipairs(plan.panes or {}) do
      names[#names + 1] = pane.id or pane.role
    end
    Assert.isTrue(#names >= 2, class .. " places both the information and controls panes")
  end
end

function T.compact_layout_keeps_every_grid_cell_and_selection_reachable()
  local Interface = requirePresent("complete compact information reflow")
  local set = Interface.browser()
  local session = ApplicationPresentation.new(set)
  local view = stubView()
  local plan = session:resolve(measurementFor("compact"), sessionView(view))
  Assert.notNil(plan, "the single-display layout resolves a compact plan")
  local compact = plan.content.pokedexCompact
  Assert.notNil(compact, "the compact plan publishes its one shared geometry record")
  local grid = assert(compact.grid, "the compact record carries its icon grid")
  Assert.equal(grid.columns, 5, "the compact grid keeps five columns")
  Assert.equal(grid.rows, 3, "the compact grid keeps three rows")
  Assert.equal(#grid.iconRects, 15, "the compact grid stages all fifteen icons")
  local expectedX, expectedY = { 0, 34, 68, 102, 136 }, { 22, 65, 108 }
  for index = 1, 15 do
    local rect = grid.iconRects[index]
    Assert.notNil(rect, "compact icon " .. index .. " carries its rectangle")
    local column = (index - 1) % 5
    local row = math.floor((index - 1) / 5)
    Assert.equal(rect.x, expectedX[column + 1], "compact icon " .. index .. " keeps its column")
    Assert.equal(rect.y, expectedY[row + 1], "compact icon " .. index .. " keeps its row")
    Assert.equal(rect.width, 32, "compact icon " .. index .. " keeps its width")
    Assert.equal(rect.height, 32, "compact icon " .. index .. " keeps its height")
    local tapped = session:mapInput(
      { hostTap(plan, "information", "pointer_down", rect.x + 16, rect.y + 16, 100) },
      sessionView(view)
    )
    session:mapInput(
      { hostTap(plan, "information", "pointer_up", rect.x + 16, rect.y + 16, 100) },
      sessionView(view)
    )
    Assert.equal(#tapped, 1, "compact icon " .. index .. " maps to exactly one command")
    Assert.equal(tapped[1].type, "activate", "compact icon " .. index .. " activates")
    Assert.equal(tapped[1].action, "grid-slot", "compact icon " .. index .. " selects its slot")
    Assert.equal(tapped[1].value, index - 1, "compact icon " .. index .. " selects its own slot")
  end
  local portrait = assert(compact.portraitRect, "the compact record carries its portrait")
  Assert.equal(portrait.x, 176, "the compact portrait keeps its left edge")
  Assert.equal(portrait.y, 48, "the compact portrait keeps its top edge")
  Assert.equal(portrait.width, 80, "the compact portrait keeps its width")
  Assert.equal(portrait.height, 80, "the compact portrait keeps its height")
  local footer = assert(compact.footer, "the compact record carries its action footer")
  Assert.isTrue(#footer.buttons >= 2, "the compact footer exposes its actions")
  local exitButton = nil
  for _, button in ipairs(footer.buttons) do
    if button.id == "exit" then
      exitButton = button
    end
  end
  Assert.notNil(exitButton, "the compact footer exposes its exit action")
  local exited = session:mapInput(
    { hostTap(plan, "controls", "pointer_down", exitButton.x + 2, exitButton.y + 2, 200) },
    sessionView(view)
  )
  session:mapInput(
    { hostTap(plan, "controls", "pointer_up", exitButton.x + 2, exitButton.y + 2, 200) },
    sessionView(view)
  )
  Assert.equal(#exited, 1, "the compact exit maps to exactly one command")
  Assert.equal(exited[1].type, "cancel", "the compact exit cancels")
end

function T.below_minimum_has_no_active_controls()
  local Interface = requirePresent("minimum-size unavailable policy")
  local set = Interface.browser()
  local session = ApplicationPresentation.new(set)
  local plan = session:resolve({
    width = 200,
    height = 160,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 200, height = 160 },
      touch = true,
      role = "world",
    }),
    pixelRatio = 1,
    signature = "pokedex-interface-test:tiny",
  }, sessionView(stubView()))
  if plan ~= nil then
    local mapped = session:mapInput(
      { { type = "pointer_down", x = 100, y = 80, pointerId = 1 } },
      sessionView(stubView())
    )
    Assert.equal(#mapped, 0, "a below-minimum plan exposes no active controls")
  else
    Assert.isNil(plan, "a below-minimum display resolves no browser plan")
  end
end

function T.layout_or_pointer_identity_changes_cancel_captured_input()
  local Interface = requirePresent("capture ownership across layout changes")
  local set = Interface.browser()
  local session = ApplicationPresentation.new(set)
  session:resolve(measurementFor("compact"), sessionView(stubView()))
  session:mapInput({ { type = "pointer_down", x = 8, y = 20, pointerId = 7 } }, sessionView(stubView()))
  session:cancelPointers()
  local mapped = session:mapInput(
    { { type = "pointer_up", x = 8, y = 20, pointerId = 7 } },
    sessionView(stubView())
  )
  Assert.equal(#mapped, 1, "a release after cancellation emits only the queued cancellation")
  Assert.equal(mapped[1].type, "pointer_cancel", "the queued event cancels the held press")
  Assert.equal(mapped[1].pointerId, 7, "cancellation names the captured pointer")
end

function T.registration_touch_reports_one_down_edge_and_no_up_action()
  local Interface = requirePresent("registration touch layout")
  local names = { dual = true, wide = true, tall = true, compact = true }
  for _, class in ipairs({ "dual", "wide", "tall", "compact" }) do
    Assert.isTrue(names[class] == true, "the registration layout covers the " .. class .. " case")
    local set = Interface.registration()
    local session = ApplicationPresentation.new(set)
    local plan = session:resolve(measurementFor(class), { view = { key = "card" }, assets = {} })
    Assert.notNil(plan, class .. " resolves a registration plan")
    local down = session:mapInput(
      { { type = "pointer_down", x = 128, y = 96, pointerId = 3 } },
      { view = { key = "card" }, assets = {} }
    )
    Assert.equal(#down, 1, class .. " registration down reports exactly one edge")
    Assert.equal(down[1].type, "touch_new", class .. " registration down opens the card")
    Assert.equal(down[1].pointerId, 3, class .. " registration down names its pointer")
    local up = session:mapInput(
      { { type = "pointer_up", x = 128, y = 96, pointerId = 3 } },
      { view = { key = "card" }, assets = {} }
    )
    Assert.equal(#up, 0, class .. " registration up reports no second activation")
  end
end

function T.native_fifth_column_selects_through_translated_host_coordinates()
  local Interface = requirePresent("native source list hitboxes on translated panes")
  local cells = {
    { lx = 30, ly = 10, slot = 0 },
    { lx = 200, ly = 20, slot = 4 },
    { lx = 220, ly = 110, slot = 14 },
  }
  for _, class in ipairs({ "dual", "wide", "tall" }) do
    local set = Interface.browser()
    local session = ApplicationPresentation.new(set)
    local view = stubView()
    local plan = session:resolve(measurementFor(class), sessionView(view))
    Assert.notNil(plan, class .. " resolves a paired browser plan")
    Assert.isNil(plan.content.pokedexCompact, class .. " keeps native geometry without a compact record")
    for _, cell in ipairs(cells) do
      local mapped = session:mapInput(
        { hostTap(plan, "controls", "pointer_down", cell.lx, cell.ly, 10) },
        sessionView(view)
      )
      session:mapInput(
        { hostTap(plan, "controls", "pointer_up", cell.lx, cell.ly, 10) },
        sessionView(view)
      )
      Assert.equal(#mapped, 1, class .. " maps cell " .. cell.slot .. " to exactly one command")
      Assert.equal(mapped[1].type, "activate", class .. " cell " .. cell.slot .. " activates")
      Assert.equal(mapped[1].action, "grid-slot", class .. " cell " .. cell.slot .. " selects")
      Assert.equal(mapped[1].value, cell.slot, class .. " cell " .. cell.slot .. " selects its own slot")
    end
  end
end

function T.information_pane_taps_never_actuate_controls()
  local Interface = requirePresent("pane-separated native hit testing")
  for _, class in ipairs({ "dual", "wide", "tall" }) do
    local set = Interface.browser()
    local session = ApplicationPresentation.new(set)
    local view = stubView()
    local plan = session:resolve(measurementFor(class), sessionView(view))
    for _, point in ipairs({ { 30, 40 }, { 200, 20 }, { 100, 100 } }) do
      local mapped = session:mapInput(
        { hostTap(plan, "information", "pointer_down", point[1], point[2], 20) },
        sessionView(view)
      )
      Assert.equal(
        #mapped,
        0,
        class .. " information taps at (" .. point[1] .. "," .. point[2] .. ") actuate no control"
      )
    end
  end
end

function T.cover_pointer_sequence_drives_the_source_drag_phases()
  local Interface = requirePresent("source cover swipe gestures")
  local set = Interface.browser()
  local session = ApplicationPresentation.new(set)
  local view = viewOn(stubView(), "cover")
  local plan = session:resolve(measurementFor("wide"), sessionView(view))
  local down = session:mapInput({ hostTap(plan, "controls", "pointer_down", 100, 100, 7) }, sessionView(view))
  Assert.equal(#down, 1, "the cover press begins exactly one gesture")
  Assert.equal(down[1].type, "drag", "the cover press drags")
  Assert.equal(down[1].target, "cover", "the cover press drags the cover")
  Assert.equal(down[1].phase, "begin", "the cover press begins the drag")
  local move = session:mapInput({ hostTap(plan, "controls", "pointer_move", 150, 100, 7) }, sessionView(view))
  Assert.equal(#move, 1, "the captured cover move continues the gesture")
  Assert.equal(move[1].phase, "move", "the captured move carries the move phase")
  Assert.equal(move[1].target, "cover", "the captured move stays on the cover")
  local up = session:mapInput({ hostTap(plan, "controls", "pointer_up", 190, 100, 7) }, sessionView(view))
  Assert.equal(#up, 1, "the cover release ends the gesture")
  Assert.equal(up[1].phase, "end", "the release ends the drag")
  Assert.equal(up[1].target, "cover", "the release stays on the cover")
end

function T.native_search_menu_hitboxes_follow_source_order_and_edges()
  local Interface = requirePresent("native search hitboxes")
  local set = Interface.browser()
  local session = ApplicationPresentation.new(set)
  local criteria = viewOn(stubView(), "search")
  criteria.search = { criteria = {}, focus = "order", previousColumn = "criteria" }
  local plan = session:resolve(measurementFor("wide"), sessionView(criteria))
  local function tapDown(lx, ly, pointerId)
    local mapped =
      session:mapInput({ hostTap(plan, "controls", "pointer_down", lx, ly, pointerId) }, sessionView(criteria))
    session:mapInput({ hostTap(plan, "controls", "pointer_up", lx, ly, pointerId) }, sessionView(criteria))
    return mapped
  end
  Assert.equal(#tapDown(20, 19, 30), 0, "the point outside every menu box opens no criterion")
  Assert.equal(#tapDown(120, 15, 31), 0, "the gap left of the first box opens no criterion")
  local first = tapDown(150, 15, 32)
  Assert.equal(#first, 1, "the first menu box maps to exactly one command")
  Assert.equal(first[1].type, "activate", "the first menu box activates")
  Assert.equal(first[1].action, "criterion", "the first menu box opens its criterion")
  Assert.equal(first[1].value, "order", "the first menu box opens the order criterion")
  local second = tapDown(90, 40, 33)
  Assert.equal(#second, 1, "the second menu box maps to exactly one command")
  Assert.equal(second[1].value, "letter", "the second menu box opens the letter criterion")
  local edge = tapDown(128, 8, 34)
  Assert.equal(#edge, 1, "the inclusive top-left edge still belongs to the first box")
  Assert.equal(edge[1].value, "order", "the inclusive edge keeps the first criterion")
  local bottomEdge = tapDown(215, 23, 35)
  Assert.equal(#bottomEdge, 1, "the inclusive bottom-right edge still belongs to the first box")
  Assert.equal(bottomEdge[1].value, "order", "the inclusive edge keeps the first criterion")
  Assert.equal(#tapDown(128, 24, 36), 0, "the row just below the first box opens no criterion")
  local run = tapDown(226, 23, 37)
  Assert.equal(#run, 1, "the run button maps to exactly one command")
  Assert.equal(run[1].action, "search-run", "the run button starts the search")
  local grid = viewOn(stubView(), "grid")
  local gridPlan = session:resolve(measurementFor("wide"), sessionView(grid))
  local function gridTap(lx, ly, pointerId)
    local mapped =
      session:mapInput({ hostTap(gridPlan, "controls", "pointer_down", lx, ly, pointerId) }, sessionView(grid))
    session:mapInput({ hostTap(gridPlan, "controls", "pointer_up", lx, ly, pointerId) }, sessionView(grid))
    return mapped
  end
  local footer = gridTap(20, 160, 38)
  Assert.equal(#footer, 1, "the list footer band maps to exactly one command")
  Assert.equal(footer[1].action, "page-prev", "the left footer box pages back")
  local footerEdge = gridTap(20, 187, 39)
  Assert.equal(#footerEdge, 1, "the inclusive footer bottom still pages")
  Assert.equal(footerEdge[1].action, "page-prev", "the inclusive edge keeps the footer action")
  Assert.equal(#gridTap(20, 188, 40), 0, "the row below the footer band stays inert")
  Assert.equal(#gridTap(65, 160, 41), 0, "the gap between footer boxes stays inert")
  Assert.equal(#gridTap(200, 160, 42), 1, "the right footer box maps to exactly one command")
end

function T.native_entry_tabs_use_narrow_source_bands()
  local Interface = requirePresent("native entry tabs")
  local set = Interface.browser()
  local session = ApplicationPresentation.new(set)
  local view = viewOn(stubView(), "area")
  local plan = session:resolve(measurementFor("wide"), sessionView(view))
  local function tapDown(lx, ly, pointerId)
    local mapped =
      session:mapInput({ hostTap(plan, "controls", "pointer_down", lx, ly, pointerId) }, sessionView(view))
    session:mapInput({ hostTap(plan, "controls", "pointer_up", lx, ly, pointerId) }, sessionView(view))
    return mapped
  end
  local cases = {
    { lx = 30, value = "area" },
    { lx = 100, value = "size" },
    { lx = 160, value = "forms" },
    { lx = 220, value = "return" },
  }
  for _, case in ipairs(cases) do
    local mapped = tapDown(case.lx, 180, 50)
    Assert.equal(#mapped, 1, "the tab at " .. case.lx .. " maps to exactly one command")
    Assert.equal(mapped[1].action, "entry-tab", "the tab strip switches tabs")
    Assert.equal(mapped[1].value, case.value, "the tab at " .. case.lx .. " selects its own page")
  end
  Assert.equal(#tapDown(7, 168, 51), 1, "the inclusive tab corner still switches")
  Assert.equal(#tapDown(57, 191, 52), 1, "the inclusive tab edge still switches")
  for _, lx in ipairs({ 60, 130, 190, 252 }) do
    Assert.equal(#tapDown(lx, 180, 53), 0, "the gap at " .. lx .. " switches no tab")
  end
  Assert.equal(#tapDown(100, 191, 54), 1, "the inclusive tab bottom still switches")
end

function T.native_area_circles_and_letter_cells_match_source_selection()
  local Interface = requirePresent("native area and letter hitboxes")
  local set = Interface.browser()
  local session = ApplicationPresentation.new(set)
  local area = viewOn(stubView(), "area")
  local areaPlan = session:resolve(measurementFor("wide"), sessionView(area))
  local function areaTap(lx, ly, pointerId)
    local mapped = session:mapInput(
      { hostTap(areaPlan, "controls", "pointer_down", lx, ly, pointerId) },
      sessionView(area)
    )
    session:mapInput({ hostTap(areaPlan, "controls", "pointer_up", lx, ly, pointerId) }, sessionView(area))
    return mapped
  end
  local circles = { { cx = 40, value = 0 }, { cx = 80, value = 1 }, { cx = 120, value = 2 } }
  for _, circle in ipairs(circles) do
    local mapped = areaTap(circle.cx, 32, 60)
    Assert.equal(#mapped, 1, "the daypart at " .. circle.cx .. " maps to exactly one command")
    Assert.equal(mapped[1].action, "area-time", "the daypart selects its time")
    Assert.equal(mapped[1].value, circle.value, "the daypart at " .. circle.cx .. " selects its own time")
    local edge = areaTap(circle.cx + 14, 32, 61)
    Assert.equal(#edge, 1, "the inclusive circle edge still selects its time")
    Assert.equal(edge[1].value, circle.value, "the circle edge keeps its own time")
  end
  Assert.equal(#areaTap(40 + 15, 32, 62), 0, "the pixel past the circle radius selects no time")
  local editor = viewOn(stubView(), "search")
  editor.search = {
    criteria = {},
    focus = "A",
    previousColumn = "criteria",
    editor = { criterion = "letter", kind = "letter", focus = "A" },
  }
  local editorPlan = session:resolve(measurementFor("wide"), sessionView(editor))
  local function editorTap(lx, ly, pointerId)
    local mapped = session:mapInput(
      { hostTap(editorPlan, "controls", "pointer_down", lx, ly, pointerId) },
      sessionView(editor)
    )
    session:mapInput({ hostTap(editorPlan, "controls", "pointer_up", lx, ly, pointerId) }, sessionView(editor))
    return mapped
  end
  local unrestricted = editorTap(8 + 16, 8 + 8, 63)
  Assert.equal(#unrestricted, 1, "the first letter cell maps to exactly one command")
  Assert.equal(unrestricted[1].action, "editor-choice", "the letter grid chooses")
  Assert.equal(unrestricted[1].value, "unrestricted", "the first letter cell clears the filter")
  local seventhColumn = editorTap(8 + 6 * 32 + 16, 8 + 8, 64)
  Assert.equal(#seventhColumn, 1, "the seventh letter column maps to exactly one command")
  Assert.equal(seventhColumn[1].value, "F", "the seventh column of the first row holds F")
  local lastRow = editorTap(8 + 5 * 32 + 16, 8 + 3 * 16 + 8, 65)
  Assert.equal(#lastRow, 1, "the last letter cell maps to exactly one command")
  Assert.equal(lastRow[1].value, "Z", "the last letter cell holds Z")
end

function T.native_option_editors_map_their_own_source_boxes()
  local Interface = requirePresent("native option editor hitboxes")
  local set = Interface.browser()
  local session = ApplicationPresentation.new(set)
  local function editorTap(kind, lx, ly, pointerId)
    local view = viewOn(stubView(), "search")
    view.search = {
      criteria = {},
      focus = kind,
      previousColumn = "criteria",
      editor = {
        criterion = kind,
        kind = kind,
        focus = nil,
        options = { "unrestricted", "normal", "fire" },
      },
    }
    local plan = session:resolve(measurementFor("wide"), sessionView(view))
    local mapped =
      session:mapInput({ hostTap(plan, "controls", "pointer_down", lx, ly, pointerId) }, sessionView(view))
    session:mapInput({ hostTap(plan, "controls", "pointer_up", lx, ly, pointerId) }, sessionView(view))
    return mapped
  end
  local orderFirst = editorTap("order", 150, 15, 70)
  Assert.equal(#orderFirst, 1, "the order editor maps its first box")
  Assert.equal(orderFirst[1].value, "numerical", "the first order box holds the numerical sort")
  Assert.equal(#editorTap("order", 20, 19, 71), 0, "the order editor leaves the menu gap inert")
  local typeFirst = editorTap("type", 40, 16, 72)
  Assert.equal(#typeFirst, 1, "the type editor maps its first box")
  Assert.equal(typeFirst[1].action, "editor-choice", "the type editor chooses")
  local shapeFirst = editorTap("shape", 52, 72, 73)
  Assert.equal(#shapeFirst, 1, "the shape editor maps its first cell")
  Assert.equal(shapeFirst[1].action, "editor-choice", "the shape editor chooses")
  local areaFirst = editorTap("area", 90, 16, 74)
  Assert.equal(#areaFirst, 1, "the area editor maps its first box")
  Assert.equal(areaFirst[1].action, "editor-choice", "the area editor chooses")
end

function T.captured_slider_target_survives_moves_outside_its_band()
  local Interface = requirePresent("captured slider routing")
  local set = Interface.browser()
  local session = ApplicationPresentation.new(set)
  local slider = viewOn(stubView(), "search")
  slider.search = {
    criteria = {},
    focus = "height",
    previousColumn = "criteria",
    editor = { criterion = "height", kind = "height", endpoint = "min" },
  }
  slider.capturedSliderTarget = "height-min"
  local plan = session:resolve(measurementFor("wide"), sessionView(slider))
  local function send(eventType, lx, ly, pointerId)
    return session:mapInput(
      { hostTap(plan, "controls", eventType, lx, ly, pointerId) },
      sessionView(slider)
    )
  end
  local begin = send("pointer_down", 20, 48, 80)
  Assert.equal(#begin, 1, "the press on the minimum track begins exactly one gesture")
  Assert.equal(begin[1].target, "height-min", "the press captures the minimum endpoint")
  Assert.equal(begin[1].phase, "begin", "the press begins the drag")
  local otherBand = send("pointer_move", 100, 88, 80)
  Assert.equal(#otherBand, 1, "a move over the other band still reports the gesture")
  Assert.equal(otherBand[1].target, "height-min", "the move keeps the captured minimum")
  Assert.equal(otherBand[1].phase, "move", "the move keeps the move phase")
  local emptyBand = send("pointer_move", 100, 120, 80)
  Assert.equal(#emptyBand, 1, "a move over empty space still reports the gesture")
  Assert.equal(emptyBand[1].target, "height-min", "empty space keeps the captured minimum")
  local release = send("pointer_up", 100, 120, 80)
  Assert.equal(#release, 1, "a release over empty space ends exactly one gesture")
  Assert.equal(release[1].target, "height-min", "the release ends the captured minimum")
  Assert.equal(release[1].phase, "end", "the release ends the drag")
  local fresh = viewOn(stubView(), "search")
  fresh.search = slider.search
  local freshPlan = session:resolve(measurementFor("wide"), sessionView(fresh))
  local stray = session:mapInput(
    { hostTap(freshPlan, "controls", "pointer_up", 100, 120, 81) },
    sessionView(fresh)
  )
  Assert.equal(#stray, 0, "a release with no capture maps to nothing")
end

---@param width number host width behind the single-display measurement
---@param height number host height behind the single-display measurement
---@param safe table<string, number>? safe rectangle inside the surface, defaulting to the full rect
---@param pixelRatio number? framebuffer pixels per host unit, defaulting to 1
---@return table<string, unknown> measured single-display facts for compact fitting
local function fittedMeasurement(width, height, safe, pixelRatio)
  local rect = { x = 0, y = 0, width = width, height = height }
  local surface = {
    id = "main",
    rect = rect,
    touch = true,
    role = "world",
  }
  if safe ~= nil then
    surface.safeRect = { x = safe.x, y = safe.y, width = safe.width, height = safe.height }
  end
  return {
    width = width,
    height = height,
    topology = ScreenTopology.oneDisplay(surface),
    pixelRatio = pixelRatio or 1,
    signature = "pokedex-interface-test:fitted-" .. width .. "x" .. height,
  }
end

---@return table<string, unknown> grid projection with paging, cursor, and seen states
local function gridFixture()
  local entries = {}
  for slot = 1, 15 do
    entries[slot] = { species = "SEEN" .. slot, seen = true, caught = slot <= 4 }
  end
  return {
    key = "fitted-generation",
    mode = "johto",
    page = "grid",
    selection = { species = "SEEN1", dexNumber = 1, seen = true, caught = true, language = "english" },
    counts = { seen = 15, caught = 4 },
    grid = {
      page = 0,
      lastPage = 3,
      cursor = 0,
      buffers = { { entries = entries } },
    },
  }
end

---@param plan table<string, unknown> resolved application plan
---@param paneId string browser pane identity
---@return table pane placement behind the plan
local function placementOf(plan, paneId)
  for _, pane in ipairs(plan.panes or {}) do
    if type(pane) == "table" and pane.id == paneId then
      return assert(pane.placement, "browser panes carry their placement")
    end
  end
  error("the resolved plan carries no " .. paneId .. " pane", 0)
end

function T.compact_parent_centers_at_the_largest_integer_scale()
  local Interface = requirePresent("centered integer compact fitting")
  local set = Interface.browser()
  local session = ApplicationPresentation.new(set)
  local view = sessionView(gridFixture())
  local filling = session:resolve(fittedMeasurement(512, 384), view)
  local fillingInfo = placementOf(filling, "information")
  local fillingControls = placementOf(filling, "controls")
  Assert.equal(fillingInfo.scale, 2, "a 512x384 display fits the compact parent at 2x")
  Assert.equal(fillingInfo.frame.x, 0, "a filling 2x parent starts at the left edge")
  Assert.equal(fillingInfo.frame.y, 0, "a filling 2x parent starts at the top edge")
  Assert.equal(fillingInfo.frame.width, 512, "a filling 2x information pane spans the display width")
  Assert.equal(fillingInfo.frame.height, 336, "a filling 2x information pane keeps 168 logical rows")
  Assert.equal(fillingControls.scale, 2, "the footer shares the parent integer scale")
  Assert.equal(fillingControls.frame.x, 0, "the footer shares the parent horizontal offset")
  Assert.equal(
    fillingControls.frame.y,
    336,
    "the footer starts exactly below the information pane"
  )
  Assert.equal(fillingControls.frame.height, 48, "the footer keeps 24 logical rows")
  local letterboxed = session:resolve(fittedMeasurement(640, 480), view)
  local boxedInfo = placementOf(letterboxed, "information")
  local boxedControls = placementOf(letterboxed, "controls")
  Assert.equal(boxedInfo.scale, 2, "a 640x480 display still fits the compact parent at 2x")
  Assert.equal(boxedInfo.frame.x, 64, "a 640x480 parent centers with horizontal margins")
  Assert.equal(boxedInfo.frame.y, 48, "a 640x480 parent centers with vertical margins")
  Assert.equal(boxedControls.scale, 2, "the letterboxed footer shares the parent scale")
  Assert.equal(boxedControls.frame.x, 64, "the letterboxed footer shares the parent offset")
  Assert.equal(boxedControls.frame.y, 48 + 336, "the letterboxed footer stays below information")
  local compact = assert(
    letterboxed.content.pokedexCompact,
    "the fitted plan publishes its one shared geometry record"
  )
  local footer = assert(compact.footer, "the compact record carries its footer")
  local middle = nil
  for _, button in ipairs(footer.buttons) do
    if type(button) == "table" and button.x <= 128 and 128 < button.x + button.width then
      middle = button
    end
  end
  local center = assert(middle, "the footer exposes its center action")
  local tapped = session:mapInput(
    { hostTap(letterboxed, "controls", "pointer_down", center.x + center.width / 2, center.y + 1, 300) },
    view
  )
  session:mapInput(
    { hostTap(letterboxed, "controls", "pointer_up", center.x + center.width / 2, center.y + 1, 300) },
    view
  )
  Assert.equal(#tapped, 1, "a tap at the drawn footer center maps through the shared record")
  local missed = session:mapInput({ { type = "pointer_down", x = 10, y = 10, pointerId = 301 } }, view)
  Assert.equal(#missed, 0, "a host press outside the centered content maps to no control")
end

function T.compact_parent_honors_safe_area_and_unfit_selects_no_controls()
  local Interface = requirePresent("safe-area compact fitting")
  local set = Interface.browser()
  local session = ApplicationPresentation.new(set)
  local view = sessionView(gridFixture())
  local offset = session:resolve(fittedMeasurement(340, 264, { x = 20, y = 12, width = 300, height = 240 }), view)
  local info = placementOf(offset, "information")
  local controls = placementOf(offset, "controls")
  Assert.equal(info.scale, 1, "a 300x240 safe area fits the compact parent at 1x")
  Assert.equal(info.frame.x, 42, "the parent centers inside the safe horizontal bounds")
  Assert.equal(info.frame.y, 36, "the parent centers inside the safe vertical bounds")
  Assert.equal(controls.frame.x, 42, "the safe-area footer shares the parent offset")
  Assert.equal(controls.frame.y, 36 + 168, "the safe-area footer stays below information")
  local tiny = session:resolve(fittedMeasurement(240, 200, { x = 20, y = 20, width = 200, height = 160 }), view)
  Assert.notNil(tiny, "an unfit display still resolves a plan")
  Assert.equal(#(tiny.panes or {}), 0, "an unfit display publishes no interactive panes")
  local mapped = session:mapInput({ { type = "pointer_down", x = 100, y = 80, pointerId = 302 } }, view)
  Assert.equal(#mapped, 0, "an unfit display exposes no active controls")
  for _, class in ipairs({ "dual", "wide", "tall" }) do
    local native = session:resolve(measurementFor(class), sessionView(gridFixture()))
    Assert.isNil(
      native.content.pokedexCompact,
      class .. " keeps native geometry without a compact record"
    )
    Assert.notNil(native.panes, class .. " keeps its paired panes")
    Assert.equal(#native.panes, 2, class .. " keeps both native panes")
  end
end

function T.compact_footer_buttons_carry_one_shared_visible_record()
  local Interface = requirePresent("single-record compact actions")
  local set = Interface.browser()
  local session = ApplicationPresentation.new(set)
  local view = sessionView(gridFixture())
  local plan = session:resolve(measurementFor("compact"), view)
  local compact = assert(plan.content.pokedexCompact, "the compact plan publishes its geometry record")
  local footer = assert(compact.footer, "the compact record carries its footer")
  Assert.isTrue(#footer.buttons >= 7, "the grid footer exposes every grid action")
  local seenIds = {}
  for _, button in ipairs(footer.buttons) do
    Assert.isTrue(button.enabled ~= nil, "footer action " .. button.id .. " declares its enablement")
    Assert.isTrue(
      button.labelRole ~= nil or button.iconRole ~= nil,
      "footer action " .. button.id .. " names its visible mark"
    )
    Assert.isTrue(seenIds[button.id] == nil, "footer action " .. button.id .. " appears once")
    seenIds[button.id] = true
    local tapped = session:mapInput(
      { hostTap(plan, "controls", "pointer_down", button.x + 1, button.y + 1, 400) },
      view
    )
    session:mapInput(
      { hostTap(plan, "controls", "pointer_up", button.x + 1, button.y + 1, 400) },
      view
    )
    if button.enabled == true then
      Assert.equal(#tapped, 1, "enabled footer action " .. button.id .. " maps at its drawn rectangle")
    else
      Assert.equal(#tapped, 0, "disabled footer action " .. button.id .. " maps to no command")
    end
  end
  local firstPage = sessionView(gridFixture())
  local firstPlan = session:resolve(measurementFor("compact"), firstPage)
  local firstCompact = assert(firstPlan.content.pokedexCompact, "the first page publishes its record")
  local prevButton = nil
  for _, button in ipairs(firstCompact.footer.buttons) do
    if button.id == "page-prev" then
      prevButton = button
    end
  end
  Assert.notNil(prevButton, "the grid footer exposes its previous-page action")
  Assert.isFalse(prevButton.enabled, "the previous-page action is disabled on page zero")
  local prevTap = session:mapInput(
    { hostTap(firstPlan, "controls", "pointer_down", prevButton.x + 1, prevButton.y + 1, 401) },
    firstPage
  )
  session:mapInput(
    { hostTap(firstPlan, "controls", "pointer_up", prevButton.x + 1, prevButton.y + 1, 401) },
    firstPage
  )
  Assert.equal(#prevTap, 0, "the disabled previous-page action stays semantically inert")
end

function T.compact_rows_stay_inside_the_information_pane()
  local Interface = requirePresent("bounded compact rows")
  local set = Interface.browser()
  local session = ApplicationPresentation.new(set)
  local search = gridFixture()
  search.page = "search"
  search.search = { criteria = {}, focus = "order", previousColumn = "criteria" }
  local plan = session:resolve(measurementFor("compact"), sessionView(search))
  local compact = assert(plan.content.pokedexCompact, "the search plan publishes its geometry record")
  Assert.isTrue(#compact.rows >= 7, "the search plan exposes every criterion row")
  for _, row in ipairs(compact.rows) do
    Assert.isTrue(row.enabled ~= nil, "search row declares its enablement")
    Assert.isTrue(
      row.rect.y + row.rect.height <= 168,
      "search row stays inside the 168px information pane"
    )
    Assert.isTrue(
      row.labelRole ~= nil or row.iconRole ~= nil or row.valueRole ~= nil,
      "search row names its visible content"
    )
    local tapped = session:mapInput(
      {
        hostTap(
          plan,
          "information",
          "pointer_down",
          row.rect.x + 1,
          row.rect.y + 1,
          500
        ),
      },
      sessionView(search)
    )
    session:mapInput(
      { hostTap(plan, "information", "pointer_up", row.rect.x + 1, row.rect.y + 1, 500) },
      sessionView(search)
    )
    if row.enabled == true then
      Assert.equal(#tapped, 1, "an enabled search row maps at its drawn rectangle")
    else
      Assert.equal(#tapped, 0, "a disabled search row maps to no command")
    end
  end
  local below = session:mapInput(
    { hostTap(plan, "information", "pointer_down", 20, 165, 501) },
    sessionView(search)
  )
  session:mapInput({ hostTap(plan, "information", "pointer_up", 20, 165, 501) }, sessionView(search))
  local covered = false
  for _, row in ipairs(compact.rows) do
    if 165 >= row.rect.y and 165 < row.rect.y + row.rect.height then
      covered = true
    end
  end
  if not covered then
    Assert.equal(#below, 0, "an information tap below every row maps to no command")
  end
end

function T.compact_disabled_editor_choice_row_maps_to_no_command()
  local Interface = requirePresent("disabled editor-choice inertness")
  local set = Interface.browser()
  local session = ApplicationPresentation.new(set)
  local search = viewOn(gridFixture(), "search")
  search.search = {
    criteria = {},
    focus = "area",
    previousColumn = "criteria",
    editor = {
      criterion = "area",
      kind = "area",
      focus = nil,
      options = { "unrestricted", "johto", "kanto", "unknown" },
      choices = {
        unrestricted = { enabled = true },
        johto = { enabled = true },
        kanto = { enabled = false },
        unknown = { enabled = true },
      },
    },
  }
  local plan = session:resolve(measurementFor("compact"), sessionView(search))
  local compact = assert(plan.content.pokedexCompact, "the editor plan publishes its geometry record")
  local locked, open = nil, nil
  for _, row in ipairs(compact.rows) do
    if type(row) == "table" and row.action == "editor-choice" then
      if row.value == "kanto" then
        locked = row
      elseif row.value == "johto" then
        open = row
      end
    end
  end
  Assert.notNil(locked, "the locked kanto scope stages its editor row")
  Assert.isFalse(locked.enabled, "the locked kanto scope stages disabled")
  Assert.notNil(open, "an unlocked scope stages its editor row")
  local lockedTap = session:mapInput(
    { hostTap(plan, "information", "pointer_down", locked.rect.x + 1, locked.rect.y + 1, 510) },
    sessionView(search)
  )
  session:mapInput(
    { hostTap(plan, "information", "pointer_up", locked.rect.x + 1, locked.rect.y + 1, 510) },
    sessionView(search)
  )
  Assert.equal(#lockedTap, 0, "a disabled editor-choice row maps to no command")
  local openTap = session:mapInput(
    { hostTap(plan, "information", "pointer_down", open.rect.x + 1, open.rect.y + 1, 511) },
    sessionView(search)
  )
  session:mapInput(
    { hostTap(plan, "information", "pointer_up", open.rect.x + 1, open.rect.y + 1, 511) },
    sessionView(search)
  )
  Assert.equal(#openTap, 1, "an enabled editor-choice row still maps at its drawn rectangle")
  Assert.equal(openTap[1].action, "editor-choice", "the enabled row keeps its editor choice")
  Assert.equal(openTap[1].value, "johto", "the enabled row keeps its own scope")
end

function T.events_without_a_known_pane_identity_map_to_no_command()
  local Interface = requirePresent("trusted pane identity mapping")
  local set = Interface.browser()
  local session = ApplicationPresentation.new(set)
  local view = stubView()
  local plan = session:resolve(measurementFor("wide"), sessionView(view))
  Assert.isNil(
    plan.mapInput({ type = "pointer_down", x = 30, y = 10 }, view, plan),
    "a pointer without pane identity maps to no command"
  )
  Assert.isNil(
    plan.mapInput({ type = "pointer_down", x = 30, y = 10, paneId = "unknown" }, view, plan),
    "a pointer with an unknown pane maps to no command"
  )
end

return { tests = T }
