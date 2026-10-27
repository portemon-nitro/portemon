-- Synthetic tests for the opening-movie source declarations. Pins the
-- edition-conditioned member inventory, the closed movie event grammar, the
-- scene 5 edition scroll, and the retail town and emitter sets without
-- touching a ROM.

local Assert = require("tests.support.Assert")
local SceneSources = require("romdump.src.digest.startup.OpeningMovieSceneSources")

local T = {}

local function sorted(values)
  local copy = {}
  for _, value in ipairs(values) do
    copy[#copy + 1] = value
  end
  table.sort(copy)
  return copy
end

function T.scene_sources_reject_bad_scenes_and_editions()
  for _, badScene in ipairs({ 0, 6, 1.5, "1" }) do
    Assert.isFalse(
      pcall(SceneSources.backgrounds, "soulsilver", badScene),
      "scene " .. tostring(badScene) .. " is rejected"
    )
    Assert.isFalse(
      pcall(SceneSources.objects, "soulsilver", badScene),
      "scene " .. tostring(badScene) .. " is rejected"
    )
    Assert.isFalse(
      pcall(SceneSources.memberSet, "soulsilver", badScene),
      "scene " .. tostring(badScene) .. " is rejected"
    )
    Assert.isFalse(
      pcall(SceneSources.spriteInstances, badScene),
      "scene " .. tostring(badScene) .. " declares no sprite instances"
    )
  end
  for _, badEdition in ipairs({ "platinum", "", 1 }) do
    Assert.isFalse(pcall(SceneSources.backgrounds, badEdition, 1), "edition " .. tostring(badEdition) .. " is rejected")
    Assert.isFalse(pcall(SceneSources.memberSet, badEdition, 1), "edition " .. tostring(badEdition) .. " is rejected")
  end
end

function T.scene_sources_keep_five_bounded_scenes_at_the_source_tick_rate()
  Assert.equal(SceneSources.SCHEMA, "g4-startup-opening-scene-v9", "the scene schema is pinned")
  Assert.equal(SceneSources.TICK_RATE, 30, "the scenes run at the retail 30 Hz source frame rate")
  Assert.equal(SceneSources.PARTICLE_ARCHIVE, "NARC_a_0_5_9", "the particle archive is pinned")
  Assert.equal(SceneSources.PARTICLE_MEMBER, 4, "the starter particle member is pinned")
end

function T.scene_sources_group_background_slots_by_engine_with_numeric_planes()
  local first = SceneSources.backgrounds("soulsilver", 1)
  local slots = {}
  for _, background in ipairs(first) do
    Assert.isTrue(background.engine == "main" or background.engine == "sub", "scene 1 layers name a source engine")
    Assert.isTrue(
      type(background.bgSlot) == "number" and background.bgSlot % 1 == 0 and background.bgSlot <= 3,
      "scene 1 layers name a numeric plane"
    )
    Assert.equal(background.priority, background.bgSlot, "scene 1 priority mirrors its source plane order")
    slots[background.engine .. ":" .. background.bgSlot] = true
  end
  Assert.isTrue(slots["main:1"] and slots["main:2"] and slots["main:3"], "scene 1 keeps its sunrise planes")
  local third = SceneSources.backgrounds("soulsilver", 3)
  local alternates = 0
  for _, background in ipairs(third) do
    Assert.equal(background.engine, "sub", "scene 3 panels stay on the sub engine")
    for _, alternate in ipairs(background.alternates or {}) do
      Assert.isTrue(type(alternate.char) == "number", "scene 3 panel swaps name a character member")
      Assert.isTrue(type(alternate.screen) == "number", "scene 3 panel swaps name a screen member")
      alternates = alternates + 1
    end
  end
  Assert.isTrue(alternates >= 6, "scene 3 declares its rival, beast, and rocket panel swaps")
end

-- Retail sprite stations transcribed from the pinned decomp CreateSprites
-- functions: scene 1 sun and bird share (128, 96) on the main engine
-- (src/intro_movie_scene_1.c IntroMovie_Scene1_CreateSprites);
-- scene 2 holds ten flowers at (128, 192) with both-engines character
-- data plus three ethan at (64, -96) and three lyra at (320, -96) on the
-- main engine (src/intro_movie_scene_2.c IntroMovie_Scene2_CreateSprites);
-- scene 3 holds silver at (128, 608), eusine at (32, 608), and unowns at
-- (128, 544/672/608) on the sub engine, all starting offscreen
-- (src/intro_movie_scene_3.c IntroMovie_Scene3_CreateSprites);
-- scene 4 holds hand1 at (128, 352) on the sub engine with hand2,
-- sparkles, and all three starters at (128, 96) on the main engine
-- (src/intro_movie_scene_4.c IntroMovie_Scene4_CreateSprites);
-- scene 5 creates no sprites (src/intro_movie_scene_5.c
-- IntroMovie_Scene5_CreateSprites is empty). Flowers carry one instance
-- per displaying engine because the decomp enables sprite pixels on both
-- engines for their both-engines character data and draws every sprite to
-- every active engine surface, so a single-engine instance cannot cover
-- both copies (see the scene 2 LoadSpriteGfx engine toggles and the
-- NNS-G2D all-surfaces draw in the vendored renderer).
local function expectedSceneInstances()
  local scenes = {
    [1] = {
      { id = "sun", engine = "main", x = 128, y = 96, drawOrder = 1 },
      { id = "bird", engine = "main", x = 128, y = 96, drawOrder = 2 },
    },
    [3] = {
      { id = "eusine", engine = "sub", x = 32, y = 608, drawOrder = 1 },
      { id = "unown0", engine = "sub", x = 128, y = 544, drawOrder = 2 },
      { id = "unown1", engine = "sub", x = 128, y = 672, drawOrder = 3 },
      { id = "unown2", engine = "sub", x = 128, y = 608, drawOrder = 4 },
      { id = "silver-silhouette", engine = "sub", x = 128, y = 608, drawOrder = 5 },
    },
    [4] = {
      { id = "hand1", engine = "sub", x = 128, y = 352, drawOrder = 1 },
      { id = "hand2", engine = "main", x = 128, y = 96, drawOrder = 1 },
      { id = "chikorita", engine = "main", x = 128, y = 96, drawOrder = 2 },
      { id = "cyndaquil", engine = "main", x = 128, y = 96, drawOrder = 2 },
      { id = "totodile", engine = "main", x = 128, y = 96, drawOrder = 2 },
      { id = "sparkles", engine = "main", x = 128, y = 96, drawOrder = 3 },
    },
    [5] = {},
  }
  local second = {}
  for flower = 1, 10 do
    second[#second + 1] = { id = "flower" .. flower .. "-main", engine = "main", x = 128, y = 192, drawOrder = flower }
    second[#second + 1] = { id = "flower" .. flower .. "-sub", engine = "sub", x = 128, y = 192, drawOrder = flower }
  end
  for hero = 0, 2 do
    second[#second + 1] = { id = "ethan" .. hero, engine = "main", x = 64, y = -96, drawOrder = 11 + hero }
    second[#second + 1] = { id = "lyra" .. hero, engine = "main", x = 320, y = -96, drawOrder = 14 + hero }
  end
  scenes[2] = second
  return scenes
end

function T.scene_sources_declare_stable_sprite_instances_per_scene()
  local expected = expectedSceneInstances()
  local counts = { 2, 26, 5, 6, 0 }
  for sceneNumber = 1, 5 do
    local instances = SceneSources.spriteInstances(sceneNumber)
    Assert.equal(#instances, counts[sceneNumber], "scene " .. sceneNumber .. " declares its sprite instances")
    local seen = {}
    for _, instance in ipairs(instances) do
      Assert.isTrue(type(instance.id) == "string" and instance.id ~= "", "scene instances carry stable ids")
      Assert.isNil(seen[instance.id], "scene " .. sceneNumber .. " keeps each instance id once")
      seen[instance.id] = true
      Assert.isTrue(instance.engine == "main" or instance.engine == "sub", "scene instances name a source engine")
      Assert.isTrue(
        type(instance.x) == "number" and type(instance.y) == "number",
        "scene instances carry stage stations"
      )
      Assert.isTrue(
        type(instance.drawOrder) == "number" and instance.drawOrder % 1 == 0,
        "scene instances carry a draw order"
      )
    end
    for _, wanted in ipairs(expected[sceneNumber]) do
      local found = seen[wanted.id]
      Assert.isTrue(found ~= nil, "scene " .. sceneNumber .. " keeps its retail instance " .. wanted.id)
      for _, instance in ipairs(instances) do
        if instance.id == wanted.id then
          Assert.equal(instance.engine, wanted.engine, wanted.id .. " names its retail engine")
          Assert.equal(instance.x, wanted.x, wanted.id .. " keeps its retail x")
          Assert.equal(instance.y, wanted.y, wanted.id .. " keeps its retail y")
          Assert.equal(instance.drawOrder, wanted.drawOrder, wanted.id .. " keeps its draw order")
        end
      end
    end
  end
end

function T.scene_sources_condition_scene_one_members_by_edition()
  local heartgold = SceneSources.memberSet("heartgold", 1)
  local soulsilver = SceneSources.memberSet("soulsilver", 1)
  for _, memberId in ipairs({ 0, 1, 6, 7, 15, 16, 17, 18, 23, 24, 25, 26 }) do
    local found = false
    for _, candidate in ipairs(heartgold) do
      if candidate == memberId then
        found = true
      end
    end
    Assert.isTrue(found, "heartgold scene 1 keeps member " .. memberId)
  end
  for _, memberId in ipairs({ 2, 3, 8, 9, 19, 20, 21, 22, 27, 28, 29, 30 }) do
    local found = false
    for _, candidate in ipairs(soulsilver) do
      if candidate == memberId then
        found = true
      end
    end
    Assert.isTrue(found, "soulsilver scene 1 keeps member " .. memberId)
  end
  for _, memberId in ipairs({ 4, 5, 12, 13, 14 }) do
    local inHeartgold, inSoulsilver = false, false
    for _, candidate in ipairs(heartgold) do
      if candidate == memberId then
        inHeartgold = true
      end
    end
    for _, candidate in ipairs(soulsilver) do
      if candidate == memberId then
        inSoulsilver = true
      end
    end
    Assert.isTrue(inHeartgold and inSoulsilver, "member " .. memberId .. " is shared across editions")
  end
end

function T.scene_sources_keep_scene_member_inventories_bounded()
  Assert.deepEqual(sorted(SceneSources.memberSet("soulsilver", 2)), {
    31,
    32,
    33,
    34,
    35,
    36,
    37,
    38,
    73,
    74,
    75,
    76,
    77,
    78,
    79,
    80,
  })
  local scene4 = SceneSources.memberSet("soulsilver", 4)
  for _, memberId in ipairs({ 53, 54, 55, 56, 57, 58, 81, 82, 83, 84 }) do
    local found = false
    for _, candidate in ipairs(scene4) do
      if candidate == memberId then
        found = true
      end
    end
    Assert.isTrue(found, "scene 4 keeps member " .. memberId)
  end
  Assert.deepEqual(sorted(SceneSources.memberSet("soulsilver", 5)), { 31, 39, 59, 60, 61, 62, 63, 64 })
end

function T.scene_sources_keep_three_towns_with_two_clips_each()
  local towns = SceneSources.townSet()
  Assert.equal(#towns.models, 3, "the scene keeps its three towns")
  local names = { towns.models[1].name, towns.models[2].name, towns.models[3].name }
  Assert.deepEqual(names, { "new-bark-town", "goldenrod-city", "ecruteak-city" })
  Assert.deepEqual({ towns.models[1].model, towns.models[2].model, towns.models[3].model }, { 103, 100, 97 })
  for _, town in ipairs(towns.models) do
    Assert.equal(#town.clips, 2, town.name .. " keeps its two animation channels")
  end
  Assert.equal(#towns.lighting, 3, "each town keeps its lighting record")
  Assert.notNil(towns.camera.distance, "the towns keep their source camera set")
end

function T.scene_sources_group_nine_starter_emitters()
  local starters = SceneSources.starterEmitters()
  Assert.equal(#starters, 3, "the scene keeps its three starters")
  Assert.deepEqual({ starters[1].speciesId, starters[2].speciesId, starters[3].speciesId }, { 152, 155, 158 })
  Assert.deepEqual({ starters[1].group, starters[2].group, starters[3].group }, { "grass", "fire", "water" })
  Assert.deepEqual(starters[1].emitters, { 6, 7, 8 })
  Assert.deepEqual(starters[2].emitters, { 3, 4, 5 })
  Assert.deepEqual(starters[3].emitters, { 0, 1, 2 })
  Assert.equal(SceneSources.starterSpecies("chikorita"), 152, "chikorita resolves its species")
  Assert.equal(SceneSources.starterSpecies("cyndaquil"), 155, "cyndaquil resolves its species")
  Assert.equal(SceneSources.starterSpecies("totodile"), 158, "totodile resolves its species")
  Assert.isFalse(pcall(SceneSources.starterSpecies, "pikachu"), "an unknown starter is rejected")
end

function T.scene_sources_declare_post_init_plane_visibility_per_slot()
  -- Post-init plane facts transcribed from the retail scene setup: template
  -- defaults enable every plane, then each scene toggles selected planes off
  -- before the first step runs. The compiler records these verbatim; the
  -- reader requires one boolean per compiled slot.
  local cases = {
    { scene = 1, engine = "main", slot = 0, visible = false },
    { scene = 1, engine = "main", slot = 1, visible = false },
    { scene = 1, engine = "main", slot = 2, visible = false },
    { scene = 1, engine = "main", slot = 3, visible = false },
    { scene = 1, engine = "sub", slot = 0, visible = false },
    { scene = 1, engine = "sub", slot = 1, visible = false },
    { scene = 1, engine = "sub", slot = 3, visible = false },
    { scene = 2, engine = "main", slot = 0, visible = true },
    { scene = 2, engine = "main", slot = 1, visible = true },
    { scene = 2, engine = "main", slot = 2, visible = true },
    { scene = 2, engine = "sub", slot = 0, visible = true },
    { scene = 3, engine = "sub", slot = 0, visible = true },
    { scene = 3, engine = "sub", slot = 1, visible = false },
    { scene = 3, engine = "sub", slot = 2, visible = false },
    { scene = 3, engine = "sub", slot = 3, visible = true },
    { scene = 4, engine = "main", slot = 1, visible = false },
    { scene = 4, engine = "main", slot = 2, visible = false },
    { scene = 4, engine = "main", slot = 3, visible = true },
    { scene = 4, engine = "sub", slot = 1, visible = false },
    { scene = 4, engine = "sub", slot = 2, visible = true },
    { scene = 4, engine = "sub", slot = 3, visible = true },
    { scene = 5, engine = "main", slot = 1, visible = true },
    { scene = 5, engine = "main", slot = 2, visible = true },
    { scene = 5, engine = "sub", slot = 1, visible = true },
    { scene = 5, engine = "sub", slot = 2, visible = true },
  }
  Assert.isTrue(type(SceneSources.initialVisible) == "function", "the sources publish post-init plane state")
  for _, case in ipairs(cases) do
    Assert.equal(
      SceneSources.initialVisible(case.scene, case.engine, case.slot),
      case.visible,
      "scene " .. case.scene .. " " .. case.engine .. " plane " .. case.slot .. " starts "
        .. (case.visible and "enabled" or "disabled")
    )
  end
  Assert.isFalse(
    pcall(SceneSources.initialVisible, 1, "main", 9),
    "an uncompiled slot declares no plane state"
  )
end

function T.scene_sources_declare_engine_window_pans_with_masks()
  Assert.isTrue(type(SceneSources.windowPans) == "function", "the sources publish window pan facts")
  local fourth = SceneSources.windowPans(4)
  Assert.equal(#fourth, 4, "scene 4 keeps its two slide-in and two slide-out pans")
  local slideInTop = nil
  local slideInBottom = nil
  for _, pan in ipairs(fourth) do
    Assert.isTrue(pan.duration == 10, "scene 4 slides run ten source frames")
    Assert.equal(pan.winIn, 30, "scene 4 slides keep their inside mask")
    Assert.equal(pan.winOut, 28, "scene 4 slides keep their outside mask")
    if pan.whichScreen == 0 then
      slideInTop = slideInTop or pan
    else
      slideInBottom = slideInBottom or pan
    end
  end
  Assert.notNil(slideInTop, "scene 4 keeps its top-screen pan")
  Assert.notNil(slideInBottom, "scene 4 keeps its bottom-screen pan")
  Assert.deepEqual(
    { slideInTop.x1Start, slideInTop.y1Start, slideInTop.x2Start, slideInTop.y2Start },
    { 255, 0, 255, 192 },
    "the top slide starts retracted"
  )
  Assert.deepEqual(
    { slideInBottom.x1Start, slideInBottom.y1Start, slideInBottom.x2Start, slideInBottom.y2Start },
    { 0, 0, 0, 192 },
    "the bottom slide starts retracted"
  )
  local third = SceneSources.windowPans(3)
  Assert.equal(#third, 11, "scene 3 keeps its eleven pan facts")
  for _, pan in ipairs(third) do
    Assert.equal(pan.whichScreen, 0, "every scene 3 pan addresses the sub engine registers")
    Assert.isTrue(pan.winIn >= 0 and pan.winIn <= 31, "scene 3 pans keep a plane inside mask")
    Assert.isTrue(pan.winOut >= 0 and pan.winOut <= 31, "scene 3 pans keep a plane outside mask")
  end
  local narrowY = nil
  for _, pan in ipairs(third) do
    if pan.duration == 5 then
      narrowY = pan
    end
  end
  Assert.notNil(narrowY, "scene 3 keeps its five-frame narrow pan")
  Assert.deepEqual(
    { narrowY.x1Start, narrowY.y1Start, narrowY.x2Start, narrowY.y2Start },
    { 0, 0, 255, 192 },
    "the narrow pan starts full width"
  )
  Assert.deepEqual(
    { narrowY.x1End, narrowY.y1End, narrowY.x2End, narrowY.y2End },
    { 0, 64, 255, 128 },
    "the narrow pan ends on the cinematic band"
  )
  Assert.isFalse(pcall(SceneSources.windowPans, 6), "an unknown scene declares no window pans")
end

function T.scene_sources_scroll_scene_five_by_edition()
  Assert.equal(SceneSources.scene5ScrollDirection("heartgold"), "left", "heartgold scrolls its panorama left")
  Assert.equal(SceneSources.scene5ScrollDirection("soulsilver"), "right", "soulsilver scrolls its panorama right")
  Assert.isFalse(pcall(SceneSources.scene5ScrollDirection, "platinum"), "an unknown edition scrolls nowhere")
end

function T.scene_sources_alias_the_current_opening_scene_contract()
  local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
  Assert.equal(
    SceneSources.SCHEMA,
    DerivedAssetContract.startupOpeningScene.schema,
    "the scene sources publish under the current opening scene contract"
  )
  Assert.equal(
    SceneSources.SCHEMA,
    "g4-startup-opening-scene-v9",
    "the scene sources carry the current native scene shape"
  )
  Assert.equal(SceneSources.TICK_RATE, 30, "the scenes keep the retail 30 Hz source tick rate")
end

return { tests = T }
