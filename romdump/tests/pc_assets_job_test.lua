-- The PC presentation is one closed cache family with a single global key.

local Assert = require("tests.support.Assert")
local ArtifactState = require("romdump.src.build.ArtifactState")
local ArtifactJobs = require("romdump.src.build.ArtifactJobs")

local T = {}

function T.pc_family_receipt_uses_only_the_global_key()
  local accepted, path = pcall(ArtifactState.path, "pc", "global")
  Assert.isTrue(accepted, "the PC cache family must admit its global receipt")
  Assert.equal(path, "data/generated/jobs/pc/global.lua")

  local acceptedNonGlobalKey = pcall(ArtifactState.path, "pc", "0")
  Assert.isFalse(acceptedNonGlobalKey, "the PC cache family must reject non-global keys")
end

function T.pc_is_required_by_field_runtime_and_not_new_game_intro()
  local fieldRuntime = false
  for _, job in ipairs(ArtifactJobs.fieldRuntimeJobs()) do
    fieldRuntime = fieldRuntime or (job.kind == "pc" and job.key == "global")
  end
  Assert.isTrue(fieldRuntime, "field runtime prepares the PC presentation family")

  local intro, complete = ArtifactJobs.newGameIntroJobs(nil)
  Assert.isFalse(complete, "the intro closure remains unresolved without its audio plan")
  for _, job in ipairs(intro) do
    Assert.isFalse(job.kind == "pc", "Oak-only preparation does not pull the PC presentation family")
  end
end

function T.pc_dependencies_reuse_shared_font_and_semantic_catalogs()
  local dependencies, complete = ArtifactJobs.dependencies("pc", "global", {})
  Assert.isTrue(complete, "PC family dependencies are statically known")
  local identities = {}
  for _, dependency in ipairs(dependencies) do
    identities[#identities + 1] = dependency.kind .. ":" .. dependency.key
  end
  Assert.equal(table.concat(identities, ","), "field-font:global,items:global,mon-catalog:global")
end

return { tests = T }
