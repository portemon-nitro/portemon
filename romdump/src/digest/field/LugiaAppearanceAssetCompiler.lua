-- Compiles the source eye-glimmer and Lugia models for the Whirl Islands
-- reveal cutscene. The eye glimmer lives in the shared legend archive; the
-- single-shot Lugia cinematic lives in its own LZ11-compressed archive.

local LegendAppearanceCompiler = require("romdump.src.digest.field.LegendAppearanceCompiler")

local Compiler = {}
local ARCHIVE = "NARC_demo_legend"
local CINEMATIC_ARCHIVE = "NARC_a_2_4_4"
local MODELS = {
  {
    id = "eyeGlimmer",
    memberId = 28,
    animations = {
      { memberId = 29, format = "NSBMA", id = "eye.color", category = "material", kind = "color" },
      { memberId = 30, format = "NSBTP", id = "eye.pattern", category = "material", kind = "pattern" },
      { memberId = 31, format = "NSBCA", id = "eye.joint", category = "joint", kind = "trs" },
    },
  },
  {
    id = "cinematic.lugia.0",
    memberId = 0,
    cinematic = true,
    animations = {
      { memberId = 1, format = "NSBCA", id = "lugia.joint", category = "joint", kind = "trs" },
      { memberId = 2, format = "NSBMA", id = "lugia.color", category = "material", kind = "color" },
      { memberId = 3, format = "NSBTA", id = "lugia.srt", category = "material", kind = "texsrt" },
      { memberId = 4, format = "NSBTP", id = "lugia.pattern", category = "material", kind = "pattern" },
    },
  },
  {
    id = "cinematic.lugia.1",
    memberId = 5,
    cinematic = true,
    -- Retail loads the far model with its material colors disabled (see
    -- gLugiaCinematicModels noMaterialColors): it draws unlit.
    noMaterialColors = true,
    animations = {
      { memberId = 6, format = "NSBCA", id = "lugia.far.joint", category = "joint", kind = "trs" },
    },
  },
}

function Compiler.compile(romFs)
  assert(romFs and romFs.openNarc, "Lugia appearance compiler requires RomFs")
  local models, meshes, textures, hashes = LegendAppearanceCompiler.compileModels(romFs, {
    archive = ARCHIVE,
    cinematicArchive = CINEMATIC_ARCHIVE,
    label = "Lugia",
    role = "field-effect-lugia-appearance",
    keyPrefix = "field-effect:lugia-appearance:",
    models = MODELS,
  })
  return {
    definition = { models = models },
    meshes = meshes,
    textures = textures,
    memberHashes = hashes,
  }
end

return Compiler
