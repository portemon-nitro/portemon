-- Frozen battle-party acceptance: in-battle Party use must be the native
-- Party application, not a generic row projection. Voluntary switches seal
-- the exact projected reserve fragment once, forced replacement holds on
-- every cancel path and seals on confirm, and each prompt answers exactly
-- one addressed entry with its launch and request identity.
--
-- Dependency note: the battle child composition module is missing, so the
-- current child still renders generic party rows, doubles batch
-- reservations across co-actors have no shared reservation owner, and no
-- summary handoff exists behind party rows. The red tests pin those misses:
-- per-actor batch opening, composition-module ownership, and a native
-- application receipt on the child view.

local Assert = require("tests.support.Assert")

local BattleSubflows = require("game.hgss.src.battle.BattleSubflows")

local COMPOSER_MODULE = "game.hgss.src.battle.BattleChildApplications"

local T = {}

---@return table<string, unknown> battle child coordinator under test driving
local function coordinator()
  return BattleSubflows.new({ launchId = "launch-party-child" })
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
    launchId = "launch-party-child",
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

function T.voluntary_switch_seals_the_projected_reserve_fragment_once()
  local flows = coordinator()
  local options = switchOptions(2)
  Assert.isTrue(flows:open(partyIntent({ options = options })), "the voluntary party child opens")
  drive(flows, { type = "confirm" })
  local result = flows:takeResult()
  Assert.notNil(result, "confirming the reserve stages its reply")
  Assert.equal(result.kind, "choice", "the reserve stages a choice")
  Assert.deepEqual(
    result.reply.choices[1],
    options.actors[1].choices[1].choice,
    "the reply copies the projected fragment"
  )
  Assert.equal(result.reply.launchId, "launch-party-child", "the reply answers the open launch")
  Assert.isNil(flows:takeResult(), "the staged reply reports once")
  flows:dispose()
end

function T.forced_replacement_holds_on_cancel_and_seals_on_confirm()
  local flows = coordinator()
  Assert.isTrue(
    flows:open(partyIntent({ purpose = "replacement", cancellable = false })),
    "the forced replacement child opens"
  )
  drive(flows, { type = "cancel" })
  Assert.isNil(flows:takeResult(), "a forced replacement has no cancel result")
  Assert.isTrue(flows:status().active, "a forced replacement keeps owning input after cancel")
  drive(flows, { type = "confirm" })
  local result = flows:takeResult()
  Assert.notNil(result, "confirming the forced reserve stages its reply")
  Assert.equal(result.kind, "choice", "the forced reserve stages a choice")
  flows:dispose()
end

function T.doubles_batch_reservations_open_per_actor_without_superseding()
  local flows = coordinator()
  Assert.isTrue(flows:open(partyIntent({})), "setup: the single-actor party child opens")
  flows:closeChild()
  local batch = switchOptions(2)
  batch.actors[#batch.actors + 1] = {
    combatant = 3,
    activation = 6,
    kind = "action",
    choices = {
      {
        id = "switch:4",
        role = "switch",
        enabled = true,
        reason = "refused",
        display = { combatant = 4 },
        choice = {
          actor = { combatant = 3, activation = 6 },
          kind = "switch",
          payload = { replacement = 4 },
        },
      },
    },
  }
  local ok, openErr = flows:open(partyIntent({ options = batch, requestId = 8, epoch = 4 }))
  Assert.isTrue(ok, "the batch reservation opens for every addressed actor: " .. tostring(openErr))
  flows:dispose()
end

function T.party_child_is_built_by_the_battle_child_composer()
  local ok, composer = pcall(require, COMPOSER_MODULE)
  Assert.isTrue(ok, "the battle party child is composed by the battle child module (" .. COMPOSER_MODULE .. ")")
  assert(composer ~= nil, "the composer loads")
end

function T.party_child_view_carries_the_native_party_application_receipt()
  local flows = coordinator()
  Assert.isTrue(flows:open(partyIntent({})), "the voluntary party child opens")
  local view = flows:status().childView
  Assert.notNil(view, "the open party exposes its child view")
  Assert.equal(view.kind, "party", "the child view names the party")
  Assert.equal(#view.rows, 6, "setup: all six roster rows are visible before the receipt check")
  Assert.equal(view.application, "party", "the party view carries its native application receipt")
  flows:dispose()
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
      "BLOCKED: no ready soulsilver user-owned ROM cache in this checkout; second-version party parity is unverified"
    )
  end
  Assert.isTrue(
    false,
    "a ready soulsilver cache appeared: this probe must grow a real second-version comparison before it may pass"
  )
end

return { tests = T }
