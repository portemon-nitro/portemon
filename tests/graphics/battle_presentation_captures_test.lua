-- Real staged-asset captures for the battle presentation: production
-- composition draws the staged scene, menu, HUD, portraits, font, and frame
-- assets into offscreen canvases. Source-pixel checks cover native sprites,
-- frame tiles, font color classes, and menu planes; regional censuses cover
-- the remaining dynamic fields. Repeated draws must remain identical.

local Assert = require("tests.support.Assert")
local BagCache = require("libs.assets.src.BagCache")
local StubLease = require("tests.support.StubLease")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local BattlePresentationSchema = require("libs.assets.src.battle.BattlePresentationSchema")
local BattlePresentationModel = require("game.hgss.src.battle.BattlePresentationModel")
local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
local BattleScreenState = require("game.hgss.src.battle.BattleScreenState")
local BattleMenuPresenter = require("game.hgss.src.battle.BattleMenuPresenter")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldWindowRenderer = require("libs.hgss.src.ui.FieldWindowRenderer")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
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
local DRIVE_BUDGET = 1200
local NATIVE_DOUBLES_HUD_ORIGINS = {
  playerLeft = { x = 192, y = 103 },
  playerRight = { x = 198, y = 132 },
  enemyLeft = { x = 64, y = 16 },
  enemyRight = { x = 58, y = 45 },
}
local NATIVE_DOUBLES_TEXT_REGIONS = {
  playerLeft = { { x = 144, y = 88, width = 72, height = 16 }, { x = 224, y = 91, width = 32, height = 16 } },
  playerRight = { { x = 150, y = 117, width = 72, height = 16 }, { x = 230, y = 120, width = 32, height = 16 } },
  enemyLeft = { { x = 14, y = 4, width = 72, height = 16 }, { x = 88, y = 4, width = 32, height = 16 } },
  enemyRight = { { x = 8, y = 33, width = 72, height = 16 }, { x = 82, y = 33, width = 32, height = 16 } },
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

local function assertStagedManifest(manifest, context)
  Assert.equal(
    manifest.schema,
    BattlePresentationSchema.MANIFEST_SCHEMA,
    context .. " stages the current catalog schema"
  )
  Assert.isTrue(
    type(manifest.battlefield.slots) == "table" and #manifest.battlefield.slots == 6,
    context .. " stages all source side-type geometry"
  )
  Assert.isTrue(
    type(manifest.hud.patchSpans.playerDoubleMode) == "table" and #manifest.hud.patchSpans.playerDoubleMode == 2,
    context .. " stages both native double-player health-box modes"
  )
  Assert.isTrue(
    type(manifest.pictures.selectors) == "table" and next(manifest.pictures.selectors) ~= nil,
    context .. " stages source picture selectors"
  )
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

local function firstPixelDifferences(left, right)
  local differences = {}
  for y = 0, left:getHeight() - 1 do
    for x = 0, left:getWidth() - 1 do
      local l = { left:getPixel(x, y) }
      local r = { right:getPixel(x, y) }
      if l[1] ~= r[1] or l[2] ~= r[2] or l[3] ~= r[3] or l[4] ~= r[4] then
        differences[#differences + 1] = tostring(x)
          .. ","
          .. tostring(y)
          .. ":"
          .. tostring(quantize(l[1]))
          .. "/"
          .. tostring(quantize(l[2]))
          .. "/"
          .. tostring(quantize(l[3]))
          .. "/"
          .. tostring(quantize(l[4]))
          .. " vs "
          .. tostring(quantize(r[1]))
          .. "/"
          .. tostring(quantize(r[2]))
          .. "/"
          .. tostring(quantize(r[3]))
          .. "/"
          .. tostring(quantize(r[4]))
        if #differences == 4 then
          return table.concat(differences, "; ")
        end
      end
    end
  end
  return table.concat(differences, "; ")
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
  if species == nil then
    -- Exact canonical selectors validate their single staged entry and
    -- page: no expansion, no guessed variant.
    local entry = assert(entries[pageKey], "the staged manifest plans " .. pageKey)
    Assert.isTrue(
      MonCache.isPageReady(
        cacheFs,
        "portraits",
        entry.pageId,
        cacheFs:read(MonCache.pageMarkerPath("portraits", entry.pageId))
      ),
      "portrait page " .. tostring(entry.pageId) .. " is staged for " .. pageKey
    )
    return
  end
  Assert.notNil(form, "portrait demands name their form: " .. pageKey)
  Assert.isTrue(facing == "front" or facing == "back", "portrait demands name their facing: " .. pageKey)
  local portraits =
    assert(cacheFs:loadLua(MonCache.portraitManifestPath()), "the staged cache carries its portrait manifest")
  local entries = assert(portraits.entries, "the staged portrait manifest carries entries")
  for _, gender in ipairs({ "male", "female" }) do
    for _, finish in ipairs({ "plain", "shiny" }) do
      local selector = MonCache.portraitSelector(species, tonumber(form), gender, finish == "shiny", facing)
      local entry = assert(entries[selector], "the staged manifest plans " .. selector)
      Assert.isTrue(
        MonCache.isPageReady(
          cacheFs,
          "portraits",
          entry.pageId,
          cacheFs:read(MonCache.pageMarkerPath("portraits", entry.pageId))
        ),
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
  assertStagedManifest(manifest, versionId)
  local images = {}
  images["scene:" .. SCENE_KEY] =
    stagedImage(scope, cacheFs, BattlePresentationCache.sceneImagePath(SCENE_KEY), versionId .. " battle scene")
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
  images["menu:two-option"] = stagedImage(
    scope,
    cacheFs,
    assert(manifest.menus.twoOption, versionId .. " carries two-option art").image,
    versionId .. " two-option art"
  )
  for layout, manifestKey in pairs({
    command = "command",
    moves = "moves",
    target = "target",
    ["two-option"] = "twoOption",
  }) do
    local section = assert(manifest.menus[manifestKey], versionId .. " carries " .. layout .. " menu layers")
    for index, screen in ipairs(assert(section.screens, versionId .. " carries " .. layout .. " screen layers")) do
      images["menu:" .. layout .. ":screen:" .. tostring(index)] =
        stagedImage(scope, cacheFs, screen.image, versionId .. " " .. layout .. " screen " .. tostring(index))
      for controlId, states in pairs(screen.feedback or {}) do
        for state, patch in pairs(states) do
          local key = "menu:" .. layout .. ":feedback:" .. controlId .. ":" .. state
          images[key] = stagedImage(scope, cacheFs, patch.image, versionId .. " " .. key)
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
  local enemyGauges = assert(manifest.hud.partyGauges[1], versionId .. " carries enemy gauges")
  local playerGauges = assert(manifest.hud.partyGauges[2], versionId .. " carries player gauges")
  images["gauges:player"] = stagedImage(scope, cacheFs, playerGauges.image, versionId .. " player gauges")
  images["gauges:enemy"] = stagedImage(scope, cacheFs, enemyGauges.image, versionId .. " enemy gauges")
  images.shadow = stagedImage(scope, cacheFs, manifest.pictures.shadow.image, versionId .. " Pokepic shadow")
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
  local bagManifest = nil
  local moveIcons = nil
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
      local bytes =
        assert(cacheFs:read(BattlePresentationCache.sceneImagePath(sceneKey)), versionId .. " stages its scene image")
      Assert.equal(
        #bytes,
        PngWriter.encodedSize(record.canvasWidth, record.canvasHeight),
        versionId .. " stages the complete scene image"
      )
    end
    for _, page in ipairs(demand.pages or {}) do
      requirePortraitKey(cacheFs, page)
    end
    return true
  end
  function services.drawable(key)
    assert(type(key) == "string" and key ~= "", "image resolution names its key")
    local image = images[key]
    if image ~= nil then
      return image
    end
    local typeKey = key:match("^battle:move%-type%-icon:([a-z%-]+)$")
    if typeKey == nil then
      return nil
    end
    moveIcons = moveIcons or MoveIconCache.loadManifest(cacheFs)
    local visual = assert(moveIcons.types, versionId .. " carries move type icons")[typeKey]
    if visual == nil then
      return nil
    end
    image = stagedImage(scope, cacheFs, visual.image, versionId .. " " .. typeKey .. " move type icon")
    images[key] = image
    return image
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
  local roleRenderers = {
    narration = scope:own(FieldTextRenderer.new({ cacheFs = cacheFs, fontId = 1 })),
    menu = scope:own(FieldTextRenderer.new({ cacheFs = cacheFs, fontId = 4 })),
  }
  local windowRenderer = scope:own(FieldWindowRenderer.new({ cacheFs = cacheFs, manifest = uiManifest }))
  local frames = assert(uiManifest.dialogueFrames, versionId .. " carries dialogue frames")
  Assert.notNil(frames.frameTiles[0], versionId .. " carries the default frame strip")
  local text = { fontDef = textRenderer.fontDef }
  function text.drawText(content, x, y)
    return textRenderer:drawText(content, x, y)
  end
  function text.drawTextForRole(role, content, x, y, colors)
    local renderer = assert(roleRenderers[role], "capture has the generated source text role")
    if colors == nil then
      return renderer:drawText(content, x, y)
    end
    local fontPalette = assert(renderer.fontDef.palette, "colored capture text uses its source font palette")
    local function colorAt(slot)
      local source = assert(fontPalette[slot + 1], "source font palette contains the requested slot")
      return {
        r = assert(tonumber(source.r or source[1])),
        g = assert(tonumber(source.g or source[2])),
        b = assert(tonumber(source.b or source[3])),
      }
    end
    return renderer:drawTextWithPalette(content, x, y, {
      foreground = colorAt(colors.foreground),
      shadow = colorAt(colors.shadow),
      background = colorAt(colors.background),
    })
  end
  if type(textRenderer.drawTextWithPalette) == "function" then
    function text.drawTextWithPalette(content, x, y, palette)
      return textRenderer:drawTextWithPalette(content, x, y, palette)
    end
  end
  function text.measure(content)
    return { width = textRenderer:textWidth(content), height = 16 }
  end
  function text.measureForRole(role, content)
    local renderer = assert(roleRenderers[role], "capture measures the generated source text role")
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
        level = 3,
        hp = 12,
        maxHp = 12,
      },
    },
  }
  local options = {
    actors = {
      {
        combatant = 0,
        kind = "command",
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
      actors = { { kind = "command", combatant = 0 } },
      legalChoices = { kinds = { "attack", "item", "switch", "run" } },
      options = options,
    },
  }
end

-- Pumps one screen through its opening cues with the given packet until
-- the command request is exposed: the send-out cue holds on the
-- player-side portrait, so arrival proves the mon drawables resolved.
---@param screen table live battle screen under driving
---@param versionId string ready game version under capture
---@param packet table delivery packet opening the staged battle
local function drivePacketToCommand(screen, versionId, packet, settleSlide)
  local port = screen:presentationPort()
  for _ = 1, 5 do
    screen:updateFixed(TICK)
  end
  Assert.isTrue(port.enter({ launchId = "battle-capture", kind = "wild" }), versionId .. " enters its staged scene")
  port.present(packet)
  local ticks = 0
  while
    (settleSlide == false and screen:status().mode ~= "command")
    or (settleSlide ~= false and screen:status().request == nil)
  do
    if ticks >= DRIVE_BUDGET then
      break
    end
    screen:updateFixed(TICK)
    ticks = ticks + 1
  end
  Assert.equal(screen:status().mode, "command", versionId .. " reaches its command request")
  if settleSlide == false then
    return
  end
  Assert.notNil(screen:status().request, versionId .. " exposes its command request")
  local menuTicks = 0
  while not screen:view().menuInputEnabled and menuTicks < 20 do
    screen:updateFixed(TICK)
    menuTicks = menuTicks + 1
  end
  Assert.isTrue(screen:view().menuInputEnabled, versionId .. " settles the source menu slide before input")
end

-- Pumps one screen through its opening cues until the command request is
-- exposed: the send-out cue holds on the player-side portrait, so arrival
-- proves the mon drawables resolved.
---@param screen table live battle screen under driving
---@param versionId string ready game version under capture
local function driveToCommand(screen, versionId)
  drivePacketToCommand(screen, versionId, openingPacket())
end

---@param screen table live command screen under source-tick advancement
---@param versionId string ready game version under capture
local function settleMenuInput(screen, versionId)
  local ticks = 0
  while not screen:view().menuInputEnabled and ticks < 20 do
    screen:updateFixed(TICK)
    ticks = ticks + 1
  end
  Assert.isTrue(screen:view().menuInputEnabled, versionId .. " settles the source menu slide before input")
end

local function doubledBattlePacket()
  local packet = openingPacket()
  packet.after.own[2].active = true
  packet.after.foes[2] = {
    combatant = 3,
    side = 2,
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
  return nil
end

local function reportRoot()
  local ok, cwd = pcall(love.filesystem.getWorkingDirectory)
  if ok and type(cwd) == "string" and cwd ~= "" then
    return cwd .. "/.agents/tmp/battles/captures"
  end
  return love.filesystem.getSourceBaseDirectory() .. "/../.agents/tmp/battles/captures"
end

local function saveCapture(data, name)
  local directories = { reportRoot() }
  local runRoot = captureRoot()
  if runRoot ~= nil then
    directories[#directories + 1] = runRoot
  end
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

local function countColor(data, rect, color)
  local red = tonumber(color.r or color[1])
  local green = tonumber(color.g or color[2])
  local blue = tonumber(color.b or color[3])
  assert(red ~= nil and green ~= nil and blue ~= nil, "source font colors carry RGB components")
  if red > 1 or green > 1 or blue > 1 then
    red, green, blue = red / 255, green / 255, blue / 255
  end
  local matches = 0
  for y = rect.y, rect.y + rect.height - 1 do
    for x = rect.x, rect.x + rect.width - 1 do
      local actualRed, actualGreen, actualBlue = data:getPixel(x, y)
      if
        quantize(actualRed) == quantize(red)
        and quantize(actualGreen) == quantize(green)
        and quantize(actualBlue) == quantize(blue)
      then
        matches = matches + 1
      end
    end
  end
  return matches
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

---@param scope table test-owned graphics scope
---@param cacheFs table versioned derived cache
---@param screens table ordered source menu layers
---@param label string capture label
---@return table readable source composite
local function composeMenuSource(scope, cacheFs, screens, label, feedbackPatch, menuWindows)
  local ordered = {}
  for index, screen in ipairs(screens) do
    ordered[#ordered + 1] = { index = index, priority = screen.priority or index, screen = screen }
  end
  table.sort(ordered, function(a, b)
    if a.priority == b.priority then
      return a.screen.plane > b.screen.plane
    end
    return a.priority > b.priority
  end)
  local planes = {
    [0] = scope:own(love.image.newImageData(256, 192)),
    [1] = scope:own(love.image.newImageData(256, 192)),
  }
  local bottom = scope:own(love.image.newImageData(256, 192))
  local blendSamples = 0
  local firstBlendPoint = nil
  for _, entry in ipairs(ordered) do
    local target = entry.screen.plane == 1 and planes[1] or planes[0]
    local source = decodeData(scope, cacheFs, entry.screen.image, label .. " source layer " .. entry.index)
    local patch = feedbackPatch ~= nil and feedbackPatch.screenIndex == entry.index and feedbackPatch or nil
    local patchImage = patch ~= nil and decodeData(scope, cacheFs, patch.image, label .. " source feedback patch")
      or nil
    for y = 0, 191 do
      for x = 0, 255 do
        local sr, sg, sb, sa = source:getPixel(x, y)
        if
          patch ~= nil
          and patchImage ~= nil
          and x >= patch.x
          and y >= patch.y
          and x < patch.x + patch.width
          and y < patch.y + patch.height
        then
          local pr, pg, pb, pa = patchImage:getPixel(x - patch.x, y - patch.y)
          if pa > 0 then
            local patchAlpha = pa + sa * (1 - pa)
            sr = patchAlpha > 0 and (pr * pa + sr * sa * (1 - pa)) / patchAlpha or 0
            sg = patchAlpha > 0 and (pg * pa + sg * sa * (1 - pa)) / patchAlpha or 0
            sb = patchAlpha > 0 and (pb * pa + sb * sa * (1 - pa)) / patchAlpha or 0
            sa = patchAlpha
          end
        end
        if sa > 0 then
          local function compositeAt(destinationX, destinationY)
            if destinationX < 0 or destinationY < 0 or destinationX >= 256 or destinationY >= 192 then
              return
            end
            local dr, dg, db, da = target:getPixel(destinationX, destinationY)
            local outputAlpha = sa + da * (1 - sa)
            local outputRed = outputAlpha > 0 and (sr * sa + dr * da * (1 - sa)) / outputAlpha or 0
            local outputGreen = outputAlpha > 0 and (sg * sa + dg * da * (1 - sa)) / outputAlpha or 0
            local outputBlue = outputAlpha > 0 and (sb * sa + db * da * (1 - sa)) / outputAlpha or 0
            target:setPixel(destinationX, destinationY, outputRed, outputGreen, outputBlue, outputAlpha)
          end
          local plane = entry.screen.plane
          if menuWindows ~= nil and (plane == 0 or plane == 1) then
            local offset = assert(menuWindows.scroll[plane], label .. " carries the source BG scroll")
            for _, regionOffset in ipairs({
              { region = menuWindows.outsideTop, y = offset.topY },
              { region = menuWindows.outsideBottom, y = offset.bottomY },
            }) do
              local region = assert(regionOffset.region, label .. " carries the source window region")
              local destinationX = x - offset.x
              local destinationY = y - regionOffset.y
              if
                destinationX >= region.x
                and destinationY >= region.y
                and destinationX < region.x + region.width
                and destinationY < region.y + region.height
              then
                compositeAt(destinationX, destinationY)
              end
            end
          else
            compositeAt(x, y)
          end
        end
      end
    end
  end
  for y = 0, 191 do
    for x = 0, 255 do
      local br, bg, bb, ba = planes[0]:getPixel(x, y)
      local tr, tg, tb, ta = planes[1]:getPixel(x, y)
      local blendRed = math.min(1, (tr * 8 + br * 12) / 16)
      local blendGreen = math.min(1, (tg * 8 + bg * 12) / 16)
      local blendBlue = math.min(1, (tb * 8 + bb * 12) / 16)
      if
        ta > 0
        and ba > 0
        and (
          math.abs(blendRed - tr) > 1 / 255
          or math.abs(blendGreen - tg) > 1 / 255
          or math.abs(blendBlue - tb) > 1 / 255
        )
      then
        blendSamples = blendSamples + 1
        firstBlendPoint = firstBlendPoint or { x = x, y = y }
      end
      bottom:setPixel(
        x,
        y,
        br * (1 - ta) + blendRed * ta,
        bg * (1 - ta) + blendGreen * ta,
        bb * (1 - ta) + blendBlue * ta,
        math.max(ba, ta)
      )
    end
  end
  return bottom, blendSamples, firstBlendPoint
end

local function menuFeedbackPatch(menu, controlId, state)
  for index, screen in ipairs(menu.screens) do
    local controls = screen.feedback
    local states = type(controls) == "table" and controls[controlId] or nil
    local patch = type(states) == "table" and states[state] or nil
    if type(patch) == "table" then
      return {
        image = patch.image,
        x = patch.x,
        y = patch.y,
        width = patch.width,
        height = patch.height,
        screenIndex = index,
      }
    end
  end
  return nil
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
---@return integer matches
---@return integer source-occupied samples
local function countGaugeMatches(capture, strip, hostX, hostY, baseTile)
  local matches, occupied = 0, 0
  for row = 0, 1 do
    for col = 0, 1 do
      local tile = baseTile + row * 2 + col
      for py = 0, 7 do
        for px = 0, 7 do
          local sx, sy = tile * 8 + px, py
          local _, _, _, sourceAlpha = strip:getPixel(sx, sy)
          if sourceAlpha > 0.5 then
            occupied = occupied + 1
            local r1, g1, b1, a1 = capture:getPixel(hostX + col * 8 + px, hostY + row * 8 + py)
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
  return matches, occupied
end

---@param capture table rendered pixels under census
---@param strip table decoded source gauge character strip
---@param object table source NCER object describing one gauge cell
---@param centerX integer native sprite center in the capture
---@param centerY integer native sprite center in the capture
---@return integer matches
---@return integer source-occupied samples
local function countGaugeObjectMatches(capture, strip, object, centerX, centerY)
  local matches, occupied = 0, 0
  local width, height = object.width, object.height
  local originX, originY = centerX + object.x, centerY + object.y
  local columns = width / 8
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local tile = object.tile + math.floor(y / 8) * columns + math.floor(x / 8)
      local sourceX, sourceY = tile * 8 + x % 8, y % 8
      local red, green, blue, alpha = strip:getPixel(sourceX, sourceY)
      local hostX, hostY = originX + x, originY + y
      if alpha > 0.5 and hostX >= 0 and hostY >= 0 and hostX < capture:getWidth() and hostY < capture:getHeight() then
        occupied = occupied + 1
        local actualRed, actualGreen, actualBlue, actualAlpha = capture:getPixel(hostX, hostY)
        if
          quantize(actualRed) == quantize(red)
          and quantize(actualGreen) == quantize(green)
          and quantize(actualBlue) == quantize(blue)
          and quantize(actualAlpha) == quantize(alpha)
        then
          matches = matches + 1
        end
      end
    end
  end
  return matches, occupied
end

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

local function nativeHudPatchBytes(patchSpans, sideType, componentBase)
  local result = {}
  for _, field in ipairs({ "hp", "currentHp", "maximumHp", "status", "gender", "caught" }) do
    for _, record in ipairs(patchSpans[field]) do
      if record.sideType == sideType then
        local spans = record.spans or { record }
        for _, span in ipairs(spans) do
          result[#result + 1] = { span.tile * 32, span.count * 32 }
        end
      end
    end
  end
  if sideType == 0 then
    for _, span in ipairs(patchSpans.experience) do
      result[#result + 1] = { span.tile * 32, span.count * 32 }
    end
  end
  for _, mode in ipairs(patchSpans.playerDoubleMode) do
    if mode.sideType == sideType then
      for _, operation in ipairs(mode.gauge) do
        result[#result + 1] = { operation.tile * 32, 32 }
        result[#result + 1] = { (componentBase + operation.sourceTile) * 32, 32 }
      end
      for _, operation in ipairs(mode.numbers) do
        result[#result + 1] = { operation.tile * 32, 32 }
        result[#result + 1] = { (componentBase + operation.sourceTile) * 32, 32 }
      end
    end
  end
  return result
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

local function nearestTextureTexel(pixelCenter, quadOrigin, scale, vertical)
  local sourceCoordinate = (pixelCenter - quadOrigin) / scale
  if vertical then
    return math.ceil(sourceCoordinate) - 1
  end
  return math.floor(sourceCoordinate)
end

local function countCompactHudCellMatches(capture, strip, section, side, dynamicByteSpans, maskedPixels)
  local frame = assert(section.animation.frames[1], "the source HUD animation has an initial frame")
  local cell = assert(section.cells[frame.cell + 1], "the initial source HUD frame selects a cell")
  local left, top, right, bottom = math.huge, math.huge, -math.huge, -math.huge
  for _, object in ipairs(cell.objs) do
    left = math.min(left, object.x)
    top = math.min(top, object.y)
    right = math.max(right, object.x + object.width)
    bottom = math.max(bottom, object.y + object.height)
  end
  local sourceWidth, sourceHeight = right - left, bottom - top
  local scale = math.min(side.width / sourceWidth, side.height / sourceHeight)
  local drawX = side.x + (side.width - sourceWidth * scale) / 2 - left * scale
  local drawY = side.y + (side.height - sourceHeight * scale) / 2 - top * scale
  local dynamicTiles = {}
  for _, span in ipairs(dynamicByteSpans) do
    local firstTile = span[1] / 32
    local tileCount = span[2] / 32
    for tile = firstTile, firstTile + tileCount - 1 do
      dynamicTiles[tile] = true
    end
  end
  local matched, occupied = 0, 0
  for _, object in ipairs(cell.objs) do
    local objectX = drawX + object.x * scale
    local objectY = drawY + object.y * scale
    for y = math.floor(objectY), math.ceil(objectY + object.height * scale) - 1 do
      for x = math.floor(objectX), math.ceil(objectX + object.width * scale) - 1 do
        if
          x >= 0
          and x < capture:getWidth()
          and y >= 0
          and y < capture:getHeight()
          and not maskedPixels[y * 256 + x]
        then
          local sourceLocalX = nearestTextureTexel(x + 0.5, objectX, scale, false)
          local sourceLocalY = nearestTextureTexel(y + 0.5, objectY, scale, true)
          if
            sourceLocalX >= 0
            and sourceLocalX < object.width
            and sourceLocalY >= 0
            and sourceLocalY < object.height
          then
            local sourceTile = object.tile
              + math.floor(sourceLocalY / 8) * (object.width / 8)
              + math.floor(sourceLocalX / 8)
            if not dynamicTiles[sourceTile] then
              local sourceX = sourceTile * 8 + sourceLocalX % 8
              local sourceY = sourceLocalY % 8
              local _, _, _, sourceAlpha = strip:getPixel(sourceX, sourceY)
              if sourceAlpha > 0.5 then
                occupied = occupied + 1
                local r1, g1, b1, a1 = capture:getPixel(x, y)
                local r2, g2, b2, a2 = strip:getPixel(sourceX, sourceY)
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
    end
  end
  return matched, occupied
end

local function compactHudCellPixelMatches(capture, strip, section, side, dynamicByteSpans, x, y)
  local frame = assert(section.animation.frames[1], "the source HUD animation has an initial frame")
  local cell = assert(section.cells[frame.cell + 1], "the initial source HUD frame selects a cell")
  local left, top, right, bottom = math.huge, math.huge, -math.huge, -math.huge
  for _, object in ipairs(cell.objs) do
    left = math.min(left, object.x)
    top = math.min(top, object.y)
    right = math.max(right, object.x + object.width)
    bottom = math.max(bottom, object.y + object.height)
  end
  local sourceWidth, sourceHeight = right - left, bottom - top
  local scale = math.min(side.width / sourceWidth, side.height / sourceHeight)
  local drawX = side.x + (side.width - sourceWidth * scale) / 2 - left * scale
  local drawY = side.y + (side.height - sourceHeight * scale) / 2 - top * scale
  local dynamicTiles = {}
  for _, span in ipairs(dynamicByteSpans) do
    for tile = span[1] / 32, span[1] / 32 + span[2] / 32 - 1 do
      dynamicTiles[tile] = true
    end
  end
  for _, object in ipairs(cell.objs) do
    local objectX, objectY = drawX + object.x * scale, drawY + object.y * scale
    local localX = nearestTextureTexel(x + 0.5, objectX, scale, false)
    local localY = nearestTextureTexel(y + 0.5, objectY, scale, true)
    if localX >= 0 and localX < object.width and localY >= 0 and localY < object.height then
      local tile = object.tile + math.floor(localY / 8) * (object.width / 8) + math.floor(localX / 8)
      if dynamicTiles[tile] then
        return true, "dynamic tile " .. tostring(tile)
      end
      local sourceX = tile * 8 + localX % 8
      local sourceY = localY % 8
      local r1, g1, b1, a1 = capture:getPixel(x, y)
      local r2, g2, b2, a2 = strip:getPixel(sourceX, sourceY)
      local matches = quantize(r1) == quantize(r2)
        and quantize(g1) == quantize(g2)
        and quantize(b1) == quantize(b2)
        and quantize(a1) == quantize(a2)
      return matches,
        "tile "
          .. tostring(tile)
          .. " source "
          .. tostring(sourceX)
          .. ","
          .. tostring(sourceY)
          .. " alpha "
          .. tostring(a2)
    end
  end
  return false, "outside cell objects"
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
    local drawError = screen:status().error
    Assert.isNil(drawError, versionId .. " keeps compact source HUD drawing active: " .. tostring(drawError))
    local second = renderCapture(scope, screen, width, height)
    local third = renderCapture(scope, screen, width, height)
    Assert.equal(
      imageDataDigest(second),
      imageDataDigest(third),
      versionId
        .. " stabilizes after its first command render ("
        .. tostring(imageDataDigest(second))
        .. " vs "
        .. tostring(imageDataDigest(third))
        .. ")"
    )
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
      -- Native tile bars carry staged-strip ink with the native
      -- quantization; the interim flat tint never paints the bar.
      Assert.isTrue(
        countInk(first, hostRect(frame, bar)) > 10,
        versionId .. " draws the " .. side.label .. " health bar"
      )
      Assert.equal(
        countColor(first, hostRect(frame, bar), { 51, 204, 51 }),
        0,
        versionId .. " paints no interim tint on the " .. side.label .. " health bar"
      )
    end

    local manifest = BattlePresentationCache.load(cacheFs)
    local enemySection = assert(manifest.hud.enemy, versionId .. " carries enemy HUD")
    local playerSection = assert(manifest.hud.player, versionId .. " carries player HUD")
    local enemyStrip = decodeData(scope, cacheFs, enemySection.image, versionId .. " enemy HUD source")
    local playerStrip = decodeData(scope, cacheFs, playerSection.image, versionId .. " player HUD source")
    local sceneSource =
      decodeData(scope, cacheFs, BattlePresentationCache.sceneImagePath(SCENE_KEY), versionId .. " scene source")
    for _, side in ipairs({
      { box = hud.enemy, strip = enemyStrip, section = enemySection, sideType = 1, label = "enemy" },
      { box = hud.player, strip = playerStrip, section = playerSection, sideType = 0, label = "player" },
    }) do
      local mask = {}
      for _, region in ipairs(side.box.regions) do
        for y = frame.y + region.y, frame.y + region.y + region.height - 1 do
          for x = frame.x + region.x, frame.x + region.x + region.width - 1 do
            mask[y * 256 + x] = true
          end
        end
      end
      local compactSide = {
        x = frame.x + side.box.x,
        y = frame.y + side.box.y,
        width = side.box.width,
        height = side.box.height,
      }
      local dynamicSpans = nativeHudPatchBytes(manifest.hud.patchSpans, side.sideType, side.section.componentBase)
      local matches, occupied =
        countCompactHudCellMatches(first, side.strip, side.section, compactSide, dynamicSpans, mask)
      Assert.isTrue(occupied > 20, versionId .. " stages an occupied " .. side.label .. " composite")
      Assert.isTrue(
        matches / occupied > 0.5,
        versionId
          .. " composites the staged "
          .. side.label
          .. " artwork ("
          .. tostring(matches)
          .. "/"
          .. tostring(occupied)
          .. ")"
      )
      local bar = assert(side.box.bar, versionId .. " carries its " .. side.label .. " bar")
      local barBox = hostRect(frame, bar)
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
      local semanticRegions = {}
      for _, region in ipairs(side.box.regions) do
        semanticRegions[#semanticRegions + 1] = {
          rect = hostRect(frame, region),
          id = region.id,
          hasText = type(region.text) == "string" and region.text ~= "",
          ink = 0,
        }
      end
      Assert.isTrue(#semanticRegions > 0, versionId .. " publishes its " .. side.label .. " HUD regions")
      local violations, violationPoints = 0, {}
      for y = side.box.y, side.box.y + side.box.height - 1 do
        for x = side.box.x, side.box.x + side.box.width - 1 do
          local inBar = x >= barBox.x and x < barBox.x + barBox.width and y >= barBox.y and y < barBox.y + barBox.height
          local inRegion = nil
          if not inBar then
            for _, semanticRegion in ipairs(semanticRegions) do
              local rect = semanticRegion.rect
              -- Glyph cells overhang their 12-pixel rows (16-pixel
              -- glyphs plus shadow), so wording ink within 4 pixels of
              -- its region still attributes to that wording.
              if
                x >= rect.x - 4
                and x < rect.x + rect.width + 4
                and y >= rect.y - 4
                and y < rect.y + rect.height + 4
              then
                inRegion = semanticRegion
                break
              end
            end
          end
          if not inBar then
            local pixel = { first:getPixel(x, y) }
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
            local hudCellMatches, hudCellSource =
              compactHudCellPixelMatches(first, side.strip, side.section, compactSide, dynamicSpans, x, y)
            local sourced = near(sceneSource, x - sceneBox.x, y - sceneBox.y) or hudCellMatches
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
                if #violationPoints < 8 then
                  violationPoints[#violationPoints + 1] = tostring(x) .. "," .. tostring(y) .. " " .. hudCellSource
                end
              end
            end
          end
        end
      end
      for _, semanticRegion in ipairs(semanticRegions) do
        if semanticRegion.hasText then
          Assert.isTrue(
            semanticRegion.ink > 10,
            versionId
              .. " prints its "
              .. side.label
              .. " "
              .. semanticRegion.id
              .. " ink ("
              .. tostring(semanticRegion.ink)
              .. " px)"
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
          .. "; pixels "
          .. table.concat(violationPoints, " ")
          .. "; regions "
          .. table.concat(
            (function()
              local descriptions = {}
              for _, region in ipairs(side.box.regions) do
                descriptions[#descriptions + 1] = region.id
                  .. "@"
                  .. tostring(region.x)
                  .. ","
                  .. tostring(region.y)
                  .. "+"
                  .. tostring(region.width)
                  .. "x"
                  .. tostring(region.height)
              end
              return descriptions
            end)(),
            " "
          )
          .. ")"
      )
    end
    local expText = nil
    for _, region in ipairs(hud.player.regions) do
      if region.id == "exp" then
        expText = region.text
      end
    end
    Assert.isTrue(
      expText == nil or tostring(expText):find("^%d+$", 1) == nil,
      versionId .. " never prints numeric experience wording"
    )

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
    drivePacketToCommand(screen, versionId, doubledBattlePacket())
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

    local manifest = BattlePresentationCache.load(cacheFs)
    local sections = assert(manifest.hud.doubles, versionId .. " stages the four native doubled HUD sections")
    for slot, origin in pairs(NATIVE_DOUBLES_HUD_ORIGINS) do
      local section = assert(sections[slot], versionId .. " stages the " .. slot .. " source cell")
      local strip = decodeData(scope, cacheFs, section.image, versionId .. " " .. slot .. " source strip")
      local anchorX, anchorY = detailFrame.x + origin.x, detailFrame.y + origin.y
      local maskedPixels = sourcePatchMask(
        section,
        nativeHudPatchBytes(manifest.hud.patchSpans, section.sideType, section.componentBase),
        anchorX,
        anchorY
      )
      for _, region in ipairs(NATIVE_DOUBLES_TEXT_REGIONS[slot]) do
        for y = detailFrame.y + region.y, detailFrame.y + region.y + region.height - 1 do
          for x = detailFrame.x + region.x, detailFrame.x + region.x + region.width - 1 do
            maskedPixels[y * 256 + x] = true
          end
        end
      end
      local matched, occupied = countHudCellMatches(capture, strip, section, anchorX, anchorY, maskedPixels)
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
    packet.request.actors = {
      { kind = "command", combatant = 0 },
      { kind = "command", combatant = 1 },
    }
    packet.request.options.actors = {
      {
        combatant = 0,
        kind = "command",
        choices = { move, { role = "run", enabled = true, choice = { kind = "run", payload = {} } } },
      },
      {
        combatant = 1,
        kind = "command",
        choices = { moveChoice("move:0", "TACKLE", 35, 35, "NORMAL", 0) },
      },
    }
    drivePacketToCommand(screen, versionId, packet)

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
        local labelRegion = nil
        for _, region in ipairs(box.regions or {}) do
          if region.id == "name" then
            labelRegion = region
            break
          end
        end
        Assert.notNil(labelRegion, versionId .. " publishes a name region for each panel")
        Assert.isTrue(
          countSceneChanges(first, sceneSource, hostRect(frame, labelRegion), scene.x, scene.y) > 10,
          versionId .. " prints the " .. tostring(box.name) .. " panel name"
        )
        if type(box.bar) == "table" then
          Assert.isTrue(
            countColor(first, hostRect(frame, box.bar), { 51, 204, 51 }) > 2,
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
        local matches, occupied = 0, 0
        for phaseY = 0, 1 do
          for phaseX = 0, 1 do
            local phaseMatches, phaseOccupied = countHalfScalePortraitMatches(first, source, rect, 0, 0, phaseX, phaseY)
            if phaseOccupied > 0 and phaseMatches / phaseOccupied > matches / math.max(occupied, 1) then
              matches, occupied = phaseMatches, phaseOccupied
            end
          end
        end
        Assert.isTrue(occupied > 100, versionId .. " has visible source pixels for " .. portrait.selector)
        Assert.isTrue(
          matches / occupied > 0.9,
          versionId .. " paints the nearest-neighbor half-scale pixels for " .. portrait.selector
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
    settleMenuInput(screen, versionId)
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
    local third = renderCapture(scope, screen, width, height)
    Assert.equal(
      imageDataDigest(second),
      imageDataDigest(third),
      versionId
        .. " stabilizes after its first Fight render ("
        .. tostring(imageDataDigest(second))
        .. " vs "
        .. tostring(imageDataDigest(third))
        .. ")"
    )
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
    local info = assert(content.moveInfo, versionId .. " carries its move information rows")
    Assert.isTrue(
      countInk(first, { x = frame.x + 202, y = frame.y + info.typeRowY, width = 44, height = 12 }) > 5,
      versionId .. " prints its move type row"
    )
    Assert.isTrue(
      countInk(first, { x = frame.x + 202, y = frame.y + info.ppRowY, width = 44, height = 12 }) > 5,
      versionId .. " prints its move PP row"
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
    local screen = captureScreen(scope, cacheFs, versionId, dualMeasurement())
    driveToCommand(screen, versionId)
    settleMenuInput(screen, versionId)
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
    Assert.isNil(screen:status().error, versionId .. " completes the first source-composed render")
    local second = renderCapture(scope, screen, width, height)
    Assert.isNil(screen:status().error, versionId .. " remains drawable after the first render")
    local third = renderCapture(scope, screen, width, height)
    Assert.equal(
      imageDataDigest(second),
      imageDataDigest(third),
      versionId .. " stabilizes after the first native command render"
    )
    Assert.equal(
      imageDataDigest(first),
      imageDataDigest(second),
      versionId
        .. " renders the native command view deterministically ("
        .. tostring(imageDataDigest(first))
        .. " vs "
        .. tostring(imageDataDigest(second))
        .. "; first pixels "
        .. firstPixelDifferences(first, second)
        .. ")"
    )
    saveCapture(first, versionId .. "-native-command")

    local detailBox = { x = detailFrame.x, y = detailFrame.y, width = 256, height = 192 }
    Assert.isTrue(countInk(first, detailBox) > 20000, versionId .. " fills the detail pane with scene ink")

    local detailScene =
      decodeData(scope, cacheFs, BattlePresentationCache.sceneImagePath(SCENE_KEY), versionId .. " scene source")
    for _, point in ipairs({ { x = 16, y = 152 }, { x = 231, y = 183 } }) do
      local actual = { first:getPixel(detailFrame.x + point.x, detailFrame.y + point.y) }
      local source = { detailScene:getPixel(point.x, point.y) }
      for channel = 1, 4 do
        Assert.equal(
          quantize(actual[channel]),
          quantize(source[channel]),
          versionId .. " keeps the native narration window transparent at " .. point.x .. "," .. point.y
        )
      end
    end
    local uiManifest =
      assert(cacheFs:loadLua(FieldUiAssetCache.manifestPath()), versionId .. " loads its source frame catalog")
    local frame = assert(uiManifest.dialogueFrames, versionId .. " carries the native dialogue frame")
    local frameTiles = assert(frame.frameTiles[0], versionId .. " carries the selected source frame strip")
    local frameStrip = decodeData(
      scope,
      cacheFs,
      assert(uiManifest.assets[FieldUiAssetCache.ASSET.DIALOGUE_FRAME_TILES]).image,
      versionId .. " selected frame pixels"
    )
    for tileY = 0, 5 do
      for tileX = 0, 31 do
        local tile = nil
        if tileY == 0 then
          tile = tileX == 0 and 0 or tileX == 1 and 1 or tileX <= 28 and 2 or tileX - 26
        elseif tileY == 5 then
          tile = tileX == 0 and 12 or tileX == 1 and 13 or tileX <= 28 and 14 or tileX - 14
        elseif tileX < 2 then
          tile = tileY <= 4 and 6 + tileX or nil
        elseif tileX >= 29 then
          tile = tileY <= 4 and 9 + tileX - 29 or nil
        end
        if tile ~= nil then
          for pixelY = 0, 7 do
            for pixelX = 0, 7 do
              local localX, localY = tileX * 8 + pixelX, tileY * 8 + pixelY + 144
              local red, green, blue, alpha =
                frameStrip:getPixel(frameTiles.x + tile * 8 + pixelX, frameTiles.y + pixelY)
              if alpha > 0 then
                local actual = { first:getPixel(detailFrame.x + localX, detailFrame.y + localY) }
                for channel, expected in ipairs({ red, green, blue, alpha }) do
                  Assert.equal(
                    quantize(actual[channel]),
                    quantize(expected),
                    versionId .. " places native narration frame source pixel " .. localX .. "," .. localY
                  )
                end
              end
            end
          end
        end
      end
    end
    local narrationInk = countInk(first, { x = detailFrame.x + 24, y = detailFrame.y + 160, width = 208, height = 16 })
    Assert.isTrue(narrationInk > 30, versionId .. " prints narration text ink")
    local narrationFont =
      assert(cacheFs:loadLua(FieldFontCache.defPath(1)), versionId .. " loads the source battle printer font")
    local narrationMask =
      decodeData(scope, cacheFs, FieldFontCache.maskAtlasPath(1), versionId .. " source battle printer glyph classes")
    local narration = assert(screen:view().message, versionId .. " carries the rendered source narration")
    local colors = {
      assert(narrationFont.palette[2], versionId .. " carries narration foreground slot 1"),
      assert(narrationFont.palette[3], versionId .. " carries narration shadow slot 2"),
      assert(narrationFont.palette[1], versionId .. " carries narration background slot 0"),
    }
    local textX, textY = 24, 160
    for character in Utf8Glyphs.iter(narration) do
      local code = narrationFont.charmap[character] or narrationFont.fallbackCode
      local glyph = assert(narrationFont.glyphs[code], versionId .. " resolves narration glyph " .. character)
      for glyphY = 0, glyph.h - 1 do
        for glyphX = 0, glyph.w - 1 do
          local red, green, blue, alpha = narrationMask:getPixel(glyph.x + glyphX, glyph.y + glyphY)
          if alpha > 0.5 then
            local color = red > 0.5 and colors[1] or green > 0.5 and colors[2] or blue > 0.5 and colors[3] or nil
            color = assert(color, versionId .. " maps every narration mask pixel to a source color class")
            local actual = { first:getPixel(detailFrame.x + textX + glyphX, detailFrame.y + textY + glyphY) }
            for channel, expected in ipairs({ color.r / 255, color.g / 255, color.b / 255, 1 }) do
              Assert.equal(
                quantize(actual[channel]),
                quantize(expected),
                versionId .. " prints source narration " .. character .. " with its foreground/shadow palette"
              )
            end
          end
        end
      end
      textX = textX + glyph.advance + (narrationFont.letterSpacing or 0)
    end

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

    local commandMenu = assert(BattlePresentationCache.load(cacheFs).menus.command, versionId .. " carries command art")
    local selectedFightPatch = assert(menuFeedbackPatch(commandMenu, "fight", "selected"))
    local menuSource, blendSamples, blendPoint =
      composeMenuSource(scope, cacheFs, commandMenu.screens, versionId .. " command menu", selectedFightPatch)
    Assert.isTrue(blendSamples > 0, versionId .. " source pixels distinguish BG1 Eva/Evb blending from raw BG1")
    local pixelMatches = countSourceMatches(first, menuSource, {
      x = interactionFrame.x + assert(blendPoint, "the source blend has a discriminating pixel").x,
      y = interactionFrame.y + blendPoint.y,
      width = 1,
      height = 1,
    }, interactionFrame.x, interactionFrame.y)
    Assert.equal(pixelMatches, 1, versionId .. " renders the source-priority BG1 blend at its discriminating pixel")
    local interactionBox = { x = interactionFrame.x, y = interactionFrame.y, width = 256, height = 192 }
    local matches, occupied =
      countSourceMatches(first, menuSource, interactionBox, interactionFrame.x, interactionFrame.y)
    Assert.isTrue(occupied > 20000, versionId .. " stages an occupied command surface")
    Assert.isTrue(
      matches / occupied > 0.8,
      versionId
        .. " keeps the staged command artwork visible ("
        .. tostring(matches)
        .. "/"
        .. tostring(occupied)
        .. ")"
    )

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
    -- renderer samples: both HUD strips cover their source cell and
    -- appended component tiles, the arrow 208x8, the
    -- 16-pixel gauge family 128x8. A producer repagination fails here
    -- before any quad can sample the wrong tiles.
    local stagedManifest = BattlePresentationCache.load(cacheFs)
    local function stagedSize(path, label)
      local record = assert(stagedManifest.menus.images[path], versionId .. " stages " .. label)
      return record.width, record.height
    end
    local enemyHudWidth, enemyHudHeight =
      stagedSize(assert(stagedManifest.hud.enemy, versionId .. " carries enemy HUD").image, "enemy HUD")
    local enemyHud = assert(stagedManifest.hud.enemy, versionId .. " carries enemy HUD")
    Assert.equal(
      enemyHudWidth,
      (enemyHud.componentBase + enemyHud.componentCount) * 8,
      versionId .. " covers every source enemy HUD component tile"
    )
    Assert.equal(enemyHudHeight, 8, versionId .. " keeps the enemy strip row")
    local playerHudWidth, playerHudHeight =
      stagedSize(assert(stagedManifest.hud.player, versionId .. " carries player HUD").image, "player HUD")
    local playerHud = assert(stagedManifest.hud.player, versionId .. " carries player HUD")
    Assert.equal(
      playerHudWidth,
      (playerHud.componentBase + playerHud.componentCount) * 8,
      versionId .. " covers every source player HUD component tile"
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

    -- The detail pane composites native OBJ cells at source anchors.
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
    local singleTextRegions = {
      player = { { x = 144, y = 92, width = 88, height = 16 }, { x = 144, y = 104, width = 88, height = 16 } },
      enemy = { { x = 8, y = 16, width = 88, height = 16 }, { x = 8, y = 28, width = 88, height = 16 } },
    }
    local function sourceSlot(sideType)
      for _, row in ipairs(stagedManifest.battlefield.slots) do
        if row.sideType == sideType then
          return row
        end
      end
      error(versionId .. " stages side type " .. tostring(sideType), 0)
    end
    for _, side in ipairs({
      { label = "player", sideType = 0, section = playerHud, strip = playerStrip },
      { label = "enemy", sideType = 1, section = enemyHud, strip = enemyStrip },
    }) do
      local row = sourceSlot(side.sideType)
      local anchorX, anchorY = detailFrame.x + row.hudX, detailFrame.y + row.hudY
      local dynamic = sourcePatchMask(
        side.section,
        nativeHudPatchBytes(stagedManifest.hud.patchSpans, side.sideType, side.section.componentBase),
        anchorX,
        anchorY
      )
      for _, region in ipairs(singleTextRegions[side.label]) do
        for y = detailFrame.y + region.y, detailFrame.y + region.y + region.height - 1 do
          for x = detailFrame.x + region.x, detailFrame.x + region.x + region.width - 1 do
            dynamic[y * 256 + x] = true
          end
        end
      end
      local matches, occupied = countHudCellMatches(first, side.strip, side.section, anchorX, anchorY, dynamic)
      Assert.isTrue(occupied > 40, versionId .. " stages an occupied " .. side.label .. " native cell")
      Assert.isTrue(
        matches / occupied > 0.6,
        versionId
          .. " composites the staged "
          .. side.label
          .. " native cell ("
          .. tostring(matches)
          .. "/"
          .. tostring(occupied)
          .. ")"
      )
    end

    -- Party gauges draw staged source cells by roster visibility: the
    -- standing lead selects the healthy ball cell at its slot origin,
    -- and the revealed foe selects its own cell.
    local enemyGauge = assert(stagedManifest.hud.partyGauges[1], versionId .. " carries enemy gauges")
    local playerGauge = assert(stagedManifest.hud.partyGauges[2], versionId .. " carries player gauges")
    local enemyGaugeStrip = decodeData(scope, cacheFs, enemyGauge.image, versionId .. " enemy gauge source")
    local playerGaugeStrip = decodeData(scope, cacheFs, playerGauge.image, versionId .. " player gauge source")
    local enemyGaugeCell = assert(enemyGauge.cells[2].objs[1], versionId .. " publishes the healthy enemy gauge cell")
    local playerGaugeCell =
      assert(playerGauge.cells[2].objs[1], versionId .. " publishes the healthy player gauge cell")
    Assert.equal(enemyGaugeCell.width, 16, versionId .. " enemy gauge cell uses its native 16px family")
    Assert.equal(playerGaugeCell.width, 32, versionId .. " player gauge cell uses its native 32px family")
    local leadMatches, leadOccupied = countGaugeObjectMatches(
      first,
      playerGaugeStrip,
      playerGaugeCell,
      interactionFrame.x + 12,
      interactionFrame.y + 13
    )
    Assert.isTrue(leadOccupied > 50, versionId .. " stages an occupied lead gauge cell")
    local foeMatches, foeOccupied =
      countGaugeObjectMatches(first, enemyGaugeStrip, enemyGaugeCell, interactionFrame.x + 246, interactionFrame.y + 9)
    Assert.isTrue(foeOccupied > 50, versionId .. " stages an occupied foe gauge cell")
    Assert.isTrue(
      leadMatches / leadOccupied > 0.9 and foeMatches / foeOccupied > 0.9,
      versionId
        .. " draws both native gauge families (player "
        .. tostring(leadMatches)
        .. "/"
        .. tostring(leadOccupied)
        .. ", opponent "
        .. tostring(foeMatches)
        .. "/"
        .. tostring(foeOccupied)
        .. ")"
    )
    for _, family in ipairs({
      { label = "enemy", section = enemyGauge, strip = enemyGaugeStrip, width = 16 },
      { label = "player", section = playerGauge, strip = playerGaugeStrip, width = 32 },
    }) do
      Assert.isTrue(#family.section.animations > 0, versionId .. " stages " .. family.label .. " gauge state sequences")
      for animationIndex, animation in ipairs(family.section.animations) do
        Assert.isTrue(
          #animation.frames > 0,
          versionId .. " carries " .. family.label .. " gauge sequence " .. animationIndex
        )
        for _, frame in ipairs(animation.frames) do
          local state = assert(
            family.section.cells[frame.cell + 1],
            versionId .. " maps " .. family.label .. " gauge frame " .. tostring(frame.cell) .. " to source cells"
          )
          Assert.isTrue(#state.objs > 0, versionId .. " gives each " .. family.label .. " gauge frame source objects")
          for _, object in ipairs(state.objs) do
            Assert.equal(
              object.width,
              family.width,
              versionId .. " keeps the " .. family.label .. " gauge family width"
            )
            Assert.isTrue(
              object.tile * 8 + object.width <= family.strip:getWidth(),
              versionId .. " keeps every " .. family.label .. " gauge cell inside its decoded strip"
            )
          end
        end
      end
    end
  end
end

-- A captured outcome's typed shake count selects the staged bank-197
-- record through the published dynamic route. The screen view is the
-- observable message boundary; the expected text comes from that
-- independently decoded source record.
local function sourceIconPatches(patchSpans, field, sideType, sourceTiles)
  local destinations = nil
  for _, record in ipairs(patchSpans[field]) do
    if record.sideType == sideType then
      destinations = record.spans or { record }
      break
    end
  end
  destinations = assert(destinations, "the source publishes the selected HUD icon destinations")
  local patches, index = {}, 1
  for _, span in ipairs(destinations) do
    for offset = 0, span.count - 1 do
      patches[#patches + 1] = { tile = span.tile + offset, sourceTile = sourceTiles[index] }
      index = index + 1
    end
  end
  Assert.equal(index, #sourceTiles + 1, "source HUD spans consume every selected icon tile")
  return patches
end

local function assertSourceHudIconPixels(
  capture,
  strip,
  section,
  cell,
  patchSpans,
  field,
  sideType,
  sourceTiles,
  anchorX,
  anchorY,
  levelTextPixels,
  label
)
  for _, patch in ipairs(sourceIconPatches(patchSpans, field, sideType, sourceTiles)) do
    local destination = nil
    for _, object in ipairs(cell.objs) do
      local columns, rowsCount = object.width / 8, object.height / 8
      local offset = patch.tile - object.tile
      if not object.disabled and offset >= 0 and offset < columns * rowsCount then
        destination = {
          x = anchorX + object.x + offset % columns * 8,
          y = anchorY + object.y + math.floor(offset / columns) * 8,
        }
        break
      end
    end
    destination = assert(destination, label .. " maps its native write to an OAM tile")
    local sourceX = (section.componentBase + patch.sourceTile) * 8
    local occupied, matches = 0, 0
    for y = 0, 7 do
      for x = 0, 7 do
        local sourceR, sourceG, sourceB, sourceA = strip:getPixel(sourceX + x, y)
        if sourceA > 0.5 then
          occupied = occupied + 1
          local hostX, hostY = destination.x + x, destination.y + y
          local textR, textG, textB, textA = levelTextPixels:getPixel(hostX, hostY)
          local expectedR, expectedG, expectedB = sourceR, sourceG, sourceB
          if textA > 0.5 then
            expectedR, expectedG, expectedB = textR, textG, textB
          end
          local actualR, actualG, actualB, actualA = capture:getPixel(hostX, hostY)
          if
            quantize(expectedR) == quantize(actualR)
            and quantize(expectedG) == quantize(actualG)
            and quantize(expectedB) == quantize(actualB)
            and quantize(sourceA) == quantize(actualA)
          then
            matches = matches + 1
          end
        end
      end
    end
    Assert.equal(matches, occupied, label .. " composes its exact source icon tile under HUD text")
  end
end

-- These source character IDs are the values written by pokeheartgold's
-- battle_hp_bar.c HUD icon routines. Compare the live native renderer's
-- dynamic character writes against the separately decoded appended source
-- tiles at each destination OAM tile.
function T.native_hud_status_gender_and_caught_tiles_match_source_pixels(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("native HUD icon pixels need a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local packet = openingPacket()
    packet.after.own[1].condition = "burn"
    packet.after.own[1].gender = "female"
    packet.after.foes[1].condition = "poison"
    packet.after.foes[1].gender = "male"
    packet.after.foes[1].caught = true
    local screen = captureScreen(scope, cacheFs, versionId, dualMeasurement())
    drivePacketToCommand(screen, versionId, packet)
    local plan = livePlan(screen, versionId)
    local detailFrame = nil
    for _, pane in ipairs(plan.panes) do
      if pane.id == "detail" then
        detailFrame = assert(pane.placement.frame, versionId .. " places its native HUD")
      end
    end
    detailFrame = assert(detailFrame, versionId .. " plans the source detail pane")
    local capture = renderCapture(scope, screen, 256, 384)
    local levelTextRenderer = scope:own(FieldTextRenderer.new({ cacheFs = cacheFs }))
    local fontPalette = assert(levelTextRenderer.fontDef.palette, versionId .. " carries the health-box font palette")
    local function fontColor(slot)
      local source = assert(fontPalette[slot], versionId .. " carries health-box font slot " .. slot)
      local red = assert(tonumber(source.r or source[1]))
      local green = assert(tonumber(source.g or source[2]))
      local blue = assert(tonumber(source.b or source[3]))
      if red > 1 or green > 1 or blue > 1 then
        red, green, blue = red / 255, green / 255, blue / 255
      end
      return { r = red * 255, g = green * 255, b = blue * 255 }
    end
    local levelText = scope:own(love.graphics.newCanvas(256, 384))
    love.graphics.push("all")
    love.graphics.setCanvas(levelText)
    love.graphics.clear(0, 0, 0, 0)
    love.graphics.setColor(1, 1, 1, 1)
    local levelPalette = {
      foreground = fontColor(2),
      shadow = fontColor(3),
      background = fontColor(16),
    }
    levelTextRenderer:drawTextWithPalette("Lv9", 144, 104, levelPalette)
    levelTextRenderer:drawTextWithPalette("Lv3", 8, 28, levelPalette)
    love.graphics.setCanvas()
    love.graphics.pop()
    local levelTextPixels = scope:own(levelText:newImageData())
    local manifest = BattlePresentationCache.load(cacheFs)
    local rows = {
      {
        label = "player",
        sideType = 0,
        section = assert(manifest.hud.player, versionId .. " carries the player HUD"),
        fields = {
          { key = "status", sources = { 41, 42, 43 } },
          { key = "gender", sources = { 60, 61, 72, 73 } },
        },
      },
      {
        label = "wild foe",
        sideType = 1,
        section = assert(manifest.hud.enemy, versionId .. " carries the enemy HUD"),
        fields = {
          { key = "status", sources = { 44, 45, 46 } },
          { key = "gender", sources = { 62, 63, 74, 75 } },
          { key = "caught", sources = { 59 } },
        },
      },
    }
    for _, row in ipairs(rows) do
      local strip = decodeData(scope, cacheFs, row.section.image, versionId .. " " .. row.label .. " HUD source")
      local frame = assert(row.section.animation.frames[1], versionId .. " stages the initial " .. row.label .. " cell")
      local cell = assert(row.section.cells[frame.cell + 1], versionId .. " stages the " .. row.label .. " cell")
      local slot = nil
      for _, candidate in ipairs(manifest.battlefield.slots) do
        if candidate.sideType == row.sideType then
          slot = candidate
          break
        end
      end
      slot = assert(slot, versionId .. " publishes the " .. row.label .. " HUD anchor")
      for _, field in ipairs(row.fields) do
        local patches = sourceIconPatches(manifest.hud.patchSpans, field.key, row.sideType, field.sources)
        for _, patch in ipairs(patches) do
          local destination = nil
          for _, object in ipairs(cell.objs) do
            local columns, rowsCount = object.width / 8, object.height / 8
            local offset = patch.tile - object.tile
            if not object.disabled and offset >= 0 and offset < columns * rowsCount then
              destination = {
                x = detailFrame.x + slot.hudX + object.x + offset % columns * 8,
                y = detailFrame.y + slot.hudY + object.y + math.floor(offset / columns) * 8,
              }
              break
            end
          end
          destination = assert(destination, versionId .. " maps " .. row.label .. " " .. field.key .. " to an OAM tile")
          local sourceX = (row.section.componentBase + patch.sourceTile) * 8
          local _, occupied = countSourceMatches(
            capture,
            strip,
            { x = destination.x, y = destination.y, width = 8, height = 8 },
            destination.x - sourceX,
            destination.y
          )
          Assert.isTrue(occupied > 0, versionId .. " stages source pixels for " .. row.label .. " " .. field.key)
          local composedMatches, composedOccupied = 0, 0
          for y = 0, 7 do
            for x = 0, 7 do
              local sourceR, sourceG, sourceB, sourceA = strip:getPixel(sourceX + x, y)
              if sourceA > 0.5 then
                composedOccupied = composedOccupied + 1
                local hostX, hostY = destination.x + x, destination.y + y
                local textR, textG, textB, textA = levelTextPixels:getPixel(hostX, hostY)
                local expectedR, expectedG, expectedB = sourceR, sourceG, sourceB
                if textA > 0.5 then
                  expectedR, expectedG, expectedB = textR, textG, textB
                end
                local actualR, actualG, actualB, actualA = capture:getPixel(hostX, hostY)
                if
                  quantize(expectedR) == quantize(actualR)
                  and quantize(expectedG) == quantize(actualG)
                  and quantize(expectedB) == quantize(actualB)
                  and quantize(sourceA) == quantize(actualA)
                then
                  composedMatches = composedMatches + 1
                end
              end
            end
          end
          Assert.equal(
            composedMatches,
            composedOccupied,
            versionId .. " composes source " .. row.label .. " " .. field.key .. " tile under HUD wording"
          )
        end
      end
    end
  end
end

function T.native_hud_status_gender_and_caught_source_pixel_matrix(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("native HUD icon matrix needs a ready user-owned ROM with a derived cache")
  end
  local statusTiles = {
    healthy = { 38, 39, 40 },
    paralysis = { 47, 48, 49 },
    freeze = { 50, 51, 52 },
    sleep = { 53, 54, 55 },
    poison = { 44, 45, 46 },
    burn = { 41, 42, 43 },
  }
  local genderTiles = {
    male = { 62, 63, 74, 75 },
    female = { 60, 61, 72, 73 },
    genderless = { 64, 65, 76, 77 },
  }
  local scenarios = {
    { player = { condition = nil, gender = nil }, foe = { condition = nil, gender = nil, caught = nil } },
    {
      player = { condition = "paralysis", gender = "female" },
      foe = { condition = "freeze", gender = "male", caught = true },
    },
    {
      player = { condition = "freeze", gender = "male" },
      foe = { condition = "paralysis", gender = "female", caught = false },
    },
    {
      player = { condition = "sleep", gender = "genderless" },
      foe = { condition = "poison", gender = "genderless", caught = true },
    },
    {
      player = { condition = "poison", gender = "female" },
      foe = { condition = "sleep", gender = "male", caught = false },
    },
    {
      player = { condition = "burn", gender = "male" },
      foe = { condition = "burn", gender = "female", caught = nil },
    },
  }
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local manifest = BattlePresentationCache.load(cacheFs)
    local function applyScenario(view, scenario)
      view.own[1].condition = scenario.player.condition
      view.own[1].gender = scenario.player.gender
      view.foes[1].condition = scenario.foe.condition
      view.foes[1].gender = scenario.foe.gender
      view.foes[1].caught = scenario.foe.caught
    end
    local player = assert(manifest.hud.player, versionId .. " carries the player HUD")
    local foe = assert(manifest.hud.enemy, versionId .. " carries the enemy HUD")
    local playerStrip = decodeData(scope, cacheFs, player.image, versionId .. " player icon matrix strip")
    local foeStrip = decodeData(scope, cacheFs, foe.image, versionId .. " foe icon matrix strip")
    local playerSlot = nil
    local foeSlot = nil
    for _, slot in ipairs(manifest.battlefield.slots) do
      if slot.sideType == 0 then
        playerSlot = slot
      elseif slot.sideType == 1 then
        foeSlot = slot
      end
    end
    playerSlot = assert(playerSlot, versionId .. " stages the player HUD anchor")
    foeSlot = assert(foeSlot, versionId .. " stages the foe HUD anchor")
    local textRenderer = scope:own(FieldTextRenderer.new({ cacheFs = cacheFs }))
    local fontPalette = assert(textRenderer.fontDef.palette, versionId .. " carries the HUD text palette")
    local function fontColor(slot)
      local color = assert(fontPalette[slot], versionId .. " carries HUD text color " .. slot)
      local red = assert(tonumber(color.r or color[1]))
      local green = assert(tonumber(color.g or color[2]))
      local blue = assert(tonumber(color.b or color[3]))
      if red > 1 or green > 1 or blue > 1 then
        red, green, blue = red / 255, green / 255, blue / 255
      end
      return { r = red * 255, g = green * 255, b = blue * 255 }
    end
    local levelText = scope:own(love.graphics.newCanvas(256, 384))
    love.graphics.push("all")
    love.graphics.setCanvas(levelText)
    love.graphics.clear(0, 0, 0, 0)
    love.graphics.setColor(1, 1, 1, 1)
    local palette = { foreground = fontColor(2), shadow = fontColor(3), background = fontColor(16) }
    textRenderer:drawTextWithPalette("Lv9", 144, 104, palette)
    textRenderer:drawTextWithPalette("Lv3", 8, 28, palette)
    love.graphics.setCanvas()
    love.graphics.pop()
    local levelTextPixels = scope:own(levelText:newImageData())
    for _, scenario in ipairs(scenarios) do
      local packet = openingPacket()
      applyScenario(packet.after, scenario)
      local screen = captureScreen(scope, cacheFs, versionId, dualMeasurement())
      drivePacketToCommand(screen, versionId, packet)
      local detailFrame = nil
      for _, pane in ipairs(livePlan(screen, versionId).panes) do
        if pane.id == "detail" then
          detailFrame = assert(pane.placement.frame, versionId .. " places the native HUD")
        end
      end
      detailFrame = assert(detailFrame, versionId .. " plans its source detail pane")
      local capture = renderCapture(scope, screen, 256, 384)
      local fields = {
        {
          label = "player",
          sideType = 0,
          section = player,
          strip = playerStrip,
          slot = playerSlot,
          data = scenario.player,
        },
        {
          label = "foe",
          sideType = 1,
          section = foe,
          strip = foeStrip,
          slot = foeSlot,
          data = scenario.foe,
        },
      }
      for _, row in ipairs(fields) do
        local frame = assert(row.section.animation.frames[1], versionId .. " stages " .. row.label .. " icon cell")
        local cell = assert(row.section.cells[frame.cell + 1], versionId .. " stages " .. row.label .. " icon OAM")
        local anchorX = detailFrame.x + row.slot.hudX
        local anchorY = detailFrame.y + row.slot.hudY
        local statusKey = row.data.condition or "healthy"
        assertSourceHudIconPixels(
          capture,
          row.strip,
          row.section,
          cell,
          manifest.hud.patchSpans,
          "status",
          row.sideType,
          statusTiles[statusKey],
          anchorX,
          anchorY,
          levelTextPixels,
          versionId .. " " .. row.label .. " " .. statusKey .. " status"
        )
        if row.data.gender ~= nil then
          assertSourceHudIconPixels(
            capture,
            row.strip,
            row.section,
            cell,
            manifest.hud.patchSpans,
            "gender",
            row.sideType,
            genderTiles[row.data.gender],
            anchorX,
            anchorY,
            levelTextPixels,
            versionId .. " " .. row.label .. " " .. row.data.gender .. " gender"
          )
        end
        if row.label == "foe" and row.data.caught ~= nil then
          assertSourceHudIconPixels(
            capture,
            row.strip,
            row.section,
            cell,
            manifest.hud.patchSpans,
            "caught",
            row.sideType,
            { row.data.caught and 59 or 38 },
            anchorX,
            anchorY,
            levelTextPixels,
            versionId .. " foe caught " .. tostring(row.data.caught)
          )
        end
      end
    end
  end
end

function T.native_party_gauge_cells_match_every_roster_state(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("native gauge pixels need a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local packet = openingPacket()
    packet.after.own = {}
    for slot = 0, 4 do
      local hp = (slot == 1 or slot == 3) and 0 or 30
      packet.after.own[#packet.after.own + 1] = {
        combatant = slot,
        side = 1,
        active = slot == 0,
        species = LEAD_SPECIES,
        form = 0,
        selector = "back",
        portraitSelector = MonCache.portraitSelector(LEAD_SPECIES, 0, "male", false, "back"),
        name = LEAD_SPECIES,
        level = 9,
        hp = hp,
        maxHp = 30,
        experience = 120,
      }
    end
    local screen = captureScreen(scope, cacheFs, versionId, dualMeasurement())
    drivePacketToCommand(screen, versionId, packet)
    local plan = livePlan(screen, versionId)
    local interaction = nil
    for _, pane in ipairs(plan.panes) do
      if pane.id == "interaction" then
        interaction = pane.placement.frame
      end
    end
    interaction = assert(interaction, versionId .. " places the native roster gauges")
    local capture = renderCapture(scope, screen, 256, 384)
    local manifest = BattlePresentationCache.load(cacheFs)
    local families = {
      {
        label = "player",
        section = assert(manifest.hud.partyGauges[2], versionId .. " stages player gauges"),
        slots = 6,
        sourceX = 12,
        pitch = 19,
        y = 13,
        stateAt = function(index)
          if index > 4 then
            return 0
          end
          return (index == 1 or index == 3) and 2 or 1
        end,
      },
      {
        label = "opponent",
        section = assert(manifest.hud.partyGauges[1], versionId .. " stages opponent gauges"),
        slots = 6,
        sourceX = 246,
        pitch = -12,
        y = 9,
        stateAt = function(index)
          return index == 0 and 1 or 0
        end,
      },
    }
    for _, family in ipairs(families) do
      local strip = decodeData(scope, cacheFs, family.section.image, versionId .. " " .. family.label .. " gauge strip")
      for index = 0, family.slots - 1 do
        local state = family.stateAt(index)
        local cell =
          assert(family.section.cells[state + 1], versionId .. " stages " .. family.label .. " state " .. state)
        local stateOccupied = 0
        for _, object in ipairs(cell.objs) do
          local matches, occupied = countGaugeObjectMatches(
            capture,
            strip,
            object,
            interaction.x + family.sourceX + family.pitch * index,
            interaction.y + family.y
          )
          stateOccupied = stateOccupied + occupied
          if occupied > 0 then
            Assert.equal(
              matches,
              occupied,
              versionId .. " draws exact " .. family.label .. " gauge pixels for roster slot " .. index
            )
          end
        end
        Assert.isTrue(
          stateOccupied > 0,
          versionId .. " draws source pixels for " .. family.label .. " gauge state " .. state
        )
      end
    end

    local before = packet.after
    local after = { own = {}, foes = before.foes }
    for index = 1, 2 do
      local record = {}
      for key, value in pairs(before.own[index]) do
        record[key] = value
      end
      record.hp = 30
      after.own[index] = record
    end
    screen:presentationPort().present({
      launchId = "battle-capture",
      packetId = 2,
      before = before,
      after = after,
      events = {},
    })
    local changedCapture = renderCapture(scope, screen, 256, 384)
    local player = families[1]
    local playerStrip = decodeData(scope, cacheFs, player.section.image, versionId .. " changed player gauge strip")
    for index = 0, player.slots - 1 do
      local state = index < 2 and 1 or 0
      local cell = assert(player.section.cells[state + 1], versionId .. " stages changed roster state " .. state)
      local occupied = 0
      for _, object in ipairs(cell.objs) do
        local matches, count = countGaugeObjectMatches(
          changedCapture,
          playerStrip,
          object,
          interaction.x + player.sourceX + player.pitch * index,
          interaction.y + player.y
        )
        occupied = occupied + count
        if count > 0 then
          Assert.equal(matches, count, versionId .. " renders the updated roster slot " .. index)
        end
      end
      Assert.isTrue(occupied > 0, versionId .. " draws the updated player state " .. state)
    end
  end
end

function T.capture_outcome_uses_its_source_message(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the battle captures need a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local manifest = BattlePresentationCache.load(cacheFs)
    local route =
      assert(manifest.messages.dynamicRoutes.captureShake, versionId .. " publishes capture message selection")
    local shakes = 2
    local packet = BattlePresentationModel.packet(openingPacket().after, {
      events = {
        {
          sequence = 1,
          kind = "broke_free",
          cause = { key = "CAPTURE" },
          audience = "public",
          payload = { shakes = shakes },
          observation = {},
        },
      },
    }, openingPacket().after, { launchId = "battle-capture", packetId = 2 })
    Assert.equal(packet.events[1].messageArgs.shakes, shakes, versionId .. " preserves the mechanics shake count")
    local messageKey = route.firstRecord:gsub("0$", tostring(packet.events[1].messageArgs.shakes))
    local entry = assert(manifest.messages.entries[messageKey], versionId .. " stages the selected source record")
    local expected = FieldMessageText.tokensToText(entry.tokens)
    local screen = captureScreen(scope, cacheFs, versionId, dualMeasurement())
    driveToCommand(screen, versionId)
    local port = screen:presentationPort()
    port.present(packet)
    local ticks = 0
    local firstPage = screen:view().message
    while
      (type(firstPage) ~= "string" or firstPage == "" or expected:sub(1, #firstPage) ~= firstPage)
      and ticks < DRIVE_BUDGET
    do
      screen:updateFixed(TICK)
      ticks = ticks + 1
      firstPage = screen:view().message
    end
    Assert.isTrue(type(firstPage) == "string" and firstPage ~= "", versionId .. " begins printing its outcome")
    Assert.equal(
      expected:sub(1, #firstPage),
      firstPage,
      versionId
        .. " reveals a prefix of the source-selected outcome (actual: "
        .. tostring(firstPage)
        .. "; source: "
        .. expected
        .. ")"
    )
    local printed = false
    for _ = 1, DRIVE_BUDGET do
      screen:updateFixed(TICK)
      if screen:view().message == expected then
        printed = true
        break
      end
    end
    Assert.isTrue(printed, versionId .. " completes the source-selected outcome within the native print budget")
    Assert.isNil(screen:status().error, versionId .. " completes the source-backed outcome without failure")
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
    local sourceManifest = BattlePresentationCache.load(cacheFs)
    local fightRoute = assert(sourceManifest.menus.routes["menu/fight"], versionId .. " publishes the fight route")
    local hasTypeIcon = false
    for _, role in ipairs(fightRoute.assetRoles) do
      hasTypeIcon = hasTypeIcon or role == "moveTypeIcon"
    end
    Assert.isTrue(hasTypeIcon, versionId .. " binds fight rows to the generated move-type icon role")
    local moveSlots =
      assert(sourceManifest.menus.contexts.moveSelection.slots, versionId .. " publishes move-slot source fields")
    Assert.equal(moveSlots.derived.moveName, "move-name", versionId .. " derives names from the move field")
    Assert.equal(moveSlots.derived.moveType, "move-type", versionId .. " derives type from the move field")
    Assert.equal(moveSlots.derived.typeIcon, "move-type-icon", versionId .. " carries the source type-icon field")
    local menuFontPath = assert(sourceManifest.messages.roles.menu.font, versionId .. " publishes the menu font")
    Assert.equal(menuFontPath, FieldFontCache.defPath(4), versionId .. " uses the source menu font")
    local menuFont = assert(cacheFs:loadLua(menuFontPath), versionId .. " loads the source menu glyph definition")
    Assert.isTrue(
      type(menuFont.glyphs) == "table" and type(menuFont.charmap) == "table",
      versionId .. " loads menu glyph geometry"
    )
    Assert.isTrue(
      type(menuFont.palette) == "table" and #menuFont.palette > 0,
      versionId .. " loads the source font palette"
    )
    for _, label in ipairs({ "TACKLE", "GROWL", "NORMAL", "BACK", "35" }) do
      for index = 1, #label do
        local glyphCode = menuFont.charmap[label:sub(index, index)]
        Assert.notNil(glyphCode, versionId .. " maps source menu text " .. label)
        Assert.notNil(menuFont.glyphs[glyphCode], versionId .. " publishes glyph geometry for " .. label)
      end
    end
    local sourceGlyphAtlas =
      decodeData(scope, cacheFs, FieldFontCache.atlasPath(4), versionId .. " menu glyph and palette atlas")
    Assert.equal(sourceGlyphAtlas:getHeight(), menuFont.atlas.height, versionId .. " decodes all menu font color bands")
    local screen = captureScreen(scope, cacheFs, versionId, dualMeasurement())
    driveToCommand(screen, versionId)
    screen:input({ { type = "confirm" } })
    screen:updateFixed(TICK)
    Assert.equal(screen:status().mode, "moves", versionId .. " opens the native move view")
    settleMenuInput(screen, versionId)
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
    local third = renderCapture(scope, screen, width, height)
    Assert.equal(
      imageDataDigest(second),
      imageDataDigest(third),
      versionId .. " stabilizes after the first native Fight render"
    )
    Assert.equal(
      imageDataDigest(first),
      imageDataDigest(second),
      versionId
        .. " renders the native Fight view deterministically ("
        .. tostring(imageDataDigest(first))
        .. " vs "
        .. tostring(imageDataDigest(second))
        .. "; first pixels "
        .. firstPixelDifferences(first, second)
        .. ")"
    )
    saveCapture(first, versionId .. "-native-fight")

    local menuSource = decodeData(
      scope,
      cacheFs,
      assert(BattlePresentationCache.load(cacheFs).menus.moves, versionId .. " carries move art").image,
      versionId .. " move source"
    )
    local function sourceDiffs(localBox)
      local changed = 0
      local box = {
        x = interactionFrame.x + localBox.x,
        y = interactionFrame.y + localBox.y,
        width = localBox.width,
        height = localBox.height,
      }
      for y = box.y, box.y + box.height - 1 do
        for x = box.x, box.x + box.width - 1 do
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
    Assert.equal(
      sourceDiffs({ x = 24, y = 102, width = 80, height = 14 }),
      0,
      versionId .. " leaves its empty third move slot exactly as staged"
    )
    Assert.equal(
      sourceDiffs({ x = 152, y = 101, width = 80, height = 14 }),
      0,
      versionId .. " leaves its empty fourth move slot exactly as staged"
    )
    Assert.isTrue(sourceDiffs({ x = 100, y = 169, width = 56, height = 12 }) > 5, versionId .. " prints its Back label")

    local moveIcons = MoveIconCache.loadManifest(cacheFs)
    local iconAnchors = {
      { x = 32, y = 61 },
      { x = 160, y = 60 },
      { x = 32, y = 124 },
      { x = 160, y = 123 },
    }
    for slot, move in ipairs(screen:view().moves) do
      if type(move.moveType) == "string" then
        local icon = assert(
          moveIcons.types[move.moveType:lower()],
          versionId .. " carries the generated icon for " .. move.moveType
        )
        local iconSource = decodeData(scope, cacheFs, icon.image, versionId .. " " .. move.moveType .. " type icon")
        local anchor = assert(iconAnchors[slot], versionId .. " has the source anchor for move slot " .. slot)
        local originX = interactionFrame.x + anchor.x - math.floor(iconSource:getWidth() / 2)
        local originY = interactionFrame.y + anchor.y - math.floor(iconSource:getHeight() / 2)
        local iconMatches, iconOccupied = countSourceMatches(first, iconSource, {
          x = originX,
          y = originY,
          width = iconSource:getWidth(),
          height = iconSource:getHeight(),
        }, originX, originY)
        Assert.isTrue(iconOccupied > 20, versionId .. " stages an occupied " .. move.moveType .. " type icon")
        Assert.equal(
          iconMatches,
          iconOccupied,
          versionId
            .. " renders the source "
            .. move.moveType
            .. " type pixels ("
            .. tostring(iconMatches)
            .. "/"
            .. tostring(iconOccupied)
            .. ")"
        )
      end
    end
  end
end

-- Expected menu-font palette slot for a move PP value, mirroring the pinned
-- battle_input.c GetPPTextColor buckets exactly (zero, full, small-maximum
-- absolute thresholds, then quarter/half fractions for larger maxima).
---@param pp integer current PP under drawing
---@param maxPp integer maximum PP under drawing
---@return integer menu-font palette slot for the PP ink
local function sourcePpForeground(pp, maxPp)
  if pp == 0 then
    return 7
  end
  if pp == maxPp then
    return 1
  end
  if maxPp <= 2 then
    if pp == 1 then
      return 5
    end
  elseif maxPp <= 7 then
    if pp == 1 then
      return 5
    end
    if pp == 2 then
      return 3
    end
  else
    if pp <= maxPp / 4 then
      return 5
    end
    if pp <= maxPp / 2 then
      return 3
    end
  end
  return 1
end

function T.native_move_type_icon_matrix_matches_generated_visuals(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the battle captures need a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local moveIcons = MoveIconCache.loadManifest(cacheFs)
    local menuFont = assert(cacheFs:loadLua(FieldFontCache.defPath(4)), versionId .. " carries the source menu font")
    local typeKeys = {}
    for typeKey in pairs(assert(moveIcons.types, versionId .. " carries move type icons")) do
      typeKeys[#typeKeys + 1] = typeKey
    end
    table.sort(typeKeys)
    local anchors = {
      { x = 32, y = 61 },
      { x = 160, y = 60 },
      { x = 32, y = 124 },
      { x = 160, y = 123 },
    }
    local ppAnchors = {
      { x = 59, y = 61 },
      { x = 187, y = 60 },
      { x = 59, y = 124 },
      { x = 187, y = 123 },
    }
    local ppValues = { 10, 1, 0, 35 }
    for firstType = 1, #typeKeys, #anchors do
      local packet = openingPacket()
      local actor = assert(packet.request.options.actors[1], versionId .. " carries move choices")
      actor.choices = {}
      for slot = 0, #anchors - 1 do
        local typeKey = typeKeys[firstType + slot]
        if typeKey ~= nil then
          actor.choices[#actor.choices + 1] = moveChoice(
            "move:" .. tostring(slot),
            "MOVE" .. tostring(slot),
            ppValues[slot + 1],
            35,
            typeKey:upper(),
            slot
          )
        end
      end
      local screen = captureScreen(scope, cacheFs, versionId, dualMeasurement())
      drivePacketToCommand(screen, versionId, packet)
      screen:input({ { type = "confirm" } })
      Assert.equal(screen:status().mode, "moves", versionId .. " opens the source move list")
      settleMenuInput(screen, versionId)
      local view = screen:view()
      local plan = livePlan(screen, versionId)
      local width, height = canvasSize(plan, versionId)
      local interaction = nil
      for _, pane in ipairs(plan.panes) do
        if pane.id == "interaction" then
          interaction = pane.placement.frame
        end
      end
      interaction = assert(interaction, versionId .. " places the native move list")
      local capture = renderCapture(scope, screen, width, height)
      for slot, move in ipairs(view.moves) do
        if type(move.moveType) == "string" then
          local ppAnchor = assert(ppAnchors[slot], versionId .. " carries the source PP anchor")
          local foreground = sourcePpForeground(move.pp, move.maxPp)
          local color = assert(menuFont.palette[foreground + 1], versionId .. " carries PP palette slot " .. foreground)
          local ppInk = countColor(capture, {
            x = interaction.x + ppAnchor.x,
            y = interaction.y + ppAnchor.y,
            width = 16,
            height = 12,
          }, color)
          Assert.isTrue(
            ppInk > 0,
            versionId .. " draws move slot " .. tostring(slot - 1) .. " with source PP color " .. foreground
          )
          local typeKey = move.moveType:lower()
          local visual = assert(
            moveIcons.types[typeKey],
            versionId .. " carries generated " .. typeKey .. " icon pixels"
          )
          local icon = decodeData(scope, cacheFs, visual.image, versionId .. " " .. typeKey .. " type icon")
          local anchor = assert(anchors[slot], versionId .. " carries the move type anchor")
          local originX = interaction.x + anchor.x - math.floor(icon:getWidth() / 2)
          local originY = interaction.y + anchor.y - math.floor(icon:getHeight() / 2)
          local matches, occupied = countSourceMatches(
            capture,
            icon,
            { x = originX, y = originY, width = icon:getWidth(), height = icon:getHeight() },
            originX,
            originY
          )
          Assert.isTrue(occupied > 20, versionId .. " stages occupied " .. typeKey .. " icon pixels")
          Assert.equal(matches, occupied, versionId .. " renders every source " .. typeKey .. " icon pixel")
        end
      end
    end
    -- Small maxima use the source absolute PP buckets rather than the
    -- quarter/half fractions: red at 1/2 and 1/5, yellow at 2/5, plain ink
    -- at 3/6, and gray at 0/5.
    local smallMaxima = {
      { pp = 1, maxPp = 2 },
      { pp = 2, maxPp = 5 },
      { pp = 3, maxPp = 6 },
      { pp = 0, maxPp = 5 },
    }
    local smallPacket = openingPacket()
    local smallActor = assert(smallPacket.request.options.actors[1], versionId .. " carries move choices")
    smallActor.choices = {}
    for slot, values in ipairs(smallMaxima) do
      smallActor.choices[#smallActor.choices + 1] =
        moveChoice("move:" .. tostring(slot - 1), "MOVE" .. tostring(slot), values.pp, values.maxPp, "NORMAL", slot - 1)
    end
    local smallScreen = captureScreen(scope, cacheFs, versionId, dualMeasurement())
    drivePacketToCommand(smallScreen, versionId, smallPacket)
    smallScreen:input({ { type = "confirm" } })
    Assert.equal(smallScreen:status().mode, "moves", versionId .. " opens the source move list")
    settleMenuInput(smallScreen, versionId)
    local smallPlan = livePlan(smallScreen, versionId)
    local smallWidth, smallHeight = canvasSize(smallPlan, versionId)
    local smallInteraction = nil
    for _, pane in ipairs(smallPlan.panes) do
      if pane.id == "interaction" then
        smallInteraction = pane.placement.frame
      end
    end
    smallInteraction = assert(smallInteraction, versionId .. " places the native move list")
    local smallCapture = renderCapture(scope, smallScreen, smallWidth, smallHeight)
    for slot, values in ipairs(smallMaxima) do
      local ppAnchor = assert(ppAnchors[slot], versionId .. " carries the source PP anchor")
      local foreground = sourcePpForeground(values.pp, values.maxPp)
      local color = assert(menuFont.palette[foreground + 1], versionId .. " carries PP palette slot " .. foreground)
      local ppInk = countColor(smallCapture, {
        x = smallInteraction.x + ppAnchor.x,
        y = smallInteraction.y + ppAnchor.y,
        width = 16,
        height = 12,
      }, color)
      Assert.isTrue(
        ppInk > 0,
        versionId
          .. " draws small-maximum PP "
          .. tostring(values.pp)
          .. "/"
          .. tostring(values.maxPp)
          .. " with source color "
          .. foreground
      )
    end
  end
end

-- Explicit target choice is composed by the production screen from the
-- staged target surface and its typed candidate list. The source PNG is
-- decoded separately from the live renderer input; candidate state is
-- checked before and after keyboard navigation so a painted target cannot
-- drift from the choice the screen will submit.
function T.native_target_view_composes_its_staged_surface_and_candidates(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the battle captures need a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local packet = openingPacket()
    local actor = assert(packet.request.options.actors[1], versionId .. " carries its actor choices")
    local move = assert(actor.choices[1], versionId .. " carries its first move")
    move.targets = {
      {
        id = "target:2",
        position = 2,
        enabled = true,
        choice = { kind = "attack", payload = { moveSlot = 0, target = { kind = "position", position = 2 } } },
      },
      {
        id = "target:3",
        position = 3,
        enabled = true,
        choice = { kind = "attack", payload = { moveSlot = 0, target = { kind = "position", position = 3 } } },
      },
      { id = "target:locked", position = 0, enabled = false, reason = "unavailable" },
    }
    local screen = captureScreen(scope, cacheFs, versionId, dualMeasurement())
    drivePacketToCommand(screen, versionId, packet)
    screen:input({ { type = "confirm" } })
    Assert.equal(screen:status().mode, "moves", versionId .. " opens the native move surface")
    settleMenuInput(screen, versionId)
    screen:input({ { type = "confirm" } })
    Assert.equal(screen:status().mode, "target", versionId .. " opens target selection for multiple legal targets")
    local targets = screen:view().targets
    Assert.equal(#targets, 3, versionId .. " exposes every source candidate")
    Assert.equal(targets[1].id, "target:2", versionId .. " starts at the first legal target")
    Assert.isTrue(targets[1].enabled and targets[2].enabled, versionId .. " retains both legal targets")
    Assert.isFalse(targets[3].enabled, versionId .. " keeps the unavailable target disabled")

    local plan = livePlan(screen, versionId)
    local width, height = canvasSize(plan, versionId)
    local interaction = nil
    for _, pane in ipairs(plan.panes) do
      if pane.id == "interaction" then
        interaction = pane.placement.frame
      end
    end
    Assert.notNil(interaction, versionId .. " places the target surface")
    local targetMenu = assert(BattlePresentationCache.load(cacheFs).menus.target, versionId .. " carries target source")
    local source = composeMenuSource(
      scope,
      cacheFs,
      targetMenu.screens,
      versionId .. " target menu",
      assert(menuFeedbackPatch(targetMenu, "target:2", "selected"))
    )
    local idle = renderCapture(scope, screen, width, height)
    local matches, occupied = countSourceMatches(
      idle,
      source,
      { x = interaction.x, y = interaction.y, width = 256, height = 192 },
      interaction.x,
      interaction.y
    )
    Assert.isTrue(occupied > 20000, versionId .. " stages an occupied target source surface")
    Assert.isTrue(
      matches / occupied > 0.8,
      versionId .. " composes the staged target surface (" .. tostring(matches) .. "/" .. tostring(occupied) .. ")"
    )

    screen:input({ { type = "navigate", direction = "right" } })
    Assert.equal(screen:view().selection, "target:3", versionId .. " moves focus with the target identity")
    local selected = renderCapture(scope, screen, width, height)
    Assert.isTrue(
      regionDistance(idle, selected, { x = interaction.x, y = interaction.y, width = 256, height = 192 }, 1) > 10,
      versionId .. " presents target selection feedback over the source surface"
    )
    Assert.isNil(screen:status().error, versionId .. " remains drawable in target selection")
  end
end

-- The same composed command scene is captured with its ordinary and
-- unavailable Run choices. The disabled state comes from the production
-- request, and pointer-down is observed before release so pressed art is
-- tested at the same control the renderer presents.
function T.native_command_capture_tracks_disabled_and_pressed_request_state(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the battle captures need a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local enabledPacket = openingPacket()
    local disabledPacket = openingPacket()
    disabledPacket.request.options.actors[1].choices[3].enabled = false
    disabledPacket.request.options.actors[1].choices[3].reason = "blocked"

    local enabled = captureScreen(scope, cacheFs, versionId, dualMeasurement())
    drivePacketToCommand(enabled, versionId, enabledPacket)
    settleMenuInput(enabled, versionId)
    local disabled = captureScreen(scope, cacheFs, versionId, dualMeasurement())
    drivePacketToCommand(disabled, versionId, disabledPacket)
    settleMenuInput(disabled, versionId)
    Assert.isTrue(enabled:view().commands[4].enabled, versionId .. " keeps an admitted Run action enabled")
    Assert.isFalse(disabled:view().commands[4].enabled, versionId .. " carries the request's disabled Run state")

    local plan = livePlan(disabled, versionId)
    local width, height = canvasSize(plan, versionId)
    local interaction = nil
    for _, pane in ipairs(plan.panes) do
      if pane.id == "interaction" then
        interaction = pane.placement.frame
      end
    end
    Assert.notNil(interaction, versionId .. " places the command surface")
    local enabledCapture = renderCapture(scope, enabled, width, height)
    local disabledCapture = renderCapture(scope, disabled, width, height)
    Assert.equal(
      regionDistance(
        enabledCapture,
        disabledCapture,
        { x = interaction.x, y = interaction.y, width = 256, height = 192 },
        1
      ),
      0,
      versionId .. " keeps the source RUN label and tilemap when only controller legality changes"
    )

    local interactionFrame = assert(interaction, "the command menu has a touch frame")
    local sourceFightPoint = { x = interactionFrame.x + 128, y = interactionFrame.y + 83 }
    disabled:input({
      { type = "pointer_down", pointerId = "touch:command", x = sourceFightPoint.x, y = sourceFightPoint.y },
    })
    Assert.equal(disabled:view().selection, "fight", versionId .. " focuses the source Fight control")
    local pressed = renderCapture(scope, disabled, width, height)
    Assert.isTrue(
      regionDistance(disabledCapture, pressed, { x = interaction.x, y = interaction.y, width = 256, height = 192 }, 1)
        > 0,
      versionId .. " renders pressed feedback before pointer release"
    )
  end
end

function T.native_menu_feedback_states_match_generated_source_patches(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the battle captures need a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local manifest = BattlePresentationCache.load(cacheFs)
    local packet = openingPacket()
    packet.request.options.actors[1].choices[1].targets = {
      {
        id = "target:2",
        position = 2,
        enabled = true,
        choice = { kind = "attack", payload = { moveSlot = 0, target = { kind = "position", position = 2 } } },
      },
      {
        id = "target:3",
        position = 3,
        enabled = true,
        choice = { kind = "attack", payload = { moveSlot = 0, target = { kind = "position", position = 3 } } },
      },
    }
    local screen = captureScreen(scope, cacheFs, versionId, dualMeasurement())
    drivePacketToCommand(screen, versionId, packet)
    local plan = livePlan(screen, versionId)
    local frame = nil
    for _, pane in ipairs(plan.panes) do
      if pane.id == "interaction" then
        frame = pane.placement.frame
      end
    end
    frame = assert(frame, versionId .. " places its native menu surface")
    local width, height = canvasSize(plan, versionId)
    local function assertPatch(layout, controlId, state)
      local menuKey = layout == "two-option" and "twoOption" or layout
      local menu = assert(manifest.menus[menuKey], versionId .. " publishes " .. layout .. " source layers")
      local patch = nil
      for index, layer in ipairs(menu.screens) do
        local feedback = layer.feedback
        local control = type(feedback) == "table" and feedback[controlId] or nil
        local states = type(control) == "table" and control or nil
        if type(states) == "table" and type(states[state]) == "table" then
          local sourcePatch = states[state]
          patch = {
            image = sourcePatch.image,
            x = sourcePatch.x,
            y = sourcePatch.y,
            width = sourcePatch.width,
            height = sourcePatch.height,
            screenIndex = index,
          }
          break
        end
      end
      patch = assert(patch, versionId .. " publishes the " .. layout .. " " .. controlId .. " " .. state .. " patch")
      local source = composeMenuSource(
        scope,
        cacheFs,
        menu.screens,
        versionId .. " " .. layout .. " " .. controlId .. " " .. state,
        patch
      )
      local capture = renderCapture(scope, screen, width, height)
      local rect = { x = frame.x, y = frame.y, width = 256, height = 192 }
      local matches, occupied = countSourceMatches(capture, source, rect, rect.x, rect.y)
      Assert.isTrue(occupied > 20000, versionId .. " samples the composited menu planes")
      Assert.isTrue(
        matches / occupied > 0.8,
        versionId
          .. " renders the source "
          .. layout
          .. " "
          .. controlId
          .. " "
          .. state
          .. " patch ("
          .. tostring(matches)
          .. "/"
          .. tostring(occupied)
          .. ")"
      )
    end

    Assert.equal(screen:view().selection, "fight", versionId .. " starts on native Fight")
    assertPatch("command", "fight", "selected")
    screen:input({ { type = "pointer_down", pointerId = "touch:feedback", x = frame.x + 128, y = frame.y + 83 } })
    assertPatch("command", "fight", "pressed")
    screen:input({ { type = "pointer_cancel", pointerId = "touch:feedback" } })
    screen:input({ { type = "navigate", direction = "down" } })
    Assert.equal(screen:view().selection, "run", versionId .. " selects the source Run control")
    assertPatch("command", "run", "selected")

    screen:input({ { type = "navigate", direction = "up" } })
    screen:input({ { type = "confirm" } })
    settleMenuInput(screen, versionId)
    Assert.equal(screen:status().mode, "moves", versionId .. " opens the source move menu")
    Assert.isNil(screen:view().menuWindows, versionId .. " ends the source entry window before changing menu layers")
    Assert.equal(screen:view().selection, "move:0", versionId .. " selects its first native move")
    assertPatch("moves", "move:0", "selected")
    screen:input({ { type = "pointer_down", pointerId = "touch:move", x = frame.x + 64, y = frame.y + 52 } })
    assertPatch("moves", "move:0", "pressed")
    screen:input({ { type = "pointer_cancel", pointerId = "touch:move" } })
    screen:input({ { type = "confirm" } })
    Assert.equal(screen:status().mode, "target", versionId .. " opens source target selection")
    Assert.isNil(screen:view().menuWindows, versionId .. " does not carry command entry windows into target selection")
    settleMenuInput(screen, versionId)
    Assert.equal(screen:view().selection, "target:2", versionId .. " selects the first legal target")
    assertPatch("target", "target:2", "selected")
    screen:input({ { type = "pointer_down", pointerId = "touch:target", x = frame.x + 196, y = frame.y + 116 } })
    assertPatch("target", "target:2", "pressed")
    screen:dispose()
  end
end

function T.native_two_option_menu_composes_selected_and_pressed_source_pixels(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("native two-option pixels need a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local manifest = BattlePresentationCache.load(cacheFs)
    local menu = assert(manifest.menus.twoOption, versionId .. " stages its two-option source layers")
    local services = captureServices(scope, cacheFs, versionId)
    local assets = {
      drawable = function(_, key)
        return services.drawable(key)
      end,
    }
    for _, row in ipairs({
      { control = "yes", state = "selected" },
      { control = "yes", state = "pressed" },
      { control = "cancel", state = "selected" },
      { control = "cancel", state = "pressed" },
    }) do
      local patch = assert(
        menuFeedbackPatch(menu, row.control, row.state),
        versionId .. " authors the " .. row.control .. " " .. row.state .. " source patch"
      )
      local source = composeMenuSource(
        scope,
        cacheFs,
        menu.screens,
        versionId .. " two-option " .. row.control .. " " .. row.state,
        patch
      )
      local canvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true }))
      love.graphics.push("all")
      love.graphics.setCanvas(canvas)
      love.graphics.clear(0, 0, 0, 0)
      BattleMenuPresenter.draw(love.graphics, assets, "two-option", menu.screens, {
        selection = row.control,
        armed = row.state == "pressed" and { scope = "two-option", id = row.control } or nil,
      }, nil)
      love.graphics.setCanvas()
      love.graphics.pop()
      local capture = scope:own(canvas:newImageData())
      local matches, occupied = countSourceMatches(capture, source, { x = 0, y = 0, width = 256, height = 192 }, 0, 0)
      Assert.isTrue(occupied > 20000, versionId .. " samples composed two-option source planes")
      Assert.isTrue(
        matches / occupied > 0.8,
        versionId .. " renders two-option " .. row.control .. " " .. row.state .. " source state"
      )
    end
  end
end

function T.native_learning_confirmation_draws_the_live_source_menu_and_labels(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("native learning-menu composition needs a ready user-owned ROM with a derived cache")
  end
  local function sourceLabel(manifest, key)
    local record = assert(manifest.messages.entries[key], "the source menu route stages its label")
    local out = {}
    for _, token in ipairs(record.tokens) do
      if token.kind == "eos" then
        break
      elseif token.kind == "glyph" then
        out[#out + 1] = token.text
      elseif token.kind == "unsupported_control" and token.control == FieldMessageText.ALN_CENTER then
        -- The source text object centers the decoded label at x=128.
      else
        error("two-option label contains an unexpected source control", 0)
      end
    end
    return table.concat(out)
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local manifest = BattlePresentationCache.load(cacheFs)
    local route = assert(manifest.menus.routes["menu/keep-forget"], versionId .. " stages the source replacement route")
    local selectedLabels = {}
    for _, key in ipairs(route.messageEntries) do
      selectedLabels[key] = true
    end
    Assert.isTrue(
      selectedLabels["label/forget-move"] == true and selectedLabels["label/keep-move"] == true,
      versionId .. " selects both labels from the source replacement text set"
    )
    local text, windows = captureDrawServices(scope, cacheFs, versionId)
    local services = captureServices(scope, cacheFs, versionId)
    local assets = {
      drawable = function(_, key)
        return services.drawable(key)
      end,
    }
    local menu = assert(manifest.menus.twoOption, versionId .. " carries the native two-option planes")
    for _, selected in ipairs({ "confirm", "back" }) do
      local sourceControl = selected == "confirm" and "yes" or "cancel"
      local patch = assert(
        menuFeedbackPatch(menu, sourceControl, "pressed"),
        versionId .. " carries the pressed " .. sourceControl .. " source patch"
      )
      local expected = composeMenuSource(scope, cacheFs, menu.screens, versionId .. " live learn " .. selected, patch)
      local canvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true }))
      local view = {
        mode = "child",
        armed = { scope = "child", id = selected },
        childView = {
          kind = "learn",
          confirmation = { kind = "replace", slot = 0 },
          twoOption = {
            route = "menu/keep-forget",
            top = sourceLabel(manifest, "label/forget-move"),
            bottom = sourceLabel(manifest, "label/keep-move"),
          },
        },
        menuLayers = { twoOption = menu.screens },
      }
      love.graphics.push("all")
      love.graphics.setCanvas(canvas)
      love.graphics.clear(0, 0, 0, 0)
      BattleRenderer.drawPane(
        { graphics = love.graphics, assets = assets, text = text, windows = windows },
        view,
        "interaction",
        { layout = "two-option" }
      )
      love.graphics.setCanvas()
      love.graphics.pop()
      local capture = scope:own(canvas:newImageData())
      local matches, occupied = countSourceMatches(capture, expected, { x = 0, y = 0, width = 256, height = 192 }, 0, 0)
      Assert.isTrue(occupied > 20000, versionId .. " samples the production two-option composition")
      Assert.isTrue(matches / occupied > 0.8, versionId .. " matches the independent source-plane oracle")
      Assert.isTrue(
        countInk(capture, { x = 0, y = selected == "confirm" and 60 or 132, width = 256, height = 20 }) > 0,
        versionId .. " draws the source label at its native " .. selected .. " anchor"
      )
    end
  end
end

function T.native_menu_entry_slide_matches_source_pixels_at_each_tick(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("native menu slide pixels need a ready user-owned ROM with a derived cache")
  end
  local expectedEdges = { 184, 174, 164, 154, 145 }
  local expectedOutsideWidths = { 0, 63, 127, 191, 254 }
  local expectedScroll = { 1, 64, 128, 192, 255 }
  local expectedBottomScroll = { 40, -30, -20, -10, 0 }
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local screen = captureScreen(scope, cacheFs, versionId, dualMeasurement())
    drivePacketToCommand(screen, versionId, openingPacket(), false)
    local plan = livePlan(screen, versionId)
    local width, height = canvasSize(plan, versionId)
    local interaction = nil
    for _, pane in ipairs(plan.panes) do
      if pane.id == "interaction" then
        interaction = pane.placement.frame
      end
    end
    interaction = assert(interaction, versionId .. " places its sliding command planes")
    local menu = assert(BattlePresentationCache.load(cacheFs).menus.command, versionId .. " stages command planes")
    local selectedFight =
      assert(menuFeedbackPatch(menu, "fight", "selected"), versionId .. " carries the selected Fight source patch")
    for step = 0, 4 do
      local menuWindows = assert(screen:view().menuWindows, versionId .. " publishes source slide step " .. step)
      Assert.equal(
        menuWindows.edge,
        expectedEdges[step + 1],
        versionId .. " follows the source W1 edge at step " .. step .. " (actual " .. tostring(menuWindows.edge) .. ")"
      )
      Assert.equal(
        menuWindows.outsideTop.width,
        expectedOutsideWidths[step + 1],
        versionId .. " follows the source W0 width at step " .. step
      )
      for plane = 0, 1 do
        Assert.equal(menuWindows.scroll[plane].x, expectedScroll[step + 1], versionId .. " scrolls BG " .. plane)
        Assert.equal(
          menuWindows.scroll[plane].bottomY,
          expectedBottomScroll[step + 1],
          versionId .. " follows the source vertical BG offset at step " .. step
        )
      end
      local source = composeMenuSource(
        scope,
        cacheFs,
        menu.screens,
        versionId .. " command slide step " .. step,
        selectedFight,
        menuWindows
      )
      local capture = renderCapture(scope, screen, width, height)
      local rect = { x = interaction.x, y = interaction.y, width = 256, height = 192 }
      local matches, occupied = countSourceMatches(capture, source, rect, interaction.x, interaction.y)
      Assert.isTrue(occupied > 100, versionId .. " exposes source menu pixels at slide step " .. step)
      Assert.isTrue(
        matches / occupied > 0.8,
        versionId .. " composes source BG, W0/W1 and scroll state at slide step " .. step
      )
      if step < 4 then
        screen:updateFixed(1 / 30)
      end
    end
  end
end

function T.native_selection_arrow_matches_source_pixels_at_duration_boundaries(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("native arrow pixels need a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local manifest = BattlePresentationCache.load(cacheFs)
    local arrow = assert(manifest.hud.arrow, versionId .. " stages the native arrow")
    local animation = assert(arrow.animation, versionId .. " stages the authored arrow animation")
    local strip = decodeData(scope, cacheFs, arrow.image, versionId .. " arrow source pixels")
    local screen = captureScreen(scope, cacheFs, versionId, dualMeasurement())
    drivePacketToCommand(screen, versionId, openingPacket(), false)
    local plan = livePlan(screen, versionId)
    local width, height = canvasSize(plan, versionId)
    local detailFrame = nil
    for _, pane in ipairs(plan.panes) do
      if pane.id == "detail" then
        detailFrame = pane.placement.frame
      end
    end
    detailFrame = assert(detailFrame, versionId .. " places the source arrow surface")
    local slot = nil
    for _, row in ipairs(manifest.battlefield.slots) do
      if row.sideType == 0 then
        slot = row
      end
    end
    slot = assert(slot, versionId .. " stages the active player arrow anchor")
    local arrowBaseX = detailFrame.x + slot.hudX - 72
    local arrowBaseY = detailFrame.y + slot.hudY - 2
    local boundaries = {
      { tick = 0, cell = 1 },
      { tick = 3, cell = 1 },
      { tick = 4, cell = 2 },
      { tick = 7, cell = 2 },
      { tick = 8, cell = 3 },
      { tick = 11, cell = 3 },
      { tick = 12, cell = 4 },
      { tick = 27, cell = 4 },
      { tick = 28, cell = 5 },
      { tick = 33, cell = 5 },
    }
    local currentTick = 0
    for _, boundary in ipairs(boundaries) do
      while currentTick < boundary.tick do
        screen:updateFixed(1 / 30)
        currentTick = currentTick + 1
      end
      local frame = assert(animation.frames[boundary.cell + 1], versionId .. " maps the arrow animation frame")
      local cell = assert(arrow.cells[frame.cell + 1], versionId .. " stages arrow cell " .. frame.cell)
      local capture = renderCapture(scope, screen, width, height)
      local visible, occupied = 0, 0
      for _, object in ipairs(cell.objs) do
        local matches, samples = countGaugeObjectMatches(capture, strip, object, arrowBaseX, arrowBaseY)
        visible = visible + matches
        occupied = occupied + samples
      end
      Assert.isTrue(occupied > 20, versionId .. " samples source arrow cell " .. tostring(frame.cell) .. " pixels")
      Assert.isTrue(
        visible / occupied > 0.9,
        versionId
          .. " draws source arrow cell "
          .. frame.cell
          .. " at duration boundary "
          .. boundary.tick
          .. " ("
          .. tostring(visible)
          .. "/"
          .. tostring(occupied)
          .. ")"
      )
    end
    screen:dispose()
  end
end

function T.native_partner_menu_entry_slide_matches_source_pixels_at_each_tick(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("native partner menu slide pixels need a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local packet = doubledBattlePacket()
    packet.after.own[1].position = 0
    packet.after.own[2].position = 1
    packet.request.actors[1].combatant = 1
    packet.request.options.actors[1].combatant = 1
    local screen = captureScreen(scope, cacheFs, versionId, dualMeasurement())
    drivePacketToCommand(screen, versionId, packet, false)
    Assert.equal(
      screen:view().actor.sideType,
      4,
      versionId
        .. " selects the right-side player source geometry (actual "
        .. tostring(screen:view().actor.sideType)
        .. ")"
    )
    local plan = livePlan(screen, versionId)
    local width, height = canvasSize(plan, versionId)
    local interaction = nil
    for _, pane in ipairs(plan.panes) do
      if pane.id == "interaction" then
        interaction = pane.placement.frame
      end
    end
    interaction = assert(interaction, versionId .. " places the partner slide planes")
    local menu = assert(BattlePresentationCache.load(cacheFs).menus.command, versionId .. " stages command planes")
    local patch = assert(menuFeedbackPatch(menu, "fight", "selected"))
    local expectedEdge = { 184, 174, 164, 154, 145 }
    local expectedW0X = { 256, 192, 128, 64, 1 }
    local expectedW0Width = { 0, 64, 128, 192, 255 }
    local expectedScroll = { 0, 64, 128, 192, 255 }
    local expectedBottomY = { 40, -30, -20, -10, 0 }
    for step = 0, 4 do
      local windows = assert(screen:view().menuWindows, versionId .. " publishes partner slide step " .. step)
      Assert.equal(windows.edge, expectedEdge[step + 1], versionId .. " moves the partner W1 edge")
      Assert.equal(windows.outsideTop.x, expectedW0X[step + 1], versionId .. " moves the partner W0 edge")
      Assert.equal(windows.outsideTop.width, expectedW0Width[step + 1], versionId .. " clips the partner W0 window")
      for plane = 0, 1 do
        Assert.equal(windows.scroll[plane].x, expectedScroll[step + 1], versionId .. " scrolls partner BG " .. plane)
        Assert.equal(
          windows.scroll[plane].bottomY,
          expectedBottomY[step + 1],
          versionId .. " vertically scrolls partner BG " .. plane
        )
      end
      local source = composeMenuSource(
        scope,
        cacheFs,
        menu.screens,
        versionId .. " partner command slide step " .. step,
        patch,
        windows
      )
      local capture = renderCapture(scope, screen, width, height)
      local rect = { x = interaction.x, y = interaction.y, width = 256, height = 192 }
      local matches, occupied = countSourceMatches(capture, source, rect, interaction.x, interaction.y)
      Assert.isTrue(occupied > 100, versionId .. " samples partner menu planes at step " .. step)
      Assert.isTrue(
        matches / occupied > 0.8,
        versionId .. " renders source partner W0/W1 and BG offsets at step " .. step
      )
      if step < 4 then
        screen:updateFixed(1 / 30)
      end
    end
    screen:dispose()
  end
end

-- The opening packet with a reserve switch choice and its party snapshot
-- so the party child finds its eligible reserve through the real options.
---@return table delivery packet opening the staged battle with a switch
local function partyPacket()
  local packet = openingPacket()
  local actor = assert(packet.request.options.actors[1], "the staged request carries its actor")
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
---@param point table tapped logical position
local function tap(screen, point)
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
    local reference = renderCapture(scope, screen, width, height)

    local cells = assert(plan.content.commands.cells, versionId .. " carries its command cells")
    -- The first press only focuses the unselected cell (the focus turns
    -- the input identity and releases the session capture); the second
    -- press seals through the shared press convention.
    tap(screen, cellCenter(cells, "bag"))
    pump(screen, 2)
    tap(screen, cellCenter(cells, "bag"))
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
    screen:input({ { type = "navigate", direction = "up" } })
    pump(screen, 2)
    Assert.equal(screen:view().selection, "fight", versionId .. " walks back to the first command")

    local returnedPlan = livePlan(screen, versionId)
    local returned = renderCapture(scope, screen, width, height)
    local rerun = renderCapture(scope, screen, width, height)
    Assert.equal(
      imageDataDigest(returned),
      imageDataDigest(reference),
      versionId .. " restores the parent command pixels across the child return"
    )
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
      Assert.isTrue(
        countInk(returned, hostRect(frame, bar)) > 10,
        versionId .. " restores the " .. side.label .. " health bar"
      )
      Assert.equal(
        countColor(returned, hostRect(frame, bar), { 51, 204, 51 }),
        0,
        versionId .. " paints no interim tint on the returned " .. side.label .. " health bar"
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
    local reference = renderCapture(scope, screen, width, height)

    local cells = assert(plan.content.commands.cells, versionId .. " carries its command cells")
    tap(screen, cellCenter(cells, "pokemon"))
    pump(screen, 2)
    tap(screen, cellCenter(cells, "pokemon"))
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
    screen:input({ { type = "navigate", direction = "up" } })
    pump(screen, 2)
    Assert.equal(screen:view().selection, "fight", versionId .. " walks back to the first command")

    local returnedPlan = livePlan(screen, versionId)
    local returned = renderCapture(scope, screen, width, height)
    Assert.equal(
      imageDataDigest(returned),
      imageDataDigest(reference),
      versionId .. " restores the parent command pixels across the party return"
    )
    local content = assert(returnedPlan.content, versionId .. " carries its returned content")
    Assert.isTrue(
      countInk(returned, hostRect(frame, content.prompt.content)) > 100,
      versionId .. " restores its prompt text ink"
    )
    local playerBar = assert(content.hud.player.bar, versionId .. " carries its player bar")
    Assert.isTrue(countInk(returned, hostRect(frame, playerBar)) > 10, versionId .. " restores the player health bar")
    Assert.equal(
      countColor(returned, hostRect(frame, playerBar), { 51, 204, 51 }),
      0,
      versionId .. " paints no interim tint on the restored player health bar"
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
      events = {},
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
    local winnerBar = assert(content.hud.player.bar, versionId .. " carries its bar")
    Assert.isTrue(countInk(first, hostRect(frame, winnerBar)) > 10, versionId .. " keeps the winner health bar")
    Assert.equal(
      countColor(first, hostRect(frame, winnerBar), { 51, 204, 51 }),
      0,
      versionId .. " paints no interim tint on the winner health bar"
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
      {
        key = "menu:two-option",
        path = assert(manifest.menus.twoOption, versionId .. " carries two-option art").image,
      },
      { key = "arrow", path = assert(manifest.hud.arrow, versionId .. " carries the arrow").image },
      {
        key = "gauges:player",
        path = assert(manifest.hud.partyGauges[2], versionId .. " carries player gauges").image,
      },
      {
        key = "gauges:enemy",
        path = assert(manifest.hud.partyGauges[1], versionId .. " carries party gauges").image,
      },
    }) do
      local source = decodeData(scope, cacheFs, entry.path, versionId .. " " .. entry.key .. " source")
      local handle = assert(services.drawable(entry.key), versionId .. " resolves " .. entry.key)
      -- Capture drawables resolve to staged pool leases or bare staged
      -- images depending on the handle behind the key.
      local image = assert(handle.image or handle, versionId .. " carries the staged image for " .. entry.key)
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

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump" }
suite.metadata.derivedAssets = {
  "battle-presentation:global",
  "battle-scene:general/grass/day",
  "field-font:global",
  "field-ui:global",
  "mon-portrait-page:34",
  "mon-portrait-page:86",
  "mon-portrait-page:164",
}
return suite
