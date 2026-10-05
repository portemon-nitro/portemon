-- Native Summary pane contracts over semantic generated roles: info and
-- memo content lands in its named fixed/group windows with generated
-- wording only, skills values carry their nature inks, move rows keep
-- their four named rows with generated detail text, performance prints no
-- numeric debug text, ribbons page through dedicated count/name/detail
-- roles, member chrome draws only proved sprite roles at producer
-- anchors, portraits use the exact supplied selector, palette blends
-- reach the shader with unnormalized targets, and every draw restores
-- graphics state. Geometry and wording here are test-local and minimal;
-- ROM-derived expectations live in the graphics suite.

local Assert = require("tests.support.Assert")
local FakeGraphics = require("tests.support.FakeGraphics")
local SummaryRenderer = require("libs.hgss.src.ui.SummaryRenderer")

local T = {}

local PAD_X = SummaryRenderer.TEXT_PAD_X
local PAD_Y = SummaryRenderer.TEXT_PAD_Y
local LINE_STEP = SummaryRenderer.LINE_STEP

---@param foreground integer[] rgb
---@param shadow integer[] rgb
---@return table<string, table<string, integer>> the opaque triple over a transparent backing
local function triple(foreground, shadow)
  return {
    foreground = { r = foreground[1], g = foreground[2], b = foreground[3], a = 255 },
    shadow = { r = shadow[1], g = shadow[2], b = shadow[3], a = 255 },
    background = { r = 0, g = 0, b = 0, a = 0 },
  }
end

local INKS = {
  ordinary = triple({ 255, 255, 255 }, { 107, 107, 107 }),
  dark = triple({ 72, 72, 72 }, { 180, 180, 180 }),
  statRaised = triple({ 255, 120, 120 }, { 107, 107, 107 }),
  statLowered = triple({ 120, 160, 255 }, { 107, 107, 107 }),
  movePanel = triple({ 72, 72, 72 }, { 200, 200, 200 }),
  male = triple({ 80, 140, 255 }, { 107, 107, 107 }),
  female = triple({ 255, 140, 200 }, { 107, 107, 107 }),
}

---@param pane string
---@param x integer
---@param y integer
---@param width integer
---@param height integer
---@param ink string?
---@param align string?
---@return table<string, unknown> one semantic window role
local function role(pane, x, y, width, height, ink, align)
  local record = {
    pane = pane,
    rect = { x = x, y = y, width = width, height = height },
    palette = 13,
    ink = ink or "ordinary",
  }
  if align ~= nil then
    record.align = align
  end
  return record
end

---@param seed integer distinct vertical slot so roles never overlap
---@return table<string, unknown> the semantic fixed roles this coverage names
local function fixedWindows(seed)
  return {
    infoTab = role("main", 2, 165 + seed, 43, 26),
    skillsTab = role("main", 48, 165 + seed, 48, 26),
    performanceTab = role("main", 99, 165 + seed, 41, 26),
    cancelButton = role("sub", 189, 165 + seed, 61, 26),
    exitLabel = role("sub", 8, 165 + seed, 60, 16),
  }
end

---@return table<string, unknown> per-group semantic pane roles with the produced census
local function groupWindows()
  return {
    info = {
      main = {
        memoBody = role("main", 8, 40, 240, 64),
        memoAuxLine = role("main", 8, 112, 240, 16),
      },
      sub = {
        dexNumber = role("sub", 8, 8, 60, 16),
        speciesName = role("sub", 72, 8, 100, 16, "ordinary", "center"),
        otName = role("sub", 176, 8, 72, 16),
        idNumber = role("sub", 176, 28, 72, 16, "ordinary", "right"),
        expPoints = role("sub", 8, 120, 120, 16),
        expToNext = role("sub", 132, 120, 116, 16, "ordinary", "right"),
      },
    },
    skills = {
      main = {
        hpValue = role("main", 8, 8, 80, 16),
        attackValue = role("main", 8, 28, 80, 16),
        defenseValue = role("main", 8, 48, 80, 16),
        spAttackValue = role("main", 96, 28, 80, 16),
        spDefenseValue = role("main", 96, 48, 80, 16),
        speedValue = role("main", 8, 68, 80, 16),
        abilityName = role("main", 8, 96, 120, 16),
        abilityDescription = role("main", 8, 116, 232, 32),
      },
      sub = {
        moveRow0 = role("sub", 8, 8, 120, 16),
        moveRow1 = role("sub", 8, 28, 120, 16),
        moveRow2 = role("sub", 8, 48, 120, 16),
        moveRow3 = role("sub", 8, 68, 120, 16),
        prospectiveRow = role("sub", 8, 88, 120, 16),
        detailPower = role("sub", 136, 8, 112, 16),
        detailAccuracy = role("sub", 136, 28, 112, 16),
        detailDescription = role("sub", 136, 48, 112, 48),
        moveFooter = role("sub", 8, 120, 240, 16),
        detailCategory = role("sub", 136, 100, 112, 16),
      },
    },
    performance = {
      main = {
        speed = role("main", 8, 8, 120, 16),
        power = role("main", 8, 32, 120, 16),
        skill = role("main", 8, 56, 120, 16),
        stamina = role("main", 8, 80, 120, 16),
        jump = role("main", 8, 104, 120, 16),
      },
      sub = {
        ribbonCount = role("sub", 8, 8, 240, 16),
        ribbonName = role("sub", 8, 120, 240, 16),
        ribbonDescription = role("sub", 8, 140, 240, 40),
      },
    },
  }
end

---@return table<string, string> generated labels with synthetic wording
local function generatedLabels()
  return {
    hpLabel = "SYN-HP",
    attackLabel = "SYN-ATTACK",
    defenseLabel = "SYN-DEFENSE",
    spAttackLabel = "SYN-SP-ATK",
    spDefenseLabel = "SYN-SP-DEF",
    speedLabel = "SYN-SPEED",
    abilityLabel = "SYN-ABILITY",
    ppLabel = "SYN-PP",
    powerLabel = "SYN-POWER",
    accuracyLabel = "SYN-ACCURACY",
    categoryLabel = "SYN-CATEGORY",
    switchLabel = "SYN-SWITCH",
    cancelLabel = "SYN-CANCEL",
    forgetLabel = "SYN-FORGET",
    hmWarning = "SYN-HM-WARNING",
    staleNotice = "SYN-STALE-NOTICE",
    emptyNotice = "SYN-EMPTY-NOTICE",
    ribbonCountLabel = "SYN-RIBBONS",
    dexLabel = "SYN-DEX",
    nameLabel = "SYN-NAME",
    otLabel = "SYN-OT",
    idLabel = "SYN-ID",
    expLabel = "SYN-EXP",
    nextLabel = "SYN-NEXT",
    speedName = "SYN-SPEED",
    powerName = "SYN-POWER",
    skillName = "SYN-SKILL",
    staminaName = "SYN-STAMINA",
    jumpName = "SYN-JUMP",
  }
end

---@return table<string, unknown> the generated text section over the test inks
local function generatedText()
  local roles = { slot13 = triple({ 255, 255, 255 }, { 107, 107, 107 }) }
  for name, ink in pairs(INKS) do
    roles[name] = ink
  end
  return { labels = generatedLabels(), templates = {}, roles = roles }
end

---@return table<string, unknown> the semantic test family in produced shape
local function manifest()
  return {
    schema = "g4-summary-manifest-v2",
    paneSize = { width = 256, height = 192 },
    groups = {
      info = { main = { map = 1 }, sub = { normal = 2, restricted = 3 } },
      skills = { main = { map = 4 }, sub = { normal = 5, restricted = 6 } },
      performance = { main = { map = 7, locked = 8 }, sub = { normal = 9, noPerformance = 10 } },
    },
    windows = { fixed = fixedWindows(0), groups = groupWindows() },
    visuals = {
      ["backdrop1"] = { image = "syn/backdrop1.png", width = 256, height = 192 },
      ["backdrop2"] = { image = "syn/backdrop2.png", width = 256, height = 192 },
      ["backdrop4"] = { image = "syn/backdrop4.png", width = 256, height = 192 },
      ["backdrop5"] = { image = "syn/backdrop5.png", width = 256, height = 192 },
      ["backdrop7"] = { image = "syn/backdrop7.png", width = 256, height = 192 },
      ["backdrop9"] = { image = "syn/backdrop9.png", width = 256, height = 192 },
      ["hp-empty"] = { image = "syn/hp-empty.png", width = 8, height = 8 },
      ["hp-full"] = { image = "syn/hp-full.png", width = 8, height = 8 },
      ["exp-empty"] = { image = "syn/exp-empty.png", width = 8, height = 8 },
      ["exp-full"] = { image = "syn/exp-full.png", width = 8, height = 8 },
    },
    sprites = {},
    hitboxes = {
      touch = {
        memberTouch0 = { top = 38, bottom = 66, left = 165, right = 203 },
        memberTouch1 = { top = 46, bottom = 74, left = 205, right = 243 },
      },
    },
    text = generatedText(),
    palettes = { banks = {} },
    bars = {
      hp = {
        length = 48,
        colors = {
          high = { r = 0, g = 255, b = 0 },
          low = { r = 255, g = 255, b = 0 },
          critical = { r = 255, g = 0, b = 0 },
        },
        empty = { image = "syn/hp-empty.png", width = 8, height = 8 },
        full = { image = "syn/hp-full.png", width = 8, height = 8 },
      },
      exp = {
        length = 56,
        colors = {
          high = { r = 0, g = 0, b = 255 },
          low = { r = 0, g = 0, b = 255 },
          critical = { r = 0, g = 0, b = 255 },
        },
        empty = { image = "syn/exp-empty.png", width = 8, height = 8 },
        full = { image = "syn/exp-full.png", width = 8, height = 8 },
      },
    },
    pictures = {
      SYNM = {
        portrait = "SYNM/f0/male/plain",
        cryDelayTicks = 0,
        samples = {
          {
            durationTicks = 1,
            frameIndex = 0,
            offsetX = 0,
            offsetY = 0,
            scaleX = 1,
            scaleY = 1,
            rotationTurns = 0,
            visible = true,
          },
        },
        terminal = {},
        placement = { offsetX = 0, offsetY = 0 },
      },
      SHEDINJA = {
        portrait = "SHEDINJA/f0/male/plain",
        cryDelayTicks = 0,
        samples = {
          {
            durationTicks = 1,
            frameIndex = 0,
            offsetX = 0,
            offsetY = 0,
            scaleX = 1,
            scaleY = 1,
            rotationTurns = 0,
            visible = true,
          },
        },
        terminal = {},
        placement = { offsetX = 0, offsetY = 0 },
      },
      EGG = {
        visual = "syn/egg.png",
        cryDelayTicks = 0,
        samples = {
          {
            durationTicks = 1,
            frameIndex = 0,
            offsetX = 0,
            offsetY = 0,
            scaleX = 1,
            scaleY = 1,
            rotationTurns = 0,
            visible = true,
          },
        },
        terminal = {},
      },
    },
    ribbons = { entries = {}, initialSpecialDescriptions = {}, descriptionChoices = { base = 1, slots = {} } },
    performance = {},
    dexNumbers = {},
    memo = { conditions = {} },
    sounds = {},
    transitions = {},
  }
end

---@return table<string, unknown>[] four logical move rows with two learned moves
local function moves()
  return {
    {
      kind = "move",
      moveSlot = 0,
      key = "SYN-TACKLE",
      name = "SYN-TACKLE",
      type = "SYN-NORMAL",
      category = "SYN-PHYSICAL",
      powerText = "35",
      accuracyText = "95",
      description = "SYN-CHARGE-DESC",
      pp = 35,
      ppMax = 35,
      ppUps = 0,
    },
    {
      kind = "move",
      moveSlot = 1,
      key = "SYN-GROWL",
      name = "SYN-GROWL",
      type = "SYN-NORMAL",
      category = "SYN-OTHER",
      powerText = "—",
      accuracyText = "100",
      description = "SYN-GROWL-DESC",
      pp = 40,
      ppMax = 40,
      ppUps = 0,
    },
    { kind = "empty", moveSlot = 2 },
    { kind = "empty", moveSlot = 3 },
  }
end

---@param overrides table<string, unknown>?
---@return table<string, unknown> display-ready facts in produced shape
local function facts(overrides)
  local record = {
    revision = 7,
    contextKey = "test-context",
    slot = 0,
    slotCount = 1,
    roster = { { slot = 0, isEgg = false, iconKey = "SYNM/f0", portraitSelector = "SYNM/f0/male/plain" } },
    isEgg = false,
    identity = {
      species = "SYNM",
      form = 0,
      nickname = "SYNM",
      displayName = "SYNM",
      speciesName = "SYN-SPECIES",
      types = { "SYN-GRASS" },
      otName = "SYN-OT",
      gender = "male",
      shiny = false,
    },
    pictureKey = "SYNM",
    portraitSelector = "SYNM/f0/male/plain",
    iconKey = "SYNM/f0",
    memo = {
      condition = "syn-wild",
      blocks = {
        { line = 1, runs = { { text = "SYN-MET", ink = "ordinary" }, { text = "SYN-SOMEWHERE", ink = "dark" } } },
        { line = 3, runs = { { text = "SYN-THIRD", ink = "ordinary" } } },
      },
    },
    info = {
      dexNumber = 25,
      dexText = "SYN-DEX-025",
      otIdText = "SYN-ID-12345",
      experience = 1000,
      expToNext = 20,
      expBar = { length = 28 },
      heldItem = "SYN-NONE",
      heldItemName = "SYN-NONE",
      ball = "SYN-BALL",
    },
    skills = {
      level = 5,
      currentHp = 20,
      maxHp = 20,
      attack = 11,
      defense = 10,
      speed = 9,
      specialAttack = 12,
      specialDefense = 11,
      ability = "SYN-OVERGROW",
      abilityName = "SYN-OVERGROW",
      abilityDescription = "SYN-BOOSTS-GRASS",
      nature = { up = "attack", down = "defense" },
      hpBar = { length = 48, color = "high" },
    },
    moves = moves(),
    ribbons = {},
    performance = nil,
    indicators = {
      status = "SYN-OK",
      pokerus = "none",
      markings = { false, false, false, false, false, false },
      leaves = { false, false, false, false, false },
      crown = false,
      shiny = false,
    },
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      record[key] = value
    end
  end
  return record
end

---@param count integer earned ribbons to project
---@return table<string, unknown>[] earned ribbon facts with path art records
local function earnedRibbons(count)
  local ribbons = {}
  for index = 1, count do
    local key = string.format("SYN-RIBBON-%02d", index)
    ribbons[#ribbons + 1] = {
      key = key,
      name = key,
      description = key .. "-DESC",
      art = {
        image = "syn/ribbon-" .. index .. ".png",
        width = 32,
        height = 32,
        palette = 0,
      },
    }
  end
  return ribbons
end

---@return table<string, unknown>[] five performance rows in display order
local function performanceRows()
  return {
    { stat = "speed", base = 5, min = 0, max = 10, stars = 7, tone = "above" },
    { stat = "power", base = 5, min = 0, max = 10, stars = 5, tone = "base" },
    { stat = "skill", base = 5, min = 0, max = 10, stars = 3, tone = "below" },
    { stat = "stamina", base = 5, min = 0, max = 10, stars = 6, tone = "above" },
    { stat = "jump", base = 5, min = 0, max = 10, stars = 4, tone = "below" },
  }
end

---@param record table<string, unknown> facts under test
---@param group string
---@param extra table<string, unknown>?
---@return table<string, unknown> stable controller-shaped status
local function openStatus(record, group, extra)
  local status = {
    open = true,
    mode = "summary",
    group = group,
    phase = "root",
    slot = 0,
    moveSlot = nil,
    reorderSource = nil,
    ribbonIndex = nil,
    ribbonPage = nil,
    notice = nil,
    facts = record,
    pictureEpoch = 0,
    picture = {
      sampleIndex = 1,
      frameIndex = 0,
      offsetX = 0,
      offsetY = 0,
      scaleX = 1,
      scaleY = 1,
      rotationTurns = 0,
      visible = true,
    },
    transition = nil,
  }
  if extra ~= nil then
    for key, value in pairs(extra) do
      status[key] = value
    end
  end
  return status
end

---@param calls table<string, unknown>[] recorded text calls
---@return table<string, unknown> recording generated-font collaborator
local function textDouble(calls)
  local text = {}
  local pending = { value = "", width = 0 }
  function text:textWidth(value)
    pending = { value = value, width = #value * 6 }
    return pending.width
  end
  function text:drawLineWithPalette(tokens, x, y, palette)
    assert(type(palette) == "table", "summary text draws through palette roles")
    assert(type(palette.foreground) == "table", "palette roles carry foreground")
    assert(type(palette.shadow) == "table", "palette roles carry shadow")
    assert(type(palette.background) == "table", "palette roles carry background")
    calls[#calls + 1] =
      { value = pending.value, tokens = tokens, x = x, y = y, palette = palette, width = pending.width }
  end
  function text:drawLineWithColorVariants(tokens, x, y, variants, background)
    calls[#calls + 1] = { value = pending.value, tokens = tokens, x = x, y = y, variants = variants }
  end
  text.fontDef = { charmap = {} }
  return text
end

---@param calls table<string, unknown> recorded portrait reads
---@return table<string, unknown> portrait provider over one dummy image
local function portraitDouble(calls)
  local image = { id = "portrait-image" }
  local portraits = {}
  function portraits:image(selector)
    calls.images[#calls.images + 1] = selector
    return image
  end
  function portraits:quadFor(selector, frameIndex)
    calls.quads[#calls.quads + 1] = { selector = selector, frameIndex = frameIndex }
    return { selector = selector, frameIndex = frameIndex }
  end
  function portraits:dimensions(_)
    return { width = 80, height = 80 }
  end
  return portraits
end

---@return table<string, unknown> recording picture shader double
local function shaderDouble()
  local shader = { sends = {} }
  function shader:send(name, value)
    self.sends[#self.sends + 1] = { name = name, value = value }
  end
  return shader
end

---@param family table<string, unknown> semantic test family
---@param realized table<string, table<string, unknown>>? realized images by visual name and path
---@return table<string, table<string, unknown>> images keyed by visual name and image path
local function realizeVisuals(family, realized)
  realized = realized or {}
  local visuals = assert(family.visuals, "the test family carries visuals")
  for name, record in pairs(visuals) do
    assert(type(record) == "table", "visuals are records")
    local image = { id = "visual:" .. name }
    realized[name] = image
    local path = assert(record.image, "visuals carry their image path")
    realized[path] = image
  end
  return realized
end

---@param family table<string, unknown>
---@param text table<string, unknown>
---@param portraits table<string, unknown>
---@param shader table<string, unknown>
---@param realized table<string, table<string, unknown>>
---@param lookups table<string, unknown>[]
---@return table<string, unknown> ready-bundle-shaped test bundle
local function readyBundle(family, text, portraits, shader, realized, lookups)
  local assets = { manifest = family, portraits = portraits, text = text, shader = shader }
  function assets.visualImage(name)
    lookups[#lookups + 1] = { kind = "visual", name = name }
    local visuals = assert(family.visuals, "the test family carries visuals")
    if visuals[name] == nil then
      return nil
    end
    local image = realized[name]
    assert(image ~= nil, "visual " .. name .. " is not prepared")
    return image
  end
  function assets.imageForPath(path)
    lookups[#lookups + 1] = { kind = "path", name = path }
    local image = realized[path]
    assert(image ~= nil, "no prepared image for path " .. tostring(path))
    return image
  end
  return assets
end

---@return FakeGraphics, table<string, unknown>, table<string, unknown>, table<string, unknown>, table<string, unknown>, SummaryRenderer
local function composition()
  local graphics = FakeGraphics.new({})
  local textCalls = {}
  local portraitCalls = { images = {}, quads = {} }
  local text = textDouble(textCalls)
  local portraits = portraitDouble(portraitCalls)
  local shader = shaderDouble()
  local renderer = SummaryRenderer.new({ graphics = graphics, text = text })
  return graphics, textCalls, portraitCalls, portraits, shader, renderer
end

---@param family table<string, unknown>
---@param record table<string, unknown>?
---@return table<string, string> every generated word the renderer may print
local function generatedCorpus(family, record)
  local words = {}
  local function add(value)
    if type(value) == "string" then
      words[#words + 1] = value
    elseif type(value) == "number" then
      words[#words + 1] = tostring(value)
    elseif type(value) == "table" then
      for _, entry in pairs(value) do
        add(entry)
      end
    end
  end
  local text = assert(family.text, "the test family carries text")
  add(assert(text.labels, "text carries labels"))
  local templates = assert(text.templates, "text carries templates")
  for _, template in pairs(templates) do
    if type(template) == "table" and type(template.segments) == "table" then
      for _, segment in ipairs(template.segments) do
        if type(segment) == "table" and type(segment.value) == "string" then
          words[#words + 1] = segment.value
        end
      end
    end
  end
  if record ~= nil then
    add(record)
  end
  return words
end

---@param value string drawn line under test
---@param corpus table<string, string> allowed generated wording
---@param what string assertion owner
local function assertGenerated(value, corpus, what)
  for word in tostring(value):gmatch("%S+") do
    local allowed = false
    for _, source in ipairs(corpus) do
      if source:find(word, 1, true) ~= nil then
        allowed = true
        break
      end
    end
    Assert.isTrue(allowed, what .. " prints only generated wording; found " .. word)
  end
end

---@param drawn table<string, unknown> recorded palette triple
---@param role table<string, unknown> compiled text role
---@return boolean matches
local function roleMatches(drawn, role)
  for _, class in ipairs({ "foreground", "shadow", "background" }) do
    local got = drawn[class]
    local want = role[class]
    if type(got) ~= "table" or type(want) ~= "table" then
      return false
    end
    if got.r ~= want.r or got.g ~= want.g or got.b ~= want.b then
      return false
    end
    local wantAlpha = want.a
    if type(wantAlpha) == "number" and wantAlpha > 1 then
      wantAlpha = wantAlpha / 255
    end
    if got.a ~= wantAlpha then
      return false
    end
  end
  return true
end

---@param calls table<string, unknown>[] recorded text calls
---@param window table<string, unknown> semantic window role
---@return table<string, unknown>[] calls starting inside the role rect
local function callsInWindow(calls, window)
  local rect = assert(window.rect, "window roles carry rects")
  local found = {}
  for _, call in ipairs(calls) do
    if
      type(call.x) == "number"
      and type(call.y) == "number"
      and call.x >= rect.x
      and call.x < rect.x + rect.width
      and call.y >= rect.y
      and call.y < rect.y + rect.height
    then
      found[#found + 1] = call
    end
  end
  return found
end

---@param calls table<string, unknown>[] recorded text calls
---@param window table<string, unknown> semantic window role
---@param fragment string required value fragment
---@param family table<string, unknown> semantic test family
---@param expected table<string, unknown>? exact ink triple replacing the window palette triple
---@return table<string, unknown> the matching call
local function assertRoleValue(calls, window, fragment, family, expected)
  local found = nil
  for _, call in ipairs(callsInWindow(calls, window)) do
    if tostring(call.value):find(fragment, 1, true) ~= nil then
      found = call
    end
  end
  Assert.notNil(found, "the named role draws its value " .. fragment)
  assert(found ~= nil, "role values draw above")
  local roles = assert(assert(family.text, "the test family carries text").roles, "text carries roles")
  local want = expected
  if want == nil then
    want = assert(roles["slot" .. window.palette], "window palettes resolve through text roles")
  end
  Assert.isTrue(roleMatches(found.palette, want), "role text carries its expected triple")
  return found
end

---@param value unknown
---@return unknown deep copy for mutation checks
local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, entry in pairs(value) do
    copy[deepCopy(key)] = deepCopy(entry)
  end
  return copy
end

function T.info_and_memo_draw_through_named_roles_with_generated_copy()
  local _, textCalls, _, portraits, shader, renderer = composition()
  local family = manifest()
  local record = facts()
  local realized = realizeVisuals(family)
  local lookups = {}
  local text = textDouble(textCalls)
  local bundle = readyBundle(family, text, portraits, shader, realized, lookups)
  local corpus = generatedCorpus(family, record)
  renderer:drawPane(openStatus(record, "info"), "main", bundle)
  renderer:drawPane(openStatus(record, "info"), "sub", bundle)
  Assert.isTrue(#textCalls > 0, "info panes draw role text")
  local groups = assert(assert(family.windows, "the family carries windows").groups, "windows carry groups")
  local info = assert(groups.info, "groups carry info")
  local main = assert(info.main, "info carries main roles")
  local sub = assert(info.sub, "info carries sub roles")
  local memoBody = assert(main.memoBody, "info main carries its memo body")
  local memoRect = assert(memoBody.rect, "memo roles carry rects")
  local blockLines = {}
  for _, call in ipairs(callsInWindow(textCalls, memoBody)) do
    blockLines[#blockLines + 1] = call
  end
  Assert.equal(#blockLines, 3, "memo runs draw once each in run order")
  Assert.equal(blockLines[1].value, "SYN-MET", "the first run keeps its text")
  Assert.equal(blockLines[2].value, "SYN-SOMEWHERE", "the second run keeps its text")
  Assert.equal(blockLines[3].value, "SYN-THIRD", "the later block keeps its text")
  Assert.equal(blockLines[1].y, memoRect.y, "the first block keeps its source line")
  Assert.equal(blockLines[2].y, memoRect.y, "runs on one line share its source row")
  Assert.equal(blockLines[3].y, memoRect.y + 2 * LINE_STEP, "the later block keeps its source line")
  Assert.equal(blockLines[1].x, memoRect.x + PAD_X, "memo lines keep their source padding")
  Assert.isTrue(blockLines[2].x >= blockLines[1].x, "later runs never move before earlier runs")
  local textRoles = assert(assert(family.text, "the family carries text").roles, "text carries roles")
  Assert.isTrue(roleMatches(blockLines[1].palette, textRoles.ordinary), "the first run keeps its ink")
  Assert.isTrue(roleMatches(blockLines[2].palette, textRoles.dark), "the second run keeps its ink")
  assertRoleValue(textCalls, sub.dexNumber, "SYN-DEX-025", family)
  assertRoleValue(textCalls, sub.speciesName, "SYN-SPECIES", family)
  assertRoleValue(textCalls, sub.otName, "SYN-OT", family)
  assertRoleValue(textCalls, sub.idNumber, "SYN-ID-12345", family)
  assertRoleValue(textCalls, sub.expPoints, "1000", family)
  assertRoleValue(textCalls, sub.expToNext, "20", family)
  for _, call in ipairs(textCalls) do
    if call.value ~= nil then
      assertGenerated(call.value, corpus, "info panes")
    end
  end
end

function T.unrelated_entries_never_move_placed_content()
  local _, firstCalls, _, firstPortraits, firstShader, firstRenderer = composition()
  local family = manifest()
  local record = facts()
  local firstBundle =
    readyBundle(family, textDouble(firstCalls), firstPortraits, firstShader, realizeVisuals(family), {})
  firstRenderer:drawPane(openStatus(record, "info"), "sub", firstBundle)
  local _, secondCalls, _, secondPortraits, secondShader, secondRenderer = composition()
  local reordered = manifest()
  local reorderedFixed = {}
  local fixedNames = {}
  for name in pairs(assert(reordered.windows, "the family carries windows").fixed) do
    fixedNames[#fixedNames + 1] = name
  end
  table.sort(fixedNames, function(a, b)
    return tostring(a) > tostring(b)
  end)
  for _, name in ipairs(fixedNames) do
    reorderedFixed[name] = reordered.windows.fixed[name]
  end
  reorderedFixed.extraUnrelated = role("sub", 200, 160, 40, 16)
  reordered.windows.fixed = reorderedFixed
  local reorderedGroups = {
    info = { main = {}, sub = {} },
    skills = reordered.windows.groups.skills,
    performance = reordered.windows.groups.performance,
  }
  local infoRoles = {}
  for name in pairs(reordered.windows.groups.info.sub) do
    infoRoles[#infoRoles + 1] = name
  end
  table.sort(infoRoles, function(a, b)
    return tostring(a) > tostring(b)
  end)
  for _, name in ipairs(infoRoles) do
    reorderedGroups.info.sub[name] = reordered.windows.groups.info.sub[name]
  end
  reorderedGroups.info.main = reordered.windows.groups.info.main
  reordered.windows.groups = reorderedGroups
  local secondBundle =
    readyBundle(reordered, textDouble(secondCalls), secondPortraits, secondShader, realizeVisuals(reordered), {})
  secondRenderer:drawPane(openStatus(record, "info"), "sub", secondBundle)
  Assert.equal(#firstCalls, #secondCalls, "reordered entries draw the same calls")
  for index, call in ipairs(firstCalls) do
    local other = secondCalls[index]
    Assert.equal(other.value, call.value, "reordered entries keep call " .. index .. " wording")
    Assert.equal(other.x, call.x, "reordered entries keep call " .. index .. " x")
    Assert.equal(other.y, call.y, "reordered entries keep call " .. index .. " y")
  end
end

function T.skills_values_nature_inks_and_move_rows_use_native_roles()
  local _, textCalls, _, portraits, shader, renderer = composition()
  local family = manifest()
  local record = facts()
  local text = textDouble(textCalls)
  local bundle = readyBundle(family, text, portraits, shader, realizeVisuals(family), {})
  local corpus = generatedCorpus(family, record)
  renderer:drawPane(openStatus(record, "skills"), "main", bundle)
  local groups = assert(assert(family.windows, "the family carries windows").groups, "windows carry groups")
  local skills = assert(groups.skills, "groups carry skills")
  local main = assert(skills.main, "skills carries main roles")
  local textRoles = assert(assert(family.text, "the family carries text").roles, "text carries roles")
  local raised = assertRoleValue(textCalls, main.attackValue, "11", family, textRoles.statRaised)
  Assert.isTrue(roleMatches(raised.palette, textRoles.statRaised), "raised values use the raised role")
  local lowered = assertRoleValue(textCalls, main.defenseValue, "10", family, textRoles.statLowered)
  Assert.isTrue(roleMatches(lowered.palette, textRoles.statLowered), "lowered values use the lowered role")
  local neutral = assertRoleValue(textCalls, main.speedValue, "9", family)
  Assert.isTrue(roleMatches(neutral.palette, textRoles.ordinary), "neutral values use the ordinary role")
  assertRoleValue(textCalls, main.hpValue, "20", family)
  assertRoleValue(textCalls, main.abilityName, "SYN-OVERGROW", family)
  assertRoleValue(textCalls, main.abilityDescription, "SYN-BOOSTS-GRASS", family)
  local detail = openStatus(record, "skills", { phase = "move_detail", moveSlot = 0 })
  renderer:drawPane(detail, "sub", bundle)
  local sub = assert(skills.sub, "skills carries sub roles")
  local firstRow = assertRoleValue(textCalls, sub.moveRow0, "SYN-TACKLE", family)
  Assert.isTrue(tostring(firstRow.value):find("35", 1, true) ~= nil, "move rows carry their power points")
  assertRoleValue(textCalls, sub.moveRow1, "SYN-GROWL", family)
  assertRoleValue(textCalls, sub.detailPower, "35", family)
  assertRoleValue(textCalls, sub.detailAccuracy, "95", family)
  assertRoleValue(textCalls, sub.detailCategory, "SYN-PHYSICAL", family)
  assertRoleValue(textCalls, sub.detailDescription, "SYN-CHARGE-DESC", family)
  for _, call in ipairs(textCalls) do
    if call.value ~= nil then
      Assert.isTrue(call.value ~= "-", "empty rows never print an invented dash")
      assertGenerated(call.value, corpus, "skills panes")
    end
  end
end

function T.move_reorder_picker_and_footer_keep_native_roles()
  local graphics, textCalls, _, portraits, shader, renderer = composition()
  local family = manifest()
  local record = facts()
  local text = textDouble(textCalls)
  local bundle = readyBundle(family, text, portraits, shader, realizeVisuals(family), {})
  local corpus = generatedCorpus(family, record)
  local reorder = openStatus(record, "skills", { phase = "move_reorder", moveSlot = 0, reorderSource = 1 })
  renderer:drawPane(reorder, "sub", bundle)
  local sub = assert(
    assert(
      assert(assert(family.windows, "the family carries windows").groups, "windows carry groups").skills,
      "groups carry skills"
    ).sub,
    "skills carries sub roles"
  )
  assertRoleValue(textCalls, sub.moveRow0, "SYN-TACKLE", family)
  assertRoleValue(textCalls, sub.moveRow1, "SYN-GROWL", family)
  local footer = callsInWindow(textCalls, sub.moveFooter)
  Assert.isTrue(#footer >= 1, "reordering keeps its footer role")
  local picker = openStatus(record, "skills", { mode = "move_pick", moveSlot = 1 })
  renderer:drawPane(picker, "sub", bundle)
  local preview = callsInWindow(textCalls, sub.prospectiveRow)
  Assert.isTrue(#preview >= 1, "the picker keeps its preview role")
  for _, call in ipairs(textCalls) do
    if call.value ~= nil then
      Assert.isTrue(call.value ~= "-", "empty rows never print an invented dash")
    end
  end
  for _, call in ipairs(textCalls) do
    local inPreview = false
    for _, seen in ipairs(preview) do
      if seen == call then
        inPreview = true
      end
    end
    if call.value ~= nil and not inPreview then
      assertGenerated(call.value, corpus, "move flows")
    end
  end
  for _, rectangle in ipairs(graphics.rectangles) do
    Assert.equal(rectangle.w, SummaryRenderer.PANE_WIDTH, "no chrome rectangle replaces a mapped visual")
    Assert.equal(rectangle.h, SummaryRenderer.PANE_HEIGHT, "no chrome rectangle replaces a mapped visual")
  end
end

function T.move_notices_use_generated_warnings()
  local _, textCalls, _, portraits, shader, renderer = composition()
  local family = manifest()
  local record = facts()
  local text = textDouble(textCalls)
  local bundle = readyBundle(family, text, portraits, shader, realizeVisuals(family), {})
  local labels = assert(assert(family.text, "the family carries text").labels, "text carries labels")
  renderer:drawPane(
    openStatus(record, "skills", { phase = "move_detail", moveSlot = 0, notice = { reason = "hm" } }),
    "sub",
    bundle
  )
  local warned = false
  for _, call in ipairs(textCalls) do
    if call.value == labels.hmWarning then
      warned = true
    end
  end
  Assert.isTrue(warned, "the held-move notice prints the generated warning")
  for _, call in ipairs(textCalls) do
    if call.value ~= nil and call.value ~= "" then
      Assert.isTrue(tostring(call.value):find("forgotten", 1, true) == nil, "notices never fall back to invented prose")
    end
  end
end

function T.performance_and_ribbons_render_paged_source_state()
  local graphics, textCalls, _, portraits, shader, renderer = composition()
  local family = manifest()
  local ribbons = earnedRibbons(12)
  local record = facts({ performance = performanceRows(), ribbons = ribbons })
  local realized = realizeVisuals(family)
  for _, ribbon in ipairs(ribbons) do
    local art = assert(ribbon.art, "ribbons carry art")
    local image = { id = "ribbon:" .. tostring(ribbon.key) }
    realized[assert(art.image, "art carries its path")] = image
  end
  local text = textDouble(textCalls)
  local lookups = {}
  local bundle = readyBundle(family, text, portraits, shader, realized, lookups)
  local corpus = generatedCorpus(family, record)
  renderer:drawPane(openStatus(record, "performance"), "main", bundle)
  local labels = assert(assert(family.text, "the family carries text").labels, "text carries labels")
  local groups = assert(assert(family.windows, "the family carries windows").groups, "windows carry groups")
  local performance = assert(groups.performance, "groups carry performance")
  local main = assert(performance.main, "performance carries main roles")
  for _, stat in ipairs({ "speed", "power", "skill", "stamina", "jump" }) do
    local window = assert(main[stat], "performance carries its " .. stat .. " role")
    assertRoleValue(textCalls, window, labels[stat .. "Name"], family)
  end
  for _, call in ipairs(textCalls) do
    if call.value ~= nil then
      Assert.isTrue(tostring(call.value):find("%d") == nil, "performance prints no numeric debug text")
      assertGenerated(call.value, corpus, "performance panes")
    end
  end
  local status = openStatus(record, "performance", { phase = "ribbon_detail", ribbonIndex = 10, ribbonPage = 1 })
  renderer:drawPane(status, "sub", bundle)
  local sub = assert(performance.sub, "performance carries sub roles")
  assertRoleValue(textCalls, sub.ribbonCount, "12", family)
  assertRoleValue(textCalls, sub.ribbonName, "SYN-RIBBON-11", family)
  assertRoleValue(textCalls, sub.ribbonDescription, "SYN-RIBBON-11-DESC", family)
  for _, call in ipairs(textCalls) do
    if call.value ~= nil then
      local value = tostring(call.value)
      for index = 1, 12 do
        if index ~= 11 then
          local other = string.format("SYN-RIBBON-%02d", index)
          Assert.isTrue(value:find(other, 1, true) == nil, "only the selected ribbon names its text roles")
        end
      end
      assertGenerated(value, corpus, "ribbon panes")
    end
  end
  local drawnImages = {}
  for _, draw in ipairs(graphics.draws) do
    if draw.image ~= nil and draw.image.id ~= nil then
      drawnImages[tostring(draw.image.id)] = true
    end
  end
  Assert.isTrue(drawnImages["ribbon:SYN-RIBBON-10"] == true, "the page draws its first cell art")
  Assert.isTrue(drawnImages["ribbon:SYN-RIBBON-12"] == true, "the page draws its last cell art")
  Assert.isTrue(drawnImages["ribbon:SYN-RIBBON-01"] == nil, "off-page art never draws")
end

function T.chrome_draws_only_proved_roles_at_producer_anchors()
  local graphics, textCalls, _, portraits, shader, renderer = composition()
  local family = manifest()
  family.sprites = {
    memberSlot0 = { visual = "memberDot", anchor = { x = 170, y = 40 }, order = 1 },
    memberSlot1 = { visual = "memberDot", anchor = { x = 210, y = 48 }, order = 2 },
    memberSlot2 = { visual = "memberDot", anchor = { x = 190, y = 70 }, order = 3 },
    futureSlot = { visual = "futureChrome", anchor = { x = 150, y = 90 }, order = 4 },
  }
  family.visuals.memberDot = { image = "syn/member-dot.png", width = 16, height = 16 }
  local roster = {}
  for slot = 0, 5 do
    roster[#roster + 1] = {
      slot = slot,
      isEgg = false,
      iconKey = "SYNM/f0",
      portraitSelector = "SYNM/f0/male/plain",
    }
  end
  local record = facts({ roster = roster, slotCount = 6 })
  local realized = realizeVisuals(family)
  local lookups = {}
  local bundle = readyBundle(family, textDouble(textCalls), portraits, shader, realized, lookups)
  renderer:drawPane(openStatus(record, "info"), "sub", bundle)
  local dots = {}
  for _, draw in ipairs(graphics.draws) do
    if draw.image == realized.memberDot then
      dots[#dots + 1] = draw
    end
  end
  Assert.equal(#dots, 3, "proved member visuals draw once each")
  local anchors = { { x = 170, y = 40 }, { x = 210, y = 48 }, { x = 190, y = 70 } }
  for index, draw in ipairs(dots) do
    Assert.equal(draw.x, anchors[index].x, "member visuals use their producer anchor")
    Assert.equal(draw.y, anchors[index].y, "member visuals use their producer anchor")
  end
  local touch = assert(assert(family.hitboxes, "the family carries hitboxes").touch, "hitboxes carry touch")
  for _, draw in ipairs(graphics.draws) do
    Assert.isTrue(draw.y ~= 160, "member visuals never form the invented one-row strip")
    for _, box in pairs(touch) do
      assert(type(box) == "table", "touch targets are records")
      local matchesTouch = draw.x == box.left and draw.y == box.top
      Assert.isFalse(matchesTouch, "render anchors never come from touch boxes")
    end
  end
  local unmappedLookups = 0
  for _, lookup in ipairs(lookups) do
    if lookup.name == "futureChrome" then
      unmappedLookups = unmappedLookups + 1
    end
  end
  Assert.isTrue(unmappedLookups <= 1, "unmapped roles resolve without invented substitutes")
end

function T.portrait_draw_uses_the_exact_supplied_selector()
  local _, textCalls, portraitCalls, portraits, shader, renderer = composition()
  local family = manifest()
  local record = facts({
    pictureKey = "SHEDINJA",
    portraitSelector = "SHEDINJA/f0/male/plain",
    identity = {
      species = "SHEDINJA",
      form = 0,
      nickname = "SHEDINJA",
      displayName = "SHEDINJA",
      speciesName = "SYN-SHEDINJA",
      types = { "SYN-GHOST" },
      otName = "SYN-OT",
      gender = "genderless",
      shiny = false,
    },
  })
  local bundle = readyBundle(family, textDouble(textCalls), portraits, shader, realizeVisuals(family), {})
  local ok, err = pcall(renderer.drawPane, renderer, openStatus(record, "info"), "main", bundle)
  Assert.equal(portraitCalls.images[1], "SHEDINJA/f0/male/plain", "genderless mons keep their declared variant")
  Assert.isTrue(ok, "exact selectors draw: " .. tostring(err))
  local _, shinyCalls, shinyPortraits, shinyProvider, shinyShader, shinyRenderer = composition()
  local shinyFacts = facts({
    pictureKey = "SYNM",
    portraitSelector = "SYNM/f1/female/shiny",
    identity = {
      species = "SYNM",
      form = 1,
      nickname = "SYNM",
      displayName = "SYNM",
      speciesName = "SYN-SPECIES",
      types = { "SYN-GRASS" },
      otName = "SYN-OT",
      gender = "female",
      shiny = true,
    },
  })
  local shinyBundle =
    readyBundle(family, textDouble(shinyCalls), shinyProvider, shinyShader, realizeVisuals(family), {})
  shinyRenderer:drawPane(openStatus(shinyFacts, "info"), "main", shinyBundle)
  Assert.equal(shinyPortraits.images[1], "SYNM/f1/female/shiny", "alternate shiny forms keep their selector")
end

function T.nonzero_palette_blend_reaches_the_shader_unchanged()
  local graphics, textCalls, _, portraits, _, renderer = composition()
  local previousShader = { id = "previous-shader" }
  graphics.setShader(previousShader)
  graphics.setColor(0.2, 0.3, 0.4, 1)
  graphics.setScissor(1, 2, 3, 4)
  local family = manifest()
  local record = facts()
  local shader = shaderDouble()
  local bundle = readyBundle(family, textDouble(textCalls), portraits, shader, realizeVisuals(family), {})
  local status = openStatus(record, "info", {
    picture = {
      sampleIndex = 1,
      frameIndex = 0,
      offsetX = 2,
      offsetY = -3,
      scaleX = 2,
      scaleY = 0.5,
      rotationTurns = 0.25,
      visible = true,
      paletteBlend = { target = { r = 31, g = 0, b = 15 }, coefficient = 8 },
    },
  })
  local ok, err = pcall(renderer.drawPane, renderer, status, "main", bundle)
  local target, coefficient = nil, nil
  for _, send in ipairs(shader.sends) do
    if send.name == "u_target" then
      target = send.value
    elseif send.name == "u_coefficient" then
      coefficient = send.value
    end
  end
  Assert.deepEqual(target, { 31, 0, 15 }, "blends carry the unnormalized target")
  Assert.equal(coefficient, 8, "blends carry the source coefficient")
  Assert.isTrue(ok, "blended pictures draw: " .. tostring(err))
  local pictureDraw = nil
  for _, draw in ipairs(graphics.draws) do
    if draw.image ~= nil and draw.image.id == "portrait-image" then
      pictureDraw = draw
    end
  end
  Assert.notNil(pictureDraw, "the main pane draws its picture")
  assert(pictureDraw ~= nil, "pictures draw above")
  Assert.equal(pictureDraw.x, 210, "the frame centers on its anchor plus offsets")
  Assert.equal(pictureDraw.y, 101, "the frame centers on its anchor plus offsets")
  local red, green, blue, alpha = graphics.getColor()
  Assert.deepEqual({ red, green, blue, alpha }, { 0.2, 0.3, 0.4, 1 }, "draws restore the caller color")
  Assert.equal(graphics.getShader(), previousShader, "draws restore the caller shader")
  local sx, sy, sw, sh = graphics.getScissor()
  Assert.deepEqual({ sx, sy, sw, sh }, { 1, 2, 3, 4 }, "draws restore the caller scissor")
  local unblended = FakeGraphics.new({})
  local unblendedShader = shaderDouble()
  local unblendedText = textDouble({})
  local plainRenderer = SummaryRenderer.new({ graphics = unblended, text = unblendedText })
  local plainBundle = readyBundle(family, unblendedText, portraits, unblendedShader, realizeVisuals(family), {})
  plainRenderer:drawPane(openStatus(record, "info"), "main", plainBundle)
  Assert.equal(#unblendedShader.sends, 0, "absent blends never bind the shader")
end

function T.required_resource_failures_restore_graphics_state()
  local graphics, textCalls, _, portraits, shader, renderer = composition()
  graphics.setColor(0.2, 0.3, 0.4, 1)
  local family = manifest()
  local strict = { manifest = family, portraits = portraits, text = textDouble(textCalls), shader = shader }
  function strict.visualImage(name)
    error("visual " .. tostring(name) .. " is not prepared", 0)
  end
  function strict.imageForPath(path)
    error("no prepared image for path " .. tostring(path), 0)
  end
  local ok, err = pcall(renderer.drawPane, renderer, openStatus(facts(), "info"), "main", strict)
  Assert.isFalse(ok, "missing required resources fail loudly")
  Assert.isTrue(
    tostring(err):find("pane windows", 1, true) ~= nil or tostring(err):find("prepared", 1, true) ~= nil,
    "failures name their missing contract"
  )
  local red, green, blue, alpha = graphics.getColor()
  Assert.deepEqual({ red, green, blue, alpha }, { 0.2, 0.3, 0.4, 1 }, "failures restore the caller color")
end

function T.draws_are_deterministic_and_leave_inputs_untouched()
  local _, firstCalls, _, firstPortraits, firstShader, firstRenderer = composition()
  local family = manifest()
  local record = facts({ performance = performanceRows(), ribbons = earnedRibbons(12) })
  local before = { status = deepCopy(openStatus(record, "performance")), family = deepCopy(family) }
  local firstBundle =
    readyBundle(family, textDouble(firstCalls), firstPortraits, firstShader, realizeVisuals(family), {})
  firstRenderer:drawPane(openStatus(record, "performance"), "main", firstBundle)
  firstRenderer:drawPane(openStatus(record, "performance"), "sub", firstBundle)
  local _, secondCalls, _, secondPortraits, secondShader, secondRenderer = composition()
  local secondBundle =
    readyBundle(family, textDouble(secondCalls), secondPortraits, secondShader, realizeVisuals(family), {})
  secondRenderer:drawPane(openStatus(record, "performance"), "main", secondBundle)
  secondRenderer:drawPane(openStatus(record, "performance"), "sub", secondBundle)
  Assert.equal(#secondCalls, #firstCalls, "repeated draws record the same text")
  for index, call in ipairs(firstCalls) do
    local other = secondCalls[index]
    Assert.equal(other.value, call.value, "repeated draws keep wording")
    Assert.equal(other.x, call.x, "repeated draws keep x")
    Assert.equal(other.y, call.y, "repeated draws keep y")
  end
  Assert.deepEqual(openStatus(record, "performance").picture, before.status.picture, "draws never mutate status")
  Assert.deepEqual(record.memo, before.status.facts.memo, "draws never mutate facts")
  Assert.deepEqual(family.groups, before.family.groups, "draws never mutate the family")
end

function T.hp_bar_tiles_follow_compiled_lengths_and_zero()
  local graphics, textCalls, _, portraits, shader, renderer = composition()
  local family = manifest()
  local realized = realizeVisuals(family)
  local bundle = readyBundle(family, textDouble(textCalls), portraits, shader, realized, {})
  renderer:drawPane(openStatus(facts(), "info"), "sub", bundle)
  local full, empty = 0, 0
  for _, draw in ipairs(graphics.draws) do
    if draw.image == realized["hp-full"] then
      full = full + 1
    elseif draw.image == realized["hp-empty"] then
      empty = empty + 1
    end
  end
  Assert.equal(full, 6, "full health fills six tiles")
  Assert.equal(empty, 0, "full health leaves no empty tile")
  local faint = facts({
    skills = {
      level = 5,
      currentHp = 0,
      maxHp = 20,
      attack = 11,
      defense = 10,
      speed = 9,
      specialAttack = 12,
      specialDefense = 11,
      ability = "SYN-OVERGROW",
      abilityName = "SYN-OVERGROW",
      abilityDescription = "SYN-BOOSTS-GRASS",
      nature = { up = "attack", down = "defense" },
      hpBar = { length = 0, color = "critical" },
    },
  })
  local graphics2 = FakeGraphics.new({})
  local secondText = textDouble({})
  local renderer2 = SummaryRenderer.new({ graphics = graphics2, text = secondText })
  renderer2:drawPane(
    openStatus(faint, "info"),
    "sub",
    readyBundle(family, secondText, portraits, shader, realized, {})
  )
  local full2, empty2 = 0, 0
  for _, draw in ipairs(graphics2.draws) do
    if draw.image == realized["hp-full"] then
      full2 = full2 + 1
    elseif draw.image == realized["hp-empty"] then
      empty2 = empty2 + 1
    end
  end
  Assert.equal(full2, 0, "fainted health fills no tile")
  Assert.equal(empty2, 6, "fainted health empties every tile")
end

function T.hp_bar_tints_follow_filled_pixels_not_tiles()
  local function barSkills(pixels)
    return {
      level = 5,
      currentHp = 20,
      maxHp = 20,
      attack = 11,
      defense = 10,
      speed = 9,
      specialAttack = 12,
      specialDefense = 11,
      ability = "SYN-OVERGROW",
      abilityName = "SYN-OVERGROW",
      abilityDescription = "SYN-BOOSTS-GRASS",
      nature = { up = "attack", down = "defense" },
      hpBar = { length = pixels, color = "high" },
    }
  end
  local function tintOf(pixels)
    local graphics, textCalls, _, portraits, shader, renderer = composition()
    local family = manifest()
    local realized = realizeVisuals(family)
    local bundle = readyBundle(family, textDouble(textCalls), portraits, shader, realized, {})
    renderer:drawPane(openStatus(facts({ skills = barSkills(pixels) }), "info"), "sub", bundle)
    local tints = {}
    for _, draw in ipairs(graphics.draws) do
      if draw.image == realized["hp-full"] then
        local color = assert(draw.color, "bar draws carry their tint")
        tints[#tints + 1] = string.format("%g,%g,%g,%g", color[1], color[2], color[3], color[4])
      end
    end
    Assert.isTrue(#tints > 0, "a non-zero fill draws tinted tiles")
    return tints
  end
  for _, tint in ipairs(tintOf(25)) do
    Assert.equal(tint, "0,1,0,1", "25 of 48 pixels reads the high ink")
  end
  for _, tint in ipairs(tintOf(10)) do
    Assert.equal(tint, "1,1,0,1", "10 of 48 pixels reads the low ink")
  end
  for _, tint in ipairs(tintOf(5)) do
    Assert.equal(tint, "1,0,0,1", "5 of 48 pixels reads the critical ink")
  end
end

function T.picture_centers_on_its_anchor_with_the_playback_transform()
  local graphics, _, portraitCalls, portraits, shader, renderer = composition()
  local family = manifest()
  local bundle = readyBundle(family, textDouble({}), portraits, shader, realizeVisuals(family), {})
  local status = openStatus(facts(), "info", {
    picture = {
      sampleIndex = 1,
      frameIndex = 1,
      offsetX = 2,
      offsetY = -3,
      scaleX = 2,
      scaleY = 0.5,
      rotationTurns = 0.25,
      visible = true,
    },
  })
  renderer:drawPane(status, "main", bundle)
  local pictureDraw = nil
  for _, draw in ipairs(graphics.draws) do
    if draw.image ~= nil and draw.image.id == "portrait-image" then
      pictureDraw = draw
    end
  end
  Assert.notNil(pictureDraw, "the main pane draws its picture")
  assert(pictureDraw ~= nil, "pictures draw above")
  Assert.equal(pictureDraw.x, 210, "the frame centers on 208 plus offsets")
  Assert.equal(pictureDraw.y, 101, "the frame centers on 104 plus offsets")
  Assert.equal(pictureDraw.sx, 2, "horizontal scale applies")
  Assert.equal(pictureDraw.sy, 0.5, "vertical scale applies")
  Assert.isTrue(math.abs(pictureDraw.rotation - math.pi / 2) < 1e-9, "rotation turns convert to radians")
  Assert.deepEqual(
    portraitCalls.quads[1],
    { selector = "SYNM/f0/male/plain", frameIndex = 2 },
    "frames address one-based samples"
  )
end

function T.hidden_pictures_draw_nothing()
  local graphics, _, _, portraits, shader, renderer = composition()
  local family = manifest()
  local bundle = readyBundle(family, textDouble({}), portraits, shader, realizeVisuals(family), {})
  local status = openStatus(facts(), "info", {
    picture = {
      sampleIndex = 1,
      frameIndex = 0,
      offsetX = 0,
      offsetY = 0,
      scaleX = 1,
      scaleY = 1,
      rotationTurns = 0,
      visible = false,
    },
  })
  renderer:drawPane(status, "main", bundle)
  for _, draw in ipairs(graphics.draws) do
    Assert.isTrue(draw.image == nil or draw.image.id ~= "portrait-image", "hidden pictures draw no pixels")
  end
end

function T.closed_statuses_draw_nothing()
  local graphics, _, _, portraits, shader, renderer = composition()
  local family = manifest()
  local closedText = textDouble({})
  local bundle = readyBundle(family, closedText, portraits, shader, realizeVisuals(family), {})
  renderer:drawPane({ open = false }, "main", bundle)
  Assert.equal(#graphics.draws + #graphics.rectangles, 0, "closed panes leave no output")
end

return { tests = T }
