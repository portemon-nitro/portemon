-- Keeps editor host placement aligned with physical pixels and authored bounds.

local Assert = require("tests.support.Assert")
local Interface = require("app.src.saveeditor.SaveEditorInterface")

local T = { tests = {} }

local function context(bounds, pixelRatio, configuration, secondaryBounds)
  local surface = { id = "primary", touch = secondaryBounds == nil }
  return {
    configuration = configuration,
    measurement = { pixelRatio = pixelRatio },
    primary = { surface = surface, usableBounds = bounds },
    secondary = secondaryBounds and {
      surface = { id = "secondary", touch = true },
      usableBounds = secondaryBounds,
    } or nil,
  }
end

local function view()
  return {
    status = "opening",
    message = "Preparing save editor",
    section = "Player",
    scope = { id = "section:Player", epoch = 0 },
    textMetrics = {
      lineHeight = 12,
      measure = function(text)
        return #text * 6
      end,
    },
  }
end

local function mapListView()
  local maps, rowTargets, indexByTarget = {}, {}, {}
  for index = 1, 30 do
    maps[index] = {
      mapId = index,
      symbol = "MAP_TEST_" .. index,
      displayName = "TEST_" .. index,
      section = "TEST_SECTION",
    }
    rowTargets[index] = "location:map:" .. index
    indexByTarget[rowTargets[index]] = index
  end
  local location = {
    mapListId = "location:group:1",
    breadcrumb = "TEST_SECTION",
    maps = maps,
    mapRowTargets = rowTargets,
    mapIndexByTarget = indexByTarget,
    generation = 1,
    status = { state = "ready" },
    mapModel = {
      revision = 1,
      queryRevision = 0,
      pending = false,
      count = #rowTargets,
      rowTargets = rowTargets,
      indexByTarget = indexByTarget,
      idAt = function(index)
        return rowTargets[index]
      end,
      indexOf = function(targetId)
        return indexByTarget[targetId]
      end,
      rowAt = function(index)
        return maps[index]
      end,
    },
  }
  local result = view()
  result.status = "ready"
  result.section = "Location"
  result.scope = { id = "section:Location:map-list", epoch = 0, kind = "section", focusId = "list:location:group:1" }
  result.query = ""
  result.location = location
  result.locationNavigation = {
    page = "group",
    groupId = "location:group:1",
    contentFocus = "map-list",
    mapId = 1,
    mapOffset = 0,
  }
  return result
end

function T.tests.wide_editor_uses_one_integer_framebuffer_scale_with_the_measured_pixel_ratio()
  local plan = Interface.resolve(context({ x = 0, y = 0, width = 1280, height = 720 }, 2, "wide"), view())
  local placement = plan.panes[1].placement

  Assert.equal(placement.pixelScale, 3, "physical density selects one preferred integer framebuffer scale")
  Assert.equal(placement.pixelRatio, 2, "the placement retains the measured host pixel ratio")
  Assert.equal(placement.scale, 1.5, "host scale is framebuffer scale divided by pixel ratio")
  Assert.equal(plan.content.width, 1280 / 1.5, "the logical canvas covers the full host width")
  Assert.equal(plan.content.height, 720 / 1.5, "the logical canvas covers the full host height")
end

function T.tests.tiny_editor_bounds_use_a_native_pixel_viewport()
  local plan = Interface.resolve(context({ x = 0, y = 0, width = 200, height = 150 }, 1, "nativeLike"), view())
  local placement = plan.panes[1].placement

  local viewSnapshot = view()
  local section = assert(plan.content.layout.targets["section:Player"], "the visible section remains a hit target")
  local sectionRect = assert(section.rect, "the published section target carries its visible rectangle")
  local mapped = plan.mapInput({
    type = "pointer_down",
    x = sectionRect.x + sectionRect.width / 2,
    y = sectionRect.y + sectionRect.height / 2,
  }, viewSnapshot, plan)
  Assert.equal(mapped.targetId, "section:Player", "the visible section remains pointer reachable")
  Assert.equal(placement.pixelScale, 1, "the editor keeps native authored pixels")
  Assert.equal(placement.scale, 1, "unit density maps each logical pixel to one host pixel")
  Assert.equal(plan.content.width, 200, "the editor reflows to the visible host width")
  Assert.equal(plan.content.height, 150, "the editor reflows to the visible host height")
end

function T.tests.undersized_dual_display_omits_the_context_preview()
  for _, pixelRatio in ipairs({ 1, 2 }) do
    local previewBounds = { x = 0, y = 0, width = 200 / pixelRatio, height = 150 / pixelRatio }
    local editorBounds = { x = 300 / pixelRatio, y = 0, width = 256 / pixelRatio, height = 192 / pixelRatio }
    local plan = Interface.resolve(context(previewBounds, pixelRatio, "dualDisplay", editorBounds), view())
    local editorPane = assert(plan.panes[1], "the touch surface keeps the interactive editor")
    Assert.equal(editorPane.id, "editor")
    Assert.isTrue(editorPane.interactive, "the touch surface remains the authoritative editor")
    Assert.equal(editorPane.placement.pixelScale, 1, "the editor uses native pixels")
    Assert.equal(editorPane.placement.pixelRatio, pixelRatio, "the editor preserves the measured density")
    Assert.equal(#plan.panes, 1, "an undersized primary has no context preview pane")
    Assert.isNil(plan.panes[2], "no fractional context-only placement is published")

    local editorView = view()
    local section = assert(plan.content.layout.targets["section:Player"], "the editor keeps a visible section action")
    local rect = assert(section.rect)
    local hit = plan.mapInput({
      type = "pointer_down",
      x = rect.x + rect.width / 2,
      y = rect.y + rect.height / 2,
    }, editorView, plan)
    Assert.equal(hit.targetId, "section:Player", "the visible action remains reachable on the touch display")
    Assert.isNil(
      plan.mapInput({ type = "pointer_down", x = plan.content.width + 1, y = rect.y }, editorView, plan).targetId,
      "the editor publishes no offscreen hit target"
    )
  end
end

function T.tests.small_map_list_only_hits_materialized_rows_and_reveals_a_distant_row()
  local editorView = mapListView()
  local editorContext = context({ x = 0, y = 0, width = 200, height = 150 }, 1, "nativeLike")
  local plan = Interface.resolve(editorContext, editorView)
  local layout = plan.content.layout
  local viewport = assert(layout.viewports["location:group:1"], "the map list keeps its scroll viewport")
  local list = assert(layout.lists["location:group:1"], "the map list keeps its logical row order")
  local lastTargetId = list.rowTargets[#list.rowTargets]
  Assert.isTrue(viewport.lastIndex < #list.rowTargets, "a map row remains below the visible fold")
  Assert.isNil(layout.targets[lastTargetId], "the offscreen map row has no hit target")

  local visibleTargetId = list.rowTargets[viewport.firstIndex]
  local visibleTarget = assert(layout.targets[visibleTargetId], "a visible map row has a hit target")
  local visibleRect = assert(visibleTarget.rect)
  local visibleHit = plan.mapInput({
    type = "pointer_down",
    x = visibleRect.x + visibleRect.width / 2,
    y = visibleRect.y + visibleRect.height / 2,
  }, editorView, plan)
  Assert.equal(visibleHit.targetId, visibleTargetId, "the visible map row remains pointer reachable")
  Assert.isNil(
    plan.mapInput({
      type = "pointer_down",
      x = viewport.clip.x + 1,
      y = viewport.clip.y + viewport.clip.height + 1,
    }, editorView, plan).targetId,
    "a point below the list clip cannot activate an offscreen map row"
  )

  editorView.locationNavigation.mapOffset = viewport.contentExtent
  local revealedPlan = Interface.resolve(editorContext, editorView)
  local revealedLayout = revealedPlan.content.layout
  local revealedTarget = assert(revealedLayout.targets[lastTargetId], "scrolling materializes the distant row")
  local revealedRect = assert(revealedTarget.rect)
  local revealedHit = revealedPlan.mapInput({
    type = "pointer_down",
    x = revealedRect.x + revealedRect.width / 2,
    y = revealedRect.y + revealedRect.height / 2,
  }, editorView, revealedPlan)
  Assert.equal(revealedHit.targetId, lastTargetId, "the revealed map row becomes pointer reachable")
end

return T
