-- ============================================================
--  AMETHYST MAPPER  v1.0.0
--  Advanced Peripherals geo scanner  ->  Hex Casting focus
--  (Ducky Peripherals focal port), for a spell circle farm.
--
--  Limits below are read out of the mod jars, not guessed:
--   * focus  : IotaType.isTooLargeToSerialize -- a list iota
--              costs 1 + <entries>; >= 1024 is silently turned
--              into a GARBAGE iota  ->  1022 vectors maximum
--   * scanner: SphereOperation.SCAN_BLOCKS -- 2000 ms cooldown,
--              radius 8 free, up to 16 if the block is powered
-- ============================================================

local VERSION     = "1.0.0"
local CFG_PATH    = "amethyst.cfg"
local DUMP_PATH   = "amethyst_last.txt"

local IOTA_BUDGET = 1024              -- hard game limit
local MAX_VECS    = IOTA_BUDGET - 2   -- 1022: list size = 1 + n, must stay < 1024
local COOLDOWN    = 2.2               -- scanBlocksCooldown = 2000 ms
local FREE_RADIUS = 8                 -- scanBlocksMaxFreeRadius
local MAX_RADIUS  = 16                -- scanBlocksMaxCostRadius

local PRESETS = {
  ripe = {
    "minecraft:amethyst_cluster",
  },
  buds = {
    "minecraft:amethyst_cluster",
    "minecraft:large_amethyst_bud",
    "minecraft:medium_amethyst_bud",
    "minecraft:small_amethyst_bud",
  },
  budding = {
    "minecraft:budding_amethyst",
  },
  all = {
    "minecraft:amethyst_cluster",
    "minecraft:large_amethyst_bud",
    "minecraft:medium_amethyst_bud",
    "minecraft:small_amethyst_bud",
    "minecraft:budding_amethyst",
  },
}

local DEFAULTS = {
  scanner  = nil,            -- absolute pos of the geo scanner block
  origin   = nil,            -- sort origin, defaults to the scanner
  radius   = 8,
  targets  = PRESETS.ripe,
  center   = true,           -- write block centres (x+0.5) instead of corners
  maxIotas = MAX_VECS,
  sort     = "near",         -- near | far | layer | scan
}

-- ------------------------------------------------------------ output

local colour = term.isColour and term.isColour()

local function paint(c)
  if colour then term.setTextColour(c) end
end

local function say(c, fmt, ...)
  paint(c)
  if select("#", ...) > 0 then
    print(string.format(fmt, ...))
  else
    print(fmt)
  end
  paint(colours.white)
end

local function info(fmt, ...) say(colours.white,     fmt, ...) end
local function good(fmt, ...) say(colours.lime,      fmt, ...) end
local function warn(fmt, ...) say(colours.orange,    fmt, ...) end
local function bad (fmt, ...) say(colours.red,       fmt, ...) end
local function dim (fmt, ...) say(colours.lightGrey, fmt, ...) end

-- ------------------------------------------------------------ config

local function copy(t)
  local r = {}
  for k, v in pairs(t) do
    if type(v) == "table" then r[k] = copy(v) else r[k] = v end
  end
  return r
end

local function loadCfg()
  local cfg = copy(DEFAULTS)
  if fs.exists(CFG_PATH) then
    local h = fs.open(CFG_PATH, "r")
    local raw = h.readAll()
    h.close()
    local t = textutils.unserialize(raw)
    if type(t) == "table" then
      for k, v in pairs(t) do cfg[k] = v end
    else
      warn("amethyst.cfg is broken, using defaults")
    end
  end
  return cfg
end

local function saveCfg(cfg)
  local h = fs.open(CFG_PATH, "w")
  h.write(textutils.serialize(cfg))
  h.close()
end

-- ------------------------------------------------------------ peripherals

local function getScanner()
  local s = peripheral.find("geoScanner")
  if not s then
    error("no geo scanner attached (peripheral type 'geoScanner')", 0)
  end
  return s
end

local function getPort()
  local p = peripheral.find("focal_port")
  if not p then
    error("no focal port attached (peripheral type 'focal_port')", 0)
  end
  return p
end

-- scan() answers either a list, or (nil, reason) when on cooldown /
-- out of power. Retry through the cooldown, give up on anything else.
local function scan(scanner, radius)
  for attempt = 1, 30 do
    local ok, res, err = pcall(scanner.scan, radius)
    if not ok then
      res, err = nil, tostring(res)
    end
    if type(res) == "table" then
      return res
    end
    err = tostring(err or "unknown error"):lower()
    if err:find("cooldown") then
      if attempt == 1 then dim("scanner on cooldown, waiting...") end
      sleep(COOLDOWN)
    elseif err:find("fuel") or err:find("energy") then
      error(string.format(
        "radius %d needs power (free radius is %d, the block takes FE)",
        radius, FREE_RADIUS), 0)
    else
      error("scan failed: " .. err, 0)
    end
  end
  error("scanner stayed on cooldown for a minute", 0)
end

-- ------------------------------------------------------------ locating the scanner

-- The scanner reports positions relative to itself, so its absolute
-- position has to come from somewhere. If a GPS constellation is up we
-- can work it out for free: find this computer inside the scan result
-- and subtract its relative offset from its GPS position.
local function autoLocate(scanner)
  local x, y, z = gps.locate(3)
  if not x then return nil, "no GPS signal" end

  local radii = { 1, 4, 8 }
  for i = 1, #radii do
    local r = radii[i]
    local blocks = scan(scanner, r)
    local hits = {}
    for _, b in ipairs(blocks) do
      if type(b.name) == "string" and b.name:find("^computercraft:computer") then
        hits[#hits + 1] = b
      end
    end
    if #hits == 1 then
      return {
        x = math.floor(x) - hits[1].x,
        y = math.floor(y) - hits[1].y,
        z = math.floor(z) - hits[1].z,
      }
    elseif #hits > 1 then
      return nil, string.format("%d computers within %d blocks, cannot tell them apart", #hits, r)
    end
  end
  return nil, "this computer is not in scanner range (wired modem?)"
end

local function askNumber(prompt)
  while true do
    write(prompt)
    local n = tonumber(read())
    if n then return math.floor(n) end
    bad("not a number")
  end
end

local function setup(cfg)
  info("=== setup ===")
  local scanner = getScanner()

  local pos, err = autoLocate(scanner)
  if pos then
    good("found the scanner automatically: %d %d %d", pos.x, pos.y, pos.z)
    write("use it? [Y/n] ")
    local a = read()
    if a == "" or a:lower():sub(1, 1) == "y" then
      cfg.scanner = pos
    end
  else
    dim("auto-detect: %s", tostring(err))
  end

  if not cfg.scanner then
    info("point F3 at the GEO SCANNER BLOCK and type its coordinates")
    cfg.scanner = {
      x = askNumber("X: "),
      y = askNumber("Y: "),
      z = askNumber("Z: "),
    }
  end

  write(string.format("scan radius [%d, max %d free / %d powered]: ", cfg.radius, FREE_RADIUS, MAX_RADIUS))
  local r = tonumber(read())
  if r then cfg.radius = math.max(1, math.min(MAX_RADIUS, math.floor(r))) end

  write("targets - ripe / buds / budding / all [ripe]: ")
  local t = read():lower()
  if PRESETS[t] then cfg.targets = PRESETS[t] end

  saveCfg(cfg)
  good("saved to %s", CFG_PATH)
  return cfg
end

-- ------------------------------------------------------------ collecting

local function collect(cfg, scanner)
  local want = {}
  for _, n in ipairs(cfg.targets) do want[n] = true end

  local blocks = scan(scanner, cfg.radius)

  local seen, out, byName = {}, {}, {}
  for _, b in ipairs(blocks) do
    if want[b.name] then
      local x = cfg.scanner.x + b.x
      local y = cfg.scanner.y + b.y
      local z = cfg.scanner.z + b.z
      local key = x .. "," .. y .. "," .. z
      if not seen[key] then
        seen[key] = true
        out[#out + 1] = { x = x, y = y, z = z, name = b.name }
        byName[b.name] = (byName[b.name] or 0) + 1
      end
    end
  end
  return out, byName, #blocks
end

local function sortSpots(cfg, spots)
  if cfg.sort == "scan" then return spots end

  local o = cfg.origin or cfg.scanner
  local mode = cfg.sort

  local function d2(p)
    local dx, dy, dz = p.x - o.x, p.y - o.y, p.z - o.z
    return dx * dx + dy * dy + dz * dz
  end

  table.sort(spots, function(a, b)
    if mode == "layer" and a.y ~= b.y then return a.y < b.y end
    local ka, kb = d2(a), d2(b)
    if mode == "far" then ka, kb = -ka, -kb end
    if ka ~= kb then return ka < kb end
    if a.x ~= b.x then return a.x < b.x end
    if a.y ~= b.y then return a.y < b.y end
    return a.z < b.z
  end)
  return spots
end

-- ------------------------------------------------------------ writing

local function toIotas(cfg, spots, from, to)
  local half = cfg.center and 0.5 or 0
  local list = {}
  for i = from, to do
    local s = spots[i]
    list[#list + 1] = { x = s.x + half, y = s.y + half, z = s.z + half }
  end
  return list
end

local function writePage(port, list, slot)
  if slot then
    local ok, err = pcall(port.setCurrentSlot, slot)
    if not ok then return false, "setCurrentSlot: " .. tostring(err) end
  end

  local ok, res = pcall(port.writeIota, list)
  if not ok  then return false, "writeIota: " .. tostring(res) end
  if not res then return false, "the focal port refused the write (no focus? sealed?)" end

  -- the size check happens at serialisation time and fails silently,
  -- so read the type back and make sure it is still a list
  local ok2, kind = pcall(port.getIotaType)
  if ok2 and kind == "hexcasting:garbage" then
    return false, string.format("%d entries turned into GARBAGE - over the %d limit", #list, MAX_VECS)
  end
  return true
end

local function writeSpots(cfg, port, spots)
  local cap = math.min(cfg.maxIotas or MAX_VECS, MAX_VECS)

  local slots = 1
  local okc, n = pcall(port.getSlotCount)
  if okc and type(n) == "number" and n > 0 then slots = n end

  local total   = #spots
  local written = 0
  local pages   = 0

  for slot = 1, slots do
    if written >= total then break end
    local from = written + 1
    local to   = math.min(total, written + cap)
    local list = toIotas(cfg, spots, from, to)

    local done, err = writePage(port, list, slots > 1 and slot or nil)
    if not done then return written, pages, err end

    written = to
    pages   = pages + 1
  end

  if slots > 1 then pcall(port.setCurrentSlot, 1) end
  return written, pages, nil
end

-- ------------------------------------------------------------ reporting

local function dumpFile(cfg, spots)
  local h = fs.open(DUMP_PATH, "w")
  h.writeLine(string.format("# amethyst mapper %s  scanner %d %d %d  radius %d",
    VERSION, cfg.scanner.x, cfg.scanner.y, cfg.scanner.z, cfg.radius))
  for i, s in ipairs(spots) do
    h.writeLine(string.format("%4d  %6d %6d %6d  %s", i, s.x, s.y, s.z, s.name))
  end
  h.close()
end

local function report(cfg, spots, byName, scanned)
  info("scanned %d blocks around %d %d %d (r=%d)",
    scanned, cfg.scanner.x, cfg.scanner.y, cfg.scanner.z, cfg.radius)
  for name, n in pairs(byName) do
    dim("  %-24s %d", (name:gsub("^minecraft:", "")), n)
  end
  info("total targets: %d", #spots)
end

-- ------------------------------------------------------------ commands

local function needScanner(cfg)
  if not cfg.scanner then
    error("scanner position unknown - run:  amethyst setup", 0)
  end
end

local function cmdScan(cfg, writeIt)
  needScanner(cfg)
  local scanner = getScanner()
  local spots, byName, scanned = collect(cfg, scanner)
  sortSpots(cfg, spots)
  report(cfg, spots, byName, scanned)
  dumpFile(cfg, spots)
  dim("full list dumped to %s", DUMP_PATH)

  if not writeIt then return spots end

  local port = getPort()

  local cap = math.min(cfg.maxIotas or MAX_VECS, MAX_VECS)
  local slots = 1
  local okc, n = pcall(port.getSlotCount)
  if okc and type(n) == "number" and n > 0 then slots = n end

  if #spots > cap * slots then
    warn("%d found, only %d fit (%d slot%s x %d) - keeping the %s ones",
      #spots, cap * slots, slots, slots == 1 and "" or "s", cap,
      cfg.sort == "far" and "farthest" or "nearest")
  end
  if #spots > 512 then
    warn("that is a lot of NBT on one item; expect sync lag if it sits in a chest")
  end

  local written, pages, err = writeSpots(cfg, port, spots)
  if err then
    bad("%s", err)
    if written > 0 then warn("%d entries made it in before that", written) end
    return spots
  end
  good("wrote %d position%s%s%s",
    written,
    written == 1 and "" or "s",
    pages > 1 and string.format(" across %d slots", pages) or "",
    cfg.center and " (block centres)" or " (block corners)")
  return spots
end

local function cmdWatch(cfg, seconds)
  needScanner(cfg)
  seconds = seconds or 300
  info("watching, rescan every %d s - hold Ctrl+T to stop", seconds)
  while true do
    local ok, err = pcall(cmdScan, cfg, true)
    if not ok then bad("%s", tostring(err)) end
    sleep(seconds)
  end
end

local function cmdClear()
  local port = getPort()
  local ok, err = writePage(port, {}, nil)
  if ok then good("focus wiped (empty list)") else bad("%s", tostring(err)) end
end

local function cmdShow(cfg)
  info("amethyst mapper %s", VERSION)
  if cfg.scanner then
    info("scanner   %d %d %d", cfg.scanner.x, cfg.scanner.y, cfg.scanner.z)
  else
    warn("scanner   not set - run: amethyst setup")
  end
  info("radius    %d  (free %d, powered %d)", cfg.radius, FREE_RADIUS, MAX_RADIUS)
  info("sort      %s", cfg.sort)
  info("centres   %s", tostring(cfg.center))
  info("cap       %d  (hard limit %d)", math.min(cfg.maxIotas or MAX_VECS, MAX_VECS), MAX_VECS)
  info("targets:")
  for _, n in ipairs(cfg.targets) do dim("  %s", n) end

  local ok, p = pcall(getPort)
  if ok then
    local _, kind = pcall(p.getIotaType)
    local _, sl   = pcall(p.getSlotCount)
    info("focal port: iota=%s slots=%s", tostring(kind), tostring(sl))
  else
    warn("focal port: not attached")
  end
end

local function help()
  info("amethyst mapper %s", VERSION)
  print("  amethyst            scan and write into the focus")
  print("  amethyst scan       scan only, no writing")
  print("  amethyst watch [s]  rescan + rewrite every s seconds")
  print("  amethyst setup      scanner position / radius / targets")
  print("  amethyst show       current settings and port state")
  print("  amethyst clear      write an empty list into the focus")
  dim("max %d positions per focus, radius %d free / %d powered", MAX_VECS, FREE_RADIUS, MAX_RADIUS)
end

-- ------------------------------------------------------------ main

local args = { ... }
local cmd  = (args[1] or "run"):lower()
local cfg  = loadCfg()

local function guard(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then bad("%s", tostring(err)) end
  return ok
end

if cmd == "setup" then
  guard(setup, cfg)
elseif cmd == "scan" then
  guard(cmdScan, cfg, false)
elseif cmd == "watch" then
  guard(cmdWatch, cfg, tonumber(args[2]))
elseif cmd == "show" then
  guard(cmdShow, cfg)
elseif cmd == "clear" then
  guard(cmdClear)
elseif cmd == "help" or cmd == "-h" or cmd == "--help" then
  help()
elseif cmd == "run" then
  if cfg.scanner or guard(setup, cfg) then
    guard(cmdScan, cfg, true)
  end
else
  bad("unknown command: %s", cmd)
  help()
end
