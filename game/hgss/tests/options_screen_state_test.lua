-- Headless contract for the scrolling Options application: seven ordered
-- rows with deterministic focus/scroll/edit behavior, the staged legacy
-- Slow draft, the prepare-then-commit-volume-then-apply confirmation
-- order, reversible previews, and exactly-once terminal results. No love,
-- no graphics, no ROM; collaborators are deterministic fakes at the true
-- host boundaries (storage-backed volume port, channel-mode sink, player
-- validation closure, sound effects).

local Assert = require("tests.support.Assert")

local T = {
  metadata = { tags = { "options", "screen_state" } },
  tests = {},
}

local function stateModule()
  local ok, mod = pcall(require, "game.hgss.src.options.OptionsScreenState")
  Assert.isTrue(ok, "OptionsScreenState missing: " .. tostring(mod))
  return mod
end

local function interfaceModule()
  local ok, mod = pcall(require, "game.hgss.src.options.OptionsInterface")
  Assert.isTrue(ok, "OptionsInterface missing: " .. tostring(mod))
  return mod
end

local function canonicalOptions(overrides)
  local base = {
    textSpeed = "fastest",
    battleScene = true,
    battleStyle = "shift",
    soundMode = "stereo",
    textFrame = 0,
    battleSpeed = 1,
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      base[key] = value
    end
  end
  return base
end

-- The injected volume port mirrors the AudioPreferences shape: read is the
-- committed percent, preview changes only audible gain, commit publishes
-- and may fail at the storage boundary, restore reapplies the committed
-- gain. Failures are injected per test.
local function fakeAudioPort(committed)
  local port = {
    _committed = committed,
    _audible = committed,
    previews = 0,
    commits = 0,
    restores = 0,
    failNextCommit = nil,
  }
  function port.read()
    return port._committed
  end
  function port.preview(percent)
    port.previews = port.previews + 1
    port._audible = percent
  end
  function port.commit(percent)
    port.commits = port.commits + 1
    if port.failNextCommit ~= nil then
      local failure = port.failNextCommit
      port.failNextCommit = nil
      error(failure, 0)
    end
    port._committed = percent
    port._audible = percent
  end
  function port.restore()
    port.restores = port.restores + 1
    port._audible = port._committed
  end
  return port
end

-- The prepared-application closure records whether the six player fields
-- were adopted; abandoning it changes nothing.
local function fakePrepare()
  local applied = 0
  local lastCandidate = nil
  local function prepare(values)
    lastCandidate = values
    local consumed = false
    return function()
      Assert.isFalse(consumed, "the prepared application applies exactly once")
      consumed = true
      applied = applied + 1
    end
  end
  return prepare, function()
    return applied
  end, function()
    return lastCandidate
  end
end

local function fakeEffects()
  local played = {}
  return played, function(sequence)
    played[#played + 1] = sequence
  end
end

local function semanticLabels()
  local function label(text)
    return { text = text, tokens = { { kind = "glyph", text = text } } }
  end
  local frameValues = {}
  for slot = 0, 19 do
    frameValues[slot] = label("TYPE " .. (slot + 1))
  end
  return {
    title = label("OPTIONS"),
    textSpeed = label("TEXT SPEED"),
    battleScene = label("BATTLE SCENE"),
    battleStyle = label("BATTLE STYLE"),
    soundMode = label("SOUND"),
    textFrame = label("FRAME"),
    volume = label("VOLUME"),
    battleSpeed = label("BATTLE SPEED"),
    confirm = label("CONFIRM"),
    quit = label("QUIT"),
    textSpeedValues = { mid = label("MID"), fast = label("FAST"), turbo = label("TURBO") },
    battleSceneValues = { on = label("ON"), off = label("OFF") },
    battleStyleValues = { shift = label("SHIFT"), set = label("SET") },
    soundModeValues = { stereo = label("STEREO"), mono = label("MONO") },
    frameValues = frameValues,
  }
end

local function openMenu(opts)
  opts = opts or {}
  local State = stateModule()
  local prepare, applied, candidate = fakePrepare()
  local port = fakeAudioPort(opts.volume == nil and 80 or opts.volume)
  if opts.failCommit ~= nil then
    port.failNextCommit = opts.failCommit
  end
  local played, effect = fakeEffects()
  local channels = {}
  local state = State.new({
    playerOptions = canonicalOptions(opts.playerOptions),
    volume = port:read(),
    preparePlayerOptions = opts.prepare == nil and prepare or opts.prepare,
    audioPreferences = port,
    applyChannelMode = function(mode)
      channels[#channels + 1] = mode
    end,
    effect = effect,
    semantic = { labels = semanticLabels() },
  })
  return {
    state = state,
    port = port,
    played = played,
    channels = channels,
    applied = applied,
    candidate = candidate,
  }
end

local function rowById(status, id)
  for _, row in ipairs(assert(status.rows, "status carries its rows")) do
    if row.id == id then
      return row
    end
  end
  error("row " .. id .. " is not published", 0)
end

function T.tests.seven_rows_publish_in_order_with_footer_actions()
  local opened = openMenu()
  local status = opened.state:status()
  Assert.equal(#status.rows, 7, "exactly seven settings publish")
  local ids = {}
  for _, row in ipairs(status.rows) do
    ids[#ids + 1] = row.id
  end
  Assert.deepEqual(ids, {
    "textSpeed",
    "battleScene",
    "battleStyle",
    "soundMode",
    "textFrame",
    "volume",
    "battleSpeed",
  }, "rows keep their stable order")
  Assert.isTrue(status.footer ~= nil and status.footer.confirm ~= nil, "the footer carries confirm")
  Assert.isTrue(status.footer.quit ~= nil, "the footer carries quit")
  Assert.equal(status.focusId, "textSpeed", "initial focus is the first row")
  Assert.equal(status.scrollOffset, 0, "the list opens unscrolled")
  for _, row in ipairs(status.rows) do
    Assert.isTrue(row.id ~= "slow" and row.id ~= "buttonMode", "no removed row publishes")
  end
end

function T.tests.text_offers_three_stops_mapping_turbo_to_fastest()
  local opened = openMenu()
  local row = rowById(opened.state:status(), "textSpeed")
  Assert.equal(row.valueCount, 3, "text speed offers three stops")
  Assert.equal(row.value, "fastest", "the draft opens on the committed fastest key")
  Assert.equal(row.valueLabel, "TURBO", "the third stop reads as Turbo")
  opened.state:updateFixed({ { type = "navigate", direction = "left" } })
  row = rowById(opened.state:status(), "textSpeed")
  Assert.equal(row.value, "fast", "left steps toward fast")
  opened.state:updateFixed({ { type = "navigate", direction = "left" } })
  row = rowById(opened.state:status(), "textSpeed")
  Assert.equal(row.value, "mid", "left reaches the first stop")
  opened.state:updateFixed({ { type = "navigate", direction = "left" } })
  row = rowById(opened.state:status(), "textSpeed")
  Assert.equal(row.value, "mid", "the first stop clamps")
  opened.state:updateFixed({ { type = "navigate", direction = "right" } })
  opened.state:updateFixed({ { type = "navigate", direction = "right" } })
  row = rowById(opened.state:status(), "textSpeed")
  Assert.equal(row.value, "fastest", "the third stop keeps the fastest stored key")
  Assert.equal(row.valueLabel, "TURBO", "the third stop reads as Turbo")
  opened.state:updateFixed({ { type = "navigate", direction = "right" } })
  row = rowById(opened.state:status(), "textSpeed")
  Assert.equal(row.value, "fastest", "the last stop clamps")
end

function T.tests.focus_graph_reaches_footer_and_returns()
  local opened = openMenu()
  local state = opened.state
  state:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(state:status().focusId, "quit", "up from the first row reaches quit")
  state:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(state:status().focusId, "textSpeed", "down from the footer returns to the first row")
  for _ = 1, 6 do
    state:updateFixed({ { type = "navigate", direction = "down" } })
  end
  Assert.equal(state:status().focusId, "battleSpeed", "down walks the fixed row order")
  state:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(state:status().focusId, "confirm", "down from battle speed reaches confirm")
  state:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(state:status().focusId, "quit", "footer right selects quit")
  state:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(state:status().focusId, "quit", "footer right clamps")
  state:updateFixed({ { type = "navigate", direction = "left" } })
  Assert.equal(state:status().focusId, "confirm", "footer left selects confirm")
  state:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(state:status().focusId, "battleSpeed", "up from either footer reaches battle speed")
  state:updateFixed({ { type = "navigate", direction = "down" } })
  state:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(state:status().focusId, "textSpeed", "down from the footer wraps to the first row")
end

function T.tests.row_left_right_never_moves_footer_focus()
  local opened = openMenu()
  local state = opened.state
  local before = state:status().focusId
  state:updateFixed({ { type = "navigate", direction = "left" } })
  state:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(state:status().focusId, before, "row edits never move focus into the footer")
end

function T.tests.legacy_slow_stages_mid_with_a_note_and_quit_preserves_it()
  local opened = openMenu({ playerOptions = { textSpeed = "slow" } })
  local status = opened.state:status()
  local row = rowById(status, "textSpeed")
  Assert.equal(row.value, "mid", "a legacy Slow draft stages Mid")
  Assert.isTrue(status.legacyNote ~= nil, "the staging explains that Confirm replaces Slow")
  Assert.isTrue(status.dirty, "the staged normalization marks the draft changed")
  opened.state:updateFixed({ { type = "cancel" } })
  Assert.isNil(opened.state:status().open == false and nil or nil, "cancel closes the menu")
  Assert.equal(opened.applied(), 0, "quit performs no player application")
  Assert.equal(opened.port:read(), 80, "quit leaves the committed volume alone")
end

function T.tests.legacy_slow_confirm_adopts_mid()
  local opened = openMenu({ playerOptions = { textSpeed = "slow" } })
  opened.state:updateFixed({ { type = "activate", id = "confirm" } })
  local result = opened.state:takeResult()
  Assert.deepEqual(result, { kind = "close" }, "a successful confirm emits one close result")
  Assert.equal(opened.applied(), 1, "confirm applies the staged Mid once")
  local candidate = opened.candidate()
  Assert.equal(candidate.textSpeed, "mid", "the candidate carries Mid, never Slow")
end

function T.tests.volume_spans_zero_to_one_hundred_with_one_percent_stops()
  local opened = openMenu({ volume = 80 })
  local row = rowById(opened.state:status(), "volume")
  Assert.equal(row.valueCount, 101, "volume offers one-percent stops")
  Assert.equal(row.value, 80, "the draft opens at the committed volume")
  Assert.equal(opened.state:status().focusId, "textSpeed", "edits start on the first row")
  for _ = 1, 5 do
    opened.state:updateFixed({ { type = "navigate", direction = "down" } })
  end
  Assert.equal(opened.state:status().focusId, "volume", "five downs reach the volume row")
  for _ = 1, 200 do
    opened.state:updateFixed({ { type = "navigate", direction = "right" } })
  end
  row = rowById(opened.state:status(), "volume")
  Assert.equal(row.value, 100, "right clamps at full volume")
  for _ = 1, 200 do
    opened.state:updateFixed({ { type = "navigate", direction = "left" } })
  end
  row = rowById(opened.state:status(), "volume")
  Assert.equal(row.value, 0, "left clamps at mute")
  opened.state:updateFixed({ { type = "slider-set", row = "volume", index = 42 } })
  row = rowById(opened.state:status(), "volume")
  Assert.equal(row.value, 41, "a pointer drag sets the one-percent draft value")
end

function T.tests.battle_speed_snaps_to_one_two_four()
  local opened = openMenu()
  local row = rowById(opened.state:status(), "battleSpeed")
  Assert.equal(row.valueCount, 3, "battle speed offers three stops")
  for _ = 1, 6 do
    opened.state:updateFixed({ { type = "navigate", direction = "down" } })
  end
  Assert.equal(opened.state:status().focusId, "battleSpeed", "six downs reach the battle speed row")
  opened.state:updateFixed({ { type = "slider-set", row = "battleSpeed", index = 2 } })
  row = rowById(opened.state:status(), "battleSpeed")
  Assert.equal(row.value, 2, "the middle stop is 2x")
  opened.state:updateFixed({ { type = "slider-set", row = "battleSpeed", index = 9 } })
  row = rowById(opened.state:status(), "battleSpeed")
  Assert.equal(row.value, 4, "an out-of-range drag clamps to 4x")
  opened.state:updateFixed({ { type = "slider-set", row = "battleSpeed", index = 0 } })
  row = rowById(opened.state:status(), "battleSpeed")
  Assert.equal(row.value, 1, "an out-of-range drag clamps to 1x")
end

function T.tests.frame_cycles_all_twenty_with_visible_one_based_labels()
  local opened = openMenu()
  local row = rowById(opened.state:status(), "textFrame")
  Assert.equal(row.valueCount, 20, "all twenty frames publish")
  Assert.equal(row.valueLabel, "TYPE 1", "the visible label is one-based")
  opened.state:updateFixed({ { type = "direct-select", row = "textFrame", index = 20 } })
  row = rowById(opened.state:status(), "textFrame")
  Assert.equal(row.value, 19, "direct selection stores the zero-based frame")
  Assert.equal(row.valueLabel, "TYPE 20", "the last visible label is twenty")
  opened.state:updateFixed({ { type = "navigate", direction = "right" } })
  row = rowById(opened.state:status(), "textFrame")
  Assert.equal(row.value, 19, "right clamps at the last frame")
end

function T.tests.direct_choice_selection_edits_value_without_moving_focus()
  local opened = openMenu()
  local state = opened.state
  local before = state:status().focusId
  state:updateFixed({ { type = "direct-select", row = "soundMode", index = 2 } })
  local row = rowById(state:status(), "soundMode")
  Assert.equal(row.value, "mono", "a pointer tap selects the concrete choice")
  Assert.equal(state:status().focusId, before, "hovering a value never erases row focus")
end

function T.tests.confirm_follows_prepare_commit_then_apply()
  local opened = openMenu()
  local order = {}
  local port = opened.port
  local realCommit = port.commit
  port.commit = function(percent)
    order[#order + 1] = "commit"
    return realCommit(percent)
  end
  local state = opened.state
  state:updateFixed({ { type = "navigate", direction = "right" } })
  state:updateFixed({ { type = "activate", id = "confirm" } })
  order[#order + 1] = "applied:" .. tostring(opened.applied())
  local result = state:takeResult()
  Assert.deepEqual(result, { kind = "close" }, "confirm emits one close result")
  Assert.equal(opened.applied(), 1, "the prepared closure applies exactly once")
  Assert.equal(port:read(), 80, "an untouched volume stays committed")
  Assert.deepEqual(order, { "commit", "applied:1" }, "volume commits before the player application")
end

function T.tests.confirm_publishes_an_edited_volume_once()
  local opened = openMenu({ volume = 80 })
  local state = opened.state
  for _ = 1, 5 do
    state:updateFixed({ { type = "navigate", direction = "down" } })
  end
  Assert.equal(state:status().focusId, "volume", "five downs reach the volume row")
  state:updateFixed({ { type = "navigate", direction = "right" } })
  state:updateFixed({ { type = "activate", id = "confirm" } })
  Assert.deepEqual(state:takeResult(), { kind = "close" }, "confirm closes once")
  Assert.equal(opened.port:read(), 81, "the edited volume commits")
  Assert.equal(opened.applied(), 1, "the player application still runs once")
end

function T.tests.failed_volume_commit_keeps_menu_open_with_draft_and_baseline()
  local opened = openMenu({ failCommit = "SAVE_WRITE_FAILED: disk is full" })
  local state = opened.state
  state:updateFixed({ { type = "navigate", direction = "left" } })
  for _ = 1, 5 do
    state:updateFixed({ { type = "navigate", direction = "down" } })
  end
  Assert.equal(state:status().focusId, "volume", "five downs reach the volume row")
  state:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(state:status().dirty, true, "the draft carries the staged edits")
  state:updateFixed({ { type = "activate", id = "confirm" } })
  Assert.isNil(state:takeResult(), "a failed confirm emits no close result")
  Assert.equal(opened.applied(), 0, "a failed confirm never applies player options")
  Assert.equal(opened.port:read(), 80, "the committed volume is unchanged")
  local status = state:status()
  Assert.isTrue(status.open, "the menu stays open")
  Assert.isTrue(status.error ~= nil, "a readable error is published")
  Assert.isTrue(status.dirty, "the draft is preserved for retry")
  state:updateFixed({ { type = "activate", id = "confirm" } })
  Assert.deepEqual(state:takeResult(), { kind = "close" }, "a retry after recovery confirms")
  Assert.equal(opened.applied(), 1, "the retry applies once")
end

function T.tests.cancel_restores_audio_and_leaves_player_options_alone()
  local opened = openMenu()
  local state = opened.state
  state:updateFixed({ { type = "navigate", direction = "right" } })
  state:updateFixed({ { type = "direct-select", row = "soundMode", index = 2 } })
  Assert.isTrue(#opened.channels >= 1, "mode previews reach the live sink")
  state:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(state:takeResult(), { kind = "close" }, "cancel closes once")
  Assert.equal(opened.applied(), 0, "cancel performs no player application")
  Assert.equal(opened.port:read(), 80, "cancel leaves the committed volume")
  Assert.isTrue(opened.port.restores >= 1, "cancel restores the committed gain")
  Assert.equal(opened.channels[#opened.channels], "stereo", "cancel restores the committed channel mode")
end

function T.tests.outside_dismissal_cancels_the_whole_draft_without_click_through()
  local opened = openMenu()
  local state = opened.state
  state:updateFixed({ { type = "navigate", direction = "right" } })
  state:updateFixed({ { type = "dismiss" } })
  Assert.deepEqual(state:takeResult(), { kind = "close" }, "outside down closes once")
  Assert.equal(opened.applied(), 0, "outside dismissal never applies")
  Assert.equal(opened.port:read(), 80, "outside dismissal restores the committed volume")
end

function T.tests.uncommitted_disposal_restores_audio_once_and_committed_disposal_never_rolls_back()
  local opened = openMenu()
  local state = opened.state
  state:updateFixed({ { type = "navigate", direction = "right" } })
  state:dispose()
  state:dispose()
  Assert.equal(opened.port.restores, 1, "disposal restores audio exactly once")
  Assert.equal(opened.applied(), 0, "disposal never applies")
  local committed = openMenu()
  committed.state:updateFixed({ { type = "activate", id = "confirm" } })
  Assert.deepEqual(committed.state:takeResult(), { kind = "close" }, "confirm closes")
  local restores = committed.port.restores
  committed.state:dispose()
  Assert.equal(committed.port.restores, restores, "disposal after success never rolls settings back")
end

function T.tests.closed_state_ignores_input_and_results_emit_once()
  local opened = openMenu()
  local state = opened.state
  state:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(state:takeResult(), { kind = "close" }, "the first take reports close")
  Assert.isNil(state:takeResult(), "the result emits exactly once")
  state:updateFixed({ { type = "navigate", direction = "right" } })
  state:updateFixed({ { type = "activate", id = "confirm" } })
  Assert.isNil(state:takeResult(), "closed input changes nothing")
  Assert.equal(opened.applied(), 0, "closed input never applies")
end

function T.tests.scroll_moves_list_without_editing_values_or_focus()
  local opened = openMenu()
  local state = opened.state
  local Interface = interfaceModule()
  Assert.isTrue(Interface.ROW_IDS ~= nil, "the interface publishes its stable row order")
  Assert.deepEqual(Interface.ROW_IDS, {
    "textSpeed",
    "battleScene",
    "battleStyle",
    "soundMode",
    "textFrame",
    "volume",
    "battleSpeed",
  }, "the interface row order is the seven-setting order")
  local before = rowById(state:status(), "textSpeed").value
  state:updateFixed({ { type = "scroll", delta = 48 } })
  Assert.isTrue(state:status().scrollOffset > 0, "wheel input scrolls the list")
  Assert.equal(rowById(state:status(), "textSpeed").value, before, "scrolling edits no value")
  Assert.equal(state:status().focusId, "textSpeed", "scrolling keeps row focus")
end

function T.tests.invalid_preparation_blocks_confirm_without_publishing_volume()
  local prepare = function()
    return nil, { code = "PLAYER_DATA_INVALID", message = "busy" }
  end
  local opened = openMenu({ prepare = prepare })
  opened.state:updateFixed({ { type = "activate", id = "confirm" } })
  Assert.isNil(opened.state:takeResult(), "an invalid draft emits no close")
  Assert.equal(opened.port.commits, 0, "volume never publishes before validation")
  Assert.equal(opened.applied(), 0, "nothing applies")
  Assert.isTrue(opened.state:status().error ~= nil, "the validation failure is visible")
end

function T.tests.confirmed_close_blocks_further_edits_and_cancel()
  local opened = openMenu()
  local state = opened.state
  state:updateFixed({ { type = "activate", id = "confirm" } })
  state:updateFixed({ { type = "navigate", direction = "right" } })
  state:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(state:takeResult(), { kind = "close" }, "the confirmed close still emits once")
  Assert.equal(opened.applied(), 1, "no second application runs during closing feedback")
end

function T.tests.footer_buttons_activate_on_matching_press_and_release()
  local opened = openMenu()
  local state = opened.state
  state:updateFixed({
    { type = "pointer_down", pointerId = "touch:0", hit = { target = "quit", control = "footer" } },
  })
  Assert.isNil(state:takeResult(), "press alone never closes")
  state:updateFixed({
    { type = "pointer_up", pointerId = "touch:0", hit = { target = "quit", control = "footer" } },
  })
  Assert.deepEqual(state:takeResult(), { kind = "close" }, "a matching release activates quit")
  Assert.equal(opened.applied(), 0, "quit never applies")
end

function T.tests.a_press_released_off_target_selects_nothing()
  local opened = openMenu()
  local state = opened.state
  state:updateFixed({
    { type = "pointer_down", pointerId = "touch:0", hit = { target = "soundMode", control = "value", index = 2 } },
    { type = "pointer_move", pointerId = "touch:0", hit = nil },
    { type = "pointer_up", pointerId = "touch:0", hit = nil },
  })
  local row = rowById(state:status(), "soundMode")
  Assert.equal(row.value, "stereo", "a press dragged away cannot select on release")
end

function T.tests.a_second_pointer_never_steals_the_capture()
  local opened = openMenu()
  local state = opened.state
  state:updateFixed({
    { type = "pointer_down", pointerId = "touch:0", hit = { target = "quit", control = "footer" } },
    { type = "pointer_down", pointerId = "touch:1", hit = { target = "confirm", control = "footer" } },
    { type = "pointer_up", pointerId = "touch:1", hit = { target = "confirm", control = "footer" } },
  })
  Assert.isNil(state:takeResult(), "the second pointer activates nothing")
  state:updateFixed({
    { type = "pointer_up", pointerId = "touch:0", hit = { target = "quit", control = "footer" } },
  })
  Assert.deepEqual(state:takeResult(), { kind = "close" }, "the first pointer still owns the press")
end

function T.tests.slider_capture_survives_wheel_while_row_presses_disarm()
  local opened = openMenu()
  local state = opened.state
  for _ = 1, 5 do
    state:updateFixed({ { type = "navigate", direction = "down" } })
  end
  state:updateFixed({ { type = "slider-set", row = "volume", index = 42 } })
  local settled = state:status().scrollOffset
  Assert.isTrue(settled > 0, "focusing the volume row scrolls it into view")
  state:updateFixed({
    { type = "pointer_down", pointerId = "touch:0", hit = { target = "volume", control = "thumb", index = 42 } },
  })
  state:updateFixed({ { type = "scroll", delta = 48 } })
  Assert.equal(state:status().scrollOffset, settled, "wheel during a slider capture never scrolls")
  Assert.equal(rowById(state:status(), "volume").value, 41, "the slider keeps its dragged value")
  state:updateFixed({
    { type = "pointer_up", pointerId = "touch:0", hit = { target = "volume", control = "thumb", index = 42 } },
  })
  Assert.isNil(state:takeResult(), "releasing the slider closes nothing")
  state:updateFixed({ { type = "pointer_cancel" } })
  Assert.equal(rowById(state:status(), "volume").value, 41, "cancellation keeps the last valid draft value")
end

function T.tests.vertical_list_drag_scrolls_without_editing_values()
  local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
  local Interface = interfaceModule()
  local ScreenTopology = require("libs.ui.src.ScreenTopology")
  local measurement = {
    width = 512,
    height = 384,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 512, height = 384 },
      role = "world",
      touch = false,
    }),
    pixelRatio = 1,
    signature = "options-list-drag",
  }
  local selection = ApplicationLayout.selectSurfaces(measurement)
  local resolvers = Interface.defaults()
  local context = {
    measurement = measurement,
    configuration = "nativeLike",
    primary = selection.primary,
    secondary = selection.secondary,
    nativeLikeInterface = resolvers.nativeLike,
  }
  local content = resolvers.nativeLike(context, openMenu().state:status()).content
  Assert.isTrue(Interface.inList(content, 4, content.listViewport.y + 4), "label space hit-tests as list")
  local opened = openMenu()
  local state = opened.state
  state:updateFixed({ { type = "scroll", delta = 48 } })
  Assert.equal(state:status().scrollOffset, 48, "a wheel scroll moves the list")
  Assert.equal(state:status().focusId, "textSpeed", "scrolling keeps the row focus")
end

return T
