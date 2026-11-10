-- Split out of Companion.lua (2026-11-10). What it needs from there comes
-- through WC.Core; what Companion.lua calls here is WC.Window.

local core = WC.Core
local effectiveModules = core.effectiveModules
local frame = core.frame
local newTranscript = core.newTranscript
local function nextSlot_now() return core.nextSlot_get() end

-- Tabs along the bottom edge, as Blizzard's own panels have them
-- (PanelTabButtonTemplate, PanelTemplates_SetTab), picked with the controller
-- cursor. No shoulder buttons: L1 and R1 are talk-button slots.
local TAB_NAMES = { "Chat", "Tools", "Status" }
local function buildTabs(frame, messages, pending)
	local pages = {}
	local function page()
		local p = CreateFrame("Frame", nil, frame)
		p:SetPoint("TOPLEFT", 20, -42)
		p:SetPoint("BOTTOMRIGHT", -20, 34)
		p:Hide()
		return p
	end
	pages[2], pages[3] = page(), page()

	-- Tools: everyday buttons, Blizzard's red panel buttons in a column, each
	-- with a line saying what it does
	local tools = pages[2]
	local y = 0
	local function note(b, text)
		local fs = tools:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		fs:SetPoint("LEFT", b, "RIGHT", 12, 0)
		fs:SetPoint("RIGHT", tools, "RIGHT", 0, 0)
		fs:SetJustifyH("LEFT")
		fs:SetText(text)
	end
	local function button(label, text, onClick)
		local made, b = pcall(CreateFrame, "Button", nil, tools, "UIPanelButtonTemplate")
		if not made or not b then return end
		b:SetSize(170, 26)
		b:SetPoint("TOPLEFT", 0, -y)
		b:SetText(label)
		b:SetScript("OnClick", onClick)
		note(b, text)
		if SmartNavigation_MarkFrameFocusable then pcall(SmartNavigation_MarkFrameFocusable, b) end
		y = y + 34
		return b
	end
	-- The reload is protected, so it is a secure button the player presses. Built
	-- out of combat only: a secure frame's attributes cannot be set in one.
	local reloadY = y
	y = y + 34
	local function makeReload()
		if frame.reloadButton or InCombatLockdown() then return end
		local made, b = pcall(CreateFrame, "Button", "WowCompanionReload", tools,
			"SecureActionButtonTemplate, UIPanelButtonTemplate")
		if not made or not b then return end
		b:SetSize(170, 26)
		b:SetPoint("TOPLEFT", 0, -reloadY)
		b:SetText("Reload UI")
		b:SetAttribute("type", "macro")
		b:SetAttribute("macrotext", "/reload")
		b:RegisterForClicks("AnyDown") -- see CLAUDE.md, "Register a secure button for AnyDown"
		note(b, "Lets me see what changed, and clears any taint.")
		if SmartNavigation_MarkFrameFocusable then pcall(SmartNavigation_MarkFrameFocusable, b) end
		frame.reloadButton = b
	end
	makeReload()
	local sizeButton = button("Size: " .. ({ "Small", "Medium", "Large" })[WowCompanionDB.windowSize or 2],
		"The size the window opens at. The corner grip changes it just for now.")
	if sizeButton then
		sizeButton:SetScript("OnClick", function(self)
			self:SetText("Size: " .. frame.CycleDefaultSize())
		end)
	end
	button("Clear map pins", "Remove every pin I put on your minimap and world map.", function()
		if WCPins and WCPins.Clear then WCPins.Clear() end
		frame.SelectTab(3)
	end)
	button("Clear transcript", "Empty this window. The conversation itself carries on.", function()
		WowCompanionDB.log = {}
		messages:Clear()
		frame.SelectTab(1)
	end)

	-- Status: what is running, read fresh while the tab is looked at
	local status = pages[3]:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	status:SetPoint("TOPLEFT")
	status:SetPoint("TOPRIGHT")
	status:SetJustifyH("LEFT")
	status:SetJustifyV("TOP")
	status:SetSpacing(5)
	local function refreshStatus()
		local gold, grey = "|cffffd100", "|cff9d9d9d"
		local lines = {}
		local function add(label, value) lines[#lines + 1] = gold .. label .. "|r   " .. value end
		local up = WowCompanion_IsUp and WowCompanion_IsUp()
		add("Companion app", up and "|cff40ff40connected|r"
			or "|cffff6060not heard from|r " .. grey .. "(is it running on the PC?)|r")
		add("Messages this session", ("%d of 64 %s(a reload resets it)|r"):format(nextSlot_now() - 1, grey))
		local pins = WowCompanionDB.pins and #WowCompanionDB.pins or 0
		add("Map pins", pins == 0 and "none" or tostring(pins))
		local wheels = {}
		for key, wheel in pairs(WowCompanionWheelDB and WowCompanionWheelDB.wheels or {}) do
			wheels[#wheels + 1] = (wheel.label or key) .. " " .. grey .. "(" .. #(wheel.slots or {}) .. ")|r"
		end
		table.sort(wheels)
		add("Wheels", #wheels > 0 and table.concat(wheels, ", ") or "none")
		local modules = {}
		for name in pairs(effectiveModules()) do modules[#modules + 1] = name end
		table.sort(modules)
		add("My modules", #modules > 0 and table.concat(modules, ", ") or "none")
		local blocked = WowCompanionDB.blocked or {}
		local b = blocked[#blocked]
		add("Blocked actions", b and ("%d kinds, last %s: %s x%d"):format(#blocked, date("%H:%M", b.at or 0), b.what, b.count or 1) or "none")
		add("Combat", InCombatLockdown() and "|cffff6060yes|r " .. grey .. "(changes wait until it ends)|r" or "no")
		status:SetText(table.concat(lines, "\n"))
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
	well:SetPoint("TOPRIGHT", -16, -40)
	well:SetPoint("BOTTOMRIGHT", -16, 32)
	well:SetWidth(WELL)
	local back = well:CreateTexture(nil, "BACKGROUND", nil, 1)
	back:SetAtlas("auctionhouse-background-categories")
	back:SetPoint("TOPLEFT", 3, -3)
	back:SetPoint("BOTTOMRIGHT", -3, 3)
	frame.chatParts = frame.chatParts or {}
	table.insert(frame.chatParts, well)
	-- The transcript sits in a well of its own, an inset like the conversation
	-- list's, with its scroll arrows inside it; the raised frame around them
	-- keeps only the waiting line (the player, 2026-11-10).
	local madeChat, chatWell = pcall(CreateFrame, "Frame", nil, frame, "InsetFrameTemplate")
	if not madeChat or not chatWell then chatWell = CreateFrame("Frame", nil, frame) end
	chatWell:SetPoint("TOPLEFT", 16, -40)
	chatWell:SetPoint("BOTTOMRIGHT", -(16 + WELL + 6), 32)
	table.insert(frame.chatParts, chatWell)
	messages.scroll:ClearAllPoints()
	messages.scroll:SetPoint("TOPLEFT", chatWell, "TOPLEFT", 10, -8)
	messages.scroll:SetPoint("BOTTOMRIGHT", chatWell, "BOTTOMRIGHT", -28, 8)
	messages.scroll:SetFrameLevel(chatWell:GetFrameLevel() + 2)
	if frame.chatParts[1] and frame.chatParts[2] then
		frame.chatParts[1]:ClearAllPoints()
		frame.chatParts[1]:SetPoint("TOPRIGHT", chatWell, "TOPRIGHT", -5, -6)
		frame.chatParts[1]:SetFrameLevel(chatWell:GetFrameLevel() + 3)
		frame.chatParts[2]:ClearAllPoints()
		frame.chatParts[2]:SetPoint("BOTTOMRIGHT", chatWell, "BOTTOMRIGHT", -5, 6)
		frame.chatParts[2]:SetFrameLevel(chatWell:GetFrameLevel() + 3)
	end
	frame.convButtons = {}
	local LABELS = { [""] = "Main", l1 = "L1", l2 = "L2", r1 = "R1", r2 = "R2", quick = "Quick" }
	for i, key in ipairs({ "", "l1", "l2", "r1", "r2", "quick" }) do
		local b = CreateFrame("Button", nil, well)
		b:SetSize(WELL - 10, 24)
		b:SetPoint("TOP", well, "TOP", 0, -6 - (i - 1) * 26)
		local normal = b:CreateTexture(nil, "BACKGROUND")
		normal:SetAtlas("auctionhouse-nav-button")
		normal:SetAllPoints()
		local selected = b:CreateTexture(nil, "ARTWORK")
		selected:SetAtlas("auctionhouse-nav-button-select")
		selected:SetBlendMode("ADD")
		selected:SetAllPoints()
		selected:Hide()
		b.selected = selected
		local glow = b:CreateTexture(nil, "HIGHLIGHT")
		glow:SetAtlas("auctionhouse-nav-button-highlight")
		glow:SetBlendMode("ADD")
		glow:SetAllPoints()
		local text = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		text:SetPoint("LEFT", 12, 0)
		text:SetPoint("RIGHT", -8, 0)
		text:SetJustifyH("LEFT")
		b:SetFontString(text)
		-- news kept across a reload shows from the start
		local kept = type(WowCompanionDB) == "table" and WowCompanionDB.unread
		-- Main is the one in view after a reload, so its news is being read
		if kept and key == "" then kept[""] = nil end
		if kept and kept[key] then
			b:SetText("|cff40ff40" .. LABELS[key] .. "  new|r")
		else
			b:SetText(LABELS[key])
		end
		b:SetScript("OnClick", function() WowCompanion_SetConversation(key) end)
		if SmartNavigation_MarkFrameFocusable then pcall(SmartNavigation_MarkFrameFocusable, b) end
		frame.convButtons[key] = b
	end
	frame.convButtons[""].selected:Show()

	-- the tabs, hanging under the bottom edge like the character sheet's
	for i, name in ipairs(TAB_NAMES) do
		local made, tab = pcall(CreateFrame, "Button", nil, frame, "PanelTabButtonTemplate")
		if not made or not tab then return end
		tab:SetID(i)
		tab:SetText(name)
		if i == 1 then
			tab:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 14, 6)
		else
			tab:SetPoint("TOPLEFT", frame.Tabs[i - 1], "TOPRIGHT", 3, 0)
		end
		tab:SetScript("OnClick", function(self) frame.SelectTab(self:GetID()) end)
		if SmartNavigation_MarkFrameFocusable then pcall(SmartNavigation_MarkFrameFocusable, tab) end
	end
	PanelTemplates_SetNumTabs(frame, #TAB_NAMES)

	function frame.SelectTab(id)
		id = ((id - 1) % #TAB_NAMES) + 1
		frame.currentTab = id
		PanelTemplates_SetTab(frame, id)
		local chat = id == 1
		messages.scroll:SetShown(chat)
		for _, part in ipairs(frame.chatParts or {}) do part:SetShown(chat) end
		if not chat then pending:Hide() elseif frame.pendingShown then pending:Show() end
		for i, p in pairs(pages) do p:SetShown(i == id) end
		if id == 2 then makeReload() end
	end
	frame.SelectTab(1)

	-- Tabs are picked with the controller cursor. L1 and R1 used to page them,
	-- but they are talk-button slots now (the player, 2026-11-10), so the window
	-- binds nothing. The reload button waits out combat, being secure.
	local keys = CreateFrame("Frame")
	keys:RegisterEvent("PLAYER_REGEN_ENABLED")
	keys:SetScript("OnEvent", function() makeReload() end)
end

-- The conversation window. Chat lines scroll away and cannot be scrolled back
-- through, so replies live in their own frame and in SavedVariables, which is what
-- makes history survive a /reload.
--
-- Deliberately not registered in UISpecialFrames: Escape handling is where the
-- gamepad taint lives, and this frame has a close button instead.
local function buildLog()
	-- the game's own dialog art, so it sits in the UI rather than on top of it.
	-- CreateFrame throws on a template this build lacks, and an ugly window beats
	-- an addon that fails to load.
	local made, frame = pcall(CreateFrame, "Frame", "WowCompanionLog", UIParent, "BackdropTemplate")
	if not made or not frame then
		frame = CreateFrame("Frame", "WowCompanionLog", UIParent)
	end
	frame:SetSize(560, 340)
	-- top left, where Blizzard docks its own left panels (the character sheet,
	-- the spellbook); the panel manager places it there on every open
	frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 16, -116)
	frame:SetFrameStrata("DIALOG")
	frame:SetClampedToScreen(true)
	frame:Hide()
	if frame.SetBackdrop then
		frame:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			edgeSize = 32,
			insets = { left = 11, right = 12, top = 12, bottom = 11 },
		})
	end

	-- the header strip is the drag handle, so a drag inside the transcript is free
	-- to select text instead of hauling the window around
	local header = CreateFrame("Frame", nil, frame)
	header:SetPoint("TOPLEFT", 12, -12)
	header:SetPoint("TOPRIGHT", -12, -12)
	header:SetHeight(26)
	header:EnableMouse(true)
	header:RegisterForDrag("LeftButton")
	frame:SetMovable(true)
	header:SetScript("OnDragStart", function() frame:StartMoving() end)
	header:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)

	local crest = header:CreateTexture(nil, "ARTWORK")
	crest:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
	crest:SetPoint("TOP", frame, "TOP", 0, 12)
	crest:SetSize(230, 64)
	local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOP", crest, "TOP", 0, -14)
	title:SetText("Companion")

	local closed, close = pcall(CreateFrame, "Button", nil, frame, "UIPanelCloseButton")
	if closed and close then
		close:SetPoint("TOPRIGHT", -6, -6)
		close:SetScript("OnClick", function() if WowCompanion_HideWindow then WowCompanion_HideWindow() else frame:Hide() end end)
		-- the controller's back button (circle) closes a focused window by clicking
		-- its frame.CloseButton (SmartNavigation:AttemptClose), so name it that
		frame.CloseButton = close
	end

	-- the waiting line: the agent takes seconds, and silence reads as broken
	local pending = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	-- A fixed box, text pinned left and never wrapping: with one anchor the region
	-- resized to its text on every tick, so the dots coming and going made the
	-- line jump. Now only the dots move.
	pending:SetPoint("BOTTOMLEFT", 18, 16)
	pending:SetPoint("BOTTOMRIGHT", -180, 16)
	pending:SetJustifyH("LEFT")
	pending:SetWordWrap(false)
	pending:Hide()
	frame.pending = pending

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
	-- The scroll bar between the arrows (the player, 2026-11-10): a thumb sized to
	-- the share of the transcript in view and placed at the scroll position, in
	-- Blizzard's own scroll bar art. Shown only, never dragged: the arrows scroll.
	if #arrows == 2 then
		local track = CreateFrame("Frame", nil, frame)
		track:SetPoint("TOP", arrows[1], "BOTTOM", 0, -2)
		track:SetPoint("BOTTOM", arrows[2], "TOP", 0, 2)
		track:SetWidth(arrows[1]:GetWidth() > 0 and arrows[1]:GetWidth() or 16)
		local groove = track:CreateTexture(nil, "BACKGROUND")
		groove:SetPoint("TOPLEFT", 3, 0)
		groove:SetPoint("BOTTOMRIGHT", -3, 0)
		groove:SetColorTexture(0, 0, 0, 0.45)
		-- Nothing is stretched (the player, 2026-11-10). The thumb is drawn as
		-- Blizzard's WowTrimScrollBar thumb is (TrimScrollBar.xml and .lua): the
		-- round end caps at their own size, and the centre *tiled*: its texture
		-- coordinate runs past 1 by the height over the art's own height, so the
		-- art repeats instead of growing. Without those atlases the old knob is
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
	if SmartNavigation_MarkFrameFocusable then
		pcall(SmartNavigation_MarkFrameFocusable, frame)
	end
	-- A real UI panel, so the controller's focus-cycle button reaches it like any
	-- of the game's own windows: that cycle walks the panels FrameControlsManager
	-- was told about, and ShowUIPanel is what tells it.
	--
	-- The catch, read in Blizzard_GamepadSharedUtility/FrameControlsManager.lua: a
	-- shown panel turns on the "fallthrough catcher" binding group, which takes the
	-- d-pad and face buttons away from the bars, and only FrameHidden turns it off.
	-- HideUIPanel sends that; a plain Hide (our close button, /wc log) does not, so
	-- the manager kept a closed window in its list and the bars stayed dead after
	-- it was gone. That is why it broke with the window shut. Blizzard's own
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
	-- The right stick scrolls a panel's text once SmartNavigation is told which
	-- scroll frame belongs to it, as the chat frame and Blizzard's own dialogs do
	-- (FloatingChatFrame.lua, SocialContract.lua). It is SecureHelper-wrapped for
	-- such callers. Deferred a tick, so the panel is registered first.
	frame:SetScript("OnShow", function(self)
		C_Timer.After(0, function()
			-- the transcript is text, no buttons: without this flag a right-stick
			-- scroll went looking for a button inside it, found none, and left the
			-- cursor drawn on the close button while nothing was selected
			-- (UpdateScrollSelection; the flag is Blizzard's, for "message text")
			if SmartNavigation_MarkScrollFrameMaintainPreviousButtonOnScroll and self.messages then
				pcall(SmartNavigation_MarkScrollFrameMaintainPreviousButtonOnScroll, self.messages.scroll)
			end
			-- not handed to SmartNavigation any more: that gave it the right stick
			-- and took the camera away while the window had focus; the arrows scroll
		end)
	end)
	frame:SetScript("OnHide", function(self)
		if GamepadMode and GamepadMode.FrameControlsManager
			and InputUtil and InputUtil.IsGamepadUIEnabled() then
			GamepadMode.FrameControlsManager:FrameHidden(self)
		end
	end)

	frame:SetResizable(true)
	if frame.SetResizeBounds then
		frame:SetResizeBounds(320, 180)
	end
	local grip = CreateFrame("Button", nil, frame)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", -8, 8)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	-- A mouse drags it; the controller can only click it, which used to do
	-- nothing. So a click that did not resize steps through three sizes. A drag
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
	-- The corner grip steps the size for now; the Tools tab's button sets the
	-- default the window opens at, kept in WowCompanionDB.windowSize (the player,
	-- 2026-11-10: medium unless they pick otherwise).
	local function applySize(index)
		local pick = SIZES[index] or SIZES[2]
		-- grow from the top-left corner, so the window stays where it is
		local left, top = frame:GetLeft(), frame:GetTop()
		-- never taller than the screen below its top, with room for the tabs
		-- that hang under it (the large size ran off the bottom, measured)
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
	function frame.CycleDefaultSize()
		local index = ((WowCompanionDB.windowSize or 2) % #SIZES) + 1
		WowCompanionDB.windowSize = index
		applySize(index)
		return frame.SIZE_NAMES[index]
	end
	applySize(WowCompanionDB.windowSize or 2)

	buildTabs(frame, messages, pending)
	return frame
end


WC.Window = WC.Window or {}
WC.Window.buildLog = buildLog
