-- Script CallFunc words behind the boosted, dropped, and presented
-- object-window stripe runs must reach the player: the graphic (Arg0)
-- and target (Arg1) select the staged stripe row and the silhouetted
-- battler, so dropping them replays the wrong feedback (stat drops
-- played the raise stripes). Three representatives cover the graphic
-- and target dimensions; every other stripe run shares the same
-- lowering path, proven selector-by-selector in the compiler suite.
local Assert = require("tests.support.Assert")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local EXPECTED_ARGS = {
  BATTLE_ANIMATION_STAT_BOOST = { 0, 0 },
  BATTLE_ANIMATION_STAT_DROP = { 1, 0 },
  PRESENT = { 2, 1 },
}

function T.panel_script_words_lower_onto_the_invocation(romFs, versionId)
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local keys = {}
  for key in pairs(EXPECTED_ARGS) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local effect, err = compiler.compileEffect(romFs, { versionId = versionId }, key)
    Assert.isNil(err, key .. " compiles: " .. tostring(err))
    Assert.notNil(effect, key .. " closes through its selected member")
    local panels = 0
    for _, instruction in ipairs(effect.program.instructions) do
      if
        instruction.op == "invoke-battle-animation-callback"
        and instruction.taskKind == "battle-sprite-panel-slide"
      then
        panels = panels + 1
        Assert.deepEqual(instruction.args, EXPECTED_ARGS[key], key .. " lowers its script graphic and target words")
      end
    end
    Assert.isTrue(panels >= 1, key .. " stages at least one panel run")
  end
end

return RomSuite.fromFacts(T)
