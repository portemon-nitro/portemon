-- Frozen move-learning acceptance: learning prompts must run through the
-- native summary and move-selection presentation, not a generic row
-- projection. Selecting a held row stages its replace confirmation without
-- sealing, confirming the staged confirmation seals the exact projected
-- fragment once, and the decline row needs its own explicit confirmation:
-- backing out never auto-declines.
--
-- Dependency note: the battle child composition module is missing, so no
-- summary owner renders held-move details and chained offers have no
-- flow-level resumption owner. The red tests pin those misses: the
-- composition module and held-move detail facts on the child view. Exactly
-- one reply per offer and no duplicate learning after reopening stay with
-- the completion owner covered by the failure-isolation suite.

local Assert = require("tests.support.Assert")

local BattleSubflows = require("game.hgss.src.battle.BattleSubflows")

local COMPOSER_MODULE = "game.hgss.src.battle.BattleChildApplications"

local T = {}

---@return table<string, unknown> battle child coordinator under test driving
local function coordinator()
  return BattleSubflows.new({ launchId = "launch-learn-child" })
end

---@param recipient integer roster-bound learning recipient under test preparation
---@return table<string, unknown> learn request with a full held move set
local function learnRequest(recipient)
  return {
    requestId = 11,
    epoch = 4,
    controller = "player",
    kind = "learn_move",
    incomingMove = "SAND_ATTACK",
    currentMoves = {
      { move = "TACKLE", pp = 35, ppUps = 0 },
      { move = "TAIL_WHIP", pp = 30, ppUps = 0 },
      { move = "GROWL", pp = 40, ppUps = 0 },
      { move = "LEER", pp = 30, ppUps = 0 },
    },
    actors = { { combatant = recipient } },
    canDecline = true,
  }
end

---@param recipient integer roster-bound learning recipient under test preparation
---@return table<string, unknown> native learning options for the held recipient
local function learnOptions(recipient)
  local choices = {}
  for slot = 0, 3 do
    choices[#choices + 1] = {
      id = "learn:replace:" .. tostring(slot),
      role = "learn",
      enabled = true,
      reason = "refused",
      display = { move = "MOVE" .. tostring(slot) },
      choice = {
        actor = { combatant = recipient },
        kind = "confirm",
        payload = { decision = "replace", slot = slot },
      },
    }
  end
  choices[#choices + 1] = {
    id = "learn:decline",
    role = "learn",
    enabled = true,
    reason = "refused",
    display = { decision = "decline" },
    choice = {
      actor = { combatant = recipient },
      kind = "confirm",
      payload = { decision = "decline" },
    },
  }
  return {
    requestId = 11,
    epoch = 4,
    controller = "player",
    kind = "learn_move",
    actors = {
      {
        combatant = recipient,
        kind = "learn_move",
        incomingMove = "SAND_ATTACK",
        currentMoves = learnRequest(recipient).currentMoves,
        choices = choices,
      },
    },
  }
end

---@param recipient integer roster-bound learning recipient under test preparation
---@return table<string, unknown> learning intent for the synthetic request
local function learnIntent(recipient)
  return {
    kind = "learn",
    purpose = "learn",
    launchId = "launch-learn-child",
    requestId = 11,
    epoch = 4,
    controller = "player",
    cancellable = false,
    request = learnRequest(recipient),
    options = learnOptions(recipient),
    party = {
      { combatant = 1, slot = 0, name = "LEAD", level = 20, hp = 30, maxHp = 30 },
      { combatant = 2, slot = 1, name = "BACK", level = 5, hp = 10, maxHp = 18 },
    },
    inventory = {},
  }
end

---@param flows table<string, unknown> coordinator under test driving
---@param event table<string, unknown> semantic input under test driving
local function drive(flows, event)
  flows:update({ event })
  flows:tick()
end

function T.replace_confirmation_seals_the_projected_slot_fragment()
  local flows = coordinator()
  local options = learnOptions(1)
  Assert.isTrue(flows:open(learnIntent(1)), "learning opens for the held recipient")
  drive(flows, { type = "confirm" })
  Assert.isNil(flows:takeResult(), "selecting a held row seals no reply")
  Assert.isTrue(flows:status().active, "selecting a held row stays on its confirmation")
  drive(flows, { type = "confirm" })
  local result = flows:takeResult()
  Assert.notNil(result, "confirming the staged replace seals its fragment")
  Assert.equal(result.kind, "choice", "the replace stages a choice")
  Assert.deepEqual(
    result.reply.choices[1],
    options.actors[1].choices[1].choice,
    "the reply copies the projected slot fragment"
  )
  Assert.isNil(flows:takeResult(), "the staged reply reports once")
  flows:dispose()
end

function T.decline_requires_its_own_confirmation_before_sealing()
  local flows = coordinator()
  Assert.isTrue(flows:open(learnIntent(1)), "learning opens for the held recipient")
  for _ = 1, 4 do
    drive(flows, { type = "navigate", direction = "down" })
  end
  drive(flows, { type = "confirm" })
  Assert.isNil(flows:takeResult(), "selecting the decline row seals no reply")
  drive(flows, { type = "confirm" })
  local result = flows:takeResult()
  Assert.notNil(result, "confirming the staged decline seals its fragment")
  Assert.equal(result.reply.choices[1].payload.decision, "decline", "the reply declines without replacing")
  flows:dispose()
end

function T.learning_is_presented_by_the_native_summary_and_move_selection_owner()
  local ok, composer = pcall(require, COMPOSER_MODULE)
  Assert.isTrue(ok, "move learning is composed by the battle child module (" .. COMPOSER_MODULE .. ")")
  assert(composer ~= nil, "the composer loads")
end

function T.learning_child_view_carries_held_move_detail_facts()
  local flows = coordinator()
  Assert.isTrue(flows:open(learnIntent(1)), "learning opens for the held recipient")
  local view = flows:status().childView
  Assert.notNil(view, "the open prompt exposes its child view")
  Assert.equal(view.kind, "learn", "the child view names the learning prompt")
  Assert.equal(#view.rows, 5, "setup: four held rows plus decline are visible before the facts check")
  local first = view.rows[1]
  Assert.notNil(first, "setup: the first held row is present before the facts check")
  Assert.notNil(first.facts, "the held row carries its summary detail facts")
  flows:dispose()
end

-- Every ready version replays the frozen learning flow through move keys
-- drawn from its own owned mon catalog: the versioned catalog names the
-- same held and incoming moves, selecting a held row still stages its
-- replace confirmation without sealing, and the decline row still needs
-- its own confirmation. The catalog comes from the versioned cache,
-- never from a shared fallback, so a version skew in move identities
-- fails here instead of hiding behind the synthetic fixture.
function T.versioned_move_keys_replay_the_frozen_learning_flow(context)
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
    context:skip("the versioned learning flow needs a ready user-owned dump with a derived cache")
  end
  for _, versionId in ipairs(versions) do
    local catalog = MonBucket.openCatalogs(versionId)
    for _, moveKey in ipairs({ "TACKLE", "TAIL_WHIP", "GROWL", "LEER", "SAND_ATTACK" }) do
      local known, knownErr = pcall(function()
        return catalog:move(moveKey)
      end)
      Assert.isTrue(known, "the owned " .. versionId .. " catalog names " .. moveKey .. ": " .. tostring(knownErr))
    end
    local options = learnOptions(1)
    local flows = coordinator()
    Assert.isTrue(flows:open(learnIntent(1)), "learning opens for the held recipient on " .. versionId)
    drive(flows, { type = "confirm" })
    Assert.isNil(flows:takeResult(), "selecting a held row seals no reply on " .. versionId)
    drive(flows, { type = "confirm" })
    local result = flows:takeResult()
    Assert.notNil(result, "confirming the staged replace seals its fragment on " .. versionId)
    Assert.equal(result.kind, "choice", "the replace stages a choice on " .. versionId)
    Assert.deepEqual(
      result.reply.choices[1],
      options.actors[1].choices[1].choice,
      "the reply copies the projected slot fragment on " .. versionId
    )
    Assert.isNil(flows:takeResult(), "the staged reply reports once on " .. versionId)
    flows:dispose()
    local declined = coordinator()
    Assert.isTrue(declined:open(learnIntent(1)), "learning opens for the decline on " .. versionId)
    for _ = 1, 4 do
      drive(declined, { type = "navigate", direction = "down" })
    end
    drive(declined, { type = "confirm" })
    Assert.isNil(declined:takeResult(), "selecting the decline row seals no reply on " .. versionId)
    drive(declined, { type = "confirm" })
    local refused = declined:takeResult()
    Assert.notNil(refused, "confirming the staged decline seals its fragment on " .. versionId)
    Assert.equal(refused.reply.choices[1].payload.decision, "decline", "the reply declines without replacing on " .. versionId)
    declined:dispose()
  end
end

return {
  tests = T,
  metadata = {
    capabilities = { "rom_dump", "derived_assets" },
    derivedAssets = { "mon-catalog:global", "items:global" },
  },
}
