-- EvolutionScenePresenter host lane: composed from its ports alone, with no
-- battle screen behind it, it drives a non-battle (item-sourced,
-- non-cancelable) evolution from pending assets to its sealed
-- `evolution_complete` result.

local Assert = require("tests.support.Assert")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local ItemFixture = require("libs.items.tests.item_fixture")
local ManifestFixture = require("tests.support.BattlePresentationManifestFixture")
local MonCatalog = require("libs.mons.src.MonCatalog")
local MonStats = require("libs.mons.src.gen4.MonStats")

local EvolutionScenePresenter = require("game.hgss.src.battle.EvolutionScenePresenter")

local T = {}

---@return table catalog where CHIKORITA evolves into TOTODILE at level 16
local function evolutionCatalog()
  local root = CatalogFixture.buildAssetRoot()
  local species = root.species --[[@as table<string, table<string, unknown>>]]
  local forms = species.CHIKORITA.forms --[[@as table<integer, table<string, unknown>>]]
  forms[0].evolutions = { { method = "level", level = 16, target = "TOTODILE", form = 0 } }
  local targetForms = species.TOTODILE.forms --[[@as table<integer, table<string, unknown>>]]
  local learnset = targetForms[0].levelUpMoves --[[@as table<integer, table<string, unknown>>]]
  learnset[#learnset + 1] = { level = 16, move = "RAZOR_LEAF" }
  return MonCatalog.new(root, ItemFixture.makeCatalog())
end

---@param catalog table mon catalog
---@return table committed level-16 subject with full health
local function subject(catalog)
  local factory = CatalogFixture.makeFactory(0xE0010001, catalog)
  local mon = factory:createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA", level = 16 }))
  mon.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  mon.condition.currentHp = MonStats.derive(mon, catalog).maxHp
  return mon
end

-- Printer port: a message stays active for two steps and fires its
-- printer-callback controls once at the first step, like the timeline.
local function newPrinter()
  local printer = { latest = nil, remaining = 0, text = "", controls = {}, fired = false }
  function printer:announce(text, _, _, controls)
    assert(self.remaining == 0, "printer messages never overlap")
    self.latest = (self.latest or 0) + 1
    self.text = text
    self.controls = controls
    self.remaining = 2
    self.fired = false
    return self.latest
  end
  function printer:messageId()
    return self.latest
  end
  function printer:messageActive()
    return self.remaining > 0
  end
  function printer:message()
    return self.text
  end
  function printer:step(owner)
    if self.remaining == 0 then
      return
    end
    if not self.fired then
      self.fired = true
      for index, control in ipairs(self.controls) do
        if control.kind == "callback" then
          Assert.isTrue(owner:printerCallback(self.latest, control.callback, index), "start callbacks release at once")
        end
      end
    end
    self.remaining = self.remaining - 1
  end
  return printer
end

-- Audio port: every voice reports complete after two polls, or never
-- when `stuck` models an unfinished real-time voice.
local function newAudio(stuck)
  local audio = { started = {}, stopped = {} }
  local function start(kind)
    return function(self, name)
      local voice = { kind = kind, name = name, polls = 0 }
      self.started[#self.started + 1] = voice
      return voice
    end
  end
  audio.startMusic = start("music")
  audio.playEffect = start("effect")
  audio.playFanfare = start("fanfare")
  function audio:stopVoice(voice)
    self.stopped[#self.stopped + 1] = voice
  end
  function audio:voiceComplete(voice)
    voice.polls = voice.polls + 1
    return not stuck and voice.polls >= 2
  end
  return audio
end

-- Assets port: the late leaf is pending on the first poll; images exist
-- only once the leaf record was handed out. Portrait images additionally
-- miss `portraitMisses` lookups, like a page whose upload is in flight.
local function newAssets()
  local assets = { polls = 0, record = nil, selectors = {}, portraitMisses = 0, failure = nil }
  function assets:ensureEvolution()
    self.polls = self.polls + 1
    if self.polls > 1 and self.record == nil then
      self.record = ManifestFixture.evolutionRecord()
    end
    return self.record
  end
  function assets:drawable(key)
    if self.record == nil then
      return nil
    end
    if key:sub(1, 4) == "mon:" and self.portraitMisses > 0 then
      self.portraitMisses = self.portraitMisses - 1
      return nil
    end
    return { key = key }
  end
  function assets:addSelectors(selectors)
    for _, selector in ipairs(selectors) do
      self.selectors[#self.selectors + 1] = selector
    end
  end
  function assets:state()
    if self.failure ~= nil then
      return "failed"
    end
    return self.record ~= nil and "ready" or "pending"
  end
  function assets:error()
    return self.failure
  end
  return assets
end

---@param opts { speed: integer, stuckVoices: boolean, moves: table[]? }
---@return table rig presenter with its fake ports and recordings
local function compose(opts)
  local catalog = evolutionCatalog()
  local rig = {
    printer = newPrinter(),
    audio = newAudio(opts.stuckVoices),
    assets = newAssets(),
    poses = BattleScene.new(),
    textKeys = {},
    cries = {},
  }
  local evolving = subject(catalog)
  if opts.moves ~= nil then
    evolving.moves = opts.moves
  end
  rig.presenter = EvolutionScenePresenter.new({
    source = "field_item",
    subject = evolving,
    context = { trigger = { kind = "level" }, timeOfDay = "day", party = {}, inventory = {} },
    partySlot = 0,
    sceneId = "field-scene-1",
    identity = { launchId = "field", requestId = 1, epoch = 1, controller = "player" },
    monCatalog = catalog,
    splRandomState = { state = 12345 },
    speed = opts.speed,
    voiced = true,
    manifest = ManifestFixture.launchView(),
    text = function(key, _, controls)
      rig.textKeys[#rig.textKeys + 1] = key
      if #rig.textKeys == 1 then
        controls.controls[1] = { glyphIndex = 0, kind = "callback", callback = 4, wait = false }
      end
      return "text:" .. key
    end,
    printer = rig.printer,
    poses = rig.poses,
    audio = rig.audio,
    playCry = function(cue)
      rig.cries[#rig.cries + 1] = cue
      return rig.audio:playEffect("cry:" .. cue.species)
    end,
    assets = rig.assets,
  })
  return rig
end

function T.terminal_asset_preparation_failure_is_not_reported_as_pending()
  local rig = compose({ speed = 1, stuckVoices = false })
  Assert.isNil(rig.presenter:advance(), "the evolution leaf starts pending")
  Assert.isNil(rig.presenter:advance(), "a successful asset stage opens the child")
  rig.assets.failure = "audio-bank failed for evolution scene field-scene-1"
  local ok, failure = pcall(rig.presenter.advance, rig.presenter)
  Assert.isFalse(ok, "a terminal asset failure stops presenter advancement")
  Assert.isTrue(
    tostring(failure):find(rig.assets.failure, 1, true) ~= nil,
    "the presenter reports the holder's detailed failure"
  )
end

-- Steps one source tick the way a host does: printer, poses, fades, then
-- the scene itself.
---@return table<string, unknown>? result sealed scene result
local function tick(rig)
  rig.printer:step(rig.presenter)
  rig.poses:stepAnimationPictures()
  rig.presenter:stepTick()
  return rig.presenter:advance()
end

function T.item_sourced_scene_runs_to_evolution_complete_through_its_ports_alone()
  local rig = compose({ speed = 1, stuckVoices = false })
  local presenter = rig.presenter

  -- Edges before composition buffer for replay; other inputs fall through.
  Assert.isFalse(presenter:open(), "the pending leaf holds composition")
  Assert.isTrue(presenter:input({ type = "cancel" }), "the scene owns edges before composition")
  Assert.isFalse(presenter:input({ type = "text" }), "non-scene inputs fall through")
  Assert.equal(presenter:view().interactive, false, "the unopened scene projects a placeholder")

  local result = nil
  for _ = 1, 4000 do
    result = tick(rig)
    if result ~= nil then
      break
    end
    if presenter:view().interactive then
      Assert.equal(presenter:view().cancellable, false, "item-sourced scenes are never cancelable")
      Assert.equal(presenter:view().presentation.assetsReady, true, "the opened view reports ready assets")
    end
  end

  assert(result ~= nil, "the scene seals a result")
  Assert.equal(result.kind, "evolution_complete", "the buffered cancel never cancels an item-sourced scene")
  Assert.notNil(result.staged, "the completed scene stages its evolved mon")
  Assert.isTrue(
    #rig.textKeys > 0 and rig.textKeys[1] ~= "evolution/916",
    "item-sourced scenes skip the battle-only message"
  )
  Assert.deepEqual(
    { rig.cries[1].species, rig.cries[2].species },
    { "CHIKORITA", "TOTODILE" },
    "the scene cries the old then the new species"
  )
  Assert.isTrue(rig.cries[1].waitForVoice, "voiced scenes gate on their cry")
  Assert.equal(#rig.assets.selectors, 2, "both Pokepic portraits were demanded")
  local sawCallbackEffect = false
  for _, voice in ipairs(rig.audio.started) do
    sawCallbackEffect = sawCallbackEffect or voice.name == "SEQ_SE_DP_KON"
  end
  Assert.isTrue(sawCallbackEffect, "printer callbacks voice through the audio port")
  presenter:dispose()
end

-- Prepared portrait pages are not yet drawable images: the scene holds its
-- clock and reports unready assets until both Pokepics resolve, so the
-- opening beat never plays over a missing portrait.
function T.scene_holds_until_both_portraits_resolve()
  local rig = compose({ speed = 1, stuckVoices = false })
  rig.assets.portraitMisses = 40
  for _ = 1, 20 do
    Assert.isNil(tick(rig), "the scene seals nothing while a portrait is missing")
  end
  Assert.equal(#rig.cries, 0, "no cry plays over a missing portrait")
  Assert.equal(rig.presenter:view().presentation.assetsReady, false, "unresolved portraits keep assets unready")
  local result = nil
  for _ = 1, 4000 do
    result = tick(rig)
    if result ~= nil then
      break
    end
  end
  Assert.equal(rig.assets.portraitMisses, 0, "the scene kept asking until the portraits resolved")
  assert(result ~= nil, "the scene runs once its portraits resolve")
  Assert.equal(result.kind, "evolution_complete")
  Assert.equal(rig.cries[1].species, "CHIKORITA", "the opening cry plays after the portraits resolve")
  rig.presenter:dispose()
end

-- The full-set learn menu answers lower-screen touches through the source
-- half-open row rectangles only: a tap outside both rows does nothing,
-- and a tap inside the lower row selects it.
function T.learn_menu_touches_reach_the_source_rows()
  local fullSet = {}
  for _, move in ipairs({ "TACKLE", "GROWL", "SCRATCH", "LEER" }) do
    fullSet[#fullSet + 1] = { move = move, pp = 10, ppUps = 0 }
  end
  local rig = compose({ speed = 1, stuckVoices = false, moves = fullSet })
  local menu = nil
  for _ = 1, 4000 do
    Assert.isNil(tick(rig), "the full set pauses on its learn menu")
    local presentation = rig.presenter:view().presentation
    menu = presentation ~= nil and presentation.learnMenu or nil
    if menu ~= nil then
      break
    end
  end
  assert(menu ~= nil, "the full set opens the learn menu")
  Assert.isTrue(rig.presenter:input({ type = "pointer_down", pointerId = 1, x = 251, y = 120 }))
  tick(rig)
  local untouched = rig.presenter:view().presentation.learnMenu
  Assert.equal(untouched.focus, 0, "a tap right of the half-open rows selects nothing")
  Assert.isNil(untouched.selecting, "a missed tap arms nothing")
  rig.presenter:input({ type = "pointer_down", pointerId = 1, x = 128, y = 120 })
  local touched = rig.presenter:view().presentation.learnMenu
  Assert.equal(touched.focus, 1, "a tap inside the lower row focuses it")
  Assert.isTrue(touched.selecting, "a tap inside a row selects it")
  rig.presenter:dispose()
end

-- Unfinished real-time voices gate the scene at single rate only.
function T.unfinished_voices_hold_the_scene_at_single_rate_but_not_above()
  for _, case in ipairs({ { speed = 1, completes = false }, { speed = 4, completes = true } }) do
    local rig = compose({ speed = case.speed, stuckVoices = true })
    local result = nil
    for _ = 1, 3000 do
      result = tick(rig)
      if result ~= nil then
        break
      end
    end
    Assert.equal(result ~= nil, case.completes, "speed " .. case.speed .. " gates the scene on unfinished voices")
    rig.presenter:dispose()
  end
end

-- WAIT printer callbacks hold the message on unfinished callback voices at
-- single rate and release at once above it.
function T.wait_callbacks_follow_voice_completion_at_single_rate_only()
  for _, case in ipairs({ { speed = 1, stuckFirst = true }, { speed = 4, stuckFirst = false } }) do
    local rig = compose({ speed = case.speed, stuckVoices = true })
    local presenter = rig.presenter
    presenter._printerMessageId = 7
    presenter._printerVoices = { [1] = rig.audio:playEffect("SEQ_SE_DP_SELECT") }
    Assert.equal(
      presenter:printerCallback(7, 1, 1),
      not case.stuckFirst,
      "effect WAIT callbacks gate on the unfinished effect only at single rate"
    )
    presenter._printerVoices = { [1] = rig.audio:playFanfare("SEQ_ME_SHINKAOME") }
    Assert.equal(
      presenter:printerCallback(7, 2, 1),
      not case.stuckFirst,
      "fanfare WAIT callbacks gate on the playing jingle only at single rate"
    )
    presenter:dispose()
  end
end

return { tests = T }
