-- EndeavorsLeaderboard
-- Version 1.0.1
-- Changes:
--  - Refresh button next to close (hard refresh)
--  - Fixed nil calls by using forward declarations for local functions
--  - Auto-refresh ticker while window is open
--  - Detect Endeavor change (initiativeId) -> clear UI + restart retry
--  - Completion date at 100% persisted in SavedVariables

local ADDON_TAG = "|cff67d4ff[ELBG]|r"

local F = CreateFrame("Frame")
F:RegisterEvent("PLAYER_LOGIN")

ELBG_DB = ELBG_DB or {}
ELBG_DB.completedAt = ELBG_DB.completedAt or {}

local function dprint(...)
  if ELBG_DB.debug then
    print(ADDON_TAG, ...)
  end
end

-- Accent folding
local FOLD = {
  ["á"]="a",["à"]="a",["ã"]="a",["â"]="a",["ä"]="a",
  ["Á"]="a",["À"]="a",["Ã"]="a",["Â"]="a",["Ä"]="a",
  ["é"]="e",["è"]="e",["ê"]="e",["ë"]="e",
  ["É"]="e",["È"]="e",["Ê"]="e",["Ë"]="e",
  ["í"]="i",["ì"]="i",["î"]="i",["ï"]="i",
  ["Í"]="i",["Ì"]="i",["Î"]="i",["Ï"]="i",
  ["ó"]="o",["ò"]="o",["ô"]="o",["õ"]="o",["ö"]="o",
  ["Ó"]="o",["Ò"]="o",["Ô"]="o",["Õ"]="o",["Ö"]="o",
  ["ú"]="u",["ù"]="u",["û"]="u",["ü"]="u",
  ["Ú"]="u",["Ù"]="u",["Û"]="u",["Ü"]="u",
  ["ç"]="c",["Ç"]="c",
}

local function normalizeName(raw)
  if type(raw) ~= "string" then return nil end
  local name = raw:match("^([^%-]+)") or raw
  for k,v in pairs(FOLD) do name = name:gsub(k, v) end
  return name:lower():gsub("[%s%p]","")
end

local function parseNumber(x)
  local n = tonumber(x)
  if n then return n end
  return tonumber(tostring(x):match("([%d%.]+)")) or 0
end

local function fmt(v)
  v = tonumber(v) or 0
  if v >= 1e6 then return string.format("%.2fm", v/1e6)
  elseif v >= 1e3 then return string.format("%.1fk", v/1e3)
  else return tostring(math.floor(v + 0.5)) end
end

local function clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

-- =========================
-- Endeavor Progress (embedded)
-- =========================
local EP_CURRENCY_ID = 3363
local EP_MAX_TOTAL = 1000
local EP_MILESTONE_PCTS = { 0.25, 0.50, 0.75 }

local UI = {}
local lastRefreshAt = 0
local refreshInProgress = false
local retryToken = 0
local refreshTicker = nil
local activeInitiativeId = nil
local MIN_REFRESH_INTERVAL = 0.9

local MAX_ROWS = 10
local ROW_H, GAP = 24, 2

-- >>> Forward declarations (FIX for nil calls inside CreateUI button handlers)
local ClearRows
local Refresh
local StartRetry
-- <<<

local function EP_GetInitiativeInfo()
  if not C_NeighborhoodInitiative then return nil end

  if type(C_NeighborhoodInitiative.RequestNeighborhoodInitiativeInfo) == "function" then
    pcall(C_NeighborhoodInitiative.RequestNeighborhoodInitiativeInfo)
  end

  if type(C_NeighborhoodInitiative.GetNeighborhoodInitiativeInfo) == "function" then
    if type(C_NeighborhoodInitiative.GetActiveNeighborhood) == "function" then
      local okId, nid = pcall(C_NeighborhoodInitiative.GetActiveNeighborhood)
      if okId and nid ~= nil then
        local okInfo, info = pcall(C_NeighborhoodInitiative.GetNeighborhoodInitiativeInfo, nid)
        if okInfo and type(info) == "table" then return info end
      end
    end

    local okInfo2, info2 = pcall(C_NeighborhoodInitiative.GetNeighborhoodInitiativeInfo)
    if okInfo2 and type(info2) == "table" then return info2 end
  end

  return nil
end

local function EP_FillWidth(clip, fill, pct)
  local w = clip:GetWidth()
  if not w or w <= 1 then
    C_Timer.After(0, function()
      if UI.frame and UI.frame:IsShown() then EP_FillWidth(clip, fill, pct) end
    end)
    return
  end
  fill:SetWidth(w * pct)
end

local function EP_Update()
  if not UI.progress or not UI.progress:IsShown() then return end

  -- safety: ensure table exists even if something reinitialized ELBG_DB
  ELBG_DB = ELBG_DB or {}
  ELBG_DB.completedAt = ELBG_DB.completedAt or {}

  local info = EP_GetInitiativeInfo()

  local titleText = "Endeavor"
  local cur = 0
  local maxV = EP_MAX_TOTAL

  if info then
    titleText = info.name or info.title or info.initiativeName or "Endeavor"
    cur = tonumber(
      info.progress
      or info.currentProgress
      or info.current
      or info.contribution
      or info.value
      or info.amount
      or info.points
      or 0
    ) or 0
  end

  cur = clamp(cur, 0, maxV)
  local pct = (maxV > 0) and clamp(cur / maxV, 0, 1) or 0

  UI.progress.title:SetText(titleText)
  UI.progress.titleProgress:SetText(string.format("%s / %s (%.1f%%)", fmt(cur), fmt(maxV), pct * 100))

  EP_FillWidth(UI.progress.clip, UI.progress.fill, pct)

  local clipW = UI.progress.clip:GetWidth()
  if clipW and clipW > 1 then
    for i, p in ipairs(EP_MILESTONE_PCTS) do
      local m = UI.progress.markers[i]
      if m then
        local pos = p * clipW
        m:ClearAllPoints()
        m:SetPoint("CENTER", UI.progress.clip, "LEFT", pos, 0)
        m:Show()
      end
    end
  end

  local nextVal
  for _, p in ipairs(EP_MILESTONE_PCTS) do
    local v = maxV * p
    if cur < v then nextVal = v break end
  end
  if not nextVal then nextVal = maxV end

  -- stable key for completion date
  local key = nil
  if info and type(info) == "table" then
    key = info.initiativeId or info.initiativeID or info.id
  end
  key = tostring(key or titleText or "unknown")

  if cur >= maxV then
    if not ELBG_DB.completedAt[key] then
      ELBG_DB.completedAt[key] = time()
    end
    local ts = ELBG_DB.completedAt[key]
    local doneDate = (ts and date("%d/%m/%Y", ts)) or "—"
    UI.progress.nextText:SetText(("Concluído desde %s"):format(doneDate))
  else
    local remaining = nextVal - cur
    UI.progress.nextText:SetText(string.format(
      "Prox. marco: %s (%.0f%%) — faltam %s (%.1f%%)",
      fmt(nextVal), (nextVal / maxV) * 100, fmt(remaining), (remaining / maxV) * 100
    ))
  end

  if C_CurrencyInfo and type(C_CurrencyInfo.GetCurrencyInfo) == "function" then
    local cInfo = C_CurrencyInfo.GetCurrencyInfo(EP_CURRENCY_ID)
    local qty = (cInfo and cInfo.quantity) or 0
    local icon = (cInfo and cInfo.iconFileID) or nil
    if icon then
      UI.progress.currencyText:SetText(string.format("|T%s:14:14:0:0|t %s", icon, fmt(qty)))
    else
      UI.progress.currencyText:SetText(fmt(qty))
    end
  else
    UI.progress.currencyText:SetText("")
  end
end

-- =========================
-- Scroll helpers
-- =========================
local function UpdateScrollRange()
  if not UI.scroll or not UI.scrollChild then return end
  local childH = UI.scrollChild:GetHeight() or 0
  local viewH  = UI.scroll:GetHeight() or 0
  local maxScroll = math.max(0, childH - viewH)
  UI.maxScroll = maxScroll
  local cur = UI.scroll:GetVerticalScroll() or 0
  UI.scroll:SetVerticalScroll(clamp(cur, 0, maxScroll))
end

-- =========================
-- UI
-- =========================
local function CreateUI()
  if UI.frame and UI.rows and UI.scroll and UI.progress then return end
  if UI.frame and (not UI.rows or not UI.scroll or not UI.progress) then
    pcall(function() UI.frame:Hide() end)
    UI.frame = nil
    UI.rows = nil
    UI.scroll = nil
    UI.scrollChild = nil
    UI.progress = nil
  end

  local f = CreateFrame("Frame","GELB_Frame",UIParent,"BackdropTemplate")
  f:SetSize(320, 212)
  f:SetClampedToScreen(true)
  f:SetBackdrop({
    bgFile="Interface/Buttons/WHITE8X8",
    edgeFile="Interface/Tooltips/UI-Tooltip-Border",
    tile=true, tileSize=8, edgeSize=12,
    insets={left=3,right=3,top=3,bottom=3}
  })
  f:SetBackdropColor(0.04,0.04,0.05,0.92)

  UI.frame = f

  -- Resizing (height only)
  f:SetResizable(true)
  if f.SetMinResize then f:SetMinResize(320, 212) end
  if f.SetResizeBounds then
    f:SetResizeBounds(320, 212, 320, 420)
  end

  local resize = CreateFrame("Button", nil, f)
  UI.resize = resize
  resize:SetSize(16,16)
  resize:SetPoint("BOTTOMRIGHT", -4, 4)
  resize:EnableMouse(true)
  resize:RegisterForDrag("LeftButton")
  resize:SetScript("OnDragStart", function() f:StartSizing("BOTTOMRIGHT") end)
  resize:SetScript("OnDragStop", function()
    f:StopMovingOrSizing()
    UpdateScrollRange()
    ELBG_DB.sizeH = f:GetHeight()
  end)

  local rt = resize:CreateTexture(nil,"OVERLAY")
  rt:SetAllPoints()
  rt:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  resize:SetNormalTexture(rt)

  -- Header drag
  local hdr = CreateFrame("Frame", nil, f)
  UI.header = hdr
  hdr:SetPoint("TOPLEFT", 6, -6)
  hdr:SetPoint("TOPRIGHT", -6, -6)
  hdr:SetHeight(34)

  f:SetMovable(true)
  f:EnableMouse(true)
  hdr:EnableMouse(true)
  hdr:RegisterForDrag("LeftButton")
  hdr:SetScript("OnDragStart", function() f:StartMoving() end)
  hdr:SetScript("OnDragStop", function()
    f:StopMovingOrSizing()
    local p,_,rp,x,y = f:GetPoint(1)
    ELBG_DB.point = {p=p, rp=rp, x=x, y=y}
  end)

  local title = hdr:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
  title:SetPoint("LEFT", hdr, "LEFT", 10, 0)
  title:SetJustifyH("LEFT")
  title:SetText("Endeavor Leaderboard")

  local close = CreateFrame("Button",nil,hdr,"UIPanelCloseButton")
  close:SetPoint("RIGHT",-2,0)
  close:SetScale(0.85)
  close:SetScript("OnClick", function()
    f:Hide()
    retryToken = retryToken + 1
    if refreshTicker then refreshTicker:Cancel(); refreshTicker=nil end
  end)

  -- NEW: Refresh button next to close
  local refreshBtn = CreateFrame("Button", nil, hdr, "UIPanelButtonTemplate")
  refreshBtn:SetSize(24, 22)
  refreshBtn:SetPoint("RIGHT", close, "LEFT", -4, 0)
  refreshBtn:SetText("R") -- if your client doesn't render, switch to "R"

  refreshBtn:SetScript("OnClick", function()
    if not UI.frame or not UI.frame:IsShown() then return end

    -- Hard refresh: ignore throttle + reset in-flight flag
    lastRefreshAt = 0
    refreshInProgress = false

    UI.sub:SetText("Endeavor • atualizando...")
    ClearRows()
    if UI.scroll then UI.scroll:SetVerticalScroll(0) end

    Refresh()
    StartRetry()
  end)

  refreshBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Atualizar agora", 1, 1, 1)
    GameTooltip:Show()
  end)
  refreshBtn:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)

  UI.sub = f:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
  UI.sub:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 8, -2)
  UI.sub:SetText("Endeavor • aguardando ranking...")

  -- Endeavor Progress panel
  local p = CreateFrame("Frame", nil, f, "BackdropTemplate")
  UI.progress = p
  p:SetPoint("TOPLEFT", UI.sub, "BOTTOMLEFT", 0, -2)
  p:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -48)
  p:SetHeight(82)
  p:SetBackdrop({
    bgFile="Interface/Buttons/WHITE8X8",
    edgeFile="Interface/Tooltips/UI-Tooltip-Border",
    tile=true, tileSize=8, edgeSize=10,
    insets={left=2,right=2,top=2,bottom=2}
  })
  p:SetBackdropColor(0.03,0.03,0.04,0.75)

  p.title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  p.title:SetPoint("TOPLEFT", 10, -8)
  p.title:SetShadowColor(0,0,0,0.8)
  p.title:SetShadowOffset(1, -1)
  p.title:SetText("Endeavor")

  p.titleProgress = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  p.titleProgress:SetPoint("LEFT", p.title, "RIGHT", 10, 0)
  p.titleProgress:SetPoint("RIGHT", p, "TOPRIGHT", -10, -8)
  p.titleProgress:SetJustifyH("RIGHT")
  p.titleProgress:SetShadowColor(0,0,0,0.9)
  p.titleProgress:SetShadowOffset(1, -1)
  p.titleProgress:SetText("—")

  local BAR_H = 21
  p.bar = CreateFrame("Frame", nil, p, "BackdropTemplate")
  p.bar:SetPoint("TOPLEFT", p.title, "BOTTOMLEFT", 0, -8)
  p.bar:SetPoint("TOPRIGHT", p, "TOPRIGHT", -10, -32)
  p.bar:SetHeight(BAR_H)

  p.bar.bg = p.bar:CreateTexture(nil, "BACKGROUND")
  p.bar.bg:SetAllPoints(true)
  p.bar.bg:SetColorTexture(0.06, 0.06, 0.06, 0.96)

  p.bar:SetBackdrop({
    edgeFile="Interface/Tooltips/UI-Tooltip-Border",
    tile=true, tileSize=16, edgeSize=10,
    insets={left=2,right=2,top=2,bottom=2}
  })
  p.bar:SetBackdropBorderColor(0.90, 0.78, 0.25, 0.70)

  p.bar.inner = CreateFrame("Frame", nil, p.bar, "BackdropTemplate")
  p.bar.inner:SetPoint("TOPLEFT", 2, -2)
  p.bar.inner:SetPoint("BOTTOMRIGHT", -2, 2)
  p.bar.inner:SetBackdrop({
    edgeFile="Interface/Buttons/WHITE8X8",
    tile=true, tileSize=8, edgeSize=1,
    insets={left=1,right=1,top=1,bottom=1}
  })
  p.bar.inner:SetBackdropBorderColor(0,0,0,0.55)

  p.clip = CreateFrame("Frame", nil, p.bar)
  p.clip:SetPoint("TOPLEFT", 3, -3)
  p.clip:SetPoint("BOTTOMRIGHT", -3, 3)
  p.clip:SetClipsChildren(true)

  p.fill = p.clip:CreateTexture(nil, "ARTWORK")
  p.fill:SetTexture("Interface\\TARGETINGFRAME\\UI-StatusBar")
  p.fill:SetVertexColor(1.00, 0.82, 0.18, 1.0)
  p.fill:SetPoint("TOPLEFT", p.clip, "TOPLEFT", 0, 1)
  p.fill:SetPoint("BOTTOMLEFT", p.clip, "BOTTOMLEFT", 0, 1)
  p.fill:SetWidth(0)

  p.fillHi = p.clip:CreateTexture(nil, "OVERLAY")
  p.fillHi:SetTexture("Interface\\Buttons\\WHITE8X8")
  p.fillHi:SetPoint("TOPLEFT", p.fill, "TOPLEFT", 0, 0)
  p.fillHi:SetPoint("BOTTOMRIGHT", p.fill, "BOTTOMRIGHT", 0, 0)
  p.fillHi:SetAlpha(0.14)
  if p.fillHi.SetGradientAlpha then
    p.fillHi:SetGradientAlpha("VERTICAL", 1,1,1,0.26, 1,1,1,0.05)
  end

  p.overlay = CreateFrame("Frame", nil, p.clip)
  p.overlay:SetAllPoints(true)
  p.markers = {}
  for i=1,3 do
    local t = p.overlay:CreateTexture(nil, "OVERLAY", nil, 7)
    t:SetTexture("Interface\\Buttons\\WHITE8X8")
    t:SetSize(2, BAR_H - 10)
    t:SetColorTexture(0,0,0,0.55)
    p.markers[i] = t
  end

  p.nextText = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  p.nextText:SetPoint("TOPLEFT", p.bar, "BOTTOMLEFT", 0, -5)
  p.nextText:SetText("Próximo marco: —")

  p.currencyText = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  p.currencyText:SetPoint("LEFT", p.nextText, "RIGHT", 8, 0)
  p.currencyText:SetPoint("RIGHT", p, "RIGHT", -10, 0)
  p.currencyText:SetJustifyH("RIGHT")
  p.currencyText:SetText("")

  -- Scrollable list area
  local scroll = CreateFrame("ScrollFrame", nil, f)
  UI.scroll = scroll
  scroll:SetPoint("TOPLEFT", p, "BOTTOMLEFT", 0, -10)
  scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 12)
  scroll:EnableMouseWheel(true)

  scroll:SetScript("OnMouseWheel", function(self, delta)
    local cur = self:GetVerticalScroll() or 0
    local step = 28
    local maxScroll = UI.maxScroll or 0
    self:SetVerticalScroll(clamp(cur - (delta * step), 0, maxScroll))
  end)

  local child = CreateFrame("Frame", nil, scroll)
  UI.scrollChild = child
  scroll:SetScrollChild(child)

  local childH = (ROW_H * MAX_ROWS) + (GAP * (MAX_ROWS - 1))
  child:SetSize(300, childH)

  UI.rows = {}
  for i=1,MAX_ROWS do
    local r = CreateFrame("Frame", nil, child)
    r:SetSize(300, ROW_H)
    if i == 1 then
      r:SetPoint("TOPLEFT", 0, 0)
    else
      r:SetPoint("TOPLEFT", UI.rows[i-1].frame, "BOTTOMLEFT", 0, -GAP)
    end

    local medal = r:CreateTexture(nil, "ARTWORK")
    medal:SetSize(18,18)
    medal:SetPoint("LEFT", 6, 0)

    local rank = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    rank:SetPoint("CENTER", medal, "CENTER", 0, 0)
    rank:SetWidth(22)
    rank:SetJustifyH("CENTER")
    rank:SetTextColor(0.85,0.85,0.85)

    local name = r:CreateFontString(nil,"OVERLAY","GameFontNormal")
    name:SetPoint("LEFT", medal, "RIGHT", 6, 0)
    name:SetWidth(180)
    name:SetJustifyH("LEFT")

    local val = r:CreateFontString(nil,"OVERLAY","GameFontHighlight")
    val:SetPoint("RIGHT", -6, 0)
    val:SetWidth(80)
    val:SetJustifyH("RIGHT")

    UI.rows[i] = { frame=r, medal=medal, rank=rank, name=name, val=val }
  end

  if ELBG_DB.point and ELBG_DB.point.p then
    local pt=ELBG_DB.point
    f:ClearAllPoints()
    f:SetPoint(pt.p,UIParent,pt.rp,pt.x,pt.y)
  else
    f:SetPoint("CENTER")
  end
  if ELBG_DB.sizeH then
    local h = tonumber(ELBG_DB.sizeH)
    if h then f:SetHeight(clamp(h, 212, 420)) end
  end

  f:SetScript("OnSizeChanged", function()
    UpdateScrollRange()
    EP_Update()
  end)

  f:Hide()
  UpdateScrollRange()
  EP_Update()
end

local function SetRankVisual(i, row)
  if i==1 then
    row.medal:SetTexture("Interface\\Icons\\Achievement_ChallengeMode_Gold")
    row.rank:SetText("")
  elseif i==2 then
    row.medal:SetTexture("Interface\\Icons\\Achievement_ChallengeMode_Silver")
    row.rank:SetText("")
  elseif i==3 then
    row.medal:SetTexture("Interface\\Icons\\Achievement_ChallengeMode_Bronze")
    row.rank:SetText("")
  else
    row.medal:SetTexture(nil)
    row.rank:SetText(tostring(i)..".")
  end
end

-- FIX: assigned (not "local function") because CreateUI closures reference it
ClearRows = function()
  for i=1,MAX_ROWS do
    local row = UI.rows and UI.rows[i]
    if not row then break end
    SetRankVisual(i, row)
    row.name:SetText("-")
    row.val:SetText("")
  end
  if UI.scroll then UI.scroll:SetVerticalScroll(0) end
end

-- =========================
-- Data + ranking
-- =========================
local function hasAPI()
  return C_NeighborhoodInitiative
    and type(C_NeighborhoodInitiative.GetNeighborhoodInitiativeInfo)=="function"
    and type(C_NeighborhoodInitiative.GetInitiativeActivityLogInfo)=="function"
end

local function GetInitiativeId()
  if not C_NeighborhoodInitiative or type(C_NeighborhoodInitiative.GetNeighborhoodInitiativeInfo)~="function" then return nil end
  local ok, info = pcall(C_NeighborhoodInitiative.GetNeighborhoodInitiativeInfo)
  if not ok or type(info)~="table" then return nil end
  return info.initiativeId or info.id or info.initiativeID
end

local function GetActivityRoot(id)
  if not C_NeighborhoodInitiative or type(C_NeighborhoodInitiative.GetInitiativeActivityLogInfo)~="function" then return nil end
  local ok, root = pcall(C_NeighborhoodInitiative.GetInitiativeActivityLogInfo, id)
  if not ok or type(root)~="table" then return nil end
  return root
end

local function ComputeTop(root)
  if not root or type(root.taskActivity)~="table" then return nil, 0 end
  local totals, display = {}, {}
  local count = 0
  for _,b in pairs(root.taskActivity) do
    if type(b)=="table" and b.playerName and b.amount then
      local key = normalizeName(b.playerName)
      if key then
        count = count + 1
        totals[key] = (totals[key] or 0) + parseNumber(b.amount)
        local dn = (b.playerName:match("^([^%-]+)") or b.playerName)
        display[key] = display[key] or dn
      end
    end
  end

  local coll = {}
  for k,v in pairs(totals) do
    coll[#coll+1] = { name = display[k], value = v }
  end
  table.sort(coll, function(a,b) return a.value > b.value end)

  local out = {}
  for i=1, math.min(MAX_ROWS, #coll) do
    out[i] = { name = coll[i].name, val = fmt(coll[i].value) }
  end
  return out, count
end

local function Render(entries)
  if entries and #entries > 0 then
    for i=1,MAX_ROWS do
      local row = UI.rows and UI.rows[i]
      if not row then break end
      local e = entries[i]
      SetRankVisual(i, row)
      if e then
        row.name:SetText(e.name or "-")
        row.val:SetText(e.val or "")
      else
        row.name:SetText("-")
        row.val:SetText("")
      end
    end
  else
    ClearRows()
  end
  UpdateScrollRange()
end

-- FIX: Refresh assigned (not "local function") because CreateUI closures reference it
Refresh = function()
  if not UI.frame or not UI.frame:IsShown() then return false end
  EP_Update()

  if refreshInProgress then return false end
  local now = GetTime()
  if (now - lastRefreshAt) < MIN_REFRESH_INTERVAL then return false end

  refreshInProgress = true
  lastRefreshAt = now

  if not hasAPI() then
    UI.sub:SetText("Endeavor • API indisponível (client)")
    Render(nil)
    refreshInProgress = false
    return false
  end

  if C_NeighborhoodInitiative then
    if type(C_NeighborhoodInitiative.RequestNeighborhoodInitiativeInfo)=="function" then
      pcall(C_NeighborhoodInitiative.RequestNeighborhoodInitiativeInfo)
    end
    if type(C_NeighborhoodInitiative.RequestInitiativeActivityLog)=="function" then
      pcall(C_NeighborhoodInitiative.RequestInitiativeActivityLog)
    end
  end

  local id = GetInitiativeId()
  if not id then
    UI.sub:SetText("Endeavor • sem initiativeId (aguarde)")
    Render(nil)
    refreshInProgress = false
    return false
  end

  -- If Endeavor changed: reset UI and restart retry flow
  if activeInitiativeId ~= id then
    activeInitiativeId = id

    retryToken = retryToken + 1

    UI.sub:SetText("Endeavor • carregando novo endeavor...")
    ClearRows()
    if UI.scroll then UI.scroll:SetVerticalScroll(0) end

    refreshInProgress = false

    C_Timer.After(0, function()
      if UI.frame and UI.frame:IsShown() then
        StartRetry()
      end
    end)

    return false
  end

  local root = GetActivityRoot(id)
  local top, n = ComputeTop(root)

  if top and #top > 0 then
    UI.sub:SetText("")
    Render(top)
    dprint("OK top:", #top, "taskActivity entries:", n, "initiativeId:", id)
    refreshInProgress = false
    return true
  else
    UI.sub:SetText("Endeavor • aguardando ranking...")
    Render(nil)
    dprint("sem ranking ainda. initiativeId:", id)
    refreshInProgress = false
    return false
  end
end

-- FIX: StartRetry assigned (not "function StartRetry()") because CreateUI closures reference it
StartRetry = function()
  if not UI.frame or not UI.frame:IsShown() then return end
  retryToken = retryToken + 1
  local token = retryToken
  local delays = {0.4, 0.9, 1.6, 2.6, 4.0, 5.0}
  local i = 1

  local function step()
    if token ~= retryToken then return end
    if not UI.frame or not UI.frame:IsShown() then return end
    local ok = Refresh()
    if ok then return end
    if i <= #delays then
      local d = delays[i]; i=i+1
      C_Timer.After(d, step)
    end
  end

  step()
end

-- Event coalescing
local eventDebounceArmed = false
local function OnDataEvent()
  if not UI.frame or not UI.frame:IsShown() then return end
  if eventDebounceArmed then return end
  eventDebounceArmed = true
  C_Timer.After(0.5, function()
    eventDebounceArmed = false
    Refresh()
  end)
end

local function RegisterEvents()
  pcall(F.RegisterEvent, F, "INITIATIVE_ACTIVITY_LOG_UPDATED")
  pcall(F.RegisterEvent, F, "NEIGHBORHOOD_INITIATIVE_UPDATED")
  pcall(F.RegisterEvent, F, "NEIGHBORHOOD_LIST_UPDATED")
  pcall(F.RegisterEvent, F, "CURRENCY_DISPLAY_UPDATE")
end

F:SetScript("OnEvent", function(_,event)
  if event=="PLAYER_LOGIN" then
    CreateUI()
    RegisterEvents()
    dprint("loaded. /elbg show")
  else
    OnDataEvent()
  end
end)

-- Commands
SLASH_ELBG1="/elbg"
SlashCmdList["ELBG"]=function(msg)
  msg=(msg or ""):lower():gsub("^%s+",""):gsub("%s+$","")
  if msg=="show" then
    CreateUI()
    UI.frame:Show()

    if UI.scroll then
      UI.scroll:SetVerticalScroll(0)
    end

    ClearRows()
    -- Primeira tentativa
    lastRefreshAt = 0
    refreshInProgress = false
    Refresh()
    StartRetry()

    -- Auto polling while window is open
    if refreshTicker then refreshTicker:Cancel() end
    refreshTicker = C_Timer.NewTicker(2.0, function()
      if UI.frame and UI.frame:IsShown() then
        Refresh()
      end
    end)

  elseif msg=="hide" then
    if UI.frame then UI.frame:Hide() end
    retryToken = retryToken + 1
    if refreshTicker then refreshTicker:Cancel(); refreshTicker=nil end

  elseif msg=="debug" then
    ELBG_DB.debug = not ELBG_DB.debug
    print(ADDON_TAG, "debug:", ELBG_DB.debug and "ON" or "OFF")
  else
    print(ADDON_TAG, "comandos: /elbg show | /elbg hide | /elbg debug")
  end
end
