-- Unit coverage for the per-launch battle resource holder: validated
-- frame selection, truthful pending/ready/failed preparation, owned
-- handle tracking with exactly-once release, and delayed versus missing
-- images. The preparation double below stands in for the real asset
-- services with held keys, injected failures, and per-key release
-- counts.

local Assert = require("tests.support.Assert")
local BattlePresentationAssets = require("game.hgss.src.battle.BattlePresentationAssets")

local T = {}

---@param opts table? heldKeys, failPrepare, seedImages
---@return table preparation double owning only the handles it hands out
local function stubAssets(opts)
  opts = opts or {}
  local held = {}
  for _, key in ipairs(opts.heldKeys or {}) do
    held[key] = true
  end
  local assets = { hold = held, failPrepare = opts.failPrepare, images = opts.seedImages or {}, released = {} }
  function assets.prepare(_)
    if assets.failPrepare ~= nil then
      return nil, assets.failPrepare
    end
    return true
  end
  function assets.drawable(key)
    if assets.hold[key] then
      return nil
    end
    if assets.images[key] == nil then
      assets.images[key] = { handle = key }
    end
    return assets.images[key]
  end
  function assets.release(key)
    assets.released[key] = (assets.released[key] or 0) + 1
  end
  return assets
end

---@param overrides table? per-instance definition input under test driving
---@param assets table? preparation double under test driving
---@return table holder under test driving
local function holder(overrides, assets)
  return BattlePresentationAssets.new({
    assets = assets or stubAssets({}),
    launchId = "assets-probe",
    sceneKey = "general/plain/day",
    sceneImage = "scene:probe",
    frameKey = overrides and overrides.frameKey,
    frames = overrides and overrides.frames,
  })
end

-- The default frame and a declared custom frame both prepare; their
-- selected images stay drawable through the holder.
function T.known_frames_prepare()
  local known = holder({ frameKey = "custom-probe-frame", frames = { ["custom-probe-frame"] = {} } })
  known:update()
  Assert.equal(known:state(), "ready", "a declared custom frame prepares")
  Assert.notNil(known:drawable("scene:probe"), "the scene image stays drawable through the holder")
  local fallback = holder(nil)
  fallback:update()
  Assert.equal(fallback:state(), "ready", "the default frame prepares without declarations")
  Assert.equal(fallback:frameKey(), "default", "the default frame key is reported")
  known:dispose()
  fallback:dispose()
end

-- An unknown frame stops preparation with definition context instead of
-- substituting a different frame or reporting false success.
function T.unknown_frames_fail_explicitly()
  local assets = stubAssets({})
  local bad = holder({ frameKey = "no-such-frame" }, assets)
  bad:update()
  Assert.equal(bad:state(), "failed", "the unknown frame stops the holder")
  local err = bad:error()
  Assert.isTrue(type(err) == "string" and err ~= "", "the failure carries its context")
  Assert.isTrue(
    err:find("no%-such%-frame", 1) ~= nil and err:find("frame", 1) ~= nil,
    "the failure names its missing definition"
  )
  bad:dispose()
  bad:dispose()
end

-- A preparation failure reaches the failure context with no false
-- interaction.
function T.preparation_failure_surfaces()
  local bad = BattlePresentationAssets.new({
    assets = stubAssets({ failPrepare = "test-scene-missing" }),
    launchId = "assets-sad",
    sceneKey = "general/plain/day",
    sceneImage = "scene:sad",
  })
  bad:update()
  Assert.equal(bad:state(), "failed", "the preparation failure stops the holder")
  Assert.isTrue((bad:error() or ""):find("test%-scene%-missing", 1) ~= nil, "the service error reaches the context")
  bad:dispose()
end

-- A bare not-yet answer polls again without failing, while a nil answer
-- or any answer carrying a failure string fails closed with context.
function T.preparation_pending_and_typed_failures()
  local polls = 0
  local patient = { images = {}, released = {} }
  function patient.prepare(_)
    polls = polls + 1
    if polls == 1 then
      return false
    end
    return true
  end
  function patient.drawable(key)
    if patient.images[key] == nil then
      patient.images[key] = { handle = key }
    end
    return patient.images[key]
  end
  function patient.release(key)
    patient.released[key] = (patient.released[key] or 0) + 1
  end
  local waiting = BattlePresentationAssets.new({
    assets = patient,
    launchId = "assets-patient",
    sceneKey = "general/plain/day",
    sceneImage = "scene:patient",
  })
  waiting:update()
  Assert.equal(waiting:state(), "pending", "a bare not-yet answer polls again without failing")
  Assert.isNil(waiting:error(), "polling again carries no failure context")
  waiting:update()
  Assert.equal(waiting:state(), "ready", "the prepared demand completes once the service answers")
  waiting:dispose()

  local untyped = BattlePresentationAssets.new({
    assets = stubAssets({ failPrepare = "test-typed-nil" }),
    launchId = "assets-untyped",
    sceneKey = "general/plain/day",
    sceneImage = "scene:untyped",
  })
  untyped:update()
  Assert.equal(untyped:state(), "failed", "a nil answer with a message fails closed")
  Assert.isTrue(
    (untyped:error() or ""):find("test%-typed%-nil", 1) ~= nil,
    "the nil failure carries its context"
  )
  untyped:dispose()

  local reluctant = { images = {}, released = {} }
  function reluctant.prepare(_)
    return false, "test-typed-false"
  end
  function reluctant.drawable(key)
    if reluctant.images[key] == nil then
      reluctant.images[key] = { handle = key }
    end
    return reluctant.images[key]
  end
  function reluctant.release(key)
    reluctant.released[key] = (reluctant.released[key] or 0) + 1
  end
  local refused = BattlePresentationAssets.new({
    assets = reluctant,
    launchId = "assets-refused",
    sceneKey = "general/plain/day",
    sceneImage = "scene:refused",
  })
  refused:update()
  Assert.equal(refused:state(), "failed", "a not-yet answer carrying a failure string fails closed")
  Assert.isTrue(
    (refused:error() or ""):find("test%-typed%-false", 1) ~= nil,
    "the typed failure carries its context"
  )
  refused:dispose()
end

-- A held image reports pending instead of failing or skipping ahead;
-- releasing it completes preparation exactly.
function T.delayed_images_stay_pending()
  local assets = stubAssets({ heldKeys = { "scene:probe" } })
  local slow = holder(nil, assets)
  slow:update()
  Assert.equal(slow:state(), "pending", "the missing scene holds preparation without failing")
  for _ = 1, 10 do
    slow:update()
  end
  Assert.equal(slow:state(), "pending", "repeated polls never invent the missing image")
  assets.hold["scene:probe"] = nil
  slow:update()
  Assert.equal(slow:state(), "ready", "releasing the image completes preparation")
  slow:dispose()
end

-- Disposal releases each owned handle exactly once and never touches
-- unowned keys; borrowed doubles stay usable.
function T.disposal_releases_owned_handles_once()
  local MonCache = require("libs.assets.src.MonCache")
  local playerBack = "mon:" .. MonCache.portraitSelector("EEVEE", 0, "male", false, "back")
  local enemyFront = "mon:" .. MonCache.portraitSelector("RATTATA", 0, "male", false)
  local assets = stubAssets({})
  local owned = holder(nil, assets)
  owned:update()
  Assert.notNil(owned:drawable("scene:probe"), "the scene image is owned")
  Assert.notNil(owned:drawable(playerBack), "the player image is owned")
  owned:dispose()
  owned:dispose()
  Assert.equal(assets.released["scene:probe"], 1, "the scene handle releases once")
  Assert.equal(assets.released[playerBack], 1, "the player handle releases once")
  Assert.isNil(assets.released[enemyFront], "never-drawn keys never release")
end

-- A regrown demand keeps readiness on a bare not-yet answer, while nil
-- or a failure string fails closed with context.
function T.regrown_demand_prefetch_failures()
  local MonCache = require("libs.assets.src.MonCache")
  local foeSelector = MonCache.portraitSelector("RATTATA", 0, "male", false)
  local assets = stubAssets({})
  local waiting = holder(nil, assets)
  waiting:update()
  Assert.equal(waiting:state(), "ready", "the first demand prepares")
  function assets.prepare(_)
    return false
  end
  waiting:addSelectors({ foeSelector })
  Assert.equal(waiting:state(), "ready", "a bare not-yet regrow keeps readiness")
  Assert.isNil(waiting:error(), "the kept readiness carries no failure context")
  waiting:dispose()

  local nilAssets = stubAssets({})
  local nilled = holder(nil, nilAssets)
  nilled:update()
  function nilAssets.prepare(_)
    return nil, "test-regrow-nil"
  end
  nilled:addSelectors({ foeSelector })
  Assert.equal(nilled:state(), "failed", "a nil regrow answer fails closed")
  Assert.isTrue(
    (nilled:error() or ""):find("test%-regrow%-nil", 1) ~= nil,
    "the nil regrow failure carries its context"
  )
  nilled:dispose()

  local typedAssets = stubAssets({})
  local refused = holder(nil, typedAssets)
  refused:update()
  function typedAssets.prepare(_)
    return false, "test-regrow-typed"
  end
  refused:addSelectors({ foeSelector })
  Assert.equal(refused:state(), "failed", "a regrow answer carrying a failure string fails closed")
  Assert.isTrue(
    (refused:error() or ""):find("test%-regrow%-typed", 1) ~= nil,
    "the typed regrow failure carries its context"
  )
  refused:dispose()
end

-- A switch and a foe replacement rebind the exact image identity: the
-- screen demands canonical selectors for the visible own roster and
-- only the revealed foe, the cue clock asks for "mon:" plus the exact
-- incoming selector at its reveal, generic side keys are never
-- requested, and the unrevealed replacement stays undemanded until it
-- actually arrives.
function T.switch_and_foe_reveal_rebind_the_exact_image_key()
  local MonCache = require("libs.assets.src.MonCache")
  local BattleScreenState = require("game.hgss.src.battle.BattleScreenState")
  local ScreenTopology = require("libs.ui.src.ScreenTopology")
  local leadBack = MonCache.portraitSelector("EEVEE", 0, "male", false, "back")
  local reserveBack = MonCache.portraitSelector("TOTODILE", 0, "female", false, "back")
  local foeFront = MonCache.portraitSelector("RATTATA", 0, "male", false)
  local reliefFront = MonCache.portraitSelector("PIDGEY", 0, "male", false)
  local TICK = 1 / 60
  local measurement = {
    width = 256,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" },
      "portrait-rebind:dual"
    ),
    pixelRatio = 1,
    signature = "portrait-rebind:dual",
  }
  local text = {}
  function text.measure(content)
    return { width = 8 * #tostring(content), height = 16 }
  end
  function text.drawText(_) end
  local windows = {}
  function windows.drawWindow(_, _, _) end
  local audio = {}
  function audio.play(_)
    return true
  end
  local prepared, drawnKeys = {}, {}
  local images = {}
  local assets = {}
  function assets.prepare(demand)
    prepared[#prepared + 1] = demand
    return true
  end
  function assets.drawable(key)
    drawnKeys[#drawnKeys + 1] = key
    if images[key] == nil then
      images[key] = { handle = key }
    end
    return images[key]
  end
  function assets.release(_) end
  local launchId = "launch-portrait-rebind"
  local screen = BattleScreenState.new({
    launchId = launchId,
    manifest = {
      schema = "test",
      version = { id = "t", language = "english" },
      verified = false,
      scenes = { { key = "general/plain/day" } },
    },
    model = {},
    submit = function(_)
      return true
    end,
    measureDisplay = function()
      return measurement
    end,
    assets = assets,
    text = text,
    windows = windows,
    audio = audio,
  })
  local function battlerRecord(combatant, side, active, species, name, portrait)
    return {
      combatant = combatant,
      participant = combatant,
      side = side,
      controller = side == 1 and "player" or "wild",
      active = active,
      hp = 20,
      maxHp = 20,
      species = species,
      form = 0,
      name = name,
      level = 9,
      selector = side == 1 and "back" or "front",
      portraitSelector = portrait,
      moves = {},
      experience = 100,
    }
  end
  local port = screen:presentationPort()
  port.enter({ launchId = launchId, kind = "wild" })
  local function pagesSoFar()
    local pages = {}
    for _, demand in ipairs(prepared) do
      for _, page in ipairs(demand.pages or {}) do
        pages[#pages + 1] = page
      end
    end
    return pages
  end
  local function hasPage(want)
    for _, page in ipairs(pagesSoFar()) do
      if page == want then
        return true
      end
    end
    return false
  end
  local function hasShorthand()
    for _, page in ipairs(pagesSoFar()) do
      if tostring(page):match("^[^/]+/%d+/[a-z]+$") ~= nil then
        return true
      end
    end
    return false
  end
  local function drewKey(want)
    for _, key in ipairs(drawnKeys) do
      if key == want then
        return true
      end
    end
    return false
  end
  local function pump(ticks)
    for _ = 1, ticks do
      screen:updateFixed(TICK)
    end
    local status = screen:status()
    if status.mode == "failed" then
      error("the portrait screen failed: " .. tostring(status.error), 0)
    end
  end
  local function openingAfter()
    return {
      own = {
        battlerRecord(1, 1, true, "EEVEE", "LEADA", leadBack),
        battlerRecord(2, 1, false, "TOTODILE", "RESERVE", reserveBack),
      },
      foes = { battlerRecord(3, 2, true, "RATTATA", "FOEX", foeFront) },
    }
  end
  port.present({ launchId = launchId, packetId = 1, events = {}, before = openingAfter(), after = openingAfter() })
  pump(400)
  Assert.isTrue(hasPage(leadBack), "the opening demands the exact active lead back selector")
  Assert.isTrue(hasPage(reserveBack), "the opening prefetches the disclosed reserve back selector")
  Assert.isTrue(hasPage(foeFront), "the opening demands the exact revealed foe selector")
  Assert.isFalse(hasShorthand(), "no demand falls back to a shorthand species/form/facing key")
  Assert.isTrue(drewKey("mon:" .. leadBack), "the first draw asks for the exact lead image key")
  Assert.isFalse(drewKey("mon:player:back"), "no frame aliases the lead through a generic side key")
  Assert.isFalse(drewKey("mon:enemy:front"), "no frame aliases the foe through a generic side key")
  local switchedAfter = {
    own = {
      battlerRecord(1, 1, false, "EEVEE", "LEADA", leadBack),
      battlerRecord(2, 1, true, "TOTODILE", "RESERVE", reserveBack),
    },
    foes = { battlerRecord(3, 2, true, "RATTATA", "FOEX", foeFront) },
  }
  port.present({
    launchId = launchId,
    packetId = 2,
    events = {
      { sequence = 1, kind = "switch", cause = { key = "TACKLE" }, audience = "public", payload = { from = 1, to = 2 } },
    },
    before = openingAfter(),
    after = switchedAfter,
  })
  pump(600)
  Assert.isTrue(
    drewKey("mon:" .. reserveBack),
    "the switch reveal asks for the exact incoming reserve image key"
  )
  local reliefAfter = {
    own = {
      battlerRecord(1, 1, false, "EEVEE", "LEADA", leadBack),
      battlerRecord(2, 1, true, "TOTODILE", "RESERVE", reserveBack),
    },
    foes = { battlerRecord(4, 2, true, "PIDGEY", "RELIEF", reliefFront) },
  }
  Assert.isFalse(hasPage(reliefFront), "the unrevealed foe reserve stays undemanded before it arrives")
  port.present({
    launchId = launchId,
    packetId = 3,
    events = {
      { sequence = 1, kind = "switch", cause = { key = "TACKLE" }, audience = "public", payload = { from = 3, to = 4 } },
    },
    before = switchedAfter,
    after = reliefAfter,
  })
  pump(600)
  Assert.isTrue(hasPage(reliefFront), "the foe replacement demands its exact revealed selector")
  Assert.isTrue(
    drewKey("mon:" .. reliefFront),
    "the foe reveal asks for the exact incoming foe image key"
  )
  screen:dispose()
end

-- Genderless and alternate forms resolve from the declared manifest
-- variant, never from a guessed male/plain tuple: source genders use
-- the shared male/female vocabulary, the actual shininess is preserved
-- with facing, and two same-species members with differing gender and
-- shininess never alias to one selector.
function T.genderless_and_shiny_forms_resolve_from_the_declared_variant()
  local MonCache = require("libs.assets.src.MonCache")
  local Model = require("game.hgss.src.battle.BattlePresentationModel")
  local Personality = require("libs.mons.src.gen4.Personality")
  local trainerId = 1001
  local function findPersonality(wantFemale, wantShiny)
    for candidate = 0, 200000 do
      local gender = Personality.gender(127, candidate)
      local shiny = Personality.shiny(trainerId, candidate)
      if (wantFemale and gender == "female" or not wantFemale and gender == "male") and shiny == wantShiny then
        return candidate
      end
    end
    error("no staged personality answers the wanted gender and finish", 0)
  end
  local femalePlain = findPersonality(true, false)
  local maleShiny = findPersonality(false, true)
  local genderlessShiny = nil
  for candidate = 0, 200000 do
    if Personality.shiny(trainerId, candidate) then
      genderlessShiny = candidate
      break
    end
  end
  Assert.notNil(genderlessShiny, "the probe finds a shiny personality for the genderless form")
  local catalog = {}
  function catalog:species(key)
    if key == "CHIKORITA" then
      return { name = "CHIKORITA", genderRatio = 127 }
    end
    if key == "MAGNEMITE" then
      return { name = "MAGNEMITE", genderRatio = 255 }
    end
    error("unknown staged species " .. tostring(key), 0)
  end
  function catalog:form(key, form)
    if key == "MAGNEMITE" and form == 1 then
      return { portrait = "MAGNEMITE/f1/female/plain" }
    end
    if key == "CHIKORITA" and form == 0 then
      return { portrait = "CHIKORITA/f0/male/plain" }
    end
    error("unknown staged form " .. tostring(key) .. "/" .. tostring(form), 0)
  end
  local function combatant(id, participant, active, mon)
    return {
      mon = mon,
      hp = 20,
      maxHp = 20,
      participant = participant,
      active = active,
    }
  end
  local snapshot = {
    round = 1,
    status = "running",
    combatants = {
      [1] = combatant(1, 1, { position = 0, activation = 1 }, {
        species = "CHIKORITA",
        form = 0,
        personality = femalePlain,
        origin = { trainerId = trainerId },
        level = 5,
        nickname = "LEADA",
      }),
      [2] = combatant(2, 1, nil, {
        species = "CHIKORITA",
        form = 0,
        personality = maleShiny,
        origin = { trainerId = trainerId },
        level = 5,
        nickname = "LEADB",
      }),
      [3] = combatant(3, 2, { position = 2, activation = 2 }, {
        species = "MAGNEMITE",
        form = 1,
        personality = genderlessShiny,
        origin = { trainerId = trainerId },
        level = 5,
        nickname = "FOE",
      }),
    },
    combatantOrder = { 1, 2, 3 },
    participants = {
      [1] = { side = 1, controller = "player" },
      [2] = { side = 2, controller = "wild" },
    },
  }
  local view = Model.view(snapshot, nil, { catalog = catalog })
  Assert.equal(#view.own, 2, "both disclosed own members project")
  Assert.equal(#view.foes, 1, "the revealed foe projects")
  local first, second = view.own[1], view.own[2]
  Assert.equal(first.gender, "female", "source genders use the shared male/female vocabulary")
  Assert.equal(
    first.portraitSelector,
    MonCache.portraitSelector("CHIKORITA", 0, "female", Personality.shiny(trainerId, femalePlain), "back"),
    "the lead keeps its exact gender, finish, and back facing"
  )
  Assert.equal(second.gender, "male", "the reserve keeps its own source gender")
  Assert.isTrue(
    second.portraitSelector ~= first.portraitSelector,
    "same-species members with differing gender and finish never alias"
  )
  Assert.equal(
    second.portraitSelector,
    MonCache.portraitSelector("CHIKORITA", 0, "male", Personality.shiny(trainerId, maleShiny), "back"),
    "the reserve keeps its exact gender, finish, and back facing"
  )
  local foe = view.foes[1]
  Assert.equal(foe.gender, "genderless", "genderless members keep their genderless identity")
  Assert.equal(foe.form, 1, "alternate form identity is preserved")
  Assert.equal(
    foe.portraitSelector,
    MonCache.portraitSelector("MAGNEMITE", 1, "female", Personality.shiny(trainerId, genderlessShiny --[[@as integer]]), "front"),
    "genderless forms resolve the declared variant with the actual finish and facing"
  )
end

return { tests = T }
