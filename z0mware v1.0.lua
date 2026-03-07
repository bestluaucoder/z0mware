--[[
    ╔══════════════════════════════════════════════════════════╗
    ║               z0mware  —  Blade Ball  v1.0               ║
    ╠══════════════════════════════════════════════════════════╣
    ║  Fixes over original NoEnemies Hub v7.2:                 ║
    ║   • Double-parry fix: hasParried flag, resets only on    ║
    ║     real target change — no more phantom 2nd parry       ║
    ║   • currentBall forward-declared BEFORE StartAntiCurve   ║
    ║     (silent nil-upvalue crash on many executors fixed)   ║
    ║   • local Main forward-declared before ToggleBtn so      ║
    ║     click handler can reference it without nil error     ║
    ║   • AntiCurve block runs AFTER parry logic in loop       ║
    ║   • Tuned threshold: base 0.155, one-way ping /2000      ║
    ║   • PARRY_LOCKOUT 0.15 → 0.06 (only for TB suppression) ║
    ║   • New z0mware UI: electric-blue accent, cleaner look   ║
    ║   • Floating ⚡ menu button (drag or tap) for PC+mobile  ║
    ║   • Mobile floating TB toggle button (bottom-left)       ║
    ║     Always visible, draggable, toggles triggerbot        ║
    ║   • All __NEH_ globals renamed to __Z0M_                 ║
    ╚══════════════════════════════════════════════════════════╝
--]]

-- ════════════════════════════════════ Services ══
local Players             = game:GetService("Players")
local RunService          = game:GetService("RunService")
local TweenService        = game:GetService("TweenService")
local UserInputService    = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local HttpService         = game:GetService("HttpService")
local Camera              = workspace.CurrentCamera

local LP         = Players.LocalPlayer
local BallFolder = workspace:WaitForChild("Balls", 15)

-- ══════════════════════════════════ Mobile detect ══
local isMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

-- Kill old instances
do
    local function kill(n)
        local ok,cg = pcall(function() return game:GetService("CoreGui") end)
        for _,p in ipairs({ok and cg or nil, LP:WaitForChild("PlayerGui")}) do
            if p then local e=p:FindFirstChild(n); if e then e:Destroy() end end
        end
    end
    for _,v in ipairs({
        "z0mware_v1",
        "NoEnemiesHub_v72","NoEnemiesHub_v71","NoEnemiesHub_v70",
        "NoEnemiesHub_v62","NoEnemiesHub_v61","NoEnemiesHub_v60","NoEnemiesHub_v53"
    }) do kill(v) end
end

-- ════════════════════════════════════ Settings ══
local S = {
    AutoParry      = true,
    AutoTiming     = true,
    ClashMode      = false,
    TriggerTime    = 0.225,
    ClashDist      = 9.5,
    MaxFires       = 2,
    CurveDetection = true,
    AutoCurve      = false,
    AntiCurve      = true,
    ACSnapDur      = 0.18,
    AntiCurveDur   = 0.35,
    PlayerNameESP    = true,
    PlayerAbilityESP = true,
    CharTrail        = true,
    TBEnabled  = true,
    TBMode     = "hold",
    TBKey      = Enum.KeyCode.LeftAlt,
    TBCps      = 60,
    TBExpCps   = 60,
    TBUseExp   = false,
    ShowCPSCounter = true,
    MenuKey        = Enum.KeyCode.RightControl,
}

local _conns = {}
local function Track(c) _conns[#_conns+1]=c; return c end

-- ══════════════════════════════════ FPS / Jitter ══
local smoothFPS=60; local rawFPS=60; local fpsLow=false
local dtHistory={}; local dtPtr=1; local DT_WIN=20; local dtVar=0
for i=1,DT_WIN do dtHistory[i]=1/60 end
local function UpdateFPS(dt)
    rawFPS=dt>0 and 1/dt or 60
    smoothFPS=smoothFPS+0.12*(rawFPS-smoothFPS); fpsLow=smoothFPS<45
    dtHistory[dtPtr]=dt; dtPtr=(dtPtr%DT_WIN)+1
    local m=0; for _,v in ipairs(dtHistory) do m+=v end; m/=DT_WIN
    local s=0; for _,v in ipairs(dtHistory) do s+=(v-m)^2 end; dtVar=s/DT_WIN
end

-- ═══════════════════════════════════════ Ping ══
local PING_WIN=30; local pingBuf={}; local pingPtr=1
local smoothPing=20; local peakPing=20; local livePing=20; local displayPing=20
for i=1,PING_WIN do pingBuf[i]=20 end
local function UpdatePing()
    local raw=LP:GetNetworkPing()*1000
    pingBuf[pingPtr]=raw; pingPtr=(pingPtr%PING_WIN)+1
    smoothPing=smoothPing+0.10*(raw-smoothPing)
    local pk=0; for _,v in ipairs(pingBuf) do if v>pk then pk=v end end
    peakPing=pk; livePing=math.max(smoothPing,peakPing); displayPing=smoothPing
end

-- ── Threshold ────────────────────────────────────────────────────
-- FIX: base 0.20→0.155, one-way ping /2000 cap 0.04
local function GetThreshold()
    local base = S.AutoTiming and 0.155 or S.TriggerTime
    local pingC = math.clamp(smoothPing / 2000, 0, 0.04)
    local fpsC  = fpsLow and math.clamp((60-smoothFPS)/60*0.04, 0, 0.04) or 0
    local jitC  = math.clamp(math.sqrt(dtVar)*1.5, 0, 0.025)
    return base + pingC + fpsC + jitC
end

-- ══════════════════════════════════ CURVE ENGINE ══
local CURVE_SAMPLES=12; local curveBuf={}; local curveBufPtr=1
local curveAngVel=0; local curveAxis=Vector3.new(0,1,0); local curveHomingBias=0
for i=1,CURVE_SAMPLES do curveBuf[i]={pos=Vector3.new(),vel=Vector3.new(),t=0} end
local function CurveSample(ball)
    local z=ball:FindFirstChild("zoomies"); if not z then return end
    curveBuf[curveBufPtr]={pos=ball.Position,vel=z.VectorVelocity,t=tick()}
    curveBufPtr=(curveBufPtr%CURVE_SAMPLES)+1
end
local function CurveAnalyse()
    local function sample(off) return curveBuf[((curveBufPtr-2-off)%CURVE_SAMPLES)+1] end
    local a,b=sample(0),sample(1)
    local dt=a.t-b.t; if dt<0.004 then return end
    local aM=a.vel.Magnitude; local bM=b.vel.Magnitude; if aM<1 or bM<1 then return end
    local aD=a.vel/aM; local bD=b.vel/bM
    local dot=math.clamp(aD:Dot(bD),-1,1)
    curveAngVel=curveAngVel+0.4*(math.acos(dot)/dt-curveAngVel)
    local ax=bD:Cross(aD); if ax.Magnitude>0.0001 then curveAxis=ax.Unit end
    curveHomingBias=math.clamp(math.abs(aM-bM)/dt/200,0,1)
end
local function CurvePredict(ball,lookahead)
    local z=ball:FindFirstChild("zoomies"); if not z then return ball.Position end
    local pos=ball.Position; local vel=z.VectorVelocity; local spd=vel.Magnitude
    if spd<1 then return pos end
    if curveAngVel<0.08 then return pos+vel*lookahead end
    local STEPS=10; local stepDt=lookahead/STEPS; local curV=vel
    for _=1,STEPS do
        local rot=CFrame.fromAxisAngle(curveAxis,curveAngVel*stepDt)
        curV=rot*curV.Unit*spd; pos=pos+curV*stepDt
    end
    return pos
end
local function CurveClear()
    for i=1,CURVE_SAMPLES do curveBuf[i]={pos=Vector3.new(),vel=Vector3.new(),t=0} end
    curveBufPtr=1; curveAngVel=0; curveAxis=Vector3.new(0,1,0); curveHomingBias=0
end
local function IsCurving() return S.CurveDetection and curveAngVel>0.08 end

-- ════════════════════════════════ AUTO CURVE ══
local acPinTarget=nil; local acCamRestoring=false
local function GetCurveTarget()
    if acPinTarget and acPinTarget.Character then
        local h=acPinTarget.Character:FindFirstChild("HumanoidRootPart"); if h then return h end
    end
    local hrp=LP.Character and LP.Character:FindFirstChild("HumanoidRootPart"); if not hrp then return nil end
    local best,bestD=nil,math.huge
    for _,p in ipairs(Players:GetPlayers()) do
        if p~=LP and p.Character then
            local eh=p.Character:FindFirstChild("HumanoidRootPart")
            if eh then local d=(eh.Position-hrp.Position).Magnitude; if d<bestD then bestD=d; best=eh end end
        end
    end
    return best
end
local function DoAutoCurve()
    if not S.AutoCurve then return end
    local target=GetCurveTarget(); if not target or acCamRestoring then return end
    Camera.CFrame=CFrame.new(Camera.CFrame.Position,target.Position+Vector3.new(0,1.5,0))
    acCamRestoring=true; task.delay(S.ACSnapDur,function() acCamRestoring=false end)
end

-- ═══════════════════ CORE PARRY VARS (MUST be before StartAntiCurve) ══
-- FIX: these were declared AFTER StartAntiCurve in the original, causing a
-- nil-upvalue crash on executors that don't hoist locals across function bodies.
local cachedHRP    = nil
local currentBall  = nil   -- used by StartAntiCurve below
local ballConn     = nil
local fireCount    = 0
local inWindow     = false
local hasParried   = false -- NEW: true once we fired this target cycle; reset on target change
local lastParryTime= 0
local PARRY_LOCKOUT= 0.06  -- FIX: 0.15→0.06 (only used to suppress TB double-fire)
local cpsFireBucket=0; local cpsActual=0; local cpsMeasTimer=0

-- ══════════════════════════════ ANTI CURVE ENGINE ══
local antiCurveActive=false; local antiCurveExpiry=0; local antiCurveDir=nil
local function StartAntiCurve()
    if not S.AntiCurve then return end
    local ball=currentBall; if not ball or not ball.Parent then return end
    local target=GetCurveTarget()
    if target then antiCurveDir=(target.Position-ball.Position).Unit
    else
        local z=ball:FindFirstChild("zoomies")
        antiCurveDir=(z and z.VectorVelocity.Magnitude>1) and z.VectorVelocity.Unit or nil
    end
    antiCurveActive=true; antiCurveExpiry=tick()+S.AntiCurveDur
end

-- ══════════════════════════════════ PARRY FIRE ══
local function FireParry()
    lastParryTime=tick()
    VirtualInputManager:SendMouseButtonEvent(0,0,0,true,game,0)
    VirtualInputManager:SendMouseButtonEvent(0,0,0,false,game,0)
    DoAutoCurve(); StartAntiCurve()
end
local function FireParryCPS() cpsFireBucket+=1; FireParry() end

local function GetBall()
    if not BallFolder then return nil end
    for _,b in ipairs(BallFolder:GetChildren()) do if b:GetAttribute("realBall") then return b end end
    for _,b in ipairs(BallFolder:GetChildren()) do if b:IsA("BasePart") or b:IsA("Model") then return b end end
    return nil
end

local function ApproachStraight(ball,hrp)
    local z=ball:FindFirstChild("zoomies")
    if not z or z.VectorVelocity.Magnitude<1 then return true end
    return z.VectorVelocity:Dot(hrp.Position-ball.Position)>0
end
local function ApproachCurve(ball,hrp)
    local fP=CurvePredict(ball,0.12)
    return (hrp.Position-fP).Magnitude<(hrp.Position-ball.Position).Magnitude
        or ApproachStraight(ball,hrp)
end
local function IsApproaching(ball,hrp)
    if tick()-lastParryTime<PARRY_LOCKOUT then return false end
    return S.CurveDetection and ApproachCurve(ball,hrp) or ApproachStraight(ball,hrp)
end

local function TTIStraight(ball,hrp,dt)
    local z=ball:FindFirstChild("zoomies"); if not z then return 0 end
    local vel=z.VectorVelocity; local spd=vel.Magnitude; if spd<1 then return 0 end
    local predictedPos=ball.Position+vel*(dt or 1/60)
    return math.max(0,(hrp.Position-predictedPos).Magnitude/spd)
end
local function TTICurve(ball,hrp,dt)
    local z=ball:FindFirstChild("zoomies"); if not z then return 0 end
    local vel=z.VectorVelocity; local spd=vel.Magnitude; if spd<1 then return 0 end
    local predictedPos=ball.Position+vel*(dt or 1/60)
    local dist=(hrp.Position-predictedPos).Magnitude
    if curveAngVel<0.08 then return math.max(0,dist/spd) end
    local pD=(hrp.Position-CurvePredict(ball,dist/spd)).Magnitude
    return math.max(0,math.min(dist,pD+(dist-pD)*0.5)/spd)
end
local function GetTTI(ball,hrp,dt)
    return S.CurveDetection and TTICurve(ball,hrp,dt) or TTIStraight(ball,hrp,dt)
end

-- ── Triggerbot ───────────────────────────────────────────────────
local tbActive=false; local tbToggleOn=false; local tbLastFire=0; local autoParryBackup=true
local function ActivateTriggerbot()
    if tbActive then return end
    autoParryBackup=S.AutoParry; S.AutoParry=false; tbActive=true
    if _G.__Z0M_RefreshStatus   then _G.__Z0M_RefreshStatus()   end
    if _G.__Z0M_RefreshTBStatus then _G.__Z0M_RefreshTBStatus() end
    if _G.__Z0M_RefreshMobileTB then _G.__Z0M_RefreshMobileTB() end
end
local function DeactivateTriggerbot()
    if not tbActive then return end
    tbActive=false; S.AutoParry=autoParryBackup
    if _G.__Z0M_RefreshStatus   then _G.__Z0M_RefreshStatus()   end
    if _G.__Z0M_RefreshTBStatus then _G.__Z0M_RefreshTBStatus() end
    if _G.__Z0M_RefreshMobileTB then _G.__Z0M_RefreshMobileTB() end
end

-- ── Ball binding ─────────────────────────────────────────────────
local function DisconnectBall()
    if ballConn then ballConn:Disconnect(); ballConn=nil end
    currentBall=nil; fireCount=0; inWindow=false; hasParried=false
end
local function BindBall(ball)
    if ballConn then ballConn:Disconnect(); ballConn=nil end
    currentBall=ball; fireCount=0; inWindow=false; hasParried=false; lastParryTime=0; CurveClear()
    if not ball then return end
    ballConn=ball:GetAttributeChangedSignal("target"):Connect(function()
        -- Real target change: fresh parry window, reset hasParried so we fire again
        fireCount=0; inWindow=false; hasParried=false
    end)
end
local function SetupBallFolder()
    if not BallFolder then return end
    Track(BallFolder.ChildAdded:Connect(function()
        task.spawn(function()
            for _=1,10 do task.wait(0.05); local b=GetBall(); if b then BindBall(b); return end end
            BindBall(GetBall())
        end)
    end))
    Track(BallFolder.ChildRemoved:Connect(function()
        task.wait(); local b=GetBall(); if b then BindBall(b) else DisconnectBall() end
    end))
    BindBall(GetBall())
end
SetupBallFolder()

local function CacheCharacter(char)
    fireCount=0; inWindow=false; hasParried=false; cachedHRP=nil; BindBall(GetBall())
    if not char then return end
    local hrp=char:FindFirstChild("HumanoidRootPart")
    if hrp then cachedHRP=hrp
    else task.spawn(function() cachedHRP=char:WaitForChild("HumanoidRootPart",10) end) end
end
CacheCharacter(LP.Character)
Track(LP.CharacterAdded:Connect(CacheCharacter))

-- ══════════════════════════════════ MAIN LOOP ══
Track(RunService.PreSimulation:Connect(function(dt)
    UpdatePing(); UpdateFPS(dt)
    if S.CurveDetection and currentBall and currentBall.Parent then
        CurveSample(currentBall); CurveAnalyse()
    end
    cpsMeasTimer+=dt
    if cpsMeasTimer>=1 then cpsActual=cpsFireBucket; cpsFireBucket=0; cpsMeasTimer-=1 end

    if tbActive then
        local ball=currentBall; local hrp=cachedHRP
        if ball and ball.Parent and hrp then
            if ball:GetAttribute("target")==LP.Name and ApproachStraight(ball,hrp) then
                local cps=S.TBUseExp and S.TBExpCps or S.TBCps
                local now=tick()
                if now-tbLastFire>=1/math.max(cps,1) then tbLastFire=now; FireParryCPS() end
            end
        end
        return
    end

    if not S.AutoParry then return end
    if not currentBall or not currentBall.Parent then local b=GetBall(); if b then BindBall(b) end end
    local ball=currentBall; if not ball or not ball.Parent then return end
    local hrp=cachedHRP; if not hrp then return end
    if ball:GetAttribute("target")~=LP.Name then return end

    local z   = ball:FindFirstChild("zoomies")
    local spd = z and z.VectorVelocity.Magnitude or 0
    local dist= (hrp.Position-ball.Position).Magnitude

    if dist<1.5 then return end

    -- ── DOUBLE-PARRY GUARD ──────────────────────────────────────
    -- hasParried is set true after we fire. It only resets when the
    -- ball.target attribute changes (new round / new player targeted).
    -- This prevents firing again when the ball velocity takes 2-4 frames
    -- to flip direction on the client side after a successful parry.
    if hasParried then return end

    if not IsApproaching(ball,hrp) then
        if inWindow then inWindow=false; fireCount=0 end
        return
    end

    if S.ClashMode and dist<=S.ClashDist then FireParry(); hasParried=true; return end
    if spd<1 then
        if dist<=5 and fireCount<S.MaxFires then fireCount+=1; FireParry(); hasParried=true end
        return
    end

    local threshold=GetThreshold()
    local tti=GetTTI(ball,hrp,dt)

    if tti<=threshold and fireCount<S.MaxFires then
        inWindow=true; fireCount+=1; FireParry()
        -- Lock immediately after the FIRST fire.
        -- MaxFires is irrelevant here — one parry per round is all the server
        -- accepts. Without this, the very next frame (ball still in-window)
        -- would fire again before the ball's reversed velocity reaches the client.
        hasParried=true
    elseif inWindow and tti>threshold+0.05 then
        inWindow=false; fireCount=0
    end

    -- ── AntiCurve AFTER parry logic (FIX: was before, polluted TTI reads) ──
    if antiCurveActive then
        if tick()>=antiCurveExpiry then
            antiCurveActive=false; antiCurveDir=nil
        else
            if ball and ball.Parent then
                local spd2=z and z.VectorVelocity.Magnitude or 0
                if spd2>1 then
                    local target=GetCurveTarget()
                    if target then antiCurveDir=(target.Position-ball.Position).Unit end
                    if antiCurveDir then
                        local sv=antiCurveDir*spd2
                        pcall(function() ball.AssemblyLinearVelocity=sv; ball.AssemblyAngularVelocity=Vector3.zero end)
                        if z then pcall(function() z.VectorVelocity=sv end) end
                    end
                end
            else antiCurveActive=false; antiCurveDir=nil end
        end
    end
end))

-- ══════════════════════════════════ PLAYER ESP ══
local espData={}
local ABILITY_ATTRS={"EquippedAbility","equippedAbility","Ability","ability","AbilityName","abilityName","SelectedAbility","selectedAbility","CurrentAbility","currentAbility","PlayerAbility","playerAbility","skillName","SkillName"}
local function ScanAttrs(obj)
    if not obj then return nil end
    for _,n in ipairs(ABILITY_ATTRS) do
        local v=obj:GetAttribute(n); if v then local s=tostring(v); if s~="" and s~="None" and s~="nil" and s~="0" and s~="false" then return s end end
    end
    local ok,attrs=pcall(function() return obj:GetAttributes() end)
    if ok and attrs then for k,v in pairs(attrs) do local lk=k:lower(); if lk:find("abilit") or lk:find("skill") or lk:find("power") then local s=tostring(v); if s~="" and s~="false" and s~="0" and s~="nil" and s~="None" then return s end end end end
    return nil
end
local function GetAbility(player)
    local ab=ScanAttrs(player); if ab then return ab end
    local char=player.Character
    if char then
        ab=ScanAttrs(char); if ab then return ab end
        local hum=char:FindFirstChild("Humanoid"); if hum then ab=ScanAttrs(hum); if ab then return ab end end
        for _,obj in ipairs(char:GetDescendants()) do if obj:IsA("StringValue") then local lk=obj.Name:lower(); if (lk:find("abilit") or lk:find("skill") or lk:find("power")) and obj.Value~="" and obj.Value~="None" then return obj.Value end end end
        for _,f in ipairs(char:GetChildren()) do if f:IsA("Folder") or f:IsA("Configuration") then ab=ScanAttrs(f); if ab then return ab end end end
    end
    local ls=player:FindFirstChild("leaderstats"); if ls then for _,v in ipairs(ls:GetChildren()) do if v:IsA("StringValue") and v.Value~="" then local lk=v.Name:lower(); if lk:find("abilit") or lk:find("skill") then return v.Value end end end end
    return "—"
end
local function ClearPlayerESP(player)
    local d=espData[player]; if not d then return end
    for _,c in ipairs(d.conns) do pcall(function() c:Disconnect() end) end
    for _,inst in ipairs(d.instances) do if typeof(inst)=="Instance" and inst.Parent then pcall(function() inst:Destroy() end) end end
    espData[player]=nil
end
local function ClearAllESP() for p in pairs(espData) do ClearPlayerESP(p) end; espData={} end
local function ApplyPlayerESP(player)
    ClearPlayerESP(player); if player==LP then return end
    if not S.PlayerNameESP and not S.PlayerAbilityESP then return end
    local d={conns={},instances={}}; espData[player]=d
    local function AddI(o) d.instances[#d.instances+1]=o end
    local function AddC(c) d.conns[#d.conns+1]=c end
    local function Build(char)
        for _,i in ipairs(d.instances) do if typeof(i)=="Instance" and i.Parent then pcall(function() i:Destroy() end) end end; d.instances={}
        local head=char:WaitForChild("Head",5); if not head then return end
        local bb=Instance.new("BillboardGui"); bb.Adornee=head; bb.AlwaysOnTop=true; bb.LightInfluence=0
        bb.Size=UDim2.new(0,160,0,(S.PlayerNameESP and S.PlayerAbilityESP) and 38 or 20)
        bb.StudsOffset=Vector3.new(0,S.PlayerAbilityESP and 3.4 or 2.8,0); bb.Parent=head; AddI(bb)
        if S.PlayerNameESP then
            local lbl=Instance.new("TextLabel",bb); lbl.Size=UDim2.new(1,0,0,18); lbl.BackgroundTransparency=1
            lbl.Font=Enum.Font.GothamBold; lbl.TextSize=13; lbl.TextXAlignment=Enum.TextXAlignment.Center
            lbl.TextStrokeTransparency=0.3; lbl.ZIndex=5; lbl.Text=player.DisplayName
            local lastC=0
            AddC(RunService.Heartbeat:Connect(function()
                if not lbl.Parent then return end; local now=tick(); if now-lastC<0.1 then return end; lastC=now
                local ball=currentBall; lbl.TextColor3=(ball and ball.Parent and ball:GetAttribute("target")==LP.Name) and Color3.fromRGB(255,60,60) or Color3.fromRGB(255,228,60)
            end))
        end
        if S.PlayerAbilityESP then
            local al=Instance.new("TextLabel",bb); al.Size=UDim2.new(1,0,0,16); al.Position=UDim2.new(0,0,0,S.PlayerNameESP and 20 or 2)
            al.BackgroundTransparency=1; al.Font=Enum.Font.Gotham; al.TextSize=11; al.TextXAlignment=Enum.TextXAlignment.Center
            al.TextColor3=Color3.fromRGB(160,228,255); al.TextStrokeTransparency=0.45; al.ZIndex=5
            local lastA=0
            AddC(RunService.Heartbeat:Connect(function()
                if not al.Parent then return end; local now=tick(); if now-lastA<0.4 then return end; lastA=now
                al.Text="⚡ "..GetAbility(player)
            end))
        end
    end
    if player.Character then Build(player.Character) end
    AddC(player.CharacterAdded:Connect(function(c) task.wait(0.1); Build(c) end))
end
local function ApplyAllESP()
    ClearAllESP(); if not S.PlayerNameESP and not S.PlayerAbilityESP then return end
    for _,p in ipairs(Players:GetPlayers()) do if p~=LP then ApplyPlayerESP(p) end end
end
Track(Players.PlayerAdded:Connect(function(p) if S.PlayerNameESP or S.PlayerAbilityESP then task.wait(0.5); ApplyPlayerESP(p) end end))
Track(Players.PlayerRemoving:Connect(ClearPlayerESP))

-- ══════════════════════════════ Character Trail ══
local function ApplyTrail(char)
    if not char then return end
    local hrp=char:WaitForChild("HumanoidRootPart",5); if not hrp then return end
    for _,v in ipairs(hrp:GetChildren()) do if v:IsA("Trail") or (v:IsA("Attachment") and v.Name:match("^_trail")) then v:Destroy() end end
    if not S.CharTrail then return end
    local a0=Instance.new("Attachment",hrp); a0.Name="_trail0"; a0.Position=Vector3.new(0,1,0)
    local a1=Instance.new("Attachment",hrp); a1.Name="_trail1"; a1.Position=Vector3.new(0,-1,0)
    local t=Instance.new("Trail",hrp); t.Attachment0=a0; t.Attachment1=a1; t.Lifetime=0.4; t.MinLength=0; t.FaceCamera=true
    t.Color=ColorSequence.new({ColorSequenceKeypoint.new(0,Color3.fromRGB(0,180,255)),ColorSequenceKeypoint.new(0.5,Color3.fromRGB(80,80,255)),ColorSequenceKeypoint.new(1,Color3.fromRGB(255,255,255))})
    t.Transparency=NumberSequence.new({NumberSequenceKeypoint.new(0,0.1),NumberSequenceKeypoint.new(1,1)})
end
if LP.Character then ApplyTrail(LP.Character) end
Track(LP.CharacterAdded:Connect(ApplyTrail))

-- ══════════════════════════════════════ FPS BOOST ENGINE ══
local FPS={Shadows=false,Decorations=false,PostFX=false,Fog=false,Particles=false,Textures=false,Quality=false}
local FPSBK={}; local fpsBaseline=0
local Lighting=game:GetService("Lighting")
local function FPSShadows(on)
    if on then if not FPS.Shadows then FPSBK.shadows=Lighting.GlobalShadows end; Lighting.GlobalShadows=false; FPS.Shadows=true
    else Lighting.GlobalShadows=FPSBK.shadows~=nil and FPSBK.shadows or true; FPS.Shadows=false end
end
local function FPSDecorations(on)
    local t=workspace:FindFirstChildOfClass("Terrain"); if not t then return end
    if on then if not FPS.Decorations then FPSBK.deco=t.Decoration end; t.Decoration=false; FPS.Decorations=true
    else t.Decoration=FPSBK.deco~=nil and FPSBK.deco or true; FPS.Decorations=false end
end
local function FPSPostFX(on)
    if on then
        if not FPS.PostFX then FPSBK.postFX={}; for _,fx in ipairs(Lighting:GetChildren()) do if fx:IsA("PostEffect") then FPSBK.postFX[#FPSBK.postFX+1]={obj=fx,enabled=fx.Enabled}; fx.Enabled=false end end end
        FPS.PostFX=true
    else if FPSBK.postFX then for _,e in ipairs(FPSBK.postFX) do if e.obj and e.obj.Parent then e.obj.Enabled=e.enabled end end end; FPS.PostFX=false end
end
local function FPSFog(on)
    if on then if not FPS.Fog then FPSBK.fogEnd=Lighting.FogEnd; FPSBK.fogStart=Lighting.FogStart end; Lighting.FogEnd=9e9; Lighting.FogStart=9e9; FPS.Fog=true
    else Lighting.FogEnd=FPSBK.fogEnd or 100000; Lighting.FogStart=FPSBK.fogStart or 0; FPS.Fog=false end
end
local function FPSParticles(on)
    if on then
        if not FPS.Particles then FPSBK.particles={}; for _,obj in ipairs(workspace:GetDescendants()) do local t=obj.ClassName; if t=="ParticleEmitter" or t=="Trail" or t=="Beam" or t=="Fire" or t=="Smoke" or t=="Sparkles" then FPSBK.particles[#FPSBK.particles+1]={obj=obj,enabled=obj.Enabled}; obj.Enabled=false end end end
        FPS.Particles=true
        if not FPSBK.particleConn then FPSBK.particleConn=workspace.DescendantAdded:Connect(function(obj) if not FPS.Particles then return end; local t=obj.ClassName; if t=="ParticleEmitter" or t=="Trail" or t=="Beam" or t=="Fire" or t=="Smoke" or t=="Sparkles" then obj.Enabled=false end end) end
    else
        if FPSBK.particles then for _,e in ipairs(FPSBK.particles) do if e.obj and e.obj.Parent then e.obj.Enabled=e.enabled end end end
        if FPSBK.particleConn then FPSBK.particleConn:Disconnect(); FPSBK.particleConn=nil end; FPS.Particles=false
    end
end
local function FPSTextures(on)
    if on then
        if not FPS.Textures then FPSBK.textures={}; for _,obj in ipairs(workspace:GetDescendants()) do if obj:IsA("Decal") or obj:IsA("Texture") then FPSBK.textures[#FPSBK.textures+1]={obj=obj,tid=obj.Texture}; obj.Texture="" elseif obj:IsA("SpecialMesh") and obj.MeshType==Enum.MeshType.FileMesh then FPSBK.textures[#FPSBK.textures+1]={obj=obj,tid=obj.TextureId}; obj.TextureId="" end end end
        FPS.Textures=true
    else if FPSBK.textures then for _,e in ipairs(FPSBK.textures) do if e.obj and e.obj.Parent then if e.obj:IsA("SpecialMesh") then e.obj.TextureId=e.tid else e.obj.Texture=e.tid end end end end; FPS.Textures=false end
end
local function FPSQuality(on)
    if on then if not FPS.Quality then pcall(function() FPSBK.quality=settings().Rendering.QualityLevel end) end; pcall(function() settings().Rendering.QualityLevel=Enum.QualityLevel.Level01 end); FPS.Quality=true
    else pcall(function() settings().Rendering.QualityLevel=FPSBK.quality or Enum.QualityLevel.Automatic end); FPS.Quality=false end
end
local FPS_DISPATCH={Shadows=FPSShadows,Decorations=FPSDecorations,PostFX=FPSPostFX,Fog=FPSFog,Particles=FPSParticles,Textures=FPSTextures,Quality=FPSQuality}
local function SetFPSFeature(name,on) local fn=FPS_DISPATCH[name]; if fn then fn(on) end end
local function NukeAll() fpsBaseline=rawFPS; for n in pairs(FPS_DISPATCH) do SetFPSFeature(n,true) end; if _G.__Z0M_RefreshFPS then _G.__Z0M_RefreshFPS() end end
local function RestoreAll() for n in pairs(FPS_DISPATCH) do SetFPSFeature(n,false) end; if _G.__Z0M_RefreshFPS then _G.__Z0M_RefreshFPS() end end

-- ════════════════════════════════════ Config ══
local CONFIG_FILE="z0mware_configs.json"; local CONFIG_SLOTS=5; local configs={}
local CONFIG_KEYS={"AutoParry","AutoTiming","ClashMode","CurveDetection","AutoCurve","AntiCurve","TriggerTime","ClashDist","MaxFires","ACSnapDur","AntiCurveDur","PlayerNameESP","PlayerAbilityESP","CharTrail","TBEnabled","TBMode","TBCps","TBExpCps","TBUseExp","ShowCPSCounter"}
local function SerializeS() local t={}; for _,k in ipairs(CONFIG_KEYS) do t[k]=S[k] end; t.TBKey=tostring(S.TBKey); t.MenuKey=tostring(S.MenuKey); return t end
local function DeserializeIntoS(t)
    for _,k in ipairs(CONFIG_KEYS) do if t[k]~=nil then S[k]=t[k] end end
    for _,f in ipairs({"TBKey","MenuKey"}) do if t[f] then local s=tostring(t[f]):gsub("Enum%.KeyCode%.",""); local ok,v=pcall(function() return Enum.KeyCode[s] end); if ok and v then S[f]=v end end end
end
local function LoadConfigs()
    local ok,data=pcall(function() if readfile then return HttpService:JSONDecode(readfile(CONFIG_FILE)) end; return nil end)
    configs=(ok and type(data)=="table") and data or {}
    for i=1,CONFIG_SLOTS do if not configs[i] then configs[i]={name="Slot "..i,data=nil} end end
end
local function SaveConfigs() pcall(function() if writefile then writefile(CONFIG_FILE,HttpService:JSONEncode(configs)) end end) end
LoadConfigs()

-- ══════════════════════════════════════════ GUI ══
local pgui=LP:WaitForChild("PlayerGui")
local function GuiParent()
    local ok,cg=pcall(function() return game:GetService("CoreGui") end); return ok and cg or pgui
end

local ScreenGui=Instance.new("ScreenGui")
ScreenGui.Name="z0mware_v1"; ScreenGui.ResetOnSpawn=false
ScreenGui.ZIndexBehavior=Enum.ZIndexBehavior.Sibling
ScreenGui.IgnoreGuiInset=true
ScreenGui.Parent=GuiParent()

-- ── Color palette — electric blue accent ──────────────────────
local C={
    bg=Color3.fromRGB(6,7,12),
    panel=Color3.fromRGB(13,14,22),
    header=Color3.fromRGB(9,10,17),
    tabBar=Color3.fromRGB(8,9,15),
    tabBtn=Color3.fromRGB(16,17,28),
    tabSel=Color3.fromRGB(18,24,44),
    accent=Color3.fromRGB(80,190,255),    -- electric blue
    accent2=Color3.fromRGB(110,65,230),   -- purple
    green=Color3.fromRGB(55,205,85),
    red=Color3.fromRGB(255,60,60),
    blue=Color3.fromRGB(75,185,255),
    text=Color3.fromRGB(210,208,200),
    subtext=Color3.fromRGB(105,100,90),
    track=Color3.fromRGB(28,28,42),
    div=Color3.fromRGB(22,22,36),
    orange=Color3.fromRGB(255,135,25),
    purple=Color3.fromRGB(175,95,255),
    cyan=Color3.fromRGB(55,225,225),
    teal=Color3.fromRGB(30,210,175),
    lime=Color3.fromRGB(140,230,60),
    pink=Color3.fromRGB(255,90,180),
}

local W       = isMobile and 350 or 390
local H_FULL  = isMobile and 490 or 450
local H_MIN   = 40
local HEADER_H= H_MIN
local TAB_H   = isMobile and 36 or 30
local CONTENT_TOP = HEADER_H + TAB_H

-- ════════════════════════════ FORWARD-DECLARE Main ══
-- FIX: Main must be declared before the toggle button's click
-- handler, otherwise the handler captures nil and errors on first tap.
local Main

-- ════════════════════════════ FLOATING MENU BUTTON ══
-- Tap/click to toggle the menu. Draggable. Always on top.
local ToggleBtn=Instance.new("TextButton",ScreenGui)
ToggleBtn.Name="Z0M_ToggleBtn"
ToggleBtn.Size=UDim2.new(0,52,0,52)
ToggleBtn.Position=isMobile and UDim2.new(1,-66,1,-144) or UDim2.new(1,-66,0,58)
ToggleBtn.BackgroundColor3=Color3.fromRGB(10,11,20)
ToggleBtn.BorderSizePixel=0
ToggleBtn.Font=Enum.Font.GothamBold
ToggleBtn.TextSize=22
ToggleBtn.Text="⚡"
ToggleBtn.TextColor3=C.accent
ToggleBtn.AutoButtonColor=false
ToggleBtn.ZIndex=50
ToggleBtn.Active=true
Instance.new("UICorner",ToggleBtn).CornerRadius=UDim.new(1,0)
local _tSt=Instance.new("UIStroke",ToggleBtn)
_tSt.Color=C.accent2; _tSt.Thickness=1.5; _tSt.Transparency=0.3

do  -- draggable toggle btn
    local dragging=false; local dragStart=nil; local startPos=nil; local moved=false
    local function onStart(pos) dragging=true; dragStart=pos; startPos=ToggleBtn.Position; moved=false end
    local function onMove(pos)
        if not dragging then return end
        local d=pos-dragStart; if d.Magnitude>6 then moved=true end
        ToggleBtn.Position=UDim2.new(startPos.X.Scale,startPos.X.Offset+d.X,startPos.Y.Scale,startPos.Y.Offset+d.Y)
    end
    local function onEnd() dragging=false end
    ToggleBtn.InputBegan:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then onStart(i.Position) end
    end)
    Track(UserInputService.InputChanged:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch then onMove(i.Position) end
    end))
    Track(UserInputService.InputEnded:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then onEnd() end
    end))
    -- FIX: Main is forward-declared above, so this closure is safe
    ToggleBtn.MouseButton1Click:Connect(function()
        if moved then return end
        if Main then
            Main.Visible=not Main.Visible
            TweenService:Create(ToggleBtn,TweenInfo.new(0.12),{
                BackgroundColor3=Main.Visible and Color3.fromRGB(18,20,42) or Color3.fromRGB(10,11,20)
            }):Play()
        end
    end)
end

-- ════════════════════════ MOBILE TRIGGERBOT BUTTON ══
-- Only shown on mobile. Floating, draggable. Green = active, Red = off.
-- This is a SEPARATE button from the menu button — always visible.
local MobileTBBtn = nil
if isMobile then
    MobileTBBtn=Instance.new("TextButton",ScreenGui)
    MobileTBBtn.Name="Z0M_MobileTBBtn"
    MobileTBBtn.Size=UDim2.new(0,64,0,64)
    MobileTBBtn.Position=UDim2.new(0,14,1,-160)
    MobileTBBtn.BackgroundColor3=Color3.fromRGB(55,10,10)
    MobileTBBtn.BorderSizePixel=0
    MobileTBBtn.Font=Enum.Font.GothamBold
    MobileTBBtn.TextSize=11
    MobileTBBtn.TextLineHeight=1.2
    MobileTBBtn.Text="TBOT\nOFF"
    MobileTBBtn.TextColor3=C.red
    MobileTBBtn.AutoButtonColor=false
    MobileTBBtn.ZIndex=50
    MobileTBBtn.Active=true
    Instance.new("UICorner",MobileTBBtn).CornerRadius=UDim.new(0,14)
    local _mbStroke=Instance.new("UIStroke",MobileTBBtn)
    _mbStroke.Color=C.red; _mbStroke.Thickness=2; _mbStroke.Transparency=0.35

    local function RefreshMobileTB()
        if tbActive then
            MobileTBBtn.Text="TBOT\nON"; MobileTBBtn.TextColor3=C.green
            MobileTBBtn.BackgroundColor3=Color3.fromRGB(10,50,14)
            _mbStroke.Color=C.green
        else
            MobileTBBtn.Text="TBOT\nOFF"; MobileTBBtn.TextColor3=C.red
            MobileTBBtn.BackgroundColor3=Color3.fromRGB(55,10,10)
            _mbStroke.Color=C.red
        end
    end
    _G.__Z0M_RefreshMobileTB=RefreshMobileTB

    do  -- draggable mobile TB btn
        local dragging=false; local dragStart=nil; local startPos=nil; local moved=false
        local function onStart(pos) dragging=true; dragStart=pos; startPos=MobileTBBtn.Position; moved=false end
        local function onMove(pos)
            if not dragging then return end
            local d=pos-dragStart; if d.Magnitude>6 then moved=true end
            MobileTBBtn.Position=UDim2.new(startPos.X.Scale,startPos.X.Offset+d.X,startPos.Y.Scale,startPos.Y.Offset+d.Y)
        end
        local function onEnd() dragging=false end
        MobileTBBtn.InputBegan:Connect(function(i)
            if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then onStart(i.Position) end
        end)
        Track(UserInputService.InputChanged:Connect(function(i)
            if i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch then onMove(i.Position) end
        end))
        Track(UserInputService.InputEnded:Connect(function(i)
            if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then onEnd() end
        end))
        MobileTBBtn.MouseButton1Click:Connect(function()
            if moved then return end
            if not S.TBEnabled then return end
            if tbActive then DeactivateTriggerbot() else ActivateTriggerbot() end
            RefreshMobileTB()
        end)
    end
end

-- ════════════════════════════════════ MAIN PANEL ══
-- FIX: assignment to the forward-declared local `Main`
Main=Instance.new("Frame",ScreenGui)
Main.Name="MainPanel"
Main.Size=UDim2.new(0,W,0,H_FULL)
Main.Position=isMobile and UDim2.new(1,-(W+8),0.5,-H_FULL/2) or UDim2.new(0,20,0.5,-H_FULL/2)
Main.BackgroundColor3=C.bg
Main.BorderSizePixel=0
Main.Active=true
Main.ClipsDescendants=true
Main.Visible=false
Main.ZIndex=10
Instance.new("UICorner",Main).CornerRadius=UDim.new(0,10)
local _ms=Instance.new("UIStroke",Main); _ms.Color=C.accent2; _ms.Thickness=1; _ms.Transparency=0.4

-- Gradient accent bar
local AccBar=Instance.new("Frame",Main); AccBar.Size=UDim2.new(0,3,1,0); AccBar.BorderSizePixel=0; AccBar.ZIndex=4
local _ag=Instance.new("UIGradient",AccBar)
_ag.Color=ColorSequence.new({
    ColorSequenceKeypoint.new(0,Color3.fromRGB(110,65,230)),
    ColorSequenceKeypoint.new(0.4,Color3.fromRGB(80,190,255)),
    ColorSequenceKeypoint.new(0.7,Color3.fromRGB(30,210,175)),
    ColorSequenceKeypoint.new(1,Color3.fromRGB(255,60,60))
}); _ag.Rotation=90

-- Header
local Header=Instance.new("Frame",Main)
Header.Name="Header"; Header.Size=UDim2.new(1,0,0,HEADER_H)
Header.BackgroundColor3=C.header; Header.BorderSizePixel=0; Header.ZIndex=3

local TitleLbl=Instance.new("TextLabel",Header)
TitleLbl.Size=UDim2.new(1,-80,1,0); TitleLbl.Position=UDim2.new(0,14,0,0)
TitleLbl.BackgroundTransparency=1; TitleLbl.Text="⚡  z0mware"
TitleLbl.Font=Enum.Font.GothamBold; TitleLbl.TextSize=isMobile and 15 or 14
TitleLbl.TextColor3=C.accent; TitleLbl.TextXAlignment=Enum.TextXAlignment.Left; TitleLbl.ZIndex=4

local MinBtn=Instance.new("TextButton",Header)
MinBtn.Size=UDim2.new(0,28,0,24); MinBtn.Position=UDim2.new(1,-64,0.5,-12)
MinBtn.BackgroundColor3=C.panel; MinBtn.BorderSizePixel=0; MinBtn.Font=Enum.Font.GothamBold
MinBtn.TextSize=14; MinBtn.TextColor3=C.subtext; MinBtn.Text="─"; MinBtn.AutoButtonColor=false; MinBtn.ZIndex=5
Instance.new("UICorner",MinBtn).CornerRadius=UDim.new(0,6)

local CloseBtn=Instance.new("TextButton",Header)
CloseBtn.Size=UDim2.new(0,28,0,24); CloseBtn.Position=UDim2.new(1,-32,0.5,-12)
CloseBtn.BackgroundColor3=Color3.fromRGB(160,28,28); CloseBtn.BorderSizePixel=0; CloseBtn.Font=Enum.Font.GothamBold
CloseBtn.TextSize=14; CloseBtn.TextColor3=Color3.new(1,1,1); CloseBtn.Text="✕"; CloseBtn.AutoButtonColor=false; CloseBtn.ZIndex=5
Instance.new("UICorner",CloseBtn).CornerRadius=UDim.new(0,6)

-- Tab bar
local TabBar=Instance.new("Frame",Main)
TabBar.Name="TabBar"; TabBar.Size=UDim2.new(1,0,0,TAB_H); TabBar.Position=UDim2.new(0,0,0,HEADER_H)
TabBar.BackgroundColor3=C.tabBar; TabBar.BorderSizePixel=0; TabBar.ZIndex=3
local _tbl=Instance.new("UIListLayout",TabBar)
_tbl.FillDirection=Enum.FillDirection.Horizontal; _tbl.HorizontalAlignment=Enum.HorizontalAlignment.Left
_tbl.SortOrder=Enum.SortOrder.LayoutOrder

-- ── Drag helper ──────────────────────────────────────────────────
local function MakeDraggable(frame,handle)
    handle=handle or frame
    local dragging=false; local dragStart,startPos
    local function begin(pos) dragging=true; dragStart=pos; startPos=frame.Position end
    local function move(pos)
        if not dragging then return end; local d=pos-dragStart
        frame.Position=UDim2.new(startPos.X.Scale,startPos.X.Offset+d.X,startPos.Y.Scale,startPos.Y.Offset+d.Y)
    end
    local function finish() dragging=false end
    handle.InputBegan:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then begin(i.Position) end
    end)
    Track(UserInputService.InputChanged:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch then move(i.Position) end
    end))
    Track(UserInputService.InputEnded:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then finish() end
    end))
end
MakeDraggable(Main,Header)

-- ── Widget helpers ───────────────────────────────────────────────
local sliderRefs={}

local function MakeDivider(p,order)
    local d=Instance.new("Frame",p); d.Size=UDim2.new(0.9,0,0,1); d.BackgroundColor3=C.div; d.BorderSizePixel=0; d.LayoutOrder=order
end
local function MakeSection(p,txt,order)
    local l=Instance.new("TextLabel",p); l.Size=UDim2.new(0.9,0,0,18); l.BackgroundTransparency=1
    l.Font=Enum.Font.GothamBold; l.TextSize=10; l.TextColor3=C.subtext
    l.TextXAlignment=Enum.TextXAlignment.Left; l.Text=txt:upper(); l.LayoutOrder=order; l.ZIndex=3
end

local TOGGLE_H=isMobile and 46 or 38

local function MakeToggle(p,label,getV,setV,onColor,order,onChange)
    local Row=Instance.new("Frame",p)
    Row.Size=UDim2.new(0.9,0,0,TOGGLE_H); Row.BackgroundColor3=C.panel; Row.BorderSizePixel=0; Row.LayoutOrder=order
    Instance.new("UICorner",Row).CornerRadius=UDim.new(0,8)
    local Lbl=Instance.new("TextLabel",Row)
    Lbl.Size=UDim2.new(1,-60,1,0); Lbl.Position=UDim2.new(0,12,0,0)
    Lbl.BackgroundTransparency=1; Lbl.Font=Enum.Font.Gotham; Lbl.TextSize=isMobile and 14 or 12
    Lbl.TextColor3=C.text; Lbl.TextXAlignment=Enum.TextXAlignment.Left; Lbl.Text=label; Lbl.ZIndex=3
    local Trk=Instance.new("Frame",Row)
    Trk.Size=UDim2.new(0,38,0,22); Trk.Position=UDim2.new(1,-50,0.5,-11)
    Trk.BackgroundColor3=getV() and onColor or C.track; Trk.BorderSizePixel=0
    Instance.new("UICorner",Trk).CornerRadius=UDim.new(1,0)
    local Knob=Instance.new("Frame",Trk)
    Knob.Size=UDim2.new(0,16,0,16)
    Knob.Position=getV() and UDim2.new(1,-19,0.5,-8) or UDim2.new(0,3,0.5,-8)
    Knob.BackgroundColor3=Color3.fromRGB(240,238,228); Knob.BorderSizePixel=0
    Instance.new("UICorner",Knob).CornerRadius=UDim.new(1,0)
    local Hit=Instance.new("TextButton",Row); Hit.Size=UDim2.new(1,0,1,0); Hit.BackgroundTransparency=1; Hit.Text=""; Hit.ZIndex=5
    local function Sync(on)
        TweenService:Create(Trk,TweenInfo.new(0.15),{BackgroundColor3=on and onColor or C.track}):Play()
        TweenService:Create(Knob,TweenInfo.new(0.15),{Position=on and UDim2.new(1,-19,0.5,-8) or UDim2.new(0,3,0.5,-8)}):Play()
    end
    Hit.MouseButton1Click:Connect(function() local on=not getV(); setV(on); Sync(on); if onChange then onChange(on) end end)
    return Sync
end

local function MakeSlider(p,label,key,minV,maxV,fmt,lockWhen,order)
    local h=isMobile and 60 or 52
    local Row=Instance.new("Frame",p); Row.Size=UDim2.new(0.9,0,0,h); Row.BackgroundColor3=C.panel; Row.BorderSizePixel=0; Row.LayoutOrder=order
    Instance.new("UICorner",Row).CornerRadius=UDim.new(0,8)
    local Lbl=Instance.new("TextLabel",Row); Lbl.Size=UDim2.new(1,-10,0,22); Lbl.Position=UDim2.new(0,12,0,4); Lbl.BackgroundTransparency=1; Lbl.Font=Enum.Font.Gotham; Lbl.TextSize=11; Lbl.TextXAlignment=Enum.TextXAlignment.Left; Lbl.ZIndex=3
    local function Locked() return lockWhen and S[lockWhen] end
    local function UpdLbl(val) Lbl.TextColor3=Locked() and C.subtext or C.text; Lbl.Text=label..":  "..string.format(fmt,val)..(Locked() and "  [AUTO]" or "") end
    UpdLbl(S[key])
    local trackH=isMobile and 8 or 5
    local Tr=Instance.new("Frame",Row); Tr.Size=UDim2.new(0.86,0,0,trackH); Tr.Position=UDim2.new(0.07,0,1,-18); Tr.BackgroundColor3=C.track; Tr.BorderSizePixel=0; Instance.new("UICorner",Tr).CornerRadius=UDim.new(1,0)
    local iR=math.clamp((S[key]-minV)/(maxV-minV),0,1)
    local Fill=Instance.new("Frame",Tr); Fill.Size=UDim2.new(iR,0,1,0); Fill.BackgroundColor3=Locked() and C.subtext or C.accent; Fill.BorderSizePixel=0; Instance.new("UICorner",Fill).CornerRadius=UDim.new(1,0)
    local kSize=isMobile and 22 or 14
    local Knob=Instance.new("TextButton",Tr); Knob.Size=UDim2.new(0,kSize,0,kSize); Knob.Position=UDim2.new(iR,-kSize/2,0.5,-kSize/2); Knob.BackgroundColor3=Locked() and C.subtext or C.accent; Knob.BorderSizePixel=0; Knob.Text=""; Knob.ZIndex=5; Instance.new("UICorner",Knob).CornerRadius=UDim.new(1,0)
    local function SetVal(val)
        local r=math.clamp((val-minV)/(maxV-minV),0,1)
        Fill.Size=UDim2.new(r,0,1,0); Knob.Position=UDim2.new(r,-kSize/2,0.5,-kSize/2); UpdLbl(val)
        Fill.BackgroundColor3=Locked() and C.subtext or C.accent; Knob.BackgroundColor3=Locked() and C.subtext or C.accent
    end
    sliderRefs[key]=SetVal
    local sliding=false
    Knob.InputBegan:Connect(function(i)
        if (i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch) and not Locked() then sliding=true end
    end)
    Track(UserInputService.InputEnded:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then sliding=false end
    end))
    Track(UserInputService.InputChanged:Connect(function(i)
        if not sliding then return end
        if i.UserInputType~=Enum.UserInputType.MouseMovement and i.UserInputType~=Enum.UserInputType.Touch then return end
        if Locked() then sliding=false; return end
        local w=Tr.AbsoluteSize.X; if w==0 then return end
        local r=math.clamp((i.Position.X-Tr.AbsolutePosition.X)/w,0,1)
        S[key]=math.floor((minV+(maxV-minV)*r)*1000+0.5)/1000
        Fill.Size=UDim2.new(r,0,1,0); Knob.Position=UDim2.new(r,-kSize/2,0.5,-kSize/2); UpdLbl(S[key])
    end))
end

local function MakeInfo(p,color,order,h)
    local l=Instance.new("TextLabel",p); l.Size=UDim2.new(0.9,0,0,h or 15); l.BackgroundTransparency=1
    l.Font=Enum.Font.Gotham; l.TextSize=11; l.TextColor3=color or C.subtext
    l.TextXAlignment=Enum.TextXAlignment.Left; l.LayoutOrder=order; l.ZIndex=3; return l
end

local function MakeScroll()
    local sf=Instance.new("ScrollingFrame",Main)
    sf.Size=UDim2.new(1,0,1,-CONTENT_TOP); sf.Position=UDim2.new(0,0,0,CONTENT_TOP)
    sf.BackgroundTransparency=1; sf.BorderSizePixel=0
    sf.ScrollBarThickness=isMobile and 4 or 3; sf.ScrollBarImageColor3=C.accent2
    sf.CanvasSize=UDim2.new(0,0,0,0); sf.AutomaticCanvasSize=Enum.AutomaticSize.Y
    sf.ZIndex=2; sf.Visible=false; sf.ElasticBehavior=Enum.ElasticBehavior.Always; sf.ScrollingEnabled=true
    local l=Instance.new("UIListLayout",sf); l.Padding=UDim.new(0,5)
    l.HorizontalAlignment=Enum.HorizontalAlignment.Center; l.SortOrder=Enum.SortOrder.LayoutOrder
    local pad=Instance.new("UIPadding",sf); pad.PaddingTop=UDim.new(0,8); pad.PaddingBottom=UDim.new(0,10)
    return sf
end

local TAB_NAMES={"Main","Curve","Visual","Triggerbot","FPS","Config"}
local tabScrolls={}; local tabBtns={}; local activeTab=nil

local function SwitchTab(name)
    if activeTab==name then return end; activeTab=name
    for n,sf in pairs(tabScrolls) do sf.Visible=(n==name) end
    for n,btn in pairs(tabBtns) do
        local on=(n==name)
        TweenService:Create(btn,TweenInfo.new(0.12),{BackgroundColor3=on and C.tabSel or C.tabBtn,TextColor3=on and C.accent or C.subtext}):Play()
        local line=btn:FindFirstChild("_line"); if line then TweenService:Create(line,TweenInfo.new(0.12),{BackgroundColor3=on and C.accent or C.tabBar}):Play() end
    end
end

local TAB_W=math.floor(W/#TAB_NAMES)
for idx,tname in ipairs(TAB_NAMES) do
    local btn=Instance.new("TextButton",TabBar)
    btn.Name=tname; btn.Size=UDim2.new(0,TAB_W,1,0); btn.BackgroundColor3=C.tabBtn; btn.BorderSizePixel=0
    btn.Font=Enum.Font.GothamBold; btn.TextSize=isMobile and 10 or 11; btn.TextColor3=C.subtext; btn.Text=tname
    btn.AutoButtonColor=false; btn.ZIndex=4; btn.LayoutOrder=idx
    local line=Instance.new("Frame",btn); line.Name="_line"; line.Size=UDim2.new(0.7,0,0,2); line.Position=UDim2.new(0.15,0,1,-2); line.BackgroundColor3=C.tabBar; line.BorderSizePixel=0; line.ZIndex=5; Instance.new("UICorner",line).CornerRadius=UDim.new(1,0)
    tabBtns[tname]=btn; tabScrolls[tname]=MakeScroll()
    btn.MouseButton1Click:Connect(function() SwitchTab(tname) end)
end

-- ═══════════════════════════════ MAIN TAB ══
do
    local sc=tabScrolls["Main"]; local o=0; local function O() o+=1; return o end

    -- Status card
    local StatusCard=Instance.new("Frame",sc)
    StatusCard.Size=UDim2.new(0.9,0,0,isMobile and 76 or 62)
    StatusCard.BackgroundColor3=C.panel; StatusCard.BorderSizePixel=0; StatusCard.LayoutOrder=O()
    Instance.new("UICorner",StatusCard).CornerRadius=UDim.new(0,10)
    local _scStroke=Instance.new("UIStroke",StatusCard); _scStroke.Thickness=1; _scStroke.Transparency=0.5

    local StatusLbl=Instance.new("TextLabel",StatusCard)
    StatusLbl.Size=UDim2.new(1,0,0.55,0); StatusLbl.Position=UDim2.new(0,0,0.1,0)
    StatusLbl.BackgroundTransparency=1; StatusLbl.Font=Enum.Font.GothamBold
    StatusLbl.TextSize=isMobile and 15 or 13; StatusLbl.TextXAlignment=Enum.TextXAlignment.Center; StatusLbl.ZIndex=3

    local SubStatusLbl=Instance.new("TextLabel",StatusCard)
    SubStatusLbl.Size=UDim2.new(1,0,0.35,0); SubStatusLbl.Position=UDim2.new(0,0,0.62,0)
    SubStatusLbl.BackgroundTransparency=1; SubStatusLbl.Font=Enum.Font.Gotham
    SubStatusLbl.TextSize=10; SubStatusLbl.TextXAlignment=Enum.TextXAlignment.Center
    SubStatusLbl.TextColor3=C.subtext; SubStatusLbl.ZIndex=3

    local function RefreshStatus()
        StatusLbl.Text=S.AutoParry and "⬤  AUTO PARRY  ON" or "○  AUTO PARRY  OFF"
        StatusLbl.TextColor3=S.AutoParry and C.green or C.red
        _scStroke.Color=S.AutoParry and C.green or C.red
        SubStatusLbl.Text=hasParried and "Parried — waiting for next round"
            or inWindow and string.format("Firing... %d/%d",fireCount,S.MaxFires)
            or string.format("Armed — threshold %.0fms",GetThreshold()*1000)
    end
    RefreshStatus(); _G.__Z0M_RefreshStatus=RefreshStatus

    MakeDivider(sc,O()); MakeSection(sc,"  ⚔  Combat",O())
    MakeToggle(sc,"Auto Parry",function() return S.AutoParry end,function(v) S.AutoParry=v end,C.green,O(),function() RefreshStatus() end)
    MakeToggle(sc,"Auto Timing",function() return S.AutoTiming end,function(v) S.AutoTiming=v end,C.blue,O(),function(on)
        if sliderRefs["TriggerTime"] then sliderRefs["TriggerTime"](on and GetThreshold() or S.TriggerTime) end
    end)
    MakeToggle(sc,"Clash Mode",function() return S.ClashMode end,function(v) S.ClashMode=v end,C.orange,O())

    MakeDivider(sc,O()); MakeSection(sc,"  🎛  Tuning",O())
    MakeSlider(sc,"Trigger (s)","TriggerTime",0.10,0.55,"%.3f","AutoTiming",O())
    MakeSlider(sc,"Clash dist", "ClashDist",  4,   20,  "%.0f st",nil,O())
    MakeSlider(sc,"Max fires",  "MaxFires",   1,   8,   "%.0f",   nil,O())

    MakeDivider(sc,O()); MakeSection(sc,"  📊  Live",O())
    local PingLbl  =MakeInfo(sc,nil,O(),16)
    local FpsLbl   =MakeInfo(sc,C.cyan,O(),14)
    local CompLbl  =MakeInfo(sc,C.orange,O(),14)
    local BallLbl  =MakeInfo(sc,C.blue,O(),14)
    local TgtLbl   =MakeInfo(sc,Color3.fromRGB(190,140,255),O(),14)
    local FireLbl  =MakeInfo(sc,Color3.fromRGB(255,200,60),O(),14)
    local ThreshLbl=MakeInfo(sc,C.subtext,O(),14)

    _G.__Z0M_UpdateMain=function()
        local thresh=GetThreshold()
        RefreshStatus()
        local spiking=peakPing>smoothPing*1.5 and peakPing>smoothPing+30
        local pc=displayPing<60 and C.green or displayPing<120 and Color3.fromRGB(255,210,40) or C.red
        PingLbl.TextColor3=spiking and C.red or pc
        PingLbl.Text=spiking and string.format("Ping: %.0f ms  ▲ spike %.0f",displayPing,peakPing) or string.format("Ping: %.0f ms",displayPing)
        local fc=smoothFPS>=55 and C.green or smoothFPS>=35 and Color3.fromRGB(255,210,40) or C.red
        FpsLbl.TextColor3=fc; FpsLbl.Text=string.format("FPS: %.0f  (raw %.0f)",smoothFPS,rawFPS)
        local fpsC2=fpsLow and math.clamp((60-smoothFPS)/60*0.07,0,0.07) or 0
        local jitC2=math.clamp(math.sqrt(dtVar)*3,0,0.04)
        local anyC=fpsC2>0.001 or jitC2>0.001 or spiking
        CompLbl.Text=anyC and string.format("⚠ Comp: +%.0fms ping  +%.0fms fps  +%.0fms jitter",smoothPing/2,fpsC2*1000,jitC2*1000) or "  All systems nominal"
        CompLbl.TextColor3=anyC and C.orange or C.subtext
        ThreshLbl.Text=S.AutoTiming and string.format("Threshold: %.3f s  (auto)",thresh) or string.format("Threshold: %.3f s  (manual)",S.TriggerTime)
        if S.AutoTiming and sliderRefs["TriggerTime"] then sliderRefs["TriggerTime"](thresh) end
        local ball=currentBall
        if ball and ball.Parent then
            BallLbl.TextColor3=C.green; BallLbl.Text="✓  Ball: "..ball.Name
            local tgt=ball:GetAttribute("target") or "—"; local isUs=tgt==LP.Name
            TgtLbl.TextColor3=isUs and C.red or C.subtext; TgtLbl.Text="Target: "..tgt..(isUs and "  ← YOU" or "")
            if hasParried then
                FireLbl.Text="✓ Parried — locked until next target"; FireLbl.TextColor3=C.green
            else
                FireLbl.Text=string.format("Fires: %d/%d  %s",fireCount,S.MaxFires,inWindow and "[ WINDOW ]" or "")
                FireLbl.TextColor3=inWindow and Color3.fromRGB(255,200,60) or C.subtext
            end
        else BallLbl.TextColor3=C.red; BallLbl.Text="✗  No ball"; TgtLbl.Text="Target: —"; FireLbl.Text="Fires: —" end
    end

    MakeDivider(sc,O()); MakeSection(sc,"  ⚠  Quick",O())
    local UBtn=Instance.new("TextButton",sc); UBtn.Size=UDim2.new(0.9,0,0,34); UBtn.BackgroundColor3=Color3.fromRGB(110,20,20); UBtn.BorderSizePixel=0; UBtn.LayoutOrder=O(); UBtn.Font=Enum.Font.GothamBold; UBtn.TextSize=11; UBtn.TextColor3=Color3.fromRGB(255,185,185); UBtn.Text="🗑  UNLOAD z0mware"; UBtn.AutoButtonColor=false
    Instance.new("UICorner",UBtn).CornerRadius=UDim.new(0,8)
    local uConf=false
    UBtn.MouseButton1Click:Connect(function()
        if not uConf then
            uConf=true; UBtn.Text="⚠  CLICK AGAIN TO CONFIRM"; UBtn.BackgroundColor3=Color3.fromRGB(180,50,15)
            task.delay(3,function() if uConf then uConf=false; UBtn.Text="🗑  UNLOAD z0mware"; UBtn.BackgroundColor3=Color3.fromRGB(110,20,20) end end)
        else
            uConf=false; if tbActive then DeactivateTriggerbot() end; RestoreAll()
            ClearAllESP(); DisconnectBall()
            for _,c in ipairs(_conns) do pcall(function() c:Disconnect() end) end
            if _G.__Z0M_CPSOverlay and _G.__Z0M_CPSOverlay.Parent then _G.__Z0M_CPSOverlay:Destroy() end
            TweenService:Create(Main,TweenInfo.new(0.2,Enum.EasingStyle.Back,Enum.EasingDirection.In),{Size=UDim2.new(0,0,0,0)}):Play()
            TweenService:Create(ToggleBtn,TweenInfo.new(0.15),{Size=UDim2.new(0,0,0,0)}):Play()
            if MobileTBBtn then TweenService:Create(MobileTBBtn,TweenInfo.new(0.15),{Size=UDim2.new(0,0,0,0)}):Play() end
            task.delay(0.3,function() ScreenGui:Destroy() end)
        end
    end)
end

-- ════════════════════════════ CURVE TAB ══
do
    local sc=tabScrolls["Curve"]; local o=0; local function O() o+=1; return o end
    MakeSection(sc,"  📡  Curve Detection",O()); MakeDivider(sc,O())
    MakeToggle(sc,"Curve Detection",function() return S.CurveDetection end,function(v) S.CurveDetection=v; CurveClear() end,C.purple,O())
    local cdNote=MakeInfo(sc,C.subtext,O(),13); cdNote.Text="  Required by Auto Curve. Provides trajectory sampling."
    MakeDivider(sc,O()); MakeSection(sc,"  🔵  Auto Curve",O())
    MakeToggle(sc,"Auto Curve",function() return S.AutoCurve end,function(v) S.AutoCurve=v; if not v then acPinTarget=nil end end,C.teal,O())
    local acN1=MakeInfo(sc,C.subtext,O(),13); acN1.Text="  After parrying, snaps camera to nearest enemy"
    local acN2=MakeInfo(sc,C.subtext,O(),13); acN2.Text="  so the ball curves toward them on exit."
    MakeSlider(sc,"Snap dur (s)","ACSnapDur",0.05,0.50,"%.2f",nil,O())
    MakeDivider(sc,O()); MakeSection(sc,"  📌  Curve Target",O())
    local pinRow=Instance.new("Frame",sc); pinRow.Size=UDim2.new(0.9,0,0,38); pinRow.BackgroundColor3=C.panel; pinRow.BorderSizePixel=0; pinRow.LayoutOrder=O(); Instance.new("UICorner",pinRow).CornerRadius=UDim.new(0,8)
    local pinLbl=Instance.new("TextLabel",pinRow); pinLbl.Size=UDim2.new(1,-90,1,0); pinLbl.Position=UDim2.new(0,12,0,0); pinLbl.BackgroundTransparency=1; pinLbl.Font=Enum.Font.Gotham; pinLbl.TextSize=11; pinLbl.TextColor3=C.text; pinLbl.TextXAlignment=Enum.TextXAlignment.Left; pinLbl.ZIndex=3
    local pinBtn=Instance.new("TextButton",pinRow); pinBtn.Size=UDim2.new(0,80,0,26); pinBtn.Position=UDim2.new(1,-88,0.5,-13); pinBtn.BackgroundColor3=C.teal; pinBtn.BorderSizePixel=0; pinBtn.Font=Enum.Font.GothamBold; pinBtn.TextSize=10; pinBtn.TextColor3=Color3.fromRGB(0,0,0); pinBtn.Text="Cycle"; pinBtn.AutoButtonColor=false; pinBtn.ZIndex=5; Instance.new("UICorner",pinBtn).CornerRadius=UDim.new(0,6)
    local function RefreshPinLbl()
        if acPinTarget then pinLbl.Text="  📌 "..acPinTarget.DisplayName; pinLbl.TextColor3=C.teal
        else pinLbl.Text="  Auto (nearest)"; pinLbl.TextColor3=C.subtext end
    end
    RefreshPinLbl()
    pinBtn.MouseButton1Click:Connect(function()
        local list={}; for _,p in ipairs(Players:GetPlayers()) do if p~=LP then list[#list+1]=p end end
        if #list==0 then acPinTarget=nil; RefreshPinLbl(); return end
        if not acPinTarget then acPinTarget=list[1]
        else local found=false; for i,p in ipairs(list) do if p==acPinTarget then acPinTarget=list[i%#list+1]; found=true; break end end; if not found then acPinTarget=list[1] end end
        RefreshPinLbl()
    end)
    MakeDivider(sc,O()); MakeSection(sc,"  🔴  Anti Curve",O())
    MakeToggle(sc,"Anti Curve",function() return S.AntiCurve end,function(v) S.AntiCurve=v; if not v then antiCurveActive=false; antiCurveDir=nil end end,C.red,O())
    local acN3=MakeInfo(sc,C.subtext,O(),13); acN3.Text="  After parrying, overrides ball physics each frame."
    local acN4=MakeInfo(sc,C.subtext,O(),13); acN4.Text="  Zeroes spin + forces straight-line velocity to target."
    MakeSlider(sc,"Duration (s)","AntiCurveDur",0.10,1.00,"%.2f",nil,O())
    MakeDivider(sc,O()); MakeSection(sc,"  📊  Curve Status",O())
    local CurveLbl=MakeInfo(sc,C.purple,O(),15); local ACLbl=MakeInfo(sc,C.red,O(),14); local HomingLbl=MakeInfo(sc,C.orange,O(),14)
    _G.__Z0M_UpdateCurve=function()
        if S.CurveDetection then
            local curving=IsCurving()
            CurveLbl.TextColor3=curving and C.purple or C.subtext; CurveLbl.Text=curving and string.format("ω = %.2f rad/s   CURVING",curveAngVel) or "Ball: straight path"
            HomingLbl.Text=string.format("Homing bias: %.0f%%",curveHomingBias*100); HomingLbl.TextColor3=curveHomingBias>0.5 and C.orange or C.subtext
        else CurveLbl.Text="Curve Detection: OFF"; CurveLbl.TextColor3=C.subtext; HomingLbl.Text="Homing bias: N/A"; HomingLbl.TextColor3=C.subtext end
        if S.AntiCurve then
            if antiCurveActive then ACLbl.TextColor3=C.red; ACLbl.Text=string.format("⬤ STRAIGHTENING  %.2fs left",math.max(0,antiCurveExpiry-tick()))
            else ACLbl.TextColor3=C.subtext; ACLbl.Text="○ Anti Curve armed — fires on next parry" end
        else ACLbl.TextColor3=C.subtext; ACLbl.Text="Anti Curve: OFF" end
        RefreshPinLbl()
    end
end

-- ═══════════════════════════════ VISUAL TAB ══
do
    local sc=tabScrolls["Visual"]; local o=0; local function O() o+=1; return o end
    MakeSection(sc,"  👤  Player ESP",O()); MakeDivider(sc,O())
    MakeToggle(sc,"Player Name ESP",function() return S.PlayerNameESP end,function(v) S.PlayerNameESP=v; ApplyAllESP() end,Color3.fromRGB(255,228,50),O())
    local n1=MakeInfo(sc,C.subtext,O(),13); n1.Text="  Names above heads. Red = shooter targeting you."
    MakeToggle(sc,"Player Ability ESP",function() return S.PlayerAbilityESP end,function(v) S.PlayerAbilityESP=v; ApplyAllESP() end,Color3.fromRGB(100,200,255),O())
    local n2=MakeInfo(sc,C.subtext,O(),13); n2.Text="  Deep attribute scan for equipped abilities."
    MakeDivider(sc,O()); MakeSection(sc,"  ✦  Character",O())
    MakeToggle(sc,"Character Trail",function() return S.CharTrail end,function(v) S.CharTrail=v; if LP.Character then ApplyTrail(LP.Character) end end,C.accent2,O())
    MakeDivider(sc,O()); MakeSection(sc,"  🖥  Overlay",O())
    MakeToggle(sc,"CPS Counter Overlay",function() return S.ShowCPSCounter end,function(v) S.ShowCPSCounter=v; if _G.__Z0M_CPSOverlay then _G.__Z0M_CPSOverlay.Visible=v end end,C.accent,O())
    local h1=MakeInfo(sc,C.subtext,O(),14); h1.Text="  Drag the overlay anywhere on screen."
    if not isMobile then
        MakeDivider(sc,O()); MakeSection(sc,"  ⌨  Menu Keybind",O())
        local MBRow=Instance.new("Frame",sc); MBRow.Size=UDim2.new(0.9,0,0,38); MBRow.BackgroundColor3=C.panel; MBRow.BorderSizePixel=0; MBRow.LayoutOrder=O(); Instance.new("UICorner",MBRow).CornerRadius=UDim.new(0,8)
        local MBLbl=Instance.new("TextLabel",MBRow); MBLbl.Size=UDim2.new(0,90,1,0); MBLbl.Position=UDim2.new(0,12,0,0); MBLbl.BackgroundTransparency=1; MBLbl.Font=Enum.Font.Gotham; MBLbl.TextSize=12; MBLbl.TextColor3=C.text; MBLbl.TextXAlignment=Enum.TextXAlignment.Left; MBLbl.Text="Show/Hide"; MBLbl.ZIndex=3
        local MBBtn=Instance.new("TextButton",MBRow); MBBtn.Size=UDim2.new(0,84,0,24); MBBtn.Position=UDim2.new(1,-94,0.5,-12); MBBtn.BackgroundColor3=C.track; MBBtn.BorderSizePixel=0; MBBtn.Font=Enum.Font.GothamBold; MBBtn.TextSize=11; MBBtn.TextColor3=C.accent; MBBtn.AutoButtonColor=false; MBBtn.ZIndex=4; Instance.new("UICorner",MBBtn).CornerRadius=UDim.new(0,6)
        local mbListening=false
        local function UpdateMBLbl()
            if mbListening then MBBtn.Text="Press key..."; MBBtn.TextColor3=Color3.fromRGB(255,255,100); MBBtn.BackgroundColor3=Color3.fromRGB(38,34,18)
            else MBBtn.Text=tostring(S.MenuKey):gsub("Enum%.KeyCode%.",""); MBBtn.TextColor3=C.accent; MBBtn.BackgroundColor3=C.track end
        end
        UpdateMBLbl(); MBBtn.MouseButton1Click:Connect(function() mbListening=true; UpdateMBLbl() end)
        _G.__Z0M_MenuBindListening=function() return mbListening end
        _G.__Z0M_MenuBindSet      =function(k) mbListening=false; S.MenuKey=k; UpdateMBLbl() end
        _G.__Z0M_MenuBindCancel   =function()  mbListening=false; UpdateMBLbl() end
    else
        _G.__Z0M_MenuBindListening=function() return false end
        _G.__Z0M_MenuBindSet=function() end; _G.__Z0M_MenuBindCancel=function() end
        MakeDivider(sc,O()); MakeSection(sc,"  ⚡  Mobile Buttons",O())
        local mNote=MakeInfo(sc,C.subtext,O(),36); mNote.Text="  ⚡ (top-right) — tap to show/hide menu\n  TBOT button (bottom-left) — toggle triggerbot\n  Both buttons are draggable."
    end
end

-- ═════════════════════════ TRIGGERBOT TAB ══
do
    local sc=tabScrolls["Triggerbot"]; local o=0; local function O() o+=1; return o end

    local TBStatusLbl=Instance.new("TextLabel",sc)
    TBStatusLbl.Size=UDim2.new(0.9,0,0,isMobile and 38 or 28)
    TBStatusLbl.BackgroundColor3=C.panel; TBStatusLbl.BackgroundTransparency=0
    TBStatusLbl.Font=Enum.Font.GothamBold; TBStatusLbl.TextSize=isMobile and 14 or 12
    TBStatusLbl.TextXAlignment=Enum.TextXAlignment.Center; TBStatusLbl.ZIndex=3; TBStatusLbl.LayoutOrder=O()
    Instance.new("UICorner",TBStatusLbl).CornerRadius=UDim.new(0,8)
    local function RefreshTBStatus()
        TBStatusLbl.Text=tbActive and "⬤  TRIGGERBOT  FIRING" or S.TBEnabled and "○  TRIGGERBOT  ARMED" or "○  TRIGGERBOT  OFF"
        TBStatusLbl.TextColor3=tbActive and C.red or S.TBEnabled and Color3.fromRGB(255,200,60) or C.subtext
        TBStatusLbl.BackgroundColor3=tbActive and Color3.fromRGB(40,6,6) or C.panel
    end
    RefreshTBStatus(); _G.__Z0M_RefreshTBStatus=RefreshTBStatus

    MakeDivider(sc,O()); MakeSection(sc,"  🎯  Triggerbot",O())
    MakeToggle(sc,"Enable Triggerbot",function() return S.TBEnabled end,function(v)
        S.TBEnabled=v; if not v then if tbActive then DeactivateTriggerbot() end; tbToggleOn=false end; RefreshTBStatus()
    end,C.red,O())
    local cn=MakeInfo(sc,C.orange,O(),20); cn.Text="  ⚠ Auto Parry pauses while Triggerbot fires"

    MakeDivider(sc,O()); MakeSection(sc,"  ⚡  Mode",O())
    local ModeRow=Instance.new("Frame",sc); ModeRow.Size=UDim2.new(0.9,0,0,isMobile and 44 or 36); ModeRow.BackgroundColor3=C.panel; ModeRow.BorderSizePixel=0; ModeRow.LayoutOrder=O(); Instance.new("UICorner",ModeRow).CornerRadius=UDim.new(0,8)
    local MLbl=Instance.new("TextLabel",ModeRow); MLbl.Size=UDim2.new(0,50,1,0); MLbl.Position=UDim2.new(0,12,0,0); MLbl.BackgroundTransparency=1; MLbl.Font=Enum.Font.Gotham; MLbl.TextSize=12; MLbl.TextColor3=C.text; MLbl.TextXAlignment=Enum.TextXAlignment.Left; MLbl.Text="Mode"; MLbl.ZIndex=3
    local function PillBtn(label,xOff)
        local b=Instance.new("TextButton",ModeRow); b.Size=UDim2.new(0,66,0,26); b.Position=UDim2.new(1,xOff,0.5,-13); b.Font=Enum.Font.GothamBold; b.TextSize=11; b.Text=label; b.BorderSizePixel=0; b.AutoButtonColor=false; b.ZIndex=4; Instance.new("UICorner",b).CornerRadius=UDim.new(0,6); return b
    end
    local HoldBtn=PillBtn("Hold",-138); local TglBtn=PillBtn("Toggle",-68)
    local function RefreshModeBtns()
        local hold=S.TBMode=="hold"
        HoldBtn.BackgroundColor3=hold and C.accent2 or C.track; HoldBtn.TextColor3=hold and Color3.new(1,1,1) or C.subtext
        TglBtn.BackgroundColor3=not hold and C.accent2 or C.track; TglBtn.TextColor3=not hold and Color3.new(1,1,1) or C.subtext
    end
    RefreshModeBtns()
    local TBHintLbl=MakeInfo(sc,C.subtext,999)
    local function RefreshHint() TBHintLbl.Text=S.TBMode=="hold" and "  Hold key → fires. Release → stops." or "  Press key → fires. Press again → stops." end
    RefreshHint()
    HoldBtn.MouseButton1Click:Connect(function() S.TBMode="hold"; tbToggleOn=false; if tbActive then DeactivateTriggerbot() end; RefreshModeBtns(); RefreshTBStatus(); RefreshHint() end)
    TglBtn.MouseButton1Click:Connect(function() S.TBMode="toggle"; if tbActive then DeactivateTriggerbot() end; tbToggleOn=false; RefreshModeBtns(); RefreshTBStatus(); RefreshHint() end)

    if not isMobile then
        MakeDivider(sc,O()); MakeSection(sc,"  ⌨  Keybind",O())
        local BindRow=Instance.new("Frame",sc); BindRow.Size=UDim2.new(0.9,0,0,38); BindRow.BackgroundColor3=C.panel; BindRow.BorderSizePixel=0; BindRow.LayoutOrder=O(); Instance.new("UICorner",BindRow).CornerRadius=UDim.new(0,8)
        local BLbl=Instance.new("TextLabel",BindRow); BLbl.Size=UDim2.new(0,80,1,0); BLbl.Position=UDim2.new(0,12,0,0); BLbl.BackgroundTransparency=1; BLbl.Font=Enum.Font.Gotham; BLbl.TextSize=12; BLbl.TextColor3=C.text; BLbl.TextXAlignment=Enum.TextXAlignment.Left; BLbl.Text="Keybind"; BLbl.ZIndex=3
        local BindBtn=Instance.new("TextButton",BindRow); BindBtn.Size=UDim2.new(0,84,0,24); BindBtn.Position=UDim2.new(1,-94,0.5,-12); BindBtn.BackgroundColor3=C.track; BindBtn.BorderSizePixel=0; BindBtn.Font=Enum.Font.GothamBold; BindBtn.TextSize=11; BindBtn.TextColor3=C.accent; BindBtn.AutoButtonColor=false; BindBtn.ZIndex=4; Instance.new("UICorner",BindBtn).CornerRadius=UDim.new(0,6)
        local tbListening=false
        local function UpdateBindLbl()
            if tbListening then BindBtn.Text="Press key..."; BindBtn.TextColor3=Color3.fromRGB(255,255,100); BindBtn.BackgroundColor3=Color3.fromRGB(38,34,18)
            else BindBtn.Text=tostring(S.TBKey):gsub("Enum%.KeyCode%.",""); BindBtn.TextColor3=C.accent; BindBtn.BackgroundColor3=C.track end
        end
        UpdateBindLbl(); BindBtn.MouseButton1Click:Connect(function() tbListening=true; UpdateBindLbl() end)
        _G.__Z0M_TBListening  =function() return tbListening end
        _G.__Z0M_TBSetBind    =function(k) tbListening=false; S.TBKey=k; UpdateBindLbl() end
        _G.__Z0M_TBCancelBind =function()  tbListening=false; UpdateBindLbl() end
    else
        -- Mobile: keybind not needed; TBOT floating button handles activation
        _G.__Z0M_TBListening  =function() return false end
        _G.__Z0M_TBSetBind    =function() end
        _G.__Z0M_TBCancelBind =function() end
        MakeDivider(sc,O()); MakeSection(sc,"  📱  Mobile — TBOT Button",O())
        local mbNote=MakeInfo(sc,C.subtext,O(),40)
        mbNote.Text="  The TBOT button (bottom-left of screen) toggles\n  triggerbot on/off with a single tap.\n  Green = firing, Red = off. Drag it anywhere."
    end

    TBHintLbl.LayoutOrder=O()
    MakeDivider(sc,O()); MakeSection(sc,"  ⚡  Speed",O())
    _G.__Z0M_CpsRefresh={}
    local function MakeCPSBlock(parent,label,key,minV,maxV,isExp)
        local NC=Instance.new("Frame",parent); NC.Size=UDim2.new(0.9,0,0,isMobile and 90 or 78); NC.BackgroundColor3=C.panel; NC.BorderSizePixel=0; NC.LayoutOrder=o; o+=1
        Instance.new("UICorner",NC).CornerRadius=UDim.new(0,8)
        if isExp then local s=Instance.new("UIStroke",NC); s.Color=C.orange; s.Thickness=1; s.Transparency=0.5 end
        local TopRow=Instance.new("Frame",NC); TopRow.Size=UDim2.new(1,0,0,36); TopRow.BackgroundTransparency=1
        local Lbl=Instance.new("TextLabel",TopRow); Lbl.Size=UDim2.new(1,-62,1,0); Lbl.Position=UDim2.new(0,12,0,0); Lbl.BackgroundTransparency=1; Lbl.Font=Enum.Font.Gotham; Lbl.TextSize=12; Lbl.TextColor3=C.text; Lbl.TextXAlignment=Enum.TextXAlignment.Left; Lbl.Text=label; Lbl.ZIndex=3
        local Trk=Instance.new("Frame",TopRow); Trk.Size=UDim2.new(0,38,0,22); Trk.Position=UDim2.new(1,-50,0.5,-11); Trk.BorderSizePixel=0; Instance.new("UICorner",Trk).CornerRadius=UDim.new(1,0)
        local KP=Instance.new("Frame",Trk); KP.Size=UDim2.new(0,14,0,14); KP.BorderSizePixel=0; KP.BackgroundColor3=Color3.fromRGB(240,238,228); Instance.new("UICorner",KP).CornerRadius=UDim.new(1,0)
        local kSz=isMobile and 22 or 14
        local ST=Instance.new("Frame",NC); ST.Size=UDim2.new(0.86,0,0,isMobile and 8 or 5); ST.Position=UDim2.new(0.07,0,1,-22); ST.BackgroundColor3=C.track; ST.BorderSizePixel=0; Instance.new("UICorner",ST).CornerRadius=UDim.new(1,0)
        local iR=math.clamp((S[key]-minV)/(maxV-minV),0,1)
        local F=Instance.new("Frame",ST); F.Size=UDim2.new(iR,0,1,0); F.BorderSizePixel=0; Instance.new("UICorner",F).CornerRadius=UDim.new(1,0)
        local SK=Instance.new("TextButton",ST); SK.Size=UDim2.new(0,kSz,0,kSz); SK.Position=UDim2.new(iR,-kSz/2,0.5,-kSz/2); SK.BorderSizePixel=0; SK.Text=""; SK.ZIndex=5; Instance.new("UICorner",SK).CornerRadius=UDim.new(1,0)
        local VL=Instance.new("TextLabel",NC); VL.Size=UDim2.new(1,-10,0,16); VL.Position=UDim2.new(0,12,0,36); VL.BackgroundTransparency=1; VL.Font=Enum.Font.Gotham; VL.TextSize=11; VL.TextXAlignment=Enum.TextXAlignment.Left; VL.ZIndex=3
        local onC=isExp and C.orange or C.green
        local function Refresh()
            local active=isExp==S.TBUseExp
            Trk.BackgroundColor3=active and onC or C.track; KP.Position=active and UDim2.new(1,-17,0.5,-7) or UDim2.new(0,3,0.5,-7)
            F.BackgroundColor3=active and (isExp and Color3.fromRGB(255,150,40) or C.accent) or C.subtext
            SK.BackgroundColor3=active and C.accent or C.subtext
            VL.TextColor3=active and C.text or C.subtext; VL.Text=string.format("%d CPS  (target)",S[key])
        end
        Refresh(); table.insert(_G.__Z0M_CpsRefresh,Refresh)
        local Hit=Instance.new("TextButton",TopRow); Hit.Size=UDim2.new(1,0,1,0); Hit.BackgroundTransparency=1; Hit.Text=""; Hit.ZIndex=5
        Hit.MouseButton1Click:Connect(function() S.TBUseExp=isExp; for _,f in ipairs(_G.__Z0M_CpsRefresh) do f() end end)
        local sliding=false
        SK.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then sliding=true end end)
        Track(UserInputService.InputEnded:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then sliding=false end end))
        Track(UserInputService.InputChanged:Connect(function(i)
            if not sliding then return end
            if i.UserInputType~=Enum.UserInputType.MouseMovement and i.UserInputType~=Enum.UserInputType.Touch then return end
            local w=ST.AbsoluteSize.X; if w==0 then return end
            local r=math.clamp((i.Position.X-ST.AbsolutePosition.X)/w,0,1)
            S[key]=math.floor(minV+(maxV-minV)*r+0.5); F.Size=UDim2.new(r,0,1,0); SK.Position=UDim2.new(r,-kSz/2,0.5,-kSz/2)
            VL.Text=string.format("%d CPS  (target)",S[key])
        end))
    end
    MakeCPSBlock(sc,"Speed  (10 – 150 CPS)","TBCps",10,150,false)
    MakeDivider(sc,O())
    local ExSL=Instance.new("TextLabel",sc); ExSL.Size=UDim2.new(0.9,0,0,14); ExSL.BackgroundTransparency=1; ExSL.Font=Enum.Font.GothamBold; ExSL.TextSize=10; ExSL.TextXAlignment=Enum.TextXAlignment.Left; ExSL.ZIndex=3; ExSL.LayoutOrder=O(); ExSL.Text="  ⚠  EXPERIMENTAL"; ExSL.TextColor3=C.orange
    MakeCPSBlock(sc,"Speed  (10 – 500 CPS)","TBExpCps",10,500,true)
end

-- ════════════════════════════════ FPS TAB ══
do
    local sc=tabScrolls["FPS"]; local o=0; local function O() o+=1; return o end
    local FPSBanner=Instance.new("Frame",sc); FPSBanner.Size=UDim2.new(0.9,0,0,54); FPSBanner.BackgroundColor3=C.panel; FPSBanner.BorderSizePixel=0; FPSBanner.LayoutOrder=O(); Instance.new("UICorner",FPSBanner).CornerRadius=UDim.new(0,8)
    local FPSBannerStroke=Instance.new("UIStroke",FPSBanner); FPSBannerStroke.Color=C.lime; FPSBannerStroke.Thickness=1; FPSBannerStroke.Transparency=0.5
    local FPSNowLbl=Instance.new("TextLabel",FPSBanner); FPSNowLbl.Size=UDim2.new(0.5,0,1,0); FPSNowLbl.Position=UDim2.new(0,14,0,0); FPSNowLbl.BackgroundTransparency=1; FPSNowLbl.Font=Enum.Font.GothamBold; FPSNowLbl.TextSize=26; FPSNowLbl.TextColor3=C.lime; FPSNowLbl.TextXAlignment=Enum.TextXAlignment.Left; FPSNowLbl.ZIndex=3; FPSNowLbl.Text="60"
    local FPSUnitLbl=Instance.new("TextLabel",FPSBanner); FPSUnitLbl.Size=UDim2.new(0.5,-14,0,14); FPSUnitLbl.Position=UDim2.new(0,14,0,34); FPSUnitLbl.BackgroundTransparency=1; FPSUnitLbl.Font=Enum.Font.Gotham; FPSUnitLbl.TextSize=10; FPSUnitLbl.TextColor3=C.subtext; FPSUnitLbl.TextXAlignment=Enum.TextXAlignment.Left; FPSUnitLbl.ZIndex=3; FPSUnitLbl.Text="FPS now"
    local FPSGainLbl=Instance.new("TextLabel",FPSBanner); FPSGainLbl.Size=UDim2.new(0.45,0,1,0); FPSGainLbl.Position=UDim2.new(0.5,0,0,0); FPSGainLbl.BackgroundTransparency=1; FPSGainLbl.Font=Enum.Font.GothamBold; FPSGainLbl.TextSize=14; FPSGainLbl.TextColor3=C.subtext; FPSGainLbl.TextXAlignment=Enum.TextXAlignment.Right; FPSGainLbl.ZIndex=3; FPSGainLbl.Text=""
    MakeDivider(sc,O())
    local BtnRow=Instance.new("Frame",sc); BtnRow.Size=UDim2.new(0.9,0,0,38); BtnRow.BackgroundTransparency=1; BtnRow.BorderSizePixel=0; BtnRow.LayoutOrder=O()
    local NukeBtn=Instance.new("TextButton",BtnRow); NukeBtn.Size=UDim2.new(0.48,0,1,0); NukeBtn.Position=UDim2.new(0,0,0,0); NukeBtn.BackgroundColor3=C.lime; NukeBtn.BorderSizePixel=0; NukeBtn.Font=Enum.Font.GothamBold; NukeBtn.TextSize=11; NukeBtn.TextColor3=Color3.fromRGB(0,0,0); NukeBtn.Text="⚡ Nuke All"; NukeBtn.AutoButtonColor=false; NukeBtn.ZIndex=4; Instance.new("UICorner",NukeBtn).CornerRadius=UDim.new(0,8)
    local RestBtn=Instance.new("TextButton",BtnRow); RestBtn.Size=UDim2.new(0.48,0,1,0); RestBtn.Position=UDim2.new(0.52,0,0,0); RestBtn.BackgroundColor3=Color3.fromRGB(55,44,72); RestBtn.BorderSizePixel=0; RestBtn.Font=Enum.Font.GothamBold; RestBtn.TextSize=11; RestBtn.TextColor3=C.subtext; RestBtn.Text="↺ Restore All"; RestBtn.AutoButtonColor=false; RestBtn.ZIndex=4; Instance.new("UICorner",RestBtn).CornerRadius=UDim.new(0,8)
    NukeBtn.MouseButton1Click:Connect(function() NukeAll(); NukeBtn.Text="✓ Nuked!"; task.delay(1.5,function() NukeBtn.Text="⚡ Nuke All" end) end)
    RestBtn.MouseButton1Click:Connect(function() RestoreAll(); fpsBaseline=0; RestBtn.Text="✓ Restored!"; task.delay(1.5,function() RestBtn.Text="↺ Restore All" end) end)
    local fpsToggleSyncs={}
    local function MakeFPSToggle(label,note,key,color)
        local ord=O()
        local sync=MakeToggle(sc,label,function() return FPS[key] end,function(v) SetFPSFeature(key,v); if v and fpsBaseline==0 then fpsBaseline=rawFPS end; if _G.__Z0M_RefreshFPS then _G.__Z0M_RefreshFPS() end end,color,ord)
        fpsToggleSyncs[key]=sync
        if note then local n=MakeInfo(sc,C.subtext,O(),13); n.Text="  "..note end
    end
    MakeDivider(sc,O()); MakeSection(sc,"  🔆  Lighting",O())
    MakeFPSToggle("Disable Shadows",    "Biggest single FPS win on most PCs.",          "Shadows",     Color3.fromRGB(255,230,60))
    MakeFPSToggle("Disable Post-FX",    "Removes blur, sun rays, depth of field, etc.", "PostFX",      Color3.fromRGB(255,170,40))
    MakeFPSToggle("Disable Fog",        "Clears distance fog for cleaner renders.",      "Fog",         Color3.fromRGB(180,220,255))
    MakeDivider(sc,O()); MakeSection(sc,"  🌿  World",O())
    MakeFPSToggle("Disable Decorations","Removes terrain grass and leaf clutter.",       "Decorations", C.teal)
    MakeFPSToggle("Disable Particles",  "Hides all particles, fire, smoke, trails.",    "Particles",   C.orange)
    MakeFPSToggle("Disable Textures",   "Blanks mesh textures and decals.",             "Textures",    Color3.fromRGB(200,120,255))
    MakeDivider(sc,O()); MakeSection(sc,"  ⚙️  Engine",O())
    MakeFPSToggle("Minimum Quality",    "Forces QualityLevel 1 — most aggressive.",     "Quality",     C.red)
    _G.__Z0M_RefreshFPS=function()
        for key,sync in pairs(fpsToggleSyncs) do sync(FPS[key]) end
        local now=math.floor(smoothFPS); FPSNowLbl.Text=tostring(now)
        local fc=now>=55 and C.lime or now>=35 and Color3.fromRGB(255,210,40) or C.red
        FPSNowLbl.TextColor3=fc; FPSBannerStroke.Color=fc
        if fpsBaseline>0 then local gain=now-math.floor(fpsBaseline); FPSGainLbl.TextColor3=gain>0 and C.lime or C.subtext; FPSGainLbl.Text=gain>0 and string.format("+%d vs baseline",gain) or gain==0 and "no change yet" or string.format("%d vs baseline",gain)
        else FPSGainLbl.Text="no baseline yet"; FPSGainLbl.TextColor3=C.subtext end
    end
    _G.__Z0M_UpdateFPS=function() if not sc.Visible then return end; if _G.__Z0M_RefreshFPS then _G.__Z0M_RefreshFPS() end end
end

-- ═══════════════════════════════ CONFIG TAB ══
do
    local sc=tabScrolls["Config"]; local o=0; local function O() o+=1; return o end
    MakeSection(sc,"  💾  Saved Configs",O()); MakeDivider(sc,O())
    local hl=MakeInfo(sc,C.subtext,O(),15); hl.Text="  SAVE → write   LOAD → click name   DEL → clear"
    MakeDivider(sc,O())
    local sNBtns={}; local sLbls={}
    local function RefSlot(i)
        local cfg=configs[i]; local btn=sNBtns[i]; local lbl=sLbls[i]; if not btn then return end
        if cfg and cfg.data then btn.Text=cfg.name or("Config "..i); btn.TextColor3=C.accent; btn.BackgroundColor3=C.tabSel; if lbl then lbl.Text="  ✓ Saved"; lbl.TextColor3=C.green end
        else btn.Text="Slot "..i.."  (empty)"; btn.TextColor3=C.subtext; btn.BackgroundColor3=C.panel; if lbl then lbl.Text="  Empty slot"; lbl.TextColor3=C.subtext end end
    end
    for i=1,CONFIG_SLOTS do
        local SR=Instance.new("Frame",sc); SR.Size=UDim2.new(0.9,0,0,54); SR.BackgroundColor3=C.panel; SR.BorderSizePixel=0; SR.LayoutOrder=O(); Instance.new("UICorner",SR).CornerRadius=UDim.new(0,8)
        local SB=Instance.new("TextButton",SR); SB.Size=UDim2.new(1,-46,0,30); SB.Position=UDim2.new(0,0,0,0); SB.BackgroundColor3=C.panel; SB.BorderSizePixel=0; SB.Font=Enum.Font.GothamBold; SB.TextSize=11; SB.TextXAlignment=Enum.TextXAlignment.Center; SB.AutoButtonColor=false; SB.ZIndex=4; Instance.new("UICorner",SB).CornerRadius=UDim.new(0,8); sNBtns[i]=SB
        local SL=Instance.new("TextLabel",SR); SL.Size=UDim2.new(0.7,0,0,20); SL.Position=UDim2.new(0,10,0,32); SL.BackgroundTransparency=1; SL.Font=Enum.Font.Gotham; SL.TextSize=10; SL.TextXAlignment=Enum.TextXAlignment.Left; SL.ZIndex=3; sLbls[i]=SL
        local SaveB=Instance.new("TextButton",SR); SaveB.Size=UDim2.new(0,40,0,26); SaveB.Position=UDim2.new(1,-44,0,2); SaveB.BackgroundColor3=Color3.fromRGB(20,70,28); SaveB.BorderSizePixel=0; SaveB.Font=Enum.Font.GothamBold; SaveB.TextSize=10; SaveB.TextColor3=C.green; SaveB.Text="SAVE"; SaveB.AutoButtonColor=false; SaveB.ZIndex=5; Instance.new("UICorner",SaveB).CornerRadius=UDim.new(0,6)
        local DelB=Instance.new("TextButton",SR); DelB.Size=UDim2.new(0,40,0,20); DelB.Position=UDim2.new(1,-44,0,30); DelB.BackgroundColor3=Color3.fromRGB(70,15,15); DelB.BorderSizePixel=0; DelB.Font=Enum.Font.GothamBold; DelB.TextSize=9; DelB.TextColor3=C.red; DelB.Text="DEL"; DelB.AutoButtonColor=false; DelB.ZIndex=5; Instance.new("UICorner",DelB).CornerRadius=UDim.new(0,5)
        RefSlot(i)
        SB.MouseButton1Click:Connect(function()
            local cfg=configs[i]
            if cfg and cfg.data then
                DeserializeIntoS(cfg.data)
                if _G.__Z0M_RefreshStatus   then _G.__Z0M_RefreshStatus()   end
                if _G.__Z0M_RefreshTBStatus then _G.__Z0M_RefreshTBStatus() end
                for _,f in ipairs(_G.__Z0M_CpsRefresh or {}) do f() end
                if LP.Character then ApplyTrail(LP.Character) end; ApplyAllESP()
                if _G.__Z0M_CPSOverlay then _G.__Z0M_CPSOverlay.Visible=S.ShowCPSCounter end
                SL.Text="  ✓ Loaded!"; SL.TextColor3=C.green; task.delay(2,function() RefSlot(i) end)
            else SL.Text="  ✗ Nothing"; SL.TextColor3=C.red; task.delay(1.5,function() RefSlot(i) end) end
        end)
        SaveB.MouseButton1Click:Connect(function()
            if not configs[i] then configs[i]={} end; configs[i].name="Config "..i; configs[i].data=SerializeS(); SaveConfigs(); RefSlot(i)
            SL.Text="  ✓ Saved!"; SL.TextColor3=C.green; task.delay(2,function() RefSlot(i) end)
        end)
        DelB.MouseButton1Click:Connect(function() configs[i]={name="Slot "..i,data=nil}; SaveConfigs(); RefSlot(i) end)
    end
    MakeDivider(sc,O()); MakeSection(sc,"  ⚡  Quick Actions",O())
    local QSB=Instance.new("TextButton",sc); QSB.Size=UDim2.new(0.9,0,0,34); QSB.BackgroundColor3=Color3.fromRGB(14,48,82); QSB.BorderSizePixel=0; QSB.LayoutOrder=O(); QSB.Font=Enum.Font.GothamBold; QSB.TextSize=11; QSB.TextColor3=C.accent; QSB.Text="💾  Quick Save  →  Slot 1"; QSB.AutoButtonColor=false; Instance.new("UICorner",QSB).CornerRadius=UDim.new(0,8)
    QSB.MouseButton1Click:Connect(function()
        configs[1]={name="Config 1",data=SerializeS()}; SaveConfigs()
        for i=1,CONFIG_SLOTS do if sNBtns[i] then RefSlot(i) end end
        QSB.Text="✓  Saved to Slot 1"; task.delay(1.8,function() QSB.Text="💾  Quick Save  →  Slot 1" end)
    end)
end

-- ════════════════════════════ CPS Overlay ══
local CPSOverlay=Instance.new("Frame",ScreenGui)
CPSOverlay.Name="Z0M_CPSOverlay"; CPSOverlay.Size=UDim2.new(0,170,0,58)
CPSOverlay.Position=isMobile and UDim2.new(0.5,-85,0,62) or UDim2.new(0.5,-85,0,14)
CPSOverlay.BackgroundColor3=Color3.fromRGB(6,7,12); CPSOverlay.BackgroundTransparency=0.08; CPSOverlay.BorderSizePixel=0
CPSOverlay.Active=true; CPSOverlay.Visible=S.ShowCPSCounter; CPSOverlay.ZIndex=20
Instance.new("UICorner",CPSOverlay).CornerRadius=UDim.new(0,10)
local _cSt=Instance.new("UIStroke",CPSOverlay); _cSt.Color=C.accent2; _cSt.Thickness=1; _cSt.Transparency=0.3
local _cAccBar=Instance.new("Frame",CPSOverlay); _cAccBar.Size=UDim2.new(0,3,1,0); _cAccBar.BorderSizePixel=0; _cAccBar.ZIndex=21; _cAccBar.BackgroundColor3=C.accent
local CPSTitleLbl=Instance.new("TextLabel",CPSOverlay); CPSTitleLbl.Size=UDim2.new(1,-8,0,14); CPSTitleLbl.Position=UDim2.new(0,8,0,4); CPSTitleLbl.BackgroundTransparency=1; CPSTitleLbl.Font=Enum.Font.GothamBold; CPSTitleLbl.TextSize=9; CPSTitleLbl.TextColor3=C.subtext; CPSTitleLbl.TextXAlignment=Enum.TextXAlignment.Left; CPSTitleLbl.Text="CPS COUNTER"; CPSTitleLbl.ZIndex=21
local CPSValLbl=Instance.new("TextLabel",CPSOverlay); CPSValLbl.Size=UDim2.new(1,-8,0,26); CPSValLbl.Position=UDim2.new(0,8,0,15); CPSValLbl.BackgroundTransparency=1; CPSValLbl.Font=Enum.Font.GothamBold; CPSValLbl.TextSize=21; CPSValLbl.TextColor3=C.accent; CPSValLbl.TextXAlignment=Enum.TextXAlignment.Left; CPSValLbl.Text="0 CPS"; CPSValLbl.ZIndex=21
local CPSFpsLbl=Instance.new("TextLabel",CPSOverlay); CPSFpsLbl.Size=UDim2.new(1,-8,0,12); CPSFpsLbl.Position=UDim2.new(0,8,0,44); CPSFpsLbl.BackgroundTransparency=1; CPSFpsLbl.Font=Enum.Font.Gotham; CPSFpsLbl.TextSize=9; CPSFpsLbl.TextColor3=C.subtext; CPSFpsLbl.TextXAlignment=Enum.TextXAlignment.Left; CPSFpsLbl.Text="FPS: 60  |  Ping: 0ms"; CPSFpsLbl.ZIndex=21
_G.__Z0M_CPSOverlay=CPSOverlay
MakeDraggable(CPSOverlay,CPSOverlay)

-- ════════════════════════════ Input Handler ══
Track(UserInputService.InputBegan:Connect(function(i,gpe)
    if _G.__Z0M_MenuBindListening and _G.__Z0M_MenuBindListening() then
        if i.UserInputType==Enum.UserInputType.Keyboard then
            if i.KeyCode==Enum.KeyCode.Escape then _G.__Z0M_MenuBindCancel() else _G.__Z0M_MenuBindSet(i.KeyCode) end
        end; return
    end
    if _G.__Z0M_TBListening and _G.__Z0M_TBListening() then
        if i.UserInputType==Enum.UserInputType.Keyboard then
            if i.KeyCode==Enum.KeyCode.Escape then _G.__Z0M_TBCancelBind() else _G.__Z0M_TBSetBind(i.KeyCode) end
        end; return
    end
    if gpe then return end
    if not isMobile then
        if S.TBEnabled and i.KeyCode==S.TBKey then
            if S.TBMode=="hold" then ActivateTriggerbot()
            else tbToggleOn=not tbToggleOn; if tbToggleOn then ActivateTriggerbot() else DeactivateTriggerbot() end end
            if _G.__Z0M_RefreshTBStatus then _G.__Z0M_RefreshTBStatus() end
        end
        if i.KeyCode==Enum.KeyCode.F then
            if not tbActive then S.AutoParry=not S.AutoParry; if _G.__Z0M_RefreshStatus then _G.__Z0M_RefreshStatus() end end
        end
        if i.KeyCode==S.MenuKey then if Main then Main.Visible=not Main.Visible end end
    end
end))

Track(UserInputService.InputEnded:Connect(function(i)
    if not isMobile and S.TBEnabled and S.TBMode=="hold" and i.KeyCode==S.TBKey then
        DeactivateTriggerbot(); if _G.__Z0M_RefreshTBStatus then _G.__Z0M_RefreshTBStatus() end
    end
end))

SwitchTab("Main")

-- Minimize / Close
local minimized=false
MinBtn.MouseButton1Click:Connect(function()
    if isMobile then
        Main.Visible=false
        TweenService:Create(ToggleBtn,TweenInfo.new(0.12),{BackgroundColor3=Color3.fromRGB(10,11,20)}):Play()
        return
    end
    minimized=not minimized
    TweenService:Create(Main,TweenInfo.new(0.2,Enum.EasingStyle.Quart),{Size=minimized and UDim2.new(0,W,0,H_MIN) or UDim2.new(0,W,0,H_FULL)}):Play()
    MinBtn.Text=minimized and "+" or "─"
end)
CloseBtn.MouseButton1Click:Connect(function()
    TweenService:Create(Main,TweenInfo.new(0.2,Enum.EasingStyle.Back,Enum.EasingDirection.In),{Size=UDim2.new(0,0,0,0)}):Play()
    task.delay(0.25,function() ScreenGui:Destroy() end)
end)
for _,btn in ipairs({MinBtn,CloseBtn}) do
    local orig=btn.BackgroundColor3
    btn.MouseEnter:Connect(function() TweenService:Create(btn,TweenInfo.new(0.1),{BackgroundColor3=btn==CloseBtn and Color3.fromRGB(210,50,50) or Color3.fromRGB(40,38,62)}):Play() end)
    btn.MouseLeave:Connect(function() TweenService:Create(btn,TweenInfo.new(0.1),{BackgroundColor3=orig}):Play() end)
end

-- ════════════════════════════ Live GUI Update ══
local guiTick=0
Track(RunService.Heartbeat:Connect(function(dt)
    guiTick+=dt; if guiTick<0.05 then return end; guiTick=0
    if _G.__Z0M_UpdateMain  then _G.__Z0M_UpdateMain()  end
    if _G.__Z0M_UpdateCurve then _G.__Z0M_UpdateCurve() end
    if _G.__Z0M_UpdateFPS   then _G.__Z0M_UpdateFPS()   end
    if S.ShowCPSCounter and CPSOverlay.Visible then
        local tCps=S.TBUseExp and S.TBExpCps or S.TBCps
        if tbActive then CPSValLbl.Text=string.format("%d / %d CPS",cpsActual,tCps); CPSValLbl.TextColor3=C.red; CPSTitleLbl.Text="CPS  (FIRING)"
        else CPSValLbl.Text=string.format("%d CPS",tCps); CPSValLbl.TextColor3=C.accent; CPSTitleLbl.Text="CPS COUNTER" end
        local fc=smoothFPS>=55 and C.green or smoothFPS>=35 and Color3.fromRGB(255,210,40) or C.red
        CPSFpsLbl.TextColor3=fc; CPSFpsLbl.Text=string.format("FPS: %.0f  |  Ping: %.0fms",smoothFPS,displayPing)
    end
end))

print(string.format("[z0mware v1.0] loaded  mobile=%s  ball=%s  players=%d",
    tostring(isMobile), currentBall and currentBall.Name or "waiting", #Players:GetPlayers()))
