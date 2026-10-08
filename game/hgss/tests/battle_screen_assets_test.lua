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

-- A bare not-yet answer polls again without failing, while a nil answer
-- or any answer carrying a failure string fails closed with context.
function T.preparation_pending_and_typed_failures()
  local polls = 0
  local patient = { images = {}, released = {} }
  function patient.prepare(_)
    polls = polls + 1
    if polls == 1 then
      return false
    end
    return true
  end
  function patient.drawable(key)
    if patient.images[key] == nil then
      patient.images[key] = { handle = key }
    end
    return patient.images[key]
  end
  function patient.release(key)
    patient.released[key] = (patient.released[key] or 0) + 1
  end
  local waiting = BattlePresentationAssets.new({
    assets = patient,
    launchId = "assets-patient",
    sceneKey = "general/plain/day",
    sceneImage = "scene:patient",
  })
  waiting:update()
  Assert.equal(waiting:state(), "pending", "a bare not-yet answer polls again without failing")
  Assert.isNil(waiting:error(), "polling again carries no failure context")
  waiting:update()
  Assert.equal(waiting:state(), "ready", "the prepared demand completes once the service answers")
  waiting:dispose()

  local untyped = BattlePresentationAssets.new({
    assets = stubAssets({ failPrepare = "test-typed-nil" }),
    launchId = "assets-untyped",
    sceneKey = "general/plain/day",
    sceneImage = "scene:untyped",
  })
  untyped:update()
  Assert.equal(untyped:state(), "failed", "a nil answer with a message fails closed")
  Assert.isTrue(
    (untyped:error() or ""):find("test%-typed%-nil", 1) ~= nil,
    "the nil failure carries its context"
  )
  untyped:dispose()

  local reluctant = { images = {}, released = {} }
  function reluctant.prepare(_)
    return false, "test-typed-false"
  end
  function reluctant.drawable(key)
    if reluctant.images[key] == nil then
      reluctant.images[key] = { handle = key }
    end
    return reluctant.images[key]
  end
  function reluctant.release(key)
    reluctant.released[key] = (reluctant.released[key] or 0) + 1
  end
  local refused = BattlePresentationAssets.new({
    assets = reluctant,
    launchId = "assets-refused",
    sceneKey = "general/plain/day",
    sceneImage = "scene:refused",
  })
  refused:update()
  Assert.equal(refused:state(), "failed", "a not-yet answer carrying a failure string fails closed")
  Assert.isTrue(
    (refused:error() or ""):find("test%-typed%-false", 1) ~= nil,
    "the typed failure carries its context"
  )
  refused:dispose()
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

-- A regrown demand keeps readiness on a bare not-yet answer, while nil
-- or a failure string fails closed with context.
function T.regrown_demand_prefetch_failures()
  local assets = stubAssets({})
  local waiting = holder(nil, assets)
  waiting:update()
  Assert.equal(waiting:state(), "ready", "the first demand prepares")
  function assets.prepare(_)
    return false
  end
  waiting:addSelectors({ "mon:enemy:front" })
  Assert.equal(waiting:state(), "ready", "a bare not-yet regrow keeps readiness")
  Assert.isNil(waiting:error(), "the kept readiness carries no failure context")
  waiting:dispose()

  local nilAssets = stubAssets({})
  local nilled = holder(nil, nilAssets)
  nilled:update()
  function nilAssets.prepare(_)
    return nil, "test-regrow-nil"
  end
  nilled:addSelectors({ "mon:enemy:front" })
  Assert.equal(nilled:state(), "failed", "a nil regrow answer fails closed")
  Assert.isTrue(
    (nilled:error() or ""):find("test%-regrow%-nil", 1) ~= nil,
    "the nil regrow failure carries its context"
  )
  nilled:dispose()

  local typedAssets = stubAssets({})
  local refused = holder(nil, typedAssets)
  refused:update()
  function typedAssets.prepare(_)
    return false, "test-regrow-typed"
  end
  refused:addSelectors({ "mon:enemy:front" })
  Assert.equal(refused:state(), "failed", "a regrow answer carrying a failure string fails closed")
  Assert.isTrue(
    (refused:error() or ""):find("test%-regrow%-typed", 1) ~= nil,
    "the typed regrow failure carries its context"
  )
  refused:dispose()
end

return { tests = T }
