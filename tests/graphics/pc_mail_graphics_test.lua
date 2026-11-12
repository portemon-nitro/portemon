-- Real PC assets prove the retained Mailbox renderer draws the native
-- MailView read and write surfaces: twelve distinct write composites,
-- sentence and label text from the shared catalog, the cursor-ordered
-- pulse highlight, the top-display backdrop, and stored author/icons on
-- read. No draw-time acquisition: every state stages its exact visuals
-- through the renderer first.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local ImageAssetPool = require("libs.hgss.src.presentation.ImageAssetPool")
local PcCache = require("libs.assets.src.PcCache")
local ItemCache = require("libs.assets.src.ItemCache")
local MonCache = require("libs.assets.src.MonCache")
local ItemCatalog = require("libs.items.src.ItemCatalog")
local MonCatalog = require("libs.mons.src.MonCatalog")
local EasyChatCache = require("libs.assets.src.EasyChatCache")
local EasyChatCatalog = require("libs.hgss.src.ui.EasyChatCatalog")
local Mailbox = require("libs.hgss.src.save.Mailbox")
local MailViewInterface = require("game.hgss.src.pc.MailViewInterface")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local MailboxRenderer = require("libs.hgss.src.ui.MailboxRenderer")
local MailboxScreenState = require("game.hgss.src.pc.MailboxScreenState")
local MonIconAssetProvider = require("libs.hgss.src.presentation.MonIconAssetProvider")
local ItemIconAssetProvider = require("libs.hgss.src.presentation.ItemIconAssetProvider")
local FieldWindowRenderer = require("libs.hgss.src.ui.FieldWindowRenderer")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

-- One session image owner per version under test: mailbox chrome and
-- letter icons share one physical owner like the production composition.
---@param scope table<string, unknown> graphics ownership scope disposing the pool
---@param cacheFs CacheFs version cache the pool classifies from
---@return table<string, unknown> session image owner disposed with the scope
local function versionPool(scope, cacheFs)
  local pool = ImageAssetPool.new(cacheFs)
  scope:own({
    release = function()
      pool:dispose()
    end,
  })
  return pool
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

-- Drawing never acquires: each state stages its exact visuals through
-- the renderer first, with the same bounded wait the icon pages use.
local function prepareMailbox(renderer, state)
  local deadline = os.clock() + 120
  while true do
    local ready, failure = renderer:prepare(state:status())
    if ready then
      return
    end
    Assert.isNil(failure, "mailbox visuals prepare: " .. tostring(failure))
    Assert.isTrue(os.clock() < deadline, "mailbox visuals prepare without stalling")
    if love.timer ~= nil and love.timer.sleep ~= nil then
      love.timer.sleep(0.005)
    end
  end
end

local function measurement()
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
end

-- One complete two-substitution sentence from the shared catalog with two
-- real word identities: no identity is ever guessed.
local function twoSlotLine(catalog)
  for bank = 0, 4 do
    for number = 0, 19 do
      local template = catalog:template(bank, number)
      if template ~= nil and template.wordCount == 2 then
        local first, second = catalog.primoWords[1], catalog.primoWords[2]
        Assert.notNil(first, "the shared catalog carries its password word bank")
        Assert.notNil(second, "the shared catalog carries its password word bank")
        Assert.equal(
          catalog:messageStatus({ bank = bank, number = number, words = { first, second } }),
          "complete",
          "the shared catalog classifies the graphic sentence complete"
        )
        return { template = "mail-template:" .. bank .. ":" .. number, words = { tostring(first), tostring(second) } }
      end
    end
  end
  error("the shared catalog carries no two-substitution template", 0)
end

local function mailFixture(catalog, stationeryType)
  local line = twoSlotLine(catalog)
  return {
    schema = "g4-mail-v2",
    type = stationeryType,
    author = { trainerId = 1, name = "MISTY", gender = 1, language = 2, game = 8 },
    icons = { "CHIKORITA/f0", "CYNDAQUIL/f0", "TOTODILE/f0" },
    lines = { line, line, line },
  }
end

local function readState(manifest, letter)
  return MailboxScreenState.new({
    mode = "read",
    manifest = manifest,
    letter = letter,
    measureDisplay = measurement,
    audio = { play = function() end },
    monCatalog = {
      iconSelection = function(_, _)
        return "unused"
      end,
    },
  })
end

local function drawState(scope, resources, view, paneId)
  local canvas = scope:own(love.graphics.newCanvas(256, 192))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  resources.mailboxRenderer:drawMailPane(view, paneId, resources)
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData()):getString()
end

function T.native_write_views_render_source_chrome_text_and_pulse(scope)
  local versions = readyVersions()
  Assert.isTrue(#versions > 0, "the declared global PC cache is available")
  for _, version in ipairs(versions) do
    local pool = versionPool(scope, version.cacheFs)
    local catalog = EasyChatCatalog.new(EasyChatCache.loadCatalog(version.cacheFs))
    local renderer = scope:own(MailboxRenderer.new({
      cacheFs = version.cacheFs,
      manifest = version.manifest,
      catalog = catalog,
      graphics = love.graphics,
      imagePool = pool,
    }))
    local text = scope:own(FieldTextRenderer.new({ cacheFs = version.cacheFs, graphics = love.graphics }))
    local uiManifest = assert(version.cacheFs:loadLua(FieldUiAssetCache.manifestPath()))
    local window = scope:own(FieldWindowRenderer.new({
      cacheFs = version.cacheFs,
      manifest = uiManifest,
      graphics = love.graphics,
    }))
    local resources = {
      graphics = love.graphics,
      textRenderer = text,
      mailboxRenderer = renderer,
      windowRenderer = window,
      applicationFrameIndex = 0,
      mailViewGeometry = MailViewInterface.TEXT,
    }
    local seen = {}
    for stationeryType = 0, 11 do
      local writeDeadline = os.clock() + 120
      while true do
        local writeReady, writeFailure = renderer:prepare({ viewMode = "write", stationeryType = stationeryType })
        if writeReady then
          break
        end
        Assert.isNil(writeFailure, "write chrome prepares: " .. tostring(writeFailure))
        Assert.isTrue(os.clock() < writeDeadline, "write chrome prepares without stalling")
        if love.timer ~= nil and love.timer.sleep ~= nil then
          love.timer.sleep(0.005)
        end
      end
      -- The write interaction pane draws its native composite without
      -- any generic frame overlay: the source chrome is self-framed.
      local status = {
        mode = "write",
        stationeryType = stationeryType,
        lines = { twoSlotLine(catalog), false, false },
        focusPos = 0,
        pulseLevel = 0,
      }
      local plan = MailViewInterface.plan(measurement(), "write", {
        hitMasks = assert(version.manifest.mail.stationery[stationeryType].write).hitMasks,
      })
      Assert.equal(plan.inputKey, "mail-view", "the write screen plans its native view")
      local pixels = drawState(scope, resources, status)
      Assert.isTrue(
        pixels:find(string.char(255), 1, true) ~= nil,
        "stationery " .. stationeryType .. " paints source pixels"
      )
      Assert.isNil(seen[pixels], "each authored stationery type selects its own compiled write visual")
      seen[pixels] = true
      -- The keyboard focus highlight follows the fourteen source
      -- coefficients: the last level visibly differs from the first.
      local pulsed = drawState(scope, resources, {
        mode = "write",
        stationeryType = stationeryType,
        lines = { twoSlotLine(catalog), false, false },
        focusPos = 0,
        pulseLevel = 13,
      })
      Assert.isTrue(pulsed ~= pixels, "the pulse highlight animates its focused control")
      -- Moving the focus recolors another control: the highlight is
      -- cursor-ordered, not a static overlay.
      local refocused = drawState(scope, resources, {
        mode = "write",
        stationeryType = stationeryType,
        lines = { twoSlotLine(catalog), false, false },
        focusPos = 3,
        pulseLevel = 13,
      })
      Assert.isTrue(refocused ~= pulsed, "the focus highlight tracks the selected control")
      -- The top pane draws the repeated source backdrop, not the
      -- interaction composite.
      local top = drawState(scope, resources, { mode = "write", stationeryType = stationeryType }, "upper")
      Assert.isTrue(top:find(string.char(255), 1, true) ~= nil, "the top display raster paints source pixels")
      Assert.isTrue(top ~= pixels, "the backdrop differs from the interaction composite")
    end
  end
  love.graphics.setCanvas()
end

function T.native_read_presents_the_author_lines_and_stored_icons(scope)
  local versions = readyVersions()
  Assert.isTrue(#versions > 0, "the declared global PC cache is available")
  for _, version in ipairs(versions) do
    local pool = versionPool(scope, version.cacheFs)
    local catalog = EasyChatCatalog.new(EasyChatCache.loadCatalog(version.cacheFs))
    local renderer = scope:own(MailboxRenderer.new({
      cacheFs = version.cacheFs,
      manifest = version.manifest,
      catalog = catalog,
      graphics = love.graphics,
      imagePool = pool,
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
      imagePool = pool,
      derivedAssets = {
        requestIconPage = function()
          return true
        end,
      },
      graphics = love.graphics,
    }))
    local ready, failure
    local deadline = os.clock() + 120
    while true do
      ready, failure = iconProvider:prepareKeys(iconKeys)
      if ready or failure ~= nil then
        break
      end
      Assert.isTrue(os.clock() < deadline, "captured Mail icon pages prepare without stalling")
      if love.timer ~= nil and love.timer.sleep ~= nil then
        love.timer.sleep(0.005)
      end
    end
    Assert.isTrue(ready, "captured Mail icon pages are prepared: " .. tostring(failure))
    local resources = {
      graphics = love.graphics,
      textRenderer = text,
      mailboxRenderer = renderer,
      monIconProvider = iconProvider,
      windowRenderer = window,
      applicationFrameIndex = 0,
      mailViewGeometry = MailViewInterface.TEXT,
    }
    local letter = mailFixture(catalog, 0)
    local state = readState(version.manifest, letter)
    prepareMailbox(renderer, state)
    local read = drawState(scope, resources, state:status().view)
    Assert.isTrue(read:find(string.char(255), 1, true) ~= nil, "the read view paints source pixels")

    local blank = mailFixture(catalog, 0)
    blank.lines = { false, false, false }
    local noText = drawState(scope, resources, readState(version.manifest, blank):status().view)
    Assert.isTrue(noText ~= read, "source Mail text changes read pixels")

    blank.icons = { false, false, false }
    local noIcons = drawState(scope, resources, readState(version.manifest, blank):status().view)
    Assert.isTrue(noIcons ~= noText, "captured source icon selectors change read pixels")
  end
  love.graphics.setCanvas()
end

function T.mailbox_list_renders_rows_and_action_feedback(scope)
  local versions = readyVersions()
  Assert.isTrue(#versions > 0, "the declared global PC cache is available")
  for _, version in ipairs(versions) do
    local pool = versionPool(scope, version.cacheFs)
    local catalog = EasyChatCatalog.new(EasyChatCache.loadCatalog(version.cacheFs))
    local renderer = scope:own(MailboxRenderer.new({
      cacheFs = version.cacheFs,
      manifest = version.manifest,
      catalog = catalog,
      graphics = love.graphics,
      imagePool = pool,
    }))
    local text = scope:own(FieldTextRenderer.new({ cacheFs = version.cacheFs, graphics = love.graphics }))
    local uiManifest = assert(version.cacheFs:loadLua(FieldUiAssetCache.manifestPath()))
    local window = scope:own(FieldWindowRenderer.new({
      cacheFs = version.cacheFs,
      manifest = uiManifest,
      graphics = love.graphics,
    }))
    local itemCatalog = ItemCatalog.new(ItemCache.loadCatalog(version.cacheFs))
    local resources = {
      graphics = love.graphics,
      textRenderer = text,
      mailboxRenderer = renderer,
      windowRenderer = window,
      applicationFrameIndex = 0,
      mailViewGeometry = MailViewInterface.TEXT,
    }
    local itemProvider = scope:own(ItemIconAssetProvider.new(version.cacheFs, { graphics = love.graphics }))
    resources.itemIconProvider = itemProvider
    local mailboxSlots = {}
    for slot = 1, Mailbox.CAPACITY do
      mailboxSlots[slot] = false
    end
    mailboxSlots[1] = mailFixture(catalog, 0)
    mailboxSlots[2] = mailFixture(catalog, 1)
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
      measureDisplay = measurement,
      audio = { play = function() end },
    })
    local function drawMailbox()
      local canvas = scope:own(love.graphics.newCanvas(256, 192))
      love.graphics.setCanvas(canvas)
      love.graphics.clear(0, 0, 0, 0)
      prepareMailbox(renderer, mailboxState)
      mailboxState:draw(resources)
      love.graphics.setCanvas()
      return scope:own(canvas:newImageData()):getString()
    end
    local focusedPixels = drawMailbox()
    mailboxState:updateFixed({ { type = "navigate", direction = "down" } })
    Assert.isTrue(
      drawMailbox() ~= focusedPixels,
      "list cursor movement changes the focused source row on the shared icon/text path"
    )
    mailboxState:updateFixed({ { type = "confirm" } })
    local actionPixels = drawMailbox()
    Assert.isTrue(actionPixels ~= focusedPixels, "opening a row draws the compiled source action menu")
    mailboxState:updateFixed({ { type = "navigate", direction = "down" } })
    Assert.equal(mailboxState:status().actionIndex, 2, "action navigation advances the selected source action")
    mailboxState:dispose()
  end
  love.graphics.setCanvas()
end

local suite = GraphicsSmoke.suite(T, { capabilities = { "graphics", "rom_dump" } })
suite.metadata.derivedAssets =
  { "pc:global", "field-font:global", "field-ui:global", "items:global", "mon-summary:global", "easy-chat-data:global" }
return suite
