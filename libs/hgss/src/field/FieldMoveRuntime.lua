-- Concrete field-move queue, plan, and phase owner behind the scheduler
-- task. At most one pending or active operation exists: queue admits
-- menu-origin requests after deciding eligibility, takePending transfers the
-- single copy to the task exactly once, plan builds the closed executable
-- plan union, advance steps acknowledgement then commits once, and cancel
-- releases motion plus the active marker idempotently. Strength arming is
-- transient map-lifetime state cleared only by an explicit reset. Pure
-- domain module: no love dependency.

local FieldMoveRuntime = {}
FieldMoveRuntime.__index = FieldMoveRuntime

---@class FieldMoveRuntime
---@field private _policy table<string, unknown>
---@field private _world table<string, unknown>
---@field private _pending table<string, unknown>?
---@field private _activeRequest table<string, unknown>?
---@field private _activePlan table<string, unknown>?
---@field private _strengthArmed boolean
---@field new fun(opts: { policy: table<string, unknown>, world: table<string, unknown> }): FieldMoveRuntime
---@field isBusy fun(self: FieldMoveRuntime): boolean
---@field queue fun(self: FieldMoveRuntime, request: table<string, unknown>): table<string, unknown>
---@field takePending fun(self: FieldMoveRuntime): table<string, unknown>
---@field discardPending fun(self: FieldMoveRuntime)
---@field plan fun(self: FieldMoveRuntime, request: table<string, unknown>): table<string, unknown>
---@field advance fun(self: FieldMoveRuntime, plan: table<string, unknown>): table<string, unknown>
---@field cancel fun(self: FieldMoveRuntime, plan: table<string, unknown>)
---@field clearTransient fun(self: FieldMoveRuntime)
---@field dispose fun(self: FieldMoveRuntime)
---@field requestDisembark fun(self: FieldMoveRuntime): table<string, unknown>
---@field tryStrengthPush fun(self: FieldMoveRuntime, snapshot: table<string, unknown>): table<string, unknown>

local Errors = require("libs.errors.src.Errors")

-- Bounded native field-use acknowledgement before a committed effect, in
-- fixed ticks on the existing cadence. This is an intentional project
-- presentation beat, not original cinematic parity.
FieldMoveRuntime.ACKNOWLEDGE_TICKS = 8

local CUT = "cut"
local SMASH = "smash"
local ENABLE_STRENGTH = "enable_strength"
local PUSH_STRENGTH = "push_strength"
local FLASH = "flash"
local DIG = "dig"
local TELEPORT = "teleport"
local SURF_ENTER = "surf_enter"
local DISEMBARK = "disembark"
local WATERFALL = "waterfall"
local WHIRLPOOL = "whirlpool"
local ROCK_CLIMB = "rock_climb"

local POLICY_MOVES = {
  cut = true,
  fly = true,
  surf = true,
  strength = true,
  flash = true,
  rock_smash = true,
  waterfall = true,
  whirlpool = true,
  rock_climb = true,
  dig = true,
  teleport = true,
  headbutt = true,
  sweet_scent = true,
  chatter = true,
  defog = true,
  escape_rope = true,
}

local EXPLICIT_DEFERRED = {
  fly = "fly_map_deferred",
  headbutt = "headbutt_encounters_deferred",
  sweet_scent = "sweet_scent_encounters_deferred",
  chatter = "chatter_recording_deferred",
}

local TRAVERSAL_MOVES = {
  surf = true,
  disembark = true,
  waterfall = true,
  whirlpool = true,
  rock_climb = true,
}

local TRAVERSAL_PLANS = {
  [SURF_ENTER] = true,
  [DISEMBARK] = true,
  [WATERFALL] = true,
  [WHIRLPOOL] = true,
  [ROCK_CLIMB] = true,
}

local function isRecord(value)
  return type(value) == "table"
end

local function copyValue(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, child in pairs(value) do
    copy[key] = copyValue(child)
  end
  return copy
end

local function assertSlot(slot, move)
  assert(
    type(slot) == "number" and slot % 1 == 0 and slot >= 0 and slot <= 5,
    move .. " requires a zero-based party slot"
  )
  return slot
end

local function checkShape(self)
  assert(
    isRecord(self._policy) and type(self._policy.check) == "function",
    "field runtime requires the eligibility policy"
  )
  assert(isRecord(self._world), "field runtime requires the world adapter")
end

---@param opts { policy: table<string, unknown>, world: table<string, unknown> }
---@return FieldMoveRuntime
function FieldMoveRuntime.new(opts)
  assert(isRecord(opts), "field runtime requires options")
  local runtime = setmetatable({
    _policy = assert(opts.policy, "field runtime requires the eligibility policy"),
    _world = assert(opts.world, "field runtime requires the world adapter"),
    _pending = nil,
    _activeRequest = nil,
    _activePlan = nil,
    _strengthArmed = false,
  }, FieldMoveRuntime)
  checkShape(runtime)
  return runtime
end

---@return boolean
function FieldMoveRuntime:isBusy()
  return self._pending ~= nil or self._activeRequest ~= nil
end

local function facingMatches(world, context)
  local facing = context.facingActor
  if facing == nil then
    return true
  end
  local live = world:resolveFacingTarget()
  if live == nil then
    return true
  end
  return live.actorId == facing.identity and live.obstacleKind == facing.obstacleKind
end

-- Admit one field-move request: a second pending/active operation is
-- rejected without mutation. Menu-origin requests carrying a context decide
-- eligibility through the policy before the application closes, and a moved
-- facing actor fails stale. Explicit script-origin requests carry no
-- context and admit on ownership/shape alone; they plan from live world
-- state instead of cached eligibility facts.
---@param request table<string, unknown> { move, slot?, partyRevision?, context? }
---@return table<string, unknown> { kind = "accepted" } or a nonaccepted Decision
function FieldMoveRuntime:queue(request)
  assert(isRecord(request), "field queue requires a request record")
  assert(type(request.move) == "string" and request.move ~= "", "field request needs a move key")
  if self:isBusy() then
    return { kind = "busy" }
  end
  local move = request.move
  if move ~= PUSH_STRENGTH then
    assertSlot(request.slot, move)
  end
  if request.partyRevision ~= nil then
    assert(
      type(request.partyRevision) == "number" and request.partyRevision % 1 == 0,
      "field request revision must be an integer"
    )
  end
  if move ~= PUSH_STRENGTH and POLICY_MOVES[move] and request.context ~= nil then
    local context = request.context
    local decision = self._policy.check(move, context)
    assert(isRecord(decision) and type(decision.kind) == "string", "policy must return a decision record")
    if decision.kind ~= "ok" then
      return decision
    end
    -- Request-scoped facing data revalidates against the live obstacle.
    if not facingMatches(self._world, context) then
      return { kind = "stale" }
    end
  end
  self._pending = copyValue(request)
  return { kind = "accepted" }
end

-- Transfer the queued request to the claiming task exactly once.
---@return table<string, unknown> the owned request copy
function FieldMoveRuntime:takePending()
  assert(self._pending ~= nil, "field runtime has no pending request to take")
  local request = self._pending
  self._pending = nil
  self._activeRequest = request
  self._activePlan = nil
  return copyValue(request)
end

-- Drop a still-unclaimed queued request, e.g. after failed scheduler
-- admission. Never touches an active operation.
function FieldMoveRuntime:discardPending()
  self._pending = nil
end

-- Plan a Dig/Teleport return from durable travel facts: without a travel
-- record there is no destination, so the request refuses as not now
-- instead of guessing. Destination records and Decisions both flow back
-- untouched; only records become executable plans.
---@param request table<string, unknown>
---@param move string
---@return table<string, unknown> plan or Decision
local function buildReturnPlan(self, request, move)
  local travel = request.travel
  if travel == nil then
    return { kind = "not_now" }
  end
  local context = assert(request.context, move .. " planning requires its context")
  local destination = self._world:planReturn(move, context, travel)
  assert(isRecord(destination), "return resolution answers a record")
  if type(destination.kind) == "string" then
    return destination
  end
  return {
    kind = move,
    move = move,
    slot = assertSlot(request.slot, move),
    partyRevision = request.partyRevision,
    mapId = assert(context.mapId, "return plans carry their source map"),
    destination = destination,
    phase = "acknowledge",
    ticksLeft = FieldMoveRuntime.ACKNOWLEDGE_TICKS,
    committed = false,
    warpStarted = false,
  }
end

local function planTarget(context, kind)
  local facing = assert(context.facingActor, kind .. " needs its facing actor")
  assert(type(facing.identity) == "string" and facing.identity ~= "", kind .. " needs a target identity")
  return {
    actorId = facing.identity,
    obstacleKind = facing.obstacleKind,
    mapId = context.mapId,
  }
end

-- Build the closed executable plan union for a taken or explicit request.
-- Menu requests re-check eligibility; explicit script-origin requests carry
-- no context and execute without re-gating, matching the source commands
-- that read a slot and act. Deferred traversal/fly moves report honestly
-- instead of succeeding; Fly never plans because the menu flow completes
-- it as a checked no-op before admission.
---@param request table<string, unknown>
---@return table<string, unknown> plan or Decision
local function buildPlan(self, request)
  assert(isRecord(request), "field planning requires a request record")
  local move = assert(request.move, "field planning requires a move key")
  if move == "fly" then
    error("fly never plans a field task; the menu flow completes it as a checked no-op", 0)
  end
  if POLICY_MOVES[move] and request.context ~= nil then
    local decision = self._policy.check(move, request.context)
    if decision.kind ~= "ok" then
      return decision
    end
  end
  if move == DIG or move == TELEPORT then
    return buildReturnPlan(self, request, move)
  end
  if move == CUT or move == "rock_smash" then
    local context = assert(request.context, move .. " planning requires its context")
    local kind = move == CUT and CUT or SMASH
    local want = move == CUT and "cut_tree" or "smash_rock"
    local target = planTarget(context, kind)
    if target.obstacleKind ~= want then
      return { kind = "not_here" }
    end
    return {
      kind = kind,
      move = move,
      slot = assertSlot(request.slot, move),
      partyRevision = request.partyRevision,
      mapId = context.mapId,
      target = target,
      phase = "acknowledge",
      ticksLeft = FieldMoveRuntime.ACKNOWLEDGE_TICKS,
      committed = false,
    }
  end
  if move == "strength" then
    local context = assert(request.context, "strength planning requires its context")
    local target = planTarget(context, ENABLE_STRENGTH)
    if target.obstacleKind ~= "strength_boulder" then
      return { kind = "not_here" }
    end
    return {
      kind = ENABLE_STRENGTH,
      move = move,
      slot = assertSlot(request.slot, move),
      partyRevision = request.partyRevision,
      mapId = context.mapId,
      target = target,
      phase = "acknowledge",
      ticksLeft = FieldMoveRuntime.ACKNOWLEDGE_TICKS,
      committed = false,
    }
  end
  if move == PUSH_STRENGTH then
    local push = assert(request.push, "push planning requires its validated snapshot")
    assert(type(push.boulderActorId) == "string" and push.boulderActorId ~= "", "push needs its boulder identity")
    assert(type(push.direction) == "string" and push.direction ~= "", "push needs its direction")
    assert(type(push.mapId) == "number", "push needs its map identity")
    return {
      kind = PUSH_STRENGTH,
      move = move,
      partyRevision = request.partyRevision,
      mapId = push.mapId,
      target = { actorId = push.boulderActorId, obstacleKind = "strength_boulder", mapId = push.mapId },
      direction = push.direction,
      phase = "begin",
      committed = false,
    }
  end
  if move == FLASH then
    local context = assert(request.context, "flash planning requires its context")
    local fieldUse = assert(context.fieldUse, "flash planning requires the map policy")
    return {
      kind = FLASH,
      move = move,
      slot = assertSlot(request.slot, move),
      partyRevision = request.partyRevision,
      mapId = context.mapId,
      alphChamber = fieldUse.alphChamber == true,
      phase = "acknowledge",
      ticksLeft = FieldMoveRuntime.ACKNOWLEDGE_TICKS,
      committed = false,
    }
  end
  if TRAVERSAL_MOVES[move] then
    -- Water and climb execution plans terrain-valid contiguous traversal
    -- through the world adapter. Menu requests re-check eligibility above
    -- when they carry a context; explicit script-origin requests plan from
    -- live world state like the other executable moves.
    local traversal = self._world:planTraversal({ move = move }, request.context)
    assert(isRecord(traversal) and type(traversal.kind) == "string", "traversal planning must decide")
    if not TRAVERSAL_PLANS[traversal.kind] then
      return traversal
    end
    local plan = {
      kind = traversal.kind,
      move = move,
      partyRevision = request.partyRevision,
      mapId = assert(traversal.sourceIdentity.mapId, "traversal plans carry their map"),
      segments = assert(traversal.segments, "traversal plans carry segments"),
      sourceIdentity = traversal.sourceIdentity,
      segmentIndex = 0,
      motionActive = false,
      phase = "traverse",
      committed = false,
    }
    if move ~= "disembark" then
      plan.slot = assertSlot(request.slot, move)
    end
    return plan
  end
  local deferred = EXPLICIT_DEFERRED[move]
  if deferred then
    return { kind = "feature_unavailable", reason = deferred }
  end
  if POLICY_MOVES[move] then
    return { kind = "feature_unavailable", reason = "move_execution_deferred" }
  end
  error("unknown field move " .. tostring(move), 0)
end

local PLAN_PHASES = { acknowledge = true, commit = true, begin = true, step = true, traverse = true, warp = true }

-- Plan and register the live plan: the built plan table identifies the
-- active operation for settling, so a stale plan can advance safely
-- without clearing a newer operation's marker.
---@param request table<string, unknown>
---@return table<string, unknown> plan or Decision
function FieldMoveRuntime:plan(request)
  local result = buildPlan(self, request)
  if isRecord(result) and PLAN_PHASES[result.phase] then
    self._activePlan = result
    return result
  end
  -- A refused plan abandons the taken operation: nothing executable
  -- remains, so the runtime releases instead of leaking busy.
  self._activePlan = nil
  self._activeRequest = nil
  return result
end

local function settle(self, plan)
  if self._activePlan == plan then
    self._activePlan = nil
    self._activeRequest = nil
  end
end

local function commitCut(self, plan)
  local stale = self._world:validateTarget(plan)
  if stale ~= nil then
    return { kind = "failed", error = stale }
  end
  self._world:removeObstacle(plan.target)
  plan.committed = true
  return nil
end

-- Advance one domain step: acknowledgement ticks, then exactly one commit.
-- A settled plan never recommits; settling clears the active marker here so
-- the task only forwards outcomes.
---@param plan table<string, unknown>
---@return table<string, unknown> { kind = "running" | "done" } or { kind = "failed", error }
function FieldMoveRuntime:advance(plan)
  assert(isRecord(plan) and type(plan.kind) == "string", "advance requires a plan")
  if plan.committed then
    settle(self, plan)
    return { kind = "done" }
  end
  local kind = plan.kind
  if kind == CUT or kind == SMASH or kind == FLASH or kind == ENABLE_STRENGTH then
    if plan.phase == "acknowledge" then
      plan.ticksLeft = (plan.ticksLeft or 0) - 1
      if plan.ticksLeft > 0 then
        return { kind = "running" }
      end
      plan.phase = "commit"
    end
    if kind == ENABLE_STRENGTH then
      self._world:activateStrength(plan)
      self._strengthArmed = true
    elseif kind == FLASH then
      local stale = self._world:validateTarget(plan)
      if stale ~= nil then
        settle(self, plan)
        return { kind = "failed", error = stale }
      end
      self._world:applyFlash(plan)
    else
      local failed = commitCut(self, plan)
      if failed ~= nil then
        settle(self, plan)
        return failed
      end
      settle(self, plan)
      return { kind = "done" }
    end
    plan.committed = true
    settle(self, plan)
    return { kind = "done" }
  end
  if kind == PUSH_STRENGTH then
    if plan.phase == "begin" then
      local stale = self._world:validateTarget(plan)
      if stale ~= nil then
        settle(self, plan)
        return { kind = "failed", error = stale }
      end
      local blocked = self._world:validatePush(plan)
      if blocked ~= nil then
        settle(self, plan)
        return { kind = "failed", error = blocked }
      end
      self._world:beginPush(plan)
      plan.phase = "step"
      return { kind = "running" }
    end
    if self._world:advancePush(plan) then
      local stale = self._world:validateTarget(plan)
      if stale ~= nil then
        self._world:cancelMotion(plan)
        settle(self, plan)
        return { kind = "failed", error = stale }
      end
      local blocked = self._world:validatePush(plan)
      if blocked ~= nil then
        self._world:cancelMotion(plan)
        settle(self, plan)
        return { kind = "failed", error = blocked }
      end
      self._world:commitPush(plan)
      plan.committed = true
      settle(self, plan)
      return { kind = "done" }
    end
    return { kind = "running" }
  end
  if kind == DIG or kind == TELEPORT then
    -- Acknowledge on the shared cadence, then start the warp exactly
    -- once and observe it to completion. A failed start or a failed warp
    -- faults the plan with the service error; the world and travel state
    -- stay exactly as the failure left them, and settling releases the
    -- runtime so nothing replays.
    if plan.phase == "acknowledge" then
      plan.ticksLeft = (plan.ticksLeft or 0) - 1
      if plan.ticksLeft > 0 then
        return { kind = "running" }
      end
      plan.phase = "warp"
    end
    if not plan.warpStarted then
      local started, startErr = pcall(function()
        self._world:beginReturnWarp(plan)
      end)
      if not started then
        if Errors.is(startErr) then
          settle(self, plan)
          return { kind = "failed", error = startErr }
        end
        error(startErr, 0)
      end
      return { kind = "running" }
    end
    if self._world:returnWarpDone(plan) then
      local warpError = self._world:returnWarpError(plan)
      if warpError ~= nil then
        settle(self, plan)
        return { kind = "failed", error = warpError }
      end
      plan.committed = true
      settle(self, plan)
      return { kind = "done" }
    end
    return { kind = "running" }
  end
  if TRAVERSAL_PLANS[kind] then
    -- One committed segment per advance: begin only from idle after
    -- revalidation, observe the motion the session tick advances, then
    -- commit. The terminal avatar transition applies once the final
    -- segment committed; cancellation restores the last committed tile
    -- through the existing motion owner with no mode rollback.
    if not plan.motionActive then
      if plan.segmentIndex >= #plan.segments then
        self._world:commitTraversalMode(plan)
        plan.committed = true
        settle(self, plan)
        return { kind = "done" }
      end
      local refused = self._world:validateTraversalSegment(plan)
      if refused ~= nil then
        settle(self, plan)
        return { kind = "failed", error = refused }
      end
      self._world:beginTraversalSegment(plan)
      return { kind = "running" }
    end
    if self._world:traversalMotionDone(plan) then
      self._world:commitTraversalSegment(plan)
      return { kind = "running" }
    end
    return { kind = "running" }
  end
  error("unknown field plan " .. tostring(kind), 0)
end

-- Release active motion and the active marker. Idempotent per plan: motion
-- already settled or absent is a no-op, and only the matching active plan
-- clears the marker. A committed plan releases nothing live.
---@param plan table<string, unknown>
function FieldMoveRuntime:cancel(plan)
  assert(isRecord(plan), "cancel requires a plan")
  if not plan.cancelled then
    plan.cancelled = true
    if not plan.committed then
      self._world:cancelMotion(plan)
    end
  end
  settle(self, plan)
end

-- Clear transient map-lifetime strength permission. Called on the source
-- full-map reset by the composition; nothing else disarms.
function FieldMoveRuntime:clearTransient()
  self._strengthArmed = false
end

-- Final idempotent backstop for the owning composition: drop a
-- still-unclaimed queued request and cancel the active plan's physical
-- work exactly once through cancel, which settles the marker. Borrowed
-- services are never touched. Safe to call with nothing outstanding and
-- safe to repeat: settled markers make every path a no-op.
function FieldMoveRuntime:dispose()
  self._pending = nil
  local plan = self._activePlan
  self._activePlan = nil
  self._activeRequest = nil
  if plan ~= nil then
    self:cancel(plan)
  end
end

-- Session disembark port: validate the shore landing and queue the
-- single disembark operation. Expected refusals return Decisions for the
-- session's normal fallthrough; program errors raise. Mirrors the
-- Strength-push port: planning is synchronous, execution runs later
-- through the claiming task.
---@return table<string, unknown> { kind = "accepted" } or Decision
function FieldMoveRuntime:requestDisembark()
  if self:isBusy() then
    return { kind = "busy" }
  end
  local request = { move = "disembark" }
  local plan = self:plan(request)
  if plan.kind ~= DISEMBARK then
    return plan
  end
  self._pending = copyValue(request)
  return { kind = "accepted" }
end

-- Session push port: validate an armed walked-into boulder step and queue
-- the single push operation. Expected refusals return Decisions for the
-- session's normal bump fallthrough; program errors raise.
---@param snapshot table<string, unknown> { boulderActorId, direction, mapId }
---@return table<string, unknown> { kind = "accepted" } or Decision
function FieldMoveRuntime:tryStrengthPush(snapshot)
  assert(isRecord(snapshot), "push attempts require a snapshot")
  if not self._strengthArmed then
    return { kind = "not_here", reason = "strength_not_enabled" }
  end
  if self:isBusy() then
    return { kind = "busy" }
  end
  local request = {
    move = PUSH_STRENGTH,
    partyRevision = nil,
    push = {
      boulderActorId = snapshot.boulderActorId,
      direction = snapshot.direction,
      mapId = snapshot.mapId,
    },
  }
  local plan = self:plan(request)
  assert(plan.kind == PUSH_STRENGTH, "push planning must produce a push plan")
  local blocked = self._world:validatePush(plan)
  if blocked ~= nil then
    return blocked
  end
  self._pending = copyValue(request)
  return { kind = "accepted" }
end

return FieldMoveRuntime
