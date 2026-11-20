-- A ringing caller presents source art over the live field instead of a card
-- or an invented plate: the touchscreen menu's Pokegear icon playing its
-- compiled ringing animation plus the compiled caller bubble carrying the
-- caller name, with the field's own pixels left visible around it. The
-- fixture notice art carries one solid color per ringing frame and per bubble
-- slice, so the capture proves exactly which compiled piece painted where
-- through the real generated PNGs and the real field text renderer; the
-- animation frames, draw order, and slice geometry live in the cheap renderer
-- units.

local Assert = require("tests.support.Assert")
local FieldCallNoticeRenderer = require("game.hgss.src.field.FieldCallNoticeRenderer")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local StubLease = require("tests.support.StubLease")

local T = {}

local SURFACE_WIDTH = 256
local SURFACE_HEIGHT = 192
local REFERENCE_FRAME = { x = 0, y = 0, width = SURFACE_WIDTH, height = SURFACE_HEIGHT }

-- The fixture notice art: one solid color per ringing frame and per bubble
-- slice, so the capture proves exactly which compiled piece painted where.
local FIRST_FRAME = { 220, 40, 40 }
local PLATE = { 25, 132, 66 }

-- The field's own pixels stand in as the host surface: one flat color, so any
-- painted pixel shows up as a change.
local FIELD_R, FIELD_G, FIELD_B = 0.2, 0.6, 0.3

---@param data table
---@param color integer[]
---@param x integer
---@param y integer
---@param what string
local function assertColor(data, color, x, y, what)
  local red, green, blue, alpha = data:getPixel(x, y)
  Assert.isTrue(
    alpha > 0.5
      and math.abs(red - color[1] / 255) < 0.02
      and math.abs(green - color[2] / 255) < 0.02
      and math.abs(blue - color[3] / 255) < 0.02,
    what .. " paints its compiled color"
  )
end

-- Pixels inside one rectangle that still carry the flat field color: the
-- notice claims only its own source rectangles, so everything else must keep
-- the host surface it was drawn over.
---@param data table
---@param rect table
---@return integer kept
local function fieldPixelsKept(data, rect)
  local kept = 0
  for y = rect.y, rect.y + rect.height - 1 do
    for x = rect.x, rect.x + rect.width - 1 do
      local red, green, blue, alpha = data:getPixel(x, y)
      if
        alpha > 0
        and math.abs(red - FIELD_R) < 0.01
        and math.abs(green - FIELD_G) < 0.01
        and math.abs(blue - FIELD_B) < 0.01
      then
        kept = kept + 1
      end
    end
  end
  return kept
end

-- Renders one draw over a flat field-colored surface and returns the
-- captured pixels.
---@param scope table
---@param draw fun()
---@return table imageData
local function renderFieldSurface(scope, draw)
  local canvas = scope:own(love.graphics.newCanvas(SURFACE_WIDTH, SURFACE_HEIGHT))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(FIELD_R, FIELD_G, FIELD_B, 1)
  love.graphics.setColor(1, 1, 1, 1)
  draw()
  love.graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

-- The shared image owner the field presentation hands the notice: every
-- request realizes the compiled PNG from the fixture cache on the main
-- thread, so the notice draws through the same pooled lease surface
-- production borrows, over the real compiled pixels.
---@param scope table
---@param cacheFs CacheFs
---@return table pool
local function imagePool(scope, cacheFs)
  local pool = { leases = {} }
  function pool:request(path)
    local data = assert(cacheFs:read(path), "the fixture cache carries " .. path)
    local image = scope:own(love.graphics.newImage(scope:own(love.filesystem.newFileData(data, path))))
    self.leases[#self.leases + 1] = StubLease.over(image)
    return #self.leases
  end
  function pool:poll()
    return "ready"
  end
  function pool:acquire(token)
    return assert(self.leases[token], "the pool hands back the lease it staged")
  end
  function pool:release() end
  return pool
end

-- The caller notice cache: the dialogue font, the source-shaped field-UI
-- manifest carrying the incoming-call projection, and the fixture notice art.
---@return CacheFs
---@return table manifest
local function noticeCache()
  local cache = FieldUiFixture.cacheWithFontAndFrames()
  local manifest = FieldUiFixture.addStartMenuIconContract(FieldUiFixture.manifest())
  FieldUiFixture.addStartMenuPhoneNotification(manifest)
  cache:writeLua("data/generated/field/ui/ui.lua", manifest)
  FieldUiFixture.writeStartMenuPhoneNotificationPngs(cache)
  return cache, manifest
end

-- The ringing notice over the live field: the Pokegear icon plays its opening
-- compiled frame at the source anchor, the caller bubble paints its compiled
-- plate under the name the real font prints, and the field keeps every pixel
-- outside the notice.
function T.the_ringing_notice_paints_the_compiled_icon_and_caller_bubble(scope)
  local cache, manifest = noticeCache()
  local text = scope:own(FieldTextRenderer.new({ cacheFs = cache, fontId = 0 }))
  local notice = assert(manifest.startMenu.phoneNotification, "the fixture class carries the call projection")
  local renderer = scope:own(FieldCallNoticeRenderer.new({
    manifest = manifest,
    text = text,
    graphics = love.graphics,
    imagePool = imagePool(scope, cache),
  }))
  local window = assert(notice.window)
  local bodyWidth = renderer:windowWidth("MOM") * 8
  local originY = (window.top - 1) * 8
  local bodyX = window.tileLeft * 8
  local plateBand = { x = bodyX + 1, y = originY + 9, width = bodyWidth - 2, height = 14 }

  local painted = renderFieldSurface(scope, function()
    renderer:draw({ name = "MOM" }, 0, REFERENCE_FRAME)
  end)

  assertColor(painted, FIRST_FRAME, 24 + 20, 142 + 16, "the opening ringing frame")
  assertColor(painted, PLATE, bodyX + 2, originY + 12, "the caller bubble plate")
  -- The real font prints over the plate: the name covers some of the window
  -- fill the plate just painted.
  local platePixels = 0
  for y = plateBand.y, plateBand.y + plateBand.height - 1 do
    for x = plateBand.x, plateBand.x + plateBand.width - 1 do
      local red, green, blue, alpha = painted:getPixel(x, y)
      if
        alpha > 0.5
        and math.abs(red - PLATE[1] / 255) < 0.02
        and math.abs(green - PLATE[2] / 255) < 0.02
        and math.abs(blue - PLATE[3] / 255) < 0.02
      then
        platePixels = platePixels + 1
      end
    end
  end
  Assert.isTrue(
    platePixels < plateBand.width * plateBand.height,
    "the caller name prints over the plate"
  )
  Assert.isTrue(
    fieldPixelsKept(painted, { x = 0, y = 0, width = SURFACE_WIDTH, height = originY - 8 }) > 0,
    "field pixels above the notice keep their own color"
  )
  Assert.isTrue(
    fieldPixelsKept(painted, { x = 0, y = originY + 33, width = SURFACE_WIDTH, height = SURFACE_HEIGHT - originY - 33 })
      > 0,
    "field pixels below the notice keep their own color"
  )
end

return GraphicsSmoke.suite(T, { tags = { "pokegear", "field" } })
