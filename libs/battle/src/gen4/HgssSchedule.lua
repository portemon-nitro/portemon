-- Native control-flow state machine. Explicit cursors track the player
-- controller flow from opening through selection, execution, residuals and
-- closing. Each step yields the next queued action or suspends with nil when
-- no decision is available yet; presentation-only waits resolve into
-- semantic boundaries and never block headless progress. Operation budgets
-- change responsiveness only: every budget yields the same sequence and
-- stepping consumes no draws. Native anchors: battle_controller_player,
-- CheckSortSpeed, SortMonsBySpeed, SortExecutionOrderBySpeed and the command
-- and subscript dispatch they feed.

---@class NativeScheduleFrame
---@field kind string
---@field version integer
---@field cursor string
---@field currentActionId integer?
---@field residualCursor string?
---@field pendingFaints integer[]

local HgssSchedule = {}

HgssSchedule.KIND = "hgss:schedule"
HgssSchedule.VERSION = 1

---@param frame NativeScheduleFrame
function HgssSchedule.validateFrame(frame)
  assert(type(frame) == "table", "schedule frames are records")
  assert(frame.kind == HgssSchedule.KIND, "schedule frames carry the native schedule identity")
  assert(frame.version == HgssSchedule.VERSION, "schedule frames carry the current version")
  assert(type(frame.cursor) == "string" and frame.cursor ~= "", "schedule frames name their cursor")
  assert(
    frame.currentActionId == nil or (type(frame.currentActionId) == "number" and frame.currentActionId % 1 == 0),
    "schedule frames track an integer action when one is due"
  )
  assert(
    frame.residualCursor == nil or type(frame.residualCursor) == "string",
    "schedule frames name their residual cursor when one is open"
  )
  assert(type(frame.pendingFaints) == "table", "schedule frames carry their pending faints")
end

---@param queue ScheduledAction[]
---@param frame NativeScheduleFrame
---@param stream BattleRng
---@param budget integer? operations this call may spend before yielding
---@return ScheduledAction? due the next queued action, or nil when suspended
function HgssSchedule.step(queue, frame, stream, budget)
  assert(type(queue) == "table", "schedule steps drain an explicit queue")
  HgssSchedule.validateFrame(frame)
  assert(type(stream) == "table", "schedule steps carry the battle stream")
  local allowance = budget
  if allowance == nil then
    allowance = 1024
  end
  assert(
    type(allowance) == "number" and allowance % 1 == 0 and allowance >= 1,
    "schedule steps spend a positive operation budget"
  )
  for _, action in ipairs(queue) do
    if action.progress == "queued" then
      action.progress = "running"
      frame.currentActionId = action.id
      return action
    end
  end
  frame.currentActionId = nil
  return nil
end

---@return table<string, string> cursor behavior mapping with native anchors
function HgssSchedule.sourceCorrespondence()
  return {
    opening = "player controller opening: message and animation waits resolve into semantic boundaries while only the first decision batch suspends headless progress (battle_controller_player)",
    selection = "decision batch collection: external input suspends the schedule and sealed replies never advance the battle stream (battle_controller_player)",
    execution = "ordered action execution in SortExecutionOrderBySpeed traversal: priority brackets, sampled speed, stream-drawn ties (CheckSortSpeed, SortMonsBySpeed, SortExecutionOrderBySpeed)",
    residual = "end-of-turn residual traversal in sampled speed order with explicit cursor boundaries (command and subscript dispatch)",
    faint = "faint settlement suspends the parent continuation until replacement resolves, so stale actors never act (command and subscript dispatch)",
    closing = "outcome publication runs exactly once after every queued action settles (battle_controller_player)",
  }
end

return HgssSchedule
