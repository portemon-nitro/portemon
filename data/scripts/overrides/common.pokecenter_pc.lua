-- Pokemon Center PC shell. Follows the retail flow, but opens Storage, Mailbox,
-- and Photo Album over the visible field instead of fading the screen out and
-- back in around each application.

local S = require("gen4.script")

local ROOT_MENU = S.var("VAR_SPECIAL_x8006")
local MENU_RESULT = S.var("VAR_SPECIAL_RESULT")
local CHOICE = S.var("VAR_SPECIAL_x8008")
local PHOTO_COUNT = S.var("VAR_BASE")

local function say(message, waitForPrint)
  return {
    S.bufferText({ slot = 0, value = S.playerName() }),
    S.message({ message = message, waitForPrint = waitForPrint }),
  }
end

local function menuBegin(result)
  return S.menuBegin({ messageSource = "standard", initialCursor = 0, cancellable = true, result = result })
end

local function menuAdd(messageId, value, vanillaMetadata)
  return S.menuAdd({ messageId = messageId, value = value, vanillaMetadata = vanillaMetadata })
end

local function whenChoice(value, target)
  return S.gotoIf({ condition = S.eq(CHOICE, value), target = target })
end

-- Closes the shell message and releases the terminal clip before an
-- application takes over input.
local function openApplication(app, mode)
  return {
    S.closeMessage({ erase = true }),
    S.pcTerminalEffect({ action = "release", prop = "pc_terminal" }),
    S.pcOpen({ app = app, mode = mode }),
    S.restoreOverworld(),
  }
end

local function concat(...)
  local steps = {}
  for _, list in ipairs({ ... }) do
    for _, step in ipairs(list) do
      steps[#steps + 1] = step
    end
  end
  return steps
end

local function terminalOn()
  return {
    S.pcTerminalEffect({ action = "start", prop = "pc_terminal" }),
    S.pcTerminalEffect({ action = "on", prop = "pc_terminal" }),
    S.pcTerminalEffect({ action = "wait", prop = "pc_terminal" }),
  }
end

return S.script({
  api = 1,
  id = "common.pokecenter_pc",
  steps = concat({
    S.yieldTick(),
    S.lockAll(),
    S.playSound({ sound = "SEQ_SE_DP_PC_ON" }),
  }, terminalOn(), say("msg.hgss.0040.00033", true), {
    S.setAuxiliaryUiVisible({ visible = false }),

    -- Root menu.
    S.label({ name = "root" }),
  }, say("msg.hgss.0040.00034", true), {
    menuBegin(ROOT_MENU),
    S.if_({
      condition = S.flag("FLAG_SYS_MET_BILL"),
      yes = { menuAdd(62, 0, 255) },
      no = { menuAdd(61, 0, 255) },
    }),
    menuAdd(63, 1, 255),
    S.if_({
      condition = S.flag("FLAG_GAME_CLEAR"),
      yes = { menuAdd(64, 2, 255), menuAdd(66, 3, 255) },
      no = { menuAdd(66, 2, 255) },
    }),
    S.menuExec(),
    S.copyVar({ destination = CHOICE, source = ROOT_MENU }),
    whenChoice(0, "storage"),
    whenChoice(1, "extras"),
    S.if_({
      condition = S.all({ S.flag("FLAG_GAME_CLEAR"), S.eq(CHOICE, 2) }),
      yes = { S.goto_({ target = "hall_of_fame" }) },
      no = {},
    }),
    S.goto_({ target = "logoff" }),

    -- Someone's PC / Storage submenu.
    S.label({ name = "storage" }),
    S.playSound({ sound = "SEQ_SE_DP_PC_LOGIN" }),
  }, say("msg.hgss.0040.00035", true), {
    S.label({ name = "storage_menu" }),
    menuBegin(MENU_RESULT),
    menuAdd(67, 0, 76),
    menuAdd(68, 1, 77),
    menuAdd(69, 2, 78),
    menuAdd(70, 3, 79),
    menuAdd(72, 5, 81),
    S.menuExec(),
    S.copyVar({ destination = CHOICE, source = MENU_RESULT }),
    whenChoice(0, "storage_mode_0"),
    whenChoice(1, "storage_mode_1"),
    whenChoice(2, "storage_mode_2"),
    whenChoice(3, "storage_mode_3"),
    S.goto_({ target = "root" }),
  }, concat({ S.label({ name = "storage_mode_0" }) }, openApplication("storage", 0), {
    S.goto_({ target = "storage_return" }),
    S.label({ name = "storage_mode_1" }),
  }, openApplication("storage", 1), {
    S.goto_({ target = "storage_return" }),
    S.label({ name = "storage_mode_2" }),
  }, openApplication("storage", 2), {
    S.goto_({ target = "storage_return" }),
    S.label({ name = "storage_mode_3" }),
  }, openApplication("storage", 3), {
    S.label({ name = "storage_return" }),
  }, say("msg.hgss.0040.00034", false), terminalOn(), {
    S.goto_({ target = "storage_menu" }),

    -- Mailbox / Seals / Photo Album submenu.
    S.label({ name = "extras" }),
    S.playSound({ sound = "SEQ_SE_DP_PC_LOGIN" }),
  }, say("msg.hgss.0040.00036", true), {
    S.label({ name = "extras_menu" }),
    menuBegin(MENU_RESULT),
    menuAdd(73, 0, 82),
    menuAdd(74, 1, 83),
    S.pcCount({ kind = "photos", result = PHOTO_COUNT }),
    S.if_({
      condition = S.ne(PHOTO_COUNT, 0),
      yes = { menuAdd(65, 2, 85), menuAdd(75, 3, 84) },
      no = { menuAdd(75, 2, 84) },
    }),
    S.menuExec(),
    S.copyVar({ destination = CHOICE, source = MENU_RESULT }),
    whenChoice(0, "mailbox"),
    whenChoice(1, "seals"),
    S.if_({
      condition = S.all({ S.ne(PHOTO_COUNT, 0), S.eq(CHOICE, 2) }),
      yes = { S.goto_({ target = "photo_album" }) },
      no = {},
    }),
    S.goto_({ target = "root" }),

    S.label({ name = "mailbox" }),
    S.closeMessage({ erase = true }),
    S.pcCount({ kind = "mailbox", result = MENU_RESULT }),
    S.if_({
      condition = S.ne(MENU_RESULT, 0),
      yes = { S.goto_({ target = "mailbox_open" }) },
      no = {},
    }),
    S.message({ message = "msg.hgss.0040.00047", waitForPrint = true }),
    S.goto_({ target = "extras_menu" }),
    S.label({ name = "mailbox_open" }),
  }, openApplication("mailbox"), {
    S.goto_({ target = "extras_return" }),

    S.label({ name = "seals" }),
    S.pcCount({ kind = "seals", result = MENU_RESULT }),
    S.if_({
      condition = S.ne(MENU_RESULT, 0),
      yes = { S.goto_({ target = "seals_open" }) },
      no = {},
    }),
    S.message({ message = "msg.hgss.0040.00079", waitForPrint = true }),
    S.goto_({ target = "extras_menu" }),
    S.label({ name = "seals_open" }),
    S.closeMessage({ erase = true }),
    S.pcTerminalEffect({ action = "release", prop = "pc_terminal" }),
    S.pcCapsules(),
    S.goto_({ target = "extras_return" }),

    S.label({ name = "photo_album" }),
  }, openApplication("photoAlbum"), {
    S.label({ name = "extras_return" }),
  }, say("msg.hgss.0040.00034", false), terminalOn(), {
    S.goto_({ target = "extras_menu" }),

    -- Hall of Fame.
    S.label({ name = "hall_of_fame" }),
    S.playSound({ sound = "SEQ_SE_DP_PC_LOGIN" }),
    S.closeMessage({ erase = true }),
    S.pcHallOfFameStatus({ result = MENU_RESULT }),
    S.if_({
      condition = S.eq(MENU_RESULT, 1),
      yes = {
        S.message({ message = "msg.hgss.0040.00094", waitForPrint = true }),
        S.goto_({ target = "root" }),
      },
      no = {},
    }),
    S.pcTerminalEffect({ action = "release", prop = "pc_terminal" }),
    S.pcHallOfFameOpen(),
    S.restoreOverworld(),
  }, terminalOn(), {
    S.goto_({ target = "root" }),

    -- Log off.
    S.label({ name = "logoff" }),
    S.closeMessage({ erase = true }),
    S.playSound({ sound = "SEQ_SE_DP_PC_LOGOFF" }),
    S.pcTerminalEffect({ action = "off", prop = "pc_terminal" }),
    S.pcTerminalEffect({ action = "wait", prop = "pc_terminal" }),
    S.pcTerminalEffect({ action = "release", prop = "pc_terminal" }),
    S.setAuxiliaryUiVisible({ visible = true }),
    S.releaseAll(),
    S.yieldTick(),
    S.stop(),
  })),
})
