-- Two independently synthesized managed-edition fixtures over the real import
-- host. The public edition identities keep real worker validation meaningful;
-- every ROM byte, banner pixel, archive, sidecar, and save marker is test-owned.

local Assert = require("tests.support.Assert")
local BannerIconFixture = require("tests.support.BannerIconFixture")
local GameVersion = require("romdump.src.source.GameVersion")
local ManagedRomFixture = require("tests.support.ManagedRomFixture")
local NdsBuilder = require("tests.support.NdsBuilder")
local RomArchive = require("romdump.src.source.RomArchive")
local RomSource = require("romdump.src.source.RomSource")

local Fixture = {}

local function writeHostFile(path, bytes)
  local file = assert(io.open(path, "wb"))
  file:write(bytes)
  Assert.isTrue(file:close(), "fixture file did not close: " .. path)
end

function Fixture.with(fn)
  local savedHeartGold = GameVersion.VERSIONS.heartgold
  local savedSoulSilver = GameVersion.VERSIONS.soulsilver
  local heartGoldBanner = BannerIconFixture.staticBanner()
  local soulSilverBanner = BannerIconFixture.transparentBanner()
  local ok, err = pcall(ManagedRomFixture.with, function(heartGold)
    local sourceInfo = heartGold.cart.info
    local heartGoldInfo = {
      id = "heartgold",
      label = "Synthetic HeartGold",
      displayName = "Synthetic HeartGold",
      sha1 = sourceInfo.sha1,
      gameCode = "IPKE",
      expectedSize = sourceInfo.expectedSize,
      cachePrefix = "heartgold/",
    }
    local heartGoldVersions = {
      info = function(versionId)
        return versionId == heartGoldInfo.id and heartGoldInfo or nil
      end,
      forSha1 = function(value)
        return value == heartGoldInfo.sha1 and heartGoldInfo or nil
      end,
      forGameCode = function(value)
        return value == "IPKE" and heartGoldInfo or nil
      end,
      ORDER = { "heartgold" },
    }
    local heartGoldEdition = {}
    for key, value in pairs(heartGold) do
      heartGoldEdition[key] = value
    end
    heartGoldEdition.cart = {
      data = heartGold.cart.data,
      sha1 = heartGold.cart.sha1,
      info = heartGoldInfo,
      versions = heartGoldVersions,
    }

    local soulSilverSpec = BannerIconFixture.spec("IPGE", soulSilverBanner.block, "SOULSILVER-BANNER")
    local soulSilverData = NdsBuilder.build(soulSilverSpec)
    local soulSilverSha1 = RomSource.fromString(soulSilverData):sha1()
    local soulSilverInfo = {
      id = "soulsilver",
      label = "Synthetic SoulSilver",
      displayName = "Synthetic SoulSilver",
      sha1 = soulSilverSha1,
      gameCode = "IPGE",
      expectedSize = #soulSilverData,
      cachePrefix = "soulsilver/",
    }
    local soulSilverVersions = {
      info = function(versionId)
        return versionId == soulSilverInfo.id and soulSilverInfo or nil
      end,
      forSha1 = function(value)
        return value == soulSilverSha1 and soulSilverInfo or nil
      end,
      forGameCode = function(value)
        return value == "IPGE" and soulSilverInfo or nil
      end,
      ORDER = { "soulsilver" },
    }
    local soulSilver = {
      cart = { data = soulSilverData, sha1 = soulSilverSha1, info = soulSilverInfo, versions = soulSilverVersions },
      host = heartGold.host,
      originalPath = heartGold.root .. "/soulsilver.nds",
      archivePath = heartGold.root .. "/soulsilver.zip",
      canonical = RomArchive.path(soulSilverSha1),
      stage = RomArchive.path(soulSilverSha1) .. ".new",
      backup = RomArchive.path(soulSilverSha1) .. ".bak",
      icon = RomArchive.path(soulSilverSha1):gsub("%.zip$", ".png"),
    }
    soulSilver.iconStage = soulSilver.icon .. ".new"
    soulSilver.iconBackup = soulSilver.icon .. ".bak"
    Assert.isNil(love.filesystem.getInfo(soulSilver.canonical), "synthetic SoulSilver archive must be unowned")
    writeHostFile(soulSilver.originalPath, soulSilverData)
    writeHostFile(
      soulSilver.archivePath,
      require("tests.support.ZipBuilder").build({ { name = "game.nds", data = soulSilverData } })
    )

    GameVersion.VERSIONS.heartgold = heartGoldInfo
    GameVersion.VERSIONS.soulsilver = soulSilverInfo
    local catalog = {
      VERSIONS = { heartgold = heartGoldInfo, soulsilver = soulSilverInfo },
      ORDER = { "heartgold", "soulsilver" },
      info = function(versionId)
        if versionId == "heartgold" then
          return heartGoldInfo
        end
        if versionId == "soulsilver" then
          return soulSilverInfo
        end
        return nil
      end,
      forSha1 = function(value)
        if value == heartGoldInfo.sha1 then
          return heartGoldInfo
        end
        if value == soulSilverInfo.sha1 then
          return soulSilverInfo
        end
        return nil
      end,
      forGameCode = function(value)
        if value == "IPKE" then
          return heartGoldInfo
        end
        if value == "IPGE" then
          return soulSilverInfo
        end
        return nil
      end,
    }
    local fixture = {
      host = heartGold.host,
      heartgold = heartGoldEdition,
      soulsilver = soulSilver,
      catalog = catalog,
      heartGoldBanner = heartGoldBanner,
      soulSilverBanner = soulSilverBanner,
    }
    local ok, err = pcall(fn, fixture)
    for _, path in ipairs({
      soulSilver.canonical,
      soulSilver.stage,
      soulSilver.backup,
      soulSilver.icon,
      soulSilver.iconStage,
      soulSilver.iconBackup,
      "heartgold/derived/sentinel.lua",
      "soulsilver/derived/sentinel.lua",
      "saves/heartgold/sentinel.lua",
      "saves/soulsilver/sentinel.lua",
    }) do
      pcall(love.filesystem.remove, path)
    end
    if not ok then
      error(err, 0)
    end
  end, { gameCode = "IPKE", banner = heartGoldBanner.block })
  GameVersion.VERSIONS.heartgold = savedHeartGold
  GameVersion.VERSIONS.soulsilver = savedSoulSilver
  if not ok then
    error(err, 0)
  end
end

return Fixture
