-- Strict closed semantic schemas for the shared Easy Chat family: the
-- data catalog (dictionary rows, templates, curated categories, authored
-- initials, interface text, password words, avatar tables) and the
-- presentation manifest (native layers, buttons, animation sequences,
-- palettes). Producer and writer boundaries use validate; warm runtime
-- reads trust the published receipt plus the cache loader identity.

local Contract = require("libs.assets.src.DerivedAssetContract")
local Errors = require("libs.errors.src.Errors")

local EasyChatAssetSchema = {
  CATALOG_SCHEMA = Contract.easyChat.catalogSchema,
  SCHEMA = Contract.easyChat.schema,
}

EasyChatAssetSchema.ERROR = {
  SCHEMA_MISMATCH = "EASY_CHAT_SCHEMA_MISMATCH",
  SHAPE_INVALID = "EASY_CHAT_SHAPE_INVALID",
  DUPLICATE_KEY = "EASY_CHAT_DUPLICATE_KEY",
  DANGLING_REFERENCE = "EASY_CHAT_DANGLING_REFERENCE",
}

---@param code string error identity
---@param message string
---@param context table<string, unknown>
---@return Errors.Error
local function fail(code, message, context)
  return Errors.new(code, message, context or {})
end

---@param value unknown
---@return boolean
local function isInteger(value)
  return type(value) == "number" and value % 1 == 0
end

---@param value unknown
---@return boolean
local function isDenseList(value)
  if type(value) ~= "table" then
    return false
  end
  local count = 0
  for key in pairs(value) do
    if not isInteger(key) or key < 1 then
      return false
    end
    count = count + 1
  end
  for index = 1, count do
    if value[index] == nil then
      return false
    end
  end
  return true
end

---@param tokens unknown
---@param label string
---@return Errors.Error?
local function checkTokens(tokens, label)
  if not isDenseList(tokens) then
    return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, label .. " carries no dense token stream", { label = label })
  end
  for index, token in ipairs(tokens) do
    if type(token) ~= "table" then
      return fail(
        EasyChatAssetSchema.ERROR.SHAPE_INVALID,
        label .. " token " .. index .. " is not a record",
        { label = label, index = index }
      )
    end
    if type(token.kind) ~= "string" or token.kind == "" then
      return fail(
        EasyChatAssetSchema.ERROR.SHAPE_INVALID,
        label .. " token " .. index .. " names no kind",
        { label = label, index = index }
      )
    end
  end
  return nil
end

---@param eligibility unknown
---@param label string
---@return Errors.Error?
local function checkEligibility(eligibility, label)
  if type(eligibility) ~= "table" then
    return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, label .. " carries no eligibility record", { label = label })
  end
  local kind = eligibility.kind
  if kind == "always" or kind == "gameClear" then
    return nil
  end
  if kind == "seen" then
    if type(eligibility.speciesKey) ~= "string" or eligibility.speciesKey == "" then
      return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, label .. " names no species key", { label = label })
    end
    return nil
  end
  if kind == "greeting" then
    if not isInteger(eligibility.bit) or eligibility.bit < 0 or eligibility.bit > 5 then
      return fail(
        EasyChatAssetSchema.ERROR.SHAPE_INVALID,
        label .. " names an out-of-range greeting bit",
        { label = label }
      )
    end
    return nil
  end
  if kind == "trendy" then
    if not isInteger(eligibility.bit) or eligibility.bit < 0 or eligibility.bit > 31 then
      return fail(
        EasyChatAssetSchema.ERROR.SHAPE_INVALID,
        label .. " names an out-of-range trendy bit",
        { label = label }
      )
    end
    return nil
  end
  return fail(
    EasyChatAssetSchema.ERROR.SHAPE_INVALID,
    label .. " names an unknown eligibility kind",
    { label = label, kind = kind }
  )
end

---@param data table<string, unknown>
---@param words table<integer, boolean> resolved word identities
---@return Errors.Error?
local function checkWordRows(data, words)
  local records = data.words
  if not isDenseList(records) then
    return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "catalog carries no dense word rows", {})
  end
  if #records ~= 1495 then
    return fail(
      EasyChatAssetSchema.ERROR.SHAPE_INVALID,
      "catalog carries " .. #records .. " word rows; expected 1495",
      { count = #records }
    )
  end
  for index = 1, #records do
    local record = records[index]
    if type(record) ~= "table" then
      return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "word row " .. index .. " is not a record", {})
    end
    if record.id ~= index - 1 then
      return fail(
        EasyChatAssetSchema.ERROR.SHAPE_INVALID,
        "word row " .. index .. " carries identity " .. tostring(record.id),
        {}
      )
    end
    if words[record.id] then
      return fail(EasyChatAssetSchema.ERROR.DUPLICATE_KEY, "word identity repeats " .. record.id, { id = record.id })
    end
    words[record.id] = true
    local tokenErr = checkTokens(record.tokens, "word " .. record.id)
    if tokenErr then
      return tokenErr
    end
    local eligibilityErr = checkEligibility(record.eligibility, "word " .. record.id)
    if eligibilityErr then
      return eligibilityErr
    end
  end
  return nil
end

---@param data table<string, unknown>
---@return Errors.Error?
local function checkTemplates(data)
  local templates = data.templates
  if not isDenseList(templates) then
    return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "catalog carries no dense templates", {})
  end
  if #templates ~= 100 then
    return fail(
      EasyChatAssetSchema.ERROR.SHAPE_INVALID,
      "catalog carries " .. #templates .. " templates; expected 100",
      { count = #templates }
    )
  end
  for index = 1, #templates do
    local template = templates[index]
    if type(template) ~= "table" then
      return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "template " .. index .. " is not a record", {})
    end
    local bank, number = math.floor((index - 1) / 20), (index - 1) % 20
    if template.bank ~= bank or template.number ~= number then
      return fail(
        EasyChatAssetSchema.ERROR.SHAPE_INVALID,
        "template " .. index .. " carries identity " .. tostring(template.bank) .. ":" .. tostring(template.number),
        {}
      )
    end
    if not isInteger(template.wordCount) or template.wordCount < 0 or template.wordCount > 2 then
      return fail(
        EasyChatAssetSchema.ERROR.SHAPE_INVALID,
        "template bank " .. bank .. " number " .. number .. " carries an invalid slot count",
        {}
      )
    end
    local tokenErr = checkTokens(template.tokens, "template bank " .. bank .. " number " .. number)
    if tokenErr then
      return tokenErr
    end
  end
  return nil
end

---@param wordId unknown
---@param words table<integer, boolean>
---@param label string
---@return Errors.Error?
local function checkWordRef(wordId, words, label)
  if not isInteger(wordId) or words[wordId] ~= true then
    return fail(
      EasyChatAssetSchema.ERROR.DANGLING_REFERENCE,
      label .. " references unknown word " .. tostring(wordId),
      { label = label, word = wordId }
    )
  end
  return nil
end

---@param data table<string, unknown>
---@param words table<integer, boolean>
---@return Errors.Error?
local function checkGroups(data, words)
  local groups = data.groups
  if not isDenseList(groups) then
    return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "catalog carries no dense categories", {})
  end
  if #groups ~= 12 then
    return fail(
      EasyChatAssetSchema.ERROR.SHAPE_INVALID,
      "catalog carries " .. #groups .. " categories; expected 12",
      { count = #groups }
    )
  end
  for index = 1, #groups do
    local group = groups[index]
    if type(group) ~= "table" then
      return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "category " .. index .. " is not a record", {})
    end
    if group.key ~= string.format("group%02d", index - 1) then
      return fail(
        EasyChatAssetSchema.ERROR.SHAPE_INVALID,
        "category " .. index .. " carries key " .. tostring(group.key),
        {}
      )
    end
    local tokenErr = checkTokens(group.labelTokens, "category " .. index .. " label")
    if tokenErr then
      return tokenErr
    end
    if not isDenseList(group.wordIds) then
      return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "category " .. index .. " carries no word list", {})
    end
    for _, wordId in ipairs(group.wordIds) do
      local refErr = checkWordRef(wordId, words, "category " .. index)
      if refErr then
        return refErr
      end
    end
  end
  return nil
end

---@param data table<string, unknown>
---@param words table<integer, boolean>
---@return Errors.Error?
local function checkInitials(data, words)
  local initials = data.initials
  if not isDenseList(initials) then
    return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "catalog carries no dense initial lists", {})
  end
  if #initials ~= 27 then
    return fail(
      EasyChatAssetSchema.ERROR.SHAPE_INVALID,
      "catalog carries " .. #initials .. " initial lists; expected 27",
      { count = #initials }
    )
  end
  for index = 1, #initials do
    local initial = initials[index]
    if type(initial) ~= "table" then
      return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "initial list " .. index .. " is not a record", {})
    end
    if initial.key ~= string.format("initial%02d", index - 1) then
      return fail(
        EasyChatAssetSchema.ERROR.SHAPE_INVALID,
        "initial list " .. index .. " carries key " .. tostring(initial.key),
        {}
      )
    end
    local tokenErr = checkTokens(initial.labelTokens, "initial list " .. index .. " label")
    if tokenErr then
      return tokenErr
    end
    if not isDenseList(initial.candidates) then
      return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "initial list " .. index .. " carries no candidates", {})
    end
    for _, candidate in ipairs(initial.candidates) do
      if type(candidate) == "table" then
        if not isDenseList(candidate) or #candidate == 0 then
          return fail(
            EasyChatAssetSchema.ERROR.SHAPE_INVALID,
            "initial list " .. index .. " carries an empty alternative group",
            {}
          )
        end
        for _, wordId in ipairs(candidate) do
          local refErr = checkWordRef(wordId, words, "initial list " .. index)
          if refErr then
            return refErr
          end
        end
      else
        local refErr = checkWordRef(candidate, words, "initial list " .. index)
        if refErr then
          return refErr
        end
      end
    end
  end
  return nil
end

---@param data table<string, unknown>
---@return Errors.Error?
local function checkGridCells(data)
  local cells = data.gridCells
  if type(cells) ~= "table" then
    return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "catalog carries no initial grid geometry", {})
  end
  if not isDenseList(cells) or #cells ~= 27 then
    return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "catalog carries no twenty-seven initial grid cells", {})
  end
  for index = 1, 27 do
    local cell = cells[index]
    if type(cell) ~= "table" then
      return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "grid cell " .. index .. " is not a record", {})
    end
    for _, field in ipairs({ "char", "x", "y", "up", "down", "left", "right", "belowBack", "aboveBack" }) do
      if not isInteger(cell[field]) then
        return fail(
          EasyChatAssetSchema.ERROR.SHAPE_INVALID,
          "grid cell " .. index .. " carries no integral " .. field,
          {}
        )
      end
    end
  end
  return nil
end

---@param data table<string, unknown>
---@param words table<integer, boolean>
---@return Errors.Error?
local function checkConsumers(data, words)
  local primoWords = data.primoWords
  if not isDenseList(primoWords) then
    return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "catalog carries no password word order", {})
  end
  if #primoWords ~= 351 then
    return fail(
      EasyChatAssetSchema.ERROR.SHAPE_INVALID,
      "catalog carries " .. #primoWords .. " password words; expected 351",
      { count = #primoWords }
    )
  end
  for _, wordId in ipairs(primoWords) do
    local refErr = checkWordRef(wordId, words, "password word")
    if refErr then
      return refErr
    end
  end
  local avatars = data.unionAvatars
  if type(avatars) ~= "table" then
    return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "catalog carries no avatar tables", {})
  end
  if not isDenseList(avatars.choices) or #avatars.choices ~= 8 then
    return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "catalog carries no eight avatar choice rows", {})
  end
  for row = 1, 8 do
    local choices = avatars.choices[row]
    if not isDenseList(choices) or #choices ~= 4 then
      return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "avatar choice row " .. row .. " offers no four entries", {})
    end
    for _, entry in ipairs(choices) do
      if not isInteger(entry) or entry < 0 or entry > 7 then
        return fail(
          EasyChatAssetSchema.ERROR.SHAPE_INVALID,
          "avatar choice row " .. row .. " carries an out-of-range entry",
          {}
        )
      end
    end
  end
  if not isDenseList(avatars.rows) or #avatars.rows ~= 16 then
    return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "catalog carries no sixteen avatar attribute rows", {})
  end
  for row = 1, 16 do
    local record = avatars.rows[row]
    if type(record) ~= "table" or not isInteger(record.spriteId) or not isInteger(record.classId) then
      return fail(
        EasyChatAssetSchema.ERROR.SHAPE_INVALID,
        "avatar attribute row " .. row .. " carries no sprite and class identities",
        {}
      )
    end
  end
  return nil
end

---@param data table<string, unknown>
---@return Errors.Error?
local function checkInterface(data)
  local interface = data.interface
  if type(interface) ~= "table" then
    return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "catalog carries no interface text", {})
  end
  local tokenErr = checkTokens(interface.categoryEmpty, "empty category label")
  if tokenErr then
    return tokenErr
  end
  if not isDenseList(interface.tabs) or #interface.tabs ~= 2 then
    return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "catalog carries no pair of tab labels", {})
  end
  for _, tokens in ipairs(interface.tabs) do
    local err = checkTokens(tokens, "tab label")
    if err then
      return err
    end
  end
  if not isDenseList(interface.buttons) or #interface.buttons ~= 3 then
    return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "catalog carries no triple of button labels", {})
  end
  for _, tokens in ipairs(interface.buttons) do
    local err = checkTokens(tokens, "button label")
    if err then
      return err
    end
  end
  if type(interface.prompts) ~= "table" then
    return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "catalog carries no prompt text", {})
  end
  for _, field in ipairs({ "answer", "incomplete", "quit" }) do
    local err = checkTokens(interface.prompts[field], field .. " prompt")
    if err then
      return err
    end
  end
  return nil
end

---@param catalog unknown
---@return table<string, unknown>?
---@return Errors.Error?
function EasyChatAssetSchema.validateCatalog(catalog)
  if type(catalog) ~= "table" then
    return nil, fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "catalog is not a table", {})
  end
  if catalog.schema ~= EasyChatAssetSchema.CATALOG_SCHEMA then
    return nil,
      fail(EasyChatAssetSchema.ERROR.SCHEMA_MISMATCH, "catalog schema is not current", { schema = catalog.schema })
  end
  if catalog.versionId ~= "heartgold" and catalog.versionId ~= "soulsilver" then
    return nil, fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "catalog names an unknown version", {})
  end
  local words = {}
  local err = checkWordRows(catalog, words)
    or checkGridCells(catalog)
    or checkTemplates(catalog)
    or checkGroups(catalog, words)
    or checkInitials(catalog, words)
    or checkConsumers(catalog, words)
    or checkInterface(catalog)
  if err then
    return nil, err
  end
  return catalog --[[@as table<string, unknown>]]
end

local LAYER_ROLES = {
  compositionMain = true,
  categories = true,
  backdrop = true,
  compositionSub = true,
  buttons = true,
  modeStates = true,
}

local BUTTON_ROLES = {
  confirm = true,
  cancel = true,
  quit = true,
}

---@param value unknown
---@param label string
---@return Errors.Error?
local function checkAssetPath(value, label)
  if type(value) ~= "string" or value:sub(1, #"assets/generated/easy-chat/") ~= "assets/generated/easy-chat/" then
    return fail(
      EasyChatAssetSchema.ERROR.SHAPE_INVALID,
      label .. " must reference an easy-chat-owned asset",
      { label = label }
    )
  end
  if value:sub(-4) ~= ".png" then
    return fail(
      EasyChatAssetSchema.ERROR.SHAPE_INVALID,
      label .. " must reference a generated PNG image",
      { label = label }
    )
  end
  return nil
end

---@param manifest table<string, unknown>
---@return Errors.Error?
local function checkLayers(manifest)
  if not isDenseList(manifest.layers) then
    return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "manifest carries no dense layers", {})
  end
  if #manifest.layers == 0 then
    return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "manifest carries no layers", {})
  end
  local seen = {}
  for _, layer in ipairs(manifest.layers) do
    if type(layer) ~= "table" then
      return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "layer is not a record", {})
    end
    if LAYER_ROLES[layer.role] ~= true then
      return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "layer names an unknown role " .. tostring(layer.role), {})
    end
    if seen[layer.role] then
      return fail(EasyChatAssetSchema.ERROR.DUPLICATE_KEY, "layer role repeats " .. tostring(layer.role), {})
    end
    seen[layer.role] = true
    local pathErr = checkAssetPath(layer.image, "layer " .. tostring(layer.role))
    if pathErr then
      return pathErr
    end
    if not isInteger(layer.width) or layer.width <= 0 or not isInteger(layer.height) or layer.height <= 0 then
      return fail(
        EasyChatAssetSchema.ERROR.SHAPE_INVALID,
        "layer " .. tostring(layer.role) .. " carries invalid dimensions",
        {}
      )
    end
  end
  return nil
end

---@param manifest table<string, unknown>
---@return Errors.Error?
local function checkSequences(manifest)
  if not isDenseList(manifest.sequences) then
    return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "manifest carries no dense sequences", {})
  end
  if #manifest.sequences == 0 then
    return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "manifest carries no sequences", {})
  end
  for _, sequence in ipairs(manifest.sequences) do
    if type(sequence) ~= "table" then
      return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "sequence is not a record", {})
    end
    if type(sequence.role) ~= "string" or sequence.role == "" then
      return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "sequence names no role", {})
    end
    if not isDenseList(sequence.frames) or #sequence.frames == 0 then
      return fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "sequence " .. sequence.role .. " carries no frames", {})
    end
    for _, frame in ipairs(sequence.frames) do
      if type(frame) ~= "table" then
        return fail(
          EasyChatAssetSchema.ERROR.SHAPE_INVALID,
          "sequence " .. sequence.role .. " frame is not a record",
          {}
        )
      end
      local pathErr = checkAssetPath(frame.image, "sequence " .. sequence.role .. " frame")
      if pathErr then
        return pathErr
      end
      if not isInteger(frame.duration) or frame.duration <= 0 then
        return fail(
          EasyChatAssetSchema.ERROR.SHAPE_INVALID,
          "sequence " .. sequence.role .. " frame carries invalid timing",
          {}
        )
      end
      if not isInteger(frame.originX) or not isInteger(frame.originY) then
        return fail(
          EasyChatAssetSchema.ERROR.SHAPE_INVALID,
          "sequence " .. sequence.role .. " frame carries no anchor facts",
          {}
        )
      end
    end
  end
  return nil
end

---@param manifest unknown
---@return table<string, unknown>?
---@return Errors.Error?
function EasyChatAssetSchema.validateManifest(manifest)
  if type(manifest) ~= "table" then
    return nil, fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "manifest is not a table", {})
  end
  if manifest.schema ~= EasyChatAssetSchema.SCHEMA then
    return nil,
      fail(EasyChatAssetSchema.ERROR.SCHEMA_MISMATCH, "manifest schema is not current", { schema = manifest.schema })
  end
  if manifest.versionId ~= "heartgold" and manifest.versionId ~= "soulsilver" then
    return nil, fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "manifest names an unknown version", {})
  end
  local err = checkLayers(manifest) or checkSequences(manifest)
  if err then
    return nil, err
  end
  if not isDenseList(manifest.buttons) then
    return nil, fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "manifest carries no dense buttons", {})
  end
  for _, button in ipairs(manifest.buttons) do
    if type(button) ~= "table" or BUTTON_ROLES[button.role] ~= true then
      return nil,
        fail(
          EasyChatAssetSchema.ERROR.SHAPE_INVALID,
          "manifest button names an unknown role " .. tostring(type(button) == "table" and button.role),
          {}
        )
    end
  end
  if not isDenseList(manifest.palettes) then
    return nil, fail(EasyChatAssetSchema.ERROR.SHAPE_INVALID, "manifest carries no dense palettes", {})
  end
  return manifest --[[@as table<string, unknown>]]
end

return EasyChatAssetSchema
