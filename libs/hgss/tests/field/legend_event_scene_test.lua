-- The legendary-story scene owner: the wing effect's begin/loop/end clips and
-- its map-child handoff, Lance's departure actor resolution, the Sinjoh Unown
-- circle and egg cutscene tick boundaries, the Arceus montage timeline, the
-- missing-source-asset fault and the exact-once cancellation cleanup.
-- Source reference: src/field/script_field_effects.c,
-- src/field/event_cutscene_sinjoh.c and src/application/arceus_cinematic.c.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local LegendEventScene = require("libs.hgss.src.field.LegendEventScene")
local AnimationPlayer = require("libs.hgss.src.presentation.AnimationPlayer")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local LanceDepartureEffect = require("libs.hgss.src.presentation.LanceDepartureEffect")

local T = {}

local ARCEUS = LegendEventScene.ARCEUS_COMMANDS

local function fakeModel(part)
  local durations = {}
  for _, phase in pairs(part and part.clips or {}) do
    for id, frames in pairs(phase.frameCounts or {}) do
      durations[id] = frames
    end
  end
  local model = { plays = {}, handles = {}, disposed = 0, ticks = 0 }
  function model:play(name, opts)
    local player = AnimationPlayer.new({ frameCount = durations[name] or 1 })
    player.loopMode = opts ~= nil and opts.loopMode or "loop"
    local handle = { name = name, player = player, loop = player.loopMode == "loop" }
    self.plays[#self.plays + 1] = handle
    self.handles[#self.handles + 1] = handle
    return handle
  end
  function model:stop(handle)
    for index, candidate in ipairs(self.handles) do
      if candidate == handle then
        table.remove(self.handles, index)
        return 1
      end
    end
    return 0
  end
  function model:updateFixed()
    self.ticks = self.ticks + 1
    for _, handle in ipairs(self.handles) do
      handle.player:updateFixed()
    end
  end
  function model:dispose()
    self.disposed = self.disposed + 1
  end
  return model
end

local function clip(frames, ids, frameCounts)
  ids = ids or { "joint.trs" }
  return { ids = ids, frames = frames, frameCounts = frameCounts or { [ids[1]] = frames } }
end

local function wingDefinition()
  return {
    sound = "SEQ_SE_GS_STOPPERKAIJO",
    parts = {
      { model = { key = "part-0" }, clips = { intro = clip(3, { "intro.joint" }), loop = clip(4, { "loop.joint" }), ["end"] = clip(2, { "end.joint" }) } },
      { model = { key = "part-1" }, clips = { intro = clip(3, { "intro.joint" }), loop = clip(4, { "loop.joint" }), ["end"] = clip(2, { "end.joint" }) } },
    },
  }
end

local function lanceModelHandle()
  local plays = {}
  local model = {}
  function model:play(id, opts)
    local player = AnimationPlayer.new({ frameCount = id == "joint" and 2 or 3 })
    player.loopMode = opts.loopMode
    local handle = { player = player }
    plays[#plays + 1] = handle
    return handle
  end
  function model:stop(handle)
    for index, candidate in ipairs(plays) do
      if candidate == handle then
        table.remove(plays, index)
        return 1
      end
    end
    return 0
  end
  function model:updateFixed()
    for _, handle in ipairs(plays) do
      handle.player:updateFixed()
    end
  end
  function model:dispose() end
  return model
end

local function lanceDefinition()
  return { clipIds = { "joint", "color" }, trainerFrameDurations = { 1, 1 } }
end

local function montageDefinition()
  return {
    bgm = "SEQ_GS_E_ARCEUS",
    timeline = {
      { ARCEUS.SAVE_BGM },
      { ARCEUS.LOAD_BG, 0, 58 },
      { ARCEUS.WAIT, 2 },
      { ARCEUS.SET_SPRITE_VISIBLE, 1 },
      { ARCEUS.SET_SPRITE_POSITION, 128, 80 },
      { ARCEUS.PLAY_BGM, "SEQ_GS_E_ARCEUS" },
      { ARCEUS.END },
    },
    layers = { [58] = { path = "assets/generated/field/effects/textures/aa.png", width = 256, height = 256 } },
    sprite = { path = "assets/generated/field/effects/textures/bb.png", width = 64, height = 64 },
  }
end

local function sceneWith(definitions, extra)
  local audio = { played = {}, music = {}, stopped = 0 }
  function audio:play(sound)
    self.played[#self.played + 1] = sound
  end
  function audio:playMusic(sequence)
    self.music[#self.music + 1] = sequence
  end
  function audio:stopMusic()
    self.stopped = self.stopped + 1
  end
  local actors = { offsets = {}, ids = {}, hidden = {} }
  function actors:actorIdForMapIndex(index)
    return self.ids[index]
  end
  function actors:getPosition(actorId)
    if actorId == nil then
      return nil
    end
    if actorId == "dragonite" or actorId == "map:88:object:10" then
      return { x = 8, y = 0, z = 10 }
    end
    if actorId == "lance" or actorId == "map:88:object:8" then
      return { x = 6, y = 0, z = 7 }
    end
    return { x = 4, y = 0, z = 6 }
  end
  function actors:getById(actorId)
    if actorId == nil then
      return nil
    end
    return {
      getWorldPosition = function()
        return self:getPosition(actorId)
      end,
    }
  end
  function actors:hide(actorId)
    self.hidden[actorId] = true
  end
  function actors:show(actorId)
    self.hidden[actorId] = false
  end
  function actors:setPresentationOffset(actorId, offset)
    self.offsets[actorId] = offset
  end
  local options = {
    definitions = definitions,
    audio = audio,
    actors = actors,
    playerOf = function()
      return { fieldX = 4, fieldZ = 6, worldX = 4, worldY = 0, worldZ = 6 }
    end,
    currentScriptBankId = function()
      return 19
    end,
  }
  local modelFactory = extra ~= nil and extra.modelFactory or nil
  for key, value in pairs(extra or {}) do
    if key ~= "modelFactory" then
      options[key] = value
    end
  end
  local scene = LegendEventScene.new(options)
  if modelFactory ~= nil then
    scene:setModelFactory(modelFactory)
  end
  return scene, audio, actors
end

local function lanceScene()
  local definition = lanceDefinition()
  return sceneWith({ lance_departure = definition }, {
    departureFactory = function()
      return LanceDepartureEffect.new({
        model = lanceModelHandle(),
        clipIds = definition.clipIds,
        trainerFrameDurations = definition.trainerFrameDurations,
        screenOffset = { x = 2, z = 4 },
      })
    end,
  })
end

local function drive(scene, limit)
  local outcomes = {}
  for _ = 1, limit do
    scene:updatePresentation()
    local outcome = scene:step()
    outcomes[#outcomes + 1] = outcome
    if outcome == "complete" then
      return outcomes
    end
  end
  error("the scene did not complete inside " .. tostring(limit) .. " ticks", 0)
end

-- The real animation owner rejects overlapping phase kinds. This scenario
-- drives intro, child, loop completion and end through actual attachments,
-- with three different loop durations so no scalar modulo can stand in for
-- the channels' own positions.
function T.wing_phase_handoffs_replace_real_attachments_and_finish_each_loop_channel()
  local specs = {
    { id = "intro.joint", phase = "intro", category = "joint", kind = "trs", frames = 2 },
    { id = "intro.srt", phase = "intro", category = "material", kind = "texsrt", frames = 2 },
    { id = "intro.color", phase = "intro", category = "material", kind = "color", frames = 2 },
    { id = "loop.joint", phase = "loop", category = "joint", kind = "trs", frames = 3 },
    { id = "loop.srt", phase = "loop", category = "material", kind = "texsrt", frames = 5 },
    { id = "loop.color", phase = "loop", category = "material", kind = "color", frames = 4 },
    { id = "end.joint", phase = "end", category = "joint", kind = "trs", frames = 2 },
    { id = "end.srt", phase = "end", category = "material", kind = "texsrt", frames = 3 },
    { id = "end.color", phase = "end", category = "material", kind = "color", frames = 2 },
  }
  local animations, phases = {}, {}
  for _, spec in ipairs(specs) do
    animations[#animations + 1] = {
      id = spec.id,
      name = spec.id,
      category = spec.category,
      kind = spec.kind,
      frameCount = spec.frames,
      tracks = { { target = spec.category == "joint" and 0 or "surface" } },
      semanticNames = {},
      compiled = {},
    }
    local phase = phases[spec.phase] or { ids = {}, frames = 0, frameCounts = {} }
    phase.ids[#phase.ids + 1] = spec.id
    phase.frames = math.max(phase.frames, spec.frames)
    phase.frameCounts[spec.id] = spec.frames
    phases[spec.phase] = phase
  end
  local definition = ModelDefinition.new({
    key = "fixture:wing",
    nodes = { { index = 0 } },
    meshes = { { id = 0, nodeIndex = 0, materialIndex = 0 } },
    materials = { {
      id = 0,
      name = "surface",
      alphaMode = "opaque",
      baseColor = { r = 255, g = 255, b = 255, a = 255 },
      polygonAlpha = 255,
    } },
    animations = animations,
  })
  local instance = ModelInstance.new(definition)
  local disposed = 0
  local handle = {}
  function handle:play(id, opts)
    return instance:play(id, opts)
  end
  function handle:stop(play)
    return instance:stop(play)
  end
  function handle:updateFixed()
    instance:updateFixed()
  end
  function handle:dispose()
    disposed = disposed + 1
  end
  local scene = sceneWith({ legend_wing = {
    parts = { { model = { key = definition.key }, clips = phases } },
  } }, { modelFactory = function() return handle end })

  local function activeIds()
    local ids = {}
    for _, category in ipairs({ "joint", "material" }) do
      for _, attachment in ipairs(instance.animationState:attachments(category)) do
        ids[#ids + 1] = attachment.clip.id
      end
    end
    table.sort(ids)
    return ids
  end

  scene:begin("wing", { kind = 0 })
  Assert.equal(scene:step(), "wait", "the wing claims its model")
  for _ = 1, 2 do
    scene:updatePresentation()
  end
  Assert.equal(scene:step(), "child", "the bounded intro hands off to the loop and map child")
  Assert.deepEqual(activeIds(), { "loop.color", "loop.joint", "loop.srt" }, "only loop attachments remain")
  for _, attachment in ipairs(instance.animationState:attachments("joint")) do
    Assert.equal(attachment.player.loopMode, "loop")
  end

  for _ = 1, 7 do
    scene:updatePresentation()
  end
  scene:childComplete()
  for _ = 1, 2 do
    scene:updatePresentation()
  end
  Assert.equal(scene:step(), "wait", "the shortest loop channel is done but the others are not")
  Assert.equal(scene._active.phase, "loop")
  for _ = 1, 2 do
    scene:updatePresentation()
  end
  Assert.equal(scene:step(), "wait", "all channels finished before the end phase attaches")
  Assert.deepEqual(activeIds(), { "end.color", "end.joint", "end.srt" }, "only end attachments remain")
  for _, category in ipairs({ "joint", "material" }) do
    for _, attachment in ipairs(instance.animationState:attachments(category)) do
      Assert.equal(attachment.player.loopMode, "once", "end channels are bounded one-shots")
    end
  end
  local outcome
  repeat
    scene:updatePresentation()
    outcome = scene:step()
  until outcome == "complete"
  Assert.equal(outcome, "complete")
  Assert.equal(disposed, 1, "the real model handle releases after the end clips")
end

function T.the_wing_effect_runs_intro_then_requests_its_child_before_the_loop_and_end()
  local models = {}
  local scene, audio = sceneWith(
    { legend_wing = wingDefinition() },
    {
      modelFactory = function(_, part)
        local model = fakeModel(part)
        models[#models + 1] = model
        return model
      end,
    }
  )
  scene:begin("wing", { kind = 0 })
  scene:step()
  Assert.equal(audio.played[1], "SEQ_SE_GS_STOPPERKAIJO", "the source wing sound plays on load")
  local outcomes = {}
  for _ = 1, 40 do
    scene:updatePresentation()
    local outcome = scene:step()
    outcomes[#outcomes + 1] = outcome
    if outcome == "child" then
      break
    end
  end
  Assert.equal(outcomes[#outcomes], "child", "the loop phase asks for the map child")
  local scriptId = scene:childScriptId()
  Assert.equal(scriptId, "vanilla.hgss.scr_seq.0019.script_002", "the child is the map's own entry 2")
  Assert.equal(models[1].plays[1].name, "intro.joint", "the intro clip plays first")
  Assert.isFalse(models[1].plays[1].loop == true, "the intro clip is a one-shot")
  scene:childComplete()
  Assert.isNil(scene:childScriptId(), "the child request is taken exactly once")
  local rest = drive(scene, 40)
  Assert.equal(rest[#rest], "complete")
  local loopPlays = 0
  for _, play in ipairs(assert(models[1], "the wing claims its source part").plays) do
    if play.loop == true then
      loopPlays = loopPlays + 1
    end
  end
  Assert.equal(loopPlays, 1, "the loop clip plays once and loops")
  Assert.equal(models[1].disposed, 1, "the wing model is released at the end clip")
end

-- A child that returns mid-loop resumes at the loop's next real boundary,
-- never with a fresh full cycle. Independently derived: loop length 4, child
-- durations 1..3 leave remainders 3..1, and a multi-cycle child wraps by modulo.
function T.a_mid_loop_child_return_finishes_at_the_next_loop_boundary()
  for _, childTicks in ipairs({ 1, 2, 3, 6 }) do
    local scene = sceneWith({ legend_wing = wingDefinition() }, {
      modelFactory = function(_, part)
        return fakeModel(part)
      end,
    })
    scene:begin("wing", { kind = 0 })
    scene:step()
    local outcome
    for _ = 1, 10 do
      scene:updatePresentation()
      outcome = scene:step()
      if outcome == "child" then
        break
      end
    end
    Assert.equal(outcome, "child", "the loop phase asks for the map child")
    for _ = 1, childTicks do
      scene:updatePresentation()
    end
    scene:childComplete()
    local loopFrames = 4
    local expectedRemaining = (loopFrames - (childTicks % loopFrames)) % loopFrames
    -- When the child returns exactly on a boundary the loop just finished:
    -- the next step switches to end after one advance. Count post-child steps
    -- until the end clip plays.
    local steps = 0
    local outcome
    repeat
      scene:updatePresentation()
      outcome = scene:step()
      steps = steps + 1
      assert(steps < 20, "the loop must finish at its next boundary")
    until outcome == "complete" or steps > 15
    -- Total post-child steps = remaining loop ticks + end ticks (2).
    -- The key invariant: a halfway return never costs a full extra cycle.
    local expectedLoopTicks = expectedRemaining == 0 and 1 or expectedRemaining
    Assert.isTrue(steps <= expectedLoopTicks + 3, "mid-loop return " .. childTicks .. " finishes without a fresh cycle")
    if childTicks < loopFrames then
      Assert.equal(steps, (loopFrames - childTicks) + 2, "child duration " .. childTicks .. " leaves the exact remainder")
    end
  end
end

function T.the_wing_effect_uses_the_soulsilver_model_for_its_second_kind()
  local scenes = {}
  local scene = sceneWith({ legend_wing = wingDefinition() }, {
    modelFactory = function(kind, _, index)
      scenes[#scenes + 1] = { kind = kind, index = index }
      return fakeModel()
    end,
  })
  scene:begin("wing", { kind = 1 })
  scene:step()
  Assert.equal(scenes[1].kind, "legend_wing")
  Assert.equal(scenes[1].index, 2, "the second source kind claims the second wing model")
end

function T.a_cancelled_wing_effect_releases_its_model_and_publishes_nothing()
  local models = {}
  local scene = sceneWith({ legend_wing = wingDefinition() }, {
    modelFactory = function(_, _, index)
      local model = fakeModel()
      models[index] = model
      return model
    end,
  })
  scene:begin("wing", { kind = 0 })
  scene:step()
  scene:cancel("the scene is cancelled")
  scene:cancel("again")
  Assert.isFalse(scene:isRunning(), "a cancelled scene owns nothing")
  Assert.equal(models[1].disposed, 1, "cancellation releases the presented model exactly once")
  Assert.isNil(scene:takeResult(), "a cancelled scene publishes no result")
end

function T.a_missing_source_asset_faults_before_the_scene_claims_anything()
  local scene = sceneWith({}, { modelFactory = function() error("must not be called") end })
  local err = Assert.throws(function()
    scene:begin("wing", { kind = 0 })
  end)
  Assert.isTrue(Errors.is(err), "the missing asset is a structured fault")
  Assert.equal(err.code, "FIELD_LEGEND_EFFECT_SOURCE_MISSING")
  Assert.isFalse(scene:isRunning(), "nothing was claimed")
end

function T.lance_departure_runs_the_fly_with_object_steps_and_clears_offsets()
  local scene, audio, actors = lanceScene()
  actors.ids[8] = "map:88:object:8"
  actors.ids[10] = "map:88:object:10"
  scene:begin("lance_departure", { first = 8, second = 10 })
  local seen = {}
  local outcomes = {}
  local sawTrainer, sawModel, sawFlyer = false, false, false
  for _ = 1, 120 do
    scene:updatePresentation()
    local outcome = scene:step()
    outcomes[#outcomes + 1] = outcome
    local active = scene._active
    local phase = active ~= nil and active.phase or "complete"
    seen[#seen + 1] = phase
    local departure = scene:presentation().departure
    sawTrainer = sawTrainer or (departure ~= nil and departure.trainer.visible)
    sawModel = sawModel or (departure ~= nil and departure.model ~= nil)
    sawFlyer = sawFlyer or (departure ~= nil and departure.flyer ~= nil and departure.flyer.visible)
    if phase == "wait_before_pickup" then
      Assert.isNil(departure.flyer, "the flyer does not exist during the source pickup wait")
      Assert.equal((actors.offsets["map:88:object:8"] or {}).y or 0, 0, "the wait never invents actor lift")
    end
    if outcome == "complete" then
      break
    end
  end
  Assert.equal(outcomes[#outcomes], "complete", "the cut-in finishes through its own steps")
  Assert.equal(audio.played[#audio.played], LegendEventScene.LANCE_FLY_SOUND, "fly-away plays its source sound at status 3")
  local pickupTicks = 0
  for _, phase in ipairs(seen) do
    if phase == "wait_before_pickup" then
      pickupTicks = pickupTicks + 1
    end
  end
  Assert.equal(pickupTicks, LegendEventScene.LANCE_PICKUP_WAIT_TICKS, "pickup waits the source 20 ticks")
  Assert.isTrue(sawTrainer, "the trainer sprite is actually presented")
  Assert.isTrue(sawModel, "the Dragonite model effect is actually presented")
  Assert.isTrue(sawFlyer, "the flyer effect is actually presented")
  Assert.isTrue(actors.hidden["map:88:object:10"], "the source Dragonite object yields to the model effect")
  Assert.equal(actors.offsets["map:88:object:8"].y, 0, "completion leaves no actor offset")
  Assert.equal(actors.offsets["map:88:object:10"].y, 0, "completion leaves no Dragonite offset")
end

function T.lance_departure_offsets_from_the_departing_trainer_not_the_dragonite()
  local captured
  local definition = lanceDefinition()
  local scene, _, actors = sceneWith({ lance_departure = definition }, {
    departureFactory = function(_, positions)
      captured = positions
      return LanceDepartureEffect.new({
        model = lanceModelHandle(),
        clipIds = definition.clipIds,
        trainerFrameDurations = definition.trainerFrameDurations,
        screenOffset = LanceDepartureEffect.screenOffsetFor(positions.player, positions.lance),
      })
    end,
  })
  actors.ids[8] = "map:88:object:8"
  actors.ids[10] = "map:88:object:10"
  scene:begin("lance_departure", { first = 8, second = 10 })
  Assert.deepEqual(
    captured.lance,
    { x = 6, y = 0, z = 7 },
    "the cut-in keeps the departing trainer's world position"
  )
  Assert.deepEqual(
    captured.dragonite,
    { x = 8, y = 0, z = 10 },
    "the Dragonite keeps its own world position"
  )
  local expected = LanceDepartureEffect.screenOffsetFor(captured.player, captured.lance)
  Assert.deepEqual(expected, { x = (6 - 4) * 8, z = (7 - 6) * 16 }, "the sprite offset is Lance-relative")
  local trainer = scene:presentation().departure.trainer
  Assert.equal(trainer.x, 128 + expected.x, "the trainer sprite starts from the Lance offset")
  Assert.equal(trainer.y, 320 + expected.z, "the trainer sprite starts from the Lance offset")
  scene:cancel("cleanup")
end

function T.a_missing_departure_object_is_an_attributed_fault()
  local scene = sceneWith({})
  local err = Assert.throws(function()
    scene:begin("lance_departure", { first = 8, second = 10 })
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "FIELD_LEGEND_SCENE_ACTOR_MISSING")
end

function T.a_cancelled_departure_restores_both_actor_offsets()
  local scene, _, actors = lanceScene()
  actors.ids[8] = "lance"
  actors.ids[10] = "dragonite"
  scene:begin("lance_departure", { first = 8, second = 10 })
  for _ = 1, 12 do
    scene:updatePresentation()
    scene:step()
  end
  Assert.isTrue(actors.hidden.dragonite, "the model effect owns the hidden source object before cancel")
  scene:cancel("cancelled")
  Assert.isFalse(actors.hidden.dragonite, "cancellation restores the source object")
  Assert.equal(actors.offsets.lance.y, 0, "the cancelled take-off returns Lance to his tile")
  Assert.equal(actors.offsets.dragonite.y, 0, "the cancelled take-off returns the Dragonite to its tile")
end

function T.the_unown_circle_waits_its_two_source_intervals_between_white_fades()
  local definitions = {
    sinjoh_unown = {
      parts = {
        { model = { key = "unown-0" }, clips = { joint = clip(2), material = clip(2) } },
        { model = { key = "unown-1" }, clips = { joint = clip(2), material = clip(2) } },
        { model = { key = "arceus" }, clips = { joint = clip(2), material = clip(2) } },
      },
    },
  }
  local fades = {}
  local screen = { active = false }
  function screen:startFade(spec)
    fades[#fades + 1] = spec
    self.active = true
  end
  function screen:fadeDone()
    self.active = false
    return true
  end
  local models = 0
  local scene = sceneWith(definitions, {
    screen = screen,
    modelFactory = function()
      models = models + 1
      return fakeModel()
    end,
  })
  scene:begin("unown_circle", {})
  local ticks = #drive(scene, 600)
  Assert.equal(models, 3, "the circle claims its two Unown models and the Arceus object")
  Assert.equal(
    ticks,
    LegendEventScene.WHITE_FADE_STEPS + LegendEventScene.UNOWN_ANIMATE_TICKS + LegendEventScene.ARCEUS_OBJECT_TICKS + 2,
    "the circle waits its own fade, 100-tick and 150-tick intervals"
  )
  Assert.equal(#fades, 3, "the circle opens and closes on the source white covers")
  Assert.equal(fades[1].color, "white", "the circle's covers are white")
end

function T.the_egg_cutscene_waits_for_every_source_animation_record()
  local definitions = {
    sinjoh_egg = {
      parts = {
        { model = { key = "egg-0" }, clips = { all = clip(5) } },
        { model = { key = "egg-1" }, clips = { all = clip(5) } },
        { model = { key = "egg-2" }, clips = { all = clip(5) } },
      },
    },
  }
  local screen = { active = false }
  function screen:startFade(spec)
    self.active = spec ~= nil
  end
  function screen:fadeDone()
    self.active = false
    return true
  end
  local scene = sceneWith(definitions, { screen = screen, modelFactory = function() return fakeModel() end })
  scene:begin("egg_cutscene", { choice = 2 })
  local ticks = #drive(scene, 100)
  Assert.equal(
    ticks,
    LegendEventScene.WHITE_FADE_STEPS + 5 + 1,
    "the egg cutscene completes only after its four-record animation"
  )
end

function T.the_arceus_montage_executes_the_closed_timeline_and_selects_its_layers()
  local scene, audio = sceneWith({ arceus_cinematic = montageDefinition() })
  scene:begin("arceus_cinematic", { kind = 2 })
  local presentation
  local outcomes = {}
  for _ = 1, 40 do
    local outcome = scene:step()
    outcomes[#outcomes + 1] = outcome
    local current = scene:presentation()
    if current.cinematic ~= nil then
      presentation = current
    end
    if outcome == "complete" then
      break
    end
  end
  Assert.equal(outcomes[#outcomes], "complete", "the montage runs to its source END command")
  Assert.equal(presentation.cinematic.layers[0], "assets/generated/field/effects/textures/aa.png")
  Assert.isTrue(presentation.cinematic.sprite.visible, "the source sprite became visible on its command")
  Assert.equal(presentation.cinematic.sprite.x, 128, "the sprite keeps its source position")
  Assert.deepEqual(audio.music, { "SEQ_GS_E_ARCEUS" }, "the montage plays its own BGM")
  Assert.equal(audio.stopped, 0, "the timeline never stops the music it saved")
end

function T.a_cinematic_scene_other_than_the_arceus_montage_is_refused()
  local scene = sceneWith({ arceus_cinematic = montageDefinition() })
  local err = Assert.throws(function()
    scene:begin("arceus_cinematic", { kind = 0 })
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "FIELD_LEGEND_SCENE_UNSUPPORTED")
end

function T.a_running_scene_is_not_stable_for_save_and_a_settled_one_is()
  local scene = sceneWith({ legend_wing = wingDefinition() }, { modelFactory = function() return fakeModel() end })
  Assert.isTrue(scene:isStableForSave(), "an idle field is stable")
  scene:begin("wing", { kind = 0 })
  Assert.isFalse(scene:isStableForSave(), "a running scene owns a presentation")
  scene:cancel("done")
  Assert.isTrue(scene:isStableForSave(), "a cancelled scene returns the field")
end

function T.a_second_scene_cannot_steal_the_field_from_a_running_one()
  local scene = sceneWith({ legend_wing = wingDefinition() }, { modelFactory = function() return fakeModel() end })
  scene:begin("wing", { kind = 0 })
  local err = Assert.throws(function()
    scene:begin("wing", { kind = 0 })
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "FIELD_LEGEND_SCENE_BUSY")
end

return { metadata = {}, tests = T }
