-- Real PC assets prove the retained Mailbox renderer selects all stationery backgrounds.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local PcCache = require("libs.assets.src.PcCache")
local ItemCache = require("libs.assets.src.ItemCache")
local MonCache = require("libs.assets.src.MonCache")
local ItemCatalog = require("libs.items.src.ItemCatalog")
local MonCatalog = require("libs.mons.src.MonCatalog")
local Mailbox = require("libs.hgss.src.save.Mailbox")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local MailboxRenderer = require("libs.hgss.src.ui.MailboxRenderer")
local MailboxScreenState = require("game.hgss.src.pc.MailboxScreenState")
local MonIconAssetProvider = require("libs.hgss.src.presentation.MonIconAssetProvider")
local ItemIconAssetProvider = require("libs.hgss.src.presentation.ItemIconAssetProvider")
local FieldWindowRenderer = require("libs.hgss.src.ui.FieldWindowRenderer")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local function iconQueue(cacheFs)
  local nextToken = 0
  local pending = {}
  local queue = {}
  function queue:request(kind, path, priority)
    Assert.equal(kind, "image")
    Assert.equal(priority, "demand")
    nextToken = nextToken + 1
    pending[nextToken] = path
    return nextToken
  end
  function queue:poll(token)
    Assert.isTrue(pending[token] ~= nil, "only a requested icon page is polled")
    return "ready"
  end
  function queue:take(token)
    local path = assert(pending[token])
    pending[token] = nil
    local bytes = assert(cacheFs:read(path))
    local data = assert(love.filesystem.newFileData(bytes, path))
    return { imageData = assert(love.image.newImageData(data)) }
  end
  function queue:cancel(token)
    pending[token] = nil
  end
  return queue
end

local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    local cacheFs = CacheFs.forVersion(versionId)
    local marker = cacheFs:read(PcCache.markerPath())
    if marker ~= nil and PcCache.isReady(cacheFs, marker) then
      versions[#versions + 1] = { id = versionId, cacheFs = cacheFs, manifest = PcCache.loadManifest(cacheFs) }
    end
  end
  return versions
end

local function mailFixture(manifest, stationeryType)
  local selectedTemplate
  for key, tokens in pairs(assert(manifest.mail.text.templates)) do
    local substitutions = 0
    for _, token in ipairs(tokens) do
      substitutions = substitutions + (token.kind == "substitution" and 1 or 0)
    end
    if substitutions == 2 then
      selectedTemplate = key
      break
    end
  end
  assert(selectedTemplate, "compiled Mail templates include the two EC field slots")
  local dictionary = assert(manifest.mail.wordDictionary)
  local wordKeys = {}
  for wordKey in pairs(dictionary) do
    wordKeys[#wordKeys + 1] = tostring(wordKey)
  end
  table.sort(wordKeys, function(left, right)
    return tonumber(left) < tonumber(right)
  end)
  Assert.isTrue(#wordKeys >= 2, "compiled Mail dictionary includes authored Easy Chat words")
  local line = { template = selectedTemplate, words = { wordKeys[1], wordKeys[2] } }
  return {
    schema = "g4-mail-v1",
    type = stationeryType,
    author = { trainerId = 1, name = "MISTY", gender = 1, language = 2, game = 8 },
    icons = {
      { species = "CHIKORITA", form = 0, palette = 2 },
      { species = "CYNDAQUIL", form = 0, palette = 0 },
      { species = "TOTODILE", form = 0, palette = 1 },
    },
    lines = { line, line, line },
  }
end

function T.twelve_compiled_stationery_backgrounds_render_distinct_source_pixels(scope)
  local versions = readyVersions()
  Assert.isTrue(#versions > 0, "the declared global PC cache is available")
  for _, version in ipairs(versions) do
    local renderer = scope:own(MailboxRenderer.new({
      cacheFs = version.cacheFs,
      manifest = version.manifest,
      graphics = love.graphics,
    }))
    local text = scope:own(FieldTextRenderer.new({ cacheFs = version.cacheFs, graphics = love.graphics }))
    local uiManifest = assert(version.cacheFs:loadLua(FieldUiAssetCache.manifestPath()))
    local window = scope:own(FieldWindowRenderer.new({
      cacheFs = version.cacheFs,
      manifest = uiManifest,
      graphics = love.graphics,
    }))
    local itemCatalog = ItemCatalog.new(ItemCache.loadCatalog(version.cacheFs))
    local monCatalog = MonCatalog.new(MonCache.loadCatalog(version.cacheFs), itemCatalog)
    local iconKeys = {
      monCatalog:iconSelection({ species = "CHIKORITA", form = 0 }),
      monCatalog:iconSelection({ species = "CYNDAQUIL", form = 0 }),
      monCatalog:iconSelection({ species = "TOTODILE", form = 0 }),
    }
    local iconProvider = scope:own(MonIconAssetProvider.new(version.cacheFs, {
      preparationQueue = iconQueue(version.cacheFs),
      derivedAssets = {
        requestIconPage = function()
          return true
        end,
      },
      graphics = love.graphics,
    }))
    local ready, failure
    for _ = 1, 8 do
      ready, failure = iconProvider:prepareKeys(iconKeys)
      if ready or failure ~= nil then
        break
      end
    end
    Assert.isTrue(ready, "captured Mail icon pages are prepared: " .. tostring(failure))
    local resources = {
      textRenderer = text,
      mailboxRenderer = renderer,
      monIconProvider = iconProvider,
      windowRenderer = window,
      applicationFrameIndex = 0,
    }
    local seen = {}
    local renderedStationery = {}
    for stationeryType = 0, 11 do
      local canvas = scope:own(love.graphics.newCanvas(256, 192))
      love.graphics.setCanvas(canvas)
      love.graphics.clear(0, 0, 0, 0)
      local state = MailboxScreenState.new({
        mode = "read",
        manifest = version.manifest,
        letter = mailFixture(version.manifest, stationeryType),
        measureDisplay = function()
          return {
            width = 256,
            height = 192,
            topology = ScreenTopology.oneDisplay({
              id = "main",
              rect = { x = 0, y = 0, width = 256, height = 192 },
              role = "world",
              touch = true,
            }),
            pixelRatio = 1,
            signature = "pc-mail-graphics:256x192",
          }
        end,
        audio = { play = function() end },
        monCatalog = monCatalog,
      })
      state:draw(resources)
      love.graphics.setCanvas()
      local pixels = scope:own(canvas:newImageData()):getString()
      Assert.isTrue(pixels:find(string.char(255), 1, true), "stationery " .. stationeryType .. " paints source pixels")
      Assert.isNil(seen[pixels], "each authored stationery type selects its own compiled visual")
      seen[pixels] = true
      if stationeryType == 0 then
        renderedStationery[0] = pixels
      end
      state:dispose()
    end
    local letter = mailFixture(version.manifest, 0)
    letter.lines = { false, false, false }
    local noText = scope:own(love.graphics.newCanvas(256, 192))
    love.graphics.setCanvas(noText)
    love.graphics.clear(0, 0, 0, 0)
    local noTextState = MailboxScreenState.new({
      mode = "read",
      manifest = version.manifest,
      letter = letter,
      measureDisplay = function()
        return {
          width = 256,
          height = 192,
          topology = ScreenTopology.oneDisplay({
            id = "main",
            rect = { x = 0, y = 0, width = 256, height = 192 },
            role = "world",
            touch = true,
          }),
          pixelRatio = 1,
          signature = "pc-mail-graphics:256x192",
        }
      end,
      audio = { play = function() end },
      monCatalog = monCatalog,
    })
    noTextState:draw(resources)
    love.graphics.setCanvas()
    local noTextPixels = scope:own(noText:newImageData()):getString()
    Assert.isTrue(noTextPixels ~= renderedStationery[0], "source Mail text changes stationery pixels")
    noTextState:dispose()

    letter.icons = { false, false, false }
    local noIcons = scope:own(love.graphics.newCanvas(256, 192))
    love.graphics.setCanvas(noIcons)
    love.graphics.clear(0, 0, 0, 0)
    local noIconsState = MailboxScreenState.new({
      mode = "read",
      manifest = version.manifest,
      letter = letter,
      measureDisplay = function()
        return {
          width = 256,
          height = 192,
          topology = ScreenTopology.oneDisplay({
            id = "main",
            rect = { x = 0, y = 0, width = 256, height = 192 },
            role = "world",
            touch = true,
          }),
          pixelRatio = 1,
          signature = "pc-mail-graphics:256x192",
        }
      end,
      audio = { play = function() end },
      monCatalog = monCatalog,
    })
    noIconsState:draw(resources)
    love.graphics.setCanvas()
    Assert.isTrue(
      scope:own(noIcons:newImageData()):getString() ~= noTextPixels,
      "captured source icon selections change stationery pixels"
    )
    noIconsState:dispose()

    local itemProvider = scope:own(ItemIconAssetProvider.new(version.cacheFs, { graphics = love.graphics }))
    resources.itemIconProvider = itemProvider
    local mailboxSlots = {}
    for slot = 1, Mailbox.CAPACITY do
      mailboxSlots[slot] = false
    end
    mailboxSlots[1] = mailFixture(version.manifest, 0)
    mailboxSlots[2] = mailFixture(version.manifest, 1)
    local mailbox = Mailbox.new({ schema = Mailbox.SCHEMA, slots = mailboxSlots })
    local mailboxState = MailboxScreenState.new({
      mode = "mailbox",
      partyHasMembers = true,
      mailbox = mailbox,
      mailActions = {
        revisionSnapshot = function()
          return {}
        end,
      },
      itemCatalog = itemCatalog,
      manifest = version.manifest,
      measureDisplay = function()
        return {
          width = 256,
          height = 192,
          topology = ScreenTopology.oneDisplay({
            id = "main",
            rect = { x = 0, y = 0, width = 256, height = 192 },
            role = "world",
            touch = true,
          }),
          pixelRatio = 1,
          signature = "pc-mail-graphics:256x192",
        }
      end,
      audio = { play = function() end },
    })
    local focused = scope:own(love.graphics.newCanvas(256, 192))
    love.graphics.setCanvas(focused)
    love.graphics.clear(0, 0, 0, 0)
    mailboxState:draw(resources)
    love.graphics.setCanvas()
    local focusedPixels = scope:own(focused:newImageData()):getString()
    mailboxState:updateFixed({ { type = "navigate", direction = "down" } })
    local moved = scope:own(love.graphics.newCanvas(256, 192))
    love.graphics.setCanvas(moved)
    love.graphics.clear(0, 0, 0, 0)
    mailboxState:draw(resources)
    love.graphics.setCanvas()
    Assert.isTrue(
      scope:own(moved:newImageData()):getString() ~= focusedPixels,
      "list cursor movement changes the focused source row on the shared icon/text path"
    )
    mailboxState:updateFixed({ { type = "confirm" } })
    local actionMenu = scope:own(love.graphics.newCanvas(256, 192))
    love.graphics.setCanvas(actionMenu)
    love.graphics.clear(0, 0, 0, 0)
    mailboxState:draw(resources)
    love.graphics.setCanvas()
    local actionPixels = scope:own(actionMenu:newImageData()):getString()
    Assert.isTrue(actionPixels ~= focusedPixels, "opening a row draws the compiled source action menu")
    mailboxState:updateFixed({ { type = "navigate", direction = "down" } })
    Assert.equal(mailboxState:status().actionIndex, 2, "action navigation advances the selected source action")
    local movedAction = scope:own(love.graphics.newCanvas(256, 192))
    love.graphics.setCanvas(movedAction)
    love.graphics.clear(0, 0, 0, 0)
    mailboxState:draw(resources)
    love.graphics.setCanvas()
    local actionImage = scope:own(actionMenu:newImageData())
    local movedActionImage = scope:own(movedAction:newImageData())
    local function pixelAt(data, x, y)
      local r, g, b, a = data:getPixel(x, y)
      return table.concat({ r, g, b, a }, ",")
    end
    Assert.isTrue(
      pixelAt(actionImage, 100, 46) ~= pixelAt(movedActionImage, 100, 46),
      "action cursor leaves its first source row after moving down"
    )
    Assert.isTrue(
      pixelAt(movedActionImage, 100, 62) ~= pixelAt(actionImage, 100, 62),
      "action cursor reaches the next source row after moving down"
    )
    Assert.isTrue(
      movedActionImage:getString() ~= actionPixels,
      "action navigation moves the rendered focus through the compiled menu labels"
    )

    local emptyPartyState = MailboxScreenState.new({
      mode = "mailbox",
      partyHasMembers = false,
      mailbox = mailbox,
      mailActions = {
        revisionSnapshot = function()
          return {}
        end,
      },
      itemCatalog = itemCatalog,
      manifest = version.manifest,
      measureDisplay = function()
        return {
          width = 256,
          height = 192,
          topology = ScreenTopology.oneDisplay({
            id = "main",
            rect = { x = 0, y = 0, width = 256, height = 192 },
            role = "world",
            touch = true,
          }),
          pixelRatio = 1,
          signature = "pc-mail-graphics:256x192",
        }
      end,
      audio = { play = function() end },
    })
    emptyPartyState:updateFixed({ { type = "confirm" } })
    Assert.deepEqual(emptyPartyState:status().menuActions, { "read", "cancel" })
    local emptyPartyMenu = scope:own(love.graphics.newCanvas(256, 192))
    love.graphics.setCanvas(emptyPartyMenu)
    love.graphics.clear(0, 0, 0, 0)
    emptyPartyState:draw(resources)
    love.graphics.setCanvas()
    Assert.isTrue(
      scope:own(emptyPartyMenu:newImageData()):getString() ~= actionPixels,
      "empty Party renders the compiled two-action source menu"
    )
    emptyPartyState:updateFixed({ { type = "navigate", direction = "down" } })
    Assert.equal(emptyPartyState:status().action, "cancel", "empty Party focus reaches the final source action")
    emptyPartyState:dispose()
    mailboxState:dispose()
  end
  love.graphics.setCanvas()
end

local suite = GraphicsSmoke.suite(T, { capabilities = { "graphics", "rom_dump" } })
suite.metadata.derivedAssets =
  { "pc:global", "field-font:global", "field-ui:global", "items:global", "mon-summary:global" }
return suite
