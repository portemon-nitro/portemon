-- Native and adaptive word editor presentation: every mode draws both
-- native panes with visible source content, the cursor blink follows its
-- fixed-step period, every display topology renders without error,
-- drawing allocates nothing, an idle pointer-cancel stays inert, and
-- every per-open lease releases exactly once. The catalog, data, and
-- presentation compile from the real dump and stage through the real
-- writer into an isolated generation, the factory, controller, and screen
-- stay production, fonts and window frames come from the prepared field
-- scopes, and only GPU images are realized from staged bytes. No ROM
-- text is asserted and no draw call is attempted until the harness owns
-- graphics.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldInput = require("libs.hgss.src.field.FieldInput")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
local RomImporter = require("romdump.src.source.RomImporter")
local RomSourcePath = require("tests.rom.support.RomSourcePath")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local NULL_WORD = 0xFFFF
local READY_BUDGET = 240
local SETTLE_TICKS = 12
local BLINK_HALF_PERIOD = 16
local BLINK_FULL_PERIOD = 32
local DUAL_VISIBLE_MINIMUM = 512
local DUAL_HALF_MINIMUM = 64
local SINGLE_VISIBLE_MINIMUM = 512
local TINY_VISIBLE_MINIMUM = 64

-- Loads a word editor module that does not exist yet at this baseline.
-- The failure names the missing behaviour instead of surfacing as a
-- suite load error, so the pre-implementation red stays attributable.
---@param moduleName string
---@param missingMessage string
---@return table
local function requireFeature(moduleName, missingMessage)
  local ok, mod = pcall(require, moduleName)
  if not ok then
    error(missingMessage, 0)
  end
  assert(type(mod) == "table", missingMessage)
  return mod --[[@as table]]
end

---@param context table?
---@return string[] versionIds
local function readyVersionIds(context)
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      versions[#versions + 1] = versionId
    end
  end
  if #versions == 0 then
    context:skip("the editor presentation needs a ready user-owned dump")
  end
  return versions
end

---@param name string
---@return table topology, integer width, integer height
local function makeTopology(name)
  if name == "dual" then
    return ScreenTopology.dualDisplay(
      { id = "world", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "aux", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
    ),
      512,
      384
  end
  local width, height = name == "wide" and 1000 or 600, name == "wide" and 600 or 1000
  if name == "native" then
    width, height = 512, 384
  elseif name == "tiny" then
    width, height = 200, 140
  end
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = true,
    role = "world",
  }),
    width,
    height
end

---@param topology table
---@param width integer
---@param height integer
---@param signature string
---@return table measurement
local function measurement(topology, width, height, signature)
  return { width = width, height = height, topology = topology, pixelRatio = 1, signature = signature }
end

-- Compiles the editor data and presentation bundles from the real dump.
-- Returns the bundles plus a release function for the open reader.
---@param versionId string
---@return table data, table presentation, fun()
local function compileBundles(versionId)
  local Compiler = requireFeature(
    "romdump.src.digest.ui.EasyChatCompiler",
    versionId .. " has no shared word editor producer yet: the editor presentation cannot compile"
  )
  local MonCatalogCompiler = require("romdump.src.digest.mons.MonCatalogCompiler")
  local ItemFixture = require("libs.items.tests.item_fixture")
  local MonCatalog = require("libs.mons.src.MonCatalog")
  local romFs, source = RomSourcePath.openReader(versionId)
  Assert.notNil(romFs, versionId .. " opens its source reader")
  local monRoot = assert(
    MonCatalogCompiler.compileCatalog(romFs, { versionId = versionId }),
    versionId .. " compiles its mon catalog for the species join"
  )
  local monCatalog = MonCatalog.new(monRoot, ItemFixture.makeCatalog())
  local data, dataErr = Compiler.compileData(romFs, versionId, monCatalog)
  Assert.notNil(data, versionId .. " compiles its editor data: " .. tostring(dataErr))
  local presentation, presentationErr = Compiler.compilePresentation(romFs, versionId, assert(data))
  Assert.notNil(presentation, versionId .. " compiles its editor presentation: " .. tostring(presentationErr))
  return assert(data),
    assert(presentation),
    function()
      romFs:close()
      if source ~= nil then
        source:release()
      end
    end
end

-- Stages one bundle scope through its real writer and publication
-- ownership into an isolated cache generation.
---@param cache table
---@param kind string
---@param jobKey string
---@param stageFn fun(artifact: table, bundle: table)
---@param bundle table
local function stageBundle(cache, kind, jobKey, stageFn, bundle)
  local artifact = PreparedArtifact.new({
    cacheFs = cache,
    generationId = "test-generation",
    epoch = 1,
    kind = kind,
    key = "global",
    jobKey = jobKey,
    stageName = "editor-presentation-smoke",
  })
  stageFn(artifact, bundle)
  artifact:finishSuccess({ marker = "editor-presentation-smoke" })
  Assert.isTrue(
    artifact:publish({
      generationId = "test-generation",
      epoch = 1,
      kind = kind,
      key = "global",
      jobKey = jobKey,
    }),
    "the " .. kind .. " scope publishes its isolated generation"
  )
end

-- Collects every image path a manifest references, so the smoke can prove
-- the reference closure resolves to staged bytes.
---@param node table
---@param out table<string, table>
local function collectImagePaths(node, out)
  if type(node) ~= "table" then
    return
  end
  if type(node.image) == "string" then
    out[node.image] = node
    return
  end
  for key, value in pairs(node) do
    if key ~= "image" and type(value) == "table" then
      collectImagePaths(value, out)
    end
  end
end

-- Realizes every manifest image from staged bytes. A referenced path with
-- no staged payload fails here: the closure is exact, never a fallback.
---@param scope table
---@param cache table
---@param manifest table
---@return table<string, table> images
local function realizeImages(scope, cache, manifest)
  local paths = {}
  collectImagePaths(manifest, paths)
  Assert.isTrue(next(paths) ~= nil, "the presentation manifest references its images")
  local images = {}
  for path in pairs(paths) do
    local bytes = cache:read(path)
    Assert.notNil(bytes, "the staged scope carries image " .. path)
    local data = scope:own(love.image.newImageData(love.filesystem.newFileData(assert(bytes), path)))
    images[path] = scope:own(love.graphics.newImage(data))
  end
  return images
end

-- Opens one production editor screen over the staged generation with a
-- recording per-open lease. Every composed owner stays real except the
-- GPU image bundle, which the lease carries ready-made so no pool or
-- worker enters the smoke.
---@param scope table
---@param versionId string
---@param topologyName string
---@param request table
---@return table rig
local function openScreen(scope, versionId, topologyName, request)
  local Catalog = requireFeature(
    "libs.hgss.src.ui.EasyChatCatalog",
    versionId .. " has no shared word editor catalog yet: the editor presentation cannot resolve words"
  )
  local State = requireFeature(
    "libs.hgss.src.save.EasyChatState",
    versionId .. " has no shared word editor state yet: the editor presentation cannot snapshot availability"
  )
  local Composition = requireFeature(
    "game.hgss.src.easychat.EasyChatComposition",
    versionId .. " has no shared word editor factory yet: the editor presentation cannot open"
  )
  local data, presentation, releaseBundles = compileBundles(versionId)
  local cache = CacheFs.forVersion(versionId, FakeCache.new())
  local Writer = requireFeature(
    "romdump.src.digest.ui.EasyChatCacheWriter",
    versionId .. " has no shared word editor publisher yet: the editor presentation cannot stage"
  )
  stageBundle(cache, "easy-chat-data", "easy-chat-data:global", Writer.stageData, data)
  stageBundle(cache, "easy-chat", "easy-chat:global", Writer.stagePresentation, presentation)
  local Cache = requireFeature(
    "libs.assets.src.EasyChatCache",
    versionId .. " has no shared word editor cache yet: the staged generation cannot load"
  )
  local catalogData = Cache.loadCatalog(cache)
  local manifest = Cache.loadManifest(cache)
  local catalog = Catalog.new(assert(catalogData))
  local images = realizeImages(scope, cache, assert(manifest))
  local fontCache = CacheFs.forVersion(versionId)
  local uiManifest = assert(fontCache:loadLua(FieldUiAssetCache.manifestPath()))

  local topology, width, height = makeTopology(topologyName)
  local releases = 0
  local lease = {
    prepare = function()
      return { kind = "ready", assets = { manifest = manifest, images = images } }
    end,
    release = function()
      releases = releases + 1
    end,
  }
  local runtime = {
    easyChatCatalog = catalog,
    easyChatState = State.restore(nil, "english", catalog),
    dexKnowledge = {
      isSeen = function()
        return false
      end,
    },
    eventState = {
      isFlagSet = function()
        return false
      end,
    },
    playerData = { options = {} },
    cacheFs = fontCache,
    presentationDisplay = measurement(topology, width, height, topologyName),
    input = FieldInput.new(),
    audio = {
      play = function() end,
    },
    uiManifest = uiManifest,
    presentationOverrides = {},
    bindEasyChatPreparation = function(_, acquire)
      assert(acquire ~= nil, "the preparation binding carries its acquisition")
      return 1
    end,
    unbindEasyChatPreparation = function() end,
    _easyChatPreparation = {
      id = 1,
      acquire = function()
        return lease
      end,
    },
  }
  local screen = Composition.open(runtime, request)
  return {
    screen = screen,
    images = images,
    width = width,
    height = height,
    releases = function()
      return releases
    end,
    closeBundles = releaseBundles,
  }
end

-- Draws one ready screen frame through its own plan onto a real canvas.
---@param scope table
---@param rig table
---@param canvas table
---@return table imageData
local function renderFrame(scope, rig, canvas)
  local status = rig.screen:status()
  local plan = assert(status.presentation, "the editor status publishes its plan")
  Assert.equal(status.uiInput, "easy-chat", "the ready editor owns the display input key")
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 1)
  love.graphics.setColor(1, 1, 1, 1)
  plan.render({ graphics = love.graphics, images = rig.images }, status, plan)
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

---@param scope table
---@param rig table
---@return table imageData
local function draw(scope, rig)
  return renderFrame(scope, rig, scope:own(love.graphics.newCanvas(rig.width, rig.height)))
end

-- Counts pixels that differ from the black backdrop beyond noise.
---@param imageData table
---@return integer visible
local function visiblePixels(imageData)
  local pixels = imageData:getString()
  local count = 0
  for index = 1, #pixels, 4 do
    local red, green, blue = pixels:byte(index, index + 2)
    if math.abs(red) > 8 or math.abs(green) > 8 or math.abs(blue) > 8 then
      count = count + 1
    end
  end
  return count
end

-- Counts visible pixels in the upper and lower canvas halves for the
-- stacked dual display, where each half carries one native surface.
---@param imageData table
---@param width integer
---@param height integer
---@return integer upper, integer lower
local function halfPixels(imageData, width, height)
  local pixels = imageData:getString()
  local upper, lower = 0, 0
  local stride = width * 4
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local base = y * stride + x * 4 + 1
      local red, green, blue = pixels:byte(base, base + 2)
      if math.abs(red) > 8 or math.abs(green) > 8 or math.abs(blue) > 8 then
        if y < height / 2 then
          upper = upper + 1
        else
          lower = lower + 1
        end
      end
    end
  end
  return upper, lower
end

-- Advances one fixed tick and draws the resulting frame.
---@param scope table
---@param rig table
---@return table imageData
local function stepDraw(scope, rig)
  rig.screen:updateFixed({})
  return draw(scope, rig)
end

-- Counts love allocation calls during one draw: drawing must realize
-- nothing and prepare nothing.
---@param fn fun()
---@return table<string, integer>
local function countAllocationsDuring(fn)
  local names = { "newImage", "newImageData", "newCanvas", "newQuad", "newMesh", "newShader" }
  local originals = {}
  local counts = {}
  for _, name in ipairs(names) do
    originals[name] = love.graphics[name]
    counts[name] = 0
  end
  for _, name in ipairs(names) do
    love.graphics[name] = function(...)
      counts[name] = counts[name] + 1
      return originals[name](...)
    end
  end
  local ok, err = pcall(fn)
  for _, name in ipairs(names) do
    love.graphics[name] = originals[name]
  end
  if not ok then
    error(err, 0)
  end
  return counts
end

---@param rig table
local function waitReady(rig)
  for _ = 1, READY_BUDGET do
    local status = rig.screen:status()
    if status.preparing == false and status.uiInput == "easy-chat" then
      return
    end
    rig.screen:updateFixed({})
  end
  error("the editor never becomes ready for input", 0)
end

---@param rig table
local function settleEntry(rig)
  for _ = 1, SETTLE_TICKS do
    rig.screen:updateFixed({})
  end
end

function T.composition_draws_both_panes_across_modes(scope, context)
  for _, versionId in ipairs(readyVersionIds(context)) do
    for _, mode in ipairs({ 0, 1, 2 }) do
      local request = mode == 2
          and {
            mode = 2,
            message = { bank = 0, number = 0, words = { NULL_WORD, NULL_WORD } },
            promptId = 0,
            alwaysConfirm = false,
            inputMode = "buttons",
          }
        or { mode = mode, words = { NULL_WORD, NULL_WORD }, promptId = 0, alwaysConfirm = false, inputMode = "buttons" }
      local rig = openScreen(scope, versionId, "dual", request)
      waitReady(rig)
      settleEntry(rig)
      local frame = draw(scope, rig)
      Assert.isTrue(
        visiblePixels(frame) >= DUAL_VISIBLE_MINIMUM,
        versionId .. " mode " .. mode .. " composition draws visible content"
      )
      -- Both native panes carry content: the information surface and the
      -- controls surface are both present, never one flattened pane.
      local upper, lower = halfPixels(frame, rig.width, rig.height)
      Assert.isTrue(upper >= DUAL_HALF_MINIMUM, versionId .. " mode " .. mode .. " draws its upper pane")
      Assert.isTrue(lower >= DUAL_HALF_MINIMUM, versionId .. " mode " .. mode .. " draws its lower pane")
      rig.screen:dispose()
      Assert.equal(rig.releases(), 1, versionId .. " mode " .. mode .. " releases its lease exactly once")
      rig.closeBundles()
    end
  end
end

function T.cursor_blink_follows_its_fixed_step_period(scope, context)
  for _, versionId in ipairs(readyVersionIds(context)) do
    local rig = openScreen(scope, versionId, "dual", {
      mode = 0,
      words = { NULL_WORD, NULL_WORD },
      promptId = 0,
      alwaysConfirm = false,
      inputMode = "buttons",
    })
    waitReady(rig)
    settleEntry(rig)
    local settled = draw(scope, rig):getString()
    for _ = 1, BLINK_HALF_PERIOD do
      rig.screen:updateFixed({})
    end
    local halfPeriod = draw(scope, rig):getString()
    Assert.isTrue(halfPeriod ~= settled, versionId .. " the cursors blink across sixteen updates")
    for _ = 1, BLINK_HALF_PERIOD do
      rig.screen:updateFixed({})
    end
    local fullPeriod = draw(scope, rig):getString()
    Assert.equal(fullPeriod, settled, versionId .. " the blink loops back after thirty-two updates")
    Assert.equal(BLINK_HALF_PERIOD * 2, BLINK_FULL_PERIOD, "the smoke names its blink period honestly")
    rig.screen:dispose()
    Assert.equal(rig.releases(), 1, versionId .. " the timing screen releases its lease exactly once")
    rig.closeBundles()
  end
end

function T.adaptive_topologies_render_without_error(scope, context)
  for _, versionId in ipairs(readyVersionIds(context)) do
    for _, topologyName in ipairs({ "wide", "tall", "native", "tiny" }) do
      local rig = openScreen(scope, versionId, topologyName, {
        mode = 1,
        words = { NULL_WORD, NULL_WORD },
        promptId = 0,
        alwaysConfirm = false,
        inputMode = "buttons",
      })
      waitReady(rig)
      settleEntry(rig)
      local frame = stepDraw(scope, rig)
      local minimum = topologyName == "tiny" and TINY_VISIBLE_MINIMUM or SINGLE_VISIBLE_MINIMUM
      Assert.isTrue(
        visiblePixels(frame) >= minimum,
        versionId .. " " .. topologyName .. " keeps visible controls without cropping them away"
      )
      rig.screen:dispose()
      Assert.equal(rig.releases(), 1, versionId .. " " .. topologyName .. " releases its lease exactly once")
      rig.closeBundles()
    end
  end
end

function T.drawing_allocates_nothing_and_idle_cancel_stays_inert(scope, context)
  for _, versionId in ipairs(readyVersionIds(context)) do
    local rig = openScreen(scope, versionId, "dual", {
      mode = 0,
      words = { NULL_WORD, NULL_WORD },
      promptId = 0,
      alwaysConfirm = false,
      inputMode = "buttons",
    })
    waitReady(rig)
    settleEntry(rig)
    -- One warm-up draw materializes the borrowed text owners' lazy glyph
    -- caches; the steady-state draw below must then realize nothing.
    draw(scope, rig)
    local canvas = scope:own(love.graphics.newCanvas(rig.width, rig.height))
    local counts = countAllocationsDuring(function()
      renderFrame(scope, rig, canvas)
    end)
    for name, count in pairs(counts) do
      Assert.equal(count, 0, versionId .. " drawing never calls love.graphics." .. name)
    end
    -- An idle pointer cancel changes nothing and reports nothing: no
    -- phantom activation reaches the composition.
    local before = rig.screen:status().view.level
    rig.screen:cancelPointerCapture()
    rig.screen:updateFixed({})
    Assert.equal(rig.screen:status().view.level, before, versionId .. " an idle cancel never activates")
    Assert.isNil(rig.screen:takeResult(), versionId .. " an idle cancel publishes no result")
    rig.screen:dispose()
    Assert.equal(rig.releases(), 1, versionId .. " the allocation screen releases its lease exactly once")
    rig.closeBundles()
  end
end

-- Records every token stream a text owner draws, so the content gate below
-- proves labels, words, prompts, and expanded sentences reach the real
-- draw calls at every editor level instead of only counting lit pixels.
---@param text table borrowed text renderer under observation
---@param counts table<string, integer> per-owner draw tallies
---@param key string tally slot for this owner
local function recordDraws(text, counts, key)
  if text == nil or type(text.drawLineWithPalette) ~= "function" then
    return
  end
  local original = text.drawLineWithPalette
  text.drawLineWithPalette = function(self, tokens, x, y, palette)
    if type(tokens) == "table" and #tokens > 0 then
      counts[key] = (counts[key] or 0) + 1
    end
    return original(self, tokens, x, y, palette)
  end
end

---@param rig table open editor rig
---@return string editor level
local function editorLevel(rig)
  return rig.screen:status().view.level
end

---@param rig table open editor rig
---@param want string editor level
---@param budget integer fixed-tick budget
local function waitLevel(rig, want, budget)
  for _ = 1, budget do
    if editorLevel(rig) == want then
      return
    end
    rig.screen:updateFixed({})
  end
  error("the editor never reaches " .. want .. " (" .. tostring(editorLevel(rig)) .. ")", 0)
end

-- Scans the authored browser for the first group that opens a word list:
-- empty groups reject in place, so the scan steps past them.
---@param rig table open editor rig
local function openFirstList(rig)
  rig.screen:updateFixed({ { type = "confirm" } })
  waitLevel(rig, "categories", 20)
  for _ = 1, 12 do
    rig.screen:updateFixed({ { type = "confirm" } })
    for _ = 1, 30 do
      rig.screen:updateFixed({})
      if editorLevel(rig) == "list" then
        return
      end
    end
    if editorLevel(rig) ~= "categories" then
      return
    end
    rig.screen:updateFixed({ { type = "navigate", direction = "down" } })
  end
  error("the browser never reaches a word list", 0)
end

-- Moves focus to CONFIRM from any composition focus without wrapping.
---@param rig table open editor rig
local function focusConfirmButton(rig)
  for _ = 1, 5 do
    rig.screen:updateFixed({ { type = "navigate", direction = "down" } })
  end
  rig.screen:updateFixed({ { type = "navigate", direction = "up" } })
end

-- The committed bundle carries every static token the renderer needs:
-- button labels on composition, category and initial labels plus tab
-- labels in the browser, word fragments in the list, prompt text over
-- the confirmation, and the expanded sentence for the zero-field
-- template. The two mode-0 journeys share one rig: composition draws,
-- then the browser journey covers list, categories, and prompt without
-- paying a second ROM compile and stage per version.
function T.committed_bundle_tokens_reach_draw_calls(scope, context)
  for _, versionId in ipairs(readyVersionIds(context)) do
    do
      local rig = openScreen(scope, versionId, "dual", {
        mode = 0,
        words = { NULL_WORD, NULL_WORD },
        promptId = 0,
        alwaysConfirm = false,
        inputMode = "buttons",
      })
      waitReady(rig)
      settleEntry(rig)
      local assets = assert(rig.screen:status().assets, versionId .. " commits its bundle before drawing")
      local text0 = assert(assets.text0, versionId .. " commits its list text owner")
      local text1 = assert(assets.text1, versionId .. " commits its sentence text owner")
      local text4 = assert(assets.text4, versionId .. " commits its button text owner")
      Assert.notNil(assets.menu, versionId .. " commits its per-open menu slice")
      Assert.notNil(assets.interface, versionId .. " commits its interface text")
      local counts = {}
      recordDraws(text0, counts, "text0")
      recordDraws(text1, counts, "text1")
      recordDraws(text4, counts, "text4")
      draw(scope, rig)
      Assert.isTrue((counts.text4 or 0) > 0, versionId .. " composition draws its button labels")
      openFirstList(rig)
      counts.text0, counts.text1, counts.text4 = nil, nil, nil
      draw(scope, rig)
      Assert.isTrue((counts.text0 or 0) > 0, versionId .. " the word list draws its word fragments")
      rig.screen:updateFixed({ { type = "cancel" } })
      waitLevel(rig, "categories", 30)
      counts.text0, counts.text1, counts.text4 = nil, nil, nil
      draw(scope, rig)
      Assert.isTrue((counts.text0 or 0) > 0, versionId .. " categories draw their labels")
      Assert.isTrue((counts.text4 or 0) > 0, versionId .. " the browser draws its tab labels")
      rig.screen:updateFixed({ { type = "cancel" } })
      waitLevel(rig, "composition", 30)
      focusConfirmButton(rig)
      rig.screen:updateFixed({ { type = "confirm" } })
      waitLevel(rig, "prompt", 20)
      counts.text0, counts.text1, counts.text4 = nil, nil, nil
      draw(scope, rig)
      Assert.isTrue((counts.text1 or 0) > 0, versionId .. " the prompt draws its prompt text")
      rig.screen:dispose()
      Assert.equal(rig.releases(), 1, versionId .. " the shared screen releases its lease exactly once")
      rig.closeBundles()
    end
    do
      local rig = openScreen(scope, versionId, "dual", {
        mode = 2,
        message = { bank = 4, number = 5, words = { NULL_WORD, NULL_WORD } },
        promptId = 0,
        alwaysConfirm = false,
        inputMode = "buttons",
      })
      waitReady(rig)
      settleEntry(rig)
      local assets = assert(rig.screen:status().assets, versionId .. " commits its bundle before drawing")
      local counts = {}
      recordDraws(assert(assets.text0), counts, "text0")
      recordDraws(assert(assets.text1), counts, "text1")
      recordDraws(assert(assets.text4), counts, "text4")
      draw(scope, rig)
      Assert.isTrue((counts.text1 or 0) > 0, versionId .. " the sentence strip draws its expanded template")
      rig.screen:dispose()
      Assert.equal(rig.releases(), 1, versionId .. " the sentence screen releases its lease exactly once")
      rig.closeBundles()
    end
  end
end

local suite = GraphicsSmoke.suite(T, { tags = { "easychat" } })
suite.metadata.capabilities = { "graphics", "rom_dump" }
suite.metadata.derivedAssets = { "field-font:global", "field-ui:global" }
return suite
