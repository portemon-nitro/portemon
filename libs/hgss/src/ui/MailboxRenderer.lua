-- Draws the value snapshot published by the Mailbox child.
local MailboxRenderer = {}
MailboxRenderer.__index = MailboxRenderer
local FieldMenuTheme = require("libs.hgss.src.ui.FieldMenuTheme")

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
  local cacheFs = assert(opts.cacheFs, "mailbox renderer borrows the version cache")
  local manifest = assert(opts.manifest, "mailbox renderer borrows the PC manifest")
  local graphics = assert(opts.graphics, "mailbox renderer borrows the graphics namespace")
  return setmetatable(
    { graphics = graphics, cacheFs = cacheFs, images = {}, manifest = manifest, released = false },
    MailboxRenderer
  )
end

function MailboxRenderer:_image(visual)
  assert(type(visual) == "table" and type(visual.image) == "string", "Mail visuals carry compiled paths")
  local image = self.images[visual.image]
  if image == nil then
    local bytes = assert(self.cacheFs:read(visual.image), "compiled Mail visual exists: " .. visual.image)
    image = self.graphics.newImage(love.filesystem.newFileData(bytes, visual.image))
    image:setFilter("nearest", "nearest")
    self.images[visual.image] = image
  end
  return image
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
    graphics.draw(self:_image(visual), visual.anchorX, visual.anchorY)
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
        local iconImage = provider:image(icon.iconKey)
        local quad = provider:quadFor(icon.iconKey, 1)
        graphics.setColor(1, 1, 1, 1)
        graphics.draw(iconImage, quad, location.x, location.y)
      end
    end
  elseif status.mode == "mailbox" then
    local visual = assert(self.manifest.mailbox.background.main, "Mailbox background is compiled")
    graphics.setColor(1, 1, 1, 1)
    graphics.draw(self:_image(visual), visual.anchorX, visual.anchorY)
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
      graphics.draw(items:image(), items:quadFor(iconKey), 8, y)
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
  for _, image in pairs(self.images) do
    image:release()
  end
  self.images = {}
end

return MailboxRenderer
