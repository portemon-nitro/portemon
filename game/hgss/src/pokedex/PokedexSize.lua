-- Authored height presentation and the fixed weight recurrence for one
-- entry: the thirty-update drop, mirrored small tilts, clamped large
-- beams, same-update throw starts, triangular landings, the upward escape,
-- and restart sequencing. Private exact fixed-point trigonometry only;
-- no shared math service, no image or audio work.

local Errors = require("libs.errors.src.Errors")

---@class PokedexSize
---@field _measurements table<string, unknown> frozen profile measurement rows
---@field _species string entry species key
---@field _playerGender string trainer gender selecting height records
---@field _monWeightHg integer entry weight in hectograms
---@field _trainerWeightHg integer trainer weight in hectograms
---@field _class integer difference bucket 0 through 16
---@field _sign integer heavier side, +1 mon or -1 trainer
---@field _phase string drop, tilt, beam, thrown, landed, escaped, even, restart
---@field _setupTick integer completed setup updates before the first drop
---@field _dropTick integer completed drop movement updates
---@field _dropFx integer accumulated drop velocity in 1/4096 units
---@field _beamAngle integer sixteen-bit beam angle
---@field _speed integer current tilt speed, signed
---@field _figures table[] weight figures with logical pane and position
---@field _throwVelocity integer? current thrown figure velocity
---@field _thrownIndex integer? which figure left the beam
---@field _restartTick integer progress through the restart rebuild
---@field _sound string? pending authored sound role
local PokedexSize = {}
PokedexSize.__index = PokedexSize

PokedexSize.SETUP_TICKS = 48
PokedexSize.DROP_UPDATES = 30
PokedexSize.DROP_STEP = 0x400
PokedexSize.DROP_START_Y = -16
PokedexSize.BEAM_Y = 88
PokedexSize.BEAM_LIMIT = 0x0A00
PokedexSize.BEAM_PIVOT_X = 128
PokedexSize.BEAM_PIVOT_Y = 104
PokedexSize.PAN_RADIUS = 56
-- One restart runs the old motion first, flashes the tab, fades out,
-- rebuilds, and fades back in before the fresh drop starts.
PokedexSize.RESTART_TICKS = 12
PokedexSize.TRAINER_WEIGHTS = { male = 400, female = 410 }

-- Difference buckets with their beam parameters and authored sounds.
PokedexSize.CLASSES = {
  { max = 0, tilt = true, speed = 0, accel = 0, terminal = 0, sound = "SEQ_SE_GS_ZUKAN01" },
  { max = 1, tilt = true, speed = 0x100, accel = -32, terminal = -224, sound = "SEQ_SE_GS_ZUKAN01" },
  { max = 2, tilt = true, speed = 0x120, accel = -32, terminal = -256, sound = "SEQ_SE_GS_ZUKAN01" },
  { max = 3, tilt = true, speed = 0x140, accel = -32, terminal = -288, sound = "SEQ_SE_GS_ZUKAN01" },
  { max = 4, tilt = true, speed = 0x160, accel = -32, terminal = -320, sound = "SEQ_SE_GS_ZUKAN01" },
  { max = 5, tilt = true, speed = 0x180, accel = -32, terminal = -352, sound = "SEQ_SE_GS_ZUKAN01" },
  { max = 6, tilt = true, speed = 0x1C0, accel = -64, terminal = -320, sound = "SEQ_SE_GS_ZUKAN01" },
  { max = 7, tilt = true, speed = 0x200, accel = -64, terminal = -384, sound = "SEQ_SE_GS_ZUKAN01" },
  { max = 15, beam = 0x300, sound = "SEQ_SE_GS_ZUKAN01" },
  { max = 30, beam = 0x300, vy = -4, ay = 1, sound = "SEQ_SE_GS_ZUKAN02" },
  { max = 50, beam = 0x400, vy = -8, ay = 1, sound = "SEQ_SE_GS_ZUKAN02" },
  { max = 75, beam = 0x400, vy = -12, ay = 1, sound = "SEQ_SE_GS_ZUKAN02" },
  { max = 105, beam = 0x500, vy = -14, ay = 1, sound = "SEQ_SE_GS_ZUKAN03" },
  { max = 155, beam = 0x500, vy = -18, ay = 1, sound = "SEQ_SE_GS_ZUKAN03" },
  { max = 235, beam = 0x600, vy = -21, ay = 1, sound = "SEQ_SE_GS_ZUKAN03" },
  { max = 350, beam = 0x700, vy = -24, ay = 1, sound = "SEQ_SE_GS_ZUKAN03" },
  { max = 65535, beam = 0x800, vy = -24, ay = 0, escape = true, sound = "SEQ_SE_GS_ZUKAN04" },
}

local function fail(message, context)
  Errors.raise("POKEDEX_INVALID", message, context)
end

---@param angle integer source sixteen-bit angle
---@return integer sine scaled by 4096
---@return integer cosine scaled by 4096
local function quantizedTrig(angle)
  local reduced = angle % 65536
  local index = math.floor(reduced / 16)
  local theta = 2 * math.pi * index / 4096
  local function quantize(value)
    local scaled = value * 4096
    if scaled >= 0 then
      return math.floor(scaled + 0.5)
    end
    return -math.floor(-scaled + 0.5)
  end
  return quantize(math.sin(theta)), quantize(math.cos(theta))
end

---@param product integer scaled product
---@return integer arithmetic shift floor equivalent
local function shiftFloor(product)
  return math.floor(product / 4096)
end

---@param args { catalog: table<string, unknown>, species: string, profileName: string, playerGender: string }
---@return PokedexSize
function PokedexSize.new(args)
  if type(args) ~= "table" then
    fail("size needs a construction record", {})
  end
  assert(type(args) == "table", "size reads its construction record")
  if type(args.catalog) ~= "table" then
    fail("size needs the generated catalog", {})
  end
  if type(args.species) ~= "string" or args.species == "" then
    fail("size names its entry species", {})
  end
  if type(args.profileName) ~= "string" or args.profileName == "" then
    fail("size names its frozen profile", {})
  end
  if args.playerGender ~= "male" and args.playerGender ~= "female" then
    fail("size needs the trainer gender", { gender = args.playerGender })
  end
  local catalog = args.catalog
  assert(type(catalog) == "table", "size reads its borrowed catalog")
  local profiles = catalog.measurementProfiles
  if type(profiles) ~= "table" then
    fail("size catalog is missing its measurement profiles", {})
  end
  local profile = profiles[args.profileName]
  if type(profile) ~= "table" then
    fail("size profile names its authored measurements", { profile = args.profileName })
  end
  local measurements = profile.measurements
  if type(measurements) ~= "table" then
    fail("size profile names its authored measurements", { profile = args.profileName })
  end
  local row = measurements[args.species]
  if type(row) ~= "table" or type(row.heightDm) ~= "number" or type(row.weightHg) ~= "number" then
    fail("size needs the legal measurement row", { species = args.species })
  end
  local trainerWeight = PokedexSize.TRAINER_WEIGHTS[args.playerGender]
  local difference = math.abs(row.weightHg - trainerWeight)
  local class = 0
  for index, bucket in ipairs(PokedexSize.CLASSES) do
    if difference <= bucket.max then
      class = index - 1
      break
    end
  end
  local sign = 1
  if row.weightHg < trainerWeight then
    sign = -1
  end
  local self = setmetatable({
    _measurements = measurements,
    _species = args.species,
    _playerGender = args.playerGender,
    _monWeightHg = row.weightHg,
    _trainerWeightHg = trainerWeight,
    _class = class,
    _sign = sign,
    _phase = "setup",
    _setupTick = 0,
    _dropTick = 0,
    _dropFx = 0,
    _beamAngle = 0,
    _speed = 0,
    _figures = {
      { side = "mon", pane = "main", y = PokedexSize.DROP_START_Y, visible = true },
      { side = "trainer", pane = "main", y = PokedexSize.DROP_START_Y, visible = true },
    },
    _throwVelocity = nil,
    _thrownIndex = nil,
    _restartTick = 0,
    _sound = nil,
  }, PokedexSize)
  return self
end

---@return { mon: { dm: number, yOffset: number }, trainer: { dm: number, yOffset: number } } height presentation for the trainer gender record
function PokedexSize:heightView()
  local row = self._measurements[self._species]
  assert(type(row) == "table", "size reads its validated measurement row")
  local offsets = row.yOffset
  if type(offsets) ~= "table" then
    fail("size needs the legal height offsets", { species = self._species })
  end
  local gendered = offsets[self._playerGender]
  if type(gendered) ~= "table" or type(gendered.trainer) ~= "number" or type(gendered.mon) ~= "number" then
    fail("size needs the legal trainer gender record", { species = self._species })
  end
  return {
    mon = { dm = row.heightDm, yOffset = gendered.mon },
    trainer = { dm = row.heightDm, yOffset = gendered.trainer },
  }
end

---@param panAngle integer sixteen-bit pan angle
---@return integer pan column
function PokedexSize:_panX(panAngle)
  local sine = quantizedTrig(panAngle)
  return PokedexSize.BEAM_PIVOT_X + shiftFloor(PokedexSize.PAN_RADIUS * sine)
end

---@return table[] detached pan projections
function PokedexSize:_pans()
  local out = {}
  for _, base in ipairs({ -0x4000, 0x4000 }) do
    out[#out + 1] = { x = self:_panX(base - self._beamAngle), y = PokedexSize.BEAM_PIVOT_Y, visible = true }
  end
  return out
end

function PokedexSize:_finishDrop()
  local bucket = PokedexSize.CLASSES[self._class + 1]
  self._sound = bucket.sound
  if bucket.tilt == true then
    if bucket.speed == 0 then
      self._phase = "even"
    else
      self._phase = "tilt"
      self._speed = bucket.speed * self._sign
    end
  else
    self._phase = "beam"
  end
end

function PokedexSize:_updateDrop()
  self._dropFx = self._dropFx + PokedexSize.DROP_STEP
  self._dropTick = self._dropTick + 1
  local step = math.floor(self._dropFx / 4096)
  for _, figure in ipairs(self._figures) do
    figure.y = figure.y + step
    if figure.y > PokedexSize.BEAM_Y then
      figure.y = PokedexSize.BEAM_Y
    end
  end
  if self._dropTick >= PokedexSize.DROP_UPDATES then
    self:_finishDrop()
  end
end

function PokedexSize:_updateTilt()
  local bucket = PokedexSize.CLASSES[self._class + 1]
  self._beamAngle = self._beamAngle + self._speed
  self._speed = self._speed + bucket.accel * self._sign
  if self._speed == bucket.terminal * self._sign then
    self._phase = "landed"
  end
end

---@return integer index of the lighter high-side figure
function PokedexSize:_highSide()
  if self._monWeightHg < self._trainerWeightHg then
    return 1
  end
  return 2
end

function PokedexSize:_updateBeam()
  local bucket = PokedexSize.CLASSES[self._class + 1]
  self._beamAngle = self._beamAngle + bucket.beam * self._sign
  if math.abs(self._beamAngle) >= PokedexSize.BEAM_LIMIT then
    self._beamAngle = PokedexSize.BEAM_LIMIT * self._sign
    if bucket.vy == nil then
      self._phase = "landed"
      return
    end
    local thrown = self:_highSide()
    self._thrownIndex = thrown
    if bucket.escape == true then
      for _, figure in ipairs(self._figures) do
        figure.y = figure.y + bucket.vy
      end
      self._throwVelocity = bucket.vy
      self._phase = "escape"
      return
    end
    local figure = self._figures[thrown]
    figure.y = figure.y + bucket.vy
    self._throwVelocity = bucket.vy + bucket.ay
    self._phase = "thrown"
  end
end

function PokedexSize:_updateThrown()
  local bucket = PokedexSize.CLASSES[self._class + 1]
  local figure = self._figures[self._thrownIndex or self:_highSide()]
  local velocity = self._throwVelocity or 0
  figure.y = figure.y + velocity
  velocity = velocity + bucket.ay
  self._throwVelocity = velocity
  if figure.y == PokedexSize.BEAM_PIVOT_Y - 16 and velocity >= 0 then
    self._phase = "landed"
  end
end

function PokedexSize:_updateEscape()
  local velocity = self._throwVelocity or 0
  local gone = true
  for _, figure in ipairs(self._figures) do
    figure.y = figure.y + velocity
    if figure.y > -256 then
      gone = false
    end
  end
  if gone == true then
    for _, figure in ipairs(self._figures) do
      figure.visible = false
    end
    self._phase = "escaped"
  end
end

function PokedexSize:_updateMotion()
  if self._phase == "setup" then
    self._setupTick = self._setupTick + 1
    if self._setupTick >= PokedexSize.SETUP_TICKS then
      -- The figures start falling here, so the fall tone fires once at
      -- the drop start like the source weight check; the bucket tone
      -- still fires at the drop end through the existing takeSound.
      self._sound = "SEQ_SE_GS_RAKKA01"
      self._phase = "drop"
    end
  elseif self._phase == "drop" then
    self:_updateDrop()
  elseif self._phase == "tilt" then
    self:_updateTilt()
  elseif self._phase == "beam" then
    self:_updateBeam()
  elseif self._phase == "thrown" then
    self:_updateThrown()
  elseif self._phase == "escape" then
    self:_updateEscape()
  end
end

function PokedexSize:update()
  if self._phase == "restart" then
    self:_updateMotion()
    self._restartTick = self._restartTick + 1
    if self._restartTick >= PokedexSize.RESTART_TICKS then
      self._phase = "drop"
      self._dropTick = 0
      self._dropFx = 0
      self._beamAngle = 0
      self._speed = 0
      self._throwVelocity = nil
      self._thrownIndex = nil
      self._restartTick = 0
      for _, figure in ipairs(self._figures) do
        figure.y = PokedexSize.DROP_START_Y
        figure.visible = true
      end
    end
    return
  end
  self:_updateMotion()
end

function PokedexSize:restart()
  if self:isMoving() and self._phase ~= "restart" then
    self._phase = "restart"
    self._restartTick = 0
  end
end

---@return boolean whether weight motion is still running
function PokedexSize:isMoving()
  return self._phase == "drop"
    or self._phase == "tilt"
    or self._phase == "beam"
    or self._phase == "thrown"
    or self._phase == "escape"
end

---@return string? pending authored sound role, cleared on read
function PokedexSize:takeSound()
  local sound = self._sound
  self._sound = nil
  return sound
end

---@return { height: { mon: { dm: number, yOffset: number }, trainer: { dm: number, yOffset: number }, scale?: { mon: number, trainer: number } }, weight: { phase: string, class: integer, beamAngle: integer, dropVelocity: integer, throwVelocity: integer? }, figures: table[], pans: table[], tick: integer } detached size projection
function PokedexSize:view()
  local figures = {}
  for _, figure in ipairs(self._figures) do
    figures[#figures + 1] = { side = figure.side, pane = figure.pane, y = figure.y, visible = figure.visible }
  end
  return {
    height = self:heightView(),
    weight = {
      phase = self._phase,
      class = self._class,
      beamAngle = self._beamAngle,
      dropVelocity = self._dropFx,
      throwVelocity = self._throwVelocity,
    },
    figures = figures,
    pans = self:_pans(),
    tick = self._dropTick,
  }
end

return PokedexSize
