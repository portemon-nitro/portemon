-- A saved photo is prepared by its private owner before the existing field
-- renderer receives the immutable view snapshot.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local CollisionFixture = require("tests.support.CollisionFixture")
local FakeCache = require("tests.support.FakeCache")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldActorAssetProvider = require("libs.hgss.src.presentation.FieldActorAssetProvider")
local FieldActorDraw = require("libs.hgss.src.presentation.FieldActorDraw")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local MonBucket = require("tests.support.MonBucket")
local MonCache = require("libs.assets.src.MonCache")
local MonIconAssetProvider = require("libs.hgss.src.presentation.MonIconAssetProvider")
local PcCache = require("libs.assets.src.PcCache")
local PngWriter = require("libs.assets.src.PngWriter")
local PhotoAlbumInterface = require("game.hgss.src.pc.PhotoAlbumInterface")
local PhotoAlbumRenderer = require("libs.hgss.src.ui.PhotoAlbumRenderer")
local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local FieldMapLoader = require("libs.hgss.src.world.FieldMapLoader")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local GameVersion = require("romdump.src.source.GameVersion")
local HgssFieldEdgeColors = require("romdump.src.digest.field.HgssFieldEdgeColors")
local HgssFieldFog = require("romdump.src.digest.field.HgssFieldFog")
local RomImporter = require("romdump.src.source.RomImporter")

local T = {}

local function photoScene()
  local ok, scene = pcall(require, "game.hgss.src.pc.PhotoScene")
  Assert.isTrue(ok, "saved photo preparation must use the private PhotoScene owner")
  return assert(scene)
end

local function photoRenderer()
  local ok, renderer = pcall(require, "libs.hgss.src.presentation.PhotoSceneRenderer")
  Assert.isTrue(ok, "a prepared saved photo must compose through FieldRenderer")
  return assert(renderer)
end

local function preparedIcons(versionId, iconKey)
  local cacheFs = CacheFs.forVersion(versionId, FakeCache.new())
  local path = MonCache.iconPagePath(0)
  local manifest = {
    schema = MonCache.ICON_MANIFEST_SCHEMA,
    version = { id = versionId, language = "english" },
    pages = { [0] = { pageId = 0, image = path, width = 32, height = 32 } },
    pageIds = { 0 },
    entries = {
      [iconKey] = {
        x = 0,
        y = 0,
        width = 32,
        height = 32,
        frames = { { x = 0, y = 0, width = 32, height = 32, duration = 1 } },
        pageId = 0,
      },
    },
    representative = { iconKey },
  }
  cacheFs:writeLua(MonCache.iconManifestPath(), manifest)
  local pixels = string.rep(string.char(180, 60, 80, 255), 32 * 32)
  cacheFs:write(path, PngWriter.encode(32, 32, pixels))
  local live = {}
  local queue = {}
  function queue:request(_, imagePath)
    live[imagePath] = true
    return imagePath
  end
  function queue:poll(token)
    return live[token] and "ready" or "failed"
  end
  function queue:take(token)
    live[token] = nil
    local bytes = assert(cacheFs:read(token))
    return { imageData = love.image.newImageData(love.filesystem.newFileData(bytes, token)) }
  end
  function queue:cancel(token)
    live[token] = nil
  end
  local provider = MonIconAssetProvider.new(cacheFs, {
    preparationQueue = queue,
    derivedAssets = {
      requestIconPage = function()
        return true
      end,
    },
  })
  return provider
end

local function displayLayouts()
  local function measurement(width, height, topology, signature)
    return { width = width, height = height, topology = topology, pixelRatio = 1, signature = signature }
  end
  return {
    dualDisplay = measurement(
      912,
      684,
      ScreenTopology.dualDisplay({
        id = "world",
        rect = { x = 400, y = 100, width = 256, height = 192 },
        role = "world",
        touch = false,
      }, {
        id = "aux",
        rect = { x = 100, y = 300, width = 256, height = 192 },
        role = "auxiliary",
        touch = true,
      }),
      "photo-dual"
    ),
    nativeLike = measurement(
      640,
      480,
      ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 640, height = 480 },
        role = "world",
        touch = false,
      }),
      "photo-native"
    ),
    wide = measurement(
      1280,
      720,
      ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 1280, height = 720 },
        role = "world",
        touch = false,
      }),
      "photo-wide"
    ),
    tall = measurement(
      390,
      844,
      ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 20, y = 30, width = 390, height = 844 },
        role = "world",
        touch = false,
      }),
      "photo-tall"
    ),
  }
end

local function renderEnvironment()
  return {
    lighting = {
      records = {
        {
          endHalfSeconds = 0,
          lights = {},
          diffuseRgb555 = 0,
          ambientRgb555 = 0,
          specularRgb555 = 0,
          emissionRgb555 = 0,
        },
      },
    },
    edgeColors = HgssFieldEdgeColors.tableForAreaLightPattern(0),
    weatherId = 0,
    fog = HgssFieldFog.runtimePreset(HgssFieldFog.resolve(0)),
  }
end

local function observedText(textRenderer)
  local observed = { messages = {}, plain = {}, fontDef = textRenderer.fontDef }
  return setmetatable(observed, {
    __index = function(_, name)
      if name == "drawLine" then
        return function(_, tokens, x, y)
          observed.messages[#observed.messages + 1] = tokens
          return textRenderer:drawLine(tokens, x, y)
        end
      end
      if name == "drawText" then
        return function(_, text, x, y)
          observed.plain[#observed.plain + 1] = text
          return textRenderer:drawText(text, x, y)
        end
      end
      return function(_, ...)
        return textRenderer[name](textRenderer, ...)
      end
    end,
  })
end

local function photoRecord()
  return {
    schema = "g4-photo-v1",
    icon = 1,
    playerName = "GOLD",
    playerGender = 0,
    leadNickname = "LEAF",
    avatarState = "normal",
    mapSymbol = "MAP_PHOTO_TEST",
    fieldX = 5,
    fieldZ = 7,
    date = { year = 2010, month = 1, day = 2, weekday = 6 },
    hour = 18,
    minute = 37,
    party = {
      { species = "CHIKORITA", form = 0, gender = 1, shiny = true },
      false,
      false,
      false,
      false,
      false,
    },
    sourcePartyCount = 1,
    hiddenPropModels = { "hidden-center", "hidden-coverage" },
  }
end

local function fieldData()
  return {
    schema = FieldMapDataCache.FIELD_SCHEMA,
    initScripts = {},
    mapId = 41,
    mapSymbol = "MAP_PHOTO_TEST",
    cameraType = 0,
    transitionEnvironment = "outdoors",
    fieldUse = {
      flyAllowed = true,
      teleportAllowed = true,
      escapeAllowed = false,
      flashUsable = false,
      alphChamber = false,
      icePathB2F = false,
      cave = false,
      unionOrColosseum = false,
    },
    events = { background = {}, objects = {}, warps = {}, coordinates = {} },
    music = { day = "SEQ_X", night = "SEQ_X", flagOverrides = {}, traversalOverrides = {} },
    soundplates = {},
    renderEnvironment = renderEnvironment(),
  }
end

local function physicalCell(index, x)
  local file = FieldCellCache.cellPath(12, index)
  local cell = {
    schema = FieldCellCache.CELL_SCHEMA,
    matrixMemberId = 12,
    index = index,
    x = x,
    z = 6,
    mapHeaderId = 0,
    altitude = 0,
    origin = { x = x * 32, y = 0, z = 6 * 32 },
    landDataMemberId = 1,
    areaDataMemberId = 1,
    file = file,
    collision = { file = FieldCellCache.collisionPath(12, index) },
    terrain = { file = FieldCellCache.terrainPath(12, index), schema = "g4-terrain-surfaces-v1" },
    buildingInstances = {},
    terrainAnimations = { textureSrt = false },
  }
  return cell
end

local function fixture(versionId)
  local scene = {
    schema = MapAssetCache.SCENE_SCHEMA,
    mapId = 41,
    mapSymbol = "MAP_PHOTO_TEST",
    type = "outdoor",
    cameraType = 0,
    neighbors = {},
    buildingInstances = {},
    terrainAnimations = { textureSrt = false },
    matrix = { memberId = 12, width = 8, height = 8, x = 0, z = 0, worldOriginX = 96, worldOriginZ = 192 },
  }
  local map = {
    id = 41,
    symbol = scene.mapSymbol,
    mapSection = "TEST_SECTION",
    mapSectionNativeId = 7,
    followMode = "ALLOW",
    worldOriginX = 96,
    worldOriginZ = 192,
    matrix = { memberId = 12 },
  }
  local world = {
    schema = MapAssetCache.WORLD_SCHEMA,
    maps = { map },
    byId = { [41] = 1 },
    bySymbol = { [scene.mapSymbol] = 41 },
    analysis = { mapHeaderCount = 1, excluded = {} },
  }
  local cells = { physicalCell(0, 3), physicalCell(1, 4) }
  local synthetic = CacheFs.forVersion(versionId, FakeCache.new())
  local sourceCache = CacheFs.forVersion(versionId)
  local files = {
    [MapAssetCache.worldPath()] = world,
    [MapAssetCache.mapDir(41) .. "/scene.lua"] = scene,
    [FieldMapDataCache.fieldPath(41)] = fieldData(),
    [FieldCellCache.indexPath()] = {
      schema = FieldCellCache.INDEX_SCHEMA,
      matrices = { { matrixMemberId = 12, width = 8, height = 8, cells = cells } },
    },
  }
  local bytes = {}
  for _, cell in ipairs(cells) do
    files[cell.file] = cell
    files[cell.terrain.file] = {
      schema = "g4-terrain-surfaces-v1",
      source = { bdhcSha1 = "photo-cell-" .. cell.index },
      plates = {},
    }
    bytes[cell.collision.file] = CollisionFixture.asset(32, 32)
  end
  for path, value in pairs(files) do
    synthetic:writeLua(path, value)
  end
  for path, value in pairs(bytes) do
    synthetic:write(path, value)
  end
  local cacheFs = {
    loadLua = function(_, path)
      local value = synthetic:loadLua(path)
      if value ~= nil then
        return value
      end
      return sourceCache:loadLua(path)
    end,
    read = function(_, path)
      local value = synthetic:read(path)
      if value ~= nil then
        return value
      end
      return sourceCache:read(path)
    end,
    exists = function(_, path, kind)
      return synthetic:exists(path, kind) or sourceCache:exists(path, kind)
    end,
  }
  local derivedAssets = {
    requestField = function()
      return true
    end,
    requestLogicalField = function()
      return true
    end,
    requestCell = function()
      return true
    end,
    ensureField = function() end,
    ensureLogicalField = function() end,
    ensureCell = function() end,
  }
  local releases = { environment = 0, cells = 0 }
  local sceneLoader = {
    loadEnvironment = function(_, loadedScene)
      return {
        scene = loadedScene,
        staticBuildingDraws = { { modelKey = "hidden-center" } },
        animatedBuildingDraws = {},
        release = function()
          releases.environment = releases.environment + 1
        end,
      }
    end,
    loadCell = function(_, cell)
      return {
        cellKey = cell.x .. ":" .. cell.z,
        staticBuildingDraws = { { modelKey = cell.index == 0 and "hidden-center" or "hidden-coverage" } },
        animatedBuildingDraws = {},
        release = function()
          releases.cells = releases.cells + 1
        end,
      }
    end,
  }
  local loader = FieldMapLoader.new(cacheFs, world, { derivedAssets = derivedAssets, sceneLoader = sceneLoader })
  return cacheFs, world, derivedAssets, loader, sceneLoader, releases, versionId
end

function T.photo_owner_prepares_source_view_and_private_coverage_before_render(scope)
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      versions[#versions + 1] = versionId
    end
  end
  Assert.isTrue(#versions > 0, "a ready imported game version supplies real mon and field-actor assets")
  for _, versionId in ipairs(versions) do
    local cacheFs, _, derivedAssets, loader, _, releases = fixture(versionId)
    local liveCacheFs, liveWorld, _, liveLoader, _, liveReleases = fixture(versionId)
    local liveMap = liveLoader:load("MAP_PHOTO_TEST")
    local liveSceneRuntime = liveMap.sceneRuntime
    local liveEnvironment = liveMap.renderEnvironment
    local PhotoScene = photoScene()
    local photo = photoRecord()
    local catalog = MonBucket.openCatalogs(versionId)
    local follower = assert(catalog:followerSelection(photo.party[1]), "the saved species has a field follower")
    local actorProvider = FieldActorAssetProvider.new(cacheFs)
    local npcSpriteId
    for _, spriteId in ipairs(actorProvider:index().spriteIds) do
      if spriteId > 0 then
        npcSpriteId = spriteId
        break
      end
    end
    npcSpriteId = assert(npcSpriteId, "the real actor cache supplies a nonzero NPC sprite")
    photo.subjectSprite = tostring(npcSpriteId)
    local npcEntry = actorProvider:acquire(npcSpriteId)
    Assert.isTrue(
      actorProvider:knows(npcSpriteId),
      "the saved NPC sprite selection resolves through the actor provider"
    )
    local npcDraw = FieldActorDraw.items({
      {
        actorId = "saved-photo-subject",
        spriteId = npcSpriteId,
        world = { x = 7, y = -2 / 16, z = 7 },
        facing = "south",
        pose = "idle",
        poseTick = 0,
      },
    }, function()
      return npcEntry
    end)
    Assert.isTrue(#npcDraw > 0, "the production actor draw path builds the NPC sprite items")
    actorProvider:release(npcSpriteId)
    actorProvider:dispose()
    Assert.isTrue(
      cacheFs:loadLua(FieldActorCache.visualPath(follower.visualId)) ~= nil,
      "the ready actor cache contains the saved subject's production visual"
    )
    local liveField = {
      mapId = liveMap.mapId,
      fieldX = 18,
      fieldZ = 24,
      party = { "current-party-snapshot" },
      fieldTimeSeconds = 12345,
      loaderWorld = liveWorld,
      cacheFs = liveCacheFs,
    }
    local liveBefore = {
      mapId = liveField.mapId,
      fieldX = liveField.fieldX,
      fieldZ = liveField.fieldZ,
      party = { liveField.party[1] },
      fieldTimeSeconds = liveField.fieldTimeSeconds,
      loaderWorld = liveField.loaderWorld,
      cacheFs = liveField.cacheFs,
    }
    local scene = PhotoScene.new({
      versionId = versionId,
      cacheFs = cacheFs,
      derivedAssets = derivedAssets,
      profile = { name = "GOLD", gender = 0 },
      monCatalog = catalog,
      fieldMapLoader = loader,
    })

    scene:request(photo)
    local status = scene:status()
    Assert.equal(status.phase, "pending", "request starts private saved-map preparation")
    for _ = 1, 16 do
      if scene:status().phase ~= "pending" then
        break
      end
      scene:advance(16)
    end
    status = scene:status()
    Assert.equal(status.phase, "ready", "bounded loader work reaches a complete photo view")
    Assert.isNil(status.failure, "successful preparation carries no typed failure")
    local view = scene:takeReady()
    Assert.isTrue(type(view) == "table", "only a completed snapshot transfers to the screen")

    local calls = {}
    local actualFieldRenderer = scope:own(FieldRenderer.new({ clearColor = { 0.04, 0.05, 0.06, 1 } }))
    local photoTarget = scope:own(love.graphics.newCanvas(256, 192))
    local function renderableParts(parts)
      local lanes = {}
      for laneIndex, lane in ipairs(parts) do
        local draws = {}
        for _, item in ipairs(lane) do
          if type(item.alphaClass) == "string" then
            draws[#draws + 1] = item
          end
        end
        lanes[laneIndex] = draws
      end
      return lanes
    end
    local fieldRenderer = {
      draw = function(_, renderEnv, camera, worldParts, spriteItems, viewport, alpha, pixelScale)
        calls[#calls + 1] = {
          renderEnvironment = renderEnv,
          camera = camera,
          worldParts = worldParts,
          spriteItems = spriteItems,
          viewport = viewport,
          alpha = alpha,
        }
        actualFieldRenderer:draw(
          renderEnv,
          camera,
          renderableParts(worldParts),
          spriteItems,
          viewport,
          alpha,
          pixelScale
        )
      end,
    }
    love.graphics.setCanvas(photoTarget)
    photoRenderer().draw(view, { photoViewport = view.viewport }, { fieldRenderer = fieldRenderer })
    love.graphics.setCanvas()

    Assert.equal(#calls, 1, "a ready saved view reaches the real renderer adapter once")
    local call = assert(calls[1])
    Assert.equal(call.renderEnvironment.fieldTimeSeconds, 67020, "saved hour and minute set only the private clock")
    Assert.equal(call.camera.profile.projectionType, "perspective", "the source camera uses perspective projection")
    Assert.near(
      call.camera.profile.distanceTiles,
      666.922119140625 / 16,
      1e-12,
      "camera distance converts DS units once"
    )
    Assert.equal(call.camera.profile.angleXRaw, 0xEE00, "camera X angle remains the source raw angle")
    Assert.near(
      call.camera.profile.halfFovRadians,
      2 * math.pi * 0x230 / 65536,
      1e-12,
      "source perspective angle is converted once"
    )
    Assert.deepEqual(call.camera.profile.targetOffsetTiles, { x = 16.3125 / 16, y = 0, z = -47 / 16 })
    Assert.deepEqual(
      view.viewport,
      { x = 4, y = 3, width = 248, height = 185 },
      "the snapshot keeps native clipping separate"
    )
    Assert.deepEqual(
      call.viewport.worldViewport,
      { x = 4, y = 3, width = 248, height = 185 },
      "the render adapter uses an isolated native viewport"
    )
    Assert.isTrue(#call.spriteItems >= 3, "the snapshot carries the saved player, NPC subject and its Pokemon")
    local positions = {}
    for _, item in ipairs(view.subjects) do
      positions[item.world.x .. ":" .. item.world.z] = true
      Assert.equal(item.facing, "south", "saved subjects face the source direction")
    end
    local savedPokemonDrawn = false
    local savedNpcDrawn = false
    for _, item in ipairs(view.subjects) do
      if item.spriteId == follower.visualId then
        savedPokemonDrawn = true
        Assert.equal(item.world.x, 6.5, "the saved NPC follower uses its source +1 X offset")
        Assert.equal(item.world.z, 6.5, "the saved NPC follower uses its source -1 Z offset")
      elseif item.spriteId == npcSpriteId then
        savedNpcDrawn = true
        Assert.equal(item.world.x, 7.5, "the saved NPC subject uses its source +2 X offset")
        Assert.equal(item.world.z, 7.5, "the saved NPC subject uses its source zero Z offset")
      end
    end
    Assert.isTrue(savedPokemonDrawn, "the actual MonCatalog follower selector resolves the saved NPC Pokemon")
    Assert.isTrue(savedNpcDrawn, "the saved subjectSprite resolves through the real actor cache")
    Assert.isTrue(positions["7.5:7.5"], "the NPC subject uses the source (+2,0) placement")
    Assert.isTrue(positions["6.5:6.5"], "the NPC subject's Pokemon uses the source (+1,-1) placement")
    Assert.isTrue(positions["5.5:7.5"], "the saved player remains at the photographed location")
    local keys = {}
    for _, lane in ipairs(view.worldParts) do
      for _, draw in ipairs(lane) do
        if type(draw.modelKey) == "string" then
          keys[draw.modelKey] = true
        end
      end
    end
    Assert.isNil(keys["hidden-center"], "the saved first model selector filters the center model")
    Assert.isNil(keys["hidden-coverage"], "the saved second selector filters a physical-coverage model")
    Assert.isTrue(#call.worldParts >= 2, "outdoor snapshots combine central and physical-coverage draws")
    local rendered = photoTarget:newImageData()
    local changedPixels = 0
    for y = 0, rendered:getHeight() - 1 do
      for x = 0, rendered:getWidth() - 1 do
        local r, g, b = rendered:getPixel(x, y)
        if math.abs(r - 0.04) > 0.02 or math.abs(g - 0.05) > 0.02 or math.abs(b - 0.06) > 0.02 then
          changedPixels = changedPixels + 1
        end
      end
    end
    rendered:release()
    Assert.isTrue(changedPixels > 0, "the saved follower produces visible pixels through FieldRenderer and GxRenderer")

    local versionCache = CacheFs.forVersion(versionId)
    local albumManifest = PcCache.loadManifest(versionCache)
    local messageBank = assert(albumManifest.text.banks[0], "the Photo Album uses compiled source message bank zero")
    local sourceActions = { messageBank[1], messageBank[2], messageBank[3], messageBank[4] }
    local sourcePrompts = { messageBank[5], messageBank[6], messageBank[9] }
    local sourceExit = assert(messageBank[0], "the source viewer exit label is compiled")
    local sourceSingular = assert(messageBank[10], "the source one-Pokemon flavor template is compiled")
    local sourcePlural = assert(messageBank[11], "the source multi-Pokemon flavor template is compiled")
    local landmarkBank = assert(albumManifest.text.banks[279], "compiled HGSS map-section message bank is required")
    local sourceLandmark = assert(landmarkBank[7], "saved map-section id resolves through source bank 279")
    for _, template in ipairs({ sourceSingular, sourcePlural }) do
      local fields = {}
      for _, token in ipairs(template) do
        if token.kind == "substitution" then
          fields[#fields + 1] = assert(token.args)[1]
        end
      end
      Assert.deepEqual(
        fields,
        { 0, 1, 2, 4, 5, 3 },
        "source flavor templates retain player/map/lead/date substitutions"
      )
    end
    local textRenderer = scope:own(FieldTextRenderer.new({ cacheFs = versionCache }))
    local albumRenderer = scope:own(PhotoAlbumRenderer.new({ cacheFs = versionCache, manifest = albumManifest }))
    local icons = scope:own(preparedIcons(versionId, catalog:iconSelection(photo.party[1])))
    local albumResources = {
      photoAlbumRenderer = albumRenderer,
      fieldRenderer = fieldRenderer,
      textRenderer = observedText(textRenderer),
      icons = icons,
      monCatalog = catalog,
    }
    local interfaces = PhotoAlbumInterface.defaults(albumManifest)
    local states = {
      {
        phase = "list",
        occupiedSlots = { 0, 8 },
        selectedSlot = 0,
        selectedIndex = 1,
        sourceMessageId = 5,
        visiblePhotos = { { slot = 0, photo = photoRecord() }, { slot = 8, photo = photoRecord() } },
        animationTick = 1,
      },
      {
        phase = "actions",
        occupiedSlots = { 0, 8 },
        selectedSlot = 0,
        selectedIndex = 1,
        selectedAction = "delete",
        visiblePhotos = {},
        animationTick = 2,
      },
      {
        phase = "delete_confirm",
        occupiedSlots = { 0, 8 },
        selectedSlot = 0,
        selectedIndex = 1,
        selectedPhoto = photoRecord(),
        deleteChoice = "yes",
        visiblePhotos = {},
        animationTick = 3,
      },
      {
        phase = "move_target",
        occupiedSlots = { 0, 8 },
        selectedSlot = 8,
        selectedIndex = 2,
        sourceMessageId = 7,
        visiblePhotos = { { slot = 0, photo = photoRecord() }, { slot = 8, photo = photoRecord() } },
        animationTick = 4,
      },
      {
        phase = "viewer",
        occupiedSlots = { 0, 8 },
        selectedSlot = 0,
        selectedIndex = 1,
        selectedPhoto = photoRecord(),
        visiblePhotos = {},
        viewer = { phase = "ready", view = view },
        animationTick = 5,
      },
      {
        phase = "viewer",
        occupiedSlots = { 0, 8 },
        selectedSlot = 0,
        selectedIndex = 1,
        selectedPhoto = photoRecord(),
        visiblePhotos = {},
        viewer = { phase = "pending" },
        animationTick = 6,
      },
      {
        phase = "viewer",
        occupiedSlots = { 0, 8 },
        selectedSlot = 0,
        selectedIndex = 1,
        selectedPhoto = photoRecord(),
        visiblePhotos = {},
        viewer = { phase = "failed", failure = { code = "fixture-failure" } },
        animationTick = 7,
      },
    }
    local layouts = displayLayouts()
    local roleByPhase = { "photo", "action", "delete-choice", "photo", "viewer" }
    local changedByLayout = {}
    for configuration, display in pairs(layouts) do
      local session = ApplicationPresentation.new(interfaces)
      local canvas = scope:own(love.graphics.newCanvas(display.width, display.height))
      for stateIndex, screen in ipairs(states) do
        albumResources.textRenderer.messages = {}
        albumResources.textRenderer.plain = {}
        local plan = session:resolve(display, screen)
        local iconReady, iconFailure = albumRenderer:advance(screen, albumResources)
        Assert.isTrue(
          iconReady,
          "saved photo icons are prepared through MonIconAssetProvider: " .. tostring(iconFailure)
        )
        if screen.phase == "viewer" then
          local roles = {}
          for _, control in ipairs(plan.controls) do
            roles[control.sprite] = true
          end
          Assert.isTrue(
            roles.previous and roles.next and roles.back,
            configuration .. " exposes the three source viewer button roles"
          )
        else
          Assert.isTrue(
            plan.controls[1] and plan.controls[1].target == roleByPhase[stateIndex],
            configuration .. " exposes the state-specific rendered control role"
          )
        end
        local fieldCallsBeforeDraw = #calls
        love.graphics.setCanvas(canvas)
        love.graphics.clear(0.04, 0.05, 0.06, 1)
        plan.render(albumResources, screen, plan)
        love.graphics.setCanvas()
        if screen.phase == "actions" then
          local sourceActionLines = {}
          for _, message in ipairs(albumResources.textRenderer.messages) do
            for _, actionMessage in ipairs(sourceActions) do
              if message == actionMessage then
                sourceActionLines[message] = true
              end
            end
          end
          for _, sourceAction in ipairs(sourceActions) do
            Assert.isTrue(sourceActionLines[sourceAction], "action labels are drawn from source message bank zero")
          end
          Assert.deepEqual(
            { plan.controls[1].action, plan.controls[2].action, plan.controls[3].action, plan.controls[4].action },
            { "view", "delete", "move", "cancel" },
            "source action order is View, Delete, Move, Cancel"
          )
          Assert.isTrue(
            table.concat(albumResources.textRenderer.plain, " "):find("PHOTO OPTIONS", 1, true) == nil,
            "action headings do not use invented English text"
          )
        elseif screen.phase == "delete_confirm" then
          local sourceDeletePrompt = false
          for _, message in ipairs(albumResources.textRenderer.messages) do
            if message == messageBank[9] then
              sourceDeletePrompt = true
            end
          end
          Assert.isTrue(sourceDeletePrompt, "delete question is drawn from source message bank zero")
          Assert.isTrue(
            table.concat(albumResources.textRenderer.plain, " "):find("DELETE THIS PHOTO?", 1, true) == nil,
            "delete confirmation does not use invented English text"
          )
        elseif screen.phase == "viewer" then
          local renderedExit = false
          local renderedFlavorCount = 0
          local renderedFlavor
          for _, message in ipairs(albumResources.textRenderer.messages) do
            local text = FieldMessageText.tokensToText(message)
            if text:find("GOLD", 1, true) then
              renderedFlavorCount = renderedFlavorCount + 1
              renderedFlavor = text
            end
            if message == sourceExit then
              renderedExit = true
            end
          end
          Assert.isTrue(
            table.concat(albumResources.textRenderer.plain, " "):find("PHOTO ", 1, true) == nil,
            "viewer flavor text comes from the source message templates"
          )
          Assert.isTrue(
            renderedExit,
            "viewer exit label uses source message bank zero"
          )
          if screen.viewer.phase == "ready" then
            local readyFlavor = assert(renderedFlavor, "a ready viewer draws its source flavor message")
            Assert.equal(#calls, fieldCallsBeforeDraw + 1, "a ready viewer renders its saved field once")
            Assert.equal(renderedFlavorCount, 1, "ready viewer flavor text is formatted once")
            Assert.isTrue(
              readyFlavor:find("LEAF", 1, true) ~= nil,
              "lead nickname is substituted into source flavor text"
            )
            Assert.isTrue(
              readyFlavor:find("2010", 1, true) ~= nil,
              "four-digit year is substituted into source flavor text"
            )
            Assert.isTrue(readyFlavor:find("01", 1, true) ~= nil, "month is substituted into source flavor text")
            Assert.isTrue(readyFlavor:find("02", 1, true) ~= nil, "day is substituted into source flavor text")
            Assert.isTrue(
              readyFlavor:find(FieldMessageText.tokensToText(sourceLandmark), 1, true) ~= nil,
              "source bank 279 landmark is substituted using the saved map-section id"
            )
          else
            Assert.equal(#calls, fieldCallsBeforeDraw, "a non-ready viewer does not render saved field content")
            Assert.equal(renderedFlavorCount, 0, "a non-ready viewer does not format map-dependent flavor text")
          end
        elseif screen.phase == "list" then
          local sourceListPrompt = false
          for _, message in ipairs(albumResources.textRenderer.messages) do
            if message == messageBank[5] then
              sourceListPrompt = true
            end
          end
          Assert.isTrue(sourceListPrompt, "album list prompt is drawn from source message bank zero")
        elseif screen.phase == "move_target" then
          local sourceMovePrompt = false
          for _, message in ipairs(albumResources.textRenderer.messages) do
            if message == messageBank[7] then
              sourceMovePrompt = true
            end
          end
          Assert.isTrue(sourceMovePrompt, "move target prompt is drawn from source message bank zero")
        end
        local pixels = canvas:newImageData()
        local changed = 0
        for y = 0, pixels:getHeight() - 1, 4 do
          for x = 0, pixels:getWidth() - 1, 4 do
            local r, g, b = pixels:getPixel(x, y)
            if math.abs(r - 0.04) > 0.02 or math.abs(g - 0.05) > 0.02 or math.abs(b - 0.06) > 0.02 then
              changed = changed + 1
            end
          end
        end
        pixels:release()
        Assert.isTrue(changed > 0, configuration .. " draws compiled album art and its active state controls")
        changedByLayout[configuration] = (changedByLayout[configuration] or 0) + changed
      end
      session:dispose()
    end
    for configuration in pairs(layouts) do
      Assert.isTrue(changedByLayout[configuration] > 0, configuration .. " produces visible Photo Album pixels")
    end

    Assert.isTrue(loader.released == false, "taking and rendering the view does not release before scene disposal")
    Assert.deepEqual(liveField, liveBefore, "photo viewing leaves the live field snapshot unchanged")
    local savedPhoto = photoRecord()
    savedPhoto.subjectSprite = tostring(npcSpriteId)
    Assert.deepEqual(photo, savedPhoto, "photo viewing leaves the persisted source record unchanged")

    scene:dispose()
    Assert.equal(releases.environment, 1, "disposing releases the private map environment once")
    Assert.isTrue(releases.cells >= 1, "disposing releases the owned physical cell presentation")
    Assert.isTrue(loader.released, "disposing releases the private FieldMapLoader")
    Assert.isFalse(liveLoader.released, "disposing the photo leaves the active field loader borrowed")
    Assert.isTrue(liveLoader:get(41) == liveMap, "disposing the photo preserves the active runtime-map identity")
    Assert.isTrue(liveMap.sceneRuntime == liveSceneRuntime, "disposing the photo preserves active scene ownership")
    Assert.isTrue(liveMap.renderEnvironment == liveEnvironment, "the active render environment remains untouched")
    liveLoader:release()
    Assert.equal(liveReleases.environment, 1, "the active scene releases only with its own loader")
  end
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump" }
suite.metadata.derivedAssets = {
  "actors:global",
  "field-font:global",
  "items:global",
  "mon-catalog:global",
  "pc:global",
}
return suite
