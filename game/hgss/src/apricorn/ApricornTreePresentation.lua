-- Presents the source tree's ripe/depleted sprite and its temporary fruit.

local ApricornTreePresentation = {}
ApricornTreePresentation.__index = ApricornTreePresentation

---@class ApricornTreePresentation
---@field runtime table<string, unknown>
---@field sprites ApricornTreePresentation.Sprites
---@field fruit table<string, unknown>?
---@field fruitRecord table<string, unknown>
---@field spawnFruit fun(self: ApricornTreePresentation, actorId: string, apricornKey: string)
---@field advanceFruit fun(self: ApricornTreePresentation, frame: integer)
---@field clearFruit fun(self: ApricornTreePresentation)

---@class ApricornTreePresentation.Sprites
---@field depletedTreeSpriteId integer
---@field treeSpriteIdByKey table<string, integer>
---@field fruitSpriteIdByKey table<string, integer>

-- FieldActorPlacement normalizes source object/map-model coordinates at 16
-- source model units per tile; native Apricorn motion advances by FX32_ONE.
local SOURCE_MODEL_UNITS_PER_TILE = 16
local JUMP_DY = { 4, 3, 3, 2, 2, 1, 1, 0, 0, -1, -2, -3, -4, -5, -6, -7 }
local AWAY_FROM_TREE = {
  north = { x = 0, z = 1 },
  south = { x = 0, z = -1 },
  east = { x = -1, z = 0 },
  west = { x = 1, z = 0 },
}

---@param runtime table<string, unknown>
---@return ApricornTreePresentation
function ApricornTreePresentation.new(runtime)
  local actorConfig = assert(runtime.actorConfig, "field actor runtime configuration is unavailable")
  ---@type ApricornTreePresentation.Sprites
  local sprites = assert(actorConfig.apricorn, "compiled Apricorn sprite identities are unavailable")
  return setmetatable({ runtime = runtime, sprites = sprites, fruit = nil, fruitRecord = {} }, ApricornTreePresentation)
end

---@param actor table<string, unknown>
---@return integer
function ApricornTreePresentation:spriteIdForTree(actor)
  local source = actor.sourceEvent.apricorn
  if source == nil then
    return actor.spriteId
  end
  local ripeTreeSpriteId =
    assert(self.sprites.treeSpriteIdByKey[source.apricornKey], "compiled ripe-tree sprite identity is unavailable")
  local gesture = actor:presentationState().gesturePose
  if
    self.runtime.martService:treeAvailable(source.treeIndex)
    and gesture ~= "apricorn_tree_wiggle"
    and gesture ~= "apricorn_tree_expel"
  then
    return ripeTreeSpriteId
  end
  return self.sprites.depletedTreeSpriteId
end

---@param spriteIds table<integer, boolean>
function ApricornTreePresentation:collectSpriteIds(spriteIds)
  local runtime = self.runtime
  for _, actor in ipairs(runtime.actors:actorsOf(runtime.runtimeMap.mapId)) do
    local source = actor.sourceEvent.apricorn
    if source ~= nil then
      local gesture = actor:presentationState().gesturePose
      if
        not runtime.martService:treeAvailable(source.treeIndex)
        or gesture == "apricorn_tree_wiggle"
        or gesture == "apricorn_tree_expel"
      then
        spriteIds[self.sprites.depletedTreeSpriteId] = true
      end
    end
  end
  if self.fruit ~= nil then
    spriteIds[self.fruit.spriteId] = true
  end
end

---@param actorRecords table[]
function ApricornTreePresentation:updateTreeSprites(actorRecords)
  for _, record in ipairs(actorRecords) do
    local actor = self.runtime.actors:getActor(record.actorId)
    if actor ~= nil then
      record.spriteId = self:spriteIdForTree(actor)
    end
  end
end

---@param actorId string
---@param apricornKey string
function ApricornTreePresentation:spawnFruit(actorId, apricornKey)
  assert(self.fruit == nil, "only one Apricorn fruit can be presented at a time")
  local actor = assert(self.runtime.actors:getActor(actorId), "Apricorn tree actor is unavailable")
  local position = actor:getWorldPosition()
  local facing = assert(self.runtime.player.facing, "player facing is unavailable")
  self.fruit = {
    actorId = actorId,
    spriteId = assert(self.sprites.fruitSpriteIdByKey[apricornKey], "compiled Apricorn fruit identity is unavailable"),
    x = assert(position.x),
    y = assert(position.y) + 12 / SOURCE_MODEL_UNITS_PER_TILE,
    z = assert(position.z),
    facing = facing,
    jumpFrame = nil,
  }
end

---@param frame integer
function ApricornTreePresentation:advanceFruit(frame)
  assert(self.fruit ~= nil, "Apricorn fruit has not been spawned")
  assert(frame >= 0 and frame < #JUMP_DY, "Apricorn jump frame is out of range")
  self.fruit.jumpFrame = frame
end

function ApricornTreePresentation:clearFruit()
  self.fruit = nil
end

---@return table<string, unknown>?
function ApricornTreePresentation:drawRecord()
  local fruit = self.fruit
  if fruit == nil then
    return nil
  end
  local x, y, z = fruit.x, fruit.y, fruit.z
  local frame = fruit.jumpFrame
  if frame ~= nil then
    local direction = assert(AWAY_FROM_TREE[fruit.facing], "unknown player facing")
    local deltaY = 0
    for index = 0, frame do
      deltaY = deltaY + JUMP_DY[index + 1]
    end
    local sourceUnit = 1 / SOURCE_MODEL_UNITS_PER_TILE
    x = x + direction.x * sourceUnit * (frame + 1)
    y = y + deltaY * sourceUnit
    z = z + direction.z * sourceUnit * (frame + 1)
  end
  local record = self.fruitRecord
  record.actorId = "field:apricorn-fruit"
  record.spriteId = fruit.spriteId
  record.world = record.world or {}
  record.world.x, record.world.y, record.world.z = x, y, z
  record.facing = fruit.facing
  record.pose = "idle"
  record.poseTick = 0
  record.visible = true
  return record
end

return ApricornTreePresentation
