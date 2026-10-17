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
---@field _paneTouch table<string, boolean>? paths drawn by the in-flight pane
---@field _requiredByPane table<string, table<string, boolean>> last drawn demand per pane id
---@field _disposed boolean
local PcStorageRenderer = {}
PcStorageRenderer.__index = PcStorageRenderer

-- Storage visuals sample point-filtered and clamped, matching the shared
-- construction below, so pooled leases draw identically.
local POOLED_SAMPLER = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }

-- Borrows one generated visual through the shared owner, waiting out its
-- classification without blocking the field longer than the bounded stall
-- budget. Failures name their path instead of drawing a blank visual.
---@param pool table<string, unknown>
---@param path string
---@return table<string, unknown> lease resolving the immutable visual
local function acquirePinned(pool, path)
  local token = pool:request(path, POOLED_SAMPLER, "demand")
  local stalled = 0
  while true do
    local status, failure = pool:poll(token)
    if status == "ready" then
      return pool:acquire(token)
    end
    if status == "failed" then
      error("compiled Storage image missing at " .. path .. ": " .. tostring(failure), 0)
    end
    assert(status == "pending", "storage preparation reports pending or ready")
    stalled = stalled + 1
    if stalled > 10000 then
      error("compiled Storage image stalled at " .. path, 0)
    end
    local timer = love and love.timer
    if timer ~= nil and timer.sleep ~= nil then
      timer.sleep(0.001)
    end
  end
end

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

local function imageFor(self, visual)
  assert(type(visual) == "table" and type(visual.image) == "string", "Storage visuals carry image paths")
  local path = visual.image
  local lease = self._leases[path]
  if lease == nil then
    -- State visuals borrow the shared owner as installed leases; two opens
    -- of one box resolve one physical image per visual through the pool.
    lease = acquirePinned(assert(self._pool, "Storage renderer borrows its shared image owner"), path)
    self._leases[path] = lease
    self._images[path] = assert(lease.image, "shared leases carry their resolved image")
  end
  local touched = self._paneTouch
  if touched ~= nil then
    touched[path] = true
  end
  return lease
end

---@param self PcStorageRenderer
---@param path string
local function dropBorrowed(self, path)
  local lease = self._leases[path]
  if lease == nil then
    return
  end
  self._leases[path] = nil
  self._images[path] = nil
  assert(self._pool, "Storage renderer borrows its shared image owner"):release(lease)
end

-- Returns the borrows the live panes no longer demand: the current box
-- keeps its hard reference while replaced state rests idle and resident.
-- Callers trim idle physicals explicitly once the turnover settles.
---@param self PcStorageRenderer
local function dropUnrequired(self)
  local required = {}
  for _, set in pairs(self._requiredByPane) do
    for path in pairs(set) do
      required[path] = true
    end
  end
  local stale = {}
  for path in pairs(self._leases) do
    if required[path] ~= true then
      stale[#stale + 1] = path
    end
  end
  for _, path in ipairs(stale) do
    dropBorrowed(self, path)
  end
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
    _paneTouch = nil,
    _requiredByPane = {},
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
-- (ov14_021F2F88).
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

-- Top-screen info text at the source window positions (ov14_021F84B4):
-- message 87/88/89 label the Nature, Ability and Item values, 92 is "None"
-- and 93 stands in for an egg's hidden values.
local function drawInfo(self, info)
  local text = self._text
  text:drawText(info.nickname, 8, 56)
  if info.speciesName ~= nil then
    text:drawText(info.speciesName, 64, 40)
    text:drawText("Lv.", 32, 72)
    text:drawText(tostring(info.level), 48, 72)
    -- A dex number of zero prints nothing (ov14_021F5190).
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

-- The selected Pokémon's marks sit on the top-screen info panel, drawn into
-- BG5 at tile (15 + bit, 18) (ov14_021E895C).
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

-- Party icons are 32x32 sprites centred in the open tray (ov14_021F32E0).
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
  self._paneTouch = {}
  LogicalSurface.draw(graphics, placement, function()
    local storage = self._manifest.storage
    if paneId == "upper" then
      -- The top screen carries only the selected Pokémon's info panel.
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
  self._requiredByPane[paneId] = assert(self._paneTouch, "the drawn pane records its demand")
  self._paneTouch = nil
  dropUnrequired(self)
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
  for _, lease in pairs(self._leases) do
    pool:release(lease)
  end
  self._leases = {}
  self._images = {}
  self._requiredByPane = {}
  self._paneTouch = nil
end

function PcStorageRenderer:release()
  self:dispose()
end

return PcStorageRenderer
