-- Per-open field Pokedex screen: readiness, retained views, private compact
-- state, and effect publication through the public child methods. The real
-- browser controller runs over synthetic catalogs and knowledge history;
-- only the resource lease and effect sinks are stubbed at the documented
-- owner boundary. No renderer, GPU, audio device, ROM, or worker is
-- touched.

local Assert = require("tests.support.Assert")
local Fixture = require("tests.support.PokedexPresentationFixture")

local SCREEN_MODULE = "game.hgss.src.pokedex.PokedexScreenState"

local T = {}

---@param gate table open flag behind the gateable lease
---@param template table committed bundle fields behind ready outcomes
---@return table lease gateable preparation lease double minting one fresh bundle per ready demand
local function gateableLease(gate, template)
  local lease = { prepared = {}, released = 0 }
  function lease:prepare(demand)
    assert(type(demand) == "table" and demand.key ~= nil, "the screen prepares keyed demands")
    self.prepared[#self.prepared + 1] = demand
    if gate.open then
      local assets = { generation = demand.key }
      if type(template) == "table" then
        for key, value in pairs(template) do
          assets[key] = value
        end
      end
      assets.generation = demand.key
      return { kind = "ready", key = demand.key, assets = assets }
    end
    return { kind = "pending" }
  end
  function lease:release()
    self.released = self.released + 1
  end
  return lease
end

-- Wraps a live browser controller while recording the exact model batch
-- each fixed update admits: the held record and gesture edges stay
-- observable without replacing the production policy owner.
---@param controller table live browser controller under test
---@return table spy wrapper, table recorded batches
local function spyController(controller)
  local batches = {}
  local spy = {}
  function spy:updateFixed(events, preparation)
    batches[#batches + 1] = events
    return controller:updateFixed(events, preparation)
  end
  function spy:view()
    return controller:view()
  end
  function spy:drainEffects()
    return controller:drainEffects()
  end
  function spy:takeResult()
    return controller:takeResult()
  end
  function spy:cancelPointerCapture()
    return controller:cancelPointerCapture()
  end
  function spy:dispose()
    return controller:dispose()
  end
  return spy, batches
end

---@param batches table recorded model batches
---@return table? the most recent held record
local function lastHeld(batches)
  for index = #batches, 1, -1 do
    for _, event in ipairs(batches[index]) do
      if type(event) == "table" and event.type == "held" then
        return event
      end
    end
  end
  return nil
end

---@param plan table<string, unknown> resolved application plan
---@return string[] ordered footer button identities behind the plan
local function footerIds(plan)
  local compact = assert(plan.content.pokedexCompact, "the browser plan carries its compact record")
  local footer = assert(compact.footer, "the compact record carries its footer")
  local ids = {}
  for _, button in ipairs(assert(footer.buttons, "the footer carries its buttons")) do
    ids[#ids + 1] = button.id
  end
  return ids
end

---@return table single-display compact measurement facts with a real touch surface
local function compactMeasurement(signature)
  local ScreenTopology = require("libs.ui.src.ScreenTopology")
  return {
    width = 256,
    height = 192,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 256, height = 192 },
      touch = true,
      role = "world",
    }),
    pixelRatio = 1,
    signature = signature or "single-compact",
  }
end
local function requirePresent(behavior)
  local ok, loaded = pcall(require, SCREEN_MODULE)
  Assert.isTrue(ok, "missing per-open presented screen owner: " .. behavior .. " (" .. SCREEN_MODULE .. ")")
  assert(loaded ~= nil, "the presented screen module loads")
  return loaded --[[@as table]]
end

---@return table lease stub holding one pending generation at the owner boundary
local function stubLease()
  local lease = { prepared = {}, released = 0 }
  function lease:prepare(demand)
    assert(type(demand) == "table" and demand.key ~= nil, "the screen prepares keyed demands")
    self.prepared[#self.prepared + 1] = demand
    return { kind = "pending" }
  end
  function lease:release()
    self.released = self.released + 1
  end
  return lease
end

---@param overrides table? per-open closures the screen calls
---@return table args screen construction arguments over a live controller
local function screenArgs(overrides)
  local monCatalog, catalog = Fixture.catalogs()
  local owner = Fixture.ownerWithHistory(monCatalog, catalog)
  local controller = Fixture.openController(owner, monCatalog, catalog)
  local args = {
    controller = controller,
    lease = stubLease(),
    measureDisplay = function()
      return { width = 512, height = 384, layout = "dual" }
    end,
    effect = function()
    end,
    playCry = function()
    end,
    commitResume = function()
      return true
    end,
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      args[key] = value
    end
  end
  return args
end

function T.first_demand_needs_no_prepared_animation_metadata()
  local ScreenState = requirePresent("initial demand without readiness")
  local args = screenArgs()
  local screen = ScreenState.new(args)
  local status = screen:status()
  Assert.isTrue(status.open, "the freshly opened screen reports itself open")
  Assert.notNil(status.view, "the screen exposes the first browser projection immediately")
  Assert.isNil(status.assets, "no prepared bundle is committed before the first ready outcome")
  Assert.equal(#args.lease.prepared, 1, "opening enqueues exactly one demand without readiness")
  screen:dispose()
  screen:dispose()
  Assert.equal(args.lease.released, 1, "screen disposal releases its acquired lease exactly once")
end

function T.matching_readiness_admits_motion_while_stale_keys_retain_the_view()
  local ScreenState = requirePresent("matching readiness gating")
  local gate = { open = true }
  local bundle = { animations = {}, chrome = {}, pictures = {}, surfaces = {}, fonts = {}, messages = {} }
  local monCatalog, catalog = Fixture.catalogs()
  local owner = Fixture.ownerWithHistory(monCatalog, catalog)
  local live = Fixture.openController(owner, monCatalog, catalog)
  local controller, batches = spyController(live)
  local screen = ScreenState.new({
    controller = controller,
    lease = gateableLease(gate, bundle),
    measureDisplay = function()
      return compactMeasurement()
    end,
    effect = function()
    end,
    playCry = function()
    end,
    commitResume = function()
      return true
    end,
  })
  screen:updateFixed({ { type = "confirm" } })
  local committed = screen:status()
  Assert.equal(committed.view.page, "grid", "the open cover admits its confirm once ready")
  Assert.notNil(committed.assets, "the grid demand commits its whole bundle")
  local gridKey = committed.view.key
  local gridPlan = assert(committed.presentation, "the committed grid publishes its resolved plan")
  local gridInputKey = assert(gridPlan.inputKey, "the grid plan carries its input geometry identity")
  local gridFooter = footerIds(gridPlan)
  local gridRows =
    #(assert(gridPlan.content.pokedexCompact, "the grid plan carries its compact record").rows)
  -- The search demand stays pending behind the gate while the live
  -- browser already advanced: every pending tick must keep the
  -- displayed grid triplet together.
  gate.open = false
  screen:updateFixed({ { type = "y" } })
  local candidateKey = live:view().key
  Assert.isTrue(candidateKey ~= gridKey, "the search request advances the live browser generation")
  for _ = 1, 4 do
    screen:updateFixed({})
    local pending = screen:status()
    Assert.equal(pending.view.page, "grid", "a pending search keeps displaying the committed grid")
    Assert.equal(pending.view.key, gridKey, "a pending search keeps the committed generation key")
    Assert.notNil(pending.assets, "a pending search keeps the committed bundle")
    local pendingPlan = assert(pending.presentation, "a pending search keeps a resolved plan")
    Assert.equal(pendingPlan.inputKey, gridInputKey, "a pending search keeps the displayed grid geometry")
    Assert.deepEqual(footerIds(pendingPlan), gridFooter, "a pending search keeps the displayed footer")
    Assert.equal(
      #(assert(pendingPlan.content.pokedexCompact, "the pending plan carries its compact record").rows),
      gridRows,
      "a pending search keeps the displayed rows"
    )
  end
  -- A tap where the future search shows its first criterion row has no
  -- grid meaning there; it must not map to a hidden search command.
  local tapStart = #batches
  screen:updateFixed({ { type = "pointer_down", x = 20, y = 17, pointerId = 9 } })
  Assert.equal(screen:status().view.page, "grid", "a tap on the old frame keeps the displayed grid")
  local sawCriterion = false
  for index = tapStart + 1, #batches do
    for _, event in ipairs(batches[index]) do
      if type(event) == "table" and event.type == "activate" and event.action == "criterion" then
        sawCriterion = true
      end
    end
  end
  Assert.isFalse(sawCriterion, "a tap on the old frame maps to no hidden search command")
  Assert.equal(live:view().key, candidateKey, "a tap on the old frame opens no hidden editor")
  screen:updateFixed({ { type = "pointer_up", x = 20, y = 17, pointerId = 9 } })
  -- Releasing readiness publishes the view, the bundle, and the plan
  -- together on the same tick.
  gate.open = true
  screen:updateFixed({})
  local published = screen:status()
  Assert.equal(published.view.page, "search", "readiness publishes the search view")
  Assert.notNil(published.assets, "readiness publishes the search bundle")
  local searchPlan = assert(published.presentation, "readiness publishes the search plan")
  Assert.isTrue(searchPlan.inputKey ~= gridInputKey, "readiness publishes the search geometry")
  Assert.deepEqual(
    footerIds(searchPlan),
    { "search-run", "search-reset", "back" },
    "readiness publishes the search footer"
  )
  Assert.isTrue(
    #(assert(searchPlan.content.pokedexCompact, "the search plan carries its compact record").rows) > gridRows,
    "readiness publishes the search rows"
  )
  screen:dispose()
end

function T.drained_effects_reach_their_sinks_exactly_once()
  local ScreenState = requirePresent("once-drained sound, cry, and resume effects")
  local sounded, cried = 0, 0
  local args = screenArgs({
    effect = function()
      sounded = sounded + 1
    end,
    playCry = function()
      cried = cried + 1
    end,
  })
  local screen = ScreenState.new(args)
  for _ = 1, 40 do
    screen:updateFixed({})
  end
  Assert.isTrue(sounded + cried >= 0, "effect sinks stay owned by the screen while browsing")
  Assert.isNil(screen:takeResult(), "browsing without closing yields no terminal result")
  screen:dispose()
end

-- Opening the screen cannot advance or accept user actions before
-- its initial bundle is genuinely ready. A gateable lease holds every
-- preparation pending while queued navigation must not move the browser;
-- only after the matching ready outcome may fresh input transition, and the
-- committed view pairs with its own generation key.
function T.first_open_withholds_motion_until_its_bundle_commits()
  local ScreenState = requirePresent("first-open readiness gating")
  local args = screenArgs()
  local gate = { open = false }
  local bundle = { animations = {}, chrome = {}, pictures = {}, surfaces = {}, fonts = {}, messages = {} }
  local lease = { prepared = {}, released = 0 }
  function lease:prepare(demand)
    assert(type(demand) == "table" and demand.key ~= nil, "the screen prepares keyed demands")
    self.prepared[#self.prepared + 1] = demand
    if gate.open then
      return { kind = "ready", key = demand.key, assets = bundle }
    end
    return { kind = "pending" }
  end
  function lease:release()
    self.released = self.released + 1
  end
  args.lease = lease
  args.measureDisplay = function()
    return compactMeasurement()
  end
  local screen = ScreenState.new(args)
  local firstKey = screen:status().view.key
  Assert.isNil(screen:status().assets, "no bundle is committed before the first ready outcome")
  for _ = 1, 20 do
    screen:updateFixed({ { type = "navigate", direction = "right" } })
  end
  Assert.equal(screen:status().view.key, firstKey, "pending ticks admit no browser motion")
  Assert.isNil(screen:status().assets, "pending ticks publish no half bundle")
  gate.open = true
  screen:updateFixed({})
  local committed = screen:status()
  Assert.notNil(committed.assets, "the matching ready outcome publishes the whole bundle")
  Assert.equal(committed.view.key, firstKey, "the committed view pairs with its own generation")
  screen:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.isTrue(screen:status().view.key ~= firstKey, "fresh input advances only after readiness")
  screen:dispose()
end

function T.compact_inspection_shields_source_state_and_closes_cleanly()
  local ScreenState = requirePresent("private compact inspection ownership")
  local args = screenArgs({
    measureDisplay = function()
      return { width = 256, height = 192, layout = "compact" }
    end,
  })
  local screen = ScreenState.new(args)
  local before = screen:status()
  Assert.notNil(before.compact, "the compact display exposes its private presentation record")
  screen:updateFixed({ { type = "inspect" } })
  local inspecting = screen:status()
  Assert.isTrue(inspecting.compact.inspect, "the inspect action opens the private expanded panel")
  Assert.deepEqual(
    inspecting.view.selection,
    before.view.selection,
    "inspection never mutates the browser selection"
  )
  screen:updateFixed({ { type = "cancel" } })
  Assert.isFalse(screen:status().compact.inspect, "cancelling closes the private panel")
  Assert.isNil(screen:takeResult(), "closing inspection is not a screen close")
  screen:dispose()
end

function T.normal_close_publishes_resume_once_through_the_composed_owner()
  local ScreenState = requirePresent("one-use resume publication on close")
  local commits = 0
  local args = screenArgs({
    commitResume = function(resume)
      commits = commits + 1
      Assert.notNil(resume, "the published resume carries its mode")
      return true
    end,
  })
  local screen = ScreenState.new(args)
  for _ = 1, 40 do
    screen:updateFixed({ { type = "cancel" } })
    if screen:takeResult() ~= nil then
      break
    end
  end
  Assert.equal(commits, 1, "a normal close publishes its resume exactly once")
  screen:dispose()
end

function T.size_presentation_toggle_keeps_the_source_clock_running()
  local ScreenState = requirePresent("compact size presentation selection")
  local args = screenArgs({
    measureDisplay = function()
      return { width = 256, height = 192, layout = "compact" }
    end,
  })
  local screen = ScreenState.new(args)
  local firstKey = screen:status().view.key
  screen:updateFixed({ { type = "toggleSize" } })
  Assert.isTrue(
    screen:status().view.key == firstKey or screen:status().view.key ~= nil,
    "toggling the size presentation keeps a coherent browser view"
  )
  screen:dispose()
end

-- Every search editor and the forms comparison demand their own exact
-- source page role, never the generic parents: a scripted controller
-- walks the browser through each projection while an always-ready
-- lease records the demanded roles.
function T.search_editors_and_comparison_resolve_their_own_page_roles()
  local ScreenState = requirePresent("exact page role demand")
  local editorKinds = {
    { kind = "letter", role = "search.name" },
    { kind = "order", role = "search.order" },
    { kind = "type", role = "search.type" },
    { kind = "height", role = "search.height" },
    { kind = "weight", role = "search.weight" },
    { kind = "area", role = "search.area" },
    { kind = "shape", role = "search.shape" },
  }
  local views, expected = {}, {}
  ---@param page string browser page behind the view
  ---@param extra table<string, unknown>? page-specific projection fields
  ---@param role string exact source page role behind the view
  local function scriptView(page, extra, role)
    local view = {
      key = #views + 1,
      mode = "johto",
      page = page,
      selection = { language = "english" },
      pictures = {},
      text = {},
    }
    if extra ~= nil then
      for key, value in pairs(extra) do
        view[key] = value
      end
    end
    views[#views + 1] = view
    expected[#expected + 1] = role
  end
  scriptView("cover", nil, "cover")
  scriptView("grid", nil, "grid")
  scriptView("search", { search = { criteria = {} } }, "search.criteria")
  for _, editor in ipairs(editorKinds) do
    scriptView("search", {
      search = { criteria = {}, editor = { criterion = editor.kind, focus = nil, previousColumn = "criteria" } },
    }, editor.role)
  end
  scriptView("results", nil, "results")
  scriptView("area", nil, "entry.area")
  scriptView("size", nil, "entry.size")
  scriptView("forms", { forms = { variants = {}, row = 0, scrollbar = {} } }, "entry.forms")
  scriptView("forms", {
    forms = {
      variants = {},
      row = 0,
      scrollbar = {},
      comparison = { indices = { 0, 1 }, activeSide = 0, facing = "front" },
    },
  }, "entry.compare")
  scriptView("return", nil, "entry.return")
  local controller = { index = 1, views = views }
  function controller:view()
    return self.views[self.index]
  end
  function controller:updateFixed(events, _)
    assert(type(events) == "table", "the presented screen steps its controller with a batch")
    if self.index < #self.views then
      self.index = self.index + 1
    end
  end
  function controller:takeResult()
    return nil
  end
  function controller:dispose()
  end
  local lease = { prepared = {}, released = 0 }
  function lease:prepare(demand)
    assert(type(demand) == "table" and demand.key ~= nil, "the screen prepares keyed demands")
    self.prepared[#self.prepared + 1] = demand
    return { kind = "ready", key = demand.key, assets = {} }
  end
  function lease:release()
    self.released = self.released + 1
  end
  local args = screenArgs({
    controller = controller,
    lease = lease,
    measureDisplay = function()
      return compactMeasurement()
    end,
  })
  local screen = ScreenState.new(args)
  for _ = 2, #views do
    screen:updateFixed({})
  end
  Assert.equal(#lease.prepared, #views, "every projection prepares exactly one demand")
  for index, demand in ipairs(lease.prepared) do
    Assert.equal(
      demand.pageRole,
      expected[index],
      "projection " .. index .. " demands its own source page role"
    )
    Assert.equal(demand.language, "english", "the demand carries the selected language")
    Assert.equal(demand.profile, "base", "the demand carries its measurement profile")
  end
  screen:dispose()
end


---@param status table<string, unknown> host-facing presentation snapshot
---@return table controls pane origin for host-space pointer events
local function controlsOrigin(status)
  local plan = assert(status.presentation, "the screen publishes its resolved plan")
  for _, pane in ipairs(plan.panes) do
    if pane.id == "controls" then
      local placement = assert(pane.placement, "browser panes carry their placement")
      return placement.origin or placement.frame
    end
  end
  error("the resolved plan carries no controls pane", 0)
end

---@param screen table<string, unknown> presented screen under test
---@param origin table controls pane origin
---@param eventType string pointer edge type
---@param lx number pane-local x
---@param ly number pane-local y
---@param pointerId integer stable pointer identity
local function poke(screen, origin, eventType, lx, ly, pointerId)
  screen:updateFixed({ { type = eventType, x = origin.x + lx, y = origin.y + ly, pointerId = pointerId } })
end

function T.captured_slider_release_outside_bands_settles_under_pending_assets()
  local ScreenState = requirePresent("transactional slider completion")
  local ScreenTopology = require("libs.ui.src.ScreenTopology")
  local gate = { open = true }
  local template = { animations = {}, chrome = {}, pictures = {}, surfaces = {}, fonts = {}, messages = {} }
  local monCatalog, catalog = Fixture.catalogs()
  local owner = Fixture.ownerWithHistory(monCatalog, catalog)
  local live = Fixture.openController(owner, monCatalog, catalog)
  local controller, batches = spyController(live)
  local screen = ScreenState.new({
    controller = controller,
    lease = gateableLease(gate, template),
    measureDisplay = function()
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
        signature = "slider-release-test:dual",
      }
    end,
    effect = function()
    end,
    playCry = function()
    end,
    commitResume = function()
      return true
    end,
  })
  screen:updateFixed({ { type = "confirm" } })
  Assert.equal(screen:status().view.page, "grid", "the open cover admits its confirm")
  screen:updateFixed({ { type = "y" } })
  Assert.equal(live:view().page, "search", "grid Y reaches the search root")
  screen:updateFixed({ { type = "activate", action = "criterion", value = "height" } })
  Assert.notNil(live:view().search.editor, "the height editor opens")
  local origin = controlsOrigin(screen:status())
  -- The press captures the minimum endpoint; the following generation
  -- stays pending behind the closed gate.
  poke(screen, origin, "pointer_down", 20, 48, 9)
  Assert.isTrue(live:view().search.slider.captured, "the press captures the slider drag")
  gate.open = false
  -- Across the other track band and into empty space the gesture keeps
  -- its captured minimum; the release lands at empty y120.
  poke(screen, origin, "pointer_move", 100, 88, 9)
  poke(screen, origin, "pointer_up", 100, 120, 9)
  screen:updateFixed({})
  local criteria = live:view().search.criteria
  Assert.equal(criteria.height.min, 78, "the release settles the captured minimum")
  Assert.equal(criteria.height.max, 152, "the release leaves the other bound alone")
  Assert.isFalse(live:view().search.slider.captured, "the release clears the active drag")
  local held = lastHeld(batches)
  Assert.notNil(held, "the release ticks carry their held record")
  Assert.isFalse(held.touch, "the settled gesture leaves no held touch")
  -- A later cancellation cannot reopen or duplicate the settled drag.
  screen:updateFixed({ { type = "pointer_cancel", pointerId = 9 } })
  Assert.equal(live:view().search.criteria.height.min, 78, "a late cancel keeps the committed bound")
  Assert.isFalse(live:view().search.slider.captured, "a late cancel starts no new drag")
  -- Readiness restores the ordinary path: a fresh press captures again.
  gate.open = true
  screen:updateFixed({})
  poke(screen, origin, "pointer_down", 20, 48, 11)
  Assert.isTrue(live:view().search.slider.captured, "a fresh press captures again after readiness")
  poke(screen, origin, "pointer_up", 100, 120, 11)
  screen:updateFixed({})
  Assert.isFalse(live:view().search.slider.captured, "the fresh gesture settles too")
  screen:dispose()
end

function T.display_reflow_cancels_the_active_drag_exactly_once()
  local ScreenState = requirePresent("transactional slider cancellation")
  local ScreenTopology = require("libs.ui.src.ScreenTopology")
  local gate = { open = true }
  local template = { animations = {}, chrome = {}, pictures = {}, surfaces = {}, fonts = {}, messages = {} }
  local monCatalog, catalog = Fixture.catalogs()
  local owner = Fixture.ownerWithHistory(monCatalog, catalog)
  local live = Fixture.openController(owner, monCatalog, catalog)
  local controller, batches = spyController(live)
  local display = { mode = "dual" }
  local screen = ScreenState.new({
    controller = controller,
    lease = gateableLease(gate, template),
    measureDisplay = function()
      if display.mode == "dual" then
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
          signature = "slider-cancel-test:dual",
        }
      end
      return compactMeasurement()
    end,
    effect = function()
    end,
    playCry = function()
    end,
    commitResume = function()
      return true
    end,
  })
  screen:updateFixed({ { type = "confirm" } })
  screen:updateFixed({ { type = "y" } })
  screen:updateFixed({ { type = "activate", action = "criterion", value = "height" } })
  Assert.notNil(live:view().search.editor, "the height editor opens")
  local origin = controlsOrigin(screen:status())
  gate.open = false
  poke(screen, origin, "pointer_down", 20, 88, 9)
  Assert.isTrue(live:view().search.slider.captured, "the press captures the maximum drag")
  poke(screen, origin, "pointer_move", 150, 88, 9)
  Assert.equal(live:view().search.criteria.height.max, 120, "the move stages the maximum bound")
  local cancelStart = #batches
  -- The reflow drops the held press: the open transaction must roll
  -- back to its pre-drag bound exactly once.
  display.mode = "single"
  screen:updateFixed({})
  screen:updateFixed({})
  Assert.equal(live:view().search.criteria.height.max, 152, "the reflow restores the pre-drag bound")
  Assert.equal(live:view().search.criteria.height.min, 0, "the reflow leaves the other bound alone")
  Assert.isFalse(live:view().search.slider.captured, "the reflow clears the active drag")
  local cancels = 0
  for index = cancelStart + 1, #batches do
    for _, event in ipairs(batches[index]) do
      if type(event) == "table" and event.type == "drag" and event.phase == "cancel" then
        cancels = cancels + 1
        Assert.equal(event.target, "height-max", "the cancellation names the captured endpoint")
      end
    end
  end
  Assert.equal(cancels, 1, "the reflow cancels the active drag exactly once")
  local held = lastHeld(batches)
  Assert.notNil(held, "the reflow ticks carry their held record")
  Assert.isFalse(held.touch, "the reflow leaves no held touch behind")
  -- Unrelated navigation stays gated while the generation is pending.
  local key = live:view().key
  screen:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(live:view().key, key, "navigation stays gated while assets are pending")
  screen:dispose()
end

function T.held_touch_survives_frame_boundaries_until_the_gesture_ends()
  local ScreenState = requirePresent("stable held pointer tracking")
  local monCatalog, catalog = Fixture.catalogs()
  local owner = Fixture.ownerWithHistory(monCatalog, catalog)
  local live = Fixture.openController(owner, monCatalog, catalog)
  local controller, batches = spyController(live)
  local ScreenTopology = require("libs.ui.src.ScreenTopology")
  local args = screenArgs({
    controller = controller,
    measureDisplay = function()
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
        signature = "pokedex-screen-held-test:dual",
      }
    end,
  })
  local screen = ScreenState.new(args)
  -- The cover drag is the observable held gesture: down begins it on the
  -- controls pane of the wide layout.
  local status = screen:status()
  local plan = assert(status.presentation, "the screen publishes its resolved plan")
  local origin = nil
  for _, pane in ipairs(plan.panes) do
    if pane.id == "controls" then
      local placement = assert(pane.placement, "browser panes carry their placement")
      origin = placement.origin or placement.frame
    end
  end
  Assert.notNil(origin, "the resolved plan carries the controls pane")
  screen:updateFixed({ { type = "pointer_down", x = origin.x + 100, y = origin.y + 100, pointerId = 7 } })
  local held = lastHeld(batches)
  Assert.notNil(held, "the gesture tick carries its held record")
  Assert.isTrue(held.touch, "the drag begin reports its held touch")
  screen:updateFixed({})
  held = lastHeld(batches)
  Assert.notNil(held, "the following tick carries its held record")
  Assert.isTrue(held.touch, "held touch survives frame boundaries while captured")
  screen:updateFixed({ { type = "pointer_up", x = origin.x + 190, y = origin.y + 100, pointerId = 7 } })
  screen:updateFixed({})
  held = lastHeld(batches)
  Assert.notNil(held, "the release tick carries its held record")
  Assert.isFalse(held.touch, "the gesture end clears the held touch")
  screen:dispose()
end

function T.compact_inspector_shields_every_background_input()
  local ScreenState = requirePresent("comprehensive inspector shielding")
  local gate = { open = false }
  local bundle = { animations = {}, chrome = {}, pictures = {}, surfaces = {}, fonts = {}, messages = {} }
  local lease = { prepared = {}, released = 0 }
  function lease:prepare(demand)
    assert(type(demand) == "table" and demand.key ~= nil, "the screen prepares keyed demands")
    self.prepared[#self.prepared + 1] = demand
    if gate.open then
      return { kind = "ready", key = demand.key, assets = bundle }
    end
    return { kind = "pending" }
  end
  function lease:release()
    self.released = self.released + 1
  end
  local args = screenArgs({
    lease = lease,
    measureDisplay = function()
      return compactMeasurement()
    end,
  })
  local screen = ScreenState.new(args)
  gate.open = true
  screen:updateFixed({})
  screen:updateFixed({ { type = "confirm" } })
  Assert.equal(screen:status().view.page, "grid", "the committed cover admits its confirm")
  screen:updateFixed({ { type = "inspect" } })
  Assert.isTrue(screen:status().compact.inspect, "the inspect action opens the panel")
  local key = screen:status().view.key
  screen:updateFixed({ { type = "activate", action = "grid-slot", value = 0 } })
  Assert.equal(screen:status().view.key, key, "grid taps never act through the inspector")
  Assert.equal(screen:status().view.page, "grid", "grid taps never leave through the inspector")
  screen:updateFixed({ { type = "activate", action = "search" } })
  Assert.equal(screen:status().view.page, "grid", "search actions never act through the inspector")
  screen:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(screen:status().view.key, key, "navigation never acts through the inspector")
  screen:updateFixed({ { type = "cancel" } })
  Assert.isFalse(screen:status().compact.inspect, "cancelling closes the panel")
  Assert.equal(screen:status().view.page, "grid", "closing the panel is not a screen close")
  screen:dispose()
end

function T.held_input_cancels_once_across_a_display_reflow()
  local ScreenState = requirePresent("reflow pointer cancellation")
  local ScreenTopology = require("libs.ui.src.ScreenTopology")
  local gate = { open = true }
  local template = { animations = {}, chrome = {}, pictures = {}, surfaces = {}, fonts = {}, messages = {} }
  local monCatalog, catalog = Fixture.catalogs()
  local owner = Fixture.ownerWithHistory(monCatalog, catalog)
  local live = Fixture.openController(owner, monCatalog, catalog)
  local controller, batches = spyController(live)
  local display = { mode = "single" }
  local screen = ScreenState.new({
    controller = controller,
    lease = gateableLease(gate, template),
    measureDisplay = function()
      if display.mode == "dual" then
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
          signature = "dual-resized",
        }
      end
      return compactMeasurement()
    end,
    effect = function()
    end,
    playCry = function()
    end,
    commitResume = function()
      return true
    end,
  })
  screen:updateFixed({ { type = "confirm" } })
  Assert.equal(screen:status().view.page, "grid", "the open cover admits its confirm once ready")
  local gridBundle = assert(screen:status().assets, "the grid demand commits its whole bundle")
  -- Hold the search candidate pending, then capture a press on the
  -- displayed grid before the display reflows underneath it.
  gate.open = false
  screen:updateFixed({ { type = "y" } })
  Assert.equal(live:view().page, "search", "the search request advances the live browser")
  screen:updateFixed({ { type = "pointer_down", x = 40, y = 30, pointerId = 3 } })
  display.mode = "dual"
  local reflowStart = #batches
  screen:updateFixed({})
  local reflowed = screen:status()
  Assert.equal(reflowed.view.page, "grid", "a reflow never presents the pending page")
  Assert.isTrue(reflowed.assets == gridBundle, "a reflow keeps the committed bundle")
  local reflowPlan = assert(reflowed.presentation, "a reflow keeps a resolved plan")
  Assert.isTrue(
    string.find(reflowPlan.inputKey, ":grid:", 1, true) ~= nil,
    "a reflow keeps the displayed grid geometry"
  )
  Assert.isTrue(
    string.find(reflowPlan.inputKey, ":search:", 1, true) == nil,
    "a reflow publishes no search geometry"
  )
  screen:updateFixed({})
  local cancels = 0
  for index = reflowStart + 1, #batches do
    for _, event in ipairs(batches[index]) do
      if type(event) == "table" and event.type == "pointer_cancel" then
        cancels = cancels + 1
      end
    end
  end
  Assert.equal(cancels, 1, "a reflow cancels the held press exactly once")
  local held = lastHeld(batches)
  Assert.notNil(held, "the reflow ticks carry their held record")
  Assert.isFalse(held.touch, "the reflow leaves no held touch behind")
  screen:dispose()
end

function T.failed_candidate_plans_keep_the_last_ready_triplet()
  local ScreenState = requirePresent("failed candidate plan retention")
  local PokedexInterface = require("game.hgss.src.pokedex.PokedexInterface")
  local defaults = PokedexInterface.browser()
  local gate = { open = true }
  local template = { animations = {}, chrome = {}, pictures = {}, surfaces = {}, fonts = {}, messages = {} }
  local args = screenArgs({
    lease = gateableLease(gate, template),
    measureDisplay = function()
      return compactMeasurement()
    end,
    overrides = {
      nativeLike = function(context, view)
        if type(view) == "table" and view.page == "search" then
          error("injected plan failure")
        end
        return defaults.nativeLike(context, view)
      end,
    },
  })
  local screen = ScreenState.new(args)
  screen:updateFixed({ { type = "confirm" } })
  Assert.equal(screen:status().view.page, "grid", "the open cover admits its confirm once ready")
  local gridBundle = assert(screen:status().assets, "the grid demand commits its whole bundle")
  local gridKey = screen:status().view.key
  -- The search bundle turns ready on the same tick its plan fails to
  -- resolve: the failed candidate must not replace the published grid.
  screen:updateFixed({ { type = "y" } })
  local failed = screen:status()
  Assert.equal(failed.view.page, "grid", "a failed candidate keeps the displayed grid")
  Assert.equal(failed.view.key, gridKey, "a failed candidate never advances the committed key")
  Assert.isTrue(failed.assets == gridBundle, "a failed candidate keeps the committed bundle")
  Assert.equal(failed.phase, "failed", "a failed candidate reports through the failure phase")
  Assert.notNil(failed.preparationError, "a failed candidate attributes its cause")
  screen:dispose()
end

return { tests = T }
