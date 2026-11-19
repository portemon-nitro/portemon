-- Configured-sprite bodies for the battle_anim_effects.c callbacks in
-- gBattleAnimSpriteFuncTable: grown/rocked sprites, stacks on the defender,
-- boomerangs, rising stretches, brightness pulses, attacker fans, shrink-
-- into-sprite, defender scaling, orbiting copies, floating streams, palette
-- cycles, and the zigzag flash. Phase tables and tick boundaries mirror the
-- pinned source routines and their battle_anim_util.c helpers.

local Support = require("libs.hgss.src.presentation.configuredSprite.Support")

local Effects = {}

---@param sprite ConfiguredSprite sprite under draw
---@param scale table<string, unknown> scale motion under application
local function applyScale(sprite, scale)
  sprite.scaleX = scale.x / 256
  sprite.scaleY = scale.y / 256
end

-- BattleAnimSpriteFunc_GrowRockShrinkSprite (battle_anim_effects.c): grow
-- 1/10 -> 10/10, rock through five value motions, then shrink back to 1/10.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newGrowRockShrink(kind, args, context, services)
  local attacker = Support.attacker(context, kind)
  local direction = Support.sideSignByMode(attacker)
  local sprite = Support.sprite(attacker.center.x + direction * 40, attacker.center.y)
  sprite.pivotX, sprite.pivotY = -direction * 12, 12
  local animIndex = attacker.side == "enemy" and 1 or 0
  local state = "grow"
  local scale = Support.scaleMotion(1, 10, 1, 10, 10, 8)
  local rotation = direction >= 0 and Support.value(0xFF48, 0xE38D, 4) or Support.value(0, 0x1C71, 4)
  local prevRotation = direction >= 0 and 0xFF48 or 0
  local rocks = 5
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local _ = self
    if state == "grow" then
      if scale:step() then
        sprite.scaleX = scale.x / 256
        sprite.scaleY = scale.y / 256
      else
        state = "rock"
        rocks = 5
        scale = Support.scaleMotion(10, 1, 10, 1, 10, 8)
      end
    elseif state == "rock" then
      local active = Support.stepValue(rotation)
      sprite.rotation = rotation.value
      if not active then
        if rocks > 0 then
          rocks = rocks - 1
          local current = rotation.value
          local previous = prevRotation
          prevRotation = current
          rotation = Support.value(current, previous, 4)
        else
          state = "shrink"
        end
      end
    elseif state == "shrink" then
      if scale:step() then
        sprite.scaleX = scale.x / 256
        sprite.scaleY = scale.y / 256
      else
        return true
      end
    end
    return false
  end
  local body = Support.newBody(kind, args, context, services, {}, advance)
  Support.setAnim(sprite, animIndex, body:bank(), kind)
  body:setSprites({ sprite })
  return body
end
Effects["sprite-grow-rock-shrink"] = newGrowRockShrink

-- BattleAnimScaleSprite_* (battle_anim_effects.c): one growing/shrinking
-- copy whose authored 1.0 -> 0.8 -> 1.0 repeats three times.
---@param sprite ConfiguredSprite sprite under animation
---@return table<string, unknown> scale sprite record
local function newScaleSprite(sprite)
  return {
    sprite = sprite,
    scale = Support.scaleMotion(10, 8, 10, 8, 10, 8),
    repeats = 3,
    start = 8,
    finish = 10,
    flip = false,
  }
end

---@param record table<string, unknown> scale sprite under advancement
---@return boolean active true while the shape still runs
local function updateScaleSprite(record)
  if record.scale:step() then
    local sprite = record.sprite
    sprite.scaleX = record.flip and -record.scale.x / 256 or record.scale.x / 256
    sprite.scaleY = 1
  elseif record.repeats > 0 then
    record.repeats = record.repeats - 1
    record.scale = Support.scaleMotion(record.start, record.finish, record.start, record.finish, 10, 8)
    local swap = record.start
    record.start = record.finish
    record.finish = swap
  else
    return false
  end
  return true
end

-- BattleAnimSpriteFunc_StackedSpritesOnDefender (battle_anim_effects.c):
-- four copies stack ten pixels apart over the defender, shake the picture,
-- then pulse their scales three times.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newStackOnDefender(kind, args, context, services)
  local defender = Support.defender(context, kind)
  local records = {}
  local sprites = {}
  local y = defender.center.y + 16
  for index = 1, 4 do
    local sprite = Support.sprite(defender.center.x, y)
    sprite.hidden = true
    local record = newScaleSprite(sprite)
    record.flip = index % 2 == 0
    if record.flip then
      sprite.scaleX = -1
    end
    records[index] = record
    sprites[index] = sprite
    y = y - 10
  end
  local state = "show"
  local timer = 0
  local shown = 0
  local shake = Support.shake(4, 0, 1, 1)
  local baseX, baseY = defender.center.x, defender.center.y
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    if state == "show" then
      if timer >= 4 then
        timer = 0
        records[shown + 1].sprite.hidden = false
        records[shown + 1].sprite.auto = true
        shown = shown + 1
        if shown >= 4 then
          state = "shake"
        end
      end
      timer = timer + 1
    elseif state == "shake" then
      if shake:step() then
        self:publishPicture(defender.activation, {
          centerX = baseX + shake.x,
          centerY = baseY + shake.y,
        })
      else
        state = "scale"
      end
    elseif state == "scale" then
      local active = true
      for _, record in ipairs(records) do
        active = updateScaleSprite(record)
      end
      if not active then
        return true
      end
    end
    return false
  end
  local body = Support.newBody(kind, args, context, services, {}, advance)
  body:setSprites(sprites)
  return body
end
Effects["sprite-stack-on-defender"] = newStackOnDefender

-- BattleAnimSpriteFunc_BoomerangSprite (battle_anim_effects.c): the attacker
-- picture leans, the sprite flies on a signed arc to the defender and back,
-- then the picture recovers.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newBoomerang(kind, args, context, services)
  local attacker = Support.attacker(context, kind)
  local defender = Support.defender(context, kind)
  local direction = Support.sideSignByMode(attacker)
  local attackerX, attackerY = attacker.center.x, attacker.center.y
  local defenderX, defenderY = defender.center.x, defender.center.y
  local lean = Support.linear(0, direction * -16, 0, 0, 4)
  local arc = Support.linearSin(attackerX, defenderX, attackerY, defenderY, 10, 2 * 65536)
  local sprite = Support.sprite(attackerX, attackerY)
  sprite.hidden = true
  local state = "lean-back"
  local function publishLean(body)
    body:publishPicture(attacker.activation, {
      centerX = attackerX + lean.x,
      centerY = attackerY + lean.y,
    })
  end
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    if state == "lean-back" then
      if lean:step() then
        publishLean(self)
      else
        lean = Support.linear(lean.x, 0, 0, 0, 2)
        state = "lean-return"
      end
      return false
    elseif state == "lean-return" then
      if lean:step() then
        publishLean(self)
      else
        self:publishPicture(attacker.activation, { centerX = attackerX, centerY = attackerY })
        lean = Support.linear(0, -(direction * 32), 0, 0, 4)
        state = "throw"
      end
      return false
    elseif state == "throw" then
      if Support.stepLinearSin(arc) then
        sprite.x, sprite.y = arc.x, arc.y
        sprite.hidden = false
        sprite.auto = true
      else
        arc = Support.linearSin(defenderX, attackerX, defenderY, attackerY, 10, -2 * 65536)
        state = "come-back"
      end
    elseif state == "come-back" then
      if Support.stepLinearSin(arc) then
        sprite.x, sprite.y = arc.x, arc.y
      else
        sprite.hidden = true
        state = "catch"
      end
    elseif state == "catch" then
      if lean:step() then
        publishLean(self)
      else
        lean = Support.linear(lean.x, 0, 0, 0, 4)
        state = "recover"
      end
    elseif state == "recover" then
      if lean:step() then
        publishLean(self)
      else
        self:publishPicture(attacker.activation, { centerX = attackerX, centerY = attackerY })
        return true
      end
    end
    return false
  end
  local body = Support.newBody(kind, args, context, services, {}, advance)
  body:setSprites({ sprite })
  return body
end
Effects["sprite-boomerang"] = newBoomerang

-- BattleAnimSpriteFunc_RisingSpriteStretchAttacker (battle_anim_effects.c):
-- the attacker picture stretches vertically to 1.5 and back while the sprite
-- rises 32 pixels, shrinks in, and fades the OBJ blend out.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newRiseStretch(kind, args, context, services)
  local attacker = Support.attacker(context, kind)
  local dirX = Support.sideSignByMode(attacker)
  local dirY = Support.sideSign(attacker)
  local baseX, baseY = attacker.center.x, attacker.center.y
  local picScale = Support.scaleMotion(10, 15, 10, 15, 10, 12)
  local picState = "stretch"
  local spriteX = baseX + dirX * 32
  local spriteY = baseY
  local rise = Support.linear(0, 0, 0, (dirY < 0 and -8 or -24) * dirY, 32)
  local spriteScale = Support.scaleMotion(5, 12, 5, 12, 10, 32)
  local sprite = Support.sprite(spriteX, spriteY)
  sprite.auto = true
  sprite.xlu = true
  local blend = Support.linear(0, 0, 0, 0, 1)
  local state = "run"
  local function publishPic(body)
    body:publishPicture(attacker.activation, {
      affineMode = true,
      affineWidth = 256,
      affineHeight = picScale.y,
      centerX = baseX,
      centerY = baseY,
    })
  end
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    if state == "run" then
      if picState == "stretch" then
        if picScale:step() then
          publishPic(self)
        else
          picState = "restore"
          picScale = Support.scaleMotion(15, 10, 15, 10, 10, 12)
        end
      elseif picState == "restore" then
        if picScale:step() then
          publishPic(self)
        else
          self:publishPicture(attacker.activation, {
            affineMode = true,
            affineWidth = 256,
            affineHeight = 256,
            centerX = baseX,
            centerY = baseY,
          })
          picState = "done"
        end
      end
      if spriteScale:step() then
        applyScale(sprite, spriteScale)
      end
      if rise:step() then
        sprite.x = spriteX + rise.x
        sprite.y = spriteY + rise.y
      else
        blend = Support.linear(16, 0, 14, 16, 8)
        state = "fade"
      end
    elseif state == "fade" then
      if blend:step() then
        self:writeBlend(blend.x, blend.y)
        sprite.alpha = math.max(0, math.min(1, blend.x / 16))
      else
        sprite.hidden = true
        return true
      end
    end
    return false
  end
  local body = Support.newBody(kind, args, context, services, {}, advance)
  body:setSprites({ sprite })
  return body
end
Effects["sprite-rise-stretch"] = newRiseStretch

-- BattleAnimSpriteFunc_PulseSpriteBrightnessFlash (battle_anim_effects.c):
-- four shrinking pulse rounds scale the sprite, then a screen-brightness
-- flash plays its authored animation and fades out.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newPulseBrightness(kind, args, context, services)
  local defender = Support.defender(context, kind)
  local sprite = Support.sprite(defender.center.x, defender.center.y)
  sprite.xlu = true
  sprite.elapsed = 0
  sprite.frame = 4
  local repeats = 3
  local duration = 400
  local scaleA = 1500
  local scaleB = 1000
  local round = "start"
  local pulseState = "grow"
  local pulseCount = 0
  local scale = Support.scaleMotion(15, 10, 15, 10, 10, 4)
  local blend = Support.linear(16, 10, 0, 6, 8)
  local state = "pulse"
  local timer = 30
  local brightness = 0
  local brightnessTicks = 0
  local flashBlend = Support.linear(0, 16, 16, 0, 4)
  local outBlend = Support.linear(16, 0, 0, 16, 8)
  local function startRound()
    local startScale = math.floor(scaleA / 100)
    local endScale = math.floor(scaleB / 100)
    local ticks = math.floor(duration / 100)
    scale = Support.scaleMotion(startScale, endScale, startScale, endScale, 10, ticks)
    blend = Support.linear(16, 10, 0, 6, ticks * 2)
    pulseState = "grow"
    pulseCount = 0
  end
  local function publishBlend(body, motion)
    body:writeBlend(motion.x, motion.y)
    sprite.alpha = math.max(0, math.min(1, motion.x / 16))
  end
  local function updatePulse(self)
    local blendActive = blend:step()
    if blendActive then
      publishBlend(self, blend)
    end
    if pulseState == "grow" then
      if scale:step() then
        applyScale(sprite, scale)
      else
        local startScale = math.floor(scaleB / 100)
        local endScale = math.floor(scaleA / 100)
        scale = Support.scaleMotion(startScale, endScale, startScale, endScale, 10, math.floor(duration / 100))
        pulseState = "shrink"
      end
      return false
    elseif pulseState == "shrink" then
      if scale:step() then
        applyScale(sprite, scale)
      else
        pulseCount = pulseCount + 1
        if pulseCount < 2 then
          pulseState = "grow"
          local startScale = math.floor(scaleA / 100)
          local endScale = math.floor(scaleB / 100)
          scale = Support.scaleMotion(startScale, endScale, startScale, endScale, 10, math.floor(duration / 100))
        else
          pulseState = "wait"
        end
      end
      return false
    elseif pulseState == "wait" then
      if blendActive then
        return false
      end
      pulseState = "done"
      return true
    end
    return true
  end
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    if state == "pulse" then
      if round == "start" then
        startRound()
        self:writeBlend(16, 0)
        sprite.alpha = 1
        updatePulse(self)
        round = "update"
      elseif updatePulse(self) then
        repeats = repeats - 1
        if repeats >= 0 then
          duration = duration - math.floor(duration / 3)
          scaleA = scaleA - math.floor(scaleA / 3)
          scaleB = scaleB - math.floor(scaleB / 3)
          round = "start"
        else
          state = "flash"
          timer = 30
          Support.setAnim(sprite, 0, self:bank(), kind)
          sprite.auto = true
          sprite.speed = 2
          sprite.scaleX, sprite.scaleY = 1, 1
          flashBlend = Support.linear(0, 16, 16, 0, 4)
        end
      end
    elseif state == "flash" then
      if flashBlend:step() then
        publishBlend(self, flashBlend)
      end
      if timer == 0 then
        brightness = 0
        brightnessTicks = 0
        timer = -1
      elseif timer > 0 then
        timer = timer - 1
      end
      if timer == -1 then
        if brightnessTicks <= 8 then
          brightnessTicks = brightnessTicks + 1
          brightness = math.min(16, brightnessTicks * 2)
          self:writeCompositor({ brightness = { mode = "up", coefficient = brightness } })
        elseif brightnessTicks <= 16 then
          brightnessTicks = brightnessTicks + 1
          brightness = math.max(0, 16 - (brightnessTicks - 8) * 2)
          self:writeCompositor({ brightness = { mode = "down", coefficient = brightness } })
        end
      end
      if not Support.isAnimated(sprite, self:bank(), kind) then
        state = "wait-brightness"
      end
    elseif state == "wait-brightness" then
      if brightnessTicks > 16 then
        state = "fade-out"
        self:writeBlend(16, 0)
        sprite.alpha = 1
        outBlend = Support.linear(16, 0, 0, 16, 8)
      else
        brightnessTicks = brightnessTicks + 1
        brightness = math.max(0, 16 - (brightnessTicks - 8) * 2)
        self:writeCompositor({ brightness = { mode = "down", coefficient = brightness } })
      end
    elseif state == "fade-out" then
      if outBlend:step() then
        publishBlend(self, outBlend)
      else
        sprite.hidden = true
        return true
      end
    end
    return false
  end
  local body = Support.newBody(kind, args, context, services, {}, advance)
  body:setSprites({ sprite })
  return body
end
Effects["sprite-pulse-brightness"] = newPulseBrightness

-- BattleAnimTask_FanSpritesStartAttackerPulse / UpdateAttackerPulse: the
-- attacker picture pulses 10/10 -> 9/8 -> 11/15 -> 10/10 around each fan
-- sprite's appearance.
---@param attacker table<string, unknown> attacker role
---@param baseY integer picture baseline
---@return table<string, unknown> pulse record
local function newFanPulse(attacker, baseY)
  return {
    role = attacker,
    baseY = baseY,
    state = "widen",
    motion = Support.scaleMotion(10, 9, 10, 8, 10, 2),
  }
end

---@param body ConfiguredSpriteBody owning body
---@param pulse table<string, unknown> pulse record under advancement
---@return boolean done true when the picture returned to 10/10
local function updateFanPulse(body, pulse)
  local function publish()
    body:publishPicture(pulse.role.activation, {
      affineMode = true,
      affineWidth = pulse.motion.x,
      affineHeight = pulse.motion.y,
      centerX = pulse.role.center.x,
      centerY = Support.alignY(pulse.baseY, 0, pulse.motion.curY, 0),
    })
  end
  if pulse.state == "widen" then
    if pulse.motion:step() then
      publish()
    else
      pulse.state = "stretch"
      pulse.motion = Support.scaleMotion(9, 11, 8, 15, 10, 2)
    end
    return false
  elseif pulse.state == "stretch" then
    if pulse.motion:step() then
      publish()
    else
      pulse.state = "restore"
      pulse.motion = Support.scaleMotion(11, 10, 15, 10, 10, 2)
    end
    return false
  elseif pulse.state == "restore" then
    if pulse.motion:step() then
      publish()
      return false
    end
    body:publishPicture(pulse.role.activation, {
      affineMode = true,
      affineWidth = 256,
      affineHeight = 256,
      centerX = pulse.role.center.x,
      centerY = pulse.baseY,
    })
    pulse.state = "done"
    return true
  end
  return true
end

-- BattleAnimSpriteFunc_FanSpritesAroundAttacker (battle_anim_effects.c):
-- six copies fan around the attacker picture, each released two at a time
-- with its own picture pulse, then all play their exit animation.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newFanAroundAttacker(kind, args, context, services)
  local attacker = Support.attacker(context, kind)
  local spriteX, spriteY = attacker.center.x, attacker.center.y
  local sprites = {}
  local timers = {}
  for i = 0, 5 do
    local angle = math.floor(i / 2) * 0x1555
    local dx = math.floor(Support.cosIdx(angle) * 48 / Support.FX + 0.5)
    local dy = math.floor(Support.sinIdx(angle) * 48 / Support.FX + 0.5)
    local x = spriteX
    if i % 2 == 0 then
      x = spriteX + dx
    else
      x = spriteX - dx
    end
    local sprite = Support.sprite(x, spriteY - dy)
    sprite.hidden = true
    if i % 2 == 0 then
      sprite.flipH = true
    end
    sprites[i + 1] = sprite
    timers[i + 1] = i < 2 and 8 or 0
  end
  local index = 0
  local state = "start-sprite"
  local pulse = nil --[[@as table<string, unknown>]]
  local pulseDone = false
  local function startSprite(self, target)
    pulse = newFanPulse(attacker, attacker.center.y)
    pulseDone = false
    Support.startSpriteAnim(target, self:bank(), kind, 2, 55)
    state = "wait-sprite"
  end
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local bank = self:bank()
    if state == "start-sprite" then
      startSprite(self, sprites[index + 1])
    elseif state == "wait-sprite" then
      pulse = assert(pulse)
      pulseDone = updateFanPulse(self, pulse) or pulseDone
      local animDone = not Support.isAnimated(sprites[index + 1], bank, kind)
      if pulseDone and animDone then
        Support.setAnim(sprites[index + 1], 1, bank, kind)
        state = "delay"
      end
    elseif state == "delay" then
      timers[index + 1] = timers[index + 1] - 1
      if timers[index + 1] < 0 then
        index = index + 1
        if index < 6 then
          state = "start-sprite"
        else
          state = "start-exit"
        end
      end
    elseif state == "start-exit" then
      for i = 1, 6 do
        Support.startSpriteAnim(sprites[i], bank, kind, 2, 55)
      end
      state = "wait-exit"
    elseif state == "wait-exit" then
      local done = false
      for i = 1, 6 do
        done = not Support.isAnimated(sprites[i], bank, kind)
      end
      if done then
        return true
      end
    end
    return false
  end
  local body = Support.newBody(kind, args, context, services, {}, advance)
  body:setSprites(sprites)
  return body
end
Effects["sprite-fan-around-attacker"] = newFanAroundAttacker

-- BattleAnimSpriteFunc_ShrinkAttackerIntoSprite (battle_anim_effects.c): the
-- sprite plays its open animation, the attacker picture shrinks and moves
-- into it, the sprite closes and leaves the screen.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newShrinkAttacker(kind, args, context, services)
  local attacker = Support.attacker(context, kind)
  local baseX, baseY = attacker.center.x, attacker.center.y
  local sprite = Support.sprite(baseX, baseY)
  sprite.auto = true
  local state = "start-anim"
  local scale = Support.scaleMotion(10, 0, 10, 0, 10, 8)
  local move = Support.linear(0, 0, 0, 0, 1)
  local leave = Support.linear(0, 0, 0, 0, 1)
  local picX, picY = baseX, baseY
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local bank = self:bank()
    if state == "start-anim" then
      sprite.auto = true
      state = "wait-anim"
    elseif state == "wait-anim" then
      if not Support.isAnimated(sprite, bank, kind) then
        sprite.auto = false
        state = "shrink"
        scale = Support.scaleMotion(10, 0, 10, 0, 10, 8)
        move = Support.linear(picX, math.floor(sprite.x), picY, math.floor(sprite.y), 8)
      end
    elseif state == "shrink" then
      if move:step() then
        picX, picY = move.x, move.y
      end
      local active = scale:step()
      self:publishPicture(attacker.activation, {
        affineMode = true,
        affineWidth = scale.x,
        affineHeight = scale.y,
        centerX = picX,
        centerY = picY,
      })
      if not active then
        self:publishPicture(attacker.activation, {
          affineMode = true,
          affineWidth = 256,
          affineHeight = 256,
          centerX = picX,
          centerY = picY,
          vanished = true,
          pictureVisible = false,
        })
        self._persist = true
        Support.setAnim(sprite, 1, bank, kind)
        sprite.auto = true
        sprite.speed = 1
        state = "wait-close"
      end
    elseif state == "wait-close" then
      if not Support.isAnimated(sprite, bank, kind) then
        sprite.auto = false
        state = "leave"
        leave = Support.linear(0, 0, math.floor(sprite.y), 0, 8)
      end
    elseif state == "leave" then
      if leave:step() then
        sprite.y = leave.y
      else
        return true
      end
    end
    return false
  end
  local body = Support.newBody(kind, args, context, services, {}, advance)
  body:setSprites({ sprite })
  return body
end
Effects["sprite-shrink-attacker-into"] = newShrinkAttacker

-- BattleAnimUtil_UpdateSpriteSequence (battle_anim_util.c): one sprite is
-- shown every interval, each carrying its own copy of the source motion.
---@param sequence table<string, unknown> sprite sequence under advancement
---@return boolean active true while a copy still runs
local function updateSequence(sequence)
  local active = { true, true, true, true }
  if sequence.interval <= sequence.timer then
    sequence.sprites[sequence.started + 1].hidden = false
    sequence.started = sequence.started + 1
    sequence.timer = 0
  end
  if sequence.started < sequence.count then
    sequence.timer = sequence.timer + 1
  end
  for index = 1, sequence.started do
    local sprite = sequence.sprites[index]
    local motion = sequence.motions[index]
    active[index] = motion:step()
    if active[index] then
      sprite.scaleX = motion.x / 256
      sprite.scaleY = motion.y / 256
    else
      sprite.hidden = true
    end
  end
  for index = 1, sequence.count do
    if active[index] == true then
      return true
    end
  end
  return false
end

-- BattleAnimSpriteFunc_ScaleSpritesOverDefender (battle_anim_effects.c):
-- three copies scale up over the defender, the defender picture shakes six
-- rounds, then the copies scale away.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newScaleOverDefender(kind, args, context, services)
  local defender = Support.defender(context, kind)
  local baseX, baseY = defender.center.x, defender.center.y
  local sprites = {}
  for index = 1, 3 do
    local sprite = Support.sprite(baseX, baseY)
    sprite.hidden = true
    sprites[index] = sprite
  end
  sprites[2].xlu = true
  sprites[3].xlu = true
  local state = "start-grow"
  local sequence = {} --[[@as table<string, unknown>]]
  local shake = Support.shake(4, 0, 1, 6)
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local bank = self:bank()
    if state == "start-grow" then
      Support.setAnim(sprites[1], 1, bank, kind)
      sequence = {
        sprites = { sprites[3], sprites[2], sprites[1] },
        motions = {},
        interval = 9,
        timer = 0,
        started = 0,
        count = 3,
      }
      for index = 1, 3 do
        local copy = Support.scaleMotion(25, 10, 25, 10, 10, 10)
        sequence.motions[index] = copy
      end
      state = "grow"
    elseif state == "grow" then
      local active = updateSequence(sequence)
      if not active then
        sprites[1].hidden = false
        state = "shake"
        shake = Support.shake(4, 0, 1, 6)
      end
    elseif state == "shake" then
      if shake:step() then
        self:publishPicture(defender.activation, {
          centerX = baseX + shake.x,
          centerY = baseY + shake.y,
        })
      else
        state = "shrink"
        sequence = {
          sprites = { sprites[1], sprites[2], sprites[3] },
          motions = {},
          interval = 5,
          timer = 0,
          started = 0,
          count = 3,
        }
        for index = 1, 3 do
          sequence.motions[index] = Support.scaleMotion(10, 25, 10, 25, 10, 6)
        end
        sprites[1].hidden = false
      end
    elseif state == "shrink" then
      if not updateSequence(sequence) then
        return true
      end
    end
    return false
  end
  local body = Support.newBody(kind, args, context, services, {}, advance)
  body:setSprites(sprites)
  return body
end

Effects["sprite-scale-over-defender"] = newScaleOverDefender

-- BattleAnimSpriteFunc_SpritesOrbitAttackerBobbing / SpritesOrbitAttacker
-- (battle_anim_effects.c): six copies orbit the attacker picture on the
-- authored sine path with a five-times-frequency vertical bob (bobbing
-- variant only), fading in and out around a twenty-eight tick orbit.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@param bobbing boolean true for the bobbing variant
---@return ConfiguredSpriteBody runnable body
local function newOrbitAttacker(kind, args, context, services, bobbing)
  local attacker = Support.attacker(context, kind)
  local direction = Support.sideSignByMode(attacker)
  local x, y = attacker.center.x, attacker.center.y
  local sprites = {}
  local paths = {}
  for i = 0, 5 do
    local sprite = Support.sprite(x, y)
    sprite.xlu = true
    sprite.auto = true
    sprite.elapsed = 0
    sprites[i + 1] = sprite
    local path = Support.sinMotion(0, 0x7FFF, 0, 0, 50 * Support.FX, 0, 48)
    path.angleX = path.angleX + i * 0x2AAA
    path.stepX = path.stepX * direction
    paths[i + 1] = path
  end
  local state = "fade-in"
  local blend = Support.linear(1, 16, 15, 0, 10)
  local timer = 0
  local function updatePaths()
    for i = 1, 6 do
      Support.stepSin(paths[i])
      local sprite = sprites[i]
      if bobbing then
        local offset = math.floor(Support.sinIdx((paths[i].angleX * 5) % 0x10000) * 10 * direction / Support.FX)
        sprite.x = x + paths[i].x
        sprite.y = y + offset
      else
        sprite.x = x + paths[i].x
        sprite.y = y
      end
    end
  end
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    if state == "fade-in" then
      if blend:step() then
        self:writeBlend(blend.x, blend.y)
        for _, sprite in ipairs(sprites) do
          sprite.alpha = math.max(0, math.min(1, blend.x / 16))
        end
      else
        state = "orbit"
        timer = 28
      end
      updatePaths()
    elseif state == "orbit" then
      updatePaths()
      timer = timer - 1
      if timer < 0 then
        state = "fade-out"
        blend = Support.linear(16, 1, 0, 15, 10)
      end
    elseif state == "fade-out" then
      updatePaths()
      if blend:step() then
        self:writeBlend(blend.x, blend.y)
        for _, sprite in ipairs(sprites) do
          sprite.alpha = math.max(0, math.min(1, blend.x / 16))
        end
      else
        return true
      end
    end
    return false
  end
  local body = Support.newBody(kind, args, context, services, {}, advance)
  body:setSprites(sprites)
  return body
end

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable bobbing body
local function newOrbitAttackerBobbing(kind, args, context, services)
  return newOrbitAttacker(kind, args, context, services, true)
end

---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newOrbitAttackerSteady(kind, args, context, services)
  return newOrbitAttacker(kind, args, context, services, false)
end

Effects["sprite-orbit-attacker-bobbing"] = newOrbitAttackerBobbing
Effects["sprite-orbit-attacker"] = newOrbitAttackerSteady

-- BattleAnimSpriteFunc_FloatingSpriteStream (battle_anim_effects.c): fifteen
-- copies launch from the attacker picture every seven ticks, drift on a
-- signed path, and bob/scale on the authored sine.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newFloatingStream(kind, args, context, services)
  local attacker = Support.attacker(context, kind)
  local dirX = Support.sideSignByMode(attacker)
  local dirY = Support.sideSign(attacker)
  local x, y = attacker.center.x, attacker.center.y
  local sprites = {}
  local motions = {}
  local anims = {}
  for index = 1, 15 do
    local sprite = Support.sprite(x, y)
    sprite.hidden = true
    sprite.elapsed = 0
    sprites[index] = sprite
    anims[index] = (index - 1) % 3
  end
  local count = 0
  local timer = 0
  local done = false
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local _ = self
    if count < 15 then
      timer = timer + 1
      if timer > 6 then
        timer = 0
        local sprite = sprites[count + 1]
        motions[count + 1] = Support.linear(sprite.x, sprite.x + (dirX * 256), sprite.y, sprite.y + dirY * -128, 59)
        sprite.hidden = false
        count = count + 1
      end
    end
    for index = 1, count do
      local sprite = sprites[index]
      local motion = motions[index]
      if motion:step() then
        local angle = (motion.x * 364) % 0x10000
        local sin = Support.sinIdx(angle)
        sprite.x = motion.x
        sprite.y = motion.y + math.floor(sin * 14 / Support.FX)
        local scale = 1.0 - math.floor(sin * 696 / Support.FX) / 4096.0
        sprite.scaleX, sprite.scaleY = scale, scale
        done = false
      else
        done = true
      end
    end
    return count >= 15 and done == true
  end
  local body = Support.newBody(kind, args, context, services, {}, advance)
  local bank = body:bank()
  for index = 1, 15 do
    Support.setAnim(sprites[index], anims[index], bank, kind)
  end
  body:setSprites(sprites)
  return body
end
Effects["sprite-floating-stream"] = newFloatingStream

-- BattleAnimSpriteFunc_FadeSpriteAnim (battle_anim_effects.c): the sprite
-- fades in over eight ticks, plays its authored animation, then fades out.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newFadeAnim(kind, args, context, services)
  local defender = Support.defender(context, kind)
  local sprite = Support.sprite(defender.center.x, defender.center.y)
  sprite.auto = true
  sprite.xlu = true
  local state = "fade-in"
  local blend = Support.linear(0, 16, 16, 0, 8)
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    if state == "fade-in" or state == "wait-anim" or state == "fade-out" then
      if state == "wait-anim" and not Support.isAnimated(sprite, self:bank(), kind) then
        state = "fade-out"
        blend = Support.linear(16, 0, 0, 16, 8)
        return false
      end
      if state ~= "wait-anim" then
        if blend:step() then
          self:writeBlend(blend.x, blend.y)
          sprite.alpha = math.max(0, math.min(1, blend.x / 16))
        elseif state == "fade-in" then
          state = "wait-anim"
          sprite.alpha = 1
        elseif state == "fade-out" then
          sprite.hidden = true
          return true
        end
      end
    end
    return false
  end
  local body = Support.newBody(kind, args, context, services, {}, advance)
  body:setSprites({ sprite })
  return body
end
Effects["sprite-fade-anim"] = newFadeAnim

-- BattleAnimSpriteFunc_RisingShrinkSprites (battle_anim_effects.c): two
-- copies rise sixteen pixels sideways and thirty-two up, shrinking into the
-- attacker picture; the second launches nine ticks after the first.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newRisingShrink(kind, args, context, services)
  local attacker = Support.attacker(context, kind)
  local direction = Support.sideSignByMode(attacker)
  local sprites = {}
  local moves = {}
  local scales = {}
  for index = 1, 2 do
    local sprite = Support.sprite(attacker.center.x, attacker.center.y)
    sprite.hidden = true
    sprites[index] = sprite
  end
  local state = "launch-first"
  local timer = 0
  local function launch(index)
    local sprite = sprites[index]
    sprite.hidden = false
    moves[index] = Support.linear(sprite.x, sprite.x + direction * 16, sprite.y, sprite.y - 32, 32)
    scales[index] = Support.scaleMotion(2, 10, 2, 10, 10, 32)
  end
  local function update(index)
    local sprite = sprites[index]
    local move = moves[index]
    local scale = scales[index]
    if move:step() then
      sprite.x, sprite.y = move.x, move.y
    end
    if scale:step() then
      applyScale(sprite, scale)
      return false
    end
    sprite.hidden = true
    return true
  end
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local _ = self
    if state == "launch-first" then
      launch(1)
      update(1)
      timer = 8
      state = "delay"
    elseif state == "delay" then
      timer = timer - 1
      update(1)
      if timer < 0 then
        state = "launch-second"
      end
    elseif state == "launch-second" then
      launch(2)
      update(2)
      update(1)
      state = "wait"
    elseif state == "wait" then
      update(1)
      if update(2) then
        return true
      end
    end
    return false
  end
  local body = Support.newBody(kind, args, context, services, {}, advance)
  body:setSprites(sprites)
  return body
end
Effects["sprite-rising-shrink"] = newRisingShrink

-- BattleAnimTask_SpriteRowSequencePlace / Update: six copies appear in a
-- staggered row, each for sixteen ticks, at the authored x offsets.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newRowSequence(kind, args, context, services)
  local attacker = Support.attacker(context, kind)
  local direction = Support.sideSignByMode(attacker)
  local sprites = {}
  local delays = {}
  local visibleTimes = {}
  local anims = {}
  for i = 0, 5 do
    local x = attacker.center.x
    local y = attacker.center.y
    local delta = (2 - 14) * i + 40
    local sprite = Support.sprite(x + direction * delta, y + 40)
    sprite.hidden = true
    sprite.elapsed = 0
    sprites[i + 1] = sprite
    delays[i + 1] = i * 2
    visibleTimes[i + 1] = 16
    anims[i + 1] = math.floor(i / 2)
  end
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local _ = self
    local done = false
    for index = 1, 6 do
      if delays[index] > 0 then
        delays[index] = delays[index] - 1
        if delays[index] == 0 then
          sprites[index].hidden = false
        end
        done = false
      elseif visibleTimes[index] > 0 then
        visibleTimes[index] = visibleTimes[index] - 1
        done = false
      else
        sprites[index].hidden = true
        done = true
      end
    end
    return done
  end
  local body = Support.newBody(kind, args, context, services, {}, advance)
  local bank = body:bank()
  for index = 1, 6 do
    Support.setAnim(sprites[index], anims[index], bank, kind)
  end
  body:setSprites(sprites)
  return body
end
Effects["sprite-row-sequence"] = newRowSequence

-- BattleAnimSpriteFunc_PaletteCycleSprite (battle_anim_effects.c): the sprite
-- fades in, cycles its native palette offset with the authored animation
-- frame modulo three, then fades out.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newPaletteCycle(kind, args, context, services)
  local defender = Support.defender(context, kind)
  local sprite = Support.sprite(defender.center.x, defender.center.y)
  sprite.hidden = true
  sprite.xlu = true
  local state = "fade-in"
  local blend = Support.linear(0, 16, 20, 4, 10)
  local paletteOffset = 0
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    if state == "fade-in" then
      sprite.hidden = false
      if blend:step() then
        self:writeBlend(blend.x, blend.y)
        sprite.alpha = math.max(0, math.min(1, blend.x / 16))
      else
        state = "cycle"
        sprite.auto = true
        sprite.speed = 1
      end
    elseif state == "cycle" then
      local bank = self:bank()
      local walk = bank.walks[sprite.anim] or {}
      local frameIndex = 0
      local elapsed = math.floor(sprite.elapsed)
      local total = 0
      for index, frame in ipairs(walk) do
        total = total + frame.duration
        if elapsed < total then
          frameIndex = index - 1
          break
        end
      end
      sprite.paletteOffset = paletteOffset + (frameIndex % 3)
      if not Support.isAnimated(sprite, bank, kind) then
        state = "fade-out"
        blend = Support.linear(16, 0, 4, 20, 8)
      end
    elseif state == "fade-out" then
      if blend:step() then
        self:writeBlend(blend.x, blend.y)
        sprite.alpha = math.max(0, math.min(1, blend.x / 16))
      else
        sprite.hidden = true
        return true
      end
    end
    return false
  end
  local body = Support.newBody(kind, args, context, services, {}, advance)
  body:setSprites({ sprite })
  return body
end
Effects["sprite-palette-cycle"] = newPaletteCycle

-- BattleAnimSpriteFunc_ZigzagFlash (battle_anim_effects.c): the sprite walks
-- four 4-tick legs from the defender picture, the battlefield and every
-- battler picture flash white, then the sprite blinks and retires.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newZigzagFlash(kind, args, context, services)
  local defender = Support.defender(context, kind)
  local sprite = Support.sprite(defender.center.x - 40, defender.center.y - 40)
  sprite.xlu = true
  sprite.elapsed = 0
  local x, y = defender.center.x - 40, defender.center.y - 40
  local legs = {
    { 80, 80 },
    { 0, -80 },
    { -80, 80 },
    { 40, -40 },
  }
  local legIndex = 0
  local leg = Support.linear(0, 0, 0, 0, 1)
  local state = "next-leg"
  local timer = -16
  local draw = false
  local brightTicks = 0
  local function setLeg()
    local step = legs[legIndex + 1]
    if step == nil then
      Support.malformed(kind, "walks its four authored zigzag legs")
    end
    step = assert(step)
    leg = Support.linear(0, step[1], 0, step[2], 4)
  end
  local function setPictureFade(self, start, finish)
    local roles = { Support.attacker(context, kind) }
    for _, target in ipairs(Support.targets(context, kind)) do
      roles[#roles + 1] = target
    end
    for _, role in ipairs(roles) do
      self:publishPicture(role.activation, {
        paletteFade = { start = start, finish = finish, framesPer = 0, targetColor = 0x7FFF },
      })
    end
  end
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    if state == "next-leg" then
      timer = timer + 1
      if timer > 1 then
        setLeg()
        state = "move"
        timer = 0
      end
    elseif state == "move" then
      if leg:step() then
        sprite.x, sprite.y = x + leg.x, y + leg.y
      else
        legIndex = legIndex + 1
        if legIndex < 4 then
          state = "next-leg"
          x = x + leg.x
          y = y + leg.y
        else
          state = "delay"
          timer = 8
          Support.setAnim(sprite, 1, self:bank(), kind)
          sprite.auto = true
        end
      end
    elseif state == "delay" then
      timer = timer - 1
      if timer < 0 then
        state = "flash"
        brightTicks = 0
        self:writeCompositor({ battlefieldFade = { color = { r = 31, g = 31, b = 31 }, amount = 0 } })
        setPictureFade(self, 14, 16)
      end
    elseif state == "flash" then
      brightTicks = brightTicks + 1
      if brightTicks <= 5 then
        local amount = math.min(16, (brightTicks - 1) * 4)
        self:writeCompositor({ battlefieldFade = { color = { r = 31, g = 31, b = 31 }, amount = amount } })
      elseif brightTicks == 6 then
        self:writeCompositor({ battlefieldFade = { color = { r = 31, g = 31, b = 31 }, amount = 16 } })
        setPictureFade(self, 2, 0)
        state = "restore"
        timer = 5
      end
    elseif state == "restore" then
      timer = timer - 1
      local amount = math.max(0, timer * 4)
      self:writeCompositor({ battlefieldFade = { color = { r = 31, g = 31, b = 31 }, amount = amount } })
      if timer < 0 then
        state = "blink"
        timer = 4
        legIndex = 4
        draw = false
      end
    elseif state == "blink" then
      timer = timer - 1
      if timer < 0 then
        timer = 4
        legIndex = legIndex - 1
        if legIndex < 0 then
          state = "end"
        else
          sprite.hidden = not draw
          draw = not draw
        end
      end
    else
      return true
    end
    return false
  end
  local body = Support.newBody(kind, args, context, services, {}, advance)
  body:setSprites({ sprite })
  return body
end
Effects["sprite-zigzag-flash"] = newZigzagFlash

return Effects
