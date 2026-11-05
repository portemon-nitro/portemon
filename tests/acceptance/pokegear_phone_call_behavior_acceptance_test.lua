-- Call-behavior contract: starting a call publishes the source dim
-- state plus the caller-name content for windows[1] (colors 1,2,0) and
-- exiting clears it; hangup plays staged click lines into the speech
-- projection with the source tones/timers (never a single tone); the
-- fast-forward hitbox geometry is published and live for the whole
-- call; in-call choice menus answer taps on options; and view.call
-- carries no choiceCursor field (the controller cursor still drives
-- view.callMenu.cursor). Synthetic catalog, real production
-- PhoneController plus the real PhoneCall engine, recording (non-GPU)
-- audio fakes; the scenarios stop before GPU rendering and stay red
-- until the call behavior lands.

local Assert = require("tests.support.Assert")

local T = {
  metadata = {
    tags = { "pokegear", "phone", "d5" },
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
-- ordinary call) and a service contact, mirroring the published
-- manifest shape the call-layering scenarios established.
---@return table
local function fixtureManifest()
  local contacts = {
    {
      key = "custom.mom",
      family = "mother",
      sortWeight = 10,
      rematchWeekday = 6,
      rematchTime = 0,
    },
    { key = "custom.trainer-plain", family = "kurt", sortWeight = 20 },
  }
  local order = { "custom.mom", "custom.trainer-plain" }
  local phoneForeground, phoneUpper = {}, {}
  local phoneListPalette, phoneTooltipPalette = {}, {}
  for skin = 0, 5 do
    phoneListPalette[skin] = {}
    phoneTooltipPalette[skin] = {}
    for index = 1, 16 do
      phoneListPalette[skin][index] =
        { r = (index * 15 + skin * 30) % 256, g = (index * 40) % 256, b = (skin * 45 + 20) % 256 }
      phoneTooltipPalette[skin][index] =
        { r = (index * 29 + skin * 12) % 256, g = (index * 17 + 90) % 256, b = (skin * 31 + 140) % 256 }
    end
  end
  for skin = 0, 5 do
    phoneForeground[skin] = visualRef("assets/generated/pokegear/phone-foreground-skin-" .. skin .. ".png", 256, 192)
    phoneUpper[skin] = visualRef("assets/generated/pokegear/phone-upper-skin-" .. skin .. ".png", 256, 192)
  end
  local phonePanel = {
    closed = visualRef("assets/generated/pokegear/phone-panel-closed.png", 240, 48),
    open = visualRef("assets/generated/pokegear/phone-panel-open.png", 240, 48),
  }
  local phoneSpriteCounts = { 2, 2, 2, 2, 2, 2, 1, 1, 3 }
  local phoneSpriteWidths = { 16, 16, 16, 16, 16, 16, 32, 32, 240 }
  local phoneSpriteHeights = { 16, 16, 16, 16, 16, 16, 32, 32, 48 }
  local phoneSprites = {}
  for sequence, frames in ipairs(phoneSpriteCounts) do
    local list = {}
    for frame = 1, frames do
      list[frame] = {
        image = "assets/generated/pokegear/phone-sprite-phone-" .. sequence .. "-" .. frame .. ".png",
        width = phoneSpriteWidths[sequence],
        height = phoneSpriteHeights[sequence],
        anchorX = -math.floor(phoneSpriteWidths[sequence] / 2),
        anchorY = -math.floor(phoneSpriteHeights[sequence] / 2),
        duration = 1,
      }
    end
    phoneSprites[sequence] = { frames = list, playMode = "forward", loopStartFrameIdx = 0 }
  end
  local menuPalette = {}
  for index = 1, 16 do
    menuPalette[index] = { r = (index * 23) % 256, g = (index * 51 + 60) % 256, b = (index * 11 + 90) % 256 }
  end
  return {
    schema = "g4-pokegear-assets-v2",
    skins = { 0, 1, 2, 3, 4, 5 },
    shell = { foreground = visualRef("assets/generated/pokegear/shell-foreground-skin-0.png", 256, 192) },
    configure = { panel = visualRef("assets/generated/pokegear/configure-panel.png", 32, 32) },
    phone = {
      foreground = phoneForeground,
      upper = phoneUpper,
      panel = phonePanel,
      listPalette = phoneListPalette,
      tooltipPalette = phoneTooltipPalette,
      sprites = { phone = phoneSprites },
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
---@return table flags owner
---@return table world
local function worldFixture()
  local flags = {}
  local world = {
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
  return flags, world
end

---@return table
local function messageRefs()
  return {
    invitation = "custom.invitation",
    accept = "custom.accept",
    resolveLine = function()
      return { tokens = { { kind = "glyph", code = 1, text = "X", raw = { 1 } } } }
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

-- Recording audio boundary: every generic effect play is captured by
-- sequence symbol, and the effect player reports completion at once so
-- only staged source timers (never audio waits) gate the scenarios.
---@return table audio
---@return string[] play log
local function recordingAudio()
  local log = {}
  local audio = {}
  function audio.play(_, sequence)
    log[#log + 1] = sequence
  end
  function audio.isEffectWaitComplete()
    return true
  end
  return audio, log
end

-- Opens the real card controller on a fresh companion state with every
-- catalogued contact registered, through the validated synthetic
-- record. Callers place menu calls through semantic confirm input.
---@param audio table?
---@return table controller
---@return table record
---@return table flags
---@return string[]? audio log, when audio is recorded
local function openMenuController(audio)
  local PhoneController = requireFeature(
    "game.hgss.src.pokegear.PhoneController",
    "the phone card has no controller yet: the call behavior has no live call to observe"
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
  local flags, world = worldFixture()
  flags["mom.savings-choice"] = false
  local audioLog = nil
  local audioDeps = audio
  if audioDeps == nil then
    audioDeps, audioLog = recordingAudio()
  elseif audio == "instant" then
    audioDeps = nil
  end
  local controller = PhoneController.new({
    state = state,
    catalog = record.catalog,
    assets = record,
    messages = messageRefs(),
    world = world,
    audio = audioDeps,
    random = PokegearRandom.new(2024),
    tooltips = fixtureTooltips(),
    menuLabels = fixtureMenuLabels(),
  })
  return controller, record, flags, audioLog
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

-- Advances the live conversation through semantic advance input until
-- the mother program owes its save/keep choice. The bound only guards
-- against a stuck call; a healthy call owes its choice within a few
-- fixed steps with no wall-clock waits.
---@param controller table
---@return table the detached view at the owed choice
local function driveToOwedChoice(controller)
  for _ = 1, 24 do
    local view = controller:status().view
    local call = view.call
    if type(call) == "table" and call.stage == "choice" then
      return view
    end
    controller:updateFixed({ { type = "advance" } })
  end
  error("the mother call never reached its owed save/keep choice", 0)
end

---@param view table
---@return table call projection
local function liveCall(view)
  local call = assert(view.call, "the live call keeps its conversation projection")
  assert(type(call) == "table", "the call projection is a record")
  return call --[[@as table]]
end

-- Source fast-forward hitbox geometry in pixels, published from
-- gPhoneCallFastForwardHitbox { 0x88, 0xb8, 0x08, 0xf8 }.
local FAST_FORWARD_HITBOX = { x = 0x88, y = 0xb8, width = 0x08, height = 0xf8 }

-- (1) starting a call publishes the source dim state plus the
-- caller-name content for windows[1] in colors (1,2,0), and exiting the
-- call clears the publication. PokegearPhone_SetTouchscreenDimState
-- fills windows[0]+[1], blends the MAIN_BG/OBJ palettes down, and
-- prints the caller name into windows[1]; PhoneCall_Exit clears both
-- windows and undims.
function T.tests.call_start_publishes_dim_state_and_name_window_and_exit_clears_it()
  local controller = openMenuController()
  placeMenuCall(controller)
  local call = liveCall(controller:status().view)
  Assert.equal(call.dim, true, "starting the call publishes the touchscreen dim state")
  local nameWindow = assert(call.nameWindow, "starting the call publishes the windows[1] caller-name content")
  assert(type(nameWindow) == "table", "the name window content is a record")
  Assert.equal(
    (nameWindow --[[@as table<string, unknown>]]).text,
    call.name,
    "the windows[1] content names the live caller"
  )
  Assert.deepEqual(
    (nameWindow --[[@as table<string, unknown>]]).colors,
    { 1, 2, 0 },
    "the caller name prints in the source windows[1] text colors (1,2,0)"
  )
  for _ = 1, 24 do
    if controller:status().view.call == nil then
      break
    end
    controller:updateFixed({ { type = "cancel" } })
    controller:updateFixed({ { type = "advance" } })
  end
  local exited = controller:status().view
  Assert.isNil(exited.call, "exiting the call clears the dim/name publication with the call view")
  controller:dispose()
end

---@param lines unknown
---@return string snapshot of the speech projection lines
local function linesSnapshot(lines)
  if type(lines) ~= "table" then
    return "<no-lines>"
  end
  local parts = {}
  for _, line in ipairs(lines --[[@as table<integer, unknown>]]) do
    if type(line) == "table" then
      parts[#parts + 1] = tostring((line --[[@as table<string, unknown>]]).text)
    else
      parts[#parts + 1] = tostring(line)
    end
  end
  return table.concat(parts, "\n")
end

-- (2) hangup plays staged click lines into the speech projection
-- with the source tones and timers, never a single tone.
-- PhoneCall_HangupTone/HangupNoTone print staged hangUpMsgs/noSignalMsgs
-- lines behind SEQ_SE_GS_PHONE_OFF across 10-tick timer stages, and
-- PokegearPhone_PrintHangUpClicks stages SELECT into BOX03 clicks; the
-- conversation must stay live across several fixed ticks while its
-- staged lines advance.
function T.tests.hangup_plays_staged_click_lines_with_source_tones_and_timers()
  local controller, _, _, audioLog = openMenuController()
  assert(audioLog ~= nil, "the hangup scenario records the audio boundary")
  placeMenuCall(controller)
  driveToOwedChoice(controller)
  local answered = #audioLog
  controller:updateFixed({ { type = "confirm" } })
  local hangupStages, lineSnapshots, ticks = {}, {}, 0
  for _ = 1, 12 do
    ticks = ticks + 1
    local view = controller:status().view
    if view.call == nil then
      break
    end
    local call = liveCall(view)
    Assert.equal(call.stage, "hangingUp", "the answered call hangs up through staged clicks, not at once")
    local hangup = assert(
      call.hangup,
      "the hanging-up call publishes its staged click progress"
    )
    assert(type(hangup) == "table", "the hangup progress is a record")
    hangupStages[#hangupStages + 1] = (hangup --[[@as table<string, unknown>]]).index
    lineSnapshots[#lineSnapshots + 1] = linesSnapshot(call.lines)
    controller:updateFixed({ { type = "advance" } })
  end
  Assert.isNil(controller:status().view.call, "the staged hangup completes and clears the call")
  local distinctStages, distinctLines = {}, {}
  for _, index in ipairs(hangupStages) do
    distinctStages[index] = true
  end
  for _, snapshot in ipairs(lineSnapshots) do
    distinctLines[snapshot] = true
  end
  local stageCount, lineCount = 0, 0
  for _ in pairs(distinctStages) do
    stageCount = stageCount + 1
  end
  for _ in pairs(distinctLines) do
    lineCount = lineCount + 1
  end
  Assert.isTrue(stageCount >= 2, "the hangup advances through at least two staged click steps")
  Assert.isTrue(lineCount >= 2, "the hangup prints at least two distinct staged lines into speech")
  Assert.isTrue(ticks >= 3, "the staged hangup spans several fixed ticks behind its source timers")
  local hangupPlays = {}
  for index = answered + 1, #audioLog do
    hangupPlays[#hangupPlays + 1] = audioLog[index]
  end
  local sawOff, sawClick = false, false
  for _, sequence in ipairs(hangupPlays) do
    if sequence == "SEQ_SE_GS_PHONE_OFF" then
      sawOff = true
    end
    if sequence == "SEQ_SE_DP_SELECT" or sequence == "SEQ_SE_DP_BOX03" then
      sawClick = true
    end
  end
  Assert.isTrue(sawOff, "the staged hangup plays the source PHONE_OFF tone")
  Assert.isTrue(sawClick, "the staged hangup plays click tones behind its staged lines, not a single tone")
  controller:dispose()
end

-- (3) the fast-forward hitbox geometry is published in the view and
-- stays live for the whole call, from the connecting stage through the
-- owed choice into hangup. The source registers
-- gPhoneCallFastForwardHitbox for the call lifetime and unsets it on
-- PhoneCall_Exit.
function T.tests.fast_forward_hitbox_published_and_live_for_whole_call()
  local controller = openMenuController()
  placeMenuCall(controller)
  local stages = {}
  local connecting = liveCall(controller:status().view)
  Assert.deepEqual(
    connecting.fastForward,
    FAST_FORWARD_HITBOX,
    "the connecting call publishes the source fast-forward hitbox geometry"
  )
  stages[#stages + 1] = connecting.stage
  local owed = driveToOwedChoice(controller)
  Assert.deepEqual(
    liveCall(owed).fastForward,
    FAST_FORWARD_HITBOX,
    "the fast-forward hitbox stays live while the call owes its choice"
  )
  stages[#stages + 1] = liveCall(owed).stage
  controller:updateFixed({ { type = "confirm" } })
  local hanging = controller:status().view.call
  if hanging ~= nil then
    Assert.deepEqual(
      (hanging --[[@as table]]).fastForward,
      FAST_FORWARD_HITBOX,
      "the fast-forward hitbox stays live through hangup"
    )
    stages[#stages + 1] = (hanging --[[@as table<string, unknown>]]).stage
  end
  local seen, distinct = {}, 0
  for _, stage in ipairs(stages) do
    if not seen[stage] then
      seen[stage] = true
      distinct = distinct + 1
    end
  end
  Assert.isTrue(distinct >= 2, "the hitbox observation spans at least two distinct call stages")
  controller:dispose()
end

---@param controller table
---@param x number tap x in pixels
---@param y number tap y in pixels
---@param pointerId integer
local function tap(controller, x, y, pointerId)
  controller:updateFixed({ { type = "pointer_down", pointerId = pointerId, x = x, y = y } })
  controller:updateFixed({ { type = "pointer_up", pointerId = pointerId, x = x, y = y } })
end

-- (4) in-call choice menus route touch taps on options: tapping an
-- option answers it, exactly like the source
-- PhoneCall_TouchscreenListMenu choice plumbing (tap selects, never
-- just navigate/confirm keys). Tapping the second owed row answers
-- "keep" and commits the savings choice without any key input.
function T.tests.in_call_choice_tap_on_option_answers_it()
  local controller, _, flags = openMenuController()
  placeMenuCall(controller)
  local owed = driveToOwedChoice(controller)
  local call = liveCall(owed)
  Assert.deepEqual(call.choices, { "save", "keep" }, "the mother call owes its save/keep choice")
  local menu = assert(owed.callMenu, "the owed choices are exposed as a menu projection on the call surface")
  assert(type(menu) == "table", "the choice menu is a record")
  local frame = assert((menu --[[@as table<string, unknown>]]).frame, "the choice menu carries its window frame")
  assert(type(frame) == "table", "the choice menu frame is a record")
  local rows = assert((menu --[[@as table<string, unknown>]]).rows, "the choice menu carries its option rows")
  assert(type(rows) == "table", "the choice menu rows are a list")
  local second = assert((rows --[[@as table<integer, unknown>]])[2], "the choice menu owes a second row")
  assert(type(second) == "table", "the second choice row is a record")
  local frameRecord = frame --[[@as table<string, integer>]]
  local secondRecord = second --[[@as table<string, unknown>]]
  tap(
    controller,
    frameRecord.x * 8 + 16,
    (secondRecord.y --[[@as integer]]) + 8,
    7
  )
  for _ = 1, 24 do
    if controller:status().view.call == nil then
      break
    end
    if flags["mom.savings-choice"] == "keep" then
      break
    end
    controller:updateFixed({ { type = "advance" } })
  end
  Assert.equal(flags["mom.savings-choice"], "keep", "tapping the second option answers keep")
  controller:dispose()
end

-- (5) view.call carries no choiceCursor field: the dead publication
-- is removed. The controller's internal cursor still drives the owed
-- choice through view.callMenu.cursor, so navigating down then
-- confirming answers the second option.
function T.tests.call_view_carries_no_choice_cursor_and_menu_cursor_drives_choice()
  local controller, _, flags = openMenuController()
  placeMenuCall(controller)
  local owed = driveToOwedChoice(controller)
  local call = liveCall(owed)
  Assert.isNil(
    call.choiceCursor,
    "view.call carries no choiceCursor publication"
  )
  local menu = assert(owed.callMenu, "the owed choices are exposed as a menu projection on the call surface")
  assert(type(menu) == "table", "the choice menu is a record")
  Assert.equal(
    (menu --[[@as table<string, unknown>]]).cursor,
    0,
    "the choice menu cursor opens on the first option"
  )
  controller:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(
    assert(controller:status().view.callMenu, "the choice menu stays open across navigation").cursor,
    1,
    "the internal cursor drives view.callMenu.cursor"
  )
  controller:updateFixed({ { type = "confirm" } })
  for _ = 1, 24 do
    if controller:status().view.call == nil then
      break
    end
    if flags["mom.savings-choice"] == "keep" then
      break
    end
    controller:updateFixed({ { type = "advance" } })
  end
  Assert.equal(flags["mom.savings-choice"], "keep", "confirming after navigating down answers keep")
  controller:dispose()
end

return T
