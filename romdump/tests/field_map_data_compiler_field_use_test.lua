-- Field-use policy compilation contract: the compiler projects frozen
-- source header facts into the semantic generated fieldUse record, never
-- inferring permission from map type alone. Same-type maps with different
-- source flags must distinguish at runtime.

local Assert = require("tests.support.Assert")
local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
local Fixture = require("tests.support.FieldMapDataFixture")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")

local T = {}

local function compileOk(map)
  local bundle, err = FieldMapDataCompiler.compile(Fixture.build(), map)
  Assert.isTrue(bundle ~= nil, "compile failed: " .. tostring(err and err.message or err))
  return assert(bundle)
end

local function header(map)
  return MapCatalog.require(map)
end

function T.field_use_projects_source_flags_per_map()
  local bark = compileOk(60)
  Assert.equal(bark.field.schema, "g4-field-map-v11")
  Assert.deepEqual(bark.field.fieldUse, {
    flyAllowed = true,
    teleportAllowed = true,
    escapeAllowed = false,
    flashUsable = false,
    alphChamber = false,
    icePathB2F = false,
    cave = false,
    unionOrColosseum = false,
  })
  local tunnel = compileOk(108)
  Assert.deepEqual(tunnel.field.fieldUse, {
    flyAllowed = false,
    teleportAllowed = false,
    escapeAllowed = true,
    flashUsable = true,
    alphChamber = false,
    icePathB2F = false,
    cave = true,
    unionOrColosseum = false,
  })
end

function T.same_type_maps_with_different_flags_distinguish()
  local barkFlags = { fly = header(60).flyAllowed, escape = header(60).escapeRopeAllowed }
  local tunnelFlags = { fly = header(108).flyAllowed, escape = header(108).escapeRopeAllowed }
  Assert.isTrue(barkFlags.fly ~= tunnelFlags.fly or barkFlags.escape ~= tunnelFlags.escape)
  local bark = compileOk(60).field.fieldUse
  local tunnel = compileOk(108).field.fieldUse
  Assert.equal(bark.flyAllowed, barkFlags.fly)
  Assert.equal(tunnel.flyAllowed, tunnelFlags.fly)
  Assert.equal(bark.escapeAllowed, barkFlags.escape)
  Assert.equal(tunnel.escapeAllowed, tunnelFlags.escape)
  Assert.isTrue(bark.flyAllowed ~= tunnel.flyAllowed)
end

function T.exception_maps_carry_explicit_source_exceptions()
  local ice = compileOk(238).field.fieldUse
  Assert.isTrue(ice.icePathB2F)
  Assert.isTrue(ice.cave)
  local alph = compileOk("MAP_RUINS_OF_ALPH_UNDERGROUND_HALL").field.fieldUse
  Assert.isTrue(alph.alphChamber)
  Assert.isTrue(alph.flashUsable)
  local plain = compileOk(60).field.fieldUse
  Assert.isFalse(plain.alphChamber)
  Assert.isFalse(plain.icePathB2F)
end

function T.union_room_rejects_external_checks_as_data()
  local union = compileOk(2).field.fieldUse
  Assert.isTrue(union.unionOrColosseum)
  Assert.isFalse(compileOk(60).field.fieldUse.unionOrColosseum)
end

return { tests = T }
