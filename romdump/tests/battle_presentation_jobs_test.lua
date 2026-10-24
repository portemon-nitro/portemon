-- Battle presentation worker registration over the real dump: the two
-- kinds live in the closed job table, scene keys validate, and scene
-- demands resolve to the staged global. Assertions are readiness
-- relationships and key rules, never catalog snapshots.
--
-- This suite deliberately declares no derived assets and executes
-- nothing: requesting battle-presentation:global or a battle-scene key
-- as a bare prepare requirement hangs the batch session (the global's
-- dependencies need the adopted audio plan, but bare kind:key
-- requirements never demand the source inventory, so planning waits
-- forever). Requirement sets that also pull a source-plan edge (the
-- graphics suites through their portrait pages) prepare fine, and every
-- such preparation executes these jobs, so a broken execute still fails
-- the run at prepare time. The execute path itself is covered by
-- romdump/tests/cache_builder_test.lua.

local Assert = require("tests.support.Assert")
local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
local ArtifactState = require("romdump.src.build.ArtifactState")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

function T.kinds_sizes_and_keys_follow_the_closed_dispatch()
  Assert.isTrue(ArtifactState.KINDS["battle-presentation"] == true, "the global kind is registered")
  Assert.isTrue(ArtifactState.KINDS["battle-scene"] == true, "the scene kind is registered")
  Assert.equal(ArtifactJobs.sizeClass("battle-presentation"), "normal", "the global job has its lane")
  Assert.equal(ArtifactJobs.sizeClass("battle-scene"), "normal", "scene jobs have their lane")
  Assert.equal(
    ArtifactJobs.jobKey("battle-scene", "general/grass/day"),
    "battle-scene:general/grass/day",
    "scene job keys carry the semantic key"
  )
  Assert.equal(
    ArtifactState.path("battle-scene", "general/grass/day"),
    "data/generated/jobs/battle-scene/general/grass/day.lua",
    "scene receipts nest under their kind"
  )
end

function T.scene_keys_validate_while_effect_backgrounds_do_not()
  local ok = pcall(ArtifactState.path, "battle-scene", "general/grass/day")
  Assert.isTrue(ok, "an ordinary scene key resolves to a receipt path")
  local effectOk = pcall(ArtifactState.path, "battle-scene", "effect/flash/day")
  Assert.isFalse(effectOk, "an effect background never resolves to a receipt path")
  local globalOk = pcall(ArtifactState.path, "battle-presentation", "other")
  Assert.isFalse(globalOk, "the global family carries no other key")
end

function T.scene_demands_resolve_to_the_staged_global()
  local dependencies, complete = ArtifactJobs.dependencies("battle-scene", "general/grass/day", {})
  Assert.isTrue(complete, "scene dependencies resolve without adopted plans")
  Assert.deepEqual(dependencies, { { kind = "battle-presentation", key = "global" } }, "scenes build on the global")
end

return RomSuite.fromFacts(T)
