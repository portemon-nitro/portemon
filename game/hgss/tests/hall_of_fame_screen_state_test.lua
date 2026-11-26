-- Retail showcase grid navigation: 3x2 party slots plus exit 6, with paging
-- only at native edges. Guards the R03 regression where Up from 0 produced
-- -1 and the topology assumed two columns of three.

local Assert = require("tests.support.Assert")
local HallOfFamePresentation = require("game.hgss.src.ending.HallOfFamePresentation")
local HallOfFameScreenState = require("game.hgss.src.ending.HallOfFameScreenState")
local HallOfFameState = require("libs.hgss.src.save.HallOfFameState")

local T = { tests = {} }

local function presentation()
  return HallOfFamePresentation.new({
    signature = "test",
    registration = { messageBank = 180, memberFrames = 84 },
    showcase = { messageBank = 181 },
    credits = {
      frames = 4976,
      musicBoxWaitFrames = 380,
      messageBank = 440,
      titleMessages = { heartgold = 0, soulsilver = 1 },
      sceneTransitionTimings = { 890 },
      screenFlipTimings = { 890 },
      scenes = {
        { index = 0, lower = { path = "a", sha1 = "aa" }, upper = { path = "b", sha1 = "bb" } },
      },
      pages = { { page = 0, startTime = 0, duration = 105, lines = {} } },
      theEnd = { path = "end", sha1 = "ee" },
    },
  })
end

local function partyMon(species)
  return {
    species = species,
    level = 50,
    form = 0,
    personality = 0,
    otId = 0,
    nickname = species,
    otName = "OT",
    moves = { "", "", "", "" },
  }
end

local function screenWithParties(parties)
  local history = HallOfFameState.empty()
  -- Build history newest-first via recordClear on a fake mon service? Use
  -- direct capture: empty then record via coordinator is heavy; instead use
  -- HallOfFameState.restore with crafted buckets.
  -- Simpler: use empty history and inject records via total/count/record
  -- stub? HallOfFameScreenState requires HallOfFameState with count/record.
  -- Use a minimal fake history.
  local records = {}
  for _, party in ipairs(parties) do
    records[#records + 1] = { date = { year = 2000, month = 1, day = 1 }, party = party }
  end
  local fakeHistory = {
    count = function()
      return #records
    end,
    total = function()
      return #records
    end,
    record = function(_, index)
      local entry = records[index + 1]
      assert(entry ~= nil)
      return entry
    end,
  }
  return HallOfFameScreenState.new({ app = "hallOfFame" }, {
    hallOfFame = fakeHistory,
    presentation = presentation(),
  })
end

function T.tests.up_from_first_slot_stays_valid()
  local state = screenWithParties({ { partyMon("A"), partyMon("B") } })
  Assert.equal(state:status().cursor, 0, "starts at first slot")
  state:updateFixed({ { type = "navigate", direction = "up" } })
  local status = state:status()
  Assert.equal(status.cursor, 0, "Up from 0 never produces -1")
  Assert.isFalse(status.exitSelected, "Up from 0 never selects exit")
  Assert.equal(status.selectedMon, 0, "first slot stays selected")
end

function T.tests.grid_uses_three_columns_two_rows_plus_exit()
  local party = {}
  for i = 1, 6 do
    party[#party + 1] = partyMon("M" .. i)
  end
  local state = screenWithParties({ party })
  -- Right across top row: 0->1->2, then held at right edge.
  state:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(state:status().cursor, 1, "0 right goes to 1")
  state:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(state:status().cursor, 2, "1 right goes to 2")
  state:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(state:status().cursor, 2, "right at 2 holds (pages only via record edge with multiple records)")
  -- Down the right column to the second row, then to exit.
  state:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(state:status().cursor, 5, "2 down goes to 5")
  state:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(state:status().cursor, 6, "5 down goes to exit 6")
  local exitStatus = state:status()
  Assert.isTrue(exitStatus.exitSelected, "exit 6 selects exit")
  Assert.isNil(exitStatus.selectedMon, "exit selects no mon (nil, not cursor)")
  -- Up from exit returns to 5.
  state:updateFixed({ { type = "navigate", direction = "up" } })
  Assert.equal(state:status().cursor, 5, "exit up returns to 5")
  -- Left edge navigation.
  local left = screenWithParties({ party })
  left:updateFixed({ { type = "navigate", direction = "down" } })
  Assert.equal(left:status().cursor, 3, "0 down goes to 3")
end

function T.tests.paging_only_at_native_edges()
  local party = { partyMon("A") }
  local state = screenWithParties({ party, party })
  Assert.equal(state:status().cursor, 0, "starts at 0")
  -- Right from 0 moves within grid, never pages.
  state:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(state:status().cursor, 1, "right from 0 moves to 1")
  Assert.equal(state:status().recordNumber, 2, "no paging on non-edge right")
  -- Left from 1 moves back, never pages.
  state:updateFixed({ { type = "navigate", direction = "left" } })
  Assert.equal(state:status().cursor, 0, "left from 1 moves to 0")
  -- Right at the native right edge (2) pages to the older record.
  state:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(state:status().cursor, 1, "right from 0 moves to 1")
  state:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(state:status().cursor, 2, "right from 1 moves to 2")
  local before = state:status().recordNumber
  state:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(state:status().cursor, 2, "cursor stays after paging")
  Assert.isTrue(state:status().recordNumber ~= before, "right at 2 pages")
  -- Left at the native left edge (0) pages back to newer.
  state:updateFixed({ { type = "navigate", direction = "left" } })
  Assert.equal(state:status().cursor, 1, "left from 2 moves to 1")
  state:updateFixed({ { type = "navigate", direction = "left" } })
  Assert.equal(state:status().cursor, 0, "left from 1 moves to 0")
  local olderNumber = state:status().recordNumber
  state:updateFixed({ { type = "navigate", direction = "left" } })
  Assert.isTrue(state:status().recordNumber ~= olderNumber, "left at 0 pages back")
end

function T.tests.touch_selects_grid_exit_and_pages()
  local party = { partyMon("A"), partyMon("B") }
  local state = screenWithParties({ party, party })
  state:updateFixed({ { type = "touch", target = 1 } })
  Assert.equal(state:status().cursor, 1, "touch selects slot 1")
  state:updateFixed({ { type = "touch", target = 6 } })
  Assert.isTrue(state:status().exitSelected, "touch 6 selects exit")
  -- Touch paging targets.
  local paged = screenWithParties({ party, party })
  local firstRecord = paged:status().recordNumber
  paged:updateFixed({ { type = "touch", target = 8 } })
  Assert.isTrue(paged:status().recordNumber ~= firstRecord, "touch 8 pages to next record")
  paged:updateFixed({ { type = "touch", target = 7 } })
  Assert.equal(paged:status().recordNumber, firstRecord, "touch 7 pages back")
  -- Out-of-range touch never invents an index.
  local invalid = screenWithParties({ party })
  invalid:updateFixed({ { type = "touch", target = 99 } })
  Assert.equal(invalid:status().cursor, 0, "invalid touch holds cursor")
end

function T.tests.raw_pointer_press_selects_through_the_shared_geometry()
  -- The host hands raw pointer edges to the child; the child routes them
  -- through the same press-only mapping the presented plan uses. Motion
  -- and release never activate, so paging fires exactly once per press.
  local party = { partyMon("A"), partyMon("B") }
  local state = screenWithParties({ party, party })
  -- Slot 1's own anchor (0x80, 0x48): a press selects it; motion and
  -- release on the same cell change nothing.
  state:updateFixed({ { type = "pointer_down", x = 0x80, y = 0x48 } })
  Assert.equal(state:status().cursor, 1, "a press on slot 1 selects slot 1")
  state:updateFixed({ { type = "pointer_move", x = 0x80, y = 0x48 } })
  Assert.equal(state:status().cursor, 1, "motion never reselects")
  state:updateFixed({ { type = "pointer_up", x = 0x80, y = 0x48 } })
  Assert.equal(state:status().cursor, 1, "release never activates")
  -- A press far outside every target holds the cursor.
  state:updateFixed({ { type = "pointer_down", x = 500, y = 500 } })
  Assert.equal(state:status().cursor, 1, "an outside press holds the cursor")
  -- The next paging box (232..255, 104..127) pages to the older record
  -- exactly once per press; motion and release between presses do nothing.
  local before = state:status().recordNumber
  state:updateFixed({ { type = "pointer_down", x = 240, y = 110 } })
  Assert.isTrue(state:status().recordNumber ~= before, "a press on next pages to the older record")
  local paged = state:status().recordNumber
  state:updateFixed({ { type = "pointer_move", x = 240, y = 110 } })
  Assert.equal(state:status().recordNumber, paged, "motion never pages")
  state:updateFixed({ { type = "pointer_up", x = 240, y = 110 } })
  Assert.equal(state:status().recordNumber, paged, "release never pages")
  -- The prev paging box pages back to the newer record.
  state:updateFixed({ { type = "pointer_down", x = 20, y = 110 } })
  Assert.equal(state:status().recordNumber, before, "a press on prev pages back")
  -- The exit anchor closes the application from any cursor.
  state:updateFixed({ { type = "pointer_down", x = 0xE0, y = 0xB0 } })
  Assert.isTrue(state:status().exitSelected, "a press on exit selects exit")
  Assert.isTrue(state:status().phase == "closed", "exit closes the application")
end

function T.tests.empty_slots_stay_navigable_with_hidden_detail()
  local party = { partyMon("A") }
  local state = screenWithParties({ party })
  state:updateFixed({ { type = "navigate", direction = "right" } })
  state:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(state:status().cursor, 2, "cursor reaches empty slot 2")
  Assert.isNil(state:status().selectedMon, "empty slot selects no mon")
  Assert.isFalse(state:status().exitSelected, "empty slot is not exit")
end

return T
