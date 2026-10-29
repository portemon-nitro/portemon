-- Exhaustive ROM census behind on-demand battle effects: every move and
-- battle-animation semantic root closes through compileEffect, the exact
-- entry each battle-effect job runs, and stages only task kinds the live
-- native factory admits. Runtime compiles one effect per demanded key, so
-- this corpus walk is the only proof that no root fails when a battle first
-- reaches it. Failures are collected and reported together.

local Assert = require("tests.support.Assert")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

function T.every_semantic_root_closes_through_its_effect_job(romFs, versionId)
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local factory = require("libs.hgss.src.presentation.BattleEffectTasks")
  local sources = require("romdump.src.config.BattleAnimationSources")
  local roots = sources.listSemanticRoots()
  Assert.isTrue(#roots > 0, versionId .. ": the census reaches semantic animation roots")
  local failures = {}
  for _, root in ipairs(roots) do
    local effect, err = compiler.compileEffect(romFs, { versionId = versionId }, root.key)
    if effect == nil then
      failures[#failures + 1] = root.key .. ": " .. tostring(err)
    elseif effect.key ~= root.key then
      failures[#failures + 1] = root.key .. ": closure names " .. tostring(effect.key)
    elseif effect.provenance.archiveSymbol ~= root.archiveSymbol or effect.provenance.memberId ~= root.memberId then
      failures[#failures + 1] = root.key .. ": compiled provenance differs from its semantic route"
    else
      for _, taskKind in ipairs(effect.program.taskKinds) do
        if not factory.supportsKind(taskKind) then
          failures[#failures + 1] = root.key .. ": unadmitted native task kind " .. tostring(taskKind)
        end
      end
      for resourceKey, descriptor in pairs(effect.resources) do
        if effect.resourcePayloads[descriptor.payload] == nil then
          failures[#failures + 1] = root.key .. ": resource " .. resourceKey .. " has no staged payload"
        end
      end
    end
  end
  Assert.equal(#failures, 0, versionId .. ": every semantic root closes:\n" .. table.concat(failures, "\n"))
end

local suite = RomSuite.fromFacts(T)
suite.metadata.fullCorpus = true
suite.metadata.tags = { "census", "battle" }
return suite
