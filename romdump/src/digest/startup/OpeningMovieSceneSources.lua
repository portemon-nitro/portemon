-- Compile-time source declarations for the five HGSS opening-movie scenes.
-- Authority: retail src/intro_movie.c (scene order, skip gate ownership),
-- src/intro_movie_scene_1..5.c (per-scene resource loads, state machines,
-- and effect timings at the source 30Hz tick), and
-- src/intro_movie_scene_4.c sStarterParticleResIds (starter emitter sets).
-- No NARC identifiers, ROM paths, or Lua callbacks cross into the runtime
-- manifest; edition branches resolve here, producer-side, into distinct
-- versioned records. Timings below are the source state thresholds and
-- effect lengths, not a master linear storyboard: parallel source effects
-- compose through waitEffects, and atTick composes state durations with
-- named effect lengths.

local OpeningMovieSceneSources = {}

OpeningMovieSceneSources.SCHEMA = "g4-startup-opening-scene-v2"
OpeningMovieSceneSources.TICK_RATE = 30
OpeningMovieSceneSources.ARCHIVE = "NARC_demo_opening_gs_opening"
OpeningMovieSceneSources.PARTICLE_ARCHIVE = "NARC_a_0_5_9"
OpeningMovieSceneSources.PARTICLE_MEMBER = 4

local EDITIONS = { heartgold = true, soulsilver = true }

---@param versionId string
local function checkEdition(versionId)
  assert(EDITIONS[versionId], "opening scene edition must be heartgold or soulsilver")
end

---@param sceneNumber integer
local function checkScene(sceneNumber)
  assert(
    type(sceneNumber) == "number" and sceneNumber % 1 == 0 and sceneNumber >= 1 and sceneNumber <= 5,
    "opening scene number must be an integer 1..5"
  )
end

-- Background triples transcribe the retail LoadCharData/LoadScrnData/GXLoadPal
-- calls: which character and screen members render on each engine and BG
-- slot, and which palette member each engine reads. Screens that share an
-- engine with their group character render through it: copyright screens
-- through the copyright characters, sunrise screens through the sunrise
-- characters, and each scene's panorama screens through that scene's
-- panorama characters. Tilemap-swapped panels (scene 3 rival/beast sections)
-- render through the sub-engine character the source keeps resident for that
-- visual group, recorded here as alternates on their slot: the base triple
-- plus every swapped screen the scene shows on the same slot.
-- bgSlot is the numeric source background plane 0..3; priority mirrors the
-- authored source plane order, so a lower plane composites above a higher
-- one, matching the hardware default the scenes rely on.
---@param versionId string
---@param sceneNumber integer
---@return table<string, unknown>[] background declarations
function OpeningMovieSceneSources.backgrounds(versionId, sceneNumber)
  checkEdition(versionId)
  checkScene(sceneNumber)
  local heartgold = versionId == "heartgold"
  if sceneNumber == 1 then
    local paletteSub = heartgold and 0 or 2
    local paletteMain = heartgold and 1 or 3
    local charSub = heartgold and 6 or 8
    local charMain = heartgold and 7 or 9
    local screensSub = heartgold and { 15 } or { 19 }
    local screensMain = heartgold and { 16, 17, 18 } or { 20, 21, 22 }
    local layers = {
      { engine = "sub", bgSlot = 1, priority = 1, char = 4, screen = 12, palette = paletteSub },
      { engine = "sub", bgSlot = 0, priority = 0, char = 4, screen = 14, palette = paletteSub },
      { engine = "main", bgSlot = 0, priority = 0, char = 5, screen = 13, palette = paletteMain },
    }
    for _, screen in ipairs(screensSub) do
      layers[#layers + 1] =
        { engine = "sub", bgSlot = 3, priority = 3, char = charSub, screen = screen, palette = paletteSub }
    end
    for index, screen in ipairs(screensMain) do
      local slots = { 3, 2, 1 }
      layers[#layers + 1] = {
        engine = "main",
        bgSlot = slots[index],
        priority = slots[index],
        char = charMain,
        screen = screen,
        palette = paletteMain,
      }
    end
    return layers
  elseif sceneNumber == 2 then
    return {
      { engine = "main", bgSlot = 2, priority = 2, char = 33, screen = 35, palette = 32 },
      { engine = "main", bgSlot = 1, priority = 1, char = 33, screen = 37, palette = 32 },
      { engine = "main", bgSlot = 0, priority = 0, char = 33, screen = 38, palette = 32 },
      { engine = "sub", bgSlot = 0, priority = 0, char = 34, screen = 36, palette = 31 },
    }
  elseif sceneNumber == 3 then
    return {
      {
        engine = "sub",
        bgSlot = 0,
        priority = 0,
        char = 40,
        screen = 42,
        palette = 39,
        alternates = {
          { char = 40, screen = 43 },
          { char = 40, screen = 44 },
          { char = 40, screen = 45 },
          { char = 40, screen = 47 },
        },
      },
      {
        engine = "sub",
        bgSlot = 3,
        priority = 3,
        char = 40,
        screen = 46,
        palette = 39,
        alternates = { { char = 41, screen = 52 } },
      },
      {
        engine = "sub",
        bgSlot = 1,
        priority = 1,
        char = 40,
        screen = 48,
        palette = 39,
        alternates = { { char = 41, screen = 50 } },
      },
      {
        engine = "sub",
        bgSlot = 2,
        priority = 2,
        char = 40,
        screen = 49,
        palette = 39,
        alternates = { { char = 41, screen = 51 } },
      },
    }
  elseif sceneNumber == 4 then
    return {
      { engine = "main", bgSlot = 1, priority = 1, char = 54, screen = 58, palette = 53 },
      { engine = "main", bgSlot = 2, priority = 2, char = 54, screen = 55, palette = 53 },
      { engine = "main", bgSlot = 3, priority = 3, char = 54, screen = 56, palette = 53 },
      { engine = "sub", bgSlot = 1, priority = 1, char = 54, screen = 57, palette = 53 },
      { engine = "sub", bgSlot = 2, priority = 2, char = 54, screen = 55, palette = 53 },
      { engine = "sub", bgSlot = 3, priority = 3, char = 54, screen = 56, palette = 53 },
    }
  end
  return {
    { engine = "sub", bgSlot = 1, priority = 1, char = 59, screen = 63, palette = 39 },
    { engine = "sub", bgSlot = 2, priority = 2, char = 59, screen = 61, palette = 39 },
    { engine = "main", bgSlot = 1, priority = 1, char = 60, screen = 62, palette = 31 },
    { engine = "main", bgSlot = 2, priority = 2, char = 60, screen = 64, palette = 31 },
  }
end

-- Object banks transcribe the retail AddChar/Pltt/Cell/AnimResObjFromNarc
-- calls: palette, character, animation, and cell members per sprite set,
-- plus the animation sequences the source sprite creation selects. Only
-- the played sequences compile; spares never stage.
---@param versionId string
---@param sceneNumber integer
---@return table<string, unknown>[] object bank declarations
function OpeningMovieSceneSources.objects(versionId, sceneNumber)
  checkEdition(versionId)
  checkScene(sceneNumber)
  local heartgold = versionId == "heartgold"
  if sceneNumber == 1 then
    local bank = heartgold and { palette = 23, char = 24, animation = 25, cell = 26 }
      or { palette = 27, char = 28, animation = 29, cell = 30 }
    bank.name = "bird"
    bank.sequences = { 0, 1 }
    return { bank }
  elseif sceneNumber == 2 then
    return {
      { name = "flowers", palette = 77, char = 78, animation = 79, cell = 80, sequences = { 0, 1, 2, 3 } },
      { name = "characters", palette = 73, char = 74, animation = 75, cell = 76, sequences = { 0, 1, 2, 3, 4, 5 } },
    }
  elseif sceneNumber == 3 then
    return {
      { name = "silver", palette = 65, char = 66, animation = 67, cell = 68, sequences = { 0 } },
      { name = "eusine", palette = 69, char = 70, animation = 71, cell = 72, sequences = { 0, 1, 2, 3 } },
    }
  elseif sceneNumber == 4 then
    return {
      { name = "hands", palette = 81, char = 82, animation = 83, cell = 84, sequences = { 0, 1, 2 } },
      {
        name = "chikorita",
        speciesId = 152,
        palette = 85,
        char = 86,
        animation = 87,
        cell = 88,
        sequences = { 0 },
      },
      {
        name = "totodile",
        speciesId = 158,
        palette = 89,
        char = 90,
        animation = 91,
        cell = 92,
        sequences = { 0 },
      },
      {
        name = "cyndaquil",
        speciesId = 155,
        palette = 93,
        char = 94,
        animation = 95,
        cell = 96,
        sequences = { 0 },
      },
    }
  end
  return {}
end

-- Sprite instance stations transcribed from the retail CreateSprites
-- functions: scene 1 sun and bird share (128, 96) on the main engine
-- (src/intro_movie_scene_1.c IntroMovie_Scene1_CreateSprites);
-- scene 2 holds ten flowers at (128, 192), three ethan at (64, -96),
-- and three lyra at (320, -96), all with sprite animation inactive on
-- creation (src/intro_movie_scene_2.c IntroMovie_Scene2_CreateSprites);
-- scene 3 holds silver at (128, 608), eusine at (32, 608), and unowns
-- at (128, 544/672/608), all offscreen (src/intro_movie_scene_3.c
-- IntroMovie_Scene3_CreateSprites); scene 4 holds hand1 at (128, 352)
-- with hand2, sparkles, and all three starters at (128, 96)
-- (src/intro_movie_scene_4.c IntroMovie_Scene4_CreateSprites); scene 5
-- creates no sprites. Engine follows the creation VRAM type
-- (2DMAIN main, 2DSUB sub); flowers carry one instance per engine
-- because their character data loads as 2DBOTH, the scene enables
-- sprite pixels on both engines, and the renderer draws every sprite to
-- every active engine surface, so one single-engine instance cannot
-- cover both displayed copies. Neither retail Main moves its sprites:
-- scenes 1, 3, and 4 change only animation and visibility, and only
-- scene 2 pans its six heroes (flowers stay fixed).
---@param sceneNumber integer
---@return table<string, unknown>[] sprite instance declarations
function OpeningMovieSceneSources.spriteInstances(sceneNumber)
  checkScene(sceneNumber)
  if sceneNumber == 1 then
    return {
      { id = "sun", sprite = "sun", engine = "main", x = 128, y = 96, drawOrder = 1 },
      { id = "bird", sprite = "bird", engine = "main", x = 128, y = 96, drawOrder = 2 },
    }
  elseif sceneNumber == 2 then
    local instances = {}
    for flower = 1, 10 do
      instances[#instances + 1] = {
        id = "flower" .. flower .. "-main",
        sprite = "flower",
        engine = "main",
        x = 128,
        y = 192,
        drawOrder = flower,
      }
      instances[#instances + 1] = {
        id = "flower" .. flower .. "-sub",
        sprite = "flower",
        engine = "sub",
        x = 128,
        y = 192,
        drawOrder = flower,
      }
    end
    for hero = 0, 2 do
      instances[#instances + 1] = {
        id = "ethan" .. hero,
        sprite = "ethan",
        engine = "main",
        x = 64,
        y = -96,
        drawOrder = 11 + hero,
      }
      instances[#instances + 1] = {
        id = "lyra" .. hero,
        sprite = "lyra",
        engine = "main",
        x = 320,
        y = -96,
        drawOrder = 14 + hero,
      }
    end
    return instances
  elseif sceneNumber == 3 then
    return {
      { id = "eusine", sprite = "eusine", engine = "sub", x = 32, y = 608, drawOrder = 1 },
      { id = "unown0", sprite = "unown0", engine = "sub", x = 128, y = 544, drawOrder = 2 },
      { id = "unown1", sprite = "unown1", engine = "sub", x = 128, y = 672, drawOrder = 3 },
      { id = "unown2", sprite = "unown2", engine = "sub", x = 128, y = 608, drawOrder = 4 },
      { id = "silver-silhouette", sprite = "silver-silhouette", engine = "sub", x = 128, y = 608, drawOrder = 5 },
    }
  elseif sceneNumber == 4 then
    return {
      { id = "hand1", sprite = "hand1", engine = "sub", x = 128, y = 352, drawOrder = 1 },
      { id = "hand2", sprite = "hand2", engine = "main", x = 128, y = 96, drawOrder = 1 },
      { id = "chikorita", sprite = "chikorita", engine = "main", x = 128, y = 96, drawOrder = 2 },
      { id = "cyndaquil", sprite = "cyndaquil", engine = "main", x = 128, y = 96, drawOrder = 2 },
      { id = "totodile", sprite = "totodile", engine = "main", x = 128, y = 96, drawOrder = 2 },
      { id = "sparkles", sprite = "sparkles", engine = "main", x = 128, y = 96, drawOrder = 3 },
    }
  end
  return {}
end

-- Retail 3D town set behind scene 3: New Bark Town, Goldenrod City, then
-- Ecruteak City, each with its model and two animation members. The camera
-- is the single sCameraParam set plus the retail perspective angle; light
-- and material tables are per town in map order.
---@return table<string, unknown>
function OpeningMovieSceneSources.townSet()
  return {
    models = {
      { name = "new-bark-town", model = 103, clips = { 104, 105 } },
      { name = "goldenrod-city", model = 100, clips = { 101, 102 } },
      { name = "ecruteak-city", model = 97, clips = { 98, 99 } },
    },
    camera = {
      distance = 410.922119140625,
      angle = { 0xD602, 0x0000, 0x0000, 0 },
      perspective = 0,
      perspectiveType = 0x05C1,
      target = { 0, 0, 96 },
      fovAngle = 0x981,
    },
    edgeColors = {
      { r = 0, g = 0, b = 0 },
      { r = 4 / 31, g = 4 / 31, b = 4 / 31 },
      { r = 4 / 31, g = 4 / 31, b = 4 / 31 },
      { r = 4 / 31, g = 4 / 31, b = 4 / 31 },
      { r = 4 / 31, g = 4 / 31, b = 4 / 31 },
      { r = 4 / 31, g = 4 / 31, b = 4 / 31 },
      { r = 4 / 31, g = 4 / 31, b = 4 / 31 },
      { r = 4 / 31, g = 4 / 31, b = 4 / 31 },
    },
    lighting = {
      {
        vectors = {
          { x = -0.46923828125, y = -0.8662109375, z = -0.072265625 },
          { x = 0, y = 0, z = 0 },
          { x = 0, y = 0, z = 1 },
          { x = 0, y = 0, z = 1 },
        },
        colors = {
          { r = 22 / 31, g = 22 / 31, b = 20 / 31 },
          { r = 0, g = 0, b = 0 },
          { r = 0, g = 4 / 31, b = 9 / 31 },
          { r = 0, g = 0, b = 0 },
        },
        diffuse = { r = 15 / 31, g = 15 / 31, b = 15 / 31 },
        ambient = { r = 9 / 31, g = 11 / 31, b = 11 / 31 },
        specular = { r = 16 / 31, g = 16 / 31, b = 16 / 31 },
        emission = { r = 14 / 31, g = 14 / 31, b = 14 / 31 },
      },
      {
        vectors = {
          { x = -0.46728515625, y = -0.8662109375, z = -0.072265625 },
          { x = 0, y = 0, z = 0 },
          { x = 0, y = 0, z = 1 },
          { x = 0, y = 0, z = 1 },
        },
        colors = {
          { r = 11 / 31, g = 11 / 31, b = 16 / 31 },
          { r = 0, g = 0, b = 0 },
          { r = 18 / 31, g = 10 / 31, b = 0 },
          { r = 0, g = 0, b = 0 },
        },
        diffuse = { r = 14 / 31, g = 14 / 31, b = 16 / 31 },
        ambient = { r = 10 / 31, g = 10 / 31, b = 10 / 31 },
        specular = { r = 14 / 31, g = 14 / 31, b = 16 / 31 },
        emission = { r = 8 / 31, g = 8 / 31, b = 11 / 31 },
      },
      {
        vectors = {
          { x = -0.46728515625, y = -0.8662109375, z = -0.072265625 },
          { x = 0, y = 0, z = 0 },
          { x = 0, y = 0, z = 1 },
          { x = 0, y = 0, z = 1 },
        },
        colors = {
          { r = 19 / 31, g = 16 / 31, b = 12 / 31 },
          { r = 0, g = 0, b = 0 },
          { r = 16 / 31, g = 6 / 31, b = 0 },
          { r = 0, g = 0, b = 0 },
        },
        diffuse = { r = 15 / 31, g = 15 / 31, b = 15 / 31 },
        ambient = { r = 11 / 31, g = 12 / 31, b = 12 / 31 },
        specular = { r = 17 / 31, g = 17 / 31, b = 17 / 31 },
        emission = { r = 8 / 31, g = 8 / 31, b = 7 / 31 },
      },
    },
  }
end

-- Starter species behind scene 4 (Chikorita 152, Cyndaquil 155, Totodile 158).
---@param starter string
---@return integer species id
function OpeningMovieSceneSources.starterSpecies(starter)
  if starter == "chikorita" then
    return 152
  elseif starter == "cyndaquil" then
    return 155
  elseif starter == "totodile" then
    return 158
  end
  error("opening scene starter must be chikorita, cyndaquil, or totodile: " .. tostring(starter), 0)
end

-- Starter emitter sets behind scene 4: retail sStarterParticleResIds rows in
-- starter order (Chikorita, Cyndaquil, Totodile).
---@return table<string, unknown>[]
function OpeningMovieSceneSources.starterEmitters()
  return {
    { starter = "chikorita", speciesId = 152, group = "grass", emitters = { 6, 7, 8 } },
    { starter = "cyndaquil", speciesId = 155, group = "fire", emitters = { 3, 4, 5 } },
    { starter = "totodile", speciesId = 158, group = "water", emitters = { 0, 1, 2 } },
  }
end

-- Edition scroll direction behind scene 5: BG_SCROLL_SPEED is -0x40 on
-- HeartGold and +0x40 on SoulSilver for the lower pair and MAIN_2, while
-- MAIN_1 always scrolls -0x40.
---@param versionId string
---@return string scroll direction for the edition-conditioned layers
function OpeningMovieSceneSources.scene5ScrollDirection(versionId)
  checkEdition(versionId)
  if versionId == "heartgold" then
    return "left"
  end
  return "right"
end

-- Scene member inventory: every source member the producer reads for one
-- scene, so the compiler decodes only its own member set and the job
-- receipt hashes exactly the selected source bytes.
---@param versionId string
---@param sceneNumber integer
---@return integer[] sorted source member ids
function OpeningMovieSceneSources.memberSet(versionId, sceneNumber)
  checkEdition(versionId)
  checkScene(sceneNumber)
  local members = {}
  local function add(memberId)
    members[#members + 1] = memberId
  end
  for _, background in ipairs(OpeningMovieSceneSources.backgrounds(versionId, sceneNumber)) do
    add(background.char)
    add(background.screen)
    add(background.palette)
    if type(background.alternates) == "table" then
      for _, alternate in ipairs(background.alternates) do
        add(alternate.char)
        add(alternate.screen)
      end
    end
  end
  for _, bank in ipairs(OpeningMovieSceneSources.objects(versionId, sceneNumber)) do
    add(bank.palette)
    add(bank.char)
    add(bank.animation)
    add(bank.cell)
  end
  if sceneNumber == 3 then
    for _, model in ipairs(OpeningMovieSceneSources.townSet().models) do
      add(model.model)
      for _, clip in ipairs(model.clips) do
        add(clip)
      end
    end
  end
  table.sort(members)
  local unique = {}
  for _, memberId in ipairs(members) do
    if unique[#unique] ~= memberId then
      unique[#unique + 1] = memberId
    end
  end
  return unique
end

return OpeningMovieSceneSources
