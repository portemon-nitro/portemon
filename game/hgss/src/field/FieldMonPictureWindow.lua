-- The source field Pokémon picture window behind Screen 452/453
-- (src/scrcmd_c.c::ScrCmd_ShowPokemonPicWindow / ScrCmd_ClosePokemonPicWindow):
-- the scene names a species and the gender whose picture it wants, the window
-- shows that species' canonical portrait, records the species as seen through
-- the one dex owner, and stays open until the scene closes it. The window owns
-- only its open identity and the sighting it publishes; the picture pixels are
-- leased from the presentation owner (MonCache portrait pages) and drawn by
-- the field renderer at the source's own MAIN-layer tile. Pure state module:
-- no love dependency.

local Errors = require("libs.errors.src.Errors")
local MonCache = require("libs.assets.src.MonCache")

---@class FieldMonPictureWindow
---@field private _portraits table<string, unknown> the validated portrait manifest
---@field private _speciesKeyByNativeId fun(nativeId: integer): string?
---@field private _markSeen fun(species: string): boolean
---@field private _open table<string, unknown>?
local FieldMonPictureWindow = {}
FieldMonPictureWindow.__index = FieldMonPictureWindow

-- The source draws the species picture on the main layer's third background at
-- (10, 5) in 8-pixel field tiles.
FieldMonPictureWindow.SOURCE_TILE_X = 10
FieldMonPictureWindow.SOURCE_TILE_Y = 5
FieldMonPictureWindow.TILE_PIXELS = 8

---@class FieldMonPictureWindow.Options
---@field portraits table<string, unknown> validated portrait manifest (selector -> page and frames)
---@field speciesKeyByNativeId fun(nativeId: integer): string?
---@field markSeen fun(species: string): boolean the canonical dex sighting receipt

---@param options FieldMonPictureWindow.Options
---@return FieldMonPictureWindow
function FieldMonPictureWindow.new(options)
  assert(type(options) == "table", "the picture window needs its collaborators")
  assert(type(options.portraits) == "table", "the picture window borrows the portrait manifest")
  assert(type(options.speciesKeyByNativeId) == "function", "the picture window resolves source species numbers")
  assert(type(options.markSeen) == "function", "the picture window records the shown species as seen")
  return setmetatable({
    _portraits = options.portraits,
    _speciesKeyByNativeId = options.speciesKeyByNativeId,
    _markSeen = options.markSeen,
    _open = nil,
  }, FieldMonPictureWindow)
end

-- The source gender selector: 0 shows the male picture and 1 the female one.
---@param gender unknown
---@return "male"|"female"
local function genderName(gender)
  if gender == 0 then
    return "male"
  end
  if gender == 1 then
    return "female"
  end
  Errors.raise("SCRIPT_INVALID_REFERENCE", "the picture window names a known gender selector", { gender = gender })
  error("unreachable after picture gender error")
end

-- Shows the named species' picture and publishes its sighting. The species
-- operand is the source's own species number; an unknown number or a species
-- whose portrait the generated family lacks fails loudly instead of drawing a
-- substitute.
---@param args { species: unknown, gender: unknown }
---@return table<string, unknown> the open window record
function FieldMonPictureWindow:show(args)
  assert(type(args) == "table", "the picture window shows one authored picture")
  local speciesKey = args.species
  if type(speciesKey) == "number" then
    speciesKey = self._speciesKeyByNativeId(args.species --[[@as integer]])
  end
  if type(speciesKey) ~= "string" or speciesKey == "" then
    Errors.raise("SCRIPT_INVALID_REFERENCE", "the picture window names a known species", { species = args.species })
  end
  assert(type(speciesKey) == "string", "the picture window resolves its species")
  local gender = genderName(args.gender)
  local selector = MonCache.portraitSelector(speciesKey, 0, gender, false)
  local entry = self._portraits.entries
  assert(type(entry) == "table", "the portrait manifest carries its selectors")
  local portrait = entry[selector]
  if type(portrait) ~= "table" then
    Errors.raise(
      "SCRIPT_INVALID_REFERENCE",
      "the picture window has no generated picture for " .. selector,
      { species = speciesKey, selector = selector }
    )
  end
  assert(type(portrait) == "table", "picture selectors carry their page entry")
  local frames = portrait.frames
  assert(type(frames) == "table" and type(frames[1]) == "table", "picture selectors carry their frames")
  local frame = frames[1] --[[@as table<string, unknown>]]
  assert(self._markSeen(speciesKey) == true, "the picture window publishes its sighting")
  self._open = {
    species = speciesKey,
    gender = gender,
    selector = selector,
    pageId = assert(portrait.pageId, "picture selectors carry their generated page"),
    frame = { x = frame.x, y = frame.y, width = frame.width, height = frame.height },
  }
  return self:status()
end

-- Closes the open picture. Closing an already-closed window is the source's
-- own no-op: the scene closes the window it opened exactly once.
function FieldMonPictureWindow:close()
  self._open = nil
end

---@return table<string, unknown>? the open window record, nil while closed
function FieldMonPictureWindow:status()
  local open = self._open
  if open == nil then
    return nil
  end
  return {
    species = open.species,
    gender = open.gender,
    selector = open.selector,
    pageId = open.pageId,
    frame = open.frame,
  }
end

return FieldMonPictureWindow
