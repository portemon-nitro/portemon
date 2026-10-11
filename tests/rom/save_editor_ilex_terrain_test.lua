-- The Save Editor's shrine approach is classified from its real source collision cell.

local Assert = require("tests.support.Assert")
local CollisionGrid = require("libs.hgss.src.world.CollisionGrid")
local SaveEditorLocationPolicy = require("app.src.saveeditor.SaveEditorLocationPolicy")
local LandData = require("romdump.src.digest.map.LandData")
local MapResolver = require("romdump.src.digest.map.MapResolver")
local RomSuite = require("tests.rom.support.RomSuite")

local function diagnostic(memberId, collision)
  return string.format(
    "Ilex Forest source member %d at (16,56): behavior=%d blocked=%s",
    memberId,
    collision.behavior,
    tostring(collision.blocked)
  )
end

return RomSuite.fromFacts({
  ilex_shrine_approach_is_source_backed_stationary_terrain = function(romFs)
    local resolved = assert(MapResolver.resolve(romFs, "MAP_ILEX_FOREST"))
    Assert.equal(resolved.map.id, 117, "the semantic Ilex map resolves to its selected header")

    local fieldX, fieldZ = 16, 56
    local matrixCellX, matrixCellZ = math.floor(fieldX / 32), math.floor(fieldZ / 32)
    local matrixCell = resolved.matrix:cell(matrixCellX, matrixCellZ)
    Assert.equal(
      matrixCell.mapHeaderId,
      resolved.map.id,
      "the physical cell at the requested global coordinates belongs to Ilex Forest"
    )
    local memberId = matrixCell.landDataMemberId
    local landData = assert(LandData.decode(
      assert(romFs:openNarc("land_data")):readMember(memberId),
      { mapId = resolved.map.id, alias = "land_data", memberId = memberId }
    ))
    local collisionGrid = CollisionGrid.new(landData.collision)
    local collision = collisionGrid:getLocal(fieldX % 32, fieldZ % 32)
    local label = diagnostic(memberId, collision)
    Assert.isFalse(collision.blocked, label .. "; the requested approach must not be hard-blocked")

    local result = SaveEditorLocationPolicy.classify({
      mapId = resolved.map.id,
      fieldX = fieldX,
      fieldZ = fieldZ,
      coverage = true,
      logicalMapMatch = true,
      trigger = false,
      collision = collision,
      occupied = false,
      -- This source-only assertion supplies no evidence about physical surfaces.
      surface = { surfaceId = 0, worldY = 0, terrainDependencyHash = "policy-only" },
    })
    Assert.isTrue(result.selectable, label .. "; terrain policy refused the real source cell as " .. tostring(result.reason))
    Assert.isNil(
      SaveEditorLocationPolicy.terrainRejection(collision),
      label .. "; the normalized source cell must pass the shared terrain gate"
    )
  end,
})
