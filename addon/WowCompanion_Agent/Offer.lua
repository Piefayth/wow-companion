-- WowCompanion_Agent: the offered button.
-- What this needs from Agent.lua comes through WC.Companion; what it offers,
-- the other files reach through WC.Offer: Show() to redraw it, Next() to step
-- to the next offer, Waiting() (its label while a press waits, else nil),
-- Count() (offers waiting), BUTTON (its name, for a binding).

-- Every conversation's offers wait in one list, newest first, so one agent's
-- offer never replaces another's and any of them can be pressed from whichever
-- conversation is in view. The one secure button shows the picked offer,
-- labelled with its conversation; R3 steps to the next (Jobs.lua binds L3 and
-- R3 while the window has focus).
local BUTTON = "WowCompanionDo"
local offers = {} -- { slot, label, macro }, newest first
local picked = 1
local actionButton
local showOffer
local logFrame = WC.Companion.window
local remember = WC.Companion.remember
local function toast(...) return WC.Board.toast(...) end

-- A button in the Companion window, retargeted on demand.
--
-- Protected calls are refused from insecure code, but a hardware button press is
-- trusted -- so for anything we cannot do ourselves, we put a button in front of the
-- player and they press it. It lives inside the window rather than on an action bar
-- so the gamepad cursor has a normal piece of UI to land on, and because it costs no
-- bar slot.
--
-- SecureActionButtonTemplate for the secure path, UIPanelButtonTemplate so it looks
-- like the game's own. Macro text is the limit of what it can do, which is also the
-- limit of what the player could type -- it grants no power they lacked.
local function buildActionButton()
	local frame = logFrame()
	if not actionButton then
		local made, button = pcall(CreateFrame, "Button", BUTTON, frame,
			"SecureActionButtonTemplate, UIPanelButtonTemplate")
		if not made or not button then
			return "could not build the button: " .. tostring(button)
		end
		actionButton = button
		-- at the foot of the conversation list, the list's width, under its buttons
		local function place(b)
			b:SetParent(frame)
			b:ClearAllPoints()
			local last = frame.convButtons and (frame.convButtons.quick or frame.convButtons.r2)
			if last then
				b:SetSize(last:GetWidth(), 24)
				b:SetPoint("TOP", last, "BOTTOM", 0, -10)
				b:SetFrameLevel(last:GetFrameLevel() + 2)
			else
				b:SetSize(150, 22)
				b:SetPoint("BOTTOMRIGHT", -18, 8)
			end
		end
		place(actionButton)
		WC.Companion.stow(actionButton, place)
		-- "AnyDown" alone runs the macro once ("AnyUp" fires PreClick and
		-- PostClick but not the macro; both edges run it twice).
		actionButton:SetAttribute("type", "macro")
		actionButton:RegisterForClicks("AnyDown")

		-- the cursor can land on it, and goes to it when the window takes focus
		WC.MarkFocusable(actionButton)
		WC.SetFocusButton(frame, actionButton)
		-- a pressed offer is done: the next one takes its place
		actionButton:SetScript("PostClick", function(self)
			if self.offer then
				for i, o in ipairs(offers) do
					if o == self.offer then table.remove(offers, i) break end
				end
			end
			self.offer = nil
			WC.AfterCombat(showOffer)
		end)
		-- it belongs to the Chat tab: another tab takes it away, Chat brings it back
		if frame.SelectTab then hooksecurefunc(frame, "SelectTab", function() showOffer() end) end
	end
	return frame
end

-- Put the picked offer on the button, or take the button away when none waits
-- or another tab than Chat is up. Secure attributes cannot change in combat; the
-- button then stays as it was until the fight ends.
showOffer = function()
	if InCombatLockdown() then return "in combat" end
	if picked > #offers then picked = 1 end
	local held = offers[picked]
	local frame = logFrame()
	if not held or (frame and (frame.currentTab or 1) ~= 1) then
		if actionButton then
			actionButton.offer = nil
			actionButton:Hide()
		end
		return "nothing"
	end
	buildActionButton()
	if not actionButton then return "nothing" end
	actionButton.offer = held
	actionButton:SetAttribute("macrotext", held.macro)
	actionButton:SetText(WC.Conversations.Label(held.slot) .. ": " .. held.label)
	actionButton:Show()
	return "shown"
end

local function offer(label, macro, slot)
	-- attributes on a secure frame cannot be set in combat, and this is
	-- configuration anyway
	if InCombatLockdown() then
		return "refused: in combat"
	end
	slot = slot or WC.Link.Current() or WowCompanion_ViewSlot()
	table.insert(offers, 1, { slot = slot, label = label, macro = macro })
	picked = 1
	local bound = showOffer()
	-- show the macro, not just the label: the player is the one authorising this, and
	-- "Do it" tells them nothing about what they would be running
	remember("claude", ("button |cffffffff%s|r runs |cff9ad5ff%s|r — it is in the window")
		:format(label, macro), nil, slot)
	toast(("|cffffd100%s|r  a button in the window: |cffffffff%s|r")
		:format(WC.Conversations.Label(slot), label), 0.8, 0.8, 0.8, 30)
	return ("offering %q which runs %q, %s"):format(label, macro, bound)
end

-- A reload clears taint, flushes SavedVariables and resets the slot cursor. We
-- cannot do it ourselves: ReloadUI wraps a protected call, and asking from insecure
-- code comes back as "WowCompanion called Reload()".
--
-- A real button press is a hardware event, and that is the one path the client
-- trusts. So build a secure button on the fly, point it at a macro, and let the
-- player press it: the click runs through the secure path, taints nothing, and is
-- never blocked. Anything expressible as a macro can go through here.
local handlers = {}
function handlers.reload(inbox)
	return offer("Reload UI", "/reload", inbox and inbox.slot)
end

-- Whatever the helper asks for, as a button the player presses. The macro text is
-- the limit of what this can do, which is also the limit of what the player could
-- type themselves -- so it grants no power they did not already have.
function handlers.press(inbox)
	return offer(inbox.label or "Do it", inbox.macro or "", inbox.slot)
end
for kind, fn in pairs(handlers) do WC.Link.Handle(kind, fn) end

WC.Offer = {
	BUTTON = BUTTON,
	Show = showOffer,
	-- the next offer on the button (out of combat: its attributes are locked in one)
	Next = function()
		if InCombatLockdown() or #offers < 2 then return end
		picked = picked % #offers + 1
		showOffer()
	end,
	Count = function() return #offers end,
	-- the label of the offer on the button while it waits for a press, or nil
	Waiting = function()
		return actionButton and actionButton:IsVisible() and actionButton.offer and actionButton:GetText() or nil
	end,
}
