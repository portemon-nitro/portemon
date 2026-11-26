-- Launcher cue ownership at the native audio boundary. The fake mirrors the
-- LÖVE FileData/SoundData/Source overloads and records physical-output intent
-- without opening a device.

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
  local audio = originalAudio or {}
  local sound = originalSound or {}
  rawset(love, "audio", audio)
  rawset(love, "sound", sound)
  local originalModule = package.loaded["app.src.launcher.LauncherAudio"]
  package.loaded["app.src.launcher.LauncherAudio"] = nil
  local originalAssets = package.loaded["app.src.launcher.LauncherAssets"]
  local originalNewSource = audio.newSource
  local originalNewSoundData = sound.newSoundData
  local sources, files, decoded, sourceCalls = {}, {}, {}, {}
  sound.newSoundData = function(data)
    local path = data:getFilename()
    if path == options.invalidPath then
      error("synthetic audio decode failure", 0)
    end
    local value = { kind = "sound-data", path = path, releases = 0 }
    function value:release()
      self.releases = self.releases + 1
    end
    decoded[#decoded + 1] = value
    return value
  end
  package.loaded["app.src.launcher.LauncherAssets"] = {
    read = function(path)
      if path == options.missingPath then
        return nil
      end
      for _, cue in ipairs(CUES) do
        if path == expectedPath(cue) then
          local value = { kind = "file-data", path = path, releases = 0 }
          function value:getFilename()
            return self.path
          end
          function value:getSize()
            return 16
          end
          function value:getString()
            return "OGG-HOST-FIXTURE"
          end
          function value:release()
            self.releases = self.releases + 1
          end
          files[#files + 1] = value
          return value
        end
      end
      return nil
    end,
  }
  audio.newSource = function(...)
    local argc = select("#", ...)
    local data, sourceType = ...
    sourceCalls[#sourceCalls + 1] = { argc = argc, data = data, sourceType = sourceType }
    local path = data.kind == "sound-data" and data.path or data:getFilename()
    if path == options.failPath then
      error("synthetic audio device failure", 0)
    end
    local source = {
      data = data,
      inputKind = data.kind,
      path = path,
      playing = false,
      plays = 0,
      stops = 0,
      releases = 0,
      playingAtRelease = nil,
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
      self.playingAtRelease = self.playing
      self.playing = false
      self.releases = self.releases + 1
    end
    sources[#sources + 1] = source
    return source
  end
  if options.audioMissing then
    audio.newSource = nil
  end
  if options.soundMissing then
    rawset(love, "sound", nil)
  end
  local ok, failure = xpcall(function()
    fn({ sources = sources, files = files, decoded = decoded, sourceCalls = sourceCalls })
  end, debug.traceback)
  audio.newSource = originalNewSource
  sound.newSoundData = originalNewSoundData
  rawset(love, "audio", originalAudio)
  rawset(love, "sound", originalSound)
  package.loaded["app.src.launcher.LauncherAudio"] = originalModule
  package.loaded["app.src.launcher.LauncherAssets"] = originalAssets
  if not ok then
    error(failure, 0)
  end
end

function T.each_cue_decodes_once_and_creates_one_static_source_from_decoded_data()
  withAudioHost({}, function(host)
    Assert.equal(type(love.sound), "table", "the recording host installs a sound boundary")
    Assert.equal(type(love.sound.newSoundData), "function")
    local launcher = require("app.src.launcher.LauncherAudio").new()
    Assert.equal(#host.files, 5)
    Assert.equal(#host.decoded, 5, "each OGG is decoded exactly once")
    Assert.equal(#host.sources, 5)
    for index, cue in ipairs(CUES) do
      Assert.equal(host.decoded[index].path, expectedPath(cue))
      Assert.equal(host.sourceCalls[index].argc, 1, "the SoundData overload has no source-type argument")
      Assert.equal(host.sourceCalls[index].sourceType, nil)
      Assert.isTrue(host.sources[index].data == host.decoded[index], "Source borrows the decoded SoundData")
      Assert.equal(host.sources[index].inputKind, "sound-data")
      Assert.equal(host.files[index].releases, 1, "compressed FileData releases after Source construction")
      Assert.equal(host.decoded[index].releases, 1, "decoded SoundData releases after Source construction")
    end
    for _, cue in ipairs(CUES) do
      launcher:play(cue)
    end
    for _, source in ipairs(host.sources) do
      Assert.equal(source.plays, 1)
    end
    launcher:dispose()
    launcher:dispose()
    for _, source in ipairs(host.sources) do
      Assert.equal(source.releases, 1)
      Assert.isFalse(source.playingAtRelease, "active output stops before Source release")
    end
  end)
end

function T.short_cues_are_bounded_and_boot_fade_is_deterministic()
  withAudioHost({}, function(host)
    local launcher = require("app.src.launcher.LauncherAudio").new()
    for _ = 1, 20 do
      launcher:play("focus")
    end
    local playing = 0
    for _, source in ipairs(host.sources) do
      if source:isPlaying() then
        playing = playing + 1
      end
    end
    Assert.isTrue(playing <= 4)

    local boot = host.sources[1]
    launcher:play("boot")
    launcher:fadeBoot(0.08)
    launcher:update(0.04)
    Assert.isTrue(boot.volume < 1)
    launcher:update(0.04)
    Assert.isFalse(boot:isPlaying())

    launcher:play("boot")
    local plays = boot.plays
    launcher:fadeBoot(0)
    Assert.isFalse(boot:isPlaying(), "zero fade stops the boot tail immediately")
    Assert.equal(boot.plays, plays, "fade never restarts the cue")
    Assert.isNil(launcher.bootFade, "zero fade leaves no pending timer")
    launcher:play("boot")
    launcher:update(1)
    Assert.isTrue(boot:isPlaying(), "a stale completed fade cannot stop a restarted cue")
    launcher:dispose()
  end)
end

function T.missing_and_corrupt_required_cues_release_all_prior_intermediates()
  for _, case in ipairs({
    { options = { missingPath = expectedPath("confirm") }, label = "missing" },
    { options = { invalidPath = expectedPath("confirm") }, label = "corrupt" },
  }) do
    withAudioHost(case.options, function(host)
      local ok, failure = pcall(require("app.src.launcher.LauncherAudio").new)
      Assert.isFalse(ok, "a " .. case.label .. " required cue is an asset error")
      Assert.isTrue(tostring(failure):find("confirm.ogg", 1, true) ~= nil)
      for _, fileData in ipairs(host.files) do
        Assert.equal(fileData.releases, 1)
      end
      for _, value in ipairs(host.decoded) do
        Assert.equal(value.releases, 1)
      end
      for _, source in ipairs(host.sources) do
        Assert.equal(source.releases, 1)
      end
    end)
  end
end

function T.device_failure_releases_prior_sources_but_still_validates_every_asset()
  withAudioHost({ failPath = expectedPath("confirm") }, function(host)
    local launcher = require("app.src.launcher.LauncherAudio").new()
    Assert.isTrue(launcher.unavailable)
    Assert.equal(#host.files, 5, "silent validation continues through later cues")
    Assert.equal(#host.decoded, 5, "silent validation still decodes every required OGG")
    Assert.equal(#host.sources, 2, "only Sources completed before the device failure were acquired")
    for _, source in ipairs(host.sources) do
      Assert.equal(source.releases, 1)
    end
    for _, fileData in ipairs(host.files) do
      Assert.equal(fileData.releases, 1)
    end
    for _, value in ipairs(host.decoded) do
      Assert.equal(value.releases, 1)
    end
    launcher:play("boot")
    launcher:update(1 / 60)
    launcher:dispose()
  end)

  for _, options in ipairs({
    { failPath = expectedPath("boot"), missingPath = expectedPath("error") },
    { failPath = expectedPath("boot"), invalidPath = expectedPath("back") },
  }) do
    withAudioHost(options, function(host)
      local ok, failure = pcall(require("app.src.launcher.LauncherAudio").new)
      Assert.isFalse(ok, "device silence cannot hide a later missing or corrupt required asset")
      Assert.isTrue(tostring(failure):find(".ogg", 1, true) ~= nil)
      for _, fileData in ipairs(host.files) do
        Assert.equal(fileData.releases, 1)
      end
      for _, value in ipairs(host.decoded) do
        Assert.equal(value.releases, 1)
      end
      for _, source in ipairs(host.sources) do
        Assert.equal(source.releases, 1)
      end
    end)
  end
end

function T.unavailable_modules_keep_asset_validation_and_release_contracts()
  withAudioHost({ audioMissing = true }, function(host)
    local launcher = require("app.src.launcher.LauncherAudio").new()
    Assert.isTrue(launcher.unavailable)
    Assert.equal(#host.files, 5)
    Assert.equal(#host.decoded, 5)
    Assert.equal(#host.sources, 0)
    for _, fileData in ipairs(host.files) do
      Assert.equal(fileData.releases, 1)
    end
    for _, value in ipairs(host.decoded) do
      Assert.equal(value.releases, 1)
    end
    launcher:dispose()
  end)

  withAudioHost({ soundMissing = true }, function(host)
    local launcher = require("app.src.launcher.LauncherAudio").new()
    Assert.isFalse(launcher.unavailable, "native static FileData Sources remain supported without a decoder")
    Assert.equal(#host.decoded, 0)
    Assert.equal(#host.sources, 5)
    for _, call in ipairs(host.sourceCalls) do
      Assert.equal(call.argc, 2)
      Assert.equal(call.sourceType, "static")
      Assert.equal(call.data.kind, "file-data")
    end
    for _, fileData in ipairs(host.files) do
      Assert.equal(fileData.releases, 1)
    end
    launcher:dispose()
  end)

  withAudioHost({ audioMissing = true, soundMissing = true }, function(host)
    local launcher = require("app.src.launcher.LauncherAudio").new()
    Assert.isTrue(launcher.unavailable)
    Assert.equal(#host.files, 5)
    Assert.equal(#host.decoded, 0)
    Assert.equal(#host.sources, 0)
    for _, fileData in ipairs(host.files) do
      Assert.equal(fileData.releases, 1)
    end
    launcher:dispose()
  end)
end

return { tests = T }
