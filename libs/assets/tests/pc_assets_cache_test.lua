-- A receipt and stale files never make an incomplete PC family ready.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")

local T = {}

-- This explicit root-level fixture intentionally omits every semantic role.
-- It proves that matching metadata and a marker cannot make an incomplete
-- family ready without reverse-engineering a valid manifest from production.
local function incompletePcManifest()
  return {
    schema = "g4-pc-v1",
    storage = { wallpapers = {} },
    mailbox = {},
    mail = { stationery = {} },
    photoAlbum = {},
    text = {},
    sequences = {},
  }
end

function T.incomplete_pc_family_is_not_ready()
  local loaded, PcCache = pcall(require, "libs.assets.src.PcCache")
  Assert.isTrue(loaded, "the PC family cache readiness owner is missing")

  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = PcCache.marker("source", "dependencies")
  cache:writeLua(PcCache.manifestPath(), incompletePcManifest())
  cache:writeLua(PcCache.provenancePath(), {})
  cache:write(PcCache.markerPath(), marker)

  Assert.isFalse(PcCache.isReady(cache, marker), "a marker cannot make an incomplete semantic family ready")
  Assert.isFalse(
    PcCache.isReady(cache, PcCache.marker("current-rom", "current-dependencies")),
    "a stale marker cannot make an incomplete family ready"
  )
end

return { tests = T }
