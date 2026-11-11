-- What this file needs from Companion.lua comes
-- through its named functions (WC.Companion.<verb>); what Companion.lua calls here is WC.Board.


-- A one-line notice at the top of the screen, instead of opening the window:
-- the window only opens when the player asks for it (a minus tap, /wc log).
-- It cannot take the mouse or the gamepad focus, so it never gets in the way,
-- and it shows in combat too.
local toastFrame, toastTimer
-- Styled like the game's own tooltips: tooltip background and border, a gold
-- title over a thin divider, then one aligned row per conversation with the
-- ready-check mark for its state. A plain notice is one wrapped string instead.
local TOAST_W, ROW_H, PAD = 420, 16, 10
-- Top left, just right of the gamepad's controls legend
-- (GamepadPersistentInputLegend, Blizzard's, anchored TOPLEFT 5,-5), or in the
-- top-left corner when the legend is off (the bottom right is where tooltips
-- go). Re-placed at every show, so turning the legend
-- on or off is followed. Only our frame is anchored: the legend is read, never
-- changed.
local function placeToast(frame)
	frame:ClearAllPoints()
	-- the legend frame itself is 10x10; its size is in its children, one
	-- background per group of prompts, shown or hidden by Blizzard. The board
	-- goes right of the widest one showing (anchored to the 10x10 frame, the
	-- board lies over the legend).
	local legend = GamepadPersistentInputLegend
	local right, top
	if legend and legend:IsVisible() then
		local k = legend:GetEffectiveScale() / UIParent:GetEffectiveScale()
		for _, child in ipairs({ legend:GetChildren() }) do
			if child:IsVisible() and child:GetRight() and child:GetWidth() > 12 then
				right = math.max(right or 0, child:GetRight() * k)
				top = math.max(top or 0, child:GetTop() * k)
			end
		end
	end
	if right then
		frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", right + 6, top)
	else
		frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 4, -4)
	end
	frame:SetWidth(TOAST_W)
end
local function toastRoom() return 2 * 10 + 20 + 5 * 16 end
local function buildToast()
	local made, frame = pcall(CreateFrame, "Frame", nil, UIParent, "BackdropTemplate")
	frame = made and frame or CreateFrame("Frame", nil, UIParent)
	frame:SetSize(TOAST_W, 34)
	placeToast(frame)
	frame:SetFrameStrata("HIGH")
	frame:EnableMouse(false)
	if frame.SetBackdrop then
		-- the game's own dialog border: the gold-trimmed frame of its popups
		frame:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			tile = true, tileSize = 16, edgeSize = 24,
			insets = { left = 6, right = 6, top = 6, bottom = 6 },
		})
		frame:SetBackdropColor(0.06, 0.06, 0.1, 0.92)
		frame:SetBackdropBorderColor(1, 1, 1, 1)
	end
	-- a notice: one string that fills the frame and wraps (a non-wrapping one
	-- anchored only left and right draws its first line alone)
	frame.text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	frame.text:SetPoint("TOPLEFT", PAD + 2, -PAD)
	frame.text:SetPoint("BOTTOMRIGHT", -PAD - 2, PAD)
	frame.text:SetJustifyH("LEFT")
	frame.text:SetJustifyV("MIDDLE")
	frame.text:SetWordWrap(true)
	frame.text:SetMaxLines(8)
	frame.text:SetSpacing(3)
	-- the board: a title, a hint, a divider, then rows made as needed
	frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	frame.title:SetPoint("TOPLEFT", PAD + 4, -PAD)
	frame.title:SetText("Companion")
	frame.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	frame.hint:SetPoint("TOPRIGHT", -PAD - 4, -PAD - 1)
	frame.hint:SetText(("tap %s to read"):format(WowCompanion_Glyph(WowCompanion_TalkKey)))
	frame.rule = frame:CreateTexture(nil, "ARTWORK")
	frame.rule:SetColorTexture(1, 0.82, 0, 0.35)
	frame.rule:SetHeight(1)
	frame.rule:SetPoint("TOPLEFT", PAD, -PAD - 17)
	frame.rule:SetPoint("TOPRIGHT", -PAD, -PAD - 17)
	frame.rows = {}
	return frame
end

-- each state's mark: Blizzard's ready-check atlases, a coloured square if missing
local MARKS = { hearing = "UI-LFG-PendingMark", working = "UI-LFG-PendingMark",
	replied = "UI-LFG-ReadyMark", problem = "UI-LFG-DeclineMark" }
local function setMark(tex, state, r, g, b)
	local atlas = MARKS[state]
	local known = atlas and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas)
	if known then
		tex:SetAtlas(atlas)
		if state == "hearing" then tex:SetVertexColor(0.6, 0.85, 1) else tex:SetVertexColor(1, 1, 1) end
	else
		tex:SetColorTexture(r, g, b, 1)
	end
end

local function showRow(row, on)
	row.mark:SetShown(on) row.name:SetShown(on) row.state:SetShown(on) row.detail:SetShown(on)
end

local function toastRow(frame, i)
	local row = frame.rows[i]
	if row then return row end
	row = {}
	row.mark = frame:CreateTexture(nil, "OVERLAY")
	row.mark:SetSize(14, 14)
	row.name = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.name:SetWidth(40)
	row.name:SetJustifyH("LEFT")
	row.name:SetPoint("LEFT", row.mark, "RIGHT", 6, 0)
	row.state = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.state:SetWidth(84)
	row.state:SetJustifyH("LEFT")
	row.state:SetPoint("LEFT", row.name, "RIGHT", 2, 0)
	row.detail = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.detail:SetJustifyH("LEFT")
	row.detail:SetWordWrap(false)
	row.detail:SetPoint("LEFT", row.state, "RIGHT", 4, 0)
	row.detail:SetPoint("RIGHT", frame, "RIGHT", -PAD - 2, 0)
	frame.rows[i] = row
	return row
end

local function boardMode(frame, on)
	frame.title:SetShown(on)
	frame.hint:SetShown(on)
	frame.rule:SetShown(on)
	frame.text:SetShown(not on)
	if not on then
		for _, row in ipairs(frame.rows) do showRow(row, false) end
	end
end

local function toast(text, r, g, b, hold)
	toastFrame = toastFrame or buildToast()
	if not text then
		toastFrame:Hide()
		return
	end
	placeToast(toastFrame)
	boardMode(toastFrame, false)
	toastFrame.text:SetText(text)
	local rows = select(2, text:gsub("\n", "")) + 1
	toastFrame:SetHeight(2 * PAD + rows * 15 + (rows - 1) * 3)
	toastFrame.text:SetTextColor(r or 1, g or 1, b or 1)
	toastFrame:Show()
	if toastTimer then toastTimer:Cancel() end
	toastTimer = nil
	if hold then
		toastTimer = C_Timer.NewTimer(hold, function() toastFrame:Hide() end)
	end
end

-- The agents at work: rows = { { label, state, detail, r, g, b }, ... }
-- for the other files (Style.lua's destroy dialog)
function WC.Toast(...) return toast(...) end

local function toastBoard(rows)
	toastFrame = toastFrame or buildToast()
	placeToast(toastFrame)
	boardMode(toastFrame, true)
	for i, item in ipairs(rows) do
		local row = toastRow(toastFrame, i)
		local label, state, detail, r, g, b = unpack(item)
		setMark(row.mark, state:match("^%a+"), r, g, b)
		row.name:SetText(label)
		row.name:SetTextColor(r, g, b)
		row.state:SetText(state)
		row.state:SetTextColor(r, g, b)
		row.detail:SetText(detail or "")
		showRow(row, true)
	end
	for i = #rows + 1, #toastFrame.rows do showRow(toastFrame.rows[i], false) end
	-- fit under the chat: the title only when there is room, then as many
	-- rows as fit (the newest conversations are last; the first ones stay)
	local room = toastRoom()
	local header = (2 * PAD + 20 + #rows * ROW_H <= room) and 20 or 0
	local fit = math.max(1, math.floor((room - 2 * PAD - header) / ROW_H))
	toastFrame.title:SetShown(header > 0)
	toastFrame.hint:SetShown(header > 0)
	toastFrame.rule:SetShown(header > 0)
	for i, row in ipairs(toastFrame.rows) do
		row.mark:ClearAllPoints()
		row.mark:SetPoint("TOPLEFT", PAD + 4, -PAD - header - 1 - (i - 1) * ROW_H)
		if i > fit then showRow(row, false) end
	end
	toastFrame:SetHeight(2 * PAD + header + math.min(#rows, fit) * ROW_H)
	if toastTimer then toastTimer:Cancel() end
	toastTimer = nil
	toastFrame:Show()
end

-- a notice still up with no timer to take it down
local function toastIdleShown() return toastFrame and toastFrame:IsShown() and not toastTimer end


WC.Board = WC.Board or {}
WC.Board.toast = toast
WC.Board.toastBoard = toastBoard
WC.Board.toastIdleShown = toastIdleShown
