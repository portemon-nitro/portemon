-- Production Summary drawing and lifetime through the real composition:
-- the field presenter map draws the live menu-flow Summary without a
-- stand-in renderer, native content ignores host topology, entry and
-- exit fades keep their source recurrences, and input, preparation, and
-- disposal cannot leak across children. Real flow, real owner, real
-- renderer, and real caches throughout; sibling dispatch is preserved.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonCache = require("libs.assets.src.MonCache")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PartyCache = require("libs.assets.src.PartyCache")
local RomImporter = require("romdump.src.source.RomImporter")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local SummaryAcceptanceFixture = require("tests.support.SummaryAcceptanceFixture")
local SummaryModel = require("libs.hgss.src.ui.SummaryModel")
local SummaryRenderer = require("libs.hgss.src.ui.SummaryRenderer")

local T = {}

local OWNER_MODULE = "game.hgss.src.field.SummaryPresentationResources"
local FPR_MODULE = "game.hgss.src.field.FieldPresentationResources"

local function readyVersion()
  local versions = SummaryAcceptanceFixture.readySummaryVersions()
  Assert.isTrue(#versions >= 1, "the prepared cache publishes the Summary family")
  return versions[1]
end

local function realCatalog(cacheFs)
  local MonCatalog = require("libs.mons.src.MonCatalog")
  return MonCatalog.new(MonCache.loadCatalog(cacheFs), CatalogFixture.makeItemCatalog())
end

local function openService(catalog, seed)
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  return HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(seed):capture()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
  })
end

local function singleTopology(width, height)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = false,
    role = "world",
  })
end

---@param class string one of dualDisplay, nativeLike, wide, tall
---@return table<string, unknown> measured display facts for the class
local function measurementFor(class)
  if class == "dualDisplay" then
    return {
      width = 512,
      height = 384,
      topology = ScreenTopology.dualDisplay({
        id = "world",
        rect = { x = 0, y = 0, width = 256, height = 192 },
        role = "world",
        touch = false,
      }, {
        id = "aux",
        rect = { x = 256, y = 0, width = 256, height = 192 },
        role = "auxiliary",
        touch = true,
      }),
      pixelRatio = 1,
      signature = "summary-production-graphics:dual",
    }
  end
  if class == "wide" then
    -- Pairing needs both native panes at 1x plus their frames: 640 wide
    -- carries the pair, while 512 falls back to the nativeLike entry.
    return {
      width = 640,
      height = 384,
      topology = singleTopology(640, 384),
      pixelRatio = 1,
      signature = "summary-production-graphics:wide",
    }
  end
  if class == "tall" then
    return {
      width = 256,
      height = 384,
      topology = singleTopology(256, 384),
      pixelRatio = 1,
      signature = "summary-production-graphics:tall",
    }
  end
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
    signature = "summary-production-graphics:nativeLike",
  }
end

---@param owner table<string, unknown> field-owned Summary resource owner
---@return table<string, unknown> lease acquired through the production owner
local function ownerLease(owner)
  local lease = assert(owner:acquire(), "the field owner hands out per-open leases")
  Assert.isTrue(type(lease.prepare) == "function", "leases prepare bounded demand")
  Assert.isTrue(type(lease.release) == "function", "leases release idempotently")
  return lease
end

---@param versionId string
---@param helper table<string, unknown> preparation doubles
---@return table<string, unknown> field-owned Summary resource owner
local function requireOwner(versionId, helper)
  local ok, Owner = pcall(require, OWNER_MODULE)
  Assert.isTrue(ok, "production parent flows prepare Summary through the field resource owner: " .. tostring(Owner))
  return Owner.new(SummaryAcceptanceFixture.ownerOptions(versionId, helper))
end

-- Production party flow over the real derived family and the real mon
-- catalog: the nested Summary child below exercises the same factories,
-- lease binding, and transitions the shipped composition uses.
---@param versionId string
---@param summaryManifest table<string, unknown> validated Summary family
---@param class string host layout class under test
---@return table<string, unknown> rig driving the production party flow
local function openProductionPartyFlow(versionId, summaryManifest, class, species)
  local PokemonMenuFlow = require("game.hgss.src.field.PokemonMenuFlow")
  local BagCursor = require("libs.hgss.src.items.BagCursor")
  local HgssBagService = require("libs.hgss.src.items.HgssBagService")
  local ItemFixture = require("libs.items.tests.item_fixture")
  local PartyActions = require("libs.hgss.src.field.PartyActions")
  local cacheFs = CacheFs.forVersion(versionId)
  local helper = SummaryAcceptanceFixture.preparationDoubles({})
  local Owner = requireOwner(versionId, helper)
  local service = openService(realCatalog(cacheFs), 0x5EED5001)
  for _, name in ipairs(species or { "CHIKORITA", "TOTODILE" }) do
    SummaryAcceptanceFixture.gift(service, name, 12)
  end
  local context = SummaryAcceptanceFixture.displayContext(summaryManifest, service:partyCount())
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local leases = 0
  local measured = measurementFor(class or "nativeLike")
  local Mailbox = require("libs.hgss.src.save.Mailbox")
  local MailActions = require("libs.hgss.src.field.MailActions")
  local PcPresentationFixture = require("tests.support.PcPresentationFixture")
  local mailbox = Mailbox.new()
  local pcManifest = PcPresentationFixture.manifest()
  local flow = PokemonMenuFlow.new({
    root = "party",
    mons = service,
    bag = bag,
    bagCursor = BagCursor.new(),
    partyActions = PartyActions.new({ mons = service, bag = bag }),
    mailActions = MailActions.new({ mons = service, mailbox = mailbox, bag = bag, manifest = pcManifest }),
    mailbox = mailbox,
    pcManifest = pcManifest,
    fieldMoves = {
      check = function(_)
        return { kind = "ok" }
      end,
    },
    assets = {
      bagManifest = {},
      partyManifest = PartyCache.loadManifest(cacheFs),
      summaryManifest = summaryManifest,
      uiManifest = FieldUiFixture.manifest(),
      monCatalog = service:catalog(),
      itemCatalog = bag:catalog(),
      heroGender = "male",
    },
    measureDisplay = function()
      return measured
    end,
    prepareIcons = function(_)
      return true, nil
    end,
    cancelIconPreparation = function() end,
    textPolicy = { interGlyphDelay = 0, glyphBudget = 512, abAcceleration = true },
    summaryContext = function()
      return context
    end,
    readSummaryNavigation = function()
      return nil
    end,
    acquireSummaryPreparation = function()
      leases = leases + 1
      return ownerLease(Owner)
    end,
  })
  return {
    flow = flow,
    service = service,
    bag = bag,
    owner = Owner,
    helper = helper,
    leases = function()
      return leases
    end,
  }
end

---@param rig table<string, unknown> production flow rig
---@return table<string, unknown> live child status
local function flowChild(rig)
  local flow = assert(rig.flow, "the rig carries its production flow")
  local status = flow:status()
  Assert.isTrue(status.open, "the production menu flow stays open")
  return assert(status.child, "the production flow carries its live child")
end

---@param rig table<string, unknown> production flow rig
local function waitPartyInteractive(rig)
  for _ = 1, 30 do
    if flowChild(rig).phase == "interactive" then
      return
    end
    rig.flow:updateFixed({})
  end
  error("the production party never turns interactive", 0)
end

-- Opens the nested Summary from the production party menu and settles
-- its entry: returns the live child plus the collected exit/entry fade
-- traces for the transition-ownership assertions.
---@param rig table<string, unknown> production flow rig
---@return table<string, unknown> active summary child status
---@return integer[] summary exit brightness coefficients
---@return integer[] nested entry coefficients
local function openNestedSummary(rig)
  local flow = rig.flow
  waitPartyInteractive(rig)
  flow:updateFixed({})
  flow:updateFixed({})
  flow:updateFixed({ { type = "confirm" } })
  local child = flowChild(rig)
  Assert.equal(child.state, "context", "confirming the focused member opens its context menu")
  local menu = assert(child.menu, "the context menu stays open")
  Assert.equal(menu[1].kind, "summary", "the source party menu lists the Summary first")
  flow:updateFixed({ { type = "navigate", direction = "down" } })
  flow:updateFixed({ { type = "navigate", direction = "up" } })
  flow:updateFixed({ { type = "confirm" } })
  local staged = flow:status()
  for _ = 1, 12 do
    if staged.transition ~= nil then
      break
    end
    flow:updateFixed({})
    staged = flow:status()
  end
  Assert.notNil(staged.transition, "opening the Summary stages its exit transition")
  -- Note: assert returns its message as a second value, so the
  -- coefficient is bound alone before entering the trace table.
  local firstCoefficient = assert(staged.transition.brightnessCoefficient, "the exit carries its coefficient")
  local exitCoefficients = { firstCoefficient }
  for _ = 1, 24 do
    flow:updateFixed({})
    local status = flow:status()
    if status.transition == nil then
      break
    end
    exitCoefficients[#exitCoefficients + 1] =
      assert(status.transition.brightnessCoefficient, "the Summary exit carries its brightness coefficient")
  end
  Assert.equal(flow:status().page, "summary", "the nested Summary owns the replacement")
  local entryCoefficients = {}
  for _ = 1, 16 do
    flow:updateFixed({})
    local nested = flowChild(rig)
    if nested.entryFade ~= nil then
      entryCoefficients[#entryCoefficients + 1] = nested.entryFade
    end
    if nested.wrapperPhase == "active" then
      break
    end
  end
  local active = flowChild(rig)
  Assert.equal(active.wrapperPhase, "active", "the nested Summary turns interactive")
  return active, exitCoefficients, entryCoefficients
end

-- Test-local atlas glue: quads cut from a realized atlas image through
-- manifest entries. Production wiring owns its own provider; the renderer
-- only requires image/quadFor/dimensions.
local function atlasProvider(graphics, image, entries)
  local quads = {}
  return {
    image = function()
      return image
    end,
    quadFor = function(_, selector)
      local entry = assert(entries[selector], "atlas carries " .. tostring(selector))
      local quad = quads[selector]
      if quad == nil then
        quad = graphics.newQuad(entry.x, entry.y, entry.width, entry.height, image:getWidth(), image:getHeight())
        quads[selector] = quad
      end
      return quad
    end,
    dimensions = function(_, selector)
      local entry = assert(entries[selector], "atlas carries " .. tostring(selector))
      return { width = entry.width, height = entry.height }
    end,
  }
end

local function realizedImage(scope, cacheFs, path)
  local bytes = assert(cacheFs:read(path), "cache carries " .. path)
  local file = assert(love.filesystem.newFileData(bytes, path), "file data wraps " .. path)
  return scope:own(love.graphics.newImage(file))
end

---@param scope table<string, unknown> graphics ownership scope
---@param cacheFs table<string, unknown> version cache reader
---@return table<string, unknown> portrait provider over the realized page
local function portraitProvider(scope, cacheFs)
  local portraitManifest = assert(cacheFs:loadLua(MonCache.portraitManifestPath()), "the portrait manifest loads")
  local portraitEntries = assert(portraitManifest.entries, "the portrait manifest carries entries")
  local portraitPageId = nil
  for selector, entry in pairs(portraitEntries) do
    if tostring(selector):find("CHIKORITA", 1, true) then
      portraitPageId = entry.pageId
      break
    end
  end
  Assert.notNil(portraitPageId, "the portrait manifest carries the exercised mon")
  local portraitPage = assert(portraitManifest.pages[portraitPageId], "the exercised portrait page loads")
  return atlasProvider(love.graphics, realizedImage(scope, cacheFs, portraitPage.image), portraitEntries)
end

---@param scope table<string, unknown> graphics ownership scope
---@param renderer table<string, unknown> Summary renderer under test
---@param status table<string, unknown> stable native status
---@param pane string "main" or "sub"
---@param assets table<string, unknown> ready resource bundle
---@return table<string, unknown> 256x192 native pixel buffer
local function drawNativePane(scope, renderer, status, pane, assets)
  local canvas = scope:own(love.graphics.newCanvas(256, 192))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  renderer:drawPane(status, pane, assets)
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

local function countLit(image, x0, y0, x1, y1)
  local lit = 0
  for y = y0, y1 do
    for x = x0, x1 do
      local _, _, _, a = image:getPixel(x, y)
      if a > 0.5 then
        lit = lit + 1
      end
    end
  end
  return lit
end

local function paneDifference(first, second)
  local differing = 0
  for y = 0, 191 do
    for x = 0, 255 do
      local r1, g1, b1, a1 = first:getPixel(x, y)
      local r2, g2, b2, a2 = second:getPixel(x, y)
      if math.abs(r1 - r2) + math.abs(g1 - g2) + math.abs(b1 - b2) + math.abs(a1 - a2) > 0.01 then
        differing = differing + 1
      end
    end
  end
  return differing
end

---@param actual integer[] collected coefficients
---@param expected integer[] source recurrence
---@param label string trace owner for failure diagnostics
local function assertCoefficients(actual, expected, label)
  local parts = {}
  for index, value in ipairs(actual) do
    parts[#parts + 1] = tostring(value)
  end
  Assert.equal(
    #actual,
    #expected,
    label .. " fades exactly " .. #expected .. " frames; got {" .. table.concat(parts, ",") .. "}"
  )
  for index, value in ipairs(expected) do
    Assert.equal(
      actual[index],
      value,
      label .. " frame " .. index .. " carries its source coefficient; got {" .. table.concat(parts, ",") .. "}"
    )
  end
end

---@param scope table<string, unknown> graphics ownership scope
---@return table<string, unknown> compiled production picture shader
local function pictureShader(scope)
  local shaderPath = "libs/hgss/src/ui/shaders/summary_picture.glsl"
  local source = love.filesystem.read(shaderPath)
  if source == nil then
    local handle = io.open(love.filesystem.getSourceBaseDirectory() .. "/" .. shaderPath, "rb")
    Assert.notNil(handle, "the picture shader source loads")
    source = handle:read("*a")
    handle:close()
  end
  Assert.notNil(source, "the picture shader source loads")
  return scope:own(love.graphics.newShader(source))
end

-- Ready-bundle-shaped test assembly over realized cache art: named
-- visuals resolve through the manifest to canonical path-owned images
-- while unmapped source roles stay absent instead of gaining invented
-- substitutes. The bundle never carries party-family presentation.
---@param scope table<string, unknown> graphics ownership scope
---@param cacheFs table<string, unknown> version cache reader
---@param manifest table<string, unknown> validated Summary family
---@param text table<string, unknown> field text collaborator
---@param portraits table<string, unknown> portrait provider
---@param shader table<string, unknown> compiled picture shader
---@return table<string, unknown> ready-bundle-shaped test bundle
local function readyLikeBundle(scope, cacheFs, manifest, text, portraits, shader)
  local images = {}
  local bundle = { manifest = manifest, portraits = portraits, text = text, shader = shader }
  function bundle.visualImage(name)
    local visuals = assert(manifest.visuals, "the compiled family carries its visuals")
    local record = visuals[name]
    if record == nil then
      return nil
    end
    local key = "visual:" .. name
    local image = images[key]
    if image == nil then
      image = realizedImage(scope, cacheFs, assert(record.image, name .. " carries its image path"))
      images[key] = image
    end
    return image
  end
  function bundle.imageForPath(path)
    local key = "path:" .. tostring(path)
    local image = images[key]
    if image == nil then
      image = realizedImage(scope, cacheFs, path)
      images[key] = image
    end
    return image
  end
  return bundle
end

-- Production presenter dispatch through the real field presentation
-- owner: every constructor collaborator is doubled except the Summary
-- renderer itself, so any drawn Summary pixel must come from production
-- code. A test-only injected renderer cannot satisfy this scenario.
local FPR_CONSTRUCTOR_MODULES = {
  "libs.assets.src.BagCache",
  "libs.assets.src.PartyCache",
  "libs.hgss.src.presentation.BagHeroRenderer",
  "libs.hgss.src.ui.BagRenderer",
  "libs.hgss.src.ui.FieldDialogueRenderer",
  "libs.hgss.src.ui.FieldMenuRenderer",
  "libs.hgss.src.ui.FieldSignpostRenderer",
  "libs.hgss.src.ui.FieldTextRenderer",
  "libs.hgss.src.presentation.FieldStaticEffectRenderer",
  "libs.hgss.src.presentation.FieldActorEmoteRenderer",
  "libs.hgss.src.presentation.FieldTerrainEffectRenderer",
  "libs.hgss.src.presentation.GpuAssetPool",
  "libs.hgss.src.presentation.FieldRenderer",
  "libs.hgss.src.ui.FieldWindowRenderer",
  "libs.hgss.src.ui.StartMenuRenderer",
  "libs.hgss.src.ui.TrainerCardRenderer",
  "libs.hgss.src.ui.PartyScreenRenderer",
  "libs.hgss.src.ui.NamingScreenRenderer",
  "libs.hgss.src.ui.MartRenderer",
  "libs.hgss.src.presentation.MonIconAssetProvider",
  "libs.hgss.src.presentation.AssetPreparationQueue",
  "libs.hgss.src.presentation.ItemIconAssetProvider",
  "libs.hgss.src.presentation.FollowingMonTransitionRenderer",
}

---@return table<string, unknown> generic constructor double tolerating any borrowed use
local function genericInstance()
  local instance = {}
  setmetatable(instance, {
    __index = function(self, key)
      if key == "release" or key == "dispose" then
        local function forget(_) end
        self[key] = forget
        return forget
      end
      local function ignore(_)
        return nil
      end
      self[key] = ignore
      return ignore
    end,
  })
  return instance
end

---@param calls table<string, integer> construction counters
---@return table<string, table<string, unknown>> module doubles
local function fprDoubles(calls)
  local modules = {
    ["libs.assets.src.BagCache"] = {
      loadManifest = function(_)
        return { compiled = true }
      end,
    },
    ["libs.assets.src.PartyCache"] = {
      loadManifest = function(_)
        return { compiled = true }
      end,
    },
  }
  for _, name in ipairs(FPR_CONSTRUCTOR_MODULES) do
    if modules[name] == nil then
      modules[name] = {
        new = function(_)
          calls[name] = (calls[name] or 0) + 1
          return genericInstance()
        end,
      }
    end
  end
  return modules
end

---@param versionId string
---@return table<string, unknown> production-shaped presentation runtime over the real cache
local function fprRuntime(versionId)
  local runtime = {
    cacheFs = CacheFs.forVersion(versionId),
    uiManifest = FieldUiFixture.manifest(),
    playerData = { options = { textFrame = 0 } },
    windowStyles = {},
    fieldEntranceIndicatorAsset = {
      model = {},
      effects = { surf_attachment = { presentation = {}, model = {} } },
    },
    fieldEmoteModels = {},
    fieldEffectAssets = {},
    fieldTerrainEffectController = {
      setModelFactory = function(_, _) end,
    },
  }
  runtime.derivedAssets = {}
  runtime.bindPartyIconPreparation = function(_, _, _)
    return 1
  end
  runtime.unbindPartyIconPreparation = function(_, _) end
  -- The recording summary seam mirrors the production runtime binding:
  -- one live acquire callback with an identity, removed only by its own
  -- identity so a stale unbind can never drop a replacement owner.
  runtime.bindSummaryCalls = 0
  runtime.unbindSummaryCalls = {}
  runtime.bindSummaryPreparation = function(_, acquire)
    assert(type(acquire) == "function", "summary preparation binding requires its acquire function")
    assert(runtime._summaryPreparation == nil, "one summary preparation binding owns the presented lifetime")
    runtime.bindSummaryCalls = runtime.bindSummaryCalls + 1
    runtime._summaryPreparation = { id = runtime.bindSummaryCalls, acquire = acquire }
    return runtime._summaryPreparation.id
  end
  runtime.unbindSummaryPreparation = function(_, binding)
    runtime.unbindSummaryCalls[#runtime.unbindSummaryCalls + 1] = binding
    local current = runtime._summaryPreparation
    if current ~= nil and current.id == binding then
      runtime._summaryPreparation = nil
    end
  end
  return runtime
end

-- Builds the real presentation owner with doubled constructors, swaps the
-- host graphics for a recording fake, and runs the callback. The Summary
-- renderer module itself is never doubled.
---@param versionId string
---@param graphics table<string, unknown> recording graphics namespace
---@param callback fun(resources: table<string, unknown>)
local function withRealPresenters(versionId, graphics, callback)
  local calls = {}
  local modules = fprDoubles(calls)
  local saved = {}
  for _, name in ipairs(FPR_CONSTRUCTOR_MODULES) do
    saved[name] = package.loaded[name]
    package.loaded[name] = modules[name]
  end
  package.loaded[FPR_MODULE] = nil
  local savedLove = rawget(_G, "love")
  local runtime = fprRuntime(versionId)
  -- The fake swaps the graphics device only: cache/filesystem reads
  -- stay real so presenter construction can acquire its artifacts
  -- while every draw records through the fake.
  rawset(_G, "love", { graphics = graphics, filesystem = savedLove.filesystem })
  local ok, err = pcall(function()
    local FieldPresentationResources = require(FPR_MODULE)
    local resources = FieldPresentationResources.new(runtime)
    callback(resources)
    resources:dispose()
  end)
  rawset(_G, "love", savedLove)
  for _, name in ipairs(FPR_CONSTRUCTOR_MODULES) do
    package.loaded[name] = saved[name]
  end
  package.loaded[FPR_MODULE] = nil
  if not ok then
    error(err, 0)
  end
end

function T.production_presenters_draw_the_live_summary_without_a_stand_in(scope)
  local versionId = readyVersion()
  local cacheFs = CacheFs.forVersion(versionId)
  local _, summaryManifest = SummaryAcceptanceFixture.loadSummaryManifest(versionId)
  local rig = openProductionPartyFlow(versionId, summaryManifest, "nativeLike")
  local active, exitCoefficients, entryCoefficients = openNestedSummary(rig)
  assertCoefficients(exitCoefficients, { 0, 2, 5, 7, 10, 13, 16 }, "the Summary exit")
  assertCoefficients(entryCoefficients, { 16, 14, 11, 9, 6, 3, 0 }, "the nested entry")
  rig.flow:updateFixed({ { type = "navigate", direction = "right" } })
  active = flowChild(rig)
  Assert.equal(active.group, "skills", "the nested Summary reaches its second native group")

  -- Native pixels from the live production child through the real
  -- renderer: both 256x192 surfaces draw, differ, and repeat
  -- identically, so no draw-time state hides behind the first frame.
  local text = FieldTextRenderer.new({ cacheFs = cacheFs })
  local renderer = SummaryRenderer.new({ text = text })
  local assets =
    readyLikeBundle(scope, cacheFs, summaryManifest, text, portraitProvider(scope, cacheFs), pictureShader(scope))
  local main = drawNativePane(scope, renderer, active, "main", assets)
  local sub = drawNativePane(scope, renderer, active, "sub", assets)
  Assert.isTrue(
    paneDifference(main, sub) > 1000,
    "the production child draws distinct main and sub surfaces for one group"
  )
  Assert.isTrue(
    countLit(main, 168, 64, 248, 144) > 200,
    "the production child centers the large picture on the main pane"
  )
  local again = drawNativePane(scope, renderer, active, "sub", assets)
  Assert.equal(paneDifference(sub, again), 0, "repeated drawing during stable state repeats identically")
  text:release()

  -- The presenter map routes the same live flow status through its real
  -- Summary branch: the previous missing-plan error cannot recur.
  local FakeGraphics = require("tests.support.FakeGraphics")
  local graphics = FakeGraphics.new({})
  local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
  withRealPresenters(versionId, graphics, function(resources)
    local ok, err = pcall(resources.drawApplication, resources, FieldApplicationIds.POKEMON, rig.flow:status(), {})
    Assert.isTrue(ok, "production presenters draw the native Summary: " .. tostring(err))
    Assert.isTrue(#graphics.rectangles + #graphics.draws > 0, "the real presenter leaves drawn Summary output behind")
  end)

  -- The sibling Party still dispatches through the same map after the
  -- Summary journey: closing returns to a drawable party.
  rig.flow:updateFixed({ { type = "cancel" } })
  for _ = 1, 24 do
    if rig.flow:status().page == "party_browse" then
      break
    end
    rig.flow:updateFixed({})
  end
  Assert.equal(rig.flow:status().page, "party_browse", "closing the Summary returns to the party")
  waitPartyInteractive(rig)
  withRealPresenters(versionId, graphics, function(resources)
    local ok, err = pcall(resources.drawApplication, resources, FieldApplicationIds.POKEMON, rig.flow:status(), {})
    -- Sibling Party detail pixels stay owned by the dedicated Party
    -- suites; here the contract is dispatch: the same map that drew
    -- the Summary still routes its Party branch without error.
    Assert.isTrue(ok, "the sibling Party keeps its dispatch: " .. tostring(err))
  end)
  Assert.equal(rig.leases(), 1, "the journey holds one preparation lease for its Summary")
  rig.flow:dispose()
  rig.owner:release()
end

function T.native_content_ignores_host_topology_with_a_guarded_fallback()
  local versionId = readyVersion()
  local _, summaryManifest = SummaryAcceptanceFixture.loadSummaryManifest(versionId)
  local contents = {}
  for _, class in ipairs({ "dualDisplay", "wide", "tall", "nativeLike" }) do
    local rig = openProductionPartyFlow(versionId, summaryManifest, class)
    local active = openNestedSummary(rig)
    local plan = assert(active.presentation, "the wrapper publishes its pane plan")
    Assert.equal(plan.inputKey, "summary", "native plans carry the Summary input role")
    local byId = {}
    for _, pane in ipairs(assert(plan.panes, "the plan carries its panes")) do
      byId[pane.id] = pane
    end
    local main = assert(byId.main, class .. " exposes the native main pane")
    local sub = assert(byId.sub, class .. " exposes the native sub pane")
    local mainPlacement = assert(main.placement, class .. " places its main pane")
    local subPlacement = assert(sub.placement, class .. " places its sub pane")
    if class == "wide" then
      Assert.isTrue(mainPlacement.x < subPlacement.x, "wide keeps the main pane left of the sub pane")
    elseif class == "tall" then
      Assert.isTrue(mainPlacement.y < subPlacement.y, "tall keeps the main pane above the sub pane")
    end
    contents[class] = plan.content
    rig.flow:dispose()
    rig.owner:release()
  end
  Assert.deepEqual(contents.wide, contents.tall, "native content is identical before host placement")
  Assert.deepEqual(contents.tall, contents.nativeLike, "native content ignores the host aspect ratio")
  Assert.deepEqual(contents.nativeLike, contents.dualDisplay, "native content ignores the host topology")

  -- The too-small pair cannot keep 1x logical resolution, so it keeps
  -- the existing nativeLike fallback instead of distorting widgets.
  local SummaryScreenState = require("game.hgss.src.field.SummaryScreenState")
  local service = openService(realCatalog(CacheFs.forVersion(versionId)), 0x5EED5002)
  SummaryAcceptanceFixture.gift(service, "CHIKORITA", 12)
  local context = SummaryAcceptanceFixture.displayContext(summaryManifest, service:partyCount())
  local helper = SummaryAcceptanceFixture.preparationDoubles({})
  local owner = requireOwner(versionId, helper)
  local small = {
    width = 512,
    height = 256,
    topology = singleTopology(512, 256),
    pixelRatio = 1,
    signature = "summary-production-graphics:wide-too-small",
  }
  local lease = ownerLease(owner)
  local state = SummaryScreenState.new({
    mons = service,
    manifest = summaryManifest,
    initialSlot = 0,
    measureDisplay = function()
      return small
    end,
    mode = "summary",
    context = function()
      return context
    end,
    readNavigation = function()
      return nil
    end,
    acquirePreparation = function()
      return lease
    end,
  })
  for _ = 1, 24 do
    state:updateFixed({})
    if state:status().wrapperPhase == "active" then
      break
    end
  end
  local fallback = state:status()
  Assert.equal(fallback.wrapperPhase, "active", "the too-small wrapper still activates")
  local fallbackPlan = assert(fallback.presentation, "the too-small wrapper publishes its pane plan")
  Assert.isTrue(fallbackPlan.nativeLike == true, "too-small wide falls back to the nativeLike entry")
  state:dispose()
  owner:release()
end

function T.input_preparation_and_disposal_cannot_leak_across_children()
  local versionId = readyVersion()
  local _, summaryManifest = SummaryAcceptanceFixture.loadSummaryManifest(versionId)

  -- Held repeat stays source-local: the field keeps its 18/4 cadence
  -- while the Summary controller repeats held root input after 8 ticks
  -- and every 4 after, and picker/detail phases answer fresh presses
  -- only.
  local FieldInput = require("libs.hgss.src.field.FieldInput")
  Assert.equal(FieldInput.UI_REPEAT_DELAY_TICKS, 18, "sibling UI repeat keeps its 18-tick start")
  Assert.equal(FieldInput.UI_REPEAT_INTERVAL_TICKS, 4, "sibling UI repeat keeps its 4-tick interval")
  local field = FieldInput.new()
  field:beginUi(0)
  field:pressDirection("south", "test-pad")
  local firstRepeat = nil
  for tick = 0, 24 do
    for _, event in ipairs(field:uiSnapshot(tick)) do
      if event.type == "navigate" and tick > 0 and firstRepeat == nil then
        firstRepeat = tick
      end
    end
  end
  Assert.equal(firstRepeat, 18, "held field input repeats at its own start tick")
  local SummaryController = require("libs.hgss.src.ui.SummaryController")
  Assert.equal(SummaryController.REPEAT_START_TICKS, 8, "the Summary repeats held input after 8 ticks")
  Assert.equal(SummaryController.REPEAT_INTERVAL_TICKS, 4, "the Summary repeats every 4 ticks after")
  local catalog = CatalogFixture.makeCatalog()
  local service = openService(catalog, 0x5EED5003)
  SummaryAcceptanceFixture.gift(service, "CHIKORITA", 12)
  SummaryAcceptanceFixture.gift(service, "TOTODILE", 12)
  local synContext = SummaryAcceptanceFixture.displayContext(summaryManifest, service:partyCount())
  local heldCalls = 0
  local browsing = SummaryController.new({
    mode = "summary",
    model = {
      refresh = function(slot)
        return SummaryModel.build(service, slot, synContext, summaryManifest)
      end,
    },
    reorderMoves = function()
      error("repeat proof publishes nothing", 0)
    end,
    resolveLayout = function()
      return {
        hitTest = function()
          return nil
        end,
      }
    end,
    manifest = summaryManifest,
    readNavigation = function()
      heldCalls = heldCalls + 1
      return { tick = heldCalls - 1, active = true, heldDirection = "right" }
    end,
  })
  browsing:updateFixed({})
  Assert.equal(browsing:status().group, "info", "a fresh press acts once without repeating early")
  for _ = 1, 7 do
    browsing:updateFixed({})
  end
  Assert.equal(browsing:status().group, "info", "held input stays silent before the 8-tick start")
  browsing:updateFixed({})
  Assert.equal(browsing:status().group, "skills", "held input repeats at the 8-tick start")
  for _ = 1, 3 do
    browsing:updateFixed({})
  end
  Assert.equal(browsing:status().group, "skills", "held input stays silent inside the interval")
  browsing:updateFixed({})
  Assert.equal(browsing:status().group, "performance", "held input repeats every 4 ticks after")
  browsing:dispose()
  local picking = SummaryController.new({
    mode = "move_pick",
    request = { context = "pp_restore" },
    model = {
      refresh = function(slot)
        return SummaryModel.build(service, slot, synContext, summaryManifest)
      end,
    },
    resolveLayout = function()
      return {
        hitTest = function()
          return nil
        end,
      }
    end,
    manifest = summaryManifest,
    readNavigation = function()
      return { tick = 99, active = true, heldDirection = "down" }
    end,
  })
  for _ = 1, 12 do
    picking:updateFixed({})
  end
  Assert.equal(picking:status().moveSlot, 0, "the picker answers fresh presses only under a held sample")
  picking:dispose()

  -- Preparation leases stay per-open under the real owner: a second
  -- wrapper takes its own lease, releasing the first never cancels the
  -- replacement, disposal is exactly-once, and stable frames schedule
  -- no further demand.
  local SummaryScreenState = require("game.hgss.src.field.SummaryScreenState")
  local leases, prepares, releases = 0, 0, 0
  local helper = SummaryAcceptanceFixture.preparationDoubles({})
  local owner = requireOwner(versionId, helper)
  local measured = measurementFor("nativeLike")
  local portraitsBefore = #helper.calls.portraitPages
  local function openCounted(initialSlot)
    local context = SummaryAcceptanceFixture.displayContext(summaryManifest, service:partyCount())
    local lease = ownerLease(owner)
    leases = leases + 1
    local inner = lease
    local counted = {}
    function counted:prepare(demand)
      prepares = prepares + 1
      return inner:prepare(demand)
    end
    function counted:release()
      releases = releases + 1
      return inner:release()
    end
    return SummaryScreenState.new({
      mons = service,
      manifest = summaryManifest,
      initialSlot = initialSlot,
      measureDisplay = function()
        return measured
      end,
      mode = "summary",
      context = function()
        return context
      end,
      readNavigation = function()
        return nil
      end,
      acquirePreparation = function()
        return counted
      end,
    })
  end
  local first = openCounted(0)
  for _ = 1, 24 do
    first:updateFixed({})
    if first:status().wrapperPhase == "active" then
      break
    end
  end
  Assert.equal(first:status().wrapperPhase, "active", "the first wrapper activates")
  local preparesAtActive = prepares
  for _ = 1, 4 do
    first:updateFixed({})
    first:status()
  end
  Assert.equal(prepares, preparesAtActive, "stable frames schedule no further demand")
  local portraitDelta = #helper.calls.portraitPages - portraitsBefore
  Assert.isTrue(
    portraitDelta >= 1 and portraitDelta <= service:partyCount(),
    "cold portrait demand is bounded by the roster; got " .. portraitDelta .. " page requests"
  )
  for _ = 1, 4 do
    first:updateFixed({})
  end
  Assert.equal(
    #helper.calls.portraitPages - portraitsBefore,
    portraitDelta,
    "stable frames request no further portrait pages"
  )
  local second = openCounted(1)
  for _ = 1, 24 do
    second:updateFixed({})
    if second:status().wrapperPhase == "active" then
      break
    end
  end
  Assert.equal(second:status().wrapperPhase, "active", "the replacement activates beside the first")
  Assert.equal(leases, 2, "each open holds its own lease")
  first:dispose()
  first:dispose()
  Assert.equal(releases, 1, "disposal releases exactly once")
  Assert.equal(second:status().wrapperPhase, "active", "releasing the old lease never cancels the replacement")
  Assert.equal(second:status().slot, 1, "the replacement keeps its own member")
  second:dispose()
  Assert.equal(releases, 2, "each lease releases exactly once")
  owner:release()

  -- A failed preparation surfaces explicitly and still cancels cleanly
  -- instead of hanging on an indefinite screen.
  local failingOwner = requireOwner(versionId, SummaryAcceptanceFixture.preparationDoubles({ portrait = true }))
  local failingLease = ownerLease(failingOwner)
  local failingContext = SummaryAcceptanceFixture.displayContext(summaryManifest, service:partyCount())
  local failing = SummaryScreenState.new({
    mons = service,
    manifest = summaryManifest,
    initialSlot = 0,
    measureDisplay = function()
      return measured
    end,
    mode = "summary",
    context = function()
      return failingContext
    end,
    readNavigation = function()
      return nil
    end,
    acquirePreparation = function()
      return failingLease
    end,
  })
  for _ = 1, 12 do
    failing:updateFixed({})
    if failing:status().wrapperPhase == "failed" then
      break
    end
  end
  local failed = failing:status()
  Assert.equal(failed.wrapperPhase, "failed", "an unavailable portrait fails explicitly")
  Assert.isTrue(
    type(failed.preparationError) == "string" and failed.preparationError ~= "",
    "the failure names its cause"
  )
  failing:updateFixed({ { type = "cancel" } })
  Assert.equal(failing:takeResult().kind, "cancelled", "the failed child still cancels cleanly")
  failing:dispose()
  failingOwner:release()

  -- Resizing discards the host overlay and any held press without
  -- touching native group, member, or picture state.
  local mutable = measurementFor("nativeLike")
  local overlayContext = SummaryAcceptanceFixture.displayContext(summaryManifest, service:partyCount())
  local overlayOwner = requireOwner(versionId, SummaryAcceptanceFixture.preparationDoubles({}))
  local overlayState = SummaryScreenState.new({
    mons = service,
    manifest = summaryManifest,
    initialSlot = 0,
    measureDisplay = function()
      return mutable
    end,
    mode = "summary",
    context = function()
      return overlayContext
    end,
    readNavigation = function()
      return nil
    end,
    acquirePreparation = function()
      return ownerLease(overlayOwner)
    end,
  })
  for _ = 1, 24 do
    overlayState:updateFixed({})
    if overlayState:status().wrapperPhase == "active" then
      break
    end
  end
  Assert.equal(overlayState:status().wrapperPhase, "active", "the inspection wrapper activates")
  local epoch = overlayState:status().pictureEpoch
  overlayState:updateFixed({ { type = "menu" } })
  overlayState:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(overlayState:status().group, "info", "hidden sub input suspends under the overlay")
  Assert.equal(overlayState:status().pictureEpoch, epoch, "hidden input advances no picture")
  mutable = {
    width = 256,
    height = 192,
    topology = mutable.topology,
    pixelRatio = 1,
    signature = "summary-production-graphics:resized",
  }
  overlayState:updateFixed({})
  overlayState:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(overlayState:status().group, "skills", "resizing closes the overlay before native input")
  Assert.equal(overlayState:status().pictureEpoch, epoch, "resizing restarts no picture")
  Assert.equal(overlayState:status().slot, 0, "resizing keeps the displayed member")
  overlayState:dispose()
  overlayOwner:release()
end

-- The live production Summary child draws through the ready bundle
-- shape without party-family presentation: no party manifest, badge
-- images, or icon strip rides the bundle, member chrome comes from
-- Summary roles alone, and both native panes draw distinctly and
-- repeat identically.
function T.production_summary_draws_through_the_ready_bundle_without_party_graft(scope)
  local versionId = readyVersion()
  local cacheFs = CacheFs.forVersion(versionId)
  local _, summaryManifest = SummaryAcceptanceFixture.loadSummaryManifest(versionId)
  local rig = openProductionPartyFlow(versionId, summaryManifest, "nativeLike")
  local active = openNestedSummary(rig)
  for _ = 1, 30 do
    if active.facts ~= nil and active.group ~= nil then
      break
    end
    rig.flow:updateFixed({})
    active = flowChild(rig)
  end
  Assert.notNil(active.facts, "the nested Summary publishes its display facts")
  Assert.equal(active.group, "info", "the nested Summary opens on its first native group")
  local text = FieldTextRenderer.new({ cacheFs = cacheFs })
  local renderer = SummaryRenderer.new({ text = text })
  local bundle =
    readyLikeBundle(scope, cacheFs, summaryManifest, text, portraitProvider(scope, cacheFs), pictureShader(scope))
  Assert.isNil(bundle.partyManifest, "the ready bundle carries no party manifest")
  Assert.isNil(bundle.badgeImage, "the ready bundle carries no party badge images")
  Assert.isNil(bundle.icons, "the ready bundle carries no party icon strip")
  local main = drawNativePane(scope, renderer, active, "main", bundle)
  local sub = drawNativePane(scope, renderer, active, "sub", bundle)
  Assert.isTrue(
    paneDifference(main, sub) > 1000,
    "the production child draws distinct main and sub surfaces through the ready bundle"
  )
  Assert.isTrue(
    countLit(main, 168, 64, 248, 144) > 200,
    "the production child centers the large picture through the ready bundle"
  )
  local again = drawNativePane(scope, renderer, active, "sub", bundle)
  Assert.equal(paneDifference(sub, again), 0, "the production child repeats its sub pane identically")
  text:release()
  rig.flow:dispose()
  rig.owner:release()
end

-- The live production Summary draws its member focus chrome through the
-- ready bundle: switching between identical members moves Summary-owned
-- cursor pixels on the sub pane while every other pixel stays stable,
-- and the journey holds one preparation lease before returning to the
-- party.
function T.production_summary_moves_member_chrome_through_its_ready_bundle(scope)
  local versionId = readyVersion()
  local cacheFs = CacheFs.forVersion(versionId)
  local _, summaryManifest = SummaryAcceptanceFixture.loadSummaryManifest(versionId)
  local rig = openProductionPartyFlow(versionId, summaryManifest, "nativeLike", { "CHIKORITA", "CHIKORITA" })
  local active = openNestedSummary(rig)
  for _ = 1, 30 do
    if active.facts ~= nil and active.group ~= nil then
      break
    end
    rig.flow:updateFixed({})
    active = flowChild(rig)
  end
  Assert.notNil(active.facts, "the nested Summary publishes its display facts")
  Assert.equal(active.group, "info", "the nested Summary opens on its first native group")
  local text = FieldTextRenderer.new({ cacheFs = cacheFs })
  local renderer = SummaryRenderer.new({ text = text })
  local assets =
    readyLikeBundle(scope, cacheFs, summaryManifest, text, portraitProvider(scope, cacheFs), pictureShader(scope))
  local main = drawNativePane(scope, renderer, active, "main", assets)
  local first = drawNativePane(scope, renderer, active, "sub", assets)
  Assert.isTrue(
    paneDifference(main, first) > 1000,
    "the production child draws distinct main and sub surfaces"
  )
  rig.flow:updateFixed({ { type = "navigate", direction = "down" } })
  active = flowChild(rig)
  Assert.equal(active.slot, 1, "vertical input reaches the second member")
  local second = drawNativePane(scope, renderer, active, "sub", assets)
  Assert.isTrue(
    paneDifference(first, second) > 20,
    "switching members moves the member focus chrome"
  )
  text:release()
  rig.flow:updateFixed({ { type = "cancel" } })
  for _ = 1, 24 do
    if rig.flow:status().page == "party_browse" then
      break
    end
    rig.flow:updateFixed({})
  end
  Assert.equal(rig.flow:status().page, "party_browse", "closing the Summary returns to the party")
  Assert.equal(rig.leases(), 1, "the journey holds one preparation lease for its Summary")
  rig.flow:dispose()
  rig.owner:release()
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump" }
suite.metadata.derivedAssets =
  { "summary:global", "mon-catalog:global", "mon-summary:global", "field-font:global", "party:global" }
return suite
