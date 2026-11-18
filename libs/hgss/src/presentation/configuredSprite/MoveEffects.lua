-- Configured-sprite bodies for the battle_anim_move_effects.c callbacks in
-- gBattleAnimSpriteFuncTable: blinking copies, crossing sprites, thrown
-- arcs, sliding pairs, scatter bursts, quads, attacker flashes, and the
-- defender trail. Every phase table and tick boundary is the pinned
-- source's, including the authored data tables in asm/battle_anim_data.s.

local Support = require("libs.hgss.src.presentation.configuredSprite.Support")

local MoveEffects = {}

-- gBattleAnimBlinkScaleFadeTimings / gBattleAnimBlinkCenterTimings.
local BLINK_SCALE_TIMINGS = { { 8, 2 }, { 13, 1 }, { 18, 3 } }
-- gBattleAnimCrossingSpritesScales: startX, endX, startY, endY, duration.
local CROSSING_SCALES = {
  { 100, 100, 100, 70, 8 },
  { 100, 100, 70, 120, 3 },
  { 100, 100, 120, 100, 3 },
}
-- gBattleAnimCrossingSpritesArcSigns: per-round arc signs for both sprites.
local CROSSING_ARC_SIGNS = {
  { 1, -1 },
  { -1, 1 },
  { 1, -1 },
  { 1, -1 },
  { 1, -1 },
}
-- gBattleAnimSlidingSpritePairPositions / Targets / Durations.
local SLIDING_POSITIONS = { { 80, 50 }, { 180, 50 }, { 80, 100 }, { 180, 100 }, { 80, 75 }, { 180, 75 } }
local SLIDING_TARGETS = {
  { { 120, 80 }, { 136, 80 } },
  { { 120, 80 }, { 136, 80 } },
  { { 120, 80 }, { 136, 80 } },
  { { 88, 80 }, { 168, 80 } },
}
local SLIDING_DURATIONS = { 5, 5, 5, 3 }
-- gBattleAnimScatterAreas: x, y, xRange, yRange.
local SCATTER_AREAS = {
  { 30, 40, 50, 53 },
  { 30, 93, 50, 53 },
  { 30, 146, 50, 53 },
  { 80, 40, 50, 53 },
  { 80, 93, 50, 53 },
  { 80, 146, 50, 53 },
}
-- gBattleAnimScatterTargets.
local SCATTER_TARGETS = { { 0, 0 }, { 128, 0 }, { 256, 0 }, { 0, 170 }, { 128, 170 }, { 256, 170 } }

---@param context table<string, unknown> occurrence-bound playback context
---@param kind string task kind under diagnosis
---@return fun(bound: integer): integer draw
local function randomDraw(context, kind)
  local draw = type(context) == "table" and context.random or nil
  if type(draw) ~= "function" then
    Support.malformed(kind, "draws its authored random selection")
  end
  return draw --[[@as fun(bound: integer): integer]]
end

-- BattleAnimSpriteFunc_BlinkScaleFadeSprites (battle_anim_move_effects.c):
-- three (or more) copies blink on their authored timing table, then shrink
-- horizontally 100/100 -> 60/100 and fade the sprite blend out.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newBlinkScaleFade(kind, args, context, services)
  local parameters = Support.parameters(args, kind)
  local count = Support.count(parameters, "spriteCount", kind, 3)
  if count < 1 or count > 8 then
    Support.malformed(kind, "carries its native sprite-copy count")
  end
  local defender = Support.defender(context, kind)
  local center = defender.center
  local sprites = {}
  local blinkTimers = {}
  local visible = {}
  for index = 1, count do
    local sprite = Support.sprite(center.x, center.y + 32 - (index - 1) * 4)
    sprite.xlu = true
    sprite.elapsed = 0
    sprites[index] = sprite
    blinkTimers[index] = 0
    visible[index] = true
  end
  local timer = 0
  local state = "blink"
  local scale = Support.scaleMotion(100, 60, 100, 100, 100, 10)
  local eva, evb = 15, 0
  local function tickAll(bank)
    for _, sprite in ipairs(sprites) do
      Support.tickFrame(sprite, bank, kind)
    end
  end
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local bank = self:bank()
    if state == "blink" then
      timer = timer + 1
      for index = 1, count do
        local timing = BLINK_SCALE_TIMINGS[index] or BLINK_SCALE_TIMINGS[#BLINK_SCALE_TIMINGS]
        local sprite = sprites[index]
        if timer >= timing[1] then
          blinkTimers[index] = blinkTimers[index] + 1
          if blinkTimers[index] >= timing[2] then
            blinkTimers[index] = 0
            visible[index] = not visible[index]
            sprite.hidden = not visible[index]
          end
        else
          visible[index] = false
          sprite.hidden = true
        end
      end
      if timer >= 45 then
        for index = 1, count do
          sprites[index].hidden = false
          visible[index] = true
        end
        timer = 0
        state = "start-scale"
      end
    elseif state == "start-scale" then
      scale = Support.scaleMotion(100, 60, 100, 100, 100, 10)
      state = "scale"
    elseif state == "scale" then
      if scale:step() then
        for index = 1, count do
          sprites[index].scaleX = scale.x / 256
          sprites[index].scaleY = scale.y / 256
        end
      else
        timer = timer + 1
        if timer >= 45 then
          state = "fade"
        end
      end
    elseif state == "fade" then
      eva = math.max(0, eva - 1)
      evb = math.min(15, evb + 1)
      self:writeBlend(eva, evb)
      for _, sprite in ipairs(sprites) do
        sprite.alpha = eva / 15
      end
      if eva == 0 and evb == 15 then
        return true
      end
    end
    tickAll(bank)
    return false
  end
  local body = Support.newBody(kind, args, context, services, {}, advance)
  body:setSprites(sprites)
  return body
end
MoveEffects["sprite-blink-scale-fade"] = newBlinkScaleFade

-- BattleAnimUtil_InitSinMotionFromStep / BattleAnimMotionSprite_Update
-- (battle_anim_move_effects.c): the orbiting motion of one sprite on the
-- two-pixel-scale ellipse; `orbit` and `speed` are copied by value from the
-- source motion when a trail sprite is created.
---@param x number native center X
---@param y number native center Y
---@param orbit table<string, unknown> source sine motion
---@param speed table<string, unknown> source cosine motion
---@param baseAngleStep integer authored base angle step
---@return table<string, unknown> motion sprite
local function newMotionSprite(x, y, orbit, speed, baseAngleStep)
  local sprite = Support.sprite(x, y)
  return {
    sprite = sprite,
    x = x,
    y = y,
    orbit = {
      duration = orbit.duration,
      angleX = orbit.angleX,
      angleY = orbit.angleY,
      ampX = orbit.ampX,
      ampY = orbit.ampY,
      stepX = orbit.stepX,
      stepY = orbit.stepY,
      x = 0,
      y = 0,
    },
    speed = {
      duration = speed.duration,
      angle = speed.angle,
      amplitude = speed.amplitude,
      step = speed.step,
      value = 0,
    },
    baseAngleStep = baseAngleStep,
    state = 0,
    active = false,
  }
end

---@param motionSprite table<string, unknown> motion sprite under advancement
---@return boolean active true while the orbit still runs
local function updateMotionSprite(motionSprite)
  if not motionSprite.active then
    return true
  end
  local sprite = motionSprite.sprite
  if motionSprite.state == 0 or motionSprite.state == 1 then
    if Support.stepSin(motionSprite.orbit) then
      Support.stepCos(motionSprite.speed)
      motionSprite.orbit.stepX = motionSprite.baseAngleStep + motionSprite.speed.value
      sprite.x = motionSprite.x + motionSprite.orbit.x
      sprite.y = motionSprite.y + motionSprite.orbit.y
    else
      if motionSprite.state < 1 then
        if motionSprite.state == 0 then
          motionSprite.orbit = Support.sinFromStep(
            motionSprite.orbit.angleX,
            0x7FFF,
            motionSprite.orbit.angleX,
            0x7FFF,
            motionSprite.orbit.ampX,
            motionSprite.orbit.ampY,
            0x071C
          )
        end
        motionSprite.speed = Support.cosMotion(0, 0xFFFF, -4096, motionSprite.orbit.duration)
      end
      motionSprite.state = motionSprite.state + 1
    end
  elseif motionSprite.state == 2 then
    return false
  end
  return true
end

-- BattleAnimSpriteFunc_OrbitingSpriteTrail (battle_anim_move_effects.c):
-- one main sprite orbits the attacker on a sine ellipse while two trail
-- sprites, released eight ticks apart, follow the same authored orbit; the
-- task then waits for the authored animation and fades the OBJ blend.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newOrbitingTrail(kind, args, context, services)
  local attacker = Support.attacker(context, kind)
  local sign = Support.sideSignByMode(attacker)
  local mainOrbit = Support.sinFromStep(0x3FFF, 0xBFFF, 0x3FFF, 0xBFFF, -(sign * 131072), -8 * Support.FX, 0x071C)
  local mainSpeed = Support.cosMotion(0, 0xFFFF, -4096, mainOrbit.duration)
  local main = newMotionSprite(attacker.center.x, attacker.center.y, mainOrbit, mainSpeed, mainOrbit.stepX)
  main.active = true
  local trails = {
    newMotionSprite(attacker.center.x, attacker.center.y, mainOrbit, mainSpeed, mainOrbit.stepX),
    newMotionSprite(attacker.center.x, attacker.center.y, mainOrbit, mainSpeed, mainOrbit.stepX),
  }
  trails[1].sprite.hidden = true
  trails[2].sprite.hidden = true
  local state = "start"
  local timer = 8
  local index = 0
  local blend = 0
  local function publishBlend(body)
    local eva = 31 - math.floor(blend / 10)
    local evb = math.floor(blend / 10)
    body:writeBlend(eva, evb)
    local alpha = Support.blendAlpha(blend, 310)
    for _, record in ipairs({ main, trails[1], trails[2] }) do
      record.sprite.alpha = alpha
    end
  end
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    if state == "start" then
      updateMotionSprite(main)
      state = "fade-in"
    elseif state == "fade-in" then
      blend = blend + 10
      publishBlend(self)
      if blend >= 310 then
        main.sprite.xlu = false
        state = "reset-blend"
      end
    elseif state == "reset-blend" then
      blend = 310
      publishBlend(self)
      state = "orbit"
    elseif state == "orbit" then
      if timer <= 0 then
        trails[index + 1].active = true
        trails[index + 1].sprite.hidden = false
        index = index + 1
        timer = 8
      end
      if index < 2 then
        timer = timer - 1
      end
      local active = updateMotionSprite(main)
      for trailIndex = 1, 2 do
        local trailActive = updateMotionSprite(trails[trailIndex])
        if not trailActive then
          trails[trailIndex].sprite.hidden = true
        end
        active = active or trailActive
      end
      if not active then
        state = "wait-anim"
      end
    elseif state == "wait-anim" then
      Support.tickFrame(main.sprite, self:bank(), kind)
      if not Support.isAnimated(main.sprite, self:bank(), kind) then
        main.sprite.xlu = true
        state = "fade-out"
      end
    elseif state == "fade-out" then
      blend = math.max(0, blend - 10)
      publishBlend(self)
      if blend <= 0 then
        return true
      end
    end
    return false
  end
  local body = Support.newBody(kind, args, context, services, {}, advance)
  body:setSprites({ main.sprite, trails[1].sprite, trails[2].sprite })
  return body
end
MoveEffects["sprite-orbit-trail"] = newOrbitingTrail

-- BattleAnimSpriteFunc_CrossingSprites (battle_anim_move_effects.c): the
-- defender picture squashes through the pinned scale rounds, the two copies
-- lower into view, fade in, then cross five times on signed arcs before the
-- blend fades out.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newCrossingSprites(kind, args, context, services)
  local parameters = Support.parameters(args, kind)
  local count = Support.count(parameters, "spriteCount", kind, 2)
  if count < 2 or count > 8 then
    Support.malformed(kind, "carries its native sprite-copy count")
  end
  local defender = Support.defender(context, kind)
  local sprites = {}
  for index = 1, count do
    sprites[index] = Support.sprite(defender.center.x, defender.center.y)
    sprites[index].xlu = true
    sprites[index].elapsed = 0
  end
  sprites[1].x, sprites[1].y = 100, 54
  sprites[2].x, sprites[2].y = 180, 39
  local state = "start-scale"
  local round = 0
  local timer = 0
  local scale = Support.scaleMotion(100, 100, 100, 70, 100, 8)
  local eva, evb = 0, 16
  local paths = {} --[[@as table<integer, ConfiguredLinearSinPath>]]
  local distance = 0
  local baseY = defender.center.y
  local function writeScale(body)
    body:publishPicture(defender.activation, {
      affineMode = true,
      affineWidth = scale.x,
      affineHeight = scale.y,
      centerX = defender.center.x,
      centerY = baseY + Support.scaleYOffset(0, scale.curY),
    })
  end
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local bank = self:bank()
    if state == "start-scale" then
      local step = CROSSING_SCALES[round + 1]
      scale = Support.scaleMotion(step[1], step[2], step[3], step[4], 100, step[5])
      round = round + 1
      state = "scale"
    elseif state == "scale" then
      if scale:step() then
        writeScale(self)
      elseif round >= 3 then
        state = "delay"
      else
        state = "start-scale"
      end
    elseif state == "delay" then
      timer = timer + 1
      if timer >= 1 then
        timer = 0
        round = 0
        state = "lower"
      end
    elseif state == "lower" then
      if sprites[1].y <= 104 then
        sprites[1].y = sprites[1].y + 2
        sprites[2].y = sprites[2].y + 2
      else
        state = "fade-in"
      end
    elseif state == "fade-in" then
      if sprites[1].y <= 104 then
        sprites[1].y = sprites[1].y + 2
        sprites[2].y = sprites[2].y + 2
      else
        self:writeBlend(16, 0)
        state = "aim"
      end
      timer = timer + 1
      eva = Support.stepTowards(eva, 16, 16)
      evb = Support.stepTowards(evb, 0, -16)
      self:writeBlend(eva, evb)
      for _, sprite in ipairs(sprites) do
        sprite.alpha = eva / 16
      end
      if timer == 10 then
        sprites[1].y = sprites[1].y + 16
      elseif timer == 12 then
        sprites[2].y = sprites[2].y + 16
      end
    elseif state == "aim" then
      timer = timer + 1
      if timer >= 1 then
        timer = 0
        distance = 40 * Support.FX
        state = "start-cross"
      end
    elseif state == "start-cross" then
      local signs = CROSSING_ARC_SIGNS[round + 1]
      if signs == nil then
        Support.malformed(kind, "walks its five crossing rounds")
      end
      signs = assert(signs)
      paths = {
        Support.linearSin(sprites[1].x, sprites[2].x, sprites[1].y, sprites[2].y, 10, distance * signs[1]),
        Support.linearSin(sprites[2].x, sprites[1].x, sprites[2].y, sprites[1].y, 10, distance * signs[2]),
      }
      round = round + 1
      state = "cross"
    elseif state == "cross" then
      local done = 0
      if not Support.stepLinearSin(paths[1]) then
        done = done + 1
      else
        sprites[1].x, sprites[1].y = paths[1].x, paths[1].y
      end
      if not Support.stepLinearSin(paths[2]) then
        done = done + 1
      else
        sprites[2].x, sprites[2].y = paths[2].x, paths[2].y
      end
      if done == 2 then
        if round == 5 then
          state = "fade-out"
        else
          state = "start-cross"
        end
      end
    elseif state == "fade-out" then
      local evaDone, evbDone
      eva, evaDone = Support.stepTowards(eva, 0, -2)
      evb, evbDone = Support.stepTowards(evb, 16, 2)
      self:writeBlend(eva, evb)
      for _, sprite in ipairs(sprites) do
        sprite.alpha = eva / 16
      end
      if evaDone and evbDone then
        return true
      end
    else
      return true
    end
    if state == "fade-in" or state == "aim" or state == "start-cross" or state == "cross" or state == "fade-out" then
      for _, sprite in ipairs(sprites) do
        Support.tickFrame(sprite, bank, kind)
      end
    end
    return false
  end
  local body = Support.newBody(kind, args, context, services, {}, advance)
  body:setSprites(sprites)
  return body
end
MoveEffects["sprite-crossing"] = newCrossingSprites

-- BattleAnimSpriteFunc_ThrowSpriteArc (battle_anim_move_effects.c): the
-- sprite flies from the attacker picture to the defender picture plus its
-- compiled offset words on a sine arc while rotating ten ticks. The doubles
-- slot-2 -> slot-1 pair mirrors the horizontal sign.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newThrowArc(kind, args, context, services)
  local parameters = Support.parameters(args, kind)
  local offsetX = Support.whole(parameters, "offsetX", kind, 0)
  local offsetY = Support.whole(parameters, "offsetY", kind, 0)
  local duration = Support.count(parameters, "durationTicks", kind, 10)
  local height = Support.whole(parameters, "arcHeight", kind, 0)
  if duration < 1 then
    Support.malformed(kind, "carries a positive flight duration")
  end
  local attacker = Support.attacker(context, kind)
  local defender = Support.defender(context, kind)
  local scene = services.scene
  local attackerX, attackerY = Support.pictureCenter(scene, attacker)
  local defenderX, defenderY = Support.pictureCenter(scene, defender)
  local sign = Support.sideSignByMode(attacker)
  local slotPair = {
    ["player-side-slot-2"] = "player-side-slot-1",
    ["enemy-side-slot-2"] = "enemy-side-slot-1",
  }
  if slotPair[attacker.slot] == defender.slot then
    sign = -sign
  end
  local path = Support.linearSin(
    attackerX,
    defenderX + offsetX * sign,
    attackerY,
    defenderY + offsetY * sign,
    duration,
    height * Support.FX
  )
  local rotation = sign > 0 and Support.value(0x0E38 * sign, 0x5C71 * sign, 10)
    or Support.value(0x3FFF * sign, 0x5C71 * sign, 10)
  local sprite = Support.sprite(path.x, path.y)
  sprite.rotation = sign > 0 and 0x0E38 * sign or 0x3FFF * sign
  -- The native setup advances the path and the authored frame once before
  -- the first task tick.
  Support.stepLinearSin(path)
  sprite.x, sprite.y = path.x, path.y
  local bank = nil --[[@as ConfiguredSpriteBank?]]
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    bank = bank or self:bank()
    bank = assert(bank)
    if not Support.stepLinearSin(path) then
      return true
    end
    sprite.x, sprite.y = path.x, path.y
    if Support.stepValue(rotation) then
      sprite.rotation = rotation.value
    end
    Support.tickFrame(sprite, bank, kind)
    return false
  end
  local body = Support.newBody(kind, args, context, services, {}, advance)
  Support.tickFrame(sprite, body:bank(), kind)
  body:setSprites({ sprite })
  return body
end
MoveEffects["sprite-throw-arc"] = newThrowArc

-- BattleAnimSpriteFunc_BlinkSpritesCenter (battle_anim_move_effects.c): the
-- copies sit at (128, 80), fade in over fifteen ticks, hold forty-five, and
-- fade out. The authored blink timers never write a draw flag in the pinned
-- source, so only the blend machine is observable.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newBlinkCenter(kind, args, context, services)
  local parameters = Support.parameters(args, kind)
  local count = Support.count(parameters, "spriteCount", kind, 2)
  if count < 1 or count > 8 then
    Support.malformed(kind, "carries its native sprite-copy count")
  end
  local attacker = Support.attacker(context, kind)
  local defender = Support.defender(context, kind)
  local animIndex
  if defender.side == "player" then
    animIndex = attacker.side == "player" and 0 or 1
  else
    animIndex = attacker.side == "enemy" and 1 or 0
  end
  local sprites = {}
  for index = 1, count do
    sprites[index] = Support.sprite(128, 80)
    sprites[index].xlu = true
    sprites[index].elapsed = 0
    sprites[index].alpha = 0
  end
  local timer = 0
  local state = "blink"
  local eva, evb = 0, 15
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local bank = self:bank()
    if state == "blink" then
      eva = math.min(15, eva + 1)
      evb = math.max(0, evb - 1)
      self:writeBlend(eva, evb)
      for _, sprite in ipairs(sprites) do
        sprite.alpha = eva / 15
      end
      timer = timer + 1
      if timer >= 45 then
        state = "fade-out"
      end
    elseif state == "fade-out" then
      eva = math.max(0, eva - 1)
      evb = math.min(15, evb + 1)
      self:writeBlend(eva, evb)
      for _, sprite in ipairs(sprites) do
        sprite.alpha = eva / 15
      end
      if eva == 0 and evb == 15 then
        return true
      end
    end
    for _, sprite in ipairs(sprites) do
      Support.tickFrame(sprite, bank, kind)
    end
    return false
  end
  local body = Support.newBody(kind, args, context, services, {}, advance)
  local bank = body:bank()
  for _, sprite in ipairs(sprites) do
    Support.setAnim(sprite, animIndex, bank, kind)
  end
  body:setSprites(sprites)
  return body
end
MoveEffects["sprite-blink-center"] = newBlinkCenter

-- BattleAnimSpriteFunc_SlidingSpritePairs (battle_anim_move_effects.c): six
-- copies start at their authored positions, fade in, slide as four pairs
-- along the pinned target table, then fade out.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newSlidingPairs(kind, args, context, services)
  local parameters = Support.parameters(args, kind)
  local count = Support.count(parameters, "spriteCount", kind, 6)
  if count < 1 or count > 6 then
    Support.malformed(kind, "carries its six native sprite copies")
  end
  local _ = Support.defender(context, kind)
  local sprites = {}
  for index = 1, 6 do
    local position = SLIDING_POSITIONS[index]
    local sprite = Support.sprite(position[1], position[2])
    sprite.auto = true
    sprite.xlu = true
    sprite.elapsed = 0
    sprite.hidden = index ~= 1 and index ~= 4
    sprites[index] = sprite
  end
  local anims = { 0, 0, 1, 1, 2, 3 }
  local state = "fade-in"
  local eva, evb = 0, 15
  local pair = 0
  local first, second = sprites[1], sprites[4]
  local firstMotion = Support.linear(0, 0, 0, 0, 1)
  local secondMotion = Support.linear(0, 0, 0, 0, 1)
  local stopAnimation = false
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local bank = self:bank()
    if state == "fade-in" then
      eva = math.min(15, eva + 1)
      evb = math.max(0, evb - 1)
      self:writeBlend(eva, evb)
      for _, sprite in ipairs(sprites) do
        sprite.alpha = eva / 15
      end
      if eva == 15 and evb == 0 then
        state = "start-pair"
      end
    elseif state == "start-pair" then
      if pair == 0 then
        first, second = sprites[1], sprites[4]
      elseif pair == 1 then
        first, second = sprites[2], sprites[3]
      else
        first, second = sprites[5], sprites[6]
      end
      first.hidden = false
      second.hidden = false
      local targets = SLIDING_TARGETS[pair + 1]
      if targets == nil then
        Support.malformed(kind, "walks its four native slide pairs")
      end
      targets = assert(targets)
      local duration = assert(SLIDING_DURATIONS[pair + 1])
      firstMotion = Support.linear(first.x, targets[1][1], first.y, targets[1][2], duration)
      secondMotion = Support.linear(second.x, targets[2][1], second.y, targets[2][2], duration)
      pair = pair + 1
      state = "slide"
    elseif state == "slide" then
      local done = 0
      if firstMotion:step() then
        first.x, first.y = firstMotion.x, firstMotion.y
      else
        done = done + 1
      end
      if secondMotion:step() then
        second.x, second.y = secondMotion.x, secondMotion.y
      else
        done = done + 1
      end
      if done >= 2 then
        if pair <= 3 then
          first.hidden = true
          second.hidden = true
          state = "start-pair"
        else
          state = "fade-out"
        end
      end
    elseif state == "fade-out" then
      eva = math.max(0, eva - 1)
      evb = math.min(15, evb + 1)
      if evb >= 7 then
        stopAnimation = true
      end
      self:writeBlend(eva, evb)
      for _, sprite in ipairs(sprites) do
        sprite.alpha = eva / 15
      end
      if eva == 0 and evb == 15 then
        return true
      end
    end
    if state ~= "fade-out" and not stopAnimation then
      for _, sprite in ipairs(sprites) do
        Support.tickFrame(sprite, bank, kind)
      end
    end
    return false
  end
  local body = Support.newBody(kind, args, context, services, {}, advance)
  local bank = body:bank()
  for index, sprite in ipairs(sprites) do
    Support.setAnim(sprite, anims[index], bank, kind)
    sprite.flipH = index == 1 or index == 4
  end
  body:setSprites(sprites)
  return body
end
MoveEffects["sprite-sliding-pairs"] = newSlidingPairs

-- BattleAnimSpriteFunc_PopAndScatterSprites (battle_anim_move_effects.c):
-- twelve copies pop in place at staggered random delays, wait for the whole
-- group, then scatter to one of six authored targets.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newPopScatter(kind, args, context, services)
  local draw = randomDraw(context, kind)
  local sprites = {}
  for index = 1, 12 do
    local area = SCATTER_AREAS[((index - 1) % 6) + 1]
    local delay = (index - 1) + (draw(10) + 10)
    local target = draw(6)
    local x = area[1] + draw(area[3])
    local y = area[2] + draw(area[4])
    local sprite = Support.sprite(x, y)
    sprite.hidden = true
    sprite.scaleX, sprite.scaleY = 1, 1
    sprites[index] = {
      sprite = sprite,
      state = 0,
      timer = 0,
      delay = delay,
      target = target,
      scale = 1.0,
      status = 0,
      motion = nil,
      startX = x,
      startY = y,
    }
  end
  local state = "wait-ready"
  local function advanceSprite(record)
    local sprite = record.sprite
    if record.state == 0 then
      record.delay = record.delay - 1
      if record.delay <= 10 then
        record.state = 1
      end
    elseif record.state == 1 then
      record.timer = record.timer + 1
      if record.timer >= 3 then
        sprite.hidden = false
        record.timer = 0
        record.state = 2
      end
    elseif record.state == 2 then
      record.timer = record.timer + 1
      if record.timer <= 3 then
        record.scale = record.scale + 0.1
        sprite.scaleX, sprite.scaleY = record.scale, record.scale
      else
        record.timer = 0
        record.state = 3
      end
    elseif record.state == 3 then
      record.timer = record.timer + 1
      if record.timer <= 3 then
        record.scale = record.scale - 0.1
        sprite.scaleX, sprite.scaleY = record.scale, record.scale
      else
        record.timer = 0
        record.state = 4
      end
    elseif record.state == 4 then
      record.delay = record.delay - 1
      if record.delay <= 10 then
        record.status = 1
        record.timer = 0
        record.state = 5
      end
    elseif record.state == 5 then
      record.timer = record.timer + 1
      if record.timer > 30 then
        record.timer = 0
        record.state = 6
      elseif record.status == 2 then
        record.state = 6
      end
    elseif record.state == 6 then
      local duration = draw(10) + 10
      local target = SCATTER_TARGETS[record.target + 1] or SCATTER_TARGETS[1]
      record.motion = Support.linear(sprite.x, target[1], sprite.y, target[2], duration)
      record.state = 7
    elseif record.state == 7 then
      if record.motion:step() then
        sprite.x, sprite.y = record.motion.x, record.motion.y
      else
        sprite.hidden = true
        record.state = 8
        record.status = 3
      end
    end
    if record.state < 8 then
      Support.tickFrame(sprite, record.bank, kind)
    end
  end
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local bank = self:bank()
    for _, record in ipairs(sprites) do
      record.bank = bank
      advanceSprite(record)
    end
    if state == "wait-ready" then
      local ready = true
      for _, record in ipairs(sprites) do
        if record.status ~= 1 then
          ready = false
          break
        end
      end
      if ready then
        state = "release"
      end
    elseif state == "release" then
      for _, record in ipairs(sprites) do
        record.status = 2
      end
      state = "wait-done"
    elseif state == "wait-done" then
      local done = true
      for _, record in ipairs(sprites) do
        if record.status ~= 3 then
          done = false
          break
        end
      end
      if done then
        return true
      end
    end
    return false
  end
  local body = Support.newBody(kind, args, context, services, {}, advance)
  local spritesList = {}
  for _, record in ipairs(sprites) do
    spritesList[#spritesList + 1] = record.sprite
  end
  body:setSprites(spritesList)
  return body
end
MoveEffects["sprite-pop-scatter"] = newPopScatter

-- BattleAnimSpriteFunc_SpriteQuad (battle_anim_move_effects.c): four copies
-- sit around the defender at the pinned offsets, tick their authored frames
-- (the lower pair starts ten ticks later), and disappear after forty ticks.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newSpriteQuad(kind, args, context, services)
  local defender = Support.defender(context, kind)
  local offsets = { { -32, 0 }, { -32, 32 }, { 32, 0 }, { 32, 32 } }
  local sprites = {}
  for index, offset in ipairs(offsets) do
    local sprite = Support.sprite(defender.center.x + offset[1], defender.center.y + offset[2])
    sprite.elapsed = 0
    sprites[index] = sprite
  end
  sprites[1].flipH = true
  sprites[2].flipH = true
  local delay = 10
  local timers = { 0, 0, 0, 0 }
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local bank = self:bank()
    if delay <= 0 then
      if not sprites[3].hidden then
        Support.tickFrame(sprites[3], bank, kind)
      end
      if not sprites[4].hidden then
        Support.tickFrame(sprites[4], bank, kind)
      end
    else
      delay = delay - 1
    end
    if not sprites[1].hidden then
      Support.tickFrame(sprites[1], bank, kind)
    end
    if not sprites[2].hidden then
      Support.tickFrame(sprites[2], bank, kind)
    end
    local hidden = 0
    for index = 1, 4 do
      timers[index] = timers[index] + 1
      if timers[index] >= 40 then
        sprites[index].hidden = true
        hidden = hidden + 1
      end
    end
    return hidden == 4
  end
  local body = Support.newBody(kind, args, context, services, {}, advance)
  body:setSprites(sprites)
  return body
end
MoveEffects["sprite-quad"] = newSpriteQuad

-- BattleAnimSpriteFunc_FlashingSpritesAroundAttacker
-- (battle_anim_move_effects.c): four copies flash around the attacker
-- picture, their palettes pulse six times between ticks 50 and 108, and the
-- OBJ blend fades them out from tick 110.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newFlashAroundAttacker(kind, args, context, services)
  local draw = randomDraw(context, kind)
  local attacker = Support.attacker(context, kind)
  local centerX = attacker.center.x
  local centerY = attacker.side == "player" and 140 or 84
  local offsets = { { -32, 0 }, { 40, 4 }, { 32, 0 }, { -40, 4 } }
  local sprites = {}
  local timers = {}
  for index = 1, 4 do
    local sprite = Support.sprite(centerX + offsets[index][1], centerY + offsets[index][2])
    sprite.xlu = true
    sprite.elapsed = 0
    sprites[index] = sprite
    timers[index] = index == 1 and 0 or (5 * (index - 1) + draw(4))
  end
  sprites[2].flipH = true
  sprites[3].flipH = true
  local eva, evb = nil, nil
  local flashing = false
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local bank = self:bank()
    for index = 1, 4 do
      timers[index] = timers[index] + 1
      if timers[index] >= 20 then
        if not sprites[index].hidden then
          Support.tickFrame(sprites[index], bank, kind)
        end
      end
    end
    local main = timers[1]
    local flash = nil
    if main >= 50 and main <= 108 then
      local phase = math.floor((main - 50) / 10)
      local localTick = (main - 50) % 10
      if localTick <= 7 then
        flash = phase % 2 == 0 and localTick * 2 or 14 - localTick * 2
      else
        flash = 0
      end
    end
    for _, sprite in ipairs(sprites) do
      if flash ~= nil and flash > 0 then
        sprite.paletteFade = { applied = true, intensity = flash, targetColor = 0x7FFF }
      else
        sprite.paletteFade = nil
      end
    end
    if main == 110 and not flashing then
      flashing = true
      eva, evb = 15, 0
      for _, sprite in ipairs(sprites) do
        sprite.xlu = true
      end
    end
    if flashing and eva ~= nil then
      eva = math.max(0, eva - 1)
      evb = math.min(15, evb + 1)
      self:writeBlend(eva, evb)
      for _, sprite in ipairs(sprites) do
        sprite.alpha = eva / 15
      end
      if eva == 0 and evb == 15 then
        return true
      end
    end
    return false
  end
  local body = Support.newBody(kind, args, context, services, {}, advance)
  body:setSprites(sprites)
  return body
end
MoveEffects["sprite-flash-around-attacker"] = newFlashAroundAttacker

-- BattleAnimSpriteFunc_SpriteTrailToDefender (battle_anim_move_effects.c):
-- eight copies are parked on every other step of a 20-tick attacker-to-
-- defender path, then each starts its authored animation after its own
-- stagger and hides at tick 160.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newTrailToDefender(kind, args, context, services)
  local attacker = Support.attacker(context, kind)
  local defender = Support.defender(context, kind)
  local path = Support.linear(attacker.center.x, defender.center.x, attacker.center.y, defender.center.y, 20)
  local sprites = {}
  local skip = attacker.side == "enemy"
  local frame = 0
  local count = 0
  while count < 8 do
    local active = path:step()
    if frame % 2 == 1 then
      if not skip then
        if count < 8 then
          sprites[count + 1] = Support.sprite(path.x, path.y)
          sprites[count + 1].elapsed = 0
          count = count + 1
        end
      else
        skip = false
      end
    end
    frame = frame + 1
    if not active then
      break
    end
  end
  while count < 8 do
    count = count + 1
    sprites[count] = Support.sprite(defender.center.x, defender.center.y)
  end
  for index = 2, 8 do
    if index % 2 == 0 then
      sprites[index].flipH = true
    end
  end
  local timers = {}
  for index = 1, 8 do
    timers[index] = (8 - (index - 1)) * 4
  end
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local bank = self:bank()
    local hidden = 0
    for index = 1, 8 do
      timers[index] = timers[index] + 1
      if timers[index] >= 32 then
        if not sprites[index].hidden then
          Support.tickFrame(sprites[index], bank, kind)
        end
        if timers[index] >= 160 then
          sprites[index].hidden = true
          hidden = hidden + 1
        end
      end
    end
    return hidden == 8
  end
  local body = Support.newBody(kind, args, context, services, {}, advance)
  body:setSprites(sprites)
  return body
end
MoveEffects["sprite-trail-to-defender"] = newTrailToDefender

return MoveEffects
