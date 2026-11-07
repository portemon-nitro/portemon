-- Call-behavior contract: starting a call publishes the source dim
-- state plus the caller-name content for windows[1] (colors 1,2,0) and
-- the fast-forward hitbox, and exiting clears the publication; the
-- normal hangup prints the three source messages at staged timer waits
-- with one hangup tone and no debug clicks; and in-call choice menus
-- answer taps on options while tracking the cursor on the shared
-- projection. Synthetic catalog, real production PhoneController plus
-- the real PhoneCall engine, recording (non-GPU) audio fakes; the
-- scenarios stop before GPU rendering.

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
  local phoneForegroundDim, phoneForegroundDimChoice, phoneDimShellForeground = {}, {}, {}
  local phoneListPalette, phoneListPaletteDim, phoneTooltipPalette = {}, {}, {}
  for skin = 0, 5 do
    phoneListPalette[skin] = {}
    phoneListPaletteDim[skin] = {}
    phoneTooltipPalette[skin] = {}
    for index = 1, 16 do
      phoneListPalette[skin][index] =
        { r = (index * 15 + skin * 30) % 256, g = (index * 40) % 256, b = (skin * 45 + 20) % 256 }
      phoneListPaletteDim[skin][index] =
        { r = (index * 37 + skin * 11 + 90) % 256, g = (index * 19 + 130) % 256, b = (skin * 23 + 40) % 256 }
      phoneTooltipPalette[skin][index] =
        { r = (index * 29 + skin * 12) % 256, g = (index * 17 + 90) % 256, b = (skin * 31 + 140) % 256 }
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
  local phoneSpritesDim = {}
  for sequence, frames in ipairs(phoneSpriteCounts) do
    local list = {}
    for frame = 1, frames do
      list[frame] = {
        image = "assets/generated/pokegear/phone-sprite-phone-" .. sequence .. "-dim-" .. frame .. ".png",
        width = phoneSpriteWidths[sequence],
        height = phoneSpriteHeights[sequence],
        anchorX = -math.floor(phoneSpriteWidths[sequence] / 2),
        anchorY = -math.floor(phoneSpriteHeights[sequence] / 2),
        duration = 1,
      }
    end
    phoneSpritesDim[sequence] = { frames = list, playMode = "forward", loopStartFrameIdx = 0 }
  end
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

-- The source UI text behind the live call: bank271 entries behind a
-- provider-style resolver returning one distinguishable record per
-- entry, so hangup and choice assertions read localized labels instead
-- of invented literals.
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

-- Advances the live static conversation through semantic advance input
-- until it stages its normal hangup. Static scripts never owe a choice:
-- the message pages complete straight into the staged hangup. The bound
-- only guards against a stuck call; a healthy call hangs up within a few
-- fixed steps with no wall-clock waits.
---@param controller table
---@return table the detached view at the staged hangup
local function driveToHangup(controller)
  for _ = 1, 24 do
    local view = controller:status().view
    local call = view.call
    if type(call) == "table" and call.stage == "hangingUp" then
      return view
    end
    Assert.isTrue(
      type(call) ~= "table" or call.stage ~= "choice",
      "a static mother call never owes its save/keep choice"
    )
    controller:updateFixed({ { type = "advance" } })
  end
  error("the static mother call never reached its staged hangup", 0)
end

---@param view table
---@return table call projection
local function liveCall(view)
  local call = assert(view.call, "the live call keeps its conversation projection")
  assert(type(call) == "table", "the call projection is a record")
  return call --[[@as table]]
end

-- Source fast-forward hitbox geometry in pixels, normalized from
-- gPhoneCallFastForwardHitbox { top 0x88, bottom 0xb8, left 0x08,
-- right 0xf8 } into half-open { x in [8,248), y in [136,184) }.
local FAST_FORWARD_HITBOX = { x = 8, y = 136, width = 240, height = 48 }

-- (1) starting a call publishes the source dim state, the caller-name
-- content for windows[1] in colors (1,2,0), and the fast-forward hitbox;
-- exiting the call clears the publication. PokegearPhone_SetTouchscreenDimState
-- fills windows[0]+[1], blends the MAIN_BG/OBJ palettes down, and
-- prints the caller name into windows[1]; the source registers
-- gPhoneCallFastForwardHitbox for the call lifetime; PhoneCall_Exit
-- clears both windows and undims.
function T.tests.call_start_publishes_dim_state_and_name_window_and_exit_clears_it()
  local controller = openMenuController()
  placeMenuCall(controller)
  local call = liveCall(controller:status().view)
  Assert.equal(call.dim, true, "starting the call publishes the touchscreen dim state")
  Assert.deepEqual(
    call.fastForward,
    FAST_FORWARD_HITBOX,
    "the connecting call publishes the source fast-forward hitbox geometry"
  )
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
  -- Completing the static message stages the normal hangup with no
  -- choice owed: empty ticks and advancing edges alike settle it.
  local hanging = driveToHangup(controller)
  Assert.deepEqual(
    liveCall(hanging).fastForward,
    FAST_FORWARD_HITBOX,
    "the fast-forward hitbox stays live through the staged hangup"
  )
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

-- (2) the normal hangup prints the three source messages on the source
-- cadence behind a single PHONE_OFF tone. PhoneCall_HangupTone prints
-- the msg_0271 hangUpMsgs entries 33, 34, 35 across post-increment
-- 11-tick waits with no debug SELECT/BOX03 clicks; the engine advances
-- on empty fixed ticks, and the call ends only after the final wait.
function T.tests.hangup_prints_three_source_messages_on_the_source_cadence()
  local controller, _, _, audioLog = openMenuController()
  assert(audioLog ~= nil, "the hangup scenario records the audio boundary")
  placeMenuCall(controller)
  local refs = messageRefs()
  local first = refs.resolvePhoneUiMessage(refs, 33).text
  local second = refs.resolvePhoneUiMessage(refs, 34).text
  local third = refs.resolvePhoneUiMessage(refs, 35).text
  -- Completing the static message starts the normal hangup staging
  -- with no choice owed. The tone window opens before the completing
  -- tick because hangup entry plays its single tone in that same tick.
  local answered = #audioLog
  local staged = liveCall(driveToHangup(controller))
  Assert.equal(staged.stage, "hangingUp", "the completed call enters the staged normal hangup, not an instant cut")
  Assert.equal(linesSnapshot(staged.lines), first, "the hangup entry prints the first source message")
  -- Repeated status reads change nothing and replay no tone.
  local quiet = #audioLog
  Assert.equal(
    linesSnapshot(liveCall(controller:status().view).lines),
    first,
    "repeated status reads never advance the hangup timer"
  )
  Assert.equal(#audioLog, quiet, "repeated status reads replay no tone")
  local snapshots = { linesSnapshot(staged.lines) }
  -- Ten empty ticks hold the first message; the eleventh prints the second.
  for _ = 1, 10 do
    controller:updateFixed({})
    snapshots[#snapshots + 1] = linesSnapshot(liveCall(controller:status().view).lines)
  end
  Assert.equal(
    linesSnapshot(liveCall(controller:status().view).lines),
    first,
    "the first source message holds across its ten-tick wait"
  )
  controller:updateFixed({})
  snapshots[#snapshots + 1] = linesSnapshot(liveCall(controller:status().view).lines)
  Assert.equal(
    linesSnapshot(liveCall(controller:status().view).lines),
    second,
    "the eleventh tick prints the second source message"
  )
  -- Ten more hold the second; the next prints the third.
  for _ = 1, 10 do
    controller:updateFixed({})
    snapshots[#snapshots + 1] = linesSnapshot(liveCall(controller:status().view).lines)
  end
  Assert.equal(
    linesSnapshot(liveCall(controller:status().view).lines),
    second,
    "the second source message holds across its ten-tick wait"
  )
  controller:updateFixed({})
  snapshots[#snapshots + 1] = linesSnapshot(liveCall(controller:status().view).lines)
  Assert.equal(
    linesSnapshot(liveCall(controller:status().view).lines),
    third,
    "the next tick prints the third source message"
  )
  -- Ten more hold the third while the call stays live; the next ends it.
  for _ = 1, 10 do
    controller:updateFixed({})
    snapshots[#snapshots + 1] = linesSnapshot(liveCall(controller:status().view).lines)
  end
  Assert.notNil(controller:status().view.call, "the call stays live through the final wait")
  controller:updateFixed({})
  Assert.isNil(controller:status().view.call, "the hangup ends only after the final wait")
  for _, snapshot in ipairs(snapshots) do
    Assert.isNil(
      snapshot:find("hangup-click", 1, true),
      "the normal hangup never prints an invented click caption"
    )
    Assert.isTrue(
      snapshot == first or snapshot == second or snapshot == third,
      "every staged line is one of the three source messages"
    )
  end
  local off, debug = 0, 0
  for index = answered + 1, #audioLog do
    local sequence = audioLog[index]
    if sequence == "SEQ_SE_GS_PHONE_OFF" then
      off = off + 1
    end
    if sequence == "SEQ_SE_DP_SELECT" or sequence == "SEQ_SE_DP_BOX03" then
      debug = debug + 1
    end
  end
  Assert.equal(off, 1, "the normal hangup plays the source PHONE_OFF tone exactly once")
  Assert.equal(debug, 0, "the normal hangup plays no debug click tone behind its staged lines")
  controller:dispose()
end

-- (3) a static mother call completes without ever owing the savings
-- choice. The local-map greeting prints its static text and hangs up;
-- no choice menu is projected, no choice stage is entered, and the
-- savings flag is never written. The dynamic savings offer (outgoing,
-- away from home, rival named and introduced) keeps its own unit-level
-- contract beside the mother policy.
function T.tests.static_mother_calls_complete_without_owing_the_savings_choice()
  local controller, _, flags = openMenuController()
  placeMenuCall(controller)
  local hanging = driveToHangup(controller)
  local call = liveCall(hanging)
  Assert.isNil(call.choices, "a static mother call owes no save/keep choice")
  Assert.isNil(hanging.callMenu, "a static mother call projects no choice menu")
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
  Assert.isNil(
    controller:status().view.call,
    "the static call settles through its staged hangup"
  )
  Assert.equal(flags["mom.savings-choice"], false, "the static call writes no savings flag")
  controller:dispose()
end

return T
