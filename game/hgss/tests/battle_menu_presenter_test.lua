-- Verifies the native lower menu composition owner uses source BG planes.

local Assert = require("tests.support.Assert")
local FakeGraphics = require("tests.support.FakeGraphics")
local BattleMenuPresenter = require("game.hgss.src.battle.BattleMenuPresenter")

local T = {}

-- Stands in for the per-screen asset holder: keyed drawables resolved
-- directly, since plane content owns no blend targets.
local function fakeAssets()
  local assets = {}
  function assets.drawable(_, key)
    return { key = key }
  end
  return assets
end

-- One menu layer draws its staged tilemaps without owning blend state:
-- the unified sub-engine frame owns visibility, priority, windows and
-- blending, so the plane entry only forwards content.
function T.draw_plane_renders_one_layer_without_owning_blend_state()
  local graphics = FakeGraphics.new({})
  local assets = fakeAssets()
  BattleMenuPresenter.drawPlane(graphics, assets, "command", {}, { index = 1, layer = { plane = 0, priority = 2 } })
  Assert.equal(
    graphics.draws[1].image.key,
    "menu:command:screen:1",
    "the plane entry draws its own staged tilemap"
  )
  Assert.equal(#graphics.canvases, 0, "a plane draw allocates no blend target")
  Assert.equal(#graphics.shaders, 0, "a plane draw owns no blend shader")
end

-- Source lower planes ride fixed sub-engine roles: buttons on menu,
-- panels on window, backdrop art on transition. Unknown planes fail
-- instead of drawing on a guessed role.
function T.source_planes_map_to_fixed_sub_engine_roles()
  Assert.equal(BattleMenuPresenter.roleForPlane(0), "menu", "plane 0 feeds the menu role")
  Assert.equal(BattleMenuPresenter.roleForPlane(1), "window", "plane 1 feeds the window role")
  Assert.equal(BattleMenuPresenter.roleForPlane(2), "transition", "plane 2 feeds the transition role")
  Assert.equal(BattleMenuPresenter.roleForPlane(3), "battlefield", "plane 3 feeds the battlefield role")
  local ok = pcall(BattleMenuPresenter.roleForPlane, 4)
  Assert.isFalse(ok, "an unknown plane fails instead of guessing a role")
end

return { tests = T }
