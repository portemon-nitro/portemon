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
    Assert.deepEqual(
      { x = panel.heldAnchor.x - panel.iconAnchor.x, y = panel.heldAnchor.y - panel.iconAnchor.y },
      { x = 8, y = 8 },
      "held-item anchor " .. slot .. " derives from its icon"
    )
    Assert.deepEqual(
      { x = panel.capsuleAnchor.x - panel.iconAnchor.x, y = panel.capsuleAnchor.y - panel.iconAnchor.y },
      { x = 16, y = 8 },
      "capsule anchor " .. slot .. " derives from its icon"
    )
    Assert.isTrue(type(panel.cursorSequence) == "number", "cursor selector " .. slot .. " is published")
  end
  Assert.deepEqual(compiled.panels[1].heldAnchor, { x = 38, y = 24 })
  Assert.deepEqual(compiled.panels[1].capsuleAnchor, { x = 46, y = 24 })
  Assert.deepEqual(compiled.panels[6].heldAnchor, { x = 166, y = 128 })
  Assert.deepEqual(compiled.panels[6].capsuleAnchor, { x = 174, y = 128 })
  Assert.deepEqual(compiled.controls.cancel.anchor, { x = 232, y = 176 })
  Assert.isNil(compiled.controls.cancel.memberId, "runtime control geometry omits source identities")
  Assert.deepEqual(compiled.detail, {
    iconAnchor = { x = 30, y = 200 },
    statusAnchor = { x = 50, y = 220 },
    nicknameTextOrigin = { x = 56, y = 192 },
    heldItemTextOrigin = { x = 138, y = 212 },
  })
end

function T.status_inventory_names_the_native_sequence_for_each_semantic_status()
  Assert.deepEqual(PartySources.status.semanticSequences, {
    { key = "paralysis", sequence = 1 },
    { key = "freeze", sequence = 2 },
    { key = "sleep", sequence = 3 },
    { key = "poison", sequence = 4 },
    { key = "burn", sequence = 5 },
    { key = "faint", sequence = 6 },
  })
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

function T.message_labels_select_the_gender_messages()
  local labels = PartySources.messages.labels
  Assert.notNil(labels.male, "the producer selects the male gender label")
  Assert.notNil(labels.female, "the producer selects the female gender label")
  Assert.equal(labels.male.bank, 300, "the male label comes from the party message bank")
  Assert.equal(labels.male.index, 27, "the male label is the dedicated source gender message")
  Assert.equal(labels.female.bank, 300, "the female label comes from the party message bank")
  Assert.equal(labels.female.index, 28, "the female label is the dedicated source gender message")
end

function T.window_inventory_names_each_native_message_placement()
  local windows = PartySources.windows
  for _, name in ipairs({ "browse", "context", "action" }) do
    local record = windows[name]
    Assert.notNil(record, "the producer transcribes the " .. name .. " message window")
    Assert.isTrue(
      record.width > 0 and record.height > 0,
      "the " .. name .. " message window has a realized size"
    )
    Assert.isTrue(
      record.x >= 0 and record.y >= 0 and record.x + record.width <= 256 and record.y + record.height <= 192,
      "the " .. name .. " message window fits the native pane"
    )
  end
  Assert.deepEqual(
    windows.prompt,
    { x = 200, y = 80 },
    "the confirm prompt anchors at the source tile-derived position"
  )
end

function T.lowered_menus_cover_every_supported_entry_count()
  local compiled = PartyAssetCompiler.compileGeometry(PartySources)
  local menu = compiled.contextMenu
  Assert.notNil(menu, "geometry lowering publishes the source-shaped context menus")
  Assert.notNil(menu.topLevel, "the top-level menu section resolves")
  Assert.notNil(menu.subcontext, "the subcontext menu section resolves")
  for count = 2, 8 do
    local layout = menu.topLevel[count] or menu.topLevel[tostring(count)]
    Assert.notNil(layout, "the top-level menu covers " .. count .. " entries")
    Assert.equal(#layout, count, "the " .. count .. "-entry top-level layout carries one record per entry")
  end
  for count = 2, 5 do
    local layout = menu.subcontext[count] or menu.subcontext[tostring(count)]
    Assert.notNil(layout, "the subcontext menu covers " .. count .. " entries")
    Assert.equal(#layout, count, "the " .. count .. "-entry subcontext layout carries one record per entry")
  end
  Assert.isTrue(
    (menu.topLevel[1] or menu.topLevel["1"]) == nil,
    "unsupported top-level counts have no fallback layout"
  )
  Assert.isTrue(
    (menu.topLevel[9] or menu.topLevel["9"]) == nil,
    "unsupported top-level counts have no fallback layout"
  )
  Assert.isTrue(
    (menu.subcontext[1] or menu.subcontext["1"]) == nil,
    "unsupported subcontext counts have no fallback layout"
  )
  Assert.isTrue(
    (menu.subcontext[6] or menu.subcontext["6"]) == nil,
    "unsupported subcontext counts have no fallback layout"
  )
end

function T.lowered_menu_entries_carry_geometry_touch_and_navigation()
  local compiled = PartyAssetCompiler.compileGeometry(PartySources)
  local menu = assert(compiled.contextMenu, "menu layouts resolve before entry inspection")
  local layout = menu.topLevel[8] or menu.topLevel["8"]
  Assert.notNil(layout, "the widest top-level layout resolves before entry inspection")
  local styles = {}
  for index, entry in ipairs(layout) do
    local where = "top-level entry " .. index
    Assert.notNil(entry.textRect, where .. " publishes its text rectangle")
    Assert.isTrue(entry.textRect.width > 0 and entry.textRect.height > 0, where .. " text size is realized")
    Assert.notNil(entry.frameRect, where .. " publishes its outer frame rectangle")
    Assert.isTrue(entry.frameRect.width > 0 and entry.frameRect.height > 0, where .. " frame size is realized")
    Assert.isTrue(
      entry.frameShape == "standard" or entry.frameShape == "cancel",
      where .. " names its native frame shape"
    )
    Assert.isTrue(type(entry.style) == "string" and #entry.style > 0, where .. " names its text/fill style")
    styles[entry.style] = true
    Assert.notNil(entry.touch, where .. " publishes its touch rectangle")
    for _, neighbor in pairs({ up = entry.up, down = entry.down, left = entry.left, right = entry.right }) do
      if neighbor ~= nil then
        Assert.isTrue(
          neighbor >= 1 and neighbor <= #layout and neighbor % 1 == 0,
          where .. " neighbors address semantic entries"
        )
      end
    end
    Assert.notNil(entry.left, where .. " keeps the source lateral relation")
    Assert.notNil(entry.right, where .. " keeps the source lateral relation")
  end
  local distinct = 0
  for _ in pairs(styles) do
    distinct = distinct + 1
  end
  Assert.isTrue(distinct >= 2, "the widest layout distinguishes entry style families")
  local sub = menu.subcontext[2] or menu.subcontext["2"]
  Assert.notNil(sub, "the smallest subcontext layout resolves before entry inspection")
  for index, entry in ipairs(sub) do
    Assert.isNil(entry.left, "subcontext entry " .. index .. " has no source lateral relation")
    Assert.isNil(entry.right, "subcontext entry " .. index .. " has no source lateral relation")
  end
end

function T.gender_offset_names_the_name_window_local_mark()
  Assert.deepEqual(PartySources.genderOffset, { x = 64, y = 0 }, "the gender mark sits at name-window-local (64,0)")
  local compiled = PartyAssetCompiler.compileGeometry(PartySources)
  Assert.equal(#compiled.panels, 6, "every slot lowers its gender origin")
  for slot, panel in ipairs(compiled.panels) do
    Assert.notNil(panel.text.name, "panel " .. slot .. " carries its name subrect")
    local name = panel.text.name
    Assert.deepEqual(
      panel.text.gender,
      { x = name.x + 64, y = name.y },
      "panel " .. slot .. " resolves the mark from its name-subrect origin"
    )
  end
end

function T.text_palette_roles_name_the_source_printer_slots()
  local roles = PartySources.textRoles
  Assert.notNil(roles, "the producer transcribes the party text palette roles")
  Assert.deepEqual(roles.ordinary, { 15, 14, 0 }, "ordinary text uses the panel printer slots")
  Assert.deepEqual(roles.male, { 3, 4, 0 }, "male text uses the source gender slots")
  Assert.deepEqual(roles.female, { 5, 6, 0 }, "female text uses the source gender slots")
end

return { tests = T }
