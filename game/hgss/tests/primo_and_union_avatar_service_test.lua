-- Password and local avatar selection semantics over explicit parent data:
-- the two trainer-specific password checks decode the ordered password
-- bank against the visible trainer identity, publish first-time wallpaper
-- unlocks through the existing box owner, answer egg passwords without
-- mutating anything, and resolve the offered avatar choices, current
-- class, and saved row from the source trainer tables. Synthetic
-- profiles, stub box owners, and the checked-in password/avatar tables
-- only; no dump data and no network, editor, or party involvement.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")

local T = {
  metadata = {
    tags = { "easychat" },
  },
  tests = {},
}

---@return table service module
local function requireService()
  local ok, mod = pcall(require, "game.hgss.src.easychat.EasyChatScriptService")
  if not ok then
    error("the field script has no password and avatar service yet", 0)
  end
  assert(type(mod) == "table", "the field script has no password and avatar service yet")
  return mod
end

---@return table shared catalog data with the real password and avatar tables
local function catalogData()
  local Sources = require("romdump.src.config.EasyChatSources")
  local rows = {}
  for _, row in ipairs(Sources.avatarAttributes) do
    rows[#rows + 1] = { spriteId = row.spriteId, classId = row.classId }
  end
  return {
    words = {},
    templates = {},
    groups = {},
    initials = {},
    gridCells = {},
    primoWords = Sources.primoWords,
    unionAvatars = { choices = Sources.avatarChoices, rows = rows },
  }
end

---@param catalog table
---@return table authoritative saved word state
local function wordState(catalog)
  local EasyChatState = require("libs.hgss.src.save.EasyChatState")
  return EasyChatState.restore(nil, "english", catalog)
end

---@return table random stub failing loudly on any draw, table call record
local function stubRandom()
  local record = { calls = {} }
  local random = {}
  function random:lc(key)
    record.calls[#record.calls + 1] = key
    error("password and avatar checks consume no random draws", 0)
  end
  return random, record
end

---@param profile table live player profile
---@param mons table live mon/box owner
---@return table service arguments
local function serviceArgs(profile, mons)
  local EasyChatCatalog = require("libs.hgss.src.ui.EasyChatCatalog")
  local catalog = EasyChatCatalog.new(catalogData())
  local random, record = stubRandom()
  local provider = {
    acquireBank = function()
      return nil, "unused"
    end,
    releaseBank = function() end,
  }
  return {
    catalog = catalog,
    state = wordState(catalog),
    profile = profile,
    mons = mons,
    world = {},
    random = random,
    messageProvider = provider,
    randomRecord = record,
  }
end

---@param trainerId integer
---@param gender integer
---@return table live profile stub
local function profile(trainerId, gender)
  return {
    name = "GOLD",
    rivalName = "Silver",
    gender = gender,
    trainerId = trainerId,
    money = 3000,
    badges = {},
    nationalDex = false,
    runningShoes = false,
    runningShoesLock = false,
  }
end

-- A stub box owner behind the wallpaper checks: unlock reads come from a
-- detached copy, staged arrays publish into the held bits, and a stale
-- flag forces the stale preparation path.
---@param unlocks boolean[] eight held wallpaper bits
---@param stale boolean? force a stale preparation
---@return table mons stub, table publication record
local function stubMons(unlocks, stale)
  local record = { stages = 0, published = 0, stagedRevisions = {} }
  local mons = {}
  function mons:boxBonusUnlocks()
    local copy = {}
    for index = 1, 8 do
      copy[index] = unlocks[index]
    end
    return copy
  end
  function mons:partyRevision()
    return 11
  end
  function mons:boxRevision()
    return 7
  end
  function mons:preparePcChanges(expected, changes)
    record.stages = record.stages + 1
    record.stagedRevisions[#record.stagedRevisions + 1] = expected
    if stale == true then
      return nil, "stale"
    end
    for index = 1, 8 do
      unlocks[index] = changes.bonusUnlocks[index]
    end
    return {
      publish = function()
        record.published = record.published + 1
      end,
    }
  end
  return mons, record
end

---@param args table service arguments
---@return table service instance
local function service(args)
  local Service = requireService()
  return Service.new(args)
end

-- Source password phrases behind the visible trainer identity below.
-- Word identities only, never copied text.
local TRAINER_ID = 12345
local WALLPAPER_FIRST = { 1007, 1048, 1050, 1064 }
local WALLPAPER_LAST = { 1299, 1369, 981, 1331 }
local EGG_MAREEP = { 1150, 1413, 1134, 1152 }
local EGG_WOOPER = { 1084, 1320, 1354, 1410 }
local EGG_SLUGMA = { 1132, 1308, 1007, 1077 }

-- A full wallpaper check against the stub box owner: the first answer
-- reports its one-based slot and publishes exactly its bit.
function T.tests.wallpaper_first_unlock_publishes_only_its_bit()
  local args = serviceArgs(profile(TRAINER_ID, 0), {})
  local unlocks = { false, false, false, false, false, false, false, false }
  local mons, record = stubMons(unlocks, false)
  args.mons = mons
  local answer = service(args):checkPrimoWallpaper(WALLPAPER_FIRST)
  Assert.equal(answer, 1, "the first wallpaper answer reports its one-based slot")
  Assert.isTrue(unlocks[1], "the first wallpaper bit publishes")
  for index = 2, 8 do
    Assert.isFalse(unlocks[index], "no other wallpaper bit publishes")
  end
  Assert.equal(record.stages, 1, "the first unlock stages once")
  Assert.equal(record.published, 1, "the first unlock publishes once")
  Assert.deepEqual(
    record.stagedRevisions[1],
    { partyRevision = 11, boxRevision = 7 },
    "the unlock stages against the live revisions"
  )
  Assert.equal(#args.randomRecord.calls, 0, "password checks consume no random draws")
end

-- The last wallpaper index unlocks through the same path, and a
-- previously unlocked wallpaper answers zero without staging anything.
function T.tests.wallpaper_last_unlock_and_duplicate_stay_idempotent()
  local args = serviceArgs(profile(TRAINER_ID, 0), {})
  local unlocks = { false, true, false, false, false, false, false, false }
  local mons, record = stubMons(unlocks, false)
  args.mons = mons
  local owned = service(args)
  Assert.equal(owned:checkPrimoWallpaper(WALLPAPER_LAST), 8, "the last wallpaper answer reports its slot")
  Assert.isTrue(unlocks[8], "the last wallpaper bit publishes")
  Assert.isTrue(unlocks[2], "the previously held bit stays held")
  Assert.equal(owned:checkPrimoWallpaper(WALLPAPER_LAST), 0, "the duplicate wallpaper answers zero")
  Assert.equal(record.stages, 1, "the duplicate unlock stages nothing")
  Assert.equal(record.published, 1, "the duplicate unlock publishes nothing")
  Assert.equal(#args.randomRecord.calls, 0, "duplicate checks consume no random draws")
end

-- A stale box preparation propagates its failure instead of publishing a
-- partial unlock.
function T.tests.wallpaper_stale_preparation_fails_without_publish()
  local args = serviceArgs(profile(TRAINER_ID, 0), {})
  local unlocks = { false, false, false, false, false, false, false, false }
  args.mons = stubMons(unlocks, true)
  local err = Assert.throws(function()
    service(args):checkPrimoWallpaper(WALLPAPER_FIRST)
  end)
  Assert.isTrue(Errors.is(err), "the stale publication fails through the structured error path")
  Assert.equal(err.code, "SCRIPT_SAVE_REVISION_MISMATCH", "the stale publication names its revision fault")
  Assert.isFalse(unlocks[1], "the stale unlock publishes no bit")
end

-- Invalid passwords and egg passwords report 255 to the wallpaper check
-- without touching the boxes.
function T.tests.wallpaper_invalid_and_egg_phrases_report_invalid()
  local args = serviceArgs(profile(TRAINER_ID, 0), {})
  local unlocks = { false, false, false, false, false, false, false, false }
  local mons, record = stubMons(unlocks, false)
  args.mons = mons
  local owned = service(args)
  Assert.equal(owned:checkPrimoWallpaper({ 0x1234, 1048, 1050, 1064 }), 255, "unknown words stay invalid")
  Assert.equal(owned:checkPrimoWallpaper(EGG_MAREEP), 255, "egg phrases stay invalid for wallpapers")
  Assert.equal(owned:checkPrimoWallpaper(WALLPAPER_FIRST), 255 - 254, "control: the wallpaper phrase still unlocks")
  Assert.equal(record.stages, 1, "only the valid phrase stages")
end

-- Decoder boundaries through the real ordered bank: positions past the
-- byte range, cyclic deltas past the byte range, and a mutated check
-- value all report invalid.
function T.tests.password_decoder_rejects_out_of_range_and_mutated_input()
  local Sources = require("romdump.src.config.EasyChatSources")
  local bank = Sources.primoWords
  local args = serviceArgs(profile(TRAINER_ID, 0), {})
  args.mons = {}
  local owned = service(args)
  Assert.equal(
    owned:checkPrimoWallpaper({ bank[300], bank[300], bank[300], bank[300] }),
    255,
    "a first index past the byte range stays invalid"
  )
  Assert.equal(
    owned:checkPrimoWallpaper({ bank[1], bank[300], bank[300], bank[300] }),
    255,
    "a cyclic delta past the byte range stays invalid"
  )
  local mutated = { WALLPAPER_FIRST[1], WALLPAPER_FIRST[2], WALLPAPER_FIRST[3], WALLPAPER_FIRST[4] }
  mutated[4] = WALLPAPER_LAST[4]
  Assert.equal(owned:checkPrimoWallpaper(mutated), 255, "a mutated check value stays invalid")
  Assert.equal(#args.randomRecord.calls, 0, "rejected checks consume no random draws")
end

-- Egg passwords answer their code without any gift, flag, or box
-- mutation; the stub mon owner is never touched.
function T.tests.egg_answers_report_their_code_without_mutation()
  for _, case in ipairs({
    { words = EGG_MAREEP, code = 8 },
    { words = EGG_WOOPER, code = 9 },
    { words = EGG_SLUGMA, code = 10 },
  }) do
    local args = serviceArgs(profile(TRAINER_ID, 0), {})
    args.mons = {}
    Assert.equal(service(args):checkPrimoEgg(case.words), case.code, "the egg phrase answers its one-time code")
    Assert.equal(#args.randomRecord.calls, 0, "egg checks consume no random draws")
  end
end

-- The opposite reward family rejects each fixture, and a different
-- visible identity rejects the egg fixtures while the same visible half
-- behind another high half keeps its answer.
function T.tests.password_families_and_visible_identities_stay_distinct()
  local args = serviceArgs(profile(TRAINER_ID, 0), {})
  args.mons = {}
  local owned = service(args)
  Assert.equal(owned:checkPrimoEgg(WALLPAPER_FIRST), 255, "wallpaper phrases stay invalid for eggs")
  Assert.equal(owned:checkPrimoWallpaper(EGG_WOOPER), 255, "egg phrases stay invalid for wallpapers")
  local otherArgs = serviceArgs(profile(12346, 0), {})
  otherArgs.mons = stubMons({ false, false, false, false, false, false, false, false }, false)
  local other = service(otherArgs)
  Assert.equal(other:checkPrimoEgg(EGG_MAREEP), 255, "a different visible identity rejects the egg phrase")
  Assert.equal(other:checkPrimoWallpaper(WALLPAPER_FIRST), 255, "a different visible identity rejects wallpapers")
  local highArgs = serviceArgs(profile(TRAINER_ID + 65536, 0), {})
  highArgs.mons = stubMons({ false, false, false, false, false, false, false, false }, false)
  local highHalf = service(highArgs)
  Assert.equal(highHalf:checkPrimoEgg(EGG_SLUGMA), 10, "the same visible half keeps its egg answer")
  Assert.equal(highHalf:checkPrimoWallpaper(WALLPAPER_FIRST), 1, "the same visible half keeps its wallpaper answer")
end

-- Offered avatar choices follow the trainer residue and gender half in
-- source order: every residue 0..7 in both halves resolves to the source
-- table rows without consuming random draws.
function T.tests.avatar_choices_follow_the_trainer_residue_in_both_halves()
  local Sources = require("romdump.src.config.EasyChatSources")
  for residue = 0, 7 do
    for _, gender in ipairs({ 0, 1 }) do
      local args = serviceArgs(profile(residue, gender), {})
      args.mons = {}
      local offered = service(args):unionAvatarChoices()
      Assert.equal(#offered, 4, "the selector offers four choices")
      for choice = 0, 3 do
        local spriteIndex = Sources.avatarChoices[residue + 1][choice + 1]
        local row = Sources.avatarAttributes[spriteIndex + gender * 8 + 1]
        Assert.equal(offered[choice + 1].spriteId, row.spriteId, "the offered sprite follows the source table")
        Assert.equal(offered[choice + 1].classId, row.classId, "the offered class follows the source table")
      end
      Assert.equal(#args.randomRecord.calls, 0, "choice resolution consumes no random draws")
    end
  end
end

-- The current saved row answers its class, and one offered choice
-- projects to the class behind 288 or the native sprite behind 558.
function T.tests.avatar_class_and_choice_project_their_source_values()
  local Sources = require("romdump.src.config.EasyChatSources")
  local trainerId = 12345
  local row = Sources.avatarChoices[trainerId % 8 + 1][2] + 0 * 8
  local expected = Sources.avatarAttributes[row + 1]
  local ownedProfile = profile(trainerId, 0)
  ownedProfile.unionAvatar = row
  local args = serviceArgs(ownedProfile, {})
  args.mons = {}
  local owned = service(args)
  Assert.equal(owned:unionAvatarClass(), expected.classId, "the saved row answers its class")
  local record = owned:unionAvatarChoice(1)
  Assert.equal(record.classId, expected.classId, "the offered choice carries its class")
  Assert.equal(record.spriteId, expected.spriteId, "the offered choice carries its native sprite")
  local badChoice = Assert.throws(function()
    owned:unionAvatarChoice(4)
  end)
  Assert.isTrue(Errors.is(badChoice), "an out-of-range choice fails through the structured error path")
end

-- Saving an offered sprite persists its normalized row in the live
-- profile and nothing else; an unknown sprite or the other gender half
-- fails instead of persisting.
function T.tests.avatar_selection_persists_only_the_normalized_row()
  local Sources = require("romdump.src.config.EasyChatSources")
  local trainerId = 9
  local args = serviceArgs(profile(trainerId, 0), {})
  args.mons = {}
  local owned = service(args)
  local spriteIndex = Sources.avatarChoices[trainerId % 8 + 1][3]
  local sprite = Sources.avatarAttributes[spriteIndex + 1].spriteId
  owned:setUnionAvatar(sprite)
  Assert.equal(args.profile.unionAvatar, spriteIndex, "the selected sprite persists its normalized male row")
  Assert.equal(args.profile.gender, 0, "saving the identity changes no other profile field")
  Assert.equal(#args.randomRecord.calls, 0, "saving the identity consumes no random draws")
  local femaleArgs = serviceArgs(profile(trainerId, 1), {})
  femaleArgs.mons = {}
  local female = service(femaleArgs)
  female:setUnionAvatar(Sources.avatarAttributes[spriteIndex + 8 + 1].spriteId)
  Assert.equal(femaleArgs.profile.unionAvatar, spriteIndex + 8, "the female half persists its own normalized row")
  local wrongGender = Assert.throws(function()
    owned:setUnionAvatar(Sources.avatarAttributes[spriteIndex + 8 + 1].spriteId)
  end)
  Assert.isTrue(Errors.is(wrongGender), "the other gender half fails through the structured error path")
  Assert.equal(args.profile.unionAvatar, spriteIndex, "the rejected sprite preserves the saved row")
  local unknown = Assert.throws(function()
    owned:setUnionAvatar(250)
  end)
  Assert.isTrue(Errors.is(unknown), "an unknown sprite fails through the structured error path")
end

-- Runtime delegation: password inputs evaluate before the aliased
-- result writes, avatar buffers snapshot into ordinary text slots, and
-- avatar selection persists through the node without a result.
function T.tests.runtime_nodes_evaluate_inputs_before_the_aliased_result()
  local Runtime = require("libs.script.src.Runtime")
  local RuntimeValues = require("libs.hgss.src.script.RuntimeValues")
  local Sources = require("romdump.src.config.EasyChatSources")
  local trainerId = 12345
  local profileStub = profile(trainerId, 0)
  local unlocks = { false, false, false, false, false, false, false, false }
  local mons, _ = stubMons(unlocks, false)
  local args = serviceArgs(profileStub, mons)
  local owned = service(args)
  local world = {
    vars = { [0x800C] = 1007 },
    getVar = function(self, id)
      return self.vars[id]
    end,
    setVar = function(self, id, value)
      self.vars[id] = value
    end,
  }
  local run = {
    instance = { scriptId = "test.primo", locals = {}, textArgs = {} },
    services = { easyChatService = owned, world = world },
    semantics = RuntimeValues,
  }
  local function var(id)
    return { value = "var", id = id }
  end
  Assert.equal(
    Runtime.executeNode({
      op = "primo_password",
      kind = "wallpaper",
      result = var(0x800C),
      word1 = var(0x800C),
      word2 = 1048,
      word3 = 1050,
      word4 = 1064,
    }, run),
    Runtime.OUTCOME_CONTINUE,
    "the password check continues in the same tick"
  )
  Assert.equal(world.vars[0x800C], 1, "the aliased result writes the decoded answer")
  Assert.isTrue(unlocks[1], "the runtime path publishes through the service")

  Assert.equal(
    Runtime.executeNode({ op = "buffer_union_avatar_choices" }, run),
    Runtime.OUTCOME_CONTINUE,
    "the choice buffer continues in the same tick"
  )
  local residueRow = Sources.avatarChoices[trainerId % 8 + 1]
  for slot = 0, 3 do
    local buffered = run.instance.textArgs[slot]
    Assert.equal(buffered.text, "trainer_class_name", "the choice buffer snapshots plain class names")
    Assert.equal(
      buffered.value,
      Sources.avatarAttributes[residueRow[slot + 1] + 1].classId,
      "the choice buffer snapshots the offered classes"
    )
  end

  Assert.equal(
    Runtime.executeNode({ op = "buffer_union_avatar_class", slot = 4 }, run),
    Runtime.OUTCOME_CONTINUE,
    "the class buffer continues in the same tick"
  )
  Assert.equal(
    run.instance.textArgs[4].text,
    "trainer_class_name_indefinite",
    "the avatar class buffers with its article"
  )

  Assert.equal(
    Runtime.executeNode({
      op = "union_avatar_choice",
      choice = 1,
      attribute = "class",
      result = var(0x8005),
    }, run),
    Runtime.OUTCOME_CONTINUE,
    "the choice projection continues in the same tick"
  )
  Assert.equal(
    world.vars[0x8005],
    Sources.avatarAttributes[residueRow[2] + 1].classId,
    "the class projection writes the offered class"
  )
  Assert.equal(
    Runtime.executeNode({
      op = "union_avatar_choice",
      choice = 1,
      attribute = "sprite",
      result = var(0x8004),
    }, run),
    Runtime.OUTCOME_CONTINUE,
    "the sprite projection continues in the same tick"
  )
  Assert.equal(
    world.vars[0x8004],
    Sources.avatarAttributes[residueRow[2] + 1].spriteId,
    "the sprite projection writes the native sprite"
  )

  Assert.equal(
    Runtime.executeNode({ op = "set_union_avatar", sprite = world.vars[0x8004] }, run),
    Runtime.OUTCOME_CONTINUE,
    "the avatar selection continues in the same tick"
  )
  Assert.equal(args.profile.unionAvatar, residueRow[2], "the runtime selection persists the normalized row")
end

return T
