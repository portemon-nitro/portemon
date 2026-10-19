-- Unit coverage for the per-launch battle resource holder: validated
-- frame selection, truthful pending/ready/failed preparation, owned
-- handle tracking with exactly-once release, and delayed versus missing
-- images. The preparation double below stands in for the real asset
-- services with held keys, injected failures, and per-key release
-- counts.

local Assert = require("tests.support.Assert")
local StubLease = require("tests.support.StubLease")
local BattlePresentationAssets = require("game.hgss.src.battle.BattlePresentationAssets")
local BattlePresentationManifestFixture = require("tests.support.BattlePresentationManifestFixture")

local T = {}
local SHADOW_REGIONS = BattlePresentationManifestFixture.manifest().pictures.shadow.regions

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
      assets.images[key] = StubLease.new(key)
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
    shadowRegions = SHADOW_REGIONS,
  })
end

function T.shadow_size_selects_the_published_source_uv_rectangle()
  local assets = holder()
  Assert.deepEqual(assets:shadowRegion(0), SHADOW_REGIONS[1], "small shadow uses the first staged source rectangle")
  Assert.deepEqual(assets:shadowRegion(1), SHADOW_REGIONS[2], "medium shadow preserves the source alias rectangle")
  Assert.deepEqual(assets:shadowRegion(2), SHADOW_REGIONS[3], "large shadow uses the next source rectangle")
  Assert.deepEqual(assets:shadowRegion(3), SHADOW_REGIONS[4], "extra-large shadow uses the final source rectangle")
  local ok = pcall(assets.shadowRegion, assets, 4)
  Assert.isFalse(ok, "unknown shadow sizes have no guessed texture region")
  assets:dispose()
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
    shadowRegions = SHADOW_REGIONS,
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
      patient.images[key] = StubLease.new(key)
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
    shadowRegions = SHADOW_REGIONS,
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
    shadowRegions = SHADOW_REGIONS,
  })
  untyped:update()
  Assert.equal(untyped:state(), "failed", "a nil answer with a message fails closed")
  Assert.isTrue((untyped:error() or ""):find("test%-typed%-nil", 1) ~= nil, "the nil failure carries its context")
  untyped:dispose()

  local reluctant = { images = {}, released = {} }
  function reluctant.prepare(_)
    return false, "test-typed-false"
  end
  function reluctant.drawable(key)
    if reluctant.images[key] == nil then
      reluctant.images[key] = StubLease.new(key)
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
    shadowRegions = SHADOW_REGIONS,
  })
  refused:update()
  Assert.equal(refused:state(), "failed", "a not-yet answer carrying a failure string fails closed")
  Assert.isTrue((refused:error() or ""):find("test%-typed%-false", 1) ~= nil, "the typed failure carries its context")
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

-- A regrown demand reopens pending until the enlarged exact demand
-- settles on a later update: a bare not-yet answer waits without
-- failing, while nil or a failure string fails closed with context.
-- Leased handles stay owned through the wait instead of releasing.
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
  Assert.equal(waiting:state(), "pending", "a bare not-yet regrow waits instead of keeping readiness")
  Assert.isNil(waiting:error(), "the wait carries no failure context")
  waiting:update()
  Assert.equal(waiting:state(), "pending", "the unready regrow keeps waiting across polls")
  function assets.prepare(_)
    return true
  end
  waiting:update()
  Assert.equal(waiting:state(), "ready", "the settled regrow prepares with its grown demand")
  waiting:dispose()

  local nilAssets = stubAssets({})
  local nilled = holder(nil, nilAssets)
  nilled:update()
  function nilAssets.prepare(_)
    return nil, "test-regrow-nil"
  end
  nilled:addSelectors({ foeSelector })
  Assert.equal(nilled:state(), "pending", "the doomed regrow waits for its next update")
  nilled:update()
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
  Assert.equal(refused:state(), "pending", "the refused regrow waits for its next update")
  refused:update()
  Assert.equal(refused:state(), "failed", "a regrow answer carrying a failure string fails closed")
  Assert.isTrue(
    (refused:error() or ""):find("test%-regrow%-typed", 1) ~= nil,
    "the typed regrow failure carries its context"
  )
  refused:dispose()
end

-- A switch and a foe replacement rebind the exact image identity: the
-- screen demands canonical selectors for the active own battler and
-- only the revealed foe, the cue clock asks for "mon:" plus the exact
-- incoming selector at its reveal, generic side keys are never
-- requested, and the benched reserve stays undemanded until its switch
-- packet makes it active.
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
      images[key] = StubLease.new(key)
    end
    local stored = images[key]
    if key:sub(1, 4) == "mon:" then
      return { lease = stored, quad = { handle = "quad:" .. key } }
    end
    return stored
  end
  function assets.release(_) end
  local launchId = "launch-portrait-rebind"
  local screen = BattleScreenState.new({
    launchId = launchId,
    manifest = BattlePresentationManifestFixture.manifest(),
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
  Assert.isFalse(hasPage(reserveBack), "the benched reserve stays undemanded before its switch packet makes it active")
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
      {
        sequence = 1,
        kind = "switch",
        cause = { key = "TACKLE" },
        audience = "public",
        payload = { from = 1, to = 2 },
      },
    },
    before = openingAfter(),
    after = switchedAfter,
  })
  pump(600)
  Assert.isTrue(hasPage(reserveBack), "the switch demands the exact incoming reserve selector")
  Assert.isTrue(drewKey("mon:" .. reserveBack), "the switch reveal asks for the exact incoming reserve image key")
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
      {
        sequence = 2,
        kind = "switch",
        cause = { key = "TACKLE" },
        audience = "public",
        payload = { from = 3, to = 4 },
      },
    },
    before = switchedAfter,
    after = reliefAfter,
  })
  pump(600)
  Assert.isTrue(hasPage(reliefFront), "the foe replacement demands its exact revealed selector")
  Assert.isTrue(drewKey("mon:" .. reliefFront), "the foe reveal asks for the exact incoming foe image key")
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
    MonCache.portraitSelector(
      "MAGNEMITE",
      1,
      "female",
      Personality.shiny(trainerId, genderlessShiny --[[@as integer]]),
      "front"
    ),
    "genderless forms resolve the declared variant with the actual finish and facing"
  )
end

-- An incoming portrait whose bytes fail upload fails the holder with the
-- exact incoming key: no stale image stands in, the failed key is never
-- retried, and earlier handles still release exactly once.
function T.incoming_portrait_upload_failure_names_its_exact_key()
  local MonCache = require("libs.assets.src.MonCache")
  local incomingKey = "mon:" .. MonCache.portraitSelector("EEVEE", 0, "male", false, "front")
  local attempts = 0
  local released = {}
  local images = {}
  local services = {}
  function services.prepare(_)
    return true
  end
  function services.drawable(key)
    if key == incomingKey then
      attempts = attempts + 1
      return nil, "battle image " .. key .. " upload failed: probe-decode-boom"
    end
    if images[key] == nil then
      images[key] = StubLease.new(key)
    end
    return images[key]
  end
  function services.release(key)
    released[key] = (released[key] or 0) + 1
  end
  local owned = holder(nil, services)
  owned:update()
  Assert.equal(owned:state(), "ready", "the opening scene prepares before the switch arrives")
  local handle, failure = owned:drawable(incomingKey)
  Assert.isNil(handle, "the failed portrait hands out no image")
  Assert.isTrue(type(failure) == "string" and failure ~= "", "the failed portrait names its reason")
  Assert.isTrue(
    (failure --[[@as string]]):find(incomingKey, 1, true) ~= nil,
    "the failure names the exact incoming image key"
  )
  Assert.equal(owned:state(), "failed", "the cue-time portrait failure stops the holder")
  Assert.isTrue(
    type(owned:error()) == "string" and (owned:error() --[[@as string]]):find(incomingKey, 1, true) ~= nil,
    "the latched error keeps the exact incoming key"
  )
  owned:update()
  local handleAgain, failureAgain = owned:drawable(incomingKey)
  Assert.isNil(handleAgain, "the failed portrait stays failed without a substitute")
  Assert.equal(failureAgain, failure, "the latched failure replays identically")
  Assert.equal(attempts, 1, "the failed upload is attempted once, never retried per tick")
  owned:dispose()
  owned:dispose()
  Assert.equal(released["scene:probe"], 1, "the scene handle releases once")
  Assert.isNil(released[incomingKey], "the never-uploaded portrait never releases")
end

-- A genuinely pending image that arrives later advances without failing:
-- waiting carries no error, readiness follows, and disposal releases once.
function T.genuinely_pending_images_become_ready_without_failing()
  local held = { ["scene:probe"] = true }
  local images, released = {}, {}
  local services = {}
  function services.prepare(_)
    return true
  end
  function services.drawable(key)
    if held[key] then
      return nil
    end
    if images[key] == nil then
      images[key] = StubLease.new(key)
    end
    return images[key]
  end
  function services.release(key)
    released[key] = (released[key] or 0) + 1
  end
  local slow = holder(nil, services)
  slow:update()
  Assert.equal(slow:state(), "pending", "the missing scene waits without failing")
  Assert.isNil(slow:error(), "waiting carries no failure context")
  local waiting, pendingErr = slow:drawable("scene:probe")
  Assert.isNil(waiting, "the pending scene hands out no image yet")
  Assert.isNil(pendingErr, "a legitimate wait carries no terminal error")
  for _ = 1, 10 do
    slow:update()
  end
  Assert.equal(slow:state(), "pending", "repeated polls never fail a legitimate wait")
  held["scene:probe"] = nil
  slow:update()
  Assert.equal(slow:state(), "ready", "the arrived image completes preparation")
  Assert.notNil(slow:drawable("scene:probe"), "the arrived scene stays drawable through the holder")
  slow:dispose()
  slow:dispose()
  Assert.equal(released["scene:probe"], 1, "the arrived handle releases once")
end

-- Exact battler portrait pages on demand through the real field
-- presentation services. A layout-only cache stages the portrait
-- selector manifest and the battle artwork but no whole-family index
-- and no portrait pixels yet: the opening demand waits while the
-- borrowed page host builds only the pages its visible selectors name,
-- then enters once those pages validate. Nothing reads the family
-- index, nothing asks for the full mon summary, and no blank sprite
-- paints while a page is still building.

local ManifestFixture = require("tests.support.BattlePresentationManifestFixture")
local PORTRAIT_SCENE_KEY = "general/grass/day"
local PORTRAIT_MENU_IMAGE = "assets/generated/battle/menu-command-1.png"
local PORTRAIT_FONT_PATH = "font-0"
local PORTRAIT_SELECT_SYMBOL = "SEQ_SE_DP_SELECT"
local PROBE_TICK = 1 / 60

---@param width integer
---@param height integer
---@return string real decodable pixels the host image loader accepts
local function solidPortraitPng(width, height)
  local PngWriter = require("libs.assets.src.PngWriter")
  local pixels = {}
  for _ = 1, width * height do
    pixels[#pixels + 1] = string.char(255, 255, 255, 255)
  end
  return PngWriter.encode(width, height, table.concat(pixels))
end

-- The staged battle manifest the demand envelope loads is the same valid
-- current v2 manifest used by the schema and cache suites.
---@return table schema-valid staged battle manifest
local function stagedPortraitBattleManifest()
  local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
  local manifest = ManifestFixture.manifest()
  manifest.menus.images[PORTRAIT_MENU_IMAGE] = { width = 8, height = 8 }
  manifest.menus.images[BattlePresentationCache.sceneImagePath(PORTRAIT_SCENE_KEY)] = { width = 512, height = 256 }
  manifest.messages.roles.narration.font = PORTRAIT_FONT_PATH
  manifest.messages.roles.menu.font = PORTRAIT_FONT_PATH
  manifest.messages.roles.hud.font = PORTRAIT_FONT_PATH
  manifest.audioRoles.select = PORTRAIT_SELECT_SYMBOL
  return manifest
end

-- An isolated layout-only versioned cache: the portrait selector manifest
-- and the staged battle artwork exist, but the whole-family index and
-- every portrait page start missing. Portrait pages arrive only through
-- stagePortraitPage once the page host reports them built.
---@param portraitEntries table<string, table<string, unknown>> canonical selector to manifest cell
---@return table isolated cache filesystem double recording every manifest read
local function layoutOnlyCache(portraitEntries)
  local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
  local MonCache = require("libs.assets.src.MonCache")
  local sceneImage = BattlePresentationCache.sceneImagePath(PORTRAIT_SCENE_KEY)
  local charactersPath = BattlePresentationCache.sceneCharactersPath(PORTRAIT_SCENE_KEY)
  local mapPath = BattlePresentationCache.sceneMapPath(PORTRAIT_SCENE_KEY)
  local palettePath = BattlePresentationCache.scenePalettePath(PORTRAIT_SCENE_KEY)
  local cache = { versionId = "portrait-demand-probe", files = {}, lua = {}, loadedPaths = {}, readPaths = {} }
  cache.files[PORTRAIT_MENU_IMAGE] = solidPortraitPng(8, 8)
  cache.files[PORTRAIT_FONT_PATH] = "staged-font"
  local stagedManifest = stagedPortraitBattleManifest()
  for _, menu in ipairs({ "command", "moves", "target" }) do
    local image = stagedManifest.menus[menu].image
    cache.files[image] = solidPortraitPng(8, 8)
  end
  local hud = stagedManifest.hud
  for _, section in ipairs({ hud.player, hud.enemy }) do
    cache.files[section.image] = solidPortraitPng(8, 8)
  end
  for _, section in pairs(hud.doubles) do
    cache.files[section.image] = solidPortraitPng(8, 8)
  end
  cache.files[stagedManifest.pictures.shadow.image] = solidPortraitPng(64, 64)
  cache.files[sceneImage] = solidPortraitPng(512, 256)
  cache.files[charactersPath] = string.rep("\0", 65536)
  local mapEntries = {}
  for index = 1, 2048 do
    mapEntries[index] = { tile = 0, flipH = false, flipV = false, palette = 0 }
  end
  local paletteColors = {}
  for index = 1, 256 do
    paletteColors[index] = { r = 0, g = 0, b = 0 }
  end
  cache.lua[BattlePresentationCache.manifestPath()] = stagedManifest
  cache.lua[mapPath] = { width = 512, height = 256, entries = mapEntries }
  cache.lua[palettePath] = { colors = paletteColors }
  cache.lua[BattlePresentationCache.scenePath(PORTRAIT_SCENE_KEY)] = {
    schema = "g4-battle-scene-v2",
    key = PORTRAIT_SCENE_KEY,
    background = "general",
    terrain = "grass",
    time = "day",
    canvasWidth = 512,
    canvasHeight = 256,
    viewport = { x = 0, y = 0, width = 256, height = 192 },
    layers = {
      {
        key = "background",
        backing = { width = 512, height = 256, mapWidth = 64, mapHeight = 32 },
        viewport = { x = 0, y = 0, width = 256, height = 192 },
        scroll = { x = 0, y = 0 },
        characters = {
          key = "battle-scene/general-grass-day/background/characters",
          path = charactersPath,
          format = "indexed8",
        },
        map = {
          key = "battle-scene/general-grass-day/background/map",
          path = mapPath,
          format = "tilemap",
        },
        palette = {
          key = "battle-scene/general-grass-day/background/palette",
          path = palettePath,
          format = "rgb888",
        },
      },
    },
    imagePath = sceneImage,
  }
  cache.lua[MonCache.portraitManifestPath()] = { entries = portraitEntries }
  function cache:loadLua(path)
    self.loadedPaths[#self.loadedPaths + 1] = path
    return self.lua[path]
  end
  function cache:read(path)
    self.readPaths[#self.readPaths + 1] = path
    return self.files[path]
  end
  function cache:exists(path, _)
    return self.files[path] ~= nil
  end
  return cache
end

---@param pageId integer zero-based portrait page identity under staging
---@return table manifest cell covering an 8x8 portrait at the page origin
local function portraitEntry(pageId)
  return {
    x = 0,
    y = 0,
    width = 8,
    height = 8,
    pageId = pageId,
    frames = {
      { x = 0, y = 0, width = 8, height = 8 },
      { x = 8, y = 0, width = 8, height = 8 },
    },
  }
end

-- Stages one portrait page exactly like the page worker would publish
-- it: the page marker plus complete decodable pixels.
---@param cache table isolated cache filesystem double under staging
---@param pageId integer zero-based portrait page identity under staging
local function stagePortraitPage(cache, pageId)
  local MonCache = require("libs.assets.src.MonCache")
  cache.files[MonCache.pageMarkerPath("portraits", pageId)] = "portrait-marker-" .. tostring(pageId)
  cache.files[MonCache.pageImagePath("portraits", pageId)] = solidPortraitPng(64, 64)
end

-- The borrowed selected-game page host: per-page programmable
-- pending/ready/terminal answers with every page request recorded.
-- Anything besides the exact page and scene requests is recorded as an
-- unexpected host call instead of silently succeeding.
---@return table page host carrying its derived assets and recordings
local function portraitPageHost()
  local host = { asks = {}, answers = {}, sceneAsks = {}, sceneReady = true, unexpected = {} }
  local derived = {}
  function derived.requestMonPortraitPage(pageId, urgency)
    host.asks[#host.asks + 1] = { pageId = pageId, urgency = urgency }
    local answer = host.answers[pageId]
    if answer == nil then
      return false, nil
    end
    return answer.ready, answer.failure
  end
  function derived.requestBattleScene(key, urgency)
    host.sceneAsks[#host.sceneAsks + 1] = { key = key, urgency = urgency }
    return host.sceneReady, host.sceneFailure
  end
  setmetatable(derived, {
    __index = function(_, key)
      host.unexpected[#host.unexpected + 1] = tostring(key)
      return nil
    end,
  })
  host.derivedAssets = derived
  return host
end

---@param cache table isolated cache filesystem double under demand
---@param host table page host under borrowing
---@param graphics table host graphics namespace under borrowing
---@return table live presented-battle envelope under test driving
-- A scripted stand-in for the shared generated-image owner behind
-- portrait demand: answers ready borrows immediately, or one terminal
-- failure for every request when constructed with a cause.
---@param failure string? terminal classification cause behind every request, nil answers ready
---@return table scripted pool behind the envelope under test
local function scriptedPool(failure)
  local pool = { requests = 0 }
  function pool:request(_, _, _)
    self.requests = self.requests + 1
    return self.requests
  end
  function pool:poll(_)
    if failure ~= nil then
      return "failed", failure
    end
    return "ready"
  end
  function pool:acquire(_)
    return { image = {}, width = 256, height = 256 }
  end
  function pool:release(_) end
  return pool
end

local function demandEnvelope(cache, host, graphics, pool)
  local FieldBattlePresentation = require("game.hgss.src.field.FieldBattlePresentation")
  local ScreenTopology = require("libs.ui.src.ScreenTopology")
  local text = {}
  function text.measure(content)
    return { width = 8 * #tostring(content), height = 16 }
  end
  function text.drawText(_) end
  local windows = {}
  function windows.drawWindow(_, _, _) end
  return FieldBattlePresentation.new({
    cacheFs = cache,
    windows = windows,
    text = text,
    measureDisplay = function()
      return {
        width = 256,
        height = 384,
        topology = ScreenTopology.dualDisplay(
          { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
          { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
        ),
        pixelRatio = 1,
        signature = "portrait-demand:dual",
      }
    end,
    graphics = graphics,
    derivedAssets = host.derivedAssets,
    imagePool = pool or scriptedPool(),
  })
end

---@param pages string[] canonical portrait selectors under demand
---@return table exact launch demand carrying the staged scene and portrait pages
local function portraitDemand(pages)
  return {
    launchId = "portrait-demand-probe",
    scenes = { PORTRAIT_SCENE_KEY },
    pages = pages,
    audio = { roles = {}, banks = {}, cries = {} },
  }
end

---@param cache table isolated cache filesystem double under inspection
---@param path string cache-relative path under inspection
---@return boolean true once the demand read that manifest path
local function loadSaw(cache, path)
  for _, seen in ipairs(cache.loadedPaths) do
    if seen == path then
      return true
    end
  end
  return false
end

---@param host table page host under inspection
---@return table<boolean> requested portrait page identities
local function askedPageSet(host)
  local set = {}
  for _, ask in ipairs(host.asks) do
    set[ask.pageId] = true
  end
  return set
end

---@param combatant integer
---@param side integer
---@param active boolean
---@param species string
---@param name string
---@param portrait string canonical portrait selector
---@return table detached battler record
local function demandBattler(combatant, side, active, species, name, portrait)
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

---@param launchId string owning launch identity
---@param services table preparation services under test driving
---@return table live battle screen over the real resource holder
local function demandScreen(launchId, services)
  local BattleScreenState = require("game.hgss.src.battle.BattleScreenState")
  local ScreenTopology = require("libs.ui.src.ScreenTopology")
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
  return BattleScreenState.new({
    launchId = launchId,
    manifest = stagedPortraitBattleManifest(),
    model = {},
    submit = function(_)
      return true
    end,
    measureDisplay = function()
      return {
        width = 256,
        height = 384,
        topology = ScreenTopology.dualDisplay(
          { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
          { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
        ),
        pixelRatio = 1,
        signature = "portrait-screen:dual",
      }
    end,
    assets = services,
    text = text,
    windows = windows,
    audio = audio,
  })
end

---@param screen table live battle screen under test driving
---@param ticks integer fixed updates under test driving
---@return table latest observed launch status snapshot
local function pumpScreen(screen, ticks)
  local status = screen:status()
  for _ = 1, ticks do
    screen:updateFixed(PROBE_TICK)
    status = screen:status()
  end
  return status
end

---@param prepared table<integer, table<string, unknown>> recorded launch demands
---@return string[] every demanded portrait page in order
local function flattenDemandPages(prepared)
  local pages = {}
  for _, demand in ipairs(prepared) do
    for _, page in ipairs(demand.pages or {}) do
      pages[#pages + 1] = page
    end
  end
  return pages
end

---@param prepared table<integer, table<string, unknown>> recorded launch demands
---@param want string canonical portrait selector under inspection
---@return boolean true once any demand named that selector
local function demandHasPage(prepared, want)
  for _, page in ipairs(flattenDemandPages(prepared)) do
    if page == want then
      return true
    end
  end
  return false
end

---@param prepared table<integer, table<string, unknown>> recorded launch demands
---@return boolean true once any demand fell back to a shorthand key
local function demandHasShorthand(prepared)
  for _, page in ipairs(flattenDemandPages(prepared)) do
    if tostring(page):match("^[^/]+/%d+/[a-z]+$") ~= nil then
      return true
    end
  end
  return false
end

-- A cold layout-only cache opens the battle once exactly the visible
-- portrait pages build: two distinct selectors on two pages hold pending
-- while the host works, demand exactly those pages urgently, never read
-- the whole-family index, hand out no sprite and touch no image driver
-- early, then resolve both sprites once the pages validate.
function T.cold_layout_cache_demands_only_its_visible_portrait_pages()
  local MonCache = require("libs.assets.src.MonCache")
  local FakeGraphics = require("tests.support.FakeGraphics")
  local leadBack = MonCache.portraitSelector("EEVEE", 0, "male", false, "back")
  local foeFront = MonCache.portraitSelector("RATTATA", 0, "male", false)
  local cache = layoutOnlyCache({
    [leadBack] = portraitEntry(3),
    [foeFront] = portraitEntry(7),
  })
  local host = portraitPageHost()
  local graphics = FakeGraphics.new()
  local envelope = demandEnvelope(cache, host, graphics)
  local services = envelope:_preparationServices()
  local waiting, waitErr = services.prepare(portraitDemand({ leadBack, foeFront }))
  Assert.isTrue(waiting == false, "the unstaged pages hold the opening pending instead of failing")
  Assert.isNil(waitErr, "a legitimate page build carries no failure context")
  local askedUrgency = {}
  for _, ask in ipairs(host.asks) do
    askedUrgency[ask.pageId] = ask.urgency
  end
  Assert.equal(askedUrgency[3], "required", "the lead page is demanded urgently")
  Assert.equal(askedUrgency[7], "required", "the foe page is demanded urgently")
  local askedCount = 0
  for _ in pairs(askedUrgency) do
    askedCount = askedCount + 1
  end
  Assert.equal(askedCount, 2, "only the two visible pages are demanded, never the whole family")
  Assert.equal(#host.unexpected, 0, "no summary or foreign host call backs the demand")
  Assert.isFalse(loadSaw(cache, MonCache.indexPath()), "the demand never reads the whole-family index")
  local pendingHandle, pendingErr = services.drawable("mon:" .. leadBack)
  Assert.isNil(pendingHandle, "the unbuilt page hands out no sprite yet")
  Assert.isNil(pendingErr, "the unbuilt page waits without a terminal error")
  Assert.equal(#graphics.images, 0, "the unbuilt page never reaches the image driver")
  host.answers[3] = { ready = true }
  host.answers[7] = { ready = true }
  stagePortraitPage(cache, 3)
  stagePortraitPage(cache, 7)
  Assert.isTrue(
    services.prepare(portraitDemand({ leadBack, foeFront })),
    "the built pages enter once staged and validated"
  )
  Assert.notNil(services.drawable("mon:" .. leadBack), "the lead sprite resolves once its page is staged")
  Assert.notNil(services.drawable("mon:" .. foeFront), "the foe sprite resolves once its page is staged")
  envelope:dispose()
end

-- A later selector reopens pending without dropping what the launch
-- already holds: the grown set waits for the next update instead of
-- preparing inline, the leased scene and menu handles stay identical
-- through the wait, and readiness returns with the exact grown demand
-- once the added page builds.
function T.grown_selector_set_reopens_pending_without_losing_leased_handles()
  local BattlePresentationAssets = require("game.hgss.src.battle.BattlePresentationAssets")
  local MonCache = require("libs.assets.src.MonCache")
  local FakeGraphics = require("tests.support.FakeGraphics")
  local leadBack = MonCache.portraitSelector("EEVEE", 0, "male", false, "back")
  local foeFront = MonCache.portraitSelector("RATTATA", 0, "male", false)
  local reserveBack = MonCache.portraitSelector("TOTODILE", 0, "female", false, "back")
  local cache = layoutOnlyCache({
    [leadBack] = portraitEntry(3),
    [foeFront] = portraitEntry(7),
    [reserveBack] = portraitEntry(11),
  })
  stagePortraitPage(cache, 3)
  stagePortraitPage(cache, 7)
  local host = portraitPageHost()
  host.answers[3] = { ready = true }
  host.answers[7] = { ready = true }
  local graphics = FakeGraphics.new()
  local envelope = demandEnvelope(cache, host, graphics)
  local services = envelope:_preparationServices()
  local prepareCalls, lastPages = 0, {}
  local basePrepare = services.prepare
  function services.prepare(demand)
    prepareCalls = prepareCalls + 1
    lastPages = demand.pages or {}
    return basePrepare(demand)
  end
  local owned = BattlePresentationAssets.new({
    assets = services,
    launchId = "portrait-growth-probe",
    sceneKey = PORTRAIT_SCENE_KEY,
    shadowRegions = SHADOW_REGIONS,
  })
  owned:addSelectors({ leadBack, foeFront })
  owned:update()
  Assert.equal(owned:state(), "ready", "the opening prepares once its pages are staged")
  local sceneImage = "scene:" .. PORTRAIT_SCENE_KEY
  local sceneHandle = owned:drawable(sceneImage)
  local menuHandle = owned:drawable("menu:command")
  Assert.notNil(sceneHandle, "the opening leases its scene handle")
  Assert.notNil(menuHandle, "the opening leases its menu handle")
  Assert.notNil(owned:drawable("shadow"), "the production asset route resolves the staged native shadow PNG")
  local shadowPathRead = false
  for _, path in ipairs(cache.readPaths) do
    shadowPathRead = shadowPathRead or path == BattlePresentationManifestFixture.manifest().pictures.shadow.image
  end
  Assert.isTrue(
    shadowPathRead,
    "shadow lookup reads the exact image path published by the global catalog"
  )
  local callsBeforeGrowth = prepareCalls
  owned:addSelectors({ reserveBack })
  Assert.equal(owned:state(), "pending", "the grown selector set reopens pending until its page builds")
  Assert.equal(
    prepareCalls,
    callsBeforeGrowth,
    "the grown demand waits for the next update instead of preparing inline"
  )
  Assert.isTrue(owned:drawable(sceneImage) == sceneHandle, "the wait keeps its leased scene handle")
  Assert.isTrue(owned:drawable("menu:command") == menuHandle, "the wait keeps its leased menu handle")
  owned:update()
  Assert.equal(owned:state(), "pending", "the unbuilt reserve page keeps the launch pending")
  host.answers[11] = { ready = true }
  stagePortraitPage(cache, 11)
  owned:update()
  Assert.equal(owned:state(), "ready", "the built reserve page completes the grown demand")
  Assert.notNil(owned:drawable("mon:" .. reserveBack), "the reserve sprite resolves under its canonical key")
  Assert.isTrue(owned:drawable(sceneImage) == sceneHandle, "readiness keeps the original scene handle")
  local demanded = {}
  for _, page in ipairs(lastPages) do
    demanded[page] = true
  end
  Assert.isTrue(
    demanded[leadBack] and demanded[foeFront] and demanded[reserveBack],
    "the settled demand carries every disclosed selector"
  )
  owned:dispose()
  owned:dispose()
  envelope:dispose()
end

-- The opening discloses only its visible battlers and the switch grows
-- the demand then: the benched reserve stays undemanded and its page
-- unrequested until the switch packet makes it active, when only that
-- added page is enqueued while the screen keeps running.
function T.opening_demand_names_only_visible_battlers_then_grows_on_switch()
  local MonCache = require("libs.assets.src.MonCache")
  local FakeGraphics = require("tests.support.FakeGraphics")
  local leadBack = MonCache.portraitSelector("EEVEE", 0, "male", false, "back")
  local reserveBack = MonCache.portraitSelector("TOTODILE", 0, "female", false, "back")
  local foeFront = MonCache.portraitSelector("RATTATA", 0, "male", false)
  local cache = layoutOnlyCache({
    [leadBack] = portraitEntry(3),
    [reserveBack] = portraitEntry(11),
    [foeFront] = portraitEntry(7),
  })
  stagePortraitPage(cache, 3)
  stagePortraitPage(cache, 7)
  local host = portraitPageHost()
  host.answers[3] = { ready = true }
  host.answers[7] = { ready = true }
  local graphics = FakeGraphics.new()
  local envelope = demandEnvelope(cache, host, graphics)
  local services = envelope:_preparationServices()
  local launchId = "launch-visible-demand"
  local screen = demandScreen(launchId, services)
  local port = screen:presentationPort()
  port.enter({ launchId = launchId, kind = "wild" })
  local function openingAfter()
    return {
      own = {
        demandBattler(1, 1, true, "EEVEE", "LEADA", leadBack),
        demandBattler(2, 1, false, "TOTODILE", "RESERVE", reserveBack),
      },
      foes = { demandBattler(3, 2, true, "RATTATA", "FOEX", foeFront) },
    }
  end
  port.present({ launchId = launchId, packetId = 1, events = {}, before = openingAfter(), after = openingAfter() })
  local opening = pumpScreen(screen, 400)
  Assert.isTrue(opening.mode ~= "failed", "the opening runs: " .. tostring(opening.error))
  local prepared = envelope:preparedDemands()
  Assert.isTrue(demandHasPage(prepared, leadBack), "the opening demands the exact active lead back selector")
  Assert.isTrue(demandHasPage(prepared, foeFront), "the opening demands the exact revealed foe selector")
  Assert.isFalse(demandHasPage(prepared, reserveBack), "the benched reserve stays undemanded before its switch")
  Assert.isFalse(demandHasShorthand(prepared), "no demand falls back to a shorthand key")
  Assert.isFalse(askedPageSet(host)[11], "the opening never requests the benched reserve page")
  local switchedAfter = {
    own = {
      demandBattler(1, 1, false, "EEVEE", "LEADA", leadBack),
      demandBattler(2, 1, true, "TOTODILE", "RESERVE", reserveBack),
    },
    foes = { demandBattler(3, 2, true, "RATTATA", "FOEX", foeFront) },
  }
  port.present({
    launchId = launchId,
    packetId = 2,
    events = {
      {
        sequence = 1,
        kind = "switch",
        cause = { key = "TACKLE" },
        audience = "public",
        payload = { from = 1, to = 2 },
      },
    },
    before = openingAfter(),
    after = switchedAfter,
  })
  host.answers[11] = { ready = true }
  stagePortraitPage(cache, 11)
  local switched = pumpScreen(screen, 400)
  Assert.isTrue(switched.mode ~= "failed", "the switch runs: " .. tostring(switched.error))
  Assert.isTrue(
    demandHasPage(envelope:preparedDemands(), reserveBack),
    "the switch demands the exact incoming reserve selector"
  )
  Assert.isTrue(askedPageSet(host)[11], "the switch enqueues the added reserve page")
  screen:dispose()
  envelope:dispose()
end

-- A terminal page build fails the launch once with its exact cause and
-- hands that cause to the field host: the reason names the selector, the
-- page, and the worker message, polls replay it identically, no sprite
-- stands in, the image driver stays untouched, and the field observes
-- exactly one screen failure before the screen releases.
function T.portrait_page_worker_failure_names_its_selector_and_page_once()
  local MonCache = require("libs.assets.src.MonCache")
  local FakeGraphics = require("tests.support.FakeGraphics")
  local leadBack = MonCache.portraitSelector("EEVEE", 0, "male", false, "back")
  local foeFront = MonCache.portraitSelector("RATTATA", 0, "male", false)
  local cache = layoutOnlyCache({
    [leadBack] = portraitEntry(13),
    [foeFront] = portraitEntry(7),
  })
  stagePortraitPage(cache, 7)
  local host = portraitPageHost()
  host.answers[13] = { ready = nil, failure = "probe-page-boom" }
  host.answers[7] = { ready = true }
  local graphics = FakeGraphics.new()
  local envelope = demandEnvelope(cache, host, graphics)
  local services = envelope:_preparationServices()
  local failed, failure = services.prepare(portraitDemand({ leadBack, foeFront }))
  Assert.isNil(failed, "the doomed page never reads ready")
  Assert.isTrue(type(failure) == "string" and failure ~= "", "the doomed page carries its reason")
  local reason = failure --[[@as string]]
  Assert.isTrue(reason:find(leadBack, 1, true) ~= nil, "the failure names the exact doomed selector: " .. reason)
  Assert.isTrue(reason:find("13", 1, true) ~= nil, "the failure names the exact doomed page: " .. reason)
  Assert.isTrue(reason:find("probe-page-boom", 1, true) ~= nil, "the failure carries the worker cause: " .. reason)
  Assert.isTrue(askedPageSet(host)[13], "the doomed page went through the borrowed page host")
  local failedAgain, failureAgain = services.prepare(portraitDemand({ leadBack, foeFront }))
  Assert.isNil(failedAgain, "the doomed page stays failed across polls")
  Assert.equal(failureAgain, reason, "the terminal cause replays identically")
  local BattlePresentationAssets = require("game.hgss.src.battle.BattlePresentationAssets")
  local owned = BattlePresentationAssets.new({
    assets = services,
    launchId = "portrait-doomed-probe",
    sceneKey = PORTRAIT_SCENE_KEY,
    shadowRegions = SHADOW_REGIONS,
  })
  owned:addSelectors({ leadBack, foeFront })
  owned:update()
  Assert.equal(owned:state(), "failed", "the doomed demand stops its holder")
  Assert.isTrue(
    (owned:error() or ""):find(leadBack, 1, true) ~= nil,
    "the latched error keeps the exact selector: " .. tostring(owned:error())
  )
  local standin, standinErr = owned:drawable("mon:" .. leadBack)
  Assert.isNil(standin, "the doomed portrait hands out no stand-in sprite")
  Assert.isTrue(type(standinErr) == "string" and standinErr ~= "", "the doomed portrait keeps its terminal reason")
  Assert.equal(#graphics.images, 0, "the doomed page never reaches the image driver")
  owned:dispose()
  local launchId = "launch-doomed-demand"
  local screen = demandScreen(launchId, services)
  local port = screen:presentationPort()
  port.enter({ launchId = launchId, kind = "wild" })
  local function doomedAfter()
    return {
      own = { demandBattler(1, 1, true, "EEVEE", "LEADA", leadBack) },
      foes = { demandBattler(3, 2, true, "RATTATA", "FOEX", foeFront) },
    }
  end
  port.present({ launchId = launchId, packetId = 1, events = {}, before = doomedAfter(), after = doomedAfter() })
  local doomedStatus = nil
  for _ = 1, 400 do
    screen:updateFixed(PROBE_TICK)
    local status = screen:status()
    if status.mode == "failed" then
      doomedStatus = status
      break
    end
  end
  Assert.notNil(doomedStatus, "the doomed page fails the screen instead of holding forever")
  local screenErr = (doomedStatus --[[@as table]]).error or ""
  Assert.isTrue(
    tostring(screenErr):find(leadBack, 1, true) ~= nil,
    "the screen error names the exact selector: " .. tostring(screenErr)
  )
  Assert.isTrue(
    tostring(screenErr):find("13", 1, true) ~= nil,
    "the screen error names the exact page: " .. tostring(screenErr)
  )
  local notified = {}
  local fieldHost = {}
  function fieldHost.notify(event, reason)
    notified[#notified + 1] = { event = event, reason = reason }
  end
  envelope._screen = screen
  envelope._descriptor = { host = fieldHost }
  envelope:_observeScreenFailure()
  Assert.equal(#notified, 1, "the failed screen reaches the field host exactly once")
  Assert.equal(notified[1].event, "screen-failed", "the handoff reports the screen failure")
  Assert.isTrue(
    tostring(notified[1].reason):find(leadBack, 1, true) ~= nil,
    "the handoff cause names the exact selector"
  )
  Assert.isTrue(tostring(notified[1].reason):find("13", 1, true) ~= nil, "the handoff cause names the exact page")
  Assert.isNil(envelope:liveScreen(), "the failed screen releases after its handoff")
  envelope:_observeScreenFailure()
  Assert.equal(#notified, 1, "the handoff never repeats")
  envelope:dispose()
end

-- Missing pixels and undecodable pixels both fail closed without
-- stand-ins: a worker-ready page with no staged bytes names its
-- selector and page and stays failed across polls, and staged bytes
-- that blow up the image driver report once naming the selector and
-- its page path, replay identically, and never retry the driver.
function T.unstaged_and_undecodable_pages_fail_closed_without_standins()
  local MonCache = require("libs.assets.src.MonCache")
  local FakeGraphics = require("tests.support.FakeGraphics")
  local leadBack = MonCache.portraitSelector("EEVEE", 0, "male", false, "back")
  local missingImage = MonCache.pageImagePath("portraits", 17)
  local cache = layoutOnlyCache({ [leadBack] = portraitEntry(17) })
  local host = portraitPageHost()
  host.answers[17] = { ready = true }
  local graphics = FakeGraphics.new()
  local envelope = demandEnvelope(cache, host, graphics)
  local services = envelope:_preparationServices()
  local missing, missingErr = services.prepare(portraitDemand({ leadBack }))
  Assert.isNil(missing, "the pixel-less page never reads ready")
  Assert.isTrue(type(missingErr) == "string" and missingErr ~= "", "the pixel-less page carries its reason")
  local missingReason = missingErr --[[@as string]]
  Assert.isTrue(
    missingReason:find(leadBack, 1, true) ~= nil,
    "the missing-pixel failure names the exact selector: " .. missingReason
  )
  Assert.isTrue(
    missingReason:find("17", 1, true) ~= nil,
    "the missing-pixel failure names the exact page: " .. missingReason
  )
  local missingAgain, missingErrAgain = services.prepare(portraitDemand({ leadBack }))
  Assert.isNil(missingAgain, "the pixel-less page stays failed across polls")
  Assert.equal(missingErrAgain, missingReason, "the missing-pixel cause replays identically")
  local BattlePresentationAssets = require("game.hgss.src.battle.BattlePresentationAssets")
  local owned = BattlePresentationAssets.new({
    assets = services,
    launchId = "portrait-missing-probe",
    sceneKey = PORTRAIT_SCENE_KEY,
    shadowRegions = SHADOW_REGIONS,
  })
  owned:addSelectors({ leadBack })
  owned:update()
  Assert.equal(owned:state(), "failed", "the pixel-less demand stops its holder")
  Assert.isNil(owned:drawable("mon:" .. leadBack), "the pixel-less portrait hands out no sprite")
  Assert.equal(#graphics.images, 0, "the pixel-less page never reaches the image driver")
  owned:dispose()
  envelope:dispose()
  local staged = layoutOnlyCache({ [leadBack] = portraitEntry(17) })
  stagePortraitPage(staged, 17)
  local stagedHost = portraitPageHost()
  stagedHost.answers[17] = { ready = true }
  local pool = scriptedPool("probe-decode-boom")
  local throwing = FakeGraphics.new({ failOnImageCall = 1 })
  local stagedEnvelope = demandEnvelope(staged, stagedHost, throwing, pool)
  local stagedServices = stagedEnvelope:_preparationServices()
  Assert.isTrue(
    stagedServices.prepare(portraitDemand({ leadBack })),
    "the staged page validates before its pixels decode"
  )
  local broken, brokenErr = stagedServices.drawable("mon:" .. leadBack)
  Assert.isNil(broken, "the undecodable portrait hands out no sprite")
  Assert.isTrue(type(brokenErr) == "string" and brokenErr ~= "", "the undecodable portrait carries its reason")
  local brokenReason = brokenErr --[[@as string]]
  Assert.isTrue(
    brokenReason:find(leadBack, 1, true) ~= nil,
    "the undecodable failure names the exact selector: " .. brokenReason
  )
  Assert.isTrue(
    brokenReason:find(missingImage, 1, true) ~= nil,
    "the undecodable failure names the exact page path: " .. brokenReason
  )
  local brokenAgain, brokenErrAgain = stagedServices.drawable("mon:" .. leadBack)
  Assert.isNil(brokenAgain, "the undecodable portrait stays failed without a substitute")
  Assert.equal(brokenErrAgain, brokenReason, "the undecodable failure replays identically")
  Assert.equal(pool.requests, 1, "the undecodable upload is attempted once, never retried per tick")
  Assert.equal(#throwing.images, 0, "the undecodable page leaves no staged handle behind")
  stagedEnvelope:dispose()
end

-- Only the selected effect is requested and consumed through the real
-- preparation services: a recording derived host plus a versioned cache
-- holding a synthetic schema-valid staged effect. The demand stays pending
-- while the marker or any dependency payload is missing, turns ready only
-- with the complete staged closure, and never enqueues a sibling effect.
local function recordingEffectHost()
  local host = { asks = {}, answers = {} }
  local derived = {}
  function derived.requestBattleEffect(key, urgency)
    host.asks[#host.asks + 1] = { key = key, urgency = urgency }
    local answer = host.answers[key]
    if type(answer) == "table" and answer.failure ~= nil then
      return false, answer.failure
    end
    if answer == "ready" then
      return true
    end
    return nil
  end
  host.derivedAssets = derived
  return host
end

local function effectStagingEnvelope(cache, host)
  local FieldBattlePresentation = require("game.hgss.src.field.FieldBattlePresentation")
  local ScreenTopology = require("libs.ui.src.ScreenTopology")
  local text = {}
  function text.measure(content)
    return { width = 8 * #tostring(content), height = 16 }
  end
  function text.drawText(_) end
  local windows = {}
  function windows.drawWindow(_, _, _) end
  return FieldBattlePresentation.new({
    cacheFs = cache,
    windows = windows,
    text = text,
    measureDisplay = function()
      return {
        width = 256,
        height = 384,
        topology = ScreenTopology.dualDisplay(
          { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
          { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
        ),
        pixelRatio = 1,
        signature = "effect-staging:dual",
      }
    end,
    derivedAssets = host.derivedAssets,
  })
end

function T.selected_effect_demand_reaches_ready_only_through_staged_closure()
  local FakeCache = require("tests.support.FakeCache")
  local CacheFs = require("libs.storage.src.CacheFs")
  local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
  local EffectStagingFixture = require("tests.support.EffectStagingFixture")
  local Hashing = require("romdump.src.digest.Hashing")
  local cache = CacheFs.forVersion("probe-effect-staging", FakeCache.new())
  local host = recordingEffectHost()
  local envelope = effectStagingEnvelope(cache, host)
  local services = envelope:_preparationServices()
  local textureBytes = EffectStagingFixture.rgba(4, 4)
  local textureIdentity = Hashing.sha1hex(textureBytes)
  local texturePath = BattlePresentationCache.globalResourcePath("effect/content/" .. textureIdentity)
  local record = EffectStagingFixture.effectRecord("TACKLE", {
    { key = "probe-spark", kind = "texture", payload = texturePath, contentIdentity = textureIdentity },
  })
  cache:writeLua(BattlePresentationCache.effectPath("TACKLE"), record)
  local owned = BattlePresentationAssets.new({
    assets = services,
    launchId = "probe-staging",
    sceneKey = "probe/plain/day",
    shadowRegions = SHADOW_REGIONS,
  })
  Assert.equal(owned:demandEffect("TACKLE"), false, "the unstaged effect polls pending without failing")
  host.answers["TACKLE"] = "ready"
  Assert.equal(owned:demandEffect("TACKLE"), false, "a ready worker without marker and payloads stays pending")
  cache:write(BattlePresentationCache.effectMarkerPath("TACKLE"), "probe-marker")
  Assert.equal(owned:demandEffect("TACKLE"), false, "a marker without dependency payloads stays pending")
  cache:writeLua(texturePath, { width = 4, height = 4, rgba8888 = textureBytes })
  Assert.equal(owned:demandEffect("TACKLE"), true, "the closed staged effect reads ready")
  for _, ask in ipairs(host.asks) do
    Assert.equal(ask.key, "TACKLE", "every host request names the selected effect, never a sibling")
  end
  Assert.isTrue(#host.asks >= 1, "the selected effect is actually requested through the host")
  local effect = owned:loadEffect("TACKLE")
  Assert.notNil(effect, "the ready effect loads")
  Assert.equal(effect.key, "TACKLE", "the loaded record names the selected effect")
  local missing, missingErr = owned:loadEffect("SPLASH")
  Assert.isNil(missing, "an undemanded effect never loads a guess")
  Assert.isTrue(type(missingErr) == "string" and missingErr ~= "", "the undemanded load fails with context")
  local slashed, slashedErr = owned:demandEffect("HAS/SLASH")
  Assert.isNil(slashed, "a non-flat effect key never reads ready")
  Assert.isTrue(type(slashedErr) == "string" and slashedErr ~= "", "the non-flat key fails with context")
  owned:dispose()
  envelope:dispose()
end

-- An unconfigured production effect service fails loudly when used: no
-- fake ready value, no silent pending, no guessed record or lease.
function T.unconfigured_effect_service_fails_instead_of_reporting_ready()
  local owned = holder(nil, stubAssets({}))
  local ready, readyErr = owned:demandEffect("TACKLE")
  Assert.isNil(ready, "an unconfigured effect service never reports ready")
  Assert.isTrue(type(readyErr) == "string" and readyErr ~= "", "the unconfigured demand fails with context")
  local record, recordErr = owned:loadEffect("TACKLE")
  Assert.isNil(record, "nothing loads without a configured effect service")
  Assert.isTrue(type(recordErr) == "string" and recordErr ~= "", "the unconfigured load fails with context")
  local lease, leaseErr = owned:resolveEffectResource({ key = "TACKLE" }, "probe-spark")
  Assert.isNil(lease, "nothing resolves without a configured effect service")
  Assert.isTrue(type(leaseErr) == "string" and leaseErr ~= "", "the unconfigured resolve fails with context")
  owned:dispose()
end

-- Two overlapping occurrences share one immutable texture: one cancel
-- never releases the shared handle early, the last release withdraws it,
-- launch disposal frees it exactly once, and a stale resolve after
-- disposal publishes nothing.
function T.overlapping_effect_leases_share_one_handle_and_release_exactly_once()
  local EffectStagingFixture = require("tests.support.EffectStagingFixture")
  local Hashing = require("romdump.src.digest.Hashing")
  local staging = EffectStagingFixture.new({ launchId = "probe-overlap" })
  local textureBytes = EffectStagingFixture.rgba(4, 4)
  local textureIdentity = Hashing.sha1hex(textureBytes)
  staging:stageEffect(
    "TACKLE",
    EffectStagingFixture.effectRecord("TACKLE", {
      { key = "probe-spark", kind = "texture", payload = "effects/probe-spark.lua", contentIdentity = textureIdentity },
    }),
    { ["effects/probe-spark.lua"] = { width = 4, height = 4, rgba8888 = textureBytes } }
  )
  local owned = BattlePresentationAssets.new({
    assets = staging.services,
    launchId = "probe-overlap",
    sceneKey = "probe/plain/day",
    shadowRegions = SHADOW_REGIONS,
  })
  Assert.equal(owned:demandEffect("TACKLE"), true, "the staged closure reads ready")
  local effect = owned:loadEffect("TACKLE")
  Assert.notNil(effect, "the ready effect loads before resolving")
  local first = owned:resolveEffectResource(effect, "probe-spark")
  Assert.notNil(first, "the first occurrence resolves its texture")
  Assert.equal(first.width, 4, "the texture lease carries its staged width")
  Assert.equal(first.height, 4, "the texture lease carries its staged height")
  Assert.equal(first.rgba8888, textureBytes, "the texture lease shares its exact staged bytes")
  local second = owned:resolveEffectResource(effect, "probe-spark")
  Assert.notNil(second, "the overlapping occurrence resolves the same texture")
  Assert.equal(staging.uploads, 1, "duplicate semantic requests upload once and share")
  Assert.notNil(owned:drawable("probe-spark"), "the shared texture resolves through drawables")
  Assert.isTrue(owned:drawable("probe-spark") == owned:drawable("probe-spark"), "drawables stay stable")
  owned:releaseEffectResource(first)
  Assert.notNil(owned:drawable("probe-spark"), "one cancel never releases the shared texture early")
  owned:releaseEffectResource(second)
  Assert.isNil(owned:drawable("probe-spark"), "only the last release withdraws the shared texture")
  owned:dispose()
  local stale, staleErr = owned:resolveEffectResource(effect, "probe-spark")
  Assert.isNil(stale, "a stale resolve after disposal publishes nothing")
  Assert.isTrue(type(staleErr) == "string" and staleErr ~= "", "the stale resolve names its disposal")
  Assert.equal(staging.drops["probe-spark"], 1, "the shared handle frees exactly once")
  owned:dispose()
  Assert.equal(staging.drops["probe-spark"], 1, "a second disposal never frees again")
end

-- A texture that fails upload after an earlier success is terminal with
-- launch, effect, and resource context: previously acquired handles
-- release once, the failure replays identically instead of hanging as
-- pending, and the failed upload is never retried.
function T.effect_upload_failure_releases_acquired_handles_and_stays_failed()
  local EffectStagingFixture = require("tests.support.EffectStagingFixture")
  local Hashing = require("romdump.src.digest.Hashing")
  local staging = EffectStagingFixture.new({ launchId = "probe-upload-failure" })
  local firstBytes = EffectStagingFixture.rgba(4, 4)
  local secondBytes = EffectStagingFixture.rgba(2, 2)
  local firstIdentity = Hashing.sha1hex(firstBytes)
  local secondIdentity = Hashing.sha1hex(secondBytes)
  staging:stageEffect(
    "TACKLE",
    EffectStagingFixture.effectRecord("TACKLE", {
      { key = "probe-first", kind = "texture", payload = "effects/probe-first.lua", contentIdentity = firstIdentity },
      {
        key = "probe-second",
        kind = "texture",
        payload = "effects/probe-second.lua",
        contentIdentity = secondIdentity,
      },
    }),
    {
      ["effects/probe-first.lua"] = { width = 4, height = 4, rgba8888 = firstBytes },
      ["effects/probe-second.lua"] = { width = 2, height = 2, rgba8888 = secondBytes },
    }
  )
  staging:failUploadFor("probe-second", "probe decode boom")
  local owned = BattlePresentationAssets.new({
    assets = staging.services,
    launchId = "probe-upload-failure",
    sceneKey = "probe/plain/day",
    shadowRegions = SHADOW_REGIONS,
  })
  Assert.equal(owned:demandEffect("TACKLE"), true, "both payloads staged, so the effect reads ready")
  local effect = owned:loadEffect("TACKLE")
  Assert.notNil(effect, "the ready effect loads before resolving")
  Assert.notNil(owned:resolveEffectResource(effect, "probe-first"), "the first texture resolves")
  local lease, failure = owned:resolveEffectResource(effect, "probe-second")
  Assert.isNil(lease, "the failed upload hands out no image")
  Assert.isTrue(type(failure) == "string" and failure ~= "", "the failed upload is terminal with context")
  local reason = failure --[[@as string]]
  Assert.isTrue(reason:find("probe-second", 1, true) ~= nil, "the failure names its resource: " .. reason)
  Assert.isTrue(reason:find("TACKLE", 1, true) ~= nil, "the failure names its effect: " .. reason)
  Assert.isTrue(
    reason:find("probe-upload-failure", 1, true) ~= nil,
    "the failure names its launch: " .. reason
  )
  Assert.equal(staging.drops["probe-first"], 1, "handles acquired before the failure release once")
  Assert.isNil(owned:drawable("probe-first"), "the rolled-back texture hands out nothing")
  local again, againErr = owned:demandEffect("TACKLE")
  Assert.isNil(again, "the failed effect never reads ready again")
  Assert.equal(againErr, reason, "the terminal failure replays identically instead of hanging pending")
  local third, thirdErr = owned:demandEffect("TACKLE")
  Assert.isNil(third, "the failed effect stays failed across polls")
  Assert.equal(thirdErr, reason, "no held queue loops forever")
  owned:dispose()
  Assert.equal(staging.drops["probe-first"], 1, "disposal never frees the rolled-back handle twice")
  Assert.isNil(staging.drops["probe-second"], "the never-uploaded texture never releases")
end

-- Readiness probes never instantiate images: repeated pending and ready
-- demands plus loads create nothing; only admission uploads.
function T.readiness_probes_create_no_images()
  local EffectStagingFixture = require("tests.support.EffectStagingFixture")
  local Hashing = require("romdump.src.digest.Hashing")
  local staging = EffectStagingFixture.new({ launchId = "probe-no-upload" })
  local owned = BattlePresentationAssets.new({
    assets = staging.services,
    launchId = "probe-no-upload",
    sceneKey = "probe/plain/day",
    shadowRegions = SHADOW_REGIONS,
  })
  Assert.equal(owned:demandEffect("TACKLE"), false, "the unstaged effect polls pending")
  Assert.equal(owned:demandEffect("TACKLE"), false, "repeated probes poll without uploading")
  local missing, missingErr = owned:loadEffect("TACKLE")
  Assert.isNil(missing, "nothing loads before readiness")
  Assert.isTrue(type(missingErr) == "string" and missingErr ~= "", "the early load fails with context")
  Assert.equal(staging.uploads, 0, "pending probes create no images")
  local textureBytes = EffectStagingFixture.rgba(4, 4)
  local textureIdentity = Hashing.sha1hex(textureBytes)
  staging:stageEffect(
    "TACKLE",
    EffectStagingFixture.effectRecord("TACKLE", {
      { key = "probe-spark", kind = "texture", payload = "effects/probe-spark.lua", contentIdentity = textureIdentity },
    }),
    { ["effects/probe-spark.lua"] = { width = 4, height = 4, rgba8888 = textureBytes } }
  )
  Assert.equal(owned:demandEffect("TACKLE"), true, "the staged effect reads ready")
  Assert.equal(staging.uploads, 0, "a ready answer still creates no images")
  local effect = owned:loadEffect("TACKLE")
  Assert.notNil(effect, "the ready effect loads")
  Assert.equal(staging.uploads, 0, "loads create no images")
  Assert.notNil(owned:resolveEffectResource(effect, "probe-spark"), "admission resolves the texture")
  Assert.equal(staging.uploads, 1, "only admission uploads")
  owned:dispose()
end

-- A source-only effect with sound but no texture is ready without dummy
-- pixels: the sound descriptor arrives as an immutable lease, never an
-- invented image.
function T.sound_only_effect_readies_without_texture()
  local EffectStagingFixture = require("tests.support.EffectStagingFixture")
  local Hashing = require("romdump.src.digest.Hashing")
  local staging = EffectStagingFixture.new({ launchId = "probe-audio-only" })
  local cryIdentity = Hashing.sha1hex("probe-effect-cry")
  staging:stageEffect(
    "GROWL",
    EffectStagingFixture.effectRecord("GROWL", {
      { key = "probe-cry", kind = "sound", payload = "effects/probe-cry.lua", contentIdentity = cryIdentity },
    }),
    { ["effects/probe-cry.lua"] = { format = "probe-sequence", steps = {} } }
  )
  local owned = BattlePresentationAssets.new({
    assets = staging.services,
    launchId = "probe-audio-only",
    sceneKey = "probe/plain/day",
    shadowRegions = SHADOW_REGIONS,
  })
  Assert.equal(owned:demandEffect("GROWL"), true, "the audio-only closure reads ready")
  local effect = owned:loadEffect("GROWL")
  Assert.notNil(effect, "the audio-only effect loads")
  local lease = owned:resolveEffectResource(effect, "probe-cry")
  Assert.notNil(lease, "the sound dependency resolves")
  Assert.equal(lease.kind, "sound", "the sound lease keeps its kind")
  Assert.equal(lease.payload, "effects/probe-cry.lua", "the sound lease names its staged payload")
  Assert.isNil(lease.rgba8888, "the sound lease carries no pixels")
  Assert.equal(staging.uploads, 0, "no dummy texture is invented for an audio-only effect")
  Assert.isNil(owned:drawable("probe-cry"), "sound dependencies never resolve to a drawable")
  owned:dispose()
end

return { tests = T }
