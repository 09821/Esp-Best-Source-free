-- BestPlot visual module
local BestPlot = {}
do
	local REFRESH_INTERVAL = 3
	local HIGHLIGHT_TAG = "BestPlotESP_Highlight"
	local PLAYER_HIGHLIGHT_TAG = "BestPlotESP_PlayerHighlight"
	local BILLBOARD_TAG = "BestPlotESP_BillboardContainer"
	local PLOTS_NAME = "Plots"
	local LINE_PART_NAME = "BestPlotESP_Line_" .. tostring(player.UserId)
	local DECOR_FILL = Color3.fromRGB(0, 200, 150)
	local DECOR_OUTLINE = Color3.fromRGB(255, 255, 255)
	local NAME_COLOR = Color3.fromRGB(255,255,255)
	local VALUE_COLOR = Color3.fromRGB(255,221,51)
	local TEXT_STROKE = Color3.fromRGB(0,0,0)
	local LINE_THICKNESS = 0.7

	local currentAdorneePart = nil
	local currentLinePart = nil
	local renderConn = nil
	local running = false
	local loopThread = nil

	local trackedBest = nil
	local trackedBestMissingSince = nil
	local MISSING_GRACE = 2.5

	local function parseSuffixNumber(str)
		if not str then return nil end
		if type(str) ~= "string" then str = tostring(str) end
		local s = string.gsub(str, "%s+", ""):lower()
		s = string.gsub(s, ",", "")
		s = string.gsub(s, "%+", "")
		if string.sub(s, 1, 1) == "$" then s = string.sub(s, 2) end
		s = string.gsub(s, "/.*$", "")
		s = string.gsub(s, "[^%w%.]+$", "")
		local numPart, suffix = string.match(s, "^([%d%.]+)([kmgtbq]?)")
		if not numPart then
			numPart = string.match(s, "([%d%.]+)")
			if not numPart then return nil end
			suffix = string.match(s, "[%d%.]+([kmgtbq])") or ""
		end
		local n = tonumber(numPart)
		if not n then return nil end
		local multipliers = { k = 1e3, m = 1e6, b = 1e9, t = 1e12, q = 1e15 }
		local mul = 1
		if suffix and suffix ~= "" then mul = multipliers[suffix] or 1 end
		return n * mul
	end

	local function getGenerationTextFromInstance(inst)
		if not inst then return nil end
		local txt = nil
		if inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox") then txt = inst.Text end
		if (not txt) and inst:IsA("ValueBase") then local v = inst.Value if v ~= nil then txt = tostring(v) end end
		if (not txt) then local ok, genericTxt = pcall(function() return inst.Text end) if ok and genericTxt then txt = genericTxt end end
		if not txt then return nil end
		local cleaned_txt = string.gsub(txt, "%s+", "")
		if string.sub(cleaned_txt, 1, 1) == "$" then return txt end
		return nil
	end

	local function findBasePartForPodium(podium)
		if not podium then return nil end
		local base = findDescendantByNameCI(podium, "Base")
		if base and base:IsA("BasePart") then return base end
		if base then
			for _, d in ipairs(base:GetDescendants()) do if d:IsA("BasePart") then return d end end
		end
		for _, d in ipairs(podium:GetDescendants()) do if d:IsA("BasePart") then return d end end
		return nil
	end

	local function clearESP(keepLine)
		if keepLine == nil then keepLine = true end
		for _, desc in ipairs(playerGui:GetDescendants()) do
			if desc:IsA("Highlight") then
				if desc.Name == HIGHLIGHT_TAG then pcall(function() desc:Destroy() end)
				elseif not keepLine and desc.Name == PLAYER_HIGHLIGHT_TAG then pcall(function() desc:Destroy() end)
				end
			end
			if desc:IsA("ScreenGui") and desc.Name == BILLBOARD_TAG then pcall(function() desc:Destroy() end) end
		end
		for _, desc in ipairs(Workspace:GetDescendants()) do
			if desc:IsA("Highlight") and desc.Name == HIGHLIGHT_TAG then pcall(function() desc:Destroy() end) end
		end
		if not keepLine then
			if renderConn then pcall(function() renderConn:Disconnect() end); renderConn = nil end
			if currentLinePart and currentLinePart.Parent then pcall(function() currentLinePart:Destroy() end) end
			currentLinePart = nil
			currentAdorneePart = nil
		end
	end

	local function createHighlightForTarget(target)
		if not target then return end
		local highlight = Instance.new("Highlight")
		highlight.Name = HIGHLIGHT_TAG
		highlight.Adornee = target
		highlight.FillColor = DECOR_FILL
		highlight.FillTransparency = 0.6
		highlight.OutlineColor = DECOR_OUTLINE
		highlight.OutlineTransparency = 0
		highlight.Parent = playerGui
		return highlight
	end

	local function createPlayerOutline()
		local char = player.Character
		if not char then char = player.CharacterAdded and player.CharacterAdded:Wait() or nil if not char then return end end
		local adornee = char
		for _, d in ipairs(playerGui:GetDescendants()) do
			if d:IsA("Highlight") and d.Name == PLAYER_HIGHLIGHT_TAG then
				d.Adornee = adornee
				return d
			end
		end
		local highlight = Instance.new("Highlight")
		highlight.Name = PLAYER_HIGHLIGHT_TAG
		highlight.Adornee = adornee
		highlight.FillTransparency = 1
		highlight.OutlineTransparency = 0
		highlight.OutlineColor = DECOR_FILL
		highlight.FillColor = DECOR_FILL
		highlight.Parent = playerGui
		return highlight
	end

	local function findPartForDecorations(decorations)
		if not decorations then return nil end
		if decorations:IsA("BasePart") then return decorations end
		if decorations:IsA("Model") then
			if decorations.PrimaryPart and decorations.PrimaryPart:IsA("BasePart") then return decorations.PrimaryPart end
		end
		for _, d in ipairs(decorations:GetDescendants()) do if d:IsA("BasePart") then return d end end
		return nil
	end

	local function createNameValueBillboard(adorneePart, nameText, valueText)
		if not adorneePart or not adorneePart:IsA("BasePart") then return end
		local container = playerGui:FindFirstChild(BILLBOARD_TAG)
		if not container then
			local sg = Instance.new("ScreenGui")
			sg.Name = BILLBOARD_TAG
			sg.ResetOnSpawn = false
			sg.Parent = playerGui
			container = sg
		end
		local bbg = Instance.new("BillboardGui")
		bbg.Name = "BestGenerationBillboard"
		bbg.Adornee = adorneePart
		bbg.Size = UDim2.new(0, 220, 0, 52)
		bbg.AlwaysOnTop = true
		bbg.StudsOffset = Vector3.new(0, adorneePart.Size.Y + 1.6, 0)
		bbg.Parent = container
		local nameLabel = Instance.new("TextLabel", bbg)
		nameLabel.Name = "NameLabel"
		nameLabel.Size = UDim2.new(1, -8, 0, 24)
		nameLabel.Position = UDim2.new(0, 4, 0, 2)
		nameLabel.BackgroundTransparency = 1
		nameLabel.Text = tostring(nameText or "")
		nameLabel.TextColor3 = NAME_COLOR
		nameLabel.TextStrokeColor3 = TEXT_STROKE
		nameLabel.TextStrokeTransparency = 0
		nameLabel.Font = Enum.Font.GothamBold
		nameLabel.TextScaled = true
		local valLabel = Instance.new("TextLabel", bbg)
		valLabel.Name = "GenLabel"
		valLabel.Size = UDim2.new(1, -8, 0, 24)
		valLabel.Position = UDim2.new(0, 4, 0, 26)
		valLabel.BackgroundTransparency = 1
		valLabel.Text = tostring(valueText or "")
		valLabel.TextColor3 = VALUE_COLOR
		valLabel.TextStrokeColor3 = TEXT_STROKE
		valLabel.TextStrokeTransparency = 0
		valLabel.Font = Enum.Font.GothamBold
		valLabel.TextScaled = true
		return bbg
	end

	local function isPodiumIndex(name)
		if not name then return false end
		local n = tonumber(name)
		return n and n >= 1 and n <= 50 and math.floor(n) == n
	end

	local function highlightBestPodiumDecorations(podium, decorationsOverride)
		if not podium then return nil end
		local decorations = decorationsOverride
		if not decorations then
			local base = findDescendantByNameCI(podium, "Base") or podium:FindFirstChild("Base")
			if base then decorations = base:FindFirstChild("Decorations") or findDescendantByNameCI(base, "Decorations") end
			if not decorations then decorations = podium:FindFirstChild("Decorations") or findDescendantByNameCI(podium, "Decorations") end
		end
		if decorations then
			if decorations:IsA("Model") or decorations:IsA("BasePart") then createHighlightForTarget(decorations); return decorations end
			for _, decoChild in ipairs(decorations:GetChildren()) do
				if decoChild:IsA("BasePart") or decoChild:IsA("Model") then createHighlightForTarget(decoChild); return decoChild end
				for _, d in ipairs(decoChild:GetDescendants()) do
					if d:IsA("BasePart") or d:IsA("Model") then createHighlightForTarget(d); return d end
				end
			end
		end
		return nil
	end

	local function findGenerationInDecorations(decorations)
		if not decorations then return nil end
		local bestNum, bestText, bestGenInst = nil, nil, nil
		local function checkInst(inst)
			local genText = getGenerationTextFromInstance(inst)
			if genText then
				local numeric = parseSuffixNumber(genText)
				if numeric then
					if (not bestNum) or numeric > bestNum then bestNum = numeric; bestText = genText; bestGenInst = inst end
				end
			end
		end
		checkInst(decorations)
		for _, desc in ipairs(decorations:GetDescendants()) do
			if string.find(string.lower(desc.Name), "generation") then checkInst(desc)
			else
				if desc:IsA("TextLabel") or desc:IsA("TextButton") or desc:IsA("TextBox") or desc:IsA("StringValue") or desc:IsA("ValueBase") then
					checkInst(desc)
				end
			end
		end
		if bestNum then return bestNum, bestText, bestGenInst end
		return nil
	end

	local function findGlobalBest()
		local plotsFolder = Workspace:FindFirstChild(PLOTS_NAME)
		if not plotsFolder then
			for _, c in ipairs(Workspace:GetChildren()) do
				if string.lower(c.Name) == string.lower(PLOTS_NAME) then plotsFolder = c; break end
			end
		end
		if not plotsFolder then return nil end
		local best = nil
		for _, plot in ipairs(plotsFolder:GetChildren()) do
			local animalPodiums = plot:FindFirstChild("AnimalPodiums") or findDescendantByNameCI(plot, "AnimalPodiums")
			if animalPodiums then
				for _, podium in ipairs(animalPodiums:GetChildren()) do
					if isPodiumIndex(podium.Name) then
						local base = findDescendantByNameCI(podium, "Base") or podium:FindFirstChild("Base")
						local decorations = nil
						if base then decorations = base:FindFirstChild("Decorations") or findDescendantByNameCI(base, "Decorations") end
						if not decorations then decorations = podium:FindFirstChild("Decorations") or findDescendantByNameCI(podium, "Decorations") end
						local numeric, rawText = nil, nil
						if decorations then local n, t = findGenerationInDecorations(decorations) if n then numeric = n rawText = t end end
						if not numeric then
							local genInst = podium:FindFirstChild("Generation") or findDescendantByNameCI(podium, "Generation")
							if not genInst then
								local overhead = podium:FindFirstChild("AnimalOverhead") or findDescendantByNameCI(podium, "AnimalOverhead")
								if overhead then genInst = overhead:FindFirstChild("Generation") or findDescendantByNameCI(overhead, "Generation") end
							end
							if not genInst then
								for _, desc in ipairs(podium:GetDescendants()) do
									if desc:IsA("TextLabel") or desc:IsA("TextButton") or desc:IsA("TextBox") or desc:IsA("StringValue") or desc:IsA("ValueBase") then
										if getGenerationTextFromInstance(desc) then genInst = desc; break end
									end
								end
							end
							if genInst then
								local genText = getGenerationTextFromInstance(genInst)
								if genText then numeric = parseSuffixNumber(genText); rawText = genText end
							end
						end
						if numeric then
							local basePart = findBasePartForPodium(podium)
							if (not best) or numeric > best.value then
								best = { value = numeric, rawText = rawText, podium = podium, plot = plot, basePart = basePart, decorations = decorations }
							end
						end
					end
				end
			end
		end
		return best
	end

	local function getDisplayFromInstance(inst)
		if not inst then return nil end
		if inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox") then return inst.Text end
		if inst:IsA("ValueBase") then return tostring(inst.Value) end
		local ok, v = pcall(function() return inst.Value or inst.Text end)
		if ok and v then return tostring(v) end
		return nil
	end

	local function getDisplayName_abmsm_style(decorationsContainer, decorationTarget)
		local function tryNamesInRoot(root, names)
			if not root then return nil end
			for _, nm in ipairs(names) do
				local found = findDescendantByNameCI(root, nm)
				if found then
					local v = getDisplayFromInstance(found)
					if v and v ~= "" then return v end
				end
			end
			return nil
		end

		local preferNames = { "DisplayName", "Displayname", "displayname" }
		local fallbackNames = { "Display", "Name" }

		if decorationsContainer then
			local v = tryNamesInRoot(decorationsContainer, preferNames)
			if v and v ~= "" then return v end
			v = tryNamesInRoot(decorationsContainer, fallbackNames)
			if v and v ~= "" then return v end
		end

		if decorationTarget then
			local v = tryNamesInRoot(decorationTarget, preferNames)
			if v and v ~= "" then return v end
			v = tryNamesInRoot(decorationTarget, fallbackNames)
			if v and v ~= "" then return v end
		end

		if decorationTarget and decorationTarget.Parent then
			local p = decorationTarget.Parent
			local v = tryNamesInRoot(p, preferNames)
			if v and v ~= "" then return v end
			v = tryNamesInRoot(p, fallbackNames)
			if v and v ~= "" then return v end
			if p.Parent then
				local gp = p.Parent
				v = tryNamesInRoot(gp, preferNames)
				if v and v ~= "" then return v end
				v = tryNamesInRoot(gp, fallbackNames)
				if v and v ~= "" then return v end
			end
		end

		if decorationsContainer then
			for _, desc in ipairs(decorationsContainer:GetDescendants()) do
				if desc:IsA("TextLabel") or desc:IsA("TextButton") or desc:IsA("TextBox") or desc:IsA("StringValue") or desc:IsA("ValueBase") then
					local txt = getDisplayFromInstance(desc)
					if txt and txt ~= "" then
						local low = string.lower(txt)
						if not string.find(low, "%$") and not string.find(low, "/s") and not string.find(low, "per") then
							return txt
						end
					end
				end
			end
		end

		if decorationTarget and decorationTarget.Name and decorationTarget.Name ~= "" then return decorationTarget.Name end
		if decorationsContainer and decorationsContainer.Name and decorationsContainer.Name ~= "" then return decorationsContainer.Name end

		return nil
	end

	local function createLinePart()
		local old = Workspace:FindFirstChild(LINE_PART_NAME)
		if old and old:IsA("BasePart") then old:Destroy() end
		local line = Instance.new("Part")
		line.Name = LINE_PART_NAME
		line.Anchored = true
		line.CanCollide = false
		line.CastShadow = false
		line.Size = Vector3.new(LINE_THICKNESS, LINE_THICKNESS, 1)
		line.Material = Enum.Material.Neon
		line.Color = DECOR_FILL
		line.Transparency = 0
		line.Parent = Workspace
		line.Locked = true
		return line
	end

	local function updateLinePartPerFrame()
		if not currentLinePart or not currentAdorneePart then return end
		local char = player.Character
		if not char then return end
		local playerPart = char.PrimaryPart or char:FindFirstChild("HumanoidRootPart") or char:FindFirstChildWhichIsA("BasePart")
		if not playerPart then return end
		local pPos = playerPart.Position
		local tPos = currentAdorneePart.Position
		local dir = tPos - pPos
		local dist = dir.Magnitude
		if dist <= 0.01 then currentLinePart.Transparency = 1; return else currentLinePart.Transparency = 0 end
		local midpoint = (pPos + tPos) / 2
		currentLinePart.Size = Vector3.new(LINE_THICKNESS, LINE_THICKNESS, dist)
		currentLinePart.CFrame = CFrame.new(midpoint, tPos)
		local highlight = playerGui:FindFirstChild(HIGHLIGHT_TAG)
		if highlight and highlight:IsA("Highlight") then currentLinePart.Color = highlight.FillColor or DECOR_FILL else currentLinePart.Color = DECOR_FILL end
	end

	local function isTrackedBestValid()
		if not trackedBest then return false end
		if trackedBest.podium and trackedBest.podium.Parent then
			local decorations = trackedBest.decorations or trackedBest.podium:FindFirstChild("Decorations") or findDescendantByNameCI(trackedBest.podium, "Decorations")
			local numeric = nil
			if decorations then
				local n, t = findGenerationInDecorations(decorations)
				if n then numeric = n end
			end
			if not numeric then
				local genInst = trackedBest.podium:FindFirstChild("Generation") or findDescendantByNameCI(trackedBest.podium, "Generation")
				if genInst then
					local genText = getGenerationTextFromInstance(genInst)
					if genText then numeric = parseSuffixNumber(genText) end
				end
			end
			if numeric and numeric > 0 then
				if numeric >= trackedBest.value then
					trackedBest.value = numeric
					trackedBestMissingSince = nil
					return true
				end
			else
				if not trackedBestMissingSince then
					trackedBestMissingSince = tick()
					return true
				else
					if tick() - trackedBestMissingSince < MISSING_GRACE then
						return true
					else
						trackedBestMissingSince = nil
						return false
					end
				end
			end
		end
		return false
	end

	local function updateESP()
		local didChange = false
		if trackedBest then
			if not isTrackedBestValid() then
				trackedBest = findGlobalBest()
				trackedBestMissingSince = nil
				didChange = true
			else
				local plotsFolder = Workspace:FindFirstChild(PLOTS_NAME)
				if not plotsFolder then
					for _, c in ipairs(Workspace:GetChildren()) do
						if string.lower(c.Name) == string.lower(PLOTS_NAME) then plotsFolder = c; break end
					end
				end
				if plotsFolder then
					local potentialHigher = nil
					for _, plot in ipairs(plotsFolder:GetChildren()) do
						if plot ~= trackedBest.plot then
							local animalPodiums = plot:FindFirstChild("AnimalPodiums") or findDescendantByNameCI(plot, "AnimalPodiums")
							if animalPodiums then
								for _, podium in ipairs(animalPodiums:GetChildren()) do
									if isPodiumIndex(podium.Name) then
										local base = findDescendantByNameCI(podium, "Base") or podium:FindFirstChild("Base")
										local decorations = nil
										if base then decorations = base:FindFirstChild("Decorations") or findDescendantByNameCI(base, "Decorations") end
										if not decorations then decorations = podium:FindFirstChild("Decorations") or findDescendantByNameCI(podium, "Decorations") end
										local numeric, rawText = nil, nil
										if decorations then local n, t = findGenerationInDecorations(decorations) if n then numeric = n rawText = t end end
										if not numeric then
											local genInst = podium:FindFirstChild("Generation") or findDescendantByNameCI(podium, "Generation")
											if not genInst then
												local overhead = podium:FindFirstChild("AnimalOverhead") or findDescendantByNameCI(podium, "AnimalOverhead")
												if overhead then genInst = overhead:FindFirstChild("Generation") or findDescendantByNameCI(overhead, "Generation") end
											end
											if genInst then
												local genText = getGenerationTextFromInstance(genInst)
												if genText then numeric = parseSuffixNumber(genText); rawText = genText end
											end
										end
										if numeric and numeric > (trackedBest.value or 0) then
											potentialHigher = { value = numeric, rawText = rawText, podium = podium, plot = plot, basePart = findBasePartForPodium(podium), decorations = decorations }
											break
										end
									end
								end
							end
							if potentialHigher then break end
						end
					end
					if potentialHigher then
						trackedBest = potentialHigher
						trackedBestMissingSince = nil
						didChange = true
					end
				end
			end
		else
			trackedBest = findGlobalBest()
			trackedBestMissingSince = nil
			didChange = true
		end

		if trackedBest and trackedBest.basePart then
			local highlightExists = nil
			for _, desc in ipairs(playerGui:GetDescendants()) do
				if desc:IsA("Highlight") and desc.Name == HIGHLIGHT_TAG then highlightExists = desc; break end
			end
			if didChange or not highlightExists then
				clearESP(true)
				highlightBestPodiumDecorations(trackedBest.podium, trackedBest.decorations)
				local adorneePart = trackedBest.basePart or findBasePartForPodium(trackedBest.podium)
				if not adorneePart and trackedBest.decorations then adorneePart = findPartForDecorations(trackedBest.decorations) end
				if adorneePart then
					createNameValueBillboard(adorneePart, getDisplayName_abmsm_style(trackedBest.decorations, trackedBest.decorations) or trackedBest.podium.Name or "", trackedBest.rawText or "")
					if not currentLinePart then currentLinePart = createLinePart() end
					currentAdorneePart = adorneePart
					if not renderConn then
						renderConn = RunService.Heartbeat:Connect(function() pcall(updateLinePartPerFrame) end)
					end
				else
					if renderConn then pcall(function() renderConn:Disconnect() end); renderConn = nil end
					if currentLinePart and currentLinePart.Parent then pcall(function() currentLinePart:Destroy() end) end
					currentLinePart = nil
					currentAdorneePart = nil
				end
			end
		else
			clearESP(false)
			trackedBest = nil
			trackedBestMissingSince = nil
		end
	end

	function BestPlot.start()
		if running then return end
		running = true
		pcall(createPlayerOutline)
		loopThread = coroutine.create(function()
			while running do
				local ok, err = pcall(updateESP)
				if not ok then warn("BestPlotESP - error in updateESP: ", err) end
				local waited = 0
				while waited < REFRESH_INTERVAL and running do
					task.wait(0.25)
					waited = waited + 0.25
				end
			end
		end)
		coroutine.resume(loopThread)
	end

	function BestPlot.stop()
		if not running then return end
		running = false
		if renderConn then pcall(function() renderConn:Disconnect() end); renderConn = nil end
		if currentLinePart and currentLinePart.Parent then pcall(function() currentLinePart:Destroy() end) end
		currentLinePart = nil
		currentAdorneePart = nil
		trackedBest = nil
		trackedBestMissingSince = nil
		clearESP(false)
	end

	function BestPlot.toggle()
		if BestPlot.isRunning() then BestPlot.stop() else BestPlot.start() end
	end

	function BestPlot.isRunning()
		return running
	end
end

-- Plot time billboard and utilities
local timeEspMap = {}
local TB_BILLBOARD_SIZE = UDim2.new(0, 120, 0, 36)
local TB_LABEL_FONT = Enum.Font.Arcade
local TB_LABEL_COLOR = Color3.fromRGB(0, 255, 0)
local TB_CENTER_HEIGHT = 3.5

local function formatSecondsToS(origText)
	if not origText or origText == "" then return "" end
	local mm, ss = origText:match("(%d+):(%d+)%s*$")
	if mm and ss then
		local s = tonumber(ss) or 0
		return tostring(s) .. "S"
	end
	local num = origText:match("(%d+)%s*[sS]?$") or origText:match("(%d+)")
	if num then
		local n = tonumber(num) or 0
		return tostring(n) .. "S"
	end
	return ""
end

local function getPlotCenter(plot)
	local sum = Vector3.new(0,0,0)
	local count = 0
	for _, part in ipairs(plot:GetDescendants()) do
		if part:IsA("BasePart") then
			sum = sum + part.Position
			count = count + 1
		end
	end
	if count == 0 then return nil end
	return sum / count
end

local function getBestAdorneeForPlot(plot)
	local center = getPlotCenter(plot)
	if not center then
		local bp = plot.PrimaryPart or plot:FindFirstChildWhichIsA("BasePart")
		return bp, (bp and bp.Position) or nil
	end
	local bestPart = nil
	local bestDist = math.huge
	for _, part in ipairs(plot:GetDescendants()) do
		if part:IsA("BasePart") then
			local d = (part.Position - center).Magnitude
			if d < bestDist then
				bestDist = d
				bestPart = part
			end
		end
	end
	return bestPart, center
end

local function findRemainingTimeLabels(plot)
	local labels = {}
	for _, obj in ipairs(plot:GetDescendants()) do
		if obj:IsA("TextLabel") and obj.Name == "RemainingTime" and obj.Text and obj.Text ~= "" then
			table.insert(labels, obj)
		end
	end
	return labels
end

local function pickBestTimeText(plot)
	local labels = findRemainingTimeLabels(plot)
	local bestVal = nil
	local bestText = nil
	for _, lbl in ipairs(labels) do
		local txt = lbl.Text
		local mm, ss = txt:match("(%d+):(%d+)%s*$")
		local val = nil
		if ss then
			val = tonumber(ss)
		else
			local n = txt:match("(%d+)%s*[sS]?$") or txt:match("(%d+)")
			if n then val = tonumber(n) end
		end
		if val then
			if val >= 0 and (bestVal == nil or val < bestVal) then
				bestVal = val
				bestText = tostring(val) .. "S"
			end
		else
			if not bestText then
				local formatted = formatSecondsToS(txt)
				if formatted ~= "" then bestText = formatted end
			end
		end
	end
	return bestText
end

local function ensureGuiForPlot(plot)
	if not plot or not plot.Parent then return end
	local entry = timeEspMap[plot]
	local adornee, center = getBestAdorneeForPlot(plot)
	if not adornee then return end

	if not entry or not entry.gui or not entry.gui.Parent then
		local bb = Instance.new("BillboardGui")
		bb.Name = "PoisonTimeCenter"
		bb.Size = TB_BILLBOARD_SIZE
		bb.Adornee = adornee
		bb.AlwaysOnTop = true
		bb.MaxDistance = 99999
		bb.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		bb.StudsOffset = Vector3.new(0, TB_CENTER_HEIGHT, 0)
		bb.Parent = plot

		local label = Instance.new("TextLabel", bb)
		label.Name = "PoisonTimeLabel"
		label.BackgroundTransparency = 1
		label.Size = UDim2.new(1, 0, 1, 0)
		label.Position = UDim2.new(0, 0, 0, 0)
		label.Font = TB_LABEL_FONT
		label.TextSize = 24
		label.TextColor3 = TB_LABEL_COLOR
		label.TextStrokeTransparency = 0.6
		label.TextScaled = true
		label.TextXAlignment = Enum.TextXAlignment.Center
		label.TextYAlignment = Enum.TextYAlignment.Center

		timeEspMap[plot] = { gui = bb, label = label, adornee = adornee }
	else
		if entry.adornee ~= adornee then
			entry.gui.Adornee = adornee
			entry.adornee = adornee
		end
	end
end

local function updateAllPlotsOnce()
	local plotsFolder = Workspace:FindFirstChild("Plots")
	if not plotsFolder then return end
	for _, plot in ipairs(plotsFolder:GetChildren()) do
		if plot:IsA("Model") then
			ensureGuiForPlot(plot)
			local best = pickBestTimeText(plot)
			local entry = timeEspMap[plot]
			if entry and entry.label then
				entry.label.Text = best or ""
			end
		end
	end
end
