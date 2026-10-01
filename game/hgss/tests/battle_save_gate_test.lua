-- Manual-save exclusion across the battle lifecycle: from launch
-- acquisition through the active battle, forced switches, learning prompts,
-- capture placement, evolution, result commit, and the loss/warp return,
-- the existing manual-save coordinator reports a structured busy reason and
-- captures no record. Only the stable field return re-enables capture.

local Assert = require("tests.support.Assert")
local FieldSaveCoordinator = require("game.hgss.src.field.FieldSaveCoordinator")

local RUNTIME_MODULE = "game.hgss.src.battle.BattleRuntime"

local T = {}

---@param name string module path under test
---@param behavior string missing owner under test
---@return table the loaded battle owner
local function requirePresent(name, behavior)
  local ok, loaded = pcall(require, name)
  Assert.isTrue(ok, "missing battle owner: " .. behavior .. " (" .. name .. ")")
  assert(loaded ~= nil, "the battle module loads")
  return loaded --[[@as table]]
end

---@return table headless presentation port acknowledging immediately
local function headlessPort()
  return {
    enter = function(_plan)
      return true
    end,
    present = function(_frame) end,
    leave = function(_plan)
      return true
    end,
    dispose = function() end,
  }
end

---@param battle table live application battle lifetime in an unsafe subflow
---@return table runtime double with a stable session behind the active battle
local function runtimeBehindBattle(battle)
  return {
    battleRuntime = battle,
    pokemonMenu = nil,
    playerAvatar = nil,
    session = {
      player = { motion = "idle" },
      transition = { phase = "idle" },
      mapEntryController = { isActive = function()
        return false
      end },
      dialogue = { isModal = function()
        return false
      end },
      signpost = { isModal = function()
        return false
      end },
      applicationHost = nil,
    },
  }
end

function T.manual_save_stays_busy_through_battle_and_completion()
  local BattleRuntime = requirePresent(RUNTIME_MODULE, "application battle lifetime consulted by manual save")
  Assert.isTrue(type(BattleRuntime.canSave) == "function", "the runtime answers whether durable save is safe")
  Assert.isTrue(type(BattleRuntime.status) == "function", "the runtime reports its lifecycle phase")
  Assert.isTrue(type(BattleRuntime.dispose) == "function", "the runtime releases its battle ownership")

  local launch = { id = "launch-save-gate", kind = "trainer", payload = { trainer = "first_rival" } }
  local battle = BattleRuntime.new({ request = launch, presentation = headlessPort() })
  local coordinator = FieldSaveCoordinator.new(runtimeBehindBattle(battle))

  -- Every unsafe subflow reports busy with its phase and captures nothing:
  -- launch wait, the active battle, forced switch, learning, capture
  -- placement, evolution, result commit, and the loss return.
  for _, phase in ipairs({ "preparing", "entering", "running", "resolving", "postbattle", "returning" }) do
    while battle:status().phase ~= phase and battle:status().phase ~= "complete" do
      battle:update()
    end
    if battle:status().phase == "complete" then
      break
    end
    Assert.equal(battle:status().phase, phase, "the runtime reaches the unsafe subflow under test")
    local busy, reason = battle:canSave()
    Assert.isFalse(busy, "durable save stays busy through " .. phase)
    Assert.isTrue(type(reason) == "table", "the busy answer is structured through " .. phase)
    Assert.equal(reason.phase, phase, "the busy reason names the owning subflow")
    local record, captureReason = coordinator:captureManual()
    Assert.isNil(record, "no partial-state record is captured during " .. phase)
    Assert.notNil(captureReason, "the coordinator names the battle through " .. phase)
    local menuRecord, menuReason = coordinator:capture(true)
    Assert.isNil(menuRecord, "menu capture also refuses during " .. phase)
    Assert.notNil(menuReason, "menu capture also names the battle through " .. phase)
  end

  -- A cancelled session never leaves a saveable partial snapshot behind:
  -- disposal without publication keeps the gate closed until the field
  -- restoration completes.
  battle:dispose()
  local cancelled, cancelReason = coordinator:captureManual()
  Assert.isNil(cancelled, "a cancelled battle captures no partial-state record")
  Assert.notNil(cancelReason, "a cancelled battle still names its busy reason")
end

return { tests = T }
