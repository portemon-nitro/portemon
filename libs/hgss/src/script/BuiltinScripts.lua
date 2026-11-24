-- Definitions for scripts owned by the runtime rather than the generated ROM
-- corpus or the mod override layer. These resources still use the normal
-- script compiler and scheduler path.

local S = require("gen4.script")
local Bindings = require("libs.hgss.src.script.Bindings")
local LuaWriter = require("libs.codec.src.LuaWriter")
local Sha256 = require("libs.script.src.Sha256")

local BuiltinScripts = {}

-- The runtime-owned menu-to-field entry script id: claims the queued
-- field request into serializable task state through the existing
-- foreground scheduler. One script for every move and slot; no per-move
-- scripts and no temporary global variables.
BuiltinScripts.FIELD_MOVE_ENTRY_SCRIPT = "runtime.field_move_entry"

-- The runtime-owned Sweet Scent script (a field task in the source, with no
-- script of its own): the scent task, then a wild battle for a prepared
-- encounter or the faded-weather / nothing-happened standard message.
BuiltinScripts.SWEET_SCENT_SCRIPT = "runtime.sweet_scent"

-- The standard scripts the source queues after the scent task: 2018 says
-- nothing happened, 2019 says the scent faded.
local NOTHING_HAPPENED_SCRIPT = "common.honey_sweet_scent_nothing_happened"
local SCENT_FADED_SCRIPT = "common.honey_sweet_scent_faded"

local function sweetScentSteps()
  local outcome = S.local_("outcome")
  return {
    S.sweetScent({ result = outcome }),
    S.if_({
      condition = S.eq(outcome, 2),
      yes = { S.battleLaunch({ kind = "wild" }) },
      no = {
        S.if_({
          condition = S.eq(outcome, 1),
          yes = { S.callCommon({ target = SCENT_FADED_SCRIPT }) },
          no = { S.callCommon({ target = NOTHING_HAPPENED_SCRIPT }) },
        }),
      },
    }),
  }
end

-- The runtime-owned fishing scripts, one per rod (Task_OverworldFish is a
-- field task in the source, with no script of its own): the cast, the
-- rod's result message dismissed with A or B, the rod stowed, then the wild
-- battle for a landed Pokemon. Every map object holds still throughout and
-- resumes unless the battle takes over.
BuiltinScripts.FISHING_SCRIPTS = {
  old_rod = "runtime.fishing.old_rod",
  good_rod = "runtime.fishing.good_rod",
  super_rod = "runtime.fishing.super_rod",
}

-- The rod's result messages (msg_0040): 49 no bite, 50 got away, 51 reeled
-- in too soon, 52 landed, by the fishing task's outcome code.
local FISHING_MESSAGES = {
  [0] = "msg.hgss.0040.00049",
  [1] = "msg.hgss.0040.00051",
  [2] = "msg.hgss.0040.00050",
  [3] = "msg.hgss.0040.00052",
}
local FISHING_LANDED = 3

local function fishingSteps(rod)
  local outcome = S.local_("outcome")
  local steps = { S.lockAll({}), S.fishing({ stage = "cast", rod = rod, result = outcome }) }
  for code = 0, FISHING_LANDED do
    steps[#steps + 1] = S.if_({
      condition = S.eq(outcome, code),
      yes = { S.message({ message = FISHING_MESSAGES[code], waitForPrint = true }) },
    })
  end
  steps[#steps + 1] = S.waitInput({})
  steps[#steps + 1] = S.closeMessage({ erase = true })
  steps[#steps + 1] = S.fishing({ stage = "put_away" })
  steps[#steps + 1] = S.if_({
    condition = S.eq(outcome, FISHING_LANDED),
    yes = { S.battleLaunch({ kind = "wild" }) },
    no = { S.releaseAll({}) },
  })
  return steps
end

-- The runtime-owned Bicycle script (Task_MountOrDismountBicycle): mounts a
-- walking player and dismounts a rider.
BuiltinScripts.BICYCLE_SCRIPT = "runtime.bicycle"

local function bicycleSteps()
  local riding = S.var("VAR_SPECIAL_RESULT")
  return {
    S.playerOnBikeCheck({ result = riding }),
    S.if_({
      condition = S.eq(riding, 1),
      yes = { S.playerOnBikeSet({ riding = false }) },
      no = { S.playerOnBikeSet({ riding = true }) },
    }),
  }
end

-- The registered key item's refusal (GetItemUseErrorMessage), by the
-- item check's decision: the escort, costume, and Cycling Road refusals
-- from the Bag bank, and Oak's words naming the player for every other
-- refusal.
BuiltinScripts.ITEM_USE_REFUSAL_SCRIPTS = {
  have_follower = "runtime.item_use_refusal.have_follower",
  no_dismount = "runtime.item_use_refusal.no_dismount",
  not_now = "runtime.item_use_refusal.not_now",
  not_here = "runtime.item_use_refusal.not_here",
}

local REFUSAL_MESSAGES = {
  have_follower = "msg.hgss.0010.00118",
  no_dismount = "msg.hgss.0010.00057",
  not_now = "msg.hgss.0010.00119",
  not_here = "msg.hgss.0040.00037",
}

local function refusalSteps(kind)
  return {
    S.bufferText({ slot = 0, value = S.playerName() }),
    S.message({ message = REFUSAL_MESSAGES[kind], waitForPrint = true }),
    S.waitInput({}),
    S.closeMessage({ erase = true }),
  }
end

---@return table<string, table<string, unknown>>
function BuiltinScripts.all()
  local scripts = {
    [Bindings.CANONICAL_INERT_SCRIPT] = S.script({
      api = 1,
      id = Bindings.CANONICAL_INERT_SCRIPT,
      steps = { S.stop() },
    }),
    [BuiltinScripts.FIELD_MOVE_ENTRY_SCRIPT] = S.script({
      api = 1,
      id = BuiltinScripts.FIELD_MOVE_ENTRY_SCRIPT,
      steps = { S.fieldMove({ source = "pending" }) },
    }),
    [BuiltinScripts.SWEET_SCENT_SCRIPT] = S.script({
      api = 1,
      id = BuiltinScripts.SWEET_SCENT_SCRIPT,
      locals = { outcome = "integer" },
      steps = sweetScentSteps(),
    }),
    [BuiltinScripts.BICYCLE_SCRIPT] = S.script({
      api = 1,
      id = BuiltinScripts.BICYCLE_SCRIPT,
      steps = bicycleSteps(),
    }),
  }
  for rod, id in pairs(BuiltinScripts.FISHING_SCRIPTS) do
    scripts[id] = S.script({ api = 1, id = id, locals = { outcome = "integer" }, steps = fishingSteps(rod) })
  end
  for kind, id in pairs(BuiltinScripts.ITEM_USE_REFUSAL_SCRIPTS) do
    scripts[id] = S.script({ api = 1, id = id, steps = refusalSteps(kind) })
  end
  return scripts
end

-- The digest covers the executable builtin projection, including ids and
-- script data, with the same deterministic serializer used by registry
-- fingerprints.
---@return string
function BuiltinScripts.contentHash()
  return Sha256.hex(LuaWriter.encode(BuiltinScripts.all()))
end

return BuiltinScripts
