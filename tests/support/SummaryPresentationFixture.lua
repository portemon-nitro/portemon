-- Synthetic native summary presentation data for summary-fact tests. The
-- manifest mirrors the real generated envelope shapes (closed top-level
-- field set, species-keyed pictures, ribbon entries with bit bindings and
-- special-description slots, form-keyed performance rows, dex maps, and
-- memo condition/template/label records) with invented display text, so
-- unit tests never need a dump. Display strings carry a SYN prefix to keep
-- synthetic expectations distinct from ROM-derived text. Location ids are
-- synthetic selection inputs: 1..500 reads wild, 4000..4099 reads gift,
-- 0 reads pal-park, anything else reads wild with the fallback landmark.
-- Condition keys, line indices, and the egg-watch threshold set follow the
-- source-authored positions the memo contract pins for the ordinary wild
-- branch (nature 1, date 2, characteristic 6, flavor 7).

local SummaryPresentationFixture = {}

SummaryPresentationFixture.SCHEMA = "g4-summary-manifest-v1"

SummaryPresentationFixture.WILD_LOCATION = 7
SummaryPresentationFixture.GIFT_LOCATION = 4001
SummaryPresentationFixture.PAL_PARK_LOCATION = 0
SummaryPresentationFixture.UNKNOWN_LOCATION = 60000

local function sample()
  return {
    durationTicks = 2,
    frameIndex = 0,
    offsetX = 0,
    offsetY = 0,
    scaleX = 1,
    scaleY = 1,
    rotationTurns = 0,
    visible = true,
  }
end

local function picture(portrait)
  return {
    portrait = portrait,
    cryDelayTicks = 0,
    samples = { sample() },
    terminal = {},
  }
end

local function barVisual(name)
  return { image = "assets/generated/summary/syn-" .. name .. ".png", width = 8, height = 8 }
end

local function statRow(base, lo, hi)
  return { base = base, lo = lo, hi = hi }
end

-- Twenty-five pokathlon nature rows in source stat order
-- (power, skill, speed, jump, stamina), transcribed from the shared
-- performance source table the generated family lowers.
local NATURE_MODIFIERS = {
  { 10, 0, 0, 0, -10 },
  { 35, -35, 0, 0, 0 },
  { 35, 0, 0, 0, -35 },
  { 35, 0, 0, -35, 0 },
  { 35, 0, -35, 0, 0 },
  { -35, 35, 0, 0, 0 },
  { 0, 10, 0, -10, 0 },
  { 0, 35, 0, 0, -35 },
  { 0, 35, 0, -35, 0 },
  { 0, 35, -35, 0, 0 },
  { -35, 0, 0, 0, 35 },
  { 0, -35, 0, 0, 35 },
  { 0, 0, -10, 0, 10 },
  { 0, 0, 0, -35, 35 },
  { 0, 0, -35, 0, 35 },
  { -35, 0, 0, 35, 0 },
  { 0, -35, 0, 35, 0 },
  { 0, 0, 0, 35, -35 },
  { -10, 0, 0, 10, 0 },
  { 0, 0, -35, 35, 0 },
  { -35, 0, 35, 0, 0 },
  { 0, -35, 35, 0, 0 },
  { 0, 0, 35, 0, -35 },
  { 0, 0, 35, -35, 0 },
  { 0, -10, 10, 0, 0 },
}

function SummaryPresentationFixture.natureModifiers()
  local rows = {}
  for _, row in ipairs(NATURE_MODIFIERS) do
    rows[#rows + 1] = { power = row[1], skill = row[2], speed = row[3], jump = row[4], stamina = row[5] }
  end
  return rows
end

local function ribbonEntries()
  local entries = {}
  local function add(key, bitGroup, bit, special)
    local index = #entries + 1
    local entry = {
      key = key,
      bitGroup = bitGroup,
      bit = bit,
      name = "synRibbonName_" .. key,
      description = "synRibbonDescription_" .. key,
      art = {
        image = "assets/generated/summary/syn-ribbon-" .. key .. ".png",
        width = 32,
        height = 32,
        palette = 0,
      },
    }
    if special ~= nil then
      entry.special = special
    end
    entries[index] = entry
  end
  for bit = 0, 30 do
    add(string.format("syn_ds1_%02d", bit), "ds1", bit)
  end
  add("syn_ds1_special", "ds1", 31, 1)
  for bit = 0, 23 do
    add(string.format("syn_gba_%02d", bit), "gba", bit)
  end
  add("syn_gba_special", "gba", 24, 2)
  for bit = 0, 22 do
    add(string.format("syn_ds2_%02d", bit), "ds2", bit)
  end
  assert(#entries == 80, "the synthetic ribbon set mirrors the 80-entry source census")
  return entries
end

local STAT_NAMES = { "Hp", "Attack", "Defense", "Speed", "SpAttack", "SpDefense" }

local function memoLabels(labels)
  labels["synMemoWild"] = "SYN wild memo"
  labels["synMemoWildTraded"] = "SYN traded memo"
  labels["synMemoWildGift"] = "SYN gift memo"
  labels["synMemoWildGiftTraded"] = "SYN traded gift memo"
  labels["synMemoFateful"] = "SYN fateful memo"
  labels["synMemoFatefulTraded"] = "SYN traded fateful memo"
  labels["synMemoMigrated"] = "SYN migrated memo"
  labels["synMemoHatched"] = "SYN hatched memo"
  labels["synMemoHatchedTraded"] = "SYN traded hatched memo"
  labels["synMemoHatchedGift"] = "SYN hatched gift memo"
  labels["synMemoEgg"] = "SYN egg memo"
  labels["synMemoEggTraded"] = "SYN traded egg memo"
  for month = 1, 12 do
    labels["synMonth" .. string.format("%02d", month)] = "SYNM" .. month
  end
  labels["synLandmarkHome"] = "SYN NEW BARK"
  labels["synLandmarkGift"] = "SYN GIFT SHOP"
  labels["synLandmarkFar"] = "SYN FARAWAY"
  for stat = 1, 6 do
    for mod = 0, 4 do
      labels["synCharacteristic" .. STAT_NAMES[stat] .. mod] = "SYN " .. STAT_NAMES[stat] .. "+" .. mod
    end
  end
  labels["synFlavorBase"] = "SYN PLAIN"
  local flavors = { "SPICY", "DRY", "SWEET", "BITTER", "SOUR" }
  for _, flavor in ipairs(flavors) do
    labels["synFlavor" .. flavor] = "SYN " .. flavor
  end
  labels["synEggWatchSoon"] = "SYN HATCH SOON"
  labels["synEggWatchClose"] = "SYN HATCH CLOSE"
  labels["synEggWatchDistant"] = "SYN HATCH DISTANT"
  labels["synEggWatchFar"] = "SYN HATCH FAR"
  labels["synUnknownDex"] = "???"
  return labels
end

local function memoSection()
  local conditions = {
    wildEncounter = { template = "synMemoWild", nature = 1, date = 2, characteristic = 6, flavor = 7, eggWatch = 0 },
    wildEncounterTraded = {
      template = "synMemoWildTraded",
      nature = 1,
      date = 2,
      characteristic = 6,
      flavor = 7,
      eggWatch = 0,
    },
    wildGift = { template = "synMemoWildGift", nature = 1, date = 2, characteristic = 6, flavor = 7, eggWatch = 0 },
    wildGiftTraded = {
      template = "synMemoWildGiftTraded",
      nature = 1,
      date = 2,
      characteristic = 6,
      flavor = 7,
      eggWatch = 0,
    },
    fatefulEncounter = {
      template = "synMemoFateful",
      nature = 1,
      date = 2,
      characteristic = 7,
      flavor = 8,
      eggWatch = 0,
    },
    fatefulEncounterTraded = {
      template = "synMemoFatefulTraded",
      nature = 1,
      date = 2,
      characteristic = 7,
      flavor = 8,
      eggWatch = 0,
    },
    migrated = { template = "synMemoMigrated", nature = 1, date = 2, characteristic = 6, flavor = 7, eggWatch = 0 },
    eggHatched = { template = "synMemoHatched", nature = 1, date = 2, characteristic = 8, flavor = 9, eggWatch = 0 },
    eggHatchedTraded = {
      template = "synMemoHatchedTraded",
      nature = 1,
      date = 2,
      characteristic = 8,
      flavor = 9,
      eggWatch = 0,
    },
    eggHatchedGift = {
      template = "synMemoHatchedGift",
      nature = 1,
      date = 2,
      characteristic = 8,
      flavor = 9,
      eggWatch = 0,
    },
    egg = { template = "synMemoEgg", nature = 0, date = 0, characteristic = 0, flavor = 0, eggWatch = 3 },
    eggTraded = { template = "synMemoEggTraded", nature = 0, date = 0, characteristic = 0, flavor = 0, eggWatch = 3 },
  }
  local months = {}
  for month = 1, 12 do
    months[month] = "synMonth" .. string.format("%02d", month)
  end
  local characteristics = {}
  for stat = 1, 6 do
    characteristics[stat] = {}
    for mod = 0, 4 do
      characteristics[stat][mod + 1] = "synCharacteristic" .. STAT_NAMES[stat] .. mod
    end
  end
  return {
    conditions = conditions,
    months = months,
    landmarks = {
      wildByLocation = { [7] = "synLandmarkHome" },
      giftByLocation = { [4001] = "synLandmarkGift" },
      fallback = "synLandmarkFar",
    },
    characteristics = characteristics,
    flavors = {
      default = "synFlavorBase",
      byFlavor = { "synFlavorSPICY", "synFlavorDRY", "synFlavorSWEET", "synFlavorBITTER", "synFlavorSOUR" },
    },
    eggWatch = {
      thresholds = { 5, 10, 40 },
      templates = { "synEggWatchSoon", "synEggWatchClose", "synEggWatchDistant", "synEggWatchFar" },
    },
  }
end

function SummaryPresentationFixture.manifest()
  local labels = {}
  memoLabels(labels)
  for _, entry in ipairs(ribbonEntries()) do
    labels[entry.name] = "SYN " .. entry.key .. " NAME"
    labels[entry.description] = "SYN " .. entry.key .. " DESC"
  end
  local specials = {}
  for slot = 1, 14 do
    specials[slot] = "SYN SPECIAL " .. slot
  end
  return {
    schema = SummaryPresentationFixture.SCHEMA,
    paneSize = { width = 256, height = 192 },
    groups = {
      info = { main = { map = 1 }, sub = { normal = 2, restricted = 3 } },
      skills = { main = { map = 4 }, sub = { normal = 5, restricted = 6 } },
      performance = { main = { map = 7, locked = 8 }, sub = { normal = 9, noPerformance = 10 } },
    },
    windows = {
      synMainA = { pane = "main", rect = { x = 8, y = 8, width = 240, height = 32 }, palette = 13 },
      synMainB = { pane = "main", rect = { x = 8, y = 48, width = 240, height = 64 }, palette = 13 },
      synSubA = { pane = "sub", rect = { x = 8, y = 8, width = 240, height = 32 }, palette = 13 },
      synSubB = { pane = "sub", rect = { x = 8, y = 48, width = 240, height = 64 }, palette = 13 },
      synSubC = { pane = "sub", rect = { x = 8, y = 120, width = 240, height = 64 }, palette = 13 },
    },
    visuals = {},
    sprites = {},
    hitboxes = {
      -- Mirroring touch entries: one box per transcribed target class
      -- (tabs, exit, member, move row, ribbon cell) with synthetic
      -- geometry inside the canonical pane. Facts and interaction tests
      -- never hit-test through this fixture; the entries only keep the
      -- strict envelope green.
      touch = {
        synTabInfo = { top = 165, bottom = 191, left = 2, right = 45 },
        synTabSkills = { top = 165, bottom = 191, left = 48, right = 96 },
        synTabPerformance = { top = 165, bottom = 191, left = 99, right = 140 },
        synExit = { top = 165, bottom = 191, left = 189, right = 250 },
        synMember0 = { top = 38, bottom = 66, left = 165, right = 203 },
        synMember1 = { top = 46, bottom = 74, left = 205, right = 243 },
        synMoveRow0 = { top = 8, bottom = 39, left = 8, right = 127 },
        synMoveRow1 = { top = 40, bottom = 71, left = 8, right = 127 },
        synRibbonCell0 = { top = 8, bottom = 39, left = 16, right = 47 },
        synRibbonCell1 = { top = 8, bottom = 39, left = 48, right = 79 },
      },
    },
    text = {
      labels = labels,
      templates = {},
      roles = {
        slot13 = {
          foreground = { r = 255, g = 255, b = 255, a = 255 },
          shadow = { r = 107, g = 107, b = 107, a = 255 },
          background = { r = 0, g = 0, b = 0, a = 0 },
        },
      },
    },
    palettes = {},
    bars = {
      hp = {
        length = 48,
        colors = {
          high = { r = 0, g = 255, b = 0 },
          low = { r = 255, g = 255, b = 0 },
          critical = { r = 255, g = 0, b = 0 },
        },
        empty = barVisual("syn-hp-empty"),
        full = barVisual("syn-hp-full"),
      },
      exp = {
        length = 56,
        colors = {
          high = { r = 0, g = 0, b = 255 },
          low = { r = 0, g = 0, b = 255 },
          critical = { r = 0, g = 0, b = 255 },
        },
        empty = barVisual("syn-exp-empty"),
        full = barVisual("syn-exp-full"),
      },
    },
    pictures = {
      CHIKORITA = picture("CHIKORITA/f0/male/plain"),
      TOTODILE = picture("TOTODILE/f0/male/plain"),
      EEVEE = picture("EEVEE/f0/male/plain"),
      SHEDINJA = picture("SHEDINJA/f0/male/plain"),
      EGG = {
        visual = "assets/generated/summary/syn-egg.png",
        cryDelayTicks = 0,
        samples = { sample() },
        terminal = {},
      },
    },
    ribbons = {
      entries = ribbonEntries(),
      initialSpecialDescriptions = specials,
      descriptionChoices = { base = 146, slots = { 1, 2 } },
    },
    performance = {
      forms = {
        ["CHIKORITA/f0"] = {
          power = statRow(5, 0, 10),
          stamina = statRow(5, 0, 10),
          skill = statRow(5, 0, 10),
          jump = statRow(5, 0, 10),
          speed = statRow(5, 0, 10),
        },
        ["TOTODILE/f0"] = {
          power = statRow(5, 3, 7),
          stamina = statRow(5, 3, 7),
          skill = statRow(5, 3, 7),
          jump = statRow(5, 3, 7),
          speed = statRow(5, 3, 7),
        },
        ["EEVEE/f0"] = {
          power = statRow(5, 0, 10),
          stamina = statRow(5, 0, 10),
          skill = statRow(5, 0, 10),
          jump = statRow(5, 0, 10),
          speed = statRow(5, 0, 10),
        },
        ["EEVEE/f1"] = {
          power = statRow(6, 0, 10),
          stamina = statRow(6, 0, 10),
          skill = statRow(6, 0, 10),
          jump = statRow(6, 0, 10),
          speed = statRow(6, 0, 10),
        },
        ["SHEDINJA/f0"] = {
          power = statRow(5, 0, 10),
          stamina = statRow(5, 0, 10),
          skill = statRow(5, 0, 10),
          jump = statRow(5, 0, 10),
          speed = statRow(5, 0, 10),
        },
      },
      natureModifiers = SummaryPresentationFixture.natureModifiers(),
      zeroAprijuice = { power = 0, stamina = 0, skill = 0, jump = 0, speed = 0 },
    },
    dexNumbers = {
      CHIKORITA = { national = 152, regional = 1 },
      TOTODILE = { national = 158, regional = 4 },
      EEVEE = { national = 133, regional = 180 },
      SHEDINJA = { national = 292, regional = 0 },
    },
    memo = memoSection(),
    sounds = {},
    transitions = {},
  }
end

-- Builds the explicit read-only display context: profile identity, captured
-- day, dex display mode, performance enablement, per-slot signed aprijuice
-- rows, and the complete special-ribbon description slots. Production
-- supplies zero aprijuice rows today; tests set nonzero rows only to prove
-- the modifier path.
---@param slotCount integer
---@param overrides table<string, unknown>|nil
---@return table<string, unknown>
function SummaryPresentationFixture.context(slotCount, overrides)
  assert(type(slotCount) == "number" and slotCount % 1 == 0 and slotCount >= 1, "context needs the party size")
  overrides = overrides or {}
  local CatalogFixture = require("libs.mons.tests.catalog_fixture")
  local profile = CatalogFixture.profile()
  local aprijuiceBySlot = {}
  for _ = 1, slotCount do
    aprijuiceBySlot[#aprijuiceBySlot + 1] = { power = 0, stamina = 0, skill = 0, jump = 0, speed = 0 }
  end
  local specials = {}
  for slot = 1, 14 do
    specials[slot] = "SYN SPECIAL " .. slot
  end
  local context = {
    profile = { trainerId = profile.trainerId, name = profile.name, gender = profile.gender },
    dayOfMonth = 13,
    dexMode = "regional",
    performanceEnabled = true,
    aprijuiceBySlot = aprijuiceBySlot,
    specialRibbonDescriptions = specials,
  }
  for key, value in pairs(overrides) do
    context[key] = value
  end
  return context
end

return SummaryPresentationFixture
