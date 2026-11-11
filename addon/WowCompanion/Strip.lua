-- Part of WowCompanion; loaded by the .toc in order: Engine, Style, Companion,
-- Pins, Strip, Bags, Status, Modules. A file shares nothing local with another:
-- they talk through globals (WC, WowCompanion_*, WCPins, WCBags).

-- The data strip: game-to-PC without a reload. Bytes
-- drawn as solid colour cells, three bytes a cell, in the very bottom-right
-- corner, shown only for a moment and then gone; the PC screenshots that corner
-- and decodes it (src/strip.rs). Pixel-exact: the frame ignores the UI scale
-- and is scaled so one unit is one screen pixel.
--   cell 0, 1: magic C0FFEE, 123456   cell 2: byte length
--   cell 3: sum of bytes, cell 4: sum of running sums (both mod 2^24)
--   cell 5 on: the bytes, 3 per cell, zero padded
-- Cells fill left to right along the bottom row, then rows upward.
WowCompanion_Strip = WowCompanion_Strip or {}
do
	local CELL, COLS = 4, 256
	local frame, pool, hideTimer
	local function build()
		frame = CreateFrame("Frame", "WowCompanionStrip", UIParent)
		frame:SetIgnoreParentScale(true)
		frame:SetFrameStrata("TOOLTIP")
		frame:SetFrameLevel(9999)
		frame:Hide()
		pool = {}
	end
	local function place()
		local _, h = GetPhysicalScreenSize()
		frame:SetScale(768 / h)
		frame:ClearAllPoints()
		frame:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", 0, 0)
	end
	local function cell(i, r, g, b)
		local t = pool[i]
		if not t then
			t = frame:CreateTexture(nil, "OVERLAY")
			t:SetSize(CELL, CELL)
			pool[i] = t
		end
		local col, row = i % COLS, math.floor(i / COLS)
		t:ClearAllPoints()
		t:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", col * CELL, row * CELL)
		t:SetColorTexture(r / 255, g / 255, b / 255, 1)
		t:Show()
	end
	local function triple(v)
		return math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256
	end
	-- text: the payload (any bytes); seconds: how long to stay (default 3)
	function WowCompanion_Strip.Send(text, seconds)
		text = tostring(text or "")
		if not frame then build() end
		place()
		local n = #text
		local a, b = 0, 0
		for i = 1, n do
			a = (a + text:byte(i)) % 16777216
			b = (b + a) % 16777216
		end
		local cells = 5 + math.ceil(n / 3)
		local rows = math.ceil(cells / COLS)
		frame:SetSize(COLS * CELL, rows * CELL)
		cell(0, 0xC0, 0xFF, 0xEE)
		cell(1, 0x12, 0x34, 0x56)
		cell(2, triple(n))
		cell(3, triple(a))
		cell(4, triple(b))
		for k = 0, math.ceil(n / 3) - 1 do
			local p = k * 3
			cell(5 + k, text:byte(p + 1) or 0, text:byte(p + 2) or 0, text:byte(p + 3) or 0)
		end
		for i = cells, #pool do pool[i]:Hide() end
		-- unused cells of the last row stay black, which decodes as padding
		for i = cells, rows * COLS - 1 do cell(i, 0, 0, 0) end
		frame:Show()
		if hideTimer then hideTimer:Cancel() end
		hideTimer = C_Timer.NewTimer(seconds or 3, function() frame:Hide() end)
		return n
	end
	function WowCompanion_Strip.Hide()
		if frame then frame:Hide() end
	end
end
