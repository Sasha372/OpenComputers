
------------------------------------------------- Libraries -------------------------------------------------

local component = require("component")
local unicode = require("unicode")
local color = require("color")
local image = require("image")

------------------------------------------------- Constants -------------------------------------------------

local gpu = component.gpu
local buffer = {}

------------------------------------------------- Core methods -------------------------------------------------

--Формула конвертации индекса массива изображения в абсолютные координаты пикселя изображения
function buffer.getCoordinatesByIndex(index)
	local integer, fractional = math.modf(index / (buffer.tripleWidth))
	return math.ceil(fractional * buffer.width), integer + 1
end

--Формула конвертации абсолютных координат пикселя изображения в индекс для массива изображения
function buffer.getIndexByCoordinates(x, y)
	return buffer.tripleWidth * (y - 1) + x * 3 - 2
end

-- Установить ограниченную зону рисования. Все пиксели, не попадающие в эту зону, будут игнорироваться.
function buffer.setDrawLimit(x1, y1, x2, y2)
	buffer.drawLimit.x1, buffer.drawLimit.y1, buffer.drawLimit.x2, buffer.drawLimit.y2 = x1, y1, x2, y2
end

-- Удалить ограничение зоны рисования, по умолчанию она будет от 1х1 до координат размера экрана.
function buffer.resetDrawLimit()
	buffer.drawLimit.x1, buffer.drawLimit.y1, buffer.drawLimit.x2, buffer.drawLimit.y2 = 1, 1, buffer.width, buffer.height
end

-- Cкопировать ограничение зоны рисования в виде отдельного массива
function buffer.getDrawLimit()
	return buffer.drawLimit.x1, buffer.drawLimit.y1, buffer.drawLimit.x2, buffer.drawLimit.y2
end

-- Создание массивов буфера и всех необходимых параметров
function buffer.flush(width, height)
	if not width or not height then
		width, height = gpu.getResolution()
	end

	buffer.currentFrame = {}
	buffer.newFrame = {}
	buffer.width = width
	buffer.height = height
	buffer.tripleWidth = width * 3
	buffer.drawLimit = {}
	buffer.resetDrawLimit()

	for y = 1, buffer.height do
		for x = 1, buffer.width do
			table.insert(buffer.currentFrame, 0x010101)
			table.insert(buffer.currentFrame, 0xFEFEFE)
			table.insert(buffer.currentFrame, " ")

			table.insert(buffer.newFrame, 0x010101)
			table.insert(buffer.newFrame, 0xFEFEFE)
			table.insert(buffer.newFrame, " ")
		end
	end
end

buffer.start = buffer.flush

-- Изменение разрешения экрана и пересоздание массивов буфера
function buffer.setResolution(width, height)
	gpu.setResolution(width, height)
	buffer.flush(width, height)
end

------------------------------------------------- Методы отрисовки -----------------------------------------------------------------

function buffer.rawSet(index, background, foreground, symbol)
	buffer.newFrame[index], buffer.newFrame[index + 1], buffer.newFrame[index + 2] = background, foreground, symbol
end

function buffer.rawGet(index)
	return buffer.newFrame[index], buffer.newFrame[index + 1], buffer.newFrame[index + 2]
end

-- Получить информацию о пикселе из буфера
function buffer.get(x, y)
	local index = buffer.getIndexByCoordinates(x, y)
	if x >= 1 and y >= 1 and x <= buffer.width and y <= buffer.height then
		return buffer.rawGet(index)
	else
		return 0x000000, 0x000000, " "
	end
end

-- Установить пиксель в буфере
function buffer.set(x, y, background, foreground, symbol)
	local index = buffer.getIndexByCoordinates(x, y)
	if x >= buffer.drawLimit.x1 and y >= buffer.drawLimit.y1 and x <= buffer.drawLimit.x2 and y <= buffer.drawLimit.y2 then
		buffer.rawSet(index, background, foreground or 0x0, symbol or " ")
	end
end

--Нарисовать квадрат
function buffer.square(x, y, width, height, background, foreground, symbol, transparency) 
	if transparency then
		if transparency == 0 then
			transparency = nil
		else
			transparency = transparency / 100
		end
	end
	if not foreground then foreground = 0x000000 end
	if not symbol then symbol = " " end

	local index, indexStepForward, indexPlus1 = buffer.getIndexByCoordinates(x, y), (buffer.width - width) * 3
	for j = y, (y + height - 1) do
		for i = x, (x + width - 1) do
			if i >= buffer.drawLimit.x1 and j >= buffer.drawLimit.y1 and i <= buffer.drawLimit.x2 and j <= buffer.drawLimit.y2 then
				indexPlus1 = index + 1
				if transparency then
					buffer.newFrame[index] = color.blend(buffer.newFrame[index], background, transparency)
					buffer.newFrame[indexPlus1] = color.blend(buffer.newFrame[indexPlus1], background, transparency)
				else
					buffer.newFrame[index] = background
					buffer.newFrame[indexPlus1] = foreground
					buffer.newFrame[index + 2] = symbol
				end
			end
			index = index + 3
		end
		index = index + indexStepForward
	end
end
buffer.rectangle = buffer.square

--Очистка экрана, по сути более короткая запись buffer.square
function buffer.clear(color, transparency)
	buffer.square(1, 1, buffer.width, buffer.height, color or 0x262626, 0x000000, " ", transparency)
end

--Скопировать область изображения и вернуть ее в виде массива
function buffer.copy(x, y, width, height)
	local copyArray = { width = width, height = height }

	local index
	for j = y, (y + height - 1) do
		for i = x, (x + width - 1) do
			if i >= 1 and j >= 1 and i <= buffer.width and j <= buffer.height then
				index = buffer.getIndexByCoordinates(i, j)
				table.insert(copyArray, buffer.newFrame[index])
				table.insert(copyArray, buffer.newFrame[index + 1])
				table.insert(copyArray, buffer.newFrame[index + 2])
			else
				table.insert(copyArray, 0x0)
				table.insert(copyArray, 0x0)
				table.insert(copyArray, " ")
			end
		end
	end

	return copyArray
end

--Вставить скопированную ранее область изображения
function buffer.paste(x, y, copyArray)
	local index, arrayIndex
	if not copyArray or #copyArray == 0 then error("Массив области экрана пуст.") end

	for j = y, (y + copyArray.height - 1) do
		for i = x, (x + copyArray.width - 1) do
			if i >= buffer.drawLimit.x1 and j >= buffer.drawLimit.y1 and i <= buffer.drawLimit.x2 and j <= buffer.drawLimit.y2 then
				--Рассчитываем индекс массива основного изображения
				index = buffer.getIndexByCoordinates(i, j)
				--Копипаст формулы, аккуратнее!
				--Рассчитываем индекс массива вставочного изображения
				arrayIndex = (copyArray.width * (j - y) + (i - x + 1)) * 3 - 2
				--Вставляем данные
				buffer.newFrame[index] = copyArray[arrayIndex]
				buffer.newFrame[index + 1] = copyArray[arrayIndex + 1]
				buffer.newFrame[index + 2] = copyArray[arrayIndex + 2]
			end
		end
	end
end

--Нарисовать линию, алгоритм спизжен с вики
function buffer.line(x1, y1, x2, y2, background, foreground, symbol)
	local deltaX = math.abs(x2 - x1)
	local deltaY = math.abs(y2 - y1)
	local signX = (x1 < x2) and 1 or -1
	local signY = (y1 < y2) and 1 or -1

	local errorCyka = deltaX - deltaY
	local errorCyka2

	buffer.set(x2, y2, background, foreground, symbol)

	while(x1 ~= x2 or y1 ~= y2) do
		buffer.set(x1, y1, background, foreground, symbol)

		errorCyka2 = errorCyka * 2

		if (errorCyka2 > -deltaY) then
			errorCyka = errorCyka - deltaY
			x1 = x1 + signX
		end

		if (errorCyka2 < deltaX) then
			errorCyka = errorCyka + deltaX
			y1 = y1 + signY
		end
	end
end

-- Отрисовка текста, подстраивающегося под текущий фон
function buffer.text(x, y, textColor, text, transparency)
	if transparency then
		if transparency == 0 then
			transparency = nil
		else
			transparency = transparency / 100
		end
	end

	local index, sText = buffer.getIndexByCoordinates(x, y), unicode.len(text)
	for i = 1, sText do
		if x >= buffer.drawLimit.x1 and y >= buffer.drawLimit.y1 and x <= buffer.drawLimit.x2 and y <= buffer.drawLimit.y2 then
			buffer.newFrame[index + 1] = not transparency and textColor or color.blend(buffer.newFrame[index], textColor, transparency)
			buffer.newFrame[index + 2] = unicode.sub(text, i, i)
		end
		index = index + 3
		x = x + 1
	end
end

-- Отрисовка изображения
function buffer.image(x, y, picture)
	local xPos, xEnd, bufferIndexStepOnReachOfImageWidth = x, x + picture[1] - 1, (buffer.width - picture[1]) * 3
	local bufferIndex = buffer.getIndexByCoordinates(x, y)
	local imageIndexPlus2, imageIndexPlus3

	for imageIndex = 3, #picture, 4 do
		if xPos >= buffer.drawLimit.x1 and y >= buffer.drawLimit.y1 and xPos <= buffer.drawLimit.x2 and y <= buffer.drawLimit.y2 then
			imageIndexPlus2, imageIndexPlus3 = imageIndex + 2, imageIndex + 3
			
			if picture[imageIndexPlus2] == 0x00 then
				buffer.newFrame[bufferIndex] = picture[imageIndex]
				buffer.newFrame[bufferIndex + 1] = picture[imageIndex + 1]
				buffer.newFrame[bufferIndex + 2] = picture[imageIndexPlus3]
			elseif picture[imageIndexPlus2] > 0x00 and picture[imageIndexPlus2] < 0xFF then
				buffer.newFrame[bufferIndex] = color.blend(buffer.newFrame[bufferIndex], picture[imageIndex], picture[imageIndexPlus2])
				buffer.newFrame[bufferIndex + 1] = picture[imageIndex + 1]
				buffer.newFrame[bufferIndex + 2] = picture[imageIndexPlus3]
			elseif picture[imageIndexPlus2] == 0xFF and picture[imageIndexPlus3] ~= " " then
				buffer.newFrame[bufferIndex + 1] = picture[imageIndex + 1]
				buffer.newFrame[bufferIndex + 2] = picture[imageIndexPlus3]
			end
		end
		
		xPos, bufferIndex = xPos + 1, bufferIndex + 3
		if xPos > xEnd then
			xPos, y, bufferIndex = x, y + 1, bufferIndex + bufferIndexStepOnReachOfImageWidth
		end
	end
end

-- Прамоугольная рамочка
function buffer.frame(x, y, width, height, color)
	local stringUp, stringDown, x2 = "┌" .. string.rep("─", width - 2) .. "┐", "└" .. string.rep("─", width - 2) .. "┘", x + width - 1
	buffer.text(x, y, color, stringUp); y = y + 1
	for i = 1, (height - 2) do
		buffer.text(x, y, color, "│")
		buffer.text(x2, y, color, "│")
		y = y + 1
	end
	buffer.text(x, y, color, stringDown)
end

-- Кнопка фиксированных размеров
function buffer.button(x, y, width, height, background, foreground, text)
	local textLength = unicode.len(text)
	if textLength > width - 2 then text = unicode.sub(text, 1, width - 2) end
	
	local textPosX = math.floor(x + width / 2 - textLength / 2)
	local textPosY = math.floor(y + height / 2)
	buffer.square(x, y, width, height, background, foreground, " ")
	buffer.text(textPosX, textPosY, foreground, text)

	return x, y, (x + width - 1), (y + height - 1)
end

-- Кнопка, подстраивающаяся под длину текста
function buffer.adaptiveButton(x, y, xOffset, yOffset, background, foreground, text)
	local width = xOffset * 2 + unicode.len(text)
	local height = yOffset * 2 + 1

	buffer.square(x, y, width, height, background, 0xFFFFFF, " ")
	buffer.text(x + xOffset, y + yOffset, foreground, text)

	return x, y, (x + width - 1), (y + height - 1)
end

-- Кнопка в виде текста в рамке
function buffer.framedButton(x, y, width, height, backColor, buttonColor, text)
	buffer.square(x, y, width, height, backColor, buttonColor, " ")
	buffer.frame(x, y, width, height, buttonColor)
	
	x = math.floor(x + width / 2 - unicode.len(text) / 2)
	y = math.floor(y + height / 2)

	buffer.text(x, y, buttonColor, text)
end

-- Вертикальный скролл-бар
function buffer.scrollBar(x, y, width, height, countOfAllElements, currentElement, backColor, frontColor)
	local sizeOfScrollBar = math.ceil(height / countOfAllElements)
	local displayBarFrom = math.floor(y + height * ((currentElement - 1) / countOfAllElements))

	buffer.square(x, y, width, height, backColor, 0xFFFFFF, " ")
	buffer.square(x, displayBarFrom, width, sizeOfScrollBar, frontColor, 0xFFFFFF, " ")

	sizeOfScrollBar, displayBarFrom = nil, nil
end

function buffer.horizontalScrollBar(x, y, width, countOfAllElements, currentElement, background, foreground)
	local pipeSize = math.ceil(width / countOfAllElements)
	local displayBarFrom = math.floor(x + width * ((currentElement - 1) / countOfAllElements))

	buffer.text(x, y, background, string.rep("▄", width))
	buffer.text(displayBarFrom, y, foreground, string.rep("▄", pipeSize))
end

-- Отрисовка любого изображения в виде трехмерного массива. Неоптимизированно, зато просто.
function buffer.customImage(x, y, pixels)
	x = x - 1
	y = y - 1

	for i=1, #pixels do
		for j=1, #pixels[1] do
			if pixels[i][j][3] ~= "#" then
				buffer.set(x + j, y + i, pixels[i][j][1], pixels[i][j][2], pixels[i][j][3])
			end
		end
	end

	return (x + 1), (y + 1), (x + #pixels[1]), (y + #pixels)
end

------------------------------------------- Semipixel methods ------------------------------------------------------------------------

function buffer.semiPixelRawSet(index, color, yPercentTwoEqualsZero)
	local upperPixel, lowerPixel, bothPixel, indexPlus1, indexPlus2 = "▀", "▄", " ", index + 1, index + 2
	local background, foreground, symbol = buffer.newFrame[index], buffer.newFrame[indexPlus1], buffer.newFrame[indexPlus2]

	if yPercentTwoEqualsZero then
		if symbol == upperPixel then
			if color == foreground then
				buffer.newFrame[index], buffer.newFrame[indexPlus1], buffer.newFrame[indexPlus2] = color, foreground, bothPixel
			else
				buffer.newFrame[index], buffer.newFrame[indexPlus1], buffer.newFrame[indexPlus2] = color, foreground, symbol
			end
		elseif symbol == bothPixel then
			if color ~= background then
				buffer.newFrame[index], buffer.newFrame[indexPlus1], buffer.newFrame[indexPlus2] = background, color, lowerPixel
			end
		else
			buffer.newFrame[index], buffer.newFrame[indexPlus1], buffer.newFrame[indexPlus2] = background, color, lowerPixel
		end
	else
		if symbol == lowerPixel then
			if color == foreground then
				buffer.newFrame[index], buffer.newFrame[indexPlus1], buffer.newFrame[indexPlus2] = color, foreground, bothPixel
			else
				buffer.newFrame[index], buffer.newFrame[indexPlus1], buffer.newFrame[indexPlus2] = color, foreground, symbol
			end
		elseif symbol == bothPixel then
			if color ~= background then
				buffer.newFrame[index], buffer.newFrame[indexPlus1], buffer.newFrame[indexPlus2] = background, color, upperPixel
			end
		else
			buffer.newFrame[index], buffer.newFrame[indexPlus1], buffer.newFrame[indexPlus2] = background, color, upperPixel
		end
	end
end

function buffer.semiPixelSet(x, y, color)
	local yFixed = math.ceil(y / 2)
	if x >= buffer.drawLimit.x1 and yFixed >= buffer.drawLimit.y1 and x <= buffer.drawLimit.x2 and yFixed <= buffer.drawLimit.y2 then
		buffer.semiPixelRawSet(buffer.getIndexByCoordinates(x, yFixed), color, y % 2 == 0)
	end
end

function buffer.semiPixelSquare(x, y, width, height, color)
	-- for j = y, y + height - 1 do for i = x, x + width - 1 do buffer.semiPixelSet(i, j, color) end end
	local index, indexStepForward, indexStepBackward, jPercentTwoEqualsZero, jFixed = buffer.getIndexByCoordinates(x, math.ceil(y / 2)), (buffer.width - width) * 3, width * 3
	for j = y, y + height - 1 do
		jPercentTwoEqualsZero = j % 2 == 0
		
		for i = x, x + width - 1 do
			jFixed = math.ceil(j / 2)
			-- if x >= buffer.drawLimit.x1 and jFixed >= buffer.drawLimit.y1 and x <= buffer.drawLimit.x2 and jFixed <= buffer.drawLimit.y2 then
				buffer.semiPixelRawSet(index, color, jPercentTwoEqualsZero)
			-- end
			index = index + 3
		end

		if jPercentTwoEqualsZero then
			index = index + indexStepForward
		else
			index = index - indexStepBackward
		end
	end
end

function buffer.semiPixelLine(x1, y1, x2, y2, color)
	local incycleValueFrom, incycleValueTo, outcycleValueFrom, outcycleValueTo, isReversed, incycleValueDelta, outcycleValueDelta = x1, x2, y1, y2, false, math.abs(x2 - x1), math.abs(y2 - y1)
	if incycleValueDelta < outcycleValueDelta then
		incycleValueFrom, incycleValueTo, outcycleValueFrom, outcycleValueTo, isReversed, incycleValueDelta, outcycleValueDelta = y1, y2, x1, x2, true, outcycleValueDelta, incycleValueDelta
	end

	if outcycleValueFrom > outcycleValueTo then
		outcycleValueFrom, outcycleValueTo = swap(outcycleValueFrom, outcycleValueTo)
		incycleValueFrom, incycleValueTo = swap(incycleValueFrom, incycleValueTo)
	end

	local outcycleValue, outcycleValueCounter, outcycleValueTriggerIncrement = outcycleValueFrom, 1, incycleValueDelta / outcycleValueDelta
	local outcycleValueTrigger = outcycleValueTriggerIncrement
	for incycleValue = incycleValueFrom, incycleValueTo, incycleValueFrom < incycleValueTo and 1 or -1 do
		if isReversed then
			buffer.semiPixelSet(outcycleValue, incycleValue, color)
		else
			buffer.semiPixelSet(incycleValue, outcycleValue, color)
		end

		outcycleValueCounter = outcycleValueCounter + 1
		if outcycleValueCounter > outcycleValueTrigger then
			outcycleValue, outcycleValueTrigger = outcycleValue + 1, outcycleValueTrigger + outcycleValueTriggerIncrement
		end
	end
end

function buffer.semiPixelCircle(xCenter, yCenter, radius, color)
	local function insertPoints(x, y)
		buffer.semiPixelSet(xCenter + x, yCenter + y, color)
		buffer.semiPixelSet(xCenter + x, yCenter - y, color)
		buffer.semiPixelSet(xCenter - x, yCenter + y, color)
		buffer.semiPixelSet(xCenter - x, yCenter - y, color)
	end

	local x, y = 0, radius
	local delta = 3 - 2 * radius;
	while (x < y) do
		insertPoints(x, y);
		insertPoints(y, x);
		if (delta < 0) then
			delta = delta + (4 * x + 6)
		else 
			delta = delta + (4 * (x - y) + 10)
			y = y - 1
		end
		x = x + 1
	end

	if x == y then insertPoints(x, y) end
end

----------------------------------------- Bezier curve -----------------------------------------

local function getPointTimedPosition(firstPoint, secondPoint, time)
	return {
		x = firstPoint.x + (secondPoint.x - firstPoint.x) * time,
		y = firstPoint.y + (secondPoint.y - firstPoint.y) * time
	}
end

local function getConnectionPoints(points, time)
	local connectionPoints = {}
	for point = 1, #points - 1 do
		table.insert(connectionPoints, getPointTimedPosition(points[point], points[point + 1], time))
	end
	return connectionPoints
end

local function getMainPointPosition(points, time)
	if #points > 1 then
		return getMainPointPosition(getConnectionPoints(points, time), time)
	else
		return points[1]
	end
end

function buffer.semiPixelBezierCurve(points, color, precision)
	local linePoints = {}
	for time = 0, 1, precision or 0.01 do
		table.insert(linePoints, getMainPointPosition(points, time))
	end
	
	for point = 1, #linePoints - 1 do
		buffer.semiPixelLine(math.floor(linePoints[point].x), math.floor(linePoints[point].y), math.floor(linePoints[point + 1].x), math.floor(linePoints[point + 1].y), color)
	end
end

------------------------------------------- Просчет изменений и отрисовка ------------------------------------------------------------------------

--Функция рассчитывает изменения и применяет их, возвращая то, что было изменено
local function calculateDifference(index)
	local somethingIsChanged = false
	
	--Если цвет фона на новом экране отличается от цвета фона на текущем, то
	if buffer.newFrame[index] ~= buffer.currentFrame[index] then
		--Присваиваем цвету фона на текущем экране значение цвета фона на новом экране
		buffer.currentFrame[index] = buffer.newFrame[index]
		--Говорим системе, что что-то изменилось
		somethingIsChanged = true
	end

	index = index + 1
	
	--Аналогично для цвета текста
	if buffer.newFrame[index] ~= buffer.currentFrame[index] then
		buffer.currentFrame[index] = buffer.newFrame[index]
		somethingIsChanged = true
	end

	index = index + 1

	--И для символа
	if buffer.newFrame[index] ~= buffer.currentFrame[index] then
		buffer.currentFrame[index] = buffer.newFrame[index]
		somethingIsChanged = true
	end

	return somethingIsChanged
end

-- Функция группировки изменений и их отрисовки на экран
function buffer.draw(force)
	local changes, index, indexStepOnEveryLine, indexPlus1, indexPlus2, sameCharArray, x, xCharCheck, indexCharCheck, currentForeground = {}, buffer.getIndexByCoordinates(buffer.drawLimit.x1, buffer.drawLimit.y1), (buffer.width - buffer.drawLimit.x2 + buffer.drawLimit.x1 - 1) * 3

	for y = buffer.drawLimit.y1, buffer.drawLimit.y2 do
		x = buffer.drawLimit.x1
		while x <= buffer.drawLimit.x2 do
			indexPlus1, indexPlus2 = index + 1, index + 2
			if calculateDifference(index) or force then
				sameCharArray = { buffer.currentFrame[indexPlus2] }
				xCharCheck, indexCharCheck = x + 1, index + 3
				while xCharCheck <= buffer.drawLimit.x2 do
					indexCharCheckPlus2 = indexCharCheck + 2
					if	
						buffer.currentFrame[index] == buffer.newFrame[indexCharCheck] and
						(
							buffer.newFrame[indexCharCheckPlus2] == " "
							or
							buffer.currentFrame[indexPlus1] == buffer.newFrame[indexCharCheck + 1]
						)
					then
					 	calculateDifference(indexCharCheck)
					 	table.insert(sameCharArray, buffer.currentFrame[indexCharCheckPlus2])
					else
						break
					end

					indexCharCheck = indexCharCheck + 3
					xCharCheck = xCharCheck + 1
				end

				changes[buffer.currentFrame[index]] = changes[buffer.currentFrame[index]] or {}
				changes[buffer.currentFrame[index]][buffer.currentFrame[indexPlus1]] = changes[buffer.currentFrame[index]][buffer.currentFrame[indexPlus1]] or {}
				
				table.insert(changes[buffer.currentFrame[index]][buffer.currentFrame[indexPlus1]], x)
				table.insert(changes[buffer.currentFrame[index]][buffer.currentFrame[indexPlus1]], y)
				table.insert(changes[buffer.currentFrame[index]][buffer.currentFrame[indexPlus1]], table.concat(sameCharArray))
				
				x, index = x + #sameCharArray - 1, index + #sameCharArray * 3 - 3
			end

			x, index = x + 1, index + 3
		end

		index = index + indexStepOnEveryLine
	end

	currentForeground = nil
	
	for background in pairs(changes) do
		gpu.setBackground(background)
		for foreground in pairs(changes[background]) do
			if currentForeground ~= foreground then gpu.setForeground(foreground); currentForeground = foreground end
			for i = 1, #changes[background][foreground], 3 do
				gpu.set(changes[background][foreground][i], changes[background][foreground][i + 1], changes[background][foreground][i + 2])
			end
		end
	end

	changes = nil
end

------------------------------------------------------------------------------------------------------

buffer.flush()

------------------------------------------------------------------------------------------------------

-- buffer.image(1, 1, image.load("/MineOS/Pictures/Raspberry.pic"))
-- buffer.clear(0x0, 60)

-- local x, y = 2, 2
-- for i = 1, 10 do
-- 	buffer.square(x, y, 6, 3, color.HSBToHEX(i * 36, 100, 100), 0x0, " ")
-- 	x, y = x + 4, y + 2
-- end

-- buffer.semiPixelCircle(22, 22, 10, 0xFFDB40)
-- buffer.semiPixelLine(2, 36, 35, 3, 0xFFFFFF)
-- buffer.semiPixelBezierCurve(
-- 	{
-- 		{ x = 2, y = 63},
-- 		{ x = 63, y = 63},
-- 		{ x = 63, y = 2}
-- 	},
-- 	0x44FF44,
-- 	0.01
-- )
-- buffer.draw()

------------------------------------------------------------------------------------------------------

return buffer













