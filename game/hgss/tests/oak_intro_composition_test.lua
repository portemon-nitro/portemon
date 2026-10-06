-- Production Oak composition tests cover generated semantic inputs and the
-- host-owned randomness boundary without embedding generated dialogue.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldDialogueController = require("libs.hgss.src.ui.FieldDialogueController")
local FieldDialogueRenderer = require("libs.hgss.src.ui.FieldDialogueRenderer")
local FieldFontLoader = require("libs.hgss.src.ui.FieldFontLoader")
local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local GameAudio = require("game.hgss.src.audio.GameAudio")
local OakIntroComposition = require("game.hgss.src.newgame.OakIntroComposition")
local OakIntroController = require("game.hgss.src.newgame.OakIntroController")
local OakIntroMessages = require("game.hgss.src.newgame.OakIntroMessages")
local OakIntroState = require("game.hgss.src.newgame.OakIntroState")
local IntroAssetCache = require("libs.assets.src.newgame.IntroAssetCache")

local T = { tests = {} }

function T.tests.message_ids_have_one_semantic_mapping()
  local messages = OakIntroComposition.messageKeys({
    [1] = { text = "morning" },
    [2] = { text = "day" },
    [3] = { text = "evening" },
    [4] = { text = "night" },
    [5] = { text = "midnight" },
    [6] = { text = "welcome" },
    [34] = { text = "inhabited" },
    [35] = { text = "alongside" },
    [36] = { text = "yourself" },
    [37] = { text = "gender" },
    [38] = { text = "male" },
    [39] = { text = "female" },
    [40] = { text = "name" },
    [41] = { text = "male-name" },
    [42] = { text = "female-name" },
    [43] = { text = "final" },
  })

  Assert.equal(messages["greeting.morning"].text, "morning")
  Assert.equal(messages["greeting.day"].text, "day")
  Assert.equal(messages["greeting.evening"].text, "evening")
  Assert.equal(messages["greeting.night"].text, "night")
  Assert.equal(messages["greeting.midnight"].text, "midnight")
  Assert.equal(messages["oak.welcome"].text, "welcome")
  Assert.equal(messages["oak.world_inhabited"].text, "inhabited")
  Assert.equal(messages["oak.live_alongside"].text, "alongside")
  Assert.equal(messages["oak.tell_about_yourself"].text, "yourself")
  Assert.equal(messages["profile.gender_question"].text, "gender")
  Assert.equal(messages["profile.gender_confirm.male"].text, "male")
  Assert.equal(messages["profile.gender_confirm.female"].text, "female")
  Assert.equal(messages["profile.name_prompt"].text, "name")
  Assert.equal(messages["profile.name_confirm.male"].text, "male-name")
  Assert.equal(messages["profile.name_confirm.female"].text, "female-name")
  Assert.equal(messages["profile.final"].text, "final")
end

function T.tests.prepared_entry_collaborator_is_validated_before_cache_reads()
  local ok, err = pcall(OakIntroComposition.compose, {
    candidate = {},
    versionId = "heartgold",
    preparedEntry = { poll = function() end },
  })
  Assert.isFalse(ok, "a prepared entry without dispose fails composition")
  Assert.isTrue(string.find(tostring(err), "poll and dispose", 1, true) ~= nil)
  local okState, errState = pcall(OakIntroComposition.compose, {
    candidate = {},
    versionId = "heartgold",
    preparedEntry = "not-a-collaborator",
  })
  Assert.isFalse(okState, "a non-table prepared entry fails composition")
  Assert.isTrue(string.find(tostring(errState), "poll and dispose", 1, true) ~= nil)
end

function T.tests.composition_trusts_published_intro_manifest_without_revalidating()
  local introCache = IntroAssetCache
  local fieldUiCache = require("libs.assets.src.field.FieldUiAssetCache")
  local originalValidate = introCache.validateManifest
  local calls = 0
  rawset(introCache, "validateManifest", function()
    calls = calls + 1
    error("published intro manifests must not be revalidated at composition", 0)
  end)
  local originalForVersion = CacheFs.forVersion
  local originalFontLoad = FieldFontLoader.load
  local originalProviderNew = FieldMessageProvider.new
  local originalAudioCompose = GameAudio.compose
  local originalTextNew = FieldTextRenderer.new
  local originalDialogueRendererNew = FieldDialogueRenderer.new
  local originalDialogueControllerNew = FieldDialogueController.new
  local originalControllerNew = OakIntroController.new
  local originalMessagesNew = OakIntroMessages.new
  local originalStateNew = OakIntroState.new
  local introManifest = { schemaVersion = introCache.SCHEMA_VERSION, variant = "heartgold" }
  local fakeCache = {
    loadLua = function(_, path)
      if path == introCache.manifestPath() then
        return introManifest
      end
      if path == fieldUiCache.manifestPath() then
        return {
          schema = fieldUiCache.SCHEMA,
          dialogueFrames = { count = 0, continueCursor = { placement = {} } },
        }
      end
      error("unexpected cache path " .. path)
    end,
  }
  rawset(CacheFs, "forVersion", function()
    return fakeCache
  end)
  rawset(FieldFontLoader, "load", function()
    return { charmap = {} }
  end)
  rawset(FieldMessageProvider, "new", function()
    return {
      acquireBank = function()
        return true
      end,
      get = function()
        return {}
      end,
      releaseBank = function() end,
    }
  end)
  rawset(GameAudio, "compose", function()
    return { sound = {}, sink = { release = function() end } }
  end)
  rawset(FieldTextRenderer, "new", function()
    return {}
  end)
  rawset(FieldDialogueRenderer, "new", function()
    return {}
  end)
  rawset(FieldDialogueController, "new", function()
    return {}
  end)
  rawset(OakIntroController, "new", function()
    return {}
  end)
  rawset(OakIntroMessages, "new", function()
    return {
      format = function()
        return {}
      end,
    }
  end)
  local composed
  rawset(OakIntroState, "new", function(options)
    composed = options
    return { trusted = true }
  end)

  local ok, state = pcall(OakIntroComposition.compose, {
    candidate = {},
    versionId = "heartgold",
    clock = {},
    randomU32 = function()
      return 1
    end,
    imageLoader = function()
      return {}
    end,
  })

  rawset(CacheFs, "forVersion", originalForVersion)
  rawset(introCache, "validateManifest", originalValidate)
  rawset(FieldFontLoader, "load", originalFontLoad)
  rawset(FieldMessageProvider, "new", originalProviderNew)
  rawset(GameAudio, "compose", originalAudioCompose)
  rawset(FieldTextRenderer, "new", originalTextNew)
  rawset(FieldDialogueRenderer, "new", originalDialogueRendererNew)
  rawset(FieldDialogueController, "new", originalDialogueControllerNew)
  rawset(OakIntroController, "new", originalControllerNew)
  rawset(OakIntroMessages, "new", originalMessagesNew)
  rawset(OakIntroState, "new", originalStateNew)

  Assert.isTrue(ok, "a published intro manifest composes without validator proof: " .. tostring(state))
  Assert.equal(calls, 0, "the comprehensive intro validator must not run during trusted composition")
  Assert.equal(state.trusted, true)
  Assert.equal(composed.manifest, introManifest, "composition retains the published intro manifest")
end

function T.tests.random_u32_provider_returns_nonconstant_uint32_values()
  local draws = { 0x1234, 0x5678 }
  local random = OakIntroComposition.randomU32({
    random = function()
      return table.remove(draws, 1)
    end,
  })
  local value = random()
  Assert.equal(value, 0x12345678)
  Assert.isTrue(value >= 0 and value <= 0xFFFFFFFF)
end

function T.tests.composition_releases_font_zero_when_font_four_acquisition_fails()
  local modules = {
    cache = CacheFs.forVersion,
    fontLoad = FieldFontLoader.load,
    providerNew = FieldMessageProvider.new,
    audioCompose = GameAudio.compose,
    textNew = FieldTextRenderer.new,
    dialogueRendererNew = FieldDialogueRenderer.new,
    dialogueControllerNew = FieldDialogueController.new,
    controllerNew = OakIntroController.new,
    messagesNew = OakIntroMessages.new,
  }
  local calls = {}
  local fieldUiCache = require("libs.assets.src.field.FieldUiAssetCache")
  local fontZero = { releases = 0 }
  function fontZero:release()
    self.releases = self.releases + 1
  end
  local fakeCache = {
    loadLua = function(_, path)
      if path == IntroAssetCache.manifestPath() then
        return { schemaVersion = IntroAssetCache.SCHEMA_VERSION, variant = "heartgold" }
      end
      if path == fieldUiCache.manifestPath() then
        return {
          schema = fieldUiCache.SCHEMA,
          dialogueFrames = { count = 0, continueCursor = { placement = {} } },
        }
      end
      error("unexpected cache path " .. path)
    end,
  }
  local provider = {
    acquireBank = function()
      return true
    end,
    get = function()
      return {}
    end,
    releaseBank = function() end,
  }
  local sink = { releases = 0 }
  function sink:release()
    self.releases = self.releases + 1
  end

  rawset(CacheFs, "forVersion", function()
    return fakeCache
  end)
  rawset(FieldFontLoader, "load", function()
    return { charmap = {}, fontId = 0 }
  end)
  rawset(FieldMessageProvider, "new", function()
    return provider
  end)
  rawset(GameAudio, "compose", function()
    return { sound = {}, sink = sink }
  end)
  rawset(FieldTextRenderer, "new", function(options)
    calls[#calls + 1] = options.fontId or 0
    if options.fontId == 4 then
      error("font 4 construction failed")
    end
    return fontZero
  end)
  rawset(OakIntroMessages, "new", function()
    return {}
  end)

  local ok, failure = pcall(function()
    OakIntroComposition.compose({ candidate = {}, versionId = "heartgold" })
  end)

  rawset(CacheFs, "forVersion", modules.cache)
  rawset(FieldFontLoader, "load", modules.fontLoad)
  rawset(FieldMessageProvider, "new", modules.providerNew)
  rawset(GameAudio, "compose", modules.audioCompose)
  rawset(FieldTextRenderer, "new", modules.textNew)
  rawset(FieldDialogueRenderer, "new", modules.dialogueRendererNew)
  rawset(FieldDialogueController, "new", modules.dialogueControllerNew)
  rawset(OakIntroController, "new", modules.controllerNew)
  rawset(OakIntroMessages, "new", modules.messagesNew)

  Assert.isFalse(ok)
  Assert.isTrue(tostring(failure):find("font 4 construction failed", 1, true) ~= nil)
  Assert.deepEqual(calls, { 0, 4 })
  Assert.equal(fontZero.releases, 1, "font 0 is released after font 4 construction fails")
  Assert.equal(sink.releases, 1, "audio is released after partial Oak composition failure")
end

return T
