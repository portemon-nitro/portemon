-- The prepared presentation behind the League ending's three native surfaces:
-- the Hall of Fame registration view (msg_0180), the PC showcase
-- (msg_0181 with the recorded party's own art) and the credit roll
-- (NARC_a_2_6_3 with msg_0440). One owner per live ending or showcase child: it
-- prepares the generated bundle once, exposes readiness, draws only immutable
-- snapshots, and releases its leases exactly once.
--
-- The bundle is the producer's own source-derived artifact: this owner never
-- invents art, layout or text and fails closed with its source identity while
-- the required sections are missing.

local Errors = require("libs.errors.src.Errors")

---@class HallOfFamePresentation
---@field private sections table<string, unknown>?
---@field private signature string?
---@field private disposed boolean
local HallOfFamePresentation = {}
HallOfFamePresentation.__index = HallOfFamePresentation

-- The source surfaces this presenter draws, in bundle order.
HallOfFamePresentation.SECTIONS = { "registration", "showcase", "credits" }

---@param bundle table<string, unknown>|nil the loaded ending asset sections
---@return HallOfFamePresentation
function HallOfFamePresentation.new(bundle)
  local presentation = setmetatable({ sections = nil, signature = nil, disposed = false }, HallOfFamePresentation)
  if bundle ~= nil then
    presentation:prepare(bundle)
  end
  return presentation
end

-- Admits one loaded bundle. Every required section must be present before the
-- presentation becomes ready: a partially loaded bundle would draw a surface
-- with missing source records.
---@param bundle table<string, unknown>
function HallOfFamePresentation:prepare(bundle)
  assert(not self.disposed, "disposed Hall of Fame presentation cannot prepare")
  assert(type(bundle) == "table", "the ending presentation needs its generated bundle")
  for _, section in ipairs(HallOfFamePresentation.SECTIONS) do
    assert(
      type(bundle[section]) == "table",
      "the ending presentation bundle carries its " .. section .. " section"
    )
  end
  self.sections = bundle
  self.signature = assert(bundle.signature, "the ending presentation bundle names its source signature")
end

---@return boolean
function HallOfFamePresentation:isReady()
  return self.sections ~= nil
end

---@param section string
---@return table<string, unknown>
function HallOfFamePresentation:_require(section)
  assert(not self.disposed, "disposed Hall of Fame presentation cannot draw")
  local sections = self.sections
  if sections == nil then
    Errors.raise(
      "FIELD_ENDING_ASSET_MISSING",
      "the League ending's generated presentation bundle is unavailable",
      { section = section }
    )
  end
  assert(sections ~= nil, "the presentation bundle is available after the missing-bundle error")
  return assert(sections[section], "the presentation bundle carries its " .. section .. " section")
end

-- The registration view's own plan: the source party records the ending is
-- about to store, drawn by the generated registration section.
---@param status table<string, unknown> the ending's registration snapshot
---@return table<string, unknown>
function HallOfFamePresentation:registrationPlan(status)
  local section = self:_require("registration")
  return assert(section.plan)(section, status)
end

-- The showcase plan over one immutable record page.
---@param status table<string, unknown> the showcase's snapshot
---@return table<string, unknown>
function HallOfFamePresentation:presentationPlan(status)
  local section = self:_require("showcase")
  return assert(section.plan)(section, status)
end

-- The registration application's own timeline: how many fixed ticks its
-- per-member reveal takes before it accepts the acknowledging input. A
-- composition without the bundle has no frames to play.
---@return integer
function HallOfFamePresentation:congratulationsFrames()
  if self.sections == nil then
    return 0
  end
  local section = self:_require("registration")
  return math.floor(assert(section.frameCount))
end

-- The save-status message's own print duration, in fixed ticks. Without the
-- bundle nothing is printed, so nothing is waited for.
---@return integer
function HallOfFamePresentation:saveStatusFrames()
  if self.sections == nil then
    return 0
  end
  local section = self:_require("credits")
  local frames = section.saveStatusFrames
  return type(frames) == "number" and math.floor(frames) or 0
end

-- One palette fade's length. The source's own frame counts apply only while a
-- bundle is composed and there is a screen to fade.
---@param frames integer
---@return integer
function HallOfFamePresentation:fadeFrames(frames)
  assert(type(frames) == "number" and frames >= 0, "a fade declares its source frame count")
  if self.sections == nil then
    return 0
  end
  return math.floor(frames)
end

---@param resources table<string, unknown>
---@param status table<string, unknown>
function HallOfFamePresentation:draw(resources, status)
  local section = self:_require(status.section or "showcase")
  assert(type(section.draw) == "function", "the ending presentation section draws its own surface")
  section.draw(section, resources, status)
end

function HallOfFamePresentation:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  self.sections = nil
end

return HallOfFamePresentation
