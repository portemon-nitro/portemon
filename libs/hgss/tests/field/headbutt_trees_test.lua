-- Headbutt tree selection: the trainer-ID digit and tree-count lookup tables
-- pick common, rare, or no encounter for a regular tree group, secret trees
-- are always secret, and a follower standing on the facing tile redirects the
-- hit one tile further along its own facing.
-- Source basis: the retail ROM's headbutt tree tables.

local Assert = require("tests.support.Assert")
local HeadbuttTrees = require("libs.hgss.src.field.HeadbuttTrees")

local T = {}

local function tree(...)
  local coords = {}
  for _, pair in ipairs({ ... }) do
    coords[#coords + 1] = { x = pair[1], z = pair[2] }
  end
  return coords
end

local function record(regular, secret)
  return { regularTrees = regular, secretTrees = secret or {} }
end

function T.single_regular_tree_alternates_by_trainer_digit()
  local headbutt = record({ tree({ 10, 10 }) })
  local seen = {}
  for digit = 0, 9 do
    seen[digit] = HeadbuttTrees.treeType(headbutt, digit, 10, 10)
  end
  Assert.equal(seen[0], "common")
  Assert.equal(seen[1], "rare")
  Assert.equal(seen[9], "rare")
  Assert.equal(HeadbuttTrees.treeType(headbutt, 10, 10, 10), "common", "only the last digit matters")
end

function T.two_trees_are_complementary()
  local headbutt = record({ tree({ 1, 1 }), tree({ 2, 2 }) })
  Assert.equal(HeadbuttTrees.treeType(headbutt, 0, 1, 1), "common")
  Assert.equal(HeadbuttTrees.treeType(headbutt, 0, 2, 2), "rare")
  Assert.equal(HeadbuttTrees.treeType(headbutt, 1, 1, 1), "rare")
  Assert.equal(HeadbuttTrees.treeType(headbutt, 1, 2, 2), "common")
end

function T.three_trees_leave_one_without_an_encounter()
  local headbutt = record({ tree({ 1, 1 }), tree({ 2, 2 }), tree({ 3, 3 }) })
  Assert.equal(HeadbuttTrees.treeType(headbutt, 0, 3, 3), nil)
  Assert.equal(HeadbuttTrees.treeType(headbutt, 4, 1, 1), nil)
  Assert.equal(HeadbuttTrees.treeType(headbutt, 4, 3, 3), "rare")
end

function T.five_or_more_trees_repeat_the_five_column_pattern_by_group_index()
  local trees = {}
  for index = 1, 7 do
    trees[index] = tree({ index, index })
  end
  local headbutt = record(trees)
  -- Digit 0 row: none, common, common, rare, rare; group 5 wraps to column 0.
  Assert.equal(HeadbuttTrees.treeType(headbutt, 0, 1, 1), nil)
  Assert.equal(HeadbuttTrees.treeType(headbutt, 0, 4, 4), "rare")
  Assert.equal(HeadbuttTrees.treeType(headbutt, 0, 6, 6), nil)
  Assert.equal(HeadbuttTrees.treeType(headbutt, 0, 7, 7), "common")
end

function T.four_trees_use_their_own_row()
  local trees = {}
  for index = 1, 4 do
    trees[index] = tree({ index, 0 })
  end
  local headbutt = record(trees)
  Assert.equal(HeadbuttTrees.treeType(headbutt, 0, 1, 0), nil)
  Assert.equal(HeadbuttTrees.treeType(headbutt, 0, 4, 0), "rare")
  Assert.equal(HeadbuttTrees.treeType(headbutt, 9, 4, 0), "rare")
end

function T.any_tile_of_a_tree_group_matches_and_secret_trees_are_secret()
  local headbutt = record({ tree({ 5, 5 }, { 5, 6 }) }, { tree({ 8, 8 }) })
  Assert.equal(HeadbuttTrees.treeType(headbutt, 0, 5, 6), "common")
  Assert.equal(HeadbuttTrees.treeType(headbutt, 3, 8, 8), "secret")
  Assert.isNil(HeadbuttTrees.treeType(headbutt, 0, 9, 9))
end

function T.a_follower_on_the_facing_tile_redirects_one_tile_along_its_facing()
  local x, z = HeadbuttTrees.struckTile({ x = 4, z = 4 }, { x = 4, z = 4, facing = "north" })
  Assert.equal(x, 4)
  Assert.equal(z, 3)
  x, z = HeadbuttTrees.struckTile({ x = 4, z = 4 }, { x = 4, z = 4, facing = "east" })
  Assert.equal(x, 5)
  Assert.equal(z, 4)
  x, z = HeadbuttTrees.struckTile({ x = 4, z = 4 }, { x = 7, z = 7, facing = "north" })
  Assert.equal(x, 4)
  Assert.equal(z, 4)
  x, z = HeadbuttTrees.struckTile({ x = 4, z = 4 }, nil)
  Assert.equal(x, 4)
  Assert.equal(z, 4)
end

return { tests = T }
