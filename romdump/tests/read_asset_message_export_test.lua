-- The read-asset tooling against a private synthetic cache: raw extraction of
-- a compact message bank, the authoritative human-readable export, and the
-- shell's output-mode rules. Every child is a windowless LÖVE process against
-- an owned data home, so no user cache, save root, or ROM is involved.

local Assert = require("tests.support.Assert")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local LuaWriter = require("libs.codec.src.LuaWriter")

local EXPORTED_BANK_ID = 543
local TRUNCATED_BANK_ID = 544
local TRUNCATED_BYTES = 12

local READER_DIR = ".agents/skills/read-asset/reader"
local HELPER = ".agents/skills/read-asset/scripts/read-asset.sh"
local LOVE_RUNNER = "scripts/lib/love.sh"

local T = {}

-- Owned per-suite state: one scratch root holds the seeded data home, the
-- generated seed app, the fake LÖVE recorder, and every child output.
local owned = { root = nil, seeded = false }

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function commandSucceeded(status)
  return status == 0 or status == true
end

-- Runs one shell command, returning its combined output and exit status.
local function run(command)
  local handle = assert(io.popen(command .. ' 2>&1; echo "__exit=$?"', "r"), "could not start: " .. command)
  local output = handle:read("*a") or ""
  handle:close()
  local exit = output:match("__exit=(%d+)%s*$")
  Assert.notNil(exit, "the command reported no exit status: " .. command .. "\n" .. output)
  return (output:gsub("__exit=%d+%s*$", "")), tonumber(assert(exit))
end

local function projectRoot()
  return love.filesystem.getSourceBaseDirectory()
end

local function ensureRoot()
  if owned.root ~= nil then
    return owned.root
  end
  local handle = assert(io.popen("mktemp -d", "r"), "mktemp -d could not start")
  local path = (handle:read("*l") or ""):gsub("^%s+", ""):gsub("%s+$", "")
  Assert.isTrue(commandSucceeded(handle:close()), "mktemp -d did not exit successfully")
  Assert.isTrue(path ~= "", "mktemp -d produced no path")
  os.execute("mkdir -p -- " .. shellQuote(path .. "/data"))
  owned.root = path
  return path
end

local function writeFile(path, content)
  local file = assert(io.open(path, "wb"), "could not create " .. path)
  file:write(content)
  file:close()
end

local function readFile(path)
  local file = io.open(path, "rb")
  if file == nil then
    return nil
  end
  local content = file:read("*a")
  file:close()
  return content
end

local function sha1hex(bytes)
  local digest = love.data.hash("sha1", bytes)
  return (digest:gsub(".", function(char)
    return string.format("%02x", char:byte())
  end))
end

-- The token spellings the producer normalizes. Display text, control framing,
-- and packed trainer-name words are the details a human-readable export must
-- keep visible.
local function glyph(code, text)
  return { kind = "glyph", code = code, text = text }
end

local function eos()
  return { kind = "eos" }
end

local function lineBreak()
  return { kind = "line_break" }
end

local function seedMessages()
  return {
    -- 0: two multi-character glyphs, a line break, and a repeated glyph
    { glyph(0x0141, "th"), glyph(0x0150, "ll"), lineBreak(), glyph(0x0141, "th"), eos() },
    -- 1: a packed trainer-name substitution
    {
      {
        kind = "substitution",
        control = FieldMessageText.TRNAME,
        name = "TRNAME",
        args = {},
        raw = { FieldMessageText.TRNAME, 0x1234, 0x5678 },
      },
      eos(),
    },
    -- 2: tokens that follow EOS
    { glyph(0x0142, "A"), eos(), glyph(0x0143, "B"), lineBreak() },
    -- 3: a message with no tokens
    {},
    -- 4: a single EOS record
    { eos() },
  }
end

local SEED_APP = [[
function love.load(argv)
  local ok, err = pcall(function()
    local root = assert(argv[1], "the project root is required")
    local specPath = assert(argv[2], "the seed spec is required")
    local expectedPath = assert(argv[3], "the expected-bytes path is required")
    package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
    local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
    local FieldMessageFixture = require("tests.support.FieldMessageFixture")
    local SnapshotBootFixture = require("tests.support.SnapshotBootFixture")
    local spec = assert(loadfile(specPath))()
    -- The seeded cache is one saved snapshot: the inspector reads the same
    -- members a next boot hydrates, and no loose generated file exists to
    -- serve instead.
    local identity = SnapshotBootFixture.identity()
    local cut = {
      generationId = identity.generationId,
      identity = identity,
      sequence = 1,
      entries = {},
      artifacts = {},
      milestones = {},
      firstPlay = false,
      complete = false,
    }
    local files = {}
    local sealed
    for _, entry in ipairs(spec.entries) do
      local bytes = FieldMessageFixture.encode(FieldMessageFixture.bank(entry.bankId, entry.messages))
      local text = bytes:getString()
      if entry.keepBytes then
        text = text:sub(1, entry.keepBytes)
      else
        sealed = bytes
      end
      local path = FieldMessageCache.bankPath(entry.bankId)
      cut.entries[#cut.entries + 1] = SnapshotBootFixture.blob(identity, path, text)
      files[#files + 1] = path
    end
    cut.artifacts[1] = {
      kind = "message-bank",
      key = "seed",
      marker = "seed-ready",
      files = files,
    }
    SnapshotBootFixture.save("heartgold", cut)
    local file = assert(io.open(expectedPath, "wb"))
    assert(file:write(assert(sealed):getString()))
    assert(file:close())
  end)
  if ok then
    love.event.quit(0)
  else
    io.stderr:write("seed failed: " .. tostring(err) .. "\n")
    love.event.quit(1)
  end
end
]]

local SEED_CONF = [[
function love.conf(t)
  t.identity = "portemon"
  t.version = "11.5"
  t.modules.window = false
  t.modules.graphics = false
  t.modules.audio = false
  t.modules.sound = false
  t.modules.joystick = false
  t.modules.touch = false
end
]]

-- Writes the seed app and seeds the private cache exactly once per run, so the
-- reader children all read the same synthetic bank.
local function ensureSeeded()
  local root = ensureRoot()
  local dataHome = root .. "/data"
  if owned.seeded then
    return dataHome
  end
  local appDir = root .. "/seed"
  os.execute("mkdir -p -- " .. shellQuote(appDir))
  writeFile(appDir .. "/conf.lua", SEED_CONF)
  writeFile(appDir .. "/main.lua", SEED_APP)
  local specPath = root .. "/seed-spec.lua"
  writeFile(
    specPath,
    LuaWriter.encode({
      entries = {
        { bankId = EXPORTED_BANK_ID, messages = seedMessages() },
        {
          bankId = TRUNCATED_BANK_ID,
          messages = { { eos() } },
          keepBytes = TRUNCATED_BYTES,
        },
      },
    })
  )
  local output, exit = run(table.concat({
    "env",
    "XDG_DATA_HOME=" .. shellQuote(dataHome),
    LOVE_RUNNER,
    shellQuote(appDir),
    shellQuote(projectRoot()),
    shellQuote(specPath),
    shellQuote(root .. "/expected-bank.g4msg"),
  }, " "))
  Assert.equal(exit, 0, "the private cache must seed: " .. output)
  Assert.notNil(readFile(root .. "/expected-bank.g4msg"), "seeding reports its compact bytes")
  owned.seeded = true
  return dataHome
end

-- The real reader, launched the way the helper launches it: a windowless LÖVE
-- process reading the private data home.
local function readerCommand(dataHome, modeArgs)
  local parts = {
    "env",
    "XDG_DATA_HOME=" .. shellQuote(dataHome),
    LOVE_RUNNER,
    READER_DIR,
    "--repo-root",
    shellQuote(projectRoot()),
    "--version",
    "heartgold",
  }
  for _, arg in ipairs(modeArgs) do
    parts[#parts + 1] = arg
  end
  return table.concat(parts, " ")
end

local function bankPath(bankId)
  return string.format("data/generated/field/messages/banks/%04d.g4msg", bankId)
end

-- Loads a generated Lua export in an empty environment, proving the output is
-- inert data rather than a chunk with hidden requirements.
local function loadInert(path)
  local chunk = assert(loadfile(path), "the export must be a loadable Lua chunk: " .. path)
  setfenv(chunk, {})
  return chunk()
end

local function contains(text, needle, label)
  Assert.isTrue(
    tostring(text):find(needle, 1, true) ~= nil,
    label .. " must mention " .. string.format("%q", needle) .. ", got:\n" .. tostring(text)
  )
end

function T.raw_extraction_returns_the_exact_compact_bytes()
  local root = ensureRoot()
  local dataHome = ensureSeeded()
  local expected = assert(readFile(root .. "/expected-bank.g4msg"), "the seed bytes are available")
  local outputPath = root .. "/raw-bank.g4msg"
  local output, exit =
    run(readerCommand(dataHome, { "--path", bankPath(EXPORTED_BANK_ID), "--output", shellQuote(outputPath) }))

  Assert.equal(exit, 0, "raw extraction must succeed: " .. output)
  Assert.equal(readFile(outputPath), expected, "raw extraction returns the stored compact bytes")
  contains(output, "decoded_file=" .. outputPath, "the reader")
  contains(output, "cache_path=" .. bankPath(EXPORTED_BANK_ID), "the reader")
  contains(output, "bytes=" .. tostring(#expected), "the reader")
  contains(output, "sha1=" .. sha1hex(expected), "the reader")
end

function T.message_text_export_carries_normalized_messages_and_rejects_truncated_input()
  local root = ensureRoot()
  local dataHome = ensureSeeded()
  local messages = seedMessages()
  local outputPath = root .. "/bank.messages.lua"
  local output, exit =
    run(readerCommand(dataHome, { "--message-text", bankPath(EXPORTED_BANK_ID), "--output", shellQuote(outputPath) }))
  Assert.equal(exit, 0, "message-text export must succeed: " .. output)
  contains(output, "decoded_file=" .. outputPath, "the reader")

  local exported = loadInert(outputPath)
  Assert.equal(exported.bankId, EXPORTED_BANK_ID)
  Assert.equal(exported.messageCount, #messages)
  for id, tokens in ipairs(messages) do
    local message = assert(exported.messages[id - 1], "the export must include message " .. (id - 1))
    Assert.equal(message.text, FieldMessageText.tokensToText(tokens), "message " .. (id - 1) .. " display text")
    -- The export is self-consistent data: re-rendering its own tokens cannot
    -- change its stored text.
    Assert.equal(message.text, FieldMessageText.tokensToText(message.tokens), "message " .. (id - 1) .. " tokens")
  end

  -- Multi-character glyph display strings survive exactly.
  local firstGlyph = assert(assert(exported.messages[0]).tokens[1])
  Assert.equal(firstGlyph.kind, "glyph")
  Assert.equal(firstGlyph.code, 0x0141)
  Assert.equal(firstGlyph.text, "th")
  Assert.deepEqual(firstGlyph.raw, { 0x0141 })

  -- Packed trainer-name words are diagnostic detail that display text cannot
  -- carry: {TRNAME} renders, while the export keeps the source words.
  local substitution = assert(assert(exported.messages[1]).tokens[1])
  Assert.equal(substitution.kind, "substitution")
  Assert.equal(substitution.control, FieldMessageText.TRNAME)
  Assert.equal(substitution.name, "TRNAME")
  Assert.deepEqual(substitution.raw, { FieldMessageText.TRNAME, 0x1234, 0x5678 })

  -- Tokens after EOS stay in the export even though the text ends at EOS.
  local afterEos = assert(exported.messages[2])
  Assert.equal(afterEos.text, "A", "display text stops at the first EOS")
  Assert.equal(#afterEos.tokens, 4, "tokens after EOS survive the export")

  -- Repeating the export produces the same chunk: nothing depends on run order.
  local secondPath = root .. "/bank-again.messages.lua"
  local again, againExit =
    run(readerCommand(dataHome, { "--message-text", bankPath(EXPORTED_BANK_ID), "--output", shellQuote(secondPath) }))
  Assert.equal(againExit, 0, "a repeated export must succeed: " .. again)
  Assert.equal(readFile(secondPath), readFile(outputPath), "the export is deterministic")

  -- A truncated compact payload is an error, never a partial export.
  local truncatedPath = root .. "/truncated.messages.lua"
  local _, truncatedExit = run(
    readerCommand(dataHome, { "--message-text", bankPath(TRUNCATED_BANK_ID), "--output", shellQuote(truncatedPath) })
  )
  Assert.isTrue(truncatedExit ~= 0, "a truncated bank must fail the export")
  Assert.isNil(readFile(truncatedPath), "a failed export leaves no partial output file")
end

-- The shell owns mode selection: it accepts exactly one output mode, and a
-- rejected combination never starts a preparation or reader process.
local function shellCommand(extraEnv, argv)
  local parts = { "env", "PATH=" .. shellQuote(extraEnv.fakeBinPath .. ":" .. (os.getenv("PATH") or "")) }
  parts[#parts + 1] = "PORTEMON_SAVE_DIR=" .. shellQuote(extraEnv.dataHome)
  parts[#parts + 1] = HELPER
  parts[#parts + 1] = "--version"
  parts[#parts + 1] = "heartgold"
  parts[#parts + 1] = "--require"
  parts[#parts + 1] = "message-bank:543"
  for _, arg in ipairs(argv) do
    parts[#parts + 1] = arg
  end
  return table.concat(parts, " ")
end

-- A recording `love`: the shell's own reference check answers the pinned
-- version, and every real invocation is appended to a log file instead of
-- building anything.
local function ensureFakeLove()
  local root = ensureRoot()
  local binPath = root .. "/bin"
  local logPath = root .. "/love.log"
  if owned.fakeLove == nil then
    os.execute("mkdir -p -- " .. shellQuote(binPath))
    writeFile(
      binPath .. "/love",
      table.concat({
        "#!/bin/sh",
        'if [ "$1" = "--version" ]; then printf "LOVE 11.5 (fake)\\n"; exit 0; fi',
        "printf '%s\\n' \"$*\" >> " .. shellQuote(logPath),
        "exit 0",
        "",
      }, "\n")
    )
    os.execute("chmod +x " .. shellQuote(binPath .. "/love"))
    owned.fakeLove = { binPath = binPath, logPath = logPath }
  end
  writeFile(logPath, "")
  return owned.fakeLove
end

local function recordedInvocations(fakeLove)
  local log = readFile(fakeLove.logPath) or ""
  local lines = {}
  for line in log:gmatch("[^\n]+") do
    lines[#lines + 1] = line
  end
  return lines
end

-- The helper writes into its own ignored scratch directory under the project;
-- only directories this test created are removed afterwards.
local function scratchDirectories()
  local found = {}
  local handle = io.popen("ls -1 .agents/tmp 2>/dev/null")
  if handle == nil then
    return found
  end
  for name in handle:lines() do
    if name:match("^read%-asset%.") then
      found[name] = true
    end
  end
  handle:close()
  return found
end

local function removeNewScratchDirectories(before)
  for name in pairs(scratchDirectories()) do
    if not before[name] then
      os.execute("rm -rf -- " .. shellQuote(".agents/tmp/" .. name))
    end
  end
end

function T.output_modes_are_mutually_exclusive_before_any_preparation()
  local root = ensureRoot()
  local fakeLove = ensureFakeLove()
  local env = { fakeBinPath = fakeLove.binPath, dataHome = root .. "/data" }
  local bank = bankPath(EXPORTED_BANK_ID)
  local before = scratchDirectories()

  local output, exit = run(shellCommand(env, { "--path", bank, "--message-text", bank }))
  Assert.equal(exit, 2, "both file modes together must be a usage error, got:\n" .. output)
  contains(output, "--message-text", "the usage")

  local listed, listExit = run(shellCommand(env, { "--list", "data/generated/field/messages", "--message-text", bank }))
  Assert.equal(listExit, 2, "listing with a message export must be a usage error, got:\n" .. listed)
  contains(listed, "--message-text", "the usage")

  Assert.equal(#recordedInvocations(fakeLove), 0, "a rejected mode combination must not prepare anything")
  removeNewScratchDirectories(before)
end

function T.message_text_mode_routes_through_targeted_preparation()
  local root = ensureRoot()
  local fakeLove = ensureFakeLove()
  local env = { fakeBinPath = fakeLove.binPath, dataHome = root .. "/data" }
  local bank = bankPath(EXPORTED_BANK_ID)
  local before = scratchDirectories()

  local output, exit = run(shellCommand(env, { "--message-text", bank }))
  local invocations = recordedInvocations(fakeLove)
  removeNewScratchDirectories(before)

  Assert.equal(exit, 0, "the shell must accept the message-text mode, got:\n" .. output)
  Assert.equal(#invocations, 2, "the shell prepares the requested job and then runs the reader, got:\n" .. output)
  local preparation, reader = invocations[1], invocations[2]
  contains(preparation, "romdump/", "targeted preparation")
  contains(preparation, "--prepare-cache", "targeted preparation")
  contains(preparation, "--dev", "targeted preparation")
  contains(preparation, "--version heartgold", "targeted preparation")
  contains(preparation, "--require message-bank:543", "targeted preparation")
  contains(reader, READER_DIR, "the reader")
  contains(reader, "--message-text " .. bank, "the reader")
  local exportedPath = reader:match("%-%-output (%S+)")
  Assert.notNil(exportedPath, "the reader receives an output file: " .. reader)
  Assert.isTrue(
    assert(exportedPath):sub(-#"/0543.messages.lua") == "/0543.messages.lua",
    "a message export writes beside the compact bank as 0543.messages.lua, got: " .. tostring(exportedPath)
  )
  contains(assert(exportedPath), "/.agents/tmp/read-asset.", "the export")
end

-- Removes exactly the scratch root this suite acquired. A test failure is
-- reported by the runner independently, so cleanup only reports its own
-- failure.
local function removeOwnedRoot()
  if owned.root == nil then
    return
  end
  local root = owned.root
  owned.root = nil
  owned.seeded = false
  owned.fakeLove = nil
  Assert.isTrue(
    commandSucceeded(os.execute("rm -rf -- " .. shellQuote(root))),
    "owned scratch cleanup failed: " .. root
  )
end

-- The prepared cache this process runs against: the runner's scoped
-- preparation leaves one snapshot archive under the process's own data home,
-- and a separate reader process must read exactly those members. The proof runs
-- against an owned copy of that archive beside a stale loose generated member
-- whose bytes contradict it, so the bytes the inspector serves show which
-- source it read. The prepared root itself is shared and stays untouched: an
-- older producer's loose files there are neither a fallback nor cleaned up.
function T.the_inspector_serves_members_from_the_prepared_snapshot()
  local SnapshotArchive = require("tests.support.SnapshotArchive")
  Assert.notNil(os.getenv("XDG_DATA_HOME"), "the scoped preparation runs against a private data home")
  local index, members, archiveBytes = SnapshotArchive.read("heartgold")
  Assert.notNil(index, "the scoped preparation must leave one snapshot archive the next process can read")
  Assert.notNil(archiveBytes, "the prepared snapshot is readable as archive bytes")
  local preparedBank = nil
  for _, path in ipairs(SnapshotArchive.memberPaths(index)) do
    if path:match("^data/generated/field/messages/banks/%d+%.g4msg$") ~= nil then
      preparedBank = path
      break
    end
  end
  Assert.notNil(preparedBank, "the prepared snapshot carries the requested message bank")
  local root = ensureRoot()
  local dataHome = root .. "/snapshot-cache"
  local saveDir = dataHome .. "/love/portemon/heartgold"
  local loosePath = saveDir .. "/" .. preparedBank
  os.execute("mkdir -p -- " .. shellQuote(loosePath:gsub("/[^/]+$", "")))
  writeFile(saveDir .. "/cache.zip", assert(archiveBytes))
  writeFile(loosePath, "stale-loose-bank-bytes")
  local decoded = root .. "/snapshot-bank.g4msg"
  local output, exit = run(readerCommand(dataHome, {
    "--path",
    shellQuote(preparedBank),
    "--output",
    shellQuote(decoded),
  }))
  Assert.equal(exit, 0, "the inspector reads a prepared snapshot member, got:\n" .. output)
  Assert.equal(readFile(decoded), members[preparedBank], "the inspector returns the snapshot member's bytes")
  Assert.isTrue(
    readFile(decoded) ~= "stale-loose-bank-bytes",
    "the inspector answers from the snapshot, never from the stale loose member beside it"
  )
  Assert.equal(
    readFile(loosePath),
    "stale-loose-bank-bytes",
    "reading a snapshot member leaves a loose generated file untouched"
  )
  local listed, listExit = run(readerCommand(dataHome, { "--list", shellQuote("data/generated/field/messages") }))
  Assert.equal(listExit, 0, "the inspector lists the prepared snapshot, got:\n" .. listed)
  Assert.isTrue(
    listed:find(preparedBank, 1, true) ~= nil,
    "the listing reaches the snapshot member path: " .. preparedBank
  )
end

-- A generated root that only carries old loose files is not a cache: the
-- inspector reports the missing snapshot instead of exporting from it.
function T.the_inspector_refuses_a_loose_bank_without_a_snapshot()
  local root = ensureRoot()
  local dataHome = root .. "/loose-cache"
  local saveDir = dataHome .. "/love/portemon"
  local loosePath = saveDir .. "/heartgold/" .. bankPath(EXPORTED_BANK_ID)
  os.execute("mkdir -p -- " .. shellQuote((loosePath:gsub("/[^/]+$", ""))))
  writeFile(loosePath, "legacy-loose-bank-bytes")
  local decoded = root .. "/loose-bank.g4msg"
  local output, exit = run(readerCommand(dataHome, {
    "--path",
    shellQuote(bankPath(EXPORTED_BANK_ID)),
    "--output",
    shellQuote(decoded),
  }))
  Assert.isTrue(exit ~= 0, "a loose generated file is not a readable cache, got:\n" .. output)
  Assert.isNil(readFile(decoded), "a refused read writes no decoded output")
  Assert.equal(readFile(loosePath), "legacy-loose-bank-bytes", "a refused read leaves the loose file untouched")
end

return {
  tests = T,
  afterAll = removeOwnedRoot,
  metadata = { tags = { "messages", "tooling" }, derivedAssets = { "message-bank:219" } },
}
