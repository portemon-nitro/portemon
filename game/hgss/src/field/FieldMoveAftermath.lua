-- Field-move aftermath: what a committed Rock Smash or Headbutt leaves
-- behind. Rock Smash first attempts a wild encounter from the map's rock
-- slots and otherwise rolls an item; Headbutt resolves the struck tree to a
-- common, rare, or secret slot table and attempts an encounter. Both the
-- script commands and the party-menu path call this one service. It owns no
-- state: the map's generated records, the random draw, the lead's ability,
-- the player's facing tile, and the shared encounter attempt come from the
-- composing runtime.

local HeadbuttTrees = require("libs.hgss.src.field.HeadbuttTrees")
local RockSmashItem = require("libs.hgss.src.field.RockSmashItem")

---@class FieldMoveAftermath
---@field private _sources table<string, unknown>
local FieldMoveAftermath = {}
FieldMoveAftermath.__index = FieldMoveAftermath

local REQUIRED_SOURCES = {
  "fieldData",
  "draw",
  "leadAbility",
  "trainerId",
  "frontTile",
  "follower",
  "attemptEncounter",
  "launchDetails",
  "itemNativeId",
}

-- sources: fieldData() the active map's generated record; draw() an integer
-- in 0..99; leadAbility() the first party mon's ability key or nil;
-- trainerId() the player's trainer ID; frontTile() the tile in front of the
-- player {x, z}; follower() the active follower {x, z, facing} or nil;
-- attemptEncounter(method, modifiers) the shared field-move attempt;
-- launchDetails(encounter) the wild launch details of a prepared encounter;
-- itemNativeId(key) the script-visible native item id.
---@param sources table<string, unknown>
---@return FieldMoveAftermath
function FieldMoveAftermath.new(sources)
  assert(type(sources) == "table", "the aftermath needs its sources")
  for _, name in ipairs(REQUIRED_SOURCES) do
    assert(type(sources[name]) == "function", "the aftermath needs the " .. name .. " source")
  end
  return setmetatable({ _sources = sources }, FieldMoveAftermath)
end

local function battleResult(self, attempt)
  if attempt ~= nil and attempt.kind == "prepared" then
    return { kind = "battle", details = self._sources.launchDetails(attempt.encounter) }
  end
  return nil
end

-- The Rock Smash aftermath: a prepared wild battle, a found item (as its
-- native id), or nothing.
---@param followerUsing boolean the follower used the move
---@return { kind: "battle", details: table<string, unknown> }|{ kind: "item", item: unknown }|{ kind: "none" }
function FieldMoveAftermath:rockSmash(followerUsing)
  local sources = self._sources
  local battle = battleResult(self, sources.attemptEncounter("rock_smash", {}))
  if battle ~= nil then
    return battle
  end
  local rockSmash = sources.fieldData().rockSmash
  local key = RockSmashItem.roll({
    odds = rockSmash.odds,
    items = rockSmash.items,
    ability = sources.leadAbility(),
    followerUsing = followerUsing,
    draw = sources.draw,
  })
  if key == nil then
    return { kind = "none" }
  end
  return { kind = "item", item = sources.itemNativeId(key) }
end

-- The Headbutt aftermath: a prepared wild battle from the struck tree's slot
-- table, or nothing when the tile is no tree or its tree yields none.
---@return { kind: "battle", details: table<string, unknown> }|{ kind: "none" }
function FieldMoveAftermath:headbutt()
  local sources = self._sources
  local headbutt = sources.fieldData().headbutt
  if #headbutt.regularTrees == 0 and #headbutt.secretTrees == 0 then
    return { kind = "none" }
  end
  local x, z = HeadbuttTrees.struckTile(sources.frontTile(), sources.follower())
  local treeType = HeadbuttTrees.treeType(headbutt, sources.trainerId(), x, z)
  if treeType == nil then
    return { kind = "none" }
  end
  local battle =
    battleResult(self, sources.attemptEncounter("headbutt", { headbutt = { slots = headbutt.slots[treeType] } }))
  return battle or { kind = "none" }
end

return FieldMoveAftermath
