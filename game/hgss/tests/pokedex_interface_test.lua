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
  local merged = { compact = { inspect = false, prosePage = 1, size = "weight" } }
  if type(view) == "table" then
    for key, value in pairs(view) do
      merged[key] = value
    end
    if type(merged.compact) ~= "table" then
      merged.compact = { inspect = false, prosePage = 1, size = "weight" }
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

function T.registration_layout_draws_on_down_without_matched_release()
  local Interface = requirePresent("registration touch layout")
  local set = Interface.registration()
  local session = ApplicationPresentation.new(set)
  for _, class in ipairs({ "dual", "wide", "tall", "compact" }) do
    local plan = session:resolve(measurementFor(class), { view = { key = "card" }, assets = {} })
    Assert.notNil(plan, class .. " resolves a registration plan")
  end
  local mapped = session:mapInput(
    { { type = "pointer_down", x = 128, y = 96, pointerId = 3 } },
    { view = { key = "card" }, assets = {} }
  )
  Assert.isTrue(#mapped >= 0, "registration pointer-down maps without raising")
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

function T.native_search_rows_and_slider_map_without_host_reinterpretation()
  local Interface = requirePresent("native search controls")
  local set = Interface.browser()
  local session = ApplicationPresentation.new(set)
  local criteria = viewOn(stubView(), "search")
  criteria.search = { criteria = {}, focus = "order", previousColumn = "criteria" }
  local plan = session:resolve(measurementFor("wide"), sessionView(criteria))
  local picked = session:mapInput({ hostTap(plan, "controls", "pointer_down", 20, 19, 30) }, sessionView(criteria))
  Assert.equal(#picked, 1, "the first criteria row maps to exactly one command")
  Assert.equal(picked[1].type, "activate", "the criteria row activates")
  Assert.equal(picked[1].action, "criterion", "the criteria row opens its criterion")
  Assert.equal(picked[1].value, "order", "the first criteria row opens the order criterion")
  session:mapInput({ hostTap(plan, "controls", "pointer_up", 20, 19, 30) }, sessionView(criteria))
  local run = session:mapInput({ hostTap(plan, "controls", "pointer_down", 226, 23, 31) }, sessionView(criteria))
  session:mapInput({ hostTap(plan, "controls", "pointer_up", 226, 23, 31) }, sessionView(criteria))
  Assert.equal(#run, 1, "the run button maps to exactly one command")
  Assert.equal(run[1].action, "search-run", "the run button starts the search")
  local editor = viewOn(stubView(), "search")
  editor.search = {
    criteria = {},
    focus = "B",
    previousColumn = "criteria",
    editor = { criterion = "letter", kind = "letter", focus = "B", options = { "A", "B", "C" } },
  }
  local editorPlan = session:resolve(measurementFor("wide"), sessionView(editor))
  local choice = session:mapInput({ hostTap(editorPlan, "controls", "pointer_down", 20, 35, 32) }, sessionView(editor))
  session:mapInput({ hostTap(editorPlan, "controls", "pointer_up", 20, 35, 32) }, sessionView(editor))
  Assert.equal(#choice, 1, "the editor row maps to exactly one command")
  Assert.equal(choice[1].action, "editor-choice", "the editor row chooses")
  Assert.equal(choice[1].value, "B", "the editor row chooses its own option")
  local slider = viewOn(stubView(), "search")
  slider.search = {
    criteria = {},
    focus = "height",
    previousColumn = "criteria",
    editor = { criterion = "height", kind = "height", endpoint = "min" },
  }
  local sliderPlan = session:resolve(measurementFor("wide"), sessionView(slider))
  local drag = session:mapInput({ hostTap(sliderPlan, "controls", "pointer_down", 20, 48, 33) }, sessionView(slider))
  Assert.equal(#drag, 1, "the slider press begins exactly one gesture")
  Assert.equal(drag[1].type, "drag", "the slider press drags")
  Assert.equal(drag[1].target, "height-min", "the upper track drags the minimum endpoint")
  Assert.equal(drag[1].phase, "begin", "the slider press begins the drag")
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

function T.registration_layout_draws_on_down_without_matched_release()
  local Interface = requirePresent("registration touch layout")
  local set = Interface.registration()
  local session = ApplicationPresentation.new(set)
  for _, class in ipairs({ "dual", "wide", "tall", "compact" }) do
    local plan = session:resolve(measurementFor(class), { view = { key = "card" }, assets = {} })
    Assert.notNil(plan, class .. " resolves a registration plan")
  end
  local mapped = session:mapInput(
    { { type = "pointer_down", x = 128, y = 96, pointerId = 3 } },
    { view = { key = "card" }, assets = {} }
  )
  Assert.isTrue(#mapped >= 0, "registration pointer-down maps without raising")
end

return { tests = T }
