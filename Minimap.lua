SPP.Minimap = SPP.Minimap or {}

local MINIMAP_RADIUS = 5
local MINIMAP_SHAPES = {
  ROUND = { true, true, true, true },
  SQUARE = { false, false, false, false },
  ["CORNER-TOPLEFT"] = { false, false, false, true },
  ["CORNER-TOPRIGHT"] = { false, false, true, false },
  ["CORNER-BOTTOMLEFT"] = { false, true, false, false },
  ["CORNER-BOTTOMRIGHT"] = { true, false, false, false },
  ["SIDE-LEFT"] = { false, true, false, true },
  ["SIDE-RIGHT"] = { true, false, true, false },
  ["SIDE-TOP"] = { false, false, true, true },
  ["SIDE-BOTTOM"] = { true, true, false, false }
}

function SPP.Minimap:GetPosition(position, width, height, shape)
  local angle = math.rad(position or 220)
  local x, y = math.cos(angle), math.sin(angle)
  local quadrant = 1
  if x < 0 then quadrant = quadrant + 1 end
  if y > 0 then quadrant = quadrant + 2 end
  local shapeRules = MINIMAP_SHAPES[shape or "ROUND"] or MINIMAP_SHAPES.ROUND
  local halfWidth = (width or 140) / 2 + MINIMAP_RADIUS
  local halfHeight = (height or 140) / 2 + MINIMAP_RADIUS
  if shapeRules[quadrant] then return x * halfWidth, y * halfHeight end
  local diagonalWidth = math.sqrt(2 * halfWidth * halfWidth) - 10
  local diagonalHeight = math.sqrt(2 * halfHeight * halfHeight) - 10
  return math.max(-halfWidth, math.min(x * diagonalWidth, halfWidth)),
    math.max(-halfHeight, math.min(y * diagonalHeight, halfHeight))
end

local function updatePosition(button)
  local shape = GetMinimapShape and GetMinimapShape() or "ROUND"
  local x, y = SPP.Minimap:GetPosition(
    ColeProfessionPlannerDB.minimapAngle, Minimap:GetWidth(), Minimap:GetHeight(), shape
  )
  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

function SPP.Minimap:Create()
  if self.button or not Minimap then return end
  local button = CreateFrame("Button", "ColeProfessionPlannerMinimapButton", Minimap)
  self.button = button
  button:SetSize(31, 31)
  button:SetFrameStrata("MEDIUM")
  button:SetFrameLevel(8)
  button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  button:RegisterForDrag("LeftButton")
  button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local background = button:CreateTexture(nil, "BACKGROUND")
  background:SetSize(20, 20)
  background:SetPoint("TOPLEFT", 7, -5)
  background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  local icon = button:CreateTexture(nil, "ARTWORK")
  icon:SetSize(17, 17)
  icon:SetPoint("TOPLEFT", 7, -6)
  icon:SetTexture("Interface\\AddOns\\ColeProfessionPlanner\\Media\\ColeIcon.tga")
  icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
  button.icon = icon
  local border = button:CreateTexture(nil, "OVERLAY")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  button.border = border

  button:SetScript("OnClick", function(_, mouseButton)
    if mouseButton == "RightButton" then
      ColeProfessionPlannerDB.hideMinimap = true
      button:Hide()
      print("|cff75c94fCole:|r minimap icon hidden. Use /cole minimap to restore it.")
    else
      SPP.UI:Toggle()
    end
  end)
  button:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", function()
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    local cursorX, cursorY = GetCursorPosition()
    ColeProfessionPlannerDB.minimapAngle = math.deg((math.atan2 or atan2)(cursorY / scale - my, cursorX / scale - mx))
    updatePosition(self)
  end) end)
  button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Cole Profession Planner")
    GameTooltip:AddLine("Left click: open planner", 1, 1, 1)
    GameTooltip:AddLine("Right click: hide icon", 1, 1, 1)
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", function() GameTooltip:Hide() end)
  updatePosition(button)
  button:SetShown(not ColeProfessionPlannerDB.hideMinimap)
end

function SPP.Minimap:Show()
  ColeProfessionPlannerDB.hideMinimap = false
  self:Create()
  if self.button then self.button:Show() end
end
