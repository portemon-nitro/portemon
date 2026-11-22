-- Selected mod packages through production composition: the ordered package
-- list a user puts in the save directory overlays the resident generated view
-- of the running field, broken selections and broken package payloads stay
-- visible at their own source, package bytes obey the shared decoded-CPU
-- ownership policy, and the whole rewrite keeps readiness, snapshot, and
-- ownership behavior stable while a selection is present.
--
-- The packages are synthetic ZIPs written into this process's private save
-- root and mounted by the real filesystem; nothing here contains commercial
-- bytes. Only host boundaries the harness already owns are faked. Every
-- scenario restores the mod configuration, unmounts, and removes its fixtures
-- on the success and the failure path, and none of them renders.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local AudioFixture = require("tests.support.AudioFixture")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")
local GeneratedCacheFixture = require("tests.support.GeneratedCacheFixture")
local ModPackageFixture = require("tests.support.ModPackageFixture")
local PngEncoder = require("tests.support.PngEncoder")
local ResidentAssetCache = require("libs.hgss.src.field.ResidentAssetCache")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = {
      "field-runtime",
      "field-entry:global",
      "audio-bank:700",
      "audio-bank:702",
      "audio-bank:709",
      "map-data:31",
      "map-data:33",
      "map-data:47",
      "map-data:48",
      "map-data:60",
      "map-data:61",
      -- The two message banks the selection replaces and falls back to.
      "message-bank:445",
      "message-bank:542",
      "map:33",
      "map:47",
      "map:48",
      "map:60",
      "map:61",
    },
    tags = { "field", "mods", "cache" },
  },
  tests = {},
}

local TOWN = "MAP_NEW_BARK"

-- The bank the packages replace and the bank no package names, so one request
-- proves precedence and a second proves base fallback through the same reader.
local OVERRIDE_BANK = 445
local BASE_BANK = 542

-- One unused package member large enough that reading it would be visible in
-- the read log, declared by the manifest and requested by nothing.
local UNUSED_PAYLOAD = "data/generated/acceptance-unused/payload.bin"

-- Consecutive epoch numbers are enough for selection identity; the App owns the
-- real counter, and nothing here depends on its value.
local FIRST_EPOCH = 41
local SECOND_EPOCH = 42

-- Compose the selected epoch's overlay the way the App composition does: the
-- installed base view plus the session's ordered package set. The acceptance
-- harness supplies pre-installed views instead of running App, so this is the
-- one production step the harness cannot perform for it.
---@param versionId string
---@param identity table<string, unknown>
---@param epoch integer
---@param base CacheFs
---@return table packages
---@return CacheFs reader
local function selectPackages(versionId, identity, epoch, base)
  local okModule, ModPackages = pcall(require, "app.src.ModPackages")
  Assert.isTrue(okModule, "the selected game must own its ordered package selection: " .. tostring(ModPackages))
  local packages = ModPackages.open(versionId, identity, epoch)
  Assert.notNil(packages, "a configured package list must produce the session's package set")
  local okReader, reader = pcall(function()
    return base:withPackages(packages)
  end)
  if not okReader then
    pcall(function()
      packages:close()
    end)
    error(reader, 0)
  end
  Assert.notNil(reader, "the selected epoch's view must overlay its packages on the base entries")
  return packages, reader
end

-- Boot the running field on the reader the selection installed, exactly as the
-- App hands its epoch view to every generated consumer.
---@param versionId string
---@param current fun(): CacheFs
---@return table game
local function bootOnSelected(versionId, current)
  local harness = AcceptanceHarness.new({
    versions = { versionId },
    generatedView = function()
      return current()
    end,
  })
  return harness:boot({ versionId = versionId, map = TOWN, save = "fresh" })
end

-- Write the ordered selection with one package per message text. Both packages
-- replace the same logical bank, so the order alone decides the observable
-- content, and both carry the unused member.
---@param versionId string
---@param identity table<string, unknown>
---@param order string[] low priority first
---@param texts table<string, string> display text by archive basename
local function writeSelection(versionId, identity, order, texts)
  for basename, text in pairs(texts) do
    ModPackageFixture.writeArchive(versionId, basename, identity, {
      id = basename:gsub("%.zip$", ""),
      revision = "1",
      files = {
        [ModPackageFixture.messageBankPath(OVERRIDE_BANK)] = ModPackageFixture.messageBank(OVERRIDE_BANK, text),
      },
      extra = string.rep("unused-package-payload;", 4096),
    })
  end
  ModPackageFixture.writeConfig(versionId, order)
end

-- Release the running field, the mounted selection, and every fixture file.
-- Each step is independent so an earlier failure cannot leave a mount or a
-- config behind.
---@param state { game: table?, packages: table? }
---@param versionId string
local function teardown(state, versionId)
  local problems = {}
  if state.game ~= nil then
    local ok, err = pcall(function()
      state.game:close()
    end)
    state.game = nil
    if not ok then
      problems[#problems + 1] = "field boot: " .. tostring(err)
    end
  end
  if state.packages ~= nil then
    local ok, err = pcall(function()
      state.packages:close()
    end)
    state.packages = nil
    if not ok then
      problems[#problems + 1] = "package unmount: " .. tostring(err)
    end
  end
  local ok, err = pcall(ModPackageFixture.cleanup, versionId)
  if not ok then
    problems[#problems + 1] = "fixture cleanup: " .. tostring(err)
  end
  if #problems > 0 then
    return table.concat(problems, "; ")
  end
  return nil
end

-- The last selected package decides the content of a path, packages are read
-- only when used, unselected paths still borrow the base bytes, and reversing
-- the order reverses the winner on the next boot.
function T.tests.selected_package_overrides_reach_the_running_field_in_order()
  local versionId = AcceptanceHarness.defaultVersion()
  local identity = ModPackageFixture.identity(versionId)
  local overridePath = ModPackageFixture.messageBankPath(OVERRIDE_BANK)
  local basePath = ModPackageFixture.messageBankPath(BASE_BANK)
  local base = GeneratedCacheFixture.reader(versionId)
  local baseOverride = base:resolveAsset(overridePath)
  local baseShare = base:resolveAsset(basePath)
  Assert.notNil(baseOverride, "the base view retains the asset the selection replaces")
  Assert.notNil(baseShare, "the base view retains the asset no package names")

  local state = { game = nil, packages = nil }
  local log = ModPackageFixture.newReadLog()
  log.failOn = { [UNUSED_PAYLOAD] = true }
  local cleanupFailure
  local ok, err = xpcall(function()
    ModPackageFixture.withReadLog(log, function()
      writeSelection(versionId, identity, { "one.zip", "two.zip" }, {
        ["one.zip"] = "PACKAGE ONE",
        ["two.zip"] = "PACKAGE TWO",
      })

      local packages, selected = selectPackages(versionId, identity, FIRST_EPOCH, base)
      state.packages = packages
      local reference = selected:resolveAsset(overridePath)
      Assert.notNil(reference, "the selected view resolves the overridden logical path")
      Assert.isNil(reference.data, "a package entry is a disk source, never resident base bytes")
      Assert.isTrue(
        reference.sourceId ~= baseOverride.sourceId,
        "a package entry never shares identity with the base entry at the same path"
      )
      Assert.equal(
        ModPackageFixture.payloadReadCount(log, overridePath),
        0,
        "selecting packages reads no package payload"
      )
      Assert.isTrue(selected:resolveAsset(basePath) == baseShare, "an unselected path borrows the base entry unchanged")

      local current = selected
      state.game = bootOnSelected(versionId, function()
        return current
      end)
      local game = state.game
      Assert.isTrue(game.runtime.cacheFs == selected, "the running field consumes the selected overlay")
      Assert.equal(
        ModPackageFixture.payloadReadCount(log, overridePath),
        0,
        "booting the field does not eagerly hydrate package payloads"
      )
      local provider = assert(game.runtime.messageProvider, "the running field owns its message provider")
      assert(provider:acquireBank(OVERRIDE_BANK), "the selected bank must open through the overlay")
      local winner = assert(provider:get(OVERRIDE_BANK, 0), "the selected bank serves its first message")
      Assert.equal(winner.text, "PACKAGE TWO", "the last selected package decides the content")
      -- The worker reads the mounted member in its own Lua state, which a
      -- main-state filesystem read wrapper cannot observe. The shared decoded
      -- owner is the observable boundary: the selected bytes are read once into
      -- it and pinned by this provider's own source lease.
      local sourceStats = assert(game.runtime.decoded, "the running field borrows the shared decoded owner"):stats()
      Assert.isTrue(
        sourceStats.pinnedBytes >= reference.size,
        "the overridden payload is read from its package on first use: "
          .. tostring(sourceStats.pinnedBytes)
          .. " pinned bytes"
      )
      assert(provider:acquireBank(BASE_BANK), "an unselected bank still opens from the base entries")
      Assert.notNil(provider:get(BASE_BANK, 0), "an unselected bank still serves base content")
      Assert.isTrue(
        selected:resolveAsset(basePath) == baseShare,
        "a base asset read in gameplay is still the store's own bytes"
      )
      Assert.equal(
        ModPackageFixture.payloadReadCount(log, UNUSED_PAYLOAD),
        0,
        "a package member no consumer requests is never read"
      )
      Assert.equal(game:renderAttempts(), 0, "the scenario stops before GPU rendering")
    end)

    -- The same selection, reversed: the previous epoch drains and unmounts
    -- before the packages and the order are rewritten.
    local firstGame = state.game
    state.game = nil
    firstGame:close()
    local closeFailure = teardown({ game = nil, packages = state.packages }, versionId)
    Assert.isNil(closeFailure, "the first selection retires cleanly: " .. tostring(closeFailure))

    ModPackageFixture.withReadLog(log, function()
      writeSelection(versionId, identity, { "two.zip", "one.zip" }, {
        ["one.zip"] = "PACKAGE ONE",
        ["two.zip"] = "PACKAGE TWO",
      })
      local packages, selected = selectPackages(versionId, identity, SECOND_EPOCH, base)
      state.packages = packages
      local current = selected
      state.game = bootOnSelected(versionId, function()
        return current
      end)
      local game = state.game
      local provider = assert(game.runtime.messageProvider, "the second boot owns its message provider")
      assert(provider:acquireBank(OVERRIDE_BANK), "the selected bank must open on the second boot")
      local winner = assert(provider:get(OVERRIDE_BANK, 0), "the selected bank serves its first message")
      Assert.equal(winner.text, "PACKAGE ONE", "reversing the order reverses the winner")
      Assert.equal(
        ModPackageFixture.payloadReadCount(log, UNUSED_PAYLOAD),
        0,
        "the unused member stays unread on the reversed selection too"
      )
    end)
  end, debug.traceback)
  cleanupFailure = teardown(state, versionId)
  if not ok then
    error(err, 0)
  end
  Assert.isNil(
    cleanupFailure,
    "the scenario restores the mod configuration and its mounts: " .. tostring(cleanupFailure)
  )
end

-- The storage vocabulary the selection owners raise through.
---@param name string
---@return string
local function storageCode(name)
  local StorageErrors = require("libs.storage.src.errors")
  local code = StorageErrors[name]
  Assert.notNil(code, "the storage error vocabulary must name " .. name)
  return code
end

-- A selection that must be rejected, and the category it must name along with
-- the offending package or config file.
---@param versionId string
---@param identity table<string, unknown>
---@param base CacheFs
---@param expectedCode string
---@param expectedName string a substring of the reported failure
local function expectSelectionRejected(versionId, identity, base, expectedCode, expectedName)
  local Errors = require("libs.errors.src.Errors")
  local ok, failure = pcall(selectPackages, versionId, identity, FIRST_EPOCH, base)
  Assert.isFalse(ok, "a broken selection must be rejected instead of opening")
  Assert.isTrue(Errors.is(failure), "a selection failure is a typed error: " .. tostring(failure))
  local error = failure --[[@as Errors.Error]]
  Assert.equal(error.code, expectedCode, "the failure names its category: " .. tostring(error))
  Assert.isTrue(
    tostring(error):find(expectedName, 1, true) ~= nil,
    "the failure names the offending file: " .. tostring(error) .. " must mention " .. expectedName
  )
end

-- No selected-package failure may write, replace, or delete the version's
-- generated archive: packages are not base artifact facts, so a broken
-- selection can never trigger a base rebuild.
---@param versionId string
---@param writes string[]
local function assertNoBaseArchiveWrite(versionId, writes)
  for _, path in ipairs(writes) do
    if type(path) == "string" and (path == versionId or path:sub(1, #versionId + 1) == versionId .. "/") then
      error("a package failure wrote the base generated root: " .. path, 0)
    end
  end
end

-- Wrong package identity, missing or malformed selection metadata, an absent
-- or incomplete package, and a corrupt selected payload each stay visible at
-- their own source; none of them silently substitutes the base asset, and none
-- of them touches the base archive.
function T.tests.broken_selection_and_broken_payload_stay_visible_at_their_source()
  local versionId = AcceptanceHarness.defaultVersion()
  local identity = ModPackageFixture.identity(versionId)
  local overridePath = ModPackageFixture.messageBankPath(OVERRIDE_BANK)
  local base = GeneratedCacheFixture.reader(versionId)
  local baseOverride = assert(base:resolveAsset(overridePath), "the base view retains the replaced asset")

  local state = { game = nil, packages = nil }
  local log = ModPackageFixture.newReadLog()
  local cleanupFailure
  local ok, err = xpcall(function()
    local incompatible = storageCode("MOD_PACKAGE_INCOMPATIBLE")
    local invalid = storageCode("MOD_PACKAGE_INVALID")
    local mountFailed = storageCode("MOD_PACKAGE_MOUNT_FAILED")
    local configInvalid = storageCode("MOD_CONFIG_INVALID")

    -- Every failing case runs with the base-archive write log active; fixture
    -- writes happen outside it so only selection-owned writes are observed.
    local function rejecting(basename, packageId, expectedCode)
      ModPackageFixture.writeConfig(versionId, { basename })
      expectSelectionRejected(versionId, identity, base, expectedCode, packageId)
      ModPackageFixture.removeArchive(versionId, basename)
      ModPackageFixture.removeConfig(versionId)
    end

    local function writingWatched(fn)
      ModPackageFixture.withSnapshotWriteLog(function(writes)
        ModPackageFixture.withReadLog(log, function()
          fn()
        end)
        assertNoBaseArchiveWrite(versionId, writes)
      end)
    end

    -- A package built for another version, asset revision, or script API is a
    -- compatibility failure, reported before any runtime aggregate exists.
    for _, mismatch in ipairs({
      { field = "versionId", value = versionId == "soulsilver" and "heartgold" or "soulsilver" },
      { field = "assetRevision", value = identity.assetRevision + 1 },
      { field = "scriptApi", value = identity.scriptApi + 1 },
    }) do
      local basename = "mismatch-" .. mismatch.field .. ".zip"
      local manifestIdentity = {
        versionId = identity.versionId,
        assetRevision = identity.assetRevision,
        scriptApi = identity.scriptApi,
      }
      manifestIdentity[mismatch.field] = mismatch.value
      ModPackageFixture.writeArchive(versionId, basename, manifestIdentity, {
        id = "mismatched-" .. mismatch.field,
        files = {
          [overridePath] = ModPackageFixture.messageBank(OVERRIDE_BANK, "PACKAGE"),
        },
      })
      writingWatched(function()
        rejecting(basename, "mismatched-" .. mismatch.field, incompatible)
      end)
    end

    -- A selected archive that is not there is a mount failure, never an empty
    -- selection.
    writingWatched(function()
      ModPackageFixture.writeConfig(versionId, { "absent.zip" })
      expectSelectionRejected(versionId, identity, base, mountFailed, "absent.zip")
      ModPackageFixture.removeConfig(versionId)
    end)

    -- A config that escapes its version's mods directory is a config failure.
    writingWatched(function()
      love.filesystem.createDirectory(ModPackageFixture.root(versionId))
      assert(love.filesystem.write(ModPackageFixture.configPath(versionId), 'return { "../escape.zip" }'))
      expectSelectionRejected(versionId, identity, base, configInvalid, "escape.zip")
      ModPackageFixture.removeConfig(versionId)
      assert(
        love.filesystem.write(ModPackageFixture.configPath(versionId), 'return { [1] = "one.zip", [3] = "two.zip" }')
      )
      expectSelectionRejected(versionId, identity, base, configInvalid, "load-order.lua")
      ModPackageFixture.removeConfig(versionId)
    end)

    -- A manifest that declares a member the archive does not carry is rejected
    -- while the package is still metadata, before any consumer sees it.
    writingWatched(function()
      local basename = "incomplete.zip"
      ModPackageFixture.writeArchive(versionId, basename, identity, {
        id = "incomplete",
        files = {},
        manifest = require("libs.codec.src.LuaWriter").encode({
          schema = ModPackageFixture.SCHEMA,
          id = "incomplete",
          revision = "1",
          versionId = identity.versionId,
          assetRevision = identity.assetRevision,
          scriptApi = identity.scriptApi,
          files = { { path = overridePath, size = 32 } },
        }),
      })
      rejecting(basename, "incomplete", invalid)
    end)

    -- An indexed member whose bytes no reader accepts fails at the selected
    -- source: the base asset at the same path is never substituted.
    writingWatched(function()
      local basename = "corrupt.zip"
      ModPackageFixture.writeArchive(versionId, basename, identity, {
        id = "corrupt",
        files = { [overridePath] = "not a compact message bank" },
      })
      ModPackageFixture.writeConfig(versionId, { basename })
      local packages, selected = selectPackages(versionId, identity, FIRST_EPOCH, base)
      state.packages = packages
      local selectedOverride = assert(selected:resolveAsset(overridePath), "the selected payload still resolves")
      Assert.isTrue(selectedOverride ~= baseOverride, "the selected entry is never the base entry")
      Assert.isNil(selectedOverride.data, "the selected entry is a disk source")

      local decoded = ResidentAssetCache.new({
        idleByteLimit = 64 * 1024,
        release = function(value)
          if type(value.release) == "function" then
            value:release()
          end
        end,
      })
      local AssetPreparationQueue = require("libs.hgss.src.presentation.AssetPreparationQueue")
      local queue = AssetPreparationQueue.new(selected, { decoded = decoded })
      local provider = FieldMessageProvider.new(selected, {
        acquireSource = function(reference)
          return queue:acquireSource(reference)
        end,
      })
      local bank, failure = provider:acquireBank(OVERRIDE_BANK)
      Assert.isNil(bank, "a corrupt selected payload must not open as a bank")
      local Errors = require("libs.errors.src.Errors")
      Assert.isTrue(Errors.is(failure), "the selected payload failure is typed: " .. tostring(failure))
      Assert.equal(
        failure --[[@as Errors.Error]].code,
        FieldMessageProvider.MESSAGE_BANK_MISSING,
        "the failure stays the format family's, naming the selected source: " .. tostring(failure)
      )
      local _, getFailure = provider:get(OVERRIDE_BANK, 0)
      Assert.isTrue(Errors.is(getFailure), "a bank that failed to open is never served from the base entry")
      -- The base entry at this path is a valid bank and would have opened, so
      -- reaching the selected format failure already proves the bytes came from
      -- the selected package rather than the base store.
      queue:release()
      provider:dispose()

      local closeFailure = teardown({ game = nil, packages = state.packages }, versionId)
      Assert.isNil(closeFailure, "the broken selection unmounts: " .. tostring(closeFailure))
      state.packages = nil
    end)

    -- Removing the selection restores base behavior for the same path.
    writingWatched(function()
      ModPackageFixture.cleanup(versionId)
      local packages, selected = selectPackages(versionId, identity, FIRST_EPOCH, base)
      state.packages = packages
      Assert.isTrue(
        selected:resolveAsset(overridePath) == baseOverride,
        "an empty selection falls through to the base entry at the path"
      )
      Assert.isTrue(
        selected:resolveAsset(overridePath) == baseOverride and base:resolveAsset(overridePath) == baseOverride,
        "the base entry is the only one left at the path"
      )
      Assert.isTrue(selected:resolveAsset(FieldMessageCache.bankPath(BASE_BANK)) ~= nil, "base entries still resolve")
      local closeFailure = teardown({ game = nil, packages = state.packages }, versionId)
      Assert.isNil(closeFailure, "the base-only selection unmounts: " .. tostring(closeFailure))
      state.packages = nil
    end)
  end, debug.traceback)
  cleanupFailure = teardown(state, versionId)
  if not ok then
    error(err, 0)
  end
  Assert.isNil(
    cleanupFailure,
    "the scenario restores the mod configuration and its mounts: " .. tostring(cleanupFailure)
  )
end

-- Bounded wait for real worker progress; a hung worker fails the scenario
-- instead of stalling the suite.
---@param queue table
---@param token integer
---@param label string
local function waitReady(queue, token, label)
  local deadline = love.timer.getTime() + 20
  while love.timer.getTime() < deadline do
    local state, failure = queue:poll(token)
    if state == "ready" then
      return
    end
    if state == "failed" then
      error(label .. " failed: " .. tostring(failure), 0)
    end
    love.timer.sleep(0.002)
  end
  error("timed out waiting for " .. label, 0)
end

-- One decoded-CPU owner at the scale a selected runtime injects, here with a
-- small idle limit so an oversized package payload has to be evicted after its
-- final return.
---@param idleByteLimit integer
---@return table
local function decodedOwner(idleByteLimit)
  return ResidentAssetCache.new({
    idleByteLimit = idleByteLimit,
    release = function(value)
      if type(value.release) == "function" then
        value:release()
      end
    end,
  })
end

---@return string 4x4 opaque RGBA scanlines
local function pngBytes()
  local row = string.rep(string.char(0x20, 0x60, 0xA0, 0xFF), 4)
  return PngEncoder.encode(4, 4, string.rep(row, 4))
end

-- A synthetic audio family whose two sequences sound the same sample on two
-- different players, so one package sample backs two simultaneous voices.
---@return AudioFixture.Bundle
local function twoVoiceBundle()
  local AudioCache = require("libs.assets.src.audio.AudioCache")
  local bundle = AudioFixture.bundle()
  local sampleKey = AudioFixture.key(1)
  -- The synthetic bank voice opens each note at the full register: the
  -- scenario proves shared storage and voice lifetime, not envelope
  -- ballistics, so the note is audible on the first mixed interval.
  local instantVoice = {
    generator = { kind = "sample", sample = sampleKey },
    originalKey = 60,
    envelope = { attack = 127, decay = 127, sustain = 127, release = 127 },
    pan = 64,
  }
  bundle.banks[12] = AudioFixture.bank(12, "BANK_TEST", { sampleKey, AudioFixture.key(2) }, {
    [0] = { kind = "direct", voice = instantVoice },
  })
  local function program()
    return {
      entry = 1,
      initialTrackMask = 0x0001,
      instructions = {
        { op = "program", program = 0 },
        { op = "note", key = 60, velocity = 100, duration = 24 },
        { op = "wait", duration = 12 },
        { op = "jump", target = 2 },
      },
    }
  end
  bundle.sequences[0] = AudioFixture.sequence(0, "SEQ_TEST_A", 12, 1, program())
  bundle.sequences[1] = AudioFixture.sequence(1, "SEQ_TEST_ALT", 12, 3, program())
  bundle.samples[sampleKey] = AudioFixture.pcm16le({ 2000, 2000, 2000, 2000 })
  bundle.sampleMetadata[sampleKey] = AudioFixture.sampleMetadata(sampleKey, { frames = 4 })
  bundle.index.sequences[1] = { id = 1, symbol = "SEQ_TEST_ALT", bankId = 12, playerId = 3 }
  bundle.index.sequenceBySymbol["SEQ_TEST_ALT"] = 1
  bundle.index.players[3] = { id = 3, maxSequences = 16, channelMask = 0xFFFF }
  assert(AudioCache.bankPath(12) ~= nil, "the fixture audio family names its bank path")
  return bundle
end

-- Package source bytes obey the shared decoded-CPU ownership policy: one
-- mounted member serves every follower, an oversized payload is evicted after
-- its final return, voices keep their own sample leases, and the mount outlives
-- every physical read while a new epoch cannot reach the old selection's
-- entries.
function T.tests.package_source_leases_are_shared_pinned_and_released_before_unmount()
  local AudioCache = require("libs.assets.src.audio.AudioCache")
  local LuaWriter = require("libs.codec.src.LuaWriter")
  local Pcm16 = require("libs.nds.src.nitro.sound.Pcm16")
  local versionId = AcceptanceHarness.defaultVersion()
  local identity = ModPackageFixture.identity(versionId)
  local base = GeneratedCacheFixture.reader(versionId)
  local pngPath = "assets/generated/acceptance/selected.png"
  local big = ModPackageFixture.pcmSample(4000)
  Assert.isTrue(#big.data:getString() > 1024, "the oversized fixture payload exceeds the small idle limit")

  local bundle = twoVoiceBundle()
  local members = ModPackageFixture.audioMembers(bundle)
  members[pngPath] = pngBytes()
  members[big.path] = big.data
  members[AudioCache.sampleMetadataPath(AudioFixture.key(3))] =
    LuaWriter.encode(AudioFixture.sampleMetadata(AudioFixture.key(3), { frames = big.frames }))
  local samplePath = big.path

  local state = { game = nil, packages = nil }
  local log = ModPackageFixture.newReadLog()
  local unmounts = {}
  local cleanupFailure
  local ok, err = xpcall(function()
    ModPackageFixture.writeArchive(versionId, "shared.zip", identity, {
      id = "shared-ownership",
      files = members,
    })
    ModPackageFixture.writeConfig(versionId, { "shared.zip" })
    ModPackageFixture.withReadLog(log, function()
      local packages, selected = selectPackages(versionId, identity, FIRST_EPOCH, base)
      state.packages = packages
      local decoded = decodedOwner(1024)
      local AssetPreparationQueue = require("libs.hgss.src.presentation.AssetPreparationQueue")
      local queue = AssetPreparationQueue.new(selected, { decoded = decoded })

      -- Two selectors for one package source coalesce onto one read and one
      -- charged payload, and each follower owns its own lease.
      local first = queue:request("image-derivative", pngPath, "demand")
      local second = queue:request("image-derivative", pngPath, "demand")
      waitReady(queue, first, "the first selected decode")
      waitReady(queue, second, "the second selected decode")
      local firstLease = queue:take(first)
      local chargedOnce = decoded:stats().pinnedBytes
      Assert.isTrue(chargedOnce > 0, "a decoded package payload is charged to the shared owner")
      Assert.equal(firstLease.value.payload.width, 4, "the selected package supplied the decoded image")
      local secondLease = queue:take(second)
      Assert.equal(
        decoded:stats().pinnedBytes,
        chargedOnce,
        "followers share one charged payload instead of allocating two"
      )
      decoded:returnLease(firstLease)
      decoded:returnLease(secondLease)
      decoded:trim()
      Assert.equal(decoded:stats().pinnedBytes, 0, "returning both followers unpins the shared payload")

      -- Compact acquisition of the same disk-backed payload hands both
      -- consumers the store's own bytes; the oversize entry is evicted after
      -- the final return rather than permanently retained.
      local reference = assert(selected:resolveAsset(samplePath), "the selected package resolves its sample")
      local firstSource = queue:acquireSource(reference)
      local secondSource = queue:acquireSource(reference)
      Assert.isTrue(
        firstSource.value == secondSource.value,
        "two acquisitions of one package source share a single allocation"
      )
      local pcm = Pcm16.fromData(firstSource.value)
      Assert.equal(pcm.frames, big.frames, "the package PCM bytes read in place")
      Assert.equal(pcm:read(0), 1000, "the borrowed frame values are the package's own")
      firstSource:release()
      Assert.isNil(firstSource.value, "a returned package source lease clears its reference")
      Assert.isTrue(secondSource.value ~= nil, "releasing one follower never invalidates another")
      Assert.equal(Pcm16.fromData(secondSource.value):read(7), 1000, "the surviving lease still reads")
      secondSource:release()
      Assert.equal(decoded:stats().idleBytes, 0, "an over-idle package payload is evicted after its final return")

      -- Voices take their own leases from the same shared owner: two voices of
      -- one package sample sound together, stopping one leaves the other
      -- sounding, and the mixer's own note-off drain returns the last lease.
      local AudioRuntime = require("libs.hgss.src.audio.AudioRuntime")
      local audio = AudioRuntime.compose({
        cacheFs = selected,
        outputRate = 48000,
        acquireSource = function(target)
          return queue:acquireSource(target)
        end,
      })
      local function render(frames)
        local out = {}
        while #out < frames do
          audio.sound:updateSoundFrame()
          local span = audio.renderer:render(2)
          for _, value in ipairs(span) do
            out[#out + 1] = value
          end
        end
        return out
      end
      local function assertAudible(frames, label)
        for _, value in ipairs(frames) do
          if value ~= 0 then
            return
          end
        end
        error(label .. " produced no audible frames", 0)
      end
      local pinnedBeforeAudio = decoded:stats().pinnedBytes
      audio.sound:playMusic(0)
      audio.sound:play(1)
      assertAudible(render(600), "two simultaneous voices over one package sample")
      Assert.isTrue(audio.sound:isEffectPlaying(0), "the first voice sounds")
      Assert.isTrue(audio.sound:isEffectPlaying(1), "the second voice sounds")
      audio.sound:stop(0)
      assertAudible(render(300), "the surviving voice's note-off tail")
      Assert.isFalse(audio.sound:isEffectPlaying(0), "stopping one voice releases it")
      Assert.isTrue(audio.sound:isEffectPlaying(1), "stopping one voice leaves the other sounding")
      audio.sound:stop(1)
      render(1200)
      Assert.isFalse(audio.sound:isEffectPlaying(1), "the last voice stops")
      audio:dispose()
      decoded:trim()
      Assert.equal(
        decoded:stats().pinnedBytes,
        pinnedBeforeAudio,
        "every voice lease is returned once the voices are gone"
      )

      -- Retirement drains physical work before the mount goes away, and a new
      -- epoch cannot reach the retired selection's entries.
      local retiredReference = assert(selected:resolveAsset(samplePath), "the selected sample resolves")
      queue:release()
      local unmount = love.filesystem.unmount
      love.filesystem.unmount = function(name)
        unmounts[#unmounts + 1] = name
        return unmount(name)
      end
      local okClose, closeFailure = pcall(function()
        state.packages:close()
      end)
      love.filesystem.unmount = unmount
      Assert.isTrue(okClose, "the drained selection unmounts: " .. tostring(closeFailure))
      state.packages = nil
      Assert.isTrue(#unmounts >= 1, "teardown really unmounted the selected package")
      local unmountedName = unmounts[#unmounts]
      Assert.isTrue(
        tostring(unmountedName):find("shared.zip", 1, true) ~= nil,
        "the unmounted archive is the selected package: " .. tostring(unmountedName)
      )

      ModPackageFixture.cleanup(versionId)
      local secondPackages, secondSelected = selectPackages(versionId, identity, SECOND_EPOCH, base)
      state.packages = secondPackages
      Assert.isNil(secondSelected:resolveAsset(samplePath), "an empty new selection selects nothing")
      local rejected = pcall(function()
        return secondPackages:readData(retiredReference)
      end)
      Assert.isFalse(rejected, "a retired selection's source reference never enters a new epoch")
      local closeSecond = teardown({ game = nil, packages = state.packages }, versionId)
      Assert.isNil(closeSecond, "the second selection retires cleanly: " .. tostring(closeSecond))
      state.packages = nil
    end)
  end, debug.traceback)
  cleanupFailure = teardown(state, versionId)
  if not ok then
    error(err, 0)
  end
  Assert.isNil(
    cleanupFailure,
    "the scenario restores the mod configuration and its mounts: " .. tostring(cleanupFailure)
  )
end

-- The writer's own output path for the real selected version, occupied by a
-- directory that holds one file: a real filesystem condition no Lua state can
-- remove, so persistence cannot succeed while the scenario plays. The scenario
-- therefore proves playable readiness that does not depend on a snapshot write,
-- and leaves the marker in place until teardown.
local BLOCKED_OUTPUT = AcceptanceHarness.defaultVersion() .. "/cache.zip.new"

local function occupySnapshotOutput()
  love.filesystem.createDirectory(BLOCKED_OUTPUT)
  Assert.isTrue(
    love.filesystem.write(BLOCKED_OUTPUT .. "/held", "the snapshot writer cannot open its output"),
    "the scenario occupies the snapshot writer's output path"
  )
end

local function releaseSnapshotOutput()
  love.filesystem.remove(BLOCKED_OUTPUT .. "/held")
  love.filesystem.remove(BLOCKED_OUTPUT)
end

-- One closed synthetic base: a complete generated graph saved through the
-- production archive writer and hydrated back through the production boot
-- reader, so the scenario proves a genuinely complete base needs no source.
---@param identity table<string, unknown>
---@param root string private generated-cache root
---@param baseOnlyPath string
---@param replacedPath string
---@return CacheFs hydrated base view
---@return table candidate the hydrated snapshot
local function closedCompleteBase(identity, root, baseOnlyPath, replacedPath)
  local SnapshotBootFixture = require("tests.support.SnapshotBootFixture")
  local ResidentCache = require("libs.storage.src.ResidentCache")
  local cut = {
    generationId = identity.generationId,
    identity = identity,
    epoch = 1,
    sequence = 4,
    entries = {
      SnapshotBootFixture.blob(identity, baseOnlyPath, "return { closedBaseMember = true }\n"),
      SnapshotBootFixture.blob(identity, replacedPath, "the closed base's own message bytes"),
    },
    artifacts = {
      {
        kind = "fixture",
        key = "closed-base",
        marker = "fixture-ready",
        dependencies = {},
        ownedRoots = {},
        sharedPaths = {},
        files = { baseOnlyPath, replacedPath },
      },
    },
    milestones = {},
    firstPlay = false,
    complete = true,
  }
  SnapshotBootFixture.save(root, cut)
  local candidate =
    assert(SnapshotBootFixture.open(root, identity), "a complete synthetic base must hydrate for the next boot")
  Assert.equal(candidate.complete, true, "the closed fixture base proves its whole graph")
  local store = ResidentCache.new(identity.versionId, "base:" .. tostring(identity.generationId))
  local batch = {}
  for position, reference in ipairs(SnapshotBootFixture.entries(candidate)) do
    batch[position] = {
      path = reference.path,
      data = reference.data,
      size = reference.size,
      sourceId = reference.sourceId,
      contentId = reference.contentId,
    }
  end
  store:commit(store:prepare(batch))
  return CacheFs.fromStore(store), candidate
end

-- The integrated behavior and ownership evidence: a complete base boots without
-- any source, a compatible selection overlays it, gameplay reaches its first
-- boundaries while the snapshot writer cannot persist anything and no archive
-- byte is read back, and repeated transitions leave the shared ownership
-- exactly where it started.
function T.tests.integrated_selection_keeps_readiness_and_ownership_stable()
  local LuaWriter = require("libs.codec.src.LuaWriter")
  local SnapshotBootFixture = require("tests.support.SnapshotBootFixture")
  local versionId = AcceptanceHarness.defaultVersion()
  local identity = ModPackageFixture.identity(versionId)
  local overridePath = ModPackageFixture.messageBankPath(OVERRIDE_BANK)
  local closedRoot = "mod-base-probe"
  local closedOnlyPath = "data/generated/acceptance/closed-only.lua"

  local state = { game = nil, packages = nil }
  local log = ModPackageFixture.newReadLog()
  local writes = {}
  local originalWrite = love.filesystem.write
  local realWrite = originalWrite
  local measurements = {}
  local cleanupFailure
  local ok, err = xpcall(function()
    -- A complete synthetic base, hydrated by the production boot reader, then
    -- overlaid by a compatible selection: nothing in this leg can consult the
    -- user's ROM, and the package layer still decides its own paths.
    local closedBase, candidate = closedCompleteBase(identity, closedRoot, closedOnlyPath, overridePath)
    measurements.closedBaseArchiveBytes = assert(love.filesystem.getInfo(closedRoot .. "/cache.zip")).size
    measurements.closedBaseResidentBytes = 0
    for _, entry in ipairs(candidate.entries) do
      measurements.closedBaseResidentBytes = measurements.closedBaseResidentBytes + entry.size
    end
    Assert.isTrue(measurements.closedBaseArchiveBytes > 0, "a persisted complete base has archive bytes")
    Assert.isTrue(
      measurements.closedBaseResidentBytes >= measurements.closedBaseArchiveBytes - 4096,
      "the resident base carries at least the payload the archive stored, minus archive framing"
    )

    ModPackageFixture.withReadLog(log, function()
      ModPackageFixture.writeArchive(versionId, "closed.zip", identity, {
        id = "closed-base-selection",
        files = {
          [overridePath] = ModPackageFixture.messageBank(OVERRIDE_BANK, "CLOSED BASE PACKAGE"),
        },
      })
      ModPackageFixture.writeConfig(versionId, { "closed.zip" })
      local packages, selected = selectPackages(versionId, identity, FIRST_EPOCH, closedBase)
      state.packages = packages
      local provider = FieldMessageProvider.new(selected, {
        acquireSource = function(target)
          local data = target.data or assert(packages:readData(target))
          local lease = { value = data }
          function lease:release()
            self.value = nil
          end
          return lease
        end,
      })
      assert(provider:acquireBank(OVERRIDE_BANK), "the selection overlays the closed complete base")
      Assert.equal(
        assert(provider:get(OVERRIDE_BANK, 0)).text,
        "CLOSED BASE PACKAGE",
        "the selected package decides the closed base's overridden path"
      )
      provider:dispose()
      local baseOnly = assert(selected:resolveAsset(closedOnlyPath), "a path no package names falls through to base")
      Assert.equal(
        assert(baseOnly.data:getString()),
        "return { closedBaseMember = true }\n",
        "the closed base's own bytes are served unchanged"
      )
      for _, path in ipairs(log.reads) do
        Assert.isTrue(
          type(path) ~= "string" or (path:find("%.nds") == nil and path:find("romfs") == nil),
          "a complete base boot with a selection reads no source bytes: " .. tostring(path)
        )
      end
      local closeClosed = teardown({ game = nil, packages = state.packages }, versionId)
      Assert.isNil(closeClosed, "the closed-base selection unmounts: " .. tostring(closeClosed))
      state.packages = nil
      SnapshotBootFixture.releaseWriters()
      SnapshotBootFixture.removeRoot(closedRoot)
    end)

    -- The real selected version: resident base bytes plus a selection, played
    -- while the snapshot writer cannot persist anything.
    local base = GeneratedCacheFixture.reader(versionId)
    local preparedSnapshot = GeneratedCacheFixture.candidate(versionId)
    measurements.baseArchiveBytes = assert(love.filesystem.getInfo(versionId .. "/cache.zip")).size
    measurements.residentBaseBytes = 0
    for _, entry in ipairs(preparedSnapshot.entries) do
      measurements.residentBaseBytes = measurements.residentBaseBytes + entry.size
    end
    for _, bankId in ipairs({ OVERRIDE_BANK, BASE_BANK }) do
      local reference = assert(base:resolveAsset(FieldMessageCache.bankPath(bankId)), "the base carries its banks")
      measurements["compactMessageBytes" .. tostring(bankId)] = reference.size
    end
    Assert.isTrue(measurements.residentBaseBytes > 0, "the resident base carries bytes")
    Assert.isTrue(
      measurements.compactMessageBytes445 > 0 and measurements.compactMessageBytes542 > 0,
      "the compact message banks are resident bytes, not expanded tables"
    )

    ModPackageFixture.writeArchive(versionId, "integrated.zip", identity, {
      id = "integrated",
      files = {
        [overridePath] = ModPackageFixture.messageBank(OVERRIDE_BANK, "INTEGRATED PACKAGE"),
      },
      extra = string.rep("integrated-unused;", 2048),
    })
    ModPackageFixture.writeConfig(versionId, { "integrated.zip" })
    occupySnapshotOutput()
    love.filesystem.write = function(path, ...)
      writes[#writes + 1] = path
      return realWrite(path, ...)
    end

    ModPackageFixture.withReadLog(log, function()
      local packages, selected = selectPackages(versionId, identity, SECOND_EPOCH, base)
      state.packages = packages
      local current = selected
      state.game = bootOnSelected(versionId, function()
        return current
      end)
      local game = state.game
      game:waitForFieldEntry()
      local provider = assert(game.runtime.messageProvider, "the running field owns its message provider")
      local idleAfterRound = {}
      local readsAfterRound = {}
      for round = 1, 3 do
        assert(provider:acquireBank(OVERRIDE_BANK), "round " .. round .. " opens the selected bank")
        Assert.equal(
          assert(provider:get(OVERRIDE_BANK, 0)).text,
          "INTEGRATED PACKAGE",
          "round " .. round .. " serves the selected content"
        )
        provider:releaseBank(OVERRIDE_BANK)
        game:step()
        local decoded = assert(game.runtime.decoded, "the running field borrows the shared decoded owner")
        local stats = decoded:stats()
        Assert.equal(stats.pinnedBytes, 0, "round " .. round .. " returns every lease it took")
        idleAfterRound[round] = stats.idleBytes
        readsAfterRound[round] = ModPackageFixture.payloadReadCount(log, overridePath)
      end
      Assert.equal(idleAfterRound[2], idleAfterRound[1], "a repeated transition does not accumulate idle package bytes")
      Assert.equal(idleAfterRound[3], idleAfterRound[1], "ownership stays stable over the third transition")
      Assert.equal(readsAfterRound[3], readsAfterRound[1], "a repeated transition re-reads no package payload")
      measurements.sharedDecodedIdleBytes = idleAfterRound[3]
      measurements.packagePayloadReads = readsAfterRound[3]
      for _, path in ipairs(log.reads) do
        Assert.isTrue(
          type(path) ~= "string" or path:sub(-#(versionId .. "/cache.zip")) ~= versionId .. "/cache.zip",
          "gameplay never reads the written snapshot back: " .. tostring(path)
        )
      end
      Assert.notNil(
        love.filesystem.getInfo(BLOCKED_OUTPUT .. "/held"),
        "no snapshot succeeded while the field played from resident and selected bytes"
      )
      Assert.equal(game:renderAttempts(), 0, "the scenario stops before GPU rendering")
      measurements.outstandingPinnedBytes = assert(game.runtime.decoded):stats().pinnedBytes
      Assert.equal(measurements.outstandingPinnedBytes, 0, "the played field holds no outstanding lease")
    end)

    love.filesystem.write = originalWrite
    local generatedWrites = 0
    for _, path in ipairs(writes) do
      if type(path) == "string" and (path == versionId or path:sub(1, #versionId + 1) == versionId .. "/") then
        if path:sub(1, #BLOCKED_OUTPUT) ~= BLOCKED_OUTPUT then
          generatedWrites = generatedWrites + 1
        end
      end
    end
    Assert.equal(generatedWrites, 0, "playing with a selection performs no main-thread generated write")
  end, debug.traceback)
  love.filesystem.write = originalWrite
  pcall(releaseSnapshotOutput)
  pcall(function()
    require("tests.support.SnapshotBootFixture").releaseWriters()
    require("tests.support.SnapshotBootFixture").removeRoot(closedRoot)
  end)
  cleanupFailure = teardown(state, versionId)
  if not ok then
    error(err, 0)
  end
  Assert.isNil(
    cleanupFailure,
    "the scenario restores the mod configuration and its mounts: " .. tostring(cleanupFailure)
  )
  Assert.isTrue(
    LuaWriter.encode(measurements):find("residentBaseBytes", 1, true) ~= nil,
    "the scenario measured the resource families it reports"
  )
end

return T
