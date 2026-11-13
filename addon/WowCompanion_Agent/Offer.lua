-- WowCompanion_Agent: the offered button.
-- What this needs from Agent.lua comes through WC.Companion; what it offers,
-- the other files reach through WC.Offer: Show() to redraw it for the
-- conversation in view, Waiting() (its label while a press waits, else nil),
-- BUTTON (its name, for L3's binding in Jobs.lua).

-- One offer per conversation, so one agent's offer never replaces another's;
-- the one secure button shows the offer of the conversation in view. The
-- conversation is picked with its own chord and R3 (Jobs.lua), L3 presses.
-- A secure button's action is written out of combat only: an offer that comes
-- in a fight waits for its end, and in a fight the button keeps the offer it had
-- (its label then names the conversation it belongs to).
local BUTTON = "WowCompanionDo"
local offers = {} -- [slot] = { label, macro, left }; saved at login (below)
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
		-- a press uses one of the offer's presses; the last one ends it (left
		-- 0: it lasts until the next offer replaces it)
		actionButton:SetScript("PostClick", function(self)
			local held = self.slot and offers[self.slot]
			if held and held.left ~= 0 then
				held.left = (held.left or 1) - 1
				if held.left <= 0 then
					offers[self.slot] = nil
					self.slot = nil
				end
			end
			WC.AfterCombat(showOffer)
		end)
	end
	return frame
end

-- an offer's label, with the presses it has left when more than one
local function labelOf(held)
	local left = held.left or 1
	return left > 1 and ("%s  x%d"):format(held.label, left) or held.label
end

-- The view's offer on the button, or the button away when it has none or
-- another tab than Chat is up. In a fight only the label follows the view.
showOffer = function()
	local view = WowCompanion_ViewSlot()
	local frame = logFrame()
	if InCombatLockdown() then
		if actionButton and actionButton.slot and offers[actionButton.slot] then
			local held = offers[actionButton.slot]
			actionButton:SetText(actionButton.slot == view and labelOf(held)
				or (WC.Conversations.Label(actionButton.slot) .. ": " .. labelOf(held)))
		end
		return "in combat"
	end
	-- it belongs to the Chat tab: another tab takes it away, Chat brings it back
	-- (followed from the first call, so an offer that came on another tab shows)
	if frame and frame.SelectTab and not frame.offerFollowsTabs then
		frame.offerFollowsTabs = true
		hooksecurefunc(frame, "SelectTab", function() showOffer() end)
	end
	local held = offers[view]
	if not held or (frame and (frame.currentTab or 1) ~= 1) then
		if actionButton then
			actionButton.slot = nil
			actionButton:Hide()
		end
		return "nothing"
	end
	buildActionButton()
	if not actionButton then return "nothing" end
	actionButton.slot = view
	actionButton:SetAttribute("macrotext", held.macro)
	actionButton:SetText(labelOf(held))
	actionButton:Show()
	return "shown"
end

-- times: the presses it lasts (1 when not given), 0 until the next offer
local offer
offer = function(label, macro, slot, times)
	slot = slot or WC.Link.Current() or WowCompanion_ViewSlot()
	-- attributes on a secure frame cannot be set in combat: an offer that comes
	-- in a fight waits for its end
	if InCombatLockdown() then
		WC.AfterCombat(function() offer(label, macro, slot, times) end)
		return "waiting for the fight to end"
	end
	offers[slot] = { label = label, macro = macro, left = tonumber(times) or 1 }
	local bound = showOffer()
	-- show the macro, not just the label: the player is the one authorising this, and
	-- "Do it" tells them nothing about what they would be running
	remember("claude", ("button |cffffffff%s|r runs |cff9ad5ff%s|r — it is in the window")
		:format(label, macro), nil, slot)
	toast(("|cffffd100%s|r  has a button for you: |cffffffff%s|r")
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
	return offer(inbox.label or "Do it", inbox.macro or "", inbox.slot, inbox.times)
end
for kind, fn in pairs(handlers) do WC.Link.Handle(kind, fn) end

-- Waiting offers outlive a reload: they are kept in the saved table. A reload
-- offer is done by the reload that just happened, whoever offered it.
local login = CreateFrame("Frame")
login:RegisterEvent("PLAYER_LOGIN")
login:SetScript("OnEvent", function()
	local saved = type(WowCompanionAgentDB.offers) == "table" and WowCompanionAgentDB.offers or {}
	for slot, o in pairs(saved) do
		if type(slot) == "string" and type(o) == "table" and o.macro and o.macro ~= "/reload"
			and not offers[slot] then
			offers[slot] = o
		end
	end
	WowCompanionAgentDB.offers = offers
	WC.AfterCombat(showOffer)
end)

-- R3 with a conversation's chord held picks that conversation, as minus does
-- to talk to it; R3 alone is Main. From any tab: it brings up Chat (Jobs.lua
-- binds it while the window has focus)
local pick = CreateFrame("Button", "WCConversationPick", UIParent)
pick:SetScript("OnClick", function()
	local slot = WowCompanion_PadSlot()
	for _, known in ipairs(WC.Conversations.list) do
		if known == slot then
			local frame = logFrame()
			if frame and frame.SelectTab and (frame.currentTab or 1) ~= 1 then frame.SelectTab(1) end
			WowCompanion_SetConversation(slot)
			return
		end
	end
end)

WC.Offer = {
	BUTTON = BUTTON,
	PICK = "WCConversationPick",
	Show = showOffer,
	-- the label of the offer on the button while it waits for a press, or nil
	Waiting = function()
		return actionButton and actionButton:IsVisible() and actionButton.slot and actionButton:GetText() or nil
	end,
}
