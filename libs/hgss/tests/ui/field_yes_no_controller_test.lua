local Assert = require("tests.support.Assert")
local Controller = require("libs.hgss.src.ui.FieldYesNoController")

local T = {}

local function open()
  local controller = Controller.new()
  controller:open({ yesText = "sim", noText = "nao", frameIndex = 2 })
  return controller
end

local function recorder()
  local plays = {}
  local audio = {}
  function audio:play(sequence)
    plays[#plays + 1] = sequence
  end
  return audio, plays
end

local function openWithAudio()
  local audio, plays = recorder()
  local controller = Controller.new({ audio = audio })
  controller:open({ yesText = "sim", noText = "nao", frameIndex = 2 })
  return controller, plays
end

function T.initial_selection_and_no_wrap()
  local controller = open()
  Assert.equal(controller:status().selectedIndex, 0)
  controller:handleEvent({ type = "navigate", direction = "up" })
  Assert.equal(controller:status().selectedIndex, 0)
  controller:handleEvent({ type = "navigate", direction = "down" })
  controller:handleEvent({ type = "navigate", direction = "down" })
  Assert.equal(controller:status().selectedIndex, 1)
  controller:handleEvent({ type = "navigate", direction = "left" })
  Assert.equal(controller:status().selectedIndex, 1)
  controller:handleEvent({ type = "navigate", direction = "right" })
  Assert.equal(controller:status().selectedIndex, 1)
end

function T.focus_selects_the_touched_row()
  local controller = open()
  controller:handleEvent({ type = "focus", row = 1 })
  Assert.equal(controller:status().selectedIndex, 1)
  controller:handleEvent({ type = "focus", row = 0 })
  Assert.equal(controller:status().selectedIndex, 0)
end

function T.action_and_cancel_return_the_selected_semantics()
  local controller = open()
  controller:handleEvent({ type = "confirm" })
  Assert.deepEqual(controller:takeResult(), { accepted = true })
  Assert.isNil(controller:takeResult())
  controller:close()
  controller:open({ yesText = "sim", noText = "nao" })
  controller:handleEvent({ type = "navigate", direction = "down" })
  controller:handleEvent({ type = "confirm" })
  Assert.deepEqual(controller:takeResult(), { accepted = false })
  controller:close()
  controller:open({ yesText = "sim", noText = "nao" })
  controller:handleEvent({ type = "cancel" })
  Assert.deepEqual(controller:takeResult(), { accepted = false })
end

function T.closed_choice_ignores_events()
  local controller = open()
  controller:close()
  controller:handleEvent({ type = "confirm" })
  Assert.isNil(controller:takeResult())
end

function T.selection_change_plays_the_dialogue_advance_sound()
  local controller, plays = openWithAudio()
  controller:handleEvent({ type = "navigate", direction = "down" })
  Assert.deepEqual(plays, { "SEQ_SE_DP_SELECT" })
  controller:handleEvent({ type = "navigate", direction = "up" })
  Assert.deepEqual(plays, { "SEQ_SE_DP_SELECT", "SEQ_SE_DP_SELECT" })
  controller:handleEvent({ type = "focus", row = 1 })
  Assert.deepEqual(plays, { "SEQ_SE_DP_SELECT", "SEQ_SE_DP_SELECT", "SEQ_SE_DP_SELECT" })
end

function T.selection_no_ops_stay_silent()
  local controller, plays = openWithAudio()
  controller:handleEvent({ type = "navigate", direction = "up" })
  controller:handleEvent({ type = "navigate", direction = "left" })
  controller:handleEvent({ type = "navigate", direction = "right" })
  controller:handleEvent({ type = "focus", row = 0 })
  Assert.deepEqual(plays, {})
  controller:handleEvent({ type = "navigate", direction = "down" })
  Assert.deepEqual(plays, { "SEQ_SE_DP_SELECT" })
  controller:handleEvent({ type = "navigate", direction = "down" })
  controller:handleEvent({ type = "focus", row = 1 })
  Assert.deepEqual(plays, { "SEQ_SE_DP_SELECT" })
end

function T.confirm_and_cancel_play_the_dialogue_advance_sound()
  local controller, plays = openWithAudio()
  controller:handleEvent({ type = "confirm" })
  Assert.deepEqual(plays, { "SEQ_SE_DP_SELECT" })
  Assert.deepEqual(controller:takeResult(), { accepted = true })
  controller:handleEvent({ type = "navigate", direction = "down" })
  controller:handleEvent({ type = "cancel" })
  Assert.deepEqual(controller:takeResult(), { accepted = false })
  Assert.deepEqual(plays, { "SEQ_SE_DP_SELECT", "SEQ_SE_DP_SELECT", "SEQ_SE_DP_SELECT" })
end

function T.choice_without_audio_stays_silent()
  local controller = open()
  controller:handleEvent({ type = "navigate", direction = "down" })
  controller:handleEvent({ type = "confirm" })
  Assert.deepEqual(controller:takeResult(), { accepted = false })
end

function T.closed_choice_plays_no_sound()
  local controller, plays = openWithAudio()
  controller:close()
  controller:handleEvent({ type = "navigate", direction = "down" })
  controller:handleEvent({ type = "confirm" })
  controller:handleEvent({ type = "cancel" })
  Assert.deepEqual(plays, {})
end

return { tests = T }
