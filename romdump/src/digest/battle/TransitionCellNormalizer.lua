-- Converts source 32-byte NCER OBJ tile units to decoded character-tile indices.

local TransitionCellNormalizer = {}

---@param cellData {cells: {objs: {tile: integer}[]}[]}
---@param mapping integer source 1D OBJ mapping mode from the NCER CEBK header
---@param depth integer decoded CHAR depth (3=4bpp, 4=8bpp)
function TransitionCellNormalizer.normalize(cellData, mapping, depth)
  assert(type(cellData.cells) == "table", "transition cell resources carry decoded cells")
  assert(type(mapping) == "number" and mapping % 1 == 0 and mapping >= 0 and mapping <= 3, "NCER mapping is valid")
  assert(depth == 3 or depth == 4, "transition CHAR resources have a decoded pixel depth")
  local scale = math.floor(depth == 3 and 2 ^ mapping or (mapping >= 1 and 2 ^ (mapping - 1) or 1))
  for _, cell in ipairs(cellData.cells) do
    for _, obj in ipairs(cell.objs) do
      assert(type(obj.tile) == "number" and obj.tile % 1 == 0 and obj.tile >= 0, "decoded OBJ tile base is valid")
      obj.tile = obj.tile * scale
    end
  end
end

return TransitionCellNormalizer
