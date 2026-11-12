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
-- The window's layout, every margin decided here (the art carries none):
-- the rim stands on the frame's own bounds; every well is GAP inside the
-- rim's inner edge, and GAP apart; the wells' tops leave room for the title
-- band and the tab row, their feet for the legend's strip (FOOT, Jobs.lua).
-- tools/make_frame_art.py draws the window at these numbers to check them.
local RIM, TOP = 6, 28 -- the rim's width; the top pieces' height (title band and rule)
local BAND = 22.6 -- the title band's foot, where the art's rule begins
local GAP = 4
local WELL_TOP, FOOT = 64, 20
local INSET = 4 -- the wells' border, as wide as its art
local CLOSE, CLOSE_PAD = 14, 3 -- the close button, inside the title band, CLOSE_PAD from the rim
-- The controller's focus glow (FrameGlow, gamepad-uiframemetal-focus) is
-- placed by Blizzard for its own metal (FocusEffects.lua: -10, 14, 14, -14
-- from the frame), not ours. Its bright line's inner edge lies this far inside
-- its box, left, top, right, bottom: 28, 21.5, 26 and 22 of the atlas's
-- pixels, drawn at half scale (measured, 2026-11-12), so the box set out by
-- these puts the line on the rim's outer edge all round.
local GLOW = { 14, 10.75, 13, 11 }

-- Our own frame art (tools/make_frame_art.py) on an owner's NineSlice pieces,
-- on the owner's bounds: every piece rim wide, the top corners and edge top
-- tall, so a corner and the edge beside it share their pixels on screen.
local ART = [[Interface\AddOns\WowCompanion_Agent\Art\%s-%s-10]]
local function dress(owner, art, rim, top)
	local slice = owner.NineSlice
	if not slice then return end
	local p = {}
	for _, name in ipairs({ "TopLeftCorner", "TopRightCorner", "BottomLeftCorner", "BottomRightCorner",
		"TopEdge", "BottomEdge", "LeftEdge", "RightEdge" }) do
		local t = slice[name]
		if not t then return end
		t:SetTexture(ART:format(art, name))
		t:SetTexCoord(0, 1, 0, 1)
		t:SetHorizTile(false)
		t:SetVertTile(false)
		t:ClearAllPoints()
		p[name] = t
	end
	p.TopLeftCorner:SetPoint("TOPLEFT", owner)
	p.TopRightCorner:SetPoint("TOPRIGHT", owner)
	p.BottomLeftCorner:SetPoint("BOTTOMLEFT", owner)
	p.BottomRightCorner:SetPoint("BOTTOMRIGHT", owner)
	p.TopLeftCorner:SetSize(rim, top)
	p.TopRightCorner:SetSize(rim, top)
	p.BottomLeftCorner:SetSize(rim, rim)
	p.BottomRightCorner:SetSize(rim, rim)
	p.TopEdge:SetPoint("TOPLEFT", p.TopLeftCorner, "TOPRIGHT")
	p.TopEdge:SetPoint("BOTTOMRIGHT", p.TopRightCorner, "BOTTOMLEFT")
	p.BottomEdge:SetPoint("TOPLEFT", p.BottomLeftCorner, "TOPRIGHT")
	p.BottomEdge:SetPoint("BOTTOMRIGHT", p.BottomRightCorner, "BOTTOMLEFT")
	p.LeftEdge:SetPoint("TOPLEFT", p.TopLeftCorner, "BOTTOMLEFT")
	p.LeftEdge:SetPoint("BOTTOMRIGHT", p.BottomLeftCorner, "TOPRIGHT")
	p.RightEdge:SetPoint("TOPLEFT", p.TopRightCorner, "BOTTOMLEFT")
	p.RightEdge:SetPoint("BOTTOMRIGHT", p.BottomRightCorner, "TOPRIGHT")
end

-- The wells' border, A, C or E while the player chooses between them (2026-11-12,
-- tools/make_frame_art.py's WELLS); WC.Window.WellStyle(letter) redresses them
-- all at once and keeps the choice.
local wells = {}
local function wellStyle()
	local db = WowCompanionAgentDB
	return type(db) == "table" and db.wellStyle or "C"
end
local function dressWell(owner)
	wells[#wells + 1] = owner
	dress(owner, "Inset" .. wellStyle(), INSET, INSET)
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
	WC.SettingsPage.Add({ kind = "dropdown", section = "Companion window", order = 10, label = "Window size",
		text = "The size the Companion window opens at. Its corner grip changes it just for now.",
		options = function() return frame.SIZE_NAMES or { "Small", "Medium", "Large" } end,
		get = function() return (frame.SIZE_NAMES or {})[WowCompanionAgentDB.windowSize or 2] end,
		set = function(name)
			for i, n in ipairs(frame.SIZE_NAMES or {}) do
				if n == name and frame.SetDefaultSize then frame.SetDefaultSize(i) end
			end
		end })
	WC.SettingsPage.Add({ kind = "slider", section = "Companion window", order = 15, label = "Window scale",
		text = "The Companion window and everything in it, apart from the rest of the interface.",
		min = 80, max = 200, steps = 12,
		get = function() return math.floor((WowCompanionAgentDB.windowScale or 1) * 100 + 0.5) end,
		set = function(value) frame.SetWindowScale(math.floor(value + 0.5) / 100) end,
		format = function(value) return ("%d%%"):format(math.floor(value + 0.5)) end })
	WC.SettingsPage.Add({ kind = "button", section = "Clean up", order = 90, label = "Clear transcript", button = "Clear",
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

	-- The conversation picker: a well on the right in the chat's own language,
	-- the darker slate under the names; the one in view a plate of the
	-- replies' slate between two vines, as a reply sits in the chat. Chat tab only.
	local WELL = 130
	local made, well = pcall(CreateFrame, "Frame", nil, frame, "InsetFrameTemplate")
	if not made or not well then well = CreateFrame("Frame", nil, frame) end
	dressWell(well)
	well:SetPoint("TOPRIGHT", -(RIM + GAP), -WELL_TOP)
	well:SetPoint("BOTTOMRIGHT", -(RIM + GAP), RIM + FOOT)
	well:SetWidth(WELL)
	local back = well:CreateTexture(nil, "BACKGROUND", nil, 1)
	back:SetTexture(WC.Style.STONE.you, "REPEAT", "REPEAT")
	back:SetHorizTile(true)
	back:SetVertTile(true)
	back:SetPoint("TOPLEFT", INSET, -INSET)
	back:SetPoint("BOTTOMRIGHT", -INSET, INSET)
	frame.chatParts = frame.chatParts or {}
	table.insert(frame.chatParts, well)
	-- The transcript sits in a well of its own, an inset like the conversation
	-- list's, with its scroll arrows inside it; the raised frame around them
	-- keeps only the waiting line.
	local madeChat, chatWell = pcall(CreateFrame, "Frame", nil, frame, "InsetFrameTemplate")
	if not madeChat or not chatWell then chatWell = CreateFrame("Frame", nil, frame) end
	dressWell(chatWell)
	chatWell:SetPoint("TOPLEFT", RIM + GAP, -WELL_TOP)
	chatWell:SetPoint("BOTTOMRIGHT", well, "BOTTOMLEFT", -GAP, 0)
	table.insert(frame.chatParts, chatWell)
	-- The chat well's geometry, in one place (docs/ui-layout.md): inside the
	-- inset's border (EDGE, its whole carved wall: the text clips there and
	-- never scrolls across the wall) the transcript fills the well, and the
	-- scroll bar (ChatBar.lua) stands over its right end, so each turn's stone
	-- runs on behind the bar to the edge.
	local EDGE = INSET
	local level = chatWell:GetFrameLevel()
	messages.scroll:ClearAllPoints()
	messages.scroll:SetPoint("TOPLEFT", chatWell, "TOPLEFT", EDGE, -EDGE)
	messages.scroll:SetPoint("BOTTOMRIGHT", chatWell, "BOTTOMRIGHT", -EDGE, EDGE)
	messages.scroll:SetFrameLevel(level + 1)
	messages.content:SetFrameLevel(level + 2)
	local column, up, down = WC.ChatBar.Build(chatWell, messages.scroll, EDGE, level)
	for _, part in ipairs({ column, up, down }) do table.insert(frame.chatParts, part) end
	-- a row's height, and its name's colour: washed bronze, lit when in view
	local ROW = 24
	local NAME, NAME_LIT = { 0.78, 0.69, 0.53 }, { 0.98, 0.92, 0.78 }
	-- the chat's vine (ChatBar.lua) along a plate's edge, rounded at both ends
	local function vine(owner, edge)
		local art = WC.ChatBar.Art
		local left = owner:CreateTexture(nil, "ARTWORK")
		left:SetTexture(art("RuleLeft"))
		left:SetSize(32, 16)
		left:SetPoint("LEFT", owner, edge .. "LEFT", 0, 0)
		local right = owner:CreateTexture(nil, "ARTWORK")
		right:SetTexture(art("RuleLeft"))
		right:SetTexCoord(1, 0, 0, 1)
		right:SetSize(32, 16)
		right:SetPoint("RIGHT", owner, edge .. "RIGHT", 0, 0)
		local mid = owner:CreateTexture(nil, "ARTWORK")
		mid:SetTexture(art("RuleMid"))
		mid:SetHeight(16)
		mid:SetPoint("LEFT", left, "RIGHT")
		mid:SetPoint("RIGHT", right, "LEFT")
		return { left, mid, right }
	end
	frame.convButtons = {}
	for i, key in ipairs(WC.Conversations.list) do
		local b = CreateFrame("Button", nil, well)
		-- rows edge to edge across the well, flush one under the next
		b:SetHeight(ROW)
		b:SetPoint("TOPLEFT", well, "TOPLEFT", INSET, -INSET - 4 - (i - 1) * ROW)
		b:SetPoint("TOPRIGHT", well, "TOPRIGHT", -INSET, -INSET - 4 - (i - 1) * ROW)
		local text = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		text:SetPoint("LEFT", 12, 0)
		text:SetPoint("RIGHT", -8, 0)
		text:SetJustifyH("LEFT")
		text:SetTextColor(unpack(NAME))
		b:SetFontString(text)
		-- the one in view: a plate of the replies' slate, a vine along its
		-- top and its foot, its name lit (Agent.lua shows it with SetShown)
		local plate = b:CreateTexture(nil, "BACKGROUND")
		plate:SetTexture(WC.Style.STONE.claude, "REPEAT", "REPEAT")
		plate:SetHorizTile(true)
		plate:SetVertTile(true)
		plate:SetAllPoints()
		local parts = { plate }
		for _, edge in ipairs({ "TOP", "BOTTOM" }) do
			for _, t in ipairs(vine(b, edge)) do parts[#parts + 1] = t end
		end
		local selected = {}
		function selected:SetShown(on)
			for _, t in ipairs(parts) do t:SetShown(on) end
			text:SetTextColor(unpack(on and NAME_LIT or NAME))
		end
		function selected:Show() self:SetShown(true) end
		selected:SetShown(false)
		b.selected = selected
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
	-- well reads as sunk into the panel: Blizzard's own ShadowOverlay-Top
	-- (SharedUIPanelTemplates.xml:195), above the scrolling text and its
	-- dividers so they slide under it. It covers the turns only, fading out
	-- sideways as it nears the bar, so the bar stands above the chat, unshaded,
	-- with no edge where the shadow stops.
	local FADE = 48
	local lip = CreateFrame("Frame", nil, chatWell)
	lip:SetPoint("TOPLEFT", messages.scroll, "TOPLEFT")
	lip:SetPoint("TOPRIGHT", column, "TOPLEFT", -6, 0)
	lip:SetHeight(24)
	lip:SetFrameLevel(level + 5)
	local shade = lip:CreateTexture(nil, "OVERLAY")
	shade:SetTexture([[Interface\Common\ShadowOverlay-Top]])
	shade:SetPoint("TOPLEFT")
	shade:SetPoint("BOTTOMRIGHT", -FADE, 0)
	local fade = lip:CreateTexture(nil, "OVERLAY")
	fade:SetTexture([[Interface\Common\ShadowOverlay-Top]])
	fade:SetPoint("TOPLEFT", shade, "TOPRIGHT")
	fade:SetPoint("BOTTOMRIGHT")
	fade:SetGradient("HORIZONTAL", CreateColor(1, 1, 1, 1), CreateColor(1, 1, 1, 0))
	table.insert(frame.chatParts, lip)

	-- the page well, over both wells' area, for the other tabs
	local madePage, pageWell = pcall(CreateFrame, "Frame", nil, frame, "InsetFrameTemplate")
	if not madePage or not pageWell then pageWell = CreateFrame("Frame", nil, frame) end
	dressWell(pageWell)
	pageWell:SetPoint("TOPLEFT", chatWell, "TOPLEFT")
	pageWell:SetPoint("BOTTOMRIGHT", well, "BOTTOMRIGHT")
	pageWell:Hide()
	local function place(p)
		p:SetParent(pageWell)
		p:SetPoint("TOPLEFT", 12, -10)
		p:SetPoint("BOTTOMRIGHT", -12, 10)
	end
	for _, p in pairs(pages) do place(p) end
	-- One stone over the whole page well, edge to edge inside its border, for
	-- every tab but Chat: one texture, divided by the pages' dividers (the
	-- well's own backing peeked out around a smaller card, the player,
	-- 2026-11-11; Settings looked bare beside Status without it).
	local stone = pageWell:CreateTexture(nil, "BACKGROUND", nil, 1)
	stone:SetTexture(WC.Style.STONE.claude, "REPEAT", "REPEAT")
	stone:SetHorizTile(true)
	stone:SetVertTile(true)
	stone:SetPoint("TOPLEFT", 3, -3)
	stone:SetPoint("BOTTOMRIGHT", -3, 3)
	-- the same shadow under the tabs as the chat well has, on every other tab,
	-- from the wall's foot
	local pageLip = CreateFrame("Frame", nil, pageWell)
	pageLip:SetPoint("TOPLEFT", INSET, -INSET)
	pageLip:SetPoint("TOPRIGHT", -INSET, -INSET)
	pageLip:SetHeight(24)
	pageLip:SetFrameLevel(pageWell:GetFrameLevel() + 20)
	local pageShade = pageLip:CreateTexture(nil, "OVERLAY")
	pageShade:SetTexture([[Interface\Common\ShadowOverlay-Top]])
	pageShade:SetAllPoints()

	-- The tabs, in the chat's own language (the player's look, 2026-11-12):
	-- no boxes of their own. The chosen tab is a plate of the replies' marbled
	-- slate standing on the chat well, crowned by the dividers' bronze vine
	-- (ChatBar.lua's art: its curl at each end, its middle stretched); its
	-- label is light. The others are only their labels, in washed bronze, on
	-- the panel. The row's spacing is here: every tab at least TAB_MIN wide
	-- (PanelTemplates_TabResize reads frame.minTabWidth), TAB_GAP between
	-- them, the first over the well's inner edge (EDGE).
	local names = {}
	local VINE = [[Interface\AddOns\WowCompanion_Agent\Art\Scroll-%s-18]] -- ChatBar.lua's VERSION
	local TAB_MIN, TAB_GAP, TAB_H = 69, 3, 25.6
	local LIGHT, BRONZE = { 0.94, 0.9, 0.82 }, { 0.78, 0.64, 0.42 }
	frame.minTabWidth = TAB_MIN
	local function makeTab(name)
		local i = #names + 1
		local made, tab = pcall(CreateFrame, "Button", nil, frame, "PanelTopTabButtonTemplate")
		if not made or not tab then return end
		-- the template's art goes; ours is the plate and its vine
		for _, part in ipairs({ "Left", "Middle", "Right" }) do
			for _, state in ipairs({ "", "Active", "Highlight" }) do
				local t = tab[part .. state]
				if t then t:SetTexture(nil) end
			end
		end
		local plate = tab:CreateTexture(nil, "BACKGROUND", nil, -8)
		plate:SetTexture(WC.Style.STONE.claude, "REPEAT", "REPEAT")
		plate:SetHorizTile(true)
		plate:SetVertTile(true)
		plate:SetPoint("BOTTOMLEFT")
		plate:SetPoint("BOTTOMRIGHT")
		plate:SetHeight(TAB_H)
		local left = tab:CreateTexture(nil, "ARTWORK")
		left:SetTexture(VINE:format("RuleLeft"))
		left:SetSize(32, 16)
		left:SetPoint("LEFT", plate, "TOPLEFT", -4, 0)
		local right = tab:CreateTexture(nil, "ARTWORK")
		right:SetTexture(VINE:format("RuleLeft"))
		right:SetTexCoord(1, 0, 0, 1)
		right:SetSize(32, 16)
		right:SetPoint("RIGHT", plate, "TOPRIGHT", 4, 0)
		local mid = tab:CreateTexture(nil, "ARTWORK")
		mid:SetTexture(VINE:format("RuleMid"))
		mid:SetHeight(16)
		mid:SetPoint("LEFT", left, "RIGHT")
		mid:SetPoint("RIGHT", right, "LEFT")
		tab.chosenParts = { plate, left, right, mid }
		names[i] = name
		tab:SetID(i)
		tab:SetText(name)
		if i == 1 then
			tab:SetPoint("BOTTOMLEFT", chatWell, "TOPLEFT", EDGE, 0)
		else
			tab:SetPoint("LEFT", frame.Tabs[i - 1], "RIGHT", TAB_GAP, 0)
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
		for i, tab in ipairs(frame.Tabs) do
			local chosen = i == id
			for _, part in ipairs(tab.chosenParts) do part:SetShown(chosen) end
			tab.Text:SetTextColor(unpack(chosen and LIGHT or BRONZE))
		end
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
	-- One panel, Blizzard's ButtonFrameTemplate, as the macro frame is built
	-- (its background, title and close button; the border, title bar and the
	-- close button's art are ours, dress below), with the tabs standing on the
	-- wells inside it (docs/proposals/companion-window-frame.md).
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
	WC.Style.NoPortrait(frame)
	-- our wells take the template's inset's place
	if frame.Inset then frame.Inset:Hide() end
	if frame.SetTitle then frame:SetTitle("Companion") end
	-- our border and title bar over the template's, on the frame's bounds,
	-- and the focus glow fitted round them
	dress(frame, "Frame", RIM, TOP)
	-- The panel's body: the chat's slate, darker, so the window is one stone
	-- trimmed in bronze; to the rim's inner edge on every side (the template
	-- set it 7 in on the left for Blizzard's wider border, which left a strip
	-- of the world showing between our rim and the panel).
	if frame.Bg then
		frame.Bg:SetTexture(WC.Style.STONE.you, "REPEAT", "REPEAT")
		frame.Bg:SetHorizTile(true)
		frame.Bg:SetVertTile(true)
		frame.Bg:SetVertexColor(0.72, 0.72, 0.72)
		frame.Bg:ClearAllPoints()
		frame.Bg:SetPoint("TOPLEFT", RIM, -RIM)
		frame.Bg:SetPoint("BOTTOMRIGHT", -RIM, RIM)
	end
	if frame.FrameGlow then
		frame.FrameGlow:ClearAllPoints()
		frame.FrameGlow:SetPoint("TOPLEFT", frame, "TOPLEFT", -GLOW[1], GLOW[2])
		frame.FrameGlow:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", GLOW[3], -GLOW[4])
	end
	-- the title centred in the band, between the close button and its mirror
	local bar = frame.TitleContainer
	if bar then
		bar:ClearAllPoints()
		bar:SetPoint("TOPLEFT", frame, "TOPLEFT", RIM + CLOSE_PAD + CLOSE, -RIM)
		bar:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", -(RIM + CLOSE_PAD + CLOSE), -BAND)
		if bar.TitleText then
			bar.TitleText:ClearAllPoints()
			bar.TitleText:SetPoint("LEFT")
			bar.TitleText:SetPoint("RIGHT")
			-- a soft old gold, not Blizzard's bright yellow: the window's bronze lit
			bar.TitleText:SetTextColor(0.90, 0.79, 0.55)
		end
	end
	-- our close button inside the title band's right end, centred in it; the
	-- controller's back button (circle) closes a focused window by clicking its
	-- frame.CloseButton (SmartNavigation:AttemptClose)
	if frame.CloseButton then
		local close = frame.CloseButton
		close:SetSize(CLOSE, CLOSE)
		close:ClearAllPoints()
		close:SetPoint("TOPRIGHT", -(RIM + CLOSE_PAD), -(RIM + BAND - CLOSE) / 2)
		close:SetNormalTexture(ART:format("Close", "Normal"))
		close:SetPushedTexture(ART:format("Close", "Pushed"))
		close:SetDisabledTexture(ART:format("Close", "Disabled"))
		close:SetHighlightTexture(ART:format("Close", "Highlight"), "ADD")
		close:SetScript("OnClick", function()
			if WowCompanion_HideWindow then WowCompanion_HideWindow() else frame:Hide() end
		end)
	end
	-- the title bar is the drag handle, so a drag inside the transcript stays free
	frame:SetMovable(true)
	if bar then
		bar:EnableMouse(true)
		bar:RegisterForDrag("LeftButton")
		bar:SetScript("OnDragStart", function() frame:StartMoving() end)
		bar:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)
	end

	local messages = newTranscript(frame)
	messages.scroll:SetPoint("TOPLEFT", 20, -42)
	messages.scroll:SetPoint("BOTTOMRIGHT", -40, 34)
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
	grip:SetPoint("BOTTOMRIGHT", -RIM, RIM)
	-- Blizzard's only corner grip is the chat frame's 16px file, blurry when
	-- scaled; this draws its three diagonal ridges as lines (crisp at any scale),
	-- cut into the panel: each groove is a dark line with a faint light lip on its
	-- lower-right side, as if lit from the top left. A touch lighter on hover.
	local LIP, LIP_LIT = { 0.6, 0.57, 0.5, 0.28 }, { 0.85, 0.8, 0.65, 0.55 }
	local lips = {}
	for i = 1, 3 do
		local d = i * 4
		for _, part in ipairs({ { 0, 0, 0, 0.6, 0 }, { LIP[1], LIP[2], LIP[3], LIP[4], 1 } }) do
			local l = grip:CreateLine(nil, "OVERLAY")
			l:SetThickness(1)
			l:SetColorTexture(part[1], part[2], part[3], part[4])
			l:SetStartPoint("BOTTOMRIGHT", -d - 1 + part[5], 2 - part[5])
			l:SetEndPoint("BOTTOMRIGHT", -2 + part[5], d + 1 - part[5])
			if part[5] == 1 then lips[#lips + 1] = l end
		end
	end
	grip:SetScript("OnEnter", function() for _, l in ipairs(lips) do l:SetColorTexture(unpack(LIP_LIT)) end end)
	grip:SetScript("OnLeave", function() for _, l in ipairs(lips) do l:SetColorTexture(unpack(LIP)) end end)
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
function WC.Window.WellStyle(letter)
	if type(WowCompanionAgentDB) == "table" then WowCompanionAgentDB.wellStyle = letter end
	for _, owner in ipairs(wells) do dress(owner, "Inset" .. letter, INSET, INSET) end
end
-- the middle of the strip under the wells, for the legend (Jobs.lua)
WC.Window.FOOT_MID = RIM + FOOT / 2
