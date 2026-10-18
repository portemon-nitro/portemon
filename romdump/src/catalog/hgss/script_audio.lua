-- Frozen producer facts for HGSS script audio dependencies, normalized from
-- the retail ROM. The two variable fanfare sites are in script member 148
-- (two `PlayFanfare VAR_SPECIAL_x8000` instructions immediately after
-- `GetDexEvalResult`); PlayFanfare resolves its operand through the script
-- variable, and the Johto/National dex rating writers emit SEQ_ME_HYOUKA1
-- normally and SEQ_ME_HYOUKA6 for the completed-dex case.
-- Producer-only reference data: the runtime must never require this module.

return {
  repository = "retail ROM",
  sourcePaths = {
    "files/fielddata/script/scr_seq/scr_seq_0148.s",
    "src/scrcmd_sound.c",
    "src/scrcmd_c.c",
    "asm/unk_0205BB1C.s",
  },
  variableFanfareMembers = { 148 },
  variableFanfareSequences = { "SEQ_ME_HYOUKA1", "SEQ_ME_HYOUKA6" },
}
