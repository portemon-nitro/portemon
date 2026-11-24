-- The closed-menu shortcut cluster: it slides out past the screen's right
-- edge while the field is held and back in once it is free, at the area-name
-- banner's scroll step per fixed tick, and its registered-item tabs answer
-- host points through the same placement they draw with.

local Assert = require("tests.support.Assert")
local FieldMapNameBanner = require("libs.hgss.src.ui.FieldMapNameBanner")
local FieldShortcutSlide = require("game.hgss.src.field.FieldShortcutSlide")
local FieldPresentationResources = require("game.hgss.src.field.FieldPresentationResources")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local StartMenuInterface = require("game.hgss.src.field.StartMenuInterface")

-- Resources shaped like the production owner: the manifest plus the start
-- menu's own layout resolution against one touch display of the given size.
local function shortcutResources(width, height)
  local manifest = FieldUiFixture.manifest()
  FieldUiFixture.addStartMenuIconContract(manifest)
  local measurement = {
    width = width,
    height = height,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = width, height = height },
      role = "world",
      touch = true,
    }),
    pixelRatio = 1,
    signature = "test:" .. width .. "x" .. height,
  }
  local function measureDisplay()
    return measurement
  end
  return {
    uiManifest = manifest,
    _shortcutLayout = ApplicationPresentation.new(StartMenuInterface.defaults()),
    _measureDisplay = measureDisplay,
  }
end

local T = { tests = {} }

function T.tests.slides_out_while_the_menu_is_open_and_back_once_it_closes()
  local step = FieldMapNameBanner.SCROLL_STEP
  local slide = FieldShortcutSlide.new(step * 2 + 1)
  Assert.equal(slide:offset(), 0, "the cluster starts fully in")
  Assert.isFalse(slide:isHidden())
  slide:updateFixed(true)
  Assert.equal(slide:offset(), step)
  slide:updateFixed(true)
  slide:updateFixed(true)
  Assert.equal(slide:offset(), step * 2 + 1, "the slide stops fully out")
  Assert.isTrue(slide:isHidden())
  slide:updateFixed(true)
  Assert.equal(slide:offset(), step * 2 + 1)
  slide:updateFixed(false)
  Assert.equal(slide:offset(), step + 1)
  slide:updateFixed(false)
  slide:updateFixed(false)
  Assert.equal(slide:offset(), 0, "the slide stops fully in")
end

-- On a native-size screen the cluster rests flush in the bottom-right
-- corner (its bottom edge, logical y 134, on the screen's bottom), so the
-- first tab spans host y 66..98; only registered slots answer, and the slide
-- offset carries the tabs toward the right edge.
function T.tests.tabs_answer_host_points_at_their_slid_placement()
  local resources = shortcutResources(256, 192)
  local bounds = { x = 0, y = 0, width = 256, height = 192 }
  local function tabAt(count, offset, x, y)
    return FieldPresentationResources.shortcutAt(resources, count, false, offset, bounds, x, y)
  end
  Assert.equal(tabAt(1, 0, 210, 70), 1, "the first tab answers")
  Assert.isNil(tabAt(0, 0, 210, 70), "an empty slot never answers")
  Assert.equal(tabAt(2, 0, 210, 110), 2, "the second tab sits below the first")
  Assert.isNil(tabAt(2, 0, 190, 70), "points left of the tabs miss")
  Assert.isNil(tabAt(1, 16, 210, 70), "a slid tab leaves its resting spot")
  Assert.equal(tabAt(1, 16, 220, 70), 1, "a slid tab answers where it now draws")
end

-- The Running Shoes button answers over its generated touch rectangle while
-- it shows: at 1x it rests at logical (184,86), host y 144 on a 192-tall
-- screen.
function T.tests.running_shoes_answer_only_while_shown()
  local resources = shortcutResources(256, 192)
  local bounds = { x = 0, y = 0, width = 256, height = 192 }
  Assert.equal(FieldPresentationResources.shortcutAt(resources, 2, true, 0, bounds, 190, 150), "running_shoes")
  Assert.isNil(FieldPresentationResources.shortcutAt(resources, 2, false, 0, bounds, 190, 150))
end

-- The cluster takes the scale the start menu itself resolves to: on a
-- 512x384 display the menu draws at 2x, so the first tab spans host
-- x 400..512 and y 132..196 against the bottom-right corner.
function T.tests.tabs_follow_the_start_menu_scale()
  local resources = shortcutResources(512, 384)
  local bounds = { x = 0, y = 0, width = 512, height = 384 }
  local function tabAt(x, y)
    return FieldPresentationResources.shortcutAt(resources, 1, false, 0, bounds, x, y)
  end
  Assert.equal(tabAt(402, 134), 1)
  Assert.isNil(tabAt(398, 134), "left of the doubled tab misses")
  Assert.isNil(tabAt(402, 130), "above the doubled tab misses")
end

return T
