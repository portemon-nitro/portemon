-- Focused presentation-test fixtures for the field Pokedex screen: compact
-- synthetic catalogs, a knowledge owner with mixed seen/caught history, a
-- real browser controller over that owner, and a synthetic detached
-- registration demand that exercises the registration drawing path and its
-- interface without a battle runtime. No renderer, GPU, audio device, ROM,
-- or worker is touched; the registration snapshot carries only detached
-- specimen facts the knowledge owner already describes.

local PokedexDexFixture = require("libs.hgss.tests.mons.pokedex_dex_fixture")
local PokedexKnowledge = require("libs.hgss.src.mons.PokedexKnowledge")

-- The immutable sampler behind every pooled Pokedex interest. Seeds use
-- this exact state so borrowed identities match the lease requests.
local POOLED_SAMPLER = { wrapX = "clamp", wrapY = "clamp", minFilter = "nearest", magFilter = "nearest" }

local PokedexPresentationFixture = {}

--- Builds the synthetic mon and generated catalogs the presentation legs
--- share: every policy family (genders, forms, Spinda, Unown, Giratina,
--- custom inside/outside keys) with explicit display and completion sets.
---@return table monCatalog resolved synthetic mon catalog
---@return table catalog synthetic generated dex catalog
function PokedexPresentationFixture.catalogs()
  return PokedexDexFixture.makeCatalog(), PokedexDexFixture.buildPokedexCatalog()
end

--- Builds a knowledge owner carrying mixed seen/caught history: Chikorita
--- and Eevee seen, Totodile and Spinda caught, with ownership
--- and international/form flags enabled so every page family has content.
---@param monCatalog table resolved synthetic mon catalog
---@param catalog table synthetic generated dex catalog
---@return table owner knowledge owner with staged history
function PokedexPresentationFixture.ownerWithHistory(monCatalog, catalog)
  local owner = PokedexKnowledge.new(PokedexDexFixture.refs(monCatalog, catalog))
  owner:prepareChanges({ flags = { dexEnabled = true, nationalDex = true } }):publish()
  local function observe(species, personality, kind)
    local specimen = owner:describe(PokedexDexFixture.makeMon(monCatalog, {
      species = species,
      personality = personality,
    }))
    owner:prepareChanges({ observations = { { kind = kind, specimen = specimen } } }):publish()
  end
  observe("CHIKORITA", 0, "seen")
  observe("EEVEE", 0, "seen")
  observe("TOTODILE", 0, "caught")
  observe("SPINDA", 16, "caught")
  return owner
end

--- Opens the real browser controller over synthetic catalogs and history.
---@param owner table knowledge owner under test
---@param monCatalog table resolved synthetic mon catalog
---@param catalog table synthetic generated dex catalog
---@return table controller live browser controller
function PokedexPresentationFixture.openController(owner, monCatalog, catalog)
  local PokedexController = require("game.hgss.src.pokedex.PokedexController")
  return PokedexController.new({
    catalog = catalog,
    monCatalog = monCatalog,
    dex = owner,
    playerGender = "male",
    playerPosition = { mapX = 10, mapY = 10 },
    nativeLanguage = "english",
  })
end

--- Advances the controller one fixed update with readiness matching its
--- current generation, so resource-gated motion is admitted.
---@param controller table browser under test
---@param events table|nil semantic batch for one fixed update
function PokedexPresentationFixture.tick(controller, events)
  controller:updateFixed(events or {}, { readyKey = controller:view().key })
end

--- Builds a synthetic detached first-catch snapshot: the display name and
--- dex mode the announcement formats, plus the actual caught specimen
--- facts described by the knowledge owner. No battle runtime or battle
--- state contributes; the record is frozen before any publication.
---@param owner table knowledge owner under test
---@param monCatalog table resolved synthetic mon catalog
---@param species string caught species key
---@param personality integer caught personality
---@return table snapshot detached registration facts
function PokedexPresentationFixture.registrationSnapshot(owner, monCatalog, species, personality)
  local specimen = owner:describe(PokedexDexFixture.makeMon(monCatalog, {
    species = species,
    personality = personality,
  }))
  assert(type(specimen.species) == "string", "the registration snapshot names its species")
  return {
    dexMode = "national",
    displayName = specimen.species,
    specimen = specimen,
  }
end

--- Builds the exact registration demand the resource owner prepares: one
--- fixed purpose, the registration page role, national numbering, native
--- UI language, no icon keys, one actual-specimen picture slot, and the
--- frozen snapshot as text with its cry identity.
--- Publishes one realized image as the physical pair behind a pooled
--- texture path, modelling worker-staged content the main thread
--- realized. The pool owns the image afterwards; prune reclaims it once
--- every lease returns.
---@param pool table shared image pool double under test
---@param path string logical texture path behind the identity
---@param image table<string, unknown> realized source image adopted as the physical pair
---@param kind "r8"|"rgba8"? payload representation, defaulting to straight RGBA
---@param palette table<string, unknown>? exact palette image, required for indexed seeds
function PokedexPresentationFixture.seedPhysical(pool, path, image, kind, palette)
  pool:seedPhysical(path, POOLED_SAMPLER, {
    image = image,
    kind = kind or "rgba8",
    palette = palette,
    width = image:getWidth(),
    height = image:getHeight(),
  })
end

---@param snapshot table detached registration facts from registrationSnapshot
---@param key string|nil resource generation key for the demand
---@return table demand immutable registration demand
function PokedexPresentationFixture.registrationDemand(snapshot, key)
  return {
    key = key or "registration-generation",
    purpose = "registration",
    pageRole = "registration",
    dexMode = snapshot.dexMode,
    language = "native",
    iconKeys = {},
    pictures = {
      {
        slot = "registration",
        specimen = snapshot.specimen,
        facing = "front",
        mode = "registration",
      },
    },
    text = { registration = snapshot },
    cry = { species = snapshot.specimen.species, form = 0 },
  }
end

return PokedexPresentationFixture
