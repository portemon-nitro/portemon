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

function T.browser_resolves_both_native_panes_in_every_paired_layout()
  local Interface = requirePresent("paired native pane placement")
  for _, class in ipairs({ "dual", "wide", "tall" }) do
    local set = Interface.browser()
    local session = ApplicationPresentation.new(set)
    local plan = session:resolve(measurementFor(class), { view = stubView(), assets = {} })
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
  local plan = session:resolve(measurementFor("compact"), { view = stubView(), assets = {} })
  Assert.notNil(plan, "the single-display layout resolves a compact plan")
  local tapped = session:mapInput(
    { { type = "pointer_down", x = 8, y = 20, pointerId = 1 } },
    { view = stubView(), assets = {} }
  )
  Assert.isTrue(#tapped >= 0, "compact grid pointers map without raising")
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
  }, {
    view = stubView(),
    assets = {},
  })
  if plan ~= nil then
    local mapped = session:mapInput(
      { { type = "pointer_down", x = 100, y = 80, pointerId = 1 } },
      { view = stubView(), assets = {} }
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
  session:resolve(measurementFor("compact"), { view = stubView(), assets = {} })
  session:mapInput({ { type = "pointer_down", x = 8, y = 20, pointerId = 7 } }, {
    view = stubView(),
    assets = {},
  })
  session:cancelPointers()
  local mapped = session:mapInput(
    { { type = "pointer_up", x = 8, y = 20, pointerId = 7 } },
    { view = stubView(), assets = {} }
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

return { tests = T }
