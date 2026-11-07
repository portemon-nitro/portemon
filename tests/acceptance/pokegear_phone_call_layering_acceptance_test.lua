-- Call-layering contract: the phone contact list lives on the lower
-- controls surface in every phone state, while the live call name and
-- speech live only on the upper information surface. Browsing paints the
-- list below with the static upper plane above; a live call keeps that
-- same list below under dim with the native fast-forward sprite, shows
-- caller windows above, and restores the browse look when the call ends.
-- Synthetic catalog, real production controller plus the real phone
-- renderer through the published plan callbacks, recording (non-GPU)
-- host fakes; the scenarios stop before GPU rendering.

local Assert = require("tests.support.Assert")

local T = {
  metadata = {
    tags = { "pokegear", "phone", "d4" },
  },
  tests = {},
}

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

---@param path string
---@param width integer
---@param height integer
---@return table
local function visualRef(path, width, height)
  return { image = path, width = width, height = height, anchorX = 0, anchorY = 0 }
end

-- Synthetic companion family with a mother contact (choice-bearing
-- ordinary call) and two plain contacts, mirroring the published
-- manifest shape including every presentation plane the call-layering contract
-- observes: per-skin foreground/upper planes, panel cells, the sixteen
-- list and tooltip palette colors per skin, the compiled phone OBJ set,
-- and the shared list-menu tile strip beside its palette.
---@return table
local function fixtureManifest()
  local contacts = {
    {
      key = "custom.mom",
      family = "mother",
      sortWeight = 10,
      rematchWeekday = 6,
      rematchTime = 0,
      className = "fixture-class-mom",
    },
    { key = "custom.trainer-plain", family = "kurt", sortWeight = 20, className = "fixture-class-kurt" },
    { key = "custom.professor", family = "elm", sortWeight = 30, className = "fixture-class-elm" },
  }
  local order = { "custom.mom", "custom.trainer-plain", "custom.professor" }
  local phoneForeground, phoneUpper = {}, {}
  local phoneForegroundDim, phoneForegroundDimChoice, phoneDimShellForeground = {}, {}, {}
  local phoneListPalette, phoneListPaletteDim, phoneTooltipPalette, phoneWindowPalette = {}, {}, {}, {}
  for skin = 0, 5 do
    phoneListPalette[skin] = {}
    phoneListPaletteDim[skin] = {}
    phoneTooltipPalette[skin] = {}
    phoneWindowPalette[skin] = {}
    for index = 1, 16 do
      phoneListPalette[skin][index] =
        { r = (index * 15 + skin * 30) % 256, g = (index * 40) % 256, b = (skin * 45 + 20) % 256 }
      phoneListPaletteDim[skin][index] =
        { r = (index * 37 + skin * 11 + 90) % 256, g = (index * 19 + 130) % 256, b = (skin * 23 + 40) % 256 }
      phoneTooltipPalette[skin][index] =
        { r = (index * 29 + skin * 12) % 256, g = (index * 17 + 90) % 256, b = (skin * 31 + 140) % 256 }
      -- The call windows print through their own bank of the upper
      -- palette (windows[0,1] palette 1), so the fixture keeps it
      -- distinct from the list and tooltip banks.
      phoneWindowPalette[skin][index] =
        { r = (index * 41 + skin * 7 + 60) % 256, g = (index * 13 + 150) % 256, b = (skin * 53 + 200) % 256 }
    end
  end
  for skin = 0, 5 do
    phoneForeground[skin] = visualRef("assets/generated/pokegear/phone-foreground-skin-" .. skin .. ".png", 256, 192)
    phoneForegroundDim[skin] =
      visualRef("assets/generated/pokegear/phone-foreground-dim-skin-" .. skin .. ".png", 256, 192)
    phoneForegroundDimChoice[skin] =
      visualRef("assets/generated/pokegear/phone-foreground-dim-choice-skin-" .. skin .. ".png", 256, 192)
    phoneDimShellForeground[skin] =
      visualRef("assets/generated/pokegear/phone-dim-shell-foreground-skin-" .. skin .. ".png", 256, 192)
    phoneUpper[skin] = visualRef("assets/generated/pokegear/phone-upper-skin-" .. skin .. ".png", 256, 192)
  end
  local phonePanel = {
    closed = visualRef("assets/generated/pokegear/phone-panel-closed.png", 240, 48),
    open = visualRef("assets/generated/pokegear/phone-panel-open.png", 240, 48),
  }
  local phoneSpriteCounts = { 2, 2, 2, 2, 2, 2, 1, 1, 3 }
  local phoneSpriteWidths = { 16, 16, 16, 16, 16, 16, 32, 32, 240 }
  local phoneSpriteHeights = { 16, 16, 16, 16, 16, 16, 32, 32, 48 }
  -- Bright and dimmed call art repaint from their own staged images:
  -- the dim infix sits behind the sequence so both sets keep the
  -- producer's staged path shape per sequence.
  local function fixturePhoneSpriteSet(nameInfix)
    local sets = {}
    for sequence, frames in ipairs(phoneSpriteCounts) do
      local list = {}
      for frame = 1, frames do
        list[frame] = {
          image = "assets/generated/pokegear/phone-sprite-phone-" .. sequence .. nameInfix .. "-" .. frame .. ".png",
          width = phoneSpriteWidths[sequence],
          height = phoneSpriteHeights[sequence],
          anchorX = -math.floor(phoneSpriteWidths[sequence] / 2),
          anchorY = -math.floor(phoneSpriteHeights[sequence] / 2),
          duration = 1,
        }
      end
      sets[sequence] = { frames = list, playMode = "forward", loopStartFrameIdx = 0 }
    end
    return sets
  end
  local phoneSprites = fixturePhoneSpriteSet("")
  local phoneSpritesDim = fixturePhoneSpriteSet("-dim")
  local menuPalette = {}
  for index = 1, 16 do
    menuPalette[index] = { r = (index * 23) % 256, g = (index * 51 + 60) % 256, b = (index * 11 + 90) % 256 }
  end
  return {
    schema = "g4-pokegear-assets-v3",
    skins = { 0, 1, 2, 3, 4, 5 },
    shell = { foreground = visualRef("assets/generated/pokegear/shell-foreground-skin-0.png", 256, 192) },
    configure = { panel = visualRef("assets/generated/pokegear/configure-panel.png", 32, 32) },
    phone = {
      foreground = phoneForeground,
      foregroundDim = phoneForegroundDim,
      foregroundDimChoice = phoneForegroundDimChoice,
      dimShellForeground = phoneDimShellForeground,
      upper = phoneUpper,
      panel = phonePanel,
      listPalette = phoneListPalette,
      listPaletteDim = phoneListPaletteDim,
      tooltipPalette = phoneTooltipPalette,
      windowPalette = phoneWindowPalette,
      sprites = { phone = phoneSprites },
      spritesDim = { phone = phoneSpritesDim },
    },
    map = { base = visualRef("assets/generated/pokegear/map-base.png", 32, 32) },
    fly = {
      base = visualRef("assets/generated/pokegear/fly-base.png", 32, 32),
      menuTiles = visualRef("assets/generated/pokegear/fly-menu-tiles.png", 256, 16),
      menuPalette = menuPalette,
    },
    radio = { dial = visualRef("assets/generated/pokegear/radio-dial.png", 32, 32) },
    catalog = {
      contacts = contacts,
      contactOrder = order,
      callDefinitions = {},
      callTriggers = {},
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

-- The borrowed world behind the mother ordinary call: no savings choice
-- yet (so the opening branch owes its save/keep choice), local-map
-- selector facts (so the native script identity resolves), and the
-- savings write the choice commits.
---@return table
local function worldFixture()
  local flags = {}
  return {
    flags = flags,
    read = function(_, key)
      return flags[key]
    end,
    setMomSavingsChoice = function(_, choice)
      flags["mom.savings-choice"] = choice
      flags.savingsChoice = choice
    end,
    rematchReady = {},
    rematches = {},
    queryRematch = function()
      return nil
    end,
    nativeSelectorFacts = function()
      return {
        localMap = true,
        gaveRivalName = false,
        talkedAfterNamingRival = false,
        eggCallPending = false,
      }
    end,
    storyTier = 2,
    weekday = 6,
    timeOfDay = 0,
    teamsByTier = { [2] = { tier = 2, members = { { species = "custom.pidgeotto", level = 13 } } } },
    player = { x = 5, y = 7 },
  }
end

---@return table
local function instantAudio()
  local completed = true
  return {
    playDialing = function()
      completed = false
    end,
    isEffectWaitComplete = function()
      local done = completed
      completed = true
      return done
    end,
  }
end

---@return table
local function messageRefs()
  return {
    invitation = "custom.invitation",
    accept = "custom.accept",
    resolveLine = function()
      return { tokens = { { kind = "glyph", code = 1, text = "X", raw = { 1 } } } }
    end,
    resolvePhoneUiMessage = function(_, entryId)
      assert(type(entryId) == "number", "phone UI text resolves through its source bank entry")
      local text = "fixture-ui-271-" .. entryId
      return { text = text, tokens = { { kind = "glyph", code = 1, text = text, raw = { 1 } } } }
    end,
  }
end

---@return string[]
local function fixtureTooltips()
  return {
    "fixture-tip-20",
    "fixture-tip-21",
    "fixture-tip-22",
    "fixture-tip-23",
    "fixture-tip-24",
    "fixture-tip-25",
    "fixture-tip-26",
    "fixture-tip-27",
  }
end

---@return string[]
local function fixtureMenuLabels()
  return {
    "fixture-menu-0",
    "fixture-menu-1",
    "fixture-menu-2",
    "fixture-menu-3",
    "fixture-menu-4",
    "fixture-menu-5",
    "fixture-menu-6",
    "fixture-menu-7",
  }
end

-- Opens the real card controller on a fresh companion state with every
-- catalogued contact registered, through the validated synthetic
-- record. Callers place menu calls through semantic confirm input.
---@return table controller
---@return table record
local function openMenuController()
  local PhoneController = requireFeature(
    "game.hgss.src.pokegear.PhoneController",
    "the phone card has no controller yet: the call layering has no menu entry to split across panes"
  )
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local record = PokegearAssetSchema.validate(fixtureManifest())
  Assert.notNil(record, "the synthetic contact catalog must validate through the asset schema")
  assert(record ~= nil, "synthetic catalog validated above")
  local PokegearState = require("libs.hgss.src.save.PokegearState")
  local PokegearRandom = require("game.hgss.src.pokegear.PokegearRandom")
  local state = PokegearState.new({ seed = 2024 }, { catalog = record.catalog })
  for _, contact in ipairs(record.catalog.contacts) do
    state:registerContact(contact.key)
  end
  state:setContactOrder(record.catalog.contactOrder)
  local world = worldFixture()
  world.flags["mom.savings-choice"] = false
  local controller = PhoneController.new({
    state = state,
    catalog = record.catalog,
    assets = record,
    messages = messageRefs(),
    world = world,
    audio = instantAudio(),
    random = PokegearRandom.new(2024),
    tooltips = fixtureTooltips(),
    menuLabels = fixtureMenuLabels(),
  })
  return controller, record
end

-- Walks the real list UI into a menu call on the first (mother)
-- contact: confirm opens its action menu, confirm chooses Call.
---@param controller table
local function placeMenuCall(controller)
  Assert.equal(
    controller:status().view.list.selected,
    0,
    "the menu list opens with the mother contact selected"
  )
  controller:updateFixed({ { type = "confirm" } })
  local menu = assert(controller:status().view, "the menu state exports its view").contextMenu
  Assert.notNil(menu, "confirming the contact opens its action menu")
  controller:updateFixed({ { type = "confirm" } })
  Assert.notNil(controller:status().view.call, "choosing Call starts the live conversation")
end

-- Recording (non-GPU) render collaborators: every graphics call is
-- captured in the log, every prepared image is a recording stub lease,
-- and text primitives record their lines, palette use, and which font
-- role drew them (names through the name font, classes and call text
-- through the class font). Nothing here touches love or allocates GPU
-- resources.
---@return table resources
---@return table log
local function recordingResources()
  local log = {}
  local current = { 1, 1, 1, 1 }
  local graphics = {}
  function graphics.push()
    log[#log + 1] = { op = "push" }
  end
  function graphics.pop()
    log[#log + 1] = { op = "pop" }
  end
  function graphics.origin()
  end
  function graphics.translate(_, _)
  end
  function graphics.scale(_, _)
  end
  function graphics.intersectScissor(_, _, _, _)
  end
  function graphics.getScissor()
    return 0, 0, 256, 192
  end
  function graphics.transformPoint(x, y)
    return x, y
  end
  function graphics.quad()
    return {}
  end
  function graphics.newQuad()
    return {}
  end
  function graphics.setColor(r, g, b, a)
    current = { r, g, b, a }
  end
  function graphics.rectangle(mode, x, y, width, height)
    log[#log + 1] = { op = "rect", mode = mode, color = { current[1], current[2], current[3], current[4] }, x = x, y = y, width = width, height = height }
  end
  local function stubLease(path)
    local lease = { image = { getDimensions = function()
      return 256, 16
    end }, path = path }
    function lease:draw(_, x, y)
      log[#log + 1] = { op = "image", path = path, x = x, y = y }
    end
    function lease:drawQuad(_, _, dx, dy)
      log[#log + 1] = { op = "quad", path = path, x = dx, y = dy }
    end
    return lease
  end
  local images = setmetatable({}, {
    __index = function(store, path)
      local lease = stubLease(path)
      store[path] = lease
      return lease
    end,
  })
  local function textRenderer(role)
    return {
      role = role,
      drawText = function(self, line, x, y)
        log[#log + 1] = { op = "text", plain = true, role = self.role, line = tostring(line), x = x, y = y }
      end,
      drawTextWithPalette = function(self, line, x, y, colors)
        log[#log + 1] = { op = "text", plain = false, role = self.role, line = tostring(line), x = x, y = y, colors = colors }
      end,
      textWidth = function(_, line)
        return #tostring(line) * 8
      end,
    }
  end
  return {
    graphics = graphics,
    images = images,
    textRenderer = textRenderer("class"),
    phoneNameTextRenderer = textRenderer("name"),
  },
    log
end

---@param left number
---@param top number
---@param width number
---@param height number
---@return table
local function rectOf(left, top, width, height)
  return { x0 = left, y0 = top, x1 = left + width, y1 = top + height }
end

---@param record table
---@param area table
---@return boolean
local function textHits(record, area)
  return record.x >= area.x0 and record.x < area.x1 and record.y >= area.y0 and record.y < area.y1
end

-- Source window geometry in pixels: the SUB_2 speech window (tiles
-- x2/y19 27x4) and name window (tiles x4/y16 9x2), and the MAIN_3 six
-- 24px contact rows riding the scrolled layer at surface y8 inside the
-- plane frame interior.
local SPEECH_RECT = rectOf(16, 152, 216, 32)
local NAME_RECT = rectOf(32, 128, 72, 16)
local LIST_BAND = rectOf(13, 8, 211, 144)

-- Paints one pane through the controller's published plan callbacks: the
-- lower controls surface through render, the upper information surface
-- through renderInformation, each with the same published status the
-- shell hands its children.
---@param controller table
---@param which string "lower" or "upper"
---@return table log the recorded paint operations
local function paintPane(controller, which)
  local status = controller:status()
  local plan = assert(status.presentation, "the phone controller publishes its presentation plan")
  local resources, log = recordingResources()
  if which == "lower" then
    assert(type(plan.render) == "function", "the published plan carries its lower render callback")
    plan.render(resources, status, plan)
  else
    assert(type(plan.renderInformation) == "function", "the published plan carries its upper render callback")
    plan.renderInformation(resources, status, plan)
  end
  return log
end

-- Contact rows paint exact 216x24 band fills at x8 (the call windows use
-- different geometry), while row text sits inside the rows but outside the
-- caller windows; both counters stay silent for call-window paints so a
-- misplaced call surface cannot masquerade as the contact list.
---@param log table
---@return integer contact row band fills
local function listBandFills(log)
  local count = 0
  for _, record in ipairs(log) do
    if record.op == "rect" and record.mode == "fill" and record.x == 8 and record.width == 216 and record.height == 24 then
      count = count + 1
    end
  end
  return count
end

---@param log table
---@return integer palette text draws inside the contact rows
local function listBandText(log)
  local count = 0
  for _, record in ipairs(log) do
    if
      record.op == "text"
      and record.plain == false
      and textHits(record, LIST_BAND)
      and not textHits(record, SPEECH_RECT)
      and not textHits(record, NAME_RECT)
    then
      count = count + 1
    end
  end
  return count
end

---@param controller table
---@return table? the compiled phone sprite sequences by id
local function contentSprites(controller)
  local status = controller:status()
  local plan = assert(status.presentation, "the phone controller publishes its presentation plan")
  local content = assert(plan.content, "the published plan carries its payload")
  local sprites = content.sprites --[[@as table<string, unknown>?]]
  if type(sprites) ~= "table" then
    return nil
  end
  return (sprites --[[@as table<string, table>]]).phone
end

-- Whether a recorded sprite paint lands on the source position through
-- one of the sequence's compiled frames: draw calls carry the anchor
-- offset, so each frame admits exactly one expected paint position.
---@param record table
---@param spriteSet table
---@param sourceX number
---@param sourceY number
---@return boolean
local function spriteDrawAtSource(record, spriteSet, sourceX, sourceY)
  local sequence = spriteSet[9] --[[@as table<string, unknown>?]]
  if type(sequence) ~= "table" then
    return false
  end
  for _, frame in ipairs((sequence --[[@as table<string, table>]]).frames) do
    if record.x == sourceX + frame.anchorX and record.y == sourceY + frame.anchorY then
      return true
    end
  end
  return false
end

---@param log table
---@return table<string, boolean> palette text lines by content
local function paletteLines(log)
  local lines = {}
  for _, record in ipairs(log) do
    if record.op == "text" and record.plain == false then
      lines[record.line] = true
    end
  end
  return lines
end

-- Call layering through one controller: browse paints its contact list
-- on the lower surface only, a live call keeps that same list below
-- under dim with the native fast-forward sprite while the conversation
-- moves above, and ending the call restores the browse look on both
-- surfaces.
function T.tests.call_layering_keeps_list_below_and_speech_above()
  local controller = openMenuController()
  local view = assert(controller:status().view, "the browse state exports its view")
  Assert.notNil(view.list, "the browse state carries its contact list projection")
  Assert.equal(#assert(view.list.rows, "the browse list carries its rows"), 3, "three contacts show three rows")

  local content = assert(controller:status().presentation, "the browse state publishes its plan").content
  Assert.isNil(content.callList, "the plan carries no second list projection beside the view")

  local browseLower = paintPane(controller, "lower")
  Assert.isTrue(listBandFills(browseLower) > 0, "the lower surface paints the contact row bands")
  local lowerNames, lowerClasses = 0, 0
  local browseLabels = {}
  for _, record in ipairs(browseLower) do
    if record.op == "text" and record.plain == false and textHits(record, LIST_BAND) then
      browseLabels[record.line] = true
      if record.role == "name" then
        lowerNames = lowerNames + 1
      elseif record.role == "class" then
        lowerClasses = lowerClasses + 1
      end
    end
  end
  Assert.equal(lowerNames, 3, "the lower surface prints every contact name through the name font")
  Assert.equal(lowerClasses, 3, "the lower surface prints every contact class through the class font")

  local browseUpper = paintPane(controller, "upper")
  Assert.equal(listBandFills(browseUpper), 0, "the upper surface never paints contact row bands")
  Assert.equal(listBandText(browseUpper), 0, "the upper surface never paints contact palette text")

  placeMenuCall(controller)
  local call = assert(controller:status().view.call, "the live call keeps its conversation projection")
  Assert.isTrue(call.dim == true, "the live call publishes its dimmed-screen state")
  local lower = paintPane(controller, "lower")
  Assert.isTrue(listBandFills(lower) > 0, "the lower surface keeps the contact row bands during the call")
  local lowerLines = paletteLines(lower)
  for line in pairs(browseLabels) do
    Assert.isTrue(lowerLines[line] == true, "the lower surface keeps the contact label during the call: " .. line)
  end
  -- The sprite set draws at its source position plus the compiled frame
  -- anchor, so the expected paint position derives from the published
  -- frames beside the source position they must preserve.
  local spriteSet = assert(contentSprites(controller), "the call plan resolves its sprite set")
  local spritePaints = 0
  for _, record in ipairs(lower) do
    if
      (record.op == "image" or record.op == "quad")
      and type(record.path) == "string"
      and record.path:find("phone-sprite-phone-9-", 1, true) ~= nil
    then
      spritePaints = spritePaints + 1
      Assert.isTrue(
        spriteDrawAtSource(record, spriteSet, 128, 160),
        "the fast-forward sprite paints at its source position with its compiled anchor"
      )
    end
  end
  Assert.isTrue(spritePaints > 0, "the lower surface paints the native fast-forward sprite during the call")

  local upper = paintPane(controller, "upper")
  Assert.equal(listBandFills(upper), 0, "the upper surface never paints contact row bands during the call")
  -- The caller name matches its contact label textually, so the
  -- no-contacts check is positional: no palette text inside the row
  -- band outside the caller windows, which the row-text counter
  -- already excludes.
  Assert.equal(listBandText(upper), 0, "the upper surface never paints contact row text during the call")
  local callText = 0
  for _, record in ipairs(upper) do
    if record.op == "text" and (textHits(record, SPEECH_RECT) or textHits(record, NAME_RECT)) then
      callText = callText + 1
    end
  end
  Assert.isTrue(callText > 0, "the upper surface paints the caller name and speech during the call")

  local content = assert(controller:status().presentation, "the live call publishes its plan").content
  Assert.notNil(content.listPaletteDim, "the call plan carries its dimmed list palette")
  Assert.notNil(content.foregroundDim, "the call plan carries its dimmed lower plane")
  Assert.notNil(content.dimShellForeground, "the call plan carries its dimmed strip plane")
  Assert.notNil(content.spritesDim, "the call plan carries its dimmed sprite set")

  -- A menu cancellation stages the normal hangup instead of cutting
  -- it: the call stays live behind its staged timer, and empty ticks
  -- settle it back to the browse look on both surfaces.
  controller:updateFixed({ { type = "cancel" } })
  Assert.notNil(controller:status().view.call, "hanging up stages through its timer, not at once")
  for _ = 1, 48 do
    if controller:status().view.call == nil then
      break
    end
    controller:updateFixed({})
    if controller:status().view.call == nil then
      break
    end
    controller:updateFixed({ { type = "advance" } })
  end
  Assert.isNil(controller:status().view.call, "the settled hangup clears the conversation projection")
  local restoredLower = paintPane(controller, "lower")
  Assert.isTrue(listBandFills(restoredLower) > 0, "the lower surface keeps the list after the call")
  local restoredUpper = paintPane(controller, "upper")
  Assert.equal(listBandFills(restoredUpper), 0, "the upper surface drops the call windows after the call")
  Assert.equal(listBandText(restoredUpper), 0, "the upper surface paints no row text after the call")
  local leaked = 0
  for _, record in ipairs(restoredLower) do
    if record.op == "text" and record.plain == false and textHits(record, SPEECH_RECT) then
      leaked = leaked + 1
    end
  end
  Assert.equal(leaked, 0, "no call window leaks onto the lower surface")
  local restoredText = 0
  for _, record in ipairs(restoredUpper) do
    if record.op == "text" then
      restoredText = restoredText + 1
    end
  end
  Assert.equal(restoredText, 0, "the upper surface returns to its text-free static plane after the call")
  controller:dispose()
end

return T
