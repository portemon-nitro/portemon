-- Per-battle source encounter palette state: the four native RGB555
-- palette buffers (main background, main object, sub background, sub
-- object) with their immutable staged backups, the background fill applied
-- at battle setup, masked two-unit fade progression, the lower-screen gray
-- ramp, and the late main background bank operation. Ticks name absolute
-- source-task frames; snapshots detach every buffer so readers never
-- advance or alias the evaluator.

---@class BattleEncounterPalette.Source
---@field mainBg integer[] staged main background RGB555 words, 256 entries
---@field mainObj integer[] staged main object RGB555 words, 256 entries
---@field subBg integer[] staged sub background RGB555 words, 256 entries
---@field subObj integer[] staged sub object RGB555 words, 256 entries
---@field fill integer background fill RGB555 word applied at battle setup

---@class BattleEncounterPalette.Options
---@field battleType "wild"|"trainer"|"ordinary-doubles"|"special-doubles" source branch selecting the object restore span
---@field source BattleEncounterPalette.Source staged source buffers and fill

---@class BattleEncounterPalette.Snapshot
---@field mainBg integer[] displayed main background RGB555 words, 256 entries
---@field mainObj integer[] displayed main object RGB555 words, 256 entries
---@field subBg integer[] displayed sub background RGB555 words, 256 entries
---@field subObj integer[] displayed sub object RGB555 words, 256 entries
---@field version integer snapshot identity, bumps on every state change
---@field lateBgMask integer? late main background bank selector, present once armed

---@class BattleEncounterPalette
---@field _battleType "wild"|"trainer"|"ordinary-doubles"|"special-doubles" source branch behind the object restore span
---@field _fill integer background fill RGB555 word behind setup and the main fades
---@field _backupMainBg integer[] staged main background words before the fill
---@field _backupMainObj integer[] staged main object words before the fill
---@field _backupSubBg integer[] staged sub background words behind the reveal
---@field _backupSubObj integer[] staged sub object words behind the reveal
---@field _initMainBg integer[] main background words after the setup fill
---@field _initMainObj integer[] main object words after the setup fill
---@field _restoredMainBg integer[] main background words after the frame-28 restore
---@field _restoredMainObj integer[] main object words after the frame-28 restore
---@field _objectBase integer[] staged base word per sixteen-color object bank
---@field _frame integer last accepted absolute source-task frame, 0 before the first tick
---@field _late boolean true once the late background bank operation is armed
---@field _version integer snapshot identity behind dirty uploads
local M = {}
M.__index = M

M.MAIN_BG_MASK = 0xF3FF
M.MAIN_OBJ_MASK = 0x3FFF
M.LATE_BG_MASK = 0x0C00

local WHITE = 31 + 31 * 32 + 31 * 1024
local BLACK = 0
local GRAY_UNIT = 1 + 1 * 32 + 1 * 1024
local FADE_START = 10
local RESTORE_FRAME = 28
local FADE_RANGE = 16
local BANK_COUNT = 16
local BANK_SIZE = 16
local ENTRY_COUNT = 256
local MAIN_BG_FILL_FIRST_END = 111
local MAIN_BG_FILL_SECOND_START = 192
local MAIN_OBJ_FILL_END = 222
local MAIN_BG_RESTORE_COUNT = 112

local OBJECT_RESTORE_COUNTS = {
  wild = 64,
  trainer = 80,
  ["ordinary-doubles"] = 112,
  ["special-doubles"] = 80,
}

---@param word integer RGB555 word under test
---@return integer r five-bit red component
---@return integer g five-bit green component
---@return integer b five-bit blue component
local function splitWord(word)
  local r = word % 32
  local g = math.floor(word / 32) % 32
  local b = math.floor(word / 1024) % 32
  return r, g, b
end

---@param source integer five-bit source component
---@param target integer five-bit target component
---@param coefficient integer blend units from 0 to 16
---@return integer blended five-bit component
local function blendComponent(source, target, coefficient)
  return source + math.floor(((target - source) * coefficient) / 16)
end

---@param source integer RGB555 source word
---@param target integer RGB555 target word
---@param coefficient integer blend units from 0 to 16
---@return integer blended RGB555 word
local function blendWord(source, target, coefficient)
  local sourceR, sourceG, sourceB = splitWord(source)
  local targetR, targetG, targetB = splitWord(target)
  return blendComponent(sourceR, targetR, coefficient)
    + blendComponent(sourceG, targetG, coefficient) * 32
    + blendComponent(sourceB, targetB, coefficient) * 1024
end

---@param index integer zero-based source color index
---@return integer containing sixteen-color bank
local function bankOf(index)
  return math.floor(index / BANK_SIZE)
end

---@param mask integer sixteen-bit bank selector
---@param bank integer bank under test
---@return boolean true while the mask selects the bank
local function maskSelects(mask, bank)
  return math.floor(mask / (2 ^ bank)) % 2 == 1
end

---@param step integer gray ramp step from 0 to 16
---@return integer RGB555 gray word for the lower background buffer
local function grayWord(step)
  return math.floor((31 * step) / FADE_RANGE) * GRAY_UNIT
end

---@param buffer table<integer, integer> value under test
---@param name string buffer identity behind the diagnostic
---@return integer[] detached 256-entry RGB555 buffer
local function checkBuffer(buffer, name)
  assert(type(buffer) == "table", name .. " stages 256 source colors")
  assert(#buffer == ENTRY_COUNT, name .. " stages 256 source colors")
  local out = {}
  for index = 1, ENTRY_COUNT do
    local word = buffer[index]
    assert(type(word) == "number", name .. " stages RGB555 words")
    out[index] = word
  end
  return out
end

---@param fill unknown background fill word under test
---@return integer background fill RGB555 word
local function checkFill(fill)
  assert(type(fill) == "number", "the encounter stages its background fill color")
  return fill
end

---@param words integer[] staged words to copy
---@return integer[] detached copy of the staged words
local function copyWords(words)
  local out = {}
  for index = 1, ENTRY_COUNT do
    out[index] = words[index]
  end
  return out
end

---@param opts BattleEncounterPalette.Options? construction facts under test
---@return BattleEncounterPalette per-battle source palette evaluator
function M.new(opts)
  assert(type(opts) == "table", "the encounter palette needs its source facts")
  local restoreCount = OBJECT_RESTORE_COUNTS[opts.battleType]
  assert(restoreCount ~= nil, "the encounter palette branches on its source battle type")
  assert(type(opts.source) == "table", "the encounter stages its source palette buffers")
  local backupMainBg = checkBuffer(opts.source.mainBg, "the staged main background")
  local backupMainObj = checkBuffer(opts.source.mainObj, "the staged main object")
  local backupSubBg = checkBuffer(opts.source.subBg, "the staged sub background")
  local backupSubObj = checkBuffer(opts.source.subObj, "the staged sub object")
  local fill = checkFill(opts.source.fill)
  local initMainBg = {}
  for index = 0, ENTRY_COUNT - 1 do
    if index <= MAIN_BG_FILL_FIRST_END or index >= MAIN_BG_FILL_SECOND_START then
      initMainBg[index + 1] = fill
    else
      initMainBg[index + 1] = backupMainBg[index + 1]
    end
  end
  local initMainObj = {}
  for index = 0, ENTRY_COUNT - 1 do
    if index <= MAIN_OBJ_FILL_END then
      initMainObj[index + 1] = fill
    else
      initMainObj[index + 1] = backupMainObj[index + 1]
    end
  end
  local restoredMainBg = copyWords(initMainBg)
  for index = 0, MAIN_BG_RESTORE_COUNT - 1 do
    restoredMainBg[index + 1] = backupMainBg[index + 1]
  end
  local restoredMainObj = copyWords(initMainObj)
  for index = 0, restoreCount - 1 do
    restoredMainObj[index + 1] = backupMainObj[index + 1]
  end
  local objectBase = {}
  for bank = 0, BANK_COUNT - 1 do
    objectBase[bank + 1] = backupMainObj[bank * BANK_SIZE + 1]
  end
  return setmetatable({
    _battleType = opts.battleType,
    _fill = fill,
    _backupMainBg = backupMainBg,
    _backupMainObj = backupMainObj,
    _backupSubBg = backupSubBg,
    _backupSubObj = backupSubObj,
    _initMainBg = initMainBg,
    _initMainObj = initMainObj,
    _restoredMainBg = restoredMainBg,
    _restoredMainObj = restoredMainObj,
    _objectBase = objectBase,
    _frame = 0,
    _late = false,
    _version = 0,
  }, M)
end

---@param frame integer absolute source-task frame under display
---@return integer main fade coefficient in blend units from 0 to 16
local function mainCoefficient(frame)
  if frame < FADE_START or frame >= RESTORE_FRAME then
    return 0
  end
  return math.min(FADE_RANGE, 2 * (frame - FADE_START))
end

---@param frame integer absolute source-task frame under display
---@return integer lower reveal coefficient in blend units from 16 down to 0
local function revealCoefficient(frame)
  if frame < RESTORE_FRAME then
    return 0
  end
  return math.max(0, FADE_RANGE - (frame - RESTORE_FRAME))
end

---@param frame integer absolute source-task frame under display
---@return integer main restore coefficient in blend units from 16 down to 0
local function restoreCoefficient(frame)
  return math.max(0, FADE_RANGE - 2 * (frame - RESTORE_FRAME))
end

---@param self BattleEncounterPalette
---@param frame integer absolute source-task frame under display
---@return integer[] displayed main background words for the frame
local function displayedMainBg(self, frame)
  if frame < FADE_START then
    return copyWords(self._initMainBg)
  end
  if frame >= RESTORE_FRAME then
    -- The unfaded base is restored at frame 28; the display blends from
    -- the fill back to that base with the same coefficient the flash
    -- metadata publishes, so buffers and metadata never diverge.
    local restore = restoreCoefficient(frame)
    if restore == 0 then
      return copyWords(self._restoredMainBg)
    end
    local out = {}
    for index = 0, ENTRY_COUNT - 1 do
      if maskSelects(M.MAIN_BG_MASK, bankOf(index)) then
        out[index + 1] = blendWord(self._restoredMainBg[index + 1], self._fill, restore)
      else
        out[index + 1] = self._restoredMainBg[index + 1]
      end
    end
    return out
  end
  local coefficient = mainCoefficient(frame)
  local out = {}
  for index = 0, ENTRY_COUNT - 1 do
    if maskSelects(M.MAIN_BG_MASK, bankOf(index)) then
      out[index + 1] = blendWord(self._backupMainBg[index + 1], self._fill, coefficient)
    else
      out[index + 1] = self._initMainBg[index + 1]
    end
  end
  return out
end

---@param self BattleEncounterPalette
---@param frame integer absolute source-task frame under display
---@return integer[] displayed main object words for the frame
local function displayedMainObj(self, frame)
  if frame < FADE_START then
    return copyWords(self._initMainObj)
  end
  if frame >= RESTORE_FRAME then
    local restore = restoreCoefficient(frame)
    if restore == 0 then
      return copyWords(self._restoredMainObj)
    end
    local out = {}
    for index = 0, ENTRY_COUNT - 1 do
      if maskSelects(M.MAIN_OBJ_MASK, bankOf(index)) then
        out[index + 1] = blendWord(self._restoredMainObj[index + 1], self._fill, restore)
      else
        out[index + 1] = self._restoredMainObj[index + 1]
      end
    end
    return out
  end
  -- Object pixels fade by their source bank's staged base entry: the bank
  -- identity resolves from the pixel index, never from its color, so equal
  -- colors staged in different banks never merge into one fade.
  local coefficient = mainCoefficient(frame)
  local out = {}
  for index = 0, ENTRY_COUNT - 1 do
    local bank = bankOf(index)
    if maskSelects(M.MAIN_OBJ_MASK, bank) then
      out[index + 1] = blendWord(self._objectBase[bank + 1], self._fill, coefficient)
    else
      out[index + 1] = self._initMainObj[index + 1]
    end
  end
  return out
end

---@param self BattleEncounterPalette
---@param frame integer absolute source-task frame under display
---@return integer[] displayed sub background words for the frame
local function displayedSubBg(self, frame)
  if frame < FADE_START then
    local out = {}
    for _ = 1, ENTRY_COUNT do
      out[#out + 1] = BLACK
    end
    return out
  end
  if frame < RESTORE_FRAME then
    local gray = grayWord(math.min(FADE_RANGE, frame - FADE_START + 1))
    local out = {}
    for _ = 1, ENTRY_COUNT do
      out[#out + 1] = gray
    end
    return out
  end
  local coefficient = revealCoefficient(frame)
  local out = {}
  for index = 1, ENTRY_COUNT do
    out[index] = blendWord(self._backupSubBg[index], WHITE, coefficient)
  end
  return out
end

---@param self BattleEncounterPalette
---@param frame integer absolute source-task frame under display
---@return integer[] displayed sub object words for the frame
local function displayedSubObj(self, frame)
  if frame < RESTORE_FRAME then
    return copyWords(self._backupSubObj)
  end
  local coefficient = revealCoefficient(frame)
  local out = {}
  for index = 1, ENTRY_COUNT do
    out[index] = blendWord(self._backupSubObj[index], WHITE, coefficient)
  end
  return out
end

---@param self BattleEncounterPalette
---@param frame integer absolute source-task frame advancing the evaluator
function M:tick(frame)
  assert(type(frame) == "number" and frame % 1 == 0 and frame >= 1, "the encounter palette advances on source frames")
  if frame ~= self._frame then
    self._frame = frame
    self._version = self._version + 1
  end
end

---@param self BattleEncounterPalette
function M:beginLateFade()
  if not self._late then
    self._late = true
    self._version = self._version + 1
  end
end

---@param self BattleEncounterPalette
function M:reset()
  self._frame = 0
  self._late = false
  self._version = self._version + 1
end

---@param self BattleEncounterPalette
---@return BattleEncounterPalette.Snapshot detached per-plane source palette state
function M:snapshot()
  local state = {
    mainBg = displayedMainBg(self, self._frame),
    mainObj = displayedMainObj(self, self._frame),
    subBg = displayedSubBg(self, self._frame),
    subObj = displayedSubObj(self, self._frame),
    version = self._version,
  }
  if self._late then
    state.lateBgMask = M.LATE_BG_MASK
  end
  return state
end

---@param self BattleEncounterPalette
---@param plane "mainBg"|"mainObj"|"subBg"|"subObj" native plane behind the sample
---@param index integer zero-based source palette index
---@return integer displayed RGB555 word for the plane index
function M:colorAt(plane, index)
  assert(
    type(index) == "number" and index % 1 == 0 and index >= 0 and index < ENTRY_COUNT,
    "palette samples name a source index"
  )
  if plane == "mainBg" then
    return displayedMainBg(self, self._frame)[index + 1]
  elseif plane == "mainObj" then
    return displayedMainObj(self, self._frame)[index + 1]
  elseif plane == "subBg" then
    return displayedSubBg(self, self._frame)[index + 1]
  end
  assert(plane == "subObj", "palette samples name their native plane")
  return displayedSubObj(self, self._frame)[index + 1]
end

return M
