-- Launcher-local display text normalization. Receipt and diagnostic strings
-- come from outside the product (POSIX filenames, picker URIs, worker
-- errors) and can contain invalid UTF-8 or C0 controls that make LÖVE font
-- metrics raise. The source pathname/URI is never mutated; only the
-- on-screen copy is sanitized. Private to the launcher; not a shared asset
-- contract.

local LauncherText = {}

-- Replaces invalid UTF-8 sequences and C0 controls (except newline) with
-- "?". Valid multi-byte sequences pass through unchanged. Newlines are
-- preserved so multi-line diagnostics keep their intentional breaks.
---@param text string
---@return string
function LauncherText.sanitize(text)
  if type(text) ~= "string" or text == "" then
    return ""
  end
  local out = {}
  local i, n = 1, #text
  while i <= n do
    local b = text:byte(i)
    if b < 0x80 then
      if b == 0x0A then
        out[#out + 1] = "\n"
      elseif b < 0x20 or b == 0x7F then
        out[#out + 1] = "?"
      else
        out[#out + 1] = text:sub(i, i)
      end
      i = i + 1
    elseif b >= 0xC2 and b <= 0xDF then
      if i + 1 <= n then
        local c2 = text:byte(i + 1)
        if c2 >= 0x80 and c2 <= 0xBF then
          out[#out + 1] = text:sub(i, i + 1)
          i = i + 2
        else
          out[#out + 1] = "?"
          i = i + 1
        end
      else
        out[#out + 1] = "?"
        i = i + 1
      end
    elseif b >= 0xE0 and b <= 0xEF then
      if i + 2 <= n then
        local c2, c3 = text:byte(i + 1, i + 2)
        local ok = c2 >= 0x80 and c2 <= 0xBF and c3 >= 0x80 and c3 <= 0xBF
        if b == 0xE0 then
          ok = ok and c2 >= 0xA0
        elseif b == 0xED then
          ok = ok and c2 <= 0x9F
        end
        if ok then
          out[#out + 1] = text:sub(i, i + 2)
          i = i + 3
        else
          out[#out + 1] = "?"
          i = i + 1
        end
      else
        out[#out + 1] = "?"
        i = i + 1
      end
    elseif b >= 0xF0 and b <= 0xF4 then
      if i + 3 <= n then
        local c2, c3, c4 = text:byte(i + 1, i + 3)
        local ok = c2 >= 0x80 and c2 <= 0xBF and c3 >= 0x80 and c3 <= 0xBF and c4 >= 0x80 and c4 <= 0xBF
        if b == 0xF0 then
          ok = ok and c2 >= 0x90
        elseif b == 0xF4 then
          ok = ok and c2 <= 0x8F
        end
        if ok then
          out[#out + 1] = text:sub(i, i + 3)
          i = i + 4
        else
          out[#out + 1] = "?"
          i = i + 1
        end
      else
        out[#out + 1] = "?"
        i = i + 1
      end
    else
      out[#out + 1] = "?"
      i = i + 1
    end
  end
  return table.concat(out)
end

-- Splits sanitized text into glyph substrings on codepoint boundaries.
---@param text string
---@return fun(): string?
local function glyphs(text)
  local position = 1
  return function()
    if position > #text then
      return nil
    end
    local byte = text:byte(position)
    local width = byte < 0x80 and 1 or byte < 0xE0 and 2 or byte < 0xF0 and 3 or 4
    local glyph = text:sub(position, math.min(position + width - 1, #text))
    position = position + width
    return glyph
  end
end

-- Fits display text to a pixel width on a codepoint boundary, appending an
-- ellipsis only when truncation occurred. Every measured candidate stays on
-- a glyph boundary so font metrics never see a byte midpoint. Single-row
-- callers must never paint a line break: embedded newlines (legal in POSIX
-- filenames) are folded to spaces here, while sanitize keeps them for
-- multi-line diagnostics.
---@param font love.Font
---@param text string
---@param width number
---@return string
function LauncherText.fitText(font, text, width)
  text = LauncherText.sanitize(tostring(text)):gsub("\n", " ")
  if font:getWidth(text) <= width then
    return text
  end
  local ellipsis = "…"
  local parts = {}
  for glyph in glyphs(text) do
    parts[#parts + 1] = glyph
  end
  local low, high = 0, #parts
  while low < high do
    local middle = math.ceil((low + high) / 2)
    local candidate = table.concat(parts, "", 1, middle) .. ellipsis
    if font:getWidth(candidate) <= width then
      low = middle
    else
      high = middle - 1
    end
  end
  return table.concat(parts, "", 1, low) .. ellipsis
end

return LauncherText
