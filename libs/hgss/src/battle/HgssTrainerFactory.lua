-- Source-faithful non-player trainer party generation. Ports
-- pret/pokeheartgold src/trainer_data.c CreateNPCTrainerParty across all
-- four trainer record variants (plain, custom moves, held item, both):
-- difficulty, level, numeric species, and numeric trainer identity seed a
-- private generator per member; the generator advances once per numeric
-- trainer class; the personality combines the final generator output with
-- the class/override selector; difficulty maps to uniform individual
-- values; gender and ability overrides read the actual species/form facts;
-- plain members learn their native initial moveset; custom moves keep
-- source order with catalog power points; held item, form, capsule, and
-- the disappointment-move friendship apply after base creation in source
-- order. Every member validates as a full domain record. The surrounding
-- stream is never drawn from: generation owns a private generator per
-- member and leaves the caller stream bit-identical, so rebuilds replay
-- every personality and individual value exactly. Templates without native
-- numeric inputs build only through a declared semantic generation policy
-- and never by silently borrowing the native formula.

local Errors = require("libs.errors.src.Errors")
local Experience = require("libs.mons.src.gen4.Experience")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local Mon = require("libs.mons.src.Mon")
local Moves = require("libs.mons.src.gen4.Moves")
local NativeLegality = require("libs.mons.src.gen4.NativeLegality")
local Personality = require("libs.mons.src.gen4.Personality")
local Stats = require("libs.mons.src.gen4.Stats")

---@class HgssTrainerFactory
---@field private _catalog table<string, unknown>
---@field private _monCatalog table<string, unknown>
---@field private _charmap table<string, unknown>
---@field private _games table<string, integer>
---@field private _languages table<string, integer>
---@field private _game string
---@field private _language string
local HgssTrainerFactory = {}
HgssTrainerFactory.__index = HgssTrainerFactory

-- Native trainer-class Wanderers in class-index order, transcribed from the
-- class gender table in src/trainer_data.c: M for male, F for female, D for
-- double. Female-based classes seed the feminine personality byte, every
-- other class the masculine one. The table also drives the per-member
-- generator roll count, which equals the numeric class identity.
local CLASS_GENDERS = "MFMFMFMFFM"
  .. "FMMFMMMFFM"
  .. "MFFMMFFMMM"
  .. "FMMFMFFMMM"
  .. "FMMFMFMFMM"
  .. "FMMMFMMMMM"
  .. "MFFMMMMFMM"
  .. "FMMMFMFFMM"
  .. "FMFMFFMFFD"
  .. "FMFMFMFMMF"
  .. "MFMFMFFMMM"
  .. "MMDMFMMMMM"
  .. "MMMMMMFMF"

assert(#CLASS_GENDERS == 129, "the class gender table covers every native trainer class")

-- Symbolic class names appearing on semantic templates resolve to the same
-- numeric identities the native class header assigns them.
local CLASS_NUMBERS = { YOUNGSTER = 2, RIVAL = 23 }

local FRIENDSHIP_MAX = 255
local FRUSTRATION_MOVE = "FRUSTRATION"
local PID_FEMALE_BASE = 0x78
local PID_MALE_BASE = 0x88
local MAX_U32 = 4294967295

-- Neutral creation facts for detached battle-owned records. The trainer,
-- not the player, owns these mons, so the origin names a fixed trainer
-- profile instead of borrowing the live party identity; the met facts stay
-- constant because generation must replay bit-identically.
local DEFAULT_PROFILE = { name = "TRAINER", gender = 0, trainerId = 0 }
local DEFAULT_BALL = "POKE_BALL"
local DEFAULT_LOCATION = 0
local DEFAULT_TERRAIN = 0
local DEFAULT_DATE = { year = 2000, month = 1, day = 1 }

---@param text string
---@return integer deterministic unsigned 32-bit seed for semantic identities
local function hashSeed(text)
  local hash = 0
  for index = 1, #text do
    hash = (hash * 31 + string.byte(text, index)) % (MAX_U32 + 1)
  end
  return hash
end

---@param trainerClass string|integer|nil
---@return integer generator roll count for this class
local function classRolls(trainerClass)
  if type(trainerClass) == "number" then
    assert(trainerClass % 1 == 0 and trainerClass >= 0, "numeric trainer classes stay non-negative integers")
    return trainerClass
  end
  if type(trainerClass) == "string" and CLASS_NUMBERS[trainerClass] ~= nil then
    return CLASS_NUMBERS[trainerClass]
  end
  return 0
end

---@param trainerClass string|integer|nil
---@return integer personality byte seeding member generation
local function classBasePid(trainerClass)
  local gender = nil
  if type(trainerClass) == "number" and trainerClass >= 0 and trainerClass < #CLASS_GENDERS then
    gender = CLASS_GENDERS:sub(trainerClass + 1, trainerClass + 1)
  elseif trainerClass == "RIVAL" or trainerClass == "YOUNGSTER" then
    gender = "M"
  end
  if gender == "F" then
    return PID_FEMALE_BASE
  end
  return PID_MALE_BASE
end

---@param policy unknown
---@return boolean true for the native identity path with native numerics
local function isNativePolicy(policy)
  return policy == nil or policy == "native_pid"
end

---@param member table<string, unknown> party member template
---@param what string
local function assertMemberShape(member, what)
  assert(type(member) == "table", what .. " builds party member records")
  local entry = member --[[@as table<string, unknown>]]
  assert(type(entry.species) == "string" and entry.species ~= "", what .. " members name their species")
  assert(
    type(entry.level) == "number" and entry.level % 1 == 0 and entry.level >= 1 and entry.level <= Stats.MAX_LEVEL,
    what .. " members carry a level in 1.." .. Stats.MAX_LEVEL
  )
end

---@param member table<string, unknown>
local function assertNativeInputs(member)
  if member.difficulty == nil then
    Errors.raise("TRAINER_NATIVE_INPUTS_MISSING", "native generation needs the native difficulty input", {
      species = member.species,
    })
  end
  assert(
    type(member.difficulty) == "number"
      and member.difficulty % 1 == 0
      and member.difficulty >= 0
      and member.difficulty <= 255,
    "native difficulty stays an unsigned byte"
  )
end

---@param trainerId unknown
---@param trainerKey unknown
---@return integer numeric trainer identity backing the native seed
local function nativeTrainerId(trainerId, trainerKey)
  local identity = trainerId
  if identity == nil then
    identity = trainerKey
  end
  if type(identity) ~= "number" or identity % 1 ~= 0 or identity < 0 then
    Errors.raise("TRAINER_NATIVE_INPUTS_MISSING", "native generation needs the numeric trainer identity", {
      trainer = tostring(trainerKey),
    })
  end
  return identity --[[@as integer]]
end

---@param member table<string, unknown>
---@return string[] custom moves in source order
local function customMoves(member)
  assert(type(member.moves) == "table", "custom members carry their move list")
  local moves = member.moves --[[@as table<integer, unknown>]]
  assert(#moves >= 1 and #moves <= 4, "custom members carry one to four moves")
  local out = {}
  for index, move in ipairs(moves) do
    assert(type(move) == "string" and move ~= "", "custom move " .. index .. " names its move key")
    out[#out + 1] = move
  end
  return out
end

---@param params table<string, unknown>|nil
---@return integer, integer gender and ability override nibbles
local function overrideNibbles(params)
  if type(params) ~= "table" then
    return 0, 0
  end
  return params.genderOverride or 0, params.abilityOverride or 0
end

---@param params table<string, unknown>|nil
---@return integer capsule word carried by the template
local function capsuleWord(params)
  if type(params) ~= "table" or params.capsule == nil then
    return 0
  end
  local capsule = params.capsule --[[@as unknown]]
  if type(capsule) ~= "number" or capsule % 1 ~= 0 or capsule < 0 or capsule > 255 then
    Errors.raise("TRAINER_NATIVE_INPUTS_MISSING", "capsule facts stay an unsigned byte", {
      capsule = tostring(params.capsule),
    })
  end
  return capsule --[[@as integer]]
end

---@param pid integer
---@param genderOverride integer
---@param abilityOverride integer
---@param ratio integer species gender ratio backing forced identities
---@return integer personality byte after the native override rules
local function applyOverrides(pid, genderOverride, abilityOverride, ratio)
  local value = pid
  if genderOverride ~= 0 or abilityOverride ~= 0 then
    if genderOverride ~= 0 then
      value = ratio
      if genderOverride == 1 then
        value = value + 2
      else
        value = value - 2
      end
    end
    if abilityOverride == 1 then
      value = value - (value % 2)
    elseif abilityOverride == 2 then
      value = value + (1 - (value % 2))
    end
  end
  return value
end

---@param difficulty integer
---@param level integer
---@param nativeSpeciesId integer
---@param trainerId integer
---@param trainerClass string|integer|nil
---@param pidByte integer
---@return integer, integer personality value and uniform individual value
local function nativeIdentity(difficulty, level, nativeSpeciesId, trainerId, trainerClass, pidByte)
  local seed = (difficulty + level + nativeSpeciesId + trainerId) % (MAX_U32 + 1)
  local generator = Lcrng.new(seed)
  local rolled = seed % 65536
  for _ = 1, classRolls(trainerClass) do
    rolled = generator:nextU16()
  end
  local personality = (rolled * 256 + (pidByte % 256)) % (MAX_U32 + 1)
  local iv = math.floor((difficulty * 31) / 255)
  return personality, iv
end

---@param templateValue integer|nil template-carried friendship, full when absent
---@param moves { move: string }[] resolved moves for the disappointment-move rule
---@return integer friendship after the native disappointment-move rule
local function friendshipFor(templateValue, moves)
  local friendship = templateValue
  if friendship == nil then
    friendship = FRIENDSHIP_MAX
  end
  assert(
    type(friendship) == "number" and friendship % 1 == 0 and friendship >= 0 and friendship <= FRIENDSHIP_MAX,
    "friendship stays an unsigned byte"
  )
  for _, entry in ipairs(moves) do
    if entry.move == FRUSTRATION_MOVE then
      return 0
    end
  end
  return friendship --[[@as integer]]
end

---@return table<string, unknown> domain validation context behind generated records
function HgssTrainerFactory:_validationContext()
  return {
    catalog = self._monCatalog,
    charmap = self._charmap,
    games = self._games,
    languages = self._languages,
  }
end

---@param member table<string, unknown>
---@param formDef table<string, unknown>
---@return { move: string, pp: integer, ppUps: integer }[] domain moves in source order
function HgssTrainerFactory:_resolveMoves(member, formDef)
  local monCatalog = self._monCatalog
  if member.moves ~= nil then
    local entries = {}
    for _, key in ipairs(customMoves(member)) do
      local definition = monCatalog:move(key)
      entries[#entries + 1] = { move = key, pp = definition.basePp, ppUps = 0 }
    end
    return entries
  end
  local level = member.level --[[@as integer]]
  return Moves.initial(formDef.levelUpMoves, level, monCatalog)
end

---@param profile table<string, unknown>|nil
---@return table<string, unknown> origin profile behind generated records
local function originProfile(profile)
  if profile == nil then
    return { name = DEFAULT_PROFILE.name, gender = DEFAULT_PROFILE.gender, trainerId = DEFAULT_PROFILE.trainerId }
  end
  assert(type(profile) == "table", "generation profiles stay records")
  local entry = profile --[[@as table<string, unknown>]]
  assert(type(entry.name) == "string" and entry.name ~= "", "generation profiles name their trainer")
  assert(type(entry.gender) == "number", "generation profiles carry their trainer gender")
  assert(type(entry.trainerId) == "number", "generation profiles carry their trainer identity")
  return { name = entry.name, gender = entry.gender, trainerId = entry.trainerId }
end

---@param args { catalog: table<string, unknown>, monCatalog: table<string, unknown>, charmap: table<string, unknown>, games: table<string, integer>, languages: table<string, integer>, game: string, language: string }
---@return HgssTrainerFactory
function HgssTrainerFactory.new(args)
  assert(type(args) == "table", "trainer generation reads its template catalog")
  assert(type(args.catalog) == "table", "trainer generation reads its template catalog")
  assert(args.monCatalog ~= nil, "trainer generation reads its domain mon catalog")
  assert(type(args.charmap) == "table", "trainer generation reads its text charmap")
  assert(type(args.games) == "table", "trainer generation reads its game table")
  assert(type(args.languages) == "table", "trainer generation reads its language table")
  assert(type(args.game) == "string" and args.games[args.game] ~= nil, "trainer generation game must resolve")
  assert(
    type(args.language) == "string" and args.languages[args.language] ~= nil,
    "trainer generation language must resolve"
  )
  return setmetatable({
    _catalog = args.catalog,
    _monCatalog = args.monCatalog,
    _charmap = args.charmap,
    _games = args.games,
    _languages = args.languages,
    _game = args.game,
    _language = args.language,
  }, HgssTrainerFactory)
end

---@param member table<string, unknown> party member template
---@param context table<string, unknown> build context carrying the trainer identity and stream
---@return table<string, unknown> validated full domain record for the member
function HgssTrainerFactory:buildNativeMon(member, context)
  assertMemberShape(member, "trainer generation")
  assert(type(context) == "table", "member generation reads its build context")
  assert(type(context.rng) == "table", "member generation threads the surrounding stream untouched")
  local trainerClass = context.trainerClass
  local native = isNativePolicy(member.identityPolicy)
  if native then
    assertNativeInputs(member)
  else
    assert(
      type(member.identityPolicy) == "string" and member.identityPolicy ~= "",
      "custom templates declare their semantic generation policy"
    )
  end
  local monCatalog = self._monCatalog
  local speciesDef = monCatalog:species(member.species)
  local form = member.form or 0
  assert(type(form) == "number" and form % 1 == 0 and form >= 0, "member forms stay non-negative integers")
  local formDef = monCatalog:form(member.species, form)
  local genderRatio = speciesDef.genderRatio
  assert(
    type(genderRatio) == "number" and genderRatio % 1 == 0 and genderRatio >= 0 and genderRatio <= 255,
    "species gender ratios stay unsigned bytes"
  )
  local genderOverride, abilityOverride = overrideNibbles(member.identityParams)
  local capsule = capsuleWord(member.identityParams)
  local ratio = genderRatio --[[@as integer]]
  local level = member.level --[[@as integer]]
  local personality, iv
  if native then
    local nativeSpeciesId = speciesDef.nativeId
    if type(nativeSpeciesId) ~= "number" then
      Errors.raise("TRAINER_NATIVE_INPUTS_MISSING", "native generation needs the numeric species identity", {
        species = member.species,
      })
    end
    local speciesId = nativeSpeciesId --[[@as integer]]
    local difficultyValue = member.difficulty --[[@as integer]]
    local trainerId = nativeTrainerId(context.trainerId, context.trainerKey)
    local pidByte = applyOverrides(classBasePid(trainerClass), genderOverride, abilityOverride, ratio)
    personality, iv = nativeIdentity(difficultyValue, level, speciesId, trainerId, trainerClass, pidByte)
  else
    local seed = hashSeed(member.species .. "|" .. tostring(level) .. "|" .. tostring(member.identityPolicy))
    personality = seed
    iv = 0
    if member.difficulty ~= nil then
      assertNativeInputs(member)
      local difficultyValue = member.difficulty --[[@as integer]]
      iv = math.floor((difficultyValue * 31) / 255)
    end
  end
  local abilitySlot = Personality.abilitySlot(#formDef.abilities, personality)
  local ability = formDef.abilities[abilitySlot]
  local moves = self:_resolveMoves(member, formDef)
  local heldItem = member.heldItem or "NONE"
  assert(type(heldItem) == "string" and heldItem ~= "", "held items name their item key")
  monCatalog:item(heldItem)
  local ivs = {
    hp = iv,
    attack = iv,
    defense = iv,
    speed = iv,
    specialAttack = iv,
    specialDefense = iv,
  }
  local evs = { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 }
  local curve = monCatalog:growthCurve(speciesDef.growthCurve)
  local experience = Experience.expFor(curve, level)
  local nature = Personality.nature(personality)
  local derived = Stats.calculate(formDef.baseStats, ivs, evs, level, nature)
  local maxHp = derived.hp
  if member.species == "SHEDINJA" then
    maxHp = 1
  end
  local profile = originProfile(context.profile)
  local ball = context.ball or DEFAULT_BALL
  assert(type(ball) == "string" and ball ~= "", "generation balls name their item key")
  local location = context.location
  if location == nil then
    location = DEFAULT_LOCATION
  end
  assert(type(location) == "number" and location % 1 == 0 and location >= 0, "met locations stay non-negative integers")
  local terrain = context.terrain
  if terrain == nil then
    terrain = DEFAULT_TERRAIN
  end
  assert(type(terrain) == "number" and terrain % 1 == 0 and terrain >= 0, "met terrains stay unsigned bytes")
  local date = context.date or DEFAULT_DATE
  assert(type(date) == "table", "generation dates stay records")
  local record = {
    schema = Mon.SCHEMA,
    species = member.species,
    form = form,
    personality = personality,
    experience = experience,
    friendship = friendshipFor(member.friendship, moves),
    ability = ability,
    heldItem = heldItem,
    markings = 0,
    evs = evs,
    contest = { cool = 0, beauty = 0, cute = 0, smart = 0, tough = 0, sheen = 0 },
    moves = moves,
    ivs = ivs,
    isEgg = false,
    nickname = nil,
    ribbons = { ds1 = 0, gba = 0, ds2 = 0 },
    fatefulEncounter = false,
    shinyLeaves = 0,
    egg = { location = 0 },
    met = {
      location = location,
      date = { year = date.year, month = date.month, day = date.day },
      level = level,
      terrain = terrain,
    },
    origin = {
      trainerId = profile.trainerId,
      trainerName = profile.name,
      trainerGender = profile.gender,
      game = self._game,
      ball = ball,
      language = self._language,
    },
    pokerus = 0,
    mood = 0,
    condition = { currentHp = maxHp, effects = {} },
    capsule = { id = capsule, seals = {} },
    mail = {},
  }
  local domain = self:_validationContext()
  local canonical = Mon.validate(record, domain)
  NativeLegality.project(canonical, domain)
  return canonical
end

---@param context table<string, unknown> build context carrying the trainer key, names, and stream
---@return table<string, unknown> built party with its resolved display name and native metadata
function HgssTrainerFactory:build(context)
  assert(type(context) == "table", "party generation reads its build context")
  assert(context.trainerKey ~= nil, "party generation names its trainer")
  assert(type(context.rng) == "table", "party generation threads the surrounding stream untouched")
  local catalog = context.catalog or self._catalog
  assert(type(catalog) == "table", "party generation reads its template catalog")
  local lookup = catalog.trainer
  assert(type(lookup) == "function", "party generation reads templates through the catalog owner")
  local template = lookup(catalog, context.trainerKey)
  if template == nil then
    Errors.raise("TRAINER_UNKNOWN", "party generation rejects unknown trainer keys", {
      trainer = tostring(context.trainerKey),
    })
  end
  local record = template --[[@as table<string, unknown>]]
  local party = record.party --[[@as table<integer, unknown>]]
  if context.storyVariant ~= nil and type(record.variants) == "table" then
    local variant = record.variants[context.storyVariant]
    if type(variant) == "table" and type(variant.party) == "table" then
      party = variant.party
    end
  end
  local name = nil
  local reference = record.nameReference
  if type(reference) == "table" and reference.rival == true then
    assert(
      type(context.rivalName) == "string" and context.rivalName ~= "",
      "rival parties resolve their display name from the saved rival name"
    )
    name = context.rivalName
  else
    name = tostring(context.trainerKey)
  end
  local memberContext = {
    rng = context.rng,
    trainerKey = context.trainerKey,
    trainerId = context.trainerId,
    trainerClass = record.trainerClass,
    profile = context.profile,
    ball = context.ball,
    location = context.location,
    terrain = context.terrain,
    date = context.date,
  }
  local mons = {}
  local partyLevels = {}
  for _, member in ipairs(party) do
    mons[#mons + 1] = self:buildNativeMon(member, memberContext)
    local entry = member --[[@as table<string, unknown>]]
    partyLevels[#partyLevels + 1] = entry.level
  end
  local program = nil
  if type(catalog.program) == "function" then
    program = catalog:program(context.trainerKey)
  end
  return {
    name = name,
    mons = mons,
    trainerKey = context.trainerKey,
    trainerClass = record.trainerClass,
    partyLevels = partyLevels,
    doubleBattle = record.doubleBattle == true,
    aiPasses = record.aiPasses or {},
    items = record.items or {},
    program = program,
  }
end

return HgssTrainerFactory
