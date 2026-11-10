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

-- opens a caught profession link as a chat click would; pressed by the player.
-- n: 1 = newest, or a name to match against who linked it or the profession
-- ("Orihime", "Enchanting"), newest match first, so one press needs no lookup.
function WCOpenTradeLink(n)
  local list = WowCompanionDB.tradeLinks or {}
  local t
  if type(n) == 'string' then
    local want = n:lower()
    for _, e in ipairs(list) do
      if (e.from or ''):lower():find(want, 1, true) or (e.label or ''):lower():find(want, 1, true) then t = e break end
    end
    if not t then
      print(('no profession link from or for "%s" caught (have %d): ask them to link it again'):format(n, #list))
      for i, e in ipairs(list) do print(('  %d: %s from %s'):format(i, e.label, e.from)) end
      return
    end
  else
    t = list[n or 1]
  end
  if not t then print('no profession link caught yet: ask them to link it again') return end
  print(('opening %s from %s (%s)'):format(t.label, t.from, t.where))
  local ok, err = pcall(SetItemRef, t.data, t.full, 'LeftButton', ChatFrame1)
  if not ok then print('could not open it: ' .. tostring(err)) end
end
