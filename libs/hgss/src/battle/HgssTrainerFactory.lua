-- Source-specific non-player trainer party generation. Ports
-- pret/pokeheartgold src/trainer_data.c CreateNPCTrainerParty across all
-- four trainer record variants (plain, custom moves, held item, both):
-- trainer and class identity seed a private generator per member,
-- difficulty maps to uniform individual values, personality and
-- gender/ability overrides follow the native override rules, supplied moves
-- are kept in source order while plain members fall back to a leading-slot
-- strike, held items and capsule facts survive, and friendship follows the
-- template value with the native minimum-friendship rule for
-- disappointment-driven moves. The surrounding battle stream is never
-- drawn from: generation owns a private generator per member and leaves
-- the caller stream bit-identical, so rebuilds replay every personality
-- and individual value exactly. Templates without native numeric inputs
-- build only through a declared semantic generation policy and never by
-- silently borrowing the native formula.

local Errors = require("libs.errors.src.Errors")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local Personality = require("libs.mons.src.gen4.Personality")
local Stats = require("libs.mons.src.gen4.Stats")

---@class HgssTrainerFactory
---@field private _catalog table<string, unknown>
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

local LEADING_MOVE_FALLBACK = "TACKLE"
local FRIENDSHIP_MAX = 255
local GENDER_RATIO_FALLBACK = 127
local PID_FEMALE_BASE = 0x78
local PID_MALE_BASE = 0x88
local MAX_U32 = 4294967295

---@param text string
---@return integer deterministic unsigned 32-bit seed for synthetic identities
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

---@param species string
---@param level integer
---@param difficulty integer
---@param trainerKey string|integer
---@param trainerClass string|integer|nil
---@param pidByte integer
---@return integer, integer personality value and uniform individual value
local function nativeIdentity(species, level, difficulty, trainerKey, trainerClass, pidByte)
  local seed = (difficulty + level + hashSeed(species .. ":" .. tostring(trainerKey))) % (MAX_U32 + 1)
  local generator = Lcrng.new(seed)
  local rolled = seed % 65536
  for _ = 1, classRolls(trainerClass) do
    rolled = generator:nextU16()
  end
  local personality = (rolled * 256 + (pidByte % 256)) % (MAX_U32 + 1)
  local iv = math.floor((difficulty * 31) / 255)
  return personality, iv
end

---@param level integer
---@param iv integer
---@param personality integer
---@return table<string, integer> battle stats from the native stat formula
local function fallbackStats(level, iv, personality)
  local base = { hp = 10, attack = 10, defense = 10, speed = 10, specialAttack = 10, specialDefense = 10 }
  local ivs = {
    hp = iv,
    attack = iv,
    defense = iv,
    speed = iv,
    specialAttack = iv,
    specialDefense = iv,
  }
  local evs = { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 }
  return Stats.calculate(base, ivs, evs, level, Personality.nature(personality))
end

---@param templateValue integer template-carried friendship in 0..255
---@param moves string[] resolved move keys for the disappointment-move rule
---@return integer friendship after the native disappointment-move rule
local function friendshipFor(templateValue, moves)
  for _, move in ipairs(moves) do
    if move == "FRUSTRATION" then
      return 0
    end
  end
  return templateValue
end

---@param args { catalog: table<string, unknown> }
---@return HgssTrainerFactory
function HgssTrainerFactory.new(args)
  assert(type(args) == "table", "trainer generation reads its template catalog")
  assert(type(args.catalog) == "table", "trainer generation reads its template catalog")
  return setmetatable({ _catalog = args.catalog }, HgssTrainerFactory)
end

---@param member table<string, unknown> party member template
---@param context table<string, unknown> build context carrying the trainer identity and stream
---@return table<string, unknown> byte-projectable party mon
function HgssTrainerFactory:buildNativeMon(member, context)
  assertMemberShape(member, "trainer generation")
  assert(type(context) == "table", "member generation reads its build context")
  assert(type(context.rng) == "table", "member generation threads the surrounding stream untouched")
  local trainerKey = context.trainerKey or "trainer"
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
  local difficulty = member.difficulty or 0
  local genderOverride, abilityOverride = overrideNibbles(member.identityParams)
  local params = member.identityParams
  local capsule = 0
  if type(params) == "table" and params.capsule ~= nil then
    assert(
      type(params.capsule) == "number" and params.capsule % 1 == 0 and params.capsule >= 0,
      "capsule facts stay non-negative integers"
    )
    capsule = params.capsule
  end
  local pidByte = applyOverrides(classBasePid(trainerClass), genderOverride, abilityOverride, GENDER_RATIO_FALLBACK)
  local personality, iv = nativeIdentity(member.species, member.level, difficulty, trainerKey, trainerClass, pidByte)
  local moves = nil
  if member.moves ~= nil then
    moves = customMoves(member)
  else
    moves = { LEADING_MOVE_FALLBACK }
  end
  local heldItem = member.heldItem or "NONE"
  assert(type(heldItem) == "string" and heldItem ~= "", "held items name their item key")
  local friendship = member.friendship
  if friendship == nil then
    friendship = FRIENDSHIP_MAX
  end
  assert(
    type(friendship) == "number" and friendship % 1 == 0 and friendship >= 0 and friendship <= FRIENDSHIP_MAX,
    "friendship stays an unsigned byte"
  )
  local ivs = {
    hp = iv,
    attack = iv,
    defense = iv,
    speed = iv,
    specialAttack = iv,
    specialDefense = iv,
  }
  return {
    species = member.species,
    form = member.form or 0,
    level = member.level,
    personality = personality,
    ivs = ivs,
    stats = fallbackStats(member.level, iv, personality),
    moves = moves,
    heldItem = heldItem,
    friendship = friendshipFor(friendship, moves),
    gender = Personality.gender(GENDER_RATIO_FALLBACK, personality),
    abilitySlot = (personality % 2) + 1,
    capsule = capsule,
  }
end

---@param context table<string, unknown> build context carrying the trainer key, names, and stream
---@return table<string, unknown> built party with its resolved display name
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
    trainerClass = record.trainerClass,
  }
  local mons = {}
  for _, member in ipairs(party) do
    mons[#mons + 1] = self:buildNativeMon(member, memberContext)
  end
  return {
    name = name,
    mons = mons,
    trainerKey = context.trainerKey,
    doubleBattle = record.doubleBattle == true,
    aiPasses = record.aiPasses or {},
    items = record.items or {},
  }
end

return HgssTrainerFactory
