-- Menu-opened evolution scene drawing through the production path: a real
-- FieldEvolutionScene leases its assets from the real battle presentation
-- envelope over the prepared cache, and its status draws through the
-- evolution application interface, the real BattleRenderer, and the field
-- draw services. The waiting scene paints opaque black on both screens; once
-- its assets are ready the top screen shows the staged scene, the old
-- Pokepic portrait in color around the source picture center, and the
-- narration window with its printed message, and the bottom screen paints
-- its opaque staged screen.

local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FieldBattlePresentation = require("game.hgss.src.field.FieldBattlePresentation")
local FieldEvolutionScene = require("game.hgss.src.field.FieldEvolutionScene")
local FieldPresentationResources = require("game.hgss.src.field.FieldPresentationResources")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldWindowRenderer = require("libs.hgss.src.ui.FieldWindowRenderer")
local GameVersion = require("romdump.src.source.GameVersion")
local GeneratedCacheFixture = require("tests.support.GeneratedCacheFixture")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local ImageAssetPool = require("libs.hgss.src.presentation.ImageAssetPool")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonCache = require("libs.assets.src.MonCache")
local MonCatalog = require("libs.mons.src.MonCatalog")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local RomImporter = require("romdump.src.source.RomImporter")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local SelectedAssetRuntimeFixture = require("tests.support.SelectedAssetRuntimeFixture")
local SummaryAcceptanceFixture = require("tests.support.SummaryAcceptanceFixture")

local T = {}

local MAX_TICKS = 2000

-- Source geometry of the scene: the narration window on the top screen.
local MESSAGE_BOX = { x = 16, y = 152, width = 216, height = 32 }
local PICTURE_AREA = { x = 0, y = 0, width = 256, height = 150 }

---@return string? versionId first ready prepared version
local function readyVersion()
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) and GeneratedCacheFixture.isPrepared(versionId) then
      return versionId
    end
  end
  return nil
end

---@return table<string, unknown> measured dual-display host facts
local function measurement()
  return {
    width = 256,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
    ),
    pixelRatio = 1,
    signature = "field-evolution-scene-graphics",
  }
end

-- The voice service double: every port starts at once and finishes at once,
-- and the field-music policy hold is recorded.
---@return table<string, unknown> audio
local function silentAudio()
  local audio = {}
  for _, port in ipairs({ "play", "playPanned", "playFanfare", "playMusic", "playCry", "stop", "stopMusic" }) do
    audio[port] = function()
      return true
    end
  end
  for _, port in ipairs({ "isCryFinished", "isFanfarePlaying", "isEffectWaitComplete" }) do
    audio[port] = function()
      return port ~= "isFanfarePlaying"
    end
  end
  function audio.suspendFieldPolicy() end
  function audio.resumeFieldPolicy() end
  return audio
end

---@param image love.ImageData
---@param box { x: integer, y: integer, width: integer, height: integer }
---@param predicate fun(red: number, green: number, blue: number): boolean
---@return integer matching opaque pixels inside the box
local function countMatching(image, box, predicate)
  local count = 0
  for y = box.y, box.y + box.height - 1 do
    for x = box.x, box.x + box.width - 1 do
      local red, green, blue, alpha = image:getPixel(x, y)
      if alpha > 0.5 and predicate(red, green, blue) then
        count = count + 1
      end
    end
  end
  return count
end

local function isLit(red, green, blue)
  return red + green + blue > 0.3
end

local function isInk(red, green, blue)
  return red + green + blue < 2.5
end

local function isAny()
  return true
end

function T.ready_scene_draws_staged_art_on_both_screens(scope, context)
  local versionId = readyVersion()
  if versionId == nil then
    context:skip("the evolution scene drawing needs a ready user-owned ROM with a derived cache")
  end
  local cacheFs = GeneratedCacheFixture.reader(versionId)
  local catalog = MonCatalog.new(MonCache.loadCatalog(cacheFs), CatalogFixture.makeItemCatalog())
  local service = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x5EED5001):capture()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
  })
  SummaryAcceptanceFixture.gift(service, "EEVEE", 12)

  -- The field draw services are the production pair over the staged field
  -- font and frame strip.
  local uiManifest = assert(cacheFs:loadLua(FieldUiAssetCache.manifestPath()), "the field-UI manifest loads")
  local textRenderer = scope:own(FieldTextRenderer.new({ cacheFs = cacheFs }))
  local owner = {
    textRenderer = textRenderer,
    windowRenderer = scope:own(FieldWindowRenderer.new({ cacheFs = cacheFs, manifest = uiManifest })),
    battleTextRenderers = {
      narration = scope:own(FieldTextRenderer.new({ cacheFs = cacheFs, fontId = 1 })),
      menu = scope:own(FieldTextRenderer.new({ cacheFs = cacheFs, fontId = 4 })),
      hud = scope:own(FieldTextRenderer.new({ cacheFs = cacheFs, fontId = 0 })),
    },
  }
  local text, windows =
    FieldPresentationResources.battleDrawServices(owner, { playerData = { options = { textFrame = 0 } } })

  local imagesRuntime = SelectedAssetRuntimeFixture.new(cacheFs, scope)
  local images =
    ImageAssetPool.new(cacheFs, { queue = imagesRuntime.preparationQueue, decoded = imagesRuntime.decoded })
  scope:own({
    release = function()
      images:dispose()
    end,
  })
  local envelope = FieldBattlePresentation.new({
    splRandomState = { state = 0 },
    cacheFs = cacheFs,
    graphics = love.graphics,
    windows = windows,
    text = text,
    monCatalog = catalog,
    measureDisplay = measurement,
    derivedAssets = {
      requestBattleEvolution = function()
        return true, nil
      end,
    },
    imagePool = images,
  })
  scope:own({
    release = function()
      envelope:dispose()
    end,
  })
  local scene = FieldEvolutionScene.new({
    request = {
      slot = 0,
      subject = service:partyMon(0),
      context = { trigger = { kind = "item", item = "FIRE_STONE" }, timeOfDay = "day", party = {}, inventory = {} },
      source = "field_item",
    },
    sceneId = "menu-evolution:1",
    assets = envelope:evolutionAssets("menu-evolution:1"),
    audio = silentAudio(),
    monCatalog = catalog,
    splRandomState = { state = 0 },
    summary = {},
    measureDisplay = measurement,
    textSpeed = "mid",
  })
  scope:own({
    release = function()
      scene:dispose()
    end,
  })

  local canvas = scope:own(love.graphics.newCanvas(256, 384, { format = "rgba8", readable = true }))
  ---@param status table<string, unknown>? status to draw; the live scene status by default
  local function drawFrame(status)
    status = status or scene:status()
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    ApplicationPresentation.draw(love.graphics, {
      graphics = love.graphics,
      text = text,
      windows = windows,
    }, status, status.presentation)
    love.graphics.setCanvas()
    return scope:own(canvas:newImageData())
  end
  local main = { x = 0, y = 0, width = 256, height = 192 }
  local sub = { x = 0, y = 192, width = 256, height = 192 }
  local messageBox = { x = MESSAGE_BOX.x, y = MESSAGE_BOX.y, width = MESSAGE_BOX.width, height = MESSAGE_BOX.height }

  local waiting = drawFrame()
  Assert.equal(countMatching(waiting, main, isLit), 0, "a scene waiting on its core paints the top screen black")
  Assert.equal(countMatching(waiting, sub, isLit), 0, "a scene waiting on its core paints the bottom screen black")
  Assert.equal(countMatching(waiting, main, isAny), 256 * 192, "the waiting top screen is opaque black, not unpainted")

  -- Drive the scene until its assets are ready and the narration prints.
  local frame
  for _ = 1, MAX_TICKS do
    scene:updateFixed({})
    local view = scene:status().evolution
    local presentation = view.presentation --[[@as table<string, unknown>?]]
    if presentation ~= nil and presentation.assetsReady == true then
      local inner = presentation.presentation --[[@as table<string, unknown>?]]
      local message = inner ~= nil and inner.message or nil
      if type(message) == "string" and #message >= 8 then
        frame = drawFrame()
        break
      end
    end
  end
  Assert.notNil(frame, "the scene turns ready and prints its first message")
  ---@cast frame love.ImageData

  -- The same status with both Pokepic scales at zero isolates the portrait:
  -- every pixel it changes sits around the source picture center.
  local live = scene:status()
  local function copy(record)
    local out = {}
    for key, value in pairs(record) do
      out[key] = value
    end
    return out
  end
  local bare = copy(live)
  bare.evolution = copy(live.evolution)
  bare.evolution.presentation = copy(live.evolution.presentation)
  local picture = copy(bare.evolution.presentation.presentation)
  bare.evolution.presentation.presentation = picture
  picture.oldPictureScale = 0
  picture.newPictureScale = 0
  local center = picture.pictureCenter
  local withoutPortrait = drawFrame(bare)
  local near, far = 0, 0
  for y = 0, 191 do
    for x = 0, 255 do
      local r1, g1, b1, a1 = frame:getPixel(x, y)
      local r2, g2, b2, a2 = withoutPortrait:getPixel(x, y)
      if r1 ~= r2 or g1 ~= g2 or b1 ~= b2 or a1 ~= a2 then
        if math.abs(x - center.x) <= 48 and math.abs(y - center.y) <= 48 then
          near = near + 1
        else
          far = far + 1
        end
      end
    end
  end
  Assert.isTrue(near > 200, "the Pokepic portrait paints around its source picture center")
  Assert.equal(far, 0, "the portrait changes nothing away from its picture center")

  Assert.isTrue(
    countMatching(frame, PICTURE_AREA, isLit) > 200,
    "the ready top screen paints staged scene art above the narration window"
  )
  Assert.isTrue(countMatching(frame, messageBox, isLit) > 1000, "the narration window paints its background")
  Assert.isTrue(countMatching(frame, messageBox, isInk) > 20, "the narration window prints its message text")
  -- The plain scene's bottom art is staged black: the pane still paints
  -- its whole opaque screen once ready.
  Assert.equal(countMatching(frame, sub, isAny), 256 * 192, "the ready bottom screen paints an opaque screen")
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump" }
suite.metadata.derivedAssets = {
  "audio-bank:133",
  "audio-bank:136",
  "battle-presentation:global",
  "battle-evolution:global",
  "field-font:global",
  "field-ui:global",
  "mon-catalog:global",
  "mon-portrait-page:57",
  "mon-portrait-page:66",
}

return suite
