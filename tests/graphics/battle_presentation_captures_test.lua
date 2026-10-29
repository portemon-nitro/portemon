-- Real staged-asset pixel captures for the battle presentation: the real
-- battle screen with its paired and compact renderers draws the staged day
-- grass scene, the staged menu and HUD composites, cropped staged mon
-- portraits, and the staged field font and frame strip into offscreen
-- canvases. Pixel censuses (never pixel-perfect matches) prove prompt and
-- command text ink, the triangular selection cursor, selected frame
-- borders, health-bar and composite ink with HUD wording ink inside the
-- published HUD bounds, menu artwork with its labels, and narration ink; a second render of each
-- view must be identical. PNG copies land beside the run for inspection.

local Assert = require("tests.support.Assert")
local StubLease = require("tests.support.StubLease")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local BattlePresentationModel = require("game.hgss.src.battle.BattlePresentationModel")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")
local BattleScreenState = require("game.hgss.tests.support.BattleScreenFixture")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldWindowRenderer = require("libs.hgss.src.ui.FieldWindowRenderer")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local ItemFixture = require("libs.items.tests.item_fixture")
local MonCache = require("libs.assets.src.MonCache")
local MoveIconCache = require("libs.assets.src.MoveIconCache")
local PngWriter = require("libs.assets.src.PngWriter")
local RomImporter = require("romdump.src.source.RomImporter")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local SCENE_KEY = "general/grass/day"
local LEAD_SPECIES = "CHIKORITA"
local FOE_SPECIES = "RATTATA"
-- Portrait pages holding the capture pair under the current deterministic
-- page layout. The mapping test below fails loudly with the fresh page
-- identities when the layout repaginates, so the staged page closure here
-- is updated instead of silently rendering the wrong mon.
local LEAD_BACK_PAGE = 34
local FOE_FRONT_PAGE = 164
local TICK = 1 / 60
local DRIVE_BUDGET = 2000
local NATIVE_DOUBLES_HUD_ORIGINS = {
  playerLeft = { x = 192, y = 103 },
  playerRight = { x = 198, y = 132 },
  enemyLeft = { x = 64, y = 16 },
  enemyRight = { x = 58, y = 45 },
}

local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      versions[#versions + 1] = versionId
    end
  end
  return versions
end

local function compactMeasurement()
  return {
    width = 256,
    height = 192,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 256, height = 192 },
      touch = true,
      role = "world",
    }),
    pixelRatio = 1,
    signature = "battle-captures:compact",
  }
end

local function dualMeasurement()
  return {
    width = 256,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
    ),
    pixelRatio = 1,
    signature = "battle-captures:dual",
  }
end

local function quantize(channel)
  return math.floor(channel * 255 + 0.5)
end

local function imageDataDigest(data)
  local hash = 2166136261
  for y = 0, data:getHeight() - 1 do
    for x = 0, data:getWidth() - 1 do
      local red, green, blue, alpha = data:getPixel(x, y)
      for _, channel in ipairs({ red, green, blue, alpha }) do
        hash = (hash * 16777619 + quantize(channel)) % 4294967296
      end
    end
  end
  return hash
end

-- Counts pixels in a host rectangle whose quantized color differs between
-- two captures; every differing pixel fails loudly only through the
-- caller's threshold.
local function regionDistance(first, second, rect, stride)
  Assert.equal(first:getWidth(), second:getWidth(), "compared captures share their width")
  Assert.equal(first:getHeight(), second:getHeight(), "compared captures share their height")
  local changed = 0
  for y = rect.y, rect.y + rect.height - 1, stride do
    for x = rect.x, rect.x + rect.width - 1, stride do
      local r1, g1, b1, a1 = first:getPixel(x, y)
      local r2, g2, b2, a2 = second:getPixel(x, y)
      if
        quantize(r1) ~= quantize(r2)
        or quantize(g1) ~= quantize(g2)
        or quantize(b1) ~= quantize(b2)
        or quantize(a1) ~= quantize(a2)
      then
        changed = changed + 1
      end
    end
  end
  return changed
end

local function decodeData(scope, cacheFs, path, what)
  local bytes = assert(cacheFs:read(path), "the staged cache carries " .. what .. " at " .. path)
  return scope:own(love.image.newImageData(love.filesystem.newFileData(bytes, path)))
end

local function stagedImage(scope, cacheFs, path, what)
  local image = scope:own(love.graphics.newImage(decodeData(scope, cacheFs, path, what)))
  image:setFilter("nearest", "nearest")
  return image
end

-- Wraps one cropped test-side portrait cell in the production drawable
-- shape: the pool lease paired with its cell quad, here a straight
-- sampler lease over the staged crop image with a full crop quad.
---@param image love.Image
---@return { lease: table<string, unknown>, image: love.Image, quad: love.Quad }
local function cellHandle(image)
  local width, height = image:getWidth(), image:getHeight()
  return {
    lease = StubLease.over(image),
    image = image,
    quad = love.graphics.newQuad(0, 0, width, height, width, height),
  }
end

-- Crops one staged portrait cell out of its atlas page into its own
-- image: the battle renderer draws one drawable per battler side, so the
-- capture harness resolves the side keys to these per-side crops. The
-- page identity is pinned above and verified against the staged manifest
-- on every run.
---@param scope table test-owned graphics scope
---@param cacheFs table versioned derived cache
---@param selector string canonical staged portrait selector
---@param pageId integer expected staged page identity
---@return table love image holding exactly the staged cell
---@return table readable pixels of the cropped cell
local function cropPortrait(scope, cacheFs, selector, pageId)
  local manifest =
    assert(cacheFs:loadLua(MonCache.portraitManifestPath()), "the staged cache carries its portrait manifest")
  local entry = assert(manifest.entries[selector], "the staged manifest plans " .. selector)
  Assert.equal(
    entry.pageId,
    pageId,
    "portrait pagination drifted for "
      .. selector
      .. ": staged on page "
      .. tostring(entry.pageId)
      .. ", update the staged page closure to that page"
  )
  local bytes = assert(
    cacheFs:read(MonCache.pageImagePath("portraits", pageId)),
    "the staged cache carries portrait page " .. tostring(pageId)
  )
  local page = scope:own(love.image.newImageData(love.filesystem.newFileData(bytes, "portraits/" .. pageId)))
  local cropped = scope:own(love.image.newImageData(entry.width, entry.height))
  cropped:paste(page, 0, 0, entry.x, entry.y, entry.width, entry.height)
  local occupied = 0
  for y = 0, cropped:getHeight() - 1 do
    for x = 0, cropped:getWidth() - 1 do
      local _, _, _, alpha = cropped:getPixel(x, y)
      if alpha > 0 then
        occupied = occupied + 1
      end
    end
  end
  Assert.isTrue(occupied > 100, "the staged cell carries portrait pixels for " .. selector)
  local image = scope:own(love.graphics.newImage(cropped))
  image:setFilter("nearest", "nearest")
  return image, cropped
end

---@param scope table test-owned graphics scope
---@param cacheFs table versioned derived cache
---@param selector string canonical icon selector
---@return table<integer, table> cropped source animation frames
local function cropIconFrames(scope, cacheFs, selector)
  local manifest = assert(cacheFs:loadLua(MonCache.iconManifestPath()), "the staged cache carries its icon manifest")
  local entry = assert(manifest.entries[selector], "the staged icon manifest plans " .. selector)
  local bytes = assert(cacheFs:read(MonCache.iconPagePath(entry.pageId)), "the staged cache carries the icon page")
  local page = scope:own(love.image.newImageData(love.filesystem.newFileData(bytes, "icons/" .. entry.pageId)))
  local frames = {}
  for index, frame in ipairs(entry.frames) do
    local cropped = scope:own(love.image.newImageData(frame.width, frame.height))
    cropped:paste(page, 0, 0, frame.x, frame.y, frame.width, frame.height)
    frames[index] = scope:own(love.graphics.newImage(cropped))
  end
  return frames
end

-- Mirrors the envelope's demand validation so the capture harness stages
-- exactly what the production demand requires: one screen key expands to
-- its four staged gender/finish selectors, and every selector must be
-- planned with a ready page.
---@param cacheFs table versioned derived cache
---@param pageKey string demand portrait key under validation
local function requirePortraitKey(cacheFs, pageKey)
  local species, form, facing = tostring(pageKey):match("^([^/]+)/([0-9]+)/([a-z]+)$")
  local portraits =
    assert(cacheFs:loadLua(MonCache.portraitManifestPath()), "the staged cache carries its portrait manifest")
  local entries = assert(portraits.entries, "the staged portrait manifest carries entries")
  local index = assert(cacheFs:loadLua(MonCache.indexPath()), "the staged cache carries its mon index")
  local markers = assert(index.portraitPages, "the staged mon index carries portrait page markers")
  if species == nil then
    -- Exact canonical selectors validate their single staged entry and
    -- page: no expansion, no guessed variant.
    local entry = assert(entries[pageKey], "the staged manifest plans " .. pageKey)
    Assert.isTrue(
      MonCache.isPageReady(cacheFs, "portraits", entry.pageId, markers[entry.pageId + 1]),
      "portrait page " .. tostring(entry.pageId) .. " is staged for " .. pageKey
    )
    return
  end
  Assert.notNil(form, "portrait demands name their form: " .. pageKey)
  Assert.isTrue(facing == "front" or facing == "back", "portrait demands name their facing: " .. pageKey)
  local portraits =
    assert(cacheFs:loadLua(MonCache.portraitManifestPath()), "the staged cache carries its portrait manifest")
  local entries = assert(portraits.entries, "the staged portrait manifest carries entries")
  local index = assert(cacheFs:loadLua(MonCache.indexPath()), "the staged cache carries its mon index")
  local markers = assert(index.portraitPages, "the staged mon index carries portrait page markers")
  for _, gender in ipairs({ "male", "female" }) do
    for _, finish in ipairs({ "plain", "shiny" }) do
      local selector = MonCache.portraitSelector(species, tonumber(form), gender, finish == "shiny", facing)
      local entry = assert(entries[selector], "the staged manifest plans " .. selector)
      Assert.isTrue(
        MonCache.isPageReady(cacheFs, "portraits", entry.pageId, markers[entry.pageId + 1]),
        "portrait page " .. tostring(entry.pageId) .. " is staged for " .. selector
      )
    end
  end
end

---@param scope table test-owned graphics scope
---@param cacheFs table versioned derived cache
---@param versionId string ready game version under capture
---@return table image services mapping drawable keys to staged images
local function captureServices(scope, cacheFs, versionId)
  local manifest = BattlePresentationCache.load(cacheFs)
  Assert.isTrue(manifest.verified == true, versionId .. " stages the verified battle manifest")
  local images = {}
  local commandIconKey = MonCache.iconSelector(LEAD_SPECIES, 0, false)
  for frameIndex, frame in ipairs(cropIconFrames(scope, cacheFs, commandIconKey)) do
    images["battle:icon:" .. commandIconKey .. ":frame:" .. tostring(frameIndex)] = frame
  end
  images["scene:" .. SCENE_KEY] =
    stagedImage(scope, cacheFs, BattlePresentationCache.sceneImagePath(SCENE_KEY), versionId .. " battle scene")
  local sceneRecord =
    assert(BattlePresentationCache.loadScene(cacheFs, SCENE_KEY), versionId .. " stages its scene record")
  images["scene-intro:" .. SCENE_KEY] =
    stagedImage(scope, cacheFs, sceneRecord.introLayer.image, versionId .. " unbaked battle intro scene")
  for _, side in ipairs({ "player", "foe" }) do
    local terrain = sceneRecord.terrainSprites[side]
    images["scene-terrain:" .. SCENE_KEY .. ":" .. side] =
      stagedImage(scope, cacheFs, terrain.image, versionId .. " " .. side .. " terrain sprite")
  end
  local pokeBall = assert(manifest.battleBalls.entries["ball:POKE_BALL"], versionId .. " stages the fixture ball")
  for _, frame in ipairs(pokeBall.frames) do
    images[frame.drawableKey] = stagedImage(scope, cacheFs, frame.image, versionId .. " fixture ball frame")
  end
  images["hud:enemy"] = stagedImage(
    scope,
    cacheFs,
    assert(manifest.hud.enemy, versionId .. " carries enemy HUD").image,
    versionId .. " enemy HUD"
  )
  images["hud:player"] = stagedImage(
    scope,
    cacheFs,
    assert(manifest.hud.player, versionId .. " carries player HUD").image,
    versionId .. " player HUD"
  )
  local doublesHud = assert(manifest.hud.doubles, versionId .. " carries native doubled HUD sections")
  for slot, artKey in pairs({
    playerLeft = "hud:player-left",
    playerRight = "hud:player-right",
    enemyLeft = "hud:enemy-left",
    enemyRight = "hud:enemy-right",
  }) do
    local section = assert(doublesHud[slot], versionId .. " carries the " .. slot .. " HUD section")
    images[artKey] = stagedImage(scope, cacheFs, section.image, versionId .. " " .. slot .. " HUD strip")
  end
  images["menu:command"] = stagedImage(
    scope,
    cacheFs,
    assert(manifest.menus.command, versionId .. " carries command art").image,
    versionId .. " command art"
  )
  images["menu:moves"] = stagedImage(
    scope,
    cacheFs,
    assert(manifest.menus.moves, versionId .. " carries move art").image,
    versionId .. " move art"
  )
  images["menu:target"] = stagedImage(
    scope,
    cacheFs,
    assert(manifest.menus.target, versionId .. " carries target art").image,
    versionId .. " target art"
  )
  images["menu:pulse-mask"] = stagedImage(
    scope,
    cacheFs,
    assert(manifest.menus.lower.pulseMask, versionId .. " carries the menu pulse mask"),
    versionId .. " menu pulse mask"
  )
  -- Native menu routes draw through per-screen artwork with per-control
  -- feedback variants, never the bare group image: stage every screen
  -- and feedback image the renderers resolve through the same
  -- menu:<layout>:screen:<n> and menu:<layout>:feedback:<id>:<state>
  -- keys production uses.
  for sectionKey, layout in pairs({
    command = "command",
    moves = "moves",
    target = "target",
    twoOption = "two-option",
  }) do
    local menuSection = manifest.menus[sectionKey]
    if type(menuSection) == "table" and type(menuSection.screens) == "table" then
      for index, menuScreen in ipairs(menuSection.screens) do
        if type(menuScreen.image) == "string" then
          -- The capture scene's background selects its lower palette
          -- variant exactly like the production key resolution.
          local background = BattlePresentationCache.parseSceneKey(SCENE_KEY).background
          local variants = menuScreen.backgrounds
          images["menu:" .. layout .. ":screen:" .. tostring(index) .. "@" .. background] = stagedImage(
            scope,
            cacheFs,
            variants ~= nil and variants[background] or menuScreen.image,
            versionId .. " " .. layout .. " screen " .. tostring(index)
          )
          local touchVariants = menuScreen.touchBackgrounds
          if type(touchVariants) == "table" and type(touchVariants[background]) == "string" then
            images["menu:" .. layout .. ":screen:" .. tostring(index) .. "@" .. background .. ":touch"] = stagedImage(
              scope,
              cacheFs,
              touchVariants[background],
              versionId .. " " .. layout .. " touch screen " .. tostring(index)
            )
          end
        end
        if type(menuScreen.moveButtons) == "table" then
          for slotIndex, button in ipairs(menuScreen.moveButtons) do
            local prefix = "menu:moves:move-button:" .. tostring(slotIndex - 1) .. ":"
            images[prefix .. "empty"] = stagedImage(scope, cacheFs, button.empty, versionId .. " empty move button")
            for typeKey, states in pairs(button.types) do
              for state, image in pairs(states) do
                images[prefix .. typeKey .. ":" .. state] =
                  stagedImage(scope, cacheFs, image, versionId .. " " .. typeKey .. " move button")
              end
            end
          end
        end
        if type(menuScreen.feedback) == "table" then
          for controlId, states in pairs(menuScreen.feedback) do
            for state, variant in pairs(states) do
              if type(variant.image) == "string" then
                images["menu:" .. layout .. ":feedback:" .. tostring(controlId) .. ":" .. tostring(state)] =
                  stagedImage(
                    scope,
                    cacheFs,
                    variant.image,
                    versionId .. " " .. layout .. " " .. tostring(controlId) .. " " .. tostring(state)
                  )
              end
            end
          end
        end
      end
    end
  end
  images["arrow"] = stagedImage(
    scope,
    cacheFs,
    assert(manifest.hud.arrow, versionId .. " carries the arrow").image,
    versionId .. " arrow"
  )
  images["cursor"] = stagedImage(
    scope,
    cacheFs,
    assert(manifest.hud.cursor, versionId .. " carries the keypad cursor").image,
    versionId .. " keypad cursor"
  )
  local shadow =
    assert(manifest.pictures ~= nil and manifest.pictures.shadow, versionId .. " carries its staged shadow")
  images["shadow"] =
    stagedImage(scope, cacheFs, assert(shadow.image, versionId .. " carries shadow art"), versionId .. " shadow")
  -- Party gauges resolve per side through the staged families, exactly
  -- like production: player gauges ride the second family, enemy
  -- gauges the first.
  local playerGauges = assert(manifest.hud.partyGauges[2], versionId .. " carries player gauges")
  local enemyGauges = assert(manifest.hud.partyGauges[1], versionId .. " carries enemy gauges")
  images["gauges:player"] = stagedImage(scope, cacheFs, playerGauges.image, versionId .. " player gauges")
  images["gauges:enemy"] = stagedImage(scope, cacheFs, enemyGauges.image, versionId .. " enemy gauges")
  local moveIconManifest = assert(MoveIconCache.loadManifest(cacheFs), versionId .. " carries the move icon catalog")
  for typeKey, icon in pairs(moveIconManifest.types) do
    images["battle:move-type-icon:" .. typeKey] =
      stagedImage(scope, cacheFs, icon.image, versionId .. " " .. typeKey .. " move type icon")
  end
  local portraitCells = {}
  -- Battler portraits resolve as "mon:" plus the exact staged
  -- selector: the capture stages those canonical identities only,
  -- never a generic side key.
  local foeSelector = MonCache.portraitSelector(FOE_SPECIES, 0, "male", false)
  local leadSelector = MonCache.portraitSelector(LEAD_SPECIES, 0, "male", false, "back")
  local foeImage, foeCell = cropPortrait(scope, cacheFs, foeSelector, FOE_FRONT_PAGE)
  images["mon:" .. foeSelector] = cellHandle(foeImage)
  portraitCells["mon:" .. foeSelector] = foeCell
  local leadImage, leadCell = cropPortrait(scope, cacheFs, leadSelector, LEAD_BACK_PAGE)
  images["mon:" .. leadSelector] = cellHandle(leadImage)
  portraitCells["mon:" .. leadSelector] = leadCell
  local femaleBackSelector = MonCache.portraitSelector(LEAD_SPECIES, 0, "female", false, "back")
  local stagedPortraits = cacheFs:loadLua(MonCache.portraitManifestPath())
  local femaleEntry = stagedPortraits ~= nil
      and stagedPortraits.entries ~= nil
      and stagedPortraits.entries[femaleBackSelector]
    or nil
  if type(femaleEntry) == "table" and type(femaleEntry.pageId) == "number" then
    local croppedOk, croppedImage = pcall(cropPortrait, scope, cacheFs, femaleBackSelector, femaleEntry.pageId)
    if croppedOk then
      images["mon:" .. femaleBackSelector] = cellHandle(croppedImage)
    end
  end
  local services = { prepared = {} }
  local stagedSceneLayer = nil
  function services.prepare(demand)
    Assert.isTrue(type(demand) == "table", versionId .. " demands arrive as records")
    services.prepared[#services.prepared + 1] = demand
    for _, sceneKey in ipairs(demand.scenes or {}) do
      Assert.notNil(
        BattlePresentationCache.parseSceneKey(sceneKey),
        versionId .. " demands a known scene: " .. tostring(sceneKey)
      )
      local record, recordErr = BattlePresentationCache.loadScene(cacheFs, sceneKey)
      Assert.notNil(record, versionId .. " stages its scene: " .. tostring(recordErr))
      local layer = record.layers[1]
      local characters = assert(cacheFs:read(layer.characters.path), versionId .. " stages BG3 characters")
      local map = assert(cacheFs:loadLua(layer.map.path), versionId .. " stages the BG3 tile map")
      local palette = assert(cacheFs:loadLua(layer.palette.path), versionId .. " stages the BG3 palette")
      local bytes =
        assert(cacheFs:read(BattlePresentationCache.sceneImagePath(sceneKey)), versionId .. " stages its scene image")
      local imageWidth, imageHeight = PngWriter.completeDimensions(bytes)
      Assert.equal(imageWidth, record.canvasWidth, versionId .. " stages the complete scene image width")
      Assert.equal(imageHeight, record.canvasHeight, versionId .. " stages the complete scene image height")
      local terrainSprites = {}
      for _, side in ipairs({ "player", "foe" }) do
        local sprite = record.terrainSprites[side]
        terrainSprites[side] = {
          drawable = assert(
            images["scene-terrain:" .. sceneKey .. ":" .. side],
            versionId .. " stages the " .. side .. " terrain drawable"
          ),
          width = sprite.width,
          height = sprite.height,
          origin = { x = sprite.origin.x, y = sprite.origin.y },
        }
      end
      stagedSceneLayer = {
        characters = characters,
        map = map,
        palette = palette,
        colorMode = "8bpp",
        introLayer = {
          drawable = assert(images["scene-intro:" .. sceneKey], versionId .. " stages the intro scene drawable"),
          width = record.introLayer.width,
          height = record.introLayer.height,
        },
        terrainSprites = terrainSprites,
      }
    end
    for _, page in ipairs(demand.pages or {}) do
      requirePortraitKey(cacheFs, page)
    end
    local iconManifest = cacheFs:loadLua(MonCache.iconManifestPath())
    local monIndex = assert(cacheFs:loadLua(MonCache.indexPath()), versionId .. " stages its mon index")
    local iconMarkers = assert(monIndex.iconPages, versionId .. " stages icon page markers")
    for _, iconKey in ipairs(demand.iconKeys or {}) do
      local entry = type(iconManifest) == "table" and iconManifest.entries[iconKey] or nil
      Assert.notNil(entry, versionId .. " stages demanded icon " .. tostring(iconKey))
      Assert.isTrue(
        MonCache.isPageReady(cacheFs, "icons", entry.pageId, iconMarkers[entry.pageId + 1]),
        versionId .. " stages icon page " .. tostring(entry.pageId)
      )
    end
    return true
  end
  function services.sceneLayer()
    return stagedSceneLayer
  end
  function services.drawable(key)
    assert(type(key) == "string" and key ~= "", "image resolution names its key")
    local stored = images[key]
    if stored == nil then
      return nil
    end
    if key:match("^battle:icon:") ~= nil then
      local drawable = {}
      function drawable:getDimensions()
        return stored:getDimensions()
      end
      function drawable:draw(drawGraphics, x, y)
        drawGraphics.draw(stored, x, y)
      end
      function drawable:drawQuad(drawGraphics, quad, x, y)
        drawGraphics.draw(stored, quad, x, y)
      end
      return drawable
    end
    -- Whole-image entries resolve as straight sampler leases over the
    -- staged image (pixel-identical); portrait cells already pair
    -- their lease and pass through untouched.
    if stored.lease ~= nil or type(stored.draw) == "function" then
      return stored
    end
    return StubLease.over(stored)
  end
  function services.release(key)
    images[key] = nil
  end
  return services, images, portraitCells
end

-- The production field composition borrows its battle text and window
-- services over the shared field renderers with the player frame option
-- resolving the default frame: the capture harness mirrors that seam so
-- the same font and frame strip reach the battle renderers.
---@param scope table test-owned graphics scope
---@param cacheFs table versioned derived cache
---@param versionId string ready game version under capture
---@return table text services
---@return table window services
local function captureDrawServices(scope, cacheFs, versionId)
  local uiManifest =
    assert(cacheFs:loadLua(FieldUiAssetCache.manifestPath()), versionId .. " loads its field-UI manifest")
  Assert.isTrue(FieldUiAssetCache.validateManifest(uiManifest), versionId .. " carries a valid field-UI manifest")
  local textRenderer = scope:own(FieldTextRenderer.new({ cacheFs = cacheFs }))
  local windowRenderer = scope:own(FieldWindowRenderer.new({ cacheFs = cacheFs, manifest = uiManifest }))
  local frames = assert(uiManifest.dialogueFrames, versionId .. " carries dialogue frames")
  Assert.notNil(frames.frameTiles[0], versionId .. " carries the default frame strip")
  local text = { fontDef = textRenderer.fontDef }
  function text.drawText(content, x, y)
    return textRenderer:drawText(content, x, y)
  end
  if type(textRenderer.drawTextWithPalette) == "function" then
    function text.drawTextWithPalette(content, x, y, palette)
      return textRenderer:drawTextWithPalette(content, x, y, palette)
    end
  end
  function text.measure(content)
    return { width = textRenderer:textWidth(content), height = 16 }
  end
  function text.windowBackgroundColor()
    return textRenderer:windowBackgroundColor()
  end
  -- Source font roles mirror the production battle text services.
  local roleRenderers = {
    narration = scope:own(FieldTextRenderer.new({ cacheFs = cacheFs, fontId = 1 })),
    menu = scope:own(FieldTextRenderer.new({ cacheFs = cacheFs, fontId = 4 })),
    hud = scope:own(FieldTextRenderer.new({ cacheFs = cacheFs, fontId = 0 })),
  }
  function text.drawTextForRole(role, content, x, y, palette)
    local renderer = assert(roleRenderers[role], "battle text role has a source font renderer")
    if palette ~= nil then
      return renderer:drawTextWithPalette(content, x, y, palette)
    end
    return renderer:drawText(content, x, y)
  end
  function text.measureForRole(role, content)
    local renderer = assert(roleRenderers[role], "battle text role has a source font renderer")
    return { width = renderer:textWidth(content), height = renderer.fontDef.lineHeight }
  end
  local windows = {}
  local function frameIndexOf(frameKey)
    if frameKey == nil or frameKey == "default" then
      return 0
    end
    error("unknown battle frame: " .. tostring(frameKey), 0)
  end
  function windows.drawWindow(box, frameKey, background)
    return windowRenderer:drawWindow(box, frameIndexOf(frameKey), background)
  end
  function windows.drawApplicationFrame(box, frameKey)
    return windowRenderer:drawApplicationFrame(box, frameIndexOf(frameKey))
  end
  return text, windows
end

local function recordingAudio()
  local audio = { plays = {} }
  function audio.play(name)
    audio.plays[#audio.plays + 1] = name
    return true
  end
  return audio
end

---@param scope table test-owned graphics scope
---@param cacheFs table versioned derived cache
---@param versionId string ready game version under capture
---@param measurement table caller-owned display facts
---@return table live battle screen behind the capture
---@return table staged images behind the screen drawables
---@return table cropped portrait cells behind the mon drawables
---@return table preparation services logging the screen demands
local function captureScreen(scope, cacheFs, versionId, measurement)
  local manifest = BattlePresentationCache.load(cacheFs)
  local text, windows = captureDrawServices(scope, cacheFs, versionId)
  local services, images, portraitCells = captureServices(scope, cacheFs, versionId)
  local submitted = {}
  local screen = BattleScreenState.new({
    launchId = "battle-capture",
    manifest = manifest,
    model = BattlePresentationModel,
    submit = function(reply)
      submitted[#submitted + 1] = reply
      return true
    end,
    measureDisplay = function()
      return measurement
    end,
    -- The battle screen borrows the immutable item catalog so its bag
    -- child can group stocked items by pocket, exactly like production.
    itemCatalog = ItemFixture.makeCatalog(),
    monIconProvider = {
      prepareKeys = function()
        return true
      end,
    },
    assets = services,
    text = text,
    windows = windows,
    audio = recordingAudio(),
    overrides = { sceneKey = SCENE_KEY },
  })
  return screen, images, portraitCells, services
end

local function moveChoice(id, name, pp, maxPp, moveType, slot)
  return {
    role = "move",
    id = id,
    enabled = true,
    display = { name = name, pp = pp, maxPp = maxPp, type = moveType },
    choice = { kind = "attack", payload = { moveSlot = slot, target = { kind = "position", position = 2 } } },
  }
end

local function openingPacket()
  -- Fixtures carry their own canonical portrait selectors: a record
  -- without one draws nothing, so the captures stage the exact
  -- identities they expect on screen. The second own record is the
  -- benched reserve, flagged exactly like production packets so the
  -- opening stages one live lead instead of a live pair.
  local after = {
    own = {
      {
        combatant = 0,
        side = 1,
        active = true,
        species = LEAD_SPECIES,
        form = 0,
        selector = "back",
        portraitSelector = MonCache.portraitSelector(LEAD_SPECIES, 0, "male", false, "back"),
        name = LEAD_SPECIES,
        gender = "male",
        level = 9,
        hp = 30,
        maxHp = 30,
        experience = 120,
      },
      {
        combatant = 1,
        side = 1,
        active = false,
        species = LEAD_SPECIES,
        form = 0,
        selector = "back",
        portraitSelector = MonCache.portraitSelector(LEAD_SPECIES, 0, "male", false, "back"),
        name = LEAD_SPECIES,
        level = 9,
        hp = 28,
        maxHp = 28,
        experience = 100,
      },
    },
    foes = {
      {
        combatant = 2,
        side = 2,
        species = FOE_SPECIES,
        form = 0,
        selector = "front",
        portraitSelector = MonCache.portraitSelector(FOE_SPECIES, 0, "male", false),
        name = FOE_SPECIES,
        gender = "female",
        level = 3,
        hp = 12,
        maxHp = 12,
      },
    },
  }
  local options = {
    actors = {
      {
        -- Voluntary children address the acting lead by stable
        -- combatant identity, exactly like the runtime projection
        -- the kernel reads.
        kind = "command",
        combatant = 0,
        choices = {
          moveChoice("move:0", "TACKLE", 35, 35, "NORMAL", 0),
          moveChoice("move:1", "GROWL", 40, 40, "NORMAL", 1),
          { role = "run", enabled = true, choice = { kind = "run", payload = {} } },
        },
      },
    },
  }
  return {
    launchId = "battle-capture",
    packetId = 1,
    after = after,
    events = {},
    request = {
      requestId = 7,
      epoch = 1,
      controller = "player",
      -- Voluntary children address the acting lead by stable combatant
      -- identity, exactly like the runtime projection the kernel reads.
      actors = { { kind = "command", combatant = 0 } },
      legalChoices = { kinds = { "attack", "item", "switch", "run" } },
      options = options,
    },
  }
end

-- Waits for the production menu reveal gate to arm: every entry to
-- the command prompt reveals before it accepts presses, so menu edges
-- sent while the gate stands are dropped instead of racing it.
---@param screen table live battle screen under driving
---@param versionId string ready game version under driving
local function waitForMenuInput(screen, versionId)
  for _ = 1, 30 do
    if screen:view().menuInputEnabled then
      return
    end
    screen:updateFixed(TICK)
  end
  Assert.isTrue(screen:view().menuInputEnabled, versionId .. " arms its menu input")
end

---@param screen table live battle screen acknowledging source narration
local function acknowledgeNarration(screen)
  local mode = screen:status().mode
  if
    mode == "intro"
    or mode == "narration"
    or mode == "outcome"
    or screen._timeline:messageActive()
    or screen._timeline:levelUpStats() ~= nil
  then
    screen:input({ { type = "confirm" } })
  end
end

-- Pumps one screen through its opening cues with the given packet until
-- the command request is exposed and armed: the send-out cue holds on
-- the player-side portrait, so arrival proves the mon drawables
-- resolved, and the reveal wait proves menu edges will act.
---@param screen table live battle screen under driving
---@param versionId string ready game version under capture
---@param packet table delivery packet opening the staged battle
---@param kind "wild"|"trainer"? encounter kind under capture
local function drivePacketToCommand(screen, versionId, packet, kind)
  local port = screen:presentationPort()
  for _ = 1, 5 do
    screen:updateFixed(TICK)
  end
  Assert.isTrue(
    port.enter({ launchId = "battle-capture", kind = kind or "wild" }),
    versionId .. " enters its staged scene"
  )
  port.present(packet)
  local ticks = 0
  while screen:status().request == nil and ticks < DRIVE_BUDGET do
    acknowledgeNarration(screen)
    screen:updateFixed(TICK)
    ticks = ticks + 1
  end
  local status = screen:status()
  Assert.notNil(
    status.request,
    versionId
      .. " exposes its command request (mode="
      .. tostring(status.mode)
      .. ", error="
      .. tostring(status.error)
      .. ", message="
      .. tostring(screen._timeline:message())
      .. ", timelineBusy="
      .. tostring(screen._timeline:busy())
      .. ")"
  )
  Assert.equal(screen:status().mode, "command", versionId .. " rests on the command view")
  waitForMenuInput(screen, versionId)
end

-- Pumps one screen through its opening cues until the command request is
-- exposed: the send-out cue holds on the player-side portrait, so arrival
-- proves the mon drawables resolved.
---@param screen table live battle screen under driving
---@param versionId string ready game version under capture
local function driveToCommand(screen, versionId)
  drivePacketToCommand(screen, versionId, openingPacket())
end

local function doubledBattlePacket()
  local packet = openingPacket()
  packet.after.own[2].active = true
  packet.after.own[1].position = 1
  packet.after.own[2].position = 2
  packet.after.foes[1].position = 3
  packet.after.foes[2] = {
    combatant = 3,
    side = 2,
    position = 4,
    species = FOE_SPECIES,
    form = 0,
    selector = "front",
    portraitSelector = MonCache.portraitSelector(FOE_SPECIES, 0, "male", false),
    name = "RATTATA-B",
    level = 4,
    hp = 8,
    maxHp = 12,
  }
  return packet
end

---@param screen table live battle screen under capture
---@return table resolved plan carrying panes and content
local function livePlan(screen, versionId)
  local status = screen:status()
  local plan = assert(status.presentation, versionId .. " publishes its plan")
  Assert.isTrue(type(plan.panes) == "table" and #plan.panes > 0, versionId .. " plans its panes")
  return plan
end

---@param plan table resolved plan under capture
---@param versionId string ready game version under capture
---@return integer canvas width covering every pane at unit scale
---@return integer canvas height covering every pane at unit scale
local function canvasSize(plan, versionId)
  local width, height = 0, 0
  for _, pane in ipairs(plan.panes) do
    local placement = assert(pane.placement, versionId .. " places its panes")
    Assert.equal(placement.pixelScale, 1, versionId .. " keeps canonical coordinates")
    local frame = assert(placement.frame, versionId .. " frames its panes")
    width = math.max(width, frame.x + frame.width)
    height = math.max(height, frame.y + frame.height)
  end
  Assert.isTrue(width > 0 and height > 0, versionId .. " covers its panes")
  return width, height
end

---@param scope table test-owned graphics scope
---@param screen table live battle screen under capture
---@param width integer host canvas width under capture
---@param height integer host canvas height under capture
---@return table readable pixels of one render
local function renderCapture(scope, screen, width, height)
  local canvas = scope:own(love.graphics.newCanvas(width, height, { format = "rgba8", readable = true }))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  screen:draw({ graphics = love.graphics })
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

local function captureRoot()
  local runDir = os.getenv("PORTEMON_TEST_RUN_DIR")
  if runDir ~= nil and runDir ~= "" then
    return runDir .. "/battle-presentation-captures"
  end
  return (os.getenv("TMPDIR") or "/tmp") .. "/portemon-battle-presentation-captures"
end

local function saveCapture(data, name)
  local directories = { captureRoot() }
  for _, directory in ipairs(directories) do
    local quoted = "'" .. directory:gsub("'", "'\\''") .. "'"
    local created = os.execute("mkdir -p -- " .. quoted)
    Assert.isTrue(created == true or created == 0, "the capture directory is writable at " .. directory)
    local file = assert(io.open(directory .. "/" .. name .. ".png", "wb"), "the capture opens at " .. directory)
    file:write(data:encode("png"):getString())
    file:close()
  end
end

-- Counts host pixels whose quantized color exactly matches the given
-- 0..255 triple with a fully opaque sample.
---@param data table readable pixels under census
---@param rect table host rectangle under census
---@return integer exact matches
local function countColor(data, rect, want)
  local count = 0
  for y = rect.y, rect.y + rect.height - 1 do
    for x = rect.x, rect.x + rect.width - 1 do
      local red, green, blue, alpha = data:getPixel(x, y)
      if
        quantize(alpha) == 255
        and quantize(red) == want[1]
        and quantize(green) == want[2]
        and quantize(blue) == want[3]
      then
        count = count + 1
      end
    end
  end
  return count
end

-- Counts host pixels covered by any opaque sample.
---@param data table readable pixels under census
---@param rect table host rectangle under census
---@return integer covered pixels
local function countInk(data, rect)
  local count = 0
  for y = rect.y, rect.y + rect.height - 1 do
    for x = rect.x, rect.x + rect.width - 1 do
      local _, _, _, alpha = data:getPixel(x, y)
      if alpha > 0 then
        count = count + 1
      end
    end
  end
  return count
end

-- Counts green-dominant opaque pixels: the staged gauge art shades the
-- health fill across a green gradient instead of a single flat channel
-- triple, so an exact triple never occurs while the bar still paints.
---@param data table readable pixels under census
---@param rect table host rectangle under census
---@return integer green-dominant samples
local function countBarGreen(data, rect)
  local count = 0
  for y = rect.y, rect.y + rect.height - 1 do
    for x = rect.x, rect.x + rect.width - 1 do
      local red, green, blue, alpha = data:getPixel(x, y)
      local r, g, b = quantize(red), quantize(green), quantize(blue)
      if quantize(alpha) == 255 and g >= 150 and g > r + 30 and g > b + 30 then
        count = count + 1
      end
    end
  end
  return count
end

-- Counts host pixels matching the decoded staged source at the same
-- 1:1 offset where the source is opaque.
---@param capture table rendered pixels under census
---@param source table decoded staged source pixels
---@param rect table host rectangle under census
---@param offsetX integer source left edge in host coordinates
---@param offsetY integer source top edge in host coordinates
---@return integer matches
---@return integer source-occupied samples
local function countSourceMatches(capture, source, rect, offsetX, offsetY)
  local matches, occupied = 0, 0
  for y = rect.y, rect.y + rect.height - 1 do
    for x = rect.x, rect.x + rect.width - 1 do
      local sx, sy = x - offsetX, y - offsetY
      if sx >= 0 and sy >= 0 and sx < source:getWidth() and sy < source:getHeight() then
        local _, _, _, sourceAlpha = source:getPixel(sx, sy)
        if sourceAlpha > 0.5 then
          occupied = occupied + 1
          local r1, g1, b1, a1 = capture:getPixel(x, y)
          local r2, g2, b2, a2 = source:getPixel(sx, sy)
          if
            quantize(r1) == quantize(r2)
            and quantize(g1) == quantize(g2)
            and quantize(b1) == quantize(b2)
            and quantize(a1) == quantize(a2)
          then
            matches = matches + 1
          end
        end
      end
    end
  end
  return matches, occupied
end

-- Counts pixels matching a nearest-neighbor half-size presentation of an
-- original 80x80 staged portrait. The source portrait remains untouched.
local function countHalfScalePortraitMatches(capture, source, rect, offsetX, offsetY, phaseX, phaseY)
  Assert.equal(source:getWidth(), 80, "the staged portrait keeps its 80-pixel source width")
  Assert.equal(source:getHeight(), 80, "the staged portrait keeps its 80-pixel source height")
  local matches, occupied = 0, 0
  for y = 0, 39 do
    for x = 0, 39 do
      -- Nearest filtering selects one pixel from each 2x2 source footprint;
      -- the host pixel-center convention determines which row and column.
      local sx, sy = x * 2 + (phaseX or 1), y * 2 + (phaseY or 1)
      local _, _, _, alpha = source:getPixel(sx, sy)
      if alpha > 0.5 then
        occupied = occupied + 1
        local r1, g1, b1, a1 = capture:getPixel(rect.x + (offsetX or 0) + x, rect.y + (offsetY or 0) + y)
        local r2, g2, b2, a2 = source:getPixel(sx, sy)
        if
          quantize(r1) == quantize(r2)
          and quantize(g1) == quantize(g2)
          and quantize(b1) == quantize(b2)
          and quantize(a1) == quantize(a2)
        then
          matches = matches + 1
        end
      end
    end
  end
  return matches, occupied
end

-- Counts pixels in a rendered scene rectangle that differ from the
-- staged background at the same scene-relative coordinates.
local function countSceneChanges(capture, scene, rect, sceneOriginX, sceneOriginY)
  local changed = 0
  for y = rect.y, rect.y + rect.height - 1 do
    for x = rect.x, rect.x + rect.width - 1 do
      local sx, sy = x - sceneOriginX, y - sceneOriginY
      local r1, g1, b1, a1 = capture:getPixel(x, y)
      local r2, g2, b2, a2 = scene:getPixel(sx, sy)
      if
        quantize(r1) ~= quantize(r2)
        or quantize(g1) ~= quantize(g2)
        or quantize(b1) ~= quantize(b2)
        or quantize(a1) ~= quantize(a2)
      then
        changed = changed + 1
      end
    end
  end
  return changed
end

local function hostRect(frame, local_)
  return { x = frame.x + local_.x, y = frame.y + local_.y, width = local_.width, height = local_.height }
end

-- Counts host pixels matching one 16x16 gauge cell sampled row-major
-- from its staged strip, where the strip cell is opaque. Tiles lay out
-- row-major from the state base tile in the single strip row.
---@param capture table rendered pixels under census
---@param strip table decoded staged strip pixels
---@param hostX integer cell left edge in host coordinates
---@param hostY integer cell top edge in host coordinates
---@param baseTile integer state base tile under census
---@param span integer? cell edge in tiles (2 for 16-pixel families, 4 for 32-pixel families)
---@return integer matches
---@return integer source-occupied samples
local function countGaugeMatches(capture, strip, hostX, hostY, baseTile, span)
  span = span or 2
  local matches, occupied = 0, 0
  for row = 0, span - 1 do
    for col = 0, span - 1 do
      local tile = baseTile + row * span + col
      for py = 0, 7 do
        for px = 0, 7 do
          local sx, sy = tile * 8 + px, py
          local gx, gy = hostX + col * 8 + px, hostY + row * 8 + py
          if gx >= 0 and gy >= 0 and gx < capture:getWidth() and gy < capture:getHeight() then
            local _, _, _, sourceAlpha = strip:getPixel(sx, sy)
            if sourceAlpha > 0.5 then
              occupied = occupied + 1
              local r1, g1, b1, a1 = capture:getPixel(gx, gy)
              local r2, g2, b2, a2 = strip:getPixel(sx, sy)
              if
                quantize(r1) == quantize(r2)
                and quantize(g1) == quantize(g2)
                and quantize(b1) == quantize(b2)
                and quantize(a1) == quantize(a2)
              then
                matches = matches + 1
              end
            end
          end
        end
      end
    end
  end
  return matches, occupied
end

-- Independently follows the compiled source animation and cell records,
-- sampling each object's row-major tiles at its source anchor. This does
-- not use BattleRenderer's object painter or anchor table.
local DOUBLE_HUD_PATCH_SPANS = {
  playerLeft = {
    { 0x240, 0xC0 },
    { 0x340, 0xC0 },
    { 0xA00, 0x40 },
    { 0xB00, 0x40 },
    { 0xA40, 0x40 },
    { 0xB40, 0x40 },
    { 0xA80, 0x60 },
    { 0xB80, 0x60 },
    { 0x4E0, 0 },
    { 0xC00, 0xC0 },
  },
  playerRight = {
    { 0x240, 0xC0 },
    { 0x340, 0xC0 },
    { 0xA00, 0x40 },
    { 0xB00, 0x40 },
    { 0xA40, 0x40 },
    { 0xB40, 0x40 },
    { 0xA80, 0x60 },
    { 0xB80, 0x60 },
    { 0x4E0, 0 },
    { 0xC00, 0xC0 },
  },
  enemyLeft = {
    { 0x220, 0xE0 },
    { 0x320, 0xE0 },
    { 0xA00, 0x20 },
    { 0xB00, 0x20 },
    { 0xA20, 0x40 },
    { 0xB20, 0x40 },
    { 0xA60, 0x60 },
    { 0xB60, 0x60 },
    { 0x4E0, 0x20 },
    { 0xC00, 0xA0 },
  },
  enemyRight = {
    { 0x220, 0xE0 },
    { 0x320, 0xE0 },
    { 0xA00, 0x20 },
    { 0xB00, 0x20 },
    { 0xA20, 0x40 },
    { 0xB20, 0x40 },
    { 0xA60, 0x60 },
    { 0xB60, 0x60 },
    { 0x4E0, 0x20 },
    { 0xC00, 0xA0 },
  },
}

-- Reconstructs source-patched pixels independently from the source byte
-- spans and staged OAM tile grids. Each 32-byte 4bpp tile maps to one
-- 8x8 cell at its object's source anchor.
local function sourcePatchMask(section, spans, hostX, hostY)
  local frame = assert(section.animation.frames[1], "the source HUD animation has an initial frame")
  local cell = assert(section.cells[frame.cell + 1], "the initial source HUD frame selects a cell")
  local mask = {}
  for _, span in ipairs(spans) do
    local firstTile = span[1] / 32
    local tileCount = span[2] / 32
    for sourceTile = firstTile, firstTile + tileCount - 1 do
      for _, object in ipairs(cell.objs) do
        local tilesPerRow = object.width / 8
        local tileRows = object.height / 8
        local localTile = sourceTile - object.tile
        if localTile >= 0 and localTile < tilesPerRow * tileRows then
          local tileX = hostX + object.x + localTile % tilesPerRow * 8
          local tileY = hostY + object.y + math.floor(localTile / tilesPerRow) * 8
          for y = tileY, tileY + 7 do
            for x = tileX, tileX + 7 do
              mask[y * 256 + x] = true
            end
          end
        end
      end
    end
  end
  return mask
end

-- Mirrors the compact renderer: the staged HUD cell scales to fit the
-- plan box, so a canvas pixel inverse-maps to its strip texel through
-- the same cell bounds, origin, and scale. Bar and icon patch
-- destinations ride the same transform into host-space dynamic tiles
-- from the staged spans, exactly like the renderer overwrites them.
---@param strip table staged strip pixels under census
---@param section table staged HUD section carrying the drawn cell
---@param box table host HUD box under census
---@param patchSpans table<string, unknown> normalized source HUD patch map
---@param sideType integer native health-box side type under census
---@return fun(x: integer, y: integer): integer?, integer?, integer? locator naming the strip tile and texel, nil outside the cell
---@return fun(tile: integer): boolean dynamic check for patch-overwritten destination tiles
local function scaledCellLookup(strip, section, box, patchSpans, sideType, offsetY)
  local frame = assert(section.animation.frames[1], "the staged HUD animation has an initial frame")
  local cell = assert(section.cells[frame.cell + 1], "the initial HUD frame selects a cell")
  local objects = cell.objs
  local left, top, right, bottom = math.huge, math.huge, -math.huge, -math.huge
  for _, object in ipairs(objects) do
    if not object.disabled then
      left = math.min(left, object.x)
      top = math.min(top, object.y)
      right = math.max(right, object.x + object.width)
      bottom = math.max(bottom, object.y + object.height)
    end
  end
  local width, height = right - left, bottom - top
  local scale = math.min(box.width / width, box.height / height)
  local originX = box.x + (box.width - width * scale) / 2 - left * scale
  local originY = box.y + (box.height - height * scale) / 2 - top * scale + offsetY
  local dynamic = {}
  for _, patch in ipairs(BattleScene.hpPatchTiles(patchSpans, sideType, 1, 1)) do
    dynamic[patch.tile] = true
  end
  for _, patch in ipairs(BattleScene.hudIconPatchTiles(patchSpans, sideType, nil, "male", true)) do
    dynamic[patch.tile] = true
  end
  for _, record in ipairs(patchSpans.level) do
    if record.sideType == sideType then
      for _, span in ipairs(record.spans) do
        for tile = span.tile, span.tile + span.count - 1 do
          dynamic[tile] = true
        end
      end
      break
    end
  end
  local function locate(x, y)
    -- Pixel centers sample the strip like the rasterizer: the integer
    -- canvas origin names a texel corner, so the lookup recenters.
    local px, py = x + 0.5, y + 0.5
    for _, object in ipairs(objects) do
      if not object.disabled then
        local lx = (px - originX) / scale - object.x
        local ly = (py - originY) / scale - object.y
        if lx >= 0 and ly >= 0 and lx < object.width and ly < object.height then
          local columns = math.floor(object.width / 8)
          local tileCol = math.floor(lx / 8)
          local tileRow = math.floor(ly / 8)
          return object.tile + tileRow * columns + tileCol, math.floor(lx - tileCol * 8), math.floor(ly - tileRow * 8)
        end
      end
    end
    return nil
  end
  local function isDynamic(tile)
    return tile ~= nil and dynamic[tile] == true
  end
  return locate, isDynamic
end

local function countHudCellMatches(capture, strip, section, hostX, hostY, maskedPixels)
  local frame = assert(section.animation.frames[1], "the source HUD animation has an initial frame")
  local cell = assert(section.cells[frame.cell + 1], "the initial source HUD frame selects a cell")
  local matched, occupied = 0, 0
  for _, object in ipairs(cell.objs) do
    local tilesPerRow = object.width / 8
    local tileRows = object.height / 8
    for tileRow = 0, tileRows - 1 do
      local sourceTile = object.tile + tileRow * tilesPerRow
      local objectX = hostX + object.x
      local objectY = hostY + object.y + tileRow * 8
      for y = 0, 7 do
        for x = 0, object.width - 1 do
          local sourceX = sourceTile * 8 + x
          local _, _, _, sourceAlpha = strip:getPixel(sourceX, y)
          local screenX, screenY = objectX + x, objectY + y
          if
            sourceAlpha > 0.5
            and screenX >= 0
            and screenX < capture:getWidth()
            and screenY >= 0
            and screenY < capture:getHeight()
            and not maskedPixels[screenY * 256 + screenX]
          then
            occupied = occupied + 1
            local r1, g1, b1, a1 = capture:getPixel(screenX, screenY)
            local r2, g2, b2, a2 = strip:getPixel(sourceX, y)
            if
              quantize(r1) == quantize(r2)
              and quantize(g1) == quantize(g2)
              and quantize(b1) == quantize(b2)
              and quantize(a1) == quantize(a2)
            then
              matched = matched + 1
            end
          end
        end
      end
    end
  end
  return matched, occupied
end

local function rectanglesOverlap(first, second)
  return first.x < second.x + second.width
    and second.x < first.x + first.width
    and first.y < second.y + second.height
    and second.y < first.y + first.height
end

-- The compact command view carries real staged pixels end to end: the
-- scene viewport fills with scene ink, the prompt and every command cell
-- carry text ink, moving the selection repaints the command box while the
-- prompt stays put, the dock frames ring their content boxes, both health
-- bars draw in their published bar rects, both HUD composites match
-- their staged source strips, and every published HUD wording prints ink
-- inside its own region while pixels outside the published regions still
-- match only scene, strip, or portrait sources.
function T.compact_command_view_uses_real_scene_text_frames_and_hud(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the battle captures need a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local screen, _, portraitCells = captureScreen(scope, cacheFs, versionId, compactMeasurement())
    driveToCommand(screen, versionId)
    local plan = livePlan(screen, versionId)
    Assert.isTrue(plan.content.compact == true, versionId .. " resolves the compact plan")
    local width, height = canvasSize(plan, versionId)
    Assert.equal(width, 256, versionId .. " keeps the compact canvas width")
    Assert.equal(height, 192, versionId .. " keeps the compact canvas height")
    local frame = assert(plan.panes[1].placement.frame, versionId .. " frames its compact pane")
    local content = assert(plan.content, versionId .. " carries its compact content")

    local first = renderCapture(scope, screen, width, height)
    local second = renderCapture(scope, screen, width, height)
    Assert.equal(
      imageDataDigest(first),
      imageDataDigest(second),
      versionId .. " renders the compact command view deterministically"
    )
    saveCapture(first, versionId .. "-compact-command")

    local sceneBox = hostRect(frame, content.scene)
    Assert.isTrue(countInk(first, sceneBox) > 20000, versionId .. " fills the compact scene viewport with scene ink")

    local promptBox = hostRect(frame, content.prompt.content)
    Assert.isTrue(countInk(first, promptBox) > 100, versionId .. " prints prompt text ink")

    local cells = assert(content.commands.cells, versionId .. " carries its command cells")
    Assert.equal(#cells, 4, versionId .. " lays out four command cells")
    for _, cell in ipairs(cells) do
      Assert.isTrue(
        countInk(first, hostRect(frame, cell)) > 30,
        versionId .. " prints the " .. tostring(cell.id) .. " command label"
      )
    end

    local moved = captureScreen(scope, cacheFs, versionId, compactMeasurement())
    driveToCommand(moved, versionId)
    moved:input({ { type = "navigate", direction = "down" } })
    moved:updateFixed(TICK)
    local movedPlan = livePlan(moved, versionId)
    local movedFrame = assert(movedPlan.panes[1].placement.frame, versionId .. " frames its moved pane")
    local movedContent = assert(movedPlan.content, versionId .. " carries its moved content")
    local movedCapture = renderCapture(scope, moved, width, height)
    local commandBox = hostRect(frame, content.commands.outer)
    Assert.isTrue(
      regionDistance(first, movedCapture, commandBox, 1) > 20,
      versionId .. " repaints the command box under its moved selection"
    )
    Assert.isTrue(
      regionDistance(first, movedCapture, hostRect(movedFrame, movedContent.prompt.outer), 2) < 50,
      versionId .. " keeps the prompt box put under its moved selection"
    )

    for _, dock in ipairs({
      { outer = content.prompt.outer, inner = content.prompt.content, label = "prompt" },
      { outer = content.commands.outer, inner = content.commands.content, label = "command" },
    }) do
      local ring = 0
      local outerBox = hostRect(frame, dock.outer)
      local innerBox = hostRect(frame, dock.inner)
      for y = outerBox.y, outerBox.y + outerBox.height - 1 do
        for x = outerBox.x, outerBox.x + outerBox.width - 1 do
          local inside = x >= innerBox.x
            and x < innerBox.x + innerBox.width
            and y >= innerBox.y
            and y < innerBox.y + innerBox.height
          if not inside then
            local red, green, blue, alpha = first:getPixel(x, y)
            if alpha > 0 and quantize(red) + quantize(green) + quantize(blue) > 0 then
              ring = ring + 1
            end
          end
        end
      end
      Assert.isTrue(ring > 20, versionId .. " rings the " .. dock.label .. " dock with frame ink")
    end

    local hud = assert(content.hud, versionId .. " carries its compact HUD")
    for _, side in ipairs({ { box = hud.enemy, label = "enemy" }, { box = hud.player, label = "player" } }) do
      local bar = assert(side.box.bar, versionId .. " carries its " .. side.label .. " bar")
      Assert.isTrue((bar.fraction or 0) > 0, versionId .. " fills the " .. side.label .. " health bar")
      -- Single-battle health bars are native tile work sampled from
      -- the staged strip, not flat rectangles at the plan rect: the
      -- green bar tiles land inside the scaled HUD cell, so the
      -- bar-ink census covers the whole HUD box.
      Assert.isTrue(
        countBarGreen(first, hostRect(frame, side.box)) > 10,
        versionId .. " draws the " .. side.label .. " health bar"
      )
    end

    local enemyStrip = decodeData(
      scope,
      cacheFs,
      assert(BattlePresentationCache.load(cacheFs).hud.enemy, versionId .. " carries enemy HUD").image,
      versionId .. " enemy HUD source"
    )
    local playerStrip = decodeData(
      scope,
      cacheFs,
      assert(BattlePresentationCache.load(cacheFs).hud.player, versionId .. " carries player HUD").image,
      versionId .. " player HUD source"
    )
    local sceneSource =
      decodeData(scope, cacheFs, BattlePresentationCache.sceneImagePath(SCENE_KEY), versionId .. " scene source")
    local stagedManifest = BattlePresentationCache.load(cacheFs)
    local stagedPatchSpans = assert(stagedManifest.hud.patchSpans, versionId .. " carries its HUD patch spans")
    local snapshot = screen:_snapshot()
    local actorCombatant = type(snapshot.actor) == "table" and snapshot.actor.combatant or nil
    for _, side in ipairs({
      {
        box = hud.enemy,
        strip = enemyStrip,
        section = stagedManifest.hud.enemy,
        sideType = 1,
        label = "enemy",
      },
      {
        box = hud.player,
        strip = playerStrip,
        section = stagedManifest.hud.player,
        sideType = 0,
        label = "player",
      },
    }) do
      local box = hostRect(frame, side.box)
      local hudOffsetY = 0
      if side.sideType == 0 then
        for _, battler in ipairs(snapshot.battlers) do
          if battler.combatant == actorCombatant and battler.side == 1 then
            local cell = assert(side.section.cells[side.section.animation.frames[1].cell + 1])
            local left, top, right, bottom = math.huge, math.huge, -math.huge, -math.huge
            for _, object in ipairs(cell.objs) do
              if not object.disabled then
                left = math.min(left, object.x)
                top = math.min(top, object.y)
                right = math.max(right, object.x + object.width)
                bottom = math.max(bottom, object.y + object.height)
              end
            end
            hudOffsetY = (battler.hudOffsetY or 0) * math.min(box.width / (right - left), box.height / (bottom - top))
            break
          end
        end
      end
      local locateCell, isDynamicTile =
        scaledCellLookup(side.strip, side.section, box, stagedPatchSpans, side.sideType, hudOffsetY)
      local sampleTop = math.floor(box.y + hudOffsetY)
      local sampleBottom = math.ceil(box.y + hudOffsetY + box.height) - 1
      local stripMatches, stripOccupied = 0, 0
      -- Battler pictures draw before the HUD composites, so the foe
      -- picture shows through wherever the player composite stays
      -- transparent: those pixels must match the portrait sources too.
      local portraits = {}
      local foeKey = "mon:" .. MonCache.portraitSelector(FOE_SPECIES, 0, "male", false)
      local leadKey = "mon:" .. MonCache.portraitSelector(LEAD_SPECIES, 0, "male", false, "back")
      for _, key in ipairs({ foeKey, leadKey }) do
        local cell = assert(portraitCells[key], versionId .. " crops " .. key)
        local origin = key == foeKey and content.enemyCenter or content.playerCenter
        portraits[#portraits + 1] = {
          data = cell,
          x = frame.x + origin.x,
          y = frame.y + origin.y,
        }
      end
      local textRegions = {}
      for _, region in ipairs(side.box.regions) do
        if type(region.text) == "string" and region.text ~= "" then
          local rect = hostRect(frame, region)
          rect.y = rect.y + hudOffsetY
          textRegions[#textRegions + 1] = { rect = rect, id = region.id, ink = 0, darkInk = 0 }
        end
      end
      Assert.isTrue(#textRegions > 0, versionId .. " publishes its " .. side.label .. " HUD wording")
      local violations = 0
      local violationSample = {}
      for y = sampleTop, sampleBottom do
        for x = box.x, box.x + box.width - 1 do
          local tile, texX, texY = locateCell(x, y)
          local isDynamic = isDynamicTile(tile)
          local inRegion = nil
          if not isDynamic then
            for _, textRegion in ipairs(textRegions) do
              local rect = textRegion.rect
              -- Compact level digits retain the native split-tile
              -- baseline, which sits below the compressed layout row.
              local bottomOverhang = textRegion.id == "level" and 16 or 4
              if
                x >= rect.x - 4
                and x < rect.x + rect.width + 4
                and y >= rect.y - 4
                and y < rect.y + rect.height + bottomOverhang
              then
                inRegion = textRegion
                break
              end
            end
          end
          if not isDynamic then
            local pixel = { first:getPixel(x, y) }
            if inRegion ~= nil and inRegion.id == "name" then
              local red, green, blue = quantize(pixel[1]), quantize(pixel[2]), quantize(pixel[3])
              if math.max(red, green, blue) < 128 then
                inRegion.darkInk = inRegion.darkInk + 1
              end
            end
            local function near(source, sx, sy)
              if sx < 0 or sy < 0 or sx >= source:getWidth() or sy >= source:getHeight() then
                return false
              end
              local probe = { source:getPixel(sx, sy) }
              for channel = 1, 4 do
                if math.abs(quantize(pixel[channel]) - quantize(probe[channel])) > 1 then
                  return false
                end
              end
              return true
            end
            local sourced = near(sceneSource, x - sceneBox.x, y - sceneBox.y)
            if not sourced and tile ~= nil then
              -- Minified sampling can land on a neighboring texel; accept
              -- one-texel bleed so staged cell pixels remain source-attributed.
              for dy = -1, 1 do
                for dx = -1, 1 do
                  if near(side.strip, tile * 8 + texX + dx, texY + dy) then
                    sourced = true
                    break
                  end
                end
                if sourced then
                  break
                end
              end
              local _, _, _, stripAlpha = side.strip:getPixel(tile * 8 + texX, texY)
              if stripAlpha > 0.5 then
                stripOccupied = stripOccupied + 1
                if sourced then
                  stripMatches = stripMatches + 1
                end
              end
            end
            if not sourced then
              for _, portrait in ipairs(portraits) do
                if near(portrait.data, x - portrait.x, y - portrait.y) then
                  sourced = true
                  break
                end
              end
            end
            if not sourced then
              if inRegion ~= nil then
                inRegion.ink = inRegion.ink + 1
              else
                violations = violations + 1
                if #violationSample < 8 then
                  violationSample[#violationSample + 1] = x .. "," .. y
                end
              end
            end
          end
        end
      end
      for _, textRegion in ipairs(textRegions) do
        if textRegion.id == "name" then
          Assert.isTrue(
            textRegion.darkInk > 10,
            versionId .. " prints dark " .. side.label .. " name ink (" .. tostring(textRegion.darkInk) .. " px)"
          )
        elseif textRegion.id == "gender" then
          Assert.equal(
            textRegion.ink,
            0,
            versionId .. " prints its native " .. side.label .. " " .. textRegion.id .. " printer tiles"
          )
        end
      end
      Assert.equal(
        violations,
        0,
        versionId
          .. " paints no extra glyphs outside its published "
          .. side.label
          .. " regions ("
          .. tostring(violations)
          .. " at "
          .. table.concat(violationSample, " ")
          .. ")"
      )
      Assert.isTrue(
        stripOccupied > 500,
        versionId .. " stages an occupied " .. side.label .. " composite (" .. tostring(stripOccupied) .. " px)"
      )
      Assert.isTrue(
        stripMatches / stripOccupied > 0.8,
        versionId
          .. " composites the staged "
          .. side.label
          .. " artwork ("
          .. tostring(stripMatches)
          .. "/"
          .. tostring(stripOccupied)
          .. ")"
      )
    end
    local expText = nil
    for _, region in ipairs(hud.player.regions) do
      if region.id == "exp" then
        expText = region.text
      end
    end
    Assert.equal(expText, "", versionId .. " prints no numeric experience total; the gauge tiles carry the progress")

    -- Battler pictures draw top-left at the plan image centers, clipped to
    -- the scene viewport: the enemy picture overhangs the pane edge while
    -- the lead picture stops above the dock.
    local enemyPicture =
      { x = frame.x + content.enemyCenter.x, y = frame.y + content.enemyCenter.y, width = 60, height = 80 }
    local playerPicture =
      { x = frame.x + content.playerCenter.x, y = frame.y + content.playerCenter.y, width = 80, height = 40 }
    Assert.isFalse(
      rectanglesOverlap(enemyPicture, hostRect(frame, hud.enemy)),
      versionId .. " keeps the foe picture clear of the enemy HUD census"
    )
    Assert.isFalse(
      rectanglesOverlap(playerPicture, hostRect(frame, hud.player)),
      versionId .. " keeps the lead picture clear of the player HUD census"
    )
    for _, picture in ipairs({ { rect = enemyPicture, label = "foe" }, { rect = playerPicture, label = "lead" } }) do
      local changed = 0
      for y = picture.rect.y, picture.rect.y + picture.rect.height - 1 do
        for x = picture.rect.x, picture.rect.x + picture.rect.width - 1 do
          local sx, sy = x - sceneBox.x, y - sceneBox.y
          if sx >= 0 and sy >= 0 and sx < sceneSource:getWidth() and sy < sceneSource:getHeight() then
            local r1, g1, b1 = first:getPixel(x, y)
            local r2, g2, b2 = sceneSource:getPixel(sx, sy)
            if math.abs(r1 - r2) + math.abs(g1 - g2) + math.abs(b1 - b2) > 0.03 then
              changed = changed + 1
            end
          end
        end
      end
      Assert.isTrue(changed > 100, versionId .. " draws its " .. picture.label .. " portrait over the scene")
    end
  end
end

-- Native doubles exercise the production screen and staged ROM sections.
-- Each visible role must reproduce opaque pixels from its own selected
-- source cell at the source anchor; this check derives tiles from the
-- manifest and samples the staged strip independently of the renderer.
function T.native_doubles_draws_the_four_staged_source_hud_cells(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("native doubled HUD pixel checks need a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local screen = captureScreen(scope, cacheFs, versionId, dualMeasurement())
    drivePacketToCommand(screen, versionId, doubledBattlePacket(), "trainer")
    local plan = livePlan(screen, versionId)
    local detailFrame
    for _, pane in ipairs(plan.panes) do
      if pane.id == "detail" then
        detailFrame = assert(pane.placement.frame, versionId .. " places its native detail pane")
      end
    end
    Assert.notNil(detailFrame, versionId .. " plans its native detail pane")
    local capture = renderCapture(scope, screen, 256, 384)
    saveCapture(capture, versionId .. "-native-doubles-hud")
    local snapshot = screen:_snapshot()
    local actorCombatant = type(snapshot.actor) == "table" and snapshot.actor.combatant or nil
    local playerIndex = 0
    local activePlayerHudSlot = nil
    local activePlayerHudOffset = 0
    for _, battler in ipairs(snapshot.battlers) do
      if battler.side == 1 then
        playerIndex = playerIndex + 1
        if battler.combatant == actorCombatant then
          activePlayerHudSlot = playerIndex == 1 and "playerLeft" or "playerRight"
          activePlayerHudOffset = battler.hudOffsetY or 0
        end
      end
    end
    local manifest = BattlePresentationCache.load(cacheFs)
    local sections = assert(manifest.hud.doubles, versionId .. " stages the four native doubled HUD sections")
    for slot, origin in pairs(NATIVE_DOUBLES_HUD_ORIGINS) do
      local section = assert(sections[slot], versionId .. " stages the " .. slot .. " source cell")
      local strip = decodeData(scope, cacheFs, section.image, versionId .. " " .. slot .. " source strip")
      local hudOffsetY = slot == activePlayerHudSlot and activePlayerHudOffset or 0
      local sampleX = detailFrame.x + origin.x
      local sampleY = detailFrame.y + origin.y + hudOffsetY
      local maskedPixels = sourcePatchMask(section, DOUBLE_HUD_PATCH_SPANS[slot], sampleX, sampleY)
      if slot == "playerLeft" or slot == "playerRight" then
        for y = detailFrame.y + 144 + hudOffsetY, detailFrame.y + 183 + hudOffsetY do
          for x = detailFrame.x + 8, detailFrame.x + 247 do
            maskedPixels[y * 256 + x] = true
          end
        end
      end
      local matched, occupied = countHudCellMatches(capture, strip, section, sampleX, sampleY, maskedPixels)
      Assert.isTrue(occupied > 40, versionId .. " has source pixels in the " .. slot .. " initial cell")
      Assert.isTrue(
        matched / occupied > 0.6,
        versionId
          .. " draws the "
          .. slot
          .. " initial source cell at its original anchor (matched "
          .. tostring(matched)
          .. " of "
          .. tostring(occupied)
          .. " opaque samples)"
      )
    end
  end
end

-- Four staged portrait selectors are drawn through the production compact
-- battle composition. The actual pixel surface must show each portrait at
-- nearest-neighbor half scale, above both the move and target docks, with
-- bounded independent panels and no raw packed HUD strip painted as a panel.
function T.compact_doubles_captures_four_bounded_panels_and_half_scale_portraits(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the compact doubles capture needs a ready user-owned ROM with staged battle assets")
  end

  local portraitSpecs = {
    { position = 1, selector = MonCache.portraitSelector("RATTATA", 0, "male", false), pageId = 164 },
    { position = 2, selector = MonCache.portraitSelector("HEATRAN", 0, "male", false), pageId = 86 },
    { position = 3, selector = MonCache.portraitSelector("CHIKORITA", 0, "male", false, "back"), pageId = 34 },
    { position = 4, selector = MonCache.portraitSelector("HERACROSS", 0, "female", false, "back"), pageId = 86 },
  }
  local portraitByPosition = {}
  for _, portrait in ipairs(portraitSpecs) do
    portraitByPosition[portrait.position] = portrait
  end

  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local screen, images, portraitCells = captureScreen(scope, cacheFs, versionId, compactMeasurement())
    for _, portrait in ipairs(portraitSpecs) do
      local image, pixels = cropPortrait(scope, cacheFs, portrait.selector, portrait.pageId)
      images["mon:" .. portrait.selector] = cellHandle(image)
      portraitCells["mon:" .. portrait.selector] = pixels
    end

    local packet = openingPacket()
    packet.after.own = {
      {
        combatant = 0,
        side = 1,
        position = 3,
        active = true,
        species = "CHIKORITA",
        form = 0,
        selector = "back",
        portraitSelector = portraitByPosition[3].selector,
        name = "CHIKORITA",
        level = 9,
        hp = 30,
        maxHp = 30,
        experience = 120,
      },
      {
        combatant = 1,
        side = 1,
        position = 4,
        active = true,
        species = "HERACROSS",
        form = 0,
        selector = "back",
        portraitSelector = portraitByPosition[4].selector,
        name = "HERACROSS",
        level = 12,
        hp = 18,
        maxHp = 24,
        experience = 100,
      },
    }
    packet.after.foes = {
      {
        combatant = 2,
        side = 2,
        position = 1,
        active = true,
        species = "RATTATA",
        form = 0,
        selector = "front",
        portraitSelector = portraitByPosition[1].selector,
        name = "RATTATA",
        level = 3,
        hp = 12,
        maxHp = 12,
      },
      {
        combatant = 3,
        side = 2,
        position = 2,
        active = true,
        species = "HEATRAN",
        form = 0,
        selector = "front",
        portraitSelector = portraitByPosition[2].selector,
        name = "HEATRAN",
        level = 40,
        hp = 31,
        maxHp = 48,
      },
    }
    local move = moveChoice("move:0", "TACKLE", 35, 35, "NORMAL", 0)
    move.targets = {
      {
        id = "target:0",
        position = 1,
        combatant = 2,
        name = "RATTATA",
        enabled = true,
        choice = { kind = "attack", payload = { moveSlot = 0, target = { kind = "position", position = 1 } } },
      },
      {
        id = "target:1",
        position = 2,
        combatant = 3,
        name = "HEATRAN",
        enabled = true,
        choice = { kind = "attack", payload = { moveSlot = 0, target = { kind = "position", position = 2 } } },
      },
    }
    packet.request.actors = { { kind = "command" }, { kind = "command" } }
    packet.request.options.actors = {
      {
        kind = "command",
        choices = { move, { role = "run", enabled = true, choice = { kind = "run", payload = {} } } },
      },
      { kind = "command", choices = { moveChoice("move:0", "TACKLE", 35, 35, "NORMAL", 0) } },
    }
    drivePacketToCommand(screen, versionId, packet, "trainer")

    local function assertCapture(mode, captureName)
      Assert.equal(screen:status().mode, mode, versionId .. " reaches the " .. mode .. " compact dock")
      local plan = livePlan(screen, versionId)
      local content = assert(plan.content, versionId .. " carries its compact content")
      local width, height = canvasSize(plan, versionId)
      Assert.equal(width, 256, versionId .. " keeps the compact canvas width")
      Assert.equal(height, 192, versionId .. " keeps the compact canvas height")
      local frame = assert(plan.panes[1].placement.frame, versionId .. " frames the compact pane")
      local hud = assert(content.hud, versionId .. " carries the compact HUD")
      local boxes = assert(hud.boxes, versionId .. " plans one panel for each active battler")
      Assert.equal(#boxes, 4, versionId .. " plans four separate compact panels")
      local dock = hostRect(frame, assert(content.dock, versionId .. " publishes the active dock"))
      local scene = hostRect(frame, assert(content.scene, versionId .. " publishes the scene viewport"))
      local sceneSource = decodeData(
        scope,
        cacheFs,
        BattlePresentationCache.sceneImagePath(SCENE_KEY),
        versionId .. " compact doubles scene source"
      )
      local first = renderCapture(scope, screen, width, height)
      local second = renderCapture(scope, screen, width, height)
      Assert.equal(
        imageDataDigest(first),
        imageDataDigest(second),
        versionId .. " renders four compact doubles deterministically in " .. mode
      )
      saveCapture(first, versionId .. "-compact-doubles-" .. captureName)

      local seenPositions, seenPanels, pictures = {}, {}, {}
      local hudOffsetByPosition = {}
      local pictureOffsetByPosition = {}
      for _, battler in ipairs(screen:_snapshot().battlers) do
        if type(battler.position) == "number" then
          hudOffsetByPosition[battler.position] = battler.hudOffsetY or 0
          pictureOffsetByPosition[battler.position] = battler.pictureYOffset or 0
        end
      end
      for _, box in ipairs(boxes) do
        Assert.isNil(seenPositions[box.position], versionId .. " assigns one panel to each slot")
        seenPositions[box.position] = true
        local panel = hostRect(frame, box)
        Assert.isTrue(panel.x >= scene.x and panel.y >= scene.y, versionId .. " keeps each panel inside the scene")
        Assert.isTrue(
          panel.x + panel.width <= scene.x + scene.width and panel.y + panel.height <= 120,
          versionId .. " keeps each panel above the earliest move/target dock"
        )
        for _, prior in ipairs(seenPanels) do
          Assert.isFalse(rectanglesOverlap(panel, prior), versionId .. " keeps compact panels independent")
        end
        seenPanels[#seenPanels + 1] = panel
        local renderedOffsetY = (hudOffsetByPosition[box.position] or 0) * math.min(box.width / 128, box.height / 64)
        local labelRegion = nil
        for _, region in ipairs(box.regions or {}) do
          if region.id == "name" then
            labelRegion = region
            break
          end
        end
        Assert.notNil(labelRegion, versionId .. " publishes a name region for each panel")
        local nameRect = hostRect(frame, labelRegion)
        nameRect.y = nameRect.y + renderedOffsetY
        local nameBottom = math.ceil(nameRect.y + nameRect.height)
        nameRect.y = math.floor(nameRect.y)
        nameRect.height = nameBottom - nameRect.y
        Assert.isTrue(
          countSceneChanges(first, sceneSource, nameRect, scene.x, scene.y) > 10,
          versionId .. " prints the " .. tostring(labelRegion.text) .. " panel name"
        )
        if type(box.bar) == "table" then
          local barRect = hostRect(frame, box.bar)
          barRect.y = barRect.y + renderedOffsetY
          local barBottom = math.ceil(barRect.y + barRect.height)
          barRect.y = math.floor(barRect.y)
          barRect.height = barBottom - barRect.y
          Assert.isTrue(
            countColor(first, barRect, { 51, 204, 51 }) > 2,
            versionId .. " paints the " .. tostring(box.name) .. " health bar"
          )
        end
      end

      local manifest = BattlePresentationCache.load(cacheFs)
      for _, portrait in ipairs(portraitSpecs) do
        local spot = nil
        for _, candidate in ipairs(assert(content.spriteCenters, versionId .. " plans every portrait spot")) do
          if candidate.position == portrait.position then
            spot = candidate
            break
          end
        end
        Assert.notNil(spot, versionId .. " preserves the portrait's native slot")
        local rect = {
          x = frame.x + spot.x,
          y = frame.y + spot.y,
          width = 40,
          height = 40,
        }
        Assert.isTrue(rect.x >= scene.x and rect.y >= scene.y, versionId .. " keeps portraits on the scene")
        Assert.isTrue(
          rect.x + rect.width <= scene.x + scene.width and rect.y + rect.height <= 120,
          versionId .. " keeps every 40x40 portrait above the earliest dock"
        )
        Assert.isFalse(rectanglesOverlap(rect, dock), versionId .. " keeps portraits clear of the active dock")
        for _, panel in ipairs(seenPanels) do
          Assert.isFalse(rectanglesOverlap(rect, panel), versionId .. " keeps portraits clear of HUD panels")
        end
        for _, prior in ipairs(pictures) do
          Assert.isFalse(rectanglesOverlap(rect, prior), versionId .. " keeps all four portrait boxes separate")
        end
        pictures[#pictures + 1] = rect

        local source = assert(portraitCells["mon:" .. portrait.selector], versionId .. " stages " .. portrait.selector)
        local pictureOffset = (pictureOffsetByPosition[portrait.position] or 0) * spot.scale
        local renderedRect = {
          x = rect.x,
          y = math.floor(rect.y + pictureOffset + 0.5),
          width = rect.width,
          height = rect.height,
        }
        local matches, occupied = 0, 0
        for pixelOffsetY = -1, 1 do
          for phaseY = 0, 1 do
            for phaseX = 0, 1 do
              local alignedRect = {
                x = renderedRect.x,
                y = renderedRect.y + pixelOffsetY,
                width = renderedRect.width,
                height = renderedRect.height,
              }
              local phaseMatches, phaseOccupied =
                countHalfScalePortraitMatches(first, source, alignedRect, 0, 0, phaseX, phaseY)
              if phaseOccupied > 0 and phaseMatches / phaseOccupied > matches / math.max(occupied, 1) then
                matches, occupied = phaseMatches, phaseOccupied
              end
            end
          end
        end
        Assert.isTrue(occupied > 100, versionId .. " has visible source pixels for " .. portrait.selector)
        local matchThreshold = pictureOffset == 0 and 0.9 or 0.8
        Assert.isTrue(
          matches / occupied > matchThreshold,
          versionId
            .. " paints the nearest-neighbor half-scale pixels for "
            .. portrait.selector
            .. " ("
            .. tostring(matches)
            .. "/"
            .. tostring(occupied)
            .. ", y="
            .. tostring(renderedRect.y)
            .. ", pictureOffset="
            .. tostring(pictureOffset)
            .. ")"
        )
      end

      local sources = {
        { asset = assert(manifest.hud.enemy, versionId .. " stages enemy HUD strip") },
        { asset = assert(manifest.hud.player, versionId .. " stages player HUD strip") },
      }
      for _, panel in ipairs(seenPanels) do
        local owner = panel.y < 80 and "enemy" or "player"
        local sourceRecord = owner == "enemy" and sources[1].asset or sources[2].asset
        local strip = decodeData(scope, cacheFs, sourceRecord.image, versionId .. " " .. owner .. " strip")
        local sample = { x = panel.x, y = panel.y, width = math.min(panel.width, 96), height = 8 }
        local matches, occupied = countSourceMatches(first, strip, sample, panel.x, panel.y)
        Assert.isTrue(occupied > 10, versionId .. " samples the staged " .. owner .. " HUD strip")
        Assert.isTrue(
          matches / occupied < 0.5,
          versionId .. " does not paint a packed " .. owner .. " HUD strip as a finished panel"
        )
      end
    end

    assertCapture("command", "command")
    screen:input({ { type = "confirm" } })
    screen:updateFixed(TICK)
    Assert.equal(screen:status().mode, "moves", versionId .. " opens its move list")
    waitForMenuInput(screen, versionId)
    screen:input({ { type = "confirm" } })
    screen:updateFixed(TICK)
    assertCapture("target", "target")
  end
end

-- The compact Fight view prints its move facts through the staged font:
-- named move labels in their grid cells, the type and PP rows in the
-- information panel, and the Back label, all ringed by the dock frames.
function T.compact_fight_view_prints_real_move_text(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the battle captures need a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local screen = captureScreen(scope, cacheFs, versionId, compactMeasurement())
    driveToCommand(screen, versionId)
    screen:input({ { type = "confirm" } })
    screen:updateFixed(TICK)
    Assert.equal(screen:status().mode, "moves", versionId .. " opens the compact move view")
    local plan = livePlan(screen, versionId)
    local width, height = canvasSize(plan, versionId)
    local frame = assert(plan.panes[1].placement.frame, versionId .. " frames its compact pane")
    local content = assert(plan.content, versionId .. " carries its compact content")

    local first = renderCapture(scope, screen, width, height)
    local second = renderCapture(scope, screen, width, height)
    Assert.equal(
      imageDataDigest(first),
      imageDataDigest(second),
      versionId .. " renders the compact Fight view deterministically"
    )
    saveCapture(first, versionId .. "-compact-fight")

    local labels = assert(content.moveLabels, versionId .. " carries its move label origins")
    Assert.isTrue(#labels >= 2, versionId .. " lays out its move labels")
    Assert.isTrue(countInk(first, hostRect(frame, labels[1])) > 5, versionId .. " prints its first move label")
    Assert.isTrue(countInk(first, hostRect(frame, labels[2])) > 5, versionId .. " prints its second move label")
    Assert.equal(#content.moveSlots, 4, versionId .. " carries its per-slot icon and PP geometry")
    local slot = content.moveSlots[1]
    Assert.isTrue(
      countInk(first, hostRect(frame, slot.icon)) > 5,
      versionId .. " draws its first move type icon"
    )
    Assert.isTrue(
      countInk(first, { x = frame.x + slot.pp.x, y = frame.y + slot.pp.y, width = slot.pp.width, height = 12 }) > 5,
      versionId .. " prints its first move PP"
    )
    local back = assert(content.moveBack, versionId .. " carries its move Back cell")
    Assert.isTrue(countInk(first, hostRect(frame, back.rect)) > 5, versionId .. " prints its Back label")
  end
end

-- The native paired command view composes real staged art on both panes:
-- the scene with both battlers and the narration window on the detail
-- pane, and the staged command artwork with its labels and party gauges
-- on the interaction pane.
function T.native_command_view_composes_real_scene_menu_and_narration(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the battle captures need a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local screen, _, _, services = captureScreen(scope, cacheFs, versionId, dualMeasurement())
    driveToCommand(screen, versionId)
    local iconKey = MonCache.iconSelector(LEAD_SPECIES, 0, false)
    Assert.equal(screen:view().commandIcon.key, iconKey, versionId .. " presents the acting lead's party icon")
    Assert.equal(
      services.prepared[#services.prepared].iconKeys[1],
      iconKey,
      versionId .. " demands its exact icon page"
    )
    local plan = livePlan(screen, versionId)
    Assert.equal(#plan.panes, 2, versionId .. " pairs its native panes")
    local width, height = canvasSize(plan, versionId)
    local detailFrame, interactionFrame = nil, nil
    for _, pane in ipairs(plan.panes) do
      if pane.id == "detail" then
        detailFrame = pane.placement.frame
      elseif pane.id == "interaction" then
        interactionFrame = pane.placement.frame
      end
    end
    Assert.notNil(detailFrame, versionId .. " places its detail pane")
    Assert.notNil(interactionFrame, versionId .. " places its interaction pane")

    local first = renderCapture(scope, screen, width, height)
    local second = renderCapture(scope, screen, width, height)
    Assert.equal(
      imageDataDigest(first),
      imageDataDigest(second),
      versionId .. " renders the native command view deterministically"
    )
    saveCapture(first, versionId .. "-native-command")

    Assert.isTrue(
      countInk(first, { x = interactionFrame.x + 75, y = interactionFrame.y + 51, width = 32, height = 32 }) > 20,
      versionId .. " draws the lead icon beside FIGHT"
    )

    local detailBox = { x = detailFrame.x, y = detailFrame.y, width = 256, height = 192 }
    Assert.isTrue(countInk(first, detailBox) > 20000, versionId .. " fills the detail pane with scene ink")

    -- The native narration window fills its content with the message
    -- palette's background and prints the prompt over it, replacing the
    -- scene pixels inside the window's source content box.
    local narrationText = { x = detailFrame.x + 16, y = detailFrame.y + 152, width = 166, height = 16 }
    local detailScene =
      decodeData(scope, cacheFs, BattlePresentationCache.sceneImagePath(SCENE_KEY), versionId .. " scene source")
    Assert.isTrue(
      countSceneChanges(first, detailScene, narrationText, detailFrame.x, detailFrame.y) > 300,
      versionId .. " prints the narration prompt over the scene"
    )

    for _, picture in ipairs({
      { rect = { x = detailFrame.x + 192, y = detailFrame.y + 56, width = 64, height = 80 }, label = "foe" },
      { rect = { x = detailFrame.x + 64, y = detailFrame.y + 112, width = 80, height = 32 }, label = "lead" },
    }) do
      local changed = 0
      for y = picture.rect.y, picture.rect.y + picture.rect.height - 1 do
        for x = picture.rect.x, picture.rect.x + picture.rect.width - 1 do
          local sx, sy = x - detailFrame.x, y - detailFrame.y
          if sx >= 0 and sy >= 0 and sx < detailScene:getWidth() and sy < detailScene:getHeight() then
            local r1, g1, b1 = first:getPixel(x, y)
            local r2, g2, b2 = detailScene:getPixel(sx, sy)
            if math.abs(r1 - r2) + math.abs(g1 - g2) + math.abs(b1 - b2) > 0.03 then
              changed = changed + 1
            end
          end
        end
      end
      Assert.isTrue(changed > 50, versionId .. " draws its " .. picture.label .. " portrait on the detail pane")
    end

    local menuSource = decodeData(
      scope,
      cacheFs,
      assert(BattlePresentationCache.load(cacheFs).menus.command, versionId .. " carries command art").image,
      versionId .. " command source"
    )
    local interactionBox = { x = interactionFrame.x, y = interactionFrame.y, width = 256, height = 192 }
    Assert.isTrue(countInk(first, interactionBox) > 20000, versionId .. " paints the interaction pane")
    -- The native menu composites layered screens over the lower
    -- background instead of blitting one static surface, so the
    -- census proves staged screen ink in the top decoration band
    -- rather than a pixel-identical base blit.
    local decorationInk = 0
    for y = interactionFrame.y, interactionFrame.y + 15 do
      for x = interactionFrame.x, interactionFrame.x + 255 do
        local red, green, blue, alpha = first:getPixel(x, y)
        if alpha > 0 and (quantize(red) < 200 or quantize(green) < 200 or quantize(blue) < 200) then
          decorationInk = decorationInk + 1
        end
      end
    end
    Assert.isTrue(decorationInk > 2000, versionId .. " keeps the staged command artwork visible")

    for _, anchor in ipairs({
      { x = 128, y = 83, label = "FIGHT" },
      { x = 40, y = 169, label = "BAG" },
      { x = 216, y = 168, label = "POKEMON" },
      { x = 128, y = 176, label = "RUN" },
    }) do
      local labelBox =
        { x = interactionFrame.x + anchor.x - 28, y = interactionFrame.y + anchor.y - 6, width = 56, height = 12 }
      local changed = 0
      for y = labelBox.y, labelBox.y + labelBox.height - 1 do
        for x = labelBox.x, labelBox.x + labelBox.width - 1 do
          local sx, sy = x - interactionFrame.x, y - interactionFrame.y
          if sx >= 0 and sy >= 0 and sx < menuSource:getWidth() and sy < menuSource:getHeight() then
            local r1, g1, b1, a1 = first:getPixel(x, y)
            local r2, g2, b2, a2 = menuSource:getPixel(sx, sy)
            if
              quantize(r1) ~= quantize(r2)
              or quantize(g1) ~= quantize(g2)
              or quantize(b1) ~= quantize(b2)
              or quantize(a1) ~= quantize(a2)
            then
              changed = changed + 1
            end
          end
        end
      end
      Assert.isTrue(changed > 10, versionId .. " prints the " .. anchor.label .. " command label")
    end

    -- The staged sprite strips keep the tile geometry the native
    -- renderer samples: both HUD strips append their 78 native
    -- component tiles after the sprite characters (128 + 78 tiles at
    -- 8 pixels), the arrow stays component-free at 208x8, and the
    -- 16-pixel gauge family stays 128x8. A producer repagination fails
    -- here before any quad can sample the wrong tiles.
    local stagedManifest = BattlePresentationCache.load(cacheFs)
    local function stagedSize(path, label)
      local record = assert(stagedManifest.menus.images[path], versionId .. " stages " .. label)
      return record.width, record.height
    end
    local enemyHudWidth, enemyHudHeight =
      stagedSize(assert(stagedManifest.hud.enemy, versionId .. " carries enemy HUD").image, "enemy HUD")
    -- Health-box strips end with the printer's ten digits and fill tile.
    Assert.equal(
      enemyHudWidth,
      (stagedManifest.hud.enemy.digitBase + 11) * 8,
      versionId .. " keeps the enemy strip width"
    )
    Assert.equal(enemyHudHeight, 8, versionId .. " keeps the enemy strip row")
    local playerHudWidth, playerHudHeight =
      stagedSize(assert(stagedManifest.hud.player, versionId .. " carries player HUD").image, "player HUD")
    Assert.equal(
      playerHudWidth,
      (stagedManifest.hud.player.digitBase + 11) * 8,
      versionId .. " keeps the player strip width"
    )
    Assert.equal(playerHudHeight, 8, versionId .. " keeps the player strip row")
    local arrowWidth, arrowHeight =
      stagedSize(assert(stagedManifest.hud.arrow, versionId .. " carries the arrow").image, "arrow")
    Assert.equal(arrowWidth, 208, versionId .. " keeps the arrow strip width")
    Assert.equal(arrowHeight, 8, versionId .. " keeps the arrow strip row")
    local gaugeWidth, gaugeHeight =
      stagedSize(assert(stagedManifest.hud.partyGauges[1], versionId .. " carries party gauges").image, "gauges")
    Assert.equal(gaugeWidth, 128, versionId .. " keeps the gauge strip width")
    Assert.equal(gaugeHeight, 8, versionId .. " keeps the gauge strip row")

    -- The detail pane composites the staged HUD strips at their slot
    -- anchors: each single-battle cell matches its strip outside the
    -- dynamic patch tiles, exactly like the native doubles census
    -- above. Destinations come from the staged spans, so a producer
    -- repagination fails here before any quad can sample the wrong tiles.
    local stagedPatchSpans = assert(stagedManifest.hud.patchSpans, versionId .. " carries its HUD patch spans")
    local function dynamicTileSpans(sideType, withExp)
      local tiles = {}
      for _, patch in ipairs(BattleScene.hpPatchTiles(stagedPatchSpans, sideType, 1, 1)) do
        tiles[patch.tile] = true
      end
      for _, patch in ipairs(BattleScene.hudIconPatchTiles(stagedPatchSpans, sideType, nil, "male", true)) do
        tiles[patch.tile] = true
      end
      -- The nickname window and level digits print over their source tiles.
      for _, category in ipairs({ "nickname", "level" }) do
        for _, record in ipairs(stagedPatchSpans[category]) do
          if record.sideType == sideType then
            for _, span in ipairs(record.spans) do
              for offset = 0, span.count - 1 do
                tiles[span.tile + offset] = true
              end
            end
          end
        end
      end
      for _, group in ipairs({
        BattleScene.hpNumberPatchTiles(stagedPatchSpans, sideType).current,
        BattleScene.hpNumberPatchTiles(stagedPatchSpans, sideType).maximum,
      }) do
        for _, patch in ipairs(group) do
          tiles[patch.tile] = true
        end
      end
      if withExp then
        for _, patch in ipairs(BattleScene.expPatchTiles(stagedPatchSpans, BattleScene.expTileFills(96, 96))) do
          tiles[patch.tile] = true
        end
      end
      local spans = {}
      for tile in pairs(tiles) do
        spans[#spans + 1] = { tile * 32, 32 }
      end
      return spans
    end
    local enemyStrip = decodeData(
      scope,
      cacheFs,
      assert(stagedManifest.hud.enemy, versionId .. " carries enemy HUD").image,
      versionId .. " enemy HUD source"
    )
    local playerStrip = decodeData(
      scope,
      cacheFs,
      assert(stagedManifest.hud.player, versionId .. " carries player HUD").image,
      versionId .. " player HUD source"
    )
    for _, band in ipairs({
      {
        strip = enemyStrip,
        section = stagedManifest.hud.enemy,
        sideType = 1,
        origin = { x = 58, y = 36 },
        label = "enemy",
      },
      {
        strip = playerStrip,
        section = stagedManifest.hud.player,
        sideType = 0,
        origin = { x = 192, y = 116 },
        label = "player",
      },
    }) do
      local masked = sourcePatchMask(
        band.section,
        dynamicTileSpans(band.sideType, band.sideType == 0),
        detailFrame.x + band.origin.x,
        detailFrame.y + band.origin.y
      )
      local bandMatches, bandOccupied = countHudCellMatches(
        first,
        band.strip,
        band.section,
        detailFrame.x + band.origin.x,
        detailFrame.y + band.origin.y,
        masked
      )
      Assert.isTrue(bandOccupied > 500, versionId .. " stages an occupied " .. band.label .. " cell")
      Assert.isTrue(
        bandMatches / bandOccupied > 0.6,
        versionId .. " composites the staged " .. band.label .. " artwork"
      )
    end

    -- Party gauges draw staged source cells by roster visibility: the
    -- standing lead selects the healthy ball cell at its slot origin.
    -- The opponent row belongs to trainer battles only, so this wild
    -- capture leaves the foe gauge slot to the lower background.
    -- Origins mirror the production gauge slot constants.
    local playerGaugeStrip = decodeData(
      scope,
      cacheFs,
      assert(stagedManifest.hud.partyGauges[2], versionId .. " carries player gauges").image,
      versionId .. " player gauge source"
    )
    local foeGaugeStrip = decodeData(
      scope,
      cacheFs,
      assert(stagedManifest.hud.partyGauges[1], versionId .. " carries foe gauges").image,
      versionId .. " foe gauge source"
    )
    local leadMatches, leadOccupied =
      countGaugeMatches(first, playerGaugeStrip, interactionFrame.x + 12 - 16, interactionFrame.y + 13 - 16, 16, 4)
    Assert.isTrue(leadOccupied > 50, versionId .. " stages an occupied lead gauge cell")
    Assert.isTrue(leadMatches / leadOccupied > 0.9, versionId .. " draws the lead gauge from its source cell")
    local foeMatches, foeOccupied =
      countGaugeMatches(first, foeGaugeStrip, interactionFrame.x + 246 - 8, interactionFrame.y + 9 - 8, 4, 2)
    Assert.isTrue(foeOccupied > 50, versionId .. " stages an occupied foe gauge cell")
    Assert.isTrue(foeMatches / foeOccupied < 0.5, versionId .. " draws no opponent gauge in a wild battle")
  end
end

-- The native Fight view prints its move facts over the staged move
-- artwork: named slots carry label, type, and PP ink, the Back strip
-- carries its label, and the empty slots stay exactly as staged.
function T.native_fight_view_prints_real_move_text(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the battle captures need a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local screen = captureScreen(scope, cacheFs, versionId, dualMeasurement())
    driveToCommand(screen, versionId)
    screen:input({ { type = "confirm" } })
    screen:updateFixed(TICK)
    Assert.equal(screen:status().mode, "moves", versionId .. " opens the native move view")
    local plan = livePlan(screen, versionId)
    local width, height = canvasSize(plan, versionId)
    local interactionFrame = nil
    for _, pane in ipairs(plan.panes) do
      if pane.id == "interaction" then
        interactionFrame = pane.placement.frame
      end
    end
    Assert.notNil(interactionFrame, versionId .. " places its interaction pane")

    local first = renderCapture(scope, screen, width, height)
    local second = renderCapture(scope, screen, width, height)
    Assert.equal(
      imageDataDigest(first),
      imageDataDigest(second),
      versionId .. " renders the native Fight view deterministically"
    )
    saveCapture(first, versionId .. "-native-fight")

    local menuSource = decodeData(
      scope,
      cacheFs,
      assert(BattlePresentationCache.load(cacheFs).menus.moves, versionId .. " carries move art").image,
      versionId .. " move source"
    )
    local function sourceDiffs(localBox, source, origin)
      source = source or menuSource
      origin = origin or { x = 0, y = 0 }
      local changed = 0
      local box = {
        x = interactionFrame.x + localBox.x,
        y = interactionFrame.y + localBox.y,
        width = localBox.width,
        height = localBox.height,
      }
      for y = box.y, box.y + box.height - 1 do
        for x = box.x, box.x + box.width - 1 do
          local sx, sy = x - interactionFrame.x - origin.x, y - interactionFrame.y - origin.y
          if sx >= 0 and sy >= 0 and sx < source:getWidth() and sy < source:getHeight() then
            local r1, g1, b1, a1 = first:getPixel(x, y)
            local r2, g2, b2, a2 = source:getPixel(sx, sy)
            if
              quantize(r1) ~= quantize(r2)
              or quantize(g1) ~= quantize(g2)
              or quantize(b1) ~= quantize(b2)
              or quantize(a1) ~= quantize(a2)
            then
              changed = changed + 1
            end
          end
        end
      end
      return changed
    end
    Assert.isTrue(
      sourceDiffs({ x = 24, y = 39, width = 80, height = 14 }) > 10,
      versionId .. " prints its first move label"
    )
    Assert.isTrue(
      sourceDiffs({ x = 152, y = 38, width = 80, height = 14 }) > 10,
      versionId .. " prints its second move label"
    )
    -- Unlearned slots show their staged blank button, unlabeled.
    local moveButtons = BattlePresentationCache.load(cacheFs).menus.moves.screens[1].moveButtons
    for slot, box in pairs({
      [3] = { x = 24, y = 102, width = 80, height = 14 },
      [4] = { x = 152, y = 101, width = 80, height = 14 },
    }) do
      local button = moveButtons[slot]
      local blank = decodeData(scope, cacheFs, button.empty, versionId .. " empty move button")
      Assert.equal(
        sourceDiffs(box, blank, button),
        0,
        versionId .. " shows the staged blank button in empty move slot " .. slot
      )
    end
    Assert.isTrue(sourceDiffs({ x = 100, y = 169, width = 56, height = 12 }) > 5, versionId .. " prints its Back label")
  end
end

-- The opening packet with a reserve switch choice and its party snapshot
-- so the party child finds its eligible reserve through the real options.
---@return table delivery packet opening the staged battle with a switch
local function partyPacket()
  local packet = openingPacket()
  local actor = assert(packet.request.options.actors[1], "the staged request carries its actor")
  -- Voluntary switches address the acting lead by stable combatant
  -- identity, exactly like the runtime projection the kernel reads:
  -- without it the party picker finds no eligible reserve.
  actor.combatant = 0
  actor.choices[#actor.choices + 1] = {
    role = "switch",
    enabled = true,
    choice = { kind = "switch", payload = { replacement = 1 } },
  }
  packet.party = {
    { slot = 0, combatant = 0, name = LEAD_SPECIES, level = 9, hp = 30, maxHp = 30 },
    { slot = 1, combatant = 1, name = LEAD_SPECIES, level = 9, hp = 28, maxHp = 28 },
  }
  return packet
end

---@param screen table live battle screen under driving
---@param ticks integer fixed updates under driving
local function pump(screen, ticks)
  for _ = 1, ticks do
    screen:updateFixed(TICK)
  end
end

---@param cells table command cells under tapping
---@param id string tapped command identity
---@return table center of the tapped cell
local function cellCenter(cells, id)
  for _, cell in ipairs(cells) do
    if cell.id == id then
      return { x = cell.x + math.floor(cell.width / 2), y = cell.y + math.floor(cell.height / 2) }
    end
  end
  error("the command grid carries " .. id, 0)
end

---@param screen table live battle screen under tapping
---@param versionId string ready game version under tapping
---@param point table tapped logical position
local function tap(screen, versionId, point)
  waitForMenuInput(screen, versionId)
  screen:input({ { type = "pointer_down", pointerId = "touch:0", x = point.x, y = point.y } })
  screen:input({ { type = "pointer_up", pointerId = "touch:0", x = point.x, y = point.y } })
end

-- A cancelled Item child hands the same command decision back: the bag
-- opens over the compact command request and its cancellation restores
-- the parent command with the same request, rendering pixel-identical to
-- the pre-child command with prompt, label, bar, and composite ink. The
-- returned view is kept as a PNG.
function T.compact_child_return_restores_the_parent_command(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the battle captures need a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local screen = captureScreen(scope, cacheFs, versionId, compactMeasurement())
    driveToCommand(screen, versionId)
    local requestId = assert(screen:status().request, versionId .. " mirrors its request").requestId
    local plan = livePlan(screen, versionId)
    local width, height = canvasSize(plan, versionId)
    local frame = assert(plan.panes[1].placement.frame, versionId .. " frames its compact pane")
    renderCapture(scope, screen, width, height)

    local cells = assert(plan.content.commands.cells, versionId .. " carries its command cells")
    -- The first press only focuses the unselected cell (the focus turns
    -- the input identity and releases the session capture); the second
    -- press seals through the shared press convention.
    tap(screen, versionId, cellCenter(cells, "bag"))
    pump(screen, 2)
    tap(screen, versionId, cellCenter(cells, "bag"))
    pump(screen, 5)
    Assert.equal(screen:status().mode, "child", versionId .. " opens the bag over its command")
    Assert.equal(screen:view().childIntent.kind, "bag", versionId .. " carries the bag intent")
    screen:input({ { type = "cancel" } })
    pump(screen, 5)
    Assert.equal(screen:status().mode, "command", versionId .. " returns to the same decision")
    Assert.equal(
      screen:status().request.requestId,
      requestId,
      versionId .. " keeps the parent request across the child return"
    )
    Assert.isNil(screen:view().childIntent, versionId .. " closes the bag intent")
    waitForMenuInput(screen, versionId)
    screen:input({ { type = "navigate", direction = "up" } })
    pump(screen, 2)
    Assert.equal(screen:view().selection, "fight", versionId .. " walks back to the first command")

    local returnedPlan = livePlan(screen, versionId)
    local returned = renderCapture(scope, screen, width, height)
    local rerun = renderCapture(scope, screen, width, height)
    Assert.equal(screen:view().selection, "fight", versionId .. " restores the parent's focused command")
    Assert.equal(
      imageDataDigest(returned),
      imageDataDigest(rerun),
      versionId .. " renders the returned command deterministically"
    )
    saveCapture(returned, versionId .. "-compact-child-return")
    local content = assert(returnedPlan.content, versionId .. " carries its returned content")
    Assert.isTrue(
      countInk(returned, hostRect(frame, content.prompt.content)) > 100,
      versionId .. " restores its prompt text ink"
    )
    for _, cell in ipairs(assert(content.commands.cells, versionId .. " carries its returned cells")) do
      Assert.isTrue(
        countInk(returned, hostRect(frame, cell)) > 30,
        versionId .. " restores the " .. tostring(cell.id) .. " command label"
      )
    end
    local hud = assert(content.hud, versionId .. " carries its returned HUD")
    for _, side in ipairs({ { box = hud.enemy, label = "enemy" }, { box = hud.player, label = "player" } }) do
      local bar = assert(side.box.bar, versionId .. " carries its bar")
      Assert.isTrue((bar.fraction or 0) > 0, versionId .. " refills the " .. side.label .. " health bar")
      Assert.isTrue(
        countBarGreen(returned, hostRect(frame, side.box)) > 10,
        versionId .. " restores the " .. side.label .. " health bar"
      )
    end
  end
end

-- A cancelled Party child hands the same command decision back: the party
-- opens through its eligible reserve switch and its cancellation
-- restores the parent command with the same request, rendering
-- pixel-identical to the pre-child command.
function T.compact_party_return_restores_the_parent_command(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the battle captures need a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local screen = captureScreen(scope, cacheFs, versionId, compactMeasurement())
    drivePacketToCommand(screen, versionId, partyPacket())
    local requestId = assert(screen:status().request, versionId .. " mirrors its request").requestId
    local plan = livePlan(screen, versionId)
    local width, height = canvasSize(plan, versionId)
    local frame = assert(plan.panes[1].placement.frame, versionId .. " frames its compact pane")
    renderCapture(scope, screen, width, height)

    local cells = assert(plan.content.commands.cells, versionId .. " carries its command cells")
    tap(screen, versionId, cellCenter(cells, "pokemon"))
    pump(screen, 2)
    tap(screen, versionId, cellCenter(cells, "pokemon"))
    pump(screen, 5)
    Assert.equal(screen:status().mode, "child", versionId .. " opens the party over its command")
    Assert.equal(screen:view().childIntent.kind, "party", versionId .. " carries the party intent")
    screen:input({ { type = "cancel" } })
    pump(screen, 5)
    Assert.equal(screen:status().mode, "command", versionId .. " returns to the same decision")
    Assert.equal(
      screen:status().request.requestId,
      requestId,
      versionId .. " keeps the parent request across the party return"
    )
    Assert.isNil(screen:view().childIntent, versionId .. " closes the party intent")
    waitForMenuInput(screen, versionId)
    screen:input({ { type = "navigate", direction = "up" } })
    pump(screen, 2)
    Assert.equal(screen:view().selection, "fight", versionId .. " walks back to the first command")

    local returnedPlan = livePlan(screen, versionId)
    local returned = renderCapture(scope, screen, width, height)
    Assert.equal(screen:view().selection, "fight", versionId .. " restores the parent's focused command")
    local content = assert(returnedPlan.content, versionId .. " carries its returned content")
    Assert.isTrue(
      countInk(returned, hostRect(frame, content.prompt.content)) > 100,
      versionId .. " restores its prompt text ink"
    )
    Assert.isTrue(
      countBarGreen(returned, hostRect(frame, content.hud.player)) > 10,
      versionId .. " restores the player health bar"
    )
  end
end

-- The settled win shows its result word on the compact narration dock:
-- the terminal delivery drains every cue, exposes no further request,
-- and the settled outcome view carries narration ink over the composed
-- scene with the final health bars. Kept as a PNG.
function T.compact_settled_return_shows_the_result_word(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the battle captures need a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local screen = captureScreen(scope, cacheFs, versionId, compactMeasurement())
    driveToCommand(screen, versionId)
    local port = screen:presentationPort()
    port.present({
      launchId = "battle-capture",
      packetId = 2,
      -- Production deliveries always carry the preceding view; the
      -- opening packet above is the exception the screen tolerates.
      before = openingPacket().after,
      after = {
        own = {
          {
            combatant = 0,
            side = 1,
            species = LEAD_SPECIES,
            form = 0,
            selector = "back",
            name = LEAD_SPECIES,
            level = 9,
            hp = 30,
            maxHp = 30,
            experience = 210,
          },
        },
        foes = {
          {
            combatant = 2,
            side = 2,
            species = FOE_SPECIES,
            form = 0,
            selector = "front",
            name = FOE_SPECIES,
            level = 3,
            hp = 0,
            maxHp = 12,
          },
        },
      },
      events = {
        { kind = "fainted", sequence = 1, payload = { combatant = 2 } },
      },
      result = { word = "win" },
    })
    local ticks = 0
    while (screen:status().mode ~= "outcome" or not screen:status().ready) and ticks < DRIVE_BUDGET do
      -- The terminal result holds its final page until a genuine
      -- acknowledgment, so the capture advances it exactly as a player
      -- would instead of expecting it to settle on its own.
      local mode = screen:status().mode
      if mode == "intro" or mode == "narration" or mode == "outcome" then
        screen:input({ { type = "confirm" } })
      end
      screen:updateFixed(TICK)
      ticks = ticks + 1
    end
    Assert.equal(screen:status().mode, "outcome", versionId .. " settles on its outcome")
    Assert.isTrue(screen:status().ready, versionId .. " drains every cue behind the outcome")
    Assert.isNil(screen:status().request, versionId .. " exposes no further request")
    Assert.isTrue(
      tostring(screen:view().message):find(FOE_SPECIES, 1, true) ~= nil,
      versionId .. " names the defeated foe in its result wording"
    )
    local plan = livePlan(screen, versionId)
    local width, height = canvasSize(plan, versionId)
    local frame = assert(plan.panes[1].placement.frame, versionId .. " frames its compact pane")
    local content = assert(plan.content, versionId .. " carries its settled content")

    local first = renderCapture(scope, screen, width, height)
    local second = renderCapture(scope, screen, width, height)
    Assert.equal(
      imageDataDigest(first),
      imageDataDigest(second),
      versionId .. " renders the settled outcome deterministically"
    )
    saveCapture(first, versionId .. "-compact-settled-return")

    local sceneBox = hostRect(frame, content.scene)
    Assert.isTrue(countInk(first, sceneBox) > 20000, versionId .. " keeps the settled scene composed")
    local narration = assert(content.narration, versionId .. " carries its settled narration")
    Assert.isTrue(
      countInk(first, hostRect(frame, narration.content)) > 30,
      versionId .. " prints its result wording ink"
    )
    Assert.isTrue(
      countBarGreen(first, hostRect(frame, content.hud.player)) > 10,
      versionId .. " keeps the winner health bar"
    )
  end
end

-- Every drawable key the battle renderers reach for resolves to its staged
-- source image through the capture services: the scene, both HUD
-- composites, the three menu surfaces, and both mon-side portraits with
-- the manifest's own dimensions. Per-control menu artwork has no staged
-- counterpart and resolves to nothing, so those controls draw labels
-- only, never substitutes.
function T.drawable_keys_resolve_to_their_staged_source_images(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the battle captures need a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local manifest = BattlePresentationCache.load(cacheFs)
    local services = captureServices(scope, cacheFs, versionId)
    for _, entry in ipairs({
      { key = "scene:" .. SCENE_KEY, path = BattlePresentationCache.sceneImagePath(SCENE_KEY) },
      { key = "hud:enemy", path = assert(manifest.hud.enemy, versionId .. " carries enemy HUD").image },
      { key = "hud:player", path = assert(manifest.hud.player, versionId .. " carries player HUD").image },
      { key = "menu:command", path = assert(manifest.menus.command, versionId .. " carries command art").image },
      { key = "menu:moves", path = assert(manifest.menus.moves, versionId .. " carries move art").image },
      { key = "menu:target", path = assert(manifest.menus.target, versionId .. " carries target art").image },
      { key = "arrow", path = assert(manifest.hud.arrow, versionId .. " carries the arrow").image },
      {
        key = "gauges:player",
        path = assert(manifest.hud.partyGauges[2], versionId .. " carries player gauges").image,
      },
      { key = "gauges:enemy", path = assert(manifest.hud.partyGauges[1], versionId .. " carries enemy gauges").image },
    }) do
      local source = decodeData(scope, cacheFs, entry.path, versionId .. " " .. entry.key .. " source")
      local lease = assert(services.drawable(entry.key), versionId .. " resolves " .. entry.key)
      local image = assert(lease.image, versionId .. " carries the staged image for " .. entry.key)
      Assert.equal(image:getWidth(), source:getWidth(), versionId .. " sizes " .. entry.key .. " from source")
      Assert.equal(image:getHeight(), source:getHeight(), versionId .. " heights " .. entry.key .. " from source")
    end
    for _, entry in ipairs({
      {
        key = "mon:" .. MonCache.portraitSelector(FOE_SPECIES, 0, "male", false),
        selector = MonCache.portraitSelector(FOE_SPECIES, 0, "male", false),
      },
      {
        key = "mon:" .. MonCache.portraitSelector(LEAD_SPECIES, 0, "male", false, "back"),
        selector = MonCache.portraitSelector(LEAD_SPECIES, 0, "male", false, "back"),
      },
    }) do
      local portraits =
        assert(cacheFs:loadLua(MonCache.portraitManifestPath()), versionId .. " carries its portrait manifest")
      local cell = assert(portraits.entries[entry.selector], versionId .. " plans " .. entry.selector)
      -- Portrait drawables pair the staged crop image with its cell
      -- quad, so the test crop resolves to the staged cell through
      -- the same image-plus-quad shape production draws.
      local handle = assert(services.drawable(entry.key), versionId .. " resolves " .. entry.key)
      local lease = assert(handle.lease, versionId .. " carries the staged cell lease for " .. entry.key)
      local image = assert(lease.image, versionId .. " carries the staged cell image for " .. entry.key)
      local quad = assert(handle.quad, versionId .. " carries the staged cell quad for " .. entry.key)
      Assert.equal(image:getWidth(), cell.width, versionId .. " sizes " .. entry.key .. " from its staged cell")
      Assert.equal(image:getHeight(), cell.height, versionId .. " heights " .. entry.key .. " from its staged cell")
      local qx, qy, qw, qh = quad:getViewport()
      Assert.equal(qx, 0, versionId .. " frames " .. entry.key .. " at its crop origin")
      Assert.equal(qy, 0, versionId .. " frames " .. entry.key .. " at its crop origin")
      Assert.equal(qw, cell.width, versionId .. " frames " .. entry.key .. " at its staged width")
      Assert.equal(qh, cell.height, versionId .. " frames " .. entry.key .. " at its staged height")
    end
    Assert.isNil(services.drawable("menu:command:fight"), versionId .. " leaves per-control art unmapped")
    Assert.isNil(services.drawable("menu:moves:move:0"), versionId .. " leaves per-slot art unmapped")
  end
end

-- The compact opening draws the live lead's exact portrait: with a
-- fainted first slot and the active lead in slot one carrying the
-- female back selector, the demands name that exact canonical
-- selector, the send-out hails the live lead, and the lead picture
-- matches the staged female cell better than the staged male cell.
-- The lead is Heracross because its staged male and female back cells
-- actually differ (soulsilver portrait page 86); a species with
-- identical gender cells cannot discriminate the drawn selector.
function T.compact_active_lead_draws_its_exact_canonical_portrait(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the battle captures need a ready user-owned ROM with a derived cache")
  end
  local leadSpecies = "HERACROSS"
  local maleBack = MonCache.portraitSelector(leadSpecies, 0, "male", false, "back")
  local femaleBack = MonCache.portraitSelector(leadSpecies, 0, "female", false, "back")
  local foeSelector = MonCache.portraitSelector(FOE_SPECIES, 0, "male", false)
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local portraits =
      assert(cacheFs:loadLua(MonCache.portraitManifestPath()), versionId .. " carries its portrait manifest")
    local femaleEntry =
      assert(portraits.entries[femaleBack], versionId .. " plans the live lead selector " .. femaleBack)
    local femaleOk, stagedFemaleImage, femaleCell =
      pcall(cropPortrait, scope, cacheFs, femaleBack, assert(femaleEntry.pageId, versionId .. " pages its live lead"))
    if not femaleOk then
      context:skip(versionId .. " stages no occupied female back cell for " .. femaleBack)
    end
    local screen, images, _, services = captureScreen(scope, cacheFs, versionId, compactMeasurement())
    -- The shared harness stages the pinned lead/foe drawables; this
    -- scenario's dimorphic lead stages its own exact keys beside them.
    local maleEntry = assert(portraits.entries[maleBack], versionId .. " plans the benched selector " .. maleBack)
    local maleImage, maleCell =
      cropPortrait(scope, cacheFs, maleBack, assert(maleEntry.pageId, versionId .. " pages its benched lead"))
    images["mon:" .. maleBack] = cellHandle(maleImage)
    images["mon:" .. femaleBack] = cellHandle(stagedFemaleImage)
    local packet = openingPacket()
    -- The acting entry is the living reserve combatant 1 here, so the
    -- request and options address it exactly like the runtime would.
    packet.request.actors = { { kind = "command", combatant = 1 } }
    packet.request.options.actors[1].combatant = 1
    packet.after.own = {
      {
        combatant = 0,
        side = 1,
        species = leadSpecies,
        form = 0,
        selector = "back",
        portraitSelector = maleBack,
        name = "BENCH",
        level = 9,
        hp = 0,
        maxHp = 30,
        experience = 120,
        active = false,
      },
      {
        combatant = 1,
        side = 1,
        species = leadSpecies,
        form = 0,
        selector = "back",
        portraitSelector = femaleBack,
        name = "LIVE",
        level = 9,
        hp = 28,
        maxHp = 28,
        experience = 100,
        active = true,
      },
    }
    packet.after.foes[1].portraitSelector = foeSelector
    local port = screen:presentationPort()
    for _ = 1, 5 do
      screen:updateFixed(TICK)
    end
    Assert.isTrue(port.enter({ launchId = "battle-capture", kind = "wild" }), versionId .. " enters its staged scene")
    port.present(packet)
    local seen, ticks = {}, 0
    while screen:status().request == nil and ticks < DRIVE_BUDGET do
      screen:updateFixed(TICK)
      seen[#seen + 1] = tostring(screen:view().message or "")
      ticks = ticks + 1
    end
    Assert.notNil(screen:status().request, versionId .. " exposes its command request")
    local demanded = {}
    for _, demand in ipairs(services.prepared) do
      for _, page in ipairs(demand.pages or {}) do
        demanded[#demanded + 1] = page
      end
    end
    local function demandedHas(want)
      for _, page in ipairs(demanded) do
        if page == want then
          return true
        end
      end
      return false
    end
    Assert.isTrue(demandedHas(femaleBack), versionId .. " demands the live lead exact selector")
    Assert.isTrue(demandedHas(foeSelector), versionId .. " demands the revealed foe exact selector")
    for _, page in ipairs(demanded) do
      Assert.isTrue(
        tostring(page):match("^[^/]+/%d+/[a-z]+$") == nil,
        versionId .. " demands no shorthand key: " .. tostring(page)
      )
    end
    local hailedLive = false
    for _, message in ipairs(seen) do
      if message:find("LIVE", 1, true) ~= nil then
        hailedLive = true
      end
      Assert.isTrue(message:find("BENCH", 1, true) == nil, versionId .. " never hails the fainted first slot")
    end
    Assert.isTrue(hailedLive, versionId .. " hails the live lead by name")
    local plan = livePlan(screen, versionId)
    local width, height = canvasSize(plan, versionId)
    local frame = assert(plan.panes[1].placement.frame, versionId .. " frames its compact pane")
    local content = assert(plan.content, versionId .. " carries its compact content")
    local first = renderCapture(scope, screen, width, height)
    local second = renderCapture(scope, screen, width, height)
    Assert.equal(
      imageDataDigest(first),
      imageDataDigest(second),
      versionId .. " renders the live-lead opening deterministically"
    )
    saveCapture(first, versionId .. "-compact-active-lead")
    -- Lead pictures draw top-left at the plan image center: the live
    -- female cell must explain the lead rect better than the staged
    -- male cell the legacy side key still resolves.
    local origin = content.playerCenter
    local rect = { x = frame.x + origin.x, y = frame.y + origin.y, width = 80, height = 40 }
    local femaleMatches, femaleOccupied = countSourceMatches(first, femaleCell, rect, rect.x, rect.y)
    local maleMatches, maleOccupied = countSourceMatches(first, maleCell, rect, rect.x, rect.y)
    Assert.isTrue(femaleOccupied > 20, versionId .. " stages an occupied live-lead cell")
    Assert.isTrue(maleOccupied > 20, versionId .. " stages an occupied benched cell")
    Assert.isTrue(femaleMatches / femaleOccupied > 0.5, versionId .. " draws the live lead portrait over the scene")
    Assert.isTrue(
      femaleMatches > maleMatches,
      versionId .. " draws the live lead selector instead of the first-slot male portrait"
    )
  end
end

-- An indexed portrait page resolves through its staged palette in the
-- picture pass: the shared page texture plus its palette image renders
-- the palette colors, never the raw index bytes. A non-zero frame
-- origin crops the same page window the pooled renderer submits, so
-- shared page uploads never crop on the game thread. Fully synthetic,
-- so it needs no user-owned dump.
function T.indexed_portrait_page_resolves_through_its_staged_palette(scope, _)
  local BattlePicturePass = require("libs.hgss.src.presentation.BattlePicturePass")
  local indexBytes = string.char(0, 0, 1, 1, 1, 1, 0, 0)
  local pageData = love.image.newImageData(4, 2, "r8", indexBytes)
  local pageImage = scope:own(love.graphics.newImage(pageData))
  local paletteBytes = string.char(255, 0, 0, 255, 0, 0, 255, 255)
  local paletteData = love.image.newImageData(2, 1, "rgba8", paletteBytes)
  local paletteImage = scope:own(love.graphics.newImage(paletteData))
  paletteImage:setFilter("nearest", "nearest")
  local pass = BattlePicturePass.new(love.graphics)
  local layer = pass:render(love.graphics, {
    {
      image = pageImage,
      imageKind = "r8",
      palette = paletteImage,
      centerX = 128,
      centerY = 96,
      zCenter = 0,
      pictureVisible = true,
      width = 4,
      height = 2,
      tintR = 1,
      tintG = 1,
      tintB = 1,
      alpha = 1,
      xOffset = 0,
      yOffset = 0,
      xOffset2 = 0,
      yOffset2 = 0,
      frameX = 0,
      frameY = 0,
      frameW = 4,
      frameH = 2,
    },
  })
  local data = scope:own(layer:newImageData())
  -- The pooled renderer submits a non-zero frame origin with its cell
  -- size: the same page cropped to columns 1-2 renders only those
  -- palette texels at the same destination origin.
  local cropLayer = pass:render(love.graphics, {
    {
      image = pageImage,
      imageKind = "r8",
      palette = paletteImage,
      centerX = 128,
      centerY = 96,
      zCenter = 0,
      pictureVisible = true,
      width = 2,
      height = 2,
      tintR = 1,
      tintG = 1,
      tintB = 1,
      alpha = 1,
      xOffset = 0,
      yOffset = 0,
      xOffset2 = 0,
      yOffset2 = 0,
      frameX = 1,
      frameY = 0,
      frameW = 2,
      frameH = 2,
    },
  })
  local cropData = scope:own(cropLayer:newImageData())
  pass:release()
  local expected = {
    { 255, 0, 0 },
    { 255, 0, 0 },
    { 0, 0, 255 },
    { 0, 0, 255 },
    { 0, 0, 255 },
    { 0, 0, 255 },
    { 255, 0, 0 },
    { 255, 0, 0 },
  }
  local slot = 0
  for y = 0, 1 do
    for x = 0, 3 do
      slot = slot + 1
      local red, green, blue, alpha = data:getPixel(88 + x, 56 + y)
      local want = expected[slot]
      Assert.equal(quantize(red), want[1], "the indexed page resolves its palette red at " .. x .. "," .. y)
      Assert.equal(quantize(green), want[2], "the indexed page resolves its palette green at " .. x .. "," .. y)
      Assert.equal(quantize(blue), want[3], "the indexed page resolves its palette blue at " .. x .. "," .. y)
      Assert.equal(quantize(alpha), 255, "the indexed page stays opaque at " .. x .. "," .. y)
    end
  end
  local cropExpected = {
    { 255, 0, 0 },
    { 0, 0, 255 },
    { 0, 0, 255 },
    { 255, 0, 0 },
  }
  local cropSlot = 0
  for y = 0, 1 do
    for x = 0, 1 do
      cropSlot = cropSlot + 1
      local red, green, blue, alpha = cropData:getPixel(88 + x, 56 + y)
      local want = cropExpected[cropSlot]
      Assert.equal(quantize(red), want[1], "the frame window crops its palette red at " .. x .. "," .. y)
      Assert.equal(quantize(green), want[2], "the frame window crops its palette green at " .. x .. "," .. y)
      Assert.equal(quantize(blue), want[3], "the frame window crops its palette blue at " .. x .. "," .. y)
      Assert.equal(quantize(alpha), 255, "the frame window stays opaque at " .. x .. "," .. y)
    end
  end
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump" }
suite.metadata.derivedAssets = {
  "battle-presentation:global",
  "battle-scene:general/grass/day",
  "field-font:global",
  "field-ui:global",
  "move-icons:global",
  "mon-icon-page:4",
  "mon-portrait-page:0",
  "mon-portrait-page:34",
  "mon-portrait-page:86",
  "mon-portrait-page:164",
}
return suite
