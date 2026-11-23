-- The follower species of the walking pair pool, in pair order. Catalogs and
-- manifests built by tests stage exactly these followers, derived from the
-- pair map itself, so no fixture restates a follower list its producer owns.

local StartupAssetCache = require("libs.assets.src.StartupAssetCache")

local WalkingPoolFixture = {}

---@return integer[] follower species in pair order
function WalkingPoolFixture.followerSpeciesIds()
  local seen, species = {}, {}
  for pairIndex = 1, StartupAssetCache.walkerPairCount() do
    local speciesId = StartupAssetCache.walkerChoice(pairIndex).followerSpeciesId
    if seen[speciesId] == nil then
      seen[speciesId] = true
      species[#species + 1] = speciesId
    end
  end
  return species
end

return WalkingPoolFixture
