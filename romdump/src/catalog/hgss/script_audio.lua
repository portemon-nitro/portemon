-- Frozen producer facts for HGSS script audio dependencies, normalized from
-- the retail ROM. The two variable fanfare sites are in script member 148
-- (two `PlayFanfare VAR_SPECIAL_x8000` instructions immediately after
-- `GetDexEvalResult`); PlayFanfare resolves its operand through the script
-- variable, and the Johto/National dex rating writers emit SEQ_ME_HYOUKA1
-- normally and SEQ_ME_HYOUKA6 for the completed-dex case.
-- Producer-only reference data: the runtime must never require this module.

return {
  variableFanfareMembers = { 148 },
  variableFanfareSequences = { "SEQ_ME_HYOUKA1", "SEQ_ME_HYOUKA6" },
}
