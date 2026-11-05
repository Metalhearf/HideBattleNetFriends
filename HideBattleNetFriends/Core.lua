local addonName, ns = ...
local L = ns.L

ns.defaults = {
	hideFriends = true,
	hideRequests = true,
	anonymize = true,
	hideBattleTag = true,
	shiftReveal = true,
	muteToasts = false,
	hideQuickJoinToasts = true,
	hideQuickJoinTab = false,
	hideNotes = true,
	hideRecruitTab = false,
	hideRecentAlliesTab = false,
	hideMinimapButton = false,
	hideOffline = false,
	hideAppOnly = false,
	hideOtherGames = false,
	hideWowOffline = false,
	hideBroadcasts = false,
}

local db
local revealed = false
local paused = false

-- paused turns every masking off for the session; revealed only lifts it while the friends list is open
local function enabled(key)
	return db and db[key] and not paused
end

local function active(key)
	return enabled(key) and not revealed
end

-- the Social UI (Forever) reads these while running protected code: replacing them gets the addon blocked there
local socialAtLoad = C_SocialUI and C_SocialUI.IsSystemEnabled and C_SocialUI.IsSystemEnabled()

local BNGetNumFriendsOrig = BNGetNumFriends
if not socialAtLoad then
	BNGetNumFriends = function(...)
		if active("hideFriends") then
			return 0, 0, 0, 0
		end
		return BNGetNumFriendsOrig(...)
	end
end

local BNGetNumFriendInvitesOrig = BNGetNumFriendInvites
if BNGetNumFriendInvitesOrig and not socialAtLoad then
	BNGetNumFriendInvites = function(...)
		if active("hideRequests") then
			return 0
		end
		return BNGetNumFriendInvitesOrig(...)
	end
end

local function shortTag(info)
	return info and info.battleTag and info.battleTag:match("^[^#]+") or L.anonymous
end

local function friendLabel(info)
	local label = shortTag(info)
	local character = info.gameAccountInfo and info.gameAccountInfo.characterName
	if character and character ~= "" then
		label = label .. " " .. (FRIENDS_WOW_NAME_COLOR_CODE or "") .. "(" .. character .. ")|r"
	end
	return label
end

-- clients that mean "online but not in a game": desktop app, mobile app, launcher
local idleClients = { App = true, BSAp = true, CLNT = true, [""] = true }

local function bnetFilteredOut(index)
	local info = C_BattleNet.GetFriendAccountInfo(index)
	if not info then
		return false
	end
	local game = info.gameAccountInfo
	if not (game and game.isOnline) then
		return active("hideOffline")
	end
	local client = game.clientProgram or ""
	if idleClients[client] then
		return active("hideAppOnly")
	end
	return client ~= BNET_CLIENT_WOW and active("hideOtherGames")
end

local function filteredOut(element)
	if element.buttonType == FRIENDS_BUTTON_TYPE_WOW then
		local info = C_FriendList.GetFriendInfoByIndex(element.id)
		return info and not info.connected and active("hideWowOffline")
	end
	return element.buttonType == FRIENDS_BUTTON_TYPE_BNET and bnetFilteredOut(element.id)
end

-- Forever (and later clients) replace FriendsFrame with the Social UI window
local function socialUI()
	return SocialUIControl and SocialUIControl.IsEnabled() and SocialUIFrame or nil
end

local socialOverlay

function ns.FriendsHost()
	return socialUI() or FriendsFrame
end

-- true when this client's friends list can be filtered (the Social UI only through the overlay)
function ns.CanFilter()
	return not socialUI() or socialOverlay ~= nil
end

local function filtering()
	return active("hideOffline") or active("hideAppOnly") or active("hideOtherGames") or active("hideWowOffline")
end

-- returns the entries left after filtering, without the dividers they orphan, or nil when nothing was filtered
local function keepEntries(entries)
	local kept, changed = {}, false
	for _, entry in ipairs(entries) do
		local last = kept[#kept]
		if filteredOut(entry) then
			changed = true
		elseif entry.buttonType ~= FRIENDS_BUTTON_TYPE_DIVIDER or (last and last.buttonType ~= FRIENDS_BUTTON_TYPE_DIVIDER) then
			tinsert(kept, entry)
		end
	end
	if not changed then return end
	if kept[#kept] and kept[#kept].buttonType == FRIENDS_BUTTON_TYPE_DIVIDER then
		kept[#kept] = nil
	end
	return kept
end

local function filterFriendsList()
	if not filtering() then return end
	local scrollBox = FriendsListFrame.ScrollBox
	local dataProvider = scrollBox:GetDataProvider()
	if not dataProvider then return end
	local entries = {}
	for _, element in dataProvider:Enumerate() do
		tinsert(entries, element)
	end
	local kept = keepEntries(entries)
	if kept then
		scrollBox:SetDataProvider(CreateDataProvider(kept), true)
	end
end

-- Classic keeps its rows in a private table; rebuild the same order so each shown row can point at Blizzard's entry index
local function classicEntries()
	local entries = {}
	local function add(buttonType, id)
		tinsert(entries, { buttonType = buttonType, id = id, index = #entries + 1 })
	end
	local bnetTotal, bnetOnline = BNGetNumFriends()
	local wowTotal, wowOnline = C_FriendList.GetNumFriends(), C_FriendList.GetNumOnlineFriends()
	local numInvites = BNGetNumFriendInvites()
	if numInvites > 0 then
		add(FRIENDS_BUTTON_TYPE_INVITE_HEADER)
		if not GetCVarBool("friendInvitesCollapsed") then
			for i = 1, numInvites do
				add(FRIENDS_BUTTON_TYPE_INVITE, i)
			end
			if bnetTotal + wowTotal > 0 then
				add(FRIENDS_BUTTON_TYPE_DIVIDER)
			end
		end
	end
	for i = 1, wowOnline do
		add(FRIENDS_BUTTON_TYPE_WOW, i)
	end
	for i = 1, bnetOnline do
		add(FRIENDS_BUTTON_TYPE_BNET, i)
	end
	if (bnetOnline > 0 or wowOnline > 0) and (bnetTotal > bnetOnline or wowTotal > wowOnline) then
		add(FRIENDS_BUTTON_TYPE_DIVIDER)
	end
	for i = wowOnline + 1, wowTotal do
		add(FRIENDS_BUTTON_TYPE_WOW, i)
	end
	for i = bnetOnline + 1, bnetTotal do
		add(FRIENDS_BUTTON_TYPE_BNET, i)
	end
	return entries
end

local function setupClassicFilter()
	local scrollFrame = FriendsFrameFriendsScrollFrame
	local updateList, topButton = FriendsList_Update, scrollFrame.dynamic
	local shown -- filtered rows, nil while the list is unfiltered

	-- Blizzard's FriendsFrame_UpdateFriends, with each row pointed at its entry through shown
	local function updateRows()
		local offset = HybridScrollFrame_GetOffset(scrollFrame)
		local count = shown and #shown or scrollFrame.numFriendListEntries
		local usedHeight = 0
		scrollFrame.dividerPool:ReleaseAll()
		scrollFrame.invitePool:ReleaseAll()
		scrollFrame.PendingInvitesHeaderButton:Hide()
		for i, button in ipairs(scrollFrame.buttons) do
			local index = offset + i
			if index <= count then
				button.index = shown and shown[index].index or index
				local height = FriendsFrame_UpdateFriendButton(button)
				button:SetHeight(height)
				usedHeight = usedHeight + height
			else
				button.index = nil
				button:Hide()
			end
		end
		HybridScrollFrame_Update(scrollFrame, scrollFrame.totalFriendListEntriesHeight, usedHeight)
	end

	FriendsFrame_UpdateFriends = updateRows
	scrollFrame.update = updateRows
	scrollFrame.dynamic = function(offset)
		if not shown then
			return topButton(offset)
		end
		local usedHeight = 0
		for i, entry in ipairs(shown) do
			local height = FRIENDS_BUTTON_HEIGHTS[entry.buttonType]
			if usedHeight + height >= offset then
				return i - 1, offset - usedHeight
			end
			usedHeight = usedHeight + height
		end
	end
	FriendsList_Update = function(forceUpdate, ...)
		shown = nil
		updateList(forceUpdate, ...)
		if not (filtering() and (forceUpdate or FriendsListFrame:IsShown())) then return end
		shown = keepEntries(classicEntries())
		if not shown then return end
		local height = 0
		for _, entry in ipairs(shown) do
			height = height + FRIENDS_BUTTON_HEIGHTS[entry.buttonType]
		end
		scrollFrame.numFriendListEntries = #shown
		scrollFrame.totalFriendListEntriesHeight = height
		updateRows()
	end
end

local toastCVars = { "showToastOnline", "showToastOffline", "showToastBroadcast", "showToastFriendRequest", "showToastWindow" }

local function applyToastCVars()
	db.savedCVars = db.savedCVars or {}
	for _, name in ipairs(toastCVars) do
		local current = C_CVar.GetCVar(name)
		if current ~= nil then
			if db.muteToasts then
				if db.savedCVars[name] == nil then
					db.savedCVars[name] = current
				end
				C_CVar.SetCVar(name, "0")
			elseif db.savedCVars[name] ~= nil then
				C_CVar.SetCVar(name, db.savedCVars[name])
				db.savedCVars[name] = nil
			end
		end
	end
end

function ns.Refresh()
	if FriendsFrameBattlenetFrame then
		FriendsFrameBattlenetFrame.Tag:SetAlpha(active("hideBattleTag") and 0 or 1)
	end
	if FRIEND_TAB_QUICK_JOIN then
		-- shortcut: unhiding ignores Blizzard's own rules for this tab until the next FriendsFrame show
		if active("hideQuickJoinTab") then
			PanelTemplates_HideTab(FriendsFrame, FRIEND_TAB_QUICK_JOIN)
		else
			PanelTemplates_ShowTab(FriendsFrame, FRIEND_TAB_QUICK_JOIN)
		end
	end
	if FriendsTabHeader and FriendsTabHeader.RefreshTabVisibility then
		FriendsTabHeader:RefreshTabVisibility()
	end
	if FriendsFrame:IsShown() and FriendsList_Update then
		FriendsList_Update(true)
	end
	local social = socialUI()
	local tag = social and social.BattleNetBar and social.BattleNetBar.ControlsContainer and social.BattleNetBar.ControlsContainer.PersonalBattleTagDisplay
	if tag then
		tag:SetAlpha(active("hideBattleTag") and 0 or 1)
	end
	if socialOverlay then
		socialOverlay()
	end
end

function ns.IsPaused()
	return paused
end

function ns.SetPaused(value)
	paused = value
	ns.Refresh()
	print("|cff00ccffHideBattleNetFriends|r: " .. (paused and L.paused or L.resumed))
end

function ns.Set(key, value)
	db[key] = value
	if key == "muteToasts" then
		applyToastCVars()
	end
	ns.Refresh()
	if ns.OnSet then
		ns.OnSet(key, value)
	end
end

-- chat args can be secret values in restricted contexts; callers fall back to Blizzard's text then
local function accountByID(id)
	local ok, info = pcall(C_BattleNet.GetAccountInfoByID, id)
	return ok and info or nil
end

local function idByName(name)
	local ok, id = pcall(BNet_GetBNetIDAccount, name)
	return ok and id or nil
end

-- swaps the real name (a |K escape that the client renders) for the BattleTag in any text
local function maskName(region, info)
	local text = region and region:GetText()
	if not (text and info and info.accountName) then return end
	local masked = text:gsub(info.accountName:gsub("%p", "%%%0"), (shortTag(info):gsub("%%", "%%%%")))
	if masked ~= text then
		region:SetText(masked)
	end
end

local namePopups = { CONFIRM_BLOCK_FRIEND = true, CONFIRM_REMOVE_BN_FRIEND = true, CONFIRM_BLOCK_INVITES = true, SET_BNFRIENDNOTE = true }

local function setupNameLeaks()
	if Menu and Menu.ModifyMenu then
		local function maskMenu(_, root, contextData)
			local info = active("anonymize") and contextData and accountByID(contextData.bnetIDAccount)
			if not info then return end
			for _, description in root:EnumerateElementDescriptions() do
				description:AddInitializer(function(button)
					maskName(button.fontString, info)
				end)
			end
		end
		Menu.ModifyMenu("MENU_UNIT_BN_FRIEND", maskMenu)
		Menu.ModifyMenu("MENU_UNIT_BN_FRIEND_OFFLINE", maskMenu)
	end

	if StaticPopup_Show and StaticPopup_FindVisible then
		hooksecurefunc("StaticPopup_Show", function(which, textArg, _, data)
			if not namePopups[which] or not active("anonymize") then return end
			local dialog = StaticPopup_FindVisible(which, data)
			local info = accountByID(data) or accountByID(idByName(textArg))
			if dialog then
				maskName(dialog.GetTextFontString and dialog:GetTextFontString() or dialog.text, info)
			end
		end)
	end

	if BNToastFrame and BNToastFrame.ShowToast then
		local function maskToast(toast)
			if not enabled("anonymize") then return end
			local info = accountByID(toast.toastData)
			maskName(toast.TopLine, info)
			maskName(toast.MiddleLine, info)
		end
		hooksecurefunc(BNToastFrame, "ShowToast", maskToast)
		BNToastFrame:HookScript("OnShow", maskToast)
	end

	if FCF_SetWindowName then
		hooksecurefunc("FCF_SetWindowName", function(chatFrame)
			local tab = _G[chatFrame:GetName() .. "Tab"]
			if not enabled("anonymize") or chatFrame.chatType ~= "BN_WHISPER" or not tab then return end
			maskName(tab, accountByID(idByName(chatFrame.chatTarget)))
			if PanelTemplates_TabResize then
				PanelTemplates_TabResize(tab, tab.sizePadding or 0)
			end
		end)
	end
end

local function maskWhisperHeader(editBox)
	if not enabled("anonymize") or editBox:GetChatType() ~= "BN_WHISPER" then return end
	local info = accountByID(idByName(editBox:GetTellTarget()))
	local header = editBox.header or _G[editBox:GetName() .. "Header"]
	if info and header then
		header:SetFormattedText(CHAT_BN_WHISPER_SEND, shortTag(info))
	end
end

local function setupChat()
	local addFilter = ChatFrame_AddMessageEventFilter or (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter)
	addFilter("CHAT_MSG_BN_INLINE_TOAST_ALERT", function(chatFrame, _, toastType, accountName, ...)
		if db.muteToasts then
			return true
		end
		if toastType == "BROADCAST" and enabled("hideBroadcasts") then
			return true
		end
		local format = _G["BN_INLINE_TOAST_" .. tostring(toastType)]
		local color = ChatTypeInfo and ChatTypeInfo.BN_INLINE_TOAST_ALERT
		if not enabled("anonymize") or (toastType ~= "FRIEND_ONLINE" and toastType ~= "FRIEND_OFFLINE") or not format or not color then
			return false
		end
		local lineID, bnetID = select(9, ...), select(11, ...)
		local info = accountByID(bnetID)
		if not info then
			return false
		end
		-- the link keeps the real account name as its target so clicking it still opens a whisper
		local link = GetBNPlayerLink(accountName, "[" .. friendLabel(info) .. "]", bnetID, lineID, "BN_INLINE_TOAST_ALERT", 0)
		chatFrame:AddMessage(format:format(link), color.r, color.g, color.b, color.id)
		return true
	end)

	if ChatFrameUtil and ChatFrameUtil.AddSenderNameFilter then
		ChatFrameUtil.AddSenderNameFilter(function(event, name, ...)
			if not enabled("anonymize") or (event ~= "CHAT_MSG_BN_WHISPER" and event ~= "CHAT_MSG_BN_WHISPER_INFORM") then
				return name
			end
			local info = accountByID((select(13, ...)))
			return info and shortTag(info) or name
		end)
	end

	for _, name in ipairs(CHAT_FRAMES or {}) do
		local editBox = _G[name].editBox
		if editBox and editBox.UpdateHeader then
			hooksecurefunc(editBox, "UpdateHeader", maskWhisperHeader)
		end
	end
end

-- Blizzard's Social UI list cannot be changed by an addon without the next opening being blocked (protected friend search),
-- so only text already on screen is touched there
local function setupSocialUI(frame)
	if FriendsListSocialCardMixin then
		-- cards copy the mixin when first created, which happens after login
		-- in-game (Title) friends show their character name, not a real name
		local function isTitle(info)
			return info and Enum.BattleNetFriendLevel and info.friendLevel == Enum.BattleNetFriendLevel.Title
		end
		hooksecurefunc(FriendsListSocialCardMixin, "RefreshFriendNameDisplayText", function(card)
			if active("anonymize") and not isTitle(card.elementData.accountInfo) then
				maskName(card.FriendName, card.elementData.accountInfo)
			end
		end)
		hooksecurefunc(FriendsListSocialCardMixin, "ShowTooltip", function(card)
			local tooltip = GetAppropriateTooltip and GetAppropriateTooltip() or GameTooltip
			local info = card.elementData.accountInfo
			local name = tooltip:GetName()
			if info and name then
				if active("anonymize") and not isTitle(info) then
					maskName(_G[name .. "TextLeft1"], info)
				end
				-- shortcut: the emptied note/broadcast lines keep their height, a small gap is left
				for i = 2, tooltip:NumLines() do
					local line = _G[name .. "TextLeft" .. i]
					local text = line and line:GetText()
					if text and ((active("hideNotes") and info.note ~= "" and text:find(info.note, 1, true))
						or (active("hideBroadcasts") and info.customMessage ~= "" and text:find(info.customMessage, 1, true))) then
						line:SetText("")
					end
				end
				tooltip:Show()
			end
			local window = HideBattleNetFriendsWindow
			if window and window:IsShown() then
				tooltip:ClearAllPoints()
				tooltip:SetPoint("TOPLEFT", window, "TOPRIGHT", 2, 0)
			end
		end)
	end

	frame:HookScript("OnShow", function()
		revealed = db.shiftReveal and IsShiftKeyDown() or false
		-- next frame, outside Blizzard's show code
		C_Timer.After(0, ns.Refresh)
	end)
	frame:HookScript("OnHide", function()
		revealed = false
	end)
end

local function isTitleFriend(info)
	return Enum.BattleNetFriendLevel and info.friendLevel == Enum.BattleNetFriendLevel.Title
end

-- Forever's in-game friends are Title friends of the Battle.net list; "Hide Battle.net friends" keeps them, like WoW friends elsewhere
local function keepSocialFriend(index, info)
	if isTitleFriend(info) then
		return info.gameAccountInfo.isOnline or not active("hideWowOffline")
	end
	return not active("hideFriends") and not bnetFilteredOut(index)
end

-- Blizzard's status filters (the Filter button); its friend search is protected, so they are applied here
local function matchesSearch(info, search)
	local game = info.gameAccountInfo
	if search.isOnline or search.isOffline or search.isAFK or search.isDND then
		local online = game.isOnline
		local afk = online and (info.isAFK or game.isGameAFK)
		local dnd = online and (info.isDND or game.isGameBusy)
		if not ((search.isOnline and online) or (search.isOffline and not online) or (search.isAFK and afk) or (search.isDND and dnd)) then
			return false
		end
	end
	local text = search.searchText and search.searchText:lower() or ""
	if text == "" then return true end
	for _, field in ipairs({ info.battleTag, game.characterName, game.areaName, info.note }) do
		if field and field:lower():find(text, 1, true) then
			return true
		end
	end
	return false
end

-- Blizzard's Social UI list cannot be filtered by an addon (its friend search is protected and any change to it gets the
-- next opening blocked), so an addon-owned copy built from the same template is laid over it, and Blizzard's list keeps
-- running untouched underneath, invisible; the rest of the window (tabs, status, search, filter) stays Blizzard's
local function listFiltering()
	return filtering() or active("hideFriends") or active("hideNotes") or active("hideBroadcasts")
end

local function setupSocialOverlay(frame)
	local blizzardList = frame.FriendsList
	local copy = CreateFrame("Frame", nil, blizzardList, "FriendsListSocialViewTemplate")
	copy:SetAllPoints(blizzardList)
	copy:SetFrameLevel(blizzardList:GetFrameLevel() + 20)
	-- the copy's own search bar, dividers and button sit exactly under Blizzard's, which stay in use
	for _, key in ipairs({ "FilterBar", "ActionButton", "TopDivider", "BottomDivider" }) do
		if copy[key] then copy[key]:SetAlpha(0) end
	end
	copy.FilterBar:Hide()
	copy.ActionButton:Hide()
	copy.GenerateDataProvider = function(self)
		local dataProvider = CreateTreeDataProvider()
		local search = blizzardList:BuildActiveSearchInfo()
		local kept = {}
		for index = 1, BNGetNumFriends() do
			local info = C_BattleNet.GetFriendAccountInfo(index)
			if info and keepSocialFriend(index, info) and matchesSearch(info, search) then
				tinsert(kept, index)
			end
		end
		self:InsertFriendsIntoDataProvider(dataProvider, kept)
		for _, node in dataProvider:EnumerateEntireRange() do
			local info = node:GetData().accountInfo
			if info then
				if active("hideNotes") then info.note = "" end
				if active("hideBroadcasts") then info.customMessage = "" end
			end
		end
		return dataProvider
	end
	local function refreshCopy()
		if copy:IsShown() then
			copy:Refresh(true)
		end
	end
	hooksecurefunc(blizzardList, "Refresh", refreshCopy)
	hooksecurefunc(blizzardList, "RefreshSearchResults", refreshCopy)

	socialOverlay = function()
		local covering = listFiltering()
		copy:SetShown(covering)
		-- alpha only: a C call that leaves Blizzard's Lua state untouched
		blizzardList.ScrollBox:SetAlpha(covering and 0 or 1)
		blizzardList.ScrollBar:SetAlpha(covering and 0 or 1)
		refreshCopy()
	end
	socialOverlay()
end

local function onLogin()
	HideBattleNetFriendsDB = HideBattleNetFriendsDB or {}
	db = HideBattleNetFriendsDB
	for key, value in pairs(ns.defaults) do
		if db[key] == nil then
			db[key] = value
		end
	end
	ns.db = db
	applyToastCVars()

	FriendsFrame:HookScript("OnShow", function()
		revealed = db.shiftReveal and IsShiftKeyDown() or false
		ns.Refresh()
	end)
	FriendsFrame:HookScript("OnHide", function()
		revealed = false
	end)

	if FriendsTabHeader and FriendsTabHeader.RefreshTabVisibility then
		hooksecurefunc(FriendsTabHeader, "RefreshTabVisibility", function(self)
			if active("hideRecruitTab") then
				self.TabSystem:SetTabShown(self.recruitAFriendTabID, false)
			end
			if active("hideRecentAlliesTab") and self.recentAlliesTabID then
				self.TabSystem:SetTabShown(self.recentAlliesTabID, false)
			end
			self:TryUpdateInvalidTabSelection()
		end)
	end

	if socialUI() then
		-- the old FriendsFrame still loads but is never shown
	elseif FriendsList_Update and FriendsListFrame and FriendsListFrame.ScrollBox then
		-- Blizzard rebuilds the whole list each update; drop filtered friends and the dividers they leave behind
		hooksecurefunc("FriendsList_Update", filterFriendsList)
	elseif FriendsList_Update and FriendsFrameFriendsScrollFrame then
		setupClassicFilter()
	end

	if FriendsFrame_UpdateFriendButton then
		hooksecurefunc("FriendsFrame_UpdateFriendButton", function(button)
			if button.buttonType ~= FRIENDS_BUTTON_TYPE_BNET or not active("anonymize") or not button.name then return end
			local info = C_BattleNet.GetFriendAccountInfo(button.id)
			if info then
				button.name:SetText(friendLabel(info))
			end
		end)
	end

	if FriendsListButtonMixin and FriendsTooltip then
		-- list buttons copy the mixin when first created, which happens after login
		hooksecurefunc(FriendsListButtonMixin, "OnEnter", function(button)
			if active("anonymize") and button.buttonType == FRIENDS_BUTTON_TYPE_BNET then
				FriendsTooltipHeader:SetText(shortTag(C_BattleNet.GetFriendAccountInfo(button.id)))
			end
			if active("hideNotes") and FriendsTooltipNoteText:IsShown() then
				FriendsTooltip:SetHeight(FriendsTooltip:GetHeight() - FriendsTooltipNoteText:GetHeight())
				FriendsTooltipNoteText:SetText("")
				FriendsTooltipNoteText:Hide()
				FriendsTooltipNoteIcon:Hide()
			end
			if active("hideBroadcasts") and FriendsTooltipBroadcastText:IsShown() then
				FriendsTooltip:SetHeight(FriendsTooltip:GetHeight() - FriendsTooltipBroadcastText:GetHeight())
				FriendsTooltipBroadcastText:SetText("")
				FriendsTooltipBroadcastText:Hide()
				FriendsTooltipBroadcastIcon:Hide()
			end
			local window = HideBattleNetFriendsWindow
			if window and window:IsShown() then
				-- Blizzard anchors the tooltip right of the list, where our window sits; dock it beside the window instead
				FriendsTooltip:ClearAllPoints()
				FriendsTooltip:SetPoint("TOPLEFT", window, "TOPRIGHT", 2, 0)
			end
		end)
	end

	if QuickJoinToastButton then
		for _, toast in ipairs({ QuickJoinToastButton.Toast, QuickJoinToastButton.Toast2 }) do
			toast:HookScript("OnShow", function(self)
				if enabled("hideQuickJoinToasts") then
					self:Hide()
				end
			end)
		end
	end

	if socialUI() then
		setupSocialUI(socialUI())
		if FriendsListSocialViewMixin and socialUI().FriendsList then
			setupSocialOverlay(socialUI())
		end
	end

	setupChat()
	setupNameLeaks()
	ns.SetupOptions()
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", onLogin)
