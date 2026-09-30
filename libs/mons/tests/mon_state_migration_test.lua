-- Legacy mon buckets survive unrelated catalog edits. A bucket written
-- against an older fingerprint upgrades without rewriting the old bytes,
-- restores under a catalog that differs only in descriptions, and captures
-- forward with every independent value and the exact generator state kept.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")

local T = {}

---@param value unknown
---@return unknown
local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = copy(item)
  end
  return out
end

---@param name string
---@param behavior string
---@return table
local function requireOwner(name, behavior)
  local ok, loaded = pcall(require, name)
  Assert.isTrue(ok, "missing " .. behavior .. ": " .. name .. " is not implemented")
  assert(loaded ~= nil, "the bucket owner loads its module")
  return loaded --[[@as table]]
end

-- Every independent datum of the persisted record except the schema tag
-- and the condition representation, which the upgrade owns.
local PRESERVED_FIELDS = {
  "species",
  "form",
  "personality",
  "experience",
  "friendship",
  "ability",
  "heldItem",
  "markings",
  "evs",
  "contest",
  "moves",
  "ivs",
  "isEgg",
  "nickname",
  "ribbons",
  "fatefulEncounter",
  "shinyLeaves",
  "egg",
  "met",
  "origin",
  "pokerus",
  "mood",
  "capsule",
  "mail",
}

---@return table<string, unknown>
local function legacyMon()
  return {
    schema = "g4-mon-v1",
    species = "CHIKORITA",
    form = 0,
    personality = 0x23456789,
    experience = 135,
    friendship = 70,
    ability = "OVERGROW",
    heldItem = "NONE",
    markings = 0,
    evs = { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 },
    contest = { cool = 0, beauty = 0, cute = 0, smart = 0, tough = 0, sheen = 0 },
    moves = {
      { move = "TACKLE", pp = 35, ppUps = 0 },
      { move = "GROWL", pp = 40, ppUps = 0 },
    },
    ivs = { hp = 10, attack = 12, defense = 14, speed = 8, specialAttack = 11, specialDefense = 13 },
    isEgg = false,
    nickname = nil,
    ribbons = { ds1 = 0, gba = 0, ds2 = 0 },
    fatefulEncounter = false,
    shinyLeaves = 0,
    egg = { location = 0 },
    met = {
      location = 7,
      date = { year = 2009, month = 9, day = 13 },
      level = 5,
      terrain = 4,
    },
    origin = {
      trainerId = 2271560481,
      trainerName = "RED",
      trainerGender = 0,
      game = "heartgold",
      ball = "POKE_BALL",
      language = "english",
    },
    pokerus = 0,
    mood = 0,
    -- Level five with the individual values above derives maximum health
    -- 20, so the record below is full health while frozen.
    condition = { status = 0x20, currentHp = 20 },
    capsule = { id = 0, seals = {} },
    mail = {},
  }
end

---@param actual table<string, unknown>
---@param expected table<string, unknown>
---@param where string
local function assertPreserved(actual, expected, where)
  Assert.equal(actual.schema, "g4-mon-v2", where .. " carries the current schema")
  for _, key in ipairs(PRESERVED_FIELDS) do
    Assert.deepEqual(actual[key], expected[key], where .. " preserves " .. key)
  end
  local condition = assert(actual.condition) --[[@as table<string, unknown>]]
  Assert.equal(condition.currentHp, 20, where .. " keeps current health")
  Assert.equal(#(condition.effects --[[@as table[] ]]), 1, where .. " keeps the frozen condition")
end

function T.legacy_buckets_restore_under_unrelated_catalog_edits()
  local Migration = requireOwner("libs.mons.src.MonStateMigration", "legacy mon and bucket upgrade")
  Assert.isTrue(type(Migration.upgradeMon) == "function", "legacy upgrade must expose upgradeMon")
  Assert.isTrue(type(Migration.upgradeBucket) == "function", "legacy upgrade must expose upgradeBucket")
  local StatusCodec = requireOwner("libs.mons.src.gen4.StatusCodec", "native status word conversion")
  Assert.isTrue(type(StatusCodec.project) == "function", "status conversion must expose project")
  local Mon = require("libs.mons.src.Mon")
  Assert.equal(Mon.SCHEMA, "g4-mon-v2", "the canonical record must carry semantic condition effects")
  local MonsSave = require("libs.mons.src.MonsSave")
  Assert.equal(MonsSave.SCHEMA, "g4-mons-save-v2", "the persisted bucket must carry the current schema")

  local catalogA = CatalogFixture.makeCatalog()
  local fingerprintA = catalogA:fingerprint()

  local editedRoot = CatalogFixture.buildAssetRoot()
  editedRoot.moves.TACKLE.description = editedRoot.moves.TACKLE.description .. " Revised."
  local MonCatalog = require("libs.mons.src.MonCatalog")
  local catalogB = MonCatalog.new(editedRoot, CatalogFixture.makeItemCatalog())
  local contextB = CatalogFixture.domainContext(catalogB)
  local fingerprintB = catalogB:fingerprint()
  Assert.isTrue(
    fingerprintA ~= fingerprintB,
    "the description edit must really change the catalog fingerprint"
  )

  local bucket = {
    schema = "g4-mon-v1",
    catalogFingerprint = fingerprintA,
    rng = { state = 0x0F1E2D3C, calls = 41 },
    party = { max = 6, mons = { legacyMon() } },
  }
  local oldBytes = copy(bucket)

  local upgraded = Migration.upgradeBucket(bucket, contextB)
  Assert.equal(upgraded.schema, "g4-mons-save-v2", "upgrade moves the bucket to the current schema")
  Assert.deepEqual(upgraded.rng, bucket.rng, "upgrade keeps the exact generator state")
  Assert.equal(#upgraded.party.mons, 1, "upgrade keeps the party size")
  assertPreserved(upgraded.party.mons[1], bucket.party.mons[1], "bucket upgrade")
  Assert.equal(
    StatusCodec.project(copy(upgraded.party.mons[1].condition.effects)),
    0x20,
    "bucket upgrade keeps the frozen condition exactly"
  )
  Assert.deepEqual(bucket, oldBytes, "bucket upgrade never rewrites the old bytes")

  local restored = MonsSave.restore(bucket, contextB)
  Assert.deepEqual(restored.rng:capture(), bucket.rng, "restore keeps the exact generator state")
  Assert.equal(restored.party:count(), 1, "restore keeps the party size")
  local mon = restored.party:get(0)
  assertPreserved(mon, bucket.party.mons[1], "bucket restore")
  Assert.equal(
    StatusCodec.project(copy(mon.condition.effects)),
    0x20,
    "bucket restore keeps the frozen condition exactly"
  )
  Assert.deepEqual(bucket, oldBytes, "restore never rewrites the old bytes")

  local fresh = MonsSave.capture(restored.party:capture(), restored.rng:capture(), fingerprintB)
  Assert.equal(fresh.schema, "g4-mons-save-v2", "current capture carries the current schema")
  Assert.equal(fresh.catalogFingerprint, fingerprintB, "current capture carries the current fingerprint")
  Assert.isTrue(MonsSave.validate(fresh, contextB), "current capture validates without rejection")
  Assert.deepEqual(bucket, oldBytes, "current capture never rewrites the old bytes")
end

return { tests = T }
