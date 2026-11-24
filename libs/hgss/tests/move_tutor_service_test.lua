-- The Move Reminder's and singleton tutor's domain queries over the canonical
-- party: the source's ordered current-form eligibility, its level filter, the
-- known-move filter and its stable deduplication, plus the single teaching
-- publication (base PP, no PP Ups, the caller's revision). The mon owner behind
-- the seam records the exact publication the service asks for, so the test
-- proves ordering, values and guarded publication without re-proving mon
-- records (the real ROM acceptance covers that path).

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

-- One party mon at the fixture species with the given level's experience and
-- known moves; the owner answers the exact partyMon/catalog pair the service
-- reads.
---@param level integer
---@param known string[]
local function mons(level, known)
  local mon = {
    species = "PIDGEY",
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
  local service = MoveTutorService.new({ mons = owner })
  Assert.deepEqual(service:eligibleRelearnMoves(0), {
    "SAND_ATTACK",
    "QUICK_ATTACK",
    "TWISTER",
  }, "the ordered list skips known and above-level entries and keeps the source order")
  Assert.isTrue(service:hasRelearnableMoves(0), "a mon with a remaining entry answers the query")
end

function T.tests.eligibility_drops_a_repeated_source_entry_once()
  local owner = mons(22, { "TACKLE", "SAND_ATTACK" })
  local service = MoveTutorService.new({ mons = owner })
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
  local service = MoveTutorService.new({ mons = owner })
  Assert.deepEqual(service:eligibleRelearnMoves(0), {}, "the list carries no entry")
  Assert.isFalse(service:hasRelearnableMoves(0), "the query answers no eligible move")
end

function T.tests.teaching_publishes_the_selected_move_at_base_pp_without_pp_ups()
  local owner = mons(22, { "TACKLE", "SAND_ATTACK" })
  local service = MoveTutorService.new({ mons = owner })
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
  local service = MoveTutorService.new({ mons = owner })
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
  local service = MoveTutorService.new({ mons = owner })
  local outcome = service:teach(0, "TWISTER", 1, 7)
  Assert.equal(outcome.kind, "stale", "a stale revision is refused")
  Assert.equal(#owner.published, 0, "a refused lesson publishes nothing")
end

return T
