-- Mailbox trusted restore: a Continue-time snapshot reproduces its authored
-- Mail slots through ownership copies, while explicit validation still
-- rejects malformed snapshots and stale preparations still refuse.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Mailbox = require("libs.hgss.src.save.Mailbox")
local Mail = require("libs.mons.src.gen4.Mail")

local T = {}

local function writtenMail(authorName)
  return {
    schema = "g4-mail-v2",
    type = 2,
    author = { trainerId = 1, name = authorName, gender = 0, language = 2, game = 7 },
    icons = { "CHIKORITA/f0", false, false },
    lines = { { template = "GREET", words = { "HELLO", false } }, false, false },
  }
end

-- Legacy predecessor record with a nonzero palette: the old renderer
-- never consumed the palette, so migration resolves the same displayed
-- icon through the catalog and drops the palette deliberately.
local function legacyMail(authorName)
  return {
    schema = "g4-mail-v1",
    type = 2,
    author = { trainerId = 1, name = authorName, gender = 0, language = 2, game = 7 },
    icons = { { species = "CHIKORITA", form = 0, palette = 9 }, false, { species = "TOTODILE", form = 1, palette = 3 } },
    lines = { { template = "GREET", words = { "HELLO", false } }, false, false },
  }
end

-- Catalog double honoring a form override: the migrated selector must
-- match the same icon the old viewer displayed for the overridden form.
local function migrationCatalog()
  return {
    iconSelection = function(_, icon)
      assert(type(icon) == "table", "legacy icons resolve through the catalog")
      if icon.species == "TOTODILE" then
        return "TOTODILE/f9"
      end
      return icon.species .. "/f" .. icon.form
    end,
  }
end

local function populatedSnapshot()
  local box = Mailbox.new()
  local preparation = box:prepareChanges(box:revision(), {
    { slot = 0, value = writtenMail("GOLD") },
    { slot = 7, value = writtenMail("SILVER") },
  })
  Assert.notNil(preparation)
  preparation.publish()
  return box:capture()
end

function T.trusted_restore_reproduces_authored_mail_without_per_slot_validation()
  local snapshot = populatedSnapshot()
  local calls = 0
  local original = Mail.validate
  Mail.validate = function(...)
    calls = calls + 1
    return original(...)
  end
  local ok, restored = pcall(Mailbox.new, snapshot)
  Mail.validate = original
  Assert.isTrue(ok, "trusted mailbox restore succeeds")
  Assert.equal(calls, 0, "trusted mailbox restore must not revalidate every authored slot")
  Assert.deepEqual(restored:capture(), snapshot, "restored mail captures back to the snapshot")
  Assert.equal(restored:usedCount(), 2)
  Assert.equal(restored:get(0).author.name, "GOLD")
  Assert.equal(restored:get(7).author.name, "SILVER")
  Assert.isNil(restored:get(1), "holes stay empty through the trusted restore")
end

function T.legacy_letters_migrate_icons_through_the_catalog_without_rewriting_content()
  local slots = {}
  for slot = 1, Mailbox.CAPACITY do
    slots[slot] = slot == 1 and legacyMail("GOLD") or false
  end
  local snapshot = { schema = Mailbox.SCHEMA, slots = slots }
  local before = snapshot.slots[1].icons[1].palette
  local restored = Mailbox.new(snapshot, { catalog = migrationCatalog() })
  local migrated = restored:get(0)
  Assert.equal(migrated.schema, "g4-mail-v2", "explicit legacy admission targets the semantic icon schema")
  Assert.equal(migrated.type, 2, "migration preserves the stationery type")
  Assert.deepEqual(migrated.author, legacyMail("GOLD").author, "migration preserves the author exactly")
  Assert.deepEqual(migrated.lines, legacyMail("GOLD").lines, "migration preserves template and word identities")
  Assert.equal(migrated.icons[1], "CHIKORITA/f0", "migration resolves the same icon the old viewer displayed")
  Assert.equal(migrated.icons[2], false, "migration keeps false middle slots")
  Assert.equal(migrated.icons[3], "TOTODILE/f9", "migration honors the catalog form override")
  Assert.equal(snapshot.slots[1].icons[1].palette, before, "migration leaves its input immutable")
  Assert.deepEqual(restored:capture(), Mailbox.new(restored:capture()):capture(), "migrated mail restores stably")
end

function T.explicit_validation_admits_legacy_letters_without_mutating_them()
  local slots = {}
  for slot = 1, Mailbox.CAPACITY do
    slots[slot] = slot == 1 and legacyMail("GOLD") or false
  end
  local snapshot = { schema = Mailbox.SCHEMA, slots = slots }
  Assert.isTrue(Mailbox.validate(snapshot, { catalog = migrationCatalog() }), "explicit validation admits legacy mail")
  Assert.equal(snapshot.slots[1].schema, "g4-mail-v1", "explicit validation never mutates the caller snapshot")
  local malformed = { schema = Mailbox.SCHEMA, slots = slots }
  malformed.slots[1] = { schema = "g4-mail-v9", type = 2 }
  local err = Assert.throws(function()
    Mailbox.validate(malformed, { catalog = migrationCatalog() })
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "GAME_SAVE_BUCKET_INVALID", "unknown nested schemas still fail")
end

function T.explicit_mailbox_validation_still_rejects_malformed_snapshots()
  local snapshot = populatedSnapshot()
  local function codeOf(fn)
    local err = Assert.throws(fn)
    Assert.isTrue(Errors.is(err))
    return err.code
  end
  local drifted = populatedSnapshot()
  drifted.schema = "g4-mailbox-v0"
  Assert.equal(
    codeOf(function()
      Mailbox.validate(drifted)
    end),
    "GAME_SAVE_BUCKET_INVALID"
  )
  local sparse = populatedSnapshot()
  sparse.slots[20] = nil
  Assert.equal(
    codeOf(function()
      Mailbox.validate(sparse)
    end),
    "GAME_SAVE_BUCKET_INVALID"
  )
  Assert.isTrue(Mailbox.validate(snapshot), "explicit validation still accepts the authored snapshot")
end

function T.stale_mail_preparations_still_refuse_without_publication()
  local box = Mailbox.new(populatedSnapshot())
  local revision = box:revision()
  local before = box:capture()
  local preparation, reason = box:prepareChanges(revision + 1, { { slot = 1, value = writtenMail("GOLD") } })
  Assert.isNil(preparation)
  Assert.equal(reason, "stale")
  Assert.deepEqual(box:capture(), before, "a stale mail preparation mutates nothing live")
  Assert.throws(function()
    box:prepareChanges(revision, { { slot = 0, value = {} } })
  end, "an empty Mail item cannot occupy a mailbox slot")
end

return { tests = T }
