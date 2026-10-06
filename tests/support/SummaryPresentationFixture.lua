-- Synthetic native summary presentation data for summary-fact tests. The
-- manifest mirrors the real generated envelope shapes (closed top-level
-- field set, semantic fixed/group window roles, species-keyed pictures,
-- ribbon entries with bit bindings and special-description slots,
-- form-keyed performance rows, dex maps, and ordered memo branches with
-- structured substitution templates) with invented display text, so unit
-- tests never need a dump. Display strings carry a SYN prefix to keep
-- synthetic expectations distinct from ROM-derived text. Window geometry
-- is synthetic but pane-correct; only the role vocabulary and the memo
-- branch order mirror the generated contract. Memo branches carry their
-- own structured date templates, never label-only strings: a branch that
-- references its wording through a label name instead of segments
-- misrepresents the generated contract. Condition keys, line indices,
-- and the egg-watch threshold set follow the source-authored positions
-- the memo contract pins for the ordinary wild branch
-- (nature 1, date 2, characteristic 6, flavor 7).

local SummaryPresentationFixture = {}

SummaryPresentationFixture.SCHEMA = "g4-summary-manifest-v3"

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

-- Synthetic dynamic chrome mirroring the generated semantic roles: one
-- single-frame animation per required role state, six member anchors,
-- move geometry, five performance rows of five star anchors with
-- modifier slots, five leaf anchors with the crown anchor, and ribbon
-- grid/page controls. Animation and frame-visual names mirror the
-- generated semantic vocabulary so preparation and schema tests
-- exercise reference resolution.
local CHROME_ANIMATIONS = {
  "rootFocus",
  "moveRowFocus",
  "restrictedCancel",
  "moveCancel",
  "moveFollow",
  "starBase",
  "starAbove",
  "starBelow",
  "starEmpty",
  "modifierPositive",
  "modifierNegative",
  "leaf",
  "crown",
  "ribbonCursor",
  "ribbonPagePrev",
  "ribbonPageNext",
}

local function chromeVisuals()
  local visuals = {
    detailBacking = { image = "assets/generated/summary/syn-detail-backing.png", width = 8, height = 8 },
  }
  for _, name in ipairs(CHROME_ANIMATIONS) do
    visuals["syn-" .. name] =
      { image = "assets/generated/summary/syn-" .. name .. ".png", width = 16, height = 16 }
  end
  return visuals
end

local function chromeSprites()
  local animations = {}
  for _, name in ipairs(CHROME_ANIMATIONS) do
    animations[name] = { frames = { { visual = "syn-" .. name, durationTicks = 2 } }, loopFrom = 1, playback = "static" }
  end
  local primaryAnchors = {}
  for index = 1, 6 do
    primaryAnchors[index] = { x = 8 * index, y = 8 }
  end
  local leafAnchors = {}
  for index = 1, 5 do
    leafAnchors[index] = { x = 8 * index, y = 16 }
  end
  local rows = {}
  for index = 1, 5 do
    local stars = {}
    for star = 1, 5 do
      stars[star] = { x = 8 * star, y = 8 * index }
    end
    rows[index] = {
      stat = "synStat" .. index,
      stars = stars,
      modifier = { x = 8, y = 8 * index },
      starBase = "starBase",
      starAbove = "starAbove",
      starBelow = "starBelow",
      starEmpty = "starEmpty",
      modifierPositive = "modifierPositive",
      modifierNegative = "modifierNegative",
    }
  end
  return {
    animations = animations,
    primaryCursor = {
      anchors = primaryAnchors,
      rootFocus = "rootFocus",
      moveRowFocus = "moveRowFocus",
      restrictedCancel = "restrictedCancel",
    },
    secondaryMoveCursor = {
      x = 68,
      rowBaseY = 24,
      rowStep = 32,
      cancelY = 152,
      restrictedCancelY = 168,
      cancelAnchor = { x = 68, y = 168 },
      restrictedSpecialAnchor = { x = 220, y = 176 },
      moveCancel = "moveCancel",
      moveFollow = "moveFollow",
    },
    performance = { rows = rows },
    leaves = { anchors = leafAnchors, crownAnchor = { x = 8, y = 16 }, leaf = "leaf", crown = "crown" },
    ribbons = {
      origin = { x = 32, y = 24 },
      columns = 3,
      columnStep = 32,
      rowStep = 40,
      cursor = "ribbonCursor",
      pagePrev = { anchor = { x = 128, y = 32 }, animation = "ribbonPagePrev" },
      pageNext = { anchor = { x = 128, y = 96 }, animation = "ribbonPageNext" },
    },
  }
end

local function chromeTransitions()
  return {
    moveDetail = { pane = "sub", axis = "x", positions = { 0, 64, 128 } },
    ribbonDetail = { pane = "sub", axis = "y", positions = { 0, 36, 72 } },
  }
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
  labels["synLandmarkJohto"] = "SYN JOHTO"
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

-- Generated nature wording in native 0..24 order, mirroring the named
-- nature templates of the real family: a colored name run followed by a
-- plain kind run. The memo expands its nature line through these
-- templates, never through a handwritten list.
local NATURE_ORDER = {
  "Hardy",
  "Lonely",
  "Brave",
  "Adamant",
  "Naughty",
  "Bold",
  "Docile",
  "Relaxed",
  "Impish",
  "Lax",
  "Timid",
  "Hasty",
  "Serious",
  "Jolly",
  "Naive",
  "Modest",
  "Mild",
  "Quiet",
  "Bashful",
  "Rash",
  "Calm",
  "Gentle",
  "Sassy",
  "Careful",
  "Quirky",
}

local function natureTemplates()
  local templates = {}
  for _, nature in ipairs(NATURE_ORDER) do
    templates["nature" .. nature] = {
      segments = {
        { kind = "color", color = 2 },
        { kind = "text", value = "SYN " .. string.upper(nature) },
        { kind = "color", color = 0 },
        { kind = "text", value = " SYN nature." },
      },
    }
  end
  return templates
end

-- Structured synthetic date templates mirroring the generated
-- substitution shapes: literal text, line breaks, and semantic bindings
-- with no raw placeholder fields. Wording is invented; the segment
-- vocabulary and the branch coverage mirror the generated contract. Every
-- branch owns its own message in the real family, so traded variants carry
-- their own opening wording here as well; the bindings stay identical.
---@param opening string|nil
local function metSegments(opening)
  return {
    { kind = "text", value = opening or "SYN " },
    { kind = "metMonth" },
    { kind = "text", value = " SYN " },
    { kind = "metDay" },
    { kind = "text", value = ", 20" },
    { kind = "metYear" },
    { kind = "lineBreak" },
    { kind = "metLocation" },
    { kind = "lineBreak" },
    { kind = "text", value = "SYN met at Lv. " },
    { kind = "metLevel" },
    { kind = "text", value = "." },
  }
end

local function hatchedSegments()
  return {
    { kind = "text", value = "SYN " },
    { kind = "eggMonth" },
    { kind = "text", value = " SYN " },
    { kind = "eggDay" },
    { kind = "text", value = ", 20" },
    { kind = "eggYear" },
    { kind = "lineBreak" },
    { kind = "eggLocation" },
    { kind = "lineBreak" },
    { kind = "text", value = "SYN hatched. " },
    { kind = "metMonth" },
    { kind = "text", value = " SYN " },
    { kind = "metDay" },
    { kind = "lineBreak" },
    { kind = "metLocation" },
  }
end

local function eggSegments()
  return {
    { kind = "text", value = "SYN " },
    { kind = "eggMonth" },
    { kind = "text", value = " SYN " },
    { kind = "eggDay" },
    { kind = "text", value = ", 20" },
    { kind = "eggYear" },
    { kind = "lineBreak" },
    { kind = "text", value = "SYN egg from " },
    { kind = "eggLocation" },
    { kind = "text", value = "." },
  }
end

local function migratedSegments()
  return {
    { kind = "text", value = "SYN " },
    { kind = "metMonth" },
    { kind = "text", value = " SYN " },
    { kind = "metDay" },
    { kind = "lineBreak" },
    { kind = "migrationRegion" },
    { kind = "lineBreak" },
    { kind = "text", value = "SYN arrived at Lv. " },
    { kind = "metLevel" },
    { kind = "text", value = "." },
  }
end

-- Ordered synthetic memo branches mirroring the generated selection
-- order, selectability, predicates, and line placement. The traded
-- gift-location closure entry travels with the rules but never
-- selects, exactly like its generated counterpart.
local MEMO_BRANCHES = {
  { key = "migrated", match = { isEgg = false, fateful = false, eggLocation = "none", metLocation = "palPark" }, lines = { 1, 2, 6, 7, 0 }, template = migratedSegments },
  { key = "fatefulEncounter", match = { isEgg = false, fateful = true, mine = true, eggLocation = "none", metLocation = "notPalPark" }, lines = { 1, 2, 7, 8, 0 }, template = metSegments },
  { key = "fatefulEncounterTraded", match = { isEgg = false, fateful = true, mine = false, eggLocation = "none", metLocation = "notPalPark" }, lines = { 1, 2, 7, 8, 0 }, template = metSegments },
  { key = "wildGift", match = { isEgg = false, fateful = false, eggLocation = "none", metLocation = "linkTrade" }, lines = { 1, 2, 6, 7, 0 }, template = metSegments },
  { key = "wildGiftTraded", selectable = false, match = { isEgg = false, fateful = false, mine = false, eggLocation = "none", metLocation = "linkTrade" }, lines = { 1, 2, 6, 7, 0 }, template = metSegments },
  { key = "wildEncounter", match = { isEgg = false, fateful = false, mine = true, eggLocation = "none", metLocation = "wild" }, lines = { 1, 2, 6, 7, 0 }, template = metSegments },
  { key = "wildEncounterTraded", match = { isEgg = false, fateful = false, mine = false, eggLocation = "none", metLocation = "wild" }, lines = { 1, 2, 6, 7, 0 }, template = function()
    return metSegments("SYN traded ")
  end },
  { key = "fatefulEggHatchedGift", match = { isEgg = false, fateful = true, mine = true, eggLocation = "linkTrade2" }, lines = { 1, 2, 9, 0, 0 }, template = hatchedSegments },
  { key = "fatefulEggHatchedGiftTraded", match = { isEgg = false, fateful = true, mine = false, eggLocation = "linkTrade2" }, lines = { 1, 2, 9, 0, 0 }, template = hatchedSegments },
  { key = "fatefulEggHatchedArrived", match = { isEgg = false, fateful = true, mine = true, eggLocation = "ranger" }, lines = { 1, 2, 9, 0, 0 }, template = hatchedSegments },
  { key = "fatefulEggHatchedArrivedTraded", match = { isEgg = false, fateful = true, mine = false, eggLocation = "ranger" }, lines = { 1, 2, 9, 0, 0 }, template = hatchedSegments },
  { key = "fatefulEggHatched", match = { isEgg = false, fateful = true, mine = true, eggLocation = "hatched" }, lines = { 1, 2, 9, 0, 0 }, template = hatchedSegments },
  { key = "fatefulEggHatchedTraded", match = { isEgg = false, fateful = true, mine = false, eggLocation = "hatched" }, lines = { 1, 2, 9, 0, 0 }, template = hatchedSegments },
  { key = "eggHatchedGift", match = { isEgg = false, fateful = false, mine = true, eggLocation = "giftSet" }, lines = { 1, 2, 8, 9, 0 }, template = hatchedSegments },
  { key = "eggHatchedGiftTraded", match = { isEgg = false, fateful = false, mine = false, eggLocation = "giftSet" }, lines = { 1, 2, 8, 9, 0 }, template = hatchedSegments },
  { key = "eggHatched", match = { isEgg = false, fateful = false, mine = true, eggLocation = "hatched" }, lines = { 1, 2, 8, 9, 0 }, template = hatchedSegments },
  { key = "eggHatchedTraded", match = { isEgg = false, fateful = false, mine = false, eggLocation = "hatched" }, lines = { 1, 2, 8, 9, 0 }, template = hatchedSegments },
  { key = "fatefulEggArrived", match = { isEgg = true, fateful = true, mine = true, eggLocation = "ranger" }, lines = { 0, 1, 0, 0, 6 }, template = eggSegments },
  { key = "fatefulEgg", match = { isEgg = true, fateful = true, mine = true, eggLocation = "egg" }, lines = { 0, 1, 0, 0, 6 }, template = eggSegments },
  { key = "fatefulEggTraded", match = { isEgg = true, fateful = true, mine = false, eggLocation = "egg" }, lines = { 0, 1, 0, 0, 6 }, template = eggSegments },
  { key = "egg", match = { isEgg = true, fateful = false, mine = true, eggLocation = "egg" }, lines = { 0, 1, 0, 0, 6 }, template = eggSegments },
  { key = "eggTraded", match = { isEgg = true, fateful = false, mine = false, eggLocation = "egg" }, lines = { 0, 1, 0, 0, 6 }, template = eggSegments },
}

local function memoSection()
  local conditions = {}
  for _, branch in ipairs(MEMO_BRANCHES) do
    conditions[#conditions + 1] = {
      key = branch.key,
      selectable = branch.selectable ~= false,
      match = branch.match,
      lines = {
        nature = branch.lines[1],
        date = branch.lines[2],
        characteristic = branch.lines[3],
        flavor = branch.lines[4],
        eggWatch = branch.lines[5],
      },
      dateTemplate = { segments = branch.template() },
    }
  end
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
    locations = {
      palPark = 55,
      linkTrade = 4001,
      linkTrade2 = 4002,
      ranger = 6001,
      giftEggOrigins = { 4009, 4010, 4011, 4012, 4013, 4014 },
    },
    months = months,
    landmarks = {
      wildByLocation = { [7] = "synLandmarkHome" },
      giftByLocation = { [4001] = "synLandmarkGift", [4004] = "synLandmarkJohto" },
      fallback = "synLandmarkFar",
    },
    migrationRegions = { heartgold = "synLandmarkJohto", soulsilver = "synLandmarkJohto" },
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

-- Synthetic semantic window roles mirroring the generated role
-- vocabulary: the persistent fixed labels plus the per-group main/sub
-- compositions with the source-pinned per-pane census. Geometry is
-- synthetic but pane-correct; only the role names mirror the generated
-- contract.
local FIXED_ROLE_NAMES = {
  "infoTab",
  "infoTitle",
  "skillsTitle",
  "trainerMemo",
  "skillsTab",
  "performanceTitle",
  "cancelButton",
  "dexNoLabel",
  "nameLabel",
  "typeLabel",
  "otLabel",
  "idNoLabel",
  "expPointsLabel",
  "toNextLabel",
  "shinyLeaf",
  "hpLabel",
  "attackLabel",
  "defenseLabel",
  "spAttackLabel",
  "spDefenseLabel",
  "speedLabel",
  "abilityLabel",
  "switchButton",
  "exitLabel",
  "movePpHeader",
  "movePpCurrent",
  "movePpMax",
  "moveDetailHeader",
  "moveDetailNote",
  "battleMoves",
  "performanceTab",
  "ribbonsCountLabel",
  "performanceStarLabel",
  "hmWarning",
}

local GROUP_ROLE_NAMES = {
  info = {
    main = { "memoBody", "memoAuxLine" },
    sub = { "dexNumber", "speciesName", "otName", "idNumber", "expPoints", "expToNext" },
  },
  skills = {
    main = {
      "hpValue",
      "attackValue",
      "defenseValue",
      "spAttackValue",
      "spDefenseValue",
      "speedValue",
      "abilityName",
      "abilityDescription",
    },
    sub = {
      "moveRow0",
      "moveRow1",
      "moveRow2",
      "moveRow3",
      "prospectiveRow",
      "detailPower",
      "detailAccuracy",
      "detailDescription",
      "moveFooter",
      "detailCategory",
    },
  },
  performance = {
    main = { "speed", "power", "skill", "stamina", "jump" },
    sub = { "ribbonCount", "ribbonName", "ribbonDescription" },
  },
}

local function syntheticRole(pane, seed)
  return {
    pane = pane,
    rect = { x = 8, y = 8 + (seed * 12) % 176, width = 48, height = 8 },
    palette = 13,
    ink = "ordinary",
  }
end

local function syntheticWindows()
  local fixed = {}
  for index, name in ipairs(FIXED_ROLE_NAMES) do
    fixed[name] = syntheticRole(index % 2 == 0 and "main" or "sub", index)
  end
  local groups = {}
  local seed = 0
  for _, name in ipairs({ "info", "skills", "performance" }) do
    groups[name] = { main = {}, sub = {} }
    for _, pane in ipairs({ "main", "sub" }) do
      for _, role in ipairs(GROUP_ROLE_NAMES[name][pane]) do
        seed = seed + 1
        groups[name][pane][role] = syntheticRole(pane, seed)
      end
    end
  end
  return { fixed = fixed, groups = groups }
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
    windows = syntheticWindows(),
    visuals = chromeVisuals(),
    sprites = chromeSprites(),
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
      templates = natureTemplates(),
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
    transitions = chromeTransitions(),
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
