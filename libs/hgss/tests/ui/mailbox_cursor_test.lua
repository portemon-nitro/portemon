-- Mailbox cursor/chrome exact-spec pass: the cursor flash follows the
-- selected retail grid input (anim 5 on mail rows, anim 4 only on CLOSE
-- at (224,176)), sprite 3 draws static at (224,176) with anim 2 every
-- list frame, anim 3 stays compiled but undrawn, and the page arrows
-- hide per side at the page ends. Driven through the real renderer with
-- seeded image identities behind FakeGraphics, so no GPU or ROM is used.

local Assert = require("tests.support.Assert")
local FakeGraphics = require("tests.support.FakeGraphics")
local MailboxInterface = require("game.hgss.src.pc.MailboxInterface")
local MailboxRenderer = require("libs.hgss.src.ui.MailboxRenderer")
local PcSources = require("romdump.src.config.PcSources")
local SharedImagePoolFake = require("tests.support.SharedImagePoolFake")

local T = {}

local SAMPLER = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }

local PATHS = {
  background = "mailbox-cursor-test/background",
  stationery = "mailbox-cursor-test/stationery-0",
  arrowPrevious = "mailbox-cursor-test/anim0-f0",
  arrowNext = "mailbox-cursor-test/anim1-f0",
  closeStatic = "mailbox-cursor-test/anim2-f0",
  deadAnim = "mailbox-cursor-test/anim3-f0",
  cursorClose = "mailbox-cursor-test/anim4-f0",
  cursorCell = "mailbox-cursor-test/anim5-f0",
}

local function frame(path)
  return { image = path, width = 16, height = 16, anchorX = 0, anchorY = 0, duration = 1 }
end

local function glyphLine()
  return { { kind = "glyph", code = 1 } }
end

local function manifest()
  return {
    mailbox = {
      background = { main = { image = PATHS.background, anchorX = 0, anchorY = 0 } },
      ui = {
        animations = {
          [0] = { frames = { frame(PATHS.arrowPrevious) } },
          [1] = { frames = { frame(PATHS.arrowNext) } },
          [2] = { frames = { frame(PATHS.closeStatic) } },
          [3] = { frames = { frame(PATHS.deadAnim) } },
          [4] = { frames = { frame(PATHS.cursorClose) } },
          [5] = { frames = { frame(PATHS.cursorCell) } },
        },
      },
    },
    mail = {
      stationery = {
        [0] = { background = { image = PATHS.stationery, anchorX = 0, anchorY = 0 } },
      },
    },
    text = {
      banks = {
        [232] = {
          [0] = glyphLine(),
          [2] = glyphLine(),
          [3] = glyphLine(),
          [5] = glyphLine(),
          [8] = glyphLine(),
          [9] = glyphLine(),
        },
      },
    },
  }
end

local function display()
  return { width = 256, height = 192, topology = {}, pixelRatio = 1 }
end

local function row(slot, selected, input, stationeryType)
  return {
    slot = slot,
    input = input,
    letter = { type = stationeryType or 0, author = { name = "MISTY" } },
    selected = selected,
    itemIconKey = "icon-mail-0",
  }
end

local function listStatus(opts)
  return {
    mode = "mailbox",
    viewMode = "mailbox",
    phase = opts.phase or "list",
    page = opts.page or 0,
    lastPage = opts.lastPage or 0,
    selectedSlot = opts.selectedSlot,
    cursorInput = opts.cursorInput,
    closeFlash = opts.closeFlash,
    visibleSlots = opts.visibleSlots or {},
    rows = opts.rows or {},
    menuActions = opts.menuActions or {},
    actionIndex = opts.actionIndex or 1,
    presentation = MailboxInterface.plan(display(), "mailbox", {}),
  }
end

local function seed(pool, path)
  local marker = {
    marker = path,
    setFilter = function() end,
    getWidth = function()
      return 16
    end,
    getHeight = function()
      return 16
    end,
  }
  pool:seedPhysical(path, SAMPLER, { image = marker })
  return marker
end

local function harness(customManifest)
  local pool = SharedImagePoolFake.new()
  for _, path in pairs(PATHS) do
    if path ~= PATHS.deadAnim then
      seed(pool, path)
    end
  end
  local lg = FakeGraphics.new({})
  local renderer = MailboxRenderer.new({ manifest = customManifest or manifest(), graphics = lg, imagePool = pool })
  return pool, lg, renderer
end

local function prepare(renderer, status)
  local deadline = os.clock() + 5
  while true do
    local ready, failure = renderer:prepare(status)
    if ready then
      return
    end
    Assert.isNil(failure, "mailbox cursor visuals prepare: " .. tostring(failure))
    Assert.isTrue(os.clock() < deadline, "mailbox cursor visuals prepare without stalling")
  end
end

local function textStub(record)
  return {
    fontDef = { lineHeight = 12, charmap = {} },
    drawLine = function(_, tokens, x, y)
      record[#record + 1] = { kind = "line", x = x, y = y }
    end,
    drawText = function(_, value, x, y)
      record[#record + 1] = { kind = "text", value = value, x = x, y = y }
    end,
    textWidth = function(_)
      return 8
    end,
    windowBackgroundColor = function()
      return { 0, 0, 0, 1 }
    end,
  }
end

local function resources(textRecord)
  return {
    textRenderer = textStub(textRecord),
    itemIconProvider = {
      handle = function()
        return nil
      end,
      image = function()
        return { setFilter = function() end }
      end,
      quadFor = function()
        return {}
      end,
    },
    windowRenderer = {
      drawWindow = function() end,
    },
    applicationFrameIndex = 0,
  }
end

local function drawsWith(lg, path)
  local found = {}
  for _, draw in ipairs(lg.draws) do
    if type(draw.image) == "table" and draw.image.marker == path then
      found[#found + 1] = draw
    end
  end
  return found
end

function T.row_selection_uses_the_cell_anim_in_list_phase()
  local _, lg, renderer = harness()
  local status = listStatus({ rows = { row(0, true, 0) }, selectedSlot = 0, cursorInput = 0, visibleSlots = { 0 } })
  prepare(renderer, status)
  renderer:draw(status, resources({}))
  local cell = drawsWith(lg, PATHS.cursorCell)
  Assert.equal(#cell, 1, "the selected row draws one cell-anim cursor flash")
  Assert.deepEqual({ cell[1].x, cell[1].y }, { 64, 16 }, "the row cursor anchors on its decoded grid cell")
  Assert.equal(#drawsWith(lg, PATHS.cursorClose), 0, "anim 4 never draws on a mail row")
  renderer:release()
end

function T.second_column_rows_anchor_the_right_cells_with_a_nameplate_highlight()
  local _, lg, renderer = harness()
  local status = listStatus({
    rows = { row(0, false, 0), row(1, true, 1) },
    selectedSlot = 1,
    cursorInput = 1,
    visibleSlots = { 0, 1 },
  })
  prepare(renderer, status)
  local record = {}
  renderer:draw(status, resources(record))
  local cell = drawsWith(lg, PATHS.cursorCell)
  Assert.equal(#cell, 1, "the right-column row draws one cell-anim cursor flash")
  Assert.deepEqual({ cell[1].x, cell[1].y }, { 192, 16 }, "the right-column cursor uses input 1")
  local highlight = nil
  for _, rect in ipairs(lg.rectangles) do
    if rect.mode == "fill" and rect.w == 112 and rect.h == 32 then
      highlight = rect
    end
  end
  Assert.isTrue(highlight ~= nil, "the selected row highlights its nameplate cell")
  Assert.deepEqual(
    { highlight.x, highlight.y },
    { 136, 0 },
    "input 1 highlights the right-column nameplate, not a full-width bar"
  )
  renderer:release()
end

function T.bottom_row_selection_anchors_the_last_nameplate_cell()
  local _, lg, renderer = harness()
  local status = listStatus({
    rows = { row(9, true, 9) },
    selectedSlot = 9,
    cursorInput = 9,
    visibleSlots = { 9 },
  })
  prepare(renderer, status)
  renderer:draw(status, resources({}))
  local cell = drawsWith(lg, PATHS.cursorCell)
  Assert.equal(#cell, 1, "the bottom row draws one cell-anim cursor flash")
  Assert.deepEqual({ cell[1].x, cell[1].y }, { 192, 144 }, "input 9 anchors the last mail cell")
  local highlight = nil
  for _, rect in ipairs(lg.rectangles) do
    if rect.mode == "fill" and rect.w == 112 and rect.h == 32 then
      highlight = rect
    end
  end
  Assert.isTrue(highlight ~= nil, "the bottom row highlights its nameplate cell")
  Assert.deepEqual({ highlight.x, highlight.y }, { 136, 128 }, "input 9 highlights the last nameplate")
  Assert.equal(#drawsWith(lg, PATHS.cursorClose), 0, "anim 4 never draws on a mail row")
  renderer:release()
end

function T.close_focus_parks_the_cursor_with_the_close_anim()
  local _, lg, renderer = harness()
  local status = listStatus({
    rows = { row(8, false, 8) },
    selectedSlot = nil,
    cursorInput = 10,
    visibleSlots = { 8 },
  })
  prepare(renderer, status)
  renderer:draw(status, resources({}))
  local parked = drawsWith(lg, PATHS.cursorClose)
  Assert.equal(#parked, 1, "CLOSE focus draws one close-anim cursor flash")
  Assert.deepEqual({ parked[1].x, parked[1].y }, { 224, 176 }, "CLOSE uses the decoded grid anchor")
  Assert.equal(#drawsWith(lg, PATHS.cursorCell), 0, "the cell anim never draws on CLOSE")
  renderer:release()
end

function T.close_flash_blinks_the_static_close_target()
  local _, lg, renderer = harness()
  local status = listStatus({
    rows = { row(8, false, 8) },
    selectedSlot = nil,
    cursorInput = 10,
    visibleSlots = { 8 },
    closeFlash = { ticks = 1 },
  })
  prepare(renderer, status)
  renderer:draw(status, resources({}))
  Assert.equal(#drawsWith(lg, PATHS.closeStatic), 0, "the flash hides sprite 3 on odd ticks")
  renderer:release()

  local _, lit, relit = harness()
  local open = listStatus({
    rows = { row(8, false, 8) },
    selectedSlot = nil,
    cursorInput = 10,
    visibleSlots = { 8 },
    closeFlash = { ticks = 0 },
  })
  prepare(relit, open)
  relit:draw(open, resources({}))
  Assert.equal(#drawsWith(lit, PATHS.closeStatic), 1, "the flash shows sprite 3 on even ticks")
  relit:release()
end

function T.row_selection_keeps_the_cell_anim_with_the_action_menu_open()
  local _, lg, renderer = harness()
  local status = listStatus({
    phase = "action",
    rows = { row(0, true, 0) },
    selectedSlot = 0,
    cursorInput = 0,
    visibleSlots = { 0 },
    menuActions = { "read", "cancel" },
    actionIndex = 1,
  })
  prepare(renderer, status)
  renderer:draw(status, resources({}))
  Assert.equal(#drawsWith(lg, PATHS.cursorCell), 1, "the open action menu keeps the cell-anim cursor")
  Assert.equal(#drawsWith(lg, PATHS.cursorClose), 0, "anim 4 never draws on a mail row")
  renderer:release()
end

function T.empty_list_parks_the_cursor_on_close_with_the_close_anim()
  local _, lg, renderer = harness()
  local status = listStatus({ rows = {}, selectedSlot = nil, cursorInput = 10, visibleSlots = {} })
  prepare(renderer, status)
  renderer:draw(status, resources({}))
  local parked = drawsWith(lg, PATHS.cursorClose)
  Assert.equal(#parked, 1, "no selection parks one close-anim cursor on CLOSE")
  Assert.deepEqual({ parked[1].x, parked[1].y }, { 224, 176 }, "the CLOSE cursor uses the decoded grid anchor")
  Assert.equal(#drawsWith(lg, PATHS.cursorCell), 0, "the cell anim never draws without a selected row")
  renderer:release()
end

function T.static_close_target_draws_on_every_list_frame()
  local _, lg, renderer = harness()
  local status = listStatus({ rows = { row(0, true, 0) }, selectedSlot = 0, cursorInput = 0, visibleSlots = { 0 } })
  prepare(renderer, status)
  renderer:draw(status, resources({}))
  local close = drawsWith(lg, PATHS.closeStatic)
  Assert.equal(#close, 1, "sprite 3 draws its anim-2 frame on a single page with no arrows")
  Assert.deepEqual({ close[1].x, close[1].y }, { 224, 176 }, "sprite 3 uses the decoded CLOSE anchor")
  Assert.equal(#drawsWith(lg, PATHS.arrowPrevious), 0, "no previous arrow draws on a single page")
  Assert.equal(#drawsWith(lg, PATHS.arrowNext), 0, "no next arrow draws on a single page")
  renderer:release()
end

function T.dead_anim_stays_compiled_but_undrawn()
  local pool, lg, renderer = harness()
  local listed = listStatus({ rows = { row(4, true, 4) }, selectedSlot = 4, cursorInput = 4, visibleSlots = { 4 } })
  prepare(renderer, listed)
  renderer:draw(listed, resources({}))
  local empty = listStatus({ rows = {}, selectedSlot = nil, cursorInput = 10, visibleSlots = {} })
  prepare(renderer, empty)
  renderer:draw(empty, resources({}))
  Assert.equal(#drawsWith(lg, PATHS.deadAnim), 0, "anim 3 never draws on rows or CLOSE")
  Assert.isNil(pool:findPhysical(PATHS.deadAnim, SAMPLER), "anim 3 is never enrolled")
  Assert.equal(pool.uploads, 0, "no unseeded visual is constructed behind the cursor pass")
  renderer:release()
end

function T.page_arrows_hide_per_side_at_the_page_ends()
  local _, first, renderer = harness()
  prepare(renderer, listStatus({ lastPage = 1, page = 0, cursorInput = 10 }))
  renderer:draw(listStatus({ lastPage = 1, page = 0, cursorInput = 10 }), resources({}))
  local nextDraws = drawsWith(first, PATHS.arrowNext)
  Assert.equal(#nextDraws, 1, "the next arrow draws on the first page")
  Assert.deepEqual({ nextDraws[1].x, nextDraws[1].y }, { 56, 176 }, "the next arrow centers on its retail anchor")
  Assert.equal(#drawsWith(first, PATHS.arrowPrevious), 0, "no previous arrow draws on the first page")
  renderer:release()

  local _, second, paged = harness()
  prepare(paged, listStatus({ lastPage = 1, page = 1, cursorInput = 10 }))
  paged:draw(listStatus({ lastPage = 1, page = 1, cursorInput = 10 }), resources({}))
  local previousDraws = drawsWith(second, PATHS.arrowPrevious)
  Assert.equal(#previousDraws, 1, "the previous arrow draws on the last page")
  Assert.deepEqual(
    { previousDraws[1].x, previousDraws[1].y },
    { 24, 176 },
    "the previous arrow centers on its retail anchor"
  )
  Assert.equal(#drawsWith(second, PATHS.arrowNext), 0, "no next arrow draws on the last page")
  paged:release()
end

function T.interface_plan_carries_the_retail_cursor_geometry()
  local plan = MailboxInterface.plan(display(), "mailbox", {})
  local grid = assert(plan.cursorGrid, "the mailbox plan carries its cursor grid")
  Assert.equal(grid.closeInput, 10, "input 10 is CLOSE")
  Assert.equal(#grid.cells, 11, "the grid covers inputs 0-10")
  Assert.deepEqual(grid.cells[1], { x = 64, y = 16 }, "input 0 anchors the first mail cell")
  Assert.deepEqual(grid.cells[10], { x = 192, y = 144 }, "input 9 anchors the last mail cell")
  Assert.deepEqual(grid.cells[11], { x = 224, y = 176 }, "input 10 anchors CLOSE")
  local controls = assert(plan.pageControls, "the mailbox plan carries its page controls")
  Assert.deepEqual(
    { controls.previous.x + controls.previous.width / 2, controls.previous.y + controls.previous.height / 2 },
    { 24, 176 },
    "the previous hitbox centers on the retail arrow anchor"
  )
  Assert.deepEqual(
    { controls.next.x + controls.next.width / 2, controls.next.y + controls.next.height / 2 },
    { 56, 176 },
    "the next hitbox centers on the retail arrow anchor"
  )
end

function T.producer_roles_carry_the_cursor_grid_and_static_close()
  local roles = assert(PcSources.mailboxSpriteRoles, "mailbox sprite roles are configured")
  Assert.deepEqual(roles.cursor, { animations = { 4, 5 } }, "the cursor keeps its two flash anims")
  Assert.equal(roles.pagePrevious.animation, 0, "the previous arrow keeps anim 0")
  Assert.equal(roles.pageNext.animation, 1, "the next arrow keeps anim 1")
  local grid = assert(roles.cursorGrid, "the roles carry the cursor grid")
  Assert.equal(grid.closeInput, 10, "input 10 is CLOSE")
  Assert.equal(#grid.cells, 11, "the grid covers inputs 0-10")
  Assert.deepEqual(grid.cells[1], { x = 64, y = 16 }, "input 0 anchors the first mail cell")
  Assert.deepEqual(grid.cells[11], { x = 224, y = 176 }, "input 10 anchors CLOSE")
  Assert.deepEqual(roles.sprite3, { animation = 2, x = 224, y = 176 }, "sprite 3 is the static close target")
end

function T.absent_source_frame_raises_instead_of_painting_a_polygon()
  local missing = manifest()
  missing.mailbox.ui.animations[1] = nil
  local _, lg, renderer = harness(missing)
  local status = listStatus({ lastPage = 1, page = 0, cursorInput = 10, visibleSlots = {} })
  local ok, failure = pcall(function()
    prepare(renderer, status)
    renderer:draw(status, resources({}))
  end)
  Assert.isFalse(ok, "a missing page-arrow frame raises instead of drawing: " .. tostring(failure))
  Assert.equal(#lg.primitives, 0, "no polygon fallback is painted for a missing source frame")
  renderer:release()

  local emptied = manifest()
  emptied.mailbox.ui.animations[5] = { frames = {} }
  local cursorRenderer = select(3, harness(emptied))
  local rowStatus = listStatus({
    rows = { row(0, true, 0) },
    selectedSlot = 0,
    cursorInput = 0,
    visibleSlots = { 0 },
  })
  local cursorOk, cursorFailure = pcall(function()
    prepare(cursorRenderer, rowStatus)
    cursorRenderer:draw(rowStatus, resources({}))
  end)
  Assert.isFalse(
    cursorOk,
    "an animation with no rendered frames raises instead of skipping: " .. tostring(cursorFailure)
  )
  cursorRenderer:release()
end

function T.malformed_cursor_geometry_raises_instead_of_using_a_legacy_path()
  local outOfRange = select(3, harness())
  local ranged = listStatus({
    rows = { row(0, true, 0) },
    selectedSlot = 0,
    cursorInput = 99,
    visibleSlots = { 0 },
  })
  local rangedOk, rangedFailure = pcall(function()
    prepare(outOfRange, ranged)
    outOfRange:draw(ranged, resources({}))
  end)
  Assert.isFalse(rangedOk, "an out-of-range cursor input raises instead of painting: " .. tostring(rangedFailure))
  outOfRange:release()

  local gridless = select(3, harness())
  local planar = listStatus({
    rows = { row(0, true, 0) },
    selectedSlot = 0,
    cursorInput = 0,
    visibleSlots = { 0 },
  })
  planar.presentation = { pageControls = planar.presentation.pageControls }
  local gridOk, gridFailure = pcall(function()
    prepare(gridless, planar)
    gridless:draw(planar, resources({}))
  end)
  Assert.isFalse(gridOk, "a status without the cursor grid raises instead of legacy-marking: " .. tostring(gridFailure))
  gridless:release()

  local rowless = select(3, harness())
  local derived = listStatus({
    rows = {
      {
        slot = 0,
        letter = { type = 0, author = { name = "MISTY" } },
        selected = true,
        itemIconKey = "icon-mail-0",
      },
    },
    selectedSlot = 0,
    cursorInput = 0,
    visibleSlots = { 0 },
  })
  local rowOk, rowFailure = pcall(function()
    prepare(rowless, derived)
    rowless:draw(derived, resources({}))
  end)
  Assert.isFalse(rowOk, "a row without an explicit grid input raises instead of deriving one: " .. tostring(rowFailure))
  rowless:release()
end

function T.bounded_preparation_borrows_outside_draw_and_releases_each_lease_once()
  local full = manifest()
  for stationeryType = 1, 5 do
    full.mail.stationery[stationeryType] = {
      background = {
        image = "mailbox-cursor-test/stationery-" .. stationeryType,
        anchorX = 0,
        anchorY = 0,
      },
    }
  end
  local rows = {}
  local visible = {}
  for slot = 0, 5 do
    rows[#rows + 1] = row(slot, slot == 0, slot, slot)
    visible[#visible + 1] = slot
  end
  local status = listStatus({
    rows = rows,
    selectedSlot = 0,
    cursorInput = 0,
    visibleSlots = visible,
    lastPage = 1,
    page = 0,
  })
  local pool, _, renderer = harness(full)
  local acquisitions = 0
  local acquire = pool.acquire
  pool.acquire = function(self, token)
    acquisitions = acquisitions + 1
    return acquire(self, token)
  end
  local perCall = {}
  local ready, failure = nil, nil
  while not ready do
    local before = acquisitions
    ready, failure = renderer:prepare(status)
    Assert.isNil(failure, "paginated preparation reports no missing visual: " .. tostring(failure))
    perCall[#perCall + 1] = acquisitions - before
    Assert.isTrue(#perCall < 20, "paginated preparation converges instead of stalling")
  end
  Assert.isTrue(#perCall > 1, "several stationery backgrounds need several bounded updates")
  for _, count in ipairs(perCall) do
    Assert.isTrue(count <= 4, "no single update borrows more than four shared images")
  end
  Assert.equal(acquisitions, 10, "every drawn path is borrowed exactly once")
  local drawnAcquisitions = acquisitions
  renderer:draw(status, resources({}))
  Assert.equal(acquisitions, drawnAcquisitions, "drawing never borrows from the shared image owner")
  local releases = 0
  local release = pool.release
  pool.release = function(self, lease)
    releases = releases + 1
    return release(self, lease)
  end
  renderer:release()
  Assert.equal(releases, 10, "each installed lease returns exactly once")
  Assert.equal(pool:stats().outstandingLeases, 0, "no borrowed image stays outstanding after release")
  renderer:release()
  Assert.equal(releases, 10, "a second release returns nothing twice")
end

return { tests = T }
