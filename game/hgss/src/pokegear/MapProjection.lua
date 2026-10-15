-- The normalized region-map context cell: the player's world cell from the
-- source coordinate roles of the current field map (outdoor world position
-- divided by thirty-two, explicit header coordinates, the tabled special
-- locations, or the last exterior fallback). The cell carries no row
-- offset; the map world view adds the source's two rows. Pure domain
-- module: no love dependency.

---@class MapProjection
local MapProjection = {}

-- World coordinate units per world cell on outdoor main-matrix maps.
local MATRIX_DIVISOR = 32

-- Resolves the source-normalized context cell: outdoor main-matrix maps
-- divide world player coordinates by thirty-two, maps with explicit
-- header coordinates keep them verbatim, maps with both coordinates zero
-- fall back to the last exterior (or the special spawn), and special
-- locations resolve through their tabled coordinates. Never invents a
-- position: a zero-coordinate map without a fallback fails loudly.
---@param input { matrixX: number?, matrixY: number?, explicitX: integer?, explicitY: integer?, lastExterior: { x: number, y: number }?, specialSpawn: { x: number, y: number }?, special: string? }
---@return { x: integer, y: integer }
function MapProjection.contextCell(input)
  assert(type(input) == "table", "map context resolution requires its coordinate record")
  local explicitX, explicitY = input.explicitX, input.explicitY
  if input.special ~= nil then
    assert(type(input.special) == "string" and input.special ~= "", "special locations name their mode")
    assert(
      type(explicitX) == "number" and explicitX % 1 == 0 and type(explicitY) == "number" and explicitY % 1 == 0,
      "special locations resolve through their tabled coordinates"
    )
    return { x = explicitX, y = explicitY }
  end
  if explicitX ~= nil or explicitY ~= nil then
    assert(
      type(explicitX) == "number" and explicitX % 1 == 0 and type(explicitY) == "number" and explicitY % 1 == 0,
      "header coordinates arrive as integral pairs"
    )
    if explicitX == 0 and explicitY == 0 then
      local fallback = input.lastExterior or input.specialSpawn
      assert(type(fallback) == "table", "a zero-coordinate map needs its last exterior or special spawn")
      assert(
        type(fallback.x) == "number" and type(fallback.y) == "number",
        "the exterior fallback carries its world cell"
      )
      return { x = fallback.x, y = fallback.y }
    end
    return { x = explicitX, y = explicitY }
  end
  assert(
    type(input.matrixX) == "number" and type(input.matrixY) == "number",
    "outdoor maps divide world player coordinates"
  )
  return {
    x = math.floor(input.matrixX / MATRIX_DIVISOR),
    y = math.floor(input.matrixY / MATRIX_DIVISOR),
  }
end

return MapProjection
