-- Real offscreen pixels for the source form-change picture lifecycle:
-- RestoreSprite exposes the underlying Pokemon, the mosaic swaps only its
-- event-time portrait, and RefreshSprite hides it again before SUB_IN.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
local BattleTimeline = require("game.hgss.src.battle.BattleTimeline")
local BattlePresentationManifestFixture = require("tests.support.BattlePresentationManifestFixture")
local MonCache = require("libs.assets.src.MonCache")

local T = {}
local TICK = 1 / 60

local function solidImage(graphics, scope, red, green, blue)
  local data = love.image.newImageData(80, 80)
  for y = 0, 79 do
    for x = 0, 79 do
      data:setPixel(x, y, red, green, blue, 1)
    end
  end
  local image = scope:own(graphics.newImage(data))
  image:setFilter("nearest", "nearest")
  return image
end

local function stripedImage(graphics, scope)
  local data = love.image.newImageData(80, 80)
  for y = 0, 79 do
    for x = 0, 79 do
      if x < 4 then
        data:setPixel(x, y, 1, 0, 0, 1)
      else
        data:setPixel(x, y, 0, 1, 0, 1)
      end
    end
  end
  local image = scope:own(graphics.newImage(data))
  image:setFilter("nearest", "nearest")
  return image
end

function T.substitute_form_change_restores_and_refreshes_real_picture_pixels(scope)
  local graphics = love.graphics
  local slots = BattlePresentationManifestFixture.manifest().battlefield.slots
  local normal = MonCache.portraitSelector("CASTFORM", 0, "male", false, "front")
  local sunny = MonCache.portraitSelector("CASTFORM", 1, "male", false, "front")
  local normalImage = solidImage(graphics, scope, 1, 0, 0)
  local sunnyImage = stripedImage(graphics, scope)
  local assets = {}
  function assets:drawable(key)
    if key == "mon:" .. normal then
      return normalImage
    end
    if key == "mon:" .. sunny then
      return sunnyImage
    end
    return nil
  end
  function assets:renderPictures(hostGraphics, frame)
    return self.pass:render(hostGraphics, frame)
  end
  assets.pass = scope:own(require("libs.hgss.src.presentation.BattlePicturePass").new(graphics))

  local starts = {}
  local timeline = BattleTimeline.new({
    effects = {
      start = function(cue)
        starts[#starts + 1] = cue.effectKey
        return {}
      end,
      status = function()
        return "complete"
      end,
      retire = function()
        return true
      end,
    },
    slotGeometry = slots,
    sound = function(_) end,
    encounterFadeColor = "white",
    messageText = function(_, _, substitutions)
      return substitutions[1] .. " transformed!"
    end,
    textSpeed = "fastest",
  })
  local view = {
    own = {},
    foes = {
      {
        combatant = 3,
        participant = 3,
        side = 2,
        controller = "wild",
        active = true,
        position = 1,
        activation = 3,
        hp = 57,
        maxHp = 57,
        species = "CASTFORM",
        form = 0,
        name = "FOE",
        level = 20,
        substitute = true,
        portraitSelector = normal,
        sourceHeight = 0,
        shadowHeight = 0,
      },
    },
    participants = {},
    environment = {},
    playerTrainer = { classKey = "PKMN_TRAINER_ETHAN" },
  }
  timeline:reset(view)
  timeline:_shown(3).hudVisible = false
  timeline:_shown(3).sourceHeight = 0
  timeline:_shown(3).shadowHeight = 0
  timeline._flowIntroDone = true
  local event = {
    sequence = 1,
    kind = "ability",
    cause = { kind = "system", key = "weather-form" },
    audience = "public",
    payload = { key = "WEATHER_FORM", combatant = 3, beforeForm = 0, form = 1 },
    actors = { { combatant = 3, activation = 3 } },
    targets = { { combatant = 3, activation = 3 } },
    presentation = {
      context = { battleFormat = "singles" },
      operation = {
        kind = "form-changed",
        subject = { combatant = 3, activation = 3 },
        source = { kind = "system", key = "weather-form" },
        beforeForm = 0,
        form = 1,
        substitute = true,
      },
    },
    formChangeAppearance = { combatant = 3, activation = 3, form = 1, portraitSelector = sunny },
  }
  Assert.isTrue(
    timeline:present({
      launchId = "form-pixels",
      packetId = 1,
      events = { event },
      before = view,
      after = view,
    }),
    "the form packet is accepted"
  )

  local canvas = scope:own(graphics.newCanvas(256, 192, { format = "rgba8", readable = true, dpiscale = 1 }))
  local function pixel(x, y)
    graphics.setCanvas(canvas)
    graphics.clear(0, 0, 0, 0)
    local battlers = timeline:battlers()
    BattleRenderer.drawPane({
      graphics = graphics,
      text = {},
      windows = {},
      assets = assets,
      sceneImageKey = "missing-scene",
    }, {
      battlers = battlers,
      slotGeometry = slots,
      effectInstances = {},
      bgScroll = {},
      hudSections = {},
    }, "detail", {}, { x = 0, y = 0, scale = 1 })
    graphics.setCanvas()
    local data = scope:own(canvas:newImageData())
    local red, green, blue, alpha = data:getPixel(x, y)
    data:release()
    return red, green, blue, alpha
  end

  local hiddenRed, hiddenGreen, hiddenBlue = pixel(192, 50)
  Assert.equal(
    hiddenRed + hiddenGreen + hiddenBlue,
    0,
    "the Substitute doll picture hides the underlying Pokemon before RestoreSprite"
  )
  local restored = false
  local swapped = false
  local revealed = false
  for _ = 1, 500 do
    timeline:update(TICK)
    local shown = timeline:_shown(3)
    if not restored and #starts == 2 and shown.formChangePicture == true then
      local red, green, blue, alpha = pixel(192, 50)
      Assert.near(red, 1, 1 / 255, "RestoreSprite paints the old Pokemon portrait")
      Assert.equal(green, 0, "the restored picture still carries the old form")
      Assert.equal(blue, 0, "the restored picture keeps its old form color")
      Assert.equal(alpha, 1, "the restored Pokemon picture is opaque")
      restored = true
    end
    if not swapped and shown.form == 1 and shown.mosaicSize == 9 then
      local centerRed, centerGreen, _, centerAlpha = pixel(192, 50)
      local mosaicRed, mosaicGreen, _, mosaicAlpha = pixel(157, 50)
      Assert.equal(centerRed, 0, "the target portrait replaces the old red form at the covered checkpoint")
      Assert.near(centerGreen, 1, 1 / 255, "the target portrait is really drawn under the mosaic")
      Assert.equal(centerAlpha, 1, "the target portrait remains visible under the mosaic")
      Assert.near(
        mosaicRed,
        1,
        1 / 255,
        "the per-picture mosaic samples its block origin; got " .. tostring(mosaicRed) .. "," .. tostring(mosaicGreen)
      )
      Assert.equal(mosaicGreen, 0, "the mosaicked stripe comes from the block origin, not the direct texel")
      Assert.equal(mosaicAlpha, 1, "mosaic sampling keeps the picture opaque")
      swapped = true
    end
    if not revealed and shown.form == 1 and shown.mosaicSize == nil and #starts == 2 then
      local _, green, _, alpha = pixel(157, 50)
      Assert.near(green, 1, 1 / 255, "mosaic-out reveals the target portrait's direct texel")
      Assert.equal(alpha, 1, "the transformed Pokemon stays visible through its message hold")
      revealed = true
    end
    if timeline:settled() then
      break
    end
  end
  Assert.isTrue(restored, "the first RestoreSprite checkpoint is observed")
  Assert.isTrue(swapped, "the target portrait is observed under the mosaic")
  Assert.isTrue(revealed, "the target portrait is observed after mosaic-out")
  Assert.deepEqual(starts, {
    "BATTLE_ANIMATION_SUB_OUT",
    "BATTLE_ANIMATION_SUB_IN",
    "BATTLE_ANIMATION_SUB_OUT",
    "BATTLE_ANIMATION_SUB_IN",
  }, "both source wrapper pairs play")
  local refreshedRed, refreshedGreen, refreshedBlue = pixel(192, 50)
  Assert.equal(
    refreshedRed + refreshedGreen + refreshedBlue,
    0,
    "RefreshSprite removes the underlying Pokemon before the final SUB_IN"
  )
end

return GraphicsSmoke.suite(T)
