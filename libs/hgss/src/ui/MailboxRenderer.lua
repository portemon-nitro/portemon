-- Draws the value snapshot published by the Mailbox child.
---@class MailboxRenderer
---@field graphics table<string, unknown>
---@field images table<string, unknown> resolved visual images by path for draw identity
---@field leases table<string, unknown> installed shared-image borrows by path
---@field manifest table<string, unknown>
---@field _pool table<string, unknown> the borrowed shared image owner behind every visual
---@field _tokens table<string, unknown> enrolled but unacquired borrows by path
---@field released boolean
local MailboxRenderer = {}
MailboxRenderer.__index = MailboxRenderer
local FieldMenuTheme = require("libs.hgss.src.ui.FieldMenuTheme")
local ImageSampling = require("libs.nds.src.love.ImageSampling")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

-- Mail visuals sample point-filtered and clamped, matching the private
-- construction below, so pooled leases draw identically.
local POOLED_SAMPLER = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }

-- At most four ready leases move into the installed group per prepare
-- call, matching the Storage owner's bounded acquisition budget.
local MAX_ACQUISITIONS_PER_UPDATE = 4

-- Source bank-232 message ids behind the Mailbox chrome and prompts.
-- banks[232] is 0-based: [5] READ, [6] ERASE, [7] GIVE, [8] CANCEL.
local ACTION_MESSAGE_IDS = { read = 5, erase = 6, give = 7, cancel = 8 }
local TITLE_MESSAGE_ID = 0
local PAGER_SLASH_MESSAGE_ID = 2
local CANCEL_MESSAGE_ID = 3
local CLOSE_MESSAGE_ID = 4
local AUTHOR_MESSAGE_ID = 9
local ERASED_MESSAGE_ID = 11
local OUTCOME_MESSAGE_IDS = { returned = 13, discarded = 14 }

-- Compiled mailbox.animation.* ids behind the Mailbox sprite roles. This
-- mirrors PcSources.mailboxSpriteRoles locally because runtime packages
-- must not import ROM-derived producer references: the list cursor
-- (sprite 2) is anim 4 on grid input 10 (CLOSE) and anim 5 on every
-- other grid input (MoveCursor :1594-1601, MoveCursorToCloseButton
-- :1353-1356); the previous/next page arrows (sprites 0/1) are anims
-- 0/1; sprite 3 is the static quit/close target at (224,176), anim 2,
-- never re-animated. Anim 3 is set by no code and no template: it stays
-- compiled but undrawn.
local SPRITE_ROLE_ANIMATIONS = {
  cursor = { close = 4, cell = 5 },
  pagePrevious = 0,
  pageNext = 1,
  closeStatic = 2,
}

-- Retail CLOSE grid anchor (input 10), shared by the cursor parked on
-- CLOSE and the static sprite-3 close target. Row cursors (inputs 0-9)
-- anchor on their decoded grid cell centers: columns at px 8/136 with
-- width 14 tiles (112 px) center on x 64/192, rows at px 32k with height
-- 4 tiles (32 px) center on y 16+32k.
local CLOSE_INPUT = 10
local CLOSE_ANCHOR = { x = 224, y = 176 }

-- Decoded nameplate cell geometry (BgCellManager_InitCell(..., 14, 4)
-- tiles at ((input & 1) * 16 + 1, (input >> 1) * 4) tiles): 112x32 px
-- plates in two columns. The 8x2-tile author window sits at tile (4,1)
-- inside the plate, so the author name prints at plate + (32, 8).
local NAMEPLATE_CELL_WIDTH = 112
local NAMEPLATE_CELL_HEIGHT = 32
local NAMEPLATE_COLUMN_X = { [0] = 8, [1] = 136 }
local NAMEPLATE_TEXT_DX = 32
local NAMEPLATE_TEXT_DY = 8

local function nameplateInput(row, page)
  if type(row.input) == "number" then
    return row.input
  end
  return row.slot - (page or 0) * 10
end

local function expandLine(line, manifest)
  local templates = assert(manifest.mail.text.templates, "Mail templates are compiled with the PC manifest")
  local template = assert(templates[line.template], "stored Mail template is present in the compiled manifest")
  assert(type(template) == "table", "Mail template is a lossless token array")
  -- Retail fills only the first nmsg fields (mail_message.c) and leaves
  -- trailing EC_WORD_NULL slots; the stored word array stays length 2
  -- (MAILMSG_FIELDS_MAX) so a 0/1-slot template renders with trailing
  -- false entries instead of one word per substitution.
  local substitutions = 0
  for _, token in ipairs(template) do
    if token.kind == "substitution" then
      substitutions = substitutions + 1
    end
  end
  assert(#line.words == 2, "stored Mail keeps its two EC fields")
  assert(substitutions <= #line.words, "Mail template substitution slots fit the stored EC fields")
  for position = substitutions + 1, #line.words do
    assert(line.words[position] == false, "trailing Mail EC fields stay EC_WORD_NULL")
  end
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
  assert(wordIndex == substitutions, "every template substitution consumes one stored EC field")
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
      and type(pool.release) == "function"
      and type(pool.cancel) == "function",
    "mailbox renderer drives request, poll, acquire, release, and cancel"
  )
  return setmetatable({
    graphics = graphics,
    images = {},
    leases = {},
    manifest = manifest,
    _pool = pool,
    _tokens = {},
    released = false,
  }, MailboxRenderer)
end

-- Expands bank-232 msg 9 ("What would you like to do with {STRVAR}
-- Mail?") with the selected letter author name, mirroring decomp
-- MailboxApp_BufferAuthorName + StringExpandPlaceholders
-- (mailbox_app.c:1485-1492): the field text renderer skips non-glyph
-- tokens, so each substitution token is spliced with the author-name
-- glyphs upstream instead of reaching drawLine unresolved.
---@param self MailboxRenderer
---@param status table<string, unknown>
---@param text table<string, unknown> the borrowed field text renderer
---@return table<string, unknown> tokens
local function authorPromptTokens(self, status, text)
  local bank = assert(self.manifest.text.banks[232], "Mailbox chrome comes from source bank 232")
  local message = assert(bank[AUTHOR_MESSAGE_ID], "the Mailbox author prompt has a compiled source message")
  local name = nil
  for _, row in ipairs(status.rows or {}) do
    if row.selected then
      name = row.letter.author.name
      break
    end
  end
  if name == nil then
    for _, row in ipairs(status.rows or {}) do
      if row.slot == status.selectedSlot then
        name = row.letter.author.name
        break
      end
    end
  end
  assert(type(name) == "string" and name ~= "", "the author prompt names the selected letter author")
  local fontDef = assert(text.fontDef, "mailbox prompts resolve glyphs through the field font")
  local nameCodes = {}
  for char in Utf8Glyphs.iter(name) do
    nameCodes[#nameCodes + 1] = fontDef.charmap[char] or 0
  end
  local tokens = {}
  for _, token in ipairs(message) do
    if token.kind == "substitution" then
      for _, code in ipairs(nameCodes) do
        tokens[#tokens + 1] = { kind = "glyph", code = code }
      end
    else
      tokens[#tokens + 1] = token
    end
  end
  return tokens
end

-- Maps the list selection through the retail cursor grid inputs 0-10:
-- the page-relative slot offset for a selected row, CLOSE_INPUT when no
-- row is selected (empty list or cleared focus). Only CLOSE selects
-- cursor anim 4; every row input selects anim 5.
---@param status table<string, unknown>
---@return integer input
local function selectedGridInput(status)
  local selectedSlot = status.selectedSlot
  if type(selectedSlot) ~= "number" then
    return CLOSE_INPUT
  end
  local page = status.page
  if type(page) ~= "number" then
    page = 0
  end
  local input = selectedSlot - page * 10
  if input < 0 or input > 9 then
    return CLOSE_INPUT
  end
  return input
end

-- Resolves the compiled sprite frames one mailbox list status draws: the
-- cursor flash driven by the selected grid input, the static sprite-3
-- close target, and the page arrows at their page controls. Single-frame
-- looping sequences draw their first frame. Every input anchors on its
-- decoded grid cell (row inputs use anim 5, CLOSE input 10 uses anim 4).
-- Anim 3 is set by no code and no template and stays undrawn, as do
-- sprites behind manifests that predate the compiled mailbox UI
-- animations.
---@alias MailboxSpriteFrame { image: string, width: number, height: number, anchorX: number, anchorY: number, duration: number }
---@alias MailboxSpritePlacement { frame: MailboxSpriteFrame, cx: number, cy: number }
---@param manifest table<string, unknown>
---@param status table<string, unknown>
---@return table<string, unknown> sprites { previous: MailboxSpritePlacement?, next: MailboxSpritePlacement?, close: MailboxSpritePlacement?, cursor: MailboxSpritePlacement? }
local function mailboxSprites(manifest, status)
  local sprites = {}
  if status.mode ~= "mailbox" then
    return sprites
  end
  local ui = manifest.mailbox.ui
  if type(ui) ~= "table" or type(ui.animations) ~= "table" then
    return sprites
  end
  local function frameOf(animId)
    local entry = ui.animations[animId]
    if type(entry) ~= "table" or type(entry.frames) ~= "table" then
      return nil
    end
    return entry.frames[1]
  end
  local presentation = status.presentation
  local controls = type(presentation) == "table" and presentation.pageControls or nil
  local lastPage = status.lastPage or 0
  if lastPage > 0 and controls ~= nil then
    if status.page > 0 then
      local frame = frameOf(SPRITE_ROLE_ANIMATIONS.pagePrevious)
      if frame ~= nil then
        local box = controls.previous
        sprites.previous = { frame = frame, cx = box.x + box.width / 2, cy = box.y + box.height / 2 }
      end
    end
    if status.page < lastPage then
      local frame = frameOf(SPRITE_ROLE_ANIMATIONS.pageNext)
      if frame ~= nil then
        local box = controls.next
        sprites.next = { frame = frame, cx = box.x + box.width / 2, cy = box.y + box.height / 2 }
      end
    end
  end
  local selectedIndex = nil
  for index, row in ipairs(status.rows or {}) do
    if row.selected then
      selectedIndex = index
      break
    end
  end
  local closeFrame = frameOf(SPRITE_ROLE_ANIMATIONS.closeStatic)
  if closeFrame ~= nil then
    -- Sprite 3 is static: it rides the CLOSE anchor every list frame
    -- and is never re-animated. No palette flash is applied: the
    -- renderer owns no flash pattern to reuse.
    sprites.close = { frame = closeFrame, cx = CLOSE_ANCHOR.x, cy = CLOSE_ANCHOR.y }
  end
  local input = status.cursorInput
  if type(input) ~= "number" then
    input = selectedGridInput(status)
  end
  local animId = input == CLOSE_INPUT and SPRITE_ROLE_ANIMATIONS.cursor.close or SPRITE_ROLE_ANIMATIONS.cursor.cell
  local frame = frameOf(animId)
  if frame ~= nil then
    local cells = presentation ~= nil and presentation.cursorGrid ~= nil and presentation.cursorGrid.cells or nil
    local anchor = cells ~= nil and cells[input + 1] or nil
    if anchor ~= nil then
      -- Every grid input parks the cursor flash on its decoded cell.
      sprites.cursor = { frame = frame, cx = anchor.x, cy = anchor.y }
    elseif selectedIndex ~= nil and input ~= CLOSE_INPUT then
      -- Manifests without the compiled grid keep the legacy mark: the
      -- selected-row highlight rect is (8, rowY - 1, 224, 12).
      local rowY = 24 + (selectedIndex - 1) * 13
      sprites.cursor = { frame = frame, cx = 8 + 224 / 2, cy = rowY - 1 + 12 / 2 }
    else
      -- Input 10 (CLOSE) parks the cursor on the CLOSE anchor.
      sprites.cursor = { frame = frame, cx = CLOSE_ANCHOR.x, cy = CLOSE_ANCHOR.y }
    end
  end
  return sprites
end

-- The exact generated paths one status draws: the list background plus
-- the stationery backgrounds behind its visible rows and the compiled
-- sprite frames behind the cursor, the static close target, and the page
-- arrows, or the single stationery background behind a read letter. Confirmation views draw
-- text only and enroll nothing.
---@param manifest table<string, unknown>
---@param status table<string, unknown>
---@return string[] paths
local function requiredPaths(manifest, status)
  local paths, seen = {}, {} ---@type string[], table<string, boolean>
  local function add(path)
    assert(type(path) == "string", "Mail visuals carry compiled paths")
    if not seen[path] then
      seen[path] = true
      paths[#paths + 1] = path
    end
  end
  if status.viewMode == "read" and status.letter ~= nil then
    add(assert(manifest.mail.stationery[status.letter.type]).background.image)
  elseif status.mode == "mailbox" then
    add(assert(manifest.mailbox.background.main, "Mailbox background is compiled").image)
    for _, row in ipairs(status.rows or {}) do
      add(assert(manifest.mail.stationery[row.letter.type]).background.image)
    end
    local sprites = mailboxSprites(manifest, status)
    for _, key in ipairs({ "previous", "next", "close" }) do
      if sprites[key] ~= nil then
        add(assert(sprites[key].frame.image, "Mailbox sprites carry compiled paths"))
      end
    end
    if sprites.cursor ~= nil then
      add(assert(sprites.cursor.frame.image, "Mailbox sprites carry compiled paths"))
    end
  end
  return paths
end

-- Stages one published status outside drawing: enrolls the exact drawn
-- paths once, then polls and borrows at most four ready leases per call.
-- Installed leases accumulate (at most the list background plus twelve
-- stationery backgrounds), so a page flip never retires the group the
-- current draw uses. Returns true once every required lease is
-- installed; returns false while the worker is still resolving, or false
-- with the missing path's cause when a required visual fails.
---@param status table<string, unknown> the published snapshot drawing will use
---@return boolean ready
---@return string? failure the named missing visual when a required path failed
function MailboxRenderer:prepare(status)
  assert(not self.released, "disposed mailbox renderer prepares nothing")
  assert(type(status) == "table", "mailbox preparation requires its published status")
  local pool = assert(self._pool, "mailbox renderer borrows its shared image owner")
  local acquired = 0
  for _, path in ipairs(requiredPaths(self.manifest, status)) do
    if self.leases[path] == nil then
      local token = self._tokens[path]
      if token == nil then
        token = pool:request(path, POOLED_SAMPLER, "demand")
        self._tokens[path] = token
      end
      local state, failure = pool:poll(token)
      if state == "failed" then
        pool:cancel(token)
        self._tokens[path] = nil
        return false, "mailbox image missing at " .. path .. ": " .. tostring(failure)
      end
      assert(state == "pending" or state == "ready", "mailbox preparation reports pending or ready")
      if state == "ready" and acquired < MAX_ACQUISITIONS_PER_UPDATE then
        local ok, lease = pcall(pool.acquire, pool, token)
        if not ok then
          pool:cancel(token)
          self._tokens[path] = nil
          return false, "mailbox image missing at " .. path .. ": " .. tostring(lease)
        end
        -- The drawn lease stays installed, released with the renderer
        -- instead of outliving the mailbox.
        self.leases[path] = lease
        self.images[path] = assert(lease.image, "shared leases carry their resolved image")
        self._tokens[path] = nil
        acquired = acquired + 1
      end
    end
  end
  for _, path in ipairs(requiredPaths(self.manifest, status)) do
    if self.leases[path] == nil then
      return false
    end
  end
  return true
end

function MailboxRenderer:_prepared(visual)
  assert(type(visual) == "table" and type(visual.image) == "string", "Mail visuals carry compiled paths")
  local lease = self.leases[visual.image]
  -- Drawing never enrolls, polls, acquires, or waits: the prepare step
  -- owns every image-owner call, so a missing lease names its path.
  if lease == nil then
    error("mailbox image not prepared at " .. tostring(visual.image), 0)
  end
  return lease
end

-- Draws the Yes / No pair beside a confirmation box, mirroring the
-- Storage message pair: one standard window per choice with the same
-- geometry the interface hit-tests.
local function drawYesNo(window, text, yesNo, fill)
  for _, choice in ipairs({
    { rect = yesNo.yes, label = "YES" },
    { rect = yesNo.no, label = "NO" },
  }) do
    local rect = choice.rect
    window:drawStandardWindow(
      { x = rect.x + 8, y = rect.y + 8, width = rect.width - 16, height = rect.height - 16 },
      fill
    )
    text:drawText(choice.label, rect.x + 12, rect.y + 8)
  end
end

-- Draws one confirmation box with compiled prompt tokens plus the Yes /
-- No pair. Prompts arrive as { bank = n, id = m } so no English string
-- is invented outside the compiled message banks.
---@param self MailboxRenderer
---@param resources table<string, unknown>
---@param prompt table<string, unknown>
---@param withChoices boolean
local function drawConfirm(self, resources, prompt, withChoices)
  local text = assert(resources.textRenderer, "confirmation text borrows the field text renderer")
  local window = assert(resources.windowRenderer, "confirmation borrows the shared field-window renderer")
  local box = assert(resources.presentation.confirmation, "confirmations use the source box geometry")
  window:drawWindow(box, resources.applicationFrameIndex, text:windowBackgroundColor())
  local bank = assert(self.manifest.text.banks[prompt.bank], "Mailbox prompts come from a compiled bank")
  drawMailLine(text, assert(bank[prompt.id], "each Mailbox prompt has a compiled source message"), box.x + 8, box.y + 8)
  if withChoices then
    drawYesNo(
      window,
      text,
      assert(resources.presentation.yesNo, "confirmations hit-test the Yes/No pair"),
      text:windowBackgroundColor()
    )
  end
end

-- Draws the list chrome: source title, page arrows (hidden on a single
-- page, and per side at the page ends), the static sprite-3 close target
-- at (224,176), the n/m pager with the compiled
-- 232:2 slash, and the CANCEL button. Numbers are dynamic data; every
-- word comes from source bank 232.
---@param self MailboxRenderer
---@param resources table<string, unknown>
---@param status table<string, unknown>
local function drawListChrome(self, resources, status)
  local graphics = self.graphics
  local text = assert(resources.textRenderer, "mailbox chrome borrows the field text renderer")
  local bank = assert(self.manifest.text.banks[232], "Mailbox chrome comes from source bank 232")
  text:drawLine(assert(bank[TITLE_MESSAGE_ID], "the Mailbox title has a compiled source label"), 100, 4)
  local lastPage = status.lastPage or 0
  local presentation = assert(status.presentation, "mailbox chrome uses the source geometry")
  local controls = assert(presentation.pageControls, "page arrows use the source hitbox geometry")
  graphics.setColor(1, 1, 1, 1)
  local sprites = mailboxSprites(self.manifest, status)
  if lastPage > 0 then
    if status.page > 0 then
      if sprites.previous ~= nil then
        local sprite = sprites.previous
        local frame = sprite.frame
        ImageSampling.draw(graphics, self:_prepared(frame), nil, sprite.cx + frame.anchorX, sprite.cy + frame.anchorY)
        graphics.setColor(1, 1, 1, 1)
      else
        local previous = controls.previous
        graphics.polygon(
          "fill",
          previous.x + 4,
          previous.y + 16,
          previous.x + 20,
          previous.y + 6,
          previous.x + 20,
          previous.y + 26
        )
      end
    end
    if status.page < lastPage then
      if sprites.next ~= nil then
        local sprite = sprites.next
        local frame = sprite.frame
        ImageSampling.draw(graphics, self:_prepared(frame), nil, sprite.cx + frame.anchorX, sprite.cy + frame.anchorY)
        graphics.setColor(1, 1, 1, 1)
      else
        local nextPage = controls.next
        graphics.polygon(
          "fill",
          nextPage.x + 28,
          nextPage.y + 16,
          nextPage.x + 12,
          nextPage.y + 6,
          nextPage.x + 12,
          nextPage.y + 26
        )
      end
    end
  end
  local left, right = tostring(status.page + 1), tostring(lastPage + 1)
  -- The quit/close flash blinks sprite 3 on alternate ticks before the
  -- state reports closed.
  local flash = status.closeFlash
  local blinkOff = flash ~= nil and flash.ticks % 2 == 1
  if sprites.close ~= nil and not blinkOff then
    local sprite = sprites.close
    local frame = sprite.frame
    graphics.setColor(1, 1, 1, 1)
    ImageSampling.draw(graphics, self:_prepared(frame), nil, sprite.cx + frame.anchorX, sprite.cy + frame.anchorY)
    graphics.setColor(1, 1, 1, 1)
  end
  local pagerX = controls.next.x + controls.next.width + 4
  text:drawText(left, pagerX, 168)
  local slashX = pagerX + text:textWidth(left) + 2
  text:drawLine(assert(bank[PAGER_SLASH_MESSAGE_ID], "the pager slash has a compiled source label"), slashX, 168)
  text:drawText(right, slashX + 8, 168)
  text:drawLine(assert(bank[CANCEL_MESSAGE_ID], "the Mailbox cancel button has a compiled source label"), 200, 168)
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
    ImageSampling.draw(graphics, self:_prepared(visual), nil, visual.anchorX, visual.anchorY)
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
    local bank = assert(self.manifest.text.banks[232], "Mailbox chrome comes from source bank 232")
    -- The read close path blinks the CLOSE region on alternate ticks
    -- while its flash stage runs.
    local flash = status.closeFlash
    if flash == nil or flash.ticks % 2 == 0 then
      text:drawLine(assert(bank[CLOSE_MESSAGE_ID], "the letter close button has a compiled source label"), 200, 168)
    end
  elseif status.mode == "mailbox" then
    local visual = assert(self.manifest.mailbox.background.main, "Mailbox background is compiled")
    graphics.setColor(1, 1, 1, 1)
    ImageSampling.draw(graphics, self:_prepared(visual), nil, visual.anchorX, visual.anchorY)
    local text = assert(resources.textRenderer, "mailbox rows borrow the field text renderer")
    local items = assert(resources.itemIconProvider, "mailbox rows borrow the shared item icon provider")
    for _, row in ipairs(status.rows) do
      -- Two nameplate columns of five: the plate frame is the decoded
      -- 112x32 cell, the author name prints through the 8x2-tile window
      -- at plate + (32, 8), beside the stationery icon.
      local input = nameplateInput(row, status.page)
      local plateX = NAMEPLATE_COLUMN_X[input % 2] or NAMEPLATE_COLUMN_X[0]
      local plateY = math.floor(input / 2) * NAMEPLATE_CELL_HEIGHT
      if row.selected then
        -- The selected row draws through the selected-nameplate path
        -- (MAILBOX_CELL_SELECTED): the whole plate takes the highlight,
        -- never a bare full-width bar.
        local selected = FieldMenuTheme.colors.selected
        graphics.setColor(selected[1], selected[2], selected[3], selected[4])
        graphics.rectangle("fill", plateX, plateY, NAMEPLATE_CELL_WIDTH, NAMEPLATE_CELL_HEIGHT)
        graphics.setColor(1, 1, 1, 1)
      end
      local iconKey = assert(row.itemIconKey, "Mailbox row projects the catalog stationery icon")
      local itemHandle = items:handle()
      if itemHandle ~= nil then
        ImageSampling.draw(graphics, itemHandle, items:quadFor(iconKey), plateX + 8, plateY + NAMEPLATE_TEXT_DY)
      else
        graphics.draw(items:image(), items:quadFor(iconKey), plateX + 8, plateY + NAMEPLATE_TEXT_DY)
      end
      text:drawText(row.letter.author.name, plateX + NAMEPLATE_TEXT_DX, plateY + NAMEPLATE_TEXT_DY)
    end
    -- The compiled list-cursor flash rides the selected row (anim 5)
    -- or parks on CLOSE at (224,176) when no row is selected (anim 4);
    -- the selection rectangle stays as the legibility mark.
    local sprites = mailboxSprites(self.manifest, status)
    if sprites.cursor ~= nil then
      local sprite = sprites.cursor
      local frame = sprite.frame
      graphics.setColor(1, 1, 1, 1)
      ImageSampling.draw(graphics, self:_prepared(frame), nil, sprite.cx + frame.anchorX, sprite.cy + frame.anchorY)
    end
    drawListChrome(self, resources, status)
    local window = assert(resources.windowRenderer, "Mailbox controls borrow the shared field-window renderer")
    local frameIndex = resources.applicationFrameIndex
    if status.phase == "action" then
      local menu = assert(status.presentation.actionMenu)
      -- The msg-9 author question sits above the action menu with the
      -- selected letter author spliced in upstream.
      local promptTokens = authorPromptTokens(self, status, text)
      local promptLines = 1
      for _, token in ipairs(promptTokens) do
        if token.kind == "line_break" then
          promptLines = promptLines + 1
        end
      end
      drawMailLine(text, promptTokens, menu.x, menu.y - promptLines * text.fontDef.lineHeight - 4)
      window:drawWindow(menu, frameIndex, text:windowBackgroundColor())
      local labels = assert(self.manifest.text.banks[232], "Mailbox action labels come from source bank 232")
      for index, action in ipairs(status.menuActions) do
        local messageId =
          assert(ACTION_MESSAGE_IDS[action], "each Mailbox action has a compiled source label: " .. tostring(action))
        local rowY = menu.y + 8 + (index - 1) * menu.rowHeight
        if index == status.actionIndex then
          local selected = FieldMenuTheme.colors.selected
          graphics.setColor(selected[1], selected[2], selected[3], selected[4])
          graphics.rectangle("fill", menu.x + 4, rowY - 2, menu.width - 8, menu.rowHeight)
        end
        text:drawLine(assert(labels[messageId], "each Mailbox action has a compiled source label"), menu.x + 8, rowY)
      end
    elseif status.phase == "confirm" or status.phase == "holdMail" then
      drawConfirm(self, {
        textRenderer = text,
        windowRenderer = window,
        applicationFrameIndex = frameIndex,
        presentation = assert(status.presentation, "confirmations use the source box geometry"),
      }, assert(status.prompt, "destructive Mail operations carry their source prompt"), true)
    elseif status.phase == "erased" then
      drawConfirm(self, {
        textRenderer = text,
        windowRenderer = window,
        applicationFrameIndex = frameIndex,
        presentation = assert(status.presentation, "confirmations use the source box geometry"),
      }, { bank = 232, id = ERASED_MESSAGE_ID }, false)
    elseif status.phase == "result" then
      local outcome = assert(status.outcome, "erase results carry their committed outcome")
      local messageId = assert(
        OUTCOME_MESSAGE_IDS[outcome.outcome],
        "each Mailbox erase outcome has a compiled source message: " .. tostring(outcome.outcome)
      )
      drawConfirm(self, {
        textRenderer = text,
        windowRenderer = window,
        applicationFrameIndex = frameIndex,
        presentation = assert(status.presentation, "confirmations use the source box geometry"),
      }, { bank = 232, id = messageId }, false)
    end
  elseif status.mode == "confirm" then
    drawConfirm(self, {
      textRenderer = assert(resources.textRenderer, "confirmation text borrows the field text renderer"),
      windowRenderer = assert(resources.windowRenderer, "confirmation borrows the shared field-window renderer"),
      applicationFrameIndex = resources.applicationFrameIndex,
      presentation = assert(status.presentation, "confirmations use the source box geometry"),
    }, assert(status.prompt, "destructive Mail operations carry their source prompt"), true)
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
  for _, token in pairs(self._tokens) do
    pool:cancel(token)
  end
  self._tokens = {}
  self.leases = {}
  self.images = {}
end

return MailboxRenderer
