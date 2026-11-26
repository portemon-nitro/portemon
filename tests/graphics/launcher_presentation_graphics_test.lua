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

local BOOT_LOGO_WIDTH, BOOT_LOGO_HEIGHT = 451, 115
local BOOT_LOGO_INK_WIDTH, BOOT_LOGO_INK_HEIGHT = 433, 107
local BOOT_LOGO_LOGICAL_WIDTH = 301

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

local function drawToPixels(scope, width, height, ratio, draw)
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
  local drew, drawFailure = xpcall(draw, debug.traceback)
  love.graphics.origin = originalOrigin
  love.graphics.intersectScissor = originalIntersectScissor
  if not drew then
    error(drawFailure, 0)
  end
  love.graphics.setCanvas()
  love.graphics.pop()
  return scope:own(canvas:newImageData())
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
    local function capture(name, width, height, ratio, _, draw)
      local pixels = drawToPixels(scope, width, height, ratio, draw)
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

local function samplePixel(pixels, x, y)
  local red, green, blue, alpha = pixels:getPixel(math.floor(x), math.floor(y))
  return { r = red * 255, g = green * 255, b = blue * 255, a = alpha * 255 }
end

local function writeCapture(name, pixels)
  local outputDir = os.getenv("PORTEMON_LAUNCHER_SCREENSHOT_DIR")
  if outputDir == nil then
    return
  end
  local encoded = assert(pixels:encode("png"))
  local file = assert(io.open(outputDir .. "/" .. name .. ".png", "wb"))
  file:write(encoded:getString())
  file:close()
  encoded:release()
end

function T.background_major_grid_uses_48_pixel_square_boundaries(scope)
  local renderer = require("app.src.launcher.LauncherRenderer").new()
  scope:own({
    release = function()
      renderer:dispose()
    end,
  })
  local width, height = 256, 192
  local pixels = drawToPixels(scope, width, height, 1, function()
    renderer:_background(width, height)
  end)
  local function sameColor(actual, expected)
    return actual.r == expected.r and actual.g == expected.g and actual.b == expected.b and actual.a == expected.a
  end
  local plain = samplePixel(pixels, 10, 1)
  local fine = samplePixel(pixels, 10, 2)
  local major = samplePixel(pixels, 10, 0)
  Assert.isTrue(not sameColor(plain, fine), "fine horizontal lines remain")
  Assert.isTrue(not sameColor(plain, major), "major boundaries use a distinct color")
  Assert.isTrue(not sameColor(fine, major), "major and fine lines are distinct")
  for y = 0, height - 1, 48 do
    Assert.isTrue(sameColor(samplePixel(pixels, 10, y), major), "y=" .. y .. " is a major horizontal boundary")
  end
  for y = 2, height - 1, 2 do
    if y % 48 ~= 0 then
      Assert.isTrue(sameColor(samplePixel(pixels, 10, y), fine), "y=" .. y .. " keeps only the fine horizontal line")
    end
  end
  for x = 0, width - 1, 48 do
    Assert.isTrue(sameColor(samplePixel(pixels, x, 25), major), "x=" .. x .. " is a major vertical boundary")
  end
  for x = 1, width - 1 do
    if x % 48 ~= 0 then
      local nearCrossing = x % 48 <= 1 or x % 48 >= 47
      if not nearCrossing then
        Assert.isTrue(sameColor(samplePixel(pixels, x, 1), plain), "x=" .. x .. " has no secondary vertical stripe")
      end
    end
  end
end

function T.background_major_intersections_carry_a_3x3_major_square(scope)
  local renderer = require("app.src.launcher.LauncherRenderer").new()
  scope:own({
    release = function()
      renderer:dispose()
    end,
  })
  local width, height = 256, 192
  local pixels = drawToPixels(scope, width, height, 1, function()
    renderer:_background(width, height)
  end)
  local function sameColor(actual, expected)
    return actual.r == expected.r and actual.g == expected.g and actual.b == expected.b and actual.a == expected.a
  end
  local plain = samplePixel(pixels, 10, 1)
  local vertical = samplePixel(pixels, 48, 50)
  local horizontal = samplePixel(pixels, 50, 48)
  local major = vertical
  Assert.isTrue(sameColor(horizontal, major), "both major directions share one color")
  Assert.isTrue(not sameColor(vertical, plain), "the vertical major line remains away from crossings")
  Assert.isTrue(not sameColor(horizontal, plain), "the horizontal major line remains away from crossings")
  for _, point in ipairs({ { 48, 48 }, { 96, 96 }, { 144, 144 } }) do
    local center = samplePixel(pixels, point[1], point[2])
    Assert.isTrue(
      sameColor(center, major),
      string.format("the %dx%d crossing carries a major square", point[1], point[2])
    )
    local corner = samplePixel(pixels, point[1] - 1, point[2] - 1)
    Assert.isTrue(
      sameColor(corner, major),
      string.format("the %dx%d square reaches its corners", point[1], point[2])
    )
    local outside = samplePixel(pixels, point[1] - 3, point[2] - 3)
    Assert.isTrue(
      sameColor(outside, plain),
      string.format("the %dx%d square stays 3x3", point[1], point[2])
    )
  end
end

function T.neutral_loading_title_is_the_dark_primary_label(scope)
  local renderer = require("app.src.launcher.LauncherRenderer").new()
  scope:own({
    release = function()
      renderer:dispose()
    end,
  })
  local Loading = require("app.src.launcher.LauncherLoadingPresentation")
  local safeRect = { x = 0, y = 0, width = 256, height = 192 }
  local loading = Loading.new({
    renderer = renderer,
    versionId = "soulsilver",
    gameLabel = "Pokémon SoulSilver",
    label = "Now loading...",
    width = 256,
    height = 192,
    safeRect = safeRect,
    pixelRatio = 1,
    displayContext = context(256, 192, 1, safeRect),
    selectionInterrupt = true,
    onCancel = function() end,
  })
  scope:own({
    release = function()
      loading:dispose()
    end,
  })
  local pixels = drawToPixels(scope, 256, 192, 1, function()
    loading:draw()
  end)
  local LauncherLayout = require("app.src.launcher.LauncherLayout")
  local layout = LauncherLayout.loading(256, 192, {
    selectionInterrupt = true,
    gameLabel = "Pokémon SoulSilver",
    fonts = renderer.fonts,
  })
  local title = assert(layout.titleRect, "neutral loading reserves a title region")
  local darkest = 255
  for y = title.y, title.y + title.height - 1 do
    for x = title.x, title.x + title.width - 1 do
      local sample = samplePixel(pixels, x, y)
      local luminance = 0.299 * sample.r + 0.587 * sample.g + 0.114 * sample.b
      if sample.a > 0 and luminance < darkest then
        darkest = luminance
      end
    end
  end
  Assert.isTrue(darkest < 100, "the game name paints as dark primary ink, not a pale wash")
end

function T.boot_frame_stays_white_with_centered_ink(scope)
  local renderer = require("app.src.launcher.LauncherRenderer").new()
  scope:own({
    release = function()
      renderer:dispose()
    end,
  })
  local BootIntroState = require("app.src.launcher.BootIntroState")
  for _, case in ipairs({
    { width = 256, height = 192, ratio = 1 },
    { width = 764, height = 575, ratio = 1 },
    { width = 764, height = 575, ratio = 2 },
    { width = 390, height = 844, ratio = 1 },
    {
      width = 385,
      height = 287,
      ratio = 3,
      safeRect = { x = 18, y = 24, width = 349, height = 239 },
    },
  }) do
    local safeRect = case.safeRect or { x = 0, y = 0, width = case.width, height = case.height }
    local boot = BootIntroState.new({
      renderer = renderer,
      audio = audio(),
      displayContext = context(case.width, case.height, case.ratio, case.safeRect),
      width = case.width,
      height = case.height,
      safeRect = safeRect,
      pixelRatio = case.ratio,
    })
    scope:own({
      release = function()
        boot:dispose()
      end,
    })
    boot:update(0.2)
    boot:draw()
    boot:update(0.2)
    local pixels = drawToPixels(scope, case.width, case.height, case.ratio, function()
      boot:draw()
    end)
    writeCapture(string.format("boot-ink-%dx%d-ratio%d", case.width, case.height, case.ratio), pixels)
    local left = math.ceil(safeRect.x * case.ratio) + 2
    local top = math.ceil(safeRect.y * case.ratio) + 2
    local right = math.floor((safeRect.x + safeRect.width) * case.ratio) - 3
    local bottom = math.floor((safeRect.y + safeRect.height) * case.ratio) - 3
    for _, point in ipairs({
      { left, top },
      { right, top },
      { left, bottom },
      { right, bottom },
      { (left + right) / 2, top + 12 * case.ratio },
    }) do
      local sample = samplePixel(pixels, point[1], point[2])
      Assert.isTrue(
        sample.a > 0 and sample.r > 250 and sample.g > 250 and sample.b > 250,
        "boot paints pure white away from its ink"
      )
    end
    local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
    local inkBottom = math.floor(top + safeRect.height * case.ratio * 0.7)
    for y = top, inkBottom do
      for x = left, right do
        local sample = samplePixel(pixels, x, y)
        if sample.a > 0 and (sample.r < 245 or sample.g < 245 or sample.b < 245) then
          minX, maxX = math.min(minX, x), math.max(maxX, x)
          minY, maxY = math.min(minY, y), math.max(maxY, y)
        end
      end
    end
    Assert.isTrue(minX < math.huge, "the boot logo reaches the framebuffer")
    Assert.isTrue(maxY < inkBottom, "the boot logo stays clear of the selection prompt")
    local logical = boot.surface.logicalViewport
    local physicalScale = assert(boot.surface.placement.pixelScale)
    local drawnWidth = math.min(BOOT_LOGO_LOGICAL_WIDTH, logical.width - 16)
    local drawnHeight = drawnWidth * BOOT_LOGO_HEIGHT / BOOT_LOGO_WIDTH
    Assert.isTrue(
      math.abs(maxX - minX + 1 - drawnWidth * BOOT_LOGO_INK_WIDTH / BOOT_LOGO_WIDTH * physicalScale)
        <= 8 * physicalScale,
      "the logo ink keeps the measured wordmark extent"
    )
    Assert.isTrue(
      math.abs(maxY - minY + 1 - drawnHeight * BOOT_LOGO_INK_HEIGHT / BOOT_LOGO_HEIGHT * physicalScale)
        <= 8 * physicalScale,
      "the logo keeps its native aspect ratio"
    )
    Assert.isTrue(
      math.abs((minX + maxX) / 2 - (safeRect.x + safeRect.width / 2) * case.ratio) <= 6 * case.ratio,
      "the boot logo is horizontally centered"
    )
    Assert.isTrue(
      math.abs((minY + maxY) / 2 - (safeRect.y + safeRect.height / 2) * case.ratio) <= 10 * case.ratio,
      "the boot logo is vertically centered"
    )
  end
end

function T.selector_chrome_owns_blue_segments_and_four_focus_corners(scope)
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
    local state = selector(renderer, rom, { heartgold = true, soulsilver = true }, 256, 192, 1, nil)
    scope:own({
      release = function()
        state:dispose()
      end,
    })
    local header = assert(state:view().layout.header)
    local pixels = drawToPixels(scope, 256, 192, 1, function()
      state:draw()
    end)
    local function blueSample(y)
      for x = header.x + 2, header.x + header.width - 3 do
        local sample = samplePixel(pixels, x, y)
        if sample.a > 0 and sample.b - sample.r >= 20 and sample.b - sample.g >= 10 then
          return sample
        end
      end
      return nil
    end
    local top = blueSample(header.y + 3)
    local bottom = blueSample(header.y + header.height - 4)
    Assert.notNil(top, "the status strip is a desaturated blue band")
    Assert.notNil(bottom, "the status strip stays blue at its lower edge")
    Assert.isTrue(math.abs(top.b - bottom.b) >= 8, "the status strip has a real vertical gradient")
    local separators = 0
    for y = header.y + 3, header.y + header.height - 4 do
      for x = header.x + 3, header.x + header.width - 4 do
        local sample = samplePixel(pixels, x, y)
        if sample.r < 120 and sample.b - sample.r > 20 then
          separators = separators + 1
        end
      end
    end
    Assert.isTrue(separators > 0, "the status strip has dark cell separators")

    state:keypressed("down")
    local view = state:view()
    local focusRect = assert(view.layout.slots.soulsilver).focusRect
    local placement = assert(view.presentation.panes[1].placement)
    local focusedPixels = drawToPixels(scope, 256, 192, 1, function()
      state:draw()
    end)
    for _, corner in ipairs({
      { focusRect.x + 1, focusRect.y + 1 },
      { focusRect.x + focusRect.width - 2, focusRect.y + 1 },
      { focusRect.x + 1, focusRect.y + focusRect.height - 2 },
      { focusRect.x + focusRect.width - 2, focusRect.y + focusRect.height - 2 },
    }) do
      local x, y = physicalPoint(placement, corner[1], corner[2], 1)
      local found = false
      for dx = -2, 2 do
        for dy = -2, 2 do
          local sample = samplePixel(focusedPixels, x + dx, y + dy)
          if sample.a > 0 and sample.b - sample.r >= 30 and sample.b - sample.g >= 10 then
            found = true
          end
        end
      end
      Assert.isTrue(found, "all four focus corners use the accent blue")
    end
  end)
end

function T.neutral_error_diagnostic_is_confined_to_the_measured_region(scope)
  local renderer = require("app.src.launcher.LauncherRenderer").new()
  scope:own({
    release = function()
      renderer:dispose()
    end,
  })
  local Loading = require("app.src.launcher.LauncherLoadingPresentation")
  local LauncherLayout = require("app.src.launcher.LauncherLayout")
  for _, case in ipairs({ { width = 256, height = 192 }, { width = 320, height = 240 }, { width = 390, height = 844 } }) do
    local safeRect = { x = 0, y = 0, width = case.width, height = case.height }
    local loading = Loading.new({
      renderer = renderer,
      versionId = "soulsilver",
      gameLabel = "Pokémon SoulSilver",
      label = "Now loading...",
      width = case.width,
      height = case.height,
      safeRect = safeRect,
      pixelRatio = 1,
      displayContext = context(case.width, case.height, 1, safeRect),
      selectionInterrupt = true,
      onCancel = function() end,
    })
    scope:own({
      release = function()
        loading:dispose()
      end,
    })
    local surface = LauncherLayout.surface(safeRect, 1)
    Assert.equal(surface.placement.pixelScale, 1, "the diagnostic evidence stays at logical density")
    local layout = LauncherLayout.loading(surface.logicalViewport.width, surface.logicalViewport.height, {
      selectionInterrupt = true,
      gameLabel = "Pokémon SoulSilver",
      error = "CARD READ FAILED",
      fonts = renderer.fonts,
    })
    local region = assert(layout.errorRect, "a neutral failure reserves measured diagnostic geometry")
    Assert.isTrue(
      region.y >= layout.indicatorRect.y + layout.indicatorRect.height,
      "the diagnostic region follows the centered indicator"
    )
    local function frame(message)
      return drawToPixels(scope, case.width, case.height, 1, function()
        loading:draw({ error = message })
      end)
    end
    local first = frame("CARD READ FAILED")
    local second = frame("SAVE DATA CORRUPTED")
    local minX, minY, maxX, maxY = case.width, case.height, -1, -1
    for y = 0, case.height - 1 do
      for x = 0, case.width - 1 do
        local firstRed, firstGreen, firstBlue, firstAlpha = first:getPixel(x, y)
        local secondRed, secondGreen, secondBlue, secondAlpha = second:getPixel(x, y)
        if
          firstRed ~= secondRed
          or firstGreen ~= secondGreen
          or firstBlue ~= secondBlue
          or firstAlpha ~= secondAlpha
        then
          minX, maxX = math.min(minX, x), math.max(maxX, x)
          minY, maxY = math.min(minY, y), math.max(maxY, y)
        end
      end
    end
    Assert.isTrue(maxX >= minX and maxY >= minY, "distinct diagnostics paint distinct pixels")
    Assert.isTrue(
      minX >= region.x and minY >= region.y and maxX < region.x + region.width and maxY < region.y + region.height,
      "all diagnostic pixels stay inside the measured region"
    )
    Assert.isTrue(maxY < layout.promptRect.y, "the reserved prompt is untouched by a diagnostic")
  end
end

function T.loading_paint_fills_the_resolved_surface_at_integer_density(scope)
  local renderer = require("app.src.launcher.LauncherRenderer").new()
  scope:own({
    release = function()
      renderer:dispose()
    end,
  })
  local Loading = require("app.src.launcher.LauncherLoadingPresentation")
  local inset = { x = 18, y = 24, width = 700, height = 520 }
  for _, case in ipairs({
    { name = "wide", width = 764, height = 575, ratio = 1 },
    { name = "inset", width = 1280, height = 960, ratio = 2, safeRect = inset },
    {
      name = "operation",
      width = 1280,
      height = 960,
      ratio = 2,
      safeRect = inset,
      selectionInterrupt = false,
      receipt = "SoulSilver.nds",
      statusText = "Waiting for readers",
      canCancel = true,
    },
  }) do
    local safeRect = case.safeRect or { x = 0, y = 0, width = case.width, height = case.height }
    local loading = Loading.new({
      renderer = renderer,
      versionId = "soulsilver",
      gameLabel = "Pokémon SoulSilver",
      label = "SoulSilver",
      width = case.width,
      height = case.height,
      safeRect = safeRect,
      pixelRatio = case.ratio,
      displayContext = context(case.width, case.height, case.ratio, case.safeRect),
      selectionInterrupt = case.selectionInterrupt ~= false,
      receipt = case.receipt,
      statusText = case.statusText,
      canCancel = case.canCancel == true,
      onCancel = function() end,
    })
    scope:own({
      release = function()
        loading:dispose()
      end,
    })
    loading:update(0.2)
    local pixels = drawToPixels(scope, case.width, case.height, case.ratio, function()
      loading:draw()
    end)
    writeCapture("loading-placement-" .. case.name, pixels)
    local left = math.ceil(safeRect.x * case.ratio) + 2
    local top = math.ceil(safeRect.y * case.ratio) + 2
    local right = math.floor((safeRect.x + safeRect.width) * case.ratio) - 3
    local bottom = math.floor((safeRect.y + safeRect.height) * case.ratio) - 3
    for _, point in ipairs({ { left, top }, { right, top }, { left, bottom }, { right, bottom } }) do
      local sample = samplePixel(pixels, point[1], point[2])
      Assert.isTrue(sample.a > 0, "the loader paints the full resolved usable rect")
    end
    if safeRect.x > 0 then
      Assert.equal(samplePixel(pixels, 2, 2).a, 0, "the loader leaves pixels outside its placement untouched")
    end
  end
end

return GraphicsSmoke.suite(T)
