-- Mailbox cursor/chrome exact-spec pass: the cursor flash follows the
-- selected retail grid input (anim 5 on mail rows, anim 4 only on CLOSE
-- at (224,176)), sprite 3 draws static at (224,176) with anim 2 every
-- list frame, and the page arrows hide per side at the page ends. Driven
-- through the real renderer with seeded image identities behind
-- FakeGraphics, so no GPU or ROM is used.

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
  cursorClose = "mailbox-cursor-test/anim4-f0",
  cursorCell = "mailbox-cursor-test/anim5-f0",
  listMenu = "mailbox-cursor-test/list-menu-tiles",
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
        listMenu = {
          tiles = { image = PATHS.listMenu, width = 8 * 22, height = 8, anchorX = 0, anchorY = 0 },
          palette = {
            { r = 8, g = 8, b = 8 },
            { r = 16, g = 16, b = 16 },
            { r = 0, g = 0, b = 0 },
            { r = 216, g = 232, b = 216 },
            { r = 248, g = 248, b = 248 },
            { r = 88, g = 88, b = 88 },
            { r = 168, g = 200, b = 168 },
            { r = 8, g = 8, b = 8 },
            { r = 16, g = 16, b = 16 },
            { r = 0, g = 0, b = 0 },
            { r = 216, g = 232, b = 216 },
            { r = 248, g = 248, b = 248 },
            { r = 88, g = 88, b = 88 },
            { r = 168, g = 200, b = 168 },
            { r = 8, g = 8, b = 8 },
            { r = 16, g = 16, b = 16 },
          },
        },
        animations = {
          [0] = { frames = { frame(PATHS.arrowPrevious) } },
          [1] = { frames = { frame(PATHS.arrowNext) } },
          [2] = { frames = { frame(PATHS.closeStatic) } },
          [4] = { frames = { frame(PATHS.cursorClose) } },
          [5] = { frames = { frame(PATHS.cursorCell) } },
        },
      },
    },
    mail = {
      stationery = {
        [0] = { background = { image = PATHS.stationery, anchorX = 0, anchorY = 0 } },
      },
      geometry = {
        iconSlots = 3,
        iconLocations = { { x = 128, y = 160 }, { x = 88, y = 160 }, { x = 48, y = 160 } },
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

-- The interface geometry every mailbox draw uses (the plan carries this same
-- record); the renderer tests draw without a presentation session.
local GEOMETRY = MailboxInterface.geometry

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
    getDimensions = function()
      return 16, 16
    end,
  }
  pool:seedPhysical(path, SAMPLER, { image = marker })
  return marker
end

local function harness(customManifest)
  local pool = SharedImagePoolFake.new()
  for _, path in pairs(PATHS) do
    seed(pool, path)
  end
  local lg = FakeGraphics.new({})
  local renderer = MailboxRenderer.new({
    manifest = customManifest or manifest(),
    graphics = lg,
    imagePool = pool,
    catalog = {
      template = function()
        return nil
      end,
      messageStatus = function()
        return "invalid"
      end,
      expandMessage = function(tokens)
        return tokens
      end,
    },
  })
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
    lineWidth = function(_)
      return 8
    end,
    drawLineWithPalette = function(_, tokens, x, y)
      record[#record + 1] = { kind = "line", tokens = tokens, x = x, y = y }
    end,
    drawTextWithPalette = function(_, value, x, y)
      record[#record + 1] = { kind = "text", value = value, x = x, y = y }
    end,
    windowBackgroundColor = function()
      return { 0, 0, 0, 1 }
    end,
  }
end

local function resources(textRecord)
  return {
    textRenderer = textStub(textRecord),
    mailViewGeometry = {
      author = { x = 168, y = 161 },
      lines = {
        { x = 24, y = 24, width = 208, height = 32 },
        { x = 24, y = 64, width = 208, height = 32 },
        { x = 24, y = 104, width = 208, height = 32 },
      },
    },
    monIconProvider = {
      dimensions = function()
        return { width = 32, height = 32 }
      end,
      handleFor = function(_, iconKey)
        return { image = { marker = iconKey, released = false, setFilter = function() end }, kind = "rgba8" }
      end,
      quadFor = function()
        return {}
      end,
    },
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

-- The recorded draws and rectangles one draw call appended: the merged
-- cursor cases share one recorder, so each case reads only its own frame.
---@param lg table fake graphics namespace under assertion
---@param path string seeded image identity
---@param from integer recorded draw count before the frame
---@return table[]
local function drawnSince(lg, path, from)
  local found = {}
  for index = from + 1, #lg.draws do
    local draw = lg.draws[index]
    if type(draw.image) == "table" and draw.image.marker == path then
      found[#found + 1] = draw
    end
  end
  return found
end

---@param lg table fake graphics namespace under assertion
---@param from integer recorded rectangle count before the frame
---@return table? the last 112x32 nameplate fill of the frame
local function nameplateSince(lg, from)
  local highlight
  for index = from + 1, #lg.rectangles do
    local rect = lg.rectangles[index]
    if rect.mode == "fill" and rect.w == 112 and rect.h == 32 then
      highlight = rect
    end
  end
  return highlight
end

function T.read_letter_centers_icons_and_keeps_the_source_author_anchor()
  local _, lg, renderer = harness()
  local status = {
    mode = "read",
    viewMode = "read",
    letter = {
      type = 0,
      author = { name = "MISTY" },
      lines = { false, false, false },
      icons = { "CHIKORITA/f0", false, false },
    },
    icons = { { iconKey = "CHIKORITA/f0" } },
    view = {
      mode = "read",
      stationeryType = 0,
      letter = {
        type = 0,
        author = { name = "MISTY" },
        lines = { false, false, false },
        icons = { "CHIKORITA/f0", false, false },
      },
      icons = { { iconKey = "CHIKORITA/f0" } },
    },
  }
  prepare(renderer, status)
  local textRecord = {}
  renderer:draw(status, resources(textRecord), GEOMETRY)
  -- The source icon locations are sprite centers: the 32x32 frame centers on
  -- them instead of starting there.
  local icon = drawsWith(lg, "CHIKORITA/f0")
  Assert.equal(#icon, 1, "one stored icon draws")
  Assert.deepEqual({ icon[1].x, icon[1].y }, { 112, 144 }, "the icon centers on its source anchor (128,160)")
  local author
  for _, entry in ipairs(textRecord) do
    if entry.kind == "text" and entry.value == "MISTY" then
      author = entry
      break
    end
  end
  Assert.notNil(author, "the stored author draws")
  Assert.deepEqual({ author.x, author.y }, { 168, 161 }, "the author uses the source window anchor")
  renderer:release()
end

-- Every row cursor draws its cell-anim flash on the decoded grid cell
-- center and highlights that nameplate: both columns, the last cell, and
-- an open action menu keep the cell anim, while the static CLOSE target
-- stays parked at its own anchor on every list frame.
function T.row_cursors_anchor_each_retail_grid_cell()
  local cases = {
    { label = "the first column", input = 0, x = 64, y = 16, plateX = 8, plateY = 0 },
    { label = "the second column", input = 1, x = 192, y = 16, plateX = 136, plateY = 0 },
    { label = "the last cell", input = 9, x = 192, y = 144, plateX = 136, plateY = 128 },
  }
  local _, lg, renderer = harness()
  for _, case in ipairs(cases) do
    local status = listStatus({
      rows = { row(case.input, true, case.input) },
      selectedSlot = case.input,
      cursorInput = case.input,
      visibleSlots = { case.input },
    })
    prepare(renderer, status)
    local draws, rectangles = #lg.draws, #lg.rectangles
    renderer:draw(status, resources({}), GEOMETRY)
    local cell = drawnSince(lg, PATHS.cursorCell, draws)
    Assert.equal(#cell, 1, case.label .. " draws one cell-anim cursor flash")
    Assert.deepEqual({ cell[1].x, cell[1].y }, { case.x, case.y }, case.label .. " anchors on its decoded grid cell")
    Assert.equal(#drawnSince(lg, PATHS.cursorClose, draws), 0, case.label .. " never draws the CLOSE anim")
    local highlight = assert(nameplateSince(lg, rectangles), case.label .. " highlights its nameplate cell")
    Assert.deepEqual(
      { highlight.x, highlight.y },
      { case.plateX, case.plateY },
      case.label .. " highlights its own nameplate, not a full-width bar"
    )
    local close = drawnSince(lg, PATHS.closeStatic, draws)
    Assert.equal(#close, 1, case.label .. " keeps sprite 3 drawn")
    Assert.deepEqual(
      { close[1].x, close[1].y },
      { 224, 176 },
      case.label .. " parks sprite 3 at the decoded CLOSE anchor"
    )
    Assert.equal(
      #drawnSince(lg, PATHS.arrowPrevious, draws),
      0,
      case.label .. " draws no previous arrow on a single page"
    )
    Assert.equal(#drawnSince(lg, PATHS.arrowNext, draws), 0, case.label .. " draws no next arrow on a single page")
  end
  -- The open action menu covers the list without changing its cursor: the
  -- selected row keeps the cell anim instead of switching to the CLOSE anim.
  local action = listStatus({
    phase = "action",
    rows = { row(0, true, 0) },
    selectedSlot = 0,
    cursorInput = 0,
    visibleSlots = { 0 },
    menuActions = { "read", "cancel" },
    actionIndex = 1,
  })
  prepare(renderer, action)
  local draws = #lg.draws
  renderer:draw(action, resources({}), GEOMETRY)
  Assert.equal(#drawnSince(lg, PATHS.cursorCell, draws), 1, "the open action menu keeps the cell-anim cursor")
  Assert.equal(#drawnSince(lg, PATHS.cursorClose, draws), 0, "the open action menu never draws the CLOSE anim")
  renderer:release()
end

-- CLOSE focus parks one anim-4 cursor on the decoded CLOSE anchor whether
-- the list still draws rows or is empty: no row cursor draws without a
-- selected row.
function T.close_focus_parks_the_cursor_on_close_anim()
  local cases = {
    { label = "an unselected row", rows = { row(8, false, 8) }, visibleSlots = { 8 } },
    { label = "an empty list", rows = {}, visibleSlots = {} },
  }
  local _, lg, renderer = harness()
  for _, case in ipairs(cases) do
    local status = listStatus({
      rows = case.rows,
      selectedSlot = nil,
      cursorInput = 10,
      visibleSlots = case.visibleSlots,
    })
    prepare(renderer, status)
    local draws = #lg.draws
    renderer:draw(status, resources({}), GEOMETRY)
    local parked = drawnSince(lg, PATHS.cursorClose, draws)
    Assert.equal(#parked, 1, case.label .. " parks one close-anim cursor on CLOSE")
    Assert.deepEqual({ parked[1].x, parked[1].y }, { 224, 176 }, "CLOSE uses the decoded grid anchor")
    Assert.equal(#drawnSince(lg, PATHS.cursorCell, draws), 0, case.label .. " draws no cell anim without a selection")
  end
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
  renderer:draw(status, resources({}), GEOMETRY)
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
  relit:draw(open, resources({}), GEOMETRY)
  Assert.equal(#drawsWith(lit, PATHS.closeStatic), 1, "the flash shows sprite 3 on even ticks")
  relit:release()
end

-- Each page end offers only the arrow that can still move: the first page
-- keeps NEXT, the last page keeps PREVIOUS.
function T.page_arrows_hide_per_side_at_the_page_ends()
  local _, first, renderer = harness()
  local firstPage = listStatus({ lastPage = 1, page = 0, cursorInput = 10 })
  prepare(renderer, firstPage)
  renderer:draw(firstPage, resources({}), GEOMETRY)
  local nextDraws = drawsWith(first, PATHS.arrowNext)
  Assert.equal(#nextDraws, 1, "the next arrow draws on the first page")
  Assert.deepEqual({ nextDraws[1].x, nextDraws[1].y }, { 56, 176 }, "the next arrow centers on its retail anchor")
  Assert.equal(#drawsWith(first, PATHS.arrowPrevious), 0, "no previous arrow draws on the first page")
  renderer:release()

  local _, second, paged = harness()
  local lastPage = listStatus({ lastPage = 1, page = 1, cursorInput = 10 })
  prepare(paged, lastPage)
  paged:draw(lastPage, resources({}), GEOMETRY)
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

function T.interface_geometry_carries_the_retail_cursor_geometry()
  local plan = MailboxInterface.geometry
  local grid = assert(plan.cursorGrid, "the mailbox geometry carries its cursor grid")
  Assert.equal(grid.closeInput, 10, "input 10 is CLOSE")
  Assert.equal(#grid.cells, 11, "the grid covers inputs 0-10")
  Assert.deepEqual(grid.cells[1], { x = 64, y = 16 }, "input 0 anchors the first mail cell")
  Assert.deepEqual(grid.cells[10], { x = 192, y = 144 }, "input 9 anchors the last mail cell")
  Assert.deepEqual(grid.cells[11], { x = 224, y = 176 }, "input 10 anchors CLOSE")
  local controls = assert(plan.pageControls, "the mailbox geometry carries its page controls")
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
  -- MailboxApp_OpenMailMenu frames the shared touchscreen list menu from
  -- tile column 18 with eleven middle tiles: four actions from row 5, the
  -- two-action list from row 11. Prompts print in the framed message box.
  Assert.deepEqual(
    plan.actionMenu,
    { x = 18, y = 5, width = 11, emptyPartyY = 11 },
    "the action menu uses its source frame"
  )
  Assert.deepEqual(
    plan.confirmation,
    { x = 16, y = 152, width = 216, height = 32 },
    "prompts use the source message box"
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
    renderer:draw(status, resources({}), GEOMETRY)
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
    cursorRenderer:draw(rowStatus, resources({}), GEOMETRY)
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
    outOfRange:draw(ranged, resources({}), GEOMETRY)
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
  local gridOk, gridFailure = pcall(function()
    prepare(gridless, planar)
    gridless:draw(planar, resources({}), { pageControls = GEOMETRY.pageControls })
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
    rowless:draw(derived, resources({}), GEOMETRY)
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
  Assert.isTrue(acquisitions > 0, "preparation borrows the drawn visuals")
  local drawnAcquisitions = acquisitions
  renderer:draw(status, resources({}), GEOMETRY)
  Assert.equal(acquisitions, drawnAcquisitions, "drawing never borrows from the shared image owner")
  local releases = 0
  local release = pool.release
  pool.release = function(self, lease)
    releases = releases + 1
    return release(self, lease)
  end
  renderer:release()
  Assert.equal(releases, acquisitions, "each installed lease returns exactly once")
  Assert.equal(pool:stats().outstandingLeases, 0, "no borrowed image stays outstanding after release")
  renderer:release()
  Assert.equal(releases, acquisitions, "a second release returns nothing twice")
end

return { tests = T }
