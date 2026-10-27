-- The selected-edition loading stage is one continuous themed scene that is
-- already distinct before generated sprite art arrives: warm gold for the
-- selected HeartGold, cool silver for SoulSilver, and a subdued neutral
-- stage with no selection. The scene paints every pixel of the drawable and
-- keeps animating; no outlined card or generic headline is ever composed.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local PngWriter = require("tests.support.PngEncoder")
local Presentation = require("libs.hgss.src.ui.HgssLoadingPresentation")

local WIDTH, HEIGHT = 480, 360

local T = {}

local function renderStage(scope, presentation)
  local canvas = scope:own(love.graphics.newCanvas(WIDTH, HEIGHT))
  love.graphics.push("all")
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  presentation:draw()
  love.graphics.setCanvas()
  love.graphics.pop()
  return scope:own(canvas:newImageData())
end

local function cornerAlpha(image)
  local minimum = 1
  for _, corner in ipairs({ { 0, 0 }, { WIDTH - 1, 0 }, { 0, HEIGHT - 1 }, { WIDTH - 1, HEIGHT - 1 } }) do
    local _, _, _, alpha = image:getPixel(corner[1], corner[2])
    minimum = math.min(minimum, alpha)
  end
  return minimum
end

function T.selected_edition_stages_differ_without_card_outlines(scope)
  local presentations = {}
  local function stage(versionId)
    local presentation = Presentation.new({ versionId = versionId, width = WIDTH, height = HEIGHT })
    presentations[#presentations + 1] = presentation
    return presentation
  end
  scope:own({
    release = function()
      for _, presentation in ipairs(presentations) do
        presentation:dispose()
      end
    end,
  })
  local gold = stage("heartgold")
  local silver = stage("soulsilver")
  local neutral = stage(nil)
  local outlined = 0
  local originalRectangle = love.graphics.rectangle
  local ok, err = xpcall(function()
    love.graphics.rectangle = function(mode, ...)
      if mode == "line" then
        outlined = outlined + 1
      end
      return originalRectangle(mode, ...)
    end
    local goldPixels = renderStage(scope, gold)
    local silverPixels = renderStage(scope, silver)
    local neutralPixels = renderStage(scope, neutral)
    Assert.isTrue(goldPixels:getString() ~= silverPixels:getString(), "gold and silver stages render distinct pixels")
    Assert.isTrue(goldPixels:getString() ~= neutralPixels:getString(), "the gold stage differs from neutral")
    Assert.isTrue(silverPixels:getString() ~= neutralPixels:getString(), "the silver stage differs from neutral")
    Assert.isTrue(cornerAlpha(goldPixels) > 0, "the gold stage covers the full drawable")
    Assert.isTrue(cornerAlpha(silverPixels) > 0, "the silver stage covers the full drawable")
    Assert.isTrue(cornerAlpha(neutralPixels) > 0, "the neutral stage covers the full drawable")
    gold:update(0.2)
    local laterGold = renderStage(scope, gold)
    Assert.isTrue(laterGold:getString() ~= goldPixels:getString(), "the pre-art stage keeps animating")
  end, debug.traceback)
  love.graphics.rectangle = originalRectangle
  if not ok then
    error(err, 0)
  end
  Assert.equal(outlined, 0, "the continuous stage draws no outlined card")
end

local function startupPairVisual(frameWidth, frameHeight)
  return {
    render = { kind = "atlas", frameWidth = frameWidth, frameHeight = frameHeight, frameCount = 2 },
    pivot = { x = 0.5, y = 1 },
    directions = {
      east = {
        walk = {
          frames = {
            { frameIndex = 1, ticks = 1 },
            { frameIndex = 2, ticks = 3 },
          },
        },
      },
    },
  }
end

-- Two-frame atlas bytes with transparent margins around an opaque sprite
-- block; the second frame shifts by one pixel so clip ticks are observable.
local function startupTransparentAtlas(frameWidth, frameHeight)
  local width = frameWidth * 2
  local parts = {}
  for y = 0, frameHeight - 1 do
    for x = 0, width - 1 do
      local localX = x % frameWidth
      local shift = math.floor(x / frameWidth)
      local inSprite = localX >= 2 + shift and localX < frameWidth - 2 + shift and y >= 2 and y < frameHeight - 2
      if inSprite then
        parts[#parts + 1] = string.char(240, 200, 120, 255)
      else
        parts[#parts + 1] = string.char(0, 0, 0, 0)
      end
    end
  end
  return PngWriter.encode(width, frameHeight, table.concat(parts))
end

local function startupPairCacheFs(pairIndex, versionId)
  local heroPath = "assets/generated/startup/loader/pairs/" .. pairIndex .. "/hero.png"
  local followerPath = "assets/generated/startup/loader/pairs/" .. pairIndex .. "/follower.png"
  local manifest = {
    schema = "g4-startup-walker-v1",
    versionId = versionId,
    generationId = "test-generation",
    pairIndex = pairIndex,
    hero = { atlasPath = heroPath, visual = startupPairVisual(16, 24) },
    follower = { speciesId = 25, atlasPath = followerPath, visual = startupPairVisual(12, 20) },
  }
  local files = {
    [heroPath] = startupTransparentAtlas(16, 24),
    [followerPath] = startupTransparentAtlas(12, 20),
  }
  return {
    loadLua = function()
      return manifest
    end,
    exists = function()
      return true
    end,
    read = function(_, path)
      return assert(files[path], "unexpected generated read " .. tostring(path))
    end,
  }
end

local function startupDiffBytes(left, right)
  Assert.equal(#left, #right, "compared stages share their dimensions")
  local changed = 0
  for index = 1, #left do
    if left:byte(index) ~= right:byte(index) then
      changed = changed + 1
    end
  end
  return changed
end

function T.startup_pair_paints_transparent_sprites_over_the_live_stage(scope)
  local presentation = Presentation.new({
    versionId = "heartgold",
    width = WIDTH,
    height = HEIGHT,
    pairIndex = 5,
    random = function()
      return 0.25
    end,
  })
  scope:own({
    release = function()
      presentation:dispose()
    end,
  })
  local pre = renderStage(scope, presentation)
  Assert.isTrue(
    presentation:adoptGeneratedAssets(startupPairCacheFs(5, "heartgold")),
    "the chosen pair adopts its two transparent atlases"
  )
  local post = renderStage(scope, presentation)
  local total = WIDTH * HEIGHT * 4
  local changed = startupDiffBytes(pre:getString(), post:getString())
  Assert.isTrue(changed > 0, "the adopted pair is visible over the live stage")
  Assert.isTrue(
    changed < total * 0.05,
    "transparent sprite margins leave the live stage visible around the pair"
  )
  presentation:update(1 / 30)
  local advanced = renderStage(scope, presentation)
  Assert.isTrue(
    advanced:getString() ~= post:getString(),
    "the adopted stage keeps animating through source walk ticks"
  )
  Assert.isTrue(cornerAlpha(advanced) > 0, "the adopted stage still covers the full drawable")
end

function T.startup_stage_opens_on_a_random_line_and_stays_animated(scope)
  local presentations = {}
  local function present(firstRandom)
    local presentation = Presentation.new({
      versionId = "heartgold",
      width = WIDTH,
      height = HEIGHT,
      pairIndex = 5,
      random = function()
        return firstRandom
      end,
    })
    presentations[#presentations + 1] = presentation
    return presentation
  end
  scope:own({
    release = function()
      for _, presentation in ipairs(presentations) do
        presentation:dispose()
      end
    end,
  })
  local first = present(0.1)
  local second = present(0.9)
  local firstPixels = renderStage(scope, first)
  local secondPixels = renderStage(scope, second)
  Assert.isTrue(
    firstPixels:getString() ~= secondPixels:getString(),
    "the opening flavor line follows the injected random stream"
  )
  Assert.isTrue(
    first:adoptGeneratedAssets(startupPairCacheFs(5, "heartgold")),
    "the chosen pair adopts its two transparent atlases"
  )
  local adopted = renderStage(scope, first)
  first:update(1 / 60)
  local moved = renderStage(scope, first)
  Assert.isTrue(
    moved:getString() ~= adopted:getString(),
    "the scenery keeps moving behind the adopted pair"
  )
end

function T.walking_pair_keeps_single_tile_gap_with_source_cadence_lift(scope)
  local presentation = Presentation.new({
    versionId = "heartgold",
    width = WIDTH,
    height = HEIGHT,
    pairIndex = 5,
    random = function()
      return 0.25
    end,
  })
  scope:own({
    release = function()
      presentation:dispose()
    end,
  })
  Assert.isTrue(
    presentation:adoptGeneratedAssets(startupPairCacheFs(5, "heartgold")),
    "the chosen pair adopts its two transparent atlases"
  )
  local heroFrameWidth, followerFrameWidth, pivotX = 16, 12, 0.5
  local totalTicks = 4
  local tickSeconds = 1 / 30
  local originalDraw = love.graphics.draw
  local samples = {}
  local ok, err = xpcall(function()
    for tickIndex = 0, totalTicks do
      presentation.elapsed = (tickIndex + 0.5) * tickSeconds
      local draws = {}
      love.graphics.draw = function(drawable, quad, x, y, rotation, scaleX, scaleY, ...)
        if quad ~= nil and type(x) == "number" and type(drawable.getWidth) == "function" then
          local atlasWidth = drawable:getWidth()
          if atlasWidth == heroFrameWidth * 2 or atlasWidth == followerFrameWidth * 2 then
            draws[#draws + 1] = { atlasWidth = atlasWidth, quad = quad, x = x, y = y, scale = scaleX or 1 }
          end
        end
        return originalDraw(drawable, quad, x, y, rotation, scaleX, scaleY, ...)
      end
      local canvas = scope:own(love.graphics.newCanvas(WIDTH, HEIGHT))
      love.graphics.push("all")
      love.graphics.setCanvas(canvas)
      love.graphics.clear(0, 0, 0, 0)
      presentation:draw()
      love.graphics.setCanvas()
      love.graphics.pop()
      love.graphics.draw = originalDraw
      local heroDraw, followerDraw
      for _, draw in ipairs(draws) do
        if draw.atlasWidth == heroFrameWidth * 2 then
          heroDraw = draw
        else
          followerDraw = draw
        end
      end
      Assert.notNil(heroDraw, "the hero sprite draws on tick " .. tickIndex)
      Assert.notNil(followerDraw, "the follower sprite draws on tick " .. tickIndex)
      samples[tickIndex] = { hero = heroDraw, follower = followerDraw }
    end
  end, debug.traceback)
  love.graphics.draw = originalDraw
  if not ok then
    error(err, 0)
  end
  for tickIndex = 0, totalTicks - 1 do
    local heroDraw = samples[tickIndex].hero
    local followerDraw = samples[tickIndex].follower
    Assert.equal(heroDraw.scale, followerDraw.scale, "the pair shares one stage scale")
    local scale = heroDraw.scale
    local gap = (heroDraw.x - followerDraw.x) / scale + (heroFrameWidth - followerFrameWidth) * pivotX
    Assert.near(gap, 16, 0.001, "the follower foot stays one tile behind the hero foot on tick " .. tickIndex)
  end
  local step = samples[0].follower.scale
  local restY = samples[0].follower.y
  local liftY = samples[1].follower.y
  Assert.isTrue(liftY ~= restY, "the follower lifts off the baseline between source walk frames")
  Assert.near(math.abs(liftY - restY), step, 0.001, "the gait lift is one source pixel")
  Assert.near(samples[totalTicks].follower.y, restY, 0.001, "the follower lands back on the baseline at gait rest")
  Assert.isTrue(samples[0].hero.quad ~= samples[1].hero.quad, "the hero walk clip advances on source tick cadence")
  Assert.isTrue(
    samples[0].follower.quad ~= samples[1].follower.quad,
    "the follower walk clip advances on source tick cadence"
  )
end

function T.tall_flavor_caption_sits_beside_pair_with_readable_type(scope)
  local presentations = {}
  scope:own({
    release = function()
      for _, presentation in ipairs(presentations) do
        presentation:dispose()
      end
    end,
  })
  local function paintedGeometry(presentation, width, height)
    local spriteBottom, captionTop, fontHeight
    local lines = {}
    local originalDraw, originalPrint, originalPrintf = love.graphics.draw, love.graphics.print, love.graphics.printf
    local ok, err = xpcall(function()
      love.graphics.draw = function(drawable, quad, x, y, rotation, scaleX, scaleY, ...)
        if quad ~= nil and type(x) == "number" and type(y) == "number" then
          local _, _, quadWidth, quadHeight = quad:getViewport()
          local bottom = y + quadHeight * (scaleY or scaleX or 1)
          if spriteBottom == nil or bottom > spriteBottom then
            spriteBottom = bottom
          end
        end
        return originalDraw(drawable, quad, x, y, rotation, scaleX, scaleY, ...)
      end
      local function record(value, textY)
        lines[#lines + 1] = tostring(value)
        if captionTop == nil or textY < captionTop then
          captionTop = textY
        end
        local textHeight = love.graphics.getFont():getHeight()
        if fontHeight == nil or textHeight > fontHeight then
          fontHeight = textHeight
        end
      end
      love.graphics.print = function(value, x, y, ...)
        if type(x) == "number" and type(y) == "number" then
          record(value, y)
        else
          lines[#lines + 1] = tostring(value)
        end
        return originalPrint(value, x, y, ...)
      end
      love.graphics.printf = function(value, x, y, ...)
        record(value, y)
        return originalPrintf(value, x, y, ...)
      end
      local canvas = scope:own(love.graphics.newCanvas(width, height))
      love.graphics.push("all")
      love.graphics.setCanvas(canvas)
      love.graphics.clear(0, 0, 0, 0)
      presentation:draw()
      love.graphics.setCanvas()
      love.graphics.pop()
    end, debug.traceback)
    love.graphics.draw, love.graphics.print, love.graphics.printf = originalDraw, originalPrint, originalPrintf
    if not ok then
      error(err, 0)
    end
    return { spriteBottom = spriteBottom, captionTop = captionTop, fontHeight = fontHeight, lines = lines }
  end
  local function checkCaption(presentation, width, height, label)
    presentation.elapsed = 0
    local geometry = paintedGeometry(presentation, width, height)
    Assert.notNil(geometry.spriteBottom, label .. " paints its sprite pair")
    Assert.notNil(geometry.captionTop, label .. " paints its flavor line")
    Assert.notNil(geometry.fontHeight, label .. " measures its flavor type")
    Assert.equal(#geometry.lines, 1, label .. " paints only the single flavor line")
    Assert.isTrue(geometry.fontHeight >= 16, label .. " keeps flavor type readable, got " .. geometry.fontHeight)
    local gap = geometry.captionTop - geometry.spriteBottom
    Assert.isTrue(gap >= 0, label .. " never overlaps the pair, got gap " .. gap)
    Assert.isTrue(gap <= 40, label .. " keeps flavor beside the pair without a gulf, got gap " .. gap)
    local bounds = presentation.secondaryBounds or presentation.primaryBounds
    Assert.notNil(bounds, label .. " exposes its active pane")
    Assert.isTrue(
      geometry.captionTop + geometry.fontHeight <= bounds.y + bounds.height,
      label .. " never clips its flavor line"
    )
  end
  local shapes = {
    { width = 360, height = 640 },
    { width = 800, height = 450 },
    { width = 480, height = 360 },
  }
  for _, shape in ipairs(shapes) do
    for _, firstRandom in ipairs({ 0.5, 0.65 }) do
      local presentation = Presentation.new({
        versionId = "heartgold",
        width = shape.width,
        height = shape.height,
        pairIndex = 5,
        random = function()
          return firstRandom
        end,
      })
      presentations[#presentations + 1] = presentation
      Assert.isTrue(
        presentation:adoptGeneratedAssets(startupPairCacheFs(5, "heartgold")),
        "the chosen pair adopts its two transparent atlases"
      )
      checkCaption(
        presentation,
        shape.width,
        shape.height,
        shape.width .. "x" .. shape.height .. " flavor " .. firstRandom
      )
    end
  end
  local resized = Presentation.new({
    versionId = "heartgold",
    width = 480,
    height = 360,
    pairIndex = 5,
    random = function()
      return 0.5
    end,
  })
  presentations[#presentations + 1] = resized
  Assert.isTrue(
    resized:adoptGeneratedAssets(startupPairCacheFs(5, "heartgold")),
    "the chosen pair adopts its two transparent atlases"
  )
  resized:resize(360, 640)
  Assert.equal(resized.configuration, "tall", "the portrait window keeps the tall arrangement")
  checkCaption(resized, 360, 640, "resized tall flavor")
end

function T.decorative_stage_prints_only_flavor_without_progress_copy(scope)
  local presentation = Presentation.new({
    versionId = "heartgold",
    width = WIDTH,
    height = HEIGHT,
    pairIndex = 5,
    random = function()
      return 0.25
    end,
  })
  scope:own({
    release = function()
      presentation:dispose()
    end,
  })
  Assert.isTrue(
    presentation:adoptGeneratedAssets(startupPairCacheFs(5, "heartgold")),
    "the chosen pair adopts its two transparent atlases"
  )
  local function renderedLinesAndPixels(status)
    local lines = {}
    local originalPrint, originalPrintf = love.graphics.print, love.graphics.printf
    local pixels
    local ok, err = xpcall(function()
      love.graphics.print = function(value, ...)
        lines[#lines + 1] = tostring(value)
        return originalPrint(value, ...)
      end
      love.graphics.printf = function(value, ...)
        lines[#lines + 1] = tostring(value)
        return originalPrintf(value, ...)
      end
      presentation.elapsed = 0
      local canvas = scope:own(love.graphics.newCanvas(WIDTH, HEIGHT))
      love.graphics.push("all")
      love.graphics.setCanvas(canvas)
      love.graphics.clear(0, 0, 0, 0)
      presentation:draw(status)
      love.graphics.setCanvas()
      love.graphics.pop()
      pixels = scope:own(canvas:newImageData()):getString()
    end, debug.traceback)
    love.graphics.print, love.graphics.printf = originalPrint, originalPrintf
    if not ok then
      error(err, 0)
    end
    return lines, pixels
  end
  local plainLines, plainPixels = renderedLinesAndPixels(nil)
  Assert.equal(#plainLines, 1, "the quiet stage paints its single flavor line")
  local flavor = plainLines[1]
  local statusLines, statusPixels = renderedLinesAndPixels({
    label = "Preparing",
    detail = "Waiting",
    fraction = 0.4,
    error = "Something failed",
  })
  Assert.equal(#statusLines, 1, "a passed status adds no extra line to the decorative stage")
  Assert.equal(statusLines[1], flavor, "a passed status never replaces the flavor line")
  for _, leak in ipairs({ "Preparing", "Waiting", "Loading", "Something failed" }) do
    Assert.isTrue(
      statusLines[1]:find(leak, 1, true) == nil,
      "the decorative stage never prints status copy, found: " .. leak
    )
  end
  Assert.isTrue(statusPixels == plainPixels, "a passed status never paints progress pixels")
  local stringLines, stringPixels = renderedLinesAndPixels("Loading your game")
  Assert.equal(#stringLines, 1, "a passed string status adds no extra line")
  Assert.equal(stringLines[1], flavor, "a passed string status never replaces the flavor line")
  Assert.isTrue(stringPixels == plainPixels, "a passed string status never paints progress pixels")
end

function T.startup_handoff_enters_warm_at_once_and_keeps_the_cold_beat(scope)
  local StartupTitleState = require("app.src.launcher.StartupTitleState")
  local Movie = require("libs.hgss.src.presentation.HgssOpeningMovie")
  local staged = {}
  local savedNew, savedScenes = Movie.new, Movie.loadValidatedScenes
  Movie.loadValidatedScenes = function()
    local scenes = {}
    for sceneNumber = 1, 5 do
      scenes[sceneNumber] = { sceneNumber = sceneNumber }
    end
    return scenes, nil
  end
  Movie.new = function(options)
    assert(type(options.scenes) == "table" and #options.scenes == 5, "the movie needs all five scene packages")
    local movie = { ticks = 0, draws = 0, disposed = 0 }
    function movie:updateFixed()
      self.ticks = self.ticks + 1
    end
    function movie:draw()
      self.draws = self.draws + 1
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.rectangle("fill", 0, 0, WIDTH, HEIGHT)
    end
    function movie:resize() end
    function movie:requestSkip()
      return false
    end
    function movie:isFinished()
      return false
    end
    function movie:sceneNumber()
      return 1
    end
    function movie:dispose()
      self.disposed = self.disposed + 1
    end
    staged[#staged + 1] = movie
    return movie
  end
  local host = {
    requestOpeningScene = function(_, _)
      return true, nil
    end,
    requestMilestone = function(name, _)
      if name == "startup-title" then
        return true, nil
      end
      return false, nil
    end,
  }
  local menu = {
    draw = function() end,
    dispose = function() end,
  }
  local function build(initialImport)
    local presentation = Presentation.new({
      versionId = "heartgold",
      width = WIDTH,
      height = HEIGHT,
      pairIndex = 5,
      random = function()
        return 0.25
      end,
    })
    Assert.isTrue(
      presentation:adoptGeneratedAssets(startupPairCacheFs(5, "heartgold")),
      "the chosen pair adopts its two transparent atlases"
    )
    local state = StartupTitleState.new({
      versionId = "heartgold",
      epoch = 7,
      derivedAssets = host,
      stageMenu = function()
        return menu
      end,
      onFinished = function() end,
      onSwitchEdition = function() end,
      isCurrent = function()
        return true
      end,
      width = WIDTH,
      height = HEIGHT,
      initialImport = initialImport,
      loading = presentation,
    })
    return state
  end
  local function renderFrame(state, lines)
    local originalPrint, originalPrintf = love.graphics.print, love.graphics.printf
    local pixels
    local ok, err = xpcall(function()
      love.graphics.print = function(value, ...)
        lines[#lines + 1] = tostring(value)
        return originalPrint(value, ...)
      end
      love.graphics.printf = function(value, ...)
        lines[#lines + 1] = tostring(value)
        return originalPrintf(value, ...)
      end
      local canvas = scope:own(love.graphics.newCanvas(WIDTH, HEIGHT))
      love.graphics.push("all")
      love.graphics.setCanvas(canvas)
      love.graphics.clear(0, 0, 0, 0)
      state:draw()
      love.graphics.setCanvas()
      love.graphics.pop()
      pixels = scope:own(canvas:newImageData()):getString()
    end, debug.traceback)
    love.graphics.print, love.graphics.printf = originalPrint, originalPrintf
    if not ok then
      error(err, 0)
    end
    return pixels
  end
  local blankCanvas = scope:own(love.graphics.newCanvas(WIDTH, HEIGHT))
  love.graphics.push("all")
  love.graphics.setCanvas(blankCanvas)
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.setCanvas()
  love.graphics.pop()
  local blank = scope:own(blankCanvas:newImageData()):getString()
  local ok, err = xpcall(function()
    -- Warm: the adopted pair hands off on the next eligible update with no
    -- loader beat.
    local warm = build(nil)
    warm:update(1 / 30)
    Assert.equal(#staged, 1, "the warm entry stages the movie behind the loader")
    warm:update(1 / 30)
    Assert.equal(warm.phase, "movie", "the warm entry starts the staged movie without a loader beat")
    local warmLines = {}
    local warmPixels = renderFrame(warm, warmLines)
    Assert.isTrue(staged[1].draws >= 1, "the entered movie paints its first frame at once")
    Assert.isTrue(warmPixels ~= blank, "the transition frame is playable pixels, never an empty stage")
    warm:dispose()
    Assert.equal(staged[1].disposed, 1, "leaving releases the staged movie exactly once")
    -- Cold: a genuinely new import keeps one bounded beat so its freshly
    -- adopted art stays visible before the same handoff.
    local state = build(true)
    local hold = {}
    for _ = 1, 16 do
      state:update(1 / 30)
      local lines = {}
      hold[#hold + 1] = { bytes = renderFrame(state, lines), lines = lines }
    end
    Assert.equal(state.phase, "loading", "the adopted pair stays visible for its beat before the first movie frame")
    Assert.equal(#staged, 2, "the movie is staged behind the loader while it holds its beat")
    Assert.equal(staged[2].ticks, 0, "the staged movie holds its source clock at zero during the beat")
    Assert.equal(staged[2].draws, 0, "no movie frame draws before the handoff")
    for index, frame in ipairs(hold) do
      Assert.isTrue(frame.bytes ~= blank, "beat frame " .. index .. " paints the loader, never an empty stage")
      if index > 1 then
        Assert.isTrue(
          frame.bytes ~= hold[index - 1].bytes,
          "beat frame " .. index .. " keeps animating behind the adopted pair"
        )
      end
      Assert.equal(#frame.lines, 1, "beat frame " .. index .. " prints only its flavor caption")
      for _, leak in ipairs({ "Preparing", "Waiting", "Loading your game" }) do
        Assert.isTrue(
          frame.lines[1]:find(leak, 1, true) == nil,
          "the holding loader never prints internal copy, found: " .. leak
        )
      end
    end
    for _ = 1, 15 do
      state:update(1 / 30)
    end
    Assert.equal(state.phase, "movie", "the beat hands off to the opening movie")
    local firstLines = {}
    local first = renderFrame(state, firstLines)
    Assert.isTrue(staged[2].draws >= 1, "the first playable source frame draws at the transition")
    Assert.isTrue(first ~= blank, "the transition frame is playable pixels, never an empty stage")
    Assert.isTrue(first ~= hold[#hold].bytes, "the transition swaps directly to movie pixels")
    state:dispose()
    Assert.equal(staged[2].disposed, 1, "leaving releases the staged movie exactly once")
  end, debug.traceback)
  Movie.new = savedNew
  Movie.loadValidatedScenes = savedScenes
  if not ok then
    error(err, 0)
  end
end

-- The boot wait paints its animated themed stage from the very first frame,
-- before the boot-source gate answers: two draws around one update already
-- differ, and no plaintext preparing headline is ever the first frame.
function T.boot_wait_paints_the_animated_stage_before_the_gate_answers(scope)
  local CachePreparationState = require("app.src.launcher.CachePreparationState")
  local script = { calls = 0 }
  local service = {}
  function service:bootSourceStatus(_)
    script.calls = script.calls + 1
    return "source-required", { code = "ROM_SOURCE_REQUIRED" }
  end
  -- Selected-pair demand seam: the blocked wait requests its pair early
  -- while the matching-ROM remedy stays visible; the demand never
  -- transfers, and adoption still waits for admission below.
  function service:request(_, selector)
    if type(selector) == "table" and selector.requestKind == "startup-walker" then
      script.pairDemands = (script.pairDemands or 0) + 1
      return "walker-request"
    end
    return nil
  end
  function service:observe()
    return false, nil
  end
  local fired = 0
  local state = CachePreparationState.new({
    kind = "boot-source",
    epoch = 7,
    service = service,
    versionId = "soulsilver",
    pairIndex = 5,
    isCurrent = function()
      return true
    end,
    onReady = function()
      fired = fired + 1
    end,
    onCancel = function() end,
  })
  local rendered = {}
  local lg = love.graphics
  local savedPrint, savedPrintf = lg.print, lg.printf
  lg.print = function(value, ...)
    rendered[#rendered + 1] = tostring(value)
    return savedPrint(value, ...)
  end
  lg.printf = function(value, ...)
    rendered[#rendered + 1] = tostring(value)
    return savedPrintf(value, ...)
  end
  local first, second
  local ok, err = xpcall(function()
    local function render()
      local canvas = scope:own(love.graphics.newCanvas(WIDTH, HEIGHT))
      love.graphics.push("all")
      love.graphics.setCanvas(canvas)
      love.graphics.clear(0, 0, 0, 0)
      state:draw()
      love.graphics.setCanvas()
      love.graphics.pop()
      return scope:own(canvas:newImageData()):getString()
    end
    -- The first visible frame precedes every controller reply.
    first = render()
    Assert.equal(script.calls, 0, "the first draw never waits on the boot-source gate")
    state:update(0.5)
    second = render()
  end, debug.traceback)
  lg.print, lg.printf = savedPrint, savedPrintf
  state:dispose()
  if not ok then
    error(err, 0)
  end
  Assert.equal(fired, 0, "a blocked gate never transfers")
  Assert.isTrue(first ~= second, "the boot stage animates instead of sitting on static text")
  local copy = table.concat(rendered, "\n")
  Assert.isTrue(
    copy:find("Preparing", 1, true) == nil,
    "no plaintext preparing headline is the first frame, got: " .. copy
  )
end

function T.warm_admitted_wait_draws_no_remedy_copy_while_the_pair_is_pending(scope)
  local CachePreparationState = require("app.src.launcher.CachePreparationState")
  local service = {}
  function service:bootSourceStatus(_)
    return "ready", nil
  end
  function service:request(_, _)
    return "walker-request"
  end
  function service:observe(_, _)
    return false, nil
  end
  local state = CachePreparationState.new({
    kind = "boot-source",
    epoch = 7,
    service = service,
    versionId = "heartgold",
    pairIndex = 5,
    isCurrent = function()
      return true
    end,
    onReady = function() end,
    onCancel = function() end,
  })
  local rendered = {}
  local lg = love.graphics
  local savedPrint, savedPrintf = lg.print, lg.printf
  lg.print = function(value, ...)
    rendered[#rendered + 1] = tostring(value)
    return savedPrint(value, ...)
  end
  lg.printf = function(value, ...)
    rendered[#rendered + 1] = tostring(value)
    return savedPrintf(value, ...)
  end
  local first, second
  local ok, err = xpcall(function()
    local function render()
      local canvas = scope:own(love.graphics.newCanvas(WIDTH, HEIGHT))
      love.graphics.push("all")
      love.graphics.setCanvas(canvas)
      love.graphics.clear(0, 0, 0, 0)
      state:draw()
      love.graphics.setCanvas()
      love.graphics.pop()
      return scope:own(canvas:newImageData()):getString()
    end
    first = render()
    state:update(0.5)
    second = render()
  end, debug.traceback)
  lg.print, lg.printf = savedPrint, savedPrintf
  state:dispose()
  if not ok then
    error(err, 0)
  end
  Assert.isTrue(first ~= second, "the admitted stage keeps animating while the pair is pending")
  local copy = table.concat(rendered, "\n")
  for _, leak in ipairs({ "Preparing", "Waiting", "Loading your game", "%" }) do
    Assert.isTrue(
      copy:find(leak, 1, true) == nil,
      "ordinary transitional frames carry no internal copy, found: " .. leak .. " in: " .. copy
    )
  end
end

function T.blocked_wait_keeps_the_matching_rom_remedy_visible(scope)
  local CachePreparationState = require("app.src.launcher.CachePreparationState")
  local service = {}
  function service:bootSourceStatus(_)
    return "source-required", { code = "ROM_SOURCE_REQUIRED" }
  end
  local state = CachePreparationState.new({
    kind = "boot-source",
    epoch = 7,
    service = service,
    versionId = "soulsilver",
    pairIndex = 5,
    isCurrent = function()
      return true
    end,
    onReady = function() end,
    onCancel = function() end,
  })
  local rendered = {}
  local lg = love.graphics
  local savedPrint, savedPrintf = lg.print, lg.printf
  lg.print = function(value, ...)
    rendered[#rendered + 1] = tostring(value)
    return savedPrint(value, ...)
  end
  lg.printf = function(value, ...)
    rendered[#rendered + 1] = tostring(value)
    return savedPrintf(value, ...)
  end
  local pixels
  local ok, err = xpcall(function()
    state:update(0.016)
    local canvas = scope:own(love.graphics.newCanvas(WIDTH, HEIGHT))
    love.graphics.push("all")
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    state:draw()
    love.graphics.setCanvas()
    love.graphics.pop()
    pixels = scope:own(canvas:newImageData()):getString()
  end, debug.traceback)
  lg.print, lg.printf = savedPrint, savedPrintf
  state:dispose()
  if not ok then
    error(err, 0)
  end
  local copy = table.concat(rendered, "\n"):lower()
  Assert.isTrue(
    copy:find("matching", 1, true) ~= nil,
    "the blocked wait names its matching-ROM remedy, got: " .. table.concat(rendered, "\n")
  )
  Assert.isTrue(
    copy:find("drop", 1, true) ~= nil,
    "the blocked wait tells the player how to supply the file, got: " .. table.concat(rendered, "\n")
  )
  Assert.isTrue(pixels ~= nil, "the blocked wait still paints its animated stage")
end

function T.failed_pair_adoption_releases_staged_art_without_half_published_sprites(scope)
  local good = startupPairCacheFs(5, "heartgold")
  local followerPath = "assets/generated/startup/loader/pairs/5/follower.png"
  local bad = {
    loadLua = good.loadLua,
    exists = good.exists,
    read = function(_, path)
      if path == followerPath then
        return nil
      end
      return good.read(_, path)
    end,
  }
  local presentation = Presentation.new({
    versionId = "heartgold",
    width = WIDTH,
    height = HEIGHT,
    pairIndex = 5,
    random = function()
      return 0.25
    end,
  })
  scope:own({
    release = function()
      presentation:dispose()
    end,
  })
  local originalNewImage = love.graphics.newImage
  local staged = {}
  local ok, err = xpcall(function()
    love.graphics.newImage = function(...)
      local image = originalNewImage(...)
      staged[#staged + 1] = image
      return image
    end
    local adopted, failure = presentation:adoptGeneratedAssets(bad)
    Assert.isFalse(adopted, "a missing follower atlas fails adoption")
    Assert.notNil(failure, "a missing follower atlas carries a diagnosis")
    Assert.isNil(presentation.hero, "no half-published hero survives a failed adoption")
    Assert.isNil(presentation.follower, "no half-published follower survives a failed adoption")
  end, debug.traceback)
  love.graphics.newImage = originalNewImage
  if not ok then
    error(err, 0)
  end
  Assert.equal(#staged, 1, "only the hero atlas stages before the follower read fails")
  Assert.throws(function()
    staged[1]:getWidth()
  end, "the staged hero image is released on failure")
  local pixels = renderStage(scope, presentation)
  Assert.isTrue(cornerAlpha(pixels) > 0, "the stage stays drawable after a failed adoption")
  Assert.isTrue(presentation:adoptGeneratedAssets(good), "a later read of both atlases still adopts")
  Assert.notNil(presentation.hero, "the retried adoption publishes the hero")
  Assert.notNil(presentation.follower, "the retried adoption publishes the follower")
end

function T.walker_phase_survives_adoption_and_resize_across_all_choices(scope)
  local presentation = Presentation.new({
    versionId = "heartgold",
    width = WIDTH,
    height = HEIGHT,
    pairIndex = 5,
    random = function()
      return 0.25
    end,
  })
  scope:own({
    release = function()
      presentation:dispose()
    end,
  })
  presentation.elapsed = 0.05
  Assert.isTrue(
    presentation:adoptGeneratedAssets(startupPairCacheFs(5, "heartgold")),
    "the chosen pair adopts its two transparent atlases"
  )
  local heroBefore = presentation:_frameIndex("hero")
  local followerBefore = presentation:_frameIndex("follower")
  Assert.notNil(heroBefore, "adoption preserves the hero walk position")
  Assert.notNil(followerBefore, "adoption preserves the follower walk position")
  presentation:resize(360, 640)
  Assert.equal(presentation.elapsed, 0.05, "resize never touches the walk clock")
  Assert.equal(presentation:_frameIndex("hero"), heroBefore, "resize never resets the hero walk position")
  Assert.equal(presentation:_frameIndex("follower"), followerBefore, "resize never resets the follower walk position")
  presentation:update(1 / 30)
  Assert.near(presentation.elapsed, 0.05 + 1 / 30, 1e-9, "the walk clock keeps advancing after resize")
  local resized = scope:own(love.graphics.newCanvas(360, 640))
  love.graphics.push("all")
  love.graphics.setCanvas(resized)
  love.graphics.clear(0, 0, 0, 0)
  presentation:draw()
  love.graphics.setCanvas()
  love.graphics.pop()
  local shared = scope:own(love.graphics.newCanvas(WIDTH, HEIGHT))
  for pairIndex = 1, 32 do
    local choice = Presentation.new({
      versionId = "heartgold",
      width = WIDTH,
      height = HEIGHT,
      pairIndex = pairIndex,
      random = function()
        return 0.1
      end,
    })
    Assert.isTrue(
      choice:adoptGeneratedAssets(startupPairCacheFs(pairIndex, "heartgold")),
      "walker choice " .. pairIndex .. " adopts its two transparent atlases"
    )
    love.graphics.push("all")
    love.graphics.setCanvas(shared)
    love.graphics.clear(0, 0, 0, 0)
    choice:draw()
    love.graphics.setCanvas()
    love.graphics.pop()
    choice:dispose()
  end
end

return GraphicsSmoke.suite(T, { tags = { "startup" } })
