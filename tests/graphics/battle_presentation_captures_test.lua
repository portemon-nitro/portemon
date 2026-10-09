-- Real staged-asset pixel captures for the battle presentation: the real
-- battle screen with its paired and compact renderers draws the staged day
-- grass scene, the staged menu and HUD composites, cropped staged mon
-- portraits, and the staged field font and frame strip into offscreen
-- canvases. Pixel censuses (never pixel-perfect matches) prove prompt and
-- command text ink, the triangular selection cursor, selected frame
-- borders, health-bar and composite ink with HUD wording ink inside the
-- published HUD bounds, menu artwork with its labels, and narration ink; a second render of each
-- view must be identical. PNG copies land beside the run for inspection.

local Assert = require("tests.support.Assert")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local BattlePresentationModel = require("game.hgss.src.battle.BattlePresentationModel")
local BattleScreenState = require("game.hgss.src.battle.BattleScreenState")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldWindowRenderer = require("libs.hgss.src.ui.FieldWindowRenderer")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local MonCache = require("libs.assets.src.MonCache")
local PngWriter = require("libs.assets.src.PngWriter")
local RomImporter = require("romdump.src.source.RomImporter")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local SCENE_KEY = "general/grass/day"
local LEAD_SPECIES = "CHIKORITA"
local FOE_SPECIES = "RATTATA"
-- Portrait pages holding the capture pair under the current deterministic
-- page layout. The mapping test below fails loudly with the fresh page
-- identities when the layout repaginates, so the staged page closure here
-- is updated instead of silently rendering the wrong mon.
local LEAD_BACK_PAGE = 34
local FOE_FRONT_PAGE = 164
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
    signature = "battle-captures:compact",
  }
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
    signature = "battle-captures:dual",
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

-- Counts pixels in a host rectangle whose quantized color differs between
-- two captures; every differing pixel fails loudly only through the
-- caller's threshold.
local function regionDistance(first, second, rect, stride)
  Assert.equal(first:getWidth(), second:getWidth(), "compared captures share their width")
  Assert.equal(first:getHeight(), second:getHeight(), "compared captures share their height")
  local changed = 0
  for y = rect.y, rect.y + rect.height - 1, stride do
    for x = rect.x, rect.x + rect.width - 1, stride do
      local r1, g1, b1, a1 = first:getPixel(x, y)
      local r2, g2, b2, a2 = second:getPixel(x, y)
      if
        quantize(r1) ~= quantize(r2)
        or quantize(g1) ~= quantize(g2)
        or quantize(b1) ~= quantize(b2)
        or quantize(a1) ~= quantize(a2)
      then
        changed = changed + 1
      end
    end
  end
  return changed
end

local function decodeData(scope, cacheFs, path, what)
  local bytes = assert(cacheFs:read(path), "the staged cache carries " .. what .. " at " .. path)
  return scope:own(love.image.newImageData(love.filesystem.newFileData(bytes, path)))
end

local function stagedImage(scope, cacheFs, path, what)
  local image = scope:own(love.graphics.newImage(decodeData(scope, cacheFs, path, what)))
  image:setFilter("nearest", "nearest")
  return image
end

-- Crops one staged portrait cell out of its atlas page into its own
-- image: the battle renderer draws one drawable per battler side, so the
-- capture harness resolves the side keys to these per-side crops. The
-- page identity is pinned above and verified against the staged manifest
-- on every run.
---@param scope table test-owned graphics scope
---@param cacheFs table versioned derived cache
---@param selector string canonical staged portrait selector
---@param pageId integer expected staged page identity
---@return table love image holding exactly the staged cell
---@return table readable pixels of the cropped cell
local function cropPortrait(scope, cacheFs, selector, pageId)
  local manifest = assert(cacheFs:loadLua(MonCache.portraitManifestPath()), "the staged cache carries its portrait manifest")
  local entry = assert(manifest.entries[selector], "the staged manifest plans " .. selector)
  Assert.equal(
    entry.pageId,
    pageId,
    "portrait pagination drifted for "
      .. selector
      .. ": staged on page "
      .. tostring(entry.pageId)
      .. ", update the staged page closure to that page"
  )
  local bytes = assert(
    cacheFs:read(MonCache.pageImagePath("portraits", pageId)),
    "the staged cache carries portrait page " .. tostring(pageId)
  )
  local page = scope:own(love.image.newImageData(love.filesystem.newFileData(bytes, "portraits/" .. pageId)))
  local cropped = scope:own(love.image.newImageData(entry.width, entry.height))
  cropped:paste(page, 0, 0, entry.x, entry.y, entry.width, entry.height)
  local occupied = 0
  for y = 0, cropped:getHeight() - 1 do
    for x = 0, cropped:getWidth() - 1 do
      local _, _, _, alpha = cropped:getPixel(x, y)
      if alpha > 0 then
        occupied = occupied + 1
      end
    end
  end
  Assert.isTrue(occupied > 100, "the staged cell carries portrait pixels for " .. selector)
  local image = scope:own(love.graphics.newImage(cropped))
  image:setFilter("nearest", "nearest")
  return image, cropped
end

-- Mirrors the envelope's demand validation so the capture harness stages
-- exactly what the production demand requires: one screen key expands to
-- its four staged gender/finish selectors, and every selector must be
-- planned with a ready page.
---@param cacheFs table versioned derived cache
---@param pageKey string demand portrait key under validation
local function requirePortraitKey(cacheFs, pageKey)
  local species, form, facing = tostring(pageKey):match("^([^/]+)/([0-9]+)/([a-z]+)$")
  Assert.notNil(species, "portrait demands name their species: " .. pageKey)
  Assert.notNil(form, "portrait demands name their form: " .. pageKey)
  Assert.isTrue(facing == "front" or facing == "back", "portrait demands name their facing: " .. pageKey)
  local portraits = assert(cacheFs:loadLua(MonCache.portraitManifestPath()), "the staged cache carries its portrait manifest")
  local entries = assert(portraits.entries, "the staged portrait manifest carries entries")
  local index = assert(cacheFs:loadLua(MonCache.indexPath()), "the staged cache carries its mon index")
  local markers = assert(index.portraitPages, "the staged mon index carries portrait page markers")
  for _, gender in ipairs({ "male", "female" }) do
    for _, finish in ipairs({ "plain", "shiny" }) do
      local selector = MonCache.portraitSelector(species, tonumber(form), gender, finish == "shiny", facing)
      local entry = assert(entries[selector], "the staged manifest plans " .. selector)
      Assert.isTrue(
        MonCache.isPageReady(cacheFs, "portraits", entry.pageId, markers[entry.pageId + 1]),
        "portrait page " .. tostring(entry.pageId) .. " is staged for " .. selector
      )
    end
  end
end

---@param scope table test-owned graphics scope
---@param cacheFs table versioned derived cache
---@param versionId string ready game version under capture
---@return table image services mapping drawable keys to staged images
local function captureServices(scope, cacheFs, versionId)
  local manifest = BattlePresentationCache.load(cacheFs)
  Assert.isTrue(manifest.verified == true, versionId .. " stages the verified battle manifest")
  local images = {}
  images["scene:" .. SCENE_KEY] = stagedImage(scope, cacheFs, BattlePresentationCache.sceneImagePath(SCENE_KEY), versionId .. " battle scene")
  images["hud:enemy"] = stagedImage(scope, cacheFs, assert(manifest.enemyHud, versionId .. " carries enemy HUD").image, versionId .. " enemy HUD")
  images["hud:player"] = stagedImage(scope, cacheFs, assert(manifest.playerHud, versionId .. " carries player HUD").image, versionId .. " player HUD")
  images["menu:command"] = stagedImage(scope, cacheFs, assert(manifest.command, versionId .. " carries command art").image, versionId .. " command art")
  images["menu:moves"] = stagedImage(scope, cacheFs, assert(manifest.moves, versionId .. " carries move art").image, versionId .. " move art")
  images["menu:target"] = stagedImage(scope, cacheFs, assert(manifest.target, versionId .. " carries target art").image, versionId .. " target art")
  images["arrow"] = stagedImage(scope, cacheFs, assert(manifest.arrow, versionId .. " carries the arrow").image, versionId .. " arrow")
  local gauges = assert(manifest.partyGauges[1], versionId .. " carries party gauges")
  images["gauges:player"] = stagedImage(scope, cacheFs, gauges.image, versionId .. " player gauges")
  images["gauges:enemy"] = stagedImage(scope, cacheFs, gauges.image, versionId .. " enemy gauges")
  local portraitCells = {}
  local foeImage, foeCell = cropPortrait(scope, cacheFs, MonCache.portraitSelector(FOE_SPECIES, 0, "male", false), FOE_FRONT_PAGE)
  images["mon:enemy:front"] = foeImage
  portraitCells["mon:enemy:front"] = foeCell
  local leadImage, leadCell =
    cropPortrait(scope, cacheFs, MonCache.portraitSelector(LEAD_SPECIES, 0, "male", false, "back"), LEAD_BACK_PAGE)
  images["mon:player:back"] = leadImage
  portraitCells["mon:player:back"] = leadCell
  local services = { prepared = {} }
  function services.prepare(demand)
    Assert.isTrue(type(demand) == "table", versionId .. " demands arrive as records")
    services.prepared[#services.prepared + 1] = demand
    for _, sceneKey in ipairs(demand.scenes or {}) do
      Assert.notNil(BattlePresentationCache.parseSceneKey(sceneKey), versionId .. " demands a known scene: " .. tostring(sceneKey))
      local record, recordErr = BattlePresentationCache.loadScene(cacheFs, sceneKey)
      Assert.notNil(record, versionId .. " stages its scene: " .. tostring(recordErr))
      local bytes = assert(cacheFs:read(BattlePresentationCache.sceneImagePath(sceneKey)), versionId .. " stages its scene image")
      Assert.equal(
        #bytes,
        PngWriter.encodedSize(record.canvasWidth, record.canvasHeight),
        versionId .. " stages the complete scene image"
      )
    end
    for _, page in ipairs(demand.pages or {}) do
      requirePortraitKey(cacheFs, page)
    end
    return true
  end
  function services.drawable(key)
    assert(type(key) == "string" and key ~= "", "image resolution names its key")
    return images[key]
  end
  function services.release(key)
    images[key] = nil
  end
  return services, images, portraitCells
end

-- The production field composition borrows its battle text and window
-- services over the shared field renderers with the player frame option
-- resolving the default frame: the capture harness mirrors that seam so
-- the same font and frame strip reach the battle renderers.
---@param scope table test-owned graphics scope
---@param cacheFs table versioned derived cache
---@param versionId string ready game version under capture
---@return table text services
---@return table window services
local function captureDrawServices(scope, cacheFs, versionId)
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

---@param scope table test-owned graphics scope
---@param cacheFs table versioned derived cache
---@param versionId string ready game version under capture
---@param measurement table caller-owned display facts
---@return table live battle screen behind the capture
---@return table staged images behind the screen drawables
---@return table cropped portrait cells behind the mon drawables
local function captureScreen(scope, cacheFs, versionId, measurement)
  local manifest = BattlePresentationCache.load(cacheFs)
  local text, windows = captureDrawServices(scope, cacheFs, versionId)
  local services, images, portraitCells = captureServices(scope, cacheFs, versionId)
  local submitted = {}
  local screen = BattleScreenState.new({
    launchId = "battle-capture",
    manifest = manifest,
    model = BattlePresentationModel,
    submit = function(reply)
      submitted[#submitted + 1] = reply
      return true
    end,
    measureDisplay = function()
      return measurement
    end,
    assets = services,
    text = text,
    windows = windows,
    audio = recordingAudio(),
    overrides = { sceneKey = SCENE_KEY },
  })
  return screen, images, portraitCells
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

local function openingPacket()
  local after = {
    own = {
      {
        combatant = 0,
        side = 1,
        species = LEAD_SPECIES,
        form = 0,
        selector = "back",
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
    launchId = "battle-capture",
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

-- Pumps one screen through its opening cues with the given packet until
-- the command request is exposed: the send-out cue holds on the
-- player-side portrait, so arrival proves the mon drawables resolved.
---@param screen table live battle screen under driving
---@param versionId string ready game version under capture
---@param packet table delivery packet opening the staged battle
local function drivePacketToCommand(screen, versionId, packet)
  local port = screen:presentationPort()
  for _ = 1, 5 do
    screen:updateFixed(TICK)
  end
  Assert.isTrue(port.enter({ launchId = "battle-capture", kind = "wild" }), versionId .. " enters its staged scene")
  port.present(packet)
  local ticks = 0
  while screen:status().request == nil and ticks < DRIVE_BUDGET do
    screen:updateFixed(TICK)
    ticks = ticks + 1
  end
  Assert.notNil(screen:status().request, versionId .. " exposes its command request")
  Assert.equal(screen:status().mode, "command", versionId .. " rests on the command view")
end

-- Pumps one screen through its opening cues until the command request is
-- exposed: the send-out cue holds on the player-side portrait, so arrival
-- proves the mon drawables resolved.
---@param screen table live battle screen under driving
---@param versionId string ready game version under capture
local function driveToCommand(screen, versionId)
  drivePacketToCommand(screen, versionId, openingPacket())
end

---@param screen table live battle screen under capture
---@return table resolved plan carrying panes and content
local function livePlan(screen, versionId)
  local status = screen:status()
  local plan = assert(status.presentation, versionId .. " publishes its plan")
  Assert.isTrue(type(plan.panes) == "table" and #plan.panes > 0, versionId .. " plans its panes")
  return plan
end

---@param plan table resolved plan under capture
---@param versionId string ready game version under capture
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

---@param scope table test-owned graphics scope
---@param screen table live battle screen under capture
---@param width integer host canvas width under capture
---@param height integer host canvas height under capture
---@return table readable pixels of one render
local function renderCapture(scope, screen, width, height)
  local canvas = scope:own(love.graphics.newCanvas(width, height, { format = "rgba8", readable = true }))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  screen:draw({ graphics = love.graphics })
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

local function captureRoot()
  local runDir = os.getenv("PORTEMON_TEST_RUN_DIR")
  if runDir ~= nil and runDir ~= "" then
    return runDir .. "/battle-presentation-captures"
  end
  return nil
end

local function reportRoot()
  local ok, cwd = pcall(love.filesystem.getWorkingDirectory)
  if ok and type(cwd) == "string" and cwd ~= "" then
    return cwd .. "/.agents/tmp/battles/d06-captures"
  end
  return love.filesystem.getSourceBaseDirectory() .. "/../.agents/tmp/battles/d06-captures"
end

local function saveCapture(data, name)
  local directories = { reportRoot() }
  local runRoot = captureRoot()
  if runRoot ~= nil then
    directories[#directories + 1] = runRoot
  end
  for _, directory in ipairs(directories) do
    local quoted = "'" .. directory:gsub("'", "'\\''") .. "'"
    local created = os.execute("mkdir -p -- " .. quoted)
    Assert.isTrue(created == true or created == 0, "the capture directory is writable at " .. directory)
    local file = assert(io.open(directory .. "/" .. name .. ".png", "wb"), "the capture opens at " .. directory)
    file:write(data:encode("png"):getString())
    file:close()
  end
end

-- Counts host pixels whose quantized color exactly matches the given
-- 0..255 triple with a fully opaque sample.
---@param data table readable pixels under census
---@param rect table host rectangle under census
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

-- Counts host pixels matching the decoded staged source at the same
-- 1:1 offset where the source is opaque.
---@param capture table rendered pixels under census
---@param source table decoded staged source pixels
---@param rect table host rectangle under census
---@param offsetX integer source left edge in host coordinates
---@param offsetY integer source top edge in host coordinates
---@return integer matches
---@return integer source-occupied samples
local function countSourceMatches(capture, source, rect, offsetX, offsetY)
  local matches, occupied = 0, 0
  for y = rect.y, rect.y + rect.height - 1 do
    for x = rect.x, rect.x + rect.width - 1 do
      local sx, sy = x - offsetX, y - offsetY
      if sx >= 0 and sy >= 0 and sx < source:getWidth() and sy < source:getHeight() then
        local _, _, _, sourceAlpha = source:getPixel(sx, sy)
        if sourceAlpha > 0.5 then
          occupied = occupied + 1
          local r1, g1, b1, a1 = capture:getPixel(x, y)
          local r2, g2, b2, a2 = source:getPixel(sx, sy)
          if
            quantize(r1) == quantize(r2)
            and quantize(g1) == quantize(g2)
            and quantize(b1) == quantize(b2)
            and quantize(a1) == quantize(a2)
          then
            matches = matches + 1
          end
        end
      end
    end
  end
  return matches, occupied
end

local function hostRect(frame, local_)
  return { x = frame.x + local_.x, y = frame.y + local_.y, width = local_.width, height = local_.height }
end

-- Counts host pixels matching one 16x16 gauge cell sampled row-major
-- from its staged strip, where the strip cell is opaque. Tiles lay out
-- row-major from the state base tile in the single strip row.
---@param capture table rendered pixels under census
---@param strip table decoded staged strip pixels
---@param hostX integer cell left edge in host coordinates
---@param hostY integer cell top edge in host coordinates
---@param baseTile integer state base tile under census
---@return integer matches
---@return integer source-occupied samples
local function countGaugeMatches(capture, strip, hostX, hostY, baseTile)
  local matches, occupied = 0, 0
  for row = 0, 1 do
    for col = 0, 1 do
      local tile = baseTile + row * 2 + col
      for py = 0, 7 do
        for px = 0, 7 do
          local sx, sy = tile * 8 + px, py
          local _, _, _, sourceAlpha = strip:getPixel(sx, sy)
          if sourceAlpha > 0.5 then
            occupied = occupied + 1
            local r1, g1, b1, a1 = capture:getPixel(hostX + col * 8 + px, hostY + row * 8 + py)
            local r2, g2, b2, a2 = strip:getPixel(sx, sy)
            if
              quantize(r1) == quantize(r2)
              and quantize(g1) == quantize(g2)
              and quantize(b1) == quantize(b2)
              and quantize(a1) == quantize(a2)
            then
              matches = matches + 1
            end
          end
        end
      end
    end
  end
  return matches, occupied
end

local function rectanglesOverlap(first, second)
  return first.x < second.x + second.width
    and second.x < first.x + first.width
    and first.y < second.y + second.height
    and second.y < first.y + first.height
end

-- The compact command view carries real staged pixels end to end: the
-- scene viewport fills with scene ink, the prompt and every command cell
-- carry text ink, moving the selection repaints the command box while the
-- prompt stays put, the dock frames ring their content boxes, both health
-- bars draw in their published bar rects, both HUD composites match
-- their staged source strips, and every published HUD wording prints ink
-- inside its own region while pixels outside the published regions still
-- match only scene, strip, or portrait sources.
function T.compact_command_view_uses_real_scene_text_frames_and_hud(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the battle captures need a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local screen, _, portraitCells = captureScreen(scope, cacheFs, versionId, compactMeasurement())
    driveToCommand(screen, versionId)
    local plan = livePlan(screen, versionId)
    Assert.isTrue(plan.content.compact == true, versionId .. " resolves the compact plan")
    local width, height = canvasSize(plan, versionId)
    Assert.equal(width, 256, versionId .. " keeps the compact canvas width")
    Assert.equal(height, 192, versionId .. " keeps the compact canvas height")
    local frame = assert(plan.panes[1].placement.frame, versionId .. " frames its compact pane")
    local content = assert(plan.content, versionId .. " carries its compact content")

    local first = renderCapture(scope, screen, width, height)
    local second = renderCapture(scope, screen, width, height)
    Assert.equal(
      imageDataDigest(first),
      imageDataDigest(second),
      versionId .. " renders the compact command view deterministically"
    )
    saveCapture(first, versionId .. "-compact-command")

    local sceneBox = hostRect(frame, content.scene)
    Assert.isTrue(
      countInk(first, sceneBox) > 20000,
      versionId .. " fills the compact scene viewport with scene ink"
    )

    local promptBox = hostRect(frame, content.prompt.content)
    Assert.isTrue(countInk(first, promptBox) > 100, versionId .. " prints prompt text ink")

    local cells = assert(content.commands.cells, versionId .. " carries its command cells")
    Assert.equal(#cells, 4, versionId .. " lays out four command cells")
    for _, cell in ipairs(cells) do
      Assert.isTrue(
        countInk(first, hostRect(frame, cell)) > 30,
        versionId .. " prints the " .. tostring(cell.id) .. " command label"
      )
    end

    local moved = captureScreen(scope, cacheFs, versionId, compactMeasurement())
    driveToCommand(moved, versionId)
    moved:input({ { type = "navigate", direction = "down" } })
    moved:updateFixed(TICK)
    local movedPlan = livePlan(moved, versionId)
    local movedFrame = assert(movedPlan.panes[1].placement.frame, versionId .. " frames its moved pane")
    local movedContent = assert(movedPlan.content, versionId .. " carries its moved content")
    local movedCapture = renderCapture(scope, moved, width, height)
    local commandBox = hostRect(frame, content.commands.outer)
    Assert.isTrue(
      regionDistance(first, movedCapture, commandBox, 1) > 20,
      versionId .. " repaints the command box under its moved selection"
    )
    Assert.isTrue(
      regionDistance(first, movedCapture, hostRect(movedFrame, movedContent.prompt.outer), 2) < 50,
      versionId .. " keeps the prompt box put under its moved selection"
    )

    for _, dock in ipairs({
      { outer = content.prompt.outer, inner = content.prompt.content, label = "prompt" },
      { outer = content.commands.outer, inner = content.commands.content, label = "command" },
    }) do
      local ring = 0
      local outerBox = hostRect(frame, dock.outer)
      local innerBox = hostRect(frame, dock.inner)
      for y = outerBox.y, outerBox.y + outerBox.height - 1 do
        for x = outerBox.x, outerBox.x + outerBox.width - 1 do
          local inside = x >= innerBox.x
            and x < innerBox.x + innerBox.width
            and y >= innerBox.y
            and y < innerBox.y + innerBox.height
          if not inside then
            local red, green, blue, alpha = first:getPixel(x, y)
            if alpha > 0 and quantize(red) + quantize(green) + quantize(blue) > 0 then
              ring = ring + 1
            end
          end
        end
      end
      Assert.isTrue(ring > 20, versionId .. " rings the " .. dock.label .. " dock with frame ink")
    end

    local hud = assert(content.hud, versionId .. " carries its compact HUD")
    for _, side in ipairs({ { box = hud.enemy, label = "enemy" }, { box = hud.player, label = "player" } }) do
      local bar = assert(side.box.bar, versionId .. " carries its " .. side.label .. " bar")
      Assert.isTrue(
        countColor(first, hostRect(frame, bar), { 51, 204, 51 }) > 10,
        versionId .. " draws the " .. side.label .. " health bar"
      )
    end

    local enemyStrip = decodeData(scope, cacheFs, assert(
      BattlePresentationCache.load(cacheFs).enemyHud,
      versionId .. " carries enemy HUD"
    ).image, versionId .. " enemy HUD source")
    local playerStrip = decodeData(scope, cacheFs, assert(
      BattlePresentationCache.load(cacheFs).playerHud,
      versionId .. " carries player HUD"
    ).image, versionId .. " player HUD source")
    local sceneSource =
      decodeData(scope, cacheFs, BattlePresentationCache.sceneImagePath(SCENE_KEY), versionId .. " scene source")
    for _, side in ipairs({
      { box = hud.enemy, strip = enemyStrip, label = "enemy" },
      { box = hud.player, strip = playerStrip, label = "player" },
    }) do
      local box = hostRect(frame, side.box)
      local matches, occupied = countSourceMatches(first, side.strip, box, box.x, box.y)
      Assert.isTrue(occupied > 20, versionId .. " stages an occupied " .. side.label .. " composite")
      Assert.isTrue(matches / occupied > 0.5, versionId .. " composites the staged " .. side.label .. " artwork")
      local bar = assert(side.box.bar, versionId .. " carries its " .. side.label .. " bar")
      local barBox = hostRect(frame, bar)
      -- Battler pictures draw before the HUD composites, so the foe
      -- picture shows through wherever the player composite stays
      -- transparent: those pixels must match the portrait sources too.
      local portraits = {}
      for _, key in ipairs({ "mon:enemy:front", "mon:player:back" }) do
        local cell = assert(portraitCells[key], versionId .. " crops " .. key)
        local origin = key == "mon:enemy:front" and content.enemyCenter or content.playerCenter
        portraits[#portraits + 1] = {
          data = cell,
          x = frame.x + origin.x,
          y = frame.y + origin.y,
        }
      end
      local textRegions = {}
      for _, region in ipairs(side.box.regions) do
        if type(region.text) == "string" and region.text ~= "" then
          textRegions[#textRegions + 1] = { rect = hostRect(frame, region), id = region.id, ink = 0 }
        end
      end
      Assert.isTrue(
        #textRegions > 0,
        versionId .. " publishes its " .. side.label .. " HUD wording"
      )
      local violations = 0
      for y = box.y, box.y + box.height - 1 do
        for x = box.x, box.x + box.width - 1 do
          local inBar = x >= barBox.x
            and x < barBox.x + barBox.width
            and y >= barBox.y
            and y < barBox.y + barBox.height
          local inRegion = nil
          if not inBar then
            for _, textRegion in ipairs(textRegions) do
              local rect = textRegion.rect
              -- Glyph cells overhang their 12-pixel rows (16-pixel
              -- glyphs plus shadow), so wording ink within 4 pixels of
              -- its region still attributes to that wording.
              if
                x >= rect.x - 4
                and x < rect.x + rect.width + 4
                and y >= rect.y - 4
                and y < rect.y + rect.height + 4
              then
                inRegion = textRegion
                break
              end
            end
          end
          if not inBar then
            local pixel = { first:getPixel(x, y) }
            local function near(source, sx, sy)
              if sx < 0 or sy < 0 or sx >= source:getWidth() or sy >= source:getHeight() then
                return false
              end
              local probe = { source:getPixel(sx, sy) }
              for channel = 1, 4 do
                if math.abs(quantize(pixel[channel]) - quantize(probe[channel])) > 1 then
                  return false
                end
              end
              return true
            end
            local sourced = near(sceneSource, x - sceneBox.x, y - sceneBox.y) or near(side.strip, x - box.x, y - box.y)
            if not sourced then
              for _, portrait in ipairs(portraits) do
                if near(portrait.data, x - portrait.x, y - portrait.y) then
                  sourced = true
                  break
                end
              end
            end
            if not sourced then
              if inRegion ~= nil then
                inRegion.ink = inRegion.ink + 1
              else
                violations = violations + 1
              end
            end
          end
        end
      end
      for _, textRegion in ipairs(textRegions) do
        Assert.isTrue(
          textRegion.ink > 10,
          versionId .. " prints its " .. side.label .. " " .. textRegion.id .. " ink (" .. tostring(
            textRegion.ink
          ) .. " px)"
        )
      end
      Assert.equal(
        violations,
        0,
        versionId .. " paints no extra glyphs outside its published " .. side.label .. " regions"
      )
    end
    local expText = nil
    for _, region in ipairs(hud.player.regions) do
      if region.id == "exp" then
        expText = region.text
      end
    end
    Assert.isTrue(
      type(expText) == "string" and expText ~= "",
      versionId .. " publishes its player numeric experience wording"
    )

    -- Battler pictures draw top-left at the plan image centers, clipped to
    -- the scene viewport: the enemy picture overhangs the pane edge while
    -- the lead picture stops above the dock.
    local enemyPicture = { x = frame.x + content.enemyCenter.x, y = frame.y + content.enemyCenter.y, width = 60, height = 80 }
    local playerPicture = { x = frame.x + content.playerCenter.x, y = frame.y + content.playerCenter.y, width = 80, height = 40 }
    Assert.isFalse(
      rectanglesOverlap(enemyPicture, hostRect(frame, hud.enemy)),
      versionId .. " keeps the foe picture clear of the enemy HUD census"
    )
    Assert.isFalse(
      rectanglesOverlap(playerPicture, hostRect(frame, hud.player)),
      versionId .. " keeps the lead picture clear of the player HUD census"
    )
    for _, picture in ipairs({ { rect = enemyPicture, label = "foe" }, { rect = playerPicture, label = "lead" } }) do
      local changed = 0
      for y = picture.rect.y, picture.rect.y + picture.rect.height - 1 do
        for x = picture.rect.x, picture.rect.x + picture.rect.width - 1 do
          local sx, sy = x - sceneBox.x, y - sceneBox.y
          if sx >= 0 and sy >= 0 and sx < sceneSource:getWidth() and sy < sceneSource:getHeight() then
            local r1, g1, b1 = first:getPixel(x, y)
            local r2, g2, b2 = sceneSource:getPixel(sx, sy)
            if math.abs(r1 - r2) + math.abs(g1 - g2) + math.abs(b1 - b2) > 0.03 then
              changed = changed + 1
            end
          end
        end
      end
      Assert.isTrue(changed > 100, versionId .. " draws its " .. picture.label .. " portrait over the scene")
    end
  end
end

-- The compact Fight view prints its move facts through the staged font:
-- named move labels in their grid cells, the type and PP rows in the
-- information panel, and the Back label, all ringed by the dock frames.
function T.compact_fight_view_prints_real_move_text(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the battle captures need a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local screen = captureScreen(scope, cacheFs, versionId, compactMeasurement())
    driveToCommand(screen, versionId)
    screen:input({ { type = "confirm" } })
    screen:updateFixed(TICK)
    Assert.equal(screen:status().mode, "moves", versionId .. " opens the compact move view")
    local plan = livePlan(screen, versionId)
    local width, height = canvasSize(plan, versionId)
    local frame = assert(plan.panes[1].placement.frame, versionId .. " frames its compact pane")
    local content = assert(plan.content, versionId .. " carries its compact content")

    local first = renderCapture(scope, screen, width, height)
    local second = renderCapture(scope, screen, width, height)
    Assert.equal(
      imageDataDigest(first),
      imageDataDigest(second),
      versionId .. " renders the compact Fight view deterministically"
    )
    saveCapture(first, versionId .. "-compact-fight")

    local labels = assert(content.moveLabels, versionId .. " carries its move label origins")
    Assert.isTrue(#labels >= 2, versionId .. " lays out its move labels")
    Assert.isTrue(
      countInk(first, hostRect(frame, labels[1])) > 5,
      versionId .. " prints its first move label"
    )
    Assert.isTrue(
      countInk(first, hostRect(frame, labels[2])) > 5,
      versionId .. " prints its second move label"
    )
    local info = assert(content.moveInfo, versionId .. " carries its move information rows")
    Assert.isTrue(
      countInk(
          first,
          { x = frame.x + 202, y = frame.y + info.typeRowY, width = 44, height = 12 }
        ) > 5,
      versionId .. " prints its move type row"
    )
    Assert.isTrue(
      countInk(first, { x = frame.x + 202, y = frame.y + info.ppRowY, width = 44, height = 12 }) > 5,
      versionId .. " prints its move PP row"
    )
    local back = assert(content.moveBack, versionId .. " carries its move Back cell")
    Assert.isTrue(
      countInk(first, hostRect(frame, back.rect)) > 5,
      versionId .. " prints its Back label"
    )
  end
end

-- The native paired command view composes real staged art on both panes:
-- the scene with both battlers and the narration window on the detail
-- pane, and the staged command artwork with its labels and party gauges
-- on the interaction pane.
function T.native_command_view_composes_real_scene_menu_and_narration(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the battle captures need a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local screen = captureScreen(scope, cacheFs, versionId, dualMeasurement())
    driveToCommand(screen, versionId)
    local plan = livePlan(screen, versionId)
    Assert.equal(#plan.panes, 2, versionId .. " pairs its native panes")
    local width, height = canvasSize(plan, versionId)
    local detailFrame, interactionFrame = nil, nil
    for _, pane in ipairs(plan.panes) do
      if pane.id == "detail" then
        detailFrame = pane.placement.frame
      elseif pane.id == "interaction" then
        interactionFrame = pane.placement.frame
      end
    end
    Assert.notNil(detailFrame, versionId .. " places its detail pane")
    Assert.notNil(interactionFrame, versionId .. " places its interaction pane")

    local first = renderCapture(scope, screen, width, height)
    local second = renderCapture(scope, screen, width, height)
    Assert.equal(
      imageDataDigest(first),
      imageDataDigest(second),
      versionId .. " renders the native command view deterministically"
    )
    saveCapture(first, versionId .. "-native-command")

    local detailBox = { x = detailFrame.x, y = detailFrame.y, width = 256, height = 192 }
    Assert.isTrue(countInk(first, detailBox) > 20000, versionId .. " fills the detail pane with scene ink")

    local narrationBox = { x = detailFrame.x + 8, y = detailFrame.y + 144, width = 240, height = 40 }
    local narrationInk, narrationFill = 0, 0
    for y = narrationBox.y, narrationBox.y + narrationBox.height - 1 do
      for x = narrationBox.x, narrationBox.x + narrationBox.width - 1 do
        local red, green, blue, alpha = first:getPixel(x, y)
        if alpha > 0 then
          if quantize(red) + quantize(green) + quantize(blue) == 0 then
            narrationFill = narrationFill + 1
          else
            narrationInk = narrationInk + 1
          end
        end
      end
    end
    Assert.isTrue(
      narrationFill > narrationBox.width * narrationBox.height / 2,
      versionId .. " draws the narration window over the scene"
    )
    Assert.isTrue(narrationInk > 30, versionId .. " prints narration text ink")

    local detailScene =
      decodeData(scope, cacheFs, BattlePresentationCache.sceneImagePath(SCENE_KEY), versionId .. " scene source")
    for _, picture in ipairs({
      { rect = { x = detailFrame.x + 192, y = detailFrame.y + 56, width = 64, height = 80 }, label = "foe" },
      { rect = { x = detailFrame.x + 64, y = detailFrame.y + 112, width = 80, height = 32 }, label = "lead" },
    }) do
      local changed = 0
      for y = picture.rect.y, picture.rect.y + picture.rect.height - 1 do
        for x = picture.rect.x, picture.rect.x + picture.rect.width - 1 do
          local sx, sy = x - detailFrame.x, y - detailFrame.y
          if sx >= 0 and sy >= 0 and sx < detailScene:getWidth() and sy < detailScene:getHeight() then
            local r1, g1, b1 = first:getPixel(x, y)
            local r2, g2, b2 = detailScene:getPixel(sx, sy)
            if math.abs(r1 - r2) + math.abs(g1 - g2) + math.abs(b1 - b2) > 0.03 then
              changed = changed + 1
            end
          end
        end
      end
      Assert.isTrue(changed > 50, versionId .. " draws its " .. picture.label .. " portrait on the detail pane")
    end

    local menuSource = decodeData(
      scope,
      cacheFs,
      assert(BattlePresentationCache.load(cacheFs).command, versionId .. " carries command art").image,
      versionId .. " command source"
    )
    local interactionBox = { x = interactionFrame.x, y = interactionFrame.y, width = 256, height = 192 }
    local matches, occupied = countSourceMatches(first, menuSource, interactionBox, interactionFrame.x, interactionFrame.y)
    Assert.isTrue(occupied > 20000, versionId .. " stages an occupied command surface")
    Assert.isTrue(matches / occupied > 0.8, versionId .. " keeps the staged command artwork visible")

    for _, anchor in ipairs({
      { x = 128, y = 83, label = "FIGHT" },
      { x = 40, y = 169, label = "BAG" },
      { x = 216, y = 168, label = "POKEMON" },
      { x = 128, y = 176, label = "RUN" },
    }) do
      local labelBox = { x = interactionFrame.x + anchor.x - 28, y = interactionFrame.y + anchor.y - 6, width = 56, height = 12 }
      local changed = 0
      for y = labelBox.y, labelBox.y + labelBox.height - 1 do
        for x = labelBox.x, labelBox.x + labelBox.width - 1 do
          local sx, sy = x - interactionFrame.x, y - interactionFrame.y
          if sx >= 0 and sy >= 0 and sx < menuSource:getWidth() and sy < menuSource:getHeight() then
            local r1, g1, b1, a1 = first:getPixel(x, y)
            local r2, g2, b2, a2 = menuSource:getPixel(sx, sy)
            if
              quantize(r1) ~= quantize(r2)
              or quantize(g1) ~= quantize(g2)
              or quantize(b1) ~= quantize(b2)
              or quantize(a1) ~= quantize(a2)
            then
              changed = changed + 1
            end
          end
        end
      end
      Assert.isTrue(changed > 10, versionId .. " prints the " .. anchor.label .. " command label")
    end

    -- The staged sprite strips keep the tile geometry the native
    -- renderer samples: both HUD strips 1024x8, the arrow 208x8, the
    -- 16-pixel gauge family 128x8. A producer repagination fails here
    -- before any quad can sample the wrong tiles.
    local stagedManifest = BattlePresentationCache.load(cacheFs)
    local function stagedSize(path, label)
      local record = assert(stagedManifest.images[path], versionId .. " stages " .. label)
      return record.width, record.height
    end
    local enemyHudWidth, enemyHudHeight =
      stagedSize(assert(stagedManifest.enemyHud, versionId .. " carries enemy HUD").image, "enemy HUD")
    Assert.equal(enemyHudWidth, 1024, versionId .. " keeps the enemy strip width")
    Assert.equal(enemyHudHeight, 8, versionId .. " keeps the enemy strip row")
    local playerHudWidth, playerHudHeight =
      stagedSize(assert(stagedManifest.playerHud, versionId .. " carries player HUD").image, "player HUD")
    Assert.equal(playerHudWidth, 1024, versionId .. " keeps the player strip width")
    Assert.equal(playerHudHeight, 8, versionId .. " keeps the player strip row")
    local arrowWidth, arrowHeight =
      stagedSize(assert(stagedManifest.arrow, versionId .. " carries the arrow").image, "arrow")
    Assert.equal(arrowWidth, 208, versionId .. " keeps the arrow strip width")
    Assert.equal(arrowHeight, 8, versionId .. " keeps the arrow strip row")
    local gaugeWidth, gaugeHeight =
      stagedSize(assert(stagedManifest.partyGauges[1], versionId .. " carries party gauges").image, "gauges")
    Assert.equal(gaugeWidth, 128, versionId .. " keeps the gauge strip width")
    Assert.equal(gaugeHeight, 8, versionId .. " keeps the gauge strip row")

    -- The detail pane composites the staged HUD strips at their anchors:
    -- the player first band matches the player strip, the enemy first
    -- band matches the enemy strip over its visible extent.
    local enemyStrip = decodeData(scope, cacheFs, assert(
      stagedManifest.enemyHud,
      versionId .. " carries enemy HUD"
    ).image, versionId .. " enemy HUD source")
    local playerStrip = decodeData(scope, cacheFs, assert(
      stagedManifest.playerHud,
      versionId .. " carries player HUD"
    ).image, versionId .. " player HUD source")
    -- The player second-object opening rows sit above the name row, so
    -- they match the player strip tiles exactly. The enemy
    -- second-object opening rows sit above the foe wording, so their
    -- visible extent matches the enemy strip.
    local playerBandBox = { x = detailFrame.x + 192, y = detailFrame.y + 84, width = 64, height = 8 }
    local playerMatches, playerOccupied =
      countSourceMatches(first, playerStrip, playerBandBox, detailFrame.x + 192 - 256, detailFrame.y + 84)
    Assert.isTrue(playerOccupied > 100, versionId .. " stages an occupied player band")
    Assert.isTrue(playerMatches / playerOccupied > 0.9, versionId .. " composites the staged player artwork")
    local enemyBandBox = { x = detailFrame.x + 58, y = detailFrame.y + 8, width = 64, height = 8 }
    local enemyMatches, enemyOccupied =
      countSourceMatches(first, enemyStrip, enemyBandBox, detailFrame.x + 58 - 256, detailFrame.y + 8)
    Assert.isTrue(enemyOccupied > 100, versionId .. " stages an occupied enemy band")
    Assert.isTrue(enemyMatches / enemyOccupied > 0.9, versionId .. " composites the staged enemy artwork")

    -- Party gauges draw staged source cells by roster visibility: the
    -- standing lead selects the healthy ball cell at its slot origin,
    -- and the revealed foe selects its own cell.
    local gaugeStrip = decodeData(
      scope,
      cacheFs,
      assert(stagedManifest.partyGauges[1], versionId .. " carries party gauges").image,
      versionId .. " gauge source"
    )
    local leadMatches, leadOccupied =
      countGaugeMatches(first, gaugeStrip, interactionFrame.x + 4, interactionFrame.y + 5, 4)
    Assert.isTrue(leadOccupied > 50, versionId .. " stages an occupied lead gauge cell")
    Assert.isTrue(leadMatches / leadOccupied > 0.9, versionId .. " draws the lead gauge from its source cell")
    local foeMatches, foeOccupied =
      countGaugeMatches(first, gaugeStrip, interactionFrame.x + 222, interactionFrame.y + 1, 4)
    Assert.isTrue(foeOccupied > 50, versionId .. " stages an occupied foe gauge cell")
    Assert.isTrue(foeMatches / foeOccupied > 0.9, versionId .. " draws the revealed foe gauge from its source cell")
  end
end

-- The native Fight view prints its move facts over the staged move
-- artwork: named slots carry label, type, and PP ink, the Back strip
-- carries its label, and the empty slots stay exactly as staged.
function T.native_fight_view_prints_real_move_text(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the battle captures need a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local screen = captureScreen(scope, cacheFs, versionId, dualMeasurement())
    driveToCommand(screen, versionId)
    screen:input({ { type = "confirm" } })
    screen:updateFixed(TICK)
    Assert.equal(screen:status().mode, "moves", versionId .. " opens the native move view")
    local plan = livePlan(screen, versionId)
    local width, height = canvasSize(plan, versionId)
    local interactionFrame = nil
    for _, pane in ipairs(plan.panes) do
      if pane.id == "interaction" then
        interactionFrame = pane.placement.frame
      end
    end
    Assert.notNil(interactionFrame, versionId .. " places its interaction pane")

    local first = renderCapture(scope, screen, width, height)
    local second = renderCapture(scope, screen, width, height)
    Assert.equal(
      imageDataDigest(first),
      imageDataDigest(second),
      versionId .. " renders the native Fight view deterministically"
    )
    saveCapture(first, versionId .. "-native-fight")

    local menuSource = decodeData(
      scope,
      cacheFs,
      assert(BattlePresentationCache.load(cacheFs).moves, versionId .. " carries move art").image,
      versionId .. " move source"
    )
    local function sourceDiffs(localBox)
      local changed = 0
      local box = { x = interactionFrame.x + localBox.x, y = interactionFrame.y + localBox.y, width = localBox.width, height = localBox.height }
      for y = box.y, box.y + box.height - 1 do
        for x = box.x, box.x + box.width - 1 do
          local sx, sy = x - interactionFrame.x, y - interactionFrame.y
          if sx >= 0 and sy >= 0 and sx < menuSource:getWidth() and sy < menuSource:getHeight() then
            local r1, g1, b1, a1 = first:getPixel(x, y)
            local r2, g2, b2, a2 = menuSource:getPixel(sx, sy)
            if
              quantize(r1) ~= quantize(r2)
              or quantize(g1) ~= quantize(g2)
              or quantize(b1) ~= quantize(b2)
              or quantize(a1) ~= quantize(a2)
            then
              changed = changed + 1
            end
          end
        end
      end
      return changed
    end
    Assert.isTrue(
      sourceDiffs({ x = 24, y = 39, width = 80, height = 14 }) > 10,
      versionId .. " prints its first move label"
    )
    Assert.isTrue(
      sourceDiffs({ x = 152, y = 38, width = 80, height = 14 }) > 10,
      versionId .. " prints its second move label"
    )
    Assert.equal(
      sourceDiffs({ x = 24, y = 102, width = 80, height = 14 }),
      0,
      versionId .. " leaves its empty third move slot exactly as staged"
    )
    Assert.equal(
      sourceDiffs({ x = 152, y = 101, width = 80, height = 14 }),
      0,
      versionId .. " leaves its empty fourth move slot exactly as staged"
    )
    Assert.isTrue(
      sourceDiffs({ x = 100, y = 169, width = 56, height = 12 }) > 5,
      versionId .. " prints its Back label"
    )
  end
end

-- The opening packet with a reserve switch choice and its party snapshot
-- so the party child finds its eligible reserve through the real options.
---@return table delivery packet opening the staged battle with a switch
local function partyPacket()
  local packet = openingPacket()
  local actor = assert(packet.request.options.actors[1], "the staged request carries its actor")
  actor.choices[#actor.choices + 1] = {
    role = "switch",
    enabled = true,
    choice = { kind = "switch", payload = { replacement = 1 } },
  }
  packet.party = {
    { slot = 0, combatant = 0, name = LEAD_SPECIES, level = 9, hp = 30, maxHp = 30 },
    { slot = 1, combatant = 1, name = LEAD_SPECIES, level = 9, hp = 28, maxHp = 28 },
  }
  return packet
end

---@param screen table live battle screen under driving
---@param ticks integer fixed updates under driving
local function pump(screen, ticks)
  for _ = 1, ticks do
    screen:updateFixed(TICK)
  end
end

---@param cells table command cells under tapping
---@param id string tapped command identity
---@return table center of the tapped cell
local function cellCenter(cells, id)
  for _, cell in ipairs(cells) do
    if cell.id == id then
      return { x = cell.x + math.floor(cell.width / 2), y = cell.y + math.floor(cell.height / 2) }
    end
  end
  error("the command grid carries " .. id, 0)
end

---@param screen table live battle screen under tapping
---@param point table tapped logical position
local function tap(screen, point)
  screen:input({ { type = "pointer_down", pointerId = "touch:0", x = point.x, y = point.y } })
  screen:input({ { type = "pointer_up", pointerId = "touch:0", x = point.x, y = point.y } })
end

-- A cancelled Item child hands the same command decision back: the bag
-- opens over the compact command request and its cancellation restores
-- the parent command with the same request, rendering pixel-identical to
-- the pre-child command with prompt, label, bar, and composite ink. The
-- returned view is kept as a PNG.
function T.compact_child_return_restores_the_parent_command(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the battle captures need a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local screen = captureScreen(scope, cacheFs, versionId, compactMeasurement())
    driveToCommand(screen, versionId)
    local requestId = assert(screen:status().request, versionId .. " mirrors its request").requestId
    local plan = livePlan(screen, versionId)
    local width, height = canvasSize(plan, versionId)
    local frame = assert(plan.panes[1].placement.frame, versionId .. " frames its compact pane")
    local reference = renderCapture(scope, screen, width, height)

    local cells = assert(plan.content.commands.cells, versionId .. " carries its command cells")
    -- The first press only focuses the unselected cell (the focus turns
    -- the input identity and releases the session capture); the second
    -- press seals through the shared press convention.
    tap(screen, cellCenter(cells, "bag"))
    pump(screen, 2)
    tap(screen, cellCenter(cells, "bag"))
    pump(screen, 5)
    Assert.equal(screen:status().mode, "child", versionId .. " opens the bag over its command")
    Assert.equal(screen:view().childIntent.kind, "bag", versionId .. " carries the bag intent")
    screen:input({ { type = "cancel" } })
    pump(screen, 5)
    Assert.equal(screen:status().mode, "command", versionId .. " returns to the same decision")
    Assert.equal(
      screen:status().request.requestId,
      requestId,
      versionId .. " keeps the parent request across the child return"
    )
    Assert.isNil(screen:view().childIntent, versionId .. " closes the bag intent")
    screen:input({ { type = "navigate", direction = "up" } })
    pump(screen, 2)
    Assert.equal(screen:view().selection, "fight", versionId .. " walks back to the first command")

    local returnedPlan = livePlan(screen, versionId)
    local returned = renderCapture(scope, screen, width, height)
    local rerun = renderCapture(scope, screen, width, height)
    Assert.equal(
      imageDataDigest(returned),
      imageDataDigest(reference),
      versionId .. " restores the parent command pixels across the child return"
    )
    Assert.equal(
      imageDataDigest(returned),
      imageDataDigest(rerun),
      versionId .. " renders the returned command deterministically"
    )
    saveCapture(returned, versionId .. "-compact-child-return")
    local content = assert(returnedPlan.content, versionId .. " carries its returned content")
    Assert.isTrue(
      countInk(returned, hostRect(frame, content.prompt.content)) > 100,
      versionId .. " restores its prompt text ink"
    )
    for _, cell in ipairs(assert(content.commands.cells, versionId .. " carries its returned cells")) do
      Assert.isTrue(
        countInk(returned, hostRect(frame, cell)) > 30,
        versionId .. " restores the " .. tostring(cell.id) .. " command label"
      )
    end
    local hud = assert(content.hud, versionId .. " carries its returned HUD")
    for _, side in ipairs({ { box = hud.enemy, label = "enemy" }, { box = hud.player, label = "player" } }) do
      Assert.isTrue(
        countColor(returned, hostRect(frame, assert(side.box.bar, versionId .. " carries its bar")), { 51, 204, 51 })
          > 10,
        versionId .. " restores the " .. side.label .. " health bar"
      )
    end
  end
end

-- A cancelled Party child hands the same command decision back: the party
-- opens through its eligible reserve switch and its cancellation
-- restores the parent command with the same request, rendering
-- pixel-identical to the pre-child command.
function T.compact_party_return_restores_the_parent_command(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the battle captures need a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local screen = captureScreen(scope, cacheFs, versionId, compactMeasurement())
    drivePacketToCommand(screen, versionId, partyPacket())
    local requestId = assert(screen:status().request, versionId .. " mirrors its request").requestId
    local plan = livePlan(screen, versionId)
    local width, height = canvasSize(plan, versionId)
    local frame = assert(plan.panes[1].placement.frame, versionId .. " frames its compact pane")
    local reference = renderCapture(scope, screen, width, height)

    local cells = assert(plan.content.commands.cells, versionId .. " carries its command cells")
    tap(screen, cellCenter(cells, "pokemon"))
    pump(screen, 2)
    tap(screen, cellCenter(cells, "pokemon"))
    pump(screen, 5)
    Assert.equal(screen:status().mode, "child", versionId .. " opens the party over its command")
    Assert.equal(screen:view().childIntent.kind, "party", versionId .. " carries the party intent")
    screen:input({ { type = "cancel" } })
    pump(screen, 5)
    Assert.equal(screen:status().mode, "command", versionId .. " returns to the same decision")
    Assert.equal(
      screen:status().request.requestId,
      requestId,
      versionId .. " keeps the parent request across the party return"
    )
    Assert.isNil(screen:view().childIntent, versionId .. " closes the party intent")
    screen:input({ { type = "navigate", direction = "up" } })
    pump(screen, 2)
    Assert.equal(screen:view().selection, "fight", versionId .. " walks back to the first command")

    local returnedPlan = livePlan(screen, versionId)
    local returned = renderCapture(scope, screen, width, height)
    Assert.equal(
      imageDataDigest(returned),
      imageDataDigest(reference),
      versionId .. " restores the parent command pixels across the party return"
    )
    local content = assert(returnedPlan.content, versionId .. " carries its returned content")
    Assert.isTrue(
      countInk(returned, hostRect(frame, content.prompt.content)) > 100,
      versionId .. " restores its prompt text ink"
    )
    Assert.isTrue(
      countColor(
          returned,
          hostRect(frame, assert(content.hud.player.bar, versionId .. " carries its player bar")),
          { 51, 204, 51 }
        ) > 10,
      versionId .. " restores the player health bar"
    )
  end
end

-- The settled win shows its result word on the compact narration dock:
-- the terminal delivery drains every cue, exposes no further request,
-- and the settled outcome view carries narration ink over the composed
-- scene with the final health bars. Kept as a PNG.
function T.compact_settled_return_shows_the_result_word(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the battle captures need a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local screen = captureScreen(scope, cacheFs, versionId, compactMeasurement())
    driveToCommand(screen, versionId)
    local port = screen:presentationPort()
    port.present({
      launchId = "battle-capture",
      packetId = 2,
      -- Production deliveries always carry the preceding view; the
      -- opening packet above is the exception the screen tolerates.
      before = openingPacket().after,
      after = {
        own = {
          {
            combatant = 0,
            side = 1,
            species = LEAD_SPECIES,
            form = 0,
            selector = "back",
            name = LEAD_SPECIES,
            level = 9,
            hp = 30,
            maxHp = 30,
            experience = 210,
          },
        },
        foes = {
          {
            combatant = 2,
            side = 2,
            species = FOE_SPECIES,
            form = 0,
            selector = "front",
            name = FOE_SPECIES,
            level = 3,
            hp = 0,
            maxHp = 12,
          },
        },
      },
      events = {},
      result = { word = "win" },
    })
    local ticks = 0
    while (screen:status().mode ~= "outcome" or not screen:status().ready) and ticks < DRIVE_BUDGET do
      screen:updateFixed(TICK)
      ticks = ticks + 1
    end
    Assert.equal(screen:status().mode, "outcome", versionId .. " settles on its outcome")
    Assert.isTrue(screen:status().ready, versionId .. " drains every cue behind the outcome")
    Assert.isNil(screen:status().request, versionId .. " exposes no further request")
    Assert.isTrue(
      tostring(screen:view().message):find(FOE_SPECIES, 1, true) ~= nil,
      versionId .. " names the defeated foe in its result wording"
    )
    local plan = livePlan(screen, versionId)
    local width, height = canvasSize(plan, versionId)
    local frame = assert(plan.panes[1].placement.frame, versionId .. " frames its compact pane")
    local content = assert(plan.content, versionId .. " carries its settled content")

    local first = renderCapture(scope, screen, width, height)
    local second = renderCapture(scope, screen, width, height)
    Assert.equal(
      imageDataDigest(first),
      imageDataDigest(second),
      versionId .. " renders the settled outcome deterministically"
    )
    saveCapture(first, versionId .. "-compact-settled-return")

    local sceneBox = hostRect(frame, content.scene)
    Assert.isTrue(countInk(first, sceneBox) > 20000, versionId .. " keeps the settled scene composed")
    local narration = assert(content.narration, versionId .. " carries its settled narration")
    Assert.isTrue(
      countInk(first, hostRect(frame, narration.content)) > 30,
      versionId .. " prints its result wording ink"
    )
    Assert.isTrue(
      countColor(first, hostRect(frame, assert(content.hud.player.bar, versionId .. " carries its bar")), { 51, 204, 51 })
        > 10,
      versionId .. " keeps the winner health bar"
    )
  end
end

-- Every drawable key the battle renderers reach for resolves to its staged
-- source image through the capture services: the scene, both HUD
-- composites, the three menu surfaces, and both mon-side portraits with
-- the manifest's own dimensions. Per-control menu artwork has no staged
-- counterpart and resolves to nothing, so those controls draw labels
-- only, never substitutes.
function T.drawable_keys_resolve_to_their_staged_source_images(scope, context)
  local versions = readyVersions()
  if #versions == 0 then
    context:skip("the battle captures need a ready user-owned ROM with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local cacheFs = CacheFs.forVersion(versionId)
    local manifest = BattlePresentationCache.load(cacheFs)
    local services = captureServices(scope, cacheFs, versionId)
    for _, entry in ipairs({
      { key = "scene:" .. SCENE_KEY, path = BattlePresentationCache.sceneImagePath(SCENE_KEY) },
      { key = "hud:enemy", path = assert(manifest.enemyHud, versionId .. " carries enemy HUD").image },
      { key = "hud:player", path = assert(manifest.playerHud, versionId .. " carries player HUD").image },
      { key = "menu:command", path = assert(manifest.command, versionId .. " carries command art").image },
      { key = "menu:moves", path = assert(manifest.moves, versionId .. " carries move art").image },
      { key = "menu:target", path = assert(manifest.target, versionId .. " carries target art").image },
      { key = "arrow", path = assert(manifest.arrow, versionId .. " carries the arrow").image },
      { key = "gauges:player", path = assert(manifest.partyGauges[1], versionId .. " carries party gauges").image },
      { key = "gauges:enemy", path = assert(manifest.partyGauges[1], versionId .. " carries party gauges").image },
    }) do
      local source = decodeData(scope, cacheFs, entry.path, versionId .. " " .. entry.key .. " source")
      local image = assert(services.drawable(entry.key), versionId .. " resolves " .. entry.key)
      Assert.equal(image:getWidth(), source:getWidth(), versionId .. " sizes " .. entry.key .. " from source")
      Assert.equal(image:getHeight(), source:getHeight(), versionId .. " heights " .. entry.key .. " from source")
    end
    for _, entry in ipairs({
      { key = "mon:enemy:front", selector = MonCache.portraitSelector(FOE_SPECIES, 0, "male", false) },
      { key = "mon:player:back", selector = MonCache.portraitSelector(LEAD_SPECIES, 0, "male", false, "back") },
    }) do
      local portraits = assert(cacheFs:loadLua(MonCache.portraitManifestPath()), versionId .. " carries its portrait manifest")
      local cell = assert(portraits.entries[entry.selector], versionId .. " plans " .. entry.selector)
      local image = assert(services.drawable(entry.key), versionId .. " resolves " .. entry.key)
      Assert.equal(image:getWidth(), cell.width, versionId .. " sizes " .. entry.key .. " from its staged cell")
      Assert.equal(image:getHeight(), cell.height, versionId .. " heights " .. entry.key .. " from its staged cell")
    end
    Assert.isNil(services.drawable("menu:command:fight"), versionId .. " leaves per-control art unmapped")
    Assert.isNil(services.drawable("menu:moves:move:0"), versionId .. " leaves per-slot art unmapped")
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
