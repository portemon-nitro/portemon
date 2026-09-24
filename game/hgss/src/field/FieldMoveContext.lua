-- Current field-context adapter: live service reads become the copied
-- read-only value record the pure eligibility checks consume. Game-side
-- composition over public current-map/player/actor services; owns no
-- pointers, clocks, or graphics. Context capture owns no pointers: every
-- table it returns is freshly built from validated inputs.

local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")

local FieldMoveContext = {}

local AVATAR_MODES = { walking = true, cycling = true, surfing = true, rocket = true }

local function isMask(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value % 1 == 0
    and value >= 0
    and value <= 0xFFFF
end

local function isBool(value)
  return type(value) == "boolean"
end

---@param sources table<string, unknown> live service reads (badges, map, fieldUse, avatar, flags, tiles, actor)
---@return table<string, unknown> the copied read-only context record
function FieldMoveContext.capture(sources)
  assert(type(sources) == "table", "field context capture requires service reads")
  assert(isMask(sources.badges), "field context badges must be a 16-bit mask")
  assert(type(sources.mapSymbol) == "string" and sources.mapSymbol ~= "", "field context needs a map symbol")
  assert(
    type(sources.mapId) == "number" and sources.mapId % 1 == 0 and sources.mapId >= 0,
    "field context needs a map id"
  )
  assert(FieldMapDataCache.hasFieldUsePolicy(sources.fieldUse), "field context requires the generated field-use policy")
  assert(AVATAR_MODES[sources.avatarMode], "field context avatar mode is invalid")
  for _, key in ipairs({ "humanFollower", "followingMon", "rocketCostume", "safari", "palPark" }) do
    assert(isBool(sources[key]), "field context flag " .. key .. " must be a boolean")
  end
  for _, key in ipairs({
    "surfEdge",
    "facingWaterfall",
    "facingWhirlpool",
    "climbTile",
    "headbuttTree",
    "foggy",
    "chatterOpen",
  }) do
    assert(isBool(sources[key]), "field context tile " .. key .. " must be a boolean")
  end
  local policy = sources.fieldUse
  local use = {}
  for _, key in ipairs({
    "flyAllowed",
    "teleportAllowed",
    "escapeAllowed",
    "flashUsable",
    "alphChamber",
    "icePathB2F",
    "cave",
    "unionOrColosseum",
  }) do
    use[key] = policy[key]
  end
  local actorSnapshot = nil
  local obstacle = nil
  if sources.facingActor ~= nil then
    local actor = sources.facingActor
    assert(type(actor) == "table", "facing actor must be a record")
    assert(type(actor.identity) == "string" and actor.identity ~= "", "facing actor needs an identity")
    actorSnapshot = {
      identity = actor.identity,
      obstacleKind = actor.obstacleKind,
      mapSymbol = actor.mapSymbol,
      fieldX = actor.fieldX,
      fieldZ = actor.fieldZ,
    }
    obstacle = actor.obstacleKind
  end
  return {
    badges = sources.badges,
    unionOrColosseum = use.unionOrColosseum,
    mapSymbol = sources.mapSymbol,
    mapId = sources.mapId,
    avatarMode = sources.avatarMode,
    humanFollower = sources.humanFollower,
    followingMon = sources.followingMon,
    rocketCostume = sources.rocketCostume,
    safari = sources.safari,
    palPark = sources.palPark,
    weatherId = sources.weatherId,
    facingObstacle = obstacle,
    facingActor = actorSnapshot,
    surfEdge = sources.surfEdge,
    facingWaterfall = sources.facingWaterfall,
    facingWhirlpool = sources.facingWhirlpool,
    climbTile = sources.climbTile,
    headbuttTree = sources.headbuttTree,
    foggy = sources.foggy,
    chatterOpen = sources.chatterOpen,
    fieldUse = use,
  }
end

return FieldMoveContext
