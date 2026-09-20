local detector = peripheral.find("playerDetector")
local modem = peripheral.find("modem")

if not detector then
    printError("Ошибка: Детектор игроков не найден!")
    return
end

if not modem or not modem.isWireless() then
    printError("Ошибка: Беспроводной (или эндер) модем не найден!")
    return
end

local PORT = 9999
modem.open(PORT)
print("Сервер радара запущен.")
print("Трансляция данных на порт: " .. PORT)

while true do
    local players = detector.getOnlinePlayers()
    local dataList = {}

    for _, name in pairs(players) do
        -- Получаем данные игрока. Детектор возвращает x, y, z и dimension
        local pos = detector.getPlayerPos(name)
        if pos then
            -- Безопасное получение измерения (если его нет, пишем "unknown")
            local rawDim = pos.dimension or "unknown"
            local dim = string.gsub(rawDim, "minecraft:", "")
            
            table.insert(dataList, {
                name = name,
                x = math.floor(pos.x or 0),
                y = math.floor(pos.y or 0),
                z = math.floor(pos.z or 0),
                dim = dim
            })
        end
    end

    -- Отправляем собранную таблицу всем слушателям на 9999 порту
    modem.transmit(PORT, PORT, dataList)
    
    -- Обновляем данные раз в секунду
    sleep(1) 
end