-- Frozen child-failure acceptance: every injected failure must preserve
-- the last known-good state. Staged child results report exactly once,
-- stale and foreign requests never seal, acquisition failure leaves no
-- child owning input, and nothing mutates live owners before the owning
-- commit.
--
-- Dependency note: the battle outcome committer already publishes the
-- terminal battle receipt exactly once, but the per-launch
-- completion-command ledger for post-battle progression (evolution,
-- naming, storage) has no owner on the battle runtime yet. The red tests
-- pin that miss from both facets: publishing a progression command once,
-- and querying its receipt without republishing. Borrowed-versus-owned UI
-- resource discipline lands with the missing child composer.

local Assert = require("tests.support.Assert")

local BattleRuntime = require("game.hgss.src.battle.BattleRuntime")
local BattleSubflows = require("game.hgss.src.battle.BattleSubflows")

local T = {}

---@return table<string, unknown> battle child coordinator under test driving
local function coordinator()
  return BattleSubflows.new({ launchId = "launch-failure-child" })
end

---@return table<integer, table<string, unknown>> detached own-party snapshot
local function twoEeveeRoster()
  return {
    { combatant = 1, slot = 0, name = "LEAD", level = 20, hp = 30, maxHp = 30 },
    { combatant = 2, slot = 1, name = "BACK", level = 5, hp = 10, maxHp = 18 },
  }
end

---@param reserve integer stable combatant identity of the eligible reserve
---@return table<string, unknown> detached action options projecting one reserve switch
local function switchOptions(reserve)
  return {
    requestId = 7,
    epoch = 3,
    controller = "player",
    kind = "action",
    actors = {
      {
        combatant = 1,
        activation = 5,
        kind = "action",
        choices = {
          {
            id = "switch:" .. tostring(reserve),
            role = "switch",
            enabled = true,
            reason = "refused",
            display = { combatant = reserve },
            choice = {
              actor = { combatant = 1, activation = 5 },
              kind = "switch",
              payload = { replacement = reserve },
            },
          },
        },
      },
    },
  }
end

---@param opts table<string, unknown> intent overrides under test preparation
---@return table<string, unknown> party selection intent for the synthetic request
local function partyIntent(opts)
  local intent = {
    kind = "party",
    purpose = "switch",
    launchId = "launch-failure-child",
    requestId = 7,
    epoch = 3,
    controller = "player",
    cancellable = true,
    request = { requestId = 7, epoch = 3, controller = "player", kind = "action" },
    options = switchOptions(2),
    party = twoEeveeRoster(),
    inventory = {},
  }
  for key, value in pairs(opts) do
    intent[key] = value
  end
  return intent --[[@as table<string, unknown>]]
end

---@param flows table<string, unknown> coordinator under test driving
---@param event table<string, unknown> semantic input under test driving
local function drive(flows, event)
  flows:update({ event })
  flows:tick()
end

function T.staged_results_report_once_and_stale_requests_never_seal()
  local flows = coordinator()
  Assert.isTrue(flows:open(partyIntent({})), "the party child opens")
  drive(flows, { type = "confirm" })
  local staged = flows:takeResult()
  Assert.notNil(staged, "confirming stages its reply")
  Assert.equal(staged.kind, "choice", "the staged result is a choice")
  Assert.isNil(flows:takeResult(), "a double collection seals nothing more")
  Assert.isTrue(flows:open(partyIntent({ requestId = 8, epoch = 9 })), "the replacement request opens")
  Assert.isNil(flows:takeResult(), "the stale request leaves no result behind")
  local foreign, foreignErr = flows:open(partyIntent({ launchId = "foreign-launch" }))
  Assert.isFalse(foreign, "a foreign launch never opens: " .. tostring(foreignErr))
  Assert.isTrue(flows:status().active, "the foreign attempt keeps the owned child")
  flows:dispose()
end

function T.acquisition_failure_leaves_no_child_owning_input()
  local flows = coordinator()
  local empty = {
    requestId = 9,
    epoch = 2,
    controller = "player",
    kind = "replacement",
    actors = { { combatant = 1, activation = 5, kind = "replacement", choices = {} } },
  }
  local ok, openErr = flows:open(partyIntent({ purpose = "replacement", cancellable = false, options = empty }))
  Assert.isFalse(ok == true, "no invented reserve ever opens")
  Assert.isTrue(type(openErr) == "string" and openErr ~= "", "the failure names itself")
  Assert.isFalse(flows:status().active, "no child owns input after the failure")
  Assert.isNil(flows:takeResult(), "the failed acquisition stages nothing")
  flows:dispose()
end

function T.progression_publishes_exactly_once_through_the_completion_owner()
  Assert.isTrue(
    type(BattleRuntime.completeProgression) == "function",
    "the battle runtime publishes a post-battle progression command exactly once per launch"
  )
end

function T.settled_completion_is_queryable_without_republishing()
  Assert.isTrue(
    type(BattleRuntime.takeCompletionReceipt) == "function",
    "the battle runtime answers a settled progression receipt without running the command again"
  )
end

function T.soulsilver_variant_stays_blocked_without_its_owned_cache(context)
  local GameVersion = require("romdump.src.source.GameVersion")
  local RomImporter = require("romdump.src.source.RomImporter")
  local known = false
  for _, versionId in ipairs(GameVersion.ORDER) do
    if versionId == "soulsilver" then
      known = true
    end
  end
  Assert.isTrue(known, "setup: the second version is a known parity dimension")
  if not RomImporter.isReady("soulsilver") then
    context:skip(
      "BLOCKED: no ready soulsilver user-owned ROM cache in this checkout; second-version failure parity is unverified"
    )
  end
  Assert.isTrue(
    false,
    "a ready soulsilver cache appeared: this probe must grow a real second-version comparison before it may pass"
  )
end

return { tests = T }
