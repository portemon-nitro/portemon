-- Shared compiled Mail template checks for composition admission and
-- stored line display. Counts substitution slots, admits composed
-- letters, and expands stored lines through the compiled dictionary.
local Mail = require("libs.mons.src.gen4.Mail")

local MailTemplate = {}

local function countTokens(tokens)
  assert(type(tokens) == "table", "mail template is a token array")
  local count = 0
  for _, token in ipairs(tokens) do
    if type(token) ~= "table" or type(token.kind) ~= "string" then
      error("mail template token has its compiled shape", 0)
    end
    if token.kind == "substitution" then
      count = count + 1
    end
  end
  return count
end

-- Returns the compiled template and its substitution count for a stored
-- line, or nil when the line has no usable template or breaks the two
-- stored word-field shape. Malformed token shape stays a raised error.
local function inspectLine(line, templates)
  if type(line) ~= "table" or type(line.words) ~= "table" then
    return nil, nil
  end
  if type(templates) ~= "table" then
    return nil, nil
  end
  local template = templates[line.template]
  if type(template) ~= "table" then
    return nil, nil
  end
  local substitutions = countTokens(template)
  if #line.words ~= 2 then
    return nil, nil
  end
  if substitutions > 2 then
    return nil, nil
  end
  return template, substitutions
end

---@param tokens table[] the compiled template token array
---@return integer count of substitution slots
function MailTemplate.substitutionCount(tokens)
  return countTokens(tokens)
end

---@param letter table<string, unknown> the composed Mail record
---@param mailText table<string, unknown> the compiled template text carrying templates
---@param dictionary table<string, unknown> the compiled word dictionary
---@return boolean admitted
---@return string? reason "incomplete" for a missing required word, "invalid_letter" otherwise
function MailTemplate.checkComposed(letter, mailText, dictionary)
  if not pcall(Mail.validate, letter) then
    return false, "invalid_letter"
  end
  local templates = type(mailText) == "table" and mailText.templates or nil
  if type(templates) ~= "table" or type(dictionary) ~= "table" then
    return false, "invalid_letter"
  end
  for _, line in ipairs(letter.lines) do
    if line ~= false then
      local _, substitutions = inspectLine(line, templates)
      if substitutions == nil then
        return false, "invalid_letter"
      end
      for position = 1, substitutions do
        local wordKey = line.words[position]
        if wordKey == false then
          return false, "incomplete"
        end
        if dictionary[wordKey] == nil then
          return false, "invalid_letter"
        end
      end
      for position = substitutions + 1, #line.words do
        if line.words[position] ~= false then
          return false, "invalid_letter"
        end
      end
    end
  end
  return true
end

---@param line table<string, unknown> the stored Mail line
---@param mailText table<string, unknown> the compiled template text carrying templates
---@param dictionary table<string, unknown> the compiled word dictionary
---@return table[] detached expanded token list
function MailTemplate.expandLine(line, mailText, dictionary)
  assert(type(line) == "table", "stored mail line is a record")
  assert(type(mailText) == "table" and type(mailText.templates) == "table", "mail template text is compiled")
  local template = assert(mailText.templates[line.template], "stored mail template is present in the compiled text")
  assert(type(template) == "table", "mail template is a token array")
  local substitutions = countTokens(template)
  assert(type(line.words) == "table" and #line.words == 2, "stored mail keeps its two word fields")
  assert(substitutions <= 2, "mail template substitution slots fit the stored word fields")
  for position = substitutions + 1, #line.words do
    assert(line.words[position] == false, "trailing mail word fields stay empty")
  end
  assert(type(dictionary) == "table", "mail words are compiled")
  local tokens, wordIndex = {}, 0
  for _, token in ipairs(template) do
    if token.kind == "substitution" then
      wordIndex = wordIndex + 1
      local wordKey = line.words[wordIndex]
      if wordKey ~= false then
        local word = assert(dictionary[wordKey], "stored mail word is present in the compiled dictionary")
        for _, wordToken in ipairs(word) do
          tokens[#tokens + 1] = wordToken
        end
      end
    else
      tokens[#tokens + 1] = token
    end
  end
  assert(wordIndex == substitutions, "every template substitution consumes one stored word field")
  return tokens
end

return MailTemplate
