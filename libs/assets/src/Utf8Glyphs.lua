-- Iterates the UTF-8 glyphs of a string: the leading byte determines the
-- sequence width (1..4 bytes), matching the generated field font's text
-- iteration, and a truncated final sequence yields the remaining bytes. The
-- one tiny shared iterator for player-name validation, text measurement, and
-- rendering, so no consumer ever iterates text bytes again. Pure module: no
-- love dependency, no generalized Unicode library.

local Utf8Glyphs = {}

-- Replaces invalid UTF-8 sequences and C0 controls for display. Valid
-- multi-byte sequences pass through unchanged; a truncated tail, a bad
-- continuation byte, an overlong/surrogate/out-of-range sequence, and any
-- C0/DEL control becomes "?". Pure display policy: the source pathname
-- is never mutated, only its on-screen receipt.

-- The one iterator: yields every full glyph substring in order.
---@param text string
---@return fun(): string?
function Utf8Glyphs.iter(text)
  assert(type(text) == "string", "Utf8Glyphs.iter requires a string")
  local position = 1
  local function nextGlyph()
    if position > #text then
      return nil
    end
    local byte = text:byte(position)
    local width = byte < 0x80 and 1 or byte < 0xE0 and 2 or byte < 0xF0 and 3 or 4
    local glyph = text:sub(position, math.min(position + width - 1, #text))
    position = position + width
    return glyph
  end
  return nextGlyph
end

---@param text string
---@return string sanitized display text with only valid UTF-8 and no C0 controls
function Utf8Glyphs.sanitize(text)
  if type(text) ~= "string" or text == "" then
    return ""
  end
  local out = {}
  local i, n = 1, #text
  while i <= n do
    local b = text:byte(i)
    if b < 0x80 then
      if b < 0x20 or b == 0x7F then
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

-- Sanitizes then truncates to a byte budget on a glyph boundary, appending
-- an ellipsis only when truncation occurred. The ellipsis itself is valid
-- UTF-8, so every measured prefix stays measurable by LÖVE font metrics.
---@param text string
---@param maxBytes integer
---@return string
function Utf8Glyphs.truncate(text, maxBytes)
  local clean = Utf8Glyphs.sanitize(text)
  if #clean <= maxBytes then
    return clean
  end
  local ellipsis = "…"
  local budget = maxBytes - 1
  if budget < 0 then
    budget = 0
  end
  -- Keep the historical 47 + ellipsis shape for a 48-byte receipt row.
  local prefixBudget = math.max(0, math.min(budget, 47))
  local bytes, parts = 0, {}
  for glyph in Utf8Glyphs.iter(clean) do
    if bytes + #glyph > prefixBudget then
      break
    end
    parts[#parts + 1] = glyph
    bytes = bytes + #glyph
  end
  return table.concat(parts) .. ellipsis
end

return Utf8Glyphs
