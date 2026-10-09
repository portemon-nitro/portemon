-- Groups structural map summaries by their source map section.

local SaveEditorMapCatalog = {}
SaveEditorMapCatalog.__index = SaveEditorMapCatalog

---@class SaveEditorMapCatalogRow
---@field targetId string
---@field kind "group"|"map"
---@field mapSectionNativeId integer?
---@field groupId string?
---@field mapId integer?
---@field symbol string?
---@field section string
---@field displayName string
---@field maps SaveEditorMapCatalogRow[]?

---@class SaveEditorMapSummary
---@field mapId integer
---@field symbol string
---@field section string
---@field mapSectionNativeId integer
---@field displayName string

---@class SaveEditorMapGroupRow: SaveEditorMapCatalogRow
---@field maps SaveEditorMapCatalogRow[]

---@class SaveEditorMapCatalog
---@field groupRows SaveEditorMapGroupRow[]
---@field groupById table<string, SaveEditorMapGroupRow>
---@field groupIdByMap table<integer, string>
---@field groups fun(self: SaveEditorMapCatalog, query: string): SaveEditorMapCatalogProjection
---@field maps fun(self: SaveEditorMapCatalog, groupId: string, query: string): SaveEditorMapCatalogProjection
---@field groupForMap fun(self: SaveEditorMapCatalog, mapId: integer): string?

---@class SaveEditorMapCatalogProjection
---@field revision integer
---@field queryRevision integer
---@field pending boolean
---@field count integer
---@field rowTargets string[]
---@field indexByTarget table<string, integer>
---@field idAt fun(index: integer): string?
---@field indexOf fun(targetId: string): integer?
---@field rowAt fun(index: integer): SaveEditorMapCatalogRow?

---@param rows SaveEditorMapCatalogRow[]
---@return SaveEditorMapCatalogProjection
local function projection(rows)
  local rowTargets, indexByTarget = {}, {}
  for index, row in ipairs(rows) do
    rowTargets[index] = row.targetId
    indexByTarget[row.targetId] = index
  end
  return {
    revision = 1,
    queryRevision = 0,
    pending = false,
    count = #rows,
    rowTargets = rowTargets,
    indexByTarget = indexByTarget,
    idAt = function(index)
      return rowTargets[index]
    end,
    indexOf = function(targetId)
      return indexByTarget[targetId]
    end,
    rowAt = function(index)
      return rows[index]
    end,
  }
end

local function folded(value)
  return value:lower()
end

local function matches(label, query)
  return query == "" or folded(label):find(query, 1, true) ~= nil
end

local function rowOrder(left, right)
  if left.displayName ~= right.displayName then
    return left.displayName < right.displayName
  end
  local leftIdentity = left.mapSectionNativeId or left.mapId or left.groupId
  local rightIdentity = right.mapSectionNativeId or right.mapId or right.groupId
  assert(leftIdentity ~= nil and rightIdentity ~= nil, "catalog rows have stable sort identities")
  if type(leftIdentity) == "number" and type(rightIdentity) == "number" then
    return leftIdentity < rightIdentity
  end
  return tostring(leftIdentity) < tostring(rightIdentity)
end

local function newSort(rows, publish)
  return { source = rows, destination = {}, width = 1, left = 1, output = 1, publish = publish }
end

local function advanceSort(sort, budget)
  local used = 0
  local count = #sort.source
  while used < budget and sort.width < count do
    if sort.left > count then
      sort.source, sort.destination = sort.destination, sort.source
      sort.width = sort.width * 2
      sort.left = 1
      sort.output = 1
      sort.leftEnd, sort.rightEnd, sort.i, sort.j = nil, nil, nil, nil
      if sort.width >= count then
        return used, true
      end
    end
    if sort.leftEnd == nil then
      sort.leftEnd = math.min(sort.left + sort.width - 1, count)
      sort.rightEnd = math.min(sort.left + sort.width * 2 - 1, count)
      sort.i = sort.left
      sort.j = sort.leftEnd + 1
    end
    local i, j = assert(sort.i), assert(sort.j)
    local leftEnd, rightEnd = assert(sort.leftEnd), assert(sort.rightEnd)
    if i > leftEnd and j > rightEnd then
      sort.left = rightEnd + 1
      sort.leftEnd, sort.rightEnd, sort.i, sort.j = nil, nil, nil, nil
    elseif i > leftEnd then
      sort.destination[sort.output] = sort.source[j]
      sort.j = j + 1
      sort.output = sort.output + 1
      used = used + 1
    elseif j > rightEnd then
      sort.destination[sort.output] = sort.source[i]
      sort.i = i + 1
      sort.output = sort.output + 1
      used = used + 1
    else
      if budget - used < 2 then
        break
      end
      if rowOrder(sort.source[j], sort.source[i]) then
        sort.destination[sort.output] = sort.source[j]
        sort.j = j + 1
      else
        sort.destination[sort.output] = sort.source[i]
        sort.i = i + 1
      end
      sort.output = sort.output + 1
      used = used + 2
    end
  end
  return used, sort.width >= count
end

---@class SaveEditorMapCatalogTask
---@field summaries SaveEditorMapSummary[]
---@field cursor integer
---@field groups SaveEditorMapGroupRow[]
---@field groupById table<string, SaveEditorMapGroupRow>
---@field groupIdByMap table<integer, string>
---@field seenMapIds table<integer, boolean>
---@field sorts table[]
---@field sortIndex integer
---@field groupsSortQueued boolean
---@field catalog SaveEditorMapCatalog?
---@field advance fun(self: SaveEditorMapCatalogTask, budget: integer): integer, boolean
---@field take fun(self: SaveEditorMapCatalogTask): SaveEditorMapCatalog

local function completeTask(task)
  task.catalog = setmetatable({
    groupRows = task.groups,
    groupById = task.groupById,
    groupIdByMap = task.groupIdByMap,
  }, SaveEditorMapCatalog)
end

---@param task SaveEditorMapCatalogTask
---@param budget integer
---@return integer used
---@return boolean complete
local function advanceTask(task, budget)
  assert(
    type(budget) == "number" and budget % 1 == 0 and budget >= 0,
    "catalog work budget must be a non-negative integer"
  )
  local used = 0
  while used < budget and task.catalog == nil do
    if task.cursor <= #task.summaries then
      local summary = task.summaries[task.cursor]
      local mapId = summary.mapId
      assert(type(mapId) == "number" and mapId % 1 == 0, "map summary needs its source map ID")
      assert(not task.seenMapIds[mapId], "a structural map summary appears once")
      task.seenMapIds[mapId] = true
      local nativeId = summary.mapSectionNativeId
      assert(type(nativeId) == "number" and nativeId % 1 == 0, "map summary needs its source map-section identity")
      assert(type(summary.section) == "string" and summary.section ~= "", "map summary needs its section label")
      assert(type(summary.symbol) == "string" and summary.symbol ~= "", "map summary needs its source symbol")
      assert(type(summary.displayName) == "string" and summary.displayName ~= "", "map summary needs its display name")
      local groupId, groupName, nativeGroup
      if summary.symbol == "MAP_BATTLE_FRONTIER" or summary.symbol:match("^MAP_BATTLE_FRONTIER_") ~= nil then
        groupId, groupName = "location:group:battle-frontier", "BATTLE FRONTIER"
      elseif summary.symbol:match("^MAP.*_ROUTE_") ~= nil then
        groupId, groupName = "location:group:routes", "ROUTES"
      else
        groupId = "location:group:" .. nativeId
        groupName = summary.section
        nativeGroup = true
      end
      local group = task.groupById[groupId]
      if group == nil then
        group = {
          targetId = groupId,
          kind = "group",
          groupId = groupId,
          mapSectionNativeId = nativeGroup and nativeId or nil,
          section = groupName,
          displayName = groupName,
          maps = {},
        }
        task.groupById[groupId] = group
        task.groups[#task.groups + 1] = group
        task.sorts[#task.sorts + 1] = newSort(group.maps, function(sorted)
          group.maps = sorted
        end)
      elseif group.mapSectionNativeId ~= nil then
        assert(group.section == summary.section, "one source section identity has one display label")
      end
      group.maps[#group.maps + 1] = {
        targetId = "location:map:" .. mapId,
        kind = "map",
        mapId = mapId,
        symbol = summary.symbol,
        section = summary.section,
        displayName = summary.displayName,
      }
      task.groupIdByMap[mapId] = groupId
      task.cursor = task.cursor + 1
      used = used + 1
    elseif task.sortIndex <= #task.sorts then
      local consumed, complete = advanceSort(task.sorts[task.sortIndex], budget - used)
      used = used + consumed
      if complete then
        local sort = task.sorts[task.sortIndex]
        if not sort.published then
          sort.publish(sort.source)
          sort.published = true
        end
        task.sortIndex = task.sortIndex + 1
      elseif consumed == 0 then
        break
      end
    elseif not task.groupsSortQueued then
      task.groupsSortQueued = true
      task.sorts[#task.sorts + 1] = newSort(task.groups, function(sorted)
        task.groups = sorted
      end)
    else
      completeTask(task)
    end
  end
  return used, task.catalog ~= nil
end

---@param task SaveEditorMapCatalogTask
---@return SaveEditorMapCatalog
local function takeTask(task)
  assert(task.catalog ~= nil, "catalog preparation is complete before publication")
  local catalog = assert(task.catalog)
  task.catalog = nil
  return catalog
end

---@param summaries SaveEditorMapSummary[] immutable structural map summaries
---@return SaveEditorMapCatalogTask
function SaveEditorMapCatalog.newTask(summaries)
  assert(type(summaries) == "table", "map summaries are required")
  return {
    summaries = summaries,
    cursor = 1,
    groups = {},
    groupById = {},
    groupIdByMap = {},
    seenMapIds = {},
    sorts = {},
    sortIndex = 1,
    groupsSortQueued = false,
    advance = advanceTask,
    take = takeTask,
  }
end

---@param summaries SaveEditorMapSummary[] immutable structural map summaries
---@return SaveEditorMapCatalog
function SaveEditorMapCatalog.new(summaries)
  local task = SaveEditorMapCatalog.newTask(summaries)
  local complete = false
  while not complete do
    local _, isComplete = task:advance(math.max(1, #summaries * 4))
    complete = isComplete
  end
  return task:take()
end

---@param mapId integer
---@return string? groupId
function SaveEditorMapCatalog:groupForMap(mapId)
  return self.groupIdByMap[mapId]
end

---@param query string
---@return SaveEditorMapCatalogProjection
function SaveEditorMapCatalog:groups(query)
  assert(type(query) == "string", "group query must be text")
  query = folded(query)
  local rows = {}
  for _, group in ipairs(self.groupRows) do
    local include = matches(group.displayName, query)
    if not include then
      for _, map in ipairs(group.maps) do
        if matches(map.displayName, query) then
          include = true
          break
        end
      end
    end
    if include then
      rows[#rows + 1] = group
    end
  end
  return projection(rows)
end

---@param groupId string
---@param query string
---@return SaveEditorMapCatalogProjection
function SaveEditorMapCatalog:maps(groupId, query)
  assert(type(groupId) == "string", "map group identity must be text")
  assert(type(query) == "string", "map query must be text")
  local group = assert(self.groupById[groupId], "map group must exist in the source catalog")
  query = folded(query)
  local rows = {}
  for _, map in ipairs(group.maps) do
    if matches(map.displayName, query) then
      rows[#rows + 1] = map
    end
  end
  return projection(rows)
end

return SaveEditorMapCatalog
