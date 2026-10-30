-- Source-only member selection for the generated HGSS field-move cut-in
-- banner class. The banner is the BG3 backdrop inside the cut-in window,
-- loaded once per cut-in by FieldMoveCutIn_InitBannerGraphics and freed by
-- FieldMoveCutIn_FreeBannerGraphics (field_move_cut_in.c): the HEARTGOLD
-- branch loads NCGR member 0, NSCR member 1, NCLR member 2, while the other
-- edition loads 3, 4, and 5 from the same choose_starter_sub_res archive.
-- CutInBanner_LoadPalette unpacks the NCLR member and places its first
-- sixteen colors at hardware BG palette slot 12; CutInBanner_LoadChar loads
-- the NCGR tiles at character base 0; CutInBanner_LoadScreen loads the NSCR
-- tilemap and then rewrites the whole 32x32 tilemap to palette slot 12
-- (BgTilemapRectChangePalette over 0, 0, 32, 32). Effect palettes, trainer
-- and mon sprites, scroll art, clouds, fly extras, and landing art share the
-- archive but are not selected: this class stages the banner graphics
-- alone, so the banner producer runs without the sprite producers. Every
-- archive alias and member number lives here and in the compiler
-- dependencies; the generated manifest never carries them. Member numbers
-- are zero-based per the repository convention.

local FieldMoveCutInBannerSources = {}

FieldMoveCutInBannerSources.provenance = {
  repo = "retail ROM",
}

-- Curated archive alias; the compiler opens it through the source reader.
FieldMoveCutInBannerSources.ARCHIVE_ALIAS = "cut_in_banner"

-- The hardware BG palette slot the retail loader places the banner colors
-- at (LoadPalette's 12 * 0x20 destination and the tilemap rewrite target).
-- The generated PNG bakes these sixteen colors, and the manifest records
-- the slot as the semantic presentation fact the composition was built
-- against.
FieldMoveCutInBannerSources.PALETTE_SLOT = 12

-- The 32x32-tile BG3 tilemap the retail rewrite covers, in pixels.
FieldMoveCutInBannerSources.BANNER_WIDTH = 256
FieldMoveCutInBannerSources.BANNER_HEIGHT = 256

-- Edition -> zero-based banner members (char, screen, palette) from the
-- InitBannerGraphics edition branches. The archive is shared; only the
-- member selection differs per edition.
FieldMoveCutInBannerSources.BANNERS = {
  heartgold = { char = 0, screen = 1, palette = 2 },
  soulsilver = { char = 3, screen = 4, palette = 5 },
}

-- The zero-based banner members for one edition. Only the two shipped
-- editions resolve; anything else is a source-selection defect, never a
-- silent fallback to one edition's artwork.
---@param versionId string
---@return { char: integer, screen: integer, palette: integer }
function FieldMoveCutInBannerSources.bannerMembers(versionId)
  local selection = FieldMoveCutInBannerSources.BANNERS[versionId]
  assert(type(selection) == "table", "the cut-in banner has no source selection for version " .. tostring(versionId))
  return { char = selection.char, screen = selection.screen, palette = selection.palette }
end

return FieldMoveCutInBannerSources
