local addon = CreateFrame("Frame")
addon:RegisterEvent("ADDON_LOADED")
addon:RegisterEvent("PLAYER_LOGIN")
addon:RegisterEvent("TRADE_SKILL_SHOW")
addon:RegisterEvent("CRAFT_SHOW")
addon:RegisterEvent("SKILL_LINES_CHANGED")
addon:RegisterEvent("MERCHANT_SHOW")
addon:RegisterEvent("MERCHANT_UPDATE")

local function currentTime()
  local serverTime = GetServerTime and GetServerTime() or nil
  if serverTime and serverTime > 0 then return serverTime end
  return time and time() or 0
end

local function npcIdFromGuid(guid)
  return guid and tonumber(guid:match("^[^-]+%-[^-]+%-[^-]+%-[^-]+%-[^-]+%-(%d+)")) or nil
end

local function scanVendorRecipeStock()
  local npcId = npcIdFromGuid(UnitGUID and UnitGUID("npc"))
  local recipes = npcId and SPP.Data:GetVendorRecipesForNpc(npcId) or {}
  if #recipes == 0 then return 0 end
  local merchantStock = {}
  for index = 1, GetMerchantNumItems and GetMerchantNumItems() or 0 do
    local link = GetMerchantItemLink and GetMerchantItemLink(index)
    local itemId = link and tonumber(link:match("item:(%d+)")) or nil
    if itemId then
      local _, _, _, _, available = GetMerchantItemInfo(index)
      merchantStock[itemId] = { available = available == nil or available == -1 or available > 0, quantity = available }
    end
  end
  ColeProfessionPlannerDB.vendorRecipeStock = ColeProfessionPlannerDB.vendorRecipeStock or {}
  local checkedAt, count = currentTime(), 0
  for _, recipe in ipairs(recipes) do
    local itemId = recipe[SPP.R.RECIPE_ITEM]
    if itemId then
      local stock = merchantStock[itemId]
      ColeProfessionPlannerDB.vendorRecipeStock[itemId] = {
        npcId = npcId,
        checkedAt = checkedAt,
        available = stock and stock.available or false,
        quantity = stock and stock.quantity or 0
      }
      count = count + 1
    end
  end
  return count
end

local function scheduleVendorRecipeScan()
  SPP.vendorScanGeneration = (SPP.vendorScanGeneration or 0) + 1
  local generation = SPP.vendorScanGeneration
  local function run()
    if generation ~= SPP.vendorScanGeneration then return end
    local count = scanVendorRecipeStock()
    if count > 0 and SPP.UI and SPP.UI.OnVendorRecipesUpdated then SPP.UI:OnVendorRecipesUpdated(count) end
  end
  if C_Timer and C_Timer.After then C_Timer.After(0.15, run) else run() end
end

local function parseMoney(text)
  local value = tonumber(text)
  if value then return math.floor(value * 10000 + 0.5) end
  local gold = tonumber(text:match("(%d+%.?%d*)g")) or 0
  local silver = tonumber(text:match("(%d+%.?%d*)s")) or 0
  local copper = tonumber(text:match("(%d+%.?%d*)c")) or 0
  local total = gold * 10000 + silver * 100 + copper
  return total > 0 and math.floor(total + 0.5) or nil
end

local function slashCommand(message)
  local command, rest = message:match("^(%S*)%s*(.-)$")
  command = command:lower()
  if command == "price" then
    local itemId, priceText = rest:match("^(%d+)%s+(.+)$")
    local price = priceText and parseMoney(priceText)
    if not itemId or not price then
      print("|cff6fb7ffSPP:|r /spp price <itemId> <gold or 12g34s56c>")
      return
    end
    ColeProfessionPlannerDB.manualPrices[tonumber(itemId)] = price
    SPP.Price:ClearCache()
    print("|cff6fb7ffSPP:|r " .. SPP.Data:GetItemName(tonumber(itemId)) .. " = " .. SPP:FormatMoney(price))
  elseif command == "clearprice" then
    local itemId = tonumber(rest)
    if itemId then ColeProfessionPlannerDB.manualPrices[itemId] = nil SPP.Price:ClearCache() end
  elseif command == "minimap" then
    SPP.Minimap:Show()
  elseif command == "pricecheck" then
    local itemId = tonumber(rest)
    if not itemId then
      print("|cff75c94fCole:|r /cole pricecheck <itemId>")
      return
    end
    print("|cff75c94fCole:|r " .. SPP.Data:GetItemName(itemId) .. " (" .. itemId .. ")")
    for _, line in ipairs(SPP.Price:GetProviderDiagnostics(itemId)) do print("  " .. line) end
  elseif command == "phase" then
    local phase = tonumber(rest)
    if rest == "auto" then
      ColeProfessionPlannerDB.phaseOverride = nil
    elseif phase and phase >= 1 and phase <= 6 then
      ColeProfessionPlannerDB.phaseOverride = phase
    else
      print("|cff75c94fCole:|r /cole phase <1-6|auto>")
      return
    end
    local info = SPP.Client:Detect()
    if SPP.UI.frame then
      SPP.UI.phase = info.phase
      UIDropDownMenu_SetSelectedValue(SPP.UI.phaseMenu, info.phase)
      UIDropDownMenu_SetText(SPP.UI.phaseMenu, "Phase " .. info.phase .. " (auto)")
      SPP.UI:Refresh()
    end
    print("|cff75c94fCole:|r phase " .. info.phase .. " (" .. info.phaseBasis .. ")")
  else
    SPP.UI:Toggle()
  end
end

local function isAddonLoaded(name)
  if C_AddOns and C_AddOns.IsAddOnLoaded then return C_AddOns.IsAddOnLoaded(name) end
  return IsAddOnLoaded and IsAddOnLoaded(name) or false
end

local function positionProfessionButton(tradeSkillParent, closeButton)
  local control = SPP.professionButtons and SPP.professionButtons[tradeSkillParent]
  if not control or not tradeSkillParent then return end
  control:ClearAllPoints()
  if isAddonLoaded("TradeSkillMaster") then
    -- TSM's default-UI switch occupies TOPRIGHT -60..-120 at this height.
    control:SetPoint("TOPRIGHT", tradeSkillParent, "TOPRIGHT", -124, -10)
    control:SetFrameLevel(tradeSkillParent:GetFrameLevel() + 10)
  elseif closeButton then
    control:SetPoint("RIGHT", closeButton, "LEFT", -2, 0)
    if closeButton.GetFrameLevel then control:SetFrameLevel(closeButton:GetFrameLevel() + 1) end
  else
    control:SetPoint("TOPRIGHT", tradeSkillParent, "TOPRIGHT", -58, -10)
  end
end

local function addProfessionButton(tradeSkillParent, closeButton)
  if not tradeSkillParent then return end
  SPP.professionButtons = SPP.professionButtons or {}
  if SPP.professionButtons[tradeSkillParent] then
    positionProfessionButton(tradeSkillParent, closeButton)
    return
  end
  local control = CreateFrame("Button", nil, tradeSkillParent, "UIPanelButtonTemplate")
  control:SetSize(28, 28)
  local icon = control:CreateTexture(nil, "ARTWORK")
  icon:SetSize(20, 20)
  icon:SetPoint("CENTER")
  icon:SetTexture("Interface\\AddOns\\ColeProfessionPlanner\\Media\\ColeIcon.tga")
  control:SetScript("OnClick", function() SPP.UI:Toggle() end)
  control:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText("Cole Profession Planner")
    GameTooltip:Show()
  end)
  control:SetScript("OnLeave", function() GameTooltip:Hide() end)
  SPP.professionButtons[tradeSkillParent] = control
  positionProfessionButton(tradeSkillParent, closeButton)
end

addon:SetScript("OnEvent", function(_, event, name)
  if event == "ADDON_LOADED" and name == "ColeProfessionPlanner" then
    ColeProfessionPlannerDB = ColeProfessionPlannerDB or SolProfessionPlannerDB or {}
    ColeProfessionPlannerDB.manualPrices = ColeProfessionPlannerDB.manualPrices or {}
    ColeProfessionPlannerDB.volumePrices = ColeProfessionPlannerDB.volumePrices or {}
    ColeProfessionPlannerDB.savedPlans = ColeProfessionPlannerDB.savedPlans or {}
    ColeProfessionPlannerDB.vendorRecipeStock = ColeProfessionPlannerDB.vendorRecipeStock or {}
    ColeProfessionPlannerDB.routeMode = ColeProfessionPlannerDB.routeMode == "fast" and "fast" or "economy"
    SPP.Data:Finalize()
    SPP.Client:Detect()
    SLASH_COLEPROFESSIONPLANNER1 = "/cole"
    SLASH_COLEPROFESSIONPLANNER2 = "/cpp"
    SLASH_COLEPROFESSIONPLANNER3 = "/spp"
    SlashCmdList.COLEPROFESSIONPLANNER = slashCommand
  elseif event == "PLAYER_LOGIN" then
    SPP.Minimap:Create()
    SPP.Client:RecordCharacterProfessions()
    if C_Timer and C_Timer.After then C_Timer.After(1, function() SPP.Client:RecordCharacterProfessions() end) end
  elseif event == "TRADE_SKILL_SHOW" then
    SPP.UI:CacheTradeSkillIcons()
    local parent = ProfessionsFrame or TradeSkillFrame
    local closeButton = TradeSkillFrameCloseButton or parent and parent.CloseButton
    addProfessionButton(parent, closeButton)
    if C_Timer and C_Timer.After then
      C_Timer.After(0, function() positionProfessionButton(parent, closeButton) end)
    end
  elseif event == "CRAFT_SHOW" then
    SPP.UI:CacheTradeSkillIcons()
    local parent = CraftFrame
    local closeButton = CraftFrameCloseButton or parent and parent.CloseButton
    addProfessionButton(parent, closeButton)
    if C_Timer and C_Timer.After then
      C_Timer.After(0, function() positionProfessionButton(parent, closeButton) end)
    end
  elseif event == "SKILL_LINES_CHANGED" then
    SPP.Client:RecordCharacterProfessions()
    if SPP.UI.frame then
      SPP.UI:SyncProfessionSkill(SPP.UI.plan == nil)
      SPP.UI:Refresh()
    end
  elseif event == "MERCHANT_SHOW" or event == "MERCHANT_UPDATE" then
    scheduleVendorRecipeScan()
  end
end)
