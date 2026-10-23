-- Neutral first-ROM import card: no edition, loader, or picker chrome.

local Errors = require("libs.errors.src.Errors")
local RomImporter = require("romdump.src.source.RomImporter")

---@class ImportState neutral first-ROM import card state
---@field importer RomImporter verified-ROM importer owned by the shell
---@field saveDir string?
---@field targetVersion string? expected edition for a targeted rebind, never rendered
---@field pickerAvailable boolean native bridge probed usable at construction
---@field onPick fun()? whole-card activation, present only when available
---@field _received string? sanitized basename latched synchronously on input
---@field _rejected string? concise rejection shown while the importer stays busy
local ImportState = {}
ImportState.__index = ImportState

local CARD_MAX_WIDTH = 380
local CARD_MAX_HEIGHT = 190
local CARD_MARGIN = 16
local LINE_HEIGHT = 20
local RECEIPT_MAX_LENGTH = 48

-- Single centered card geometry shared by drawing and hit-testing, derived
-- from the current drawable size so both stay consistent across resizes.
-- The card stays compact around its copy: one title row, the instruction
-- rows, and reserved status and bar rows, never the oversized half-window
-- frame it used to claim.
---@param width number current drawable width
---@param height number current drawable height
---@param pickerAvailable boolean whether the two picker instruction rows draw
---@return number left
---@return number top
---@return number width
---@return number height
local function cardBounds(width, height, pickerAvailable)
  local cardWidth = math.min(CARD_MAX_WIDTH, math.max(160, width - CARD_MARGIN * 2))
  local rows = 1 + (pickerAvailable and 2 or 1) + 2
  local cardHeight = CARD_MARGIN * 2 + 24 + 8 + rows * LINE_HEIGHT + 12
  cardHeight = math.min(CARD_MAX_HEIGHT, cardHeight)
  cardHeight = math.min(cardHeight, math.max(80, height - CARD_MARGIN * 2))
  return (width - cardWidth) / 2, (height - cardHeight) / 2, cardWidth, cardHeight
end

local function hit(x, y, left, top, width, height)
  return x >= left and x <= left + width and y >= top and y <= top + height
end

---@param name unknown raw dropped or picked file label
---@return string? sanitized basename truncated to one card row, never blank
local function sanitizeName(name)
  if type(name) ~= "string" or name == "" then
    return nil
  end
  local clean = name:gsub("[%c]", "?")
  if #clean > RECEIPT_MAX_LENGTH then
    clean = clean:sub(1, RECEIPT_MAX_LENGTH - 1) .. "…"
  end
  if clean == "" then
    return nil
  end
  return clean
end

---@param importer RomImporter
---@param saveDir string?
---@param options { targetVersion: string?, pickerAvailable: boolean?, onPick: fun()? }?
---@return ImportState
function ImportState.new(importer, saveDir, options)
  options = options or {}
  return setmetatable({
    importer = importer,
    saveDir = saveDir,
    -- Retained only to route file drops into the targeted importer session;
    -- never rendered, so the first card stays edition-neutral.
    targetVersion = options.targetVersion,
    pickerAvailable = options.pickerAvailable == true,
    onPick = options.onPick,
    _received = nil,
    _rejected = nil,
  }, ImportState)
end

function ImportState:update() end

function ImportState:resize() end

function ImportState:dispose() end

-- One receipt seam shared by the drop and picker channels: the visible
-- acknowledgement latches synchronously, before importer validation runs,
-- and never claims the file is verified or accepted.
---@param displayName string sanitized basename shown on the first frame
function ImportState:markReceived(displayName)
  local clean = sanitizeName(displayName)
  if clean == nil then
    return
  end
  self._received = clean
  self._rejected = nil
end

---@return string? the latched receipt basename, or nil when nothing was received
function ImportState:receivedName()
  return self._received
end

---@param importer RomImporter the owned import session
---@return boolean whether an import is already running
local function importerBusy(importer)
  if importer == nil or type(importer.isBusy) ~= "function" then
    return false
  end
  local ok, busy = pcall(importer.isBusy, importer)
  return ok and busy == true
end

---@param failure unknown importer or drop rejection
---@return string concise one-line rejection reason
local function rejectionReason(failure)
  if Errors.is(failure) then
    return tostring(failure.message or failure.code or "rejected")
  end
  return tostring(failure)
end

function ImportState:filedropped(file)
  local name = nil
  if file ~= nil and type(file.getFilename) == "function" then
    local ok, raw = pcall(file.getFilename, file)
    if ok then
      name = sanitizeName(raw)
    end
  end
  -- A drop that lands while an import is running is rejected on the first
  -- frame without touching the running session or resetting its progress.
  if importerBusy(self.importer) then
    self._received = nil
    self._rejected = "an import is already in progress"
    return
  end
  local ok, failure = pcall(self.importer.filedropped, self.importer, file)
  if ok then
    if name ~= nil then
      self:markReceived(name)
    end
  else
    self._received = nil
    self._rejected = rejectionReason(failure)
  end
end

-- The picker is armed only when the platform bridge probed usable at screen
-- construction and no import is already running.
---@return boolean
function ImportState:_pickerArmed()
  if not self.pickerAvailable or self.onPick == nil then
    return false
  end
  if importerBusy(self.importer) then
    return false
  end
  return true
end

function ImportState:_openPicker()
  if self:_pickerArmed() then
    self.onPick()
  end
end

---@param key string
---@param isrepeat boolean?
function ImportState:keypressed(key, _, isrepeat)
  if isrepeat then
    return
  end
  if key == "escape" then
    love.event.quit(0)
  elseif key == "return" or key == "kpenter" or key == "space" then
    self:_openPicker()
  end
end

function ImportState:mousepressed(x, y, button)
  if button ~= 1 then
    return
  end
  self:_pointerpressed(x, y)
end

function ImportState:touchpressed(_, x, y)
  self:_pointerpressed(x, y)
end

function ImportState:_pointerpressed(x, y)
  local width, height = love.graphics.getDimensions()
  local left, top, cardWidth, cardHeight = cardBounds(width, height, self.pickerAvailable)
  if hit(x, y, left, top, cardWidth, cardHeight) then
    self:_openPicker()
  end
end

---@param fraction number? raw importer progress
---@return number clamped determinate fraction
local function clampProgress(fraction)
  if type(fraction) ~= "number" or fraction ~= fraction then
    return 0
  end
  if fraction < 0 then
    return 0
  end
  if fraction > 1 then
    return 1
  end
  return fraction
end

---@return number animated pulse position in seconds
local function pulseNow()
  if love ~= nil and love.timer ~= nil and type(love.timer.getTime) == "function" then
    return love.timer.getTime()
  end
  return 0
end

---@return love.Font? live font when one answers, else nil
local function liveFont()
  if love == nil or love.graphics == nil or type(love.graphics.getFont) ~= "function" then
    return nil
  end
  local ok, font = pcall(love.graphics.getFont)
  if ok and font ~= nil then
    return font
  end
  return nil
end

---@param rows {text:string, y:number}[] rows with y relative to the block top
---@param textWidth number wrap width used by the drawn printf calls
---@return number measured block height from the block top to the lowest wrapped row bottom
local function measuredBlockHeight(rows, textWidth)
  local lineHeight = LINE_HEIGHT
  local font = liveFont()
  if font ~= nil and type(font.getHeight) == "function" then
    local ok, height = pcall(font.getHeight, font)
    if ok and type(height) == "number" and height > 0 then
      lineHeight = height
    end
  end
  local height = 0
  for _, row in ipairs(rows) do
    local lines = 1
    if font ~= nil and type(font.getWrap) == "function" then
      local ok, _, wrapped = pcall(font.getWrap, font, row.text, textWidth)
      if ok and type(wrapped) == "table" then
        lines = math.max(1, #wrapped)
      end
    end
    local bottom = row.y + lines * lineHeight
    if bottom > height then
      height = bottom
    end
  end
  return height
end

function ImportState:draw(statusOverride)
  local lg = love.graphics
  local width, height = lg.getDimensions()
  lg.setColor(0.055, 0.09, 0.13, 1)
  lg.rectangle("fill", 0, 0, width, height)

  local left, top, cardWidth, cardHeight = cardBounds(width, height, self.pickerAvailable)
  lg.setColor(0.10, 0.16, 0.20, 1)
  lg.rectangle("fill", left, top, cardWidth, cardHeight, 12, 12)
  lg.setColor(0.35, 0.55, 0.58, 1)
  lg.rectangle("line", left, top, cardWidth, cardHeight, 12, 12)

  local textX, textWidth = left + 16, cardWidth - 32
  local status = self.importer:status()
  local s = RomImporter.STATES
  local busy = importerBusy(self.importer)

  local titleText = "Import a Pokémon ROM"
  local instructionTexts = {}
  if self.pickerAvailable then
    instructionTexts[1] = "Drop a supported .nds or .zip file anywhere on this card."
    instructionTexts[2] = "Click the card or press Return to browse for a file."
  else
    instructionTexts[1] = "Drop a supported .nds or .zip file onto this window to import it."
  end

  local errorText = nil
  if status.state == s.ERROR then
    errorText = "Import failed [" .. tostring(status.errorCode or "ERROR") .. "]: " .. Errors.format(status.error)
  end

  local rejectionText = nil
  local receiptText = nil
  if errorText == nil then
    if self._rejected ~= nil and busy then
      rejectionText = "Drop rejected (" .. self._rejected .. ")."
    elseif self._received ~= nil then
      receiptText = "File received " .. self._received
    end
  end

  local isArtworkStage = status.state == s.COMPLETE
    and type(statusOverride) == "table"
    and statusOverride.stage == "artwork"
  local artworkFailure = isArtworkStage and statusOverride.failure ~= nil
  -- The card knows no worker internals: the waiting owner declares whether
  -- the shown failure can run again in this epoch. Only an explicit true
  -- keeps the retry row; anything else is Escape-only.
  local artworkRetryable = artworkFailure and statusOverride.retryable == true
  local artworkDetail = nil
  if artworkFailure then
    local detail = tostring(rejectionReason(statusOverride.failure))
    if #detail > 80 then
      detail = detail:sub(1, 79) .. "…"
    end
    artworkDetail = detail
  end

  -- Measure the visible rows with the live font wrap metrics, then start
  -- the group in the middle of the usable area above the reserved band.
  local rows = {}
  local measureY = 0
  rows[#rows + 1] = { text = titleText, y = measureY }
  measureY = measureY + 24
  for _, instructionText in ipairs(instructionTexts) do
    rows[#rows + 1] = { text = instructionText, y = measureY }
    measureY = measureY + LINE_HEIGHT
  end
  measureY = measureY + 8
  if errorText ~= nil then
    rows[#rows + 1] = { text = errorText, y = measureY }
  else
    if rejectionText ~= nil then
      rows[#rows + 1] = { text = rejectionText, y = measureY }
      measureY = measureY + LINE_HEIGHT
    elseif receiptText ~= nil then
      rows[#rows + 1] = { text = receiptText, y = measureY }
      measureY = measureY + LINE_HEIGHT
    end
    if status.state == s.READING then
      rows[#rows + 1] = { text = "Checking ROM", y = measureY }
    elseif status.state == s.VERIFYING or status.state == s.REGISTERING then
      rows[#rows + 1] = { text = "Verifying ROM", y = measureY }
      measureY = measureY + LINE_HEIGHT
      rows[#rows + 1] = { text = "Verifying cartridge identity…", y = measureY }
    elseif isArtworkStage then
      if artworkFailure then
        rows[#rows + 1] = { text = "Walking sprites hit an error.", y = measureY }
        measureY = measureY + LINE_HEIGHT
        rows[#rows + 1] = { text = artworkDetail, y = measureY }
        measureY = measureY + LINE_HEIGHT
        if artworkRetryable then
          rows[#rows + 1] = { text = "Press R to retry, or Esc to reselect.", y = measureY }
        else
          rows[#rows + 1] = { text = "Press Esc to reselect.", y = measureY }
        end
      else
        rows[#rows + 1] = { text = "Preparing walking sprites", y = measureY }
      end
    elseif status.state == s.COMPLETE then
      rows[#rows + 1] = { text = "ROM accepted.", y = measureY }
    end
  end

  local contentTop = top + CARD_MARGIN
  local usableBottom = top + cardHeight - 30
  if errorText ~= nil or artworkFailure then
    usableBottom = top + cardHeight - CARD_MARGIN
  end
  local blockHeight = measuredBlockHeight(rows, textWidth)
  local shift = 0
  if usableBottom - contentTop > blockHeight then
    shift = (usableBottom - contentTop - blockHeight) / 2
  end
  local y = contentTop + shift
  lg.setColor(0.94, 0.94, 0.9, 1)
  lg.printf(titleText, textX, y, textWidth, "center")
  y = y + 24
  lg.setColor(0.7, 0.78, 0.8, 1)
  for _, instructionText in ipairs(instructionTexts) do
    lg.printf(instructionText, textX, y, textWidth, "center")
    y = y + LINE_HEIGHT
  end
  y = y + 8

  if errorText ~= nil then
    lg.setColor(1, 0.58, 0.53, 1)
    lg.printf(errorText, textX, y, textWidth, "center")
    return
  end

  -- A busy-drop rejection stays visible only while the running import still
  -- owns the session; its progress bar below is untouched.
  if rejectionText ~= nil then
    lg.setColor(1, 0.58, 0.53, 1)
    lg.printf(rejectionText, textX, y, textWidth, "center")
    y = y + LINE_HEIGHT
  elseif receiptText ~= nil then
    lg.setColor(0.94, 0.94, 0.9, 1)
    lg.printf(receiptText, textX, y, textWidth, "center")
    y = y + LINE_HEIGHT
  end

  -- Progress is a real determinate bar for importer verification within its
  -- reported stage, then an honest indeterminate wait while the selected
  -- walking pair is prepared. The two phases never merge into one faked
  -- completion fraction, and internal registration wording never surfaces.
  local trackX, trackWidth = left + 24, cardWidth - 48
  local trackY, trackHeight = top + cardHeight - 30, 8
  if status.state == s.READING then
    lg.setColor(0.8, 0.9, 0.78, 1)
    lg.printf("Checking ROM", textX, y, textWidth, "center")
    self:_drawBar(trackX, trackY, trackWidth, trackHeight, clampProgress(status.progress), false)
  elseif status.state == s.VERIFYING or status.state == s.REGISTERING then
    lg.setColor(0.8, 0.9, 0.78, 1)
    lg.printf("Verifying ROM", textX, y, textWidth, "center")
    y = y + LINE_HEIGHT
    lg.setColor(0.7, 0.78, 0.8, 1)
    lg.printf("Verifying cartridge identity…", textX, y, textWidth, "center")
    self:_drawBar(trackX, trackY, trackWidth, trackHeight, clampProgress(status.progress), false)
  elseif status.state == s.COMPLETE and type(statusOverride) == "table" and statusOverride.stage == "artwork" then
    self:_drawArtworkWait(
      textX,
      y,
      textWidth,
      trackX,
      trackY,
      trackWidth,
      trackHeight,
      statusOverride.failure,
      statusOverride.retryable
    )
  elseif status.state == s.COMPLETE then
    lg.setColor(0.8, 0.9, 0.78, 1)
    lg.printf("ROM accepted.", textX, y, textWidth, "center")
  end
end

-- The verified-source wait names its pending artwork step and animates an
-- indeterminate bar: no completion fraction is shown before the selected
-- pair is genuinely resident.
---@param textX number card text origin x
---@param y number current card text row y
---@param textWidth number card text width
---@param trackX number progress track origin x
---@param trackY number progress track origin y
---@param trackWidth number progress track width
---@param trackHeight number progress track height
---@param failure unknown? selected-pair failure surfaced with its truthful remedy
---@param retryable boolean? true only when the failure can run again in this epoch
function ImportState:_drawArtworkWait(textX, y, textWidth, trackX, trackY, trackWidth, trackHeight, failure, retryable)
  local lg = love.graphics
  if failure ~= nil then
    lg.setColor(1, 0.67, 0.53, 1)
    lg.printf("Walking sprites hit an error.", textX, y, textWidth, "center")
    y = y + LINE_HEIGHT
    lg.setColor(0.7, 0.78, 0.8, 1)
    local detail = tostring(rejectionReason(failure))
    if #detail > 80 then
      detail = detail:sub(1, 79) .. "…"
    end
    lg.printf(detail, textX, y, textWidth, "center")
    y = y + LINE_HEIGHT
    if retryable == true then
      lg.printf("Press R to retry, or Esc to reselect.", textX, y, textWidth, "center")
    else
      lg.printf("Press Esc to reselect.", textX, y, textWidth, "center")
    end
    return
  end
  lg.setColor(0.8, 0.9, 0.78, 1)
  lg.printf("Preparing walking sprites", textX, y, textWidth, "center")
  self:_drawBar(trackX, trackY, trackWidth, trackHeight, 0, true)
end

---@param trackX number
---@param trackY number
---@param trackWidth number
---@param trackHeight number
---@param fraction number determinate fill, ignored when indeterminate
---@param indeterminate boolean pulse a block instead of filling a fraction
function ImportState:_drawBar(trackX, trackY, trackWidth, trackHeight, fraction, indeterminate)
  local lg = love.graphics
  lg.setColor(0.22, 0.30, 0.32, 1)
  lg.rectangle("fill", trackX, trackY, trackWidth, trackHeight)
  lg.setColor(0.55, 0.85, 0.70, 1)
  if indeterminate then
    local blockWidth = math.min(56, trackWidth)
    local span = math.max(1, trackWidth - blockWidth)
    local phase = (pulseNow() * 1.2) % 2
    local t = phase < 1 and phase or 2 - phase
    lg.rectangle("fill", trackX + t * span, trackY, blockWidth, trackHeight)
  else
    lg.rectangle("fill", trackX, trackY, math.max(1, trackWidth * fraction), trackHeight)
  end
end

return ImportState
