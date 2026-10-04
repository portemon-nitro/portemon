-- Build-dispatch contract for the native summary family: the closed
-- generation-kind vocabulary admits the family, its build edges bind the
-- current mon catalog and layout without dragging portrait pages along,
-- and field runtime enrolls it. Synthetic only; no dump required.

local Assert = require("tests.support.Assert")
local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
local ArtifactState = require("romdump.src.build.ArtifactState")

local T = {}

function T.generation_vocabulary_admits_the_summary_family()
  Assert.isTrue(
    ArtifactState.KINDS.summary == true,
    "the generation-kind vocabulary admits no summary family: the bounded job cannot be addressed"
  )
end

-- The family builds over the current mon catalog and layout families, and
-- never over paged portrait pixels: opening the screen must not demand the
-- whole portrait corpus.
function T.summary_build_edges_bind_catalog_and_layout_only()
  local ok, deps = pcall(ArtifactJobs.dependencies, "summary", "global", {})
  Assert.isTrue(ok, "the summary family has no build dispatch: compilation cannot be planned")
  Assert.isTrue(type(deps) == "table", "summary planning reports its prerequisite edges")
  local set = {}
  for _, dep in ipairs(assert(deps, "summary planning reports its edges")) do
    set[dep.kind .. ":" .. dep.key] = true
  end
  Assert.isTrue(set["mon-catalog:global"] == true, "summary planning keeps its catalog edge")
  Assert.isTrue(set["mon-layout:global"] == true, "summary planning keeps its layout edge")
  for key in pairs(set) do
    Assert.isNil(
      key:match("^mon%-portrait%-page:"),
      "summary planning must not demand portrait pages: " .. key
    )
    Assert.isNil(key:match("^mon%-icon%-page:"), "summary planning must not demand icon pages: " .. key)
  end
end

-- Field runtime enrolls the bounded family so the screen is available
-- without a whole-corpus build.
function T.field_runtime_enrolls_the_summary_family()
  local set = {}
  for _, job in ipairs(ArtifactJobs.fieldRuntimeJobs()) do
    set[job.kind .. ":" .. job.key] = true
  end
  Assert.isTrue(set["summary:global"] == true, "field runtime carries no summary family")
end

return { tests = T }
