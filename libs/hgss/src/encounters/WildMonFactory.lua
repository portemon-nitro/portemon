-- Source wild mon identity and held-item generation. Identity stages five
-- labeled draws in fixed source order: the synchronizing-lead check first
-- when a synchronizing lead applies, the cute-charm check first when a
-- charming lead applies, then two personality draws, two
-- individual-value draws, and the single held-item roll. The fixed trace
-- is deterministic, not draw-identical to the native generator: natively
-- CreateMonWithNature loops fresh personality draws until the nature
-- matches (pokemon.c), and cute charm mints its personality
-- arithmetically with no personality draws at all
-- (GenPersonalityByGenderAndNature). Exact native personalities are
-- unreachable from any fixed trace (and from any replay whose seed history
-- diverges), so this owner fixes the positions instead: the outcome rules
-- stay native-exact (check odds, nature/gender forcing, held windows)
-- while individual values, held items, and every draw after the identity
-- sit at stable positions. Ordinary construction reuses the mon domain factory at an explicit lower boundary:
-- the labeled draws are staged here and served to the factory through a
-- single-use draw adapter, so ability, experience, moves, validation, and
-- native projection stay identical to ordinary creation. A passed
-- synchronize check forces the lead nature onto the drawn personality
-- without extra draws; a passed cute-charm check against a coerceable
-- species forces the opposite lead gender the same way, clearing the low
-- personality byte for a female wild and setting it for a male one.
-- Genderless and single-gender species never roll the check. Held items
-- follow the native percent roll against the 45/95 windows (20/80 behind
-- compound eyes), holding the shared entry unconditionally when both
-- species entries agree, else nothing below the lower window. Unknown
-- species, out-of-range levels, and unknown or mismatched lead abilities
-- fail before any draw is consumed. Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonFactory = require("libs.mons.src.gen4.MonFactory")
local Stats = require("libs.mons.src.gen4.Stats")
local U32 = require("libs.codec.src.U32")

---@class WildMonFactory
---@field private _catalog MonCatalog
---@field private _charmap table<string, integer>
---@field private _games table<string, integer>
---@field private _languages table<string, integer>
---@field private _game string
---@field private _language string
local WildMonFactory = {}
WildMonFactory.__index = WildMonFactory

WildMonFactory.SYNCHRONIZE_ABILITY = "synchronize"
WildMonFactory.COMPOUND_EYES_ABILITY = "compoundeyes"
WildMonFactory.CUTE_CHARM_ABILITY = "cute_charm"

WildMonFactory.FEMALE_FORCED_LOW_BYTE = 0
WildMonFactory.MALE_FORCED_LOW_BYTE = 255

---@class WildMonOptions
---@field profile table<string, unknown>
---@field ball string
---@field location integer
---@field terrain integer
---@field date table<string, integer>
---@field leadAbility string?
---@field leadNature integer?
---@field leadGender string?

---@class WildMonDraws
---@field personality integer
---@field ivFirst integer
---@field ivSecond integer
---@field held integer single percent roll against the held windows

---@param args { catalog: MonCatalog, items: ItemCatalog, charmap: table<string, integer>, games: table<string, integer>, languages: table<string, integer>, game: string, language: string }
---@return WildMonFactory
function WildMonFactory.new(args)
  assert(type(args) == "table", "wild construction requires an argument record")
  assert(args.catalog ~= nil, "wild construction requires a mon catalog")
  assert(type(args.charmap) == "table", "wild construction requires a charmap")
  assert(type(args.games) == "table", "wild construction requires a game table")
  assert(type(args.languages) == "table", "wild construction requires a language table")
  assert(type(args.game) == "string" and args.games[args.game] ~= nil, "wild construction game must resolve")
  assert(
    type(args.language) == "string" and args.languages[args.language] ~= nil,
    "wild construction language must resolve"
  )
  return setmetatable({
    _catalog = args.catalog,
    _charmap = args.charmap,
    _games = args.games,
    _languages = args.languages,
    _game = args.game,
    _language = args.language,
  }, WildMonFactory)
end

---@return MonsSave.Context
function WildMonFactory:_context()
  return {
    catalog = self._catalog,
    charmap = self._charmap,
    games = self._games,
    languages = self._languages,
  }
end

---@param species unknown
---@return table<string, unknown>
function WildMonFactory:_speciesOrRaise(species)
  if type(species) ~= "string" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "wild construction requires a species key", { species = species })
  end
  assert(type(species) == "string", "wild construction resolves its species key")
  local ok, definition = pcall(self._catalog.species, self._catalog, species)
  if not ok then
    if Errors.is(definition) then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "wild construction names an unknown species", { species = species })
    end
    error(definition, 0)
  end
  assert(type(definition) == "table", "the catalog carries the species definition")
  return definition
end

---@param level unknown
---@param species string
local function checkLevel(level, species)
  if type(level) ~= "number" or level % 1 ~= 0 or level < 1 or level > Stats.MAX_LEVEL then
    Errors.raise(
      "ENCOUNTER_INVALID_INPUT",
      "wild construction level must be an integer in 1.." .. Stats.MAX_LEVEL,
      { species = species, level = level }
    )
  end
end

---@param options WildMonOptions
---@return integer? forced nature, or nil without a synchronizing lead
local function checkLeadAbility(options)
  local leadAbility = options.leadAbility
  if leadAbility == nil then
    if options.leadGender ~= nil then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "a lead gender without cute charm is unused", {
        leadGender = options.leadGender,
      })
    end
    return nil
  end
  if leadAbility == WildMonFactory.COMPOUND_EYES_ABILITY then
    if options.leadNature ~= nil then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "compound eyes takes no lead nature", {
        leadNature = options.leadNature,
      })
    end
    if options.leadGender ~= nil then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "compound eyes takes no lead gender", {
        leadGender = options.leadGender,
      })
    end
    return nil
  end
  if leadAbility == WildMonFactory.CUTE_CHARM_ABILITY then
    if options.leadNature ~= nil then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "cute charm takes no lead nature", {
        leadNature = options.leadNature,
      })
    end
    return nil
  end
  if leadAbility ~= WildMonFactory.SYNCHRONIZE_ABILITY then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "wild construction names an unknown lead ability", {
      leadAbility = leadAbility,
    })
  end
  local leadNature = options.leadNature
  if type(leadNature) ~= "number" or leadNature % 1 ~= 0 or leadNature < 0 or leadNature > Stats.MAX_NATURE then
    Errors.raise(
      "ENCOUNTER_INVALID_INPUT",
      "synchronize coercion requires a lead nature in 0.." .. Stats.MAX_NATURE,
      { leadNature = leadNature }
    )
  end
  assert(type(leadNature) == "number", "coercion carries the lead nature")
  return leadNature
end

---@param options WildMonOptions
---@return string? forced opposite gender, or nil without a charming lead
local function checkCuteCharm(options)
  local leadAbility = options.leadAbility
  if leadAbility == nil or leadAbility == WildMonFactory.COMPOUND_EYES_ABILITY then
    return nil
  end
  if leadAbility ~= WildMonFactory.CUTE_CHARM_ABILITY then
    return nil
  end
  local leadGender = options.leadGender
  if leadGender ~= "male" and leadGender ~= "female" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "cute charm coercion requires a lead gender", {
      leadGender = leadGender,
    })
  end
  assert(leadGender == "male" or leadGender == "female", "coercion carries the lead gender")
  if leadGender == "male" then
    return "female"
  end
  return "male"
end

-- Whether the species can be gender-coerced: single-gender and genderless
-- ratios never roll the cute-charm check, matching the native ratio gate.
---@param speciesDef table<string, unknown>
---@return boolean
local function isGenderCoerceable(speciesDef)
  local ratio = speciesDef.genderRatio
  if type(ratio) ~= "number" or ratio % 1 ~= 0 or ratio < 0 or ratio > 255 then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "wild construction names a species with no gender ratio", {
      ratio = ratio,
    })
  end
  assert(type(ratio) == "number", "coercion reads the species gender ratio")
  return ratio ~= 0 and ratio ~= 254 and ratio ~= 255
end

---@param stream table<string, unknown>
local function checkStream(stream)
  if type(stream) ~= "table" or type(stream.nextU16) ~= "function" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "wild construction requires a labeled draw stream", {})
  end
end

-- Stages the five labeled identity draws, forcing the lead nature onto the
-- drawn personality when the synchronize check passes, or forcing the
-- opposite lead gender when the cute-charm check passes against a
-- coerceable species. At most one check ever draws: synchronize and cute
-- charm never share a lead.
---@param stream table<string, unknown>
---@param leadNature integer?
---@param forcedGender string?
---@param coerceable boolean
---@return WildMonDraws
local function drawIdentity(stream, leadNature, forcedGender, coerceable)
  assert(type(stream.nextU16) == "function", "identity draws consult the labeled stream")
  local draw = stream.nextU16
  local cause = { kind = "encounter" }
  local forced = false
  if leadNature ~= nil then
    local check = draw(stream, "synchronize", cause)
    forced = (check % 2) == 0
  elseif forcedGender ~= nil and coerceable then
    local check = draw(stream, "cute_charm", cause)
    forced = (check % 3) ~= 0
  end
  local low = draw(stream, "personality_low", cause)
  local high = draw(stream, "personality_high", cause)
  local personality = low + high * U32.HALF_BASE
  if forced then
    if leadNature ~= nil then
      assert(leadNature ~= nil, "coercion carries the lead nature")
      personality = personality - (personality % 25) + leadNature
      if personality > U32.MAX then
        personality = personality - U32.MOD
      end
    else
      assert(forcedGender == "male" or forcedGender == "female", "coercion carries the forced gender")
      -- NOTE (retail fidelity): the native coercion loops fresh draws
      -- until the gender matches; the fixed trace forces the outcome
      -- arithmetically instead. Clearing the low byte always reads
      -- female and setting it always reads male against every mixed
      -- ratio, and neither operation can overflow the personality.
      personality = personality - (personality % 256)
      if forcedGender == "male" then
        personality = personality + WildMonFactory.MALE_FORCED_LOW_BYTE
      else
        personality = personality + WildMonFactory.FEMALE_FORCED_LOW_BYTE
      end
    end
  end
  return {
    personality = personality,
    ivFirst = draw(stream, "iv_first", cause),
    ivSecond = draw(stream, "iv_second", cause),
    held = draw(stream, "held_item", cause),
  }
end

-- Serves the staged draws through the exact generator interface ordinary
-- creation consumes: the personality fills the single two-draw slot, then
-- one single slot per individual-value draw. The generator is constructed
-- locally for one creation and never escapes, so no live random state is
-- shared or reseeded.
---@param draws WildMonDraws
---@return Gen4Lcrng
local function stagedGenerator(draws)
  local pending = { draws.personality, draws.ivFirst, draws.ivSecond }
  local generator = Lcrng.new(0)
  function generator:nextU32FromTwoDraws()
    local value = table.remove(pending, 1)
    assert(value ~= nil, "ordinary creation draws its staged personality once")
    return value
  end
  function generator:nextU16()
    local value = table.remove(pending, 1)
    assert(value ~= nil, "ordinary creation draws its staged individual values once")
    return value
  end
  return generator
end

-- Selects the held item from the species entries against the single
-- percent roll. Matching common and rare entries hold unconditionally;
-- otherwise the roll keeps the common entry from the lower window, the
-- rare entry from the upper window, else nothing. Species without entries
-- still consume the roll and hold none.
---@param speciesDef table<string, unknown>
---@param heldRoll integer raw percent roll
---@param compoundEyes boolean
---@return string
function WildMonFactory:_heldItemOrRaise(speciesDef, heldRoll, compoundEyes)
  if type(heldRoll) ~= "number" or heldRoll % 1 ~= 0 or heldRoll < 0 or heldRoll > 65535 then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "wild construction requires a held roll in 0..65535", {})
  end
  assert(type(heldRoll) == "number", "held selection reads its percent roll")
  local heldItems = speciesDef.heldItems
  local commonKey = nil
  local rareKey = nil
  if type(heldItems) == "table" then
    local common = heldItems.common
    if type(common) == "table" and type(common.item) == "string" and common.item ~= "NONE" then
      commonKey = common.item
    end
    local rare = heldItems.rare
    if type(rare) == "table" and type(rare.item) == "string" and rare.item ~= "NONE" then
      rareKey = rare.item
    end
  end
  -- NOTE (retail fidelity): the native windows are 45/95 without
  -- compound eyes and 20/80 with it, against one percent roll.
  local lower = 45
  local upper = 95
  if compoundEyes then
    lower = 20
    upper = 80
  end
  local roll = heldRoll % 100
  local held = "NONE"
  if commonKey ~= nil and commonKey == rareKey then
    held = commonKey
  elseif roll >= lower then
    if roll < upper then
      held = commonKey or "NONE"
    else
      held = rareKey or "NONE"
    end
  end
  if held ~= "NONE" then
    local ok, definition = pcall(self._catalog.item, self._catalog, held)
    if not ok or type(definition) ~= "table" then
      Errors.raise("ENCOUNTER_INVALID_INPUT", "wild construction names an unknown held item", { heldItem = held })
    end
  end
  return held
end

---@param species string
---@param level integer
---@param stream table<string, unknown>
---@param options WildMonOptions
---@param leadNature integer?
---@param forcedGender string?
---@param compoundEyes boolean
---@return table<string, unknown>
function WildMonFactory:_createWithLead(species, level, stream, options, leadNature, forcedGender, compoundEyes)
  local speciesDef = self:_speciesOrRaise(species)
  checkLevel(level, species)
  checkStream(stream)
  if type(options) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "wild construction requires a capture record", { species = species })
  end
  assert(type(options) == "table", "construction reads its capture record")
  assert(compoundEyes == true or compoundEyes == false, "construction reads its compound-eyes fact")
  local draws = drawIdentity(stream, leadNature, forcedGender, isGenderCoerceable(speciesDef))
  local held = self:_heldItemOrRaise(speciesDef, draws.held, compoundEyes)
  local inner = MonFactory.new({
    catalog = self._catalog,
    rng = stagedGenerator(draws),
    charmap = self._charmap,
    games = self._games,
    languages = self._languages,
    game = self._game,
    language = self._language,
  })
  local mon = inner:createNormal({
    species = species,
    level = level,
    form = 0,
    profile = options.profile,
    ball = options.ball,
    location = options.location,
    terrain = options.terrain,
    date = options.date,
    heldItem = held,
  })
  return mon
end

-- Builds one wild mon for the given species and level. Scripted encounters
-- share the uniform trace; lead abilities never apply to them.
---@param species string
---@param level integer
---@param stream table<string, unknown>
---@param options WildMonOptions
---@return table<string, unknown>
function WildMonFactory:create(species, level, stream, options)
  if type(options) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "wild construction requires a capture record", { species = species })
  end
  assert(type(options) == "table", "construction reads its capture record")
  local leadAbility = options.leadAbility
  local compoundEyes = leadAbility == WildMonFactory.COMPOUND_EYES_ABILITY
  return self:_createWithLead(
    species,
    level,
    stream,
    options,
    checkLeadAbility(options),
    checkCuteCharm(options),
    compoundEyes
  )
end

-- Builds one scripted wild mon with a fixed species and level.
---@param species string
---@param level integer
---@param stream table<string, unknown>
---@param options WildMonOptions
---@return table<string, unknown>
function WildMonFactory:createStatic(species, level, stream, options)
  if type(options) == "table" and (options.leadAbility ~= nil or options.leadGender ~= nil) then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "scripted construction takes no lead ability", { species = species })
  end
  return self:_createWithLead(species, level, stream, options, nil, nil, false)
end

return WildMonFactory
