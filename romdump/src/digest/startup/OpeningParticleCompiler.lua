-- Normalizes the retail SPL starter emitter resources behind opening-movie
-- scene 4 (NARC_a_0_5_9 member 4) into the particle vocabulary the scene
-- manifest carries. The retail library starts one emitter per starter
-- group: grass {6,7,8} for Chikorita, fire {3,4,5} for Cyndaquil, water
-- {0,1,2} for Totodile (src/intro_movie_scene_4.c sStarterParticleResIds).
-- This module owns only the starter assignment and the scene texture root;
-- emitter compilation is SplEmitterCompiler's.

local SplEmitterCompiler = require("romdump.src.digest.particle.SplEmitterCompiler")

local OpeningParticleCompiler = {}

local STARTER_EMITTER_COUNT = 9

local EMITTER_GROUPS = {
  [0] = "water",
  [1] = "water",
  [2] = "water",
  [3] = "fire",
  [4] = "fire",
  [5] = "fire",
  [6] = "grass",
  [7] = "grass",
  [8] = "grass",
}

---@param emitterId integer
---@return string|nil
local function starterGroup(emitterId)
  return EMITTER_GROUPS[emitterId]
end

-- Compile the starter emitter set from the raw scene 4 SPL member. The
-- member must carry exactly the nine retail starter emitters; their
-- textures stage under the scene 4 asset root.
---@param memberBytes string raw NARC_a_0_5_9 member 4 bytes
---@param sceneRoot string scene asset root the texture art stages under
---@return table<string, unknown>|nil
---@return Errors.Error|string|nil
function OpeningParticleCompiler.compile(memberBytes, sceneRoot)
  assert(type(memberBytes) == "string", "opening particles require the source member bytes")
  assert(type(sceneRoot) == "string" and sceneRoot ~= "", "opening particles require their scene asset root")
  ---@param textureId integer
  ---@return string
  local function texturePath(textureId)
    return sceneRoot .. "/particles/texture" .. textureId .. ".png"
  end
  return SplEmitterCompiler.compile(memberBytes, {
    emitterCount = STARTER_EMITTER_COUNT,
    texturePath = texturePath,
    group = starterGroup,
  })
end

return OpeningParticleCompiler
