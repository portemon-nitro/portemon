-- The incoming-call notice over the live field: the Pokegear icon plays the
-- compiled ringing frames on the field's source tick and the source caller
-- bubble carries the caller name. The renderer owns the compiled art slots,
-- never ring policy; the caller window width is the source font formula
-- capped at the compiled maximum.

local Assert = require("tests.support.Assert")
local FieldCallNoticeRenderer = require("game.hgss.src.field.FieldCallNoticeRenderer")
local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local StubLease = require("tests.support.StubLease")

local T = {}

local fakeGraphics = require("tests.support.FakeGraphics").new

local REFERENCE_FRAME = { x = 0, y = 0, width = 256, height = 192 }

-- The caller name text double: the field font advance is ten pixels per
-- capital, and the draw records the exact palette roles the window prints.
---@return table
local function callerText()
  local text = { calls = {} }
  function text:textWidth(name)
    return #name * 10
  end
  function text:drawTextWithPalette(name, x, y, palette)
    self.calls[#self.calls + 1] = { name = name, x = x, y = y, palette = palette }
  end
  return text
end

---@return table manifest
local function callManifest()
  local value = FieldUiFixture.addStartMenuIconContract(FieldUiFixture.manifest())
  return FieldUiFixture.addStartMenuPhoneNotification(value)
end

---@param value table
---@return CacheFs
local function callCache(value)
  local result = FieldUiFixture.startMenuCache()
  result:writeLua("data/generated/field/ui/ui.lua", value)
  FieldUiFixture.writeStartMenuPhoneNotificationPngs(result)
  return result
end

-- One renderer over the fixture class: the ringing atlas then the caller
-- bubble atlas are the only images it materializes.
---@param lg table
---@param text table?
---@return FieldCallNoticeRenderer
local function renderer(lg, text)
  local value = callManifest()
  return FieldCallNoticeRenderer.new({
    cacheFs = callCache(value),
    manifest = value,
    text = text or callerText(),
    graphics = lg,
  })
end

-- Draws at a fake 1:1 reference frame and returns the notice's draw records.
---@param subject FieldCallNoticeRenderer
---@param lg table
---@param name string
---@param tick integer
---@return table[]
local function draw(subject, lg, name, tick)
  local before = #lg.draws
  subject:draw({ name = name }, tick, REFERENCE_FRAME)
  local records = {}
  for index = before + 1, #lg.draws do
    records[#records + 1] = lg.draws[index]
  end
  return records
end

-- The bubble slice draws only: the ringing atlas draws sample the 40x32
-- caller bubble atlas, which distinguishes them from the ringing frames.
---@param lg table
---@return table[]
local function bubbleDraws(lg)
  local draws = {}
  for _, record in ipairs(lg.draws) do
    if record.quad ~= nil and record.quad.imgW == 40 then
      draws[#draws + 1] = record
    end
  end
  return draws
end

function T.the_ringing_icon_plays_the_compiled_frames_on_the_source_tick()
  local lg = fakeGraphics({ imageSizes = { { 120, 32 }, { 40, 32 } } })
  local subject = renderer(lg)

  local first = draw(subject, lg, "MOM", 0)[1]
  Assert.equal(first.quad.x, 0, "the ring opens on the first compiled frame")
  Assert.equal(first.x, 24, "the ringing icon sits on the Pokegear source anchor")
  Assert.equal(first.y, 142, "the first frame keeps its compiled offset")

  local second = draw(subject, lg, "MOM", 2)[1]
  Assert.equal(second.quad.x, 40, "the second tick span advances to the second frame")
  Assert.equal(second.y, 136, "the second frame carries its compiled upward offset")

  local third = draw(subject, lg, "MOM", 4)[1]
  Assert.equal(third.quad.x, 80, "the third tick span advances to the third frame")
  Assert.equal(third.y, 142, "the third frame returns to the anchor")

  local looped = draw(subject, lg, "MOM", 7)[1]
  Assert.equal(looped.quad.x, 0, "the animation loops from the compiled loop point")
  subject:release()
end

function T.the_caller_bubble_wraps_the_name_in_the_source_nine_slice()
  local lg = fakeGraphics({ imageSizes = { { 120, 32 }, { 40, 32 } } })
  local text = callerText()
  local subject = renderer(lg, text)
  -- Five tiles wide: the name advances thirty pixels, so the source width
  -- formula floors it to three tiles and adds the window's two columns.
  Assert.equal(subject:windowWidth("MOM"), 5, "the caller window follows the source width formula")
  Assert.equal(subject:windowWidth("MAXIMILLIAN-CHRISTOPHER"), 9, "the caller window caps at its compiled width")

  draw(subject, lg, "MOM", 0)
  local bubble = bubbleDraws(lg)
  -- The left cap, one right cap, and the top and bottom edges per column.
  Assert.equal(#bubble, 2 + 5 * 2, "the bubble paints its cap, edges, and right cap")
  Assert.deepEqual(
    { bubble[1].quad.x, bubble[1].x, bubble[1].y },
    { 0, 64, 144 },
    "the left cap starts three tiles before the window"
  )
  Assert.deepEqual({ bubble[2].quad.x, bubble[2].x, bubble[2].y }, { 24, 128, 144 }, "the right cap closes the body")
  local tops, bottoms = {}, {}
  for index = 3, #bubble do
    local record = bubble[index]
    local list = record.quad.y == 0 and tops or bottoms
    list[#list + 1] = record
  end
  Assert.equal(#tops, 5, "one top edge per window column")
  Assert.equal(#bottoms, 5, "one bottom edge per window column")
  Assert.deepEqual({ tops[1].x, tops[1].y }, { 88, 144 }, "the top edge starts at the window's left column")
  Assert.deepEqual({ tops[5].x, tops[5].y }, { 120, 144 }, "the top edge repeats across the window width")
  Assert.deepEqual({ bottoms[1].x, bottoms[1].y }, { 88, 168 }, "the bottom edge sits below the two-tile window")

  local plate = lg.rectangles[#lg.rectangles]
  Assert.deepEqual({ plate.x, plate.y, plate.w, plate.h }, { 88, 152, 40, 16 }, "the plate fills the window")
  Assert.deepEqual(plate.color, { 25 / 255, 132 / 255, 66 / 255, 1 }, "the plate uses its compiled source color")

  local expected = callManifest().startMenu.phoneNotification.bubble
  local call = assert(text.calls[1], "the caller name prints on the plate")
  Assert.deepEqual({ call.name, call.x, call.y }, { "MOM", 91, 152 }, "the name prints three pixels into the window")
  Assert.deepEqual(call.palette.foreground, expected.name.foreground, "the name uses its compiled ink")
  Assert.deepEqual(call.palette.shadow, expected.name.shadow, "the name uses its compiled shadow")
  Assert.equal(call.palette.background.a, 0, "the name background leaves the plate visible")
  local clip = lg.scissorIntersections[#lg.scissorIntersections]
  Assert.deepEqual(clip.requested, { 88, 152, 40, 16 }, "the name clips to the window like the source glyph copier")

  -- A single-glyph name stays at the source minimum width: the window, the
  -- plate, and the right cap all shrink together.
  local drawnBefore = #lg.draws
  draw(subject, lg, "A", 0)
  local rightCap = nil
  for index = drawnBefore + 1, #lg.draws do
    local record = lg.draws[index]
    if record.quad ~= nil and record.quad.imgW == 40 and record.quad.x == 24 then
      rightCap = record
    end
  end
  rightCap = assert(rightCap, "the short window closes with its right cap") --[[@as table]]
  Assert.equal(rightCap.x, 112, "the right cap closes the short window")
  local shortPlate = lg.rectangles[#lg.rectangles]
  Assert.deepEqual({ shortPlate.x, shortPlate.w }, { 88, 24 }, "a short name narrows the window to the source minimum")
  subject:release()
end

function T.construction_requires_the_compiled_call_projection()
  local lg = fakeGraphics({ imageSizes = { { 120, 32 }, { 40, 32 } } })
  local value = FieldUiFixture.addStartMenuIconContract(FieldUiFixture.manifest())
  local ok = pcall(function()
    FieldCallNoticeRenderer.new({ cacheFs = callCache(value), manifest = value, text = callerText(), graphics = lg })
  end)
  Assert.isFalse(ok, "a class without the incoming-call projection must fail loudly")
end

-- The field composes the notice over the shared image owner, so the
-- production notice borrows both compiled atlases through the pool's request
-- protocol, draws through the returned leases, and gives every lease back
-- exactly once. The eager cacheFs path stands in for hosts that own their
-- images directly.
function T.the_composed_notice_borrows_its_atlases_from_the_shared_image_owner()
  local lg = fakeGraphics({ imageSizes = { { 120, 32 }, { 40, 32 } } })
  local value = callManifest()
  local requests, leases, returned = {}, {}, {}
  local pool = {
    request = function(_, path, sampler, purpose)
      local token = #requests + 1
      requests[token] = { path = path, sampler = sampler, purpose = purpose }
      leases[token] = StubLease.over(lg.newImage())
      return token
    end,
    poll = function()
      return "ready"
    end,
    acquire = function(_, token)
      return assert(leases[token], "the pool hands back the lease it staged")
    end,
    release = function(_, lease)
      returned[#returned + 1] = lease
    end,
  }
  local subject = FieldCallNoticeRenderer.new({
    cacheFs = callCache(value),
    manifest = value,
    text = callerText(),
    graphics = lg,
    imagePool = pool,
  })
  draw(subject, lg, "MOM", 0)
  Assert.equal(#requests, 2, "the notice borrows exactly its two compiled atlases")
  for index, request in ipairs(requests) do
    Assert.equal(request.purpose, "demand", "borrow " .. index .. " is a demand request")
    Assert.deepEqual(request.sampler, {
      wrapX = "clamp",
      wrapY = "clamp",
      minFilter = "nearest",
      magFilter = "nearest",
    }, "borrow " .. index .. " samples like the pooled art beside it")
  end
  Assert.deepEqual({ requests[1].path, requests[2].path }, {
    assert(value.assets.hgss_start_menu_ringing or value.assets["hgss.start_menu.ringing"]).image,
    assert(value.assets["hgss.start_menu.caller_bubble"]).image,
  }, "the notice borrows the compiled ringing and caller bubble atlases")
  local drawnImages = {}
  for _, record in ipairs(lg.draws) do
    drawnImages[record.image] = true
  end
  for token, lease in ipairs(leases) do
    Assert.isTrue(drawnImages[lease.image] == true, "atlas " .. token .. " draws through its borrowed lease")
  end
  subject:release()
  Assert.equal(#returned, 2, "release returns both borrowed leases")
  for token, lease in ipairs(leases) do
    Assert.equal(returned[token], lease, "release returns lease " .. token .. " itself, never a copy")
  end
end

function T.release_returns_every_acquired_atlas()
  local lg = fakeGraphics({ imageSizes = { { 120, 32 }, { 40, 32 } } })
  local subject = renderer(lg)
  draw(subject, lg, "MOM", 0)
  Assert.equal(#lg.images, 2, "the notice owns exactly its two compiled atlases")
  subject:release()
  for index, image in ipairs(lg.images) do
    Assert.equal(image.releaseCount, 1, "atlas " .. index .. " is released exactly once")
  end
end

return { tests = T }
