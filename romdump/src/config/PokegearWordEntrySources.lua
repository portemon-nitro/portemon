-- Source selectors for the single-word Easy Chat map annotation
-- application: the closed overlay/graphics/message set behind the selector,
-- validated per game version. Every number below is gate-measured evidence
-- from the retail ROM joined to the owned HeartGold dump; FAT ids are provenance, never identity.
-- Runtime records never carry them.

local PokegearWordEntrySources = {}

PokegearWordEntrySources.provenance = {
  romAudit = "retail ROM",
  symbols = {
    "asm/overlay_102.s",
    "src/application/pokegear/main/pokegear_main.c",
    "src/easy_chat.c",
    "src/mail_misc.c",
    "include/easy_chat.h",
    "include/constants/easy_chat.h",
  },
  rom = { version = "heartgold", sha1 = "4fcded0e2713dc03929845de631d0932ea2b5a37" },
}

-- Only HeartGold selectors are verified; SoulSilver stays unverified per
-- the evidence gate and fails loudly instead of compiling.
PokegearWordEntrySources.versions = { heartgold = true }

-- Overlay 102 carries the word-entry entrypoints: EasyChat_Init at
-- 0x021E7740, EasyChat_Main at 0x021E77B8, EasyChat_Exit at 0x021E7868.
PokegearWordEntrySources.overlay = {
  fileId = 102,
  ramBase = 0x021E7740,
  rawSize = 15776,
  decodedSize = 20992,
  rawSha1 = "fb977aebd02f232c740997fb83b9a6939fdf7690",
  decodedSha1 = "1d413da9b4baaf07c57d59d57f6cfe439c34c422",
}

-- Graphics archive a/0/7/6: seventeen members, four bound by the selector
-- sprite loaders (mapping loaded twice, partial palette into slots 1..2),
-- background screen member 0 and character member 1 behind layers 0 and 4.
PokegearWordEntrySources.graphics = {
  path = "a/0/7/6",
  fileId = 205,
  memberCount = 17,
  narcSha1 = "37597f1e881777bbaf5817c5d598ca8b450a414f",
  members = { cell = 7, animation = 8, mapping = 9, palette = 10 },
  background = { screenMember = 0, charMember = 1, layers = { 0, 4 } },
}

-- Message archive a/0/2/7: the three interface banks behind the selector
-- windows plus the eleven word banks shared with the PC dictionary. Word
-- identities are decimal strings from the cumulative group base; the null
-- word renders empty and is never selectable.
PokegearWordEntrySources.messages = {
  path = "a/0/2/7",
  fileId = 156,
  narcSha1 = "dda4290205ead8920b6a5c0e9c9a81d368925f7a",
  interfaceBanks = { 282, 283, 284 },
}

-- Group order is the fixed source order 0..10 with message-bank order
-- inside each group; no sort routine runs in the single-word path and no
-- save or Dex fact gates any word.
PokegearWordEntrySources.wordBanks = {
  { messageBank = 237, firstWordId = 0, wordCount = 496 },
  { messageBank = 751, firstWordId = 496, wordCount = 468 },
  { messageBank = 735, firstWordId = 964, wordCount = 18 },
  { messageBank = 721, firstWordId = 982, wordCount = 124 },
  { messageBank = 285, firstWordId = 1106, wordCount = 38 },
  { messageBank = 286, firstWordId = 1144, wordCount = 38 },
  { messageBank = 287, firstWordId = 1182, wordCount = 107 },
  { messageBank = 288, firstWordId = 1289, wordCount = 104 },
  { messageBank = 289, firstWordId = 1393, wordCount = 47 },
  { messageBank = 290, firstWordId = 1440, wordCount = 32 },
  { messageBank = 291, firstWordId = 1472, wordCount = 23 },
}

PokegearWordEntrySources.groupCount = 11
PokegearWordEntrySources.nullWord = 0xFFFF

-- Five touch hitboxes with touch-held tracking; the drag path clamps touch
-- Y; every handled case plays the confirm sound.
PokegearWordEntrySources.input = {
  hitboxes = 5,
  touchYMin = 0x1C,
  touchYMax = 0xE2,
  confirmSound = 1500,
}

-- Palette fade open with its finish gate; heaps, font slot, and string
-- slot behind the selector text.
PokegearWordEntrySources.presentation = {
  heaps = { 0x22, 0x23 },
  fontSlot = 2,
  stringSlot = 0x15,
  fade = { 0, 0, 0, 0, 5, 1, 0x23 },
}

---@param versionId string
function PokegearWordEntrySources.checkVersion(versionId)
  assert(type(versionId) == "string" and versionId ~= "", "word-entry selectors need a game version")
  assert(
    PokegearWordEntrySources.versions[versionId] == true,
    "word-entry selectors name a supported game version, got " .. versionId
  )
end

-- Version-qualified word bank records for one game version. Returns
-- detached copies; mutating them never touches the producer table.
---@param versionId string
---@return table<integer, table<string, integer>>
function PokegearWordEntrySources.wordBankRecords(versionId)
  PokegearWordEntrySources.checkVersion(versionId)
  local records = {}
  for _, entry in ipairs(PokegearWordEntrySources.wordBanks) do
    records[#records + 1] =
      { messageBank = entry.messageBank, firstWordId = entry.firstWordId, wordCount = entry.wordCount }
  end
  assert(#records == PokegearWordEntrySources.groupCount, "word bank records cover every source group")
  return records
end

return PokegearWordEntrySources
