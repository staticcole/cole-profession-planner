SPP.Map = SPP.Map or {}

local function showWorldMap(mapId)
  if not WorldMapFrame and UIParentLoadAddOn then pcall(UIParentLoadAddOn, "Blizzard_WorldMap") end
  if not WorldMapFrame then return false end
  if not WorldMapFrame:IsShown() then
    if ToggleWorldMap then
      pcall(ToggleWorldMap)
    elseif ShowUIPanel then
      pcall(ShowUIPanel, WorldMapFrame)
    end
  end
  if WorldMapFrame.SetMapID then
    return pcall(WorldMapFrame.SetMapID, WorldMapFrame, mapId)
  end
  if WorldMapFrame.NavigateToMap then
    return pcall(WorldMapFrame.NavigateToMap, WorldMapFrame, mapId)
  end
  return false
end

local function sourceTitle(source, includeLocation, includeCoordinates)
  local S = SPP.S
  local title = source[S.NPC_NAME] or source[S.NAME] or "Recipe source"
  local location = source[S.LOCATION]
  if includeLocation and location and location ~= "N/A" then title = title .. " - " .. location end
  if includeCoordinates and source[S.X] and source[S.Y] then
    title = title .. string.format(" (%.1f, %.1f)", source[S.X], source[S.Y])
  end
  return title
end

local function vectorXY(vector)
  if not vector then return nil end
  if vector.GetXY then return vector:GetXY() end
  return vector.x, vector.y
end

function SPP.Map:GetSourceDistance(source)
  if not C_Map or not C_Map.GetBestMapForUnit or not C_Map.GetPlayerMapPosition then return nil end
  local playerMapId = C_Map.GetBestMapForUnit("player")
  local playerPosition = playerMapId and C_Map.GetPlayerMapPosition(playerMapId, "player") or nil
  local sourceMapId, x, y = source[SPP.S.MAP_ID], source[SPP.S.X], source[SPP.S.Y]
  if not playerPosition or not sourceMapId or not x or not y then return nil end

  if C_Map.GetWorldPosFromMapPos and CreateVector2D then
    local playerContinent, playerWorld = C_Map.GetWorldPosFromMapPos(playerMapId, playerPosition)
    local sourceContinent, sourceWorld = C_Map.GetWorldPosFromMapPos(sourceMapId, CreateVector2D(x / 100, y / 100))
    if playerContinent and playerContinent == sourceContinent and playerWorld and sourceWorld then
      local playerX, playerY = vectorXY(playerWorld)
      local sourceX, sourceY = vectorXY(sourceWorld)
      if playerX and sourceX then
        return math.sqrt(((sourceX - playerX) ^ 2) + ((sourceY - playerY) ^ 2)), "yd"
      end
    end
  end

  if playerMapId == sourceMapId then
    local playerX, playerY = vectorXY(playerPosition)
    if playerX then
      return math.sqrt(((x / 100 - playerX) ^ 2) + ((y / 100 - playerY) ^ 2)) * 100, "% map"
    end
  end
  return nil
end

function SPP.Map:OpenSource(source)
  if not source then return false, "This source has no map location" end
  local S = SPP.S
  local mapId, x, y = source[S.MAP_ID], source[S.X], source[S.Y]
  if not mapId then return false, "This source has no map location" end
  local title = sourceTitle(source, false, false)
  if TomTom and TomTom.AddWaypoint and x and y then
    TomTom:AddWaypoint(mapId, x / 100, y / 100, {
      title = title, persistent = false, minimap = true, world = true, crazy = true
    })
  end
  local mapOpened = showWorldMap(mapId)
  if x and y then
    local suffix = TomTom and " (TomTom waypoint added)" or mapOpened and "" or " (open the world map manually)"
    return true, string.format("%s: %.1f, %.1f%s", title, x, y, suffix)
  end
  return true, title
end

function SPP.Map:CreateSourcePicker()
  if self.picker then return self.picker end
  local picker = CreateFrame("Frame", "ColeProfessionPlannerSourcePicker", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  self.picker = picker
  picker:SetSize(560, 440)
  picker:SetPoint("CENTER")
  picker:SetFrameStrata("FULLSCREEN_DIALOG")
  picker:SetClampedToScreen(true)
  picker:EnableMouse(true)
  picker:EnableMouseWheel(true)
  picker:SetMovable(true)
  picker:RegisterForDrag("LeftButton")
  picker:SetScript("OnDragStart", picker.StartMoving)
  picker:SetScript("OnDragStop", picker.StopMovingOrSizing)
  picker:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", edgeSize = 24,
    insets = { left = 8, right = 8, top = 8, bottom = 8 }
  })
  picker:SetBackdropColor(0.025, 0.03, 0.025, 1)
  local solidBackground = picker:CreateTexture(nil, "BACKGROUND")
  solidBackground:SetPoint("TOPLEFT", 9, -9)
  solidBackground:SetPoint("BOTTOMRIGHT", -9, 9)
  solidBackground:SetTexture("Interface\\Buttons\\WHITE8X8")
  solidBackground:SetVertexColor(0.012, 0.016, 0.012, 1)
  picker.solidBackground = solidBackground
  local title = picker:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 18, -18)
  picker.title = title
  local close = CreateFrame("Button", nil, picker, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -5, -5)
  picker.rows = {}
  for index = 1, 10 do
    local row = CreateFrame("Button", nil, picker)
    row:SetHeight(34)
    row:SetPoint("TOPLEFT", 16, -48 - ((index - 1) * 36))
    row:SetPoint("TOPRIGHT", -16, -48 - ((index - 1) * 36))
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.background = row:CreateTexture(nil, "BACKGROUND")
    row.background:SetAllPoints()
    row.background:SetTexture("Interface\\Buttons\\WHITE8X8")
    row.background:SetVertexColor(index % 2 == 0 and 0.08 or 0.045, index % 2 == 0 and 0.095 or 0.055, index % 2 == 0 and 0.08 or 0.045, 0.98)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("TOPLEFT", 8, -4)
    row.name:SetPoint("RIGHT", -98, 0)
    row.name:SetJustifyH("LEFT")
    row.details = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.details:SetPoint("BOTTOMLEFT", 8, 4)
    row.details:SetPoint("RIGHT", -98, 0)
    row.details:SetJustifyH("LEFT")
    row.distance = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.distance:SetPoint("RIGHT", -8, 0)
    row.distance:SetWidth(84)
    row.distance:SetJustifyH("RIGHT")
    row:SetScript("OnClick", function(selected)
      picker:Hide()
      local _, message = SPP.Map:OpenSource(selected.source)
      if message then print("|cff75c94fCole:|r " .. message) end
    end)
    picker.rows[index] = row
  end
  picker.count = picker:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  picker.count:SetPoint("BOTTOMRIGHT", -20, 15)
  picker:SetScript("OnMouseWheel", function(_, delta)
    local maxOffset = math.max(0, #(SPP.Map.pickerEntries or {}) - #picker.rows)
    SPP.Map.pickerOffset = math.max(0, math.min(maxOffset, (SPP.Map.pickerOffset or 0) - delta * 3))
    SPP.Map:UpdateSourcePicker()
  end)
  picker:Hide()
  if UISpecialFrames then table.insert(UISpecialFrames, "ColeProfessionPlannerSourcePicker") end
  return picker
end

function SPP.Map:UpdateSourcePicker()
  local entries = self.pickerEntries or {}
  local offset = self.pickerOffset or 0
  for index, row in ipairs(self.picker.rows) do
    local entry = entries[offset + index]
    if not entry then
      row:Hide()
    else
      local source = entry.source
      row.source = source
      row.name:SetText(sourceTitle(source, false, false))
      local location = source[SPP.S.LOCATION] and source[SPP.S.LOCATION] ~= "N/A" and source[SPP.S.LOCATION] or "Unknown location"
      local coordinates = source[SPP.S.X] and string.format("  %.1f, %.1f", source[SPP.S.X], source[SPP.S.Y]) or ""
      row.details:SetText(location .. coordinates)
      row.distance:SetText(entry.distance and string.format("%.0f %s", entry.distance, entry.unit) or "")
      row:Show()
    end
  end
  local first = #entries > 0 and offset + 1 or 0
  local last = math.min(#entries, offset + #self.picker.rows)
  self.picker.count:SetText(string.format("%d-%d / %d", first, last, #entries))
end

function SPP.Map:ShowSourcePicker(recipe, sources)
  local picker = self:CreateSourcePicker()
  self.pickerEntries, self.pickerOffset = {}, 0
  local currentMapId = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player") or nil
  for _, source in ipairs(sources) do
    local distance, unit = self:GetSourceDistance(source)
    table.insert(self.pickerEntries, {
      source = source, distance = distance, unit = unit,
      currentMap = currentMapId and source[SPP.S.MAP_ID] == currentMapId or false
    })
  end
  table.sort(self.pickerEntries, function(a, b)
    if a.distance and b.distance and a.unit == b.unit then return a.distance < b.distance end
    if a.currentMap ~= b.currentMap then return a.currentMap end
    if (a.distance ~= nil) ~= (b.distance ~= nil) then return a.distance ~= nil end
    return sourceTitle(a.source, true, false) < sourceTitle(b.source, true, false)
  end)
  picker.title:SetText(recipe[SPP.R.NAME] .. " - choose source")
  self:UpdateSourcePicker()
  picker:Show()
  return true
end

function SPP.Map:OpenRecipeSources(recipe, maxExpansion, maxPhase)
  local sources = SPP.Data:GetMappableSources(recipe, maxExpansion, maxPhase)
  if #sources == 0 then return false, "This recipe has no mapped source in the selected phase" end
  if #sources == 1 then return self:OpenSource(sources[1]) end
  return self:ShowSourcePicker(recipe, sources)
end

function SPP.Map:GetTomTomCommand(source)
  if not source or not source[SPP.S.X] or not source[SPP.S.Y] then return nil end
  return string.format("/way %s %.1f %.1f %s", source[SPP.S.LOCATION] or "", source[SPP.S.X], source[SPP.S.Y], source[SPP.S.NPC_NAME] or "")
end
