-- Launcher cue host behavior. Filesystem and audio device boundaries are
-- deterministic; the owner still has to request the five amended OGG paths,
-- bound simultaneous voices, fade the boot cue and release every source once.

local Assert = require("tests.support.Assert")

local T = {}

local CUES = { "boot", "focus", "confirm", "back", "error" }

local function expectedPath(cue)
  return "assets/audio/launcher/" .. cue .. ".ogg"
end

local function withAudioHost(options, fn)
  options = options or {}
  local originalAudio = love.audio
  local originalSound = love.sound
  local originalNewSoundData = originalSound and originalSound.newSoundData
  local audio = originalAudio or {}
  love.audio = audio
  local sound = originalSound or {}
  love.sound = sound
  sound.newSoundData = function(data)
    if data:getFilename() == options.invalidPath then
      error("synthetic audio decode failure", 0)
    end
    return { release = function() end }
  end
  local originalModule = package.loaded["app.src.launcher.LauncherAudio"]
  local originalNewSource = audio.newSource
  local originalAssets = package.loaded["app.src.launcher.LauncherAssets"]
  local sources = {}
  local files = {}
  package.loaded["app.src.launcher.LauncherAudio"] = nil
  package.loaded["app.src.launcher.LauncherAssets"] = {
    read = function(path)
      if path == options.missingPath then
        return nil
      end
      for _, cue in ipairs(CUES) do
        if path == expectedPath(cue) then
          local raw = love.filesystem.newFileData("OGG-HOST-FIXTURE", path)
          local fileData = { path = path, releases = 0, raw = raw }
          function fileData:getFilename()
            return self.path
          end
          function fileData:getSize()
            return self.raw:getSize()
          end
          function fileData:getString()
            return self.raw:getString()
          end
          function fileData:release()
            self.releases = self.releases + 1
            self.raw:release()
          end
          files[#files + 1] = fileData
          return fileData
        end
      end
      return nil
    end,
  }
  audio.newSource = function(data)
    local path = data:getFilename()
    if path == options.failPath then
      error("synthetic audio device failure", 0)
    end
    local source = {
      data = data,
      path = path,
      playing = false,
      plays = 0,
      stops = 0,
      releases = 0,
      volume = 1,
    }
    function source:play()
      self.playing = true
      self.plays = self.plays + 1
    end
    function source:pause()
      self.playing = false
    end
    function source:stop()
      self.playing = false
      self.stops = self.stops + 1
    end
    function source:isPlaying()
      return self.playing
    end
    function source:getDuration()
      return 0.1
    end
    function source:setVolume(volume)
      self.volume = volume
    end
    function source:getVolume()
      return self.volume
    end
    function source:release()
      self.releases = self.releases + 1
      self.playing = false
    end
    sources[#sources + 1] = source
    return source
  end
  if options.audioMissing then
    audio.newSource = nil
  end
  if options.soundMissing then
    love.sound = nil
  end
  local ok, err = xpcall(function()
    fn(sources, files)
  end, debug.traceback)
  audio.newSource = originalNewSource
  if originalSound ~= nil then
    originalSound.newSoundData = originalNewSoundData
  end
  love.sound = originalSound
  love.audio = originalAudio
  package.loaded["app.src.launcher.LauncherAudio"] = originalModule
  package.loaded["app.src.launcher.LauncherAssets"] = originalAssets
  if not ok then
    error(err, 0)
  end
end

function T.requests_all_five_ogg_cues_and_releases_each_source_once()
  withAudioHost({}, function(sources, files)
    local LauncherAudio = require("app.src.launcher.LauncherAudio")
    local launcher = LauncherAudio.new()
    Assert.equal(#sources, 5, "the launcher acquires one source for each required cue")
    for index, cue in ipairs(CUES) do
      Assert.equal(sources[index].data:getFilename(), expectedPath(cue), "the cue uses its OGG runtime path")
      Assert.equal(files[index].releases, 1, "each FileData releases immediately after its Source is constructed")
    end
    launcher:play("boot")
    launcher:play("focus")
    launcher:play("confirm")
    launcher:play("back")
    launcher:play("error")
    for _, source in ipairs(sources) do
      Assert.equal(source.plays, 1, "each semantic cue starts its own source")
    end
    launcher:dispose()
    launcher:dispose()
    for _, source in ipairs(sources) do
      Assert.equal(source.releases, 1, "disposal releases every acquired source exactly once")
    end
  end)
end

function T.short_cues_are_bounded_and_boot_fades_for_eighty_milliseconds()
  withAudioHost({}, function(sources)
    local LauncherAudio = require("app.src.launcher.LauncherAudio")
    local launcher = LauncherAudio.new()
    for _ = 1, 20 do
      launcher:play("focus")
    end
    local playing = 0
    for _, source in ipairs(sources) do
      if source:isPlaying() then
        playing = playing + 1
      end
    end
    Assert.isTrue(playing <= 4, "short cue voices never exceed the four-voice bound")

    local boot = sources[1]
    launcher:play("boot")
    local playsBeforeFade = boot.plays
    launcher:fadeBoot(0.08)
    Assert.equal(boot.plays, playsBeforeFade, "input fade never restarts the boot cue")
    launcher:update(0.04)
    Assert.isTrue(boot.volume < 1, "the boot cue fades instead of cutting immediately")
    launcher:update(0.04)
    Assert.isFalse(boot:isPlaying(), "the boot cue is silent at the end of the 80 ms fade")
    launcher:dispose()
  end)
end

function T.missing_required_ogg_is_an_asset_error_not_a_silent_substitute()
  withAudioHost({ missingPath = expectedPath("confirm") }, function(sources, files)
    local LauncherAudio = require("app.src.launcher.LauncherAudio")
    local ok, failure = pcall(LauncherAudio.new)
    Assert.isFalse(ok, "a missing required cue cannot be hidden by a silent or synthetic substitute")
    Assert.isTrue(tostring(failure):find("confirm.ogg", 1, true) ~= nil, "the asset error names the missing cue")
    Assert.equal(#files, 2, "asset reads stop at the missing cue")
    for _, fileData in ipairs(files) do
      Assert.equal(fileData.releases, 1, "a missing later asset releases every earlier FileData")
    end
    for _, source in ipairs(sources) do
      Assert.equal(source.releases, 1, "a missing later asset releases every earlier Source")
    end
  end)
end

function T.corrupt_required_ogg_is_an_asset_error_not_an_unavailable_device()
  withAudioHost({ invalidPath = expectedPath("confirm") }, function(sources, files)
    local LauncherAudio = require("app.src.launcher.LauncherAudio")
    local ok, failure = pcall(LauncherAudio.new)
    Assert.isFalse(ok, "a required cue that cannot decode is an asset failure")
    Assert.isTrue(tostring(failure):find("confirm.ogg", 1, true) ~= nil, "the asset error names the corrupt cue")
    Assert.equal(#sources, 2, "corrupt decoding stops before acquiring a Source for that cue")
    Assert.equal(#files, 3, "the corrupt cue's FileData was acquired for validation")
    for _, source in ipairs(sources) do
      Assert.equal(source.releases, 1, "partial construction releases prior Sources")
    end
    for _, fileData in ipairs(files) do
      Assert.equal(fileData.releases, 1, "partial construction releases every FileData")
    end
  end)
end

function T.audio_device_failure_never_prevents_silent_launcher_use()
  withAudioHost({ failPath = expectedPath("boot") }, function(sources, files)
    local LauncherAudio = require("app.src.launcher.LauncherAudio")
    local ok, launcher = pcall(LauncherAudio.new)
    Assert.isTrue(ok, "an unavailable audio device does not make the launcher unusable: " .. tostring(launcher))
    Assert.isTrue(launcher.unavailable, "device failure publishes the explicit silent owner")
    Assert.deepEqual(sources, {}, "a failed first Source is not retained")
    Assert.equal(#files, 1, "source construction stops at the first device failure")
    Assert.equal(files[1].releases, 1, "the failed Source's FileData still releases")
    launcher:play("confirm")
    launcher:update(1 / 60)
    launcher:dispose()
  end)
end

function T.partial_audio_construction_releases_prior_sources_and_every_file_data()
  withAudioHost({ failPath = expectedPath("confirm") }, function(sources, files)
    local LauncherAudio = require("app.src.launcher.LauncherAudio")
    local launcher = LauncherAudio.new()
    Assert.isTrue(launcher.unavailable, "a partial device failure falls back to silent launcher audio")
    Assert.equal(#sources, 2, "only Sources completed before the failure were acquired")
    Assert.equal(#files, 3, "the failing cue's FileData was acquired before Source construction")
    for _, source in ipairs(sources) do
      Assert.equal(source.releases, 1, "partial construction releases each prior Source exactly once")
    end
    for _, fileData in ipairs(files) do
      Assert.equal(fileData.releases, 1, "partial construction releases every acquired FileData exactly once")
    end
    launcher:dispose()
    for _, source in ipairs(sources) do
      Assert.equal(source.releases, 1, "silent-owner disposal cannot release prior Sources twice")
    end
  end)
end

function T.missing_audio_device_releases_all_five_acquired_file_data()
  withAudioHost({ audioMissing = true }, function(sources, files)
    local LauncherAudio = require("app.src.launcher.LauncherAudio")
    local launcher = LauncherAudio.new()
    Assert.isTrue(launcher.unavailable, "a host without Source construction remains explicitly silent")
    Assert.deepEqual(sources, {})
    Assert.equal(#files, 5, "asset validation still requests every required cue")
    for _, fileData in ipairs(files) do
      Assert.equal(fileData.releases, 1, "silent audio releases each FileData without constructing a Source")
    end
    launcher:dispose()
  end)

  withAudioHost({ audioMissing = true, invalidPath = expectedPath("boot") }, function(_, files)
    local LauncherAudio = require("app.src.launcher.LauncherAudio")
    local ok, failure = pcall(LauncherAudio.new)
    Assert.isFalse(ok, "silent hosts still reject corrupt required assets")
    Assert.isTrue(tostring(failure):find("boot.ogg", 1, true) ~= nil)
    Assert.equal(files[1].releases, 1, "the corrupt FileData releases on the silent path")
  end)

  withAudioHost({ audioMissing = true, soundMissing = true }, function(_, files)
    local LauncherAudio = require("app.src.launcher.LauncherAudio")
    local launcher = LauncherAudio.new()
    Assert.isTrue(launcher.unavailable, "a host without audio decoding remains explicitly silent")
    Assert.equal(#files, 5, "asset presence is still checked without a decoder")
    for _, fileData in ipairs(files) do
      Assert.equal(fileData.releases, 1)
    end
    launcher:dispose()
  end)
end

return { tests = T }
