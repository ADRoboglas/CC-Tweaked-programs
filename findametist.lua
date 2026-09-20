-- Configuration
-- REPLACE THESE WITH YOUR ACTUAL PC COORDINATES
local PC_X = 3546
local PC_Y = 85
local PC_Z = -4217

local RADIUS = 8
local TARGET_BLOCK = "minecraft:amethyst_cluster"

-- Find peripherals
local geoScanner = peripheral.find("geoScanner")
local focalPort = peripheral.find("focal_port")

if not geoScanner then
    error("Error: Geo Scanner not found!", 0)
end
if not focalPort then
    error("Error: Focal Port not found!", 0)
end
if not focalPort.writeIota then
    error("Error: writeIota method not found. Check if focus is inserted.", 0)
end

local scanBlocks = geoScanner.scan or geoScanner.scanBlocks
if not scanBlocks then
    error("Error: Scan method not found on Geo Scanner.", 0)
end
while true do
    term.clear()
    term.setCursorPos(1, 1)
    print("=== Amethyst Cluster Scanner ===")
    print(string.format("PC Coords: X:%d | Y:%d | Z:%d", PC_X, PC_Y, PC_Z))
    print("Scanning in radius " .. RADIUS .. "...")
    
    -- Perform scan
    local success, result = pcall(scanBlocks, RADIUS)
    if not success or not result then
        error("Scan failed! (Cooldown active or no energy)", 0)
    end
    
    -- Process results
    local iotaList = {}
    
    for _, block in ipairs(result) do
        if block.name == TARGET_BLOCK then
            -- Calculate absolute coordinates
            local absX = PC_X + block.x+0.5
            local absY = PC_Y + block.y
            local absZ = PC_Z + block.z+0.5
            
            -- Add to list in {{x=0,y=0,z=0}} format
            table.insert(iotaList, {x = absX, y = absY, z = absZ})
        end
    end
        
    if #iotaList == 0 then
        print("No clusters found. Focus was not updated.")
        return
    end
    
    -- Write to Focal Port
    print("Writing to Focal Port...")
    local writeSuccess, writeError = pcall(focalPort.writeIota, iotaList)
    
    if writeSuccess then
        print("SUCCESS! Data written to focus.")
        for i, vec in ipairs(iotaList) do
            print(string.format("  [%d] X:%d Y:%d Z:%d", i, vec.x, vec.y, vec.z))
        end
    else
        print("WRITE ERROR: " .. tostring(writeError))
        print("Make sure a writable focus is in the Focal Port.")
    end
end
