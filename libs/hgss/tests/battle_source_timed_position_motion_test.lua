-- Owner tests for the source-timed position motion bodies: each kind
-- reproduces one overlay-07 callback whose native machine owns its whole
-- timeline (battle_anim_move_effects.c, battle_anim_effects.c). The tests
-- prove the source phase writes, the native tick boundary, the exactly-once
-- restoration of the presented picture, and the native details the scene
-- cannot present.

local Assert = require("tests.support.Assert")
local BattleEffectTasks = require("libs.hgss.src.presentation.BattleEffectTasks")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")

local T = {}

local ATTACKER = { combatant = 1, activation = 1 }
local DEFENDER = { combatant = 3, activation = 3 }
local BYSTANDER = { combatant = 5, activation = 5 }

local function sceneWithPair()
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  return scene
end

-- A third presented battler keeps an overlay the crossing motion never owns,
-- so restoration proves the body releases exactly the two pictures it moves.
local function sceneWithTrio()
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
    { combatant = 3, activation = 3, visible = true },
    { combatant = 5, activation = 5, visible = true },
  })
  return scene
end

-- Exact shape of the occurrence topology the player publishes: these natives
-- address their own battler (BattleAnimSystem_GetAttacker/GetDefender), so the
-- bodies resolve the presented picture from the sides instead of a lowered
-- battler target.
local function occurrenceContextWithSideType(attackerSideType)
  return {
    launchId = "position-motion-probe",
    packetId = 1,
    programKey = "position-motion-probe",
    seed = 4242,
    random = function(bound)
      assert(type(bound) == "number" and bound >= 1, "visual draws name a positive bound")
      return 0
    end,
    topology = {
      attacker = { combatant = 1, activation = 1, slot = "solo-player", sideType = attackerSideType },
      targets = { { combatant = 3, activation = 3, slot = "solo-enemy", sideType = 1 } },
    },
    event = { sequence = 1, actionId = 1, hitIndex = 1, effectKey = "position-motion-probe" },
    visualSeed = 4242,
  }
end

local function occurrenceContext()
  return occurrenceContextWithSideType(0)
end

local function services(scene)
  return { scene = scene, audio = {}, resources = {} }
end

-- The producer's lowered task context per kind; the rest of these callbacks
-- lower "pokemon-picture".
local TASK_CONTEXT = {
  ["battle-background-pokepic-slide"] = "battle-display",
}

local function spawn(scene, kind, context)
  return assert(BattleEffectTasks.create(kind, {
    callback = kind,
    taskContext = TASK_CONTEXT[kind] or "pokemon-picture",
    parameters = {},
  }, context or occurrenceContext(), services(scene)))
end

local function spawnWith(scene, kind, parameters, context)
  return assert(BattleEffectTasks.create(kind, {
    callback = kind,
    taskContext = TASK_CONTEXT[kind] or "pokemon-picture",
    parameters = parameters,
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

-- BattleAnimFunc_ShakeDefenderWithOverlay (battle_anim_move_effects.c,
-- selector 11): a two-pixel horizontal shake of the defender picture wrapped
-- in the seven-tick stretch and four-tick settle of a battler sprite copy.
function T.shake_defender_overlay_displaces_the_defender_picture()
  local scene = sceneWithPair()
  local task = spawn(scene, "pokemon-picture-scale-position-transition")
  Assert.equal(task:status(), "pending", "the shake opens pending")
  task:stepSourceTick({ tick = 1 })
  local first = scene:pictureState(DEFENDER)
  Assert.notNil(first, "the first shake frame writes the defender picture")
  Assert.equal(first.pictureXOffset, 2, "the shake displaces the picture by its two-pixel amplitude")
  Assert.equal(first.pictureYOffset, 0, "the shake carries no vertical amplitude")
  task:stepSourceTick({ tick = 1 })
  Assert.equal(scene:pictureState(DEFENDER).pictureXOffset, 0, "the second frame crosses the picture centre")
  task:stepSourceTick({ tick = 1 })
  local third = scene:pictureState(DEFENDER)
  Assert.equal(third.pictureXOffset, -2, "the third frame displaces the other way")
  Assert.isNil(third.affineWidth, "the stretch scales the script-created sprite copy, never the picture")
  Assert.isNil(third.affineHeight, "the settle leg never rescales the picture either")
  Assert.isNil(scene:pictureState(ATTACKER), "the attacker picture stays untouched")
end

function T.shake_defender_overlay_retires_on_its_native_tick_and_restores()
  local scene = sceneWithPair()
  pinBystander(scene, ATTACKER)
  local task = spawn(scene, "pokemon-picture-scale-position-transition")
  Assert.equal(
    tickUntilComplete(task),
    14,
    "seven stretch, four settle, the restore, and the finish frame take 14 ticks"
  )
  Assert.isNil(scene:pictureState(DEFENDER), "completion restores the defender picture")
  Assert.isTrue(scene:pictureState(ATTACKER).pictureVisible == true, "the bystander overlay survives completion")

  local cancelled = spawn(scene, "pokemon-picture-scale-position-transition")
  step(cancelled, 5)
  Assert.notNil(scene:pictureState(DEFENDER), "the shake owns the picture mid-run")
  cancelled:cancel("withdrawn")
  Assert.equal(cancelled:status(), "cancelled", "cancellation lands on cancelled")
  Assert.isNil(scene:pictureState(DEFENDER), "cancellation restores the owned picture")
  Assert.isTrue(scene:pictureState(ATTACKER).pictureVisible == true, "cancellation never touches the attacker side")
  cancelled:cancel("repeated")
  cancelled:dispose()
  Assert.isTrue(scene:pictureState(ATTACKER).pictureVisible == true, "repeated release stays exactly once")
end

-- BattleAnimFunc_AttackerDip (battle_anim_effects.c, selector 29): four
-- six-tick linear legs over y 0 -> 32 -> 0 -> 32 -> 0, each initialized on
-- its own frame and every leg tick writing the picture offset pair.
function T.attacker_dip_walks_the_four_native_legs()
  local scene = sceneWithPair()
  local task = spawn(scene, "pokemon-picture-oscillating-axis-motion")
  task:stepSourceTick({ tick = 1 })
  Assert.isNil(scene:pictureState(ATTACKER), "the first leg frame only initializes its motion")
  task:stepSourceTick({ tick = 1 })
  local first = scene:pictureState(ATTACKER)
  Assert.equal(first.pictureYOffset, 5, "the first leg tick covers a sixth of the 32-pixel dip")
  Assert.equal(first.pictureXOffset, 0, "the dip never moves the picture sideways")
  step(task, 5)
  Assert.equal(scene:pictureState(ATTACKER).pictureYOffset, 31, "the sixth leg tick reaches the dip floor")
  step(task, 1)
  Assert.equal(scene:pictureState(ATTACKER).pictureYOffset, 31, "the exhausted leg frame holds the reached offset")
  step(task, 1)
  Assert.equal(scene:pictureState(ATTACKER).pictureYOffset, 31, "the next leg frame only initializes the rise")
  step(task, 1)
  Assert.equal(scene:pictureState(ATTACKER).pictureYOffset, 26, "the rise leg walks the picture back up")
  step(task, 5)
  Assert.equal(scene:pictureState(ATTACKER).pictureYOffset, 0, "the rise leg parks the picture on its authored row")
  Assert.isNil(scene:pictureState(DEFENDER), "the dip never patches the defender")
end

function T.attacker_dip_retires_on_its_native_tick_and_restores()
  local scene = sceneWithPair()
  pinBystander(scene, DEFENDER)
  local task = spawn(scene, "pokemon-picture-oscillating-axis-motion")
  Assert.equal(tickUntilComplete(task), 33, "four six-tick legs with their init and exhaust frames take 33 ticks")
  Assert.isNil(scene:pictureState(ATTACKER), "completion restores the attacker picture")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "the bystander overlay survives completion")

  local cancelled = spawn(scene, "pokemon-picture-oscillating-axis-motion")
  step(cancelled, 4)
  Assert.notNil(scene:pictureState(ATTACKER), "the dip owns the picture mid-run")
  cancelled:cancel("withdrawn")
  Assert.isNil(scene:pictureState(ATTACKER), "cancellation restores the owned picture")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "cancellation never touches the defender side")
  cancelled:cancel("repeated")
  cancelled:dispose()
end

-- BattleAnimFunc_SkewSlideAttackerBg (battle_anim_effects.c, selector 12):
-- the callback hides the attacker picture and runs its own first shear frame;
-- twenty-four shear ticks, a sixteen-tick blend in, a nine-frame hold, a
-- sixteen-tick blend out, and the restore frame follow.
function T.skew_slide_hides_the_attacker_picture_and_ramps_the_effect_blend()
  local scene = sceneWithPair()
  local task = spawn(scene, "battle-background-pokepic-slide")
  local hidden = scene:pictureState(ATTACKER)
  Assert.notNil(hidden, "the callback hides the picture before its first scheduled frame")
  Assert.equal(hidden.vanished, true, "the source hides the picture with POKEPIC_VANISHED")
  Assert.equal(hidden.pictureVisible, false, "the hidden picture draws nothing")
  step(task, 23)
  Assert.isNil(scene:blendCoefficients(), "the shear frames write no blend register")
  Assert.equal(scene:pictureState(ATTACKER).vanished, true, "the picture stays hidden through the shear")
  task:stepSourceTick({ tick = 1 })
  local opened = assert(scene:blendCoefficients(), "the exhausted shear starts the effect-plane blend")
  Assert.equal(opened.blendCoefficientA, 31, "the plane blend opens at the full effect weight")
  Assert.equal(opened.blendCoefficientB, 0, "the battlefield weight starts at zero")
  task:stepSourceTick({ tick = 1 })
  local ramped = assert(scene:blendCoefficients())
  Assert.equal(ramped.blendCoefficientA, 29, "the blend walks one sixteenth of the pair per frame")
  Assert.equal(ramped.blendCoefficientB, 1, "the battlefield weight rises with the plane weight")
  step(task, 7)
  local crossed = assert(scene:blendCoefficients())
  Assert.equal(crossed.blendCoefficientA, 15, "the pair crosses at the midpoint")
  Assert.equal(crossed.blendCoefficientB, 15, "the pair crosses at the midpoint")
  local scroll = scene:scroll()
  Assert.equal(scroll.x, 0, "the per-scanline shear never fakes a battlefield viewport sweep")
  Assert.equal(scroll.y, 0, "the per-scanline shear never fakes a battlefield viewport sweep")
end

function T.skew_slide_retires_on_its_native_tick_and_restores()
  local scene = sceneWithPair()
  pinBystander(scene, DEFENDER)
  local task = spawn(scene, "battle-background-pokepic-slide")
  Assert.equal(tickUntilComplete(task), 68, "the shear, both blends, and the hold take 68 scheduled ticks")
  Assert.isNil(scene:pictureState(ATTACKER), "completion restores the attacker picture")
  Assert.isNil(scene:blendCoefficients(), "completion drops the owned blend register")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "the bystander overlay survives completion")

  local cancelled = spawn(scene, "battle-background-pokepic-slide")
  step(cancelled, 30)
  Assert.notNil(scene:blendCoefficients(), "the running blend owns its register pair")
  cancelled:cancel("withdrawn")
  Assert.equal(cancelled:status(), "cancelled", "cancellation lands on cancelled")
  Assert.isNil(scene:pictureState(ATTACKER), "cancellation restores the hidden picture")
  Assert.isNil(scene:blendCoefficients(), "cancellation drops the owned blend register")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "cancellation never touches the defender side")
  cancelled:cancel("repeated")
  cancelled:dispose()
end

function T.skew_slide_returns_the_picture_on_its_blend_out_frame()
  -- The source restores POKEPIC_VANISHED on the blend-out frame and destroys
  -- the task on the frame after it, so the picture is drawn again one tick
  -- before the run retires.
  local scene = sceneWithPair()
  local task = spawn(scene, "battle-background-pokepic-slide")
  local spent = 0
  while task:status() ~= "complete" do
    task:stepSourceTick({ tick = 1 })
    spent = spent + 1
    if spent == 67 then
      local returned = assert(scene:pictureState(ATTACKER), "the blend-out frame draws the picture again")
      Assert.equal(returned.vanished, false, "the blend-out frame clears POKEPIC_VANISHED")
      Assert.equal(returned.pictureVisible, true, "the returned picture draws again")
    end
    assert(spent <= 200, "the slide retires on its own tick")
  end
  Assert.equal(spent, 68, "the restore frame precedes the teardown frame")
end

-- BattleAnimFunc_AttackerLungeKnockback (battle_anim_effects.c, selector
-- 30): a sixty-four-frame attacker ellipse, the two-tick 32-pixel lunge, the
-- matching defender knockback, and both eight-tick returns home.
function T.two_battler_crossing_motion_orbits_the_attacker_picture()
  local scene = sceneWithPair()
  local task = spawn(scene, "pokemon-picture-two-battler-crossing-motion")
  Assert.equal(task:status(), "pending", "the crossing motion opens pending")
  task:stepSourceTick({ tick = 1 })
  Assert.isNil(scene:pictureState(ATTACKER), "the init frame only starts the ellipse")
  task:stepSourceTick({ tick = 1 })
  local first = assert(scene:pictureState(ATTACKER), "the first ellipse frame writes the attacker picture")
  Assert.equal(first.pictureXOffset, 3, "the ellipse starts from its 32-pixel horizontal amplitude")
  Assert.equal(first.pictureYOffset, 0, "the ellipse starts on its eight-pixel row baseline")
  step(task, 15)
  local wide = assert(scene:pictureState(ATTACKER))
  Assert.equal(wide.pictureXOffset, 32, "the quarter-orbit frame reaches the full horizontal amplitude")
  Assert.equal(wide.pictureYOffset, 7, "the quarter-orbit frame sits one pixel under the row baseline")
  step(task, 16)
  local high = assert(scene:pictureState(ATTACKER))
  Assert.equal(high.pictureXOffset, 0, "the half-orbit frame crosses the picture column")
  Assert.equal(high.pictureYOffset, 16, "the half-orbit frame lifts the picture by its eight-pixel amplitude")
  Assert.isNil(scene:pictureState(DEFENDER), "the ellipse never moves the defender")
end

function T.two_battler_crossing_motion_lunges_then_knocks_the_defender_back()
  local scene = sceneWithPair()
  local task = spawn(scene, "pokemon-picture-two-battler-crossing-motion")
  step(task, 65)
  Assert.equal(scene:pictureState(ATTACKER).pictureYOffset, 0, "the sixty-fifth tick already restored the picture row")
  task:stepSourceTick({ tick = 1 })
  Assert.equal(scene:pictureState(ATTACKER).pictureXOffset, 16, "the exhausted ellipse starts the two-tick lunge")
  Assert.isNil(scene:pictureState(DEFENDER), "the lunge leaves the defender where it stands")
  task:stepSourceTick({ tick = 1 })
  Assert.equal(scene:pictureState(ATTACKER).pictureXOffset, 32, "the lunge reaches its 32-pixel reach")
  step(task, 2)
  Assert.equal(scene:pictureState(DEFENDER).pictureXOffset, 16, "the defender is knocked back toward its own side")
  Assert.equal(scene:pictureState(ATTACKER).pictureXOffset, 32, "the attacker holds its lunge reach")
  task:stepSourceTick({ tick = 1 })
  Assert.equal(scene:pictureState(DEFENDER).pictureXOffset, 32, "the knockback reaches its 32-pixel reach")
  step(task, 2)
  Assert.equal(scene:pictureState(ATTACKER).pictureXOffset, 28, "the attacker walks home one four-pixel step per tick")
  Assert.equal(scene:pictureState(DEFENDER).pictureXOffset, 32, "the defender waits at its knocked-back reach")
  step(task, 7)
  Assert.equal(scene:pictureState(ATTACKER).pictureXOffset, 0, "the attacker lands on its authored column")
  Assert.equal(scene:pictureState(DEFENDER).pictureXOffset, 32, "the defender waits at its knocked-back reach")
  step(task, 2)
  Assert.equal(scene:pictureState(DEFENDER).pictureXOffset, 28, "the defender then walks home the same way")
  step(task, 9)
  Assert.equal(task:status(), "complete", "the crossing motion retires after the defender lands")
end

function T.two_battler_crossing_motion_retires_on_its_native_tick_and_restores()
  local scene = sceneWithTrio()
  pinBystander(scene, BYSTANDER)
  local task = spawn(scene, "pokemon-picture-two-battler-crossing-motion")
  Assert.equal(
    tickUntilComplete(task),
    90,
    "the 64-frame ellipse, both crossing legs, and the four exhausted frames take 90 ticks"
  )
  Assert.isNil(scene:pictureState(ATTACKER), "completion restores the attacker picture")
  Assert.isNil(scene:pictureState(DEFENDER), "completion restores the defender picture")
  Assert.isTrue(scene:pictureState(BYSTANDER).pictureVisible == true, "the bystander overlay survives completion")

  local cancelled = spawn(scene, "pokemon-picture-two-battler-crossing-motion")
  step(cancelled, 70)
  Assert.notNil(scene:pictureState(ATTACKER), "the crossing motion owns the attacker picture mid-run")
  Assert.notNil(scene:pictureState(DEFENDER), "the knockback owns the defender picture mid-run")
  cancelled:cancel("withdrawn")
  Assert.equal(cancelled:status(), "cancelled", "cancellation lands on cancelled")
  Assert.isNil(scene:pictureState(ATTACKER), "cancellation restores the attacker picture")
  Assert.isNil(scene:pictureState(DEFENDER), "cancellation restores the defender picture")
  Assert.isTrue(scene:pictureState(BYSTANDER).pictureVisible == true, "cancellation never touches the bystander")
  cancelled:cancel("repeated")
  cancelled:dispose()
  Assert.isTrue(scene:pictureState(BYSTANDER).pictureVisible == true, "repeated release stays exactly once")
end

function T.two_battler_crossing_motion_mirrors_the_enemy_side()
  local scene = sceneWithPair()
  local task = spawn(scene, "pokemon-picture-two-battler-crossing-motion", occurrenceContextWithSideType(1))
  step(task, 66)
  Assert.equal(scene:pictureState(ATTACKER).pictureXOffset, -16, "the enemy-side attacker lunges the other way")
  step(task, 3)
  Assert.equal(scene:pictureState(DEFENDER).pictureXOffset, -16, "the enemy-side knockback follows its attacker")
  task:dispose()
end

-- BattleAnimFunc_AttackerStretchUp (battle_anim_effects.c, selector 31):
-- the callback starts BattleAnimUtil_InitScaleMotion(10, 10, 15, 8) — 1/100
-- words, so a uniform 256 -> 384 scale over eight ticks — and the task holds
-- the stretched pose, settles back over eight mirrored ticks, writes the
-- identity affine pair, and waits out a sixteen-frame timer.
function T.two_phase_entry_motion_stretches_the_attacker_picture()
  local scene = sceneWithPair()
  local task = spawn(scene, "pokemon-picture-two-phase-entry-motion")
  Assert.equal(task:status(), "pending", "the stretch opens pending")
  task:stepSourceTick({ tick = 1 })
  local first = assert(scene:pictureState(ATTACKER), "the first stretch tick writes the picture")
  Assert.equal(first.affineMode, true, "the stretch scales the picture")
  Assert.equal(first.affineWidth, 272, "the eight-tick walk adds a sixteenth of the 128-unit range per tick")
  Assert.equal(first.affineHeight, 272, "the native uniform InitScaleMotion scales both axes together")
  task:stepSourceTick({ tick = 1 })
  local second = assert(scene:pictureState(ATTACKER))
  Assert.equal(second.affineWidth, 288, "the second stretch tick lands on 288")
  Assert.equal(second.pictureYOffset, -5, "the scaled picture keeps its feet row: half of the eighty-pixel gain")
  step(task, 6)
  local stretched = assert(scene:pictureState(ATTACKER))
  Assert.equal(stretched.affineWidth, 384, "the eighth stretch tick reaches the 1.5 scale end word")
  Assert.equal(stretched.pictureYOffset, -20, "the stretched picture is aligned to its scale")
  Assert.isNil(scene:pictureState(DEFENDER), "the stretch only owns the attacker picture")
end
function T.two_phase_entry_motion_holds_then_settles_the_stretched_picture()
  local scene = sceneWithPair()
  local task = spawn(scene, "pokemon-picture-two-phase-entry-motion")
  step(task, 9)
  Assert.equal(scene:pictureState(ATTACKER).affineWidth, 384, "the exhausted stretch frame writes nothing")
  step(task, 5)
  Assert.equal(scene:pictureState(ATTACKER).affineWidth, 384, "the five hold frames keep the stretched pose")
  task:stepSourceTick({ tick = 1 })
  local settling = assert(scene:pictureState(ATTACKER))
  Assert.equal(settling.affineWidth, 368, "the settle leg walks the scale back one sixteenth per tick")
  Assert.equal(settling.pictureYOffset, -18, "the settling picture follows its scale row")
  step(task, 7)
  Assert.equal(scene:pictureState(ATTACKER).affineWidth, 256, "the eighth settle tick returns the authored scale")
  Assert.equal(scene:pictureState(ATTACKER).pictureYOffset, 0, "the settled picture sits on its authored row")
  step(task, 1)
  Assert.equal(scene:pictureState(ATTACKER).affineWidth, 256, "the exhausted settle frame writes nothing")
  task:stepSourceTick({ tick = 1 })
  local reset = assert(scene:pictureState(ATTACKER))
  Assert.equal(reset.affineWidth, 256, "the reset frame writes POKEPIC_AFFINEW = 0x100")
  Assert.equal(reset.affineHeight, 256, "the reset frame writes POKEPIC_AFFINEH = 0x100")
  Assert.equal(reset.pictureYOffset, 0, "the reset frame leaves the row the last settle tick aligned")
end

function T.two_phase_entry_motion_retires_on_its_native_tick_and_restores()
  local scene = sceneWithPair()
  pinBystander(scene, DEFENDER)
  local task = spawn(scene, "pokemon-picture-two-phase-entry-motion")
  step(task, 24)
  Assert.equal(
    tickUntilComplete(task),
    18,
    "the sixteen-frame delay, the frame it goes below zero, and the teardown take 18 ticks"
  )
  Assert.isNil(scene:pictureState(ATTACKER), "completion restores the attacker picture")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "the bystander overlay survives completion")

  local cancelled = spawn(scene, "pokemon-picture-two-phase-entry-motion")
  step(cancelled, 20)
  Assert.notNil(scene:pictureState(ATTACKER), "the stretch owns the picture mid-run")
  cancelled:cancel("withdrawn")
  Assert.equal(cancelled:status(), "cancelled", "cancellation lands on cancelled")
  Assert.isNil(scene:pictureState(ATTACKER), "cancellation restores the owned picture")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "cancellation never touches the defender side")
  cancelled:cancel("repeated")
  cancelled:dispose()
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "repeated release stays exactly once")
end

-- BattleAnimFunc_AttackerShakeLunge (battle_anim_effects.c, selector 47):
-- BattleAnimUtil_InitShake(4, 0, 1, 4) shakes the attacker picture sixteen
-- frames, the picture then lunges forty pixels sideways and seven up over
-- four ticks, holds eight delays, walks home over four ticks, and the
-- teardown frame writes the authored row back.
function T.height_position_transition_shakes_then_lunges_the_attacker_picture()
  local scene = sceneWithPair()
  local task = spawn(scene, "pokemon-picture-height-position-transition")
  Assert.equal(task:status(), "pending", "the shake opens pending")
  task:stepSourceTick({ tick = 1 })
  Assert.isNil(scene:pictureState(ATTACKER), "the start frame only initializes the shake")
  task:stepSourceTick({ tick = 1 })
  local first = assert(scene:pictureState(ATTACKER), "the first shake frame writes the picture")
  Assert.equal(first.pictureXOffset, 4, "the shake opens on its four-pixel amplitude")
  Assert.equal(first.pictureYOffset, 0, "the shake carries no vertical amplitude")
  task:stepSourceTick({ tick = 1 })
  Assert.equal(scene:pictureState(ATTACKER).pictureXOffset, 0, "the second shake frame crosses the picture column")
  task:stepSourceTick({ tick = 1 })
  Assert.equal(scene:pictureState(ATTACKER).pictureXOffset, -4, "the third shake frame displaces the other way")
  step(task, 14)
  Assert.equal(scene:pictureState(ATTACKER).pictureXOffset, 0, "the sixteenth shake frame parks the picture")
  Assert.equal(scene:pictureState(ATTACKER).pictureYOffset, 0, "the shake never lifts the picture")
  Assert.isNil(scene:pictureState(DEFENDER), "the shake only owns the attacker picture")
end

function T.height_position_transition_walks_the_lunge_hold_and_return()
  local scene = sceneWithPair()
  local task = spawn(scene, "pokemon-picture-height-position-transition")
  step(task, 18)
  task:stepSourceTick({ tick = 1 })
  local lunging = assert(scene:pictureState(ATTACKER), "the exhausted shake frame starts the lunge")
  Assert.equal(lunging.pictureXOffset, 10, "the lunge covers a quarter of its forty-pixel reach per tick")
  Assert.equal(lunging.pictureYOffset, -2, "the lunge climbs a quarter of its seven-pixel lift per tick")
  step(task, 3)
  local reach = assert(scene:pictureState(ATTACKER))
  Assert.equal(reach.pictureXOffset, 40, "the fourth lunge tick reaches the forty-pixel reach")
  Assert.equal(reach.pictureYOffset, -7, "the lunge lands seven pixels above the authored row")
  step(task, 10)
  Assert.equal(scene:pictureState(ATTACKER).pictureXOffset, 40, "the nine hold frames leave the picture at its reach")
  step(task, 1)
  Assert.equal(scene:pictureState(ATTACKER).pictureXOffset, 30, "the return leg walks back a ten-pixel tick")
  step(task, 3)
  Assert.equal(scene:pictureState(ATTACKER).pictureXOffset, 0, "the return leg lands on the authored column")
  Assert.equal(scene:pictureState(ATTACKER).pictureYOffset, 0, "the return leg lands on the authored row")
  step(task, 2)
  Assert.equal(task:status(), "complete", "the shake lunge retires on its teardown frame")
end

function T.height_position_transition_retires_on_its_native_tick_and_restores()
  local scene = sceneWithPair()
  pinBystander(scene, DEFENDER)
  local task = spawn(scene, "pokemon-picture-height-position-transition")
  Assert.equal(
    tickUntilComplete(task),
    38,
    "sixteen shake frames, both four-tick legs, the nine hold frames, and the teardown frames take 38 ticks"
  )
  Assert.isNil(scene:pictureState(ATTACKER), "completion restores the attacker picture")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "the bystander overlay survives completion")

  local cancelled = spawn(scene, "pokemon-picture-height-position-transition")
  step(cancelled, 20)
  Assert.notNil(scene:pictureState(ATTACKER), "the lunge owns the picture mid-run")
  cancelled:cancel("withdrawn")
  Assert.equal(cancelled:status(), "cancelled", "cancellation lands on cancelled")
  Assert.isNil(scene:pictureState(ATTACKER), "cancellation restores the owned picture")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "cancellation never touches the defender side")
  cancelled:cancel("repeated")
  cancelled:dispose()
end

function T.height_position_transition_mirrors_the_enemy_side()
  local scene = sceneWithPair()
  local task = spawn(scene, "pokemon-picture-height-position-transition", occurrenceContextWithSideType(1))
  task:stepSourceTick({ tick = 1 })
  task:stepSourceTick({ tick = 1 })
  Assert.equal(scene:pictureState(ATTACKER).pictureXOffset, 4, "the shake amplitude keeps its native sign")
  step(task, 17)
  local lunging = assert(scene:pictureState(ATTACKER))
  Assert.equal(lunging.pictureXOffset, -10, "the enemy-side attacker lunges the other way")
  Assert.equal(
    lunging.pictureYOffset,
    1,
    "the descending leg reads its own fixed-point step, a 1.75-pixel quarter truncated to one"
  )
  task:dispose()
end

function T.position_motion_kinds_refuse_a_run_without_a_presented_battler()
  local scene = sceneWithPair()
  local context = occurrenceContext()
  context.topology = {}
  for _, kind in ipairs({
    "pokemon-picture-scale-position-transition",
    "battle-background-pokepic-slide",
    "pokemon-picture-oscillating-axis-motion",
    "pokemon-picture-two-battler-crossing-motion",
    "pokemon-picture-two-phase-entry-motion",
    "pokemon-picture-height-position-transition",
    "pokemon-picture-vertical-offset-visibility-transition",
    "pokemon-picture-target-priority-transition",
  }) do
    Assert.throws(function()
      BattleEffectTasks.create(kind, { callback = kind, parameters = {} }, context, services(scene))
    end, kind .. " never guesses an absent battler picture")
  end
  Assert.isNil(scene:pictureState(ATTACKER), "the refused construction publishes nothing")
  Assert.isNil(scene:pictureState(DEFENDER), "the refused construction publishes nothing")
end

-- BattleAnimFunc_RevealBattler (battle_anim_funcs.c, selector 67): the
-- callback stages a crop window over one battler picture and starts the
-- upward reveal, the sink, or the rise machine according to the upward flag
-- and the step word; every machine writes on the tick its pre-incremented
-- timer reaches the interval word and retires one tick after its reveal
-- state retires.
function T.vertical_offset_visibility_transition_reveals_the_picture_upward()
  local scene = sceneWithPair()
  local task = spawnWith(scene, "pokemon-picture-vertical-offset-visibility-transition", {
    pictureTarget = "attacker",
    offsetStep = 2,
    ticksPerStep = 1,
    applyVisibilityOffset = true,
  })
  Assert.equal(task:status(), "pending", "the reveal opens pending")
  local staged = assert(scene:pictureState(ATTACKER), "the callback stages the crop before its first frame")
  Assert.equal(staged.pictureVisible, true, "the staged reveal activates the crop window")
  Assert.equal(staged.pictureYOffset2, 80, "the upward reveal starts below the picture box")
  Assert.equal(staged.pictureHeight, 0, "the upward reveal starts with no visible row")
  Assert.equal(staged.dontDraw, true, "a crop with no area draws nothing")
  Assert.isNil(scene:pictureState(DEFENDER), "the reveal only owns the picture its flags name")
  task:stepSourceTick({ tick = 1 })
  local first = assert(scene:pictureState(ATTACKER))
  Assert.equal(first.pictureYOffset2, 78, "the first reveal tick lifts the crop origin one step")
  Assert.equal(first.pictureHeight, 2, "the first reveal tick grows the visible height one step")
  Assert.equal(first.pictureWidth, 80, "the reveal crop keeps the whole picture width")
  Assert.equal(first.dontDraw, false, "a revealed band draws again")
  task:stepSourceTick({ tick = 1 })
  Assert.equal(scene:pictureState(ATTACKER).pictureYOffset2, 76, "the second tick lifts the crop origin again")
  Assert.equal(scene:pictureState(ATTACKER).pictureHeight, 4, "the second tick keeps the crop bottom on the box bottom")
end

function T.vertical_offset_visibility_transition_spends_the_interval_word_without_a_write()
  local scene = sceneWithPair()
  local task = spawnWith(scene, "pokemon-picture-vertical-offset-visibility-transition", {
    pictureTarget = "attacker",
    offsetStep = 2,
    ticksPerStep = 2,
    applyVisibilityOffset = true,
  })
  task:stepSourceTick({ tick = 1 })
  Assert.equal(scene:pictureState(ATTACKER).pictureYOffset2, 80, "the first tick only fills the interval")
  Assert.equal(scene:pictureState(ATTACKER).dontDraw, true, "the staged crop survives the unwritten tick")
  task:stepSourceTick({ tick = 1 })
  Assert.equal(scene:pictureState(ATTACKER).pictureYOffset2, 78, "the interval tick writes the reveal step")
  Assert.equal(scene:pictureState(ATTACKER).pictureHeight, 2, "the interval tick grows the visible height")
  task:dispose()
end

function T.vertical_offset_visibility_transition_reveals_on_its_native_tick_and_restores()
  local scene = sceneWithPair()
  pinBystander(scene, DEFENDER)
  local task = spawnWith(scene, "pokemon-picture-vertical-offset-visibility-transition", {
    pictureTarget = "attacker",
    offsetStep = 2,
    ticksPerStep = 1,
    applyVisibilityOffset = true,
  })
  Assert.equal(
    tickUntilComplete(task),
    42,
    "forty reveal steps, the clamped frame, and the teardown frame take 42 ticks"
  )
  Assert.isNil(scene:pictureState(ATTACKER), "completion restores the revealed picture")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "the bystander overlay survives completion")

  local cancelled = spawnWith(scene, "pokemon-picture-vertical-offset-visibility-transition", {
    pictureTarget = "attacker",
    offsetStep = 2,
    ticksPerStep = 1,
    applyVisibilityOffset = true,
  })
  step(cancelled, 20)
  Assert.notNil(scene:pictureState(ATTACKER), "the reveal owns the crop mid-run")
  cancelled:cancel("withdrawn")
  Assert.equal(cancelled:status(), "cancelled", "cancellation lands on cancelled")
  Assert.isNil(scene:pictureState(ATTACKER), "cancellation restores the revealed picture")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "cancellation never touches the bystander")
  cancelled:cancel("repeated")
  cancelled:dispose()
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "repeated release stays exactly once")
end

function T.vertical_offset_visibility_transition_sinks_the_picture_while_the_crop_closes()
  local scene = sceneWithPair()
  local task = spawnWith(scene, "pokemon-picture-vertical-offset-visibility-transition", {
    pictureTarget = "opposing-battler",
    offsetStep = 2,
    ticksPerStep = 1,
    applyVisibilityOffset = false,
  })
  local staged = assert(scene:pictureState(DEFENDER), "the sink stages the defended picture")
  Assert.equal(staged.pictureYOffset, 0, "the sink opens on the authored picture row")
  Assert.equal(staged.pictureHeight, 80, "the sink opens on the whole picture box")
  task:stepSourceTick({ tick = 1 })
  local first = assert(scene:pictureState(DEFENDER))
  Assert.equal(first.pictureYOffset, 2, "the first sink tick slides the picture one step down")
  Assert.equal(first.pictureHeight, 78, "the first sink tick crops the picture one step shorter")
  step(task, 39)
  local spent = assert(scene:pictureState(DEFENDER))
  Assert.equal(spent.pictureYOffset, 80, "the fortieth sink tick lands one box below the authored row")
  Assert.equal(spent.pictureHeight, 0, "the fortieth sink tick closes the crop")
  Assert.equal(spent.dontDraw, true, "a closed crop draws nothing")
  Assert.equal(tickUntilComplete(task), 2, "the clamped frame and the teardown frame close the sink")
  Assert.isNil(scene:pictureState(DEFENDER), "completion restores the sunk picture")
  Assert.isNil(scene:pictureState(ATTACKER), "the sink never touches the other side")
end

function T.vertical_offset_visibility_transition_rises_the_picture_back_to_its_row()
  local scene = sceneWithPair()
  local task = spawnWith(scene, "pokemon-picture-vertical-offset-visibility-transition", {
    pictureTarget = "attacker",
    offsetStep = -2,
    ticksPerStep = 1,
    applyVisibilityOffset = false,
  })
  local staged = assert(scene:pictureState(ATTACKER), "the rise stages its picture below the authored row")
  Assert.equal(staged.pictureYOffset, 80, "the rise parks the picture one box below its row")
  Assert.equal(staged.pictureHeight, 0, "the rise reveals nothing on its staging frame")
  task:stepSourceTick({ tick = 1 })
  local first = assert(scene:pictureState(ATTACKER))
  Assert.equal(first.pictureYOffset, 78, "the first rise tick climbs one step")
  Assert.equal(first.pictureHeight, 2, "the first rise tick opens the crop one step")
  step(task, 39)
  local landed = assert(scene:pictureState(ATTACKER))
  Assert.equal(landed.pictureYOffset, 0, "the fortieth rise tick lands on the authored row")
  Assert.equal(landed.pictureHeight, 80, "the fortieth rise tick reveals the whole picture")
  Assert.equal(tickUntilComplete(task), 2, "the overrun frame and the teardown frame close the rise")
  Assert.isNil(scene:pictureState(ATTACKER), "completion restores the risen picture")
end

function T.vertical_offset_visibility_transition_refuses_a_step_that_never_progresses()
  local scene = sceneWithPair()
  Assert.throws(function()
    spawnWith(scene, "pokemon-picture-vertical-offset-visibility-transition", {
      pictureTarget = "attacker",
      offsetStep = 0,
      ticksPerStep = 1,
      applyVisibilityOffset = false,
    })
  end, "a zero step would walk the same crop forever")
  Assert.isNil(scene:pictureState(ATTACKER), "the refused construction publishes nothing")
end

-- BattleAnimFunc_WipeOutDefender (battle_anim_move_effects.c, selector 79):
-- the callback dims the defender picture to alpha 8 and the task walks a
-- two-pixel crop band up the picture, alternating between the left and right
-- edges, over thirty-nine rows before clearing the crop and restoring alpha.
function T.target_priority_transition_wipes_the_defender_picture_bottom_up()
  local scene = sceneWithPair()
  local task = spawn(scene, "pokemon-picture-target-priority-transition")
  local dimmed = assert(scene:pictureState(DEFENDER), "the callback dims the picture before its first frame")
  Assert.equal(dimmed.polygonAlpha, 8, "the wipe dims the defender picture to alpha 8")
  Assert.isNil(dimmed.pictureXOffset2, "the callback opens its object window, not a picture crop")
  task:stepSourceTick({ tick = 1 })
  local band = assert(scene:pictureState(DEFENDER), "the first wipe frame draws a band")
  Assert.equal(band.pictureVisible, true, "the band activates the crop window")
  Assert.equal(band.pictureXOffset2, 0, "the first band starts at the left edge")
  Assert.equal(band.pictureYOffset2, 76, "the first band two rows above the picture bottom")
  Assert.equal(band.pictureWidth, 79, "the band covers the full strip step")
  Assert.equal(band.pictureHeight, 2, "the band is two pixels tall")
  Assert.equal(band.polygonAlpha, 8, "the band keeps the dimmed picture alpha")
  step(task, 4)
  local next = assert(scene:pictureState(DEFENDER), "the next row draws the mirrored band")
  Assert.equal(next.pictureXOffset2, 1, "the second band starts at the right edge")
  Assert.equal(next.pictureYOffset2, 74, "the second band climbs one row")
  step(task, 4)
  Assert.equal(scene:pictureState(DEFENDER).pictureXOffset2, 0, "the third band returns to the left edge")
  Assert.isNil(scene:pictureState(ATTACKER), "the wipe only owns the defended picture")
end

function T.target_priority_transition_wipes_on_its_native_tick_and_restores()
  local scene = sceneWithTrio()
  pinBystander(scene, BYSTANDER)
  local task = spawn(scene, "pokemon-picture-target-priority-transition")
  local spent = 0
  while task:status() ~= "complete" do
    task:stepSourceTick({ tick = 1 })
    spent = spent + 1
    if spent == 157 then
      local cleared = assert(scene:pictureState(DEFENDER), "the hide frame still owns the picture")
      Assert.equal(cleared.pictureVisible, false, "the hide frame clears the crop window")
      Assert.equal(cleared.pictureXOffset2, nil, "the cleared crop draws the whole picture again")
    end
    assert(spent <= 200, "the wipe retires on its own tick")
  end
  Assert.equal(
    spent,
    158,
    "thirty-nine band rows with their two window frames and the two closing frames take 158 ticks"
  )
  Assert.isNil(scene:pictureState(DEFENDER), "completion restores the wiped picture and its alpha")
  Assert.isTrue(scene:pictureState(BYSTANDER).pictureVisible == true, "the bystander overlay survives completion")

  local cancelled = spawn(scene, "pokemon-picture-target-priority-transition")
  step(cancelled, 30)
  Assert.notNil(scene:pictureState(DEFENDER), "the wipe owns the picture mid-run")
  cancelled:cancel("withdrawn")
  Assert.equal(cancelled:status(), "cancelled", "cancellation lands on cancelled")
  Assert.isNil(scene:pictureState(DEFENDER), "cancellation restores the owned picture")
  Assert.isTrue(scene:pictureState(BYSTANDER).pictureVisible == true, "cancellation never touches the bystander")
  cancelled:cancel("repeated")
  cancelled:dispose()
  Assert.isTrue(scene:pictureState(BYSTANDER).pictureVisible == true, "repeated release stays exactly once")
end

return { tests = T }
