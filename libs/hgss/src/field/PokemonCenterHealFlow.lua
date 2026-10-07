-- Owns the ordered temporary props and completion gates for PokeCenAnim.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")

---@class PokemonCenterHealFlow
---@field definition table<string, unknown>
---@field phase string
---@field balls table<integer, table<string, unknown>>
---@field count integer
---@field error unknown
---@field audio table<string, unknown>
---@field mapId fun(): integer?
---@field resolveAnchor fun(animation: string): table<string, unknown>
---@field spawnBall fun(position: table<string, number>, record: table<string, unknown>, index: integer): table<string, unknown>
---@field activeMapId integer?
---@field anchor table<string, unknown>|nil
---@field spawned integer
---@field taskState integer
---@field delay integer
---@field machine table<string, unknown>|nil
---@field start fun(self: PokemonCenterHealFlow, count: integer)
---@field updateFixed fun(self: PokemonCenterHealFlow)
---@field setBallFactory fun(self: PokemonCenterHealFlow, factory: fun(position: table<string, number>, record: table<string, unknown>, index: integer): table<string, unknown>)
---@field status fun(self: PokemonCenterHealFlow): table<string, unknown>
---@field dispose fun(self: PokemonCenterHealFlow)
local PokemonCenterHealFlow = {}
PokemonCenterHealFlow.__index = PokemonCenterHealFlow

-- State 2 of the healing-machine task waits while its delay counter is below
-- this threshold (0x0C). It is a counter threshold, never a spawn interval:
-- the threshold-observation invocation only selects the next state, and the
-- following invocation performs it.
local HEALING_MACHINE_DELAY_THRESHOLD = 12

local function finiteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function copyPoint(point)
  return { x = point.x, y = point.y, z = point.z }
end

local function translated(anchor, offset)
  return { x = anchor.x + offset.x, y = anchor.y + offset.y, z = anchor.z + offset.z }
end

---@param options table<string, unknown>
---@return PokemonCenterHealFlow
function PokemonCenterHealFlow.new(options)
  assert(type(options) == "table", "center healing flow options are required")
  local definition = assert(options.definition, "center healing flow definition is required")
  assert(type(options.mapId) == "function", "center healing flow map identity is required")
  assert(type(options.resolveAnchor) == "function", "center healing flow anchor resolver is required")
  assert(type(options.spawnBall) == "function", "center healing flow ball factory is required")
  assert(options.audio and options.audio.play and options.audio.playFanfare, "center healing flow audio is required")
  local positions = assert(definition.ballPositions, "center healing flow ball positions are required")
  assert(#positions == 6, "center healing flow has six retail ball positions")
  return setmetatable({
    definition = definition,
    mapId = options.mapId,
    resolveAnchor = options.resolveAnchor,
    spawnBall = options.spawnBall,
    audio = options.audio,
    phase = "idle",
    balls = {},
    error = nil,
    count = 0,
    taskState = 0,
    delay = 0,
  }, PokemonCenterHealFlow)
end

local function releaseFlow(self)
  local firstError
  for index = #self.balls, 1, -1 do
    local ball = self.balls[index]
    if ball.handle ~= nil then
      local ok, err = pcall(ball.handle.dispose, ball.handle)
      if not ok and firstError == nil then
        firstError = err
      end
      ball.handle = nil
    end
    self.balls[index] = nil
  end
  if self.machine ~= nil then
    local ok, err = pcall(self.machine.release, self.machine)
    if not ok and firstError == nil then
      firstError = err
    end
    self.machine = nil
  end
  if firstError ~= nil then
    error(firstError, 0)
  end
end

local function fail(self, err)
  local ok, cleanupError = pcall(releaseFlow, self)
  self.error = Errors.new(FieldErrors.FIELD_MAP_DATA_CACHE_INVALID, "Pokémon Center healing flow failed", {
    cause = tostring(err),
    cleanupError = not ok and tostring(cleanupError) or nil,
    mapId = self.activeMapId,
  })
  self.phase = "failed"
end

function PokemonCenterHealFlow:_spawn(index)
  local record = assert(self.definition.ballPositions[index], "healing ball position is missing")
  local anchor = assert(self.anchor.position, "healing anchor position is required")
  local position = translated(anchor, record.offset)
  local handle = self.spawnBall(position, record, index)
  assert(
    handle and handle.updateFixed and handle.isFinished and handle.dispose,
    "healing ball factory returned an incomplete handle"
  )
  self.balls[#self.balls + 1] = {
    index = index,
    role = record.role,
    offset = copyPoint(record.offset),
    position = position,
    handle = handle,
  }
  self.audio:play(self.definition.placementSound)
end

---@param factory fun(position: table<string, number>, record: table<string, unknown>, index: integer): table<string, unknown>
function PokemonCenterHealFlow:setBallFactory(factory)
  assert(type(factory) == "function", "center healing ball factory is required")
  assert(
    self.phase == "idle" or self.phase == "complete" or self.phase == "failed",
    "cannot replace an active ball factory"
  )
  self.spawnBall = factory
end

function PokemonCenterHealFlow:_startAnimations()
  self.machine =
    assert(self.anchor:startAnimation(self.definition.machineAnimation), "healing machine animation did not start")
  for _, ball in ipairs(self.balls) do
    ball.handle:startAnimation()
  end
  self.audio:playFanfare(self.definition.fanfare)
  self.phase = "waiting"
end

function PokemonCenterHealFlow:start(count)
  assert(
    self.phase == "idle" or self.phase == "complete" or self.phase == "failed",
    "center healing flow is already active"
  )
  assert(
    type(count) == "number" and count % 1 == 0 and count >= 0,
    "center healing count must be a nonnegative integer"
  )
  assert(count <= #self.definition.ballPositions, "center healing count exceeds generated ball positions")
  self.phase = "spawning"
  self.count = count
  self.spawned = 0
  self.taskState = 0
  self.delay = 0
  self.error = nil
  local ok, anchor = pcall(function()
    local resolved = self.resolveAnchor(self.definition.machineAnimation)
    assert(type(resolved) == "table" and type(resolved.position) == "table", "center healing anchor was not resolved")
    for _, axis in ipairs({ "x", "y", "z" }) do
      assert(finiteNumber(resolved.position[axis]), "center healing anchor requires finite world coordinates")
    end
    return resolved
  end)
  if not ok then
    fail(self, anchor)
    return
  end
  self.anchor = anchor
  self.activeMapId = self.mapId()
  if count > 0 then
    local spawned, spawnError = pcall(self._spawn, self, 1)
    if not spawned then
      fail(self, spawnError)
      return
    end
    self.spawned = 1
    -- The first ball is created during startup. Every later ball, and the
    -- machine startup itself, runs through the fixed-update state dispatch
    -- below after the full delay and transition sequence.
    self.taskState = 2
    self.delay = 0
  else
    self.taskState = 3
    self.phase = "start_animations"
  end
end

function PokemonCenterHealFlow:updateFixed()
  if self.phase == "idle" or self.phase == "complete" or self.phase == "failed" then
    return
  end
  if self.mapId() ~= self.activeMapId then
    fail(self, "active map changed during center healing")
    return
  end
  local ok, err = pcall(function()
    if self.taskState == 1 then
      self:_spawn(self.spawned + 1)
      self.spawned = self.spawned + 1
      self.taskState = 2
      self.delay = 0
    elseif self.taskState == 2 then
      if self.delay < HEALING_MACHINE_DELAY_THRESHOLD then
        self.delay = self.delay + 1
      else
        -- The threshold observation only selects the next state. The
        -- selected ball creation or machine startup runs on a later
        -- invocation, never in this one.
        self.delay = 0
        if self.spawned == self.count then
          self.taskState = 3
          self.phase = "start_animations"
        else
          self.taskState = 1
        end
      end
    elseif self.taskState == 3 then
      self:_startAnimations()
      self.taskState = 4
    elseif self.taskState == 4 then
      local ballsFinished = true
      for _, ball in ipairs(self.balls) do
        ball.handle:updateFixed()
        if not ball.handle:isFinished() then
          ballsFinished = false
        end
      end
      if self.machine.updateFixed then
        self.machine:updateFixed()
      end
      if ballsFinished and self.machine:isFinished() and not self.audio:isFanfarePlaying() then
        releaseFlow(self)
        self.taskState = 5
        self.phase = "complete"
      end
    end
  end)
  if not ok then
    fail(self, err)
  end
end

function PokemonCenterHealFlow:status()
  local balls = {}
  for index, ball in ipairs(self.balls) do
    balls[index] = {
      index = ball.index,
      role = ball.role,
      offset = copyPoint(ball.offset),
      position = copyPoint(ball.position),
    }
  end
  local fanfare = "idle"
  if self.phase == "waiting" then
    fanfare = self.audio:isFanfarePlaying() and "playing" or "complete"
  end
  local animations = self.phase == "waiting" and "playing" or (self.phase == "complete" and "complete" or "idle")
  return {
    phase = self.phase,
    count = self.count,
    balls = balls,
    ballAnimation = animations,
    machineAnimation = animations,
    fanfare = fanfare,
    error = self.error,
  }
end

function PokemonCenterHealFlow:dispose()
  releaseFlow(self)
  self.phase = "idle"
  self.error = nil
  self.count = 0
end

function PokemonCenterHealFlow:cancel(_)
  self:dispose()
end

return PokemonCenterHealFlow
