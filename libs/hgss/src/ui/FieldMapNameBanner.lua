-- Pure fixed-tick controller for the transient top-left area-name banner:
-- one eligible request at a time, one latest pending request, and
-- source-equivalent enter/hold/exit elapsed timing on the field's 30 Hz tick.
-- Compiled style eligibility and the native section title arrive through
-- injected selectors, so the controller owns no message cache or presentation
-- dependency and never re-reads either in draw.

---@class FieldMapNameBanner.Pending
---@field mapSectionNativeId integer
---@field styleKey integer

---@class FieldMapNameBanner.Status
---@field title string
---@field styleKey integer
---@field scrollOffset integer

---@class FieldMapNameBanner
---@field private _styleByMapId table<integer, integer>
---@field private _resolveTitle fun(mapSectionNativeId: integer): string
---@field private _state "idle"|"enter"|"hold"|"exit"
---@field private _title string?
---@field private _styleKey integer?
---@field private _offset integer
---@field private _holdElapsed integer
---@field private _pending FieldMapNameBanner.Pending?
local FieldMapNameBanner = {}
FieldMapNameBanner.__index = FieldMapNameBanner

-- The source BG3 scroll: 38 logical pixels in, a one-second hold, and 38 back
-- out. The 30 Hz field tick advances two retail display-frame steps, so the
-- entry and exit each span five ticks and the hold spans thirty.
FieldMapNameBanner.ENTER_DISPLACEMENT = 38
local SCROLL_STEP = 8
local HOLD_TICKS = 30

---@param opts { styleByMapId: table<integer, integer>, resolveTitle: fun(mapSectionNativeId: integer): string }
---@return FieldMapNameBanner
function FieldMapNameBanner.new(opts)
  assert(type(opts) == "table", "the map-name banner needs its options")
  assert(type(opts.styleByMapId) == "table", "the map-name banner needs the compiled style projection")
  assert(type(opts.resolveTitle) == "function", "the map-name banner needs its section-title resolver")
  return setmetatable({
    _styleByMapId = opts.styleByMapId,
    _resolveTitle = opts.resolveTitle,
    _state = "idle",
    _title = nil,
    _styleKey = nil,
    _offset = 0,
    _holdElapsed = 0,
    _pending = nil,
  }, FieldMapNameBanner)
end

-- Starts a pending request as the visible banner: the title resolves once, at
-- activation, and the entry begins at the source displacement.
---@param pending FieldMapNameBanner.Pending
function FieldMapNameBanner:_activate(pending)
  self._title = self._resolveTitle(pending.mapSectionNativeId)
  self._styleKey = pending.styleKey
  self._offset = FieldMapNameBanner.ENTER_DISPLACEMENT
  self._holdElapsed = 0
  self._state = "enter"
end

-- Eligibility is the compiled projection alone; the caller distinguishes warp
-- from seamless producers. An ineligible map is ignored rather than blanking
-- an already visible banner.
---@param mapId integer
---@param mapSectionNativeId integer
---@return boolean accepted
function FieldMapNameBanner:request(mapId, mapSectionNativeId)
  local styleKey = self._styleByMapId[mapId]
  if styleKey == nil then
    return false
  end
  local pending = { mapSectionNativeId = mapSectionNativeId, styleKey = styleKey }
  if self._state == "idle" then
    self:_activate(pending)
    return true
  end
  -- A visible banner keeps its own art while it departs; a repeated request
  -- only replaces the single latest pending entry. The outgoing slide starts
  -- from the current displacement and leaves the active text untouched.
  self._pending = pending
  if self._state ~= "exit" then
    self._state = "exit"
    self._offset = math.min(self._offset + SCROLL_STEP, FieldMapNameBanner.ENTER_DISPLACEMENT)
  end
  return true
end

function FieldMapNameBanner:updateFixed()
  local state = self._state
  if state == "enter" then
    self._offset = math.max(0, self._offset - SCROLL_STEP)
    if self._offset == 0 then
      self._state = "hold"
      self._holdElapsed = 0
    end
  elseif state == "hold" then
    self._holdElapsed = self._holdElapsed + 1
    if self._holdElapsed >= HOLD_TICKS then
      self._state = "exit"
    end
  elseif state == "exit" then
    self._offset = math.min(FieldMapNameBanner.ENTER_DISPLACEMENT, self._offset + SCROLL_STEP)
    if self._offset >= FieldMapNameBanner.ENTER_DISPLACEMENT then
      local pending = self._pending
      self._pending = nil
      if pending ~= nil then
        self:_activate(pending)
      else
        self._state = "idle"
        self._title = nil
        self._styleKey = nil
        self._offset = 0
        self._holdElapsed = 0
      end
    end
  end
end

---@return FieldMapNameBanner.Status?
function FieldMapNameBanner:status()
  if self._state == "idle" then
    return nil
  end
  return {
    title = assert(self._title),
    styleKey = assert(self._styleKey),
    scrollOffset = self._offset,
  }
end

return FieldMapNameBanner
