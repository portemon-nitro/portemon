-- Checked-in source identity is immutable and contains no update channel.

local Assert = require("tests.support.Assert")

local T = {}

function T.source_build_identity_is_exactly_the_development_record()
  local BuildInfo = require("app.src.BuildInfo")
  Assert.keySet(BuildInfo, "commit,version")
  Assert.equal(BuildInfo.version, "dev")
  Assert.equal(BuildInfo.commit, "development")
end

return { tests = T }
