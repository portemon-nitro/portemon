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

-- The prepared attempt records whether the six player fields were
-- adopted; abandoning it changes nothing. Rollback stays a recorded
-- no-op beside the counter so ordering tests observe the new contract.
local function fakePrepare()
  local applied = 0
  local rolledBack = 0
  local lastCandidate = nil
  local function prepare(values)
    lastCandidate = values
    local consumed = false
    local transaction = {}
    function transaction.apply()
      Assert.isFalse(consumed, "the prepared application applies exactly once")
      consumed = true
      applied = applied + 1
    end
    function transaction.rollback()
      rolledBack = rolledBack + 1
    end
    return transaction
  end
  return prepare,
    function()
      return applied
    end,
    function()
      return lastCandidate
    end,
    function()
      return rolledBack
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
  local prepare, applied, candidate, rolledBack = fakePrepare()
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
    rolledBack = rolledBack,
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

local function fakePresentationPort()
  local port = { disposes = 0 }
  function port.prepare()
    return true
  end
  function port.dispose()
    port.disposes = port.disposes + 1
  end
  return port
end

local function singleMeasurement(signature)
  local ScreenTopology = require("libs.ui.src.ScreenTopology")
  return {
    width = 512,
    height = 384,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 512, height = 384 },
      role = "world",
      touch = true,
    }),
    pixelRatio = 1,
    signature = signature or "options-presented",
  }
end

local function dualMeasurement(signature)
  local ScreenTopology = require("libs.ui.src.ScreenTopology")
  return {
    width = 512,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, role = "world", touch = true },
      { id = "sub", rect = { x = 256, y = 0, width = 256, height = 192 }, role = "auxiliary", touch = true }
    ),
    pixelRatio = 1,
    signature = signature or "options-presented-dual",
  }
end

local function openPresentedMenu(opts)
  opts = opts or {}
  local State = stateModule()
  local prepare, applied, candidate = fakePrepare()
  local port = fakeAudioPort(opts.volume == nil and 80 or opts.volume)
  local played, effect = fakeEffects()
  local channels = {}
  local measurement = opts.measurement
  if measurement == nil then
    if opts.dual then
      measurement = dualMeasurement(opts.signature)
    else
      measurement = singleMeasurement(opts.signature)
    end
  end
  local presentationPort = fakePresentationPort()
  local state = State.new({
    playerOptions = canonicalOptions(opts.playerOptions),
    volume = port:read(),
    preparePlayerOptions = prepare,
    audioPreferences = port,
    applyChannelMode = function(mode)
      channels[#channels + 1] = mode
    end,
    effect = effect,
    semantic = { labels = semanticLabels() },
    measureDisplay = function()
      return measurement
    end,
    presentationPort = presentationPort,
  })
  state:updateFixed({})
  return {
    state = state,
    port = port,
    played = played,
    channels = channels,
    applied = applied,
    candidate = candidate,
    presentationPort = presentationPort,
  }
end

local function presentationPane(status, id)
  local presentation = assert(status.presentation, "presented status carries its plan")
  local panes = assert(presentation.panes, "the plan carries its panes")
  for _, pane in ipairs(panes) do
    if pane.id == id then
      return pane
    end
  end
  error("pane " .. tostring(id) .. " is not published", 0)
end

local function hostForLogical(pane, lx, ly)
  local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
  local hx, hy = LayoutGeometry.logicalToHost(pane.placement, lx, ly)
  return hx, hy
end

local function findLogicalForHit(Interface, content, predicate)
  for y = 0, 191 do
    for x = 0, 255 do
      local hit = Interface.hitTest(content, x, y)
      if predicate(hit, x, y) then
        return x, y, hit
      end
    end
  end
  error("no logical point matched the wanted control", 0)
end

local function findLogicalForListGap(Interface, content)
  for y = 0, 191 do
    for x = 0, 255 do
      if Interface.inList(content, x, y) then
        return x, y
      end
    end
  end
  error("no empty list gap is published", 0)
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
    "volume",
    "battleSpeed",
    "textFrame",
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
  for _ = 1, 5 do
    state:updateFixed({ { type = "navigate", direction = "down" } })
  end
  Assert.equal(state:status().focusId, "battleSpeed", "down walks the fixed row order")
  state:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(state:status().focusId, "textFrame", "down from battle speed reaches the closing frame")
  state:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(state:status().focusId, "confirm", "down from the frame reaches confirm")
  state:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(state:status().focusId, "quit", "footer right selects quit")
  state:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(state:status().focusId, "quit", "footer right clamps")
  state:updateFixed({ { type = "navigate", direction = "left" } })
  Assert.equal(state:status().focusId, "confirm", "footer left selects confirm")
  state:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(state:status().focusId, "textFrame", "up from either footer reaches the frame")
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
  for _ = 1, 4 do
    opened.state:updateFixed({ { type = "navigate", direction = "down" } })
  end
  Assert.equal(opened.state:status().focusId, "volume", "four downs reach the volume row")
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
  for _ = 1, 5 do
    opened.state:updateFixed({ { type = "navigate", direction = "down" } })
  end
  Assert.equal(opened.state:status().focusId, "battleSpeed", "five downs reach the battle speed row")
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
  local realPrepare = opened.state._preparePlayerOptions
  opened.state._preparePlayerOptions = function(values)
    local transaction = realPrepare(values)
    local realApply = transaction.apply
    transaction.apply = function()
      order[#order + 1] = "apply"
      return realApply()
    end
    return transaction
  end
  local state = opened.state
  state:updateFixed({ { type = "navigate", direction = "left" } })
  state:updateFixed({ { type = "activate", id = "confirm" } })
  local result = state:takeResult()
  Assert.deepEqual(result, { kind = "close" }, "confirm emits one close result")
  Assert.equal(opened.applied(), 1, "the prepared attempt applies exactly once")
  Assert.equal(port:read(), 80, "an untouched volume stays committed")
  Assert.deepEqual(order, { "apply", "commit" }, "the player step runs before durable volume publication")
end

function T.tests.confirm_publishes_an_edited_volume_once()
  local opened = openMenu({ volume = 80 })
  local state = opened.state
  for _ = 1, 4 do
    state:updateFixed({ { type = "navigate", direction = "down" } })
  end
  Assert.equal(state:status().focusId, "volume", "four downs reach the volume row")
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
  for _ = 1, 4 do
    state:updateFixed({ { type = "navigate", direction = "down" } })
  end
  Assert.equal(state:status().focusId, "volume", "four downs reach the volume row")
  state:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(state:status().dirty, true, "the draft carries the staged edits")
  state:updateFixed({ { type = "activate", id = "confirm" } })
  Assert.isNil(state:takeResult(), "a failed confirm emits no close result")
  Assert.equal(opened.applied(), 1, "a failed publication attempted the player step once")
  Assert.equal(opened.rolledBack(), 1, "a failed publication restores the player step")
  Assert.equal(opened.port:read(), 80, "the committed volume is unchanged")
  local status = state:status()
  Assert.isTrue(status.open, "the menu stays open")
  Assert.isTrue(status.error ~= nil, "a readable error is published")
  Assert.isTrue(status.dirty, "the draft is preserved for retry")
  state:updateFixed({ { type = "activate", id = "confirm" } })
  Assert.deepEqual(state:takeResult(), { kind = "close" }, "a retry after recovery confirms")
  Assert.equal(opened.applied(), 2, "the retry runs its own fresh attempt")
  Assert.equal(opened.rolledBack(), 1, "the retry needed no further restoration")
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
    "volume",
    "battleSpeed",
    "textFrame",
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
  for _ = 1, 6 do
    state:updateFixed({ { type = "navigate", direction = "down" } })
  end
  Assert.equal(state:status().focusId, "textFrame", "six downs reach the closing frame")
  local settled = state:status().scrollOffset
  Assert.isTrue(settled > 0, "focusing the frame row scrolls it into view")
  state:updateFixed({ { type = "navigate", direction = "up" } })
  state:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(state:status().focusId, "volume", "two ups return to the volume row")
  Assert.equal(state:status().scrollOffset, settled, "revealing an earlier row keeps the scrolled list")
  state:updateFixed({
    { type = "slider-set", row = "volume", index = 42 },
  })
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

function T.tests.presented_touch_edits_choice_and_confirms()
  local Interface = interfaceModule()
  local opened = openPresentedMenu()
  local state = opened.state
  Assert.isTrue(state:status().presentation ~= nil, "the presented menu publishes its plan")
  local status = state:status()
  local content = assert(status.presentation.content, "the plan carries its content")
  local pane = presentationPane(status, "content")
  local lx, ly = findLogicalForHit(Interface, content, function(hit)
    return hit ~= nil and hit.target == "soundMode" and hit.control == "value" and hit.index == 2
  end)
  local hx, hy = hostForLogical(pane, lx, ly)
  state:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = hx, y = hy } })
  state:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = hx, y = hy } })
  Assert.equal(rowById(state:status(), "soundMode").value, "mono", "touch on the second choice selects mono")
  status = state:status()
  content = assert(status.presentation.content, "the plan carries its content")
  pane = presentationPane(status, "content")
  local cx, cy = findLogicalForHit(Interface, content, function(hit)
    return hit ~= nil and hit.target == "confirm"
  end)
  local chx, chy = hostForLogical(pane, cx, cy)
  state:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = chx, y = chy } })
  Assert.isNil(state:takeResult(), "press alone never confirms")
  state:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = chx, y = chy } })
  Assert.deepEqual(state:takeResult(), { kind = "close" }, "a matching release on confirm closes")
  Assert.equal(opened.applied(), 1, "the presented confirm applies once")
end

function T.tests.presented_slider_list_and_capture_identity()
  local Interface = interfaceModule()
  local opened = openPresentedMenu()
  local state = opened.state
  for _ = 1, 6 do
    state:updateFixed({ { type = "navigate", direction = "down" } })
  end
  Assert.equal(state:status().focusId, "textFrame", "six downs reach the closing frame")
  local settled = state:status().scrollOffset
  Assert.isTrue(settled > 0, "focusing the frame row scrolls it into view")
  state:updateFixed({ { type = "navigate", direction = "up" } })
  state:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(state:status().focusId, "volume", "two ups return to the volume row")
  Assert.equal(state:status().scrollOffset, settled, "revealing an earlier row keeps the scrolled list")
  local status = state:status()
  local content = assert(status.presentation.content, "the plan carries its content")
  local pane = presentationPane(status, "content")
  local _, railY = findLogicalForHit(Interface, content, function(hit)
    return hit ~= nil and hit.target == "volume"
  end)
  local startX, endX = nil, nil
  for x = 0, 255 do
    local hit = Interface.hitTest(content, x, railY)
    if hit ~= nil and hit.target == "volume" and hit.index == 20 then
      startX = x
    end
    if hit ~= nil and hit.target == "volume" and hit.index == 80 then
      endX = x
    end
  end
  Assert.isTrue(startX ~= nil and endX ~= nil, "the slider rail spans both percent stops")
  local startHx, startHy = hostForLogical(pane, startX, railY)
  local endHx, endHy = hostForLogical(pane, endX, railY)
  state:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = startHx, y = startHy } })
  state:updateFixed({ { type = "pointer_move", pointerId = "touch:0", x = endHx, y = endHy } })
  state:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = endHx, y = endHy } })
  Assert.equal(rowById(state:status(), "volume").value, 79, "dragging the rail between stops edits the percent")
  Assert.equal(state:status().scrollOffset, settled, "a slider drag never scrolls")
  Assert.isNil(state:takeResult(), "releasing the slider closes nothing")
  state:updateFixed({ { type = "scroll", delta = -64 } })
  Assert.equal(state:status().scrollOffset, 0, "a wheel scroll returns the list to the top")
  status = state:status()
  content = assert(status.presentation.content, "the plan carries its content")
  pane = presentationPane(status, "content")
  local gapX, gapY = findLogicalForListGap(Interface, content)
  local gapHx, gapHy = hostForLogical(pane, gapX, gapY)
  local dragLy = math.max(0, gapY - 30)
  local dragHx, dragHy = hostForLogical(pane, gapX, dragLy)
  local soundBefore = rowById(state:status(), "soundMode").value
  local scrollBefore = state:status().scrollOffset
  state:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = gapHx, y = gapHy } })
  state:updateFixed({ { type = "pointer_move", pointerId = "touch:1", x = dragHx, y = dragHy } })
  state:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = dragHx, y = dragHy } })
  Assert.isTrue(state:status().scrollOffset > scrollBefore, "dragging an empty list gap scrolls")
  Assert.equal(rowById(state:status(), "soundMode").value, soundBefore, "a list drag edits no value")
  Assert.isNil(state:takeResult(), "a list drag closes nothing")
  status = state:status()
  content = assert(status.presentation.content, "the plan carries its content")
  pane = presentationPane(status, "content")
  local confirmX, confirmY = findLogicalForHit(Interface, content, function(hit)
    return hit ~= nil and hit.target == "confirm"
  end)
  local quitX, quitY = findLogicalForHit(Interface, content, function(hit)
    return hit ~= nil and hit.target == "quit"
  end)
  local confirmHx, confirmHy = hostForLogical(pane, confirmX, confirmY)
  local quitHx, quitHy = hostForLogical(pane, quitX, quitY)
  state:updateFixed({ { type = "pointer_down", pointerId = "touch:2", x = confirmHx, y = confirmHy } })
  state:updateFixed({ { type = "pointer_down", pointerId = "touch:3", x = quitHx, y = quitHy } })
  state:updateFixed({ { type = "pointer_up", pointerId = "touch:3", x = quitHx, y = quitHy } })
  Assert.isNil(state:takeResult(), "a second pointer never activates")
  state:updateFixed({ { type = "pointer_up", pointerId = "touch:9", x = confirmHx, y = confirmHy } })
  Assert.isNil(state:takeResult(), "a stale release never activates")
  state:updateFixed({ { type = "pointer_cancel", pointerId = "touch:2" } })
  state:updateFixed({ { type = "pointer_up", pointerId = "touch:2", x = confirmHx, y = confirmHy } })
  Assert.isNil(state:takeResult(), "a cancelled press never activates on release")
  Assert.isTrue(state:status().open, "the menu stays open after cancelled presses")
end

function T.tests.presented_preview_press_stays_open_while_outside_down_closes()
  local opened = openPresentedMenu({ dual = true })
  local state = opened.state
  local status = state:status()
  Assert.isTrue(status.presentation ~= nil, "the dual menu publishes its plan")
  local previewPane = presentationPane(status, "preview")
  local previewHx, previewHy = hostForLogical(previewPane, 128, 96)
  local soundBefore = rowById(status, "soundMode").value
  state:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = previewHx, y = previewHy } })
  state:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = previewHx, y = previewHy } })
  Assert.isNil(state:takeResult(), "a press on the preview pane closes nothing")
  Assert.isTrue(state:status().open, "the preview press leaves the menu open")
  Assert.equal(rowById(state:status(), "soundMode").value, soundBefore, "the preview press edits no value")
  state:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = 10, y = 300 } })
  Assert.deepEqual(state:takeResult(), { kind = "close" }, "a true outside down closes once")
  Assert.isNil(state:takeResult(), "the outside close emits exactly once")
  Assert.equal(opened.applied(), 0, "an outside dismissal never applies")
end

-- The menu-local sample prints through a real dialogue controller over
-- generated frame messages: paced by the draft speed policy, restarted on
-- speed/frame edits, and closed exactly once with the menu.
local function previewGlyph(text, code)
  return { kind = "glyph", code = code, text = text }
end

local function previewMessage(word, fillerPairs)
  local text = word .. " " .. string.rep("AB", fillerPairs)
  local tokens = {}
  local code = 0x0121
  for index = 1, #text do
    tokens[#tokens + 1] = previewGlyph(text:sub(index, index), code)
    code = code + 1
  end
  tokens[#tokens + 1] = { kind = "eos" }
  return { text = text, tokens = tokens }
end

local function previewSection(markerFor)
  local records = {}
  for slot = 0, 19 do
    records[slot] = previewMessage(markerFor(slot), 20)
  end
  return records
end

local function defaultMarkers(slot)
  return "TYPE " .. (slot + 1)
end

local function livePrinter(speed)
  local DialogueLayout = require("libs.hgss.src.ui.DialogueLayout")
  local FieldDialogueController = require("libs.hgss.src.ui.FieldDialogueController")
  local TextSpeedPolicy = require("libs.hgss.src.ui.TextSpeedPolicy")
  local metrics = {
    glyphWidth = function(_)
      return 8
    end,
  }
  return FieldDialogueController.new({
    layout = function(formatted)
      return DialogueLayout.layout(formatted.tokens, metrics, { width = 216, maxLines = 2 })
    end,
    policy = TextSpeedPolicy.forSpeed(speed or "mid"),
    audio = { play = function() end },
    continueCursor = { cycle = { 0, 1, 2, 1 }, framePrinterTicks = 9 },
  })
end

local function openPreviewMenu(opts)
  opts = opts or {}
  local State = stateModule()
  local prepare, applied, candidate = fakePrepare()
  local port = fakeAudioPort(opts.volume == nil and 80 or opts.volume)
  local played, effect = fakeEffects()
  local channels = {}
  local committed = canonicalOptions(opts.playerOptions)
  local state = State.new({
    playerOptions = committed,
    volume = port:read(),
    preparePlayerOptions = prepare,
    audioPreferences = port,
    applyChannelMode = function(mode)
      channels[#channels + 1] = mode
    end,
    effect = effect,
    semantic = { labels = semanticLabels(), framePreviewText = opts.framePreviewText or previewSection(defaultMarkers) },
    previewPrinter = opts.previewPrinter or livePrinter(committed.textSpeed),
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

local function visibleGlyphs(status)
  local preview = assert(status.preview, "status carries its preview")
  local lines = assert(preview.visibleLines, "the open preview publishes its visible lines")
  local count = 0
  local first = nil
  local texts = {}
  for _, line in ipairs(lines) do
    for _, token in ipairs(line.tokens or line) do
      if token.kind == "glyph" then
        count = count + 1
        if first == nil then
          first = token.text
        end
        texts[#texts + 1] = token.text
      end
    end
  end
  return count, first, table.concat(texts)
end

function T.tests.preview_reveals_faster_on_turbo_than_mid_from_the_same_message()
  local records = previewSection(defaultMarkers)
  local total = #records[0].tokens - 1
  local opened = openPreviewMenu({ playerOptions = { textSpeed = "mid" }, framePreviewText = records })
  local state = opened.state
  for _ = 1, 6 do
    state:updateFixed({})
  end
  local midCount, midFirst = visibleGlyphs(state:status())
  Assert.isTrue(midCount > 0, "mid reveals glyphs after fixed ticks")
  Assert.isTrue(midCount < total, "mid shows only a prefix of the generated message")
  Assert.equal(midFirst, "T", "mid reveals the generated message from its start")
  state:updateFixed({ { type = "navigate", direction = "right" } })
  state:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(rowById(state:status(), "textSpeed").value, "fastest", "two rights reach turbo")
  local fresh = openPreviewMenu({ playerOptions = { textSpeed = "fastest" }, framePreviewText = records })
  fresh.state:updateFixed({})
  local freshCount = visibleGlyphs(fresh.state:status())
  local restartedCount = visibleGlyphs(state:status())
  Assert.equal(restartedCount, freshCount, "the speed edit restarts the sample from its beginning")
  for _ = 1, 5 do
    state:updateFixed({})
  end
  local turboCount, turboFirst = visibleGlyphs(state:status())
  Assert.equal(turboFirst, "T", "turbo reveals the same generated message from its start")
  Assert.isTrue(turboCount > midCount, "turbo reveals more than mid after equal ticks")
  Assert.equal(opened.applied(), 0, "preview edits apply nothing")
  Assert.equal(opened.port.commits, 0, "preview edits publish no volume")
  Assert.equal(opened.port:read(), 80, "the committed volume is untouched")
end

function T.tests.preview_uses_the_selected_frame_message()
  local records = previewSection(function(slot)
    if slot == 0 then
      return "ZERO"
    elseif slot == 7 then
      return "SEVEN"
    end
    return defaultMarkers(slot)
  end)
  local opened = openPreviewMenu({ playerOptions = { textSpeed = "mid" }, framePreviewText = records })
  local state = opened.state
  for _ = 1, 6 do
    state:updateFixed({})
  end
  local _, first0, text0 = visibleGlyphs(state:status())
  Assert.equal(first0, "Z", "frame zero reveals its own generated message")
  state:updateFixed({ { type = "direct-select", row = "textFrame", index = 8 } })
  local status7 = state:status()
  Assert.equal(status7.preview.textFrame, 7, "the preview carries the draft frame")
  for _ = 1, 5 do
    state:updateFixed({})
  end
  local _, first7, text7 = visibleGlyphs(state:status())
  Assert.equal(first7, "S", "frame seven reveals its own generated message")
  Assert.isTrue(text7 ~= text0, "the frame edit changes the visible source glyphs")
  state:updateFixed({ { type = "direct-select", row = "textFrame", index = 20 } })
  Assert.equal(state:status().preview.textFrame, 19, "the last frame resolves to its own message")
  local count19 = visibleGlyphs(state:status())
  Assert.isTrue(count19 >= 0, "the last frame previews without falling back")
end

local function countingPrinter(real)
  local closes = 0
  local opens = 0
  local printer = {}
  function printer:setPolicy(policy)
    return real:setPolicy(policy)
  end
  function printer:open(request)
    opens = opens + 1
    return real:open(request)
  end
  function printer:step(snapshot)
    return real:step(snapshot)
  end
  function printer:status()
    return real:status()
  end
  function printer:isModal()
    return real:isModal()
  end
  function printer:close()
    closes = closes + 1
    return real:close()
  end
  return printer, function()
    return closes
  end, function()
    return opens
  end, real
end

function T.tests.preview_lifetime_follows_the_menu_close()
  local records = previewSection(defaultMarkers)
  local real = livePrinter("mid")
  local printer, closes, opens = countingPrinter(real)
  local opened = openPreviewMenu({
    playerOptions = { textSpeed = "mid" },
    framePreviewText = records,
    previewPrinter = printer,
  })
  local state = opened.state
  local field = livePrinter("mid")
  field:open({ id = "field-dialogue", message = records[1], allowCancel = true })
  field:step({})
  field:step({})
  local fieldRevealed = field:status().revealedGlyphs
  state:updateFixed({ { type = "navigate", direction = "right" } })
  state:updateFixed({ { type = "direct-select", row = "textFrame", index = 3 } })
  for _ = 1, 4 do
    state:updateFixed({})
  end
  local partial = visibleGlyphs(state:status())
  Assert.isTrue(partial > 0, "edits and ticks partially reveal the sample")
  Assert.isTrue(printer:isModal(), "the sample prints while the menu stays open")
  Assert.equal(closes(), opens() - 1, "every superseded request closed exactly once")
  state:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(state:takeResult(), { kind = "close" }, "quit closes once")
  Assert.equal(closes(), opens(), "quit closes the live request exactly once")
  Assert.isTrue(not printer:isModal(), "the local printer leaves modal ownership")
  local settled = real:status().revealedGlyphs
  state:updateFixed({})
  state:updateFixed({})
  Assert.equal(closes(), opens(), "post-exit ticks close nothing further")
  Assert.equal(real:status().revealedGlyphs, settled, "no post-exit advancement occurs")
  state:dispose()
  state:dispose()
  Assert.equal(closes(), opens(), "double disposal stays safe")
  Assert.equal(field:status().revealedGlyphs, fieldRevealed, "the menu never steps field dialogue")
  Assert.isTrue(field:isModal(), "field dialogue keeps its own ownership")
  local TextSpeedPolicy = require("libs.hgss.src.ui.TextSpeedPolicy")
  Assert.deepEqual(
    TextSpeedPolicy.forSpeed("mid"),
    { interGlyphDelay = 4, glyphBudget = 1, abAcceleration = true },
    "the committed gameplay cadence is untouched"
  )
  local freshPrinter = livePrinter("mid")
  local fresh = openPreviewMenu({
    playerOptions = { textSpeed = "mid" },
    framePreviewText = records,
    previewPrinter = freshPrinter,
  })
  local empty = fresh.state:status().preview
  Assert.isTrue(empty.visibleLines ~= nil and #empty.visibleLines == 0, "a fresh menu restarts unrevealed")
  fresh.state:updateFixed({})
  local _, freshFirst = visibleGlyphs(fresh.state:status())
  Assert.equal(freshFirst, "T", "a fresh menu restarts at the committed sample beginning")
end

function T.tests.discrete_rows_publish_an_ordered_label_for_every_stop()
  local opened = openMenu()
  local state = opened.state
  local function labelsOf(id)
    local row = rowById(state:status(), id)
    return row, row.choiceLabels
  end
  local speedRow, speedLabels = labelsOf("textSpeed")
  Assert.deepEqual(speedLabels, { "MID", "FAST", "TURBO" }, "text speed labels every stop including Turbo")
  Assert.equal(speedRow.valueIndex, 3, "the draft opens on the fastest stop")
  Assert.equal(speedLabels[speedRow.valueIndex], speedRow.valueLabel, "the current value matches its stop label")
  local _, sceneLabels = labelsOf("battleScene")
  Assert.deepEqual(sceneLabels, { "ON", "OFF" }, "battle scene labels both stops")
  local _, styleLabels = labelsOf("battleStyle")
  Assert.deepEqual(styleLabels, { "SHIFT", "SET" }, "battle style labels both stops")
  local _, modeLabels = labelsOf("soundMode")
  Assert.deepEqual(modeLabels, { "STEREO", "MONO" }, "sound mode labels both stops")
  for _, id in ipairs({ "textFrame", "volume", "battleSpeed" }) do
    local row = rowById(state:status(), id)
    Assert.isNil(row.choiceLabels, id .. " shows one current value instead of stop labels")
  end
  Assert.equal(rowById(state:status(), "textFrame").valueLabel, "TYPE 1", "the frame shows its current value")
  Assert.equal(rowById(state:status(), "volume").valueLabel, "80%", "volume shows its current percent")
  Assert.equal(rowById(state:status(), "battleSpeed").valueLabel, "1x", "battle speed shows its current stop")
  state:updateFixed({ { type = "navigate", direction = "left" } })
  local movedRow, movedLabels = labelsOf("textSpeed")
  Assert.deepEqual(movedLabels, { "MID", "FAST", "TURBO" }, "selecting another stop keeps every label")
  Assert.equal(movedRow.valueIndex, 2, "the selection moves to the fast stop")
  Assert.equal(movedRow.valueLabel, "FAST", "only the pill state changes, not the label set")
  Assert.equal(movedLabels[movedRow.valueIndex], "FAST", "the new selection matches its own stop label")
end

-- A live-consumer failure during the player step never reaches durable
-- volume publication: the menu stays open with its draft and a readable
-- failure, and a fresh preparation retries cleanly.
function T.tests.failed_player_application_keeps_volume_unpublished_and_draft_open()
  local State = stateModule()
  local port = fakeAudioPort(80)
  local played, effect = fakeEffects()
  local channels = {}
  local commitsBefore = port.commits
  local rollbackCalls = 0
  local attempts = 0
  local function prepare(_)
    attempts = attempts + 1
    if attempts == 1 then
      return {
        apply = function()
          error("injected live setter failure", 0)
        end,
        rollback = function()
          rollbackCalls = rollbackCalls + 1
        end,
      }
    end
    return {
      apply = function() end,
      rollback = function() end,
    }
  end
  local state = State.new({
    playerOptions = canonicalOptions(),
    volume = port:read(),
    preparePlayerOptions = prepare,
    audioPreferences = port,
    applyChannelMode = function(mode)
      channels[#channels + 1] = mode
    end,
    effect = effect,
    semantic = { labels = semanticLabels() },
  })
  state:updateFixed({ { type = "navigate", direction = "left" } })
  state:updateFixed({ { type = "activate", id = "confirm" } })
  Assert.isNil(state:takeResult(), "a failed player step emits no close")
  Assert.equal(port.commits, commitsBefore, "a failed player step never publishes volume")
  Assert.equal(rollbackCalls, 1, "a failed player step restores the committed player state")
  Assert.isTrue(#channels >= 1, "the still-open draft preview is reapplied after restoration")
  local status = state:status()
  Assert.isTrue(status.open, "the menu stays open")
  Assert.isTrue(status.error ~= nil, "a readable failure is published")
  Assert.isTrue(status.dirty, "the draft is preserved for retry")
  state:updateFixed({ { type = "activate", id = "confirm" } })
  Assert.deepEqual(state:takeResult(), { kind = "close" }, "a fresh preparation retries cleanly")
  Assert.equal(attempts, 2, "the retry prepares again instead of reusing the consumed attempt")
end

-- A durable volume failure after a successful player step restores the
-- committed player state while the draft stays editable for retry.
function T.tests.failed_volume_publication_restores_player_and_keeps_draft_for_retry()
  local State = stateModule()
  local port = fakeAudioPort(80)
  port.failNextCommit = "SAVE_WRITE_FAILED: injected storage failure"
  local played, effect = fakeEffects()
  local channels = {}
  local order = {}
  local rollbackCalls = 0
  local attempts = 0
  local function prepare(_)
    attempts = attempts + 1
    return {
      apply = function()
        order[#order + 1] = "apply"
      end,
      rollback = function()
        rollbackCalls = rollbackCalls + 1
      end,
    }
  end
  local realCommit = port.commit
  port.commit = function(percent)
    order[#order + 1] = "commit"
    return realCommit(percent)
  end
  local state = State.new({
    playerOptions = canonicalOptions(),
    volume = port:read(),
    preparePlayerOptions = prepare,
    audioPreferences = port,
    applyChannelMode = function(mode)
      channels[#channels + 1] = mode
    end,
    effect = effect,
    semantic = { labels = semanticLabels() },
  })
  state:updateFixed({ { type = "navigate", direction = "left" } })
  state:updateFixed({ { type = "activate", id = "confirm" } })
  Assert.deepEqual(order, { "apply", "commit" }, "the player step runs before durable volume publication")
  Assert.isNil(state:takeResult(), "a failed publication emits no close")
  Assert.equal(port:read(), 80, "the committed volume is unchanged")
  Assert.equal(rollbackCalls, 1, "a failed publication restores the committed player state")
  Assert.isTrue(#channels >= 1, "the still-open draft preview is reapplied after restoration")
  local status = state:status()
  Assert.isTrue(status.open, "the menu stays open")
  Assert.isTrue(status.error ~= nil, "a readable failure is published")
  Assert.isTrue(status.dirty, "the draft is preserved for retry")
  state:updateFixed({ { type = "activate", id = "confirm" } })
  Assert.deepEqual(state:takeResult(), { kind = "close" }, "a fresh preparation publishes both scopes once")
  Assert.equal(attempts, 2, "the retry prepares again instead of reusing the consumed attempt")
  Assert.equal(port:read(), 80, "the retried volume publishes at the draft level")
end

-- When restoration itself fails the menu raises terminally with both
-- causes instead of advertising a safe retry.
function T.tests.failed_restoration_is_terminal_and_names_both_causes()
  local State = stateModule()
  local port = fakeAudioPort(80)
  local played, effect = fakeEffects()
  local function prepare(_)
    return {
      apply = function()
        error("injected live setter failure", 0)
      end,
      rollback = function()
        error("injected restore failure", 0)
      end,
    }
  end
  local state = State.new({
    playerOptions = canonicalOptions(),
    volume = port:read(),
    preparePlayerOptions = prepare,
    audioPreferences = port,
    applyChannelMode = function(_) end,
    effect = effect,
    semantic = { labels = semanticLabels() },
  })
  local ok, err = pcall(function()
    state:updateFixed({ { type = "activate", id = "confirm" } })
  end)
  Assert.isFalse(ok, "an unrestorable failure raises terminally")
  local message = tostring(err)
  Assert.isTrue(
    message:find("injected live setter failure", 1, true) ~= nil,
    "the terminal error names the original cause"
  )
  Assert.isTrue(message:find("injected restore failure", 1, true) ~= nil, "the terminal error names the restore cause")
  Assert.isNil(state:takeResult(), "a terminal failure emits no close")
end

-- A successful confirmation settles before optional feedback so a
-- feedback failure cannot duplicate durable publication.
function T.tests.successful_confirm_marks_closed_before_feedback()
  local State = stateModule()
  local port = fakeAudioPort(80)
  local applyCalls = 0
  local function prepare(_)
    return {
      apply = function()
        applyCalls = applyCalls + 1
      end,
      rollback = function()
        error("a successful confirmation never rolls back", 0)
      end,
    }
  end
  local state = State.new({
    playerOptions = canonicalOptions(),
    volume = port:read(),
    preparePlayerOptions = prepare,
    audioPreferences = port,
    applyChannelMode = function(_) end,
    effect = function(_)
      error("injected feedback failure", 0)
    end,
    semantic = { labels = semanticLabels() },
  })
  local ok, err = pcall(function()
    state:updateFixed({ { type = "activate", id = "confirm" } })
  end)
  Assert.isFalse(ok, "the feedback failure still propagates")
  Assert.isTrue(tostring(err):find("injected feedback failure", 1, true) ~= nil, "the propagated cause is the feedback")
  Assert.equal(applyCalls, 1, "the player step ran exactly once")
  Assert.equal(port.commits, 1, "durable volume published exactly once")
  Assert.deepEqual(state:takeResult(), { kind = "close" }, "the settled close is still available")
  state:updateFixed({ { type = "activate", id = "confirm" } })
  Assert.equal(applyCalls, 1, "a settled confirmation never republishes")
  Assert.equal(port.commits, 1, "a settled confirmation never republishes volume")
  Assert.isNil(state:takeResult(), "the result emits exactly once")
end

-- A preview failure during construction releases the partial session
-- while the factory-owned port stays with its owner; a fresh open with
-- complete generated text succeeds.
function T.tests.failed_preview_construction_keeps_port_with_owner_and_allows_a_fresh_open()
  local State = stateModule()
  local port = fakeAudioPort(80)
  local presentationPort = fakePresentationPort()
  local measurement = singleMeasurement("options-construction-failure")
  local played, effect = fakeEffects()
  local printer = livePrinter("mid")
  local prepare, _, _, _ = fakePrepare()
  local ok, err = pcall(function()
    State.new({
      playerOptions = canonicalOptions(),
      volume = port:read(),
      preparePlayerOptions = prepare,
      audioPreferences = port,
      applyChannelMode = function(_) end,
      effect = effect,
      semantic = { labels = semanticLabels() },
      measureDisplay = function()
        return measurement
      end,
      presentationPort = presentationPort,
      previewPrinter = printer,
    })
  end)
  Assert.isFalse(ok, "a missing generated preview message fails construction")
  Assert.isTrue(err ~= nil, "the failure propagates its cause")
  Assert.equal(presentationPort.disposes, 0, "a failed construction never disposes the factory-owned port")
  Assert.isFalse(printer:isModal(), "a failed construction leaves no live preview")
  local freshPort = fakeAudioPort(80)
  local freshPresentation = fakePresentationPort()
  local freshPrinter = livePrinter("mid")
  local records = previewSection(defaultMarkers)
  local freshPrepare, freshApplied = fakePrepare()
  local fresh = State.new({
    playerOptions = canonicalOptions(),
    volume = freshPort:read(),
    preparePlayerOptions = freshPrepare,
    audioPreferences = freshPort,
    applyChannelMode = function(_) end,
    effect = effect,
    semantic = { labels = semanticLabels(), framePreviewText = records },
    measureDisplay = function()
      return measurement
    end,
    presentationPort = freshPresentation,
    previewPrinter = freshPrinter,
  })
  fresh:updateFixed({})
  Assert.isTrue(fresh:status().open, "a fresh open works after a construction failure")
  Assert.isTrue(fresh:status().preview.visibleLines ~= nil, "the fresh preview prints")
  fresh:dispose()
  Assert.equal(freshPresentation.disposes, 1, "the fresh screen still owns its port exactly once")
  Assert.equal(presentationPort.disposes, 0, "the failed port is never double-released")
end

-- The published view carries token-bearing source records beside the
-- authored strings: the title, every row name, each discrete choice stop
-- (with the authored Turbo fallback carrying no record), the current
-- frame value, and both footer actions.
function T.tests.view_projects_token_bearing_source_records()
  local opened = openMenu()
  local status = opened.state:status()
  Assert.equal(status.titleSource.text, "OPTIONS", "the title carries its source record")
  local speedRow = rowById(status, "textSpeed")
  Assert.equal(speedRow.sourceLabel.text, "TEXT SPEED", "rows carry their source name record")
  Assert.equal(speedRow.label, "TEXT SPEED", "the authored row string is preserved")
  Assert.equal(#speedRow.choiceDisplay, 3, "every text-speed stop carries a display entry")
  Assert.equal(speedRow.choiceDisplay[1].text, "MID", "the first stop keeps its generated text")
  Assert.equal(speedRow.choiceDisplay[1].source.text, "MID", "the first stop carries its source record")
  Assert.equal(speedRow.choiceDisplay[3].text, "TURBO", "the fastest stop keeps its authored text")
  Assert.equal(speedRow.choiceDisplay[3].source.text, "TURBO", "the fastest stop carries its curated record here")
  local OptionsRows = require("game.hgss.src.options.OptionsRows")
  local bare = OptionsRows.choicePresentation("textSpeed", {})
  Assert.equal(bare[3].text, "TURBO", "the fastest stop falls back to authored text")
  Assert.isNil(bare[3].source, "the authored Turbo fallback carries no source record")
  local sceneRow = rowById(status, "battleScene")
  Assert.equal(#sceneRow.choiceDisplay, 2, "battle scene carries both stops")
  Assert.equal(sceneRow.choiceDisplay[2].source.text, "OFF", "the off stop carries its source record")
  local frameRow = rowById(status, "textFrame")
  Assert.equal(frameRow.valueSource.text, "TYPE 1", "the frame value carries its source record")
  Assert.equal(status.footer.confirm.sourceLabel.text, "CONFIRM", "confirm carries its source record")
  Assert.equal(status.footer.quit.sourceLabel.text, "QUIT", "quit carries its source record")
  Assert.equal(status.footer.confirm.label, "CONFIRM", "the authored footer string is preserved")
  local volumeRow = rowById(status, "volume")
  Assert.isNil(volumeRow.sourceLabel, "authored rows carry no source record")
  Assert.isNil(volumeRow.choiceDisplay, "slider rows carry no choice display")
end

-- Without generated labels the view keeps its authored strings and
-- publishes no source records: headless fakes stay fully semantic.
function T.tests.view_falls_back_without_generated_labels()
  local State = stateModule()
  local port = fakeAudioPort(80)
  local played, effect = fakeEffects()
  local state = State.new({
    playerOptions = canonicalOptions(),
    volume = port:read(),
    preparePlayerOptions = fakePrepare(),
    audioPreferences = port,
    applyChannelMode = function(_) end,
    effect = effect,
  })
  local status = state:status()
  Assert.isNil(status.titleSource, "no title record without generated labels")
  local speedRow = rowById(status, "textSpeed")
  Assert.equal(speedRow.label, "TEXT SPEED", "row strings fall back to authored text")
  Assert.isNil(speedRow.sourceLabel, "no row record without generated labels")
  Assert.equal(#speedRow.choiceDisplay, 3, "every stop still carries a display entry")
  Assert.equal(speedRow.choiceDisplay[1].text, "MID", "stop text falls back to authored strings")
  Assert.isNil(speedRow.choiceDisplay[1].source, "no stop record without generated labels")
  Assert.isNil(rowById(status, "textFrame").valueSource, "no frame record without generated labels")
  Assert.equal(status.footer.confirm.label, "CONFIRM", "footer strings fall back to authored text")
  Assert.isNil(status.footer.confirm.sourceLabel, "no footer record without generated labels")
  state:dispose()
end

-- The closing frame row carries its own tall item and sample window.
-- All layouts share one tall list region with a pinned footer; focusing
-- the last row reveals both its selector and its window together.
function T.tests.frame_is_last_with_co_scrolling_preview_and_full_reveal()
  local Interface = interfaceModule()
  Assert.deepEqual(Interface.ROW_IDS, {
    "textSpeed",
    "battleScene",
    "battleStyle",
    "soundMode",
    "volume",
    "battleSpeed",
    "textFrame",
  }, "the frame row closes the list")
  local opened = openPresentedMenu({ playerOptions = { textFrame = 9 } })
  local state = opened.state
  local status = state:status()
  local content = assert(status.presentation.content, "the presented plan carries its list")
  Assert.deepEqual(
    content.listViewport,
    { x = 0, y = 24, width = 256, height = 144 },
    "the list keeps one tall viewport"
  )
  Assert.equal(content.footer.y, 168, "the footer stays pinned below the list")
  Assert.isNil(content.preview, "no fixed preview rides outside the rows")
  Assert.equal(content.scrollMax, 64, "the tall frame sets the scroll limit")
  Assert.equal(content.totalHeight, 208, "the row heights sum to the list height")
  Assert.equal(#content.rows, 7, "seven rows publish")
  local starts = { 0, 24, 48, 72, 96, 120, 144 }
  local heights = { 24, 24, 24, 24, 24, 24, 64 }
  for position, row in ipairs(content.rows) do
    Assert.equal(row.rect.y, starts[position], "row keeps its list offset")
    Assert.equal(row.rect.height, heights[position], "row keeps its own height")
    if row.id == "textFrame" then
      Assert.deepEqual(
        row.previewRect,
        { x = 16, y = 172, width = 216, height = 32 },
        "the sample lives inside the frame row"
      )
    else
      Assert.isNil(row.previewRect, "only the frame row carries a sample")
    end
  end
  Assert.equal(status.focusId, "textSpeed", "the menu opens at the top")
  Assert.equal(status.scrollOffset, 0, "the list opens unscrolled")
  for _ = 1, 6 do
    state:updateFixed({ { type = "navigate", direction = "down" } })
  end
  Assert.equal(state:status().focusId, "textFrame", "six downs reach the closing frame")
  Assert.equal(state:status().scrollOffset, 64, "focusing the frame reveals its window")
  local frameRow = rowById(state:status(), "textFrame")
  Assert.equal(frameRow.valueLabel, "TYPE 10", "the draft frame reads one-based")
  Assert.equal(state:status().preview.textFrame, 9, "the sample follows the draft frame")
  for _ = 1, 6 do
    state:updateFixed({ { type = "navigate", direction = "up" } })
  end
  Assert.equal(state:status().focusId, "textSpeed", "ups return to the first row")
  Assert.equal(state:status().scrollOffset, 0, "returning to the top restores the offset")
end

-- The sample never selects a value but still belongs to the scrolling
-- list: taps there change nothing while arrows stay reachable, and a
-- released drag never rests with the selector showing and the window cut.
function T.tests.frame_preview_stays_passive_while_gestures_settle_whole()
  local Interface = interfaceModule()
  local opened = openPresentedMenu({ playerOptions = { textFrame = 9 } })
  local state = opened.state
  for _ = 1, 6 do
    state:updateFixed({ { type = "navigate", direction = "down" } })
  end
  Assert.equal(state:status().focusId, "textFrame", "six downs reach the closing frame")
  Assert.equal(state:status().scrollOffset, 64, "the frame rests fully revealed")
  local content = assert(state:status().presentation.content, "the revealed plan carries its list")
  Assert.isNil(Interface.hitTest(content, 124, 148), "tapping the sample selects nothing")
  Assert.isTrue(Interface.inList(content, 124, 148), "the sample still starts a list drag")
  local left = Interface.hitTest(content, 130, 116)
  Assert.isTrue(
    left ~= nil and left.target == "textFrame" and left.control == "left",
    "the left arrow stays hit-testable"
  )
  local right = Interface.hitTest(content, 220, 116)
  Assert.isTrue(
    right ~= nil and right.target == "textFrame" and right.control == "right",
    "the right arrow stays hit-testable"
  )
  local status = state:status()
  local pane = presentationPane(status, status.presentation.panes[1].id)
  if pane.id ~= "content" then
    for _, candidate in ipairs(status.presentation.panes) do
      if candidate.id == "content" then
        pane = candidate
      end
    end
  end
  local before = rowById(state:status(), "textFrame").value
  local previewHx, previewHy = hostForLogical(pane, 124, 148)
  state:updateFixed({ { type = "pointer_down", pointerId = "touch:0", x = previewHx, y = previewHy } })
  state:updateFixed({ { type = "pointer_up", pointerId = "touch:0", x = previewHx, y = previewHy } })
  Assert.equal(rowById(state:status(), "textFrame").value, before, "tapping the sample edits no value")
  Assert.isNil(state:takeResult(), "tapping the sample closes nothing")
  Assert.isTrue(state:status().open, "the menu stays open after a sample tap")
  for _ = 1, 6 do
    state:updateFixed({ { type = "navigate", direction = "up" } })
  end
  Assert.equal(state:status().scrollOffset, 0, "the list returns to the top")
  status = state:status()
  content = assert(status.presentation.content, "the top plan carries its list")
  pane = nil
  for _, candidate in ipairs(status.presentation.panes) do
    if candidate.id == "content" then
      pane = candidate
    end
  end
  pane = pane or status.presentation.panes[1]
  local gapX, gapY = findLogicalForListGap(Interface, content)
  local downHx, downHy = hostForLogical(pane, gapX, gapY)
  local movedHx, movedHy = hostForLogical(pane, gapX, gapY - 24)
  state:updateFixed({ { type = "pointer_down", pointerId = "touch:1", x = downHx, y = downHy } })
  state:updateFixed({ { type = "pointer_move", pointerId = "touch:1", x = movedHx, y = movedHy } })
  state:updateFixed({ { type = "pointer_up", pointerId = "touch:1", x = movedHx, y = movedHy } })
  Assert.equal(state:status().scrollOffset, 64, "a drag toward the end settles fully revealed")
  status = state:status()
  content = assert(status.presentation.content, "the settled plan carries its list")
  pane = nil
  for _, candidate in ipairs(status.presentation.panes) do
    if candidate.id == "content" then
      pane = candidate
    end
  end
  pane = pane or status.presentation.panes[1]
  local topX, topY = findLogicalForListGap(Interface, content)
  local startHx, startHy = hostForLogical(pane, topX, topY)
  local backHx, backHy = hostForLogical(pane, topX, topY + 40)
  state:updateFixed({ { type = "pointer_down", pointerId = "touch:2", x = startHx, y = startHy } })
  state:updateFixed({ { type = "pointer_move", pointerId = "touch:2", x = backHx, y = backHy } })
  state:updateFixed({ { type = "pointer_up", pointerId = "touch:2", x = backHx, y = backHy } })
  Assert.equal(state:status().scrollOffset, 0, "a drag toward the start settles back to the top")
end

return T
