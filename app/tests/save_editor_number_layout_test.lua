-- Compact numeric columns share one geometry for drawing and pointer input.

local Assert = require("tests.support.Assert")
local loaded, NumberLayout = pcall(require, "app.src.saveeditor.SaveEditorNumberLayout")

local T = { tests = {} }

local function overlaps(a, b)
  return a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height
end

function T.tests.range_sized_columns_fit_compact_and_wide_viewports()
  Assert.isTrue(loaded, "numeric layout must expose its pure resolve operation")
  Assert.isTrue(type(NumberLayout.resolve) == "function", "numeric layout exposes resolve")
  for _, count in ipairs({ 1, 3, 8, 10 }) do
    for _, viewport in ipairs({ { width = 256, height = 192 }, { width = 360, height = 640 }, { width = 1280, height = 720 } }) do
      local digits = {}
      for index = 1, count do
        digits[index] = index == 1 and "1" or "0"
      end
      local result = NumberLayout.resolve({
        available = { x = 0, y = 0, width = viewport.width, height = viewport.height },
        projection = { digitCount = count, digits = digits, selectedPlace = 0 },
        font = { lineHeight = 14, measure = function(text) return #text * 7 end },
        arrows = { width = 12, height = 12 },
        frame = { inset = 8, actionHeight = 34, errorHeight = 16, actionGap = 4 },
      })

      Assert.equal(#result.columns, count, "every range digit owns an arrow column")
      Assert.isTrue(result.bodyRect.width < viewport.width, "the number dialog stays sized to its content")
      for _, actionRect in ipairs({ result.confirmRect, result.backRect, result.errorRect }) do
        Assert.isTrue(actionRect.x >= result.bodyRect.x and actionRect.x + actionRect.width <= result.bodyRect.x + result.bodyRect.width)
        Assert.isTrue(actionRect.y >= result.bodyRect.y and actionRect.y + actionRect.height <= result.bodyRect.y + result.bodyRect.height)
      end
      for index, column in ipairs(result.columns) do
        Assert.equal(column.place, count - index, "display order maps to zero-based places")
        Assert.equal(column.digit, digits[index], "each column publishes its padded digit")
        Assert.isTrue(column.upRect.width > 0 and column.upRect.height > 0)
        Assert.isTrue(column.downRect.width > 0 and column.downRect.height > 0)
        Assert.isTrue(column.digitRect.width > 0 and column.digitRect.height > 0)
        Assert.isFalse(overlaps(column.upRect, column.digitRect), "digits stay below their upper arrows")
        Assert.isFalse(overlaps(column.digitRect, column.downRect), "digits stay above their lower arrows")
        for _, rect in ipairs({ column.upRect, column.digitRect, column.downRect }) do
          Assert.isTrue(rect.x >= result.bodyRect.x and rect.x + rect.width <= result.bodyRect.x + result.bodyRect.width)
          Assert.isTrue(rect.y >= result.bodyRect.y and rect.y + rect.height <= result.bodyRect.y + result.bodyRect.height)
        end
        if index < count then
          local nextColumn = result.columns[index + 1]
          Assert.equal(nextColumn.upRect.x - (column.upRect.x + column.upRect.width), 2, "columns use two-pixel gaps")
        end
      end
      Assert.isTrue(result.confirmRect.y > result.columns[1].downRect.y, "actions follow the digit strip")
      Assert.isTrue(result.errorRect.y > result.confirmRect.y, "validation has a reserved line below actions")
      if viewport.width == 1280 then
        Assert.isTrue(result.bodyRect.width < viewport.width / 2, "the modal does not span a wide page")
      end
    end
  end
end

function T.tests.measured_content_that_cannot_fit_reports_a_cancelable_geometry_result()
  Assert.isTrue(loaded, "numeric layout must expose its pure resolve operation")
  local result, reason = NumberLayout.resolve({
    available = { x = 24, y = 36, width = 44, height = 30 },
    projection = { digitCount = 10, digits = { "0", "0", "0", "0", "0", "0", "0", "0", "0", "0" }, selectedPlace = 0 },
    font = { lineHeight = 14, measure = function(text) return #text * 7 end },
    arrows = { width = 16, height = 16 },
    frame = { inset = 4, actionHeight = 34, errorHeight = 16, actionGap = 4 },
  })

  Assert.isNil(result, "measured content too small for readable controls has no numeric geometry")
  Assert.equal(reason, "too_small", "valid but insufficient content is an explicit layout outcome")
end

return T
