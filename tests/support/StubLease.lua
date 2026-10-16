-- Lease-shaped drawable stubs for renderer tests: the production pool-lease
-- lease draw surface over a stub image, so draws record through
-- FakeGraphics (or real graphics) exactly like pooled leases while
-- string-identity assertions on the stub image hold. Straight RGBA
-- keeps raw-draw pixel identity through the sampler by construction.

local ImageAssetPool = require("libs.hgss.src.presentation.ImageAssetPool")

local StubLease = {}

-- One shared no-op filter so stub images stay value-comparable across
-- draws: tests assert draw-record identity by value, and distinct
-- closures would never compare equal.
local function noopFilter() end

-- One drawable stub carrying its artwork identity on a filterable stub
-- image. Draws record the stub image through the shared exact sampler.
---@param key string artwork identity carried on the stub image
---@return table<string, unknown> pool-lease-shaped drawable stub
function StubLease.new(key)
  local lease = setmetatable({
    image = { handle = key, setFilter = noopFilter },
    kind = "rgba8",
  }, ImageAssetPool.Lease)
  return lease
end

-- One portrait-cell stub: the lease-plus-quad drawable shape production
-- portrait cells resolve, over a filterable stub image and stub cell quad.
-- Draws record the stub image and quad through the shared exact sampler.
---@param key string portrait drawable key ("mon:...")
---@return table<string, unknown> lease-plus-quad portrait drawable stub
function StubLease.cell(key)
  return {
    lease = StubLease.new(key),
    quad = { handle = "quad:" .. key },
  }
end

-- The pool-lease draw surface over an already-realized image (real love Image
-- or another stub): same sampler draw contract, no new image. Stub
-- tables gain the no-op filter the sampler normalizes; real images
-- already filter. Identity stays with the wrapped image.
---@param image table<string, unknown> realized image behind the stub
---@return table<string, unknown> pool-lease-shaped drawable stub
function StubLease.over(image)
  assert(image ~= nil, "lease stubs wrap realized images")
  if type(image) == "table" and type(image.setFilter) ~= "function" then
    image.setFilter = noopFilter
  end
  return setmetatable({
    image = image,
    kind = "rgba8",
  }, ImageAssetPool.Lease)
end

return StubLease
