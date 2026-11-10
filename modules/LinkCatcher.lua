-- Links other players post in chat (WC module). Item links go to
-- WowCompanionDB.links (20, newest first), profession links to
-- WowCompanionDB.tradeLinks (10): chat history is wiped at every reload, so
-- they are kept here. Sends LINK_CAUGHT(entry) and TRADE_LINK_CAUGHT(entry).
local M = WC.Module('LinkCatcher')
local EVENTS = { 'CHAT_MSG_GUILD', 'CHAT_MSG_OFFICER', 'CHAT_MSG_PARTY', 'CHAT_MSG_PARTY_LEADER', 'CHAT_MSG_RAID', 'CHAT_MSG_RAID_LEADER', 'CHAT_MSG_INSTANCE_CHAT', 'CHAT_MSG_SAY', 'CHAT_MSG_YELL', 'CHAT_MSG_WHISPER', 'CHAT_MSG_BN_WHISPER', 'CHAT_MSG_CHANNEL' }

-- recent chat, this session only, for the agent's live look (WCChatStrip)
WCRecentChat = WCRecentChat or {}

local function heard(event, text, sender, _, channelName)
  if type(text) ~= 'string' then return end
  local where = event:gsub('CHAT_MSG_', ''):lower()
  if where == 'channel' and type(channelName) == 'string' and channelName ~= '' then where = channelName end
  local plainText = text:gsub('|c%x%x%x%x%x%x%x%x', ''):gsub('|r', ''):gsub('|H[^|]*|h(.-)|h', '%1')
  table.insert(WCRecentChat, 1, ('%s [%s] %s: %s'):format(date('%H:%M'), where, tostring(sender or '?'), plainText:sub(1, 200)))
  while #WCRecentChat > 40 do table.remove(WCRecentChat) end
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
-- ("Orihime", "Enchanting"), newest match first, so one press needs no lookup;
-- or a function(entry) returning true for the one wanted.
function WCOpenTradeLink(n)
  local list = WowCompanionDB.tradeLinks or {}
  local t
  if type(n) == 'function' then
    -- the agent's own test, so any request fits one press: each entry has
    -- label ("[Enchanting]"), from ("Orihime Shishun"), where, at; newest first
    for _, e in ipairs(list) do
      local ok, yes = pcall(n, e)
      if ok and yes then t = e break end
    end
    if not t then
      print(('no caught profession link fits (have %d):'):format(#list))
      for i, e in ipairs(list) do print(('  %d: %s from %s'):format(i, e.label, e.from)) end
      return
    end
  elseif type(n) == 'string' then
    local want = n:lower()
    for _, e in ipairs(list) do
      if (e.from or ''):lower():find(want, 1, true) or (e.label or ''):lower():find(want, 1, true) then t = e break end
    end
    if not t and WowCompanion_Closest then
      -- speech-to-text spells invented names a letter off: take the closest
      local names, owner = {}, {}
      for _, e in ipairs(list) do
        names[#names + 1] = (e.from or ''):match('^[^%-]+') or '' owner[#names] = e
        names[#names + 1] = (e.label or ''):gsub('[%[%]]', '') owner[#names] = e
      end
      local i = WowCompanion_Closest(n, names, owner)
      if i then t = owner[i] end
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

-- the companion asks for this before a request about chat or links: recent chat
-- and the caught profession links, drawn as the data strip for the PC to read
function WCChatStrip()
  if not (WowCompanion_Strip and WowCompanion_Strip.Send) then return end
  local out = { 'recent chat (newest first, this session):' }
  for _, line in ipairs(WCRecentChat) do out[#out + 1] = line end
  out[#out + 1] = 'profession links caught (n for WCOpenTradeLink(n), newest first):'
  for i, e in ipairs(WowCompanionDB.tradeLinks or {}) do
    out[#out + 1] = ('%d: %s from %s in %s at %s'):format(i, e.label or '?', e.from or '?', e.where or '?', e.at and date('%H:%M', e.at) or '?')
  end
  WowCompanion_Strip.Send(table.concat(out, '\n'), 6)
end
