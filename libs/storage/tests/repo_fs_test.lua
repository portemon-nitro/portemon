-- RepoFs path confinement: the repo-relative path guard must reject every
-- traversal form (leading/embedded `..`, dot components, backslash and mixed
-- separators, and canonical-root escapes) loudly at the boundary, while normal
-- relative paths keep resolving. This is the sole confinement defense for
-- manifest-supplied file ids, so rejection must be an error, never a silent
-- nil that is indistinguishable from a missing file. Tests run with the repo
-- root as cwd and read real checked-in files, like script_override_test.lua.

local Assert = require("tests.support.Assert")

local RepoFs = require("libs.storage.src.RepoFs")

local T = {
  metadata = {
    tags = { "security", "regression" },
  },
  tests = {},
}

local function assertRejected(fs, path)
  Assert.throws(function()
    fs:read(path)
  end, "traversal path must be rejected: " .. path)
end

function T.tests.traversal_paths_are_rejected()
  local fs = RepoFs.new("data")
  for _, path in ipairs({
    "scripts/../../../../outside",
    "../outside",
    "data/../outside",
    "scripts/../../scripts/../../../../outside",
    "scripts/../outside",
    "./manifests/example.lua",
    "..\\outside",
    "scripts\\..\\outside",
    "scripts/..\\outside",
  }) do
    assertRejected(fs, path)
  end
end

function T.tests.normal_relative_paths_still_resolve()
  local fs = RepoFs.new(".")
  local content = fs:read("libs/storage/src/RepoFs.lua")
  Assert.notNil(content, "normal path must resolve")
  Assert.notNil(string.find(content --[[@as string]], "RepoFs"), "resolved content must be the real file")

  local fsWithTrailingSlash = RepoFs.new("app/")
  Assert.notNil(fsWithTrailingSlash:read("main.lua"), "trailing-slash root must still resolve")

  Assert.isNil(fs:read("no/such/file.lua"), "a missing normal path stays a silent nil")
end

function T.tests.injected_source_bytes_take_precedence_without_changing_checkout_fallback()
  local calls = {}
  local sourceFs = {
    read = function(path)
      calls[#calls + 1] = path
      if path == "data/scripts/overrides/common.pokecenter_pc.lua" then
        return 'return "archived override"\n'
      end
      return nil
    end,
  }
  local archived = RepoFs.new("unused-checkout-root", sourceFs)
  Assert.equal(
    archived:read("data\\scripts\\overrides\\common.pokecenter_pc.lua"),
    'return "archived override"\n',
    "the source reader receives one canonical repo-relative path and its bytes pass through unchanged"
  )
  Assert.deepEqual(calls, { "data/scripts/overrides/common.pokecenter_pc.lua" })

  local fallbackCalls = {}
  local fallback = RepoFs.new(".", {
    read = function(path)
      fallbackCalls[#fallbackCalls + 1] = path
      return nil
    end,
  })
  local content = fallback:read("libs/storage/src/RepoFs.lua")
  Assert.notNil(content, "a missing source member falls back to the physical checkout")
  Assert.deepEqual(fallbackCalls, { "libs/storage/src/RepoFs.lua" })
  Assert.isNil(fallback:read("no/such/file.lua"), "missing source and checkout members stay nil")
end

function T.tests.invalid_paths_fail_before_either_reader_is_consulted()
  local sourceCalls, checkoutCalls = 0, 0
  local fs = RepoFs.new("unused-checkout-root", {
    read = function(_)
      sourceCalls = sourceCalls + 1
      return nil
    end,
  })
  local originalOpen = io.open
  io.open = function(...)
    checkoutCalls = checkoutCalls + 1
    return originalOpen(...)
  end
  local ok, err = pcall(function()
    for _, path in ipairs({ "../outside", "data/../outside", "..\\outside", "./file.lua", "/absolute" }) do
      assertRejected(fs, path)
    end
  end)
  io.open = originalOpen
  if not ok then
    error(err, 0)
  end
  Assert.equal(sourceCalls, 0, "confinement rejects before archived reads")
  Assert.equal(checkoutCalls, 0, "confinement rejects before physical reads")
end

function T.tests.canonical_root_escape_attempts_fail_at_the_boundary()
  local fs = RepoFs.new(".")
  assertRejected(fs, "src/../../AGENTS.md")
  assertRejected(fs, "src/game/../../../../README.md")
end

return T
