-- The Blackthorn Gym's three moving platforms (src/field/gymmick/blackthorn.c).
-- Each platform is one source prop standing on a save-owned anchor tile pair
-- and quarter-turn rotation (include/gymmick.h::GymmickUnion.blackthorn); its
-- 3x6 floor is the only ground over the gym's lava, and the three buttons it
-- carries start a translation or a rotation of the whole platform:
--
--   rotate button       the anchor tile itself, always ACTION_ROTATE
--   moveLeftButton      anchor x + 1 in default orientation, ACTION_MOVE_RIGHT
--   moveRightButton     anchor x - 1 in default orientation, ACTION_MOVE_LEFT
--
-- Everything else is rotated about the anchor with the platform
-- (BlackthornPlatform_ApplyRotation), so a turned platform answers its buttons,
-- its floor and its walls in the turned frame. A move travels one platform
-- width in the direction the rotation implies, one tile per two 8-unit motion
-- ticks, and the rider is carried with it; a rotation is one 4-degree quarter
-- turn animated over sixteen 0.25-degree ticks.
--
-- Both actions test their leading geometry over the map's own collision and
-- metatile behavior first (BlackthornGymmick_CheckWallCollision accepts a point
-- only when it is unblocked and magma). A blocked move reverses every tile it
-- travelled, a blocked rotation reverses its animated angle, and neither
-- commits: the union keeps the anchor and rotation the action started from.
--
-- This module owns the source tables and the two pure derivations the runtime
-- geometry projects (the floor cells and one tile's collision verdict) plus the
-- one in-flight action. It never walks the avatar, so no committed step,
-- terrain response or encounter comes out of a platform action.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")

---@class BlackthornGym.PlatformAnchor
---@field x integer the source anchor tile column
---@field z integer the source anchor tile row
---@field rotation integer settled quarter turn, 0..3

---@class BlackthornGym.Point
---@field x integer
---@field z integer

---@class BlackthornGym.Platform
---@field slot integer one-based source platform index
---@field x integer anchor column
---@field z integer anchor row
---@field rotation integer settled quarter turn
---@field shape integer 0 for the 5x7 platform, 1 for the 4x8 one
---@field width integer platform width in tiles
---@field height integer platform depth in tiles
---@field floor BlackthornGym.Point[] the 3x6 walkable floor, rotated
---@field rotateButton BlackthornGym.Point
---@field moveRightButton BlackthornGym.Point
---@field moveLeftButton BlackthornGym.Point
---@field rightWall BlackthornGym.Point[] leading wall of an ACTION_MOVE_RIGHT
---@field leftWall BlackthornGym.Point[] leading wall of an ACTION_MOVE_LEFT
---@field bottomWall BlackthornGym.Point[] the side the platform's south faces
---@field topWall BlackthornGym.Point[] the side the platform's north faces
---@field rotateCollisionCheck BlackthornGym.Point[] the swept main area of a turn
---@field rightEdgeOuter BlackthornGym.Point[] the swept leading edge of a turn

---@class BlackthornGym.ButtonAction
---@field slot integer the platform the button belongs to
---@field action string "rotate", "move_right" or "move_left"

-- The map tile facts the source algorithm reads: the generated permission and
-- whether the metatile behavior is TILE_BEHAVIOR_MAGMA.
---@class BlackthornGym.Geometry
---@field mapTile fun(self: table<string, unknown>, fieldX: integer, fieldZ: integer): boolean, boolean
---@field floorWorldY fun(self: table<string, unknown>, fieldX: number, fieldZ: number): number
---@field tileCentre fun(self: table<string, unknown>, fieldX: integer, fieldZ: integer): { x: number, z: number }|nil
---@field setBlackthornPlatforms fun(self: table<string, unknown>, anchors: BlackthornGym.PlatformAnchor[]?)

---@class BlackthornGymOptions
---@field state GymMechanismState the saved union this mechanism settles
---@field geometry BlackthornGym.Geometry the runtime map facts and projection
---@field player table<string, unknown> the transport player this mechanism carries
---@field audio table<string, unknown> the source audio host

---@class BlackthornGym.Action
---@field kind string "move" or "rotate"
---@field slot integer
---@field phase string
---@field direction { x: integer, z: integer }? the move direction, nil for a rotation
---@field distance integer the source platform width a move travels
---@field steps integer completed motion tiles
---@field timer integer motion ticks inside the current tile
---@field travelled number tiles carried (moves) or degrees turned (rotations)
---@field leadingWall BlackthornGym.Point[] the points the next tile is checked against
---@field extent integer the turn's animated extent in quarter-turn 1/64ths
---@field committed boolean whether the union already took this action
---@field origin { fieldX: integer, fieldZ: integer, worldX: number, worldY: number, worldZ: number } the rider's lease anchor

---@class BlackthornGym
---@field private _state GymMechanismState
---@field private _geometry BlackthornGym.Geometry
---@field private _player table<string, unknown>
---@field private _audio table<string, unknown>
---@field private _platforms BlackthornGym.Platform[]
---@field private _action BlackthornGym.Action?
---@field private _soundStopped boolean
local BlackthornGym = {}
BlackthornGym.__index = BlackthornGym

-- The source build models each platform loads in index order
-- (GymmickInit_Blackthorn: { 120, 121, 120 }). The generated effect bundle
-- publishes the two distinct models; the roles carry the platform footprints
-- so a runtime claim names the model it draws.
BlackthornGym.PLATFORM_MODELS = { "wide", "narrow", "wide" }

-- include/constants/sndseq.h: the platform action loop and the wall hit.
BlackthornGym.MOVE_SEQUENCE = "SEQ_SE_GS_GONDORA_IDOU"
BlackthornGym.BONK_SEQUENCE = "SEQ_SE_GS_GONDORA_KABEHIT"

-- include/constants/metatile_behavior.h::TILE_BEHAVIOR_MAGMA.
BlackthornGym.MAGMA_BEHAVIOR = 44

-- BlackthornGymmick_DirectionToVec moves the prop 8 * FX32_ONE per tick at 16
-- units per tile: half a tile, two ticks per tile.
BlackthornGym.MOTION_TILES = 0.5
BlackthornGym.TICKS_PER_TILE = 2

-- Task_BlackthornGymmick_RotatePlatform: sixteen 0.25-degree ticks make one
-- 4-degree quarter turn (rotationVec.y = -4 * FX32_ONE * rotation).
BlackthornGym.ROTATION_TICKS = 16
BlackthornGym.TURN_DEGREES = 0.25
BlackthornGym.QUARTER_DEGREES = 4

-- The rotation extent tables below count 1/64ths of a quarter turn, so 64 is
-- the full travel FX_DEG_TO_IDX(FX32_CONST(90)).
BlackthornGym.QUARTER_EXTENT = 64

-- BlackthornGymmick_GetButtonAction's three source buttons.
BlackthornGym.ACTION_ROTATE = "rotate"
BlackthornGym.ACTION_MOVE_RIGHT = "move_right"
BlackthornGym.ACTION_MOVE_LEFT = "move_left"

-- The source button sides: addend 0 walks the platform "right", 2 "left", both
-- measured in the platform's default orientation.
local MOVE_SIDES = { right = 0, left = 2 }

-- BlackthornGymmick_DirectionToVec, indexed by BlackthornGymmick_GetMoveDirection.
local MOVE_DIRECTIONS = {
  [0] = { name = "east", x = 1, z = 0 },
  [1] = { name = "south", x = 0, z = 1 },
  [2] = { name = "west", x = -1, z = 0 },
  [3] = { name = "north", x = 0, z = -1 },
}

-- PLATFORM_TYPE_0_W/H/AREA and PLATFORM_TYPE_1_W/H/AREA, then the two
-- rotation extent tables that bound a turn: the main swept area and the leading
-- outer edge (sMainAreaRotationExtents_Type0/1 and
-- sLeadingEdgeRotationExtents_Type0/1).
local SHAPES = {
  [0] = {
    width = 5,
    height = 7,
    mainExtents = { 10, 10, 13, 18, 25, 38, 51, 64, 64, 23, 28, 35, 45, 55 },
    leadingExtents = { 64, 64, 64, 64, 42 },
  },
  [1] = {
    width = 4,
    height = 8,
    mainExtents = { 8, 9, 10, 14, 19, 26, 37, 51, 64, 17, 19, 23, 28, 35, 46, 55, 64, 64, 64, 30, 35, 41, 49, 57 },
    leadingExtents = { 64, 20, 30, 46 },
  },
}

local FLOOR_WIDTH = 3
local FLOOR_DEPTH = 6
local PLATFORM_COUNT = 3

local ROTATION_BONK_NO_GO = "no_go"
local ROTATION_BONK_PARTIAL_GO = "partial_go"
local ROTATION_BONK_OK = "ok"

-- How a turn's own wall check starts: a refused turn finishes in its tick, a
-- partially blocked one hits the wall, a clear one runs its sixteen ticks.
local ROTATION_START_PHASES = {
  [ROTATION_BONK_NO_GO] = "finish",
  [ROTATION_BONK_PARTIAL_GO] = "rotate_bonk",
  [ROTATION_BONK_OK] = "rotate_run",
}

-- BlackthornGymmick_ApplyRotationToPoints: a point's offset from the anchor,
-- turned one quarter per rotation index. Rotation 0 returns the point as it is.
---@param rotation integer
---@param x integer anchor column
---@param z integer anchor row
---@param point BlackthornGym.Point
---@return BlackthornGym.Point
local function rotatePoint(rotation, x, z, point)
  local dx, dz = point.x - x, point.z - z
  if rotation == 1 then
    return { x = x - dz, z = z + dx }
  end
  if rotation == 2 then
    return { x = x - dx, z = z - dz }
  end
  if rotation == 3 then
    return { x = x + dz, z = z - dx }
  end
  return { x = point.x, z = point.z }
end

---@param rotation integer?
---@return integer
local function requireRotation(rotation)
  if type(rotation) ~= "number" or rotation % 1 ~= 0 or rotation < 0 or rotation > 3 then
    Errors.raise(FieldErrors.FIELD_GYM_MECHANISM_INVALID, "a platform rotation is one of the source quarters", {
      rotation = tostring(rotation),
    })
  end
  return assert(rotation)
end

---@param points BlackthornGym.Point[]
---@param vector { x: integer, z: integer }
---@return BlackthornGym.Point[]
local function translatePoints(points, vector)
  local moved = {}
  for index, point in ipairs(points) do
    moved[index] = { x = point.x + vector.x, z = point.z + vector.z }
  end
  return moved
end

---@param points BlackthornGym.Point[]
---@return BlackthornGym.Point[]
local function copyPoints(points)
  local copy = {}
  for index, point in ipairs(points) do
    copy[index] = { x = point.x, z = point.z }
  end
  return copy
end

-- BlackthornPlatform_Init: the source tables one platform owns at one anchor
-- and rotation, in default orientation and then turned about the anchor.
---@param slot integer one-based source platform index
---@param anchor BlackthornGym.PlatformAnchor
---@return BlackthornGym.Platform
local function buildPlatform(slot, anchor)
  local shapeIndex = slot == 2 and 1 or 0
  local shape = assert(SHAPES[shapeIndex], "the source platform shapes are closed")
  local x, z, rotation = anchor.x, anchor.z, requireRotation(anchor.rotation)
  local width, height = shape.width, shape.height

  local function point(pointX, pointZ)
    return rotatePoint(rotation, x, z, { x = pointX, z = pointZ })
  end

  local rotateButton = point(x, z)
  -- BlackthornPlatform_Init names the +x button moveLeftButton and the -x one
  -- moveRightButton; BlackthornGymmick_GetButtonAction maps them to the
  -- opposite action, which is why the pair below reads mirrored.
  local moveLeftButton = point(x + 1, z)
  local moveRightButton = point(x - 1, z)

  local rightWall = {}
  for index = 0, height - 1 do
    rightWall[#rightWall + 1] = point(x + 3, z - 2 + index)
  end
  local leftWall = {}
  for index = 0, height - 1 do
    leftWall[#leftWall + 1] = point(x - 3, z - 2 + index)
  end
  local bottomWall = {}
  for index = 0, width - 1 do
    bottomWall[#bottomWall + 1] = point(x - 2 + index, z + 5)
  end
  local topWall = {}
  for index = 0, width - 1 do
    topWall[#topWall + 1] = point(x - 2 + index, z - 3)
  end

  local rotateCollisionCheck = {}
  local sweepColumns = shapeIndex == 0 and 2 or 3
  local sweepTop = shapeIndex == 0 and 4 or 5
  for column = 0, sweepColumns - 1 do
    for row = 0, height - 1 do
      rotateCollisionCheck[#rotateCollisionCheck + 1] = point(x - 4 - column, z + sweepTop - row)
    end
  end

  local rightEdgeOuter = {}
  for index = 0, width - 1 do
    rightEdgeOuter[#rightEdgeOuter + 1] = point(x + 3, z - 2 + index)
  end

  local floor = {}
  for row = 0, FLOOR_DEPTH - 1 do
    for column = 0, FLOOR_WIDTH - 1 do
      floor[#floor + 1] = point(x - 1 + column, z - 1 + row)
    end
  end

  return {
    slot = slot,
    x = x,
    z = z,
    rotation = rotation,
    shape = shapeIndex,
    width = width,
    height = height,
    floor = floor,
    rotateButton = rotateButton,
    moveRightButton = moveRightButton,
    moveLeftButton = moveLeftButton,
    rightWall = rightWall,
    leftWall = leftWall,
    bottomWall = bottomWall,
    topWall = topWall,
    rotateCollisionCheck = rotateCollisionCheck,
    rightEdgeOuter = rightEdgeOuter,
  }
end

-- The three source platforms at the anchors the union carries.
---@param anchors BlackthornGym.PlatformAnchor[]
---@return BlackthornGym.Platform[]
function BlackthornGym.platforms(anchors)
  assert(type(anchors) == "table", "the platform builder needs the union's anchors")
  local platforms = {}
  for slot = 1, PLATFORM_COUNT do
    local anchor = assert(anchors[slot], "the blackthorn union carries three platform anchors")
    platforms[slot] = buildPlatform(slot, anchor)
  end
  return platforms
end

-- The gym's walkable platform ground: every platform's 3x6 floor, addressed by
-- field tile. GymmickCheckCollision_Blackthorn answers these tiles first.
---@param anchors BlackthornGym.PlatformAnchor[]
---@return table<integer, table<integer, true>>
function BlackthornGym.floorCells(anchors)
  local floors = {} ---@type table<integer, table<integer, true>>
  for _, platform in ipairs(BlackthornGym.platforms(anchors)) do
    for _, point in ipairs(platform.floor) do
      local column = floors[point.x]
      if column == nil then
        column = {} ---@type table<integer, true>
        floors[point.x] = column
      end
      column[point.z] = true
    end
  end
  return floors
end

-- BlackthornGymmick_GetButtonAction: which platform answers one tile and with
-- which of its three buttons.
---@param platforms BlackthornGym.Platform[]
---@param fieldX integer
---@param fieldZ integer
---@return BlackthornGym.ButtonAction?
function BlackthornGym.buttonAction(platforms, fieldX, fieldZ)
  for slot = 1, PLATFORM_COUNT do
    local platform = platforms[slot]
    if fieldX == platform.rotateButton.x and fieldZ == platform.rotateButton.z then
      return { slot = slot, action = BlackthornGym.ACTION_ROTATE }
    end
    if fieldX == platform.moveLeftButton.x and fieldZ == platform.moveLeftButton.z then
      return { slot = slot, action = BlackthornGym.ACTION_MOVE_RIGHT }
    end
    if fieldX == platform.moveRightButton.x and fieldZ == platform.moveRightButton.z then
      return { slot = slot, action = BlackthornGym.ACTION_MOVE_LEFT }
    end
  end
  return nil
end

-- BlackthornGymmick_GetMoveDirection: (addend + rotation) % 4, where the
-- addend is the button's own side in default orientation.
---@param rotation integer
---@param side string "right" or "left"
---@return { name: string, x: integer, z: integer }
function BlackthornGym.moveDirection(rotation, side)
  requireRotation(rotation)
  local addend = assert(MOVE_SIDES[side], "a platform move side is right or left")
  local index = (addend + rotation) % 4
  return assert(MOVE_DIRECTIONS[index], "the source move directions are closed")
end

-- GymmickCheckCollision_Blackthorn: the source rule for one gym tile. A
-- platform floor is walkable whatever the map says; magma is blocked outside
-- one; every other tile keeps the map's own permission.
---@param floors table<integer, table<integer, true>>
---@param fieldX integer
---@param fieldZ integer
---@param behavior integer
---@return boolean? blocked nil when the map's own permission stands
function BlackthornGym.collisionVerdict(floors, fieldX, fieldZ, behavior)
  local column = floors[fieldX]
  if column ~= nil and column[fieldZ] then
    return false
  end
  if behavior == BlackthornGym.MAGMA_BEHAVIOR then
    return true
  end
  return nil
end

-- The live mechanism of one map: the three platform tables derived from the
-- settled union and the one action a completed step may start.
---@param options BlackthornGymOptions
---@return BlackthornGym
function BlackthornGym.new(options)
  assert(type(options) == "table", "the blackthorn mechanism needs its collaborators")
  assert(options.state and options.state.blackthornPlatforms, "the blackthorn mechanism owns the saved union")
  assert(options.geometry and options.geometry.mapTile, "the blackthorn mechanism reads the map's tile facts")
  assert(options.geometry.setBlackthornPlatforms, "the blackthorn mechanism projects its floors")
  assert(options.geometry.floorWorldY and options.geometry.tileCentre, "the blackthorn mechanism places its props")
  assert(options.player and options.player.beginTransport, "the blackthorn mechanism carries the transport player")
  assert(options.audio and options.audio.play and options.audio.stop, "the blackthorn mechanism plays its sounds")
  local instance = setmetatable({
    _state = options.state,
    _geometry = options.geometry,
    _player = options.player,
    _audio = options.audio,
    _platforms = {},
    _action = nil,
    _soundStopped = false,
  }, BlackthornGym)
  instance:_restorePlatforms()
  return instance
end

---@return boolean
function BlackthornGym:isRunning()
  return self._action ~= nil
end

-- The source map load and every commit settle the platform tables and the
-- collision floors they imply together, from the union alone.
---@private
function BlackthornGym:_restorePlatforms()
  local anchors = self._state:blackthornPlatforms()
  self._platforms = BlackthornGym.platforms(anchors)
  self._geometry:setBlackthornPlatforms(anchors)
end

-- BlackthornGymmick_CheckWallCollision: a leading point is clear only when the
-- map does not block it and its metatile behavior is magma.
---@private
---@param points BlackthornGym.Point[]
---@param count integer
---@return boolean clear
function BlackthornGym:_wallClear(points, count)
  for index = 1, count do
    local point = points[index]
    local blocked, magma = self._geometry:mapTile(point.x, point.z)
    if blocked or not magma then
      return false
    end
  end
  return true
end

-- BlackthornGymmick_GetMaxRotationExtent: the smallest extent among the first
-- blocked point of the swept points, full travel when none of them bonks.
---@private
---@param points BlackthornGym.Point[]
---@param extents integer[]
---@return integer extent in quarter-turn 1/64ths
function BlackthornGym:_maxRotationExtent(points, extents)
  local extent = BlackthornGym.QUARTER_EXTENT
  for index, point in ipairs(points) do
    local blocked, magma = self._geometry:mapTile(point.x, point.z)
    if blocked or not magma then
      local candidate = assert(extents[index], "a rotation sweep point carries its own extent")
      if candidate < BlackthornGym.QUARTER_EXTENT then
        extent = candidate
        break
      end
    end
  end
  return extent
end

-- BlackthornPlatform_CheckRotationBonk: the four sides decide a refused turn,
-- then the swept area and the swept leading edge decide how far a partial one
-- may travel.
---@private
---@param platform BlackthornGym.Platform
---@return string bonk, integer extent
function BlackthornGym:_rotationBonk(platform)
  local shape = assert(SHAPES[platform.shape], "the source platform shapes are closed")
  if not self:_wallClear(platform.bottomWall, platform.width) then
    return ROTATION_BONK_NO_GO, BlackthornGym.QUARTER_EXTENT
  end
  if not self:_wallClear(platform.topWall, platform.width) then
    return ROTATION_BONK_NO_GO, BlackthornGym.QUARTER_EXTENT
  end
  if not self:_wallClear(platform.leftWall, platform.height) then
    return ROTATION_BONK_NO_GO, BlackthornGym.QUARTER_EXTENT
  end
  if not self:_wallClear(platform.rightWall, platform.width - 1) then
    return ROTATION_BONK_NO_GO, BlackthornGym.QUARTER_EXTENT
  end
  local swept = self:_maxRotationExtent(platform.rotateCollisionCheck, shape.mainExtents)
  local edge = self:_maxRotationExtent(platform.rightEdgeOuter, shape.leadingExtents)
  local extent = math.min(swept, edge)
  if extent < BlackthornGym.QUARTER_EXTENT then
    return ROTATION_BONK_PARTIAL_GO, extent
  end
  return ROTATION_BONK_OK, extent
end

-- Publish this tick's carried pose: the rider keeps the anchor height and the
-- platform's own horizontal displacement.
---@private
function BlackthornGym:_publishCarriedPose()
  local action = assert(self._action, "a carried pose belongs to one action")
  local direction = assert(action.direction, "a carried pose belongs to a move")
  local origin = assert(action.origin, "a carried pose needs its lease")
  self._player:applyTransportPose(
    origin.worldX + direction.x * action.travelled,
    origin.worldY,
    origin.worldZ + direction.z * action.travelled
  )
end

-- STATE_MOVE_INIT: claim the rider, start the source loop and fix the leading
-- wall this move tests one tile at a time.
---@private
---@param button BlackthornGym.ButtonAction
function BlackthornGym:_beginMove(button)
  local platform = assert(self._platforms[button.slot], "a move belongs to one platform")
  local rightward = button.action == BlackthornGym.ACTION_MOVE_RIGHT
  local direction = BlackthornGym.moveDirection(platform.rotation, rightward and "right" or "left")
  local lease = self._player:beginTransport()
  self._action = {
    kind = "move",
    slot = button.slot,
    phase = "check",
    direction = { x = direction.x, z = direction.z },
    distance = platform.width,
    steps = 0,
    timer = 0,
    travelled = 0,
    leadingWall = copyPoints(rightward and platform.rightWall or platform.leftWall),
    extent = BlackthornGym.QUARTER_EXTENT,
    committed = false,
    origin = {
      fieldX = lease.fieldX,
      fieldZ = lease.fieldZ,
      worldX = lease.worldX,
      worldY = lease.worldY,
      worldZ = lease.worldZ,
    },
  }
  self._soundStopped = false
  self._audio:play(BlackthornGym.MOVE_SEQUENCE)
end

-- STATE_ROTATE_INIT: claim the rider (a turn never moves it), start the source
-- loop and fix how far the turn may travel before its swept geometry bonks.
---@private
---@param button BlackthornGym.ButtonAction
function BlackthornGym:_beginRotate(button)
  local platform = assert(self._platforms[button.slot], "a rotation belongs to one platform")
  local bonk, extent = self:_rotationBonk(platform)
  local lease = self._player:beginTransport()
  self._action = {
    kind = "rotate",
    slot = button.slot,
    phase = assert(ROTATION_START_PHASES[bonk], "a turn starts in one of the source bonk states"),
    distance = 0,
    steps = 0,
    timer = 0,
    travelled = 0,
    leadingWall = {},
    extent = extent,
    committed = false,
    origin = {
      fieldX = lease.fieldX,
      fieldZ = lease.fieldZ,
      worldX = lease.worldX,
      worldY = lease.worldY,
      worldZ = lease.worldZ,
    },
  }
  self._soundStopped = false
  self._audio:play(BlackthornGym.MOVE_SEQUENCE)
  if bonk == ROTATION_BONK_PARTIAL_GO then
    -- The partially blocked turn hits a wall and returns from where it stopped.
    self._audio:play(BlackthornGym.BONK_SEQUENCE)
  end
end

-- STATE_MOVE_APPLY: the anchor the prop reached becomes the union's, and the
-- platform's own tables follow it. The rider's tile is committed once, as the
-- last motion tile settles, from the anchor it boarded with.
---@private
---@param action BlackthornGym.Action
function BlackthornGym:_commitMove(action)
  local platform = assert(self._platforms[action.slot], "a move belongs to one platform")
  local direction = assert(action.direction, "a committed move carries its direction")
  local origin = assert(action.origin, "a committed move needs its lease")
  self._state:setBlackthornPlatformPosition(
    action.slot,
    platform.x + direction.x * platform.width,
    platform.z + direction.z * platform.width
  )
  self._player:commitTransport(
    origin.fieldX + direction.x * platform.width,
    origin.fieldZ + direction.z * platform.width,
    origin.worldY
  )
  action.committed = true
  self:_restorePlatforms()
end

-- STATE_ROTATE_RUN's last tick: one more quarter turn at the platform's index.
---@private
---@param action BlackthornGym.Action
function BlackthornGym:_commitRotation(action)
  self._state:advanceBlackthornRotation(action.slot)
  action.committed = true
  self:_restorePlatforms()
end

-- STATE_MOVE_FINISH / STATE_ROTATE_FINISH: release the source loop, then the
-- rider's lease. A committed move already settled its tile through the lease;
-- every other way out - a refused move, a rotation of any outcome - restores the
-- anchor the action started from, which for a rotation is the tile it never
-- left.
---@private
function BlackthornGym:_finish()
  if not self._soundStopped then
    self._soundStopped = true
    self._audio:stop(BlackthornGym.MOVE_SEQUENCE)
  end
  self._player:cancelTransport()
  self._action = nil
end

-- BlackthornGymmick_TryStartPlatformAction: only a completed step onto one of
-- the platform buttons starts an action.
---@param fieldX integer
---@param fieldZ integer
---@return boolean started
function BlackthornGym:startAction(fieldX, fieldZ)
  assert(self._action == nil, "a platform action is already running")
  local button = BlackthornGym.buttonAction(self._platforms, fieldX, fieldZ)
  if button == nil then
    return false
  end
  if button.action == BlackthornGym.ACTION_ROTATE then
    self:_beginRotate(button)
  else
    self:_beginMove(button)
  end
  return true
end

-- One fixed tick of the in-flight action.
---@return string status "idle", "riding" or "complete"
function BlackthornGym:updateFixed()
  local action = self._action
  if action == nil then
    return "idle"
  end
  if action.phase == "check" then
    if self:_wallClear(action.leadingWall, self._platforms[action.slot].height) then
      action.phase = "run"
      action.timer = 0
    else
      action.phase = "bonk_start"
    end
    return "riding"
  end
  if action.phase == "run" then
    action.travelled = action.travelled + BlackthornGym.MOTION_TILES
    self:_publishCarriedPose()
    action.timer = action.timer + 1
    if action.timer >= BlackthornGym.TICKS_PER_TILE then
      action.timer = 0
      local direction = assert(action.direction, "a running move carries its direction")
      action.leadingWall = translatePoints(action.leadingWall, direction)
      action.steps = action.steps + 1
      if action.steps >= action.distance then
        self:_commitMove(action)
        action.phase = "finish"
      else
        action.phase = "check"
      end
    end
    return "riding"
  end
  if action.phase == "bonk_start" then
    self._audio:play(BlackthornGym.BONK_SEQUENCE)
    action.phase = "bonk_check"
    return "riding"
  end
  if action.phase == "bonk_check" then
    -- The source reverses its motion vector; here the direction stays the move
    -- direction and the decreasing travel carries the rider back, so the
    -- carried pose never jumps across the anchor.
    action.phase = action.steps == 0 and "finish" or "bonk_return"
    return "riding"
  end
  if action.phase == "bonk_return" then
    action.travelled = action.travelled - BlackthornGym.MOTION_TILES
    self:_publishCarriedPose()
    action.timer = action.timer + 1
    if action.timer >= BlackthornGym.TICKS_PER_TILE then
      action.timer = 0
      action.steps = action.steps - 1
      if action.steps == 0 then
        action.phase = "finish"
      end
    end
    return "riding"
  end
  if action.phase == "rotate_run" then
    action.travelled = action.travelled + BlackthornGym.TURN_DEGREES
    action.timer = action.timer + 1
    if action.timer >= BlackthornGym.ROTATION_TICKS then
      self:_commitRotation(action)
      action.phase = "finish"
    end
    return "riding"
  end
  if action.phase == "rotate_bonk" then
    action.travelled = action.travelled + BlackthornGym.TURN_DEGREES
    local extentDegrees = action.extent / BlackthornGym.QUARTER_EXTENT * BlackthornGym.QUARTER_DEGREES
    if action.travelled >= extentDegrees then
      action.travelled = extentDegrees
      action.phase = "rotate_bonk_return"
    end
    return "riding"
  end
  if action.phase == "rotate_bonk_return" then
    action.travelled = action.travelled - BlackthornGym.TURN_DEGREES
    if action.travelled <= 0 then
      action.travelled = 0
      action.phase = "finish"
    end
    return "riding"
  end
  assert(action.phase == "finish", "a platform action phase is closed")
  self:_finish()
  return "complete"
end

-- Leave the map or the field with the action's ownership released. A refused
-- or cancelled action never commits, so the union keeps what it started from.
function BlackthornGym:cancel()
  if self._action == nil then
    return
  end
  if not self._soundStopped then
    self._soundStopped = true
    self._audio:stop(BlackthornGym.MOVE_SEQUENCE)
  end
  self._player:cancelTransport()
  self._action = nil
end

-- Release the action and the collision floors this mechanism projected: a
-- replaced or retired mechanism leaves no platform ground behind.
function BlackthornGym:dispose()
  self:cancel()
  self._geometry:setBlackthornPlatforms(nil)
end

-- The immutable presentation snapshot this tick: where each platform prop
-- stands. The source places each prop at native y 48, which is the gym floor
-- (three tiles at 16 units per tile) the platforms ride over, so the port keeps
-- the map's own floor under the anchor. A moving platform carries its own
-- displacement and a turning one carries its animated angle; nothing here reads
-- the field's clocks.
---@return GymMechanism.PropPlacement[] placements
function BlackthornGym:presentation()
  local action = self._action
  local placements = {}
  for slot = 1, PLATFORM_COUNT do
    local platform = self._platforms[slot]
    local anchorX, anchorZ = platform.x, platform.z
    local offsetX, offsetZ = 0, 0
    -- A turning platform's animated angle accumulates fractional travel.
    local degrees = -BlackthornGym.QUARTER_DEGREES * platform.rotation ---@type number
    if action ~= nil and action.slot == slot then
      if action.kind == "move" then
        local direction = assert(action.direction, "a moving platform carries its direction")
        offsetX, offsetZ = direction.x * action.travelled, direction.z * action.travelled
      else
        degrees = degrees - action.travelled
      end
    end
    local centre = assert(self._geometry:tileCentre(anchorX, anchorZ), "a platform prop needs its map origin")
    placements[slot] = {
      slot = slot,
      x = centre.x + offsetX,
      y = self._geometry:floorWorldY(anchorX, anchorZ),
      z = centre.z + offsetZ,
      rotationDegrees = degrees,
    }
  end
  return placements
end

return BlackthornGym
