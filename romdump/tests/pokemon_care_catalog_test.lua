-- Source projection of the Day Care breeding tables and the NPC trade table:
-- the personal egg-species table becomes the semantic mother-to-offspring map,
-- the personal egg-move list becomes ordered move keys per species, the source
-- incense pairs travel beside them, and the thirteen trade records keep their
-- exact identity columns with the nickname and OT-name messages resolved. The
-- compiler rejects malformed source data instead of substituting a plausible
-- table.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")
local ItemSources = require("romdump.src.config.ItemSources")
local MonSources = require("romdump.src.config.MonSources")
local PokemonCareAssetSchema = require("libs.assets.src.PokemonCareAssetSchema")
local PokemonCareCatalogCompiler = require("romdump.src.digest.mons.PokemonCareCatalogCompiler")
local PokemonCareSources = require("romdump.src.config.PokemonCareSources")
local charmap = require("romdump.src.catalog.hgss.charmap")

local T = {}

local PIKACHU = 25
local PICHU = 172
local SNORLAX = 143
local MUNCHLAX = 446
local MANAPHY = 490
local DITTO = 132

local function u16(value)
  return string.char(value % 256, math.floor(value / 256) % 256)
end

-- The personal egg-species table: one u16 per species, defaulting to itself.
---@param overrides table<integer, integer>
---@return string
local function eggSpeciesTable(overrides)
  local parts = {}
  for speciesId = 0, PokemonCareSources.eggSpeciesSource.lastSpecies + 1 do
    parts[#parts + 1] = u16(overrides[speciesId] or speciesId)
  end
  return table.concat(parts)
end

-- LoadEggMoves' flat list: headers above the header base open each block.
---@param blocks table<integer, integer[]>
---@return string
local function eggMoveList(blocks)
  local parts = {}
  for _, speciesId in ipairs({ PIKACHU, SNORLAX, DITTO }) do
    local moves = blocks[speciesId]
    if moves ~= nil then
      parts[#parts + 1] = u16(PokemonCareSources.eggMoveSource.headerBase + speciesId)
      for _, moveId in ipairs(moves) do
        parts[#parts + 1] = u16(moveId)
      end
    end
  end
  return table.concat(parts)
end

local EOS_UNIT = 0xFFFF

---@param text string
---@return integer[] message code units ending with EOS
local function codes(text)
  local byGlyph = {}
  for code, glyph in pairs(charmap.glyphs) do
    byGlyph[glyph] = code
  end
  local units = {}
  for index = 1, #text do
    local code = byGlyph[text:sub(index, index)]
    assert(code ~= nil, "the charmap carries the fixture glyph " .. text:sub(index, index))
    units[#units + 1] = code
  end
  units[#units + 1] = EOS_UNIT
  return units
end

local SPECIES_IDS = {}
for nativeId, key in pairs(MonSources.speciesKeys) do
  SPECIES_IDS[key] = nativeId
end
local ITEM_IDS = {}
for nativeId, key in pairs(ItemSources.itemKeys) do
  ITEM_IDS[key] = nativeId
end

---@param overrides table<string, unknown>?
---@return string one 84-byte trade member
local function tradeMember(overrides)
  local record = {
    offeredSpecies = "ONIX",
    requestedSpecies = "BELLSPROUT",
    personality = 9711,
    otId = 48926,
    ivs = { hp = 25, attack = 20, defense = 25, speed = 15, specialAttack = 15, specialDefense = 15 },
    heldItem = "PERSIM_BERRY",
    otGender = 0,
    language = 2,
    ability = 5,
    sheen = 0,
    unusedFlag = 0,
  }
  for key, value in pairs(overrides or {}) do
    record[key] = value
  end
  local ivs = record.ivs
  local function u32(value)
    return string.char(
      value % 256,
      math.floor(value / 256) % 256,
      math.floor(value / 65536) % 256,
      math.floor(value / 16777216) % 256
    )
  end
  -- An unknown identity writes the source column as zero so the compiler, not
  -- the fixture, reports the bad species.
  local function speciesColumn(key)
    if type(key) == "number" then
      return u32(key)
    end
    return u32(SPECIES_IDS[key] or 0)
  end

  local parts = {
    speciesColumn(record.offeredSpecies),
    u32(ivs.hp),
    u32(ivs.attack),
    u32(ivs.defense),
    u32(ivs.speed),
    u32(ivs.specialAttack),
    u32(ivs.specialDefense),
    u32(record.ability),
    u32(record.otId),
    u32(0),
    u32(0),
    u32(0),
    u32(0),
    u32(0),
    u32(record.personality),
    u32(ITEM_IDS[record.heldItem] or 0),
    u32(record.otGender),
    u32(record.sheen),
    u32(record.language),
    speciesColumn(record.requestedSpecies),
    u32(record.unusedFlag),
  }
  return table.concat(parts)
end

-- Bank 200 carries the trade nicknames at 0..12 and the OT names at 13..25.
local function tradeMessageBank()
  local messages = {}
  for tradeId = 0, PokemonCareSources.tradeTable.count - 1 do
    messages[tradeId + 1] = codes("Trade" .. tostring(tradeId))
    messages[tradeId + 1 + PokemonCareSources.tradeMessages.otNameOffset] = codes("Ot" .. tostring(tradeId))
  end
  return FieldMessageBank.encodeForTests(messages, 7)
end

local TUTOR = PokemonCareSources.tutorLearnsets
local MUD_SLAP_INDEX = 1
local HEADBUTT_INDEX = 51

-- fielddata/wazaoshie/waza_oshie.bin: one eight-byte bit field per species
-- identity with SPECIES_EGG and SPECIES_BAD_EGG removed. A bit at inventory
-- index j means that row of the source tutor inventory is learnable.
---@param learnable table<integer, integer[]>? member id -> inventory indexes
---@return string
local function tutorTable(learnable)
  local rows = {}
  for member = TUTOR.firstSpecies, TUTOR.lastFormSpecies do
    if member ~= TUTOR.eggSpecies and member ~= TUTOR.badEggSpecies then
      rows[#rows + 1] = member
    end
  end
  local parts = {}
  for _, member in ipairs(rows) do
    local bytes = { 0, 0, 0, 0, 0, 0, 0, 0 }
    for _, index in ipairs((learnable or {})[member] or {}) do
      local byteIndex = math.floor(index / 8) + 1
      bytes[byteIndex] = bytes[byteIndex] + 2 ^ (index % 8)
    end
    for index = 1, 8 do
      parts[#parts + 1] = string.char(bytes[index])
    end
  end
  return table.concat(parts)
end

---@param options { eggSpecies: string, eggMoves: string, tradeMembers: table<integer, string>?, tradeBank: string?, tutors: string? }?
---@return table romFs-shaped source reader
local function romFsFor(options)
  options = options or {}
  local eggSpecies = options.eggSpecies
    or eggSpeciesTable({ [PIKACHU] = PICHU, [SNORLAX] = MUNCHLAX, [MANAPHY] = MANAPHY, [DITTO] = DITTO })
  local eggMoves = options.eggMoves or eggMoveList({ [PIKACHU] = { 179, 117 }, [SNORLAX] = { 187 } })
  -- Per-record overrides: every source member exists unless a test replaces it.
  local tradeOverrides = options.tradeMembers or {}
  local tradeMembers = {}
  for tradeId = 0, PokemonCareSources.tradeTable.count - 1 do
    tradeMembers[tradeId] = tradeOverrides[tradeId] or tradeMember()
  end
  local tradeBank = options.tradeBank or tradeMessageBank()
  local tutorBytes = options.tutors
  if tutorBytes == nil then
    local learnable = { [1] = { MUD_SLAP_INDEX, HEADBUTT_INDEX }, [TUTOR.badEggSpecies + 6] = { MUD_SLAP_INDEX } }
    tutorBytes = tutorTable(learnable)
  end
  local reads = {}
  return {
    readSourcePath = function(_, path)
      reads[#reads + 1] = path
      if path == TUTOR.path then
        return tutorBytes
      end
      if path ~= PokemonCareSources.eggSpeciesSource.path then
        return nil, Errors.new("ROMFS_PATH_UNKNOWN", "no such source file", { sourcePath = path })
      end
      return eggSpecies
    end,
    openNarc = function(_, alias)
      if alias == PokemonCareSources.eggMoveSource.alias then
        return {
          readMember = function(_, memberId)
            if memberId ~= PokemonCareSources.eggMoveSource.memberId then
              return nil, Errors.new("NARC_MEMBER_MISSING", "no such member", { memberId = memberId })
            end
            return eggMoves
          end,
        }
      end
      if alias == PokemonCareSources.tradeTable.alias then
        return {
          readMember = function(_, memberId)
            local member = tradeMembers[memberId]
            if member == nil then
              return nil, Errors.new("NARC_MEMBER_MISSING", "no such member", { memberId = memberId })
            end
            return member
          end,
        }
      end
      if alias == PokemonCareSources.tradeMessages.alias then
        return {
          readMember = function(_, memberId)
            if memberId ~= PokemonCareSources.tradeMessages.memberId then
              return nil, Errors.new("NARC_MEMBER_MISSING", "no such member", { memberId = memberId })
            end
            return tradeBank
          end,
        }
      end
      return nil, Errors.new("ROMFS_NARC_UNRESOLVED", "no such archive", { alias = alias })
    end,
    reads = reads,
  }
end

function T.compiles_the_source_breeding_tables_into_semantic_keys()
  local catalog = assert(PokemonCareCatalogCompiler.compile(romFsFor()))
  Assert.equal(catalog.schema, PokemonCareAssetSchema.CATALOG_SCHEMA, "the catalog carries its own schema")
  Assert.equal(catalog.eggSpecies.PIKACHU, "PICHU", "the mother resolves through the egg-species table")
  Assert.equal(catalog.eggSpecies.SNORLAX, "MUNCHLAX", "an incense baby stays the source egg species")
  Assert.equal(catalog.eggSpecies.MANAPHY, "MANAPHY", "the Manaphy override belongs to the runtime rule")
  Assert.equal(catalog.eggSpecies.DITTO, "DITTO", "a Ditto entry keeps its own identity")
  Assert.deepEqual(catalog.eggMoves.PIKACHU, { "REVERSAL", "BIDE" }, "egg moves keep source order")
  Assert.deepEqual(catalog.eggMoves.SNORLAX, { "BELLY_DRUM" }, "each block carries its own moves")
  Assert.isNil(catalog.eggMoves.DITTO, "a species without an egg-move block publishes none")
  Assert.equal(#catalog.incense, #PokemonCareSources.incenseRows, "every source incense pair travels")
  Assert.deepEqual(catalog.incense[5], { baby = "MUNCHLAX", item = "FULL_INCENSE", parent = "SNORLAX" })
  Assert.isTrue(PokemonCareAssetSchema.isValidCatalog(catalog), "the compiled catalog satisfies its schema")
end

-- The Frontier move tutor projection: the source inventory keeps its order,
-- its prices and its tutor assignment, and each species publishes the moves its
-- compatibility row names, with the five form families carrying their own row.
function T.projects_the_source_move_tutor_inventory_and_compatibility_rows()
  local catalog = assert(PokemonCareCatalogCompiler.compile(romFsFor()))
  Assert.equal(#catalog.tutors.moves, 52, "the source inventory carries its fifty-two rows")
  Assert.deepEqual(catalog.tutors.moves[1], { move = "DIVE", cost = 40, npc = "top_left" }, "the first row keeps its order")
  Assert.deepEqual(catalog.tutors.moves[2], { move = "MUD_SLAP", cost = 32, npc = "top_right" })
  Assert.deepEqual(
    catalog.tutors.moves[52],
    { move = "HEADBUTT", cost = 0, npc = "headbutt" },
    "the zero-cost Headbutt lesson closes the inventory"
  )
  Assert.deepEqual(
    catalog.tutors.learnsets.BULBASAUR[1],
    { "MUD_SLAP", "HEADBUTT" },
    "the species row publishes the learnable moves in inventory order"
  )
  -- Giratina's origin form reads its own compatibility row, published beside
  -- the base list the other forms share.
  local originMember = TUTOR.badEggSpecies + 6
  Assert.equal(#catalog.tutors.learnsets.GIRATINA, 2, "the form family publishes its own row")
  Assert.deepEqual(catalog.tutors.learnsets.GIRATINA[1], {}, "the base row names no tutor move")
  Assert.deepEqual(
    catalog.tutors.learnsets.GIRATINA[2],
    { "MUD_SLAP" },
    "the origin form reads the row the source's form switch selects"
  )
  Assert.isTrue(originMember > TUTOR.lastSpecies, "the form row follows the two egg sentinels")
  Assert.isTrue(PokemonCareAssetSchema.isValidCatalog(catalog), "the compiled catalog satisfies its schema")
end

function T.rejects_a_move_tutor_table_that_is_not_one_row_per_species()
  local bytes = tutorTable()
  local noLearnable = assert(PokemonCareCatalogCompiler.compile(romFsFor({ tutors = bytes })))
  Assert.equal(noLearnable.tutors.moves[1].move, "DIVE", "a table without a set bit still compiles")

  local truncated = bytes:sub(1, #bytes - 8)
  local catalog, err = PokemonCareCatalogCompiler.compile(romFsFor({ tutors = truncated }))
  Assert.isNil(catalog, "a truncated tutor table never compiles")
  Assert.isTrue(Errors.is(err), "the refusal is attributed")
  Assert.equal(err.code, "POKEMON_CARE_SOURCE_TRUNCATED")
end

-- The thirteen source trade records keep their order and every published
-- identity column; the unused ability and sheen columns are dropped and the
-- nickname and OT name resolve through the source message bank.
function T.projects_the_source_trade_records()
  local catalog = assert(PokemonCareCatalogCompiler.compile(romFsFor()))
  Assert.equal(#catalog.trades, PokemonCareSources.tradeTable.count, "every source trade record travels in order")
  local first = catalog.trades[1]
  Assert.equal(first.offeredSpecies, "ONIX", "the first record offers its source species")
  Assert.equal(first.requestedSpecies, "BELLSPROUT", "the first record asks for its source species")
  Assert.equal(first.otId, 48926, "the OT id stays the source value")
  Assert.equal(first.personality, 9711, "the personality stays the source value")
  Assert.equal(first.heldItem, "PERSIM_BERRY", "the held item resolves through the item catalog")
  Assert.equal(first.language, "english", "the record language resolves to its semantic key")
  Assert.equal(first.otGender, 0, "the OT gender stays the source value")
  Assert.equal(first.nickname, "Trade0", "the nickname resolves through message bank 200")
  Assert.equal(first.otName, "Ot0", "the OT name resolves through message bank 200")
  Assert.deepEqual(first.ivs, {
    hp = 25,
    attack = 20,
    defense = 25,
    speed = 15,
    specialAttack = 15,
    specialDefense = 15,
  }, "every individual value travels")
  Assert.deepEqual(first.contest, { cool = 0, beauty = 0, cute = 0, smart = 0, tough = 0 })
  Assert.equal(first.ability, nil, "the source's unused ability column is never published")
  Assert.equal(first.sheen, nil, "the source's unused sheen column is never published")
end

function T.rejects_a_truncated_trade_record()
  local catalog, err = PokemonCareCatalogCompiler.compile(romFsFor({
    tradeMembers = { [0] = tradeMember():sub(1, 40) },
  }))
  Assert.isNil(catalog, "a truncated trade record fails the projection")
  Assert.equal(assert(err).code, "POKEMON_CARE_SOURCE_TRUNCATED", "the failure names the truncation")
end

function T.rejects_an_unknown_trade_identity()
  local catalog, err = PokemonCareCatalogCompiler.compile(romFsFor({
    tradeMembers = { [0] = tradeMember({ offeredSpecies = 9999 }) },
  }))
  Assert.isNil(catalog, "an unknown offered species fails the projection")
  Assert.equal(assert(err).code, "POKEMON_CARE_BAD_SPECIES", "the failure names the species identity")
end

function T.rejects_an_unknown_source_species()
  local catalog, err = PokemonCareCatalogCompiler.compile(romFsFor({
    eggSpecies = eggSpeciesTable({ [PIKACHU] = 600 }),
  }))
  Assert.isNil(catalog, "an unknown egg species fails the projection")
  Assert.equal(assert(err).code, "POKEMON_CARE_BAD_SPECIES", "the failure names the source identity")
end

function T.rejects_a_truncated_egg_species_table()
  local catalog, err = PokemonCareCatalogCompiler.compile(romFsFor({ eggSpecies = u16(0) .. u16(1) }))
  Assert.isNil(catalog, "a truncated table fails the projection")
  Assert.equal(assert(err).code, "POKEMON_CARE_SOURCE_TRUNCATED", "the failure names the truncation")
end

function T.rejects_an_unknown_egg_move()
  local catalog, err = PokemonCareCatalogCompiler.compile(romFsFor({
    eggMoves = eggMoveList({ [PIKACHU] = { 900 } }),
  }))
  Assert.isNil(catalog, "an unknown move fails the projection")
  Assert.equal(assert(err).code, "POKEMON_CARE_BAD_MOVE", "the failure names the move identity")
end

function T.rejects_a_block_wider_than_the_source_list()
  local moves = {}
  for index = 1, PokemonCareSources.eggMoveSource.maxMoves + 1 do
    moves[index] = index
  end
  local catalog, err = PokemonCareCatalogCompiler.compile(romFsFor({
    eggMoves = eggMoveList({ [PIKACHU] = moves }),
  }))
  Assert.isNil(catalog, "an oversized block fails the projection")
  Assert.equal(assert(err).code, "POKEMON_CARE_SOURCE_INVALID", "the failure names the block width")
end

return { tests = T }
