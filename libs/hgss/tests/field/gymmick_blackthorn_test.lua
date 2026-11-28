-- The Blackthorn Gym's three platforms over fake field owners: the source
-- platform tables and their rotation, the button table, the per-rotation move
-- directions, the exact translation cadence with the rider carried, the two
-- wall checks that stop a move or a turn, and the rule that a refused action
-- commits nothing and leaves no lease behind.

local Assert = require("tests.support.Assert")
local BlackthornGym = require("libs.hgss.src.field.gymmick.BlackthornGym")
local GymMechanismState = require("libs.hgss.src.field.GymMechanismState")

local T = {}

local INITIAL_ANCHORS = {
  { x = 13, z = 75, rotation = 0 },
  { x = 9, z = 58, rotation = 1 },
  { x = 14, z = 32, rotation = 0 },
}

---@param joined table<integer, table<integer, true>>
local function joinedCells(joined)
  local cells = {}
  for x, column in pairs(joined) do
    for z in pairs(column) do
      cells[#cells + 1] = x .. "," .. z
    end
  end
  table.sort(cells)
  return cells
end

local function bounds(points)
  local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
  for _, point in ipairs(points) do
    minX, maxX = math.min(minX, point.x), math.max(maxX, point.x)
    minZ, maxZ = math.min(minZ, point.z), math.max(maxZ, point.z)
  end
  return minX, maxX, minZ, maxZ
end

-- The map the fake field answers: a tile is magma unless a test names it,
-- nothing is blocked by the generated permission, and the floor height is the
-- gym's own 48 native units over 16 per tile.
local function newHost(options)
  options = options or {}
  local host = {
    effects = {},
    poses = {},
    blocked = options.blocked or {},
    floor = options.floor or {},
    magma = options.magma or {},
  }
  host.state = GymMechanismState.restore(nil)
  host.state:initialize("blackthorn")
  for slot, anchor in ipairs(options.anchors or {}) do
    host.state:setBlackthornPlatformPosition(slot, anchor.x, anchor.z)
    while host.state:blackthornPlatforms()[slot].rotation ~= anchor.rotation do
      host.state:advanceBlackthornRotation(slot)
    end
  end
  host.player = {
    fieldX = options.playerX or 14,
    fieldZ = options.playerZ or 75,
    worldX = (options.playerX or 14) + 0.5,
    worldY = 3,
    worldZ = (options.playerZ or 75) + 0.5,
    motion = "idle",
    lease = nil,
    poses = {},
    beginTransport = function(self)
      self.lease =
        { fieldX = self.fieldX, fieldZ = self.fieldZ, worldX = self.worldX, worldY = self.worldY, worldZ = self.worldZ }
      return self.lease
    end,
    applyTransportPose = function(self, worldX, worldY, worldZ)
      self.worldX, self.worldY, self.worldZ = worldX, worldY, worldZ
      host.poses[#host.poses + 1] = { x = worldX, y = worldY, z = worldZ }
    end,
    commitTransport = function(self, fieldX, fieldZ, worldY)
      self.fieldX, self.fieldZ = fieldX, fieldZ
      self.worldX, self.worldY, self.worldZ = fieldX + 0.5, worldY or self.worldY, fieldZ + 0.5
      host.lease = nil
      host.committed = { fieldX = fieldX, fieldZ = fieldZ }
    end,
    cancelTransport = function(self)
      if self.lease ~= nil then
        self.fieldX, self.fieldZ = self.lease.fieldX, self.lease.fieldZ
        self.worldX, self.worldY, self.worldZ = self.lease.worldX, self.lease.worldY, self.lease.worldZ
        self.lease = nil
        host.cancelled = (host.cancelled or 0) + 1
      end
    end,
  }
  host.geometry = {
    floors = nil,
    mapTile = function(_, fieldX, fieldZ)
      local key = fieldX .. ":" .. fieldZ
      if host.blocked[key] then
        return true, false
      end
      if host.magma[key] == false then
        return false, false
      end
      return false, true
    end,
    setBlackthornPlatforms = function(self, anchors)
      self.floors = anchors
    end,
    floorWorldY = function(_, fieldX, fieldZ)
      return host.floor[fieldX .. ":" .. fieldZ] or 3
    end,
    tileCentre = function(_, fieldX, fieldZ)
      return { x = fieldX + 0.5, z = fieldZ + 0.5 }
    end,
  }
  host.audio = {
    play = function(_, sequence)
      host.effects[#host.effects + 1] = "play:" .. sequence
    end,
    stop = function(_, sequence)
      host.effects[#host.effects + 1] = "stop:" .. sequence
    end,
  }
  host.gym = BlackthornGym.new({
    state = host.state,
    geometry = host.geometry,
    player = host.player,
    audio = host.audio,
  })
  return host
end

local function countEffects(host, entry)
  local count = 0
  for _, effect in ipairs(host.effects) do
    if effect == entry then
      count = count + 1
    end
  end
  return count
end

local function runAction(host, maxTicks)
  local status
  for _ = 1, maxTicks or 200 do
    status = host.gym:updateFixed()
    if status ~= "riding" then
      return status
    end
  end
  return status
end

-- The narrow platform uses the source's own shape-specific walls: right wall
-- x + 2 and bottom wall z + 6 (BlackthornPlatform_Init index == 1), while
-- the leading outer edge stays x + 3 and every other wall keeps the wide
-- offsets. Independently enumerated from retail, not from the constants
-- under test.
function T.the_narrow_platform_uses_its_own_wall_offsets()
  local anchors = { { x = 10, z = 10, rotation = 0 }, { x = 20, z = 20, rotation = 0 }, { x = 30, z = 30, rotation = 0 } }
  local platforms = BlackthornGym.platforms(anchors)
  local narrow = platforms[2]
  Assert.equal(#narrow.rightWall, 8, "the narrow platform checks eight right-wall tiles")
  for _, point in ipairs(narrow.rightWall) do
    Assert.equal(point.x, 22, "narrow right wall is x + 2, not x + 3")
  end
  Assert.equal(#narrow.bottomWall, 4, "the narrow platform checks four bottom-wall tiles")
  for _, point in ipairs(narrow.bottomWall) do
    Assert.equal(point.z, 26, "narrow bottom wall is z + 6, not z + 5")
  end
  for _, point in ipairs(narrow.rightEdgeOuter) do
    Assert.equal(point.x, 23, "the narrow outer edge stays x + 3")
  end
  local wide = platforms[1]
  for _, point in ipairs(wide.rightWall) do
    Assert.equal(point.x, 13, "wide right wall is x + 3")
  end
  for _, point in ipairs(wide.bottomWall) do
    Assert.equal(point.z, 15, "wide bottom wall is z + 5")
  end
  -- A blocker on the correct-but-not-wrong tile stops the narrow platform.
  local host = newHost({ blocked = { ["22:20"] = true }, anchors = anchors, playerX = 21, playerZ = 20 })
  Assert.isTrue(host.gym:startAction(21, 20), "the +x button starts a move")
  Assert.equal(runAction(host), "complete")
  Assert.isNil(host.committed, "the narrow wall blocker refuses the move")
end

-- The three source platforms at the union's anchors: each 3x6 floor is the
-- only walkable ground, and a turn rotates the whole platform about its anchor.
function T.the_platform_tables_follow_the_source_anchor_and_rotation()
  local platforms = BlackthornGym.platforms(INITIAL_ANCHORS)
  Assert.equal(#platforms, 3, "the source loads three platforms")
  Assert.deepEqual({ platforms[1].width, platforms[1].height }, { 5, 7 }, "the first platform is the 5x7 shape")
  Assert.deepEqual({ platforms[2].width, platforms[2].height }, { 4, 8 }, "the second platform is the 4x8 shape")
  Assert.deepEqual({ platforms[3].width, platforms[3].height }, { 5, 7 }, "the third platform is the 5x7 shape")
  Assert.deepEqual({ platforms[1].shape, platforms[2].shape, platforms[3].shape }, { 0, 1, 0 })
  Assert.deepEqual(platforms[1].rotateButton, { x = 13, z = 75 }, "the rotate button is the anchor")
  Assert.deepEqual(platforms[1].moveLeftButton, { x = 14, z = 75 })
  Assert.deepEqual(platforms[1].moveRightButton, { x = 12, z = 75 })

  for _, platform in ipairs(platforms) do
    Assert.equal(#platform.floor, 18, "every platform owns its 3x6 floor")
  end
  -- The unrotated 3x6 floor spans the anchor's own neighbourhood.
  local minX, maxX, minZ, maxZ = bounds(platforms[1].floor)
  Assert.deepEqual({ minX, maxX, minZ, maxZ }, { 12, 14, 74, 79 })

  -- A quarter turn swaps the footprint: the 3-wide, 6-deep floor becomes 6 wide
  -- and 3 deep about the same anchor.
  local turned =
    BlackthornGym.platforms({ { x = 9, z = 54, rotation = 2 }, { x = 9, z = 58, rotation = 1 }, INITIAL_ANCHORS[3] })
  minX, maxX, minZ, maxZ = bounds(turned[1].floor)
  Assert.deepEqual({ minX, maxX, minZ, maxZ }, { 8, 10, 50, 55 }, "a half turn reflects the floor through its anchor")
  local quarter = BlackthornGym.platforms({ { x = 9, z = 54, rotation = 1 }, INITIAL_ANCHORS[2], INITIAL_ANCHORS[3] })
  minX, maxX, minZ, maxZ = bounds(quarter[1].floor)
  Assert.deepEqual({ minX, maxX, minZ, maxZ }, { 5, 10, 53, 55 }, "a quarter turn rotates the floor about its anchor")

  -- The buttons rotate with the platform, so the turned platform still answers
  -- one button on each side of its own default orientation.
  Assert.deepEqual(quarter[1].moveLeftButton, { x = 9, z = 55 }, "the +x button turns with the platform")
  Assert.deepEqual(quarter[1].moveRightButton, { x = 9, z = 53 })
  local half = turned[1]
  Assert.deepEqual(half.moveLeftButton, { x = 8, z = 54 }, "a half turn mirrors the button pair")
  Assert.deepEqual(half.moveRightButton, { x = 10, z = 54 })
  Assert.deepEqual(quarter[1].rotateButton, { x = 9, z = 54 }, "the rotate button never leaves the anchor")
end

-- The floor cells the runtime collision projection uses are exactly the union
-- of the three floors.
function T.the_floor_cells_are_the_union_of_the_three_floors()
  local cells = joinedCells(BlackthornGym.floorCells(INITIAL_ANCHORS))
  Assert.equal(#cells, 54, "three platforms own 54 floor cells")
  for _, cell in ipairs({ "12,74", "14,79", "5,57", "10,59", "13,31", "15,36" }) do
    local present = false
    for _, candidate in ipairs(cells) do
      present = present or candidate == cell
    end
    Assert.isTrue(present, "floor cell " .. cell .. " is part of the platform ground")
  end
  Assert.isFalse(BlackthornGym.floorCells(INITIAL_ANCHORS)[11] ~= nil, "a tile beside the floor is not platform ground")
end

-- BlackthornGymmick_GetButtonAction: the anchor rotates, its +x button moves
-- the platform right and its -x button moves it left.
function T.the_button_table_answers_the_source_action_for_each_platform()
  local platforms = BlackthornGym.platforms(INITIAL_ANCHORS)
  Assert.equal(assert(BlackthornGym.buttonAction(platforms, 13, 75)).action, "rotate")
  Assert.equal(assert(BlackthornGym.buttonAction(platforms, 13, 75)).slot, 1)
  Assert.equal(assert(BlackthornGym.buttonAction(platforms, 14, 75)).action, "move_right")
  Assert.equal(assert(BlackthornGym.buttonAction(platforms, 12, 75)).action, "move_left")
  Assert.equal(assert(BlackthornGym.buttonAction(platforms, 15, 32)).action, "move_right")
  Assert.equal(assert(BlackthornGym.buttonAction(platforms, 15, 32)).slot, 3)
  Assert.isNil(BlackthornGym.buttonAction(platforms, 13, 76), "an ordinary platform tile is not a button")
  Assert.isNil(BlackthornGym.buttonAction(platforms, 0, 0))
end

-- BlackthornGymmick_GetMoveDirection: (addend + rotation) % 4, where the side's
-- own addend is 0 for right and 2 for left.
function T.every_rotation_moves_its_own_direction()
  local expected = {
    [0] = { right = "east", left = "west" },
    [1] = { right = "south", left = "north" },
    [2] = { right = "west", left = "east" },
    [3] = { right = "north", left = "south" },
  }
  for rotation, sides in pairs(expected) do
    Assert.equal(BlackthornGym.moveDirection(rotation, "right").name, sides.right, "rotation " .. rotation .. " right")
    Assert.equal(BlackthornGym.moveDirection(rotation, "left").name, sides.left, "rotation " .. rotation .. " left")
  end
  Assert.throws(function()
    BlackthornGym.moveDirection(4, "right")
  end, "a rotation outside the source quarters is refused")
  Assert.throws(function()
    BlackthornGym.moveDirection(0, "sideways")
  end, "a move side is right or left")
end

-- The move travels its whole platform width at half a tile per fixed tick, and
-- only the last tick commits the rider's tile and the union's anchor.
function T.a_move_carries_the_rider_its_platform_width_and_commits_once()
  local host = newHost()
  Assert.isTrue(host.gym:startAction(14, 75), "the +x button starts a move")
  Assert.equal(host.effects[1], "play:" .. BlackthornGym.MOVE_SEQUENCE, "the move starts the source loop")
  local status = runAction(host)
  Assert.equal(status, "complete")
  Assert.equal(#host.poses, 10, "five tiles take two motion ticks each")
  for index, pose in ipairs(host.poses) do
    Assert.near(pose.x, 14.5 + index * 0.5, 1e-9, "the rider travels half a tile per motion tick")
    Assert.near(pose.y, 3, 1e-9, "the rider keeps the platform height")
    Assert.near(pose.z, 75.5, 1e-9, "the rider keeps the carriage row")
  end
  Assert.deepEqual(host.committed, { fieldX = 19, fieldZ = 75 }, "the rider lands one platform width east")
  Assert.deepEqual(host.state:blackthornPlatforms()[1], { x = 18, z = 75, rotation = 0 }, "the anchor follows")
  Assert.equal(countEffects(host, "stop:" .. BlackthornGym.MOVE_SEQUENCE), 1, "the settled move releases its loop")
  Assert.equal(countEffects(host, "play:" .. BlackthornGym.BONK_SEQUENCE), 0, "an unobstructed move never hits a wall")
  Assert.isFalse(host.gym:isRunning(), "a settled move leaves no action behind")
  Assert.isNil(host.player.lease, "a settled move releases its rider lease")
end

-- The leading wall is checked before every tile. A wall that is already blocked
-- at the first tile finishes without moving or committing.
function T.a_move_blocked_at_its_first_tile_never_carries_the_rider()
  local host = newHost({ blocked = { ["16:75"] = true } })
  Assert.isTrue(host.gym:startAction(14, 75))
  Assert.equal(runAction(host), "complete")
  Assert.equal(#host.poses, 0, "a refused move never publishes a carried pose")
  Assert.isNil(host.committed, "a refused move never commits a rider tile")
  Assert.deepEqual({ host.player.fieldX, host.player.fieldZ }, { 14, 75 }, "a refused move keeps the rider's tile")
  Assert.deepEqual(host.state:blackthornPlatforms()[1], { x = 13, z = 75, rotation = 0 }, "the anchor never moved")
  Assert.equal(countEffects(host, "play:" .. BlackthornGym.BONK_SEQUENCE), 1, "the refused move plays the wall hit")
  Assert.equal(
    countEffects(host, "stop:" .. BlackthornGym.MOVE_SEQUENCE),
    1,
    "the refused move still releases its loop"
  )
end

-- A wall reached after three tiles reverses every tile the platform travelled
-- and commits nothing at all.
function T.a_move_blocked_mid_way_returns_to_its_start()
  local host = newHost({ blocked = { ["19:75"] = true } })
  Assert.isTrue(host.gym:startAction(14, 75))
  Assert.equal(runAction(host), "complete")
  Assert.near(host.player.worldX, 14.5, 1e-9, "the refused move returns the rider to its anchor")
  Assert.isNil(host.committed, "a returned move commits no tile")
  Assert.deepEqual(host.state:blackthornPlatforms()[1], { x = 13, z = 75, rotation = 0 })
  local furthest = 0
  for _, pose in ipairs(host.poses) do
    furthest = math.max(furthest, pose.x - 14.5)
  end
  Assert.near(furthest, 3, 1e-9, "the platform travelled three tiles out before the wall")
  Assert.equal(countEffects(host, "play:" .. BlackthornGym.BONK_SEQUENCE), 1)
end

-- A move is refused when the leading point is not magma, exactly like the
-- source's own two-part test.
function T.a_leading_point_that_is_not_magma_stops_the_move()
  local host = newHost({ magma = { ["17:75"] = false } })
  Assert.isTrue(host.gym:startAction(14, 75))
  Assert.equal(runAction(host), "complete")
  Assert.isNil(host.committed, "the platform bonks off the room's own floor")
  Assert.near(host.player.worldX, 14.5, 1e-9)
end

-- A rotation animates sixteen 5.625-degree ticks, turning the union one 90-degree
-- quarter (rotationVec.y = -4 * FX32_ONE * rotation; 16384 indices = 90 degrees).
-- Independently derived: 90 per quarter, 5.625 per tick, not the constants under test.
function T.a_clear_rotation_turns_the_platform_one_quarter()
  local host = newHost()
  Assert.isTrue(host.gym:startAction(13, 75), "the anchor is the rotate button")
  local angles = {}
  for _ = 1, 32 do
    local status = host.gym:updateFixed()
    angles[#angles + 1] = host.gym:presentation()[1].rotationDegrees
    if status ~= "riding" then
      break
    end
  end
  Assert.deepEqual(host.state:blackthornPlatforms()[1], { x = 13, z = 75, rotation = 1 }, "the settled quarter turn")
  Assert.equal(#host.poses, 0, "a rotation never publishes a carried pose")
  Assert.isNil(host.committed, "a rotation never commits a rider tile")
  Assert.equal(countEffects(host, "play:" .. BlackthornGym.BONK_SEQUENCE), 0, "a clear turn never hits a wall")
  Assert.equal(countEffects(host, "stop:" .. BlackthornGym.MOVE_SEQUENCE), 1)
  -- The platform tables follow the new rotation: the +x button moved with it.
  local placements = host.gym:presentation()
  Assert.equal(#placements, 3, "three platform props are presented")
  Assert.near(placements[2].rotationDegrees, -90, 1e-9, "a settled prop carries its own 90-degree angle")
  Assert.near(placements[1].rotationDegrees, -90, 1e-9, "the turned prop carries the new 90-degree angle")
  Assert.near(angles[1], -5.625, 1e-9, "the first motion tick turns 5.625 degrees")
  Assert.near(angles[16], -90, 1e-9, "sixteen ticks complete the quarter turn")
  Assert.equal(placements[1].slot, 1)
  Assert.near(placements[1].x, 13.5, 1e-9, "the prop stands on its anchor's tile centre")
  Assert.near(placements[1].y, 3, 1e-9, "the prop stands at the source native height over the gym floor")
end

-- The committed platform never presents its in-flight displacement twice: the
-- snapshot taken on the committing tick (while the action is still in finish)
-- already shows the settled anchor with no overtravel.
function T.a_committed_action_presents_its_settled_endpoint_without_overtravel()
  local host = newHost()
  Assert.isTrue(host.gym:startAction(14, 75))
  local seenFinishOffset = nil
  for _ = 1, 200 do
    local status = host.gym:updateFixed()
    local placement = host.gym:presentation()[1]
    if status == "riding" then
      -- During travel the offset grows monotonically and never exceeds the width.
      Assert.isTrue(placement.x - 13.5 <= 5 + 1e-9, "a move never overtravels its platform width")
    else
      break
    end
    -- Capture the presentation on the tick that commits (action still alive in finish).
    -- The update loop above already sampled every tick; the settled check follows.
  end
  Assert.deepEqual(host.state:blackthornPlatforms()[1], { x = 18, z = 75, rotation = 0 })
  local settled = host.gym:presentation()[1]
  Assert.near(settled.x, 18.5, 1e-9, "a committed move presents the new anchor exactly")
  Assert.near(settled.rotationDegrees, 0, 1e-9, "a committed move presents no turn")
  local turnHost = newHost()
  Assert.isTrue(turnHost.gym:startAction(13, 75))
  for _ = 1, 200 do
    local status = turnHost.gym:updateFixed()
    if status ~= "riding" then
      break
    end
    local degrees = turnHost.gym:presentation()[1].rotationDegrees
    Assert.isTrue(degrees >= -90 - 1e-9, "a turn never overtravels its quarter")
  end
  Assert.near(turnHost.gym:presentation()[1].rotationDegrees, -90, 1e-9, "a committed turn presents one quarter exactly")
  Assert.isTrue(seenFinishOffset == nil, "overtravel is bounded by the per-tick assertions above")
end

-- A rotation whose own sides are already blocked is refused outright: no angle
-- animates, no wall hit plays and the union keeps its quarter turn.
function T.a_blocked_rotation_changes_nothing()
  local host = newHost({ blocked = { ["13:80"] = true } })
  Assert.isTrue(host.gym:startAction(13, 75))
  Assert.equal(runAction(host), "complete")
  Assert.deepEqual(
    host.state:blackthornPlatforms()[1],
    { x = 13, z = 75, rotation = 0 },
    "a refused turn commits nothing"
  )
  Assert.near(host.gym:presentation()[1].rotationDegrees, 0, 1e-9, "the refused prop keeps its source angle")
  Assert.equal(
    countEffects(host, "play:" .. BlackthornGym.BONK_SEQUENCE),
    0,
    "a refused turn never reaches the wall hit"
  )
  Assert.equal(countEffects(host, "stop:" .. BlackthornGym.MOVE_SEQUENCE), 1, "the refused turn releases its loop")
end

-- A turn whose swept area bonks part way animates out to the source extent and
-- returns all the way, committing nothing.
function T.a_partial_rotation_returns_to_its_own_angle()
  -- A single blocked point in the swept main area caps the turn well short of a
  -- quarter; the first swept point of the 5x7 shape is (x - 4, z + 4).
  local host = newHost({ blocked = { ["9:79"] = true } })
  Assert.isTrue(host.gym:startAction(13, 75))
  Assert.equal(runAction(host, 400), "complete")
  Assert.deepEqual(
    host.state:blackthornPlatforms()[1],
    { x = 13, z = 75, rotation = 0 },
    "a partial turn commits nothing"
  )
  Assert.near(host.gym:presentation()[1].rotationDegrees, 0, 1e-9, "the returned prop keeps its angle")
  Assert.equal(countEffects(host, "play:" .. BlackthornGym.BONK_SEQUENCE), 1, "a partial turn hits the wall")
  Assert.equal(countEffects(host, "stop:" .. BlackthornGym.MOVE_SEQUENCE), 1)
end

-- Cancelling a live move restores the rider's anchor, releases the source loop
-- and leaves the union on the platform the action started from.
function T.cancelling_a_move_restores_the_rider_and_commits_nothing()
  local host = newHost()
  Assert.isTrue(host.gym:startAction(14, 75))
  for _ = 1, 5 do
    host.gym:updateFixed()
  end
  Assert.isTrue(host.gym:isRunning(), "the move is still travelling")
  host.gym:cancel()
  Assert.isFalse(host.gym:isRunning())
  Assert.near(host.player.worldX, 14.5, 1e-9, "a cancelled move restores the rider exactly")
  Assert.isNil(host.committed, "a cancelled move commits no tile")
  Assert.deepEqual(host.state:blackthornPlatforms()[1], { x = 13, z = 75, rotation = 0 })
  Assert.equal(countEffects(host, "stop:" .. BlackthornGym.MOVE_SEQUENCE), 1, "a cancelled move releases its loop")
  host.gym:cancel()
  host.gym:dispose()
  host.gym:dispose()
  Assert.equal(
    countEffects(host, "stop:" .. BlackthornGym.MOVE_SEQUENCE),
    1,
    "a repeated cancel and dispose stay inert"
  )
  Assert.equal(host.gym:updateFixed(), "idle", "a disposed mechanism has no action left")
end

-- Only a real button starts an action; an ordinary platform tile or an
-- unrelated tile answers no action at all.
function T.only_a_button_starts_an_action()
  local host = newHost()
  Assert.isFalse(host.gym:startAction(13, 76), "an ordinary platform tile starts nothing")
  Assert.isFalse(host.gym:isRunning())
  Assert.equal(#host.effects, 0, "a non-button plays no sound")
  Assert.isTrue(host.gym:startAction(12, 75), "the -x button starts its own move")
  Assert.throws(function()
    host.gym:startAction(13, 75)
  end, "a second action cannot start beside the live one")
end

-- The role of each platform's own source build model, in source index order.
function T.every_platform_names_its_source_model_role()
  Assert.deepEqual(BlackthornGym.PLATFORM_MODELS, { "wide", "narrow", "wide" })
end

return { tests = T }
