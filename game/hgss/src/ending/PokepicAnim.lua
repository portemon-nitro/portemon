-- The source picture animation stepper (pokepic.c runPokepicAnim): a small
-- state machine over ten {next, duration} script entries. Loop entries
-- (next < -1) count down their own duration before jumping back; next == -1
-- or running past the script ends the animation on frame 0. The caller
-- advances exactly one step per fixed tick and draws the returned charbuf
-- frame while non-negative. Pure module: no love, no I/O.

---@class PokepicAnim
---@field active boolean
---@field step integer current charbuf frame
---@field id integer current script index (1-based)
---@field delay integer ticks left on the current entry
---@field loops integer[] per-entry loop counters
---@field script table[] ten {next, duration} entries
local PokepicAnim = {}
PokepicAnim.__index = PokepicAnim

-- Starts one picture animation from its baked script: frame and delay come
-- from the script head, exactly like PokepicAnim_Init.
---@param script table[] ten {next, duration} entries
---@return PokepicAnim
function PokepicAnim.new(script)
  assert(type(script) == "table" and #script == 10, "a picture animation carries its ten script entries")
  local loops = {}
  for index = 1, 10 do
    loops[index] = 0
  end
  local head = assert(script[1], "a picture script carries its head entry")
  return setmetatable({
    active = true,
    step = head.next,
    id = 1,
    delay = head.duration,
    loops = loops,
    script = script,
  }, PokepicAnim)
end

-- Advances exactly one step, exactly like PokepicAnim_Exec: returns the
-- charbuf frame to display while non-negative, -1 once finished.
---@return integer frame 0/1, or -1 once finished
function PokepicAnim:update()
  if not self.active then
    return -1
  end
  local script = self.script
  if self.delay == 0 then
    self.id = self.id + 1
    while self.id <= 10 and script[self.id] ~= nil and script[self.id].next < -1 do
      self.loops[self.id] = (self.loops[self.id] or 0) + 1
      local entry = script[self.id]
      if entry.duration == self.loops[self.id] or entry.duration == 0 then
        self.loops[self.id] = 0
        self.id = self.id + 1
      else
        self.id = -2 - entry.next
      end
    end
    if self.id > 10 or script[self.id] == nil or script[self.id].next == -1 then
      self.step = 0
      self.active = false
    else
      self.step = script[self.id].next
      self.delay = script[self.id].duration
    end
  else
    self.delay = self.delay - 1
  end
  return self.step
end

return PokepicAnim
