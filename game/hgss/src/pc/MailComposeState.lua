-- Owns free word composition for the hold-mail follow-up (the UseMail sub-app).
-- Retail erases first and then asks 232:12; answering Yes opens party
-- selection and composes a new letter on the erased stationery. This child
-- assembles the composed letter: the stationery type, author, and line
-- templates are prefilled from the retained erased letter while every word
-- slot starts empty. Submitted letters satisfy the same template/word
-- contract the Mailbox renderer expands.
local Mail = require("libs.mons.src.gen4.Mail")
local MailboxInterface = require("game.hgss.src.pc.MailboxInterface")

local MailComposeState = {}
MailComposeState.__index = MailComposeState

-- Easy Chat bank ranges mirror romdump PcSources.mailText.wordBanks
-- (first word id and word count per bank, in source order) without
-- importing ROM selection: the manifest carries the compiled dictionary,
-- this table only groups its keys for browsing.
local WORD_BANK_RANGES = {
  { firstWordId = 0, wordCount = 496 },
  { firstWordId = 496, wordCount = 468 },
  { firstWordId = 964, wordCount = 18 },
  { firstWordId = 982, wordCount = 124 },
  { firstWordId = 1106, wordCount = 38 },
  { firstWordId = 1144, wordCount = 38 },
  { firstWordId = 1182, wordCount = 107 },
  { firstWordId = 1289, wordCount = 104 },
  { firstWordId = 1393, wordCount = 47 },
  { firstWordId = 1440, wordCount = 32 },
  { firstWordId = 1472, wordCount = 23 },
}

-- The composed letter shares the Mailbox read-view anchors; both records
-- carry the same numbers, so the shared table is reused rather than copied.
MailComposeState.defaults = {
  letter = MailboxInterface.defaults.letter,
  browser = { x = 16, y = 136, width = 224, height = 48, rowHeight = 16 },
}

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, child in pairs(value) do
    out[key] = copy(child)
  end
  return out
end

local function cue(self, sequence)
  local audio = self.audio
  if type(audio) == "table" and type(audio.play) == "function" then
    audio.play(sequence)
  end
end

-- Mirrors MailboxRenderer.expandLine so only submittable assemblies reach
-- the custody intent: the template must be compiled, the first nmsg word
-- fields fill the substitution slots, trailing fields stay EC_WORD_NULL,
-- and every filled word is a compiled dictionary entry.
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

local function checkAssembly(lines, manifest)
  local templates = manifest.mail.text.templates
  local wordDictionary = manifest.mail.wordDictionary
  if type(templates) ~= "table" or type(wordDictionary) ~= "table" then
    return false, "invalid_letter"
  end
  for _, line in ipairs(lines) do
    if line ~= false then
      local template = templates[line.template]
      if type(template) ~= "table" then
        return false, "invalid_letter"
      end
      local substitutions = 0
      for _, token in ipairs(template) do
        if token.kind == "substitution" then
          substitutions = substitutions + 1
        end
      end
      -- The stored word array stays length 2 (MAILMSG_FIELDS_MAX): the
      -- first nmsg fields fill the substitution slots while trailing
      -- fields stay EC_WORD_NULL.
      if #line.words ~= 2 or substitutions > #line.words then
        return false, "invalid_letter"
      end
      for position = 1, substitutions do
        local wordKey = line.words[position]
        if wordKey == false then
          return false, "incomplete"
        end
        if wordDictionary[wordKey] == nil then
          return false, "invalid_letter"
        end
      end
      for position = substitutions + 1, #line.words do
        if line.words[position] ~= false then
          return false, "invalid_letter"
        end
      end
    end
  end
  return true
end

function MailComposeState.new(opts)
  assert(type(opts) == "table", "mail composition requires options")
  local manifest = assert(opts.manifest, "mail composition needs its manifest")
  local stationeryType = assert(opts.stationeryType, "mail composition carries its stationery type")
  assert(manifest.mail.stationery[stationeryType], "mail composition uses compiled stationery")
  local author = assert(opts.author, "mail composition carries its retained author")
  assert(type(author) == "table" and type(author.name) == "string", "mail composition carries a named author")
  local claimed = assert(opts.templates, "mail composition carries its retained line templates")
  assert(#claimed == 3, "mail composition assembles exactly three lines")
  local templates = assert(manifest.mail.text.templates, "Mail templates are compiled with the PC manifest")
  local lines = {}
  for index = 1, 3 do
    local key = claimed[index]
    if key == false then
      lines[index] = false
    else
      assert(type(key) == "string", "each composed line carries its template key")
      assert(templates[key], "composed Mail templates are present in the compiled manifest")
      lines[index] = { template = key, words = { false, false } }
    end
  end
  local dictionary = assert(manifest.mail.wordDictionary, "Mail words are compiled with the PC manifest")
  local banks = {}
  for bankIndex, range in ipairs(WORD_BANK_RANGES) do
    local keys = {}
    for wordId = range.firstWordId, range.firstWordId + range.wordCount - 1 do
      local wordKey = tostring(wordId)
      if dictionary[wordKey] ~= nil then
        keys[#keys + 1] = wordKey
      end
    end
    if #keys > 0 then
      table.sort(keys, function(left, right)
        return tonumber(left) < tonumber(right)
      end)
      banks[#banks + 1] = { bank = bankIndex - 1, keys = keys }
    end
  end
  assert(#banks > 0, "mail composition needs at least one compiled word bank")
  assert(type(opts.measureDisplay) == "function", "mail composition needs its display facts")
  local state = setmetatable({
    manifest = manifest,
    stationeryType = stationeryType,
    author = copy(author),
    lines = lines,
    banks = banks,
    measureDisplay = opts.measureDisplay,
    audio = opts.audio,
    slots = {},
    cursor = 1,
    phase = "edit",
    bankIndex = 1,
    wordIndex = 1,
    error = nil,
    closed = false,
    closedKind = nil,
    result = nil,
    resultTaken = false,
    disposed = false,
  }, MailComposeState)
  for lineIndex, line in ipairs(lines) do
    if line ~= false then
      -- Only the template substitution slots are fillable: a 0/1-slot
      -- retail template leaves its trailing EC fields EC_WORD_NULL.
      local template = assert(templates[line.template], "composed Mail templates are present in the compiled manifest")
      local substitutions = 0
      for _, token in ipairs(template) do
        if token.kind == "substitution" then
          substitutions = substitutions + 1
        end
      end
      assert(substitutions <= #line.words, "composed Mail substitution slots fit the stored EC fields")
      for position = 1, substitutions do
        state.slots[#state.slots + 1] = { line = lineIndex, position = position }
      end
    end
  end
  state.cursor = 1
  return state
end

local function plan(self)
  local display = self.measureDisplay()
  return {
    width = display.width,
    height = display.height,
    topology = display.topology,
    pixelRatio = display.pixelRatio,
    letter = MailComposeState.defaults.letter,
    browser = MailComposeState.defaults.browser,
  }
end

-- Assigns one compiled word to one template slot. Structural mistakes are
-- programmer errors; unknown words cannot reach the custody intent.
function MailComposeState:setWord(lineIndex, position, wordKey)
  assert(not self.disposed, "disposed mail composition assigns nothing")
  local line = assert(self.lines[lineIndex], "mail composition assigns a composed line")
  assert(line ~= false, "mail composition assigns a templated line")
  assert(position >= 1 and position <= #line.words, "mail composition assigns a stored EC field")
  assert(type(wordKey) == "string", "mail composition assigns a dictionary word key")
  assert(self.manifest.mail.wordDictionary[wordKey], "composed Mail words are present in the compiled dictionary")
  line.words[position] = wordKey
  self.error = nil
end

-- Builds the submittable letter without closing: every slot must hold a
-- compiled word and the assembly must satisfy the renderer contract.
function MailComposeState:letter()
  local lines = {}
  for index, line in ipairs(self.lines) do
    if line == false then
      lines[index] = false
    else
      lines[index] = { template = line.template, words = { line.words[1], line.words[2] } }
    end
  end
  return {
    schema = Mail.SCHEMA,
    type = self.stationeryType,
    author = copy(self.author),
    icons = { false, false, false },
    lines = lines,
  }
end

function MailComposeState:validate()
  local ok, reason = checkAssembly(self:letter().lines, self.manifest)
  if not ok then
    return false, reason
  end
  if pcall(Mail.validate, self:letter()) then
    return true
  end
  return false, "invalid_letter"
end

-- Attempts submission: incomplete or invalid assemblies stay open with
-- their reason published on status so the browser keeps custody.
function MailComposeState:submit()
  assert(not self.disposed, "disposed mail composition submits nothing")
  if self.closed then
    return false, "closed"
  end
  local ok, reason = self:validate()
  if not ok then
    self.error = reason
    return false, reason
  end
  self.result = { kind = "submitted", letter = self:letter() }
  self.closed, self.closedKind = true, "submitted"
  self.error = nil
  cue(self, "SEQ_SE_DP_DECIDE")
  return true
end

function MailComposeState:updateFixed(events)
  assert(not self.disposed, "disposed mail composition cannot update")
  assert(type(events) == "table", "mail composition updates from an event list")
  if self.closed then
    return
  end
  for _, event in ipairs(events) do
    if event.type == "cancel" then
      if self.phase == "bank" then
        self.phase = "edit"
      elseif self.phase == "word" then
        self.phase = "bank"
      else
        self.closed, self.closedKind = true, "cancelled"
        self.result = { kind = "cancelled" }
        cue(self, "SEQ_SE_DP_DECIDE")
      end
    elseif event.type == "navigate" then
      assert(
        event.direction == "up" or event.direction == "down" or event.direction == "left" or event.direction == "right",
        "mail composition uses the four controller directions"
      )
      local delta = (event.direction == "down" or event.direction == "right") and 1 or -1
      if self.phase == "edit" then
        local stops = #self.slots + 1
        self.cursor = math.max(1, math.min(stops, self.cursor + delta))
        cue(self, "SEQ_SE_DP_SELECT")
      elseif self.phase == "bank" then
        self.bankIndex = math.max(1, math.min(#self.banks, self.bankIndex + delta))
        cue(self, "SEQ_SE_DP_SELECT")
      else
        local keys = self.banks[self.bankIndex].keys
        self.wordIndex = math.max(1, math.min(#keys, self.wordIndex + delta))
        cue(self, "SEQ_SE_DP_SELECT")
      end
    elseif event.type == "confirm" then
      if self.phase == "edit" then
        if self.cursor > #self.slots then
          self:submit()
        else
          self.phase, self.bankIndex = "bank", 1
          cue(self, "SEQ_SE_DP_DECIDE")
        end
      elseif self.phase == "bank" then
        self.phase, self.wordIndex = "word", 1
        cue(self, "SEQ_SE_DP_DECIDE")
      else
        local slot = assert(self.slots[self.cursor], "mail composition fills a composed slot")
        self:setWord(slot.line, slot.position, self.banks[self.bankIndex].keys[self.wordIndex])
        self.phase = "edit"
        local nextCursor = nil
        for index, candidate in ipairs(self.slots) do
          if self.lines[candidate.line].words[candidate.position] == false then
            nextCursor = index
            break
          end
        end
        self.cursor = nextCursor or (#self.slots + 1)
        cue(self, "SEQ_SE_DP_DECIDE")
      end
    end
  end
end

function MailComposeState:status()
  local lines = {}
  for index, line in ipairs(self.lines) do
    if line == false then
      lines[index] = false
    else
      lines[index] = { template = line.template, words = { line.words[1], line.words[2] } }
    end
  end
  local banks = {}
  for _, bank in ipairs(self.banks) do
    banks[#banks + 1] = { bank = bank.bank, count = #bank.keys }
  end
  local words = nil
  if self.phase == "word" then
    words = copy(self.banks[self.bankIndex].keys)
  end
  local ready = self:validate()
  return {
    phase = self.phase,
    stationeryType = self.stationeryType,
    author = copy(self.author),
    lines = lines,
    slots = copy(self.slots),
    cursor = self.cursor,
    submitStop = #self.slots + 1,
    banks = banks,
    bankIndex = self.bankIndex,
    words = words,
    wordIndex = self.wordIndex,
    submitReady = ready,
    error = self.error,
    closed = self.closed,
    presentation = plan(self),
  }
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

-- Draws through the shared text/window renderers only: the compose child
-- owns no mailbox visuals and enrolls no image leases.
function MailComposeState:draw(resources, status)
  assert(not self.disposed, "disposed mail composition draws nothing")
  assert(type(resources) == "table", "mail composition borrows field presentation resources")
  local value = status or self:status()
  local text = assert(resources.textRenderer, "mail composition borrows the field text renderer")
  local window = assert(resources.windowRenderer, "mail composition borrows the shared field-window renderer")
  local geometry = assert(value.presentation.letter, "composition text uses the source geometry")
  local frameIndex = resources.applicationFrameIndex
  local fill = text:windowBackgroundColor()
  window:drawWindow({ x = 8, y = 0, width = 240, height = 128 }, frameIndex, fill)
  text:drawText(value.author.name, geometry.author.x, geometry.author.y)
  for index, line in ipairs(value.lines) do
    if line ~= false then
      local placement = assert(geometry.lines[index], "each Mail line uses its source window anchor")
      drawMailLine(text, expandLine(line, self.manifest), placement.x, placement.y)
    end
  end
  local browser = assert(value.presentation.browser, "composition browsing uses the source box geometry")
  window:drawWindow(browser, frameIndex, fill)
  if value.phase == "bank" or value.phase == "word" then
    local entries = {}
    if value.phase == "bank" then
      for index, bank in ipairs(value.banks) do
        entries[index] = tostring(bank.bank)
      end
    else
      entries = assert(value.words, "word browsing lists its bank entries")
    end
    local focused = value.phase == "bank" and value.bankIndex or value.wordIndex
    -- The browser box fits only part of a long bank/word list, so the
    -- focused entry keeps its containing page in view: page bounds derive
    -- from the current box geometry and focus each frame and no page
    -- offset is stored. Selection still uses the absolute entry index.
    local visibleCount = math.max(1, math.floor((browser.height - 8) / browser.rowHeight))
    local firstVisible = math.floor((focused - 1) / visibleCount) * visibleCount + 1
    local lastVisible = math.min(#entries, firstVisible + visibleCount - 1)
    for index = firstVisible, lastVisible do
      local entry = entries[index]
      local rowY = browser.y + 8 + (index - firstVisible) * browser.rowHeight
      if index == focused then
        text:drawText(">", browser.x + 4, rowY)
      end
      if value.phase == "word" then
        local tokens = assert(self.manifest.mail.wordDictionary[entry], "browsed words stay compiled")
        text:drawLine(tokens, browser.x + 12, rowY)
      else
        text:drawText(entry, browser.x + 12, rowY)
      end
    end
  end
end

function MailComposeState:takeResult()
  if not self.closed or self.resultTaken then
    return nil
  end
  self.resultTaken = true
  return self.result
end

function MailComposeState:cancel()
  if not self.closed then
    self.closed, self.closedKind = true, "cancelled"
    self.result = { kind = "cancelled" }
  end
end

function MailComposeState:dispose()
  self.disposed = true
end

function MailComposeState:isActive()
  return not self.closed
end

return MailComposeState
