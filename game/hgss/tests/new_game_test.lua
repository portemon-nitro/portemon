-- Contract tests for the game-owned new-game candidate and profile lifecycle.
-- Storage and randomness are injected boundaries; no LÖVE or filesystem state
-- is needed here.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local Mailbox = require("libs.hgss.src.save.Mailbox")
local SaveFs = require("libs.storage.src.SaveFs")
local NewGame = require("game.hgss.src.newgame.NewGame")

local T = {}

local CHARMAP = {
  A = 299,
  B = 300,
  C = 301,
  D = 302,
  E = 303,
  F = 304,
  G = 305,
  O = 313,
  L = 310,
  Q = 315,
  U = 321,
  R = 316,
  S = 322,
  e = 335,
  i = 339,
  l = 342,
  r = 346,
  v = 347,
}

local FRAME_INDEXES = { [0] = true, [1] = true, [2] = true }

local function playerDataContext()
  return { charmap = CHARMAP, frameIndexes = FRAME_INDEXES }
end

local function reservationService()
  local calls = { reserve = 0, publish = 0, save = 0 }
  return {
    calls = calls,
    reserve = function()
      calls.reserve = calls.reserve + 1
      return "save-00000027"
    end,
    publish = function()
      calls.publish = calls.publish + 1
    end,
    save = function()
      calls.save = calls.save + 1
    end,
  }
end

local function invalidReservationService(saveId)
  return {
    reserve = function()
      return saveId
    end,
  }
end

local function newCandidate(service)
  return NewGame.createCandidate({
    saveService = service,
    versionId = "heartgold",
    eventState = FieldEventState.new(),
    scriptSymbols = FieldScriptSymbols,
    mapIdentity = {
      mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
      fieldX = 6,
      fieldZ = 6,
      facing = "south",
    },
  })
end

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured domain error")
  Assert.equal(err.code, code)
end

function T.new_candidate_uses_source_owned_opening_state()
  local service = reservationService()
  local candidate = newCandidate(service)
  local openingFlag = FieldScriptSymbols.flagsByName.FLAG_UNK_960

  Assert.equal(service.calls.reserve, 1, "New Game reserves exactly one stable identity")
  Assert.equal(candidate.saveId, "save-00000027")
  Assert.equal(candidate.versionId, "heartgold")
  Assert.deepEqual(candidate.location, {
    mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
    fieldX = 6,
    fieldZ = 6,
    facing = "south",
  })
  Assert.equal(candidate.profileDraft.money, 3000)
  Assert.deepEqual(candidate.options, {
    textSpeed = "fastest",
    textFrame = 0,
    battleStyle = "shift",
    battleScene = true,
    soundMode = "stereo",
    battleSpeed = 1,
  })
  Assert.equal(candidate.playTime:seconds(), 0)
  Assert.isTrue(candidate.worldState:isFlagSet(openingFlag), "the source opening flag is seeded semantically")
  Assert.isNil(candidate.surfaceId, "surface resolution belongs to field entry")
  Assert.isNil(candidate.worldState.fishingRecord, "unowned retail buckets are not fabricated")
  Assert.equal(service.calls.publish, 0)
  Assert.equal(service.calls.save, 0)
end

function T.normalized_location_rejects_legacy_source_direction_inputs()
  local service = reservationService()
  for _, mapIdentity in ipairs({
    { mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F", fieldX = 6, fieldZ = 6, sourceFacing = 1 },
    { mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F", fieldX = 6, fieldZ = 6, facing = 1 },
    { mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F", fieldX = 6, fieldZ = 6, facing = "up" },
    { mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F", fieldX = 6, fieldZ = 6 },
  }) do
    local ok = pcall(NewGame.createCandidate, {
      saveService = service,
      versionId = "heartgold",
      eventState = FieldEventState.new(),
      scriptSymbols = FieldScriptSymbols,
      mapIdentity = mapIdentity,
    })
    Assert.isFalse(ok, "candidate construction must not interpret raw source directions")
  end
end

function T.real_store_reservation_creates_an_unpublished_candidate()
  local backend = FakeCache.new()
  local GameSaveStore = require("libs.hgss.src.save.GameSaveStore")
  local store = GameSaveStore.new(SaveFs.global(backend))
  local candidate = newCandidate(store)

  Assert.equal(candidate.saveId, "save-00000001")
  Assert.equal(store:listMetadata()[1], nil, "reservation must remain unpublished")
  Assert.notNil(backend.files["saves/catalog.lua"], "reservation state must be durable")
end

function T.invalid_reservation_identity_uses_the_shared_save_id_contract()
  for _, saveId in ipairs({ 27, "../escape" }) do
    throwsCode("GAME_SAVE_SAVE_ID_INVALID", function()
      newCandidate(invalidReservationService(saveId))
    end)
  end
end

function T.partial_candidate_finalizes_after_confirmation_without_publishing_gameplay()
  local service = reservationService()
  local candidate = newCandidate(service)

  Assert.isNil(candidate.playerData, "Oak receives a partial candidate, not a fake final profile")
  local finalized = assert(NewGame.finalize(candidate, {
    name = "GOLD",
    gender = 0,
  }, {
    randomU32 = function()
      return 0xFFFFFFFF
    end,
    playerDataContext = playerDataContext(),
  }))

  Assert.equal(finalized.saveId, "save-00000027")
  Assert.equal(finalized.playerData.profile.name, "GOLD")
  Assert.equal(finalized.playerData.profile.gender, 0)
  Assert.equal(finalized.playerData.profile.trainerId, 0xFFFFFFFF)
  Assert.equal(finalized.playerData.profile.money, 3000)
  Assert.equal(service.calls.reserve, 1)
  Assert.equal(service.calls.publish, 0, "finalization is not first Save")
  Assert.equal(service.calls.save, 0, "finalization does not publish a gameplay payload")
end

function T.finalize_places_rival_mail_in_mailbox_slot_zero()
  local service = reservationService()
  local candidate = newCandidate(service)
  candidate.versionId = "heartgold"
  local finalized = assert(NewGame.finalize(candidate, {
    name = "GOLD",
    gender = 0,
  }, {
    randomU32 = function()
      return 0x12345678
    end,
    playerDataContext = playerDataContext(),
  }))
  local mailbox = Mailbox.new(finalized.mailbox)
  Assert.equal(mailbox:usedCount(), 1, "a new game starts with the rival mail in the PC")
  local letter = assert(mailbox:get(0), "the rival mail occupies mailbox slot zero")
  Assert.equal(letter.type, 9, "the rival mail uses AIR stationery")
  Assert.equal(letter.author.name, "Lyra")
  Assert.equal(letter.author.gender, 1)
  Assert.equal(letter.author.trainerId, 0)
  Assert.equal(letter.author.language, 2)
  Assert.equal(letter.author.game, 7)
  Assert.deepEqual(letter.icons, {
    { species = "MARILL", form = 0, palette = 2 },
    false,
    false,
  })
  Assert.deepEqual(letter.lines, {
    { template = "mail-template:2:4", words = { "1371", "1417" } },
    { template = "mail-template:3:1", words = { "1479", false } },
    false,
  })
  Assert.isNil(mailbox:get(1), "only the rival mail occupies the new-game mailbox")
end

function T.finalize_addresses_rival_mail_to_male_player()
  local service = reservationService()
  local candidate = newCandidate(service)
  candidate.versionId = "soulsilver"
  local finalized = assert(NewGame.finalize(candidate, {
    name = "GOLD",
    gender = 1,
  }, {
    randomU32 = function()
      return 0x12345678
    end,
    playerDataContext = playerDataContext(),
  }))
  local mailbox = Mailbox.new(finalized.mailbox)
  local letter = assert(mailbox:get(0), "the rival mail occupies mailbox slot zero")
  Assert.equal(letter.author.name, "Ethan")
  Assert.equal(letter.author.gender, 0)
  Assert.equal(letter.author.game, 8)
end

return { tests = T }
