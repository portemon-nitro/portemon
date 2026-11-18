-- Owner tests for the source-timed shake and palette bodies: each kind
-- reproduces one overlay-07 callback whose native machine owns its whole
-- timeline (battle_anim_move_effects.c, battle_anim_effects.c). The tests
-- prove the source phase writes, the native tick boundary, and the
-- exactly-once restoration of the presented picture, its palette fade, and
-- the shared blend registers.

local Assert = require("tests.support.Assert")
local BattleEffectTasks = require("libs.hgss.src.presentation.BattleEffectTasks")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")

local T = {}

local ATTACKER = { combatant = 1, activation = 1 }
local DEFENDER = { combatant = 3, activation = 3 }

local function sceneWithPair()
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  return scene
end

-- Exact shape of the occurrence topology the player publishes: the natives in
-- this family address their own battler, so the bodies resolve the presented
-- picture from the sides instead of a lowered battler target.
local function occurrenceContext(defenderSideType)
  return {
    launchId = "shake-palette-probe",
    packetId = 1,
    programKey = "shake-palette-probe",
    seed = 4242,
    random = function(bound)
      assert(type(bound) == "number" and bound >= 1, "visual draws name a positive bound")
      return 0
    end,
    topology = {
      attacker = { combatant = 1, activation = 1, slot = "solo-player", sideType = 0 },
      targets = { { combatant = 3, activation = 3, slot = "solo-enemy", sideType = defenderSideType or 1 } },
    },
    event = { sequence = 1, actionId = 1, hitIndex = 1, effectKey = "shake-palette-probe" },
    visualSeed = 4242,
  }
end

local function services(scene)
  return { scene = scene, audio = {}, resources = {} }
end

-- The producer's lowered task context per kind; the rest of these callbacks
-- lower "pokemon-picture".
local TASK_CONTEXT = {
  ["sprite-affine-scale-and-blend-transition"] = "battle-sprite",
}

-- The producer lowers no battler target and an empty parameter record for
-- these selectors, so the spawn carries exactly that shape.
local function spawn(scene, kind, parameters, context)
  return assert(BattleEffectTasks.create(kind, {
    callback = kind,
    taskContext = TASK_CONTEXT[kind] or "pokemon-picture",
    parameters = parameters or {},
  }, context or occurrenceContext(), services(scene)))
end

-- Selectors whose script operand picks the addressed side lower the same
-- record a battler target names.
local function spawnTarget(scene, kind, battlerTarget, context)
  return assert(BattleEffectTasks.create(kind, {
    callback = kind,
    taskContext = "pokemon-picture",
    battlerTarget = battlerTarget,
    parameters = {},
  }, context or occurrenceContext(), services(scene)))
end

local function step(task, count)
  for _ = 1, count do
    task:stepSourceTick({ tick = 1 })
  end
end

-- Advances to the body's own retirement and reports the tick it took, so a
-- test names the source boundary instead of a tolerated budget.
local function tickUntilComplete(task, limit)
  local spent = 0
  while task:status() ~= "complete" do
    task:stepSourceTick({ tick = 1 })
    spent = spent + 1
    assert(spent <= (limit or 400), "source-timed bodies retire on their own tick")
  end
  return spent
end

-- A second task keeps an overlay on the untouched battler, so restoration
-- proves the body only releases the picture it owns.
local function pinBystander(scene, activation)
  local bystander = {}
  scene:applyTaskPicturePatch(bystander, activation, { pictureVisible = true })
  return bystander
end

-- BattleAnimFunc_AttackerPulseWhite (battle_anim_move_effects.c, selector 13):
-- four pulses read gBattleAnimPulseWhiteSteps (asm/battle_anim_data.s): the
-- initialization frame starts a six-tick scale motion and a six-coefficient
-- white palette fade, and the pulse frame writes the affine pair every tick
-- until both have exhausted. The exhaustion frame only returns the machine to
-- the initialization state (or retires it after the fourth pulse), so one
-- pulse costs eight ticks and the task destroys itself on the thirty-third.
function T.picture_palette_pulse_ramps_the_white_fade_of_each_pulse()
  local scene = sceneWithPair()
  pinBystander(scene, DEFENDER)
  local task = spawn(scene, "pokemon-picture-palette-pulse-position-transition")
  Assert.equal(task:status(), "pending", "the pulse opens pending")
  task:stepSourceTick({ tick = 1 })
  Assert.isNil(scene:pictureState(ATTACKER), "the initialization frame only starts the motion and the fade")
  task:stepSourceTick({ tick = 1 })
  local whitening = scene:pictureState(ATTACKER)
  Assert.equal(whitening.affineMode, true, "the pulse drives the affine pair")
  Assert.equal(whitening.affineWidth, 262, "the first step widens toward the 115/100 row target")
  Assert.equal(whitening.affineHeight, 262, "the pulse scales both axes together")
  Assert.equal(whitening.paletteFade.intensity, 1, "the white fade spends its first coefficient")
  Assert.equal(whitening.paletteFade.finish, 6, "the fade walks to the sixth coefficient")
  Assert.equal(whitening.paletteFade.targetColor, 0x7fff, "the fade targets white")
  step(task, 5)
  local whitened = scene:pictureState(ATTACKER)
  Assert.equal(whitened.paletteFade.intensity, 6, "the fade reaches the sixth coefficient on the sixth pulse tick")
  step(task, 1)
  local exhausted = scene:pictureState(ATTACKER)
  Assert.equal(exhausted.paletteFade.intensity, 6, "the exhausted motion frame writes the held pose")
  Assert.equal(exhausted.affineWidth, 293, "the exhausted scale motion holds its reach")
  step(task, 1)
  Assert.equal(
    scene:pictureState(ATTACKER).paletteFade.intensity,
    6,
    "the restarted pulse writes no picture attributes"
  )
  step(task, 1)
  local fading = scene:pictureState(ATTACKER)
  Assert.equal(fading.paletteFade.finish, 0, "the second pulse fades the white back out")
  Assert.equal(fading.paletteFade.intensity, 5, "the second pulse starts one coefficient below white")
  step(task, 1)
  Assert.equal(scene:pictureState(ATTACKER).paletteFade.intensity, 4, "the second pulse drops one coefficient per tick")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "the defender picture stays untouched")
end

function T.picture_palette_pulse_retires_on_its_native_tick_and_restores()
  local scene = sceneWithPair()
  pinBystander(scene, DEFENDER)
  local task = spawn(scene, "pokemon-picture-palette-pulse-position-transition")
  Assert.equal(tickUntilComplete(task), 33, "four pulses of eight ticks and the destroy frame take 33 ticks")
  Assert.isNil(scene:pictureState(ATTACKER), "completion restores the attacker picture")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "the bystander overlay survives completion")

  local cancelled = spawn(scene, "pokemon-picture-palette-pulse-position-transition")
  step(cancelled, 3)
  Assert.notNil(scene:pictureState(ATTACKER), "the pulse owns the picture mid-run")
  cancelled:cancel("withdrawn")
  Assert.equal(cancelled:status(), "cancelled", "cancellation lands on cancelled")
  Assert.isNil(scene:pictureState(ATTACKER), "cancellation restores the owned picture")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "cancellation never touches the other side")
  cancelled:cancel("repeated")
  cancelled:dispose()
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "repeated release stays exactly once")
end

-- BattleAnimFunc_FadeInShrinkSprite (battle_anim_effects.c, selector 17): the
-- callback starts an eight-tick alpha ramp from 0/31 to 16/15, holds the pair
-- for thirty-three ticks, then shrinks the copy from 14/10 to 10/10 over eight
-- ticks and hides it on the exhausted frame. The shift is a script-created
-- battler sprite copy (BattleAnimSystem_GetBattlerSprite slot 0) with its XLU
-- OAM mode, its draw priority and its terminal hide; the scene presents the
-- attacker picture, so it carries the copy's affine timeline and the body
-- names the rest as unreproduced instead of hiding the mon.
function T.sprite_affine_and_blend_ramps_the_alpha_pair_then_shrinks()
  local scene = sceneWithPair()
  pinBystander(scene, DEFENDER)
  local task = spawn(scene, "sprite-affine-scale-and-blend-transition")
  local entry = scene:pictureState(ATTACKER)
  Assert.equal(entry.affineWidth, 358, "the callback writes the copy's 1.4 affine width")
  Assert.equal(entry.affineHeight, 358, "the callback writes the copy's 1.4 affine height")
  local opened = assert(scene:blendCoefficients())
  Assert.equal(opened.blendCoefficientA, 0, "the callback opens the blend at 0/31")
  Assert.equal(opened.blendCoefficientB, 31, "the battlefield weight starts at 31")

  task:stepSourceTick({ tick = 1 })
  local first = assert(scene:blendCoefficients())
  Assert.equal(first.blendCoefficientA, 2, "the ramp lifts the sprite weight two coefficients per tick")
  Assert.equal(first.blendCoefficientB, 29, "the battlefield weight drops with it")
  Assert.equal(scene:pictureState(ATTACKER).affineWidth, 358, "the fade-in holds the copy's scale")
  step(task, 7)
  local ramped = assert(scene:blendCoefficients())
  Assert.equal(ramped.blendCoefficientA, 16, "the eighth tick reaches the 16 coefficient")
  Assert.equal(ramped.blendCoefficientB, 15, "the closing alpha pair is 16/15")
  step(task, 1)
  Assert.equal(
    scene:blendCoefficients().blendCoefficientA,
    16,
    "the exhausted ramp frame writes the held pair once more"
  )
  step(task, 20)
  Assert.equal(scene:blendCoefficients().blendCoefficientA, 16, "the hold keeps the register pair")
  Assert.equal(scene:pictureState(ATTACKER).affineWidth, 358, "the hold keeps the copy's scale")
  step(task, 14)
  local shrinking = scene:pictureState(ATTACKER)
  Assert.equal(shrinking.affineWidth, 345, "the shrink closes the first of the eight ticks")
  Assert.equal(shrinking.affineHeight, 345, "the shrink is uniform")
  step(task, 7)
  local shrunk = scene:pictureState(ATTACKER)
  Assert.equal(shrunk.affineWidth, 256, "the shrink lands on the authored 1.0 scale")
  Assert.equal(shrunk.pictureVisible, nil, "the presented picture is never hidden like the copy")
end

function T.sprite_affine_and_blend_retires_on_its_native_tick_and_restores()
  local scene = sceneWithPair()
  pinBystander(scene, DEFENDER)
  local task = spawn(scene, "sprite-affine-scale-and-blend-transition")
  Assert.equal(
    tickUntilComplete(task),
    52,
    "the eight ramp ticks, thirty-three hold ticks, eight shrink ticks, and the destroy frames take 52 ticks"
  )
  Assert.isNil(scene:pictureState(ATTACKER), "completion restores the attacker picture")
  Assert.isNil(scene:blendCoefficients(), "completion drops the owned alpha pair")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "the bystander overlay survives completion")

  local cancelled = spawn(scene, "sprite-affine-scale-and-blend-transition")
  step(cancelled, 5)
  Assert.notNil(scene:blendCoefficients(), "the ramp owns the alpha pair mid-run")
  cancelled:cancel("withdrawn")
  Assert.isNil(scene:pictureState(ATTACKER), "cancellation restores the owned picture")
  Assert.isNil(scene:blendCoefficients(), "cancellation drops the owned alpha pair")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "cancellation never touches the other side")
  cancelled:cancel("repeated")
  cancelled:dispose()
end

-- BattleAnimFunc_ShakeDefenderBlackFlash (battle_anim_effects.c, selector 18):
-- BattleAnimUtil_InitShake(4, 0, 1, 4) displaces the defender picture four
-- pixels per tick and the side sign biases the first phase, while the
-- callback's black palette fade walks 0 -> 16 and the frame that finds it
-- finished starts the 16 -> 0 walk back. The frame after that walk writes the
-- authored X/Y, and only the following frame destroys the task.
function T.palette_fade_shakes_the_defender_toward_black()
  local scene = sceneWithPair()
  pinBystander(scene, ATTACKER)
  local task = spawn(scene, "pokemon-picture-palette-fade")
  task:stepSourceTick({ tick = 1 })
  local first = scene:pictureState(DEFENDER)
  Assert.equal(first.pictureXOffset, 4, "the first shake phase reaches the four-pixel amplitude")
  Assert.equal(first.pictureYOffset, 0, "the source shake is horizontal only")
  Assert.equal(first.paletteFade.intensity, 1, "the black fade spends its first coefficient")
  Assert.equal(first.paletteFade.finish, 16, "the fade walks to the full black coefficient")
  Assert.equal(first.paletteFade.targetColor, 0, "the fade targets black")
  task:stepSourceTick({ tick = 1 })
  Assert.equal(scene:pictureState(DEFENDER).pictureXOffset, 1, "the side sign biases the second shake phase")
  task:stepSourceTick({ tick = 1 })
  Assert.equal(scene:pictureState(DEFENDER).pictureXOffset, -4, "the third phase swings the other way")
  task:stepSourceTick({ tick = 1 })
  Assert.equal(scene:pictureState(DEFENDER).pictureXOffset, -1, "the fourth phase closes the first round")
  step(task, 12)
  local black = scene:pictureState(DEFENDER)
  Assert.equal(black.paletteFade.intensity, 16, "the sixteenth tick reaches black")
  Assert.equal(black.pictureXOffset, -1, "the four shake rounds end on the biased phase")
  step(task, 1)
  local returning = scene:pictureState(DEFENDER)
  Assert.equal(returning.paletteFade.finish, 0, "the finished fade starts the walk back")
  Assert.equal(returning.paletteFade.intensity, 16, "the walk back starts from black")
  Assert.equal(returning.pictureXOffset, -1, "the exhausted shake holds its last offset")
  Assert.isTrue(scene:pictureState(ATTACKER).pictureVisible == true, "the attacker picture stays untouched")
end

function T.palette_fade_retires_on_its_native_tick_and_restores()
  local scene = sceneWithPair()
  pinBystander(scene, ATTACKER)
  local task = spawn(scene, "pokemon-picture-palette-fade")
  Assert.equal(tickUntilComplete(task), 35, "seventeen ticks out, seventeen back, and the destroy frame take 35")
  Assert.isNil(scene:pictureState(DEFENDER), "completion restores the defender picture")
  Assert.isTrue(scene:pictureState(ATTACKER).pictureVisible == true, "the bystander overlay survives completion")

  local cancelled = spawn(scene, "pokemon-picture-palette-fade")
  step(cancelled, 6)
  Assert.notNil(scene:pictureState(DEFENDER), "the flash owns the defender picture mid-run")
  cancelled:cancel("withdrawn")
  Assert.isNil(scene:pictureState(DEFENDER), "cancellation restores the owned picture")
  Assert.isTrue(scene:pictureState(ATTACKER).pictureVisible == true, "cancellation never touches the other side")
  cancelled:cancel("repeated")
  cancelled:dispose()
end

-- BattleAnimFunc_AttackerCircleFade (battle_anim_effects.c, selector 23): the
-- callback hides the attacker picture, opens the battlefield blend at 16/0,
-- and starts the two-orbit BattleAnimUtil_InitCircleMotion(2, 16) ellipse plus
-- its 32-tick 16/0 -> 0/16 blend walk. After the 32 ellipse ticks the machine
-- waits seventeen more, starts the 0/16 -> 16/0 walk, and restores the picture
-- visibility on the frame that walk reports finished. The ellipse is a
-- script-created battler sprite copy (BattleAnimSystem_GetBattlerSprite slot
-- 0) in XLU OAM mode, which the scene does not present; the body reproduces
-- the picture vanish the callback writes and the blend registers instead.
function T.picture_vanish_and_restore_hides_the_picture_and_walks_the_blend()
  local scene = sceneWithPair()
  pinBystander(scene, DEFENDER)
  local task = spawn(scene, "pokemon-picture-vanish-and-restore-transition")
  local hidden = scene:pictureState(ATTACKER)
  Assert.equal(hidden.vanished, true, "the callback hides the attacker picture")
  Assert.equal(hidden.pictureVisible, false, "the picture draws nothing while the copy circles")
  local opened = assert(scene:blendCoefficients())
  Assert.equal(opened.blendCoefficientA, 16, "the callback opens the battlefield blend at 16/0")
  Assert.equal(opened.blendCoefficientB, 0, "the battlefield weight starts at zero")
  task:stepSourceTick({ tick = 1 })
  local first = assert(scene:blendCoefficients())
  Assert.equal(first.blendCoefficientA, 15, "the first blend tick spends half of the 32-tick walk")
  Assert.equal(first.blendCoefficientB, 0, "the background weight lags one step behind")
  step(task, 2)
  local rising = assert(scene:blendCoefficients())
  Assert.equal(rising.blendCoefficientA, 14, "the walk drops a coefficient every two ticks")
  Assert.equal(rising.blendCoefficientB, 1, "the background weight rises with it")
  step(task, 31)
  local walked = assert(scene:blendCoefficients())
  Assert.equal(walked.blendCoefficientA, 0, "the thirty-second tick reaches the 0/16 pair")
  Assert.equal(walked.blendCoefficientB, 16, "the closing pair is 0/16")
  Assert.equal(scene:pictureState(ATTACKER).pictureVisible, false, "the ellipse keeps the picture hidden")
  step(task, 16)
  local fade = assert(scene:blendCoefficients())
  Assert.equal(fade.blendCoefficientA, 0, "the seventeen-frame delay keeps the register pair")
  Assert.equal(fade.blendCoefficientB, 16, "the delay writes nothing")
end

function T.picture_vanish_and_restore_retires_on_its_native_tick_and_restores()
  local scene = sceneWithPair()
  pinBystander(scene, DEFENDER)
  local task = spawn(scene, "pokemon-picture-vanish-and-restore-transition")
  Assert.equal(
    tickUntilComplete(task),
    84,
    "the 32 ellipse ticks, seventeen delay ticks, 33 blend ticks, and the destroy frame take 84 ticks"
  )
  Assert.isNil(scene:pictureState(ATTACKER), "completion restores the attacker picture")
  Assert.isNil(scene:blendCoefficients(), "completion drops the owned blend pair")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "the bystander overlay survives completion")

  local cancelled = spawn(scene, "pokemon-picture-vanish-and-restore-transition")
  step(cancelled, 3)
  Assert.equal(scene:pictureState(ATTACKER).pictureVisible, false, "the run owns the hidden picture mid-way")
  cancelled:cancel("withdrawn")
  Assert.isNil(scene:pictureState(ATTACKER), "cancellation restores the owned picture")
  Assert.isNil(scene:blendCoefficients(), "cancellation drops the owned blend pair")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "cancellation never touches the other side")
  cancelled:cancel("repeated")
  cancelled:dispose()
end

function T.picture_vanish_and_restore_shows_the_picture_again_before_it_retires()
  local scene = sceneWithPair()
  local task = spawn(scene, "pokemon-picture-vanish-and-restore-transition")
  step(task, 83)
  local restored = scene:pictureState(ATTACKER)
  Assert.equal(restored.pictureVisible, true, "the finished blend restores the picture visibility")
  Assert.equal(restored.vanished, false, "the restored picture is no longer vanished")
  Assert.equal(task:status(), "running", "the destroy frame is still ahead")
  step(task, 1)
  Assert.equal(task:status(), "complete", "the following frame destroys the task")
end

-- BattleAnimFunc_WaddlePic (battle_anim_effects.c, selector 25): the
-- callback reads the authored X/Y of the picture its script operand names,
-- sets the picture's Y pivot to 50, and starts a three-tick value motion to
-- 0xAAA whose step the attacker's side sign negates. Each of the four steps
-- then runs a tilt frame (ZROT 910), two hop ticks (ZROT 1820/2730 over the
-- two-pixel descent), the landing that ramps the tilt back to zero while the
-- picture climbs home, and the frame that reports the step done. The step
-- frame ends by starting the next step and spending its tilt frame at once,
-- so the four steps run 33 ticks and the destroy frame takes the thirty-
-- fourth. The absolute X/Y the native writes are this picture's own presented
-- position, so the hop is published as a picture offset.
function T.picture_entry_offset_waddles_the_addressed_picture()
  local scene = sceneWithPair()
  pinBystander(scene, DEFENDER)
  local task = spawnTarget(scene, "pokemon-picture-entry-offset-transition", "attacker")
  Assert.equal(task:status(), "pending", "the waddle opens pending")
  Assert.isNil(scene:pictureState(ATTACKER), "the callback writes only the pivot the scene cannot carry")
  task:stepSourceTick({ tick = 1 })
  local tilt = scene:pictureState(ATTACKER)
  Assert.equal(tilt.rotationZ, 910, "the tilt frame spends the first third of the 0xAAA reach")
  Assert.isNil(tilt.pictureYOffset, "the tilt frame writes no position")
  task:stepSourceTick({ tick = 1 })
  local rising = scene:pictureState(ATTACKER)
  Assert.equal(rising.rotationZ, 1820, "the first hop tick tilts further")
  Assert.equal(rising.pictureYOffset, 1, "the first hop tick drops the picture one pixel")
  Assert.equal(rising.pictureXOffset, 0, "the hop keeps the picture on its authored column")
  task:stepSourceTick({ tick = 1 })
  local hopped = scene:pictureState(ATTACKER)
  Assert.equal(hopped.rotationZ, 2730, "the second hop tick reaches the 0xAAA tilt")
  Assert.equal(hopped.pictureYOffset, 2, "the second hop tick reaches the two-pixel reach")
  task:stepSourceTick({ tick = 1 })
  local parked = scene:pictureState(ATTACKER)
  Assert.equal(parked.rotationZ, 2730, "the hop's exhausted frame writes nothing")
  Assert.equal(parked.pictureYOffset, 2, "the exhausted hop frame holds the reach")
  task:stepSourceTick({ tick = 1 })
  local landing = scene:pictureState(ATTACKER)
  Assert.equal(landing.rotationZ, 1820, "the landing ramps the tilt back")
  Assert.equal(landing.pictureYOffset, 1, "the landing climbs one pixel")
  task:stepSourceTick({ tick = 1 })
  Assert.equal(scene:pictureState(ATTACKER).rotationZ, 910, "the second landing tick halves the tilt")
  Assert.equal(scene:pictureState(ATTACKER).pictureYOffset, 0, "the second landing tick reaches the authored row")
  task:stepSourceTick({ tick = 1 })
  Assert.equal(scene:pictureState(ATTACKER).rotationZ, 0, "the third landing tick untilts the picture")
  step(task, 1)
  local settled = scene:pictureState(ATTACKER)
  Assert.equal(settled.rotationZ, 0, "the step frame writes the authored Z rotation")
  Assert.equal(settled.pictureYOffset, 0, "the step frame writes the authored row")
  task:stepSourceTick({ tick = 1 })
  Assert.equal(scene:pictureState(ATTACKER).rotationZ, 64626, "the second step tilts the other way")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "the other side stays untouched")
end

function T.picture_entry_offset_waddle_retires_on_its_native_tick_and_restores()
  local scene = sceneWithPair()
  pinBystander(scene, DEFENDER)
  local task = spawnTarget(scene, "pokemon-picture-entry-offset-transition", "attacker")
  Assert.equal(tickUntilComplete(task), 34, "four nine-tick steps and the destroy frame take 34 ticks")
  Assert.isNil(scene:pictureState(ATTACKER), "completion restores the attacker picture")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "the bystander overlay survives completion")

  local cancelled = spawnTarget(scene, "pokemon-picture-entry-offset-transition", "attacker")
  step(cancelled, 3)
  Assert.notNil(scene:pictureState(ATTACKER), "the waddle owns the picture mid-run")
  cancelled:cancel("withdrawn")
  Assert.equal(cancelled:status(), "cancelled", "cancellation lands on cancelled")
  Assert.isNil(scene:pictureState(ATTACKER), "cancellation restores the owned picture")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "cancellation never touches the other side")
  cancelled:cancel("repeated")
  cancelled:dispose()
end

function T.picture_entry_offset_waddle_drives_the_side_its_operand_names()
  local scene = sceneWithPair()
  pinBystander(scene, ATTACKER)
  local task = spawnTarget(scene, "pokemon-picture-entry-offset-transition", "target")
  task:stepSourceTick({ tick = 1 })
  Assert.equal(scene:pictureState(DEFENDER).rotationZ, 910, "the target profile waddles the defender picture")
  Assert.isTrue(scene:pictureState(ATTACKER).pictureVisible == true, "the attacker picture stays untouched")
  -- The attacker's side sign still sides the run, so an enemy attacker flips
  -- the tilt even though the waddled picture is the player-side defender.
  local enemy = sceneWithPair()
  local context = occurrenceContext(1)
  context.topology.attacker.sideType = 1
  context.topology.targets[1].sideType = 0
  local flipped = spawnTarget(enemy, "pokemon-picture-entry-offset-transition", "target", context)
  flipped:stepSourceTick({ tick = 1 })
  Assert.equal(enemy:pictureState(DEFENDER).rotationZ, 64626, "the enemy attacker flips the tilt")
end

-- BattleAnimFunc_SpriteDriftFade (battle_anim_move_effects.c, selector 26):
-- the callback picks the defender picture (script arg 0 zero) or the attacker
-- picture, opens the masked blend at 26/5, drifts the script-created battler
-- sprite copy twenty pixels away from the picked battler over twenty ticks,
-- and walks reg_G2_BLDALPHA 31/0 -> 0/31 over fifteen frames on its own
-- task. The drift step is exactly one pixel per tick and the coefficient walk
-- truncates, so the fifteenth frame leaves the pair at 0/30. The exhausted
-- drift frame holds the reach and the frame after it destroys the task.
function T.picture_randomized_position_motion_drifts_the_picture_and_blend()
  local scene = sceneWithPair()
  pinBystander(scene, ATTACKER)
  local task = spawnTarget(scene, "pokemon-picture-randomized-position-motion", "target")
  local opened = assert(scene:blendCoefficients())
  Assert.equal(opened.blendCoefficientA, 26, "the callback opens the masked blend at 26")
  Assert.equal(opened.blendCoefficientB, 5, "the battlefield weight starts at 5")
  Assert.isNil(scene:pictureState(DEFENDER), "the callback itself writes no picture attribute")
  task:stepSourceTick({ tick = 1 })
  local first = scene:pictureState(DEFENDER)
  Assert.equal(first.pictureXOffset, 1, "the enemy-side defender drifts one pixel toward the field")
  Assert.equal(first.pictureYOffset, -1, "the same sign raises the defender picture")
  local blend = assert(scene:blendCoefficients())
  Assert.equal(blend.blendCoefficientA, 28, "the coefficient walk spends three of its thirty-one levels")
  Assert.equal(blend.blendCoefficientB, 2, "the battlefield weight rises with it")
  step(task, 1)
  Assert.equal(scene:pictureState(DEFENDER).pictureXOffset, 2, "the drift spends one pixel per tick")
  Assert.equal(scene:blendCoefficients().blendCoefficientA, 26, "the walk keeps truncating two levels per tick")
  step(task, 13)
  local walked = assert(scene:blendCoefficients())
  Assert.equal(walked.blendCoefficientA, 0, "the fifteenth frame reaches a zero sprite weight")
  Assert.equal(walked.blendCoefficientB, 30, "the truncated walk closes on 30")
  Assert.equal(scene:pictureState(DEFENDER).pictureYOffset, -15, "the drift is still climbing")
  step(task, 1)
  local closed = assert(scene:blendCoefficients())
  Assert.equal(closed.blendCoefficientA, 0, "the walk's closing frame writes nothing")
  Assert.equal(closed.blendCoefficientB, 30, "the pair keeps its last value")
  Assert.equal(scene:pictureState(DEFENDER).pictureYOffset, -16, "the drift outlives the fade")
  step(task, 4)
  Assert.equal(scene:pictureState(DEFENDER).pictureXOffset, 20, "the drift reaches twenty pixels")
  Assert.equal(scene:pictureState(DEFENDER).pictureYOffset, -20, "both axes walk the same reach")
  step(task, 1)
  Assert.equal(scene:pictureState(DEFENDER).pictureXOffset, 20, "the exhausted frame holds the reach")
  Assert.equal(task:status(), "running", "the destroy frame is still ahead")
  Assert.isTrue(scene:pictureState(ATTACKER).pictureVisible == true, "the other side stays untouched")
end

function T.picture_randomized_position_motion_retires_on_its_native_tick_and_restores()
  local scene = sceneWithPair()
  pinBystander(scene, ATTACKER)
  local task = spawnTarget(scene, "pokemon-picture-randomized-position-motion", "target")
  Assert.equal(tickUntilComplete(task), 22, "twenty drift ticks, the retired frame, and the destroy frame take 22")
  Assert.isNil(scene:pictureState(DEFENDER), "completion restores the defender picture")
  Assert.isNil(scene:blendCoefficients(), "completion drops the owned blend pair")
  Assert.isTrue(scene:pictureState(ATTACKER).pictureVisible == true, "the bystander overlay survives completion")

  local cancelled = spawnTarget(scene, "pokemon-picture-randomized-position-motion", "target")
  step(cancelled, 4)
  Assert.notNil(scene:blendCoefficients(), "the drift owns the register pair mid-run")
  cancelled:cancel("withdrawn")
  Assert.isNil(scene:pictureState(DEFENDER), "cancellation restores the owned picture")
  Assert.isNil(scene:blendCoefficients(), "cancellation drops the owned blend pair")
  Assert.isTrue(scene:pictureState(ATTACKER).pictureVisible == true, "cancellation never touches the other side")
  cancelled:cancel("repeated")
  cancelled:dispose()
end

function T.picture_randomized_position_motion_mirrors_the_addressed_side()
  local scene = sceneWithPair()
  local context = occurrenceContext(0)
  local task = spawnTarget(scene, "pokemon-picture-randomized-position-motion", "target", context)
  task:stepSourceTick({ tick = 1 })
  Assert.equal(scene:pictureState(DEFENDER).pictureXOffset, -1, "a player-side defender drifts the other way")
  Assert.equal(scene:pictureState(DEFENDER).pictureYOffset, 1, "and the other vertical way")
end

-- BattleAnimFunc_SlideOutAndTransform (battle_anim_move_effects.c,
-- selector 71): three fifteen-tick legs sided by the attacker's own side. The
-- collected picture parks on its column for the first leg, crosses the
-- 415-pixel reach between the two native picture columns for the second (on
-- the opposite battler's row), and walks home for the third. Each leg start
-- requests a shadow Y adjust and every leg frame writes the motion's X/Y; the
-- exhausted frame holds the pose and the frame after the third leg clears the
-- request and destroys the task.
function T.picture_selected_pair_transition_slides_the_picture_across()
  local scene = sceneWithPair()
  pinBystander(scene, DEFENDER)
  local task = spawn(scene, "pokemon-picture-selected-pair-transition", { pictureSets = { "active-battler" } })
  Assert.isNil(scene:pictureState(ATTACKER), "the callback itself writes no picture attribute")
  task:stepSourceTick({ tick = 1 })
  local parked = scene:pictureState(ATTACKER)
  Assert.equal(parked.pictureXOffset, 0, "the parking leg holds the presented column")
  Assert.equal(parked.pictureYOffset, 0, "the parking leg holds the presented row")
  Assert.equal(parked.shadowAdjustY, true, "the leg start requests a shadow Y adjust")
  step(task, 14)
  Assert.equal(scene:pictureState(ATTACKER).pictureXOffset, 0, "the parking leg spends all fifteen ticks in place")
  step(task, 1)
  Assert.equal(scene:pictureState(ATTACKER).pictureXOffset, 0, "the exhausted frame holds the parking pose")
  task:stepSourceTick({ tick = 1 })
  local crossing = scene:pictureState(ATTACKER)
  Assert.equal(crossing.pictureXOffset, -28, "the crossing leg walks 415 pixels over fifteen ticks")
  Assert.equal(crossing.pictureYOffset, -64, "the crossing leg sits on the opposite battler's row")
  Assert.equal(crossing.shadowAdjustY, true, "the crossing leg requests a shadow Y adjust")
  step(task, 14)
  Assert.equal(scene:pictureState(ATTACKER).pictureXOffset, -416, "the truncated walk lands one pixel past the reach")
  step(task, 1)
  Assert.equal(scene:pictureState(ATTACKER).pictureXOffset, -416, "the exhausted frame holds the crossing pose")
  task:stepSourceTick({ tick = 1 })
  local returning = scene:pictureState(ATTACKER)
  Assert.equal(returning.pictureXOffset, -388, "the return leg walks back from the crossing reach")
  Assert.equal(returning.pictureYOffset, 0, "the return leg is back on the presented row")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "the other side stays untouched")
end

function T.picture_selected_pair_transition_retires_on_its_native_tick_and_restores()
  local scene = sceneWithPair()
  pinBystander(scene, DEFENDER)
  local task = spawn(scene, "pokemon-picture-selected-pair-transition", { pictureSets = { "active-battler" } })
  Assert.equal(tickUntilComplete(task), 49, "three fifteen-tick legs and their four frames take 49 ticks")
  Assert.isNil(scene:pictureState(ATTACKER), "completion restores the attacker picture")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "the bystander overlay survives completion")

  local cancelled = spawn(scene, "pokemon-picture-selected-pair-transition", { pictureSets = { "active-battler" } })
  step(cancelled, 20)
  Assert.notNil(scene:pictureState(ATTACKER), "the slide owns the picture mid-run")
  cancelled:cancel("withdrawn")
  Assert.equal(cancelled:status(), "cancelled", "cancellation lands on cancelled")
  Assert.isNil(scene:pictureState(ATTACKER), "cancellation restores the owned picture")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "cancellation never touches the other side")
  cancelled:cancel("repeated")
  cancelled:dispose()
end

function T.picture_selected_pair_transition_mirrors_the_enemy_attacker()
  local scene = sceneWithPair()
  local context = occurrenceContext()
  context.topology.attacker.sideType = 1
  context.topology.targets[1].sideType = 0
  local task =
    spawn(scene, "pokemon-picture-selected-pair-transition", { pictureSets = { "opposing-battler" } }, context)
  step(task, 17)
  local pose = scene:pictureState(DEFENDER)
  Assert.equal(pose.pictureXOffset, 27, "an enemy attacker crosses the other way")
  Assert.equal(pose.pictureYOffset, 64, "and onto the player row below")
end

function T.picture_selected_pair_transition_clears_its_shadow_adjust_before_retiring()
  local scene = sceneWithPair()
  local task = spawn(scene, "pokemon-picture-selected-pair-transition", { pictureSets = { "active-battler" } })
  step(task, 48)
  Assert.equal(task:status(), "running", "the clearing frame is still ahead")
  Assert.equal(scene:pictureState(ATTACKER).shadowAdjustY, true, "the request stands through the last leg")
  step(task, 1)
  Assert.equal(task:status(), "complete", "the default frame clears the request and destroys the task")
  Assert.isNil(scene:pictureState(ATTACKER), "the cleared picture patch retires with the task")
end

function T.shake_and_palette_kinds_refuse_a_run_without_a_presented_battler()
  local scene = sceneWithPair()
  local context = occurrenceContext()
  context.topology = {}
  for _, kind in ipairs({
    "pokemon-picture-palette-pulse-position-transition",
    "pokemon-picture-vanish-and-restore-transition",
    "sprite-affine-scale-and-blend-transition",
    "pokemon-picture-palette-fade",
    "pokemon-picture-entry-offset-transition",
    "pokemon-picture-randomized-position-motion",
    "pokemon-picture-selected-pair-transition",
  }) do
    Assert.throws(function()
      BattleEffectTasks.create(kind, { callback = kind, parameters = {} }, context, services(scene))
    end, kind .. " never guesses an absent battler picture")
  end
end

return { tests = T }
