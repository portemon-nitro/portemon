-- Script runtime coverage for the field-move cue operations: the cut-in,
-- the effect cue that completes a polled variable, the follower gestures,
-- and the small mon/follower/text operations the field-move scripts need.
-- Each handler calls one named operation on its injected collaborator.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Runtime = require("libs.script.src.Runtime")
local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")

local T = {}

local function var(id)
  return { value = "var", id = id }
end

local function cueDouble(finished)
  local cue = { calls = {}, finished = finished ~= false, pendingFinish = nil }
  function cue:startCutIn(slot)
    self.calls[#self.calls + 1] = { "cutIn", slot }
  end
  function cue:startFollowerGesture(gesture, a, b)
    self.calls[#self.calls + 1] = { "gesture", gesture, a, b }
  end
  function cue:startEffect(kind, onFinished)
    self.calls[#self.calls + 1] = { "effect", kind }
    self.pendingFinish = onFinished
  end
  function cue:startEmoteMark(onFollower)
    self.calls[#self.calls + 1] = { "emote", onFollower }
  end
  function cue:addFollowerMood(amount)
    self.calls[#self.calls + 1] = { "mood", amount }
  end
  function cue:isBlockingCueFinished()
    return self.finished
  end
  return cue
end

local function runWith(services, vars)
  local stored = vars or {}
  services.world = {
    getVar = function(_, id)
      return stored[id]
    end,
    setVar = function(_, id, value)
      stored[id] = value
    end,
  }
  return {
    instance = { scriptId = "test.cue", locals = {}, textArgs = {} },
    services = services,
    semantics = RuntimeValues,
    scheduler = {
      createTask = function(self, taskType, spec)
        self.created = { taskType = taskType, spec = spec }
        return "task:" .. taskType
      end,
    },
    tick = 1,
    input = {},
  },
    stored
end

function T.cut_in_starts_the_cue_with_the_evaluated_party_slot_and_continues_when_finished()
  local cue = cueDouble(true)
  local run = runWith({ fieldMoveCue = cue }, { [0x8004] = 2 })
  Assert.equal(Runtime.executeNode({ op = "field_move_cut_in", slot = var(0x8004) }, run), Runtime.OUTCOME_CONTINUE)
  Assert.deepEqual(cue.calls, { { "cutIn", 2 } })
end

function T.an_unfinished_blocking_cue_blocks_on_the_cue_wait_task()
  local cue = cueDouble(false)
  local run = runWith({ fieldMoveCue = cue })
  Assert.equal(Runtime.executeNode({ op = "field_move_cut_in", slot = 1 }, run), Runtime.OUTCOME_BLOCK)
  Assert.equal(run.scheduler.created.taskType, "field_move_cue_wait")
  local gesture = runWith({ fieldMoveCue = cueDouble(false) })
  Assert.equal(
    Runtime.executeNode({ op = "follower_gesture", gesture = "jump", a = 2 }, gesture),
    Runtime.OUTCOME_BLOCK
  )
end

function T.effect_clears_the_done_variable_and_the_cue_completes_it_later()
  local cue = cueDouble(true)
  local run, stored = runWith({ fieldMoveCue = cue }, { [0x8005] = 7 })
  local node = { op = "field_move_effect", effect = 3, done = var(0x8005) }
  Assert.equal(Runtime.executeNode(node, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(stored[0x8005], 0, "the script polls a cleared variable until the cue completes")
  Assert.deepEqual(cue.calls, { { "effect", 3 } })
  cue.pendingFinish()
  Assert.equal(stored[0x8005], 1, "completion writes the polled variable through the world")
end

function T.follower_gesture_and_mood_reach_the_cue()
  local cue = cueDouble(true)
  local run = runWith({ fieldMoveCue = cue })
  Runtime.executeNode({ op = "follower_gesture", gesture = "flash", a = 16, b = 2 }, run)
  Runtime.executeNode({ op = "follower_add_mood", amount = 20 }, run)
  Assert.deepEqual(cue.calls, { { "gesture", "flash", 16, 2 }, { "mood", 20 } })
end

function T.swap_and_visibility_query_use_the_following_controller()
  local calls = {}
  local follower = {
    swapPositionsWithPlayer = function()
      calls[#calls + 1] = "swap"
    end,
    isInactiveOrVisible = function()
      return true
    end,
  }
  follower.recallToPlayer = function()
    calls[#calls + 1] = "recall"
    return true
  end
  follower.isNextToPlayer = function()
    return true
  end
  local run, stored = runWith({ followingMon = follower })
  Runtime.executeNode({ op = "follower_recall_to_player" }, run)
  Runtime.executeNode({ op = "follower_is_next_to_player", result = var(0x800C) }, run)
  Assert.equal(stored[0x800C], 1)
  Runtime.executeNode({ op = "follower_swap_with_player" }, run)
  Runtime.executeNode({ op = "follower_inactive_or_visible", result = var(0x8006) }, run)
  Assert.deepEqual(calls, { "recall", "swap" })
  Assert.equal(stored[0x8006], 1)
end

function T.lead_type_query_compares_the_first_alive_mon_types()
  local mons = {
    leadAliveSlot = function()
      return 1
    end,
    monTypes = function(_, slot)
      Assert.equal(slot, 1)
      return 0, 12
    end,
  }
  local run, stored = runWith({ mons = mons })
  Runtime.executeNode({ op = "party_lead_has_type", type = 12, result = var(0x800C) }, run)
  Assert.equal(stored[0x800C], 1, "the second type counts")
  Runtime.executeNode({ op = "party_lead_has_type", type = 1, result = var(0x800C) }, run)
  Assert.equal(stored[0x800C], 0)
end

function T.capitalize_wraps_the_buffered_text_lazily()
  local run = runWith({})
  run.instance.textArgs[1] = { text = "item_name_indefinite", value = 4 }
  Assert.equal(Runtime.executeNode({ op = "buffer_capitalize", slot = 1 }, run), Runtime.OUTCOME_CONTINUE)
  Assert.deepEqual(run.instance.textArgs[1], {
    text = "capitalized",
    source = { text = "item_name_indefinite", value = 4 },
  })
end

local function aftermathDouble(result)
  local service = { calls = {} }
  function service:rockSmash(followerUsing)
    self.calls[#self.calls + 1] = { "rockSmash", followerUsing }
    return result
  end
  function service:headbutt()
    self.calls[#self.calls + 1] = { "headbutt" }
    return result
  end
  return service
end

function T.rock_smash_item_check_writes_the_found_item_after_the_emote_cue()
  local cue = cueDouble(true)
  local aftermath = aftermathDouble({ kind = "item", item = 17 })
  local run, stored = runWith({ fieldMoveCue = cue, fieldMoveAftermath = aftermath }, { [0x8007] = 1 })
  local node = {
    op = "rock_smash_item_check",
    followerUsing = var(0x8007),
    found = var(0x800C),
    item = var(0x8006),
  }
  Assert.equal(Runtime.executeNode(node, run), Runtime.OUTCOME_CONTINUE)
  Assert.deepEqual(aftermath.calls, { { "rockSmash", true } })
  Assert.deepEqual(cue.calls, { { "emote", true } })
  Assert.equal(stored[0x800C], 1)
  Assert.equal(stored[0x8006], 17)
end

function T.rock_smash_item_check_without_an_item_writes_not_found()
  local cue = cueDouble(true)
  local run, stored = runWith(
    { fieldMoveCue = cue, fieldMoveAftermath = aftermathDouble({ kind = "none" }) },
    { [0x8007] = 0, [0x8006] = 9 }
  )
  local node = { op = "rock_smash_item_check", followerUsing = 0, found = var(0x800C), item = var(0x8006) }
  Assert.equal(Runtime.executeNode(node, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(stored[0x800C], 0)
  Assert.equal(stored[0x8006], 0)
  Assert.deepEqual(cue.calls, {})
end

function T.a_started_wild_battle_suspends_the_script_on_the_battle_task()
  local details = { species = "GEODUDE", level = 7, attemptId = 3 }
  local aftermath = aftermathDouble({ kind = "battle", details = details })
  local run, stored = runWith({ fieldMoveCue = cueDouble(true), fieldMoveAftermath = aftermath })
  local node = { op = "rock_smash_item_check", followerUsing = 0, found = var(0x800C), item = var(0x8006) }
  local outcome = Runtime.executeNode(node, run)
  Assert.equal(outcome, Runtime.OUTCOME_BLOCK)
  Assert.equal(run.scheduler.created.taskType, "battle")
  Assert.deepEqual(run.scheduler.created.spec, { kind = "wild", details = details })
  Assert.equal(stored[0x800C], 0, "a battle leaves the item result cleared")
  local headbutt = runWith({ fieldMoveAftermath = aftermathDouble({ kind = "battle", details = details }) })
  Assert.equal(Runtime.executeNode({ op = "try_headbutt_encounter", result = var(0x800C) }, headbutt), Runtime.OUTCOME_BLOCK)
  local struck, storedHeadbutt = runWith({ fieldMoveAftermath = aftermathDouble({ kind = "none" }) })
  Assert.equal(Runtime.executeNode({ op = "try_headbutt_encounter", result = var(0x800C) }, struck), Runtime.OUTCOME_CONTINUE)
  Assert.equal(storedHeadbutt[0x800C], 0)
end

function T.sweet_scent_blocks_on_the_scent_task_and_names_its_result_variable()
  local run = runWith({})
  Assert.equal(Runtime.executeNode({ op = "sweet_scent", result = var(0x800C) }, run), Runtime.OUTCOME_BLOCK)
  Assert.equal(run.scheduler.created.taskType, "sweet_scent")
  Assert.deepEqual(run.blockResultRef, var(0x800C))
end

function T.missing_cue_service_is_an_attributed_fault()
  local run = runWith({})
  local err = Assert.throws(function()
    Runtime.executeNode({ op = "field_move_cut_in", slot = 0 }, run)
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "SCRIPT_SERVICE_MISSING")
end

return { tests = T }
