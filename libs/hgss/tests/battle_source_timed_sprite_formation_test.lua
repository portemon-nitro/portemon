-- Owner tests for the source-timed sprite formation bodies: each kind
-- reproduces one overlay-07 callback that spreads script-created copies of the
-- attacker's battler sprite into an afterimage formation, or drives the
-- presented battler pictures the way a copy-driven callback does
-- (battle_anim_move_effects.c and battle_anim_effects.c). The tests prove the
-- source phase writes, the native tick boundary, the exactly-once restoration
-- of the presented picture, and the per-copy details the scene cannot present.

local Assert = require("tests.support.Assert")
local BattleEffectTasks = require("libs.hgss.src.presentation.BattleEffectTasks")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")

local T = {}

local ATTACKER = { combatant = 1, activation = 1 }
local DEFENDER = { combatant = 3, activation = 3 }

local WAVE_KIND = "pokemon-picture-four-sprite-wave-transition"
local SQUASH_KIND = "pokemon-picture-three-sprite-affine-transition"
local OSCILLATION_KIND = "battle-background-picture-scroll-oscillation"
local AFFINE_PAIR_KIND = "pokemon-picture-managed-sprite-affine-pair-transition"

-- The producer's lowered task context per kind; the rest of these callbacks
-- lower "pokemon-picture".
local TASK_CONTEXT = {
  [OSCILLATION_KIND] = "battle-display",
}

local function sceneWithPair()
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  return scene
end

-- Exact shape of the occurrence topology the player publishes: the native
-- callback addresses its own attacker, so the bodies resolve the presented
-- picture from the sides instead of a lowered battler target, which the
-- producer does not emit for these selectors.
local function occurrenceContext()
  return {
    launchId = "sprite-formation-probe",
    packetId = 1,
    programKey = "sprite-formation-probe",
    seed = 4242,
    random = function(bound)
      assert(type(bound) == "number" and bound >= 1, "visual draws name a positive bound")
      return 0
    end,
    topology = {
      attacker = { combatant = 1, activation = 1, slot = "solo-player", sideType = 0 },
      targets = { { combatant = 3, activation = 3, slot = "solo-enemy", sideType = 1 } },
    },
    event = { sequence = 1, actionId = 1, hitIndex = 1, effectKey = "sprite-formation-probe" },
    visualSeed = 4242,
  }
end

local function services(scene)
  return { scene = scene, audio = {}, resources = {} }
end

local function spawn(scene, kind, parameters)
  return assert(BattleEffectTasks.create(kind, {
    callback = kind,
    taskContext = TASK_CONTEXT[kind] or "pokemon-picture",
    parameters = parameters or {},
  }, occurrenceContext(), services(scene)))
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

-- BattleAnimFunc_AttackerAfterimages (battle_anim_move_effects.c, selector 7):
-- nine gBattleAnimAttackerAfterimagePasses passes over rows {0, 32} and
-- {32, 0}, each one shortened by its (count + 1) / 2 delay, then the
-- nine-tick reg_G2_BLDALPHA fade and the destroy frame.
function T.wave_walks_its_passes_and_fades_the_copies()
  local scene = sceneWithPair()
  local task = spawn(scene, WAVE_KIND)
  Assert.equal(task:status(), "pending", "the wave opens pending")
  local opened = assert(scene:blendCoefficients(), "the callback writes the afterimage blend pair")
  Assert.equal(opened.blendCoefficientA, 8, "the copies open at the callback's sprite weight")
  Assert.equal(opened.blendCoefficientB, 6, "and the callback's battlefield weight")
  Assert.isNil(scene:pictureState(ATTACKER), "the callback frame patches no picture")

  task:stepSourceTick({ tick = 1 })
  Assert.equal(scene:pictureState(ATTACKER).pictureXOffset, 4, "the first pass spends a seventh of its 32-pixel track")
  step(task, 6)
  Assert.equal(scene:pictureState(ATTACKER).pictureXOffset, 32, "the seventh pass tick reaches the row's end")
  step(task, 1)
  Assert.equal(
    scene:pictureState(ATTACKER).pictureXOffset,
    32,
    "the exhausted leading copy holds its reach while the slower pair ends the pass"
  )
  step(task, 4)
  Assert.equal(
    scene:pictureState(ATTACKER).pictureXOffset,
    26,
    "the second pass walks the leading copy back from 32 over its six shortened ticks"
  )
  Assert.isNil(scene:pictureState(DEFENDER), "the formation never patches the target picture")

  -- Nine passes bring the machine to its fade window.
  step(task, 67)
  local parked = assert(scene:blendCoefficients(), "the passes keep the callback's register pair")
  Assert.equal(parked.blendCoefficientA, 8, "the passes never touch the sprite weight")
  Assert.equal(parked.blendCoefficientB, 6, "the passes never touch the battlefield weight")

  step(task, 1)
  local fading = assert(scene:blendCoefficients())
  Assert.equal(fading.blendCoefficientA, 7, "the fade drops one sprite weight per frame")
  Assert.equal(fading.blendCoefficientB, 7, "and raises the battlefield weight with it")
  step(task, 8)
  local faded = assert(scene:blendCoefficients())
  Assert.equal(faded.blendCoefficientA, 0, "the ninth fade tick reaches the zero sprite weight")
  Assert.equal(faded.blendCoefficientB, 15, "and the full battlefield weight")
  Assert.equal(task:status(), "running", "the fade's own last tick does not retire the task")

  local pose = assert(scene:pictureState(ATTACKER), "the source only fades the copies, never the picture")
  Assert.isNil(pose.vanished, "the picture is never vanished behind the faded copies")
  Assert.isNil(pose.pictureVisible, "and stays drawn")
  task:dispose()
end

function T.wave_retires_on_its_native_tick_and_restores_the_picture()
  local scene = sceneWithPair()
  pinBystander(scene, DEFENDER)
  local task = spawn(scene, WAVE_KIND)
  Assert.equal(tickUntilComplete(task), 89, "nine passes, nine fade ticks, and the destroy frame take 89 ticks")
  Assert.isNil(scene:pictureState(ATTACKER), "completion restores the picture the copies slid")
  Assert.isNil(scene:blendCoefficients(), "completion drops the owned blend register")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "the bystander overlay survives completion")
  local cancelled = spawn(scene, WAVE_KIND)
  step(cancelled, 12)
  Assert.notNil(scene:pictureState(ATTACKER), "the wave owns the picture mid-run")
  cancelled:cancel("withdrawn")
  Assert.equal(cancelled:status(), "cancelled", "cancellation lands on cancelled")
  Assert.isNil(scene:pictureState(ATTACKER), "cancellation restores the owned picture")
  Assert.isNil(scene:blendCoefficients(), "cancellation drops the owned blend register")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "cancellation never touches the other side")
  cancelled:cancel("repeated")
  cancelled:dispose()
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "repeated release stays exactly once")
end

-- BattleAnimFunc_AttackerSquashAfterimages (battle_anim_move_effects.c,
-- selector 22): the shown picture, three rounds of the gBattleAnimSquashAfterimageDelays
-- squash, the restore leg, and the destroy frame that hides the picture.
function T.squash_squashes_holds_the_round_and_reseats_it()
  local scene = sceneWithPair()
  local task = spawn(scene, SQUASH_KIND)
  local opened = assert(scene:blendCoefficients(), "the callback writes the afterimage blend pair")
  Assert.equal(opened.blendCoefficientA, 12, "the copies squash inside the callback's sprite weight")
  Assert.equal(opened.blendCoefficientB, 6, "and the callback's battlefield weight")

  task:stepSourceTick({ tick = 1 })
  Assert.equal(scene:pictureState(ATTACKER).pictureVisible, true, "the first state shows the picture")
  step(task, 2)
  Assert.isNil(scene:pictureState(ATTACKER).affineWidth, "the delay frames only count down")
  step(task, 1)
  local first = scene:pictureState(ATTACKER)
  Assert.equal(first.affineMode, true, "the squash drives the affine pair")
  Assert.equal(first.affineWidth, 207, "the first squash tick covers one fifth of the way to 5/100")
  Assert.equal(first.affineHeight, 207, "both axes squash together")
  Assert.equal(first.pictureYOffset, 7, "the copy row is aligned through the scale offset")
  step(task, 4)
  local squashed = scene:pictureState(ATTACKER)
  Assert.equal(squashed.affineWidth, 11, "the fifth squash tick reaches the fixed-point floor of 5/100")
  Assert.equal(squashed.pictureYOffset, 38, "and parks the row at the flattened picture's offset")

  -- The second and third copies wait 7 and 13 frames and own no scene write:
  -- the presented squash is finished long before the round closes, and only
  -- those delays decide when the next round starts.
  step(task, 13)
  Assert.equal(scene:pictureState(ATTACKER).affineWidth, 11, "the later copies only extend the round")
  Assert.equal(task:status(), "running", "the round has not closed yet")
  step(task, 3)
  Assert.equal(
    scene:pictureState(ATTACKER).affineWidth,
    207,
    "the second round re-seats the copies and squashes again nineteen ticks later"
  )
  task:dispose()
end

function T.squash_restores_hides_the_picture_and_retires_on_its_native_tick()
  local scene = sceneWithPair()
  pinBystander(scene, DEFENDER)
  local task = spawn(scene, SQUASH_KIND)
  step(task, 63)
  Assert.equal(scene:pictureState(ATTACKER).affineWidth, 60, "the restore leg climbs one step per frame")
  step(task, 4)
  local restored = scene:pictureState(ATTACKER)
  Assert.equal(restored.affineWidth, 256, "the fifth restore tick returns the authored scale")
  Assert.equal(restored.pictureYOffset, 0, "and the authored row")
  Assert.equal(task:status(), "running", "the exhausted restore frame has not retired the task")

  step(task, 2)
  Assert.equal(task:status(), "complete", "the destroy frame retires the task on its sixty-ninth tick")
  local hidden = assert(scene:pictureState(ATTACKER), "the destroy frame leaves the hidden picture pose")
  Assert.equal(hidden.pictureVisible, false, "the source hides the shown picture for good")
  Assert.isNil(hidden.affineWidth, "the terminal pose drops the transient affine overlay")
  Assert.isNil(scene:blendCoefficients(), "completion drops the owned blend register")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "the bystander overlay survives completion")
end

function T.squash_cancellation_restores_the_picture_once()
  local scene = sceneWithPair()
  pinBystander(scene, DEFENDER)
  local cancelled = spawn(scene, SQUASH_KIND)
  step(cancelled, 30)
  Assert.notNil(scene:pictureState(ATTACKER), "the squash owns the picture mid-run")
  Assert.notNil(scene:blendCoefficients(), "and its blend register")
  cancelled:cancel("withdrawn")
  Assert.equal(cancelled:status(), "cancelled", "cancellation lands on cancelled")
  Assert.isNil(scene:pictureState(ATTACKER), "cancellation restores the owned picture")
  Assert.isNil(scene:blendCoefficients(), "cancellation drops the owned blend register")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "cancellation never touches the other side")
  cancelled:cancel("repeated")
  cancelled:dispose()
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "repeated release stays exactly once")
end

-- BattleAnimFunc_RockOrShakeAttacker (battle_anim_move_effects.c, selector 27):
-- a zero script arg 0 turns the attacker picture through the five
-- gBattleAnimRockAttackerSteps rows, each played from its negative angle and
-- back. The callback's POKEPIC_YPIVOT 100 write has no scene expression, so
-- the rotation turns around the picture centre.
function T.rock_turns_the_attacker_through_the_source_angle_rows()
  local scene = sceneWithPair()
  local task = spawn(scene, OSCILLATION_KIND)
  Assert.equal(task:status(), "pending", "the rock opens pending")
  Assert.isNil(scene:pictureState(ATTACKER), "the callback writes only the picture's Y pivot")
  Assert.isNil(scene:blendCoefficients(), "the rock writes no blend register")

  task:stepSourceTick({ tick = 1 })
  Assert.equal(
    scene:pictureState(ATTACKER).rotationZ,
    64322,
    "the 3640 row turns down to -1214 and the 16-bit ZROT store keeps that word"
  )
  step(task, 1)
  Assert.equal(scene:pictureState(ATTACKER).rotationZ, 1212, "the second tick lands one step past the upright pose")
  step(task, 1)
  Assert.equal(scene:pictureState(ATTACKER).rotationZ, 3638, "the third tick reaches the row's negative of its start")
  step(task, 1)
  Assert.equal(
    scene:pictureState(ATTACKER).rotationZ,
    3638,
    "the exhausted frame writes nothing while the machine keeps the row's positive angle"
  )
  step(task, 1)
  Assert.equal(scene:pictureState(ATTACKER).rotationZ, 1213, "the second pass turns back from the row's positive angle")
end

-- The rock never touches the target picture, never leaves a translation on the
-- attacker, and retires on the destroy frame after the fifth row's second pass.
function T.rock_holds_the_zero_row_and_retires_on_the_destroy_frame()
  local scene = sceneWithPair()
  pinBystander(scene, DEFENDER)
  local task = spawn(scene, OSCILLATION_KIND)
  step(task, 30)
  local parked = assert(scene:pictureState(ATTACKER), "the rock keeps the rotated picture")
  Assert.equal(parked.rotationZ, 0, "the fifth row's zero angle holds the picture upright")
  Assert.isNil(parked.pictureXOffset, "the rock never translates the picture")
  Assert.isNil(parked.pictureYOffset, "the Y pivot write has no scene expression")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "the rock never patches the target picture")

  step(task, 2)
  Assert.equal(task:status(), "running", "the tenth pass retires inside the run")
  step(task, 1)
  Assert.equal(task:status(), "complete", "ten passes and the destroy frame take 33 ticks")
  Assert.isNil(scene:pictureState(ATTACKER), "completion restores the rotated picture")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "the bystander overlay survives completion")
end

function T.rock_cancellation_restores_the_picture_once()
  local scene = sceneWithPair()
  pinBystander(scene, DEFENDER)
  local cancelled = spawn(scene, OSCILLATION_KIND)
  step(cancelled, 9)
  Assert.notNil(scene:pictureState(ATTACKER), "the rock owns the picture mid-run")
  cancelled:cancel("withdrawn")
  Assert.equal(cancelled:status(), "cancelled", "cancellation lands on cancelled")
  Assert.isNil(scene:pictureState(ATTACKER), "cancellation restores the owned picture")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "cancellation never touches the other side")
  cancelled:cancel("repeated")
  cancelled:dispose()
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "repeated release stays exactly once")
end

-- A non-zero script arg 0 runs the defender shake instead: the source reads
-- args 1..4 as the amplitude, the per-phase tick interval, and the round count,
-- and the machine seats the shake on its init frame before displacing the
-- picture against its authored position every active frame.
function T.shake_displaces_the_target_picture_on_the_lowered_words()
  local scene = sceneWithPair()
  local task = spawn(scene, OSCILLATION_KIND, {
    shake = 1,
    shakeAmpX = 6,
    shakeAmpY = 2,
    shakeInterval = 2,
    shakeCount = 3,
  })
  task:stepSourceTick({ tick = 1 })
  Assert.isNil(scene:pictureState(DEFENDER), "the init frame only seats the shake motion")
  step(task, 1)
  local first = assert(scene:pictureState(DEFENDER), "the shake owns the target picture")
  Assert.equal(first.pictureXOffset, 6, "the first phase steps to the positive amplitude")
  Assert.equal(first.pictureYOffset, 2, "and to the vertical amplitude")
  Assert.isNil(scene:pictureState(ATTACKER), "the shake never turns the attacker picture")

  step(task, 3)
  Assert.equal(scene:pictureState(DEFENDER).pictureXOffset, 0, "the two-tick interval holds one phase per step")
  step(task, 1)
  Assert.equal(scene:pictureState(DEFENDER).pictureXOffset, -6, "the third phase mirrors the amplitude")
  Assert.equal(scene:pictureState(DEFENDER).pictureYOffset, -2, "on both axes")

  Assert.equal(
    tickUntilComplete(task),
    20,
    "the remaining shake frames, the exhausted frame, and the destroy frame take 20 ticks"
  )
  Assert.isNil(scene:pictureState(DEFENDER), "completion restores the shaken picture")
end

-- The shake branch cannot invent the amplitude words its script args carry, so
-- a selector without them fails closed instead of guessing a budget.
function T.shake_requires_the_amplitude_words_its_selector_names()
  local scene = sceneWithPair()
  local ok, failure = pcall(BattleEffectTasks.create, OSCILLATION_KIND, {
    callback = OSCILLATION_KIND,
    taskContext = "pokemon-picture",
    parameters = { shake = 1 },
  }, occurrenceContext(), services(scene))
  Assert.isFalse(ok, "a shake selector without its amplitude words never yields a runnable task")
  Assert.isTrue(
    string.find(tostring(failure), "BATTLE_EFFECT_TASK_MALFORMED", 1, true) ~= nil,
    "the operand-less shake fails closed: " .. tostring(failure)
  )
  Assert.isNil(scene:pictureState(ATTACKER), "the rejected construction owns no activation patch")
  Assert.isNil(scene:pictureState(DEFENDER), "on either side")
end

-- A third observed activation nobody addresses, so a pair body's release can
-- prove it never touches a picture outside the pair.
local BYSTANDER = { combatant = 5, activation = 5 }

local function sceneWithBystander()
  local scene = sceneWithPair()
  scene:observe({ { combatant = BYSTANDER.combatant, activation = BYSTANDER.activation, visible = true } })
  return scene
end

-- BattleAnimFunc_DarkSpriteJump (battle_anim_effects.c, selector 32): the fade
-- frames walk the battlefield pair to 8/8, then the attacker's rising copy
-- stretches to twice its height, shrinks its width to a tenth, and is hidden
-- again before the defender's copy drops from sixty-four pixels above.
function T.affine_pair_raises_drops_and_fades_the_paired_pictures()
  local scene = sceneWithBystander()
  pinBystander(scene, BYSTANDER)
  local task = spawn(scene, AFFINE_PAIR_KIND)
  task:stepSourceTick({ tick = 1 })
  local opened = assert(scene:blendCoefficients(), "the fade-in frame opens the battlefield pair")
  Assert.equal(opened.blendCoefficientA, 0, "the sprite weight starts at zero")
  Assert.equal(opened.blendCoefficientB, 16, "and the battlefield weight at full")
  Assert.isNil(scene:pictureState(ATTACKER), "the fade-in frames raise no picture")
  Assert.isNil(scene:pictureState(DEFENDER), "on either side")

  step(task, 1)
  local walked = assert(scene:blendCoefficients())
  Assert.equal(walked.blendCoefficientA, 1, "the walk raises one sprite weight per frame")
  Assert.equal(walked.blendCoefficientB, 15, "and lowers the battlefield weight with it")
  step(task, 7)
  local balanced = assert(scene:blendCoefficients())
  Assert.equal(balanced.blendCoefficientA, 8, "the eighth walk frame reaches the sprite weight")
  Assert.equal(balanced.blendCoefficientB, 8, "and the matching battlefield weight")
  Assert.isNil(scene:pictureState(ATTACKER), "the rise opens only after the walk is spent")

  step(task, 1)
  local raised = assert(scene:pictureState(ATTACKER), "the rise opens on the attacker picture")
  Assert.equal(raised.affineWidth, 256, "at the authored width")
  Assert.equal(raised.affineHeight, 256, "and height")
  Assert.equal(raised.pictureYOffset, 0, "on the authored row")

  step(task, 1)
  local stretched = assert(scene:pictureState(ATTACKER))
  Assert.equal(stretched.affineHeight, 288, "the first stretch tick covers one eighth of the doubling")
  Assert.equal(stretched.affineWidth, 256, "while the width holds")
  Assert.equal(stretched.pictureYOffset, -5, "the taller row lifts the picture by half the height it gains")

  step(task, 6)
  Assert.equal(
    scene:pictureState(ATTACKER).affineHeight,
    480,
    "the seventh stretch tick stops one step short of double"
  )
  step(task, 1)
  local shrinking = assert(scene:pictureState(ATTACKER))
  Assert.equal(shrinking.affineWidth, 198, "the width leg then shrinks a quarter of the way to a tenth")
  Assert.equal(shrinking.affineHeight, 512, "at the doubled height the stretch reached")
  Assert.equal(shrinking.pictureYOffset, -40, "and the flattened row offset of that height")

  step(task, 3)
  Assert.equal(scene:pictureState(ATTACKER).affineWidth, 25, "the fourth width step reaches a tenth of the picture")
  step(task, 1)
  local parked = assert(scene:pictureState(ATTACKER), "the rise copy is hidden behind the authored picture")
  Assert.equal(parked.affineWidth, 256, "which keeps its authored width")
  Assert.equal(parked.affineHeight, 256, "and height")
  Assert.equal(parked.pictureYOffset, 0, "and row")

  Assert.isNil(scene:pictureState(DEFENDER), "the two-frame delay holds the target picture")
  step(task, 3)
  local dropped = assert(scene:pictureState(DEFENDER), "the drop frame shows the target picture")
  Assert.equal(dropped.pictureYOffset, -56, "one linear step below the sixty-four pixel reach")
  Assert.equal(dropped.affineWidth, 51, "the falling copy opens on the two-tenths width")
  Assert.equal(dropped.affineHeight, 512, "and twice its height")

  step(task, 7)
  Assert.equal(scene:pictureState(DEFENDER).pictureYOffset, 0, "seven fall ticks land the copy on the authored row")
  step(task, 1)
  local landing = assert(scene:pictureState(DEFENDER))
  Assert.equal(landing.affineWidth, 76, "the landing leg widens the copy one eighth per tick")
  Assert.equal(landing.affineHeight, 480, "and lowers its doubled height")

  step(task, 8)
  local settled = assert(scene:pictureState(DEFENDER))
  Assert.equal(settled.affineWidth, 256, "the exhausted landing frame holds the authored width")
  Assert.equal(settled.affineHeight, 256, "and height")
  Assert.equal(settled.pictureYOffset, 0, "on the authored row")

  local fading = assert(scene:blendCoefficients(), "the landing frame starts the fade-out walk")
  Assert.equal(fading.blendCoefficientA, 8, "from the sprite weight the fade-in left")
  Assert.equal(fading.blendCoefficientB, 8, "and the matching battlefield weight")
  step(task, 1)
  local walked = assert(scene:blendCoefficients())
  Assert.equal(walked.blendCoefficientA, 7, "the fade-out walk lowers one weight per frame")
  Assert.equal(walked.blendCoefficientB, 9, "and raises the battlefield weight")

  Assert.equal(
    tickUntilComplete(task),
    9,
    "the remaining fade-out walk, its closing frame, and the destroy frame take 9 ticks"
  )
  Assert.isNil(scene:blendCoefficients(), "completion drops the owned blend register")
  Assert.isNil(scene:pictureState(ATTACKER), "and restores the raised picture")
  Assert.isNil(scene:pictureState(DEFENDER), "and the dropped one")
  Assert.isTrue(scene:pictureState(BYSTANDER).pictureVisible == true, "the bystander overlay survives completion")
end

function T.affine_pair_cancellation_restores_both_pictures_once()
  local scene = sceneWithBystander()
  pinBystander(scene, BYSTANDER)
  local cancelled = spawn(scene, AFFINE_PAIR_KIND)
  step(cancelled, 30)
  Assert.notNil(scene:pictureState(ATTACKER), "the pair owns the attacker picture mid-run")
  Assert.notNil(scene:pictureState(DEFENDER), "and the target picture")
  cancelled:cancel("withdrawn")
  Assert.equal(cancelled:status(), "cancelled", "cancellation lands on cancelled")
  Assert.isNil(scene:pictureState(ATTACKER), "cancellation restores the attacker picture")
  Assert.isNil(scene:pictureState(DEFENDER), "and the target picture")
  Assert.isNil(scene:blendCoefficients(), "and drops the owned blend register")
  Assert.isTrue(scene:pictureState(BYSTANDER).pictureVisible == true, "cancellation never touches a third picture")
  cancelled:cancel("repeated")
  cancelled:dispose()
  Assert.isTrue(scene:pictureState(BYSTANDER).pictureVisible == true, "repeated release stays exactly once")
end

return { tests = T }
