-- The concrete party-screen application owns its icon-preparation wait: it
-- reports pending/error preparation instead of normal selection input,
-- stays cancellable while waiting, discards held activation received
-- before readiness, and releases its preparation interest exactly once on
-- close or disposal. Swaps and close results keep their existing meaning
-- once preparation is ready.

local Assert = require("tests.support.Assert")
local PartyScreenState = require("game.hgss.src.field.PartyScreenState")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local T = {}

local function fakeCatalog()
  return {
    species = function(_)
      return { name = "Chikorita", genderRatio = 127 }
    end,
    item = function(_, item)
      assert(item == "NONE")
      return { name = "None" }
    end,
    iconSelection = function(_, mon)
      return mon.species .. "/f" .. mon.form
    end,
  }
end

local function fakeService(calls)
  local catalog = fakeCatalog()
  return {
    partyCount = function(_)
      return 2
    end,
    partyRevision = function(_)
      return 1
    end,
    partyMon = function(_)
      return {
        species = "CHIKORITA",
        form = 0,
        isEgg = false,
        personality = 0,
        nickname = "CHIKO",
        heldItem = "NONE",
        moves = { { move = "TACKLE", pp = 35, ppUps = 0 } },
        condition = { currentHp = 20, status = 0 },
      }
    end,
    partyMonDerived = function(_)
      return { maxHp = 20, level = 5 }
    end,
    catalog = function(_)
      return catalog
    end,
    swapPartyMons = function(_, a, b)
      calls.swaps[#calls.swaps + 1] = { a, b }
    end,
  }
end

---@param ready boolean
---@param failure string?
---@param calls table<string, unknown>
---@return PartyScreenState state
---@return table<string, fun(): integer> probes
local function sourceManifest()
  local panels = {}
  local origins = { { 0, 0 }, { 128, 8 }, { 0, 48 }, { 128, 56 }, { 0, 96 }, { 128, 104 } }
  for slot, origin in ipairs(origins) do
    panels[slot] = {
      origin = { x = origin[1], y = origin[2] },
      size = { width = 128, height = 48 },
    }
  end
  local function dpadBox(up, down, leftNeighbor, rightNeighbor)
    return {
      left = 0,
      top = 0,
      width = 0,
      height = 0,
      up = up,
      down = down,
      leftNeighbor = leftNeighbor,
      rightNeighbor = rightNeighbor,
    }
  end
  local function touch(top, bottom, left, right)
    return { top = top, bottom = bottom, left = left, right = right }
  end
  return {
    panels = panels,
    windows = {
      message = { x = 16, y = 168, width = 160, height = 16 },
      context = { x = 152, y = 120, width = 96, height = 64 },
    },
    navigation = {
      dpad = {
        default = {
          dpadBox(7, 2, 7, 1),
          dpadBox(7, 3, 0, 2),
          dpadBox(0, 4, 1, 3),
          dpadBox(1, 5, 2, 4),
          dpadBox(2, 7, 3, 5),
          dpadBox(3, 7, 4, 7),
          dpadBox(0, 0, 0, 0),
          dpadBox(5, 1, 5, 0),
        },
      },
    },
    hitboxes = {
      touch = {
        default = {
          touch(0, 48, 0, 128),
          touch(8, 56, 128, 0),
          touch(48, 96, 0, 128),
          touch(56, 104, 128, 0),
          touch(96, 144, 0, 128),
          touch(104, 152, 128, 0),
          touch(152, 192, 200, 0),
        },
      },
    },
  }
end

local function openParty(ready, failure, calls)
  local preparations = 0
  local cancels = 0
  local service = fakeService(calls)
  local measurement = {
    width = 800,
    height = 600,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 800, height = 600 },
      role = "world",
      touch = false,
    }),
    pixelRatio = 1,
    signature = "party-screen-state-test:800x600",
  }
  local state = PartyScreenState.new({
    service = service,
    manifest = sourceManifest(),
    measureDisplay = function()
      return measurement
    end,
    prepareIcons = function(_)
      preparations = preparations + 1
      return ready, failure
    end,
    cancelIconPreparation = function()
      cancels = cancels + 1
    end,
  })
  return state,
    {
      preparations = function()
        return preparations
      end,
      cancels = function()
        return cancels
      end,
    }
end

-- Activation held while icons prepare must not select anything: the screen
-- reports pending preparation and stays there until readiness arrives.
function T.opening_waits_for_icon_preparation_before_accepting_selection()
  local calls = { swaps = {} }
  local state, _ = openParty(false, nil, calls)
  state:updateFixed({ { type = "confirm" } })
  local status = state:status()
  Assert.equal(status.preparationState, "pending", "the screen waits for icon preparation before normal input")
  Assert.isNil(status.action, "held activation never selects while preparation is pending")
  Assert.equal(#calls.swaps, 0, "no swap fires before readiness")
  state:dispose()
end

-- Closing or disposing a waiting screen drops its preparation interest
-- exactly once; a late readiness arrival cannot reopen or draw it. The
-- same exactly-once release holds for a screen disposed after readiness.
function T.closing_releases_icon_preparation_exactly_once()
  local calls = { swaps = {} }
  local state, probes = openParty(false, nil, calls)
  state:updateFixed({})
  state:dispose()
  Assert.equal(probes.cancels(), 1, "disposal cancels the outstanding preparation exactly once")
  Assert.isNil(state:takeResult(), "disposal reports no close after cancelling")
  local readyCalls = { swaps = {} }
  local readyState, readyProbes = openParty(true, nil, readyCalls)
  readyState:updateFixed({})
  readyState:dispose()
  Assert.equal(readyProbes.cancels(), 1, "disposal releases a finished preparation exactly once")
end

-- Once preparation is ready the existing selection, swap, and close
-- behavior is unchanged. This guards current behavior through the new
-- required collaborators: it passes before and after the wait lands.
function T.ready_preparation_preserves_selection_and_close()
  local calls = { swaps = {} }
  local state, probes = openParty(true, nil, calls)
  state:updateFixed({ { type = "confirm" } })
  local status = state:status()
  Assert.equal(status.action, "context", "selection input works after readiness")
  Assert.equal(#calls.swaps, 0, "opening the context menu swaps nothing")
  Assert.isNil(state:takeResult(), "opening the context menu completes nothing")
  Assert.equal(probes.cancels(), 0, "nothing cancels while the screen stays open")
  state:dispose()
end

return { tests = T }
