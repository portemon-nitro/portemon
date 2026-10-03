-- Switch wiring through the production menu flow: the flow hands its
-- borrowed sound boundary to every party page that can switch, so the
-- list sound fires at the start and the midpoint while the live service
-- reorders exactly once at the end. ROM-free: a hand-built mon service
-- stages two semantic mons while the synthetic presentation manifest
-- carries the layout sections the party child resolves. Pages without a
-- sound boundary keep working; the boundary stays optional.

local Assert = require("tests.support.Assert")
local BagCursor = require("libs.hgss.src.items.BagCursor")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local ItemFixture = require("libs.items.tests.item_fixture")
local PartyPresentationFixture = require("tests.support.PartyPresentationFixture")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local SWITCH_SOUND = "SEQ_SE_DP_POKELIST_001"
local CONFIRM_SOUND = "SEQ_SE_DP_SELECT"

local function stubMeasurement()
  return {
    width = 256,
    height = 192,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 256, height = 192 },
      touch = true,
      role = "world",
    }),
    pixelRatio = 1,
    signature = "party-switch-test:256x192",
  }
end

---@return table fake mon service with two staged mons and a swap log
local function fakeMons()
  local catalog = CatalogFixture.makeCatalog()
  local calls = { swaps = {} }
  local revision = 5
  local function monRecord(species)
    return {
      species = species,
      form = 0,
      nickname = nil,
      personality = 0,
      condition = { status = 0, currentHp = 20 },
      moves = {},
      heldItem = "NONE",
      isEgg = false,
      shinyLeaves = 0,
      capsule = nil,
    }
  end
  local records = { monRecord("CHIKORITA"), monRecord("TOTODILE") }
  local service = {
    partyCount = function()
      return #records
    end,
    partyRevision = function()
      return revision
    end,
    partyMon = function(_, slot)
      return records[slot + 1]
    end,
    partyMonDerived = function()
      return { level = 5, maxHp = 20 }
    end,
    catalog = function()
      return catalog
    end,
    swapPartyMons = function(_, a, b)
      calls.swaps[#calls.swaps + 1] = { a, b }
      local first = records[a + 1]
      records[a + 1] = records[b + 1]
      records[b + 1] = first
      revision = revision + 1
    end,
  }
  return service, calls
end

---@param service table
---@param effect fun(sequence: string)?
---@return table rig with the live flow and recording ports
local function openPartyFlow(service, effect)
  local Flow = require("game.hgss.src.field.PokemonMenuFlow")
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local flow = Flow.new({
    root = "party",
    mons = service,
    bag = bag,
    bagCursor = BagCursor.new(),
    partyActions = {
      preview = function(_)
        return { kind = "preview" }
      end,
      commit = function(_, _)
        return { kind = "no_op" }
      end,
    },
    fieldMoves = {
      check = function(_)
        return { kind = "ok" }
      end,
    },
    assets = {
      bagManifest = {},
      partyManifest = PartyPresentationFixture.manifest(),
      uiManifest = FieldUiFixture.manifest(),
      monCatalog = {
        moveByNativeId = function()
          error("move picks never open in the switch suite", 0)
        end,
      },
      itemCatalog = bag:catalog(),
      heroGender = "male",
    },
    measureDisplay = stubMeasurement,
    prepareIcons = function(_)
      return true, nil
    end,
    cancelIconPreparation = function() end,
    effect = effect,
  })
  return { flow = flow, service = service }
end

local function childStatus(rig)
  local status = rig.flow:status()
  Assert.isTrue(status.open, "the party flow stays open")
  return assert(status.child, "the party page carries its child status")
end

-- A fresh party page clears its open before input: wait for the leaf
-- to turn interactive, then run out the handover ticks that still drop
-- input so the first navigation acts.
local function settleInteractive(rig)
  for _ = 1, 30 do
    if childStatus(rig).phase == "interactive" then
      break
    end
    rig.flow:updateFixed({})
  end
  rig.flow:updateFixed({})
  rig.flow:updateFixed({})
end

---@param rig table
---@param label string
---@param maxSteps integer
---@param predicate fun(child: table): boolean
local function driveUntilChild(rig, label, maxSteps, predicate)
  for _ = 1, maxSteps do
    local child = childStatus(rig)
    if predicate(child) then
      return child
    end
    rig.flow:updateFixed({})
  end
  error("the party flow never reaches " .. label, 0)
end

-- Confirms the focused slot, focuses the switch entry, and arms the
-- destination pick through the gated press cadence.
local function armSwitch(rig)
  settleInteractive(rig)
  rig.flow:updateFixed({ { type = "confirm" } })
  Assert.equal(childStatus(rig).state, "context", "confirming the lead opens its context menu")
  rig.flow:updateFixed({ { type = "navigate", direction = "down" } })
  rig.flow:updateFixed({ { type = "confirm" } })
  driveUntilChild(rig, "the switch destination pick", 10, function(child)
    return child.state == "choose_swap"
  end)
end

-- Clears recorded setup effects where a later contract intentionally
-- measures only the sounds from its own stimulus onward.
---@param sounds string[]
local function drainSounds(sounds)
  for index = 1, #sounds do
    sounds[index] = nil
  end
end

function T.switch_animation_sounds_twice_and_reorders_once_through_the_flow()
  local service, calls = fakeMons()
  local sounds = {}
  local rig = openPartyFlow(service, function(sequence)
    sounds[#sounds + 1] = sequence
  end)
  local revision = service:partyRevision()
  armSwitch(rig)
  rig.flow:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(childStatus(rig).cursorNode, 1, "setup focuses the destination slot")
  rig.flow:updateFixed({ { type = "confirm" } })
  drainSounds(sounds)
  driveUntilChild(rig, "the settled switch", 60, function(child)
    return child.state == "browse" and child.swap == nil
  end)
  Assert.deepEqual(sounds, { SWITCH_SOUND, SWITCH_SOUND }, "the start and the midpoint sound exactly once each")
  Assert.equal(#calls.swaps, 1, "the return commits exactly once")
  Assert.deepEqual(calls.swaps[1], { 0, 1 }, "the commit carries its source and destination")
  Assert.equal(service:partyRevision(), revision + 1, "exactly one revision publishes the reorder")
  local child = childStatus(rig)
  Assert.equal(child.cursorNode, 1, "focus follows the destination")
end

function T.switch_without_a_sound_boundary_still_reorders_once()
  local service, calls = fakeMons()
  local rig = openPartyFlow(service, nil)
  local revision = service:partyRevision()
  armSwitch(rig)
  rig.flow:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(childStatus(rig).cursorNode, 1, "setup focuses the destination slot")
  rig.flow:updateFixed({ { type = "confirm" } })
  driveUntilChild(rig, "the settled switch", 60, function(child)
    return child.state == "browse" and child.swap == nil
  end)
  Assert.equal(#calls.swaps, 1, "pages without a sound boundary still commit exactly once")
  Assert.equal(service:partyRevision(), revision + 1, "exactly one revision publishes the reorder")
end

-- Confirming the destination requests the source selection effect at
-- activation; the swap animation keeps its own start/midpoint list
-- sounds on later ticks.
function T.switch_destination_confirmation_sounds_select_before_the_first_animation_tick()
  local service, calls = fakeMons()
  local sounds = {}
  local rig = openPartyFlow(service, function(sequence)
    sounds[#sounds + 1] = sequence
  end)
  armSwitch(rig)
  rig.flow:updateFixed({ { type = "navigate", direction = "right" } })
  Assert.equal(childStatus(rig).cursorNode, 1, "setup focuses the destination slot")
  drainSounds(sounds)
  rig.flow:updateFixed({ { type = "confirm" } })
  local armed = childStatus(rig)
  Assert.equal(armed.state, "swapping", "confirming the destination starts the animation")
  Assert.isTrue(armed.swap ~= nil, "arming publishes its swap record")
  Assert.equal(armed.swap.xOffset, 0, "arming holds tile-step zero")
  Assert.isFalse(armed.swap.exchanged == true, "arming exchanges nothing yet")
  Assert.deepEqual(sounds, { CONFIRM_SOUND }, "destination confirmation requests select at activation")
  Assert.equal(#calls.swaps, 0, "arming publishes nothing")
  rig.flow:updateFixed({})
  local started = childStatus(rig)
  Assert.equal(started.swap.xOffset, 0, "the first animation tick holds offset zero")
  Assert.deepEqual(
    sounds,
    { CONFIRM_SOUND, SWITCH_SOUND },
    "the first animation tick adds the list sound after the confirmation"
  )
  Assert.equal(#calls.swaps, 0, "the first animation tick publishes nothing")
end

return { tests = T }
