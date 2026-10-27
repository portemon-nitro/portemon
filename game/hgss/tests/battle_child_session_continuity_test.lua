-- Frozen session-continuity acceptance: host edges during an open child
-- must never invent input. Closed children drop stale pointer edges, a
-- held-press cancel seals nothing and keeps the owned child, and
-- alternating touch and controller edges route through the same child
-- without forking a second selection.
--
-- Dependency note: opening a child does not yet consume its initiating
-- input through a real application owner. The red test pins that miss:
-- initiating-input consumption behind the missing child composer.

local Assert = require("tests.support.Assert")

local BattleSubflows = require("game.hgss.src.battle.BattleSubflows")

local COMPOSER_MODULE = "game.hgss.src.battle.BattleChildApplications"

local T = {}

---@return table<string, unknown> battle child coordinator under test driving
local function coordinator()
  return BattleSubflows.new({ launchId = "launch-continuity-child" })
end

---@param opts table<string, unknown> intent overrides under test preparation
---@return table<string, unknown> party selection intent for the synthetic request
local function partyIntent(opts)
  local intent = {
    kind = "party",
    purpose = "switch",
    launchId = "launch-continuity-child",
    requestId = 7,
    epoch = 3,
    controller = "player",
    cancellable = true,
    request = { requestId = 7, epoch = 3, controller = "player", kind = "action" },
    options = {
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
              id = "switch:2",
              role = "switch",
              enabled = true,
              reason = "refused",
              display = { combatant = 2 },
              choice = {
                actor = { combatant = 1, activation = 5 },
                kind = "switch",
                payload = { replacement = 2 },
              },
            },
          },
        },
      },
    },
    party = {
      { combatant = 1, slot = 0, name = "LEAD", level = 20, hp = 30, maxHp = 30 },
      { combatant = 2, slot = 1, name = "BACK", level = 5, hp = 10, maxHp = 18 },
    },
    inventory = {},
  }
  for key, value in pairs(opts) do
    intent[key] = value
  end
  return intent --[[@as table<string, unknown>]]
end

function T.closed_children_drop_stale_pointer_edges()
  local flows = coordinator()
  Assert.isTrue(flows:open(partyIntent({})), "the party child opens")
  flows:update({ { type = "pointer_down", pointerId = "stale", x = 8, y = 8 } })
  flows:closeChild()
  flows:update({ { type = "pointer_up", pointerId = "stale", x = 8, y = 8 } })
  Assert.isNil(flows:takeResult(), "the stale release seals nothing")
  Assert.isFalse(flows:activateControl("party:1"), "taps miss the closed child")
  Assert.isTrue(flows:open(partyIntent({ requestId = 8, epoch = 9 })), "the replacement child opens")
  Assert.isTrue(flows:status().active, "the fresh child owns input")
  flows:dispose()
end

function T.pointer_capture_cancel_never_seals_a_choice()
  local flows = coordinator()
  Assert.isTrue(flows:open(partyIntent({})), "the party child opens")
  flows:cancelPointerCapture()
  Assert.isNil(flows:takeResult(), "cancelling a held press seals nothing")
  Assert.isTrue(flows:status().active, "the child keeps owning input after the cancel")
  flows:dispose()
end

-- Native learning authority behind the battle barrier: navigation edges wait
-- for the accepted source tick, the native move picker stages an explicit
-- keep-or-forget confirmation before anything seals, rejecting the
-- confirmation returns to the native list, and expired requests seal nothing.
function T.native_learning_seals_once_through_confirmation()
  local function learnIntent(launchId, requestId)
    local moves = {
      { move = "TACKLE", pp = 35, ppUps = 0 },
      { move = "TAIL_WHIP", pp = 30, ppUps = 0 },
      { move = "GROWL", pp = 40, ppUps = 0 },
      { move = "LEER", pp = 30, ppUps = 0 },
    }
    local choices = {}
    for slot = 0, 3 do
      choices[#choices + 1] = {
        id = "learn:replace:" .. tostring(slot),
        role = "learn",
        enabled = true,
        reason = "refused",
        display = { move = "MOVE" .. tostring(slot) },
        choice = {
          actor = { combatant = 1 },
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
        actor = { combatant = 1 },
        kind = "confirm",
        payload = { decision = "decline" },
      },
    }
    return {
      kind = "learn",
      purpose = "learn",
      launchId = launchId,
      requestId = requestId,
      epoch = 4,
      controller = "player",
      cancellable = false,
      request = {
        requestId = requestId,
        epoch = 4,
        controller = "player",
        kind = "learn_move",
        incomingMove = "SAND_ATTACK",
        currentMoves = moves,
        actors = { { combatant = 1 } },
      },
      options = {
        requestId = requestId,
        epoch = 4,
        controller = "player",
        kind = "learn_move",
        actors = {
          {
            combatant = 1,
            kind = "learn_move",
            incomingMove = "SAND_ATTACK",
            currentMoves = moves,
            choices = choices,
          },
        },
      },
      party = {},
      inventory = {},
    }
  end
  local function openLearned(launchId, requestId)
    local flows = BattleSubflows.new({ launchId = launchId })
    Assert.isTrue(flows:open(learnIntent(launchId, requestId)), "the learning prompt opens")
    return flows
  end
  local function step(flows, events)
    flows:update(events)
    flows:tick()
  end
  local function focusId(flows)
    local view = flows:status().childView
    Assert.notNil(view, "the open child projects its view")
    return assert(view.focusId, "the learning list projects its focus")
  end
  -- A bare input moves no focus: edges wait for the accepted tick.
  local flows = openLearned("launch-learn-once", 11)
  Assert.equal(focusId(flows), "learn:0", "the native list opens on its first row")
  flows:update({ { type = "navigate", direction = "down" } })
  Assert.equal(focusId(flows), "learn:0", "the navigation edge waits for the accepted source tick")
  flows:tick()
  Assert.equal(focusId(flows), "learn:1", "the accepted tick applies the buffered edge once")
  -- Selecting a row stages its explicit confirmation without sealing.
  step(flows, { { type = "confirm" } })
  Assert.isNil(flows:takeResult(), "selecting a row seals no reply")
  local confirmation = flows:status().childView.confirmation
  Assert.notNil(confirmation, "selecting a row stages its confirmation")
  assert(confirmation ~= nil, "the replace confirmation stages")
  Assert.equal(confirmation.kind, "replace", "the confirmation replaces the focused row")
  Assert.equal(confirmation.slot, 1, "the confirmation names the focused slot")
  step(flows, { { type = "confirm" } })
  local sealed = flows:takeResult()
  Assert.notNil(sealed, "confirming the replace seals its reply")
  assert(sealed ~= nil, "the replace reply seals")
  Assert.equal(sealed.kind, "choice", "the replace seals a choice")
  Assert.deepEqual(
    sealed.reply.choices[1].payload,
    { decision = "replace", slot = 1 },
    "the replace binds the focused slot fragment"
  )
  Assert.isNil(flows:takeResult(), "the replace reports exactly once")
  flows:dispose()
  -- Rejecting the confirmation returns to the native list.
  local rejected = openLearned("launch-learn-reject", 12)
  step(rejected, { { type = "confirm" } })
  Assert.isNil(rejected:takeResult(), "selecting a row seals no reply")
  Assert.notNil(rejected:status().childView.confirmation, "the confirmation stages")
  step(rejected, { { type = "cancel" } })
  Assert.isNil(rejected:takeResult(), "rejecting the confirmation seals no reply")
  Assert.isNil(rejected:status().childView.confirmation, "rejecting the confirmation returns to the list")
  Assert.equal(focusId(rejected), "learn:0", "the returned list keeps its opening focus")
  step(rejected, { { type = "confirm" } })
  step(rejected, { { type = "confirm" } })
  local resealed = rejected:takeResult()
  Assert.notNil(resealed, "reselecting after the rejection seals")
  assert(resealed ~= nil, "the reselected reply seals")
  Assert.deepEqual(
    resealed.reply.choices[1].payload,
    { decision = "replace", slot = 0 },
    "the reselection binds the opening row"
  )
  rejected:dispose()
  -- The decline row asks its own confirmation before sealing.
  local declined = openLearned("launch-learn-decline", 13)
  for _ = 1, 4 do
    step(declined, { { type = "navigate", direction = "down" } })
  end
  Assert.equal(focusId(declined), "learn:decline", "keys reach the decline row")
  step(declined, { { type = "confirm" } })
  Assert.isNil(declined:takeResult(), "selecting decline seals no reply")
  local declineConfirm = declined:status().childView.confirmation
  Assert.notNil(declineConfirm, "decline stages its confirmation")
  assert(declineConfirm ~= nil, "the decline confirmation stages")
  Assert.equal(declineConfirm.kind, "decline", "the confirmation declines without replacing")
  step(declined, { { type = "confirm" } })
  local declineSealed = declined:takeResult()
  Assert.notNil(declineSealed, "confirming the decline seals its reply")
  assert(declineSealed ~= nil, "the decline reply seals")
  Assert.deepEqual(
    declineSealed.reply.choices[1].payload,
    { decision = "decline" },
    "the decline binds its own fragment"
  )
  declined:dispose()
  -- Backing out of the list asks the stop confirmation instead of declining.
  local stopped = openLearned("launch-learn-stop", 14)
  step(stopped, { { type = "cancel" } })
  Assert.isNil(stopped:takeResult(), "backing out of the list never auto-declines")
  local stopConfirm = stopped:status().childView.confirmation
  Assert.notNil(stopConfirm, "backing out asks its stop confirmation")
  assert(stopConfirm ~= nil, "the stop confirmation stages")
  Assert.equal(stopConfirm.kind, "stop", "the stop confirmation names itself")
  step(stopped, { { type = "cancel" } })
  Assert.isNil(stopped:takeResult(), "rejecting the stop confirmation seals no reply")
  Assert.isNil(stopped:status().childView.confirmation, "the rejection returns to the list")
  Assert.equal(focusId(stopped), "learn:0", "the returned list keeps its opening focus")
  stopped:dispose()
  -- An expired request seals nothing, even replayed.
  local expired = openLearned("launch-learn-stale", 15)
  expired:closeChild()
  expired:update({ { type = "confirm" } })
  expired:tick()
  Assert.isNil(expired:takeResult(), "the expired request seals nothing")
  expired:dispose()
end
function T.opening_a_child_consumes_its_initiating_input()
  local ok, composer = pcall(require, COMPOSER_MODULE)
  Assert.isTrue(
    ok,
    "child opening consumes its initiating input through the battle child module (" .. COMPOSER_MODULE .. ")"
  )
  assert(composer ~= nil, "the composer loads")
end

-- Every ready version replays the frozen continuity flow through rosters
-- drawn from its own owned mon catalog: the versioned catalog names the
-- same EEVEE reserve, closed children still drop stale pointer edges, and
-- a held-press cancel still seals nothing while keeping the owned child.
-- The catalog comes from the versioned cache, never from a shared
-- fallback, so a version skew in species identities fails here instead
-- of hiding behind the synthetic fixture.
function T.versioned_rosters_replay_the_frozen_continuity_flow(context)
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
    context:skip("the versioned continuity flow needs a ready user-owned dump with a derived cache")
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
    flows:update({ { type = "pointer_down", pointerId = "stale", x = 8, y = 8 } })
    flows:closeChild()
    flows:update({ { type = "pointer_up", pointerId = "stale", x = 8, y = 8 } })
    Assert.isNil(flows:takeResult(), "the stale release seals nothing on " .. versionId)
    Assert.isFalse(flows:activateControl("party:1"), "taps miss the closed child on " .. versionId)
    Assert.isTrue(
      flows:open(partyIntent({ party = roster, requestId = 8, epoch = 9 })),
      "the replacement child opens on " .. versionId
    )
    Assert.isTrue(flows:status().active, "the fresh child owns input on " .. versionId)
    flows:dispose()
    local held = coordinator()
    Assert.isTrue(held:open(partyIntent({ party = roster })), "the party child opens for the hold on " .. versionId)
    held:cancelPointerCapture()
    Assert.isNil(held:takeResult(), "cancelling a held press seals nothing on " .. versionId)
    Assert.isTrue(held:status().active, "the child keeps owning input after the cancel on " .. versionId)
    held:dispose()
  end
end

return {
  tests = T,
  metadata = {
    capabilities = { "rom_dump", "derived_assets" },
    derivedAssets = { "mon-catalog:global", "items:global" },
  },
}
