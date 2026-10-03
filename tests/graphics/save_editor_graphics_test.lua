-- Render and inspect the editor's canonical targets across measured topologies.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local DisplayContext = require("libs.ui.src.DisplayContext")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local Interface = require("app.src.saveeditor.SaveEditorInterface")
local Layout = require("app.src.saveeditor.SaveEditorLayout")
local Renderer = require("app.src.saveeditor.SaveEditorRenderer")
local ValueEditor = require("app.src.saveeditor.SaveEditorValueEditor")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local function realTextMetrics(scope)
  local fieldText = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
  return {
    lineHeight = fieldText.fontDef.lineHeight,
    measure = function(text)
      return fieldText:textWidth(text)
    end,
  }
end

local function fixture(scope, width, height, topology, section, variant)
  section = section or "Progress"
  local view = {
    status = "ready",
    versionId = "heartgold",
    saveId = "TEST-SAVE-42",
    section = section,
    ready = true,
    dirty = variant ~= "clean-status",
    focus = "flag:FLAG_TEST",
    query = "",
    session = {
      playerName = "PLAYER",
      versionId = "HEARTGOLD",
      flags = {},
      location = { fieldX = 32, fieldZ = 48 },
    },
    flagRows = { { name = "FLAG_TEST", displayName = "TEST", id = 1, value = false } },
    flagFilter = "Named",
    flagGroupLabel = "Named",
    scope = {
      id = "section:" .. section,
      epoch = 1,
      kind = "section",
      focusId = "flag:FLAG_TEST",
    },
    textMetrics = realTextMetrics(scope),
  }
  if section == "Player" and variant == "leave" then
    view.modal = "leave"
    view.scope = { id = "modal:leave", epoch = 2, kind = "decision", focusId = "cancel" }
  end
  if section == "Party" then
    view.partyPage = variant or "list"
    if view.partyPage == "list" then
      view.partyCanAdd = true
      view.partyMemberCount = 1
      view.partyRows = {
        { role = "action", targetId = "party:slot:0", label = "Pikachu", value = "Lv. 25" },
      }
    else
      view.partyDirty = true
      view.partyValid = false
      view.partySubpage = "Identity"
      view.partySubpages = { "Identity", "Training", "Stats", "Moves", "Origin" }
      view.partyRows = {
        {
          role = "named choice",
          targetId = "party:field:species",
          id = "species",
          label = "Species",
          value = "PIKACHU",
        },
        {
          role = "integer value",
          targetId = "party:field:personality",
          id = "personality",
          label = "Personality",
          value = 123456789,
        },
        {
          role = "read-only value",
          targetId = "party:readonly:nature",
          id = "nature",
          label = "Nature",
          value = "Hardy",
        },
        { role = "warning", targetId = "party:validation", label = "HP exceeds calculated maximum" },
      }
    end
  elseif section == "Bag" then
    view.bagPocket = "items"
    view.bagPocketLabel = "Items"
    view.bagSelectedItem = "POTION"
    view.bagSelectedQuantity = 2
    view.bagPockets = { { key = "items", label = "Items" } }
    view.bagRows = { { item = "POTION", label = "Potion", quantity = 2 } }
  elseif section == "Location" then
    view.location = {
      mapId = 12,
      symbol = "MAP_AZALEA_ILEX_FOREST_GATEHOUSE",
      displayName = "AZALEA_ILEX_FOREST_GATEHOUSE",
      section = "TEST_SECTION",
      map = { symbol = "MAP_AZALEA_ILEX_FOREST_GATEHOUSE" },
      maps = {
        {
          mapId = 12,
          symbol = "MAP_AZALEA_ILEX_FOREST_GATEHOUSE",
          displayName = "AZALEA_ILEX_FOREST_GATEHOUSE",
          section = "TEST_SECTION",
        },
      },
      generation = 1,
      status = { state = "ready" },
      original = { fieldX = 31, fieldZ = 48 },
      draft = { fieldX = 32, fieldZ = 48 },
      tiles = {
        { fieldX = 32, fieldZ = 48, selectable = true },
        { fieldX = 33, fieldZ = 48, selectable = false, reason = "blocked" },
      },
      cursor = { fieldX = 33, fieldZ = 48 },
      original = { fieldX = 31, fieldZ = 48 },
      draft = { fieldX = 32, fieldZ = 48 },
      scale = 16,
    }
    view.locationNavigation = {
      page = variant == "map-list" and "map-list" or "grid",
      mapId = 12,
      cursor = { fieldX = 33, fieldZ = 48 },
      center = { fieldX = 32, fieldZ = 48 },
      scale = 16,
      mapOffset = 0,
    }
    view.savedLocation = { mapId = 12, fieldX = 31, fieldZ = 48 }
    view.pendingLocation = { mapId = 12, fieldX = 32, fieldZ = 48 }
  end
  local context = DisplayContext.new({
    graphics = love.graphics,
    topologyProvider = function()
      return topology
    end,
  })
  local presentation = ApplicationPresentation.new(Interface.defaults())
  local plan = presentation:resolve(context:measure(width, height), view)
  view.presentation = plan
  view.layout = plan.content.layout
  return view, presentation, plan
end

local function draw(scope, width, height, topology, name, section, variant)
  local graphics = love.graphics
  local view, presentation, plan = fixture(scope, width, height, topology, section, variant)
  local drawnText = {}
  local text = {
    textWidth = function(_, value)
      return view.textMetrics.measure(value)
    end,
    drawTextWithPalette = function(_, value, x, y)
      drawnText[#drawnText + 1] = value
      graphics.print(value, x, y)
    end,
    drawText = function(_, value, x, y)
      drawnText[#drawnText + 1] = value
      graphics.print(value, x, y)
    end,
  }
  local renderer = Renderer.new({ text = text, versionId = "heartgold" })
  local canvas = scope:own(graphics.newCanvas(width, height))
  graphics.setCanvas(canvas)
  graphics.clear(0.94, 0.94, 0.94, 1)
  ApplicationPresentation.draw(graphics, { renderer = renderer }, view, plan)
  graphics.setCanvas()
  local data = scope:own(canvas:newImageData())
  local output =
    io.open(love.filesystem.getSourceBaseDirectory() .. "/tmp/agents/captures/save-editor-" .. name .. ".png", "wb")
  if output then
    output:write(data:encode("png"):getString())
    output:close()
  end

  local layout = Layout.compute(view, plan.content.width, plan.content.height, view.textMetrics)
  local visibleActions = view.modal and { "save", "discard", "cancel" } or { "save", "discard", "back" }
  for _, targetId in ipairs(visibleActions) do
    local target = assert(layout.targets[targetId], name .. " must publish " .. targetId)
    local rect = target.rect
    Assert.isTrue(rect.x >= 0 and rect.y >= 0)
    Assert.isTrue(rect.x + rect.width <= plan.content.width + 0.01, name .. " " .. targetId .. " fits width")
    Assert.isTrue(rect.y + rect.height <= plan.content.height + 0.01, name .. " " .. targetId .. " fits height")
  end
  if view.section == "Progress" then
    local row = assert(layout.targets["flag:FLAG_TEST"], name .. " must expose its flag target")
    local rect = row.rect
    Assert.isTrue(rect.y >= layout.content.y and rect.y + rect.height <= layout.content.y + layout.content.height)
  elseif view.section == "Party" then
    if view.partyPage == "list" then
      Assert.notNil(layout.targets["party:add"], name .. " keeps Add visible")
      Assert.notNil(layout.targets["party:slot:0"], name .. " exposes the occupied slot")
    else
      Assert.notNil(layout.targets["party:field:personality"], name .. " exposes raw identity")
      Assert.notNil(layout.targets["party:readonly:nature"], name .. " explains derived nature")
      Assert.notNil(layout.targets["party:apply"], name .. " exposes the nested Apply decision")
      Assert.notNil(layout.targets["party:cancel"], name .. " exposes the nested Cancel decision")
    end
  elseif view.section == "Location" then
    Assert.notNil(layout.targets["location:map-picker"], name .. " exposes Change Map")
    Assert.isNil(layout.targets["location:zoom-in"], name .. " has no zoom-in target")
    Assert.isNil(layout.targets["location:zoom-out"], name .. " has no zoom-out target")
    Assert.notNil(layout.locationGrid, name .. " publishes the canonical clipped tile grid")
    Assert.isTrue(layout.locationGrid.clip.width > 0 and layout.locationGrid.clip.height > 0)
    Assert.equal(layout.locationGrid.tileSize, 16, name .. " uses the fixed tile scale")
    Assert.isTrue(layout.locationGrid.clip.height >= 16, name .. " keeps at least one complete tile row")
  elseif view.section == "Bag" then
    Assert.notNil(layout.targets["bag:item:POTION"], name .. " exposes the selected stack")
    Assert.notNil(layout.targets["bag:quantity"], name .. " exposes quantity editing")
    Assert.notNil(layout.targets["bag:add"], name .. " exposes Add item")
  end
  local pane
  for _, candidate in ipairs(plan.panes) do
    if candidate.interactive then
      pane = candidate
    end
  end
  Assert.notNil(pane, name .. " must have an interactive pane")
  if name == "dual-touch" then
    Assert.isTrue(pane.placement.frame.y >= 192, "touch auxiliary owns the complete interactive editor")
  end

  local changed = 0
  for y = 0, height - 1, 4 do
    for x = 0, width - 1, 4 do
      local r, g, b = data:getPixel(x, y)
      if r < 0.9 or g < 0.9 or b < 0.9 then
        changed = changed + 1
      end
    end
  end
  Assert.isTrue(changed > 20, name .. " must render visible editor chrome")
  local renderedText = table.concat(drawnText, " ")
  if section == "Player" and variant ~= "leave" then
    Assert.isTrue(renderedText:find("PLAYER"), name .. " shows the player identity")
  end
  if view.section == "Progress" then
    Assert.isNil(layout.targets["group-previous"], name .. " has no flag group controls")
    Assert.isNil(layout.targets["group-next"], name .. " has no flag group controls")
    Assert.isFalse(renderedText:find("FLAG_", 1, true), name .. " displays the stripped flag name")
    Assert.isTrue(renderedText:find("Type to filter flags", 1, true), name .. " shows the visible search hint")
  end
  if view.section == "Location" then
    Assert.isFalse(renderedText:find("MAP_", 1, true), name .. " hides the map symbol prefix")
    Assert.isTrue(
      renderedText:find("AZALEA_ILEX", 1, true) ~= nil,
      name .. " shows the prefix-clean map name within the control bounds"
    )
    if plan.content.width >= 500 then
      Assert.isTrue(
        renderedText:find("X 32", 1, true) ~= nil and renderedText:find("Z 48", 1, true) ~= nil,
        name .. " shows staged coordinates when space permits"
      )
    end
    Assert.isFalse(renderedText:find("Physical only", 1, true), name .. " omits the disclaimer")
    Assert.isFalse(renderedText:find("blocked", 1, true), name .. " omits invalid-cell reason prose")
    Assert.isFalse(renderedText:find("Ready", 1, true), name .. " omits the ready label")
    Assert.isFalse(renderedText:find("Saved", 1, true), name .. " omits Saved/Pending comparison prose")
    Assert.isFalse(renderedText:find("Pending", 1, true), name .. " omits Saved/Pending comparison prose")
  end
  renderer:dispose()
  presentation:dispose()
  return data, renderedText, layout
end

function T.player_shell_renders_headerless_controls_and_a_dirty_leave_decision(scope)
  for _, size in ipairs({ { 256, 192 }, { 640, 480 } }) do
    local topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = size[1], height = size[2] },
      touch = true,
      role = "world",
    })
    local _, renderedText, layout = draw(scope, size[1], size[2], topology, "player-shell", "Player", "leave")
    Assert.isFalse(renderedText:find("Save Editor", 1, true) ~= nil, "shell has no editor title header")
    Assert.isFalse(renderedText:find("TEST-SAVE-42", 1, true) ~= nil, "shell has no save identity header")
    Assert.isFalse(renderedText:find("HEARTGOLD", 1, true) ~= nil, "shell has no version identity header")
    for _, label in ipairs({ "Save", "Discard", "Cancel", "Save changes before leaving?" }) do
      Assert.isTrue(renderedText:find(label, 1, true) ~= nil, "leave decision renders " .. label)
    end
    Assert.isNil(layout.header, "shell publishes no header geometry")
  end
end

function T.dirty_shell_has_no_persistent_status_prose(scope)
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 640, height = 480 },
    touch = true,
    role = "world",
  })
  local dualDisplay = ScreenTopology.dualDisplay(
    { id = "upper", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
    { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
  )
  for _, case in ipairs({
    { topology = singleDisplay, width = 640, height = 480, name = "dirty-status-single", variant = "dirty-status" },
    { topology = dualDisplay, width = 256, height = 384, name = "dirty-status-dual", variant = "dirty-status" },
    { topology = singleDisplay, width = 640, height = 480, name = "clean-status-single", variant = "clean-status" },
    { topology = dualDisplay, width = 256, height = 384, name = "clean-status-dual", variant = "clean-status" },
  }) do
    local _, renderedText = draw(scope, case.width, case.height, case.topology, case.name, "Player", case.variant)
    Assert.isFalse(renderedText:find("Saved", 1, true) ~= nil, case.name .. " has no persistent saved status")
    Assert.isFalse(renderedText:find("Unsaved changes", 1, true) ~= nil, case.name .. " has no persistent dirty status")
  end
end

function T.layouts_render_reachable_actions_on_compact_wide_tall_and_dual_surfaces(scope)
  local compact = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    touch = false,
    role = "world",
  })
  draw(scope, 256, 192, compact, "compact")
  local wide = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 1280, height = 720 },
    touch = false,
    role = "world",
  })
  draw(scope, 1280, 720, wide, "wide")
  local tall = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 360, height = 640 },
    touch = true,
    role = "world",
  })
  draw(scope, 360, 640, tall, "tall")
  local dual = ScreenTopology.dualDisplay(
    { id = "upper", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
    { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
  )
  draw(scope, 256, 384, dual, "dual-touch")
end

function T.party_and_bag_render_on_compact_and_wide_surfaces(scope)
  local compact = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    touch = false,
    role = "world",
  })
  draw(scope, 256, 192, compact, "party-compact", "Party")
  draw(scope, 256, 192, compact, "bag-compact", "Bag")
  local wide = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 1280, height = 720 },
    touch = false,
    role = "world",
  })
  draw(scope, 1280, 720, wide, "party-wide", "Party")
  draw(scope, 1280, 720, wide, "party-raw-wide", "Party", "draft")
  draw(scope, 1280, 720, wide, "bag-wide", "Bag")
end

function T.location_grid_shows_status_and_controls_on_compact_wide_tall_and_dual_touch(scope)
  local compact = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    touch = false,
    role = "world",
  })
  draw(scope, 256, 192, compact, "location-compact", "Location")
  local wide = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 1280, height = 720 },
    touch = false,
    role = "world",
  })
  draw(scope, 1280, 720, wide, "location-wide", "Location")
  local tall = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 360, height = 640 },
    touch = true,
    role = "world",
  })
  draw(scope, 360, 640, tall, "location-tall", "Location")
  local dual = ScreenTopology.dualDisplay(
    { id = "upper", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
    { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
  )
  draw(scope, 256, 384, dual, "location-dual-touch", "Location")
end

function T.location_map_list_labels_fit_button_content_without_losing_map_identity(scope)
  local wide = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 1280, height = 720 },
    touch = false,
    role = "world",
  })
  local _, renderedText, layout = draw(scope, 1280, 720, wide, "location-map-list-labels", "Location", "map-list")
  local targetId = "location:map:12"
  local found
  for _, row in ipairs(layout.navigation) do
    if row.targetId == targetId then
      found = row
      break
    end
  end
  Assert.equal(found and found.label, "AZALEA_ILEX_FOREST_GATEHOUSE", "layout retains the complete map display name")
  Assert.isTrue(renderedText:find("AZALEA_ILEX", 1, true) ~= nil, "the painted map label remains recognizable")
end

function T.name_editor_renders_the_real_naming_snapshot_in_a_neutral_dialog(scope)
  local width, height = 256, 192
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = true,
    role = "world",
  })
  local view = {
    status = "ready",
    versionId = "heartgold",
    saveId = "TEST-SAVE-42",
    section = "Player",
    ready = true,
    dirty = false,
    session = { playerName = "PLAYER", versionId = "HEARTGOLD" },
    scope = { id = "value:player-name:", epoch = 1, kind = "value", focusId = "2:1" },
    textMetrics = realTextMetrics(scope),
    valueEditor = ValueEditor.new({
      kind = "name",
      nameKind = "player",
      maxLength = 7,
      initialText = "A",
      charmap = { A = 1, B = 2 },
      subject = { kind = "player", gender = 0 },
    }):snapshot(),
  }
  local context = DisplayContext.new({
    graphics = love.graphics,
    topologyProvider = function()
      return topology
    end,
  })
  local presentation = ApplicationPresentation.new(Interface.defaults())
  local plan = presentation:resolve(context:measure(width, height), view)
  view.presentation, view.layout = plan, plan.content.layout
  local drawn = {}
  local text = {
    textWidth = function(_, value)
      return #value * 8
    end,
    drawTextWithPalette = function(_, value, x, y)
      drawn[#drawn + 1] = value
      love.graphics.print(value, x, y)
    end,
    drawText = function(_, value, x, y)
      drawn[#drawn + 1] = value
      love.graphics.print(value, x, y)
    end,
  }
  local renderer = Renderer.new({ text = text, versionId = "heartgold" })
  local canvas = scope:own(love.graphics.newCanvas(width, height))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0.94, 0.94, 0.94, 1)
  ApplicationPresentation.draw(love.graphics, { renderer = renderer }, view, plan)
  love.graphics.setCanvas()
  local namingText = table.concat(drawn, " ")
  Assert.isTrue(namingText:find("Upper"), "the real naming page controls are rendered")
  Assert.isTrue(namingText:find("Symbols"), "the naming page selector is rendered")
  Assert.isTrue(namingText:find("OK"), "the naming submit control is rendered")
  Assert.notNil(view.layout.targets["2:1"], "the naming glyph grid has reachable cells")
  Assert.notNil(view.layout.targets.confirm, "name submit remains reachable")
  Assert.notNil(view.layout.targets.cancel, "name cancel remains reachable")
  renderer:dispose()
  presentation:dispose()
end

return GraphicsSmoke.suite(T, { capabilities = { "graphics" } })
