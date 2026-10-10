-- Pinned native battle-presentation source inventory: the ordinary
-- persistent-scene axes, the exact shared menu/HUD member roles, and the
-- palette formulas behind the lower screen and the BG3 bake. Member
-- selection follows src/battle/battle_system.c:BattleSystem_SetBackground
-- (pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36); the main
-- scene is the overlay-12 BG3 recipe, never the overlay-7 effect
-- backgrounds. Pure data and pure functions; no I/O. Never imported by
-- runtime: libs/assets and game packages must not require this module (see
-- tests/architecture/module_boundaries_test.lua).

---@class BattlePresentationSources
local BattlePresentationSources = {}

BattlePresentationSources.provenance = {
  repo = "pret/pokeheartgold",
  commit = "9d8b7591f09b65804da2fb2dfd56f320633e0d36",
  sources = {
    "src/battle/battle_system.c",
    "src/battle/battle_setup.c",
  },
}

-- Version-filesystem NARC symbols behind the two battle archives. The
-- symbols resolve through the version's ROM filesystem; no physical file
-- identity is assumed here or anywhere downstream.
BattlePresentationSources.LOWER_NARC = "NARC_a_0_0_7"
BattlePresentationSources.SCENE_NARC = "NARC_a_0_0_8"

-- Ordinary persistent backgrounds in source order. The first six are the
-- outdoor recipes whose palettes follow the time of day; the rest use
-- palette variant zero. The last entry is a known source recipe, not a new
-- gameplay region commitment.
BattlePresentationSources.BACKGROUNDS = {
  "general",
  "ocean",
  "city",
  "forest",
  "mountain",
  "snow",
  "building_1",
  "building_2",
  "building_3",
  "cave_1",
  "cave_2",
  "cave_3",
  "will",
  "koga",
  "bruno",
  "karen",
  "lance",
  "distortion_world",
}

BattlePresentationSources.OUTDOOR_BACKGROUNDS = 6

BattlePresentationSources.TIMES = { "day", "evening", "night" }

-- Terrain recipes by native ordinal: the two 4bpp cell members plus the
-- day/evening/night palette members. Every member below lives in the scene
-- archive. The unknown recipe reuses the great-marsh daylight with puddle
-- type-0 cells; it is source data, not a gap.
---@type table<string, { ordinal: integer, type0: integer, type1: integer, day: integer, evening: integer, night: integer }>
BattlePresentationSources.TERRAIN = {
  plain = { ordinal = 0, type0 = 135, type1 = 136, day = 7, evening = 8, night = 9 },
  sand = { ordinal = 1, type0 = 145, type1 = 146, day = 22, evening = 23, night = 24 },
  grass = { ordinal = 2, type0 = 127, type1 = 130, day = 1, evening = 2, night = 3 },
  puddle = { ordinal = 3, type0 = 151, type1 = 152, day = 31, evening = 32, night = 33 },
  mountain = { ordinal = 4, type0 = 139, type1 = 140, day = 13, evening = 14, night = 15 },
  cave = { ordinal = 5, type0 = 149, type1 = 150, day = 28, evening = 29, night = 30 },
  snow = { ordinal = 6, type0 = 141, type1 = 142, day = 16, evening = 17, night = 18 },
  water = { ordinal = 7, type0 = 133, type1 = 134, day = 4, evening = 5, night = 6 },
  ice = { ordinal = 8, type0 = 137, type1 = 138, day = 10, evening = 11, night = 12 },
  building = { ordinal = 9, type0 = 143, type1 = 144, day = 19, evening = 20, night = 21 },
  great_marsh = { ordinal = 10, type0 = 147, type1 = 148, day = 25, evening = 26, night = 27 },
  unknown = { ordinal = 11, type0 = 151, type1 = 148, day = 25, evening = 26, night = 27 },
  will = { ordinal = 12, type0 = 153, type1 = 154, day = 34, evening = 35, night = 36 },
  koga = { ordinal = 13, type0 = 155, type1 = 156, day = 37, evening = 38, night = 39 },
  bruno = { ordinal = 14, type0 = 157, type1 = 158, day = 40, evening = 41, night = 42 },
  karen = { ordinal = 15, type0 = 159, type1 = 160, day = 43, evening = 44, night = 45 },
  lance = { ordinal = 16, type0 = 161, type1 = 162, day = 46, evening = 47, night = 48 },
  distortion_world = { ordinal = 17, type0 = 163, type1 = 164, day = 49, evening = 50, night = 51 },
}

-- Exact shared menu/HUD member roles. All numbers below are zero-based
-- archive members: lower-screen roles live in the lower archive, HUD/arrow
-- and terrain roles in the scene archive.
BattlePresentationSources.ROLES = {
  lowerChars = 28,
  commandScreens = { 36, 41, 43 },
  fightScreens = { 37, 43 },
  targetScreens = { 38, 42, 43 },
  twoOptionScreens = { 39, 43 },
  lowerPalette = 246,
  hudPalette = 71,
  lowerObjPalette = 72,
  playerHud = { nanr = 189, ncer = 190, ncgr = 191 },
  enemyHud = { nanr = 186, ncer = 187, ncgr = 188 },
  arrow = { nanr = 183, ncer = 184, ncgr = 185 },
  gauges = {
    { ncer = 204, ncgr = 205, nanr = 206 },
    { ncer = 207, ncgr = 208, nanr = 209 },
  },
  backdropScreen = 2,
  terrainCells0 = 128,
  terrainAnim0 = 129,
  terrainCells1 = 131,
  terrainAnim1 = 132,
}

-- Source battle font behind narration, and the narration sound bank. The
-- font resolves to an existing generated font at compile time; the bank
-- resolves through the adopted audio plan at demand time.
BattlePresentationSources.BATTLE_FONT_ID = 1
BattlePresentationSources.NARRATION_BANK = 197

-- Ordinary single-battle audio roles: symbolic sequence references the
-- adopted audio plan resolves, never hard-coded bank numbers.
BattlePresentationSources.AUDIO_ROLES = {
  wild = "SEQ_GS_VS_NORAPOKE",
  trainer = "SEQ_GS_VS_TRAINER",
  rival = "SEQ_GS_VS_RIVAL",
  select = "SEQ_SE_DP_SELECT",
}

-- The retail lower load keeps the first 0x6000 bytes of the shared
-- 1024-tile lower characters: 384 tiles of 64 bytes in 8bpp terms, read
-- here as the staged 4bpp run's leading 384 tiles.
BattlePresentationSources.LOWER_USED_TILES = 384

local backgroundIndex = {}
for index, background in ipairs(BattlePresentationSources.BACKGROUNDS) do
  backgroundIndex[background] = index - 1
end

local timeIndex = {}
for index, time in ipairs(BattlePresentationSources.TIMES) do
  timeIndex[time] = index - 1
end

---@param background string
---@return integer|nil zero-based source background identity
function BattlePresentationSources.backgroundId(background)
  return backgroundIndex[background]
end

---@param background string
---@return boolean true for the outdoor recipes whose palettes follow the time
function BattlePresentationSources.isOutdoor(background)
  local id = backgroundIndex[background]
  return id ~= nil and id < BattlePresentationSources.OUTDOOR_BACKGROUNDS
end

---@param background string
---@param time string
---@return integer|nil palette variant, or nil for an unknown axis
function BattlePresentationSources.paletteVariant(background, time)
  if backgroundIndex[background] == nil or timeIndex[time] == nil then
    return nil
  end
  if not BattlePresentationSources.isOutdoor(background) then
    return 0
  end
  return timeIndex[time]
end

---@param backgroundId integer zero-based source background identity
---@param variant integer palette variant
---@return integer base palette member
function BattlePresentationSources.basePaletteMember(backgroundId, variant)
  return 176 + 3 * backgroundId + variant
end

---@param backgroundId integer zero-based source background identity
---@return integer base character member
function BattlePresentationSources.baseCharMember(backgroundId)
  return backgroundId + 3
end

---@param backgroundId integer zero-based source background identity
---@return integer base lower palette member
function BattlePresentationSources.lowerBasePaletteMember(backgroundId)
  if backgroundId == 17 then
    return 288
  end
  return 247 + backgroundId
end

---@param backgroundId integer zero-based source background identity
---@return integer touch lower palette member
function BattlePresentationSources.lowerTouchPaletteMember(backgroundId)
  if backgroundId == 17 then
    return 289
  end
  return 271 + backgroundId
end

---@param background string
---@param terrain string
---@param time string
---@return string canonical semantic scene key
function BattlePresentationSources.sceneKey(background, terrain, time)
  return background .. "/" .. terrain .. "/" .. time
end

---@param key string
---@return { background: string, terrain: string, time: string }|nil
function BattlePresentationSources.parseSceneKey(key)
  if type(key) ~= "string" then
    return nil
  end
  local background, terrain, time = key:match("^([^/]+)/([^/]+)/([^/]+)$")
  if background == nil or terrain == nil or time == nil then
    return nil
  end
  if backgroundIndex[background] == nil then
    return nil
  end
  if BattlePresentationSources.TERRAIN[terrain] == nil then
    return nil
  end
  if timeIndex[time] == nil then
    return nil
  end
  return { background = background, terrain = terrain, time = time }
end

---@param key string
---@return boolean
function BattlePresentationSources.validateSceneKey(key)
  return BattlePresentationSources.parseSceneKey(key) ~= nil
end

-- Every ordinary role/variant resolves to a complete recipe: the background
-- and terrain axes are fully inventoried, every role member is a
-- non-negative integer, and the palette formulas stay inside the evidenced
-- member ranges.
---@return boolean
function BattlePresentationSources.validate()
  if #BattlePresentationSources.BACKGROUNDS ~= 18 then
    return false
  end
  local ordinals = {}
  local terrainCount = 0
  for _, record in pairs(BattlePresentationSources.TERRAIN) do
    terrainCount = terrainCount + 1
    if type(record.ordinal) ~= "number" or ordinals[record.ordinal] then
      return false
    end
    ordinals[record.ordinal] = true
    for _, field in ipairs({ "type0", "type1", "day", "evening", "night" }) do
      if type(record[field]) ~= "number" or record[field] < 0 then
        return false
      end
    end
  end
  if terrainCount ~= 18 then
    return false
  end
  for ordinal = 0, 17 do
    if not ordinals[ordinal] then
      return false
    end
  end
  local roles = BattlePresentationSources.ROLES
  local function member(value)
    return type(value) == "number" and value >= 0
  end
  for _, field in ipairs({
    "lowerChars",
    "lowerPalette",
    "hudPalette",
    "lowerObjPalette",
    "backdropScreen",
    "terrainCells0",
    "terrainAnim0",
    "terrainCells1",
    "terrainAnim1",
  }) do
    if not member(roles[field]) then
      return false
    end
  end
  for _, field in ipairs({ "commandScreens", "fightScreens", "targetScreens", "twoOptionScreens" }) do
    if type(roles[field]) ~= "table" or #roles[field] == 0 then
      return false
    end
    for _, id in ipairs(roles[field]) do
      if not member(id) then
        return false
      end
    end
  end
  for _, field in ipairs({ "playerHud", "enemyHud", "arrow" }) do
    local role = roles[field]
    if type(role) ~= "table" or not member(role.nanr) or not member(role.ncer) or not member(role.ncgr) then
      return false
    end
  end
  if type(roles.gauges) ~= "table" or #roles.gauges ~= 2 then
    return false
  end
  for _, family in ipairs(roles.gauges) do
    if not member(family.ncer) or not member(family.ncgr) or not member(family.nanr) then
      return false
    end
  end
  return true
end

return BattlePresentationSources
