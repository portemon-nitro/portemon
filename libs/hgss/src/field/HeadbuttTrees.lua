-- Headbutt tree selection: which encounter table a struck tree uses, from
-- the map's tree groups and the trainer ID's last digit, and the tile the
-- strike lands on when the follower stands in front of the player.
-- Source basis: the retail ROM's headbutt tree lookup tables. Pure domain
-- module: no love dependency.

local HeadbuttTrees = {}

local C, R, N = "common", "rare", false

-- Rows by trainer-ID last digit; columns by regular tree index. Tables for
-- five or more trees repeat their five columns over the tree index.
local LUT_1 = { { C }, { R }, { C }, { R }, { C }, { R }, { C }, { R }, { C }, { R } }
local LUT_2 = { { C, R }, { R, C }, { C, R }, { R, C }, { C, R }, { R, C }, { C, R }, { R, C }, { C, R }, { R, C } }
local LUT_3 = {
  { C, R, N },
  { C, N, R },
  { R, C, N },
  { R, N, C },
  { N, C, R },
  { N, R, C },
  { C, R, N },
  { C, N, R },
  { R, C, N },
  { R, N, C },
}
local LUT_4 = {
  { N, C, C, R },
  { R, N, C, C },
  { R, R, N, C },
  { C, R, R, N },
  { C, C, R, R },
  { N, C, R, C },
  { R, N, C, R },
  { C, R, N, C },
  { R, C, R, N },
  { C, R, C, R },
}
local LUT_5_PLUS = {
  { N, C, C, R, R },
  { R, N, C, C, R },
  { R, R, N, C, C },
  { C, R, R, N, C },
  { C, C, R, R, N },
  { N, C, R, C, R },
  { R, N, C, R, C },
  { C, R, N, C, R },
  { R, C, R, N, C },
  { C, R, C, R, N },
}

local DELTAS = {
  north = { 0, -1 },
  south = { 0, 1 },
  west = { -1, 0 },
  east = { 1, 0 },
}

---@param treeIndex integer zero-based regular tree index
---@param treeCount integer
---@param digit integer
---@return string|nil
local function regularType(treeIndex, treeCount, digit)
  local row
  local column
  if treeCount >= 5 then
    row, column = LUT_5_PLUS[digit + 1], treeIndex % 5 + 1
  elseif treeCount == 4 then
    row, column = LUT_4[digit + 1], treeIndex + 1
  elseif treeCount == 3 then
    row, column = LUT_3[digit + 1], treeIndex + 1
  elseif treeCount == 2 then
    row, column = LUT_2[digit + 1], treeIndex + 1
  else
    row, column = LUT_1[digit + 1], 1
  end
  return row[column] or nil
end

---@param trees { x: integer, z: integer }[][]
---@param x integer
---@param z integer
---@return integer|nil zero-based group index
local function groupAt(trees, x, z)
  for index, group in ipairs(trees) do
    for _, coord in ipairs(group) do
      if coord.x == x and coord.z == z then
        return index - 1
      end
    end
  end
  return nil
end

-- The table kind a struck tile uses: common or rare for a regular tree
-- (decided by the trainer ID's last digit), secret for a secret tree, nil
-- when the tile belongs to no tree or that tree yields no encounter.
---@param headbutt { regularTrees: { x: integer, z: integer }[][], secretTrees: { x: integer, z: integer }[][] }
---@param trainerId integer
---@param x integer
---@param z integer
---@return "common"|"rare"|"secret"|nil
function HeadbuttTrees.treeType(headbutt, trainerId, x, z)
  local regular = groupAt(headbutt.regularTrees, x, z)
  if regular ~= nil then
    return regularType(regular, #headbutt.regularTrees, trainerId % 10)
  end
  if groupAt(headbutt.secretTrees, x, z) ~= nil then
    return "secret"
  end
  return nil
end

-- The tile a headbutt strikes: the tile in front of the player, or one tile
-- further along the follower's facing when the follower stands on it.
---@param front { x: integer, z: integer }
---@param follower { x: integer, z: integer, facing: string }|nil
---@return integer x, integer z
function HeadbuttTrees.struckTile(front, follower)
  if follower ~= nil and follower.x == front.x and follower.z == front.z then
    local delta = assert(DELTAS[follower.facing], "the follower faces a cardinal direction")
    return front.x + delta[1], front.z + delta[2]
  end
  return front.x, front.z
end

return HeadbuttTrees
