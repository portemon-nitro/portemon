-- Source trigger raisers behind the retail trigger slots whose
-- detectors are still missing (the Bike Shop's slot 2 is raised by
-- FieldRuntime): each names the field-side detector that must raise the
-- flag and fails loudly until that detector exists. The flag mechanics
-- (state.setTrigger) already exist; these are the missing call sites.
-- When a detector is implemented, its function gains its parameters,
-- performs the detection, and raises its flag instead of failing; the
-- function then moves to its detecting owner. The Day-Care egg call
-- (slot 5) already lives with its detector: the Day Care step check
-- raises it, and the Day-Care Man's own script clears it.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.script.src.errors")

---@class PhoneTriggerSources
local PhoneTriggerSources = {}

---@param slot integer retail trigger slot
---@param domain string missing detector owner
---@param condition string source condition that raises the flag
local function missingDetector(slot, domain, condition)
  local failure = Errors.new(
    ScriptErrors.FEATURE_UNAVAILABLE,
    "phone trigger source needs its missing detector: " .. condition .. " (slot " .. slot .. ")",
    { slot = slot, condition = condition }
  )
  error({ code = failure.code, message = failure.message, context = failure.context, domain = domain })
end

-- An egg hatching in the party raises slot 0 (Elm 13).
function PhoneTriggerSources.elmEggHatch()
  missingDetector(0, "field-events", "an egg hatching in the party")
end

-- The pokerus check raises slot 1 (Elm 7).
function PhoneTriggerSources.elmPokerus()
  missingDetector(1, "field-events", "the pokerus spread check")
end

-- A full Bill PC raises slot 3 (Bill 93).
function PhoneTriggerSources.billPcFull()
  missingDetector(3, "pc", "a full Bill PC")
end

-- Oak dex progress raises slot 4 (Oak dynamic).
function PhoneTriggerSources.oakDexProgress()
  missingDetector(4, "dex", "an Oak dex progress milestone")
end

-- The next safari test raises slot 6 (Baoba dynamic).
function PhoneTriggerSources.baobaNextTest()
  missingDetector(6, "safari", "the next Baoba safari test")
end

-- The object arrangement raises slot 7 (Baoba 142).
function PhoneTriggerSources.baobaArrangement()
  missingDetector(7, "safari", "the Baoba object arrangement")
end

-- New safari objects raise slot 8 (Baoba 143).
function PhoneTriggerSources.baobaNewObjects()
  missingDetector(8, "safari", "new Baoba safari objects")
end

-- More safari objects raise slot 9 (Baoba 144).
function PhoneTriggerSources.baobaMoreObjects()
  missingDetector(9, "safari", "more Baoba safari objects")
end

-- Even more safari objects raise slot 10 (Baoba 145).
function PhoneTriggerSources.baobaEvenMoreObjects()
  missingDetector(10, "safari", "even more Baoba safari objects")
end

-- Safari memory loss raises slot 11 (Baoba 146).
function PhoneTriggerSources.baobaMemoryLoss()
  missingDetector(11, "safari", "Baoba safari memory loss")
end

-- The Mom gift purchase raises slot 12 (Mom 27).
function PhoneTriggerSources.momGift()
  missingDetector(12, "mom", "the Mom gift purchase")
end

return PhoneTriggerSources
