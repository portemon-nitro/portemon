-- Resolves Save Editor focus within semantic regions and logical containers.

local Navigation = {}
local FocusGraph = require("libs.ui.src.FocusGraph")

local function findById(records, id)
  for _, record in ipairs(records) do
    if record.id == id then
      return record
    end
  end
  return nil
end

local function logicalIndex(region, targetId)
  if region.logical == nil then
    return nil
  end
  if region.logical.matrix ~= nil then
    for rowIndex, row in ipairs(region.logical.matrix) do
      for columnIndex, id in ipairs(row) do
        if id == targetId then
          return (rowIndex - 1) * #row + columnIndex
        end
      end
    end
    return nil
  end
  assert(type(region.logical.count) == "number" and region.logical.count >= 0)
  assert(type(region.logical.idAt) == "function" and type(region.logical.indexOf) == "function")
  return region.logical.indexOf(targetId)
end

local function controlFor(snapshot, targetId)
  return findById(snapshot.controls, targetId)
end

local function regionFor(snapshot, regionId)
  return findById(snapshot.regions, regionId)
end

local function eligibleControls(snapshot, regionId)
  local result = {}
  for _, control in ipairs(snapshot.controls) do
    if control.regionId == regionId and control.eligible and control.rect ~= nil then
      result[#result + 1] = { id = control.id, rect = control.rect, order = control.order }
    end
  end
  return result
end

local function validTarget(snapshot, targetId)
  local control = controlFor(snapshot, targetId)
  return control ~= nil and control.eligible and control or nil
end

local function moved(targetId, regionId, reason, reveal)
  return { kind = "move", targetId = targetId, regionId = regionId, reason = reason, reveal = reveal }
end

local function revealFor(region, targetId)
  if region.logical and region.logical.matrix then
    for rowIndex, row in ipairs(region.logical.matrix) do
      for _, id in ipairs(row) do
        if id == targetId then
          return { viewportId = region.viewportId or region.id, index = rowIndex }
        end
      end
    end
  end
  local index = logicalIndex(region, targetId)
  if index == nil then
    return nil
  end
  return { viewportId = region.viewportId or region.id, index = index }
end

local function entryTarget(snapshot, region, focus, direction)
  local remembered = snapshot.remembered and snapshot.remembered[region.id]
  local target = remembered and validTarget(snapshot, remembered) and remembered or region.defaultId
  if region.logical ~= nil and remembered ~= nil and logicalIndex(region, remembered) ~= nil then
    return remembered
  end
  if region.logical ~= nil and region.logical.matrix == nil then
    local rememberedIndex = remembered and logicalIndex(region, remembered)
    if rememberedIndex ~= nil then
      return remembered
    end
    local index = region.logical.indexOf(target)
    if index == nil and region.logical.count > 0 then
      target = region.logical.idAt(1)
    end
  elseif region.kind == "spatial" then
    local source = controlFor(snapshot, focus.targetId)
    if source ~= nil and source.rect ~= nil then
      target = FocusGraph.spatialCandidate(source.rect, eligibleControls(snapshot, region.id), direction) or target
    end
  end
  local control = validTarget(snapshot, target)
  return control and target or nil
end

local function resolveOverride(snapshot, override, source, direction)
  if override == nil then
    return nil
  end
  assert(type(override) == "table" and type(override.kind) == "string", "navigation override is malformed")
  if override.kind == "stop" then
    return { kind = "stay", regionId = source.regionId, reason = "override-stop" }
  elseif override.kind == "targets" then
    assert(type(override.ids) == "table", "target override needs an ordered id list")
    local count = 0
    for _ in pairs(override.ids) do
      count = count + 1
    end
    assert(count == #override.ids, "override targets must be dense")
    for _, id in ipairs(override.ids) do
      local target = validTarget(snapshot, id)
      if target ~= nil then
        return moved(id, target.regionId, "override-target")
      end
    end
    assert(override.fallback == "auto" or override.fallback == "stop", "target override needs a fallback")
    if override.fallback == "stop" then
      return { kind = "stay", regionId = source.regionId, reason = "override-fallback-stop" }
    end
  elseif override.kind == "region" then
    assert(override.entry == "spatial" or override.entry == "remembered", "region override needs an entry policy")
    assert(override.fallback == "auto" or override.fallback == "stop", "region override needs a fallback")
    local region = regionFor(snapshot, override.id)
    if region ~= nil then
      local target = override.entry == "remembered" and snapshot.remembered and snapshot.remembered[region.id] or nil
      target = target and validTarget(snapshot, target) and target or entryTarget(snapshot, region, source, direction)
      if target ~= nil then
        return moved(target, region.id, "override-region", revealFor(region, target))
      end
    end
    if override.fallback == "stop" then
      return { kind = "stay", regionId = source.regionId, reason = "override-fallback-stop" }
    end
  else
    error("unknown navigation override kind: " .. override.kind, 2)
  end
  return nil
end

local function logicalDestination(region, targetId, direction)
  if region.logical == nil then
    return nil
  end
  if region.logical.matrix ~= nil then
    local rowIndex, columnIndex
    for index, row in ipairs(region.logical.matrix) do
      for column, id in ipairs(row) do
        if id == targetId then
          rowIndex, columnIndex = index, column
          break
        end
      end
      if rowIndex ~= nil then
        break
      end
    end
    if rowIndex == nil then
      return nil
    end
    local nextRow, nextColumn = rowIndex, columnIndex
    if direction == "up" then
      nextRow = rowIndex - 1
    elseif direction == "down" then
      nextRow = rowIndex + 1
    elseif direction == "left" then
      nextColumn = columnIndex - 1
    else
      nextColumn = columnIndex + 1
    end
    local row = region.logical.matrix[nextRow]
    local id = row and row[nextColumn]
    if id ~= nil then
      return id, nextRow
    end
    return nil
  end
  local index = logicalIndex(region, targetId)
  if index == nil then
    return nil
  end
  local columns = region.logical.columns or 1
  assert(type(columns) == "number" and columns >= 1 and columns % 1 == 0)
  local count = region.logical.count
  local nextIndex
  if region.kind == "grid" then
    local delta = direction == "left" and -1 or direction == "right" and 1 or direction == "up" and -columns or columns
    nextIndex = index + delta
    if direction == "left" and (index - 1) % columns == 0 then
      return nil
    end
    if direction == "right" and (index % columns == 0 or nextIndex > count) then
      return nil
    end
    if direction == "up" or direction == "down" then
      if nextIndex < 1 then
        return nil
      end
      if nextIndex > count then
        local adjacentRow = math.floor((index - 1) / columns) + (direction == "down" and 1 or -1)
        local rowStart = adjacentRow * columns + 1
        if rowStart < 1 or rowStart > count then
          return nil
        end
        nextIndex = math.min(rowStart + ((index - 1) % columns), count)
      end
      local targetRow = math.floor((nextIndex - 1) / columns)
      if targetRow == math.floor((index - 1) / columns) then
        return nil
      end
    end
  elseif region.kind == "row" or region.kind == "column" or region.kind == "list" then
    if
      (region.kind == "row" and (direction == "left" or direction == "right"))
      or ((region.kind == "column" or region.kind == "list") and (direction == "up" or direction == "down"))
    then
      local step = (direction == "left" or direction == "up") and -1 or 1
      nextIndex = index + step
      if region.logical.wrap then
        nextIndex = (nextIndex - 1) % count + 1
      end
      if nextIndex < 1 or nextIndex > count then
        return nil
      end
    else
      return nil
    end
  else
    return nil
  end
  local id = region.logical.idAt(nextIndex)
  assert(id ~= nil, "logical container returned no id for an in-range index")
  return id, nextIndex
end

local function validateSnapshot(snapshot, focus)
  assert(type(snapshot) == "table" and type(snapshot.scope) == "table")
  assert(type(snapshot.scope.id) == "string" and type(snapshot.scope.epoch) == "number")
  assert(type(snapshot.regions) == "table" and type(snapshot.controls) == "table")
  assert(type(focus) == "table" and focus.scopeId == snapshot.scope.id)
  for _, region in ipairs(snapshot.regions) do
    assert(type(region.id) == "string" and type(region.order) == "number")
  end
  for _, control in ipairs(snapshot.controls) do
    assert(type(control.id) == "string" and type(control.regionId) == "string")
    assert(regionFor(snapshot, control.regionId) ~= nil, "control references an undeclared region")
  end
end

---@param snapshot table<string, unknown>
---@param focus {scopeId: string, regionId: string, targetId: string}
---@param fallbackTargets string[]
---@return {scopeId: string, regionId: string, targetId: string}
function Navigation.reconcile(snapshot, focus, fallbackTargets)
  assert(type(snapshot) == "table" and type(snapshot.regions) == "table" and type(snapshot.controls) == "table")
  assert(type(fallbackTargets) == "table")
  local currentRegion = regionFor(snapshot, focus.regionId)
  local current = currentRegion
      and focus.scopeId == snapshot.scope.id
      and (validTarget(snapshot, focus.targetId) or logicalIndex(currentRegion, focus.targetId) ~= nil)
    or nil
  if current ~= nil then
    local currentLogicalRegion = assert(currentRegion)
    if currentLogicalRegion.kind == "list" and currentLogicalRegion.containerId == focus.targetId then
      local remembered = snapshot.remembered and snapshot.remembered[currentLogicalRegion.id]
      local targetId = remembered and logicalIndex(currentLogicalRegion, remembered) ~= nil and remembered
        or currentLogicalRegion.defaultId
      if targetId ~= nil then
        return { scopeId = snapshot.scope.id, regionId = currentLogicalRegion.id, targetId = targetId }
      end
    end
    return focus
  end
  for _, targetId in ipairs(fallbackTargets) do
    local target = validTarget(snapshot, targetId)
    if target ~= nil then
      return { scopeId = snapshot.scope.id, regionId = target.regionId, targetId = targetId }
    end
  end
  error("navigation snapshot has no reconcilable target", 2)
end

---@param snapshot table<string, unknown>
---@param focus {scopeId: string, regionId: string, targetId: string}
---@param direction "up"|"down"|"left"|"right"
---@return table<string, unknown>
function Navigation.resolve(snapshot, focus, direction)
  validateSnapshot(snapshot, focus)
  assert(direction == "up" or direction == "down" or direction == "left" or direction == "right")
  local region = assert(regionFor(snapshot, focus.regionId), "focused region is absent")
  local source = controlFor(snapshot, focus.targetId)
  assert(source ~= nil or logicalIndex(region, focus.targetId) ~= nil, "logical focus is not a member of its region")
  local override = source and source.overrides and source.overrides[direction]
  local overridden = resolveOverride(snapshot, override, focus, direction)
  if overridden ~= nil then
    return overridden
  end
  if
    snapshot.editor
    and snapshot.editor.engaged
    and snapshot.editor.consumes
    and snapshot.editor.consumes[direction]
  then
    return { kind = "edit", regionId = region.id, reason = "editor" }
  end
  local targetId, index = logicalDestination(region, focus.targetId, direction)
  if targetId ~= nil then
    local target = validTarget(snapshot, targetId)
    if target ~= nil or logicalIndex(region, targetId) ~= nil then
      return moved(targetId, region.id, "container", { viewportId = region.viewportId or region.id, index = index })
    end
  end
  if region.kind == "spatial" and source and source.rect then
    local candidateId = FocusGraph.spatialCandidate(source.rect, eligibleControls(snapshot, region.id), direction)
    if candidateId ~= nil then
      return moved(candidateId, region.id, "spatial")
    end
  end
  local exit = region.exits and region.exits[direction]
  local exited = resolveOverride(snapshot, exit, focus, direction)
  if exited ~= nil then
    return exited
  end
  local regionCandidates = {}
  for _, candidate in ipairs(snapshot.regions) do
    if candidate.id ~= region.id and candidate.rect ~= nil then
      local target = entryTarget(snapshot, candidate, focus, direction)
      if target ~= nil then
        regionCandidates[#regionCandidates + 1] = { id = candidate.id, rect = candidate.rect, order = candidate.order }
      end
    end
  end
  local nextRegionId = region.rect and FocusGraph.spatialCandidate(region.rect, regionCandidates, direction)
  if nextRegionId ~= nil then
    local nextRegion = assert(regionFor(snapshot, nextRegionId))
    local nextTarget = entryTarget(snapshot, nextRegion, focus, direction)
    if nextTarget ~= nil then
      return moved(nextTarget, nextRegion.id, "region-entry", revealFor(nextRegion, nextTarget))
    end
  end
  return { kind = "stay", regionId = region.id, reason = "stop" }
end

local function tabEntryTarget(snapshot, region)
  local remembered = snapshot.remembered and snapshot.remembered[region.id]
  if remembered ~= nil then
    if validTarget(snapshot, remembered) ~= nil or logicalIndex(region, remembered) ~= nil then
      return remembered
    end
  end
  local target = region.defaultId
  if region.logical ~= nil and logicalIndex(region, target) == nil and region.logical.count > 0 then
    target = region.logical.idAt(1)
  end
  if target ~= nil and (validTarget(snapshot, target) ~= nil or logicalIndex(region, target) ~= nil) then
    return target
  end
  return nil
end

---@param snapshot table<string, unknown>
---@param focus {scopeId: string, regionId: string, targetId: string}
---@param direction "previous"|"next"
---@return table<string, unknown>
function Navigation.resolveTab(snapshot, focus, direction)
  validateSnapshot(snapshot, focus)
  assert(direction == "previous" or direction == "next")
  local indexed = {}
  local currentIndex
  for index, region in ipairs(snapshot.regions) do
    indexed[index] = { region = region, index = index }
    if region.id == focus.regionId then
      currentIndex = index
    end
  end
  assert(currentIndex ~= nil, "tab focus region is absent")
  table.sort(indexed, function(left, right)
    if left.region.order == right.region.order then
      return left.index < right.index
    end
    return left.region.order < right.region.order
  end)
  local sortedFocusIndex
  for index, candidate in ipairs(indexed) do
    if candidate.index == currentIndex then
      sortedFocusIndex = index
      break
    end
  end
  local count = #indexed
  local step = direction == "next" and 1 or -1
  for distance = 1, count do
    local index = ((assert(sortedFocusIndex) - 1 + step * distance) % count) + 1
    local region = indexed[index].region
    local targetId = tabEntryTarget(snapshot, region)
    if targetId ~= nil then
      if region.id == focus.regionId and targetId == focus.targetId then
        return { kind = "stay", regionId = region.id, reason = "tab-single-region" }
      end
      return moved(targetId, region.id, "tab-region", revealFor(region, targetId))
    end
  end
  return { kind = "stay", regionId = focus.regionId, reason = "tab-no-region" }
end

return Navigation
