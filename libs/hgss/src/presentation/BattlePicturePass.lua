-- Projects the source Pokepic quad into an isolated color/depth layer.

local BattlePicturePass = {}
BattlePicturePass.__index = BattlePicturePass

local WIDTH, HEIGHT = 256, 192
local DEPTH_RANGE = 1024
local VERTEX_FORMAT = {
  { "VertexPosition", "float", 3 },
  { "VertexTexCoord", "float", 2 },
  { "VertexNormal", "float", 3 },
  { "VertexColor", "float", 4 },
  { "VertexColorSource", "float", 1 },
}
local SHADER = [[
#ifdef VERTEX
varying vec2 vTexCoord;

vec4 position(mat4 transform_projection, vec4 vertex_position)
{
  vTexCoord = VertexTexCoord.xy;
  return vec4(vertex_position.x / 128.0 - 1.0,
    vertex_position.y / 96.0 - 1.0, vertex_position.z, 1.0);
}
#endif

#ifdef PIXEL
varying vec2 vTexCoord;
uniform vec3 paletteFadeColor;
uniform float paletteFadeAmount;
vec4 effect(vec4 color, Image image, vec2 texture_coords, vec2 screen_coords)
{
  vec4 pixel = Texel(image, vTexCoord);
  if (pixel.a <= 0.0) discard;
  if (paletteFadeAmount > 0.0) {
    vec3 source5 = floor(pixel.rgb * 31.0 + 0.5);
    vec3 target5 = floor(paletteFadeColor * 31.0 + 0.5);
    vec3 blended5 = source5 + floor((target5 - source5) * paletteFadeAmount / 16.0);
    pixel.rgb = (blended5 * 8.0 + floor(blended5 / 4.0)) / 255.0;
  }
  pixel *= color;
  return pixel;
}
#endif
]]

local function angle(value)
  return (value or 0) * (2 * math.pi / 0x10000)
end

local function vertex(x, y, z, u, v)
  return { x, y, z, u, v, 0, 0, 1, 1, 1, 1, 1, 0 }
end

local function paletteFade(fade)
  if type(fade) ~= "table" or fade.applied ~= true then
    return { 0, 0, 0 }, 0
  end
  local color = fade.targetColor
  local intensity = fade.intensity
  assert(type(color) == "number" and color % 1 == 0, "palette fade carries RGB555 target color")
  assert(type(intensity) == "number" and intensity % 1 == 0, "palette fade carries integer intensity")
  return {
    (color % 32) / 31,
    (math.floor(color / 32) % 32) / 31,
    (math.floor(color / 1024) % 32) / 31,
  },
    intensity
end

local function rotate(x, y, z, item)
  local ax, ay, az = angle(item.rotationX), angle(item.rotationY), angle(item.rotationZ)
  az = az + (item.rotation or 0)
  local sx, cx = math.sin(ax), math.cos(ax)
  local sy, cy = math.sin(ay), math.cos(ay)
  local sz, cz = math.sin(az), math.cos(az)
  local y1, z1 = cx * y - sx * z, sx * y + cx * z
  local x2, z2 = cy * x + sy * z1, -sy * x + cy * z1
  return cz * x2 - sz * y1, sz * x2 + cz * y1, z2
end

local function vertices(item)
  local imageWidth, imageHeight = item.image:getDimensions()
  local width, height = item.width, item.height
  local xOffset, yOffset = item.xOffset or 0, item.yOffset or 0
  local xOffset2, yOffset2 = 0, 0
  local u0, v0, u1, v1 = 0, 0, 1, 1
  if item.kind == "shadow" then
    local region = assert(item.textureRegion, "shadow submissions select a staged native size region")
    u0, v0 = region.x / imageWidth, region.y / imageHeight
    u1, v1 = (region.x + region.width) / imageWidth, (region.y + region.height) / imageHeight
    if item.shadowAffine then
      width = width * (item.affineWidth or 0x100) / 0x100
      height = height * (item.affineHeight or 0x100) / 0x100
    end
  elseif item.pictureVisible then
    xOffset2, yOffset2 = item.xOffset2 or 0, item.yOffset2 or 0
    assert(
      xOffset2 >= 0
        and yOffset2 >= 0
        and width > 0
        and height > 0
        and xOffset2 + width <= imageWidth
        and yOffset2 + height <= imageHeight,
      "Pokepic crop stays inside its staged selector frame"
    )
    u0, v0 = xOffset2 / imageWidth, yOffset2 / imageHeight
    u1, v1 = (xOffset2 + width) / imageWidth, (yOffset2 + height) / imageHeight
  end
  local left, right = -width / 2, width / 2
  local top, bottom = -height / 2, height / 2
  if item.kind == "shadow" then
    left, right = -width / 2 + (item.shadowOffsetX or 0), width / 2 + (item.shadowOffsetX or 0)
    top, bottom = -height / 2 + (item.shadowOffsetY or 0), height / 2 + (item.shadowOffsetY or 0)
  elseif item.pictureVisible then
    left, right = -40 + xOffset + xOffset2, -40 + xOffset + xOffset2 + width
    top, bottom = -40 + yOffset + yOffset2, -40 + yOffset + yOffset2 + height
  else
    left, right = left + xOffset, right + xOffset
    top, bottom = top + yOffset, bottom + yOffset
  end
  top, bottom = top - (item.shadowHeight or 0), bottom - (item.shadowHeight or 0)
  local centerX, centerY = item.centerX, item.centerY
  local pivotX, pivotY = item.pivotX or 0, item.pivotY or 0
  local baseZ = item.kind == "shadow" and -1000 or item.zCenter + (item.zOffset or 0)
  local result = {}
  for _, point in ipairs({
    { left, top, u0, v0 },
    { right, top, u1, v0 },
    { right, bottom, u1, v1 },
    { left, bottom, u0, v1 },
  }) do
    local x, y, z = rotate(
      point[1] - pivotX,
      point[2] - pivotY,
      0,
      item.kind == "shadow" and { rotation = 0, rotationX = 0, rotationY = 0, rotationZ = 0 } or item
    )
    local screenX, screenY = centerX + pivotX + x, centerY + pivotY + y
    local depth = math.max(0, math.min(1, -((baseZ + z) / DEPTH_RANGE)))
    local clipZ = depth * 2 - 1
    result[#result + 1] = vertex(screenX, screenY, clipZ, point[3], point[4])
  end
  return result
end

function BattlePicturePass.new(graphics)
  assert(type(graphics) == "table", "Pokepic rendering requires host graphics")
  local color = graphics.newCanvas(WIDTH, HEIGHT, { format = "rgba8", readable = true, dpiscale = 1 })
  local depth, mesh, shader
  local ok, failure = pcall(function()
    depth = graphics.newCanvas(WIDTH, HEIGHT, { format = "depth24stencil8", readable = false, dpiscale = 1 })
    mesh = graphics.newMesh(VERTEX_FORMAT, {
      vertex(-40, -40, 0, 0, 0),
      vertex(40, -40, 0, 1, 0),
      vertex(40, 40, 0, 1, 1),
      vertex(-40, 40, 0, 0, 1),
    }, "fan", "dynamic")
    shader = graphics.newShader(SHADER)
  end)
  if not ok then
    if shader then
      shader:release()
    end
    if mesh then
      mesh:release()
    end
    if depth then
      depth:release()
    end
    color:release()
    error(failure, 0)
  end
  color:setFilter("nearest", "nearest")
  return setmetatable(
    { graphics = graphics, color = color, depth = depth, mesh = mesh, shader = shader },
    BattlePicturePass
  )
end

function BattlePicturePass:render(graphics, items)
  local saved = {
    canvas = { graphics.getCanvas() },
    shader = graphics.getShader(),
    blend = { graphics.getBlendMode() },
    depth = { graphics.getDepthMode() },
    color = { graphics.getColor() },
    scissor = { graphics.getScissor() },
    wireframe = graphics.isWireframe(),
    cullMode = graphics.getMeshCullMode(),
  }
  local ok, err = pcall(function()
    graphics.setCanvas({ self.color, depthstencil = self.depth })
    graphics.setScissor()
    graphics.clear(0, 0, 0, 0, false, true)
    graphics.setWireframe(false)
    graphics.setMeshCullMode("none")
    graphics.setShader(self.shader)
    graphics.setBlendMode("alpha", "alphamultiply")
    for _, item in ipairs(items) do
      self.mesh:setVertices(vertices(item))
      self.mesh:setTexture(item.image)
      graphics.setColor(item.tintR, item.tintG, item.tintB, item.alpha)
      local fadeColor, fadeAmount = paletteFade(item.paletteFade)
      self.shader:send("paletteFadeColor", fadeColor)
      self.shader:send("paletteFadeAmount", fadeAmount)
      graphics.setDepthMode("less", item.alpha >= 1)
      graphics.draw(self.mesh)
    end
  end)
  graphics.setCanvas((table.unpack or unpack)(saved.canvas))
  graphics.setShader(saved.shader)
  graphics.setBlendMode((table.unpack or unpack)(saved.blend))
  graphics.setDepthMode((table.unpack or unpack)(saved.depth))
  graphics.setColor((table.unpack or unpack)(saved.color))
  graphics.setScissor((table.unpack or unpack)(saved.scissor))
  graphics.setWireframe(saved.wireframe)
  graphics.setMeshCullMode(saved.cullMode)
  if not ok then
    error(err, 0)
  end
  return self.color
end

function BattlePicturePass:release()
  if self._released then
    return
  end
  self._released = true
  self.mesh:release()
  self.shader:release()
  self.depth:release()
  self.color:release()
end

return BattlePicturePass
