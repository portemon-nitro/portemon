-- Static source configuration for the field message and font derived classes.
-- Message bank reachability is derived from frozen map and script references by
-- FieldMessageCompiler, not selected by this manifest.

return {
  schema = 1,
  provenance = {
    repo = "retail ROM",
  },
  -- Battle text uses FontIDs 0, 1, and 4. Each ID maps directly to the
  -- same `NARC_graphic_font` glyph member.
  fontIds = { 0, 1, 4 },
  fontGlyphMembers = { [0] = 0, [1] = 1, [4] = 4 },
  -- Member 6 is the screen-focus indicator set the text printer blits next
  -- to YESNO prompts.
  fontFocusIndicatorMember = 6,
  fontPaletteMember = 7,
  -- Atlas packing: 16px glyphs in a fixed grid.
  atlasGlyphsPerRow = 64,
}
