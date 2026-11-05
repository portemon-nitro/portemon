# Phone asset census: pgphone_gra per-skin members vs current selectors

Source of truth: retail `files/application/pokegear/phone/pgphone_gra.mk`
member census (52 members) crossed with every `pgphone_gra` loader in
`src/application/pokegear/phone/*.c`. Only `pokegear_phone_gfx.c` loads
phone members; nothing under `scripts/` touches them. Report-only unless
flagged behavioral below.

## Per-skin member map (skin s in 0..5)

| Members   | Type | Retail loader                                            | Current selector              | Standing |
|-----------|------|----------------------------------------------------------|-------------------------------|----------|
| 0         | NCLR | OBJ palettes, both engines (`LoadPalettes`, fixed)       | `phoneSpritePalette = 0`      | match    |
| 1         | NCGR | OBJ char via a/1/7/5 descriptors 44-47 (char=1)          | `phoneSprites.phone.char = 1` | match    |
| 2         | NCER | OBJ cell (descriptor cell=2)                               | `cell = 2`                    | match    |
| 3         | NANR | OBJ anim (descriptor anim=3), 9 sequences                | `anim = 3`                    | match    |
| 4+s       | NCLR | SUB_BG palettes (`LoadPalettes`, `skin+4`)               | `phoneUpper.palette = 4+s`    | match    |
| 10+s      | NCLR | MAIN_BG palettes (`LoadPalettes`, `skin+10`)             | `phoneForeground.palette`     | match    |
| 16+s      | NCGR | SUB_3 char (`LoadBgGraphics`, `skin+16`)                 | `phoneUpper.char = 16+s`      | match    |
| 22+s      | NSCR | SUB_3 screen (`LoadBgGraphics`, `skin+22`)               | `phoneUpper.screen = 22+s`    | match    |
| 28+s      | NCGR | MAIN_2 char (`LoadBgGraphics`, `skin+28`)                | `phoneForeground.char`        | match    |
| 34+s      | NSCR | MAIN_2 screen (`screenData`, `skin+34`)                  | `phoneForeground.screen`      | match    |
| 40+s      | NCGR | NO LOADER in the phone app                               | none (provenance closure only)| extra    |
| 46+s      | NSCR | NO LOADER in the phone app                               | none (provenance closure only)| extra    |

## Findings

1. **BEHAVIORAL (a): missing window palette.** `sWindowTemplates[0,1]`
   (call speech/name on SUB_2) print with palette **1**, but no producer
   bank is selected for it today: `phoneForeground` only yields the list
   bank 2 (windows[2] on MAIN_3) and the tooltip bank 10 (windows[3] on
   MAIN_1). Contract: emit `phone.windowPalette[skin]` = bank 1 of the
   same NCLR member `10+s`; carry through schema (no schema change: palette
   tables already validate as nested scalars), plan, and `drawCall`.
   `drawCall` reusing `listPalette` is the current defect the renderer
   contract pins red.
2. **BEHAVIORAL (c): phone OBJ banks untranscribed.** `sSpriteTemplates`
   drives phone anims {0,1,2,3,4,5,6,8} with non-zero OBJ palette slots 6
   and 7, while `PokegearSources.phoneSprites.phone.banks` is empty, so
   every sequence renders bank 0. Verified-bank-0 is REFUTED by the
   template slots; exact bank values are transcription duty in the
   implementation lane (hypothesis: bank == template slot, i.e. anims
   {0,1,6} -> 7 and {2,3,4,5,8} -> 6, against NCLR member 0 with 11 banks;
   confirm against the a/1/7/5 descriptors during implementation). The
   ROM contract pins coverage of {1,2,3,4,5,6,7,9} plus range red.
3. **Report-only: no native menu-strip art.** Context menus frame through
   the shared borrowed `sbox_gra` (a/1/6/5) tiles, matching the retail
   `TouchscreenListMenu` path; there is no per-skin phone menu strip to
   select. Current `listMenu` selector stands.
4. **Report-only: `screenData` (34+s) role.** The MAIN_2 tilemap behind the
   foreground plane; `pokegear_phone_contacts.c:115` additionally copies
   its rows 24-27 to MAIN_1 rows 20-23 as the tooltip-strip source. No new
   plane is owed: it is the `phoneForeground.screen` member, already
   selected. The strip fill itself resolves through `tooltipPalette`
   bank 10, already contracted.
5. **Report-only: extra screens/chars (40+s NCGR, 46+s NSCR).** Six skins
   of tile and map art with no loader anywhere in the phone app. Keep them
   in the provenance closure, select nothing; revisit only if a future
   card state references them.
6. **Report-only: failure policy.** Current `SKIN_FILLS` fallback
   (missing foreground) and silent skip (missing upper) have no retail
   standing: retail always loads both planes before first paint. The contract set unifies
   both to loud failure, pinned by asset-less unit contracts.
