SPP.UI = SPP.UI or { offset = 0, planOffset = 0, shoppingOffset = 0, mode = "planner", recipeIcons = {}, knownRecipes = {} }

local COLORS = {
  orange = { 1, 0.5, 0 }, yellow = { 1, 0.9, 0.15 }, green = { 0.25, 0.9, 0.35 },
  gray = { 0.55, 0.55, 0.55 }, locked = { 0.45, 0.45, 0.45 }
}
local EXPANSIONS = { "Vanilla", "The Burning Crusade" }
local PRICE_TTL_SECONDS = 30 * 60
local VISIBLE_PLAN_ROWS = 8
local VISIBLE_SHOPPING_ROWS = 10
local BAR_RELATED_PROFESSIONS = { blacksmithing = true, engineering = true, jewelcrafting = true }
local ROUTE_MODES = {
  { value = "fast", label = "Fast - orange first" },
  { value = "economy", label = "Economy - green allowed" }
}

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

local function formatQuantity(quantity)
  local rounded = math.floor(quantity + 0.5)
  if math.abs(quantity - rounded) < 0.05 then return tostring(rounded) end
  return string.format("%.1f", quantity)
end

local function formatDuration(seconds, estimated)
  local total = math.max(0, math.floor((seconds or 0) + 0.5))
  local minutes = math.floor(total / 60)
  local remainder = total % 60
  local text = minutes > 0 and string.format("%dm %02ds", minutes, remainder) or (remainder .. "s")
  return estimated and ("~" .. text) or text
end

local function getStepMaterialRows(step)
  local rows = {}
  for itemId, quantity in pairs(step and step.materials or {}) do
    if quantity > 0.001 then
      table.insert(rows, { itemId = itemId, name = SPP.Data:GetItemName(itemId), quantity = quantity })
    end
  end
  table.sort(rows, function(a, b) return a.name < b.name end)
  return rows
end

local function formatStepMaterials(step)
  local parts = {}
  for _, material in ipairs(getStepMaterialRows(step)) do
    table.insert(parts, material.name .. " x" .. formatQuantity(material.quantity))
  end
  return #parts > 0 and table.concat(parts, ", ") or "No shopping materials"
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
  row:SetHeight(40)
  row:SetFrameLevel(parent:GetFrameLevel() + 1)
  row:SetPoint("TOPLEFT", 8, -30 - ((index - 1) * 34))
  row:SetPoint("TOPRIGHT", -8, -30 - ((index - 1) * 34))
  row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  row.skill = label(row, "")
  row.skill:SetPoint("LEFT", 34, 0)
  row.skill:SetWidth(58)
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(26, 26)
  row.icon:SetPoint("LEFT", 3, 0)
  row.name = label(row, "")
  row.name:SetPoint("TOPLEFT", 94, -3)
  row.name:SetPoint("RIGHT", -199, 0)
  row.name:SetJustifyH("LEFT")
  row.materials = label(row, "", "GameFontDisableSmall")
  row.materials:SetPoint("BOTTOMLEFT", 94, 3)
  row.materials:SetPoint("RIGHT", -199, 0)
  row.materials:SetJustifyH("LEFT")
  row.materials:SetTextColor(0.68, 0.74, 0.68)
  row.crafts = label(row, "")
  row.crafts:SetPoint("RIGHT", -151, 0)
  row.crafts:SetWidth(42)
  row.crafts:SetJustifyH("RIGHT")
  row.time = label(row, "")
  row.time:SetPoint("RIGHT", -99, 0)
  row.time:SetWidth(48)
  row.time:SetJustifyH("RIGHT")
  row.cost = label(row, "")
  row.cost:SetPoint("RIGHT", -5, 0)
  row.cost:SetWidth(90)
  row.cost:SetJustifyH("RIGHT")
  row:SetScript("OnEnter", function(self)
    if not self.step then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(self.step.recipe[SPP.R.NAME], 1, 1, 1)
    GameTooltip:AddDoubleLine("Skill", self.step.fromSkill .. " - " .. self.step.toSkill, 0.7, 0.8, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("Expected crafts", string.format("%.1f", self.step.expectedCrafts), 0.7, 0.8, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("Craft time", formatDuration(self.step.craftSeconds, self.step.craftTimeEstimated), 0.7, 0.8, 1, 1, 1, 1)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Shopping materials for this step", 1, 0.82, 0)
    local materials = getStepMaterialRows(self.step)
    if #materials == 0 then
      GameTooltip:AddLine("None; covered by bags or earlier crafted outputs.", 0.55, 0.85, 0.55, true)
    else
      for _, material in ipairs(materials) do
        GameTooltip:AddDoubleLine(material.name, "x" .. formatQuantity(material.quantity), 0.9, 0.9, 0.9, 1, 1, 1)
      end
    end
    if self.step.craftTimeEstimated then
      GameTooltip:AddLine("Time uses the 3-second fallback because the client did not expose this recipe's cast time.", 0.75, 0.75, 0.75, true)
    end
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  row:Hide()
  return row
end

function SPP.UI:CreateShoppingRow(parent, index)
  local row = CreateFrame("Button", nil, parent)
  row:SetHeight(32)
  row:SetPoint("TOPLEFT", 5, -72 - ((index - 1) * 34))
  row:SetPoint("TOPRIGHT", -5, -72 - ((index - 1) * 34))
  row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(24, 24)
  row.icon:SetPoint("LEFT", 3, 0)
  row.name = label(row, "")
  row.name:SetPoint("LEFT", 33, 0)
  row.name:SetPoint("RIGHT", -128, 0)
  row.name:SetJustifyH("LEFT")
  row.quantity = label(row, "")
  row.quantity:SetPoint("RIGHT", -88, 0)
  row.quantity:SetWidth(38)
  row.quantity:SetJustifyH("RIGHT")
  row.cost = label(row, "")
  row.cost:SetPoint("RIGHT", -6, 0)
  row.cost:SetWidth(84)
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
    routeMode = self.routeMode == "fast" and "fast" or "economy",
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
  self.routeMode = ColeProfessionPlannerDB.routeMode == "fast" and "fast" or "economy"

  local frame = CreateFrame("Frame", "ColeProfessionPlannerFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  self.frame = frame
  frame:SetSize(1050, 620)
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

  self.planTab = button(frame, "Planner", 100, 24)
  self.planTab:SetPoint("TOPLEFT", 18, -48)
  self.browserTab = button(frame, "Recipe library", 112, 24)
  self.browserTab:SetPoint("LEFT", self.planTab, "RIGHT", 4, 0)
  self.planTab:SetScript("OnClick", function() SPP.UI:SetMode("planner") end)
  self.browserTab:SetScript("OnClick", function() SPP.UI:SetMode("browser") end)

  self.provider = label(frame, "")
  self.provider:SetPoint("TOPRIGHT", -180, -55)
  self.provider:SetTextColor(0.55, 0.75, 1)
  self.refreshPricesButton = button(frame, "Refresh range prices", 154, 24)
  self.refreshPricesButton:SetPoint("TOPRIGHT", -18, -48)
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
  self.refreshPricesButton:SetScript("OnEnter", function(control)
    GameTooltip:SetOwner(control, "ANCHOR_BOTTOM")
    GameTooltip:SetText("Refresh prices for the selected range")
    GameTooltip:AddLine("Scans materials and unknown recipe items only for recipes that can give skill between From and To.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  self.refreshPricesButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
  self.refreshPricesButton:SetEnabled(true)

  self.browserPanel = CreateFrame("Frame", nil, frame)
  self.browserPanel:SetPoint("TOPLEFT", 16, -82)
  self.browserPanel:SetPoint("BOTTOMRIGHT", -16, 16)
  self.browserPanel:EnableMouseWheel(true)
  self.browserPanel:SetScript("OnMouseWheel", function(_, delta)
    self.offset = math.max(0, math.min(math.max(0, #self.filtered - 12), self.offset - delta * 3))
    self:UpdateBrowserRows()
  end)
  self.search = editBox(self.browserPanel, 240, false)
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
  self.planPanel:SetPoint("TOPLEFT", 16, -82)
  self.planPanel:SetPoint("BOTTOMRIGHT", -16, 16)

  self.settingsPanel = CreateFrame("Frame", nil, self.planPanel)
  self.settingsPanel:SetPoint("TOPLEFT")
  self.settingsPanel:SetPoint("BOTTOMLEFT")
  self.settingsPanel:SetWidth(220)
  local settingsSeparator = self.planPanel:CreateTexture(nil, "BORDER")
  settingsSeparator:SetPoint("TOPLEFT", self.settingsPanel, "TOPRIGHT", 2, 0)
  settingsSeparator:SetPoint("BOTTOMLEFT", self.settingsPanel, "BOTTOMRIGHT", 2, 0)
  settingsSeparator:SetWidth(1)
  settingsSeparator:SetTexture("Interface\\Buttons\\WHITE8X8")
  settingsSeparator:SetVertexColor(0.28, 0.32, 0.27, 0.8)

  self.shoppingPanel = CreateFrame("Frame", nil, self.planPanel)
  self.shoppingPanel:SetPoint("TOPRIGHT")
  self.shoppingPanel:SetPoint("BOTTOMRIGHT")
  self.shoppingPanel:SetWidth(278)
  self.shoppingPanel:EnableMouseWheel(true)
  self.shoppingPanel:SetScript("OnMouseWheel", function(_, delta)
    local count = self.shoppingRowsData and #self.shoppingRowsData or 0
    self.shoppingOffset = math.max(0, math.min(math.max(0, count - VISIBLE_SHOPPING_ROWS), self.shoppingOffset - delta * 3))
    self:UpdateShoppingRows()
  end)
  local shoppingSeparator = self.planPanel:CreateTexture(nil, "BORDER")
  shoppingSeparator:SetPoint("TOPRIGHT", self.shoppingPanel, "TOPLEFT", -2, 0)
  shoppingSeparator:SetPoint("BOTTOMRIGHT", self.shoppingPanel, "BOTTOMLEFT", -2, 0)
  shoppingSeparator:SetWidth(1)
  shoppingSeparator:SetTexture("Interface\\Buttons\\WHITE8X8")
  shoppingSeparator:SetVertexColor(0.28, 0.32, 0.27, 0.8)

  self.routePanel = CreateFrame("Frame", nil, self.planPanel)
  self.routePanel:SetPoint("TOPLEFT", self.settingsPanel, "TOPRIGHT", 8, 0)
  self.routePanel:SetPoint("BOTTOMRIGHT", self.shoppingPanel, "BOTTOMLEFT", -8, 0)
  self.routePanel:EnableMouseWheel(true)
  self.routePanel:SetScript("OnMouseWheel", function(_, delta)
    local count = self.plan and #self.plan.steps or 0
    self.planOffset = math.max(0, math.min(math.max(0, count - VISIBLE_PLAN_ROWS), self.planOffset - delta * 3))
    self:UpdatePlanRows()
  end)

  local settingsTitle = label(self.settingsPanel, "Plan profession", "GameFontNormal")
  settingsTitle:SetPoint("TOPLEFT", 10, -8)

  local professionValues = function()
    return SPP.Client:GetProfessionChoices()
  end
  self.professionMenu = dropdown(self.settingsPanel, 145, professionValues, function(value)
    self.profession = value
    self.skill = 1
    self:SyncProfessionSkill(true)
    self.offset, self.planOffset, self.shoppingOffset, self.plan = 0, 0, 0, nil
    self:Refresh()
  end)
  self.professionMenu:SetPoint("TOPLEFT", 38, -31)
  UIDropDownMenu_SetSelectedValue(self.professionMenu, self.profession)
  UIDropDownMenu_SetText(self.professionMenu, professionChoices[1] and professionChoices[1].label or "Alchemy")
  self.openProfessionButton = CreateFrame("Button", nil, self.settingsPanel, "UIPanelButtonTemplate")
  self.openProfessionButton:SetSize(26, 26)
  self.openProfessionButton:SetPoint("TOPLEFT", 8, -32)
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

  self.expansionMenu = dropdown(self.settingsPanel, 174, function() return EXPANSIONS end, function(value)
    self.expansion = value
    self.phase = SPP.Client:GetDefaultPhase(value)
    if self.phaseMenu then
      UIDropDownMenu_SetSelectedValue(self.phaseMenu, self.phase)
      UIDropDownMenu_SetText(self.phaseMenu, phaseLabel(self.expansion, self.phase))
    end
    self.offset, self.plan = 0, nil
    self:Refresh()
  end)
  self.expansionMenu:SetPoint("TOPLEFT", 0, -70)
  UIDropDownMenu_SetSelectedValue(self.expansionMenu, self.expansion)
  UIDropDownMenu_SetText(self.expansionMenu, EXPANSIONS[self.expansion])

  self.phaseMenu = dropdown(self.settingsPanel, 174, function()
    local maxPhase = self.expansion == 1 and 6 or self.expansion == 2 and 5 or 4
    local values = {}
    for phase = 1, maxPhase do table.insert(values, { value = phase, label = phaseLabel(self.expansion, phase) }) end
    return values
  end, function(value)
    self.phase = value
    self.offset, self.plan = 0, nil
    self:Refresh()
  end)
  self.phaseMenu:SetPoint("TOPLEFT", 0, -105)
  UIDropDownMenu_SetSelectedValue(self.phaseMenu, self.phase)
  UIDropDownMenu_SetText(self.phaseMenu, phaseLabel(self.expansion, self.phase))

  local fromLabel = label(self.settingsPanel, "From")
  fromLabel:SetPoint("TOPLEFT", 10, -151)
  self.fromBox = editBox(self.settingsPanel, 50, true)
  self.fromBox:SetPoint("LEFT", fromLabel, "RIGHT", 7, 0)
  self.fromBox:SetText(self.skill)
  local toLabel = label(self.settingsPanel, "To")
  toLabel:SetPoint("LEFT", self.fromBox, "RIGHT", 14, 0)
  self.toBox = editBox(self.settingsPanel, 50, true)
  self.toBox:SetPoint("LEFT", toLabel, "RIGHT", 7, 0)
  self.toBox:SetText(client.maxSkill)

  local modeLabel = label(self.settingsPanel, "Calculation mode")
  modeLabel:SetPoint("TOPLEFT", 10, -184)
  self.routeModeMenu = dropdown(self.settingsPanel, 174, function() return ROUTE_MODES end, function(value)
    self.routeMode = value == "fast" and "fast" or "economy"
    ColeProfessionPlannerDB.routeMode = self.routeMode
    self.plan, self.planMessage = nil, nil
    self.planOffset, self.shoppingOffset = 0, 0
    self:Refresh()
  end)
  self.routeModeMenu:SetPoint("TOPLEFT", 0, -199)
  UIDropDownMenu_SetSelectedValue(self.routeModeMenu, self.routeMode)
  UIDropDownMenu_SetText(self.routeModeMenu, self.routeMode == "fast" and ROUTE_MODES[1].label or ROUTE_MODES[2].label)
  self.routeModeMenu:SetScript("OnEnter", function(control)
    GameTooltip:SetOwner(control, "ANCHOR_RIGHT")
    GameTooltip:SetText("Calculation mode")
    GameTooltip:AddLine("Fast favors guaranteed orange skill-ups and shorter craft time.", 1, 1, 1, true)
    GameTooltip:AddLine("Economy allows green recipes and minimizes the full material cost.", 0.75, 0.9, 0.75, true)
    GameTooltip:Show()
  end)
  self.routeModeMenu:SetScript("OnLeave", function() GameTooltip:Hide() end)

  self.useBags = CreateFrame("CheckButton", nil, self.settingsPanel, "UICheckButtonTemplate")
  self.useBags:SetSize(24, 24)
  self.useBags:SetPoint("TOPLEFT", 7, -240)
  self.useBags:SetChecked(true)
  self.useBagsLabel = label(self.settingsPanel, "Bags/bank")
  self.useBagsLabel:SetPoint("LEFT", self.useBags, "RIGHT", 2, 0)
  self.useBagsLabel:SetWidth(150)
  self.useBagsLabel:SetJustifyH("LEFT")
  self.useBags:SetScript("OnEnter", function(control)
    GameTooltip:SetOwner(control, "ANCHOR_RIGHT")
    GameTooltip:SetText("Use current bags and bank")
    local provider = SPP.Inventory:GetAltProviderName()
    GameTooltip:AddLine(provider and ("Bank cache: " .. provider) or "Current bags are available; install Baganator or Bagnon to include the bank while away from it.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  self.useBags:SetScript("OnLeave", function() GameTooltip:Hide() end)
  self.useAlts = CreateFrame("CheckButton", nil, self.settingsPanel, "UICheckButtonTemplate")
  self.useAlts:SetSize(24, 24)
  self.useAlts:SetPoint("TOPLEFT", 7, -269)
  self.useAlts:SetChecked(ColeProfessionPlannerDB.useAltInventory == true)
  self.useAltsLabel = label(self.settingsPanel, "Alts/banks")
  self.useAltsLabel:SetPoint("LEFT", self.useAlts, "RIGHT", 2, 0)
  self.useAltsLabel:SetWidth(150)
  self.useAltsLabel:SetJustifyH("LEFT")
  self.useAlts:SetScript("OnClick", function(control)
    ColeProfessionPlannerDB.useAltInventory = control:GetChecked() == true
  end)
  self.useAlts:SetScript("OnEnter", function(control)
    GameTooltip:SetOwner(control, "ANCHOR_RIGHT")
    GameTooltip:SetText("Use alt bags and banks")
    local provider = SPP.Inventory:GetAltProviderName()
    GameTooltip:AddLine(provider and ("Inventory cache: " .. provider) or "Install Baganator or Bagnon to cache alt inventory.", 1, 1, 1, true)
    GameTooltip:AddLine("The current character is excluded to avoid counting its bags twice.", 0.75, 0.75, 0.75, true)
    GameTooltip:Show()
  end)
  self.useAlts:SetScript("OnLeave", function() GameTooltip:Hide() end)
  self.includeRareRecipes = CreateFrame("CheckButton", nil, self.settingsPanel, "UICheckButtonTemplate")
  self.includeRareRecipes:SetSize(24, 24)
  self.includeRareRecipes:SetPoint("TOPLEFT", 7, -298)
  self.includeRareRecipes:SetChecked(true)
  self.includeRareRecipesLabel = label(self.settingsPanel, "Auction recipes")
  self.includeRareRecipesLabel:SetPoint("LEFT", self.includeRareRecipes, "RIGHT", 2, 0)
  self.includeRareRecipes:SetScript("OnEnter", function(control)
    GameTooltip:SetOwner(control, "ANCHOR_RIGHT")
    GameTooltip:SetText("Consider unknown recipes")
    GameTooltip:AddLine("An unknown drop, quest or reputation recipe is used only after a fresh Auctionator scan confirms at least one copy for sale.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  self.includeRareRecipes:SetScript("OnLeave", function() GameTooltip:Hide() end)

  self.buildButton = button(self.settingsPanel, "Calculate route", 188, 28)
  self.buildButton:SetPoint("TOPLEFT", 10, -335)
  self.buildButton:SetScript("OnClick", function() self:BuildPlan() end)

  self.totalLabel = label(self.settingsPanel, "")
  self.totalLabel:SetPoint("TOPLEFT", 10, -377)
  self.totalLabel:SetWidth(190)
  self.totalLabel:SetJustifyH("LEFT")
  self.totalLabel:SetFontObject("GameFontNormal")
  self.selectionLabel = label(self.settingsPanel, "", "GameFontDisableSmall")
  self.selectionLabel:SetPoint("TOPLEFT", 10, -400)
  self.selectionLabel:SetWidth(190)
  self.selectionLabel:SetJustifyH("LEFT")
  self.miningNote = label(self.settingsPanel, "")
  self.miningNote:SetPoint("TOPLEFT", 10, -435)
  self.miningNote:SetWidth(190)
  self.miningNote:SetJustifyH("LEFT")
  self:UpdateMiningNote()

  local routeTitle = label(self.routePanel, "Leveling route", "GameFontNormal")
  routeTitle:SetPoint("TOPLEFT", 8, -8)
  local planSkillHeader = label(self.routePanel, "Skill")
  planSkillHeader:SetPoint("TOPLEFT", 12, -34)
  local planRecipeHeader = label(self.routePanel, "Recipe and materials")
  planRecipeHeader:SetPoint("TOPLEFT", 102, -34)
  local planCraftHeader = label(self.routePanel, "Crafts")
  planCraftHeader:SetPoint("TOPRIGHT", -151, -34)
  local planTimeHeader = label(self.routePanel, "Time")
  planTimeHeader:SetPoint("TOPRIGHT", -101, -34)
  local planCostHeader = label(self.routePanel, "Cost")
  planCostHeader:SetPoint("TOPRIGHT", -8, -34)
  self.planRows = {}
  for i = 1, VISIBLE_PLAN_ROWS do
    self.planRows[i] = self:CreatePlanRow(self.routePanel, i)
    self.planRows[i]:ClearAllPoints()
    self.planRows[i]:SetPoint("TOPLEFT", 4, -48 - ((i - 1) * 46))
    self.planRows[i]:SetPoint("TOPRIGHT", -4, -48 - ((i - 1) * 46))
  end
  self.planError = label(self.routePanel, "")
  self.planError:SetPoint("BOTTOMLEFT", 6, 2)
  self.planError:SetPoint("BOTTOMRIGHT", -6, 2)
  self.planError:SetTextColor(1, 0.35, 0.25)

  local shoppingTitle = label(self.shoppingPanel, "Shopping list", "GameFontNormal")
  shoppingTitle:SetPoint("TOPLEFT", 8, -8)
  self.shoppingTotal = label(self.shoppingPanel, "")
  self.shoppingTotal:SetPoint("TOPLEFT", 8, -29)
  self.shoppingTotal:SetPoint("TOPRIGHT", -8, -29)
  self.shoppingTotal:SetJustifyH("LEFT")
  self.shoppingTotal:SetFontObject("GameFontNormal")
  local materialHeader = label(self.shoppingPanel, "Material")
  materialHeader:SetPoint("TOPLEFT", 38, -56)
  local quantityHeader = label(self.shoppingPanel, "Need")
  quantityHeader:SetPoint("TOPRIGHT", -91, -56)
  local materialCostHeader = label(self.shoppingPanel, "Cost")
  materialCostHeader:SetPoint("TOPRIGHT", -8, -56)
  self.shoppingRows = {}
  for i = 1, VISIBLE_SHOPPING_ROWS do self.shoppingRows[i] = self:CreateShoppingRow(self.shoppingPanel, i) end
  self.shoppingStatus = label(self.shoppingPanel, "")
  self.shoppingStatus:SetPoint("BOTTOMLEFT", 7, 64)
  self.shoppingStatus:SetPoint("BOTTOMRIGHT", -7, 64)
  self.shoppingStatus:SetHeight(38)
  self.shoppingStatus:SetJustifyH("LEFT")
  self.shoppingStatus:SetTextColor(1, 0.35, 0.25)

  self.listButton = button(self.shoppingPanel, "Create list", 124, 24)
  self.listButton:SetPoint("BOTTOMLEFT", 7, 35)
  self.listButton:SetScript("OnClick", function()
    local ok, message = SPP.Auctionator:CreateList(self.plan)
    self.shoppingStatus:SetTextColor(ok and 0.45 or 1, ok and 1 or 0.35, ok and 0.45 or 0.25)
    self.shoppingStatus:SetText(message or "")
  end)
  self.recipeSearchButton = button(self.shoppingPanel, "Recipe prices", 124, 24)
  self.recipeSearchButton:SetPoint("BOTTOMRIGHT", -7, 35)
  self.recipeSearchButton:SetScript("OnClick", function()
    local ok, message = SPP.Auctionator:SearchRecipeOpportunities(self.plan)
    self.shoppingStatus:SetTextColor(ok and 0.45 or 1, ok and 1 or 0.35, ok and 0.45 or 0.25)
    self.shoppingStatus:SetText(message or "")
  end)
  self.searchButton = button(self.shoppingPanel, "Search at Auction House", 250, 26)
  self.searchButton:SetPoint("BOTTOM", 0, 6)
  self.searchButton:SetScript("OnClick", function()
    local ok, message = SPP.Auctionator:Search(self.plan)
    self.shoppingStatus:SetTextColor(ok and 0.45 or 1, ok and 1 or 0.35, ok and 0.45 or 0.25)
    self.shoppingStatus:SetText(message or "")
  end)

  self:SetMode("planner")
end

function SPP.UI:SetMode(mode)
  self.mode = mode == "browser" and "browser" or "planner"
  self.browserPanel:SetShown(self.mode == "browser")
  self.planPanel:SetShown(self.mode == "planner")
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
  if self.useBags:GetChecked() then
    self.useBagsLabel:SetText("Bags/bank " .. SPP.Inventory:GetRelevantCount(currentInventory))
  else
    self.useBagsLabel:SetText("Bags/bank")
  end
  local altProviderMissing = self.useAlts:GetChecked() and altInfo and not altInfo.provider
  self.planOffset, self.shoppingOffset = 0, 0
  self:UpdatePlanRows()
  self:UpdateShoppingRows()
  if altProviderMissing then
    local status = self.shoppingStatus or self.planError
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
  local existingPlan = self.plan
  local planMatchesRange = existingPlan
    and existingPlan.profession == self.profession
    and existingPlan.fromSkill == fromSkill
    and existingPlan.toSkill == toSkill
    and existingPlan.maxExpansion == self.expansion
    and existingPlan.maxPhase == self.phase
  return {
    profession = self.profession, fromSkill = fromSkill, toSkill = toSkill,
    maxExpansion = self.expansion, maxPhase = self.phase,
    shopping = planMatchesRange and existingPlan.shopping or {},
    refreshShopping = refreshShopping,
    recipeOpportunities = planMatchesRange and existingPlan.recipeOpportunities or {},
    refreshQuantityCap = SPP.Planner:GetRefreshQuantityCap(), fullMarketRefresh = true
  }
end

function SPP.UI:UpdatePlanRows()
  local steps = self.plan and self.plan.steps or {}
  for index, row in ipairs(self.planRows) do
    local step = steps[self.planOffset + index]
    if not step then row:Hide() else
      row.step = step
      row:Show()
      row.skill:SetText(step.fromSkill .. " - " .. step.toSkill)
      row.name:SetText(step.recipe[SPP.R.NAME])
      row.icon:SetTexture(recipeIcon(step.recipe))
      row.materials:SetText(formatStepMaterials(step))
      row.crafts:SetText(string.format("%.1f", step.expectedCrafts))
      row.time:SetText(formatDuration(step.craftSeconds, step.craftTimeEstimated))
      row.cost:SetText(SPP:FormatMoney(step.cost)
        .. (step.usedInventory and "  |cff75c94fbags|r" or "")
        .. (step.acquisitionItem and "  |cffffd34erecipe|r" or ""))
    end
    if not step then row.step = nil end
  end
  local bagSuffix = self.plan and self.plan.usedInventory and " + bags" or ""
  if self.plan and self.plan.priceDiscovery then
    self.totalLabel:SetText("Prices needed: " .. self.plan.missingPriceCount)
  else
    self.totalLabel:SetText(self.plan and ("Total: " .. SPP:FormatMoney(self.plan.totalCost) .. bagSuffix) or "")
  end
  local totalSeconds = 0
  for _, step in ipairs(steps) do totalSeconds = totalSeconds + (step.craftSeconds or 0) end
  if self.selectionLabel then
    local selection = self.plan and self.plan.selection or (self.routeMode == "fast"
      and "Fast: orange recipes first"
      or "Economy: green recipes allowed")
    self.selectionLabel:SetText(selection .. (self.plan and ("\nCraft time: " .. formatDuration(totalSeconds)) or ""))
  end
  self.listButton:SetText(self.plan and self.plan.priceDiscovery and "Create scan list" or "Create list")
  self.searchButton:SetText(self.plan and self.plan.priceDiscovery and "Scan prices at Auction House" or "Search at Auction House")
  self.listButton:SetEnabled(self.plan ~= nil)
  self.searchButton:SetEnabled(self.plan ~= nil)
  if self.plan and self.plan.priceDiscovery then
    self.planError:SetTextColor(1, 0.82, 0.2)
    self.planError:SetText(string.format(
      "%d auction prices are missing. Use Search at Auction House on the right.",
      self.plan.missingPriceCount
    ))
  else
    local skipped = self.plan and self.plan.skippedMissingPriceCount or 0
    if skipped > 0 then
      self.planError:SetTextColor(1, 0.82, 0.2)
      self.planError:SetText(string.format(
        "Route calculated; %d optional material price%s missing. Refresh range prices for a complete comparison.",
        skipped, skipped == 1 and " is" or "s are"
      ))
    else
      self.planError:SetTextColor(1, 0.35, 0.25)
      self.planError:SetText(self.plan and "" or (self.planMessage or ""))
    end
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
    self.planError:SetText((message or "Auction prices are stale.") .. " Refresh at the Auction House; the route will recalculate after the scan.")
    if self.shoppingStatus then
      self.shoppingStatus:SetTextColor(1, 0.82, 0.2)
      self.shoppingStatus:SetText((message or "Auction prices are stale.") .. " Refresh prices to update the route.")
    end
  end
end

function SPP.UI:OnAuctionPricesUpdated(count)
  if not self.frame then return end
  self:BuildPlan()
  local message = string.format("Updated quantity pricing for %d auction items and recalculated the route.", count or 0)
  self.planError:SetTextColor(0.45, 1, 0.45)
  self.planError:SetText(message)
  self.shoppingStatus:SetTextColor(0.45, 1, 0.45)
  self.shoppingStatus:SetText(message)
end

function SPP.UI:UpdateShoppingRows()
  self.shoppingRowsData = SPP.Auctionator:GetShoppingRows(self.plan)
  local auctionRows = SPP.Auctionator:GetShoppingRows(self.plan, true)
  self.shoppingOffset = math.min(self.shoppingOffset or 0, math.max(0, #self.shoppingRowsData - VISIBLE_SHOPPING_ROWS))
  local estimatedTotal, vendorCount = 0, 0
  for index, row in ipairs(self.shoppingRows or {}) do
    local material = self.shoppingRowsData[self.shoppingOffset + index]
    if not material then
      row:Hide()
    else
      local unitPrice = SPP.Price:GetUnitPrice(material.itemId)
      row.icon:SetTexture(itemTexture(material.itemId))
      row.name:SetText(material.name)
      row.quantity:SetText("x" .. material.quantity)
      row.cost:SetText((unitPrice and SPP:FormatMoney(unitPrice * material.quantity) or "Price needed")
        .. (material.vendor and "  |cff75c94fVendor|r" or ""))
      row:Show()
    end
  end
  for _, material in ipairs(self.shoppingRowsData) do
    local unitPrice = SPP.Price:GetUnitPrice(material.itemId)
    if unitPrice then estimatedTotal = estimatedTotal + unitPrice * material.quantity end
    if material.vendor then vendorCount = vendorCount + 1 end
  end
  if not self.plan then
    self.shoppingTotal:SetText("")
    self.shoppingStatus:SetTextColor(0.8, 0.8, 0.8)
    self.shoppingStatus:SetText("Calculate a profession route to build its shopping list.")
  elseif self.plan.priceDiscovery then
    self.shoppingTotal:SetText(string.format("%d prices needed", self.plan.missingPriceCount or #self.shoppingRowsData))
    self.shoppingStatus:SetTextColor(1, 0.82, 0.2)
    self.shoppingStatus:SetText("Open the Auction House and scan these items. Cole recalculates when the scan finishes.")
  else
    self.shoppingTotal:SetText(string.format(
      "%d materials%s  |  %s",
      #self.shoppingRowsData, vendorCount > 0 and (" (" .. vendorCount .. " vendor)") or "",
      SPP:FormatMoney(estimatedTotal)
    ))
    local opportunityCount = #(self.plan.recipeOpportunities or {})
    local notes = {}
    if vendorCount > 0 then
      table.insert(notes, string.format("Vendor supplies: %d (excluded from Auctionator).", vendorCount))
    end
    if opportunityCount > 0 then
      table.insert(notes, string.format("Unknown cheaper recipes: %d.", opportunityCount))
    end
    self.shoppingStatus:SetText(table.concat(notes, "  "))
  end
  self.listButton:SetText(self.plan and self.plan.priceDiscovery and "Create scan list" or "Create list")
  self.searchButton:SetText(self.plan and self.plan.priceDiscovery and "Scan prices at Auction House" or "Search at Auction House")
  self.listButton:SetEnabled(self.plan ~= nil and #auctionRows > 0)
  self.searchButton:SetEnabled(self.plan ~= nil and #auctionRows > 0)
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
  if self.mode == "browser" then
    self:UpdateBrowser()
  else
    self:UpdatePlanRows()
    self:UpdateShoppingRows()
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
