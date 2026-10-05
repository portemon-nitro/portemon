-- Capture the real editor composition with its generated field font and save.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local AcceptanceFixture = require("app.tests.support.SaveEditorAcceptanceFixture")
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
      "mon-icon-page:0",
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
    requestIconPage = ready,
    ensureField = ready,
    ensureLogicalField = ready,
    ensureCell = ready,
  }
end

local function shellQuote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function clickTarget(state, targetId)
  local view = state:view()
  local pane = assert(view.presentation.panes[1], "the editor publishes a pointer pane")
  local layout = assert(view.layout)
  local target = assert(layout.targets[targetId], "the visible editor publishes " .. targetId)
  local rect = target.rect or target.hitRect or target
  local x, y = LayoutGeometry.logicalToHost(assert(pane.placement), rect.x + rect.width / 2, rect.y + rect.height / 2)
  state:mousepressed(x, y, 1, false)
  state:mousereleased(x, y, 1, false)
  return state:view()
end

function T.tests.real_state_uses_the_editor_palette_and_saves_a_capture(scope)
  local fixture = AcceptanceFixture.new()
  local originalGlobal = SaveFs.global
  local state
  local repositoryRoot = love.filesystem.getSourceBaseDirectory()
  local captureDirectory = repositoryRoot .. "/tmp/agents/captures"
  local mkdirStatus = os.execute("mkdir -p -- " .. shellQuote(captureDirectory))
  Assert.isTrue(mkdirStatus == true or mkdirStatus == 0, "the graphics capture directory is available")
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
    local frameRenderer =
      assert(state.renderer._windowRenderer, "ready composition owns one application-frame renderer")
    local frameDraws = {}
    local drawApplicationFrame = frameRenderer.drawApplicationFrame
    frameRenderer.drawApplicationFrame = function(self, box, frameIndex)
      frameDraws[#frameDraws + 1] = frameIndex
      return drawApplicationFrame(self, box, frameIndex)
    end

    local function capture(name, captureWidth, captureHeight)
      state:resize(captureWidth, captureHeight)
      state:update(0)
      if state.controller.section == "Party" then
        for _ = 1, 240 do
          if state.renderer.iconStatus == "ready" then
            break
          end
          state:update(0)
        end
      end
      local view = state:view()
      Assert.equal(view.status, "ready", name .. " uses the production editor state")
      local frameCount = #frameDraws
      local canvas = scope:own(love.graphics.newCanvas(captureWidth, captureHeight))
      love.graphics.setCanvas(canvas)
      love.graphics.clear(0, 0, 0, 0)
      local drawOk, drawFailure = xpcall(function()
        state:draw()
      end, debug.traceback)
      if not drawOk then
        error(drawFailure, 0)
      end
      love.graphics.setCanvas()

      local actual = scope:own(canvas:newImageData())
      local imageData = actual:encode("png")
      local file = assert(
        io.open(captureDirectory .. "/save-editor-production-" .. name .. ".png", "wb"),
        "capture directory must exist for " .. name
      )
      assert(file:write(imageData:getString()))
      assert(file:close())

      local pane = assert(view.presentation.panes[1], name .. " publishes the interactive pane")
      local x, y = LayoutGeometry.logicalToHost(assert(pane.placement), 1, 1)
      local red, green, blue = actual:getPixel(x, y)
      Assert.near(red, state.renderer.skin.background[1], 1 / 255, name .. " uses the editor palette red")
      Assert.near(green, state.renderer.skin.background[2], 1 / 255, name .. " uses the editor palette green")
      Assert.near(blue, state.renderer.skin.background[3], 1 / 255, name .. " uses the editor palette blue")
      local explicitFrames = #(view.layout.listSurfaces or {})
      if view.layout.decisionList ~= nil then
        explicitFrames = explicitFrames + 1
      end
      if view.layout.valueModal ~= nil then
        explicitFrames = explicitFrames + 1
      end
      Assert.equal(
        #frameDraws - frameCount,
        explicitFrames,
        name .. " draws only explicit list/modal frames without a blanket content frame"
      )
      if #frameDraws - frameCount > 0 then
        Assert.equal(frameDraws[#frameDraws], view.session.frameIndex, name .. " uses the staged dialogue frame")
      end
      local content = assert(view.layout.content, name .. " publishes its content bounds")
      local occupied = {}
      for _, target in pairs(view.layout.targets or {}) do
        if target.rect ~= nil then
          occupied[#occupied + 1] = target.rect
        end
      end
      for _, surface in ipairs(view.layout.listSurfaces or {}) do
        occupied[#occupied + 1] = surface
      end
      if view.layout.decisionList ~= nil then
        occupied[#occupied + 1] = view.layout.decisionList.surface
      end
      if view.layout.valueModal ~= nil then
        occupied[#occupied + 1] = view.layout.valueModal
      end
      if view.layout.bagPageText ~= nil then
        occupied[#occupied + 1] = view.layout.bagPageText
      end
      if view.layout.locationStatus ~= nil then
        occupied[#occupied + 1] = view.layout.locationStatus.bounds
      end
      local gapX, gapY = nil, nil
      local probeY = content.y + content.height - 4
      while probeY > content.y + 2 and gapX == nil do
        local probeX = content.x + content.width / 2
        local covered = false
        for _, rect in ipairs(occupied) do
          if probeX >= rect.x and probeX < rect.x + rect.width and probeY >= rect.y and probeY < rect.y + rect.height then
            covered = true
            break
          end
        end
        local grid = view.layout.locationGrid
        if not covered and grid ~= nil then
          local clip = grid.clip
          if probeX >= clip.x and probeX < clip.x + clip.width and probeY >= clip.y and probeY < clip.y + clip.height then
            covered = true
          end
        end
        if not covered then
          gapX, gapY = probeX, probeY
        else
          probeY = probeY - 4
        end
      end
      Assert.notNil(gapX, name .. " keeps ordinary themed page space inside its content")
      local background = state.renderer.skin.background
      local themed = false
      for _, offset in ipairs({ { 0, 0 }, { -3, 0 }, { 3, 0 }, { 0, -3 }, { 0, 3 } }) do
        local sampleX, sampleY =
          LayoutGeometry.logicalToHost(assert(pane.placement), (gapX or 0) + offset[1], (gapY or 0) + offset[2])
        local sampleRed, sampleGreen, sampleBlue = actual:getPixel(math.floor(sampleX), math.floor(sampleY))
        if math.abs(sampleRed - background[1]) < 0.02 and math.abs(sampleGreen - background[2]) < 0.02 and math.abs(sampleBlue - background[3]) < 0.02 then
          themed = true
        end
      end
      Assert.isTrue(themed, name .. " leaves ordinary content on the themed page background")
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
    Assert.isTrue(crowdedBag.layout.bagPage.count > 1, "the crowded pocket has multiple Bag pages")
    clickTarget(state, "bag:page:next")
    local nextPage = capture("crowded-bag-next-page", width, height)
    Assert.equal(
      nextPage.layout.bagPage.index,
      crowdedBag.layout.bagPage.index + 1,
      "Next opens the following Bag page"
    )
    Assert.isTrue(
      assert(nextPage.bagPageRows[1]).item ~= assert(crowdedBag.bagPageRows[1]).item,
      "the next Bag page exposes different item rows"
    )
    for _, targetId in ipairs({ "save", "discard", "back" }) do
      Assert.notNil(nextPage.layout.targets[targetId], "the fixed Bag action remains visible after page navigation")
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
    Assert.equal(#crowdedParty.partyCards, 6, "the production Party view contains six applied members")
    Assert.equal(#crowdedParty.layout.partyGrid, 6, "the production renderer receives all six Party card layouts")
    local iconProvider = assert(state.renderer._iconProvider, "the selected ROM supplied the real Mon icon provider")
    local centeredIcons = 0
    for _, row in ipairs(crowdedParty.layout.rows) do
      if row.iconKey ~= nil then
        local rect = assert(row.iconRect, "Party geometry publishes each icon's content rectangle")
        local iconDimensions = iconProvider:dimensions(row.iconKey)
        local icon = assert(
          state.renderer._icons[row.iconKey],
          "the real provider prepared "
            .. row.iconKey
            .. " with status "
            .. tostring(state.renderer.iconStatus)
            .. " and failure "
            .. tostring(state.renderer.iconFailure)
        )
        Assert.notNil(icon.image, "the selected ROM supplies the Party icon image")
        Assert.notNil(icon.quad, "the selected ROM supplies the Party icon frame")
        Assert.equal(icon.dimensions.width, iconDimensions.width, "the renderer retains provider width")
        Assert.equal(icon.dimensions.height, iconDimensions.height, "the renderer retains provider height")
        Assert.isTrue(rect.width >= iconDimensions.width, "Party icon bounds fit the real icon width")
        Assert.isTrue(rect.height >= iconDimensions.height, "Party icon bounds fit the real icon height")
        centeredIcons = centeredIcons + 1
      end
    end
    Assert.equal(centeredIcons, 6, "all six real Party icons have prepared provider assets and bounded layout")

    state.controller:setSection("Player")
    clickTarget(state, "money")
    state:textinput("999")
    clickTarget(state, "confirm")
    Assert.isTrue(state.session:isDirty(), "the leave dialog follows a real session edit")
    state.controller:setSection("Location")
    state:keypressed("escape")
    state:keyreleased("escape")
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
