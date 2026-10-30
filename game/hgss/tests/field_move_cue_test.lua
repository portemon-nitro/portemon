-- Field-move cue service: validates what the scripts ask it to present and
-- holds every cue until the presentation reports it finished, so the
-- field-move scripts block on the cue wait task and poll the effect's done
-- variable. Tests stand in for the presentation by finishing while stepping.

local Assert = require("tests.support.Assert")
local FieldMoveCue = require("game.hgss.src.field.FieldMoveCue")

local T = {}

function T.blocking_cues_stay_pending_until_the_presentation_finishes_them()
  local cue = FieldMoveCue.new()
  Assert.isTrue(cue:isBlockingCueFinished(), "an idle cue reports finished")
  cue:startCutIn(2)
  Assert.isFalse(cue:isBlockingCueFinished(), "a started cut-in blocks the script")
  cue:finishBlockingCue()
  Assert.isTrue(cue:isBlockingCueFinished())
  cue:startFollowerGesture("jump", 2)
  Assert.isFalse(cue:isBlockingCueFinished())
  cue:finishBlockingCue()
  cue:startFollowerGesture("grow_shrink")
  Assert.isFalse(cue:isBlockingCueFinished())
  cue:finishBlockingCue()
  cue:startFollowerGesture("flash", 16, 2)
  Assert.isFalse(cue:isBlockingCueFinished())
  cue:finishBlockingCue()
  cue:startEmoteMark(true)
  Assert.isFalse(cue:isBlockingCueFinished(), "the emote mark blocks the script")
  cue:finishBlockingCue()
  cue:startEmoteMark(false)
  Assert.isFalse(cue:isBlockingCueFinished())
  cue:finishBlockingCue()
  Assert.isTrue(cue:isBlockingCueFinished())
  cue:finishBlockingCue()
  Assert.isTrue(cue:isBlockingCueFinished(), "finishing while idle stays finished")
end

function T.effects_stay_pending_until_finish_effects_fires_each_callback_once()
  local cue = FieldMoveCue.new()
  local finished = 0
  cue:startEffect(4, function()
    finished = finished + 1
  end)
  Assert.equal(finished, 0, "the effect must not complete synchronously")
  Assert.equal(cue:pendingEffectCount(), 1)
  Assert.isTrue(cue:isBlockingCueFinished(), "effects never block the cue wait")
  cue:finishEffects()
  Assert.equal(finished, 1, "the presentation completes the effect once")
  Assert.equal(cue:pendingEffectCount(), 0)
  cue:finishEffects()
  Assert.equal(finished, 1, "completing twice never refires")
  cue:addFollowerMood(20)
  Assert.isTrue(cue:isBlockingCueFinished(), "mood never blocks")
end

function T.malformed_cue_requests_fail_loudly()
  local cue = FieldMoveCue.new()
  Assert.throws(function()
    cue:startCutIn(6)
  end)
  Assert.throws(function()
    cue:startEffect(6, function() end)
  end)
  Assert.throws(function()
    cue:startFollowerGesture("spin")
  end)
  Assert.throws(function()
    cue:startEmoteMark(nil)
  end)
end

return { tests = T }
