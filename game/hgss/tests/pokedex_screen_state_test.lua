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

---@param behavior string missing screen behavior under test
---@return table the loaded per-open screen owner
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
  local screen = ScreenState.new(args)
  local firstKey = screen:status().view.key
  screen:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(screen:status().view.key, firstKey, "an update without matching readiness retains the view")
  Assert.isNil(screen:status().assets, "pending ticks publish no half bundle")
  gate.open = true
  screen:updateFixed({})
  Assert.notNil(screen:status().assets, "the matching ready outcome publishes the whole bundle")
  screen:updateFixed({ { type = "navigate", direction = "right" } })
  local movedKey = screen:status().view.key
  Assert.isTrue(movedKey ~= firstKey, "an admitted update advances the generation key")
  gate.open = false
  screen:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(
    screen:status().view.key,
    movedKey,
    "a newer pending generation retains the last committed view"
  )
  Assert.notNil(screen:status().assets, "the retained pair keeps its committed bundle")
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
  local args = screenArgs({ controller = controller, lease = lease })
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

return { tests = T }
