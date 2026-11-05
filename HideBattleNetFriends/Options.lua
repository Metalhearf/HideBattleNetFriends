local addonName, ns = ...
local L = ns.L

local TITLE = "HideBattleNetFriends"
BINDING_HEADER_HIDEBATTLENETFRIENDS = TITLE
BINDING_NAME_HIDEBATTLENETFRIENDS_PAUSE = L.pauseBinding
local groups = {
	{ "groupFriends", { "hideFriends", "hideRequests", "anonymize", "hideNotes", "hideBroadcasts", "hideWowOffline" } },
	{ "groupFilter", { "hideOffline", "hideAppOnly", "hideOtherGames" } },
	{ "groupPrivacy", { "hideBattleTag", "shiftReveal" } },
	{ "groupNotifications", { "muteToasts", "hideQuickJoinToasts" } },
	{ "groupTabs", { "hideQuickJoinTab", "hideRecentAlliesTab", "hideRecruitTab" } },
	{ "groupDisplay", { "hideMinimapButton" } },
}
local keys = {}
for _, group in ipairs(groups) do
	for _, key in ipairs(group[2]) do
		tinsert(keys, key)
	end
end
-- each profile lists the options it turns on; every other option except the minimap button is turned off
local profiles = {
	{ "profileClassic", { hideFriends = true, hideRequests = true, anonymize = true, hideNotes = true, hideBroadcasts = true, hideBattleTag = true, shiftReveal = true,
		muteToasts = true, hideQuickJoinToasts = true, hideQuickJoinTab = true, hideRecentAlliesTab = true, hideRecruitTab = true } },
	{ "profileNoBnet", { hideFriends = true, hideRequests = true, anonymize = true, hideNotes = true, hideBroadcasts = true, hideBattleTag = true, shiftReveal = true,
		muteToasts = true, hideQuickJoinToasts = true } },
	{ "profileOnline", { hideOffline = true, hideWowOffline = true, shiftReveal = true } },
	{ "profileWow", { hideOffline = true, hideAppOnly = true, hideOtherGames = true, hideWowOffline = true, shiftReveal = true } },
	{ "profileBlizzard", {} },
}
-- Forever's Social UI list cannot be filtered by an addon (see Core.lua)
local function classicWindow()
	return ns.CanFilter()
end
-- options for Blizzard features that some clients (Classic) do not have
local available = {
	-- shortcut: the Social UI tabs (Forever) cannot be hidden without tainting that window, so these options are left out there
	hideQuickJoinTab = function() return ns.FriendsHost() == FriendsFrame and FRIEND_TAB_QUICK_JOIN and _G["FriendsFrameTab" .. FRIEND_TAB_QUICK_JOIN] end,
	hideRequests = function() return ns.FriendsHost() == FriendsFrame end,
	hideFriends = classicWindow,
	hideWowOffline = classicWindow,
	hideOffline = classicWindow,
	hideAppOnly = classicWindow,
	hideOtherGames = classicWindow,
	hideQuickJoinToasts = function() return QuickJoinToastButton and QuickJoinToastButton.Toast end,
	hideRecruitTab = function() return ns.FriendsHost() == FriendsFrame and FriendsTabHeader and FriendsTabHeader.recruitAFriendTabID end,
	hideRecentAlliesTab = function() return ns.FriendsHost() == FriendsFrame and FriendsTabHeader and FriendsTabHeader.recentAlliesTabID end,
}

local function pruneGroups()
	-- the Social UI's tabs cannot be hidden, which leaves No Battle.net identical to Classic experience there
	if ns.FriendsHost() ~= FriendsFrame and ns.CanFilter() then
		for i = #profiles, 1, -1 do
			if profiles[i][1] == "profileNoBnet" then
				tremove(profiles, i)
			end
		end
	end
	if not classicWindow() then
		for i = #profiles, 1, -1 do
			if profiles[i][1] ~= "profileNoBnet" and profiles[i][1] ~= "profileBlizzard" then
				tremove(profiles, i)
			end
		end
	end
	for i = #groups, 1, -1 do
		local list = groups[i][2]
		for j = #list, 1, -1 do
			local check = available[list[j]]
			if check and not check() then
				tremove(list, j)
			end
		end
		if #list == 0 then
			tremove(groups, i)
		end
	end
end

-- filters only matter while Battle.net friends are shown
local parents = { hideOffline = "hideFriends", hideAppOnly = "hideFriends", hideOtherGames = "hideFriends" }
local settings = {}
local category

local function set(key, value)
	if settings[key] then
		settings[key]:SetValue(value)
	else
		ns.Set(key, value)
	end
end

local function matchesProfile(values)
	for _, key in ipairs(keys) do
		if key ~= "hideMinimapButton" and (values[key] or false) ~= (ns.db[key] or false) then
			return false
		end
	end
	return true
end

local function applyProfile(values)
	for _, key in ipairs(keys) do
		if key ~= "hideMinimapButton" then
			set(key, values[key] or false)
		end
	end
end

local function setupPanel()
	if not (Settings and Settings.RegisterAddOnSetting) then return end
	category = Settings.RegisterVerticalLayoutCategory(TITLE)
	local layout = SettingsPanel:GetLayout(category)
	local createCheckbox = Settings.CreateCheckbox or Settings.CreateCheckBox
	local initializers = {}
	for _, group in ipairs(groups) do
		if CreateSettingsListSectionHeaderInitializer then
			layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(L[group[1]]))
		end
		for _, key in ipairs(group[2]) do
			local default = ns.defaults[key]
			local setting = Settings.RegisterAddOnSetting(category, "HBNF_" .. key, key, ns.db, type(default), L[key], default)
			setting:SetValueChangedCallback(function(_, value)
				ns.Set(key, value)
			end)
			local initializer = createCheckbox(category, setting, L[key .. "Desc"])
			local parent = parents[key]
			if parent and initializers[parent] and initializer.SetParentInitializer then
				-- greys the filters out while their parent option hides Battle.net friends
				initializer:SetParentInitializer(initializers[parent], function() return not ns.db[parent] end)
			end
			initializers[key] = initializer
			settings[key] = setting
		end
	end
	if CreateSettingsButtonInitializer then
		layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(L.groupProfiles))
		for _, profile in ipairs(profiles) do
			layout:AddInitializer(CreateSettingsButtonInitializer(L[profile[1] .. "Desc"], L[profile[1]], function() applyProfile(profile[2]) end, nil, false))
		end
	end
	Settings.RegisterAddOnCategory(category)
end

local function setupWindow()
	local window = CreateFrame("Frame", "HideBattleNetFriendsWindow", UIParent, "BasicFrameTemplateWithInset")
	window:SetFrameStrata("HIGH")
	window:Hide()
	tinsert(UISpecialFrames, window:GetName())
	local title = window:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	title:SetPoint("TOP", 0, -5)
	title:SetText(TITLE)

	local boxes, labels, profileButtons = {}, {}, {}
	local sync
	local y = -32
	local function addHeader(text)
		local header = window:CreateFontString(nil, "ARTWORK", "GameFontNormal")
		header:SetPoint("TOPLEFT", 16, y)
		header:SetText(text)
		local line = window:CreateTexture(nil, "ARTWORK")
		line:SetColorTexture(1, 0.82, 0, 0.25)
		line:SetHeight(1)
		line:SetPoint("TOPLEFT", 16, y - 15)
		line:SetPoint("TOPRIGHT", -16, y - 15)
		y = y - 20
	end

	addHeader(L.groupProfiles)
	for i, profile in ipairs(profiles) do
		local button = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
		profileButtons[button] = profile[2]
		button:SetSize(146, 22)
		button:SetPoint("TOPLEFT", 16 + (i - 1) % 2 * 152, y - math.floor((i - 1) / 2) * 24)
		button:SetText(L[profile[1]])
		button:SetScript("OnClick", function()
			applyProfile(profile[2])
			sync()
		end)
		button:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(L[profile[1]])
			GameTooltip:AddLine(L[profile[1] .. "Desc"], 1, 1, 1, true)
			GameTooltip:Show()
		end)
		button:SetScript("OnLeave", GameTooltip_Hide)
	end
	y = y - math.ceil(#profiles / 2) * 24 - 8

	for _, group in ipairs(groups) do
		addHeader(L[group[1]])
		for _, key in ipairs(group[2]) do
			local box = CreateFrame("CheckButton", nil, window, "UICheckButtonTemplate")
			box:SetSize(24, 24)
			box:SetPoint("TOPLEFT", 18, y)
			local label = box:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
			label:SetPoint("LEFT", box, "RIGHT", 4, 0)
			label:SetWidth(265)
			label:SetJustifyH("LEFT")
			label:SetWordWrap(false)
			label:SetText(L[key])
			box:SetScript("OnClick", function(self)
				set(key, self:GetChecked() and true or false)
				sync()
			end)
			box:SetScript("OnEnter", function(self)
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:SetText(L[key])
				GameTooltip:AddLine(L[key .. "Desc"], 1, 1, 1, true)
				GameTooltip:Show()
			end)
			box:SetScript("OnLeave", GameTooltip_Hide)
			boxes[key] = box
			labels[key] = label
			y = y - 24
		end
		y = y - 8
	end
	if not classicWindow() then
		local filterHint = window:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
		filterHint:SetPoint("TOP", 0, y - 2)
		filterHint:SetText(L.filterHint)
		y = y - 14
	end
	local hint = window:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	hint:SetPoint("TOP", 0, y - 2)
	hint:SetText(L.helpHint)
	local getMetadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
	local signature = window:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	signature:SetPoint("BOTTOMRIGHT", -10, 7)
	signature:SetText(getMetadata(addonName, "Author") .. " · v" .. getMetadata(addonName, "Version"))
	window:SetSize(330, -y + 32)

	function sync()
		for key, box in pairs(boxes) do
			box:SetChecked(ns.db[key])
			local off = parents[key] and ns.db[parents[key]]
			box:SetEnabled(not off)
			labels[key]:SetFontObject(off and GameFontDisable or GameFontHighlight)
		end
		for button, values in pairs(profileButtons) do
			if matchesProfile(values) then
				button:LockHighlight()
			else
				button:UnlockHighlight()
			end
		end
	end

	window:SetScript("OnShow", function(self)
		sync()
		local host = ns.FriendsHost()
		if not host:IsShown() and not InCombatLockdown() then
			ShowUIPanel(host)
		end
		self:ClearAllPoints()
		if host:IsShown() then
			self:SetPoint("TOPLEFT", host, "TOPRIGHT", 2, 0)
		else
			self:SetPoint("CENTER")
		end
	end)
	return window
end

local function toggle()
	local window = HideBattleNetFriendsWindow
	window:SetShown(not window:IsShown())
end
HideBattleNetFriends_Toggle = toggle

function HideBattleNetFriends_TogglePause()
	ns.SetPaused(not ns.IsPaused())
end

local function setupMinimapButton()
	local button = CreateFrame("Button", "HideBattleNetFriendsMinimapButton", Minimap)
	button:SetSize(31, 31)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:RegisterForDrag("LeftButton")
	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	local icon = button:CreateTexture(nil, "BACKGROUND")
	icon:SetSize(20, 20)
	icon:SetPoint("TOPLEFT", 7, -5)
	icon:SetTexture("Interface\\AddOns\\" .. addonName .. "\\Logo\\HideBattleNetFriends32")
	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetSize(53, 53)
	border:SetPoint("TOPLEFT")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

	local function place()
		local angle = math.rad(ns.db.minimapAngle or 225)
		local radius = Minimap:GetWidth() / 2 + 5
		button:ClearAllPoints()
		button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
	end
	place()

	button:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local scale = Minimap:GetEffectiveScale()
			local cx, cy = GetCursorPosition()
			ns.db.minimapAngle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
			place()
		end)
	end)
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)
	button:SetScript("OnClick", toggle)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText(TITLE)
		GameTooltip:AddLine(L.buttonHint, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", GameTooltip_Hide)
	button:SetShown(not ns.db.hideMinimapButton)

	function ns.OnSet(key, value)
		if key == "hideMinimapButton" then
			button:SetShown(not value)
			if value then
				print("|cff00ccffHideBattleNetFriends|r: " .. L.slashHint)
			end
		end
	end
end

local function setupFriendsButton()
	local host = ns.FriendsHost()
	local close = host.CloseButton or FriendsFrameCloseButton
	if not close then return end
	-- the title bar next to the close button is the same on every client and no tab or language can grow into it
	local button = CreateFrame("Button", "HideBattleNetFriendsFriendsButton", host)
	button:SetSize(18, 18)
	button:SetFrameLevel(close:GetFrameLevel())
	button:SetPoint("RIGHT", close, "LEFT", -2, 0)
	button:SetNormalTexture("Interface\\AddOns\\" .. addonName .. "\\Logo\\HideBattleNetFriends32")
	button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	button:SetScript("OnClick", toggle)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(TITLE)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", GameTooltip_Hide)
end

function ns.SetupOptions()
	pruneGroups()
	setupPanel()
	setupWindow()
	setupMinimapButton()
	setupFriendsButton()
	SLASH_HIDEBATTLENETFRIENDS1 = "/hbnf"
	SlashCmdList.HIDEBATTLENETFRIENDS = function(msg)
		msg = msg and msg:lower():match("%a+")
		if msg == "on" or msg == "off" then
			ns.SetPaused(msg == "off")
		elseif msg then
			print("|cff00ccff" .. TITLE .. "|r")
			for _, line in ipairs({ { "", L.helpToggle }, { " off", L.helpOff }, { " on", L.helpOn }, { " help", L.helpHelp } }) do
				print("  |cffffd100/hbnf" .. line[1] .. "|r - " .. line[2])
			end
			print(L.helpWhere)
		else
			toggle()
		end
	end
end
