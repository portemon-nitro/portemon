-- Render and inspect the editor's canonical targets across measured topologies.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local DisplayContext = require("libs.ui.src.DisplayContext")
local Interface = require("app.src.saveeditor.SaveEditorInterface")
local Layout = require("app.src.saveeditor.SaveEditorLayout")
local Renderer = require("app.src.saveeditor.SaveEditorRenderer")
local ValueEditor = require("app.src.saveeditor.SaveEditorValueEditor")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local function fixture(width, height, topology)
  local view = {
    status = "ready",
    versionId = "heartgold",
    saveId = "TEST-SAVE-42",
    section = "Progress",
    ready = true,
    dirty = true,
    focus = "flag:FLAG_TEST",
    session = { playerName = "PLAYER", versionId = "HEARTGOLD", flags = {} },
    flagRows = { { name = "FLAG_TEST", id = 1, value = false } },
    flagFilter = "Named",
    flagGroupLabel = "Named",
  }
  local context = DisplayContext.new({
    graphics = love.graphics,
    topologyProvider = function() return topology end,
  })
  local presentation = ApplicationPresentation.new(Interface.defaults())
  local plan = presentation:resolve(context:measure(width, height), view)
  view.presentation = plan
  view.layout = plan.content.layout
  return view, presentation, plan
end

local function draw(scope, width, height, topology, name)
  local graphics = love.graphics
  local view, presentation, plan = fixture(width, height, topology)
  local drawnText = {}
  local text = { drawText = function(_, value, x, y)
    drawnText[#drawnText + 1] = value
    graphics.print(value, x, y)
  end }
  local renderer = Renderer.new({ text = text })
  local canvas = scope:own(graphics.newCanvas(width, height))
  graphics.setCanvas(canvas)
  graphics.clear(0.94, 0.94, 0.94, 1)
  ApplicationPresentation.draw(graphics, { renderer = renderer }, view, plan)
  graphics.setCanvas()
  local data = scope:own(canvas:newImageData())
  local output = io.open(
    love.filesystem.getSourceBaseDirectory() .. "/tmp/agents/captures/save-editor-" .. name .. ".png",
    "wb"
  )
  if output then
    output:write(data:encode("png"):getString())
    output:close()
  end

  local layout = Layout.compute(view, plan.content.width, plan.content.height)
  for _, targetId in ipairs({ "save", "discard", "back" }) do
    local target = assert(layout.targets[targetId], name .. " must publish " .. targetId)
    Assert.isTrue(target.x >= 0 and target.y >= 0)
    Assert.isTrue(target.x + target.width <= plan.content.width + 0.01, name .. " " .. targetId .. " fits width")
    Assert.isTrue(target.y + target.height <= plan.content.height + 0.01, name .. " " .. targetId .. " fits height")
  end
  local row = assert(layout.targets["flag:FLAG_TEST"], name .. " must expose its flag target")
  Assert.isTrue(row.y >= layout.content.y and row.y + row.height <= layout.content.y + layout.content.height)
  local pane
  for _, candidate in ipairs(plan.panes) do if candidate.interactive then pane = candidate end end
  Assert.notNil(pane, name .. " must have an interactive pane")
  if name == "dual-touch" then
    Assert.isTrue(pane.placement.frame.y >= 192, "touch auxiliary owns the complete interactive editor")
  end

  local changed = 0
  for y = 0, height - 1, 4 do
    for x = 0, width - 1, 4 do
      local r, g, b = data:getPixel(x, y)
      if r < 0.9 or g < 0.9 or b < 0.9 then changed = changed + 1 end
    end
  end
  Assert.isTrue(changed > 20, name .. " must render visible editor chrome")
  local renderedText = table.concat(drawnText, " ")
  Assert.isTrue(renderedText:find("TEST%-SAVE%-42"), name .. " shows the selected save identity")
  Assert.isTrue(renderedText:find("PLAYER"), name .. " shows the player identity")
  Assert.isTrue(renderedText:find("HEARTGOLD"), name .. " shows the game version")
  Assert.isTrue(renderedText:find("Unsaved changes"), name .. " shows the current dirty state in the footer")
  for _, targetId in ipairs({ "group-previous", "group-next" }) do
    local target = assert(layout.targets[targetId], name .. " exposes touch browsing for flag groups")
    Assert.equal(
      Layout.hitTest(layout, view, target.x + target.width / 2, target.y + target.height / 2),
      targetId,
      name .. " maps group browse touch targets"
    )
  end
  renderer:dispose()
  presentation:dispose()
  return data
end

function T.layouts_render_reachable_actions_on_compact_wide_tall_and_dual_surfaces(scope)
  local compact = ScreenTopology.oneDisplay({
    id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world",
  })
  draw(scope, 256, 192, compact, "compact")
  local wide = ScreenTopology.oneDisplay({
    id = "main", rect = { x = 0, y = 0, width = 1280, height = 720 }, touch = false, role = "world",
  })
  draw(scope, 1280, 720, wide, "wide")
  local tall = ScreenTopology.oneDisplay({
    id = "main", rect = { x = 0, y = 0, width = 360, height = 640 }, touch = true, role = "world",
  })
  draw(scope, 360, 640, tall, "tall")
  local dual = ScreenTopology.dualDisplay(
    { id = "upper", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
    { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
  )
  draw(scope, 256, 384, dual, "dual-touch")
end

function T.name_editor_renders_the_real_naming_snapshot_in_a_neutral_dialog(scope)
  local width, height = 256, 192
  local topology = ScreenTopology.oneDisplay({
    id = "main", rect = { x = 0, y = 0, width = width, height = height }, touch = true, role = "world",
  })
  local view = {
    status = "ready",
    versionId = "heartgold",
    saveId = "TEST-SAVE-42",
    section = "Player",
    ready = true,
    dirty = false,
    session = { playerName = "PLAYER", versionId = "HEARTGOLD" },
    valueEditor = ValueEditor.new({
      kind = "name",
      nameKind = "player",
      maxLength = 7,
      initialText = "A",
      charmap = { A = 1, B = 2 },
      subject = { kind = "player", gender = 0 },
    }):snapshot(),
  }
  local context = DisplayContext.new({ graphics = love.graphics, topologyProvider = function() return topology end })
  local presentation = ApplicationPresentation.new(Interface.defaults())
  local plan = presentation:resolve(context:measure(width, height), view)
  view.presentation, view.layout = plan, plan.content.layout
  local drawn = {}
  local text = { drawText = function(_, value, x, y)
    drawn[#drawn + 1] = value
    love.graphics.print(value, x, y)
  end }
  local renderer = Renderer.new({ text = text })
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
