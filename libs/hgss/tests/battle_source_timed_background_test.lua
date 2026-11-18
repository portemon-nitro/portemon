-- Owner tests for the source-timed background wave bodies: each kind
-- reproduces one overlay-07 callback whose native machine owns its whole
-- timeline (battle_anim_effects.c, battle_anim_move_effects.c). The tests
-- prove the source phase writes, the native tick boundary, and the
-- exactly-once restoration of the owned picture and registers.

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

-- Exact shape of the occurrence topology the player publishes: these natives
-- address their own battler (BattleAnimSystem_GetDefender), so the bodies
-- resolve the presented picture from the sides instead of a lowered battler
-- target.
local function occurrenceContext(defenderSideType)
  return {
    launchId = "background-wave-probe",
    packetId = 1,
    programKey = "background-wave-probe",
    seed = 4242,
    random = function(bound)
      assert(type(bound) == "number" and bound >= 1, "visual draws name a positive bound")
      return 0
    end,
    topology = {
      attacker = { combatant = 1, activation = 1, slot = "solo-player", sideType = 0 },
      targets = { { combatant = 3, activation = 3, slot = "solo-enemy", sideType = defenderSideType or 1 } },
    },
    event = { sequence = 1, actionId = 1, hitIndex = 1, effectKey = "background-wave-probe" },
    visualSeed = 4242,
  }
end

local function services(scene)
  return { scene = scene, audio = {}, resources = {} }
end

-- The producer's lowered task context per kind, so the spawn carries exactly
-- the shape the player publishes.
local TASK_CONTEXT = {
  ["battle-background-picture-wipe-transition"] = "battle-display",
  ["pokemon-picture-vanish-affine-transition"] = "pokemon-picture",
  ["battle-background-picture-palette-scroll"] = "battle-display",
  ["battle-display-window-palette-transition"] = "battle-display",
  ["battle-sprite-affine-appearance-transition"] = "battle-sprite",
}

-- The producer lowers no battler target and an empty parameter record for
-- these selectors, so the spawn carries exactly that shape.
local function spawn(scene, kind, context)
  return assert(BattleEffectTasks.create(kind, {
    callback = kind,
    taskContext = TASK_CONTEXT[kind],
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

-- BattleAnimFunc_WaveDefenderOnBg (battle_anim_effects.c, selector 20 of
-- gBattleAnimFuncTable): the callback opens the effect-over-battlefield
-- register pair at 0/16 and starts BattleAnimUtil_InitLinearMotion(0, 8, 16,
-- 8, 24), so one frame later the pokepic vanishes while the walk writes one
-- third of a coefficient per frame.
function T.background_picture_wipe_ramps_holds_and_walks_the_effect_blend()
  local scene = sceneWithPair()
  local task = spawn(scene, "battle-background-picture-wipe-transition", occurrenceContext(2))
  Assert.equal(task:status(), "pending", "the wipe opens pending")
  local opened = assert(scene:blendCoefficients(), "the callback writes its register pair before the first frame")
  Assert.equal(opened.blendCoefficientA, 0, "the effect layer starts fully transparent")
  Assert.equal(opened.blendCoefficientB, 16, "the battlefield starts at the full blend weight")
  Assert.isNil(scene:pictureState(DEFENDER), "the callback frame hides no picture yet")
  task:stepSourceTick({ tick = 1 })
  local hidden = scene:pictureState(DEFENDER)
  Assert.equal(hidden.vanished, true, "the hide state writes POKEPIC_VANISHED on its own frame")
  Assert.equal(hidden.pictureVisible, false, "the vanished picture draws nothing")
  step(task, 3)
  local walked = assert(scene:blendCoefficients())
  Assert.equal(walked.blendCoefficientA, 1, "the fourth walk tick spends its first whole coefficient")
  Assert.equal(walked.blendCoefficientB, 14, "the battlefield weight falls with the effect weight")
  step(task, 20)
  local reached = assert(scene:blendCoefficients())
  Assert.equal(reached.blendCoefficientA, 7, "the walk reaches its truncated EVA endpoint")
  Assert.equal(reached.blendCoefficientB, 8, "the EVB endpoint truncates one step further")
  local scroll = scene:scroll()
  Assert.equal(scroll.x, 0, "the scanline wave never fakes a battlefield viewport sweep")
  Assert.equal(scroll.y, 0, "the scanline wave never fakes a battlefield viewport sweep")

  -- The blend state machine only starts the mirrored walk when its 32-tick
  -- down counter drops below zero, so the thirty-third hold frame after the
  -- reached pair writes the first reverse coefficient one frame after it
  -- starts the walk.
  step(task, 33)
  local held = assert(scene:blendCoefficients())
  Assert.equal(held.blendCoefficientA, 7, "the hold frames write no coefficient of their own")
  Assert.equal(held.blendCoefficientB, 8, "the hold keeps the reached pair")
  task:stepSourceTick({ tick = 1 })
  local restarted = assert(scene:blendCoefficients())
  Assert.equal(restarted.blendCoefficientA, 7, "the frame that starts the reverse walk writes no register")
  Assert.equal(restarted.blendCoefficientB, 8, "the frame that starts the reverse walk writes no register")
  task:stepSourceTick({ tick = 1 })
  local reversing = assert(scene:blendCoefficients())
  Assert.equal(reversing.blendCoefficientA, 7, "the reverse walk starts from the mirrored eight-coefficient pair")
  Assert.equal(reversing.blendCoefficientB, 8, "the battlefield weight starts rising again")
  step(task, 23)
  local crossedBack = assert(scene:blendCoefficients())
  Assert.equal(crossedBack.blendCoefficientA, 0, "the reverse walk returns the effect layer to zero")
  Assert.equal(crossedBack.blendCoefficientB, 15, "the reverse walk returns the battlefield weight")
  Assert.equal(scene:pictureState(DEFENDER).vanished, true, "the picture stays hidden through the reverse walk")
  task:dispose()
end

function T.background_picture_wipe_retires_on_its_native_tick_and_restores()
  local scene = sceneWithPair()
  pinBystander(scene, ATTACKER)
  local task = spawn(scene, "battle-background-picture-wipe-transition", occurrenceContext(2))
  Assert.equal(
    tickUntilComplete(task),
    85,
    "24 walk ticks, 33 hold frames, 24 reverse ticks, and four closing frames take 85"
  )
  Assert.isNil(scene:pictureState(DEFENDER), "completion restores the hidden picture")
  Assert.isNil(scene:blendCoefficients(), "completion drops the owned register pair")
  Assert.isTrue(scene:pictureState(ATTACKER).pictureVisible == true, "the bystander overlay survives completion")

  local cancelled = spawn(scene, "battle-background-picture-wipe-transition", occurrenceContext(2))
  step(cancelled, 40)
  Assert.notNil(scene:pictureState(DEFENDER), "the wave owns the picture mid-run")
  Assert.notNil(scene:blendCoefficients(), "the walk owns the register pair mid-run")
  cancelled:cancel("withdrawn")
  Assert.equal(cancelled:status(), "cancelled", "cancellation lands on cancelled")
  Assert.isNil(scene:pictureState(DEFENDER), "cancellation restores the owned picture")
  Assert.isNil(scene:blendCoefficients(), "cancellation drops the owned register pair")
  Assert.isTrue(scene:pictureState(ATTACKER).pictureVisible == true, "cancellation never touches the attacker side")
  cancelled:cancel("repeated")
  cancelled:dispose()
end

-- The callback's sprite-copy draw flag is FALSE for the remaining native
-- battler types, so the hide state never reaches the pokepic even though the
-- blend walk still runs.
function T.background_picture_wipe_keeps_an_undrawn_defender_picture()
  local scene = sceneWithPair()
  pinBystander(scene, DEFENDER)
  local task = spawn(scene, "battle-background-picture-wipe-transition")
  Assert.equal(tickUntilComplete(task), 85, "the undrawn branch runs the same blend machine")
  Assert.equal(scene:pictureState(DEFENDER).pictureVisible, true, "the undrawn copy never hides the picture")
  Assert.isNil(scene:blendCoefficients(), "completion drops the owned register pair")
end

-- BattleAnimFunc_WaveAttackerOnBg (battle_anim_move_effects.c, selector 55
-- of gBattleAnimFuncTable): the callback starts
-- BattleAnimUtil_InitLinearMotion(16, 2, 2, 16, 16), so the first scheduled
-- frame vanishes the attacker pokepic while the walk writes its first pair and
-- the sixteenth writes the truncated endpoint.
function T.pokemon_picture_vanish_affine_walks_the_fade_and_holds_the_wave()
  local scene = sceneWithPair()
  local task = spawn(scene, "pokemon-picture-vanish-affine-transition")
  Assert.equal(task:status(), "pending", "the wave opens pending")
  Assert.isNil(scene:blendCoefficients(), "the callback itself writes no register pair")
  task:stepSourceTick({ tick = 1 })
  local hidden = scene:pictureState(ATTACKER)
  Assert.equal(hidden.vanished, true, "the hide state writes POKEPIC_VANISHED on its own frame")
  local opened = assert(scene:blendCoefficients())
  Assert.equal(opened.blendCoefficientA, 15, "the walk spends seven eighths of a coefficient per frame")
  Assert.equal(opened.blendCoefficientB, 2, "the battlefield weight starts at its authored word")
  task:stepSourceTick({ tick = 1 })
  local walked = assert(scene:blendCoefficients())
  Assert.equal(walked.blendCoefficientA, 14, "the second walk tick drops one whole coefficient")
  Assert.equal(walked.blendCoefficientB, 3, "the battlefield weight rises with the effect weight")
  step(task, 14)
  local reached = assert(scene:blendCoefficients())
  Assert.equal(reached.blendCoefficientA, 2, "the walk reaches its authored EVA endpoint")
  Assert.equal(reached.blendCoefficientB, 16, "the walk reaches its authored EVB endpoint")
  Assert.isNil(scene:pictureState(DEFENDER), "the defender picture stays untouched")

  -- The wave gate waits for the opening walk's closing frame and then counts
  -- its own 120 frames, so the mirrored walk's first register write lands on
  -- the frame after the wave retires.
  step(task, 1)
  Assert.equal(task:status(), "running", "the wave gate opens the wave on the walk's closing frame")
  local held = assert(scene:blendCoefficients())
  Assert.equal(held.blendCoefficientA, 2, "the wave frames write no coefficient of their own")
  Assert.equal(held.blendCoefficientB, 16, "the wave keeps the reached pair")
  step(task, 119)
  local heldPair = assert(scene:blendCoefficients())
  Assert.equal(heldPair.blendCoefficientA, 2, "the wave frames write no coefficient of their own")
  Assert.equal(heldPair.blendCoefficientB, 16, "the wave keeps the reached pair")
  task:stepSourceTick({ tick = 1 })
  local freed = assert(scene:blendCoefficients())
  Assert.equal(freed.blendCoefficientA, 2, "the frame that frees the wave writes no register")
  Assert.equal(freed.blendCoefficientB, 16, "the frame that frees the wave writes no register")
  task:stepSourceTick({ tick = 1 })
  local reversing = assert(scene:blendCoefficients())
  Assert.equal(reversing.blendCoefficientA, 2, "the mirrored walk starts from its authored pair")
  Assert.equal(reversing.blendCoefficientB, 15, "the battlefield weight walks back down")
  step(task, 15)
  local crossedBack = assert(scene:blendCoefficients())
  Assert.equal(crossedBack.blendCoefficientA, 16, "the mirrored walk returns the effect weight")
  Assert.equal(crossedBack.blendCoefficientB, 2, "the mirrored walk returns the battlefield weight")
  Assert.equal(scene:pictureState(ATTACKER).vanished, true, "the picture stays hidden through the wave")
  task:dispose()
end

-- The source restores POKEPIC_VANISHED on the closing frame of the mirrored
-- walk and destroys its task one frame later.
function T.pokemon_picture_vanish_affine_restores_the_picture_before_retiring()
  local scene = sceneWithPair()
  local task = spawn(scene, "pokemon-picture-vanish-affine-transition")
  Assert.equal(tickUntilComplete(task), 155, "16 fade ticks, 121 gate and wave frames, and 18 closing frames take 155")
  Assert.equal(task:status(), "complete", "the wave retires on its default frame")
  Assert.isNil(scene:pictureState(ATTACKER), "completion restores the hidden picture")
  Assert.isNil(scene:blendCoefficients(), "completion drops the owned register pair")

  local cancelled = spawn(scene, "pokemon-picture-vanish-affine-transition")
  step(cancelled, 5)
  Assert.notNil(scene:pictureState(ATTACKER), "the wave owns the picture mid-run")
  Assert.notNil(scene:blendCoefficients(), "the walk owns the register pair mid-run")
  cancelled:cancel("withdrawn")
  Assert.equal(cancelled:status(), "cancelled", "cancellation lands on cancelled")
  Assert.isNil(scene:pictureState(ATTACKER), "cancellation restores the owned picture")
  Assert.isNil(scene:blendCoefficients(), "cancellation drops the owned register pair")
  cancelled:cancel("repeated")
  cancelled:dispose()
end

-- The battlefield palette writes both flash kinds share: the native palette
-- callbacks blend the battle BG plane, which the scene presents as its
-- battlefield fade.
local function compositorFade(scene)
  local main = assert(scene:animationFrame().main, "the flash publishes its main-engine state")
  return assert(main.compositor.battlefieldFade, "the flash publishes a battlefield fade")
end

-- BattleAnimFunc_ShakeBattlefieldFlashing (battle_anim_move_effects.c,
-- selector 24 of gBattleAnimFuncTable): the opening state starts
-- PaletteData_BeginPaletteFade(MAIN_BG_F, mask, wait 1, cur 0, end 10,
-- RGB_BLACK), a two-coefficient step every other frame.
function T.background_palette_scroll_darkens_then_shakes_the_battlefield()
  local scene = sceneWithPair()
  local task = spawn(scene, "battle-background-picture-palette-scroll")
  Assert.equal(task:status(), "pending", "the shake opens pending")
  task:stepSourceTick({ tick = 1 })
  local opening = compositorFade(scene)
  Assert.equal(opening.amount, 0, "the darken applies its opening zero coefficient inside the call")
  Assert.equal(opening.color.r, 0, "the darken targets RGB_BLACK")
  step(task, 7)
  Assert.equal(compositorFade(scene).amount, 6, "the fourth application of the fade publishes six")
  step(task, 2)
  Assert.equal(compositorFade(scene).amount, 8, "the wait frame between applications writes no coefficient")
  Assert.isNil(scene:pictureState(ATTACKER), "the darken shakes no picture yet")
  Assert.equal(scene:scroll().x, 0, "the darken moves no viewport")

  -- The first SHAKE state starts BattleAnimUtil_InitShake(amplitude, 0, 0, 5)
  -- on the frame the palette task clears its last fade bit, blends the battle
  -- BG at ten sixteenths toward black, and shakes every collected picture X
  -- plus the battlefield BG3 layer.
  step(task, 1)
  local flashing = compositorFade(scene)
  Assert.equal(flashing.amount, 10, "the blink blends the battle BG at its authored ten sixteenths")
  Assert.equal(flashing.color.r, 0, "the first blink targets black")
  Assert.equal(scene:pictureState(ATTACKER).pictureXOffset, 12, "the first phase spends the twelve-pixel amplitude")
  Assert.equal(scene:pictureState(DEFENDER).pictureXOffset, 12, "every collected picture takes the same offset")
  Assert.equal(scene:scroll().x, 12, "the battlefield BG3 register follows the shake")
  task:stepSourceTick({ tick = 1 })
  Assert.equal(scene:pictureState(ATTACKER).pictureXOffset, 0, "the second phase returns the picture column")
  task:stepSourceTick({ tick = 1 })
  local cleared = compositorFade(scene)
  Assert.equal(cleared.amount, 0, "the third flash frame drops the blend back to the opaque palette")
  Assert.equal(scene:pictureState(ATTACKER).pictureXOffset, -12, "the third phase mirrors the amplitude")
  task:stepSourceTick({ tick = 1 })
  Assert.equal(scene:pictureState(ATTACKER).pictureXOffset, 0, "the fourth phase closes the round")
  -- The second amplitude starts one exhausted-shake frame after the first
  -- round's twenty update ticks.
  step(task, 18)
  local second = compositorFade(scene)
  Assert.equal(second.color.r, 31, "the second blink alternates to RGB_WHITE")
  Assert.equal(second.amount, 10, "every blink blends at the same authored strength")
  Assert.equal(scene:pictureState(DEFENDER).pictureXOffset, 10, "the second round walks the ten-pixel amplitude")
  task:cancel("withdrawn")
  task:dispose()
end

function T.background_palette_scroll_retires_after_eight_rounds_and_restores()
  local scene = sceneWithPair()
  local task = spawn(scene, "battle-background-picture-palette-scroll")
  Assert.equal(
    tickUntilComplete(task),
    179,
    "ten darken frames, eight amplitudes of twenty-one ticks, and the closing frame take 179"
  )
  Assert.isNil(scene:pictureState(DEFENDER), "completion restores the shaken picture")
  Assert.isNil(scene:pictureState(ATTACKER), "completion restores every picture the shake moved")
  Assert.isTrue(
    scene:animationFrame().main.compositor.battlefieldFade == nil,
    "completion drops the owned battlefield fade"
  )
  Assert.equal(scene:scroll().x, 0, "completion restores the authored viewport column")

  local cancelled = spawn(scene, "battle-background-picture-palette-scroll")
  step(cancelled, 12)
  Assert.notNil(scene:pictureState(DEFENDER), "the shake owns the picture mid-run")
  Assert.notNil(compositorFade(scene), "the flash owns the compositor mid-run")
  cancelled:cancel("withdrawn")
  Assert.equal(cancelled:status(), "cancelled", "cancellation lands on cancelled")
  Assert.isNil(scene:pictureState(DEFENDER), "cancellation restores the shaken picture once")
  Assert.isTrue(
    scene:animationFrame().main.compositor.battlefieldFade == nil,
    "cancellation drops the owned battlefield fade once"
  )
  Assert.equal(scene:scroll().x, 0, "cancellation restores the viewport column once")
  cancelled:cancel("repeated")
  cancelled:dispose()
  Assert.equal(scene:scroll().x, 0, "a repeated release leaves the viewport alone")
  Assert.isNil(scene:pictureState(ATTACKER), "a repeated release leaves the pictures alone")
end

-- The shake owns the battlefield viewport and the battle BG palette, not the
-- scanline effect layer or the zero-amplitude vertical axis.
-- BattleAnimFunc_WindowSweepFlashWhite (battle_anim_effects.c, selector 41 of
-- gBattleAnimFuncTable): WINDOW_SWEEP_STATE_DELAY counts seven frames down and
-- starts the sixteen-frame fade toward RGB_WHITE on the eighth.
function T.battle_display_window_palette_ramps_to_white_and_fades_back()
  local scene = sceneWithPair()
  local task = spawn(scene, "battle-display-window-palette-transition")
  Assert.equal(task:status(), "pending", "the sweep opens pending")
  task:stepSourceTick({ tick = 1 })
  Assert.isTrue(
    scene:animationFrame().main.compositor.battlefieldFade == nil,
    "the init frame only arms the window registers"
  )
  step(task, 8)
  local opening = compositorFade(scene)
  Assert.equal(opening.amount, 0, "the fade applies its opening coefficient inside the call")
  Assert.equal(opening.color.r, 31, "the flash targets RGB_WHITE")
  step(task, 3)
  Assert.equal(compositorFade(scene).amount, 6, "the fade spends two coefficients per frame")
  step(task, 5)
  Assert.equal(compositorFade(scene).amount, 16, "the sweep ends on the fully white palette")
  Assert.equal(scene:scroll().x, 0, "the window sweep writes no battlefield viewport")

  -- WINDOW_SWEEP_STATE_WAIT_FLASH holds until the white fade clears, then
  -- closes the window and fades the palette back from sixteen to zero.
  step(task, 5)
  Assert.equal(compositorFade(scene).amount, 10, "the return fade spends two coefficients per frame")
  step(task, 5)
  Assert.equal(compositorFade(scene).amount, 0, "the return fade closes on the opaque palette")
  Assert.equal(task:status(), "running", "the restore gate only opens on the frame after the fade")
  Assert.equal(tickUntilComplete(task, 6), 1, "the restore gate retires one frame after the fade clears")
  Assert.isTrue(
    scene:animationFrame().main.compositor.battlefieldFade == nil,
    "completion drops the owned battlefield fade"
  )
  Assert.isNil(scene:pictureState(ATTACKER), "the window sweep patches no picture")
  task:dispose()
end

function T.battle_display_window_palette_cancels_with_one_restore()
  local scene = sceneWithPair()
  pinBystander(scene, ATTACKER)
  local task = spawn(scene, "battle-display-window-palette-transition")
  step(task, 12)
  Assert.notNil(compositorFade(scene), "the fade owns the compositor mid-run")
  task:cancel("withdrawn")
  Assert.equal(task:status(), "cancelled", "cancellation lands on cancelled")
  Assert.isTrue(
    scene:animationFrame().main.compositor.battlefieldFade == nil,
    "cancellation drops the owned battlefield fade once"
  )
  Assert.isTrue(scene:pictureState(ATTACKER).pictureVisible == true, "cancellation never touches a picture overlay")
  task:cancel("repeated")
  task:dispose()
  Assert.isTrue(
    scene:animationFrame().main.compositor.battlefieldFade == nil,
    "a repeated release leaves the compositor alone"
  )
end

-- The window interior reg_G2_WIN0H/WIN0V sweep, GX_SetVisibleWnd, and the
-- windowed plane mask have no scene expression: the body flashes the whole
-- battlefield plane and writes no window rectangle or per-row offset.
-- BattleAnimFunc_ShowBattleBgInObjWindow (battle_anim_funcs.c, selector 56 of
-- gBattleAnimFuncTable): the callback loads the battle background copy onto
-- BG2, writes the WINOUT plane split, and turns battler sprite 0 - the
-- attacker's - into the object window; BattleAnimTask_EndObjWindow clears that
-- window on its own frame, so the appearance lives one source tick. The
-- producer lowers this selector with an empty parameter record and no battler
-- target, so the body resolves the presented attacker side itself.
function T.battle_sprite_affine_appearance_presents_the_object_window_for_one_tick()
  local scene = sceneWithPair()
  local task = spawn(scene, "battle-sprite-affine-appearance-transition", occurrenceContext(2))
  Assert.equal(task:status(), "pending", "the appearance opens pending")
  local opened = scene:animationFrame()
  local silhouette = assert(opened.objWindowSilhouette, "the callback names the object window coverage")
  Assert.equal(silhouette.combatant, ATTACKER.combatant, "battler sprite 0 is the attacker's picture")
  Assert.equal(silhouette.activation, ATTACKER.activation, "the window covers the presented attacker activation")
  local windows = assert(opened.main.compositor.windows, "the callback writes the WINOUT plane split")
  Assert.isTrue(windows.objWindow.mask.battlefield == true, "the battlefield stands in for the BG2 copy inside")
  Assert.isTrue(windows.outside.mask.transition == false, "the BG2 copy covers the object window only")
  Assert.isTrue(windows.outside.mask.battlefield == true, "the battlefield plane stays visible outside")
  Assert.equal(tickUntilComplete(task), 1, "BattleAnimTask_EndObjWindow clears the window on its own frame")
  local closed = scene:animationFrame()
  Assert.isNil(closed.objWindowSilhouette, "completion releases the object window coverage")
  Assert.isNil(closed.main.compositor.windows, "completion restores the owned window masks")
end

-- The native task destroys itself with the window it installed, so a
-- withdrawn run releases the silhouette and the masks exactly once.
function T.battle_sprite_affine_appearance_cancels_exactly_once()
  local scene = sceneWithPair()
  local task = spawn(scene, "battle-sprite-affine-appearance-transition")
  Assert.notNil(scene:animationFrame().objWindowSilhouette, "the appearance owns the coverage mid-run")
  task:cancel("withdrawn")
  Assert.equal(task:status(), "cancelled", "cancellation lands on cancelled")
  Assert.isNil(scene:animationFrame().objWindowSilhouette, "cancellation releases the object window coverage")
  Assert.isNil(scene:animationFrame().main.compositor.windows, "cancellation restores the owned window masks")
  task:cancel("repeated")
  task:dispose()
  Assert.isNil(scene:animationFrame().objWindowSilhouette, "a repeated release leaves the coverage alone")
end

return { tests = T }
