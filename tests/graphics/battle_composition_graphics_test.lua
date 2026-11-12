-- Unified battle composition through one shared depth/alpha target: native
-- picture and particle polygons resolve against each other in the same 3D
-- pass, then the private six-plane shader selects top-two planes by
-- priority with native EVA/EVB/alpha5/brightness equations under source
-- window masks. One source transform serves both detail and compact
-- views; a failed frame keeps the last good canvas. Synthetic fixtures
-- only; no ROM data.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local BattlePicturePass = require("libs.hgss.src.presentation.BattlePicturePass")

local T = {}

local WIDTH, HEIGHT = 256, 192

local function solidImage(graphics, scope, red, green, blue)
  local data = love.image.newImageData(8, 8)
  for y = 0, 7 do
    for x = 0, 7 do
      data:setPixel(x, y, red, green, blue, 1)
    end
  end
  local image = scope:own(graphics.newImage(data))
  image:setFilter("nearest", "nearest")
  return image
end

local function quad(texture, color5, alpha5, clipZ)
  return {
    kind = "picture",
    vertices = {
      { clipX = -4096, clipY = 4096, clipZ = clipZ or 0, clipW = 4096, u = 0, v = 0 },
      { clipX = 4096, clipY = 4096, clipZ = clipZ or 0, clipW = 4096, u = 1, v = 0 },
      { clipX = 4096, clipY = -4096, clipZ = clipZ or 0, clipW = 4096, u = 1, v = 1 },
      { clipX = -4096, clipY = -4096, clipZ = clipZ or 0, clipW = 4096, u = 0, v = 1 },
    },
    color5 = color5,
    alpha5 = alpha5,
    polygonId = 5,
    image = texture,
    sampler = { minFilter = "nearest", magFilter = "nearest", wrapX = "clamp", wrapY = "clamp" },
    submissionOrdinal = 0,
    flags = { cullMode = "none", fogEnabled = false, translucentDepthWrite = false, depthEqual = false },
  }
end

local function rectObject(graphics, x, y, width, height, red, green, blue, priority, order, mode)
  return {
    objPriority = priority,
    submissionOrder = order,
    oamMode = mode or "normal",
    draw = function(lg)
      lg.setColor(red, green, blue, 1)
      lg.rectangle("fill", x, y, width, height)
    end,
  }
end

local function animationState(overrides)
  local state = {
    visible = { world3d = true, window = true, transition = true, battlefield = true, objects = true },
    priority = { world3d = 1, window = 0, transition = 2, battlefield = 3 },
    firstTarget = {},
    secondTarget = {},
    backdrop = { 0, 0, 0 },
    windows = { win0 = nil, win1 = nil, objWindow = nil, outside = nil },
    blend = { mode = "none", eva = 0, evb = 0, evy = 0 },
    brightness = { mode = "none", coefficient = 0 },
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      state[key] = value
    end
  end
  return state
end

local function compositionFrame(texture, overrides)
  local frame = {
    sourceTick = 1,
    engine = "main",
    animation = animationState(),
    primitives = {},
    planes = {},
    objects = {},
    layout = { worldRect = { x = 0, y = 0, width = 256, height = 192 }, scale = 1, offsetX = 0, offsetY = 0 },
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      frame[key] = value
    end
  end
  return frame
end

local function snapshot(canvas)
  local data = canvas:newImageData()
  return data
end

local function pixel6(data, x, y)
  local red, green, blue, alpha = data:getPixel(x, y)
  return math.floor(red * 63 + 0.5), math.floor(green * 63 + 0.5), math.floor(blue * 63 + 0.5), alpha
end

local function checkPixel(data, x, y, er, eg, eb, why)
  local r, g, b, a = pixel6(data, x, y)
  Assert.equal(r, er, why .. ": red at (" .. x .. "," .. y .. "), got " .. r)
  Assert.equal(g, eg, why .. ": green at (" .. x .. "," .. y .. "), got " .. g)
  Assert.equal(b, eb, why .. ": blue at (" .. x .. "," .. y .. "), got " .. b)
  Assert.isTrue(a > 0.5, why .. ": final canvas stays opaque at (" .. x .. "," .. y .. ")")
end

function T.shared_depth_resolves_pictures_against_particles_under_hud_priority(scope)
  local graphics = love.graphics
  local redImage = solidImage(graphics, scope, 1, 0, 0)
  local greenImage = solidImage(graphics, scope, 0, 1, 0)
  local pass = scope:own(BattlePicturePass.new(graphics))
  local frame = compositionFrame()
  -- Opaque red picture behind a nearer translucent green polygon: the one
  -- shared target blends them with w = 15 + 1, so the center resolves to
  -- floor(63 * 16 / 32) = 31 on red and green alike.
  frame.primitives = {
    quad(redImage, { r = 31, g = 0, b = 0 }, 31, 0),
    quad(greenImage, { r = 0, g = 31, b = 0 }, 15, -512),
  }
  frame.planes = { battlefield = { color = { 0, 1, 0 } } }
  frame.objects = { rectObject(graphics, 200, 140, 40, 30, 0, 0, 1, 0, 0) }
  local before = #frame.primitives
  local canvas = pass:render(graphics, frame)
  Assert.notNil(canvas, "one shared 3D target composes the typed battle frame")
  local data = snapshot(canvas)
  checkPixel(data, 128, 96, 31, 31, 0, "shared translucent blend covers the frame center")
  checkPixel(data, 220, 155, 0, 0, 63, "priority-0 OBJ covers the world beneath it")
  checkPixel(data, 10, 10, 31, 31, 0, "the battlefield stays behind the world planes")
  data:release()
  Assert.equal(#frame.primitives, before, "drawing advances no source state")
  local again = pass:render(graphics, frame)
  Assert.isTrue(again == canvas, "repeated draws reuse the borrowed canvas")
  local second = snapshot(canvas)
  checkPixel(second, 128, 96, 31, 31, 0, "repeated host draws perform no mutation")
  second:release()
end

function T.independent_blend_coefficients_resolve_without_double_multiply(scope)
  local graphics = love.graphics
  local pass = scope:own(BattlePicturePass.new(graphics))
  local function blendFrame(eva, evb, secondEligible, mode, evy)
    local frame = compositionFrame()
    frame.animation.blend = { mode = mode or "alpha", eva = eva, evb = evb, evy = evy or 0 }
    frame.animation.firstTarget = { window = true }
    frame.animation.secondTarget = secondEligible and { battlefield = true } or {}
    frame.planes = {
      window = { color = { 1, 0, 0 } },
      battlefield = { color = { 0, 0, 0 } },
    }
    return frame
  end
  local function centerOf(frame)
    local canvas = pass:render(graphics, frame)
    local data = snapshot(canvas)
    local r, g, b, a = pixel6(data, 128, 96)
    data:release()
    Assert.isTrue(a > 0.5, "the final canvas stays opaque: the hardware blend resolves once")
    return r, g, b
  end
  -- floor((63 * 8 + 0 * 8 + 8) / 16) = 32 on red.
  local r88 = centerOf(blendFrame(8, 8, true))
  Assert.equal(r88, 32, "independent EVA/EVB resolve, got " .. r88)
  -- floor(8 / 16) = 0: a zero first coefficient blanks the top plane.
  local r016 = centerOf(blendFrame(0, 16, true))
  Assert.equal(r016, 0, "a zero EVA blanks the top plane, got " .. r016)
  -- floor((63 * 16 + 0 * 16 + 8) / 16) = 63: coefficients never sum to 16.
  local r1616 = centerOf(blendFrame(16, 16, true))
  Assert.equal(r1616, 63, "coefficients stay independent, got " .. r1616)
  -- An ineligible second plane blocks blending instead of searching lower.
  local rBlocked = centerOf(blendFrame(8, 8, false))
  Assert.equal(rBlocked, 63, "an ineligible second plane passes the top through, got " .. rBlocked)
  -- Brighten: 0 + floor((63 * 16 + 8) / 16) = 63 on every channel.
  do
    local frame = compositionFrame()
    frame.animation.blend = { mode = "brighten", eva = 0, evb = 0, evy = 16 }
    frame.animation.firstTarget = { window = true }
    frame.planes = { window = { color = { 0, 0, 0 } }, battlefield = { color = { 0, 0, 0 } } }
    local canvas = pass:render(graphics, frame)
    local data = snapshot(canvas)
    checkPixel(data, 128, 96, 63, 63, 63, "brighten lifts black to white")
    data:release()
  end
  -- Darken: 63 - floor((63 * 16 + 7) / 16) = 0 on red.
  do
    local frame = compositionFrame()
    frame.animation.blend = { mode = "darken", eva = 0, evb = 0, evy = 16 }
    frame.animation.firstTarget = { window = true }
    frame.planes = { window = { color = { 1, 0, 0 } }, battlefield = { color = { 0, 0, 0 } } }
    local canvas = pass:render(graphics, frame)
    local data = snapshot(canvas)
    checkPixel(data, 128, 96, 0, 0, 0, "darken drops red to black")
    data:release()
  end
  -- 3D alpha: a = 15 + 1 over black gives floor((63 * 16 + 16) / 32) = 32.
  do
    local texture = solidImage(graphics, scope, 1, 0, 0)
    local frame = compositionFrame()
    frame.animation.firstTarget = { world3d = true }
    frame.animation.secondTarget = { battlefield = true }
    frame.primitives = { quad(texture, { r = 31, g = 0, b = 0 }, 15, 0) }
    frame.planes = { battlefield = { color = { 0, 0, 0 } } }
    local canvas = pass:render(graphics, frame)
    local data = snapshot(canvas)
    checkPixel(data, 128, 96, 32, 0, 0, "the 3D plane uses its own alpha resolve")
    data:release()
    frame.primitives = { quad(texture, { r = 31, g = 0, b = 0 }, 31, 0) }
    local canvas2 = pass:render(graphics, frame)
    local data2 = snapshot(canvas2)
    checkPixel(data2, 128, 96, 63, 0, 0, "alpha 31 replaces directly")
    data2:release()
  end
  -- Semitransparent OBJ over an eligible second plane uses EVA/EVB once:
  -- red floor((63 * 8 + 8) / 16) = 32, blue floor((63 * 8 + 8) / 16) = 32.
  do
    local frame = compositionFrame()
    frame.animation.blend = { mode = "alpha", eva = 8, evb = 8, evy = 0 }
    frame.animation.secondTarget = { battlefield = true }
    frame.animation.objTargets = { second = true }
    frame.planes = { battlefield = { color = { 1, 0, 0 } } }
    frame.objects = { rectObject(graphics, 0, 0, WIDTH, HEIGHT, 0, 0, 1, 0, 0, "semitransparent") }
    local canvas = pass:render(graphics, frame)
    local data = snapshot(canvas)
    checkPixel(data, 128, 96, 32, 0, 32, "semitransparent OBJ blends with native coefficients")
    data:release()
  end
end

function T.window_masks_and_row_state_reach_sampled_pixels(scope)
  local graphics = love.graphics
  local texture = solidImage(graphics, scope, 1, 0, 0)
  local pass = scope:own(BattlePicturePass.new(graphics))
  -- win0 hides the world on its left half while win1 would show it on the
  -- overlap: win0 wins, so the overlap stays on the battlefield.
  do
    local frame = compositionFrame()
    frame.primitives = { quad(texture, { r = 31, g = 0, b = 0 }, 31, 0) }
    frame.planes = { battlefield = { color = { 0, 1, 0 } } }
    frame.animation.windows = {
      win0 = { x = 0, y = 0, width = 128, height = 192, mask = { world3d = false } },
      win1 = { x = 64, y = 0, width = 128, height = 192, mask = { world3d = true } },
      objWindow = nil,
      outside = nil,
    }
    local canvas = pass:render(graphics, frame)
    local data = snapshot(canvas)
    checkPixel(data, 32, 96, 0, 63, 0, "the window mask hides the world inside win0")
    checkPixel(data, 96, 96, 0, 63, 0, "win0 keeps precedence over win1 on the overlap")
    checkPixel(data, 200, 96, 63, 0, 0, "pixels outside keep the outside mask")
    data:release()
  end
  -- OBJ-window coverage selects its own mask without painting color: the
  -- covered corner shows the battlefield, not the world or a hole.
  do
    local frame = compositionFrame()
    frame.primitives = { quad(texture, { r = 31, g = 0, b = 0 }, 31, 0) }
    frame.planes = { battlefield = { color = { 0, 1, 0 } } }
    frame.animation.windows = {
      win0 = nil,
      win1 = nil,
      objWindow = { mask = { world3d = false } },
      outside = nil,
    }
    frame.objects = { rectObject(graphics, 180, 20, 40, 40, 1, 1, 1, 0, 0, "object-window") }
    local canvas = pass:render(graphics, frame)
    local data = snapshot(canvas)
    checkPixel(data, 200, 40, 0, 63, 0, "OBJ-window coverage selects its mask")
    checkPixel(data, 40, 40, 63, 0, 0, "uncovered pixels keep the outside mask")
    data:release()
  end
  -- Equal-priority overlapping OBJ keeps native submission order: the
  -- first-submitted fragment wins each shared pixel.
  do
    local frame = compositionFrame()
    frame.planes = { battlefield = { color = { 0, 0, 0 } } }
    frame.objects = {
      rectObject(graphics, 60, 60, 40, 40, 1, 0, 0, 1, 0),
      rectObject(graphics, 60, 60, 40, 40, 0, 0, 1, 1, 1),
    }
    local canvas = pass:render(graphics, frame)
    local data = snapshot(canvas)
    checkPixel(data, 80, 80, 63, 0, 0, "the first-submitted OBJ wins its pixels")
    data:release()
  end
  -- Both transition layers coexist through a priority change: blue on top
  -- first, then the world beneath it once priorities swap.
  do
    local frame = compositionFrame()
    frame.primitives = { quad(texture, { r = 31, g = 0, b = 0 }, 31, 0) }
    frame.planes = { transition = { color = { 0, 0, 1 } } }
    frame.animation.priority = { world3d = 1, window = 0, transition = 0, battlefield = 3 }
    local canvas = pass:render(graphics, frame)
    local data = snapshot(canvas)
    checkPixel(data, 128, 96, 0, 0, 63, "the incoming transition layer covers first")
    data:release()
    frame.animation.priority.transition = 3
    local canvas2 = pass:render(graphics, frame)
    local data2 = snapshot(canvas2)
    checkPixel(data2, 128, 96, 63, 0, 0, "priority state restores the world without redrawing order")
    data2:release()
  end
  -- Mosaic samples the block origin: column 65 samples column 64 (red)
  -- under a 4-wide block, while the unmosaicked toggle shows white.
  local function stripePlanes()
    return {
      battlefield = {
        draw = function(lg)
          for x = 0, WIDTH - 1 do
            if x % 2 == 0 then
              lg.setColor(1, 0, 0, 1)
            else
              lg.setColor(1, 1, 1, 1)
            end
            lg.rectangle("fill", x, 0, 1, HEIGHT)
          end
        end,
      },
    }
  end
  do
    local frame = compositionFrame()
    frame.planes = stripePlanes()
    frame.mosaic = { size = 4, layers = { battlefield = true } }
    local canvas = pass:render(graphics, frame)
    local data = snapshot(canvas)
    checkPixel(data, 65, 96, 63, 0, 0, "mosaic samples the block origin texel")
    data:release()
    frame.mosaic = { size = 1, layers = {} }
    local canvas2 = pass:render(graphics, frame)
    local data2 = snapshot(canvas2)
    checkPixel(data2, 65, 96, 63, 63, 63, "the same texel samples directly without mosaic")
    data2:release()
  end
  -- Scanline rows shift the designated layer only: row 96 reads one texel
  -- right (white), row 97 reads straight (red), and the transition layer
  -- above ignores both rows.
  do
    local rows = {}
    for row = 1, HEIGHT do
      rows[row] = { x = 0, y = 0 }
    end
    rows[97] = { x = 1, y = 0 }
    local frame = compositionFrame()
    frame.planes = stripePlanes()
    frame.planes.transition = {
      draw = function(lg)
        lg.setColor(0, 0, 1, 1)
        lg.rectangle("fill", 0, 0, 128, HEIGHT)
      end,
    }
    frame.animation.priority = { world3d = 1, window = 3, transition = 0, battlefield = 3 }
    frame.scanlines = rows
    frame.scanlineLayer = "battlefield"
    local canvas = pass:render(graphics, frame)
    local data = snapshot(canvas)
    checkPixel(data, 200, 96, 63, 63, 63, "the shifted row samples one texel right")
    checkPixel(data, 200, 97, 63, 0, 0, "the next row samples straight")
    checkPixel(data, 10, 96, 0, 0, 63, "rows above the designated layer ignore the shift")
    checkPixel(data, 10, 97, 0, 0, 63, "the designated layer alone carries row state")
    data:release()
  end
end

-- RGBA sprite with a transparent border over an opaque center: the
-- shared picture cutout for staged portrait, shadow, and effect art.
local function borderedImage(graphics, scope, red, green, blue)
  local data = love.image.newImageData(64, 64)
  for y = 0, 63 do
    for x = 0, 63 do
      if x == 0 or y == 0 or x == 63 or y == 63 then
        data:setPixel(x, y, 0, 0, 0, 0)
      else
        data:setPixel(x, y, red, green, blue, 1)
      end
    end
  end
  local image = scope:own(graphics.newImage(data))
  image:setFilter("nearest", "nearest")
  return image
end

function T.compact_view_keeps_source_geometry_under_one_transform(scope)
  local graphics = love.graphics
  local texture = solidImage(graphics, scope, 1, 0, 0)
  local pass = scope:own(BattlePicturePass.new(graphics))
  local function worldFrame()
    local frame = compositionFrame()
    frame.animation.backdrop = { 0, 0, 0 }
    frame.primitives = { quad(texture, { r = 31, g = 0, b = 0 }, 31, 0) }
    frame.planes = { battlefield = { color = { 0, 1, 0 } } }
    frame.objects = { rectObject(graphics, 200, 140, 40, 30, 0, 0, 1, 0, 0) }
    return frame
  end
  local detail = worldFrame()
  local detailCanvas = pass:render(graphics, detail)
  local detailData = snapshot(detailCanvas)
  checkPixel(detailData, 128, 96, 63, 0, 0, "detail centers the composed world")
  checkPixel(detailData, 220, 155, 0, 0, 63, "detail keeps OBJ under its own priority")
  detailData:release()
  local compact = worldFrame()
  compact.layout = {
    worldRect = { x = 0, y = 0, width = 256, height = 96 },
    scale = 0.5,
    offsetX = 0,
    offsetY = 48,
  }
  local compactCanvas = pass:render(graphics, compact)
  Assert.isTrue(compactCanvas == detailCanvas, "both views share the borrowed canvas")
  local compactData = snapshot(compactCanvas)
  -- Native (128, 96) lands at (64, 96); the OBJ rect (200..240, 140..170)
  -- lands at (100..120, 118..133); padding keeps the backdrop.
  checkPixel(compactData, 64, 96, 63, 0, 0, "the compact transform carries world geometry")
  checkPixel(compactData, 110, 125, 0, 0, 63, "the compact transform carries OBJ under priority")
  checkPixel(compactData, 8, 8, 0, 0, 0, "padding outside the fitted battlefield keeps the backdrop")
  compactData:release()
  Assert.equal(#compact.primitives, 1, "toggling views advances nothing")
  local detailAgain = worldFrame()
  local canvasAgain = pass:render(graphics, detailAgain)
  local dataAgain = snapshot(canvasAgain)
  checkPixel(dataAgain, 128, 96, 63, 0, 0, "returning to detail restores the same pixels")
  dataAgain:release()
end

function T.failed_frames_keep_the_last_good_canvas(scope)
  local graphics = love.graphics
  local pass = BattlePicturePass.new(graphics)
  local function goodFrame(red, green, blue)
    local textureData = love.image.newImageData(8, 8)
    for y = 0, 7 do
      for x = 0, 7 do
        textureData:setPixel(x, y, red, green, blue, 1)
      end
    end
    local texture = scope:own(graphics.newImage(textureData))
    texture:setFilter("nearest", "nearest")
    local frame = compositionFrame()
    frame.primitives = { quad(texture, { r = 31, g = 0, b = 0 }, 31, 0) }
    frame.planes = { battlefield = { color = { 0, 1, 0 } } }
    return frame
  end
  local canvas = pass:render(graphics, goodFrame(1, 0, 0))
  local data = snapshot(canvas)
  checkPixel(data, 128, 96, 63, 0, 0, "the good frame stages first")
  data:release()
  local bad = goodFrame(1, 0, 0)
  bad.planes = {
    battlefield = {
      draw = function()
        error("staged plane acquisition failed", 0)
      end,
    },
  }
  local ok, failure = pcall(pass.render, pass, graphics, bad)
  Assert.isFalse(ok, "a failed plane acquisition surfaces, got " .. tostring(failure))
  local survivor = snapshot(canvas)
  checkPixel(survivor, 128, 96, 63, 0, 0, "the failed frame preserves the last good pixels")
  survivor:release()
  local canvas2 = pass:render(graphics, goodFrame(1, 0, 0))
  Assert.isTrue(canvas2 == canvas, "the surviving canvas stays borrowed")
  local data2 = snapshot(canvas2)
  checkPixel(data2, 128, 96, 63, 0, 0, "a successor frame replaces cleanly after failure")
  data2:release()
  pass:release()
  pass:release()
end

function T.transparent_plane_layers_composite_over_instead_of_erasing(scope)
  -- One opaque background plus an RGBA sprite with a transparent
  -- border: every border pixel must stay background-colored, never
  -- backdrop-black. Under replace blending the sprite's alpha-zero
  -- border punches a rectangular hole through the plane.
  local graphics = love.graphics
  local sprite = borderedImage(graphics, scope, 0, 0, 1)
  local pass = scope:own(BattlePicturePass.new(graphics))
  local frame = compositionFrame({ engine = "main" })
  frame.planes = {
    battlefield = {
      draw = function(graphics)
        graphics.setColor(1, 0, 0, 1)
        graphics.rectangle("fill", 0, 0, WIDTH, HEIGHT)
        graphics.setColor(1, 1, 1, 1)
        graphics.draw(sprite, 96, 64)
      end,
    },
  }
  local canvas = pass:render(graphics, frame)
  local data = snapshot(canvas)
  checkPixel(data, 10, 10, 63, 0, 0, "the background stays opaque away from the sprite")
  checkPixel(data, 96, 64, 63, 0, 0, "the sprite border preserves the background underneath")
  checkPixel(data, 159, 127, 63, 0, 0, "the far sprite border preserves the background underneath")
  checkPixel(data, 128, 96, 0, 0, 63, "the sprite center paints its own color")
  data:release()
end

function T.transparent_corners_never_occlude_the_picture_behind(scope)
  -- A nearer picture with transparent corners over an opaque picture:
  -- alpha-zero corners must discard in the cutout pass instead of
  -- writing depth on the opaque path and hiding the picture behind.
  local graphics = love.graphics
  local behind = solidImage(graphics, scope, 0, 1, 0)
  local front = borderedImage(graphics, scope, 1, 0, 0)
  local pass = scope:own(BattlePicturePass.new(graphics))
  local function picture(image, clipZ)
    local primitive = quad(image, { r = 31, g = 31, b = 31 }, 31, clipZ)
    -- Production classification behind staged portrait, shadow, and
    -- effect art: transparent texels discard, opaque texels keep depth.
    primitive.alphaUsage = { hasZero = true, hasOpaque = true }
    return primitive
  end
  local frame = compositionFrame()
  frame.planes = {}
  frame.primitives = { picture(behind, 0), picture(front, -512) }
  local canvas = pass:render(graphics, frame)
  local data = snapshot(canvas)
  checkPixel(data, 2, 2, 0, 63, 0, "the transparent corner reveals the picture behind")
  checkPixel(data, 253, 189, 0, 63, 0, "the far transparent corner reveals the picture behind")
  checkPixel(data, 128, 96, 63, 0, 0, "the opaque center covers the picture behind")
  data:release()
end

function T.picture_palette_pulses_apply_in_the_shared_target(scope)
  -- The legacy picture fade blends each texel toward its RGB555 target
  -- in exact 5-bit steps; the shared Gx target must paint the same
  -- source colors instead of dropping the fade at the draw boundary.
  local graphics = love.graphics
  local texture = solidImage(graphics, scope, 1, 0, 0)
  local pass = scope:own(BattlePicturePass.new(graphics))
  local function fadedFrame(intensity)
    local frame = compositionFrame()
    frame.planes = {}
    -- White vertex tint: the fade blends the red texel toward blue
    -- before the combiner, so the tint must not prefilter the target.
    local primitive = quad(texture, { r = 31, g = 31, b = 31 }, 31, 0)
    primitive.paletteFade = {
      applied = true,
      targetColor = 0x7C00,
      intensity = intensity,
    }
    frame.primitives = { primitive }
    return frame
  end
  local full = snapshot(pass:render(graphics, fadedFrame(16)))
  -- Full strength reaches the blue target exactly.
  checkPixel(full, 128, 96, 0, 0, 63, "a finished pulse paints its target color")
  full:release()
  local halfData = snapshot(pass:render(graphics, fadedFrame(8)))
  -- Source formula: red 31 + floor((0 - 31) * 8 / 16) = 15 and blue
  -- 0 + 15 = 15, so both channels land strictly inside the endpoints
  -- and stay symmetric through the shared 6-bit/staging resolve.
  local hr, hg, hb = pixel6(halfData, 128, 96)
  Assert.isTrue(hr > 0 and hr < 63, "a partial pulse dims red, got " .. hr)
  Assert.isTrue(hb > 0 and hb < 63, "a partial pulse lifts blue, got " .. hb)
  Assert.equal(hr, hb, "the partial pulse blends both channels symmetrically")
  Assert.equal(hg, 0, "the partial pulse keeps green at zero")
  halfData:release()
  local none = snapshot(pass:render(graphics, fadedFrame(0)))
  checkPixel(none, 128, 96, 63, 0, 0, "a zero pulse keeps the source color")
  none:release()
end

function T.scripted_background_grayscale_grays_the_battlefield_plane(scope)
  -- Native MAIN_BG fade-buffer grayscale
  -- (battle_anim_util.c PaletteToGrayscale):
  -- level = (b * 29 + r * 76 + g * 151) >> 8.
  local graphics = love.graphics
  local pass = scope:own(BattlePicturePass.new(graphics))
  local function grayFrame(flag)
    local frame = compositionFrame()
    frame.animation.grayscaleBattlefield = flag
    frame.primitives = {}
    frame.planes = { battlefield = { color = { 1, 0, 0 } } }
    return frame
  end
  local gray = snapshot(pass:render(graphics, grayFrame(true)))
  -- Red level (0 * 29 + 31 * 76 + 0 * 151) >> 8 = 9, then 9 / 31 of 63.
  checkPixel(gray, 128, 96, 18, 18, 18, "the grayscale flag grays the battlefield plane")
  gray:release()
  local plain = snapshot(pass:render(graphics, grayFrame(false)))
  checkPixel(plain, 128, 96, 63, 0, 0, "the settled plane keeps its source color")
  plain:release()
end

return GraphicsSmoke.suite(T)
