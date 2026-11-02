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
---@field _tokenRoles table<integer, string[]> request token to the semantic roles it serves
---@field _tokenPaths table<integer, string> request token to its generated image path
---@field _leases table[] owned acquired image leases
---@field _leaseByRole table<string, ImageAssetPoolLease> semantic role to its acquired image lease
---@field _leaseByPath table<string, ImageAssetPoolLease> generated image path to its acquired image lease
---@field _quadByFrame table<table, love.Quad> prepared viewport per immutable compiled frame
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
---@field backdrops table<string, string> semantic role to its indexed backdrop asset key
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
    _tokenRoles = {},
    _tokenPaths = {},
    _leases = {},
    _leaseByRole = {},
    _leaseByPath = {},
    _quadByFrame = {},
    _ready = false,
    _disposed = false,
  }, OptionsRenderer)
end

---@return OptionsRenderer.Section the generated options section, never a substitute
function OptionsRenderer:_section()
  local manifest = self._manifest
  local section = manifest.options
  assert(type(section) == "table", "the field-UI manifest carries the options section")
  assert(section.version == 2, "the options section carries its locked version")
  return section
end

-- Requests every unique required art path once through the shared pool:
-- the packed chrome atlas frames plus the two semantic source backdrops
-- resolved through the manifest asset index, never hardcoded producer
-- paths. Pending interests accumulate under this owner; the pool keeps the
-- shared GPU objects. Each request remembers the semantic roles it serves
-- so one shared path never acquires twice.
function OptionsRenderer:_requestChrome()
  local section = self:_section()
  local seen = {}
  local function add(path, role)
    if type(path) ~= "string" or path == "" then
      error(role .. " art path is required", 0)
    end
    local entry = seen[path]
    if entry == nil then
      local token = self._imagePool:request(path, POOLED_SAMPLER, "demand")
      entry = { token = token, roles = {} }
      seen[path] = entry
      self._tokens[#self._tokens + 1] = token
      self._tokenRoles[token] = entry.roles
      self._tokenPaths[token] = path
    end
    entry.roles[#entry.roles + 1] = role
  end
  local choices = assert(section.choices, "the options section carries its choice sequences")
  for _, size in ipairs({ "small", "wide" }) do
    local group = assert(choices[size], "the options section carries its " .. size .. " choices")
    for _, state in ipairs({ "unselected", "selected" }) do
      local sequence = assert(group[state], "choices carry both states")
      for _, frame in ipairs(assert(sequence.frames, "choices carry frames")) do
        add(frame.image, "chrome")
      end
    end
  end
  local arrows = assert(section.arrows, "the options section carries its arrows")
  for _, side in ipairs({ "left", "right" }) do
    local pair = assert(arrows[side], "arrows carry both sides")
    for _, state in ipairs({ "idle", "pressed" }) do
      local sequence = assert(pair[state], "arrows carry idle and pressed states")
      for _, frame in ipairs(assert(sequence.frames, "arrows carry frames")) do
        add(frame.image, "chrome")
      end
    end
  end
  local actions = assert(section.actions, "the options section carries footer actions")
  for _, state in ipairs({ "normal", "focused", "pressed", "pressedFocused" }) do
    local sequence = assert(actions[state], "actions carry every compiled state")
    for _, frame in ipairs(assert(sequence.frames, "actions carry frames")) do
      add(frame.image, "chrome")
    end
  end
  local backdrops = assert(section.backdrops, "the options section carries its source backdrops")
  local assets = assert(self._manifest.assets, "the field-UI manifest indexes its assets")
  for _, role in ipairs({ "controls", "preview" }) do
    local assetKey = assert(backdrops[role], "the options section carries its " .. role .. " backdrop role")
    local entry = assert(assets[assetKey], "the " .. role .. " backdrop indexes its asset")
    add(assert(entry.image, "the " .. role .. " backdrop asset carries its image path"), role)
  end
end

-- Prebuilds one stable viewport per unique immutable compiled frame
-- outside draw, using the acquired image dimensions for that frame's own
-- atlas path. Draw resolves these by frame identity and never allocates.
function OptionsRenderer:_buildQuads()
  local graphics = assert(love and love.graphics, "options chrome preparation requires its host graphics")
  local section = self:_section()
  local seen = {}
  local function add(sequence, what)
    for _, frame in ipairs(assert(sequence.frames, what .. " carry frames")) do
      if not seen[frame] then
        seen[frame] = true
        local lease = assert(self._leaseByPath[frame.image], what .. " resolves its prepared lease")
        local image = assert(lease.image, what .. " lease carries its resolved image")
        local width, height = image:getWidth(), image:getHeight()
        self._quadByFrame[frame] =
          graphics.newQuad(frame.atlas.x, frame.atlas.y, frame.atlas.width, frame.atlas.height, width, height)
      end
    end
  end
  for _, size in ipairs({ "small", "wide" }) do
    local group = assert(section.choices[size], "the options section carries its " .. size .. " choices")
    add(assert(group.unselected, "choices carry both states"), "choices." .. size .. ".unselected")
    add(assert(group.selected, "choices carry both states"), "choices." .. size .. ".selected")
  end
  for _, side in ipairs({ "left", "right" }) do
    local pair = assert(section.arrows[side], "arrows carry both sides")
    add(assert(pair.idle, "arrows carry idle and pressed states"), "arrows." .. side .. ".idle")
    add(assert(pair.pressed, "arrows carry idle and pressed states"), "arrows." .. side .. ".pressed")
  end
  for _, state in ipairs({ "normal", "focused", "pressed", "pressedFocused" }) do
    add(assert(section.actions[state], "actions carry every compiled state"), "actions." .. state)
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
    local byToken = {}
    for _, token in ipairs(self._tokens) do
      local lease = self._imagePool:acquire(token)
      byToken[token] = lease
      self._leases[#self._leases + 1] = lease
    end
    self._tokens = {}
    for token, lease in pairs(byToken) do
      for _, role in ipairs(assert(self._tokenRoles[token], "prepared requests carry their roles")) do
        if self._leaseByRole[role] == nil then
          self._leaseByRole[role] = lease
        end
      end
      local path = assert(self._tokenPaths[token], "prepared requests carry their path")
      if self._leaseByPath[path] == nil then
        self._leaseByPath[path] = lease
      end
      self._tokenRoles[token] = nil
      self._tokenPaths[token] = nil
    end
    assert(self._leaseByRole.chrome ~= nil, "prepared chrome carries its lease")
    assert(self._leaseByRole.controls ~= nil, "prepared controls carry their backdrop lease")
    assert(self._leaseByRole.preview ~= nil, "prepared preview carries its backdrop lease")
    self:_buildQuads()
  end)
  if not ok then
    self:_releaseOwned()
    error(err, 0)
  end
  self._ready = true
  return true
end

-- Paints one resolved plan: each pane first paints its own semantic
-- source backdrop, then the controls/content pane paints the header, the
-- clipped scrolling rows translated by the list offset, the local preview
-- sample, and the fixed footer, while the preview pane paints only the
-- sample window. Rows outside the published viewport never draw; draw
-- acquires nothing and leaves shared owners alone.
---@param view table<string, unknown> the screen semantic snapshot
---@param plan table<string, unknown> the resolved plan
function OptionsRenderer:draw(view, plan)
  assert(not self._disposed, "a disposed options renderer draws nothing")
  assert(self._ready, "the options renderer draws only after preparation")
  assert(type(view) == "table", "options draw needs its view")
  assert(type(plan) == "table" and type(plan.content) == "table", "options draw needs its content")
  local graphics = assert(love and love.graphics, "options drawing requires its host graphics namespace")
  local content = assert(plan.content, "the plan carries its options content")
  local chrome = assert(self._leaseByRole.chrome, "prepared chrome carries its lease")
  local section = self:_section()
  local ink = { foreground = { r = 1, g = 1, b = 1, a = 1 }, shadow = { r = 0, g = 0, b = 0, a = 1 } }
  local function quadFor(frame)
    return assert(self._quadByFrame[frame], "prepared chrome carries every drawn frame")
  end
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
        self:_drawRow(graphics, chrome, quadFor, section, ink, row, rowView, view)
      end
    end
  end
  for _, pane in ipairs(assert(plan.panes, "the plan carries its panes")) do
    local paneId = assert(pane.id, "panes carry their semantic id")
    if paneId == "preview" then
      LogicalSurface.draw(graphics, assert(pane.placement, "panes carry placements"), function()
        self:_drawBackdrop(graphics, "preview")
        self:_drawPreview(graphics, section, ink, content, view)
      end)
    elseif paneId == "controls" or paneId == "content" then
      LogicalSurface.draw(graphics, assert(pane.placement, "panes carry placements"), function()
        self:_drawBackdrop(graphics, "controls")
        local viewport = assert(content.listViewport, "content carries its list viewport")
        LogicalSurface.clip(graphics, viewport, function()
          graphics.push("all")
          graphics.translate(0, viewport.y - content.scrollOffset)
          drawRows()
          graphics.pop()
        end)
        self:_drawLegacyNote(ink, view)
        if paneId == "content" then
          self:_drawPreview(graphics, section, ink, content, view)
        end
        self:_drawFooter(graphics, chrome, quadFor, section, ink, content, view)
      end)
    else
      error("unknown options pane " .. tostring(paneId), 0)
    end
  end
end

---@param graphics love.graphics
---@param role string "controls"|"preview" the semantic backdrop role
function OptionsRenderer:_drawBackdrop(graphics, role)
  local lease = assert(self._leaseByRole[role], "prepared backdrops carry their " .. role .. " lease")
  lease:draw(graphics, 0, 0)
end

---@param graphics love.graphics
---@param chrome ImageAssetPoolLease
---@param quadFor fun(frame: OptionsWidgets.SequenceFrame): love.Quad prepared viewport per immutable compiled frame
---@param section OptionsRenderer.Section
---@param ink OptionsWidgets.Ink
---@param row OptionsInterface.RowLayout
---@param rowView table<string, unknown>
---@param view table<string, unknown>
function OptionsRenderer:_drawRow(graphics, chrome, quadFor, section, ink, row, rowView, view)
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
      quadFor,
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
    local label = assert(rowView.choiceLabels[choiceIndex], "every option stop is labeled")
    OptionsWidgets.drawChoice(
      graphics,
      chrome,
      quadFor,
      text,
      group,
      { x = rect.x, y = rect.y },
      label,
      { x = rect.x, y = rect.y },
      ink,
      choiceIndex == index,
      0
    )
  end
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
---@param quadFor fun(frame: OptionsWidgets.SequenceFrame): love.Quad prepared viewport per immutable compiled frame
---@param section OptionsRenderer.Section
---@param ink OptionsWidgets.Ink
---@param content OptionsInterface.ContentGeometry
---@param view table<string, unknown>
function OptionsRenderer:_drawFooter(graphics, chrome, quadFor, section, ink, content, view)
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
    quadFor,
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
    quadFor,
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
  self._tokenRoles = {}
  self._tokenPaths = {}
  for _, lease in ipairs(self._leases) do
    pcall(function()
      self._imagePool:release(lease)
    end)
  end
  self._leases = {}
  self._leaseByRole = {}
  self._leaseByPath = {}
  self._quadByFrame = {}
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
