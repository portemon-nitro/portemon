-- Presented-battle coverage through the real production services: the
-- field-local envelope builds its preparation services with the live host
-- graphics namespace (never the test-only image map), the real battle
-- screen prepares through them against the staged cache, and production
-- frames render to a canvas with real staged pixels. A second leg forces
-- a preparation failure and proves the deterministic failed state with
-- context: no raise, no held cue mistaken for success, no blank success.

local Assert = require("tests.support.Assert")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local BattlePresentationManifestFixture = require("tests.support.BattlePresentationManifestFixture")
local BattlePresentationSchema = require("libs.assets.src.battle.BattlePresentationSchema")
local BattlePresentationModel = require("game.hgss.src.battle.BattlePresentationModel")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldBattlePresentation = require("game.hgss.src.field.FieldBattlePresentation")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldWindowRenderer = require("libs.hgss.src.ui.FieldWindowRenderer")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local ImageAssetPool = require("libs.hgss.src.presentation.ImageAssetPool")
local MonCache = require("libs.assets.src.MonCache")
local RomImporter = require("romdump.src.source.RomImporter")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local SCENE_KEY = "general/grass/day"
local SAD_SCENE_KEY = "city/sand/night"
local LEAD_SPECIES = "CHIKORITA"
local FOE_SPECIES = "RATTATA"
local TICK = 1 / 60
local DRIVE_BUDGET = 1200

local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      versions[#versions + 1] = versionId
    end
  end
  return versions
end

local function assertStagedManifest(manifest, context)
  Assert.equal(
    manifest.schema,
    BattlePresentationSchema.MANIFEST_SCHEMA,
    context .. " stages the current catalog schema"
  )
  Assert.isTrue(
    type(manifest.battlefield.slots) == "table" and #manifest.battlefield.slots == 6,
    context .. " stages all source side-type geometry"
  )
  Assert.isTrue(
    type(manifest.hud.patchSpans.playerDoubleMode) == "table" and #manifest.hud.patchSpans.playerDoubleMode == 2,
    context .. " stages both native double-player health-box modes"
  )
  Assert.isTrue(
    type(manifest.pictures.selectors) == "table" and next(manifest.pictures.selectors) ~= nil,
    context .. " stages source picture selectors"
  )
end

local function compactMeasurement()
  return {
    width = 256,
    height = 192,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 256, height = 192 },
      touch = true,
      role = "world",
    }),
    pixelRatio = 1,
    signature = "battle-production-services:compact",
  }
end

local function quantize(channel)
  return math.floor(channel * 255 + 0.5)
end

local function imageDataDigest(data)
  local hash = 2166136261
  for y = 0, data:getHeight() - 1 do
    for x = 0, data:getWidth() - 1 do
      local red, green, blue, alpha = data:getPixel(x, y)
      for _, channel in ipairs({ red, green, blue, alpha }) do
        hash = (hash * 16777619 + quantize(channel)) % 4294967296
      end
    end
  end
  return hash
end

-- Counts host pixels covered by any opaque sample.
---@param data table readable pixels under census
---@param rect table host rectangle under census
---@return integer covered pixels
local function countInk(data, rect)
  local count = 0
  for y = rect.y, rect.y + rect.height - 1 do
    for x = rect.x, rect.x + rect.width - 1 do
      local _, _, _, alpha = data:getPixel(x, y)
      if alpha > 0 then
        count = count + 1
      end
    end
  end
  return count
end

-- Counts host pixels whose quantized color exactly matches the given
-- 0..255 triple with a fully opaque sample.
---@param data table readable pixels under census
---@param rect table host rectangle under census
---@param want integer[] exact 0..255 triple under census
---@return integer exact matches
local function countColor(data, rect, want)
  local count = 0
  for y = rect.y, rect.y + rect.height - 1 do
    for x = rect.x, rect.x + rect.width - 1 do
      local red, green, blue, alpha = data:getPixel(x, y)
      if
        quantize(alpha) == 255
        and quantize(red) == want[1]
        and quantize(green) == want[2]
        and quantize(blue) == want[3]
      then
        count = count + 1
      end
    end
  end
  return count
end

local function hostRect(frame, local_)
  return { x = frame.x + local_.x, y = frame.y + local_.y, width = local_.width, height = local_.height }
end

-- The production field composition borrows its battle text and window
-- services over the shared field renderers: the staged field font draws
-- the wording and the staged frame strip borders the docks.
---@param scope table test-owned graphics scope
---@param cacheFs table versioned derived cache
---@param versionId string ready game version under test
---@return table text services
---@return table window services
local function productionDrawServices(scope, cacheFs, versionId)
  local uiManifest =
    assert(cacheFs:loadLua(FieldUiAssetCache.manifestPath()), versionId .. " loads its field-UI manifest")
  Assert.isTrue(FieldUiAssetCache.validateManifest(uiManifest), versionId .. " carries a valid field-UI manifest")
  local textRenderer = scope:own(FieldTextRenderer.new({ cacheFs = cacheFs }))
  local windowRenderer = scope:own(FieldWindowRenderer.new({ cacheFs = cacheFs, manifest = uiManifest }))
  local frames = assert(uiManifest.dialogueFrames, versionId .. " carries dialogue frames")
  Assert.notNil(frames.frameTiles[0], versionId .. " carries the default frame strip")
  local text = { fontDef = textRenderer.fontDef }
  function text.drawText(content, x, y)
    return textRenderer:drawText(content, x, y)
  end
  if type(textRenderer.drawTextWithPalette) == "function" then
    function text.drawTextWithPalette(content, x, y, palette)
      return textRenderer:drawTextWithPalette(content, x, y, palette)
    end
  end
  function text.measure(content)
    return { width = textRenderer:textWidth(content), height = 16 }
  end
  local windows = {}
  local function frameIndexOf(frameKey)
    if frameKey == nil or frameKey == "default" then
      return 0
    end
    error("unknown battle frame: " .. tostring(frameKey), 0)
  end
  function windows.drawWindow(box, frameKey, background)
    return windowRenderer:drawWindow(box, frameIndexOf(frameKey), background)
  end
  function windows.drawApplicationFrame(box, frameKey)
    return windowRenderer:drawApplicationFrame(box, frameIndexOf(frameKey))
  end
  return text, windows
end

local function recordingAudio()
  local audio = { plays = {} }
  function audio.play(name)
    audio.plays[#audio.plays + 1] = name
    return true
  end
  return audio
end

local function recordingText()
  local text = { draws = {} }
  function text.measure(content)
    return { width = 8 * #tostring(content), height = 16 }
  end
  function text.drawText(content, x, y)
    text.draws[#text.draws + 1] = { content = content, x = x, y = y }
  end
  return text
end

local function recordingWindows()
  local windows = { calls = {} }
  function windows.drawWindow(box, frameKey, background)
    windows.calls[#windows.calls + 1] = { box = box, frame = frameKey, background = background }
  end
  function windows.drawApplicationFrame(box, frameKey)
    windows.calls[#windows.calls + 1] = { box = box, frame = frameKey }
  end
  return windows
end

-- A cache view hiding one staged path so preparation fails
-- deterministically no matter how the corpus grows around it.
---@param real table versioned derived cache under wrapping
---@param hiddenPath string cache-relative staged path reported as missing
---@return table cache view delegating every other read
local function hidingCacheFs(real, hiddenPath)
  local wrapper = { versionId = real.versionId }
  function wrapper.read(_, path)
    if path == hiddenPath then
      return nil
    end
    return real:read(path)
  end
  function wrapper.loadLua(_, path)
    return real:loadLua(path)
  end
  return wrapper
end

---@param descriptor table launch descriptor under building
---@return table fresh presentation port behind a fresh production screen
local function buildPort(envelope, descriptor)
  return envelope:factory()(descriptor)
end

---@return table stub launch host holding its phase with recorded notifications
local function stubHost()
  local host = { notifies = {} }
  function host.status()
    return { phase = "leaving" }
  end
  function host.advance() end
  function host.submit(_)
    return true
  end
  function host.notify(event)
    host.notifies[#host.notifies + 1] = event
  end
  return host
end

local function moveChoice(id, name, pp, maxPp, moveType, slot)
  return {
    role = "move",
    id = id,
    enabled = true,
    display = { name = name, pp = pp, maxPp = maxPp, type = moveType },
    choice = { kind = "attack", payload = { moveSlot = slot, target = { kind = "position", position = 2 } } },
  }
end

-- Resolves one staged exact portrait selector for the species and facing
-- through the derived cache, preferring the plain male cell: demands
-- name exact canonical selectors only, so the synthetic opening packet
-- must carry them (never shorthand) for the demand to grow and the
-- send-out cue to resolve through the production drawables.
---@param cacheFs table versioned derived cache under inspection
---@param species string staged species under lookup
---@param facing string "back" for own sprites, "front" for foes
---@return string exact canonical portrait selector with a ready staged page
local function stagedPortraitSelector(cacheFs, species, facing)
  local portraits =
    assert(cacheFs:loadLua(MonCache.portraitManifestPath()), "the staged cache carries its portrait manifest")
  local entries = assert(portraits.entries, "the staged cache plans its portrait entries")
  local fallback = nil
  local keys = {}
  for selector in pairs(entries) do
    keys[#keys + 1] = selector
  end
  table.sort(keys)
  for _, selector in ipairs(keys) do
    local entry = entries[selector]
    local isBack = selector:sub(-5) == "/back"
    if
      selector:sub(1, #species + 1) == species .. "/"
      and ((facing == "back") == isBack)
      and type(entry) == "table"
      and type(entry.pageId) == "number"
      and MonCache.isPageReady(
        cacheFs,
        "portraits",
        entry.pageId,
        cacheFs:read(MonCache.pageMarkerPath("portraits", entry.pageId))
      )
    then
      if selector:find("/male/plain", 1, true) ~= nil then
        return selector
      end
      fallback = fallback or selector
    end
  end
  assert(fallback ~= nil, "the staged cache stages a ready " .. facing .. " portrait for " .. species)
  return fallback --[[@as string]]
end

local function openingPacket(launchId, portraits)
  local after = {
    own = {
      {
        combatant = 0,
        side = 1,
        species = LEAD_SPECIES,
        form = 0,
        selector = "back",
        portraitSelector = portraits.leadBack,
        name = LEAD_SPECIES,
        level = 9,
        hp = 30,
        maxHp = 30,
        experience = 120,
      },
      {
        combatant = 1,
        side = 1,
        species = LEAD_SPECIES,
        form = 0,
        selector = "back",
        portraitSelector = portraits.leadBack,
        name = LEAD_SPECIES,
        level = 9,
        hp = 28,
        maxHp = 28,
        experience = 100,
      },
    },
    foes = {
      {
        combatant = 2,
        side = 2,
        species = FOE_SPECIES,
        form = 0,
        selector = "front",
        portraitSelector = portraits.foeFront,
        name = FOE_SPECIES,
        level = 3,
        hp = 12,
        maxHp = 12,
      },
    },
  }
  local options = {
    actors = {
      {
        kind = "command",
        choices = {
          moveChoice("move:0", "TACKLE", 35, 35, "NORMAL", 0),
          moveChoice("move:1", "GROWL", 40, 40, "NORMAL", 1),
          { role = "run", enabled = true, choice = { kind = "run", payload = {} } },
        },
      },
    },
  }
  return {
    launchId = launchId,
    packetId = 1,
    after = after,
    events = {},
    request = {
      requestId = 7,
      epoch = 1,
      controller = "player",
      actors = { { kind = "command" } },
      legalChoices = { kinds = { "attack", "item", "switch", "run" } },
      options = options,
    },
  }
end

-- Pumps one envelope until its port enters: preparation runs inside the
-- fixed updates, so arrival proves the exact demand validated and every
-- required member resolved through the production services.
---@param envelope table live presented-battle envelope under driving
---@param port table fresh presentation port under driving
---@param launchId string owning launch identity under driving
---@param versionId string ready game version under test
local function driveToEnter(envelope, port, launchId, versionId)
  local ticks = 0
  while ticks < DRIVE_BUDGET do
    envelope:updateFixed(TICK)
    ticks = ticks + 1
    if port.enter({ launchId = launchId, kind = "wild" }) then
      return
    end
  end
  local screen = envelope:liveScreen()
  local status = screen ~= nil and screen:status() or nil
  error(
    versionId
      .. " enters its staged launch (mode="
      .. tostring(status ~= nil and status.mode)
      .. " err="
      .. tostring(status ~= nil and status.error)
      .. ")",
    0
  )
end

-- Presents the opening packet and pumps until the command request is
-- exposed: arrival proves the portrait demand grew and the send-out cues
-- drained through the production drawables.
---@param envelope table live presented-battle envelope under driving
---@param port table entered presentation port under driving
---@param launchId string owning launch identity under driving
---@param versionId string ready game version under driving
---@param portraits table exact staged portrait selectors under demand
local function driveToCommand(envelope, port, launchId, versionId, portraits)
  port.present(openingPacket(launchId, portraits))
  local ticks = 0
  while ticks < DRIVE_BUDGET do
    envelope:updateFixed(TICK)
    ticks = ticks + 1
    local screen = envelope:liveScreen()
    local status = screen ~= nil and screen:status() or nil
    if status ~= nil and status.request ~= nil then
      Assert.equal(status.mode, "command", versionId .. " rests on the command view")
      return
    end
    Assert.isTrue(
      status == nil or status.mode ~= "failed",
      versionId .. " never fails its staged launch: " .. tostring(status ~= nil and status.error)
    )
  end
  error(versionId .. " exposes its command request", 0)
end

---@param screen table live battle screen under test
---@param versionId string ready game version under test
---@return table resolved plan carrying panes and content
local function livePlan(screen, versionId)
  local status = screen:status()
  local plan = assert(status.presentation, versionId .. " publishes its plan")
  Assert.isTrue(type(plan.panes) == "table" and #plan.panes > 0, versionId .. " plans its panes")
  return plan
end

---@param plan table resolved plan under test
---@param versionId string ready game version under test
---@return integer canvas width covering every pane at unit scale
---@return integer canvas height covering every pane at unit scale
local function canvasSize(plan, versionId)
  local width, height = 0, 0
  for _, pane in ipairs(plan.panes) do
    local placement = assert(pane.placement, versionId .. " places its panes")
    Assert.equal(placement.pixelScale, 1, versionId .. " keeps canonical coordinates")
    local frame = assert(placement.frame, versionId .. " frames its panes")
    width = math.max(width, frame.x + frame.width)
    height = math.max(height, frame.y + frame.height)
  end
  Assert.isTrue(width > 0 and height > 0, versionId .. " covers its panes")
  return width, height
end

-- A full presented launch renders production frames with real staged
-- assets: the envelope uploads the staged scene, menu, HUD, and portrait
-- pixels through the live host graphics, the exact demand carries the
-- staged audio roles beside the scene and portrait pages, and two
-- renders are pixel-identical with scene, prompt, command, and health
-- ink on the canvas.
function T.presented_launch_renders_real_staged_frames(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the production battle coverage needs a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local manifest = BattlePresentationCache.load(cacheFs)
    assertStagedManifest(manifest, versionId)
    local wildRole = assert(manifest.audioRoles.wild, versionId .. " stages its wild music role")
    local text, windows = productionDrawServices(scope, cacheFs, versionId)
    -- Real staged pixels draw through the session image owner: the real
    -- pool classifies through its own worker, following the migrated
    -- starter-ball/map-renderer/bag precedent (fake leases can never reach
    -- the real GPU backend or satisfy staged-pixel assertions).
    local images = ImageAssetPool.new(cacheFs)
    scope:own({
      release = function()
        images:dispose()
      end,
    })
    local envelope = FieldBattlePresentation.new({
      cacheFs = cacheFs,
      graphics = love.graphics,
      windows = windows,
      text = text,
      audio = recordingAudio(),
      measureDisplay = compactMeasurement,
      imagePool = images,
    })
    local launchId = "battle-production"
    local host = stubHost()
    local port = buildPort(envelope, {
      launchId = launchId,
      kind = "wild",
      environment = { sceneKey = SCENE_KEY },
      host = host,
    })
    local canvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true }))
    love.graphics.setCanvas(canvas)
    driveToEnter(envelope, port, launchId, versionId)
    local demands = envelope:preparedDemands()
    Assert.isTrue(#demands >= 1, versionId .. " prepares its exact launch demand")
    local first = demands[1]
    Assert.deepEqual(first.scenes, { SCENE_KEY }, versionId .. " demands exactly its staged scene")
    Assert.isTrue(
      type(first.audio) == "table" and type(first.audio.roles) == "table" and #first.audio.roles > 0,
      versionId .. " demands its staged audio roles beside the scene"
    )
    local carriesWild = false
    for _, role in ipairs(first.audio.roles) do
      if role == wildRole then
        carriesWild = true
      end
    end
    Assert.isTrue(carriesWild, versionId .. " demands its staged wild music role")
    local portraits = {
      leadBack = stagedPortraitSelector(cacheFs, LEAD_SPECIES, "back"),
      foeFront = stagedPortraitSelector(cacheFs, FOE_SPECIES, "front"),
    }
    driveToCommand(envelope, port, launchId, versionId, portraits)
    local grown = envelope:preparedDemands()
    local pages, cries = {}, {}
    for _, demand in ipairs(grown) do
      for _, page in ipairs(demand.pages or {}) do
        pages[page] = true
      end
      for _, cry in ipairs(demand.audio ~= nil and demand.audio.cries or {}) do
        cries[cry] = true
      end
    end
    Assert.isTrue(pages[portraits.leadBack] == true, versionId .. " grows its lead portrait demand")
    Assert.isTrue(pages[portraits.foeFront] == true, versionId .. " grows its foe portrait demand")
    Assert.isTrue(cries["cry:" .. LEAD_SPECIES] == true, versionId .. " demands its lead cry")
    Assert.isTrue(cries["cry:" .. FOE_SPECIES] == true, versionId .. " demands its foe cry")
    local screen = assert(envelope:liveScreen(), versionId .. " keeps its live screen")
    local plan = livePlan(screen, versionId)
    Assert.isTrue(plan.content.compact == true, versionId .. " resolves the compact plan")
    local width, height = canvasSize(plan, versionId)
    Assert.equal(width, 256, versionId .. " keeps the compact canvas width")
    Assert.equal(height, 192, versionId .. " keeps the compact canvas height")
    local frame = assert(plan.panes[1].placement.frame, versionId .. " frames its compact pane")
    local content = assert(plan.content, versionId .. " carries its compact content")

    local function render()
      love.graphics.setCanvas(canvas)
      love.graphics.clear(0, 0, 0, 0)
      Assert.isTrue(
        envelope:drawBattle({ graphics = love.graphics, text = text, windows = windows }),
        versionId .. " draws its live battle"
      )
      love.graphics.setCanvas()
      return scope:own(canvas:newImageData())
    end
    local firstPixels = render()
    local secondPixels = render()
    Assert.equal(
      imageDataDigest(firstPixels),
      imageDataDigest(secondPixels),
      versionId .. " renders its production frames deterministically"
    )
    local sceneBox = hostRect(frame, content.scene)
    Assert.isTrue(
      countInk(firstPixels, sceneBox) > 20000,
      versionId .. " fills the scene viewport with staged scene ink"
    )
    local promptBox = hostRect(frame, content.prompt.content)
    Assert.isTrue(countInk(firstPixels, promptBox) > 100, versionId .. " prints prompt text ink")
    local cells = assert(content.commands.cells, versionId .. " carries its command cells")
    Assert.equal(#cells, 4, versionId .. " lays out four command cells")
    for _, cell in ipairs(cells) do
      Assert.isTrue(
        countInk(firstPixels, hostRect(frame, cell)) > 30,
        versionId .. " prints the " .. tostring(cell.id) .. " command label"
      )
    end
    local hud = assert(content.hud, versionId .. " carries its compact HUD")
    for _, side in ipairs({ { box = hud.enemy, label = "enemy" }, { box = hud.player, label = "player" } }) do
      local bar = assert(side.box.bar, versionId .. " carries its " .. side.label .. " bar")
      -- Native tile bars carry staged-strip ink with the native
      -- quantization; the interim flat tint never paints the bar.
      Assert.isTrue(
        countInk(firstPixels, hostRect(frame, bar)) > 10,
        versionId .. " draws the " .. side.label .. " health bar"
      )
      Assert.equal(
        countColor(firstPixels, hostRect(frame, bar), { 51, 204, 51 }),
        0,
        versionId .. " paints no interim tint on the " .. side.label .. " health bar"
      )
    end
    for _, event in ipairs(host.notifies) do
      Assert.isTrue(event ~= "screen-failed", versionId .. " never fails its staged launch")
    end
    love.graphics.setCanvas()
    envelope:dispose()
  end
end

-- A cold global and scene stay covered without a screen until the worker
-- publishes: the admitted port stays unacknowledged with no live screen
-- and no painted frame while pending, then exactly one staged-backed
-- screen enters and renders staged scene ink deterministically.
function T.cold_global_and_scene_build_one_staged_screen(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the cold battle coverage needs a ready user-owned ROM with a derived cache")
  end
  local BattleScreenState = require("game.hgss.src.battle.BattleScreenState")
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local manifest = BattlePresentationCache.load(cacheFs)
    assertStagedManifest(manifest, versionId)
    local wildRole = assert(manifest.audioRoles.wild, versionId .. " stages its wild music role")
    local manifestPath = BattlePresentationCache.manifestPath()
    local recordPath = BattlePresentationCache.scenePath(SCENE_KEY)
    local imagePath = BattlePresentationCache.sceneImagePath(SCENE_KEY)
    local revealed = false
    local view = { versionId = cacheFs.versionId }
    function view.loadLua(_, path)
      if not revealed and (path == manifestPath or path == recordPath) then
        return nil
      end
      return cacheFs:loadLua(path)
    end
    function view.read(_, path)
      if not revealed and path == imagePath then
        return nil
      end
      return cacheFs:read(path)
    end
    -- The session image owner resolves paths exactly like the versioned
    -- cache: the hiding view delegates confinement while still hiding the
    -- pending global/scene bytes above.
    function view.resolve(_, relativePath)
      return cacheFs:resolve(relativePath)
    end
    local worker = { ready = nil, failure = nil, asks = {} }
    local derivedAssets = {}
    function derivedAssets.requestBattleScene(key, urgency)
      worker.asks[#worker.asks + 1] = { key = key, urgency = urgency }
      return worker.ready, worker.failure
    end
    local host = { phase = "leaving", notifies = {} }
    function host.status()
      return { phase = host.phase }
    end
    function host.advance() end
    function host.submit(_)
      return true
    end
    function host.notify(event, reason)
      host.notifies[#host.notifies + 1] = { event = event, reason = reason }
    end
    local realNew = BattleScreenState.new
    local constructions = {}
    BattleScreenState.new = function(opts)
      constructions[#constructions + 1] = opts ~= nil and opts.manifest or nil
      return realNew(opts)
    end
    local ok, failure = xpcall(function()
      local text, windows = productionDrawServices(scope, cacheFs, versionId)
      -- Real staged pixels draw through the session image owner (see the
      -- presented launch above); the hiding view still governs cache
      -- reads for the pending/ready progression.
      local images = ImageAssetPool.new(view)
      scope:own({
        release = function()
          images:dispose()
        end,
      })
      local envelope = FieldBattlePresentation.new({
        cacheFs = view,
        graphics = love.graphics,
        windows = windows,
        text = text,
        audio = recordingAudio(),
        measureDisplay = compactMeasurement,
        derivedAssets = derivedAssets,
        imagePool = images,
      })
      local launchId = "battle-cold-global"
      local port = buildPort(envelope, {
        launchId = launchId,
        kind = "wild",
        environment = { sceneKey = SCENE_KEY },
        host = host,
      })
      Assert.isNil(envelope:liveScreen(), versionId .. " holds no screen while its global builds")
      Assert.equal(#constructions, 0, versionId .. " constructs no screen before the worker publishes")
      for _ = 1, 30 do
        envelope:updateFixed(TICK)
      end
      Assert.isFalse(
        port.enter({ launchId = launchId, kind = "wild" }),
        versionId .. " stays unacknowledged while pending"
      )
      Assert.isFalse(port.ready(), versionId .. " never reads interactive while pending")
      Assert.isNil(envelope:liveScreen(), versionId .. " still holds no screen while pending")
      Assert.isTrue(#worker.asks >= 1, versionId .. " demands its scene through the borrowed host")
      for _, ask in ipairs(worker.asks) do
        Assert.equal(ask.key, SCENE_KEY, versionId .. " demands exactly its launch scene")
        Assert.equal(ask.urgency, "required", versionId .. " demands its scene urgently")
      end
      Assert.isFalse(
        envelope:drawBattle({ graphics = love.graphics, text = text, windows = windows }),
        versionId .. " paints no blank success while pending"
      )
      for _, note in ipairs(host.notifies) do
        Assert.isTrue(note.event ~= "screen-failed", versionId .. " reports no failure while pending")
      end
      revealed = true
      worker.ready = true
      driveToEnter(envelope, port, launchId, versionId)
      Assert.equal(#constructions, 1, versionId .. " constructs exactly one screen")
      Assert.isTrue(type(constructions[1]) == "table", versionId .. " backs its screen with the staged global")
      assertStagedManifest(constructions[1], versionId .. " screen")
      local demands = envelope:preparedDemands()
      Assert.isTrue(#demands >= 1, versionId .. " prepares its exact launch demand")
      Assert.deepEqual(demands[1].scenes, { SCENE_KEY }, versionId .. " demands exactly its staged scene")
      local carriesWild = false
      for _, role in ipairs(demands[1].audio.roles) do
        if role == wildRole then
          carriesWild = true
        end
      end
      Assert.isTrue(carriesWild, versionId .. " demands its staged wild music role")
      local portraits = {
        leadBack = stagedPortraitSelector(cacheFs, LEAD_SPECIES, "back"),
        foeFront = stagedPortraitSelector(cacheFs, FOE_SPECIES, "front"),
      }
      driveToCommand(envelope, port, launchId, versionId, portraits)
      local screen = assert(envelope:liveScreen(), versionId .. " keeps its live screen")
      local plan = livePlan(screen, versionId)
      local width, height = canvasSize(plan, versionId)
      Assert.equal(width, 256, versionId .. " keeps the compact canvas width")
      Assert.equal(height, 192, versionId .. " keeps the compact canvas height")
      local frame = assert(plan.panes[1].placement.frame, versionId .. " frames its compact pane")
      local content = assert(plan.content, versionId .. " carries its compact content")
      local canvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true }))
      local function render()
        love.graphics.setCanvas(canvas)
        love.graphics.clear(0, 0, 0, 0)
        Assert.isTrue(
          envelope:drawBattle({ graphics = love.graphics, text = text, windows = windows }),
          versionId .. " draws its live battle"
        )
        love.graphics.setCanvas()
        return scope:own(canvas:newImageData())
      end
      local firstPixels = render()
      local secondPixels = render()
      Assert.equal(
        imageDataDigest(firstPixels),
        imageDataDigest(secondPixels),
        versionId .. " renders its cold-built frames deterministically"
      )
      local sceneBox = hostRect(frame, content.scene)
      Assert.isTrue(
        countInk(firstPixels, sceneBox) > 20000,
        versionId .. " fills the scene viewport with staged scene ink"
      )
      local promptBox = hostRect(frame, content.prompt.content)
      Assert.isTrue(countInk(firstPixels, promptBox) > 100, versionId .. " prints prompt text ink")
      local cells = assert(content.commands.cells, versionId .. " carries its command cells")
      Assert.equal(#cells, 4, versionId .. " lays out four command cells")
      for _, note in ipairs(host.notifies) do
        Assert.isTrue(note.event ~= "screen-failed", versionId .. " never fails its staged launch")
      end
      love.graphics.setCanvas()
      envelope:dispose()
    end, debug.traceback)
    BattleScreenState.new = realNew
    if not ok then
      error(failure, 0)
    end
  end
end

-- A launch whose staged scene image is missing fails closed with
-- context: entry stays unacknowledged, the screen reports failed with
-- the missing member named, drawing never raises on either graphics
-- boundary, and the envelope drops the launch after notifying the host
-- exactly once. Nothing here reads as ready, and nothing paints a blank
-- success.
function T.missing_scene_image_fails_closed_with_context(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the production battle coverage needs a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = hidingCacheFs(CacheFs.forVersion(versionId), BattlePresentationCache.sceneImagePath(SAD_SCENE_KEY))
    local envelope = FieldBattlePresentation.new({
      cacheFs = cacheFs,
      graphics = love.graphics,
      windows = recordingWindows(),
      text = recordingText(),
      audio = recordingAudio(),
      measureDisplay = compactMeasurement,
    })
    local launchId = "battle-missing-scene"
    local host = stubHost()
    local port = buildPort(envelope, {
      launchId = launchId,
      kind = "wild",
      environment = { sceneKey = SAD_SCENE_KEY },
      host = host,
    })
    Assert.isFalse(
      port.enter({ launchId = launchId, kind = "wild" }),
      versionId .. " leaves its unstaged launch unacknowledged"
    )
    local screen = assert(envelope:liveScreen(), versionId .. " keeps its screen for inspection")
    for _ = 1, 5 do
      screen:updateFixed(TICK)
    end
    Assert.isFalse(
      port.enter({ launchId = launchId, kind = "wild" }),
      versionId .. " never acknowledges its unstaged launch"
    )
    local status = screen:status()
    Assert.equal(status.mode, "failed", versionId .. " reports its deterministic failed state")
    local failure = assert(status.error, versionId .. " carries its failure context")
    -- Both the scene record and image paths carry the launch scene
    -- stem, so either missing member names the scene in context.
    Assert.isTrue(
      tostring(failure):find("city-sand-night", 1, true) ~= nil,
      versionId .. " names its missing scene member: " .. tostring(failure)
    )
    Assert.isFalse(port.ready(), versionId .. " never reads ready for its failed launch")
    local canvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true }))
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    screen:draw({ graphics = love.graphics })
    local recording = { draws = {} }
    function recording.push(_) end
    function recording.pop() end
    function recording.origin() end
    function recording.intersectScissor(_, _, _, _) end
    function recording.translate(_, _) end
    function recording.scale(_, _) end
    function recording.transformPoint(x, y)
      return x, y
    end
    function recording.getColor()
      return 1, 1, 1, 1
    end
    function recording.setColor(_, _, _, _) end
    function recording.getDepthMode() end
    function recording.setDepthMode(_, _) end
    function recording.setShader(_) end
    function recording.setBlendMode(_, _) end
    function recording.setScissor(_, _, _, _) end
    function recording.rectangle(_, _, _, _, _) end
    function recording.draw(drawable, x, y)
      recording.draws[#recording.draws + 1] = { drawable = drawable, x = x, y = y }
    end
    screen:draw({ graphics = recording })
    love.graphics.setCanvas()
    local settled = screen:status()
    Assert.equal(settled.mode, "failed", versionId .. " stays failed across both draw boundaries")
    Assert.equal(settled.error, status.error, versionId .. " keeps its failure context across draws")
    for _ = 1, 60 do
      envelope:updateFixed(TICK)
    end
    local failed = 0
    for _, event in ipairs(host.notifies) do
      if event == "screen-failed" then
        failed = failed + 1
      end
    end
    Assert.equal(failed, 1, versionId .. " notifies its deterministic failure exactly once")
    Assert.isNil(envelope:liveScreen(), versionId .. " drops its failed launch")
    Assert.isFalse(envelope:ownsInput(), versionId .. " releases input with its failed launch")
    envelope:dispose()
  end
end

-- The battle draw boundary owns every pixel it paints: the same staged
-- command view rendered into the same offscreen target must match the
-- neutral control exactly after an incoming black tint, a partial-alpha
-- tint, and a foreign shader with a nondefault blend and scissor, and
-- must keep every fully opaque control color over a leftover black cover
-- fill (where the battle legitimately leaves transparency over the
-- previous fill). Every leg runs so one failure names all contaminated
-- legs instead of stopping at the first.
function T.hostile_incoming_graphics_state_never_reaches_battle_pixels(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the hostile-state coverage needs a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local manifest = BattlePresentationCache.load(cacheFs)
    assertStagedManifest(manifest, versionId)
    local text, windows = productionDrawServices(scope, cacheFs, versionId)
    local envelope = FieldBattlePresentation.new({
      cacheFs = cacheFs,
      graphics = love.graphics,
      windows = windows,
      text = text,
      audio = recordingAudio(),
      measureDisplay = compactMeasurement,
    })
    local launchId = "battle-hostile-pixels"
    local host = stubHost()
    local port = buildPort(envelope, {
      launchId = launchId,
      kind = "wild",
      environment = { sceneKey = SCENE_KEY },
      host = host,
    })
    local canvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true }))
    love.graphics.setCanvas(canvas)
    driveToEnter(envelope, port, launchId, versionId)
    local portraits = {
      leadBack = stagedPortraitSelector(cacheFs, LEAD_SPECIES, "back"),
      foeFront = stagedPortraitSelector(cacheFs, FOE_SPECIES, "front"),
    }
    driveToCommand(envelope, port, launchId, versionId, portraits)
    local function renderCleared()
      love.graphics.setCanvas(canvas)
      love.graphics.clear(0, 0, 0, 0)
      Assert.isTrue(
        envelope:drawBattle({ graphics = love.graphics, text = text, windows = windows }),
        versionId .. " draws its live battle"
      )
      love.graphics.setCanvas()
      return scope:own(canvas:newImageData())
    end
    local function neutralize()
      love.graphics.setShader()
      love.graphics.setBlendMode("alpha")
      love.graphics.setScissor()
      love.graphics.setColor(1, 1, 1, 1)
    end
    local failures = {}
    neutralize()
    local controlPixels = renderCleared()
    local controlDigest = imageDataDigest(controlPixels)
    local function checkDigest(pixels, label)
      if imageDataDigest(pixels) ~= controlDigest then
        failures[#failures + 1] = label
      end
    end
    neutralize()
    love.graphics.setColor(0, 0, 0, 1)
    checkDigest(renderCleared(), "black incoming tint")
    neutralize()
    love.graphics.setColor(1, 1, 1, 0.45)
    checkDigest(renderCleared(), "partial-alpha incoming tint")
    local shaderOk, foreign = pcall(
      love.graphics.newShader,
      [[
      vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
        vec4 px = Texel(texture, texture_coords);
        return vec4(1.0 - px.rgb, px.a) * color;
      }
    ]]
    )
    if not shaderOk or foreign == nil then
      context:skip(versionId .. " cannot compile a foreign test shader")
    end
    ---@cast foreign -nil
    if type(foreign.release) == "function" then
      scope:own(foreign)
    end
    neutralize()
    love.graphics.setShader(foreign)
    love.graphics.setBlendMode("add")
    love.graphics.setScissor(32, 32, 64, 64)
    love.graphics.setColor(0.2, 0.5, 0.9, 1)
    checkDigest(renderCleared(), "foreign shader with nondefault blend and scissor")
    neutralize()
    love.graphics.setCanvas(canvas)
    love.graphics.setColor(0, 0, 0, 1)
    love.graphics.rectangle("fill", 0, 0, 256, 192)
    Assert.isTrue(
      envelope:drawBattle({ graphics = love.graphics, text = text, windows = windows }),
      versionId .. " draws over the leftover black cover"
    )
    love.graphics.setCanvas()
    local coveredPixels = scope:own(canvas:newImageData())
    local opaque, matched = 0, 0
    for y = 0, coveredPixels:getHeight() - 1 do
      for x = 0, coveredPixels:getWidth() - 1 do
        local cr, cg, cb, ca = controlPixels:getPixel(x, y)
        if quantize(ca) == 255 then
          opaque = opaque + 1
          local r, g, b, a = coveredPixels:getPixel(x, y)
          if
            quantize(r) == quantize(cr)
            and quantize(g) == quantize(cg)
            and quantize(b) == quantize(cb)
            and quantize(a) == 255
          then
            matched = matched + 1
          end
        end
      end
    end
    Assert.isTrue(opaque > 20000, versionId .. " stages an opaque control to compare against")
    if matched ~= opaque then
      failures[#failures + 1] = "leftover black cover (" .. tostring(opaque - matched) .. " opaque pixels tinted)"
    end
    Assert.equal(#failures, 0, versionId .. " contaminated legs: " .. table.concat(failures, "; "))
    love.graphics.setCanvas()
    envelope:dispose()
  end
end

-- Drawing never borrows caller state: color, shader, blend, scissor, and
-- canvas read back identical around the battle draw on a neutral leg and
-- on every hostile leg.
function T.battle_draw_preserves_caller_graphics_state(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the state-preservation coverage needs a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local manifest = BattlePresentationCache.load(cacheFs)
    assertStagedManifest(manifest, versionId)
    local text, windows = productionDrawServices(scope, cacheFs, versionId)
    local envelope = FieldBattlePresentation.new({
      cacheFs = cacheFs,
      graphics = love.graphics,
      windows = windows,
      text = text,
      audio = recordingAudio(),
      measureDisplay = compactMeasurement,
    })
    local launchId = "battle-caller-state"
    local host = stubHost()
    local port = buildPort(envelope, {
      launchId = launchId,
      kind = "wild",
      environment = { sceneKey = SCENE_KEY },
      host = host,
    })
    local canvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true }))
    love.graphics.setCanvas(canvas)
    driveToEnter(envelope, port, launchId, versionId)
    local portraits = {
      leadBack = stagedPortraitSelector(cacheFs, LEAD_SPECIES, "back"),
      foeFront = stagedPortraitSelector(cacheFs, FOE_SPECIES, "front"),
    }
    driveToCommand(envelope, port, launchId, versionId, portraits)
    local function captureState()
      local red, green, blue, alpha = love.graphics.getColor()
      local blendMode, blendAlpha = love.graphics.getBlendMode()
      return {
        color = { red, green, blue, alpha },
        shader = love.graphics.getShader(),
        blend = { blendMode, blendAlpha },
        scissor = { love.graphics.getScissor() },
        canvas = love.graphics.getCanvas(),
      }
    end
    local function drawAndCheck(label)
      love.graphics.setCanvas(canvas)
      love.graphics.clear(0, 0, 0, 0)
      local before = captureState()
      Assert.isTrue(
        envelope:drawBattle({ graphics = love.graphics, text = text, windows = windows }),
        versionId .. " draws its live battle " .. label
      )
      local after = captureState()
      love.graphics.setCanvas()
      Assert.deepEqual(after.color, before.color, versionId .. " restores the caller tint " .. label)
      Assert.isTrue(after.shader == before.shader, versionId .. " restores the caller shader " .. label)
      Assert.deepEqual(after.blend, before.blend, versionId .. " restores the caller blend " .. label)
      Assert.deepEqual(after.scissor, before.scissor, versionId .. " restores the caller scissor " .. label)
      Assert.isTrue(after.canvas == before.canvas, versionId .. " keeps the caller canvas " .. label)
    end
    love.graphics.setShader()
    love.graphics.setBlendMode("alpha")
    love.graphics.setScissor()
    love.graphics.setColor(1, 1, 1, 1)
    drawAndCheck("on the neutral leg")
    love.graphics.setColor(0, 0, 0, 1)
    drawAndCheck("under a black incoming tint")
    local shaderOk, foreign = pcall(
      love.graphics.newShader,
      [[
      vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
        vec4 px = Texel(texture, texture_coords);
        return vec4(1.0 - px.rgb, px.a) * color;
      }
    ]]
    )
    if not shaderOk or foreign == nil then
      context:skip(versionId .. " cannot compile a foreign test shader")
    end
    ---@cast foreign -nil
    if type(foreign.release) == "function" then
      scope:own(foreign)
    end
    love.graphics.setShader(foreign)
    love.graphics.setBlendMode("add")
    love.graphics.setScissor(32, 32, 64, 64)
    love.graphics.setColor(0.2, 0.5, 0.9, 1)
    drawAndCheck("under a foreign shader and blend")
    love.graphics.setCanvas()
    envelope:dispose()
  end
end

-- A nested draw failure still classifies through the launch failure path:
-- the failure raises on the first nested primitive, so the doomed canvas
-- carries a deterministic painted prefix. Every painted pixel of that
-- prefix must already match the neutral control exactly; the failed
-- screen reports with launch context, the envelope notifies exactly once,
-- the caller state is identical to before the draw, and an unrelated
-- surface painted next matches its failure-free control pixel for pixel.
function T.failed_battle_draw_reports_and_leaves_no_graphics_behind(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the draw-failure coverage needs a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local manifest = BattlePresentationCache.load(cacheFs)
    assertStagedManifest(manifest, versionId)
    local text, windows = productionDrawServices(scope, cacheFs, versionId)
    local envelope = FieldBattlePresentation.new({
      cacheFs = cacheFs,
      graphics = love.graphics,
      windows = windows,
      text = text,
      audio = recordingAudio(),
      measureDisplay = compactMeasurement,
    })
    local launchId = "battle-nested-draw-failure"
    local host = stubHost()
    local port = buildPort(envelope, {
      launchId = launchId,
      kind = "wild",
      environment = { sceneKey = SCENE_KEY },
      host = host,
    })
    local canvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true }))
    love.graphics.setCanvas(canvas)
    driveToEnter(envelope, port, launchId, versionId)
    local portraits = {
      leadBack = stagedPortraitSelector(cacheFs, LEAD_SPECIES, "back"),
      foeFront = stagedPortraitSelector(cacheFs, FOE_SPECIES, "front"),
    }
    driveToCommand(envelope, port, launchId, versionId, portraits)
    local shaderOk, foreign = pcall(
      love.graphics.newShader,
      [[
      vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
        vec4 px = Texel(texture, texture_coords);
        return vec4(1.0 - px.rgb, px.a) * color;
      }
    ]]
    )
    if not shaderOk or foreign == nil then
      context:skip(versionId .. " cannot compile a foreign test shader")
    end
    ---@cast foreign -nil
    if type(foreign.release) == "function" then
      scope:own(foreign)
    end
    local function neutralize()
      love.graphics.setShader()
      love.graphics.setBlendMode("alpha")
      love.graphics.setScissor()
      love.graphics.setColor(1, 1, 1, 1)
    end
    local function renderCleared()
      love.graphics.setCanvas(canvas)
      love.graphics.clear(0, 0, 0, 0)
      Assert.isTrue(
        envelope:drawBattle({ graphics = love.graphics, text = text, windows = windows }),
        versionId .. " draws its live battle"
      )
      love.graphics.setCanvas()
      return scope:own(canvas:newImageData())
    end
    neutralize()
    local controlPixels = renderCleared()
    -- A second settled command view fails under neutral incoming state: its
    -- doomed canvas carries exactly the background prefix the composition
    -- later overpaints, so the poisoned comparison below can exclude
    -- compositional overpaint without excusing leaked tint.
    local baseText, baseWindows = productionDrawServices(scope, cacheFs, versionId)
    local baseEnvelope = FieldBattlePresentation.new({
      cacheFs = cacheFs,
      graphics = love.graphics,
      windows = baseWindows,
      text = baseText,
      audio = recordingAudio(),
      measureDisplay = compactMeasurement,
    })
    local baseLaunchId = "battle-nested-draw-baseline"
    local baseHost = stubHost()
    local basePort = buildPort(baseEnvelope, {
      launchId = baseLaunchId,
      kind = "wild",
      environment = { sceneKey = SCENE_KEY },
      host = baseHost,
    })
    local baseCanvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true }))
    love.graphics.setCanvas(baseCanvas)
    driveToEnter(baseEnvelope, basePort, baseLaunchId, versionId)
    driveToCommand(baseEnvelope, basePort, baseLaunchId, versionId, portraits)
    local baseRaised = false
    local baseProxy = setmetatable({}, {
      __index = love.graphics,
    })
    function baseProxy.draw(...)
      local results = { love.graphics.draw(...) }
      baseRaised = true
      error("injected nested draw failure", 0)
      return unpack(results)
    end
    neutralize()
    love.graphics.setCanvas(baseCanvas)
    love.graphics.clear(0, 0, 0, 0)
    Assert.isTrue(
      baseEnvelope:drawBattle({ graphics = baseProxy, text = baseText, windows = baseWindows }),
      versionId .. " converts the neutral nested draw failure instead of raising"
    )
    love.graphics.setCanvas()
    Assert.isTrue(baseRaised, versionId .. " fails the neutral run inside the nested render")
    local baselinePrefix = scope:own(baseCanvas:newImageData())
    baseEnvelope:dispose()
    local reference = scope:own(love.graphics.newCanvas(128, 64, { format = "rgba8", readable = true }))
    local function paintReference()
      love.graphics.setCanvas(reference)
      love.graphics.rectangle("fill", 0, 0, 128, 64)
      love.graphics.setCanvas()
      return scope:own(reference:newImageData())
    end
    love.graphics.setShader(foreign)
    love.graphics.setBlendMode("add")
    love.graphics.setScissor(8, 8, 112, 48)
    love.graphics.setColor(0.15, 0.35, 0.85, 1)
    local controlDigest = imageDataDigest(paintReference())
    love.graphics.setShader(foreign)
    love.graphics.setBlendMode("add")
    love.graphics.setScissor(8, 8, 112, 48)
    love.graphics.setColor(0.15, 0.35, 0.85, 1)
    local raised = false
    local proxy = setmetatable({}, {
      __index = love.graphics,
    })
    function proxy.draw(...)
      local results = { love.graphics.draw(...) }
      raised = true
      error("injected nested draw failure", 0)
      return unpack(results)
    end
    local red, green, blue, alpha = love.graphics.getColor()
    local blendMode, blendAlpha = love.graphics.getBlendMode()
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    local beforeState = {
      color = { red, green, blue, alpha },
      shader = love.graphics.getShader(),
      blend = { blendMode, blendAlpha },
      scissor = { love.graphics.getScissor() },
      canvas = love.graphics.getCanvas(),
    }
    Assert.isTrue(
      envelope:drawBattle({ graphics = proxy, text = text, windows = windows }),
      versionId .. " converts the nested draw failure instead of raising"
    )
    local ar, ag, ab, aa = love.graphics.getColor()
    local bmode, balpha = love.graphics.getBlendMode()
    local afterState = {
      color = { ar, ag, ab, aa },
      shader = love.graphics.getShader(),
      blend = { bmode, balpha },
      scissor = { love.graphics.getScissor() },
      canvas = love.graphics.getCanvas(),
    }
    love.graphics.setCanvas()
    Assert.isTrue(raised, versionId .. " fails inside the nested render, not before it")
    local doomedPixels = scope:own(canvas:newImageData())
    local painted, matched, compared = 0, 0, 0
    for y = 0, doomedPixels:getHeight() - 1 do
      for x = 0, doomedPixels:getWidth() - 1 do
        local _, _, _, fa = doomedPixels:getPixel(x, y)
        if quantize(fa) > 0 then
          painted = painted + 1
          local r, g, b, a = doomedPixels:getPixel(x, y)
          local cr, cg, cb, ca = controlPixels:getPixel(x, y)
          local br, bg, bb, ba = baselinePrefix:getPixel(x, y)
          -- Mask compositional overpaint: where the full control differs
          -- from the neutral background prefix, later interface layers
          -- cover the background, so only unmasked pixels must match.
          if
            quantize(br) == quantize(cr)
            and quantize(bg) == quantize(cg)
            and quantize(bb) == quantize(cb)
            and quantize(ba) == quantize(ca)
          then
            compared = compared + 1
            if
              quantize(r) == quantize(cr)
              and quantize(g) == quantize(cg)
              and quantize(b) == quantize(cb)
              and quantize(a) == quantize(ca)
            then
              matched = matched + 1
            end
          end
        end
      end
    end
    Assert.isTrue(painted > 0, versionId .. " paints a deterministic prefix before failing")
    Assert.isTrue(compared > 0, versionId .. " keeps unmasked background to compare")
    Assert.equal(
      matched,
      compared,
      versionId
        .. " paints its unmasked doomed prefix exactly as the neutral control ("
        .. tostring(compared - matched)
        .. " poisoned)"
    )
    Assert.deepEqual(afterState.color, beforeState.color, versionId .. " restores the caller tint after a draw failure")
    Assert.isTrue(
      afterState.shader == beforeState.shader,
      versionId .. " restores the caller shader after a draw failure"
    )
    Assert.deepEqual(
      afterState.blend,
      beforeState.blend,
      versionId .. " restores the caller blend after a draw failure"
    )
    Assert.deepEqual(
      afterState.scissor,
      beforeState.scissor,
      versionId .. " restores the caller scissor after a draw failure"
    )
    Assert.isTrue(afterState.canvas == beforeState.canvas, versionId .. " keeps the caller canvas after a draw failure")
    Assert.equal(
      imageDataDigest(paintReference()),
      controlDigest,
      versionId .. " paints the next unrelated surface exactly as without the failure"
    )
    local screen = assert(envelope:liveScreen(), versionId .. " keeps its failed screen for inspection")
    local status = screen:status()
    Assert.equal(status.mode, "failed", versionId .. " classifies the nested draw failure")
    Assert.isTrue(
      tostring(status.error):find(launchId, 1, true) ~= nil,
      versionId .. " keeps the launch identity in its failure context"
    )
    for _ = 1, 3 do
      envelope:updateFixed(TICK)
    end
    local failed = 0
    for _, event in ipairs(host.notifies) do
      if event == "screen-failed" then
        failed = failed + 1
      end
    end
    Assert.equal(failed, 1, versionId .. " notifies its draw failure exactly once")
    Assert.isNil(envelope:liveScreen(), versionId .. " drops its failed launch")
    Assert.isFalse(envelope:ownsInput(), versionId .. " releases input with its failed launch")
    love.graphics.setCanvas()
    envelope:dispose()
  end
end

-- The selection arrow is a source-timed control, not a host-call counter:
-- from the same settled paired command view, equal accepted source time
-- must paint the same arrow cell on 30 Hz, on 60 Hz with zero-step calls,
-- and on irregular schedules. A shorter schedule first proves the comparison
-- is sensitive by painting a different cell seventeen source ticks later.
function T.equal_source_time_paints_the_same_arrow_cell_on_every_schedule(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the arrow-schedule coverage needs a ready user-owned ROM with a derived cache")
  end
  local function dualMeasurement()
    return {
      width = 256,
      height = 384,
      topology = ScreenTopology.dualDisplay(
        { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
        { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
      ),
      pixelRatio = 1,
      signature = "battle-production-services:dual-partition",
    }
  end
  local function bootToCommand(cacheFs, text, windows, launchId)
    local envelope = FieldBattlePresentation.new({
      cacheFs = cacheFs,
      graphics = love.graphics,
      windows = windows,
      text = text,
      audio = recordingAudio(),
      measureDisplay = dualMeasurement,
    })
    local host = stubHost()
    local port = buildPort(envelope, {
      launchId = launchId,
      kind = "wild",
      environment = { sceneKey = SCENE_KEY },
      host = host,
    })
    driveToEnter(envelope, port, launchId, "paired boot")
    local portraits = {
      leadBack = stagedPortraitSelector(cacheFs, LEAD_SPECIES, "back"),
      foeFront = stagedPortraitSelector(cacheFs, FOE_SPECIES, "front"),
    }
    port.present(openingPacket(launchId, portraits))
    local ticks = 0
    while ticks < DRIVE_BUDGET do
      envelope:updateFixed(TICK)
      ticks = ticks + 1
      local screen = envelope:liveScreen()
      local status = screen ~= nil and screen:status() or nil
      if status ~= nil and status.mode == "command" and status.request ~= nil then
        return envelope
      end
      Assert.isTrue(
        status == nil or status.mode ~= "failed",
        "paired boot never fails: " .. tostring(status ~= nil and status.error)
      )
    end
    error("paired boot exposes its command request", 0)
    return envelope
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local manifest = BattlePresentationCache.load(cacheFs)
    assertStagedManifest(manifest, versionId)
    local function renderOver(envelope, text, windows, schedule)
      for _, dt in ipairs(schedule) do
        envelope:updateFixed(dt)
      end
      local screen = assert(envelope:liveScreen(), versionId .. " keeps its live screen")
      local plan = livePlan(screen, versionId)
      local width, height = canvasSize(plan, versionId)
      local canvas = scope:own(love.graphics.newCanvas(width, height, { format = "rgba8", readable = true }))
      love.graphics.setCanvas(canvas)
      love.graphics.clear(0, 0, 0, 0)
      Assert.isTrue(
        envelope:drawBattle({ graphics = love.graphics, text = text, windows = windows }),
        versionId .. " draws its live battle"
      )
      love.graphics.setCanvas()
      return scope:own(canvas:newImageData())
    end
    local at30 = {}
    for _ = 1, 90 do
      at30[#at30 + 1] = 1 / 30
    end
    local at60zero = {}
    for _ = 1, 90 do
      at60zero[#at60zero + 1] = 1 / 60
      at60zero[#at60zero + 1] = 1 / 60
      at60zero[#at60zero + 1] = 0
    end
    local irregular = {}
    for _ = 1, 45 do
      irregular[#irregular + 1] = 1 / 30
      irregular[#irregular + 1] = 0
      irregular[#irregular + 1] = 1 / 60
      irregular[#irregular + 1] = 1 / 60
    end
    local later = {}
    for _ = 1, 17 do
      later[#later + 1] = 1 / 30
    end
    local textA, windowsA = productionDrawServices(scope, cacheFs, versionId)
    local envelopeA = bootToCommand(cacheFs, textA, windowsA, "battle-arrow-30")
    local digestA = imageDataDigest(renderOver(envelopeA, textA, windowsA, at30))
    local digestLater = imageDataDigest(renderOver(envelopeA, textA, windowsA, later))
    envelopeA:dispose()
    Assert.isTrue(digestLater ~= digestA, versionId .. " animates its command arrow across seventeen source ticks")
    local textB, windowsB = productionDrawServices(scope, cacheFs, versionId)
    local envelopeB = bootToCommand(cacheFs, textB, windowsB, "battle-arrow-60")
    local digestB = imageDataDigest(renderOver(envelopeB, textB, windowsB, at60zero))
    envelopeB:dispose()
    local textC, windowsC = productionDrawServices(scope, cacheFs, versionId)
    local envelopeC = bootToCommand(cacheFs, textC, windowsC, "battle-arrow-irregular")
    local digestC = imageDataDigest(renderOver(envelopeC, textC, windowsC, irregular))
    envelopeC:dispose()
    Assert.equal(digestB, digestA, versionId .. " paints the same arrow cell on 60 Hz with zero-step calls as on 30 Hz")
    Assert.equal(digestC, digestA, versionId .. " paints the same arrow cell on irregular frames as on 30 Hz")
    love.graphics.setCanvas()
  end
end

-- Records one selected-game effect demand per call for the graphics
-- effect coverage: programmable pending/ready answers, no worker.
local function recordingGraphicsEffectHost()
  local host = { asks = {}, answers = {} }
  local derived = {}
  function derived.requestBattleEffect(key, urgency)
    host.asks[#host.asks + 1] = { key = key, urgency = urgency }
    local answer = host.answers[key]
    if type(answer) == "table" and answer.failure ~= nil then
      return false, answer.failure
    end
    if answer == "ready" then
      return true
    end
    return nil
  end
  host.derivedAssets = derived
  return host
end

local function graphicsEffectEnvelope(cache, host, graphics)
  local text = {}
  function text.measure(content)
    return { width = 8 * #tostring(content), height = 16 }
  end
  function text.drawText(_) end
  local windows = {}
  function windows.drawWindow(_, _, _) end
  return FieldBattlePresentation.new({
    cacheFs = cache,
    windows = windows,
    text = text,
    measureDisplay = function()
      return {
        width = 256,
        height = 192,
        topology = ScreenTopology.oneDisplay({
          id = "main",
          rect = { x = 0, y = 0, width = 256, height = 192 },
          touch = true,
          role = "world",
        }),
        pixelRatio = 1,
        signature = "graphics-effect:compact",
      }
    end,
    graphics = graphics,
    derivedAssets = host.derivedAssets,
  })
end

local function stagedGraphicsSpark(cache, key, width, height)
  local EffectStagingFixture = require("tests.support.EffectStagingFixture")
  local Hashing = require("romdump.src.digest.Hashing")
  local textureBytes = EffectStagingFixture.rgba(width, height)
  local textureIdentity = Hashing.sha1hex(textureBytes)
  local textureKey = "battle/particle/texture/" .. textureIdentity
  local texturePath = BattlePresentationCache.globalResourcePath("effect/content/" .. textureIdentity)
  local record = EffectStagingFixture.effectRecord(key, {
    { key = textureKey, kind = "texture", payload = texturePath, contentIdentity = textureIdentity },
  })
  cache:writeLua(BattlePresentationCache.effectPath(key), record)
  return textureKey, texturePath, textureBytes
end

local function graphicsEffectHolder(services, launchId)
  local BattlePresentationAssets = require("game.hgss.src.battle.BattlePresentationAssets")
  return BattlePresentationAssets.new({
    assets = services,
    launchId = launchId,
    sceneKey = "probe/plain/day",
    shadowRegions = BattlePresentationManifestFixture.manifest().pictures.shadow.regions,
  })
end

-- A staged effect texture paints native pixels through the production
-- chain: real field services upload the staged RGBA descriptor into one
-- owned LÖVE image, the holder resolves it under its semantic key, and
-- the production renderer paints the source pixel at native coordinates
-- with no fabricated registry.
function T.staged_effect_texture_paints_native_pixels_through_production_services(scope, context)
  local FakeCache = require("tests.support.FakeCache")
  local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
  local BattleScene = require("libs.hgss.src.presentation.BattleScene")
  local CacheFs = require("libs.storage.src.CacheFs")
  local cache = CacheFs.forVersion("probe-effect-pixels", FakeCache.new())
  local textureKey, texturePath, textureBytes = stagedGraphicsSpark(cache, "TACKLE", 8, 8)
  local host = recordingGraphicsEffectHost()
  local envelope = graphicsEffectEnvelope(cache, host, love.graphics)
  local services = envelope:_preparationServices()
  local assets = graphicsEffectHolder(services, "probe-pixels")
  Assert.equal(assets:demandEffect("TACKLE"), false, "the unstaged effect polls pending without failing")
  host.answers["TACKLE"] = "ready"
  Assert.equal(assets:demandEffect("TACKLE"), false, "a ready worker without staged closure stays pending")
  cache:write(BattlePresentationCache.effectMarkerPath("TACKLE"), "probe-marker")
  cache:writeLua(texturePath, { width = 8, height = 8, rgba8888 = textureBytes })
  Assert.equal(assets:demandEffect("TACKLE"), true, "the closed staged effect reads ready")
  local effect = assets:loadEffect("TACKLE")
  Assert.notNil(effect, "the ready effect loads")
  Assert.equal(effect.key, "TACKLE", "the loaded record names the selected effect")
  local lease = assets:resolveEffectResource(effect, textureKey)
  Assert.notNil(lease, "the staged texture admits")
  Assert.equal(lease.width, 8, "the admitted lease carries its staged width")
  Assert.equal(lease.height, 8, "the admitted lease carries its staged height")
  Assert.equal(lease.rgba8888, textureBytes, "the admitted lease shares its exact staged bytes")
  local image = assets:drawable(textureKey)
  Assert.notNil(image, "the admitted texture resolves to a real image")
  Assert.equal(image:getWidth(), 8, "the uploaded image keeps its staged width")
  Assert.equal(image:getHeight(), 8, "the uploaded image keeps its staged height")
  Assert.isNil(
    assets:drawable("battle/effect-background/blend"),
    "invented proxy keys never resolve to a fabricated image"
  )
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  local slot = scene:allocEffect("pixel-paint-probe")
  scene:setEffectPicture(slot.id, {
    assetKey = textureKey,
    selector = "spark",
    centerX = 32,
    centerY = 24,
    zCenter = 0,
    width = 8,
    height = 8,
    alpha = 1,
  })
  local canvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true }))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  BattleRenderer.drawPane({
    graphics = love.graphics,
    text = {},
    windows = {},
    assets = assets,
    frameKey = "default",
    sceneImageKey = "scene:probe",
  }, {
    battlers = {},
    effectInstances = scene:effectViews(),
    hudPatchSpans = {},
    hudSections = {},
  }, "detail", {})
  love.graphics.setCanvas()
  local data = scope:own(canvas:newImageData())
  Assert.equal(
    countColor(data, { x = 28, y = 20, width = 8, height = 8 }, { 255, 0, 0 }),
    1,
    "the staged source pixel paints at its native coordinates"
  )
  local _, _, _, farAlpha = data:getPixel(200, 150)
  Assert.equal(quantize(farAlpha), 0, "no effect ink leaks outside the staged region")
  assets:dispose()
  local stale, staleErr = assets:demandEffect("TACKLE")
  Assert.isNil(stale, "a disposed launch publishes no stale readiness")
  Assert.isTrue(type(staleErr) == "string" and staleErr ~= "", "the stale demand fails with context")
  envelope:dispose()
end

-- A staged sprite strip crops through the production chain: the real
-- field services upload the staged strip, the scene carries an exact
-- tile-band crop origin with an authored flip, and the production
-- renderer paints only the cropped texels at native coordinates with
-- the flip mirrored.
function T.staged_sprite_cell_crop_paints_native_pixels_through_production_services(scope, context)
  local _ = context
  local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
  local BattleScene = require("libs.hgss.src.presentation.BattleScene")
  local EffectStagingFixture = require("tests.support.EffectStagingFixture")
  local FakeCache = require("tests.support.FakeCache")
  local Hashing = require("romdump.src.digest.Hashing")
  local CacheFs = require("libs.storage.src.CacheFs")
  local width, height = 16, 8
  local parts = {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      if x == 8 and y == 0 then
        parts[#parts + 1] = string.char(0, 255, 0, 255)
      elseif x == 0 and y == 0 then
        parts[#parts + 1] = string.char(255, 0, 0, 255)
      else
        parts[#parts + 1] = string.char(0, 0, 0, 0)
      end
    end
  end
  local stripBytes = table.concat(parts)
  local stripIdentity = Hashing.sha1hex(stripBytes)
  local stripKey = "battle/sprite/strip/" .. stripIdentity
  local stripPath = BattlePresentationCache.globalResourcePath("effect/content/" .. stripIdentity)
  local cache = CacheFs.forVersion("probe-sprite-cell-pixels", FakeCache.new())
  cache:writeLua(
    BattlePresentationCache.effectPath("TACKLE"),
    EffectStagingFixture.effectRecord("TACKLE", {
      { key = stripKey, kind = "texture", payload = stripPath, contentIdentity = stripIdentity },
    })
  )
  local host = recordingGraphicsEffectHost()
  local envelope = graphicsEffectEnvelope(cache, host, love.graphics)
  local services = envelope:_preparationServices()
  local assets = graphicsEffectHolder(services, "probe-sprite-cell-pixels")
  host.answers["TACKLE"] = "ready"
  cache:write(BattlePresentationCache.effectMarkerPath("TACKLE"), "probe-marker")
  cache:writeLua(stripPath, { width = width, height = height, rgba8888 = stripBytes })
  Assert.equal(assets:demandEffect("TACKLE"), true, "the closed staged effect reads ready")
  local effect = assets:loadEffect("TACKLE")
  Assert.notNil(effect, "the ready effect loads")
  local lease = assets:resolveEffectResource(effect, stripKey)
  Assert.notNil(lease, "the staged strip admits")
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  local first = scene:allocEffect("sprite-crop-probe")
  scene:setEffectPicture(first.id, {
    assetKey = stripKey,
    selector = "sprite-crop",
    centerX = 32,
    centerY = 24,
    zCenter = 0,
    width = 8,
    height = 8,
    alpha = 1,
    xOffset2 = 8,
    yOffset2 = 0,
    flipH = false,
    flipV = false,
  })
  local second = scene:allocEffect("sprite-flip-probe")
  scene:setEffectPicture(second.id, {
    assetKey = stripKey,
    selector = "sprite-flip",
    centerX = 64,
    centerY = 24,
    zCenter = -1,
    width = 8,
    height = 8,
    alpha = 1,
    xOffset2 = 8,
    yOffset2 = 0,
    flipH = true,
    flipV = false,
  })
  local canvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true }))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  BattleRenderer.drawPane({
    graphics = love.graphics,
    text = {},
    windows = {},
    assets = assets,
    frameKey = "default",
    sceneImageKey = "scene:probe",
  }, {
    battlers = {},
    effectInstances = scene:effectViews(),
    hudPatchSpans = {},
    hudSections = {},
  }, "detail", {})
  love.graphics.setCanvas()
  local data = scope:own(canvas:newImageData())
  Assert.equal(
    countColor(data, { x = 28, y = 20, width = 8, height = 8 }, { 0, 255, 0 }),
    1,
    "the cropped band paints its staged texel at native coordinates"
  )
  Assert.equal(
    countColor(data, { x = 28, y = 20, width = 8, height = 8 }, { 255, 0, 0 }),
    0,
    "the crop excludes the uncropped strip origin"
  )
  local _, flippedGreen, _, flippedAlpha = data:getPixel(67, 20)
  Assert.equal(quantize(flippedGreen), 255, "the authored flip mirrors the texel to the far edge")
  Assert.equal(quantize(flippedAlpha), 255, "the mirrored texel stays opaque")
  local _, _, _, plainAlpha = data:getPixel(60, 20)
  Assert.equal(quantize(plainAlpha), 0, "the mirrored-away edge stays transparent")
  assets:dispose()
  envelope:dispose()
end

-- A staged particle archive runs through the real player, factory,
-- scene, holder, and renderer and paints native pixels: the production
-- resolver hands the task its decoded emitters, the staged texture
-- uploads to a real image, the live run publishes sprites mid-flight,
-- one canvas frame carries staged ink, completion retires every sprite,
-- and every lease returns exactly once.
function T.production_particle_effect_paints_native_pixels_and_releases(scope, context)
  local _ = context
  local BattleAnimationPlayer = require("libs.hgss.src.presentation.BattleAnimationPlayer")
  local BattleAnimationSchema = require("libs.assets.src.battle.BattleAnimationSchema")
  local BattleEffectTasks = require("libs.hgss.src.presentation.BattleEffectTasks")
  local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
  local BattleScene = require("libs.hgss.src.presentation.BattleScene")
  local EffectStagingFixture = require("tests.support.EffectStagingFixture")
  local FakeCache = require("tests.support.FakeCache")
  local Hashing = require("romdump.src.digest.Hashing")
  local CacheFs = require("libs.storage.src.CacheFs")
  local archiveKey = "battle/particle/tackle"
  local textureKey = "battle/particle/tackle-texture"
  local archivePath = "effects/probe-pixel-archive.lua"
  local texturePath = "effects/probe-pixel-texture.lua"
  local textureBytes = EffectStagingFixture.rgba(8, 8)
  local params = {}
  for index = 1, 42 do
    params[index] = 0
  end
  params[29], params[30], params[24], params[32] = 12, 12, 0, 1
  local archive = {
    emitters = {
      { features = { "color", "random" }, params = params, textureSlot = 0, textureKey = textureKey },
    },
    resources = { { textureKey = textureKey, paletteKey = nil } },
  }
  local cache = CacheFs.forVersion("probe-particle-pixels", FakeCache.new())
  cache:writeLua(BattlePresentationCache.effectPath("TACKLE"), {
    schema = BattleAnimationSchema.EFFECT_SCHEMA,
    key = "TACKLE",
    catalogIdentity = "probe-catalog",
    program = {
      entry = "main",
      instructions = {
        {
          op = "create-battler-effect",
          resource = archiveKey,
          emitterPosition = "solo-enemy",
          taskKind = "battler-effect-continuation",
        },
        { op = "wait-for-battler-effects", cursorRule = "advance-when-effects-finish" },
      },
      subprograms = {},
      taskKinds = { "battler-effect-continuation" },
    },
    dependencies = { archiveKey, textureKey },
    resources = {
      [archiveKey] = {
        kind = "particle",
        payload = archivePath,
        contentIdentity = Hashing.sha1hex(textureBytes .. "probe-pixel-archive"),
      },
      [textureKey] = {
        kind = "texture",
        payload = texturePath,
        contentIdentity = Hashing.sha1hex(textureBytes),
      },
    },
    requiredContext = {},
  })
  cache:write(BattlePresentationCache.effectMarkerPath("TACKLE"), "probe-marker")
  cache:writeLua(archivePath, archive)
  cache:writeLua(texturePath, { width = 8, height = 8, rgba8888 = textureBytes })
  local host = recordingGraphicsEffectHost()
  host.answers["TACKLE"] = "ready"
  local envelope = graphicsEffectEnvelope(cache, host, love.graphics)
  local services = envelope:_preparationServices()
  local assets = graphicsEffectHolder(services, "probe-particle-pixels")
  Assert.equal(assets:demandEffect("TACKLE"), true, "the staged closure reads ready")
  local effect = assets:loadEffect("TACKLE")
  Assert.notNil(effect, "the ready effect loads before resolving")
  local lease = assets:resolveEffectResource(effect, archiveKey)
  Assert.notNil(lease, "the archive admits through production services")
  Assert.isTrue(type(lease.data) == "table", "the archive lease carries its decoded record")
  Assert.notNil(lease.data.emitters, "the decoded record stages its emitters")
  local texture = assets:resolveEffectResource(effect, textureKey)
  Assert.notNil(texture, "the texture admits beside the archive")
  Assert.equal(texture.rgba8888, textureBytes, "the admitted lease shares its exact staged bytes")
  local image = assets:drawable(textureKey)
  Assert.notNil(image, "the admitted texture resolves to a real image")
  Assert.equal(image:getWidth(), 8, "the uploaded image keeps its staged width")
  assets:releaseEffectResource(lease)
  assets:releaseEffectResource(texture)
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  local audio = {}
  function audio.play(_) end
  function audio.stop(_) end
  function audio.isFinished(_)
    return true
  end
  local journal = { acquired = {}, released = {} }
  local holderServices = {}
  function holderServices.resolve(key)
    journal.acquired[#journal.acquired + 1] = key
    return assets:resolveEffectResource(effect, key)
  end
  function holderServices.release(resolved)
    journal.released[#journal.released + 1] = type(resolved) == "table" and resolved.key or resolved
    return assets:releaseEffectResource(resolved)
  end
  local player = assert(BattleAnimationPlayer.new({
    scene = scene,
    audio = audio,
    resources = holderServices,
    tasks = BattleEffectTasks,
  }))
  local handle = assert(player:start({
    launchId = "probe-particle-pixels",
    packetId = 1,
    event = { sequence = 1, actionId = 1, hitIndex = 1, effectKey = "TACKLE" },
    visualSeed = 4242,
    topology = {
      attacker = { combatant = 1, activation = 1, slot = "solo-player", sideType = 0 },
      targets = { { combatant = 3, activation = 3, slot = "solo-enemy", sideType = 1 } },
    },
  }, effect.program))
  local canvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true }))
  local painted = false
  for _ = 1, 600 do
    player:stepSourceTick({ tick = 1 })
    local live = 0
    for _, view in ipairs(scene:effectViews()) do
      if view.picture ~= nil then
        live = live + 1
      end
    end
    if live > 0 and not painted then
      love.graphics.setCanvas(canvas)
      love.graphics.clear(0, 0, 0, 0)
      BattleRenderer.drawPane({
        graphics = love.graphics,
        text = {},
        windows = {},
        assets = assets,
        frameKey = "default",
        sceneImageKey = "scene:probe",
      }, {
        battlers = {},
        effectInstances = scene:effectViews(),
        hudPatchSpans = {},
        hudSections = {},
      }, "detail", {})
      love.graphics.setCanvas()
      local data = scope:own(canvas:newImageData())
      painted = countInk(data, { x = 160, y = 48, width = 64, height = 64 }) > 0
    end
    local status = player:status(handle)
    if status == "complete" or status == "failed" then
      break
    end
  end
  Assert.equal(player:status(handle), "complete", "the production-fed run reaches its own completion")
  Assert.isTrue(painted, "a live frame of the run carries staged effect ink")
  Assert.equal(#scene:effectViews(), 0, "retirement releases every owned sprite record")
  player:dispose()
  local acquired, released = {}, {}
  for _, key in ipairs(journal.acquired) do
    acquired[key] = (acquired[key] or 0) + 1
  end
  for _, key in ipairs(journal.released) do
    released[key] = (released[key] or 0) + 1
  end
  for key, count in pairs(acquired) do
    Assert.equal(released[key] or 0, count, "the settled run releases " .. tostring(key) .. " exactly once")
  end
  assets:dispose()
  local stale, staleErr = assets:demandEffect("TACKLE")
  Assert.isNil(stale, "a disposed launch publishes no stale readiness")
  Assert.isTrue(type(staleErr) == "string" and staleErr ~= "", "the stale demand fails with context")
  envelope:dispose()
end

-- A routine-move visual program runs through the real player, factory,
-- scene, holder, and renderer without publishing proxy pictures. Visual
-- task bodies that only move scene state (picture offsets, scrolls,
-- palette fades) publish no drawable of their own: the production
-- renderer rejects unknown picture keys, so a published proxy would fail
-- the draw instead of painting. The program below is lowered through the
-- real animation compiler from real source words (a parameterized picture
-- offset callback, the shape routine contact moves use for their visual
-- strike), executes against a real scene, and draws twice through the
-- production renderer to canvas: completion comes from the compiled
-- duration, the owned picture patch applies mid-run and restores on
-- completion, no transient picture is ever published, and both frames
-- settle to identical settled pixels.
function T.routine_visual_task_program_paints_no_proxy_pictures_and_settles(scope, context)
  local _ = context
  local BattleAnimationCompiler = require("romdump.src.digest.battle.BattleAnimationCompiler")
  local BattleAnimationSources = require("romdump.src.config.BattleAnimationSources")
  local BattleAnimationPlayer = require("libs.hgss.src.presentation.BattleAnimationPlayer")
  local BattleEffectTasks = require("libs.hgss.src.presentation.BattleEffectTasks")
  local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
  local BattleScene = require("libs.hgss.src.presentation.BattleScene")
  local FakeCache = require("tests.support.FakeCache")
  local CacheFs = require("libs.storage.src.CacheFs")
  local function u32(value)
    return string.char(
      value % 256,
      math.floor(value / 256) % 256,
      math.floor(value / 65536) % 256,
      math.floor(value / 16777216) % 256
    )
  end
  local words = { 45, 51, 3, 10, 0xFFF0, 258, 50, 4 }
  local stream = {}
  for _, word in ipairs(words) do
    stream[#stream + 1] = u32(word)
  end
  local program = assert(BattleAnimationCompiler.compile({
    key = "probe-routine-visual",
    stream = table.concat(stream),
    resolveSourceInput = function(role, operands)
      Assert.equal(role, "battle-animation-callback", "the visual word asks for its source callback")
      return BattleAnimationSources.resolveBattleAnimationCallback(operands)
    end,
  }))
  Assert.equal(
    program.instructions[1].taskKind,
    "pokemon-picture-selected-horizontal-offset-transition",
    "the lowered program keeps its source visual task kind"
  )
  local cache = CacheFs.forVersion("probe-routine-visual", FakeCache.new())
  local _, texturePath, textureBytes = stagedGraphicsSpark(cache, "TACKLE", 8, 8)
  cache:write(BattlePresentationCache.effectMarkerPath("TACKLE"), "probe-marker")
  cache:writeLua(texturePath, { width = 8, height = 8, rgba8888 = textureBytes })
  local host = recordingGraphicsEffectHost()
  host.answers["TACKLE"] = "ready"
  local envelope = graphicsEffectEnvelope(cache, host, love.graphics)
  local services = envelope:_preparationServices()
  local assets = graphicsEffectHolder(services, "probe-routine-visual")
  Assert.equal(assets:demandEffect("TACKLE"), true, "the staged closure reads ready")
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  local audio = {}
  function audio.play(_name) end
  function audio.stop(_name) end
  function audio.isFinished(_name)
    return true
  end
  local resources = {}
  function resources.resolve(key)
    error("state-only visual tasks stage no leases: " .. tostring(key), 0)
  end
  function resources.release(_lease)
    error("state-only visual tasks release no leases", 0)
  end
  local player = assert(BattleAnimationPlayer.new({
    scene = scene,
    audio = audio,
    resources = resources,
    tasks = BattleEffectTasks,
  }))
  local packet = {
    launchId = "probe-routine-visual",
    packetId = 1,
    event = { sequence = 1, actionId = 1, hitIndex = 1, effectKey = "probe-routine-visual" },
    visualSeed = 4242,
    topology = {
      attacker = { combatant = 1, activation = 1, slot = "solo-player", sideType = 0 },
      targets = { { combatant = 3, activation = 3, slot = "solo-enemy", sideType = 1 } },
    },
  }
  local handle = assert(player:start(packet, program))
  player:stepSourceTick({ tick = 1 })
  local firstPhase = player:status(handle)
  Assert.isTrue(
    firstPhase ~= "complete" and firstPhase ~= "failed",
    "the visual run stays alive past its first tick, got " .. tostring(firstPhase)
  )
  Assert.equal(#scene:effectViews(), 0, "spawning the callback publishes no drawable picture")
  player:stepSourceTick({ tick = 2 })
  Assert.isTrue(
    scene:pictureState({ combatant = 1, activation = 1 }) ~= nil,
    "the running callback owns its activation picture patch"
  )
  Assert.equal(#scene:effectViews(), 0, "the running callback still publishes no drawable picture")
  for _ = 1, 120 do
    if player:status(handle) == "complete" then
      break
    end
    player:stepSourceTick({ tick = 1 })
  end
  Assert.equal(player:status(handle), "complete", "the visual run reaches its compiled completion")
  Assert.isNil(
    scene:pictureState({ combatant = 1, activation = 1 }),
    "completion restores the owned activation exactly"
  )
  Assert.equal(#scene:effectViews(), 0, "completion publishes no lingering drawable")
  local function drawFrame()
    local canvas = scope:own(love.graphics.newCanvas(256, 192, { format = "rgba8", readable = true }))
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    BattleRenderer.drawPane({
      graphics = love.graphics,
      text = {},
      windows = {},
      assets = assets,
      frameKey = "default",
      sceneImageKey = "scene:probe",
    }, {
      battlers = {},
      effectInstances = scene:effectViews(),
      hudPatchSpans = {},
      hudSections = {},
    }, "detail", {})
    love.graphics.setCanvas()
    return scope:own(canvas:newImageData())
  end
  local first = drawFrame()
  local second = drawFrame()
  Assert.equal(
    imageDataDigest(first),
    imageDataDigest(second),
    "settled visual state paints identical pixels on every frame"
  )
  Assert.equal(
    countInk(first, { x = 0, y = 0, width = 256, height = 192 }),
    0,
    "no proxy picture inks the settled frame"
  )
  player:dispose()
  assets:dispose()
  envelope:dispose()
end

-- Corrupt staged media and driver failures are terminal with context:
-- a truncated payload and a failing GPU upload both fail the selected
-- effect with its launch, effect, and resource identity, never hang as
-- pending, and leave the field recoverable for other effects.
function T.failed_effect_upload_reports_context_and_leaves_no_held_handles(scope, context)
  local FakeCache = require("tests.support.FakeCache")
  local CacheFs = require("libs.storage.src.CacheFs")
  local cache = CacheFs.forVersion("probe-effect-failure", FakeCache.new())
  local textureKey, texturePath = stagedGraphicsSpark(cache, "TACKLE", 8, 8)
  local host = recordingGraphicsEffectHost()
  host.answers["TACKLE"] = "ready"
  local envelope = graphicsEffectEnvelope(cache, host, love.graphics)
  local services = envelope:_preparationServices()
  local assets = graphicsEffectHolder(services, "probe-failure")
  cache:write(BattlePresentationCache.effectMarkerPath("TACKLE"), "probe-marker")
  cache:writeLua(texturePath, { width = 8, height = 8, rgba8888 = "short" })
  Assert.equal(assets:demandEffect("TACKLE"), true, "marker and payload presence read ready before decoding")
  local effect = assets:loadEffect("TACKLE")
  Assert.notNil(effect, "the ready effect loads before admission")
  local lease, failure = assets:resolveEffectResource(effect, textureKey)
  Assert.isNil(lease, "the truncated payload hands out no image")
  Assert.isTrue(type(failure) == "string" and failure ~= "", "the corrupt payload fails terminally")
  local reason = failure --[[@as string]]
  Assert.isTrue(reason:find(textureKey, 1, true) ~= nil, "the failure names its resource: " .. reason)
  Assert.isTrue(reason:find("TACKLE", 1, true) ~= nil, "the failure names its effect: " .. reason)
  Assert.isTrue(reason:find("probe-failure", 1, true) ~= nil, "the failure names its launch: " .. reason)
  local again, againErr = assets:demandEffect("TACKLE")
  Assert.isNil(again, "the failed effect never reads ready again")
  Assert.isTrue(
    type(againErr) == "string" and againErr:find(textureKey, 1, true) ~= nil,
    "the terminal failure replays instead of hanging pending"
  )
  Assert.isNil(assets:drawable(textureKey), "the failed texture hands out nothing")
  local splashKey, splashPath, splashBytes = stagedGraphicsSpark(cache, "SPLASH", 2, 2)
  cache:write(BattlePresentationCache.effectMarkerPath("SPLASH"), "probe-marker")
  cache:writeLua(splashPath, { width = 2, height = 2, rgba8888 = splashBytes })
  host.answers["SPLASH"] = "ready"
  local fresh = graphicsEffectHolder(services, "probe-failure-recovery")
  Assert.equal(fresh:demandEffect("SPLASH"), true, "the field stays recoverable for other effects")
  local splash = fresh:loadEffect("SPLASH")
  Assert.notNil(splash, "the other effect loads")
  Assert.notNil(fresh:resolveEffectResource(splash, splashKey), "the other effect admits")
  Assert.notNil(fresh:drawable(splashKey), "the other effect uploads")
  fresh:dispose()
  assets:dispose()
  envelope:dispose()
  local failingGraphics = setmetatable({
    newImage = function(_pixels)
      error("probe gpu boom")
    end,
  }, { __index = love.graphics })
  local gpuCache = CacheFs.forVersion("probe-effect-gpu-failure", FakeCache.new())
  local gpuTextureKey, gpuTexturePath, gpuTextureBytes = stagedGraphicsSpark(gpuCache, "TACKLE", 8, 8)
  gpuCache:write(BattlePresentationCache.effectMarkerPath("TACKLE"), "probe-marker")
  gpuCache:writeLua(gpuTexturePath, { width = 8, height = 8, rgba8888 = gpuTextureBytes })
  local gpuHost = recordingGraphicsEffectHost()
  gpuHost.answers["TACKLE"] = "ready"
  local gpuEnvelope = graphicsEffectEnvelope(gpuCache, gpuHost, failingGraphics)
  local gpuServices = gpuEnvelope:_preparationServices()
  local gpuAssets = graphicsEffectHolder(gpuServices, "probe-gpu-failure")
  Assert.equal(gpuAssets:demandEffect("TACKLE"), true, "the staged closure reads ready before the driver fails")
  local gpuEffect = gpuAssets:loadEffect("TACKLE")
  Assert.notNil(gpuEffect, "the ready effect loads before the driver fails")
  local gpuLease, gpuFailure = gpuAssets:resolveEffectResource(gpuEffect, gpuTextureKey)
  Assert.isNil(gpuLease, "the driver failure hands out no image")
  Assert.isTrue(type(gpuFailure) == "string" and gpuFailure ~= "", "the driver failure is terminal with context")
  Assert.isTrue(
    (gpuFailure --[[@as string]]):find(gpuTextureKey, 1, true) ~= nil,
    "the driver failure names its resource"
  )
  local gpuAgain, gpuAgainErr = gpuAssets:demandEffect("TACKLE")
  Assert.isNil(gpuAgain, "the driver-failed effect never reads ready again")
  Assert.isTrue(type(gpuAgainErr) == "string" and gpuAgainErr ~= "", "the driver failure replays")
  gpuAssets:dispose()
  gpuEnvelope:dispose()
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump" }
suite.metadata.derivedAssets = {
  "battle-presentation:global",
  "battle-scene:general/grass/day",
  "field-font:global",
  "field-ui:global",
  "mon-portrait-page:34",
  "mon-portrait-page:164",
}
return suite
