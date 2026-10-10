-- Presented-battle coverage through the real production services: the
-- field-local envelope builds its preparation services with the live host
-- graphics namespace (never the test-only image map), the real battle
-- screen prepares through them against the staged cache, and production
-- frames render to a canvas with real staged pixels. A second leg forces
-- a preparation failure and proves the deterministic failed state with
-- context: no raise, no held cue mistaken for success, no blank success.

local Assert = require("tests.support.Assert")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local BattlePresentationModel = require("game.hgss.src.battle.BattlePresentationModel")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldBattlePresentation = require("game.hgss.src.field.FieldBattlePresentation")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldWindowRenderer = require("libs.hgss.src.ui.FieldWindowRenderer")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
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
  local uiManifest = assert(cacheFs:loadLua(FieldUiAssetCache.manifestPath()), versionId .. " loads its field-UI manifest")
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
  local portraits = assert(
    cacheFs:loadLua(MonCache.portraitManifestPath()),
    "the staged cache carries its portrait manifest"
  )
  local entries = assert(portraits.entries, "the staged cache plans its portrait entries")
  local markers =
    assert(cacheFs:loadLua(MonCache.indexPath()), "the staged cache carries its mon page markers").portraitPages
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
      and MonCache.isPageReady(cacheFs, "portraits", entry.pageId, markers[entry.pageId + 1])
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
    versionId .. " enters its staged launch (mode=" .. tostring(status ~= nil and status.mode)
      .. " err=" .. tostring(status ~= nil and status.error) .. ")",
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
    Assert.isTrue(manifest.verified == true, versionId .. " stages the verified battle manifest")
    local wildRole = assert(manifest.audioRoles.wild, versionId .. " stages its wild music role")
    local text, windows = productionDrawServices(scope, cacheFs, versionId)
    local envelope = FieldBattlePresentation.new({
      cacheFs = cacheFs,
      graphics = love.graphics,
      windows = windows,
      text = text,
      audio = recordingAudio(),
      measureDisplay = compactMeasurement,
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
      Assert.isTrue(
        countColor(firstPixels, hostRect(frame, bar), { 51, 204, 51 }) > 10,
        versionId .. " draws the " .. side.label .. " health bar"
      )
    end
    for _, event in ipairs(host.notifies) do
      Assert.isTrue(event ~= "screen-failed", versionId .. " never fails its staged launch")
    end
    love.graphics.setCanvas()
    envelope:dispose()
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
    local cacheFs = hidingCacheFs(
      CacheFs.forVersion(versionId),
      BattlePresentationCache.sceneImagePath(SAD_SCENE_KEY)
    )
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
