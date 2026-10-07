-- HGSS field-effect source selections. These are producer-only facts from
-- the curated field_static_models archive; generated assets carry semantic
-- definitions and cache references instead of source archive details.
--
-- Surf attachment presentation (pret/pokeheartgold ov01_021FE7AC,
-- ov01_021FE868, ov01_021FE8C8): the surf resource loader attaches the field
-- model selected below, starts player presentation at {0, 0x4000, 0x4000},
-- and bounces an oscillator height between 0x1000 and 0x4000 in 0x400 steps.
-- Player presentation Y is the oscillator plus 0x4000, player Z stays 0x4000,
-- and the attachment Y is the oscillator minus 0x1000 relative to logical
-- player Y. Source geometry uses 16 model units per world tile.

local MODEL_UNITS_PER_TILE = 16
local SURF_OSCILLATOR_MIN = 0x1000 / (0x1000 * MODEL_UNITS_PER_TILE)
local SURF_OSCILLATOR_MAX = 0x4000 / (0x1000 * MODEL_UNITS_PER_TILE)
local SURF_OSCILLATOR_STEP = 0x400 / (0x1000 * MODEL_UNITS_PER_TILE)
local SURF_PLAYER_BASE = 0x4000 / (0x1000 * MODEL_UNITS_PER_TILE)
local SURF_ATTACHMENT_BASE = -0x1000 / (0x1000 * MODEL_UNITS_PER_TILE)

return {
  schema = 1,
  archive = {
    alias = "field_static_models",
    path = "a/1/0/3",
  },
  animationArchive = {
    alias = "field_static_models",
    path = "a/1/0/3",
  },
  effects = {
    warp_entrance = {
      renderer = 3,
      modelMembers = { 85 },
      animationMembers = {},
    },
    tall_grass = {
      renderer = 8,
      modelMembers = { 126 },
      animationMembers = { 140 },
      lifecycle = {
        mode = "hold_until_owner_moves",
        holdFrame = 12,
      },
      placementOffset = { x = 0, y = 0, z = 0.625 },
    },
    very_tall_grass = {
      renderer = 12,
      modelMembers = { 122 },
      animationMembers = { 146 },
      lifecycle = {
        mode = "hold_until_owner_moves",
        holdFrame = 12,
      },
      placementOffset = { x = 0, y = 0, z = 0.625 },
    },
    trainer_reveal = {
      renderer = 1,
      modelMembers = { 124 },
      animationMembers = { 148 },
      lifecycle = {
        mode = "once",
        frameCount = 7,
      },
      placementOffset = { x = 0, y = 0, z = 0.5 },
    },
    surf_attachment = {
      modelMembers = { 86 },
      animationMembers = {},
      presentation = {
        initialPlayerOffset = { x = 0, y = SURF_PLAYER_BASE, z = SURF_PLAYER_BASE },
        oscillator = {
          initialY = SURF_OSCILLATOR_MIN,
          minY = SURF_OSCILLATOR_MIN,
          maxY = SURF_OSCILLATOR_MAX,
          stepY = SURF_OSCILLATOR_STEP,
        },
        playerBaseOffset = { x = 0, y = SURF_PLAYER_BASE, z = SURF_PLAYER_BASE },
        attachmentBaseOffset = { x = 0, y = SURF_ATTACHMENT_BASE, z = 0 },
        yawDegrees = { north = 180, south = 0, west = 270, east = 90 },
      },
    },
    follower_transition = {
      -- The transient follower effect: source models 129 ("monsterball") and
      -- 104 ("mb_out") plus the texture animation bound to model 104.
      -- animatedModelMember names the clip target explicitly so a swapped or
      -- corrupt companion can never silently rebind the animation.
      -- placementOffset carries the traced source-model-unit vertical offset;
      -- the compiler normalizes it into runtime tiles.
      modelMembers = { 129, 104 },
      animationMembers = { 164 },
      animatedModelMember = 104,
      lifecycle = {
        mode = "once",
        preludeTicks = 2,
      },
      placementOffset = { x = 0, y = 6, z = 0 },
    },
    pokemon_center_heal = {
      mapSymbol = "MAP_CHERRYGROVE_POKECENTER_1F",
      anchorModelMemberId = 36,
      machineModelMemberId = 37,
      ballModelMemberId = 107,
      spawnIntervalSourceFrames = 12,
      placementSound = "SEQ_SE_DP_BOWA",
      fanfare = "SEQ_ME_ASA",
      ballPositionsFx32 = {
        { role = "northwest", x = -0x4800, y = 0xC000, z = -0x4800 },
        { role = "northeast", x = 0x4800, y = 0xC000, z = -0x4800 },
        { role = "west", x = -0x4800, y = 0xC000, z = 0 },
        { role = "east", x = 0x4800, y = 0xC000, z = 0 },
        { role = "southwest", x = -0x4800, y = 0xC000, z = 0x4800 },
        { role = "southeast", x = 0x4800, y = 0xC000, z = 0x4800 },
      },
    },
  },
  -- The source callback table `ov01_02209544` in
  -- pret/pokeheartgold@9d8b7591f09b65804da2fb2dfd56f320633e0d36
  -- pairs each reaction's BTX0 texture member with a companion four-frame
  -- selector table. Both source identities stay here; generated keys stay semantic.
  followerReactions = {
    { key = "follower_reaction_1", textureMember = 2, descriptorMember = 150 },
    { key = "follower_reaction_2", textureMember = 3, descriptorMember = 151 },
    { key = "follower_reaction_3", textureMember = 4, descriptorMember = 152 },
    { key = "follower_reaction_4", textureMember = 5, descriptorMember = 153 },
    { key = "follower_reaction_5", textureMember = 6, descriptorMember = 154 },
    { key = "follower_reaction_6", textureMember = 7, descriptorMember = 155 },
    { key = "follower_reaction_7", textureMember = 8, descriptorMember = 156 },
    { key = "follower_reaction_8", textureMember = 9, descriptorMember = 157 },
    { key = "follower_reaction_9", textureMember = 10, descriptorMember = 158 },
    { key = "follower_reaction_10", textureMember = 11, descriptorMember = 159 },
    { key = "follower_reaction_11", textureMember = 12, descriptorMember = 160 },
    { key = "follower_reaction_12", textureMember = 13, descriptorMember = 161 },
    { key = "follower_reaction_13", textureMember = 14, descriptorMember = 162 },
    { key = "follower_reaction_14", textureMember = 15, descriptorMember = 163 },
  },
  followerReactionBase = {
    modelMember = 130,
    textureMember = 28,
    patternMember = 140,
  },
}
