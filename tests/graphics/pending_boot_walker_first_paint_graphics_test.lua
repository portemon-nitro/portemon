-- Pending boot gate with genuine walker art: the boot wait observes its
-- source gate as pending, adopts the selected SoulSilver pair into the real
-- loading presentation, paints walker pixels, and never transfers.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local CachePreparationState = require("app.src.launcher.CachePreparationState")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local Presentation = require("libs.hgss.src.ui.HgssLoadingPresentation")
local RomImporter = require("romdump.src.source.RomImporter")
local StartupAssetCache = require("libs.assets.src.StartupAssetCache")

local WIDTH, HEIGHT = 480, 360

local T = {}

---@param state CachePreparationState
---@param scope table
---@return love.ImageData
local function renderWait(state, scope)
  local canvas = scope:own(love.graphics.newCanvas(WIDTH, HEIGHT))
  love.graphics.push("all")
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  state:draw()
  love.graphics.setCanvas()
  love.graphics.pop()
  return scope:own(canvas:newImageData())
end

---@param pairIndex integer
---@param script table
---@return CachePreparationState
local function pendingBootWaitWithReadyWalker(pairIndex, script)
  local service = {}
  function service:bootSourceStatus(_)
    script.bootPolls = script.bootPolls + 1
    return "pending"
  end
  function service:request(_, selector)
    if type(selector) == "table" and selector.requestKind == "startup-walker" then
      script.walkerDemands = script.walkerDemands + 1
    end
    return "walker-request"
  end
  function service:observe(_, selector)
    if type(selector) == "table" and selector.requestKind == "startup-walker" then
      return true, nil
    end
    return false, nil
  end
  return CachePreparationState.new({
    kind = "boot-source",
    epoch = 7,
    service = service,
    versionId = "soulsilver",
    pairIndex = pairIndex,
    isCurrent = function()
      return true
    end,
    onReady = function()
      script.fired = script.fired + 1
    end,
    onCancel = function()
      script.cancelled = (script.cancelled or 0) + 1
    end,
  })
end

local function pending_gate_paints_adopted_walker_pixels_without_transfer(scope, context)
  if not RomImporter.isReady("soulsilver") then
    context:skip("no user-owned SoulSilver dump is ready")
  end
  local cacheFs = CacheFs.forVersion("soulsilver")
  local pairIndex = Presentation.publishedPair(cacheFs)
  Assert.notNil(pairIndex, "the prepared test cache publishes a selectable walking pair")
  ---@cast pairIndex integer
  local manifest = StartupAssetCache.loadWalker(cacheFs, pairIndex)
  Assert.notNil(manifest, "the selected pair reads back as a ready bundle")
  local script = { bootPolls = 0, walkerDemands = 0, fired = 0 }
  local state = pendingBootWaitWithReadyWalker(pairIndex, script)
  local ok, err = xpcall(function()
    local pre = renderWait(state, scope)
    Assert.equal(script.bootPolls, 0, "the first draw never waits on the boot-source gate")
    -- A zero tick keeps the themed stage identical so only adopted walker
    -- pixels can differ between the two frames.
    state:update(0)
    Assert.isTrue(script.bootPolls >= 1, "the pending wait observes the gate without admission")
    Assert.isTrue(script.walkerDemands >= 1, "the pending wait demands the selected pair while verifying")
    Assert.equal(script.fired, 0, "visible sprites never transfer before the gate admits")
    local spriteDraws = 0
    local originalDraw = love.graphics.draw
    local post
    local drawOk, drawErr = xpcall(function()
      -- The themed stage paints rectangles and the caption prints text:
      -- only the adopted hero and follower paint through image draws
      -- with a source quad.
      love.graphics.draw = function(drawable, quad, ...)
        if quad ~= nil then
          spriteDraws = spriteDraws + 1
        end
        return originalDraw(drawable, quad, ...)
      end
      post = renderWait(state, scope)
    end, debug.traceback)
    love.graphics.draw = originalDraw
    if not drawOk then
      error(drawErr, 0)
    end
    Assert.isTrue(spriteDraws >= 1, "the pending wait paints hero or follower sprite draws")
    local preBytes = pre:getString()
    local postBytes = assert(post, "the pending wait renders its adopted frame"):getString()
    Assert.equal(#preBytes, #postBytes, "compared frames share their dimensions")
    local changedBytes = 0
    local firstPixel = nil
    for index = 1, #preBytes do
      if preBytes:byte(index) ~= postBytes:byte(index) then
        changedBytes = changedBytes + 1
        if firstPixel == nil then
          firstPixel = math.floor((index - 1) / 4)
        end
      end
    end
    Assert.isTrue(changedBytes > 0, "the adopted pair changes real frame pixels while the gate is pending")
    local alpha = postBytes:byte(assert(firstPixel, "a changed pixel was counted") * 4 + 4)
    Assert.isTrue(alpha ~= nil and alpha ~= 0, "the first changed walker pixel is nontransparent")
    Assert.equal(script.fired, 0, "a pending gate never transfers even with walker pixels on screen")
    Assert.throws(function()
      state:takeLoading()
    end, "nothing detaches before admission even when sprites are visible")
  end, debug.traceback)
  state:dispose()
  if not ok then
    error(err, 0)
  end
end

local suite = GraphicsSmoke.suite({
  ["pending gate paints adopted walker pixels without transfer"] = pending_gate_paints_adopted_walker_pixels_without_transfer,
})
suite.metadata.capabilities = { "graphics", "rom_dump" }
suite.metadata.derivedAssets = { "startup-loader:5" }
suite.metadata.tags = { "startup" }
return suite
