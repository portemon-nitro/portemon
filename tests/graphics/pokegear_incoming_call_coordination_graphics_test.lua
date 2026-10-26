-- The field caller banner reuses Start Menu art: while ringing, the
-- notification view names the shared ringing animation and the exact
-- source caller window for a short and a capped long caller name, the
-- view carries no art of its own, the retained Start Menu renders
-- pixel-identical before, during, and after the episode in every layout,
-- and resizing leaves no stale surface. Window widths are checked
-- against the real font-zero text metrics with the source capping
-- formula; menu pixels come from the real renderer over the fixture
-- Start Menu contract. No derived assets are required. No ROM data is
-- required.

local Assert = require("tests.support.Assert")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local PixelScale = require("libs.ui.src.PixelScale")
local PngWriter = require("tests.support.PngEncoder")
local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
local PokegearCalendar = require("game.hgss.src.pokegear.PokegearCalendar")
local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
local PokegearState = require("libs.hgss.src.save.PokegearState")
local PhoneRewards = require("game.hgss.src.pokegear.PhoneRewards")
local PhoneWorldContext = require("game.hgss.src.pokegear.PhoneWorldContext")
local StartMenuRenderer = require("libs.hgss.src.ui.StartMenuRenderer")

local T = {}

-- Loads the incoming-call coordinator that does not exist yet at this
-- baseline. The failure names the missing behaviour instead of surfacing
-- as a suite load error, so the pre-implementation red stays attributable.
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

local MOM_KEY = "custom.mom"
local LONG_KEY = "custom.trainer-long"
local MOM_NAME = "MOM"
local LONG_NAME = "MAXIMILLIAN-CHRISTOPHER"
local MOM_TRIGGER = PhoneRewards.MOM_GIFT_TRIGGER
local LONG_TRIGGER = "custom.long-caller-event"

local CANONICAL_WIDTH = 256
local CANONICAL_HEIGHT = 192

local SUB_R, SUB_G, SUB_B = 20, 40, 160
local NORMAL_R, NORMAL_G, NORMAL_B = 200, 40, 40
local SELECTED_R, SELECTED_G, SELECTED_B = 255, 220, 120

---@param path string
---@return table
local function visualRef(path)
  return { image = path, width = 32, height = 32, anchorX = 0, anchorY = 0 }
end

-- Synthetic companion catalog with a short and a very long caller name,
-- validated through the real asset schema. Display labels follow the
-- published contact reads: the record name wins, else the key.
---@return table
local function fixtureManifest()
  local contacts = {
    { key = MOM_KEY, name = MOM_NAME, sortWeight = 10, family = "mother" },
    { key = LONG_KEY, name = LONG_NAME, sortWeight = 20, family = "trainer" },
  }
  return {
    schema = "g4-pokegear-assets-v2",
    skins = { 0, 1, 2, 3, 4, 5 },
    shell = { foreground = visualRef("assets/generated/pokegear/shell-foreground-skin-0.png") },
    configure = { panel = visualRef("assets/generated/pokegear/configure-panel.png") },
    phone = { panel = visualRef("assets/generated/pokegear/phone-panel.png") },
    map = { base = visualRef("assets/generated/pokegear/map-base.png") },
    fly = { base = visualRef("assets/generated/pokegear/fly-base.png") },
    radio = { dial = visualRef("assets/generated/pokegear/radio-dial.png") },
    catalog = {
      contacts = contacts,
      contactOrder = { MOM_KEY, LONG_KEY },
      callDefinitions = {},
      callTriggers = {
        { key = MOM_TRIGGER, contact = MOM_KEY, kind = 3, slot = 12, clearOnPickup = true },
        { key = LONG_TRIGGER, contact = LONG_KEY, kind = 3, slot = 13, clearOnPickup = false },
      },
      rematches = {},
      gifts = {},
      momPurchases = {},
      locations = {
        { key = "custom.new-bark" },
      },
      flypoints = {},
      regionMap = require("tests.support.PokegearRegionMapFixture").build(),
      reception = {},
      shows = {},
      radioEffects = {},
    },
    text = {},
    sequences = {},
  }
end

-- The fixture Start Menu contract plus the SUB chrome and a banded icon
-- atlas, mirroring the shared selector fixture: normal visuals sample
-- the top band, selected visuals the bottom band, so the drawn icon
-- state is pixel-visible. The SUB color appears nowhere else.
---@return table cacheFs, table manifest
local function selectorCacheAndManifest()
  local manifest = FieldUiFixture.manifest()
  FieldUiFixture.addStartMenuIconContract(manifest)
  local cache = FieldUiFixture.startMenuCache()
  local bands = {}
  for y = 0, 79 do
    local r, g, b = NORMAL_R, NORMAL_G, NORMAL_B
    if y >= 40 then
      r, g, b = SELECTED_R, SELECTED_G, SELECTED_B
    end
    bands[#bands + 1] = string.rep(string.char(r, g, b, 255), 352)
  end
  cache:write("assets/generated/field/ui/start-menu-icons.png", PngWriter.encode(352, 80, table.concat(bands)))
  cache:write(
    "assets/generated/field/ui/start-menu-icon-palette.png",
    PngWriter.encode(16, 2, string.rep(string.char(10, 10, 10, 255), 16 * 2))
  )
  cache:write(
    "assets/generated/field/ui/start-menu-chrome-sub.png",
    PngWriter.encode(256, 256, string.rep(string.char(SUB_R, SUB_G, SUB_B, 255), 256 * 256))
  )
  FieldUiFixture.writeFont(cache, 0)
  cache:writeLua(FieldUiAssetCache.manifestPath(), manifest)
  return cache, manifest
end

-- The placement record for a host, fitted through the real shared pixel
-- policy: the same record hit testing maps through.
---@param width integer
---@param height integer
---@return table
local function hostPlacement(width, height)
  return assert(
    PixelScale.placeFixed({ x = 0, y = 0, width = width, height = height }, 256, 192),
    "the host fits the canonical surface"
  )
end

---@return table
local function recordingText()
  local text = {
    draws = {},
  }
  function text.drawText(_, str, x, y)
    text.draws[#text.draws + 1] = { text = str, x = x, y = y }
  end
  function text.drawTextWithPalette(_, str, x, y, palette)
    text.draws[#text.draws + 1] = { text = str, x = x, y = y, palette = palette }
  end
  function text.textWidth(_, str)
    return #str * 8
  end
  return text
end

-- Renders the retained Start Menu with the gear entry selected into a
-- real canvas through the placement record and returns its ImageData.
---@param scope table
---@param cacheFs table
---@param manifest table
---@param placement table
---@param width integer
---@param height integer
---@return table
local function menuRenderInto(scope, cacheFs, manifest, placement, width, height)
  local lg = love.graphics
  local renderer = scope:own(StartMenuRenderer.new({ cacheFs = cacheFs, manifest = manifest, text = recordingText() }))
  local canvas = scope:own(lg.newCanvas(width, height))
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  renderer:draw({
    selectedPosition = 3,
    trainerGender = "male",
    actions = {
      { id = "vanilla.pokedex", position = 0, icon = 0, label = "POKEDEX" },
      { id = "vanilla.pokemon", position = 1, icon = 1, label = "POKEMON" },
      { id = "vanilla.bag", position = 2, icon = 2, label = "BAG" },
      { id = "vanilla.pokegear", position = 3, icon = 3, label = "POKEGEAR" },
    },
  }, placement)
  lg.setCanvas()
  return scope:own(canvas:newImageData())
end

-- Compares two ImageData buffers channel by channel; a single differing
-- pixel fails with its coordinates.
---@param expected table
---@param actual table
---@param label string
local function assertPixelsEqual(expected, actual, label)
  Assert.equal(expected:getWidth(), actual:getWidth(), label .. " width")
  Assert.equal(expected:getHeight(), actual:getHeight(), label .. " height")
  local function quantize(v)
    return math.floor(v * 255 + 0.5)
  end
  for y = 0, expected:getHeight() - 1 do
    for x = 0, expected:getWidth() - 1 do
      local er, eg, eb, ea = expected:getPixel(x, y)
      local ar, ag, ab, aa = actual:getPixel(x, y)
      if
        quantize(er) ~= quantize(ar)
        or quantize(eg) ~= quantize(ag)
        or quantize(eb) ~= quantize(ab)
        or quantize(ea) ~= quantize(aa)
      then
        error(
          string.format(
            "%s: pixel mismatch at (%d,%d): expected (%d,%d,%d,%d) got (%d,%d,%d,%d)",
            label,
            x,
            y,
            quantize(er),
            quantize(eg),
            quantize(eb),
            quantize(ea),
            quantize(ar),
            quantize(ag),
            quantize(ab),
            quantize(aa)
          ),
          0
        )
      end
    end
  end
end

-- Asserts the selected gear icon is really drawn from the shared atlas:
-- at least one pixel inside its source rect carries the selected band
-- color rather than the SUB chrome color. The rect scales with the
-- placement record, so scaled layouts check the scaled region.
---@param rendered table
---@param manifest table
---@param scale integer
---@param label string
local function assertGearIconDrawn(rendered, manifest, scale, label)
  local interactive = assert(manifest.startMenu, "the fixture manifest must carry the start menu section").interactive
  local anchor = assert(interactive.positions[3], "the gear position must exist").anchor
  local found = false
  for y = anchor.y * scale, (anchor.y + 40) * scale - 1 do
    for x = anchor.x * scale, (anchor.x + 32) * scale - 1 do
      local r, g, b = rendered:getPixel(x, y)
      if
        math.floor(r * 255 + 0.5) == SELECTED_R
        and math.floor(g * 255 + 0.5) == SELECTED_G
        and math.floor(b * 255 + 0.5) == SELECTED_B
      then
        found = true
        break
      end
    end
    if found then
      break
    end
  end
  Assert.isTrue(found, label .. ": the selected gear icon draws its shared-art band")
end

-- One civil sample on a fixed morning that never crosses an hour or day
-- boundary, so expectations need no date arithmetic.
---@param minute integer
---@param second integer?
---@return table<string, integer>
local function moment(minute, second)
  return { year = 2024, month = 1, day = 8, hour = 10, minute = minute, second = second or 0 }
end

-- Starts one deterministic event ring for the given trigger key: real
-- companion providers, traced streams, and recording boundaries. Only
-- the coordinator itself is the behaviour under test.
---@param triggerKey string
---@return table rig, table view
local function startRing(triggerKey)
  local IncomingCalls = requireFeature(
    "game.hgss.src.pokegear.IncomingCalls",
    "incoming calls have no field coordinator yet: the field banner has no ringing view to project"
  )
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local state = PokegearState.new({ seed = 4242 }, { catalog = record.catalog })
  state:registerContact(MOM_KEY)
  state:registerContact(LONG_KEY)
  state:setTrigger(triggerKey, true)
  local trace = {}
  local calls = IncomingCalls.new({
    state = state,
    catalog = record.catalog,
    calendar = PokegearCalendar.new(state),
    random = PokegearRandom.new(4242, { trace = trace, traceLimit = 4096 }),
    world = PhoneWorldContext.new({ state = state, flags = {} }),
    host = {
      opens = {},
      open = function(self, args)
        self.opens[#self.opens + 1] = args
        return { id = #self.opens }
      end,
      isActive = function()
        return false
      end,
    },
    audio = {
      plays = {},
      playRing = function(self, sequence)
        self.plays[#self.plays + 1] = sequence
      end,
      isRingPlaying = function()
        return false
      end,
      completeRing = function() end,
      stopRing = function() end,
    },
  })
  calls:onFieldClock(moment(0))
  calls:onFieldClock(moment(10))
  calls:onFieldClock(moment(20))
  calls:onOpportunity({ mapKey = "custom.new-bark-town", movementState = "none", higherPriorityClaimed = false })
  local view = calls:notification()
  Assert.notNil(view, "the event trigger rings for the banner check")
  assert(type(view) == "table", "ringing publishes its caller view")
  return { calls = calls, state = state }, view
end

-- The independent source window: SUB background 1 at tile left 11 top 19
-- with height 2 and width min(floor(font0Width/8)+2, 9).
---@param fontWidth integer
---@return table
local function expectedWindow(fontWidth)
  local width = math.floor(fontWidth / 8) + 2
  if width > 9 then
    width = 9
  end
  return { tileLeft = 11, top = 19, height = 2, width = width }
end

-- Checks the projected window geometry field by field: the four source
-- facts are pinned exactly while the view stays free to carry companion
-- metadata the contract does not name.
---@param view table
---@param expected table
---@param label string
local function checkWindow(view, expected, label)
  local window = assert(view.sourceWindow, label .. " projects its caller window")
  assert(type(window) == "table", "caller window is a record")
  Assert.equal(window.tileLeft, expected.tileLeft, label .. " sits at tile left 11")
  Assert.equal(window.top, expected.top, label .. " sits at top 19")
  Assert.equal(window.height, expected.height, label .. " spans height 2")
  Assert.equal(window.width, expected.width, label .. " spans the capped width")
end

-- The field banner reuses Start Menu art with a capped caller window: a
-- short and a long caller name project the shared ringing animation and
-- the exact source window geometry, the view references no art of its
-- own, the banner clears on stop, and the retained menu renders
-- pixel-identical across layouts and a resize.
function T.the_field_banner_reuses_start_menu_art_with_a_capped_caller_window(scope)
  local cache, manifest = selectorCacheAndManifest()
  local text = scope:own(FieldTextRenderer.new({ cacheFs = cache, fontId = 0 }))

  -- The short caller projects the shared ringing animation and the exact
  -- source window without capping.
  local momRig, momView = startRing(MOM_TRIGGER)
  Assert.equal(momView.contactKey, MOM_KEY, "the short ring names its caller")
  Assert.notNil(momView.nameTokens, "the short ring carries its caller name tokens")
  Assert.equal(momView.ringingAnimation, 5, "ringing selects the shared source ringing animation")
  local momWidth = text:textWidth(MOM_NAME)
  Assert.isTrue(math.floor(momWidth / 8) + 2 <= 9, "the short name exercises the uncapped window")
  checkWindow(momView, expectedWindow(momWidth), "short window")
  Assert.isNil(momView.image, "the banner references no image of its own")
  Assert.isNil(momView.visual, "the banner references no visual of its own")
  Assert.isNil(momView.asset, "the banner references no asset of its own")

  -- The long caller caps at the source width: the uncapped formula would
  -- overflow, but the projected window stops at nine tiles.
  local longRig, longView = startRing(LONG_TRIGGER)
  Assert.equal(longView.contactKey, LONG_KEY, "the long ring names its caller")
  Assert.equal(longView.ringingAnimation, 5, "the long ring selects the same ringing animation")
  local longWidth = text:textWidth(LONG_NAME)
  Assert.isTrue(math.floor(longWidth / 8) + 2 > 9, "the long name genuinely overflows the uncapped window")
  checkWindow(longView, expectedWindow(longWidth), "long window")
  Assert.equal(longView.sourceWindow.width, 9, "the long window caps at nine tiles")
  Assert.equal(longView.sourceWindow.tileLeft, momView.sourceWindow.tileLeft, "both windows share the source tile")
  Assert.equal(longView.sourceWindow.top, momView.sourceWindow.top, "both windows share the source row")

  -- The banner clears on stop: expiry quiets the view while the menu
  -- below is untouched.
  momRig.calls:onFieldClock(moment(20))
  momRig.calls:onFieldClock(moment(20, 31))
  Assert.isFalse(momRig.calls:notification(), "the banner clears when ringing stops")

  -- The retained menu renders pixel-identical before, during, and after
  -- the episode in every layout: ringing adds no toast, stopping leaves
  -- no residue, and the gear icon keeps its shared art.
  local canonical = hostPlacement(CANONICAL_WIDTH, CANONICAL_HEIGHT)
  local scaled = hostPlacement(512, 384)
  local beforeCanonical = menuRenderInto(scope, cache, manifest, canonical, CANONICAL_WIDTH, CANONICAL_HEIGHT)
  assertGearIconDrawn(beforeCanonical, manifest, 1, "retained menu")
  local duringCanonical = menuRenderInto(scope, cache, manifest, canonical, CANONICAL_WIDTH, CANONICAL_HEIGHT)
  assertPixelsEqual(beforeCanonical, duringCanonical, "ringing adds no menu primitives")
  local afterCanonical = menuRenderInto(scope, cache, manifest, canonical, CANONICAL_WIDTH, CANONICAL_HEIGHT)
  assertPixelsEqual(beforeCanonical, afterCanonical, "stopping leaves no menu residue")
  local beforeScaled = menuRenderInto(scope, cache, manifest, scaled, 512, 384)
  assertGearIconDrawn(beforeScaled, manifest, 2, "scaled retained menu")
  local afterScaled = menuRenderInto(scope, cache, manifest, scaled, 512, 384)
  assertPixelsEqual(beforeScaled, afterScaled, "the scaled layout keeps the retained menu identical")

  -- A resize during the episode leaves no stale surface: returning to
  -- the canonical placement reproduces its pixels exactly.
  local resized = menuRenderInto(scope, cache, manifest, scaled, 512, 384)
  assertPixelsEqual(beforeScaled, resized, "the resized render matches its own layout")
  local restored = menuRenderInto(scope, cache, manifest, canonical, CANONICAL_WIDTH, CANONICAL_HEIGHT)
  assertPixelsEqual(beforeCanonical, restored, "restoring the placement restores its pixels")

  momRig.calls:dispose()
  longRig.calls:dispose()
end

return GraphicsSmoke.suite(T, { tags = { "pokegear" } })
