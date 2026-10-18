-- Producer-only source selectors for the HGSS Pokedex family: archive
-- paths, bounded member layouts, measurement/profile mapping, search and
-- area mask semantics, form policies, completion exclusions, height
-- correction selectors, and fixed text roles. Native identities stop here;
-- runtime game code never requires this module.

local PokedexSources = {}

PokedexSources.provenance = {
  decompRevision = "ctrl-cheeb-del/pokeheartgold@9776a7c03160841e967d90a2a3c6d4e5e5b9f2",
  symbols = {
    "filesystem.mk",
    "include/constants/filesystem_files_def.h",
    "src/application/pokedex/pokedex_screen_setup.c",
    "src/application/pokedex/pokedex_sprites.c",
    "src/application/pokedex/pokedex_windows.c",
    "src/dex_mon_measures.c",
    "src/application/pokedex/pokedex_text_util.c",
    "src/pokemon.c",
    "src/application/pokedex/pokedex_app.c",
  },
}

PokedexSources.versions = { heartgold = true, soulsilver = true }

-- Native application/data source archives with their verified HG member
-- counts. Physical file IDs are evidence anchors, not runtime arithmetic.
PokedexSources.archives = {
  graphics = { path = "a/0/6/8", memberCount = 123 },
  footprints = { path = "a/0/6/9", memberCount = 497 },
  measuresOrigin = { path = "a/0/7/4", memberCount = 102 },
  measuresBase = { path = "a/2/1/4", memberCount = 102 },
  slider = { path = "a/0/7/5", memberCount = 2 },
  habitat = { path = "a/1/3/3", memberCount = 3962 },
  johtoInverse = { path = "a/1/3/8", memberCount = 1 },
  portraitY = { path = "a/0/0/5", memberCount = 1976 },
  portraitYAlt = { path = "a/1/1/7", memberCount = 160 },
}

-- Numeric Giratina mapping: file 343 (a/2/1/4) is the base profile
-- (45dm/7500hg), file 203 (a/0/7/4) is the origin profile (69dm/6500hg).
-- The application chooses one profile per open; the mislabeled decomp
-- branch name never overrides the observed numeric selector.
PokedexSources.measureProfiles = { base = "a/2/1/4", giratina_origin = "a/0/7/4" }

PokedexSources.sliderRows = 153
PokedexSources.speciesSlots = 494
PokedexSources.areaSlots = 495

-- Zero-based NARC member ids of the habitat encounter lists for species
-- slot S (0..494): dungeon morning/day/night, outdoor morning/day/night,
-- dungeon other, outdoor other. List values are 1-based area ids with a
-- zero terminator; slot 0 is the show-everything row, slot 494 is unused.
PokedexSources.habitatBases = { 2, 497, 992, 1487, 1982, 2477, 2972, 3467 }

-- Search mask bits of file 204 member 1 (one byte per species slot).
PokedexSources.maskBits = {
  johto = 0x02,
  kanto = 0x04,
  unknown = 0x10,
  unrestricted = 0x80,
}

-- Type lists of file 203/343 members 62..78 in source order (mystery has
-- no list). Positions are zero-based member offsets from member 62.
PokedexSources.typeOrder = {
  "normal",
  "fighting",
  "flying",
  "poison",
  "ground",
  "rock",
  "bug",
  "ghost",
  "steel",
  "fire",
  "water",
  "grass",
  "electric",
  "psychic",
  "ice",
  "dragon",
  "dark",
}

-- Body-shape lists of members 79..92 in source order.
PokedexSources.shapeOrder = {
  "quadruped",
  "bipedal without tail",
  "bipedal with tail",
  "serpentine",
  "multiple wings",
  "two wings",
  "insectoid",
  "head/torso",
  "head/arms",
  "head/legs",
  "tentacles",
  "fins",
  "head only",
  "multiple bodies",
}

-- Letter lists of members 18..43 (A..Z) in source order.
PokedexSources.letterOrder = {
  "a",
  "b",
  "c",
  "d",
  "e",
  "f",
  "g",
  "h",
  "i",
  "j",
  "k",
  "l",
  "m",
  "n",
  "o",
  "p",
  "q",
  "r",
  "s",
  "t",
  "u",
  "v",
  "w",
  "x",
  "y",
  "z",
}

-- Exact vanilla completion exclusions (event mythicals): national order
-- minus these nine is the 484 requirement set; johto order minus Mew and
-- Celebi is the 254 requirement set.
PokedexSources.completionExclusions = {
  national = { "MEW", "CELEBI", "JIRACHI", "DEOXYS", "PHIONE", "MANAPHY", "DARKRAI", "SHAYMIN", "ARCEUS" },
  johto = { "MEW", "CELEBI" },
}

-- Native ordered form families (fixed logical variant IDs). Unown alone
-- persists caught variants; Spinda alone persists its first personality.
-- Pichu carries three fixed gender/form variants; additional forms use
-- ID = form + 1 so unrelated additions never renumber saved variants.
PokedexSources.orderedPolicies = {
  UNOWN = { capacity = 28, rememberCaughtVariants = true },
  SPINDA = { capacity = 1, rememberFirstPersonality = true },
  DEOXYS = { capacity = 4 },
  BURMY = { capacity = 3 },
  WORMADAM = { capacity = 3 },
  SHELLOS = { capacity = 2 },
  GASTRODON = { capacity = 2 },
  GIRATINA = { capacity = 2 },
  SHAYMIN = { capacity = 2 },
  ROTOM = { capacity = 6 },
  PICHU = { capacity = 2, gendered = true },
}

-- Native automatic families expose every declared variant once seen and
-- persist no automatic form history.
PokedexSources.automaticFamilies = { CASTFORM = true, CHERRIM = true }

-- Fixed Pichu gender/form variants: normal male, normal female, then the
-- spiky form. Additional forms use ID = form + 1.
PokedexSources.pichuVariants = {
  { id = 0, form = 0, gender = "male" },
  { id = 1, form = 0, gender = "female" },
  { id = 2, form = 1 },
}

-- Ordinary portrait Y member in a/0/0/5 for a species, facing (0 back,
-- 2 front), and image gender: 4*S + facing + (female and 0 or 1).
---@param speciesId integer
---@param facing integer
---@param female boolean
---@return integer
function PokedexSources.ordinaryHeightMember(speciesId, facing, female)
  return 4 * speciesId + facing + (female and 0 or 1)
end

-- Alternate portrait Y members in a/1/1/7. Each entry names the native
-- form range the alternate branch covers; forms outside the native range
-- fall back to the ordinary member. Facing is 0 (back) or 2 (front).
PokedexSources.altHeightFamilies = {
  DEOXYS = { base = 0, halfFacing = true, stride = 2, forms = 4 },
  UNOWN = { base = 0x08, halfFacing = true, stride = 2, forms = 28 },
  CASTFORM = { base = 0x40, doubleFacing = true, stride = 1, forms = 4 },
  BURMY = { base = 0x48, halfFacing = true, stride = 2, forms = 3 },
  WORMADAM = { base = 0x4E, halfFacing = true, stride = 2, forms = 3 },
  SHELLOS = { base = 0x54, stride = 1, forms = 2 },
  GASTRODON = { base = 0x58, stride = 1, forms = 2 },
  CHERRIM = { base = 0x5C, stride = 1, forms = 2 },
  ARCEUS = { base = 0x60, halfFacing = true, stride = 2, forms = 18 },
  SHAYMIN = { base = 0x88, halfFacing = true, stride = 2, forms = 2 },
  ROTOM = { base = 0x8C, halfFacing = true, stride = 2, forms = 6 },
  GIRATINA = { base = 0x98, halfFacing = true, stride = 2, forms = 2 },
  PICHU = { base = 0x9C, halfFacing = true, stride = 2, forms = 2 },
}

---@param speciesKey string
---@param form integer
---@param facing integer
---@return integer?
function PokedexSources.altHeightMember(speciesKey, form, facing)
  local family = PokedexSources.altHeightFamilies[speciesKey]
  if family == nil then
    return nil
  end
  if form < 0 or form >= family.forms then
    return nil
  end
  if family.halfFacing then
    return family.base + math.floor(facing / 2) + family.stride * form
  end
  if family.doubleFacing then
    return family.base + 2 * facing + family.stride * form
  end
  return family.base + facing + family.stride * form
end

-- Fixed message roles. The native flavor bank follows the game version;
-- every other role is version-independent.
---@param versionId string
---@return table<string, unknown>
function PokedexSources.textBindings(versionId)
  assert(PokedexSources.versions[versionId], "pokedex text bindings need a supported version")
  return {
    ui = { bankId = 802 },
    entryByLanguage = {
      native = {
        nameBankId = 237,
        categoryBankId = 816,
        flavorBankId = versionId == "heartgold" and 803 or 804,
      },
      japanese = { nameBankId = 822, categoryBankId = 828, flavorBankId = 810 },
      english = { nameBankId = 817, categoryBankId = 823, flavorBankId = 805 },
      french = { nameBankId = 818, categoryBankId = 824, flavorBankId = 806 },
      german = { nameBankId = 819, categoryBankId = 825, flavorBankId = 807 },
      italian = { nameBankId = 820, categoryBankId = 826, flavorBankId = 808 },
      spanish = { nameBankId = 821, categoryBankId = 827, flavorBankId = 809 },
    },
    measureByProfile = {
      base = { heightBankId = 815, weightBankId = 813 },
      giratina_origin = { heightBankId = 814, weightBankId = 812 },
    },
    registrationAnnouncement = { bankId = 197, messageId = 871 },
  }
end

-- Message banks the presentation scope depends on: every bank named by the
-- fixed text roles for both versions.
-- Message banks the presentation scope waits for. The fixed text roles
-- name every language bank, but the three Japanese entry banks cannot
-- compile against the frozen reference charmap (MESSAGE_GLYPH_UNMAPPED
-- for their control codes), a pre-existing toolchain gap unrelated to
-- this family. The presentation job therefore waits for the buildable
-- closure; the catalog still binds every language and the gap is
-- reported as a blocked capability for Japanese-locale text.
PokedexSources.unbuildableMessageBanks = { [810] = true, [822] = true, [828] = true }

---@return integer[]
function PokedexSources.messageBankIds()
  local seen, ids = {}, {}
  for _, versionId in ipairs({ "heartgold", "soulsilver" }) do
    local bindings = PokedexSources.textBindings(versionId)
    local banks = { bindings.ui.bankId }
    for _, entry in pairs(bindings.entryByLanguage) do
      banks[#banks + 1] = entry.nameBankId
      banks[#banks + 1] = entry.categoryBankId
      banks[#banks + 1] = entry.flavorBankId
    end
    for _, entry in pairs(bindings.measureByProfile) do
      banks[#banks + 1] = entry.heightBankId
      banks[#banks + 1] = entry.weightBankId
    end
    banks[#banks + 1] = bindings.registrationAnnouncement.bankId
    for _, bankId in ipairs(banks) do
      if not seen[bankId] then
        seen[bankId] = true
        ids[#ids + 1] = bankId
      end
    end
  end
  table.sort(ids)
  return ids
end

return PokedexSources
