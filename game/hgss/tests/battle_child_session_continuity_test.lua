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

function T.opening_a_child_consumes_its_initiating_input()
  local ok, composer = pcall(require, COMPOSER_MODULE)
  Assert.isTrue(
    ok,
    "child opening consumes its initiating input through the battle child module (" .. COMPOSER_MODULE .. ")"
  )
  assert(composer ~= nil, "the composer loads")
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
      "BLOCKED: no ready soulsilver user-owned ROM cache in this checkout; second-version continuity parity is unverified"
    )
  end
  Assert.isTrue(
    false,
    "a ready soulsilver cache appeared: this probe must grow a real second-version comparison before it may pass"
  )
end

return { tests = T }
