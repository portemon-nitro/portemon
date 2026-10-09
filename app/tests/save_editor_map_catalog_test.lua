-- Source sections project into stable map groups and indexed map leaves.

local Assert = require("tests.support.Assert")

local T = { tests = {} }

local function fixtureSummaries()
  return {
    { mapId = 41, symbol = "MAP_BETA", section = "Shared", mapSectionNativeId = 5, displayName = "BETA" },
    { mapId = 9, symbol = "MAP_ALPHA", section = "Shared", mapSectionNativeId = 5, displayName = "ALPHA" },
    { mapId = 6, symbol = "MAP_ALPHA", section = "Shared", mapSectionNativeId = 9, displayName = "ALPHA" },
    { mapId = 72, symbol = "MAP_CUSTOM", section = "Custom source", mapSectionNativeId = 77, displayName = "CUSTOM" },
  }
end

local function projectedRows(projection)
  local rows = {}
  for index = 1, projection.count do
    rows[index] = {
      id = assert(projection.idAt(index), "an in-range catalog row has a stable ID"),
      row = assert(projection.rowAt(index), "an in-range catalog row has a payload"),
    }
  end
  return rows
end

function T.tests.source_sections_keep_complete_membership_and_filter_through_child_labels()
  local loaded, Catalog = pcall(require, "app.src.saveeditor.SaveEditorMapCatalog")
  Assert.isTrue(loaded, "the source map catalog groups every map by source section identity")

  local catalog = Catalog.new(fixtureSummaries())
  local groups = catalog:groups("")
  local groupRows = projectedRows(groups)
  Assert.equal(#groupRows, 3, "distinct source sections remain distinct even when their labels match")
  Assert.deepEqual({
    groupRows[1].row.mapSectionNativeId,
    groupRows[2].row.mapSectionNativeId,
    groupRows[3].row.mapSectionNativeId,
  }, { 77, 5, 9 }, "groups sort by display label, then source identity for duplicate labels")

  local groupIdsByNativeId = {}
  local membersById = {}
  for _, entry in ipairs(groupRows) do
    local nativeId = entry.row.mapSectionNativeId
    Assert.notNil(nativeId, "each group retains its source section identity")
    Assert.isNil(groupIdsByNativeId[nativeId], "one source section has one root row")
    groupIdsByNativeId[nativeId] = entry.id

    local leaves = projectedRows(catalog:maps(entry.id, ""))
    membersById[nativeId] = {}
    local leafMapIds = {}
    for _, leaf in ipairs(leaves) do
      local mapId = assert(leaf.row.mapId, "each leaf retains its stable map identity")
      Assert.isNil(membersById[nativeId][mapId], "a map appears once in its source group")
      membersById[nativeId][mapId] = true
      leafMapIds[#leafMapIds + 1] = mapId
    end
    if nativeId == 5 then
      Assert.deepEqual(leafMapIds, { 9, 41 }, "leaves sort by their existing display labels")
    end
  end

  Assert.deepEqual(membersById[5], { [9] = true, [41] = true }, "the first source section owns both leaves")
  Assert.deepEqual(membersById[9], { [6] = true }, "duplicate labels do not merge source sections")
  Assert.deepEqual(membersById[77], { [72] = true }, "custom source sections remain their own group")

  local childMatchedGroups = projectedRows(catalog:groups("BETA"))
  Assert.equal(#childMatchedGroups, 1, "a root query can match a child map label")
  Assert.equal(
    childMatchedGroups[1].id,
    groupIdsByNativeId[5],
    "child-only matches retain the source section's stable group identity"
  )
  local childMatchedMaps = projectedRows(catalog:maps(childMatchedGroups[1].id, "BETA"))
  Assert.equal(#childMatchedMaps, 1, "the carried child query filters the entered group")
  Assert.equal(childMatchedMaps[1].row.mapId, 41, "the matching leaf keeps its source map ID")
  Assert.equal(catalog:maps(groupIdsByNativeId[5], "no match").count, 0, "empty leaf results are valid")
end

function T.tests.route_and_battle_frontier_prefixes_share_only_their_explicit_groups()
  local Catalog = require("app.src.saveeditor.SaveEditorMapCatalog")
  local summaries = {
    { mapId = 10, symbol = "MAP_ROUTE_29", section = "Route 29", mapSectionNativeId = 3, displayName = "ROUTE 29" },
    { mapId = 11, symbol = "MAP_ROUTE_30", section = "Route 30", mapSectionNativeId = 4, displayName = "ROUTE 30" },
    { mapId = 12, symbol = "MAP_BATTLE_FRONTIER_GATE", section = "Gate", mapSectionNativeId = 7, displayName = "GATE" },
    { mapId = 13, symbol = "MAP_BATTLE_FRONTIER_PLAZA", section = "Plaza", mapSectionNativeId = 8, displayName = "PLAZA" },
    { mapId = 14, symbol = "MAP_ROUTEHOUSE", section = "Route House", mapSectionNativeId = 12, displayName = "ROUTE HOUSE" },
    { mapId = 15, symbol = "MAP_ORDINARY", section = "Ordinary", mapSectionNativeId = 9, displayName = "ORDINARY" },
    { mapId = 16, symbol = "MAP_BATTLE_FRONTIER", section = "Frontier", mapSectionNativeId = 13, displayName = "FRONTIER" },
    { mapId = 17, symbol = "MAP_BATTLE_FRONTIERS", section = "Frontiers", mapSectionNativeId = 14, displayName = "FRONTIERS" },
    { mapId = 18, symbol = "MAP_KANTO_ROUTE_1", section = "Kanto Route 1", mapSectionNativeId = 15, displayName = "KANTO ROUTE 1" },
    { mapId = 19, symbol = "MAP_EAST_ROUTE_2", section = "East Route 2", mapSectionNativeId = 16, displayName = "EAST ROUTE 2" },
    { mapId = 20, symbol = "MAP_SEVII_ROUTE_3", section = "Sevii Route 3", mapSectionNativeId = 17, displayName = "SEVII ROUTE 3" },
    { mapId = 21, symbol = "MAP_ROUTER", section = "Router", mapSectionNativeId = 18, displayName = "ROUTER" },
    { mapId = 22, symbol = "MAP_SOMETHING_ROUTEHOUSE", section = "Routehouse", mapSectionNativeId = 19, displayName = "ROUTEHOUSE" },
  }
  local task = Catalog.newTask(summaries)
  local complete = false
  while not complete do
    local _, isComplete = task:advance(2)
    complete = isComplete
  end
  local catalog = task:take()
  local expectedGroupByMap = {
    [10] = "location:group:routes",
    [11] = "location:group:routes",
    [12] = "location:group:battle-frontier",
    [13] = "location:group:battle-frontier",
    [14] = "location:group:12",
    [15] = "location:group:9",
    [16] = "location:group:battle-frontier",
    [17] = "location:group:14",
    [18] = "location:group:routes",
    [19] = "location:group:routes",
    [20] = "location:group:routes",
    [21] = "location:group:18",
    [22] = "location:group:19",
  }
  local occurrences = {}
  local groups = projectedRows(catalog:groups(""))
  local ids = {}
  for _, entry in ipairs(groups) do
    Assert.isNil(ids[entry.id], "native and synthetic groups have distinct stable identities")
    ids[entry.id] = true
    local leaves = projectedRows(catalog:maps(entry.id, ""))
    for _, leaf in ipairs(leaves) do
      occurrences[leaf.row.mapId] = (occurrences[leaf.row.mapId] or 0) + 1
      Assert.equal(catalog:groupForMap(leaf.row.mapId), entry.id, "group lookup follows each leaf identity")
      Assert.equal(entry.id, expectedGroupByMap[leaf.row.mapId], "only the declared source-symbol prefixes override grouping")
    end
  end
  Assert.equal(#groups, 7, "synthetic categories coexist with every native fallback group")
  Assert.equal(catalog.groupById["location:group:routes"].displayName, "ROUTES")
  Assert.equal(catalog.groupById["location:group:routes"].section, "ROUTES")
  Assert.equal(catalog.groupById["location:group:battle-frontier"].displayName, "BATTLE FRONTIER")
  Assert.equal(catalog.groupById["location:group:battle-frontier"].section, "BATTLE FRONTIER")
  for _, summary in ipairs(summaries) do
    Assert.equal(occurrences[summary.mapId], 1, "each source map appears in exactly one group")
  end
  local filtered = projectedRows(catalog:maps("location:group:routes", "30"))
  Assert.equal(#filtered, 1, "synthetic groups retain child-label filtering")
  Assert.equal(filtered[1].row.mapId, 11, "filter results preserve the source map identity")
  local nestedRouteMatches = projectedRows(catalog:maps("location:group:routes", "route"))
  Assert.equal(#nestedRouteMatches, 5, "every accepted route symbol remains available through the group filter")
  Assert.deepEqual(
    { nestedRouteMatches[1].row.mapId, nestedRouteMatches[2].row.mapId, nestedRouteMatches[3].row.mapId, nestedRouteMatches[4].row.mapId, nestedRouteMatches[5].row.mapId },
    { 19, 18, 10, 11, 20 },
    "route filtering returns each matching source leaf in deterministic display order"
  )
end

function T.tests.incremental_catalog_preparation_limits_summary_reads_per_advance()
  local Catalog = require("app.src.saveeditor.SaveEditorMapCatalog")
  local reads = 0
  local summaries = {}
  for index = 1, 7 do
    summaries[index] = setmetatable({
      mapId = index,
      symbol = "MAP_" .. index,
      section = "Section " .. (index % 2),
      mapSectionNativeId = index % 2,
      displayName = "Map " .. (8 - index),
    }, {
      __index = function(_, key)
        if key == "mapId" then
          reads = reads + 1
        end
      end,
    })
  end

  local task = Catalog.newTask(summaries)
  Assert.equal(reads, 0, "starting catalog preparation does not scan the map inventory")
  local completed = false
  while not completed do
    local before = reads
    local used
    used, completed = task:advance(2)
    Assert.isTrue(used <= 2, "one catalog update charges no more than its row budget")
    Assert.isTrue(reads - before <= 2, "one catalog update reads no more than its row budget")
  end

  local catalog = task:take()
  Assert.equal(catalog:groups("").count, 2, "the bounded build publishes the complete hierarchy")
  local maps = projectedRows(catalog:maps("location:group:1", ""))
  Assert.equal(#maps, 4, "the built group preserves all leaves")
  Assert.equal(maps[1].row.mapId, 7, "incremental merge passes publish the sorted first leaf")
  Assert.equal(maps[4].row.mapId, 1, "incremental merge passes publish the sorted last leaf")
end

return T
