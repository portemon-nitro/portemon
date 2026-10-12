-- The map annotation single-word Easy Chat selector: the source
-- category/word/confirm graph over the eleven ordered word groups. The
-- selector owns transient focus and the exactly-once terminal result; the
-- caller keeps the edit and restores its own session through the existing
-- Map result contract. Word identities are decimal strings from the
-- cumulative group base; the null word is never selectable. Availability is
-- a validated projection the single-word path consults only for removals:
-- the source offers every dictionary word with no save or Dex gating.
-- Pure module: no love, no I/O, no save mutation.

---@class WordEntryScreenState
---@field _operationId string the caller operation behind this edit
---@field _selectedWord string|false the carried preselection, never written back
---@field _catalog WordEntryScreenState.Catalog the eleven ordered source groups
---@field _availability WordEntryScreenState.Availability the validated removal projection
---@field _assets table<string, unknown> the borrowed compiled asset family
---@field _level string the focus level: category, word, or confirm
---@field _group integer the focused source group, zero-based
---@field _index integer the focused word offset within the offered list
---@field _hidden table<string, boolean> the removals behind the offering
---@field _pendingWord string? the word behind the open confirmation
---@field _outcome table<string, unknown>? the latched terminal result
---@field _consumed boolean true once the terminal result is taken
---@field _disposed boolean
local WordEntryScreenState = {}
WordEntryScreenState.__index = WordEntryScreenState

WordEntryScreenState.GROUP_COUNT = 11
WordEntryScreenState.NULL_WORD = 0xFFFF

---@param value unknown
---@return boolean
local function isDecimalKey(value)
  return type(value) == "string" and value:match("^[0-9]+$") ~= nil
end

---@param catalog unknown
---@return WordEntryScreenState.Group[] groups
local function checkCatalog(catalog)
  assert(type(catalog) == "table", "the word selector requires its word catalog")
  local groups = catalog.groups
  assert(
    type(groups) == "table" and #groups == WordEntryScreenState.GROUP_COUNT,
    "the word catalog keeps eleven groups"
  )
  for index, entry in ipairs(groups) do
    assert(type(entry) == "table", "word group " .. index .. " is a record")
    assert(entry.group == index - 1, "word groups keep the source group order")
    assert(
      type(entry.bank) == "number" and entry.bank % 1 == 0 and entry.bank > 0,
      "word group " .. index .. " names its message bank"
    )
    assert(
      type(entry.count) == "number" and entry.count % 1 == 0 and entry.count >= 1,
      "word group " .. index .. " carries its source word count"
    )
    if entry.firstWordId ~= nil then
      local base = 0
      for prior = 1, index - 1 do
        base = base + groups[prior].count
      end
      assert(entry.firstWordId == base, "word group " .. index .. " keeps the cumulative word order")
    end
  end
  return groups
end

---@param availability unknown
---@return table<string, boolean> hidden identities
local function checkAvailability(availability)
  assert(type(availability) == "table", "the word selector requires its availability projection")
  local hidden = {}
  local unavailable = availability.unavailable
  if unavailable ~= nil then
    assert(type(unavailable) == "table", "the availability projection lists removals as a record")
    for key, value in pairs(unavailable) do
      assert(isDecimalKey(key) and value == true, "removals name decimal word identities")
      hidden[key] = true
    end
  end
  return hidden
end

---@param groups WordEntryScreenState.Group[]
---@return integer[] bases
local function groupBases(groups)
  local bases, base = {}, 0
  for index, entry in ipairs(groups) do
    bases[index] = base
    base = base + entry.count
  end
  return bases
end

---@param groups WordEntryScreenState.Group[]
---@param hidden table<string, boolean>
---@param groupIndex integer zero-based
---@return string[] offered decimal identities in bank order
local function offeredWords(groups, hidden, groupIndex)
  assert(groupIndex >= 0 and groupIndex < WordEntryScreenState.GROUP_COUNT, "unknown word group: " .. groupIndex)
  local entry = groups[groupIndex + 1]
  local bases = groupBases(groups)
  local offered = {}
  for offset = 0, entry.count - 1 do
    local key = tostring(bases[groupIndex + 1] + offset)
    if hidden[key] ~= true then
      offered[#offered + 1] = key
    end
  end
  return offered
end

-- Offers the source group in bank order with removals filtered. The
-- availability record carries only removals; save, Dex, and language facts
-- never gate the single-word path, so extra fields are accepted and
-- ignored.
---@param catalog WordEntryScreenState.Catalog
---@param groupIndex integer zero-based source group
---@param availability WordEntryScreenState.Availability?
---@return string[] offered decimal identities in bank order
function WordEntryScreenState.wordsInGroup(catalog, groupIndex, availability)
  local groups = checkCatalog(catalog)
  local hidden = {}
  if availability ~= nil then
    hidden = checkAvailability(availability)
  end
  return offeredWords(groups, hidden, groupIndex)
end

-- Resolves a numeric word identity to its decimal string, or nil for the
-- null word. Unknown identities fail instead of resolving to a neighbour.
---@param wordId integer
---@return string?
function WordEntryScreenState.wordKey(wordId)
  assert(type(wordId) == "number" and wordId % 1 == 0, "word identities are integers")
  if wordId == WordEntryScreenState.NULL_WORD then
    return nil
  end
  if wordId < 0 or wordId > 1494 then
    error("unknown word identity: " .. tostring(wordId), 0)
  end
  return tostring(wordId)
end

---@param catalog WordEntryScreenState.Catalog
---@param selectedWord string|false
---@return integer group, integer index
local function resolvePreselection(catalog, selectedWord)
  if selectedWord == false then
    return 0, 0
  end
  local groups = checkCatalog(catalog)
  local bases = groupBases(groups)
  local id = tonumber(selectedWord)
  for index, entry in ipairs(groups) do
    if id ~= nil and id % 1 == 0 and id >= bases[index] and id < bases[index] + entry.count then
      return index - 1, (id - bases[index]) --[[@as integer]]
    end
  end
  return 0, 0
end

---@class WordEntryScreenState.Group
---@field group integer the zero-based source group
---@field bank integer the message bank behind this group
---@field count integer the source word count
---@field firstWordId integer? the cumulative word base, when pinned

---@class WordEntryScreenState.Catalog
---@field groups WordEntryScreenState.Group[] the eleven ordered source groups

---@class WordEntryScreenState.Availability
---@field unavailable table<string, boolean>? removals by decimal word identity

---@class WordEntryScreenState.Presentation
---@field mode string? the host mode behind this opening
---@field layout string the host layout behind this opening

---@class WordEntryScreenState.Options
---@field operationId string the caller operation behind this edit
---@field selectedWord string|false the carried preselection
---@field wordCatalog WordEntryScreenState.Catalog the eleven ordered source groups
---@field availability WordEntryScreenState.Availability the validated removal projection, never nil
---@field assets table<string, unknown> the borrowed compiled asset family
---@field presentation WordEntryScreenState.Presentation the host plan behind this opening

---@param opts WordEntryScreenState.Options
---@return WordEntryScreenState
function WordEntryScreenState.new(opts)
  assert(type(opts) == "table", "the word selector requires its options")
  assert(
    type(opts.operationId) == "string" and opts.operationId ~= "",
    "the word selector requires its caller operation identity"
  )
  assert(
    opts.selectedWord == false or isDecimalKey(opts.selectedWord),
    "the carried preselection is false or a decimal word identity"
  )
  local groups = checkCatalog(opts.wordCatalog)
  local hidden = checkAvailability(opts.availability)
  assert(type(opts.assets) == "table", "the word selector borrows its compiled asset family")
  assert(type(opts.presentation) == "table", "the word selector requires its host plan")
  local mode = opts.presentation.mode
  assert(mode == nil or mode == "single-word", "only the single-word mode opens the word selector")
  assert(type(opts.presentation.layout) == "string", "the host plan names its layout")
  local group, _ = resolvePreselection(opts.wordCatalog, opts.selectedWord)
  local offered = offeredWords(groups, hidden, group)
  local index = 0
  if opts.selectedWord ~= false then
    for position, key in ipairs(offered) do
      if key == opts.selectedWord then
        index = position - 1
        break
      end
    end
  end
  if #offered == 0 then
    group, index = 0, 0
  end
  return setmetatable({
    _operationId = opts.operationId,
    _selectedWord = opts.selectedWord,
    _catalog = opts.wordCatalog,
    _availability = opts.availability,
    _assets = opts.assets,
    _level = "category",
    _group = group,
    _index = index,
    _hidden = hidden,
    _pendingWord = nil,
    _outcome = nil,
    _consumed = false,
    _disposed = false,
  }, WordEntryScreenState)
end

---@return string[] offered decimal identities behind the current focus
function WordEntryScreenState:_offered()
  return offeredWords(self._catalog.groups, self._hidden, self._group)
end

---@param event table<string, unknown>
function WordEntryScreenState:_navigate(event)
  local direction = event.direction
  if type(direction) ~= "string" then
    return
  end
  if self._level == "category" then
    if direction == "left" then
      self._group = (self._group - 1) % WordEntryScreenState.GROUP_COUNT
    elseif direction == "right" then
      self._group = (self._group + 1) % WordEntryScreenState.GROUP_COUNT
    end
    self._index = 0
    return
  end
  if self._level == "word" then
    local offered = self:_offered()
    if #offered == 0 then
      self._index = 0
      return
    end
    if direction == "up" then
      self._index = (self._index - 1) % #offered
    elseif direction == "down" then
      self._index = (self._index + 1) % #offered
    elseif direction == "left" then
      self._group = (self._group - 1) % WordEntryScreenState.GROUP_COUNT
      self._index = 0
    elseif direction == "right" then
      self._group = (self._group + 1) % WordEntryScreenState.GROUP_COUNT
      self._index = 0
    end
  end
end

---@param event table<string, unknown>
function WordEntryScreenState:_confirm(event)
  if event.type ~= "confirm" then
    return
  end
  if self._level == "category" then
    self._level = "word"
    local offered = self:_offered()
    if #offered == 0 then
      self._index = 0
    elseif self._index >= #offered then
      self._index = 0
    end
  elseif self._level == "word" then
    local offered = self:_offered()
    local key = offered[self._index + 1]
    if key == nil then
      return
    end
    self._pendingWord = key
    self._level = "confirm"
  elseif self._level == "confirm" then
    local key = self._pendingWord
    self._pendingWord = nil
    if key == nil or self._hidden[key] == true then
      self._level = "word"
      return
    end
    self._outcome = { operationId = self._operationId, kind = "selected", wordKey = key }
  end
end

function WordEntryScreenState:_cancel()
  if self._level == "confirm" then
    self._pendingWord = nil
    self._level = "word"
  elseif self._level == "word" then
    self._pendingWord = nil
    self._level = "category"
  elseif self._level == "category" then
    self._outcome = { operationId = self._operationId, kind = "cancelled" }
  end
end

-- One fixed tick over the semantic input vocabulary. After the terminal
-- outcome latches, further input changes nothing; takeResult delivers it
-- exactly once.
---@param uiInput table[]
function WordEntryScreenState:updateFixed(uiInput)
  assert(not self._disposed, "a disposed word selector steps nothing")
  assert(type(uiInput) == "table", "the word selector input must be an event list")
  if self._outcome ~= nil then
    return
  end
  for _, event in ipairs(uiInput) do
    if type(event) == "table" and type(event.type) == "string" then
      if event.type == "navigate" then
        self:_navigate(event)
      elseif event.type == "confirm" then
        self:_confirm(event)
      elseif event.type == "cancel" then
        self:_cancel()
      end
      if self._outcome ~= nil then
        return
      end
    end
  end
end

-- The detached selector view: mode, focus level, group, offered offset,
-- and focused identity. Fresh tables per call; status performs no
-- mutation and carries no terminal outcome.
---@return table<string, unknown>
function WordEntryScreenState:status()
  local offered = self:_offered()
  return {
    mode = "single-word",
    level = self._level,
    group = self._group,
    index = self._index,
    wordKey = offered[self._index + 1],
    selectedWord = self._selectedWord,
    groupCount = WordEntryScreenState.GROUP_COUNT,
    groupSize = #offered,
  }
end

-- Delivers the terminal result exactly once, or nil while the edit is
-- still open. Disposal abandons an untaken result.
---@return table<string, unknown>?
function WordEntryScreenState:takeResult()
  if self._disposed or self._consumed then
    return nil
  end
  local outcome = self._outcome
  if outcome == nil then
    return nil
  end
  self._consumed = true
  if outcome.kind == "selected" then
    return { operationId = outcome.operationId, kind = "selected", wordKey = outcome.wordKey }
  end
  return { operationId = outcome.operationId, kind = "cancelled" }
end

-- Idempotent release of the transient edit state. Borrowed catalog,
-- availability, and asset owners outlive the view.
function WordEntryScreenState:dispose()
  self._outcome = nil
  self._pendingWord = nil
  self._disposed = true
end

return WordEntryScreenState
