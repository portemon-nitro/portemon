-- Unit coverage for the battle visual-state owner: six slot rows,
-- activation-local picture state, picture/shadow origins, HP/EXP patch
-- arithmetic, source-ticked entry, background layers and effect lifetime.

local Assert = require("tests.support.Assert")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")

local T = {}

local function slotGeometry()
  return require("tests.support.BattlePresentationManifestFixture").manifest().battlefield.slots
end

function T.picture_attributes_follow_the_exact_portrait_identity()
  local animation = { steps = { { next = 0, duration = 8, xOffset = -1, auxiliary = 2 } } }
  local attributes = { height = 23, animation = animation }
  local key = "pokemon/EEVEE/form-0/male/back"
  local manifest = {
    pictures = {
      selectors = {
        [key] = {
          species = "EEVEE",
          form = 0,
          gender = "male",
          facing = "back",
          attributes = key,
        },
      },
      attributes = { [key] = attributes },
    },
  }

  Assert.equal(
    BattleScene.pictureAttributes(manifest, "EEVEE/f0/male/shiny/back"),
    attributes,
    "shiny back portraits share their source height and animation attributes"
  )
  Assert.equal(
    BattleScene.pictureAttributes(manifest, "EEVEE/f0/male/plain"),
    nil,
    "a different source-facing selector never borrows the back-facing attributes"
  )
  Assert.equal(
    BattleScene.pictureAttributes({}, "EEVEE/f0/male/plain"),
    nil,
    "planning manifests without picture catalogs remain unbound"
  )
end

function T.picture_state_restores_only_the_changed_activation_snapshot()
  local scene = BattleScene.new()
  local changed = {
    combatant = 4,
    activation = "switch-2",
    portraitSelector = "EEVEE/f0/male/plain/back",
    rotation = 0,
    scaleX = 1,
    scaleY = 1,
    affineMode = false,
    affineWidth = 0x100,
    affineHeight = 0x100,
    pictureTint = { r = 1, g = 1, b = 1, a = 1 },
    polygonAlpha = 31,
    shadowSize = 2,
    shadowAffine = false,
    shadowHeight = 3,
    shadowOffsetX = 2,
    shadowTint = { r = 0.5, g = 0.75, b = 1, a = 1 },
    shadowVisible = true,
  }
  local unrelated = {
    combatant = 5,
    activation = "switch-3",
    portraitSelector = "PIKACHU/f0/female/plain/back",
    rotation = 0,
    scaleX = 1,
    scaleY = 1,
    pictureTint = { r = 1, g = 1, b = 1, a = 1 },
    shadowVisible = true,
  }
  scene:install(changed)
  scene:install(unrelated)

  local transformed = scene:applyPictureState(changed, {
    portraitSelector = "EEVEE/f0/male/plain/front",
    substitute = true,
    rotation = 0.25,
    scaleX = 1.5,
    affineMode = true,
    affineWidth = 0x180,
    affineHeight = 0x80,
    pictureTint = { r = 1, g = 0.5, b = 0.5, a = 1 },
    polygonAlpha = 17,
    shadowSize = 1,
    shadowAffine = true,
    shadowHeight = -2,
    shadowOffsetX = -1,
    shadowTint = { r = 1, g = 0.5, b = 0.5, a = 1 },
    shadowVisible = false,
  })
  Assert.deepEqual(transformed, {
    portraitSelector = "EEVEE/f0/male/plain/front",
    rotation = 0.25,
    scaleX = 1.5,
    scaleY = 1,
    affineMode = true,
    affineWidth = 0x180,
    affineHeight = 0x80,
    pictureTint = { r = 1, g = 0.5, b = 0.5, a = 1 },
    polygonAlpha = 17,
    shadowSize = 1,
    shadowAffine = true,
    shadowHeight = -2,
    shadowOffsetX = -1,
    shadowTint = { r = 1, g = 0.5, b = 0.5, a = 1 },
    shadowVisible = false,
    substitute = true,
  }, "the activation's transform and appearance patch returns its detached view")
  transformed.scaleX = 9
  transformed.pictureTint.g = 9
  Assert.deepEqual(scene:pictureState(changed), {
    portraitSelector = "EEVEE/f0/male/plain/front",
    substitute = true,
    rotation = 0.25,
    scaleX = 1.5,
    scaleY = 1,
    affineMode = true,
    affineWidth = 0x180,
    affineHeight = 0x80,
    pictureTint = { r = 1, g = 0.5, b = 0.5, a = 1 },
    polygonAlpha = 17,
    shadowSize = 1,
    shadowAffine = true,
    shadowHeight = -2,
    shadowOffsetX = -1,
    shadowTint = { r = 1, g = 0.5, b = 0.5, a = 1 },
    shadowVisible = false,
  }, "the returned picture view cannot mutate scene state")
  Assert.equal(scene:pictureState(unrelated), nil, "another activation receives no transform state")
  local restored = scene:restorePictureState(changed)
  Assert.deepEqual(restored, {
    portraitSelector = "EEVEE/f0/male/plain/back",
    rotation = 0,
    scaleX = 1,
    scaleY = 1,
    affineMode = false,
    affineWidth = 0x100,
    affineHeight = 0x100,
    pictureTint = { r = 1, g = 1, b = 1, a = 1 },
    polygonAlpha = 31,
    shadowSize = 2,
    shadowAffine = false,
    shadowHeight = 3,
    shadowOffsetX = 2,
    shadowTint = { r = 0.5, g = 0.75, b = 1, a = 1 },
    shadowVisible = true,
  }, "restore returns the activation's saved presentation")
  Assert.deepEqual(scene:pictureState(changed), restored, "the renderer sees the restored base without stale transform fields")
  scene:remove(changed.combatant, changed.activation)
  Assert.equal(scene:pictureState(unrelated), nil, "removal leaves unrelated activation state unchanged")
end

function T.picture_palette_fade_steps_with_native_delay_and_restores_activation_state()
  local scene = BattleScene.new()
  local battler = {
    combatant = 2,
    activation = "fade-source",
    portraitSelector = "EEVEE/f0/male/plain/front",
  }
  scene:install(battler)
  local initial = scene:applyPictureState(battler, {
    paletteFade = { start = 4, finish = 2, framesPer = 1, targetColor = 0x7FFF },
  })
  Assert.deepEqual(initial.paletteFade, {
    intensity = 4,
    current = 4,
    finish = 2,
    delayCounter = 0,
    delayLength = 1,
    targetColor = 0x7FFF,
    active = true,
    applied = false,
  }, "fade installation starts with the source parameters before the first palette update")

  scene:stepSourceTick()
  Assert.deepEqual(scene:pictureState(battler).paletteFade, {
    intensity = 4,
    current = 3,
    finish = 2,
    delayCounter = 1,
    delayLength = 1,
    targetColor = 0x7FFF,
    active = true,
    applied = true,
  }, "the first source tick blends at the start intensity and advances the native counter")
  scene:stepSourceTick()
  Assert.equal(scene:pictureState(battler).paletteFade.delayCounter, 0, "native fade delay counts down")
  scene:stepSourceTick()
  Assert.equal(scene:pictureState(battler).paletteFade.intensity, 3, "fade intensity advances after its delay")
  scene:stepSourceTick()
  scene:stepSourceTick()
  Assert.deepEqual(scene:pictureState(battler).paletteFade, {
    intensity = 2,
    current = 2,
    finish = 2,
    delayCounter = 1,
    delayLength = 1,
    targetColor = 0x7FFF,
    active = false,
    applied = true,
  }, "the terminal palette value remains visible after the native task completes")

  local restored = scene:restorePictureState(battler)
  Assert.deepEqual(restored, { portraitSelector = "EEVEE/f0/male/plain/front" }, "restore removes transient fade")
  Assert.equal(scene:pictureState(battler).paletteFade, nil, "the source activation snapshot has no changed fade")
end

function T.picture_restore_resumes_only_the_activation_source_animation_task()
  local scene = BattleScene.new()
  local changed = { combatant = 4, activation = "form-7", portraitSelector = "EEVEE/f0/male/plain/back" }
  local unrelated = { combatant = 5, activation = "form-8", portraitSelector = "PIKACHU/f0/female/plain/back" }
  local baseAnimation = {
    steps = {
      { next = 1, duration = 3, xOffset = 2 },
      { next = -1, duration = 0, xOffset = 0 },
      { next = 0, duration = 0, xOffset = 0 },
      { next = 0, duration = 0, xOffset = 0 },
      { next = 0, duration = 0, xOffset = 0 },
      { next = 0, duration = 0, xOffset = 0 },
      { next = 0, duration = 0, xOffset = 0 },
      { next = 0, duration = 0, xOffset = 0 },
      { next = 0, duration = 0, xOffset = 0 },
      { next = 0, duration = 0, xOffset = 0 },
    },
  }
  local changedAnimation = {
    steps = {
      { next = 2, duration = 1, xOffset = -3 },
      { next = -1, duration = 0, xOffset = 0 },
      { next = 0, duration = 0, xOffset = 0 },
      { next = 0, duration = 0, xOffset = 0 },
      { next = 0, duration = 0, xOffset = 0 },
      { next = 0, duration = 0, xOffset = 0 },
      { next = 0, duration = 0, xOffset = 0 },
      { next = 0, duration = 0, xOffset = 0 },
      { next = 0, duration = 0, xOffset = 0 },
      { next = 0, duration = 0, xOffset = 0 },
    },
  }
  scene:install(changed)
  scene:install(unrelated)
  local original = scene:picturePose(changed, baseAnimation)
  scene:picturePose(unrelated, baseAnimation)
  scene:stepSourceTick()
  scene:applyPictureState(changed, { portraitSelector = "EEVEE/f1/male/plain/back" })
  Assert.equal(
    scene:picturePose(changed, changedAnimation).frame,
    2,
    "the changed selector starts its own authored animation"
  )
  scene:stepSourceTick()
  local unrelatedBeforeRestore = scene:picturePose(unrelated, baseAnimation)
  scene:restorePictureState(changed)
  Assert.deepEqual(
    scene:picturePose(changed, baseAnimation),
    { frame = original.frame, xOffset = original.xOffset, active = original.active, step = original.step, delay = 2 },
    "form restore resumes the exact source frame and remaining delay from its saved task"
  )
  Assert.deepEqual(
    scene:picturePose(unrelated, baseAnimation),
    unrelatedBeforeRestore,
    "restoring one form leaves another activation animation task unchanged"
  )
  scene:release()
end

function T.picture_crop_and_shadow_attributes_are_activation_owned()
  local scene = BattleScene.new()
  local battler = { combatant = 1, activation = "crop-1" }
  scene:install(battler)
  local patch = {
    pictureVisible = true,
    pictureXOffset2 = 8,
    pictureYOffset2 = 4,
    pictureWidth = 64,
    pictureHeight = 48,
    pictureYOffset = -3,
    zOffset = -12,
    shadowHeight = 2,
    shadowSize = 2,
    shadowAffine = true,
    shadowAdjustX = false,
    shadowAdjustY = false,
    shadowX = 128,
    shadowY = 96,
    shadowOffsetX = 5,
    shadowOffsetY = -1,
    shadowTint = { r = 0.2, g = 0.3, b = 0.4, a = 0.5 },
  }
  local state = scene:applyPictureState(battler, patch)
  Assert.deepEqual(state, patch, "source crop, depth and independent shadow facts reach the activation view")
  patch.shadowTint.r = 1
  Assert.equal(scene:pictureState(battler).shadowTint.r, 0.2, "shadow color is detached from producer-owned input")

  local ok = pcall(function()
    scene:applyPictureState(battler, { pictureXOffset2 = 256 })
  end)
  Assert.isFalse(ok, "native crop offsets remain unsigned bytes")
  local invalidShadow = pcall(function()
    scene:applyPictureState(battler, { shadowSize = 4 })
  end)
  Assert.isFalse(invalidShadow, "native shadow selectors stay within the four staged UV regions")
  scene:remove(battler.combatant, battler.activation)
end

function T.background_map_and_palette_patches_update_owned_staged_layer_state()
  local map = {
    width = 16,
    height = 8,
    entries = {
      { tile = 1, flipH = false, flipV = false, palette = 0 },
      { tile = 2, flipH = true, flipV = false, palette = 1 },
    },
  }
  local palette = { colors = { { r = 1, g = 2, b = 3 }, { r = 4, g = 5, b = 6 } } }
  local payload = { characters = "chars", map = map, palette = palette, colorMode = "4bpp" }
  local scene = BattleScene.new()

  scene:installBackground(payload)
  scene:patchBackgroundMap(0, { tile = 7, flipH = false, flipV = true, palette = 2 })
  scene:patchBackgroundPalette(0, { r = 90, g = 91, b = 92 })

  local background = scene:background()
  Assert.deepEqual(background.map.entries[1], {
    tile = 7,
    flipH = false,
    flipV = true,
    palette = 2,
  }, "map patches replace one zero-based source entry")
  Assert.deepEqual(background.palette.colors[1], { r = 90, g = 91, b = 92 }, "palette patches replace one color")
  Assert.deepEqual(
    map.entries[1],
    { tile = 1, flipH = false, flipV = false, palette = 0 },
    "source map stays immutable"
  )
  Assert.deepEqual(palette.colors[1], { r = 1, g = 2, b = 3 }, "source palette stays immutable")
  Assert.equal(background.characters, "chars", "the layer retains its staged character bytes")
end

function T.source_effect_bg_replaces_bg3_and_restores_the_previous_plane_on_remove()
  local colors = {}
  for index = 0, 15 do
    colors[index + 1] = { r = 0, g = 0, b = 0 }
  end
  colors[2] = { r = 200, g = 0, b = 0 }
  local base = {
    characters = string.char(0x11) .. string.rep("\0", 31),
    colorMode = "4bpp",
    colorMode = "4bpp",
    map = { width = 8, height = 8, entries = { { tile = 0, flipH = false, flipV = false, palette = 0 } } },
    palette = { colors = colors },
  }
  local scene = BattleScene.new()
  scene:installBackground(base)
  local effectColors = {}
  for index = 0, 15 do
    effectColors[index + 1] = { r = 0, g = 0, b = 0 }
  end
  effectColors[2] = { r = 0, g = 180, b = 0 }
  scene:installBackgroundLayer("effect/first", {
    character = { depth = 3, tiles = string.char(0x10) .. string.rep("\0", 31) },
    screen = base.map,
    palette = { colors = effectColors },
  })
  local effect = scene:backgroundRaster()
  Assert.deepEqual({ effect:pixel(0, 0) }, { 0, 0, 0, 0 }, "transparent palette index does not reveal replaced BG3")
  Assert.deepEqual({ effect:pixel(1, 0) }, { 0, 180, 0, 255 }, "effect pixels replace the ordinary BG3 plane")
  Assert.equal(scene:backgroundRaster(), effect, "unchanged layer state reuses the uploaded BG3 source raster")

  local secondColors = {}
  for index = 0, 15 do
    secondColors[index + 1] = { r = 0, g = 0, b = 0 }
  end
  secondColors[2] = { r = 0, g = 0, b = 190 }
  scene:installBackgroundLayer("effect/second", {
    character = { depth = 3, tiles = string.char(0x10) .. string.rep("\0", 31) },
    screen = base.map,
    palette = { colors = secondColors },
  })
  Assert.deepEqual({ scene:backgroundRaster():pixel(1, 0) }, { 0, 0, 190, 255 }, "latest BG3 load is the visible plane")
  scene:removeBackgroundLayer("effect/second")
  Assert.deepEqual(
    { scene:backgroundRaster():pixel(1, 0) },
    { 0, 180, 0, 255 },
    "removing the latest load restores prior BG3 state"
  )

  scene:patchBackgroundLayerMap("effect/first", 0, { tile = 0, flipH = true, flipV = false, palette = 0 })
  local mapPatched = scene:backgroundRaster()
  Assert.isTrue(mapPatched ~= effect, "an effect map patch invalidates its BG3 source raster")
  Assert.deepEqual({ mapPatched:pixel(6, 0) }, { 0, 180, 0, 255 }, "map patches redraw the active effect plane")
  scene:patchBackgroundLayerMap("effect/first", 0, { tile = 0, flipH = false, flipV = false, palette = 0 })
  scene:patchBackgroundLayerPalette("effect/first", 1, { r = 0, g = 0, b = 190 })
  local patched = scene:backgroundRaster()
  Assert.isTrue(patched ~= effect, "an effect palette patch invalidates the BG3 raster")
  Assert.deepEqual({ patched:pixel(1, 0) }, { 0, 0, 190, 255 }, "effect palette patches reach the visible plane")
  scene:removeBackgroundLayer("effect/first")
  Assert.deepEqual({ scene:backgroundRaster():pixel(1, 0) }, { 200, 0, 0, 255 }, "removal restores the persistent BG3")
end

function T.effect_bg_layer_accepts_decoded_battle_background_resource_slots()
  local colors = {}
  for index = 0, 15 do
    colors[index + 1] = { r = 0, g = 0, b = 0 }
  end
  colors[2] = { r = 22, g = 44, b = 66 }
  local character = { depth = 3, tiles = string.char(0x11) .. string.rep("\0", 31) }
  local palette = { colors = colors }
  local screen = {
    width = 8,
    height = 8,
    entries = { { tile = 0, flipH = false, flipV = false, palette = 0 } },
  }
  local scene = BattleScene.new()
  scene:installBackground({
    characters = character.tiles,
    colorMode = "4bpp",
    map = screen,
    palette = palette,
  })
  scene:installBackgroundLayer("battle-background-layer-3", {
    character = character,
    palette = palette,
    screen = screen,
  })

  Assert.deepEqual(
    { scene:backgroundRaster():pixel(0, 0) },
    { 22, 44, 66, 255 },
    "typed battle-background character, palette and selected screen resources compose through BattleScene"
  )
end

function T.background_raster_applies_map_and_palette_patches()
  local colors = {}
  for index = 0, 15 do
    colors[index + 1] = { r = index, g = 0, b = 0 }
  end
  local scene = BattleScene.new()
  scene:installBackground({
    characters = string.char(0x21) .. string.rep("\0", 31),
    colorMode = "4bpp",
    map = { width = 8, height = 8, entries = { { tile = 0, flipH = false, flipV = false, palette = 0 } } },
    palette = { colors = colors },
  })
  local original = scene:backgroundRaster()
  Assert.equal(original:pixel(0, 0), 1, "BG3 raster reads its packed source nibble")
  Assert.equal(scene:backgroundRaster(), original, "unchanged layer state reuses the BG3 raster")
  scene:patchBackgroundPalette(1, { r = 80, g = 0, b = 0 })
  local patched = scene:backgroundRaster()
  Assert.isTrue(patched ~= original, "a source patch invalidates the composed pixels")
  Assert.equal(patched:pixel(0, 0), 80, "palette patch pixels reach the composed BG layer")
end

function T.persistent_bg3_raster_uses_native_8bpp_character_bytes()
  local colors = {}
  for index = 0, 255 do
    colors[index + 1] = { r = index, g = 255 - index, b = index % 2 }
  end
  local scene = BattleScene.new()
  scene:installBackground({
    characters = string.char(0x21) .. string.rep("\0", 63),
    colorMode = "8bpp",
    map = { width = 8, height = 8, entries = { { tile = 0, flipH = false, flipV = false, palette = 0 } } },
    palette = { colors = colors },
  })

  Assert.deepEqual(
    { scene:backgroundRaster():pixel(0, 0) },
    { 33, 222, 1, 255 },
    "persistent BG3 reads the full 8bpp index"
  )
  scene:patchBackgroundPalette(33, { r = 8, g = 9, b = 10 })
  Assert.deepEqual(
    { scene:backgroundRaster():pixel(0, 0) },
    { 8, 9, 10, 255 },
    "native palette patches use 8bpp indices"
  )
end

function T.picture_animation_uses_source_tick_countdown_loop_and_stop_rules()
  local scene = BattleScene.new()
  local battler = { combatant = 1, activation = 4 }
  local animation = {
    steps = {
      { next = 0, duration = 1, xOffset = -3, auxiliary = 0 },
      { next = -2, duration = 2, xOffset = 0, auxiliary = 0 },
      { next = 1, duration = 0, xOffset = 5, auxiliary = 0 },
      { next = -1, duration = 0, xOffset = 0, auxiliary = 0 },
      { next = -1, duration = 0, xOffset = 0, auxiliary = 0 },
      { next = -1, duration = 0, xOffset = 0, auxiliary = 0 },
      { next = -1, duration = 0, xOffset = 0, auxiliary = 0 },
      { next = -1, duration = 0, xOffset = 0, auxiliary = 0 },
      { next = -1, duration = 0, xOffset = 0, auxiliary = 0 },
      { next = -1, duration = 0, xOffset = 0, auxiliary = 0 },
    },
  }

  Assert.deepEqual(scene:picturePose(battler, animation), {
    frame = 0,
    xOffset = -3,
    active = true,
    step = 0,
    delay = 1,
  }, "Pokepic starts the first authored step immediately")
  scene:stepSourceTick()
  Assert.equal(scene:picturePose(battler, animation).delay, 0, "one source tick drains one delay unit")
  scene:stepSourceTick()
  Assert.deepEqual(scene:picturePose(battler, animation), {
    frame = 0,
    xOffset = -3,
    active = true,
    step = 0,
    delay = 1,
  }, "loop control jumps back to the authored frame until its counter expires")
  scene:stepSourceTick()
  scene:stepSourceTick()
  Assert.deepEqual(scene:picturePose(battler, animation), {
    frame = 1,
    xOffset = 5,
    active = true,
    step = 2,
    delay = 0,
  }, "the loop counter advances to the next frame after two source passes")
  scene:stepSourceTick()
  Assert.deepEqual(scene:picturePose(battler, animation), {
    frame = 0,
    xOffset = 0,
    active = false,
    step = 3,
    delay = 0,
  }, "the stop sentinel resets the frame and horizontal offset")
end

function T.health_gauge_tasks_step_on_source_ticks_with_native_integer_and_subpixel_rounding()
  local scene = BattleScene.new()
  scene:startGaugeTask("normal", { maximum = 100, current = 21, delta = 1, tiles = 6 })
  Assert.equal(scene:gaugeTaskValue("normal"), 21, "the task begins from its supplied source checkpoint")
  Assert.equal(scene:gaugeTaskPixels("normal"), 10, "the source pixel buffer floors the current value")
  scene:stepSourceTick()
  Assert.equal(scene:gaugeTaskValue("normal"), 20, "normal bars apply the source one-unit frame change")
  Assert.equal(scene:gaugeTaskPixels("normal"), 9, "the updated checkpoint repatches its exact pixel count")
  Assert.isFalse(scene:gaugeTaskActive("normal"), "the task stops at its clamped source target")

  scene:startGaugeTask("small", { maximum = 3, current = 2, delta = 1, tiles = 6 })
  for _ = 1, 16 do
    scene:stepSourceTick()
  end
  Assert.equal(scene:gaugeTaskValue("small"), 1, "subpixel arithmetic clamps after the source fixed-point steps")
  Assert.equal(scene:gaugeTaskPixels("small"), 16, "small gauges quantize fixed-point state before tile patches")
  Assert.isFalse(scene:gaugeTaskActive("small"), "a completed small-range bar task is removed")
end

function T.experience_task_uses_native_delta_per_visible_pixel_and_resets_at_level_boundary()
  local scene = BattleScene.new()
  local patchSpans = require("tests.support.BattlePresentationManifestFixture").manifest().hud.patchSpans
  scene:startExpGaugeTask("level-1", { maximum = 1000, current = 200, delta = -50 })
  Assert.equal(scene:gaugeTaskPixels("level-1"), 19, "experience starts at its native quantized fill")
  Assert.equal(
    scene:gaugeTaskPatchTiles(patchSpans, "level-1")[3].sourceTile,
    32,
    "the experience task selects component 29 plus its exact third-cell fill"
  )
  scene:stepSourceTick()
  Assert.equal(
    scene:gaugeTaskValue("level-1"),
    210,
    "native experience task advances by delta divided by quantized pixel travel"
  )
  Assert.equal(scene:gaugeTaskPixels("level-1"), 20, "the next source tick patches the displayed tile fill")
  Assert.equal(
    scene:gaugeTaskPatchTiles(patchSpans, "level-1")[3].sourceTile,
    33,
    "the changed experience tile is reflected by the native patch map"
  )

  scene:startExpGaugeTask("level-up", { maximum = 1000, current = 950, delta = -100 })
  Assert.equal(scene:gaugeTaskValue("level-up"), 950, "each level span begins at its own supplied source checkpoint")
  for _ = 1, 10 do
    scene:stepSourceTick()
  end
  Assert.equal(scene:gaugeTaskValue("level-up"), 1000, "a level span clamps at its boundary")
  Assert.isFalse(scene:gaugeTaskActive("level-up"), "a completed level span stops before the next span is installed")

  scene:startExpGaugeTask("level-up", { maximum = 1200, current = 100, delta = -50 })
  Assert.equal(
    scene:gaugeTaskPixels("level-up"),
    8,
    "a new level span resets the displayed fill against its new maximum"
  )
  scene:stepSourceTick()
  Assert.equal(scene:gaugeTaskValue("level-up"), 112, "the new level span uses source delta-per-visible-pixel speed")
  Assert.equal(
    scene:gaugeTaskPixels("level-up"),
    8,
    "subpixel updates keep the initial EXP fill until a pixel boundary"
  )
  for _ = 1, 4 do
    scene:stepSourceTick()
  end
  Assert.equal(scene:gaugeTaskValue("level-up"), 150, "the new level span clamps at its own checkpoint target")
  Assert.equal(scene:gaugeTaskPixels("level-up"), 12, "the new maximum controls the completed EXP fill")
  Assert.isFalse(scene:gaugeTaskActive("level-up"), "the reset task stops after completing the new level span")
end

function T.native_hud_icon_patches_follow_status_gender_and_caught_selectors()
  local patches = BattleScene.hudIconPatchTiles({
    status = { { sideType = 0, tile = 36, count = 3 } },
    gender = { { sideType = 0, spans = { { tile = 83, count = 2 }, { tile = 91, count = 2 } } } },
    caught = { { sideType = 0, tile = 35, count = 1 } },
  }, 0, "sleep", "female", true)

  Assert.deepEqual(patches, {
    { tile = 36, sourceTile = 53 },
    { tile = 37, sourceTile = 54 },
    { tile = 38, sourceTile = 55 },
    { tile = 83, sourceTile = 60 },
    { tile = 84, sourceTile = 61 },
    { tile = 91, sourceTile = 72 },
    { tile = 92, sourceTile = 73 },
    { tile = 35, sourceTile = 59 },
  }, "native icons select their raw component tiles and source character destinations")
end

function T.native_hud_icon_rejects_unmapped_condition_keys()
  local ok = pcall(BattleScene.hudIconPatchTiles, {
    status = { { sideType = 0, tile = 36, count = 3 } },
  }, 0, "PSN", nil, nil)
  Assert.isFalse(ok, "an unmapped status is not silently drawn as healthy")
end

function T.native_hud_icon_maps_all_status_and_gender_variants()
  local patchSpans = {
    status = { { sideType = 0, tile = 10, count = 3 } },
    gender = { { sideType = 0, spans = { { tile = 20, count = 2 }, { tile = 30, count = 2 } } } },
  }
  local statuses = {
    { key = nil, tiles = { 38, 39, 40 } },
    { key = "paralysis", tiles = { 47, 48, 49 } },
    { key = "freeze", tiles = { 50, 51, 52 } },
    { key = "sleep", tiles = { 53, 54, 55 } },
    { key = "poison", tiles = { 44, 45, 46 } },
    { key = "burn", tiles = { 41, 42, 43 } },
  }
  for _, status in ipairs(statuses) do
    local patches = BattleScene.hudIconPatchTiles(patchSpans, 0, status.key, nil, nil)
    for index, patch in ipairs(patches) do
      Assert.equal(patch.sourceTile, status.tiles[index], "native status selector uses its source component")
    end
  end
  local genders = {
    { key = "male", tiles = { 62, 63, 74, 75 } },
    { key = "female", tiles = { 60, 61, 72, 73 } },
    { key = "genderless", tiles = { 64, 65, 76, 77 } },
  }
  for _, gender in ipairs(genders) do
    local patches = BattleScene.hudIconPatchTiles(patchSpans, 0, nil, gender.key, nil)
    for index = 1, 4 do
      Assert.equal(patches[index + 3].sourceTile, gender.tiles[index], "native gender selector uses its source component")
    end
  end
end

function T.double_player_health_box_mode_is_activation_scoped_and_uses_source_tiles()
  local scene = BattleScene.new()
  local first = { combatant = 5, activation = "left", side = 1, position = 1 }
  local second = { combatant = 11, activation = "right", side = 1, position = 2 }
  scene:install(first)
  scene:install(second)
  local patchSpans = require("romdump.src.config.BattlePresentationSources").HUD_PATCH_SPANS

  Assert.equal(scene:healthBoxMode(first), "gauge", "double-player rows start in source gauge mode")
  scene:setHealthBoxMode(first, 2, "numbers")
  Assert.equal(scene:healthBoxMode(first), "numbers", "mode updates only the selected activation")
  Assert.equal(scene:healthBoxMode(second), "gauge", "the partner keeps its own source mode")
  Assert.deepEqual(
    BattleScene.healthBoxModePatchTiles(patchSpans, 2, "numbers"),
    {
      { tile = 39, sourceTile = 70 },
      { tile = 103, sourceTile = 71 },
      { tile = 99, sourceTile = 69 },
    },
    "number mode installs the pinned current/max number character cells"
  )
  Assert.deepEqual(
    BattleScene.healthBoxModePatchTiles(patchSpans, 4, "gauge"),
    {
      { tile = 38, sourceTile = 66 },
      { tile = 39, sourceTile = 67 },
      { tile = 102, sourceTile = 68 },
      { tile = 103, sourceTile = 38 },
    },
    "gauge mode restores the pinned double-player gauge character cells"
  )

  scene:remove(first.combatant, first.activation)
  Assert.equal(scene:healthBoxMode(second), "gauge", "removal keeps the unrelated activation mode")
  scene:release()
end

function T.hud_tile_patches_map_each_bar_cell_to_its_source_character_tile()
  local patchSpans = require("tests.support.BattlePresentationManifestFixture").manifest().hud.patchSpans
  local expectedHealth = {
    [0] = { 97, 98, 99, 100, 101, 102 },
    [1] = { 39, 96, 97, 98, 99, 100 },
    [2] = { 96, 97, 98, 99, 100, 101 },
    [3] = { 39, 96, 97, 98, 99, 100 },
    [4] = { 96, 97, 98, 99, 100, 101 },
    [5] = { 39, 96, 97, 98, 99, 100 },
  }
  for sideType = 0, 5 do
    local patches = BattleScene.hpPatchTiles(patchSpans, sideType, 9, 48)
    local destinations = {}
    for index, patch in ipairs(patches) do
      destinations[index] = patch.tile
      local fills = { 8, 1, 0, 0, 0, 0 }
      Assert.equal(
        patch.sourceTile,
        20 + fills[index],
        "nine pixels use the red component's source tile for cell " .. index
      )
    end
    Assert.deepEqual(
      destinations,
      expectedHealth[sideType],
      "side type " .. sideType .. " patches its six authored tile slots"
    )
  end

  local experience = BattleScene.expPatchTiles(patchSpans, { 8, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 })
  Assert.equal(experience[1].tile, 51, "the first experience cell maps into the first native patch span")
  Assert.equal(experience[5].tile, 55, "the fifth experience cell ends the first native span")
  Assert.equal(experience[6].tile, 112, "the sixth experience cell starts the second native span")
  Assert.equal(experience[1].sourceTile, 37, "a full experience tile selects component 29 plus fill 8")
  Assert.equal(experience[12].tile, 118, "the last experience cell reaches the end of the second span")
end

function T.hp_number_patch_spans_resolve_each_native_side_type()
  local patches = {
    currentHp = {
      { sideType = 0, tile = 104, count = 3 },
      { sideType = 1, tile = 49, count = 3 },
      { sideType = 2, tile = 96, count = 3 },
      { sideType = 3, tile = 49, count = 3 },
      { sideType = 4, tile = 96, count = 3 },
      { sideType = 5, tile = 49, count = 3 },
    },
    maximumHp = {
      { sideType = 0, tile = 108, count = 3 },
      { sideType = 1, tile = 53, count = 3 },
      { sideType = 2, tile = 100, count = 3 },
      { sideType = 3, tile = 53, count = 3 },
      { sideType = 4, tile = 100, count = 3 },
      { sideType = 5, tile = 53, count = 3 },
    },
  }
  for sideType = 0, 5 do
    local result = BattleScene.hpNumberPatchTiles(patches, sideType)
    local current = sideType == 0 and 104 or (sideType == 2 or sideType == 4) and 96 or 49
    local maximum = sideType == 0 and 108 or (sideType == 2 or sideType == 4) and 100 or 53
    Assert.deepEqual(result, {
      current = { { tile = current }, { tile = current + 1 }, { tile = current + 2 } },
      maximum = { { tile = maximum }, { tile = maximum + 1 }, { tile = maximum + 2 } },
    }, "side type " .. sideType .. " selects its native current and maximum HP character spans")
  end
end

function T.gauge_tasks_emit_native_character_patches_for_each_hit_checkpoint()
  local scene = BattleScene.new()
  local patchSpans = require("tests.support.BattlePresentationManifestFixture").manifest().hud.patchSpans
  scene:startGaugeTask("activation/7/hit/1", { maximum = 48, current = 30, delta = 1, tiles = 6 })
  local first = scene:gaugeTaskPatchTiles(patchSpans, "activation/7/hit/1", 0)
  Assert.equal(first[4].sourceTile, 8, "the first hit starts with the fourth green tile six pixels filled")
  scene:stepSourceTick()
  first = scene:gaugeTaskPatchTiles(patchSpans, "activation/7/hit/1", 0)
  Assert.equal(first[4].sourceTile, 7, "one source tick applies one native health unit to the current character tile")

  scene:startGaugeTask("activation/7/hit/2", { maximum = 48, current = 29, delta = 1, tiles = 6 })
  scene:stepSourceTick()
  local second = scene:gaugeTaskPatchTiles(patchSpans, "activation/7/hit/2", 0)
  Assert.equal(second[4].sourceTile, 6, "the next hit starts from its own checkpoint and patches its resulting fill")
end

-- All six slot rows carry distinct settled centers, spawn triples,
-- depths and health-box anchors; singles spawn from the screen edges
-- while doubles spawn from their own sides.
function T.slot_rows_carry_settled_spawn_depth_and_hud_anchors()
  local rows = slotGeometry()
  Assert.equal(#rows, 6, "six slot rows resolve")
  local function row(sideType)
    for _, candidate in ipairs(rows) do
      if candidate.sideType == sideType then
        return candidate
      end
    end
    error("side type " .. tostring(sideType) .. " resolves", 0)
  end
  local single = row(0)
  Assert.deepEqual({ single.settledX, single.settledY }, { 64, 112 }, "the single player settles at its center")
  Assert.deepEqual({ single.entryX, single.entryY }, { 336, 112 }, "the single player spawns off the right edge")
  Assert.deepEqual({ single.hudX, single.hudY }, { 192, 116 }, "the single player anchors its health box")
  local foe = row(1)
  Assert.deepEqual({ foe.settledX, foe.settledY }, { 192, 50 }, "the single foe settles at its center")
  Assert.deepEqual({ foe.entryX, foe.entryY }, { -80, 50 }, "the single foe spawns off the left edge")
  Assert.deepEqual({ foe.hudX, foe.hudY }, { 58, 36 }, "the single foe anchors its health box")
  Assert.deepEqual(
    { row(2).settledX, row(2).settledY, row(2).entryX, row(4).settledX, row(4).settledY, row(4).entryX },
    { 40, 112, 316, 80, 120, 356 },
    "the doubled players settle and spawn on their own side"
  )
  Assert.deepEqual(
    { row(3).settledX, row(3).settledY, row(3).entryX, row(5).settledX, row(5).settledY, row(5).entryX },
    { 216, 50, -60, 176, 42, -100 },
    "the doubled foes settle and spawn on their own side"
  )
  local depths = {}
  for _, candidate in ipairs(rows) do
    Assert.isTrue(type(candidate.depth) == "number", "side type " .. candidate.sideType .. " carries its depth")
    depths[#depths + 1] = candidate.depth
  end
  table.sort(depths)
  Assert.deepEqual(depths, { -640, -640, -512, -512, -100, 0 }, "slot depths follow the spawn table")
end

-- Records without a native position keep their single-battle row;
-- doubled records take their side row by sorted slot order.
function T.slot_resolution_keeps_singles_and_sorted_doubles_rows()
  local rows = slotGeometry()
  Assert.equal(BattleScene.slotRow({ side = 1 }, nil, rows).sideType, 0, "position-less players keep the single row")
  Assert.equal(BattleScene.slotRow({ side = 2 }, nil, rows).sideType, 1, "position-less foes keep the single row")
  Assert.equal(
    BattleScene.slotRow({ side = 1, position = 1 }, { 1, 2 }, rows).sideType,
    2,
    "the first sorted ally owns the left row"
  )
  Assert.equal(
    BattleScene.slotRow({ side = 1, position = 2 }, { 1, 2 }, rows).sideType,
    4,
    "the second sorted ally owns the right row"
  )
  Assert.equal(
    BattleScene.slotRow({ side = 2, position = 4 }, { 3, 4 }, rows).sideType,
    5,
    "the second sorted foe owns the right row whatever its raw slot"
  )
  Assert.equal(
    BattleScene.slotRow({ side = 2, position = 9 }, { 3, 4 }, rows).sideType,
    1,
    "an unclaimed slot falls back to the single row"
  )
end

function T.slot_resolution_uses_published_geometry_for_every_side_type()
  local rows = slotGeometry()
  rows[1].settledX = 71
  rows[2].settledX = 193
  rows[3].settledX = 41
  rows[4].settledX = 81
  rows[5].settledX = 217
  rows[6].settledX = 177
  local expected = {
    { side = 1, position = nil, sideType = 0, x = 71 },
    { side = 2, position = nil, sideType = 1, x = 193 },
    { side = 1, position = 1, order = { 1, 2 }, sideType = 2, x = 41 },
    { side = 1, position = 2, order = { 1, 2 }, sideType = 4, x = 81 },
    { side = 2, position = 3, order = { 3, 4 }, sideType = 3, x = 217 },
    { side = 2, position = 4, order = { 3, 4 }, sideType = 5, x = 177 },
  }
  for _, record in ipairs(expected) do
    local row = BattleScene.slotRow({ side = record.side, position = record.position }, record.order, rows)
    Assert.deepEqual(
      { row.sideType, row.settledX },
      { record.sideType, record.x },
      "slot geometry uses the published record for side type " .. record.sideType
    )
  end
end

-- The nominal 80x80 origin is the center minus the half inset minus the
-- signed height displacement; shadows center their own quad on the
-- battler center.
function T.origins_apply_half_inset_height_and_shadow_geometry()
  local x, y = BattleScene.originFor(192, 50, nil)
  Assert.deepEqual({ x, y }, { 152, 10 }, "the foe origin sits one half inset left and above its center")
  local tx, ty = BattleScene.originFor(192, 50, 12)
  Assert.deepEqual({ tx, ty }, { 152, -2 }, "a nonzero height displaces the origin upward only")
  Assert.equal(tx, x, "height displacement never moves the origin horizontally")
  local sx, sy = BattleScene.shadowOriginFor(192, 50)
  Assert.deepEqual({ sx, sy }, { 160, 42 }, "the shadow quad centers on the battler center")
  Assert.equal(BattleScene.SHADOW_WIDTH, 64, "shadows span their native width")
  Assert.equal(BattleScene.SHADOW_HEIGHT, 16, "shadows span their native height")
  Assert.equal(BattleScene.SHADOW_DEPTH, -1000, "shadows sit behind every picture plane")
end

-- Health pixels follow integer division with the minimum-visible rule
-- across zero, small, boundary and large values.
function T.health_pixels_quantize_with_minimum_visible_nonzero()
  local cases = {
    { hp = 0, maxHp = 48, want = 0 },
    { hp = 1, maxHp = 30, want = 1 },
    { hp = 1, maxHp = 48, want = 1 },
    { hp = 2, maxHp = 48, want = 2 },
    { hp = 7, maxHp = 30, want = 11 },
    { hp = 5, maxHp = 7, want = 34 },
    { hp = 9, maxHp = 48, want = 9 },
    { hp = 10, maxHp = 48, want = 10 },
    { hp = 24, maxHp = 48, want = 24 },
    { hp = 25, maxHp = 48, want = 25 },
    { hp = 30, maxHp = 30, want = 48 },
    { hp = 48, maxHp = 48, want = 48 },
    { hp = 999, maxHp = 999, want = 48 },
    { hp = 1000, maxHp = 999, want = 48 },
    { hp = -4, maxHp = 30, want = 0 },
    { hp = 12, maxHp = 0, want = 0 },
  }
  for _, case in ipairs(cases) do
    Assert.equal(
      BattleScene.hpPixels(case.hp, case.maxHp),
      case.want,
      "health " .. tostring(case.hp) .. "/" .. tostring(case.maxHp) .. " fills " .. tostring(case.want) .. " pixels"
    )
  end
  for hp = 0, 8 do
    local pixels = BattleScene.hpPixels(hp, 7)
    if hp == 0 then
      Assert.equal(pixels, 0, "zero of seven fills nothing")
    else
      Assert.isTrue(pixels >= 1 and pixels <= 48, "health " .. hp .. " of seven stays visible and bounded")
    end
  end
end

-- Color boundaries follow the fixed-point compares exactly: 24 stays
-- yellow, 25 turns green, 10 stays yellow, 9 turns red, 1 stays red.
function T.health_colors_follow_exact_capacity_boundaries()
  Assert.equal(BattleScene.hpColorIdx(48), 3, "a full bar reads green")
  Assert.equal(BattleScene.hpColorIdx(25), 3, "one pixel above half reads green")
  Assert.equal(BattleScene.hpColorIdx(24), 2, "exactly half reads yellow")
  Assert.equal(BattleScene.hpColorIdx(11), 2, "eleven pixels read yellow")
  Assert.equal(BattleScene.hpColorIdx(10), 2, "ten pixels read yellow")
  Assert.equal(BattleScene.hpColorIdx(9), 1, "nine pixels read red")
  Assert.equal(BattleScene.hpColorIdx(1), 1, "one pixel reads red")
  Assert.equal(BattleScene.hpColorIdx(0), 0, "zero pixels read fainted")
  Assert.equal(BattleScene.hpComponentBase(3), 2, "green selects its component base")
  Assert.equal(BattleScene.hpComponentBase(2), 11, "yellow selects its component base")
  Assert.equal(BattleScene.hpComponentBase(1), 20, "red selects its component base")
  Assert.equal(BattleScene.hpComponentBase(0), 20, "fainted patches the red base empty")
end

-- Tile fills drain full tiles first with the minimum-visible seed, and
-- the six fills always sum to the pixel count.
function T.health_tile_fills_drain_full_tiles_first()
  Assert.deepEqual(BattleScene.hpTileFills(30, 30), { 8, 8, 8, 8, 8, 8 }, "full health fills every tile")
  Assert.deepEqual(BattleScene.hpTileFills(9, 48), { 8, 1, 0, 0, 0, 0 }, "nine pixels spill one into the second tile")
  Assert.deepEqual(BattleScene.hpTileFills(1, 30), { 1, 0, 0, 0, 0, 0 }, "the minimum visible seed fills one")
  Assert.deepEqual(BattleScene.hpTileFills(0, 48), { 0, 0, 0, 0, 0, 0 }, "zero health fills nothing")
  local vectors = {
    { hp = 22, maxHp = 30 },
    { hp = 15, maxHp = 30 },
    { hp = 5, maxHp = 7 },
    { hp = 767, maxHp = 999 },
  }
  for _, vector in ipairs(vectors) do
    local fills = BattleScene.hpTileFills(vector.hp, vector.maxHp)
    local total = 0
    for _, fill in ipairs(fills) do
      Assert.isTrue(fill >= 0 and fill <= 8, "fills stay in tile range")
      total = total + fill
    end
    Assert.equal(
      total,
      BattleScene.hpPixels(vector.hp, vector.maxHp),
      "fills sum to the pixel count at " .. vector.hp .. "/" .. vector.maxHp
    )
  end
end

-- Experience pixels divide over the level span with clamps; a missing
-- or empty span draws nothing.
function T.experience_pixels_divide_over_the_level_span()
  Assert.equal(BattleScene.expPixels(30, 100), 28, "thirty of one hundred fills twenty-eight pixels")
  Assert.equal(BattleScene.expPixels(0, 100), 0, "zero progress fills nothing")
  Assert.equal(BattleScene.expPixels(100, 100), 96, "a full span fills every tile")
  Assert.equal(BattleScene.expPixels(200, 100), 96, "overflow clamps to the capacity")
  Assert.equal(BattleScene.expPixels(-5, 100), 0, "negative progress clamps to zero")
  Assert.equal(BattleScene.expPixels(40, 0), 0, "an empty span fills nothing")
  Assert.equal(BattleScene.expPixels(40, nil), 0, "a missing span fills nothing")
  local fills = BattleScene.expTileFills(30, 100)
  Assert.equal(#fills, 12, "experience spans twelve tiles")
  local total = 0
  for _, fill in ipairs(fills) do
    Assert.isTrue(fill >= 0 and fill <= 8, "experience fills stay in tile range")
    total = total + fill
  end
  Assert.equal(total, 28, "experience fills sum to the pixel count")
  Assert.deepEqual(
    BattleScene.expTileFills(0, 0),
    { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    "a capped level forces all-zero experience tiles"
  )
end

-- The opening observation installs settled positions; explicit controller
-- start arms only the new activation while survivors stay settled.
function T.entry_arms_arrivals_and_keeps_survivors_settled()
  local scene = BattleScene.new()
  local rows = slotGeometry()
  local survivor = { combatant = 2, side = 2, position = 2, activation = 12, visible = true }
  local ally = { combatant = 1, side = 1, position = 0, activation = 11, visible = true }
  scene:observe({ ally, survivor })
  local foeRow = BattleScene.slotRow(survivor, { 2, 3 }, rows)
  local dx, dy = scene:entryOffsetFor(survivor, foeRow)
  Assert.deepEqual({ dx, dy }, { 0, 0 }, "the opening installs settled positions")
  local arrival = { combatant = 3, side = 2, position = 3, activation = 21, visible = false }
  scene:observe({ ally, survivor, arrival })
  local arrivalRow = BattleScene.slotRow(arrival, { 2, 3 }, rows)
  Assert.equal(arrivalRow.sideType, 5, "the arrival resolves its own side type")
  local sdx, sdy = scene:entryOffsetFor(survivor, foeRow)
  Assert.deepEqual({ sdx, sdy }, { 0, 0 }, "arming an arrival never moves its survivor")
  arrival.visible = true
  scene:observe({ ally, survivor, arrival })
  scene:startEntry(arrival, arrivalRow, 8)
  local adx, ady = scene:entryOffsetFor(arrival, arrivalRow)
  Assert.deepEqual(
    { adx, ady },
    { arrivalRow.entryX - arrivalRow.settledX, arrivalRow.entryY - arrivalRow.settledY },
    "a revealed arrival starts displaced toward its spawn side"
  )
  Assert.isTrue(adx < 0, "the right-side arrival starts left of its settled edge")
  for _ = 1, 27 do
    scene:stepSourceTick()
  end
  Assert.equal(
    (scene:entryOffsetFor(arrival, arrivalRow)),
    adx,
    "the local controller waits through 27 source updates before its first movement"
  )
  scene:stepSourceTick()
  local firstStep = (scene:entryOffsetFor(arrival, arrivalRow))
  Assert.equal(firstStep, adx + 8, "the opponent controller moves eight pixels on its first travel update")
  for _ = 1, 34 do
    scene:stepSourceTick()
  end
  local endX, endY = scene:entryOffsetFor(arrival, arrivalRow)
  Assert.deepEqual({ endX, endY }, { 0, 0 }, "the source step loop snaps to its settled edge")
  scene:stepSourceTick()
  local settledX, settledY = scene:entryOffsetFor(arrival, arrivalRow)
  Assert.deepEqual({ settledX, settledY }, { 0, 0 }, "settled entries never overshoot")
end

function T.visibility_does_not_start_controller_entry_without_an_explicit_task()
  local scene = BattleScene.new()
  local rows = slotGeometry()
  local opening = { combatant = 2, side = 2, position = 2, activation = 12, visible = true }
  scene:observe({ opening })
  local arrival = { combatant = 3, side = 2, position = 3, activation = 21, visible = false }
  scene:observe({ opening, arrival })
  arrival.visible = true
  scene:observe({ opening, arrival })
  local row = BattleScene.slotRow(arrival, { 2, 3 }, rows)
  Assert.deepEqual(
    { scene:entryOffsetFor(arrival, row) },
    { 0, 0 },
    "the observation path does not invent a controller start from visibility"
  )
end

function T.entry_completion_waits_for_controller_picture_and_optional_task_gates()
  local scene = BattleScene.new()
  scene:observe({ { combatant = 1, visible = true } })
  local arrival = { combatant = 2, activation = 2, side = 2, position = 1, visible = true }
  scene:install(arrival)
  scene:startEntry(arrival, { entryX = 0, settledX = 8 }, 8)
  for _ = 1, BattleScene.ENTRY_WAIT_TICKS + 1 do
    scene:stepSourceTick()
  end
  Assert.equal(scene:entryStatus(arrival), "awaiting-completion", "movement reaches the controller gate")

  Assert.isFalse(
    scene:completeEntry(arrival, {
      battlerReady = false,
      pictureAnimationActive = false,
      followupTaskRequired = false,
      followupTaskComplete = false,
    }),
    "the controller cannot complete before its battler state is ready"
  )
  Assert.isFalse(
    scene:completeEntry(arrival, {
      battlerReady = true,
      pictureAnimationActive = true,
      followupTaskRequired = false,
      followupTaskComplete = false,
    }),
    "the controller waits for the Pokepic animation to finish"
  )
  Assert.isFalse(
    scene:completeEntry(arrival, {
      battlerReady = true,
      pictureAnimationActive = false,
      followupTaskRequired = true,
      followupTaskComplete = false,
    }),
    "the optional controller child task holds completion"
  )
  Assert.isTrue(
    scene:completeEntry(arrival, {
      battlerReady = true,
      pictureAnimationActive = false,
      followupTaskRequired = true,
      followupTaskComplete = true,
    }),
    "the controller completes only after every applicable source gate"
  )
  Assert.equal(scene:entryStatus(arrival), "complete", "the completed controller task clears its movement state")
  scene:release()
end

function T.controller_entry_vectors_cover_each_source_side_type()
  local expectedFirstOffset = { [0] = 264, [1] = -264, [2] = 268, [3] = -268, [4] = 268, [5] = -268 }
  for _, row in ipairs(slotGeometry()) do
    local scene = BattleScene.new()
    scene:observe({ { combatant = 1, visible = true } })
    local arrival = { combatant = 2, activation = row.sideType, visible = true }
    scene:install(arrival)
    local stepX = row.settledX > row.entryX and 8 or -8
    scene:startEntry(arrival, row, stepX)
    local startX = scene:entryOffsetFor(arrival, row)
    for _ = 1, 27 do
      scene:stepSourceTick()
    end
    Assert.equal(scene:entryOffsetFor(arrival, row), startX, "side type " .. row.sideType .. " waits before movement")
    scene:stepSourceTick()
    Assert.equal(
      scene:entryOffsetFor(arrival, row),
      expectedFirstOffset[row.sideType],
      "side type " .. row.sideType .. " follows its horizontal source step"
    )
    for _ = 1, 35 do
      scene:stepSourceTick()
    end
    Assert.equal(scene:entryOffsetFor(arrival, row), 0, "side type " .. row.sideType .. " settles at its own center")
    Assert.equal(
      scene:entryStatus(arrival),
      "awaiting-completion",
      "side type " .. row.sideType .. " reaches its controller gate"
    )
    Assert.isTrue(
      scene:completeEntry(arrival, {
        battlerReady = true,
        pictureAnimationActive = false,
        followupTaskRequired = false,
        followupTaskComplete = false,
      }),
      "source entry completes after its controller gates are satisfied"
    )
    Assert.equal(scene:entryStatus(arrival), "complete", "side type " .. row.sideType .. " completes explicitly")
  end
end

-- Observation never advances the clock: repeated frames without source
-- ticks keep the travel parked, while banked seconds step whole ticks.
function T.entry_advances_on_source_ticks_never_on_observation()
  local scene = BattleScene.new()
  local rows = slotGeometry()
  scene:observe({ { combatant = 1, side = 1, visible = true } })
  local arrival = { combatant = 3, side = 2, position = 3, activation = 21, visible = true }
  local row = BattleScene.slotRow(arrival, { 2, 3 }, rows)
  scene:install(arrival)
  scene:startEntry(arrival, row, 8)
  local first = (scene:entryOffsetFor(arrival, row))
  for _ = 1, 100 do
    scene:observe({ { combatant = 1, side = 1, visible = true }, arrival })
  end
  Assert.equal((scene:entryOffsetFor(arrival, row)), first, "observation alone never advances travel")
  scene:advance(1 / 120)
  Assert.equal((scene:entryOffsetFor(arrival, row)), first, "a partial frame never advances travel")
  scene:advance(1 / 60 + 1 / 30)
  local stillWaiting = (scene:entryOffsetFor(arrival, row))
  Assert.equal(stillWaiting, first, "banked seconds remain inside the controller wait")
  scene:advance(26 / 30)
  Assert.equal((scene:entryOffsetFor(arrival, row)), first, "the first 27 updates finish the wait")
  scene:advance(1 / 30)
  local moved = (scene:entryOffsetFor(arrival, row))
  Assert.isTrue(moved > first, "the controller starts on update 28")
end

-- Background scroll patches decoded layer state and starts settled;
-- transient effects allocate concrete records and release idempotently.
function T.scroll_patches_effects_allocate_and_release_is_idempotent()
  local scene = BattleScene.new()
  Assert.deepEqual(scene:scroll(), { x = 0, y = 0 }, "scroll starts settled")
  scene:applyScrollPatch(24, 16)
  Assert.deepEqual(scene:scroll(), { x = 24, y = 16 }, "scroll patches decoded layer state")
  local first = scene:allocEffect("weather")
  local second = scene:allocEffect("transition")
  Assert.equal(first.id, 1, "effects allocate identities in order")
  Assert.equal(second.id, 2, "later effects allocate later identities")
  Assert.equal(first.age, 0, "effects start at age zero")
  scene:stepSourceTick()
  Assert.equal(first.age, 1, "source ticks age live effects")
  scene:releaseEffect(first.id)
  scene:releaseEffect(first.id)
  Assert.isTrue(true, "releasing one effect twice stays silent")
  scene:release()
  scene:release()
  Assert.isTrue(true, "launch-scoped release is idempotent")
end

function T.transient_picture_effect_views_are_detached_and_source_ticked()
  local scene = BattleScene.new()
  local effect = scene:allocEffect("animation-picture")
  scene:setEffectPicture(effect.id, {
    assetKey = "battle/effect/overlay",
    selector = "PIKACHU/0/male/plain/front",
    centerX = 72,
    centerY = 84,
    zCenter = -120,
    width = 32,
    height = 24,
    alpha = 0.75,
  })
  local first = scene:effectViews()
  Assert.equal(#first, 1, "an allocated effect enters the immutable scene view")
  Assert.equal(first[1].picture.assetKey, "battle/effect/overlay", "the effect uses its staged drawable key")
  Assert.equal(first[1].picture.zCenter, -120, "the effect keeps native depth separate from screen position")
  first[1].picture.centerX = -1
  Assert.equal(scene:effectViews()[1].picture.centerX, 72, "editing a detached view cannot mutate scene state")
  scene:stepSourceTick()
  Assert.equal(scene:effectViews()[1].age, 1, "source ticks advance the effect instance")
  scene:releaseEffect(effect.id)
  Assert.equal(#scene:effectViews(), 0, "released effects leave the render view")
  scene:release()
end

return { tests = T }
