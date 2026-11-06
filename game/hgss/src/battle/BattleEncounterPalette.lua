-- Evaluates the native HGSS encounter palette setup and scheduled fades.

---@class BattleEncounterPalette.Source
---@field restoreType "wild"|"trainer"|"ordinary-doubles"|"special-doubles" accepted native restore class for OBJ backups
---@field mainBg integer[] main BG opaque RGB555 words before setup, 256 entries
---@field mainObj table<integer, integer> defined main OBJ opaque RGB555 words, keyed by one-based slot within 224 entries
---@field mainObjPostFill table<integer, integer> defined MAIN_OBJ RGB555 words loaded after setup fill, keyed by one-based slot within 224 entries
---@field subBgOpaque integer[] sub BG opaque RGB555 words, 256 entries
---@field subObjOpaque table<integer, integer> defined sub OBJ opaque RGB555 words, keyed by one-based palette slot
---@field initialDisplayed { subBg: integer[], subObj: integer[] } transparent-side initial palette words
---@field fill integer RGB555 destination for encounter fades

---@class BattleEncounterPalette.Options
---@field battleType "wild"|"trainer"|"ordinary-doubles"|"special-doubles" source branch selecting the OBJ restore span
---@field source BattleEncounterPalette.Source staged native palette words

---@class BattleEncounterPalette.Snapshot
---@field mainBg integer[] displayed main BG RGB555 words, 256 entries
---@field mainObj table<integer, integer> defined displayed main OBJ RGB555 words, keyed by one-based slot within 224 entries
---@field subBg integer[] displayed sub BG RGB555 words, 256 entries
---@field subObj table<integer, integer> defined displayed sub OBJ RGB555 words, keyed by one-based palette slot
---@field version integer identity changed only when displayed colors change
---@field lateBgMask integer? late main BG bank selector, present once armed

---@class BattleEncounterPalette
---@field _battleType "wild"|"trainer"|"ordinary-doubles"|"special-doubles"
---@field _fill integer
---@field _opaqueMainBg integer[] post-setup main BG opaque words
---@field _opaqueMainObj table<integer, integer> post-setup defined main OBJ opaque words
---@field _initialOpaqueMainBg integer[] initial post-setup main BG opaque words
---@field _initialOpaqueMainObj table<integer, integer> initial post-setup defined main OBJ opaque words
---@field _opaqueSubBg integer[] original sub BG opaque words
---@field _opaqueSubObj table<integer, integer> defined original sub OBJ opaque words
---@field _displayedInitialMainBg integer[] initial displayed main BG words
---@field _displayedInitialMainObj table<integer, integer> initial displayed defined main OBJ words
---@field _displayedInitialSubBg integer[] initial displayed sub BG words
---@field _displayedInitialSubObj integer[] initial displayed sub OBJ words
---@field _backupMainBg integer[] pre-fill main BG words
---@field _backupMainObj table<integer, integer> pre-fill defined main OBJ words
---@field _frame integer last accepted source-task frame
---@field _displayed table<integer, table<integer, integer>> cached displayed planes in mainBg, mainObj, subBg, subObj order
---@field _restoreCount integer native OBJ backup span
---@field _restored boolean true once the frame-28 opaque backup is installed
---@field _lateFrame integer? frame that armed the late fade
---@field _version integer displayed palette identity
local M = {}
M.__index = M

M.MAIN_BG_MASK = 0xF3FF
M.MAIN_OBJ_MASK = 0x3FFF
M.LATE_BG_MASK = 0x0C00

local BLACK = 0
local GRAY_UNIT = 1 + 1 * 32 + 1 * 1024
local FADE_START = 10
local RESTORE_FRAME = 28
local LATE_FADE_START = 50
local FADE_RANGE = 16
local MAIN_BG_RESTORE_COUNT = 112
local MAIN_BG_FILL_FIRST_END = 111
local MAIN_BG_FILL_SECOND_START = 192
local MAIN_OBJ_FILL_END = 222
local BUFFER_LENGTHS = { mainBg = 256, mainObj = 224, subBg = 256, subObj = 256 }
local PLANE_ORDER = { "mainBg", "mainObj", "subBg", "subObj" }
local OBJECT_RESTORE_COUNTS = { wild = 64, trainer = 80, ["ordinary-doubles"] = 112, ["special-doubles"] = 80 }

---@param word integer RGB555 word under test
---@return integer r five-bit red component
---@return integer g five-bit green component
---@return integer b five-bit blue component
local function splitWord(word)
  return word % 32, math.floor(word / 32) % 32, math.floor(word / 1024) % 32
end

---@param source integer source channel
---@param target integer target channel
---@param coefficient integer blend units from 0 to 16
---@return integer blended channel
local function blendComponent(source, target, coefficient)
  return source + math.floor(((target - source) * coefficient) / 16)
end

---@param source integer source RGB555 word
---@param target integer target RGB555 word
---@param coefficient integer blend units from 0 to 16
---@return integer blended RGB555 word
local function blendWord(source, target, coefficient)
  local sr, sg, sb = splitWord(source)
  local tr, tg, tb = splitWord(target)
  return blendComponent(sr, tr, coefficient)
    + blendComponent(sg, tg, coefficient) * 32
    + blendComponent(sb, tb, coefficient) * 1024
end

---@param buffer unknown source palette words under staged ownership
---@param plane "mainBg"|"mainObj"|"subBg"|"subObj" native plane name
---@return integer[] detached RGB555 words
local function checkBuffer(buffer, plane)
  local count = BUFFER_LENGTHS[plane]
  assert(type(buffer) == "table" and #buffer == count, plane .. " stages " .. count .. " source colors")
  local out = {}
  for index = 1, count do
    out[index] = buffer[index]
  end
  return out
end

---@param buffer unknown sparse source palette words under staged ownership
---@param plane "mainObj"|"subObj" sparse native plane name
---@return table<integer, integer> detached defined RGB555 words
local function checkDefinedBuffer(buffer, plane)
  assert(type(buffer) == "table", plane .. " stages defined source colors")
  local out = {}
  for index, word in pairs(buffer) do
    assert(
      type(index) == "number" and index % 1 == 0 and index >= 1 and index <= BUFFER_LENGTHS[plane],
      plane .. " stages an in-range source slot"
    )
    out[index] = word
  end
  return out
end

---@param words table<integer, integer> defined opaque words to fill
---@param fill integer target RGB555 word
---@param first integer first one-based slot to replace
---@param last integer last one-based slot to replace
local function fillDefinedWords(words, fill, first, last)
  for index in pairs(words) do
    if index >= first and index <= last then
      words[index] = fill
    end
  end
end

---@param words integer[] words to copy
---@return integer[] detached copy
local function copyWords(words)
  local out = {}
  for index = 1, #words do
    out[index] = words[index]
  end
  return out
end

---@param words table<integer, integer> sparse defined words to copy
---@return table<integer, integer> detached copy preserving absent slots
local function copyDefinedWords(words)
  local out = {}
  for index, word in pairs(words) do
    out[index] = word
  end
  return out
end

---@param opaque integer[] opaque source words
---@param fill integer target RGB555 word
---@param first integer first one-based palette word to replace
---@param last integer last one-based palette word to replace
local function fillWords(opaque, fill, first, last)
  for index = first, last do
    opaque[index] = fill
  end
end

---@param words table<integer, integer> pre-fill defined words
---@param count integer number of words retained before fill
---@param destination table<integer, integer> post-fill opaque words
local function restoreWords(words, count, destination)
  for index = 1, count do
    destination[index] = words[index]
  end
end

---@param buffer table<integer, integer> RGB555 words
---@param index integer zero-based source palette index
---@param plane string plane identity for diagnostics
---@param length integer native palette slot count
---@return integer one-based index
local function checkedIndex(buffer, index, plane, length)
  assert(
    type(index) == "number" and index % 1 == 0 and index >= 0 and index < length,
    plane .. " palette sample names an in-range source index"
  )
  assert(buffer[index + 1] ~= nil, plane .. " palette source index " .. index .. " is undefined")
  return index + 1
end

---@param index integer one-based buffer index
---@return integer zero-based bank containing the index
local function bankOf(index)
  return math.floor((index - 1) / 16)
end

---@param mask integer sixteen-bank selector
---@param bank integer zero-based palette bank
---@return boolean true when selected
local function maskSelects(mask, bank)
  return math.floor(mask / (2 ^ bank)) % 2 == 1
end

---@param frame integer absolute source frame
---@return integer fade coefficient
local function mainCoefficient(frame)
  if frame < FADE_START then
    return 0
  end
  return math.min(FADE_RANGE, 2 * (frame - FADE_START))
end

---@param frame integer absolute source frame
---@return integer restore coefficient
local function restoreCoefficient(frame)
  return math.max(0, FADE_RANGE - 2 * (frame - RESTORE_FRAME))
end

---@param step integer gray ramp step
---@return integer RGB555 gray word
local function grayWord(step)
  return math.floor((31 * step) / FADE_RANGE) * GRAY_UNIT
end

---@param self BattleEncounterPalette
---@param frame integer absolute source frame
---@return integer[] displayed main BG words
local function displayedMainBg(self, frame)
  local base = self._opaqueMainBg
  local out = copyWords(self._displayedInitialMainBg)
  local coefficient = frame < RESTORE_FRAME and mainCoefficient(frame) or restoreCoefficient(frame)
  for index = 1, #base do
    if maskSelects(M.MAIN_BG_MASK, bankOf(index)) then
      out[index] = blendWord(base[index], self._fill, coefficient)
    end
  end
  if self._lateFrame ~= nil and frame >= self._lateFrame then
    local lateCoefficient = math.max(0, FADE_RANGE - 2 * (frame - self._lateFrame))
    for index = 1, #base do
      if maskSelects(M.LATE_BG_MASK, bankOf(index)) then
        out[index] = blendWord(base[index], BLACK, lateCoefficient)
      end
    end
  end
  return out
end

---@param self BattleEncounterPalette
---@param frame integer absolute source frame
---@return table<integer, integer> displayed defined main OBJ words
local function displayedMainObj(self, frame)
  local out = copyDefinedWords(self._displayedInitialMainObj)
  local coefficient = frame < RESTORE_FRAME and mainCoefficient(frame) or restoreCoefficient(frame)
  for index, word in pairs(self._opaqueMainObj) do
    if maskSelects(M.MAIN_OBJ_MASK, bankOf(index)) then
      out[index] = blendWord(word, self._fill, coefficient)
    end
  end
  return out
end

---@param self BattleEncounterPalette
---@param frame integer absolute source frame
---@return integer[] displayed sub BG words
local function displayedSubBg(self, frame)
  if frame < FADE_START then
    return copyWords(self._displayedInitialSubBg)
  end
  if frame < RESTORE_FRAME then
    local gray = grayWord(math.min(FADE_RANGE, frame - FADE_START + 1))
    local out = {}
    for index = 1, #self._opaqueSubBg do
      out[index] = gray
    end
    return out
  end
  local coefficient = restoreCoefficient(frame)
  local out = {}
  for index, word in ipairs(self._opaqueSubBg) do
    out[index] = blendWord(word, self._fill, coefficient)
  end
  return out
end

---@param self BattleEncounterPalette
---@param frame integer absolute source frame
---@return integer[] displayed sub OBJ words
local function displayedSubObj(self, frame)
  if frame < RESTORE_FRAME then
    return copyDefinedWords(self._displayedInitialSubObj)
  end
  local coefficient = restoreCoefficient(frame)
  local out = {}
  for index, word in pairs(self._opaqueSubObj) do
    out[index] = blendWord(word, self._fill, coefficient)
  end
  return out
end

---@param self BattleEncounterPalette
---@param frame integer absolute source frame
---@return table<integer, table<integer, integer>> displayed defined words for every native plane
local function recomputeDisplayed(self, frame)
  return {
    displayedMainBg(self, frame),
    displayedMainObj(self, frame),
    displayedSubBg(self, frame),
    displayedSubObj(self, frame),
  }
end

---@param before table<integer, table<integer, integer>> prior displayed planes
---@param after table<integer, table<integer, integer>> next displayed planes
---@return boolean true when at least one displayed palette word changed
local function planesChanged(before, after)
  for planeIndex = 1, #before do
    local oldPlane, newPlane = before[planeIndex], after[planeIndex]
    local length = BUFFER_LENGTHS[PLANE_ORDER[planeIndex]]
    for index = 1, length do
      if oldPlane[index] ~= newPlane[index] then
        return true
      end
    end
  end
  return false
end

---@param self BattleEncounterPalette
---@param fresh table<integer, table<integer, integer>> freshly computed displayed planes
local function publishDisplayed(self, fresh)
  if planesChanged(self._displayed, fresh) then
    self._version = self._version + 1
  end
  self._displayed = fresh
end

---@param opts BattleEncounterPalette.Options constructor source facts
---@return BattleEncounterPalette per-battle source palette evaluator
function M.new(opts)
  assert(type(opts) == "table", "the encounter palette needs its source facts")
  assert(type(opts.source) == "table", "the encounter stages its source palette buffers")
  local restoreCount = OBJECT_RESTORE_COUNTS[opts.battleType]
  assert(restoreCount ~= nil, "the encounter palette branches on its source battle type")
  local source = opts.source
  local backupMainBg = checkBuffer(source.mainBg, "mainBg")
  local backupMainObj = checkDefinedBuffer(source.mainObj, "mainObj")
  local postFillMainObj = checkDefinedBuffer(source.mainObjPostFill, "mainObj")
  for index in pairs(postFillMainObj) do
    assert(
      backupMainObj[index] == nil,
      "mainObj post-fill source slot " .. (index - 1) .. " overlaps a pre-fill source slot"
    )
    assert(
      index > restoreCount,
      "mainObj post-fill source slot " .. (index - 1) .. " lies inside the native restore span"
    )
  end
  local opaqueMainBg = copyWords(backupMainBg)
  local opaqueMainObj = copyDefinedWords(backupMainObj)
  local opaqueSubBg = checkBuffer(source.subBgOpaque, "subBg")
  local opaqueSubObj = checkDefinedBuffer(source.subObjOpaque, "subObj")
  assert(type(source.initialDisplayed) == "table", "the encounter stages its initial displayed lower palettes")
  local initialDisplayedSubBg = checkBuffer(source.initialDisplayed.subBg, "subBg")
  local initialDisplayedSubObj = checkDefinedBuffer(source.initialDisplayed.subObj, "subObj")
  for index in pairs(opaqueSubObj) do
    assert(
      initialDisplayedSubObj[index] ~= nil,
      "subObj initial displayed palette defines opaque source slot " .. (index - 1)
    )
  end
  for index in pairs(initialDisplayedSubObj) do
    assert(opaqueSubObj[index] ~= nil, "subObj initial displayed palette has no opaque source slot " .. (index - 1))
  end
  assert(
    type(source.fill) == "number" and source.fill % 1 == 0 and source.fill >= 0 and source.fill <= 0x7FFF,
    "the encounter stages an RGB555 background fill color"
  )
  local fill = source.fill

  fillWords(opaqueMainBg, fill, 1, MAIN_BG_FILL_FIRST_END + 1)
  fillWords(opaqueMainBg, fill, MAIN_BG_FILL_SECOND_START + 1, 256)
  fillDefinedWords(opaqueMainObj, fill, 1, MAIN_OBJ_FILL_END + 1)
  for index, word in pairs(postFillMainObj) do
    opaqueMainObj[index] = word
  end
  local displayedInitialMainBg = copyWords(opaqueMainBg)
  local displayedInitialMainObj = copyDefinedWords(opaqueMainObj)
  local initialOpaqueMainBg = copyWords(opaqueMainBg)
  local initialOpaqueMainObj = copyDefinedWords(opaqueMainObj)
  fillWords(displayedInitialMainBg, BLACK, 161, 192)

  local self = setmetatable({
    _battleType = opts.battleType,
    _fill = fill,
    _opaqueMainBg = opaqueMainBg,
    _opaqueMainObj = opaqueMainObj,
    _initialOpaqueMainBg = initialOpaqueMainBg,
    _initialOpaqueMainObj = initialOpaqueMainObj,
    _opaqueSubBg = opaqueSubBg,
    _opaqueSubObj = opaqueSubObj,
    _displayedInitialMainBg = displayedInitialMainBg,
    _displayedInitialMainObj = displayedInitialMainObj,
    _displayedInitialSubBg = initialDisplayedSubBg,
    _displayedInitialSubObj = initialDisplayedSubObj,
    _backupMainBg = backupMainBg,
    _backupMainObj = backupMainObj,
    _restoreCount = restoreCount,
    _frame = 0,
    _lateFrame = nil,
    _version = 0,
  }, M)
  self._displayed = recomputeDisplayed(self, 0)
  return self
end

---@param self BattleEncounterPalette
---@param frame integer absolute source-task frame advancing the evaluator
function M:tick(frame)
  assert(type(frame) == "number" and frame % 1 == 0 and frame >= 1, "the encounter palette advances on source frames")
  if frame == self._frame then
    return
  end
  self._frame = frame
  if frame >= RESTORE_FRAME and not self._restored then
    restoreWords(self._backupMainBg, MAIN_BG_RESTORE_COUNT, self._opaqueMainBg)
    restoreWords(self._backupMainObj, self._restoreCount, self._opaqueMainObj)
    self._restored = true
  end
  publishDisplayed(self, recomputeDisplayed(self, frame))
end

---@param self BattleEncounterPalette
function M:beginLateFade()
  assert(self._frame >= LATE_FADE_START, "the late encounter fade starts at source frame 50 or later")
  if self._lateFrame ~= nil then
    return
  end
  self._lateFrame = self._frame
  publishDisplayed(self, recomputeDisplayed(self, self._frame))
end

---@param self BattleEncounterPalette
function M:reset()
  self._opaqueMainBg = copyWords(self._initialOpaqueMainBg)
  self._opaqueMainObj = copyDefinedWords(self._initialOpaqueMainObj)
  self._frame = 0
  self._lateFrame = nil
  self._restored = false
  publishDisplayed(self, recomputeDisplayed(self, 0))
end

---@param self BattleEncounterPalette
---@return BattleEncounterPalette.Snapshot detached per-plane source palette state
function M:snapshot()
  local displayed = self._displayed
  local state = {
    mainBg = copyWords(displayed[1]),
    mainObj = copyDefinedWords(displayed[2]),
    subBg = copyWords(displayed[3]),
    subObj = copyDefinedWords(displayed[4]),
    version = self._version,
  }
  if self._lateFrame ~= nil then
    state.lateBgMask = M.LATE_BG_MASK
  end
  return state
end

---@param self BattleEncounterPalette
---@param plane "mainBg"|"mainObj"|"subBg"|"subObj" native plane
---@param index integer zero-based source palette index
---@return integer displayed RGB555 word
function M:colorAt(plane, index)
  if plane == "mainBg" then
    return self._displayed[1][checkedIndex(self._opaqueMainBg, index, plane, BUFFER_LENGTHS.mainBg)]
  elseif plane == "mainObj" then
    return self._displayed[2][checkedIndex(self._opaqueMainObj, index, plane, BUFFER_LENGTHS.mainObj)]
  elseif plane == "subBg" then
    return self._displayed[3][checkedIndex(self._opaqueSubBg, index, plane, BUFFER_LENGTHS.subBg)]
  end
  assert(plane == "subObj", "palette samples name their native plane")
  return self._displayed[4][checkedIndex(self._opaqueSubObj, index, plane, BUFFER_LENGTHS.subObj)]
end

return M
