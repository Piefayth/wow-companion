-- The Companion button: one button for everything of ours, so a player spends
-- one binding. A tap asks each answer in order (WC.Tap.Answer(order, fn), lower
-- first; fn returns true when the tap was its): the Agent closes its open
-- window (10), the Wheel places the thing under the controller's cursor (20),
-- the Agent opens its window (30). With no answer the settings window opens or
-- closes. With the companion (Link) the talk button's tap is this button;
-- without it, a WoW binding (Bindings.xml) set on the settings page.

WC.Tap = {}
local answers = {}

function WC.Tap.Answer(order, fn)
	answers[#answers + 1] = { order = order, fn = fn }
	table.sort(answers, function(a, b) return a.order < b.order end)
end

function WC.Tap.Fire()
	for _, answer in ipairs(answers) do
		local ok, mine = pcall(answer.fn)
		if not ok then WC.Say("Companion button: " .. tostring(mine)) end
		if ok and mine then return end
	end
	WC.SettingsPage.Toggle()
end

BINDING_NAME_WCCOMPANION_TAP = "Companion button"

-- its row, only without the companion: with it, the talk button is this button
-- (its own row, Link's)
local login = CreateFrame("Frame")
login:RegisterEvent("PLAYER_LOGIN")
login:SetScript("OnEvent", function()
	if WC.Link then return end
	WC.SettingsPage.BindingRow({
		action = "WCCOMPANION_TAP", section = "Companion button", order = 5, label = "Companion button",
		what = "Tapped on a spell, item or macro, puts it on a wheel; anywhere else, opens these settings.",
	})
end)
