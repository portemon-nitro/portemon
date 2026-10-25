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

function T.factory_routes_fallback_and_rocket_and_red_roles_through_their_source_families()
  local function backgroundRoute(role, key)
    return {
      key = key,
      role = role,
      assetGroups = {
        sceneAssets = {
          palette = "bg-palette",
          characters = { "bg-character" },
          maps = { "bg-map" },
          transitionBackground = { palette = "bg-palette", character = "bg-character", map = "bg-map" },
        },
      },
    }
  end
  local backgroundResources = {
    ["bg-palette"] = { colors = {} },
    ["bg-character"] = { tiles = "" },
    ["bg-map"] = { tiles = {} },
  }
  local wild = TransitionFamilyFactory.new(
    backgroundRoute("plain-wild-fallback", "fallback/plain/day/wild"),
    backgroundResources,
    love.graphics,
    {},
    { kind = "wild", terrain = "plain", timeOfDay = "day" }
  )
  wild:start()
  wild:stepSourceTick()
  Assert.equal(wild:frame().family, "wild-fallback", "wild fallback routes run the window/mosaic worker")
  Assert.equal(wild:frame().polarity, 0x10, "day fallback routes carry the opening polarity")
  wild:dispose()

  local trainerWipe = TransitionFamilyFactory.new({
    key = "fallback/plain/day/trainer",
    role = "water-trainer-fallback",
    assetGroups = {
      sprite = {
        palette = "wipe-palette",
        character = "wipe-character",
        cell = "wipe-cell",
        animation = "wipe-animation",
      },
    },
  }, {
    ["wipe-palette"] = { colors = { { r = 0, g = 0, b = 0 }, { r = 240, g = 220, b = 40 } } },
    ["wipe-character"] = { depth = 3, tiles = string.rep(string.char(0x11), 32) },
    ["wipe-cell"] = {
      cells = { { objs = { { tile = 0, width = 8, height = 8, x = -4, y = -4, palette = 0 } } } },
    },
    ["wipe-animation"] = {
      anims = {
        {
          frames = { { cell = 0, duration = 1, translateX = 0, translateY = 0, scaleX = 1, scaleY = 1, rotation = 0 } },
        },
      },
    },
  }, love.graphics, {}, {})
  trainerWipe:start()
  trainerWipe:stepSourceTick()
  Assert.equal(trainerWipe:frame().family, "trainer-fallback", "trainer fallback routes run the affine worker")
  Assert.equal(#trainerWipe:frame().sprites, 2, "trainer fallback routes own two wipe sprites")
  trainerWipe:dispose()
end

function T.factory_routes_rocket_kimono_and_red_roles_through_their_source_families()
  local function gruntSet()
    return {
      ["grunt-palette"] = { colors = { { r = 0, g = 0, b = 0 }, { r = 250, g = 30, b = 20 } } },
      ["grunt-character"] = { depth = 3, tiles = string.rep(string.char(0x11), 32) },
      ["grunt-cell"] = {
        cells = { { objs = { { tile = 0, width = 8, height = 8, x = -4, y = -4, palette = 0 } } } },
      },
      ["grunt-animation"] = {
        anims = {
          {
            frames = {
              { cell = 0, duration = 1, translateX = 0, translateY = 0, scaleX = 1, scaleY = 1, rotation = 0 },
            },
          },
        },
      },
    }
  end
  local intro = TransitionFamilyFactory.new({
    key = "trainer/team-rocket",
    role = "trainer-transition",
    assetGroups = {
      sprite = {
        palette = "grunt-palette",
        character = "grunt-character",
        cell = "grunt-cell",
        animation = "grunt-animation",
      },
    },
  }, gruntSet(), love.graphics, {}, {})
  intro:start()
  intro:stepSourceTick()
  Assert.equal(intro:frame().shape, "intro", "sprite-only trainer routes run the rocket intro")
  intro:dispose()

  local kimono = TransitionFamilyFactory.new({
    key = "trainer/kimono-girl",
    role = "background-transition",
    assetGroups = {
      background = { palette = "kimono-palette", character = "kimono-character", map = "kimono-map" },
    },
  }, {
    ["kimono-palette"] = { colors = {} },
    ["kimono-character"] = { tiles = "" },
    ["kimono-map"] = { tiles = {} },
  }, love.graphics, {}, {})
  kimono:start()
  kimono:stepSourceTick()
  Assert.equal(kimono:frame().family, "kimono", "background routes run the pure scroll worker")
  Assert.isNil(kimono:frame().paletteFade, "background routes carry no fade layer")
  kimono:dispose()

  local red = TransitionFamilyFactory.new(
    {
      key = "trainer/red",
      role = "red-trainer-transition",
      assetGroups = {
        sprite = {
          palette = "grunt-palette",
          character = "grunt-character",
          cell = "grunt-cell",
          animation = "grunt-animation",
        },
        background = { palette = "kimono-palette", character = "kimono-character", map = "kimono-map" },
      },
    },
    (function()
      local resources = gruntSet()
      resources["kimono-palette"] = { colors = {} }
      resources["kimono-character"] = { tiles = "" }
      resources["kimono-map"] = { tiles = {} }
      return resources
    end)(),
    love.graphics,
    {},
    {}
  )
  red:start()
  red:stepSourceTick()
  Assert.equal(red:frame().family, "red", "Red routes run the window and sprite intro")
  red:dispose()
end

function T.factory_fails_closed_for_roles_without_an_installed_source_family()
  local route, resources = gymFixture()
  route.role = "unknown-transition-role"
  local ok = pcall(function()
    TransitionFamilyFactory.new(route, resources, love.graphics, {}, { playerGender = "male" })
  end)
  Assert.equal(ok, false, "uninstalled roles have no silent fallback")
  local tasked, taskedResources = gymFixture()
  tasked.key = "trainer/scout"
  tasked.task = { kind = "overlay-unknown-probe" }
  local taskOk = pcall(function()
    TransitionFamilyFactory.new(tasked, taskedResources, love.graphics, {}, { playerGender = "male" })
  end)
  Assert.equal(taskOk, false, "trainer routes with an unknown intro task stay uninstalled")
end

return { tests = T }
