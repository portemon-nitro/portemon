-- Animation sprite copies are native managed sprites: 2D OBJ objects drawn
-- by the sprite system after the Pokepic 3D layer. They composite against
-- the world plane by OBJ priority instead of sharing the picture depth
-- buffer, and they honor the source slot's draw flag.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local BattlePicturePass = require("libs.hgss.src.presentation.BattlePicturePass")
local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")

local T = {}

local SLOTS = {
  {
    sideType = 0,
    settledX = 128,
    settledY = 96,
    entryX = 320,
    entryY = 96,
    depth = -512,
    hudX = 192,
    hudY = 116,
    hudPriority = 23,
    hudBgPriority = 0,
  },
}

local function solidImage(graphics, scope, red, green, blue, size)
  local extent = size or 16
  local data = love.image.newImageData(extent, extent)
  for y = 0, extent - 1 do
    for x = 0, extent - 1 do
      data:setPixel(x, y, red, green, blue, 1)
    end
  end
  local image = scope:own(graphics.newImage(data))
  image:setFilter("nearest", "nearest")
  return image
end

function T.sprite_copies_composite_above_the_3d_layer(scope)
  local graphics = love.graphics
  -- Staged portraits are 80x80 cells; the visible Pokepic window crops them.
  local monArt = solidImage(graphics, scope, 0, 1, 0, 80)
  local overlayArt = solidImage(graphics, scope, 1, 0, 0)
  local scene = scope:own(BattleScene.new())
  local battler = {
    combatant = 1,
    activation = 1,
    side = 1,
    position = 1,
    portraitSelector = "probe/hero",
    visible = true,
    sourceHeight = 0,
    pictureVisible = true,
    pictureWidth = 64,
    pictureHeight = 64,
    shadowHeight = 0,
    hudVisible = false,
  }
  scene:observe({ battler })
  scene:install(battler)
  scene:setBattlerSpriteSlot("probe:1", 0, { combatant = 1, activation = 1 }, false)
  local overlay = scene:allocEffect("probe-overlay")
  scene:setEffectPicture(overlay.id, {
    assetKey = "probe/overlay",
    selector = "probe/overlay",
    centerX = 128,
    centerY = 96,
    zCenter = 0,
    width = 256,
    height = 192,
    alpha = 1,
  })
  local pass = scope:own(BattlePicturePass.new(graphics))
  local assets = {}
  function assets:drawable(assetKey)
    if assetKey == "probe/overlay" then
      return overlayArt
    end
    if type(assetKey) == "string" and assetKey:sub(1, 4) == "mon:" then
      return monArt
    end
    return nil
  end
  function assets:renderPictures(hostGraphics, frame)
    return pass:render(hostGraphics, frame)
  end
  local canvas = scope:own(graphics.newCanvas(256, 192, { format = "rgba8", readable = true, dpiscale = 1 }))
  local function centerPixel()
    local pictureState = scene:pictureState(battler)
    local renderBattler = {}
    for field, value in pairs(battler) do
      renderBattler[field] = value
    end
    if pictureState ~= nil then
      for field, value in pairs(pictureState) do
        renderBattler[field] = value
      end
    end
    local view = {
      battlers = { renderBattler },
      slotGeometry = SLOTS,
      effectInstances = scene:effectViews(),
      bgScroll = scene:scroll(),
      hudSections = {},
    }
    graphics.setCanvas(canvas)
    graphics.clear(0, 0, 0, 0)
    BattleRenderer.drawPane({
      graphics = graphics,
      text = {},
      windows = {},
      assets = assets,
      sceneImageKey = "missing-scene",
    }, view, "detail", {}, { x = 0, y = 0, scale = 1 })
    graphics.setCanvas()
    local data = scope:own(canvas:newImageData())
    local red, green = data:getPixel(128, 96)
    return red, green
  end

  local red, green = centerPixel()
  Assert.isTrue(
    green > 0.5 and red < 0.5,
    "the sprite copy draws above the nearer effect plane, got r=" .. red .. " g=" .. green
  )
  -- StopBattlerSpriteDraw / SetBattlerSpriteVisible hide the copy without
  -- deleting it: the hidden copy submits nothing and the nearer effect plane
  -- shows through instead.
  scene:setAnimationSpriteDrawFlag(0, false)
  local hiddenRed, hiddenGreen = centerPixel()
  Assert.isTrue(
    hiddenRed > 0.5 and hiddenGreen < 0.5,
    "a hidden sprite copy stops drawing, got r=" .. hiddenRed .. " g=" .. hiddenGreen
  )
  scene:setAnimationSpriteDrawFlag(0, true)
  local shownRed, shownGreen = centerPixel()
  Assert.isTrue(
    shownGreen > 0.5 and shownRed < 0.5,
    "the copy returns with its source draw flag, got r=" .. shownRed .. " g=" .. shownGreen
  )
end

return GraphicsSmoke.suite(T)
