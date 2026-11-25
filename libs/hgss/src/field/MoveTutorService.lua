-- The Move Reminder's and the move tutors' domain queries over the canonical
-- party: the source's ordered relearn list, the one teaching publication, and
-- the Frontier tutor offers the tutor house and the Headbutt lesson ask for.
-- Source authority: src/move_relearner.c (MoveRelearner_GetEligibleLevelUpMoves,
-- MoveRelearner_IsValidMove), src/application/move_relearner/
-- move_relearner_app.c (MoveRelearner_TeachMove), and
-- src/field/scrcmd_move_tutor.c (GetLearnableTutorMoves, sTutorMoves,
-- ScrCmd_GetTutorMoveListPageCount, ScrCmd_MoveTutorChooseMove,
-- ScrCmd_TutorMoveGetPrice, ScrCmd_MonCanLearnHeadbuttFromTutor).
--
-- The service owns no state of its own: every read comes from the live mon
-- service, its validated catalog, and the generated tutor inventory, and every
-- write goes through the owned prepared publication with the caller's expected
-- party revision. Nothing here charges a fee, awards friendship or touches the
-- Bag: the source script owns the Heart Scale, the Battle Point charge and the
-- tutor's own gates.

local Errors = require("libs.errors.src.Errors")
local Experience = require("libs.mons.src.gen4.Experience")
local ScriptErrors = require("libs.script.src.errors")

-- MOVE_TUTOR_NPC_* selectors (include/constants/scrcmd.h) as the semantic names
-- the generated inventory carries.
local TUTOR_NPC_BY_SELECTOR = {
  [0] = "top_left",
  [1] = "top_right",
  [2] = "bottom_right",
  [3] = "headbutt",
}
-- GetLearnableTutorMoves' own page width (MAX_TUTOR_MOVES_PER_PAGE).
local TUTOR_PAGE_SIZE = 6

---@class MoveTutorService.TutorOffer
---@field move string semantic move key
---@field cost integer the source inventory price in Battle Points
---@field nativeId integer the source move identity the script passes back

---@class MoveTutorService
---@field private _mons table<string, unknown> the live canonical mon service
---@field private _tutors table<string, unknown> the generated tutor inventory and compatibility lists
local MoveTutorService = {}
MoveTutorService.__index = MoveTutorService

---@param opts { mons: table<string, unknown>, tutors: table<string, unknown> }
---@return MoveTutorService
function MoveTutorService.new(opts)
  assert(type(opts) == "table", "the move tutor service requires its owner")
  local mons = assert(opts.mons, "the move tutor service borrows the live mon service")
  assert(type(mons.partyMon) == "function" and type(mons.catalog) == "function", "the service needs the mon owner")
  local tutors = assert(opts.tutors, "the move tutor service reads the generated tutor inventory")
  assert(type(tutors.moves) == "table" and type(tutors.learnsets) == "table", "the tutor inventory is complete")
  return setmetatable({ _mons = mons, _tutors = tutors }, MoveTutorService)
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

---@param selector integer raw source tutor selector
---@return string
local function tutorNpcName(selector)
  local name = type(selector) == "number" and TUTOR_NPC_BY_SELECTOR[selector] or nil
  if name == nil then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the tutor command names a source tutor", {
      tutorNpc = selector,
    })
  end
  assert(type(name) == "string", "the selector table carries the tutor name")
  return name
end

-- GetLearnableTutorMoves: the inventory in its own order, keeping the row when
-- the mon's compatibility list carries the move, the row belongs to the asked
-- tutor, and the mon does not already know the move. The source resolves a
-- form-specific compatibility row only for the five form families; every other
-- form reads its species' own row.
---@param slot0 integer
---@param tutorNpc integer raw source tutor selector
---@return MoveTutorService.TutorOffer[]
function MoveTutorService:tutorEligibleMoves(slot0, tutorNpc)
  local npc = tutorNpcName(tutorNpc)
  local mon = self:_mon(slot0)
  local catalog = self._mons:catalog()
  local species = assert(mon.species, "a stored mon carries its species")
  local forms = assert(self._tutors.learnsets --[[@as table<string, string[][]>]][species], "the tutor table covers species")
  local form = assert(mon.form, "a stored mon carries its form")
  local learnable = forms[form + 1]
  if learnable == nil then
    learnable = assert(forms[1], "every species carries its own tutor row")
  end
  local canLearn = {}
  for _, moveKey in ipairs(learnable) do
    canLearn[moveKey] = true
  end
  local known = {}
  for _, entry in ipairs(assert(mon.moves, "a stored mon carries its moves")) do
    known[entry.move] = true
  end
  local offers = {}
  for _, row in ipairs(self._tutors.moves --[[@as { move: string, cost: integer, npc: string }[] ]]) do
    if row.npc == npc and canLearn[row.move] == true and known[row.move] ~= true then
      offers[#offers + 1] = {
        move = row.move,
        cost = row.cost,
        nativeId = catalog:move(row.move).nativeId,
      }
    end
  end
  return offers
end

-- ScrCmd_GetTutorMoveListPageCount: no eligible move answers no page, up to
-- seven fit one page, and a larger list takes floor(count / 6) + 1 pages.
---@param count integer
---@return integer
local function tutorPageCountOf(count)
  if count == 0 then
    return 0
  end
  if count <= 7 then
    return 1
  end
  return math.floor(count / TUTOR_PAGE_SIZE) + 1
end

---@param slot0 integer
---@param tutorNpc integer raw source tutor selector
---@return integer
function MoveTutorService:tutorPageCount(slot0, tutorNpc)
  return tutorPageCountOf(#self:tutorEligibleMoves(slot0, tutorNpc))
end

-- ScrCmd_MoveTutorChooseMove: one page of the eligible list. A list of at most
-- seven moves is the whole list; a larger one skips `page * 6` rows, shows at
-- most six and keeps the source Next row, even on the page that carries the
-- last move.
---@param slot0 integer
---@param tutorNpc integer raw source tutor selector
---@param page integer zero-based source page
---@return { rows: MoveTutorService.TutorOffer[], hasNext: boolean }
function MoveTutorService:tutorPage(slot0, tutorNpc, page)
  if type(page) ~= "number" or page % 1 ~= 0 or page < 0 then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the tutor page names a source page", { page = page })
  end
  local eligible = self:tutorEligibleMoves(slot0, tutorNpc)
  local count = #eligible
  local pageNumber = page --[[@as integer]]
  local pages = tutorPageCountOf(count)
  -- A script opens only the pages its own page count answered; the source's
  -- third branch reads an uninitialized flag, so any other page is an
  -- attributed fault here rather than a plausible repeated page.
  if count == 0 or pageNumber >= pages then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "the tutor page is outside the source list", {
      page = pageNumber,
      pages = pages,
      moves = count,
    })
  end
  local skip, shown, hasNext
  if count <= 7 then
    skip, shown, hasNext = 0, count, false
  else
    skip = pageNumber * TUTOR_PAGE_SIZE
    shown = math.min(count - skip, TUTOR_PAGE_SIZE)
    hasNext = true
  end
  local rows = {}
  for index = 1, shown do
    rows[index] = eligible[skip + index]
  end
  return { rows = rows, hasNext = hasNext }
end

-- ScrCmd_TutorMoveGetPrice: the inventory row that carries the move the script
-- selects, or nil when the inventory does not offer it, so the caller refuses
-- the lesson instead of charging nothing.
---@param move unknown source move identity (native id) from the script operand
---@return MoveTutorService.TutorOffer|nil
function MoveTutorService:tutorPrice(move)
  if type(move) ~= "number" or move % 1 ~= 0 then
    return nil
  end
  local catalog = self._mons:catalog()
  for _, row in ipairs(self._tutors.moves --[[@as { move: string, cost: integer, npc: string }[] ]]) do
    local definition = catalog:move(row.move)
    if definition.nativeId == move then
      return { move = row.move, cost = row.cost, nativeId = definition.nativeId }
    end
  end
  return nil
end

-- ScrCmd_MonCanLearnHeadbuttFromTutor: the Headbutt tutor's own offer list,
-- which is empty for a mon whose compatibility row omits the move or already
-- knows it.
---@param slot0 integer
---@return boolean
function MoveTutorService:canLearnHeadbutt(slot0)
  return #self:tutorEligibleMoves(slot0, 3) > 0
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
