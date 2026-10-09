-- Stateless ordered directional candidate resolution over an explicit graph.

---@alias FocusDirection "up"|"down"|"left"|"right"
---@alias FocusNodeId string|integer
---@alias FocusGraphMap table<FocusNodeId, table<string, FocusNodeId[]>>

local FocusGraph = {}

local function validateRect(value, label)
  assert(type(value) == "table", label .. " must be a rectangle")
  for _, key in ipairs({ "x", "y", "width", "height" }) do
    local number = value[key]
    assert(
      type(number) == "number" and number == number and math.abs(number) < math.huge,
      label .. " has invalid " .. key
    )
  end
  assert(value.width > 0 and value.height > 0, label .. " must have positive dimensions")
end

---@param sourceRect table<string, number>
---@param candidates {id: FocusNodeId, rect: table<string, number>, order: integer}[]
---@param direction FocusDirection
---@return FocusNodeId?
function FocusGraph.spatialCandidate(sourceRect, candidates, direction)
  validateRect(sourceRect, "source rectangle")
  assert(direction == "up" or direction == "down" or direction == "left" or direction == "right")
  assert(type(candidates) == "table", "spatial candidates must be an ordered list")
  local count = 0
  for _ in pairs(candidates) do
    count = count + 1
  end
  assert(count == #candidates, "spatial candidates must be dense")

  local sourceCenterX = sourceRect.x + sourceRect.width / 2
  local sourceCenterY = sourceRect.y + sourceRect.height / 2
  local ranked = {}
  local seen = {}
  for index, candidate in ipairs(candidates) do
    assert(type(candidate) == "table", "spatial candidate must be a record")
    assert(type(candidate.id) == "string" or type(candidate.id) == "number", "spatial candidate needs an id")
    assert(not seen[candidate.id], "spatial candidate ids must be unique")
    seen[candidate.id] = true
    validateRect(candidate.rect, "candidate rectangle")
    assert(type(candidate.order) == "number" and candidate.order % 1 == 0, "candidate order must be an integer")
    local rect = candidate.rect
    local centerX, centerY = rect.x + rect.width / 2, rect.y + rect.height / 2
    local forward = direction == "right" and centerX - sourceCenterX
      or direction == "left" and sourceCenterX - centerX
      or direction == "down" and centerY - sourceCenterY
      or sourceCenterY - centerY
    if forward > 0 then
      local perpendicular = (direction == "left" or direction == "right") and math.abs(centerY - sourceCenterY)
        or math.abs(centerX - sourceCenterX)
      local horizontal = direction == "left" or direction == "right"
      local sourcePerpStart = horizontal and sourceRect.y or sourceRect.x
      local sourcePerpExtent = horizontal and sourceRect.height or sourceRect.width
      local candidatePerpStart = horizontal and rect.y or rect.x
      local candidatePerpExtent = horizontal and rect.height or rect.width
      local overlap = math.min(sourcePerpStart + sourcePerpExtent, candidatePerpStart + candidatePerpExtent)
        - math.max(sourcePerpStart, candidatePerpStart)
      local sourceEdge = direction == "right" and (sourceRect.x + sourceRect.width)
        or direction == "left" and sourceRect.x
        or direction == "down" and (sourceRect.y + sourceRect.height)
        or sourceRect.y
      local candidateEdge = direction == "right" and rect.x
        or direction == "left" and (rect.x + rect.width)
        or direction == "down" and rect.y
        or (rect.y + rect.height)
      local edgeGap = (direction == "left" or direction == "up") and sourceEdge - candidateEdge
        or candidateEdge - sourceEdge
      local horizontalGap =
        math.max(0, math.max(sourceRect.x - (rect.x + rect.width), rect.x - (sourceRect.x + sourceRect.width)))
      local verticalGap =
        math.max(0, math.max(sourceRect.y - (rect.y + rect.height), rect.y - (sourceRect.y + sourceRect.height)))
      ranked[#ranked + 1] = {
        id = candidate.id,
        order = candidate.order,
        beam = overlap > 0,
        edgeGap = edgeGap,
        perpendicular = perpendicular,
        edgeDistance = horizontalGap * horizontalGap + verticalGap * verticalGap,
        inputOrder = index,
      }
    end
  end
  table.sort(ranked, function(a, b)
    if a.beam ~= b.beam then
      return a.beam
    elseif a.beam then
      if a.edgeGap ~= b.edgeGap then
        return a.edgeGap < b.edgeGap
      elseif a.perpendicular ~= b.perpendicular then
        return a.perpendicular < b.perpendicular
      end
    else
      if a.edgeDistance ~= b.edgeDistance then
        return a.edgeDistance < b.edgeDistance
      elseif a.perpendicular ~= b.perpendicular then
        return a.perpendicular < b.perpendicular
      elseif a.edgeGap ~= b.edgeGap then
        return a.edgeGap < b.edgeGap
      end
    end
    if a.order ~= b.order then
      return a.order < b.order
    end
    return a.inputOrder < b.inputOrder
  end)
  return ranked[1] and ranked[1].id or nil
end

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
