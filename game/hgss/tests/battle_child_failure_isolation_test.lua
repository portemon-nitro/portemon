-- Frozen child-failure acceptance: every injected failure must preserve
-- the last known-good state. Staged child results report exactly once,
-- stale and foreign requests never seal, acquisition failure leaves no
-- child owning input, and nothing mutates live owners before the owning
-- commit.
--
-- Dependency note: the battle outcome committer already publishes the
-- terminal battle receipt exactly once. Borrowed-versus-owned UI
-- resource discipline lands with the missing child composer.

local Assert = require("tests.support.Assert")

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
  drive(flows, { type = "navigate", direction = "down" })
  drive(flows, { type = "confirm" })
  drive(flows, { type = "confirm" })
  for _ = 1, 12 do
    flows:tick()
  end
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

-- Every ready version replays the frozen failure-isolation flow through
-- rosters drawn from its own owned mon catalog: the versioned catalog
-- names the same EEVEE reserve, staged results still report once, stale
-- requests never seal, and acquisition failure still leaves no child
-- owning input. The catalog comes from the versioned cache, never from a
-- shared fallback, so a version skew in species identities fails here
-- instead of hiding behind the synthetic fixture.
function T.versioned_rosters_replay_the_frozen_failure_isolation_flow(context)
  local GameVersion = require("romdump.src.source.GameVersion")
  local RomImporter = require("romdump.src.source.RomImporter")
  local MonBucket = require("tests.support.MonBucket")
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      versions[#versions + 1] = versionId
    end
  end
  if #versions == 0 then
    context:skip("the versioned failure flow needs a ready user-owned dump with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local catalog = MonBucket.openCatalogs(versionId)
    local known, knownErr = pcall(function()
      return catalog:species("EEVEE")
    end)
    Assert.isTrue(known, "the owned " .. versionId .. " catalog names the EEVEE reserve: " .. tostring(knownErr))
    local roster = {
      { combatant = 1, slot = 0, name = "EEVEE", level = 20, hp = 30, maxHp = 30 },
      { combatant = 2, slot = 1, name = "EEVEE", level = 5, hp = 10, maxHp = 18 },
    }
    local flows = coordinator()
    Assert.isTrue(flows:open(partyIntent({ party = roster })), "the party child opens on " .. versionId)
    drive(flows, { type = "confirm" })
    local staged = flows:takeResult()
    Assert.notNil(staged, "confirming stages its reply on " .. versionId)
    Assert.equal(staged.kind, "choice", "the staged result is a choice on " .. versionId)
    Assert.isNil(flows:takeResult(), "a double collection seals nothing more on " .. versionId)
    Assert.isTrue(
      flows:open(partyIntent({ party = roster, requestId = 8, epoch = 9 })),
      "the replacement request opens on " .. versionId
    )
    Assert.isNil(flows:takeResult(), "the stale request leaves no result behind on " .. versionId)
    local foreign, foreignErr = flows:open(partyIntent({ party = roster, launchId = "foreign-launch" }))
    Assert.isFalse(foreign, "a foreign launch never opens on " .. versionId .. ": " .. tostring(foreignErr))
    Assert.isTrue(flows:status().active, "the foreign attempt keeps the owned child on " .. versionId)
    flows:dispose()
    local failed = coordinator()
    local empty = {
      requestId = 9,
      epoch = 2,
      controller = "player",
      kind = "replacement",
      actors = { { combatant = 1, activation = 5, kind = "replacement", choices = {} } },
    }
    local ok, openErr = failed:open(partyIntent({ party = roster, purpose = "replacement", cancellable = false, options = empty }))
    Assert.isFalse(ok == true, "no invented reserve ever opens on " .. versionId)
    Assert.isTrue(type(openErr) == "string" and openErr ~= "", "the failure names itself on " .. versionId)
    Assert.isFalse(failed:status().active, "no child owns input after the failure on " .. versionId)
    Assert.isNil(failed:takeResult(), "the failed acquisition stages nothing on " .. versionId)
    failed:dispose()
  end
end

return {
  tests = T,
  metadata = {
    capabilities = { "rom_dump", "derived_assets" },
    derivedAssets = { "mon-catalog:global", "items:global" },
  },
}
