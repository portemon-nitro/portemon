-- Switch-entry trajectory through the staged cache: a reserve arrival in a
-- doubled battle starts displaced toward its source spawn side and
-- settles exactly on its slot settled edge over source ticks, while the
-- surviving partner never leaves its own settled edge. The production
-- battle screen runs over the real staged presentation manifest with
-- real playback packets; draws record through a recording double, never
-- through a reimplementation of the renderer. Expected slot edges come
-- from the pinned native geometry (battle_hp_bar.c health-box
-- templates; overlay-7 spawn tables): the opponent-right settled edge
-- is one half inset left of X=176 at baseline Y=42. Needs a ready
-- user-owned ROM with a prepared derived cache, otherwise it skips.

local Assert = require("tests.support.Assert")
local FakeGraphics = require("tests.support.FakeGraphics")

local T = {}
local function stagedImageWidth(image)
  return image.width
end

local function stagedImageHeight(image)
  return image.height
end

local function stagedImageDimensions(image)
  return image.width, image.height
end

local function stagedImageFilter() end

local function stagedDrawable(key)
  local hud = key:match("^hud:") ~= nil
  return {
    handle = key,
    width = hud and 1648 or 256,
    height = hud and 8 or 256,
    getWidth = stagedImageWidth,
    getHeight = stagedImageHeight,
    getDimensions = stagedImageDimensions,
    setFilter = stagedImageFilter,
  }
end

local PICTURE_HALF = 40
local DOUBLES_SETTLED = {
  { side = 2, x = 40, y = 112 },
  { side = 4, x = 80, y = 120 },
  { side = 3, x = 216, y = 50 },
  { side = 5, x = 176, y = 42 },
}

---@param center table<string, number> native settled center under test driving
---@param height number|nil signed height displacement under test driving
---@return number expected nominal image left edge
---@return number expected nominal image top edge
local function nominalOrigin(center, height)
  local displacement = 0
  if type(height) == "number" then
    displacement = height
  end
  return center.x - PICTURE_HALF, center.y - PICTURE_HALF + displacement
end

---@return table recording text boundary behind one draw
local function recordingText()
  local text = { draws = {} }
  function text.measure(content)
    return { width = 8 * #tostring(content), height = 16 }
  end
  function text.drawText(content, x, y)
    text.draws[#text.draws + 1] = { content = tostring(content), x = x, y = y, palette = nil }
  end
  function text.drawTextWithPalette(content, x, y, palette)
    text.draws[#text.draws + 1] = { content = tostring(content), x = x, y = y, palette = palette }
  end
  return text
end

---@return table recording window boundary behind one draw
local function recordingWindows()
  local windows = { boxes = {} }
  function windows.drawWindow(box, frameKey, background)
    windows.boxes[#windows.boxes + 1] = { box = box, frame = frameKey, background = background }
  end
  function windows.drawApplicationFrame(box, frameIndex)
    windows.boxes[#windows.boxes + 1] = { box = box, frame = frameIndex }
  end
  return windows
end

---@param draws table[] recorded draws under inspection
---@param handle string artwork identity under inspection
---@return table[] draws carrying that artwork identity
local function drawsOf(draws, handle)
  local found = {}
  for _, entry in ipairs(draws) do
    local image = entry.meshTexture or entry.image
    if type(image) == "table" and image.handle == handle then
      found[#found + 1] = entry
    end
  end
  return found
end

-- A reserve arrival in a doubled battle starts displaced toward its
-- source spawn side and settles exactly on its slot settled edge, while
-- the surviving partner never leaves its own settled edge.
function T.switched_arrival_travels_from_its_spawn_side_to_its_settled_edge(_, context)
  local RomImporter = require("romdump.src.source.RomImporter")
  local GameVersion = require("romdump.src.source.GameVersion")
  local ready = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      ready[#ready + 1] = versionId
    end
  end
  if #ready == 0 then
    context:skip("the switch-entry trajectory needs a ready user-owned ROM with a derived cache")
  end
  local CacheFs = require("libs.storage.src.CacheFs")
  local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
  local BattlePresentationModel = require("game.hgss.src.battle.BattlePresentationModel")
  local BattleScreenState = require("game.hgss.tests.support.BattleScreenFixture")
  local ScreenTopology = require("libs.ui.src.ScreenTopology")
  local versionId = ready[1]
  local cacheFs = CacheFs.forVersion(versionId)
  local manifest = BattlePresentationCache.load(cacheFs)
  Assert.equal(manifest.schema, BattlePresentationCache.MANIFEST_SCHEMA, versionId .. " stages the v3 battle manifest")
  Assert.equal(#manifest.battlefield.slots, 6, versionId .. " stages all six source slot geometries")
  Assert.isTrue(#manifest.hud.player.cells > 0, versionId .. " stages native player health-box cells")
  Assert.equal(manifest.hud.player.componentCount, 78, versionId .. " stages native health-box patch tiles")
  Assert.isTrue(next(manifest.pictures.selectors) ~= nil, versionId .. " stages source picture selectors")
  local scopeText = recordingText()
  local scopeWindows = recordingWindows()
  local launchId = "scene-entry-probe"
  local screen = BattleScreenState.new({
    launchId = launchId,
    manifest = manifest,
    model = BattlePresentationModel,
    submit = function(_)
      return true
    end,
    measureDisplay = function()
      return {
        width = 256,
        height = 384,
        topology = ScreenTopology.dualDisplay(
          { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
          { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
        ),
        pixelRatio = 1,
        signature = "scene-entry-probe:dual",
      }
    end,
    assets = {
      prepare = function(_)
        return true
      end,
      -- The holder calls its preparation services dot-style, so the
      -- recording double takes the key directly for handles to resolve.
      drawable = function(key)
        return stagedDrawable(key)
      end,
      release = function(_, _) end,
    },
    text = scopeText,
    windows = scopeWindows,
    audio = {
      play = function(_)
        return true
      end,
    },
    overrides = { sceneKey = "general/grass/day" },
  })
  local function foeRecord(combatant, position, activation, name, selector)
    return {
      combatant = combatant,
      side = 2,
      active = true,
      species = "RATTATA",
      form = 0,
      selector = "front",
      portraitSelector = selector,
      name = name,
      level = 4,
      hp = 12,
      maxHp = 12,
      position = position,
      activation = activation,
    }
  end
  local function ownRecord(combatant, position, activation, name, selector)
    return {
      combatant = combatant,
      side = 1,
      active = true,
      species = "CHIKORITA",
      form = 0,
      selector = "back",
      portraitSelector = selector,
      name = name,
      level = 9,
      hp = 30,
      maxHp = 30,
      experience = 120,
      position = position,
      activation = activation,
    }
  end
  local opening = {
    own = {
      ownRecord(1, 0, 11, "LEAD", "CHIKORITA/f0/male/plain/back"),
      ownRecord(4, 1, 14, "ALLY", "CHIKORITA/f0/female/plain/back"),
    },
    foes = {
      foeRecord(2, 2, 12, "FOE-A", "RATTATA/f0/male/plain"),
    },
  }
  local port = screen:presentationPort()
  for _ = 1, 5 do
    screen:updateFixed(1 / 60)
  end
  Assert.isTrue(port.enter({ launchId = launchId, kind = "wild" }), versionId .. " enters its staged doubled scene")
  port.present({ launchId = launchId, packetId = 1, before = opening, after = opening, events = {} })
  for _ = 1, 1200 do
    screen:updateFixed(1 / 60)
  end
  local openingGraphics = FakeGraphics.new({})
  screen:draw({ graphics = openingGraphics })
  local openingRattata = drawsOf(openingGraphics.draws, "mon:RATTATA/f0/male/plain")
  local sourceSelector = manifest.pictures.selectors["pokemon/RATTATA/form-0/male/front"]
  local sourceAttributes = manifest.pictures.attributes[sourceSelector.attributes]
  Assert.equal(#openingRattata, 1, "the opening foe uses its exact staged portrait")
  local portraitTop = math.huge
  for _, vertex in ipairs(assert(openingRattata[1].meshVertices, "the production mesh carries source vertices")) do
    portraitTop = math.min(portraitTop, vertex[2])
  end
  -- Pokepic lowers the picture by its height and lifts an opponent's by
  -- the species shadow height.
  local expectedTop = DOUBLES_SETTLED[3].y - PICTURE_HALF + sourceAttributes.height - sourceAttributes.shadow.height
  Assert.equal(
    portraitTop,
    expectedTop,
    "the real screen resolves staged front-facing source height into its mesh origin, got "
      .. tostring(portraitTop)
      .. " expected "
      .. tostring(expectedTop)
  )
  local function arrivalDraws()
    local graphics = FakeGraphics.new({})
    screen:draw({ graphics = graphics })
    return drawsOf(graphics.draws, "mon:RATTATA/f0/male/shiny")
  end
  local function pictureLeft(entry)
    local left = math.huge
    for _, vertex in ipairs(assert(entry.meshVertices, "the production mesh carries source vertices")) do
      left = math.min(left, vertex[1])
    end
    return left
  end
  local before = arrivalDraws()
  Assert.equal(#before, 0, "the reserve arrival draws nothing before its switch packet")
  local switchedAfter = {
    own = opening.own,
    foes = {
      foeRecord(2, 2, 12, "FOE-A", "RATTATA/f0/male/plain"),
      foeRecord(3, 3, 21, "FOE-B", "RATTATA/f0/male/shiny"),
    },
  }
  port.present({
    launchId = launchId,
    packetId = 2,
    before = opening,
    after = switchedAfter,
    events = { { kind = "join", payload = { combatant = 3 } } },
  })
  screen:startPictureEntry(switchedAfter.foes[2], 8)
  local trajectory = {}
  for _ = 1, 600 do
    screen:updateFixed(1 / 60)
    local graphics = FakeGraphics.new({})
    screen:draw({ graphics = graphics })
    local pictures = drawsOf(graphics.draws, "mon:RATTATA/f0/male/shiny")
    if #pictures >= 1 then
      trajectory[#trajectory + 1] = pictureLeft(pictures[1])
    end
  end
  Assert.isTrue(#trajectory >= 1, "the switched arrival becomes visible after its switch packet")
  local settledArrivalX = nominalOrigin(DOUBLES_SETTLED[4], 0)
  Assert.equal(
    trajectory[#trajectory],
    settledArrivalX,
    "the switched arrival settles exactly on its slot settled edge"
  )
  local displaced = false
  for _, x in ipairs(trajectory) do
    if
      x --[[@as number]]
      < settledArrivalX - 4
    then
      displaced = true
      break
    end
  end
  Assert.isTrue(displaced, "the switched arrival starts displaced toward its source spawn side before settling")
  local survivorGraphics = FakeGraphics.new({})
  screen:draw({ graphics = survivorGraphics })
  local survivor = drawsOf(survivorGraphics.draws, "mon:RATTATA/f0/male/plain")
  Assert.isTrue(#survivor >= 1, "the surviving foe still draws after the arrival settles")
  local survivorX = nominalOrigin(DOUBLES_SETTLED[3], 0)
  Assert.equal(pictureLeft(survivor[1]), survivorX, "the surviving foe never leaves its settled edge")
end

return {
  tests = T,
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "battle-presentation:global",
      "battle-scene:general/grass/day",
    },
  },
}
