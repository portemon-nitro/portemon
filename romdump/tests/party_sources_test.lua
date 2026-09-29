-- Producer-inventory scenarios for the native party presentation sources.
-- Asserts the audited archive/member selection, the transcribed source
-- geometry, and the provenance pins. No ROM access: every fact here is a
-- static producer declaration the compiler consumes.

local Assert = require("tests.support.Assert")
local PartySources = require("romdump.src.config.PartySources")
local PartyAssetCompiler = require("romdump.src.digest.ui.PartyAssetCompiler")

local T = {}

function T.provenance_records_both_pins()
  Assert.isTrue(type(PartySources.provenance.repoPin) == "string", "the producer records the research commit")
  Assert.isTrue(type(PartySources.provenance.decompPin) == "string", "the producer records the audited decomp pin")
  Assert.isTrue(#PartySources.provenance.repoPin >= 7, "the research pin is a real commit prefix")
end

function T.party_archive_selects_narc21()
  Assert.equal(PartySources.archive.symbol, "NARC_graphic_plist_gra")
  Assert.equal(PartySources.archive.narcId, 21)
  Assert.equal(PartySources.archive.path, "a/0/2/1")
  Assert.equal(PartySources.archive.memberCount, 27)
end

function T.member_groups_cover_all27_members()
  local seen = {}
  for group, members in pairs(PartySources.members) do
    Assert.isTrue(type(members) == "table" and #members > 0, group .. " selects members")
    for _, memberId in ipairs(members) do
      Assert.isTrue(memberId >= 0 and memberId < 27, "member " .. memberId .. " is inside the party archive")
      Assert.isNil(seen[memberId], "member " .. memberId .. " belongs to exactly one group")
      seen[memberId] = group
    end
  end
  local covered = 0
  for _ in pairs(seen) do
    covered = covered + 1
  end
  Assert.equal(covered, 27, "every party archive member has exactly one owning group")
end

function T.panel_templates_come_from_member22_rows()
  local templates = PartySources.panelTemplates
  Assert.equal(templates.member, 22)
  Assert.equal(#templates.rows, 3)
  Assert.deepEqual({ templates.rows[1].tileRow, templates.rows[2].tileRow, templates.rows[3].tileRow }, { 0, 6, 12 })
  Assert.deepEqual({ templates.rows[1].use, templates.rows[2].use, templates.rows[3].use }, { "first", "rest", "aux" })
end

function T.geometry_carries_six_slot_placements()
  Assert.equal(#PartySources.geometry.panels, 6)
  Assert.equal(#PartySources.geometry.monAnchors, 6)
  Assert.equal(#PartySources.geometry.ballAnchors, 6)
  Assert.deepEqual(PartySources.geometry.panels[1].origin, { x = 0, y = 0 })
  Assert.deepEqual(PartySources.geometry.panels[2].origin, { x = 128, y = 8 })
  Assert.deepEqual(PartySources.geometry.monAnchors[1], { x = 30, y = 16 })
  Assert.deepEqual(PartySources.geometry.ballAnchors[1], { x = 16, y = 14 })
  Assert.deepEqual(PartySources.geometry.panelSize, { width = 128, height = 48 })
end

function T.compiled_geometry_publishes_source_independent_runtime_anchors()
  local compiled = PartyAssetCompiler.compileGeometry(PartySources)
  Assert.equal(#compiled.panels, 6)
  for slot, panel in ipairs(compiled.panels) do
    Assert.deepEqual(panel.iconAnchor, PartySources.geometry.monAnchors[slot], "icon anchor " .. slot)
    Assert.deepEqual(panel.ballAnchor, PartySources.geometry.ballAnchors[slot], "ball anchor " .. slot)
    Assert.deepEqual(panel.statusRect, PartySources.geometry.statusRects[slot], "status rectangle " .. slot)
    Assert.isTrue(type(panel.heldAnchor) == "table", "held-item anchor " .. slot .. " is published")
    Assert.isTrue(type(panel.capsuleAnchor) == "table", "capsule anchor " .. slot .. " is published")
    Assert.isTrue(type(panel.cursorSequence) == "number", "cursor selector " .. slot .. " is published")
  end
  Assert.deepEqual(compiled.controls.cancel.anchor, { x = 232, y = 184 })
  Assert.isNil(compiled.controls.cancel.memberId, "runtime control geometry omits source identities")
end

function T.status_rects_match_the_sprite_template_centers()
  Assert.equal(#PartySources.geometry.statusRects, 6)
  Assert.deepEqual(PartySources.geometry.statusRects[1], { x = 24, y = 40, width = 24, height = 8 })
  Assert.deepEqual(PartySources.geometry.statusRects[2], { x = 152, y = 48, width = 24, height = 8 })
end

function T.numeric_selection_names_font_member5_cells()
  Assert.equal(PartySources.numeric.fontSymbol, "NARC_graphic_font")
  Assert.equal(PartySources.numeric.member, 5)
  Assert.equal(PartySources.numeric.digitWidth, 8)
  Assert.equal(PartySources.numeric.digitHeight, 8)
  Assert.equal(PartySources.numeric.slashOffset, 0x140)
  Assert.equal(PartySources.numeric.levelOffset, 0x160)
end

function T.badge_selection_names_members65_to_68()
  Assert.equal(PartySources.badges.archiveSymbol, "NARC_a_1_6_2")
  Assert.equal(PartySources.badges.paletteMember, 65)
  Assert.equal(PartySources.badges.charMember, 66)
  Assert.equal(PartySources.badges.cellMember, 67)
  Assert.equal(PartySources.badges.animationMember, 68)
  Assert.equal(PartySources.badges.leafSequence, 6)
  Assert.equal(PartySources.badges.crownSequence, 7)
  Assert.equal(PartySources.badges.paletteBank, 1)
  Assert.equal(#PartySources.badges.leafAnchors, 5)
end

function T.message_bank300_is_explicit()
  Assert.equal(PartySources.messages.archiveSymbol, "NARC_msgdata_msg")
  Assert.equal(PartySources.messages.bank, 300)
  Assert.isTrue(type(PartySources.messages.labels) == "table", "action labels are selected")
  Assert.isTrue(type(PartySources.messages.templates) == "table", "prompt templates are selected")
end

function T.navigation_names_the_audited_layout_variants()
  Assert.equal(#PartySources.geometry.dpad.default, 8)
  Assert.equal(#PartySources.geometry.dpad.alternate, 8)
  Assert.equal(#PartySources.geometry.dpad.union, 8)
  Assert.equal(#PartySources.geometry.dpad.contest, 8)
  Assert.deepEqual(
    PartySources.geometry.dpad.default[1],
    { left = 64, top = 25, width = 0, height = 0, up = 7, down = 2, leftNeighbor = 7, rightNeighbor = 1 }
  )
  Assert.equal(#PartySources.geometry.touch.default, 7)
  Assert.equal(#PartySources.geometry.touch.alternate, 7)
  Assert.equal(#PartySources.geometry.touch.context, 8)
  Assert.deepEqual(PartySources.geometry.touch.default[2], { top = 8, bottom = 56, left = 128, right = 0 })
end

return { tests = T }
