-- Field-move encounter data decoding: the retail ROM's rock smash member
-- (a/2/5/3: u16 item odds, u16 item table type per map) and headbutt member
-- (a/2/5/2: HeadbuttEncounterData with its source-ordered tree coordinate
-- groups), projected into the semantic generated records. Source basis: the
-- retail ROM's rock smash and headbutt tables.

local Assert = require("tests.support.Assert")
local FieldMoveEncounterData = require("romdump.src.digest.field.FieldMoveEncounterData")

local T = {}

local function u16(value)
  return string.char(value % 256, math.floor(value / 256) % 256)
end

local function s16(value)
  return u16(value % 65536)
end

local function slot(species, minLevel, maxLevel)
  return u16(species) .. string.char(minLevel, maxLevel)
end

local function slots(first)
  local out = {}
  for index = 0, 5 do
    out[#out + 1] = slot(first + index, 2 + index, 3 + index)
  end
  return table.concat(out)
end

local function group(coords)
  local out = {}
  for index = 1, 6 do
    local pair = coords[index] or { -1, -1 }
    out[#out + 1] = s16(pair[1]) .. s16(pair[2])
  end
  return table.concat(out)
end

function T.rock_smash_default_table_carries_the_odds_and_items()
  local record = FieldMoveEncounterData.decodeRockSmash(u16(40) .. u16(0), "heartgold")
  Assert.equal(record.odds, 40)
  Assert.deepEqual(record.items, {
    "MAX_ETHER",
    "REVIVE",
    "HEART_SCALE",
    "RED_SHARD",
    "BLUE_SHARD",
    "GREEN_SHARD",
    "YELLOW_SHARD",
    "STAR_PIECE",
  })
end

function T.rock_smash_alph_and_cliff_tables_differ_per_version()
  local alphHg = FieldMoveEncounterData.decodeRockSmash(u16(10) .. u16(1), "heartgold")
  local alphSs = FieldMoveEncounterData.decodeRockSmash(u16(10) .. u16(1), "soulsilver")
  Assert.equal(alphHg.items[3], "HELIX_FOSSIL")
  Assert.equal(alphSs.items[3], "DOME_FOSSIL")
  Assert.equal(alphHg.items[8], "MAX_REVIVE")
  local cliffHg = FieldMoveEncounterData.decodeRockSmash(u16(10) .. u16(2), "heartgold")
  local cliffSs = FieldMoveEncounterData.decodeRockSmash(u16(10) .. u16(2), "soulsilver")
  Assert.equal(cliffHg.items[6], "CLAW_FOSSIL")
  Assert.equal(cliffHg.items[7], "CLAW_FOSSIL")
  Assert.equal(cliffSs.items[6], "ROOT_FOSSIL")
  Assert.equal(cliffSs.items[8], "RARE_BONE")
end

function T.rock_smash_rejects_malformed_members()
  local _, truncated = FieldMoveEncounterData.decodeRockSmash(u16(10), "heartgold")
  Assert.equal(truncated.code, "FIELD_ROCK_SMASH_BAD_MEMBER")
  local _, badType = FieldMoveEncounterData.decodeRockSmash(u16(10) .. u16(3), "heartgold")
  Assert.equal(badType.code, "FIELD_ROCK_SMASH_BAD_MEMBER")
  local _, tooHigh = FieldMoveEncounterData.decodeRockSmash(u16(101) .. u16(0), "heartgold")
  Assert.equal(tooHigh.code, "FIELD_ROCK_SMASH_BAD_MEMBER")
end

function T.rock_smash_zero_odds_ignores_the_unused_type()
  local record = FieldMoveEncounterData.decodeRockSmash(u16(0) .. u16(9), "heartgold")
  Assert.equal(record.odds, 0)
  Assert.equal(#record.items, 8)
end

function T.headbutt_member_projects_tree_groups_and_weighted_slots()
  local member = table.concat({
    u16(2),
    u16(1),
    slots(10),
    slots(20),
    slots(30),
    group({ { 5, 6 }, { 5, 7 } }),
    group({ { 9, 9 } }),
    group({ { 1, 2 }, { 3, 4 }, { 5, 6 }, { 7, 8 }, { 9, 10 }, { 11, 12 } }),
  })
  local record = assert(FieldMoveEncounterData.decodeHeadbutt(member))
  Assert.deepEqual(record.regularTrees, {
    { { x = 5, z = 6 }, { x = 5, z = 7 } },
    { { x = 9, z = 9 } },
  })
  Assert.deepEqual(record.secretTrees, {
    {
      { x = 1, z = 2 },
      { x = 3, z = 4 },
      { x = 5, z = 6 },
      { x = 7, z = 8 },
      { x = 9, z = 10 },
      { x = 11, z = 12 },
    },
  })
  Assert.equal(#record.slots.common, 6)
  Assert.equal(record.slots.common[1].minLevel, 2)
  Assert.equal(record.slots.common[1].maxLevel, 3)
  local weights = {}
  for index, entry in ipairs(record.slots.rare) do
    weights[index] = entry.weight
  end
  Assert.deepEqual(weights, { 50, 15, 15, 10, 5, 5 })
  Assert.equal(type(record.slots.secret[1].species), "string")
end

function T.headbutt_member_without_regular_trees_carries_no_body()
  local record = assert(FieldMoveEncounterData.decodeHeadbutt(u16(0) .. u16(0)))
  Assert.deepEqual(record.regularTrees, {})
  Assert.deepEqual(record.secretTrees, {})
  Assert.deepEqual(record.slots, { common = {}, rare = {}, secret = {} })
  -- The source tool omits the whole body whenever the regular list is empty,
  -- even if the header counts secret trees.
  local secretOnly = assert(FieldMoveEncounterData.decodeHeadbutt(u16(0) .. u16(2)))
  Assert.deepEqual(secretOnly.secretTrees, {})
end

function T.headbutt_member_rejects_truncated_bodies()
  local _, err = FieldMoveEncounterData.decodeHeadbutt(u16(1) .. u16(0) .. slots(10))
  Assert.equal(err.code, "FIELD_HEADBUTT_BAD_MEMBER")
end

return { tests = T }
