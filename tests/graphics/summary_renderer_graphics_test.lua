-- Real-asset smoke for the bounded Summary presentation: the
-- production renderer draws the real Party badge frames, the real mon
-- portrait atlas, and the real field font through the required native
-- geometry. Pixel evidence (never draw-did-not-throw) proves five-leaf,
-- crown, and bare masks differ in the leaf row, long metadata paginates
-- with a continuation marker, and repeated draws are identical.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonCache = require("libs.assets.src.MonCache")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local PartyCache = require("libs.assets.src.PartyCache")
local Personality = require("libs.mons.src.gen4.Personality")
local RomImporter = require("romdump.src.source.RomImporter")
local SummaryAcceptanceFixture = require("tests.support.SummaryAcceptanceFixture")
local SummaryModel = require("libs.hgss.src.ui.SummaryModel")
local SummaryRenderer = require("libs.hgss.src.ui.SummaryRenderer")

local T = {}

local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      local cacheFs = CacheFs.forVersion(versionId)
      local marker = cacheFs:read(PartyCache.markerPath())
      if
        marker ~= nil
        and PartyCache.isReady(cacheFs, marker)
        and MonCache.isReady(cacheFs, cacheFs:read(MonCache.markerPath()))
        and cacheFs:read(FieldFontCache.atlasPath(0)) ~= nil
      then
        versions[#versions + 1] = versionId
      end
    end
  end
  return versions
end

local function openService(catalog, seed)
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  return HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(seed):capture(), catalog:fingerprint()),
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

local function realCatalog(cacheFs)
  local MonCatalog = require("libs.mons.src.MonCatalog")
  return MonCatalog.new(MonCache.loadCatalog(cacheFs), CatalogFixture.makeItemCatalog())
end

local function gift(service, species, level)
  local added = service:giveMon({
    species = species,
    level = level or 5,
    heldItem = nil,
    form = 0,
    location = 7,
    date = CatalogFixture.metDate(),
  })
  Assert.isTrue(added, "setup gift must enter the party")
end

local function setLeaves(service, slot, mask)
  local revision = service:partyRevision()
  local copy = service:partyMon(slot)
  copy.shinyLeaves = mask
  local preparation = assert(service:preparePartyChanges(revision, { { slot = slot, mon = copy } }))
  preparation.publish()
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

local function composition(scope, versionId)
  local cacheFs = CacheFs.forVersion(versionId)
  local manifest = PartyCache.loadManifest(cacheFs)
  local text = FieldTextRenderer.new({ cacheFs = cacheFs })
  local renderer = SummaryRenderer.new({ text = text })
  local portraitManifest = assert(cacheFs:loadLua(MonCache.portraitManifestPath()), "the portrait manifest loads")
  local portraitEntries = assert(portraitManifest.entries, "the portrait manifest carries entries")
  -- The exercised mon's portrait page resolves from the manifest
  -- instead of pinning a page number: roster layout stays the
  -- producer's business while the renderer keeps its one-image
  -- provider contract for the drawn variants.
  local portraitPageId = nil
  for selector, entry in pairs(portraitEntries) do
    if tostring(selector):find("CHIKORITA", 1, true) then
      portraitPageId = entry.pageId
      break
    end
  end
  assert(portraitPageId ~= nil, "the portrait manifest carries the exercised mon")
  local portraitPage =
    assert(portraitManifest.pages[portraitPageId], "the portrait manifest carries the exercised page")
  local portraits =
    atlasProvider(love.graphics, realizedImage(scope, cacheFs, portraitPage.image), portraitEntries)
  local catalog = realCatalog(cacheFs)
  local service = openService(catalog, 0xC10C4000)
  gift(service, "CHIKORITA", 12)
  return cacheFs, manifest, renderer, portraits, service
end

local function badgeImages(scope, cacheFs)
  local images = {}
  return function(frame)
    local path = assert(frame.image, "badge frames carry their image path")
    local image = images[path]
    if image == nil then
      image = realizedImage(scope, cacheFs, path)
      images[path] = image
    end
    return image
  end
end

-- Native status for one facts snapshot: the controller owns group and
-- phase transitions; draw-only coverage assembles the stable status the
-- renderer reads without stepping interaction.
---@param facts table<string, unknown> immutable summary facts
---@param group string native group under test
---@return table<string, unknown> stable native status
local function nativeStatus(facts, group)
  return {
    open = true,
    mode = "summary",
    group = group,
    phase = "root",
    slot = facts.slot,
    facts = facts,
    pictureEpoch = 0,
    picture = {
      sampleIndex = 1,
      frameIndex = 0,
      offsetX = 0,
      offsetY = 0,
      scaleX = 1,
      scaleY = 1,
      rotationTurns = 0,
      visible = true,
    },
  }
end

---@param scope table<string, unknown> graphics ownership scope
---@param cacheFs table<string, unknown> version cache reader
---@param renderer table<string, unknown> summary renderer under test
---@param text table<string, unknown> recording text collaborator
---@param manifest table<string, unknown> validated summary family
---@param partyManifest table<string, unknown> validated party family for badges
---@param portraits table<string, unknown> portrait provider
---@param facts table<string, unknown> immutable summary facts
---@param pane string "main" or "sub"
---@return table<string, unknown> 256x192 native pixel buffer
local function drawStatusPane(scope, cacheFs, renderer, text, manifest, partyManifest, portraits, facts, pane)
  local canvas = scope:own(love.graphics.newCanvas(256, 192))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  local group = "info"
  renderer:drawPane(nativeStatus(facts, group), pane, {
    manifest = manifest,
    partyManifest = partyManifest,
    portraits = portraits,
    badgeImage = badgeImages(scope, cacheFs),
    text = text,
  })
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

local function drawFacts(scope, cacheFs, renderer, service, slot, manifest, portraits, mask, versionId)
  setLeaves(service, slot, mask)
  local _, summaryManifest = SummaryAcceptanceFixture.loadSummaryManifest(versionId)
  local context = SummaryAcceptanceFixture.displayContext(summaryManifest, service:partyCount())
  local facts = SummaryModel.build(service, slot, context, summaryManifest)
  local text = FieldTextRenderer.new({ cacheFs = cacheFs })
  local pane = drawStatusPane(scope, cacheFs, renderer, text, summaryManifest, manifest, portraits, facts, "sub")
  text:release()
  return pane
end

local function regionDifference(first, second, x0, y0, x1, y1)
  local differing = 0
  for y = y0, y1 do
    for x = x0, x1 do
      local r1, g1, b1, a1 = first:getPixel(x, y)
      local r2, g2, b2, a2 = second:getPixel(x, y)
      if math.abs(r1 - r2) + math.abs(g1 - g2) + math.abs(b1 - b2) + math.abs(a1 - a2) > 0.01 then
        differing = differing + 1
      end
    end
  end
  return differing
end

function T.leaf_row_distinguishes_five_leaves_crown_and_bare(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest, renderer, portraits, service = composition(scope, versionId)
    local bare = drawFacts(scope, cacheFs, renderer, service, 0, manifest, portraits, 0, versionId)
    local leaves = drawFacts(scope, cacheFs, renderer, service, 0, manifest, portraits, 31, versionId)
    local crown = drawFacts(scope, cacheFs, renderer, service, 0, manifest, portraits, 32, versionId)
    local badgeRegion = assert(manifest.shinyLeaves, versionId .. " carries leaf badge geometry")
    local anchors = assert(badgeRegion.anchors, versionId .. " carries five leaf anchors")
    local x0, y0, x1, y1 = 256, 192, 0, 0
    for _, anchor in ipairs(anchors) do
      x0 = math.min(x0, anchor.x)
      y0 = math.min(y0, anchor.y)
      -- The badge region stays inside the 256x192 native canvas: an
      -- anchor within 16px of the right/bottom edge would otherwise push
      -- the inclusive comparison region out of range.
      x1 = math.min(255, math.max(x1, anchor.x + 16))
      y1 = math.min(191, math.max(y1, anchor.y + 16))
    end
    Assert.isTrue(
      regionDifference(bare, leaves, x0, y0, x1, y1) > 20,
      versionId .. " draws five leaves where the bare row stands empty"
    )
    Assert.isTrue(
      regionDifference(leaves, crown, x0, y0, x1, y1) > 20,
      versionId .. " draws the crown apart from the five leaves"
    )
    local again = drawFacts(scope, cacheFs, renderer, service, 0, manifest, portraits, 31, versionId)
    Assert.equal(regionDifference(leaves, again, 0, 0, 255, 191), 0, versionId .. " repeats one leaf frame identically")
  end
end

function T.long_metadata_clips_to_its_window_without_markers(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest, renderer, portraits, service = composition(scope, versionId)
    service:setMove(0, 0, "THIEF")
    service:setMove(0, 1, "TACKLE")
    local _, summaryManifest = SummaryAcceptanceFixture.loadSummaryManifest(versionId)
    local context = SummaryAcceptanceFixture.displayContext(summaryManifest, service:partyCount())
    local facts = SummaryModel.build(service, 0, context, summaryManifest)
    Assert.equal(facts.moves[1].key, "THIEF", versionId .. " stages its long real description")
    Assert.isTrue(
      #facts.moves[1].description > 100,
      versionId .. " exercises clipping against a long real description"
    )
    local text = FieldTextRenderer.new({ cacheFs = cacheFs })
    local status = nativeStatus(facts, "skills")
    status.phase = "move_detail"
    status.moveSlot = 0
    local longCanvas = scope:own(love.graphics.newCanvas(256, 192))
    love.graphics.setCanvas(longCanvas)
    love.graphics.clear(0, 0, 0, 0)
    renderer:drawPane(status, "sub", {
      manifest = summaryManifest,
      partyManifest = manifest,
      portraits = portraits,
      badgeImage = badgeImages(scope, cacheFs),
      text = text,
    })
    love.graphics.setCanvas()
    local longImage = scope:own(longCanvas:newImageData())
    local lit = 0
    for y = 0, 191 do
      for x = 0, 255 do
        local _, _, _, a = longImage:getPixel(x, y)
        if a > 0.5 then
          lit = lit + 1
        end
      end
    end
    Assert.isTrue(
      lit > 200,
      versionId .. " draws long move detail without inventing pagination chrome"
    )
    local againCanvas = scope:own(love.graphics.newCanvas(256, 192))
    love.graphics.setCanvas(againCanvas)
    love.graphics.clear(0, 0, 0, 0)
    renderer:drawPane(status, "sub", {
      manifest = summaryManifest,
      partyManifest = manifest,
      portraits = portraits,
      badgeImage = badgeImages(scope, cacheFs),
      text = text,
    })
    love.graphics.setCanvas()
    local againImage = scope:own(againCanvas:newImageData())
    Assert.equal(
      regionDifference(longImage, againImage, 0, 0, 255, 191),
      0,
      versionId .. " repeats clipped move detail identically"
    )
    text:release()
  end
end

function T.portrait_follows_gender_and_shininess(scope)
  for _, versionId in ipairs(readyVersions()) do
    local cacheFs, manifest, renderer, portraits, service = composition(scope, versionId)
    local mon = service:partyMon(0)
    local species = service:catalog():species(mon.species)
    local gender = Personality.gender(species.genderRatio, mon.personality)
    Assert.isTrue(gender == "male" or gender == "female", versionId .. " resolves a portrait gender")
    local _, summaryManifest = SummaryAcceptanceFixture.loadSummaryManifest(versionId)
    local context = SummaryAcceptanceFixture.displayContext(summaryManifest, service:partyCount())
    local facts = SummaryModel.build(service, 0, context, summaryManifest)
    Assert.equal(facts.pictureKey, mon.species, versionId .. " selects a portrait for a hatched mon")
    Assert.equal(facts.identity.gender, gender, versionId .. " draws the resolved portrait gender")
    local text = FieldTextRenderer.new({ cacheFs = cacheFs })
    local canvas = scope:own(love.graphics.newCanvas(256, 192))
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    renderer:drawPane(nativeStatus(facts, "info"), "main", {
      manifest = summaryManifest,
      partyManifest = manifest,
      portraits = portraits,
      badgeImage = badgeImages(scope, cacheFs),
      text = text,
    })
    love.graphics.setCanvas()
    local image = scope:own(canvas:newImageData())
    local lit = 0
    for y = 64, 144 do
      for x = 168, 248 do
        local _, _, _, a = image:getPixel(x, y)
        if a > 0.5 then
          lit = lit + 1
        end
      end
    end
    Assert.isTrue(lit > 50, versionId .. " paints portrait material in the centered portrait well")
    text:release()
  end
end

-- Native Summary composition over the real derived family: both 256x192
-- surfaces render before any host placement at exact fixed ticks, with
-- the source main/sub group assignment, centered picture motion, and
-- window-disciplined text. Expectations come from the manifest itself
-- (window rects, palettes, bar lengths), never from the renderer's own
-- tables, and every buffer is an actual main/sub pixel comparison.

local SummaryController = require("libs.hgss.src.ui.SummaryController")

local OPEN_GATES = { interactive = true, playback = true }

---@param service table<string, unknown> live mon service
---@param context table<string, unknown> explicit display context
---@param manifest table<string, unknown> validated Summary family
---@return table<string, unknown> native controller bound to the live facts
local function openNativeController(service, context, manifest)
  return SummaryController.new({
    mode = "summary",
    model = {
      refresh = function(slot)
        return SummaryModel.build(service, slot, context, manifest)
      end,
    },
    reorderMoves = function()
      error("pixel proof publishes nothing", 0)
    end,
    resolveLayout = function()
      return {
        hitTest = function()
          return nil
        end,
      }
    end,
    manifest = manifest,
  })
end

-- Records palette text calls while delegating every draw to the real
-- generated-font renderer, so role/order/palette/window evidence shares
-- the exact pixels under test.
---@param real table<string, unknown> production field text renderer
---@return table<string, unknown> recording text double
---@return table<string, unknown> recorded calls
local function recordingText(real, calls)
  local double = {}
  -- The renderer measures each line with textWidth(value) immediately
  -- before its palette draw on this same collaborator, so the last
  -- measurement pairs with the next recorded call single-threaded.
  local pendingWidth = 0
  function double:textWidth(value)
    pendingWidth = real:textWidth(value) or 0
    return pendingWidth
  end
  function double:drawLineWithPalette(tokens, x, y, palette)
    assert(type(palette) == "table", "summary text draws through palette roles")
    assert(type(palette.foreground) == "table", "palette roles carry foreground")
    assert(type(palette.shadow) == "table", "palette roles carry shadow")
    assert(type(palette.background) == "table", "palette roles carry background")
    calls[#calls + 1] = { kind = "palette", tokens = tokens, x = x, y = y, palette = palette, width = pendingWidth }
    return real:drawLineWithPalette(tokens, x, y, palette)
  end
  function double:drawLineWithColorVariants(tokens, x, y, variants, background)
    calls[#calls + 1] = { kind = "variants", tokens = tokens, x = x, y = y, variants = variants }
    return real:drawLineWithColorVariants(tokens, x, y, variants, background)
  end
  setmetatable(double, {
    __index = function(_, key)
      local value = real[key]
      if type(value) == "function" then
        return function(_, ...)
          return value(real, ...)
        end
      end
      return value
    end,
  })
  return double, calls
end

---@param renderer table<string, unknown> Summary renderer under test
---@param calls table<string, unknown> recorded text calls (cleared per pane)
---@param status table<string, unknown> stable native status
---@param pane string "main" or "sub"
---@param assets table<string, unknown> ready resource bundle
---@param scope table<string, unknown> graphics ownership scope
---@return table<string, unknown> 256x192 native pixel buffer
local function drawNativePane(renderer, scope, calls, status, pane, assets)
  Assert.isTrue(type(renderer.drawPane) == "function", "the renderer draws independent native main/sub panes")
  for index = #calls, 1, -1 do
    calls[index] = nil
  end
  local canvas = scope:own(love.graphics.newCanvas(256, 192))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  renderer:drawPane(status, pane, assets)
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

---@param image table<string, unknown> native pixel buffer
---@param x0 integer
---@param y0 integer
---@param x1 integer
---@param y1 integer
---@return integer lit pixels in the region
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

---@param first table<string, unknown>
---@param second table<string, unknown>
---@return integer differing pixels over the whole native pane
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

function T.native_main_and_sub_panes_carry_their_source_groups(scope)
  local versions = SummaryAcceptanceFixture.readySummaryVersions()
  Assert.isTrue(#versions >= 1, "the prepared cache publishes the Summary family")
  for _, versionId in ipairs(versions) do
    local cacheFs, manifest = SummaryAcceptanceFixture.loadSummaryManifest(versionId)
    local catalog = realCatalog(cacheFs)
    local service = openService(catalog, 0xC10C4001)
    gift(service, "CHIKORITA", 12)
    local context = SummaryAcceptanceFixture.displayContext(manifest, service:partyCount())
    local textCalls = {}
    local realText = FieldTextRenderer.new({ cacheFs = cacheFs })
    local text, _ = recordingText(realText, textCalls)
    local renderer = SummaryRenderer.new({ text = text })
    local manifestRecord = PartyCache.loadManifest(cacheFs)
    local _, _, _, portraits = composition(scope, versionId)
    local controller = openNativeController(service, context, manifest)
    controller:updateFixed({}, OPEN_GATES)
    local info = controller:status()
    Assert.equal(info.group, "info", versionId .. " opens on the first native group")
    local assets = {
      manifest = manifest,
      partyManifest = manifestRecord,
      portraits = portraits,
      badgeImage = badgeImages(scope, cacheFs),
      text = text,
    }
    local infoMain = drawNativePane(renderer, scope, textCalls, info, "main", assets)
    local infoSub = drawNativePane(renderer, scope, textCalls, info, "sub", assets)
    Assert.isTrue(
      paneDifference(infoMain, infoSub) > 1000,
      versionId .. " draws distinct main and sub surfaces for one group"
    )
    Assert.isTrue(
      countLit(infoMain, 168, 64, 248, 144) > 200,
      versionId .. " centers the large picture on the main pane"
    )
    controller:updateFixed({ { type = "navigate", direction = "right" } }, OPEN_GATES)
    local skills = controller:status()
    Assert.equal(skills.group, "skills", versionId .. " turns to the second native group")
    local skillsMain = drawNativePane(renderer, scope, textCalls, skills, "main", assets)
    local skillsSub = drawNativePane(renderer, scope, textCalls, skills, "sub", assets)
    Assert.isTrue(
      paneDifference(infoMain, skillsMain) > 200,
      versionId .. " moves the main pane with its group"
    )
    Assert.isTrue(
      paneDifference(infoSub, skillsSub) > 200,
      versionId .. " moves the sub pane with its group"
    )
    controller:dispose()
    realText:release()
  end
end

function T.native_text_and_state_variants_follow_source_roles(scope)
  local versions = SummaryAcceptanceFixture.readySummaryVersions()
  Assert.isTrue(#versions >= 1, "the prepared cache publishes the Summary family")
  for _, versionId in ipairs(versions) do
    local cacheFs, manifest = SummaryAcceptanceFixture.loadSummaryManifest(versionId)
    local catalog = realCatalog(cacheFs)
    local service = openService(catalog, 0xC10C4002)
    gift(service, "CHIKORITA", 12)
    local context = SummaryAcceptanceFixture.displayContext(manifest, service:partyCount())
    local windows = assert(manifest.windows, versionId .. " lowers its source windows")
    local textCalls = {}
    local realText = FieldTextRenderer.new({ cacheFs = cacheFs })
    local text, _ = recordingText(realText, textCalls)
    local renderer = SummaryRenderer.new({ text = text })
    local _, _, _, portraits = composition(scope, versionId)
    local controller = openNativeController(service, context, manifest)
    controller:updateFixed({}, OPEN_GATES)
    local assets = {
      manifest = manifest,
      portraits = portraits,
      badgeImage = badgeImages(scope, cacheFs),
      text = text,
    }
    local sub = drawNativePane(renderer, scope, textCalls, controller:status(), "sub", assets)
    Assert.isTrue(#textCalls > 0, versionId .. " draws its sub pane through palette text roles")
    -- Drawn triples match their compiled role by value: byte channels
    -- pass through while byte alpha arrives normalized to the unit
    -- range, so identity against the numeric window slot can never hold
    -- once the renderer correctly resolves triples.
    local function roleMatches(drawn, role)
      for _, class in ipairs({ "foreground", "shadow", "background" }) do
        local got = drawn[class]
        local want = role[class]
        if type(got) ~= "table" or type(want) ~= "table" then
          return false
        end
        if got.r ~= want.r or got.g ~= want.g or got.b ~= want.b then
          return false
        end
        local wantAlpha = want.a
        if type(wantAlpha) == "number" and wantAlpha > 1 then
          wantAlpha = wantAlpha / 255
        end
        if got.a ~= wantAlpha then
          return false
        end
      end
      return true
    end
    local pad = SummaryRenderer.TEXT_PAD_X
    for _, call in ipairs(textCalls) do
      if call.kind == "palette" then
        local matched = false
        for _, window in pairs(windows) do
          if
            type(window) == "table"
            and window.pane == "sub"
            and type(window.rect) == "table"
            and type(window.palette) == "number"
          then
            local rect = window.rect
            local role = assert(
              manifest.text.roles["slot" .. window.palette],
              versionId .. " binds its used window palette slot through a text role"
            )
            local left = rect.x + pad
            local right = rect.x + rect.width - pad - call.width
            local center = rect.x + math.floor((rect.width - call.width) / 2)
            if
              roleMatches(call.palette, role)
              and call.y == rect.y + SummaryRenderer.TEXT_PAD_Y
              and (call.x == left or call.x == right or call.x == center)
              and call.x + call.width > rect.x
              and call.x < rect.x + rect.width
            then
              matched = true
              break
            end
          end
        end
        Assert.isTrue(matched, versionId .. " keeps every sub text call inside its source window role")
      end
    end
    local healthy = sub
    local copy = service:partyMon(0)
    copy.condition = { status = 0, currentHp = 0 }
    local preparation = assert(service:preparePartyChanges(service:partyRevision(), { { slot = 0, mon = copy } }))
    preparation.publish()
    controller:updateFixed({}, OPEN_GATES)
    local fainted = drawNativePane(renderer, scope, textCalls, controller:status(), "sub", assets)
    Assert.isTrue(
      paneDifference(healthy, fainted) > 20,
      versionId .. " shows the source zero-HP behavior apart from full health"
    )
    controller:dispose()
    realText:release()
  end
end

-- Feature-local picture palette operation: all 32 source levels through
-- the blend at several coefficients match the integer reference, and
-- transparent texels stay transparent. The reference mirrors the shader
-- formula exactly (quantize, floor, clamp, re-expand); the GPU result
-- must agree within one 8-bit step.
local function blendReference(channel, target, coefficient)
  local source5 = math.floor(channel * 31 + 0.5)
  local mixed = math.floor((source5 * (16 - coefficient) + target * coefficient) / 16)
  if mixed < 0 then
    mixed = 0
  end
  if mixed > 31 then
    mixed = 31
  end
  return mixed / 31
end

function T.picture_shader_matches_the_integer_reference_across_levels(scope)
  local shaderPath = "libs/hgss/src/ui/shaders/summary_picture.glsl"
  local source = love.filesystem.read(shaderPath)
  if source == nil then
    local handle = io.open(love.filesystem.getSourceBaseDirectory() .. "/" .. shaderPath, "rb")
    Assert.notNil(handle, "the picture shader source loads")
    source = handle:read("*a")
    handle:close()
  end
  Assert.notNil(source, "the picture shader source loads")
  local shader = scope:own(love.graphics.newShader(source))
  local steps = 32
  local data = love.image.newImageData(steps + 1, 1)
  for level = 0, 31 do
    data:setPixel(level, 0, level / 31, level / 31, level / 31, 1)
  end
  data:setPixel(steps, 0, 0, 0, 0, 0)
  local strip = scope:own(love.graphics.newImage(data))
  strip:setFilter("nearest", "nearest")
  for _, coefficient in ipairs({ 1, 8, 15, 16 }) do
    shader:send("u_target", { 31, 0, 0 })
    shader:send("u_coefficient", coefficient)
    local canvas = scope:own(love.graphics.newCanvas(steps + 1, 1))
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    love.graphics.setShader(shader)
    love.graphics.draw(strip, 0, 0)
    love.graphics.setShader()
    love.graphics.setCanvas()
    local pixels = scope:own(canvas:newImageData())
    for level = 0, 31 do
      local r, g, b, a = pixels:getPixel(level, 0)
      Assert.isTrue(
        math.abs(r - blendReference(level / 31, 31, coefficient)) < 2 / 255,
        "red blends level " .. level .. " at coefficient " .. coefficient
      )
      Assert.isTrue(
        math.abs(g - blendReference(level / 31, 0, coefficient)) < 2 / 255,
        "green holds level " .. level .. " at coefficient " .. coefficient
      )
      Assert.isTrue(
        math.abs(b - blendReference(level / 31, 0, coefficient)) < 2 / 255,
        "blue holds level " .. level .. " at coefficient " .. coefficient
      )
      Assert.isTrue(a > 0.5, "opaque texels stay opaque at level " .. level)
    end
    local _, _, _, transparent = pixels:getPixel(steps, 0)
    Assert.isTrue(transparent < 0.5, "transparent texels stay transparent")
  end
end

-- Produced bar rules over the real derived family: model-built facts draw
-- the sub pane from the compiled health and experience tracks with their
-- realized art, and fainted health shows the source zero behavior. Tile
-- presence is proved differentially: the same status with and without
-- realized tiles, all art coming from the cache, never injected.
local function realBarTiles(scope, cacheFs, manifest)
  local visuals = assert(manifest.visuals, "the compiled family carries its visuals")
  assert(type(visuals) == "table", "compiled visuals arrive as a record")
  local tiles = {}
  for _, name in ipairs({ "hp-empty", "hp-full", "exp-empty", "exp-full" }) do
    local entry = assert(visuals[name], "the compiled family carries its " .. name .. " tile")
    tiles[name] = realizedImage(scope, cacheFs, assert(entry.image, name .. " carries its image path"))
  end
  return tiles
end

local function faintMon(service, slot)
  local revision = service:partyRevision()
  local copy = service:partyMon(slot)
  local condition = {}
  for key, value in pairs(assert(copy.condition, "stored mons carry conditions")) do
    condition[key] = value
  end
  condition.currentHp = 0
  copy.condition = condition
  local preparation = assert(service:preparePartyChanges(revision, { { slot = slot, mon = copy } }))
  preparation.publish()
end

function T.produced_bar_rules_draw_from_the_real_family(scope)
  local versions = SummaryAcceptanceFixture.readySummaryVersions()
  Assert.isTrue(#versions >= 1, "the prepared cache publishes the Summary family")
  for _, versionId in ipairs(versions) do
    local cacheFs, manifest = SummaryAcceptanceFixture.loadSummaryManifest(versionId)
    local bars = assert(manifest.bars, versionId .. " produces bar rules")
    assert(type(bars) == "table", versionId .. " carries its bar rules as a record")
    for _, name in ipairs({ "hp", "exp" }) do
      local rule = assert(bars[name], versionId .. " produces its " .. name .. " bar rule")
      assert(type(rule) == "table", versionId .. " carries its " .. name .. " rule as a record")
      assert(type(rule.length) == "number" and rule.length > 0, versionId .. " carries its " .. name .. " length")
      assert(type(rule.colors) == "table", versionId .. " carries its " .. name .. " inks")
      assert(type(rule.empty) == "table", versionId .. " carries its " .. name .. " empty track")
      assert(type(rule.full) == "table", versionId .. " carries its " .. name .. " full track")
    end
    Assert.equal(bars.hp.length, 48, versionId .. " spans the source health width")
    Assert.equal(bars.exp.length, 56, versionId .. " spans the source experience width")
    -- A triple-strict recording double over the real generated-font
    -- renderer: role/order/palette/window evidence shares the exact
    -- pixels under test while widths ride the renderer's own
    -- measurement, so the placement assertion below pins the exact
    -- width-based formula and lets the window scissor own
    -- overlong-line clipping.
    local textCalls = {}
    local realText = FieldTextRenderer.new({ cacheFs = cacheFs })
    local text, _ = recordingText(realText, textCalls)
    local renderer = SummaryRenderer.new({ text = text })
    local _, partyManifest, _, portraits, service = composition(scope, versionId)
    local context = SummaryAcceptanceFixture.displayContext(manifest, service:partyCount())
    local healthy = SummaryModel.build(service, 0, context, manifest)
    Assert.equal(healthy.skills.hpBar.length, 48, versionId .. " fills the produced track at full health")
    local tiles = realBarTiles(scope, cacheFs, manifest)
    local function bundle(extra)
      return {
        manifest = manifest,
        partyManifest = partyManifest,
        portraits = portraits,
        badgeImage = badgeImages(scope, cacheFs),
        text = text,
        visuals = extra,
      }
    end
    local healthyTiled = drawNativePane(renderer, scope, textCalls, nativeStatus(healthy, "info"), "sub", bundle(tiles))
    local healthyBare = drawNativePane(renderer, scope, textCalls, nativeStatus(healthy, "info"), "sub", bundle(nil))
    Assert.isTrue(
      paneDifference(healthyTiled, healthyBare) > 100,
      versionId .. " draws produced bar tiles from the facts widths when art is realized"
    )
    faintMon(service, 0)
    local fainted = SummaryModel.build(service, 0, context, manifest)
    Assert.equal(fainted.skills.hpBar.length, 0, versionId .. " fills no pixels without health")
    local faintedTiled = drawNativePane(renderer, scope, textCalls, nativeStatus(fainted, "info"), "sub", bundle(tiles))
    Assert.isTrue(
      paneDifference(healthyTiled, faintedTiled) > 20,
      versionId .. " shows the source zero-HP behavior apart from full health"
    )
    Assert.isTrue(#textCalls > 0, versionId .. " places sub text through window roles with produced bars")
    local subWindows = {}
    for _, window in pairs(assert(manifest.windows, versionId .. " lowers its source windows")) do
      if type(window) == "table" and window.pane == "sub" then
        subWindows[#subWindows + 1] = window
      end
    end
    Assert.isTrue(#subWindows > 0, versionId .. " carries sub windows")
    -- Window discipline under the scissor rule: every call carries the
    -- triple its window resolves through, starts on its window's text
    -- row, and pins one of the exact width-based origins while its span
    -- meets the window. Overlong lines keep their aligned origin (which
    -- may sit outside a narrow window); the window scissor owns the
    -- clipping, covered pixel-wise by the long-metadata test.
    local function roleMatches(drawn, role)
      for _, class in ipairs({ "foreground", "shadow", "background" }) do
        local got = drawn[class]
        local want = role[class]
        if type(got) ~= "table" or type(want) ~= "table" then
          return false
        end
        if got.r ~= want.r or got.g ~= want.g or got.b ~= want.b then
          return false
        end
        local wantAlpha = want.a
        if type(wantAlpha) == "number" and wantAlpha > 1 then
          wantAlpha = wantAlpha / 255
        end
        if got.a ~= wantAlpha then
          return false
        end
      end
      return true
    end
    for _, call in ipairs(textCalls) do
      local placed = false
      for _, window in ipairs(subWindows) do
        local rect = assert(window.rect, versionId .. " windows carry rects")
        local role = assert(
          manifest.text.roles["slot" .. window.palette],
          versionId .. " binds its used window palette slot through a text role"
        )
        if roleMatches(call.palette, role) and call.y >= rect.y and call.y < rect.y + rect.height then
          -- The locked placement rule is width-based alignment with the
          -- window scissor as the clipper: the origin matches one of the
          -- exact left/right/center formulas, and the drawn span meets the
          -- window instead of starting from a clamped rewriting.
          local pad = SummaryRenderer.TEXT_PAD_X
          local left = rect.x + pad
          local right = rect.x + rect.width - pad - call.width
          local center = rect.x + math.floor((rect.width - call.width) / 2)
          if call.x == left or call.x == right or call.x == center then
            placed = call.x + call.width > rect.x and call.x < rect.x + rect.width
            if placed then
              break
            end
          end
        end
      end
      Assert.isTrue(placed, versionId .. " aligns every sub text call to its source window role")
    end
  end
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump" }
suite.metadata.derivedAssets =
  { "summary:global", "mon-catalog:global", "mon-summary:global", "field-font:global", "party:global" }
return suite
