-- Links other players post in chat (WC module). Item links go to
-- WowCompanionDB.links (20, newest first), profession links to
-- WowCompanionDB.tradeLinks (10): chat history is wiped at every reload, so
-- they are kept here. Sends LINK_CAUGHT(entry) and TRADE_LINK_CAUGHT(entry).
local M = WC.Module('LinkCatcher')
local EVENTS = { 'CHAT_MSG_GUILD', 'CHAT_MSG_OFFICER', 'CHAT_MSG_PARTY', 'CHAT_MSG_PARTY_LEADER', 'CHAT_MSG_RAID', 'CHAT_MSG_RAID_LEADER', 'CHAT_MSG_INSTANCE_CHAT', 'CHAT_MSG_SAY', 'CHAT_MSG_YELL', 'CHAT_MSG_WHISPER', 'CHAT_MSG_BN_WHISPER', 'CHAT_MSG_CHANNEL' }

local function heard(event, text, sender)
  if type(text) ~= 'string' then return end
  local where = event:gsub('CHAT_MSG_', ''):lower()
  for link in text:gmatch('(|c[^|]*|Hitem:[^|]+|h%[[^%]]+%]|h|r)') do
    local list = WowCompanionDB.links
    local entry = { link = link, from = tostring(sender or '?'), where = where, at = time() }
    table.insert(list, 1, entry)
    while #list > 20 do table.remove(list) end
    WC.Send('LINK_CAUGHT', entry)
  end
  for full, data, label in text:gmatch('(|H(trade:[^|]+)|h(%[[^%]]+%])|h)') do
    local list = WowCompanionDB.tradeLinks
    local entry = { data = data, full = full, label = label, from = tostring(sender or '?'), where = where, at = time() }
    table.insert(list, 1, entry)
    while #list > 10 do table.remove(list) end
    WC.Send('TRADE_LINK_CAUGHT', entry)
  end
end

function M:Enable()
  WowCompanionDB.links = WowCompanionDB.links or {}
  WowCompanionDB.tradeLinks = WowCompanionDB.tradeLinks or {}
  -- the frame the pre-engine version used, if this session still has it
  if WCLinkCatcherFrame then WCLinkCatcherFrame:UnregisterAllEvents() end
  for _, e in ipairs(EVENTS) do self:Event(e, heard) end
end

function WCShowLink(n)
  if WowCompanion_ShowItem then return WowCompanion_ShowItem(n or 1) end
  print('item viewer not loaded yet: reload')
end

-- opens the newest caught profession link as a chat click would; pressed by the player
function WCOpenTradeLink(n)
  local t = WowCompanionDB.tradeLinks and WowCompanionDB.tradeLinks[n or 1]
  if not t then print('no profession link caught yet: ask them to link it again') return end
  print(('opening %s from %s (%s)'):format(t.label, t.from, t.where))
  local ok, err = pcall(SetItemRef, t.data, t.full, 'LeftButton', ChatFrame1)
  C_Timer.After(0.5, function()
    local s = ('trade open: %s from %s ok=%s err=%s tooltip=%s profLoaded=%s profWindow=%s'):format(t.label, t.from, tostring(ok), tostring(err), tostring(ItemRefTooltip and ItemRefTooltip:IsShown()), tostring(C_AddOns.IsAddOnLoaded('Blizzard_Professions')), tostring(ProfessionsFrame and ProfessionsFrame:IsShown()))
    if WowCompanion_Strip then WowCompanion_Strip.Send(s .. '\nraw: ' .. t.full:gsub('|', '!'), 30) end
  end)
end
