-- Draws compiled Storage visuals through the paired source presentation plan.

local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local ImageSampling = require("libs.nds.src.love.ImageSampling")
local LogicalSurface = require("libs.ui.src.LogicalSurface")
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
---@field _disposed boolean
local PcStorageRenderer = {}
PcStorageRenderer.__index = PcStorageRenderer

-- Storage visuals sample point-filtered and clamped, matching the shared
-- construction below, so pooled leases draw identically.
local POOLED_SAMPLER = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }

-- Bounds the GPU realizations one update may install, so a cold open
-- spreads its uploads across frames instead of stalling the field.
local MAX_ACQUISITIONS_PER_UPDATE = 4

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

-- A framed button strip (palette bank 12 window frame) with one text line per
-- source line.
local function drawButton(self, rect, label)
  local frame = assert(
    self._manifest.storage.ui.windowFrames.standard.paletteBank0,
    "Storage button frame style and palette bank are compiled"
  )
  local graphics = self._graphics
  graphics.setColor(1, 1, 1, 1)
  ImageSampling.draw(
    graphics,
    imageFor(self, frame),
    nil,
    rect.x,
    rect.y,
    0,
    rect.width / frame.width,
    rect.height / frame.height
  )
  local line = 0
  for text in label:gmatch("[^\n]+") do
    self._text:drawText(text, rect.x + 8, rect.y + 4 + line * 16)
    line = line + 1
  end
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
  add(storage.backgrounds.default)
  local wallpaperId = view.wallpaperId or 0
  add(assert(storage.wallpapers[wallpaperId], "selected wallpaper is compiled"))
  add(ui.boxPane)
  local editor = view.editor
  if editor == nil then
    add(ui.arrows.left)
    add(ui.arrows.right)
  end
  if view.tray ~= "closed" then
    add(ui.partyTray)
  end
  if editor ~= nil and editor.kind == "markings" then
    add(ui.markingPanel)
  end
  if editor ~= nil then
    if editor.kind == "markings" then
      local markings = assert(ui.markings, "Storage marking visuals are compiled")
      for bit = 0, 5 do
        local marked = math.floor(editor.mask / (2 ^ bit)) % 2 == 1
        add(markings[bit][marked and "set" or "clear"])
      end
      add(ui.cursors.browse)
    elseif editor.kind == "wallpaper" then
      add(ui.wallpaperBar)
      add(ui.arrows.left)
      add(ui.arrows.right)
      add(
        assert(
          storage.ui.windowFrames.standard.paletteBank0,
          "Storage button frame style and palette bank are compiled"
        )
      )
      add(ui.cursors.menu)
    else
      error("unknown Storage editor " .. tostring(editor.kind), 0)
    end
  end
  -- The button frame draws while any button draws: the menu list, the
  -- bottom buttons, or the wallpaper confirm pair.
  local needsFrame = editor ~= nil and editor.kind == "wallpaper"
  if not needsFrame and self._text.drawText ~= nil then
    needsFrame = view.menu ~= nil or #PcStorageGeometry.bottomButtons(view) > 0
  end
  if needsFrame then
    add(
      assert(storage.ui.windowFrames.standard.paletteBank0, "Storage button frame style and palette bank are compiled")
    )
  end
  if editor == nil then
    local pose ---@type string?
    if view.carry ~= nil then
      local target = view.carry.destination or view.focus
      if target == nil then
        pose = nil
      elseif target.kind == "party" or target.domain == "party" then
        pose = view.tray ~= "closed" and "carry" or nil
      else
        pose = "carry"
      end
    elseif view.menu ~= nil then
      pose = "menu"
    elseif view.focus ~= nil then
      local partyFocus = focus.domain == "party" or focus.kind == "party"
      pose = partyFocus and view.tray == "closed" and nil or "browse"
    end
    if pose ~= nil then
      add(assert(ui.cursors[pose], "Storage cursor pose is compiled: " .. pose))
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
  for _, entry in ipairs(pending.entries) do
    if pending.staged[entry.token] == nil then
      local status, failure = pool:poll(entry.token)
      if status == "failed" then
        abandonPending(pool, pending)
        self._pending = nil
        return false, "compiled Storage image missing at " .. entry.path .. ": " .. tostring(failure)
      end
      assert(status == "pending" or status == "ready", "storage preparation reports pending or ready")
      if status == "ready" and acquired < MAX_ACQUISITIONS_PER_UPDATE then
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

---@param options { graphics: love.graphics, manifest: table<string, unknown>, text: table<string, unknown>, imagePool: table<string, unknown> }
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
    _images = {},
    _leases = {},
    _pool = pool,
    _readySignature = nil,
    _pending = nil,
    _disposed = false,
  }, PcStorageRenderer)
end

-- Mon icons resolve through the shared mon provider's sampling handles
-- so indexed pages bind their exact palette on capable hardware. Item
-- icons ride the shared item provider's own read surface, which stays
-- owned by its own provider.
local function drawIcon(graphics, provider, iconKey, x, y, scale)
  if iconKey == nil or provider == nil then
    return
  end
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

-- The hand cursor sprite at a nav-table node (OBJ set A anims 8, 14 and 10).
local function drawCursor(self, pose, x, y)
  local visual = assert(self._manifest.storage.ui.cursors[pose], "Storage cursor pose is compiled: " .. pose)
  drawVisual(self, visual, x + visual.anchorX, y + visual.anchorY)
end

local BOX_ICON_SIZE = 32

-- Box icons are 32x32 sprites centred four pixels above their slot's centre
--.
local CARRY_LIFT = 8

local function drawBoxMon(self, resources, mon, slot, carried)
  if type(mon) ~= "table" then
    return
  end
  local rect = PcStorageGeometry.boxSlotRect(slot)
  local lift = carried and CARRY_LIFT or 0
  local x, y = rect.x + rect.width / 2 - BOX_ICON_SIZE / 2, rect.y + rect.height / 2 - 4 - lift - BOX_ICON_SIZE / 2
  local graphics = self._graphics
  drawIcon(graphics, resources.icons, mon.iconKey, x, y, BOX_ICON_SIZE)
  drawItemIcon(graphics, resources.itemIcons, mon.heldItem ~= "NONE" and mon.itemIconKey or nil, x + 20, y + 20, 12)
end

-- Top-screen info text at the source window positions:
-- message 87/88/89 label the Nature, Ability and Item values, 92 is "None"
-- and 93 stands in for an egg's hidden values.
local function drawInfo(self, info)
  local text = self._text
  text:drawText(info.nickname, 8, 56)
  if info.speciesName ~= nil then
    text:drawText(info.speciesName, 64, 40)
    text:drawText("Lv.", 32, 72)
    text:drawText(tostring(info.level), 48, 72)
    -- A dex number of zero prints nothing.
    if info.dexNumber ~= nil and info.dexNumber > 0 then
      text:drawText("No.", 8, 40)
      text:drawText(string.format("%03d", info.dexNumber), 24, 40)
    end
    if info.gender ~= nil then
      text:drawText(sourceText(self, info.gender == "male" and 82 or 83), 128, 40)
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
    local markings = assert(self._manifest.storage.ui.markings, "Storage marking visuals are compiled")
    for bit = 0, 5 do
      local marked = math.floor(editor.mask / (2 ^ bit)) % 2 == 1
      local rect = PcStorageGeometry.markingRect(bit)
      local visual = markings[bit][marked and "set" or "clear"]
      graphics.setColor(1, 1, 1, 1)
      ImageSampling.draw(
        graphics,
        imageFor(self, visual),
        nil,
        rect.x,
        rect.y,
        0,
        rect.width / visual.width,
        rect.height / visual.height
      )
    end
    drawCursor(self, "browse", PcStorageGeometry.markingCursorAnchor(editor.selected))
  elseif editor.kind == "wallpaper" then
    local storage = self._manifest.storage
    local swatches = storage.wallpaperSwatches
    local unlocks = assert(view.wallpaperUnlocks, "Storage snapshots carry wallpaper unlocks")
    local pageStart = editor.selected - editor.selected % PcStorageGeometry.WALLPAPER_PAGE_SIZE
    drawVisual(self, storage.ui.wallpaperBar, 0, 0)
    for side, center in pairs(PcStorageGeometry.WALLPAPER_ARROW_CENTERS) do
      local arrow = storage.ui.arrows[side]
      drawVisual(self, arrow, center.x + arrow.anchorX, center.y + arrow.anchorY)
    end
    for slot = 0, PcStorageGeometry.WALLPAPER_PAGE_SIZE - 1 do
      local logicalId = pageStart + slot
      local unlocked = logicalId < 16 or unlocks[logicalId - 15] == true
      local color = unlocked and swatches.colors[logicalId] or swatches.locked
      local rect = PcStorageGeometry.wallpaperSlotRect(slot)
      graphics.setColor(color.r / 255, color.g / 255, color.b / 255, 1)
      graphics.rectangle("fill", rect.x + 4, rect.y + 5, 16, 14)
      graphics.setColor(1, 1, 1, 1)
    end
    -- The selected swatch's name; locked entries read "－" (message 59).
    local selectedUnlocked = editor.selected < 16 or unlocks[editor.selected - 15] == true
    local name = sourceText(self, selectedUnlocked and 35 + editor.selected or 59)
    self._text:drawText(name, 59 + 46 * (editor.selected % 4) - self._text:textWidth(name) / 2, 8)
    drawButton(self, PcStorageGeometry.WALLPAPER_CONFIRM_RECT, sourceText(self, 78))
    drawButton(self, PcStorageGeometry.WALLPAPER_CANCEL_RECT, sourceText(self, 73))
    if editor.focus == "confirm" then
      drawCursor(
        self,
        "menu",
        PcStorageGeometry.WALLPAPER_CONFIRM_CURSOR.x,
        PcStorageGeometry.WALLPAPER_CONFIRM_CURSOR.y
      )
    elseif editor.focus == "cancel" then
      drawCursor(self, "menu", PcStorageGeometry.WALLPAPER_CANCEL_CURSOR.x, PcStorageGeometry.WALLPAPER_CANCEL_CURSOR.y)
    else
      drawCursor(self, "menu", PcStorageGeometry.wallpaperCursorAnchor(editor.selected % 4))
    end
  else
    error("unknown Storage editor " .. tostring(editor.kind), 0)
  end
  graphics.setColor(1, 1, 1, 1)
end

-- Party icons are 32x32 sprites centred in the open tray.
local function drawPartyMon(self, resources, mon, slot, side, carried)
  if type(mon) ~= "table" then
    return
  end
  local rect = PcStorageGeometry.partySlotRect(slot, side)
  local y = rect.y - (carried and CARRY_LIFT or 0)
  local graphics = self._graphics
  drawIcon(graphics, resources.icons, mon.iconKey, rect.x, y, PcStorageGeometry.PARTY_ICON_SIZE)
  drawItemIcon(
    graphics,
    resources.itemIcons,
    mon.heldItem ~= "NONE" and mon.itemIconKey or nil,
    rect.x + 20,
    y + 20,
    12
  )
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
  windows:drawWindow(window, frameIndex, fill)
  self._graphics.setColor(1, 1, 1, 1)
  self._text:drawText(messageText(self, message), window.x, window.y)
  if message.yesNo then
    for _, choice in ipairs({
      { rect = PcStorageGeometry.YES_RECT, label = "YES" },
      { rect = PcStorageGeometry.NO_RECT, label = "NO" },
    }) do
      local rect = choice.rect
      windows:drawStandardWindow(
        { x = rect.x + 8, y = rect.y + 8, width = rect.width - 16, height = rect.height - 16 },
        fill
      )
      self._text:drawText(choice.label, rect.x + 12, rect.y + 8)
    end
  end
end

function PcStorageRenderer:drawPane(view, resources, paneId, placement)
  assert(not self._disposed, "disposed Storage renderer draws nothing")
  local graphics = self._graphics
  resources = resources or {}
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
      end
      return
    end
    -- Touch screen, back to front: the cream base, the wallpaper tilemap, the
    -- box icons (OBJ priority 3, behind the box pane's BG2 but over BG3), the
    -- box pane (transparent over the wallpaper), the party tray (BG1), and the
    -- party icons (OBJ priority 1, in front of the tray).
    drawVisual(self, storage.backgrounds.default, 0, 0)
    local wallpaperId = assert(view.wallpaperId or 0, "Storage snapshots carry a wallpaper")
    local wallpaper = assert(storage.wallpapers[wallpaperId], "selected wallpaper is compiled")
    drawVisual(self, wallpaper, PcStorageGeometry.WALLPAPER.x, PcStorageGeometry.WALLPAPER.y)
    for slot, mon in ipairs(assert(view.boxSlots, "Storage snapshots carry all box slots")) do
      if not carriedFrom(view, "box", slot - 1) then
        drawBoxMon(self, resources, mon, slot - 1)
      end
    end
    drawVisual(self, storage.ui.boxPane, 0, 0)
    if view.editor == nil then
      for side, center in pairs(PcStorageGeometry.BOX_ARROW_CENTERS) do
        local arrow = storage.ui.arrows[side]
        drawVisual(self, arrow, center.x + arrow.anchorX, center.y + arrow.anchorY)
      end
    end
    local editing = view.editor ~= nil
    local trayOpen = view.tray ~= "closed"
    if trayOpen then
      local origin = PcStorageGeometry.PARTY_TRAY_ORIGINS[view.tray]
      drawVisual(self, storage.ui.partyTray, origin.x, origin.y)
    end
    if view.editor ~= nil and view.editor.kind == "markings" then
      local panel = PcStorageGeometry.PARTY_TRAY_ORIGINS.right
      drawVisual(self, storage.ui.markingPanel, panel.x, panel.y)
    end
    for slot, mon in ipairs(view.party or {}) do
      if trayOpen and not editing and not carriedFrom(view, "party", slot - 1) then
        drawPartyMon(self, resources, mon, slot - 1, view.tray)
      end
    end
    drawEditor(self, view)
    if view.carry ~= nil and view.carry.mon ~= nil then
      local target = view.carry.destination or view.focus
      if target ~= nil then
        if target.kind == "party" or target.domain == "party" then
          if view.tray ~= "closed" then
            drawPartyMon(self, resources, view.carry.mon, target.slot, view.tray, true)
          end
        elseif target.slot ~= nil then
          local box = target.box or view.activeBox
          if box == view.activeBox then
            drawBoxMon(self, resources, view.carry.mon, target.slot, true)
          end
        end
      end
    end
    if self._text.drawText then
      -- The box title plate spans x 26..141, y 17..39 (hit rect); the title is
      -- centred on it.
      local title = tostring(view.boxName or "")
      self._text:drawText(title, 84 - self._text:textWidth(title) / 2, 20)
      if view.menu ~= nil then
        local count = #view.menu.actions
        for index, action in ipairs(view.menu.actions) do
          drawButton(self, PcStorageGeometry.actionButtonRect(count, index - 1), sourceLabel(self, action))
        end
      end
      for _, button in ipairs(PcStorageGeometry.bottomButtons(view)) do
        drawButton(self, button.rect, sourceText(self, button.messageId))
      end
      if view.message ~= nil then
        drawMessage(self, resources, view.message)
      end
    end
    if view.editor == nil then
      local x, y, pose
      if view.carry ~= nil then
        local target = view.carry.destination or view.focus
        pose = "carry"
        if target ~= nil and (target.kind == "party" or target.domain == "party") then
          if view.tray ~= "closed" then
            x, y = PcStorageGeometry.partyCursorAnchor(target.slot, view.tray)
          end
        elseif target ~= nil then
          x, y = PcStorageGeometry.boxCursorAnchor(target.slot)
        end
      elseif view.menu ~= nil then
        pose = "menu"
        x, y = PcStorageGeometry.actionCursorAnchor(#view.menu.actions, view.menu.selected - 1)
      elseif view.focus ~= nil then
        pose = "browse"
        local focus = view.focus
        if focus.domain == "party" or focus.kind == "party" then
          if view.tray ~= "closed" then
            x, y = PcStorageGeometry.partyCursorAnchor(focus.slot, view.tray)
          end
        else
          x, y = PcStorageGeometry.boxCursorAnchor(focus.slot)
        end
      end
      if x ~= nil then
        drawCursor(self, pose, x, y)
      end
    end
  end)
end

function PcStorageRenderer:draw(view, plan)
  for _, pane in ipairs(plan.panes) do
    self:drawPane(view, plan, pane.id, pane.placement)
  end
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
end

function PcStorageRenderer:release()
  self:dispose()
end

return PcStorageRenderer
