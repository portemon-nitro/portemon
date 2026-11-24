-- The hatch scene's drawing: the generated background, the egg sprite with its
-- source shake displacement and affine scale, the reveal bars, the scene's
-- message window with its own lines and answers, and the two compiled particle
-- systems. Every value drawn comes from an immutable care snapshot and from the
-- generated hatch manifest; the renderer never loads an asset, advances a
-- timer, or draws random state. Draw order follows the source overlay: the
-- background layer, then the egg, then the bars that cover the reveal, then the
-- message window.
--
-- Retail sources (tmp/refs/pokeheartgold): src/application/hatch_egg_gfx.c
-- (HatchEggApp_LoadBackground, HatchEggApp_CreateSprites,
-- HatchEggApp_UpdateEggShake, HatchEggParticles_Emit) and
-- src/application/hatch_egg_app.c (the scene's window, lines and yes/no).

local SplParticleDraw = require("libs.hgss.src.presentation.SplParticleDraw")
local SplParticleSimulation = require("libs.hgss.src.presentation.SplParticleSimulation")

---@class EggHatchRenderer
---@field private _graphics table<string, unknown>
---@field private _manifest table<string, unknown>
---@field private _images table<string, table<string, unknown>>
---@field private _text table<string, unknown> borrowed field text renderer
---@field private _window table<string, unknown>? borrowed window frame renderer
---@field private _frameIndex integer? the player's selected window frame
---@field private _fontDef table<string, unknown> borrowed field font definition
---@field private _ordinals table<string, table<integer, integer>> source emitter id -> manager ordinal per variant
---@field private _sims table<string, table<string, unknown>> live particle simulations per variant
---@field private _variant string? variant whose simulation is live
local EggHatchRenderer = {}
EggHatchRenderer.__index = EggHatchRenderer

-- The source sprite origins (HatchEggApp_CreateSprites): the egg sits at
-- (128, 120); the reveal bars are one 256x16 strip drawn at y -16 and y 144.
local EGG_X = 128
local EGG_Y = 120
local TOP_BAR_Y = -16
local BOTTOM_BAR_Y = 144
-- HatchEggApp_HatchEgg slides the bars four pixels per frame until both are
-- fully off screen.
local BAR_SLIDE_STEP = 4

local VARIANTS = { "egg", "manaphy" }

-- The hatch window prints its lines with the field's default ink on the
-- generated window fill; the source sets one text color for the whole scene.
local HATCH_TEXT_PALETTE = {
  foreground = { r = 248, g = 248, b = 248, a = 255 },
  shadow = { r = 88, g = 88, b = 88, a = 255 },
  background = { r = 0, g = 0, b = 0, a = 255 },
}

-- The focus-indicator primitive indexes the window palette by slot, so the
-- indicator trio spreads over the sixteen-window slots the source frame uses.
---@param palette { foreground: table, shadow: table, background: table }
---@return table<integer, table>
local function focusPalette(palette)
  local slots = {}
  for slot = 0, 15 do
    slots[slot] = palette.foreground
  end
  return slots
end

---@param opts { graphics: table<string, unknown>, manifest: table<string, unknown>, images: table<string, table<string, unknown>>, text: table<string, unknown>, window: table<string, unknown>?, fontDef: table<string, unknown>, frameIndex: integer? }
---@return EggHatchRenderer
function EggHatchRenderer.new(opts)
  assert(type(opts) == "table", "the hatch renderer requires its options")
  local graphics = assert(opts.graphics, "the hatch renderer requires the graphics namespace")
  assert(type(graphics.draw) == "function", "the hatch renderer draws through the graphics namespace")
  local manifest = assert(opts.manifest, "the hatch renderer requires the generated manifest")
  local images = assert(opts.images, "the hatch renderer requires its realized images")
  local text = assert(opts.text, "the hatch renderer borrows the field text renderer")
  assert(
    type(text.drawTextWithPalette) == "function" and type(text.windowBackgroundColor) == "function",
    "the hatch renderer requires the shared field text renderer"
  )
  local fontDef = assert(opts.fontDef, "the hatch renderer requires the field font definition")
  local window = opts.window
  if window ~= nil then
    assert(type(window.drawWindow) == "function", "the hatch renderer borrows a framed window renderer")
  end
  local ordinals = {}
  for _, variant in ipairs(VARIANTS) do
    local set = assert(manifest.particles, "the hatch manifest carries particles") --[[@as table]]
    local records = assert(set[variant], "the hatch manifest carries both particle sets") --[[@as table]]
    local byId = {}
    for ordinal, emitter in ipairs(records.emitters) do
      assert(type(emitter.id) == "number", "compiled particle emitters carry their source identity")
      byId[emitter.id] = ordinal - 1
    end
    ordinals[variant] = byId
  end
  return setmetatable({
    _graphics = graphics,
    _manifest = manifest,
    _images = images,
    _text = text,
    _window = window,
    _frameIndex = opts.frameIndex,
    _fontDef = fontDef,
    _ordinals = ordinals,
    _sims = {},
    _variant = nil,
  }, EggHatchRenderer)
end

---@param path string
---@return table<string, unknown>
function EggHatchRenderer:_image(path)
  local image = self._images[path]
  assert(image ~= nil, "the hatch scene image is not realized: " .. tostring(path))
  return image
end

-- One staged animation frame of a compiled group by its source index.
---@param groupKey string
---@param index integer
---@return table<string, unknown>|nil frame
function EggHatchRenderer:_frame(groupKey, index)
  local group = assert(self._manifest[groupKey], "the hatch manifest carries " .. groupKey) --[[@as table]]
  local frames = assert(group.frames, "the hatch group carries frames") --[[@as table]]
  return frames[index + 1]
end

-- Starts the variant's particle simulation and emits the source emitter ids
-- the scene requests at that moment. Emitting is idempotent per request: a
-- repeated source emission simply creates another emitter, exactly like the
-- native particle system.
---@param variant string
---@param emitterIds integer[]
function EggHatchRenderer:emitParticles(variant, emitterIds)
  local sim = self._sims[variant]
  if sim == nil then
    local set = assert(self._manifest.particles) --[[@as table]]
    local records = assert(set[variant], "the hatch manifest carries the " .. variant .. " particles") --[[@as table]]
    sim = SplParticleSimulation.new({ state = 1 }, 0, records.emitters)
    self._sims[variant] = sim
    self._variant = variant
  end
  for _, emitterId in ipairs(emitterIds) do
    local ordinal = self._ordinals[variant][emitterId]
    assert(ordinal ~= nil, "the hatch scene requests an emitter its resource does not carry: " .. tostring(emitterId))
    SplParticleSimulation.addEmitter(sim, ordinal, nil)
  end
end

-- Advances the live particle simulation one source frame. Gameplay never waits
-- on this: the scene's own clock owns every wait.
function EggHatchRenderer:updateFixed()
  local variant = self._variant
  if variant == nil then
    return
  end
  SplParticleSimulation.advance(self._sims[variant], nil)
end

---@return boolean whether any particle emitter is still running
function EggHatchRenderer:particlesRunning()
  local variant = self._variant
  if variant == nil then
    return false
  end
  return #self._sims[variant].emitters > 0
end

---@param variant string
function EggHatchRenderer:releaseParticles(variant)
  self._sims[variant] = nil
  if self._variant == variant then
    self._variant = nil
  end
end

-- The scene's own text: the manifest line with the hatched record's name in
-- the substitution position the source buffer filled.
---@param key string
---@param name string
---@return string
function EggHatchRenderer:lineText(key, name)
  local messages = assert(self._manifest.messages, "the hatch manifest carries its lines") --[[@as table]]
  local line = assert(messages[key], "the hatch manifest carries " .. key) --[[@as table]]
  return (assert(line.text) --[[@as string]]):gsub("{name}", name)
end

---@param key string
---@return integer
function EggHatchRenderer:lineId(key)
  local messages = assert(self._manifest.messages, "the hatch manifest carries its lines") --[[@as table]]
  local line = assert(messages[key], "the hatch manifest carries " .. key) --[[@as table]]
  return assert(line.id) --[[@as integer]]
end

-- Draws the scene's message window with the source content box, the current
-- line, and -- once the question is on screen -- the two answers with the
-- selected one marked by the shared field focus indicator.
---@param status PokemonCareHatchStatus
---@param name string the hatched record's display name
function EggHatchRenderer:_drawWindow(status, name)
  local window = self._window
  if window == nil then
    return
  end
  local spec = assert(self._manifest.window, "the hatch manifest carries its window") --[[@as table]]
  local box = {
    x = assert(spec.x) --[[@as number]],
    y = assert(spec.y) --[[@as number]],
    width = assert(spec.width) --[[@as number]],
    height = assert(spec.height) --[[@as number]],
  }
  local background = self._text:windowBackgroundColor()
  window:drawWindow(box, self._frameIndex, background)
  local palette = HATCH_TEXT_PALETTE
  local lineHeight = 16
  local lineY = box.y + 2
  if status.messageId == self:lineId("hatched") then
    self._text:drawTextWithPalette(self:lineText("hatched", name), box.x + 4, lineY, palette)
    return
  end
  if status.messageId == self:lineId("nicknameQuestion") then
    self._text:drawTextWithPalette(self:lineText("nicknameQuestion", name), box.x + 4, lineY, palette)
  end
  if not status.question then
    return
  end
  local answerY = lineY + lineHeight
  for _, answer in ipairs({ "yes", "no" }) do
    local selected = (answer == "yes") == (status.selection == "yes")
    local line = assert(self._manifest.messages, "the hatch manifest carries its lines") --[[@as table]]
    local align = assert(line[answer]) --[[@as table]]
    local x = box.x + 4
    if align.align == "center" then
      x = box.x + math.floor((box.width - 8) / 2)
    elseif align.align == "right" then
      x = box.x + box.width - 40
    end
    self._text:drawTextWithPalette(self:lineText(answer, name), x + 10, answerY, palette)
    if selected then
      self._text:drawFocusIndicator(0, x + 2, answerY - 2, focusPalette(palette))
    end
    answerY = answerY + lineHeight
  end
end

-- Draws one immutable snapshot of the hatch scene at native 256x192 reference
-- coordinates. The caller owns the pane transform and the graphics state.
---@param status PokemonCareHatchStatus
---@param name string the hatched record's display name
function EggHatchRenderer:draw(status, name)
  local lg = assert(self._graphics)
  local manifest = self._manifest
  local background = assert(manifest.background, "the hatch manifest carries its background") --[[@as table]]
  lg.setColor(1, 1, 1, 1)
  lg.draw(self:_image(assert(background.image) --[[@as string]]), 0, 0)

  local eggFrame = status.eggFrame
  if eggFrame >= 0 then
    local frame = assert(self:_frame("egg", eggFrame), "the egg animation carries this frame")
    local image = self:_image(assert(frame.image) --[[@as string]])
    lg.setColor(1, 1, 1, 1)
    lg.draw(
      image,
      EGG_X + status.eggOffsetX,
      EGG_Y + status.eggOffsetY,
      0,
      status.scaleX,
      status.scaleY,
      assert(frame.width) --[[@as number]] / 2,
      assert(frame.height) --[[@as number]] / 2
    )
  end

  if status.bars then
    local barFrame = assert(self:_frame("bars", 0), "the reveal bars carry their frame")
    local image = self:_image(assert(barFrame.image) --[[@as string]])
    lg.setColor(1, 1, 1, 1)
    lg.draw(image, 0, TOP_BAR_Y - status.barsOffset)
    lg.draw(image, 0, BOTTOM_BAR_Y + status.barsOffset)
  end

  local variant = self._variant
  if variant ~= nil then
    local slotImages = self._images
    SplParticleDraw.draw(lg, self._sims[variant], {
      centerX = EGG_X,
      centerY = EGG_Y,
      resolveTexture = function(runtime, _, child)
        local path = (child or runtime.record).textureImage
        local image = slotImages[path]
        assert(image ~= nil, "the hatch particle texture is not realized: " .. tostring(path))
        return image
      end,
    })
  end

  self:_drawWindow(status, name)
  lg.setColor(1, 1, 1, 1)
end

-- The reveal animation's own slide step, so a host that only draws never
-- guesses the source displacement.
function EggHatchRenderer.barSlideStep()
  return BAR_SLIDE_STEP
end

-- Releases nothing borrowed: the realized images, the field text renderer and
-- the framed window renderer belong to the field presentation that created
-- them. Only the owned particle simulations are dropped.
function EggHatchRenderer:release()
  self._sims = {}
  self._variant = nil
end

return EggHatchRenderer
