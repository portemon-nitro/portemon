-- A launch returning to a warmup-retired scene re-acquires its layer:
-- idle warmup retires a superseded scene's pins once its successor group
-- completes, so preparation must not reuse the staged memo through the
-- released leases on the next launch at the retired scene.
local Assert = require("tests.support.Assert")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldBattlePresentation = require("game.hgss.src.field.FieldBattlePresentation")
local ImageAssetPool = require("libs.hgss.src.presentation.ImageAssetPool")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local SCENE_A = "building_1/building/day"
local SCENE_B = "general/plain/day"

local function measurement(signature)
  return {
    width = 256,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
    ),
    pixelRatio = 1,
    signature = signature,
  }
end

local function recordingText()
  local text = { measures = 0 }
  function text.measure(content)
    text.measures = text.measures + 1
    return { width = 8 * #tostring(content), height = 16 }
  end
  function text.drawText(content, x, y) end
  return text
end

local function recordingWindows()
  local windows = {}
  function windows.drawWindow(...) end
  function windows.drawApplicationFrame(...) end
  return windows
end

-- Host graphics behind real pool leases: real ImageData sizes the staged
-- handles while every draw records instead of reaching a GPU.
local function stubGraphics()
  local graphics = { paint = 0 }
  local function paint()
    graphics.paint = graphics.paint + 1
  end
  function graphics.getImageFormats()
    return {}
  end
  function graphics.newImage(data)
    local width, height = 8, 8
    if data ~= nil and type(data.getDimensions) == "function" then
      local decoded, decodedWidth, decodedHeight = pcall(function()
        return data:getDimensions()
      end)
      if decoded and type(decodedWidth) == "number" and type(decodedHeight) == "number" then
        width, height = decodedWidth, decodedHeight
      end
    end
    local image = { width = width, height = height }
    function image.setFilter(_, _, _) end
    function image.setWrap(_, _, _) end
    function image.release() end
    function image.getWidth()
      return width
    end
    function image.getHeight()
      return height
    end
    function image.getDimensions()
      return width, height
    end
    return image
  end
  function graphics.newQuad(x, y, w, h, imgW, imgH)
    return { x = x, y = y, w = w, h = h, imgW = imgW, imgH = imgH }
  end
  function graphics.newShader(_)
    local shader = {}
    function shader.send(_, _, _) end
    function shader.release() end
    return shader
  end
  function graphics.getShader()
    return nil
  end
  function graphics.setShader(_)
    paint()
  end
  function graphics.draw(_, _, _, _)
    paint()
  end
  return graphics
end

-- Synchronous worker stand-in: every classification pends a few polls
-- before publishing per-path pixel identity, like the real background
-- worker. Sized to the largest staged battle page so frame bounds checks
-- pass against stub pixels.
local function stubQueue()
  local jobs = {}
  local nextJob = 0
  local queue = {}
  function queue:request(kind, path, _)
    assert(kind == "image-derivative", "the stub queue serves image derivatives only")
    nextJob = nextJob + 1
    jobs[nextJob] = { state = "pending", polls = 0, path = path }
    return nextJob
  end
  function queue:poll(job)
    local record = assert(jobs[job], "unknown preparation token")
    if record.state == "pending" then
      record.polls = record.polls + 1
      if record.polls >= 3 then
        local pixels = string.rep("\7\11\13\255", 640 * 320)
        record.state = "ready"
        record.payload = {
          sourceHash = "stub-source-for-" .. record.path,
          pixelHash = "stub-pixels-for-" .. record.path,
          width = 640,
          height = 320,
          kind = "rgba8",
          colors = 0,
          indexData = love.data.newByteData(pixels),
          paletteData = nil,
        }
      end
    end
    return record.state
  end
  function queue:take(job)
    local record = assert(jobs[job], "unknown preparation token")
    assert(record.state == "ready", "preparation result is not ready")
    jobs[job] = nil
    return record.payload
  end
  function queue:cancel(job)
    assert(jobs[job], "unknown preparation token")
    jobs[job] = nil
  end
  function queue:release() end
  return queue
end

local function readyVersions()
  local GameVersion = require("romdump.src.source.GameVersion")
  local RomImporter = require("romdump.src.source.RomImporter")
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      return { versionId }
    end
  end
  error("retired scene staging needs a ready versioned cache", 0)
end

local function demandFor(launchId, sceneKey)
  return {
    launchId = launchId,
    scenes = { sceneKey },
    pages = {},
    trainerPictures = {},
    battleBalls = {},
    iconKeys = {},
    audio = { roles = {}, banks = {}, cries = {} },
  }
end

function T.retired_scene_layer_reacquires_before_its_next_launch()
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs = CacheFs.forVersion(versionId)
    local graphics = stubGraphics()
    local pool = ImageAssetPool.new(cacheFs, { graphics = graphics, queue = stubQueue() })
    local envelope = FieldBattlePresentation.new({
      cacheFs = cacheFs,
      windows = recordingWindows(),
      text = recordingText(),
      measureDisplay = function()
        return measurement("retired-scene:dual")
      end,
      graphics = graphics,
      imagePool = pool,
      derivedAssets = {
        requestBattleScene = function(_, _)
          return true
        end,
        requestBattlePresentation = function(_)
          return true
        end,
        requestAudioBank = function(_, _)
          return true
        end,
      },
    })
    local ok, failure = xpcall(function()
      local services = envelope._services
      Assert.isTrue(services.prepare(demandFor("first", SCENE_A)), "the first scene prepares")
      local sceneImage = assert(services.drawable("scene:" .. SCENE_A), "the first scene image resolves")
      local firstLayer = assert(services.sceneLayer(), "the first launch stages its layer")
      -- Battle teardown releases the holder-owned scene image while the
      -- envelope pins keep the group; the layer drawables stay staged.
      services.release("scene:" .. SCENE_A)
      Assert.isTrue(sceneImage ~= nil, "the released scene image stays readable")
      -- Idle warmup adopts the other scene to completion, retiring the
      -- first scene's pins while the staged memo still names it.
      for _ = 1, 60 do
        envelope:advanceWarmup(SCENE_B, 1)
      end
      Assert.isNil(
        envelope._warmPinned["scene-intro:" .. SCENE_A],
        "warmup retires the superseded scene group"
      )
      Assert.notNil(envelope._warmPinned["scene-intro:" .. SCENE_B], "warmup completes the successor group")
      -- The next launch at the retired scene re-acquires instead of
      -- drawing released leases through the stale memo.
      Assert.isTrue(services.prepare(demandFor("second", SCENE_A)), "the retired scene prepares again")
      local secondLayer = assert(services.sceneLayer(), "the second launch stages its layer")
      local introOk, introErr = pcall(secondLayer.introLayer.drawable.draw, secondLayer.introLayer.drawable, graphics, 0, 0)
      Assert.isTrue(introOk, "the re-acquired intro draws: " .. tostring(introErr))
      local playerOk, playerErr =
        pcall(secondLayer.terrainSprites.player.drawable.draw, secondLayer.terrainSprites.player.drawable, graphics, 0, 0)
      Assert.isTrue(playerOk, "the re-acquired player terrain draws: " .. tostring(playerErr))
      local foeOk, foeErr =
        pcall(secondLayer.terrainSprites.foe.drawable.draw, secondLayer.terrainSprites.foe.drawable, graphics, 0, 0)
      Assert.isTrue(foeOk, "the re-acquired foe terrain draws: " .. tostring(foeErr))
    end, debug.traceback)
    pcall(function()
      envelope:dispose()
    end)
    pcall(function()
      pool:dispose()
    end)
    if not ok then
      error(failure, 0)
    end
  end
end

return {
  tests = T,
  metadata = {
    capabilities = { "rom_dump", "derived_assets" },
    derivedAssets = {
      "battle-presentation:global",
      "battle-scene:building_1/building/day",
      "battle-scene:general/plain/day",
    },
  },
}
