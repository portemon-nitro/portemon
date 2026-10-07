-- Stateless ordered directional candidate resolution over an explicit graph.

---@alias FocusDirection "up"|"down"|"left"|"right"
---@alias FocusNodeId string|integer
---@alias FocusGraphMap table<FocusNodeId, table<string, FocusNodeId[]>>

local FocusGraph = {}

---@param graph FocusGraphMap
---@param currentId FocusNodeId|nil
---@param fallbackIds FocusNodeId[]
---@return FocusNodeId
function FocusGraph.reconcile(graph, currentId, fallbackIds)
  assert(type(graph) == "table", "the focus graph is required")
  if currentId ~= nil and graph[currentId] ~= nil then
    return currentId
  end
  assert(type(fallbackIds) == "table", "focus fallbacks must be an ordered list")
  local seen = 0
  for _ in pairs(fallbackIds) do
    seen = seen + 1
  end
  assert(seen == #fallbackIds, "focus fallbacks must be a dense ordered list")
  for _, candidateId in ipairs(fallbackIds) do
    if graph[candidateId] ~= nil then
      return candidateId
    end
  end
  error("focus graph has no reconcilable target", 2)
end

---@param graph FocusGraphMap
---@param currentId FocusNodeId
---@param direction FocusDirection
---@return FocusNodeId
function FocusGraph.move(graph, currentId, direction)
  assert(type(graph) == "table", "the focus graph is required")
  local node = assert(graph[currentId], "current focus node is absent")
  local candidates = assert(node[direction], "unknown focus direction")
  assert(type(candidates) == "table", "the focus direction field must be an ordered candidate list")
  for _, candidateId in ipairs(candidates) do
    if graph[candidateId] ~= nil then
      return candidateId
    end
  end
  return currentId
end

return FocusGraph
