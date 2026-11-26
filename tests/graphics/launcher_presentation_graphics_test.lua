-- Real offscreen launcher framebuffer coverage. Synthetic managed editions
-- exercise the production renderer/layout with real fonts and PNG textures;
-- evidence captures stay outside Git and never contain commercial pixels.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local ManagedRomIconFixture = require("tests.support.ManagedRomIconFixture")
local DisplayContext = require("libs.ui.src.DisplayContext")
local LocalClock = require("game.src.LocalClock")
local RomArchive = require("romdump.src.source.RomArchive")
local GameVersion = require("romdump.src.source.GameVersion")

local T = {}

local function context(width, height, ratio, safeRect)
  safeRect = safeRect or { x = 0, y = 0, width = width, height = height }
  return DisplayContext.new({
    graphics = {
      getDimensions = function()
        return width, height
      end,
      getDPIScale = function()
        return ratio or 1
      end,
    },
    topologyProvider = function()
      return {
        surfaces = {
          {
            id = "main",
            role = "world",
            rect = { x = 0, y = 0, width = width, height = height },
            safeRect = safeRect,
            touch = true,
          },
        },
      }
    end,
  })
end

local function audio()
  return { play = function() end, fadeBoot = function() end, update = function() end, dispose = function() end }
end

local function installEdition(rom, versionId)
  local edition = rom[versionId]
  local bytes = love.data.newByteData(edition.cart.data)
  local prepared = assert(RomArchive.prepare(edition.cart.info, bytes, edition.cart.versions))
  Assert.isTrue(RomArchive.publish(prepared))
  local png = assert(RomArchive.encodeIcon(bytes))
  Assert.isTrue(RomArchive.publishIcon(edition.cart.sha1, png))
  png:release()
  bytes:release()
end

local function editionGames(rom, installed)
  local games = {}
  for _, versionId in ipairs({ "heartgold", "soulsilver" }) do
    local game =
      { versionId = versionId, label = rom[versionId].cart.info.label, installed = installed[versionId] == true }
    if game.installed then
      game.iconSha1 = rom[versionId].cart.sha1
    end
    games[#games + 1] = game
  end
  return games
end

local function selector(renderer, rom, installed, width, height, ratio, safeRect, importView)
  return require("app.src.launcher.GameSelectState").new({
    games = editionGames(rom, installed),
    initialGameId = installed.heartgold and "heartgold" or installed.soulsilver and "soulsilver" or "heartgold",
    renderer = renderer,
    audio = audio(),
    width = width,
    height = height,
    safeRect = safeRect or { x = 0, y = 0, width = width, height = height },
    pixelRatio = ratio or 1,
    displayContext = context(width, height, ratio, safeRect),
    clock = LocalClock.new(function()
      return { year = 2026, month = 12, day = 31, hour = 23, minute = 59, second = 0 }
    end),
    getImportView = function()
      return importView
    end,
    onAction = function() end,
  })
end

local function inside(inner, outer, label)
  Assert.isTrue(inner.width > 0 and inner.height > 0, label .. " has positive area")
  Assert.isTrue(inner.x >= outer.x and inner.y >= outer.y, label .. " starts inside")
  Assert.isTrue(
    inner.x + inner.width <= outer.x + outer.width + 1e-7 and inner.y + inner.height <= outer.y + outer.height + 1e-7,
    label .. " ends inside"
  )
end

local function physicalPoint(placement, logicalX, logicalY, ratio)
  local scale = placement.pixelScale / ratio
  return (placement.origin.x + logicalX * scale) * ratio, (placement.origin.y + logicalY * scale) * ratio
end

function T.real_framebuffer_geometry_covers_selector_import_boot_and_loading(scope)
  ManagedRomIconFixture.with(function(rom)
    for editionId, info in pairs(GameVersion.VERSIONS) do
      if editionId ~= "heartgold" and info.sha1 == rom.heartgold.cart.sha1 then
        GameVersion.VERSIONS[editionId] = nil
      end
    end
    installEdition(rom, "heartgold")
    installEdition(rom, "soulsilver")
    local renderer = require("app.src.launcher.LauncherRenderer").new()
    scope:own({
      release = function()
        renderer:dispose()
      end,
    })
    Assert.equal(type(renderer.refreshGameIcon), "function", "renderer owns the narrow managed PNG refresh operation")
    Assert.equal(type(renderer.dropGameIcon), "function", "renderer owns optional texture retirement")
    for _, versionId in ipairs({ "heartgold", "soulsilver" }) do
      Assert.isTrue(renderer:refreshGameIcon(rom[versionId].cart.sha1, RomArchive.iconPath(rom[versionId].cart.sha1)))
      Assert.isTrue(
        renderer:refreshGameIcon(rom[versionId].cart.sha1, RomArchive.iconPath(rom[versionId].cart.sha1)),
        "cached icon refresh is idempotent"
      )
    end

    local outputDir = os.getenv("PORTEMON_LAUNCHER_SCREENSHOT_DIR")
    local evidence = {}
    if outputDir ~= nil then
      os.execute("mkdir -p " .. string.format("%q", outputDir))
    end
    local function capture(name, width, height, ratio, safeRect, draw)
      local canvas =
        scope:own(love.graphics.newCanvas(width * ratio, height * ratio, { format = "rgba8", readable = true }))
      love.graphics.push("all")
      love.graphics.setCanvas(canvas)
      love.graphics.clear(0, 0, 0, 0)
      love.graphics.scale(ratio, ratio)
      local originalOrigin = love.graphics.origin
      local originalIntersectScissor = love.graphics.intersectScissor
      if ratio ~= 1 then
        love.graphics.origin = function()
          originalOrigin()
          love.graphics.scale(ratio, ratio)
        end
        love.graphics.intersectScissor = function(x, y, width, height)
          originalIntersectScissor(x * ratio, y * ratio, width * ratio, height * ratio)
        end
      end
      local drew, drawFailure = xpcall(function()
        draw()
      end, debug.traceback)
      love.graphics.origin = originalOrigin
      love.graphics.intersectScissor = originalIntersectScissor
      if not drew then
        error(drawFailure, 0)
      end
      love.graphics.setCanvas()
      love.graphics.pop()
      local pixels = scope:own(canvas:newImageData())
      if outputDir ~= nil then
        local encoded = assert(pixels:encode("png"))
        local file = assert(io.open(outputDir .. "/" .. name .. ".png", "wb"))
        Assert.isTrue(file:write(encoded:getString()) ~= nil)
        Assert.isTrue(file:close())
        encoded:release()
        evidence[#evidence + 1] = { name = name, width = width * ratio, height = height * ratio, pixels = pixels }
      end
      return pixels
    end

    local cases = {
      { name = "256x192-none", width = 256, height = 192, ratio = 1, installed = {} },
      {
        name = "256x192-both",
        width = 256,
        height = 192,
        ratio = 1,
        installed = { heartgold = true, soulsilver = true },
      },
      {
        name = "320x240-both",
        width = 320,
        height = 240,
        ratio = 1,
        installed = { heartgold = true, soulsilver = true },
      },
      {
        name = "385x287-both",
        width = 385,
        height = 287,
        ratio = 1,
        installed = { heartgold = true, soulsilver = true },
      },
      {
        name = "390x844-both",
        width = 390,
        height = 844,
        ratio = 1,
        installed = { heartgold = true, soulsilver = true },
      },
      {
        name = "844x390-both",
        width = 844,
        height = 390,
        ratio = 1,
        installed = { heartgold = true, soulsilver = true },
      },
      {
        name = "1280x720-both",
        width = 1280,
        height = 720,
        ratio = 1,
        installed = { heartgold = true, soulsilver = true },
      },
      {
        name = "385x287-ratio3-insets",
        width = 385,
        height = 287,
        ratio = 3,
        safeRect = { x = 18, y = 24, width = 349, height = 239 },
        installed = { heartgold = true, soulsilver = true },
      },
    }
    local frames = {}
    for _, case in ipairs(cases) do
      local state = selector(renderer, rom, case.installed, case.width, case.height, case.ratio, case.safeRect)
      scope:own({
        release = function()
          state:dispose()
        end,
      })
      local view = state:view()
      inside(view.layout.header, view.layout.viewport, "status bar")
      for _, versionId in ipairs({ "heartgold", "soulsilver" }) do
        local slot = assert(view.layout.slots[versionId])
        inside(slot.rect, view.layout.viewport, versionId .. " cartridge")
        inside(slot.iconWell, slot.rect, versionId .. " icon well")
        Assert.notNil(view.layout.graph.targets[versionId])
      end
      local pixels = capture(
        case.name,
        case.width,
        case.height,
        case.ratio,
        case.safeRect or { x = 0, y = 0, width = case.width, height = case.height },
        function()
          state:draw()
        end
      )
      frames[case.name] = pixels
      if case.installed.heartgold then
        local placement = view.presentation.panes[1].placement
        local well = view.layout.slots.heartgold.iconWell
        local x, y = physicalPoint(placement, well.x + well.width / 2, well.y + well.height / 2, case.ratio)
        local r, g, b, a = pixels:getPixel(math.floor(x), math.floor(y))
        Assert.isTrue(a > 0 and (r ~= 0 or g ~= 0 or b ~= 0), "the real managed icon is visible in its well")
      end
      state:keypressed("down")
      capture(
        case.name .. "-silver-focus",
        case.width,
        case.height,
        case.ratio,
        case.safeRect or { x = 0, y = 0, width = case.width, height = case.height },
        function()
          state:draw()
        end
      )
    end
    Assert.isTrue(
      frames["256x192-none"]:getString() ~= frames["256x192-both"]:getString(),
      "installation changes actual cartridge pixels"
    )

    local importCases = {
      {
        mode = "choose",
        expectedVersionId = "soulsilver",
        attemptId = "choose",
        pickerAvailable = true,
        canCancel = true,
      },
      {
        mode = "receipt",
        expectedVersionId = "soulsilver",
        attemptId = "receipt",
        receipt = "A long selected ROM filename that must fit the compact receipt row.nds",
        statusText = "Waiting for readers",
        canCancel = true,
      },
      {
        mode = "importing",
        expectedVersionId = "soulsilver",
        attemptId = "busy",
        receipt = "SoulSilver.nds",
        statusText = "Verifying ROM",
        canCancel = true,
      },
      {
        mode = "importing",
        expectedVersionId = "soulsilver",
        attemptId = "commit",
        receipt = "SoulSilver.nds",
        statusText = "Saving ROM",
        progress = 0.9,
        canCancel = false,
      },
      {
        mode = "error",
        expectedVersionId = "soulsilver",
        attemptId = "error",
        error = "Expected SoulSilver; detected HeartGold",
        pickerAvailable = false,
        canCancel = false,
      },
    }
    for _, importView in ipairs(importCases) do
      local state = selector(renderer, rom, { heartgold = true }, 256, 192, 1, nil, importView)
      scope:own({
        release = function()
          state:dispose()
        end,
      })
      local view = state:view()
      Assert.equal(view.mode, importView.mode)
      for targetId, target in pairs(view.layout.graph.targets) do
        inside(target.rect, view.layout.viewport, importView.mode .. " " .. targetId)
      end
      capture("import-256x192-" .. importView.attemptId, 256, 192, 1, nil, function()
        state:draw()
      end)
    end

    local BootIntroState = require("app.src.launcher.BootIntroState")
    for _, size in ipairs({ { 256, 192 }, { 390, 844 } }) do
      local display = context(size[1], size[2], 1)
      local boot = BootIntroState.new({
        renderer = renderer,
        audio = audio(),
        displayContext = display,
        width = size[1],
        height = size[2],
        safeRect = { x = 0, y = 0, width = size[1], height = size[2] },
        pixelRatio = 1,
      })
      scope:own({
        release = function()
          boot:dispose()
        end,
      })
      boot:update(0.2)
      Assert.equal(boot.elapsed, 0, "time before the first paint is not jingle time")
      boot:draw()
      boot:update(0.2)
      Assert.equal(boot.elapsed, 0.2, "jingle time advances only after the painted frame")
      capture("boot-" .. size[1] .. "x" .. size[2], size[1], size[2], 1, nil, function()
        boot:draw()
      end)
    end

    local Loading = require("app.src.launcher.LauncherLoadingPresentation")
    for _, operation in ipairs({
      { name = "selection", selectionInterrupt = true },
      {
        name = "quiescence",
        selectionInterrupt = false,
        receipt = "SoulSilver.nds",
        statusText = "Waiting for readers",
        canCancel = true,
      },
    }) do
      local loading = Loading.new({
        renderer = renderer,
        versionId = "soulsilver",
        label = "SoulSilver",
        width = 256,
        height = 192,
        safeRect = { x = 0, y = 0, width = 256, height = 192 },
        pixelRatio = 1,
        displayContext = context(256, 192, 1),
        selectionInterrupt = operation.selectionInterrupt,
        receipt = operation.receipt,
        statusText = operation.statusText,
        canCancel = operation.canCancel,
        onCancel = function() end,
      })
      scope:own({
        release = function()
          loading:dispose()
        end,
      })
      loading:update(0.2)
      capture("loading-256x192-" .. operation.name, 256, 192, 1, nil, function()
        loading:draw()
      end)
    end

    if outputDir ~= nil then
      local columns = 3
      local thumbWidth, thumbHeight = 320, 240
      local rows = math.ceil(#evidence / columns)
      local sheet = scope:own(love.graphics.newCanvas(columns * thumbWidth, rows * thumbHeight))
      love.graphics.push("all")
      love.graphics.setCanvas(sheet)
      love.graphics.clear(0.12, 0.12, 0.12, 1)
      for index, item in ipairs(evidence) do
        local x = ((index - 1) % columns) * thumbWidth
        local y = math.floor((index - 1) / columns) * thumbHeight
        local image = scope:own(love.graphics.newImage(item.pixels))
        love.graphics.draw(image, x, y, 0, thumbWidth / item.width, thumbHeight / item.height)
      end
      love.graphics.setCanvas()
      love.graphics.pop()
      local sheetData = scope:own(sheet:newImageData())
      local encoded = assert(sheetData:encode("png"))
      local file = assert(io.open(outputDir .. "/contact-sheet.png", "wb"))
      Assert.isTrue(file:write(encoded:getString()) ~= nil)
      Assert.isTrue(file:close())
      encoded:release()
      local manifest = assert(io.open(outputDir .. "/manifest.txt", "w"))
      manifest:write("Synthetic managed-edition framebuffer evidence; not final private-ROM visual proof.\n")
      for _, item in ipairs(evidence) do
        manifest:write(string.format("%s.png %dx%d\n", item.name, item.width, item.height))
      end
      manifest:write("contact-sheet.png\n")
      Assert.isTrue(manifest:close())
    end
  end)
end

function T.dual_content_pane_acknowledges_the_visible_receipt(scope)
  local renderer = require("app.src.launcher.LauncherRenderer").new()
  scope:own({
    release = function()
      renderer:dispose()
    end,
  })
  local width, height = 512, 192
  local safeRect = { x = 0, y = 0, width = 256, height = 192 }
  local displayContext = DisplayContext.new({
    graphics = {
      getDimensions = function()
        return width, height
      end,
      getDPIScale = function()
        return 1
      end,
    },
    topologyProvider = function()
      return {
        surfaces = {
          {
            id = "main",
            role = "world",
            rect = { x = 0, y = 0, width = 256, height = 192 },
            safeRect = safeRect,
            touch = true,
          },
          {
            id = "aux",
            role = "auxiliary",
            rect = { x = 256, y = 0, width = 256, height = 192 },
            safeRect = { x = 256, y = 0, width = 256, height = 192 },
            touch = true,
          },
        },
      }
    end,
  })
  local importView = {
    attemptId = "dual-receipt-paint",
    mode = "receipt",
    expectedVersionId = "heartgold",
    receipt = "source.nds",
    statusText = "Waiting for readers",
    canCancel = true,
  }
  local selection = require("app.src.launcher.GameSelectState").new({
    games = {
      { versionId = "heartgold", label = "HeartGold", installed = false },
      { versionId = "soulsilver", label = "SoulSilver", installed = false },
    },
    initialGameId = "heartgold",
    renderer = renderer,
    audio = audio(),
    width = width,
    height = height,
    safeRect = safeRect,
    pixelRatio = 1,
    displayContext = displayContext,
    clock = LocalClock.new(function()
      return { year = 2026, month = 12, day = 31, hour = 23, minute = 59, second = 0 }
    end),
    getImportView = function()
      return importView
    end,
    onAction = function() end,
  })
  scope:own({
    release = function()
      selection:dispose()
    end,
  })
  Assert.isNil(selection:paintedReceipt(), "a latched receipt is not paint evidence")
  Assert.equal(#selection:view().presentation.panes, 2, "the dual topology owns a separate status pane")
  selection:draw()
  Assert.equal(
    selection:paintedReceipt(),
    "dual-receipt-paint",
    "the content pane's drawn receipt survives the status pane paint"
  )
end

function T.shared_touch_button_renderer_remains_real_and_stateful(scope)
  local renderer = require("app.src.launcher.LauncherRenderer").new()
  scope:own({
    release = function()
      renderer:dispose()
    end,
  })
  local function frame(visual)
    local canvas = scope:own(love.graphics.newCanvas(128, 48))
    love.graphics.push("all")
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    renderer:drawButton({ x = 0, y = 0, width = 128, height = 44 }, "A", nil, visual)
    love.graphics.setCanvas()
    love.graphics.pop()
    return scope:own(canvas:newImageData()):getString()
  end
  local normal = frame({})
  local focused = frame({ focused = true })
  local pressed = frame({ focused = true, pressed = true })
  Assert.isTrue(normal ~= focused, "focus changes real touch-control pixels")
  Assert.isTrue(focused ~= pressed, "pressed state changes real touch-control pixels")
end

function T.corrupt_optional_icon_is_blank_without_gating_managed_source(scope)
  ManagedRomIconFixture.with(function(rom)
    for editionId, info in pairs(GameVersion.VERSIONS) do
      if editionId ~= "heartgold" and info.sha1 == rom.heartgold.cart.sha1 then
        GameVersion.VERSIONS[editionId] = nil
      end
    end
    installEdition(rom, "heartgold")
    Assert.isTrue(love.filesystem.write(rom.heartgold.icon, "not a png"))
    local renderer = require("app.src.launcher.LauncherRenderer").new()
    scope:own({
      release = function()
        renderer:dispose()
      end,
    })
    Assert.isFalse(
      renderer:refreshGameIcon(rom.heartgold.cart.sha1, rom.heartgold.icon),
      "corrupt optional PNG is rejected without a synthetic replacement"
    )
    Assert.notNil(
      RomArchive.recoverablePath(rom.heartgold.cart.sha1),
      "optional icon failure leaves the managed source installed"
    )
    renderer:dropGameIcon(rom.heartgold.cart.sha1)
    renderer:dropGameIcon(rom.heartgold.cart.sha1)
  end)
end

return GraphicsSmoke.suite(T)
