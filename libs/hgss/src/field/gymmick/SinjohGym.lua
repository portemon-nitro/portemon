-- The Sinjoh Mystri Stage mechanism (src/field/gymmick/sinjoh.c). The map's
-- own stage scene installs the union, loads the three stage models with their
-- two animation records each, and places them at the source's own FX32
-- positions; a pedestal script then stores its raw choice in the union and the
-- mechanism waits for the animations' common 30-frame boundary before the
-- selected phase (frames 30..60) starts. The source frees all three models when
-- the map's local data goes away.
--
-- Each stage model carries joint and texture-matrix records whose idle phase
-- runs frames 0..30 and whose selected phase runs frames 30..60; a choice
-- transition lands exactly on the phase boundary, so the three models stay
-- synchronized. The mechanism owns the phase clock, the frozen flag and the
-- chosen union; nothing here grants a mon or decides eligibility, which stay in
-- the authored script and the existing GiveMon operation.
--
-- A composition without stage model instances (the headless field) presents
-- nothing: the phase clock and the selected union are unchanged.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local GymMechanismState = require("libs.hgss.src.field.GymMechanismState")

---@class SinjohGymOptions
---@field state GymMechanismState the saved union this mechanism settles
---@field modelFactory (fun(slot: integer): table<string, unknown>)? the composed stage-model factory

---@class SinjohGym.Placement
---@field slot integer one-based source stage model index
---@field x number source position in tiles
---@field y number
---@field z number
---@field frame integer source animation frame 0..59
---@field selected boolean the model sits in its selected phase
---@field visible boolean false while the stage froze its models

---@class SinjohGym
---@field private _state GymMechanismState
---@field private _models table<integer, table<string, unknown>>
---@field private _frame integer the shared source animation frame 0..59
---@field private _selected boolean the current phase's selected state
---@field private _pending integer? the choice whose boundary transition is pending
---@field private _frozen boolean
local SinjohGym = {}
SinjohGym.__index = SinjohGym

-- src/field/gymmick/sinjoh.c: three stage models with two animation records
-- each out of the demo/legend archive.
SinjohGym.MODEL_MEMBERS = { 101, 104, 107 }
SinjohGym.ANIMATION_MEMBERS = { { 102, 103 }, { 105, 106 }, { 108, 109 } }

-- The source placements are FX32_CONST tile positions; sixteen model units make
-- a tile, so the three models stand on the centres of tiles (12,15), (20,15)
-- and (16,8).
SinjohGym.PLACEMENTS = {
  { x = 200 / 16, y = 16 / 16, z = 248 / 16 },
  { x = 328 / 16, y = 16 / 16, z = 248 / 16 },
  { x = 264 / 16, y = 16 / 16, z = 136 / 16 },
}

-- The idle phase runs frames 0..30 and the selected phase frames 30..60; a
-- transition commits when the advance reaches the current phase's end frame.
SinjohGym.PHASE_FRAMES = 30
SinjohGym.FRAME_COUNT = 60

---@param options SinjohGymOptions
---@return SinjohGym
function SinjohGym.new(options)
  assert(type(options) == "table", "the Sinjoh stage needs its collaborators")
  assert(options.state and options.state.sinjohChoice, "the Sinjoh stage owns the saved union")
  if options.modelFactory ~= nil then
    assert(type(options.modelFactory) == "function", "the Sinjoh stage model factory creates stage props")
  end
  local gym = setmetatable({
    _state = options.state,
    _models = {},
    _frame = 0,
    _selected = false,
    _pending = nil,
    _frozen = false,
  }, SinjohGym)
  if options.modelFactory ~= nil then
    for slot = 1, #SinjohGym.MODEL_MEMBERS do
      gym._models[slot] = options.modelFactory(slot)
    end
  end
  return gym
end

-- GymmickInit_Sinjoh: the stage starts in its unresolved phase.
---@return integer the stored union choice
function SinjohGym:initialize()
  local choice = self._state:sinjohChoice()
  self._selected = choice ~= 0
  if self._selected then
    self._frame = SinjohGym.PHASE_FRAMES
  end
  return choice
end

-- SinjohGymmick_FreezeAllModels: the three stage models stop being drawn. The
-- source only clears each object's active flag; the animation clock and the
-- stored union are untouched.
function SinjohGym:freeze()
  self._frozen = true
end

---@return boolean
function SinjohGym:isFrozen()
  return self._frozen
end

-- SinjohGymmick_SetChosenLegend: store the raw choice and start the one
-- blocking wait the source's own task runs until the shared phase boundary.
---@param choice integer
function SinjohGym:choose(choice)
  if type(choice) ~= "number" or choice % 1 ~= 0 or choice < 0 or choice >= GymMechanismState.SINJOH_CHOICES then
    Errors.raise(FieldErrors.FIELD_GYM_MECHANISM_INVALID, "the Sinjoh choice is not a source pedestal", {
      choice = tostring(choice),
      choiceCount = GymMechanismState.SINJOH_CHOICES,
    })
  end
  assert(type(choice) == "number", "choice validation requires a number")
  self._state:setSinjohChoice(choice)
  self._pending = choice
  self._frozen = false
end

---@return boolean
function SinjohGym:isWaiting()
  return self._pending ~= nil
end

-- A cancelled stage choice keeps the stored union value and abandons only the
-- pending phase transition, exactly like an abandoned source wait task.
function SinjohGym:cancelWait()
  self._pending = nil
end

-- Advance the shared source animation clock one fixed tick. The pending choice
-- commits when the current phase reaches its own end frame: the models then
-- continue from the selected phase's first frame, exactly like the source's
-- FrameAdvanceAndLoop/FrameSet pair.
function SinjohGym:updateFixed()
  local endFrame = self._selected and SinjohGym.FRAME_COUNT or SinjohGym.PHASE_FRAMES
  if self._pending ~= nil and self._frame == endFrame - 1 then
    self._selected = self._pending ~= 0
    self._frame = self._selected and SinjohGym.PHASE_FRAMES or 0
    self._pending = nil
    return
  end
  self._frame = (self._frame + 1) % SinjohGym.FRAME_COUNT
end

-- Advance the presented stage models' own clip clocks one fixed tick.
function SinjohGym:updatePresentation()
  for _, model in pairs(self._models) do
    model:updateFixed()
  end
end

-- The immutable per-tick snapshot: where each stage model stands and which
-- phase it is in. The frozen flag is the source's object active flag.
---@return SinjohGym.Placement[]
function SinjohGym:presentation()
  local placements = {}
  for slot, source in ipairs(SinjohGym.PLACEMENTS) do
    placements[slot] = {
      slot = slot,
      x = source.x,
      y = source.y,
      z = source.z,
      frame = self._frame,
      selected = self._selected,
      visible = not self._frozen,
    }
  end
  return placements
end

-- GymmickFree_Sinjoh: release every stage model exactly once. A repeated
-- dispose is a clean no-op.
function SinjohGym:dispose()
  for slot, model in pairs(self._models) do
    model:dispose()
    self._models[slot] = nil
  end
  self._pending = nil
end

return SinjohGym
