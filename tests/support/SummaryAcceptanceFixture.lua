-- Shared setup for the native Summary acceptance coverage: real derived
-- Summary family selection, trainer display contexts built from that
-- family, and party gifts over a live mon service. Suites keep their own
-- assertions; this helper only assembles inputs every scenario needs.

local CacheFs = require("libs.storage.src.CacheFs")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local GameVersion = require("romdump.src.source.GameVersion")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local RomImporter = require("romdump.src.source.RomImporter")

local SummaryAcceptanceFixture = {}

---@return string[] ready game versions whose Summary family is published
function SummaryAcceptanceFixture.readySummaryVersions()
  local SummaryCache = require("libs.assets.src.SummaryCache")
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      local cacheFs = CacheFs.forVersion(versionId)
      local marker = cacheFs:read(SummaryCache.markerPath())
      if marker ~= nil and SummaryCache.isReady(cacheFs, marker) then
        versions[#versions + 1] = versionId
      end
    end
  end
  return versions
end

---@param versionId string
---@return table<string, unknown> cache filesystem for the ready version
---@return table<string, unknown> validated Summary family
function SummaryAcceptanceFixture.loadSummaryManifest(versionId)
  local SummaryCache = require("libs.assets.src.SummaryCache")
  local cacheFs = CacheFs.forVersion(versionId)
  return cacheFs, SummaryCache.loadManifest(cacheFs)
end

---@param manifest table<string, unknown> validated Summary family
---@param slotCount integer current party size
---@param profile table<string, unknown>? trainer profile (defaults to the catalog fixture)
---@return table<string, unknown> explicit read-only display context
function SummaryAcceptanceFixture.displayContext(manifest, slotCount, profile)
  local performance = assert(manifest.performance, "the summary family carries performance rules")
  assert(type(performance) == "table", "performance rules are a record")
  local zero = assert(performance.zeroAprijuice, "performance rules carry the zero modifiers")
  assert(type(zero) == "table", "zero modifiers are a record")
  local ribbons = assert(manifest.ribbons, "the summary family carries ribbon definitions")
  assert(type(ribbons) == "table", "ribbon definitions are a record")
  local initials = assert(
    ribbons.initialSpecialDescriptions,
    "ribbon definitions carry the source-initial special descriptions"
  )
  assert(type(initials) == "table", "initial special descriptions are a record")
  -- Special-ribbon display text is a runtime resolution (the family
  -- carries source message selections, production reads the bank): tests
  -- use the family's own strings when they are display text, and
  -- explicit test placeholders otherwise. This never affects pane,
  -- layout, or lifecycle assertions.
  local specials = {}
  local direct = true
  for slot = 1, 14 do
    if type(initials[slot]) ~= "string" or initials[slot] == "" then
      direct = false
      break
    end
  end
  if direct then
    for slot = 1, 14 do
      specials[slot] = initials[slot]
    end
  else
    for slot = 1, 14 do
      specials[slot] = "test special-ribbon description " .. slot
    end
  end
  local rows = {}
  for _ = 1, slotCount do
    rows[#rows + 1] = {
      power = zero.power,
      stamina = zero.stamina,
      skill = zero.skill,
      jump = zero.jump,
      speed = zero.speed,
    }
  end
  return {
    profile = profile or CatalogFixture.profile(),
    dayOfMonth = 13,
    dexMode = "regional",
    performanceEnabled = false,
    aprijuiceBySlot = rows,
    specialRibbonDescriptions = specials,
  }
end

---@param catalog table<string, unknown>? mon catalog (defaults to the synthetic fixture)
---@param seed integer?
---@return table<string, unknown> live mon service over an empty party
function SummaryAcceptanceFixture.openService(catalog, seed)
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  local resolved = catalog or CatalogFixture.makeCatalog()
  return HgssMonService.new({
    catalog = resolved,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(seed or 0x5EED1234):capture()),
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

---@param failures table<string, boolean>? armed failure switches shared with the doubles
---@return table<string, unknown> counting preparation doubles
function SummaryAcceptanceFixture.preparationDoubles(failures)
  failures = failures or {}
  local FakeGraphics = require("tests.support.FakeGraphics")
  local Assert = require("tests.support.Assert")
  local calls = {
    portraitPages = {},
    iconPrepares = {},
    iconCancels = 0,
    iconReleases = 0,
    queueCancels = 0,
    queueReleases = 0,
  }
  local derivedAssets = {
    requestMonPortraitPage = function(_, pageId, _)
      Assert.equal(type(pageId), "number", "portrait demand names its page")
      if failures.portrait == true then
        return nil, "test portrait compilation is unavailable"
      end
      calls.portraitPages[#calls.portraitPages + 1] = { pageId = pageId }
      return true, nil
    end,
  }
  local icons = {
    prepareKeys = function(_, keys)
      local snapshot = {}
      for index, key in ipairs(keys) do
        snapshot[index] = key
      end
      calls.iconPrepares[#calls.iconPrepares + 1] = snapshot
      if failures.icons == true then
        return false, "test icon preparation is unavailable"
      end
      return true, nil
    end,
    cancelPreparation = function(_)
      calls.iconCancels = calls.iconCancels + 1
    end,
    release = function(_)
      calls.iconReleases = calls.iconReleases + 1
    end,
  }
  local pendingTokens = {}
  local preparationQueue = {
    request = function(_, kind, path, priority)
      local token = { id = #pendingTokens + 1, kind = kind, path = path, priority = priority }
      pendingTokens[#pendingTokens + 1] = token
      if failures.decode == true then
        token.failed = true
      else
        token.completed = failures.hang ~= true
      end
      return token
    end,
    poll = function(_, token)
      if token.failed == true then
        return { status = "failed", error = "test image decoding is unavailable" }
      end
      if token.completed == true then
        return { status = "ready" }
      end
      return { status = "pending" }
    end,
    take = function(_, token)
      Assert.isTrue(token.completed == true, "decoded payloads are taken once ready")
      return { bytes = "test-image-bytes" }
    end,
    cancel = function(_, _)
      calls.queueCancels = calls.queueCancels + 1
    end,
    release = function(_)
      calls.queueReleases = calls.queueReleases + 1
    end,
  }
  local graphics = FakeGraphics.new(failures.image == true and { failOnImageCall = 1 } or {})
  local text = {
    drawLineWithPalette = function(_, _, _, _, _)
    end,
    drawLineWithColorVariants = function(_, _, _, _, _, _)
    end,
    textWidth = function(_, _)
      return 0
    end,
  }
  return {
    calls = calls,
    derivedAssets = derivedAssets,
    icons = icons,
    preparationQueue = preparationQueue,
    graphics = graphics,
    text = text,
  }
end

---@param versionId string
---@param helper table<string, unknown> preparation doubles
---@return table<string, unknown> resource-owner constructor options over the real family
function SummaryAcceptanceFixture.ownerOptions(versionId, helper)
  local cacheFs, manifest = SummaryAcceptanceFixture.loadSummaryManifest(versionId)
  return {
    cacheFs = cacheFs,
    graphics = helper.graphics,
    text = helper.text,
    icons = helper.icons,
    preparationQueue = helper.preparationQueue,
    derivedAssets = helper.derivedAssets,
    manifest = manifest,
  }
end

---@param service table<string, unknown> live mon service
---@param species string
---@param level integer?
---@return nil
function SummaryAcceptanceFixture.gift(service, species, level)
  local Assert = require("tests.support.Assert")
  local added = service:giveMon({
    species = species,
    level = level or 5,
    heldItem = "NONE",
    form = 0,
    location = 7,
    date = CatalogFixture.metDate(),
  })
  Assert.isTrue(added, "setup gift must enter the party")
end

return SummaryAcceptanceFixture
