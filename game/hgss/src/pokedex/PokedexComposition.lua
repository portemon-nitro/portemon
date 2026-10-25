-- The sole ordinary field Pokedex factory: borrows the composed services,
-- snapshots the native language, player gender, and resolved map cell,
-- constructs the browser policy over the authoritative knowledge, acquires the
-- late-bound browser lease, and builds the per-open screen. Only the
-- controller, screen, and lease are newly owned; audio stays optional in
-- the same headless sense as the existing summary closure. Construction
-- is exception safe: a failed open releases what it acquired and raises
-- the real cause before host input is captured.

local MapProjection = require("game.hgss.src.pokegear.MapProjection")
local PokedexController = require("game.hgss.src.pokedex.PokedexController")
local PokedexScreenState = require("game.hgss.src.pokedex.PokedexScreenState")

---@class PokedexComposition
local PokedexComposition = {}

-- Resolves the player position once per open through the existing
-- authority: the read-only Pokégear context closure over the live map,
-- converted through the existing projection. Never derives the marker
-- from local player coordinates and never caches exterior state here.
---@param runtime table<string, unknown> the owning field runtime
---@return { mapX: integer, mapY: integer } captured global block cell
local function resolvePlayerCell(runtime)
  local pokegear = assert(runtime.pokegear, "the pokedex factory borrows the composed companion feature")
  assert(type(pokegear.mapContext) == "function", "the pokedex factory reads the shared player-location authority")
  local facts = pokegear.mapContext()
  assert(type(facts) == "table", "the shared map context resolves its location facts afresh")
  local cellInput = {}
  for key, value in pairs(facts) do
    cellInput[key] = value
  end
  if cellInput.special == nil and cellInput.specialMode ~= nil then
    cellInput.special = cellInput.specialMode
  end
  local cell = MapProjection.contextCell(cellInput)
  assert(
    type(cell.x) == "number" and type(cell.y) == "number",
    "the existing projection resolves numeric block coordinates"
  )
  return { mapX = cell.x, mapY = cell.y }
end

---@param runtime table<string, unknown> the owning field runtime
---@return table<string, unknown> the complete usable field pokedex screen
function PokedexComposition.open(runtime)
  assert(type(runtime) == "table", "the pokedex factory needs its owning runtime")
  local dex = assert(runtime.dexKnowledge, "the pokedex factory borrows the composed dex knowledge")
  local catalog = assert(runtime.pokedexCatalog, "the pokedex factory borrows the generated dex catalog")
  assert(type(catalog) == "table", "the generated dex catalog stays a record")
  local monCatalog = assert(runtime.monCatalog, "the pokedex factory borrows the resolved mon catalog")
  local nativeLanguage = assert(catalog.nativeLanguage, "the pokedex factory reads the catalog native language")
  assert(
    type(nativeLanguage) == "string" and nativeLanguage ~= "",
    "the pokedex factory needs a nonempty native language"
  )
  local playerData = assert(runtime.playerData, "the pokedex factory reads the validated player profile")
  local profile = assert(playerData.profile, "the pokedex factory reads the validated player profile")
  local playerGender = ({ [0] = "male", [1] = "female" })[profile.gender]
  assert(playerGender == "male" or playerGender == "female", "the pokedex factory needs a known player gender")
  local playerName = profile.name
  assert(type(playerName) == "string" and playerName ~= "", "the pokedex factory needs the player name")
  local cell = resolvePlayerCell(runtime)
  local controller = PokedexController.new({
    catalog = catalog,
    monCatalog = monCatalog,
    dex = dex,
    playerGender = playerGender,
    playerPosition = cell,
    playerName = playerName,
    nativeLanguage = nativeLanguage,
  })
  local binding = runtime._pokedexPreparation
  if type(binding) ~= "table" or type(binding.acquire) ~= "function" then
    controller:dispose()
    error("pokedex opens require the bound preparation seam", 0)
  end
  local okLease, lease = pcall(binding.acquire, { purpose = "browser" })
  if not okLease then
    controller:dispose()
    error(lease, 0)
  end
  assert(type(lease) == "table", "the preparation binding acquires a per-open lease")
  local function measureDisplay()
    return assert(runtime.presentationDisplay, "the pokedex screen measures its display")
  end
  local function playSequence(sequence)
    if runtime.audio ~= nil then
      runtime.audio:play(sequence)
    end
  end
  local function playCry(species, pattern, form)
    local audio = runtime.audio
    if audio == nil then
      return
    end
    local speciesOf = monCatalog.species
    assert(type(speciesOf) == "function", "the cry closure reads the resolved mon catalog")
    local record = speciesOf(monCatalog, species)
    assert(type(record) == "table" and type(record.nativeId) == "number", "cries resolve their numeric identity")
    local CryPlayer = require("libs.hgss.src.audio.CryPlayer")
    audio:playCry(CryPlayer.bankFor(record.nativeId, form), pattern, form)
  end
  local function commitResume(resume)
    local candidate = dex:prepareChanges({ resume = resume })
    if candidate:isCurrent() then
      candidate:publish()
      return true
    end
    return false
  end
  -- Retail opens the dex under scene 54 with no new BGM sequence: the
  -- field BGM keeps playing while its player ducks to 42, restored to
  -- 127 on exit (Pokedex_Init/Pokedex_Exit through
  -- GF_SndHandleSetPlayerVolume). The facade has no secondary-scene or
  -- player-volume spelling, so the closest sink moves the still-current
  -- BGM through the unified fader for a single frame; silence or a
  -- headless music service skips the move. The sink reports whether it
  -- moved a sequence and remembers the ducked sequence so the matching
  -- restore never retargets a replacement track.
  local duckedSequence = nil
  local function duckOrRestoreMusic(action)
    local audio = runtime.audio
    if audio == nil then
      return false
    end
    if type(audio.currentMusic) ~= "function" or type(audio.moveSequenceVolume) ~= "function" then
      return false
    end
    if action == "duck" then
      local current = audio:currentMusic()
      if current == nil then
        return false
      end
      audio:moveSequenceVolume(current, 42, 1)
      duckedSequence = current
      return true
    elseif action == "restore" then
      if duckedSequence == nil then
        return false
      end
      local current = audio:currentMusic()
      if current ~= duckedSequence then
        duckedSequence = nil
        return false
      end
      audio:moveSequenceVolume(duckedSequence, 127, 1)
      duckedSequence = nil
      return true
    end
    return false
  end
  local overrides = runtime.presentationOverrides
  local pokedexOverrides = nil
  if type(overrides) == "table" then
    pokedexOverrides = overrides.pokedex
  end
  local okScreen, screen = pcall(PokedexScreenState.new, {
    controller = controller,
    lease = lease,
    measureDisplay = measureDisplay,
    effect = playSequence,
    playCry = playCry,
    commitResume = commitResume,
    music = duckOrRestoreMusic,
    overrides = pokedexOverrides,
  })
  if not okScreen then
    local okRelease, releaseFailure = pcall(lease.release, lease)
    controller:dispose()
    if not okRelease then
      error(tostring(screen) .. "; lease release failed: " .. tostring(releaseFailure), 0)
    end
    error(screen, 0)
  end
  return screen
end

return PokedexComposition
