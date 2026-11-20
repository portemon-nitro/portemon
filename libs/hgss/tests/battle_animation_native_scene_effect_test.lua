-- Owner tests for the interpreter's synchronous scene effects: every
-- source visual operation applies its concrete main/sub engine state in
-- its own quantum through the narrow scene seam instead of succeeding
-- as a journal entry. A recording double stands in for the scene seam;
-- the real BattleScene owns the sprite registry transitions.

local Assert = require("tests.support.Assert")
local BattleAnimationPlayer = require("libs.hgss.src.presentation.BattleAnimationPlayer")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")

local T = {}

local function recordingScene()
  local calls = {}
  local scene = {}
  function scene.writeAnimationPlane(_self, owner, engine, plane, patch)
    calls[#calls + 1] = { method = "writeAnimationPlane", owner = owner, engine = engine, plane = plane, patch = patch }
  end
  function scene.writeAnimationCompositor(_self, owner, engine, patch)
    calls[#calls + 1] = { method = "writeAnimationCompositor", owner = owner, engine = engine, patch = patch }
  end
  function scene.writeBattlerAnimation(_self, owner, activation, patch)
    calls[#calls + 1] = { method = "writeBattlerAnimation", owner = owner, activation = activation, patch = patch }
  end
  function scene.restorePictureState(_self, activation)
    calls[#calls + 1] = { method = "restorePictureState", activation = activation }
  end
  function scene.resetBlendCoefficients(_self)
    calls[#calls + 1] = { method = "resetBlendCoefficients" }
  end
  function scene.applyTaskScalarPatch(_self, owner, patch)
    calls[#calls + 1] = { method = "applyTaskScalarPatch", owner = owner, patch = patch }
  end
  function scene.setAnimationSpriteDrawFlag(_self, slot, draw)
    calls[#calls + 1] = { method = "setAnimationSpriteDrawFlag", slot = slot, draw = draw }
  end
  function scene.setAnimationSpritePriority(_self, slot, priority)
    calls[#calls + 1] = { method = "setAnimationSpritePriority", slot = slot, priority = priority }
  end
  function scene.startAnimationSpriteDraw(_self, loopIndex, slot)
    calls[#calls + 1] = { method = "startAnimationSpriteDraw", loopIndex = loopIndex, slot = slot }
  end
  function scene.stopAnimationSpriteDraw(_self, loopIndex)
    calls[#calls + 1] = { method = "stopAnimationSpriteDraw", loopIndex = loopIndex }
  end
  function scene.pictureState(_self, activation)
    calls[#calls + 1] = { method = "pictureState", activation = activation }
    return nil
  end
  function scene.stopAnimationSpriteFollow(_self, slot)
    calls[#calls + 1] = { method = "stopAnimationSpriteFollow", slot = slot }
  end
  function scene.setAnimationSpriteManager(_self, name, present)
    calls[#calls + 1] = { method = "setAnimationSpriteManager", name = name, present = present }
  end
  return scene, calls
end

local function collaborators(scene)
  local audio = {}
  function audio.play(_name) end
  function audio.stop(_name) end
  function audio.isFinished(_name)
    return true
  end
  local tasks = {}
  function tasks.create(kind, _args, _context, _services)
    error("scene effect programs spawn no tasks for kind " .. tostring(kind), 0)
  end
  local resources = {}
  function resources.resolve(key)
    return { key = key, lease = key }
  end
  function resources.release(_lease) end
  return { scene = scene, audio = audio, tasks = tasks, resources = resources }
end

local function packet()
  return {
    launchId = "scene-effect-probe",
    packetId = 1,
    topology = {
      attacker = { combatant = 1, activation = 1, slot = "solo-player", sideType = 0 },
      targets = { { combatant = 3, activation = 3, slot = "solo-enemy", sideType = 1 } },
    },
  }
end

local function programOf(instructions)
  return { entry = "main", instructions = instructions, subprograms = {}, taskKinds = {} }
end

local function runToCompletion(instructions, scene)
  local helpers = collaborators(scene or recordingScene())
  local actualScene = helpers.scene
  local player = assert(BattleAnimationPlayer.new({
    scene = actualScene,
    audio = helpers.audio,
    resources = helpers.resources,
    tasks = helpers.tasks,
    services = { onNativeFrame = function() end },
  }))
  local handle = assert(player:start(packet(), programOf(instructions)))
  for _ = 1, 20 do
    player:stepSourceTick({ tick = 1 })
    if player:status(handle) == "complete" then
      break
    end
  end
  return player, handle
end

local function planeCalls(calls)
  local found = {}
  for _, call in ipairs(calls) do
    if call.method == "writeAnimationPlane" then
      found[#found + 1] = call
    end
  end
  return found
end

local function compositorCalls(calls, engine)
  local found = {}
  for _, call in ipairs(calls) do
    if call.method == "writeAnimationCompositor" and (engine == nil or call.engine == engine) then
      found[#found + 1] = call
    end
  end
  return found
end

function T.plane_clears_apply_synchronously_on_their_quantum()
  local scene, calls = recordingScene()
  local player, handle = runToCompletion({
    { op = "interpreter-wait", values = { 1 } },
    { op = "clear-background-plane", values = { 2 } },
    { op = "reset-blend-alpha" },
  }, scene)
  Assert.equal(player:status(handle), "complete", "the plane program completes")
  local planes = planeCalls(calls)
  Assert.equal(#planes, 1, "the clear writes exactly one plane binding")
  Assert.equal(planes[1].engine, "main", "the battler plane clears on the main engine")
  Assert.equal(planes[1].plane, "bg2", "the clear names the battler plane")
  Assert.isTrue(planes[1].patch.cleared == true, "the binding records the clear")
end

function T.plane_clears_land_on_their_precise_source_tick()
  local scene, calls = recordingScene()
  local helpers = collaborators(scene)
  local player = assert(BattleAnimationPlayer.new({
    scene = helpers.scene,
    audio = helpers.audio,
    resources = helpers.resources,
    tasks = helpers.tasks,
    services = { onNativeFrame = function() end },
  }))
  local handle = assert(player:start(
    packet(),
    programOf({
      { op = "interpreter-wait", values = { 2 } },
      { op = "clear-background-plane", values = { 2 } },
      { op = "reset-blend-alpha" },
    })
  ))
  -- A positive Wait(N) resumes its chain at T+N+2: the parking tick plus
  -- N decrements and one runner-only switch tick.
  for tick = 1, 4 do
    player:stepSourceTick({ tick = tick })
    Assert.equal(#planeCalls(calls), 0, "the plane stays set before its source tick: tick " .. tick)
  end
  player:stepSourceTick({ tick = 5 })
  Assert.equal(#planeCalls(calls), 1, "the plane clears on its precise source tick")
  player:stepSourceTick({ tick = 6 })
  Assert.equal(player:status(handle), "complete", "the program completes after its clear")
end

function T.sub_screen_blends_land_on_the_sub_engine()
  local scene, calls = recordingScene()
  local player, handle = runToCompletion({
    { op = "set-blend-alpha", values = { 8, 12 } },
    { op = "reset-blend-alpha" },
  }, scene)
  Assert.equal(player:status(handle), "complete", "the blend program completes")
  local sub = compositorCalls(calls, "sub")
  Assert.equal(#sub, 1, "the blend writes the sub-engine compositor once")
  -- Native SetSubScreenBlend carries absolute plane masks (first BG0,
  -- second BG1) through the same consumed blend contract the menu
  -- defaults ride, never a side channel the renderer ignores.
  Assert.deepEqual(
    sub[1].patch.blend,
    { mode = "alpha", eva = 8, evb = 12, evy = 0 },
    "the sub-engine records the native blend coefficients"
  )
  Assert.deepEqual(sub[1].patch.firstTarget, { menu = true }, "the first target names BG0")
  Assert.deepEqual(sub[1].patch.secondTarget, { window = true }, "the second target names BG1")
end

function T.background_scroll_components_select_their_register()
  local scene, calls = recordingScene()
  local player, handle = runToCompletion({
    { op = "set-background-component", values = { 0, 5 } },
    { op = "set-background-component", values = { 1, -3 } },
    { op = "set-background-component", values = { 2, 9 } },
    { op = "set-background-component", values = { 9, 9 } },
    { op = "reset-blend-alpha" },
  }, scene)
  Assert.equal(player:status(handle), "complete", "the scroll program completes")
  local main = compositorCalls(calls, "main")
  Assert.equal(#main, 3, "known components write; unknown components journal without writing")
  Assert.equal(main[1].patch.bgScrollDx, 5, "component zero drives the delta-x register")
  Assert.equal(main[2].patch.bgScrollDy, -3, "component one drives the delta-y register")
  Assert.equal(main[3].patch.bgScrollX, 9, "component two drives the position register")
end

function T.palette_operations_land_on_the_main_engine()
  local scene, calls = recordingScene()
  local player, handle = runToCompletion({
    { op = "copy-main-background-palette-to-fade-buffer" },
    { op = "grayscale-main-background-fade-buffer" },
    { op = "reset-blend-alpha" },
  }, scene)
  Assert.equal(player:status(handle), "complete", "the palette program completes")
  local main = compositorCalls(calls, "main")
  -- The fade-buffer copy journals without scene state (every plane
  -- re-derives from source art); the grayscale apply is the
  -- pixel-affecting half the compositor consumes.
  Assert.equal(#main, 1, "only the grayscale apply writes the main engine")
  Assert.isTrue(main[1].patch.paletteGrayscale == true, "the grayscale flags the fade buffer")
end

function T.presentation_layouts_write_and_restore_the_attacker_picture()
  local scene, calls = recordingScene()
  local player, handle = runToCompletion({
    { op = "submit-presentation-layout", values = { 2 } },
    { op = "submit-presentation-update", values = { 2 } },
    { op = "reset-blend-alpha" },
  }, scene)
  Assert.equal(player:status(handle), "complete", "the layout program completes")
  local writes = {}
  local restores = {}
  for _, call in ipairs(calls) do
    if call.method == "writeBattlerAnimation" then
      writes[#writes + 1] = call
    elseif call.method == "restorePictureState" then
      restores[#restores + 1] = call
    end
  end
  Assert.equal(#writes, 1, "the layout writes the attacker picture once")
  Assert.equal(writes[1].activation.combatant, 1, "the layout addresses the attacker")
  Assert.equal(writes[1].patch.layoutMode, 2, "the layout records the picture selector")
  Assert.equal(#restores, 1, "the update restores the attacker picture once")
  Assert.equal(restores[1].activation.combatant, 1, "the restore addresses the attacker")
end

function T.vanished_pictures_resolve_their_named_sets()
  local scene, calls = recordingScene()
  local player, handle = runToCompletion({
    {
      op = "set-pokemon-picture-vanished",
      vanished = true,
      pictureSets = { "active-battler", "opposing-battler" },
    },
    {
      op = "set-pokemon-picture-vanished",
      vanished = false,
      pictureSets = { "all-battler-positions" },
    },
    { op = "reset-blend-alpha" },
  }, scene)
  Assert.equal(player:status(handle), "complete", "the vanish program completes")
  local writes = {}
  for _, call in ipairs(calls) do
    if call.method == "writeBattlerAnimation" then
      writes[#writes + 1] = call
    end
  end
  Assert.equal(#writes, 4, "each named battler receives its own vanish write")
  Assert.equal(writes[1].activation.combatant, 1, "the active set names the attacker")
  Assert.isTrue(writes[1].patch.vanished == true, "the first wave vanishes")
  Assert.equal(writes[2].activation.combatant, 3, "the opposing set names the target")
  Assert.isTrue(
    writes[3].patch.vanished == false and writes[4].patch.vanished == false,
    "the all-positions wave restores"
  )
end

function T.sprite_draw_flags_and_follows_record_their_slots()
  local scene, calls = recordingScene()
  local player, handle = runToCompletion({
    { op = "set-managed-sprite-draw-flag", values = { 2, 0 } },
    { op = "clear-effect-slot", values = { 2 } },
    { op = "destroy-effect-slot", values = { 3 } },
    { op = "reset-blend-alpha" },
  }, scene)
  Assert.equal(player:status(handle), "complete", "the sprite program completes")
  local flags = {}
  local stops = {}
  local follows = {}
  for _, call in ipairs(calls) do
    if call.method == "setAnimationSpriteDrawFlag" then
      flags[#flags + 1] = call
    elseif call.method == "stopAnimationSpriteDraw" then
      stops[#stops + 1] = call
    elseif call.method == "stopAnimationSpriteFollow" then
      follows[#follows + 1] = call
    end
  end
  Assert.equal(#flags, 1, "the explicit visibility write records its flag")
  Assert.equal(flags[1].slot, 2, "the explicit flag names its slot")
  Assert.isTrue(flags[1].draw == false, "a zero flag hides the sprite")
  Assert.equal(#stops, 1, "the effect clear stops its draw loop")
  Assert.equal(stops[1].loopIndex, 2, "the stop names its source loop index")
  Assert.equal(#follows, 1, "the effect destroy stops its follow binding")
  Assert.equal(follows[1].slot, 3, "the destroy names its slot")
end

function T.sprite_managers_record_their_lifetime_by_name()
  local scene = BattleScene.new()
  local player, handle = runToCompletion({
    { op = "create-sprite-manager", values = { 1, 4, 0, 0, 0, 0, 0, 0 } },
    { op = "create-managed-sprite-manager" },
    { op = "dispose-sprite-manager", values = { 1 } },
    { op = "dispose-shared-sprite-manager" },
    { op = "reset-blend-alpha" },
  }, scene)
  Assert.equal(player:status(handle), "complete", "the manager program completes")
  Assert.isTrue(scene:animationSpriteManagerPresent("manager-1") == false, "the disposed indexed manager reads absent")
  Assert.isTrue(
    scene:animationSpriteManagerPresent("battler-sprite-manager") == false,
    "the disposed battler manager reads absent"
  )
end

function T.brightness_transitions_cover_both_engines()
  local scene, calls = recordingScene()
  local player, handle = runToCompletion({
    { op = "start-brightness-transition", values = { 6 } },
    { op = "reset-blend-alpha" },
  }, scene)
  Assert.equal(player:status(handle), "complete", "the brightness program completes")
  Assert.equal(#compositorCalls(calls, "main"), 1, "the main engine records the flash")
  Assert.equal(#compositorCalls(calls, "sub"), 1, "the sub engine records the flash")
  Assert.equal(compositorCalls(calls, "main")[1].patch.brightnessSteps, 6, "the flash carries its step count")
end

function T.unlowered_schema_operations_fail_closed()
  -- Operations no producer route emits never run silently: malformed
  -- shapes refuse admission, and well-shaped ones fail at runtime with
  -- their identity.
  for _, op in ipairs({ "set-sprite-draw-flag", "clear-sprite-slot", "clear-pokemon-picture" }) do
    local values = nil
    if op == "set-sprite-draw-flag" then
      values = { 1, 1 }
    elseif op == "clear-sprite-slot" then
      values = { 1 }
    end
    local scene = recordingScene()
    local helpers = collaborators(scene)
    local player = assert(BattleAnimationPlayer.new({
      scene = helpers.scene,
      audio = helpers.audio,
      resources = helpers.resources,
      tasks = helpers.tasks,
      services = { onNativeFrame = function() end },
    }))
    local instructions = values ~= nil and { { op = op, values = values } } or { { op = op } }
    local handle = player:start(packet(), programOf(instructions))
    if handle == nil then
      Assert.isTrue(true, op .. " refuses admission without a producer shape")
    else
      player:stepSourceTick({ tick = 1 })
      Assert.equal(player:status(handle), "failed", op .. " fails instead of succeeding silently")
      Assert.notNil(player:failure(handle), op .. " carries its failure detail")
    end
  end
end

function T.real_scene_registry_records_draw_and_manager_lifetimes()
  local scene = BattleScene.new()
  local player, handle = runToCompletion({
    { op = "set-managed-sprite-draw-flag", values = { 2, 1 } },
    { op = "create-sprite-manager", values = { 1, 4, 0, 0, 0, 0, 0, 0 } },
    { op = "destroy-effect-slot", values = { 2 } },
    { op = "reset-blend-alpha" },
  }, scene)
  Assert.equal(player:status(handle), "complete", "the registry program completes")
  local slot = assert(scene:animationSprite(2), "the flagged slot reads back")
  Assert.isTrue(slot.draw == true, "the slot records its draw flag")
  Assert.isTrue(slot.followStopped == true, "the slot records its stopped follow")
  Assert.isTrue(scene:animationSpriteManagerPresent("manager-1") == true, "the created manager reads present")
  Assert.isNil(scene:animationSprite(9), "unnamed slots read absent")
end

-- Doubles topology with explicit source battler types: attacker,
-- defender, and their partner rows when the side owns one.
local function doublesPacket(attackerSideType, defenderSideType)
  local attacker = { combatant = 1, activation = 1, slot = "a", sideType = attackerSideType }
  local defender = { combatant = 3, activation = 3, slot = "b", sideType = defenderSideType }
  local attackerPartner = attackerSideType % 2 == 0
      and { combatant = 2, activation = 2, slot = "a2", sideType = attackerSideType == 2 and 4 or 2 }
    or { combatant = 4, activation = 4, slot = "a2", sideType = attackerSideType == 3 and 5 or 3 }
  local defenderPartner = defenderSideType % 2 == 0
      and { combatant = 5, activation = 5, slot = "b2", sideType = defenderSideType == 2 and 4 or 2 }
    or { combatant = 6, activation = 6, slot = "b2", sideType = defenderSideType == 3 and 5 or 3 }
  return {
    launchId = "sprite-draw-probe",
    packetId = 1,
    topology = {
      attacker = attacker,
      defender = defender,
      attackerPartner = attackerPartner,
      defenderPartner = defenderPartner,
      targets = { defender },
      sourceBattlers = { attacker, attackerPartner, defender, defenderPartner },
    },
  }
end

local function runSpriteDraw(scene, playback, mode, loopIndex, slot)
  local helpers = collaborators(scene)
  local player = assert(BattleAnimationPlayer.new({
    scene = helpers.scene,
    audio = helpers.audio,
    resources = helpers.resources,
    tasks = helpers.tasks,
    services = { onNativeFrame = function() end },
  }))
  local handle = assert(player:start(playback, programOf({
    { op = "start-sprite-effect", mode = mode, values = { loopIndex, slot }, taskKind = "managed-sprite-draw-loop" },
    { op = "reset-blend-alpha" },
  })))
  for _ = 1, 8 do
    player:stepSourceTick({ tick = 1 })
    if player:status(handle) ~= "running" and player:status(handle) ~= "waiting" then
      break
    end
  end
  Assert.equal(player:status(handle), "complete", "the sprite draw program completes")
  return player
end

function T.singles_sprite_draw_keeps_the_copy_hidden()
  -- Native StartBattlerSpriteDraw clears the copy's draw flag and only
  -- the doubles branch re-shows it or creates the draw task, so a
  -- single battle's copy stays hidden.
  local scene = BattleScene.new()
  runSpriteDraw(scene, packet(), "first-battler-class-priority-gate", 0, 4)
  local slot = assert(scene:animationSprite(4), "the hidden slot reads back")
  Assert.isTrue(slot.draw == false, "the single-battle copy stays hidden")
  Assert.isNil(scene:animationSpriteDraw(0), "singles create no draw loop")
end

function T.doubles_sprite_draw_applies_the_native_role_priority_table()
  local cases = {
    {
      mode = "first-battler-class-priority-gate",
      attacker = 3,
      defender = 2,
      draw = true,
      priority = 1,
    },
    {
      mode = "first-battler-class-priority-gate",
      attacker = 4,
      defender = 2,
      draw = true,
      priority = 1,
    },
    {
      mode = "first-battler-class-priority-gate",
      attacker = 0,
      defender = 3,
      draw = false,
      priority = 255,
    },
    {
      mode = "first-battler-class-priority-alternate",
      attacker = 5,
      defender = 2,
      draw = true,
      priority = 1,
    },
    {
      mode = "first-battler-class-priority-alternate",
      attacker = 3,
      defender = 2,
      draw = false,
      priority = 255,
    },
    { mode = "second-battler-class-priority-forward", attacker = 2, defender = 2, draw = true, priority = 255 },
    { mode = "second-battler-class-priority-forward", attacker = 2, defender = 3, draw = true, priority = 1 },
    { mode = "second-battler-class-priority-forward", attacker = 2, defender = 4, draw = true, priority = 1 },
    { mode = "second-battler-class-priority-forward", attacker = 2, defender = 5, draw = true, priority = 255 },
    { mode = "second-battler-class-priority-reverse", attacker = 2, defender = 2, draw = true, priority = 1 },
    { mode = "second-battler-class-priority-reverse", attacker = 2, defender = 3, draw = true, priority = 255 },
    { mode = "second-battler-class-priority-reverse", attacker = 2, defender = 4, draw = true, priority = 255 },
    { mode = "second-battler-class-priority-reverse", attacker = 2, defender = 5, draw = true, priority = 1 },
    -- A defender type outside the source switch writes no priority at all:
    -- the slot keeps whatever it had and only the draw flag is decided.
    { mode = "second-battler-class-priority-forward", attacker = 2, defender = 0, draw = true, priority = nil },
    { mode = "second-battler-class-priority-reverse", attacker = 2, defender = 1, draw = true, priority = nil },
  }
  for _, case in ipairs(cases) do
    local scene = BattleScene.new()
    runSpriteDraw(scene, doublesPacket(case.attacker, case.defender), case.mode, 1, 4)
    local slot = assert(scene:animationSprite(4), case.mode .. " records its slot")
    Assert.equal(slot.draw, case.draw, case.mode .. " draw flag for attacker " .. case.attacker)
    Assert.equal(slot.priority, case.priority, case.mode .. " priority for attacker " .. case.attacker)
    local loop = assert(scene:animationSpriteDraw(1), case.mode .. " starts its draw loop")
    Assert.equal(loop.slot, 4, case.mode .. " draws the named sprite slot")
  end
end

function T.vanished_role_pictures_hide_the_copy_but_keep_their_priority()
  local scene = BattleScene.new()
  local attacker = { combatant = 1, activation = 1 }
  scene:install(attacker)
  scene:applyPictureState(attacker, { vanished = true })
  runSpriteDraw(scene, doublesPacket(3, 2), "first-battler-class-priority-gate", 0, 4)
  local slot = assert(scene:animationSprite(4), "the vanished copy keeps its slot")
  Assert.isTrue(slot.draw == false, "a vanished role picture keeps the copy hidden")
  Assert.equal(slot.priority, 1, "the role priority still applies to a vanished picture")
end

function T.sprite_draw_stop_deactivates_only_the_loop()
  local scene = BattleScene.new()
  local playback = doublesPacket(3, 2)
  local helpers = collaborators(scene)
  local player = assert(BattleAnimationPlayer.new({
    scene = helpers.scene,
    audio = helpers.audio,
    resources = helpers.resources,
    tasks = helpers.tasks,
    services = { onNativeFrame = function() end },
  }))
  local handle = assert(player:start(playback, programOf({
    { op = "start-sprite-effect", mode = "first-battler-class-priority-gate", values = { 0, 4 }, taskKind = "managed-sprite-draw-loop" },
    { op = "clear-effect-slot", values = { 0 } },
    { op = "reset-blend-alpha" },
  })))
  for _ = 1, 8 do
    player:stepSourceTick({ tick = 1 })
    if player:status(handle) == "complete" then
      break
    end
  end
  Assert.equal(player:status(handle), "complete", "the draw program completes")
  Assert.isNil(scene:animationSpriteDraw(0), "the stop deactivates the draw loop")
  local slot = assert(scene:animationSprite(4), "the sprite slot survives the stop")
  Assert.isTrue(slot.draw == true, "the stop leaves the draw flag untouched")
end

function T.move_programs_install_and_restore_the_system_blend()
  local scene = BattleScene.new()
  local helpers = collaborators(scene)
  local player = assert(BattleAnimationPlayer.new({
    scene = helpers.scene,
    audio = helpers.audio,
    resources = helpers.resources,
    tasks = helpers.tasks,
    services = { onNativeFrame = function() end },
  }))
  local handle = assert(player:start(packet(), programOf({
    { op = "interpreter-wait", values = { 1 } },
    { op = "reset-blend-alpha" },
  })))
  local frame = scene:animationFrame()
  local blend = assert(frame.main.systemBlend, "the move installs the source default blend")
  Assert.deepEqual(blend.blend, { mode = "alpha", eva = 8, evb = 8, evy = 0 }, "the default blend uses the source pair")
  Assert.deepEqual(blend.firstTarget, {}, "the default blend targets nothing first")
  Assert.deepEqual(
    blend.secondTarget,
    { world3d = true, window = true, transition = true, battlefield = true },
    "every main plane joins the second target"
  )
  Assert.deepEqual(blend.objTargets, { second = true }, "OBJ joins the second target")
  for _ = 1, 8 do
    player:stepSourceTick({ tick = 1 })
    if player:status(handle) == "complete" then
      break
    end
  end
  Assert.equal(player:status(handle), "complete", "the move program completes")
  Assert.isNil(scene:animationFrame().main.systemBlend, "teardown restores the hardware default")
end

return { tests = T }
