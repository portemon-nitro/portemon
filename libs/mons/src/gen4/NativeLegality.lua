-- Native representability for admitted semantic records. The projection
-- resolves identities to Generation-IV values and checks native-only field
-- widths, encodings, and status combinations before the boxed codec writes.

local MonsErrors = require("libs.mons.src.errors")
local Personality = require("libs.mons.src.gen4.Personality")
local StatusCodec = require("libs.mons.src.gen4.StatusCodec")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

---@class NativeLegality
local NativeLegality = {}

---@alias NativeLegality.Mon { schema: string, species: string, form: integer, personality: integer, experience: integer, friendship: integer, ability: string, heldItem: string, markings: integer, evs: table<string, integer>, contest: table<string, integer>, moves: { move: string, pp: integer, ppUps: integer }[], ivs: table<string, integer>, isEgg: boolean, nickname?: string, ribbons: { ds1: integer, gba: integer, ds2: integer }, fatefulEncounter: boolean, shinyLeaves: integer, egg: { location: integer, date?: { year: integer, month: integer, day: integer } }, met: { location: integer, date: { year: integer, month: integer, day: integer }, level: integer, terrain: integer }, origin: { trainerId: integer, trainerName: string, trainerGender: integer, game: string, ball: string, language: string }, pokerus: integer, mood: integer, condition?: { currentHp: integer, effects: StatusCodec.Effect[] }, capsule?: table<string, unknown>, mail?: table<string, unknown> }
---@alias NativeLegality.Projection { personality: integer, speciesId: integer, heldItemId: integer, trainerId: integer, experience: integer, friendship: integer, abilityId: integer, markings: integer, languageId: integer, evs: table<string, integer>, contest: table<string, integer>, ribbonsDs1: integer, moves: { id: integer, pp: integer, ppUps: integer }[], ivs: table<string, integer>, isEgg: boolean, hasNickname: boolean, ribbonsGba: integer, fateful: boolean, genderCode: integer, form: integer, leaves: integer, nicknameText: string, gameId: integer, ribbonsDs2: integer, otText: string, eggYear: integer, eggMonth: integer, eggDay: integer, metYear: integer, metMonth: integer, metDay: integer, eggLocation: integer, metLocation: integer, pokerus: integer, ballId: integer, metLevel: integer, trainerGender: integer, terrain: integer, mood: integer }

NativeLegality.NICKNAME_CAPACITY = 11
NativeLegality.OT_NAME_CAPACITY = 8

---@param identity string
---@param field string
---@param nativeId integer?
local function requireNativeId(identity, field, nativeId)
  if nativeId == nil then
    MonsErrors.raise(MonsErrors.LEGALITY_INVALID, field .. " " .. identity .. " has no native identity", {
      identity = identity,
      field = field,
    })
  end
end
---@param text string
---@param charmap table<string, unknown>
---@param capacity integer
---@param what string
local function checkShapedText(text, charmap, capacity, what)
  if type(text) ~= "string" then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, what .. " must be a string", {})
  end
  local glyphs = 0
  for glyph in Utf8Glyphs.iter(text) do
    if charmap[glyph] == nil then
      MonsErrors.raise(MonsErrors.RECORD_INVALID, what .. " carries an unencodable glyph", {})
    end
    glyphs = glyphs + 1
  end
  if glyphs + 1 > capacity then
    MonsErrors.raise(MonsErrors.RECORD_INVALID, what .. " exceeds its glyph capacity", {})
  end
end

---@param mon NativeLegality.Mon
---@param context MonsSave.Context
---@return NativeLegality.Projection
function NativeLegality.project(mon, context)
  assert(type(mon) == "table", "legality projection requires a mon record")
  assert(type(context) == "table", "legality projection requires a context")
  assert(context.catalog ~= nil, "legality projection requires a catalog")
  local catalog = context.catalog

  local species = catalog:species(mon.species)
  requireNativeId(mon.species, "species", species.nativeId)
  if mon.form < 0 or mon.form > 31 then
    MonsErrors.raise(MonsErrors.LEGALITY_INVALID, "form exceeds its native field", { form = mon.form })
  end

  local abilityDefinition = catalog:ability(mon.ability)
  requireNativeId(mon.ability, "ability", abilityDefinition.nativeId)
  local heldDefinition = catalog:item(mon.heldItem)
  requireNativeId(mon.heldItem, "held item", heldDefinition.nativeId)
  local ballDefinition = catalog:item(mon.origin.ball)
  requireNativeId(mon.origin.ball, "ball", ballDefinition.nativeId)

  local moves = {}
  for _, entry in ipairs(mon.moves) do
    local definition = catalog:move(entry.move)
    requireNativeId(entry.move, "move", definition.nativeId)
    moves[#moves + 1] = { id = definition.nativeId, pp = entry.pp, ppUps = entry.ppUps }
  end

  if mon.condition ~= nil then
    -- The boxed form carries no party status, so the projection only
    -- proves the semantic conditions encode back to a native word.
    StatusCodec.project(mon.condition.effects)
  end

  local gender = Personality.gender(species.genderRatio, mon.personality)
  local genderCode = 0
  if gender == "male" then
    genderCode = 1
  elseif gender == "female" then
    genderCode = 2
  end

  local nicknameText = mon.nickname
  if nicknameText == nil then
    nicknameText = species.name
    checkShapedText(nicknameText, context.charmap, NativeLegality.NICKNAME_CAPACITY, "nickname")
  end

  return {
    personality = mon.personality,
    speciesId = species.nativeId,
    heldItemId = heldDefinition.nativeId,
    trainerId = mon.origin.trainerId,
    experience = mon.experience,
    friendship = mon.friendship,
    abilityId = abilityDefinition.nativeId,
    markings = mon.markings,
    languageId = context.languages[mon.origin.language] --[[@as integer]],
    evs = {
      hp = mon.evs.hp,
      attack = mon.evs.attack,
      defense = mon.evs.defense,
      speed = mon.evs.speed,
      specialAttack = mon.evs.specialAttack,
      specialDefense = mon.evs.specialDefense,
    },
    contest = {
      cool = mon.contest.cool,
      beauty = mon.contest.beauty,
      cute = mon.contest.cute,
      smart = mon.contest.smart,
      tough = mon.contest.tough,
      sheen = mon.contest.sheen,
    },
    ribbonsDs1 = mon.ribbons.ds1,
    moves = moves,
    ivs = {
      hp = mon.ivs.hp,
      attack = mon.ivs.attack,
      defense = mon.ivs.defense,
      speed = mon.ivs.speed,
      specialAttack = mon.ivs.specialAttack,
      specialDefense = mon.ivs.specialDefense,
    },
    isEgg = mon.isEgg,
    hasNickname = mon.nickname ~= nil,
    ribbonsGba = mon.ribbons.gba,
    fateful = mon.fatefulEncounter,
    genderCode = genderCode,
    form = mon.form,
    leaves = mon.shinyLeaves,
    nicknameText = nicknameText,
    gameId = context.games[mon.origin.game] --[[@as integer]],
    ribbonsDs2 = mon.ribbons.ds2,
    otText = mon.origin.trainerName,
    eggYear = mon.egg.date ~= nil and mon.egg.date.year or 0,
    eggMonth = mon.egg.date ~= nil and mon.egg.date.month or 0,
    eggDay = mon.egg.date ~= nil and mon.egg.date.day or 0,
    metYear = mon.met.date.year,
    metMonth = mon.met.date.month,
    metDay = mon.met.date.day,
    eggLocation = mon.egg.location,
    metLocation = mon.met.location,
    pokerus = mon.pokerus,
    ballId = ballDefinition.nativeId,
    metLevel = mon.met.level,
    trainerGender = mon.origin.trainerGender,
    terrain = mon.met.terrain,
    mood = mon.mood,
  }
end

return NativeLegality
