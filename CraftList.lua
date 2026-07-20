SPP.CraftList = SPP.CraftList or {}

local LIST_NAME = "Cole Craft List"
local STORE_VERSION = 1
local UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

local function queue()
  ColeProfessionPlannerDB.craftShopping = ColeProfessionPlannerDB.craftShopping or {}
  return ColeProfessionPlannerDB.craftShopping
end

local function copyQuantities(source)
  local result = {}
  for itemId, quantity in pairs(source or {}) do
    if quantity and quantity > 0 then result[itemId] = quantity end
  end
  return result
end

local function hasEntries(value)
  return value and next(value) ~= nil
end

function SPP.CraftList:Initialize()
  ColeProfessionPlannerDB.craftShopping = ColeProfessionPlannerDB.craftShopping or {}
  if ColeProfessionPlannerDB.craftRecipesVersion ~= STORE_VERSION then
    if hasEntries(ColeProfessionPlannerDB.craftShopping) and not hasEntries(ColeProfessionPlannerDB.craftRecipes) then
      ColeProfessionPlannerDB.craftLegacyShopping = copyQuantities(ColeProfessionPlannerDB.craftShopping)
    end
    ColeProfessionPlannerDB.craftRecipes = ColeProfessionPlannerDB.craftRecipes or {}
    ColeProfessionPlannerDB.craftRecipesVersion = STORE_VERSION
  end
  ColeProfessionPlannerDB.craftRecipes = ColeProfessionPlannerDB.craftRecipes or {}
  return ColeProfessionPlannerDB.craftRecipes
end

local function recipeKey(recipe, mode)
  if recipe.key then return recipe.key end
  local identity = recipe.spellId or string.lower(recipe.name or "recipe")
  return (mode or recipe.mode or "trade") .. ":" .. identity
end

local function recipeIdFromLink(link)
  return link and tonumber(link:match("enchant:(%d+)") or link:match("spell:(%d+)")) or nil
end

local function itemIdFromLink(link, name)
  local itemId = link and tonumber(link:match("item:(%d+)")) or nil
  if itemId then return itemId end
  if C_Item and C_Item.GetItemInfoInstant then
    return select(1, C_Item.GetItemInfoInstant(link or name))
  end
  if GetItemInfoInstant then return select(1, GetItemInfoInstant(link or name)) end
end

local function craftQuantity(inputBox)
  if not inputBox then return 1 end
  local value = inputBox.GetNumber and inputBox:GetNumber()
    or inputBox.GetText and tonumber(inputBox:GetText())
  return math.max(1, math.floor(tonumber(value) or 1))
end

local function selectedTradeSkill()
  if not GetTradeSkillSelectionIndex or not GetTradeSkillNumReagents then return nil end
  local index = GetTradeSkillSelectionIndex()
  if not index or index <= 0 then return nil end
  local name, skillType = GetTradeSkillInfo(index)
  if not name or skillType == "header" then return nil end
  local reagents = {}
  for reagentIndex = 1, GetTradeSkillNumReagents(index) do
    local reagentName, _, quantity = GetTradeSkillReagentInfo(index, reagentIndex)
    local link = GetTradeSkillReagentItemLink and GetTradeSkillReagentItemLink(index, reagentIndex)
    local itemId = itemIdFromLink(link, reagentName)
    if itemId and quantity and quantity > 0 then
      table.insert(reagents, { itemId = itemId, quantity = quantity, name = reagentName })
    end
  end
  local recipeLink = GetTradeSkillRecipeLink and GetTradeSkillRecipeLink(index)
  return {
    name = name, crafts = craftQuantity(TradeSkillInputBox), reagents = reagents,
    spellId = recipeIdFromLink(recipeLink), icon = GetTradeSkillIcon and GetTradeSkillIcon(index)
  }
end

local function selectedCraft()
  if not GetCraftSelectionIndex or not GetCraftNumReagents then return nil end
  local index = GetCraftSelectionIndex()
  if not index or index <= 0 then return nil end
  local name, _, craftType = GetCraftInfo(index)
  if not name or craftType == "header" then return nil end
  local reagents = {}
  for reagentIndex = 1, GetCraftNumReagents(index) do
    local reagentName, _, quantity = GetCraftReagentInfo(index, reagentIndex)
    local link = GetCraftReagentItemLink and GetCraftReagentItemLink(index, reagentIndex)
    local itemId = itemIdFromLink(link, reagentName)
    if itemId and quantity and quantity > 0 then
      table.insert(reagents, { itemId = itemId, quantity = quantity, name = reagentName })
    end
  end
  local recipeLink = GetCraftRecipeLink and GetCraftRecipeLink(index)
  return {
    name = name, crafts = craftQuantity(CraftInputBox), reagents = reagents,
    spellId = recipeIdFromLink(recipeLink), icon = GetCraftIcon and GetCraftIcon(index)
  }
end

function SPP.CraftList:GetSelected(mode)
  local parent
  if mode == "craft" then parent = CraftFrame else parent = ProfessionsFrame or TradeSkillFrame end
  if parent and parent.IsShown and not parent:IsShown() then return nil end
  return mode == "craft" and selectedCraft() or selectedTradeSkill()
end

function SPP.CraftList:GetRecipes()
  return self:Initialize()
end

function SPP.CraftList:RebuildShopping()
  local shopping = copyQuantities(ColeProfessionPlannerDB.craftLegacyShopping)
  for _, recipe in ipairs(self:GetRecipes()) do
    local crafts = math.max(0, math.floor(tonumber(recipe.crafts) or 0))
    for _, reagent in ipairs(recipe.reagents or {}) do
      local quantity = (tonumber(reagent.quantity) or 0) * crafts
      if reagent.itemId and quantity > 0 then
        shopping[reagent.itemId] = (shopping[reagent.itemId] or 0) + quantity
      end
    end
  end
  ColeProfessionPlannerDB.craftShopping = shopping
  return shopping
end

function SPP.CraftList:AddRecipe(recipe, mode)
  if not recipe or not recipe.name then return false, "Select a recipe with reagents first" end
  if not recipe.reagents or #recipe.reagents == 0 then return false, recipe.name .. " has no purchasable reagents" end
  local recipes = self:GetRecipes()
  local key = recipeKey(recipe, mode)
  local entry
  for _, candidate in ipairs(recipes) do
    if candidate.key == key then entry = candidate break end
  end
  if not entry then
    entry = {
      key = key, name = recipe.name, mode = mode or recipe.mode or "trade",
      crafts = 0, icon = recipe.icon or UNKNOWN_ICON, spellId = recipe.spellId,
      reagents = recipe.reagents
    }
    table.insert(recipes, entry)
  else
    entry.reagents = recipe.reagents
    entry.icon = recipe.icon or entry.icon or UNKNOWN_ICON
  end
  entry.crafts = entry.crafts + math.max(1, math.floor(tonumber(recipe.crafts) or 1))
  self:RebuildShopping()
  self:UpdateButtons()
  self:UpdateManager()
  return true, entry
end

function SPP.CraftList:AdjustRecipe(key, delta)
  for _, recipe in ipairs(self:GetRecipes()) do
    if recipe.key == key then
      recipe.crafts = math.max(1, math.floor((tonumber(recipe.crafts) or 1) + delta))
      self:RebuildShopping()
      self:UpdateButtons()
      self:UpdateManager()
      return true
    end
  end
  return false
end

function SPP.CraftList:RemoveRecipe(key)
  local recipes = self:GetRecipes()
  for index, recipe in ipairs(recipes) do
    if recipe.key == key then
      table.remove(recipes, index)
      self:RebuildShopping()
      self:UpdateButtons()
      self:UpdateManager()
      return true
    end
  end
  return false
end

function SPP.CraftList:RemoveLegacyMaterials()
  ColeProfessionPlannerDB.craftLegacyShopping = nil
  self:RebuildShopping()
  self:UpdateButtons()
  self:UpdateManager()
end

function SPP.CraftList:GetRecipeStats()
  local recipeCount, craftCount = 0, 0
  for _, recipe in ipairs(self:GetRecipes()) do
    recipeCount = recipeCount + 1
    craftCount = craftCount + (tonumber(recipe.crafts) or 0)
  end
  return recipeCount, craftCount
end

function SPP.CraftList:GetStats()
  local itemCount, unitCount = 0, 0
  for _, quantity in pairs(queue()) do
    if quantity > 0 then
      itemCount = itemCount + 1
      unitCount = unitCount + quantity
    end
  end
  return itemCount, unitCount
end

function SPP.CraftList:AddSelected(mode)
  local recipe = self:GetSelected(mode)
  local ok, entryOrMessage = self:AddRecipe(recipe, mode)
  if not ok then return false, entryOrMessage end
  local itemCount = self:GetStats()
  return true, string.format("Added %s x%d to %s (%d materials)", recipe.name, recipe.crafts, LIST_NAME, itemCount)
end

function SPP.CraftList:Clear()
  ColeProfessionPlannerDB.craftShopping = {}
  ColeProfessionPlannerDB.craftRecipes = {}
  ColeProfessionPlannerDB.craftLegacyShopping = nil
  ColeProfessionPlannerDB.craftRecipesVersion = STORE_VERSION
  local api = Auctionator and Auctionator.API and Auctionator.API.v1
  if api and api.CreateShoppingList then pcall(api.CreateShoppingList, "ColeProfessionPlanner", LIST_NAME, {}) end
  self:UpdateButtons()
  self:UpdateManager()
  return true, LIST_NAME .. " cleared"
end

function SPP.CraftList:GetPlan()
  local required, relevant = {}, {}
  for itemId, quantity in pairs(queue()) do
    if quantity > 0 then
      required[itemId] = quantity
      relevant[itemId] = true
    end
  end
  local stock = SPP.Inventory:GetBagCounts()
  stock = SPP.Inventory:Merge(stock, SPP.Inventory:GetCurrentBankCounts(relevant))
  local shopping = {}
  for itemId, quantity in pairs(required) do
    local remaining = math.max(0, quantity - (stock[itemId] or 0))
    if remaining > 0 then shopping[itemId] = remaining end
  end
  return {
    profession = "craft-list", fromSkill = 0, toSkill = 0,
    shopping = shopping, craftShopping = true
  }
end

function SPP.CraftList:OpenAtAuctionHouse()
  local itemCount = self:GetStats()
  if itemCount == 0 then return false, LIST_NAME .. " is empty" end
  if not SPP.Auctionator:IsAuctionHouseOpen() then return false, "Open the Auction House first" end
  local plan = self:GetPlan()
  local rows = SPP.Auctionator:GetShoppingRows(plan, true)
  if #rows == 0 then return false, "Everything on the list is already owned or sold by vendors" end
  local created, createMessage = SPP.Auctionator:CreateList(plan, LIST_NAME)
  if not created then return false, createMessage end
  local searched, searchMessage = SPP.Auctionator:Search(plan)
  return searched, searched and ("Opened " .. LIST_NAME .. " in Auctionator") or searchMessage
end

local function managerLabel(parent, text, template)
  local value = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
  value:SetText(text or "")
  return value
end

local function managerButton(parent, text, width)
  local control = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  control:SetSize(width, 24)
  control:SetText(text)
  return control
end

local function setEnabled(control, enabled)
  control:SetEnabled(enabled and true or false)
  if control.SetAlpha then control:SetAlpha(enabled and 1 or 0.55) end
end

local function recipeMaterialsText(recipe)
  local parts = {}
  for index, reagent in ipairs(recipe.reagents or {}) do
    if index <= 3 then
      local name = reagent.name or SPP.Data:GetItemName(reagent.itemId)
      table.insert(parts, string.format("%s x%d", name, (reagent.quantity or 0) * (recipe.crafts or 0)))
    end
  end
  if #(recipe.reagents or {}) > 3 then table.insert(parts, "+" .. (#recipe.reagents - 3) .. " more") end
  return table.concat(parts, ", ")
end

function SPP.CraftList:GetManagerEntries()
  local result = {}
  for _, recipe in ipairs(self:GetRecipes()) do table.insert(result, recipe) end
  if hasEntries(ColeProfessionPlannerDB.craftLegacyShopping) then
    local itemCount, unitCount = 0, 0
    for _, quantity in pairs(ColeProfessionPlannerDB.craftLegacyShopping) do
      itemCount = itemCount + 1
      unitCount = unitCount + quantity
    end
    table.insert(result, {
      key = "legacy", legacy = true, name = "Previous material list",
      crafts = unitCount, icon = UNKNOWN_ICON,
      details = string.format("%d materials retained from the previous addon version", itemCount)
    })
  end
  return result
end

function SPP.CraftList:CreateManager()
  if self.managerFrame then return self.managerFrame end
  local frame = CreateFrame("Frame", "ColeProfessionPlannerCraftListFrame", UIParent,
    BackdropTemplateMixin and "BackdropTemplate" or nil)
  frame:SetSize(640, 500)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("FULLSCREEN_DIALOG")
  frame:SetFrameLevel(110)
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  if frame.SetToplevel then frame:SetToplevel(true) end
  frame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", edgeSize = 24,
    insets = { left = 8, right = 8, top = 8, bottom = 8 }
  })
  frame:SetBackdropColor(0.025, 0.03, 0.025, 1)
  frame:SetBackdropBorderColor(0.45, 0.48, 0.42, 1)
  local background = frame:CreateTexture(nil, "BACKGROUND")
  background:SetPoint("TOPLEFT", 9, -9)
  background:SetPoint("BOTTOMRIGHT", -9, 9)
  background:SetTexture("Interface\\Buttons\\WHITE8X8")
  background:SetVertexColor(0.008, 0.012, 0.008, 1)

  frame.title = managerLabel(frame, LIST_NAME, "GameFontNormalLarge")
  frame.title:SetPoint("TOPLEFT", 20, -18)
  frame.summary = managerLabel(frame, "", "GameFontHighlightSmall")
  frame.summary:SetPoint("TOPLEFT", 20, -46)
  frame.summary:SetPoint("TOPRIGHT", -20, -46)
  frame.summary:SetJustifyH("LEFT")
  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -5, -5)

  local recipeHeader = managerLabel(frame, "Recipe and required materials", "GameFontNormalSmall")
  recipeHeader:SetPoint("TOPLEFT", 62, -72)
  local craftsHeader = managerLabel(frame, "Crafts", "GameFontNormalSmall")
  craftsHeader:SetPoint("TOPRIGHT", -125, -72)
  craftsHeader:SetWidth(100)
  craftsHeader:SetJustifyH("CENTER")

  frame.rows = {}
  for index = 1, 7 do
    local row = CreateFrame("Frame", nil, frame)
    row:SetHeight(48)
    row:SetPoint("TOPLEFT", 18, -90 - ((index - 1) * 49))
    row:SetPoint("TOPRIGHT", -18, -90 - ((index - 1) * 49))
    row.background = row:CreateTexture(nil, "BACKGROUND")
    row.background:SetAllPoints()
    row.background:SetTexture("Interface\\Buttons\\WHITE8X8")
    local shade = index % 2 == 0 and 0.06 or 0.035
    row.background:SetVertexColor(shade, shade + 0.01, shade, 1)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(34, 34)
    row.icon:SetPoint("LEFT", 5, 0)
    row.name = managerLabel(row, "")
    row.name:SetPoint("TOPLEFT", 46, -5)
    row.name:SetPoint("TOPRIGHT", -210, -5)
    row.name:SetJustifyH("LEFT")
    row.details = managerLabel(row, "", "GameFontDisableSmall")
    row.details:SetPoint("TOPLEFT", 46, -24)
    row.details:SetPoint("TOPRIGHT", -210, -24)
    row.details:SetJustifyH("LEFT")
    row.minus = managerButton(row, "-", 26)
    row.minus:SetPoint("RIGHT", -174, 0)
    row.quantity = managerLabel(row, "")
    row.quantity:SetPoint("RIGHT", -120, 0)
    row.quantity:SetWidth(48)
    row.quantity:SetJustifyH("CENTER")
    row.plus = managerButton(row, "+", 26)
    row.plus:SetPoint("RIGHT", -92, 0)
    row.remove = managerButton(row, "Remove", 76)
    row.remove:SetPoint("RIGHT", -5, 0)
    row.minus:SetScript("OnClick", function()
      if row.entry and not row.entry.legacy then SPP.CraftList:AdjustRecipe(row.entry.key, -1) end
    end)
    row.plus:SetScript("OnClick", function()
      if row.entry and not row.entry.legacy then SPP.CraftList:AdjustRecipe(row.entry.key, 1) end
    end)
    row.remove:SetScript("OnClick", function()
      if not row.entry then return end
      if row.entry.legacy then SPP.CraftList:RemoveLegacyMaterials()
      else SPP.CraftList:RemoveRecipe(row.entry.key) end
    end)
    row:Hide()
    table.insert(frame.rows, row)
  end

  frame.add = managerButton(frame, "Add selected recipe", 154)
  frame.add:SetPoint("BOTTOMLEFT", 20, 18)
  frame.add:SetScript("OnClick", function()
    local ok, message = SPP.CraftList:AddSelected(SPP.CraftList.activeProfessionMode or "trade")
    frame.status:SetText(message or (ok and "Recipe added" or "Select a recipe in the profession window"))
  end)
  frame.clear = managerButton(frame, "Clear all", 90)
  frame.clear:SetPoint("LEFT", frame.add, "RIGHT", 8, 0)
  frame.clear:SetScript("OnClick", function()
    local _, message = SPP.CraftList:Clear()
    frame.status:SetText(message)
  end)
  frame.search = managerButton(frame, "Search in Auctionator", 170)
  frame.search:SetPoint("BOTTOMRIGHT", -20, 18)
  frame.search:SetScript("OnClick", function()
    local _, message = SPP.CraftList:OpenAtAuctionHouse()
    frame.status:SetText(message or "")
  end)
  frame.status = managerLabel(frame, "", "GameFontHighlightSmall")
  frame.status:SetPoint("BOTTOMLEFT", frame.clear, "RIGHT", 10, 6)
  frame.status:SetPoint("BOTTOMRIGHT", frame.search, "LEFT", -10, 6)
  frame.status:SetJustifyH("CENTER")

  frame:EnableMouseWheel(true)
  frame:SetScript("OnMouseWheel", function(_, delta)
    local count = #SPP.CraftList:GetManagerEntries()
    SPP.CraftList.managerOffset = math.max(0,
      math.min(math.max(0, count - #frame.rows), (SPP.CraftList.managerOffset or 0) - delta))
    SPP.CraftList:UpdateManager()
  end)
  frame:Hide()
  self.managerFrame = frame
  if UISpecialFrames then table.insert(UISpecialFrames, "ColeProfessionPlannerCraftListFrame") end
  return frame
end

function SPP.CraftList:UpdateManager()
  local frame = self.managerFrame
  if not frame then return end
  local entries = self:GetManagerEntries()
  local maxOffset = math.max(0, #entries - #frame.rows)
  self.managerOffset = math.min(self.managerOffset or 0, maxOffset)
  for rowIndex, row in ipairs(frame.rows) do
    local entry = entries[self.managerOffset + rowIndex]
    row.entry = entry
    if entry then
      row.icon:SetTexture(entry.icon or UNKNOWN_ICON)
      row.name:SetText(entry.name)
      row.details:SetText(entry.details or recipeMaterialsText(entry))
      row.quantity:SetText(entry.legacy and (entry.crafts .. " items") or ("x" .. entry.crafts))
      row.minus:SetShown(not entry.legacy)
      row.plus:SetShown(not entry.legacy)
      row:Show()
    else
      row:Hide()
    end
  end
  local recipeCount, craftCount = self:GetRecipeStats()
  local materialCount, unitCount = self:GetStats()
  frame.summary:SetText(string.format("%d recipes | %d crafts | %d materials (%d units)%s",
    recipeCount, craftCount, materialCount, unitCount,
    maxOffset > 0 and string.format(" | rows %d-%d of %d", self.managerOffset + 1,
      math.min(#entries, self.managerOffset + #frame.rows), #entries) or ""))
  setEnabled(frame.clear, materialCount > 0 or #entries > 0)
  setEnabled(frame.search, materialCount > 0)
  setEnabled(frame.add, self:GetSelected(self.activeProfessionMode or "trade") ~= nil)
end

function SPP.CraftList:OpenManager(mode)
  if mode then self.activeProfessionMode = mode end
  local frame = self:CreateManager()
  self:UpdateManager()
  frame:Show()
  frame:Raise()
  return frame
end

local function addQueueTooltip(control, title, canClear)
  GameTooltip:SetOwner(control, "ANCHOR_RIGHT")
  GameTooltip:SetText(title)
  local rows = SPP.Auctionator:GetShoppingRows(SPP.CraftList:GetPlan())
  if #rows == 0 then
    GameTooltip:AddLine("The list is empty or already covered by bags and bank.", 0.8, 0.8, 0.8, true)
  else
    for index = 1, math.min(8, #rows) do
      local row = rows[index]
      GameTooltip:AddDoubleLine(row.name, "x" .. row.quantity, 1, 1, 1, 1, 0.82, 0)
    end
    if #rows > 8 then GameTooltip:AddLine(string.format("...and %d more", #rows - 8), 0.8, 0.8, 0.8) end
  end
  if canClear then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Shift-right click to clear the list.", 1, 0.45, 0.25)
  end
  GameTooltip:Show()
end

local function handleClearClick(mouseButton)
  if mouseButton ~= "RightButton" or not IsShiftKeyDown or not IsShiftKeyDown() then return false end
  local _, message = SPP.CraftList:Clear()
  print("|cff75c94fCole:|r " .. message)
  return true
end

function SPP.CraftList:PositionProfessionButton(parent, mode)
  local control = self.professionButtons and self.professionButtons[parent]
  if not control then return end
  control:ClearAllPoints()
  local plannerButton = SPP.professionButtons and SPP.professionButtons[parent]
  if plannerButton then
    control:SetPoint("RIGHT", plannerButton, "LEFT", -4, 0)
  else
    local closeButton
    if mode == "craft" then closeButton = CraftFrameCloseButton
    else closeButton = TradeSkillFrameCloseButton or parent.CloseButton end
    if closeButton then
      control:SetPoint("RIGHT", closeButton, "LEFT", -34, 0)
    else
      control:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -72, -10)
    end
  end
  control:SetFrameLevel(parent:GetFrameLevel() + 20)
end

function SPP.CraftList:AttachProfessionButton(parent, mode)
  if not parent then return end
  self.professionButtons = self.professionButtons or {}
  if not self.professionButtons[parent] then
    local control = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    control:SetSize(94, 24)
    control:SetText("Cole list")
    control.mode = mode
    control:SetScript("OnClick", function(button) SPP.CraftList:OpenManager(button.mode) end)
    control:SetScript("OnEnter", function(button)
      local recipe = SPP.CraftList:GetSelected(button.mode)
      addQueueTooltip(button, recipe and ("Manage list / selected: " .. recipe.name) or "Manage " .. LIST_NAME, false)
    end)
    control:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.professionButtons[parent] = control
  end
  self.professionButtons[parent].mode = mode
  self.activeProfessionMode = mode
  self:PositionProfessionButton(parent, mode)
  self:UpdateButtons()
end

function SPP.CraftList:AttachAuctionButton()
  local parent = AuctionFrame or AuctionHouseFrame
  if not parent then return false end
  if not self.auctionButton then
    local control = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    control:SetSize(118, 24)
    control:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    control:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -34, -8)
    control:SetFrameLevel(parent:GetFrameLevel() + 30)
    control:SetScript("OnClick", function(_, mouseButton)
      if handleClearClick(mouseButton) then return end
      if mouseButton ~= "LeftButton" then return end
      local ok, message = SPP.CraftList:OpenAtAuctionHouse()
      print("|cff75c94fCole:|r " .. (message or (ok and "Opened" or "Unable to open list")))
    end)
    control:SetScript("OnEnter", function(button) addQueueTooltip(button, LIST_NAME, true) end)
    control:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.auctionButton = control
    local manage = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    manage:SetSize(78, 24)
    manage:SetPoint("RIGHT", control, "LEFT", -4, 0)
    manage:SetFrameLevel(parent:GetFrameLevel() + 30)
    manage:SetText("Manage")
    manage:SetScript("OnClick", function() SPP.CraftList:OpenManager() end)
    self.auctionManageButton = manage
  end
  self:UpdateButtons()
  return true
end

function SPP.CraftList:UpdateButtons()
  local itemCount = self:GetStats()
  local recipeCount = self:GetRecipeStats()
  if self.auctionButton then
    self.auctionButton:SetText(string.format("Cole list (%d)", itemCount))
    self.auctionButton:SetEnabled(itemCount > 0)
  end
  for _, control in pairs(self.professionButtons or {}) do
    control:SetText(string.format("Cole list (%d)", recipeCount))
  end
  if self.auctionManageButton then self.auctionManageButton:SetText(string.format("Manage (%d)", recipeCount)) end
end

function SPP.CraftList:GetListName()
  return LIST_NAME
end
