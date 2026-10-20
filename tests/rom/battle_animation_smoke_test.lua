-- Fast ROM-backed smoke cover for battle-animation closure: a handful of
-- moves that failed before (selector gaps, callback-17 config trailers,
-- ClearBattlerBg framing) close through compileEffect without building
-- the global catalog or stepping traces. The full-corpus inventory suite
-- this replaces never finished inside a useful gate window; the component
-- compiler tests pin framing rules, this pins end-to-end ROM closure.

local Assert = require("tests.support.Assert")
local RomSuite = require("tests.rom.support.RomSuite")
local RomSourcePath = require("tests.rom.support.RomSourcePath")
local RomImporter = require("romdump.src.source.RomImporter")

local T = {}

local SMOKE_EFFECTS = {
  "WHIRLWIND",
  "ROAR",
  "MEGAHORN",
  "SHADOW_PUNCH",
  "EXTRASENSORY",
  "GUST",
}

local function hasTaskKind(effect, kind)
  local program = effect.program
  if type(program) ~= "table" or type(program.taskKinds) ~= "table" then
    return false
  end
  for _, taskKind in ipairs(program.taskKinds) do
    if taskKind == kind then
      return true
    end
  end
  return false
end

function T.previously_failing_effects_close_through_compile(romFs, versionId)
  local compiler = require("romdump.src.digest.battle.BattlePresentationCompiler")
  for _, effectKey in ipairs(SMOKE_EFFECTS) do
    local effect, err = compiler.compileEffect(romFs, { versionId = versionId }, effectKey)
    Assert.isNil(err, effectKey .. " closes without a source failure: " .. tostring(err))
    Assert.notNil(effect, effectKey .. " closes through its selected source member")
    Assert.equal(effect.key, effectKey, effectKey .. " closure carries its semantic key")
    Assert.isTrue(type(effect.program) == "table", effectKey .. " closure carries its program")
    Assert.isTrue(type(effect.resources) == "table", effectKey .. " closure carries its staged resources")
    Assert.isTrue(
      type(effect.requiredContext) == "table",
      effectKey .. " closure declares its typed runtime inputs"
    )
  end
  local whirlwind, whirlwindErr =
    compiler.compileEffect(romFs, { versionId = versionId }, "WHIRLWIND")
  Assert.isNil(whirlwindErr, "WHIRLWIND closure carries no error for the task-kind probe")
  Assert.isTrue(
    hasTaskKind(whirlwind, "pokemon-picture-linear-offscreen-transition"),
    "WHIRLWIND stages its defender offscreen slide"
  )
  Assert.isTrue(
    hasTaskKind(whirlwind, "pokemon-picture-reset-position-transition"),
    "WHIRLWIND stages its defender reset marker"
  )
  local shadowPunch, shadowPunchErr =
    compiler.compileEffect(romFs, { versionId = versionId }, "SHADOW_PUNCH")
  Assert.isNil(shadowPunchErr, "SHADOW_PUNCH closure carries no error for the task-kind probe")
  Assert.isTrue(
    hasTaskKind(shadowPunch, "pokemon-picture-attacker-dash-afterimages"),
    "SHADOW_PUNCH stages its attacker dash hold"
  )
end

return RomSuite.build({
  tests = T,
  readyVersions = RomImporter.isReady("heartgold") and { "heartgold" } or {},
  open = RomSourcePath.openReader,
})
