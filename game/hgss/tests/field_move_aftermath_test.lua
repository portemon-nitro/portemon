-- Field-move aftermath service: the Rock Smash wild-encounter-then-item
-- sequence and the Headbutt tree encounter, over the map's generated records
-- and the shared encounter attempt. Collaborators are the real pure rules
-- with scripted draws and a recording encounter attempt.

local Assert = require("tests.support.Assert")
local FieldMoveAftermath = require("game.hgss.src.field.FieldMoveAftermath")

local T = {}

local ITEMS = { "MAX_ETHER", "REVIVE", "HEART_SCALE", "RED_SHARD", "BLUE_SHARD", "GREEN_SHARD", "YELLOW_SHARD", "STAR_PIECE" }

local function slots()
  local out = {}
  for index = 1, 6 do
    out[index] = { species = "EEVEE", minLevel = 2, maxLevel = 3, weight = 1 }
  end
  return out
end

local function rig(opts)
  local events = {}
  local draws = opts.draws or {}
  local drawn = 0
  local fieldData = {
    rockSmash = { odds = opts.odds or 0, items = ITEMS },
    headbutt = opts.headbutt or {
      regularTrees = {},
      secretTrees = {},
      slots = { common = {}, rare = {}, secret = {} },
    },
  }
  local aftermath = FieldMoveAftermath.new({
    fieldData = function()
      return fieldData
    end,
    draw = function()
      drawn = drawn + 1
      events[#events + 1] = "draw"
      return assert(draws[drawn], "unexpected extra draw")
    end,
    leadAbility = function()
      return opts.ability
    end,
    trainerId = function()
      return opts.trainerId or 0
    end,
    frontTile = function()
      return opts.front or { x = 0, z = 0 }
    end,
    follower = function()
      return opts.follower
    end,
    attemptEncounter = function(method, modifiers)
      events[#events + 1] = "attempt:" .. method
      opts.attempted = { method = method, modifiers = modifiers }
      return opts.attempt or { kind = "none" }
    end,
    launchDetails = function(encounter)
      return { attemptId = encounter.id }
    end,
    itemNativeId = function(key)
      return "native:" .. key
    end,
  })
  return aftermath, events, opts
end

function T.rock_smash_battle_wins_before_any_item_draw()
  local aftermath, events = rig({ odds = 100, attempt = { kind = "prepared", encounter = { id = 4 } } })
  local result = aftermath:rockSmash(false)
  Assert.equal(result.kind, "battle")
  Assert.deepEqual(result.details, { attemptId = 4 })
  Assert.deepEqual(events, { "attempt:rock_smash" })
end

function T.rock_smash_without_a_battle_rolls_the_item_with_the_lead_ability()
  local aftermath, events = rig({ odds = 40, ability = "KEEN_EYE", draws = { 44, 0 } })
  local result = aftermath:rockSmash(false)
  Assert.deepEqual(result, { kind = "item", item = "native:MAX_ETHER" })
  Assert.deepEqual(events, { "attempt:rock_smash", "draw", "draw" })
  local missed = rig({ odds = 40, draws = { 40 } })
  Assert.deepEqual(missed:rockSmash(false), { kind = "none" })
end

function T.rock_smash_item_roll_uses_the_follower_bonus()
  local aftermath = rig({ odds = 40, draws = { 44, 0 } })
  Assert.equal(aftermath:rockSmash(false).kind, "none", "no bonus without the follower")
  local boosted = rig({ odds = 40, draws = { 44, 0 } })
  Assert.equal(boosted:rockSmash(true).kind, "item")
end

local function headbuttRecord()
  local record = {
    regularTrees = { { { x = 10, z = 10 } } },
    secretTrees = { { { x = 20, z = 20 } } },
    slots = { common = slots(), rare = slots(), secret = slots() },
  }
  record.slots.common[1].species = "TOTODILE"
  record.slots.rare[1].species = "CHIKORITA"
  record.slots.secret[1].species = "SHEDINJA"
  return record
end

local function headbuttSpecies(opts)
  opts.headbutt = headbuttRecord()
  opts.attempt = { kind = "prepared", encounter = { id = 9 } }
  local aftermath, events, state = rig(opts)
  local result = aftermath:headbutt()
  return result, events, state.attempted and state.attempted.modifiers.headbutt.slots[1].species
end

function T.headbutt_picks_common_rare_or_secret_slots_by_tree_and_trainer_digit()
  local result, events, species = headbuttSpecies({ trainerId = 0, front = { x = 10, z = 10 } })
  Assert.equal(result.kind, "battle")
  Assert.deepEqual(result.details, { attemptId = 9 })
  Assert.deepEqual(events, { "attempt:headbutt" })
  Assert.equal(species, "TOTODILE")
  Assert.equal(select(3, headbuttSpecies({ trainerId = 1, front = { x = 10, z = 10 } })), "CHIKORITA")
  Assert.equal(select(3, headbuttSpecies({ trainerId = 5, front = { x = 20, z = 20 } })), "SHEDINJA")
end

function T.headbutt_on_an_empty_tree_or_unknown_tile_attempts_nothing()
  local aftermath, events = rig({ headbutt = headbuttRecord(), front = { x = 99, z = 99 } })
  Assert.deepEqual(aftermath:headbutt(), { kind = "none" })
  local empty, emptyEvents = rig({ front = { x = 10, z = 10 } })
  Assert.deepEqual(empty:headbutt(), { kind = "none" })
  Assert.deepEqual(events, {})
  Assert.deepEqual(emptyEvents, {})
  -- Three trees leave one without an encounter for this trainer digit.
  local record = headbuttRecord()
  record.regularTrees = { { { x = 1, z = 1 } }, { { x = 2, z = 2 } }, { { x = 3, z = 3 } } }
  local none, noneEvents = rig({ headbutt = record, trainerId = 0, front = { x = 3, z = 3 } })
  Assert.deepEqual(none:headbutt(), { kind = "none" })
  Assert.deepEqual(noneEvents, {})
end

function T.headbutt_redirects_through_a_follower_on_the_facing_tile()
  local result, events, species = headbuttSpecies({
    trainerId = 0,
    front = { x = 10, z = 11 },
    follower = { x = 10, z = 11, facing = "north" },
  })
  Assert.equal(result.kind, "battle")
  Assert.deepEqual(events, { "attempt:headbutt" })
  Assert.equal(species, "TOTODILE")
end

return { tests = T }
