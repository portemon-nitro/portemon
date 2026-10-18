-- Source-only member selection for the generated HGSS field-entry class: the
-- nine map-name banner skins in the areawindow archive and the pinned
-- destination/time selection over the ordered location-preview archive. The
-- 25 destination rows transcribe the retail ROM's map preview graphic table; the preview archive is ordered as contiguous
-- triples (NCLR member `base`, NCGR member `base + 1`, NSCR member
-- `base + 2`). The banner skins follow the retail ROM's area icon loader:
-- char member `2 * style` and palette member `2 * style + 1`, composed into a
-- 17x4 grid from source tiles 1..68. Every archive alias and member number
-- lives here and in the compiler dependencies; the generated manifest never
-- carries them. Member numbers are zero-based per the repository convention.
local MapCatalog = require("romdump.src.digest.map.MapCatalog")

local FieldEntrySources = {}

FieldEntrySources.provenance = {
  repo = "retail ROM",
  sources = {
    "src/field/draw_map_name.c",
    "src/map_preview_graphic.c",
    "files/fielddata/graphic/preview_graphic/preview_graphic.order",
  },
}

-- The four native time slots in selection order; a destination whose evening
-- base equals its day base aliases the daytime graphic.
FieldEntrySources.SLOTS = { "morning", "day", "evening", "night" }

-- The nine areawindow banner skins (styles 0..8).
FieldEntrySources.BANNER_STYLE_COUNT = 9

-- Curated archive aliases; the compiler opens these through the source reader.
FieldEntrySources.AREA_WINDOWS_ALIAS = "field_area_windows"
FieldEntrySources.PREVIEWS_ALIAS = "field_map_previews"

-- Destination source symbol -> one zero-based preview base per time slot.
---@type { symbol: string, bases: integer[] }[]
FieldEntrySources.DESTINATIONS = {
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

-- Banner skin `style` reads its char/palette members from the areawindow
-- archive. Zero-based member numbers.
---@param style integer
---@return integer charMemberId
---@return integer paletteMemberId
function FieldEntrySources.bannerMemberIds(style)
  assert(
    type(style) == "number" and style % 1 == 0 and style >= 0 and style < FieldEntrySources.BANNER_STYLE_COUNT,
    "banner style is out of range"
  )
  return style * 2, style * 2 + 1
end

-- Every distinct preview triple base referenced by the selector, ascending.
-- The archive orders its 228 members as contiguous NCLR/NCGR/NSCR triples, so
-- the selected bases must be exactly 0, 3, 6, ... with no gaps: a missing or
-- unexpected group is a source-selection defect, never a smaller asset set.
---@return integer[]
function FieldEntrySources.uniqueBases()
  local seen = {}
  for _, destination in ipairs(FieldEntrySources.DESTINATIONS) do
    for _, base in ipairs(destination.bases) do
      seen[base] = true
    end
  end
  local bases = {}
  for base in pairs(seen) do
    bases[#bases + 1] = base
  end
  table.sort(bases)
  for position, base in ipairs(bases) do
    assert(
      base == (position - 1) * 3,
      "field-entry preview bases must be contiguous source triples: " .. tostring(base)
    )
  end
  return bases
end

local function validate()
  local seenSymbols = {}
  for _, destination in ipairs(FieldEntrySources.DESTINATIONS) do
    assert(
      not seenSymbols[destination.symbol],
      "duplicate field-entry destination: " .. destination.symbol
    )
    seenSymbols[destination.symbol] = true
    MapCatalog.require(destination.symbol)
    assert(
      #destination.bases == #FieldEntrySources.SLOTS,
      "destination " .. destination.symbol .. " must carry one base per time slot"
    )
    for slot, base in ipairs(destination.bases) do
      assert(
        type(base) == "number" and base % 1 == 0 and base >= 0,
        "destination " .. destination.symbol .. " slot " .. slot .. " base is invalid"
      )
    end
  end
  FieldEntrySources.uniqueBases()
end

validate()

return FieldEntrySources
