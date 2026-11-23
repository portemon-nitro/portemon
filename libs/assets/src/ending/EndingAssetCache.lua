-- Published League ending bundle: the registration, showcase and credit-roll
-- sections one generated artifact owns, with the source background images the
-- roll draws. The schema is closed: every section, timing table and image
-- reference is validated before the bundle is admitted, and a bundle missing a
-- required part is never treated as ready.
--
-- Pure asset contract module: paths and validation only, no love dependency.

local Contract = require("libs.assets.src.DerivedAssetContract")
local AssetErrors = require("libs.assets.src.errors")
local Errors = require("libs.errors.src.Errors")

---@class EndingAssetCache
local EndingAssetCache = {}

local DIR = "data/generated/ending"
local INDEX = DIR .. "/index.lua"
local MARKER = DIR .. "/marker"

EndingAssetCache.DIR = DIR
EndingAssetCache.FORMAT = Contract.ending.format
EndingAssetCache.SCHEMA = Contract.ending.indexSchema

---@param message string
---@param context table<string, unknown>
local function fail(message, context)
  Errors.raise(AssetErrors.ENDING_ASSET_INVALID, message, context)
end

---@param value unknown
---@return boolean
local function isInteger(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge and value % 1 == 0
end

---@return string
function EndingAssetCache.indexPath()
  return INDEX
end

---@return string
function EndingAssetCache.markerPath()
  return MARKER
end

-- One rasterized source image inside the bundle's own asset root.
---@param sha1 string
---@return string
function EndingAssetCache.imagePath(sha1)
  assert(type(sha1) == "string" and sha1:match("^%x+$") ~= nil, "an ending image is addressed by its content digest")
  return DIR .. "/images/" .. sha1 .. ".png"
end

---@param romSha1 string
---@param depHash string
---@return string
function EndingAssetCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", Contract.ending.format, romSha1, depHash)
end

---@param value unknown
---@param what string
---@return table<string, unknown>
local function checkRecord(value, what)
  if type(value) ~= "table" then
    fail("the League ending bundle " .. what .. " must be a record", { field = what })
  end
  return value --[[@as table<string, unknown>]]
end

---@param value unknown
---@param what string
---@return integer
local function checkInteger(value, what, min)
  if not isInteger(value) or value < (min or 0) then
    fail("the League ending bundle " .. what .. " must be an integer", { field = what, value = value })
  end
  return value --[[@as integer]]
end

---@param value unknown
---@param what string
---@return table<string, unknown>
local function checkImage(value, what)
  local image = checkRecord(value, what)
  if type(image.path) ~= "string" or image.path == "" or type(image.sha1) ~= "string" or image.sha1 == "" then
    fail("the League ending bundle " .. what .. " must name its published image", { field = what })
  end
  if image.path ~= EndingAssetCache.imagePath(image.sha1) then
    fail("the League ending bundle " .. what .. " names its own content-addressed image", { field = what })
  end
  return image
end

-- One background scene: its transition frame and its two source layers.
---@param value unknown
---@param index integer
---@return table<string, unknown>
local function checkScene(value, index)
  local scene = checkRecord(value, "credit scene " .. index)
  if scene.index ~= index - 1 then
    fail("the League ending bundle orders its credit scenes by source scene", { index = index })
  end
  checkImage(scene.lower, "credit scene lower layer")
  checkImage(scene.upper, "credit scene upper layer")
  return scene
end

-- One roll page: its own start time, duration and printed lines.
---@param value unknown
---@param index integer
---@return table<string, unknown>
local function checkPage(value, index)
  local page = checkRecord(value, "credit page " .. index)
  if page.page ~= index - 1 then
    fail("the League ending bundle orders its credit pages by source page", { index = index })
  end
  checkInteger(page.startTime, "credit page start time", 0)
  checkInteger(page.duration, "credit page duration", 0)
  if type(page.lines) ~= "table" then
    fail("the League ending bundle credit page carries its lines", { index = index })
  end
  for lineIndex, line in ipairs(page.lines) do
    checkRecord(line, "credit line " .. index .. ":" .. lineIndex)
    checkInteger(line.x, "credit line x", 0)
    checkInteger(line.y, "credit line y", 0)
    checkInteger(line.message, "credit line message", 0)
  end
  return page
end

---@param section unknown
---@return table<string, unknown>
local function checkCredits(section)
  local credits = checkRecord(section, "credits section")
  checkInteger(credits.frames, "credit frames", 1)
  checkInteger(credits.musicBoxWaitFrames, "credit music-box wait", 1)
  checkInteger(credits.messageBank, "credit message bank", 1)
  local titles = checkRecord(credits.titleMessages, "credit title messages")
  checkInteger(titles.heartgold, "HeartGold title message", 0)
  checkInteger(titles.soulsilver, "SoulSilver title message", 0)
  if type(credits.sceneTransitionTimings) ~= "table" or #credits.sceneTransitionTimings < #credits.scenes - 1 then
    fail("the League ending bundle carries one scene transition per scene change", {})
  end
  for index, timing in ipairs(credits.sceneTransitionTimings) do
    if not isInteger(timing) or timing < 0 then
      fail("a credit scene transition timing is invalid", { index = index })
    end
  end
  if type(credits.scenes) ~= "table" or #credits.scenes == 0 then
    fail("the League ending bundle carries its credit scenes", {})
  end
  for index, scene in ipairs(credits.scenes) do
    checkScene(scene, index)
  end
  if type(credits.pages) ~= "table" or #credits.pages == 0 then
    fail("the League ending bundle carries its credit pages", {})
  end
  for index, page in ipairs(credits.pages) do
    checkPage(page, index)
  end
  checkImage(credits.theEnd, "The End screen")
  return credits
end

---@param section unknown
---@return table<string, unknown>
local function checkRegistration(section)
  local registration = checkRecord(section, "registration section")
  checkInteger(registration.messageBank, "registration message bank", 1)
  checkInteger(registration.memberFrames, "registration member frames", 0)
  return registration
end

---@param section unknown
---@return table<string, unknown>
local function checkShowcase(section)
  local showcase = checkRecord(section, "showcase section")
  checkInteger(showcase.messageBank, "showcase message bank", 1)
  return showcase
end

---@param cacheFs table<string, unknown>
---@param expectedMarker string|nil
---@return boolean ready
function EndingAssetCache.isReady(cacheFs, expectedMarker)
  if expectedMarker ~= nil and cacheFs:read(MARKER) ~= expectedMarker then
    return false
  end
  local loaded, index = pcall(cacheFs.loadLua, cacheFs, INDEX)
  if not loaded or type(index) ~= "table" or index.schema ~= EndingAssetCache.SCHEMA then
    return false
  end
  local sections = index.sections
  if type(sections) ~= "table" then
    return false
  end
  for _, name in ipairs({ "registration", "showcase", "credits" }) do
    local path = sections[name]
    if type(path) ~= "string" or path ~= DIR .. "/" .. name .. ".lua" then
      return false
    end
    local sectionLoaded, section = pcall(cacheFs.loadLua, cacheFs, path)
    if not sectionLoaded or type(section) ~= "table" then
      return false
    end
    local valid = pcall(function()
      if name == "credits" then
        checkCredits(section)
      elseif name == "registration" then
        checkRegistration(section)
      else
        checkShowcase(section)
      end
    end)
    if not valid then
      return false
    end
  end
  -- Every published image the roll draws must be present in the bundle.
  local loadedCredits = cacheFs:loadLua(sections.credits)
  local function requireImage(image)
    if not cacheFs:exists(image.path) then
      fail("the League ending bundle is missing a published image", { path = image.path })
    end
  end
  for _, scene in ipairs(loadedCredits.scenes) do
    requireImage(scene.lower)
    requireImage(scene.upper)
  end
  requireImage(loadedCredits.theEnd)
  return true
end

-- The complete published bundle, for a composition that draws the ending.
---@param cacheFs table<string, unknown>
---@return table<string, unknown> bundle
function EndingAssetCache.load(cacheFs)
  local index, indexErr = cacheFs:loadLua(INDEX)
  if index == nil then
    Errors.raise(AssetErrors.ENDING_ASSET_INVALID, "the League ending bundle is unavailable", {
      path = INDEX,
      cause = tostring(indexErr),
    })
  end
  assert(index ~= nil, "the ending index is available after the missing-bundle error")
  if index.schema ~= EndingAssetCache.SCHEMA then
    fail("the League ending bundle schema is unsupported", { schema = index.schema })
  end
  local function section(name)
    local value, loadErr = cacheFs:loadLua(assert(index.sections[name], "the bundle carries " .. name))
    if value == nil then
      fail("the League ending bundle section failed to load", { section = name, cause = tostring(loadErr) })
    end
    return assert(value)
  end
  return {
    signature = assert(index.marker, "the bundle names its source signature"),
    registration = checkRegistration(section("registration")),
    showcase = checkShowcase(section("showcase")),
    credits = checkCredits(section("credits")),
  }
end

return EndingAssetCache
