-- Explicit battle queue mutation. Callers own the queue array; this owner
-- moves actions between queued, running, suspended and complete without ever
-- drawing from the battle stream. Interceptions suspend the live parent at
-- the child boundary and link the child to its causal parent; forced
-- replacements suspend and resume through the same states. Completions are
-- once-only: suspended, completed, cancelled and unknown actions fail loudly
-- instead of fabricating progress, so work never runs twice and stale actors
-- never resume.

local ActionQueue = {}

---@param queue ScheduledAction[]
---@param id integer
---@return integer? position
---@return ScheduledAction? action
local function locate(queue, id)
  assert(type(queue) == "table", "queue mutations own an explicit queue")
  assert(type(id) == "number" and id % 1 == 0, "queue mutations name an integer identity")
  for position, action in ipairs(queue) do
    if action.id == id then
      return position, action
    end
  end
  return nil, nil
end

---@param queue ScheduledAction[]
---@param action ScheduledAction
local function checkStaged(queue, action)
  assert(type(action) == "table", "staged actions are records")
  assert(type(action.id) == "number" and action.id % 1 == 0, "staged actions carry an integer identity")
  local _, existing = locate(queue, action.id)
  assert(existing == nil, "staged identities never repeat while queued")
  if action.progress == nil then
    action.progress = "queued"
  end
  assert(action.progress == "queued", "staged actions wait queued")
end

---@param queue ScheduledAction[]
---@param action ScheduledAction
function ActionQueue.enqueue(queue, action)
  checkStaged(queue, action)
  queue[#queue + 1] = action
end

---@param queue ScheduledAction[]
---@param parentId integer
---@param child ScheduledAction
function ActionQueue.intercept(queue, parentId, child)
  local _, parent = locate(queue, parentId)
  assert(parent ~= nil, "interceptions need their queued parent")
  assert(parent.progress == "queued" or parent.progress == "running", "interceptions suspend a live parent")
  checkStaged(queue, child)
  child.parentActionId = parentId
  parent.progress = "suspended"
  queue[#queue + 1] = child
end

---@param queue ScheduledAction[]
---@param id integer
function ActionQueue.suspend(queue, id)
  local _, action = locate(queue, id)
  assert(action ~= nil, "suspensions name a queued action")
  assert(action.progress == "queued" or action.progress == "running", "suspensions park a live action")
  action.progress = "suspended"
end

---@param queue ScheduledAction[]
---@param id integer
function ActionQueue.resume(queue, id)
  local _, action = locate(queue, id)
  assert(action ~= nil, "resumptions name a suspended action")
  assert(action.progress == "suspended", "resumptions restart a suspended action")
  action.progress = "queued"
end

---@param queue ScheduledAction[]
---@param id integer
function ActionQueue.complete(queue, id)
  local _, action = locate(queue, id)
  assert(action ~= nil, "completions name a queued action")
  assert(action.progress == "queued" or action.progress == "running", "completions finish a live action once")
  action.progress = "complete"
end

return ActionQueue
