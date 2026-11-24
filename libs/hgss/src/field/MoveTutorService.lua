-- The Move Reminder's and the singleton move tutor's domain queries over the
-- canonical party: the source's ordered relearn list and the one teaching
-- publication. Source authority: src/move_relearner.c
-- (MoveRelearner_GetEligibleLevelUpMoves, MoveRelearner_IsValidMove) and
-- src/application/move_relearner/move_relearner_app.c
-- (MoveRelearner_TeachMove).
--
-- The service owns no state of its own: every read comes from the live mon
-- service and its validated catalog, and every write goes through the owned
-- prepared publication with the caller's expected party revision. Nothing here
-- charges a fee, awards friendship or touches the Bag: the source script owns
-- the Heart Scale and the tutor's own gates.

local Experience = require("libs.mons.src.gen4.Experience")

---@class MoveTutorService
---@field private _mons table<string, unknown> the live canonical mon service
local MoveTutorService = {}
MoveTutorService.__index = MoveTutorService

---@param opts { mons: table<string, unknown> }
---@return MoveTutorService
function MoveTutorService.new(opts)
  assert(type(opts) == "table", "the move tutor service requires its owner")
  local mons = assert(opts.mons, "the move tutor service borrows the live mon service")
  assert(type(mons.partyMon) == "function" and type(mons.catalog) == "function", "the service needs the mon owner")
  return setmetatable({ _mons = mons }, MoveTutorService)
end

---@param slot0 integer
---@return table<string, unknown> the live mon record
function MoveTutorService:_mon(slot0)
  assert(type(slot0) == "number" and slot0 % 1 == 0 and slot0 >= 0, "a move query names a party slot")
  return self._mons:partyMon(slot0)
end

-- The mon's level as the source reads it (MON_DATA_LEVEL, derived from the
-- record's own experience and growth curve).
---@param mon table<string, unknown>
---@return integer
function MoveTutorService:levelOf(mon)
  local catalog = self._mons:catalog()
  local species = catalog:species(mon.species)
  local curve = catalog:growthCurve(species.growthCurve)
  return Experience.level(curve, assert(mon.experience, "a stored mon carries its experience"))
end

-- MoveRelearner_GetEligibleLevelUpMoves: the current form's level-up list in
-- source order, skipping entries above the mon's level, dropping moves the mon
-- already knows and repeating an entry only once. A form entry may legitimately
-- appear more than once (a repeated level-1 entry), so the list is the source
-- table's own order, not a sorted or unique catalog.
---@param slot0 integer
---@return string[] ordered eligible move keys
function MoveTutorService:eligibleRelearnMoves(slot0)
  local mon = self:_mon(slot0)
  local catalog = self._mons:catalog()
  local level = self:levelOf(mon)
  local form = catalog:form(mon.species, assert(mon.form, "a stored mon carries its form"))
  local known = {}
  for _, entry in ipairs(assert(mon.moves, "a stored mon carries its moves")) do
    known[entry.move] = true
  end
  local seen = {}
  local eligible = {}
  for _, entry in ipairs(assert(form.levelUpMoves, "a form carries its level-up list")) do
    if entry.level <= level and not known[entry.move] and not seen[entry.move] then
      seen[entry.move] = true
      eligible[#eligible + 1] = entry.move
    end
  end
  return eligible
end

-- ScrCmd_MonHasRelearnableMoves: TRUE while the ordered list carries one entry.
---@param slot0 integer
---@return boolean
function MoveTutorService:hasRelearnableMoves(slot0)
  return #self:eligibleRelearnMoves(slot0) > 0
end

-- MoveRelearner_TeachMove: one selected move lands in the target slot with the
-- move's base PP and no PP Ups, exactly where the source's moveSlot points --
-- the known-move count when the moveset has room, the replacement Summary's
-- chosen slot otherwise. The whole record publishes once through the owned
-- prepared path, so a stale revision leaves the party untouched.
---@param slot0 integer
---@param move string move key the caller selected
---@param moveSlot0 integer zero-based target move row
---@param expectedRevision integer the caller's observed party revision
---@return { kind: "changed"|"stale" }
function MoveTutorService:teach(slot0, move, moveSlot0, expectedRevision)
  local mon = self:_mon(slot0)
  assert(type(move) == "string" and move ~= "", "teaching names the selected move")
  assert(type(moveSlot0) == "number" and moveSlot0 % 1 == 0, "teaching names its target move row")
  assert(type(expectedRevision) == "number" and expectedRevision % 1 == 0, "teaching names its party revision")
  local definition = self._mons:catalog():move(move)
  local moves = {}
  for index, entry in ipairs(assert(mon.moves, "a stored mon carries its moves")) do
    moves[index] = { move = entry.move, pp = entry.pp, ppUps = entry.ppUps }
  end
  local target = moveSlot0 + 1
  local taught = { move = move, pp = definition.basePp, ppUps = 0 }
  if target <= #moves then
    moves[target] = taught
  elseif target == #moves + 1 and #moves < 4 then
    moves[target] = taught
  else
    error("the tutor target row is outside the learned moveset", 0)
  end
  mon.moves = moves
  local preparation, reason = self._mons:preparePartyChanges(expectedRevision, { { slot = slot0, mon = mon } })
  if preparation == nil then
    assert(reason == "stale", "preparation refuses stale revisions loudly")
    return { kind = "stale" }
  end
  preparation.publish()
  return { kind = "changed" }
end

return MoveTutorService
