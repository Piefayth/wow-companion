-- Bags, the same in and out of combat: Blizzard's bag frame opens ours, by the same secure path in a fight
-- or out of one. A secure handler of ours is a child of their combined bags, so
-- whatever shows theirs (the bag radial, a vendor, the mailbox) shows it, and its
-- _onshow runs in the restricted environment: it shows our pad's handler (which
-- binds the pad and opens our window) and hides their frame at once. Their frame
-- counts as protected while it holds our protected child, which is what lets the
-- restricted code hide it in combat; hiding it there is secure, so the
-- controller's focus manager lets it go cleanly. Nothing of theirs is written:
-- no alpha, no FrameHidden, no hooks on their toggles.
do
	local done
	local function setup()
	local blizz = ContainerFrameCombinedBags
	local pad = WCBags and WCBags.pad
	if done or InCombatLockdown() then return end
	if blizz and pad then
		done = true
		local trigger = CreateFrame("Frame", "WCBagsTrigger", blizz, "SecureHandlerShowHideTemplate")
		trigger:SetSize(1, 1)
		trigger:SetPoint("TOPLEFT")
		trigger:SetFrameRef("pad", pad)
		trigger:SetFrameRef("bags", blizz)
		-- always opens: a vendor opening their bags while ours is up must not
		-- close ours (circle closes)
		trigger:SetAttribute("_onshow", [[
			local pad = self:GetFrameRef("pad")
			if not pad:IsShown() then pad:Show() end
			self:GetFrameRef("bags"):Hide(true)
		]])
		-- a vendor, mailbox or bank closing: Blizzard closes its bags then; ours
		-- follows (out of combat; in one, circle closes)
		local w = CreateFrame("Frame")
		for _, e in ipairs({ "MERCHANT_CLOSED", "MAIL_CLOSED", "BANKFRAME_CLOSED", "TRADE_CLOSED", "AUCTION_HOUSE_CLOSED" }) do
			pcall(w.RegisterEvent, w, e)
		end
		w:SetScript("OnEvent", function() if WCBags then WCBags:Shut() end end)
	end
	end
	setup()
	-- the bag window builds after a fight when the UI loaded in one
	local later = CreateFrame("Frame")
	later:RegisterEvent("PLAYER_REGEN_ENABLED")
	later:SetScript("OnEvent", function(self) setup() if done then self:UnregisterAllEvents() end end)
end

-- square sells while a vendor is open, so the legend says so
do
	local w = CreateFrame("Frame")
	w:RegisterEvent("MERCHANT_SHOW")
	w:RegisterEvent("MERCHANT_CLOSED")
	w:SetScript("OnEvent", function(_, event)
		local pr = WCBags and WCBags.usePrompt
		if not (pr and pr.SetPromptText) then return end
		pcall(pr.SetPromptText, pr, event == "MERCHANT_SHOW" and (SELL or "Sell") or (USE or "Use"))
		if pr.RefreshInputPromptSize then pcall(pr.RefreshInputPromptSize, pr) end
	end)
end
