-- Field evolution scene ownership: the asset holder's staging, failure, and
-- release lifecycle, and the scene's field-music hold, which restores the
-- map music exactly once however the scene ends.

local Assert = require("tests.support.Assert")
local FieldEvolutionAssets = require("game.hgss.src.field.FieldEvolutionAssets")
local FieldEvolutionScene = require("game.hgss.src.field.FieldEvolutionScene")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

---@return FieldEvolutionAssets assets
---@return table rig recorded demands, releases, and the answer slots
local function newAssets()
  local rig = {
    demands = {},
    released = {},
    core = nil,
    prepareAnswer = false,
    prepareFailure = nil,
    drawableFailure = nil,
  }
  local services = {
    prepare = function(demand)
      rig.demands[#rig.demands + 1] = demand
      return rig.prepareAnswer, rig.prepareFailure
    end,
    drawable = function(key)
      if rig.drawableFailure == key then
        return nil, "upload failed"
      end
      return { key = key }
    end,
    release = function(key)
      rig.released[#rig.released + 1] = key
    end,
    prepareEvolution = function()
      return rig.leaf
    end,
  }
  local assets = FieldEvolutionAssets.new({
    services = services,
    verifiedManifest = function()
      return rig.core
    end,
    audioBanks = function()
      return { 700 }
    end,
    sceneId = "scene-1",
  })
  return assets, rig
end

function T.assets_wait_for_the_core_and_share_it_without_mutation()
  local assets, rig = newAssets()
  Assert.isNil(assets:manifest(), "a pending core answers no view")
  rig.core = { verified = true, messages = { entries = {} } }
  local view = assets:manifest()
  Assert.equal(view.messages, rig.core.messages, "the view borrows the core sections")
  view.evolutionGraphics = {}
  Assert.isNil(rig.core.evolutionGraphics, "the presenter writes onto the view, never the core")
  Assert.equal(assets:manifest(), view, "one view serves the scene")
end

function T.assets_stage_the_leaf_once_and_latch_its_failure()
  local assets, rig = newAssets()
  Assert.isNil(assets:ensureEvolution(), "a pending leaf answers nothing")
  rig.leaf = { particles = {} }
  Assert.equal(assets:ensureEvolution(), rig.leaf)
  rig.leaf = nil
  Assert.equal(assets:ensureEvolution(), assets:ensureEvolution(), "a staged leaf is kept")

  local failing = FieldEvolutionAssets.new({
    services = {
      prepare = function()
        return true
      end,
      drawable = function() end,
      release = function() end,
      prepareEvolution = function()
        return nil, "no leaf"
      end,
    },
    verifiedManifest = function() end,
    audioBanks = function()
      return {}
    end,
    sceneId = "scene-2",
  })
  local _, failure = failing:ensureEvolution()
  Assert.isTrue(failure:find("no leaf", 1, true) ~= nil and failure:find("scene-2", 1, true) ~= nil)
  Assert.equal(select(2, failing:ensureEvolution()), failure, "the failure replays without retrying")
end

function T.assets_prepare_pages_and_banks_and_reopen_on_new_selectors()
  local assets, rig = newAssets()
  assets:update()
  Assert.equal(#rig.demands, 1, "the first update demands once")
  Assert.equal(rig.demands[1].audio.banks[1], 700, "the scene's sequence banks ride the demand")
  Assert.equal(assets:state(), "pending", "a not-yet answer polls again")
  assets:update()
  Assert.equal(#rig.demands, 2)
  rig.prepareAnswer = true
  assets:update()
  Assert.equal(assets:state(), "ready")
  assets:update()
  Assert.equal(#rig.demands, 3, "a ready holder demands nothing more")
  assets:addSelectors({ "EEVEE/f0/male/plain" })
  Assert.equal(assets:state(), "pending", "a new portrait reopens preparation")
  assets:addSelectors({ "EEVEE/f0/male/plain" })
  assets:update()
  Assert.equal(assets:state(), "ready")
  Assert.equal(rig.demands[4].pages[1], "EEVEE/f0/male/plain")
  Assert.equal(#rig.demands, 4, "a known selector adds no demand")
end

function T.assets_latch_terminal_preparation_failure_without_retrying()
  local assets, rig = newAssets()
  rig.prepareFailure = "audio-bank failed"
  assets:update()
  Assert.equal(assets:state(), "failed", "a terminal preparation answer remains failed")
  Assert.isTrue(assets:error():find("audio-bank failed", 1, true) ~= nil, "the holder retains the reason")
  assets:update()
  Assert.equal(#rig.demands, 1, "terminal failures never retry preparation")
end

function T.assets_latch_a_failed_image_and_release_each_drawable_once()
  local assets, rig = newAssets()
  Assert.equal(assets:drawable("battle:evolution:main").key, "battle:evolution:main")
  Assert.equal(assets:drawable("battle:evolution:main").key, "battle:evolution:main")
  rig.drawableFailure = "mon:EEVEE/f0/male/plain"
  local image, failure = assets:drawable("mon:EEVEE/f0/male/plain")
  Assert.isNil(image)
  Assert.isTrue(failure:find("upload failed", 1, true) ~= nil)
  Assert.equal(assets:state(), "failed", "a terminal upload failure fails the holder")
  Assert.equal(select(2, assets:drawable("battle:evolution:sub")), failure, "later keys replay the failure")
  assets:dispose()
  assets:dispose()
  Assert.equal(#rig.released, 1, "each owned drawable releases once")
  Assert.equal(rig.released[1], "battle:evolution:main")
end

local function measurement()
  return {
    width = 256,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" }
    ),
    pixelRatio = 1,
    signature = "evolution-scene",
  }
end

---@return FieldEvolutionScene scene still waiting on its presentation core
---@return table audio recorded policy calls
---@return table assets recorded disposal
local function pendingScene(manifestFailure)
  local audio = { calls = {} }
  function audio:suspendFieldPolicy(token)
    self.calls[#self.calls + 1] = "suspend:" .. token
  end
  function audio:resumeFieldPolicy(token, restore)
    self.calls[#self.calls + 1] = "resume:" .. token .. ":" .. tostring(restore)
  end
  local assets = { disposed = 0 }
  function assets:manifest()
    return nil, manifestFailure
  end
  function assets:dispose()
    self.disposed = self.disposed + 1
  end
  local scene = FieldEvolutionScene.new({
    request = { slot = 0, subject = {}, context = {}, source = "field_item" },
    sceneId = "menu-evolution:1",
    assets = assets,
    audio = audio,
    monCatalog = {},
    splRandomState = { state = 0 },
    summary = {},
    measureDisplay = measurement,
    textSpeed = "mid",
  })
  return scene, audio, assets
end

function T.terminal_composition_failure_disposes_scene_and_releases_field_music()
  local scene, audio, assets = pendingScene("audio-bank failed")
  local ok, failure = pcall(scene.updateFixed, scene, {})
  Assert.isFalse(ok, "a terminal scene preparation error is surfaced")
  Assert.isTrue(tostring(failure):find("audio-bank failed", 1, true) ~= nil, "the source failure is preserved")
  Assert.equal(audio.calls[2], "resume:menu-evolution:1:true", "failure restores the field music")
  Assert.equal(assets.disposed, 1, "failure disposes the owned asset lease once")
  scene:dispose()
  Assert.equal(#audio.calls, 2, "repeated disposal never releases field music twice")
  Assert.equal(assets.disposed, 1, "repeated disposal never releases the asset lease twice")
end

function T.scene_holds_the_field_music_from_construction_and_restores_it_once_on_dispose()
  local scene, audio, assets = pendingScene()
  Assert.equal(audio.calls[1], "suspend:menu-evolution:1", "the scene claims the policy at construction")
  scene:updateFixed({ { type = "confirm" } })
  Assert.equal(scene:status().presentation.inputKey, "evolution", "a pending scene still publishes its plan")
  Assert.isNil(scene:takeResult(), "a pending scene seals nothing")
  scene:dispose()
  scene:dispose()
  Assert.equal(#audio.calls, 2, "the policy releases exactly once")
  Assert.equal(audio.calls[2], "resume:menu-evolution:1:true", "disposal restores the map music")
  Assert.equal(assets.disposed, 1, "the asset holder releases exactly once")
end

return { tests = T }
