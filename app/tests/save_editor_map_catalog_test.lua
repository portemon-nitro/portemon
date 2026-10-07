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
  Assert.deepEqual(
    {
      groupRows[1].row.mapSectionNativeId,
      groupRows[2].row.mapSectionNativeId,
      groupRows[3].row.mapSectionNativeId,
    },
    { 77, 5, 9 },
    "groups sort by display label, then source identity for duplicate labels"
  )

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

return T
