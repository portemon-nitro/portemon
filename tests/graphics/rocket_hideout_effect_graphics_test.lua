-- Graphics regression for the Rocket hideout's own script-driven effects. The
-- test compiles the three trap models and the alarm overlay straight from the
-- user's ROM, realizes them through the production GPU pool and story-effect
-- adapter, and draws them over a bright target: the models render, their
-- published anchor decides where they land, and the alarm overlay paints its
-- source tilemap under the pulse alpha.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldCamera = require("libs.hgss.src.field.FieldCamera")
local FieldEffects = require("romdump.src.config.FieldEffects")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local GpuAssetPool = require("libs.hgss.src.presentation.GpuAssetPool")
local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local GeneratedCacheFixture = require("tests.support.GeneratedCacheFixture")
local ImageAssetPool = require("libs.hgss.src.presentation.ImageAssetPool")
local MeshWriter = require("libs.assets.src.model.MeshWriter")
local ResidentCache = require("libs.storage.src.ResidentCache")
local RomImporter = require("romdump.src.source.RomImporter")
local RomSourcePath = require("tests.rom.support.RomSourcePath")
local StoryEffectAssetCompiler = require("romdump.src.digest.field.StoryEffectAssetCompiler")
local StoryEffectRenderer = require("libs.hgss.src.presentation.StoryEffectRenderer")

local T = {}

local BACKGROUND = { 0.2, 0.7, 0.9 }

local function runtime()
  local fogTable = {}
  for i = 1, 32 do
    fogTable[i] = 0
  end
  return {
    mapDraws = {},
    buildingDraws = {},
    edgeColors = { [0] = 0, 0, 0, 0, 0, 0, 0, 0 },
    fog = { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = fogTable },
  }
end

-- Renders one snapshot and answers the changed-pixel box and centroid.
local function drawSnapshot(fieldRenderer, camera, items, canvas)
  love.graphics.setCanvas(canvas)
  love.graphics.clear(BACKGROUND[1], BACKGROUND[2], BACKGROUND[3], 1)
  fieldRenderer:draw(runtime(), camera, { items }, nil, FieldViewport.new(256, 192, { mode = "strict" }), nil, 3)
  love.graphics.setCanvas()
  local image = canvas:newImageData()
  local changed, sumX, sumY = 0, 0, 0
  local minX, minY = image:getWidth(), image:getHeight()
  local maxX, maxY = -1, -1
  for y = 0, image:getHeight() - 1 do
    for x = 0, image:getWidth() - 1 do
      local r, g, b = image:getPixel(x, y)
      local isBackground = math.abs(r - BACKGROUND[1]) < 0.02
        and math.abs(g - BACKGROUND[2]) < 0.02
        and math.abs(b - BACKGROUND[3]) < 0.02
      if not isBackground then
        changed = changed + 1
        sumX, sumY = sumX + x, sumY + y
        minX, minY = math.min(minX, x), math.min(minY, y)
        maxX, maxY = math.max(maxX, x), math.max(maxY, y)
      end
    end
    end
  return {
    changed = changed,
    centroidX = changed > 0 and sumX / changed or 0,
    centroidY = changed > 0 and sumY / changed or 0,
    minX = minX,
    minY = minY,
    maxX = maxX,
    maxY = maxY,
  }
end

-- The compiled source effects for one ready version, straight from the ROM: no
-- derived-cache generation is involved, so the graphics gate always exercises
-- the current producer.
local function compiledEffects(context)
  local versionId = nil
  for _, candidate in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(candidate) then
      versionId = candidate
      break
    end
  end
  if versionId == nil then
    context:skip("the source ROM is unavailable")
    return nil
  end
  local romFs, source = RomSourcePath.openReader(versionId)
  if romFs == nil then
    context:skip("the source ROM could not be opened")
    return nil
  end
  local meshes, textures = {}, {}
  local compiled = assert(StoryEffectAssetCompiler.compile(romFs, meshes, textures))
  romFs:close()
  source:release()
  local traps = {}
  for _, sourceModel in ipairs(FieldEffects.hideoutTrapModels) do
    traps[sourceModel.key] = assert(compiled.definitions[sourceModel.key])
  end
  local overlay = assert(compiled.definitions[FieldEffects.hideoutAlarmOverlay.key]).overlay
  return versionId, { trap = traps, overlay = assert(overlay) }, { meshes = meshes, textures = textures }
end

-- One compiled effect bundle realized through the production pool: the compiled
-- bytes and the camera profiles the renderer needs live in one disposable
-- resident view, exactly the reader a selected epoch installs.
local function stageCompiledAssets(versionId, compiled)
  local sourceId = "base:rocket-effect-graphics-test"
  local store = ResidentCache.new(versionId, sourceId)
  local function entry(path, bytes)
    assert(type(bytes) == "string", "staged compiled asset is bytes: " .. path)
    return {
      path = path,
      data = assert(love.data.newByteData(bytes)),
      size = #bytes,
      sourceId = sourceId,
      contentId = versionId .. "\0" .. path,
    }
  end
  local entries = {}
  for sha1, mesh in pairs(compiled.meshes) do
    -- A compiled mesh is either finalized native bank bytes or a raw batch the
    -- writer encodes here, exactly like the effect bundle writer.
    local bytes = mesh
    if type(mesh) == "table" and type(mesh.getSize) ~= "function" then
      bytes = MeshWriter.encode(mesh)
    end
    entries[#entries + 1] = entry(FieldEffectAssetCache.geometryPath(sha1), bytes)
  end
  for sha1, texture in pairs(compiled.textures) do
    if type(texture) == "table" then
      entries[#entries + 1] = entry(FieldEffectAssetCache.imagePath(sha1), assert(texture.data))
    else
      entries[#entries + 1] = entry(FieldEffectAssetCache.texturePath(sha1), texture)
    end
  end
  local cameraProfiles = assert(
    GeneratedCacheFixture.reader(versionId):loadLua("data/generated/field/camera/profiles.lua"),
    "the prepared cache carries its camera profiles"
  )
  entries[#entries + 1] = entry(
    "data/generated/field/camera/profiles.lua",
    require("libs.codec.src.LuaWriter").encode(cameraProfiles)
  )
  store:commit(store:prepare(entries))
  return CacheFs.fromStore(store)
end

-- The shared image owner the pooled renderer borrows: a real preparation queue
-- and decoded budget over the staged resident view.
---@param scope table graphics ownership scope
---@param cache table resident staged view
---@return table image owner
local function stagedImageOwner(scope, cache)
  local AssetPreparationQueue = require("libs.hgss.src.presentation.AssetPreparationQueue")
  local ResidentAssetCache = require("libs.hgss.src.field.ResidentAssetCache")
  local decoded = ResidentAssetCache.new({
    idleByteLimit = 32 * 1024 * 1024,
    release = function(value)
      if type(value) == "table" and type(value.release) == "function" then
        value:release()
      end
    end,
  })
  local queue = AssetPreparationQueue.new(cache, { decoded = decoded })
  local owner = ImageAssetPool.new(cache, { graphics = love.graphics, queue = queue, decoded = decoded })
  return scope:own({
    pool = owner,
    release = function(self)
      self.pool:dispose()
      queue:release()
    end,
  }).pool
end

function T.the_trap_models_render_at_their_published_anchor(scope, context)
  local versionId, definitions, compiled = compiledEffects(context)
  if versionId == nil then
    return
  end
  local cache = stageCompiledAssets(versionId, compiled)
  local imagePool = stagedImageOwner(scope, cache)
  local pool = scope:own(GpuAssetPool.new(cache, { imageAssets = imagePool }))
  local renderer = StoryEffectRenderer.new(definitions, pool)
  scope:own({
    release = function()
      renderer:dispose()
    end,
  })
  local cameraProfiles = assert(cache:loadLua("data/generated/field/camera/profiles.lua"))
  local camera = FieldCamera.new(cameraProfiles.profiles[0], { canonicalAspect = 4 / 3 })
  local fieldRenderer =
    scope:own(FieldRenderer.new({ clearColor = { BACKGROUND[1], BACKGROUND[2], BACKGROUND[3], 1 } }))
  local canvas = scope:own(love.graphics.newCanvas(256, 192))

  for _, source in ipairs(FieldEffects.hideoutTrapModels) do
    local trap = renderer:newTrap(source.key)
    scope:own({
      release = function()
        trap:dispose()
      end,
    })
    trap:start()
    -- A source trap clip starts at its first frame, which may still be a
    -- pre-roll pose; advance the owned clip clock until the effect shows.
    local base
    for _ = 1, 90 do
      base = drawSnapshot(
        fieldRenderer,
        camera,
        renderer:drawItems({ trap = { kind = source.key, x = 0, y = 0, z = 0, rotationDegrees = 0 } }),
        canvas
      )
      if base.changed > 0 then
        break
      end
      trap:updateFixed()
    end
    Assert.isTrue(base.changed > 0, "the " .. source.key .. " model must render visible pixels")
    local moved = drawSnapshot(
      fieldRenderer,
      camera,
      renderer:drawItems({ trap = { kind = source.key, x = 2, y = 0, z = 0, rotationDegrees = 0 } }),
      canvas
    )
    Assert.isTrue(moved.centroidX > base.centroidX, "a trap anchored two tiles east draws further right")
    trap:dispose()
  end
end

function T.the_alarm_overlay_paints_its_source_tilemap(scope, context)
  local versionId, definitions, compiled = compiledEffects(context)
  if versionId == nil then
    return
  end
  local cache = stageCompiledAssets(versionId, compiled)
  local imagePool = stagedImageOwner(scope, cache)
  local pool = scope:own(GpuAssetPool.new(cache, { imageAssets = imagePool }))
  local renderer = StoryEffectRenderer.new(definitions, pool)
  scope:own({
    release = function()
      renderer:dispose()
    end,
  })
  local canvas = scope:own(love.graphics.newCanvas(256, 192))

  local function paint(blend)
    love.graphics.setCanvas(canvas)
    love.graphics.clear(BACKGROUND[1], BACKGROUND[2], BACKGROUND[3], 1)
    local drawn = renderer:drawAlarmOverlay({ alarm = { pulse = 0, blend = blend } })
    love.graphics.setCanvas()
    local image = canvas:newImageData()
    local changed = 0
    for y = 0, image:getHeight() - 1 do
      for x = 0, image:getWidth() - 1 do
        local r, g, b = image:getPixel(x, y)
        if
          math.abs(r - BACKGROUND[1]) >= 0.02
          or math.abs(g - BACKGROUND[2]) >= 0.02
          or math.abs(b - BACKGROUND[3]) >= 0.02
        then
          changed = changed + 1
        end
        end
    end
    return drawn, changed
  end

  local darkDrawn, darkPixels = paint(0)
  Assert.isTrue(darkDrawn == true, "the alarm overlay reports one painted frame")
  local brightDrawn, brightPixels = paint(12)
  Assert.isTrue(brightDrawn == true, "the alarm overlay paints every presented pulse")
  Assert.isTrue(brightPixels > darkPixels, "a stronger source pulse covers the screen with more overlay pixels")
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.derivedAssets = { "field-camera:global" }
return suite
