-- Black-box shell-entrypoint environment contract: `scripts/test.sh` selects
-- the host platform's headless graphics defaults, and
-- `scripts/lib/repo-setup.sh` refuses to reuse an incompatible LÖVE
-- runtime. Both prove environment selection through generated fake
-- executables (a platform-reporting `uname`, version-reporting `love`
-- doubles, and an offline AppImage download), so no real download, display
-- host, or terminal is required.

local Assert = require("tests.support.Assert")

local T = {}

-- The pinned LÖVE release the installer manages. This is an explicitly
-- maintained fixture: when LOVE_VERSION in scripts/lib/repo-setup.sh moves,
-- update this literal alongside it. Nothing here parses the shell source,
-- so reformatting that assignment never breaks these tests.
local EXPECTED_LOVE_VERSION = "11.5"

local function shellQuote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function popen(command)
  return assert(io.popen(command))
end

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function mkdtemp()
  local handle = popen("mktemp -d")
  local path = trim(handle:read("*l") or "")
  handle:close()
  assert(path ~= "", "mktemp -d produced no path")
  return path
end

local function mkdir(path)
  os.execute("mkdir -p -- " .. shellQuote(path))
end

local function writeFile(path, content)
  local handle = assert(io.open(path, "w"))
  handle:write(content)
  handle:close()
end

local function writeExecutable(path, content)
  writeFile(path, content)
  os.execute("chmod +x " .. shellQuote(path))
end

local function readFile(path)
  local handle = io.open(path, "r")
  if handle == nil then
    return nil
  end
  local content = handle:read("*a")
  handle:close()
  return content
end

local function fileExists(path)
  local handle = io.open(path, "r")
  if handle then
    handle:close()
    return true
  end
  return false
end

local function contains(text, needle, label)
  Assert.isTrue(
    tostring(text):find(needle, 1, true) ~= nil,
    (label or "text") .. " must mention " .. string.format("%q", needle) .. ", got: " .. tostring(text)
  )
end

local function withTempDirectory(fn)
  local root = mkdtemp()
  local ok, err = pcall(fn, root)
  os.execute("rm -rf -- " .. shellQuote(root))
  if not ok then
    error(err, 0)
  end
end

-- Reports FAKE_UNAME_S for `-s` (default Linux) and a fixed x86_64 for
-- `-m`; every other probe answers the platform name, which is all the
-- entrypoints under test ever ask of `uname`.
local FAKE_UNAME = [[
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "-s" ]; then
  printf '%s\n' "${FAKE_UNAME_S:-Linux}"
elif [ "${1:-}" = "-m" ]; then
  printf '%s\n' "${FAKE_UNAME_M:-x86_64}"
else
  printf '%s\n' "${FAKE_UNAME_S:-Linux}"
fi
]]

-- A version-reporting `love` double. FAKE_LOVE_VERSION selects the reported
-- release (`__fail__` fails the probe, `__garbage__` prints an
-- unrecognizable answer). The `--plan` answer keeps nested test-command
-- runs fixture-free, and the `app/` branch records the graphics environment
-- the entrypoint selected for its LÖVE child. The release default is the
-- expected fixture above, so the double agrees with it unless a case
-- overrides the answer.
local FAKE_LOVE = ([[
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "--version" ]; then
  version="${FAKE_LOVE_VERSION:-@PINNED@}"
  case "$version" in
    __fail__) exit 1 ;;
    __garbage__) printf 'not a love version string\n' ;;
    *) printf 'LOVE %s (Mysterious Mysteries)\n' "$version" ;;
  esac
  exit 0
fi
is_plan=false
for arg in "$@"; do
  if [ "$arg" = "--plan" ]; then
    is_plan=true
  fi
done
if [ "$is_plan" = true ]; then
  echo "prepare=none"
  echo "fresh=0"
  echo "jobs=1"
  exit 0
fi
if [ "${1:-}" = "app/" ]; then
  {
    printf 'sdl=%s\n' "${SDL_VIDEODRIVER:-}"
    printf 'libgl=%s\n' "${LIBGL_ALWAYS_SOFTWARE:-}"
  } > "${FAKE_HEADLESS_RECORD:?missing record file}"
  exit 0
fi
echo "fake love: unrecognized invocation: $*" >&2
exit 1
]]):gsub("@PINNED@", EXPECTED_LOVE_VERSION)

-- An offline `curl` double synthesizing the pinned AppImage: whatever URL
-- the installer requests, it writes a shell executable answering
-- `--appimage-extract` with an AppRun entrypoint reporting the expected
-- release, so `--yes` installs prove the real extraction and shim wiring
-- without network access.
local FAKE_CURL = ([[
#!/usr/bin/env bash
set -u
output=""
previous=""
for arg in "$@"; do
  if [ "$previous" = "--output" ]; then
    output="$arg"
  fi
  previous="$arg"
done
if [ -z "$output" ]; then
  echo "fake curl: no --output in: $*" >&2
  exit 1
fi
cat > "$output" <<EOF
#!/bin/sh
if [ "\${1:-}" = "--appimage-extract" ]; then
  mkdir -p squashfs-root
  printf '%s\n' '#!/bin/sh' 'echo "LOVE ${FAKE_CURL_LOVE_VERSION:-@PINNED@} (Mysterious Mysteries)"' > squashfs-root/AppRun
  chmod +x squashfs-root/AppRun
fi
EOF
exit 0
]]):gsub("@PINNED@", EXPECTED_LOVE_VERSION)

-- Every nested command runs inside this worktree with worker identity
-- sanitized, a fresh fake `love` first on PATH, and the product save
-- location left to the repository's own environment file so product-root
-- isolation is proved against the real default.
local SANITIZE_ENV =
  "unset PORTEMON_TEST_RUN_DIR PORTEMON_TEST_WORKERS PORTEMON_TEST_WORKER PORTEMON_TEST_AGGREGATE PORTEMON_TEST_ACCEPTANCE_NAMESPACE PORTEMON_TEST_PREPARED_REQUIREMENTS PORTEMON_DERIVED_CACHE_READY PORTEMON_REQUIRE_ROM_TESTS;"

local function recordField(path, field)
  local content = readFile(path)
  Assert.notNil(content, "the nested command must record its environment in " .. path)
  local value = tostring(content):match(field .. "=([^\n]*)")
  Assert.notNil(value, "the record must carry " .. field .. ", got: " .. tostring(content))
  return value
end

-- One nested `scripts/test.sh` invocation under the given platform name and
-- graphics overrides. The outer command's own headless defaults are dropped
-- first so the nested selection is proved, not the inheritance; every entry
-- in `overrides` is then exported, proving explicit choices survive.
-- Returns the graphics record, the log, and the status file.
local function runNestedTestCommand(root, platform, overrides)
  local binDir = root .. "/bin"
  mkdir(binDir)
  writeExecutable(binDir .. "/uname", FAKE_UNAME)
  writeExecutable(binDir .. "/love", FAKE_LOVE)
  local saveDir = root .. "/save"
  mkdir(saveDir)
  local recordFile = root .. "/headless.env"
  local logFile = root .. "/command.log"
  local statusFile = root .. "/status"

  local exports = {
    "export PATH=" .. shellQuote(binDir) .. ":$PATH;",
    "export PORTEMON_SAVE_DIR=" .. shellQuote(saveDir) .. ";",
    "export FAKE_UNAME_S=" .. shellQuote(platform) .. ";",
    -- The expected release answers the setup probe, so the nested run never
    -- reaches the installer.
    "export FAKE_LOVE_VERSION=" .. shellQuote(EXPECTED_LOVE_VERSION) .. ";",
    "export FAKE_HEADLESS_RECORD=" .. shellQuote(recordFile) .. ";",
  }
  for name, value in pairs(overrides or {}) do
    exports[#exports + 1] = "export " .. name .. "=" .. shellQuote(value) .. ";"
  end
  local command = table.concat({
    SANITIZE_ENV,
    "unset SDL_VIDEODRIVER LIBGL_ALWAYS_SOFTWARE;",
    table.concat(exports, " "),
    "scripts/test.sh >" .. shellQuote(logFile) .. " 2>&1;",
    "echo $? > " .. shellQuote(statusFile) .. ";",
  }, " ")
  local handle = popen(command)
  local _ = handle:read("*a")
  handle:close()
  return recordFile, logFile, statusFile
end

local function nestedStatus(statusFile, logFile)
  local status = trim(readFile(statusFile) or "")
  Assert.equal(status, "0", "the nested test command must exit zero: " .. tostring(readFile(logFile)))
end

-- Linux and the BSDs share the container's offscreen software context while
-- macOS keeps its native Cocoa host without those defaults.
function T.headless_graphics_defaults_follow_the_host_platform()
  withTempDirectory(function(root)
    for _, platform in ipairs({ "Linux", "FreeBSD", "OpenBSD", "NetBSD" }) do
      local recordFile, logFile, statusFile = runNestedTestCommand(root .. "/" .. platform, platform)
      nestedStatus(statusFile, logFile)
      Assert.equal(recordField(recordFile, "sdl"), "offscreen", platform .. " must default to the offscreen driver")
      Assert.equal(recordField(recordFile, "libgl"), "1", platform .. " must default to software rendering")
    end

    local recordFile, logFile, statusFile = runNestedTestCommand(root .. "/Darwin", "Darwin")
    nestedStatus(statusFile, logFile)
    Assert.equal(recordField(recordFile, "sdl"), "", "macOS must not default the video driver")
    Assert.equal(recordField(recordFile, "libgl"), "", "macOS must not default software rendering")
  end)
end

-- Explicit contributor overrides survive the entrypoint.
function T.explicit_graphics_overrides_survive_the_test_entrypoint()
  withTempDirectory(function(root)
    local recordFile, logFile, statusFile = runNestedTestCommand(root .. "/override", "Linux", {
      SDL_VIDEODRIVER = "x11",
      LIBGL_ALWAYS_SOFTWARE = "0",
    })
    nestedStatus(statusFile, logFile)
    Assert.equal(recordField(recordFile, "sdl"), "x11", "an explicit video driver must survive")
    Assert.equal(recordField(recordFile, "libgl"), "0", "an explicit software-rendering choice must survive")
  end)
end

-- Copies the setup script into an isolated tree so installs land in a
-- fixture `scripts/bin` and the working tree is never touched. `spec`
-- selects the fixture: `loveVersion` installs the versioned double (nil
-- means absent), `withCurl` adds the offline download, and `hideLove`
-- makes `command -v love` fail so a missing executable is proved without
-- scrubbing the real system runtime off PATH. Returns the fixture repo and
-- a runner script executing the copy with the fixture bin first on PATH, a
-- Linux/x86_64 platform, and the expected release behind the download.
local function installSetupCopy(root, spec)
  local repo = root .. "/fakerepo"
  mkdir(repo .. "/scripts/lib")
  local source = assert(io.open("scripts/lib/repo-setup.sh", "rb"))
  local body = source:read("*a")
  source:close()
  local target = assert(io.open(repo .. "/scripts/lib/repo-setup.sh", "wb"))
  target:write(body)
  target:close()
  os.execute("chmod +x " .. shellQuote(repo .. "/scripts/lib/repo-setup.sh"))

  local binDir = root .. "/setup-bin"
  mkdir(binDir)
  writeExecutable(binDir .. "/uname", FAKE_UNAME)
  if spec.withCurl then
    writeExecutable(binDir .. "/curl", FAKE_CURL)
  end
  if spec.loveVersion ~= nil then
    writeExecutable(binDir .. "/love", FAKE_LOVE)
  end

  local lines = {
    "#!/usr/bin/env bash",
    "set -u",
    "cd " .. shellQuote(repo),
    "export PATH=" .. shellQuote(binDir) .. ":$PATH",
    "export FAKE_UNAME_S='Linux'",
    "export FAKE_UNAME_M='x86_64'",
    "export FAKE_CURL_LOVE_VERSION=" .. shellQuote(EXPECTED_LOVE_VERSION),
  }
  if spec.hideLove then
    lines[#lines + 1] =
      'command() { if [ "${1:-}" = "-v" ] && [ "${2:-}" = "love" ]; then return 1; fi; builtin command "$@"; }; export -f command'
  end
  if spec.loveVersion ~= nil then
    lines[#lines + 1] = "export FAKE_LOVE_VERSION=" .. shellQuote(spec.loveVersion)
  end
  lines[#lines + 1] = 'bash scripts/lib/repo-setup.sh "$@"'
  lines[#lines + 1] = ""
  local runScript = root .. "/run-setup.sh"
  writeExecutable(runScript, table.concat(lines, "\n"))
  return repo, runScript
end

-- Runs the copied setup script with the given arguments and stdin closed,
-- so every run proves the noninteractive path. The exit status lands in the
-- status file next to the captured log.
local function runSetupScript(runScript, args)
  local logFile = runScript .. ".log"
  local statusFile = runScript .. ".status"
  local command = shellQuote(runScript)
    .. " "
    .. (args or "")
    .. " >"
    .. shellQuote(logFile)
    .. " 2>&1 </dev/null; echo $? > "
    .. shellQuote(statusFile)
    .. ";"
  local handle = popen(command)
  local _ = handle:read("*a")
  handle:close()
  return logFile, statusFile
end

local function setupStatus(statusFile)
  return trim(readFile(statusFile) or "")
end

-- A matching runtime is reused silently: no download, no install, no
-- prompt, even without a terminal on stdin.
function T.matching_love_runtime_is_reused_without_install()
  withTempDirectory(function(root)
    local repo, runScript = installSetupCopy(root, { loveVersion = EXPECTED_LOVE_VERSION, withCurl = true })
    local logFile, statusFile = runSetupScript(runScript, "")
    Assert.equal(setupStatus(statusFile), "0", "a matching runtime must be accepted: " .. tostring(readFile(logFile)))
    local output = tostring(readFile(logFile))
    Assert.isNil(output:find("downloading", 1, true), "a matching runtime must install nothing, got: " .. output)
    Assert.isFalse(fileExists(repo .. "/scripts/bin/love"), "a matching runtime must not create a local install")
  end)
end

-- A missing executable keeps the existing install offer: without a
-- terminal it fails with the `--yes` remediation instead of succeeding.
function T.missing_love_runtime_keeps_the_install_offer()
  withTempDirectory(function(root)
    local repo, runScript = installSetupCopy(root, { withCurl = true, hideLove = true })
    local logFile, statusFile = runSetupScript(runScript, "")
    Assert.isTrue(setupStatus(statusFile) ~= "0", "a missing runtime must not succeed without a terminal")
    contains(tostring(readFile(logFile)), "--yes", "the failure must name the unattended remediation")
    Assert.isFalse(fileExists(repo .. "/scripts/bin/love"), "no install may happen without consent")
  end)
end

-- An incompatible runtime reports what it found and what the repository
-- needs, then refuses to run silently: noninteractive execution fails with
-- the `--yes` remediation and installs nothing.
function T.mismatched_love_runtime_reports_both_versions_and_refuses_silent_use()
  withTempDirectory(function(root)
    local repo, runScript = installSetupCopy(root, { loveVersion = "0.0", withCurl = true })
    local logFile, statusFile = runSetupScript(runScript, "")
    Assert.isTrue(
      setupStatus(statusFile) ~= "0",
      "a mismatched runtime must not succeed: " .. tostring(readFile(logFile))
    )
    local output = tostring(readFile(logFile))
    contains(output, "0.0", "the failure must report the detected version")
    contains(output, EXPECTED_LOVE_VERSION, "the failure must report the required version")
    contains(output, "--yes", "the failure must name the unattended remediation")
    Assert.isFalse(fileExists(repo .. "/scripts/bin/love"), "a mismatched runtime must not be replaced silently")
  end)
end

-- A development-suffixed version string is not the pinned release: the
-- installer must refuse to reuse it silently even though it starts with
-- the expected number.
function T.development_suffixed_love_version_is_never_accepted_as_the_pinned_release()
  withTempDirectory(function(root)
    local repo, runScript =
      installSetupCopy(root, { loveVersion = EXPECTED_LOVE_VERSION .. "-development", withCurl = true })
    local logFile, statusFile = runSetupScript(runScript, "")
    Assert.isTrue(
      setupStatus(statusFile) ~= "0",
      "a suffixed version must not succeed: " .. tostring(readFile(logFile))
    )
    contains(tostring(readFile(logFile)), EXPECTED_LOVE_VERSION, "the failure must name the required version")
    Assert.isFalse(fileExists(repo .. "/scripts/bin/love"), "a suffixed version must not be replaced silently")
  end)
end

-- `--yes` installs the pinned release into the fixture `scripts/bin`
-- through the real extraction and shim wiring, reusing the installer's own
-- download path offline.
function T.yes_flag_installs_the_pinned_runtime_into_scripts_bin()
  withTempDirectory(function(root)
    local repo, runScript = installSetupCopy(root, { loveVersion = "0.0", withCurl = true })
    local logFile, statusFile = runSetupScript(runScript, "--yes")
    Assert.equal(setupStatus(statusFile), "0", "the pinned install must succeed: " .. tostring(readFile(logFile)))
    contains(tostring(readFile(logFile)), "love-" .. EXPECTED_LOVE_VERSION, "the install must fetch the pinned release")
    local installed = repo .. "/scripts/bin/love"
    Assert.isTrue(fileExists(installed), "the install must leave a scripts/bin shim")
    local handle = popen(shellQuote(installed) .. " --version 2>&1")
    local reported = trim(handle:read("*l") or "")
    handle:close()
    contains(reported, EXPECTED_LOVE_VERSION, "the installed shim must report the pinned release")
  end)
end

-- A failed probe and an unrecognizable answer are unverified, never a
-- silent match: both fail loudly instead of reusing the runtime.
function T.unverifiable_love_runtime_is_never_treated_as_compatible()
  withTempDirectory(function(root)
    for _, probe in ipairs({ "__fail__", "__garbage__" }) do
      local repo, runScript = installSetupCopy(root .. "/" .. probe, { loveVersion = probe, withCurl = true })
      local logFile, statusFile = runSetupScript(runScript, "")
      Assert.isTrue(
        setupStatus(statusFile) ~= "0",
        "an unverifiable runtime (" .. probe .. ") must not succeed: " .. tostring(readFile(logFile))
      )
      contains(tostring(readFile(logFile)), EXPECTED_LOVE_VERSION, "the failure must name the required version")
      Assert.isFalse(
        fileExists(repo .. "/scripts/bin/love"),
        "an unverifiable runtime (" .. probe .. ") must not be replaced silently"
      )
    end
  end)
end

-- Piped input is never a terminal: even an affirmative pipe must fail
-- rather than install without an explicit `--yes` or a real prompt.
function T.piped_input_never_counts_as_consent_to_install()
  withTempDirectory(function(root)
    local repo, runScript = installSetupCopy(root, { loveVersion = "0.0", withCurl = true })
    local logFile = runScript .. ".log"
    local statusFile = runScript .. ".status"
    local command = shellQuote(runScript)
      .. " >"
      .. shellQuote(logFile)
      .. " 2>&1; echo $? > "
      .. shellQuote(statusFile)
      .. ";"
    local handle = popen("printf 'y\\n' | " .. command)
    local _ = handle:read("*a")
    handle:close()
    Assert.isTrue(setupStatus(statusFile) ~= "0", "a piped yes must not install: " .. tostring(readFile(logFile)))
    Assert.isFalse(fileExists(repo .. "/scripts/bin/love"), "a piped yes must install nothing")
  end)
end

return { tests = T }
