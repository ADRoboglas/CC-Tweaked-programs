-- Поиск аметистов через Geo Scanner (Advanced Peripherals)

local RADIUS = 8 -- Радиус сканирования (обычно от 1 до 8 или до 16 в зависимости от конфига)
local SEARCH_PATTERN = "amethyst" -- Поисковый запрос (ищет все блоки, содержащие "amethyst")

-- Подключение периферийного устройства
local geoScanner = peripheral.find("geoScanner")
if not geoScanner then
    error("Ошибка: Geo Scanner не обнаружен! Проверьте подключение.", 0)
end

-- Совместимость с разными версиями Advanced Peripherals
local scanBlocks = geoScanner.scan or geoScanner.scanBlocks
if not scanBlocks then
    error("Ошибка: Не найден метод сканирования у Geo Scanner.", 0)
end

term.clear()
term.setCursorPos(1, 1)
print("=== Сканер Аметиста ===")
print("Сканирование в радиусе " .. RADIUS .. " блоков...")

-- Выполнение сканирования
local success, result = pcall(scanBlocks, RADIUS)
if not success or not result then
    print("\nОшибка сканирования!")
    print("Возможные причины: сканер на перезарядке или недостаточно энергии/топлива.")
    return
end

-- Фильтрация найденных блоков
local found = {}
for _, block in ipairs(result) do
    if block.name and string.find(block.name:lower(), SEARCH_PATTERN) then
        table.insert(found, block)
    end
end

-- Сортировка по расстоянию до центра (от ближайшего к дальнему)
table.sort(found, function(a, b)
    local distA = a.x*a.x + a.y*a.y + a.z*a.z
    local distB = b.x*b.x + b.y*b.y + b.z*b.z
    return distA < distB
end)

-- Вывод результатов
print("\nНайдено аметистовых блоков: " .. #found)
print("-----------------------------------")

if #found == 0 then
    print("В указанном радиусе аметистов не найдено.")
else
    for i, b in ipairs(found) do
        -- Координаты относительно компьютера (X: право/лево, Y: верх/низ, Z: вперед/назад)
        print(string.format("[%d] %s", i, b.name))
        print(string.format("    Относительные координаты: X:%+d | Y:%+d | Z:%+d", b.x, b.y, b.z))
    end
end