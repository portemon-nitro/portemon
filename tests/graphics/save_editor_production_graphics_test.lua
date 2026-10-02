-- Capture the real editor composition with its generated field font and save.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local AcceptanceFixture = require("app.tests.support.SaveEditorAcceptanceFixture")
local MainMenuRenderer = require("app.src.mainmenu.MainMenuRenderer")
local State = require("app.src.saveeditor.SaveEditorState")
local DisplayContext = require("libs.ui.src.DisplayContext")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local SaveFs = require("libs.storage.src.SaveFs")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {
  metadata = {
    capabilities = { "graphics", "rom_dump" },
    derivedAssets = {
      "field-planning",
      "field-runtime",
      "audio-bank:702",
      "audio-bank:709",
      "map-data:7",
      "map-data:48",
      "map-data:34",
      "map-data:47",
      "map-data:60",
      "map-data:67",
      "map-data:33",
      "map-data:63",
      "map:7",
      "map:33",
      "map:63",
      "audio-bank:730",
    },
    tags = { "save-editor", "product", "visual" },
  },
  tests = {},
}

local function readyHost()
  local function ready()
    return true
  end
  return {
    requestMilestone = ready,
    requestField = ready,
    requestLogicalField = ready,
    requestCell = ready,
    ensureField = ready,
    ensureLogicalField = ready,
    ensureCell = ready,
  }
end

local function clickTarget(state, targetId)
  local view = state:view()
  local pane = assert(view.presentation.panes[1], "the editor publishes a pointer pane")
  local layout = assert(view.layout)
  local target = assert(layout.targets[targetId], "the visible editor publishes " .. targetId)
  local rect = target.rect or target.hitRect or target
  local x, y = LayoutGeometry.logicalToHost(
    assert(pane.placement),
    rect.x + rect.width / 2,
    rect.y + rect.height / 2
  )
  state:mousepressed(x, y, 1, false)
  state:mousereleased(x, y, 1, false)
  return state:view()
end

function T.tests.real_state_uses_the_selected_main_menu_skin_and_saves_a_capture(scope)
  local fixture = AcceptanceFixture.new()
  local originalGlobal = SaveFs.global
  local state
  local repositoryRoot = love.filesystem.getSourceBaseDirectory()
  local ok, failure = xpcall(function()
    SaveFs.global = function(backend)
      Assert.isNil(backend, "production editor composition uses the isolated acceptance backend")
      return fixture.saveFs
    end

    local width, height = 256, 192
    local topology = ScreenTopology.oneDisplay({
      id = "editor",
      rect = { x = 0, y = 0, width = width, height = height },
      touch = true,
      role = "world",
    })
    local displayContext = DisplayContext.new({
      graphics = love.graphics,
      topologyProvider = function()
        return topology
      end,
    })
    state = State.new({
      versionId = fixture.versionId,
      saveId = fixture.saveId,
      width = width,
      height = height,
      derivedAssets = readyHost(),
      repositoryRoot = repositoryRoot,
      displayContext = displayContext,
      onResult = function() end,
    })
    state:update(0)
    local view = state:view()
    Assert.equal(view.status, "ready", "the actual editor State opens the selected save")
    Assert.notNil(view.session, "the rendered view comes from a production Session")
    Assert.notNil(state.renderer.text.fontDef, "the renderer uses the selected ROM's generated field font")

    local menu = MainMenuRenderer.new({ text = state.renderer.text, versionId = fixture.versionId })
    local function capture(name, captureWidth, captureHeight)
      state:resize(captureWidth, captureHeight)
      local view = state:view()
      Assert.equal(view.status, "ready", name .. " uses the production editor state")
      local canvas = scope:own(love.graphics.newCanvas(captureWidth, captureHeight))
      love.graphics.setCanvas(canvas)
      love.graphics.clear(0, 0, 0, 0)
      state:draw()
      love.graphics.setCanvas()

      local actual = scope:own(canvas:newImageData())
      local imageData = actual:encode("png")
      local file = assert(
        io.open(repositoryRoot .. "/tmp/agents/captures/save-editor-production-" .. name .. ".png", "wb"),
        "capture directory must exist for " .. name
      )
      assert(file:write(imageData:getString()))
      assert(file:close())

      local pane = assert(view.presentation.panes[1], name .. " publishes the interactive pane")
      local x, y = LayoutGeometry.logicalToHost(assert(pane.placement), 1, 1)
      local red, green, blue = actual:getPixel(x, y)
      Assert.near(red, menu.background[1], 1 / 255, name .. " follows the selected Main Menu skin red")
      Assert.near(green, menu.background[2], 1 / 255, name .. " follows the selected Main Menu skin green")
      Assert.near(blue, menu.background[3], 1 / 255, name .. " follows the selected Main Menu skin blue")
      return view
    end
    local cases = {
      {
        name = "compact-location",
        width = 256,
        height = 192,
        section = "Location",
        topology = ScreenTopology.oneDisplay({
          id = "compact",
          rect = { x = 0, y = 0, width = 256, height = 192 },
          touch = true,
          role = "world",
        }),
      },
      {
        name = "wide-bag",
        width = 1280,
        height = 720,
        section = "Bag",
        topology = ScreenTopology.oneDisplay({
          id = "wide",
          rect = { x = 0, y = 0, width = 1280, height = 720 },
          touch = false,
          role = "world",
        }),
      },
      {
        name = "tall-party",
        width = 720,
        height = 1280,
        section = "Party",
        topology = ScreenTopology.oneDisplay({
          id = "tall",
          rect = { x = 0, y = 0, width = 720, height = 1280 },
          touch = true,
          role = "world",
        }),
      },
      {
        name = "dual-location",
        width = 256,
        height = 384,
        section = "Location",
        topology = ScreenTopology.dualDisplay(
          { id = "world", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
          { id = "auxiliary", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
        ),
      },
    }
    for _, case in ipairs(cases) do
      width, height, topology = case.width, case.height, case.topology
      state.controller:setSection(case.section)
      local captured = capture(case.name, case.width, case.height)
      if case.section == "Location" then
        local hasUnavailableTile = false
        for _, tile in ipairs(assert(captured.location).tiles) do
          hasUnavailableTile = hasUnavailableTile or tile.selectable == false
        end
        Assert.isTrue(hasUnavailableTile, case.name .. " renders nonselectable map cells")
      end
    end

    width, height = 1280, 720
    topology = cases[2].topology
    state:resize(width, height)
    state.controller:setSection("Bag")
    local itemCatalog = assert(state.dependencies.context.itemCatalog)
    local crowdedItems = 0
    for _, key in ipairs(itemCatalog:itemKeys()) do
      local item = itemCatalog:item(key)
      if key ~= "NONE" and item.pocket == "items" and crowdedItems < 16 then
        Assert.isTrue(state.session:setBagQuantity(key, 1).ok, "the production session accepts a valid Bag stack")
        crowdedItems = crowdedItems + 1
      end
    end
    Assert.isTrue(crowdedItems >= 10, "the selected ROM catalog provides a crowded item pocket")
    clickTarget(state, "bag:pocket:items")
    local crowdedBag = capture("crowded-bag", width, height)
    Assert.isTrue(#crowdedBag.bagRows >= 10, "the production Bag view contains a long item list")
    state:wheelmoved(0, -5)
    local scrolledBag = capture("crowded-bag-scrolled", width, height)
    Assert.isTrue(scrolledBag.layout.viewports.bag.offset > 0, "the Bag list scrolls independently of fixed actions")
    for _, targetId in ipairs({ "save", "discard", "back" }) do
      Assert.notNil(scrolledBag.layout.targets[targetId], "the fixed Bag action remains visible after scrolling")
    end

    state.controller:setSection("Party")
    clickTarget(state, "party:add")
    state:textinput("NO MATCHING SPECIES")
    local emptyChoice = capture("no-results", width, height)
    Assert.isTrue(emptyChoice.valueEditor.empty, "the production species picker exposes its no-result state")

    clickTarget(state, "cancel")
    clickTarget(state, "party:add")
    local speciesKey = assert(state.valueEditor:snapshot().selectedKey)
    clickTarget(state, "choice:" .. speciesKey)
    clickTarget(state, "party:subpage:Stats")
    topology = cases[3].topology
    capture("tall-party-stats", 720, 1280)
    topology = cases[1].topology
    clickTarget(state, "party:subpage:Moves")
    capture("compact-party-moves", 256, 192)
    topology = cases[2].topology
    width, height = 1280, 720
    clickTarget(state, "party:subpage:Identity")
    clickTarget(state, "party:field:nickname")
    local keyboard = capture("naming-keyboard", width, height)
    Assert.equal(keyboard.valueEditor.kind, "name", "the naming keyboard comes from the production draft editor")

    clickTarget(state, "cancel")
    clickTarget(state, "party:field:personality")
    state:textinput("NOT A PID")
    local invalidPid = capture("invalid-pid", width, height)
    Assert.equal(invalidPid.valueEditor.parsedValue, nil, "the invalid PID remains visible in the active editor")

    clickTarget(state, "cancel")
    clickTarget(state, "party:discard")

    clickTarget(state, "party:add")
    local selectedSpecies = assert(state:view().valueEditor.options[1].key)
    clickTarget(state, "choice:" .. selectedSpecies)
    clickTarget(state, "party:apply")
    clickTarget(state, "party:back")
    for _ = 2, 6 do
      clickTarget(state, "party:add")
      local species = assert(state:view().valueEditor.options[1].key)
      clickTarget(state, "choice:" .. species)
      clickTarget(state, "party:apply")
      clickTarget(state, "party:back")
    end
    local crowdedParty = capture("crowded-party", width, height)
    Assert.equal(#crowdedParty.partyRows, 6, "the production Party view contains six applied members")

    state.controller:setSection("Player")
    clickTarget(state, "money")
    state:textinput("999")
    clickTarget(state, "confirm")
    Assert.isTrue(state.session:isDirty(), "the leave dialog follows a real session edit")
    state.controller:setSection("Location")
    state:keypressed("escape")
    local leaveDialog = capture("leave-dialog", width, height)
    Assert.equal(leaveDialog.modal, "leave", "the leave confirmation is the production modal")
  end, debug.traceback)

  if state then
    pcall(function()
      state:dispose()
    end)
  end
  SaveFs.global = originalGlobal
  fixture.cleanup()
  if not ok then
    error(failure, 0)
  end
end

local suite = GraphicsSmoke.suite(T.tests)
suite.metadata = T.metadata
return suite
