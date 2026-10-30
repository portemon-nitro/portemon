-- Decoders for the per-map field-move encounter members of the retail ROM:
-- the rock smash member (a/2/5/3: u16 item odds, u16 item table type) and
-- the headbutt member (a/2/5/2: HeadbuttEncounterData, u16 regular and secret
-- tree counts, three 6-slot tables of u16 species / u8 min / u8 max, then s16
-- coordinate pairs in groups of six per tree, padded with -1). The source tool
-- omits the whole body when the regular tree list is empty. Both project to
-- semantic records; source member identities stay with the caller. Pure
-- module: no love dependency.

local BinaryReader = require("libs.codec.src.BinaryReader")
local Errors = require("libs.errors.src.Errors")
local FieldMoveSources = require("romdump.src.config.FieldMoveSources")
local MonSources = require("romdump.src.config.MonSources")

---@class FieldMoveEncounterData
local FieldMoveEncounterData = {}

local ROCK_SMASH_MEMBER_SIZE = 4
local MAX_ODDS = 100
local SLOT_COUNT = 6
local SLOT_SIZE = 4
local COORDS_PER_TREE = 6
local COORD_SIZE = 4
local HEADER_SIZE = 4

---@param code string
---@param message string
---@param context table<string, unknown>
---@return nil, Errors.Error
local function fail(code, message, context)
  return nil, Errors.new(code, message, context --[[@as Errors.Context]])
end

-- Decode one rock smash member into the semantic odds and its 8 item keys.
---@param bytes string
---@param versionId string heartgold or soulsilver
---@return { odds: integer, items: string[] }|nil record, Errors.Error|nil err
function FieldMoveEncounterData.decodeRockSmash(bytes, versionId)
  if type(bytes) ~= "string" or #bytes ~= ROCK_SMASH_MEMBER_SIZE then
    return fail(
      "FIELD_ROCK_SMASH_BAD_MEMBER",
      "rock smash member must be 4 bytes",
      { size = type(bytes) == "string" and #bytes or nil }
    )
  end
  local reader = BinaryReader.new(bytes, "rock smash member")
  local odds = reader:u16le(0)
  local tableType = reader:u16le(2)
  if odds > MAX_ODDS then
    return fail("FIELD_ROCK_SMASH_BAD_MEMBER", "rock smash odds exceed 100", { odds = odds })
  end
  -- A zero-odds map never reads its table type.
  local items = FieldMoveSources.ROCK_SMASH_ITEM_TABLES[odds == 0 and 0 or tableType]
  if items == nil then
    return fail("FIELD_ROCK_SMASH_BAD_MEMBER", "rock smash item table type is unknown", { type = tableType })
  end
  local table = items[versionId]
  assert(table ~= nil, "rock smash item tables cover every supported version")
  local copy = {}
  for index, key in ipairs(table) do
    copy[index] = key
  end
  return { odds = odds, items = copy }
end

local function s16(reader, offset)
  local value = reader:u16le(offset)
  if value >= 0x8000 then
    return value - 0x10000
  end
  return value
end

local function decodeSlots(reader, offset)
  local out = {}
  for index = 0, SLOT_COUNT - 1 do
    local at = offset + index * SLOT_SIZE
    local speciesId = reader:u16le(at)
    local species = MonSources.speciesKeys[speciesId]
    if species == nil then
      return nil, speciesId
    end
    out[index + 1] = {
      species = species,
      minLevel = reader:u8(at + 2),
      maxLevel = reader:u8(at + 3),
      weight = FieldMoveSources.HEADBUTT_SLOT_WEIGHTS[index + 1],
    }
  end
  return out
end

local function decodeTrees(reader, offset, count)
  local trees = {}
  for tree = 0, count - 1 do
    local coords = {}
    for index = 0, COORDS_PER_TREE - 1 do
      local at = offset + (tree * COORDS_PER_TREE + index) * COORD_SIZE
      local x = s16(reader, at)
      local z = s16(reader, at + 2)
      if not (x == -1 and z == -1) then
        coords[#coords + 1] = { x = x, z = z }
      end
    end
    trees[tree + 1] = coords
  end
  return trees
end

-- Decode one headbutt member into the semantic tree groups and weighted slot
-- tables. Coordinates are the source's global tile coordinates.
---@param bytes string
---@return table<string, unknown>|nil record, Errors.Error|nil err
function FieldMoveEncounterData.decodeHeadbutt(bytes)
  if type(bytes) ~= "string" or #bytes < HEADER_SIZE then
    return fail(
      "FIELD_HEADBUTT_BAD_MEMBER",
      "headbutt member lacks its header",
      { size = type(bytes) == "string" and #bytes or nil }
    )
  end
  local reader = BinaryReader.new(bytes, "headbutt member")
  local regularCount = reader:u16le(0)
  local secretCount = reader:u16le(2)
  if regularCount == 0 then
    return { regularTrees = {}, secretTrees = {}, slots = { common = {}, rare = {}, secret = {} } }
  end
  local slotBytes = SLOT_COUNT * SLOT_SIZE
  local coordsOffset = HEADER_SIZE + 3 * slotBytes
  local expected = coordsOffset + (regularCount + secretCount) * COORDS_PER_TREE * COORD_SIZE
  if #bytes ~= expected then
    return fail("FIELD_HEADBUTT_BAD_MEMBER", "headbutt member size does not match its tree counts", {
      size = #bytes,
      expected = expected,
    })
  end
  local slots = {}
  for tableIndex, name in ipairs({ "common", "rare", "secret" }) do
    local decoded, badSpecies = decodeSlots(reader, HEADER_SIZE + (tableIndex - 1) * slotBytes)
    if decoded == nil then
      return fail("FIELD_HEADBUTT_BAD_MEMBER", "headbutt slot names an unknown species", { species = badSpecies })
    end
    slots[name] = decoded
  end
  local regularTrees = decodeTrees(reader, coordsOffset, regularCount)
  local secretTrees = decodeTrees(reader, coordsOffset + regularCount * COORDS_PER_TREE * COORD_SIZE, secretCount)
  return { regularTrees = regularTrees, secretTrees = secretTrees, slots = slots }
end

return FieldMoveEncounterData
