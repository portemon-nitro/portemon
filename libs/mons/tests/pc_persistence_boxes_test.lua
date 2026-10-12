-- Box persistence keeps stable holes and metadata when the configured count grows.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")

local T = {}

local function boxesModule()
  local ok, result = pcall(require, "libs.mons.src.Boxes")
  Assert.isTrue(ok, "storage must provide persistent box ownership")
  return result
end

function T.retail_capacity_and_expansion_survive_reopen()
  local Boxes = boxesModule()
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(0x12345678, catalog)
  local standard = Boxes.new(nil, { configuredCount = 18 })
  Assert.equal(Boxes.new():count(), 18, "production reads the single default capacity")
  Assert.equal(standard:count(), 18)
  Assert.equal(Boxes.SLOTS_PER_BOX, 30)
  Assert.equal(standard:activeBox(), 0)
  Assert.equal(standard:mon(0, 0), nil)
  Assert.equal(standard:metadata(0).wallpaperId, 0)

  local mon = factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE", level = 5 }))
  local expanded = Boxes.new(nil, { configuredCount = 37 })
  Assert.equal(expanded:count(), 37)
  local preparation = expanded:prepareChanges(expanded:revision(), {
    updates = { { box = 36, slot = 29, mon = mon } },
    metadata = { { box = 36, name = "EXPANDED BOX", wallpaperId = 39 } },
    activeBox = 36,
  })
  Assert.isTrue(preparation.isCurrent())
  preparation.publish()

  local snapshot = expanded:capture()
  local reopened = Boxes.new(snapshot, { configuredCount = 18 })
  Assert.equal(reopened:count(), 37, "saved boxes remain authoritative when the configured count drops")
  Assert.deepEqual(reopened:mon(36, 29), mon)
  Assert.equal(reopened:mon(36, 0), nil, "holes before the occupied slot remain empty")
  Assert.equal(reopened:mon(36, 28), nil, "holes remain literal empty slots")
  Assert.equal(reopened:metadata(36).name, "EXPANDED BOX")
  Assert.equal(reopened:metadata(36).wallpaperId, 39)
  Assert.equal(reopened:activeBox(), 36)

  local medium = Boxes.new(nil, { configuredCount = 24 })
  Assert.equal(medium:count(), 24)
  local unchanged = reopened:prepareChanges(reopened:revision(), {
    metadata = { { box = 36, name = "EXPANDED BOX", wallpaperId = 39 } },
    activeBox = 36,
  })
  Assert.isFalse(unchanged.changed)
  unchanged.publish()
  Assert.equal(reopened:revision(), 0, "same-value metadata does not advance revision")

  for _, invalidCount in ipairs({ 0, -1, 1.5, 0 / 0, math.huge, -math.huge }) do
    Assert.throws(function()
      Boxes.new(nil, { configuredCount = invalidCount })
    end)
  end

  local malformed = snapshot
  malformed.boxes[37].slots[30] = nil
  Assert.throws(function()
    Boxes.new(malformed, { configuredCount = 18 })
  end)
end

-- Staging one slot must not pay for a full snapshot copy: preparation takes
-- no exported capture, leaves live state alone until publish, installs the
-- incoming mon as a detached copy, and keeps unrelated slots intact.
function T.single_slot_prepare_stages_without_copying_every_stored_mon()
  local Boxes = boxesModule()
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(0x12345678, catalog)
  local boxes = Boxes.new(nil, { configuredCount = 4 })
  local species = { "TOTODILE", "CHIKORITA", "EEVEE" }
  for box = 0, 3 do
    for slot = 0, 29 do
      if not (box == 1 and slot == 7) then
        local pick = species[((box * 30 + slot) % 3) + 1]
        local placed = factory:createNormal(CatalogFixture.normalRequest({
          species = pick,
          level = 5 + ((box + slot) % 3),
        }))
        local fill = boxes:prepareChanges(boxes:revision(), {
          updates = { { box = box, slot = slot, mon = placed } },
        })
        Assert.notNil(fill)
        fill.publish()
      end
    end
  end
  local before = boxes:capture()
  local untouched = boxes:mon(0, 0)
  local incoming = factory:createNormal(CatalogFixture.normalRequest({ species = "TOTODILE", level = 9 }))
  local pristineNickname = incoming.nickname

  local captures = 0
  local original = Boxes.capture
  Boxes.capture = function(self)
    captures = captures + 1
    return original(self)
  end
  local preparation
  local staged = pcall(function()
    preparation = boxes:prepareChanges(boxes:revision(), {
      updates = { { box = 1, slot = 7, mon = incoming } },
    })
  end)
  Boxes.capture = original
  Assert.isTrue(staged, "staging one slot prepares")
  Assert.notNil(preparation)
  Assert.equal(captures, 0, "staging one slot must not take a full snapshot copy")
  Assert.isTrue(preparation.changed)
  Assert.isTrue(preparation.isCurrent())
  Assert.deepEqual(boxes:capture(), before, "an uncommitted candidate never mutates live boxes")
  Assert.isNil(boxes:mon(1, 7), "the staged hole stays empty until publish")
  Assert.equal(before.boxes[2].slots[8], false)

  incoming.nickname = "STAGED EDIT"
  incoming.evs.hp = (incoming.evs.hp + 1) % 256
  preparation.publish()
  local stored = boxes:mon(1, 7)
  Assert.notNil(stored)
  Assert.equal(stored.nickname, pristineNickname, "the staged mon publishes detached from the caller record")
  Assert.deepEqual(boxes:mon(0, 0), untouched, "unrelated slots survive a localized edit")
  Assert.deepEqual(boxes:mon(3, 29), before.boxes[4].slots[30])
  Assert.deepEqual(before.boxes[2].slots[8], false, "the earlier capture keeps its own hole")
end

return { tests = T }
