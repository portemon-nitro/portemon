-- WarpSystem tests cover coordinate lookup, indexed and direct-record
-- destination resolution, terrain-height selection, typed failures, and
-- one-coordinate suppression.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")
local WarpSystem = require("libs.hgss.src.transition.WarpSystem")

local T = {}

local function runtimeMap(mapId, originX, originZ, warps, plates)
  return {
    mapId = mapId,
    coordinateOrigin = { x = originX, z = originZ },
    fieldData = { events = { warps = warps } },
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
      isBlockedLocal = function()
        return false
      end,
    },
    terrain = TerrainSurface.new({
      plates = plates or {
        {
          id = 0,
          minX = 0,
          minZ = 0,
          maxX = 32,
          maxZ = 32,
          normal = { x = 0, y = 1, z = 0 },
          distance = 0,
          slopeClass = "flat",
        },
      },
    }),
  }
end

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected structured error")
  Assert.equal(err.code, code)
end

function T.finds_warp_by_authoritative_field_coordinate()
  local warp = { index = 0, x = 4, z = 14, destinationMapId = 60, destinationWarpId = 0, y = 0 }
  local map = runtimeMap(61, 0, 0, { warp })
  Assert.equal(WarpSystem.findAt(map, 4, 14), warp)
  Assert.isNil(WarpSystem.findAt(map, 4, 13))
end

function T.resolves_destination_warp_and_nearest_height_surface()
  local sourceWarp = { index = 0, x = 4, z = 14, destinationMapId = 60, destinationWarpId = 0, y = 0 }
  local destinationWarp = { index = 0, x = 684, z = 393, destinationMapId = 61, destinationWarpId = 0, y = 32 }
  local destination = runtimeMap(60, 672, 384, { destinationWarp }, {
    {
      id = 3,
      minX = 0,
      minZ = 0,
      maxX = 32,
      maxZ = 32,
      normal = { x = 0, y = 1, z = 0 },
      distance = 0,
      slopeClass = "flat",
    },
    {
      id = 7,
      minX = 0,
      minZ = 0,
      maxX = 32,
      maxZ = 32,
      normal = { x = 0, y = 1, z = 0 },
      distance = 2,
      slopeClass = "flat",
    },
  })
  local loader = {
    load = function(_, mapId)
      Assert.equal(mapId, 60)
      return destination
    end,
  }
  local result = WarpSystem.resolveDestination(loader, runtimeMap(61, 0, 0, { sourceWarp }), sourceWarp)
  Assert.equal(result.destinationMap, destination)
  Assert.equal(result.destinationWarp, destinationWarp)
  Assert.equal(result.fieldX, 684)
  Assert.equal(result.fieldZ, 393)
  Assert.equal(result.surfaceId, 7)
  Assert.equal(result.worldY, 2)
  Assert.deepEqual(result.suppression, { mapId = 60, fieldX = 684, fieldZ = 393 })
end

-- A dynamic-warp anchor carries no map of its own: the saved destination names
-- the map, the warp event on it whose tile the arrival re-anchors on, and the
-- facing the arrival player is created with.
function T.dynamic_anchor_resolves_the_saved_destination_warp()
  local savedWarp = {
    index = 2,
    x = 684,
    z = 393,
    destinationMapId = 0xFFF,
    destinationWarpId = WarpSystem.DYNAMIC_WARP_SENTINEL,
    y = 32,
  }
  local destination = runtimeMap(60, 672, 384, {
    {
      index = 0,
      x = 676,
      z = 386,
      destinationMapId = 0xFFF,
      destinationWarpId = WarpSystem.DYNAMIC_WARP_SENTINEL,
      y = 0,
    },
    { index = 1, x = 677, z = 387, destinationMapId = 60, destinationWarpId = 1, y = 0 },
    savedWarp,
  }, {
    {
      id = 3,
      minX = 0,
      minZ = 0,
      maxX = 32,
      maxZ = 32,
      normal = { x = 0, y = 1, z = 0 },
      distance = 0,
      slopeClass = "flat",
    },
    {
      id = 7,
      minX = 0,
      minZ = 0,
      maxX = 32,
      maxZ = 32,
      normal = { x = 0, y = 1, z = 0 },
      distance = 2,
      slopeClass = "flat",
    },
  })
  local loader = {
    load = function(_, destinationMap)
      Assert.equal(destinationMap, "MAP_CELADON_CONDOMINIUMS_1F", "the saved destination names the map")
      return destination
    end,
  }
  local trigger = {
    index = 1,
    x = 4,
    z = 14,
    destinationMapId = 0xFFF,
    destinationWarpId = WarpSystem.DYNAMIC_WARP_SENTINEL,
  }
  local result = WarpSystem.resolveDestination(loader, runtimeMap(61, 0, 0, {}), trigger, {
    map = "MAP_CELADON_CONDOMINIUMS_1F",
    fieldX = 5,
    fieldZ = 3,
    warpId = 2,
    direction = "west",
  })
  Assert.equal(result.destinationMap, destination)
  Assert.equal(result.destinationWarp, savedWarp, "the saved warp event is the arrival anchor")
  Assert.equal(result.fieldX, 684)
  Assert.equal(result.fieldZ, 393)
  Assert.equal(result.surfaceId, 7, "the destination warp height selects the arrival floor")
  Assert.equal(result.worldY, 2)
  Assert.equal(result.facing, "west", "the saved direction is the arrival facing")
end

-- The source's -1 names no destination warp event: the saved map-local tile is
-- the arrival, converted through the destination map's origin.
function T.dynamic_anchor_without_a_destination_warp_uses_the_saved_local_tile()
  local destination = runtimeMap(60, 672, 384, {})
  local loader = {
    load = function()
      return destination
    end,
  }
  local trigger =
    { index = 1, x = 4, z = 14, destinationMapId = 0xFFF, destinationWarpId = WarpSystem.DYNAMIC_WARP_SENTINEL }
  local result = WarpSystem.resolveDestination(loader, runtimeMap(61, 0, 0, {}), trigger, {
    map = "MAP_CELADON_CONDOMINIUMS_1F",
    fieldX = 5,
    fieldZ = 3,
    warpId = -1,
    direction = "north",
  })
  Assert.equal(result.fieldX, 677, "the saved map-local tile converts through the destination origin")
  Assert.equal(result.fieldZ, 387)
  Assert.isNil(result.destinationWarp, "a saved tile names no destination warp event")
  Assert.equal(result.surfaceId, 0, "with no warp height the topmost walkable surface is the arrival")
  Assert.equal(result.facing, "north")
end

-- An anchor reached with no established destination is attributed, never
-- resolved against the sentinel header or the source map.
function T.dynamic_anchor_without_a_saved_destination_is_attributed()
  local loader = {
    load = function()
      error("a dynamic warp anchor with no destination must not load a map")
    end,
  }
  local trigger = {
    index = 1,
    x = 4,
    z = 14,
    destinationMapId = 0xFFF,
    destinationWarpId = WarpSystem.DYNAMIC_WARP_SENTINEL,
  }
  local err = Assert.throws(function()
    WarpSystem.resolveDestination(loader, runtimeMap(61, 0, 0, {}), trigger)
  end)
  Assert.isTrue(Errors.is(err), "expected structured error")
  Assert.equal(assert(err).code, "FIELD_DYNAMIC_WARP_UNSET")
  Assert.equal(assert(err).context.sourceMapId, 61)
  Assert.equal(assert(err).context.sourceWarpId, 1)
  Assert.equal(assert(err).context.destinationWarpId, WarpSystem.DYNAMIC_WARP_SENTINEL)
end

-- A saved warp id that names no record on the saved destination map is the
-- same missing-record failure the indexed path reports, with the saved id.
function T.dynamic_anchor_with_an_unknown_saved_warp_id_is_attributed()
  local destination = runtimeMap(60, 672, 384, {
    {
      index = 0,
      x = 684,
      z = 393,
      destinationMapId = 0xFFF,
      destinationWarpId = WarpSystem.DYNAMIC_WARP_SENTINEL,
      y = 0,
    },
  })
  local loader = {
    load = function()
      return destination
    end,
  }
  local trigger =
    { index = 1, x = 4, z = 14, destinationMapId = 0xFFF, destinationWarpId = WarpSystem.DYNAMIC_WARP_SENTINEL }
  local err = Assert.throws(function()
    WarpSystem.resolveDestination(loader, runtimeMap(61, 0, 0, {}), trigger, {
      map = "MAP_CELADON_CONDOMINIUMS_1F",
      fieldX = 5,
      fieldZ = 3,
      warpId = 2,
      direction = "west",
    })
  end)
  Assert.isTrue(Errors.is(err), "expected structured error")
  Assert.equal(assert(err).code, "FIELD_DESTINATION_WARP_UNKNOWN")
  Assert.equal(assert(err).context.sourceWarpId, 1)
  Assert.equal(assert(err).context.destinationWarpId, 2, "the attribution names the saved warp id")
end

function T.rejects_a_missing_indexed_destination_warp()
  local destination = runtimeMap(60, 0, 0, {})
  local loader = {
    load = function()
      return destination
    end,
  }
  local source = runtimeMap(61, 0, 0, {})
  throwsCode("FIELD_DESTINATION_WARP_UNKNOWN", function()
    WarpSystem.resolveDestination(loader, source, { index = 0, destinationMapId = 60, destinationWarpId = 4 })
  end)
end

function T.destination_coordinates_share_planning_and_resolution_selection()
  local source = runtimeMap(61, 0, 0, {})
  local destinationWarp = { index = 2, x = 684, z = 393, destinationMapId = 61, destinationWarpId = 0, y = 32 }
  local fieldData = { events = { warps = { [3] = destinationWarp } } }
  local indexed = WarpSystem.destinationCoordinates(source, {
    index = 0,
    x = 4,
    z = 14,
    destinationMapId = 60,
    destinationWarpId = 2,
  }, fieldData)
  Assert.equal(indexed.fieldX, 684)
  Assert.equal(indexed.fieldZ, 393)
  Assert.equal(indexed.warp, destinationWarp)

  local directWarp = { index = 0, x = 688, z = 392, destinationMapId = 60, destinationWarpId = 1, direct = true }
  local direct = WarpSystem.destinationCoordinates(source, directWarp, { events = { warps = {} } })
  Assert.equal(direct.fieldX, 688)
  Assert.equal(direct.fieldZ, 392)
  Assert.equal(direct.warp, directWarp)

  -- A dynamic anchor plans through the same selection: the saved warp id names
  -- the destination record, and a saved tile converts through the destination
  -- origin the structural world table supplies.
  local anchor = { index = 0, destinationMapId = 0xFFF, destinationWarpId = WarpSystem.DYNAMIC_WARP_SENTINEL }
  local dynamic = WarpSystem.destinationCoordinates(source, anchor, fieldData, {
    map = "MAP_CELADON_CONDOMINIUMS_1F",
    fieldX = 5,
    fieldZ = 3,
    warpId = 2,
    direction = "west",
  }, { x = 672, z = 384 })
  Assert.equal(dynamic.fieldX, 684)
  Assert.equal(dynamic.fieldZ, 393)
  Assert.equal(dynamic.warp, destinationWarp)

  local savedTile = WarpSystem.destinationCoordinates(source, anchor, fieldData, {
    map = "MAP_CELADON_CONDOMINIUMS_1F",
    fieldX = 5,
    fieldZ = 3,
    warpId = -1,
    direction = "west",
  }, { x = 672, z = 384 })
  Assert.equal(savedTile.fieldX, 677)
  Assert.equal(savedTile.fieldZ, 387)
  Assert.isNil(savedTile.warp, "a saved tile names no destination record")

  throwsCode("FIELD_DYNAMIC_WARP_UNSET", function()
    WarpSystem.destinationCoordinates(source, anchor, fieldData, nil, { x = 672, z = 384 })
  end)
  throwsCode("FIELD_DESTINATION_WARP_UNKNOWN", function()
    WarpSystem.destinationCoordinates(source, { index = 0, destinationMapId = 60, destinationWarpId = 4 }, fieldData)
  end)
end

-- A loader failure for the destination map is wrapped into the warp-boundary
-- code with the warp identity in context; any other loader error propagates
-- unchanged.
function T.loader_failure_is_wrapped_with_warp_context()
  local source = runtimeMap(61, 0, 0, {})
  local failing = {
    load = function()
      Errors.raise("FIELD_MAP_UNKNOWN", "map 60 is missing", { mapId = 60 })
    end,
  }
  local err = Assert.throws(function()
    WarpSystem.resolveDestination(failing, source, { index = 0, destinationMapId = 60, destinationWarpId = 0 })
  end)
  Assert.isTrue(Errors.is(err), "expected structured error")
  Assert.equal(assert(err).code, "FIELD_DESTINATION_MAP_UNKNOWN")
  Assert.equal(assert(err).context.destinationMap, 60)

  local other = {
    load = function()
      error("boom")
    end,
  }
  local rawErr = Assert.throws(function()
    WarpSystem.resolveDestination(other, source, { index = 0, destinationMapId = 60, destinationWarpId = 0 })
  end)
  Assert.isTrue(tostring(rawErr):match("boom"), "unexpected loader errors propagate unchanged")
end

-- A scripted direct warp record carries pre-resolved global destination
-- coordinates; resolveDestination must honor them instead of falling into the
-- indexed-record path. WarpSystem is the single destination-semantics owner,
-- so the branch resolves here.
function T.direct_warp_record_resolves_its_own_global_coordinates()
  local destination = runtimeMap(62, 672, 384, {
    { index = 0, x = 600, z = 300, destinationMapId = 61, destinationWarpId = 0, y = 0 },
  })
  local loader = {
    load = function(_, mapId)
      Assert.equal(mapId, 62)
      return destination
    end,
  }
  local directWarp = {
    index = 0,
    x = 688,
    z = 392,
    y = 0,
    destinationMapId = 62,
    destinationWarpId = 0,
    direct = true,
  }
  local result = WarpSystem.resolveDestination(loader, runtimeMap(60, 672, 384, {}), directWarp)
  Assert.equal(result.destinationMap, destination)
  Assert.equal(result.destinationWarp, directWarp)
  Assert.equal(result.fieldX, 688)
  Assert.equal(result.fieldZ, 392)
  Assert.equal(result.surfaceId, 0)
  Assert.equal(result.worldY, 0)
  Assert.deepEqual(result.suppression, { mapId = 62, fieldX = 688, fieldZ = 392 })
end

-- The direct path must not depend on the destination map carrying any indexed
-- warp: the coordinates are pre-resolved, so an empty warp list is fine.
function T.direct_warp_record_resolves_without_destination_warps()
  local destination = runtimeMap(62, 672, 384, {})
  local loader = {
    load = function()
      return destination
    end,
  }
  local directWarp = {
    index = 0,
    x = 688,
    z = 392,
    y = 0,
    destinationMapId = 62,
    destinationWarpId = 0,
    direct = true,
  }
  local result = WarpSystem.resolveDestination(loader, runtimeMap(60, 672, 384, {}), directWarp)
  Assert.equal(result.fieldX, 688)
  Assert.equal(result.fieldZ, 392)
end

-- A direct warp with no indexed destination warp derives its arrival surface
-- from the terrain: the topmost walkable plate, never an unconditional
-- zero-height hint (which would select the wrong floor on vertically stacked
-- maps).
function T.direct_warp_without_a_destination_warp_uses_the_topmost_surface()
  local destination = runtimeMap(62, 672, 384, {}, {
    {
      id = 0,
      minX = 0,
      minZ = 0,
      maxX = 32,
      maxZ = 32,
      normal = { x = 0, y = 1, z = 0 },
      distance = 0,
      slopeClass = "flat",
    },
    {
      id = 1,
      minX = 0,
      minZ = 0,
      maxX = 32,
      maxZ = 32,
      normal = { x = 0, y = 1, z = 0 },
      distance = 3,
      slopeClass = "flat",
    },
  })
  local loader = {
    load = function()
      return destination
    end,
  }
  local directWarp = {
    index = 0,
    x = 688,
    z = 392,
    destinationMapId = 62,
    destinationWarpId = 9,
    direct = true,
  }
  local result = WarpSystem.resolveDestination(loader, runtimeMap(60, 672, 384, {}), directWarp)
  Assert.equal(result.surfaceId, 1, "the topmost walkable surface is the arrival floor")
  Assert.equal(result.worldY, 3)
end

-- When the direct record names an indexed warp in the destination map, that
-- warp's height is the authoritative hint -- exactly as in the indexed path --
-- instead of the zero-height default.
function T.direct_warp_surface_comes_from_the_named_destination_warp()
  local destination = runtimeMap(62, 672, 384, {
    { index = 2, x = 688, z = 392, destinationMapId = 61, destinationWarpId = 0, y = 48 },
  }, {
    {
      id = 0,
      minX = 0,
      minZ = 0,
      maxX = 32,
      maxZ = 32,
      normal = { x = 0, y = 1, z = 0 },
      distance = 0,
      slopeClass = "flat",
    },
    {
      id = 1,
      minX = 0,
      minZ = 0,
      maxX = 32,
      maxZ = 32,
      normal = { x = 0, y = 1, z = 0 },
      distance = 3,
      slopeClass = "flat",
    },
  })
  local loader = {
    load = function()
      return destination
    end,
  }
  local directWarp = {
    index = 0,
    x = 688,
    z = 392,
    destinationMapId = 62,
    destinationWarpId = 2,
    direct = true,
  }
  local result = WarpSystem.resolveDestination(loader, runtimeMap(60, 672, 384, {}), directWarp)
  Assert.equal(result.surfaceId, 1, "the destination warp height (48/16) selects the upper floor")
  Assert.equal(result.worldY, 3)
end

-- An explicit record y remains the caller's intent and beats the destination
-- warp record.
function T.direct_warp_record_y_is_honored_as_an_explicit_hint()
  local destination = runtimeMap(62, 672, 384, {
    { index = 2, x = 688, z = 392, destinationMapId = 61, destinationWarpId = 0, y = 48 },
  }, {
    {
      id = 0,
      minX = 0,
      minZ = 0,
      maxX = 32,
      maxZ = 32,
      normal = { x = 0, y = 1, z = 0 },
      distance = 0,
      slopeClass = "flat",
    },
    {
      id = 1,
      minX = 0,
      minZ = 0,
      maxX = 32,
      maxZ = 32,
      normal = { x = 0, y = 1, z = 0 },
      distance = 3,
      slopeClass = "flat",
    },
  })
  local loader = {
    load = function()
      return destination
    end,
  }
  local directWarp = {
    index = 0,
    x = 688,
    z = 392,
    y = 0,
    destinationMapId = 62,
    destinationWarpId = 2,
    direct = true,
  }
  local result = WarpSystem.resolveDestination(loader, runtimeMap(60, 672, 384, {}), directWarp)
  Assert.equal(result.surfaceId, 0, "an explicit record y pins the arrival surface")
  Assert.equal(result.worldY, 0)
end

-- Record-variant dispatch order: a direct record is resolved by its own
-- coordinates even when its destinationWarpId is the dynamic-warp sentinel.
function T.direct_warp_record_bypasses_the_dynamic_sentinel()
  local destination = runtimeMap(62, 672, 384, {})
  local loader = {
    load = function()
      return destination
    end,
  }
  local directWarp = {
    index = 0,
    x = 688,
    z = 392,
    y = 0,
    destinationMapId = 62,
    destinationWarpId = WarpSystem.DYNAMIC_WARP_SENTINEL,
    direct = true,
  }
  local result = WarpSystem.resolveDestination(loader, runtimeMap(60, 672, 384, {}), directWarp)
  Assert.equal(result.fieldX, 688)
  Assert.equal(result.fieldZ, 392)
end

-- The direct branch shares the indexed path's unknown-destination-map wrap:
-- one standardized code names an unavailable destination map with the warp
-- identity in context, whichever resolution branch found it.
function T.direct_warp_destination_loader_failure_wraps_like_the_indexed_path()
  local failing = {
    load = function()
      Errors.raise("FIELD_MAP_UNKNOWN", "map 62 is missing", { mapId = 62 })
    end,
  }
  local directWarp = {
    index = 0,
    x = 688,
    z = 392,
    y = 0,
    destinationMapId = 62,
    destinationWarpId = 0,
    direct = true,
  }
  local err = Assert.throws(function()
    WarpSystem.resolveDestination(failing, runtimeMap(60, 672, 384, {}), directWarp)
  end)
  Assert.isTrue(Errors.is(err), "expected structured error")
  Assert.equal(assert(err).code, "FIELD_DESTINATION_MAP_UNKNOWN")
  Assert.equal(assert(err).context.destinationMap, 62)
end

function T.suppression_lasts_until_the_player_leaves_its_coordinate()
  local token = { mapId = 60, fieldX = 684, fieldZ = 393 }
  Assert.isTrue(WarpSystem.isSuppressed(token, 60, 684, 393))
  Assert.equal(WarpSystem.updateSuppression(token, 60, 684, 393), token)
  Assert.isNil(WarpSystem.updateSuppression(token, 60, 684, 394))
end

return { tests = T }
