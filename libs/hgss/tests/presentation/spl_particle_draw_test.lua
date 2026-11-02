-- SplParticleDraw contracts over a recording graphics namespace.

local Assert = require("tests.support.Assert")
local SplParticleDraw = require("libs.hgss.src.presentation.SplParticleDraw")

local T = {}

local function image(name)
  return {
    name = name,
    getWidth = function()
      return 8
    end,
    getHeight = function()
      return 8
    end,
  }
end

local function recorder()
  local graphics = { calls = {}, color = nil, shaders = {}, shader = nil }
  function graphics.newQuad(x, y, w, h, imgW, imgH)
    return { w = w, h = h, x = x, y = y, imgW = imgW, imgH = imgH }
  end
  function graphics.newShader()
    local shader = { sends = {} }
    function shader.send(_, name, value)
      shader.sends[#shader.sends + 1] = { name = name, value = value }
    end
    graphics.shaders[#graphics.shaders + 1] = shader
    return shader
  end
  function graphics.getShader()
    return graphics.shader
  end
  function graphics.setShader(shader)
    graphics.shader = shader
  end
  function graphics.setColor(r, g, b, a)
    graphics.color = { r, g, b, a }
  end
  function graphics.draw(img, quad, x, y, rotation, sx, sy, ox, oy)
    graphics.calls[#graphics.calls + 1] = {
      image = img,
      quad = quad,
      x = x,
      y = y,
      rotation = rotation,
      sx = sx,
      sy = sy,
      ox = ox,
      oy = oy,
      color = graphics.color,
    }
  end
  return graphics
end

local function particle(overrides)
  local value = {
    x = 0,
    y = 0,
    z = 0,
    ex = 0,
    ey = 0,
    ez = 0,
    vx = 0,
    vy = 0,
    vz = 0,
    baseAlpha = 31,
    animAlpha = 31,
    baseScale = 4096,
    animScale = 4096,
    colorRgb = { r = 31, g = 0, b = 31 },
    rtt = 0,
    texNo = 0,
  }
  for key, v in pairs(overrides or {}) do
    value[key] = v
  end
  return value
end

local function record(overrides)
  local value = {
    aspect = 1,
    sclAnmDirect = 0,
    drawType = 0,
    dbbScale = 0,
    texRepeat = { s = 0, t = 0 },
    child = { drawType = 0, texRepeat = { s = 1, t = 0 }, texNo = 9 },
  }
  for key, v in pairs(overrides or {}) do
    value[key] = v
  end
  return value
end

local function simulate(runtimes)
  return { emitters = runtimes }
end

local function runtime(rec, particles, children)
  return { record = rec, particles = particles or {}, children = children or {} }
end

local function options(images)
  return {
    centerX = 128,
    centerY = 96,
    resolveTexture = function(_, p, child)
      return images[child ~= nil and "child" or p.texNo]
    end,
  }
end

function T.billboard_projects_world_units_to_pane_pixels_with_color_and_alpha()
  local graphics = recorder()
  local images = { [0] = image("a") }
  local sim = simulate({ runtime(record(), { particle({ x = 1, y = 2, colorRgb = { r = 31, g = 0, b = 15 } }) }) })
  SplParticleDraw.draw(graphics, sim, options(images))
  Assert.equal(#graphics.calls, 1, "one particle draws")
  local call = graphics.calls[1]
  Assert.equal(call.x, 128 + 24, "world x maps to pane pixels")
  Assert.equal(call.y, 96 - 48, "world +y maps up")
  Assert.equal(call.sx, 2 * 24 / 8, "a unit-scale quad spans 2 world units")
  Assert.deepEqual(call.color, { 1, 0, 15 / 31, 1 }, "color and alpha normalize from 5-bit channels")
  Assert.deepEqual(graphics.color, { 1, 1, 1, 1 }, "the draw color resets")
end

function T.texture_selection_follows_each_particles_texNo_and_child_record()
  local graphics = recorder()
  local images = { [0] = image("a"), [3] = image("b"), child = image("c") }
  local sim = simulate({
    runtime(record(), { particle({ texNo = 3, z = -1 }), particle({ texNo = 0, z = -2 }) }, { particle() }),
  })
  SplParticleDraw.draw(graphics, sim, options(images))
  local names = {}
  for _, call in ipairs(graphics.calls) do
    names[#names + 1] = call.image.name
  end
  Assert.deepEqual(names, { "a", "b", "c" }, "particles show their own texture and children the child art")
  Assert.equal(graphics.calls[3].quad.w, 16, "the child repeat power tiles its quad")
end

function T.far_particles_draw_first_and_out_of_range_depths_are_clipped()
  local graphics = recorder()
  local images = { [0] = image("a") }
  local sim = simulate({
    runtime(record(), {
      particle({ x = 1, z = 2 }),
      particle({ x = 2, z = -3 }),
      particle({ x = 3, z = 4 }),
      particle({ x = 4, z = -900 }),
    }),
  })
  SplParticleDraw.draw(graphics, sim, options(images))
  local xs = {}
  for _, call in ipairs(graphics.calls) do
    xs[#xs + 1] = (call.x - 128) / 24
  end
  Assert.deepEqual(xs, { 2, 1 }, "the farthest visible draws first; nearer than 1 or beyond 900 is clipped")
end

function T.transparent_particles_draw_nothing()
  local graphics = recorder()
  local sim = simulate({ runtime(record(), { particle({ baseAlpha = 0 }) }) })
  SplParticleDraw.draw(graphics, sim, options({ [0] = image("a") }))
  Assert.equal(#graphics.calls, 0, "alpha zero is skipped")
end

function T.child_first_emitters_order_children_before_parents_at_equal_depth()
  local images = { [0] = image("a"), child = image("c") }
  local function order(childFirst)
    local graphics = recorder()
    local sim = simulate({ runtime(record({ drawChildFirst = childFirst }), { particle() }, { particle() }) })
    SplParticleDraw.draw(graphics, sim, options(images))
    return graphics.calls[1].image.name .. graphics.calls[2].image.name
  end
  Assert.equal(order(nil), "ac", "parents draw before children by default")
  Assert.equal(order(true), "ca", "draw_child_first emitters draw children first")
end

function T.texture_offset_moves_the_quad_pivot_in_half_extents()
  local graphics = recorder()
  local sim = simulate({ runtime(record({ textureOffset = { mode = 0, x = 0.5, y = 0.5 } }), { particle() }) })
  SplParticleDraw.draw(graphics, sim, options({ [0] = image("a") }))
  Assert.equal(graphics.calls[1].ox, 2, "a +x offset puts the pivot left of the image center")
  Assert.equal(graphics.calls[1].oy, 6, "a +y offset puts the pivot below the image center")
end

function T.directional_billboard_rotates_along_velocity()
  local graphics = recorder()
  local sim = simulate({
    runtime(record({ drawType = 1, dbbScale = 4096 }), { particle({ vx = 0, vy = 1, vz = 0 }) }),
  })
  SplParticleDraw.draw(graphics, sim, options({ [0] = image("a") }))
  Assert.equal(graphics.calls[1].rotation, 0, "a +y velocity aligns the quad x-axis with screen x")
  Assert.equal(graphics.calls[1].sy, 2 * 24 * 2 / 8, "screen-parallel motion stretches the y extent")
end

function T.pooled_indexed_lease_draws_through_its_own_palette_sampler()
  local ImageAssetPool = require("libs.hgss.src.presentation.ImageAssetPool")
  local graphics = recorder()
  local source = {}
  function source.setFilter() end
  local palette = {}
  function palette.setFilter() end
  function palette.getWidth()
    return 4
  end
  -- Production leases expose only width/height/drawQuad: no raw
  -- getWidth/getHeight/setWrap, so shared drawing must route through
  -- the lease instead of unwrapping its image.
  local lease = setmetatable({
    image = source,
    palette = palette,
    kind = "r8",
    width = 8,
    height = 8,
  }, ImageAssetPool.Lease)
  local sim = simulate({ runtime(record({ texRepeat = { s = 1, t = 0 } }), { particle() }) })
  SplParticleDraw.draw(graphics, sim, options({ [0] = lease }))
  Assert.equal(#graphics.calls, 1, "one pooled particle draws")
  local call = graphics.calls[1]
  Assert.isTrue(call.image == source, "the palette shader draws the index image, never the lease handle")
  Assert.equal(call.quad.w, 16, "the x2 repeat power tiles the sampled viewport")
  Assert.equal(call.quad.h, 8, "the unrepeated axis keeps its source height")
  Assert.equal(call.quad.imgW, 8, "the quad keeps the unrepeated source width")
  Assert.equal(call.quad.imgH, 8, "the quad keeps the unrepeated source height")
  Assert.deepEqual(call.color, { 1, 0, 1, 1 }, "the lease draw carries the particle color")
  local shader = graphics.shaders[1]
  Assert.notNil(shader, "the indexed draw binds the sampling shader")
  local sends = {}
  for _, send in ipairs(shader.sends) do
    sends[send.name] = send.value
  end
  Assert.isTrue(sends.u_usePalette == true, "the indexed draw enables palette sampling")
  Assert.isTrue(sends.u_palette == palette, "the indexed draw binds the lease palette")
  Assert.isTrue(graphics.shader == nil, "the draw restores the previous shader")
  Assert.deepEqual(graphics.color, { 1, 1, 1, 1 }, "the draw color resets")
end

function T.raw_images_keep_directional_and_child_first_draws()
  local graphics = recorder()
  local rec = record({
    drawType = 1,
    dbbScale = 4096,
    drawChildFirst = true,
    child = { drawType = 1, texRepeat = { s = 0, t = 0 }, texNo = 9 },
  })
  local sim = simulate({
    runtime(rec, { particle({ vx = 0, vy = 1, vz = 0 }) }, { particle({ vx = 0, vy = 1, vz = 0, rtt = 16384 }) }),
  })
  SplParticleDraw.draw(graphics, sim, options({ [0] = image("a"), child = image("c") }))
  Assert.equal(#graphics.calls, 2, "parent and directional child both draw through raw images")
  Assert.equal(
    graphics.calls[1].image.name .. graphics.calls[2].image.name,
    "ca",
    "children draw before parents when the emitter asks for it"
  )
  for _, call in ipairs(graphics.calls) do
    Assert.equal(call.rotation, 0, "screen-parallel motion aligns the quad x-axis")
    Assert.equal(call.sy, 2 * 24 * 2 / 8, "screen-parallel motion stretches the y extent")
  end
end

function T.directional_children_follow_their_velocity_with_the_emitter_stretch()
  local graphics = recorder()
  local rec = record({ dbbScale = 4096 })
  rec.child.drawType = 1
  local child = particle({ vx = 0, vy = 1, vz = 0, rtt = 16384 })
  local sim = simulate({ runtime(rec, {}, { child }) })
  SplParticleDraw.draw(graphics, sim, options({ child = image("c") }))
  Assert.equal(graphics.calls[1].rotation, 0, "a directional child ignores its own angle and follows velocity")
  Assert.equal(graphics.calls[1].sy, 2 * 24 * 2 / 8, "screen-parallel motion stretches the child like its emitter")
end

return { tests = T }
