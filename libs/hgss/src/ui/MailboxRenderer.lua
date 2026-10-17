-- Draws the value snapshot published by the Mailbox child.
---@class MailboxRenderer
---@field graphics table<string, unknown>
---@field images table<string, unknown> resolved visual images by path for draw identity
---@field leases table<string, unknown> installed shared-image borrows by path
---@field manifest table<string, unknown>
---@field _pool table<string, unknown> the borrowed shared image owner behind every visual
---@field released boolean
local MailboxRenderer = {}
MailboxRenderer.__index = MailboxRenderer
local FieldMenuTheme = require("libs.hgss.src.ui.FieldMenuTheme")
local ImageSampling = require("libs.nds.src.love.ImageSampling")

-- Mail visuals sample point-filtered and clamped, matching the private
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
      error("mailbox image missing at " .. path .. ": " .. tostring(failure), 0)
    end
    assert(status == "pending", "mailbox preparation reports pending or ready")
    stalled = stalled + 1
    if stalled > 10000 then
      error("mailbox image stalled at " .. path, 0)
    end
    local timer = love and love.timer
    if timer ~= nil and timer.sleep ~= nil then
      timer.sleep(0.001)
    end
  end
end

local function expandLine(line, manifest)
  local templates = assert(manifest.mail.text.templates, "Mail templates are compiled with the PC manifest")
  local template = assert(templates[line.template], "stored Mail template is present in the compiled manifest")
  assert(type(template) == "table", "Mail template is a lossless token array")
  local substitutions = 0
  for _, token in ipairs(template) do
    if token.kind == "substitution" then
      substitutions = substitutions + 1
    end
  end
  assert(substitutions == #line.words, "Mail template substitution slots match the stored EC fields")
  local tokens, wordIndex = {}, 0
  for _, token in ipairs(template) do
    if token.kind == "substitution" then
      wordIndex = wordIndex + 1
      local wordKey = line.words[wordIndex]
      if wordKey ~= false then
        local word =
          assert(manifest.mail.wordDictionary[wordKey], "stored EC word is present in the compiled dictionary")
        for _, wordToken in ipairs(word) do
          tokens[#tokens + 1] = wordToken
        end
      end
    else
      tokens[#tokens + 1] = token
    end
  end
  assert(wordIndex == #line.words, "every stored EC field has one template substitution")
  return tokens
end

local function drawMailLine(text, tokens, x, y)
  local row, lineHeight = {}, text.fontDef.lineHeight
  for _, token in ipairs(tokens) do
    if token.kind == "line_break" then
      text:drawLine(row, x, y)
      row = {}
      y = y + lineHeight
    else
      row[#row + 1] = token
    end
  end
  text:drawLine(row, x, y)
end

function MailboxRenderer.new(opts)
  assert(type(opts) == "table", "mailbox renderer requires options")
  local manifest = assert(opts.manifest, "mailbox renderer borrows the PC manifest")
  local graphics = assert(opts.graphics, "mailbox renderer borrows the graphics namespace")
  local pool = assert(opts.imagePool, "mailbox renderer borrows its shared image owner")
  assert(
    type(pool.request) == "function"
      and type(pool.poll) == "function"
      and type(pool.acquire) == "function"
      and type(pool.release) == "function",
    "mailbox renderer drives request, poll, acquire, and release"
  )
  return setmetatable({
    graphics = graphics,
    images = {},
    leases = {},
    manifest = manifest,
    _pool = pool,
    released = false,
  }, MailboxRenderer)
end

function MailboxRenderer:_image(visual)
  assert(type(visual) == "table" and type(visual.image) == "string", "Mail visuals carry compiled paths")
  local lease = self.leases[visual.image]
  if lease == nil then
    -- Mail state visuals borrow the shared owner as installed leases; the
    -- drawn image stays the resolved lease image, released with the
    -- renderer instead of outliving the mailbox.
    lease = acquirePinned(self._pool, visual.image)
    self.leases[visual.image] = lease
    self.images[visual.image] = assert(lease.image, "shared leases carry their resolved image")
  end
  return lease
end

function MailboxRenderer:draw(status, resources)
  assert(not self.released, "disposed mailbox renderer cannot draw")
  assert(type(status) == "table", "mailbox renderer needs a status snapshot")
  assert(type(resources) == "table", "mailbox drawing borrows field presentation resources")
  local graphics = self.graphics
  if status.viewMode == "read" and status.letter ~= nil then
    local letter = status.letter
    local visual = assert(self.manifest.mail.stationery[letter.type]).background
    local geometry = assert(status.presentation.letter, "letter text uses source overlay geometry")
    graphics.setColor(1, 1, 1, 1)
    ImageSampling.draw(graphics, self:_image(visual), nil, visual.anchorX, visual.anchorY)
    local text = assert(resources.textRenderer, "mail drawing borrows the field text renderer")
    text:drawText(letter.author.name, geometry.author.x, geometry.author.y)
    for index, line in ipairs(letter.lines) do
      if line ~= false then
        local placement = assert(geometry.lines[index], "each Mail line uses its source window anchor")
        drawMailLine(text, expandLine(line, self.manifest), placement.x, placement.y)
      end
    end
    for index, location in ipairs(self.manifest.mail.geometry.iconLocations) do
      local icon = status.icons and status.icons[index]
      if icon ~= nil and icon.iconKey ~= nil then
        local provider = assert(resources.monIconProvider, "letter icons borrow the shared mon icon provider")
        graphics.setColor(1, 1, 1, 1)
        ImageSampling.draw(
          graphics,
          provider:handleFor(icon.iconKey),
          provider:quadFor(icon.iconKey, 1),
          location.x,
          location.y
        )
      end
    end
  elseif status.mode == "mailbox" then
    local visual = assert(self.manifest.mailbox.background.main, "Mailbox background is compiled")
    graphics.setColor(1, 1, 1, 1)
    ImageSampling.draw(graphics, self:_image(visual), nil, visual.anchorX, visual.anchorY)
    local text = assert(resources.textRenderer, "mailbox rows borrow the field text renderer")
    local items = assert(resources.itemIconProvider, "mailbox rows borrow the shared item icon provider")
    for index, row in ipairs(status.rows) do
      local y = 24 + (index - 1) * 13
      if row.selected then
        local selected = FieldMenuTheme.colors.selected
        graphics.setColor(selected[1], selected[2], selected[3], selected[4])
        graphics.rectangle("fill", 8, y - 1, 224, 12)
      end
      local iconKey = assert(row.itemIconKey, "Mailbox row projects the catalog stationery icon")
      local itemHandle = items:handle()
      if itemHandle ~= nil then
        ImageSampling.draw(graphics, itemHandle, items:quadFor(iconKey), 8, y)
      else
        graphics.draw(items:image(), items:quadFor(iconKey), 8, y)
      end
      text:drawText(row.letter.author.name, 28, y)
    end
    text:drawText(tostring(status.page + 1), 12, 164)
    local window = assert(resources.windowRenderer, "Mailbox controls borrow the shared field-window renderer")
    local frameIndex = resources.applicationFrameIndex
    if status.phase == "action" then
      local menu = assert(status.presentation.actionMenu)
      window:drawWindow(menu, frameIndex, text:windowBackgroundColor())
      local labels = assert(self.manifest.text.banks[232], "Mailbox action labels come from source bank 232")
      for index = 1, #status.menuActions do
        local rowY = menu.y + 8 + (index - 1) * menu.rowHeight
        if index == status.actionIndex then
          local selected = FieldMenuTheme.colors.selected
          graphics.setColor(selected[1], selected[2], selected[3], selected[4])
          graphics.rectangle("fill", menu.x + 4, rowY - 2, menu.width - 8, menu.rowHeight)
        end
        text:drawLine(assert(labels[index + 3], "each Mailbox action has a compiled source label"), menu.x + 8, rowY)
      end
    elseif status.phase == "confirm" then
      local box = assert(status.presentation.confirmation)
      window:drawWindow(box, frameIndex, text:windowBackgroundColor())
      text:drawText(
        assert(status.prompt, "destructive Mail operations carry their source prompt"),
        box.x + 8,
        box.y + 8
      )
    end
  elseif status.mode == "confirm" then
    local text = assert(resources.textRenderer, "confirmation text borrows the field text renderer")
    local window = assert(resources.windowRenderer, "confirmation borrows the shared field-window renderer")
    local box = assert(status.presentation.confirmation)
    window:drawWindow(box, resources.applicationFrameIndex, text:windowBackgroundColor())
    text:drawText(status.prompt, box.x + 8, box.y + 8)
  end
end

function MailboxRenderer:release()
  if self.released then
    return
  end
  self.released = true
  local pool = assert(self._pool, "mailbox renderer borrows its shared image owner")
  self._pool = nil
  for _, lease in pairs(self.leases) do
    pool:release(lease)
  end
  self.leases = {}
  self.images = {}
end

return MailboxRenderer
