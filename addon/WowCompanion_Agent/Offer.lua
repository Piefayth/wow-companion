-- WowCompanion_Agent: the offered button, one per conversation.
-- What this needs from Agent.lua comes through WC.Companion; what it
-- offers, the other files reach through WC.Offer: Show(slot) when the view changes, Waiting() (its
-- label while a press waits, else nil), BUTTON (its name, for a binding).

-- One offered button per conversation (the player, 2026-11-10): a Reload from
-- one agent replaced the Quit another had just offered. Each keeps its own; the
-- one secure button shows the offer of the conversation in view.
local BUTTON = "WowCompanionDo"
local offers = {}
local actionButton
local logFrame = WC.Companion.window
local remember = WC.Companion.remember
local function toast(...) return WC.Board.toast(...) end
local function viewSlot() return WowCompanion_ViewSlot() end

-- A button in the Companion window, retargeted on demand.
--
-- Protected calls are refused from insecure code, but a hardware button press is
-- trusted -- so for anything we cannot do ourselves, we put a button in front of the
-- player and they press it. It lives inside the window rather than on an action bar
-- so the gamepad cursor has a normal piece of UI to land on, and because it costs no
-- binding and no bar slot.
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
		-- at the foot of the conversation list, the list's width, under its
		-- buttons (the player, 2026-11-10): it belongs to the conversation in view
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
		-- Measured, one variable at a time. "AnyUp": the wrapper runs -- PreClick and
		-- PostClick both fire -- and the macro does not, which reads exactly like a
		-- permissions refusal and is not one. Both edges: runs, but twice, once down
		-- and once up. "AnyDown" alone: runs once. That is the answer.
		--
		-- Attributes are still set first, which is cheap and conventional, but the
		-- edge is what decides whether the macro fires at all.
		actionButton:SetAttribute("type", "macro")
		actionButton:RegisterForClicks("AnyDown")

		-- the cursor can land on it, and goes to it when the window takes focus
		WC.MarkFocusable(actionButton)
		WC.SetFocusButton(frame, actionButton)
		actionButton:SetScript("PostClick", function(self)
			if self.slot then offers[self.slot] = nil end
			self:Hide()
		end)
	end
	return frame
end

-- Put the view's offer on the button, or take the button away when it has none.
-- Secure attributes cannot change in combat; the button then stays as it was
-- until the next switch.
local function showOffer(slot)
	if InCombatLockdown() then return "in combat" end
	local held = offers[slot]
	if not held then
		if actionButton then
			actionButton.slot = nil
			actionButton:Hide()
		end
		return "nothing"
	end
	local label, macro = held.label, held.macro
	buildActionButton()
	if not actionButton then return "nothing" end
	actionButton.slot = slot
	actionButton:SetAttribute("macrotext", macro)
	actionButton:SetText(label)
	actionButton:Show()
	-- the cursor reaches it, and L3 presses it while the window has focus
	-- (Jobs.lua); nothing else is bound to it
	return "shown"
end

local function offer(label, macro, slot)
	-- attributes on a secure frame cannot be set in combat, and this is
	-- configuration anyway
	if InCombatLockdown() then
		return "refused: in combat"
	end
	slot = slot or WC.Link.Current() or viewSlot()
	offers[slot] = { label = label, macro = macro }
	local where = WC.Conversations.Label(slot)
	if slot ~= viewSlot() then
		-- the view never jumps on its own: the button waits in its conversation
		remember("claude", ("button |cffffffff%s|r runs |cff9ad5ff%s|r — it waits in this conversation")
			:format(label, macro), nil, slot)
		toast(("|cffffd100%s|r  has a button for you: |cffffffff%s|r (open %s)"):format(where, label, where),
			0.8, 0.8, 0.8, 30)
		return ("offering %q in %s, not in view"):format(label, where)
	end
	local bound = showOffer(slot)
	-- show the macro, not just the label: the player is the one authorising this, and
	-- "Do it" tells them nothing about what they would be running
	remember("claude", ("button |cffffffff%s|r runs |cff9ad5ff%s|r — it is in the window")
		:format(label, macro), nil, slot)
	toast(("|cffffd100Claude|r  a button in the window: |cffffffff%s|r"):format(label), 0.8, 0.8, 0.8, 30)
	return ("offering %q which runs %q, bound to %s"):format(label, macro, bound)
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
	-- the label of the offer in view while it waits for a press, or nil
	Waiting = function()
		return actionButton and actionButton:IsVisible() and actionButton.slot ~= nil and actionButton:GetText() or nil
	end,
}
