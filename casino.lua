--========================================================================
--  LUCKY BARREL CASINO   v1.7.0   (VERSION below is authoritative)
--  Single-file casino for CC:Tweaked: slots, mega slots, roulette, wheel,
--  blackjack, poker, hi-lo, double x2 - plus a player MARKET.
--
--  HARDWARE
--    * 1 computer (advanced recommended - colours + mouse)
--    * TELLER barrel (outer)  - the only one players can reach.
--                               They insert money here AND collect wins here.
--    * BANK (inner)           - where all money is stored and every payout
--                               is pulled from. Either a plain inventory,
--                               or a Refined Storage network reached via an
--                               Advanced Peripherals RS Bridge.
--    * optional speaker (sounds), optional monitor (advanced = colours)
--    * Advanced Peripherals PLAYER DETECTOR - needed for the MARKET,
--      placed where players can right-click it next to the terminal
--    Attach with wired modems (recommended) or place directly touching
--    the computer.
--
--  HOW THE MONEY MOVES
--    insert -> TELLER -> swept into BANK -> credits appear on screen
--    CASH OUT -> pulled from BANK -> TELLER -> player takes it out
--    Credits are only granted AFTER the items are safely in the BANK,
--    so nobody can insert, get credits and take the items back.
--    After a payout the machine waits (CFG.collectTimeout) for the player
--    to empty the TELLER. If they walk away, the payout is swept back in
--    and returned to their credit balance - nothing is ever lost.
--
--    To refill the house, put items straight into the BANK (the barrel,
--    or anywhere in the RS network when the bank is an RS Bridge).
--
--  MARKET
--    Player-to-player trading. A seller puts goods in the TELLER and lists
--    them; the goods are escrowed in the BANK. Buyers pay credits, the
--    goods land in the TELLER, and the proceeds (minus the house fee) wait
--    in the seller's wallet: MARKET > MINE > COLLECT, then CASH OUT.
--    Every name-bound action is signed by right-clicking the Player
--    Detector - the server names the clicker, so nobody can act as
--    someone else. Goods are matched by item id: enchanted, renamed or
--    damaged stacks cannot be listed, and keep hoppers off the TELLER.
--
--  INSTALL
--    pastebin get <code> casino
--    casino setup      -- (re)pick the TELLER barrel and the BANK storage
--    casino            -- run
--
--  SERVICE MENU
--    Touch/click the top title bar, or press "A". Default PIN 1234.
--    The PIN is never stored in the clear - only a salted SHA-256 of it.
--    Change it from the service menu, or run "casino pin" at the computer
--    if you locked yourself out.
--========================================================================

local ARGS = { ... }
local VERSION = "1.7.0"

--======================== CONFIG ========================================
local CFG = {
  dataFile       = "/casino.dat",
  -- Service PIN. Only the salted hash is kept; the default below is
  -- sha256-chained "1234". Change it in the service menu (CHANGE PIN) or
  -- with "casino pin" - the new salt+hash go into the data file.
  pinSalt   = "lucky-barrel",
  pinHash   = "4ffb39abbcb4242be20fc3f2ea0ceeb6b310369f52959ac5eb8073f31a027343",
  pinRounds = 4,             -- hash iterations (CC is slow, keep it small)

  textScale      = 1,        -- monitor text scale
  pollDelay      = 1,        -- seconds between barrel scans
  vaultEvery     = 5,        -- polls between full BANK rescans (movers rescan themselves)
  collectTimeout = 60,       -- seconds a payout may sit in the TELLER
  clickDebounce  = 250,      -- ms; swallows the echo of a double-delivered click
  minBet         = 1,
  maxBet         = 512,
  houseEdge      = 0.04,     -- HI-LO edge (4%); other games have their own knobs
  jackpotRate    = 0.02,     -- share of every bet added to the jackpot
  jackpotSeed    = 250,      -- jackpot resets to this after it is won
  sound          = true,

  -- DOUBLE X2 ladder. Climb multiplies the pot, a burn wipes it.
  x2 = {
    mult     = 2.0,          -- pot multiplier on a successful raise
    burn     = 1 / 3,        -- chance the pot burns, at the first raise
    burnRamp = 0.05,         -- added to the burn chance on every next step
    startPay = 0.5,          -- starting pot, as a share of the bet
    maxSteps = 10,           -- hard cap on the ladder
  },

  -- Odds curve.
  curve = {
    lowStake  = 25,          -- at or below this stake, keep factor lowK
    highStake = 200,         -- at or above this stake, keep factor highK
    lowK      = 1.00,
    highK     = 0.50,
    richPay   = 8,           -- payouts richer than this many x get richK too
    richK     = 0.50,
    bjFloor   = 0.08,        -- blackjack dealer draw floor
  },

  -- MARKET: player-to-player trading. Goods are escrowed in the BANK and
  -- every name-bound action is signed by a right-click on the Player Detector.
  market = {
    fee         = 0.05,     -- house share of every sale, rounded up
    listFee     = 0,        -- credits taken when a listing is signed (0 = off)
    sign        = "click",  -- "click": sign by right-clicking the detector
                            -- "alone": CONFIRM counts when you are the only one in range
    range       = 8,        -- blocks from the detector a signer must be within
    signTimeout = 20,       -- seconds the SIGN screen waits
    cooldown    = 2,        -- seconds between signed actions
    minPrice    = 1,        -- lowest price per lot
    maxLot      = 64,       -- items per lot
    maxLots     = 32,       -- lots per listing
    maxOpen     = 6,        -- open listings per seller
    maxTotal    = 48,       -- open listings on the board
    perPage     = 9,        -- listings per page
  },

  -- what counts as money, and how much one item is worth in credits
  currency = {
    { id = "minecraft:diamond",      value = 1,   name = "diamond"      },
    { id = "minecraft:diamond_block",      value = 9,   name = "Big diamond"      },
    { id = "minecraft:netherite_scrap",         value = 8,  name = "Scrap"   },
    { id = "minecraft:netherite_ingot",         value = 32,  name = "N ingot"   },
    { id = "minecraft:netherite_block", value = 288, name = "Big Netherite" },
  },
}
--========================================================================

local VALUE, DENOMS = {}, {}
for _, c in ipairs(CFG.currency) do
  VALUE[c.id] = c.value
  DENOMS[#DENOMS + 1] = c
end
table.sort(DENOMS, function(a, b) return a.value > b.value end)

-- idle hint built from the currency table so it never goes stale
local IDLE_HINT
do
  local list = ""
  for _, c in ipairs(CFG.currency) do
    local try = (list == "") and c.name or (list .. ", " .. c.name)
    if #("Insert " .. try .. " into the TELLER") > 49 then break end
    list = try
  end
  IDLE_HINT = "Insert " .. ((list ~= "") and list or "coins") .. " into the TELLER"
end

--======================== SHA-256 =======================================
-- Pure arithmetic, no bit32 - works on every Lua CC has ever shipped.
-- Verified against the reference vectors, padding boundaries included.
local function bxor(a, b)
  local r, bit = 0, 1
  for _ = 1, 32 do
    local x, y = a % 2, b % 2
    if x ~= y then r = r + bit end
    a, b, bit = (a - x) / 2, (b - y) / 2, bit * 2
  end
  return r
end

local function band(a, b)
  local r, bit = 0, 1
  for _ = 1, 32 do
    local x, y = a % 2, b % 2
    if x == 1 and y == 1 then r = r + bit end
    a, b, bit = (a - x) / 2, (b - y) / 2, bit * 2
  end
  return r
end

local function bnot(a) return 4294967295 - a end
local function shr(a, n) return math.floor(a / 2 ^ n) end
local function rotr(a, n)
  return (shr(a, n) + (a * 2 ^ (32 - n)) % 4294967296) % 4294967296
end

local SHA_K = {
  0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
  0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
  0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
  0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
  0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
  0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
  0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
  0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
}

local function sha256(msg)
  local h = { 0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
              0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19 }
  local len = #msg
  msg = msg .. "\128" .. string.rep("\0", (55 - len) % 64)
  local hi = math.floor(len * 8 / 4294967296)
  local lo = (len * 8) % 4294967296
  for i = 3, 0, -1 do msg = msg .. string.char(math.floor(hi / 256 ^ i) % 256) end
  for i = 3, 0, -1 do msg = msg .. string.char(math.floor(lo / 256 ^ i) % 256) end

  for pos = 1, #msg, 64 do
    local w = {}
    for i = 0, 15 do
      local a, b, c, d = msg:byte(pos + i * 4, pos + i * 4 + 3)
      w[i + 1] = ((a * 256 + b) * 256 + c) * 256 + d
    end
    for i = 17, 64 do
      local v  = w[i - 15]
      local s0 = bxor(bxor(rotr(v, 7), rotr(v, 18)), shr(v, 3))
      v = w[i - 2]
      local s1 = bxor(bxor(rotr(v, 17), rotr(v, 19)), shr(v, 10))
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % 4294967296
    end
    local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
    for i = 1, 64 do
      local S1 = bxor(bxor(rotr(e, 6), rotr(e, 11)), rotr(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local t1 = (hh + S1 + ch + SHA_K[i] + w[i]) % 4294967296
      local S0 = bxor(bxor(rotr(a, 2), rotr(a, 13)), rotr(a, 22))
      local mj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
      local t2 = (S0 + mj) % 4294967296
      hh, g, f, e = g, f, e, (d + t1) % 4294967296
      d, c, b, a  = c, b, a, (t1 + t2) % 4294967296
    end
    local t = { a, b, c, d, e, f, g, hh }
    for i = 1, 8 do h[i] = (h[i] + t[i]) % 4294967296 end
  end

  local out = ""
  for i = 1, 8 do out = out .. string.format("%08x", h[i]) end
  return out
end

--======================== STATE =========================================
local bank = {
  vault   = 0,                 -- credit value held by the BANK (barrel or RS network)
  credits = 0,                 -- current player's credits
  jackpot = CFG.jackpotSeed,
  stats   = { wagered = 0, paid = 0, rounds = 0 },
  tellerName = nil,
  vaultName  = nil,
  vaultKind  = "inv",          -- "inv" = inventory, "rs" = RS Bridge
  market     = nil,            -- listings, wallets, journal (mkLoad builds it)
  pinSalt    = nil,            -- set once the PIN is changed from default
  pinHash    = nil,
}

-- salted, iterated hash - the plain PIN is never written anywhere
local function hashPin(pin, salt)
  local h = pin
  for _ = 1, CFG.pinRounds do h = sha256(salt .. ":" .. h) end
  return h
end

local function checkPin(entry)
  local salt = bank.pinSalt or CFG.pinSalt
  local want = bank.pinHash or CFG.pinHash
  return hashPin(entry, salt) == want
end

local function newSalt()
  local seed = tostring(os.epoch and os.epoch("utc") or os.time())
             .. ":" .. tostring(math.random(1, 2 ^ 30))
             .. ":" .. tostring(os.clock())
  return sha256(seed):sub(1, 16)
end

-- payout waiting in the TELLER for the player to pick up
local collect = { active = false, value = 0, last = 0, idle = 0 }

local tellerInv, vaultInv, monitor, speaker, detector, detName, monName
local busy      = false        -- true while we move items ourselves
local running   = true
local soundBusy = false
local junkSeen  = false
local W, H, usingMonitor
local msgText, msgColour = "", colors.white

--======================== PERSISTENCE ===================================
-- market table sanitiser: tolerates old files, hand edits and missing parts
local function mkLoad(raw)
  local m = { lots = {}, wallet = {}, alerts = {}, next = 1, pending = nil }
  if type(raw) ~= "table" then return m end
  local maxId = 0
  for _, l in ipairs(type(raw.lots) == "table" and raw.lots or {}) do
    if type(l) == "table" and type(l.seller) == "string" and type(l.item) == "string"
       and not VALUE[l.item] then
      local lot   = math.floor(tonumber(l.lot)   or 0)
      local price = math.floor(tonumber(l.price) or 0)
      local qty   = math.floor(tonumber(l.qty)   or 0)
      if lot >= 1 and price >= 1 and qty >= 1 then
        local id = math.floor(tonumber(l.id) or 0)
        m.lots[#m.lots + 1] = { id = id, seller = l.seller, item = l.item, lot = lot,
                                price = price, qty = qty,
                                hold = (type(l.hold) == "string") and l.hold or nil }
        if id > maxId then maxId = id end
      end
    end
  end
  for _, l in ipairs(m.lots) do
    if l.id < 1 then maxId = maxId + 1; l.id = maxId end
  end
  m.next = math.max(maxId + 1, math.floor(tonumber(raw.next) or 1))
  for name, v in pairs(type(raw.wallet) == "table" and raw.wallet or {}) do
    local n = math.floor(tonumber(v) or 0)
    if type(name) == "string" and n >= 1 then m.wallet[name] = n end
  end
  for _, a in ipairs(type(raw.alerts) == "table" and raw.alerts or {}) do
    if type(a) == "string" then m.alerts[#m.alerts + 1] = a end
  end
  if type(raw.pending) == "table" then m.pending = raw.pending end
  return m
end

local function save()
  local data = textutils.serialize({
    credits    = bank.credits,
    jackpot    = bank.jackpot,
    stats      = bank.stats,
    tellerName = bank.tellerName,
    vaultName  = bank.vaultName,
    vaultKind  = bank.vaultKind,
    market     = bank.market,
    pinSalt    = bank.pinSalt,
    pinHash    = bank.pinHash,
    collect    = { active = collect.active, value = collect.value },
    version    = VERSION,
  })
  -- write beside the live file and swap, so a crash never leaves it empty
  local tmp = CFG.dataFile .. ".tmp"
  local f = fs.open(tmp, "w")
  if not f then return end
  f.write(data)
  f.close()
  if fs.exists(CFG.dataFile) then fs.delete(CFG.dataFile) end
  fs.move(tmp, CFG.dataFile)
end

local function load()
  local t
  for _, path in ipairs({ CFG.dataFile, CFG.dataFile .. ".tmp" }) do
    if not t and fs.exists(path) then
      local f = fs.open(path, "r")
      if f then
        local raw = f.readAll(); f.close()
        local parsed = textutils.unserialize(raw or "")
        if type(parsed) == "table" then t = parsed end
      end
    end
  end
  bank.market = mkLoad(t and t.market)
  if type(t) ~= "table" then return end
  bank.credits    = tonumber(t.credits) or 0
  bank.jackpot    = tonumber(t.jackpot) or CFG.jackpotSeed
  bank.stats      = type(t.stats) == "table" and t.stats or bank.stats
  bank.tellerName = t.tellerName
  bank.vaultName  = t.vaultName
  bank.vaultKind  = (t.vaultKind == "rs") and "rs" or "inv"
  bank.pinSalt    = t.pinSalt
  bank.pinHash    = t.pinHash
  if type(t.collect) == "table" then
    collect.active = t.collect.active and true or false
    collect.value  = tonumber(t.collect.value) or 0
  end
end

--======================== SOUND =========================================
-- Every entry is a list of steps.
--   s = minecraft sound event (playSound)   n = note instrument (playNote)
--   p = pitch (0.5..2 for s, 0..24 for n)   v = volume (0..3)
--   w = pause in seconds after this step
local SFX = {
  click     = { { s = "minecraft:ui.button.click", v = 0.7, p = 1.7 } },
  select    = { { n = "pling", p = 16, v = 1 } },
  deny      = { { s = "minecraft:entity.villager.no", v = 1, p = 1.2 } },
  enter     = { { n = "bit", p = 10, v = 1, w = 0.06 },
                { n = "bit", p = 14, v = 1, w = 0.06 },
                { n = "bit", p = 18, v = 1 } },

  coin      = { { s = "minecraft:entity.experience_orb.pickup", v = 1,   p = 1.1, w = 0.06 },
                { s = "minecraft:entity.experience_orb.pickup", v = 1,   p = 1.4, w = 0.06 },
                { s = "minecraft:entity.experience_orb.pickup", v = 0.9, p = 1.8 } },
  cashout   = { { s = "minecraft:block.chain.place",            v = 1,   p = 1.6, w = 0.08 },
                { s = "minecraft:entity.experience_orb.pickup", v = 1.2, p = 0.9, w = 0.08 },
                { s = "minecraft:entity.experience_orb.pickup", v = 1.2, p = 1.2, w = 0.08 },
                { s = "minecraft:entity.experience_orb.pickup", v = 1.2, p = 1.6, w = 0.08 },
                { n = "chime", p = 21, v = 2 } },
  collected = { { n = "chime", p = 19, v = 1.4, w = 0.07 },
                { n = "chime", p = 24, v = 1.4 } },

  tick      = { { n = "hat",  p = 13, v = 0.4 } },
  wheel     = { { n = "hat",  p = 9,  v = 0.5 } },
  reelstop  = { { n = "bass", p = 5,  v = 1.4 },
                { s = "minecraft:block.wooden_button.click_off", v = 0.8, p = 0.7 } },
  card      = { { s = "minecraft:item.book.page_turn", v = 1.2, p = 1.1 } },
  ball      = { { s = "minecraft:block.note_block.bell", v = 1.4, p = 1.2 } },

  lose      = { { n = "bass", p = 9, v = 1.2, w = 0.13 },
                { n = "bass", p = 6, v = 1.2, w = 0.13 },
                { n = "bass", p = 2, v = 1.4 } },
  small     = { { n = "bell", p = 12, v = 1.6, w = 0.09 },
                { n = "bell", p = 16, v = 1.6 } },
  win       = { { n = "chime", p = 12, v = 2.2, w = 0.08 },
                { n = "chime", p = 16, v = 2.2, w = 0.08 },
                { n = "chime", p = 19, v = 2.2, w = 0.08 },
                { n = "chime", p = 24, v = 2.4 } },
  bigwin    = { { s = "minecraft:entity.player.levelup", v = 1.6, p = 1.3, w = 0.16 },
                { n = "bell", p = 12, v = 3, w = 0.10 },
                { n = "bell", p = 16, v = 3, w = 0.10 },
                { n = "bell", p = 19, v = 3, w = 0.10 },
                { n = "bell", p = 24, v = 3 } },
  jackpot   = { { s = "minecraft:ui.toast.challenge_complete", v = 2.5, p = 1, w = 0.30 },
                { n = "bell", p = 12, v = 3, w = 0.11 },
                { n = "bell", p = 16, v = 3, w = 0.11 },
                { n = "bell", p = 19, v = 3, w = 0.11 },
                { n = "bell", p = 24, v = 3, w = 0.22 },
                { n = "bell", p = 19, v = 3, w = 0.11 },
                { n = "bell", p = 24, v = 3, w = 0.22 },
                { s = "minecraft:entity.firework_rocket.twinkle", v = 3, p = 1,   w = 0.18 },
                { s = "minecraft:entity.firework_rocket.twinkle", v = 3, p = 1.4 } },
  alarm     = { { s = "minecraft:block.note_block.didgeridoo", v = 2, p = 0.6, w = 0.20 },
                { s = "minecraft:block.note_block.didgeridoo", v = 2, p = 0.6 } },
}

-- short sounds are dropped while a melody is playing, so ticks never queue up
local SHORT = { click = true, tick = true, wheel = true, select = true }

local function sfx(name)
  if not speaker or not CFG.sound then return end
  if soundBusy and SHORT[name] then return end
  os.queueEvent("casino_sfx", name)
end

local function soundLoop()
  while running do
    local _, name = os.pullEvent("casino_sfx")
    local seq = SFX[name]
    if seq and speaker then
      soundBusy = true
      for _, st in ipairs(seq) do
        if st.s and speaker.playSound then
          pcall(speaker.playSound, st.s, math.min(3, st.v or 1), st.p or 1)
        elseif st.n then
          pcall(speaker.playNote, st.n, math.min(3, st.v or 1), st.p or 12)
        end
        if st.w then sleep(st.w) end
      end
      soundBusy = false
    end
  end
end

--======================== PERIPHERALS ===================================
-- The BANK is either a plain inventory, or a Refined Storage network reached
-- through an Advanced Peripherals RS Bridge.
local bankOffline = false
local vaultAge = 0

local function isInv(name)
  if not name then return false end
  local p = peripheral.wrap(name)
  return p ~= nil and p.list ~= nil and p.pushItems ~= nil
end

local function isBridge(name)
  if not name then return false end
  local p = peripheral.wrap(name)
  return p ~= nil and p.exportItemToPeripheral ~= nil
         and p.importItemFromPeripheral ~= nil and p.getItem ~= nil
end

local function isRS() return bank.vaultKind == "rs" end

local function findInventories()
  local out = {}
  for _, n in ipairs(peripheral.getNames()) do
    if isInv(n) and not isBridge(n) then out[#out + 1] = n end
  end
  return out
end

local function findBridges()
  local out = {}
  for _, n in ipairs(peripheral.getNames()) do
    if isBridge(n) then out[#out + 1] = n end
  end
  return out
end

-- is the saved TELLER / BANK pair still attached and usable
local function bankReady()
  if not isInv(bank.tellerName) then return false end
  if isRS() then return isBridge(bank.vaultName) end
  return isInv(bank.vaultName) and bank.vaultName ~= bank.tellerName
end

local function setupWizard()
  term.redirect(term.native())
  term.setBackgroundColour(colors.black)
  term.setTextColour(colors.white)
  term.clear(); term.setCursorPos(1, 1)
  print("LUCKY BARREL CASINO - setup " .. VERSION)
  print("")
  local invs, bridges = findInventories(), findBridges()
  if #invs < 1 then
    print("No inventory found for the TELLER.")
    print("Attach the outer barrel with a wired modem")
    print("and run:  casino setup")
    error("setup aborted", 0)
  end

  local function ask(what, max)
    while true do
      write(what .. " (1-" .. max .. "): ")
      local n = tonumber(read())
      if n and n >= 1 and n <= max and n == math.floor(n) then return n end
      print("  ?")
    end
  end

  print("Inventories:")
  for i, n in ipairs(invs) do print(("  %d) %s"):format(i, n)) end
  bank.tellerName = invs[ask("TELLER - outer barrel players reach", #invs)]

  local opts = {}
  for _, b in ipairs(bridges) do
    opts[#opts + 1] = { kind = "rs", name = b, label = "RS network via " .. b }
  end
  for _, n in ipairs(invs) do
    if n ~= bank.tellerName then
      opts[#opts + 1] = { kind = "inv", name = n, label = n }
    end
  end
  if #opts == 0 then
    print("")
    print("Nothing to use as the BANK. Attach an RS Bridge")
    print("or a second inventory and run:  casino setup")
    error("setup aborted", 0)
  end

  print("")
  print("BANK storage:")
  for i, o in ipairs(opts) do print(("  %d) %s"):format(i, o.label)) end
  local pick = opts[ask("BANK", #opts)]
  bank.vaultKind, bank.vaultName = pick.kind, pick.name

  if pick.kind == "rs" then
    local ok, conn = pcall(peripheral.call, pick.name, "isConnected")
    if ok and conn == false then
      print("")
      print("WARNING: the bridge says the RS network is not")
      print("connected - check the controller has power.")
    end
  end

  save()
  print("")
  print("TELLER = " .. bank.tellerName)
  print("BANK   = " .. pick.label)
  print("Saved. Starting...")
  sleep(1.5)
end

local function attach()
  tellerInv = bank.tellerName and peripheral.wrap(bank.tellerName)
  vaultInv  = bank.vaultName  and peripheral.wrap(bank.vaultName)
  -- prefer an advanced (touch) monitor; fall back to any monitor
  monitor   = peripheral.find("monitor", function(_, m) return m.isColour and m.isColour() end)
              or peripheral.find("monitor")
  speaker   = peripheral.find("speaker")
  detector  = peripheral.find("playerDetector")
  local okM, mn = pcall(peripheral.getName, monitor)
  monName = (monitor and okM and type(mn) == "string") and mn or nil
  local okD, dn = pcall(peripheral.getName, detector)
  detName = (detector and okD and type(dn) == "string") and dn or nil
  if not tellerInv or not vaultInv then
    error("Teller or bank missing - run: casino setup", 0)
  end
end

--======================== MONEY MOVEMENT ================================
-- value of currency sitting in the TELLER, plus whether junk is in there
local function tellerScan()
  local ok, list = pcall(tellerInv.list)
  if not ok or type(list) ~= "table" then return 0, false end
  local total, junk = 0, false
  for _, item in pairs(list) do
    local v = VALUE[item.name]
    if v then
      total = total + v * item.count
    else
      junk = true
    end
  end
  return total, junk
end

-- how many of one item the RS network holds (0 if none or unreachable).
-- The bridge reports stored quantity as "amount".
local function rsAmount(id)
  local ok, it = pcall(vaultInv.getItem, { name = id })
  if not ok or type(it) ~= "table" then return 0 end
  return tonumber(it.amount or it.count) or 0
end

local function vaultScan()
  if isRS() then
    local ok, conn = pcall(vaultInv.isConnected)
    bankOffline = (not ok) or conn == false
    if bankOffline then return bank.vault end
    local total = 0
    for _, c in ipairs(CFG.currency) do
      total = total + rsAmount(c.id) * c.value
    end
    return total
  end
  local ok, list = pcall(vaultInv.list)
  bankOffline = (not ok) or type(list) ~= "table"
  if bankOffline then return bank.vault end
  local total = 0
  for _, item in pairs(list) do
    local v = VALUE[item.name]
    if v then total = total + v * item.count end
  end
  return total
end

-- move every coin from the TELLER into the BANK.
-- returns the credit value actually moved and whether the BANK refused some.
local function sweepToVault()
  busy = true
  local moved, full = 0, false
  pcall(function()
    if isRS() then
      local want = {}
      for _, item in pairs(tellerInv.list()) do
        if VALUE[item.name] then
          want[item.name] = (want[item.name] or 0) + item.count
        end
      end
      for id, cnt in pairs(want) do
        -- the bridge may move one stack per call: loop until it gives 0
        -- (extra parentheses keep only the count, never the error string)
        local got = 0
        while got < cnt do
          local n = tonumber((vaultInv.importItemFromPeripheral(
                      { name = id, count = cnt - got }, bank.tellerName))) or 0
          if n <= 0 then break end
          got = got + n
        end
        moved = moved + got * VALUE[id]
        if got < cnt then full = true end
      end
      return
    end
    for slot, item in pairs(tellerInv.list()) do
      local v = VALUE[item.name]
      if v then
        local n = tellerInv.pushItems(bank.vaultName, slot)
        if n and n > 0 then moved = moved + n * v end
        if not n or n < item.count then full = true end
      end
    end
  end)
  bank.vault = vaultScan()
  busy = false
  return moved, full
end

-- move items worth up to `amount` credits from the BANK to the TELLER.
-- returns credits actually paid, and whether nothing more could be moved.
local function payout(amount)
  busy = true
  local paid, full = 0, false

  pcall(function()
    if isRS() then
      for _, den in ipairs(DENOMS) do
        local n = math.min(rsAmount(den.id), math.floor((amount - paid) / den.value))
        while n > 0 do
          local moved = tonumber((vaultInv.exportItemToPeripheral(
                          { name = den.id, count = n }, bank.tellerName))) or 0
          if moved <= 0 then full = true; break end
          paid = paid + moved * den.value
          n    = n - moved
        end
      end
      return
    end

    local pool = {}
    for slot, item in pairs(vaultInv.list()) do
      if VALUE[item.name] then
        pool[item.name] = pool[item.name] or {}
        table.insert(pool[item.name], { slot = slot, count = item.count })
      end
    end
    for _, den in ipairs(DENOMS) do
      local stacks = pool[den.id]
      if stacks then
        for _, st in ipairs(stacks) do
          while st.count > 0 and (amount - paid) >= den.value do
            local n = math.min(st.count, math.floor((amount - paid) / den.value))
            local moved = vaultInv.pushItems(bank.tellerName, st.slot, n)
            if not moved or moved == 0 then full = true; break end
            paid     = paid + moved * den.value
            st.count = st.count - moved
          end
        end
      end
    end
  end)

  bank.vault = vaultScan()
  busy = false
  return paid, full
end

-- how many clean (no NBT) items of one id the BANK holds
local function bankStock(id)
  if isRS() then return rsAmount(id) end
  local ok, list = pcall(vaultInv.list)
  if not ok or type(list) ~= "table" then return 0 end
  local n = 0
  for _, it in pairs(list) do
    if it.name == id and not it.nbt then n = n + it.count end
  end
  return n
end

-- BANK -> TELLER, returns how many items actually moved
local function bankGive(id, n)
  busy = true
  local moved = 0
  pcall(function()
    if isRS() then
      while moved < n do
        local m = tonumber((vaultInv.exportItemToPeripheral(
                    { name = id, count = n - moved }, bank.tellerName))) or 0
        if m <= 0 then return end
        moved = moved + m
      end
      return
    end
    for slot, it in pairs(vaultInv.list()) do
      if moved >= n then return end
      if it.name == id and not it.nbt then
        local m = vaultInv.pushItems(bank.tellerName, slot, n - moved) or 0
        if m <= 0 then return end
        moved = moved + m
      end
    end
  end)
  bank.vault = vaultScan()
  busy = false
  return moved
end

-- TELLER -> BANK, clean items only, returns how many items actually moved
local function bankTake(id, n)
  busy = true
  local moved = 0
  pcall(function()
    if isRS() then
      while moved < n do
        local m = tonumber((vaultInv.importItemFromPeripheral(
                    { name = id, count = n - moved }, bank.tellerName))) or 0
        if m <= 0 then return end
        moved = moved + m
      end
      return
    end
    for slot, it in pairs(tellerInv.list()) do
      if moved >= n then return end
      if it.name == id and not it.nbt then
        local m = tellerInv.pushItems(bank.vaultName, slot, n - moved) or 0
        if m <= 0 then return end
        moved = moved + m
      end
    end
  end)
  bank.vault = vaultScan()
  busy = false
  return moved
end

--======================== DRAW HELPERS ==================================
local function fill(x, y, w, h, bg)
  if w < 1 or h < 1 then return end
  term.setBackgroundColour(bg)
  local line = string.rep(" ", w)
  for i = 0, h - 1 do
    term.setCursorPos(x, y + i)
    term.write(line)
  end
end

local function put(x, y, s, fg, bg)
  s = tostring(s)
  if W then                              -- never write past the screen edge
    if x < 1 then s = s:sub(2 - x); x = 1 end
    if x + #s - 1 > W then s = s:sub(1, math.max(0, W - x + 1)) end
    if #s == 0 then return end
  end
  if bg then term.setBackgroundColour(bg) end
  if fg then term.setTextColour(fg) end
  term.setCursorPos(x, y)
  term.write(s)
end

local function putC(y, s, fg, bg)
  s = tostring(s)
  put(math.max(1, math.floor((W - #s) / 2) + 1), y, s, fg, bg)
end

-- right-aligned text ending at column xr
local function rput(xr, y, s, fg, bg)
  s = tostring(s)
  put(xr - #s + 1, y, s, fg, bg)
end

local function fmt(n)
  local s = tostring(math.floor(tonumber(n) or 0))
  local r = s:reverse():gsub("(%d%d%d)", "%1 ")
  return (r:reverse():gsub("^%s+", ""))
end

local function msg(t, c)
  msgText, msgColour = t or "", c or colors.white
end

local function bankCanCover(amount)
  return bank.vault >= math.floor(amount)
end

-- the jackpot can only be won while the BANK can actually pay it
local function jackpotLocked()
  return not bankCanCover(bank.jackpot)
end

-- Odds curve lookup. payMult is the total return as a multiple of the stake.
local function stakeK(stake, payMult)
  local C = CFG.curve
  local span = math.max(1, C.highStake - C.lowStake)
  local t = math.max(0, math.min(1, (stake - C.lowStake) / span))
  local k = C.lowK + (C.highK - C.lowK) * t
  if payMult and payMult > C.richPay then k = k * C.richK end
  return k
end

--======================== BUTTONS =======================================
local buttons = {}

local function clearButtons() buttons = {} end

local function button(id, x, y, w, h, label, bg, fg, key)
  local b = { id = id, x = x, y = y, w = w, h = h, key = key }
  buttons[#buttons + 1] = b
  fill(x, y, w, h, bg or colors.gray)
  label = tostring(label)
  if #label > w then label = label:sub(1, w) end
  put(x + math.floor((w - #label) / 2), y + math.floor((h - 1) / 2),
      label, fg or colors.white, bg or colors.gray)
  return b
end

local function ghost(id, x, y, w, h)
  buttons[#buttons + 1] = { id = id, x = x, y = y, w = w, h = h }
end

local function rowButtons(y, h, defs)
  local n = #defs
  local bw = math.floor((W - 2 - (n - 1)) / n)
  local x = 2
  for _, d in ipairs(defs) do
    button(d[1], x, y, bw, h, d[2], d[3], d[4], d[5])
    x = x + bw + 1
  end
end

local function hitTest(mx, my)
  for i = #buttons, 1, -1 do
    local b = buttons[i]
    if mx >= b.x and mx < b.x + b.w and my >= b.y and my < b.y + b.h then return b.id end
  end
end

--======================== EVENTS ========================================
local function pullUI()
  while true do
    local ev = { os.pullEvent() }
    local e = ev[1]
    if e == "monitor_touch" and usingMonitor and (monName == nil or ev[2] == monName) then
      return "click", ev[3], ev[4]
    elseif e == "mouse_click" and not usingMonitor and ev[2] == 1 then
      return "click", ev[3], ev[4]
    elseif e == "char" then
      return "char", ev[2]
    elseif e == "playerClick" then
      return "sign", ev[2], ev[3]
    elseif e == "timer" then
      return "timer", ev[2]
    elseif e == "casino_update" then
      return "update"
    elseif e == "term_resize" or e == "monitor_resize" then
      W, H = term.getSize()
      return "resize"
    end
  end
end

local lastClick = 0

local function nowMs()
  if os.epoch then return os.epoch("utc") end
  return math.floor(os.clock() * 1000)
end

local function waitAction(redraw)
  while true do
    local t, a, b = pullUI()
    if t == "click" then
      -- One physical touch can arrive as two events, and the click that
      -- opened this screen may still be in flight while the new layout is
      -- already drawn underneath it. Swallow anything that close together.
      local now = nowMs()
      if now - lastClick >= CFG.clickDebounce then
        local id = hitTest(a, b)
        if id then lastClick = now; sfx("click"); return id end
      end
    elseif t == "char" then
      local c = tostring(a):lower()
      for _, bt in ipairs(buttons) do
        if bt.key == c then sfx("click"); return bt.id end
      end
      if c == "a" then return "__admin" end
    elseif t == "update" or t == "resize" then
      if redraw then redraw() end
    end
  end
end

--======================== FRAME =========================================
local function header(sub)
  fill(1, 1, W, 1, colors.blue)
  put(2, 1, "* LUCKY BARREL CASINO *", colors.yellow, colors.blue)
  local cr = "CREDITS " .. fmt(bank.credits)
  put(math.max(2, W - #cr), 1, cr, colors.white, colors.blue)
  ghost("__admin", 1, 1, W, 1)

  if collect.active then
    fill(1, 2, W, 1, colors.orange)
    putC(2, "COLLECT " .. fmt(collect.value) .. " FROM THE TELLER BARREL",
         colors.black, colors.orange)
  else
    fill(1, 2, W, 1, colors.gray)
    local jl = jackpotLocked()
    put(2, 2, "JACKPOT " .. fmt(bank.jackpot) .. (jl and " [LOCKED]" or ""),
        jl and colors.red or colors.orange, colors.gray)
    local r = bankOffline and "BANK OFFLINE" or ("BANK " .. fmt(bank.vault))
    put(math.max(2, W - #r), 2, r, bankOffline and colors.red or colors.lime, colors.gray)
    if sub then
      -- keep the sub-title clear of the jackpot tag and the bank figure
      local st = " " .. sub .. " "
      local leftEnd = 1 + #("JACKPOT " .. fmt(bank.jackpot) .. (jl and " [LOCKED]" or ""))
      local rightStart = math.max(2, W - #r)
      local x = math.floor((W - #st) / 2) + 1
      if x <= leftEnd + 1 or x + #st - 1 >= rightStart - 1 then
        local room = rightStart - leftEnd - 3
        if room >= 4 then put(leftEnd + 2, 2, st:sub(1, room), colors.white, colors.gray) end
      else
        put(x, 2, st, colors.white, colors.gray)
      end
    end
  end
end

local function footer()
  fill(1, H, W, 1, colors.black)
  put(2, H, msgText:sub(1, math.max(1, W - 2)), msgColour, colors.black)
end

local function frame(sub)
  fill(1, 1, W, H, colors.black)
  clearButtons()
  header(sub)
  footer()
end

--======================== BET CONTROL ===================================
local bet = 10

local function clampBet()
  bet = math.floor(bet)
  if bet < CFG.minBet then bet = CFG.minBet end
  if bet > CFG.maxBet then bet = CFG.maxBet end
  if bet > bank.credits then bet = math.max(CFG.minBet, math.floor(bank.credits)) end
end

local function betStep()
  if bet < 10 then return 1 elseif bet < 50 then return 5
  elseif bet < 200 then return 10 else return 50 end
end

local function drawBetBar(y)
  fill(1, y, W, 1, colors.black)
  put(2, y, "BET " .. string.format("%-8s", fmt(bet)), colors.yellow, colors.black)
  local x = 15
  button("bet-",   x,      y, 3, 1, "-",   colors.red)
  button("bet+",   x + 4,  y, 3, 1, "+",   colors.green)
  button("betx2",  x + 8,  y, 4, 1, "x2",  colors.gray)
  button("betmax", x + 13, y, 5, 1, "MAX", colors.gray)
end

local function handleBet(id)
  if     id == "bet-"   then bet = bet - betStep()
  elseif id == "bet+"   then bet = bet + betStep()
  elseif id == "betx2"  then bet = bet * 2
  elseif id == "betmax" then bet = math.min(CFG.maxBet, math.floor(bank.credits))
  else return false end
  clampBet()
  sfx("select")
  return true
end

--======================== WAGER / AWARD =================================
-- which game is on screen; every wager and win is booked against it
local curGame = "-"

local function statFor(id)
  bank.stats.games = bank.stats.games or {}
  local g = bank.stats.games[id]
  if not g then g = { w = 0, p = 0, r = 0 }; bank.stats.games[id] = g end
  return g
end

local function canPlay(amount)
  clampBet()
  amount = amount or bet
  if bank.credits < amount or bet < CFG.minBet then
    msg("Not enough credits - insert coins in the TELLER", colors.orange)
    sfx("deny")
    return false
  end
  return true
end

local function placeBet(amount)
  amount = math.floor(amount or bet)
  bank.credits       = bank.credits - amount
  bank.stats.wagered = bank.stats.wagered + amount
  bank.stats.rounds  = bank.stats.rounds + 1
  bank.jackpot       = bank.jackpot + amount * CFG.jackpotRate
  local g = statFor(curGame)
  g.w, g.r = g.w + amount, g.r + 1
  save()
end

local function award(amount)
  amount = math.floor(amount)
  if amount <= 0 then return 0 end
  bank.credits    = bank.credits + amount
  bank.stats.paid = bank.stats.paid + amount
  statFor(curGame).p = statFor(curGame).p + amount
  save()
  return amount
end

-- picks the right fanfare for the size of the win
local function winSound(amount)
  if amount >= bet * 20 then sfx("bigwin")
  elseif amount > bet then sfx("win")
  else sfx("small") end
end

--======================== CASH OUT ======================================
local function cashOut()
  if collect.active then
    msg("Empty the TELLER barrel first", colors.orange)
    sfx("deny")
    return
  end
  local want = math.floor(bank.credits)
  if want < 1 then
    msg("Nothing to cash out", colors.orange); sfx("deny"); return
  end
  msg("Counting out your money...", colors.white)
  footer()

  local paid, full = payout(want)
  bank.credits = bank.credits - paid
  if paid > 0 then
    collect.active = true
    collect.value  = paid
    collect.last   = (tellerScan())
    collect.idle   = 0
  end
  save()

  if paid <= 0 then
    -- three very different causes, they used to share one wrong message
    local smallest = DENOMS[#DENOMS].value
    if bankOffline then
      msg("The bank storage is offline - call the owner", colors.red)
    elseif bank.vault <= 0 then
      msg("The bank is empty - call the owner", colors.red)
    elseif full then
      msg("Nothing moved: teller full or bank blocks pulls", colors.red)
    elseif want < smallest then
      msg("Payout below the smallest coin (" .. smallest .. ") - keep playing",
          colors.orange)
    else
      msg("Bank has no small coins - owner must add change", colors.orange)
    end
    sfx("alarm")
  elseif bank.credits >= 1 then
    msg("Paid " .. fmt(paid) .. ", " .. fmt(bank.credits) .. " still on credit "
        .. (full and "(teller full)" or "(bank low)"), colors.orange)
    sfx("cashout")
  else
    msg("Paid " .. fmt(paid) .. " - collect it from the TELLER barrel", colors.lime)
    sfx("cashout")
  end
end

--======================== GAME: SLOTS ===================================
local SYM = {
  { ch = "C", w = 8, pay = 4,   col = colors.red,     name = "CHERRY" },
  { ch = "B", w = 6, pay = 8,   col = colors.yellow,  name = "BELL"   },
  { ch = "=", w = 5, pay = 12,  col = colors.brown,   name = "BAR"    },
  { ch = "*", w = 4, pay = 25,  col = colors.white,   name = "STAR"   },
  { ch = "@", w = 3, pay = 60,  col = colors.lime,    name = "GEM"    },
  { ch = "7", w = 2, pay = 150, col = colors.magenta, name = "SEVEN"  },
}
local REEL = {}
for _, s in ipairs(SYM) do
  for _ = 1, s.w do REEL[#REEL + 1] = s end
end
local function spinSym() return REEL[math.random(1, #REEL)] end

-- Builds the reel set for one spin.
local function slotDraw(stake)
  local total = 0
  for _, s in ipairs(SYM) do total = total + s.w end

  local pool, acc = {}, 0
  for _, s in ipairs(SYM) do
    local ps  = s.w / total
    local pay = s.pay
    if s.ch == "7" and not jackpotLocked() then
      pay = pay + bank.jackpot / math.max(1, stake)
    end
    acc = acc + ps ^ 3 * stakeK(stake, pay)
    pool[#pool + 1] = { k = "t", s = s, upto = acc }
    acc = acc + 3 * ps * ps * (1 - ps) * stakeK(stake, 1)
    pool[#pool + 1] = { k = "p", s = s, upto = acc }
  end

  local r = math.random()
  for _, e in ipairs(pool) do
    if r < e.upto then
      if e.k == "t" then return { e.s, e.s, e.s } end
      local other = spinSym()
      while other == e.s do other = spinSym() end
      local out = { e.s, e.s, e.s }
      out[math.random(3)] = other
      return out
    end
  end

  local a, b, c
  repeat a, b, c = spinSym(), spinSym(), spinSym()
  until a ~= b and b ~= c and a ~= c
  return { a, b, c }
end

local function drawReel(x, y, s)
  fill(x, y, 7, 5, colors.lightGray)
  fill(x + 1, y + 1, 5, 3, colors.black)
  put(x + 3, y + 2, s.ch, s.col, colors.black)
end

local function slotsPaytable()
  local function draw()
    frame("PAYTABLE")
    local y = 4
    put(3, y, "3 OF A KIND", colors.lightGray, colors.black)
    put(W - 12, y, "PAYS", colors.lightGray, colors.black)
    y = y + 1
    for i = #SYM, 1, -1 do
      local s = SYM[i]
      put(3, y, s.ch .. " " .. s.ch .. " " .. s.ch, s.col, colors.black)
      put(11, y, s.name, colors.white, colors.black)
      put(W - 12, y, "x" .. s.pay, colors.yellow, colors.black)
      y = y + 1
    end
    y = y + 1
    put(3, y, "Any 2 matching", colors.white, colors.black)
    put(W - 12, y, "x1", colors.yellow, colors.black); y = y + 1
    put(3, y, "7 7 7", colors.magenta, colors.black)
    put(11, y, "JACKPOT + x150", colors.orange, colors.black)
    button("back", 2, H - 1, 10, 1, "BACK", colors.blue, colors.white, "q")
    footer()
  end
  draw()
  while true do
    local id = waitAction(draw)
    if id == "back" then return end
  end
end

local function gameSlots()
  sfx("enter")
  local reels = { spinSym(), spinSym(), spinSym() }
  local rx = math.floor((W - 25) / 2) + 1
  local ry, py, by, ay = 5, 11, 13, 15

  local function drawReels()
    for i = 1, 3 do drawReel(rx + (i - 1) * 9, ry, reels[i]) end
  end

  local function draw()
    frame("SLOTS")
    drawReels()
    putC(py, "3 of a kind up to x150 - 7 7 7 takes the JACKPOT",
         colors.lightGray, colors.black)
    drawBetBar(by)
    button("spin", 2, ay, 12, 1, "SPIN", colors.green, colors.white, " ")
    button("pay", 16, ay, 12, 1, "PAYTABLE", colors.gray, colors.white, "p")
    button("back", W - 10, ay, 9, 1, "BACK", colors.blue, colors.white, "q")
    footer()
  end

  draw()
  while true do
    local id = waitAction(draw)
    if handleBet(id) then
      draw()
    elseif id == "back" then
      return
    elseif id == "pay" then
      slotsPaytable(); draw()
    elseif id == "spin" then
      if canPlay() then
        placeBet()
        msg("Spinning...", colors.white)
        draw()
        local stop  = { 9, 14, 19 }
        local final = slotDraw(bet)
        for step = 1, 19 do
          for i = 1, 3 do
            if step < stop[i] then reels[i] = spinSym() else reels[i] = final[i] end
            if step == stop[i] then sfx("reelstop") end
          end
          drawReels()
          if step % 2 == 0 then sfx("tick") end
          sleep(0.06)
        end
        reels = final

        local win, label = 0, "NO WIN"
        if reels[1] == reels[2] and reels[2] == reels[3] then
          win   = bet * reels[1].pay
          label = reels[1].name .. " x3"
          if reels[1].ch == "7" then
            local jp = math.floor(bank.jackpot)
            -- never hand out a jackpot the BANK cannot actually pay
            if jp > 0 and not jackpotLocked() then
              win   = win + jp
              label = "*** JACKPOT " .. fmt(jp) .. " ***"
              bank.jackpot = CFG.jackpotSeed
            else
              label = "SEVEN x3 (JACKPOT LOCKED)"
            end
          end
        elseif reels[1] == reels[2] or reels[2] == reels[3] or reels[1] == reels[3] then
          win, label = bet, "PAIR"
        end

        if win > 0 then
          award(win)
          msg(label .. "  -  WIN " .. fmt(win), colors.lime)
          if label:find("JACKPOT") then sfx("jackpot") else winSound(win) end
        else
          save()
          msg("No win. Try again.", colors.lightGray)
          sfx("lose")
        end
        draw()
      else
        footer()
      end
    end
  end
end

--======================== GAME: ROULETTE ================================
local REDSET = {}
for _, n in ipairs({ 1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36 }) do REDSET[n] = true end

local RBET = {
  red   = { label = "RED",    pay = 1,  col = colors.red,    test = function(n) return REDSET[n] == true end },
  black = { label = "BLACK",  pay = 1,  col = colors.gray,   test = function(n) return n > 0 and not REDSET[n] end },
  even  = { label = "EVEN",   pay = 1,  col = colors.blue,   test = function(n) return n > 0 and n % 2 == 0 end },
  odd   = { label = "ODD",    pay = 1,  col = colors.blue,   test = function(n) return n % 2 == 1 end },
  low   = { label = "1-18",   pay = 1,  col = colors.cyan,   test = function(n) return n >= 1 and n <= 18 end },
  high  = { label = "19-36",  pay = 1,  col = colors.cyan,   test = function(n) return n >= 19 end },
  dz1   = { label = "1-12",   pay = 2,  col = colors.purple, test = function(n) return n >= 1 and n <= 12 end },
  dz2   = { label = "13-24",  pay = 2,  col = colors.purple, test = function(n) return n >= 13 and n <= 24 end },
  dz3   = { label = "25-36",  pay = 2,  col = colors.purple, test = function(n) return n >= 25 and n <= 36 end },
  num   = { label = "NUMBER", pay = 35, col = colors.orange, test = nil },
}

local function numColour(n)
  if n == 0 then return colors.green end
  return REDSET[n] and colors.red or colors.gray
end

-- Rolls the wheel.
local function wheelDraw(choice, pick, stake)
  local b = RBET[choice]
  local hits, misses = {}, {}
  for n = 0, 36 do
    local hit = (choice == "num") and (n == pick) or (b.test and b.test(n))
    if hit then hits[#hits + 1] = n else misses[#misses + 1] = n end
  end
  local p = (#hits / 37) * stakeK(stake, b.pay + 1)
  if #hits > 0 and math.random() < p then return hits[math.random(#hits)] end
  return misses[math.random(#misses)]
end

local function gameRoulette()
  sfx("enter")
  local pick, choice, last = 17, "red", nil
  local ry, r1, r2, r3, by, ay = 4, 8, 10, 12, 14, 16

  local function drawWheel(n)
    fill(1, ry, W, 3, colors.black)
    local x = math.floor(W / 2) - 4
    fill(x, ry, 9, 3, numColour(n))
    local s = tostring(n)
    put(x + math.floor((9 - #s) / 2), ry + 1, s, colors.white, numColour(n))
  end

  local function draw()
    frame("ROULETTE")
    if last then
      drawWheel(last)
    else
      fill(1, ry, W, 3, colors.black)
      putC(ry + 1, "PLACE YOUR BET", colors.lightGray, colors.black)
    end

    local function c(id) return (choice == id) and colors.white or RBET[id].col end
    local function f(id) return (choice == id) and colors.black or colors.white end

    rowButtons(r1, 1, {
      { "red", "RED", c("red"), f("red") }, { "black", "BLACK", c("black"), f("black") },
      { "even", "EVEN", c("even"), f("even") }, { "odd", "ODD", c("odd"), f("odd") },
      { "low", "1-18", c("low"), f("low") }, { "high", "19-36", c("high"), f("high") },
    })
    rowButtons(r2, 1, {
      { "dz1", "1-12 x2",  c("dz1"), f("dz1") },
      { "dz2", "13-24 x2", c("dz2"), f("dz2") },
      { "dz3", "25-36 x2", c("dz3"), f("dz3") },
    })

    fill(1, r3, W, 1, colors.black)
    button("num", 2, r3, 14, 1, "NUMBER x35", c("num"), f("num"))
    button("n-", 17, r3, 3, 1, "-", colors.red)
    put(21, r3, string.format("%2d", pick), colors.orange, colors.black)
    button("n+", 24, r3, 3, 1, "+", colors.green)

    drawBetBar(by)
    button("spin", 2, ay, 12, 1, "SPIN", colors.green, colors.white, " ")
    button("back", W - 10, ay, 9, 1, "BACK", colors.blue, colors.white, "q")
    footer()
  end

  draw()
  while true do
    local id = waitAction(draw)
    if handleBet(id) then
      draw()
    elseif id == "back" then
      return
    elseif RBET[id] then
      choice = id; sfx("select"); draw()
    elseif id == "n-" then
      pick = (pick - 1) % 37; choice = "num"; sfx("select"); draw()
    elseif id == "n+" then
      pick = (pick + 1) % 37; choice = "num"; sfx("select"); draw()
    elseif id == "spin" then
      if canPlay() then
        placeBet()
        msg("No more bets...", colors.white)
        draw()
        local result = wheelDraw(choice, pick, bet)
        for i = 1, 22 do
          drawWheel(i < 22 and math.random(0, 36) or result)
          sfx("wheel")
          sleep(0.04 + i * 0.006)
        end
        last = result
        drawWheel(result)
        sfx("ball")

        local b   = RBET[choice]
        local hit = (choice == "num") and (result == pick) or (b.test and b.test(result))
        if hit then
          local win = bet * (b.pay + 1)
          award(win)
          msg(result .. " - " .. (choice == "num" and ("NUMBER " .. pick) or b.label)
              .. " WINS " .. fmt(win), colors.lime)
          winSound(win)
        else
          save()
          msg(result .. " - " .. (result == 0 and "ZERO, house takes it" or "no luck"),
              colors.lightGray)
          sfx("lose")
        end
        draw()
      else
        footer()
      end
    end
  end
end

--======================== GAME: HI-LO ===================================
local RANK = { "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K" }

local function gameHiLo()
  sfx("enter")
  local card, lastCard = math.random(1, 13), nil
  local guess = nil                -- picked direction, played only on DEAL
  local cy, py, by, ay = 4, 10, 12, 14

  local function mults()
    local hiCount, loCount = 13 - card, card - 1
    local hi = hiCount > 0 and (1 - CFG.houseEdge) * 13 / hiCount or 0
    local lo = loCount > 0 and (1 - CFG.houseEdge) * 13 / loCount or 0
    return hi, lo
  end

  local function drawCard(x, y, r, col, tag)
    fill(x, y, 9, 5, col or colors.white)
    local s = RANK[r]
    put(x + math.floor((9 - #s) / 2), y + 2, s, colors.black, col or colors.white)
    if tag then put(x, y + 5, tag:sub(1, 9), colors.lightGray, colors.black) end
  end

  local function draw()
    frame("HI-LO")
    fill(1, cy, W, 6, colors.black)
    local x = math.floor(W / 2) - 11
    drawCard(x, cy, card, colors.white, " CURRENT")
    if lastCard then
      drawCard(x + 13, cy, lastCard.r, lastCard.win and colors.lime or colors.red, "  DRAWN")
    else
      fill(x + 13, cy, 9, 5, colors.gray)
      put(x + 17, cy + 2, "?", colors.white, colors.gray)
    end

    local hi, lo = mults()
    local function bg(id, avail, base)
      if not avail then return colors.gray end
      return (guess == id) and colors.white or base
    end
    local function fg(id) return (guess == id) and colors.black or colors.white end
    rowButtons(py, 1, {
      { "hi", hi > 0 and ("HIGHER x" .. ("%.2f"):format(hi)) or "HIGHER -",
        bg("hi", hi > 0, colors.green), fg("hi"), "h" },
      { "lo", lo > 0 and ("LOWER x" .. ("%.2f"):format(lo)) or "LOWER -",
        bg("lo", lo > 0, colors.red), fg("lo"), "l" },
    })
    putC(py + 1, guess and "Press DEAL to draw the next card"
                        or "Pick a direction. Ties lose, A is low, K is high.",
         colors.lightGray, colors.black)
    drawBetBar(by)
    button("deal", 2, ay, 12, 1, "DEAL",
           guess and colors.green or colors.gray, colors.white, " ")
    button("new", 16, ay, 12, 1, "NEW CARD", colors.gray, colors.white, "n")
    button("back", W - 10, ay, 9, 1, "BACK", colors.blue, colors.white, "q")
    footer()
  end

  draw()
  while true do
    local id = waitAction(draw)
    if handleBet(id) then
      draw()
    elseif id == "back" then
      return
    elseif id == "new" then
      card, lastCard, guess = math.random(1, 13), nil, nil
      msg("New card dealt - pick HIGHER or LOWER", colors.lightGray)
      sfx("card")
      draw()
    elseif id == "hi" or id == "lo" then
      -- selecting a direction never plays; DEAL does
      local hi, lo = mults()
      if ((id == "hi") and hi or lo) <= 0 then
        msg("That bet is impossible on this card", colors.orange); sfx("deny"); footer()
      else
        guess = id
        msg("Betting " .. (id == "hi" and "HIGHER" or "LOWER") .. " - press DEAL",
            colors.white)
        sfx("select")
        draw()
      end
    elseif id == "deal" then
      local hi, lo = mults()
      local mult = (guess == "hi") and hi or (guess == "lo") and lo or 0
      if not guess then
        msg("Pick HIGHER or LOWER first", colors.orange); sfx("deny"); footer()
      elseif mult <= 0 then
        msg("That bet is impossible on this card", colors.orange); sfx("deny"); footer()
      elseif canPlay() then
        placeBet()
        sfx("card")
        sleep(0.25)
        local hits, misses = {}, {}
        for r = 1, 13 do
          local good = (guess == "hi" and r > card) or (guess == "lo" and r < card)
          if good then hits[#hits + 1] = r else misses[#misses + 1] = r end
        end
        local win = #hits > 0
                    and math.random() < (#hits / 13) * stakeK(bet, mult)
        local n   = win and hits[math.random(#hits)]
                        or misses[math.random(#misses)]
        lastCard  = { r = n, win = win }
        draw()
        if win then
          local amount = math.floor(bet * mult)
          award(amount)
          msg(RANK[n] .. " - WIN " .. fmt(amount), colors.lime)
          winSound(amount)
        else
          save()
          msg(RANK[n] .. " - lost " .. fmt(bet), colors.lightGray)
          sfx("lose")
        end
        -- the current card stays until the player presses NEW CARD
        draw()
      else
        footer()
      end
    end
  end
end

--======================== GAME: DOUBLE X2 ===============================
-- Climb the ladder: every RAISE multiplies the pot, or burns it to nothing.
-- TAKE banks the pot. Walking away with BACK cashes the pot, never eats it.
local function gameDouble()
  sfx("enter")
  local X = CFG.x2
  local pot, step = 0, 0
  local py, sy, by, ay = 4, 10, 12, 14

  local function burnChance()
    return math.min(0.95, X.burn + X.burnRamp * step)
  end

  local function nextPot() return math.floor(pot * X.mult) end

  -- why a raise may be refused: cap reached, or the bank cannot cover it
  local function raiseBlock()
    if step >= X.maxSteps then return "ladder capped at " .. X.maxSteps .. " steps" end
    if not bankCanCover(nextPot()) then return "bank cannot cover the next step" end
    return nil
  end

  local function drawPot(col)
    fill(1, py, W, 5, colors.black)
    local box = math.min(W - 6, 23)
    local x   = math.floor((W - box) / 2) + 1
    fill(x, py, box, 5, col or colors.gray)
    local s = (pot > 0) and fmt(pot) or "-"
    put(x + math.floor((box - #s) / 2), py + 2, s, colors.black, col or colors.gray)
    local tag = (pot > 0) and ("STEP " .. step) or "PLACE A BET"
    put(x + math.floor((box - #tag) / 2), py, tag, colors.black, col or colors.gray)
  end

  local function draw()
    frame("DOUBLE X2")
    drawPot(pot > 0 and colors.yellow or colors.gray)

    fill(1, sy, W, 1, colors.black)
    if pot > 0 then
      local blocked = raiseBlock()
      local line = ("NEXT %s   SURVIVE %d%%"):format(
                     fmt(nextPot()), math.floor((1 - burnChance()) * 100 + 0.5))
      putC(sy, blocked and ("RAISE BLOCKED - " .. blocked) or line,
           blocked and colors.red or colors.lightGray, colors.black)
    else
      putC(sy, ("Each raise pays x%.2f, burn chance %d%%"):format(
             X.mult, math.floor(X.burn * 100 + 0.5)), colors.lightGray, colors.black)
    end

    if pot > 0 then
      fill(1, by, W, 1, colors.black)
      putC(by, "TAKE banks the pot - BACK cashes it too", colors.lightGray, colors.black)
    else
      drawBetBar(by)
    end

    fill(1, ay, W, 1, colors.black)
    if pot > 0 then
      local ok = raiseBlock() == nil
      button("raise", 2, ay, 14, 1, "RAISE x" .. ("%.2g"):format(X.mult),
             ok and colors.red or colors.gray, colors.white, " ")
      button("take", 18, ay, 12, 1, "TAKE " .. fmt(pot), colors.green, colors.white, "t")
    else
      button("start", 2, ay, 14, 1, "PLACE BET", colors.green, colors.white, " ")
    end
    button("back", W - 10, ay, 9, 1, "BACK", colors.blue, colors.white, "q")
    footer()
  end

  draw()
  while true do
    local id = waitAction(draw)
    if handleBet(id) then
      draw()
    elseif id == "back" then
      if pot > 0 then
        local got = award(pot)
        msg("Left the ladder with " .. fmt(got), colors.lime)
        sfx("small")
        pot, step = 0, 0
      end
      return
    elseif id == "start" and pot == 0 then
      if canPlay() then
        placeBet()
        pot  = math.max(1, math.floor(bet * X.startPay))
        step = 0
        msg("Pot is " .. fmt(pot) .. " - raise it or take it", colors.white)
        sfx("select")
        draw()
      else
        footer()
      end
    elseif id == "take" and pot > 0 then
      local got = award(pot)
      msg("Banked " .. fmt(got) .. " after " .. step .. " raise(s)", colors.lime)
      winSound(got)
      pot, step = 0, 0
      draw()
    elseif id == "raise" and pot > 0 then
      local blocked = raiseBlock()
      if blocked then
        msg("Cannot raise - " .. blocked, colors.orange)
        sfx("deny")
        footer()
      else
        local burn = burnChance()
        local safe = math.random()
                     < (1 - burn) * stakeK(bet, nextPot() / math.max(1, bet))
        -- suspense: flash the pot before revealing
        for i = 1, 10 do
          drawPot(i % 2 == 0 and colors.orange or colors.yellow)
          sfx("tick")
          sleep(0.05 + i * 0.012)
        end
        if safe then
          pot  = nextPot()
          step = step + 1
          drawPot(colors.lime)
          msg("Survived! Pot is now " .. fmt(pot), colors.lime)
          sfx("small")
        else
          pot, step = 0, 0
          drawPot(colors.red)
          msg("BURNED - the pot is gone", colors.red)
          sfx("lose")
        end
        sleep(0.3)
        save()
        draw()
      end
    end
  end
end

--======================== CARDS =========================================
local SUITCH = { "S", "H", "D", "C" }

local function cardInk(c) return (c.s == 2 or c.s == 3) and colors.red or colors.black end

local function drawCardBox(x, y, w, h, c, hidden)
  if hidden or not c then
    fill(x, y, w, h, colors.blue)
    put(x + math.floor((w - 2) / 2), y + math.floor(h / 2), "??",
        colors.lightBlue, colors.blue)
    return
  end
  fill(x, y, w, h, colors.white)
  put(x + 1, y, RANK[c.r], cardInk(c), colors.white)
  if h >= 3 then
    put(x + math.floor((w - 1) / 2), y + math.floor(h / 2), SUITCH[c.s],
        cardInk(c), colors.white)
  end
  put(x + w - 2, y + h - 1, SUITCH[c.s], cardInk(c), colors.white)
end

local function newShoe(decks)
  local d = {}
  for _ = 1, decks or 6 do
    for r = 1, 13 do
      for s = 1, 4 do d[#d + 1] = { r = r, s = s } end
    end
  end
  for i = #d, 2, -1 do
    local j = math.random(i)
    d[i], d[j] = d[j], d[i]
  end
  return d
end

--======================== GAME: MEGA SLOTS ==============================
-- 5 reels x 3 rows, 1 to 9 selectable lines, bet is per line.
local MLINES = {
  { 2,2,2,2,2 }, { 1,1,1,1,1 }, { 3,3,3,3,3 },
  { 1,2,3,2,1 }, { 3,2,1,2,3 },
  { 1,1,2,3,3 }, { 3,3,2,1,1 }, { 2,1,1,1,2 }, { 2,3,3,3,2 },
}
local MSETS = { 1, 3, 5, 9 }

-- 3 / 4 / 5 matching from the left, as a multiple of the per-line bet
local MPAY = {
  ["C"] = {  8,  20,   80 },
  ["B"] = { 10,  30,  125 },
  ["="] = { 15,  45,  200 },
  ["*"] = { 25,  80,  400 },
  ["@"] = { 40, 150,  800 },
  ["7"] = { 80, 400, 2000 },
}

local function megaGrid()
  local g = {}
  for c = 1, 5 do
    g[c] = {}
    for r = 1, 3 do g[c][r] = spinSym() end
  end
  return g
end

local function megaEval(g, lines)
  local total, hits = 0, {}
  for li = 1, lines do
    local path  = MLINES[li]
    local first = g[1][path[1]]
    local n = 1
    for c = 2, 5 do
      if g[c][path[c]] == first then n = n + 1 else break end
    end
    if n >= 3 then
      local pay = MPAY[first.ch][n - 2]
      total = total + pay
      hits[#hits + 1] = { li = li, n = n, pay = pay, sym = first }
    end
  end
  return total, hits
end

local function megaDrawGrid(stake, lines)
  for _ = 1, 40 do
    local g = megaGrid()
    local total = megaEval(g, lines)
    if total == 0 then return g end
    if math.random() < stakeK(stake, total / lines) then return g end
  end
  local g
  repeat g = megaGrid() until megaEval(g, lines) == 0
  return g
end

local function megaPaytable()
  local function draw()
    frame("MEGA SLOTS PAYTABLE")
    put(3, 4, "PER LINE", colors.lightGray, colors.black)
    put(24, 4, "   3", colors.lightGray, colors.black)
    put(31, 4, "   4", colors.lightGray, colors.black)
    put(38, 4, "   5", colors.lightGray, colors.black)
    local y = 5
    for i = #SYM, 1, -1 do
      local s = SYM[i]
      put(3, y, s.ch .. " " .. s.ch .. " " .. s.ch, s.col, colors.black)
      put(11, y, s.name, colors.white, colors.black)
      local m = MPAY[s.ch]
      put(24, y, ("%4d"):format(m[1]), colors.yellow, colors.black)
      put(31, y, ("%4d"):format(m[2]), colors.yellow, colors.black)
      put(38, y, ("%4d"):format(m[3]), colors.yellow, colors.black)
      y = y + 1
    end
    putC(y + 1, "Counts from the leftmost reel. The bet is per line.",
         colors.lightGray, colors.black)
    button("back", 2, H - 1, 10, 1, "BACK", colors.blue, colors.white, "q")
    footer()
  end
  draw()
  while true do
    if waitAction(draw) == "back" then return end
  end
end

local function gameMega()
  sfx("enter")
  local grid     = megaGrid()
  local lineIx   = 2
  local winCells = {}
  local spinning = false
  local gy, iy, ly, by, ay = 4, 10, 11, 13, 15

  local function lines() return MSETS[lineIx] end
  local function stake() return bet * lines() end

  local function cellOn(col, row)
    for _, h in ipairs(winCells) do
      if col <= h.n and MLINES[h.li][col] == row then return true end
    end
    return false
  end

  local function drawGrid()
    local x0 = math.floor((W - 29) / 2) + 1
    for c = 1, 5 do
      for r = 1, 3 do
        local x, y = x0 + (c - 1) * 6, gy + (r - 1) * 2
        local lit  = (not spinning) and cellOn(c, r)
        local bgc  = lit and colors.white or colors.gray
        fill(x, y, 5, 2, bgc)
        put(x + 2, y, grid[c][r].ch, lit and colors.black or grid[c][r].col, bgc)
      end
    end
  end

  local function draw()
    frame("MEGA SLOTS  5x3")
    drawGrid()
    fill(1, iy, W, 1, colors.black)
    putC(iy, ("%d line(s) x %s = %s per spin")
             :format(lines(), fmt(bet), fmt(stake())),
         colors.lightGray, colors.black)
    fill(1, ly, W, 1, colors.black)
    put(2, ly, "LINES", colors.white, colors.black)
    local x = 9
    for i, nl in ipairs(MSETS) do
      button("ln" .. i, x, ly, 5, 1, tostring(nl),
             (i == lineIx) and colors.white or colors.gray,
             (i == lineIx) and colors.black or colors.white)
      x = x + 6
    end
    drawBetBar(by)
    button("spin", 2, ay, 12, 1, "SPIN", colors.green, colors.white, " ")
    button("pay", 16, ay, 12, 1, "PAYTABLE", colors.gray, colors.white, "p")
    button("back", W - 10, ay, 9, 1, "BACK", colors.blue, colors.white, "q")
    footer()
  end

  draw()
  while true do
    local id = waitAction(draw)
    if handleBet(id) then
      draw()
    elseif id == "back" then
      return
    elseif id == "pay" then
      megaPaytable(); draw()
    elseif type(id) == "string" and id:match("^ln%d$") then
      lineIx   = tonumber(id:sub(3))
      winCells = {}
      sfx("select")
      draw()
    elseif id == "spin" then
      if canPlay(stake()) then
        local st = stake()
        placeBet(st)
        winCells = {}
        msg("Spinning...", colors.white)
        draw()
        local final = megaDrawGrid(st, lines())
        spinning = true
        local stop = { 8, 11, 14, 17, 20 }
        for step = 1, 20 do
          for c = 1, 5 do
            if step < stop[c] then
              for r = 1, 3 do grid[c][r] = spinSym() end
            else
              for r = 1, 3 do grid[c][r] = final[c][r] end
            end
            if step == stop[c] then sfx("reelstop") end
          end
          drawGrid()
          if step % 2 == 0 then sfx("tick") end
          sleep(0.05)
        end
        spinning = false
        grid = final

        local total, hits = megaEval(grid, lines())
        winCells = hits
        drawGrid()
        if total > 0 then
          local got  = award(total * bet)
          local best = hits[1]
          for _, h in ipairs(hits) do if h.pay > best.pay then best = h end end
          msg(("%d line(s) hit - %s x%d - WIN %s")
              :format(#hits, best.sym.name, best.n, fmt(got)), colors.lime)
          winSound(got)
        else
          save()
          msg("No line paid.", colors.lightGray)
          sfx("lose")
        end
        draw()
      else
        footer()
      end
    end
  end
end

--======================== GAME: BLACKJACK ===============================
local function handValue(h)
  local total, aces = 0, 0
  for _, c in ipairs(h) do
    local v = math.min(10, c.r)
    if c.r == 1 then aces = aces + 1; v = 11 end
    total = total + v
  end
  while total > 21 and aces > 0 do total = total - 10; aces = aces - 1 end
  return total
end

local function gameBlack()
  sfx("enter")
  local shoe = newShoe(6)
  local you, dealer = {}, {}
  local state = "idle"
  local staked, hole = 0, true
  local dy, py, by, ay = 4, 9, 13, 15

  -- draws a card, sometimes taking the better of two for the house
  local function take(forDealer)
    if #shoe < 20 then shoe = newShoe(6) end
    local c = table.remove(shoe)
    local n = math.max(CFG.curve.bjFloor, 1 - stakeK(bet, 2))
    if n > 0 and math.random() < n and #shoe > 0 then
      local alt  = table.remove(shoe)
      local base = forDealer and dealer or you
      local function score(card)
        local probe = {}
        for i, b in ipairs(base) do probe[i] = b end
        probe[#probe + 1] = card
        local v = handValue(probe)
        if forDealer then return (v > 21) and -100 or v end
        return (v > 21) and 100 or -v
      end
      if score(alt) > score(c) then
        shoe[#shoe + 1] = c
        return alt
      end
      shoe[#shoe + 1] = alt
    end
    return c
  end

  local function drawHand(h, y, hideSecond)
    fill(1, y, W, 3, colors.black)
    local x = 3
    for i, c in ipairs(h) do
      if x + 4 <= W then
        drawCardBox(x, y, 4, 3, c, hideSecond and i == 2)
        x = x + 5
      end
    end
  end

  local function draw()
    frame("BLACKJACK")
    local shown = "-"
    if #dealer > 0 then
      shown = hole and (#dealer > 1) and (handValue({ dealer[1] }) .. "+")
              or tostring(handValue(dealer))
    end
    fill(1, dy - 1, W, 1, colors.black)
    put(3, dy - 1, "DEALER  " .. shown, colors.lightGray, colors.black)
    drawHand(dealer, dy, hole)
    fill(1, py - 1, W, 1, colors.black)
    put(3, py - 1, "YOU     " .. ((#you > 0) and tostring(handValue(you)) or "-"),
        colors.lightGray, colors.black)
    drawHand(you, py, false)

    fill(1, by, W, 1, colors.black)
    if state == "play" then
      putC(by, "Dealer stands on 17, BJ 3:2 - staked " .. fmt(staked),
           colors.lightGray, colors.black)
    else
      drawBetBar(by)
    end

    fill(1, ay, W, 1, colors.black)
    if state == "play" then
      button("hit", 2, ay, 10, 1, "HIT", colors.green, colors.white, " ")
      button("stand", 13, ay, 10, 1, "STAND", colors.red, colors.white, "s")
      if #you == 2 and bank.credits >= staked then
        button("dbl", 24, ay, 10, 1, "DOUBLE", colors.orange, colors.black, "d")
      end
    else
      button("deal", 2, ay, 12, 1, "DEAL", colors.green, colors.white, " ")
    end
    button("back", W - 10, ay, 9, 1, "BACK", colors.blue, colors.white, "q")
    footer()
  end

  local function settle()
    hole = false
    draw()
    sleep(0.4)
    while handValue(dealer) < 17 do
      dealer[#dealer + 1] = take(true)
      draw()
      sfx("card")
      sleep(0.45)
    end
    local pv, dv = handValue(you), handValue(dealer)
    local natural = (#you == 2 and pv == 21)
    local dnat    = (#dealer == 2 and dv == 21)
    local got, text
    if pv > 21 then
      text = "BUST - lost " .. fmt(staked)
    elseif natural and not dnat then
      got = award(math.floor(staked * 2.5)); text = "BLACKJACK - WIN " .. fmt(got)
    elseif dv > 21 then
      got = award(staked * 2); text = "Dealer busts - WIN " .. fmt(got)
    elseif pv > dv then
      got = award(staked * 2); text = pv .. " beats " .. dv .. " - WIN " .. fmt(got)
    elseif pv == dv then
      got = award(staked); text = "Push - " .. fmt(staked) .. " returned"
    else
      text = dv .. " beats " .. pv .. " - lost " .. fmt(staked)
    end
    if got then winSound(got) else sfx("lose"); save() end
    msg(text, got and colors.lime or colors.lightGray)
    state = "done"
    draw()
  end

  draw()
  while true do
    local id = waitAction(draw)
    if state ~= "play" and handleBet(id) then
      draw()
    elseif id == "back" then
      return
    elseif id == "deal" and state ~= "play" then
      if canPlay() then
        placeBet()
        staked = bet
        you, dealer, hole = {}, {}, true
        you[1]    = take(false)
        dealer[1] = take(true)
        you[2]    = take(false)
        dealer[2] = take(true)
        state = "play"
        msg("Hit or stand?", colors.white)
        sfx("card")
        draw()
        if handValue(you) == 21 then settle() end
      else
        footer()
      end
    elseif id == "hit" and state == "play" then
      you[#you + 1] = take(false)
      sfx("card")
      draw()
      if handValue(you) >= 21 then settle() end
    elseif id == "stand" and state == "play" then
      settle()
    elseif id == "dbl" and state == "play" and #you == 2 then
      if canPlay(staked) then
        placeBet(staked)
        staked = staked * 2
        you[#you + 1] = take(false)
        sfx("card")
        draw()
        settle()
      else
        footer()
      end
    end
  end
end

--======================== GAME: POKER ===================================
-- Five card draw, jacks or better.
local PPAY = {
  { 250, "ROYAL FLUSH"     }, { 50, "STRAIGHT FLUSH" },
  { 25,  "FOUR OF A KIND"  }, { 7,  "FULL HOUSE"     },
  { 5,   "FLUSH"           }, { 4,  "STRAIGHT"       },
  { 3,   "THREE OF A KIND" }, { 2,  "TWO PAIR"       },
  { 1,   "JACKS OR BETTER" },
}

local function pokerEval(h)
  local cnt, suit = {}, {}
  for _, c in ipairs(h) do
    cnt[c.r]  = (cnt[c.r] or 0) + 1
    suit[c.s] = (suit[c.s] or 0) + 1
  end
  local flush = false
  for _, k in pairs(suit) do if k == 5 then flush = true end end

  local rs = {}
  for _, c in ipairs(h) do rs[#rs + 1] = c.r end
  table.sort(rs)
  local straight, acehigh = true, false
  for i = 2, 5 do
    if rs[i] ~= rs[i - 1] + 1 then straight = false break end
  end
  if not straight and rs[1] == 1 and rs[2] == 10 and rs[3] == 11
     and rs[4] == 12 and rs[5] == 13 then
    straight, acehigh = true, true
  end

  local twos, three, four, goodPair = 0, false, false, false
  for r, k in pairs(cnt) do
    if k == 4 then four = true
    elseif k == 3 then three = true
    elseif k == 2 then
      twos = twos + 1
      if r == 1 or r >= 11 then goodPair = true end
    end
  end

  -- PPAY is the single source of names and payouts (also drawn by the paytable)
  local hand
  if     straight and flush and acehigh then hand = 1
  elseif straight and flush             then hand = 2
  elseif four                           then hand = 3
  elseif three and twos == 1            then hand = 4
  elseif flush                          then hand = 5
  elseif straight                       then hand = 6
  elseif three                          then hand = 7
  elseif twos == 2                      then hand = 8
  elseif twos == 1 and goodPair         then hand = 9
  end
  if hand then return PPAY[hand][1], PPAY[hand][2] end
  return 0, "NO WIN"
end

local function pokerPaytable()
  local function draw()
    frame("POKER PAYTABLE")
    local y = 4
    for _, e in ipairs(PPAY) do
      put(4, y, e[2], colors.white, colors.black)
      put(W - 10, y, "x" .. e[1], colors.yellow, colors.black)
      y = y + 1
    end
    putC(y + 1, "Five card draw. Hold what you keep, then DRAW.",
         colors.lightGray, colors.black)
    button("back", 2, H - 1, 10, 1, "BACK", colors.blue, colors.white, "q")
    footer()
  end
  draw()
  while true do
    if waitAction(draw) == "back" then return end
  end
end

local function gamePoker()
  sfx("enter")
  local hand  = {}
  local hold  = { false, false, false, false, false }
  local state = "idle"
  local cy, hy, ry, by, ay = 4, 9, 11, 13, 15

  local function drawCards()
    local x0 = math.floor((W - 39) / 2) + 1
    for i = 1, 5 do
      local x = x0 + (i - 1) * 8
      drawCardBox(x, cy, 7, 5, hand[i], state == "idle")
      fill(x, hy, 7, 1, colors.black)
      if state == "draw" then
        button("h" .. i, x, hy, 7, 1, hold[i] and "HELD" or "hold",
               hold[i] and colors.lime or colors.gray,
               hold[i] and colors.black or colors.white, tostring(i))
      elseif state == "done" and hold[i] then
        put(x + 1, hy, "kept", colors.lightGray, colors.black)
      end
    end
  end

  local function draw()
    frame("POKER")
    fill(1, cy, W, 6, colors.black)
    drawCards()
    fill(1, ry, W, 1, colors.black)
    if state == "draw" then
      putC(ry, "Pick the cards to keep, then DRAW", colors.lightGray, colors.black)
    else
      putC(ry, "A pair of jacks or better pays - royal flush x250",
           colors.lightGray, colors.black)
    end
    if state == "draw" then
      fill(1, by, W, 1, colors.black)
      putC(by, "Staked " .. fmt(bet), colors.lightGray, colors.black)
    else
      drawBetBar(by)
    end
    fill(1, ay, W, 1, colors.black)
    button("go", 2, ay, 12, 1, (state == "draw") and "DRAW" or "DEAL",
           colors.green, colors.white, " ")
    button("pay", 16, ay, 12, 1, "PAYTABLE", colors.gray, colors.white, "p")
    button("back", W - 10, ay, 9, 1, "BACK", colors.blue, colors.white, "q")
    footer()
  end

  draw()
  while true do
    local id = waitAction(draw)
    if state ~= "draw" and handleBet(id) then
      draw()
    elseif id == "back" then
      return
    elseif id == "pay" then
      pokerPaytable(); draw()
    elseif type(id) == "string" and id:match("^h%d$") and state == "draw" then
      local i = tonumber(id:sub(2))
      hold[i] = not hold[i]
      sfx("select")
      draw()
    elseif id == "go" and state == "draw" then
      local keep = {}
      for i = 1, 5 do if hold[i] then keep[i] = hand[i] end end
      local final
      for _ = 1, 30 do
        local pool = newShoe(1)
        for i = 1, 5 do
          if keep[i] then
            for k, c in ipairs(pool) do
              if c.r == keep[i].r and c.s == keep[i].s then
                table.remove(pool, k)
                break
              end
            end
          end
        end
        local try = {}
        for i = 1, 5 do try[i] = keep[i] or table.remove(pool) end
        local mult = pokerEval(try)
        if mult == 0 or math.random() < stakeK(bet, mult) then
          final = try
          break
        end
      end
      if not final then
        local pool = newShoe(1)
        final = {}
        for i = 1, 5 do final[i] = keep[i] or table.remove(pool) end
      end
      for i = 1, 5 do
        if not hold[i] then
          hand[i] = final[i]
          drawCards()
          sfx("card")
          sleep(0.18)
        end
      end
      state = "done"
      local mult, name = pokerEval(hand)
      if mult > 0 then
        local got = award(bet * mult)
        msg(name .. " - WIN " .. fmt(got), colors.lime)
        winSound(got)
      else
        save()
        msg("No hand - " .. name, colors.lightGray)
        sfx("lose")
      end
      draw()
    elseif id == "go" then
      if canPlay() then
        placeBet()
        local shoe = newShoe(1)
        hand = {}
        for i = 1, 5 do hand[i] = table.remove(shoe) end
        hold  = { false, false, false, false, false }
        state = "draw"
        msg("Hold what you want to keep", colors.white)
        sfx("card")
        draw()
      else
        footer()
      end
    end
  end
end

--======================== GAME: WHEEL ===================================
-- 24 segments, pointer fixed at the top, the ring turns under it.
local WSEG = {
  0, 1, 0, 0, 1.5, 0, 1, 0, 1, 2, 0, 1,
  0, 12, 0, 1, 0, 0, 1.5, 0, 1, 0, 0, 0,
}

local function segColour(m)
  if m == 0   then return colors.gray   end
  if m <= 1   then return colors.lime   end
  if m <= 1.5 then return colors.cyan   end
  if m <= 2   then return colors.yellow end
  return colors.magenta
end

local function wheelPick(stake)
  for _ = 1, 40 do
    local i = math.random(#WSEG)
    if WSEG[i] == 0 then return i end
    if math.random() < stakeK(stake, WSEG[i]) then return i end
  end
  local i
  repeat i = math.random(#WSEG) until WSEG[i] == 0
  return i
end

local function gameWheel()
  sfx("enter")
  local n      = #WSEG
  local offset = 0
  local cx, cy = math.floor(W / 2), 8
  local rx, ry = math.min(14, math.floor(W / 2) - 4), 4
  local by, ay = 14, 16

  local function segAt(k) return WSEG[((k + offset - 2) % n) + 1] end

  local function drawRing()
    fill(1, 3, W, 2 * ry + 2, colors.black)
    put(cx, 3, "V", colors.white, colors.black)
    for k = 1, n do
      local a = 2 * math.pi * (k - 1) / n
      local x = cx + math.floor(rx * math.sin(a) + 0.5)
      local y = cy - math.floor(ry * math.cos(a) + 0.5)
      fill(x - 1, y, 2, 1, (k == 1) and colors.white or segColour(segAt(k)))
    end
    local m = segAt(1)
    fill(cx - 6, cy - 1, 13, 3, colors.black)
    local s = (m == 0) and "LOSE" or ("x" .. ("%.4g"):format(m))
    put(cx - math.floor(#s / 2), cy, s,
        (m == 0) and colors.gray or segColour(m), colors.black)
  end

  local function draw()
    frame("WHEEL OF FORTUNE")
    drawRing()
    drawBetBar(by)
    fill(1, ay, W, 1, colors.black)
    button("spin", 2, ay, 12, 1, "SPIN", colors.green, colors.white, " ")
    local top = 0
    for _, m in ipairs(WSEG) do if m > top then top = m end end
    put(16, ay, "TOP PRIZE x" .. top, colors.magenta, colors.black)
    button("back", W - 10, ay, 9, 1, "BACK", colors.blue, colors.white, "q")
    footer()
  end

  draw()
  while true do
    local id = waitAction(draw)
    if handleBet(id) then
      draw()
    elseif id == "back" then
      return
    elseif id == "spin" then
      if canPlay() then
        placeBet()
        msg("Round and round...", colors.white)
        footer()
        local target = wheelPick(bet)
        local want   = (target - 1) % n
        local steps  = 3 * n + ((want - offset) % n)
        for i = 1, steps do
          offset = (offset + 1) % n
          drawRing()
          sfx("wheel")
          sleep(0.02 + 0.16 * (i / steps) ^ 3)
        end
        local landed = segAt(1)
        drawRing()
        if landed > 0 then
          local got = award(bet * landed)
          msg(("x%.4g - WIN %s"):format(landed, fmt(got)), colors.lime)
          winSound(got)
        else
          save()
          msg("No prize this time.", colors.lightGray)
          sfx("lose")
        end
        draw()
      else
        footer()
      end
    end
  end
end

--======================== KEYPAD ========================================
-- On-screen digit entry. Returns the digits typed, or nil if backed out.
-- mask = true hides the digits (used for the service PIN).
local function readDigits(title, maxLen, mask)
  maxLen = maxLen or 8
  local entry = ""
  local keys  = { "1","2","3","4","5","6","7","8","9","CLR","0","OK" }
  local bar   = mask and colors.red or colors.blue

  local function draw()
    fill(1, 1, W, H, colors.black)
    clearButtons()
    fill(1, 1, W, 1, bar)
    put(2, 1, tostring(title):sub(1, W - 2), colors.white, bar)
    local shown
    if mask then
      shown = string.rep("*", #entry) .. string.rep("_", math.max(0, 4 - #entry))
    else
      shown = (entry == "") and "_" or entry
    end
    putC(3, shown, colors.white, colors.black)
    local x0 = math.floor(W / 2) - 8
    for i, k in ipairs(keys) do
      local c, r = (i - 1) % 3, math.floor((i - 1) / 3)
      button("k" .. k, x0 + c * 6, 5 + r * 2, 5, 1, k,
             (k == "OK") and colors.green or (k == "CLR") and colors.orange or colors.gray,
             colors.white, k:match("^%d$") and k or nil)
    end
    button("kBACK", 2, H - 1, 10, 1, "BACK", colors.blue, colors.white, "q")
    footer()
  end

  draw()
  while true do
    local id = waitAction(draw)
    if id == "kBACK" then
      return nil
    elseif id == "kOK" then
      return entry
    elseif id == "kCLR" then
      entry = ""; draw()
    elseif type(id) == "string" and id:match("^k%d$") then
      if #entry < maxLen then entry = entry .. id:sub(2) end
      draw()
    end
  end
end

-- keypad wrapper that returns a whole number inside [lo, hi], or nil
local function readNumber(title, lo, hi, digits)
  local s = readDigits(title, digits or 8, false)
  if not s or s == "" then return nil end
  local n = math.floor(tonumber(s) or 0)
  if n < lo then n = lo end
  if n > hi then n = hi end
  return n
end

--======================== MARKET ========================================
-- Player-to-player trading. Listed goods are escrowed in the BANK, sale
-- proceeds wait in per-name wallets, and every name-bound action is signed
-- by a right-click on the Advanced Peripherals Player Detector: the server
-- names the player who clicked, so nobody can act as someone else.
local MK = CFG.market
local mkLastSign = 0

local function itemLabel(id)
  return (tostring(id):gsub("^[^:]*:", ""):gsub("_", " "))
end

local function mkAlert(text)
  local m = bank.market
  m.alerts[#m.alerts + 1] = text
  while #m.alerts > 30 do table.remove(m.alerts, 1) end
end

local function mkFind(id)
  for i, l in ipairs(bank.market.lots) do
    if l.id == id then return l, i end
  end
  return nil
end

local function mkDrop(l)
  for i, x in ipairs(bank.market.lots) do
    if x == l then table.remove(bank.market.lots, i); return end
  end
end

local function mkEscrow(item)
  local n = 0
  for _, l in ipairs(bank.market.lots) do
    if l.item == item then n = n + l.qty end
  end
  return n
end

local function mkOpen(name)
  local n = 0
  for _, l in ipairs(bank.market.lots) do
    if l.seller == name then n = n + 1 end
  end
  return n
end

local function mkOwed()
  local n = 0
  for _, v in pairs(bank.market.wallet) do n = n + v end
  return n
end

local function mkFee(paid)
  return math.min(paid, math.ceil(paid * MK.fee))
end

-- IN = gross paid by buyers (+ listing fees), OUT = credited to wallets,
-- so the GAME P/L page shows the fees kept
local function mkBook(gross, toWallet)
  local g = statFor("market")
  g.w, g.p, g.r = g.w + gross, g.p + toWallet, g.r + 1
end

-- non-currency goods in the TELLER, by id: clean count and marked (nbt) count
local function tellerGoods()
  local byId, order = {}, {}
  local ok, list = pcall(tellerInv.list)
  if not ok or type(list) ~= "table" then return byId, order end
  for _, st in pairs(list) do
    if not VALUE[st.name] then
      local g = byId[st.name]
      if not g then
        g = { id = st.name, clean = 0, marked = 0 }
        byId[st.name] = g
        order[#order + 1] = g
      end
      if st.nbt then g.marked = g.marked + st.count else g.clean = g.clean + st.count end
    end
  end
  table.sort(order, function(a, b) return a.id < b.id end)
  return byId, order
end

local function tellerHas(id)
  local ok, list = pcall(tellerInv.list)
  if not ok or type(list) ~= "table" then return false end
  for _, st in pairs(list) do
    if st.name == id then return true end
  end
  return false
end

local function tellerMarked(id)
  local n = 0
  local ok, list = pcall(tellerInv.list)
  if ok and type(list) == "table" then
    for _, st in pairs(list) do
      if st.name == id and st.nbt then n = n + st.count end
    end
  end
  return n
end

-- one-slot journal, written before every goods move and reconciled at boot
local function mkJournal(kind, l, want, cost)
  bank.market.pending = {
    kind = kind, id = l.id, item = l.item, want = want, cost = cost or 0,
    before = bankStock(l.item), seller = l.seller, at = nowMs(),
  }
  save()
end

local function mkSettle()
  bank.market.pending = nil
end

local function mkReady()
  if not detector then
    msg("No Player Detector - call the owner", colors.red); sfx("deny"); return false
  end
  if bankOffline then
    msg("The bank storage is offline - call the owner", colors.red); sfx("deny"); return false
  end
  if busy then
    msg("Machine is busy - try again", colors.orange); sfx("deny"); return false
  end
  return true
end

--------------------------------------------------------------- identity
local function mkInRange(name)
  if not detector then return false end
  local ok, r = pcall(detector.isPlayerInRange, MK.range, name)
  return ok and r == true
end

local function mkAlone()
  if not detector then return nil, "No Player Detector attached" end
  local ok, list = pcall(detector.getPlayersInRange, MK.range)
  if not ok or type(list) ~= "table" then return nil, "Player Detector error" end
  if #list == 1 then return list[1] end
  if #list == 0 then
    return nil, ("Stand within %d blocks of the detector"):format(MK.range)
  end
  return nil, "Several players at the terminal - others step back"
end

-- SIGN screen. Waits for a right-click on the Player Detector and returns
-- the name the server attached to that click, or nil when cancelled.
-- `expect` pins the action to one name (collect / cancel).
local function mkSign(purpose, expect)
  if not detector then
    msg("No Player Detector - call the owner", colors.red); sfx("deny"); return nil
  end
  if nowMs() - mkLastSign < MK.cooldown * 1000 then
    msg("Too fast - wait a moment", colors.orange); sfx("deny"); return nil
  end
  local opened   = nowMs()
  local deadline = opened + MK.signTimeout * 1000
  local alone    = (MK.sign == "alone")
  pcall(os.startTimer, 1)

  local function draw()
    frame("SIGN")
    putC(5, "RIGHT-CLICK THE PLAYER DETECTOR", colors.yellow, colors.black)
    for i, line in ipairs(purpose) do
      putC(6 + i, line, colors.white, colors.black)
    end
    local left = math.max(0, math.ceil((deadline - nowMs()) / 1000))
    putC(11, ("waiting  %d s"):format(left), colors.lightGray, colors.black)
    if expect then
      putC(12, "only " .. expect .. " can sign this", colors.lightGray, colors.black)
    end
    putC(14, "The server names the player who clicks,", colors.gray, colors.black)
    putC(15, "so nobody can sign for you.", colors.gray, colors.black)
    if alone then
      button("confirm", 2, H - 2, 12, 1, "CONFIRM", colors.green, colors.white, " ")
      button("back", 16, H - 2, 10, 1, "CANCEL", colors.blue, colors.white, "q")
    else
      button("back", 2, H - 2, 10, 1, "CANCEL", colors.blue, colors.white, "q")
    end
    footer()
  end

  local function accept(name)
    if expect and name ~= expect then
      msg("That was " .. tostring(name) .. " - nothing done", colors.orange)
      sfx("deny")
      return nil, true
    end
    mkLastSign = nowMs()
    sfx("enter")
    return name, true
  end

  local function confirmAlone()
    local name, why = mkAlone()
    if not name then
      msg(why, colors.orange); sfx("deny"); draw()
      return nil, false
    end
    return accept(name)
  end

  draw()
  while true do
    local t, a, b = pullUI()
    if t == "sign" then
      -- clicks queued before this screen opened arrive at once: ignore them
      local ok = (nowMs() - opened) >= 250
      if ok and detName and b ~= nil and b ~= detName then ok = false end
      if ok and not mkInRange(a) then ok = false end
      if ok then
        local name, done = accept(a)
        if done then return name end
      end
    elseif t == "click" then
      local id = hitTest(a, b)
      if id == "back" then return nil end
      if id == "confirm" and alone then
        local name, done = confirmAlone()
        if done then return name end
      end
    elseif t == "char" then
      if a == "q" then return nil end
      if a == " " and alone then
        local name, done = confirmAlone()
        if done then return name end
      end
    elseif t == "timer" then
      if nowMs() >= deadline then
        msg("Sign timed out - nothing done", colors.orange)
        return nil
      end
      pcall(os.startTimer, 1)
      draw()
    elseif t == "update" or t == "resize" then
      draw()
    end
  end
end

--------------------------------------------------------------- actions
local function mkList(name, id, lot, price, lots)
  if not mkReady() then return false end
  local m = bank.market
  if #m.lots >= MK.maxTotal then
    msg("The board is full - try later", colors.orange); sfx("deny"); return false
  end
  if mkOpen(name) >= MK.maxOpen then
    msg(("You already have %d listings - cancel one first"):format(MK.maxOpen),
        colors.orange); sfx("deny"); return false
  end
  if MK.listFee > 0 and bank.credits < MK.listFee then
    msg(("Listing fee is %d credit(s) - insert a coin first"):format(MK.listFee),
        colors.orange); sfx("deny"); return false
  end
  local goods = tellerGoods()
  local g = goods[id]
  if not g or g.marked > 0 then
    msg("Take out enchanted/renamed " .. itemLabel(id) .. " first", colors.orange)
    sfx("deny"); return false
  end
  lots = math.min(lots, math.floor(g.clean / lot))
  if lots < 1 then
    msg(("Only %d clean %s in the TELLER"):format(g.clean, itemLabel(id)), colors.orange)
    sfx("deny"); return false
  end
  local want = lot * lots

  if MK.listFee > 0 then bank.credits = bank.credits - MK.listFee end
  local l = { id = m.next, seller = name, item = id, lot = lot, price = price,
              qty = 0, hold = "moving" }
  m.next = m.next + 1
  m.lots[#m.lots + 1] = l
  mkJournal("list", l, want, 0)

  local moved = bankTake(id, want)
  mkSettle()
  if moved <= 0 then
    mkDrop(l)
    if MK.listFee > 0 then bank.credits = bank.credits + MK.listFee end
    save()
    msg("Nothing moved - the bank refused the goods", colors.red)
    sfx("alarm")
    return false
  end
  l.qty, l.hold = moved, nil
  if MK.listFee > 0 then statFor("market").w = statFor("market").w + MK.listFee end
  save()
  msg(("Listed %d %s at %s per %d - #%d"):format(moved, itemLabel(id), fmt(price), lot, l.id)
      .. ((moved < want) and " (bank took part)" or ""), colors.lime)
  sfx("coin")
  return true
end

local function mkBuy(l, lots)
  if not mkReady() then return end
  if l.hold then
    msg("This listing is on hold - ask the owner", colors.orange); sfx("deny"); return
  end
  if isRS() and tellerHas(l.item) then
    msg("Take the " .. itemLabel(l.item) .. " out of the TELLER first", colors.orange)
    sfx("deny"); return
  end
  local want = math.min(lots * l.lot, l.qty)
  local cost = math.ceil(l.price * want / l.lot)
  if bank.credits < cost then
    msg("Not enough credits - you need " .. fmt(cost), colors.orange); sfx("deny"); return
  end

  -- reserve the credits, journal, move, then refund what did not arrive
  bank.credits = bank.credits - cost
  mkJournal("buy", l, want, cost)
  local moved = bankGive(l.item, want)
  local paid  = (moved > 0) and math.ceil(cost * moved / want) or 0
  bank.credits = bank.credits + (cost - paid)
  local fee, net = 0, 0
  if paid > 0 then
    fee, net = mkFee(paid), paid - mkFee(paid)
    if net > 0 then
      bank.market.wallet[l.seller] = (bank.market.wallet[l.seller] or 0) + net
    end
    mkBook(paid, net)
    l.qty = l.qty - moved
  end
  mkSettle()

  if moved <= 0 then
    save()
    if bankStock(l.item) < want then
      msg("The bank holds less than listed - tell the owner", colors.red)
    else
      msg("Nothing moved - empty the TELLER first", colors.red)
    end
    sfx("alarm")
    return
  end

  -- RS matches by id only: if a marked variant came out, undo the sale
  if isRS() then
    local bad = tellerMarked(l.item)
    if bad > 0 then
      local back = bankTake(l.item, moved)
      bank.credits = bank.credits + paid
      if net > 0 then
        local w = (bank.market.wallet[l.seller] or 0) - net
        bank.market.wallet[l.seller] = (w > 0) and w or nil
      end
      local g = statFor("market")
      g.w, g.p = g.w - paid, g.p - net
      l.qty  = l.qty + back
      l.hold = "variant"
      mkAlert(("#%d %s: marked variant delivered, %d taken back, refunded %d")
              :format(l.id, itemLabel(l.item), back, paid))
      save()
      msg("Wrong variant came out - refunded, on hold", colors.red)
      sfx("alarm")
      return
    end
  end

  if l.qty <= 0 then mkDrop(l) end
  save()
  msg(("Bought %d %s for %s - in the TELLER"):format(moved, itemLabel(l.item), fmt(paid))
      .. ((moved < want) and " (teller full)" or ""), colors.lime)
  sfx("cashout")
end

local function mkCancel(l, name)
  if l.seller ~= name then
    msg("Only " .. l.seller .. " can cancel this", colors.orange); sfx("deny"); return
  end
  if not mkReady() then return end
  mkJournal("cancel", l, l.qty, 0)
  local moved = bankGive(l.item, l.qty)
  mkSettle()
  if moved <= 0 then
    save()
    if bankStock(l.item) < l.qty then
      msg("The bank holds less than listed - tell the owner", colors.red)
    else
      msg("Nothing moved - empty the TELLER first", colors.red)
    end
    sfx("alarm")
    return
  end
  l.qty = l.qty - moved
  if l.qty <= 0 then mkDrop(l) end
  save()
  msg(("Returned %d %s to the TELLER"):format(moved, itemLabel(l.item))
      .. ((l.qty > 0) and (" - " .. l.qty .. " still listed") or ""), colors.lime)
  sfx("collected")
end

local function mkCollect(name)
  local w = bank.market.wallet[name] or 0
  if w < 1 then
    msg("Nothing to collect", colors.orange); sfx("deny"); return
  end
  bank.market.wallet[name] = nil
  bank.credits = bank.credits + w
  save()
  msg(("Collected %s - CASH OUT before you leave"):format(fmt(w)), colors.lime)
  sfx("cashout")
end

-- settle a goods move that was interrupted by a reboot, from the stock delta
local function mkRecover()
  local p = bank.market.pending
  if type(p) ~= "table" then return end
  bank.market.pending = nil
  local now   = bankStock(p.item)
  local want  = math.max(0, math.floor(tonumber(p.want) or 0))
  local before = math.floor(tonumber(p.before) or 0)
  local l     = mkFind(p.id)
  local moved = 0
  if p.kind == "list" then
    moved = math.max(0, math.min(want, now - before))
    if l then
      if moved > 0 then l.qty, l.hold = moved, nil else mkDrop(l) end
    end
  elseif p.kind == "buy" then
    moved = math.max(0, math.min(want, before - now))
    local cost = math.floor(tonumber(p.cost) or 0)
    local paid = (moved > 0 and want > 0) and math.ceil(cost * moved / want) or 0
    bank.credits = bank.credits + (cost - paid)
    if paid > 0 then
      local net = paid - mkFee(paid)
      if net > 0 and type(p.seller) == "string" then
        bank.market.wallet[p.seller] = (bank.market.wallet[p.seller] or 0) + net
      end
      mkBook(paid, net)
      if l then
        l.qty = l.qty - moved
        if l.qty <= 0 then mkDrop(l) end
      end
    end
  elseif p.kind == "cancel" then
    moved = math.max(0, math.min(want, before - now))
    if l then
      l.qty = l.qty - moved
      if l.qty <= 0 then mkDrop(l) end
    end
  end
  mkAlert(("recovered interrupted %s #%s: assumed %d moved")
          :format(tostring(p.kind), tostring(p.id), moved))
  save()
end

--------------------------------------------------------------- screens
local function mkSellScreen()
  local byId, order = tellerGoods()
  if #order == 0 then
    msg("Put the goods into the TELLER first", colors.orange); sfx("deny"); return
  end
  local sel, ay = 1, H - 2

  local function draw()
    frame("SELL")
    put(2, 3, "IN THE TELLER", colors.lightGray, colors.black)
    rput(41, 3, "CLEAN", colors.lightGray, colors.black)
    rput(48, 3, "NBT", colors.lightGray, colors.black)
    for i = 1, math.min(#order, 9) do
      local g  = order[i]
      local y  = 3 + i
      local bg = (i == sel) and colors.gray or colors.black
      fill(1, y, W, 1, bg)
      put(2, y, itemLabel(g.id):sub(1, 30), (g.marked > 0) and colors.red or colors.white, bg)
      rput(41, y, tostring(g.clean), colors.white, bg)
      rput(48, y, (g.marked > 0) and tostring(g.marked) or "-",
           (g.marked > 0) and colors.red or colors.gray, bg)
      ghost("row" .. i, 1, y, W, 1)
    end
    putC(14, "Enchanted, renamed or damaged stacks (NBT)", colors.lightGray, colors.black)
    putC(15, "block that item - take them out first.", colors.lightGray, colors.black)
    button("go", 2, ay, 12, 1, "LIST THIS", colors.green, colors.white, " ")
    button("back", W - 10, ay, 9, 1, "BACK", colors.blue, colors.white, "q")
    footer()
  end

  draw()
  while true do
    local id = waitAction(draw)
    if id == "back" then
      return
    elseif type(id) == "string" and id:match("^row%d$") then
      sel = tonumber(id:sub(4)); sfx("select"); draw()
    elseif id == "go" then
      local g = order[sel]
      if not g then
        draw()
      elseif g.marked > 0 then
        msg("Take out enchanted/renamed " .. itemLabel(g.id) .. " first", colors.orange)
        sfx("deny"); footer()
      else
        local lot = readNumber(("LOT SIZE  (1-%d per lot)"):format(math.min(MK.maxLot, g.clean)),
                               1, math.min(MK.maxLot, g.clean), 3)
        if not lot then msg("Listing cancelled", colors.lightGray); return end
        local price = readNumber("PRICE PER LOT  (credits)", MK.minPrice, 99999999, 8)
        if not price then msg("Listing cancelled", colors.lightGray); return end
        local maxLots = math.min(MK.maxLots, math.floor(g.clean / lot))
        local lots = readNumber(("HOW MANY LOTS  (max %d)"):format(maxLots), 1, maxLots, 3)
        if not lots then msg("Listing cancelled", colors.lightGray); return end

        -- confirm screen
        local function cdraw()
          frame("SELL - CONFIRM")
          put(8, 4, "Item    " .. itemLabel(g.id):sub(1, 30), colors.white, colors.black)
          put(8, 5, ("Lot     %d items"):format(lot), colors.white, colors.black)
          put(8, 6, ("Price   %s credits per lot"):format(fmt(price)), colors.white, colors.black)
          put(8, 7, ("Lots    %d   (%d items go into escrow)"):format(lots, lot * lots),
              colors.white, colors.black)
          put(8, 8, ("You get %s per lot after the %d%% fee"):format(
                fmt(price - mkFee(price)), math.floor(MK.fee * 100 + 0.5)), colors.yellow, colors.black)
          if MK.listFee > 0 then
            put(8, 9, ("Listing fee %d credit(s), taken on sign"):format(MK.listFee),
                colors.orange, colors.black)
          end
          putC(11, "The goods move into the bank now and come", colors.lightGray, colors.black)
          putC(12, "back only when you CANCEL. Sales go to your", colors.lightGray, colors.black)
          putC(13, "wallet: MARKET > MINE > COLLECT.", colors.lightGray, colors.black)
          button("sign", 2, ay, 14, 1, "SIGN & LIST", colors.green, colors.white, " ")
          button("back", W - 10, ay, 9, 1, "BACK", colors.blue, colors.white, "q")
          footer()
        end
        cdraw()
        while true do
          local cid = waitAction(cdraw)
          if cid == "back" then
            return
          elseif cid == "sign" then
            local name = mkSign({
              ("to LIST %d %s"):format(lot * lots, itemLabel(g.id)),
              ("%d lots x%d at %s each"):format(lots, lot, fmt(price)),
              "The name on that click becomes the seller",
            })
            if name then
              mkList(name, g.id, lot, price, lots)
            end
            return
          end
        end
      end
    end
  end
end

local function mkMineScreen()
  local name = mkSign({ "to open YOUR wallet and listings" })
  if not name then return end
  local opened = nowMs()
  local sel, ay = 1, H - 2

  local function mine()
    local out = {}
    for _, l in ipairs(bank.market.lots) do
      if l.seller == name then out[#out + 1] = l end
    end
    return out
  end

  local function draw()
    frame("MINE")
    local w = bank.market.wallet[name] or 0
    put(2, 3, name:sub(1, 20), colors.yellow, colors.black)
    rput(50, 3, "WALLET " .. fmt(w), colors.lime, colors.black)
    put(2, 4, "ITEM", colors.lightGray, colors.black)
    rput(34, 4, "LOT", colors.lightGray, colors.black)
    rput(41, 4, "PRICE", colors.lightGray, colors.black)
    rput(48, 4, "LOTS", colors.lightGray, colors.black)
    local list = mine()
    if sel > #list then sel = math.max(1, #list) end
    for i = 1, math.min(#list, 9) do
      local l  = list[i]
      local y  = 4 + i
      local bg = (i == sel) and colors.gray or colors.black
      fill(1, y, W, 1, bg)
      put(2, y, ("#%d %s"):format(l.id, itemLabel(l.item)):sub(1, 28),
          l.hold and colors.red or colors.white, bg)
      rput(34, y, "x" .. l.lot, colors.white, bg)
      rput(41, y, fmt(l.price), colors.yellow, bg)
      rput(48, y, l.hold and "HOLD" or tostring(math.ceil(l.qty / l.lot)), colors.white, bg)
      ghost("row" .. i, 1, y, W, 1)
    end
    if #list == 0 then putC(7, "no listings", colors.gray, colors.black) end
    putC(14, "COLLECT moves your wallet into CREDITS -", colors.lightGray, colors.black)
    putC(15, "CASH OUT from the main menu to take coins.", colors.lightGray, colors.black)
    local l = list[sel]
    button("collect", 2, ay, 16, 1, "COLLECT " .. fmt(w),
           (w >= 1) and colors.green or colors.gray, colors.white, "k")
    button("cancel", 20, ay, 14, 1, l and ("CANCEL #" .. l.id) or "CANCEL",
           l and colors.orange or colors.gray, colors.black, "c")
    button("back", W - 10, ay, 9, 1, "BACK", colors.blue, colors.white, "q")
    footer()
  end

  draw()
  while true do
    if nowMs() - opened > 300000 then
      msg("Signed out - open MINE again", colors.lightGray); return
    end
    local id = waitAction(draw)
    if id == "back" then
      return
    elseif type(id) == "string" and id:match("^row%d$") then
      sel = tonumber(id:sub(4)); sfx("select"); draw()
    elseif id == "collect" then
      local w = bank.market.wallet[name] or 0
      if w < 1 then
        msg("Nothing to collect", colors.orange); sfx("deny"); footer()
      else
        local who = mkSign({ ("to COLLECT %s credits of %s"):format(fmt(w), name),
                             "onto THIS screen - CASH OUT right after" }, name)
        if who == name then mkCollect(name) end
        draw()
      end
    elseif id == "cancel" then
      local l = mine()[sel]
      if not l then
        draw()
      else
        local who = mkSign({ ("to CANCEL #%d and return"):format(l.id),
                             ("%d %s to the TELLER"):format(l.qty, itemLabel(l.item)) }, name)
        if who == name then mkCancel(l, name) end
        draw()
      end
    end
  end
end

local function gameMarket()
  if not detector then
    msg("Market needs a Player Detector - call the owner", colors.red)
    sfx("deny")
    return
  end
  sfx("enter")
  local PER = MK.perPage
  local sel, page, lots = 1, 1, 1
  local ay = H - 2

  local function pages() return math.max(1, math.ceil(#bank.market.lots / PER)) end

  local function clampSel()
    local n = #bank.market.lots
    if page > pages() then page = pages() end
    if sel < 1 then sel = 1 end
    if sel > n then sel = math.max(1, n) end
    local first = (page - 1) * PER + 1
    if sel < first or sel > first + PER - 1 then page = math.ceil(sel / PER) end
  end

  local function cost(l)
    local want = math.min(lots * l.lot, l.qty)
    return math.ceil(l.price * want / l.lot), want
  end

  local function draw()
    clampSel()
    frame(("MARKET %d/%d"):format(page, pages()))
    put(2, 3, "ITEM", colors.lightGray, colors.black)
    put(20, 3, "SELLER", colors.lightGray, colors.black)
    rput(34, 3, "LOT", colors.lightGray, colors.black)
    rput(41, 3, "PRICE", colors.lightGray, colors.black)
    rput(48, 3, "LOTS", colors.lightGray, colors.black)
    local first = (page - 1) * PER + 1
    for row = 0, PER - 1 do
      local idx = first + row
      local l   = bank.market.lots[idx]
      if l then
        local y  = 4 + row
        local bg = (idx == sel) and colors.gray or colors.black
        fill(1, y, W, 1, bg)
        put(2, y, itemLabel(l.item):sub(1, 17), l.hold and colors.red or colors.white, bg)
        put(20, y, l.seller:sub(1, 10), colors.lightGray, bg)
        rput(34, y, "x" .. l.lot, colors.white, bg)
        rput(41, y, fmt(l.price), colors.yellow, bg)
        rput(48, y, l.hold and "HOLD" or tostring(math.ceil(l.qty / l.lot)), colors.white, bg)
        ghost("row" .. idx, 1, y, W, 1)
      end
    end
    fill(1, 13, W, 3, colors.black)
    local l = bank.market.lots[sel]
    if l then
      put(2, 13, ("%s x%d at %s/lot  %d in escrow  by %s")
                 :format(itemLabel(l.item), l.lot, fmt(l.price), l.qty, l.seller):sub(1, W - 2),
          colors.white, colors.black)
      local c = cost(l)
      put(2, 14, "LOTS", colors.white, colors.black)
      button("q-", 7, 14, 3, 1, "-", colors.red, colors.white, "-")
      put(11, 14, string.format("%-3d", lots), colors.yellow, colors.black)
      button("q+", 15, 14, 3, 1, "+", colors.green, colors.white, "=")
      put(20, 14, "PAY " .. fmt(c), colors.yellow, colors.black)
    else
      putC(8, "Nothing for sale - press SELL to list goods", colors.gray, colors.black)
    end
    put(2, 15, ("Fee %d%% on every sale  -  goods land in the TELLER")
               :format(math.floor(MK.fee * 100 + 0.5)):sub(1, W - 2), colors.gray, colors.black)
    rowButtons(ay, 1, {
      { "buy",  "BUY",  colors.green,  colors.white, "b" },
      { "sell", "SELL", colors.cyan,   colors.black, "s" },
      { "mine", "MINE", colors.yellow, colors.black, "m" },
      { "prev", "<",    colors.gray,   colors.white, "," },
      { "next", ">",    colors.gray,   colors.white, "." },
      { "back", "BACK", colors.blue,   colors.white, "q" },
    })
    footer()
  end

  draw()
  while true do
    local id = waitAction(draw)
    if id == "back" then
      return
    elseif type(id) == "string" and id:match("^row%d+$") then
      sel, lots = tonumber(id:sub(4)), 1
      sfx("select"); draw()
    elseif id == "q-" then
      lots = math.max(1, lots - 1); draw()
    elseif id == "q+" then
      local l = bank.market.lots[sel]
      local top = l and math.max(1, math.ceil(l.qty / l.lot)) or 1
      lots = math.min(top, lots + 1); draw()
    elseif id == "prev" then
      page = (page - 2) % pages() + 1
      sel  = (page - 1) * PER + 1
      draw()
    elseif id == "next" then
      page = page % pages() + 1
      sel  = (page - 1) * PER + 1
      draw()
    elseif id == "buy" then
      local l = bank.market.lots[sel]
      if l then mkBuy(l, lots) end
      lots = 1
      draw()
    elseif id == "sell" then
      mkSellScreen()
      draw()
    elseif id == "mine" then
      mkMineScreen()
      draw()
    end
  end
end

--------------------------------------------------------------- service
local function adminWallets()
  local sel, ay = 1, H - 2
  local function names()
    local out = {}
    for n in pairs(bank.market.wallet) do out[#out + 1] = n end
    table.sort(out)
    return out
  end
  local function draw()
    fill(1, 1, W, H, colors.black)
    clearButtons()
    fill(1, 1, W, 1, colors.red)
    put(2, 1, "MARKET WALLETS - credits owed to sellers", colors.white, colors.red)
    local list = names()
    if sel > #list then sel = math.max(1, #list) end
    for i = 1, math.min(#list, 12) do
      local y  = 2 + i
      local bg = (i == sel) and colors.gray or colors.black
      fill(1, y, W, 1, bg)
      put(2, y, list[i]:sub(1, 30), colors.white, bg)
      rput(48, y, fmt(bank.market.wallet[list[i]]), colors.lime, bg)
      ghost("row" .. i, 1, y, W, 1)
    end
    if #list == 0 then putC(6, "nothing owed", colors.gray, colors.black) end
    put(2, 16, "TOTAL OWED " .. fmt(mkOwed()), colors.yellow, colors.black)
    rowButtons(ay, 1, {
      { "pay",  "PAY TO CREDITS", colors.green, colors.white },
      { "zero", "ZERO",           colors.red,   colors.white },
      { "back", "BACK",           colors.blue,  colors.white, "q" },
    })
    footer()
  end
  draw()
  while true do
    local id = waitAction(draw)
    if id == "back" then
      return
    elseif type(id) == "string" and id:match("^row%d+$") then
      sel = tonumber(id:sub(4)); draw()
    elseif id == "pay" or id == "zero" then
      local n = names()[sel]
      if n then
        local w = bank.market.wallet[n] or 0
        bank.market.wallet[n] = nil
        if id == "pay" then bank.credits = bank.credits + w end
        mkAlert(("admin %s wallet of %s (%d)"):format(id == "pay" and "paid out" or "zeroed", n, w))
        save()
        msg(("%s: %s credits"):format(id == "pay" and "Paid to credits" or "Zeroed", fmt(w)),
            colors.orange)
      end
      draw()
    end
  end
end

local function adminAlerts()
  local ay = H - 2
  local function draw()
    fill(1, 1, W, H, colors.black)
    clearButtons()
    fill(1, 1, W, 1, colors.red)
    put(2, 1, "MARKET ALERTS", colors.white, colors.red)
    local a = bank.market.alerts
    local first = math.max(1, #a - 13)
    for i = first, #a do
      put(2, 2 + (i - first + 1), a[i]:sub(1, W - 2), colors.white, colors.black)
    end
    if #a == 0 then putC(6, "no alerts", colors.gray, colors.black) end
    rowButtons(ay, 1, {
      { "clear", "CLEAR", colors.orange, colors.black },
      { "back",  "BACK",  colors.blue,   colors.white, "q" },
    })
    footer()
  end
  draw()
  while true do
    local id = waitAction(draw)
    if id == "back" then return
    elseif id == "clear" then bank.market.alerts = {}; save(); draw() end
  end
end

local function adminMarket()
  local sel, ay = 1, H - 2
  local stock = {}
  local function recheck()
    stock = {}
    for _, l in ipairs(bank.market.lots) do
      if stock[l.item] == nil then stock[l.item] = bankStock(l.item) end
    end
  end
  local function draw()
    fill(1, 1, W, H, colors.black)
    clearButtons()
    fill(1, 1, W, 1, colors.red)
    put(2, 1, "MARKET SERVICE", colors.white, colors.red)
    local escrow = 0
    for _, l in ipairs(bank.market.lots) do escrow = escrow + l.qty end
    put(2, 2, ("Listings %d   Escrow %s items   Owed %s   Alerts %d")
              :format(#bank.market.lots, fmt(escrow), fmt(mkOwed()), #bank.market.alerts)
              :sub(1, W - 2), colors.lightGray, colors.black)
    put(2, 3, "#  SELLER     ITEM", colors.lightGray, colors.black)
    rput(36, 3, "QTY", colors.lightGray, colors.black)
    rput(44, 3, "STOCK", colors.lightGray, colors.black)
    local list = bank.market.lots
    if sel > #list then sel = math.max(1, #list) end
    for i = 1, math.min(#list, 11) do
      local l  = list[i]
      local y  = 3 + i
      local bg = (i == sel) and colors.gray or colors.black
      local st = stock[l.item] or 0
      local short = st < mkEscrow(l.item)
      fill(1, y, W, 1, bg)
      put(2, y, ("%-2d %-10s %s"):format(l.id, l.seller:sub(1, 10), itemLabel(l.item)):sub(1, 30),
          l.hold and colors.red or colors.white, bg)
      rput(36, y, tostring(l.qty), colors.white, bg)
      rput(44, y, tostring(st), short and colors.red or colors.lime, bg)
      if short then put(46, y, "SHORT", colors.red, bg) end
      ghost("row" .. i, 1, y, W, 1)
    end
    if #list == 0 then putC(8, "no listings", colors.gray, colors.black) end
    local l = list[sel]
    rowButtons(ay, 1, {
      { "recheck", "RECHECK", colors.gray,   colors.white },
      { "kill",    l and ("KILL #" .. l.id) or "KILL", l and colors.red or colors.gray, colors.white },
      { "wallets", "WALLETS", colors.gray,   colors.white },
      { "alerts",  "ALERTS",  colors.gray,   colors.white },
      { "back",    "BACK",    colors.blue,   colors.white, "q" },
    })
    footer()
  end
  recheck()
  draw()
  while true do
    local id = waitAction(draw)
    if id == "back" then
      return
    elseif type(id) == "string" and id:match("^row%d+$") then
      sel = tonumber(id:sub(4)); draw()
    elseif id == "recheck" then
      recheck(); msg("Stock rechecked", colors.lime); draw()
    elseif id == "wallets" then
      adminWallets(); draw()
    elseif id == "alerts" then
      adminAlerts(); draw()
    elseif id == "kill" then
      local l = bank.market.lots[sel]
      if l and not busy and not bankOffline then
        mkJournal("cancel", l, l.qty, 0)
        local moved = bankGive(l.item, l.qty)
        mkSettle()
        l.qty = l.qty - moved
        mkAlert(("admin killed #%d of %s: %d %s returned to the TELLER, %d lost")
                :format(l.id, l.seller, moved, itemLabel(l.item), math.max(0, l.qty)))
        mkDrop(l)
        save()
        msg(("Killed #%d - %d returned to the TELLER"):format(l.id, moved), colors.orange)
        recheck()
      elseif l then
        msg(bankOffline and "Bank offline" or "Machine busy - try again", colors.orange)
      end
      draw()
    end
  end
end

--======================== SERVICE MENU ==================================
local GAMEROWS = {
  { "slots",     "SLOTS"      }, { "mega",   "MEGA SLOTS" },
  { "roulette",  "ROULETTE"   }, { "wheel",  "WHEEL"      },
  { "blackjack", "BLACKJACK"  }, { "poker",  "POKER"      },
  { "hilo",      "HI-LO"      }, { "double", "DOUBLE X2"  },
  { "market",    "MARKET"     },
}

-- per-game book: what each mode took in and paid out
local function gameBook()
  local function draw()
    fill(1, 1, W, H, colors.black)
    clearButtons()
    fill(1, 1, W, 1, colors.red)
    put(2, 1, "PER GAME PROFIT / LOSS", colors.white, colors.red)

    put(3, 3, "GAME", colors.lightGray, colors.black)
    rput(22, 3, "ROUNDS", colors.lightGray, colors.black)
    rput(31, 3, "IN", colors.lightGray, colors.black)
    rput(40, 3, "OUT", colors.lightGray, colors.black)
    rput(50, 3, "P/L", colors.lightGray, colors.black)

    local y, tw, tp, tr = 4, 0, 0, 0
    for _, row in ipairs(GAMEROWS) do
      local g  = statFor(row[1])
      local pl = g.w - g.p
      tw, tp, tr = tw + g.w, tp + g.p, tr + g.r
      put(3, y, row[2], colors.white, colors.black)
      rput(22, y, fmt(g.r), colors.lightGray, colors.black)
      rput(31, y, fmt(g.w), colors.lightGray, colors.black)
      rput(40, y, fmt(g.p), colors.lightGray, colors.black)
      rput(50, y, (pl >= 0 and "+" or "-") .. fmt(math.abs(pl)),
           pl >= 0 and colors.lime or colors.red, colors.black)
      y = y + 1
    end

    y = y + 1
    local tpl = tw - tp
    put(3, y, "TOTAL", colors.yellow, colors.black)
    rput(22, y, fmt(tr), colors.yellow, colors.black)
    rput(31, y, fmt(tw), colors.yellow, colors.black)
    rput(40, y, fmt(tp), colors.yellow, colors.black)
    rput(50, y, (tpl >= 0 and "+" or "-") .. fmt(math.abs(tpl)),
         tpl >= 0 and colors.lime or colors.red, colors.black)

    rowButtons(H - 2, 1, {
      { "wipe", "RESET BOOK", colors.gray },
      { "back", "BACK",       colors.blue, colors.white, "q" },
    })
    footer()
  end

  draw()
  while true do
    local id = waitAction(draw)
    if id == "back" then
      return
    elseif id == "wipe" then
      bank.stats.games = {}
      save()
      msg("Per game book cleared", colors.orange)
      draw()
    end
  end
end

-- On-screen keypad. Returns the digits typed, or nil if the user backed out.
local function readPin(title)
  return readDigits(title, 8, true)
end

local function adminMenu()
  local function draw()
    fill(1, 1, W, H, colors.black)
    clearButtons()
    fill(1, 1, W, 1, colors.red)
    put(2, 1, "SERVICE MENU  v" .. VERSION, colors.white, colors.red)
    local s = bank.stats
    local y = 3
    put(3, y, (isRS() and "Bank (RS)    " or "Bank barrel  ") .. fmt(bank.vault) .. (bankOffline and "  OFFLINE" or ""),   colors.lime,   colors.black); y = y + 1
    put(3, y, "Credits      " .. fmt(bank.credits), colors.yellow, colors.black); y = y + 1
    put(3, y, "Jackpot      " .. fmt(bank.jackpot), colors.orange, colors.black); y = y + 1
    put(3, y, "Uncollected  " .. (collect.active and fmt(collect.value) or "-"),
        colors.orange, colors.black); y = y + 1
    put(3, y, "Owed (mkt)   " .. fmt(mkOwed()), colors.orange, colors.black); y = y + 1
    put(3, y, "Wagered      " .. fmt(s.wagered),    colors.white,  colors.black); y = y + 1
    put(3, y, "Paid out     " .. fmt(s.paid),       colors.white,  colors.black); y = y + 1
    put(3, y, "Rounds       " .. fmt(s.rounds),     colors.white,  colors.black); y = y + 1
    local profit = s.wagered - s.paid
    put(3, y, "House P/L    " .. fmt(profit),
        profit >= 0 and colors.lime or colors.red, colors.black)

    rowButtons(H - 6, 1, {
      { "rescan", "RESCAN BANK",   colors.gray },
      { "zero",   "ZERO CREDIT",   colors.gray },
      { "clr",    "CLR COLLECT", colors.gray },
      { "book",   "GAME P/L",      colors.gray },
    })
    rowButtons(H - 4, 1, {
      { "jp-",    "JP -100",  colors.gray },
      { "jp+",    "JP +100",  colors.gray },
      { "jpr",    "JP RESET", colors.gray },
      { "market", "MARKET",   colors.gray },
    })
    rowButtons(H - 2, 1, {
      { "pin",  "CHANGE PIN",  colors.gray },
      { "stat", "RESET STATS", colors.gray },
      { "back", "BACK",        colors.blue },
      { "quit", "EXIT",        colors.red },
    })
    footer()
  end

  draw()
  while true do
    local id = waitAction(draw)
    if id == "back" then
      return
    elseif id == "quit" then
      running = false; return
    elseif id == "book" then
      gameBook()
      draw()
    elseif id == "market" then
      adminMarket()
      draw()
    elseif id == "rescan" then
      bank.vault = vaultScan()
      msg((bankOffline and "Bank OFFLINE - last known " or "Bank holds ")
          .. fmt(bank.vault), bankOffline and colors.red or colors.lime)
      draw()
    elseif id == "zero" then
      bank.credits = 0; save()
      msg("Player credits cleared", colors.orange)
      draw()
    elseif id == "clr" then
      collect.active, collect.value, collect.idle = false, 0, 0
      save()
      msg("Collection window closed", colors.orange)
      draw()
    elseif id == "pin" then
      local a = readPin("SET A NEW PIN")
      if a and #a >= 4 then
        local b = readPin("REPEAT THE NEW PIN")
        if b == a then
          bank.pinSalt = newSalt()
          bank.pinHash = hashPin(a, bank.pinSalt)
          save()
          msg("PIN changed - only its hash is stored", colors.lime)
          sfx("enter")
        else
          msg("The two entries did not match - PIN unchanged", colors.red)
          sfx("deny")
        end
      elseif a then
        msg("PIN must be at least 4 digits - unchanged", colors.orange)
        sfx("deny")
      end
      draw()
    elseif id == "stat" then
      bank.stats = { wagered = 0, paid = 0, rounds = 0 }; save()
      msg("Statistics reset", colors.orange)
      draw()
    elseif id == "jp-" then
      bank.jackpot = math.max(0, bank.jackpot - 100); save(); draw()
    elseif id == "jp+" then
      bank.jackpot = bank.jackpot + 100; save(); draw()
    elseif id == "jpr" then
      bank.jackpot = CFG.jackpotSeed; save(); draw()
    end
  end
end

local function adminGate()
  local entry = readPin("SERVICE - ENTER PIN")
  while entry do
    if checkPin(entry) then
      msg("", colors.white)
      sfx("enter")
      return adminMenu()
    end
    msg("Wrong PIN", colors.red)
    sfx("deny")
    entry = readPin("SERVICE - ENTER PIN")
  end
  msg("", colors.white)
end

--======================== MAIN MENU =====================================
local GAMES = {
  { id = "slots",     fn = gameSlots },
  { id = "mega",      fn = gameMega },
  { id = "roulette",  fn = gameRoulette },
  { id = "wheel",     fn = gameWheel },
  { id = "blackjack", fn = gameBlack },
  { id = "poker",     fn = gamePoker },
  { id = "hilo",      fn = gameHiLo },
  { id = "double",    fn = gameDouble },
  { id = "market",    fn = gameMarket },
}

local function mainMenu()
  local bh  = (H >= 15) and 3 or 1
  local gap = (H >= 15) and 1 or 0
  local r1  = 4
  local r2  = r1 + bh + gap
  local cy  = r2 + bh + gap

  local function draw()
    frame()
    rowButtons(r1, bh, {
      { "slots",     "SLOTS",      colors.red,     colors.white, "1" },
      { "mega",      "MEGA SLOTS", colors.orange,  colors.black, "2" },
      { "roulette",  "ROULETTE",   colors.green,   colors.white, "3" },
      { "wheel",     "WHEEL",      colors.magenta, colors.white, "4" },
    })
    rowButtons(r2, bh, {
      { "blackjack", "BLACKJACK",  colors.blue,    colors.white, "5" },
      { "poker",     "POKER",      colors.purple,  colors.white, "6" },
      { "hilo",      "HI-LO",      colors.cyan,    colors.black, "7" },
      { "double",    "DOUBLE X2",  colors.brown,   colors.white, "8" },
    })
    rowButtons(cy, 1, {
      { "cash",  "CASH OUT", colors.orange, colors.black, "c" },
      { "market", "MARKET", detector and colors.yellow or colors.gray, colors.black, "m" },
      { "admin", "SERVICE",  colors.gray,   colors.white, "a" },
    })
    if msgText == "" then
      msg(bank.credits >= 1
          and "Pick a game, trade in MARKET, or CASH OUT"
          or  IDLE_HINT)
    end
    footer()
  end

  draw()
  while running do
    local id = waitAction(draw)
    if id == "cash" then
      cashOut(); draw()
    elseif id == "admin" or id == "__admin" then
      adminGate()
      if not running then return end
      draw()
    else
      for _, g in ipairs(GAMES) do
        if g.id == id then
          msg("")
          curGame = g.id
          g.fn()
          curGame = "-"
          draw()
          break
        end
      end
    end
  end
end

--======================== BACKGROUND SCANNER ============================
--  no collection window -> every currency item in the TELLER is swept
--  into the BANK and credited (only once the coins are safe); other
--  items are left where they are - they are market goods
--  collection window    -> hands off, the player is taking their payout
local function scanner()
  while running do
    if not busy then
      local tv, goods = tellerScan()
      vaultAge = vaultAge + 1
      if vaultAge >= CFG.vaultEvery then
        bank.vault, vaultAge = vaultScan(), 0
      elseif isRS() then
        local okC, conn = pcall(vaultInv.isConnected)
        bankOffline = (not okC) or conn == false
      end

      if collect.active then
        if tv <= 0 then
          collect.active, collect.value, collect.idle = false, 0, 0
          save()
          msg("Payout collected. Good luck!", colors.lime)
          sfx("collected")
          os.queueEvent("casino_update")
        elseif tv ~= collect.last then
          collect.last  = tv
          collect.value = tv
          collect.idle  = 0
          os.queueEvent("casino_update")
        else
          collect.idle = collect.idle + CFG.pollDelay
          if collect.idle >= CFG.collectTimeout then
            collect.active, collect.idle = false, 0
            msg("Payout timed out - returned to your credits", colors.orange)
            os.queueEvent("casino_update")
          end
        end
      elseif tv > 0 and not bankOffline then
        local moved, full = sweepToVault()
        if moved > 0 then
          bank.credits = bank.credits + moved
          save()
          msg("Accepted " .. fmt(moved) .. " credits", colors.lime)
          sfx("coin")
          os.queueEvent("casino_update")
        end
        if full then
          msg(isRS() and "BANK STORAGE FULL OR OFFLINE - call the owner"
                     or "BANK BARREL IS FULL - call the owner", colors.red)
          sfx("alarm")
          os.queueEvent("casino_update")
        end
      end

      if goods ~= junkSeen then
        junkSeen = goods
        if goods and curGame ~= "market" then
          msg("Goods in TELLER: list in MARKET or take them out", colors.orange)
          os.queueEvent("casino_update")
        end
      end
    end
    sleep(CFG.pollDelay)
  end
end

--======================== BOOT ==========================================
local function initScreen()
  if monitor then
    pcall(monitor.setTextScale, CFG.textScale)
    term.redirect(monitor)
    usingMonitor = true
  else
    usingMonitor = false
  end
  W, H = term.getSize()
  term.setBackgroundColour(colors.black)
  term.setTextColour(colors.white)
  term.clear()
  if W < 51 or H < 19 then
    msg("Needs a 51x19 screen - use text scale 0.5", colors.orange)
  end
end

local function main()
  math.randomseed((os.epoch and os.epoch("utc") or os.time() * 1000) % 2147483647)
  for _ = 1, 5 do math.random() end

  load()

  -- recovery path: physical access to the computer resets the service PIN
  if ARGS[1] == "pin" then
    term.redirect(term.native())
    term.setBackgroundColour(colors.black); term.setTextColour(colors.white)
    term.clear(); term.setCursorPos(1, 1)
    print("Reset the service PIN")
    write("New PIN (4-8 digits): ")
    local a = read("*")
    write("Repeat: ")
    local b = read("*")
    if a ~= b then print("They did not match. Nothing changed."); return end
    if not a:match("^%d%d%d%d%d?%d?%d?%d?$") then
      print("4 to 8 digits, digits only. Nothing changed."); return
    end
    bank.pinSalt = newSalt()
    bank.pinHash = hashPin(a, bank.pinSalt)
    save()
    print("Saved. Only the salted hash is stored.")
    return
  end

  if ARGS[1] == "setup" or not bankReady() then
    setupWizard()
  end
  attach()

  term.redirect(term.native())
  term.clear(); term.setCursorPos(1, 1)
  print("Lucky Barrel Casino " .. VERSION)
  print("TELLER : " .. bank.tellerName)
  print("BANK   : " .. (isRS() and "RS network via " or "") .. bank.vaultName)
  print("Speaker: " .. (speaker and "yes" or "NONE"))
  print("Detector: " .. (detector and (detName or "yes") or "NONE - market off"))

  initScreen()
  bank.vault = vaultScan()
  mkRecover()
  -- a payout left in the teller across a reboot still belongs to the player
  if collect.active then collect.last = (tellerScan()) end
  save()

  if monitor then
    local old = term.current()
    term.redirect(term.native())
    print("UI is on the monitor. Hold Ctrl+T to stop.")
    term.redirect(old)
  end

  sfx("enter")
  parallel.waitForAny(mainMenu, scanner, soundLoop)
end

local ok, err = pcall(main)
running = false
pcall(save)

term.redirect(term.native())
term.setBackgroundColour(colors.black)
term.setTextColour(colors.white)
term.clear()
term.setCursorPos(1, 1)
if monitor then
  pcall(function()
    monitor.setBackgroundColour(colors.black)
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.setTextColour(colors.white)
    monitor.write("CASINO OFFLINE")
  end)
end
if not ok and err ~= "Terminated" then printError(err) end
print("Casino stopped. Credits held: " .. tostring(math.floor(bank.credits)))
