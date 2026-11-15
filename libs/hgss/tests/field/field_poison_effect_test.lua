-- FieldPoisonEffect owns the retail HBlank wobble behind field damage
-- ticks: every HBlank shifts the 3D layer horizontally with an offset that
-- alternates sign every 10 scanlines, ramping 1, 2, 3, 2, 1, 0 over six
-- frames inside an eight-frame START/RAMP_UP/RAMP_DOWN/STOP lifetime.

local Assert = require("tests.support.Assert")
local FieldPoisonEffect = require("libs.hgss.src.field.FieldPoisonEffect")

local T = { tests = {} }

-- Idle owns no frame and idle updates never start one: the field draws
-- normally until a damage tick starts the wobble.
function T.tests.idle_publishes_no_frame_and_ignores_updates()
  local effect = FieldPoisonEffect.new()
  Assert.isFalse(effect:isActive())
  Assert.isNil(effect:frame(), "an idle wobble draws the field normally")
  effect:updateSourceFrame()
  Assert.isFalse(effect:isActive())
  Assert.isNil(effect:frame(), "an idle update never starts the wobble")
end

function T.tests.start_opens_a_zeroed_frame()
  local effect = FieldPoisonEffect.new()
  effect:start()
  Assert.isTrue(effect:isActive())
  local frame = assert(effect:frame(), "a started wobble publishes its scanline frame")
  Assert.equal(#frame.scanlineOffsets, 192, "the wobble covers every native scanline")
  for line = 1, 192 do
    Assert.equal(frame.scanlineOffsets[line], 0, "the START frame holds the cleared buffers")
  end
end

function T.tests.ramp_matches_the_native_fill_sequence()
  local effect = FieldPoisonEffect.new()
  effect:start()
  effect:updateSourceFrame() -- START -> RAMP_UP, still cleared
  local want = { 1, 2, 3, 2, 1, 0 }
  for step, amplitude in ipairs(want) do
    effect:updateSourceFrame()
    local offsets = assert(effect:frame(), "the wobble stays active through ramp step " .. step).scanlineOffsets
    Assert.equal(#offsets, 192)
    -- The sign alternates every 10 lines starting negative; the magnitude
    -- is the ramp amplitude on every line.
    for line = 1, 192 do
      local band = math.floor((line - 1) / 10) % 2
      local expected = band == 0 and -amplitude or amplitude
      Assert.equal(offsets[line], expected, "line " .. line .. " at ramp step " .. step)
    end
  end
  effect:updateSourceFrame() -- STOP releases the offsets
  Assert.isFalse(effect:isActive())
  Assert.isNil(effect:frame(), "STOP releases the wobble so the field draws normally")
end

return T
