SPP.CraftList = SPP.CraftList or {}

local LIST_NAME = "Cole Craft List"

local function queue()
  ColeProfessionPlannerDB.craftShopping = ColeProfessionPlannerDB.craftShopping or {}
  return ColeProfessionPlannerDB.craftShopping
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
  return { name = name, crafts = craftQuantity(TradeSkillInputBox), reagents = reagents }
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
  return { name = name, crafts = craftQuantity(CraftInputBox), reagents = reagents }
end

function SPP.CraftList:GetSelected(mode)
  return mode == "craft" and selectedCraft() or selectedTradeSkill()
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
  if not recipe then return false, "Select a recipe with reagents first" end
  if #recipe.reagents == 0 then return false, recipe.name .. " has no purchasable reagents" end
  local shopping = queue()
  for _, reagent in ipairs(recipe.reagents) do
    shopping[reagent.itemId] = (shopping[reagent.itemId] or 0) + reagent.quantity * recipe.crafts
  end
  local itemCount = self:GetStats()
  self:UpdateButtons()
  return true, string.format("Added %s x%d to %s (%d materials)", recipe.name, recipe.crafts, LIST_NAME, itemCount)
end

function SPP.CraftList:Clear()
  ColeProfessionPlannerDB.craftShopping = {}
  local api = Auctionator and Auctionator.API and Auctionator.API.v1
  if api and api.CreateShoppingList then pcall(api.CreateShoppingList, "ColeProfessionPlanner", LIST_NAME, {}) end
  self:UpdateButtons()
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

local function addQueueTooltip(control, title)
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
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Shift-right click to clear the list.", 1, 0.45, 0.25)
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
  local auctionSearch = mode == "trade" and AuctionatorCraftingInfo and AuctionatorCraftingInfo.SearchButton
  if auctionSearch then
    control:SetPoint("RIGHT", auctionSearch, "LEFT", -4, 0)
  else
    local createButton = mode == "craft" and CraftCreateButton or TradeSkillCreateButton
    if createButton then
      control:SetPoint("BOTTOMRIGHT", createButton, "TOPRIGHT", 0, 6)
    else
      control:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -42, -78)
    end
  end
  control:SetFrameLevel(parent:GetFrameLevel() + 20)
end

function SPP.CraftList:AttachProfessionButton(parent, mode)
  if not parent then return end
  self.professionButtons = self.professionButtons or {}
  if not self.professionButtons[parent] then
    local control = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    control:SetSize(126, 24)
    control:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    control:SetText("Add to Cole list")
    control.mode = mode
    control:SetScript("OnClick", function(button, mouseButton)
      if handleClearClick(mouseButton) then return end
      if mouseButton ~= "LeftButton" then return end
      local ok, message = SPP.CraftList:AddSelected(button.mode)
      print("|cff75c94fCole:|r " .. (message or (ok and "Added" or "Unable to add recipe")))
    end)
    control:SetScript("OnEnter", function(button)
      local recipe = SPP.CraftList:GetSelected(button.mode)
      addQueueTooltip(button, recipe and ("Add " .. recipe.name .. " x" .. recipe.crafts) or "Cole Craft List")
    end)
    control:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.professionButtons[parent] = control
  end
  self.professionButtons[parent].mode = mode
  self:PositionProfessionButton(parent, mode)
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
    control:SetScript("OnEnter", function(button) addQueueTooltip(button, LIST_NAME) end)
    control:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.auctionButton = control
  end
  self:UpdateButtons()
  return true
end

function SPP.CraftList:UpdateButtons()
  local itemCount = self:GetStats()
  if self.auctionButton then
    self.auctionButton:SetText(string.format("Cole list (%d)", itemCount))
    self.auctionButton:SetEnabled(itemCount > 0)
  end
end

function SPP.CraftList:GetListName()
  return LIST_NAME
end
