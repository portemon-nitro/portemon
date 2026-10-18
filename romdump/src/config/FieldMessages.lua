-- Static source configuration for the field message and font derived classes.
-- Message bank reachability is derived from frozen map and script references by
-- FieldMessageCompiler, not selected by this manifest.

return {
  schema = 1,
  provenance = {
    repo = "retail ROM",
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
