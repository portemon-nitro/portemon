local Assert = require("tests.support.Assert")
local Overlay115Effect = require("libs.hgss.src.transition.battle.Overlay115Effect")
local TransitionParticlesFixture = require("tests.support.TransitionParticlesFixture")

local T = {}

local function spriteResource(prefix)
  return {
    [prefix .. "-palette"] = { colors = { { r = 0, g = 0, b = 0 }, { r = 240, g = 220, b = 40 } } },
    [prefix .. "-character"] = { depth = 3, tiles = string.rep(string.char(0x11), 32) },
    [prefix .. "-cell"] = {
      cells = { { objs = { { tile = 0, width = 8, height = 8, x = -4, y = -4, palette = 0 } } } },
    },
    [prefix .. "-animation"] = {
      anims = {
        {
          frames = { { cell = 0, duration = 1, translateX = 0, translateY = 0, scaleX = 1, scaleY = 1, rotation = 0 } },
        },
        {
          frames = { { cell = 0, duration = 2, translateX = 0, translateY = 0, scaleX = 1, scaleY = 1, rotation = 0 } },
        },
      },
    },
  }
end

local function spriteGroup(prefix)
  return {
    palette = prefix .. "-palette",
    character = prefix .. "-character",
    cell = prefix .. "-cell",
    animation = prefix .. "-animation",
  }
end

local function gymFixture()
  local resources = spriteResource("leader")
  for key, value in pairs(spriteResource("star")) do
    resources[key] = value
  end
  resources["bg-palette"] = { colors = {} }
  resources["bg-character"] = { tiles = "" }
  resources["bg-map"] = { tiles = {} }
  local route = {
    key = "trainer/falkner",
    role = "trainer-transition",
    task = { kind = "overlay115-gym-rival-intro", parameters = { endXFx32 = 214 * 4096 } },
    messages = { "transition/trainer-name" },
    assetGroups = {
      record = spriteGroup("leader"),
      fixedSprite = spriteGroup("star"),
      background = { palette = "bg-palette", character = "bg-character", map = "bg-map" },
    },
  }
  return route, resources
end

local function eliteFixture(shakeTicks)
  local resources = {}
  for prefix, group in pairs({
    male = "player-male",
    female = "player-female",
    opponent = "opponent",
    nameplate = "nameplate",
    star = "star",
  }) do
    for key, value in pairs(spriteResource(group)) do
      resources[key] = value
    end
    resources[prefix] = spriteGroup(group)
  end
  resources["particle-intro"], resources["particle-followup"] = TransitionParticlesFixture.pair()
  local route = {
    key = "trainer/lance",
    role = "trainer-intro",
    task = { kind = "overlay115-elite-intro", parameters = { shakeTicks = shakeTicks } },
    messages = { "transition/trainer-name" },
    assetGroups = {
      spriteVariants = { male = resources.male, female = resources.female },
      opponent = resources.opponent,
      nameplate = resources.nameplate,
      fixedSprite = resources.star,
      particles = { intro = "particle-intro", followup = "particle-followup" },
    },
  }
  return route, resources
end

function T.gym_and_rival_routes_use_the_source_intro_schedule_and_release_route_art()
  local route, resources = gymFixture()
  local effect = Overlay115Effect.new(route, resources)
  effect:start()
  Assert.equal(effect:stepSourceTick(), false, "native state zero initializes the gym runner")
  Assert.equal(effect:frame().sourcePhase, 1, "gym runner enters its flash-start state")
  Assert.equal(#effect:frame().sprites, 5, "gym runner owns one trainer and four scale sprites")
  Assert.equal(effect:frame().sprites[1].position.x, 272 * 4096, "trainer starts at native X=272")
  Assert.equal(effect:frame().sprites[1].position.y, 66 * 4096, "trainer starts at native Y=66")
  Assert.equal(effect:frame().sprites[1].visible, false, "trainer remains hidden before the reveal task")
  Assert.equal(effect:stepSourceTick(), false, "flash starts on its own native state")
  Assert.equal(effect:frame().sourcePhase, 2, "flash completion is awaited in state two")

  local flashTicks = 0
  while effect:frame().sourcePhase == 2 do
    effect:stepSourceTick()
    flashTicks = flashTicks + 1
  end
  Assert.equal(flashTicks, 12, "the paired source flash task reaches its completion flag")
  Assert.equal(effect:frame().sourcePhase, 3, "completed flash permits background and wipe initialization")
  effect:stepSourceTick()
  local wipe = effect:frame().wipe
  Assert.equal(wipe.duration, 6, "gym route starts the six-update native edge interpolation")
  Assert.equal(wipe.period, 8, "gym route retains the source zigzag scanline period")
  Assert.equal(wipe.rows[1][1][2], 256, "zigzag window includes the native right edge")
  Assert.equal(
    effect:frame().background.group,
    route.assetGroups.background,
    "route-specific background stays attached"
  )

  while not effect:stepSourceTick() do
  end
  Assert.equal(effect:frame().sourcePhase, 15, "gym route terminates only in its cleanup state")
  Assert.equal(#effect:frame().sprites, 0, "terminal cleanup releases the leader and scale sprites")
  Assert.equal(effect:frame().ownsResources, nil, "released resources are not advertised as live")
end

function T.elite_routes_keep_gender_art_and_own_native_particle_setup()
  local route, resources = eliteFixture(9)
  local effect = Overlay115Effect.new(route, resources, { playerGender = "female" })
  effect:start()
  effect:stepSourceTick()
  effect:stepSourceTick()
  Assert.equal(effect:frame().sprites[1].sourceRoute, route.key, "elite route retains its selected identity")
  Assert.equal(effect:frame().sprites[1].name, "player", "first primary sprite is the source-selected player")
  effect:stepSourceTick()
  local ticks = 0
  while effect:frame().sourcePhase == 3 do
    effect:stepSourceTick()
    ticks = ticks + 1
  end
  Assert.equal(ticks, 12, "elite flash wait remains independent from particle setup")
  Assert.equal(effect:frame().sourcePhase, 4, "elite source waits for particle setup after flash")
  effect:stepSourceTick()
  Assert.equal(effect:frame().sourcePhase, 5, "elite route advances after VWait and main-queue setup tasks")
  Assert.equal(effect:frame().particleSystem.resource, "intro", "the declared intro particle group is owned")

  local guard = 0
  while effect:frame().sourcePhase ~= 7 and guard < 500 do
    guard = guard + 1
    effect:stepSourceTick()
  end
  Assert.equal(effect:frame().sourcePhase, 7, "elite source waits while source emitters are active")
  Assert.equal(
    effect:frame().particleSystem.simulation.emitters[1].id,
    0,
    "particle emitters preserve source resource indices"
  )
  effect:dispose()
  Assert.equal(effect._particles.resource, nil, "failure or cancellation releases the owned particle set")
  Assert.equal(effect._particles.resourceFrees, 1, "particle resource cleanup is exactly once")
  Assert.equal(effect._particles.mode, false, "particle mode is ended during cleanup")
end

-- EncounterEffect_LoadParticles / CreateEmitters / UpdateParticles /
-- AreParticlesDone / FreeParticles: each member is a fresh system whose
-- emitters appear on their source tick, simulate in states 5 through 13, and
-- leave through completion rather than a timer.
function T.elite_particle_systems_follow_the_source_load_create_free_sequence()
  local route, resources = eliteFixture(9)
  local effect = Overlay115Effect.new(route, resources, { playerGender = "male" })
  effect:prepareGraphics(love.graphics)
  effect:start()
  local function particleSystem()
    return effect:frame().particleSystem
  end
  local function stepUntil(done)
    for _ = 1, 500 do
      if done() then
        return
      end
      effect:stepSourceTick()
    end
    error("the intro did not reach the awaited source state, stuck in " .. tostring(effect:frame().sourcePhase))
  end

  stepUntil(function()
    return effect:frame().sourcePhase == 5
  end)
  Assert.equal(#particleSystem().simulation.emitters, 0, "loading a member creates no emitter")
  Assert.isNil(particleSystem().draw, "the 3D layer stays hidden until its source tick")

  local ticks = 0
  while #particleSystem().simulation.emitters == 0 do
    effect:stepSourceTick()
    ticks = ticks + 1
  end
  Assert.equal(ticks, 4, "the intro emitters appear after the source's three-tick counter")
  Assert.equal(#particleSystem().simulation.emitters, 3, "the intro creates emitters 0 through 2")
  Assert.isTrue(particleSystem().draw.aboveSprites, "the intro layer outranks the priority-one sprites")
  Assert.isTrue(particleSystem().draw.textures[0] ~= nil, "the layer draws the member's uploaded textures")
  effect:stepSourceTick()
  local livingParticles = 0
  for _, runtime in ipairs(particleSystem().simulation.emitters) do
    livingParticles = livingParticles + #runtime.particles
  end
  Assert.isTrue(livingParticles > 0, "created emitters simulate on the ticks that follow")

  local firstSimulation = particleSystem().simulation
  local lastPhaseSevenEmitters
  while effect:frame().sourcePhase < 8 do
    if effect:frame().sourcePhase == 7 then
      lastPhaseSevenEmitters = #firstSimulation.emitters
    end
    effect:stepSourceTick()
  end
  Assert.equal(lastPhaseSevenEmitters, 0, "the intro leaves its wait only once every emitter retired")
  Assert.isNil(particleSystem().simulation, "completion frees the intro system")
  Assert.equal(particleSystem().resourceFrees, 1, "the intro system is freed exactly once")

  stepUntil(function()
    return effect:frame().sourcePhase == 10
  end)
  Assert.equal(particleSystem().resource, "followup", "the second member loads after the brightness ramp")
  Assert.equal(particleSystem().resourceLoads, 2, "each member loads exactly once")
  Assert.isTrue(particleSystem().simulation ~= firstSimulation, "the follow-up is a fresh system")
  Assert.equal(#particleSystem().simulation.emitters, 4, "the follow-up creates emitters 0 through 3")
  Assert.isFalse(particleSystem().draw.aboveSprites, "the follow-up layer drops to the sprites' priority")

  stepUntil(function()
    return effect.complete
  end)
  Assert.isNil(particleSystem().simulation, "the intro ends with no live particle system")
  Assert.equal(particleSystem().resourceFrees, 2, "the follow-up system is freed exactly once")
  Assert.isNil(effect._particleImages, "particle textures release with the task")
  effect:dispose()
  Assert.equal(effect._particles.resourceFrees, 2, "disposal after completion frees nothing twice")
end

function T.unknown_tasks_and_invalid_particle_payloads_fail_closed()
  local route, resources = gymFixture()
  route.task.kind = "unrecognized-overlay115-task"
  local ok = pcall(Overlay115Effect.new, route, resources)
  Assert.equal(ok, false, "unknown normalized callback task is rejected")

  route, resources = eliteFixture(32)
  resources["particle-intro"].emitters[3] = nil
  ok = pcall(Overlay115Effect.new, route, resources, { playerGender = "male" })
  Assert.equal(ok, false, "elite route rejects a particle set missing an emitter the intro creates")
end

function T.gym_route_uploads_native_sprite_cells_before_start()
  local route, resources = gymFixture()
  local effect = Overlay115Effect.new(route, resources)
  effect:prepareGraphics(love.graphics)
  Assert.equal(effect.started, false, "sprite upload precedes callback start")
  Assert.equal(#effect.imageHandles, 3, "distinct route sprite cells and animation sequences are uploaded once each")
  Assert.equal(effect.sprites[1].imageHandle, effect.imageHandles[1], "trainer sprite receives the uploaded cell")
  effect:dispose()
  Assert.equal(#effect.imageHandles, 0, "disposal releases transition-owned GPU images")
end

return { tests = T }
