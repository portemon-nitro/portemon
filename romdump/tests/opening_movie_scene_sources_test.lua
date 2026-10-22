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
  end
  for _, badEdition in ipairs({ "platinum", "", 1 }) do
    Assert.isFalse(pcall(SceneSources.backgrounds, badEdition, 1), "edition " .. tostring(badEdition) .. " is rejected")
    Assert.isFalse(pcall(SceneSources.memberSet, badEdition, 1), "edition " .. tostring(badEdition) .. " is rejected")
  end
end

function T.scene_sources_keep_five_bounded_scenes_at_the_source_tick_rate()
  Assert.equal(SceneSources.SCHEMA, "g4-startup-opening-scene-v1", "the scene schema is pinned")
  Assert.equal(SceneSources.TICK_RATE, 30, "the scenes run at the source frame rate")
  Assert.equal(SceneSources.PARTICLE_ARCHIVE, "NARC_a_0_5_9", "the particle archive is pinned")
  Assert.equal(SceneSources.PARTICLE_MEMBER, 4, "the starter particle member is pinned")
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

function T.scene_sources_scroll_scene_five_by_edition()
  Assert.equal(SceneSources.scene5ScrollDirection("heartgold"), "left", "heartgold scrolls its panorama left")
  Assert.equal(SceneSources.scene5ScrollDirection("soulsilver"), "right", "soulsilver scrolls its panorama right")
  Assert.isFalse(pcall(SceneSources.scene5ScrollDirection, "platinum"), "an unknown edition scrolls nowhere")
end

return { tests = T }
