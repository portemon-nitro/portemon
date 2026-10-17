-- Per-launch completion-command ledger: post-battle progression publishes
-- exactly once per barrier identity, repeats answer the stored receipt
-- without republishing, and failures leave live owners unchanged with
-- nothing recorded. Take hands the settled receipt to the visual flow
-- exactly once; the ledger retains the committed record so repeats never
-- replay the command.

local Assert = require("tests.support.Assert")

local BattleRuntime = require("game.hgss.src.battle.BattleRuntime")

local T = {}

---@return table<string, unknown> application battle lifetime under test driving
local function headlessRuntime()
  return BattleRuntime.new({
    request = { id = "launch-ledger-child", kind = "wild", payload = { species = "EEVEE", level = 5 } },
    presentation = {
      enter = function(_)
        return true
      end,
      present = function(_) end,
      ready = function()
        return true
      end,
      leave = function(_)
        return true
      end,
      dispose = function() end,
    },
  })
end

---@param owners table<string, table<string, unknown>>? live owner doubles under the command
---@return table<string, unknown> completion command with recording stage/commit owners
local function recordingCommand(owners)
  local calls = { prepare = 0, commit = 0 }
  local command = {
    identity = "barrier-7",
    kind = "evolution",
    subjectIdentity = "mon-1",
    subjectRevision = 3,
    calls = calls,
  }
  function command.prepare()
    calls.prepare = calls.prepare + 1
    if owners ~= nil then
      owners.staged = { monAfter = { species = "TESTVOLVED" }, additionalMons = {}, inventoryDeltas = {} }
    end
    return { monAfter = { species = "TESTVOLVED" }, additionalMons = {}, inventoryDeltas = {} }
  end
  function command.commit(staged)
    calls.commit = calls.commit + 1
    if owners ~= nil then
      Assert.notNil(staged, "the commit owner receives the staged result")
      owners.published = staged
    end
    return { applied = true, resultingRevision = 4 }
  end
  return command
end

function T.malformed_commands_publish_nothing()
  local battle = headlessRuntime()
  local receipt, err = battle:completeProgression({})
  Assert.isNil(receipt, "identity-free commands publish nothing")
  Assert.isTrue(type(err) == "string" and err ~= "", "the boundary names the identity")
  local incomplete, incompleteErr = battle:completeProgression({ identity = "barrier-1", kind = "evolution" })
  Assert.isNil(incomplete, "subject-free commands publish nothing")
  Assert.isTrue(type(incompleteErr) == "string" and incompleteErr ~= "", "the boundary names the subject")
  Assert.isNil(battle:takeCompletionReceipt("barrier-1"), "failed commands record no receipt")
  battle:dispose()
end

function T.publish_stages_once_and_repeats_answer_without_rerunning()
  local battle = headlessRuntime()
  local command = recordingCommand(nil)
  local receipt, err = battle:completeProgression(command)
  Assert.isNil(err, "a well-formed command publishes: " .. tostring(err))
  Assert.notNil(receipt, "publication answers its receipt")
  assert(receipt ~= nil, "the completion receipt seals")
  Assert.equal(receipt.identity, "barrier-7", "the receipt answers its barrier")
  Assert.equal(receipt.kind, "evolution", "the receipt names its progression kind")
  Assert.isTrue(receipt.committed, "the receipt marks its publication")
  Assert.equal(receipt.subjectIdentity, "mon-1", "the receipt binds its committed subject")
  Assert.equal(receipt.resultingRevision, 4, "the receipt carries the resulting revision")
  Assert.equal(command.calls.prepare, 1, "prepare runs once")
  Assert.equal(command.calls.commit, 1, "commit runs once")
  local repeated, repeatErr = battle:completeProgression(command)
  Assert.isNil(repeatErr, "repeating a settled identity reports no failure")
  Assert.deepEqual(repeated, receipt, "the repeat answers the stored receipt")
  Assert.equal(command.calls.prepare, 1, "the repeat never re-prepares")
  Assert.equal(command.calls.commit, 1, "the repeat never republishes")
  battle:dispose()
end

function T.take_hands_the_receipt_off_exactly_once()
  local battle = headlessRuntime()
  local command = recordingCommand(nil)
  local receipt, _ = battle:completeProgression(command)
  Assert.notNil(receipt, "setup: the command publishes")
  local taken = battle:takeCompletionReceipt("barrier-7")
  Assert.deepEqual(taken, receipt, "the first take answers the settled receipt")
  Assert.isNil(battle:takeCompletionReceipt("barrier-7"), "a second take answers nothing")
  Assert.isNil(battle:takeCompletionReceipt("barrier-unknown"), "unknown identities answer nothing")
  Assert.equal(command.calls.commit, 1, "querying never republishes")
  battle:dispose()
end

function T.precommit_failure_leaves_owners_unchanged_and_records_nothing()
  local battle = headlessRuntime()
  local owners = { published = nil }
  local calls = { prepare = 0 }
  local receipt, err = battle:completeProgression({
    identity = "barrier-9",
    kind = "naming",
    subjectIdentity = "mon-2",
    subjectRevision = 5,
    prepare = function()
      calls.prepare = calls.prepare + 1
      return nil, "the dex owner is unavailable"
    end,
    commit = function(_)
      owners.published = true
      return {}
    end,
  })
  Assert.isNil(receipt, "a failed prepare publishes nothing")
  Assert.isTrue(type(err) == "string" and err ~= "", "the failure names itself")
  Assert.isNil(owners.published, "a failed prepare never reaches its commit owner")
  Assert.isNil(battle:takeCompletionReceipt("barrier-9"), "a failed prepare records no receipt")
  battle:dispose()
end

function T.commit_failure_records_nothing_and_supports_a_later_retry()
  local battle = headlessRuntime()
  local attempts = 0
  local command = {
    identity = "barrier-11",
    kind = "storage",
    subjectIdentity = "mon-3",
    subjectRevision = 6,
    prepare = function()
      return { staged = true }
    end,
    commit = function(_)
      attempts = attempts + 1
      if attempts == 1 then
        error("the storage owner is unavailable", 0)
      end
      return { applied = true }
    end,
  }
  local receipt, err = battle:completeProgression(command)
  Assert.isNil(receipt, "a failed commit settles nothing")
  Assert.isTrue(type(err) == "string" and err ~= "", "the failure names itself")
  Assert.isNil(battle:takeCompletionReceipt("barrier-11"), "a failed commit records no receipt")
  local retried, retryErr = battle:completeProgression(command)
  Assert.isNil(retryErr, "the retry publishes: " .. tostring(retryErr))
  Assert.notNil(retried, "the retry settles its receipt")
  Assert.equal(attempts, 2, "only the retry commits")
  battle:dispose()
end

function T.multiowner_publication_applies_once_with_shared_staging()
  local battle = headlessRuntime()
  local owners = { writes = 0, staged = nil, published = nil }
  local receipt, err = battle:completeProgression({
    identity = "barrier-13",
    kind = "evolution",
    subjectIdentity = "mon-4",
    subjectRevision = 7,
    prepare = function()
      local staged = { monAfter = { species = "TESTVOLVED" }, side = { species = "TESTSHED" } }
      owners.staged = staged
      return staged
    end,
    commit = function(staged)
      owners.writes = owners.writes + 1
      owners.published = { mon = staged.monAfter, side = staged.side }
      return { applied = true, resultingRevision = 8 }
    end,
  })
  Assert.isNil(err, "the multi-owner command publishes: " .. tostring(err))
  Assert.notNil(receipt, "setup: the command publishes")
  assert(receipt ~= nil, "the multi-owner receipt seals")
  Assert.equal(owners.writes, 1, "the staged batch publishes once across owners")
  Assert.equal(owners.published.mon.species, "TESTVOLVED", "the primary stages through the shared result")
  Assert.equal(owners.published.side.species, "TESTSHED", "the side product rides the same operation")
  Assert.deepEqual(receipt.outcome, { applied = true, resultingRevision = 8 }, "the receipt carries its outcome")
  battle:dispose()
end

function T.settled_failures_never_publish()
  local battle = BattleRuntime.new({
    request = { id = "launch-ledger-broken", kind = "wild", payload = { species = "EEVEE", level = 5 } },
    scenario = {},
    presentation = {
      enter = function(_)
        return true
      end,
      present = function(_) end,
      ready = function()
        return true
      end,
      leave = function(_)
        return true
      end,
      dispose = function() end,
    },
  })
  while battle:status().phase ~= "failed" and battle:status().phase ~= "complete" do
    battle:update()
  end
  Assert.equal(battle:status().phase, "failed", "setup: the malformed scenario settles failed")
  local receipt, err = battle:completeProgression(recordingCommand(nil))
  Assert.isNil(receipt, "settled failures never publish")
  Assert.isTrue(type(err) == "string" and err ~= "", "the refusal names the settlement")
  battle:dispose()
end

return { tests = T }
