-- Native configured-sprite callback behavior: each opcode-78 sprite function
-- owns a phase machine from battle_anim_funcs.c, battle_anim_effects.c, or
-- battle_anim_move_effects.c. These probes run the real configured lanes
-- against a real scene with synthetic normalized sprite banks, asserting the
-- authored tick boundaries, positions, scales, rotations, and blend writes
-- the pinned source routines produce.

local Assert = require("tests.support.Assert")
local BattleEffectTasks = require("libs.hgss.src.presentation.BattleEffectTasks")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")

local T = {}

local KEYS = {
  character = "probe/character",
  palette = "probe/palette",
  cell = "probe/cell",
  animation = "probe/animation",
}

local ATTACKER = { combatant = 1, activation = 1 }
local DEFENDER = { combatant = 3, activation = 3 }

local function occurrenceContext()
  return {
    launchId = "configured-sprite-probe",
    packetId = 1,
    programKey = "configured-sprite-probe",
    seed = 4242,
    visualSeed = 4242,
    random = function(bound)
      assert(type(bound) == "number" and bound >= 1, "visual draws name a positive bound")
      return 0
    end,
    topology = {
      attacker = { combatant = 1, activation = 1, slot = "solo-player", sideType = 0 },
      targets = { { combatant = 3, activation = 3, slot = "solo-enemy", sideType = 1 } },
    },
    event = { sequence = 1, actionId = 1, hitIndex = 1, effectKey = "configured-sprite-probe" },
  }
end

local function defaultAnims()
  local anims = {}
  for index = 1, 4 do
    anims[index] = { frames = { { cell = 0, duration = 100 } } }
  end
  return anims
end

local function servicesWith(options)
  options = options or {}
  local cells = options.cells or { { objs = { { x = 0, y = 0, tile = 0, width = 8, height = 8, priority = 0 } } } }
  local anims = options.anims or defaultAnims()
  local palette = options.palette or { colors = { 0, 1, 2 } }
  local leases = {
    [KEYS.character] = { key = KEYS.character, kind = "texture", width = 512 },
    [KEYS.palette] = { key = KEYS.palette, kind = "palette", data = palette },
    [KEYS.cell] = { key = KEYS.cell, kind = "cells", data = { cells = cells } },
    [KEYS.animation] = { key = KEYS.animation, kind = "animation", data = { anims = anims } },
  }
  local journal = { acquired = {}, released = {} }
  local resources = {}
  function resources.resolve(key)
    journal.acquired[#journal.acquired + 1] = key
    return assert(leases[key], "configured role stages " .. tostring(key))
  end
  function resources.release(lease)
    journal.released[#journal.released + 1] = lease
  end
  local scene = BattleScene.new()
  scene:observe({
    { combatant = 1, activation = 1, visible = true },
    { combatant = 3, activation = 3, visible = true },
  })
  return { scene = scene, audio = {}, resources = resources }, scene, journal
end

local function spawn(kind, parameters, options)
  local services, scene, journal = servicesWith(options)
  local task = assert(BattleEffectTasks.create(kind, {
    taskContext = "battle-sprite",
    parameters = parameters or {},
    resourceKeys = KEYS,
  }, occurrenceContext(), services))
  return task, scene, journal
end

local function step(task, count)
  for _ = 1, count or 1 do
    task:stepSourceTick({ tick = 1 })
  end
end

local function views(scene)
  return scene:effectViews()
end

local function picturesFor(scene, spriteIndex)
  local list = {}
  for _, view in ipairs(views(scene)) do
    local picture = view.picture
    if picture.selector:find("/sprite-" .. spriteIndex .. "/", 1, true) ~= nil then
      list[#list + 1] = picture
    end
  end
  return list
end

function T.sprite_orbit_walks_the_pinned_step_table_then_swings()
  local task, scene = spawn("sprite-orbit")
  step(task)
  local first = picturesFor(scene, 1)[1]
  Assert.notNil(first, "the orbit sprite publishes on its first tick")
  Assert.equal(first.centerX, 192 + 5 + 4, "the first authored step moves five pixels right")
  Assert.equal(first.centerY, 50 + 12 + 4, "the orbit starts twelve pixels below the defender")
  step(task, 41)
  local settled = picturesFor(scene, 1)[1]
  Assert.equal(settled.centerX, 192 + 4, "the full step table returns the sprite to the defender column")
  step(task, 2)
  local swinging = picturesFor(scene, 1)[1]
  Assert.notNil(swinging.rotationZ, "the swing begins its affine rotation")
  Assert.isTrue(swinging.rotationZ > 0, "the first swing angle is positive")
  task:dispose()
end

function T.sprite_throw_arc_follows_the_compiled_path_and_rotation()
  local task, scene = spawn("sprite-throw-arc", {
    offsetX = 10,
    offsetY = 20,
    durationTicks = 10,
    arcHeight = 10,
  })
  step(task)
  local first = picturesFor(scene, 1)[1]
  Assert.notNil(first, "the thrown sprite publishes after the setup step")
  Assert.isTrue(first.centerX > 64 + 4, "the arc leaves the attacker column")
  Assert.isTrue(first.centerX < 192 + 10 + 4, "the arc has not reached its defender-relative target")
  Assert.isTrue(first.rotationZ > 0 and first.rotationZ < 0x5C71, "the authored rotation advances")
  step(task, 12)
  Assert.equal(task:status(), "complete", "the thrown arc retires at its compiled duration")
  Assert.equal(#views(scene), 0, "completion releases the sprite")
  task:dispose()
end

function T.sprite_crossing_scales_the_defender_picture_through_three_rounds()
  local task, scene = spawn("sprite-crossing", { spriteCount = 2 })
  step(task, 9)
  local picture = scene:pictureState(DEFENDER)
  Assert.notNil(picture, "the crossing body scales the defender picture")
  Assert.equal(picture.affineHeight, 179, "the first scale round ends at the authored 70/100 height")
  step(task, 120)
  Assert.equal(task:status(), "complete", "the five crossing rounds retire on their own boundary")
  Assert.equal(#views(scene), 0, "completion releases both copies")
  task:dispose()
end

function T.sprite_grow_rock_shrink_grows_rocks_and_shrinks()
  local task, scene = spawn("sprite-grow-rock-shrink")
  step(task)
  local tiny = picturesFor(scene, 1)[1]
  Assert.notNil(tiny, "the grown sprite publishes from its first tick")
  Assert.isTrue(tiny.scaleX < 0.3, "the served scale starts near one tenth")
  step(task, 7)
  local grown = picturesFor(scene, 1)[1]
  Assert.isTrue(grown.scaleX > 0.9, "eight ticks grow the sprite to its authored 1/1 scale")
  step(task, 2)
  local rocked = picturesFor(scene, 1)[1]
  Assert.isTrue(rocked.rotationZ ~= 0, "the rock phase turns the sprite")
  step(task, 40)
  Assert.equal(task:status(), "complete", "the rock-and-shrink machine retires")
  task:dispose()
end

function T.sprite_stack_on_defender_shows_one_copy_every_four_ticks()
  local task, scene = spawn("sprite-stack-on-defender")
  step(task, 4)
  Assert.equal(#views(scene), 0, "the stack waits four ticks before its first copy")
  step(task)
  Assert.isTrue(#picturesFor(scene, 1) > 0, "the first copy appears on tick five")
  step(task, 4)
  Assert.isTrue(#picturesFor(scene, 2) > 0, "the second copy appears four ticks later")
  step(task, 4)
  Assert.isTrue(#picturesFor(scene, 3) > 0, "the third copy appears four ticks later")
  step(task, 4)
  Assert.isTrue(#picturesFor(scene, 4) > 0, "the fourth copy appears four ticks later")
  step(task, 10)
  local picture = scene:pictureState(DEFENDER)
  Assert.notNil(picture, "the stack shakes the defender picture")
  task:dispose()
end

function T.sprite_blink_scale_fade_blinks_then_hides_behind_the_scale()
  local task, scene = spawn("sprite-blink-scale-fade", { spriteCount = 3 })
  step(task, 8)
  Assert.equal(#views(scene), 0, "before its authored timing the first copy stays hidden")
  step(task)
  Assert.isTrue(#picturesFor(scene, 1) > 0, "the authored blink timing reveals the first copy")
  step(task, 46)
  local scaling = picturesFor(scene, 1)[1]
  Assert.notNil(scaling, "the scale phase still draws the copies")
  Assert.isTrue(scaling.scaleX < 0.7, "the authored scale shrinks horizontally toward 60/100")
  task:dispose()
end

function T.sprite_zigzag_flash_walks_legs_and_flashes_the_pictures()
  local task, scene = spawn("sprite-zigzag-flash")
  step(task, 24)
  local moved = picturesFor(scene, 1)[1]
  Assert.notNil(moved, "the flash sprite publishes while its legs run")
  Assert.isTrue(moved.centerX > 192 - 40, "the first legs travel right")
  step(task, 40)
  local picture = scene:pictureState(ATTACKER)
  Assert.notNil(picture, "the flash writes the battler picture fade")
  Assert.notNil(picture.paletteFade, "the battler picture carries its white palette fade")
  local fade = scene:animationFrame().main.compositor.battlefieldFade
  Assert.notNil(fade, "the battlefield palette flashes with the sprite")
  step(task, 60)
  Assert.equal(task:status(), "complete", "the zigzag flash retires after its blink")
  task:dispose()
end

function T.sprite_orbit_attacker_bobbing_moves_the_authored_y_frequency()
  local plain, plainScene = spawn("sprite-orbit-attacker")
  local bobbing, bobbingScene = spawn("sprite-orbit-attacker-bobbing")
  step(plain, 15)
  step(bobbing, 15)
  local plainPicture = picturesFor(plainScene, 1)[1]
  local bobbingPicture = picturesFor(bobbingScene, 1)[1]
  Assert.notNil(plainPicture, "the plain orbit publishes")
  Assert.notNil(bobbingPicture, "the bobbing orbit publishes")
  local plainY = plainPicture.centerY
  local bobbingY = bobbingPicture.centerY
  step(plain)
  step(bobbing)
  Assert.equal(picturesFor(plainScene, 1)[1].centerY, plainY, "the plain orbit keeps the picture row")
  Assert.isTrue(picturesFor(bobbingScene, 1)[1].centerY ~= bobbingY, "the bobbing orbit modulates its row")
  plain:dispose()
  bobbing:dispose()
end

function T.sprite_trail_to_defender_parks_eight_copies_and_hides_at_its_boundary()
  local task, scene = spawn("sprite-trail-to-defender")
  step(task)
  local first = picturesFor(scene, 1)[1]
  local last = picturesFor(scene, 8)[1]
  Assert.notNil(first, "the first trail copy publishes")
  Assert.notNil(last, "the eighth trail copy publishes")
  Assert.isTrue(first.centerX > 64 and first.centerX < last.centerX, "trail copies keep their authored path order")
  Assert.isTrue(first.centerY > last.centerY, "the trail descends toward the defender row")
  step(task, 160)
  Assert.equal(task:status(), "complete", "the trail retires when all copies pass their authored lifetime")
  Assert.equal(#views(scene), 0, "completion releases every trail copy")
  task:dispose()
end

function T.sprite_floating_stream_launches_one_copy_every_seven_ticks()
  local task, scene = spawn("sprite-floating-stream")
  step(task, 7)
  Assert.equal(#views(scene), 1, "the first stream copy launches on tick seven")
  step(task, 7)
  Assert.equal(#views(scene), 2, "the second copy launches seven ticks later")
  step(task, 150)
  Assert.equal(task:status(), "complete", "the stream retires after its last copy")
  task:dispose()
end

function T.sprite_quad_hides_all_four_copies_at_its_authored_lifetime()
  local task, scene = spawn("sprite-quad")
  step(task)
  Assert.equal(#views(scene), 4, "all four quad copies start visible")
  step(task, 38)
  Assert.equal(#views(scene), 4, "the quad keeps all copies through tick thirty-nine")
  step(task)
  Assert.equal(task:status(), "complete", "the quad retires at its forty-tick boundary")
  Assert.equal(#views(scene), 0, "completion releases the quad")
  task:dispose()
end

function T.sprite_row_sequence_staggers_copies_on_its_twelve_pixel_row()
  local task, scene = spawn("sprite-row-sequence")
  step(task)
  Assert.equal(#views(scene), 0, "the zero-delay copy never paints in the pinned source")
  step(task)
  local second = picturesFor(scene, 2)[1]
  Assert.notNil(second, "the second row copy appears after two ticks")
  Assert.equal(second.centerX, 64 + 28 + 4, "the row lands on its authored attack-side offset")
  Assert.equal(second.centerY, 112 + 40 + 4, "the row sits forty pixels below the attacker picture")
  step(task, 30)
  Assert.equal(task:status(), "complete", "the row sequence retires on its last copy")
  task:dispose()
end

function T.sprite_palette_cycle_offsets_the_staged_palette_with_the_frame()
  local anims = {
    {
      frames = {
        { cell = 0, duration = 1 },
        { cell = 0, duration = 1 },
        { cell = 0, duration = 1 },
        { cell = 0, duration = 1 },
        { cell = 0, duration = 1 },
        { cell = 0, duration = 1 },
      },
    },
  }
  local task, scene = spawn("sprite-palette-cycle", nil, { anims = anims })
  step(task, 11)
  local first = picturesFor(scene, 1)[1]
  Assert.notNil(first, "the palette cycle publishes after its fade-in")
  Assert.equal(first.paletteOffset, 0, "the first authored frame keeps the base palette")
  step(task)
  local second = picturesFor(scene, 1)[1]
  Assert.equal(second.paletteOffset, 1, "the next frame offsets the palette by one color")
  step(task)
  local third = picturesFor(scene, 1)[1]
  Assert.equal(third.paletteOffset, 2, "the third frame offsets the palette by two colors")
  task:dispose()
end

function T.sprite_scale_over_defender_shakes_the_picture_between_sequences()
  local task, scene = spawn("sprite-scale-over-defender")
  step(task, 11)
  Assert.isTrue(#picturesFor(scene, 3) > 0, "the grow sequence shows its first copy")
  step(task, 9)
  Assert.isTrue(#picturesFor(scene, 2) > 0, "the grow sequence shows its second copy")
  step(task, 31)
  local picture = scene:pictureState(DEFENDER)
  Assert.notNil(picture, "the defender picture is owned during the shake")
  step(task, 60)
  Assert.equal(task:status(), "complete", "the scale-over-defender machine retires")
  task:dispose()
end

function T.sprite_shrink_attacker_into_leaves_the_attacker_vanished()
  local task, scene = spawn("sprite-shrink-attacker-into")
  step(task, 170)
  Assert.equal(task:status(), "complete", "the shrink-into-sprite machine retires")
  local picture = scene:pictureState(ATTACKER)
  Assert.notNil(picture, "the terminal vanish keeps the attacker picture overlay")
  Assert.equal(picture.vanished, true, "the attacker picture stays vanished after completion")
  task:dispose()
end

function T.sprite_rising_shrink_launches_the_second_copy_after_nine_ticks()
  local task, scene = spawn("sprite-rising-shrink")
  step(task)
  Assert.equal(#views(scene), 1, "the first copy launches on the first tick")
  step(task, 9)
  Assert.equal(#views(scene), 1, "the second copy waits for its authored delay")
  step(task)
  Assert.equal(#views(scene), 2, "the second copy launches nine ticks after the first")
  step(task, 40)
  Assert.equal(task:status(), "complete", "both rising copies retire")
  task:dispose()
end

function T.sprite_spread_copies_splits_the_sprite_into_three_drifting_copies()
  local task, scene = spawn("sprite-spread-copies")
  step(task)
  local first = picturesFor(scene, 1)[1]
  local second = picturesFor(scene, 2)[1]
  local third = picturesFor(scene, 3)[1]
  Assert.notNil(first, "the original copy publishes")
  Assert.notNil(second, "the second copy publishes")
  Assert.notNil(third, "the third copy publishes")
  Assert.equal(first.centerX, 192 + 1 + 4, "the original drifts one pixel right")
  Assert.equal(second.centerX, 192 - 1 + 4, "the second drifts one pixel left")
  Assert.equal(third.centerY, 50 + 1 + 4, "the third drifts one pixel down")
  task:dispose()
end

function T.sprite_pops_grows_and_shrinks_beside_the_defender_picture()
  local task, scene = spawn("sprite-pops")
  step(task)
  local first = picturesFor(scene, 1)[1]
  Assert.notNil(first, "the first pop publishes")
  Assert.equal(first.centerX, 192 + 24 + 4, "the first pop sits the authored side offset away")
  Assert.equal(first.centerY, 50 - 16 + 4, "the first pop sits the authored height above")
  step(task, 4)
  local grown = picturesFor(scene, 1)[1]
  Assert.isTrue(grown.scaleX > 1.2, "four ticks grow the pop toward fourteen tenths")
  task:dispose()
end

function T.sprite_arc_throws_the_sprite_from_offscreen_and_fades_it()
  local task, scene = spawn("sprite-arc")
  step(task)
  local start = picturesFor(scene, 1)[1]
  Assert.notNil(start, "the arc sprite publishes")
  Assert.isTrue(start.centerX < 0, "the arc starts offscreen left")
  step(task, 10)
  local travelled = picturesFor(scene, 1)[1]
  Assert.isTrue(travelled.centerX > start.centerX, "the arc travels to the right")
  Assert.isTrue(travelled.centerY < start.centerY, "the sine arc carries the sprite above the row")
  step(task, 200)
  Assert.equal(task:status(), "complete", "the arc retires after its animation and fade")
  task:dispose()
end

function T.sprite_offset_animate_uses_the_compiled_offsets_and_keeps_cell_part_offsets()
  local task, scene = spawn("sprite-offset-animate", { offsetX = 12, offsetY = -8 }, {
    cells = {
      {
        objs = {
          { x = 0, y = 0, tile = 0, width = 8, height = 8, priority = 0 },
          { x = 8, y = 0, tile = 1, width = 8, height = 8, priority = 0 },
        },
      },
    },
  })
  step(task)
  local parts = picturesFor(scene, 1)
  Assert.equal(#parts, 2, "both authored cell parts reach the scene")
  Assert.equal(parts[1].centerX, 192 + 12 + 4, "the compiled X offset moves the sprite")
  Assert.equal(parts[1].centerY, 50 - 8 + 4, "the compiled Y offset moves the sprite")
  Assert.equal(parts[2].centerX - parts[1].centerX, 8, "retained parts keep their distinct authored offsets")
  task:dispose()
end

function T.sprite_above_defender_places_the_copy_on_the_defender_row()
  local task, scene = spawn("sprite-above-defender")
  step(task)
  local picture = picturesFor(scene, 1)[1]
  Assert.notNil(picture, "the above-defender sprite publishes")
  Assert.equal(picture.centerX, 192 + 4, "the copy keeps the defender column")
  Assert.equal(picture.centerY, 32 + 4, "an enemy defender puts the copy above the picture row")
  task:dispose()
end

function T.sprite_fan_around_attacker_places_six_copies_on_the_authored_fan()
  local task, scene = spawn("sprite-fan-around-attacker")
  step(task)
  local first = picturesFor(scene, 1)[1]
  Assert.notNil(first, "the first fan copy publishes on its start tick")
  Assert.equal(first.centerX, 64 + 48 + 4, "the first copy sits forty-eight pixels right of the attacker")
  Assert.equal(first.centerY, 112 + 4, "the first copy stays on the attacker row")
  step(task)
  local picture = scene:pictureState(ATTACKER)
  Assert.notNil(picture, "the fan pulses the attacker picture")
  step(task, 600)
  Assert.equal(task:status(), "complete", "the fan retires after its exit animation")
  task:dispose()
end

function T.sprite_pulse_brightness_pulses_the_scale_then_flashes_the_screen()
  local task, scene = spawn("sprite-pulse-brightness")
  step(task, 3)
  local pulsed = picturesFor(scene, 1)[1]
  Assert.notNil(pulsed, "the brightness sprite publishes during its pulse rounds")
  Assert.isTrue(pulsed.scaleX > 1 and pulsed.scaleX < 1.6, "the pulse grows the sprite toward its authored scale")
  step(task, 100)
  local brightness = scene:animationFrame().main.compositor.brightness
  Assert.notNil(brightness, "the pulse ends with a screen-brightness transition")
  Assert.isTrue(
    brightness.mode == "up" or brightness.mode == "down",
    "the brightness transition keeps its native direction"
  )
  step(task, 300)
  Assert.equal(task:status(), "complete", "the brightness flash retires after its fade")
  task:dispose()
end

function T.sprite_flash_around_attacker_publishes_four_copies_and_palette_flashes()
  local task, scene = spawn("sprite-flash-around-attacker")
  step(task)
  Assert.equal(#views(scene), 4, "four copies flash around the attacker")
  step(task, 52)
  local flashing = false
  for _, view in ipairs(views(scene)) do
    if type(view.picture.paletteFade) == "table" and view.picture.paletteFade.intensity > 0 then
      flashing = true
    end
  end
  Assert.isTrue(flashing, "the authored palette blends flash the copies")
  step(task, 80)
  Assert.equal(task:status(), "complete", "the flashing copies retire after their blend fade")
  task:dispose()
end

-- BattleAnimSpriteFunc_PopAndScatterSprites draws every delay, area, and
-- target from the occurrence random stream, so the seeded stream must repaint
-- the same positions and a different seed must move them.
local function seededRandom(seed)
  local state = seed
  return function(bound)
    assert(type(bound) == "number" and bound >= 1, "visual draws name a positive bound")
    state = (state * 1103515245 + 12345) % 2147483648
    return state % bound
  end
end

local function scatterSignature(seed)
  local services, scene = servicesWith()
  local context = occurrenceContext()
  context.random = seededRandom(seed)
  context.visualSeed = seed
  local task = assert(BattleEffectTasks.create("sprite-pop-scatter", {
    taskContext = "battle-sprite",
    parameters = {},
    resourceKeys = KEYS,
  }, context, services))
  local positions = {}
  for _ = 1, 24 do
    task:stepSourceTick({ tick = 1 })
    local signature = {}
    for _, view in ipairs(views(scene)) do
      local picture = view.picture
      signature[#signature + 1] = string.format("%d:%d", math.floor(picture.centerX), math.floor(picture.centerY))
    end
    table.sort(signature)
    positions[#positions + 1] = table.concat(signature, ",")
  end
  task:dispose()
  return positions
end

function T.sprite_pop_scatter_pops_at_the_served_delays_and_keeps_the_seeded_stream()
  local task, scene = spawn("sprite-pop-scatter")
  step(task, 3)
  Assert.equal(#views(scene), 0, "the scatter copies respect their served delays")
  step(task)
  Assert.isTrue(#views(scene) > 0, "the first copy pops after its delay")
  step(task, 100)
  Assert.equal(task:status(), "complete", "the scatter retires after every copy reaches its target")
  Assert.equal(#views(scene), 0, "completion releases the scatter copies")
  task:dispose()

  local first = scatterSignature(4242)
  Assert.deepEqual(scatterSignature(4242), first, "the same seed paints the same positions on every schedule")
  local moved = false
  for _, position in ipairs(first) do
    if position ~= first[1] then
      moved = true
    end
  end
  Assert.isTrue(moved, "the run moves across ticks instead of holding one offset")
  local varied = false
  for index, position in ipairs(scatterSignature(777)) do
    if position ~= first[index] then
      varied = true
    end
  end
  Assert.isTrue(varied, "a different seed paints a different motion")
end

function T.sprite_fade_anim_fades_in_plays_and_fades_out()
  local task, scene = spawn("sprite-fade-anim")
  step(task)
  Assert.isTrue(#views(scene) > 0, "the fading sprite publishes while it fades in")
  local blend = scene:blendCoefficients()
  Assert.notNil(blend, "the fade owns the shared blend registers")
  Assert.isTrue(blend.blendCoefficientA < 16, "the sprite starts its fade-in in translucent mode")
  step(task, 140)
  Assert.equal(task:status(), "complete", "the fade retires after the authored animation")
  task:dispose()
end

function T.sprite_blink_center_fades_the_authored_copies()
  local task, scene = spawn("sprite-blink-center", { spriteCount = 2 })
  step(task)
  Assert.equal(#views(scene), 2, "both centre copies publish from the first tick")
  step(task, 15)
  local blend = scene:blendCoefficients()
  Assert.equal(blend.blendCoefficientA, 15, "fifteen ticks reach the authored fully-visible coefficient")
  step(task, 50)
  Assert.equal(task:status(), "complete", "the centre blink retires after its fade out")
  task:dispose()
end

return { tests = T }
