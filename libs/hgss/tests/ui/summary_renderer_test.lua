-- Native Summary pane contracts over hand-built family records: window
-- palette roles and clipping, dynamic bar tiles, centered picture
-- transforms with the palette operation, detail backing wrap, state
-- sprite visibility and draw order, and draw-time acquisition silence.
-- Geometry here is test-local and minimal; ROM-derived expectations live
-- in the graphics suite.

local Assert = require("tests.support.Assert")
local FakeGraphics = require("tests.support.FakeGraphics")
local SummaryRenderer = require("libs.hgss.src.ui.SummaryRenderer")

local T = {}

local function manifest()
  return {
    groups = {
      info = { main = { map = 1 }, sub = { normal = 2, restricted = 3 } },
      skills = { main = { map = 4 }, sub = { normal = 5, restricted = 6 } },
      performance = { main = { map = 7, locked = 8 }, sub = { normal = 9 } },
    },
    windows = {
      mainA = { pane = "main", rect = { x = 8, y = 8, width = 240, height = 32 }, palette = 13 },
      mainB = { pane = "main", rect = { x = 8, y = 48, width = 240, height = 64 }, palette = 13 },
      subA = { pane = "sub", rect = { x = 8, y = 8, width = 240, height = 32 }, palette = 13 },
      subB = { pane = "sub", rect = { x = 8, y = 48, width = 240, height = 64 }, palette = 13 },
      subC = { pane = "sub", rect = { x = 8, y = 120, width = 240, height = 64 }, palette = 13 },
    },
    visuals = {},
    sprites = {},
    hitboxes = { touch = {} },
    text = {
      labels = {},
      templates = {},
      roles = {
        slot13 = {
          foreground = { r = 255, g = 255, b = 255, a = 255 },
          shadow = { r = 107, g = 107, b = 107, a = 255 },
          background = { r = 0, g = 0, b = 0, a = 0 },
        },
      },
    },
    palettes = { banks = {} },
    bars = {
      hp = {
        length = 48,
        colors = {
          high = { r = 0, g = 255, b = 0 },
          low = { r = 255, g = 255, b = 0 },
          critical = { r = 255, g = 0, b = 0 },
        },
        empty = { image = "hp-empty.png", width = 8, height = 8 },
        full = { image = "hp-full.png", width = 8, height = 8 },
      },
      exp = {
        length = 56,
        colors = {
          high = { r = 0, g = 0, b = 255 },
          low = { r = 0, g = 0, b = 255 },
          critical = { r = 0, g = 0, b = 255 },
        },
        empty = { image = "exp-empty.png", width = 8, height = 8 },
        full = { image = "exp-full.png", width = 8, height = 8 },
      },
    },
    pictures = {
      MON = {
        portrait = "MON/f0/male/plain",
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
    },
    ribbons = { entries = {}, initialSpecialDescriptions = {}, descriptionChoices = { base = 1, slots = {} } },
    performance = { forms = {}, natureModifiers = {}, zeroAprijuice = { power = 0, stamina = 0, skill = 0, jump = 0, speed = 0 } },
    dexNumbers = {},
    memo = { conditions = {}, months = {}, landmarks = {}, characteristics = {}, flavors = {}, eggWatch = {} },
    sounds = {},
    transitions = {},
  }
end

local function moves()
  return {
    { kind = "move", moveSlot = 0, name = "TACKLE", type = "NORMAL", category = "physical", powerText = "35", accuracyText = "95", description = "A full-body charge.", pp = 35, ppMax = 35 },
    { kind = "move", moveSlot = 1, name = "GROWL", type = "NORMAL", category = "other", powerText = "—", accuracyText = "100", description = "Growls.", pp = 40, ppMax = 40 },
    { kind = "empty", moveSlot = 2 },
    { kind = "empty", moveSlot = 3 },
  }
end

local function facts(overrides)
  local record = {
    revision = 7,
    contextKey = "test-context",
    slot = 0,
    slotCount = 1,
    roster = { { slot = 0, isEgg = false, iconKey = "MON/f0" } },
    isEgg = false,
    identity = { species = "MON", form = 0, displayName = "MON", gender = "male", shiny = false },
    pictureKey = "MON",
    iconKey = "MON/f0",
    memo = { condition = "t", blocks = { { line = 1, runs = { { text = "met somewhere" } } } } },
    info = {
      dexNumber = 1,
      dexText = "001",
      otIdText = "12345",
      expToNext = 20,
      expBar = { length = 28 },
      heldItem = "NONE",
      ball = "POKE_BALL",
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
      ability = "OVERGROW",
      abilityName = "Overgrow",
      abilityDescription = "Boosts grass.",
      nature = { up = "attack", down = "defense" },
      hpBar = { length = 48, color = "high" },
    },
    moves = moves(),
    ribbons = {},
    performance = nil,
    indicators = {
      status = "OK",
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

---@param status table<string, unknown>?
local function openStatus(record, group, status)
  status = status or {}
  status.open = true
  status.mode = "summary"
  status.group = group
  status.phase = status.phase or "root"
  status.slot = 0
  status.facts = record
  status.pictureEpoch = 0
  status.picture = status.picture or {
    sampleIndex = 1,
    frameIndex = 0,
    offsetX = 0,
    offsetY = 0,
    scaleX = 1,
    scaleY = 1,
    rotationTurns = 0,
    visible = true,
  }
  return status
end

local function textDouble(calls)
  local text = {}
  function text:drawLineWithPalette(tokens, x, y, palette)
    assert(type(palette) == "table", "summary text draws through palette roles")
    assert(type(palette.foreground) == "table", "palette roles carry foreground")
    assert(type(palette.shadow) == "table", "palette roles carry shadow")
    assert(type(palette.background) == "table", "palette roles carry background")
    calls[#calls + 1] = { kind = "palette", tokens = tokens, x = x, y = y, palette = palette }
  end
  function text:drawLineWithColorVariants(tokens, x, y, variants, background)
    calls[#calls + 1] = { kind = "variants", tokens = tokens, x = x, y = y }
  end
  function text:textWidth(value)
    return #value * 6
  end
  text.fontDef = { charmap = {} }
  return text
end

local function portraitDouble(calls, image)
  local portraits = {}
  function portraits:image(selector)
    calls.images[#calls.images + 1] = selector
    return image
  end
  function portraits:quadFor(selector, frameIndex)
    calls.quads[#calls.quads + 1] = { selector = selector, frameIndex = frameIndex }
    return { selector = selector, frameIndex = frameIndex }
  end
  function portraits:dimensions(selector)
    calls.dims[#calls.dims + 1] = selector
    return { width = 80, height = 80 }
  end
  return portraits
end

local function composition()
  local graphics = FakeGraphics.new({})
  local calls = { text = {}, images = {}, quads = {}, dims = {} }
  local text = textDouble(calls.text)
  local image = { id = "portrait-image" }
  local portraits = portraitDouble(calls, image)
  local renderer = SummaryRenderer.new({ graphics = graphics, text = text })
  return graphics, calls, text, portraits, renderer
end

-- Compares a drawn triple against its compiled role under the consumer
-- boundary rule: byte channels pass through, byte alpha arrives
-- normalized to the unit range, absent alpha stays absent.
---@param drawn table<string, unknown>
---@param role table<string, unknown>
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

local function bundle(family, text, portraits, extra)
  local assets = { manifest = family, portraits = portraits, text = text }
  if extra ~= nil then
    for key, value in pairs(extra) do
      assets[key] = value
    end
  end
  return assets
end

function T.text_uses_window_roles_and_stays_inside_windows()
  local graphics, calls, text, portraits, renderer = composition()
  local family = manifest()
  renderer:drawPane(openStatus(facts(), "info"), "sub", bundle(family, text, portraits))
  Assert.isTrue(#calls.text > 0, "the info pane draws role text")
  local windows = {}
  for _, window in pairs(family.windows) do
    if window.pane == "sub" then
      windows[#windows + 1] = window
    end
  end
  for _, call in ipairs(calls.text) do
    Assert.equal(call.kind, "palette", "role text draws through palette roles")
    Assert.isTrue(
      roleMatches(call.palette, family.text.roles.slot13),
      "calls carry the window palette role resolved through its text role"
    )
    local inside = false
    for _, window in ipairs(windows) do
      local rect = window.rect
      if call.x >= rect.x and call.x < rect.x + rect.width and call.y >= rect.y and call.y < rect.y + rect.height then
        inside = true
      end
    end
    Assert.isTrue(inside, "every text call starts inside its source window")
  end
  Assert.equal(#graphics.images, 0, "draw creates no images")
  Assert.equal(#graphics.shaders, 0, "draw creates no shaders")
end

function T.memo_lines_follow_their_authored_positions()
  local graphics, calls, text, portraits, renderer = composition()
  local family = manifest()
  local record = facts({ memo = { condition = "t", blocks = {
    { line = 1, runs = { { text = "first" } } },
    { line = 3, runs = { { text = "third" } } },
  } } })
  renderer:drawPane(openStatus(record, "info"), "main", bundle(family, text, portraits))
  Assert.equal(#calls.text, 2, "memo blocks draw once each")
  local first, third = calls.text[1], calls.text[2]
  Assert.equal(third.y - first.y, 32, "memo lines keep their (line-1)*16 spacing")
  Assert.equal(first.x, third.x, "memo lines share their source padding")
end

function T.hp_bar_tiles_follow_compiled_lengths_and_zero()
  local graphics, calls, text, portraits, renderer = composition()
  local family = manifest()
  local emptyImage, fullImage = { id = "empty" }, { id = "full" }
  local assets = bundle(family, text, portraits, {
    visuals = { ["hp-empty"] = emptyImage, ["hp-full"] = fullImage },
  })
  renderer:drawPane(openStatus(facts(), "info"), "sub", assets)
  local full, empty = 0, 0
  for _, draw in ipairs(graphics.draws) do
    if draw.image == fullImage then
      full = full + 1
    elseif draw.image == emptyImage then
      empty = empty + 1
    end
  end
  Assert.equal(full, 6, "full health fills six tiles")
  Assert.equal(empty, 0, "full health leaves no empty tile")
  local faint = facts({ skills = {
    level = 5, currentHp = 0, maxHp = 20, attack = 11, defense = 10, speed = 9,
    specialAttack = 12, specialDefense = 11, ability = "OVERGROW", abilityName = "Overgrow",
    abilityDescription = "Boosts grass.", nature = { up = "attack", down = "defense" },
    hpBar = { length = 0, color = "critical" },
  } })
  local graphics2 = FakeGraphics.new({})
  local renderer2 = SummaryRenderer.new({ graphics = graphics2, text = text })
  renderer2:drawPane(openStatus(faint, "info"), "sub", bundle(family, text, portraits, {
    visuals = { ["hp-empty"] = emptyImage, ["hp-full"] = fullImage },
  }))
  local full2, empty2 = 0, 0
  for _, draw in ipairs(graphics2.draws) do
    if draw.image == fullImage then
      full2 = full2 + 1
    elseif draw.image == emptyImage then
      empty2 = empty2 + 1
    end
  end
  Assert.equal(full2, 0, "fainted health fills no tile")
  Assert.equal(empty2, 6, "fainted health empties every tile")
end

-- The source tint rule reads filled pixels against the track length,
-- never filled 8-pixel tiles: 25 of 48 pixels fills only three tiles
-- yet reads green, 10 of 48 reads yellow, and 5 of 48 reads red.
function T.hp_bar_tints_follow_filled_pixels_not_tiles()
  local function barSkills(pixels)
    return {
      level = 5, currentHp = 20, maxHp = 20, attack = 11, defense = 10, speed = 9,
      specialAttack = 12, specialDefense = 11, ability = "OVERGROW", abilityName = "Overgrow",
      abilityDescription = "Boosts grass.", nature = { up = "attack", down = "defense" },
      hpBar = { length = pixels, color = "high" },
    }
  end
  local function tintOf(pixels)
    local graphics, _, text, portraits, renderer = composition()
    local family = manifest()
    local emptyImage, fullImage = { id = "empty" }, { id = "full" }
    renderer:drawPane(openStatus(facts({ skills = barSkills(pixels) }), "info"), "sub", bundle(
      family,
      text,
      portraits,
      { visuals = { ["hp-empty"] = emptyImage, ["hp-full"] = fullImage } }
    ))
    local tints = {}
    for _, draw in ipairs(graphics.draws) do
      if draw.image == fullImage then
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
  local graphics, calls, text, portraits, renderer = composition()
  local family = manifest()
  local status = openStatus(facts(), "info", {
    picture = {
      sampleIndex = 1, frameIndex = 1, offsetX = 2, offsetY = -3,
      scaleX = 2, scaleY = 0.5, rotationTurns = 0.25, visible = true,
    },
  })
  renderer:drawPane(status, "main", bundle(family, text, portraits))
  local pictureDraw = nil
  for _, draw in ipairs(graphics.draws) do
    if draw.image ~= nil and draw.image.id == "portrait-image" then
      pictureDraw = draw
    end
  end
  Assert.notNil(pictureDraw, "the main pane draws its picture")
  Assert.equal(pictureDraw.x, 210, "the frame centers on 208 plus offsets")
  Assert.equal(pictureDraw.y, 101, "the frame centers on 104 plus offsets")
  Assert.equal(pictureDraw.sx, 2, "horizontal scale applies")
  Assert.equal(pictureDraw.sy, 0.5, "vertical scale applies")
  Assert.isTrue(
    math.abs(pictureDraw.rotation - math.pi / 2) < 1e-9,
    "rotation turns convert to radians"
  )
  Assert.deepEqual(calls.quads[1], { selector = "MON/f0/male/plain", frameIndex = 2 }, "frames address one-based samples")
end

function T.hidden_pictures_draw_nothing()
  local graphics, _, text, portraits, renderer = composition()
  local family = manifest()
  local status = openStatus(facts(), "info", {
    picture = {
      sampleIndex = 1, frameIndex = 0, offsetX = 0, offsetY = 0,
      scaleX = 1, scaleY = 1, rotationTurns = 0, visible = false,
    },
  })
  renderer:drawPane(status, "main", bundle(family, text, portraits))
  for _, draw in ipairs(graphics.draws) do
    Assert.isTrue(draw.image == nil or draw.image.id ~= "portrait-image", "hidden pictures draw no pixels")
  end
end

function T.palette_blends_send_source_uniforms_and_noop_draws_plain()
  local graphics, _, text, portraits, renderer = composition()
  local family = manifest()
  local shader = { sends = {} }
  function shader:send(name, value)
    self.sends[#self.sends + 1] = { name = name, value = value }
  end
  local record = facts()
  local status = openStatus(record, "info", {
    picture = {
      sampleIndex = 1, frameIndex = 0, offsetX = 0, offsetY = 0,
      scaleX = 1, scaleY = 1, rotationTurns = 0, visible = true,
      paletteBlend = { target = { r = 31, g = 0, b = 0 }, coefficient = 8 },
    },
  })
  renderer:drawPane(status, "main", bundle(family, text, portraits, { shader = shader }))
  local target, coefficient = nil, nil
  for _, send in ipairs(shader.sends) do
    if send.name == "u_target" then
      target = send.value
    elseif send.name == "u_coefficient" then
      coefficient = send.value
    end
  end
  Assert.deepEqual(target, { 31, 0, 0 }, "blends carry the 5-bit target")
  Assert.equal(coefficient, 8, "blends carry the source coefficient")
  local graphics2 = FakeGraphics.new({})
  local renderer2 = SummaryRenderer.new({ graphics = graphics2, text = text })
  local ok = pcall(renderer2.drawPane, renderer2, openStatus(record, "info"), "main", bundle(family, text, portraits))
  Assert.isTrue(ok, "no-op blends draw without a shader")
end

function T.move_backing_wraps_across_transition_ticks()
  local _, _, text, portraits, renderer = composition()
  local family = manifest()
  local backing = { id = "backing" }
  local assets = bundle(family, text, portraits, { visuals = { moveBacking = backing } })
  local record = facts()
  local function drawAt(ticksLeft)
    local inner = FakeGraphics.new({})
    local innerRenderer = SummaryRenderer.new({ graphics = inner, text = text })
    local status = openStatus(record, "skills")
    status.phase = "move_detail"
    status.moveSlot = 0
    status.transition = { phase = "move_detail", ticksLeft = ticksLeft }
    innerRenderer:drawPane(status, "sub", assets)
    for _, draw in ipairs(inner.draws) do
      if draw.image == backing then
        return draw.x
      end
    end
    return nil
  end
  local first = drawAt(2)
  local second = drawAt(1)
  Assert.notNil(first, "detail draws its backing")
  Assert.notNil(second, "detail draws its backing across ticks")
  Assert.isTrue(first ~= second, "transition ticks scroll the backing instead of stretching it")
end

function T.state_sprites_follow_earned_visibility_in_source_order()
  local graphics, _, text, portraits, renderer = composition()
  local family = manifest()
  local leafImage = { id = "leaf" }
  local partyManifest = {
    shinyLeaves = {
      anchors = { { x = 10, y = 10 }, { x = 20, y = 10 }, { x = 30, y = 10 }, { x = 40, y = 10 }, { x = 50, y = 10 } },
      crownAnchor = { x = 10, y = 10 },
      leaves = { frames = { { image = "leaf.png", width = 8, height = 8 } } },
      crown = { frames = { { image = "crown.png", width = 8, height = 8 } } },
    },
  }
  local assets = bundle(family, text, portraits, {
    partyManifest = partyManifest,
    badgeImage = function(_)
      return leafImage
    end,
  })
  local record = facts({ indicators = {
    status = "OK", pokerus = "none", markings = { false, false, false, false, false, false },
    leaves = { true, false, true, false, false }, crown = false, shiny = false,
  } })
  renderer:drawPane(openStatus(record, "info"), "sub", assets)
  local badgeDraws = {}
  for _, draw in ipairs(graphics.draws) do
    if draw.image == leafImage then
      badgeDraws[#badgeDraws + 1] = draw
    end
  end
  Assert.equal(#badgeDraws, 2, "earned leaves draw once each")
  Assert.equal(badgeDraws[1].x, 10, "badges use their source anchors")
  Assert.equal(badgeDraws[2].x, 30, "badges keep source order")
end

function T.closed_statuses_draw_nothing()
  local graphics, _, text, portraits, renderer = composition()
  renderer:drawPane({ open = false }, "main", bundle(manifest(), text, portraits))
  Assert.equal(#graphics.draws + #graphics.rectangles, 0, "closed panes leave no output")
end

return { tests = T }
