-- Routes installed transition roles through the production family factory.

local Assert = require("tests.support.Assert")
local TransitionFamilyFactory = require("libs.hgss.src.transition.TransitionFamilyFactory")

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

function T.factory_routes_gym_trainer_callbacks_through_the_native_intro_task()
  local route, resources = gymFixture()
  local effect = TransitionFamilyFactory.new(route, resources, love.graphics, {}, { playerGender = "male" })
  effect:start()
  Assert.equal(effect:stepSourceTick(), false, "native state zero initializes the gym runner")
  Assert.equal(effect:frame().sourcePhase, 1, "factory-built gym runner enters its flash-start state")
  Assert.equal(#effect:frame().sprites, 5, "factory-built gym runner owns the trainer and scale sprites")
  while not effect:stepSourceTick() do
  end
  Assert.equal(effect:frame().sourcePhase, 15, "factory-built gym route terminates in its cleanup state")
  Assert.equal(#effect:frame().sprites, 0, "terminal cleanup releases the leader sprites")
  effect:dispose()
end

function T.factory_routes_elite_callbacks_with_the_captured_trainer_gender()
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
    task = { kind = "overlay115-elite-intro", parameters = { shakeTicks = 9 } },
    messages = { "transition/trainer-name" },
    assetGroups = {
      spriteVariants = { male = resources.male, female = resources.female },
      opponent = resources.opponent,
      nameplate = resources.nameplate,
      fixedSprite = resources.star,
      particles = { intro = "particle-intro", followup = "particle-followup" },
    },
  }
  local effect = TransitionFamilyFactory.new(route, resources, love.graphics, {}, { playerGender = "female" })
  effect:start()
  effect:stepSourceTick()
  effect:stepSourceTick()
  Assert.equal(
    effect:frame().sprites[1].sourceRoute,
    route.key,
    "factory-built elite route retains its selected identity"
  )
  effect:dispose()
  local ok = pcall(function()
    local missing = TransitionFamilyFactory.new(route, resources, love.graphics, {}, {})
    missing:dispose()
  end)
  Assert.equal(ok, false, "elite intro without captured gender fails closed")
end

function T.factory_fails_closed_for_roles_without_an_installed_source_family()
  local route, resources = gymFixture()
  for _, role in ipairs({
    "red-trainer-transition",
    "background-transition",
    "plain-wild-fallback",
  }) do
    route.role = role
    local ok = pcall(function()
      TransitionFamilyFactory.new(route, resources, love.graphics, {}, { playerGender = "male" })
    end)
    Assert.equal(ok, false, "uninstalled role " .. role .. " has no silent fallback")
  end
  local taskless, tasklessResources = gymFixture()
  taskless.key = "trainer/team-rocket"
  taskless.task = nil
  local taskOk = pcall(function()
    TransitionFamilyFactory.new(taskless, tasklessResources, love.graphics, {}, { playerGender = "male" })
  end)
  Assert.equal(taskOk, false, "trainer routes without an overlay 115 task stay uninstalled")
end

return { tests = T }
