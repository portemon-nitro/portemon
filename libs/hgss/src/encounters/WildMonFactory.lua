-- Source wild mon identity and held-item generation. Identity consumes six
-- labeled native draws in source order: the synchronizing-lead check first
-- when a synchronizing lead applies, then two personality draws, two
-- individual-value draws, and the two uniform held-item draws. Ordinary
-- construction reuses the mon domain factory at an explicit lower boundary:
-- the labeled draws are staged here and served to the factory through a
-- single-use draw adapter, so ability, experience, moves, validation, and
-- native projection stay identical to ordinary creation. A passed
-- synchronize check forces the lead nature onto the drawn personality
-- without extra draws; held items keep the common entry on an even common
-- draw, else the rare entry on a rare draw divisible by twenty, else none.
-- Unknown species, out-of-range levels, and unknown lead abilities fail
-- before any draw is consumed. Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local Mon = require("libs.mons.src.Mon")
local MonFactory = require("libs.mons.src.gen4.MonFactory")
local NativeLegality = require("libs.mons.src.gen4.NativeLegality")
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
WildMonFactory.RARE_HELD_DIVISOR = 20

---@class WildMonOptions
---@field profile table<string, unknown>
---@field ball string
---@field location integer
---@field terrain integer
---@field date table<string, integer>
---@field leadAbility string?
---@field leadNature integer?

---@class WildMonDraws
---@field personality integer
---@field ivFirst integer
---@field ivSecond integer
---@field heldCommon integer
---@field heldRare integer

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

---@param stream table<string, unknown>
local function checkStream(stream)
  if type(stream) ~= "table" or type(stream.nextU16) ~= "function" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "wild construction requires a labeled draw stream", {})
  end
end

-- Stages the six labeled identity draws, forcing the lead nature onto the
-- drawn personality when the synchronize check passes.
---@param stream table<string, unknown>
---@param leadNature integer?
---@return WildMonDraws
local function drawIdentity(stream, leadNature)
  assert(type(stream.nextU16) == "function", "identity draws consult the labeled stream")
  local draw = stream.nextU16
  local cause = { kind = "encounter" }
  local forced = false
  if leadNature ~= nil then
    local check = draw(stream, "synchronize", cause)
    forced = (check % 2) == 0
  end
  local low = draw(stream, "personality_low", cause)
  local high = draw(stream, "personality_high", cause)
  local personality = low + high * U32.HALF_BASE
  if forced then
    assert(leadNature ~= nil, "coercion carries the lead nature")
    personality = personality - (personality % 25) + leadNature
    if personality > U32.MAX then
      personality = personality - U32.MOD
    end
  end
  return {
    personality = personality,
    ivFirst = draw(stream, "iv_first", cause),
    ivSecond = draw(stream, "iv_second", cause),
    heldCommon = draw(stream, "held_common", cause),
    heldRare = draw(stream, "held_rare", cause),
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

-- Selects the held item from the species entries against the staged uniform
-- draws. Species without entries still consume both draws and hold none.
---@param speciesDef table<string, unknown>
---@param draws WildMonDraws
---@return string
function WildMonFactory:_heldItemOrRaise(speciesDef, draws)
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
  local held = "NONE"
  if commonKey ~= nil and draws.heldCommon % 2 == 0 then
    held = commonKey
  elseif rareKey ~= nil and draws.heldRare % WildMonFactory.RARE_HELD_DIVISOR == 0 then
    held = rareKey
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
---@return table<string, unknown>
function WildMonFactory:_createWithLead(species, level, stream, options, leadNature)
  local speciesDef = self:_speciesOrRaise(species)
  checkLevel(level, species)
  checkStream(stream)
  if type(options) ~= "table" then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "wild construction requires a capture record", { species = species })
  end
  assert(type(options) == "table", "construction reads its capture record")
  local draws = drawIdentity(stream, leadNature)
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
  })
  local held = self:_heldItemOrRaise(speciesDef, draws)
  if held ~= "NONE" then
    mon.heldItem = held
    NativeLegality.project(mon, self:_context())
    mon = Mon.validate(mon, self:_context())
  end
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
  return self:_createWithLead(species, level, stream, options, checkLeadAbility(options))
end

-- Builds one scripted wild mon with a fixed species and level.
---@param species string
---@param level integer
---@param stream table<string, unknown>
---@param options WildMonOptions
---@return table<string, unknown>
function WildMonFactory:createStatic(species, level, stream, options)
  if type(options) == "table" and options.leadAbility ~= nil then
    Errors.raise("ENCOUNTER_INVALID_INPUT", "scripted construction takes no lead ability", { species = species })
  end
  return self:_createWithLead(species, level, stream, options, nil)
end

return WildMonFactory
