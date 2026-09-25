-- Synthetic coverage for the integrated mon flow: a mixed six-slot party
-- paints every slot through the party-screen layout and renderer.
-- Production-cache variant and party-application graphics live in the
-- derived-cache suite; representative icon/portrait pixels live in the
-- manifest suite.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local MonCache = require("libs.assets.src.MonCache")
local MonIconAssetProvider = require("libs.hgss.src.presentation.MonIconAssetProvider")
local PartyScreenLayout = require("libs.hgss.src.ui.PartyScreenLayout")
local PartyScreenRenderer = require("libs.hgss.src.ui.PartyScreenRenderer")
local PngWriter = require("libs.assets.src.PngWriter")

local T = {}

local function decodingQueue(cache)
  local nextToken = 0
  local live = {}
  local queue = {}
  function queue:request(kind, path, priority)
    assert(kind == "image", "icon pages decode as images")
    assert(priority == "demand", "visible party pages decode as demand")
    nextToken = nextToken + 1
    live[nextToken] = path
    return nextToken
  end
  function queue:poll(token)
    assert(live[token], "poll observes a live token")
    return "ready"
  end
  function queue:take(token)
    local path = assert(live[token], "take transfers a live token once")
    live[token] = nil
    local bytes = assert(cache:read(path), "the compiled icon page is present")
    local fileData = assert(love.filesystem.newFileData(bytes, "icon-page.png"), "page bytes form a file")
    return { imageData = assert(love.image.newImageData(fileData), "page bytes decode") }
  end
  function queue:cancel(token)
    live[token] = nil
  end
  return queue
end

local function preparedProvider(cache, keys)
  local provider = MonIconAssetProvider.new(cache, {
    preparationQueue = decodingQueue(cache),
    derivedAssets = {
      requestIconPage = function(pageId, _)
        assert(type(pageId) == "number", "icon demand carries its page")
        return true
      end,
    },
  })
  local ready, failure
  for _ = 1, 8 do
    ready, failure = provider:prepareKeys(keys)
    if ready or failure ~= nil then
      break
    end
  end
  Assert.isTrue(ready, "demanded icon pages prepare: " .. tostring(failure))
  return provider
end

local function iconCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(MonCache.iconManifestPath(), {
    schema = MonCache.ICON_MANIFEST_SCHEMA,
    version = { id = "heartgold", language = "english" },
    pages = {
      [0] = { pageId = 0, image = MonCache.iconPagePath(0), width = 256, height = 128 },
    },
    pageIds = { 0 },
    entries = {
      ["MON0/f0"] = {
        x = 0,
        y = 0,
        width = 32,
        height = 32,
        frames = { { x = 0, y = 0, width = 32, height = 32, duration = 1 } },
        pageId = 0,
      },
    },
    representative = { "MON0/f0" },
  })
  local pixels = {}
  for _ = 1, 64 * 64 do
    pixels[#pixels + 1] = string.char(200, 40, 40, 255)
  end
  cache:write(MonCache.iconPagePath(0), PngWriter.encode(64, 64, table.concat(pixels)))
  return cache
end

local function foundationManifest()
  local panels = {}
  local origins = { { 0, 0 }, { 128, 8 }, { 0, 48 }, { 128, 56 }, { 0, 96 }, { 128, 104 } }
  for slot, origin in ipairs(origins) do
    local ox, oy = origin[1], origin[2]
    panels[slot] = {
      origin = { x = ox, y = oy },
      size = { width = 128, height = 48 },
      chrome = { normal = { image = "test/panel.png", width = 128, height = 48 } },
      text = {
        name = { x = ox + 48, y = oy + 8, width = 72, height = 16 },
        level = { x = ox + 0, y = oy + 32, width = 48, height = 16 },
      },
      hp = {
        bar = { x = ox + 64, y = oy + 24, width = 48, height = 8 },
        number = { x = ox + 56, y = oy + 32, width = 64, height = 16 },
      },
      compat = { x = ox + 48, y = oy + 32, width = 80, height = 16 },
    }
  end
  local function dpadBox(up, down, leftNeighbor, rightNeighbor)
    return {
      left = 0,
      top = 0,
      width = 0,
      height = 0,
      up = up,
      down = down,
      leftNeighbor = leftNeighbor,
      rightNeighbor = rightNeighbor,
    }
  end
  local function touch(top, bottom, left, right)
    return { top = top, bottom = bottom, left = left, right = right }
  end
  local digits = {}
  for digit = 0, 9 do
    digits[digit + 1] = { image = "test/digit-" .. digit .. ".png", width = 8, height = 8 }
  end
  return {
    panels = panels,
    windows = {
      message = { x = 16, y = 168, width = 160, height = 16 },
      context = { x = 152, y = 120, width = 96, height = 64 },
    },
    visuals = {
      balls = {
        sequences = {
          {
            frames = {
              { image = "test/ball.png", width = 32, height = 32, offset = { x = 0, y = 0 }, durationTicks = 1 },
            },
          },
          {
            frames = {
              { image = "test/ball.png", width = 32, height = 32, offset = { x = 0, y = 0 }, durationTicks = 1 },
            },
          },
        },
      },
      held = {
        sequences = {
          {
            frames = {
              { image = "test/held.png", width = 8, height = 8, offset = { x = 0, y = 0 }, durationTicks = 1 },
            },
          },
        },
      },
      cursor = {
        sequences = {
          {
            frames = {
              { image = "test/cursor.png", width = 128, height = 48, offset = { x = 0, y = 0 }, durationTicks = 1 },
            },
          },
        },
      },
    },
    iconAnimations = { periods = { 1, 8, 12, 24, 40, 36 } },
    navigation = {
      dpad = {
        default = {
          dpadBox(7, 2, 7, 1),
          dpadBox(7, 3, 0, 2),
          dpadBox(0, 4, 1, 3),
          dpadBox(1, 5, 2, 4),
          dpadBox(2, 7, 3, 5),
          dpadBox(3, 7, 4, 7),
          dpadBox(0, 0, 0, 0),
          dpadBox(5, 1, 5, 0),
        },
      },
    },
    hitboxes = {
      touch = {
        default = {
          touch(0, 48, 0, 128),
          touch(8, 56, 128, 0),
          touch(48, 96, 0, 128),
          touch(56, 104, 128, 0),
          touch(96, 144, 0, 128),
          touch(104, 152, 128, 0),
          touch(152, 192, 200, 0),
        },
      },
    },
    numberGlyphs = {
      advance = 8,
      digits = digits,
      level = { image = "test/level.png", width = 16, height = 8 },
      slash = { image = "test/slash.png", width = 8, height = 8 },
    },
    text = { labels = {}, templates = {} },
  }
end

local function foundationCache()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local function stub(path, width, height, r, g, b, a)
    local pixels = {}
    for _ = 1, width * height do
      pixels[#pixels + 1] = string.char(r, g, b, a or 255)
    end
    cache:write(path, PngWriter.encode(width, height, table.concat(pixels)))
  end
  stub("test/panel.png", 128, 48, 40, 40, 56)
  stub("test/ball.png", 32, 32, 60, 60, 80)
  stub("test/held.png", 8, 8, 200, 200, 80)
  stub("test/cursor.png", 128, 48, 0, 0, 0, 0)
  for digit = 0, 9 do
    stub("test/digit-" .. digit .. ".png", 8, 8, 230, 230, 230)
  end
  stub("test/level.png", 16, 8, 230, 230, 230)
  stub("test/slash.png", 8, 8, 230, 230, 230)
  return cache
end

---@param slot0 integer
---@param overrides table<string, any>
---@return table<string, any>
local function occupiedSlot(slot0, overrides)
  local record = {
    slot = slot0,
    occupied = true,
    eligible = true,
    iconKey = "MON0/f0",
    displayName = "MON" .. slot0,
    level = 5,
    gender = "male",
    status = "ok",
    currentHp = 20,
    maxHp = 20,
    hpFraction = 1,
    isEgg = false,
    heldItem = "NONE",
    capsule = nil,
    moves = {},
    shinyLeaves = 0,
  }
  for key, value in pairs(overrides) do
    record[key] = value
  end
  return record
end

local function sixSlotView(cursorNode)
  return {
    open = true,
    context = "browse",
    state = "browse",
    mode = "browse",
    action = "browse",
    cursorNode = cursorNode,
    menuIndex = nil,
    menu = nil,
    menuSlot = nil,
    message = nil,
    swap = nil,
    anim = { tick = 0, sequences = { 1, 3, 2, 5, 4, 0 }, phases = { 0, 0, 0, 0, 0, 0 }, panelSlide = 0 },
    infoOverlay = false,
    view = {
      revision = 7,
      slots = {
        occupiedSlot(0, {}),
        occupiedSlot(1, { gender = "female", status = "poison", currentHp = 4, maxHp = 20, hpFraction = 0.2 }),
        occupiedSlot(2, { status = "burn", currentHp = 10, maxHp = 20, hpFraction = 0.5 }),
        occupiedSlot(3, { gender = "genderless", status = "sleep", currentHp = 20, maxHp = 20, hpFraction = 1 }),
        occupiedSlot(4, { status = "paralysis", currentHp = 1, maxHp = 20, hpFraction = 0.05 }),
        occupiedSlot(5, { status = "faint", currentHp = 0, maxHp = 20, hpFraction = 0 }),
      },
    },
    cancellable = true,
  }
end

local function opaqueCount(image, width, height)
  local found = 0
  for y = 0, height - 1, 4 do
    for x = 0, width - 1, 4 do
      local _, _, _, a = image:getPixel(x, y)
      if a > 0.5 then
        found = found + 1
      end
    end
  end
  return found
end

function T.mixed_six_slot_party_paints_every_slot(scope)
  local text = scope:own(FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames() }))
  local manifest = foundationManifest()
  local assetCache = foundationCache()
  for _, size in ipairs({ { width = 320, height = 240 }, { width = 640, height = 480 } }) do
    local layout = PartyScreenLayout.resolve({ manifest = manifest, cancellable = true })
    Assert.equal(#layout.slotRects, 6, "all six slots resolve")
    for left = 1, 6 do
      for right = left + 1, 6 do
        local a, b = layout.slotRects[left], layout.slotRects[right]
        Assert.isTrue(
          a.x + a.width <= b.x or b.x + b.width <= a.x or a.y + a.height <= b.y or b.y + b.height <= a.y,
          "party slots never overlap"
        )
      end
    end
    local provider = preparedProvider(iconCache(), { "MON0/f0" })
    local renderer = PartyScreenRenderer.new({
      graphics = love.graphics,
      cacheFs = assetCache,
      manifest = manifest,
      text = text,
    })
    local canvas = scope:own(love.graphics.newCanvas(size.width, size.height))
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    renderer:draw(sixSlotView(5), layout, provider)
    love.graphics.setCanvas()
    local image = scope:own(canvas:newImageData())
    Assert.isTrue(
      opaqueCount(image, size.width, size.height) > 0,
      "the full party paints visible surfaces at " .. size.width .. "x" .. size.height
    )
    -- The healthy lead keeps its slot surface; the damaged second slot
    -- keeps a red HP bar segment; the fainted last slot paints under the
    -- cursor without failing.
    local lead = layout.slotRects[1]
    local r, g, b, a = image:getPixel(math.floor(lead.x + 2), math.floor(lead.y + 2))
    Assert.near(r, 40 / 255, 0.06, "the lead slot surface paints")
    Assert.near(g, 40 / 255, 0.06)
    Assert.near(b, 56 / 255, 0.06)
    Assert.near(a, 1, 0.01)
    -- The selected icon shifts (2,2) off its stored base; sample the
    -- icon-only region clear of the later ball indicator overlay.
    local ir, ig = image:getPixel(math.floor(lead.x + 30 + 2 + 24), math.floor(lead.y + 16 + 2 + 4))
    Assert.near(ir, 200 / 255, 0.06, "the icon quad draws inside the lead slot")
    Assert.near(ig, 40 / 255, 0.06)
    local hr, hg = image:getPixel(192 + 4, 32 + 4)
    Assert.isTrue(hr > 0.7 and hg < 0.5, "low HP paints the red zone")
    provider:release()
  end

  -- Selection mode dims the ineligible slot while keeping its icon under
  -- dimmed chrome: a separate layout case the view capture cannot show.
  local size = { width = 640, height = 480 }
  local layout = PartyScreenLayout.resolve({ manifest = manifest, cancellable = true })
  local status = sixSlotView(0)
  status.context = "pick"
  status.view.slots[2].eligible = false
  local provider = preparedProvider(iconCache(), { "MON0/f0" })
  local renderer = PartyScreenRenderer.new({
    graphics = love.graphics,
    cacheFs = assetCache,
    manifest = manifest,
    text = text,
  })
  local canvas = scope:own(love.graphics.newCanvas(size.width, size.height))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  renderer:draw(status, layout, provider)
  love.graphics.setCanvas()
  local image = scope:own(canvas:newImageData())
  Assert.isTrue(opaqueCount(image, size.width, size.height) > 0, "selection paints with dimmed chrome")
  provider:release()
end

return GraphicsSmoke.suite(T)
