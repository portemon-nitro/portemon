-- Timeline unit tests resolve narration through synthetic staged message records.
local BattlePresentationManifestFixture = require("tests.support.BattlePresentationManifestFixture")
local BattleTimeline = require("game.hgss.src.battle.BattleTimeline")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")

local BattleTimelineFixture = {}

---@param key string semantic staged message key
---@param substitutions string[] ordered source values
---@return string rendered fixture source text
local function resolve(_, key, substitutions)
  local entries = BattlePresentationManifestFixture.manifest().messages.entries
  local record = assert(entries[key], "timeline fixture stages message key: " .. key)
  local values = {}
  local substitutionIndex = 1
  for _, token in ipairs(record.tokens) do
    if token.kind == "substitution" then
      values[#values + 1] = {
        kind = "glyph",
        text = assert(substitutions[substitutionIndex], "timeline fixture receives source substitutions"),
      }
      substitutionIndex = substitutionIndex + 1
    else
      values[#values + 1] = token
    end
  end
  assert(substitutionIndex == #substitutions + 1, "timeline fixture consumes all source substitutions")
  return FieldMessageText.tokensToText(values)
end

---@param view table<string, unknown>? detached view under fixture enrichment
local function completeView(view)
  if type(view) ~= "table" then
    return
  end
  view.playerTrainer = view.playerTrainer or { classKey = "PKMN_TRAINER_ETHAN", name = "ETHAN" }
  view.playerTrainer.classKey = view.playerTrainer.classKey or "PKMN_TRAINER_ETHAN"
  view.playerTrainer.name = view.playerTrainer.name or "ETHAN"
  view.playerName = view.playerName or "ETHAN"
  view.foeTrainers = view.foeTrainers or { { classKey = "YOUNGSTER", name = "WHITNEY" } }
  for _, trainer in ipairs(view.foeTrainers) do
    trainer.classKey = trainer.classKey or "YOUNGSTER"
    trainer.name = trainer.name or "WHITNEY"
  end
  for _, group in ipairs({ view.own, view.foes }) do
    if type(group) == "table" then
      for _, battler in ipairs(group) do
        if type(battler) == "table" then
          battler.ballKey = battler.ballKey or "POKE_BALL"
          battler.name = battler.name or battler.species
        end
      end
    end
  end
end

---@param opts game.hgss.src.battle.BattleTimeline.Options?
---@return game.hgss.src.battle.BattleTimeline
function BattleTimelineFixture.new(opts)
  opts = opts or {}
  opts.messageText = opts.messageText or resolve
  opts.moveName = opts.moveName or function(move)
    return move == "TACKLE" and "Tackle" or move
  end
  opts.itemName = opts.itemName or function(item)
    return item
  end
  opts.speciesName = opts.speciesName or function(species)
    return species
  end
  local timeline = BattleTimeline.new(opts)
  local reset = timeline.reset
  function timeline:reset(view)
    completeView(view)
    return reset(self, view)
  end
  local intro = timeline.intro
  function timeline:intro(view, wild)
    completeView(view)
    return intro(self, view, wild)
  end
  local present = timeline.present
  function timeline:present(packet, sourceMessages)
    for _, name in ipairs({ "before", "after" }) do
      completeView(packet[name])
    end
    return present(self, packet, sourceMessages)
  end
  return timeline
end

return BattleTimelineFixture
