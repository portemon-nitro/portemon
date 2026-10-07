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
  local function pressRelease()
    local view = state:view()
    local pane = assert(view.presentation.panes[1], "the editor publishes a pointer pane")
    local layout = assert(view.layout)
    local target = assert(layout.targets[targetId], "the visible editor publishes " .. targetId)
    local rect = target.rect or target.hitRect or target
    local x, y = LayoutGeometry.logicalToHost(assert(pane.placement), rect.x + rect.width / 2, rect.y + rect.height / 2)
    state:mousepressed(x, y, 1, false)
    state:mousereleased(x, y, 1, false)
  end
  pressRelease()
  if targetId:match("^choice:") ~= nil then
    if state.controller.focus == targetId and state:view().valueEditor ~= nil then
      pressRelease()
    end
  end
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
      frameDraws[#frameDraws + 1] =
        { x = box.x, y = box.y, width = box.width, height = box.height, frameIndex = frameIndex }
      return drawApplicationFrame(self, box, frameIndex)
    end

    local function capture(name, captureWidth, captureHeight)
      state:resize(captureWidth, captureHeight)
      state:update(0)
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
      local scrimCount = 0
      for _, layer in ipairs(view.modalLayers or {}) do
        if layer.kind == "leave" or layer.kind == "bag-item" or layer.kind == "bag-remove" or layer.kind == "move" then
          scrimCount = scrimCount + 1
        end
      end
      if view.valueEditor ~= nil then
        scrimCount = scrimCount + 1
      end
      local backgroundScale = (1 - 0.42) ^ scrimCount
      local backgroundLabel = scrimCount == 0 and "uses the editor palette" or "uses the modal-dimmed editor palette"
      local tolerance = scrimCount == 0 and 1 / 255 or 2 / 255
      Assert.near(
        red,
        state.renderer.skin.background[1] * backgroundScale,
        tolerance,
        name .. " " .. backgroundLabel .. " red"
      )
      Assert.near(
        green,
        state.renderer.skin.background[2] * backgroundScale,
        tolerance,
        name .. " " .. backgroundLabel .. " green"
      )
      Assert.near(
        blue,
        state.renderer.skin.background[3] * backgroundScale,
        tolerance,
        name .. " " .. backgroundLabel .. " blue"
      )
      local explicit = {}
      for _, surface in ipairs(view.layout.listSurfaces or {}) do
        explicit[#explicit + 1] = surface
      end
      if view.layout.decisionList ~= nil then
        explicit[#explicit + 1] = view.layout.decisionList.surface
      end
      if view.layout.valueModal ~= nil then
        explicit[#explicit + 1] = view.layout.valueModal
      end
      for index = frameCount + 1, #frameDraws do
        local frame = frameDraws[index]
        local owned = false
        for _, surface in ipairs(explicit) do
          local frameWidth = math.floor(surface.width / 8) * 8
          local frameHeight = math.floor(surface.height / 8) * 8
          local frameX = math.floor(surface.x + (surface.width - frameWidth) / 2 + 0.5)
          local frameY = math.floor(surface.y + (surface.height - frameHeight) / 2 + 0.5)
          if frame.x == frameX and frame.y == frameY and frame.width == frameWidth and frame.height == frameHeight then
            owned = true
          end
        end
        Assert.isTrue(owned, name .. " draws only explicit list/modal frames without a blanket content frame")
      end
      if #frameDraws - frameCount > 0 then
        Assert.equal(
          frameDraws[#frameDraws].frameIndex,
          view.session.frameIndex,
          name .. " uses the staged dialogue frame"
        )
      end
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
    -- Location opens on the map list, so grid captures first narrow the
    -- list to the staged map through the real filter path and then enter
    -- coordinate selection through the real map-row activation path.
    -- Only the staged map's assets are provisioned for these captures.
    local function enterStagedGrid(context)
      state:keypressed("delete")
      state:keyreleased("delete")
      local stagedMapId = assert(assert(state.session, context .. " stages a session"):snapshot().location).mapId
      local stagedName
      local summaries = assert(state.locationService, context .. " owns its location service"):mapSummaries()
      for _, summary in ipairs(summaries) do
        if summary.mapId == stagedMapId then
          stagedName = assert(summary.displayName, context .. " names the staged map")
        end
      end
      state:textinput(assert(stagedName, context .. " catalogs the staged map"))
      local stagedMapTarget = "location:map:" .. stagedMapId
      local activated
      for _ = 1, 120 do
        if assert(state:view().layout).targets[stagedMapTarget] ~= nil then
          activated = stagedMapTarget
          break
        end
        state:update(0)
      end
      assert(activated, context .. " eventually publishes the staged map row")
      clickTarget(state, activated)
      state:update(0)
      for _ = 1, 120 do
        local snapshot = assert(state.locationService, context .. " owns its location service"):snapshot()
        local classified = false
        for _, tile in ipairs(snapshot.tiles) do
          if tile.selectable == false then
            classified = true
            break
          end
        end
        if classified then
          break
        end
        state:update(0)
      end
    end
    for _, case in ipairs(cases) do
      width, height, topology = case.width, case.height, case.topology
      state.controller:setSection(case.section)
      if case.section == "Location" then
        enterStagedGrid(case.name)
      end
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
    Assert.isTrue(state.valueEditor:snapshot().pending, "the production species filter starts pending")
    for _ = 1, 120 do
      if not state.valueEditor:snapshot().pending then
        break
      end
      state:update(0)
    end
    Assert.isFalse(state.valueEditor:snapshot().pending, "the production species filter eventually publishes")
    local emptyChoice = capture("no-results", width, height)
    Assert.isTrue(emptyChoice.valueEditor.empty, "the production species picker exposes its no-result state")

    clickTarget(state, "cancel")
    clickTarget(state, "party:add")
    local speciesKey = assert(state.valueEditor:snapshot().selectedKey)
    clickTarget(state, "choice:" .. speciesKey)
    Assert.equal(state.controller.partyTab, "Stats", "a new member opens on the Stats page")
    topology = cases[3].topology
    capture("tall-party-stats", 720, 1280)
    topology = cases[1].topology
    clickTarget(state, "party:page:next")
    Assert.equal(state.controller.partyTab, "Moves", "the pager advances to the Moves page")
    capture("compact-party-moves", 256, 192)
    topology = cases[2].topology
    width, height = 1280, 720
    clickTarget(state, "party:page:next")
    Assert.equal(state.controller.partyTab, "Details", "the pager advances to the Details page")
    clickTarget(state, "party:field:nickname")
    local keyboard = capture("naming-keyboard", width, height)
    Assert.equal(keyboard.valueEditor.kind, "name", "the naming keyboard comes from the production draft editor")

    clickTarget(state, "cancel")
    clickTarget(state, "party:page:previous")
    clickTarget(state, "party:page:previous")
    Assert.equal(state.controller.partyTab, "Stats", "the pager returns to the Stats page")
    clickTarget(state, "party:field:level")
    state:textinput("NOT A LEVEL")
    local invalidLevel = capture("invalid-level", width, height)
    Assert.equal(invalidLevel.valueEditor.parsedValue, nil, "the invalid level remains visible in the active editor")

    clickTarget(state, "cancel")
    clickTarget(state, "party:add")
    for index = 2, 6 do
      local species = assert(state:view().valueEditor.options[1].key)
      clickTarget(state, "choice:" .. species)
      if index < 6 then
        clickTarget(state, "party:add")
      end
    end
    clickTarget(state, "party:slot:0")
    clickTarget(state, "party:slot:5")
    local crowdedParty = capture("crowded-party", width, height)
    Assert.equal(crowdedParty.partyMemberCount, 6, "the production Party view contains six applied members")
    Assert.equal(
      #assert(crowdedParty.layout.partyStrip).slots,
      6,
      "the production renderer receives all six strip positions"
    )
    local iconProvider = assert(state.renderer._iconProvider, "the selected ROM supplied the real Mon icon provider")
    local centeredIcons = 0
    for _, slot in ipairs(assert(crowdedParty.layout.partyStrip).slots) do
      if slot.iconKey ~= nil then
        local rect = assert(slot.iconRect, "Party geometry publishes each icon's content rectangle")
        local iconDimensions = iconProvider:dimensions(slot.iconKey)
        local icon = assert(
          state.renderer._icons[slot.iconKey],
          "the real provider prepared "
            .. slot.iconKey
            .. " with status "
            .. tostring(state.renderer.iconStatus)
            .. " and failure "
            .. tostring(state.renderer.iconFailure)
        )
        Assert.notNil(icon.image, "the selected ROM supplies the Party icon image")
        Assert.notNil(icon.quad, "the selected ROM supplies the Party icon frame")
        Assert.equal(icon.dimensions.width, iconDimensions.width, "the renderer retains provider width")
        Assert.equal(icon.dimensions.height, iconDimensions.height, "the renderer retains provider height")
        local scale = math.min(1, rect.width / iconDimensions.width, rect.height / iconDimensions.height)
        Assert.isTrue(scale > 0 and scale <= 1, "strip icons never upscale beyond provider pixels")
        Assert.isTrue(
          iconDimensions.width * scale <= rect.width + 0.001 and iconDimensions.height * scale <= rect.height + 0.001,
          "the scaled real icon fits its strip cell"
        )
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
    -- Reach coordinate selection first: the first escape returns to the
    -- map list and the second requests the leave confirmation.
    enterStagedGrid("leave-dialog")
    state:keypressed("escape")
    state:keyreleased("escape")
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

function T.tests.production_party_uses_generic_selector_without_retail_manifest(scope)
  local fixture = AcceptanceFixture.new()
  local originalGlobal = SaveFs.global
  local state
  local repositoryRoot = love.filesystem.getSourceBaseDirectory()
  local ok, failure = xpcall(function()
    SaveFs.global = function(backend)
      Assert.isNil(backend, "production editor composition uses the isolated acceptance backend")
      return fixture.saveFs
    end
    local topology = ScreenTopology.oneDisplay({
      id = "editor",
      rect = { x = 0, y = 0, width = 1280, height = 720 },
      touch = false,
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
      width = 1280,
      height = 720,
      derivedAssets = readyHost(),
      repositoryRoot = repositoryRoot,
      displayContext = displayContext,
      onResult = function() end,
    })
    state:update(0)
    Assert.equal(state:view().status, "ready", "the actual editor State opens the selected save")

    local dependencies = assert(state.dependencies, "ready composition publishes its manifests")
    local bagManifest = assert(dependencies.bagManifest, "the Bag manifest is already composed")
    Assert.isNil(dependencies.partyManifest, "composition no longer publishes the retail Party manifest to the editor")

    state.controller:setSection("Party")
    state:update(0)
    clickTarget(state, "party:add")
    local species = assert(state:view().valueEditor.options[1].key)
    clickTarget(state, "choice:" .. species)
    local partyView = state:view()
    local member = nil
    for _, slot in ipairs(assert(partyView.partySelector, "Party publishes its member strip").slots) do
      if slot.kind == "member" then
        member = slot
      end
    end
    member = assert(member, "the added member appears in the production member strip")
    Assert.notNil(member.iconKey, "the strip member carries its sprite identity")
    Assert.isNil(member.chrome, "strip members carry no retail panel chrome descriptor")

    state.controller:setSection("Bag")
    state:update(0)
    local itemCatalog = assert(state.dependencies.context.itemCatalog, "ready Bag needs its item catalog")
    local pocketKey = state:view().bagPocket
    local probeKey
    for _, key in ipairs(itemCatalog:itemKeys()) do
      if key ~= "NONE" and itemCatalog:item(key).pocket == pocketKey then
        probeKey = key
        break
      end
    end
    probeKey = assert(probeKey, "the catalog offers an item for the current pocket")
    Assert.isTrue(state.session:setBagQuantity(probeKey, 1).ok, "the production session stages one probe stack")
    state:update(0)
    local bagView = state:view()
    local pageRows = assert(bagView.bagPageRows, "the Bag view publishes its visible page rows")
    Assert.isTrue(#pageRows > 0, "the production Bag page exposes its item rows")
    for _, row in ipairs(pageRows) do
      Assert.notNil(row.iconKey, "item rows keep their catalog icon identity")
      Assert.notNil(row.label, "item rows keep their catalog name")
      Assert.isTrue(row.quantity > 0, "item rows keep their staged quantity")
      Assert.isNil(row.description, "item rows carry no card description")
    end
    Assert.isNil(bagView.bagBrowseBackground, "the Bag view publishes no browse background")
    Assert.isNil(bagView.bagItemSlots, "the Bag view publishes no item slot rects")
    Assert.isNil(bagView.bagItemFocusVisual, "the Bag view publishes no item focus visual")
    Assert.notNil(bagView.bagPocketStrip, "the pocket strip keeps its generated visual")
    Assert.notNil(bagView.bagQuantityVisuals, "quantity controls keep their generated visuals")
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
