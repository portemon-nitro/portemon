-- Locator metadata for the HGSS field-actor graphics tables. The overlay 1
-- tables are addressed by their original
-- runtime (RAM) addresses; the importer converts them to overlay offsets using
-- the load address the ROM's own overlay table reports, so no raw .nds file
-- offset is ever hardcoded. Addresses are taken from the retail ROM's overlay 1 sprite and field data
-- and validated byte-for-byte against every supported ROM at import time. Pure data; no love dependency.

return {
  schema = 1,

  provenance = {
    repo = "retail ROM",
  },

  -- Overlay 1 (ARM9) holds every field-actor table. Runtime addresses only.
  overlay = { cpu = "arm9", overlayId = 1 },

  tables = {
    -- ObjectEvent_GetGraphicsInfo scans this in six-byte steps to the 0xFFFF
    -- terminator. The expectations are invariants, not a substitute for parsing.
    graphics = {
      address = 0x022074A8,
      expectedRecordCount = 901,
      expectedTerminatorOffset = 0x151E,
    },
    -- ov01_02207318: 24 eight-byte visual descriptors selected by packed bits 10-15.
    descriptors = { address = 0x02207318, count = 24 },
    -- Flat u16 (key, memberId) pair arrays, terminated by key 255.
    modelKeys = { address = 0x02207294 },
    timelineKeys = { address = 0x022072CC },
  },

  -- The NitroFS path of the field-actor archive (`data/mmodel/mmodel`).
  archive = { alias = "field_actor_models", path = "a/0/8/1" },

  -- Descriptor 63 is a sentinel for the separate static map-object renderer.
  -- ov01_02208E30 maps those sprite IDs to self-contained NSBMD members.
  staticModels = {
    descriptor = 63,
    table = { address = 0x02208E30, count = 12 },
    archive = { alias = "field_static_models", path = "a/1/0/3" },
  },

  -- global_fieldmap.h direction order. The index is the animation-range index
  -- inside a descriptor's range table; east is never a mirror of west.
  directionOrder = { "north", "south", "west", "east" },

  -- FieldSystem_ResolveObjectSpriteID redirects this inclusive range through
  -- field variables before the graphics lookup, so these
  -- IDs are absent from the table by design. spriteId `s` reads variable
  -- `variableVarBase + (s - first)` once, at object creation
  -- Every variable defaults to 0, the hero graphic.
  variableSpriteRange = { first = 101, last = 117 },
  -- VAR_OBJ_GFX_BASE. The retail ROM flags spriteId
  -- 117 as an off-by-one reading the variable past the sixteen VAR_OBJ_* slots;
  -- the var-base formula above reproduces that original behavior.
  variableVarBase = 0x4020,

  -- The player identities available to a field session. Gender uses the same
  -- validated player-profile values as PlayerData (0 = male, 1 = female).
  -- Visuals resolve through the producer player-avatar reference by gender,
  -- so no sprite selection lives here.
  avatars = {
    { id = "hero", gender = 0 },
    { id = "heroine", gender = 1 },
  },

  -- Common placement recovered from the field-actor loader and billboard models:
  -- a bottom-center local origin, the Nitro SBC full camera-facing billboard
  -- command, and the loader's six-model-unit Y offset. Frame dimensions come
  -- from each resource; the ordinary actor model is 32x32 and rocks are 16x16.
  placement = {
    pivot = { x = 0.5, y = 1.0 },
    modelOffset = { x = 0, y = 0, z = 6 },
    billboardMode = "cameraFacingFull",
    mirrorEastWest = false,
  },
}
