-- Readiness scenarios for the party presentation family: the family is
-- ready only with an exact marker, a valid manifest, and every referenced
-- artifact present. Fixtures are synthetic; the ROM suite proves the real
-- family.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local PartyCache = require("libs.assets.src.PartyCache")

local T = {}

local function imageRef(path, width, height)
  return { image = path, width = width, height = height }
end

local function frameRef(path, width, height, durationTicks)
  return { image = path, width = width, height = height, durationTicks = durationTicks }
end

local function rect(x, y, width, height)
  return { x = x, y = y, width = width, height = height }
end

local function touch(top, bottom, left, right)
  return { top = top, bottom = bottom, left = left, right = right }
end

local function manifest()
  local panels = {}
  local origins = { { 0, 0 }, { 128, 8 }, { 0, 48 }, { 128, 56 }, { 0, 96 }, { 128, 104 } }
  for slot, origin in ipairs(origins) do
    panels[slot] = {
      origin = { x = origin[1], y = origin[2] },
      size = { width = 128, height = 48 },
      iconAnchor = { x = origin[1] + 30, y = origin[2] + 16 },
      ballAnchor = { x = origin[1] + 16, y = origin[2] + 14 },
      heldAnchor = { x = origin[1] + 38, y = origin[2] + 24 },
      capsuleAnchor = { x = origin[1] + 46, y = origin[2] + 24 },
      statusRect = rect(origin[1] + 24, origin[2] + 40, 24, 8),
      cursorSequence = 1,
      chrome = {
        normal = imageRef("assets/generated/party/panel-normal.png", 128, 48),
        selected = imageRef("assets/generated/party/panel-selected.png", 128, 48),
        fainted = imageRef("assets/generated/party/panel-fainted.png", 128, 48),
        selectedFainted = imageRef("assets/generated/party/panel-selected-fainted.png", 128, 48),
      },
      text = {
        name = rect(origin[1] + 48, origin[2] + 8, 72, 16),
        level = rect(origin[1] + 0, origin[2] + 32, 48, 16),
      },
      hp = {
        bar = rect(origin[1] + 64, origin[2] + 24, 48, 8),
        number = rect(origin[1] + 56, origin[2] + 32, 64, 16),
      },
      compat = rect(origin[1] + 48, origin[2] + 32, 80, 16),
    }
  end
  local digits = {}
  for digit = 0, 9 do
    digits[digit + 1] = imageRef("assets/generated/party/digit-" .. digit .. ".png", 8, 8)
  end
  local anchors = {}
  for leaf = 0, 4 do
    anchors[leaf + 1] = { x = 91 + leaf * 10, y = 182 }
  end
  local dpadRow = {}
  for entry = 1, 8 do
    dpadRow[entry] =
      { left = 64, top = 25, width = 0, height = 0, up = 7, down = 2, leftNeighbor = 7, rightNeighbor = 1 }
  end
  return {
    schema = "g4-party-presentation-v2",
    panes = {
      main = { width = 256, height = 192 },
      sub = { width = 256, height = 192 },
    },
    panels = panels,
    windows = {
      message = rect(16, 168, 160, 16),
      context = rect(152, 120, 96, 64),
    },
    visuals = {
      cursor = {
        sequences = {
          {
            frames = { { image = "assets/generated/party/cursor-0.png", width = 32, height = 32, durationTicks = 8 } },
            loopFrom = 1,
            playback = "static",
          },
        },
      },
      balls = {
        sequences = {
          {
            frames = { { image = "assets/generated/party/ball-0.png", width = 32, height = 32, durationTicks = 8 } },
            loopFrom = 1,
            playback = "static",
          },
        },
      },
      buttons = {
        sequences = {
          {
            frames = { { image = "assets/generated/party/button-0.png", width = 32, height = 32, durationTicks = 8 } },
            loopFrom = 1,
            playback = "static",
          },
        },
      },
      held = {
        sequences = {
          {
            frames = { { image = "assets/generated/party/held-0.png", width = 8, height = 8, durationTicks = 8 } },
            loopFrom = 1,
            playback = "static",
          },
        },
      },
      status = {
        paralysis = imageRef("assets/generated/party/status-paralysis.png", 24, 8),
        freeze = imageRef("assets/generated/party/status-freeze.png", 24, 8),
        sleep = imageRef("assets/generated/party/status-sleep.png", 24, 8),
        poison = imageRef("assets/generated/party/status-poison.png", 24, 8),
        burn = imageRef("assets/generated/party/status-burn.png", 24, 8),
        faint = imageRef("assets/generated/party/status-faint.png", 24, 8),
      },
      feedback = {
        frames = {
          { image = "assets/generated/party/feedback-0.png", width = 16, height = 16, durationTicks = 3 },
          { image = "assets/generated/party/feedback-1.png", width = 16, height = 16, durationTicks = 2 },
        },
        loopFrom = 1,
        playback = "once",
        hideAtFrame = 3,
      },
      backdropMain = { image = "assets/generated/party/backdrop-main.png", width = 256, height = 256 },
      backdropSub = { image = "assets/generated/party/backdrop-sub.png", width = 256, height = 256 },
      detailSub = { image = "assets/generated/party/detail-sub.png", width = 256, height = 256 },
      decoration = { image = "assets/generated/party/decoration.png", width = 128, height = 16 },
      auxPanel = { image = "assets/generated/party/panel-aux.png", width = 128, height = 48 },
      hpBars = {
        green = imageRef("assets/generated/party/hp-green.png", 48, 4),
        yellow = imageRef("assets/generated/party/hp-yellow.png", 48, 4),
        red = imageRef("assets/generated/party/hp-red.png", 48, 4),
      },
    },
    controls = { cancel = { anchor = { x = 232, y = 176 } } },
    detail = {
      iconAnchor = { x = 30, y = 200 },
      statusAnchor = { x = 50, y = 220 },
      nicknameTextOrigin = { x = 56, y = 192 },
      heldItemTextOrigin = { x = 138, y = 212 },
    },
    iconAnimations = {
      periods = { 1, 8, 12, 24, 40, 36 },
      replacementDurations = { 32, 2, 2 },
      replacementShift = { 0, 1, -1 },
    },
    navigation = { dpad = { default = dpadRow, alternate = dpadRow, union = dpadRow, contest = dpadRow } },
    hitboxes = {
      touch = {
        default = { touch(0, 48, 0, 128) },
        alternate = { touch(0, 48, 0, 128) },
        context = { touch(0, 48, 0, 128) },
      },
    },
    text = { labels = {}, templates = {} },
    numberGlyphs = {
      advance = 8,
      height = 8,
      digits = digits,
      slash = imageRef("assets/generated/party/slash.png", 8, 8),
      level = imageRef("assets/generated/party/level.png", 16, 8),
    },
    shinyLeaves = {
      anchors = anchors,
      crownAnchor = { x = 111, y = 182 },
      leafSequence = 6,
      crownSequence = 7,
      paletteBank = 1,
      leaves = {
        frames = { frameRef("assets/generated/party/leaf-0.png", 16, 16, 4) },
        loopFrom = 1,
        playback = "loop",
      },
      crown = {
        frames = { frameRef("assets/generated/party/crown-0.png", 16, 16, 4) },
        loopFrom = 1,
        playback = "loop",
      },
    },
  }
end

local function writeReady(cache, marker)
  local data = manifest()
  cache:writeLua(PartyCache.manifestPath(), data)
  for _, path in ipairs(PartyCache.referencedPaths(data)) do
    cache:write(path, "pixels")
  end
  cache:writeLua(PartyCache.provenancePath(), { cacheFormat = PartyCache.FORMAT, schema = "g4-party-presentation-v2" })
  cache:write(PartyCache.markerPath(), marker)
end

function T.missing_image_is_not_ready()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = PartyCache.marker("abc", "dep")
  cache:writeLua(PartyCache.manifestPath(), manifest())
  cache:writeLua(PartyCache.provenancePath(), { cacheFormat = PartyCache.FORMAT, schema = "g4-party-presentation-v2" })
  cache:write(PartyCache.markerPath(), marker)
  Assert.isFalse(PartyCache.isReady(cache, marker), "referenced images must all exist")
end

function T.stale_format_is_not_ready()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  writeReady(cache, PartyCache.marker("abc", "dep"))
  Assert.isFalse(PartyCache.isReady(cache, "party-v0:abc:dep"), "a marker from another format never reads as current")
end

function T.missing_marker_is_not_ready()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local data = manifest()
  cache:writeLua(PartyCache.manifestPath(), data)
  for _, path in ipairs(PartyCache.referencedPaths(data)) do
    cache:write(path, "pixels")
  end
  cache:writeLua(PartyCache.provenancePath(), { cacheFormat = PartyCache.FORMAT, schema = "g4-party-presentation-v2" })
  Assert.isFalse(PartyCache.isReady(cache, PartyCache.marker("abc", "dep")), "no marker means not ready")
end

function T.current_valid_family_is_ready()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local marker = PartyCache.marker("abc", "dep")
  writeReady(cache, marker)
  Assert.isTrue(PartyCache.isReady(cache, marker), "the complete family reads as ready")
  local loaded = PartyCache.loadManifest(cache)
  Assert.equal(loaded.schema, "g4-party-presentation-v2")
end

return { tests = T }
