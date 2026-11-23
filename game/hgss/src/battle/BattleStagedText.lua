-- Decodes one staged battle message entry from the verified presentation
-- manifest into printable glyph text and its source printer controls.
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

local BattleStagedText = {}

---@class BattleStagedText.PrinterControls
---@field controls table<integer, table<string, unknown>> ordered source printer controls
---@field glyphCount integer rendered glyph count under substitution

---@param manifest table<string, unknown> planning manifest with staged message entries
---@param key string semantic message key
---@param substitutions string[] values for source string-variable tokens
---@param printerControls BattleStagedText.PrinterControls? collect source pause/callback controls
---@return string printable source message: glyphs and line breaks only
function BattleStagedText.decode(manifest, key, substitutions, printerControls)
  local messages = assert(manifest.messages, "battle narration requires staged message entries")
  local entries = assert(messages.entries, "battle narration requires semantic message entries")
  local record = assert(entries[key], "battle narration message is staged: " .. key)
  local sourceTokens = record.tokens --[[@as table<integer, table<string, unknown>>]]
  local out = {}
  local substitutionIndex = 1
  for _, token in ipairs(sourceTokens) do
    if token.kind == "eos" then
      break
    elseif token.kind == "glyph" then
      out[#out + 1] = token.text
      if printerControls ~= nil then
        for _ in Utf8Glyphs.iter(token.text) do
          printerControls.glyphCount = printerControls.glyphCount + 1
        end
      end
    elseif token.kind == "line_break" then
      out[#out + 1] = "\n"
      if printerControls ~= nil then
        printerControls.glyphCount = printerControls.glyphCount + 1
      end
    elseif token.kind == "substitution" then
      local substitution = assert(substitutions[substitutionIndex], "source message substitution is supplied: " .. key)
      out[#out + 1] = substitution
      if printerControls ~= nil then
        for _ in Utf8Glyphs.iter(substitution) do
          printerControls.glyphCount = printerControls.glyphCount + 1
        end
      end
      substitutionIndex = substitutionIndex + 1
    elseif printerControls ~= nil and token.kind == "pause" then
      printerControls.controls[#printerControls.controls + 1] = {
        glyphIndex = printerControls.glyphCount,
        kind = "pause",
        updates = assert(token.args and token.args[1], "pause tokens carry their update count"),
      }
    elseif printerControls ~= nil and token.kind == "printer_callback" then
      local callback = assert(token.args and token.args[1], "printer callbacks carry their source id")
      assert(callback >= 1 and callback <= 5, "evolution printer callback ids are source-defined")
      printerControls.controls[#printerControls.controls + 1] = {
        glyphIndex = printerControls.glyphCount,
        kind = "callback",
        callback = callback,
        wait = callback == 1 or callback == 2,
      }
    end
    -- Style, pause, printer-callback, continuation, page/prompt-break and
    -- focus tokens have no glyphs: narration paces itself on the timeline and
    -- the command child draws its own Yes/No choices.
  end
  assert(
    substitutionIndex == #substitutions + 1,
    "source message " .. key .. " consumes " .. (substitutionIndex - 1) .. " substitutions, got " .. #substitutions
  )
  return table.concat(out)
end

return BattleStagedText
