-- Static source configuration for the field message and font derived classes.
-- Message bank reachability is derived from frozen map and script references by
-- FieldMessageCompiler, not selected by this manifest.

return {
  schema = 1,
  provenance = {
    repo = "retail ROM",
    sources = {
      { path = "include/msgdata.h" },
      { path = "src/msgdata.c" },
      { path = "src/font.c" },
      { path = "src/font_data.c" },
      { path = "src/text.c" },
      { path = "src/data/map_headers.h" },
      { path = "files/msgdata/msg/msg_0542_T20.gmm" },
      { path = "files/msgdata/msg/msg_0543_T20R0101.gmm" },
    },
  },
  -- The current field-font consumers use font 0 for dialogue and font 4 for
  -- Oak choice labels.
  fontIds = { 0, 4 },
  fontGlyphMembers = { [0] = 0, [4] = 4 },
  -- Member 6 is the screen-focus indicator set the text printer blits next
  -- to YESNO prompts.
  fontFocusIndicatorMember = 6,
  fontPaletteMember = 7,
  -- Atlas packing: 16px glyphs in a fixed grid.
  atlasGlyphsPerRow = 64,
}
