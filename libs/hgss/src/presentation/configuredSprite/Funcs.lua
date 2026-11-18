-- Configured-sprite bodies for the battle_anim_funcs.c callbacks in
-- gBattleAnimSpriteFuncTable: the generic sprite machines that place one
-- managed sprite, walk it across the field, and retire with its authored
-- animation. Phase tables and tick boundaries mirror the pinned source.

local Support = require("libs.hgss.src.presentation.configuredSprite.Support")

local Funcs = {}

-- gBattleAnimSpriteOrbitStepX (asm/battle_anim_data.s), s16 through the
-- 255 terminator. The orbit crosses the defender picture in this exact
-- per-tick step sequence before the rocking swing begins.
local ORBIT_STEP_X = {
  5,
  5,
  5,
  5,
  4,
  4,
  4,
  3,
  3,
  3,
  0,
  -3,
  -3,
  -3,
  -4,
  -4,
  -4,
  -5,
  -5,
  -5,
  -5,
  -5,
  -5,
  -5,
  -5,
  -4,
  -4,
  -4,
  -3,
  -3,
  -3,
  0,
  3,
  3,
  3,
  4,
  4,
  4,
  5,
  5,
  5,
  5,
  255,
}

-- BattleAnimSpriteFunc_SpreadSpriteCopies (battle_anim_funcs.c): three
-- copies tick their authored animation and drift apart one pixel at a time.
-- The native task has no internal END transition; the script deletes the
-- sprite later, so the authored animation is the bounded lifetime here.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newSpreadCopies(kind, args, context, services)
  local defender = Support.defender(context, kind)
  local sprites = {}
  for index = 1, 3 do
    local sprite = Support.sprite(defender.center.x, defender.center.y)
    sprite.elapsed = 0
    sprites[index] = sprite
  end
  local total = nil
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    total = total or Support.total(self:bank(), 1, kind)
    local bank = self:bank()
    Support.tickFrame(sprites[1], bank, kind)
    Support.tickFrame(sprites[2], bank, kind)
    Support.tickFrame(sprites[3], bank, kind)
    sprites[1].x = sprites[1].x + 1
    sprites[2].x = sprites[2].x - 1
    sprites[3].x = sprites[3].x + 1
    sprites[3].y = sprites[3].y + 1
    return self:ticks() >= total
  end
  local body = Support.newBody(kind, args, context, services, {}, advance)
  body:setSprites(sprites)
  return body
end
Funcs["sprite-spread-copies"] = newSpreadCopies

-- BattleAnimSpriteFunc_SpriteOrbit (battle_anim_funcs.c): the sprite walks
-- the pinned per-tick step table across the defender, then swings around its
-- pivot through six value motions before the task retires.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newSpriteOrbit(kind, args, context, services)
  local defender = Support.defender(context, kind)
  local attacker = Support.attacker(context, kind)
  local sprite = Support.sprite(defender.center.x, defender.center.y + 12)
  sprite.pivotX, sprite.pivotY = -8, 16
  local state = "circle"
  local step = 0
  local angle = Support.value(0, 0, 1)
  local swingState = 0
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local bank = self:bank()
    if state == "circle" then
      local dx = ORBIT_STEP_X[step + 1]
      step = step + 1
      if dx == nil then
        Support.malformed(kind, "walks its pinned orbit step table")
      end
      if dx ~= 255 then
        sprite.x = sprite.x + dx
      else
        angle = Support.value(0, 0x0E38, 4)
        sprite.rotation = 0
        step = 0
        state = "swing"
      end
    elseif state == "swing" then
      if Support.stepValue(angle) then
        sprite.rotation = angle.value
      elseif swingState > 5 then
        state = "end"
      else
        swingState = swingState + 1
        if swingState == 1 then
          angle = Support.value(0x0E38, -0x0E38, 4)
        elseif swingState == 2 then
          angle = Support.value(-0x0E38, 0x0E38, 4)
        elseif swingState == 3 then
          angle = Support.value(0x0E38, -0x0E38, 4)
        elseif swingState == 4 then
          angle = Support.value(-0x0E38, 0x0E38, 4)
        elseif swingState == 5 then
          angle = Support.value(0x0E38, 0, 2)
        end
      end
    else
      return true
    end
    Support.tickFrame(sprite, bank, kind)
    return false
  end
  local body = Support.newBody(kind, args, context, services, {}, advance)
  local bank = body:bank()
  Support.setAnim(sprite, attacker.side == "enemy" and 1 or 0, bank, kind)
  body:setSprites({ sprite })
  return body
end
Funcs["sprite-orbit"] = newSpriteOrbit

-- BattleAnimSpriteFunc_MoveSpriteAndAnimate (battle_anim_funcs.c): offset
-- the sprite by its two compiled words, then play the authored animation
-- once. The native task retires the tick the sequence stops advancing.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newOffsetAnimate(kind, args, context, services)
  local parameters = Support.parameters(args, kind)
  local offsetX = Support.whole(parameters, "offsetX", kind, 0)
  local offsetY = Support.whole(parameters, "offsetY", kind, 0)
  local defender = Support.defender(context, kind)
  local bank = nil
  local sprite = Support.sprite(defender.center.x + offsetX, defender.center.y + offsetY)
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    bank = bank or self:bank()
    bank = assert(bank)
    Support.tickFrame(sprite, bank, kind)
    return not Support.isAnimated(sprite, bank, kind)
  end
  local body = Support.newBody(kind, args, context, services, {}, advance)
  body:setSprites({ sprite })
  return body
end
Funcs["sprite-offset-animate"] = newOffsetAnimate

-- BattleAnimSpriteFunc_SpriteAboveDefender (battle_anim_funcs.c): one sprite
-- sits above (enemy defender) or below (player defender) the picture and
-- plays its authored animation once. Contest placement is not reachable in
-- the battle presentation.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newAboveDefender(kind, args, context, services)
  local defender = Support.defender(context, kind)
  local sprite = Support.sprite(defender.center.x, defender.side == "player" and 126 or 32)
  local initialized = false
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local bank = self:bank()
    if not initialized then
      initialized = true
      Support.setAnim(sprite, defender.side == "player" and 1 or 0, bank, kind)
    end
    Support.tickFrame(sprite, bank, kind)
    return not Support.isAnimated(sprite, bank, kind)
  end
  local body = Support.newBody(kind, args, context, services, {}, advance)
  local bank = body:bank()
  Support.setAnim(sprite, defender.side == "player" and 1 or 0, bank, kind)
  body:setSprites({ sprite })
  return body
end
Funcs["sprite-above-defender"] = newAboveDefender

-- BattleAnimSpriteFunc_SpriteArc (battle_anim_funcs.c): throws the sprite
-- from offscreen left along a 21-tick sine arc to (112, 112), waits for its
-- authored animation, then fades the shared blend out over sixteen steps.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newSpriteArc(kind, args, context, services)
  local sprite = Support.sprite(-30, 160)
  local state = "init"
  local path = Support.linear(0, 0, 0, 0, 1)
  local eva, evb = 16, 0
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local bank = self:bank()
    if state == "init" then
      path = Support.linear(-30, 112, 160, 112, 21)
      state = "arc"
    elseif state == "arc" then
      if path:step() then
        sprite.x = path.x
        sprite.y = path.y
      else
        state = "wait"
      end
    elseif state == "wait" then
      Support.tickFrame(sprite, bank, kind)
      if not Support.isAnimated(sprite, bank, kind) then
        sprite.xlu = true
        eva, evb = 16, 0
        self:writeBlend(eva, evb)
        state = "fade"
      end
    elseif state == "fade" then
      eva = math.max(0, eva - 1)
      evb = math.min(16, evb + 1)
      self:writeBlend(eva, evb)
      if eva == 0 then
        state = "end"
      end
      Support.tickFrame(sprite, bank, kind)
    else
      return true
    end
    return false
  end
  local body = Support.newBody(kind, args, context, services, {}, advance)
  body:setSprites({ sprite })
  return body
end
Funcs["sprite-arc"] = newSpriteArc

-- BattleAnimSpriteFunc_SpritePops (battle_anim_funcs.c): one sprite pops up
-- twice beside the defender, growing 10/10 to 14/10 and back to 12/10, with
-- a four-tick authored delay between the two pops.
---@param kind string task kind under construction
---@param args table<string, unknown> instruction-derived construction arguments
---@param context table<string, unknown> occurrence-bound playback context
---@param services table<string, unknown> factory services record
---@return ConfiguredSpriteBody runnable body
local function newSpritePops(kind, args, context, services)
  local defender = Support.defender(context, kind)
  local attacker = Support.attacker(context, kind)
  local side = Support.sideSignByMode(attacker)
  local sprite = Support.sprite(defender.center.x, defender.center.y)
  sprite.hidden = true
  local x, y = defender.center.x, defender.center.y
  local motion = Support.scaleMotion(10, 14, 10, 14, 10, 4)
  local shrinking = false
  -- BattleAnimSpritePop_Update: grow 10/10 -> 14/10 over four ticks, then
  -- shrink 14/10 -> 12/10 over two ticks; the false return hides the sprite.
  local function start(popX, popY)
    sprite.hidden = false
    sprite.x, sprite.y = popX, popY
    sprite.scaleX, sprite.scaleY = 256 / 256, 256 / 256
    motion = Support.scaleMotion(10, 14, 10, 14, 10, 4)
    shrinking = false
  end
  local function update()
    if motion:step() then
      sprite.scaleX = motion.x / 256
      sprite.scaleY = motion.y / 256
      return false
    end
    if shrinking then
      sprite.hidden = true
      return true
    end
    shrinking = true
    motion = Support.scaleMotion(14, 12, 14, 12, 10, 2)
    return false
  end
  local sequence = "start-first"
  local delay = 4
  ---@param self ConfiguredSpriteBody body under advancement
  ---@return boolean? retired
  local function advance(self)
    local _ = self
    if sequence == "start-first" then
      start(x + side * 24, y - 16)
      sequence = "first"
    elseif sequence == "first" then
      if update() then
        sequence = "delay"
      end
    elseif sequence == "delay" then
      delay = delay - 1
      if delay < 0 then
        sequence = "second"
        start(x - side * 24, y - 24)
      end
    elseif sequence == "second" then
      if update() then
        sequence = "done"
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
Funcs["sprite-pops"] = newSpritePops

return Funcs
