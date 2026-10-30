-- Field-move encounter projection: each compiled map carries the rock smash
-- odds with its resolved item table and the headbutt tree and slot record
-- decoded from the map's own source members (member id = map id).
-- Source basis: the retail ROM's rock smash and headbutt tables.

local Assert = require("tests.support.Assert")
local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
local Fixture = require("tests.support.FieldMapDataFixture")

local T = {}

local MAP_ID = 60

local function u16(value)
  return string.char(value % 256, math.floor(value / 256) % 256)
end

local function compile(members)
  local bundle, err = FieldMapDataCompiler.compile(Fixture.build({ members = members }), MAP_ID)
  Assert.isTrue(bundle ~= nil, "compile failed: " .. tostring(err and err.message or err))
  return assert(bundle)
end

function T.maps_without_source_entries_carry_inert_records()
  local field = compile({}).field
  Assert.equal(field.rockSmash.odds, 0)
  Assert.equal(#field.rockSmash.items, 8)
  Assert.deepEqual(field.headbutt.regularTrees, {})
  Assert.deepEqual(field.headbutt.secretTrees, {})
end

function T.rock_smash_member_projects_odds_and_version_items()
  local field = compile({ rock_smash_items = { [MAP_ID] = u16(25) .. u16(1) } }).field
  Assert.equal(field.rockSmash.odds, 25)
  Assert.equal(field.rockSmash.items[3], "HELIX_FOSSIL")
end

function T.headbutt_member_projects_trees_and_slots()
  local slots = {}
  for index = 0, 17 do
    slots[#slots + 1] = u16(16 + index) .. string.char(3, 5)
  end
  local coords = u16(7) .. u16(8) .. string.rep(u16(0xFFFF), 10)
  local member = u16(1) .. u16(0) .. table.concat(slots) .. coords
  local field = compile({ headbutt_encounters = { [MAP_ID] = member } }).field
  Assert.deepEqual(field.headbutt.regularTrees, { { { x = 7, z = 8 } } })
  Assert.equal(#field.headbutt.slots.rare, 6)
end

function T.malformed_members_fail_the_compile()
  local bundle, err =
    FieldMapDataCompiler.compile(Fixture.build({ members = { rock_smash_items = { [MAP_ID] = u16(5) } } }), MAP_ID)
  Assert.isNil(bundle)
  Assert.equal(err.code, "FIELD_ROCK_SMASH_BAD_MEMBER")
end

return { tests = T }
