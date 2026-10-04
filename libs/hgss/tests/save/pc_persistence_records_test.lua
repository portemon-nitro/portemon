-- Mail and photo snapshots own nested records and preserve sparse positions.

local Assert = require("tests.support.Assert")

local T = {}

local function requireOwner(path, message)
  local ok, result = pcall(require, path)
  Assert.isTrue(ok, message)
  return result
end

local function mailRecord()
  return {
    schema = "g4-mail-v1",
    type = 2,
    author = { trainerId = 1, name = "GOLD", gender = 0, language = 2, game = 7 },
    icons = { { species = "CHIKORITA", form = 0, palette = 0 }, false, false },
    lines = { { template = "GREET", words = { "HELLO", false } }, false, false },
  }
end

local function photoRecord()
  return {
    schema = "g4-photo-v1",
    icon = 0,
    playerName = "GOLD",
    playerGender = 0,
    leadNickname = "CHIKORITA",
    avatarState = "walking",
    mapSymbol = "MAP_NEW_BARK_TOWN",
    fieldX = 1,
    fieldZ = 2,
    date = { year = 2026, month = 10, day = 4, weekday = 0 },
    hour = 12,
    minute = 30,
    party = { { species = "CHIKORITA", form = 0, gender = 0, shiny = false }, false, false, false, false, false },
    sourcePartyCount = 1,
    hiddenPropModels = { false, false },
  }
end

function T.mailbox_and_album_round_trip_nested_copies_and_holes()
  local Mailbox = requireOwner("libs.hgss.src.save.Mailbox", "the game save must own its twenty Mail slots")
  local PhotoAlbum = requireOwner("libs.hgss.src.save.PhotoAlbum", "the game save must own its thirty-six photo slots")
  local mailbox = Mailbox.new()
  local album = PhotoAlbum.new()
  local mail = mailRecord()
  local photo = photoRecord()

  local mailPreparation = mailbox:prepareChanges(mailbox:revision(), { { slot = 7, value = mail } })
  local photoPreparation = album:prepareChanges(album:revision(), { { slot = 35, value = photo } })
  mailPreparation.publish()
  photoPreparation.publish()

  local mailRead = mailbox:get(7)
  local photoRead = album:get(35)
  mailRead.author.name = "MUTATED"
  mailRead.lines[1].words[1] = "MUTATED"
  photoRead.party[1].species = "EEVEE"
  photoRead.date.month = 1
  Assert.equal(mailbox:get(7).author.name, "GOLD")
  Assert.equal(mailbox:get(7).lines[1].words[1], "HELLO")
  Assert.equal(album:get(35).party[1].species, "CHIKORITA")
  Assert.equal(album:get(35).date.month, 10)

  local mailSnapshot = mailbox:capture()
  local photoSnapshot = album:capture()
  mailSnapshot.slots[8] = mailRecord()
  photoSnapshot.slots[0] = photoRecord()
  Assert.isNil(mailbox:get(7 + 1), "snapshot mutation cannot change an owned slot")
  Assert.isNil(album:get(0), "snapshot mutation cannot change album holes")
  local restoredMailbox = Mailbox.new(mailbox:capture())
  local restoredAlbum = PhotoAlbum.new(album:capture())
  Assert.equal(restoredMailbox:count(), 20)
  Assert.equal(restoredAlbum:count(), 36)
  Assert.equal(restoredMailbox:get(0), nil)
  Assert.equal(restoredMailbox:get(7).author.name, "GOLD")
  Assert.equal(restoredAlbum:get(34), nil)
  Assert.equal(restoredAlbum:get(35).leadNickname, "CHIKORITA")
  Assert.throws(function()
    mailbox:prepareChanges(mailbox:revision(), { { slot = 0, value = {} } })
  end, "an empty Mail item cannot occupy a Mailbox slot")
end

return { tests = T }
