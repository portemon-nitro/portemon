-- Unit coverage for the per-launch battle resource holder: validated
-- frame selection, truthful pending/ready/failed preparation, owned
-- handle tracking with exactly-once release, and delayed versus missing
-- images. The preparation double below stands in for the real asset
-- services with held keys, injected failures, and per-key release
-- counts.

local Assert = require("tests.support.Assert")
local BattlePresentationAssets = require("game.hgss.src.battle.BattlePresentationAssets")

local T = {}

---@param opts table? heldKeys, failPrepare, seedImages
---@return table preparation double owning only the handles it hands out
local function stubAssets(opts)
  opts = opts or {}
  local held = {}
  for _, key in ipairs(opts.heldKeys or {}) do
    held[key] = true
  end
  local assets = { hold = held, failPrepare = opts.failPrepare, images = opts.seedImages or {}, released = {} }
  function assets.prepare(_)
    if assets.failPrepare ~= nil then
      return nil, assets.failPrepare
    end
    return true
  end
  function assets.drawable(key)
    if assets.hold[key] then
      return nil
    end
    if assets.images[key] == nil then
      assets.images[key] = { handle = key }
    end
    return assets.images[key]
  end
  function assets.release(key)
    assets.released[key] = (assets.released[key] or 0) + 1
  end
  return assets
end

---@param overrides table? per-instance definition input under test driving
---@param assets table? preparation double under test driving
---@return table holder under test driving
local function holder(overrides, assets)
  return BattlePresentationAssets.new({
    assets = assets or stubAssets({}),
    launchId = "assets-probe",
    sceneKey = "general/plain/day",
    sceneImage = "scene:probe",
    frameKey = overrides and overrides.frameKey,
    frames = overrides and overrides.frames,
  })
end

-- The default frame and a declared custom frame both prepare; their
-- selected images stay drawable through the holder.
function T.known_frames_prepare()
  local known = holder({ frameKey = "custom-probe-frame", frames = { ["custom-probe-frame"] = {} } })
  known:update()
  Assert.equal(known:state(), "ready", "a declared custom frame prepares")
  Assert.notNil(known:drawable("scene:probe"), "the scene image stays drawable through the holder")
  local fallback = holder(nil)
  fallback:update()
  Assert.equal(fallback:state(), "ready", "the default frame prepares without declarations")
  Assert.equal(fallback:frameKey(), "default", "the default frame key is reported")
  known:dispose()
  fallback:dispose()
end

-- An unknown frame stops preparation with definition context instead of
-- substituting a different frame or reporting false success.
function T.unknown_frames_fail_explicitly()
  local assets = stubAssets({})
  local bad = holder({ frameKey = "no-such-frame" }, assets)
  bad:update()
  Assert.equal(bad:state(), "failed", "the unknown frame stops the holder")
  local err = bad:error()
  Assert.isTrue(type(err) == "string" and err ~= "", "the failure carries its context")
  Assert.isTrue(
    err:find("no%-such%-frame", 1) ~= nil and err:find("frame", 1) ~= nil,
    "the failure names its missing definition"
  )
  bad:dispose()
  bad:dispose()
end

-- A preparation failure reaches the failure context with no false
-- interaction.
function T.preparation_failure_surfaces()
  local bad = BattlePresentationAssets.new({
    assets = stubAssets({ failPrepare = "test-scene-missing" }),
    launchId = "assets-sad",
    sceneKey = "general/plain/day",
    sceneImage = "scene:sad",
  })
  bad:update()
  Assert.equal(bad:state(), "failed", "the preparation failure stops the holder")
  Assert.isTrue((bad:error() or ""):find("test%-scene%-missing", 1) ~= nil, "the service error reaches the context")
  bad:dispose()
end

-- A held image reports pending instead of failing or skipping ahead;
-- releasing it completes preparation exactly.
function T.delayed_images_stay_pending()
  local assets = stubAssets({ heldKeys = { "scene:probe" } })
  local slow = holder(nil, assets)
  slow:update()
  Assert.equal(slow:state(), "pending", "the missing scene holds preparation without failing")
  for _ = 1, 10 do
    slow:update()
  end
  Assert.equal(slow:state(), "pending", "repeated polls never invent the missing image")
  assets.hold["scene:probe"] = nil
  slow:update()
  Assert.equal(slow:state(), "ready", "releasing the image completes preparation")
  slow:dispose()
end

-- Disposal releases each owned handle exactly once and never touches
-- unowned keys; borrowed doubles stay usable.
function T.disposal_releases_owned_handles_once()
  local assets = stubAssets({})
  local owned = holder(nil, assets)
  owned:update()
  Assert.notNil(owned:drawable("scene:probe"), "the scene image is owned")
  Assert.notNil(owned:drawable("mon:player:back"), "the player image is owned")
  owned:dispose()
  owned:dispose()
  Assert.equal(assets.released["scene:probe"], 1, "the scene handle releases once")
  Assert.equal(assets.released["mon:player:back"], 1, "the player handle releases once")
  Assert.isNil(assets.released["mon:enemy:front"], "never-drawn keys never release")
end

return { tests = T }
