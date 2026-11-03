-- Per-open Options resources and concrete screen painting: the renderer
-- borrows the shared image pool, the field text/window services, and the
-- generated options manifest, then prepares pooled leases outside draw and
-- paints one resolved plan per frame through the shared option widgets.
-- Draw performs no acquisition, no IO, and never releases shared owners; disposal
-- cancels pending interests and releases owned leases exactly once.

local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local LogicalSurface = require("libs.ui.src.LogicalSurface")
local OptionsWidgets = require("game.hgss.src.ui.OptionsWidgets")

-- Resolves the glyph origin inside the label's own bounded window:
-- centered about centerX (or the window center) unless a leading source
-- prefix asks otherwise. CURSOR_X/CURSOR_Y pin the window-relative step;
-- ALN_CENTER/ALN_RIGHT align in the window; otherwise defaultAlign holds.
---@param tokens table[] validated generated token stream
---@param window table<string, number> bounded label window
---@param centerX number? glyph center override
---@param defaultAlign string "left"|"center"|"right"
---@param measure fun(tokens: table[]): number glyph advance sum
---@return number x
---@return number y
local function layoutSource(tokens, window, centerX, defaultAlign, measure)
  local align = defaultAlign
  local pinnedX = nil
  local pinnedY = nil
  for _, token in ipairs(tokens) do
    if token.kind == "glyph" or token.kind == "eos" then
      break
    end
    if token.control == FieldMessageText.ALN_CENTER then
      align = "center"
    elseif token.control == FieldMessageText.ALN_RIGHT then
      align = "right"
    elseif token.control == FieldMessageText.CURSOR_X then
      pinnedX = token.args[1]
    elseif token.control == FieldMessageText.CURSOR_Y then
      pinnedY = token.args[1]
    end
  end
  local width = measure(tokens)
  local x = window.x
  if pinnedX ~= nil then
    x = window.x + pinnedX
  elseif align == "center" then
    x = (centerX or (window.x + window.width / 2)) - math.floor(width / 2)
  elseif align == "right" then
    x = window.x + window.width - width
  end
  local y = window.y
  if pinnedY ~= nil then
    y = window.y + pinnedY
  end
  return x, y
end

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
---@field selectionOverlay string required indexed selected-row strip asset key
---@field rowBackings table<string, string> semantic role to its indexed row backing asset key
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
    type(text.drawTokens) == "function"
      and type(text.drawPlain) == "function"
      and type(text.measureTokens) == "function"
      and type(text.measurePlain) == "function"
      and type(text.drawPreviewTokens) == "function"
      and type(text.windowBackgroundColor) == "function",
    "the options renderer borrows its source token text service"
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
  assert(section.version == 4, "the options section carries its locked version")
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
  local overlayKey = assert(section.selectionOverlay, "the options section carries its selection overlay role")
  local overlay = assert(assets[overlayKey], "the selection overlay indexes its asset")
  add(assert(overlay.image, "the selection overlay asset carries its image path"), "selectionOverlay")
  local backings = assert(section.rowBackings, "the options section carries its row plates")
  for _, role in ipairs({ "odd", "even", "frame" }) do
    local assetKey = assert(backings[role], "the options section carries its " .. role .. " row plate role")
    local entry = assert(assets[assetKey], "the " .. role .. " row plate indexes its asset")
    local leaseRole = "row" .. role:sub(1, 1):upper() .. role:sub(2)
    add(assert(entry.image, "the " .. role .. " row plate asset carries its image path"), leaseRole)
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

-- Validates the generated source label contract once at preparation: every
-- required menu role carries its glyph token stream and no unsupported
-- control survives into paint. Authored Volume/Battle Speed rows stay out;
-- they have no source records by design.
function OptionsRenderer:_checkLabels()
  local section = self:_section()
  local text = assert(self._text, "options labels borrow the text service")
  local labels = assert(section.labels, "the options section carries its source labels")
  local function record(role, group, key)
    local entry = group ~= nil and group[key] or nil
    assert(type(entry) == "table", "the options section carries its " .. role)
    text:measureTokens(assert(entry.tokens, "options " .. role .. " carries its glyph tokens"), role)
  end
  for _, rowId in ipairs({ "title", "textSpeed", "battleScene", "battleStyle", "soundMode", "textFrame" }) do
    record("row " .. rowId .. " label", labels, rowId)
  end
  record("footer confirm", labels, "confirm")
  record("footer quit", labels, "quit")
  local groups = {
    textSpeedValues = { "mid", "fast" },
    battleSceneValues = { "on", "off" },
    battleStyleValues = { "shift", "set" },
    soundModeValues = { "stereo", "mono" },
  }
  for groupName, stops in pairs(groups) do
    local group = assert(labels[groupName], "the options section carries its " .. groupName)
    for _, stop in ipairs(stops) do
      record("choice " .. groupName .. " " .. stop, group, stop)
    end
  end
  local frames = assert(labels.frameValues, "the options section carries its frame values")
  for slot = 0, 19 do
    record("frame value " .. (slot + 1), frames, slot)
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
    assert(self._leaseByRole.selectionOverlay ~= nil, "prepared selection overlay carries its lease")
    assert(self._leaseByRole.rowOdd ~= nil, "prepared odd row plate carries its lease")
    assert(self._leaseByRole.rowEven ~= nil, "prepared even row plate carries its lease")
    assert(self._leaseByRole.rowFrame ~= nil, "prepared frame plate carries its lease")
    self:_buildQuads()
    self:_checkLabels()
  end)
  if not ok then
    self:_releaseOwned()
    error(err, 0)
  end
  self._ready = true
  return true
end

-- Selects the scrolled plate for one laid-out row: the compound frame
-- backing for the closing item, otherwise the alternating band by content
-- position. Private to this module; leases stay borrowed, never owned here.
---@param row OptionsInterface.RowLayout laid-out row
---@return ImageAssetPoolLease borrowed plate lease
function OptionsRenderer:_plateFor(row)
  if row.id == "textFrame" then
    return assert(self._leaseByRole.rowFrame, "prepared frame plate carries its lease")
  end
  if row.position % 2 == 1 then
    return assert(self._leaseByRole.rowOdd, "prepared odd row plate carries its lease")
  end
  return assert(self._leaseByRole.rowEven, "prepared even row plate carries its lease")
end

-- Paints one resolved plan: each pane first paints its own semantic
-- source backdrop, then the controls/content pane paints the header, the
-- clipped scrolling rows translated by the list offset (the closing frame
-- row paints its child sample window inside the same clip), and the
-- fixed footer, while the upper preview pane paints only its decorative
-- backdrop. Every visible row plate paints before the single focused
-- strip and the row contents under one translation; rows outside the
-- published viewport never draw; draw acquires nothing and leaves shared
-- owners alone.
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
        self:_drawRow(graphics, chrome, quadFor, section, row, rowView, view)
      end
    end
  end
  for _, pane in ipairs(assert(plan.panes, "the plan carries its panes")) do
    local paneId = assert(pane.id, "panes carry their semantic id")
    if paneId == "preview" then
      LogicalSurface.draw(graphics, assert(pane.placement, "panes carry placements"), function()
        self:_drawBackdrop(graphics, "preview")
      end)
    elseif paneId == "controls" or paneId == "content" then
      LogicalSurface.draw(graphics, assert(pane.placement, "panes carry placements"), function()
        self:_drawBackdrop(graphics, "controls")
        local viewport = assert(content.listViewport, "content carries its list viewport")
        LogicalSurface.clip(graphics, viewport, function()
          graphics.push("all")
          -- One content-space translation serves every scrolled layer: all
          -- row plates first, then the single focused strip, then every
          -- visible row's contents. Nothing paints a second offset.
          graphics.translate(0, viewport.y - content.scrollOffset)
          for _, row in ipairs(assert(content.rows, "content carries its rows")) do
            if not row.clipped then
              self:_plateFor(row):draw(graphics, row.rect.x, row.rect.y)
            end
          end
          self:_drawStrip(graphics, content, view)
          drawRows()
          graphics.pop()
        end)
        self:_drawTitle(graphics, view)
        self:drawHeaderFeedback(view)
        self:_drawFooter(graphics, chrome, quadFor, section, content, view)
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

-- Paints the selected-row strip behind the focused scrollable row only,
-- at its content-space selector band under the single list translation.
-- Footer focus hides the layer.
---@param graphics love.graphics
---@param content OptionsInterface.ContentGeometry
---@param view table<string, unknown>
function OptionsRenderer:_drawStrip(graphics, content, view)
  local focusId = view.focusId
  if type(focusId) ~= "string" then
    return
  end
  local focused = nil
  for _, row in ipairs(assert(content.rows, "content carries its rows")) do
    if row.id == focusId then
      focused = row
      break
    end
  end
  if focused == nil or focused.clipped then
    return
  end
  local lease = assert(self._leaseByRole.selectionOverlay, "prepared selection overlay carries its lease")
  lease:draw(graphics, focused.rect.x, focused.rect.y)
end

-- Draws one source label record inside its bounded window: validates the
-- token stream at its semantic role, resolves the glyph origin from the
-- source prefix, and paints a single palette pass. Returns the origin.
---@param record table<string, unknown> generated label record
---@param box table<string, number> layout box
---@param clipRect table<string, number>? clip window
---@param centerX number? glyph center override
---@param defaultAlign string "left"|"center"|"right"
---@param role string semantic role for failure detail
---@param paletteRole string "normal"|"selected"
---@return number x
---@return number y
function OptionsRenderer:_drawSourceLabel(record, box, clipRect, centerX, defaultAlign, role, paletteRole)
  local text = assert(self._text, "options labels borrow the text service")
  local tokens = assert(record.tokens, "options " .. role .. " carries its glyph tokens")
  local x, y = layoutSource(tokens, box, centerX, defaultAlign, function(stream)
    return text:measureTokens(stream, role)
  end)
  if clipRect ~= nil then
    local graphics = assert(love and love.graphics, "options labels require their host graphics namespace")
    LogicalSurface.clip(graphics, clipRect, function()
      text:drawTokens(tokens, x, y, paletteRole, role)
    end)
  else
    text:drawTokens(tokens, x, y, paletteRole, role)
  end
  return x, y
end

-- Draws one authored plain string, centered about centerX when given.
---@param line string authored visible string
---@param box table<string, number> layout box
---@param clipRect table<string, number>? clip window
---@param centerX number? glyph center override
---@param paletteRole string "normal"|"selected"
---@return number x
---@return number y
function OptionsRenderer:_drawPlainLabel(line, box, clipRect, centerX, paletteRole)
  local text = assert(self._text, "options labels borrow the text service")
  assert(type(line) == "string", "authored options labels stay strings")
  local x = box.x
  if centerX ~= nil then
    x = centerX - math.floor(text:measurePlain(line) / 2)
  end
  if clipRect ~= nil then
    local graphics = assert(love and love.graphics, "options labels require their host graphics namespace")
    LogicalSurface.clip(graphics, clipRect, function()
      text:drawPlain(line, x, box.y, paletteRole)
    end)
  else
    text:drawPlain(line, x, box.y, paletteRole)
  end
  return x, box.y
end

-- Paints the OPTIONS title at its header origin. The staged migration
-- note keeps a separate bounded slot to the right, never over the title.
---@param graphics love.graphics
---@param view table<string, unknown>
function OptionsRenderer:_drawTitle(graphics, view)
  local title = view.titleSource
  if title == nil then
    return
  end
  LogicalSurface.clip(graphics, { x = 8, y = 0, width = 96, height = 24 }, function()
    self:_drawSourceLabel(title, { x = 10, y = 5, width = 94, height = 19 }, nil, nil, "left", "title", "normal")
  end)
end

-- Paints one published row: the row name once from source tokens (or the
-- authored string where no source record exists), then the control chrome
-- with value glyphs centered from measured advances. One palette pass
-- per label; selected values use the dark source ink.
---@param graphics love.graphics
---@param chrome ImageAssetPoolLease
---@param quadFor fun(frame: OptionsWidgets.SequenceFrame): love.Quad prepared viewport per immutable compiled frame
---@param section OptionsRenderer.Section
---@param row OptionsInterface.RowLayout
---@param rowView table<string, unknown>
---@param view table<string, unknown>
function OptionsRenderer:_drawRow(graphics, chrome, quadFor, section, row, rowView, view)
  local labelY = row.rect.y + 5
  if rowView.sourceLabel ~= nil then
    LogicalSurface.clip(graphics, { x = 12, y = row.rect.y, width = 100, height = 24 }, function()
      self:_drawSourceLabel(
        rowView.sourceLabel,
        { x = 12, y = labelY, width = 100, height = 19 },
        nil,
        nil,
        "left",
        "row " .. row.id .. " label",
        "normal"
      )
    end)
  else
    self:_drawPlainLabel(assert(rowView.label, "rows carry their label"), { x = 12, y = labelY }, nil, nil, "normal")
  end
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
    self:_drawPlainLabel(
      assert(rowView.valueLabel, "rows carry their value label"),
      { x = control.rect.x, y = labelY },
      nil,
      nil,
      "normal"
    )
    return
  end
  if control.kind == "cycle" then
    local pressedSide = nil
    local pressAge = 0
    local arrowPress = view.pressVisual
    if type(arrowPress) == "table" and arrowPress.kind == "arrow" then
      assert(arrowPress.side == "left" or arrowPress.side == "right", "arrow presses name a side")
      assert(
        type(arrowPress.ageTicks) == "number"
          and arrowPress.ageTicks == arrowPress.ageTicks
          and arrowPress.ageTicks >= 0,
        "arrow presses carry their source age"
      )
      pressedSide = arrowPress.side
      pressAge = arrowPress.ageTicks
    end
    OptionsWidgets.drawCycle(
      graphics,
      chrome,
      quadFor,
      assert(section.arrows, "the section carries arrows"),
      control.leftArrow.chromeAnchor,
      control.rightArrow.chromeAnchor,
      pressedSide,
      pressAge
    )
    local value = assert(control.value, "cycle rows carry their value geometry")
    local box = { x = value.labelWindow.x, y = labelY, width = value.labelWindow.width, height = 19 }
    if rowView.valueSource ~= nil then
      self:_drawSourceLabel(
        rowView.valueSource,
        box,
        value.labelWindow,
        value.textCenterX,
        "center",
        "frame value",
        "normal"
      )
    else
      self:_drawPlainLabel(
        assert(rowView.valueLabel, "rows carry their value label"),
        box,
        value.labelWindow,
        value.textCenterX,
        "normal"
      )
    end
    -- The closing frame row owns the live sample: paint it under the same
    -- list clip/translate, right after its selector chrome.
    if row.previewRect ~= nil then
      self:_drawPreview(graphics, row.previewRect, view)
    end
    return
  end
  local groupName = assert(control.chromeKind, "choice rows carry their source chrome kind")
  local group = assert(section.choices[groupName], "the options section carries its " .. groupName .. " choices")
  local index = assert(rowView.valueIndex, "rows carry their value stop")
  local display = rowView.choiceDisplay
  for choiceIndex, stop in ipairs(assert(control.choices, "choice rows carry choice stops")) do
    OptionsWidgets.drawChoice(graphics, chrome, quadFor, group, stop.chromeAnchor, choiceIndex == index, 0)
    local paletteRole = choiceIndex == index and "selected" or "normal"
    local box = { x = stop.labelWindow.x, y = labelY, width = stop.labelWindow.width, height = 19 }
    local entry = display ~= nil and display[choiceIndex] or nil
    local source = entry ~= nil and entry.source or nil
    if source ~= nil then
      self:_drawSourceLabel(
        source,
        box,
        stop.labelWindow,
        stop.textCenterX,
        "center",
        "choice " .. row.id .. " stop " .. choiceIndex,
        paletteRole
      )
    else
      local fallback = entry ~= nil and entry.text
        or assert(rowView.choiceLabels[choiceIndex], "every option stop is labeled")
      self:_drawPlainLabel(fallback, box, stop.labelWindow, stop.textCenterX, paletteRole)
    end
  end
end

-- Paints the menu-local sample inside its owning frame row: the
-- draft-frame border, then the already revealed printer token lines
-- clipped to the sample inset. The rect already sits in content
-- coordinates under the list clip/translate; an unrevealed sample draws
-- a blank framed window, and nothing static ever substitutes for the
-- printer status. Called exactly once per visible frame row, never as a
-- fixed copy outside the list.
---@param graphics love.graphics
---@param previewRect OptionsInterface.Rect content-space sample window owned by the frame row
---@param view table<string, unknown>
function OptionsRenderer:_drawPreview(graphics, previewRect, view)
  local window = assert(self._window, "the preview borrows the window service")
  local text = assert(self._text, "the preview borrows the text service")
  local previewView = view.preview
  local frame = (previewView ~= nil and previewView.textFrame) or 0
  window:drawWindow(
    { x = previewRect.x, y = previewRect.y, width = previewRect.width, height = previewRect.height },
    frame,
    text:windowBackgroundColor()
  )
  if previewView == nil then
    return
  end
  local lines = previewView.scrollLines or previewView.visibleLines
  if lines == nil then
    return
  end
  local lineHeight = previewView.lineHeight or 16
  local lineSpacing = previewView.lineSpacing or 0
  local scrollOffset = 0
  if previewView.scrollLines ~= nil then
    scrollOffset = previewView.scrollOffsetY or 0
  end
  local originX = previewRect.x + 4
  local lineY = previewRect.y + 4 - scrollOffset
  LogicalSurface.clip(graphics, {
    x = previewRect.x + 4,
    y = previewRect.y + 4,
    width = previewRect.width - 8,
    height = previewRect.height - 8,
  }, function()
    for _, line in ipairs(lines) do
      text:drawPreviewTokens(line.tokens or line, originX, lineY)
      lineY = lineY + lineHeight + lineSpacing
    end
  end)
end

-- Paints the bounded header feedback beside the title: a rejected
-- Confirm shows its authored two-line retry note while the full error
-- record stays in semantic status for debugging, otherwise the staged
-- legacy-Slow migration note paints in the same reserved band. Never
-- over the OPTIONS title and never raw exception text.
---@param view table<string, unknown>
function OptionsRenderer:drawHeaderFeedback(view)
  if view.error ~= nil then
    -- Two ~9px source-font lines cannot share the 24px header at an 8px
    -- pitch; stack at 12 so neither line paints into the other.
    self:_drawPlainLabel("APPLY FAILED", { x = 116, y = 4 }, nil, nil, "normal")
    self:_drawPlainLabel("RETRY", { x = 116, y = 16 }, nil, nil, "normal")
    return
  end
  self:_drawLegacyNote(view)
end

-- Paints the staged legacy-Slow migration note in its own bounded header
-- slot to the right of the title when the draft carries it. One palette
-- pass per line; the title window is never covered.
---@param view table<string, unknown>
function OptionsRenderer:_drawLegacyNote(view)
  if view.legacyNote == nil then
    return
  end
  self:_drawPlainLabel("SLOW BECOMES MID", { x = 116, y = 4 }, nil, nil, "normal")
  self:_drawPlainLabel("CONFIRM: MID QUIT: SLOW", { x = 116, y = 16 }, nil, nil, "normal")
end

-- Paints the fixed footer: one source action frame per button with the
-- Confirm/Quit glyphs centered in their own label windows. One palette
-- pass per label; the two windows never share an x anchor.
---@param graphics love.graphics
---@param chrome ImageAssetPoolLease
---@param quadFor fun(frame: OptionsWidgets.SequenceFrame): love.Quad prepared viewport per immutable compiled frame
---@param section OptionsRenderer.Section
---@param content OptionsInterface.ContentGeometry
---@param view table<string, unknown>
function OptionsRenderer:_drawFooter(graphics, chrome, quadFor, section, content, view)
  local footer = assert(content.footer, "content carries its footer")
  local actions = assert(section.actions, "the section carries footer actions")
  local focusId = view.focusId
  local footerView = view.footer or {}
  local buttons = {
    { id = "confirm", geometry = footer.confirm, shown = footerView.confirm },
    { id = "quit", geometry = footer.quit, shown = footerView.quit },
  }
  for _, button in ipairs(buttons) do
    local geometry = assert(button.geometry, "footer actions carry their geometry")
    local state = "normal"
    if focusId == button.id then
      state = "focused"
    end
    local age = 0
    local press = view.pressVisual
    if type(press) == "table" and press.kind == "footer" and press.actionId == button.id then
      assert(
        type(press.ageTicks) == "number" and press.ageTicks == press.ageTicks and press.ageTicks >= 0,
        "footer presses carry their source age"
      )
      age = press.ageTicks
      if press.focused then
        state = "pressedFocused"
      else
        state = "pressed"
      end
    end
    OptionsWidgets.drawAction(graphics, chrome, quadFor, actions, geometry.chromeAnchor, state, age)
    local window = assert(geometry.labelWindow, "footer actions carry their label window")
    local centerX = window.x + window.width / 2
    local box = { x = window.x, y = window.y + 6, width = window.width, height = 18 }
    local shown = button.shown or {}
    if shown.sourceLabel ~= nil then
      self:_drawSourceLabel(shown.sourceLabel, box, window, centerX, "center", "footer " .. button.id, "normal")
    else
      local fallback = shown.label
      if fallback == nil then
        fallback = button.id == "confirm" and "CONFIRM" or "QUIT"
      end
      self:_drawPlainLabel(fallback, box, window, centerX, "normal")
    end
  end
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
