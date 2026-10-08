-- Real generated overhead emotes through the production loader, model,
-- material, and presentation sprite-layer paths: the follower reaction's
-- pattern clip follows the emote tick after the shared entrance bounce, and
-- every emote billboard composites in the sprite layer.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldActorEmote = require("libs.hgss.src.actors.FieldActorEmote")
local FieldActorEmoteRenderer = require("libs.hgss.src.presentation.FieldActorEmoteRenderer")
local FieldActorEmoteRuntime = require("game.hgss.src.field.FieldActorEmoteRuntime")
local FieldCamera = require("libs.hgss.src.field.FieldCamera")
local FieldEntranceIndicatorRuntime = require("game.hgss.src.field.FieldEntranceIndicatorRuntime")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local GameVersion = require("romdump.src.source.GameVersion")
local GpuAssetPool = require("libs.hgss.src.presentation.GpuAssetPool")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local RomImporter = require("romdump.src.source.RomImporter")

local WORLD = { x = 0, y = 0, z = 0 }

local function sceneRuntime()
  local fogTable = {}
  for index = 1, 32 do
    fogTable[index] = 0
  end
  return {
    mapDraws = {},
    buildingDraws = {},
    edgeColors = { [0] = 0, 0, 0, 0, 0, 0, 0, 0 },
    fog = { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = fogTable },
  }
end

local function record(kind, tick)
  return { actorId = "partner", activeEmoteKind = kind, activeEmoteTick = tick, world = WORLD }
end

local function assertSpriteItems(items, label)
  Assert.isTrue(#items > 0, label .. " must produce a real draw item")
  for _, item in ipairs(items) do
    Assert.isTrue(item.billboardProjection, label .. " must route to the presentation sprite layer")
    local bounds = assert(item.bounds, label .. " must carry sprite-layer bounds")
    Assert.isTrue(bounds.width > 0 and bounds.height > 0, label .. " bounds must be mesh extents")
  end
end

local function runVersion(scope, versionId)
  local cache = CacheFs.forVersion(versionId)
  local fieldEffects = FieldEntranceIndicatorRuntime.load(cache)
  local models, reactionTicks = FieldActorEmoteRuntime.load(cache, fieldEffects.effects)
  local pool = scope:own(GpuAssetPool.new(cache))
  local renderer = FieldActorEmoteRenderer.new(models, pool)
  scope:own({
    release = function()
      renderer:dispose()
    end,
  })
  local cameraProfiles = assert(cache:loadLua("data/generated/field/camera/profiles.lua"))
  local camera = FieldCamera.new(cameraProfiles.profiles[0], { canonicalAspect = 4 / 3 })
  local fieldRenderer = FieldRenderer.new({ clearColor = { 0.1, 0.2, 0.3, 1 } })
  scope:own({
    release = function()
      fieldRenderer:release()
    end,
  })
  local viewport = FieldViewport.new(256, 192, { mode = "strict" })
  local target = scope:own(love.graphics.newCanvas(256, 192))
  local function composite(items)
    love.graphics.setCanvas(target)
    fieldRenderer:draw(sceneRuntime(), camera, {}, items, viewport, 0, 3)
    love.graphics.setCanvas()
    return fieldRenderer.stats.spriteCompositeArea
  end

  local exclamation = renderer:drawItems({ record("exclamation", 1) })
  assertSpriteItems(exclamation, "the exclamation")
  Assert.isTrue(composite(exclamation) > 0, "the exclamation must composite in the sprite layer")

  local kind = "follower_reaction_1"
  local ticks = assert(reactionTicks[kind])
  local frameCount = fieldEffects.effects[kind].lifecycle.frameCount
  Assert.equal(ticks, FieldActorEmote.reactionTicks(frameCount), "the composed duration follows the clip")
  local images, restingCenterY = {}, nil
  for tick = 1, ticks - 1 do
    local items = renderer:drawItems({ record(kind, tick) })
    assertSpriteItems(items, kind .. " tick " .. tick)
    images[tick] = items[1].material.image
    local centerY = items[1].billboardCenter[2] - FieldActorEmote.bounceOffsetY(tick)
    restingCenterY = restingCenterY or centerY
    Assert.near(centerY, restingCenterY, 1e-9, "only the entrance bounce moves the reaction at tick " .. tick)
    if tick == 1 then
      Assert.isTrue(composite(items) > 0, "the reaction must composite in the sprite layer")
    end
  end
  for tick = 2, 7 do
    Assert.equal(images[tick], images[1], "the reaction holds its first pattern frame through the bounce")
  end
  local changed = false
  for tick = 8, ticks - 1 do
    changed = changed or images[tick] ~= images[1]
  end
  Assert.isTrue(changed, "the reaction's pattern clip advances after the bounce")
  Assert.equal(images[ticks - 1], images[ticks - 3], "the reaction holds its final frame through the tail")
end

local T = GraphicsSmoke.suite({
  ["generated emotes draw above their actor in the presentation sprite layer"] = function(scope)
    local versions = 0
    for _, versionId in ipairs(GameVersion.ORDER) do
      if RomImporter.isReady(versionId) then
        versions = versions + 1
        runVersion(scope, versionId)
      end
    end
    Assert.isTrue(versions > 0, "a ready imported game version is required")
  end,
})
T.metadata.capabilities = { "graphics", "rom_dump" }
T.metadata.derivedAssets = { "field-effects:global", "field-emotes:global", "field-camera:global" }
T.metadata.tags = { "field", "emote", "follower-interaction" }
return T
