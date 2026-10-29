local Assert = require("tests.support.Assert")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local FieldBattlePresentation = require("game.hgss.src.field.FieldBattlePresentation")
local MoveIconCache = require("libs.assets.src.MoveIconCache")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local function graphicsManifest()
  local function art(path)
    return { image = path }
  end
  local function menu(path)
    return { image = path, screens = { { image = path } } }
  end
  local path = "assets/generated/battle/synthetic.png"
  return {
    verified = true,
    pictures = { shadow = art(path) },
    hud = {
      player = art(path),
      enemy = art(path),
      doubles = {
        playerLeft = art(path),
        playerRight = art(path),
        enemyLeft = art(path),
        enemyRight = art(path),
      },
      cursor = art(path),
      arrow = art(path),
      partyGauges = { art(path), art(path) },
    },
    menus = {
      command = menu(path),
      moves = menu(path),
      target = menu(path),
      twoOption = menu(path),
      lower = { pulseMask = path },
    },
    messages = {
      roles = {
        narration = { font = "fonts/narration" },
        menu = { font = "fonts/menu" },
        hud = { font = "fonts/hud" },
      },
    },
    audioRoles = { wild = "wild", trainer = "trainer", rival = "rival", select = "select" },
  }
end

local function sceneRecord(sceneKey)
  local introPath = BattlePresentationCache.sceneIntroImagePath(sceneKey)
  local playerPath = BattlePresentationCache.sceneTerrainSpritePath(sceneKey, "player")
  local foePath = BattlePresentationCache.sceneTerrainSpritePath(sceneKey, "foe")
  local charsPath = BattlePresentationCache.sceneCharactersPath(sceneKey)
  local mapPath = BattlePresentationCache.sceneMapPath(sceneKey)
  local palettePath = BattlePresentationCache.scenePalettePath(sceneKey)
  return {
    schema = BattlePresentationCache.SCENE_SCHEMA,
    key = sceneKey,
    background = "general",
    terrain = "plain",
    time = "day",
    canvasWidth = 512,
    canvasHeight = 256,
    viewport = { x = 0, y = 0, width = 256, height = 192 },
    layers = {
      {
        key = "background",
        backing = { width = 512, height = 256, mapWidth = 64, mapHeight = 32 },
        viewport = { x = 0, y = 0, width = 256, height = 192 },
        scroll = { x = 0, y = 0 },
        characters = {
          key = "battle-scene/general-plain-day/background/characters",
          path = charsPath,
          format = "indexed8",
        },
        map = {
          key = "battle-scene/general-plain-day/background/map",
          path = mapPath,
          format = "tilemap",
        },
        palette = {
          key = "battle-scene/general-plain-day/background/palette",
          path = palettePath,
          format = "rgb888",
        },
      },
    },
    imagePath = BattlePresentationCache.sceneImagePath(sceneKey),
    introLayer = { image = introPath, width = 512, height = 256 },
    terrainSprites = {
      player = { image = playerPath, width = 48, height = 24, origin = { x = 24, y = 12 } },
      foe = { image = foePath, width = 40, height = 20, origin = { x = 20, y = 10 } },
    },
  }
end

local SCENE_KEY = "general/plain/day"

local function stagedCacheFs(record)
  local mapEntries = {}
  for index = 1, 2048 do
    mapEntries[index] = { tile = 0, flipH = false, flipV = false, palette = 0 }
  end
  local paletteColors = {}
  for index = 1, 256 do
    paletteColors[index] = { r = 0, g = 0, b = 0 }
  end
  local cacheFs = { versionId = "synthetic" }
  function cacheFs:loadLua(path)
    if path == BattlePresentationCache.scenePath(SCENE_KEY) then
      return record
    end
    if path == BattlePresentationCache.sceneMapPath(SCENE_KEY) then
      return { width = 512, height = 256, entries = mapEntries }
    end
    if path == BattlePresentationCache.scenePalettePath(SCENE_KEY) then
      return { colors = paletteColors }
    end
    if path == MoveIconCache.manifestPath() then
      return { schema = MoveIconCache.SCHEMA, types = {}, categories = {} }
    end
    return nil
  end
  function cacheFs:read(path)
    if path == record.layers[1].characters.path then
      return string.rep("c", 65536)
    end
    return "staged"
  end
  function cacheFs:exists(_, _)
    return true
  end
  return cacheFs
end

-- Pool whose images become ready after `pendingPolls` polls, except the
-- paths in `failures`; it ledgers every lease it hands out and takes back.
local function ledgerPool(pendingPolls, failures)
  local pool = { acquired = {}, released = {}, polls = {} }
  function pool:request(path)
    return path
  end
  function pool:poll(token)
    self.polls[token] = (self.polls[token] or 0) + 1
    if failures[token] ~= nil then
      return "failed", failures[token]
    end
    if self.polls[token] <= pendingPolls then
      return "pending"
    end
    return "ready", token
  end
  function pool:acquire(token)
    local lease = { image = { path = token } }
    self.acquired[#self.acquired + 1] = lease
    return lease
  end
  function pool:release(lease)
    self.released[#self.released + 1] = lease
  end
  return pool
end

local function newEnvelope(cacheFs, imagePool)
  local envelope = FieldBattlePresentation.new({
    cacheFs = cacheFs,
    windows = { drawWindow = function() end, drawApplicationFrame = function() end },
    text = {
      measure = function()
        return { width = 0, height = 0 }
      end,
      drawText = function() end,
    },
    measureDisplay = function()
      return {
        width = 256,
        height = 384,
        topology = ScreenTopology.dualDisplay(
          { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
          { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
        ),
        pixelRatio = 1,
        signature = "scene-assets",
      }
    end,
    graphics = {},
    imagePool = imagePool,
  })
  envelope._manifest = graphicsManifest()
  return envelope
end

local function prepareScene(services)
  return services.prepare({
    launchId = "scene-assets",
    scenes = { SCENE_KEY },
    pages = {},
    trainerPictures = {},
    battleBalls = {},
    iconKeys = {},
    audio = { roles = {}, banks = {}, cries = {} },
  })
end

local function leasePaths(leases)
  local paths = {}
  for index, lease in ipairs(leases) do
    paths[index] = lease.image.path
  end
  table.sort(paths)
  return paths
end

function T.preparation_retains_intro_and_terrain_drawables_with_source_metadata()
  local record = sceneRecord(SCENE_KEY)
  local pool = ledgerPool(2, {})
  local envelope = newEnvelope(stagedCacheFs(record), pool)
  local services = envelope:_preparationServices()
  local ready, failure = prepareScene(services)
  Assert.isTrue(ready, "the staged scene and its intro assets prepare: " .. tostring(failure))
  local layer = assert(services.sceneLayer(), "the prepared scene layer is retained")
  Assert.equal(#pool.acquired, 3, "the intro and both terrain images are leased from the shared pool")
  Assert.isTrue(layer.introLayer.drawable ~= nil, "the unbaked intro layer carries its pooled drawable")
  Assert.equal(layer.introLayer.width, record.introLayer.width, "the intro canvas size is retained")
  Assert.equal(layer.introLayer.height, record.introLayer.height, "the intro canvas size is retained")
  for _, side in ipairs({ "player", "foe" }) do
    local sprite = layer.terrainSprites[side]
    local source = record.terrainSprites[side]
    Assert.isTrue(sprite.drawable ~= nil, side .. " OBJ carries its pooled drawable")
    Assert.deepEqual(
      { sprite.width, sprite.height, sprite.origin.x, sprite.origin.y },
      { source.width, source.height, source.origin.x, source.origin.y },
      side .. " OBJ keeps its source size and origin"
    )
  end
  envelope:dispose()
  Assert.deepEqual(
    leasePaths(pool.released),
    leasePaths(pool.acquired),
    "disposal returns each retained lease exactly once"
  )
end

function T.failed_terrain_upload_returns_the_leases_it_already_holds()
  local record = sceneRecord(SCENE_KEY)
  local pool = ledgerPool(0, { [record.terrainSprites.foe.image] = "probe-foe-upload-failed" })
  local envelope = newEnvelope(stagedCacheFs(record), pool)
  local ready, failure = prepareScene(envelope:_preparationServices())
  Assert.isNil(ready, "a failed foe terrain upload never prepares the scene")
  Assert.isTrue(
    type(failure) == "string" and failure:find("probe-foe-upload-failed", 1, true) ~= nil,
    "the failed upload preserves its pool cause"
  )
  Assert.isTrue(#pool.acquired > 0, "the other images were leased before the failure")
  Assert.deepEqual(
    leasePaths(pool.released),
    leasePaths(pool.acquired),
    "every lease taken before the failure is returned"
  )
  local releasedBefore = #pool.released
  envelope:dispose()
  Assert.equal(#pool.released, releasedBefore, "disposal does not release rolled-back leases twice")
end

return { tests = T }
