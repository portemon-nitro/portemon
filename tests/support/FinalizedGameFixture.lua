-- Fresh finalized new-game tables for production-boot tests. Every field
-- mirrors the unpublished candidate NewGame finalizes (same buckets, same
-- player defaults), so the next runtime-contract change lands here instead
-- of in every hand-rolled game table. Tests that need party members still
-- gift them through the production mon service and pass the capture as
-- `mons`; only the table assembly lives here.

local BagSave = require("libs.hgss.src.save.BagSave")
local FashionCaseState = require("libs.hgss.src.save.FashionCaseState")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local Mailbox = require("libs.hgss.src.save.Mailbox")
local MartSave = require("libs.hgss.src.save.MartSave")
local MonBucket = require("tests.support.MonBucket")
local PhotoAlbum = require("libs.hgss.src.save.PhotoAlbum")
local PlayTime = require("libs.hgss.src.save.PlayTime")

local FinalizedGameFixture = {}

---@class FinalizedGameLocation
---@field mapSymbol string
---@field fieldX integer
---@field fieldZ integer
---@field facing string

---@class FinalizedGameOptions
---@field location FinalizedGameLocation?
---@field mons table?
---@field bag table?
---@field mart table?
---@field worldState table?
---@field fieldTravel table?
---@field saveId string?
---@field textSpeed string?
---@field textFrame integer?

---@param versionId string
---@param options FinalizedGameOptions?
---@return table<string, unknown>
function FinalizedGameFixture.build(versionId, options)
  assert(type(versionId) == "string", "finalized games are version-scoped")
  options = options or {}
  return {
    saveId = options.saveId or "save-00000001",
    versionId = versionId,
    location = options.location or { mapSymbol = "MAP_NEW_BARK", fieldX = 10, fieldZ = 10, facing = "south" },
    playerData = {
      profile = {
        name = "GOLD",
        gender = 0,
        trainerId = 1,
        money = 3000,
        badges = {},
        nationalDex = false,
        runningShoes = false,
        runningShoesLock = false,
        rivalName = "Silver",
      },
      options = { textSpeed = options.textSpeed or "fastest", textFrame = options.textFrame or 0 },
    },
    fieldTravel = options.fieldTravel or { lastHealSpawn = "SPAWN_NEW_BARK" },
    fashionCase = FashionCaseState.empty(),
    playTime = PlayTime.new(),
    worldState = options.worldState or FieldEventState.new(),
    mons = options.mons or MonBucket.emptyForVersion(versionId),
    bag = options.bag or BagSave.empty(),
    mart = options.mart or MartSave.empty(),
    mailbox = Mailbox.new():capture(),
    photoAlbum = PhotoAlbum.new():capture(),
  }
end

return FinalizedGameFixture
