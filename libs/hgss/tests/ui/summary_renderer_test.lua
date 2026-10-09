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
local SummaryPresentationFixture = require("tests.support.SummaryPresentationFixture")
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
  local family = {
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
  -- Animated cursors, stars, markers, and panel offsets read the same
  -- generated shapes production consumes, grafted here so every pane
  -- draws through the current contract instead of an empty stand-in.
  local sourced = SummaryPresentationFixture.manifest()
  family.sprites = assert(sourced.sprites, "the sourced family carries its sprite roles")
  family.transitions = assert(sourced.transitions, "the sourced family carries its transition tracks")
  for name, record in pairs(assert(sourced.visuals, "the sourced family carries its visuals")) do
    family.visuals[name] = record
  end
  return family
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
    { stat = "speed", base = 5, min = 0, max = 10, stars = 7, tone = "above", modifier = 0 },
    { stat = "power", base = 5, min = 0, max = 10, stars = 5, tone = "base", modifier = 0 },
    { stat = "skill", base = 5, min = 0, max = 10, stars = 3, tone = "below", modifier = 0 },
    { stat = "stamina", base = 5, min = 0, max = 10, stars = 6, tone = "above", modifier = 0 },
    { stat = "jump", base = 5, min = 0, max = 10, stars = 4, tone = "below", modifier = 0 },
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
    -- Party selections address the root member cursor anchors; detached
    -- selections override this capability explicitly.
    showMemberCursor = true,
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
  renderer2:drawPane(openStatus(faint, "info"), "sub", readyBundle(family, secondText, portraits, shader, realized, {}))
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

-- Generated color controls split ink runs without inserting text, so
-- the second run starts exactly where the first run's measured width
-- ends. The current renderer adds one measured separator space that
-- the source message never contained.
function T.adjacent_color_runs_share_an_edge_without_separator_space()
  local _, textCalls, _, portraits, shader, renderer = composition()
  local family = manifest()
  local text = textDouble(textCalls)
  local bundle = readyBundle(family, text, portraits, shader, realizeVisuals(family), {})
  local record = facts({
    memo = {
      condition = "syn-adjacent",
      blocks = {
        { line = 1, runs = { { text = "AB", ink = "ordinary" }, { text = "CD", ink = "dark" } } },
      },
    },
  })
  renderer:drawPane(openStatus(record, "info"), "main", bundle)
  local memoBody = assert(
    assert(assert(family.windows, "the family carries windows").groups, "windows carry groups").info,
    "groups carry info"
  ).main
  local rect = assert(assert(memoBody.memoBody, "info main carries its memo body").rect, "memo roles carry rects")
  local memoCalls = {}
  for _, call in ipairs(textCalls) do
    if
      type(call.x) == "number"
      and type(call.y) == "number"
      and call.x >= rect.x
      and call.x < rect.x + rect.width
      and call.y >= rect.y
      and call.y < rect.y + rect.height
    then
      memoCalls[#memoCalls + 1] = call
    end
  end
  Assert.equal(#memoCalls, 2, "adjacent runs draw once each")
  Assert.equal(memoCalls[1].value, "AB", "the first run keeps its text")
  Assert.equal(memoCalls[2].value, "CD", "the second run keeps its text")
  Assert.equal(memoCalls[1].x, rect.x + PAD_X, "the line keeps its source padding")
  Assert.equal(memoCalls[2].x, memoCalls[1].x + memoCalls[1].width, "the second run starts where the first run ends")
end

-- Produced memo lines draw on consecutive baselines: the real memo
-- expansion feeds the real renderer through the fixture family, and
-- every generated break moves the next run down exactly one line step.
-- The memo window and branch placement come from the family itself;
-- only the mon record is test input.
function T.produced_memo_lines_draw_on_consecutive_baselines()
  local SummaryMemo = require("libs.hgss.src.ui.SummaryMemo")
  local SummaryPresentationFixture = require("tests.support.SummaryPresentationFixture")
  local fixture = SummaryPresentationFixture.manifest()
  local mon = {
    isEgg = false,
    fatefulEncounter = false,
    personality = 0,
    friendship = 70,
    ivs = { hp = 1, attack = 1, defense = 1, speed = 1, specialAttack = 1, specialDefense = 1 },
    origin = { game = "heartgold", trainerId = 1, trainerName = "RED", trainerGender = 0 },
    egg = { location = 0 },
    met = {
      location = SummaryPresentationFixture.WILD_LOCATION,
      level = 5,
      date = { year = 2009, month = 3, day = 13 },
    },
  }
  local memo = SummaryMemo.build(mon, true, SummaryPresentationFixture.context(1), fixture)
  Assert.equal(memo.condition, "wildEncounter", "the ordinary wild meeting keeps its branch")
  local branch = nil
  for _, candidate in ipairs(assert(fixture.memo.conditions, "the family carries ordered memo rules")) do
    if candidate.key == memo.condition then
      branch = candidate
    end
  end
  Assert.notNil(branch, "the family carries the selected branch")
  assert(branch ~= nil, "branches select above")
  local segments =
    assert(assert(branch.dateTemplate, "the branch carries its date template").segments, "templates carry segments")
  local breaks = 0
  for _, segment in ipairs(segments) do
    if segment.kind == "lineBreak" then
      breaks = breaks + 1
    end
  end
  Assert.isTrue(breaks >= 1, "the exercised template carries source line breaks")
  local base = assert(branch.lines.date, "the branch places its date line")
  local _, textCalls, _, portraits, shader, renderer = composition()
  local bundle = readyBundle(fixture, textDouble(textCalls), portraits, shader, realizeVisuals(fixture), {})
  local record = facts({
    memo = memo,
    pictureKey = "CHIKORITA",
    portraitSelector = "CHIKORITA/f0/male/plain",
  })
  renderer:drawPane(openStatus(record, "info"), "main", bundle)
  local memoBody = assert(
    assert(assert(fixture.windows, "the family carries windows").groups, "windows carry groups").info,
    "groups carry info"
  ).main
  local rect = assert(assert(memoBody.memoBody, "info main carries its memo body").rect, "memo roles carry rects")
  local drawnY = {}
  for _, call in ipairs(textCalls) do
    if
      type(call.x) == "number"
      and type(call.y) == "number"
      and call.x >= rect.x
      and call.x < rect.x + rect.width
      and call.y >= rect.y
    then
      Assert.isTrue(tostring(call.value):find("\n", 1, true) == nil, "no drawn run carries a newline glyph")
      drawnY[call.y] = true
    end
  end
  for offset = 0, breaks do
    local expected = rect.y + (base + offset - 1) * LINE_STEP
    Assert.isTrue(drawnY[expected] == true, "break " .. offset .. " draws on its own baseline")
  end
end

-- Generated dynamic-chrome vocabulary grafted onto the local synthetic
-- family: windows, labels, bars, and pictures stay exactly as the
-- surrounding coverage shapes them, while sprite roles, transition
-- tracks, and frame visuals take the generated semantic shapes the
-- runtime consumes. Frame visuals resolve through the same realized
-- bundle as every other visual.
local function sourcedFamily()
  local SummaryPresentationFixture = require("tests.support.SummaryPresentationFixture")
  local sourced = SummaryPresentationFixture.manifest()
  local family = manifest()
  family.sprites = assert(sourced.sprites, "the sourced family carries its sprite roles")
  family.transitions = assert(sourced.transitions, "the sourced family carries its transition tracks")
  local visuals = assert(sourced.visuals, "the sourced family carries its visuals")
  for name, record in pairs(visuals) do
    family.visuals[name] = record
  end
  return family, sourced
end

---@param sourced table<string, unknown> generated-shape family
---@param realized table<string, table<string, unknown>> realized images
---@param animation string animation role name
---@return table<string, unknown> realized frame image
local function frameImage(sourced, realized, animation)
  local sprites = assert(sourced.sprites, "the sourced family carries sprite roles")
  local animations = assert(sprites.animations, "sprite roles carry animations")
  local descriptor = assert(animations[animation], "the family carries animation " .. animation)
  local frames = assert(descriptor.frames, "animations carry frames")
  local first = assert(frames[1], "animations carry at least one frame")
  local visual = assert(first.visual, "frames name their visual")
  return assert(realized[visual], "frame visual " .. visual .. " is prepared")
end

---@param family table<string, unknown> grafted test family
---@param record table<string, unknown> display facts
---@param group string native group
---@param pane string "main" or "sub"
---@param extra table<string, unknown>? controller-shaped overrides
---@param extraRealized table<string, table<string, unknown>>? additional prepared images by path
---@return table<string, unknown> recording graphics
---@return table<string, table<string, unknown>> realized images backing the draw
local function drawWithChrome(family, record, group, pane, extra, extraRealized)
  local graphics, textCalls, _, portraits, shader, renderer = composition()
  local realized = realizeVisuals(family)
  if extraRealized ~= nil then
    for key, image in pairs(extraRealized) do
      realized[key] = image
    end
  end
  local status = openStatus(record, group, extra)
  local bundle = readyBundle(family, textDouble(textCalls), portraits, shader, realized, {})
  local ok, err = pcall(renderer.drawPane, renderer, status, pane, bundle)
  Assert.isTrue(ok, "dynamic chrome draws through generated roles: " .. tostring(err))
  return graphics, realized
end

function T.member_focus_follows_the_generated_party_anchors()
  local family, sourced = sourcedFamily()
  local cursors =
    assert(assert(family.sprites, "the family carries sprite roles").primaryCursor, "roles carry the primary cursor")
  local anchors = assert(cursors.anchors, "the primary cursor carries its member anchors")
  local focusAnimation = assert(cursors.rootFocus, "the cursor names its root animation")
  local roster = {}
  for slot = 0, 1 do
    roster[#roster + 1] = {
      slot = slot,
      isEgg = false,
      iconKey = "SYNM/f0",
      portraitSelector = "SYNM/f0/male/plain",
    }
  end
  local record = facts({ roster = roster, slotCount = 2, slot = 0 })
  local function cursorAt(slot, mode)
    record.slot = slot
    local graphics, realized =
      drawWithChrome(family, record, "info", "sub", { slot = slot, spriteTick = 5, mode = mode or "summary" })
    local cursorImage = frameImage(sourced, realized, focusAnimation)
    local found = {}
    for _, draw in ipairs(graphics.draws) do
      if draw.image == cursorImage then
        found[#found + 1] = draw
      end
    end
    return found
  end
  local first = cursorAt(0)
  Assert.equal(#first, 1, "one member cursor draws for the displayed member")
  Assert.equal(first[1].x, anchors[1].x, "the cursor uses its generated anchor")
  Assert.equal(first[1].y, anchors[1].y, "the cursor uses its generated anchor")
  local second = cursorAt(1)
  Assert.equal(#second, 1, "one member cursor draws after switching members")
  Assert.equal(second[1].x, anchors[2].x, "the cursor follows the displayed member")
  Assert.equal(second[1].y, anchors[2].y, "the cursor follows the displayed member")
  Assert.equal(#cursorAt(0, "move_pick"), 0, "the restricted picker hides the member cursor")
end

function T.selections_past_party_range_draw_no_member_cursor()
  local family, sourced = sourcedFamily()
  local cursors =
    assert(assert(family.sprites, "the family carries sprite roles").primaryCursor, "roles carry the primary cursor")
  local focusAnimation = assert(cursors.rootFocus, "the cursor names its root animation")
  local roster = {}
  for slot = 0, 6 do
    roster[#roster + 1] = {
      slot = slot,
      isEgg = false,
      iconKey = "SYNM/f0",
      portraitSelector = "SYNM/f0/male/plain",
    }
  end
  local record = facts({ roster = roster, slotCount = 7, slot = 6 })
  local graphics, textCalls, _, portraits, shader, renderer = composition()
  local realized = realizeVisuals(family)
  local status = openStatus(record, "info", { slot = 6, spriteTick = 5, showMemberCursor = false })
  local bundle = readyBundle(family, textDouble(textCalls), portraits, shader, realized, {})
  local ok, err = pcall(renderer.drawPane, renderer, status, "sub", bundle)
  Assert.isTrue(ok, "a selection past party range draws without party member chrome: " .. tostring(err))
  local cursorImage = frameImage(sourced, realized, focusAnimation)
  local found = 0
  for _, draw in ipairs(graphics.draws) do
    if draw.image == cursorImage then
      found = found + 1
    end
  end
  Assert.equal(found, 0, "no party member cursor draws without party member chrome")
end

function T.performance_stars_and_modifier_markers_follow_their_facts()
  local family, sourced = sourcedFamily()
  local rows = {
    { stat = "speed", base = 5, min = 0, max = 10, stars = 7, tone = "above", modifier = 2 },
    { stat = "power", base = 5, min = 0, max = 10, stars = 5, tone = "base", modifier = 0 },
    { stat = "skill", base = 5, min = 0, max = 10, stars = 3, tone = "below", modifier = -1 },
    { stat = "stamina", base = 5, min = 0, max = 3, stars = 2, tone = "below", modifier = 0 },
    { stat = "jump", base = 5, min = 0, max = 10, stars = 0, tone = "below", modifier = 0 },
  }
  local record = facts({ performance = rows })
  local graphics, realized = drawWithChrome(family, record, "performance", "main", { spriteTick = 5 })
  local sprows =
    assert(assert(family.sprites, "the family carries sprite roles").performance, "roles carry performance rows").rows
  local toneKey = { base = "starBase", above = "starAbove", below = "starBelow" }
  local expected = {}
  for index, row in ipairs(rows) do
    local sprow = assert(sprows[index], "the family carries performance row " .. index)
    local starAnchors = assert(sprow.stars, "performance rows carry star anchors")
    for i = 0, 4 do
      local anchor = assert(starAnchors[i + 1], "star positions carry anchors")
      if i > row.max then
        -- positions past the row maximum draw nothing.
      elseif i > row.stars then
        expected[#expected + 1] = {
          image = frameImage(sourced, realized, assert(sprow.starEmpty, "rows carry their empty state")),
          x = anchor.x,
          y = anchor.y,
          what = row.stat .. " empty " .. i,
        }
      else
        local key = assert(toneKey[row.tone], "tones select their star state")
        expected[#expected + 1] = {
          image = frameImage(sourced, realized, assert(sprow[key], "rows carry their filled states")),
          x = anchor.x,
          y = anchor.y,
          what = row.stat .. " filled " .. i,
        }
      end
    end
    local modifierAnchor = assert(sprow.modifier, "performance rows carry modifier anchors")
    if row.modifier > 0 then
      expected[#expected + 1] = {
        image = frameImage(sourced, realized, assert(sprow.modifierPositive, "rows carry positive markers")),
        x = modifierAnchor.x,
        y = modifierAnchor.y,
        what = row.stat .. " positive",
      }
    elseif row.modifier < 0 then
      expected[#expected + 1] = {
        image = frameImage(sourced, realized, assert(sprow.modifierNegative, "rows carry negative markers")),
        x = modifierAnchor.x,
        y = modifierAnchor.y,
        what = row.stat .. " negative",
      }
    end
  end
  Assert.isTrue(#expected > 0, "the exercised facts expect star draws")
  for _, want in ipairs(expected) do
    local count = 0
    for _, draw in ipairs(graphics.draws) do
      if draw.image == want.image and draw.x == want.x and draw.y == want.y then
        count = count + 1
      end
    end
    Assert.equal(count, 1, want.what .. " draws exactly once at its generated anchor")
  end
  local wanted = {}
  for _, want in ipairs(expected) do
    wanted[want.image] = wanted[want.image] or {}
    wanted[want.image][want.x .. "," .. want.y] = true
  end
  for _, draw in ipairs(graphics.draws) do
    local positions = wanted[draw.image]
    if positions ~= nil then
      Assert.isTrue(positions[draw.x .. "," .. draw.y] == true, "every star draw lands on a generated anchor")
    end
  end
end

function T.shiny_leaves_and_crown_render_on_the_info_main_pane_only()
  local family, sourced = sourcedFamily()
  local leafRoles = assert(assert(family.sprites, "the family carries sprite roles").leaves, "roles carry leaves")
  local leafAnchors = assert(leafRoles.anchors, "leaves carry their anchors")
  local crownAnchor = assert(leafRoles.crownAnchor, "leaves carry the crown anchor")
  local function indicatorsWith(crown, slots)
    return {
      status = "SYN-OK",
      pokerus = "none",
      markings = { false, false, false, false, false, false },
      leaves = slots,
      crown = crown,
      shiny = false,
    }
  end
  local function chromeDraws(record, group, pane)
    local graphics, realized = drawWithChrome(family, record, group, pane, { spriteTick = 5 })
    local leafImage = frameImage(sourced, realized, assert(leafRoles.leaf, "leaves name their animation"))
    local crownImage = frameImage(sourced, realized, assert(leafRoles.crown, "leaves name the crown"))
    local found = {}
    for _, draw in ipairs(graphics.draws) do
      if draw.image == leafImage or draw.image == crownImage then
        found[#found + 1] = draw
      end
    end
    return found, leafImage, crownImage
  end
  local leafy = facts({ indicators = indicatorsWith(false, { true, false, true, false, false }) })
  local leafDraws, leafImage = chromeDraws(leafy, "info", "main")
  Assert.equal(#leafDraws, 2, "each true leaf draws once")
  local positions = {}
  for _, draw in ipairs(leafDraws) do
    Assert.equal(draw.image, leafImage, "leaf slots use the leaf animation")
    positions[draw.x .. "," .. draw.y] = true
  end
  Assert.isTrue(
    positions[leafAnchors[1].x .. "," .. leafAnchors[1].y] == true,
    "the first true leaf uses its generated anchor"
  )
  Assert.isTrue(
    positions[leafAnchors[3].x .. "," .. leafAnchors[3].y] == true,
    "the second true leaf uses its generated anchor"
  )
  local crowned = facts({ indicators = indicatorsWith(true, { true, false, false, false, false }) })
  local crownDraws, _, crownImage = chromeDraws(crowned, "info", "main")
  Assert.equal(#crownDraws, 1, "the crown draws alone")
  Assert.equal(crownDraws[1].image, crownImage, "the crown uses the crown animation")
  Assert.equal(crownDraws[1].x, crownAnchor.x, "the crown uses its generated anchor")
  Assert.equal(crownDraws[1].y, crownAnchor.y, "the crown uses its generated anchor")
  Assert.equal(#chromeDraws(leafy, "skills", "main"), 0, "leaves never leave the info pane")
  Assert.equal(#chromeDraws(leafy, "info", "sub"), 0, "leaves never move to the sub pane")
end

function T.move_reorder_and_ribbon_controls_follow_native_geometry()
  local family, sourced = sourcedFamily()
  local sprites = assert(family.sprites, "the family carries sprite roles")
  local secondary = assert(sprites.secondaryMoveCursor, "roles carry nested move geometry")
  local rowBaseY = assert(secondary.rowBaseY, "move geometry carries its first row")
  local rowStep = assert(secondary.rowStep, "move geometry carries its row step")
  local record = facts()
  local reorder, realized = drawWithChrome(family, record, "skills", "sub", {
    phase = "move_reorder",
    moveSlot = 2,
    reorderSource = 0,
    spriteTick = 5,
  })
  local chromeSet = {}
  for name in pairs(assert(sourced.visuals, "the sourced family carries its visuals")) do
    if name ~= "detailBacking" then
      chromeSet[assert(realized[name], "chrome visual " .. name .. " is prepared")] = true
    end
  end
  local rowSet = {}
  for row = 0, 3 do
    rowSet[rowBaseY + row * rowStep] = true
  end
  local rowHits = {}
  for _, draw in ipairs(reorder.draws) do
    if chromeSet[draw.image] and rowSet[draw.y] then
      rowHits[#rowHits + 1] = draw.y
    end
  end
  table.sort(rowHits)
  Assert.deepEqual(
    rowHits,
    { rowBaseY, rowBaseY + 2 * rowStep },
    "source and target cursors occupy generated row anchors"
  )
  local ribbonRoles = assert(sprites.ribbons, "roles carry ribbon controls")
  local origin = assert(ribbonRoles.origin, "ribbon controls carry their grid origin")
  local columnStep = assert(ribbonRoles.columnStep, "ribbon controls carry their column step")
  local ribbonRowStep = assert(ribbonRoles.rowStep, "ribbon controls carry their row step")
  local cursorAnimation = assert(ribbonRoles.cursor, "ribbon controls name their cursor")
  local prevControl = assert(ribbonRoles.pagePrev, "ribbon controls carry the previous control")
  local nextControl = assert(ribbonRoles.pageNext, "ribbon controls carry the next control")
  local earned = earnedRibbons(20)
  local ribbonArt = {}
  for _, ribbon in ipairs(earned) do
    local art = assert(ribbon.art, "ribbons carry art")
    ribbonArt[assert(art.image, "ribbon art carries its image")] = { id = "ribbon:" .. tostring(ribbon.key) }
  end
  local cases = {
    { index = 0, page = 0, prev = false, next = true },
    { index = 10, page = 1, prev = true, next = true },
    { index = 19, page = 2, prev = true, next = false },
  }
  for _, case in ipairs(cases) do
    local ribbonRecord = facts({ ribbons = earned })
    local graphics, realizedRibbons = drawWithChrome(family, ribbonRecord, "performance", "sub", {
      phase = "ribbon_detail",
      ribbonIndex = case.index,
      ribbonPage = case.page,
      spriteTick = 5,
    }, ribbonArt)
    local cell = case.index % 9
    local cursorX = origin.x + (cell % 3) * columnStep
    local cursorY = origin.y + math.floor(cell / 3) * ribbonRowStep
    local cursorImage = frameImage(sourced, realizedRibbons, cursorAnimation)
    local prevAnchor = assert(prevControl.anchor, "page controls carry anchors")
    local nextAnchor = assert(nextControl.anchor, "page controls carry anchors")
    local prevImage =
      frameImage(sourced, realizedRibbons, assert(prevControl.animation, "page controls name animations"))
    local nextImage =
      frameImage(sourced, realizedRibbons, assert(nextControl.animation, "page controls name animations"))
    local cursorHits, prevHits, nextHits = 0, 0, 0
    for _, draw in ipairs(graphics.draws) do
      if draw.image == cursorImage and draw.x == cursorX and draw.y == cursorY then
        cursorHits = cursorHits + 1
      end
      if draw.image == prevImage and draw.x == prevAnchor.x and draw.y == prevAnchor.y then
        prevHits = prevHits + 1
      end
      if draw.image == nextImage and draw.x == nextAnchor.x and draw.y == nextAnchor.y then
        nextHits = nextHits + 1
      end
    end
    Assert.equal(cursorHits, 1, "the ribbon cursor marks earned ribbon " .. case.index)
    Assert.equal(prevHits > 0, case.prev, "the previous control shows only past the first page")
    Assert.equal(nextHits > 0, case.next, "the next control shows only before the last page")
  end
end

function T.move_detail_backing_follows_the_generated_x_offsets()
  local family, sourced = sourcedFamily()
  local track = assert(
    assert(sourced.transitions, "the sourced family carries transition tracks").moveDetail,
    "tracks carry the move detail"
  )
  Assert.equal(track.axis, "x", "the move track runs along x")
  local positions = assert(track.positions, "tracks carry positions")
  local terminal = positions[#positions]
  local record = facts()
  local cases = {
    {
      phase = "move_opening",
      transition = { kind = "moveDetail", direction = "open", axis = "x", offset = positions[1] },
      x = positions[1],
    },
    {
      phase = "move_opening",
      transition = { kind = "moveDetail", direction = "open", axis = "x", offset = positions[2] },
      x = positions[2],
    },
    { phase = "move_detail", transition = nil, x = terminal },
    {
      phase = "move_closing",
      transition = { kind = "moveDetail", direction = "close", axis = "x", offset = positions[2] },
      x = positions[2],
    },
  }
  for _, case in ipairs(cases) do
    local graphics, realized = drawWithChrome(family, record, "skills", "sub", {
      phase = case.phase,
      moveSlot = 0,
      spriteTick = 5,
      transition = case.transition,
    })
    local backing = assert(realized["detailBacking"], "the detail backing is prepared")
    local hits = 0
    for _, draw in ipairs(graphics.draws) do
      if draw.image == backing then
        hits = hits + 1
        Assert.equal(draw.x, case.x, "the detail backing translates along x by the generated offset")
      end
    end
    Assert.equal(hits, 1, "the detail backing draws exactly once")
  end
end

function T.ribbon_detail_backing_follows_the_generated_y_offsets()
  local family, sourced = sourcedFamily()
  local track = assert(
    assert(sourced.transitions, "the sourced family carries transition tracks").ribbonDetail,
    "tracks carry the ribbon detail"
  )
  Assert.equal(track.axis, "y", "the ribbon track runs along y")
  local positions = assert(track.positions, "tracks carry positions")
  local terminal = positions[#positions]
  local earned = earnedRibbons(3)
  local ribbonArt = {}
  for _, ribbon in ipairs(earned) do
    local art = assert(ribbon.art, "ribbons carry art")
    ribbonArt[assert(art.image, "ribbon art carries its image")] = { id = "ribbon:" .. tostring(ribbon.key) }
  end
  local record = facts({ ribbons = earned })
  local cases = {
    {
      phase = "ribbon_opening",
      transition = { kind = "ribbonDetail", direction = "open", axis = "y", offset = positions[1] },
      y = positions[1],
    },
    {
      phase = "ribbon_opening",
      transition = { kind = "ribbonDetail", direction = "open", axis = "y", offset = positions[2] },
      y = positions[2],
    },
    { phase = "ribbon_detail", transition = nil, y = terminal },
    {
      phase = "ribbon_closing",
      transition = { kind = "ribbonDetail", direction = "close", axis = "y", offset = positions[2] },
      y = positions[2],
    },
  }
  for _, case in ipairs(cases) do
    local graphics, realized = drawWithChrome(family, record, "performance", "sub", {
      phase = case.phase,
      ribbonIndex = 0,
      ribbonPage = 0,
      spriteTick = 5,
      transition = case.transition,
    }, ribbonArt)
    local backing = assert(realized["detailBacking"], "the detail backing is prepared")
    local hits = 0
    for _, draw in ipairs(graphics.draws) do
      if draw.image == backing then
        hits = hits + 1
        Assert.equal(draw.y, case.y, "the detail backing translates along y by the generated offset")
      end
    end
    Assert.equal(hits, 1, "the detail backing draws exactly once")
  end
end

function T.sampled_frames_hold_prefix_and_loop_origins_with_visual_offsets()
  local family = sourcedFamily()
  local sprites = assert(family.sprites, "the family carries sprite roles")
  local animations = assert(sprites.animations, "sprite roles carry animations")
  animations.looped = {
    frames = {
      { visual = "syn-rootFocus", durationTicks = 2 },
      { visual = "syn-moveRowFocus", durationTicks = 1 },
      { visual = "syn-restrictedCancel", durationTicks = 1 },
    },
    loopFrom = 2,
    playback = "loop",
  }
  animations.single = {
    frames = {
      { visual = "syn-rootFocus", durationTicks = 1 },
      { visual = "syn-moveRowFocus", durationTicks = 1 },
    },
    loopFrom = 1,
    playback = "once",
  }
  family.visuals["syn-moveRowFocus"].offset = { x = 3, y = -2 }
  local cursors = assert(sprites.primaryCursor, "roles carry the primary cursor")
  local anchor = assert(assert(cursors.anchors, "the cursor carries anchors")[1], "the cursor covers slot 0")
  local record = facts()
  local function cursorAt(animation, tick)
    cursors.rootFocus = animation
    local graphics, realized = drawWithChrome(family, record, "info", "sub", { slot = 0, spriteTick = tick })
    local first = assert(realized["syn-rootFocus"], "the first frame visual is prepared")
    local second = assert(realized["syn-moveRowFocus"], "the second frame visual is prepared")
    local third = assert(realized["syn-restrictedCancel"], "the third frame visual is prepared")
    local found = {}
    for _, draw in ipairs(graphics.draws) do
      if draw.image == first or draw.image == second or draw.image == third then
        found[#found + 1] = draw
      end
    end
    Assert.equal(#found, 1, "one cursor frame draws at tick " .. tick)
    return found[1], first, second, third
  end
  local loopedFrames = { "first", "first", "second", "third", "second", "third" }
  for tick = 0, 5 do
    local draw, first, second, third = cursorAt("looped", tick)
    local want = loopedFrames[tick + 1]
    if want == "first" then
      Assert.equal(draw.image, first, "the looped prefix holds tick " .. tick)
      Assert.equal(draw.x, anchor.x, "unoffset frames keep their anchor at tick " .. tick)
      Assert.equal(draw.y, anchor.y, "unoffset frames keep their anchor at tick " .. tick)
    elseif want == "second" then
      Assert.equal(draw.image, second, "the looped cycle reaches its origin at tick " .. tick)
      Assert.equal(draw.x, anchor.x + 3, "frame visuals apply their compiled x offset")
      Assert.equal(draw.y, anchor.y - 2, "frame visuals apply their compiled y offset")
    else
      Assert.equal(draw.image, third, "the looped cycle advances past its origin at tick " .. tick)
      Assert.equal(draw.x, anchor.x, "unoffset frames keep their anchor at tick " .. tick)
      Assert.equal(draw.y, anchor.y, "unoffset frames keep their anchor at tick " .. tick)
    end
  end
  for _, tick in ipairs({ 0, 1, 9 }) do
    local draw, first, second = cursorAt("single", tick)
    if tick == 0 then
      Assert.equal(draw.image, first, "one-shot playback starts on its first frame")
    else
      Assert.equal(draw.image, second, "one-shot playback rests on its final frame")
    end
  end
  cursors.rootFocus = "leaf"
  local heldGraphics, heldRealized = drawWithChrome(family, record, "info", "sub", { slot = 0, spriteTick = 50 })
  local leafImage = assert(heldRealized["syn-leaf"], "the leaf frame visual is prepared")
  local leafHits = 0
  for _, draw in ipairs(heldGraphics.draws) do
    if draw.image == leafImage then
      leafHits = leafHits + 1
      Assert.equal(draw.x, anchor.x, "single-frame playbacks hold their anchor")
      Assert.equal(draw.y, anchor.y, "single-frame playbacks hold their anchor")
    end
  end
  Assert.equal(leafHits, 1, "single-frame playbacks draw once at any tick")
end

return { tests = T }
