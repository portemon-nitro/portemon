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
  local leftIdentity = left.mapSectionNativeId or left.mapId
  local rightIdentity = right.mapSectionNativeId or right.mapId
  return leftIdentity < rightIdentity
end

---@param summaries SaveEditorMapSummary[] immutable structural map summaries
---@return SaveEditorMapCatalog
function SaveEditorMapCatalog.new(summaries)
  assert(type(summaries) == "table", "map summaries are required")
  local groups, groupById = {}, {}
  local groupIdByMap = {}
  local seenMapIds = {}
  for _, summary in ipairs(summaries) do
    assert(type(summary.mapId) == "number" and summary.mapId % 1 == 0, "map summary needs its source map ID")
    assert(not seenMapIds[summary.mapId], "a structural map summary appears once")
    seenMapIds[summary.mapId] = true
    assert(
      type(summary.mapSectionNativeId) == "number" and summary.mapSectionNativeId % 1 == 0,
      "map summary needs its source map-section identity"
    )
    assert(type(summary.section) == "string" and summary.section ~= "", "map summary needs its section label")
    assert(type(summary.symbol) == "string" and summary.symbol ~= "", "map summary needs its source symbol")
    assert(type(summary.displayName) == "string" and summary.displayName ~= "", "map summary needs its display name")
    local groupId = "location:group:" .. summary.mapSectionNativeId
    local group = groupById[groupId]
    if group == nil then
      group = {
        targetId = groupId,
        kind = "group",
        groupId = groupId,
        mapSectionNativeId = summary.mapSectionNativeId,
        section = summary.section,
        displayName = summary.section,
        maps = {},
      }
      groupById[groupId] = group
      groups[#groups + 1] = group
    else
      assert(group.section == summary.section, "one source section identity has one display label")
    end
    group.maps[#group.maps + 1] = {
      targetId = "location:map:" .. summary.mapId,
      kind = "map",
      mapId = summary.mapId,
      symbol = summary.symbol,
      section = summary.section,
      displayName = summary.displayName,
    }
    groupIdByMap[summary.mapId] = groupId
  end
  table.sort(groups, rowOrder)
  for _, group in ipairs(groups) do
    table.sort(group.maps, rowOrder)
  end
  return setmetatable({
    groupRows = groups,
    groupById = groupById,
    groupIdByMap = groupIdByMap,
  }, SaveEditorMapCatalog)
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
