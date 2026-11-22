-- Source geometry for the Storage custody drop resolver and release timing.

local Assert = require("tests.support.Assert")
local PcStorageGeometry = require("libs.hgss.src.ui.PcStorageGeometry")

local T = {}

function T.box_drop_slot_clamps_the_edge_columns_and_rejects_the_gutter()
  -- PCBox_GetTouchedBoxSlot uses the inclusive grid rect and clamps the outer
  -- columns instead of rejecting points in the one-pixel border.
  Assert.equal(PcStorageGeometry.boxDropSlot(8, 40), 0, "the left grid edge clamps to column zero")
  Assert.equal(PcStorageGeometry.boxDropSlot(11, 63), 0, "the dead gutter still names the first cell")
  Assert.equal(PcStorageGeometry.boxDropSlot(12, 40), 0, "the first cell starts at its source corner")
  Assert.equal(PcStorageGeometry.boxDropSlot(35, 63), 0, "the first cell ends at its source width")
  Assert.equal(PcStorageGeometry.boxDropSlot(36, 40), 1, "the next cell starts on the 24 px pitch")
  Assert.equal(PcStorageGeometry.boxDropSlot(156, 159), 29, "the lower-right grid corner is the last cell")
  Assert.isNil(PcStorageGeometry.boxDropSlot(7, 80), "a point left of the grid names no cell")
  Assert.isNil(PcStorageGeometry.boxDropSlot(80, 160), "a point below the grid names no cell")
end

function T.party_drop_rects_match_the_source_columns_and_rows()
  local first = PcStorageGeometry.partyDropRect(0, "left")
  Assert.deepEqual(first, { x = 26, y = 58, width = 32, height = 23 }, "the first left drop rect is 32x23")
  Assert.equal(PcStorageGeometry.partyDropSlot(26, 58, "left"), 0, "the rect is inclusive on its source corner")
  Assert.equal(PcStorageGeometry.partyDropSlot(57, 80, "left"), 0, "the rect covers its last row and column")
  Assert.isNil(PcStorageGeometry.partyDropSlot(58, 80, "left"), "the next column starts a new cell")
  local right = PcStorageGeometry.partyDropRect(5, "right")
  Assert.deepEqual(right, { x = 214, y = 122, width = 32, height = 23 }, "the right panel offsets by its source band")
  Assert.equal(PcStorageGeometry.partyDropSlot(230, 130, "right"), 5, "the last right cell resolves")
end

function T.tray_drop_columns_use_the_source_thumbnail_rects()
  Assert.deepEqual(
    PcStorageGeometry.trayDropRect(0, false),
    { x = 31, y = 15, width = 24, height = 23 },
    "the tray row starts at the source rect"
  )
  Assert.equal(PcStorageGeometry.trayDropColumn(31, 15, false), 0)
  Assert.equal(PcStorageGeometry.trayDropColumn(205, 30, false), 5, "columns step on the 34 px pitch")
  Assert.isNil(PcStorageGeometry.trayDropColumn(60, 30, false), "the 10 px gap between wells names nothing")
  Assert.deepEqual(
    PcStorageGeometry.trayDropRect(0, true),
    { x = 31, y = 71, width = 24, height = 23 },
    "the deposit selector keeps its lower row"
  )
end

function T.release_timing_matches_the_source_affine_contract()
  Assert.equal(PcStorageGeometry.RELEASE_SHRINK_TICKS, 40, "the shrink runs forty fixed ticks")
  Assert.equal(PcStorageGeometry.RELEASE_GROW_TICKS, 20, "the grow-back runs twenty fixed ticks")
  Assert.equal(PcStorageGeometry.RELEASE_SHRINK_STEP, 0.025, "the shrink removes one fortieth per tick")
  Assert.equal(PcStorageGeometry.RELEASE_GROW_STEP, 0.05, "the grow adds one twentieth per tick")
end

return { tests = T }
