-- Source-faithful mon creation. Source: the retail ROM (CreateBoxMon, CreateMon, CreateStarter, GiveMon, and
-- trainer memo assignment). Creation consumes exactly
-- four generator draws in source order: two for the personality value (low
-- draw first) and two for the six individual values. The factory never
-- inserts into a party; the caller owns publication. Public creation methods
-- return a validated, native-projectable record or fail.

local Experience = require("libs.mons.src.gen4.Experience")
local Mon = require("libs.mons.src.Mon")
local MonsErrors = require("libs.mons.src.errors")
local Moves = require("libs.mons.src.gen4.Moves")
local NativeLegality = require("libs.mons.src.gen4.NativeLegality")
local Personality = require("libs.mons.src.gen4.Personality")
local Stats = require("libs.mons.src.gen4.Stats")
local U32 = require("libs.codec.src.U32")

---@class MonFactory
---@field private _catalog MonCatalog
---@field private _rng Gen4Lcrng
---@field private _charmap table<string, unknown>
---@field private _games table<string, integer>
---@field private _languages table<string, integer>
---@field private _game string
---@field private _language string
local MonFactory = {}
MonFactory.__index = MonFactory

---@param args { catalog: MonCatalog, rng: Gen4Lcrng, charmap: table<string, unknown>, games: table<string, integer>, languages: table<string, integer>, game: string, language: string }
---@return MonFactory
function MonFactory.new(args)
  assert(type(args) == "table", "factory requires an argument record")
  assert(args.catalog ~= nil, "factory requires a catalog")
  assert(args.rng ~= nil, "factory requires an exact generator")
  assert(type(args.charmap) == "table", "factory requires a charmap")
  assert(type(args.games) == "table", "factory requires a game table")
  assert(type(args.languages) == "table", "factory requires a language table")
  assert(type(args.game) == "string" and args.games[args.game] ~= nil, "factory game must resolve")
  assert(type(args.language) == "string" and args.languages[args.language] ~= nil, "factory language must resolve")
  return setmetatable({
    _catalog = args.catalog,
    _rng = args.rng,
    _charmap = args.charmap,
    _games = args.games,
    _languages = args.languages,
    _game = args.game,
    _language = args.language,
  }, MonFactory)
end

---@return MonsSave.Context
function MonFactory:_context()
  return {
    catalog = self._catalog,
    charmap = self._charmap,
    games = self._games,
    languages = self._languages,
  }
end

---@param draw integer
---@return table<string, integer>
local function splitIvDraw(draw)
  return {
    low = draw % 32,
    mid = math.floor(draw / 32) % 32,
    high = math.floor(draw / 1024) % 32,
  }
end

---@param record table<string, unknown>
---@return table<string, unknown>
function MonFactory:_finish(record)
  local canonical = Mon.validate(record, self:_context())
  NativeLegality.project(canonical, self:_context())
  return canonical
end

---@param request { species: string, level: integer, form: integer, profile: { name: string, gender: integer, trainerId: integer }, ball: string, location: integer, terrain: integer, date: { year: integer, month: integer, day: integer }, heldItem?: string, personality?: integer }
---@return table<string, unknown>
function MonFactory:_normalRecord(request)
  assert(type(request) == "table", "normal creation requires a request record")
  local species = self._catalog:species(request.species)
  local form = self._catalog:form(request.species, request.form)
  if
    type(request.level) ~= "number"
    or request.level % 1 ~= 0
    or request.level < 1
    or request.level > Stats.MAX_LEVEL
  then
    MonsErrors.raise(
      MonsErrors.RECORD_INVALID,
      "normal creation level must be an integer in 1.." .. Stats.MAX_LEVEL,
      { policy = "normal", species = request.species }
    )
  end
  local profile = request.profile
  assert(type(profile) == "table", "normal creation requires an owner profile")
  if type(request.ball) ~= "string" then
    MonsErrors.raise(
      MonsErrors.RECORD_INVALID,
      "normal creation ball must resolve",
      { policy = "normal", species = request.species }
    )
  end
  if not self._catalog:item(request.ball).isBall then
    MonsErrors.raise(
      MonsErrors.RECORD_INVALID,
      "normal creation ball must resolve",
      { policy = "normal", species = request.species }
    )
  end

  -- A forced personality skips its two generator draws (the source
  -- CreateMon with a fixed personality still draws the individual
  -- values); ordinary creation always draws all four values.
  local personality = request.personality
  if personality == nil then
    personality = self._rng:nextU32FromTwoDraws()
  else
    assert(
      type(personality) == "number" and personality % 1 == 0 and personality >= 0 and personality <= U32.MAX,
      "normal creation personality override must be an unsigned 32-bit integer"
    )
  end
  local first = splitIvDraw(self._rng:nextU16())
  local second = splitIvDraw(self._rng:nextU16())
  local ivs = {
    hp = first.low,
    attack = first.mid,
    defense = first.high,
    speed = second.low,
    specialAttack = second.mid,
    specialDefense = second.high,
  }

  local slot = Personality.abilitySlot(#form.abilities, personality)
  local ability = form.abilities[slot]
  local heldItem = request.heldItem
  if heldItem == nil then
    heldItem = "NONE"
  end
  local curve = self._catalog:growthCurve(species.growthCurve)
  local experience = Experience.expFor(curve, request.level)
  local nature = Personality.nature(personality)
  local evs = { hp = 0, attack = 0, defense = 0, speed = 0, specialAttack = 0, specialDefense = 0 }
  local derived = Stats.calculate(form.baseStats, ivs, evs, request.level, nature)
  local maxHp = derived.hp
  if request.species == "SHEDINJA" then
    maxHp = 1
  end

  local record = {
    schema = Mon.SCHEMA,
    species = request.species,
    form = request.form,
    personality = personality,
    experience = experience,
    friendship = species.baseFriendship,
    ability = ability,
    heldItem = heldItem,
    markings = 0,
    evs = evs,
    contest = { cool = 0, beauty = 0, cute = 0, smart = 0, tough = 0, sheen = 0 },
    moves = Moves.initial(form.levelUpMoves, request.level, self._catalog),
    ivs = ivs,
    isEgg = false,
    nickname = nil,
    ribbons = { ds1 = 0, gba = 0, ds2 = 0 },
    fatefulEncounter = false,
    shinyLeaves = 0,
    egg = { location = 0 },
    met = {
      location = request.location,
      date = {
        year = request.date.year,
        month = request.date.month,
        day = request.date.day,
      },
      level = request.level,
      terrain = request.terrain,
    },
    origin = {
      trainerId = profile.trainerId,
      trainerName = profile.name,
      trainerGender = profile.gender,
      game = self._game,
      ball = request.ball,
      language = self._language,
    },
    pokerus = 0,
    mood = 0,
    condition = { currentHp = maxHp, effects = {} },
    capsule = { id = 0, seals = {} },
    mail = {},
  }
  return record
end

---@param request { species: string, level: integer, form: integer, profile: { name: string, gender: integer, trainerId: integer }, ball: string, location: integer, terrain: integer, date: { year: integer, month: integer, day: integer }, heldItem?: string }
---@return table<string, unknown>
function MonFactory:createNormal(request)
  return self:_finish(self:_normalRecord(request))
end

---@param request { species: string, profile: { name: string, gender: integer, trainerId: integer }, location: integer, date: unknown }
---@return table<string, unknown>
function MonFactory:createStarter(request)
  assert(type(request) == "table", "starter creation requires a request record")
  return self:createNormal({
    species = request.species,
    level = 5,
    form = 0,
    profile = request.profile,
    ball = "POKE_BALL",
    location = request.location,
    terrain = 12,
    date = request.date --[[@as { year: integer, month: integer, day: integer }]],
  })
end

---@param request { species: string, level: integer, profile: { name: string, gender: integer, trainerId: integer }, location: integer, date: { year: integer, month: integer, day: integer }, heldItem?: string, form?: integer, ability?: string }
---@return table<string, unknown>
function MonFactory:createScriptGift(request)
  assert(type(request) == "table", "script-gift creation requires a request record")
  local mon = self:_normalRecord({
    species = request.species,
    level = request.level,
    form = 0,
    profile = request.profile,
    ball = "POKE_BALL",
    location = request.location,
    terrain = 24,
    date = request.date,
  })
  mon.heldItem = request.heldItem == nil and "NONE" or request.heldItem
  mon.form = request.form or 0
  if request.ability ~= nil then
    mon.ability = request.ability
  end
  return self:_finish(mon)
end

-- The source Spiky-Ear Pichu distribution constants in distribution order
-- (retail ROM): Naughty is nature
-- 4, and the ability parity must agree with it (source GF_ASSERT).
local SPIKY_EAR_PICHU_MOVES = { "HELPING_HAND", "VOLT_TACKLE", "SWAGGER", "PAIN_SPLIT" }
local SPIKY_EAR_NATURE = 4

-- The event-locked Spiky-Ear Pichu distribution: a fixed level-30 form-1
-- Pichu holding the Zap Plate with the source moveset at full power
-- points and an arithmetically forced Naughty female personality, exactly
-- like the retail ROM. The forced personality consumes no generator
-- draws (only the two individual-value draws run); met location and date
-- ride the request like any script gift. The caller owns party
-- publication, including the source full-party refusal before creation.
---@param request { profile: { name: string, gender: integer, trainerId: integer }, location: integer, date: { year: integer, month: integer, day: integer } }
---@return table<string, unknown>
function MonFactory:createSpikyEarPichu(request)
  assert(type(request) == "table", "spiky-ear pichu creation requires a request record")
  local profile = assert(request.profile, "spiky-ear pichu creation requires an owner profile")
  local ratio = self._catalog:species("PICHU").genderRatio
  local personality = Personality.forcedNatureGenderAbility(profile.trainerId, ratio, SPIKY_EAR_NATURE, "female", 0)
  local mon = self:_normalRecord({
    species = "PICHU",
    level = 30,
    form = 0,
    profile = profile,
    ball = "POKE_BALL",
    location = request.location,
    terrain = 24,
    date = request.date,
    personality = personality,
  })
  mon.form = 1
  mon.heldItem = "ZAP_PLATE"
  local moves = {}
  for _, key in ipairs(SPIKY_EAR_PICHU_MOVES) do
    local definition = self._catalog:move(key)
    moves[#moves + 1] = { move = key, pp = definition.basePp, ppUps = 0 }
  end
  mon.moves = moves
  return self:_finish(mon)
end

return MonFactory
