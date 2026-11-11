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

-- Battle-default manager camera behind overlay draws: the shared
-- producer reads the simulation camera, so camera-less unit sims would
-- exercise only the degenerate fallback. These values mirror the
-- Simulation.new defaults the field, opening, and evolution panes run.
local function simulate(runtimes)
  return {
    emitters = runtimes,
    camera = {
      x = 0,
      y = 0,
      z = 16384,
      targetX = 0,
      targetY = 0,
      targetZ = 0,
      upX = 0,
      upY = 4096,
      upZ = 0,
      distance = 16384,
      halfFov = 8192,
      aspect = 5461,
      near = 4096,
      far = 3686400,
      perspective = 0,
    },
  }
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

-- The pane maps the shared producer's clip output: normalized device
-- coordinates scale by the center on each axis with the host Y flip, so
-- the overlay matches the battle composition's mapping instead of a
-- parallel orthographic path. Values below are the producer output for
-- the battle camera above, pinned against the real fixed-point math.
function T.billboard_projects_producer_clip_into_pane_pixels_with_color_and_alpha()
  local graphics = recorder()
  local images = { [0] = image("a") }
  local sim = simulate({ runtime(record(), { particle({ x = 1, y = 2, colorRgb = { r = 31, g = 0, b = 15 } }) }) })
  SplParticleDraw.draw(graphics, sim, options(images))
  Assert.equal(#graphics.calls, 1, "one particle draws")
  local call = graphics.calls[1]
  Assert.equal(call.x, 136, "the producer clip maps onto the pane")
  Assert.equal(call.y, 80, "pane +y stays up through the host flip")
  Assert.equal(call.sx, 14, "the recovered quad transform spans the projected corners")
  Assert.equal(call.sy, 14, "the recovered quad transform spans the projected corners")
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

function T.far_particles_draw_first_in_producer_depth_order()
  local graphics = recorder()
  local images = { [0] = image("a"), [1] = image("b"), [2] = image("c"), [3] = image("d") }
  local sim = simulate({
    runtime(record(), {
      particle({ x = 1, z = 0, texNo = 0 }),
      particle({ x = 2, z = -1, texNo = 1 }),
      particle({ x = 3, z = 1, texNo = 2 }),
      particle({ x = 4, z = -2, texNo = 3 }),
    }),
  })
  SplParticleDraw.draw(graphics, sim, options(images))
  Assert.equal(#graphics.calls, 4, "every frontal primitive draws through the shared camera")
  local names = {}
  for _, call in ipairs(graphics.calls) do
    names[#names + 1] = call.image.name
  end
  -- Producer depths under the battle camera order z=-2, z=-1, z=0,
  -- z=1 from far to near; the pane drains them in that order instead
  -- of re-sorting by world depth.
  Assert.deepEqual(names, { "d", "b", "a", "c" }, "the farthest primitive draws first")
  Assert.near(graphics.calls[1].x, 155.4286, 1e-4, "the farthest primitive lands on its projected corner")
  Assert.near(graphics.calls[4].x, 154.1818, 1e-4, "the nearest primitive lands on its projected corner")
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

function T.texture_offset_moves_the_quad_center_through_the_producer()
  local graphics = recorder()
  local sim = simulate({ runtime(record({ textureOffset = { mode = 0, x = 0.5, y = 0.5 } }), { particle() }) })
  SplParticleDraw.draw(graphics, sim, options({ [0] = image("a") }))
  -- The offset rides the producer's local corners, so the projected
  -- quad center shifts while the pivot stays the quad center.
  Assert.equal(graphics.calls[1].x, 132, "a +x offset moves the quad center right")
  Assert.equal(graphics.calls[1].y, 92, "a +y offset moves the quad center up")
  Assert.equal(graphics.calls[1].ox, 4, "the pivot stays the quad center")
  Assert.equal(graphics.calls[1].oy, 4, "the pivot stays the quad center")
end

function T.directional_billboard_rotates_along_velocity()
  local graphics = recorder()
  local sim = simulate({
    runtime(record({ drawType = 1, dbbScale = 4096 }), { particle({ vx = 0, vy = 1, vz = 0 }) }),
  })
  SplParticleDraw.draw(graphics, sim, options({ [0] = image("a") }))
  Assert.near(graphics.calls[1].rotation, math.pi, 1e-6, "the recovered x-axis follows the projected quad")
  Assert.equal(graphics.calls[1].sy, 28, "screen-parallel motion stretches the y extent through the producer")
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
    Assert.near(call.rotation, math.pi, 1e-6, "the recovered x-axis follows the projected quad")
    Assert.equal(call.sy, 28, "screen-parallel motion stretches the y extent through the producer")
  end
end

function T.directional_children_follow_their_velocity_with_the_emitter_stretch()
  local graphics = recorder()
  local rec = record({ dbbScale = 4096 })
  rec.child.drawType = 1
  local child = particle({ vx = 0, vy = 1, vz = 0, rtt = 16384 })
  local sim = simulate({ runtime(rec, {}, { child }) })
  SplParticleDraw.draw(graphics, sim, options({ child = image("c") }))
  Assert.near(graphics.calls[1].rotation, math.pi, 1e-6, "a directional child follows velocity through the producer")
  Assert.equal(graphics.calls[1].sy, 28, "screen-parallel motion stretches the child like its emitter")
end

-- Battle composition consumes an ordered, pure homogeneous primitive array
-- from the captured simulation state: one record per native polygon with
-- clip-space positions, normalized UVs, and material state, in native
-- submission order. Host drawing never re-sorts it and simulation never
-- advances while producing it.
function T.primitive_production_is_a_pure_ordered_clip_space_array()
  Assert.isTrue(
    type(SplParticleDraw.appendPrimitives) == "function",
    "battle composition consumes one pure ordered primitive producer instead of " .. "the overlay draw path"
  )
end

local function geometryRecord(overrides)
  local value = record({
    aspect = 1,
    sclAnmDirect = 0,
    drawType = 0,
    dbbScale = 0,
    texRepeat = { s = 0, t = 0 },
    reverseTex = { s = false, t = false },
    polygonRotationAxis = "y",
    polygonPlane = "xy",
  })
  for key, v in pairs(overrides or {}) do
    value[key] = v
  end
  return value
end

local function geometryCamera()
  return {
    x = 0,
    y = 0,
    z = 16384,
    targetX = 0,
    targetY = 0,
    targetZ = 0,
    upX = 0,
    upY = 4096,
    upZ = 0,
    distance = 16384,
    angleX = 0,
    angleY = 0,
    angleZ = 0,
    halfFov = 8192,
    aspect = 5461,
    near = 4096,
    far = 3686400,
    perspective = 1,
  }
end

local function geometryRuntime(rec, particles, children)
  return {
    record = rec,
    resource = { position = { x = 0, y = 0, z = 0 } },
    particles = particles or {},
    children = children or {},
  }
end

local function centeredParticle(overrides)
  local value = particle({
    x = 0,
    y = 0,
    z = 0,
    ex = 0,
    ey = 0,
    ez = 0,
    vx = 0,
    vy = 0,
    vz = 1,
    baseScale = 4096,
    animScale = 4096,
    baseAlpha = 31,
    animAlpha = 31,
    rtt = 0,
    pid = 6,
    colorRgb = { r = 31, g = 31, b = 31 },
  })
  for key, v in pairs(overrides or {}) do
    value[key] = v
  end
  return value
end

function T.orthographic_projection_centers_the_world_origin_with_real_depth()
  local camera = geometryCamera()
  local sim = { emitters = { geometryRuntime(geometryRecord(), { centeredParticle() }) } }
  local primitives = SplParticleDraw.appendPrimitives(sim, camera, function()
    return nil
  end, {})
  Assert.equal(#primitives, 1, "one live particle appends one polygon")
  local vertices = primitives[1].vertices
  local centerX = (vertices[1].clipX + vertices[2].clipX + vertices[3].clipX + vertices[4].clipX) / 4
  local centerY = (vertices[1].clipY + vertices[2].clipY + vertices[3].clipY + vertices[4].clipY) / 4
  Assert.equal(centerX, 0, "the world origin projects to the clip center")
  Assert.equal(centerY, 0, "the world origin projects to the clip middle")
  for _, vertex in ipairs(vertices) do
    Assert.equal(vertex.clipW, 4096, "the orthographic quad keeps a constant w")
  end
  Assert.isTrue(math.abs(vertices[1].clipX) > 100, "the projected half width is real, not a unit placeholder")
  Assert.isTrue(math.abs(vertices[1].clipY) > 100, "the projected half height is real, not a unit placeholder")
  Assert.equal(vertices[1].clipX, -vertices[2].clipX, "the quad stays symmetric in x")
  Assert.equal(vertices[1].clipY, -vertices[4].clipY, "the quad stays symmetric in y")
  Assert.equal(primitives[1].polygonId, 6, "the primitive carries the per-tick polygon identity")
end

function T.positive_rotation_turns_corners_counterclockwise()
  local camera = geometryCamera()
  local function quadAt(rtt)
    local sim = { emitters = { geometryRuntime(geometryRecord(), { centeredParticle({ rtt = rtt }) }) } }
    local primitives = SplParticleDraw.appendPrimitives(sim, camera, function()
      return nil
    end, {})
    return primitives[1].vertices
  end
  local resting = quadAt(0)
  local turned = quadAt(16384)
  Assert.equal(turned[1].clipX, resting[4].clipX, "a quarter turn moves the top-left corner to the bottom-left x")
  Assert.equal(turned[1].clipY, resting[4].clipY, "a quarter turn moves the top-left corner to the bottom-left y")
  Assert.equal(turned[2].clipX, resting[1].clipX, "a quarter turn moves the top-right corner to the top-left x")
  Assert.equal(turned[2].clipY, resting[1].clipY, "a quarter turn moves the top-right corner to the top-left y")
end

function T.parent_and_child_matrix_orders_differ_for_stretched_quads()
  local camera = geometryCamera()
  local function quadsFor(aspect)
    local rec = geometryRecord({ aspect = aspect, drawType = 2, polygonPlane = "xz" })
    rec.child = {
      drawType = 2,
      polygonRotationAxis = "y",
      polygonPlane = "xz",
      texRepeat = { s = 0, t = 0 },
    }
    local made = centeredParticle({ rtt = 8192 })
    local sim = { emitters = { geometryRuntime(rec, { made }, {}) } }
    local view, proj = SplParticleDraw.cameraViewProjection(sim, camera)
    local runtime = sim.emitters[1]
    local parent = SplParticleDraw.particleClipQuad(runtime, made, nil, view, proj)
    local child = SplParticleDraw.particleClipQuad(runtime, made, rec.child, view, proj)
    return parent, child
  end
  local uniformParent, uniformChild = quadsFor(1)
  Assert.equal(uniformParent[1].x, uniformChild[1].x, "uniform scale commutes across the rotation")
  Assert.equal(uniformParent[1].y, uniformChild[1].y, "uniform scale commutes in y")
  local stretchedParent, stretchedChild = quadsFor(2)
  Assert.isTrue(
    stretchedParent[1].x ~= stretchedChild[1].x or stretchedParent[1].y ~= stretchedChild[1].y,
    "stretched scale before rotation differs from rotation before scale"
  )
end

function T.uv_spans_follow_repeat_powers_and_mirror_flags()
  local camera = geometryCamera()
  local rec = geometryRecord({ texRepeat = { s = 1, t = 2 }, reverseTex = { s = true, t = false } })
  rec.child = {
    drawType = 0,
    texRepeat = { s = 0, t = 1 },
    reverseTex = { s = false, t = true },
  }
  local sim = {
    emitters = { geometryRuntime(rec, { centeredParticle() }, { centeredParticle() }) },
  }
  local primitives = SplParticleDraw.appendPrimitives(sim, camera, function()
    return nil
  end, {})
  Assert.equal(#primitives, 2, "parent and child both append in native order")
  local parent, child = primitives[1], primitives[2]
  Assert.equal(parent.vertices[2].u, -2, "the parent signed s span negates its x2 repeat")
  Assert.equal(parent.vertices[3].v, 4, "the parent t span tiles its x4 repeat")
  Assert.equal(child.vertices[2].u, 1, "the child keeps its own s span")
  Assert.equal(child.vertices[3].v, -2, "the child signed t span negates its x2 repeat")
end

return { tests = T }
