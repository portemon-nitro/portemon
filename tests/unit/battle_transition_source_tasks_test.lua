-- Source-normalized transition programs from pret/pokeheartgold commit
-- 9d8b7591f09b65804da2fb2dfd56f320633e0d36, including overlay_116.s and
-- src/field/encounter_effect_leaders.c route records.

local Assert = require("tests.support.Assert")
local Sources = require("romdump.src.config.BattlePresentationSources")

local T = {}

function T.legendary_camera_routes_publish_their_distinct_source_programs()
  local specialRoute = assert(Sources.TRANSITION_SELECTOR_ROUTES[34])
  Assert.notNil(specialRoute.task, "special legendary callback publishes its normalized source task")
  local sequence = specialRoute.task
  Assert.equal(sequence.kind, "field-camera-pose-sequence")
  local waits = {}
  for _, pose in ipairs(sequence.parameters.poses) do
    waits[#waits + 1] = pose.waitTicks
  end
  Assert.deepEqual(waits, { 4, 4, 4, 3, 3, 3, 3, 3, 3, 3, 2, 2, 1, 1, 1, 1 })
  Assert.deepEqual(sequence.parameters.poses[1], {
    distanceFx32 = 2731713,
    angleXRaw = 54786,
    angleYRaw = 0,
    perspectiveRaw = 1473,
    waitTicks = 4,
  })
  Assert.equal(sequence.parameters.fadeTicks, 10)

  local hoOh = assert(Sources.TRANSITION_SELECTOR_ROUTES[35]).task
  local lugia = assert(Sources.TRANSITION_SELECTOR_ROUTES[36]).task
  Assert.equal(hoOh.kind, "field-camera-perspective-distance-fade")
  Assert.equal(lugia.kind, "field-camera-perspective-distance-fade")
  Assert.equal(hoOh.parameters.perspectiveDeltaRaw, 0x100)
  Assert.equal(hoOh.parameters.perspectiveTicks, 40)
  Assert.equal(hoOh.parameters.waitTicks, 5)
  Assert.equal(hoOh.parameters.distanceDeltaFx32, -2703360)
  Assert.equal(lugia.parameters.distanceDeltaFx32, -2252800)
  Assert.equal(hoOh.parameters.distanceVelocityFx32, 2048)
  Assert.equal(hoOh.parameters.distanceTicks, 8)
  Assert.equal(hoOh.parameters.fadeTicks, 60)
  Assert.equal(lugia.parameters.fadeTicks, 13)
end

function T.overlay_115_routes_publish_their_complete_task_and_asset_groups()
  local gym = assert(Sources.TRANSITION_SELECTOR_ROUTES[12])
  Assert.equal(gym.task.kind, "overlay115-gym-rival-intro")
  Assert.equal(gym.task.parameters.endXFx32, 876544)
  Assert.deepEqual(gym.background, { palette = 21, character = 20, map = 22 })

  local rival = assert(Sources.TRANSITION_SELECTOR_ROUTES[28])
  Assert.equal(rival.task.kind, "overlay115-gym-rival-intro")
  Assert.equal(rival.task.parameters.endXFx32, 876544)
  Assert.deepEqual(rival.background, { palette = 45, character = 44, map = 46 })

  local will = assert(Sources.TRANSITION_SELECTOR_ROUTES[29])
  Assert.equal(will.task.kind, "overlay115-elite-intro")
  Assert.equal(will.task.parameters.shakeTicks, 32)
  Assert.deepEqual(will.opponent, { palette = 131, character = 132, cell = 133, animation = 134 })
  Assert.deepEqual(will.nameplate, { palette = 47, character = 48, cell = 49, animation = 50 })
  Assert.deepEqual(will.particles, { intro = 151, followup = 152 })

  local champion = assert(Sources.TRANSITION_SELECTOR_ROUTES[33])
  Assert.equal(champion.task.parameters.shakeTicks, 9)
  Assert.deepEqual(champion.opponent, { palette = 147, character = 148, cell = 149, animation = 150 })
  Assert.deepEqual(champion.nameplate, { palette = 54, character = 48, cell = 49, animation = 50 })
end

function T.overlay_115_route_assets_are_selected_with_their_native_resource_kinds()
  local function hasResource(selector, memberId, kind)
    for _, resource in ipairs(Sources.TRANSITION_TYPED_RESOURCES) do
      if resource.memberId == memberId and resource.kind == kind then
        for _, selected in ipairs(resource.selectors) do
          if selected == selector then
            return true
          end
        end
      end
    end
    return false
  end

  for _, resource in ipairs({
    { 63, "palette" },
    { 64, "texture" },
    { 65, "cell" },
    { 66, "animation" },
    { 21, "palette" },
    { 20, "texture" },
    { 22, "map" },
  }) do
    Assert.isTrue(hasResource(12, resource[1], resource[2]), "callback 12 closes a typed loader resource")
  end

  for _, resource in ipairs({
    { 207, "palette" },
    { 208, "texture" },
    { 209, "cell" },
    { 210, "animation" },
    { 131, "palette" },
    { 132, "texture" },
    { 133, "cell" },
    { 134, "animation" },
    { 47, "palette" },
    { 48, "texture" },
    { 49, "cell" },
    { 50, "animation" },
  }) do
    Assert.isTrue(hasResource(29, resource[1], resource[2]), "callback 29 closes a typed loader resource")
  end

  local particles = {}
  for _, memberId in ipairs(Sources.TRANSITION_PARTICLE_MEMBERS) do
    particles[memberId] = true
  end
  Assert.isTrue(particles[151] and particles[152], "Elite Four task particle members are inventoried")
end

return { tests = T }
