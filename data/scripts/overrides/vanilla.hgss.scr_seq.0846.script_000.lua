-- Player-room Mailbox shell. Follows the source event flow, but opens the
-- Mailbox over the visible field instead of fading the screen out and
-- back in around it: the script screen fade draws over every foreground
-- application, so the vanilla fade would hide the open Mailbox behind
-- opaque black and softlock the player on an invisible screen.
-- Storage-style terminal effects are absent here because the source event
-- never drives the terminal prop.

local S = require("gen4.script")

local RESULT = S.var("VAR_SPECIAL_RESULT")

return S.script({
  api = 1,
  id = "vanilla.hgss.scr_seq.0846.script_000",
  steps = {
    S.yieldTick(),
    S.lockAll(),
    S.playSound({ sound = "SEQ_SE_DP_PC_ON" }),
    S.bufferText({ slot = 0, value = S.playerName() }),
    S.message({ message = "msg.hgss.0546.00000", waitForPrint = true }),
    S.closeMessage({ erase = true }),
    S.pcCount({ kind = "mailbox", result = RESULT }),
    S.gotoIf({ condition = S.eq(RESULT, 0), target = "empty" }),
    S.pcOpen({ app = "mailbox" }),
    S.restoreOverworld(),
    S.releaseAll(),
    S.yieldTick(),
    S.stop(),
    S.label({ name = "empty" }),
    S.say({ message = "msg.hgss.0546.00001" }),
    S.releaseAll(),
    S.yieldTick(),
    S.stop(),
  },
})
