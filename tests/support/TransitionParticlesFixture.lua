-- Synthetic Elite Four intro particle sets in the shape the battle transition
-- stages: compiled emitter records plus RGBA texture pixels under the set's
-- seed. Every emitter is the plain terrain-grass emitter of the encounter
-- fixture with its own id, so the sets replay through the real simulation.

local BattleEncounterParticlesFixture = require("tests.support.BattleEncounterParticlesFixture")

local Fixture = {}

---@param emitterCount integer emitters the set declares
---@return table<string, unknown> staged particle set
function Fixture.set(emitterCount)
  local template = BattleEncounterParticlesFixture.sets("transition")[1].emitters[1]
  local emitters = {}
  for index = 1, emitterCount do
    local record = {}
    for key, value in pairs(template) do
      record[key] = value
    end
    record.id = index - 1
    record.textureImage = nil
    emitters[index] = record
  end
  return {
    seed = 0,
    emitters = emitters,
    textures = { { id = 0, width = 2, height = 2, pixels = string.rep("\255", 16) } },
  }
end

-- The staged resources of the intro and follow-up members.
---@return table<string, unknown> intro, table<string, unknown> followup
function Fixture.pair()
  return Fixture.set(3), Fixture.set(4)
end

return Fixture
