SPP.UI = SPP.UI or { offset = 0, planOffset = 0, shoppingOffset = 0, mode = "planner", recipeIcons = {}, knownRecipes = {} }

local COLORS = {
  orange = { 1, 0.5, 0 }, yellow = { 1, 0.9, 0.15 }, green = { 0.25, 0.9, 0.35 },
  gray = { 0.55, 0.55, 0.55 }, locked = { 0.45, 0.45, 0.45 }
}
local EXPANSIONS = { "Vanilla", "The Burning Crusade" }
local PRICE_TTL_SECONDS = 30 * 60
local BAR_RELATED_PROFESSIONS = { blacksmithing = true, engineering = true, jewelcrafting = true }

local function currentTime()
  local serverTime = GetServerTime and GetServerTime() or nil
  if serverTime and serverTime > 0 then return serverTime end
  if time then return time() end
  return os and os.time and os.time() or 0
end

local function phaseLabel(expansion, phase)
  local client = SPP.Client:GetInfo()
  local isCurrent = expansion == client.expansion and phase == client.phase
  return "Phase " .. phase .. (isCurrent and " (auto)" or "")
end

local PROFESSION_ICONS = {
  alchemy = "Interface\\Icons\\Trade_Alchemy", blacksmithing = "Interface\\Icons\\Trade_BlackSmithing",
  cooking = "Interface\\Icons\\INV_Misc_Food_15", enchanting = "Interface\\Icons\\Trade_Engraving",
  engineering = "Interface\\Icons\\Trade_Engineering", ["first-aid"] = "Interface\\Icons\\Spell_Holy_SealOfSacrifice",
  jewelcrafting = "Interface\\Icons\\INV_Misc_Gem_01", leatherworking = "Interface\\Icons\\Trade_LeatherWorking",
  mining = "Interface\\Icons\\Trade_Mining", tailoring = "Interface\\Icons\\Trade_Tailoring"
}

local function spellIdFromLink(link)
  return link and tonumber(link:match("enchant:(%d+)") or link:match("spell:(%d+)")) or nil
end

local function recipeIcon(recipe)
  if not recipe then return "Interface\\Icons\\INV_Misc_Note_01" end
  local spellId = recipe[SPP.R.SPELL]
  local texture = SPP.UI.recipeIcons[spellId] or SPP.UI.recipeIcons[recipe[SPP.R.NAME]]
  if texture then return texture end
  if C_Spell and C_Spell.GetSpellTexture then texture = C_Spell.GetSpellTexture(spellId) end
  if not texture and spellId and GetSpellTexture then texture = GetSpellTexture(spellId) end
  if not texture and spellId and GetSpellInfo then texture = select(3, GetSpellInfo(spellId)) end
  local output = recipe[SPP.R.OUTPUT]
  if not texture and output and C_Item and C_Item.GetItemIconByID then texture = C_Item.GetItemIconByID(output) end
  if not texture and output and GetItemIcon then texture = GetItemIcon(output) end
  local recipeItem = recipe[SPP.R.RECIPE_ITEM]
  if not texture and recipeItem and C_Item and C_Item.GetItemIconByID then texture = C_Item.GetItemIconByID(recipeItem) end
  if not texture and recipeItem and GetItemIcon then texture = GetItemIcon(recipeItem) end
  return texture or PROFESSION_ICONS[recipe[SPP.R.PROFESSION]] or "Interface\\Icons\\INV_Misc_Note_01"
end

local function itemTexture(itemId)
  local texture
  if itemId and C_Item and C_Item.GetItemIconByID then texture = C_Item.GetItemIconByID(itemId) end
  if not texture and itemId and GetItemIcon then texture = GetItemIcon(itemId) end
  return texture or "Interface\\Icons\\INV_Misc_Bag_10"
end

function SPP.UI:CacheTradeSkillIcons()
  self.recipeIcons = self.recipeIcons or {}
  self.knownRecipes = self.knownRecipes or {}
  if GetNumTradeSkills and GetTradeSkillInfo and GetTradeSkillIcon then
    for index = 1, GetNumTradeSkills() do
      local name, skillType = GetTradeSkillInfo(index)
      if name and skillType ~= "header" then
        local texture = GetTradeSkillIcon(index)
        local spellId = spellIdFromLink(GetTradeSkillRecipeLink and GetTradeSkillRecipeLink(index))
        if texture then
          self.recipeIcons[name] = texture
          if spellId then self.recipeIcons[spellId] = texture end
        end
        if spellId then self.knownRecipes[spellId] = true end
      end
    end
  end
  if GetNumCrafts and GetCraftInfo and GetCraftIcon then
    for index = 1, GetNumCrafts() do
      local name, _, craftType = GetCraftInfo(index)
      if name and craftType ~= "header" then
        local texture = GetCraftIcon(index)
        local spellId = spellIdFromLink(GetCraftRecipeLink and GetCraftRecipeLink(index))
        if texture then
          self.recipeIcons[name] = texture
          if spellId then self.recipeIcons[spellId] = texture end
        end
        if spellId then self.knownRecipes[spellId] = true end
      end
    end
  end
  if self.frame and self.frame:IsShown() then self:Refresh() end
end

local function label(parent, text, size)
  local font = parent:CreateFontString(nil, "OVERLAY", size or "GameFontHighlightSmall")
  font:SetText(text)
  return font
end

local function button(parent, text, width, height)
  local control = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  control:SetSize(width, height or 22)
  control:SetText(text)
  return control
end

local function editBox(parent, width, numeric)
  local edit = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  edit:SetSize(width, 22)
  edit:SetAutoFocus(false)
  if numeric then edit:SetNumeric(true) end
  return edit
end

local function dropdown(parent, width, values, onSelect)
  local menu = CreateFrame("Frame", nil, parent, "UIDropDownMenuTemplate")
  UIDropDownMenu_SetWidth(menu, width)
  UIDropDownMenu_Initialize(menu, function()
    for index, value in ipairs(values()) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = value.label or value
      info.value = value.value or index
      info.func = function()
        UIDropDownMenu_SetSelectedValue(menu, info.value)
        UIDropDownMenu_SetText(menu, info.text)
        onSelect(info.value, info.text)
      end
      UIDropDownMenu_AddButton(info)
    end
  end)
  return menu
end

local function setRowRecipe(row, recipe, skill)
  row.recipe = recipe
  if not recipe then row:Hide() return end
  row:Hide()
  row.map:Hide()
  local colorName = SPP.Data:GetColor(recipe, skill)
  local color = COLORS[colorName]
  row.name:SetText(recipe[SPP.R.NAME])
  row.name:SetTextColor(color[1], color[2], color[3])
  row.range:SetText(string.format("%d / %d / %d / %d", recipe[SPP.R.ORANGE], recipe[SPP.R.YELLOW], recipe[SPP.R.GREEN], recipe[SPP.R.GRAY]))
  row.source:SetText(SPP.Data:GetSourceSummary(recipe, SPP.UI.expansion, SPP.UI.phase))
  row.icon:SetTexture(recipeIcon(recipe))
  row.mapSources = SPP.Data:GetMappableSources(recipe, SPP.UI.expansion, SPP.UI.phase)
  row.map:SetText(#row.mapSources > 1 and "Sources" or "Map")
  row.map:SetShown(#row.mapSources > 0)
  row:Show()
end

function SPP.UI:CreateRecipeRow(parent, index)
  local row = CreateFrame("Button", nil, parent)
  row:SetHeight(32)
  row:SetFrameLevel(parent:GetFrameLevel() + 1)
  row:SetPoint("TOPLEFT", 8, -30 - ((index - 1) * 34))
  row:SetPoint("TOPRIGHT", -8, -30 - ((index - 1) * 34))
  row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

  row.background = row:CreateTexture(nil, "BACKGROUND")
  row.background:SetAllPoints()
  row.background:SetTexture("Interface\\Buttons\\WHITE8X8")
  if index % 2 == 0 then
    row.background:SetVertexColor(0.09, 0.11, 0.09, 0.72)
  else
    row.background:SetVertexColor(0.055, 0.065, 0.055, 0.72)
  end

  row.icon = row:CreateTexture(nil, "OVERLAY")
  row.icon:SetSize(26, 26)
  row.icon:SetPoint("LEFT", 2, 0)
  row.name = label(row, "")
  row.name:SetPoint("LEFT", row.icon, "RIGHT", 7, 0)
  row.name:SetSize(205, 28)
  row.name:SetJustifyH("LEFT")
  row.range = label(row, "")
  row.range:SetPoint("LEFT", 248, 0)
  row.range:SetSize(174, 28)
  row.range:SetJustifyH("LEFT")
  row.source = label(row, "")
  row.source:SetPoint("LEFT", 432, 0)
  row.source:SetPoint("RIGHT", -66, 0)
  row.source:SetHeight(28)
  row.source:SetJustifyH("LEFT")
  row.map = button(row, "Map", 60, 20)
  row.map:SetPoint("RIGHT", -2, 0)
  row.map:SetScript("OnClick", function()
    local ok, message = SPP.Map:OpenRecipeSources(row.recipe, SPP.UI.expansion, SPP.UI.phase, row.map)
    if message then print("|cff75c94fCole:|r " .. message) end
  end)

  row:SetScript("OnEnter", function(self)
    if not self.recipe then return end
    local recipe = self.recipe
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(recipe[SPP.R.NAME], 1, 1, 1)
    local phaseSuffix = recipe[SPP.R.PHASE_EXACT] == 1 and "" or " (assumed)"
    GameTooltip:AddLine(EXPANSIONS[recipe[SPP.R.EXPANSION]] .. " - Phase " .. recipe[SPP.R.PHASE] .. phaseSuffix, 0.7, 0.8, 1)
    for _, source in ipairs(SPP.Data:GetAvailableSources(recipe, SPP.UI.expansion, SPP.UI.phase)) do
      local expansion = EXPANSIONS[source[SPP.S.EXPANSION]] or "Unknown"
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine(string.format("%s - Phase %d", expansion, source[SPP.S.PHASE]), 0.45, 0.75, 1)
      GameTooltip:AddLine(SPP.Data:GetSourceText(source, true), 0.9, 0.9, 0.9, true)
      local command = SPP.Map:GetTomTomCommand(source)
      if command then GameTooltip:AddLine(command, 0.45, 1, 0.45, true) end
    end
    GameTooltip:AddLine(" ")
    local reagents = recipe[SPP.R.REAGENTS]
    for i = 1, #reagents, 2 do
      GameTooltip:AddDoubleLine(SPP.Data:GetItemName(reagents[i]), "x" .. reagents[i + 1], 1, 0.82, 0, 1, 1, 1)
    end
    local cost = SPP.Price:GetRecipeCost(recipe, { maxExpansion = SPP.UI.expansion, maxPhase = SPP.UI.phase })
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("Craft cost", SPP:FormatMoney(cost), 0.7, 0.8, 1, 1, 1, 1)
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  row.map:Hide()
  row:Hide()
  return row
end

function SPP.UI:CreatePlanRow(parent, index)
  local row = CreateFrame("Button", nil, parent)
  row:SetHeight(32)
  row:SetFrameLevel(parent:GetFrameLevel() + 1)
  row:SetPoint("TOPLEFT", 8, -30 - ((index - 1) * 34))
  row:SetPoint("TOPRIGHT", -8, -30 - ((index - 1) * 34))
  row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  row.skill = label(row, "")
  row.skill:SetPoint("LEFT", 34, 0)
  row.skill:SetWidth(70)
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(26, 26)
  row.icon:SetPoint("LEFT", 3, 0)
  row.name = label(row, "")
  row.name:SetPoint("LEFT", 105, 0)
  row.name:SetWidth(280)
  row.name:SetJustifyH("LEFT")
  row.crafts = label(row, "")
  row.crafts:SetPoint("LEFT", 395, 0)
  row.crafts:SetWidth(100)
  row.cost = label(row, "")
  row.cost:SetPoint("RIGHT", -5, 0)
  row.cost:SetWidth(150)
  row.cost:SetJustifyH("RIGHT")
  row:Hide()
  return row
end

function SPP.UI:CreateShoppingRow(parent, index)
  local row = CreateFrame("Button", nil, parent)
  row:SetHeight(32)
  row:SetPoint("TOPLEFT", 8, -58 - ((index - 1) * 34))
  row:SetPoint("TOPRIGHT", -8, -58 - ((index - 1) * 34))
  row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(26, 26)
  row.icon:SetPoint("LEFT", 3, 0)
  row.name = label(row, "")
  row.name:SetPoint("LEFT", 38, 0)
  row.name:SetWidth(390)
  row.name:SetJustifyH("LEFT")
  row.quantity = label(row, "")
  row.quantity:SetPoint("LEFT", 450, 0)
  row.quantity:SetWidth(90)
  row.quantity:SetJustifyH("RIGHT")
  row.cost = label(row, "")
  row.cost:SetPoint("RIGHT", -6, 0)
  row.cost:SetWidth(180)
  row.cost:SetJustifyH("RIGHT")
  row:Hide()
  return row
end

function SPP.UI:GetPlanPriceFreshness(plan, now)
  if not plan or plan.priceDiscovery then return false end
  local usesAuction, auctionAgeDays = SPP.Price:GetPlanAuctionAge(plan)
  if not usesAuction then return false end
  if auctionAgeDays and auctionAgeDays >= 1 then
    return true, string.format("Auctionator prices are at least %d day%s old.", auctionAgeDays, auctionAgeDays == 1 and "" or "s")
  end
  local calculatedAt = plan.calculatedAt or 0
  local elapsed = calculatedAt > 0 and math.max(0, (now or currentTime()) - calculatedAt) or 0
  if elapsed >= PRICE_TTL_SECONDS then
    return true, string.format("Route prices were checked %d minutes ago.", math.floor(elapsed / 60))
  end
  return false
end

function SPP.UI:UpdateProfessionButton()
  if not self.openProfessionButton then return end
  local known = SPP.Client:GetProfessions()[self.profession]
  self.openProfessionButton:SetEnabled(known ~= nil)
  self.openProfessionButton:SetAlpha(known and 1 or 0.35)
  self.openProfessionIcon:SetTexture(known and known.icon or PROFESSION_ICONS[self.profession])
end

function SPP.UI:GetPricingOptions()
  local available = SPP.Client:GetAvailableProfessions()
  available[self.profession] = true
  return {
    maxExpansion = self.expansion, maxPhase = self.phase,
    includeRareRecipes = self.includeRareRecipes and self.includeRareRecipes:GetChecked() or true,
    knownRecipes = self.knownRecipes, availableProfessions = available
  }
end

function SPP.UI:UpdateMiningNote()
  if not self.miningNote then return end
  if not BAR_RELATED_PROFESSIONS[self.profession] then self.miningNote:Hide() return end
  local currentMining = SPP.Client:GetProfessions().mining ~= nil
  local availableMining = SPP.Client:HasAvailableProfession("mining")
  if currentMining then
    self.miningNote:SetText("Mining available: ore smelting is included in price comparisons.")
    self.miningNote:SetTextColor(0.45, 1, 0.45)
  elseif availableMining then
    self.miningNote:SetText("Mining alt recorded: ore smelting is included in price comparisons.")
    self.miningNote:SetTextColor(0.45, 1, 0.45)
  else
    self.miningNote:SetText("No Mining recorded: bars stay direct. Log into a Mining alt once to enable ore pricing.")
    self.miningNote:SetTextColor(1, 0.82, 0.2)
  end
  self.miningNote:Show()
end

function SPP.UI:SyncProfessionSkill(force)
  local known = SPP.Client:GetProfessions()[self.profession]
  local previousSkill = self.skill
  if known then
    self.skill = known.rank or self.skill or 1
    local currentFrom = self.fromBox and tonumber(self.fromBox:GetText()) or nil
    if self.fromBox and (force or not currentFrom or currentFrom == previousSkill) then
      self.fromBox:SetText(self.skill)
    end
  end
  self:UpdateProfessionButton()
end

function SPP.UI:OpenProfession()
  local known = SPP.Client:GetProfessions()[self.profession]
  if not known then return false, "This profession is not learned" end
  if InCombatLockdown and InCombatLockdown() then return false, "Cannot open a profession during combat" end
  if C_TradeSkillUI and C_TradeSkillUI.OpenTradeSkill and known.skillLineId then
    local ok = pcall(C_TradeSkillUI.OpenTradeSkill, known.skillLineId)
    if ok then return true end
  end
  if CastSpellByName then
    local ok = pcall(CastSpellByName, known.name)
    if ok then return true end
  end
  return false, "The client could not open " .. (known.name or self.profession)
end

function SPP.UI:Create()
  if self.frame then return end
  local client = SPP.Client:GetInfo()
  local professionChoices, knownProfessions = SPP.Client:GetProfessionChoices()
  self.profession = professionChoices[1] and professionChoices[1].value or "alchemy"
  self.expansion = client.expansion
  self.phase = client.phase
  self.skill = knownProfessions[self.profession] and knownProfessions[self.profession].rank or 1

  local frame = CreateFrame("Frame", "ColeProfessionPlannerFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  self.frame = frame
  frame:SetSize(820, 600)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("DIALOG")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetScript("OnUpdate", function(_, elapsed)
    self.freshnessElapsed = (self.freshnessElapsed or 0) + elapsed
    if self.freshnessElapsed >= 30 then
      self.freshnessElapsed = 0
      self:UpdatePriceFreshness()
    end
  end)
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
  background:SetVertexColor(0.025, 0.03, 0.025, 0.97)
  self.background = background
  frame:Hide()
  if UISpecialFrames then table.insert(UISpecialFrames, "ColeProfessionPlannerFrame") end

  local title = label(frame, "Cole Profession Planner", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 18, -17)
  self.clientLabel = label(frame, string.format("%s %s  |  Phase %d", client.label, client.version or "", client.phase))
  self.clientLabel:SetPoint("TOPRIGHT", -42, -21)
  self.clientLabel:SetTextColor(0.55, 0.85, 0.45)
  self.clientLabel:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText("Client detection")
    GameTooltip:AddLine("Build: " .. tostring(client.build), 1, 1, 1)
    GameTooltip:AddLine("Interface: " .. tostring(client.interface), 1, 1, 1)
    GameTooltip:AddLine("Phase: " .. client.phaseBasis, 1, 1, 1)
    GameTooltip:Show()
  end)
  self.clientLabel:SetScript("OnLeave", function() GameTooltip:Hide() end)
  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -5, -5)

  self.planTab = button(frame, "Professions", 100, 24)
  self.planTab:SetPoint("TOPLEFT", 18, -48)
  self.shoppingTab = button(frame, "Shopping list", 110, 24)
  self.shoppingTab:SetPoint("LEFT", self.planTab, "RIGHT", 4, 0)
  self.browserTab = button(frame, "Recipes", 90, 24)
  self.browserTab:SetPoint("LEFT", self.shoppingTab, "RIGHT", 4, 0)
  self.planTab:SetScript("OnClick", function() SPP.UI:SetMode("planner") end)
  self.shoppingTab:SetScript("OnClick", function() SPP.UI:SetMode("shopping") end)
  self.browserTab:SetScript("OnClick", function() SPP.UI:SetMode("browser") end)

  local professionValues = function()
    return SPP.Client:GetProfessionChoices()
  end
  self.professionMenu = dropdown(frame, 155, professionValues, function(value)
    self.profession = value
    self.skill = 1
    self:SyncProfessionSkill(true)
    self.offset, self.planOffset, self.shoppingOffset, self.plan = 0, 0, 0, nil
    self:Refresh()
  end)
  self.professionMenu:SetPoint("TOPLEFT", 48, -80)
  UIDropDownMenu_SetSelectedValue(self.professionMenu, self.profession)
  UIDropDownMenu_SetText(self.professionMenu, professionChoices[1] and professionChoices[1].label or "Alchemy")
  self.openProfessionButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  self.openProfessionButton:SetSize(26, 26)
  self.openProfessionButton:SetPoint("TOPLEFT", 12, -81)
  self.openProfessionIcon = self.openProfessionButton:CreateTexture(nil, "ARTWORK")
  self.openProfessionIcon:SetSize(18, 18)
  self.openProfessionIcon:SetPoint("CENTER")
  self.openProfessionButton:SetScript("OnClick", function()
    local ok, message = self:OpenProfession()
    if not ok and message then print("|cff75c94fCole:|r " .. message) end
  end)
  self.openProfessionButton:SetScript("OnEnter", function(control)
    local known = SPP.Client:GetProfessions()[self.profession]
    GameTooltip:SetOwner(control, "ANCHOR_BOTTOM")
    GameTooltip:SetText(known and ("Open " .. known.name) or "Profession not learned")
    GameTooltip:Show()
  end)
  self.openProfessionButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
  self:UpdateProfessionButton()

  self.expansionMenu = dropdown(frame, 180, function() return EXPANSIONS end, function(value)
    self.expansion = value
    self.phase = SPP.Client:GetDefaultPhase(value)
    if self.phaseMenu then
      UIDropDownMenu_SetSelectedValue(self.phaseMenu, self.phase)
      UIDropDownMenu_SetText(self.phaseMenu, phaseLabel(self.expansion, self.phase))
    end
    self.offset, self.plan = 0, nil
    self:Refresh()
  end)
  self.expansionMenu:SetPoint("LEFT", self.professionMenu, "RIGHT", -8, 0)
  UIDropDownMenu_SetSelectedValue(self.expansionMenu, self.expansion)
  UIDropDownMenu_SetText(self.expansionMenu, EXPANSIONS[self.expansion])

  self.phaseMenu = dropdown(frame, 104, function()
    local maxPhase = self.expansion == 1 and 6 or self.expansion == 2 and 5 or 4
    local values = {}
    for phase = 1, maxPhase do table.insert(values, { value = phase, label = phaseLabel(self.expansion, phase) }) end
    return values
  end, function(value)
    self.phase = value
    self.offset, self.plan = 0, nil
    self:Refresh()
  end)
  self.phaseMenu:SetPoint("LEFT", self.expansionMenu, "RIGHT", -8, 0)
  UIDropDownMenu_SetSelectedValue(self.phaseMenu, self.phase)
  UIDropDownMenu_SetText(self.phaseMenu, phaseLabel(self.expansion, self.phase))

  self.provider = label(frame, "")
  self.provider:SetPoint("TOPRIGHT", -20, -91)
  self.provider:SetTextColor(0.55, 0.75, 1)

  self.browserPanel = CreateFrame("Frame", nil, frame)
  self.browserPanel:SetPoint("TOPLEFT", 16, -120)
  self.browserPanel:SetPoint("BOTTOMRIGHT", -16, 16)
  self.browserPanel:EnableMouseWheel(true)
  self.browserPanel:SetScript("OnMouseWheel", function(_, delta)
    self.offset = math.max(0, math.min(math.max(0, #self.filtered - 12), self.offset - delta * 3))
    self:UpdateBrowserRows()
  end)
  self.search = editBox(self.browserPanel, 220, false)
  self.search:SetPoint("TOPLEFT", 4, -2)
  self.search:SetScript("OnTextChanged", function() self.offset = 0 self:UpdateBrowser() end)
  local rangeHeader = label(self.browserPanel, "Orange / Yellow / Green / Gray")
  rangeHeader:SetPoint("TOPLEFT", 256, -7)
  rangeHeader:SetSize(174, 18)
  rangeHeader:SetJustifyH("LEFT")
  local sourceHeader = label(self.browserPanel, "Source")
  sourceHeader:SetPoint("TOPLEFT", 440, -7)
  sourceHeader:SetSize(250, 18)
  sourceHeader:SetJustifyH("LEFT")
  self.recipeRows = {}
  for i = 1, 12 do self.recipeRows[i] = self:CreateRecipeRow(self.browserPanel, i) end
  self.browserCount = label(self.browserPanel, "")
  self.browserCount:SetPoint("BOTTOMLEFT", 6, 1)

  self.planPanel = CreateFrame("Frame", nil, frame)
  self.planPanel:SetPoint("TOPLEFT", 16, -120)
  self.planPanel:SetPoint("BOTTOMRIGHT", -16, 16)
  self.planPanel:EnableMouseWheel(true)
  self.planPanel:SetScript("OnMouseWheel", function(_, delta)
    local count = self.plan and #self.plan.steps or 0
    self.planOffset = math.max(0, math.min(math.max(0, count - 10), self.planOffset - delta * 3))
    self:UpdatePlanRows()
  end)
  local fromLabel = label(self.planPanel, "From")
  fromLabel:SetPoint("TOPLEFT", 5, -7)
  self.fromBox = editBox(self.planPanel, 50, true)
  self.fromBox:SetPoint("LEFT", fromLabel, "RIGHT", 7, 0)
  self.fromBox:SetText(self.skill)
  local toLabel = label(self.planPanel, "To")
  toLabel:SetPoint("LEFT", self.fromBox, "RIGHT", 14, 0)
  self.toBox = editBox(self.planPanel, 50, true)
  self.toBox:SetPoint("LEFT", toLabel, "RIGHT", 7, 0)
  self.toBox:SetText(client.maxSkill)
  self.buildButton = button(self.planPanel, "Calculate", 100, 24)
  self.buildButton:SetPoint("LEFT", self.toBox, "RIGHT", 15, 0)
  self.buildButton:SetScript("OnClick", function() self:BuildPlan() end)
  self.useBags = CreateFrame("CheckButton", nil, self.planPanel, "UICheckButtonTemplate")
  self.useBags:SetSize(24, 24)
  self.useBags:SetPoint("LEFT", self.buildButton, "RIGHT", 12, 0)
  self.useBags:SetChecked(true)
  self.useBagsLabel = label(self.planPanel, "Bags/bank")
  self.useBagsLabel:SetPoint("LEFT", self.useBags, "RIGHT", 2, 0)
  self.useBagsLabel:SetWidth(80)
  self.useBagsLabel:SetJustifyH("LEFT")
  self.useBags:SetScript("OnEnter", function(control)
    GameTooltip:SetOwner(control, "ANCHOR_BOTTOM")
    GameTooltip:SetText("Use current bags and bank")
    local provider = SPP.Inventory:GetAltProviderName()
    GameTooltip:AddLine(provider and ("Bank cache: " .. provider) or "Current bags are available; install Baganator or Bagnon to include the bank while away from it.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  self.useBags:SetScript("OnLeave", function() GameTooltip:Hide() end)
  self.useAlts = CreateFrame("CheckButton", nil, self.planPanel, "UICheckButtonTemplate")
  self.useAlts:SetSize(24, 24)
  self.useAlts:SetPoint("LEFT", self.useBagsLabel, "RIGHT", 8, 0)
  self.useAlts:SetChecked(ColeProfessionPlannerDB.useAltInventory == true)
  self.useAltsLabel = label(self.planPanel, "Alts/banks")
  self.useAltsLabel:SetPoint("LEFT", self.useAlts, "RIGHT", 2, 0)
  self.useAltsLabel:SetWidth(80)
  self.useAltsLabel:SetJustifyH("LEFT")
  self.useAlts:SetScript("OnClick", function(control)
    ColeProfessionPlannerDB.useAltInventory = control:GetChecked() == true
  end)
  self.useAlts:SetScript("OnEnter", function(control)
    GameTooltip:SetOwner(control, "ANCHOR_BOTTOM")
    GameTooltip:SetText("Use alt bags and banks")
    local provider = SPP.Inventory:GetAltProviderName()
    GameTooltip:AddLine(provider and ("Inventory cache: " .. provider) or "Install Baganator or Bagnon to cache alt inventory.", 1, 1, 1, true)
    GameTooltip:AddLine("The current character is excluded to avoid counting its bags twice.", 0.75, 0.75, 0.75, true)
    GameTooltip:Show()
  end)
  self.useAlts:SetScript("OnLeave", function() GameTooltip:Hide() end)
  self.includeRareRecipes = CreateFrame("CheckButton", nil, self.planPanel, "UICheckButtonTemplate")
  self.includeRareRecipes:SetSize(24, 24)
  self.includeRareRecipes:SetPoint("LEFT", self.useAltsLabel, "RIGHT", 8, 0)
  self.includeRareRecipes:SetChecked(true)
  self.includeRareRecipesLabel = label(self.planPanel, "AH recipes")
  self.includeRareRecipesLabel:SetPoint("LEFT", self.includeRareRecipes, "RIGHT", 2, 0)
  self.includeRareRecipes:SetScript("OnEnter", function(control)
    GameTooltip:SetOwner(control, "ANCHOR_BOTTOM")
    GameTooltip:SetText("Consider unknown recipes")
    GameTooltip:AddLine("Compare drop, quest, reputation and other recipes. Their Auctionator price is included before Cole uses them.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  self.includeRareRecipes:SetScript("OnLeave", function() GameTooltip:Hide() end)
  self.totalLabel = label(self.planPanel, "")
  self.totalLabel:SetPoint("TOPRIGHT", -6, -39)
  self.totalLabel:SetFontObject("GameFontNormal")
  self.miningNote = label(self.planPanel, "")
  self.miningNote:SetPoint("TOPLEFT", 5, -39)
  self.miningNote:SetWidth(500)
  self.miningNote:SetJustifyH("LEFT")
  self:UpdateMiningNote()
  local planSkillHeader = label(self.planPanel, "Skill")
  planSkillHeader:SetPoint("TOPLEFT", 12, -69)
  local planRecipeHeader = label(self.planPanel, "Recipe")
  planRecipeHeader:SetPoint("TOPLEFT", 113, -69)
  local planCraftHeader = label(self.planPanel, "Expected crafts")
  planCraftHeader:SetPoint("TOPLEFT", 403, -69)
  local planCostHeader = label(self.planPanel, "Cost")
  planCostHeader:SetPoint("TOPRIGHT", -14, -69)
  self.planRows = {}
  for i = 1, 10 do
    self.planRows[i] = self:CreatePlanRow(self.planPanel, i)
    self.planRows[i]:ClearAllPoints()
    self.planRows[i]:SetPoint("TOPLEFT", 8, -86 - ((i - 1) * 34))
    self.planRows[i]:SetPoint("TOPRIGHT", -8, -86 - ((i - 1) * 34))
  end
  self.planError = label(self.planPanel, "")
  self.planError:SetPoint("BOTTOMLEFT", 6, 2)
  self.planError:SetPoint("BOTTOMRIGHT", -6, 2)
  self.planError:SetTextColor(1, 0.35, 0.25)
  self.refreshPricesButton = button(self.planPanel, "Refresh all prices", 136, 22)
  self.refreshPricesButton:SetPoint("TOPRIGHT", -6, -2)
  self.refreshPricesButton:SetScript("OnClick", function()
    local refreshPlan, buildMessage = self:BuildFullRefreshPlan()
    local ok, message
    if refreshPlan then
      ok, message = SPP.Auctionator:RefreshPrices(refreshPlan)
    else
      ok, message = false, buildMessage
    end
    self.planError:SetTextColor(ok and 0.45 or 1, ok and 1 or 0.35, ok and 0.45 or 0.25)
    self.planError:SetText(message or "")
  end)
  self.refreshPricesButton:SetEnabled(true)

  self.shoppingPanel = CreateFrame("Frame", nil, frame)
  self.shoppingPanel:SetPoint("TOPLEFT", 16, -120)
  self.shoppingPanel:SetPoint("BOTTOMRIGHT", -16, 16)
  self.shoppingPanel:EnableMouseWheel(true)
  self.shoppingPanel:SetScript("OnMouseWheel", function(_, delta)
    local count = self.shoppingRowsData and #self.shoppingRowsData or 0
    self.shoppingOffset = math.max(0, math.min(math.max(0, count - 12), self.shoppingOffset - delta * 3))
    self:UpdateShoppingRows()
  end)
  self.listButton = button(self.shoppingPanel, "Create Auctionator list", 166, 24)
  self.listButton:SetPoint("TOPLEFT", 5, -2)
  self.listButton:SetScript("OnClick", function()
    local ok, message = SPP.Auctionator:CreateList(self.plan)
    self.shoppingStatus:SetTextColor(ok and 0.45 or 1, ok and 1 or 0.35, ok and 0.45 or 0.25)
    self.shoppingStatus:SetText(message or "")
  end)
  self.searchButton = button(self.shoppingPanel, "Search materials", 132, 24)
  self.searchButton:SetPoint("LEFT", self.listButton, "RIGHT", 6, 0)
  self.searchButton:SetScript("OnClick", function()
    local ok, message = SPP.Auctionator:Search(self.plan)
    self.shoppingStatus:SetTextColor(ok and 0.45 or 1, ok and 1 or 0.35, ok and 0.45 or 0.25)
    self.shoppingStatus:SetText(message or "")
  end)
  self.recipeSearchButton = button(self.shoppingPanel, "Search cheaper recipes", 158, 24)
  self.recipeSearchButton:SetPoint("LEFT", self.searchButton, "RIGHT", 6, 0)
  self.recipeSearchButton:SetScript("OnClick", function()
    local ok, message = SPP.Auctionator:SearchRecipeOpportunities(self.plan)
    self.shoppingStatus:SetTextColor(ok and 0.45 or 1, ok and 1 or 0.35, ok and 0.45 or 0.25)
    self.shoppingStatus:SetText(message or "")
  end)
  self.shoppingTotal = label(self.shoppingPanel, "")
  self.shoppingTotal:SetPoint("TOPRIGHT", -6, -7)
  self.shoppingTotal:SetFontObject("GameFontNormal")
  local materialHeader = label(self.shoppingPanel, "Material")
  materialHeader:SetPoint("TOPLEFT", 46, -41)
  local quantityHeader = label(self.shoppingPanel, "Need")
  quantityHeader:SetPoint("TOPLEFT", 480, -41)
  local materialCostHeader = label(self.shoppingPanel, "Estimated cost")
  materialCostHeader:SetPoint("TOPRIGHT", -14, -41)
  self.shoppingRows = {}
  for i = 1, 12 do self.shoppingRows[i] = self:CreateShoppingRow(self.shoppingPanel, i) end
  self.shoppingStatus = label(self.shoppingPanel, "")
  self.shoppingStatus:SetPoint("BOTTOMLEFT", 6, 2)
  self.shoppingStatus:SetPoint("BOTTOMRIGHT", -6, 2)
  self.shoppingStatus:SetTextColor(1, 0.35, 0.25)

  self:SetMode("planner")
end

function SPP.UI:SetMode(mode)
  self.mode = mode
  self.browserPanel:SetShown(mode == "browser")
  self.planPanel:SetShown(mode == "planner")
  self.shoppingPanel:SetShown(mode == "shopping")
  self:Refresh()
end

function SPP.UI:UpdateBrowser()
  self.filtered = {}
  local query = self.search and self.search:GetText():lower() or ""
  for _, recipe in ipairs(SPP.Data.professions[self.profession] or {}) do
    if SPP.Data:IsAvailable(recipe[SPP.R.EXPANSION], recipe[SPP.R.PHASE], self.expansion, self.phase) then
      local haystack = (recipe[SPP.R.NAME] .. " " .. SPP.Data:GetSourceSummary(recipe, self.expansion, self.phase)):lower()
      if query == "" or haystack:find(query, 1, true) then table.insert(self.filtered, recipe) end
    end
  end
  table.sort(self.filtered, function(a, b)
    if a[SPP.R.LEARN] == b[SPP.R.LEARN] then return a[SPP.R.NAME] < b[SPP.R.NAME] end
    return a[SPP.R.LEARN] < b[SPP.R.LEARN]
  end)
  self.offset = math.min(self.offset, math.max(0, #self.filtered - 12))
  self:UpdateBrowserRows()
end

function SPP.UI:UpdateBrowserRows()
  for index, row in ipairs(self.recipeRows) do setRowRecipe(row, self.filtered[self.offset + index], self.skill) end
  self.browserCount:SetText(string.format("%d recipes", #self.filtered))
end

function SPP.UI:BuildPlan()
  self.planError:SetTextColor(1, 0.35, 0.25)
  local fromSkill = tonumber(self.fromBox:GetText()) or 1
  local toSkill = tonumber(self.toBox:GetText()) or 375
  local options = self:GetPricingOptions()
  local candidateItems
  if self.useBags:GetChecked() or self.useAlts:GetChecked() then
    candidateItems = SPP.Planner:BuildRefreshShopping(self.profession, fromSkill, toSkill, options)
  end
  local inventory, currentInventory
  if self.useBags:GetChecked() then
    currentInventory = SPP.Inventory:GetBagCounts()
    local bankCounts = SPP.Inventory:GetCurrentBankCounts(candidateItems)
    currentInventory = SPP.Inventory:Merge(currentInventory, bankCounts)
    inventory = SPP.Inventory:Copy(currentInventory)
  end
  local altInfo
  if self.useAlts:GetChecked() then
    local altCounts
    altCounts, altInfo = SPP.Inventory:GetAltCounts(candidateItems)
    inventory = SPP.Inventory:Merge(inventory, altCounts)
    self.useAltsLabel:SetText("Alts/banks " .. SPP.Inventory:GetRelevantCount(altCounts))
  else
    self.useAltsLabel:SetText("Alts/banks")
  end
  options.inventory = inventory
  local plan, message, priceScan = SPP.Planner:Build(self.profession, fromSkill, toSkill, options)
  self.plan, self.planMessage = plan or priceScan, message
  self.shoppingTab:SetEnabled(self.plan ~= nil)
  if self.useBags:GetChecked() then
    self.useBagsLabel:SetText("Bags/bank " .. SPP.Inventory:GetRelevantCount(currentInventory))
  else
    self.useBagsLabel:SetText("Bags/bank")
  end
  local altProviderMissing = self.useAlts:GetChecked() and altInfo and not altInfo.provider
  self.planOffset, self.shoppingOffset = 0, 0
  self:UpdatePlanRows()
  self:UpdateShoppingRows()
  if self.plan and self.plan.priceDiscovery then self:SetMode("shopping") end
  if altProviderMissing then
    local status = self.mode == "shopping" and self.shoppingStatus or self.planError
    status:SetTextColor(1, 0.82, 0.2)
    status:SetText("Alt inventory needs Baganator or Bagnon; the route used current bags only.")
  end
end

function SPP.UI:BuildFullRefreshPlan()
  local fromSkill = tonumber(self.fromBox:GetText()) or 1
  local toSkill = tonumber(self.toBox:GetText()) or (self.expansion == 1 and 300 or 375)
  if fromSkill < 1 or toSkill <= fromSkill or toSkill > (self.expansion == 1 and 300 or 375) then
    return nil, "Choose a valid From/To range before refreshing prices"
  end
  local options = self:GetPricingOptions()
  local refreshShopping = SPP.Planner:BuildRefreshShopping(self.profession, fromSkill, toSkill, options)
  if not next(refreshShopping) then return nil, "No eligible recipe materials in this range" end
  return {
    profession = self.profession, fromSkill = fromSkill, toSkill = toSkill,
    shopping = self.plan and self.plan.profession == self.profession and self.plan.shopping or {},
    refreshShopping = refreshShopping,
    recipeOpportunities = self.plan and self.plan.profession == self.profession and self.plan.recipeOpportunities or {},
    refreshQuantityCap = SPP.Planner:GetRefreshQuantityCap(), fullMarketRefresh = true
  }
end

function SPP.UI:UpdatePlanRows()
  local steps = self.plan and self.plan.steps or {}
  for index, row in ipairs(self.planRows) do
    local step = steps[self.planOffset + index]
    if not step then row:Hide() else
      row:Show()
      row.skill:SetText(step.fromSkill .. " - " .. step.toSkill)
      row.name:SetText(step.recipe[SPP.R.NAME])
      row.icon:SetTexture(recipeIcon(step.recipe))
      row.crafts:SetText(string.format("%.1f", step.expectedCrafts))
      row.cost:SetText(SPP:FormatMoney(step.cost)
        .. (step.usedInventory and "  |cff75c94fbags|r" or "")
        .. (step.acquisitionItem and "  |cffffd34erecipe|r" or ""))
    end
  end
  local bagSuffix = self.plan and self.plan.usedInventory and " + bags" or ""
  if self.plan and self.plan.priceDiscovery then
    self.totalLabel:SetText("Prices needed: " .. self.plan.missingPriceCount)
  else
    self.totalLabel:SetText(self.plan and ("Total: " .. SPP:FormatMoney(self.plan.totalCost) .. bagSuffix) or "")
  end
  self.listButton:SetText(self.plan and self.plan.priceDiscovery and "Create scan list" or "Create Auctionator list")
  self.searchButton:SetText(self.plan and self.plan.priceDiscovery and "Scan prices" or "Search materials")
  self.listButton:SetEnabled(self.plan ~= nil)
  self.searchButton:SetEnabled(self.plan ~= nil)
  if self.plan and self.plan.priceDiscovery then
    self.planError:SetTextColor(1, 0.82, 0.2)
    self.planError:SetText(string.format(
      "%d auction prices are missing. Continue in Shopping list.",
      self.plan.missingPriceCount
    ))
  else
    self.planError:SetTextColor(1, 0.35, 0.25)
    self.planError:SetText(self.plan and "" or (self.planMessage or ""))
  end
  self:UpdatePriceFreshness()
end

function SPP.UI:UpdatePriceFreshness()
  if not self.refreshPricesButton then return end
  local stale, message = self:GetPlanPriceFreshness(self.plan)
  self.refreshPricesButton:Show()
  self.refreshPricesButton:SetEnabled(true)
  if stale then
    self.planError:SetTextColor(1, 0.82, 0.2)
    self.planError:SetText((message or "Auction prices are stale.") .. " Refresh at the Auction House, then calculate again.")
    if self.shoppingStatus and self.mode == "shopping" then
      self.shoppingStatus:SetTextColor(1, 0.82, 0.2)
      self.shoppingStatus:SetText((message or "Auction prices are stale.") .. " Refresh prices, then calculate again.")
    end
  end
end

function SPP.UI:OnAuctionPricesUpdated(count)
  if not self.frame then return end
  self.planError:SetTextColor(0.45, 1, 0.45)
  self.planError:SetText(string.format("Captured quantity pricing for %d materials. Click Calculate again.", count or 0))
  if self.shoppingStatus then
    self.shoppingStatus:SetTextColor(0.45, 1, 0.45)
    self.shoppingStatus:SetText(string.format("Quantity pricing updated for %d materials. Recalculate the route.", count or 0))
  end
end

function SPP.UI:UpdateShoppingRows()
  self.shoppingRowsData = SPP.Auctionator:GetShoppingRows(self.plan)
  self.shoppingOffset = math.min(self.shoppingOffset or 0, math.max(0, #self.shoppingRowsData - 12))
  local estimatedTotal = 0
  for index, row in ipairs(self.shoppingRows or {}) do
    local material = self.shoppingRowsData[self.shoppingOffset + index]
    if not material then
      row:Hide()
    else
      local unitPrice = SPP.Price:GetUnitPrice(material.itemId)
      row.icon:SetTexture(itemTexture(material.itemId))
      row.name:SetText(material.name)
      row.quantity:SetText("x" .. material.quantity)
      row.cost:SetText(unitPrice and SPP:FormatMoney(unitPrice * material.quantity) or "Price needed")
      row:Show()
    end
  end
  for _, material in ipairs(self.shoppingRowsData) do
    local unitPrice = SPP.Price:GetUnitPrice(material.itemId)
    if unitPrice then estimatedTotal = estimatedTotal + unitPrice * material.quantity end
  end
  if not self.plan then
    self.shoppingTotal:SetText("")
    self.shoppingStatus:SetTextColor(0.8, 0.8, 0.8)
    self.shoppingStatus:SetText("Calculate a profession route to build its shopping list.")
  elseif self.plan.priceDiscovery then
    self.shoppingTotal:SetText(string.format("%d prices needed", self.plan.missingPriceCount or #self.shoppingRowsData))
    self.shoppingStatus:SetTextColor(1, 0.82, 0.2)
    self.shoppingStatus:SetText("Open the Auction House, scan these materials, then return to Professions and calculate again.")
  else
    self.shoppingTotal:SetText(string.format("%d materials  |  %s", #self.shoppingRowsData, SPP:FormatMoney(estimatedTotal)))
    local opportunityCount = #(self.plan.recipeOpportunities or {})
    self.shoppingStatus:SetText(opportunityCount > 0 and string.format("%d unknown recipe%s may reduce the route cost.", opportunityCount, opportunityCount == 1 and "" or "s") or "")
  end
  self.listButton:SetText(self.plan and self.plan.priceDiscovery and "Create scan list" or "Create Auctionator list")
  self.searchButton:SetText(self.plan and self.plan.priceDiscovery and "Scan prices" or "Search materials")
  self.listButton:SetEnabled(self.plan ~= nil and #self.shoppingRowsData > 0)
  self.searchButton:SetEnabled(self.plan ~= nil and #self.shoppingRowsData > 0)
  local opportunityCount = self.plan and #(self.plan.recipeOpportunities or {}) or 0
  self.recipeSearchButton:SetShown(not (self.plan and self.plan.priceDiscovery))
  self.recipeSearchButton:SetEnabled(opportunityCount > 0)
  self:UpdatePriceFreshness()
end

function SPP.UI:Refresh()
  if not self.frame then return end
  local client = SPP.Client:GetInfo()
  self.clientLabel:SetText(string.format("%s %s  |  Phase %d", client.label, client.version or "", client.phase))
  local choices = SPP.Client:GetProfessionChoices()
  for _, choice in ipairs(choices) do
    if choice.value == self.profession then
      UIDropDownMenu_SetText(self.professionMenu, choice.label)
      break
    end
  end
  self.provider:SetText(SPP.Price:GetProviderLabel())
  self:UpdateProfessionButton()
  self:UpdateMiningNote()
  self.shoppingTab:SetEnabled(self.plan ~= nil)
  if self.mode == "browser" then
    self:UpdateBrowser()
  elseif self.mode == "shopping" then
    self:UpdateShoppingRows()
  else
    self:UpdatePlanRows()
  end
end

function SPP.UI:Toggle()
  self:Create()
  if self.frame:IsShown() then
    self.frame:Hide()
  else
    self:SyncProfessionSkill(true)
    self.frame:Show()
    self:Refresh()
  end
end
