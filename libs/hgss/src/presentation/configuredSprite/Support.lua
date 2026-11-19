-- Shared machinery behind the opcode-78 configured-sprite lane. A spawn
-- names one of the 33 overlay-07 sprite callbacks (gBattleAnimSpriteFuncTable
-- in asm/battle_anim_data.s) together with the four staged sprite roles the
-- interpreter loaded. Every body in this lane owns one native sprite callback
-- machine: it stages the roles, decodes the authored NCER/NANR bank, publishes
-- the drawn cells as transient strip-band pictures, and advances the native
-- phase machine tick for tick.
--
-- The native sprite funcs are in battle_anim_funcs.c, battle_anim_effects.c,
-- and battle_anim_move_effects.c; the shared motion helpers they call live in
-- battle_anim_util.c. This module mirrors those helpers so the family bodies
-- read like the source routines.

local BattleSlotCenters = require("libs.hgss.src.presentation.BattleSlotCenters")
local PresentationFxMath = require("libs.hgss.src.presentation.PresentationFxMath")
local Timed = require("libs.hgss.src.presentation.sourceTimed.Support")

local Support = {}

local FX = Timed.FX32_ONE
local REQUIRED_ROLES = { "character", "palette", "cell", "animation" }

Support.FX = FX

---@type fun(startX: integer, endX: integer, startY: integer, endY: integer, ticks: integer): SourceTimedLinearMotion
Support.linear = Timed.linear

---@type fun(startX: integer, endX: integer, startY: integer, endY: integer, divisor: integer, ticks: integer): SourceTimedScaleMotion
Support.scaleMotion = Timed.scaleMotion

---@type fun(ampX: integer, ampY: integer, interval: integer, count: integer): SourceTimedShake
Support.shake = Timed.shake

---@type fun(y: integer, inset: integer, scale: integer, mode: integer): integer
Support.alignY = Timed.alignY

---@type fun(inset: integer, scale: integer): integer
Support.scaleYOffset = Timed.scaleYOffset

---@type fun(value: unknown): integer
Support.clampLevel = Timed.clampLevel

---@type fun(value: unknown): integer
Support.clampOffset = Timed.clampOffset

---@type fun(value: unknown): integer
Support.clampRotation = Timed.clampRotation

---@param kind string task kind under diagnosis
---@param detail string violated construction invariant
function Support.malformed(kind, detail)
  error("BATTLE_EFFECT_TASK_MALFORMED: kind " .. kind .. " " .. detail, 0)
end

---@param args table<string, unknown>|nil instruction-derived construction arguments
---@param kind string task kind under diagnosis
---@return table<string, unknown> compiled parameter record, never nil
function Support.parameters(args, kind)
  local parameters = type(args) == "table" and args.parameters or nil
  if parameters == nil then
    return {}
  end
  if type(parameters) ~= "table" then
    Support.malformed(kind, "reads its compiled parameter record")
  end
  return parameters
end

---@param parameters table<string, unknown> compiled parameter record
---@param name string parameter name
---@param kind string task kind under diagnosis
---@param fallback integer? absent-value fallback
---@return integer value
function Support.whole(parameters, name, kind, fallback)
  local value = parameters[name]
  if value == nil then
    if fallback ~= nil then
      return fallback
    end
    Support.malformed(kind, "carries its compiled " .. name .. " operand")
  end
  if type(value) ~= "number" or value % 1 ~= 0 then
    Support.malformed(kind, "carries its compiled " .. name .. " operand as a whole word")
  end
  return value
end

---@param parameters table<string, unknown> compiled parameter record
---@param name string parameter name
---@param kind string task kind under diagnosis
---@param fallback integer? absent-value fallback
---@return integer value
function Support.count(parameters, name, kind, fallback)
  local value = Support.whole(parameters, name, kind, fallback)
  if value < 0 then
    Support.malformed(kind, "carries a non-negative " .. name .. " operand")
  end
  return value
end

---@param context table<string, unknown> occurrence-bound playback context
---@param kind string task kind under diagnosis
---@return table<string, unknown> occurrence topology
function Support.topology(context, kind)
  local topology = type(context) == "table" and context.topology or nil
  if type(topology) ~= "table" then
    Support.malformed(kind, "reads the occurrence topology")
  end
  return topology --[[@as table<string, unknown>]]
end

---@param record table<string, unknown> battler topology record
---@param kind string task kind under diagnosis
---@return table<string, unknown> addressed role
local function roleOf(record, kind)
  if type(record) ~= "table" or type(record.combatant) ~= "number" then
    Support.malformed(kind, "addresses a presented battler")
  end
  local center = BattleSlotCenters.get(record.slot)
  if center == nil then
    Support.malformed(kind, "addresses a known battler slot")
  end
  center = assert(center)
  local side
  if record.sideType == 1 then
    side = "enemy"
  elseif record.sideType == 0 then
    side = "player"
  elseif type(record.slot) == "string" and record.slot:find("^enemy") ~= nil then
    side = "enemy"
  else
    side = "player"
  end
  local combatant = record.combatant --[[@as integer]]
  return {
    activation = { combatant = combatant, activation = record.activation },
    center = { x = center.x, y = center.y },
    slot = record.slot,
    side = side,
    sideType = record.sideType,
  }
end

---@param context table<string, unknown> occurrence-bound playback context
---@param kind string task kind under diagnosis
---@return table<string, unknown> attacker role
function Support.attacker(context, kind)
  local topology = Support.topology(context, kind)
  return roleOf(topology.attacker --[[@as table<string, unknown>]], kind)
end

---@param context table<string, unknown> occurrence-bound playback context
---@param kind string task kind under diagnosis
---@return table<string, unknown> first defender role
function Support.defender(context, kind)
  local topology = Support.topology(context, kind)
  local targets = topology.targets
  local first = type(targets) == "table" and targets[1] or nil
  return roleOf(first --[[@as table<string, unknown>]], kind)
end

---@param context table<string, unknown> occurrence-bound playback context
---@param kind string task kind under diagnosis
---@return table<integer, table<string, unknown>> every addressed target role
function Support.targets(context, kind)
  local topology = Support.topology(context, kind)
  local targets = topology.targets
  if type(targets) ~= "table" or #targets < 1 then
    Support.malformed(kind, "addresses at least one presented target")
  end
  local roles = {}
  for index, record in ipairs(targets) do
    roles[index] = roleOf(record, kind)
  end
  return roles
end

---@param role table<string, unknown> attacker or defender role
---@return integer sign native side sign, 1 for the player side
function Support.sideSign(role)
  return role.side == "enemy" and -1 or 1
end

---@param role table<string, unknown> attacker or defender role
---@return integer sign native mode side sign, 1 for the player side
function Support.sideSignByMode(role)
  return Support.sideSign(role)
end

-- BattleAnimUtil_GetPicPosition: the presented picture center, falling back
-- to the settled slot center when the picture carries no live patch yet.
---@param scene table<string, unknown> scene behind the run
---@param role table<string, unknown> attacker or defender role
---@return integer x native picture center X
---@return integer y native picture center Y
function Support.pictureCenter(scene, role)
  local state = scene:pictureState(role.activation)
  local x = type(state) == "table" and state.centerX or nil
  local y = type(state) == "table" and state.centerY or nil
  local center = role.center --[[@as { x: integer, y: integer }]]
  return math.floor(type(x) == "number" and x or center.x), math.floor(type(y) == "number" and y or center.y)
end

---@class ConfiguredValueMotion
---@field value integer current whole value
---@field step integer whole step per tick
---@field remaining integer ticks left behind the ramp

-- BattleAnimUtil_InitValueMotion: whole-number interpolation whose step is
-- the native fixed-point step truncated back to whole pixels.
---@param start integer start value
---@param finish integer end value
---@param ticks integer positive tick count
---@return ConfiguredValueMotion value motion
function Support.value(start, finish, ticks)
  local step = math.floor(Timed.fxStep(math.floor(start) * FX, math.floor(finish) * FX, ticks) / FX)
  return {
    value = math.floor(start),
    step = step,
    remaining = math.floor(ticks),
  }
end

---@param motion ConfiguredValueMotion value motion under advancement
---@return boolean active true while the motion had a tick to spend
function Support.stepValue(motion)
  if motion.remaining == 0 then
    return false
  end
  motion.value = motion.value + motion.step
  motion.remaining = motion.remaining - 1
  return true
end

-- BattleAnimUtil_StepTowards: moves one register value toward a target and
-- reports whether it arrived this tick.
---@param current integer current value
---@param target integer target value
---@param step integer positive step
---@return integer value
---@return boolean arrived
function Support.stepTowards(current, target, step)
  local nextValue = current + step
  if step < 0 then
    if nextValue > target then
      return nextValue, false
    end
    return target, true
  end
  if nextValue < target then
    return nextValue, false
  end
  return target, true
end

---@param angle integer 16-bit native angle index
---@return integer sin fixed-point sine
function Support.sinIdx(angle)
  return PresentationFxMath.sinIdx(angle)
end

---@param angle integer 16-bit native angle index
---@return integer cos fixed-point cosine
function Support.cosIdx(angle)
  return PresentationFxMath.cosIdx(angle)
end

---@class ConfiguredSinMotion
---@field duration integer remaining ticks
---@field angleX integer current X angle index
---@field angleY integer current Y angle index
---@field ampX integer fixed-point X amplitude
---@field ampY integer fixed-point Y amplitude
---@field stepX integer X angle step per tick
---@field stepY integer Y angle step per tick
---@field x integer computed whole X
---@field y integer computed whole Y

---@class ConfiguredCosMotion
---@field duration integer remaining ticks
---@field angle integer current angle index
---@field amplitude integer fixed-point amplitude
---@field step integer angle step per tick
---@field value integer computed whole value

-- BattleAnimUtil_InitSinMotion (battle_anim_emitter.c): a two-axis sine
-- whose angles advance by a fixed step and whose fixed-point amplitudes are
-- read back as whole native pixels.
---@param startX integer start X angle index
---@param endX integer finish X angle index
---@param startY integer start Y angle index
---@param endY integer finish Y angle index
---@param ampX integer fixed-point X amplitude
---@param ampY integer fixed-point Y amplitude
---@param ticks integer positive tick count
---@return ConfiguredSinMotion sine motion
function Support.sinMotion(startX, endX, startY, endY, ampX, ampY, ticks)
  local duration = math.max(1, ticks)
  return {
    duration = duration,
    angleX = startX,
    angleY = startY,
    ampX = ampX,
    ampY = ampY,
    stepX = math.floor((endX - startX) / duration),
    stepY = math.floor((endY - startY) / duration),
    x = 0,
    y = 0,
  }
end

---@param motion ConfiguredSinMotion sine motion under advancement
---@return boolean active true while the motion had a tick to spend
function Support.stepSin(motion)
  if motion.duration == 0 then
    return false
  end
  motion.angleX = (motion.angleX + motion.stepX) % 0x10000
  motion.angleY = (motion.angleY + motion.stepY) % 0x10000
  if motion.angleX < 0 then
    motion.angleX = motion.angleX + 0x10000
  end
  if motion.angleY < 0 then
    motion.angleY = motion.angleY + 0x10000
  end
  motion.duration = motion.duration - 1
  motion.x = PresentationFxMath.arithmeticShift(Support.sinIdx(motion.angleX) * motion.ampX, 24)
  motion.y = PresentationFxMath.arithmeticShift(Support.cosIdx(motion.angleY) * motion.ampY, 24)
  return true
end

-- BattleAnimUtil_InitSinMotionFromStep: sine motion whose angle step and
-- duration come from the native step word (rounded up like the source).
---@param startX integer start X angle index
---@param endX integer finish X angle index
---@param startY integer start Y angle index
---@param endY integer finish Y angle index
---@param ampX integer fixed-point X amplitude
---@param ampY integer fixed-point Y amplitude
---@param step integer positive angle step
---@return ConfiguredSinMotion sine motion
function Support.sinFromStep(startX, endX, startY, endY, ampX, ampY, step)
  local signedStep = startX > endX and -step or step
  local span = math.abs(endX - startX)
  local duration = math.max(1, math.ceil(span / step))
  local motion = Support.sinMotion(startX, endX, startY, endY, ampX, ampY, duration)
  motion.stepX = signedStep
  motion.stepY = math.floor((endY - startY) / duration)
  return motion
end

-- BattleAnimUtil_InitCosMotion / UpdateCosMotion: a one-axis cosine value
-- motion used to ease an angle step.
---@param startAngle integer start angle index
---@param endAngle integer finish angle index
---@param amplitude integer fixed-point amplitude
---@param ticks integer positive tick count
---@return ConfiguredCosMotion cosine motion
function Support.cosMotion(startAngle, endAngle, amplitude, ticks)
  local duration = math.max(1, ticks)
  return {
    duration = duration,
    angle = startAngle,
    amplitude = amplitude,
    step = math.floor((endAngle - startAngle) / duration),
    value = 0,
  }
end

---@param motion ConfiguredCosMotion cosine motion under advancement
---@return boolean active true while the motion had a tick to spend
function Support.stepCos(motion)
  if motion.duration == 0 then
    return false
  end
  motion.angle = (motion.angle + motion.step) % 0x10000
  if motion.angle < 0 then
    motion.angle = motion.angle + 0x10000
  end
  motion.duration = motion.duration - 1
  motion.value = PresentationFxMath.arithmeticShift(Support.cosIdx(motion.angle) * motion.amplitude, 24)
  return true
end

---@class ConfiguredLinearSinPath
---@field linear SourceTimedLinearMotion linear path under the arc
---@field sin ConfiguredSinMotion arc motion
---@field x integer current whole X
---@field y integer current whole Y

-- BattleAnimUtil_InitLinearSinMotion / UpdateLinearSinMotion: a linear path
-- with a half-cosine vertical arc layered on top of each step.
---@param startX integer start X in pixels
---@param endX integer finish X in pixels
---@param startY integer start Y in pixels
---@param endY integer finish Y in pixels
---@param ticks integer positive tick count
---@param amplitude integer fixed-point arc amplitude
---@return ConfiguredLinearSinPath path record
function Support.linearSin(startX, endX, startY, endY, ticks, amplitude)
  return {
    linear = Timed.linear(startX, endX, startY, endY, ticks),
    sin = Support.sinMotion(0, 0, 0x3FFF, 0xBFFF, 0, amplitude, ticks),
    x = math.floor(startX),
    y = math.floor(startY),
  }
end

---@param path ConfiguredLinearSinPath linear sine path under advancement
---@return boolean active true while either motion had a tick to spend
function Support.stepLinearSin(path)
  local linearActive = path.linear:step()
  local sinActive = Support.stepSin(path.sin)
  path.x = path.linear.x + path.sin.x
  path.y = path.linear.y + path.sin.y
  if linearActive == sinActive then
    if not linearActive then
      return false
    end
  end
  return true
end

---@param total integer normalized native coefficient total
---@param value integer normalized native coefficient
---@return number alpha normalized alpha behind a native blend coefficient
function Support.blendAlpha(value, total)
  local bound = total or 16
  if bound <= 0 then
    return 1
  end
  return math.max(0, math.min(1, value / bound))
end

-- One authored NANR sequence over its NCER cells: zero-duration frames never
-- paint, and an all-zero sequence shows its first frame for one tick.
---@param frames table<integer, table<string, unknown>> authored frames
---@param kind string task kind under diagnosis
---@param key string animation resource key behind provenance
---@return table<integer, { cell: integer, duration: integer }> walk display frames
local function buildWalk(frames, kind, key)
  local walk = {}
  for _, frame in ipairs(frames) do
    local cell, duration = frame.cell, frame.duration
    if type(cell) ~= "number" or cell % 1 ~= 0 or cell < 0 then
      Support.malformed(kind, "advances normalized sprite frames from " .. key)
    end
    if type(duration) ~= "number" or duration % 1 ~= 0 or duration < 0 then
      Support.malformed(kind, "advances authored sprite durations from " .. key)
    end
    if duration >= 1 then
      walk[#walk + 1] = { cell = cell, duration = duration }
    end
  end
  if #walk == 0 then
    if #frames < 1 then
      Support.malformed(kind, "advances at least one authored sprite frame from " .. key)
    end
    walk[1] = { cell = frames[1].cell, duration = 1 }
  end
  return walk
end

---@param key string resource key behind the staged lease
---@param role string expected lease role
---@param staged table<integer, table<string, unknown>> staged leases
---@param kind string task kind under diagnosis
---@return table<string, unknown> lease behind the role
local function stagedLease(key, role, staged, kind)
  for _, record in ipairs(staged) do
    local lease = record.lease
    if type(lease) == "table" and lease.key == key then
      if lease.kind ~= role then
        Support.malformed(kind, "stages its " .. role .. " role, not " .. tostring(lease.kind))
      end
      return lease --[[@as table<string, unknown>]]
    end
  end
  error("BATTLE_EFFECT_TASK_RESOURCE: kind " .. kind .. " stages no lease for resource " .. key, 0)
end

---@class ConfiguredSpriteBank
---@field characterKey string staged texture role behind strip-band pictures
---@field stripWidth integer staged texture width in pixels behind tile crops
---@field palette table<string, unknown> staged palette lease
---@field cells table<integer, table<string, unknown>> normalized NCER cells
---@field anims table<integer, table<string, unknown>> normalized NANR sequences
---@field walks table<integer, table<integer, { cell: integer, duration: integer }>> lazily built display walks
---@field totals table<integer, integer> lazily summed display durations

---@param kind string configured sprite kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param services table<string, unknown> scene, audio, and resource collaborators
---@return table<string, unknown> scene behind owned transient records
---@return table<integer, table<string, unknown>> staged occurrence leases
---@return table<string, string> decoded resource roles behind the sprite
function Support.stage(kind, args, services)
  local scene = Timed.checkScene(services, kind)
  if type(scene.allocEffect) ~= "function" or type(scene.setEffectPicture) ~= "function" then
    Support.malformed(kind, "draws through a scene with transient effect records")
  end
  local resourceKeys = type(args) == "table" and args.resourceKeys or nil
  if type(resourceKeys) ~= "table" then
    Support.malformed(kind, "configures its four sprite roles")
  end
  resourceKeys = assert(resourceKeys) --[[@as table<string, string>]]
  local staged = {}
  local stageLease = services.stageLease --[[@as function|nil]]
  if type(stageLease) ~= "function" then
    -- The factory owns lease staging; bodies receive it through services.
    Support.malformed(kind, "stages its roles through the resource seam")
  end
  stageLease = assert(stageLease) --[[@as function]]
  for _, role in ipairs(REQUIRED_ROLES) do
    local key = resourceKeys[role]
    if type(key) ~= "string" or key == "" then
      Support.malformed(kind, "names its " .. role .. " resource")
    end
    stageLease(kind, key, services, staged)
  end
  return scene, staged, resourceKeys --[[@as table<string, string>]]
end

-- Validates one enabled NCER object for the picture-layer path: only
-- axis-aligned integer geometry with a staged tile origin is representable,
-- so affine objects fail here instead of drawing unrotated stand-ins.
---@param obj table<string, unknown> normalized cell object under validation
---@param kind string task kind under diagnosis
---@param key string sprite cell resource key behind provenance
local function checkObject(obj, kind, key)
  if obj.affine == true then
    Support.malformed(kind, "draws no affine sprite object from " .. key)
  end
  for _, field in ipairs({ "x", "y", "tile", "width", "height", "priority" }) do
    if type(obj[field]) ~= "number" or obj[field] % 1 ~= 0 then
      Support.malformed(kind, "pictures integer sprite geometry from " .. key)
    end
  end
  if
    obj.tile < 0
    or obj.width < 8
    or obj.width > 64
    or obj.width % 8 ~= 0
    or obj.height < 8
    or obj.height > 64
    or obj.height % 8 ~= 0
  then
    Support.malformed(kind, "pictures native sprite geometry from " .. key)
  end
end

---@param kind string configured sprite kind under construction
---@param resourceKeys table<string, string> decoded resource roles
---@param staged table<integer, table<string, unknown>> staged occurrence leases
---@param context table<string, unknown> occurrence-bound playback context
---@return ConfiguredSpriteBank decoded bank
function Support.decode(kind, resourceKeys, staged, context)
  local _ = context
  local character = stagedLease(resourceKeys.character, "texture", staged, kind)
  local width = character.width
  if type(width) ~= "number" or width % 1 ~= 0 or width < 8 then
    Support.malformed(kind, "draws sprite strips from a sized staged texture")
  end
  local palette = stagedLease(resourceKeys.palette, "palette", staged, kind)
  if type(palette.data) ~= "table" or type(palette.data.colors) ~= "table" then
    Support.malformed(kind, "stages decoded palette records for " .. resourceKeys.palette)
  end
  local cellLease = stagedLease(resourceKeys.cell, "cell", staged, kind)
  if type(cellLease.data) ~= "table" or type(cellLease.data.cells) ~= "table" then
    Support.malformed(kind, "stages decoded cell records for " .. resourceKeys.cell)
  end
  local cells = cellLease.data.cells --[[@as table<integer, table<string, unknown>>]]
  if #cells < 1 then
    Support.malformed(kind, "pictures staged sprite cells from " .. resourceKeys.cell)
  end
  for _, cell in ipairs(cells) do
    if type(cell) ~= "table" or type(cell.objs) ~= "table" then
      Support.malformed(kind, "pictures staged sprite cells from " .. resourceKeys.cell)
    end
    for _, obj in
      ipairs(cell.objs --[[@as table<integer, table<string, unknown>>]])
    do
      if type(obj) == "table" and obj.disabled ~= true then
        checkObject(obj, kind, resourceKeys.cell)
      end
    end
  end
  local animationLease = stagedLease(resourceKeys.animation, "animation", staged, kind)
  local animationData = animationLease.data
  if type(animationData) ~= "table" or type(animationData.anims) ~= "table" then
    Support.malformed(kind, "stages decoded animation records for " .. resourceKeys.animation)
  end
  local anims = animationData.anims --[[@as table<integer, table<string, unknown>>]]
  if #anims < 1 then
    Support.malformed(kind, "advances at least one authored animation from " .. resourceKeys.animation)
  end
  for index, anim in ipairs(anims) do
    if type(anim.frames) ~= "table" or #anim.frames < 1 then
      Support.malformed(kind, "advances authored frames for sequence " .. (index - 1))
    end
  end
  return {
    characterKey = resourceKeys.character,
    stripWidth = width,
    palette = palette,
    cells = cells,
    anims = anims,
    walks = {},
    totals = {},
  }
end

---@param bank ConfiguredSpriteBank decoded bank
---@param animIndex integer one-based animation sequence
---@param kind string task kind under diagnosis
---@return table<integer, { cell: integer, duration: integer }> display walk
local function walkFor(bank, animIndex, kind)
  local walk = bank.walks[animIndex]
  if walk ~= nil then
    return walk
  end
  local anim = bank.anims[animIndex]
  if anim == nil then
    Support.malformed(kind, "selects an authored animation sequence the resource carries")
  end
  anim = assert(anim)
  walk = buildWalk(anim.frames --[[@as table<integer, table<string, unknown>>]], kind, bank.characterKey)
  for _, frame in ipairs(walk) do
    local cell = bank.cells[frame.cell + 1]
    if type(cell) ~= "table" or type(cell.objs) ~= "table" then
      Support.malformed(kind, "pictures staged sprite cell " .. frame.cell)
    end
    cell = assert(cell)
  end
  bank.walks[animIndex] = walk
  return walk
end

---@param bank ConfiguredSpriteBank decoded bank
---@param animIndex integer one-based animation sequence
---@param kind string task kind under diagnosis
---@return integer total authored duration in source ticks
local function totalFor(bank, animIndex, kind)
  local total = bank.totals[animIndex]
  if total ~= nil then
    return total
  end
  total = 0
  for _, frame in ipairs(walkFor(bank, animIndex, kind)) do
    total = total + frame.duration
  end
  bank.totals[animIndex] = total
  return total
end

---@param bank ConfiguredSpriteBank decoded bank
---@param animIndex integer one-based animation sequence
---@param kind string task kind under diagnosis
---@return integer total authored duration in source ticks
function Support.total(bank, animIndex, kind)
  return totalFor(bank, animIndex, kind)
end

---@class ConfiguredSprite
---@field x number native sprite center X
---@field y number native sprite center Y
---@field anim integer one-based authored animation sequence
---@field elapsed number animation frame units advanced
---@field speed number animation frame units per tick while active
---@field auto boolean the native animate flag advances this sprite
---@field frame integer? explicit zero-based frame override
---@field scaleX number horizontal affine scale (1 is native 1.0)
---@field scaleY number vertical affine scale
---@field rotation integer 16-bit native Z rotation index
---@field flipH boolean authored horizontal mirror
---@field flipV boolean authored vertical mirror
---@field alpha number normalized polygon alpha
---@field pivotX number native affine pivot X in pixels
---@field pivotY number native affine pivot Y in pixels
---@field paletteOffset integer native palette override offset in colors
---@field paletteFade table<string, unknown>? native palette blend toward one RGB555 color
---@field hidden boolean draw flag is off
---@field xlu boolean native OAM translucent mode

---@param x number native center X
---@param y number native center Y
---@return ConfiguredSprite sprite
function Support.sprite(x, y)
  return {
    x = x,
    y = y,
    anim = 1,
    elapsed = 0,
    speed = 2,
    auto = false,
    frame = nil,
    scaleX = 1,
    scaleY = 1,
    rotation = 0,
    flipH = false,
    flipV = false,
    alpha = 1,
    pivotX = 0,
    pivotY = 0,
    paletteOffset = 0,
    paletteFade = nil,
    hidden = false,
    xlu = false,
  }
end

---@param sprite ConfiguredSprite sprite under mutation
---@param animIndex integer zero-based authored sequence
---@param bank ConfiguredSpriteBank decoded bank
---@param kind string task kind under diagnosis
function Support.setAnim(sprite, animIndex, bank, kind)
  if type(animIndex) ~= "number" or animIndex % 1 ~= 0 or animIndex < 0 then
    Support.malformed(kind, "selects an authored animation sequence by index")
  end
  if bank.anims[animIndex + 1] == nil then
    Support.malformed(kind, "selects an authored animation sequence the resource carries")
  end
  sprite.anim = animIndex + 1
  sprite.elapsed = 0
  sprite.frame = nil
end

---@param sprite ConfiguredSprite sprite under query
---@param bank ConfiguredSpriteBank decoded bank
---@param kind string task kind under diagnosis
---@return table<integer, { cell: integer, duration: integer }> walk
local function spriteWalk(sprite, bank, kind)
  return walkFor(bank, sprite.anim, kind)
end

---@param sprite ConfiguredSprite sprite under query
---@param bank ConfiguredSpriteBank decoded bank
---@param kind string task kind under diagnosis
---@return integer cell zero-based authored cell
function Support.cellFor(sprite, bank, kind)
  local walk = spriteWalk(sprite, bank, kind)
  local index
  if sprite.frame ~= nil then
    index = math.floor(sprite.frame) + 1
  else
    local elapsed = math.floor(sprite.elapsed)
    local total = 0
    index = #walk
    for position, frame in ipairs(walk) do
      total = total + frame.duration
      if elapsed < total then
        index = position
        break
      end
    end
  end
  if index < 1 then
    index = 1
  elseif index > #walk then
    index = #walk
  end
  return walk[index].cell
end

---@param sprite ConfiguredSprite sprite under query
---@param bank ConfiguredSpriteBank decoded bank
---@param kind string task kind under diagnosis
---@return boolean active true while the authored sequence still runs
function Support.isAnimated(sprite, bank, kind)
  return math.floor(sprite.elapsed) < totalFor(bank, sprite.anim, kind)
end

---@param sprite ConfiguredSprite sprite under advancement
---@param bank ConfiguredSpriteBank decoded bank
---@param kind string task kind under diagnosis
function Support.tickFrame(sprite, bank, kind)
  local total = totalFor(bank, sprite.anim, kind)
  if sprite.elapsed < total then
    sprite.elapsed = math.min(total, sprite.elapsed + 1)
  end
end

---@param sprite ConfiguredSprite sprite under advancement
---@param bank ConfiguredSpriteBank decoded bank
---@param kind string task kind under diagnosis
function Support.autoTick(sprite, bank, kind)
  if not sprite.auto then
    return
  end
  local total = totalFor(bank, sprite.anim, kind)
  if sprite.elapsed < total then
    sprite.elapsed = math.min(total, sprite.elapsed + sprite.speed)
  end
end

-- BattleAnimUtil_StartSpriteAnim: selects sequence 0, restarts it, makes the
-- native animate flag own it, and skips its authored lead-in.
---@param sprite ConfiguredSprite sprite under start
---@param bank ConfiguredSpriteBank decoded bank
---@param kind string task kind under diagnosis
---@param speed number frame units per tick
---@param skip integer frame units to advance immediately
function Support.startSpriteAnim(sprite, bank, kind, speed, skip)
  Support.setAnim(sprite, 0, bank, kind)
  sprite.auto = true
  sprite.speed = speed
  sprite.hidden = false
  local total = totalFor(bank, sprite.anim, kind)
  sprite.elapsed = math.max(0, math.min(total, math.floor(skip or 0)))
end

-- One owned transient sprite body: the native callback machine lives in
-- `advance`, whose sprite records keep their authored animation state between
-- ticks. Writes publish through journaled helpers so completion, cancel, and
-- disposal restore exactly what this body owns.
---@class ConfiguredSpriteBody
---@field _kind string task kind behind the run
---@field _scene table<string, unknown> scene behind every owned write
---@field _bank ConfiguredSpriteBank decoded sprite bank
---@field _staged table<integer, table<string, unknown>> staged occurrence leases
---@field _sprites ConfiguredSprite[] live sprite records behind the draw
---@field _effectIds integer[] owned transient effect identities behind the draw
---@field _advance fun(self: ConfiguredSpriteBody): boolean? native callback step
---@field _patched table<integer, table<string, unknown>> activations this body patched
---@field _compositor boolean the body wrote the animation compositor
---@field _scalar boolean the body wrote the scalar blend patch
---@field _releaseStaged fun(staged: table<integer, table<string, unknown>>) lease release seam
---@field _persist boolean terminal picture patch survives completion
---@field _ticks integer source ticks advanced
---@field _state string pending, running, complete, or cancelled
---@field _cancelReason string? last cancellation cause under diagnosis
---@field _disposed boolean release has run
local Body = {}
Body.__index = Body

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@param fields table<string, unknown> body-specific initial fields
---@param advance fun(self: ConfiguredSpriteBody): boolean? native callback step
---@return ConfiguredSpriteBody runnable body
function Support.newBody(kind, args, context, services, fields, advance)
  local scene, staged, resourceKeys = Support.stage(kind, args, services)
  local ok, bankOrFailure = pcall(Support.decode, kind, resourceKeys, staged, context)
  if not ok then
    services.releaseStaged(staged)
    error(bankOrFailure, 0)
  end
  local body = setmetatable({
    _kind = kind,
    _scene = scene,
    _bank = bankOrFailure --[[@as ConfiguredSpriteBank]],
    _staged = staged,
    _releaseStaged = services.releaseStaged,
    _sprites = {},
    _effectIds = {},
    _advance = advance,
    _patched = {},
    _compositor = false,
    _scalar = false,
    _ticks = 0,
    _state = "pending",
    _disposed = false,
  }, Body)
  for field, value in pairs(fields or {}) do
    body[field] = value
  end
  return body
end

---@return ConfiguredSpriteBank decoded sprite bank
function Body:bank()
  return self._bank
end

---@return table<string, unknown> scene behind the owned writes
function Body:scene()
  return self._scene
end

---@return integer source ticks advanced
function Body:ticks()
  return self._ticks
end

---@param sprites ConfiguredSprite[] sprites behind the next draw
function Body:setSprites(sprites)
  self._sprites = sprites
end

---@param activation table<string, unknown> activation under keying
---@return string
local function activationKey(activation)
  return tostring(activation.combatant) .. ":" .. tostring(activation.activation)
end

---@param activation table<string, unknown> combatant and activation pair
---@param patch table<string, unknown> rendered appearance writes
function Body:publishPicture(activation, patch)
  local scene = self._scene
  local ok, err = pcall(scene.applyTaskPicturePatch, scene, self, activation, patch)
  if not ok then
    self:_restoreOwned()
    error(err, 0)
  end
  local key = activationKey(activation)
  for _, owned in ipairs(self._patched) do
    if activationKey(owned) == key then
      return
    end
  end
  self._patched[#self._patched + 1] = activation
end

---@param patch table<string, unknown> compositor write record
function Body:writeCompositor(patch)
  local scene = self._scene
  if type(scene.writeAnimationCompositor) ~= "function" or type(scene.restoreAnimationCompositor) ~= "function" then
    Support.malformed(self._kind, "fades through the scene compositor seam")
  end
  local ok, err = pcall(scene.writeAnimationCompositor, scene, self, "main", patch)
  if not ok then
    self:_restoreOwned()
    error(err, 0)
  end
  self._compositor = true
end

---@param patch table<string, unknown> scalar register writes
function Body:writeScalar(patch)
  local scene = self._scene
  if type(scene.applyTaskScalarPatch) ~= "function" or type(scene.removeTaskScalarPatch) ~= "function" then
    Support.malformed(self._kind, "blends through the scene scalar seam")
  end
  scene.applyTaskScalarPatch(scene, self, patch)
  self._scalar = true
end

---@param eva integer blend coefficient A
---@param evb integer blend coefficient B
function Body:writeBlend(eva, evb)
  self:writeScalar({ blendCoefficientA = Timed.clampLevel(eva), blendCoefficientB = Timed.clampLevel(evb) })
end

---@param a unknown normalized alpha under clamping
---@return number alpha
local function clampAlpha(a)
  local value = type(a) == "number" and a or 1
  if value < 0 then
    return 0
  elseif value > 1 then
    return 1
  end
  return value
end

-- Publishes one authored cell as 8-pixel strip bands. An affine sprite is
-- built from the same bands: the records already carry the native 1/256
-- scale and 16-bit Z rotation, so the picture pass only has to scale the
-- quad geometry while the UV window keeps the exact authored crop.
---@param body ConfiguredSpriteBody owning body
---@param sprite ConfiguredSprite sprite under publication
---@param index integer one-based sprite ordinal behind selectors
local function publishSprite(body, sprite, index)
  if sprite.hidden then
    return
  end
  local bank = body._bank
  local kind = body._kind
  local cellIndex = Support.cellFor(sprite, bank, kind)
  local cell = bank.cells[cellIndex + 1]
  if type(cell) ~= "table" or type(cell.objs) ~= "table" then
    Support.malformed(kind, "pictures staged sprite cell " .. cellIndex)
  end
  local alpha = clampAlpha(sprite.alpha)
  local cos = Support.cosIdx(sprite.rotation)
  local sin = Support.sinIdx(sprite.rotation)
  local scaleX = sprite.scaleX
  local scaleY = sprite.scaleY
  local scene = body._scene
  for objectIndex, obj in
    ipairs(cell.objs --[[@as table<integer, table<string, unknown>>]])
  do
    if type(obj) == "table" and obj.disabled ~= true then
      checkObject(obj, kind, bank.characterKey)
      local width = obj.width --[[@as integer]]
      local height = obj.height --[[@as integer]]
      local tilesPerRow = math.floor(width / 8)
      local rows = math.floor(height / 8)
      for band = 0, rows - 1 do
        local origin = (obj.tile + band * tilesPerRow) * 8
        if origin < 0 or origin + width > bank.stripWidth then
          error(
            "BATTLE_EFFECT_TASK_RESOURCE: kind " .. kind .. " crops staged sprite tiles from " .. bank.characterKey,
            0
          )
        end
        -- Native ManagedSprite positions the cell at its own center: the
        -- object origin plus half its size is the local offset, scaled about
        -- that center and rotated by the sprite's affine Z word.
        local localX = (obj.x + width / 2) * scaleX
        local localY = (obj.y + band * 8 + 4) * scaleY
        local pivotX = sprite.pivotX * scaleX
        local pivotY = sprite.pivotY * scaleY
        local relativeX = localX - pivotX
        local relativeY = localY - pivotY
        local offsetX = pivotX + (relativeX * cos - relativeY * sin) / FX
        local offsetY = pivotY + (relativeX * sin + relativeY * cos) / FX
        local effectId = scene.allocEffect(scene, "configured-sprite")
        local id = effectId.id --[[@as integer]]
        body._effectIds[#body._effectIds + 1] = id
        scene.setEffectPicture(scene, id, {
          assetKey = bank.characterKey,
          selector = kind .. "/sprite-" .. index .. "/cell-" .. cellIndex .. "/band-" .. band .. "/obj-" .. objectIndex,
          centerX = math.floor(sprite.x + offsetX + 0.5),
          centerY = math.floor(sprite.y + offsetY + 0.5),
          zCenter = -(obj.priority or 0),
          width = width,
          height = 8,
          scaleX = scaleX,
          scaleY = scaleY,
          rotationZ = Support.clampRotation(sprite.rotation),
          alpha = alpha,
          paletteOffset = sprite.paletteOffset,
          paletteFade = sprite.paletteFade,
          xOffset2 = origin,
          yOffset2 = 0,
          flipH = (obj.flipH == true) ~= (sprite.flipH == true),
          flipV = (obj.flipV == true) ~= (sprite.flipV == true),
        })
      end
    end
  end
end

---@param body ConfiguredSpriteBody owning body
local function releaseDraw(body)
  local scene = body._scene
  for _, id in ipairs(body._effectIds) do
    scene.releaseEffect(scene, id)
  end
  body._effectIds = {}
end

---@param body ConfiguredSpriteBody owning body
local function render(body)
  releaseDraw(body)
  for index, sprite in ipairs(body._sprites) do
    publishSprite(body, sprite, index)
  end
end

---@param completed boolean? whether the run reached its own completion
function Body:_restoreOwned(completed)
  releaseDraw(self)
  local scene = self._scene
  local keepPictures = completed == true and self._persist == true
  if not keepPictures then
    for _, activation in ipairs(self._patched) do
      scene.removeTaskPicturePatch(scene, self, activation)
    end
    self._patched = {}
  else
    self._patched = {}
  end
  if self._compositor then
    self._compositor = false
    scene.restoreAnimationCompositor(scene, self, "main")
  end
  if self._scalar then
    self._scalar = false
    scene.removeTaskScalarPatch(scene, self)
  end
  if not self._released then
    self._released = true
    self._releaseStaged(self._staged)
    self._staged = {}
  end
end

---@param tick table<string, unknown>? source tick under advancement
function Body:stepSourceTick(tick)
  local _ = tick
  if self._disposed or self._state == "complete" or self._state == "cancelled" then
    return
  end
  self._state = "running"
  self._ticks = self._ticks + 1
  local ok, retired = pcall(self._advance, self)
  if not ok then
    self:_restoreOwned(false)
    error(retired, 0)
  end
  if retired == true then
    self._state = "complete"
    self:_restoreOwned(true)
    return
  end
  for _, sprite in ipairs(self._sprites) do
    Support.autoTick(sprite, self._bank, self._kind)
  end
  local renderOk, failure = pcall(render, self)
  if not renderOk then
    self:_restoreOwned(false)
    error(failure, 0)
  end
end

---@return string run state
function Body:status()
  assert(Timed.VALID_STATES[self._state] == true, "configured sprite bodies report a known run state")
  return self._state
end

---@param reason string cancellation cause under diagnosis
function Body:cancel(reason)
  if self._state == "complete" then
    return
  end
  self._state = "cancelled"
  self._cancelReason = reason
  self:_restoreOwned(false)
end

function Body:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  if self._state ~= "complete" then
    self:_restoreOwned(false)
  end
end

Support.Body = Body

return Support
