-- Pending boot gate with genuine walker art: the boot wait observes its
-- source gate as pending, adopts the selected SoulSilver pair into the real
-- loading presentation, paints walker pixels, and never transfers.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local CachePreparationState = require("app.src.launcher.CachePreparationState")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
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
  local pairIndex = 5
  local manifest = StartupAssetCache.loadWalker(cacheFs, "soulsilver")
  Assert.notNil(manifest, "the shared walking catalog reads back as a ready bundle")
  local choice = StartupAssetCache.walkerChoice(pairIndex)
  Assert.notNil(choice.heroId, "the fixed pair maps to a catalog hero")
  Assert.notNil(choice.followerSpeciesId, "the fixed pair maps to a catalog follower")
  local script = { bootPolls = 0, walkerDemands = 0, fired = 0 }
  local state = pendingBootWaitWithReadyWalker(pairIndex, script)
  local ok, err = xpcall(function()
    local preSprites = 0
    local originalPreDraw = love.graphics.draw
    local pre
    local preOk, preErr = xpcall(function()
      love.graphics.draw = function(drawable, quad, ...)
        if quad ~= nil then
          preSprites = preSprites + 1
        end
        return originalPreDraw(drawable, quad, ...)
      end
      pre = renderWait(state, scope)
    end, debug.traceback)
    love.graphics.draw = originalPreDraw
    if not preOk then
      error(preErr, 0)
    end
    Assert.equal(script.bootPolls, 0, "the first draw never waits on the boot-source gate")
    Assert.isTrue(preSprites >= 1, "the first frame already paints hero or follower sprite draws")
    -- A zero tick keeps the themed stage identical; the cached pair
    -- stays on screen while the gate is observed without admission.
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
    Assert.isTrue(preBytes == postBytes, "the cached pair stays stable across a zero tick")
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
suite.metadata.derivedAssets = { "startup-loader:global" }
suite.metadata.tags = { "startup" }
return suite
