-- Pinned retail location-preview source selectors for the generated
-- field-entry class. The rows transcribe pret/pokeheartgold
-- src/map_preview_graphic.c `sMapPreviewGraphicData` and
-- files/fielddata/graphic/preview_graphic/preview_graphic.order at commit
-- d2355244ac42b3c6e40d8c36aa3564ee8706dea4. Each base is a zero-based NCLR
-- member id; the companion NCGR and NSCR members follow at base+1 and base+2.
-- Slot order is morning, day, evening, night. A map whose evening base equals
-- its day base aliases the daytime graphic.

local FieldEntryFixture = {}

FieldEntryFixture.SLOTS = { "morning", "day", "evening", "night" }

---@type { symbol: string, bases: integer[] }[]
FieldEntryFixture.DESTINATIONS = {
  { symbol = "MAP_DARK_CAVE_ROUTE_45_SIDE", bases = { 0, 3, 3, 6 } },
  { symbol = "MAP_DARK_CAVE_ROUTE_31_SIDE", bases = { 9, 12, 12, 15 } },
  { symbol = "MAP_SPROUT_TOWER_1F", bases = { 18, 21, 21, 24 } },
  { symbol = "MAP_RUINS_OF_ALPH_HALL_ENTRANCE", bases = { 27, 30, 30, 33 } },
  { symbol = "MAP_RUINS_OF_ALPH_HALL_ENTRANCE_SINJOH_EVENT", bases = { 27, 30, 30, 33 } },
  { symbol = "MAP_UNION_CAVE_1F", bases = { 36, 39, 39, 42 } },
  { symbol = "MAP_SLOWPOKE_WELL_ENTRANCE", bases = { 45, 48, 48, 51 } },
  { symbol = "MAP_ILEX_FOREST", bases = { 54, 57, 60, 63 } },
  { symbol = "MAP_NATIONAL_PARK", bases = { 66, 69, 72, 75 } },
  { symbol = "MAP_BURNED_TOWER_1F", bases = { 78, 81, 84, 87 } },
  { symbol = "MAP_BELL_TOWER_1F", bases = { 90, 93, 96, 99 } },
  { symbol = "MAP_WHIRL_ISLANDS_1F", bases = { 102, 105, 105, 108 } },
  { symbol = "MAP_MOUNT_MORTAR_1F_ENTRANCE", bases = { 111, 114, 117, 120 } },
  { symbol = "MAP_ICE_PATH_1F", bases = { 123, 126, 126, 129 } },
  { symbol = "MAP_DRAGONS_DEN_ENTRANCE", bases = { 132, 135, 135, 138 } },
  { symbol = "MAP_TOHJO_FALLS", bases = { 141, 144, 144, 147 } },
  { symbol = "MAP_VICTORY_ROAD_1F", bases = { 150, 153, 153, 156 } },
  { symbol = "MAP_VICTORY_ROAD_3F", bases = { 150, 153, 153, 156 } },
  { symbol = "MAP_VIRIDIAN_FOREST", bases = { 159, 162, 165, 168 } },
  { symbol = "MAP_DIGLETT_CAVE", bases = { 171, 174, 174, 177 } },
  { symbol = "MAP_ROCK_TUNNEL_1F", bases = { 180, 183, 183, 186 } },
  { symbol = "MAP_MOUNT_MOON", bases = { 189, 192, 195, 198 } },
  { symbol = "MAP_SEAFOAM_ISLANDS_1F", bases = { 201, 204, 204, 207 } },
  { symbol = "MAP_MOUNT_SILVER_CAVE_1F", bases = { 210, 213, 213, 216 } },
  { symbol = "MAP_CERULEAN_CAVE_1F", bases = { 219, 222, 222, 225 } },
}

-- Every distinct source triple base referenced by the table, ascending. The
-- archive carries one NCLR/NCGR/NSCR group per base (76 groups in 228 members).
---@return integer[]
function FieldEntryFixture.uniqueBases()
  local seen = {}
  for _, destination in ipairs(FieldEntryFixture.DESTINATIONS) do
    for _, base in ipairs(destination.bases) do
      seen[base] = true
    end
  end
  local bases = {}
  for base in pairs(seen) do
    bases[#bases + 1] = base
  end
  table.sort(bases)
  return bases
end

-- The nine areawindow banner members: char member 2*i and palette member
-- 2*i+1 for i = 0..8 (pret/pokeheartgold src/field/draw_map_name.c
-- LoadAreaIconGraphics). The banner composes source tiles 1..68 as a 17x4
-- grid, so each char member carries at least 69 tiles.
FieldEntryFixture.BANNER_STYLE_COUNT = 9

-- Raw BG map entries (tile | flipH<<10 | flipV<<11 | palette<<12) for the
-- 17x4 banner grid: entry k addresses source tile k+1 in palette bank 0.
---@return integer[]
function FieldEntryFixture.bannerEntries()
  local entries = {}
  for k = 0, 67 do
    entries[k + 1] = k + 1
  end
  return entries
end

return FieldEntryFixture
