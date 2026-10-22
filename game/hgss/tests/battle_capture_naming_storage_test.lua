-- Frozen capture-naming acceptance: naming a capture must reuse the
-- existing native naming screen, and its result must join party insertion
-- and storage transfer in source order with no lost or duplicated subject.
-- The standalone naming controller already accepts text and seals exactly
-- once; the battle side must delegate to that mechanism instead of a
-- substitute prompt.
--
-- Dependency note: the battle child composition module is missing, so no
-- naming child kind exists behind battle input and the capture
-- naming/storage ordering has no completion owner. The red tests pin those
-- misses. Full-party storage transfer atomicity stays with the completion
-- owner covered by the failure-isolation suite.

local Assert = require("tests.support.Assert")
local NamingScreenController = require("libs.hgss.src.ui.NamingScreenController")

local BattleSubflows = require("game.hgss.src.battle.BattleSubflows")

local COMPOSER_MODULE = "game.hgss.src.battle.BattleChildApplications"

local T = {}

local CHARMAP = {}
for code = string.byte(" "), string.byte("~") do
  CHARMAP[string.char(code)] = code
end

---@return table<string, unknown> naming controller bound to a captured subject
local function captureNaming()
  return NamingScreenController.new({
    kind = "pokemon",
    maxLength = 10,
    initialText = "",
    charmap = CHARMAP,
    subject = { kind = "pokemon", species = 25 },
  })
end

function T.standalone_naming_screen_accepts_and_seals_text_exactly_once()
  local screen = captureNaming()
  Assert.equal(screen:text(), "", "setup: the capture starts from the empty default")
  Assert.isTrue(screen:inputText("AB"), "the real naming screen accepts text")
  Assert.isTrue(screen:submit(), "the real naming screen submits")
  Assert.deepEqual(screen:result(), { kind = "submit", text = "AB" }, "the sealed text matches the entry")
  Assert.isFalse(screen:submit(), "a second submit seals nothing more")
  Assert.equal(screen:text(), "AB", "the sealed text is preserved after the extra submit")
end

function T.capture_naming_delegates_through_the_battle_child_composer()
  local ok, composer = pcall(require, COMPOSER_MODULE)
  Assert.isTrue(ok, "capture naming composes through the battle child module (" .. COMPOSER_MODULE .. ")")
  assert(composer ~= nil, "the composer loads")
end

function T.capture_naming_opens_as_a_real_naming_child()
  local flows = BattleSubflows.new({ launchId = "launch-naming-child" })
  local intent = {
    kind = "naming",
    purpose = "nickname",
    launchId = "launch-naming-child",
    requestId = 13,
    epoch = 5,
    controller = "player",
    cancellable = true,
    -- The capture naming intent carries the authoritative committed
    -- subject the completion caller stages: without a species the real
    -- naming screen cannot name its subject and the child must refuse
    -- rather than invent one.
    subject = { species = 25 },
    request = { requestId = 13, epoch = 5, controller = "player", kind = "nickname" },
    options = {
      requestId = 13,
      epoch = 5,
      controller = "player",
      kind = "nickname",
      actors = { { combatant = 1, activation = 5, kind = "nickname", choices = {} } },
    },
    party = {
      { combatant = 1, slot = 0, name = "LEAD", level = 20, hp = 30, maxHp = 30 },
    },
    inventory = {},
  }
  local ok, openErr = flows:open(intent)
  Assert.isTrue(ok, "the capture naming intent opens as a real naming child: " .. tostring(openErr))
  local reopened, _ = flows:open(intent)
  Assert.isTrue(reopened, "the capture naming intent opens as a real naming child")
  flows:dispose()
end

function T.soulsilver_variant_stays_blocked_without_its_owned_cache(context)
  local GameVersion = require("romdump.src.source.GameVersion")
  local RomImporter = require("romdump.src.source.RomImporter")
  local known = false
  for _, versionId in ipairs(GameVersion.ORDER) do
    if versionId == "soulsilver" then
      known = true
    end
  end
  Assert.isTrue(known, "setup: the second version is a known parity dimension")
  if not RomImporter.isReady("soulsilver") then
    context:skip(
      "BLOCKED: no ready soulsilver user-owned ROM cache in this checkout; second-version naming parity is unverified"
    )
  end
  Assert.isTrue(
    false,
    "a ready soulsilver cache appeared: this probe must grow a real second-version comparison before it may pass"
  )
end

return { tests = T }
