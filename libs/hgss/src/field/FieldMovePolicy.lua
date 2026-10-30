-- Pure ordered field-move eligibility checks over copied context
-- records. The predicate order below is the contract, not just the final
-- booleans: paired failures prove the first source reason wins. Never
-- queries presentation, host time, or private runtime fields, and never
-- mutates the context. Pure domain module: no love dependency and no I/O.
--
-- Source basis: the retail ROM's field-move checks (field_move.c) and the
-- Escape Rope item check. Badge semantics follow the durable progression
-- order. Checks answer eligibility only; moves whose execution is not yet
-- implemented report that at the runtime layer.

local FieldMovePolicy = {}

FieldMovePolicy.MOVE_KEYS = {
  "cut",
  "fly",
  "surf",
  "strength",
  "flash",
  "rock_smash",
  "waterfall",
  "whirlpool",
  "rock_climb",
  "dig",
  "teleport",
  "headbutt",
  "sweet_scent",
  "chatter",
}

-- Badge bit per semantic badge key, following the progression order.
local BADGE_BITS = {
  zephyr = 0,
  hive = 1,
  plain = 2,
  fog = 3,
  storm = 4,
  mineral = 5,
  glacier = 6,
  rising = 7,
  boulder = 8,
  cascade = 9,
  thunder = 10,
  rainbow = 11,
  soul = 12,
  marsh = 13,
  volcano = 14,
  earth = 15,
}

local function hasBadge(badges, key)
  local bit = assert(BADGE_BITS[key], "unknown badge key " .. tostring(key))
  return (math.floor(badges / (2 ^ bit)) % 2) == 1
end

local function fieldUse(context)
  local policy = context.fieldUse
  assert(type(policy) == "table", "field checks require the generated map policy")
  return policy
end

-- Source WEATHER_FLASH: the dark-cave weather Flash can light. Using Flash
-- switches to a different weather, so the check fails afterwards.
local WEATHER_FLASH = 11

-- A visible following mon is not the source's human-escort restriction.
local function escortRefusal(context)
  if context.humanFollower then
    return { kind = "have_follower" }
  end
  return nil
end

local function checkCut(context)
  if not hasBadge(context.badges, "hive") then
    return { kind = "need_badge", badge = "hive" }
  end
  if context.facingObstacle ~= "cut_tree" then
    return { kind = "not_here" }
  end
  -- Field checks do not consume a move's PP or enable it globally.
  return { kind = "ok" }
end

local function checkFly(context)
  if not hasBadge(context.badges, "storm") then
    return { kind = "need_badge", badge = "storm" }
  end
  if not fieldUse(context).flyAllowed then
    return { kind = "not_here" }
  end
  local escort = escortRefusal(context)
  if escort then
    return escort
  end
  if context.rocketCostume then
    return { kind = "not_now" }
  end
  if context.safari or context.palPark then
    return { kind = "not_here" }
  end
  return { kind = "ok" }
end

local function checkSurf(context)
  if not hasBadge(context.badges, "fog") then
    return { kind = "need_badge", badge = "fog" }
  end
  if context.avatarMode == "surfing" then
    return { kind = "already_surfing" }
  end
  if not context.surfEdge then
    return { kind = "not_here" }
  end
  local escort = escortRefusal(context)
  if escort then
    return escort
  end
  -- Field checks do not consume a move's PP or enable it globally.
  if context.rocketCostume then
    return { kind = "not_now" }
  end
  return { kind = "ok" }
end

local function checkStrength(context)
  if not hasBadge(context.badges, "plain") then
    return { kind = "need_badge", badge = "plain" }
  end
  if fieldUse(context).icePathB2F then
    return { kind = "not_here", reason = "ice_path_b2f" }
  end
  if context.facingObstacle ~= "strength_boulder" then
    return { kind = "not_here" }
  end
  -- Field checks do not consume a move's PP or enable it globally.
  return { kind = "ok" }
end

local function checkFlash(context)
  if context.alphFlashSpot or context.weatherId == WEATHER_FLASH then
    return { kind = "ok" }
  end
  return { kind = "not_here" }
end

local function checkRockSmash(context)
  if not hasBadge(context.badges, "zephyr") then
    return { kind = "need_badge", badge = "zephyr" }
  end
  if context.facingObstacle ~= "smash_rock" then
    return { kind = "not_here" }
  end
  -- Field checks do not consume a move's PP or enable it globally.
  return { kind = "ok" }
end

local function checkWaterfall(context)
  if context.avatarMode ~= "surfing" then
    return { kind = "not_here" }
  end
  if not hasBadge(context.badges, "rising") then
    return { kind = "need_badge", badge = "rising" }
  end
  if not context.facingWaterfall then
    return { kind = "not_here" }
  end
  -- Field checks do not consume a move's PP or enable it globally.
  return { kind = "ok" }
end

local function checkWhirlpool(context)
  if context.avatarMode ~= "surfing" then
    return { kind = "not_here" }
  end
  if not hasBadge(context.badges, "glacier") then
    return { kind = "need_badge", badge = "glacier" }
  end
  if not context.facingWhirlpool then
    return { kind = "not_here" }
  end
  -- Field checks do not consume a move's PP or enable it globally.
  return { kind = "ok" }
end

local function checkRockClimb(context)
  if not hasBadge(context.badges, "earth") then
    return { kind = "need_badge", badge = "earth" }
  end
  if not context.climbTile then
    return { kind = "not_here" }
  end
  local escort = escortRefusal(context)
  if escort then
    return escort
  end
  -- Field checks do not consume a move's PP or enable it globally.
  if context.rocketCostume then
    return { kind = "not_now" }
  end
  return { kind = "ok" }
end

local function checkDig(context)
  local policy = fieldUse(context)
  if not policy.cave or not policy.escapeAllowed then
    return { kind = "not_here" }
  end
  local escort = escortRefusal(context)
  if escort then
    return escort
  end
  -- Field checks do not consume a move's PP or enable it globally.
  if context.rocketCostume then
    return { kind = "not_now" }
  end
  return { kind = "ok" }
end

local function checkTeleport(context)
  if not fieldUse(context).teleportAllowed then
    return { kind = "not_here" }
  end
  local escort = escortRefusal(context)
  if escort then
    return escort
  end
  if context.rocketCostume then
    return { kind = "not_now" }
  end
  if context.safari or context.palPark then
    return { kind = "not_here" }
  end
  return { kind = "ok" }
end

local function checkHeadbutt(context)
  if not context.headbuttTree then
    return { kind = "not_here" }
  end
  return { kind = "ok" }
end

local function checkSweetScent(context)
  if context.palPark then
    return { kind = "not_here" }
  end
  return { kind = "ok" }
end

local function checkChatter(_)
  return { kind = "ok" }
end

-- The Escape Rope bag item shares the field-move vocabulary but is not a
-- party move: escort and costume refusals precede the Alph first-room
-- exception, then the cave rule.
---@param context table<string, unknown> a copied read-only context record
---@return table<string, unknown>
function FieldMovePolicy.checkEscapeRope(context)
  assert(type(context) == "table", "field checks require a context record")
  local escort = escortRefusal(context)
  if escort then
    return escort
  end
  if context.rocketCostume then
    return { kind = "not_now" }
  end
  if context.alphEscapeRopeSpot then
    return { kind = "ok" }
  end
  local policy = fieldUse(context)
  if not policy.cave or not policy.escapeAllowed then
    return { kind = "not_here" }
  end
  return { kind = "ok" }
end

local CHECKS = {
  cut = checkCut,
  fly = checkFly,
  surf = checkSurf,
  strength = checkStrength,
  flash = checkFlash,
  rock_smash = checkRockSmash,
  waterfall = checkWaterfall,
  whirlpool = checkWhirlpool,
  rock_climb = checkRockClimb,
  dig = checkDig,
  teleport = checkTeleport,
  headbutt = checkHeadbutt,
  sweet_scent = checkSweetScent,
  chatter = checkChatter,
}

---@param moveKey string
---@param context table<string, unknown> a copied read-only context record
---@return table<string, unknown> { kind: string, badge?: string, reason?: string }
function FieldMovePolicy.check(moveKey, context)
  local check = CHECKS[moveKey]
  assert(check ~= nil, "unknown field move " .. tostring(moveKey))
  assert(type(context) == "table", "field checks require a context record")
  if context.unionOrColosseum then
    return { kind = "not_here", reason = "union_or_colosseum" }
  end
  return check(context)
end

return FieldMovePolicy
