-- Screen tests use semantic trainer and ball facts in their detached packets.
local BattleScreenState = require("game.hgss.src.battle.BattleScreenState")

local BattleScreenFixture = {}
setmetatable(BattleScreenFixture, { __index = BattleScreenState })

local function completeView(view)
  if type(view) ~= "table" then
    return
  end
  if view.playerTrainer == nil then
    view.playerTrainer = { classKey = "PKMN_TRAINER_ETHAN", name = "ETHAN" }
  end
  view.playerTrainer.classKey = view.playerTrainer.classKey or "PKMN_TRAINER_ETHAN"
  view.playerTrainer.name = view.playerTrainer.name or "ETHAN"
  view.playerName = view.playerName or "ETHAN"
  if view.foeTrainers == nil then
    view.foeTrainers = { { classKey = "YOUNGSTER", name = "WHITNEY" } }
  end
  view.participants = view.participants or {}
  for _, trainer in ipairs(view.foeTrainers) do
    trainer.classKey = trainer.classKey or "YOUNGSTER"
    trainer.name = trainer.name or "WHITNEY"
  end
  for _, group in ipairs({ view.own, view.foes }) do
    if type(group) == "table" then
      for _, battler in ipairs(group) do
        if type(battler) == "table" and battler.ballKey == nil then
          battler.ballKey = "POKE_BALL"
        end
        if type(battler) == "table" and battler.name == nil then
          battler.name = battler.species
        end
      end
    end
  end
  if type(view.participants) == "table" and #view.participants == 0 and #view.foeTrainers > 0 then
    local seen = {}
    for _, foe in ipairs(view.foes or {}) do
      local participant = foe.participant or foe.combatant
      if type(participant) == "number" and not seen[participant] then
        seen[participant] = true
        foe.participant = participant
        view.participants[#view.participants + 1] = {
          participant = participant,
          side = 2,
          controller = "trainer:" .. tostring(participant),
        }
      end
    end
  end
end

function BattleScreenFixture.new(options)
  local screen = BattleScreenState.new(options)
  local present = screen._portPresent
  function screen:_portPresent(packet)
    completeView(packet.before)
    completeView(packet.after)
    return present(self, packet)
  end
  return screen
end

return BattleScreenFixture
