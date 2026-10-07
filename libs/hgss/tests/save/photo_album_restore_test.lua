-- Photo Album trusted restore: a Continue-time snapshot reproduces its saved
-- photo slots through ownership copies, while explicit validation still
-- rejects malformed snapshots and stale preparations still refuse.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local PhotoAlbum = require("libs.hgss.src.save.PhotoAlbum")

local T = {}

local function photoRecord(leadNickname)
  return {
    schema = "g4-photo-v1",
    icon = 0,
    playerName = "GOLD",
    playerGender = 0,
    leadNickname = leadNickname,
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

local function populatedSnapshot()
  local album = PhotoAlbum.new()
  local preparation = album:prepareChanges(album:revision(), {
    { slot = 0, value = photoRecord("CHIKORITA") },
    { slot = 35, value = photoRecord("EEVEE") },
  })
  Assert.notNil(preparation)
  preparation.publish()
  return album:capture()
end

function T.trusted_restore_reproduces_saved_photos_without_explicit_preflight()
  local snapshot = populatedSnapshot()
  local calls = 0
  local original = PhotoAlbum.validate
  PhotoAlbum.validate = function(...)
    calls = calls + 1
    return original(...)
  end
  local ok, restored = pcall(PhotoAlbum.new, snapshot)
  PhotoAlbum.validate = original
  Assert.isTrue(ok, "trusted photo restore succeeds")
  Assert.equal(calls, 0, "trusted photo restore must not route through the explicit preflight")
  Assert.deepEqual(restored:capture(), snapshot, "restored photos capture back to the snapshot")
  Assert.equal(restored:usedCount(), 2)
  Assert.equal(restored:get(0).leadNickname, "CHIKORITA")
  Assert.equal(restored:get(35).leadNickname, "EEVEE")
  Assert.isNil(restored:get(1), "holes stay empty through the trusted restore")
end

function T.explicit_photo_validation_still_rejects_malformed_snapshots()
  local snapshot = populatedSnapshot()
  local function codeOf(fn)
    local err = Assert.throws(fn)
    Assert.isTrue(Errors.is(err))
    return err.code
  end
  local drifted = populatedSnapshot()
  drifted.schema = "g4-photo-album-v0"
  Assert.equal(codeOf(function()
    PhotoAlbum.validate(drifted)
  end), "GAME_SAVE_BUCKET_INVALID")
  local sparse = populatedSnapshot()
  sparse.slots[36] = nil
  Assert.equal(codeOf(function()
    PhotoAlbum.validate(sparse)
  end), "GAME_SAVE_BUCKET_INVALID")
  local tampered = populatedSnapshot()
  tampered.slots[1].hour = 24
  Assert.equal(codeOf(function()
    PhotoAlbum.validate(tampered)
  end), "GAME_SAVE_BUCKET_INVALID")
  Assert.isTrue(PhotoAlbum.validate(snapshot), "explicit validation still accepts the saved snapshot")
  Assert.throws(function()
    PhotoAlbum.new(drifted)
  end, "an explicitly invalid snapshot never becomes a live album")
end

function T.stale_photo_preparations_still_refuse_without_publication()
  local album = PhotoAlbum.new(populatedSnapshot())
  local revision = album:revision()
  local before = album:capture()
  local preparation, reason = album:prepareChanges(revision + 1, { { slot = 1, value = photoRecord("CHIKORITA") } })
  Assert.isNil(preparation)
  Assert.equal(reason, "stale")
  Assert.deepEqual(album:capture(), before, "a stale photo preparation mutates nothing live")
end

return { tests = T }
