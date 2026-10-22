local Assert = require("tests.support.Assert")
local Overlay115Effect = require("libs.hgss.src.transition.battle.Overlay115Effect")

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
  resources["particle-intro"] = { format = "APS12_1", emitters = { {}, {}, {} }, resources = {} }
  resources["particle-followup"] = { format = "APS12_1", emitters = { {}, {}, {}, {} }, resources = {} }
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
    effect:frame().particleSystem.emitters[1].resourceIndex,
    0,
    "particle emitters preserve source resource indices"
  )
  effect:dispose()
  Assert.equal(effect._particles.resource, nil, "failure or cancellation releases the owned APS record")
  Assert.equal(effect._particles.resourceFrees, 1, "particle resource cleanup is exactly once")
  Assert.equal(effect._particles.mode, false, "particle mode is ended during cleanup")
end

function T.unknown_tasks_and_invalid_particle_payloads_fail_closed()
  local route, resources = gymFixture()
  route.task.kind = "unrecognized-overlay115-task"
  local ok = pcall(Overlay115Effect.new, route, resources)
  Assert.equal(ok, false, "unknown normalized callback task is rejected")

  route, resources = eliteFixture(32)
  resources["particle-intro"].format = "unknown"
  ok = pcall(Overlay115Effect.new, route, resources, { playerGender = "male" })
  Assert.equal(ok, false, "elite route rejects particle data outside the decoded APS contract")
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
