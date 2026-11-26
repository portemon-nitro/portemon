-- Source-faithful mon creation. Source: the retail ROM (CreateBoxMon,
-- CreateMon, CreateStarter, GiveMon, SetEggStats, GiveEggToPlayer, and trainer
-- memo assignment). Ordinary creation consumes exactly four generator draws in
-- source order: two for the personality value (low draw first) and two for the
-- six individual values; a forced personality skips its two draws, and a bred
-- egg continues with the source's three inherited values after those two. The
-- factory never inserts into a party; the caller owns publication. Public
-- creation methods return a validated, native-projectable record or fail.

local Breeding = require("libs.mons.src.gen4.Breeding")
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
  elseif mon.form ~= 0 then
    -- UpdateBoxMonAbility: a requested alternate form owns its own ability
    -- slot table, so the stored ability follows the form the caller asked for
    -- instead of the base form the value was generated from.
    local formed = self._catalog:form(request.species, mon.form)
    mon.ability = formed.abilities[Personality.abilitySlot(#formed.abilities, mon.personality)]
  end
  return self:_finish(mon)
end

-- The source unhatched-egg record (SetEggStats with memo strategy 3 in
-- get_egg.c): a level-1 egg in a Poke Ball whose friendship is the personal
-- egg cycles, whose egg record carries the receipt location and date, and
-- whose meeting record is cleared to location zero, no date, and level zero.
-- The biological species stays on the record while the default display name
-- resolves to the localized egg label, with no custom nickname or fateful
-- encounter. A forced personality skips its two generation draws; the caller
-- owns party insertion, including the source capacity check before any draw.
---@param request { species: string, form: integer, personality: integer?, profile: { name: string, gender: integer, trainerId: integer }, location: integer, date: { year: integer, month: integer, day: integer } }
---@return table<string, unknown>
function MonFactory:_eggRecord(request)
  assert(type(request) == "table", "egg creation requires a request record")
  local profile = assert(request.profile, "egg creation requires an owner profile")
  local location = assert(request.location, "egg creation requires a receipt location")
  local date = assert(request.date, "egg creation requires a receipt date")
  assert(
    type(date) == "table"
      and type(date.year) == "number"
      and type(date.month) == "number"
      and type(date.day) == "number",
    "egg creation requires a receipt date record"
  )
  local mon = self:_normalRecord({
    species = request.species,
    level = 1,
    form = request.form,
    profile = profile,
    ball = "POKE_BALL",
    location = location,
    terrain = 0,
    date = date,
    personality = request.personality,
  })
  mon.friendship = self._catalog:species(request.species).eggCycles
  mon.isEgg = true
  mon.nickname = nil
  mon.fatefulEncounter = false
  mon.egg = {
    location = location,
    date = { year = date.year, month = date.month, day = date.day },
  }
  mon.met = { location = 0, level = 0, terrain = 0 }
  return mon
end

-- The source script-gift egg (SetEggStats): no forced personality, so the
-- record keeps the four generation draws and the base form.
---@param request { species: string, profile: { name: string, gender: integer, trainerId: integer }, location: integer, date: { year: integer, month: integer, day: integer } }
---@return table<string, unknown>
function MonFactory:createScriptEgg(request)
  assert(type(request) == "table", "script-egg creation requires a request record")
  return self:_finish(self:_eggRecord({
    species = request.species,
    form = 0,
    profile = request.profile,
    location = request.location,
    date = request.date,
  }))
end

-- Source GiveEggToPlayer's bred egg: the forced pending personality (already
-- resolved through the different-language mixer), the mother's form, the two
-- generation individual-value draws followed by InheritIVs' three distinct
-- inherited values, and the inherited move set in source insertion order.
---@param request { species: string, form: integer, personality: integer, profile: { name: string, gender: integer, trainerId: integer }, location: integer, date: { year: integer, month: integer, day: integer }, parents: table[], moves: table<string, unknown>[] }
---@return table<string, unknown>
function MonFactory:createBredEgg(request)
  assert(type(request) == "table", "bred-egg creation requires a request record")
  local parents = assert(request.parents, "bred-egg creation requires the parents")
  local moves = assert(request.moves, "bred-egg creation requires the inherited move set")
  local mon = self:_eggRecord({
    species = request.species,
    form = request.form,
    personality = request.personality,
    profile = request.profile,
    location = request.location,
    date = request.date,
  })
  local function drawLc()
    return self._rng:nextU16()
  end
  for _, assignment in ipairs(Breeding.inheritedIvs({ parents = parents, lc = drawLc })) do
    local parent = assert(parents[assignment.slot], "the inherited stat names its parent")
    mon.ivs[assignment.stat] = parent.ivs[assignment.stat]
  end
  mon.moves = moves
  local form = self._catalog:form(request.species, request.form)
  local derived = Stats.calculate(form.baseStats, mon.ivs, mon.evs, 1, Personality.nature(mon.personality))
  mon.condition = { currentHp = derived.hp, effects = {} }
  return self:_finish(mon)
end

-- The Ranger-origin egg receipt location: Mapsec_FromTypeAndIndex with the
-- external base and index 1. The hatch advances a shiny Manaphy's personality
-- only for an egg that arrived with this receipt.
local RANGER_EGG_LOCATION = 3001
-- The source hatch friendship (HatchEgg_RecreateMon).
local HATCH_FRIENDSHIP = 120

---@param personality integer
---@return integer the source PRandom personality mixer
local function prandom(personality)
  return U32.add(U32.mul(personality, Breeding.PERSONALITY_MIXER), 1)
end

-- Source HatchEgg_RecreateMon and HatchEggMon: one party egg becomes the mon it
-- carried. The species stays at level one with the egg's personality, a
-- shiny Ranger-origin Manaphy advances that personality with PRandom until the
-- trainer no longer sees a shiny, and creation consumes exactly the two base
-- individual-value draws a forced personality leaves in CreateMon. The hatched
-- record then keeps the egg's moves with their current power points, its
-- retained individual values, language, met game, markings, Pokerus, fateful
-- status, original trainer identity, form, and egg and meeting facts; PP Ups
-- and every other fresh-record field come from level-one creation. It hatches
-- with the source friendship in a Poke Ball at meeting level zero, no custom
-- nickname, and the egg flag cleared. The caller owns party publication.
---@param request { egg: table<string, unknown> }
---@return table<string, unknown>
function MonFactory:createHatchedMon(request)
  assert(type(request) == "table", "hatch creation requires a request record")
  local egg = assert(request.egg, "hatch creation requires the egg record")
  if egg.isEgg ~= true then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, "hatch creation requires an unhatched egg", {})
  end
  local species = egg.species
  local personality = egg.personality
  local otId = egg.origin.trainerId
  if species == "MANAPHY" and egg.egg.location == RANGER_EGG_LOCATION then
    if Personality.shiny(otId, personality) then
      repeat
        personality = prandom(personality)
      until not Personality.shiny(otId, personality)
    end
  end
  local metDate = egg.met.date
  local mon = self:_normalRecord({
    species = species,
    level = 1,
    form = 0,
    profile = {
      name = egg.origin.trainerName,
      gender = egg.origin.trainerGender,
      trainerId = otId,
    },
    ball = "POKE_BALL",
    location = egg.met.location,
    terrain = egg.met.terrain,
    date = metDate or egg.egg.date,
    personality = personality,
  })
  local moves = {}
  for index, entry in ipairs(egg.moves) do
    moves[index] = { move = entry.move, pp = entry.pp, ppUps = 0 }
  end
  mon.moves = moves
  mon.ivs = {
    hp = egg.ivs.hp,
    attack = egg.ivs.attack,
    defense = egg.ivs.defense,
    speed = egg.ivs.speed,
    specialAttack = egg.ivs.specialAttack,
    specialDefense = egg.ivs.specialDefense,
  }
  mon.friendship = HATCH_FRIENDSHIP
  mon.markings = egg.markings
  mon.pokerus = egg.pokerus
  mon.fatefulEncounter = egg.fatefulEncounter
  mon.form = egg.form
  if egg.form ~= 0 then
    -- The stored ability follows the form the egg carried; base and alternate
    -- forms publish their own slot tables.
    local formed = self._catalog:form(species, mon.form)
    mon.ability = formed.abilities[Personality.abilitySlot(#formed.abilities, personality)]
  end
  mon.origin = {
    trainerId = otId,
    trainerName = egg.origin.trainerName,
    trainerGender = egg.origin.trainerGender,
    game = egg.origin.game,
    ball = "POKE_BALL",
    language = egg.origin.language,
  }
  mon.egg = { location = egg.egg.location }
  if egg.egg.date ~= nil then
    mon.egg.date = {
      year = egg.egg.date.year,
      month = egg.egg.date.month,
      day = egg.egg.date.day,
    }
  end
  mon.met = {
    location = egg.met.location,
    level = 0,
    terrain = egg.met.terrain,
  }
  if metDate ~= nil then
    mon.met.date = { year = metDate.year, month = metDate.month, day = metDate.day }
  end
  mon.isEgg = false
  mon.nickname = nil
  local form = self._catalog:form(species, mon.form)
  local derived = Stats.calculate(form.baseStats, mon.ivs, mon.evs, 1, Personality.nature(personality))
  mon.condition = { currentHp = derived.hp, effects = {} }
  return self:_finish(mon)
end

-- The original gift egg (ScrCmd_GiveTogepiEgg): SetEggStats builds the
-- level-one Togepi egg with its source receipt, and Extrasensory fills the
-- first empty move slot -- or replaces the last move when the set is full --
-- at the move's own base power points. The caller checks party room and owns
-- publication plus the recorded gift identity.
---@param request { profile: { name: string, gender: integer, trainerId: integer }, location: integer, date: { year: integer, month: integer, day: integer } }
---@return table<string, unknown>
function MonFactory:createTogepiEgg(request)
  assert(type(request) == "table", "gift-egg creation requires a request record")
  local mon = self:_eggRecord({
    species = "TOGEPI",
    form = 0,
    profile = request.profile,
    location = request.location,
    date = request.date,
  })
  -- The source scans the four move slots for the first empty one and falls
  -- back to the last slot when the set is already full.
  local slot = math.min(#mon.moves + 1, Moves.MAX_SLOTS)
  local definition = self._catalog:move("EXTRASENSORY")
  local move = { move = "EXTRASENSORY", pp = definition.basePp, ppUps = 0 }
  if slot <= #mon.moves then
    mon.moves[slot] = move
  else
    mon.moves[#mon.moves + 1] = move
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

-- Source _CreateTradeMon (src/npc_trade.c): the NPC's own record is created
-- with the table's fixed personality, so ordinary creation spends exactly the
-- two individual-value draws and then every identity column is written over
-- the generated one -- the six individual values, the five contest values, the
-- held item, the custom nickname, the OT name, the OT gender and the record
-- language. The ability stays the one ordinary creation derived from the
-- personality and the form, and the source's unused ability and sheen columns
-- are never applied. The meeting memo is the caller's resolved strategy. The
-- caller owns party publication.
---@param request { species: string, level: integer, personality: integer, otId: integer, otName: string, otGender: integer, language: string, heldItem: string, nickname: string, ivs: table<string, integer>, contest: table<string, integer>, location: integer, date: { year: integer, month: integer, day: integer } }
---@return table<string, unknown>
function MonFactory:createNpcTrade(request)
  assert(type(request) == "table", "NPC trade creation requires a request record")
  local mon = self:_normalRecord({
    species = request.species,
    level = request.level,
    form = 0,
    profile = {
      name = request.otName,
      gender = request.otGender,
      trainerId = request.otId,
    },
    ball = "POKE_BALL",
    location = request.location,
    terrain = 0,
    date = request.date,
    personality = request.personality,
  })
  mon.ivs = {
    hp = request.ivs.hp,
    attack = request.ivs.attack,
    defense = request.ivs.defense,
    speed = request.ivs.speed,
    specialAttack = request.ivs.specialAttack,
    specialDefense = request.ivs.specialDefense,
  }
  mon.contest = {
    cool = request.contest.cool,
    beauty = request.contest.beauty,
    cute = request.contest.cute,
    smart = request.contest.smart,
    tough = request.contest.tough,
    sheen = 0,
  }
  mon.heldItem = request.heldItem
  mon.nickname = request.nickname
  mon.origin.trainerName = request.otName
  mon.origin.trainerGender = request.otGender
  mon.origin.language = request.language
  -- The replaced individual values change the derived maximum, so the record
  -- keeps its own full health from the values it now carries.
  local form = self._catalog:form(request.species, mon.form)
  local derived = Stats.calculate(form.baseStats, mon.ivs, mon.evs, request.level, Personality.nature(mon.personality))
  mon.condition = { currentHp = derived.hp, effects = {} }
  return self:_finish(mon)
end

return MonFactory
