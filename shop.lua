--[[===========================================================================
  SHOP  v1.0.0  --  CC:Tweaked storefront
  Refined Storage (or AE2) through an Advanced Peripherals bridge + one barrel.

  Wiring:
    computer  ..  rsBridge (or meBridge)     -- the stock / the bank
              ..  barrel  (any inventory)    -- the teller, players use this one
              ..  monitor (optional)         -- touch storefront
              ..  playerDetector (optional)  -- sign in, per name wallets
              ..  speaker (optional)         -- clicks

  Everything is configurable from the ADMIN panel (terminal, key A, PIN).
  Data lives in  shopdata/  next to this program.
===========================================================================]]--

local VERSION = "1.0.0"

local DIR    = "shopdata"
local F_CFG  = DIR .. "/config.tbl"
local F_ITEM = DIR .. "/items.tbl"
local F_WAL  = DIR .. "/wallets.tbl"
local F_LOG  = DIR .. "/log.tbl"
local F_JRN  = DIR .. "/journal.tbl"

--==========================================================================
-- DEFAULT CONFIG
--==========================================================================
local DEF = {
  shopName = "GENERAL STORE",
  motd     = "DROP CURRENCY IN THE BARREL TO GET CREDITS",
  barrelName = "auto",         -- "auto" or exact peripheral name
  currency = {
    symbol = "c",
    units  = {
      { id = "minecraft:diamond",       label = "Diamond",       value = 1 },
      { id = "minecraft:diamond_block", label = "Diamond Block", value = 9 },
    },
  },
  shop = {
    buyEnabled  = true,        -- shop sells to players
    sellEnabled = true,        -- shop buys from players
    autoSell    = false,       -- buy anything sellable the moment it lands
    buyTax      = 0,           -- % added on top of the buy price
    sellFee     = 0,           -- % taken off the sell price
    maxQty      = 1024,        -- hard cap for one order
    sortBy      = "label",     -- label | price | stock | custom
    hideEmpty   = false,       -- hide out of stock rows
    showId      = false,       -- print item ids in the list
  },
  wallet = {
    enabled      = true,       -- per name credit wallets (needs a playerDetector)
    range        = 8,          -- how close the signer must stand
    signCooldown = 2,          -- seconds between two accepted signatures
    autoStore    = true,       -- park leftover credits in the wallet on cash out
  },
  ui = {
    monScale = 0.5,
    stockTTL = 5,              -- seconds between network stock refreshes
    tick     = 0.5,            -- teller scan period
    idle     = 120,            -- seconds of silence before an auto cash out
    sounds   = true,
    theme = {
      bg = "black", fg = "white", head = "blue", headFg = "white",
      btn = "gray", btnFg = "white", ok = "lime", warn = "orange",
      bad = "red", accent = "yellow", dim = "lightGray", rowAlt = "gray",
    },
  },
  admin = { pin = "1234", logSize = 250 },
}

--==========================================================================
-- SMALL UTILITIES
--==========================================================================
local function copy(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = copy(v) end
  return o
end

local function saveT(path, t)
  if not fs.exists(DIR) then fs.makeDir(DIR) end
  local f = fs.open(path, "w")
  if not f then return false end
  f.write(textutils.serialize(t))
  f.close()
  return true
end

local function loadT(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  if not f then return nil end
  local s = f.readAll()
  f.close()
  local ok, v = pcall(textutils.unserialize, s)
  if ok and type(v) == "table" then return v end
  return nil
end

-- fill missing keys from the defaults, keep whatever the admin set
local function mergeDef(v, d)
  if type(d) ~= "table" then
    if v == nil or type(v) ~= type(d) then return d end
    return v
  end
  local out, src = {}, (type(v) == "table") and v or {}
  for k, dv in pairs(d) do out[k] = mergeDef(src[k], dv) end
  for k, sv in pairs(src) do if out[k] == nil then out[k] = sv end end
  return out
end

local function clamp(n, lo, hi) return math.max(lo, math.min(hi, n)) end

local function commify(n)
  local s = tostring(math.floor(math.abs(n)))
  local out = ""
  while #s > 3 do
    out = "," .. s:sub(-3) .. out
    s = s:sub(1, -4)
  end
  out = s .. out
  if n < 0 then out = "-" .. out end
  return out
end

local function trunc(s, w)
  s = tostring(s or "")
  if #s <= w then return s end
  if w <= 1 then return s:sub(1, w) end
  return s:sub(1, w - 1) .. "."
end

local function pad(s, w)
  s = trunc(s, w)
  return s .. string.rep(" ", math.max(0, w - #s))
end

local function rpad(s, w)
  s = trunc(s, w)
  return string.rep(" ", math.max(0, w - #s)) .. s
end

local function shortId(id)
  local s = tostring(id or ""):match("[^:]+$") or tostring(id)
  s = s:gsub("_", " ")
  return (s:gsub("(%a)([%w]*)", function(a, b) return a:upper() .. b end))
end

--==========================================================================
-- STATE
--==========================================================================
local CFG, ITEMS, WAL, LOGD
local bridge, barrel, barrelName, mon, monName, det, spk

local online   = false          -- bridge answered the last call
local stockMap = {}             -- id -> amount in the network
local nameMap  = {}             -- id -> display name seen on the network
local lastStock = -1000

local tellerCount = {}          -- id -> count sitting in the barrel
local tellerNbt   = {}          -- id -> true when a stack carries nbt
local protect     = {}          -- id -> count the scanner must ignore (we put it there)

local S = {                     -- the live session at the counter
  bal     = 0,
  name    = nil,
  signAt  = 0,
  lastAct = 0,
}

--==========================================================================
-- CONFIG / CATALOG LOAD
--==========================================================================
local function loadCfg()
  local raw = loadT(F_CFG) or {}
  CFG = mergeDef(raw, DEF)
  if raw.currency and type(raw.currency.units) == "table" and #raw.currency.units > 0 then
    CFG.currency.units = raw.currency.units
  end
  ITEMS = loadT(F_ITEM) or {}
  WAL   = loadT(F_WAL) or {}
  LOGD  = loadT(F_LOG) or { entries = {}, stats = {} }
  LOGD.entries = LOGD.entries or {}
  LOGD.stats   = mergeDef(LOGD.stats, {
    buys = 0, sells = 0, credIn = 0, credOut = 0, revenue = 0, paid = 0,
  })
end

local function saveCfg()  saveT(F_CFG,  CFG)   end
local function saveItems() saveT(F_ITEM, ITEMS) end
local function saveWal()  saveT(F_WAL,  WAL)   end
local function saveLog()  saveT(F_LOG,  LOGD)  end

local function itemById(id)
  for i, e in ipairs(ITEMS) do
    if e.id == id then return e, i end
  end
  return nil
end

local function itemLabel(e)
  return e.label or nameMap[e.id] or shortId(e.id)
end

--==========================================================================
-- LOG
--==========================================================================
local function logAdd(kind, who, id, qty, amt, note)
  table.insert(LOGD.entries, {
    t = os.epoch("utc"), kind = kind, who = who or "-",
    id = id, qty = qty, amt = amt, note = note,
  })
  local over = #LOGD.entries - (CFG.admin.logSize or 250)
  while over > 0 do table.remove(LOGD.entries, 1); over = over - 1 end
  local st = LOGD.stats
  if kind == "BUY"  then st.buys  = st.buys  + 1; st.revenue = st.revenue + (amt or 0) end
  if kind == "SELL" then st.sells = st.sells + 1; st.paid    = st.paid    + (amt or 0) end
  if kind == "DEP"  then st.credIn  = st.credIn  + (amt or 0) end
  if kind == "OUT"  then st.credOut = st.credOut + (amt or 0) end
  saveLog()
end

local function stamp(ms)
  local ok, s = pcall(function()
    return os.date("!%d.%m %H:%M", math.floor((ms or 0) / 1000))
  end)
  return ok and s or "--"
end

--==========================================================================
-- MONEY
--==========================================================================
local function SYM() return CFG.currency.symbol or "c" end

local function money(n) return commify(n) .. SYM() end

local function unitById(id)
  for _, u in ipairs(CFG.currency.units) do
    if u.id == id then return u end
  end
  return nil
end

local function unitsDesc()
  local u = {}
  for _, x in ipairs(CFG.currency.units) do
    if (tonumber(x.value) or 0) > 0 then table.insert(u, x) end
  end
  table.sort(u, function(a, b) return (a.value or 0) > (b.value or 0) end)
  return u
end

local function buyPrice(e, qty)
  local p = (tonumber(e.buy) or 0) * qty
  p = p * (1 + (tonumber(CFG.shop.buyTax) or 0) / 100)
  return math.ceil(p - 1e-9)
end

local function sellPrice(e, qty)
  local p = (tonumber(e.sell) or 0) * qty
  p = p * (1 - (tonumber(CFG.shop.sellFee) or 0) / 100)
  return math.floor(p + 1e-9)
end

--==========================================================================
-- WALLETS
--==========================================================================
local function walGet(name)
  if not name then return 0 end
  return tonumber(WAL[name]) or 0
end

local function walAdd(name, amt)
  if not name or amt == 0 then return end
  WAL[name] = math.max(0, walGet(name) + amt)
  if WAL[name] == 0 then WAL[name] = nil end
  saveWal()
end

--==========================================================================
-- PERIPHERALS
--==========================================================================
local function isType(n, t)
  local ok, r = pcall(peripheral.hasType, n, t)
  return ok and r or false
end

local function findBridge()
  return peripheral.find("rsBridge") or peripheral.find("meBridge")
end

local function findBarrel()
  local want = CFG.barrelName
  if want and want ~= "auto" and peripheral.isPresent(want) then
    return peripheral.wrap(want), want
  end
  local fallback, fallbackName
  for _, n in ipairs(peripheral.getNames()) do
    local skip = isType(n, "rsBridge") or isType(n, "meBridge")
                 or isType(n, "monitor") or isType(n, "playerDetector")
    if not skip and isType(n, "inventory") then
      if n:find("barrel") then return peripheral.wrap(n), n end
      if not fallback then fallback, fallbackName = peripheral.wrap(n), n end
    end
  end
  return fallback, fallbackName
end

local function bindPeripherals()
  bridge = findBridge()
  barrel, barrelName = findBarrel()
  mon = peripheral.find("monitor")
  monName = mon and peripheral.getName(mon) or nil
  det = peripheral.find("playerDetector")
  spk = peripheral.find("speaker")
  if mon then
    pcall(mon.setTextScale, tonumber(CFG.ui.monScale) or 0.5)
  end
end

local function beep(note)
  if not (CFG.ui.sounds and spk) then return end
  pcall(spk.playNote, "harp", 1, note or 12)
end

--==========================================================================
-- BRIDGE CALLS
--==========================================================================
local function bx(fn, ...)
  if not bridge or not fn then return nil, "NO BRIDGE" end
  local ok, a, b = pcall(fn, ...)
  if not ok then return nil, tostring(a) end
  if a == nil then return nil, tostring(b or "ERR") end
  return a
end

local function filterOf(id, n, nbt)
  local f = { name = id, count = n }
  if nbt and nbt ~= "" then f.nbt = nbt end
  return f
end

local function refreshStock(force)
  if not bridge then online = false; return end
  if not force and (os.clock() - lastStock) < (tonumber(CFG.ui.stockTTL) or 5) then return end
  lastStock = os.clock()
  local l = bx(bridge.listItems)
  if type(l) ~= "table" then online = false; return end
  online = true
  local m = {}
  for _, it in ipairs(l) do
    local id = it.name
    if id then
      m[id] = (m[id] or 0) + (tonumber(it.amount) or tonumber(it.count) or 0)
      if it.displayName and not nameMap[id] then nameMap[id] = it.displayName end
    end
  end
  stockMap = m
end

local function stockOf(id)
  return tonumber(stockMap[id]) or 0
end

local function freeStock(e)
  return math.max(0, stockOf(e.id) - (tonumber(e.reserve) or 0))
end

-- export out of the network into the barrel; returns how many really moved
local function rsExport(id, n, nbt)
  if not bridge or not barrelName or n <= 0 then return 0 end
  local total, guard = 0, 0
  while total < n and guard < 80 do
    guard = guard + 1
    local m = tonumber((bx(bridge.exportItemToPeripheral, filterOf(id, n - total, nbt), barrelName))) or 0
    if m <= 0 then break end
    total = total + m
  end
  if total > 0 then
    stockMap[id] = math.max(0, stockOf(id) - total)
    protect[id] = (protect[id] or 0) + total
  end
  return total
end

-- import out of the barrel into the network; returns how many really moved
local function rsImport(id, n, nbt)
  if not bridge or not barrelName or n <= 0 then return 0 end
  local total, guard = 0, 0
  while total < n and guard < 80 do
    guard = guard + 1
    local m = tonumber((bx(bridge.importItemFromPeripheral, filterOf(id, n - total, nbt), barrelName))) or 0
    if m <= 0 then break end
    total = total + m
  end
  if total > 0 then stockMap[id] = stockOf(id) + total end
  return total
end

--==========================================================================
-- JOURNAL  (a move is written down before it happens, settled after)
--==========================================================================
local function jrnSet(t) saveT(F_JRN, t) end
local function jrnClear() if fs.exists(F_JRN) then fs.delete(F_JRN) end end

local function jrnRecover()
  local j = loadT(F_JRN)
  jrnClear()
  if not j then return end
  -- we cannot know how much moved before the crash; be generous to the player
  if j.kind == "BUY" and j.who and (tonumber(j.charged) or 0) > 0 and CFG.wallet.enabled then
    walAdd(j.who, j.charged)
    logAdd("FIX", j.who, j.id, j.want, j.charged, "refund after reboot")
  else
    logAdd("FIX", j.who, j.id, j.want, j.charged, "unsettled " .. tostring(j.kind))
  end
end

--==========================================================================
-- TELLER (the barrel)
--==========================================================================
local function scanTeller()
  if not barrel then return end
  local ok, list = pcall(barrel.list)
  if not ok or type(list) ~= "table" then return end
  local counts, nbts = {}, {}
  for _, st in pairs(list) do
    if st and st.name then
      counts[st.name] = (counts[st.name] or 0) + (tonumber(st.count) or 0)
      if st.nbt then nbts[st.name] = true end
    end
  end
  for id, n in pairs(protect) do
    local c = counts[id] or 0
    if c < n then protect[id] = c end
    if (protect[id] or 0) <= 0 then protect[id] = nil end
  end
  tellerCount, tellerNbt = counts, nbts
end

local function avail(id)
  return math.max(0, (tellerCount[id] or 0) - (protect[id] or 0))
end

local function tellerFree()
  if not barrel then return 0 end
  local ok, list = pcall(barrel.list)
  local ok2, size = pcall(barrel.size)
  if not (ok and ok2) then return 0 end
  local used = 0
  for _ in pairs(list) do used = used + 1 end
  return math.max(0, (tonumber(size) or 0) - used)
end

--==========================================================================
-- MESSAGES
--==========================================================================
local UI = {
  screen = "catalog", cat = "ALL", page = 1, sel = nil, qty = 1,
  filter = "", msg = "", msgKind = "fg", msgUntil = 0,
  signFrom = 0, busy = false,
}

local function msg(text, kind)
  UI.msg = tostring(text or "")
  UI.msgKind = kind or "fg"
  UI.msgUntil = os.clock() + 5
  if kind == "bad" then beep(6) elseif kind == "ok" then beep(18) end
end

local function touch() S.lastAct = os.clock() end

--==========================================================================
-- TRANSACTIONS
--==========================================================================
local function depositCurrency()
  if not bridge then return end
  for _, u in ipairs(CFG.currency.units) do
    local n = avail(u.id)
    if n > 0 then
      local moved = rsImport(u.id, n)
      if moved > 0 then
        local credit = moved * (tonumber(u.value) or 0)
        S.bal = S.bal + credit
        logAdd("DEP", S.name, u.id, moved, credit)
        msg("+" .. money(credit) .. "  (" .. moved .. " " .. (u.label or shortId(u.id)) .. ")", "ok")
        touch()
      end
    end
  end
end

local function maxAffordable(e)
  local unit = (tonumber(e.buy) or 0) * (1 + (tonumber(CFG.shop.buyTax) or 0) / 100)
  if unit <= 0 then return 0 end
  local n = math.floor(S.bal / unit)
  while n > 0 and buyPrice(e, n) > S.bal do n = n - 1 end
  return n
end

local function doBuy(e, qty)
  if not CFG.shop.buyEnabled then return msg("BUYING IS DISABLED", "bad") end
  if not e or e.enabled == false or (tonumber(e.buy) or 0) <= 0 then
    return msg("ITEM NOT FOR SALE", "bad")
  end
  qty = math.floor(tonumber(qty) or 0)
  if qty <= 0 then return msg("SET A QUANTITY", "warn") end
  qty = math.min(qty, tonumber(CFG.shop.maxQty) or 1024)
  if (tonumber(e.limit) or 0) > 0 then qty = math.min(qty, e.limit) end

  refreshStock(true)
  local free = freeStock(e)
  if free <= 0 then return msg("OUT OF STOCK", "bad") end
  if qty > free then qty = free; msg("ONLY " .. free .. " IN STOCK", "warn") end

  local price = buyPrice(e, qty)
  if price > S.bal then
    local can = maxAffordable(e)
    if can <= 0 then return msg("NOT ENOUGH CREDITS", "bad") end
    qty, price = math.min(qty, can), buyPrice(e, math.min(qty, can))
    msg("TRIMMED TO " .. qty .. " (CREDITS)", "warn")
  end
  if tellerFree() <= 0 then return msg("TELLER FULL - TAKE YOUR ITEMS", "bad") end

  S.bal = S.bal - price
  jrnSet({ kind = "BUY", id = e.id, want = qty, charged = price, who = S.name,
           before = stockOf(e.id), t = os.epoch("utc") })
  local moved = rsExport(e.id, qty, e.nbt)
  jrnClear()

  if moved < qty then
    local refund = price - buyPrice(e, moved)
    S.bal = S.bal + refund
    if moved <= 0 then
      msg("DELIVERY FAILED - REFUNDED " .. money(refund), "bad")
      logAdd("BUY", S.name, e.id, 0, 0, "failed, refund " .. refund)
      return
    end
    msg("ONLY " .. moved .. " DELIVERED - REFUND " .. money(refund), "warn")
  else
    msg("BOUGHT " .. moved .. "x " .. itemLabel(e) .. " FOR " .. money(price), "ok")
  end
  logAdd("BUY", S.name, e.id, moved, buyPrice(e, moved))
  touch()
end

local function doSell(e, qty)
  if not CFG.shop.sellEnabled then return msg("THE SHOP IS NOT BUYING", "bad") end
  if not e or e.enabled == false or (tonumber(e.sell) or 0) <= 0 then
    return msg("NOT BOUGHT HERE", "bad")
  end
  qty = math.min(math.floor(tonumber(qty) or 0), avail(e.id))
  if qty <= 0 then return msg("NOTHING TO SELL", "warn") end
  if tellerNbt[e.id] and (e.nbt == nil or e.nbt == "") then
    return msg("DAMAGED/ENCHANTED STACK - NOT ACCEPTED", "bad")
  end
  if (tonumber(e.stockCap) or 0) > 0 then
    refreshStock(true)
    local room = e.stockCap - stockOf(e.id)
    if room <= 0 then return msg("STOCK IS FULL - NOT BUYING", "bad") end
    if qty > room then qty = room; msg("ONLY " .. room .. " ACCEPTED", "warn") end
  end

  jrnSet({ kind = "SELL", id = e.id, want = qty, charged = 0, who = S.name, t = os.epoch("utc") })
  local moved = rsImport(e.id, qty, e.nbt)
  jrnClear()
  if moved <= 0 then return msg("COULD NOT TAKE THE ITEMS", "bad") end

  local pay = sellPrice(e, moved)
  S.bal = S.bal + pay
  logAdd("SELL", S.name, e.id, moved, pay)
  msg("SOLD " .. moved .. "x " .. itemLabel(e) .. " FOR " .. money(pay), "ok")
  touch()
end

local function sellables()
  local out = {}
  if not CFG.shop.sellEnabled then return out end
  for _, e in ipairs(ITEMS) do
    if e.enabled ~= false and (tonumber(e.sell) or 0) > 0 then
      local n = avail(e.id)
      if n > 0 then table.insert(out, { e = e, qty = n, pay = sellPrice(e, n) }) end
    end
  end
  table.sort(out, function(a, b) return a.pay > b.pay end)
  return out
end

local function strangers()
  local out = {}
  for id, n in pairs(tellerCount) do
    local left = avail(id)
    if left > 0 and not unitById(id) then
      local e = itemById(id)
      if not (e and e.enabled ~= false and (tonumber(e.sell) or 0) > 0 and CFG.shop.sellEnabled) then
        table.insert(out, { id = id, qty = left })
      end
    end
  end
  table.sort(out, function(a, b) return a.qty > b.qty end)
  return out
end

local function autoSellPass()
  if not (CFG.shop.sellEnabled and CFG.shop.autoSell) then return end
  for _, s in ipairs(sellables()) do doSell(s.e, s.qty) end
end

local function cashOut(reason)
  if S.bal <= 0 then return false end
  local want, paid = S.bal, 0
  refreshStock(true)
  for _, u in ipairs(unitsDesc()) do
    local n = math.floor(S.bal / (tonumber(u.value) or 1))
    if n > 0 then
      local moved = rsExport(u.id, math.min(n, stockOf(u.id)))
      S.bal = S.bal - moved * u.value
      paid = paid + moved * u.value
    end
  end
  if paid > 0 then logAdd("OUT", S.name, "cash", 0, paid, reason) end
  if S.bal > 0 then
    if S.name and CFG.wallet.enabled and CFG.wallet.autoStore then
      walAdd(S.name, S.bal)
      logAdd("OUT", S.name, "wallet", 0, S.bal, "stored")
      msg("PAID " .. money(paid) .. ", " .. money(S.bal) .. " TO YOUR WALLET", "ok")
      S.bal = 0
    else
      msg("NO CHANGE IN STOCK - " .. money(S.bal) .. " STILL ON THE COUNTER", "warn")
    end
  elseif want > 0 then
    msg("PAID OUT " .. money(paid) .. " - TAKE IT FROM THE BARREL", "ok")
  end
  touch()
  return true
end

local function signOut()
  if S.name and CFG.wallet.enabled and CFG.wallet.autoStore and S.bal > 0 then
    walAdd(S.name, S.bal)
    logAdd("OUT", S.name, "wallet", 0, S.bal, "sign out")
    S.bal = 0
  end
  S.name = nil
end

--==========================================================================
-- DRAW TOOLKIT
--==========================================================================
local BT = {}

local function isColorDev(D)
  local ok, r = pcall(D.isColor)
  if ok then return r end
  return false
end

local function C(D, key)
  local name = (CFG.ui.theme or {})[key] or "white"
  if isColorDev(D) then return colors[name] or colors.white end
  if key == "bg" then return colors.black end
  if key == "fg" or key == "headFg" or key == "btnFg" then return colors.white end
  if key == "dim" then return colors.lightGray end
  return colors.gray
end

local function fill(D, x, y, w, h, bg)
  D.setBackgroundColor(bg)
  local s = string.rep(" ", math.max(0, w))
  for i = 0, h - 1 do
    D.setCursorPos(x, y + i)
    D.write(s)
  end
end

local function put(D, x, y, s, fg, bg)
  if bg then D.setBackgroundColor(bg) end
  if fg then D.setTextColor(fg) end
  D.setCursorPos(x, y)
  D.write(tostring(s))
end

local function center(D, y, s, fg, bg, W)
  local x = math.max(1, math.floor((W - #tostring(s)) / 2) + 1)
  put(D, x, y, s, fg, bg)
end

local function button(D, x, y, w, label, id, bgKey, fgKey)
  local bg, fg = C(D, bgKey or "btn"), C(D, fgKey or "btnFg")
  fill(D, x, y, w, 1, bg)
  local lbl = trunc(label, w)
  put(D, x + math.floor((w - #lbl) / 2), y, lbl, fg, bg)
  table.insert(BT, { x = x, y = y, w = w, h = 1, id = id })
end

local function zone(x, y, w, h, id)
  table.insert(BT, { x = x, y = y, w = w, h = h, id = id })
end

local function hitTest(x, y)
  for i = #BT, 1, -1 do
    local b = BT[i]
    if x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h then return b.id end
  end
  return nil
end

--==========================================================================
-- STOREFRONT
--==========================================================================
local FR, frDev   -- front device + "mon" | "term"

local function categories()
  local seen, list = {}, {}
  for _, e in ipairs(ITEMS) do
    local c = e.cat or "MISC"
    if not seen[c] then seen[c] = true; table.insert(list, c) end
  end
  table.sort(list)
  table.insert(list, 1, "ALL")
  return list
end

local function visibleItems()
  local out = {}
  for _, e in ipairs(ITEMS) do
    local show = CFG.shop.buyEnabled and e.enabled ~= false and (tonumber(e.buy) or 0) > 0
    if show and UI.cat ~= "ALL" and (e.cat or "MISC") ~= UI.cat then show = false end
    if show and UI.filter ~= "" then
      local hay = (itemLabel(e) .. " " .. e.id):lower()
      if not hay:find(UI.filter:lower(), 1, true) then show = false end
    end
    if show and CFG.shop.hideEmpty and freeStock(e) <= 0 then show = false end
    if show then table.insert(out, e) end
  end
  local by = CFG.shop.sortBy
  if by == "label" then
    table.sort(out, function(a, b) return itemLabel(a):lower() < itemLabel(b):lower() end)
  elseif by == "price" then
    table.sort(out, function(a, b) return (tonumber(a.buy) or 0) < (tonumber(b.buy) or 0) end)
  elseif by == "stock" then
    table.sort(out, function(a, b) return freeStock(a) > freeStock(b) end)
  end
  return out
end

local function drawHeader(D, W)
  local hb, hf = C(D, "head"), C(D, "headFg")
  fill(D, 1, 1, W, 1, hb)
  put(D, 2, 1, trunc(CFG.shopName, W - 16), hf, hb)
  local bal = "BAL " .. money(S.bal)
  put(D, W - #bal, 1, bal, C(D, "accent"), hb)

  local bg = C(D, "bg")
  fill(D, 1, 2, W, 1, bg)
  local who
  if S.name then
    who = "USER " .. S.name
    if CFG.wallet.enabled then who = who .. "  WALLET " .. money(walGet(S.name)) end
  elseif CFG.wallet.enabled and det then
    who = "GUEST - SIGN IN FOR A WALLET"
  else
    who = CFG.motd or ""
  end
  put(D, 2, 2, trunc(who, W - 12), C(D, "dim"), bg)
  local st = online and "RS OK" or "RS OFF"
  put(D, W - #st, 2, st, online and C(D, "ok") or C(D, "bad"), bg)
end

local function drawFooter(D, W, H)
  local bg = C(D, "bg")
  fill(D, 1, H - 1, W, 1, bg)
  local n = 4
  local bw = math.floor((W - 1) / n) - 1
  local x = 2
  button(D, x, H - 1, bw, "SELL", "nav:sell"); x = x + bw + 1
  button(D, x, H - 1, bw, "CASH OUT", "nav:cash", S.bal > 0 and "ok" or "btn",
         S.bal > 0 and "bg" or "btnFg"); x = x + bw + 1
  button(D, x, H - 1, bw, CFG.wallet.enabled and "WALLET" or "INFO", "nav:wallet"); x = x + bw + 1
  button(D, x, H - 1, bw, "HELP", "nav:help")

  fill(D, 1, H, W, 1, bg)
  if os.clock() < UI.msgUntil and UI.msg ~= "" then
    put(D, 2, H, trunc(UI.msg, W - 2), C(D, UI.msgKind), bg)
  else
    put(D, 2, H, trunc(CFG.motd or "", W - 2), C(D, "dim"), bg)
  end
end

local function drawCatalog(D, W, H)
  drawHeader(D, W)
  local bg = C(D, "bg")
  local list = visibleItems()
  local top, bottom = 4, H - 3
  local rows = math.max(1, bottom - top + 1)
  local pages = math.max(1, math.ceil(#list / rows))
  UI.page = clamp(UI.page, 1, pages)

  -- category / paging bar
  fill(D, 1, 3, W, 1, bg)
  local cw = math.min(18, math.max(8, math.floor(W / 3)))
  button(D, 2, 3, cw, "CAT " .. trunc(UI.cat, cw - 5), "nav:cats")
  local pinfo = UI.page .. "/" .. pages
  if UI.filter ~= "" and W >= 40 then pinfo = "/" .. trunc(UI.filter, 8) .. " " .. pinfo end
  put(D, W - #pinfo - 8, 3, pinfo, C(D, "dim"), bg)
  button(D, W - 7, 3, 3, "<", "nav:prev")
  button(D, W - 3, 3, 3, ">", "nav:next")

  fill(D, 1, top, W, rows, bg)
  local btnW  = 5
  local priceW = 8
  local stockW = (W >= 42) and 7 or 0
  local labW  = W - 3 - priceW - stockW - btnW - 1

  for i = 1, rows do
    local e = list[(UI.page - 1) * rows + i]
    local y = top + i - 1
    if e then
      local rowBg = bg
      local st = freeStock(e)
      local lab = itemLabel(e)
      if CFG.shop.showId then lab = lab .. " (" .. shortId(e.id) .. ")" end
      put(D, 2, y, pad(lab, labW), st > 0 and C(D, "fg") or C(D, "dim"), rowBg)
      if stockW > 0 then
        put(D, 2 + labW, y, rpad(st > 0 and ("x" .. commify(st)) or "---", stockW),
            st > 0 and C(D, "dim") or C(D, "bad"), rowBg)
      end
      put(D, 2 + labW + stockW, y, rpad(money(buyPrice(e, 1)), priceW), C(D, "accent"), rowBg)
      button(D, W - btnW, y, btnW, st > 0 and "BUY" or "--", st > 0 and ("item:" .. e.id) or "none",
             st > 0 and "btn" or "bg", st > 0 and "btnFg" or "dim")
      zone(2, y, labW + stockW + priceW, 1, "item:" .. e.id)
    end
  end
  if #list == 0 then
    center(D, top + math.floor(rows / 2), "NOTHING ON SALE HERE", C(D, "dim"), bg, W)
  end
  drawFooter(D, W, H)
end

local function qtyButtons(D, y, W, step)
  local wide = W >= 40
  local w = wide and 5 or 4
  if wide then
    button(D, 2, y, w, "-" .. (step * 8), "q:-" .. (step * 8))
    button(D, 2 + w + 1, y, w, "-" .. step, "q:-" .. step)
    button(D, W - w - 1, y, w, "+" .. (step * 8), "q:+" .. (step * 8))
    button(D, W - 2 * w - 2, y, w, "+" .. step, "q:+" .. step)
  else
    button(D, 2, y, w, "-" .. step, "q:-" .. step)
    button(D, W - w - 1, y, w, "+" .. step, "q:+" .. step)
  end
end

local function drawItem(D, W, H)
  drawHeader(D, W)
  local bg = C(D, "bg")
  fill(D, 1, 3, W, H - 4, bg)
  local e = UI.sel and itemById(UI.sel)
  if not e then UI.screen = "catalog"; return end

  local st = freeStock(e)
  local unit = buyPrice(e, 1)
  UI.qty = clamp(UI.qty, 1, math.max(1, math.min(st, tonumber(CFG.shop.maxQty) or 1024)))
  local total = buyPrice(e, UI.qty)

  -- the controls are anchored to the bottom, the description gets what is left
  local qy    = H - 5          -- +/- 1 row
  local info  = {}
  table.insert(info, { trunc(itemLabel(e), W - 2), "accent" })
  table.insert(info, { trunc(e.id, W - 2), "dim" })
  table.insert(info, { "STOCK " .. commify(st), st > 0 and "fg" or "bad" })
  table.insert(info, { "PRICE " .. money(unit) .. " EACH", "fg" })
  if (tonumber(e.sell) or 0) > 0 and CFG.shop.sellEnabled then
    table.insert(info, { "BOUGHT BACK AT " .. money(sellPrice(e, 1)), "dim" })
  end
  for i, l in ipairs(info) do
    local y = 2 + i
    if y <= qy - 2 then put(D, 2, y, l[1], C(D, l[2]), bg) end
  end

  center(D, qy - 1, "QTY  " .. UI.qty, C(D, "accent"), bg, W)
  qtyButtons(D, qy, W, 1)
  qtyButtons(D, qy + 1, W, 16)
  button(D, 2, qy + 2, 6, "MAX", "q:max")
  button(D, 9, qy + 2, 6, "1", "q:=1")
  button(D, W - 13, qy + 2, 12, "TOTAL " .. trunc(money(total), 6), "none", "bg", "accent")

  local half = math.floor(W / 2) - 2
  button(D, 2, H - 2, half, st > 0 and ("BUY " .. UI.qty) or "NO STOCK",
         st > 0 and "do:buy" or "none", st > 0 and "ok" or "btn", st > 0 and "bg" or "dim")
  button(D, math.floor(W / 2) + 1, H - 2, half, "BACK", "nav:back")

  fill(D, 1, H - 1, W, 1, bg)
  put(D, 2, H - 1, "BAL " .. money(S.bal), C(D, "fg"), bg)
  fill(D, 1, H, W, 1, bg)
  if os.clock() < UI.msgUntil then put(D, 2, H, trunc(UI.msg, W - 2), C(D, UI.msgKind), bg) end
end

local function drawSell(D, W, H)
  drawHeader(D, W)
  local bg = C(D, "bg")
  fill(D, 1, 3, W, H - 4, bg)
  put(D, 2, 3, "SELL - PUT ITEMS IN THE BARREL", C(D, "accent"), bg)

  local list = sellables()
  local odd  = strangers()
  local y = 4
  local btnW, payW = 6, 8
  local labW = W - 3 - payW - btnW - 1
  for _, s in ipairs(list) do
    if y > H - 3 then break end
    put(D, 2, y, pad(itemLabel(s.e) .. " x" .. s.qty, labW), C(D, "fg"), bg)
    put(D, 2 + labW, y, rpad(money(s.pay), payW), C(D, "accent"), bg)
    button(D, W - btnW, y, btnW, "SELL", "sell:" .. s.e.id)
    y = y + 1
  end
  if #list == 0 then
    put(D, 2, y, CFG.shop.sellEnabled and "NOTHING THE SHOP BUYS IN THE BARREL"
        or "THE SHOP IS NOT BUYING RIGHT NOW", C(D, "dim"), bg)
    y = y + 1
  end
  if #odd > 0 and y <= H - 3 then
    y = y + 1
    put(D, 2, y, "NOT ACCEPTED - TAKE IT BACK:", C(D, "warn"), bg)
    y = y + 1
    for _, o in ipairs(odd) do
      if y > H - 2 then break end
      put(D, 2, y, trunc(shortId(o.id) .. " x" .. o.qty, W - 2), C(D, "dim"), bg)
      y = y + 1
    end
  end

  local half = math.floor(W / 2) - 2
  if #list > 0 then
    button(D, 2, H - 2, half, "SELL ALL", "sell:*", "ok", "bg")
  end
  button(D, math.floor(W / 2) + 1, H - 2, half, "BACK", "nav:back")
  drawFooter(D, W, H)
end

local function drawWallet(D, W, H)
  drawHeader(D, W)
  local bg = C(D, "bg")
  fill(D, 1, 3, W, H - 4, bg)
  local y = 3
  if not CFG.wallet.enabled or not det then
    put(D, 2, y, "WALLETS ARE OFF", C(D, "warn"), bg); y = y + 1
    put(D, 2, y, det and "ENABLE THEM IN THE ADMIN PANEL"
        or "NO PLAYER DETECTOR ATTACHED", C(D, "dim"), bg)
  elseif not S.name then
    put(D, 2, y, "SIGN IN", C(D, "accent"), bg); y = y + 2
    put(D, 2, y, "RIGHT CLICK THE PLAYER DETECTOR", C(D, "fg"), bg); y = y + 1
    put(D, 2, y, "BLOCK WHILE STANDING NEXT TO IT.", C(D, "fg"), bg); y = y + 2
    put(D, 2, y, "YOUR CREDITS THEN SURVIVE LOGOUT.", C(D, "dim"), bg)
    if os.clock() - UI.signFrom < 30 then
      center(D, H - 4, "WAITING FOR YOUR CLICK...", C(D, "accent"), bg, W)
    else
      button(D, 2, H - 4, 14, "SIGN IN", "wal:signon", "ok", "bg")
    end
  else
    put(D, 2, y, "USER  " .. S.name, C(D, "accent"), bg); y = y + 1
    put(D, 2, y, "WALLET  " .. money(walGet(S.name)), C(D, "fg"), bg); y = y + 1
    put(D, 2, y, "COUNTER " .. money(S.bal), C(D, "fg"), bg); y = y + 2
    put(D, 2, y, "CREDITS MOVE BETWEEN THE TWO.", C(D, "dim"), bg)
    local half = math.floor(W / 2) - 2
    button(D, 2, H - 4, half, "TAKE ALL", "wal:load", "ok", "bg")
    button(D, math.floor(W / 2) + 1, H - 4, half, "STORE ALL", "wal:store")
    button(D, 2, H - 2, half, "SIGN OUT", "wal:signoff", "bad", "btnFg")
    button(D, math.floor(W / 2) + 1, H - 2, half, "BACK", "nav:back")
  end
  if not S.name then
    button(D, math.floor(W / 2) + 1, H - 2, math.floor(W / 2) - 2, "BACK", "nav:back")
  end
  drawFooter(D, W, H)
end

local function drawCats(D, W, H)
  drawHeader(D, W)
  local bg = C(D, "bg")
  fill(D, 1, 3, W, H - 4, bg)
  put(D, 2, 3, "CATEGORY", C(D, "accent"), bg)
  local list = categories()
  local y, col, cw = 5, 2, math.min(20, W - 4)
  for _, c in ipairs(list) do
    if y > H - 3 then break end
    button(D, col, y, cw, c, "cat:" .. c, (c == UI.cat) and "ok" or "btn", (c == UI.cat) and "bg" or "btnFg")
    y = y + 1
  end
  button(D, 2, H - 2, 12, "BACK", "nav:back")
  drawFooter(D, W, H)
end

local function drawHelp(D, W, H)
  drawHeader(D, W)
  local bg = C(D, "bg")
  fill(D, 1, 3, W, H - 4, bg)
  local cur = {}
  for _, u in ipairs(unitsDesc()) do
    table.insert(cur, (u.label or shortId(u.id)) .. "=" .. u.value .. SYM())
  end
  local lines = {
    "HOW IT WORKS",
    "",
    "1. DROP CURRENCY IN THE BARREL.",
    "   " .. trunc(table.concat(cur, "  "), W - 5),
    "2. PICK AN ITEM, SET THE AMOUNT, BUY.",
    "3. TAKE THE GOODS FROM THE BARREL.",
    "4. CASH OUT TO GET CREDITS BACK.",
    "",
    CFG.shop.sellEnabled and "THE SHOP ALSO BUYS ITEMS - USE SELL." or "THE SHOP DOES NOT BUY ITEMS.",
    CFG.wallet.enabled and "SIGN IN TO KEEP CREDITS AFTER LOGOUT." or "",
    "",
    "SHOP v" .. VERSION,
  }
  for i, l in ipairs(lines) do
    if 3 + i <= H - 3 then put(D, 2, 3 + i - 1, trunc(l, W - 2), C(D, "fg"), bg) end
  end
  button(D, 2, H - 2, 12, "BACK", "nav:back")
  drawFooter(D, W, H)
end

local function drawFront()
  if not FR then return end
  BT = {}
  local W, H = FR.getSize()
  if W < 26 or H < 12 then
    FR.setBackgroundColor(colors.black); FR.setTextColor(colors.red); FR.clear()
    FR.setCursorPos(1, 1); FR.write("TOO SMALL")
    FR.setCursorPos(1, 2); FR.write(W .. "x" .. H .. " < 26x12")
    return
  end
  FR.setBackgroundColor(C(FR, "bg"))
  FR.clear()
  local s = UI.screen
  if s == "item" then drawItem(FR, W, H)
  elseif s == "sell" then drawSell(FR, W, H)
  elseif s == "wallet" then drawWallet(FR, W, H)
  elseif s == "cats" then drawCats(FR, W, H)
  elseif s == "help" then drawHelp(FR, W, H)
  else drawCatalog(FR, W, H) end
end

local function drawConsole()
  if FR == term then return end
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  local W, H = term.getSize()
  term.setCursorPos(1, 1)
  term.setBackgroundColor(colors.blue)
  term.write(pad(" SHOP v" .. VERSION .. " - CONSOLE", W))
  term.setBackgroundColor(colors.black)
  local lines = {
    "",
    "storefront : " .. (monName or "terminal"),
    "teller     : " .. (barrelName or "MISSING"),
    "network    : " .. (bridge and (online and "connected" or "no answer") or "NO BRIDGE"),
    "detector   : " .. (det and "yes" or "no"),
    "items      : " .. #ITEMS,
    "counter    : " .. money(S.bal) .. (S.name and ("  (" .. S.name .. ")") or ""),
    "",
    "[A] admin panel   [Q] quit",
  }
  for i, l in ipairs(lines) do
    if i + 1 <= H then term.setCursorPos(2, i + 1); term.write(trunc(l, W - 2)) end
  end
end

--==========================================================================
-- ADMIN PANEL  (terminal only, keyboard)
--==========================================================================
local function aclear(title)
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  local W = term.getSize()
  term.setCursorPos(1, 1)
  term.setBackgroundColor(colors.blue)
  term.write(pad(" ADMIN / " .. tostring(title), W))
  term.setBackgroundColor(colors.black)
  term.setCursorPos(1, 3)
end

local function pr(s, col)
  if col then term.setTextColor(col) end
  print(s or "")
  term.setTextColor(colors.white)
end

local function ask(prompt, default)
  term.setTextColor(colors.yellow)
  write(prompt)
  term.setTextColor(colors.white)
  local v = read(nil, nil, nil, default ~= nil and tostring(default) or nil)
  return v
end

local function askNum(prompt, default)
  local v = ask(prompt .. " [" .. tostring(default) .. "]: ")
  if v == nil or v == "" then return tonumber(default) or 0 end
  return tonumber(v) or (tonumber(default) or 0)
end

local function askStr(prompt, default)
  local v = ask(prompt .. ": ", default)
  if v == nil then return default end
  return v
end

local function askYN(prompt, default)
  local d = default and "y" or "n"
  local v = ask(prompt .. " (y/n) [" .. d .. "]: ")
  if v == nil or v == "" then return default end
  v = v:lower():sub(1, 1)
  return v == "y" or v == "1" or v == "t"
end

local function pause(s)
  term.setTextColor(colors.lightGray)
  print("")
  print(s or "-- press any key --")
  term.setTextColor(colors.white)
  os.pullEvent("key")
end

local function confirmWord(word)
  local v = ask("type " .. word .. " to confirm: ")
  return v == word
end

-- pick one entry from a list of {key=, text=}; returns index or nil
local function picker(title, rows, perPage, extra)
  local page = 1
  while true do
    local pages = math.max(1, math.ceil(#rows / perPage))
    page = clamp(page, 1, pages)
    aclear(title .. "  " .. page .. "/" .. pages)
    for i = 1, perPage do
      local r = rows[(page - 1) * perPage + i]
      if r then
        term.setTextColor(r.col or colors.white)
        print(string.format("%2d) %s", i, trunc(r.text, term.getSize() - 5)))
      end
    end
    if #rows == 0 then pr("(empty)", colors.lightGray) end
    term.setTextColor(colors.lightGray)
    print("")
    print("number=pick  n/p=page  " .. (extra or "") .. "q=back")
    term.setTextColor(colors.white)
    write("> ")
    local v = read()
    if v == "q" or v == nil then return nil end
    if v == "n" then page = page + 1
    elseif v == "p" then page = page - 1
    elseif extra and v ~= "" and v:match("^%a$") then return nil, v
    else
      local n = tonumber(v)
      if n and rows[(page - 1) * perPage + n] then
        return (page - 1) * perPage + n
      end
    end
  end
end

--------------------------------------------------------------------------
-- item editing
--------------------------------------------------------------------------
local function itemSummary(e)
  local parts = {}
  table.insert(parts, pad(itemLabel(e), 18))
  table.insert(parts, pad(e.cat or "MISC", 10))
  table.insert(parts, "buy " .. rpad((tonumber(e.buy) or 0) > 0 and tostring(e.buy) or "-", 6))
  table.insert(parts, "sell " .. rpad((tonumber(e.sell) or 0) > 0 and tostring(e.sell) or "-", 6))
  table.insert(parts, e.enabled == false and "OFF" or "on")
  return table.concat(parts, " ")
end

local function editItem(idx)
  while true do
    local e = ITEMS[idx]
    if not e then return end
    aclear("ITEM " .. idx .. " / " .. #ITEMS)
    pr(itemLabel(e), colors.yellow)
    pr(e.id, colors.lightGray)
    pr("in network: " .. commify(stockOf(e.id)), colors.lightGray)
    print("")
    pr("1 label        " .. tostring(e.label or "-"))
    pr("2 category     " .. tostring(e.cat or "MISC"))
    pr("3 buy price    " .. tostring(e.buy or 0) .. "  (0 = not sold)")
    pr("4 sell price   " .. tostring(e.sell or 0) .. "  (0 = not bought)")
    pr("5 reserve      " .. tostring(e.reserve or 0) .. "  (keep in network)")
    pr("6 order limit  " .. tostring(e.limit or 0) .. "  (0 = no limit)")
    pr("7 stock cap    " .. tostring(e.stockCap or 0) .. "  (stop buying above)")
    pr("8 enabled      " .. tostring(e.enabled ~= false))
    pr("9 nbt hash     " .. tostring(e.nbt or "-"))
    print("")
    pr("u/d move  x delete  q back", colors.lightGray)
    write("> ")
    local v = read()
    if v == "q" or v == nil then return end
    if v == "1" then e.label = askStr("label", itemLabel(e))
    elseif v == "2" then e.cat = askStr("category", e.cat or "MISC")
    elseif v == "3" then e.buy = askNum("buy price per item", e.buy or 0)
    elseif v == "4" then e.sell = askNum("sell price per item", e.sell or 0)
    elseif v == "5" then e.reserve = math.floor(askNum("reserve", e.reserve or 0))
    elseif v == "6" then e.limit = math.floor(askNum("order limit", e.limit or 0))
    elseif v == "7" then e.stockCap = math.floor(askNum("stock cap", e.stockCap or 0))
    elseif v == "8" then e.enabled = (e.enabled == false)
    elseif v == "9" then
      local s = askStr("nbt hash (empty = any)", e.nbt or "")
      e.nbt = (s ~= "") and s or nil
    elseif v == "u" and idx > 1 then
      ITEMS[idx], ITEMS[idx - 1] = ITEMS[idx - 1], ITEMS[idx]; idx = idx - 1
    elseif v == "d" and idx < #ITEMS then
      ITEMS[idx], ITEMS[idx + 1] = ITEMS[idx + 1], ITEMS[idx]; idx = idx + 1
    elseif v == "x" then
      if askYN("delete " .. itemLabel(e) .. "?", false) then
        table.remove(ITEMS, idx); saveItems(); return
      end
    end
    if (tonumber(e.sell) or 0) > 0 and (tonumber(e.buy) or 0) > 0
       and (tonumber(e.sell) or 0) >= (tonumber(e.buy) or 0) then
      pr("WARNING: sell >= buy, players can farm credits!", colors.red)
      pause()
    end
    saveItems()
  end
end

local function newEntry(id, label, cat, buy, sell)
  return { id = id, label = label, cat = cat or "MISC", buy = buy or 0, sell = sell or 0,
           reserve = 0, limit = 0, stockCap = 0, enabled = true }
end

local function addFlow(id, defLabel)
  local e = itemById(id)
  if e then
    pr("already in the catalog - editing it", colors.orange)
    pause()
    local _, i = itemById(id)
    return editItem(i)
  end
  print("")
  pr(id, colors.lightGray)
  local label = askStr("label", defLabel or shortId(id))
  local cat   = askStr("category", "MISC")
  local buy   = askNum("buy price per item (0 = not sold)", 0)
  local sell  = askNum("sell price per item (0 = not bought)", 0)
  table.insert(ITEMS, newEntry(id, label, cat, buy, sell))
  saveItems()
  pr("added " .. label, colors.lime)
  pause()
end

local function pageItems()
  while true do
    local rows = {}
    for i, e in ipairs(ITEMS) do
      rows[i] = { text = itemSummary(e), col = (e.enabled == false) and colors.gray or colors.white }
    end
    local idx, letter = picker("ITEMS (" .. #ITEMS .. ")", rows, 10, "a=add  ")
    if letter == "a" then
      aclear("ADD ITEM BY ID")
      local id = askStr("item id (e.g. minecraft:iron_ingot)", "minecraft:")
      if id and id ~= "" and id ~= "minecraft:" then addFlow(id) end
    elseif idx then editItem(idx)
    else return end
  end
end

local function netRows(filter)
  refreshStock(true)
  local rows = {}
  for id, n in pairs(stockMap) do
    local label = nameMap[id] or shortId(id)
    if filter == "" or (label .. " " .. id):lower():find(filter:lower(), 1, true) then
      table.insert(rows, { id = id, label = label, n = n })
    end
  end
  table.sort(rows, function(a, b) return a.n > b.n end)
  return rows
end

local function pageAddFromNet()
  aclear("ADD FROM THE NETWORK")
  if not bridge then pr("no bridge attached", colors.red); return pause() end
  local filter = askStr("search (empty = everything)", "")
  local data = netRows(filter or "")
  if #data == 0 then pr("nothing matched", colors.orange); return pause() end
  local rows = {}
  for i, d in ipairs(data) do
    rows[i] = { text = pad(d.label, 24) .. " x" .. commify(d.n) }
  end
  while true do
    local idx, letter = picker("NETWORK (" .. #rows .. ")", rows, 10, "b=bulk add all  ")
    if letter == "b" then
      aclear("BULK ADD " .. #data .. " ITEMS")
      local cat  = askStr("category for all", filter ~= "" and filter:upper() or "MISC")
      local buy  = askNum("buy price per item", 0)
      local sell = askNum("sell price per item", 0)
      if askYN("add " .. #data .. " items?", false) then
        local added = 0
        for _, d in ipairs(data) do
          if not itemById(d.id) then
            table.insert(ITEMS, newEntry(d.id, d.label, cat, buy, sell))
            added = added + 1
          end
        end
        saveItems()
        pr("added " .. added, colors.lime)
        pause()
      end
      return
    elseif idx then
      aclear("ADD " .. data[idx].label)
      addFlow(data[idx].id, data[idx].label)
    else return end
  end
end

local function pageAddFromBarrel()
  aclear("ADD FROM THE BARREL")
  if not barrel then pr("no barrel attached", colors.red); return pause() end
  scanTeller()
  local data = {}
  local ok, list = pcall(barrel.list)
  if ok and type(list) == "table" then
    local seen = {}
    for slot, st in pairs(list) do
      if st and st.name and not seen[st.name] then
        seen[st.name] = true
        local label = nameMap[st.name]
        local ok2, d = pcall(barrel.getItemDetail, slot)
        if ok2 and type(d) == "table" and d.displayName then label = d.displayName end
        table.insert(data, { id = st.name, label = label or shortId(st.name),
                             n = tellerCount[st.name] or st.count })
      end
    end
  end
  if #data == 0 then pr("the barrel is empty", colors.orange); return pause() end
  local rows = {}
  for i, d in ipairs(data) do rows[i] = { text = pad(d.label, 24) .. " x" .. d.n } end
  local idx = picker("IN THE BARREL", rows, 10)
  if idx then
    aclear("ADD " .. data[idx].label)
    addFlow(data[idx].id, data[idx].label)
  end
end

--------------------------------------------------------------------------
-- currency
--------------------------------------------------------------------------
local function pageCurrency()
  while true do
    local rows = {}
    for i, u in ipairs(CFG.currency.units) do
      rows[i] = { text = pad(u.label or shortId(u.id), 18) .. " = " .. (u.value or 0) .. SYM()
                  .. "   " .. trunc(u.id, 22) }
    end
    local idx, letter = picker("CURRENCY (symbol " .. SYM() .. ")", rows, 8, "a=add  s=symbol  ")
    if letter == "a" then
      aclear("NEW CURRENCY UNIT")
      local id = askStr("item id", "minecraft:")
      if id and id ~= "" then
        local label = askStr("label", shortId(id))
        local val = askNum("credits per item", 1)
        table.insert(CFG.currency.units, { id = id, label = label, value = val })
        saveCfg()
      end
    elseif letter == "s" then
      CFG.currency.symbol = askStr("credit symbol", SYM())
      saveCfg()
    elseif idx then
      local u = CFG.currency.units[idx]
      aclear("UNIT " .. (u.label or ""))
      pr(u.id, colors.lightGray)
      print("")
      pr("1 label   " .. tostring(u.label))
      pr("2 value   " .. tostring(u.value))
      pr("3 item id " .. tostring(u.id))
      pr("x delete   q back", colors.lightGray)
      write("> ")
      local v = read()
      if v == "1" then u.label = askStr("label", u.label)
      elseif v == "2" then u.value = askNum("credits per item", u.value)
      elseif v == "3" then u.id = askStr("item id", u.id)
      elseif v == "x" then
        if #CFG.currency.units <= 1 then
          pr("you need at least one currency unit", colors.red); pause()
        elseif askYN("delete?", false) then table.remove(CFG.currency.units, idx) end
      end
      saveCfg()
    else return end
  end
end

--------------------------------------------------------------------------
-- settings pages
--------------------------------------------------------------------------
local function pageRules()
  while true do
    aclear("SHOP RULES")
    local s = CFG.shop
    pr("1 selling to players   " .. tostring(s.buyEnabled))
    pr("2 buying from players  " .. tostring(s.sellEnabled))
    pr("3 auto buy on drop     " .. tostring(s.autoSell))
    pr("4 buy tax %            " .. tostring(s.buyTax))
    pr("5 sell fee %           " .. tostring(s.sellFee))
    pr("6 max qty per order    " .. tostring(s.maxQty))
    pr("7 sort by              " .. tostring(s.sortBy))
    pr("8 hide empty rows      " .. tostring(s.hideEmpty))
    pr("9 show item ids        " .. tostring(s.showId))
    print("")
    pr("q back", colors.lightGray)
    write("> ")
    local v = read()
    if v == "q" or v == nil then saveCfg(); return end
    if v == "1" then s.buyEnabled = not s.buyEnabled
    elseif v == "2" then s.sellEnabled = not s.sellEnabled
    elseif v == "3" then s.autoSell = not s.autoSell
    elseif v == "4" then s.buyTax = askNum("buy tax %", s.buyTax)
    elseif v == "5" then s.sellFee = askNum("sell fee %", s.sellFee)
    elseif v == "6" then s.maxQty = math.floor(askNum("max qty", s.maxQty))
    elseif v == "7" then
      local o = { label = "price", price = "stock", stock = "custom", custom = "label" }
      s.sortBy = o[s.sortBy] or "label"
    elseif v == "8" then s.hideEmpty = not s.hideEmpty
    elseif v == "9" then s.showId = not s.showId end
    saveCfg()
  end
end

local function pageInterface()
  while true do
    aclear("INTERFACE")
    local u = CFG.ui
    pr("1 shop name      " .. tostring(CFG.shopName))
    pr("2 bottom line    " .. trunc(tostring(CFG.motd), 30))
    pr("3 monitor scale  " .. tostring(u.monScale))
    pr("4 stock refresh  " .. tostring(u.stockTTL) .. "s")
    pr("5 scan period    " .. tostring(u.tick) .. "s")
    pr("6 idle cash out  " .. tostring(u.idle) .. "s")
    pr("7 sounds         " .. tostring(u.sounds))
    pr("8 colors")
    pr("9 wallets        " .. tostring(CFG.wallet.enabled)
       .. (det and "" or "  (no detector!)"))
    print("")
    pr("q back", colors.lightGray)
    write("> ")
    local v = read()
    if v == "q" or v == nil then saveCfg(); bindPeripherals(); return end
    if v == "1" then CFG.shopName = askStr("shop name", CFG.shopName)
    elseif v == "2" then CFG.motd = askStr("bottom line", CFG.motd)
    elseif v == "3" then
      u.monScale = clamp(askNum("monitor text scale (0.5..5)", u.monScale), 0.5, 5)
      if mon then pcall(mon.setTextScale, u.monScale) end
    elseif v == "4" then u.stockTTL = askNum("stock refresh seconds", u.stockTTL)
    elseif v == "5" then u.tick = clamp(askNum("scan period seconds", u.tick), 0.2, 10)
    elseif v == "6" then u.idle = askNum("idle cash out seconds (0 = never)", u.idle)
    elseif v == "7" then u.sounds = not u.sounds
    elseif v == "8" then
      while true do
        aclear("COLORS")
        local keys = { "bg", "fg", "head", "headFg", "btn", "btnFg", "ok", "warn", "bad", "accent", "dim" }
        for i, k in ipairs(keys) do pr(i .. " " .. pad(k, 8) .. " " .. tostring(u.theme[k])) end
        print("")
        pr("q back   (names: white orange magenta lightBlue yellow lime", colors.lightGray)
        pr(" pink gray lightGray cyan purple blue brown green red black)", colors.lightGray)
        write("> ")
        local c = read()
        if c == "q" or c == nil then break end
        local n = tonumber(c)
        if n and keys[n] then
          local name = askStr("color for " .. keys[n], u.theme[keys[n]])
          if colors[name] then u.theme[keys[n]] = name
          else pr("unknown color", colors.red); pause() end
        end
      end
    elseif v == "9" then
      CFG.wallet.enabled = not CFG.wallet.enabled
      if CFG.wallet.enabled then
        CFG.wallet.range = askNum("detector range", CFG.wallet.range)
        CFG.wallet.autoStore = askYN("park leftovers in the wallet?", CFG.wallet.autoStore)
      end
    end
    saveCfg()
  end
end

--------------------------------------------------------------------------
-- wallets / log / tools
--------------------------------------------------------------------------
local function pageWallets()
  while true do
    local names = {}
    for n in pairs(WAL) do table.insert(names, n) end
    table.sort(names, function(a, b) return walGet(a) > walGet(b) end)
    local rows = {}
    for i, n in ipairs(names) do rows[i] = { text = pad(n, 20) .. money(walGet(n)) } end
    local idx, letter = picker("WALLETS (" .. #names .. ")", rows, 10, "a=add credits  ")
    if letter == "a" then
      aclear("GRANT CREDITS")
      local n = askStr("player name", "")
      if n ~= "" then
        local amt = askNum("credits to add", 0)
        walAdd(n, amt)
        logAdd("ADM", n, "wallet", 0, amt, "granted")
        pr("wallet of " .. n .. " = " .. money(walGet(n)), colors.lime)
        pause()
      end
    elseif idx then
      local n = names[idx]
      aclear("WALLET " .. n)
      pr("balance " .. money(walGet(n)), colors.yellow)
      print("")
      pr("1 add credits")
      pr("2 take credits")
      pr("3 zero it")
      pr("q back", colors.lightGray)
      write("> ")
      local v = read()
      if v == "1" then walAdd(n, askNum("add", 0))
      elseif v == "2" then walAdd(n, -askNum("take", 0))
      elseif v == "3" then
        if askYN("zero the wallet of " .. n .. "?", false) then
          logAdd("ADM", n, "wallet", 0, -walGet(n), "zeroed")
          WAL[n] = nil; saveWal()
        end
      end
    else return end
  end
end

local function pageLog()
  local page = 1
  while true do
    local W, H = term.getSize()
    local per = H - 8
    local n = #LOGD.entries
    local pages = math.max(1, math.ceil(n / per))
    page = clamp(page, 1, pages)
    aclear("LOG " .. page .. "/" .. pages)
    local st = LOGD.stats
    pr("sold " .. st.buys .. " orders / earned " .. money(st.revenue)
       .. "   bought " .. st.sells .. " / paid " .. money(st.paid), colors.lightGray)
    pr("credits in " .. money(st.credIn) .. "   out " .. money(st.credOut), colors.lightGray)
    print("")
    for i = 1, per do
      local e = LOGD.entries[n - ((page - 1) * per + i) + 1]
      if e then
        local col = colors.white
        if e.kind == "BUY" then col = colors.lime
        elseif e.kind == "SELL" then col = colors.orange
        elseif e.kind == "FIX" or e.kind == "ADM" then col = colors.red end
        local line = stamp(e.t) .. " " .. pad(e.kind, 5) .. pad(e.who or "-", 12)
          .. pad(shortId(e.id), 14) .. rpad((e.qty or 0) > 0 and ("x" .. e.qty) or "", 6)
          .. " " .. money(e.amt or 0)
        term.setTextColor(col)
        print(trunc(line .. (e.note and ("  " .. e.note) or ""), W))
        term.setTextColor(colors.white)
      end
    end
    pr("n/p page   c=clear   q=back", colors.lightGray)
    write("> ")
    local v = read()
    if v == "q" or v == nil then return end
    if v == "n" then page = page + 1
    elseif v == "p" then page = page - 1
    elseif v == "c" and askYN("clear the log?", false) then
      LOGD.entries = {}; saveLog()
    end
  end
end

local function exportCatalog()
  local path = DIR .. "/catalog.txt"
  local f = fs.open(path, "w")
  if not f then return false end
  f.writeLine("# id;label;category;buy;sell   -- edit and use IMPORT")
  for _, e in ipairs(ITEMS) do
    f.writeLine(table.concat({ e.id, itemLabel(e), e.cat or "MISC",
                               tostring(e.buy or 0), tostring(e.sell or 0) }, ";"))
  end
  f.close()
  return path
end

local function importCatalog(path, replace)
  if not fs.exists(path) then return nil, "no file " .. path end
  local f = fs.open(path, "r")
  local added, updated = 0, 0
  if replace then ITEMS = {} end
  while true do
    local line = f.readLine()
    if not line then break end
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local p = {}
      for chunk in (line .. ";"):gmatch("([^;]*);") do table.insert(p, chunk) end
      local id = p[1]
      if id and id ~= "" then
        local e = itemById(id)
        if e then
          e.label = (p[2] ~= "" and p[2]) or e.label
          e.cat   = (p[3] ~= "" and p[3]) or e.cat
          e.buy   = tonumber(p[4]) or e.buy
          e.sell  = tonumber(p[5]) or e.sell
          updated = updated + 1
        else
          table.insert(ITEMS, newEntry(id, (p[2] ~= "" and p[2]) or shortId(id),
                                       (p[3] ~= "" and p[3]) or "MISC",
                                       tonumber(p[4]) or 0, tonumber(p[5]) or 0))
          added = added + 1
        end
      end
    end
  end
  f.close()
  saveItems()
  return added, updated
end

local RUN = true

local function pageTools()
  while true do
    aclear("MAINTENANCE")
    pr("1 rescan peripherals")
    pr("2 teller peripheral   " .. tostring(CFG.barrelName) .. "  (now: " .. tostring(barrelName) .. ")")
    pr("3 bulk price change")
    pr("4 export catalog to " .. DIR .. "/catalog.txt")
    pr("5 import catalog from a file")
    pr("6 change PIN")
    pr("7 log size            " .. tostring(CFG.admin.logSize))
    pr("8 wipe catalog")
    pr("9 factory reset")
    pr("r reboot computer     x quit the program")
    print("")
    pr("q back", colors.lightGray)
    write("> ")
    local v = read()
    if v == "q" or v == nil then return end
    if v == "1" then
      bindPeripherals(); refreshStock(true)
      pr("bridge " .. tostring(bridge ~= nil) .. "  barrel " .. tostring(barrelName)
         .. "  monitor " .. tostring(monName) .. "  detector " .. tostring(det ~= nil), colors.lime)
      pause()
    elseif v == "2" then
      local names = { "auto" }
      for _, n in ipairs(peripheral.getNames()) do
        if isType(n, "inventory") then table.insert(names, n) end
      end
      local rows = {}
      for i, n in ipairs(names) do rows[i] = { text = n } end
      local idx = picker("TELLER PERIPHERAL", rows, 10)
      if idx then
        CFG.barrelName = names[idx]; saveCfg(); bindPeripherals()
        pr("teller = " .. tostring(barrelName), colors.lime); pause()
      end
    elseif v == "3" then
      aclear("BULK PRICE CHANGE")
      local cat = askStr("category (empty = all)", "")
      local kb = askNum("multiply BUY prices by", 1)
      local ks = askNum("multiply SELL prices by", 1)
      local n = 0
      for _, e in ipairs(ITEMS) do
        if cat == "" or (e.cat or "MISC") == cat then
          if (tonumber(e.buy) or 0) > 0 then
            e.buy = tonumber(string.format("%.2f", e.buy * kb)) or e.buy
          end
          if (tonumber(e.sell) or 0) > 0 then
            e.sell = tonumber(string.format("%.2f", e.sell * ks)) or e.sell
          end
          n = n + 1
        end
      end
      saveItems()
      pr(n .. " items repriced", colors.lime); pause()
    elseif v == "4" then
      local p = exportCatalog()
      pr(p and ("written " .. p) or "failed", p and colors.lime or colors.red); pause()
    elseif v == "5" then
      aclear("IMPORT CATALOG")
      pr("lines of  id;label;category;buy;sell", colors.lightGray)
      local p = askStr("file", DIR .. "/catalog.txt")
      local rep = askYN("replace the whole catalog?", false)
      local a, u = importCatalog(p, rep)
      if a then pr("added " .. a .. ", updated " .. u, colors.lime)
      else pr(tostring(u), colors.red) end
      pause()
    elseif v == "6" then
      local p1 = ask("new PIN: ")
      if p1 and p1 ~= "" then
        if ask("repeat: ") == p1 then CFG.admin.pin = p1; saveCfg(); pr("PIN changed", colors.lime)
        else pr("they do not match", colors.red) end
      end
      pause()
    elseif v == "7" then
      CFG.admin.logSize = math.floor(askNum("log size", CFG.admin.logSize)); saveCfg()
    elseif v == "8" then
      if confirmWord("WIPE") then ITEMS = {}; saveItems(); pr("catalog cleared", colors.lime); pause() end
    elseif v == "9" then
      if confirmWord("RESET") then
        fs.delete(F_CFG); fs.delete(F_ITEM)
        loadCfg(); bindPeripherals()
        pr("defaults restored (wallets kept)", colors.lime); pause()
      end
    elseif v == "r" then
      if askYN("reboot?", false) then os.reboot() end
    elseif v == "x" then
      if askYN("quit the shop program?", false) then RUN = false; return end
    end
  end
end

local function adminMain()
  while true do
    aclear("v" .. VERSION)
    refreshStock(false)
    pr(CFG.shopName, colors.yellow)
    pr("items " .. #ITEMS .. "   network " .. (online and "ok" or "OFFLINE")
       .. "   teller " .. tostring(barrelName), colors.lightGray)
    pr("earned " .. money(LOGD.stats.revenue) .. "   paid out " .. money(LOGD.stats.paid),
       colors.lightGray)
    print("")
    pr("1 items & prices")
    pr("2 add from the network")
    pr("3 add from the barrel")
    pr("4 currency")
    pr("5 shop rules")
    pr("6 interface & wallets")
    pr("7 wallets")
    pr("8 log & stats")
    pr("9 maintenance")
    print("")
    pr("0 back to the shop", colors.lightGray)
    write("> ")
    local v = read()
    if v == "0" or v == "q" or v == nil then return end
    if v == "1" then pageItems()
    elseif v == "2" then pageAddFromNet()
    elseif v == "3" then pageAddFromBarrel()
    elseif v == "4" then pageCurrency()
    elseif v == "5" then pageRules()
    elseif v == "6" then pageInterface()
    elseif v == "7" then pageWallets()
    elseif v == "8" then pageLog()
    elseif v == "9" then pageTools(); if not RUN then return end end
  end
end

local function adminGate()
  aclear("LOCKED")
  pr("PIN required", colors.lightGray)
  print("")
  write("PIN: ")
  local p = read("*")
  if p ~= tostring(CFG.admin.pin) then
    pr("wrong PIN", colors.red)
    logAdd("ADM", "-", "login", 0, 0, "wrong pin")
    sleep(1.5)
    return false
  end
  return true
end

--==========================================================================
-- FRONT EVENTS
--==========================================================================
local function walletOn()
  return CFG.wallet.enabled and det ~= nil
end

local function handleFront(id)
  if not id or id == "none" then return end
  touch()
  beep(14)
  local kind, arg = id:match("^([%a]+):(.*)$")
  if not kind then return end

  if kind == "nav" then
    if arg == "sell" then UI.screen = "sell"
    elseif arg == "cash" then
      if S.bal <= 0 then msg("NOTHING TO CASH OUT", "warn") else cashOut("counter") end
    elseif arg == "wallet" then UI.screen = "wallet"; UI.signFrom = 0
    elseif arg == "help" then UI.screen = "help"
    elseif arg == "cats" then UI.screen = "cats"
    elseif arg == "prev" then UI.page = UI.page - 1
    elseif arg == "next" then UI.page = UI.page + 1
    elseif arg == "back" then UI.screen = "catalog" end

  elseif kind == "cat" then
    UI.cat = arg; UI.page = 1; UI.screen = "catalog"

  elseif kind == "item" then
    local e = itemById(arg)
    if e then
      UI.sel = arg
      UI.qty = 1
      UI.screen = "item"
      refreshStock(true)
    end

  elseif kind == "q" then
    local e = UI.sel and itemById(UI.sel)
    if not e then return end
    if arg == "max" then
      local top = math.min(freeStock(e), tonumber(CFG.shop.maxQty) or 1024)
      local afford = maxAffordable(e)
      UI.qty = math.max(1, math.min(top, afford > 0 and afford or top))
      if afford <= 0 then msg("NO CREDITS - DROP CURRENCY IN THE BARREL", "warn") end
    elseif arg == "=1" then UI.qty = 1
    else
      local d = tonumber(arg)
      if d then UI.qty = math.max(1, UI.qty + d) end
    end

  elseif kind == "do" then
    if arg == "buy" then
      local e = UI.sel and itemById(UI.sel)
      if e then doBuy(e, UI.qty) end
    end

  elseif kind == "sell" then
    if arg == "*" then
      local list = sellables()
      if #list == 0 then msg("NOTHING TO SELL", "warn") end
      for _, s in ipairs(list) do doSell(s.e, s.qty) end
    else
      local e = itemById(arg)
      if e then doSell(e, avail(e.id)) end
    end
    scanTeller()

  elseif kind == "wal" then
    if not walletOn() then msg("WALLETS ARE OFF", "bad"); return end
    if arg == "signon" then
      UI.signFrom = os.clock()
      msg("RIGHT CLICK THE PLAYER DETECTOR", "accent")
    elseif arg == "signoff" then
      signOut(); msg("SIGNED OUT", "ok"); UI.screen = "catalog"
    elseif arg == "load" then
      local w = walGet(S.name)
      if w <= 0 then msg("YOUR WALLET IS EMPTY", "warn")
      else
        walAdd(S.name, -w); S.bal = S.bal + w
        logAdd("WAL", S.name, "load", 0, w)
        msg("TOOK " .. money(w) .. " FROM THE WALLET", "ok")
      end
    elseif arg == "store" then
      if S.bal <= 0 then msg("NOTHING ON THE COUNTER", "warn")
      else
        walAdd(S.name, S.bal)
        logAdd("WAL", S.name, "store", 0, S.bal)
        msg("STORED " .. money(S.bal), "ok")
        S.bal = 0
      end
    end
  end
end

local function handleSign(name)
  if not walletOn() then return end
  if UI.screen ~= "wallet" then
    if not S.name then msg("PRESS WALLET ON THE SCREEN TO SIGN IN", "accent") end
    return
  end
  local dt = os.clock() - UI.signFrom
  if dt < 0.25 or dt > 60 then return end          -- stale or queued click
  if os.clock() - S.signAt < (tonumber(CFG.wallet.signCooldown) or 2) then return end
  local ok, near = pcall(det.isPlayerInRange, tonumber(CFG.wallet.range) or 8, name)
  if not (ok and near) then
    msg("STAND CLOSER TO THE DETECTOR", "warn")
    return
  end
  if S.name and S.name ~= name then signOut() end
  S.name = name
  S.signAt = os.clock()
  UI.signFrom = 0
  touch()
  msg("WELCOME, " .. name .. "  WALLET " .. money(walGet(name)), "ok")
end

local function closedScreen(text)
  if not mon then return end
  local W, H = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.orange)
  mon.clear()
  local y = math.max(1, math.floor(H / 2))
  mon.setCursorPos(math.max(1, math.floor((W - #text) / 2) + 1), y)
  mon.write(text)
end

local function enterAdmin()
  local hadSession = S.bal > 0
  if hadSession then cashOut("admin") end
  closedScreen("CLOSED - BACK SOON")
  local ok = adminGate()
  if ok then
    logAdd("ADM", "-", "login", 0, 0, "panel opened")
    local good, err = pcall(adminMain)
    if not good then
      aclear("ERROR")
      pr(tostring(err), colors.red)
      pause()
    end
  end
  saveCfg(); saveItems()
  bindPeripherals()
  FR = mon or term
  frDev = mon and "mon" or "term"
  UI.screen = "catalog"
  refreshStock(true)
end

--==========================================================================
-- BOOT / MAIN LOOP
--==========================================================================
local function boot()
  loadCfg()
  if not fs.exists(F_CFG) then saveCfg() end
  bindPeripherals()
  jrnRecover()
  FR = mon or term
  frDev = mon and "mon" or "term"
  S.lastAct = os.clock()
  refreshStock(true)
  scanTeller()
  -- anything already lying in the barrel belongs to somebody: do not swallow it
  local left = 0
  for id, n in pairs(tellerCount) do
    protect[id] = n
    left = left + n
  end
  if left > 0 then msg("ITEMS LEFT IN THE BARREL - TAKE THEM OR DROP AGAIN", "warn") end
  if not bridge then msg("NO RS/ME BRIDGE FOUND - CHECK THE WIRING", "bad") end
  if not barrel then msg("NO TELLER INVENTORY FOUND", "bad") end
end

local function shutdown()
  cashOut("shutdown")
  if mon then
    mon.setBackgroundColor(colors.black); mon.setTextColor(colors.white); mon.clear()
    local W, H = mon.getSize()
    mon.setCursorPos(1, 1); mon.write(trunc("SHOP OFFLINE", W))
  end
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  print("shop v" .. VERSION .. " stopped.")
end

local function main()
  boot()
  drawFront(); drawConsole()
  local tick = os.startTimer(tonumber(CFG.ui.tick) or 0.5)

  while RUN do
    local e = { os.pullEventRaw() }
    local ev = e[1]
    local redraw = true

    if ev == "terminate" then
      RUN = false
      redraw = false

    elseif ev == "timer" and e[2] == tick then
      tick = os.startTimer(tonumber(CFG.ui.tick) or 0.5)
      scanTeller()
      depositCurrency()
      scanTeller()
      autoSellPass()
      refreshStock(false)
      local idle = tonumber(CFG.ui.idle) or 0
      if idle > 0 and (S.bal > 0 or S.name) and (os.clock() - S.lastAct) > idle then
        if S.bal > 0 then cashOut("idle") end
        signOut()
        UI.screen = "catalog"; UI.cat = "ALL"; UI.page = 1; UI.filter = ""
      end

    elseif ev == "monitor_touch" and frDev == "mon" and e[2] == monName then
      handleFront(hitTest(e[3], e[4]))

    elseif ev == "mouse_click" and frDev == "term" then
      handleFront(hitTest(e[3], e[4]))

    elseif ev == "playerClick" then
      handleSign(e[2])

    elseif ev == "key" then
      local k = e[2]
      if k == keys.f1 then
        enterAdmin()
      elseif frDev == "term" then
        if k == keys.tab then
          local W, H = term.getSize()
          term.setCursorPos(2, H); term.setBackgroundColor(colors.black)
          term.setTextColor(colors.yellow); term.write("SEARCH: ")
          term.setTextColor(colors.white)
          UI.filter = read() or ""
          UI.page = 1
          touch()
        elseif k == keys.backspace then
          UI.filter = ""; UI.page = 1
        end
      end

    elseif ev == "char" and frDev == "mon" then
      local c = e[2]:lower()
      if c == "a" then enterAdmin()
      elseif c == "q" then RUN = false; redraw = false end

    elseif ev == "peripheral" or ev == "peripheral_detach" then
      bindPeripherals()
      FR = mon or term
      frDev = mon and "mon" or "term"
      refreshStock(true)

    elseif ev == "monitor_resize" or ev == "term_resize" then
      -- just redraw

    else
      redraw = false
    end

    if redraw and RUN then
      local okDraw, err = pcall(drawFront)
      if not okDraw then
        term.setCursorPos(1, 1); term.setTextColor(colors.red)
        print("draw error: " .. tostring(err))
      end
      pcall(drawConsole)
    end
  end

  shutdown()
end

local ok, err = pcall(main)
if not ok then
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.red)
  term.clear()
  term.setCursorPos(1, 1)
  print("SHOP CRASHED:")
  print(tostring(err))
  print("")
  term.setTextColor(colors.white)
  print("credits on the counter: " .. tostring(S.bal))
  print("run the program again to continue.")
end
