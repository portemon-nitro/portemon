-- Failure-safety contract for the native summary family publication: the
-- family stages marker-last, malformed or interrupted rebuilds preserve the
-- previous live family, and sibling families stay byte-identical. Synthetic
-- bundles only; no dump required.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local Errors = require("libs.errors.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local PartyCache = require("libs.assets.src.PartyCache")

local T = {}

local SUMMARY_SCHEMA = "g4-summary-manifest-v3"

-- Synthetic semantic layout with the source-pinned per-pane role census
-- (info 2/6, skills 8/10, performance 5/3) plus one ordered memo branch:
-- publication-mechanics tests need a schema-valid envelope so staging
-- behavior, not shape validity, is under test.
local GROUP_ROLE_CENSUS = { info = { main = 2, sub = 6 }, skills = { main = 8, sub = 10 }, performance = { main = 5, sub = 3 } }

local function semanticRole(pane, seed)
  return {
    pane = pane,
    rect = { x = 8, y = 8 + (seed * 16) % 176, width = 64, height = 8 },
    palette = 13,
    ink = "ordinary",
  }
end

local function semanticWindows()
  local fixed = { synHeader = semanticRole("sub", 0) }
  local groups = {}
  for group, census in pairs(GROUP_ROLE_CENSUS) do
    groups[group] = { main = {}, sub = {} }
    for pane, count in pairs(census) do
      for index = 1, count do
        groups[group][pane]["syn" .. group .. pane .. index] = semanticRole(pane, index)
      end
    end
  end
  return { fixed = fixed, groups = groups }
end

local function semanticMemo()
  return {
    conditions = {
      {
        key = "synBranch",
        selectable = true,
        match = { isEgg = false, fateful = false, mine = true, metLocation = "wild" },
        lines = { nature = 1, date = 2, characteristic = 6, flavor = 7, eggWatch = 0 },
        dateTemplate = {
          segments = {
            { kind = "text", value = "SYN" },
            { kind = "metMonth" },
            { kind = "lineBreak" },
            { kind = "metLocation" },
          },
        },
      },
    },
    locations = { palPark = 55, linkTrade = 4001, linkTrade2 = 4002, ranger = 6001, giftEggOrigins = { 4009 } },
    migrationRegions = { heartgold = "synRegion", soulsilver = "synRegion" },
  }
end

local function requireCache()
  local ok, cache = pcall(require, "libs.assets.src.SummaryCache")
  Assert.isTrue(ok, "the summary consumer cache is missing: publication has no readiness owner")
  return cache
end

local function requireWriter()
  local ok, writer = pcall(require, "romdump.src.digest.ui.SummaryCacheWriter")
  Assert.isTrue(ok, "the summary cache writer is missing: the family has no marker-last staging owner")
  return writer
end

-- Minimal valid envelope for publication-mechanics tests. The manifest
-- carries the closed top-level field set with one finite picture track
-- plus the required bar and touch sections; structural detail beyond
-- publication mechanics belongs to the compiled-output conformance
-- coverage. If the consumer schema demands richer substructure, extend
-- this builder there rather than weakening the publication assertions below.
local function barStub(length)
  return {
    length = length,
    colors = {
      high = { r = 0, g = 255, b = 0 },
      low = { r = 255, g = 255, b = 0 },
      critical = { r = 255, g = 0, b = 0 },
    },
    empty = {
      image = "assets/generated/summary/syn-bar-empty.png",
      width = 8,
      height = 8,
    },
    full = {
      image = "assets/generated/summary/syn-bar-full.png",
      width = 8,
      height = 8,
    },
  }
end

-- Minimal valid dynamic-chrome and transition sections for
-- publication-mechanics tests. Role geometry is synthetic but
-- shape-correct; structural detail beyond publication mechanics belongs
-- to the compiled-output conformance coverage.
local CHROME_ANIMATIONS = {
  "rootFocus",
  "moveRowFocus",
  "restrictedCancel",
  "moveCancel",
  "moveFollow",
  "starBase",
  "starAbove",
  "starBelow",
  "starEmpty",
  "modifierPositive",
  "modifierNegative",
  "leaf",
  "crown",
  "ribbonCursor",
  "ribbonPagePrev",
  "ribbonPageNext",
}

local function chromeVisuals()
  local visuals = { detailBacking = { image = "assets/generated/summary/syn-detail-backing.png", width = 8, height = 8 } }
  for _, name in ipairs(CHROME_ANIMATIONS) do
    visuals["syn-" .. name] = { image = "assets/generated/summary/syn-" .. name .. ".png", width = 16, height = 16 }
  end
  return visuals
end

local function chromeSprites()
  local animations = {}
  for _, name in ipairs(CHROME_ANIMATIONS) do
    animations[name] = { frames = { { visual = "syn-" .. name, durationTicks = 2 } }, loopFrom = 1, playback = "static" }
  end
  local primaryAnchors = {}
  for index = 1, 6 do
    primaryAnchors[index] = { x = 8 * index, y = 8 }
  end
  local leafAnchors = {}
  for index = 1, 5 do
    leafAnchors[index] = { x = 8 * index, y = 16 }
  end
  local rows = {}
  for index = 1, 5 do
    local stars = {}
    for star = 1, 5 do
      stars[star] = { x = 8 * star, y = 8 * index }
    end
    rows[index] = {
      stat = "synStat" .. index,
      stars = stars,
      modifier = { x = 8, y = 8 * index },
      starBase = "starBase",
      starAbove = "starAbove",
      starBelow = "starBelow",
      starEmpty = "starEmpty",
      modifierPositive = "modifierPositive",
      modifierNegative = "modifierNegative",
    }
  end
  return {
    animations = animations,
    primaryCursor = {
      anchors = primaryAnchors,
      rootFocus = "rootFocus",
      moveRowFocus = "moveRowFocus",
      restrictedCancel = "restrictedCancel",
    },
    secondaryMoveCursor = {
      x = 68,
      rowBaseY = 24,
      rowStep = 32,
      cancelY = 152,
      restrictedCancelY = 168,
      cancelAnchor = { x = 68, y = 168 },
      restrictedSpecialAnchor = { x = 220, y = 176 },
      moveCancel = "moveCancel",
      moveFollow = "moveFollow",
    },
    performance = { rows = rows },
    leaves = { anchors = leafAnchors, crownAnchor = { x = 8, y = 16 }, leaf = "leaf", crown = "crown" },
    ribbons = {
      origin = { x = 32, y = 24 },
      columns = 3,
      columnStep = 32,
      rowStep = 40,
      cursor = "ribbonCursor",
      pagePrev = { anchor = { x = 128, y = 32 }, animation = "ribbonPagePrev" },
      pageNext = { anchor = { x = 128, y = 96 }, animation = "ribbonPageNext" },
    },
  }
end

local function chromeTransitions()
  return {
    moveDetail = { pane = "sub", axis = "x", positions = { 0, 64, 128 } },
    ribbonDetail = { pane = "sub", axis = "y", positions = { 0, 36, 72 } },
  }
end

local function validManifest()
  return {
    schema = SUMMARY_SCHEMA,
    paneSize = { width = 256, height = 192 },
    groups = {
      info = { main = {}, sub = {} },
      skills = { main = {}, sub = {} },
      performance = { main = {}, sub = {} },
    },
    windows = semanticWindows(),
    visuals = chromeVisuals(),
    sprites = chromeSprites(),
    hitboxes = {
      touch = {
        exitChrome = { top = 165, bottom = 191, left = 189, right = 250 },
      },
    },
    text = {},
    palettes = {},
    bars = { hp = barStub(48), exp = barStub(56) },
    pictures = {
      exemplar = {
        portrait = "EXEMPLAR_PORTRAIT",
        cryDelayTicks = 0,
        samples = {
          {
            durationTicks = 2,
            frameIndex = 0,
            offsetX = 0,
            offsetY = 0,
            scaleX = 1,
            scaleY = 1,
            rotationTurns = 0,
            visible = true,
          },
        },
        terminal = {},
      },
    },
    ribbons = {},
    performance = {},
    dexNumbers = {},
    memo = semanticMemo(),
    sounds = {},
    transitions = chromeTransitions(),
  }
end

local function validBundle(marker)
  local SummaryCache = requireCache()
  local manifest = validManifest()
  local assets = {}
  for _, path in ipairs(SummaryCache.referencedPaths(manifest)) do
    assets[path] = "pixels"
  end
  return {
    marker = marker,
    manifest = manifest,
    dependencies = { cacheFormat = DerivedAssetContract.summary.cacheFormat, schema = SUMMARY_SCHEMA },
    assets = assets,
  }
end

function T.writes_the_class_and_reports_ready()
  local SummaryCache = requireCache()
  local writer = requireWriter()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = SummaryCache.marker("abc", "dep")
  Assert.isTrue(writer.write(cache, validBundle(marker)), "publication reports success")
  Assert.isTrue(SummaryCache.isReady(cache, marker), "the family reads ready after publication")
  local loaded = SummaryCache.loadManifest(cache)
  Assert.equal(loaded.schema, SUMMARY_SCHEMA, "the published manifest loads back under its schema")
end

function T.rejects_a_malformed_class_without_publishing()
  local SummaryCache = requireCache()
  local writer = requireWriter()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local bad = validBundle(SummaryCache.marker("abc", "dep"))
  bad.manifest = { schema = "g4-party-presentation-v6" }
  local err = Assert.throws(function()
    writer.write(cache, bad)
  end)
  Assert.isTrue(Errors.is(err), "a malformed class must fail structurally")
  Assert.isNil(cache:read(SummaryCache.markerPath()), "no ready marker follows a rejected publication")
end

-- A malformed rebuild cannot replace ready content: the rebuild fails
-- structurally and the prior ready tree stays unchanged and loadable with
-- no new ready marker.
function T.failed_rebuild_preserves_the_previous_artifact()
  local SummaryCache = requireCache()
  local writer = requireWriter()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local firstMarker = SummaryCache.marker("abc", "dep")
  writer.write(cache, validBundle(firstMarker))

  local broken = validBundle(SummaryCache.marker("abc", "new-dep"))
  broken.manifest = nil
  Assert.throws(function()
    writer.write(cache, broken)
  end)
  Assert.isTrue(SummaryCache.isReady(cache, firstMarker), "the previous artifact remains ready")
  Assert.equal(cache:read(SummaryCache.markerPath()), firstMarker, "the new marker never reached the live tree")
  Assert.isNil(backend:getInfo("staging/heartgold/summary"), "the stage is cleaned on failure")
end

-- A marker alone never establishes readiness: the manifest plus every
-- referenced payload must be present under the current marker.
function T.marker_without_payload_is_not_ready()
  local SummaryCache = requireCache()
  requireWriter()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = SummaryCache.marker("abc", "dep")
  cache:write(SummaryCache.markerPath(), marker)
  Assert.isFalse(SummaryCache.isReady(cache, marker), "a lone marker without payload is not ready")
end

-- Summary publication shares the backend with sibling families but never
-- disturbs them: party payload bytes stay identical across a successful
-- summary write and a failed summary rebuild.
function T.summary_publication_leaves_sibling_families_untouched()
  local SummaryCache = requireCache()
  local writer = requireWriter()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  cache:write(PartyCache.manifestPath(), "party-sentinel")
  cache:write(PartyCache.markerPath(), PartyCache.marker("party-sha", "party-dep"))

  local marker = SummaryCache.marker("abc", "dep")
  writer.write(cache, validBundle(marker))
  local broken = validBundle(SummaryCache.marker("abc", "new-dep"))
  broken.manifest = { schema = "not-a-summary-schema" }
  Assert.throws(function()
    writer.write(cache, broken)
  end)
  Assert.equal(cache:read(PartyCache.manifestPath()), "party-sentinel", "sibling payload survives summary work")
  Assert.equal(
    cache:read(PartyCache.markerPath()),
    PartyCache.marker("party-sha", "party-dep"),
    "sibling readiness survives summary work"
  )
end

return { tests = T }
