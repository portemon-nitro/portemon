-- Configured sprite placement and cell fidelity: sprites initialize at
-- the defender screen position with their selected bindings, and every
-- authored cell part reaches the scene. Probes run the real task body
-- against a real scene with synthetic staged sprite banks.

local Assert = require("tests.support.Assert")
local BattleEffectTasks = require("libs.hgss/src/presentation/BattleEffectTasks")
local BattleScene = require("libs.hgss.src.presentation.BattleScene")

local T = {}

-- The solo-enemy battler picture center the native slots stage through.
-- It mirrors EMITTER_CENTERS["solo-enemy"] in BattleEffectTasks and is
-- asserted once below; every other expectation rides authored deltas so a
-- settled-geometry move touches one line.
local DEFENDER_CENTER = { x = 192, y = 50 }

local function occurrenceContext()
  return {
    launchId = "native-sprite-probe",
    packetId = 1,
    programKey = "native-sprite-probe",
    seed = 4242,
    random = function(bound)
      assert(type(bound) == "number" and bound > 0, "visual draws name a positive bound")
      return 0
    end,
    topology = {
      attacker = { combatant = 1, activation = 1, slot = "solo-player", sideType = 0 },
      targets = { { combatant = 3, activation = 3, slot = "solo-enemy", sideType = 1 } },
    },
    event = { sequence = 1, actionId = 1, hitIndex = 1, effectKey = "native-sprite-probe" },
    visualSeed = 4242,
  }
end

local function stagedServices()
  local leases = {
    ["sprite/character"] = { key = "sprite/character", kind = "texture", width = 64 },
    ["sprite/palette"] = { key = "sprite/palette", kind = "palette", data = { colors = { 0, 1, 2 } } },
  }
  local journal = { acquired = {}, released = {} }
  local resources = {}
  function resources.resolve(key)
    journal.acquired[#journal.acquired + 1] = key
    local lease = leases[key]
    assert(lease ~= nil, "staged bank carries " .. key)
    return lease
  end
  function resources.release(lease)
    journal.released[#journal.released + 1] = lease
  end
  return { scene = BattleScene.new(), audio = {}, resources = resources }, journal, leases
end

local function bankWith(cells, anims, leases)
  leases["sprite/cell"] = { key = "sprite/cell", kind = "cells", data = { cells = cells } }
  leases["sprite/animation"] = { key = "sprite/animation", kind = "animation", data = { anims = anims } }
end

local function spawnKind()
  return "probe-configured-sprite"
end

local function spawnArgs()
  return {
    resourceKeys = {
      character = "sprite/character",
      palette = "sprite/palette",
      cell = "sprite/cell",
      animation = "sprite/animation",
    },
  }
end

function T.configured_sprites_center_every_authored_cell_part_on_the_defender()
  -- One spawn proves both halves of the placement contract: parts
  -- initialize on the defender position with their selected bindings, and
  -- every authored cell part reaches the scene with its distinct offset
  -- instead of collapsing onto one rectangle.
  local services, _, leases = stagedServices()
  bankWith(
    {
      {
        objs = {
          { x = 0, y = 0, tile = 0, width = 8, height = 8, priority = 0 },
          { x = 8, y = 0, tile = 1, width = 8, height = 8, priority = 0 },
        },
      },
    },
    { { frames = { { cell = 0, duration = 4 } } } },
    leases
  )
  local task = assert(BattleEffectTasks.create(spawnKind(), spawnArgs(), occurrenceContext(), services))
  task:stepSourceTick({ tick = 1 })
  local views = services.scene:effectViews()
  Assert.equal(#views, 2, "both authored parts of one cell reach the scene")
  local first = assert(views[1].picture, "the first part publishes staged picture state")
  local second = assert(views[2].picture, "the second part publishes staged picture state")
  Assert.equal(first.centerX, DEFENDER_CENTER.x + 4, "8-pixel parts center on the defender horizontal position")
  Assert.equal(first.centerY, DEFENDER_CENTER.y + 4, "8-pixel parts center on the defender vertical position")
  Assert.equal(
    second.centerX - first.centerX,
    8,
    "retained parts keep their distinct authored offsets"
  )
end

return { tests = T }
