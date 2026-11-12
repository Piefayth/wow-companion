-- What this file needs from Agent.lua comes
-- through its named functions (WC.Companion.<verb>); what Agent.lua calls here is WC.Window.

local effectiveModules = WC.Companion.modules
local function newTranscript(...) return WC.Transcript.newTranscript(...) end

-- Tabs on the top edge, standing on the chat well (PanelTopTabButtonTemplate,
-- PanelTemplates_SetTab, as the macro frame's). Top, not side: the
-- conversation list is already a column of choices on the right, and side
-- tabs beside it read as tabs on tabs. Picked with
-- the controller cursor. No shoulder buttons: L1 and R1 are talk-button slots.
-- The tabs: the Agent's own three, then one per loaded addon that adds its
-- page (WC.Companion.AddTab), so a disabled addon has no tab.
local TAB_NAMES = { "Chat", "Settings", "Status" }
local added = {} -- { name, fill } from other addons, in the order they came
local addTab -- set once the window is built
-- name: the tab's label; fill(page): called once with the page's frame
function WC.Companion.AddTab(name, fill)
	if addTab then return addTab(name, fill) end
	added[#added + 1] = { name = name, fill = fill }
end
local function buildTabs(frame, messages)
	local pages = {}
	-- every page but Chat stands in a page well of its own, an inset over
	-- both wells' area (anchored below, once the wells exist)
	local function page()
		local p = CreateFrame("Frame", nil, frame)
		p:Hide()
		return p
	end
	pages[2], pages[3] = page(), page()

	-- Settings: Core's page (SettingsPage.lua), shown in this tab; the
	-- window's own rows are added here
	pages[2]:SetScript("OnShow", function(self) WC.SettingsPage.ShowIn(self) end)
	WC.SettingsPage.Add({ kind = "dropdown", order = 10, label = "Window size",
		text = "The size the Companion window opens at. Its corner grip changes it just for now.",
		options = function() return frame.SIZE_NAMES or { "Small", "Medium", "Large" } end,
		get = function() return (frame.SIZE_NAMES or {})[WowCompanionAgentDB.windowSize or 2] end,
		set = function(name)
			for i, n in ipairs(frame.SIZE_NAMES or {}) do
				if n == name and frame.SetDefaultSize then frame.SetDefaultSize(i) end
			end
		end })
	WC.SettingsPage.Add({ kind = "slider", order = 40, label = "Window scale",
		text = "The Companion window and everything in it, apart from the rest of the interface.",
		min = 80, max = 200, steps = 12,
		get = function() return math.floor((WowCompanionAgentDB.windowScale or 1) * 100 + 0.5) end,
		set = function(value) frame.SetWindowScale(math.floor(value + 0.5) / 100) end,
		format = function(value) return ("%d%%"):format(math.floor(value + 0.5)) end })
	WC.SettingsPage.Add({ kind = "button", order = 90, label = "Clear transcript", button = "Clear",
		text = "Empty the Companion window. The conversation itself carries on.",
		onClick = function()
			WowCompanionAgentDB.log = {}
			messages:Clear()
		end })

	-- Status: what is running, read fresh while the tab is looked at. In the
	-- chat's look: one row per fact on the replies' stone (one sheet for the page), the label in gold,
	-- the value beside it, a quest log divider between rows, a light, colour-
	-- blind-safe word for good or bad (green ok, red problem) and grey detail.
	local ROW = 30
	local rows = {}
	-- One stone over the whole page well (the inset the page sits in, edge to
	-- edge inside its border), so only one texture shows, divided by the row
	-- dividers; the well's own backing no longer peeks out around a smaller
	-- card (the player, 2026-11-11). Anchored once the page has its parent.
	local stone = pages[3]:CreateTexture(nil, "BACKGROUND")
	stone:SetTexture(WC.Transcript.STONE.claude, "REPEAT", "REPEAT")
	stone:SetHorizTile(true)
	stone:SetVertTile(true)
	pages[3].stone = stone
	local function row(i)
		local r = rows[i]
		if r then return r end
		r = CreateFrame("Frame", nil, pages[3])
		r:SetHeight(ROW)
		if i > 1 then
			-- edge to edge of the stone (the page sits 9 px inside it)
			local divider = r:CreateTexture(nil, "ARTWORK")
			divider:SetAtlas("QuestLog-frame-devider")
			divider:SetAlpha(0.8)
			divider:SetHeight(15)
			divider:SetPoint("LEFT", r, "TOPLEFT", -9, 0)
			divider:SetPoint("RIGHT", r, "TOPRIGHT", 9, 0)
		end
		r.label = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		r.label:SetPoint("LEFT", 12, 0)
		r.label:SetWidth(170)
		r.label:SetJustifyH("LEFT")
		r.value = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		r.value:SetPoint("LEFT", r.label, "RIGHT", 8, 0)
		r.value:SetPoint("RIGHT", -12, 0)
		r.value:SetJustifyH("LEFT")
		r.value:SetWordWrap(false)
		rows[i] = r
		return r
	end
	local function refreshStatus()
		local grey, good, bad = "|cff9d9d9d", "|cff40ff40", "|cffff6060"
		local n = 0
		local function add(label, value)
			n = n + 1
			local r = row(n)
			r.label:SetText(label)
			r.value:SetText(value)
			r:Show()
		end
		local up = WowCompanion_IsUp and WowCompanion_IsUp()
		add("Companion app", up and good .. "connected|r"
			or bad .. "not heard from|r " .. grey .. "(is it running on the PC?)|r")
		local sent = WC.Link and WC.Link.MessagesSent and WC.Link.MessagesSent() or 0
		local slots = WowCompanionLinkDB and WowCompanionLinkDB.slotCount or 0
		add("Messages", ("%d of %d %s(a reload resets it)|r"):format(sent, slots, grey))
		local pins = WCPins and #WCPins.List() or 0
		add("Map pins", pins == 0 and grey .. "none|r" or tostring(pins))
		local wheels = {}
		if WCWheel then
			WCWheel.Each(function(key, wheel)
				wheels[#wheels + 1] = (wheel.label or key) .. " " .. grey .. "(" .. #(wheel.slots or {}) .. ")|r"
			end)
		end
		table.sort(wheels)
		add("Wheels", #wheels > 0 and table.concat(wheels, ", ") or grey .. "none|r")
		local modules = {}
		for name in pairs(effectiveModules()) do modules[#modules + 1] = name end
		table.sort(modules)
		add("My modules", #modules > 0 and table.concat(modules, ", ") or grey .. "none|r")
		local blocked = WowCompanionAgentDB.blocked or {}
		local b = blocked[#blocked]
		add("Blocked actions", b and bad .. ("%d kinds|r %slast %s: %s x%d|r"):format(#blocked, grey,
			date("%H:%M", b.at or 0), b.what, b.count or 1) or good .. "none|r")
		local plist = {}
		for _, p in ipairs(WC.ProviderProblems and WC.ProviderProblems() or {}) do
			plist[#plist + 1] = ("%s/%s: %s"):format(p.cap, p.provider, p.why)
		end
		add("Addon links", #plist == 0 and good .. "all working|r" or bad .. table.concat(plist, "; ") .. "|r")
		local fp, flast = 0, nil
		if WC.FocusLog then fp, flast = WC.FocusLog.Problems() end
		add("Focus", fp == 0 and good .. "ok|r" or bad .. ("%d problem%s|r %slast %s|r"):format(fp,
			fp == 1 and "" or "s", grey, tostring(flast)))
		-- the export's sections that failed when it was last written (Export.lua)
		local failed = WowCompanionAgentDB.exportFailures
		add("Export", failed and bad .. ("%d part%s failed|r %s%s|r"):format(#failed,
			#failed == 1 and "" or "s", grey, failed[1]) or good .. "whole|r")
		add("Combat", InCombatLockdown() and bad .. "yes|r " .. grey .. "(changes wait until it ends)|r" or "no")
		for i = n + 1, #rows do rows[i]:Hide() end
		-- the rows share the page's height, so the card is filled to its foot
		local h = math.max(ROW, math.floor((pages[3]:GetHeight() or 0) / n))
		for i = 1, n do
			rows[i]:ClearAllPoints()
			rows[i]:SetPoint("TOPLEFT", 0, -(i - 1) * h)
			rows[i]:SetPoint("TOPRIGHT", 0, -(i - 1) * h)
			rows[i]:SetHeight(h)
		end
	end
	local since = 0
	pages[3]:SetScript("OnShow", function() since = 0 refreshStatus() end)
	pages[3]:SetScript("OnUpdate", function(_, dt)
		since = since + dt
		if since > 1 then since = 0 refreshStatus() end
	end)

	-- The conversation picker: a well on the right, the auction house's category
	-- list art (auctionhouse-nav-button, -select, -highlight, the categories
	-- background, an inset border). Chat tab only.
	local WELL = 130
	local made, well = pcall(CreateFrame, "Frame", nil, frame, "InsetFrameTemplate")
	if not made or not well then well = CreateFrame("Frame", nil, frame) end
	-- inside the panel where its own inset would be (ButtonFrameTemplate's
	-- Inset: 4, -60 to -6, 26), the tabs standing on top
	well:SetPoint("TOPRIGHT", -6, -60)
	well:SetPoint("BOTTOMRIGHT", -6, 26)
	well:SetWidth(WELL)
	local back = well:CreateTexture(nil, "BACKGROUND", nil, 1)
	back:SetAtlas("auctionhouse-background-categories")
	back:SetPoint("TOPLEFT", 3, -3)
	back:SetPoint("BOTTOMRIGHT", -3, 3)
	frame.chatParts = frame.chatParts or {}
	table.insert(frame.chatParts, well)
	-- The transcript sits in a well of its own, an inset like the conversation
	-- list's, with its scroll arrows inside it; the raised frame around them
	-- keeps only the waiting line.
	local madeChat, chatWell = pcall(CreateFrame, "Frame", nil, frame, "InsetFrameTemplate")
	if not madeChat or not chatWell then chatWell = CreateFrame("Frame", nil, frame) end
	chatWell:SetPoint("TOPLEFT", 4, -60)
	chatWell:SetPoint("BOTTOMRIGHT", -(6 + WELL + 2), 26)
	table.insert(frame.chatParts, chatWell)
	-- The chat well's geometry, in one place (docs/ui-layout.md): inside the
	-- inset's border (EDGE) there are two rects and nothing else, the
	-- transcript on the left and the scroll column (BAR wide) on the right.
	-- Everything in the well anchors to one of the two, never to a number of
	-- its own, so backings, shadows and the bar cannot drift apart.
	-- BAR is the classic trough's own width (its end cap atlas, 31)
	local EDGE, BAR = 3, 31
	local level = chatWell:GetFrameLevel()
	-- The column is Blizzard's classic scroll trough, as WowClassicScrollBar
	-- draws it (TrimScrollBar.xml; the classic auction house's bar): metal
	-- rails with an end cap at each end. Its centre atlas is not in this
	-- client, so the centre is the top cap's rails-only rows (9..14 of its
	-- 64-row file), stretched along the rails, which run straight down.
	-- Between the rails, the player's darker stone: a gutter apart from the
	-- replies' stone beside it.
	local column = _G["WCChatScrollColumn"] or CreateFrame("Frame", "WCChatScrollColumn", chatWell)
	column:SetPoint("TOPRIGHT", -EDGE, -EDGE)
	column:SetPoint("BOTTOMRIGHT", -EDGE, EDGE)
	column:SetWidth(BAR)
	column:SetFrameLevel(level + 1)
	table.insert(frame.chatParts, column)
	local gutter = column:CreateTexture(nil, "BACKGROUND")
	gutter:SetTexture(WC.Transcript.STONE.you, "REPEAT", "REPEAT")
	gutter:SetHorizTile(true)
	gutter:SetVertTile(true)
	gutter:SetPoint("TOPLEFT", 5, 0)
	gutter:SetPoint("BOTTOMRIGHT", -5, 0)
	local capTop = column:CreateTexture(nil, "BORDER")
	capTop:SetAtlas("UI-ClassicScrollBar-EndCap-Top", true)
	capTop:SetPoint("TOPLEFT")
	local capBottom = column:CreateTexture(nil, "BORDER")
	capBottom:SetAtlas("UI-ClassicScrollBar-EndCap-Bottom", true)
	capBottom:SetPoint("BOTTOMLEFT")
	local cap = C_Texture.GetAtlasInfo("UI-ClassicScrollBar-EndCap-Top")
	if cap then
		local rails = column:CreateTexture(nil, "BORDER")
		rails:SetTexture(cap.file)
		rails:SetTexCoord(cap.leftTexCoord, cap.rightTexCoord, 9 / 64, 14 / 64)
		rails:SetPoint("TOPLEFT", capTop, "BOTTOMLEFT")
		rails:SetPoint("BOTTOMRIGHT", capBottom, "TOPRIGHT")
	end
	messages.scroll:ClearAllPoints()
	messages.scroll:SetPoint("TOPLEFT", chatWell, "TOPLEFT", EDGE, -EDGE)
	messages.scroll:SetPoint("BOTTOMRIGHT", column, "BOTTOMLEFT", 2, 0)
	messages.scroll:SetFrameLevel(level + 2)
	if frame.chatParts[1] and frame.chatParts[2] then
		frame.chatParts[1]:ClearAllPoints()
		-- inside the caps, where WowClassicScrollBar puts its steppers
		frame.chatParts[1]:SetPoint("TOP", column, "TOP", 0, -4)
		frame.chatParts[1]:SetFrameLevel(level + 3)
		frame.chatParts[2]:ClearAllPoints()
		frame.chatParts[2]:SetPoint("BOTTOM", column, "BOTTOM", 0, 4)
		frame.chatParts[2]:SetFrameLevel(level + 3)
	end
	if frame.scrollTrack then frame.scrollTrack:SetFrameLevel(level + 3) end
	frame.convButtons = {}
	for i, key in ipairs(WC.Conversations.list) do
		local b = CreateFrame("Button", nil, well)
		-- Blizzard's own geometry (AuctionCategoryButtonTemplate): a 21-tall
		-- button, its art 32 tall from the top-left (-2, 0), since the atlas has
		-- empty space at the bottom; the select glow on the art's exact bounds.
		-- Stretched to the button, the art sat high and the text low.
		b:SetSize(WELL - 10, 21)
		b:SetPoint("TOP", well, "TOP", 0, -8 - (i - 1) * 24)
		local function art(layer, atlas)
			local t = b:CreateTexture(nil, layer)
			t:SetAtlas(atlas)
			t:SetPoint("TOPLEFT", -2, 0)
			t:SetSize(WELL - 10 + 4, 32)
			return t
		end
		art("BACKGROUND", "auctionhouse-nav-button")
		-- the glow and highlight have no empty band: they cover the art's
		-- visible part, which is the button itself (measured from a screenshot)
		local function glowOn(t)
			t:ClearAllPoints()
			t:SetPoint("TOPLEFT", -2, 0)
			t:SetPoint("BOTTOMRIGHT", 2, 0)
			return t
		end
		local selected = glowOn(art("ARTWORK", "auctionhouse-nav-button-select"))
		selected:SetBlendMode("ADD")
		selected:Hide()
		b.selected = selected
		local glow = glowOn(art("HIGHLIGHT", "auctionhouse-nav-button-highlight"))
		glow:SetBlendMode("ADD")
		local text = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		text:SetPoint("LEFT", 12, 0)
		text:SetPoint("RIGHT", -8, 0)
		text:SetJustifyH("LEFT")
		b:SetFontString(text)
		-- news kept across a reload shows from the start
		local kept = type(WowCompanionAgentDB) == "table" and WowCompanionAgentDB.unread
		-- Main is the one in view after a reload, so its news is being read
		if kept and key == "" then kept[""] = nil end
		if kept and kept[key] then
			b:SetText("|cff40ff40" .. WC.Conversations.Label(key) .. "  new|r")
		else
			b:SetText(WC.Conversations.Label(key))
		end
		b:SetScript("OnClick", function() WowCompanion_SetConversation(key) end)
		WC.MarkFocusable(b)
		frame.convButtons[key] = b
	end
	frame.convButtons[""].selected:Show()

	-- each message's own panel (Jobs.lua) docks at the bottom of the chat well
	frame.chatWell = chatWell
	-- A shadow cast down from the chat well's top edge, under the tabs, so the
	-- well reads as sunk into the panel: Blizzard's
	-- own ShadowOverlay-Top (SharedUIPanelTemplates.xml:195), above the
	-- scrolling text so lines slide under it.
	local lip = CreateFrame("Frame", nil, chatWell)
	lip:SetPoint("TOPLEFT", messages.scroll, "TOPLEFT")
	lip:SetPoint("TOPRIGHT", messages.scroll, "TOPRIGHT")
	lip:SetHeight(24)
	lip:SetFrameLevel(chatWell:GetFrameLevel() + 3)
	local shade = lip:CreateTexture(nil, "OVERLAY")
	shade:SetTexture([[Interface\Common\ShadowOverlay-Top]])
	shade:SetAllPoints()
	table.insert(frame.chatParts, lip)

	-- the page well, over both wells' area, for the other tabs
	local madePage, pageWell = pcall(CreateFrame, "Frame", nil, frame, "InsetFrameTemplate")
	if not madePage or not pageWell then pageWell = CreateFrame("Frame", nil, frame) end
	pageWell:SetPoint("TOPLEFT", chatWell, "TOPLEFT")
	pageWell:SetPoint("BOTTOMRIGHT", well, "BOTTOMRIGHT")
	pageWell:Hide()
	local function place(p)
		p:SetParent(pageWell)
		p:SetPoint("TOPLEFT", 12, -10)
		p:SetPoint("BOTTOMRIGHT", -12, 10)
	end
	for _, p in pairs(pages) do place(p) end
	pages[3].stone:SetPoint("TOPLEFT", pageWell, "TOPLEFT", 3, -3)
	pages[3].stone:SetPoint("BOTTOMRIGHT", pageWell, "BOTTOMRIGHT", -3, 3)
	-- the same shadow under the tabs as the chat well has, on every other tab
	local pageLip = CreateFrame("Frame", nil, pageWell)
	pageLip:SetPoint("TOPLEFT", 3, -3)
	pageLip:SetPoint("TOPRIGHT", -3, -3)
	pageLip:SetHeight(24)
	pageLip:SetFrameLevel(pageWell:GetFrameLevel() + 20)
	local pageShade = pageLip:CreateTexture(nil, "OVERLAY")
	pageShade:SetTexture([[Interface\Common\ShadowOverlay-Top]])
	pageShade:SetAllPoints()

	-- the tabs, their foot resting on the chat well's top border (one pixel
	-- in, no more: deeper, they covered the top line of text), drawn under
	-- the well's top shadow so it falls across their foot as across the text
	local names = {}
	local function makeTab(name)
		local i = #names + 1
		local made, tab = pcall(CreateFrame, "Button", nil, frame, "PanelTopTabButtonTemplate")
		if not made or not tab then return end
		names[i] = name
		tab:SetID(i)
		tab:SetText(name)
		if i == 1 then
			tab:SetPoint("BOTTOMLEFT", chatWell, "TOPLEFT", 8, -1)
		else
			tab:SetPoint("LEFT", frame.Tabs[i - 1], "RIGHT", 0, 0)
		end
		tab:SetScript("OnClick", function(self) frame.SelectTab(self:GetID()) end)
		tab:SetFrameLevel(chatWell:GetFrameLevel() + 2)
		WC.MarkFocusable(tab)
		PanelTemplates_SetNumTabs(frame, i)
		return i
	end
	for _, name in ipairs(TAB_NAMES) do makeTab(name) end
	addTab = function(name, fill)
		local i = makeTab(name)
		if not i then return end
		pages[i] = page()
		place(pages[i])
		local ok, err = pcall(fill, pages[i])
		if not ok then pages[i].failed = tostring(err) end
		-- tabs are laid out again for the new width
		if frame.currentTab then PanelTemplates_SetTab(frame, frame.currentTab) end
	end
	for _, t in ipairs(added) do addTab(t.name, t.fill) end
	added = {}

	function frame.SelectTab(id)
		id = ((id - 1) % #names) + 1
		frame.currentTab = id
		PanelTemplates_SetTab(frame, id)
		local chat = id == 1
		-- the page's name in the title, as Collections does
		if frame.SetTitle then frame:SetTitle(chat and "Companion" or names[id]) end
		messages.scroll:SetShown(chat)
		for _, part in ipairs(frame.chatParts or {}) do part:SetShown(chat) end
		pageWell:SetShown(not chat)
		for i, p in pairs(pages) do p:SetShown(i == id) end
	end
	frame.SelectTab(1)
	-- Tabs are picked with the controller cursor; L1 and R1 are talk-button
	-- slots, so the window binds nothing.
end

-- The conversation window. Chat lines scroll away and cannot be scrolled back
-- through, so replies live in their own frame and in SavedVariables, which is what
-- makes history survive a /reload.
--
-- Deliberately not registered in UISpecialFrames: Escape handling is where the
-- gamepad taint lives, and this frame has a close button instead.
local function buildLog()
	-- One panel, Blizzard's own: ButtonFrameTemplate, as the macro frame is
	-- built (its border, background, title bar and close button), with the
	-- tabs standing on the wells inside it (docs/proposals/companion-window-frame.md).
	-- CreateFrame throws on a template this build lacks, and an ugly window
	-- beats an addon that fails to load.
	local made, frame = pcall(CreateFrame, "Frame", "WowCompanionLog", UIParent, "ButtonFrameTemplate")
	if not made or not frame then frame = CreateFrame("Frame", "WowCompanionLog", UIParent) end
	frame:SetSize(560, 340)
	-- top left, where Blizzard docks its own left panels (the character sheet,
	-- the spellbook); the panel manager places it there on every open
	frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 16, -116)
	frame:SetFrameStrata("DIALOG")
	frame:SetClampedToScreen(true)
	frame:Hide()
	if ButtonFrameTemplate_HidePortrait and frame.PortraitContainer then ButtonFrameTemplate_HidePortrait(frame) end
	-- our wells take the template's inset's place
	if frame.Inset then frame.Inset:Hide() end
	if frame.SetTitle then frame:SetTitle("Companion") end
	-- the controller's back button (circle) closes a focused window by
	-- clicking its frame.CloseButton (SmartNavigation:AttemptClose)
	if frame.CloseButton then
		frame.CloseButton:SetScript("OnClick", function()
			if WowCompanion_HideWindow then WowCompanion_HideWindow() else frame:Hide() end
		end)
	end
	-- the title bar is the drag handle, so a drag inside the transcript stays free
	frame:SetMovable(true)
	local bar = frame.TitleContainer
	if bar then
		bar:EnableMouse(true)
		bar:RegisterForDrag("LeftButton")
		bar:SetScript("OnDragStart", function() frame:StartMoving() end)
		bar:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)
	end

	local messages = newTranscript(frame)
	messages.scroll:SetPoint("TOPLEFT", 20, -42)
	messages.scroll:SetPoint("BOTTOMRIGHT", -40, 34)
	-- Scrolling on a controller without taking the right stick (the camera):
	-- Blizzard's own scroll arrows on the right edge, which the cursor reaches
	-- like any button and A presses. Each press moves most of a page.
	local function scrollBy(pages)
		local sc = messages.scroll
		local step = math.max(40, (sc:GetHeight() or 200) * 0.75)
		local range = sc:GetVerticalScrollRange()
		sc:SetVerticalScroll(math.max(0, math.min(range, sc:GetVerticalScroll() + pages * step)))
	end
	local arrows = {}
	for _, spec in ipairs({ { "UIPanelScrollUpButtonTemplate", -1, "TOPRIGHT", -16, -44 },
		{ "UIPanelScrollDownButtonTemplate", 1, "BOTTOMRIGHT", -16, 36 } }) do
		local made, arrow = pcall(CreateFrame, "Button", nil, frame, spec[1])
		if made and arrow then
			frame.chatParts = frame.chatParts or {}
			table.insert(frame.chatParts, arrow)
			arrow:SetPoint(spec[3], frame, spec[3], spec[4], spec[5])
			arrow:SetScript("OnClick", function() scrollBy(spec[2]) end)
			arrows[#arrows + 1] = arrow
		end
	end
	-- The scroll bar between the arrows: a thumb sized to
	-- the share of the transcript in view and placed at the scroll position, in
	-- Blizzard's own scroll bar art. Shown only, never dragged: the arrows scroll.
	if #arrows == 2 then
		local track = CreateFrame("Frame", nil, frame)
		frame.scrollTrack = track
		track:SetPoint("TOP", arrows[1], "BOTTOM", 0, -2)
		track:SetPoint("BOTTOM", arrows[2], "TOP", 0, 2)
		track:SetWidth(arrows[1]:GetWidth() > 0 and arrows[1]:GetWidth() or 16)
		-- Nothing is stretched. The thumb is drawn as
		-- Blizzard's WowTrimScrollBar thumb is (TrimScrollBar.xml and .lua): the
		-- round end caps at their own size, and the centre *tiled*: its texture
		-- coordinate runs past 1 by the height over the art's own height, so the
		-- art repeats instead of growing. Without those atlases a knob is
		-- shown at one fixed size, which only moves.
		local thumb = CreateFrame("Frame", nil, track)
		thumb:SetWidth(math.min(18, track:GetWidth()))
		local function piece(atlas, layer)
			local info = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas)
			if not info then return nil end
			local t = thumb:CreateTexture(nil, layer or "ARTWORK")
			t:SetAtlas(atlas, true)
			t.info = info
			return t
		end
		local top = piece("UI-ScrollBar-Knob-EndCap-Top", "OVERLAY")
		local bottom = top and piece("UI-ScrollBar-Knob-EndCap-Bottom", "OVERLAY")
		local middle = bottom and piece("UI-ScrollBar-Knob-Center")
		if middle and middle.info.height and middle.info.height > 0 then
			-- Blizzard's anchors: caps at the ends, the centre inset 5 under them
			top:SetPoint("TOPLEFT")
			bottom:SetPoint("BOTTOMLEFT")
			middle:SetPoint("TOPLEFT", 0, -5)
			middle:SetPoint("TOPRIGHT", 0, -5)
			thumb:SetWidth(math.max(top:GetWidth(), middle:GetWidth()))
			thumb.minSize = 23 -- Blizzard's minThumbExtent
			thumb.tile = function(height)
				local h = math.max(1, height - 10)
				middle:SetHeight(h)
				middle:SetTexCoord(0, 1, 0, h / middle.info.height)
			end
		else
			local knob = thumb:CreateTexture(nil, "ARTWORK")
			knob:SetAllPoints()
			knob:SetTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
			knob:SetTexCoord(0.20, 0.80, 0.125, 0.875)
			thumb.fixed = 24
		end
		table.insert(frame.chatParts, track)
		local function paintThumb()
			local sc = messages.scroll
			local range = sc:GetVerticalScrollRange() or 0
			local view = sc:GetHeight() or 0
			local room = track:GetHeight() or 0
			if range <= 1 or view <= 0 or room <= 0 then thumb:Hide() return end
			local size = thumb.fixed or math.max(thumb.minSize or 23, room * view / (view + range))
			local offset = (room - size) * math.min(1, (sc:GetVerticalScroll() or 0) / range)
			thumb:ClearAllPoints()
			thumb:SetPoint("TOP", track, "TOP", 0, -offset)
			thumb:SetHeight(size)
			if thumb.tile then thumb.tile(size) end
			thumb:Show()
		end
		messages.scroll:HookScript("OnVerticalScroll", paintThumb)
		messages.scroll:HookScript("OnScrollRangeChanged", paintThumb)
		messages.scroll:HookScript("OnSizeChanged", paintThumb)
		track:SetScript("OnShow", paintThumb)
		frame.paintThumb = paintThumb
	end
	frame.messages = messages

	-- 1.60.1 added a SmartNavigation API for exactly this: an addon can mark its own
	-- frames focusable by the gamepad cursor, so the window is reachable on a
	-- controller instead of needing a mouse.
	WC.MarkFocusable(frame)
	-- A real UI panel, so the controller's focus-cycle button reaches it like any
	-- of the game's own windows: that cycle walks the panels FrameControlsManager
	-- was told about, and ShowUIPanel is what tells it.
	--
	-- The catch, read in Blizzard_GamepadSharedUtility/FrameControlsManager.lua: a
	-- shown panel turns on the "fallthrough catcher" binding group, which takes the
	-- d-pad and face buttons away from the bars, and only FrameHidden turns it off.
	-- HideUIPanel sends that; a plain Hide (our close button, /wc log) does not, so
	-- the manager keeps a closed window in its list and the bars stay dead after
	-- it is gone. Blizzard's own
	-- non-panel windows (ColorPickerFrame, BuffFrame) call FrameHidden from OnHide,
	-- and it is wrapped by SecureHelper for exactly such callers, so we do the same:
	-- however the window goes away, the manager hears about it.
	if UIPanelWindows then
		UIPanelWindows["WowCompanionLog"] = {
			area = "left",
			pushable = 1, -- another left panel opening pushes it right, as Blizzard's do
			whileDead = 1,
			allowOtherPanels = 1,
		}
	end
	-- The transcript is text, no buttons: without this flag a right-stick
	-- scroll goes looking for a button inside it, finds none, and leaves the
	-- cursor drawn on the close button while nothing was selected
	-- (UpdateScrollSelection). Set once; a tick later, once buildTabs below has
	-- set frame.messages. (Not handed to SmartNavigation as a scroll frame: that
	-- gives it the right stick and takes the camera away.)
	C_Timer.After(0, function()
		if frame.messages then WC.MarkTextScroll(frame.messages.scroll) end
	end)
	frame:SetScript("OnHide", function(self)
		WC.FrameHidden(self)
	end)

	frame:SetResizable(true)
	if frame.SetResizeBounds then
		frame:SetResizeBounds(320, 180)
	end
	local grip = CreateFrame("Button", nil, frame)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", -4, 4)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	-- A mouse drags it; the controller can only click it, so a
	-- click that did not resize steps through three sizes. A drag
	-- also ends in a click, which is why the size at mouse-down is compared.
	local SIZES = { { 560, 340 }, { 760, 520 }, { 980, 700 } }
	local sizeBefore
	grip:SetScript("OnMouseDown", function()
		sizeBefore = frame:GetWidth() .. "x" .. frame:GetHeight()
		frame:StartSizing("BOTTOMRIGHT")
	end)
	grip:SetScript("OnMouseUp", function() frame:StopMovingOrSizing() end)
	grip:SetScript("OnClick", function()
		if sizeBefore and sizeBefore ~= frame:GetWidth() .. "x" .. frame:GetHeight() then
			sizeBefore = nil
			return
		end
		sizeBefore = nil
		frame.CycleSize()
	end)
	-- The corner grip steps the size for now; the Settings row sets the
	-- default the window opens at, kept in WowCompanionAgentDB.windowSize
	-- (medium unless the player picks otherwise).
	local function applySize(index)
		local pick = SIZES[index] or SIZES[2]
		-- grow from the top-left corner, so the window stays where it is
		local left, top = frame:GetLeft(), frame:GetTop()
		-- never taller than the screen below its top, with room for the tabs
		-- that hang under it (the large size runs off the bottom)
		local room = (top or (UIParent:GetHeight() - 116)) - 44
		frame:SetSize(pick[1], math.min(pick[2], math.max(240, room)))
		if left and top then
			frame:ClearAllPoints()
			frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
		end
	end
	function frame.CycleSize()
		local width = frame:GetWidth()
		local index = 1
		for i, size in ipairs(SIZES) do
			if size[1] > width + 10 then
				index = i
				break
			end
		end
		applySize(index)
	end
	frame.SIZE_NAMES = { "Small", "Medium", "Large" }
	-- The whole window, text and all, at its own scale (readable on a TV); the rest of the interface keeps its own.
	function frame.SetWindowScale(k)
		WowCompanionAgentDB.windowScale = k ~= 1 and k or nil
		frame:SetScale(k)
	end
	frame:SetScale(WowCompanionAgentDB.windowScale or 1)
	function frame.SetDefaultSize(index)
		WowCompanionAgentDB.windowSize = index
		applySize(index)
	end
	applySize(WowCompanionAgentDB.windowSize or 2)

	buildTabs(frame, messages)
	return frame
end


WC.Window = WC.Window or {}
WC.Window.buildLog = buildLog
