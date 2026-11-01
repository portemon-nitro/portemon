-- Per-open Options resources and concrete screen painting: the renderer
-- borrows the shared image pool, the field text/window services, and the
-- generated options manifest, then prepares pooled leases outside draw and
-- paints one resolved plan per frame through the shared option widgets.
-- Draw performs no acquisition, no IO, and never releases shared owners; disposal
-- cancels pending interests and releases owned leases exactly once.

local LogicalSurface = require("libs.ui.src.LogicalSurface")
local OptionsWidgets = require("game.hgss.src.ui.OptionsWidgets")

---@class OptionsRenderer
---@field _cacheFs CacheFs borrowed generated asset filesystem
---@field _manifest FieldUiAssetCache.Manifest validated field-UI manifest carrying the options section
---@field _imagePool ImageAssetPool borrowed shared session image owner
---@field _text OptionsWidgets.TextCollaborator borrowed text collaborator
---@field _window OptionsRenderer.WindowCollaborator borrowed window collaborator
---@field _tokens integer[] owned pending request tokens
---@field _leases table[] owned acquired image leases
---@field _ready boolean
---@field _disposed boolean
local OptionsRenderer = {}
OptionsRenderer.__index = OptionsRenderer

local POOLED_SAMPLER = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }

---@class OptionsRenderer.Section
---@field version integer
---@field labels table<string, unknown>
---@field choices table<string, unknown>
---@field arrows table<string, unknown>
---@field actions table<string, unknown>
---@field framePreviewText table<integer, table<string, unknown>>?
---@field animationTickSeconds number?
---@alias OptionsRenderer.Rect { x: number, y: number, width: number, height: number }
---@alias OptionsRenderer.WindowCollaborator { drawWindow: fun(self: OptionsRenderer.WindowCollaborator, rect: OptionsRenderer.Rect, frameIndex: integer, background: number[]) }
---@class OptionsRenderer.Options
---@field cacheFs CacheFs borrowed generated asset filesystem
---@field manifest FieldUiAssetCache.Manifest validated field-UI manifest carrying the options section
---@field imagePool ImageAssetPool borrowed shared session image owner
---@field text table<string, unknown> borrowed text collaborator, cast after its capability checks
---@field window OptionsRenderer.WindowCollaborator borrowed window collaborator

---@param opts OptionsRenderer.Options
---@return OptionsRenderer
function OptionsRenderer.new(opts)
  assert(type(opts) == "table", "the options renderer requires options")
  assert(type(opts.cacheFs) == "table", "the options renderer borrows its asset filesystem")
  assert(type(opts.manifest) == "table", "the options renderer borrows its validated manifest")
  assert(type(opts.imagePool) == "table", "the options renderer borrows the shared image owner")
  local text = assert(opts.text, "the options renderer borrows its text service")
  assert(
    type(text.drawTextWithPalette) == "function" and type(text.windowBackgroundColor) == "function",
    "the options renderer borrows its text service"
  )
  ---@cast text OptionsWidgets.TextCollaborator
  assert(type(opts.window) == "table", "the options renderer borrows its window service")
  return setmetatable({
    _cacheFs = opts.cacheFs,
    _manifest = opts.manifest,
    _imagePool = opts.imagePool,
    _text = text,
    _window = opts.window,
    _tokens = {},
    _leases = {},
    _ready = false,
    _disposed = false,
  }, OptionsRenderer)
end

---@return OptionsRenderer.Section the generated options section, never a substitute
function OptionsRenderer:_section()
  local manifest = self._manifest
  local section = manifest.options
  assert(type(section) == "table", "the field-UI manifest carries the options section")
  assert(section.version == 1, "the options section carries its locked version")
  return section
end

-- Requests every unique required chrome atlas path once through the shared
-- pool. Pending interests accumulate under this owner; the pool keeps the
-- shared GPU objects.
function OptionsRenderer:_requestChrome()
  local section = self:_section()
  local seen = {}
  local function add(path)
    if type(path) ~= "string" or seen[path] then
      return
    end
    seen[path] = true
    local token = self._imagePool:request(path, POOLED_SAMPLER, "demand")
    self._tokens[#self._tokens + 1] = token
  end
  local choices = assert(section.choices, "the options section carries its choice sequences")
  for _, size in ipairs({ "small", "wide" }) do
    local group = assert(choices[size], "the options section carries its " .. size .. " choices")
    for _, state in ipairs({ "unselected", "selected" }) do
      local sequence = assert(group[state], "choices carry both states")
      for _, frame in ipairs(assert(sequence.frames, "choices carry frames")) do
        add(frame.image)
      end
    end
  end
  local arrows = assert(section.arrows, "the options section carries its arrows")
  for _, side in ipairs({ "left", "right" }) do
    local pair = assert(arrows[side], "arrows carry both sides")
    for _, state in ipairs({ "idle", "pressed" }) do
      local sequence = assert(pair[state], "arrows carry idle and pressed states")
      for _, frame in ipairs(assert(sequence.frames, "arrows carry frames")) do
        add(frame.image)
      end
    end
  end
  local actions = assert(section.actions, "the options section carries its footer actions")
  for _, state in ipairs({ "normal", "focused", "pressed", "pressedFocused" }) do
    local sequence = assert(actions[state], "actions carry every compiled state")
    for _, frame in ipairs(assert(sequence.frames, "actions carry frames")) do
      add(frame.image)
    end
  end
end

-- Advances preparation without blocking: pending interests poll through
-- the shared queue, a terminal failure unwinds owned state before it
-- surfaces, and readiness acquires each lease once and prebuilds every
-- caller-owned quad outside draw.
---@return boolean ready
---@return string? failure while waiting
function OptionsRenderer:prepare()
  assert(not self._disposed, "a disposed options renderer prepares nothing")
  if self._ready then
    return true
  end
  if #self._tokens == 0 then
    local ok, err = pcall(function()
      self:_requestChrome()
    end)
    if not ok then
      self:_releaseOwned()
      error(err, 0)
    end
  end
  for _, token in ipairs(self._tokens) do
    local status, failure = self._imagePool:poll(token)
    if status == "failed" then
      local cause = failure
      self:_releaseOwned()
      error("options art preparation failed: " .. tostring(cause), 0)
    end
    if status ~= "ready" then
      return false
    end
  end
  local ok, err = pcall(function()
    for _, token in ipairs(self._tokens) do
      self._leases[#self._leases + 1] = self._imagePool:acquire(token)
    end
    self._tokens = {}
  end)
  if not ok then
    self:_releaseOwned()
    error(err, 0)
  end
  self._ready = true
  return true
end

-- Paints one resolved plan: header, the clipped scrolling rows with
-- source-derived controls, the local preview sample, and the fixed
-- footer with its focus treatment. Rows outside the published viewport
-- never draw; draw acquires nothing and leaves shared owners alone.
---@param view table<string, unknown> the screen semantic snapshot
---@param plan table<string, unknown> the resolved plan
function OptionsRenderer:draw(view, plan)
  assert(not self._disposed, "a disposed options renderer draws nothing")
  assert(self._ready, "the options renderer draws only after preparation")
  assert(type(view) == "table", "options draw needs its view")
  assert(type(plan) == "table" and type(plan.content) == "table", "options draw needs its content")
  local graphics = assert(love and love.graphics, "options drawing requires its host graphics namespace")
  local content = assert(plan.content, "the plan carries its options content")
  local chrome = assert(self._leases[1], "prepared chrome carries its lease")
  -- Every generated option frame shares the one packed chrome atlas, so a
  -- single lease paints all states; a second atlas would need per-frame
  -- lease selection here instead of this first-lease shortcut.
  assert(#self._leases == 1, "option chrome packs into one shared atlas lease")
  local section = self:_section()
  local ink = { foreground = { r = 1, g = 1, b = 1, a = 1 }, shadow = { r = 0, g = 0, b = 0, a = 1 } }
  local function drawRows()
    for _, row in ipairs(assert(content.rows, "content carries its rows")) do
      if not row.clipped then
        local rowView = nil
        for _, entry in ipairs(assert(view.rows, "the view carries its rows")) do
          if entry.id == row.id then
            rowView = entry
            break
          end
        end
        assert(rowView ~= nil, "every laid-out row has a published value")
        self:_drawRow(graphics, chrome, section, ink, row, rowView, view)
      end
    end
  end
  for _, pane in ipairs(assert(plan.panes, "the plan carries its panes")) do
    if pane.interactive then
      LogicalSurface.draw(graphics, assert(pane.placement, "panes carry placements"), function()
        local viewport = assert(content.listViewport, "content carries its list viewport")
        LogicalSurface.clip(graphics, viewport, drawRows)
        self:_drawLegacyNote(ink, view)
        self:_drawPreview(graphics, section, ink, content, view)
        self:_drawFooter(graphics, chrome, section, ink, content, view)
      end)
    end
  end
end

---@param graphics love.graphics
---@param chrome ImageAssetPoolLease
---@param section OptionsRenderer.Section
---@param ink OptionsWidgets.Ink
---@param row OptionsInterface.RowLayout
---@param rowView table<string, unknown>
---@param view table<string, unknown>
function OptionsRenderer:_drawRow(graphics, chrome, section, ink, row, rowView, view)
  local _ = view
  local text = assert(self._text, "options rows borrow the text service")
  text:drawTextWithPalette(
    assert(rowView.label, "rows carry their label"),
    row.labelAnchor.x,
    row.labelAnchor.y,
    ink.shadow
  )
  text:drawTextWithPalette(
    assert(rowView.label, "rows carry their label"),
    row.labelAnchor.x,
    row.labelAnchor.y,
    ink.foreground
  )
  local control = assert(row.control, "rows carry their control geometry")
  local selected = view.focusId == row.id
  if control.kind == "slider" then
    local resolved = assert(control.slider, "slider rows carry resolved geometry")
    OptionsWidgets.drawSlider(graphics, resolved, selected, {
      rail = { r = 0.25, g = 0.25, b = 0.25, a = 1 },
      fill = { r = 0.9, g = 0.9, b = 0.9, a = 1 },
      thumb = { r = 0.95, g = 0.95, b = 0.95, a = 1 },
      thumbEdge = { r = 0.1, g = 0.1, b = 0.1, a = 1 },
      focus = { r = 1, g = 0.85, b = 0.2, a = 1 },
    })
    text:drawTextWithPalette(
      assert(rowView.valueLabel, "rows carry their value label"),
      control.rect.x,
      row.rect.y + 4,
      ink.foreground
    )
    return
  end
  local group = section.choices.wide
  if rowView.valueCount <= 2 then
    group = section.choices.small
  end
  if control.kind == "cycle" then
    OptionsWidgets.drawCycle(
      graphics,
      chrome,
      text,
      assert(section.arrows, "the section carries arrows"),
      control.leftArrow,
      control.rightArrow,
      assert(rowView.valueLabel, "rows carry their value label"),
      { x = control.value.x + control.value.width / 2, y = row.rect.y + 4 },
      ink,
      nil,
      0
    )
    return
  end
  local choiceRects = assert(control.choices, "choice rows carry choice rects")
  local index = assert(rowView.valueIndex, "rows carry their value stop")
  for choiceIndex, rect in ipairs(choiceRects) do
    OptionsWidgets.drawChoice(
      graphics,
      chrome,
      text,
      group,
      { x = rect.x, y = rect.y },
      choiceIndex == index and assert(rowView.valueLabel, "rows carry their value label") or "",
      { x = rect.x, y = rect.y },
      ink,
      choiceIndex == index,
      0
    )
  end
  local _ = selected
end

---@param _ love.graphics
---@param section OptionsRenderer.Section
---@param ink OptionsWidgets.Ink
---@param content OptionsInterface.ContentGeometry
---@param view table<string, unknown>
function OptionsRenderer:_drawPreview(_, section, ink, content, view)
  local preview = content.preview
  if preview == nil then
    return
  end
  local window = assert(self._window, "the preview borrows the window service")
  local text = assert(self._text, "the preview borrows the text service")
  local frame = (view.preview ~= nil and view.preview.textFrame) or 0
  window:drawWindow(
    { x = preview.x, y = preview.y, width = preview.width, height = preview.height },
    frame,
    text:windowBackgroundColor()
  )
  local labels = section.labels or {}
  local sample = "SAMPLE"
  if labels.framePreviewText ~= nil then
    local entry = labels.framePreviewText[(view.preview ~= nil and view.preview.textFrame) or 0]
    if entry ~= nil and type(entry.text) == "string" then
      sample = entry.text
    end
  end
  text:drawTextWithPalette(sample, preview.x + 4, preview.y + 4, ink.foreground)
end

-- Paints the staged legacy-Slow migration note in the header band above
-- the scrolling list when the draft carries it. The fixed header copy
-- stays in borrowed text services beside the rows; no atlas is added.
---@param ink OptionsWidgets.Ink
---@param view table<string, unknown>
function OptionsRenderer:_drawLegacyNote(ink, view)
  if view.legacyNote == nil then
    return
  end
  local text = assert(self._text, "the header note borrows the text service")
  text:drawTextWithPalette("SLOW BECOMES MID", 12, 4, ink.shadow)
  text:drawTextWithPalette("SLOW BECOMES MID", 12, 4, ink.foreground)
  text:drawTextWithPalette("CONFIRM: MID QUIT: SLOW", 12, 12, ink.shadow)
  text:drawTextWithPalette("CONFIRM: MID QUIT: SLOW", 12, 12, ink.foreground)
end

---@param graphics love.graphics
---@param chrome ImageAssetPoolLease
---@param section OptionsRenderer.Section
---@param ink OptionsWidgets.Ink
---@param content OptionsInterface.ContentGeometry
---@param view table<string, unknown>
function OptionsRenderer:_drawFooter(graphics, chrome, section, ink, content, view)
  local footer = assert(content.footer, "content carries its footer")
  local text = assert(self._text, "the footer borrows the text service")
  local actions = assert(section.actions, "the section carries footer actions")
  local focusId = view.focusId
  local confirmState = "normal"
  if focusId == "confirm" then
    confirmState = "focused"
  end
  local quitState = "normal"
  if focusId == "quit" then
    quitState = "focused"
  end
  OptionsWidgets.drawAction(
    graphics,
    chrome,
    text,
    actions,
    footer.confirmRect,
    (view.footer ~= nil and view.footer.confirm ~= nil and view.footer.confirm.label) or "CONFIRM",
    { x = footer.confirmRect.x, y = footer.confirmRect.y },
    ink,
    confirmState,
    0
  )
  OptionsWidgets.drawAction(
    graphics,
    chrome,
    text,
    actions,
    footer.quitRect,
    (view.footer ~= nil and view.footer.quit ~= nil and view.footer.quit.label) or "QUIT",
    { x = footer.quitRect.x, y = footer.quitRect.y },
    ink,
    quitState,
    0
  )
end

function OptionsRenderer:_releaseOwned()
  for _, token in ipairs(self._tokens) do
    pcall(function()
      self._imagePool:cancel(token)
    end)
  end
  self._tokens = {}
  for _, lease in ipairs(self._leases) do
    pcall(function()
      self._imagePool:release(lease)
    end)
  end
  self._leases = {}
  self._ready = false
end

-- Releases pending interests and owned leases exactly once; shared pool,
-- text, and window owners are never released or disposed here. Either
-- disposal order (port dispose before or after field teardown) is safe.
function OptionsRenderer:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self:_releaseOwned()
end

return OptionsRenderer
