-- Screen tests use semantic trainer and ball facts in their detached packets.
local BattleScreenState = require("game.hgss.src.battle.BattleScreenState")
local BattlePresentationManifestFixture = require("tests.support.BattlePresentationManifestFixture")

local BattleScreenFixture = {}
setmetatable(BattleScreenFixture, { __index = BattleScreenState })

local function completeView(view, battleKind)
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
    view.foeTrainers = battleKind == "wild" and {} or { { classKey = "YOUNGSTER", name = "WHITNEY" } }
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
  if battleKind ~= "wild" and type(view.participants) == "table" and #view.participants == 0 and #view.foeTrainers > 0 then
    local foes = view.foes or {}
    for index, trainer in ipairs(view.foeTrainers) do
      local foe = foes[math.min(index, #foes)]
      local participant = trainer.participant or (type(foe) == "table" and foe.combatant)
      if type(participant) == "number" then
        trainer.participant = participant
        view.participants[#view.participants + 1] = {
          participant = participant,
          side = 2,
          controller = "trainer:" .. tostring(participant),
        }
      end
    end
    for index, foe in ipairs(foes) do
      local trainer = view.foeTrainers[math.min(index, #view.foeTrainers)]
      if type(foe) == "table" and type(trainer) == "table" then
        foe.participant = trainer.participant
      end
    end
  end
end

function BattleScreenFixture.new(options)
  local defaults = BattlePresentationManifestFixture.launchView(
    { "back:PKMN_TRAINER_ETHAN", "front:YOUNGSTER", "front:LEADER_FALKNER" },
    { "ball:POKE_BALL" }
  )
  local manifest = options.manifest
  if type(manifest) == "table" then
    manifest = setmetatable({}, { __index = manifest })
  else
    manifest = defaults
  end
  local trainers = type(manifest.trainerPictures) == "table" and manifest.trainerPictures.entries or nil
  if type(trainers) ~= "table" then
    trainers = {}
    manifest.trainerPictures = { entries = trainers }
  end
  for selector, entry in pairs(defaults.trainerPictures.entries) do
    if trainers[selector] == nil then
      trainers[selector] = entry
    end
  end
  local balls = type(manifest.battleBalls) == "table" and manifest.battleBalls.entries or nil
  if type(balls) ~= "table" then
    balls = {}
    manifest.battleBalls = { entries = balls }
  end
  for selector, entry in pairs(defaults.battleBalls.entries) do
    if balls[selector] == nil then
      balls[selector] = entry
    end
  end
  options.manifest = manifest
  local screen = BattleScreenState.new(options)
  local present = screen._portPresent
  function screen:_portPresent(packet)
    completeView(packet.before, self._kind)
    completeView(packet.after, self._kind)
    return present(self, packet)
  end
  return screen
end

return BattleScreenFixture
