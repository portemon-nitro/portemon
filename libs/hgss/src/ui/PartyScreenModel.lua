-- The party-screen view projection: one fresh immutable six-slot model per
-- build. Occupied slots carry the nickname-or-species display name, the
-- service-derived level and max HP, the personality-derived gender, live
-- current HP and its fraction, the source status key, the catalog (or
-- egg) icon key, egg state, the semantic held-item key, the capsule
-- record (or nil), learned moves in move-slot order as semantic records,
-- and the six-bit shiny-leaf mask. Empty slots carry position and
-- occupancy only. Every derived value comes from its domain owner (Mon,
-- Personality, the HgssMonService derivation seam, the mon catalog); this
-- module copies no stat, level, gender, or icon formula. Pure module:
-- no love, no I/O.

local Mon = require("libs.mons.src.Mon")
local MonCache = require("libs.assets.src.MonCache")
local Personality = require("libs.mons.src.gen4.Personality")
local PartyScreenTheme = require("libs.hgss.src.ui.PartyScreenTheme")

---@class PartyScreenModel
local PartyScreenModel = {}

PartyScreenModel.SLOT_COUNT = 6

---@param service HgssMonService the live mon service (partyCount/partyRevision/partyMon/partyMonDerived/catalog)
---@param mon table<string, unknown> an owned party mon copy
---@return string
local function iconKeyFor(service, mon)
  if mon.isEgg then
    return MonCache.iconSelector(mon.species, mon.form, true)
  end
  return service:catalog():iconSelection(mon)
end

---@param mon table<string, unknown>
---@return { key: string, pp: integer, ppUps: integer }[]
local function projectMoves(mon)
  local moves = {}
  local entries = assert(mon.moves, "party mons carry their move entries")
  assert(type(entries) == "table", "party moves arrive as an array")
  for index, entry in ipairs(entries) do
    assert(type(entry) == "table", "move entry " .. index .. " is a record")
    assert(type(entry.move) == "string", "move entry " .. index .. " names its semantic key")
    assert(type(entry.pp) == "number", "move entry " .. index .. " carries power points")
    assert(type(entry.ppUps) == "number", "move entry " .. index .. " carries power-point ups")
    moves[index] = { key = entry.move, pp = entry.pp, ppUps = entry.ppUps }
  end
  return moves
end

---@param service HgssMonService
---@param slot0 integer
---@param isEligible fun(slot: integer): boolean
---@return table<string, unknown>
local function projectSlot(service, slot0, isEligible)
  local record = { slot = slot0, occupied = false, eligible = false }
  if slot0 >= service:partyCount() then
    return record
  end
  local mon = service:partyMon(slot0)
  local derived = service:partyMonDerived(slot0)
  local catalog = service:catalog()
  local species = catalog:species(mon.species)
  assert(type(derived.maxHp) == "number" and derived.maxHp > 0, "party max HP derives positive")
  assert(mon.condition.currentHp <= derived.maxHp, "current HP cannot exceed derived max HP")
  record.occupied = true
  record.eligible = isEligible(slot0) == true
  record.iconKey = iconKeyFor(service, mon)
  record.displayName = Mon.displayName(mon, catalog)
  record.level = derived.level
  record.gender = Personality.gender(species.genderRatio, mon.personality)
  record.status = PartyScreenTheme.statusKey(mon.condition.status, mon.condition.currentHp)
  record.currentHp = mon.condition.currentHp
  record.maxHp = derived.maxHp
  record.hpFraction = mon.condition.currentHp / derived.maxHp
  record.isEgg = mon.isEgg == true
  local heldItem = mon.heldItem
  assert(type(heldItem) == "string", "party mons carry their held-item key")
  record.heldItem = heldItem
  if mon.capsule ~= nil then
    assert(type(mon.capsule) == "table", "party capsules arrive as records")
    if mon.capsule.id ~= nil and mon.capsule.id ~= 0 then
      record.capsule = { id = mon.capsule.id, seals = mon.capsule.seals }
    end
  end
  record.moves = projectMoves(mon)
  local shinyLeaves = mon.shinyLeaves or 0
  assert(
    type(shinyLeaves) == "number" and shinyLeaves % 1 == 0 and shinyLeaves >= 0 and shinyLeaves <= 63,
    "party mons carry a six-bit leaf mask"
  )
  record.shinyLeaves = shinyLeaves
  return record
end

---@param service HgssMonService the live mon service
---@param opts { isEligible?: fun(slot: integer): boolean }?
---@return { revision: integer, slots: table[] }
function PartyScreenModel.build(service, opts)
  assert(type(service) == "table", "the party view needs the live mon service")
  assert(type(service.partyCount) == "function", "the party view needs the party count")
  assert(type(service.partyRevision) == "function", "the party view needs the party revision")
  assert(type(service.partyMon) == "function", "the party view needs party reads")
  assert(type(service.partyMonDerived) == "function", "the party view needs derived level and max HP")
  assert(type(service.catalog) == "function", "the party view needs the mon catalog")
  opts = opts or {}
  assert(type(opts) == "table", "the party view options must be a record")
  local isEligible = opts.isEligible
  if isEligible == nil then
    local function allEligible(_)
      return true
    end
    isEligible = allEligible
  end
  assert(type(isEligible) == "function", "slot eligibility must be a predicate")
  local slots = {}
  for slot0 = 0, PartyScreenModel.SLOT_COUNT - 1 do
    slots[slot0 + 1] = projectSlot(service, slot0, isEligible)
  end
  return { revision = service:partyRevision(), slots = slots }
end

return PartyScreenModel
