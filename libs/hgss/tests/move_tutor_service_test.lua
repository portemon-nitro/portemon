-- The Move Reminder's and singleton tutor's domain queries over the canonical
-- party: the source's ordered current-form eligibility, its level filter, the
-- known-move filter and its stable deduplication, plus the single teaching
-- publication (base PP, no PP Ups, the caller's revision). The Frontier tutor
-- queries come from the same owner: the ordered inventory filtered by tutor and
-- by the moves the mon already knows, the source page formula, the page slice
-- with its Next row, and the source price. The mon owner behind the seam records
-- the exact publication the service asks for, so the test proves ordering,
-- values and guarded publication without re-proving mon records (the real ROM
-- acceptance covers that path).

local Assert = require("tests.support.Assert")
local MoveTutorService = require("libs.hgss.src.field.MoveTutorService")

local T = {
  metadata = { capabilities = { "graphics" }, tags = { "mons", "moves" } },
  tests = {},
}

-- A medium-fast growth curve: level N needs N^3 experience, which keeps the
-- level arithmetic readable in the fixture.
local function mediumFast()
  local curve = {}
  for level = 1, 100 do
    curve[level] = level * level * level
  end
  return curve
end

local CATALOG = {
  growthCurves = { medium_fast = mediumFast() },
  species = {
    PIDGEY = { nativeId = 16, growthCurve = "medium_fast", name = "PIDGEY" },
    MEW = { nativeId = 151, growthCurve = "medium_fast", name = "MEW" },
    TYRANITAR = { nativeId = 248, growthCurve = "medium_fast", name = "TYRANITAR" },
    CATERPIE = { nativeId = 10, growthCurve = "medium_fast", name = "CATERPIE" },
    SEVEN = { nativeId = 19, growthCurve = "medium_fast", name = "SEVEN" },
  },
  forms = {
    ["PIDGEY:0"] = {
      levelUpMoves = {
        { level = 1, move = "TACKLE" },
        { level = 5, move = "SAND_ATTACK" },
        { level = 9, move = "GUST" },
        { level = 15, move = "QUICK_ATTACK" },
        { level = 22, move = "TWISTER" },
        { level = 31, move = "WING_ATTACK" },
        -- A repeated entry later in the source table stays a duplicate.
        { level = 9, move = "GUST" },
      },
    },
  },
  moves = {
    TACKLE = { nativeId = 33, name = "TACKLE", basePp = 35 },
    DIVE = { nativeId = 291, name = "DIVE", basePp = 10 },
    MUD_SLAP = { nativeId = 189, name = "MUD-SLAP", basePp = 10 },
    ICY_WIND = { nativeId = 196, name = "ICY WIND", basePp = 15 },
    SUPERPOWER = { nativeId = 276, name = "SUPERPOWER", basePp = 5 },
    HEADBUTT = { nativeId = 29, name = "HEADBUTT", basePp = 15 },
    SAND_ATTACK = { nativeId = 28, name = "SAND_ATTACK", basePp = 15 },
    GUST = { nativeId = 16, name = "GUST", basePp = 35 },
    QUICK_ATTACK = { nativeId = 98, name = "QUICK_ATTACK", basePp = 30 },
    TWISTER = { nativeId = 239, name = "TWISTER", basePp = 20 },
    WING_ATTACK = { nativeId = 17, name = "WING_ATTACK", basePp = 35 },
  },
}

---@return { species: fun(key: string): table, form: fun(key: string, form: integer): table, growthCurve: fun(key: string): table, move: fun(key: string): table }
local function catalog()
  return {
    species = function(_, key)
      return assert(CATALOG.species[key], "the fixture carries " .. tostring(key))
    end,
    form = function(_, key, form)
      return assert(CATALOG.forms[key .. ":" .. tostring(form)], "the fixture carries that form")
    end,
    growthCurve = function(_, key)
      return assert(CATALOG.growthCurves[key], "the fixture carries that curve")
    end,
    move = function(_, key)
      return assert(CATALOG.moves[key], "the fixture carries " .. tostring(key))
    end,
  }
end

-- The compiled care catalog's tutor tables, in the shape the producer
-- publishes: one ordered inventory of source offers and one dense list per
-- runtime form of a species (index 1 is the species' own row). The fixture
-- carries twenty-one top-right offers so the source's one-page boundary and its
-- four-page list are both reachable.
local TOP_RIGHT_OFFERS = 21
local TOP_LEFT_OFFERS = 2

---@param index integer zero-based offer index
---@return string
local function tutorMoveKey(index)
  return "TUTOR_" .. string.format("%02d", index)
end

local TUTOR_INVENTORY = {}
local function addTutorOffer(move, cost, npc)
  TUTOR_INVENTORY[#TUTOR_INVENTORY + 1] = { move = move, cost = cost, npc = npc }
  CATALOG.moves[move] = { nativeId = 500 + #TUTOR_INVENTORY, name = move, basePp = 10 }
end
for index = 0, TOP_RIGHT_OFFERS - 1 do
  addTutorOffer(tutorMoveKey(index), 32 + index, "top_right")
end
for index = 0, TOP_LEFT_OFFERS - 1 do
  addTutorOffer("LEFT_" .. string.format("%02d", index), 40, "top_left")
end
addTutorOffer("HEADBUTT", 0, "headbutt")

---@param npc string
---@param count integer how many of that tutor's offers the species can learn
---@return string[]
local function tutorOffers(npc, count)
  local list = {}
  for _, row in ipairs(TUTOR_INVENTORY) do
    if row.npc == npc and #list < count then
      list[#list + 1] = row.move
    end
  end
  assert(#list == count, "the fixture inventory carries that many " .. npc .. " offers")
  return list
end

local function tutors()
  local function learnset(list)
    return { list }
  end
  local all = tutorOffers("top_right", TOP_RIGHT_OFFERS)
  for _, move in ipairs(tutorOffers("top_left", TOP_LEFT_OFFERS)) do
    all[#all + 1] = move
  end
  all[#all + 1] = "HEADBUTT"
  return {
    moves = TUTOR_INVENTORY,
    learnsets = {
      MEW = learnset(all),
      TYRANITAR = learnset(tutorOffers("top_right", 8)),
      SEVEN = learnset(tutorOffers("top_right", 7)),
      CATERPIE = learnset({}),
      PIDGEY = learnset(tutorOffers("headbutt", 1)),
    },
  }
end

-- One party mon at the fixture species with the given level's experience and
-- known moves; the owner answers the exact partyMon/catalog pair the service
-- reads.
---@param level integer
---@param known string[]
---@param species string?
local function mons(level, known, species)
  local mon = {
    species = species or "PIDGEY",
    form = 0,
    experience = level * level * level,
    moves = {},
  }
  for index, move in ipairs(known) do
    mon.moves[index] = { move = move, pp = CATALOG.moves[move].basePp, ppUps = 0 }
  end
  local published = {}
  local owner = {
    published = published,
    partyMon = function(_, slot)
      assert(slot == 0, "the fixture carries one party slot")
      local copy = { species = mon.species, form = mon.form, experience = mon.experience, moves = {} }
      for index, entry in ipairs(mon.moves) do
        copy.moves[index] = { move = entry.move, pp = entry.pp, ppUps = entry.ppUps }
      end
      return copy
    end,
    catalog = function()
      return catalog()
    end,
    preparePartyChanges = function(_, expectedRevision, updates)
      if expectedRevision ~= 1 then
        return nil, "stale"
      end
      return {
        publish = function()
          published[#published + 1] = updates[1]
        end,
      }
    end,
  }
  return owner, mon
end

function T.tests.eligibility_keeps_source_order_and_filters_level_and_known_moves()
  local owner = mons(22, { "TACKLE", "GUST" })
  local service = MoveTutorService.new({ mons = owner, tutors = tutors() })
  Assert.deepEqual(service:eligibleRelearnMoves(0), {
    "SAND_ATTACK",
    "QUICK_ATTACK",
    "TWISTER",
  }, "the ordered list skips known and above-level entries and keeps the source order")
  Assert.isTrue(service:hasRelearnableMoves(0), "a mon with a remaining entry answers the query")
end

function T.tests.eligibility_drops_a_repeated_source_entry_once()
  local owner = mons(22, { "TACKLE", "SAND_ATTACK" })
  local service = MoveTutorService.new({ mons = owner, tutors = tutors() })
  local list = service:eligibleRelearnMoves(0)
  local gusts = 0
  for _, move in ipairs(list) do
    if move == "GUST" then
      gusts = gusts + 1
    end
  end
  Assert.equal(gusts, 1, "a repeated level-up entry is offered once")
  Assert.equal(list[1], "GUST", "the first occurrence keeps its source position")
end

function T.tests.eligibility_is_empty_when_every_entry_is_known()
  local owner = mons(9, { "TACKLE", "SAND_ATTACK", "GUST" })
  local service = MoveTutorService.new({ mons = owner, tutors = tutors() })
  Assert.deepEqual(service:eligibleRelearnMoves(0), {}, "the list carries no entry")
  Assert.isFalse(service:hasRelearnableMoves(0), "the query answers no eligible move")
end

function T.tests.teaching_publishes_the_selected_move_at_base_pp_without_pp_ups()
  local owner = mons(22, { "TACKLE", "SAND_ATTACK" })
  local service = MoveTutorService.new({ mons = owner, tutors = tutors() })
  local outcome = service:teach(0, "TWISTER", 2, 1)
  Assert.equal(outcome.kind, "changed", "a live revision publishes the lesson")
  Assert.equal(#owner.published, 1, "one prepared party change carries the lesson")
  local mon = owner.published[1].mon
  Assert.equal(owner.published[1].slot, 0, "the lesson publishes on its own party slot")
  Assert.equal(#mon.moves, 3, "the new move appends after the known moves")
  Assert.equal(mon.moves[3].move, "TWISTER", "the selected move lands at the source row")
  Assert.equal(mon.moves[3].pp, 20, "the taught move starts at its base PP")
  Assert.equal(mon.moves[3].ppUps, 0, "the taught move carries no PP Ups")
  Assert.equal(mon.moves[1].move, "TACKLE", "the untouched rows keep their order")
end

function T.tests.teaching_replaces_the_replacement_row_the_summary_answered()
  local owner = mons(22, { "TACKLE", "SAND_ATTACK", "GUST" })
  local service = MoveTutorService.new({ mons = owner, tutors = tutors() })
  local outcome = service:teach(0, "TWISTER", 1, 1)
  Assert.equal(outcome.kind, "changed", "a live revision publishes the replacement")
  local mon = owner.published[1].mon
  Assert.equal(#mon.moves, 3, "a replacement keeps the moveset size")
  Assert.equal(mon.moves[2].move, "TWISTER", "the answered row carries the taught move")
  Assert.equal(mon.moves[2].pp, 20, "the replacement starts at its base PP")
  Assert.equal(mon.moves[3].move, "GUST", "the following rows keep their order")
end

function T.tests.teaching_a_stale_revision_publishes_nothing()
  local owner = mons(22, { "TACKLE" })
  local service = MoveTutorService.new({ mons = owner, tutors = tutors() })
  local outcome = service:teach(0, "TWISTER", 1, 7)
  Assert.equal(outcome.kind, "stale", "a stale revision is refused")
  Assert.equal(#owner.published, 0, "a refused lesson publishes nothing")
end

-- ScrCmd_GetTutorMoveListPageCount: no eligible move answers zero pages, up to
-- seven fit one page, and a larger list takes the source's own
-- floor(count / 6) + 1 rather than a ceiling division.
function T.tests.tutor_page_count_follows_the_source_formula()
  local function pages(species, known, npc)
    local owner = mons(30, known, species)
    local service = MoveTutorService.new({ mons = owner, tutors = tutors() })
    return service:tutorPageCount(0, npc)
  end
  Assert.equal(pages("CATERPIE", {}, 1), 0, "a mon this tutor cannot teach opens no page")
  Assert.equal(pages("SEVEN", {}, 1), 1, "seven moves fit one page")
  Assert.equal(pages("TYRANITAR", { tutorMoveKey(0) }, 1), 1, "a known move leaves six moves on one page")
  Assert.equal(pages("TYRANITAR", {}, 1), 2, "eight moves take the source's second page")
  Assert.equal(pages("MEW", {}, 1), 4, "twenty-one moves take floor(21 / 6) + 1 pages")
  Assert.equal(pages("MEW", {}, 0), 1, "the other tutor's own two offers fit one page")
end

-- GetLearnableTutorMoves: the inventory order is the list order, the tutor
-- selector filters the offers and the moves the mon already knows drop out.
function T.tests.the_list_filters_the_tutor_and_the_known_moves()
  local owner = mons(30, {}, "MEW")
  local service = MoveTutorService.new({ mons = owner, tutors = tutors() })
  local right = service:tutorEligibleMoves(0, 1)
  Assert.equal(#right, TOP_RIGHT_OFFERS, "every top-right offer the mon can learn is listed")
  Assert.equal(right[1].move, tutorMoveKey(0), "the list keeps the inventory's own order")
  Assert.equal(right[1].cost, 32, "the row carries the source price")
  Assert.equal(right[1].nativeId, CATALOG.moves[tutorMoveKey(0)].nativeId, "the row names the source move identity")
  Assert.equal(right[#right].move, tutorMoveKey(TOP_RIGHT_OFFERS - 1), "the last offer closes the list")

  local left = service:tutorEligibleMoves(0, 0)
  Assert.equal(#left, TOP_LEFT_OFFERS, "the top-left tutor offers only its own moves")
  Assert.equal(left[1].move, "LEFT_00", "the other tutor's list starts at its own first offer")

  local known = mons(30, { tutorMoveKey(0), tutorMoveKey(5) }, "MEW")
  local filtered = MoveTutorService.new({ mons = known, tutors = tutors() })
  local remaining = filtered:tutorEligibleMoves(0, 1)
  Assert.equal(#remaining, TOP_RIGHT_OFFERS - 2, "the moves the mon already knows leave the list")
  Assert.equal(remaining[1].move, tutorMoveKey(1), "the remaining rows keep their source order")
  for _, row in ipairs(remaining) do
    Assert.isTrue(row.move ~= tutorMoveKey(0) and row.move ~= tutorMoveKey(5), "a known move is never offered")
  end
end

-- ScrCmd_MoveTutorChooseMove: each page of a larger list skips six rows, shows
-- at most six, and keeps the source Next row even on the last page.
function T.tests.the_page_slice_skips_six_rows_and_keeps_the_next_row()
  local owner = mons(30, {}, "MEW")
  local service = MoveTutorService.new({ mons = owner, tutors = tutors() })
  local first = service:tutorPage(0, 1, 0)
  Assert.equal(#first.rows, 6, "a full page shows six moves")
  Assert.equal(first.rows[1].move, tutorMoveKey(0), "the first page starts at the first offer")
  Assert.isTrue(first.hasNext, "a larger list keeps its Next row")
  local second = service:tutorPage(0, 1, 1)
  Assert.equal(second.rows[1].move, tutorMoveKey(6), "the second page skips six rows")
  local last = service:tutorPage(0, 1, 3)
  Assert.equal(#last.rows, 3, "the last page shows the remaining three moves")
  Assert.equal(last.rows[3].move, tutorMoveKey(TOP_RIGHT_OFFERS - 1), "the last offer closes the last page")
  Assert.isTrue(last.hasNext, "the source keeps the Next row on the page that takes the second branch")

  -- A list of at most seven moves is one page with no Next row.
  local small = mons(30, {}, "SEVEN")
  local seven = MoveTutorService.new({ mons = small, tutors = tutors() })
  local only = seven:tutorPage(0, 1, 0)
  Assert.equal(#only.rows, 7, "seven moves all fit the page")
  Assert.isFalse(only.hasNext, "a list that fits one page offers no Next row")
end

-- The source's third page branch reads an uninitialized flag and is never
-- taken by a retail script; a page outside the source list is an attributed
-- fault here rather than a plausible repeated page.
function T.tests.a_page_outside_the_source_list_faults()
  local owner = mons(30, {}, "SEVEN")
  local service = MoveTutorService.new({ mons = owner, tutors = tutors() })
  local err = Assert.throws(function()
    return service:tutorPage(0, 1, 1)
  end, "a page past a one-page list")
  Assert.isTrue(require("libs.errors.src.Errors").is(err), "the fault is attributed")
  local empty = mons(30, {}, "CATERPIE")
  local none = MoveTutorService.new({ mons = empty, tutors = tutors() })
  Assert.throws(function()
    return none:tutorPage(0, 1, 0)
  end, "an empty list has no page to open")
end

-- ScrCmd_TutorMoveGetPrice answers the inventory price of the move it names;
-- a move the inventory does not carry has no price at all, so the caller
-- refuses it instead of charging zero.
function T.tests.the_price_comes_from_the_inventory_row()
  local owner = mons(30, {}, "MEW")
  local service = MoveTutorService.new({ mons = owner, tutors = tutors() })
  local nativeId = CATALOG.moves[tutorMoveKey(3)].nativeId
  local row = assert(service:tutorPrice(nativeId), "an inventory move answers its row")
  Assert.equal(row.move, tutorMoveKey(3), "the row names the move")
  Assert.equal(row.cost, 32 + 3, "the row carries the source price")
  local headbutt = assert(service:tutorPrice(CATALOG.moves.HEADBUTT.nativeId), "the zero-cost lesson answers too")
  Assert.equal(headbutt.cost, 0, "the Headbutt lesson is the free source entry")
  Assert.isNil(service:tutorPrice(9999), "a move outside the inventory has no price")
  Assert.isNil(service:tutorPrice(CATALOG.moves.TACKLE.nativeId), "a known but unoffered move has no price")
end

-- ScrCmd_MonCanLearnHeadbuttFromTutor: the same compatibility row and the same
-- known-move filter decide the Headbutt lesson.
function T.tests.headbutt_eligibility_follows_the_compatibility_rows()
  local owner = mons(20, {}, "PIDGEY")
  local service = MoveTutorService.new({ mons = owner, tutors = tutors() })
  Assert.isTrue(service:canLearnHeadbutt(0), "a mon whose row lists Headbutt is eligible")
  local knows = mons(20, { "HEADBUTT" }, "PIDGEY")
  local filtered = MoveTutorService.new({ mons = knows, tutors = tutors() })
  Assert.isFalse(filtered:canLearnHeadbutt(0), "a mon that already knows Headbutt is not offered it")
  local excluded = mons(5, {}, "CATERPIE")
  local none = MoveTutorService.new({ mons = excluded, tutors = tutors() })
  Assert.isFalse(none:canLearnHeadbutt(0), "a mon outside the rows is refused")
end

return T
