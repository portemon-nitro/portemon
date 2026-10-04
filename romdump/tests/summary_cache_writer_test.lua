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

local SUMMARY_SCHEMA = "g4-summary-manifest-v1"

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

local function validManifest()
  return {
    schema = SUMMARY_SCHEMA,
    paneSize = { width = 256, height = 192 },
    groups = {
      info = { main = {}, sub = {} },
      skills = { main = {}, sub = {} },
      performance = { main = {}, sub = {} },
    },
    windows = {},
    visuals = {},
    sprites = {},
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
    memo = {},
    sounds = {},
    transitions = {},
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
