-- The legendary-story scene owner: the wing effect's begin/loop/end clips and
-- its map-child handoff, Lance's departure actor resolution, the Sinjoh Unown
-- circle and egg cutscene tick boundaries, the Arceus montage timeline, the
-- missing-source-asset fault and the exact-once cancellation cleanup.
-- Source reference: src/field/script_field_effects.c,
-- src/field/event_cutscene_sinjoh.c and src/application/arceus_cinematic.c.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local LegendEventScene = require("libs.hgss.src.field.LegendEventScene")

local T = {}

local ARCEUS = LegendEventScene.ARCEUS_COMMANDS

local function fakeModel()
  local model = { plays = {}, disposed = 0, ticks = 0 }
  function model:play(name, opts)
    self.plays[#self.plays + 1] = { name = name, loop = opts ~= nil and opts.loopMode == "loop" }
  end
  function model:updateFixed()
    self.ticks = self.ticks + 1
  end
  function model:dispose()
    self.disposed = self.disposed + 1
  end
  return model
end

local function clip(frames)
  return { ids = { "joint.trs" }, frames = frames }
end

local function wingDefinition()
  return {
    sound = "SEQ_SE_GS_STOPPERKAIJO",
    parts = {
      { model = { key = "part-0" }, clips = { intro = clip(3), loop = clip(4), ["end"] = clip(2) } },
      { model = { key = "part-1" }, clips = { intro = clip(3), loop = clip(4), ["end"] = clip(2) } },
    },
  }
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
  local actors = { offsets = {}, ids = {} }
  function actors:actorIdForMapIndex(index)
    return self.ids[index]
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

local function drive(scene, limit)
  local outcomes = {}
  for _ = 1, limit do
    local outcome = scene:step()
    outcomes[#outcomes + 1] = outcome
    if outcome == "complete" then
      return outcomes
    end
  end
  error("the scene did not complete inside " .. tostring(limit) .. " ticks", 0)
end

function T.the_wing_effect_runs_intro_then_requests_its_child_before_the_loop_and_end()
  local models = {}
  local scene, audio = sceneWith(
    { legend_wing = wingDefinition() },
    {
      modelFactory = function()
        local model = fakeModel()
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
    local outcome = scene:step()
    outcomes[#outcomes + 1] = outcome
    if outcome == "child" then
      break
    end
  end
  Assert.equal(outcomes[#outcomes], "child", "the loop phase asks for the map child")
  local scriptId = scene:childScriptId()
  Assert.equal(scriptId, "vanilla.hgss.scr_seq.0019.script_002", "the child is the map's own entry 2")
  Assert.equal(models[1].plays[1].name, "joint.trs", "the intro clip plays first")
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

function T.lance_departure_resolves_both_source_objects_and_lifts_them_until_the_fly_ends()
  local scene, _, actors = sceneWith({})
  actors.ids[8] = "map:88:object:8"
  actors.ids[10] = "map:88:object:10"
  scene:begin("lance_departure", { first = 8, second = 10 })
  local outcomes = drive(scene, 40)
  Assert.equal(#outcomes, LegendEventScene.LANCE_FLY_STEPS, "the take-off runs the source step count")
  Assert.equal(actors.offsets["map:88:object:8"].y, LegendEventScene.LANCE_FLY_STEPS * LegendEventScene.LANCE_FLY_LIFT_PER_STEP)
  Assert.notNil(actors.offsets["map:88:object:10"], "the Dragonite object takes off beside Lance")
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
  local scene, _, actors = sceneWith({})
  actors.ids[8] = "lance"
  actors.ids[10] = "dragonite"
  scene:begin("lance_departure", { first = 8, second = 10 })
  scene:step()
  Assert.equal(actors.offsets.lance.y, LegendEventScene.LANCE_FLY_LIFT_PER_STEP)
  scene:cancel("cancelled")
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
