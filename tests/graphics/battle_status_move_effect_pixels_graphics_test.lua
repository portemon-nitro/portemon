-- Source-compiled Tail Whip and Hypnosis programs must paint changing
-- native effect pixels through the battle picture pass.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local BattleAnimationPlayer = require("libs.hgss.src.presentation.BattleAnimationPlayer")
local BattleEffectTasks = require("libs.hgss.src.presentation.BattleEffectTasks")
local BattlePicturePass = require("libs.hgss.src.presentation.BattlePicturePass")
local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local BattlePresentationFlow = require("game.hgss.src.battle.BattlePresentationFlow")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")
local CacheFs = require("libs.storage.src.CacheFs")
local GameVersion = require("romdump.src.source.GameVersion")
local ManifestFixture = require("tests.support.BattlePresentationManifestFixture")
local RomImporter = require("romdump.src.source.RomImporter")

local T = {}
local MOVES = { "TAIL_WHIP", "HYPNOSIS" }
-- Pixels are fingerprinted on a coarse grid at a coarse tick cadence; the
-- programs run to completion every tick, only the readback is sampled.
local PIXEL_STRIDE = 2
local SAMPLE_EVERY = 3

local function firstReadyVersion()
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      return versionId
    end
  end
  error("a ready game dump and derived cache are required", 0)
end

local function nativePixels(data)
  local hash = 2166136261
  local covered = 0
  for y = 0, data:getHeight() - 1, PIXEL_STRIDE do
    for x = 0, data:getWidth() - 1, PIXEL_STRIDE do
      local red, green, blue, alpha = data:getPixel(x, y)
      if alpha > 0 then
        covered = covered + 1
      end
      for _, channel in ipairs({ red, green, blue, alpha }) do
        hash = (hash * 16777619 + math.floor(channel * 255 + 0.5)) % 4294967296
      end
    end
  end
  return hash, covered
end

local function runVersion(scope, versionId)
  local graphics = love.graphics
  local cacheFs = CacheFs.forVersion(versionId)
  local slots = ManifestFixture.manifest().battlefield.slots
  local before = {
    own = { { combatant = 1, activation = 1, side = 1, position = 1 } },
    foes = { { combatant = 3, activation = 3, side = 2, position = 2 } },
  }
  local failures = {}

  for index, key in ipairs(MOVES) do
    local effect = assert(BattlePresentationCache.loadEffect(cacheFs, key), key .. " has a staged source program")
    local images = {}
    local resources = {}
    function resources.resolve(resourceKey)
      local descriptor = assert(effect.resources[resourceKey], key .. " declares " .. resourceKey)
      local payload = assert(cacheFs:loadLua(descriptor.payload), key .. " stages " .. descriptor.payload)
      local lease = {
        key = resourceKey,
        kind = descriptor.kind,
        payloadPath = descriptor.payload,
        data = payload,
      }
      if descriptor.kind == "texture" then
        local data = love.image.newImageData(payload.width, payload.height, "rgba8", payload.rgba8888)
        local image = scope:own(graphics.newImage(data))
        image:setFilter("nearest", "nearest")
        images[resourceKey] = image
        lease.width = payload.width
        lease.height = payload.height
        lease.rgba8888 = payload.rgba8888
        lease.handle = image
      end
      return lease
    end
    function resources.release(_lease) end

    local audio = {}
    function audio.play(name)
      return name
    end
    function audio.stop(_name) end
    function audio.isFinished(_name)
      return true
    end
    local scene = BattleScene.new()
    local battlers = {
      {
        combatant = 1,
        activation = 1,
        side = 1,
        position = 1,
        portraitSelector = "probe/player",
        visible = true,
        pictureVisible = true,
        pictureWidth = 48,
        pictureHeight = 48,
        shadowHeight = 8,
        hudVisible = false,
      },
      {
        combatant = 3,
        activation = 3,
        side = 2,
        position = 2,
        portraitSelector = "probe/foe",
        visible = true,
        pictureVisible = true,
        pictureWidth = 48,
        pictureHeight = 48,
        shadowHeight = 8,
        hudVisible = false,
      },
    }
    scene:observe(battlers)
    for _, battler in ipairs(battlers) do
      scene:install(battler)
    end
    local player = assert(BattleAnimationPlayer.new({
      scene = scene,
      audio = audio,
      resources = resources,
      tasks = BattleEffectTasks,
    }))
    local packet = {
      launchId = "named-effect-pixels",
      packetId = index,
      before = before,
      after = before,
    }
    local event = {
      sequence = index,
      actionId = index,
      hitIndex = 1,
      effectKey = key,
      actors = { { combatant = 1, activation = 1 } },
      targets = { { combatant = 3, activation = 3 } },
      move = { selected = key, executed = key, phase = "direct", power = 0 },
      visualSeed = 0x5151 + index,
    }
    local playback = BattlePresentationFlow.animationPlayback(packet, event, slots)
    local handle = assert(player:start(playback, effect.program), key .. " admits its source program")
    local pass = scope:own(BattlePicturePass.new(graphics))
    local canvas = scope:own(graphics.newCanvas(256, 192, { format = "rgba8", readable = true, dpiscale = 1 }))
    local portraitData = love.image.newImageData(80, 80, "rgba8")
    for y = 0, 79 do
      for x = 0, 79 do
        portraitData:setPixel(x, y, (x % 8) / 7, (y % 8) / 7, ((x + y) % 8) / 7, 1)
      end
    end
    local portrait = scope:own(graphics.newImage(portraitData))
    portrait:setFilter("nearest", "nearest")
    local battleAssets = {}
    function battleAssets:drawable(assetKey)
      if images[assetKey] ~= nil then
        return images[assetKey]
      end
      if type(assetKey) == "string" and assetKey:sub(1, 4) == "mon:" then
        return portrait
      end
      return nil
    end
    function battleAssets:renderPictures(hostGraphics, pictures)
      return pass:render(hostGraphics, pictures)
    end
    local firstHash = nil
    local changed = false
    local visible = false
    local battlerSpriteObserved = false
    for tick = 1, 900 do
      player:stepSourceTick({ tick = tick })
      local renderBattlers = {}
      for _, battler in ipairs(battlers) do
        local state = scene:pictureState(battler)
        local copy = {}
        for field, value in pairs(battler) do
          copy[field] = value
        end
        if state ~= nil then
          for field, value in pairs(state) do
            copy[field] = value
          end
        end
        renderBattlers[#renderBattlers + 1] = copy
      end
      for _, view in ipairs(scene:effectViews()) do
        local source = view.picture
        if source ~= nil then
          battlerSpriteObserved = battlerSpriteObserved or source.battlerActivation ~= nil
        end
      end
      local battleView = {
        battlers = renderBattlers,
        slotGeometry = slots,
        effectInstances = scene:effectViews(),
        bgScroll = scene:scroll(),
        hudSections = {},
      }
      local sampled = tick % SAMPLE_EVERY == 1
      if sampled then
        graphics.setCanvas(canvas)
        graphics.clear(0, 0, 0, 0)
        BattleRenderer.drawPane({
          graphics = graphics,
          text = {},
          windows = {},
          assets = battleAssets,
          sceneImageKey = "missing-scene",
        }, battleView, "detail", {}, { x = 0, y = 0, scale = 1 })
        graphics.setCanvas()
        local hash, covered = nativePixels(scope:own(canvas:newImageData()))
        visible = visible or covered > 0
        if firstHash == nil then
          firstHash = hash
        elseif hash ~= firstHash then
          changed = true
        end
      end
      if player:status(handle) == "complete" or player:status(handle) == "failed" then
        break
      end
    end
    local taskKinds = table.concat(effect.program.taskKinds or {}, ",")
    local missingSpriteLifecycle = key == "HYPNOSIS" and (not battlerSpriteObserved or #scene:effectViews() ~= 0)
    if not visible or not changed or player:status(handle) ~= "complete" or missingSpriteLifecycle then
      local failure = player:failure(handle) or {}
      failures[#failures + 1] = key
        .. " visible="
        .. tostring(visible)
        .. " changed="
        .. tostring(changed)
        .. " phase="
        .. tostring(player:status(handle))
        .. " taskKinds="
        .. taskKinds
        .. " effectViews="
        .. tostring(#scene:effectViews())
        .. " failure="
        .. tostring(failure.op)
        .. "@"
        .. tostring(failure.instructionIndex)
        .. ":"
        .. tostring(failure.reason)
        .. " battlerSpriteObserved="
        .. tostring(battlerSpriteObserved)
    end
    pass:release()
    player:dispose()
    scene:release()
  end
  Assert.isTrue(#failures == 0, table.concat(failures, "; "))
end

function T.source_programs_paint_native_pixels(scope)
  runVersion(scope, firstReadyVersion())
end

local suite = GraphicsSmoke.suite(T, {
  capabilities = { "graphics", "derived_assets" },
  tags = { "battle", "animation" },
})
suite.metadata.derivedAssets = { "battle-effect:TAIL_WHIP", "battle-effect:HYPNOSIS" }
return suite
