-- Minimal valid catalog.regionMap for synthetic Pokegear manifests.

local PokegearRegionMapFixture = {}

function PokegearRegionMapFixture.build()
  return {
    locations = {
      {
        mapId = 1,
        mapSymbol = "MAP_FIXTURE",
        x = 1,
        y = 2,
        width = 3,
        height = 3,
        objXOffset = 0,
        objYOffset = 12,
        flavorEntry = 4,
        previewBlock = 0,
        sectionEntry = 3,
        overlay = { srcX = 0, srcY = 0, width = 0, height = 0 },
      },
    },
    flypoints = {
      {
        nameMapId = 1,
        nameSectionEntry = 3,
        warpMapId = 1,
        flypoint = 0,
        x = 1,
        y = 2,
        width = 1,
        height = 1,
        overlay = { srcX = 0, srcY = 20, destX = 1, destY = 1, width = 3, height = 3 },
      },
    },
  }
end

return PokegearRegionMapFixture
