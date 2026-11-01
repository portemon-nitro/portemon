-- Producer-side semantic inventory of the native options application
-- sources: NARC member selection, the resdat resource-set relationships,
-- the source animation/message roles, and the baseline face crop origins.
-- The audit basis is the retail ROM: members are identified by decoding
-- every member of the options archive through the production G2D decoders
-- and cross-checking the char/palette/cell/animation sets through the
-- resource lists and headers; screens 18 and 19 (the full backing planes)
-- and the Button Mode label row stay outside this contract. Pure data and
-- pure functions; no I/O. Never imported by runtime: libs/assets, game,
-- and script packages must not require this module.

local OptionsSources = {}

OptionsSources.provenance = {
  romAudit = "retail ROM",
}

-- Curated archive identities. NARC and NitroFS IDs are not interchangeable;
-- the symbol form is the only selector the compiler resolves. narcId 72 is
-- the catalog identity, never the physical ROM fileId the reader resolves.
OptionsSources.archive = { symbol = "NARC_a_0_7_2", path = "a/0/7/2", narcId = 72, memberCount = 20 }
OptionsSources.messagesArchive = { symbol = "NARC_msgdata_msg", path = "a/0/2/7" }
OptionsSources.messageBank = 45
OptionsSources.resdat = {
  symbol = "NARC_data_resdat",
  path = "a/1/7/5",
  lists = { animation = 20, cell = 21, char = 22, palette = 23 },
  headers = 77,
}

-- Audited member groups inside the options archive (zero-based).
-- Palettes 0 and 1 and chars 4, 5, and 6 serve the sprite sets through
-- the resdat lists; palette 2 and char 7 serve the baseline face outside
-- those lists. Char 7 carries the 128-tile baseline face bank the
-- unselected patches crop; screen 17 is the 256x256 baseline face.
-- Screen 18 and the full screen 19 are backing planes the menu never
-- ships. Char 8 and palette 3 stay outside the selected sets.
OptionsSources.members = {
  palettes = { 0, 1 },
  facePalette = 2,
  chars = { 4, 5, 6 },
  faceChar = 7,
  cells = { 9, 10, 11, 12 },
  animations = { 13, 14, 15, 16 },
  faceScreen = 17,
}

-- Resource-set relationships transcribed from the options header set: each
-- entry names the char/palette/cell/animation resource ids the resdat lists
-- resolve to archive members. Set 0 carries the small/wide pills (sequences
-- 0/1 select the size), sets 1 and 2 carry the left/right frame arrows
-- (idle and pressed animation states), and set 3 carries the Confirm/Quit
-- action chrome (normal/focused/pressed/pressed-focused).
OptionsSources.sets = {
  pills = { char = 0, palette = 0, cell = 0, animation = 0 },
  leftArrow = { char = 1, palette = 0, cell = 1, animation = 1 },
  rightArrow = { char = 1, palette = 0, cell = 2, animation = 2 },
  actions = { char = 2, palette = 1, cell = 3, animation = 3 },
}

-- Message bank slots (zero-based) for the semantic labels. Only the
-- offered rows are exposed: the Button Mode name (slot 5), the legacy Slow
-- value (slot 9), and the unselected name/confirm values (slots 18/19)
-- stay outside the generated labels. Slots 7 and 8 carry a display prefix
-- control the tokenizer lowers through the shared message text.
OptionsSources.messages = {
  title = 0,
  textSpeed = 1,
  battleScene = 2,
  battleStyle = 3,
  soundMode = 4,
  textFrame = 6,
  confirm = 7,
  quit = 8,
  textSpeedValues = { mid = 10, fast = 11 },
  battleSceneValues = { on = 12, off = 13 },
  battleStyleValues = { shift = 14, set = 15 },
  soundModeValues = { stereo = 16, mono = 17 },
  firstFrameValue = 20,
  frameValueCount = 20,
  firstFramePreview = 40,
  framePreviewCount = 20,
}

-- Baseline face crop origins in baseline-screen pixels. The small patch
-- backs the small pill and the wide patch backs the wide pill; the crop
-- extents always come from the decoded pill frame footprints, never from
-- these origins.
OptionsSources.faceOrigins = {
  small = { x = 112, y = 24 },
  wide = { x = 112, y = 72 },
}

return OptionsSources
