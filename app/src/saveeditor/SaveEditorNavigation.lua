-- Resolves Save Editor focus within semantic regions and logical containers.
-- Navigation graphs are checked once at publication: Navigation.compile builds a
-- detached record with lookup indexes, and the resolvers below run against it.
-- Raw records are compiled on demand so established callers keep their meaning.

local Navigation = {}
local FocusGraph = require("libs.ui.src.FocusGraph")

local function isRect(value)
  return type(value) == "table"
    and type(value.x) == "number"
    and type(value.y) == "number"
    and type(value.width) == "number"
    and type(value.height) == "number"
end

local function copyArray(records)
  local result = {}
  for index, record in ipairs(records) do
    result[index] = record
  end
  return result
end

local function buildCompiled(raw)
  assert(type(raw) == "table", "navigation snapshot is required")
  assert(type(raw.scope) == "table", "navigation snapshot needs a scope")
  assert(type(raw.scope.id) == "string" and type(raw.scope.epoch) == "number")
  assert(type(raw.regions) == "table" and type(raw.controls) == "table")
  local regions = copyArray(raw.regions)
  local controls = copyArray(raw.controls)
  local regionById = {}
  for _, region in ipairs(regions) do
    assert(type(region.id) == "string" and type(region.order) == "number")
    assert(regionById[region.id] == nil, "duplicate navigation region id: " .. region.id)
    if region.rect ~= nil then
      assert(isRect(region.rect), "navigation region has malformed coordinates: " .. region.id)
    end
    regionById[region.id] = region
  end
  local controlById = {}
  for _, control in ipairs(controls) do
    assert(type(control.id) == "string" and type(control.regionId) == "string")
    assert(controlById[control.id] == nil, "duplicate navigation target id: " .. control.id)
    assert(regionById[control.regionId] ~= nil, "control references an undeclared region")
    controlById[control.id] = control
  end
  local eligibleByRegion = {}
  for _, region in ipairs(regions) do
    eligibleByRegion[region.id] = {}
  end
  for _, control in ipairs(controls) do
    if control.eligible and control.rect ~= nil then
      local eligible = assert(eligibleByRegion[control.regionId])
      eligible[#eligible + 1] = { id = control.id, rect = control.rect, order = control.order }
    end
  end
  local indexed = {}
  for index, region in ipairs(regions) do
    indexed[index] = { region = region, index = index }
  end
  table.sort(indexed, function(left, right)
    if left.region.order == right.region.order then
      return left.index < right.index
    end
    return left.region.order < right.region.order
  end)
  local tabRegions = {}
  for index, entry in ipairs(indexed) do
    tabRegions[index] = entry.region
  end
  local matrixMembers = {}
  for _, region in ipairs(regions) do
    if region.logical ~= nil and region.logical.matrix ~= nil then
      local members = {}
      for rowIndex, row in ipairs(region.logical.matrix) do
        for columnIndex, id in ipairs(row) do
          if members[id] == nil then
            members[id] = { row = rowIndex, column = columnIndex, position = (rowIndex - 1) * #row + columnIndex }
          end
        end
      end
      matrixMembers[region.id] = members
    end
  end
  local remembered
  if type(raw.remembered) == "table" then
    remembered = {}
    for key, value in pairs(raw.remembered) do
      remembered[key] = value
    end
  end
  return {
    scope = { id = raw.scope.id, epoch = raw.scope.epoch },
    regions = regions,
    controls = controls,
    editor = raw.editor,
    remembered = remembered,
    controlById = controlById,
    regionById = regionById,
    eligibleByRegion = eligibleByRegion,
    tabRegions = tabRegions,
    matrixMembers = matrixMembers,
  }
end

local function isCompiled(snapshot)
  return type(snapshot) == "table"
    and type(snapshot.controlById) == "table"
    and type(snapshot.regionById) == "table"
    and type(snapshot.eligibleByRegion) == "table"
    and type(snapshot.tabRegions) == "table"
    and type(snapshot.matrixMembers) == "table"
end

local function ensureCompiled(snapshot)
  if isCompiled(snapshot) then
    return snapshot
  end
  return buildCompiled(snapshot)
end

---@param rawSnapshot table<string, unknown>
---@return table<string, unknown>
function Navigation.compile(rawSnapshot)
  return buildCompiled(rawSnapshot)
end

local function controlFor(snapshot, targetId)
  return snapshot.controlById[targetId]
end

local function regionFor(snapshot, regionId)
  return snapshot.regionById[regionId]
end

local function eligibleControls(snapshot, regionId)
  return snapshot.eligibleByRegion[regionId] or {}
end

local function matrixMember(snapshot, region, targetId)
  local members = snapshot.matrixMembers[region.id]
  return members and members[targetId] or nil
end

local function logicalIndex(snapshot, region, targetId)
  if region.logical == nil then
    return nil
  end
  if region.logical.matrix ~= nil then
    local member = matrixMember(snapshot, region, targetId)
    return member and member.position or nil
  end
  assert(type(region.logical.count) == "number" and region.logical.count >= 0)
  assert(type(region.logical.idAt) == "function" and type(region.logical.indexOf) == "function")
  return region.logical.indexOf(targetId)
end

local function validTarget(snapshot, targetId)
  local control = controlFor(snapshot, targetId)
  return control ~= nil and control.eligible and control or nil
end

local function moved(targetId, regionId, reason, reveal)
  return { kind = "move", targetId = targetId, regionId = regionId, reason = reason, reveal = reveal }
end

local function revealFor(snapshot, region, targetId)
  if type(region.viewportId) ~= "string" or region.viewportId == "" then
    return nil
  end
  if region.logical and region.logical.matrix then
    local member = matrixMember(snapshot, region, targetId)
    if member == nil then
      return nil
    end
    return { viewportId = region.viewportId, index = member.row }
  end
  local index = logicalIndex(snapshot, region, targetId)
  if index == nil then
    return nil
  end
  return { viewportId = region.viewportId, index = index }
end

local function entryTarget(snapshot, region, focus, direction)
  local remembered = snapshot.remembered and snapshot.remembered[region.id]
  local directionalEntry = direction == "up" and region.entryUpId or nil
  local target = directionalEntry or remembered and validTarget(snapshot, remembered) and remembered or region.defaultId
  if
    region.logical ~= nil
    and directionalEntry == nil
    and remembered ~= nil
    and logicalIndex(snapshot, region, remembered) ~= nil
  then
    return remembered
  end
  if region.logical ~= nil and region.logical.matrix == nil then
    local rememberedIndex = remembered and logicalIndex(snapshot, region, remembered)
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
  local control = controlFor(snapshot, target)
  if control ~= nil then
    return control.eligible and target or nil
  end
  if
    type(region.viewportId) == "string"
    and region.viewportId ~= ""
    and logicalIndex(snapshot, region, target) ~= nil
  then
    return target
  end
  return nil
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
        return moved(target, region.id, "override-region", revealFor(snapshot, region, target))
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

local function matrixDestination(snapshot, region, targetId, direction)
  local member = matrixMember(snapshot, region, targetId)
  if member == nil then
    return nil
  end
  local rowIndex, columnIndex = member.row, member.column
  local matrix = region.logical.matrix
  if direction == "left" or direction == "right" then
    local step = direction == "left" and -1 or 1
    local column = columnIndex + step
    while column >= 1 and column <= #matrix[rowIndex] do
      local candidate = matrix[rowIndex][column]
      if type(candidate) == "string" then
        return candidate, rowIndex
      end
      column = column + step
    end
    return nil
  end
  local nextRow = direction == "up" and rowIndex - 1 or rowIndex + 1
  local row = matrix[nextRow]
  if row == nil then
    return nil
  end
  local candidate = row[columnIndex]
  if type(candidate) == "string" then
    return candidate, nextRow
  end
  -- Jagged rows (a wide primary row above a single Back action) still
  -- resolve by nearest column: the search spans the full column gap,
  -- not just the next row's own width.
  for distance = 1, math.max(#row, columnIndex) do
    candidate = row[columnIndex - distance]
    if type(candidate) == "string" then
      return candidate, nextRow
    end
    candidate = row[columnIndex + distance]
    if type(candidate) == "string" then
      return candidate, nextRow
    end
  end
  return nil
end

local function gridNextIndex(index, count, columns, direction)
  if direction == "left" then
    return (index - 1) % columns ~= 0 and index - 1 or nil
  end
  if direction == "right" then
    local nextIndex = index + 1
    return index % columns ~= 0 and nextIndex <= count and nextIndex or nil
  end
  local nextIndex = direction == "up" and index - columns or index + columns
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
  if math.floor((nextIndex - 1) / columns) == math.floor((index - 1) / columns) then
    return nil
  end
  return nextIndex
end

local function listNextIndex(region, index, direction)
  local horizontal = direction == "left" or direction == "right"
  if horizontal ~= (region.kind == "row") then
    return nil
  end
  local count = region.logical.count
  local nextIndex = index + ((direction == "left" or direction == "up") and -1 or 1)
  if region.logical.wrap then
    nextIndex = (nextIndex - 1) % count + 1
  end
  if nextIndex < 1 or nextIndex > count then
    return nil
  end
  return nextIndex
end

local function logicalDestination(snapshot, region, targetId, direction)
  if region.logical == nil then
    return nil
  end
  if region.logical.matrix ~= nil then
    return matrixDestination(snapshot, region, targetId, direction)
  end
  local index = logicalIndex(snapshot, region, targetId)
  if index == nil then
    return nil
  end
  local columns = region.logical.columns or 1
  assert(type(columns) == "number" and columns >= 1 and columns % 1 == 0)
  local nextIndex
  if region.kind == "grid" then
    nextIndex = gridNextIndex(index, region.logical.count, columns, direction)
  elseif region.kind == "row" or region.kind == "column" or region.kind == "list" then
    nextIndex = listNextIndex(region, index, direction)
  end
  if nextIndex == nil then
    return nil
  end
  local id = region.logical.idAt(nextIndex)
  assert(id ~= nil, "logical container returned no id for an in-range index")
  return id, nextIndex
end

---@param snapshotInput table<string, unknown>
---@param focus {scopeId: string, regionId: string, targetId: string}
---@param fallbackTargets string[]
---@return {scopeId: string, regionId: string, targetId: string}
function Navigation.reconcile(snapshotInput, focus, fallbackTargets)
  local snapshot = ensureCompiled(snapshotInput)
  assert(type(snapshot.regions) == "table" and type(snapshot.controls) == "table")
  assert(type(fallbackTargets) == "table")
  local currentRegion = regionFor(snapshot, focus.regionId)
  local targetRegion
  if focus.scopeId == snapshot.scope.id then
    local targetControl = controlFor(snapshot, focus.targetId)
    if targetControl ~= nil then
      if targetControl.eligible then
        targetRegion = assert(regionFor(snapshot, targetControl.regionId), "control references an undeclared region")
      end
    elseif currentRegion ~= nil and logicalIndex(snapshot, currentRegion, focus.targetId) ~= nil then
      targetRegion = currentRegion
    end
  end
  if targetRegion ~= nil then
    local currentLogicalRegion = targetRegion
    if currentLogicalRegion.kind == "list" and currentLogicalRegion.containerId == focus.targetId then
      local remembered = snapshot.remembered and snapshot.remembered[currentLogicalRegion.id]
      local targetId = remembered and logicalIndex(snapshot, currentLogicalRegion, remembered) ~= nil and remembered
        or currentLogicalRegion.defaultId
      if targetId ~= nil then
        return { scopeId = snapshot.scope.id, regionId = currentLogicalRegion.id, targetId = targetId }
      end
    end
    if targetRegion.id == focus.regionId then
      return focus
    end
    return { scopeId = snapshot.scope.id, regionId = targetRegion.id, targetId = focus.targetId }
  end
  for _, targetId in ipairs(fallbackTargets) do
    local target = validTarget(snapshot, targetId)
    if target ~= nil then
      return { scopeId = snapshot.scope.id, regionId = target.regionId, targetId = targetId }
    end
  end
  error("navigation snapshot has no reconcilable target", 2)
end

---@param snapshotInput table<string, unknown>
---@param focus {scopeId: string, regionId: string, targetId: string}
---@param direction "up"|"down"|"left"|"right"
---@return table<string, unknown>
function Navigation.resolve(snapshotInput, focus, direction)
  local snapshot = ensureCompiled(snapshotInput)
  assert(type(focus) == "table" and focus.scopeId == snapshot.scope.id)
  assert(direction == "up" or direction == "down" or direction == "left" or direction == "right")
  local region = assert(regionFor(snapshot, focus.regionId), "focused region is absent")
  local source = controlFor(snapshot, focus.targetId)
  assert(
    source ~= nil or logicalIndex(snapshot, region, focus.targetId) ~= nil,
    "logical focus is not a member of its region"
  )
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
  local targetId = logicalDestination(snapshot, region, focus.targetId, direction)
  if targetId ~= nil then
    local target = validTarget(snapshot, targetId)
    if target ~= nil or logicalIndex(snapshot, region, targetId) ~= nil then
      return moved(targetId, region.id, "container", revealFor(snapshot, region, targetId))
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
      return moved(nextTarget, nextRegion.id, "region-entry", revealFor(snapshot, nextRegion, nextTarget))
    end
  end
  return { kind = "stay", regionId = region.id, reason = "stop" }
end

local function tabEntryTarget(snapshot, region)
  local remembered = snapshot.remembered and snapshot.remembered[region.id]
  if remembered ~= nil then
    if validTarget(snapshot, remembered) ~= nil or logicalIndex(snapshot, region, remembered) ~= nil then
      return remembered
    end
  end
  local target = region.defaultId
  if region.logical ~= nil and logicalIndex(snapshot, region, target) == nil and region.logical.count > 0 then
    target = region.logical.idAt(1)
  end
  if target ~= nil and (validTarget(snapshot, target) ~= nil or logicalIndex(snapshot, region, target) ~= nil) then
    return target
  end
  return nil
end

---@param snapshotInput table<string, unknown>
---@param focus {scopeId: string, regionId: string, targetId: string}
---@param direction "previous"|"next"
---@return table<string, unknown>
function Navigation.resolveTab(snapshotInput, focus, direction)
  local snapshot = ensureCompiled(snapshotInput)
  assert(type(focus) == "table" and focus.scopeId == snapshot.scope.id)
  assert(direction == "previous" or direction == "next")
  local ordered = snapshot.tabRegions
  local sortedFocusIndex
  for index, region in ipairs(ordered) do
    if region.id == focus.regionId then
      sortedFocusIndex = index
      break
    end
  end
  assert(sortedFocusIndex ~= nil, "tab focus region is absent")
  local count = #ordered
  local step = direction == "next" and 1 or -1
  for distance = 1, count do
    local index = ((sortedFocusIndex - 1 + step * distance) % count) + 1
    local region = ordered[index]
    local targetId = tabEntryTarget(snapshot, region)
    if targetId ~= nil then
      if region.id == focus.regionId and targetId == focus.targetId then
        return { kind = "stay", regionId = region.id, reason = "tab-single-region" }
      end
      return moved(targetId, region.id, "tab-region", revealFor(snapshot, region, targetId))
    end
  end
  return { kind = "stay", regionId = focus.regionId, reason = "tab-no-region" }
end

return Navigation
