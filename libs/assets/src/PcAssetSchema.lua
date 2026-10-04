-- Strict source-independent manifest shape for the HGSS PC presentation.

local Contract = require("libs.assets.src.DerivedAssetContract")

local PcAssetSchema = { SCHEMA = Contract.pc.schema }

local function fail(message)
  error("invalid PC asset manifest: " .. message, 0)
end

local function exactKeys(value, allowed, label)
  if type(value) ~= "table" then
    fail(label .. " must be a record")
  end
  for key in pairs(value) do
    if not allowed[key] then
      fail(label .. " has unexpected key " .. tostring(key))
    end
  end
  for key in pairs(allowed) do
    if value[key] == nil then
      fail(label .. " is missing " .. key)
    end
  end
end

local function checkVisual(visual, label)
  exactKeys(visual, { image = true, width = true, height = true, anchorX = true, anchorY = true }, label)
  if type(visual.image) ~= "string" or visual.image:sub(1, #"assets/generated/pc/") ~= "assets/generated/pc/" then
    fail(label .. ".image must reference a PC-owned asset")
  end
  for _, key in ipairs({ "width", "height" }) do
    if type(visual[key]) ~= "number" or visual[key] % 1 ~= 0 or visual[key] <= 0 then
      fail(label .. "." .. key .. " must be a positive integer")
    end
  end
  for _, key in ipairs({ "anchorX", "anchorY" }) do
    if type(visual[key]) ~= "number" or visual[key] % 1 ~= 0 then
      fail(label .. "." .. key .. " must be an integer")
    end
  end
end

local function checkRenderedFrame(frame, label, requireDuration)
  if type(frame) ~= "table" then
    fail(label .. " must be a rendered frame")
  end
  local allowed = { image = true, width = true, height = true, anchorX = true, anchorY = true, duration = true }
  for key in pairs(frame) do
    if not allowed[key] then
      fail(label .. " has unexpected key " .. tostring(key))
    end
  end
  checkVisual({
    image = frame.image,
    width = frame.width,
    height = frame.height,
    anchorX = frame.anchorX,
    anchorY = frame.anchorY,
  }, label)
  if requireDuration and (type(frame.duration) ~= "number" or frame.duration % 1 ~= 0 or frame.duration <= 0) then
    fail(label .. ".duration must be positive ticks")
  end
  if frame.duration ~= nil and (type(frame.duration) ~= "number" or frame.duration % 1 ~= 0 or frame.duration <= 0) then
    fail(label .. ".duration must be positive ticks")
  end
end

local function checkVisualMap(value, label, count)
  if type(value) ~= "table" then
    fail(label .. " must be a record")
  end
  local seen = 0
  for key, child in pairs(value) do
    local childLabel = label .. "." .. tostring(key)
    if type(child) == "table" and child.image ~= nil then
      checkRenderedFrame(child, childLabel)
      seen = seen + 1
    elseif type(child) == "table" then
      seen = seen + checkVisualMap(child, childLabel)
    else
      fail(childLabel .. " must be a visual or visual map")
    end
  end
  if count ~= nil and seen ~= count then
    fail(label .. " has " .. seen .. " roles; expected " .. count)
  end
  return seen
end

local function checkWordDictionary(value)
  if type(value) ~= "table" then
    fail("mail.wordDictionary must be a record")
  end
  for wordId = 0, 1494 do
    local key = tostring(wordId)
    local tokens = value[key]
    if type(tokens) ~= "table" or #tokens == 0 then
      fail("mail.wordDictionary is missing source word " .. wordId)
    end
    for index, token in ipairs(tokens) do
      if type(token) ~= "table" or type(token.kind) ~= "string" then
        fail("mail.wordDictionary[" .. wordId .. "][" .. index .. "] is not a text token")
      end
    end
  end
  for wordId in pairs(value) do
    local numericWordId = type(wordId) == "string" and tonumber(wordId) or nil
    if
      numericWordId == nil
      or numericWordId % 1 ~= 0
      or numericWordId < 0
      or numericWordId > 1494
      or tostring(numericWordId) ~= wordId
    then
      fail("mail.wordDictionary contains an unsupported word key")
    end
  end
end

local function checkTextBanks(value)
  if type(value) ~= "table" then
    fail("text.banks must be a record")
  end
  for _, requiredBank in ipairs({ 0, 279 }) do
    if type(value[requiredBank]) ~= "table" then
      fail("text.banks is missing source bank " .. requiredBank)
    end
  end
  for bankId, bank in pairs(value) do
    if type(bankId) ~= "number" or bankId % 1 ~= 0 or bankId < 0 or type(bank) ~= "table" then
      fail("text.banks contains an invalid source bank")
    end
    local messageCount = 0
    for messageId, tokens in pairs(bank) do
      if type(messageId) ~= "number" or messageId % 1 ~= 0 or messageId < 0 or type(tokens) ~= "table" then
        fail("text.banks." .. bankId .. " contains an invalid message")
      end
      local tokenCount = 0
      for index, token in pairs(tokens) do
        if
          type(index) ~= "number"
          or index % 1 ~= 0
          or index < 1
          or type(token) ~= "table"
          or type(token.kind) ~= "string"
        then
          fail("text.banks." .. bankId .. "." .. messageId .. " contains an invalid token")
        end
        tokenCount = tokenCount + 1
      end
      if tokenCount == 0 or tokenCount ~= #tokens then
        fail("text.banks." .. bankId .. "." .. messageId .. " must contain source tokens")
      end
      for index = 1, tokenCount do
        if tokens[index] == nil then
          fail("text.banks." .. bankId .. "." .. messageId .. " has a missing token " .. index)
        end
      end
      messageCount = messageCount + 1
    end
    if messageCount == 0 then
      fail("text.banks." .. bankId .. " must contain source messages")
    end
    for messageId = 0, messageCount - 1 do
      if bank[messageId] == nil then
        fail("text.banks." .. bankId .. " has a missing message " .. messageId)
      end
    end
  end
end

local function checkTerminal(value)
  exactKeys(value, { animationTag = true, candidateBuildModelMembers = true, slots = true }, "terminal")
  if value.animationTag ~= 90 then
    fail("terminal.animationTag must be the source PC animation tag")
  end
  local members = value.candidateBuildModelMembers
  exactKeys(members, { [1] = true, [2] = true }, "terminal.candidateBuildModelMembers")
  if members[1] ~= 33 or members[2] ~= 138 then
    fail("terminal.candidateBuildModelMembers must preserve source prop order")
  end
  exactKeys(value.slots, { [0] = true, [1] = true }, "terminal.slots")
  for _, expected in ipairs({
    { slot = 0, role = "terminal.on" },
    { slot = 1, role = "terminal.off" },
  }) do
    local playback = value.slots[expected.slot]
    exactKeys(playback, { role = true, playMode = true }, "terminal.slots." .. expected.slot)
    if playback.role ~= expected.role or playback.playMode ~= "forward" then
      fail("terminal.slots." .. expected.slot .. " must be the source one-shot forward role")
    end
  end
end

local function checkMessageTokens(value, label)
  if type(value) ~= "table" or #value == 0 then
    fail(label .. " must contain compiled message tokens")
  end
  for index, token in ipairs(value) do
    if type(token) ~= "table" or type(token.kind) ~= "string" then
      fail(label .. "[" .. index .. "] is not a compiled message token")
    end
  end
end

local function checkMailTemplates(mailText, rootText)
  exactKeys(mailText, { sourceBanks = true, templates = true }, "mail.text")
  if type(mailText.sourceBanks) ~= "table" or #mailText.sourceBanks ~= 5 then
    fail("mail.text.sourceBanks must retain the five MailMessage bank identities")
  end
  if type(rootText) ~= "table" or type(rootText.banks) ~= "table" then
    fail("text.banks are required for compiled Mail templates")
  end
  local templates = mailText.templates
  if type(templates) ~= "table" then
    fail("mail.text.templates must be a record")
  end
  local expectedCount = 0
  for mailBankIndex, sourceBankId in ipairs(mailText.sourceBanks) do
    if type(sourceBankId) ~= "number" or sourceBankId % 1 ~= 0 or sourceBankId < 0 then
      fail("mail.text.sourceBanks must contain source bank identities")
    end
    local messages = rootText.banks[sourceBankId]
    if type(messages) ~= "table" or #messages == 0 then
      fail("mail.text.sourceBanks references an uncompiled message bank")
    end
    for messageIndex = 0, #messages - 1 do
      local key = "mail-template:" .. (mailBankIndex - 1) .. ":" .. messageIndex
      checkMessageTokens(templates[key], "mail.text.templates." .. key)
      expectedCount = expectedCount + 1
    end
  end
  local actualCount = 0
  for key, tokens in pairs(templates) do
    local bankIndex = type(key) == "string" and key:match("^mail%-template:(%d+):(%d+)$")
    if bankIndex == nil then
      fail("mail.text.templates contains an unsupported key")
    end
    checkMessageTokens(tokens, "mail.text.templates." .. key)
    actualCount = actualCount + 1
  end
  if actualCount ~= expectedCount then
    fail("mail.text.templates must contain every and only compiled source message")
  end
end

local function checkStationery(value)
  if type(value) ~= "table" then
    fail("mail.stationery must be a record")
  end
  local itemKeys = {
    "GRASS_MAIL",
    "FLAME_MAIL",
    "BUBBLE_MAIL",
    "BLOOM_MAIL",
    "TUNNEL_MAIL",
    "STEEL_MAIL",
    "HEART_MAIL",
    "SNOW_MAIL",
    "SPACE_MAIL",
    "AIR_MAIL",
    "MOSAIC_MAIL",
    "BRICK_MAIL",
  }
  local count = 0
  for stationeryType = 0, 11 do
    local stationery = value[stationeryType]
    exactKeys(stationery, { background = true, itemKey = true }, "mail.stationery." .. stationeryType)
    checkVisual(stationery.background, "mail.stationery." .. stationeryType .. ".background")
    if stationery.itemKey ~= itemKeys[stationeryType + 1] then
      fail("mail.stationery." .. stationeryType .. ".itemKey has an invalid semantic item key")
    end
    count = count + 1
  end
  for stationeryType in pairs(value) do
    if type(stationeryType) ~= "number" or stationeryType % 1 ~= 0 or stationeryType < 0 or stationeryType > 11 then
      fail("mail.stationery contains an unsupported type key")
    end
  end
  if count ~= 12 then
    fail("mail.stationery must contain twelve semantic stationery records")
  end
end

local function checkAnimationMap(value, label, count)
  if type(value) ~= "table" then
    fail(label .. " must be a record")
  end
  local seen = 0
  for animationId, animation in pairs(value) do
    if type(animationId) ~= "number" or animationId % 1 ~= 0 or animationId < 0 then
      fail(label .. " has a nonnumeric source animation key")
    end
    if type(animation) ~= "table" or type(animation.frames) ~= "table" or #animation.frames == 0 then
      fail(label .. "." .. animationId .. " must contain rendered frames")
    end
    for index, frame in ipairs(animation.frames) do
      checkRenderedFrame(frame, label .. "." .. animationId .. ".frames[" .. index .. "]", true)
    end
    seen = seen + 1
  end
  if seen ~= count then
    fail(label .. " has " .. seen .. " animations; expected " .. count)
  end
end

local function checkSequences(value, label)
  if type(value) ~= "table" then
    fail(label .. " must be a record")
  end
  for name, sequence in pairs(value) do
    exactKeys(sequence, { frames = true, loop = true }, label .. "." .. tostring(name))
    if type(sequence.frames) ~= "table" or #sequence.frames == 0 or type(sequence.loop) ~= "boolean" then
      fail(label .. "." .. tostring(name) .. " must carry frames and a loop flag")
    end
    for index, frame in ipairs(sequence.frames) do
      checkRenderedFrame(frame, label .. "." .. tostring(name) .. ".frames[" .. index .. "]", true)
    end
  end
end

---@param manifest unknown
function PcAssetSchema.assertManifest(manifest)
  if type(manifest) ~= "table" then
    fail("root must be a record")
  end
  local root = manifest --[[@as table<string, unknown>]]
  exactKeys(root, {
    schema = true,
    storage = true,
    mailbox = true,
    mail = true,
    photoAlbum = true,
    text = true,
    sequences = true,
    terminal = true,
  }, "root")
  if root.schema ~= PcAssetSchema.SCHEMA then
    fail("schema does not match " .. PcAssetSchema.SCHEMA)
  end
  local storage = root.storage --[[@as table<string, unknown>]]
  exactKeys(
    storage,
    { backgrounds = true, wallpapers = true, ui = true, boxNames = true, expansionNameFormat = true, geometry = true },
    "storage"
  )
  checkVisualMap(storage.backgrounds, "storage.backgrounds", 1)
  checkVisualMap(storage.wallpapers, "storage.wallpapers", 24)
  exactKeys(storage.ui, { boxPane = true, partyPane = true, windowFrames = true, markings = true }, "storage.ui")
  checkVisual(storage.ui.boxPane, "storage.ui.boxPane")
  checkVisual(storage.ui.partyPane, "storage.ui.partyPane")
  exactKeys(storage.ui.windowFrames, { standard = true, accent = true }, "storage.ui.windowFrames")
  for _, style in ipairs({ "standard", "accent" }) do
    local banks = storage.ui.windowFrames[style]
    exactKeys(banks, { paletteBank0 = true, paletteBank1 = true }, "storage.ui.windowFrames." .. style)
    for _, bank in ipairs({ "paletteBank0", "paletteBank1" }) do
      local frame = banks[bank]
      checkVisual(frame, "storage.ui.windowFrames." .. style .. "." .. bank)
      if frame.width ~= 96 or frame.height ~= 8 then
        fail("storage.ui.windowFrames." .. style .. "." .. bank .. " must preserve twelve 8x8 source cells")
      end
    end
  end
  local markingBits = {}
  for bit = 0, 5 do
    markingBits[bit] = true
  end
  exactKeys(storage.ui.markings, markingBits, "storage.ui.markings")
  for bit = 0, 5 do
    local pair = storage.ui.markings[bit]
    exactKeys(pair, { clear = true, set = true }, "storage.ui.markings." .. bit)
    for _, state in ipairs({ "clear", "set" }) do
      local visual = pair[state]
      checkVisual(visual, "storage.ui.markings." .. bit .. "." .. state)
      if visual.width ~= 8 or visual.height ~= 8 then
        fail("storage.ui.markings." .. bit .. "." .. state .. " must preserve one source tile")
      end
    end
  end
  if type(storage.boxNames) ~= "table" or #storage.boxNames ~= 18 then
    fail("storage.boxNames must carry the eighteen source labels")
  end
  exactKeys(
    storage.expansionNameFormat,
    { prefix = true, suffix = true, firstNumber = true },
    "storage.expansionNameFormat"
  )
  if
    type(storage.expansionNameFormat.prefix) ~= "string"
    or type(storage.expansionNameFormat.suffix) ~= "string"
    or type(storage.expansionNameFormat.firstNumber) ~= "number"
    or storage.expansionNameFormat.firstNumber % 1 ~= 0
  then
    fail("storage.expansionNameFormat must describe a source-derived ordinal label")
  end
  exactKeys(storage.geometry, { wallpaperMap = true }, "storage.geometry")
  exactKeys(storage.geometry.wallpaperMap, {
    width = true,
    height = true,
    columns = true,
    rows = true,
    tileIdWrap = true,
  }, "storage.geometry.wallpaperMap")
  if
    storage.geometry.wallpaperMap.width ~= 168
    or storage.geometry.wallpaperMap.height ~= 160
    or storage.geometry.wallpaperMap.columns ~= 21
    or storage.geometry.wallpaperMap.rows ~= 20
    or storage.geometry.wallpaperMap.tileIdWrap ~= 64
  then
    fail("storage.geometry.wallpaperMap does not match the source BG3 map")
  end

  local mailbox = root.mailbox --[[@as table<string, unknown>]]
  exactKeys(mailbox, { background = true, ui = true, geometry = true, pageSize = true }, "mailbox")
  checkVisualMap(mailbox.background, "mailbox.background", 1)
  checkVisualMap(mailbox.ui, "mailbox.ui")
  exactKeys(mailbox.geometry, { visibleLetters = true }, "mailbox.geometry")
  if mailbox.pageSize ~= 10 or mailbox.geometry.visibleLetters ~= 10 then
    fail("mailbox page size must retain ten source-visible records")
  end

  local mail = root.mail --[[@as table<string, unknown>]]
  exactKeys(mail, { stationery = true, geometry = true, text = true, wordDictionary = true }, "mail")
  checkStationery(mail.stationery)
  if type(mail.geometry) ~= "table" or type(mail.text) ~= "table" then
    fail("mail geometry and text records are required")
  end
  if
    mail.geometry.iconSlots ~= 3
    or type(mail.geometry.iconLocations) ~= "table"
    or #mail.geometry.iconLocations ~= 3
  then
    fail("mail geometry must retain its three source icon locations")
  end
  for index, point in ipairs(mail.geometry.iconLocations) do
    exactKeys(point, { x = true, y = true }, "mail.geometry.iconLocations[" .. index .. "]")
    if type(point.x) ~= "number" or point.x % 1 ~= 0 or type(point.y) ~= "number" or point.y % 1 ~= 0 then
      fail("mail.geometry.iconLocations[" .. index .. "] must use logical pixel coordinates")
    end
  end
  checkMailTemplates(mail.text, root.text)
  checkWordDictionary(mail.wordDictionary)

  local photoAlbum = root.photoAlbum --[[@as table<string, unknown>]]
  exactKeys(photoAlbum, { ui = true }, "photoAlbum")
  exactKeys(photoAlbum.ui, { sprites = true, animations = true, backgrounds = true }, "photoAlbum.ui")
  checkVisualMap(photoAlbum.ui.backgrounds, "photoAlbum.ui.backgrounds", 2)
  if type(photoAlbum.ui.sprites) ~= "table" or #photoAlbum.ui.sprites ~= 5 then
    fail("photoAlbum.ui.sprites must retain the five source sprite roles")
  end
  for index, sprite in ipairs(photoAlbum.ui.sprites) do
    exactKeys(
      sprite,
      { animationSpeed = true, initiallyAnimating = true, initiallyVisible = true },
      "photoAlbum.ui.sprites[" .. index .. "]"
    )
    if
      sprite.animationSpeed ~= 0x1000
      or type(sprite.initiallyAnimating) ~= "boolean"
      or type(sprite.initiallyVisible) ~= "boolean"
    then
      fail("photoAlbum.ui.sprites[" .. index .. "] has invalid source initial state")
    end
  end
  checkAnimationMap(photoAlbum.ui.animations, "photoAlbum.ui.animations", 10)
  exactKeys(root.text, { banks = true }, "text")
  checkTextBanks(root.text.banks)
  checkSequences(root.sequences, "sequences")
  checkTerminal(root.terminal)
end

---@param manifest unknown
---@return boolean
function PcAssetSchema.isValidManifest(manifest)
  return pcall(PcAssetSchema.assertManifest, manifest)
end

return PcAssetSchema
