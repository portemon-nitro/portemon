-- Draws compiled Storage visuals through the paired source presentation plan.

local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local ImageSampling = require("libs.nds.src.love.ImageSampling")
local MonCache = require("libs.assets.src.MonCache")
local MoveIconCache = require("libs.assets.src.MoveIconCache")
local LogicalSurface = require("libs.ui.src.LogicalSurface")
local PcStorageAnimation = require("libs.hgss.src.ui.PcStorageAnimation")
local PcStorageGeometry = require("libs.hgss.src.ui.PcStorageGeometry")

---@class PcStorageRenderer
---@field _graphics love.graphics
---@field _manifest table<string, unknown>
---@field _text table<string, unknown>
---@field _images table<string, love.Image> resolved visual images by path for draw identity
---@field _leases table<string, unknown> installed shared-owner borrows by path
---@field _pool table<string, unknown> the borrowed shared image owner behind every visual
---@field _readySignature string? stable identity of the installed visual group
---@field _pending PcStorageVisualPending? the enrolled visual group resolving outside drawing
---@field _cacheFs table<string, unknown> cache filesystem behind shared mon/move manifests
---@field _monPortraits table<string, unknown>? lazily loaded portrait manifest
---@field _moveIcons table<string, unknown>? lazily loaded move-icon manifest
---@field _quads table<string, love.Quad> shared quads by page rectangle
---@field _animation PcStorageAnimation presentation animation owner
---@field _disposed boolean
local PcStorageRenderer = {}
PcStorageRenderer.__index = PcStorageRenderer

-- Storage visuals sample point-filtered and clamped, matching the shared
-- construction below, so pooled leases draw identically.
local POOLED_SAMPLER = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }

-- Bounds the GPU realizations one update may install, so a cold open
-- spreads its uploads across frames instead of stalling the field. The
-- wallpaper chooser adds four swatch variants plus its cursor on one tick.
local MAX_ACQUISITIONS_PER_UPDATE = 4
-- Editor views stage a whole chooser at once (four swatches, the selection
-- band, its triangle and the bar chrome) so opening one does not gate the host
-- for several frames.
local MAX_EDITOR_ACQUISITIONS_PER_UPDATE = 12

---@class PcStorageVisualPending
---@field signature string stable identity of the resolving visual group
---@field paths string[] every required path in stable order
---@field entries { path: string, token: integer }[] freshly enrolled borrows
---@field tokenByPath table<string, integer> freshly enrolled token by path
---@field staged table<integer, table<string, unknown>> acquired leases by token

-- State visuals borrow instead of owning: each drawn visual holds one
-- installed shared-owner lease, so two opens of one box resolve one
-- physical image per visual through the pool's own dedup.

local ACTION_MESSAGES = {
  deposit = 70,
  withdraw = 69,
  move = 61,
  summary = 65,
  heldItems = 66,
  markings = 67,
  release = 68,
  wallpaper = 26,
  boxName = 27,
  bagItem = 80,
  takeItem = 80,
  giveItem = 81,
  swapItems = 64,
  cancel = 73,
}

local function sourceText(self, messageId, bankId)
  bankId = bankId or 24
  local bank = assert(self._manifest.text.banks[bankId], "Storage borrows source text bank " .. bankId)
  return FieldMessageText.tokensToText(
    assert(bank[messageId], "Storage source message is compiled: " .. bankId .. ":" .. tostring(messageId))
  )
end

local function sourceLabel(self, action)
  local messageId = assert(ACTION_MESSAGES[action], "Storage menu action has a source message")
  return sourceText(self, messageId)
end

---@param pending PcStorageVisualPending
---@return boolean complete every freshly enrolled lease staged its borrow
local function stagedComplete(pending)
  for _, entry in ipairs(pending.entries) do
    if pending.staged[entry.token] == nil then
      return false
    end
  end
  return true
end

-- Resolves one admitted visual lease for drawing. An installed lease wins;
-- a fully staged group also resolves, so a view that just reported ready
-- draws with no image-owner traffic before its cutover installs it.
-- Preparation stages or installs every drawn path before the present, so
-- drawing never enrolls, polls, acquires, sleeps, or creates GPU objects;
-- a missing path is a preparation bug that fails loudly instead of
-- painting a blank visual.
---@param self PcStorageRenderer
---@param visual table<string, unknown>
---@return table<string, unknown> lease resolving the immutable visual
local function imageFor(self, visual)
  assert(type(visual) == "table" and type(visual.image) == "string", "Storage visuals carry image paths")
  local path = visual.image
  local lease = self._leases[path]
  if lease == nil then
    local pending = self._pending
    if pending ~= nil and stagedComplete(pending) then
      local token = pending.tokenByPath[path]
      if token ~= nil then
        lease = pending.staged[token]
      end
    end
  end
  assert(lease ~= nil, "Storage visual was not admitted before drawing: " .. path)
  return lease
end

local function drawVisual(self, visual, x, y)
  self._graphics.setColor(1, 1, 1, 1)
  local offset = visual.offset or { x = 0, y = 0 }
  ImageSampling.draw(self._graphics, imageFor(self, visual), nil, x + offset.x, y + offset.y)
end

-- One 8x8 source cell of a compiled strip/atlas, drawn at (x, y). The 96x8
-- frame atlas and the 8x24 plate columns both resolve through this.
local function drawAtlasTile(self, visual, tileIndex, x, y)
  local path = assert(visual.image, "Storage plate visuals carry their image path")
  local key = path .. ":" .. tileIndex
  local quad = self._quads[key]
  if quad == nil then
    local lease = imageFor(self, visual)
    local image = assert(lease.image, "shared leases carry their resolved image")
    local across = math.floor(visual.width / 8)
    quad = self._graphics.newQuad(
      (tileIndex % across) * 8,
      math.floor(tileIndex / across) * 8,
      8,
      8,
      image:getWidth(),
      image:getHeight()
    )
    self._quads[key] = quad
  end
  self._graphics.setColor(1, 1, 1, 1)
  ImageSampling.draw(self._graphics, imageFor(self, visual), quad, x, y)
end

local function fillColor(self, color)
  local graphics = self._graphics
  graphics.setColor(color.r / 255, color.g / 255, color.b / 255, 1)
end

-- PCBox_DrawButtonWindow: eight named 8x8 tiles of the member-64 frame around
-- a flat interior filled with window palette entry 4 (never the source's
-- unused style 1). Nothing is scaled: the edges tile, the corners sit at the
-- rect corners.
local FRAME_ROLES = {
  topleft = 0,
  top = 1,
  topright = 2,
  left = 3,
  right = 5,
  bottomleft = 9,
  bottom = 10,
  bottomright = 11,
}
local function drawFramePlate(self, rect)
  local frames = assert(self._manifest.storage.ui.windowFrames, "Storage window frames are compiled")
  local atlas = assert(frames.standard and frames.standard.paletteBank0, "Storage button frame is compiled")
  local graphics = self._graphics
  fillColor(self, assert(frames.fill, "Storage window frames carry their interior fill"))
  graphics.rectangle("fill", rect.x + 8, rect.y + 8, rect.width - 16, rect.height - 16)
  graphics.setColor(1, 1, 1, 1)
  local columns, rows = math.floor(rect.width / 8), math.floor(rect.height / 8)
  assert(columns >= 2 and rows >= 2, "Storage plates are at least two tiles on a side")
  drawAtlasTile(self, atlas, FRAME_ROLES.topleft, rect.x, rect.y)
  drawAtlasTile(self, atlas, FRAME_ROLES.topright, rect.x + (columns - 1) * 8, rect.y)
  drawAtlasTile(self, atlas, FRAME_ROLES.bottomleft, rect.x, rect.y + (rows - 1) * 8)
  drawAtlasTile(self, atlas, FRAME_ROLES.bottomright, rect.x + (columns - 1) * 8, rect.y + (rows - 1) * 8)
  for index = 1, rows - 2 do
    drawAtlasTile(self, atlas, FRAME_ROLES.left, rect.x, rect.y + index * 8)
    drawAtlasTile(self, atlas, FRAME_ROLES.right, rect.x + (columns - 1) * 8, rect.y + index * 8)
  end
  for index = 1, columns - 2 do
    drawAtlasTile(self, atlas, FRAME_ROLES.top, rect.x + index * 8, rect.y)
    drawAtlasTile(self, atlas, FRAME_ROLES.bottom, rect.x + index * 8, rect.y + (rows - 1) * 8)
  end
end

-- The tab/summary plate: an 8px left cap, a repeating 8px middle and an 8px
-- right cap, three 8px rows tall (PCBox_DrawTabWindow / _DrawSummaryButton).
local function drawRolePlate(self, rect, role)
  local plates = assert(self._manifest.storage.ui.plates, "Storage plate roles are compiled")
  local plate = assert(plates[role], "Storage plate role is compiled: " .. tostring(role))
  drawVisual(self, plate.left, rect.x, rect.y)
  local x = rect.x + 8
  local right = rect.x + rect.width - 8
  while x < right do
    drawVisual(self, plate.middle, x, rect.y)
    x = x + 8
  end
  drawVisual(self, plate.right, right, rect.y)
end

local function drawPlate(self, rect, style)
  if style == "tab" or style == "summary" then
    drawRolePlate(self, rect, style)
  else
    drawFramePlate(self, rect)
  end
end

-- Centre one line of label text on the plate with the source's button font.
local function labelText(self)
  return self._labelText or self._text
end

local function drawCenteredLine(self, text, centerX, y)
  local renderer = labelText(self)
  renderer:drawText(text, centerX - renderer:textWidth(text) / 2, y)
end

-- A framed plate with one centred text line per source line
-- (PCBox_PrintAligned(..., width*8/2, 4, font 4, align 2)).
local function drawButton(self, rect, label, style)
  drawPlate(self, rect, style)
  local line = 0
  for text in label:gmatch("[^\n]+") do
    drawCenteredLine(self, text, rect.x + rect.width / 2, rect.y + 4 + line * 16)
    line = line + 1
  end
end

-- PCBox_DrawButtonWindow's multi-line variant (PCBox_PrintWindowMessage with
-- align 3): each line is centred inside the plate's one-tile inset content box
-- and prints from the top of that box.
local function drawWindowMessage(self, rect, label, style)
  drawPlate(self, rect, style)
  local centerX = rect.x + rect.width / 2
  local line = 0
  for text in label:gmatch("[^\n]+") do
    drawCenteredLine(self, text, centerX, rect.y + 8 + line * 16)
    line = line + 1
  end
end

-- Lazily loads the shared generated manifests the top-screen info needs.
-- A view without a selected portrait or types never touches them.
function PcStorageRenderer:_portraitManifest()
  if self._monPortraits == nil then
    local manifest = assert(
      self._cacheFs:loadLua(MonCache.portraitManifestPath()),
      "Storage info borrows the compiled portrait manifest"
    )
    assert(type(manifest) == "table" and type(manifest.entries) == "table", "the portrait manifest carries its entries")
    self._monPortraits = manifest
  end
  return self._monPortraits
end

function PcStorageRenderer:_moveIconManifest()
  if self._moveIcons == nil then
    self._moveIcons = MoveIconCache.loadManifest(self._cacheFs)
  end
  return self._moveIcons
end

-- The portrait entry and page geometry behind one selector.
---@param selector string
---@return table<string, unknown> entry
---@return table<string, unknown> page
function PcStorageRenderer:_portraitFor(selector)
  local manifest = self:_portraitManifest()
  local entry = assert(manifest.entries[selector], "the portrait manifest carries " .. selector)
  local page = assert(manifest.pages[entry.pageId], "the portrait manifest carries page " .. tostring(entry.pageId))
  return entry, page
end

-- Draws one shared cache image at its top-left corner.
---@param path string
---@param x number
---@param y number
---@param width number?
---@param height number?
function PcStorageRenderer:_drawImagePath(path, x, y, width, height)
  local lease = imageFor(self, { image = path })
  local quad = nil
  if width ~= nil and height ~= nil then
    local key = path .. ":" .. tostring(width) .. "x" .. tostring(height)
    quad = self._quads[key]
    if quad == nil then
      local image = assert(lease.image, "shared leases carry their resolved image")
      quad = self._graphics.newQuad(0, 0, width, height, image:getWidth(), image:getHeight())
      self._quads[key] = quad
    end
  end
  ImageSampling.draw(self._graphics, lease, quad, x, y)
end

-- Collects the exact generated-image paths one published view draws,
-- branch by branch with the pane rendering below: the upper info pane
-- with the selected mon's marking tiles, the lower base, wallpaper, and
-- box pane, the tray and marking panel while open, the editor chrome,
-- the arrows and cursor of the current pose, and the button frame while
-- any button draws. Hidden wallpapers and undrawn poses never enroll.
---@param self PcStorageRenderer
---@param view table<string, unknown>
---@return string[] sorted required paths
local function requiredPaths(self, view)
  local storage = assert(self._manifest.storage, "Storage borrows its compiled storage manifest")
  local ui = assert(storage.ui, "Storage chrome is compiled")
  local set = {} ---@type table<string, boolean>
  local function add(visual)
    assert(type(visual) == "table" and type(visual.image) == "string", "Storage visuals carry image paths")
    set[visual.image] = true
  end
  -- The top screen carries only the selected mon's info panel.
  add(ui.infoPane)
  local focus = view.focus
  local selected = view.carry and view.carry.mon
  if selected == nil and focus ~= nil then
    local party = focus.domain == "party" or focus.kind == "party"
    local slots = party and view.party or view.boxSlots
    if slots ~= nil then
      selected = slots[focus.slot + 1]
    end
  end
  if type(selected) == "table" then
    local markings = assert(ui.markings, "Storage marking visuals are compiled")
    for bit = 0, 5 do
      local isSet = math.floor(selected.markings / (2 ^ bit)) % 2 == 1
      add(markings[bit][isSet and "set" or "clear"])
    end
  end
  local info = view.info
  if type(info) == "table" then
    if type(info.portraitSelector) == "string" then
      local entry, _ = self:_portraitFor(info.portraitSelector)
      add({ image = MonCache.pageImagePath("portraits", assert(entry.pageId)) })
    end
    if info.egg ~= true and type(info.types) == "table" and #info.types > 0 then
      local icons = self:_moveIconManifest()
      local limit = math.min(2, #info.types)
      for index = 1, limit do
        local visual =
          assert(icons.types[info.types[index]], "the move-icon manifest carries type " .. tostring(info.types[index]))
        add(visual)
      end
    end
    if info.egg ~= true then
      add(view.mode == 3 and ui.itemPanel or ui.movesPanel)
    end
  end
  if type(view.info) == "table" then
    local glyphs = assert(ui.infoGlyphs, "Storage info glyphs are compiled")
    add(glyphs.lv)
    if view.info.dexNumber ~= nil and view.info.dexNumber > 0 then
      add(glyphs.no)
    end
  end
  local message = view.message
  if message ~= nil and message.yesNo == true then
    local prompt = assert(ui.yesNo, "Storage confirmation buttons are compiled")
    add(prompt.yesNormal)
    add(prompt.yesSelected)
    add(prompt.noNormal)
    add(prompt.noSelected)
  end
  add(storage.backgrounds.default)
  local wallpaperId = view.wallpaperId or 0
  add(assert(storage.wallpapers[wallpaperId], "selected wallpaper is compiled"))
  add(ui.boxPane)
  local editor = view.editor
  local trayOpen = view.tray ~= "closed" or view.transferSide ~= nil
  if editor == nil and not trayOpen and view.message == nil and view.boxTray == nil then
    add(ui.arrows.left)
    add(ui.arrows.right)
  end
  if trayOpen then
    add(view.mode >= 2 and ui.partyTrayMove or ui.partyTray)
  end
  if view.boxTray ~= nil then
    add(assert(ui.boxTray, "Storage compiles the box tray strip"))
    add(assert(ui.depositBoxTray, "Storage compiles the deposit tray strip"))
    add(ui.tray.prev)
    add(ui.tray.next)
    add(ui.tray.marker)
    add(ui.tray.cursor)
    add(ui.tray.label)
    local thumbnail = assert(storage.boxThumbnail, "Storage compiles box thumbnails")
    local unlocks = view.wallpaperUnlocks or {}
    for _, entry in ipairs(view.boxTray.boxes) do
      local entryWallpaper = entry.wallpaperId
      local logical = entryWallpaper >= 32 and entryWallpaper - 16 or entryWallpaper
      local unlocked = logical < 16 or unlocks[logical - 15] == true
      add(unlocked and assert(thumbnail.variants[logical]) or thumbnail.locked)
    end
  end
  if editor ~= nil and editor.kind == "markings" then
    add(ui.markingPanel)
  end
  if editor ~= nil then
    if editor.kind == "markings" then
      local markings = assert(ui.panelMarkings, "Storage panel marking visuals are compiled")
      for bit = 0, 5 do
        local marked = math.floor(editor.mask / (2 ^ bit)) % 2 == 1
        add(markings[bit][marked and "set" or "clear"])
      end
    elseif editor.kind == "wallpaper" then
      add(ui.wallpaperBar)
      add(ui.tray.prev)
      add(ui.tray.next)
      add(ui.tray.wallpaperCursor)
      add(ui.tray.marker)
      add(ui.tray.label)
      local art = assert(storage.wallpaperSwatchArt, "Storage compiles wallpaper swatches")
      local pageStart = editor.selected - editor.selected % PcStorageGeometry.WALLPAPER_PAGE_SIZE
      for slot = 0, PcStorageGeometry.WALLPAPER_PAGE_SIZE - 1 do
        local logicalId = pageStart + slot
        local unlocked = logicalId < 16 or (view.wallpaperUnlocks or {})[logicalId - 15] == true
        add(unlocked and assert(art.variants[logicalId]) or art.locked)
      end
      add(
        assert(
          storage.ui.windowFrames.standard.paletteBank0,
          "Storage button frame style and palette bank are compiled"
        )
      )
    else
      error("unknown Storage editor " .. tostring(editor.kind), 0)
    end
  end
  -- The button frame draws while any button draws: the menu list, the
  -- bottom buttons, or the wallpaper confirm pair.
  local needsFrame = editor ~= nil and editor.kind == "wallpaper"
  local needsTab, needsSummary = false, false
  if not needsFrame and self._text.drawText ~= nil then
    needsFrame = view.menu ~= nil or #PcStorageGeometry.bottomButtons(view) > 0
  end
  if view.menu ~= nil then
    for _, action in ipairs(view.menu.actions) do
      if PcStorageGeometry.actionStyle(action) == "tab" then
        needsTab = true
      end
    end
  end
  for _, button in ipairs(PcStorageGeometry.bottomButtons(view)) do
    if button.style == "tab" then
      needsTab = true
    elseif button.style == "summary" then
      needsSummary = true
    end
  end
  if needsFrame then
    add(
      assert(storage.ui.windowFrames.standard.paletteBank0, "Storage button frame style and palette bank are compiled")
    )
  end
  if needsTab or needsSummary then
    local plates = assert(storage.ui.plates, "Storage plate roles are compiled")
    for _, role in ipairs({ needsTab and "tab" or nil, needsSummary and "summary" or nil }) do
      for _, part in ipairs({ "left", "middle", "right" }) do
        add(plates[role][part])
      end
    end
  end
  if view.cursor ~= nil then
    local pose = assert(ui.cursors[view.cursor.pose], "Storage cursor pose is compiled: " .. tostring(view.cursor.pose))
    for _, frame in ipairs(assert(pose.frames, "Storage cursor poses carry their source frames")) do
      add(frame)
    end
  end
  local paths = {} ---@type string[]
  for path in pairs(set) do
    paths[#paths + 1] = path
  end
  table.sort(paths)
  return paths
end

-- Enrolls the freshly needed paths of one visual group: paths the
-- installed group already holds stay on their existing leases without a
-- new request, so a wallpaper turnover borrows only its new wallpaper.
---@param self PcStorageRenderer
---@param pool table<string, unknown>
---@param paths string[]
---@param signature string
---@return PcStorageVisualPending
local function enroll(self, pool, paths, signature)
  local tokenByPath = {} ---@type table<string, integer>
  local entries = {} ---@type { path: string, token: integer }[]
  for _, path in ipairs(paths) do
    if self._leases[path] == nil and tokenByPath[path] == nil then
      local token = pool:request(path, POOLED_SAMPLER, "demand")
      tokenByPath[path] = token
      entries[#entries + 1] = { path = path, token = token }
    end
  end
  return { signature = signature, paths = paths, entries = entries, tokenByPath = tokenByPath, staged = {} }
end

-- Forgets one resolving group without touching the installed state:
-- staged leases return and unconsumed tokens cancel, each exactly once.
---@param pool table<string, unknown>
---@param pending PcStorageVisualPending
local function abandonPending(pool, pending)
  for _, entry in ipairs(pending.entries) do
    local staged = pending.staged[entry.token]
    if staged ~= nil then
      pool:release(staged)
    else
      pool:cancel(entry.token)
    end
  end
  pending.staged = {}
end

-- Installs one fully acquired group atomically: carried-over leases stay
-- borrowed, staged leases move into the installed group, and only the
-- leases the new group no longer needs return.
---@param self PcStorageRenderer
---@param pool table<string, unknown>
---@param pending PcStorageVisualPending
local function publishPending(self, pool, pending)
  local leases = {} ---@type table<string, unknown>
  local images = {} ---@type table<string, love.Image>
  for _, path in ipairs(pending.paths) do
    local lease = self._leases[path]
    if lease == nil then
      lease = assert(
        pending.staged[assert(pending.tokenByPath[path], "every required visual enrolled its token")],
        "every required visual staged its lease"
      )
    end
    leases[path] = lease
    images[path] = assert(lease.image, "shared leases carry their resolved image")
  end
  for path, lease in pairs(self._leases) do
    if leases[path] == nil then
      pool:release(lease)
    end
  end
  self._leases = leases
  self._images = images
  self._readySignature = pending.signature
  self._pending = nil
end

--- Stages one published view outside drawing: enrolls the exact visible
--- paths once, then polls and borrows at most four ready leases per
--- call. Returns true once every required lease is staged or already
--- installed and the view could draw with no image-owner traffic;
--- installation waits for an explicit commit once every other
--- prerequisite for the same view is ready, so a pending replacement
--- never retires the installed group. Returns false while the worker is
--- still resolving, or false with the missing path's cause when a
--- required visual fails. A superseded resolving group never publishes:
--- its partial work returns while the installed group stays drawable.
---@param view table<string, unknown> the published snapshot drawing will use
---@return boolean ready
---@return string? failure the named missing visual when a required path failed
function PcStorageRenderer:prepare(view)
  assert(not self._disposed, "disposed Storage renderer prepares nothing")
  assert(type(view) == "table", "Storage preparation requires its published view")
  local pool = assert(self._pool, "Storage renderer borrows its shared image owner")
  local paths = requiredPaths(self, view)
  local signature = table.concat(paths, "\0")
  local pending = self._pending
  if pending ~= nil and pending.signature ~= signature then
    abandonPending(pool, pending)
    self._pending = nil
    pending = nil
  end
  if pending == nil then
    if self._readySignature == signature then
      return true
    end
    pending = enroll(self, pool, paths, signature)
    self._pending = pending
  end
  local acquired = 0
  local budget = view.editor ~= nil and MAX_EDITOR_ACQUISITIONS_PER_UPDATE or MAX_ACQUISITIONS_PER_UPDATE
  for _, entry in ipairs(pending.entries) do
    if pending.staged[entry.token] == nil then
      local status, failure = pool:poll(entry.token)
      if status == "failed" then
        abandonPending(pool, pending)
        self._pending = nil
        return false, "compiled Storage image missing at " .. entry.path .. ": " .. tostring(failure)
      end
      assert(status == "pending" or status == "ready", "storage preparation reports pending or ready")
      if status == "ready" and acquired < budget then
        local ok, lease = pcall(pool.acquire, pool, entry.token)
        if not ok then
          abandonPending(pool, pending)
          self._pending = nil
          return false, "compiled Storage image missing at " .. entry.path .. ": " .. tostring(lease)
        end
        pending.staged[entry.token] = lease
        acquired = acquired + 1
      end
    end
  end
  if not stagedComplete(pending) then
    return false
  end
  return true
end

--- Installs one fully staged visual group: the staged leases move into
--- the installed group atomically and only the leases the new group no
--- longer needs return. A view matching the installed group is a quiet
--- no-op. Any other view without a complete staged group is a
--- programming error, so a pending replacement can never retire the
--- installed visuals before its own admission.
---@param view table<string, unknown> the staged snapshot to install
function PcStorageRenderer:commitPrepared(view)
  assert(not self._disposed, "disposed Storage renderer commits nothing")
  assert(type(view) == "table", "Storage commit requires its published view")
  local pool = assert(self._pool, "Storage renderer borrows its shared image owner")
  local paths = requiredPaths(self, view)
  local signature = table.concat(paths, "\0")
  local pending = self._pending
  if pending == nil or pending.signature ~= signature then
    assert(self._readySignature == signature, "Storage commits only its staged view")
    return
  end
  assert(stagedComplete(pending), "Storage commits only a fully staged view")
  publishPending(self, pool, pending)
end

---@param options { graphics: love.graphics, cacheFs: table<string, unknown>, manifest: table<string, unknown>, text: table<string, unknown>, labelText?: table<string, unknown>, imagePool: table<string, unknown> }
---@return PcStorageRenderer
function PcStorageRenderer.new(options)
  assert(type(options) == "table", "Storage renderer requires its borrowed collaborators")
  local pool = assert(options.imagePool, "Storage renderer borrows its shared image owner")
  assert(
    type(pool.request) == "function"
      and type(pool.poll) == "function"
      and type(pool.acquire) == "function"
      and type(pool.release) == "function",
    "Storage renderer drives request, poll, acquire, and release"
  )
  return setmetatable({
    _graphics = assert(options.graphics, "Storage renderer requires graphics"),
    _manifest = assert(options.manifest, "Storage renderer requires the PC manifest"),
    _text = assert(options.text, "Storage renderer borrows the shared text renderer"),
    -- Button, tab and title labels print with the source's small button font
    -- (font 4) when the composition supplies that renderer; info text,
    -- messages and names always keep the field font.
    _labelText = options.labelText,
    _images = {},
    _leases = {},
    _pool = pool,
    _readySignature = nil,
    _pending = nil,
    _cacheFs = assert(options.cacheFs, "Storage renderer borrows its cache filesystem"),
    _monPortraits = nil,
    _moveIcons = nil,
    _quads = {},
    _animation = PcStorageAnimation.new(),
    _cursorTick = 0,
    _disposed = false,
  }, PcStorageRenderer)
end

-- Mon icons resolve through the shared mon provider's sampling handles
-- so indexed pages bind their exact palette on capable hardware. Item
-- icons ride the shared item provider's own read surface, which stays
-- owned by its own provider.
-- GX_OAM_MODE_XLU halves the sprite's intensity; the source dims icons that are
-- not part of the current interaction (item mode, marking menu, a held mon,
-- and the yes/no prompts).
local DIMMED_ALPHA = 0.5
local function dimmedIcon(view, domain, slot)
  if view.carry ~= nil then
    return true
  end
  if view.editor ~= nil and view.editor.kind == "markings" then
    local focus = view.focus
    return not (focus ~= nil and focus.domain == domain and focus.slot == slot)
  end
  if view.message ~= nil and view.message.yesNo == true then
    return true
  end
  return false
end

local function drawIcon(graphics, provider, iconKey, x, y, scale, alpha)
  if iconKey == nil or provider == nil then
    return
  end
  graphics.setColor(1, 1, 1, alpha or 1)
  local dimensions = provider:dimensions(iconKey)
  ImageSampling.draw(
    graphics,
    provider:handleFor(iconKey),
    provider:quadFor(iconKey),
    x,
    y,
    0,
    scale / dimensions.width,
    scale / dimensions.height
  )
end

-- Held-item icons ride the shared item provider's pooled atlas borrow
-- through the exact sampler; the eager RGBA-direct atlas keeps its raw
-- draw. Extra placement arguments pass through to the draw call.
local function drawItemIcon(graphics, provider, iconKey, x, y, scale)
  if iconKey == nil or provider == nil then
    return
  end
  local dimensions = provider:dimensions(iconKey)
  local quad = provider:quadFor(iconKey)
  local handle = provider:handle()
  if handle ~= nil then
    ImageSampling.draw(graphics, handle, quad, x, y, 0, scale / dimensions.width, scale / dimensions.height)
    return
  end
  graphics.draw(provider:image(), quad, x, y, 0, scale / dimensions.width, scale / dimensions.height)
end

-- The source's 8-piece icon outline: the selected mon's own 32x32 character
-- drawn eight times at the one-pixel neighbourhood in OBJ palette slot 8,
-- which the box screen never loads, so every non-zero pixel renders as the
-- silhouette colour and index 0 stays clear. Drawing the copies behind the
-- icon leaves a 1px ring.
local OUTLINE_OFFSETS = {
  { 1, 0 },
  { -1, 0 },
  { 0, 1 },
  { 0, -1 },
  { 1, 1 },
  { 1, -1 },
  { -1, 1 },
  { -1, -1 },
}

local function drawIconOutline(graphics, provider, iconKey, x, y, scale, alpha)
  if iconKey == nil or provider == nil then
    return
  end
  local handle = provider:handleFor(iconKey)
  local quad = provider:quadFor(iconKey)
  local dimensions = provider:dimensions(iconKey)
  graphics.setColor(0, 0, 0, alpha or 1)
  for _, offset in ipairs(OUTLINE_OFFSETS) do
    ImageSampling.draw(
      graphics,
      handle,
      quad,
      x + offset[1],
      y + offset[2],
      0,
      scale / dimensions.width,
      scale / dimensions.height
    )
  end
  graphics.setColor(1, 1, 1, 1)
end

local function drawItemIconOutline(graphics, provider, iconKey, x, y, scale)
  if iconKey == nil or provider == nil then
    return
  end
  local handle = provider:handle()
  local quad = provider:quadFor(iconKey)
  local dimensions = provider:dimensions(iconKey)
  graphics.setColor(0, 0, 0, 1)
  for _, offset in ipairs(OUTLINE_OFFSETS) do
    if handle ~= nil then
      ImageSampling.draw(
        graphics,
        handle,
        quad,
        x + offset[1],
        y + offset[2],
        0,
        scale / dimensions.width,
        scale / dimensions.height
      )
    else
      graphics.draw(
        provider:image(),
        quad,
        x + offset[1],
        y + offset[2],
        0,
        scale / dimensions.width,
        scale / dimensions.height
      )
    end
  end
  graphics.setColor(1, 1, 1, 1)
end

-- The hand cursor sprite at a nav-table node (OBJ set A anims 8, 14 and 10).
-- The browsing and menu hands are two-frame source pulses: the tick the
-- renderer advances once per presented frame selects the visible cell
-- through the poses' own tick durations.
---@param pose table<string, unknown>
---@param tick integer
---@return table<string, unknown>
local function cursorFrameAt(pose, tick)
  local frames = assert(pose.frames, "Storage cursor poses carry their source frames")
  local total = 0
  for _, frame in ipairs(frames) do
    total = total + assert(frame.duration, "Storage cursor frames carry tick durations")
  end
  local position = total > 0 and tick % total or 0
  local accumulated = 0
  for _, frame in ipairs(frames) do
    accumulated = accumulated + frame.duration
    if position < accumulated then
      return frame
    end
  end
  return frames[1]
end

local function drawCursor(self, pose, x, y)
  local sequence = assert(self._manifest.storage.ui.cursors[pose], "Storage cursor pose is compiled: " .. pose)
  local frame = cursorFrameAt(sequence, self._cursorTick or 0)
  drawVisual(self, frame, x + frame.anchorX, y + frame.anchorY)
end

local BOX_ICON_SIZE = 32

-- Box icons are 32x32 sprites centred four pixels above their slot's centre
--.
local CARRY_LIFT = 8

-- Whether the source shows the selected-icon outline on this custody cell:
-- an open action list selects the focused mon, and a carried mon keeps the
-- outline riding its icon.
local function outlinedCell(view, domain, slot)
  local carry = view.carry
  if carry ~= nil and carry.mon ~= nil and carry.source ~= nil then
    local source = carry.source
    return source.kind == domain and source.slot == slot and (domain == "party" or source.box == view.activeBox)
  end
  if view.menu ~= nil then
    local focus = view.focus
    return focus ~= nil and focus.domain == domain and focus.slot == slot
  end
  return false
end

local function drawBoxMon(self, resources, mon, slot, carried, view)
  if type(mon) ~= "table" then
    return
  end
  local rect = PcStorageGeometry.boxSlotRect(slot)
  local lift = carried and CARRY_LIFT or 0
  local x, y = rect.x + rect.width / 2 - BOX_ICON_SIZE / 2, rect.y + rect.height / 2 - 4 - lift - BOX_ICON_SIZE / 2
  local alpha = dimmedIcon(view, "box", slot) and DIMMED_ALPHA or 1
  if outlinedCell(view, "box", slot) then
    drawIconOutline(self._graphics, resources.icons, mon.iconKey, x, y, BOX_ICON_SIZE, alpha)
  end
  drawIcon(self._graphics, resources.icons, mon.iconKey, x, y, BOX_ICON_SIZE, alpha)
  self._graphics.setColor(1, 1, 1, 1)
end

-- Top-screen info text at the source window positions:
-- message 87/88/89 label the Nature, Ability and Item values, 92 is "None"
-- and 93 stands in for an egg's hidden values.
local function drawInfo(self, info)
  local text = self._text
  text:drawText(info.nickname, 8, 56)
  if info.speciesName ~= nil then
    text:drawText(info.speciesName, 64, 40)
    -- PCBox_PrintLevel/PCBox_PrintDexNumber blit the raw 16x8 "Lv."/"No."
    -- bitmaps into their windows and print the number after them.
    local glyphs = assert(self._manifest.storage.ui.infoGlyphs, "Storage info glyphs are compiled")
    drawVisual(self, assert(glyphs.lv), 32, 77)
    text:drawText(tostring(info.level), 48, 72)
    -- A dex number of zero prints nothing.
    if info.dexNumber ~= nil and info.dexNumber > 0 then
      drawVisual(self, assert(glyphs.no), 8, 45)
      text:drawText(string.format("%03d", info.dexNumber), 24, 40)
    end
    if info.gender ~= nil then
      -- The box info panel prints the gender symbol in its own colour band:
      -- male foreground 7/shadow 8, female foreground 3/shadow 4.
      local variant = info.gender == "male" and 3 or 1
      text:drawTextWithColorVariant(sourceText(self, info.gender == "male" and 82 or 83), 128, 40, variant)
    end
  end
  local hidden = sourceText(self, 93)
  text:drawText(sourceText(self, 87), 8, 88)
  text:drawText(info.natureName or hidden, 8, 104)
  text:drawText(sourceText(self, 88), 8, 120)
  text:drawText(info.abilityName or hidden, 8, 136)
  text:drawText(sourceText(self, 89), 8, 152)
  text:drawText(info.itemName or sourceText(self, 92), 8, 168)
end

-- The top-screen picture, type icons and the Move/Item info panel. The
-- portrait is the generated 80x80 front frame; the two type icons reuse the
-- shared move-icon sprites; the panel images are the source BG6 cell rasters.
---@param self PcStorageRenderer
---@param view table<string, unknown>
---@param resources table<string, unknown>
local function drawInfoArt(self, view, resources)
  local info = view.info
  if type(info) ~= "table" then
    return
  end
  local graphics = self._graphics
  if type(info.portraitSelector) == "string" then
    local entry, page = self:_portraitFor(info.portraitSelector)
    local frame = assert(entry.frames and entry.frames[1], "portrait entries carry their first frame")
    local path = MonCache.pageImagePath("portraits", assert(entry.pageId))
    local lease = imageFor(self, { image = path })
    local key = path .. ":" .. frame.x .. "," .. frame.y .. "," .. frame.width .. "," .. frame.height
    local quad = self._quads[key]
    if quad == nil then
      quad = self._graphics.newQuad(frame.x, frame.y, frame.width, frame.height, page.width, page.height)
      self._quads[key] = quad
    end
    local picture = PcStorageGeometry.INFO_MON_PICTURE
    ImageSampling.draw(
      graphics,
      lease,
      quad,
      picture.x,
      picture.y,
      0,
      picture.width / frame.width,
      picture.height / frame.height
    )
  end
  if info.egg == true then
    return
  end
  if type(info.types) == "table" and #info.types > 0 then
    local icons = self:_moveIconManifest()
    local limit = math.min(2, #info.types)
    for index = 1, limit do
      local visual =
        assert(icons.types[info.types[index]], "the move-icon manifest carries type " .. tostring(info.types[index]))
      local anchor = assert(PcStorageGeometry.INFO_TYPE_ICONS[index], "the info panel carries two type slots")
      local offset = visual.offset or { x = -visual.width / 2, y = -visual.height / 2 }
      self:_drawImagePath(visual.image, anchor.x + offset.x, anchor.y + offset.y)
    end
  end
  if view.mode == 3 then
    local panel = assert(self._manifest.storage.ui.itemPanel, "Storage compiles the Item info panel")
    drawVisual(self, panel, PcStorageGeometry.INFO_ITEM_PANEL.x, PcStorageGeometry.INFO_ITEM_PANEL.y)
    local fill = assert(self._manifest.storage.ui.itemPanelFill, "Storage compiles the item window fill")
    graphics.setColor(fill.r / 255, fill.g / 255, fill.b / 255, 1)
    local name = PcStorageGeometry.INFO_ITEM_NAME
    local description = PcStorageGeometry.INFO_ITEM_DESC
    graphics.rectangle("fill", name.x, name.y, name.width, name.height)
    graphics.rectangle("fill", description.x, description.y, description.width, description.height)
    graphics.setColor(1, 1, 1, 1)
    if info.itemName ~= nil then
      self._text:drawText(info.itemName, name.x, name.y)
      if info.itemDescription ~= nil then
        -- The description bank already carries the source's own line breaks;
        -- the window prints them as-is (216x48 = 3 lines of 16 px).
        local line = 0
        for text in (tostring(info.itemDescription) .. "\n"):gmatch("(.-)\n") do
          self._text:drawText(text, description.x, description.y + line * 16)
          line = line + 1
        end
      end
    end
    if info.itemIconKey ~= nil and resources.itemIcons ~= nil then
      local iconRect = PcStorageGeometry.INFO_ITEM_ICON
      drawItemIcon(graphics, resources.itemIcons, info.itemIconKey, iconRect.x, iconRect.y, iconRect.width)
    end
  else
    local panel = assert(self._manifest.storage.ui.movesPanel, "Storage compiles the Move info panel")
    drawVisual(self, panel, PcStorageGeometry.INFO_MOVES_PANEL.x, PcStorageGeometry.INFO_MOVES_PANEL.y)
    -- An empty slot prints bank 750 message 0, the ASCII "-".
    for slot = 1, 4 do
      local name = info.moves and info.moves[slot] or nil
      self._text:drawText(name or "-", 168, assert(PcStorageGeometry.INFO_MOVE_ROWS[slot]))
    end
  end
end

-- Box tray / deposit selector: the panel strip, six 32x32 thumbnails with
-- their BASE_COLOR dots, page arrows, the current-box marker, the name/count
-- plate and the Change Box / EXIT plates.
---@param self PcStorageRenderer
---@param view table<string, unknown>
local function drawBoxTray(self, view)
  local tray = view.boxTray
  if tray == nil then
    return
  end
  local storage = assert(self._manifest.storage, "Storage borrows its compiled storage manifest")
  local ui = assert(storage.ui, "Storage chrome is compiled")
  local graphics = self._graphics
  local deposit = tray.mode == "deposit"
  if deposit then
    -- The source blanks the band around the strip rather than painting it, so
    -- the layers underneath still show above and below the selector row.
    drawVisual(self, assert(ui.depositBoxTray, "Storage compiles the deposit tray strip"), 0, 48)
  else
    drawVisual(self, assert(ui.boxTray, "Storage compiles the box tray strip"), 0, 0)
  end
  local thumbnail = assert(storage.boxThumbnail, "Storage compiles box thumbnails")
  local unlocks = view.wallpaperUnlocks or {}
  for column = 0, PcStorageGeometry.TRAY_PAGE_SIZE - 1 do
    local entry = assert(tray.boxes[column + 1], "the tray page carries six boxes")
    local rect = PcStorageGeometry.traySlotRect(column, deposit)
    local logical = entry.wallpaperId >= 32 and entry.wallpaperId - 16 or entry.wallpaperId
    local unlocked = logical < 16 or unlocks[logical - 15] == true
    drawVisual(self, unlocked and assert(thumbnail.variants[logical]) or thumbnail.locked, rect.x, rect.y)
    for slot, colorIndex in pairs(entry.dots) do
      local color = assert(thumbnail.dots[colorIndex], "thumbnail dot color is compiled")
      local row = math.floor((slot - 1) / 6)
      local col = (slot - 1) % 6
      graphics.setColor(color.r / 255, color.g / 255, color.b / 255, 1)
      graphics.rectangle(
        "fill",
        rect.x + thumbnail.dotOrigin.x + col * thumbnail.dotStep,
        rect.y + thumbnail.dotOrigin.y + row * thumbnail.dotStep,
        2,
        2
      )
    end
  end
  graphics.setColor(1, 1, 1, 1)
  local arrowCenters = deposit and PcStorageGeometry.DEPOSIT_ARROW_CENTERS or PcStorageGeometry.TRAY_ARROW_CENTERS
  for side, visual in pairs({ prev = ui.tray.prev, next = ui.tray.next }) do
    local center = assert(arrowCenters[side], "the tray page has both arrows")
    drawVisual(self, visual, center.x + visual.anchorX, center.y + visual.anchorY)
  end
  local trayPage = math.floor(tray.trayBox / PcStorageGeometry.TRAY_PAGE_SIZE)
  if math.floor(view.activeBox / PcStorageGeometry.TRAY_PAGE_SIZE) == trayPage then
    local column = view.activeBox % PcStorageGeometry.TRAY_PAGE_SIZE
    local centerX = PcStorageGeometry.TRAY_BOX_CENTERS[column + 1]
    local centerY = deposit and 84 or 27
    drawVisual(self, ui.tray.marker, centerX + ui.tray.marker.anchorX, centerY + ui.tray.marker.anchorY)
  end
  local column = tray.trayBox % PcStorageGeometry.TRAY_PAGE_SIZE
  local plateX = assert(PcStorageGeometry.TRAY_CURSOR_X[column + 1], "the tray page has a cursor column")
  local plateY = deposit and PcStorageGeometry.DEPOSIT_PLATE_Y or PcStorageGeometry.TRAY_PLATE_Y
  drawVisual(self, ui.tray.cursor, plateX + ui.tray.cursor.anchorX, plateY + ui.tray.cursor.anchorY)
  local boxCenterX = PcStorageGeometry.TRAY_BOX_CENTERS[column + 1]
  local boxCenterY = deposit and 84 or 27
  -- The deposit selector's triangle points down at the row from 7 px above it.
  local labelY = deposit and 77 or boxCenterY
  drawVisual(self, ui.tray.label, boxCenterX + ui.tray.label.anchorX, labelY + ui.tray.label.anchorY)
  if self._text.drawText then
    local selected = assert(tray.boxes[column + 1], "the selected tray column carries its box")
    -- The name is centred in the 96 px slab at cursor-72 and the count in the
    -- 40 px slab at cursor+32 (PCBox_DrawTrayBoxNameAndCount, align 2).
    local textY = plateY + PcStorageGeometry.TRAY_NAME_OFFSET.y
    drawCenteredLine(self, selected.name, plateX + PcStorageGeometry.TRAY_NAME_OFFSET.x + 48, textY)
    drawCenteredLine(
      self,
      tostring(selected.count) .. "/30",
      plateX + PcStorageGeometry.TRAY_COUNT_OFFSET.x + 20,
      textY
    )
  end
  -- The strip's own plates (CONFIRM/CHANGE BOX/SUMMARY/EXIT) come from
  -- PcStorageGeometry.bottomButtons so only one owner draws them.
end

-- The selected mon's marks sit on the top-screen info panel, drawn into
-- BG5 at tile (15 + bit, 18).
local function drawSelectedMarkings(self, view)
  local focus = view.focus
  local mon = view.carry and view.carry.mon
  if mon == nil and focus ~= nil then
    local party = focus.domain == "party" or focus.kind == "party"
    mon = (party and view.party or view.boxSlots)[focus.slot + 1]
  end
  if type(mon) ~= "table" then
    return
  end
  local markings = assert(self._manifest.storage.ui.markings, "Storage marking visuals are compiled")
  for bit = 0, 5 do
    local selected = math.floor(mon.markings / (2 ^ bit)) % 2 == 1
    drawVisual(self, markings[bit][selected and "set" or "clear"], 120 + bit * 8, 144)
  end
end

local function drawEditor(self, view)
  local editor = view.editor
  if editor == nil then
    return
  end
  local graphics = self._graphics
  graphics.setColor(1, 1, 1, 1)
  if editor.kind == "markings" then
    -- One 8x8 member-14 tile per mark at panel tiles (3,2),(7,2)… — the 16x16
    -- touch rects are hit boxes, not draw rectangles.
    local markings = assert(self._manifest.storage.ui.panelMarkings, "Storage panel marking visuals are compiled")
    for bit = 0, 5 do
      local marked = math.floor(editor.mask / (2 ^ bit)) % 2 == 1
      local visual = markings[bit][marked and "set" or "clear"]
      drawVisual(self, visual, 192 + 32 * (bit % 2), 64 + 24 * math.floor(bit / 2))
    end
    local confirmRect = PcStorageGeometry.MARKING_CONFIRM_RECT
    local cancelRect = PcStorageGeometry.MARKING_CANCEL_RECT
    -- PCBox_PrintCenteredLabel prints at the plate's own top (y = 0).
    drawCenteredLine(self, sourceText(self, 72), confirmRect.x + confirmRect.width / 2, confirmRect.y)
    drawCenteredLine(self, sourceText(self, 73), cancelRect.x + cancelRect.width / 2, cancelRect.y)
  elseif editor.kind == "wallpaper" then
    local storage = self._manifest.storage
    local art = assert(storage.wallpaperSwatchArt, "Storage compiles wallpaper swatches")
    local unlocks = assert(view.wallpaperUnlocks, "Storage snapshots carry wallpaper unlocks")
    local pageStart = editor.selected - editor.selected % PcStorageGeometry.WALLPAPER_PAGE_SIZE
    drawVisual(self, storage.ui.wallpaperBar, 0, 0)
    for side, center in pairs(PcStorageGeometry.WALLPAPER_ARROW_CENTERS) do
      local role = side == "left" and "prev" or "next"
      local arrow = storage.ui.tray[role]
      drawVisual(self, arrow, center.x + arrow.anchorX, center.y + arrow.anchorY)
    end
    for slot = 0, PcStorageGeometry.WALLPAPER_PAGE_SIZE - 1 do
      local logicalId = pageStart + slot
      local unlocked = logicalId < 16 or unlocks[logicalId - 15] == true
      local rect = PcStorageGeometry.wallpaperSlotRect(slot)
      drawVisual(self, unlocked and assert(art.variants[logicalId]) or art.locked, rect.x, rect.y)
    end
    -- The selected swatch's plate, triangle and name sit on the swatch row
    -- (PCBox_UpdateWallpaperCursor / _PlaceWallpaperMenuTextObj).
    local column = editor.selected % PcStorageGeometry.WALLPAPER_PAGE_SIZE
    local swatchX = 59 + 46 * column
    -- The current wallpaper in this page carries the marker bar.
    local current = editor.current
    if current ~= nil and current >= pageStart and current < pageStart + 4 then
      local markerX = 59 + 46 * (current - pageStart)
      drawVisual(
        self,
        storage.ui.tray.marker,
        markerX + storage.ui.tray.marker.anchorX,
        35 + storage.ui.tray.marker.anchorY
      )
    end
    local cursor = storage.ui.tray.wallpaperCursor
    drawVisual(self, cursor, swatchX + cursor.anchorX, 35 + cursor.anchorY)
    drawVisual(self, storage.ui.tray.label, swatchX + storage.ui.tray.label.anchorX, 35 + storage.ui.tray.label.anchorY)
    local selectedUnlocked = editor.selected < 16 or unlocks[editor.selected - 15] == true
    local name = sourceText(self, selectedUnlocked and 35 + editor.selected or 59)
    -- The name window is 96 px wide, centred on the swatch, top at swatch y - 8.
    drawCenteredLine(self, name, swatchX, 27)
    drawWindowMessage(self, PcStorageGeometry.WALLPAPER_TITLE_RECT, sourceText(self, 78))
    drawButton(self, { x = 192, y = 168, width = 64, height = 24 }, sourceText(self, 76))
  else
    error("unknown Storage editor " .. tostring(editor.kind), 0)
  end
  graphics.setColor(1, 1, 1, 1)
end

-- Party icons are 32x32 sprites centred in the open tray.
local function drawPartyMon(self, resources, mon, slot, side, carried, view)
  if type(mon) ~= "table" then
    return
  end
  local rect = PcStorageGeometry.partySlotRect(slot, side)
  local y = rect.y - (carried and CARRY_LIFT or 0)
  local alpha = not carried and dimmedIcon(view, "party", slot) and DIMMED_ALPHA or 1
  if outlinedCell(view, "party", slot) then
    drawIconOutline(self._graphics, resources.icons, mon.iconKey, rect.x, y, PcStorageGeometry.PARTY_ICON_SIZE, alpha)
  end
  drawIcon(self._graphics, resources.icons, mon.iconKey, rect.x, y, PcStorageGeometry.PARTY_ICON_SIZE, alpha)
  self._graphics.setColor(1, 1, 1, 1)
end

-- Draws the moving icons of the presentation animator: mon flights between
-- slots and the shrinking icon of a released mon.
---@param self PcStorageRenderer
---@param resources table<string, unknown>
---@param frame PcStorageAnimation.Frame
local function drawAnimatingIcons(self, resources, frame)
  local graphics = self._graphics
  if frame.icons ~= nil then
    for _, slots in pairs(frame.icons) do
      for _, icon in pairs(slots) do
        local mon = icon.mon
        if type(mon) == "table" then
          local x, y = icon.x - 16, icon.y - 16
          drawIcon(graphics, resources.icons, mon.iconKey, x, y, 32)
        end
      end
    end
  end
  if frame.item ~= nil then
    -- The item sprite is one 32x32 cell whose art is centred on its position.
    drawItemIcon(graphics, resources.itemIcons, frame.item.iconKey, frame.item.x - 16, frame.item.y - 16, 32)
  end
  for _, entry in ipairs(frame.release or {}) do
    local size = 32 * entry.scale
    drawIcon(graphics, resources.icons, entry.mon.iconKey, entry.x - size / 2, entry.y - size / 2, size)
  end
end

-- The release animation hides its source cell while the shrink and the
-- release messages run, exactly like the source sprite's draw flag.
local function releasedSlot(view, domain, slot)
  local release = view.release
  if release == nil or release.address == nil then
    return false
  end
  local address = release.address
  if address.kind ~= domain or address.slot ~= slot then
    return false
  end
  return domain ~= "box" or address.box == view.activeBox
end

local function carriedFrom(view, kind, index)
  local source = view.carry and view.carry.source
  if source == nil or source.kind ~= kind or source.slot ~= index then
    return false
  end
  return kind == "party" or source.box == view.activeBox
end

-- A bank 25 message as text, with its one subject (a mon or item name) in place.
local function messageText(self, message)
  local bank = assert(self._manifest.text.banks[25], "Storage borrows source text bank 25")
  local tokens = assert(bank[message.id], "Storage prompt message is compiled: " .. tostring(message.id))
  local parts = {}
  for _, token in ipairs(tokens) do
    if token.kind == "glyph" then
      parts[#parts + 1] = token.text
    elseif token.kind == "substitution" then
      parts[#parts + 1] = message.subject or ""
    end
  end
  return table.concat(parts)
end

-- The prompt window in the player's own frame, plus the Yes / No pair.
local function drawMessage(self, resources, message)
  local window = assert(PcStorageGeometry.MESSAGE_WINDOWS[message.window], "Storage message window is known")
  local windows = assert(resources.windowRenderer, "Storage messages borrow the window renderer")
  local frameIndex = assert(resources.applicationFrameIndex, "Storage messages borrow the player frame index")
  local fill = self._text:windowBackgroundColor()
  if message.window == "W40" then
    -- PCBox_PrintPanelHint fills the hint strip without drawing a frame.
    windows:drawWindow(window, nil, fill)
  else
    windows:drawWindow(window, frameIndex, fill)
  end
  self._graphics.setColor(1, 1, 1, 1)
  self._text:drawText(messageText(self, message), window.x, window.y)
  if message.yesNo then
    -- The shared YesNoPrompt draws baked button art: the highlighted row
    -- swaps to its selected variant, and the other row keeps its idle art.
    local prompt = assert(self._manifest.storage.ui.yesNo, "Storage confirmation buttons are compiled")
    local selected = message.yesNoChoice or "yes"
    local yesSelected = selected == "yes"
    local noSelected = selected == "no"
    drawVisual(
      self,
      assert(prompt[yesSelected and "yesSelected" or "yesNormal"]),
      PcStorageGeometry.YES_RECT.x,
      PcStorageGeometry.YES_RECT.y
    )
    drawVisual(
      self,
      assert(prompt[noSelected and "noSelected" or "noNormal"]),
      PcStorageGeometry.NO_RECT.x,
      PcStorageGeometry.NO_RECT.y
    )
  end
end

function PcStorageRenderer:drawPane(view, resources, paneId, placement, animated)
  assert(not self._disposed, "disposed Storage renderer draws nothing")
  local graphics = self._graphics
  resources = resources or {}
  local frame = type(animated) == "table" and animated or nil
  if frame == nil then
    local cursor = view.cursor or { x = 0, y = 0 }
    frame = { cursor = { x = cursor.x, y = cursor.y }, wallpaper = { { id = view.wallpaperId or 0, x = 0 } } }
  end
  LogicalSurface.draw(graphics, placement, function()
    local storage = self._manifest.storage
    if paneId == "upper" then
      -- The top screen carries only the selected mon's info panel.
      drawVisual(self, storage.ui.infoPane, 0, 0)
      -- The mode's header line, printed once at init on the top screen (F5620).
      self._text:drawText(sourceText(self, 50 + view.mode, 25), 8, 8)
      drawSelectedMarkings(self, view)
      if view.info ~= nil then
        drawInfo(self, view.info)
        drawInfoArt(self, view, resources)
      end
      return
    end
    -- Touch screen, back to front: the cream base, the wallpaper tilemap, the
    -- box icons (OBJ priority 3, behind the box pane's BG2 but over BG3), the
    -- box pane (transparent over the wallpaper), the party tray (BG1), and the
    -- party icons (OBJ priority 1, in front of the tray).
    drawVisual(self, storage.backgrounds.default, 0, 0)
    for _, layer in ipairs(frame.wallpaper or {}) do
      local wallpaper = assert(storage.wallpapers[layer.id], "selected wallpaper is compiled")
      drawVisual(self, wallpaper, PcStorageGeometry.WALLPAPER.x + layer.x, PcStorageGeometry.WALLPAPER.y)
    end
    if self._text.drawText then
      -- The box name is burned into the wallpaper's name plate (21x3 window
      -- centred at (84, 4) inside the plate), so it paints with the wallpaper
      -- and every overlay covers it.
      local title = tostring(view.boxName or "")
      if title ~= "" then
        self._text:drawText(title, 84 - self._text:textWidth(title) / 2, 20)
      end
    end
    for slot, mon in ipairs(assert(view.boxSlots, "Storage snapshots carry all box slots")) do
      if
        not carriedFrom(view, "box", slot - 1)
        and PcStorageAnimation.iconAt(frame, "box", slot - 1) == nil
        and not releasedSlot(view, "box", slot - 1)
      then
        drawBoxMon(self, resources, mon, slot - 1, false, view)
      end
    end
    drawVisual(self, storage.ui.boxPane, 0, 0)
    -- The box arrows are hidden while the party panel, a menu, a prompt or an
    -- editor occupies the screen (PCBox_SetBoxArrowsVisible call sites).
    local editing = view.editor ~= nil
    local traySide = view.tray ~= "closed" and view.tray or view.transferSide
    local trayOpen = traySide ~= nil
    local boxArrows = not editing and not trayOpen and view.message == nil and view.boxTray == nil
    if boxArrows then
      for side, center in pairs(PcStorageGeometry.BOX_ARROW_CENTERS) do
        local arrow = storage.ui.arrows[side]
        drawVisual(self, arrow, center.x + arrow.anchorX, center.y + arrow.anchorY)
      end
    end
    if trayOpen then
      local origin = PcStorageGeometry.PARTY_TRAY_ORIGINS[traySide]
      -- Move/Item modes load the panel art that carries the SWITCH/EXIT plate.
      local partyTray = view.mode >= 2 and assert(storage.ui.partyTrayMove, "Storage compiles the Move party panel")
        or storage.ui.partyTray
      drawVisual(self, partyTray, origin.x, origin.y)
    end
    if view.editor ~= nil and view.editor.kind == "markings" then
      local panel = PcStorageGeometry.PARTY_TRAY_ORIGINS.right
      drawVisual(self, storage.ui.markingPanel, panel.x, panel.y)
    end
    drawBoxTray(self, view)
    drawAnimatingIcons(self, resources, frame)
    for slot, mon in ipairs(view.party or {}) do
      if
        trayOpen
        and not editing
        and not carriedFrom(view, "party", slot - 1)
        and PcStorageAnimation.iconAt(frame, "party", slot - 1) == nil
        and not releasedSlot(view, "party", slot - 1)
      then
        drawPartyMon(self, resources, mon, slot - 1, traySide, false, view)
      end
    end
    drawEditor(self, view)
    local panelLabel = PcStorageGeometry.partyPanelLabel(view)
    if panelLabel ~= nil and self._text.drawText then
      -- PCBox_PrintCenteredLabel draws at the plate's own top row.
      drawCenteredLine(self, sourceText(self, panelLabel.messageId), panelLabel.x + panelLabel.width / 2, panelLabel.y)
    end
    local drag = view.drag
    if drag ~= nil then
      -- A stylus drag pins the carried mon's centre 8 px above the touch,
      -- and the held-item sprite's centre 4 px right/below it; the hand
      -- cursor itself hides for the whole drag.
      if drag.kind == "items" then
        local iconKey = drag.mon ~= nil and drag.mon.heldItem ~= "NONE" and drag.mon.itemIconKey or nil
        if iconKey ~= nil then
          drawItemIconOutline(self._graphics, resources.itemIcons, iconKey, drag.x - 12, drag.y - 12, 32)
          drawItemIcon(self._graphics, resources.itemIcons, iconKey, drag.x - 12, drag.y - 12, 32)
        end
      elseif drag.mon ~= nil then
        drawIconOutline(self._graphics, resources.icons, drag.mon.iconKey, drag.x - 16, drag.y - 24, 32, 1)
        drawIcon(self._graphics, resources.icons, drag.mon.iconKey, drag.x - 16, drag.y - 24, 32)
      end
    elseif view.carry ~= nil and view.carry.mon ~= nil and view.carry.kind ~= "items" then
      -- The held mon rides the hand: its centre sits 4 px below the cursor
      -- (PCBox_UpdateCursorSlide), including through the four-step slide.
      -- Item mode carries the held-item sprite instead, never the mon icon.
      local carry = view.carry
      local x = frame.cursor.x - 16
      local y = frame.cursor.y + 4 - 16
      drawIconOutline(self._graphics, resources.icons, carry.mon.iconKey, x, y, 32, 1)
      drawIcon(self._graphics, resources.icons, carry.mon.iconKey, x, y, 32)
    end
    -- Item mode draws exactly one held-item sprite, on the selected slot or on
    -- the hand; per-mon badges do not exist in the source. A drag draws its
    -- own held-item sprite above.
    if view.mode == 3 and view.drag == nil then
      local itemKey, itemX, itemY
      if view.carry ~= nil and view.carry.kind == "items" and view.carry.mon ~= nil then
        itemKey = view.carry.mon.heldItem ~= "NONE" and view.carry.mon.itemIconKey or nil
        itemX, itemY = frame.cursor.x + 8, frame.cursor.y + 4 + 8
      else
        local focus = view.focus
        if focus ~= nil then
          local list = focus.domain == "party" and view.party or view.boxSlots
          local mon = list and list[focus.slot + 1]
          if type(mon) == "table" and mon.heldItem ~= "NONE" then
            local centerX, centerY
            if focus.domain == "party" then
              if view.tray ~= "closed" then
                local rect = PcStorageGeometry.partySlotRect(focus.slot, view.tray)
                centerX, centerY = rect.x + rect.width / 2, rect.y + rect.height / 2
              end
            else
              local rect = PcStorageGeometry.boxSlotRect(focus.slot)
              centerX, centerY = rect.x + rect.width / 2, rect.y + rect.height / 2
            end
            if centerX ~= nil then
              itemKey, itemX, itemY = mon.itemIconKey, centerX + 8, centerY + 8
            end
          end
        end
      end
      if itemKey ~= nil then
        -- Item mode outlines the lifted/selected held-item icon the same way
        -- the source does: eight silhouette copies behind the icon.
        drawItemIconOutline(self._graphics, resources.itemIcons, itemKey, itemX - 16, itemY - 16, 32)
        drawItemIcon(self._graphics, resources.itemIcons, itemKey, itemX - 16, itemY - 16, 32)
      end
    end
    if self._text.drawText then
      if view.menu ~= nil then
        if view.menu.address == nil then
          drawWindowMessage(self, PcStorageGeometry.BOX_MENU_TITLE_RECT, sourceText(self, 77))
        end
        local count = #view.menu.actions
        for index, action in ipairs(view.menu.actions) do
          drawButton(
            self,
            PcStorageGeometry.actionButtonRect(count, index - 1),
            sourceLabel(self, action),
            PcStorageGeometry.actionStyle(action)
          )
        end
      end
      for _, button in ipairs(PcStorageGeometry.bottomButtons(view)) do
        drawButton(self, button.rect, sourceText(self, button.messageId), button.style)
      end
      if view.message ~= nil then
        drawMessage(self, resources, view.message)
      end
    end
    if view.cursor ~= nil and view.drag == nil then
      drawCursor(self, view.cursor.pose, frame.cursor.x, frame.cursor.y)
    end
  end)
end

-- Starts one Storage presentation session: the animator forgets the previous
-- open's last view so a new box does not animate in from stale pixels.
function PcStorageRenderer:beginSession()
  assert(not self._disposed, "disposed Storage renderer starts no session")
  self._animation:beginSession()
end

-- Advances one presented animation frame for this view.
---@param view table<string, unknown>
---@return PcStorageAnimation.Frame
function PcStorageRenderer:stepAnimation(view)
  assert(not self._disposed, "disposed Storage renderer animates nothing")
  self._cursorTick = (self._cursorTick or 0) + 1
  return self._animation:step(view)
end

-- Bounds physical retention after a state lease turnover through the
-- shared idle limit: returned borrows rest idle and resident while the
-- live panes keep their hard references, and the explicit trim frees
-- every idle visual exactly once. Borrowed visuals stay resident
-- regardless of idle age.
---@return integer freed physical image count
function PcStorageRenderer:trimIdle()
  assert(not self._disposed, "disposed Storage renderer trims nothing")
  return assert(self._pool, "Storage renderer borrows its shared image owner"):prune()
end

function PcStorageRenderer:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  local pool = assert(self._pool, "Storage renderer borrows its shared image owner")
  self._pool = nil
  local pending = self._pending
  self._pending = nil
  if pending ~= nil then
    abandonPending(pool, pending)
  end
  for _, lease in pairs(self._leases) do
    pool:release(lease)
  end
  self._leases = {}
  self._images = {}
  self._readySignature = nil
  self._animation = nil
end

function PcStorageRenderer:release()
  self:dispose()
end

return PcStorageRenderer
