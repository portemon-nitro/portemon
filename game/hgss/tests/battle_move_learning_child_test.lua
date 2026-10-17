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
      "BLOCKED: no ready soulsilver user-owned ROM cache in this checkout; second-version learning parity is unverified"
    )
  end
  Assert.isTrue(
    false,
    "a ready soulsilver cache appeared: this probe must grow a real second-version comparison before it may pass"
  )
end

return { tests = T }
