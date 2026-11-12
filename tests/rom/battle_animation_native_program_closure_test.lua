-- Bounded source closure over the owned dump: named branch-heavy roots
-- close through their own members with factory-supported tasks, the
-- plane-clear-plus-callback framing stays closed on its corpus member,
-- and the follower enter/recall pair resolves its own roots. Real
-- members stream through the real producer; no commercial bytes enter
-- the repository. Occurrence execution through the player belongs to the
-- animation-player suite behind synthetic programs; this file proves
-- closure only.

local Assert = require("tests.support.Assert")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local function compiler()
  return require("romdump.src.digest.battle.BattlePresentationCompiler")
end

local function factory()
  return require("libs.hgss.src.presentation.BattleEffectTasks")
end

local function closeEffect(romFs, versionId, effectKey)
  local effect, err = compiler().compileEffect(romFs, { versionId = versionId }, effectKey)
  Assert.isNil(err, effectKey .. " closes without a source failure: " .. tostring(err))
  Assert.notNil(effect, effectKey .. " closes through its selected source member")
  return assert(effect)
end

local function instructionOps(effect)
  local ops = {}
  for _, instruction in ipairs(effect.program.instructions) do
    ops[#ops + 1] = instruction.op
  end
  return ops
end

function T.plane_clear_keeps_the_following_callback_on_its_corpus_member(romFs, versionId)
  local effect = closeEffect(romFs, versionId, "EXTRASENSORY")
  local ops = instructionOps(effect)
  local cleared = nil
  for index, op in ipairs(ops) do
    if op == "clear-background-plane" then
      cleared = index
      break
    end
  end
  Assert.notNil(cleared, "the corpus member clears its battler plane")
  local following = effect.program.instructions[assert(cleared) + 1]
  Assert.notNil(following, "a command follows the plane clear")
  Assert.isTrue(
    following.callback ~= nil or following.op == "replace-parameters-and-call",
    "the word after the clear decodes as a callback instead of an operand"
  )
end

function T.branch_heavy_roots_close_with_supported_tasks(romFs, versionId)
  local kinds = factory()
  for _, effectKey in ipairs({ "BATON_PASS", "FLY", "SOLAR_BEAM" }) do
    local effect = closeEffect(romFs, versionId, effectKey)
    local branched = false
    for _, instruction in ipairs(effect.program.instructions) do
      if instruction.branchTarget ~= nil or instruction.branchCases ~= nil then
        branched = true
      end
    end
    Assert.isTrue(branched, effectKey .. " keeps its source branch structure")
    for _, taskKind in ipairs(effect.program.taskKinds) do
      Assert.isTrue(kinds.supportsKind(taskKind), effectKey .. " stages only factory-supported tasks: " .. taskKind)
    end
  end
end

function T.follower_enter_and_recall_close_through_their_own_members(romFs, versionId)
  for _, effectKey in ipairs({ "BATTLE_ANIMATION_FOLLOWER_ENTER", "BATTLE_ANIMATION_FOLLOWER_RECALL" }) do
    closeEffect(romFs, versionId, effectKey)
  end
end

-- Programs that once failed closure for source-reading reasons close
-- through their own members with factory-supported tasks: ERUPTION
-- carries a side-ignoring emitter offset, DARK_VOID an opposing-pair
-- picture word, and DISABLE, TOXIC, and LUNAR_DANCE blend their
-- sprites' palettes.
function T.previously_unclosed_roots_close_with_supported_tasks(romFs, versionId)
  local kinds = factory()
  for _, effectKey in ipairs({ "ERUPTION", "DARK_VOID", "DISABLE", "TOXIC", "LUNAR_DANCE" }) do
    local effect = closeEffect(romFs, versionId, effectKey)
    for _, taskKind in ipairs(effect.program.taskKinds) do
      Assert.isTrue(kinds.supportsKind(taskKind), effectKey .. " stages only factory-supported tasks: " .. taskKind)
    end
  end
end

local readyVersions = {}
for _, versionId in ipairs(GameVersion.ORDER) do
  if RomImporter.isReady(versionId) then
    readyVersions[#readyVersions + 1] = versionId
  end
end

local RomSourcePath = require("tests.rom.support.RomSourcePath")

return RomSuite.build({
  tests = T,
  readyVersions = readyVersions,
  open = RomSourcePath.openReader,
})
