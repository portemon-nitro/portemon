-- Owner tests for the source-timed scale/offset picture bodies: each kind
-- reproduces one overlay-07 callback whose native machine owns its whole
-- timeline (battle_anim_move_effects.c, battle_anim_effects.c). The tests
-- prove the source phase writes, the native tick boundary, and the
-- exactly-once restoration of the presented picture.

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

-- Exact shape of the occurrence topology the player publishes: the native
-- callback addresses its own battler, so the bodies resolve the presented
-- picture from the sides instead of a lowered battler target.
local function occurrenceContext(attackerSideType)
  return {
    launchId = "scale-motion-probe",
    packetId = 1,
    programKey = "scale-motion-probe",
    seed = 4242,
    random = function(bound)
      assert(type(bound) == "number" and bound >= 1, "visual draws name a positive bound")
      return 0
    end,
    topology = {
      attacker = { combatant = 1, activation = 1, slot = "solo-player", sideType = attackerSideType or 0 },
      targets = { { combatant = 3, activation = 3, slot = "solo-enemy", sideType = 1 } },
    },
    event = { sequence = 1, actionId = 1, hitIndex = 1, effectKey = "scale-motion-probe" },
    visualSeed = 4242,
  }
end

local function services(scene)
  return { scene = scene, audio = {}, resources = {} }
end

-- The producer's lowered task context per kind; the rest of these callbacks
-- lower "pokemon-picture".
local TASK_CONTEXT = {
  ["pokemon-picture-affine-blend-palette-transition"] = "battle-display",
}

local function spawn(scene, kind, parameters, context)
  return assert(BattleEffectTasks.create(kind, {
    callback = kind,
    taskContext = TASK_CONTEXT[kind] or "pokemon-picture",
    parameters = parameters or {},
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

-- BattleAnimFunc_AttackerRecoilTilt (battle_anim_move_effects.c, selector 9):
-- a 32-pixel recoil away from the defender over three ticks, an eight-tick
-- 0xE38 tilt, a two-tick wait, a two-tick return, a 32-tick hold, the
-- untilt over four ticks, and the authored pose on the retirement tick.
function T.recoil_tilt_ramps_its_recoil_then_its_tilt()
  local scene = sceneWithPair()
  local task = spawn(scene, "pokemon-picture-battler-pair-scale-transition")
  Assert.equal(task:status(), "pending", "the recoil opens pending")
  task:stepSourceTick({ tick = 1 })
  local first = scene:pictureState(ATTACKER)
  Assert.notNil(first, "the recoil writes the attacker picture")
  Assert.equal(first.pictureXOffset, -11, "the first recoil tick covers a third of the 32 pixels")
  Assert.equal(first.pictureYOffset, 0, "the recoil never lifts the picture")
  step(task, 1)
  Assert.equal(scene:pictureState(ATTACKER).pictureXOffset, -22, "the recoil keeps spending its fixed step")
  step(task, 1)
  Assert.equal(scene:pictureState(ATTACKER).pictureXOffset, -33, "the third recoil tick is the task's last")
  step(task, 1)
  Assert.equal(scene:pictureState(ATTACKER).pictureXOffset, -33, "the exhausted recoil motion holds its reach")
  step(task, 1)
  local tilted = scene:pictureState(ATTACKER)
  Assert.equal(tilted.rotationZ, 455, "the tilt ramps one eighth of a turn in eight ticks")
  Assert.equal(tilted.pictureXOffset, -33, "the tilt keeps the recoiled offset")
end

function T.recoil_tilt_retires_on_its_native_tick_and_restores_the_picture()
  local scene = sceneWithPair()
  pinBystander(scene, DEFENDER)
  local task = spawn(scene, "pokemon-picture-battler-pair-scale-transition")
  Assert.equal(tickUntilComplete(task), 58, "the recoil/tilt task retires on its native 58th tick")
  Assert.isNil(scene:pictureState(ATTACKER), "completion restores the attacker picture")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "the bystander overlay survives completion")

  local cancelled = spawn(scene, "pokemon-picture-battler-pair-scale-transition")
  step(cancelled, 6)
  Assert.notNil(scene:pictureState(ATTACKER), "the tilt owns the picture mid-run")
  cancelled:cancel("withdrawn")
  Assert.equal(cancelled:status(), "cancelled", "cancellation lands on cancelled")
  Assert.isNil(scene:pictureState(ATTACKER), "cancellation restores the owned picture")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "cancellation never touches the other side")
  cancelled:cancel("repeated")
  cancelled:dispose()
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "repeated release stays exactly once")
end

function T.recoil_tilt_mirrors_the_enemy_side()
  local scene = sceneWithPair()
  local task = spawn(scene, "pokemon-picture-battler-pair-scale-transition", {}, occurrenceContext(1))
  task:stepSourceTick({ tick = 1 })
  Assert.equal(scene:pictureState(ATTACKER).pictureXOffset, 10, "the enemy-side recoil leans the other way")
  step(task, 4)
  Assert.equal(scene:pictureState(ATTACKER).rotationZ, 65081, "the enemy-side tilt wraps into the 16-bit angle")
end

-- BattleAnimFunc_AttackerStretchSteps (battle_anim_move_effects.c, selector
-- 14): three gBattleAnimAttackerStretchSteps scale rows of eight ticks each,
-- every one of them writing the affine pair and the scale-aligned row.
function T.stretch_steps_walk_the_source_rows()
  local scene = sceneWithPair()
  local task = spawn(scene, "pokemon-picture-table-driven-position-transition")
  task:stepSourceTick({ tick = 1 })
  Assert.isNil(scene:pictureState(ATTACKER), "the first row only initializes the scale motion")
  task:stepSourceTick({ tick = 1 })
  local first = scene:pictureState(ATTACKER)
  Assert.equal(first.affineMode, true, "the stretch drives the affine pair")
  Assert.equal(first.affineWidth, 272, "the first row stretches the width one step toward 150/100")
  Assert.equal(first.affineHeight, 240, "the first row squeezes the height one step toward 50/100")
  Assert.isTrue(type(first.pictureYOffset) == "number", "the row is aligned through the scale offset")
  step(task, 7)
  local last = scene:pictureState(ATTACKER)
  Assert.equal(last.affineWidth, 384, "the first row reaches its 150/100 width")
  Assert.equal(last.affineHeight, 128, "the first row reaches its 50/100 height")
  Assert.isTrue(first.pictureYOffset ~= last.pictureYOffset, "the alignment follows the row's scale")
end

function T.stretch_steps_retire_on_their_native_tick_and_restore()
  local scene = sceneWithPair()
  pinBystander(scene, DEFENDER)
  local task = spawn(scene, "pokemon-picture-table-driven-position-transition")
  Assert.equal(tickUntilComplete(task), 31, "three eight-tick rows plus their start/retire frames take 31 ticks")
  Assert.isNil(scene:pictureState(ATTACKER), "completion restores the attacker picture")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "the bystander overlay survives completion")

  local cancelled = spawn(scene, "pokemon-picture-table-driven-position-transition")
  step(cancelled, 4)
  Assert.notNil(scene:pictureState(ATTACKER), "the stretch owns the picture mid-run")
  cancelled:cancel("withdrawn")
  Assert.isNil(scene:pictureState(ATTACKER), "cancellation restores the owned picture")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "cancellation never touches the other side")
  cancelled:cancel("repeated")
  cancelled:dispose()
end

-- BattleAnimFunc_AttackerHop (battle_anim_move_effects.c, selector 19):
-- three gBattleAnimAttackerHopScales/gBattleAnimAttackerHopOffsets legs of
-- five ticks, repeated three rounds, each leg writing the affine pair and
-- the hop row aligned to the current scale.
function T.attacker_hop_ramps_scale_and_hop_row_together()
  local scene = sceneWithPair()
  local task = spawn(scene, "pokemon-picture-repeated-scale-position-transition")
  task:stepSourceTick({ tick = 1 })
  Assert.isNil(scene:pictureState(ATTACKER), "the first leg only initializes its motions")
  task:stepSourceTick({ tick = 1 })
  local first = scene:pictureState(ATTACKER)
  Assert.equal(first.affineWidth, 266, "the first leg widens toward 120/100")
  Assert.equal(first.affineHeight, 245, "the first leg shortens toward 80/100")
  Assert.equal(first.pictureYOffset, 4, "the first leg starts its 16-pixel rise along the row alignment")
  step(task, 4)
  local landed = scene:pictureState(ATTACKER)
  Assert.equal(landed.affineWidth, 306, "the first leg reaches its 120/100 width")
  Assert.equal(landed.affineHeight, 204, "the first leg reaches its 80/100 height")
  Assert.equal(landed.pictureYOffset, 23, "the fifth leg tick parks the row on its 16-pixel rise")
end

function T.attacker_hop_retires_on_its_native_tick_and_restores()
  local scene = sceneWithPair()
  pinBystander(scene, DEFENDER)
  local task = spawn(scene, "pokemon-picture-repeated-scale-position-transition")
  Assert.equal(tickUntilComplete(task), 64, "nine hop legs of seven ticks and the retire frame take 64 ticks")
  Assert.isNil(scene:pictureState(ATTACKER), "completion restores the attacker picture")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "the bystander overlay survives completion")

  local cancelled = spawn(scene, "pokemon-picture-repeated-scale-position-transition")
  step(cancelled, 9)
  Assert.notNil(scene:pictureState(ATTACKER), "the hop owns the picture mid-run")
  cancelled:cancel("withdrawn")
  Assert.isNil(scene:pictureState(ATTACKER), "cancellation restores the owned picture")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "cancellation never touches the other side")
  cancelled:dispose()
end

-- BattleAnimFunc_StretchShakeDefender (battle_anim_effects.c, selector 43):
-- a four-tick stretch to 7/10 by 30/10 wrapped in the two-round horizontal
-- shake, then the three-tick reciprocal restore, then the authored pose.
function T.stretch_shake_defender_stretches_and_shakes_the_target()
  local scene = sceneWithPair()
  pinBystander(scene, ATTACKER)
  local task = spawn(scene, "pokemon-picture-reciprocal-position-palette-transition")
  task:stepSourceTick({ tick = 1 })
  local first = scene:pictureState(DEFENDER)
  Assert.notNil(first, "the stretch writes the defender picture")
  Assert.equal(first.affineWidth, 236, "the stretch narrows toward 7/10")
  Assert.equal(first.affineHeight, 384, "the stretch deepens toward 30/10")
  Assert.equal(first.pictureXOffset, 2, "the first shake round displacements the picture")
  Assert.isTrue(first.pictureYOffset < 0, "the growing picture is lifted by the row alignment")
  task:stepSourceTick({ tick = 1 })
  Assert.equal(scene:pictureState(DEFENDER).pictureXOffset, 0, "the shake crosses its centre on the next tick")
  task:stepSourceTick({ tick = 1 })
  Assert.equal(scene:pictureState(DEFENDER).pictureXOffset, -2, "the third tick displaces the other way")
  Assert.isTrue(scene:pictureState(ATTACKER).pictureVisible == true, "the attacker picture stays untouched")
end

function T.stretch_shake_defender_retires_on_its_native_tick_and_restores()
  local scene = sceneWithPair()
  pinBystander(scene, ATTACKER)
  local task = spawn(scene, "pokemon-picture-reciprocal-position-palette-transition")
  Assert.equal(tickUntilComplete(task), 10, "the stretch, restore, and end frames take 10 ticks")
  Assert.isNil(scene:pictureState(DEFENDER), "completion restores the defender picture")
  Assert.isTrue(scene:pictureState(ATTACKER).pictureVisible == true, "the bystander overlay survives completion")

  local cancelled = spawn(scene, "pokemon-picture-reciprocal-position-palette-transition")
  step(cancelled, 3)
  Assert.notNil(scene:pictureState(DEFENDER), "the stretch owns the defender picture mid-run")
  cancelled:cancel("withdrawn")
  Assert.isNil(scene:pictureState(DEFENDER), "cancellation restores the owned picture")
  Assert.isTrue(scene:pictureState(ATTACKER).pictureVisible == true, "cancellation never touches the attacker")
  cancelled:cancel("repeated")
  cancelled:dispose()
end

-- BattleAnimFunc_StretchFadeSprite (battle_anim_move_effects.c, selector 49):
-- the entry tick squashes the picture flat, twelve ticks stretch it tall
-- while the alpha pair ramps, four ticks hold, twelve ticks shrink it back,
-- and the source frees the sprite one tick after the last scale step.
function T.stretch_fade_sprite_publishes_its_entry_pose_and_alpha_ramp()
  local scene = sceneWithPair()
  local task = spawn(scene, "pokemon-picture-affine-sprite-entry-transition")
  local entry = scene:pictureState(ATTACKER)
  Assert.notNil(entry, "the entry tick already writes the picture")
  Assert.equal(entry.affineWidth, 256, "the entry keeps the authored width")
  Assert.equal(entry.affineHeight, 12, "the entry flattens the picture to 5/100")
  task:stepSourceTick({ tick = 1 })
  Assert.isNil(scene:blendCoefficients(), "the initialize tick writes no alpha pair")
  task:stepSourceTick({ tick = 1 })
  local stretched = scene:pictureState(ATTACKER)
  Assert.equal(stretched.affineWidth, 247, "the stretch starts from the flattened entry scale")
  Assert.equal(stretched.affineHeight, 43, "the stretch grows the height one step toward 150/100")
  local blend = assert(scene:blendCoefficients())
  Assert.equal(blend.blendCoefficientA, 1, "the alpha pair ramps one coefficient per stretch tick")
  Assert.equal(blend.blendCoefficientB, 30, "the background weight ramps down with it")
end

function T.stretch_fade_sprite_retires_on_its_native_tick_and_restores()
  local scene = sceneWithPair()
  pinBystander(scene, DEFENDER)
  local task = spawn(scene, "pokemon-picture-affine-sprite-entry-transition")
  Assert.equal(tickUntilComplete(task), 32, "the stretch, hold, shrink, and free frames take 32 ticks")
  Assert.isNil(scene:pictureState(ATTACKER), "completion restores the attacker picture")
  Assert.isNil(scene:blendCoefficients(), "completion drops the owned alpha pair")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "the bystander overlay survives completion")

  local cancelled = spawn(scene, "pokemon-picture-affine-sprite-entry-transition")
  step(cancelled, 5)
  Assert.notNil(scene:blendCoefficients(), "the ramp owns the alpha pair mid-run")
  cancelled:cancel("withdrawn")
  Assert.isNil(scene:pictureState(ATTACKER), "cancellation restores the owned picture")
  Assert.isNil(scene:blendCoefficients(), "cancellation drops the owned alpha pair")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "cancellation never touches the other side")
  cancelled:cancel("repeated")
  cancelled:dispose()
end

-- BattleAnimFunc_ShrinkSpriteOnDefender (battle_anim_move_effects.c,
-- selector 58): ten ticks shrinking the defender's battler sprites to
-- 20/100, then the hide-and-destroy frame.
function T.shrink_sprite_on_defender_ramps_the_source_scale()
  local scene = sceneWithPair()
  local task = spawn(scene, "pokemon-picture-three-sprite-position-wave-transition")
  task:stepSourceTick({ tick = 1 })
  local first = scene:pictureState(DEFENDER)
  Assert.notNil(first, "the shrink writes the defender picture")
  Assert.equal(first.affineMode, true, "the shrink drives the affine pair")
  Assert.equal(first.affineWidth, 235, "the first tick closes one tenth of the 100/20 scale")
  Assert.equal(first.affineHeight, 235, "the shrink is uniform")
  step(task, 9)
  local last = scene:pictureState(DEFENDER)
  Assert.equal(last.affineWidth, 51, "the ramp lands on the 20/100 target")
  Assert.equal(last.affineHeight, 51, "the ramp lands on the 20/100 target")
end

function T.shrink_sprite_on_defender_retires_without_a_terminal_pose()
  -- The native hides its own script-created battler sprite copies on the
  -- retire tick; the presented picture is not one of those copies, so the
  -- body never publishes a vanish write and restores the picture instead.
  local scene = sceneWithPair()
  pinBystander(scene, ATTACKER)
  local task = spawn(scene, "pokemon-picture-three-sprite-position-wave-transition")
  local vanished = false
  local spent = 0
  while task:status() ~= "complete" do
    task:stepSourceTick({ tick = 1 })
    spent = spent + 1
    local state = scene:pictureState(DEFENDER)
    if state ~= nil and (state.vanished == true or state.pictureVisible == false) then
      vanished = true
    end
    assert(spent <= 40, "the shrink retires on its own tick")
  end
  Assert.equal(spent, 11, "ten scale ticks and the hide frame take 11 ticks")
  Assert.isFalse(vanished, "the presented picture is never hidden like a sprite copy")
  Assert.isNil(scene:pictureState(DEFENDER), "completion restores the defender picture")
  Assert.isTrue(scene:pictureState(ATTACKER).pictureVisible == true, "the bystander overlay survives completion")

  local cancelled = spawn(scene, "pokemon-picture-three-sprite-position-wave-transition")
  step(cancelled, 4)
  cancelled:cancel("withdrawn")
  Assert.isNil(scene:pictureState(DEFENDER), "cancellation restores the owned picture")
  Assert.isTrue(scene:pictureState(ATTACKER).pictureVisible == true, "cancellation never touches the other side")
  cancelled:dispose()
end

-- BattleAnimFunc_SquashSprite (battle_anim_move_effects.c, selector 70):
-- the source callback runs its first machine frame itself
-- (BattleAnim_CreateTaskAndRun), so fifteen alpha-pair frames, three squash
-- frames and the hide frame precede the two palette-blend legs.
function T.squash_sprite_ramps_the_alpha_pair_then_squashes_flat()
  local scene = sceneWithPair()
  local task = spawn(scene, "pokemon-picture-affine-blend-palette-transition")
  local entry = assert(scene:blendCoefficients())
  Assert.equal(entry.blendCoefficientA, 1, "the callback's own first frame ramps the alpha pair once")
  Assert.equal(entry.blendCoefficientB, 14, "the background weight starts at 15 and drops")
  Assert.equal(scene:pictureState(ATTACKER).affineWidth, 256, "the squash starts from the authored scale")
  step(task, 14)
  local ramped = assert(scene:blendCoefficients())
  Assert.equal(ramped.blendCoefficientA, 15, "the alpha pair reaches its fifteenth frame")
  Assert.equal(ramped.blendCoefficientB, 0, "the background weight reaches zero with it")
  task:stepSourceTick({ tick = 1 })
  local squashed = scene:pictureState(ATTACKER)
  Assert.equal(squashed.affineWidth, 307, "the squash widens a fifth per frame")
  Assert.equal(squashed.affineHeight, 204, "the squash flattens a fifth per frame")
  step(task, 2)
  local flat = scene:pictureState(ATTACKER)
  Assert.equal(flat.affineWidth, 409, "the third squash frame reaches 1.6 width")
  Assert.equal(flat.affineHeight, 102, "the third squash frame reaches 0.4 height")
  task:stepSourceTick({ tick = 1 })
  local hidden = scene:pictureState(ATTACKER)
  Assert.equal(hidden.pictureVisible, false, "the fourth squash frame hides the flattened picture")
  Assert.equal(hidden.vanished, true, "the hide is the native vanished write")
end

function T.squash_sprite_retires_on_its_native_tick_and_restores()
  local scene = sceneWithPair()
  pinBystander(scene, DEFENDER)
  local task = spawn(scene, "pokemon-picture-affine-blend-palette-transition")
  Assert.equal(tickUntilComplete(task), 36, "the squash and both palette-blend legs take 36 stepped ticks")
  Assert.isNil(scene:pictureState(ATTACKER), "completion restores the attacker picture")
  Assert.isNil(scene:blendCoefficients(), "completion drops the owned alpha pair")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "the bystander overlay survives completion")

  local cancelled = spawn(scene, "pokemon-picture-affine-blend-palette-transition")
  step(cancelled, 8)
  Assert.notNil(scene:blendCoefficients(), "the ramp owns the alpha pair mid-run")
  cancelled:cancel("withdrawn")
  Assert.isNil(scene:pictureState(ATTACKER), "cancellation restores the owned picture")
  Assert.isNil(scene:blendCoefficients(), "cancellation drops the owned alpha pair")
  Assert.isTrue(scene:pictureState(DEFENDER).pictureVisible == true, "cancellation never touches the other side")
  cancelled:cancel("repeated")
  cancelled:dispose()
end

function T.scale_motion_kinds_refuse_a_run_without_a_presented_battler()
  local scene = sceneWithPair()
  local context = occurrenceContext()
  context.topology = {}
  for _, kind in ipairs({
    "pokemon-picture-battler-pair-scale-transition",
    "pokemon-picture-table-driven-position-transition",
    "pokemon-picture-repeated-scale-position-transition",
    "pokemon-picture-affine-sprite-entry-transition",
    "pokemon-picture-affine-blend-palette-transition",
  }) do
    Assert.throws(function()
      BattleEffectTasks.create(kind, { callback = kind, parameters = {} }, context, services(scene))
    end, kind .. " never guesses an absent attacker picture")
  end
  for _, kind in ipairs({
    "pokemon-picture-reciprocal-position-palette-transition",
    "pokemon-picture-three-sprite-position-wave-transition",
  }) do
    Assert.throws(function()
      BattleEffectTasks.create(kind, { callback = kind, parameters = {} }, context, services(scene))
    end, kind .. " never guesses an absent target picture")
  end
end

function T.scale_motion_kinds_validate_their_optional_picture_inset()
  local scene = sceneWithPair()
  for _, kind in ipairs({
    "pokemon-picture-table-driven-position-transition",
    "pokemon-picture-repeated-scale-position-transition",
    "pokemon-picture-reciprocal-position-palette-transition",
  }) do
    Assert.throws(function()
      spawn(scene, kind, { pictureInset = -1 })
    end, kind .. " refuses a negative battler picture inset")
    Assert.throws(function()
      spawn(scene, kind, { pictureInset = 1.5 })
    end, kind .. " refuses a fractional battler picture inset")
  end
  local inset = spawn(scene, "pokemon-picture-table-driven-position-transition", { pictureInset = 8 })
  inset:stepSourceTick({ tick = 1 })
  inset:stepSourceTick({ tick = 1 })
  Assert.isTrue(type(scene:pictureState(ATTACKER).pictureYOffset) == "number", "a lowered inset aligns the row")
  inset:cancel("probe")
end

return { tests = T }
