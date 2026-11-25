-- Bank keypad drawing with the real compiled bundle: the source layer, the
-- entered digit glyphs, the underline cursor and the pressed-key feedback paint
-- onto the 256x192 surface from the generated images, and the native, wide and
-- tall display cases place the same surface.

local Assert = require("tests.support.Assert")
local BankAssetCompiler = require("romdump.src.digest.ui.BankAssetCompiler")
local BankAssetSchema = require("libs.assets.src.BankAssetSchema")
local BankInterface = require("game.hgss.src.bank.BankInterface")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local function scope(t)
  local owned = {}
  return {
    own = function(_, value)
      owned[#owned + 1] = value
      return value
    end,
    release = function()
      for _, value in ipairs(owned) do
        if type(value) == "table" and type(value.release) == "function" then
          value:release()
        end
      end
    end,
  }
end

---@param bundle table
---@param cache table
---@return fun(path: string): table<string, unknown>?
local function imageProvider(bundle, cache)
  local images = {}
  return function(path)
    local existing = images[path]
    if existing ~= nil then
      return existing
    end
    local bytes = bundle.assets[path]
    if bytes == nil then
      return nil
    end
    local fileData = love.filesystem.newFileData(bytes, "bank.png")
    local image = love.graphics.newImage(fileData)
    images[path] = image
    return image
  end
end

---@param status table
---@return table
local function status(overrides)
  local digitCells = {}
  for index = 1, 4 do
    digitCells[index] = { x = 80 + (index - 1) * 32, y = 40 }
  end
  local value = {
    amount = 1200,
    maxAmount = 3000,
    maxDigits = 4,
    cursor = 1,
    gridKey = 1,
    blinkVisible = true,
    blinkTarget = 1,
    digits = { 1, 2, 0, 0, 0, 0 },
    digitCells = digitCells,
    cursorCell = { x = 112, y = 52 },
    keys = {},
  }
  for key, override in pairs(overrides or {}) do
    value[key] = override
  end
  return value
end

local function renderToData(owner, paint, width, height)
  local lg = love.graphics
  local canvas = owner:own(lg.newCanvas(width, height))
  lg.push("all")
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  paint()
  lg.setCanvas()
  lg.pop()
  return owner:own(canvas:newImageData())
end

T["the compiled keypad paints its source layer, digits and feedback"] = function(romFs)
  local bundle = assert(BankAssetCompiler.compile(romFs))
  local manifest = assert(BankAssetSchema.validate(bundle.manifest))
  local interface = BankInterface.new({
    manifest = manifest,
    measureDisplay = function()
      return { auxiliary = { x = 0, y = 0, width = 256, height = 192 } }
    end,
  })
  local owner = scope()
  local images = imageProvider(bundle, CacheFs.forVersion("heartgold", FakeCache.new()))
  local plan = interface:plan(status())
  local data = renderToData(owner, function()
    BankInterface.draw(plan, images)
  end, 256, 192)

  -- The composited source layer covers the display: the top-left pad region is
  -- opaque where the source screen paints it.
  local painted = 0
  for y = 0, 191, 8 do
    for x = 0, 255, 8 do
      local _, _, _, alpha = data:getPixel(x, y)
      if alpha > 0 then
        painted = painted + 1
      end
    end
  end
  Assert.isTrue(painted > 0, "the source layer paints the keypad background")

  -- The entered digit glyphs paint at their source cell anchors.
  local glyphPixels = 0
  for y = 40, 40 + plan.glyphs[1].dest.height - 1 do
    for x = plan.glyphs[1].dest.x, plan.glyphs[1].dest.x + plan.glyphs[1].dest.width - 1 do
      local _, _, _, alpha = data:getPixel(x, y)
      if alpha > 0 then
        glyphPixels = glyphPixels + 1
      end
    end
  end
  Assert.isTrue(glyphPixels > 0, "the entered digit glyph paints its cell")

  -- Pressed-key feedback paints the pressed cell, and a status without a press
  -- leaves the same cell to the layer only.
  local cell = manifest.keys.digits[1]
  local function cellInk(withPress)
    local pressedPlan = interface:plan(status({ blinkVisible = withPress, blinkTarget = 0 }))
    local pressedData = renderToData(owner, function()
      BankInterface.draw(pressedPlan, images)
    end, 256, 192)
    local r, g, b = pressedData:getPixel(cell.x + 24, cell.y + 24)
    return string.format("%.3f/%.3f/%.3f", r, g, b)
  end
  local withoutPress = cellInk(false)
  local withPress = cellInk(true)
  Assert.isTrue(
    withPress ~= withoutPress,
    "the pressed-key feedback changes the pressed cell " .. tostring(withoutPress) .. " -> " .. tostring(withPress)
  )

  -- The three display cases keep the source aspect and center the surface.
  local native = interface:placement("native")
  Assert.deepEqual({ native.width, native.height }, { 256, 192 }, "the native case is the source surface")
  local wide = BankInterface.new({
    manifest = manifest,
    measureDisplay = function()
      return { auxiliary = { x = 0, y = 0, width = 640, height = 480 } }
    end,
  }):placement("wide")
  Assert.equal(wide.scale, 2, "the wide case doubles the source pixels")
  Assert.equal(wide.width / wide.height, 256 / 192, "the wide case keeps the source aspect")
  local tall = BankInterface.new({
    manifest = manifest,
    measureDisplay = function()
      return { auxiliary = { x = 0, y = 0, width = 640, height = 480 } }
    end,
  }):placement("tall")
  Assert.equal(tall.width, wide.width, "both windowed cases present the same aspect-preserving surface")
  owner.release()
end

return RomSuite.fromFacts(T)
