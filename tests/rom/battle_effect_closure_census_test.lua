-- Exhaustive ROM census behind on-demand battle effects: every move and
-- battle-animation semantic root closes through compileEffect, the exact
-- entry each battle-effect job runs, and stages only task kinds the live
-- native factory admits. Runtime compiles one effect per demanded key, so
-- this corpus walk is the only proof that no root fails when a battle first
-- reaches it. Failures are collected and reported together.

local Assert = require("tests.support.Assert")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local VISUAL_OPS = {
  ["show-pokemon-picture"] = true,
  ["set-pokemon-picture-vanished"] = true,
  ["create-pokemon-sprite"] = true,
  ["load-battle-background"] = true,
  ["invoke-battle-animation-callback"] = true,
  ["create-battler-effect"] = true,
  ["create-parameterized-battler-effect"] = true,
  ["create-configured-sprite"] = true,
  ["create-managed-sprite"] = true,
  ["start-visual-task"] = true,
  ["start-battler-effect"] = true,
  ["start-sprite-effect"] = true,
  ["update-battle-visual"] = true,
  ["submit-presentation-layout"] = true,
  ["submit-presentation-update"] = true,
}

local function classifyProgram(program)
  local instructions = 0
  local visualOpcode = false
  local opcodes = {}
  local function collect(body)
    for _, instruction in ipairs(body) do
      instructions = instructions + 1
      opcodes[instruction.op] = true
      visualOpcode = visualOpcode or VISUAL_OPS[instruction.op] == true
    end
  end
  collect(program.instructions)
  for _, subprogram in pairs(program.subprograms or {}) do
    collect(subprogram.instructions)
  end
  local visualTask = false
  for _, taskKind in ipairs(program.taskKinds or {}) do
    visualTask = visualTask or string.find(taskKind, "sound", 1, true) == nil
  end
  return {
    instructions = instructions,
    opcodes = opcodes,
    hasVisual = visualOpcode or visualTask,
  }
end

function T.every_semantic_root_closes_through_its_effect_job(romFs, versionId)
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  local factory = require("libs.hgss.src.presentation.BattleEffectTasks")
  local sources = require("romdump.src.config.BattleAnimationSources")
  local roots = sources.listSemanticRoots()
  Assert.isTrue(#roots > 0, versionId .. ": the census reaches semantic animation roots")
  local failures = {}
  local moveRoots = 0
  local visualRoots = 0
  local zeroVisualRoots = 0
  local opcodeKinds = {}
  local taskKinds = {}
  local zeroVisualKeys = {}
  local resourceCount = 0
  local textureResources = 0
  for _, root in ipairs(roots) do
    moveRoots = moveRoots + (root.kind == "move" and 1 or 0)
    local effect, err = compiler.compileEffect(romFs, { versionId = versionId }, root.key)
    if effect == nil then
      failures[#failures + 1] = root.key .. ": " .. tostring(err)
    elseif effect.key ~= root.key then
      failures[#failures + 1] = root.key .. ": closure names " .. tostring(effect.key)
    else
      if
        effect.provenance.archiveSymbol ~= root.archiveSymbol
        or effect.provenance.memberId ~= root.memberId
      then
        failures[#failures + 1] = root.key .. ": compiled provenance differs from its semantic route"
      end
      local classification = classifyProgram(effect.program)
      if classification.instructions == 0 then
        failures[#failures + 1] = root.key .. ": compiled source closure has no instructions"
      end
      for opcode in pairs(classification.opcodes) do
        opcodeKinds[opcode] = true
      end
      for _, taskKind in ipairs(effect.program.taskKinds) do
        taskKinds[taskKind] = true
        if not factory.supportsKind(taskKind) then
          failures[#failures + 1] = root.key .. ": unadmitted native task kind " .. tostring(taskKind)
        end
      end
      local rootTextures = 0
      for resourceKey, descriptor in pairs(effect.resources) do
        resourceCount = resourceCount + 1
        if effect.resourcePayloads[descriptor.payload] == nil then
          failures[#failures + 1] = root.key .. ": resource " .. resourceKey .. " has no staged payload"
        end
        if descriptor.kind == "texture" then
          rootTextures = rootTextures + 1
          textureResources = textureResources + 1
        end
      end
      if classification.hasVisual or rootTextures > 0 then
        visualRoots = visualRoots + 1
      elseif #effect.program.taskKinds == 0 then
        -- An exact compiled source stream with no rendering opcode, visual task,
        -- or texture closure is the explicit zero-visual source expectation.
        zeroVisualRoots = zeroVisualRoots + 1
        zeroVisualKeys[#zeroVisualKeys + 1] = root.key
      else
        failures[#failures + 1] = root.key .. ": nonvisual tasks have no source-expected zero-visual classification"
      end
      if root.key == "TAIL_WHIP" or root.key == "HYPNOSIS" then
        if not classification.hasVisual then
          failures[#failures + 1] = root.key .. ": named move compiles without a visual source operation"
        end
        if rootTextures == 0 and root.key == "HYPNOSIS" then
          failures[#failures + 1] = root.key .. ": copied battler picture has no source texture closure"
        end
      end
    end
  end
  Assert.equal(#failures, 0, versionId .. ": every semantic root closes:\n" .. table.concat(failures, "\n"))
  Assert.isTrue(moveRoots >= 467, versionId .. ": the inventory includes every routed move root")
  print(
    versionId
      .. ": moveRoots="
      .. tostring(moveRoots)
      .. " visualRoots="
      .. tostring(visualRoots)
      .. " zeroVisualSourceRoots="
      .. tostring(zeroVisualRoots)
      .. "["
      .. table.concat(zeroVisualKeys, ",")
      .. "] resources="
      .. tostring(resourceCount)
      .. " opcodes="
      .. tostring((function()
        local count = 0
        for _ in pairs(opcodeKinds) do
          count = count + 1
        end
        return count
      end)())
      .. " taskKinds="
      .. tostring((function()
        local count = 0
        for _ in pairs(taskKinds) do
          count = count + 1
        end
        return count
      end)())
      .. " textureResources="
      .. tostring(textureResources)
  )
end

local suite = RomSuite.fromFacts(T)
suite.metadata.fullCorpus = true
suite.metadata.tags = { "census", "battle" }
return suite
