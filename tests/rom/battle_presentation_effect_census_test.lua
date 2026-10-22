-- Opt-in exhaustive audit over every semantic battle-animation root. This
-- suite never runs in routine verification: it walks all 467 moves plus
-- every named non-move animation through the real producer and checks each
-- closure against the live native task factory, streaming one root at a
-- time so no giant resource map is retained. A missing member, an
-- undecoded payload, or a task kind without a real factory body fails with
-- the root key and version; an absent source dump fails loudly instead of
-- reporting coverage.

local Assert = require("tests.support.Assert")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local RomSuite = require("tests.rom.support.RomSuite")
local RomSourcePath = require("tests.rom.support.RomSourcePath")

local T = {}

-- Line-buffered progress: the harness redirects stdout to a file, and a
-- killed or timed-out census must still show how far the stream got.
if io.stdout ~= nil and io.stdout.setvbuf ~= nil then
  io.stdout:setvbuf("line")
end

local function recordFailure(failures, root, versionId, detail)
  failures[#failures + 1] = root.key .. " (" .. versionId .. "): " .. tostring(detail)
end

function T.every_semantic_root_closes_with_admitted_tasks_and_staged_payloads(romFs, versionId)
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local factory = require("libs.hgss.src.presentation.BattleEffectTasks")
  local sources = require("romdump.src.config.BattleAnimationSources")
  local roots = sources.listSemanticRoots()
  Assert.isTrue(#roots > 0, "the producer enumerates a nonempty semantic root set")
  local moveCount = 0
  local nonMoveCount = 0
  for _, root in ipairs(roots) do
    if root.kind == "move" then
      moveCount = moveCount + 1
    else
      nonMoveCount = nonMoveCount + 1
    end
  end
  Assert.equal(moveCount, 467, "the census walks the full pinned move ladder")
  Assert.isTrue(nonMoveCount >= 1, "the census walks at least one named non-move animation")
  Assert.equal(#roots, moveCount + nonMoveCount, "every enumerated root is accounted for")

  local failures = {}
  local distinctKinds = {}
  local startedAt = os.clock()
  for index, root in ipairs(roots) do
    local effect, err = compiler.compileEffect(romFs, { versionId = versionId }, root.key)
    if effect == nil then
      recordFailure(failures, root, versionId, err)
    else
      if effect.key ~= root.key then
        recordFailure(failures, root, versionId, "closure carries key " .. tostring(effect.key))
      end
      if type(effect.program) ~= "table" or type(effect.program.taskKinds) ~= "table" then
        recordFailure(failures, root, versionId, "closure carries no staged task list")
      else
        if #effect.program.taskKinds < 1 then
          recordFailure(failures, root, versionId, "closure stages no native task kind")
        end
        for _, taskKind in ipairs(effect.program.taskKinds) do
          distinctKinds[taskKind] = true
          if not factory.supportsKind(taskKind) then
            recordFailure(failures, root, versionId, "unsupported native task kind " .. tostring(taskKind))
          end
        end
      end
      if type(effect.resources) == "table" then
        for resourceKey, descriptor in pairs(effect.resources) do
          if effect.resourcePayloads == nil or effect.resourcePayloads[descriptor.payload] == nil then
            recordFailure(
              failures,
              root,
              versionId,
              "missing staged payload for resource " .. tostring(resourceKey)
            )
          end
        end
      else
        recordFailure(failures, root, versionId, "closure carries no staged resources")
      end
      if type(effect.requiredContext) ~= "table" then
        recordFailure(failures, root, versionId, "closure declares no typed runtime inputs")
      elseif effect.requiredContext.movePower ~= nil then
        if type(effect.requiredContext.movePower.type) ~= "string" then
          recordFailure(failures, root, versionId, "move-power context declares no event-time type")
        end
        if effect.requiredContext.movePower.value ~= nil then
          recordFailure(failures, root, versionId, "move-power context guesses a value before the event")
        end
      end
    end
    effect = nil
    if index % 64 == 0 then
      collectgarbage("collect")
      print(
        ("battle-effect census %s progress: %d/%d roots, %.1fs, lua heap %.1fMB"):format(
          versionId,
          index,
          #roots,
          os.clock() - startedAt,
          collectgarbage("count") / 1024
        )
      )
    end
  end
  local elapsed = os.clock() - startedAt
  local distinctCount = 0
  for _ in pairs(distinctKinds) do
    distinctCount = distinctCount + 1
  end
  print(
    ("battle-effect census %s: %d roots, %d distinct task kinds, %d failures, %.1fs"):format(
      versionId,
      #roots,
      distinctCount,
      #failures,
      elapsed
    )
  )
  if #failures > 0 then
    local shown = {}
    for index = 1, math.min(#failures, 20) do
      shown[#shown + 1] = failures[index]
    end
    if #failures > #shown then
      shown[#shown + 1] = ("... and %d more"):format(#failures - #shown)
    end
    Assert.equal(#failures, 0, "every semantic root closes cleanly:\n" .. table.concat(shown, "\n"))
  end
end

-- Each ready dump is censused on its own reader; with no ready dump the
-- census fails loudly instead of reporting coverage it never walked.
local readyVersions = {}
for _, versionId in ipairs(GameVersion.ORDER) do
  if RomImporter.isReady(versionId) then
    readyVersions[#readyVersions + 1] = versionId
  end
end

local suite = RomSuite.build({
  tests = T,
  readyVersions = readyVersions,
  open = RomSourcePath.openReader,
})
-- A census that opened no source dump must fail instead of passing over an
-- empty version set; the runner only reaches this hook in the explicit
-- opt-in mode, so routine listing and filtering never touch it.
local suiteBeforeAll = suite.beforeAll
function suite.beforeAll()
  if #readyVersions == 0 then
    error("no ready game dump to census", 0)
  end
  return suiteBeforeAll()
end
suite.metadata.fullCorpus = true
suite.metadata.tags = { "battle", "animation", "census" }
return suite
