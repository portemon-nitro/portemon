-- Location staging publishes one destination tuple and preserves unrelated save domains.

local Assert = require("tests.support.Assert")
local Fixture = require("app.tests.support.SaveEditorFixture")

local T = { tests = {} }

function T.tests.destination_tuple_reverts_and_preserves_unrelated_edits()
  local fixture = Fixture.new()
  local Session = require("app.src.saveeditor.SaveEditorSession")
  local session, err = Session.new({
    record = fixture.initial,
    context = fixture.context,
    saveStore = fixture.store,
    saveFs = fixture.saveFs,
    validateRecord = fixture.validateRecord,
    symbols = fixture.symbols,
  })
  Assert.isNil(err, "the canonical save fixture opens in the existing transaction owner")
  session = assert(session)
  local original = fixture.copy(fixture.initial)
  local sameMap = {
    mapId = original.mapId,
    fieldX = original.fieldX + 1,
    fieldZ = original.fieldZ,
    surfaceId = 5,
    worldY = 2.5,
    terrainDependencyHash = "destination-centered-indoor-window",
  }
  local crossMap = {
    mapId = original.mapId + 1,
    fieldX = 704,
    fieldZ = 417,
    surfaceId = 8,
    worldY = 0.5,
    terrainDependencyHash = "destination-centered-outdoor-window",
  }
  local function successful(result)
    Assert.isTrue(result.ok, result.error and result.error.message or "the staged edit must succeed")
    return result
  end

  successful(session:setMoney(4800))
  successful(session:setFlag("FLAG_HIDDENITEM_D42R0101_HYPER_POTION", false))
  successful(session:setBagQuantity("POTION", 2))
  local stagedCandidate = session:captureCandidate()
  local browsedRevision = session:revision()
  Assert.deepEqual(session:captureCandidate(), stagedCandidate, "browsing and inspection leave the candidate unchanged")
  Assert.equal(session:revision(), browsedRevision, "browsing does not publish a Session revision")

  successful(session:setLocation(sameMap))
  local sameMapCandidate = session:captureCandidate()
  for _, key in ipairs({ "mapId", "fieldX", "fieldZ", "surfaceId", "worldY", "terrainDependencyHash" }) do
    Assert.equal(sameMapCandidate[key], sameMap[key], "the destination tuple stores " .. key)
  end
  Assert.equal(sameMapCandidate.facing, original.facing, "relocation preserves facing")
  Assert.deepEqual(sameMapCandidate.avatar, { state = "walking" }, "relocation uses ordinary walking")
  Assert.isNil(sameMapCandidate.suppression, "relocation clears coordinate-specific suppression")
  Assert.equal(sameMapCandidate.weatherId, original.weatherId, "same-map relocation preserves weather override")
  Assert.deepEqual(sameMapCandidate.audio, original.audio, "same-map relocation preserves audio overrides")
  Assert.equal(sameMapCandidate.playerData.profile.money, 4800, "location preserves staged money")
  Assert.isNil(sameMapCandidate.world.flags[817], "location preserves staged named flags")
  Assert.deepEqual(sameMapCandidate.mons, original.mons, "location preserves party data")
  Assert.equal(sameMapCandidate.bag.pockets.medicine[1].quantity, 2, "location preserves staged bag quantity")
  Assert.deepEqual(sameMapCandidate.fieldTravel, original.fieldTravel, "location preserves heal and travel destinations")
  Assert.deepEqual(sameMapCandidate.world.objects, original.world.objects, "location preserves actor snapshots")
  Assert.deepEqual(sameMapCandidate.scripts, original.scripts, "location preserves script state")

  successful(session:setLocation(crossMap))
  local crossMapCandidate = session:captureCandidate()
  for _, key in ipairs({ "mapId", "fieldX", "fieldZ", "surfaceId", "worldY", "terrainDependencyHash" }) do
    Assert.equal(crossMapCandidate[key], crossMap[key], "the cross-map destination tuple stores " .. key)
  end
  Assert.isNil(crossMapCandidate.weatherId, "cross-map relocation clears old map weather")
  Assert.isNil(crossMapCandidate.audio.fieldMusicOverride, "cross-map relocation clears old map music")
  Assert.deepEqual(crossMapCandidate.world.rng, original.world.rng, "relocation preserves world RNG")
  Assert.deepEqual(crossMapCandidate.world.variables, original.world.variables, "relocation preserves variables")

  successful(session:setLocation(session:snapshot().originalLocation))
  Assert.deepEqual(session:captureCandidate(), stagedCandidate, "baseline selection restores location-owned state only")
  Assert.isTrue(session:isDirty(), "unrelated staged edits remain dirty after returning to the original location")
  Assert.isFalse(session:snapshot().dirtySections.location, "returning to the location baseline clears location dirtiness")

  successful(session:setMoney(4800))
  successful(session:setFlag("FLAG_HIDDENITEM_D42R0101_HYPER_POTION", false))
  successful(session:setBagQuantity("POTION", 2))
  successful(session:setLocation(crossMap))
  successful(session:save())
  local published = assert(fixture.store:load(fixture.saveId))
  Assert.deepEqual(published, session:captureCandidate(), "Save publishes the entire canonical candidate")
  successful(session:setLocation(sameMap))
  Assert.isTrue(session:isDirty(), "moving from the saved baseline is dirty")
  Assert.isTrue(session:discard(), "Discard restores the published destination")
  Assert.deepEqual(session:captureCandidate(), published, "Discard restores destination and unrelated domains")
end

return T
