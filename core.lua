-- PROTOTYPE | CamLock + Silent Aim + AutoPred + DynFOV + Whitelist
-- UI v3 - Top tabs, left name, flat dark style
-- CAMLOCK v3: true FPS-independent, works at 1~10000 FPS

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local lp = Players.LocalPlayer
local cam = workspace.CurrentCamera
local gui = lp:WaitForChild("PlayerGui")

local isAiming = false
local target = nil
local pinnedTarget = nil  -- manually selected target (overrides all auto-targeting)
local char = lp.Character or lp.CharacterAdded:Wait()
local camLockEnabled = false
local silentUseDynFOV = false
local oldPositions = {}
local silentFovSize = 150
local silentFovVisible = false

-- ===== WHITELIST =====
local Whitelist = {}

local function isWhitelisted(player)
    return Whitelist[player.UserId] == true
end

-- ===== BLACKLIST =====
-- Blacklist tiene prioridad sobre Whitelist.
-- Si Blacklist tiene jugadores, las features SOLO funcionan en ellos.
-- Si esta vacia, se comporta normal (whitelist aplica).
local Blacklist = {}

local function isBlacklisted(player)
    return Blacklist[player.UserId] == true
end

local function blacklistActive()
    for _ in pairs(Blacklist) do return true end
    return false
end

local DynamicFOV = {
    enabled = false,
    zones = {
        close  = { maxDist = 30,  fovSize = 350 },
        medium = { maxDist = 80,  fovSize = 200 },
        far    = { maxDist = 150, fovSize = 100 },
        sniper = { maxDist = 999, fovSize = 40  },
    },
    smoothTransition = true,
    transitionSpeed  = 0.18,  -- decay multiplier: 0.01=lento, 1.0=instantáneo
    currentFOV       = 150,
    targetFOV        = 150,
    showZoneLabel    = false,
}
local zoneColors = {
    CLOSE  = Color3.fromRGB(255, 80,  80),
    MEDIUM = Color3.fromRGB(255, 165, 0),
    FAR    = Color3.fromRGB(80,  200, 255),
    SNIPER = Color3.fromRGB(150, 80,  255),
}

local settings = {
    key         = Enum.KeyCode.E,
    toggle      = false,
    range       = 300,
    smooth      = 0.1,
    fovSize     = 150,
    fovVisible  = false,
    use2DFOV    = false,
    stickyAim   = false,
    predictionX = 0,
    predictionY = 0,
    predictionZ = 0,
    knockCheck  = false,
    teamCheck   = false,   -- skip teammates
    crewCheck   = false,   -- skip crew members
    wallCheck   = false,   -- pause lock when target behind wall
    -- Shake: random camera jitter when locked on target
    shakeEnabled = false,
    shakeX       = 0.003,  -- horizontal shake magnitude
    shakeY       = 0.003,  -- vertical shake magnitude
}

-- GunProfiles: per-gun FOV, prediction, smoothness overrides
local GunProfiles = {
    enabled = false,
    -- Gun name → { fovSize, predictionX, predictionY, predictionZ, smooth }
    -- All values are nil = use global setting
    profiles = {
        ["[Double-Barrel SG]"]    = { fovSize=120, predictionX=0.12, predictionY=0, predictionZ=0.12, smooth=0.25 },
        ["[Revolver]"]            = { fovSize=100, predictionX=0.10, predictionY=0, predictionZ=0.10, smooth=0.18 },
        ["[TacticalShotgun]"]     = { fovSize=110, predictionX=0.11, predictionY=0, predictionZ=0.11, smooth=0.22 },
        ["[Shotgun]"]             = { fovSize=130, predictionX=0.12, predictionY=0, predictionZ=0.12, smooth=0.28 },
        ["[Rifle]"]               = { fovSize=80,  predictionX=0.13, predictionY=0, predictionZ=0.13, smooth=0.14 },
        ["[Smg]"]                 = { fovSize=90,  predictionX=0.11, predictionY=0, predictionZ=0.11, smooth=0.16 },
        ["[AK-47]"]               = { fovSize=85,  predictionX=0.13, predictionY=0, predictionZ=0.13, smooth=0.15 },
        ["[AR]"]                  = { fovSize=85,  predictionX=0.13, predictionY=0, predictionZ=0.13, smooth=0.15 },
        ["[Silencer]"]            = { fovSize=90,  predictionX=0.10, predictionY=0, predictionZ=0.10, smooth=0.14 },
        ["[Pistol]"]              = { fovSize=110, predictionX=0.09, predictionY=0, predictionZ=0.09, smooth=0.20 },
    },
    _active = nil,  -- current profile name
}

-- Apply active gun profile values (called each frame when tool changes)
-- Supports both simple profiles AND full GunFov (Default/AirShot/Range) system
local function applyGunProfile(toolName)
    if not GunProfiles.enabled then GunProfiles._active = nil; return end
    GunProfiles._active = toolName

    -- Full GunFov system (loaded from config table)
    if GunProfiles._useGunFov and GunProfiles._gfCFG and GunProfiles._gunMap then
        local gf  = GunProfiles._gfCFG
        local gun = GunProfiles._gunMap[toolName]
        if not gun then return end

        -- Determine distance to nearest target for range selection
        local myHRP = char and char:FindFirstChild("HumanoidRootPart")
        local dist  = math.huge
        if myHRP then
            for _, e in pairs(getAllEnemyChars and getAllEnemyChars() or {}) do
                if e.hrp then
                    local d = (myHRP.Position - e.hrp.Position).Magnitude
                    if d < dist then dist = d end
                end
            end
        end

        -- Check if any target is in the air (airshot)
        local inAir = false
        if myHRP then
            for _, e in pairs(getAllEnemyChars and getAllEnemyChars() or {}) do
                if e.char then
                    local hum = e.char:FindFirstChildOfClass("Humanoid")
                    if hum and hum:GetState() == Enum.HumanoidStateType.Freefall then
                        inAir = true; break
                    end
                end
            end
        end

        local prefix = ""
        if gf.Range and dist ~= math.huge then
            if dist <= gf.Close then
                prefix = "Close_"
            elseif dist <= gf.Mid then
                prefix = "Mid_"
            else
                prefix = "Far_"
            end
        elseif gf.AirShot and inAir then
            prefix = "AirShot_"
        end
        -- fallback to Default if Range/AirShot disabled
        if prefix == "" and not gf.Default then return end

        local fov  = gun[prefix.."Fov"]
        local pred = gun[prefix.."Prediction"]
        local hc   = gun[prefix.."HitChance"]
        local sm   = gun[prefix.."Smoothness"]

        if gf.Fov        and fov  then settings.fovSize    = fov  end
        if gf.Prediction and pred then
            settings.predictionX = pred
            settings.predictionY = 0
            settings.predictionZ = pred
        end
        if gf.HitChance  and hc   then SilentAimV2.hitChance = hc end
        if gf.Smoothness and sm   then settings.smooth = sm        end
        return
    end

    -- Simple profiles fallback
    local p = GunProfiles.profiles[toolName]
    if p then
        if p.fovSize     then settings.fovSize    = p.fovSize     end
        if p.predictionX then settings.predictionX = p.predictionX end
        if p.predictionY then settings.predictionY = p.predictionY end
        if p.predictionZ then settings.predictionZ = p.predictionZ end
        if p.smooth      then settings.smooth      = p.smooth      end
    end
end

local DBSniper        = { enabled = false, intensity = 0 }
local TacticalSniper  = { enabled = false, intensity = 0 }
local SpeedHack = { enabled = false, speed = 16, key = nil }

local dbCachedPos  = nil
local dbLastCache  = 0
local isDBEquipped       = false
local isTacticalEquipped = false

-- ================================================================
-- CAMLOCK CORE — FPS Independent
-- Formula: lerp(a, b, 1 - exp(-k * dt))
-- This equals the same result at ANY framerate by definition.
-- At 1000 FPS: dt ≈ 0.001, many tiny steps = same as 60 FPS one step.
-- ================================================================

-- Smooth slider [0.01 .. 1] → decay rate
-- Curve designed so:
--   s=0.01 → barely noticeable assist (~0.5% pull/frame @60fps)
--   s=0.5  → moderate (~8% pull/frame @60fps)
--   s=1.0  → hard lock (~74% pull/frame @60fps)
local function sliderToDecay(s)
    -- exponential ramp: 0.01→0.3, 0.5→5, 1.0→80
    return math.exp(s * math.log(288))
end

-- Exponential decay lerp — the correct FPS-independent smooth
-- Replaces:  val + (target - val) * smooth * 60 * dt   (WRONG, FPS-dependent)
-- With:      val + (target - val) * (1 - exp(-decay * dt))  (CORRECT)
local function eDamp(a, b, decay, dt)
    local t = 1 - math.exp(-decay * dt)
    return a + (b - a) * t
end

local function eDampV3(a, b, decay, dt)
    local t = 1 - math.exp(-decay * dt)
    return a:Lerp(b, t)
end

-- ================================================================
-- VELOCITY TRACKER — FPS independent EMA
-- ================================================================
local _velData = {}  -- [id] = {pos, t, vel}

local function getVelocity(id, pos, dt)
    local now = tick()
    local d = _velData[id]
    if not d then
        _velData[id] = { pos = pos, t = now, vel = Vector3.zero }
        return Vector3.zero
    end
    -- dt from RenderStepped is preferred; fallback to wall clock
    local elapsed = (dt and dt > 0.0001) and dt or math.max(now - d.t, 0.0001)
    local raw = (pos - d.pos) / elapsed
    -- EMA: decay=10 → settles in ~0.3s. Clamp elapsed to avoid teleport spikes.
    local alpha = 1 - math.exp(-10 * math.min(elapsed, 0.1))
    d.vel = d.vel + (raw - d.vel) * alpha
    d.pos = pos
    d.t   = now
    return d.vel
end

RunService.Heartbeat:Connect(function()
    local now = tick()
    for id, d in pairs(_velData) do
        if now - d.t > 5 then _velData[id] = nil end
    end
end)

-- ================================================================
-- EASING ENGINE — pure functions, all styles, any FPS
-- ================================================================
local _pi = math.pi

-- Each function: t ∈ [0,1] → [0,1]
-- amp/freq are optional (only Elastic/Back use them)
local EasFns = {
    -- ── LINEAR ────────────────────────────────────────────────────
    ["Linear"]               = function(t,_,_) return t end,

    -- ── SINE ──────────────────────────────────────────────────────
    ["Sine In"]              = function(t,_,_) return 1 - math.cos(t * _pi * 0.5) end,
    ["Sine Out"]             = function(t,_,_) return math.sin(t * _pi * 0.5) end,
    ["Sine InOut"]           = function(t,_,_) return -(math.cos(_pi * t) - 1) / 2 end,

    -- ── QUAD ──────────────────────────────────────────────────────
    ["Quad In"]              = function(t,_,_) return t*t end,
    ["Quad Out"]             = function(t,_,_) return 1-(1-t)*(1-t) end,
    ["Quad InOut"]           = function(t,_,_)
        if t < 0.5 then return 2*t*t else return 1-(-2*t+2)^2/2 end
    end,

    -- ── CUBIC ─────────────────────────────────────────────────────
    ["Cubic In"]             = function(t,_,_) return t*t*t end,
    ["Cubic Out"]            = function(t,_,_) return 1-(1-t)^3 end,
    ["Cubic InOut"]          = function(t,_,_)
        if t < 0.5 then return 4*t*t*t else return 1-(-2*t+2)^3/2 end
    end,

    -- ── QUART ─────────────────────────────────────────────────────
    ["Quart In"]             = function(t,_,_) return t^4 end,
    ["Quart Out"]            = function(t,_,_) return 1-(1-t)^4 end,
    ["Quart InOut"]          = function(t,_,_)
        if t < 0.5 then return 8*t^4 else return 1-(-2*t+2)^4/2 end
    end,

    -- ── QUINT ─────────────────────────────────────────────────────
    ["Quint In"]             = function(t,_,_) return t^5 end,
    ["Quint Out"]            = function(t,_,_) return 1-(1-t)^5 end,
    ["Quint InOut"]          = function(t,_,_)
        if t < 0.5 then return 16*t^5 else return 1-(-2*t+2)^5/2 end
    end,

    -- ── EXPONENTIAL ───────────────────────────────────────────────
    ["Exponential In"]       = function(t,_,_) return t==0 and 0 or 2^(10*t-10) end,
    ["Exponential Out"]      = function(t,_,_) return t==1 and 1 or 1-2^(-10*t) end,
    ["Exponential InOut"]    = function(t,_,_)
        if t==0 then return 0 elseif t==1 then return 1
        elseif t<0.5 then return 2^(20*t-10)/2
        else return (2-2^(-20*t+10))/2 end
    end,

    -- ── CIRCULAR ──────────────────────────────────────────────────
    ["Circular In"]          = function(t,_,_) return 1-math.sqrt(1-t^2) end,
    ["Circular Out"]         = function(t,_,_) return math.sqrt(1-(t-1)^2) end,
    ["Circular InOut"]       = function(t,_,_)
        if t < 0.5 then return (1-math.sqrt(1-(2*t)^2))/2
        else return (math.sqrt(1-(-2*t+2)^2)+1)/2 end
    end,

    -- ── BACK ──────────────────────────────────────────────────────
    ["Back In"]              = function(t, amp, _)
        local c = (amp or 1) * 1.70158
        return (c+1)*t^3 - c*t^2
    end,
    ["Back Out"]             = function(t, amp, _)
        local c = (amp or 1) * 1.70158
        return 1+(c+1)*(t-1)^3+c*(t-1)^2
    end,
    ["Back InOut"]           = function(t, amp, _)
        local c = (amp or 1) * 1.70158 * 1.525
        if t < 0.5 then return ((2*t)^2*((c+1)*2*t-c))/2
        else return ((2*t-2)^2*((c+1)*(2*t-2)+c)+2)/2 end
    end,

    -- ── ELASTIC ───────────────────────────────────────────────────
    ["Elastic In"]           = function(t, amp, freq)
        if t==0 then return 0 elseif t==1 then return 1 end
        amp = amp or 1; freq = freq or 1
        local c4 = (2*_pi)/(freq*0.3)
        return -(amp*2^(10*t-10)*math.sin((t*10-10.75)*c4))
    end,
    ["Elastic Out"]          = function(t, amp, freq)
        if t==0 then return 0 elseif t==1 then return 1 end
        amp = amp or 1; freq = freq or 1
        local c4 = (2*_pi)/(freq*0.3)
        return amp*2^(-10*t)*math.sin((t*10-0.75)*c4)+1
    end,
    ["Elastic InOut"]        = function(t, amp, freq)
        if t==0 then return 0 elseif t==1 then return 1 end
        amp = amp or 1; freq = freq or 1
        local c5 = (2*_pi)/(freq*0.45)
        if t < 0.5 then
            return -(amp*2^(20*t-10)*math.sin((20*t-11.125)*c5))/2
        else
            return  (amp*2^(-20*t+10)*math.sin((20*t-11.125)*c5))/2+1
        end
    end,

    -- ── BOUNCE ────────────────────────────────────────────────────
    ["Bounce Out"]           = function(t,_,_)
        if t < 1/2.75    then return 7.5625*t*t
        elseif t < 2/2.75   then t=t-1.5/2.75;   return 7.5625*t*t+0.75
        elseif t < 2.5/2.75 then t=t-2.25/2.75;  return 7.5625*t*t+0.9375
        else t=t-2.625/2.75; return 7.5625*t*t+0.984375 end
    end,
    ["Bounce In"]            = function(t,_,_)
        -- BounceIn = 1 - BounceOut(1-t)
        t = 1-t
        if t < 1/2.75    then return 1-(7.5625*t*t)
        elseif t < 2/2.75   then t=t-1.5/2.75;   return 1-(7.5625*t*t+0.75)
        elseif t < 2.5/2.75 then t=t-2.25/2.75;  return 1-(7.5625*t*t+0.9375)
        else t=t-2.625/2.75; return 1-(7.5625*t*t+0.984375) end
    end,
    ["Bounce InOut"]         = function(t,_,_)
        local function bo(x)
            if x < 1/2.75    then return 7.5625*x*x
            elseif x < 2/2.75   then x=x-1.5/2.75;  return 7.5625*x*x+0.75
            elseif x < 2.5/2.75 then x=x-2.25/2.75; return 7.5625*x*x+0.9375
            else x=x-2.625/2.75; return 7.5625*x*x+0.984375 end
        end
        if t < 0.5 then return (1-bo(1-2*t))/2
        else return (1+bo(2*t-1))/2 end
    end,
}

local function evalEasing(name, t, amp, freq)
    local fn = EasFns[name] or EasFns["Linear"]
    return math.clamp(fn(math.clamp(t,0,1), amp, freq), 0, 1)
end

-- EasingSettings: global + per-category overrides
local EasingSettings = {
    enabled          = false,
    style            = "Linear",
    duration         = 0.15,
    -- Back: controls overshoot amount
    backAmplitude    = 1.0,
    -- Elastic: controls oscillation amplitude and frequency
    elasticAmplitude = 1.0,
    elasticFrequency = 1.0,
}

-- Helper: returns (amp, freq) for the current style
local function getEasingParams()
    local s = EasingSettings.style
    if s:find("Back") then
        return EasingSettings.backAmplitude, nil
    elseif s:find("Elastic") then
        return EasingSettings.elasticAmplitude, EasingSettings.elasticFrequency
    end
    return nil, nil
end

-- Camlock target part setting
-- Options: "Head", "UpperTorso", "LowerTorso", "HumanoidRootPart", "Torso"
local camlockAimPart = "Head"

-- ================================================================
-- AIM STATE — persists between frames
-- ================================================================
-- Smooth mode: stores current smoothed look direction
local _aimDir = nil  -- Vector3 unit

-- Easing mode: stores tween state
local _easStartDir  = nil   -- Vector3 unit (where tween started)
local _easElapsed   = 0     -- seconds into current tween
local _easLastTP    = nil   -- last target world position (for jump detection)
local _easJumpDist  = 5     -- studs; if target jumps more than this, restart tween

-- Call when aim begins, ends, or target lost — prevents direction snap
local function resetAimState()
    _aimDir       = nil
    _easStartDir  = nil
    _easElapsed   = 0
    _easLastTP    = nil
end

-- ================================================================
-- MAIN aimAt — called every RenderStepped with real dt
-- ================================================================


local function aimAt(targetChar, dt)
    if not targetChar then return end

    -- Wall check: if enabled, pause camera movement when target behind wall
    local targetHRP = targetChar:FindFirstChild("HumanoidRootPart")
    if settings.wallCheck and targetHRP and not isVisible(targetHRP) then
        return  -- pause, do NOT clear target — resumes when wall removed
    end

    -- Pick aim bone from selected part, fallback chain
    local bone = targetChar:FindFirstChild(camlockAimPart)
    if not bone then
        -- fallback priority: Head → UpperTorso → HumanoidRootPart
        bone = targetChar:FindFirstChild("Head")
            or targetChar:FindFirstChild("UpperTorso")
            or targetChar:FindFirstChild("HumanoidRootPart")
    end
    if not bone then return end

    -- ── Prediction ──────────────────────────────────────────────
    local tp = bone.Position

 local predX = settings.predictionX
local predY = settings.predictionY
local predZ = settings.predictionZ

    if predX ~= 0 or predY ~= 0 or predZ ~= 0 then
        local id  = tostring(targetChar)
        local vel = getVelocity(id, tp, dt)
        local ping = 0.06
        local ok, raw = pcall(function()
            return game:GetService("Stats").Network.ServerStatsItem["Data Ping"]:GetValue()
        end)
        if ok and raw > 0 then ping = raw / 1000 end
        tp = tp + Vector3.new(
            vel.X * ping * predX * 10,
            vel.Y * ping * predY * 10,
            vel.Z * ping * predZ * 10
        )
    end

    -- ── Target direction ────────────────────────────────────────
    local camPos = cam.CFrame.Position
    local offset = tp - camPos
    if offset.Magnitude < 0.01 then return end
    local targetDir = offset.Unit

    -- ── Sticky Aim: bias toward existing aim direction ───────────
    -- This makes the cam "stick" to a target instead of drifting.
    -- We always aim at the computed targetDir; stickyAim just makes
    -- the smooth decay faster when we already have a locked dir.
    -- (Actual sticky logic is in getBestTarget — this is the motion part)

    -- ── EASING MODE ─────────────────────────────────────────────
    if EasingSettings.enabled then
        -- Detect large target jump (teleport, etc.) → restart tween
        local jumped = _easLastTP ~= nil
            and (_easLastTP - tp).Magnitude > _easJumpDist

        if _easStartDir == nil or jumped then
            -- Start from current camera look, not from scratch
            _easStartDir = cam.CFrame.LookVector
            _easElapsed  = 0
        end
        _easLastTP = tp

        local dur = math.max(EasingSettings.duration, 0.001)
        _easElapsed = _easElapsed + dt

        local t  = _easElapsed / dur
        local amp, freq = getEasingParams()
        local et = evalEasing(
            EasingSettings.style,
            t,
            amp,
            freq
        )

        -- Interpolate from tween-start → live targetDir every frame
        -- This means moving targets are tracked continuously through the tween
        local newDir = _easStartDir:Lerp(targetDir, et)
        if newDir.Magnitude > 0.0001 then
            cam.CFrame = CFrame.new(camPos, camPos + newDir.Unit)
        end

        -- Tween finished → reset start to current camera look
        -- Next frame begins a new tween from wherever we are
        if _easElapsed >= dur then
            _easStartDir = cam.CFrame.LookVector
            _easElapsed  = 0
        end

    -- ── SMOOTH MODE — exp decay, FPS-independent ─────────────────
    else
        -- KEY FIX: read the camera's CURRENT look direction every frame.
        -- This means the player's mouse input is always respected.
        -- At smooth=0.01: tiny alpha → gentle pull, player aims freely.
        -- At smooth=1.0:  large alpha → hard lock, camera snaps to target.
        --
        -- Old (broken) approach was accumulating _aimDir separately,
        -- which overwrote the player's mouse completely even at low smooth.
        local currentDir = cam.CFrame.LookVector

        -- decay: s=0.01→0.3 (barely anything), s=1.0→80 (hard lock)
        local decay = sliderToDecay(settings.smooth)
        local alpha = 1 - math.exp(-decay * dt)

        local newDir = currentDir:Lerp(targetDir, alpha)

        if newDir.Magnitude > 0.0001 then
            local newCF = CFrame.new(camPos, camPos + newDir.Unit)
            -- Shake: apply random angular jitter when enabled
            if settings.shakeEnabled then
                local sx = (math.random() - 0.5) * 2 * settings.shakeX
                local sy = (math.random() - 0.5) * 2 * settings.shakeY
                newCF = newCF * CFrame.Angles(sy, sx, 0)
            end
            cam.CFrame = newCF
        end
    end
end

-- ================================================================
-- UTILITY
-- ================================================================
local function isKnockedOrDead(c)
    if not c then return true end
    local h = c:FindFirstChild("Humanoid")
    if not h or h.Health < 2 then return true end
    if h:GetState() == Enum.HumanoidStateType.Dead then return true end
    local ko   = c:FindFirstChild("K.O")
    if ko   and ko:IsA("BoolValue")   and ko.Value   then return true end
    local dead = c:FindFirstChild("Dead")
    if dead and dead:IsA("BoolValue") and dead.Value then return true end
    return false
end

local function isValidTargetPosition(hrp)
    if not hrp then return false end
    if hrp.Position.Y < -100 then return false end
    return true
end

local function isTargetValid(hrp, character)
    if not hrp or not character then return false end
    if not isValidTargetPosition(hrp) then return false end
    if hrp.Anchored then return false end
    local hum = character:FindFirstChild("Humanoid")
    if not hum or hum.Health <= 0 then return false end
    if isKnockedOrDead(character) then return false end
    return true
end

-- Wall check: raycast from camera to target HRP, returns true if target visible (no wall)
local _wallParams = RaycastParams.new()
_wallParams.FilterType = Enum.RaycastFilterType.Exclude
local function isVisible(targetHRP)
    if not targetHRP then return false end
    local myChar = char
    local exclude = {workspace.Terrain}
    if myChar then table.insert(exclude, myChar) end
    -- also exclude target character so ray doesn't hit their own parts
    if targetHRP.Parent then table.insert(exclude, targetHRP.Parent) end
    _wallParams.FilterDescendantsInstances = exclude
    local origin = cam.CFrame.Position
    local dir    = targetHRP.Position - origin
    local result = workspace:Raycast(origin, dir, _wallParams)
    -- If ray hits nothing = clear line of sight
    -- If ray hits something that is a descendant of target = also clear
    if not result then return true end
    return false
end

-- Team check: returns true if character is on our team
local function isSameTeam(character)
    if not character then return false end
    for _, p in pairs(Players:GetPlayers()) do
        if p ~= lp and p.Character == character then
            return lp.Team ~= nil and p.Team == lp.Team
        end
    end
    return false
end

-- Crew check: Da Hood stores crew in a StringValue "CrewTag" under the player
local function isSameCrew(character)
    if not character then return false end
    local myCrewTag = nil
    local myData = lp:FindFirstChild("leaderstats") or lp:FindFirstChild("PlayerData")
    -- Da Hood uses a "CrewTag" StringValue directly under the player
    local myTag = lp:FindFirstChild("CrewTag")
    if myTag then myCrewTag = myTag.Value end
    if not myCrewTag or myCrewTag == "" then return false end
    for _, p in pairs(Players:GetPlayers()) do
        if p ~= lp and p.Character == character then
            local tag = p:FindFirstChild("CrewTag")
            if tag and tag.Value ~= "" and tag.Value == myCrewTag then
                return true
            end
        end
    end
    return false
end

-- NPC version: skip Anchored check (Da Track moves bots via scripts not physics)
local function isTargetValidNPC(hrp, character)
    if not hrp or not character then return false end
    if not isValidTargetPosition(hrp) then return false end
    local hum = character:FindFirstChild("Humanoid")
    if not hum or hum.Health <= 0 then return false end
    return true
end

local function isCharWhitelisted(character)
    if not character then return false end
    for _, p in pairs(Players:GetPlayers()) do
        if p.Character == character and isWhitelisted(p) then return true end
    end
    return false
end

-- FOV circles
if gui:FindFirstChild("CamLockUI")   then gui.CamLockUI:Destroy()   end
if gui:FindFirstChild("PrototypeUI") then gui.PrototypeUI:Destroy() end

local fovScreen = Instance.new("ScreenGui", gui)
fovScreen.Name = "CamLockUI"
fovScreen.ResetOnSpawn = false
fovScreen.IgnoreGuiInset = true

local fovOuter = Instance.new("Frame", fovScreen)
fovOuter.Size = UDim2.new(0, settings.fovSize, 0, settings.fovSize)
fovOuter.BackgroundTransparency = 1
fovOuter.BorderSizePixel = 0
Instance.new("UICorner", fovOuter).CornerRadius = UDim.new(1, 0)
local uiStroke = Instance.new("UIStroke", fovOuter)
uiStroke.Color = Color3.fromRGB(100, 100, 100)
uiStroke.Thickness = 1.5
uiStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
fovOuter.Visible = false

local silentFovOuter = Instance.new("Frame", fovScreen)
silentFovOuter.Size = UDim2.new(0, silentFovSize, 0, silentFovSize)
silentFovOuter.BackgroundTransparency = 1
silentFovOuter.BorderSizePixel = 0
silentFovOuter.Visible = silentFovVisible
Instance.new("UICorner", silentFovOuter).CornerRadius = UDim.new(1, 0)
local silentFovStroke = Instance.new("UIStroke", silentFovOuter)
silentFovStroke.Color = Color3.fromRGB(180, 0, 0)
silentFovStroke.Thickness = 1.5
silentFovStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border

RunService.RenderStepped:Connect(function()
    local vp = cam.ViewportSize
    -- Camlock FOV stays at screen center
    fovOuter.Position = UDim2.new(0, vp.X/2 - fovOuter.AbsoluteSize.X/2, 0, vp.Y/2 - fovOuter.AbsoluteSize.Y/2)
    -- Silent FOV follows the mouse cursor
    local mp = UserInputService:GetMouseLocation()
    silentFovOuter.Position = UDim2.new(0, mp.X - silentFovOuter.AbsoluteSize.X/2, 0, mp.Y - silentFovOuter.AbsoluteSize.Y/2)
end)

-- ================================================================
-- TRIGGERBOT HITBOX CIRCLE (centered, follows screen center)
-- ================================================================
local tbFovVisible = false
local tbFovOuter = Instance.new("Frame", fovScreen)
tbFovOuter.BackgroundTransparency = 1
tbFovOuter.BorderSizePixel = 0
tbFovOuter.Visible = false
Instance.new("UICorner", tbFovOuter).CornerRadius = UDim.new(1, 0)
local tbFovStroke = Instance.new("UIStroke", tbFovOuter)
tbFovStroke.Color = Color3.fromRGB(255, 200, 0)
tbFovStroke.Thickness = 1.5
tbFovStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border

RunService.RenderStepped:Connect(function()
    if not tbFovVisible then return end
    local r = math.max(TriggerBot.hitboxSize * 60, 8)
    local sz = r * 2
    local vp = cam.ViewportSize
    tbFovOuter.Size = UDim2.new(0, sz, 0, sz)
    tbFovOuter.Position = UDim2.new(0, vp.X/2 - r, 0, vp.Y/2 - r)
    -- color: yellow idle, green when enemy inside
    local active = TriggerBot.enabled and not isSuppressedByTool() and triggerRay and triggerRay()
    tbFovStroke.Color = active and Color3.fromRGB(80, 255, 80) or Color3.fromRGB(255, 200, 0)
end)

-- ================================================================
-- TOAST NOTIFICATION SYSTEM
-- ================================================================
local toastGui = Instance.new("ScreenGui", gui)
toastGui.Name = "ToastUI"; toastGui.ResetOnSpawn = false
toastGui.IgnoreGuiInset = true; toastGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local function _uicorner(p, r)
    local c = Instance.new("UICorner", p); c.CornerRadius = UDim.new(0, r or 3)
end

local TOAST_BLUE    = Color3.fromRGB(58,  100, 200)
local TOAST_GREEN   = Color3.fromRGB(50,  200, 100)
local TOAST_RED     = Color3.fromRGB(220, 50,  50)
local TOAST_YELLOW  = Color3.fromRGB(230, 180, 30)
local TOAST_PURPLE  = Color3.fromRGB(160, 60,  255)

-- Active toasts for stacking
local _activeToasts = {}
local TOAST_W    = 260
local TOAST_H    = 52
local TOAST_GAP  = 6
local TOAST_MARGIN_X = 16
local TOAST_MARGIN_Y = 16

local function _repositionToasts()
    local vp = cam.ViewportSize
    for i, t in ipairs(_activeToasts) do
        local yTarget = vp.Y - TOAST_MARGIN_Y - (i - 1) * (TOAST_H + TOAST_GAP) - TOAST_H
        TweenService:Create(t, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
            {Position = UDim2.new(0, vp.X - TOAST_MARGIN_X - TOAST_W, 0, yTarget)}):Play()
    end
end

-- showToast(title, body, color, icon)
-- For backwards compat, if body is nil then title IS the full message
local function showToast(title, body, color, icon)
    -- backwards compat: old calls pass (msg, color)
    if type(body) == "userdata" or body == nil then
        -- called as showToast(msg, color)
        color = body or color or TOAST_BLUE
        body  = nil
    end
    color = color or TOAST_BLUE
    icon  = icon  or "●"

    local vp = cam.ViewportSize
    local xPos = vp.X - TOAST_MARGIN_X - TOAST_W

    local toast = Instance.new("Frame", toastGui)
    toast.Size            = UDim2.new(0, TOAST_W, 0, TOAST_H)
    toast.BackgroundColor3 = Color3.fromRGB(12, 15, 25)
    toast.BorderSizePixel  = 0
    toast.Position         = UDim2.new(0, xPos, 0, vp.Y + TOAST_H + 10)
    Instance.new("UICorner", toast).CornerRadius = UDim.new(0, 4)

    -- Left accent bar
    local bar = Instance.new("Frame", toast)
    bar.Size             = UDim2.new(0, 3, 1, -8)
    bar.Position         = UDim2.new(0, 0, 0, 4)
    bar.BackgroundColor3 = color
    bar.BorderSizePixel  = 0
    Instance.new("UICorner", bar).CornerRadius = UDim.new(0, 2)

    -- Icon dot
    local iconLbl = Instance.new("TextLabel", toast)
    iconLbl.Size               = UDim2.new(0, 18, 0, 18)
    iconLbl.Position           = UDim2.new(0, 10, 0.5, -9)
    iconLbl.BackgroundTransparency = 1
    iconLbl.Text               = icon
    iconLbl.Font               = Enum.Font.GothamBold
    iconLbl.TextSize           = 14
    iconLbl.TextColor3         = color

    if body then
        -- Title + body layout
        local titleLbl = Instance.new("TextLabel", toast)
        titleLbl.Size              = UDim2.new(1, -36, 0, 18)
        titleLbl.Position          = UDim2.new(0, 32, 0, 8)
        titleLbl.BackgroundTransparency = 1
        titleLbl.Text              = title
        titleLbl.Font              = Enum.Font.GothamBold
        titleLbl.TextSize          = 12
        titleLbl.TextColor3        = Color3.new(1, 1, 1)
        titleLbl.TextXAlignment    = Enum.TextXAlignment.Left
        titleLbl.TextTruncate      = Enum.TextTruncate.AtEnd

        local bodyLbl = Instance.new("TextLabel", toast)
        bodyLbl.Size               = UDim2.new(1, -36, 0, 16)
        bodyLbl.Position           = UDim2.new(0, 32, 0, 28)
        bodyLbl.BackgroundTransparency = 1
        bodyLbl.Text               = body
        bodyLbl.Font               = Enum.Font.Gotham
        bodyLbl.TextSize           = 11
        bodyLbl.TextColor3         = Color3.fromRGB(160, 160, 175)
        bodyLbl.TextXAlignment     = Enum.TextXAlignment.Left
        bodyLbl.TextTruncate       = Enum.TextTruncate.AtEnd
    else
        -- Single line
        local lbl = Instance.new("TextLabel", toast)
        lbl.Size               = UDim2.new(1, -36, 1, 0)
        lbl.Position           = UDim2.new(0, 32, 0, 0)
        lbl.BackgroundTransparency = 1
        lbl.Text               = title
        lbl.Font               = Enum.Font.GothamBold
        lbl.TextSize           = 12
        lbl.TextColor3         = Color3.new(1, 1, 1)
        lbl.TextXAlignment     = Enum.TextXAlignment.Left
        lbl.TextWrapped        = true
    end

    table.insert(_activeToasts, 1, toast)
    _repositionToasts()

    task.delay(2.8, function()
        -- Slide out to right
        local vp2 = cam.ViewportSize
        TweenService:Create(toast, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
            {Position = UDim2.new(0, vp2.X + 10, 0, toast.Position.Y.Offset)}):Play()
        task.delay(0.2, function()
            toast:Destroy()
            for i, t in ipairs(_activeToasts) do
                if t == toast then table.remove(_activeToasts, i); break end
            end
            _repositionToasts()
        end)
    end)
end

-- ================================================================
-- ENEMY DETECTION — Players + NPCs (Da Hood + Da Track support)
-- ================================================================
local NPC_BLACKLIST = {
    ["CA$HIER"]  = true,
    ["Join/Leave"] = true,
    ["BankDoor1"] = true,
    ["Clean the shoes on the floor and come to me for cash"] = true,
    ["Help the patient for money"] = true,
}

-- Cache: rebuilt via signals, not scanned every frame
local _npcCache = {}  -- [model] = {char=model, hrp=part, isNPC=true}

local function isNPCEnemy(model)
    if not model or not model.Parent then return false end
    local hum = model:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return false end
    if not model:FindFirstChild("Head") then return false end
    if NPC_BLACKLIST[model.Name] then return false end
    if model == char then return false end
    for _, p in pairs(Players:GetPlayers()) do
        if p.Character == model then return false end
    end
    -- MAIN FILTER: all decorative items/NPCs in Da Track are Anchored=true
    -- Real enemy bots (Bot_1 etc.) are Anchored=false — use this as the selector
    local root = model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Head")
    if not root or root.Anchored then return false end
    return true
end

local function tryAddToCache(model)
    if isNPCEnemy(model) then
        local hrp = model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Head")
        if hrp then _npcCache[model] = {char=model, hrp=hrp, isNPC=true} end
    end
end

local function rebuildNPCCache()
    -- Scan only workspace.Bots folder — direct and cheap, no full tree walk
    local botsFolder = workspace:FindFirstChild("Bots")
    if botsFolder then
        for _, model in pairs(botsFolder:GetChildren()) do
            if model:IsA("Model") and not _npcCache[model] then
                tryAddToCache(model)
            end
        end
    end
    -- Prune dead entries
    for model in pairs(_npcCache) do
        if not model.Parent then
            _npcCache[model] = nil
        end
    end
end

-- Initial build
rebuildNPCCache()

-- Rescan every 0.5s — catches bot respawns quickly, still cheap vs every-frame scan
task.spawn(function()
    while true do
        task.wait(0.5)
        rebuildNPCCache()
    end
end)

-- Watch Bots folder directly — zero overhead, only fires when a bot spawns/despawns
task.defer(function()
    local botsFolder = workspace:WaitForChild("Bots", 10)
    if not botsFolder then return end
    botsFolder.ChildAdded:Connect(function(model)
        if model:IsA("Model") then
            task.defer(function()
                if model and model.Parent then tryAddToCache(model) end
            end)
        end
    end)
    botsFolder.ChildRemoved:Connect(function(model)
        _npcCache[model] = nil
    end)
end)

-- Returns all valid enemy characters — O(players + cached NPCs), no scan
local function getAllEnemyChars()
    local result = {}
    local blActive = blacklistActive()
    for _, p in pairs(Players:GetPlayers()) do
        if p ~= lp and p.Character then
            -- Si blacklist activa: solo incluir blacklisteados
            -- Si blacklist vacia: excluir whitelisteados
            if blActive then
                if not isBlacklisted(p) then continue end
            else
                if isWhitelisted(p) then continue end
            end
            local c = p.Character
            local hrp = c:FindFirstChild("HumanoidRootPart")
            if hrp then table.insert(result, {char=c, hrp=hrp, isNPC=false}) end
        end
    end
    for model, entry in pairs(_npcCache) do
        if model.Parent and entry.hrp and entry.hrp.Parent then
            local hum = model:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health > 0 then
                table.insert(result, entry)
            end
        else
            _npcCache[model] = nil
        end
    end
    return result
end

-- Shared target indicator for RF + MB
local _weaponTarget = nil
local _weaponTargetPlayer = nil

RunService.Heartbeat:Connect(function()
    local root = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    if not root then _weaponTarget = nil; _weaponTargetPlayer = nil; return end
    local center = Vector2.new(cam.ViewportSize.X/2, cam.ViewportSize.Y/2)
    local best, bestDist = nil, math.huge
    local bestPl = nil
    for _, e in pairs(getAllEnemyChars()) do
        local c, hrp = e.char, e.hrp
        if not hrp then continue end
        if isKnockedOrDead(c) then continue end
        local sp = cam:WorldToViewportPoint(hrp.Position)
        if sp.Z > 0 then
            local sd = (Vector2.new(sp.X, sp.Y) - center).Magnitude
            if sd < bestDist then
                bestDist = sd; best = c; bestPl = nil
                if not e.isNPC then
                    for _, p in pairs(Players:GetPlayers()) do
                        if p.Character == c then bestPl = p; break end
                    end
                end
            end
        end
    end
    _weaponTarget = best
    _weaponTargetPlayer = bestPl
end)

-- ================================================================
-- TARGET SELECTION
-- ================================================================
local function getBestTarget()
    -- Pinned target overrides everything
    if pinnedTarget then
        local hrp = pinnedTarget:FindFirstChild("HumanoidRootPart")
        if hrp and not isKnockedOrDead(pinnedTarget) then
            return pinnedTarget
        end
    end
    local root = char:FindFirstChild("HumanoidRootPart")
    if not root then return nil end
    local best, bestDist = nil, math.huge
    local center = Vector2.new(cam.ViewportSize.X/2, cam.ViewportSize.Y/2)

    -- Sticky aim: keep current target if still valid
    if settings.stickyAim and target then
        local tHRP = target:FindFirstChild("HumanoidRootPart") or target:FindFirstChild("Head")
        local tHum = target:FindFirstChild("Humanoid")
        if tHRP and tHum and tHum.Health > 0
            and not (settings.knockCheck and isKnockedOrDead(target))
            and not isCharWhitelisted(target) then
            if (root.Position - tHRP.Position).Magnitude <= settings.range then
                local _, onS = cam:WorldToViewportPoint(tHRP.Position)
                if onS then return target end
            end
        else
            target = nil
        end
    end

    for _, e in pairs(getAllEnemyChars()) do
        local c, hrp = e.char, e.hrp
        local valid = e.isNPC and isTargetValidNPC(hrp, c) or isTargetValid(hrp, c)
        if not valid then continue end
        if settings.knockCheck and isKnockedOrDead(c) then continue end
        if settings.teamCheck  and isSameTeam(c) then continue end
        if settings.crewCheck  and isSameCrew(c) then continue end
        if (root.Position - hrp.Position).Magnitude <= settings.range then
            -- Wall check: skip if target behind wall (but only for picking new target)
            if settings.wallCheck and not isVisible(hrp) then continue end
            local sp, onS = cam:WorldToViewportPoint(hrp.Position)
            if onS then
                local sd = (Vector2.new(sp.X, sp.Y) - center).Magnitude
                if sd <= settings.fovSize / 2 and sd < bestDist then
                    bestDist = sd; best = c
                end
            end
        end
    end
    return best
end

local function getNearestPart(targetChar)
    local center = Vector2.new(cam.ViewportSize.X/2, cam.ViewportSize.Y/2)
    local nearest, nearestDist = nil, math.huge
    local NEAR_PARTS = {"Head","UpperTorso","LowerTorso","Torso","LeftArm","RightArm","LeftLeg","RightLeg","Left Arm","Right Arm","Left Leg","Right Leg"}
    for _, pname in ipairs(NEAR_PARTS) do
        local p = targetChar:FindFirstChild(pname)
        if p and p:IsA("BasePart") then
            local sp, onS = cam:WorldToViewportPoint(p.Position)
            if onS then
                local d = (Vector2.new(sp.X, sp.Y) - center).Magnitude
                if d < nearestDist then nearestDist = d; nearest = p end
            end
        end
    end
    return nearest or targetChar:FindFirstChild("HumanoidRootPart")
end

local function getDBTargetPos()
    local localRoot = char and char:FindFirstChild("HumanoidRootPart")
    if not localRoot then return nil end
    local best, bestDist = nil, math.huge
    local center = Vector2.new(cam.ViewportSize.X/2, cam.ViewportSize.Y/2)
    for _, e in pairs(getAllEnemyChars()) do
        local c, hrp = e.char, e.hrp
        if hrp and not isKnockedOrDead(c) and (localRoot.Position - hrp.Position).Magnitude <= 120 then
            local sp, onS = cam:WorldToViewportPoint(hrp.Position)
            if onS then
                local sd = (Vector2.new(sp.X, sp.Y) - center).Magnitude
                if sd < bestDist then bestDist = sd; best = c end
            end
        end
    end
    if not best then return nil end
    local np = getNearestPart(best)
    return np and np.Position or nil
end

-- ================================================================
-- FOV UPDATE
-- ================================================================
local function updateFOV()
    if not settings.fovVisible or DynamicFOV.enabled then return end
    if not camLockEnabled then uiStroke.Color = Color3.fromRGB(70,70,70); return end
    uiStroke.Color = (isAiming and target) and Color3.fromRGB(190,0,0)
        or (isAiming and Color3.fromRGB(180,70,0) or Color3.fromRGB(90,90,90))
end

-- ================================================================
-- INPUT
-- ================================================================
local function matchesKey(inp, key)
    if key == nil then return false end
    if type(key) == "string" then
        if key == "MB1" then return inp.UserInputType == Enum.UserInputType.MouseButton1 end
        if key == "MB2" then return inp.UserInputType == Enum.UserInputType.MouseButton2 end
        if key == "MB3" then return inp.UserInputType == Enum.UserInputType.MouseButton3 end

        return false
    end
    return inp.KeyCode == key
end

UserInputService.InputBegan:Connect(function(input, gp)
    if gp then return end
    if matchesKey(input, settings.key) then
        if not camLockEnabled then isAiming = false; target = nil; return end
        if settings.toggle then
            isAiming = not isAiming
            if not isAiming then
                target = nil; resetAimState()
            else
                target = getBestTarget(); resetAimState()
            end
        else
            isAiming = true; target = getBestTarget(); resetAimState()
        end
    end
end)

UserInputService.InputEnded:Connect(function(input, gp)
    if gp then return end
    if matchesKey(input, settings.key) and not settings.toggle then
        isAiming = false; target = nil; resetAimState()
    end
end)

-- ================================================================
-- CAMLOCK LOOP — RenderStepped gives real dt every frame
-- ================================================================
RunService.RenderStepped:Connect(function(dt)
    updateFOV()
    if not camLockEnabled or not isAiming then return end

    -- If pinned target exists, force target = pinned (but only when camlock is already active)
    if pinnedTarget then
        local hrp = pinnedTarget:FindFirstChild("HumanoidRootPart")
        if hrp and not isKnockedOrDead(pinnedTarget) then
            target = pinnedTarget
        else
            pinnedTarget = nil
        end
    end

    if target then
        local root = target:FindFirstChild("HumanoidRootPart")
        local lr   = char:FindFirstChild("HumanoidRootPart")
        if not root or not lr then
            if not pinnedTarget then target = nil end; resetAimState(); return
        end
        -- Only clear target from range check if NOT pinned
        if not pinnedTarget then
            if not isTargetValid(root, target)                         then target = nil; resetAimState(); return end
            if settings.knockCheck and isKnockedOrDead(target)         then target = nil; resetAimState(); return end
            if isCharWhitelisted(target)                               then target = nil; resetAimState(); return end
            if (lr.Position - root.Position).Magnitude > settings.range * 1.5 then target = nil; resetAimState(); return end
        end
        aimAt(target, dt)
    else
        if not pinnedTarget then
            target = getBestTarget()
            if target then resetAimState() end
        end
    end
end)

-- ================================================================
-- SPEEDHACK
-- ================================================================
RunService.RenderStepped:Connect(function()
    if not SpeedHack.enabled then return end
    local hum = char and char:FindFirstChildWhichIsA("Humanoid")
    if hum then hum.WalkSpeed = SpeedHack.speed end
end)

-- Gun Profile: detect equipped tool and apply matching profile
local _lastToolName = nil
RunService.Heartbeat:Connect(function()
    if not GunProfiles.enabled then return end
    local tool = lp.Character and lp.Character:FindFirstChildOfClass("Tool")
    local name = tool and tool.Name or nil
    if name ~= _lastToolName then
        _lastToolName = name
        if name then
            applyGunProfile(name)
        end
    end
end)

UserInputService.InputBegan:Connect(function(inp, gp)
    if gp then return end
    if SpeedHack.key == nil then return end
    if inp.KeyCode ~= SpeedHack.key then return end
    SpeedHack.enabled = not SpeedHack.enabled
    local hum = char and char:FindFirstChildWhichIsA("Humanoid")
    if not SpeedHack.enabled and hum then hum.WalkSpeed = 16 end
end)

lp.CharacterAdded:Connect(function(c)
    char = c; target = nil; isAiming = false; oldPositions = {}
    _velData = {}; resetAimState()
end)

-- ===== FLY =====
local Fly = { enabled = false, speed = 50 }
local flyConn, flyConnNW = nil, nil

local function stopFly()
    if flyConn   then flyConn:Disconnect();   flyConn   = nil end
    if flyConnNW then flyConnNW:Disconnect(); flyConnNW = nil end
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    local hum = char and char:FindFirstChildWhichIsA("Humanoid")
    if hum then hum.PlatformStand = false end
    if hrp then hrp.AssemblyLinearVelocity = Vector3.zero; hrp.AssemblyAngularVelocity = Vector3.zero end
end

local function startFly()
    stopFly()
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    local hum = char and char:FindFirstChildWhichIsA("Humanoid")
    if not hrp or not hum then return end
    pcall(function() hrp:SetNetworkOwner(lp) end)
    hum.PlatformStand = true
    flyConn = RunService.RenderStepped:Connect(function(dt)
        if not Fly.enabled then stopFly(); return end
        local hrp2 = char and char:FindFirstChild("HumanoidRootPart")
        local hum2 = char and char:FindFirstChildWhichIsA("Humanoid")
        if not hrp2 or not hum2 then stopFly(); return end
        hum2.PlatformStand = true
        pcall(function() hrp2:SetNetworkOwner(lp) end)
        local cf = cam.CFrame; local move = Vector3.zero
        if UserInputService:IsKeyDown(Enum.KeyCode.W) then move = move + cf.LookVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then move = move - cf.LookVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then move = move - cf.RightVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then move = move + cf.RightVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.Space) then move = move + Vector3.new(0,1,0) end
        if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.C) then move = move - Vector3.new(0,1,0) end
        if move.Magnitude > 0 then
            hrp2.AssemblyLinearVelocity = move.Unit * Fly.speed
            hrp2.CFrame = CFrame.new(hrp2.CFrame.Position + move.Unit * Fly.speed * dt) * CFrame.Angles(0, math.atan2(-cf.LookVector.X, -cf.LookVector.Z), 0)
        else
            hrp2.AssemblyLinearVelocity = Vector3.zero; hrp2.AssemblyAngularVelocity = Vector3.zero
            hrp2.CFrame = CFrame.new(hrp2.CFrame.Position) * CFrame.Angles(0, math.atan2(-cf.LookVector.X, -cf.LookVector.Z), 0)
        end
    end)
end

lp.CharacterAdded:Connect(function(c) char = c; if Fly.enabled then task.wait(0.5); startFly() end end)

-- ================================================================
-- SILENT AIM v4  — Da Hood (hookmetamethod __index, no __namecall)
-- ================================================================
-- Da Hood gun LocalScripts read:
--   Mouse.Hit    → CFrame   (position the bullet travels toward)
--   Mouse.Target → BasePart (the part that was "hit" for dmg)
-- We intercept those via hookmetamethod(game, "__index").
-- __namecall / workspace:Raycast is NOT touched — that was causing
-- the speed/fly camera-follow bug because Roblox uses workspace
-- raycasts internally for CameraSubject occlusion.
-- ================================================================
local SilentAimV2 = {
    enabled      = false,
    hitChance    = 100,
    checkFOV     = false,
    checkRange   = false,
    checkKnock   = false,
    nearestPart  = false,
    prediction   = 0.112,
    teamCheck    = false,    -- skip teammates
    crewCheck    = false,    -- skip crew members
    wallCheck    = false,    -- skip targets behind walls
    cachedPart   = nil,
    cachedCFrame = nil,
    cachedChar   = nil,
}

-- All body bones, R15 first then R6 fallbacks
local _PARTS = {
    "Head",
    "UpperTorso","LowerTorso","Torso","HumanoidRootPart",
    "RightUpperArm","LeftUpperArm","RightLowerArm","LeftLowerArm",
    "RightHand","LeftHand",
    "RightUpperLeg","LeftUpperLeg","RightLowerLeg","LeftLowerLeg",
    "RightFoot","LeftFoot",
    "Right Arm","Left Arm","Right Leg","Left Leg",
}

-- Returns (part, screenDist) for the visible bone of character c
-- that is closest to the mouse cursor.
local function _bestPart(c)
    local mp = UserInputService:GetMouseLocation()
    local bp, bd = nil, math.huge
    for _, n in ipairs(_PARTS) do
        local p = c:FindFirstChild(n)
        if p and p:IsA("BasePart") then
            local ok, sp = pcall(cam.WorldToViewportPoint, cam, p.Position)
            if ok and sp.Z > 0.5 then
                local d = (Vector2.new(sp.X, sp.Y) - mp).Magnitude
                if d < bd then bd = d; bp = p end
            end
        end
    end
    return bp, bd
end

-- Da Hood KO check: uses BodyEffects["K.O"] BoolValue inside the character
local function _isDaHoodKO(c)
    local be = c:FindFirstChild("BodyEffects")
    if be then
        local ko = be:FindFirstChild("K.O")
        if ko and ko:IsA("BoolValue") and ko.Value then return true end
    end
    -- also check generic knock signals
    return isKnockedOrDead(c)
end

-- ── Target picker ─────────────────────────────────────────────────────────
local function _getSilentTarget()
    -- Pinned target always wins
    if pinnedTarget and pinnedTarget.Parent then
        if not _isDaHoodKO(pinnedTarget) then return pinnedTarget end
    end

    local myHRP = char and char:FindFirstChild("HumanoidRootPart")
    if not myHRP then return nil end

    local fovR  = (silentUseDynFOV and settings.fovSize or silentFovSize) / 2
    local best, bestD = nil, math.huge

    for _, e in pairs(getAllEnemyChars()) do
        local c, hrp = e.char, e.hrp
        if not c or not hrp then continue end

        local valid = e.isNPC and isTargetValidNPC(hrp, c) or isTargetValid(hrp, c)
        if not valid then continue end
        if SilentAimV2.checkKnock and _isDaHoodKO(c)  then continue end
        if SilentAimV2.teamCheck  and isSameTeam(c)    then continue end
        if SilentAimV2.crewCheck  and isSameCrew(c)    then continue end
        if SilentAimV2.checkRange and
           (myHRP.Position - hrp.Position).Magnitude > settings.range then continue end
        -- Wall check: skip if target behind a wall
        if SilentAimV2.wallCheck and not isVisible(hrp) then continue end

        local _, sd = _bestPart(c)
        if sd >= math.huge then continue end
        if SilentAimV2.checkFOV and sd > fovR then continue end
        if sd < bestD then bestD = sd; best = c end
    end
    return best
end

-- ── Per-frame cache update ────────────────────────────────────────────────
RunService.RenderStepped:Connect(function()
    if not SilentAimV2.enabled then
        SilentAimV2.cachedPart   = nil
        SilentAimV2.cachedCFrame = nil
        SilentAimV2.cachedChar   = nil
        return
    end

    local tc = _getSilentTarget()
    if not tc then
        SilentAimV2.cachedPart   = nil
        SilentAimV2.cachedCFrame = nil
        SilentAimV2.cachedChar   = nil
        return
    end

    -- Resolve the aim bone
    local bp
    if SilentAimV2.nearestPart then
        bp = _bestPart(tc)
    else
        bp = tc:FindFirstChild("Head") or tc:FindFirstChild("HumanoidRootPart")
    end
    if not bp then
        SilentAimV2.cachedPart   = nil
        SilentAimV2.cachedCFrame = nil
        SilentAimV2.cachedChar   = nil
        return
    end

    -- Visibility check
    local ok, sp = pcall(cam.WorldToViewportPoint, cam, bp.Position)
    if not ok or sp.Z <= 0.5 then
        SilentAimV2.cachedPart   = nil
        SilentAimV2.cachedCFrame = nil
        SilentAimV2.cachedChar   = nil
        return
    end

    -- Velocity prediction (horizontal only — vertical has little effect in Da Hood)
    local aimPos = bp.Position
    if SilentAimV2.prediction > 0 then
        local vel = Vector3.zero
        local ok2, v = pcall(function() return bp.AssemblyLinearVelocity end)
        if ok2 and v then vel = v end
        local p = SilentAimV2.prediction
        aimPos = aimPos + Vector3.new(vel.X * p, vel.Y * p * 0.05, vel.Z * p)
    end

    SilentAimV2.cachedPart   = bp
    SilentAimV2.cachedCFrame = CFrame.new(aimPos)
    SilentAimV2.cachedChar   = tc
end)

-- ── DB / Tactical ammo tracker + Spread Reduction ────────────────────────
local _rayParams = RaycastParams.new()
_rayParams.FilterType = Enum.RaycastFilterType.Exclude

-- Publicado en _G igual que SilentAimV2 para que el hook lo lea siempre
_G.__PROTO_DB = { enabled = false, cf = nil }
_G.__PROTO_TC = { enabled = false, cf = nil }

RunService.RenderStepped:Connect(function()
    local tool    = lp.Character and lp.Character:FindFirstChildOfClass("Tool")
    local maxAmmo = tool and tool:FindFirstChild("MaxAmmo") and tool.MaxAmmo.Value or 0
    isDBEquipped       = DBSniper.enabled       and (maxAmmo == 2)
    isTacticalEquipped = TacticalSniper.enabled and (maxAmmo == 6)
    dbCachedPos        = nil

    local isDB   = DBSniper.enabled       and (maxAmmo == 2) and DBSniper.intensity   > 0
    local isTact = TacticalSniper.enabled and (maxAmmo == 6) and TacticalSniper.intensity > 0

    _G.__PROTO_DB.enabled = isDB
    _G.__PROTO_TC.enabled = isTact

    if not isDB and not isTact then
        _G.__PROTO_DB.cf = nil
        _G.__PROTO_TC.cf = nil
        return
    end

    local intensity = isDB and DBSniper.intensity or TacticalSniper.intensity

    -- Raycast desde camara para obtener distancia real al punto de impacto
    if lp.Character then
        _rayParams.FilterDescendantsInstances = {lp.Character}
    end
    local origin = cam.CFrame.Position
    local result = workspace:Raycast(origin, cam.CFrame.LookVector * 1000, _rayParams)
    local dist   = result and result.Distance or 500
    local hitPos = origin + cam.CFrame.LookVector * dist

    -- Mouse actual con spread natural
    local mPos   = UserInputService:GetMouseLocation()
    local mray   = cam:ScreenPointToRay(mPos.X, mPos.Y)
    local rawPos = mray.Origin + mray.Direction * dist

    -- Lerp hacia centro segun intensity
    local finalCF = CFrame.new(rawPos:Lerp(hitPos, intensity))

    if isDB   then _G.__PROTO_DB.cf = finalCF end
    if isTact then _G.__PROTO_TC.cf = finalCF end
end)

-- TargetLock state table — full implementation defined after CharacterAdded section
local TargetLock = {
    masterEnabled = false,
    enabled       = false,
    key           = Enum.KeyCode.T,
    lockedChar    = nil,
    cachedPos     = nil,   -- kept for legacy/namecall compat
    cachedPart    = nil,   -- BasePart  → Mouse.Target
    cachedCFrame  = nil,   -- CFrame    → Mouse.Hit
    showLine      = true,
    showOutline   = true,
    showToasts    = true,
}


lp.CharacterAdded:Connect(function(c)
    char = c; target = nil; isAiming = false; oldPositions = {}
    _velData = {}; resetAimState()
    SilentAimV2.cachedPart   = nil
    SilentAimV2.cachedCFrame = nil
    SilentAimV2.cachedChar   = nil
end)

-- ================================================================
-- MOUSE LOCK (Cursor Lock / Sticky Cursor)
-- Da Hood term: "Cursor Lock" or "Mouse Lock"
-- Keeps Mouse.Hit / Mouse.Target glued to the enemy constantly —
-- no camera movement, just the cursor follows the target.
-- Works via the same __index hook as Silent Aim but fires every
-- frame regardless of shooting.
-- Features:
--   • Independent target selection (own FOV, range, knock filter)
--   • Aim bone: Head / Nearest Part / HumanoidRootPart
--   • Smooth cursor interpolation (lerp speed slider)
--   • Frame Skip / Mouse TP mode: skips N frames between updates
--     so the cursor movement looks less robotic / more human
--   • Hit chance (random skip chance per frame)
--   • Velocity prediction lead
--   • Keybind: user-selectable, no default key
-- ================================================================
local MouseLock = {
    enabled      = false,
    key          = nil,       -- no default key — user assigns in UI
    toggle       = false,     -- false = hold, true = toggle mode
    active       = false,     -- runtime state (key held / toggled on)

    -- Target config
    aimPart      = "Head",    -- "Head" | "HumanoidRootPart" | "Nearest"
    checkFOV     = false,
    checkRange   = true,
    checkKnock   = true,
    range        = 500,
    fovSize      = 250,

    -- Smoothness (lerp): 1 = instant snap, 0.01 = very slow glide
    smooth       = 0.35,

    -- Frame Skip / Mouse TP:
    -- Every N rendered frames the cursor jumps to target directly.
    -- Between skips it lerps smoothly for a human-like pattern.
    -- 0 = disabled (always lerp), 1 = every frame (instant TP)
    frameSkip    = 0,
    _skipCounter = 0,

    -- Hit chance: % chance per frame to actually redirect
    hitChance    = 100,

    -- Velocity prediction
    prediction   = 0.08,

    -- Internal cached values
    cachedPart   = nil,
    cachedCFrame = nil,
    cachedChar   = nil,

    -- Smoothed cursor CFrame (for lerp mode)
    _smoothCF    = nil,
}

-- ================================================================
-- METATABLE HOOK — Volt compatible, re-injection safe
--
-- PROBLEM: If the user re-injects the script, the OLD hook closure
-- still lives in the metatable and holds upvalue references to the
-- OLD SilentAimV2 / MouseLock tables (now garbage-collected = nil).
-- This causes "attempt to index nil with 'enabled'" every frame.
--
-- SOLUTION: Store both tables in _G under fixed keys so ANY closure
-- (old or new) always reads the CURRENT live tables.
-- The hook is also idempotent: we detect if our hook is already
-- installed (via a marker key in _G) and skip re-installation,
-- so only one hook ever exists in the metatable at a time.
-- ================================================================

-- Publish tables to _G so old hook closures can still find them
_G.__PROTO_SA  = SilentAimV2   -- silent aim
_G.__PROTO_ML  = MouseLock     -- mouse lock
_G.__PROTO_TL  = TargetLock    -- target lock

local _mt          = getrawmetatable(game)
local _cachedMouse = lp:GetMouse()

-- Only install the hook once per game session
if not _G.__PROTO_HOOK_INSTALLED then
    _G.__PROTO_HOOK_INSTALLED = true

    setreadonly(_mt, false)

    -- Capture the original __index (C closure in Volt)
    local _origIndex = rawget(_mt, "__index")
    -- rawget may return nil in Volt — try a pcall read instead
    if type(_origIndex) ~= "function" then
        setreadonly(_mt, true)
        local ok, v = pcall(function() return _mt.__index end)
        _origIndex = (ok and type(v) == "function") and v or nil
        setreadonly(_mt, false)
    end

    local _inHook = false

    rawset(_mt, "__index", function(self, key)
        if _inHook then
            -- Re-entrancy: call original directly, no game API
            return type(_origIndex) == "function"
                and _origIndex(self, key)
                or nil
        end

        -- Only intercept Mouse.Hit / Mouse.Target
        if rawequal(self, _cachedMouse)
        and (key == "Hit" or key == "Target") then

            -- Read tables from _G — always points to latest injection
            local tl = _G.__PROTO_TL
            local ml = _G.__PROTO_ML
            local sa = _G.__PROTO_SA
            local db = _G.__PROTO_DB
            local tc = _G.__PROTO_TC

            -- Target Lock — absolute priority (explicit locked target)
            if type(tl) == "table"
            and tl.masterEnabled == true
            and tl.enabled       == true
            and tl.cachedPart   ~= nil then
                if key == "Hit"    then return tl.cachedCFrame end
                if key == "Target" then return tl.cachedPart   end
            end

            -- Mouse Lock — second priority
            if type(ml) == "table"
            and ml.enabled == true
            and ml.active  == true
            and ml.cachedPart ~= nil then
                if key == "Hit"    then return ml.cachedCFrame end
                if key == "Target" then return ml.cachedPart   end
            end

            -- Silent Aim — fires on shot with hit-chance roll
            if type(sa) == "table"
            and sa.enabled == true
            and sa.cachedPart ~= nil then
                local roll = sa.hitChance >= 100
                          or math.random(1, 100) <= sa.hitChance
                if roll then
                    if key == "Hit"    then return sa.cachedCFrame end
                    if key == "Target" then return sa.cachedPart   end
                end
            end

            -- DB Sniper spread reduction
            if key == "Hit"
            and type(db) == "table" and db.enabled and db.cf then
                return db.cf
            end

            -- Tactical Sniper spread reduction
            if key == "Hit"
            and type(tc) == "table" and tc.enabled and tc.cf then
                return tc.cf
            end
        end

        -- Fall through
        if type(_origIndex) == "function" then
            _inHook = true
            local ok, r = pcall(_origIndex, self, key)
            _inHook = false
            return ok and r or nil
        end
        return nil
    end)

    setreadonly(_mt, true)
end

-- ── Helpers (reuse _PARTS / _bestPart from Silent Aim) ───────────────────

local function _mlGetTarget()
    if pinnedTarget and pinnedTarget.Parent then
        if not isKnockedOrDead(pinnedTarget) then return pinnedTarget end
    end
    local myHRP = char and char:FindFirstChild("HumanoidRootPart")
    if not myHRP then return nil end

    local fovR  = MouseLock.fovSize / 2
    local best, bestD = nil, math.huge

    for _, e in pairs(getAllEnemyChars()) do
        local c, hrp = e.char, e.hrp
        if not c or not hrp then continue end
        local valid = e.isNPC and isTargetValidNPC(hrp, c) or isTargetValid(hrp, c)
        if not valid then continue end
        if MouseLock.checkKnock  and isKnockedOrDead(c) then continue end
        if MouseLock.checkRange  and
           (myHRP.Position - hrp.Position).Magnitude > MouseLock.range then continue end

        local _, sd = _bestPart(c)
        if sd >= math.huge then continue end
        if MouseLock.checkFOV and sd > fovR then continue end
        if sd < bestD then bestD = sd; best = c end
    end
    return best
end

local function _mlResolvePart(tc)
    if not tc then return nil end
    if MouseLock.aimPart == "Nearest" then
        return _bestPart(tc)
    elseif MouseLock.aimPart == "HumanoidRootPart" then
        return tc:FindFirstChild("HumanoidRootPart")
    else
        return tc:FindFirstChild("Head") or tc:FindFirstChild("HumanoidRootPart")
    end
end

-- ── Per-frame update ──────────────────────────────────────────────────────
RunService.RenderStepped:Connect(function()
    -- Clear if not active
    if not MouseLock.enabled or not MouseLock.active then
        MouseLock.cachedPart   = nil
        MouseLock.cachedCFrame = nil
        MouseLock.cachedChar   = nil
        MouseLock._smoothCF    = nil
        return
    end

    -- Hit chance roll (per frame)
    if MouseLock.hitChance < 100 then
        if math.random(1, 100) > MouseLock.hitChance then return end
    end

    local tc = _mlGetTarget()
    if not tc then
        MouseLock.cachedPart   = nil
        MouseLock.cachedCFrame = nil
        MouseLock.cachedChar   = nil
        MouseLock._smoothCF    = nil
        return
    end

    local bp = _mlResolvePart(tc)
    if not bp then
        MouseLock.cachedPart   = nil
        MouseLock.cachedCFrame = nil
        MouseLock.cachedChar   = nil
        return
    end

    -- Visibility
    local ok, sp = pcall(cam.WorldToViewportPoint, cam, bp.Position)
    if not ok or sp.Z <= 0.5 then
        MouseLock.cachedPart   = nil
        MouseLock.cachedCFrame = nil
        MouseLock.cachedChar   = nil
        return
    end

    -- Velocity prediction
    local aimPos = bp.Position
    if MouseLock.prediction > 0 then
        local vel = Vector3.zero
        local ok2, v = pcall(function() return bp.AssemblyLinearVelocity end)
        if ok2 and v then vel = v end
        local p = MouseLock.prediction
        aimPos = aimPos + Vector3.new(vel.X * p, vel.Y * p * 0.05, vel.Z * p)
    end

    local targetCF = CFrame.new(aimPos)

    -- ── Frame Skip / Mouse TP logic ───────────────────────────────
    local fs = math.floor(MouseLock.frameSkip)
    if fs <= 0 then
        -- Pure lerp: smooth cursor toward target
        if MouseLock._smoothCF == nil then
            MouseLock._smoothCF = targetCF
        else
            local alpha = math.clamp(MouseLock.smooth, 0.01, 1)
            local currPos = MouseLock._smoothCF.Position
            local newPos  = currPos:Lerp(aimPos, alpha)
            MouseLock._smoothCF = CFrame.new(newPos)
        end
        MouseLock.cachedCFrame = MouseLock._smoothCF
    else
        -- Frame skip: every `fs` frames → instant TP (mouse jumps)
        -- between skips → lerp toward last TP position (human-like micro-drift)
        MouseLock._skipCounter = (MouseLock._skipCounter or 0) + 1
        if MouseLock._skipCounter >= fs then
            MouseLock._skipCounter = 0
            MouseLock._smoothCF    = targetCF   -- snap
        else
            -- drift toward target between skips
            if MouseLock._smoothCF == nil then
                MouseLock._smoothCF = targetCF
            else
                local driftAlpha = math.clamp(MouseLock.smooth * 0.5, 0.01, 1)
                local newPos = MouseLock._smoothCF.Position:Lerp(aimPos, driftAlpha)
                MouseLock._smoothCF = CFrame.new(newPos)
            end
        end
        MouseLock.cachedCFrame = MouseLock._smoothCF
    end

    MouseLock.cachedPart  = bp
    MouseLock.cachedChar  = tc
end)

-- ── Keybind handler ───────────────────────────────────────────────────────
UserInputService.InputBegan:Connect(function(inp, gp)
    if gp then return end
    if MouseLock.key and inp.KeyCode == MouseLock.key then
        if MouseLock.toggle then
            MouseLock.active = not MouseLock.active
            if not MouseLock.active then
                MouseLock.cachedPart   = nil
                MouseLock.cachedCFrame = nil
                MouseLock._smoothCF    = nil
            end
        else
            MouseLock.active = true
        end
    end
end)
UserInputService.InputEnded:Connect(function(inp)
    if not MouseLock.toggle and MouseLock.key and inp.KeyCode == MouseLock.key then
        MouseLock.active       = false
        MouseLock.cachedPart   = nil
        MouseLock.cachedCFrame = nil
        MouseLock._smoothCF    = nil
    end
end)



-- ================================================================
-- RAGEBOT — Target Strafe + Auto Kill + Auto Reload
-- Strafe modes: Circle, Figure8, Zigzag, Spiral, Random, Bounce, Pendulum
-- TP instantaneo al seleccionar target
-- ================================================================
local Ragebot = {
    enabled        = false,
    strafeEnabled  = false,
    autoShoot      = false,
    autoReload     = false,
    strafeRadius   = 10,
    strafeSpeed    = 8,       -- rad/s for circular modes
    strafeHeight   = 0,
    strafeMode     = "Circle",
    pinnedTarget   = nil,
    _angle         = 0,
    _time          = 0,
    _lastShot      = 0,
    _shootInterval = 0.05,
    _lastReload    = 0,
    _zigTimer      = 0,
    _spiralT       = 0,
    _randomTimer   = 0,
    _randomTarget  = Vector3.zero,
    _pendDir       = 1,
    _pendAngle     = 0,
    _bounceDir     = nil,
}

local rbConn = nil
local _strafeModList = {"Circle","Figure8","Zigzag","Spiral","Random","Bounce","Pendulum"}

local function stopRageStrafe()
    if rbConn then rbConn:Disconnect(); rbConn = nil end
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    local hum = char and char:FindFirstChildWhichIsA("Humanoid")
    if hum then hum.PlatformStand = false end
    if hrp then
        hrp.AssemblyLinearVelocity  = Vector3.zero
        hrp.AssemblyAngularVelocity = Vector3.zero
    end
end

-- Teleport instantly to orbit position around target
local function tpToTargetOrbit(tHRP)
    local myHRP = char and char:FindFirstChild("HumanoidRootPart")
    if not myHRP or not tHRP then return end
    local r   = Ragebot.strafeRadius
    local ang = Ragebot._angle
    local offset = Vector3.new(math.cos(ang)*r, Ragebot.strafeHeight, math.sin(ang)*r)
    myHRP.CFrame = CFrame.new(tHRP.Position + offset)
end

local function startRageStrafe()
    stopRageStrafe()
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    local hum = char and char:FindFirstChildWhichIsA("Humanoid")
    if not hrp or not hum then return end
    -- Instant TP to orbit position before starting loop
    if Ragebot.pinnedTarget then
        local tHRP = Ragebot.pinnedTarget:FindFirstChild("HumanoidRootPart")
        tpToTargetOrbit(tHRP)
    end
    pcall(function() hrp:SetNetworkOwner(lp) end)
    hum.PlatformStand = true
    Ragebot._time      = 0
    Ragebot._angle     = 0
    Ragebot._zigTimer  = 0
    Ragebot._spiralT   = 0
    Ragebot._randomTimer = 0
    Ragebot._pendAngle = 0
    Ragebot._bounceDir = nil

    rbConn = RunService.RenderStepped:Connect(function(dt)
        if not Ragebot.enabled or not Ragebot.strafeEnabled then
            stopRageStrafe(); return
        end
        local tgt = Ragebot.pinnedTarget
        if not tgt or not tgt.Parent then return end
        local tHRP = tgt:FindFirstChild("HumanoidRootPart")
        if not tHRP then return end
        local tHum = tgt:FindFirstChildWhichIsA("Humanoid")
        if not tHum or tHum.Health <= 0 then return end

        local myHRP = char and char:FindFirstChild("HumanoidRootPart")
        local myHum = char and char:FindFirstChildWhichIsA("Humanoid")
        if not myHRP or not myHum then stopRageStrafe(); return end

        myHum.PlatformStand = true
        pcall(function() myHRP:SetNetworkOwner(lp) end)

        local spd = Ragebot.strafeSpeed
        Ragebot._angle = Ragebot._angle + spd * dt
        Ragebot._time  = Ragebot._time  + dt

        local r      = Ragebot.strafeRadius
        local ang    = Ragebot._angle
        local t      = Ragebot._time
        local center = tHRP.Position + Vector3.new(0, Ragebot.strafeHeight, 0)
        local targetPos
        local mode = Ragebot.strafeMode

        if mode == "Circle" then
            -- Classic circular orbit — fast and tight
            targetPos = center + Vector3.new(math.cos(ang)*r, 0, math.sin(ang)*r)

        elseif mode == "Figure8" then
            -- Lemniscate — sweeps through target's position
            local s = math.sin(ang)
            local c = math.cos(ang)
            local d = 1 + s*s
            targetPos = center + Vector3.new(r*c/d, 0, r*s*c/d)

        elseif mode == "Zigzag" then
            -- Circle + oscillating lateral offset
            Ragebot._zigTimer = Ragebot._zigTimer + dt * spd * 2.5
            local fwd  = (myHRP.Position - tHRP.Position)
            local fwdN = fwd.Magnitude > 0 and fwd.Unit or Vector3.new(1,0,0)
            local side = Vector3.new(-fwdN.Z, 0, fwdN.X)
            local lat  = math.sin(Ragebot._zigTimer) * r * 0.7
            targetPos  = center + fwdN * r + side * lat

        elseif mode == "Spiral" then
            -- Pulsing radius — expands and contracts
            Ragebot._spiralT = Ragebot._spiralT + dt * 1.2
            local sr = r * (0.35 + 0.65 * math.abs(math.sin(Ragebot._spiralT)))
            targetPos = center + Vector3.new(
                math.cos(ang * 1.7) * sr,
                math.sin(t * 1.5)  * 2.5,
                math.sin(ang * 1.7) * sr
            )

        elseif mode == "Random" then
            -- Teleport-snap to random orbit points every ~0.2s
            Ragebot._randomTimer = Ragebot._randomTimer - dt
            if Ragebot._randomTimer <= 0 then
                Ragebot._randomTimer = 0.18 + math.random() * 0.14
                local ra = math.random() * math.pi * 2
                local rr = r * (0.5 + math.random() * 0.8)
                Ragebot._randomTarget = center + Vector3.new(
                    math.cos(ra)*rr, (math.random()-0.5)*3, math.sin(ra)*rr)
            end
            targetPos = Ragebot._randomTarget

        elseif mode == "Bounce" then
            -- Pinball-style bouncing
            if not Ragebot._bounceDir then
                Ragebot._bounceDir = Vector3.new(math.random()-0.5, 0, math.random()-0.5).Unit
            end
            local curOff = (myHRP.Position - tHRP.Position)
            -- Reflect if too far
            if curOff.Magnitude > r * 1.3 then
                local n = -curOff.Unit
                Ragebot._bounceDir = (Ragebot._bounceDir - 2*(Ragebot._bounceDir:Dot(n))*n).Unit
            end
            -- Add random perturbation
            Ragebot._bounceDir = (Ragebot._bounceDir + Vector3.new(
                (math.random()-0.5)*0.3, 0, (math.random()-0.5)*0.3)).Unit
            targetPos = myHRP.Position + Ragebot._bounceDir * spd * 0.55

        elseif mode == "Pendulum" then
            -- Swings back and forth across the target
            Ragebot._pendAngle = Ragebot._pendAngle + dt * spd * Ragebot._pendDir
            local maxAng = math.pi * 0.8
            if Ragebot._pendAngle > maxAng then
                Ragebot._pendAngle = maxAng; Ragebot._pendDir = -1
            elseif Ragebot._pendAngle < -maxAng then
                Ragebot._pendAngle = -maxAng; Ragebot._pendDir = 1
            end
            local fwd  = tHRP.CFrame.RightVector
            targetPos  = center + fwd * (math.sin(Ragebot._pendAngle) * r)
                                 + tHRP.CFrame.LookVector * (math.cos(Ragebot._pendAngle) * r * 0.4)
        else
            targetPos = center + Vector3.new(math.cos(ang)*r, 0, math.sin(ang)*r)
        end

        -- Move to target position — high speed, high responsiveness
        local dir   = targetPos - myHRP.Position
        local dist  = dir.Magnitude
        local moveSpd = math.min(dist * 22, 150)
        if dist > 0.1 then
            myHRP.AssemblyLinearVelocity = dir.Unit * moveSpd
        else
            myHRP.AssemblyLinearVelocity = Vector3.zero
        end
        myHRP.AssemblyAngularVelocity = Vector3.zero

        -- Always look at enemy HEAD (not HRP)
        local tHead = tgt:FindFirstChild("Head") or tHRP
        local lookDir = tHead.Position - cam.CFrame.Position
        if lookDir.Magnitude > 0.01 then
            cam.CFrame = CFrame.new(cam.CFrame.Position, cam.CFrame.Position + lookDir.Unit)
        end

        -- Auto no-clip while strafing (so we don't get stuck in walls)
        local myChar2 = lp.Character
        if myChar2 then
            for _, part in ipairs(myChar2:GetDescendants()) do
                if part:IsA("BasePart") then part.CanCollide = false end
            end
        end

        -- Auto shoot
        if Ragebot.autoShoot then
            local now = tick()
            if now - Ragebot._lastShot >= Ragebot._shootInterval then
                Ragebot._lastShot = now
                pcall(mouse1click)
            end
        end

        -- Auto reload
        if Ragebot.autoReload then
            local tool = lp.Character and lp.Character:FindFirstChildOfClass("Tool")
            if tool then
                local ammo    = tool:FindFirstChild("Ammo")
                local maxAmmo = tool:FindFirstChild("MaxAmmo")
                if ammo and maxAmmo and ammo.Value <= 0 and maxAmmo.Value > 0 then
                    local now = tick()
                    if now - Ragebot._lastReload > 0.8 then
                        Ragebot._lastReload = now
                        pcall(function()
                            keypress(Enum.KeyCode.R.Value)
                            task.delay(0.05, function()
                                pcall(function() keyrelease(Enum.KeyCode.R.Value) end)
                            end)
                        end)
                    end
                end
            end
        end
    end)
end

-- Reiniciar strafe al respawnear
lp.CharacterAdded:Connect(function(c)
    char = c
    if Ragebot.enabled and Ragebot.strafeEnabled and Ragebot.pinnedTarget then
        task.wait(0.5); startRageStrafe()
    end
end)


-- ================================================================
-- NOCLIP
-- ================================================================
local NoClip = { enabled = false }
local ncConn = nil

local function updateNoClip()
    local character = lp.Character
    if not character then return end
    for _, part in ipairs(character:GetDescendants()) do
        if part:IsA("BasePart") then
            part.CanCollide = not NoClip.enabled
        end
    end
end

local function startNoClip()
    if ncConn then ncConn:Disconnect(); ncConn = nil end
    ncConn = RunService.Stepped:Connect(function()
        if not NoClip.enabled then
            if ncConn then ncConn:Disconnect(); ncConn = nil end
            return
        end
        local character = lp.Character
        if not character then return end
        for _, part in ipairs(character:GetDescendants()) do
            if part:IsA("BasePart") then
                part.CanCollide = false
            end
        end
    end)
end

lp.CharacterAdded:Connect(function(c)
    char = c
    if NoClip.enabled then
        task.wait(0.1); startNoClip()
    end
end)

-- ================================================================
-- TARGET LOCK — redirects ALL bullets to a pinned enemy
-- Does NOT touch Silent Aim tab. Uses the same raycast hook.
-- ================================================================

-- Visual: line from crosshair to target
local tlGuiScreen = Instance.new("ScreenGui")
tlGuiScreen.Name = "TargetLockGui"; tlGuiScreen.ResetOnSpawn = false
tlGuiScreen.IgnoreGuiInset = true; tlGuiScreen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
tlGuiScreen.Parent = gui

local tlLine = Instance.new("Frame", tlGuiScreen)
tlLine.BackgroundColor3 = Color3.fromRGB(180, 60, 255)
tlLine.BorderSizePixel = 0; tlLine.AnchorPoint = Vector2.new(0.5, 0.5)
tlLine.Visible = false

-- Visual: highlight on target
local tlHighlight = Instance.new("Highlight")
tlHighlight.FillTransparency = 0.85
tlHighlight.OutlineColor = Color3.fromRGB(180, 60, 255)
tlHighlight.OutlineTransparency = 0
tlHighlight.FillColor = Color3.fromRGB(180, 60, 255)
tlHighlight.Enabled = false
tlHighlight.Parent = workspace

local function tlDrawLine(x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    local len = math.sqrt(dx*dx + dy*dy)
    if len < 1 then tlLine.Visible = false; return end
    tlLine.Size = UDim2.new(0, len, 0, 2)
    tlLine.Position = UDim2.new(0, (x1+x2)/2, 0, (y1+y2)/2)
    tlLine.Rotation = math.deg(math.atan2(dy, dx))
    tlLine.Visible = true
end

local function tlClearVisuals()
    tlLine.Visible = false
    tlHighlight.Enabled = false
    tlHighlight.Adornee = nil
end

local function tlLockOn(character)
    TargetLock.lockedChar = character
    if character then
        if TargetLock.showOutline then
            tlHighlight.Adornee = character
            tlHighlight.Enabled = true
        end
    else
        tlClearVisuals()
    end
end

-- Get nearest enemy to crosshair (cursor position)
-- Uses screen distance for on-screen targets, and for off-screen
-- targets uses angular distance from camera forward — so targets
-- slightly behind the camera edge are still catchable.
local function tlGetBestTarget()
    local mp       = UserInputService:GetMouseLocation()
    local camCF    = cam.CFrame
    local myHRP    = char and char:FindFirstChild("HumanoidRootPart")
    local best, bestScore, bestDisplay = nil, math.huge, nil

    for _, e in pairs(getAllEnemyChars()) do
        local c, hrp = e.char, e.hrp
        if not hrp or not c or not c.Parent then continue end
        if isKnockedOrDead(c) then continue end

        -- Use HRP for picking, Head for scoring accuracy
        local head = c:FindFirstChild("Head") or hrp

        -- Screen distance to cursor — works even if sp.Z <= 0
        -- because WorldToViewportPoint still gives valid X/Y when behind cam
        local sp = cam:WorldToViewportPoint(head.Position)
        local score

        if sp.Z > 0 then
            -- Target is in front of camera — use pixel distance to cursor
            score = (Vector2.new(sp.X, sp.Y) - mp).Magnitude
        else
            -- Target is behind camera — use a large penalty so on-screen
            -- targets are always preferred, but off-screen still reachable
            -- (gives 9999 + angular offset so the closest behind-cam target
            --  wins when nothing is on screen)
            local toTarget = (head.Position - camCF.Position).Unit
            local dot = camCF.LookVector:Dot(toTarget)  -- -1 = directly behind
            score = 9999 + (1 + dot) * 500  -- lower = more behind = worse
        end

        if score < bestScore then
            bestScore = score
            best = c
            bestDisplay = c.Name
            if not e.isNPC then
                for _, p in pairs(Players:GetPlayers()) do
                    if p.Character == c then
                        bestDisplay = p.DisplayName
                        break
                    end
                end
            end
        end
    end
    return best, bestDisplay
end

-- Update cached position + visuals every frame
RunService.RenderStepped:Connect(function()
    if not TargetLock.masterEnabled or not TargetLock.enabled or not TargetLock.lockedChar then
        TargetLock.cachedPos    = nil
        TargetLock.cachedPart   = nil
        TargetLock.cachedCFrame = nil
        tlClearVisuals()
        return
    end

    local c = TargetLock.lockedChar
    -- Drop lock if target died/left
    if isKnockedOrDead(c) or not c.Parent then
        TargetLock.lockedChar   = nil
        TargetLock.cachedPos    = nil
        TargetLock.cachedPart   = nil
        TargetLock.cachedCFrame = nil
        tlClearVisuals()
        return
    end

    local head = c:FindFirstChild("Head") or c:FindFirstChild("HumanoidRootPart")
    if not head then
        TargetLock.cachedPos    = nil
        TargetLock.cachedPart   = nil
        TargetLock.cachedCFrame = nil
        return
    end

    -- Always cache regardless of camera angle
    TargetLock.cachedPos    = head.Position
    TargetLock.cachedPart   = head
    TargetLock.cachedCFrame = CFrame.new(head.Position)

    local sp = cam:WorldToViewportPoint(head.Position)
    local onScreen = sp.Z > 0

    if onScreen and TargetLock.showLine then
        local vp = cam.ViewportSize
        tlDrawLine(vp.X/2, vp.Y/2, sp.X, sp.Y)
    else
        tlLine.Visible = false
    end

    if TargetLock.showOutline then
        tlHighlight.Adornee = c
        tlHighlight.Enabled = true
    else
        tlHighlight.Enabled = false
    end
end)

-- Toggle keybind — solo funciona si el toggle raiz esta activado
UserInputService.InputBegan:Connect(function(inp, gp)
    if gp then return end
    if inp.KeyCode ~= TargetLock.key then return end
    if not TargetLock.masterEnabled then return end
    TargetLock.enabled = not TargetLock.enabled
    if TargetLock.enabled then
        local best, displayName = tlGetBestTarget()
        if best then
            tlLockOn(best)
            if TargetLock.showToasts then
                pcall(showToast, "Target Lock", "locked → " .. (displayName or "?"), TOAST_BLUE, "🔒")
            end
        else
            TargetLock.enabled = false
            if TargetLock.showToasts then pcall(showToast, "Target Lock", "no target found near cursor", TOAST_RED, "🔒") end
        end
    else
        tlLockOn(nil)
        if TargetLock.showToasts then pcall(showToast, "Target Lock", "released", TOAST_PURPLE, "🔓") end
    end
end)

lp.CharacterAdded:Connect(function(c)
    char = c
    TargetLock.enabled      = false
    TargetLock.lockedChar   = nil
    TargetLock.cachedPos    = nil
    TargetLock.cachedPart   = nil
    TargetLock.cachedCFrame = nil
    tlClearVisuals()
end)

-- ================================================================
-- TRIGGERBOT
-- ================================================================
local TriggerBot = {
    enabled    = false,
    interval   = 0.005,
    hitboxSize = 0.5,
    requireKey = false,
    toggleMode = false,
    toggled    = false,
    key        = nil,
    knifeCheck  = true,
    knockCheck  = true,
}

local BODY_PARTS = {
    Head=true, UpperTorso=true, LowerTorso=true, Torso=true,
    RightUpperArm=true, LeftUpperArm=true, RightLowerArm=true, LeftLowerArm=true,
    RightHand=true, LeftHand=true,
    RightUpperLeg=true, LeftUpperLeg=true, RightLowerLeg=true, LeftLowerLeg=true,
    RightFoot=true, LeftFoot=true, HumanoidRootPart=true,
}

-- Knife detection: name-based (Da Hood knives are consistent)
local KNIFE_NAMES = {
    -- Da Hood knife names
    ["Knife"]=true, ["knife"]=true,
    ["Fist"]=true, ["fist"]=true,
    ["Combat Knife"]=true, ["Switchblade"]=true,
    ["Butterfly Knife"]=true, ["Balisong"]=true,
    ["Karambit"]=true, ["Stiletto"]=true,
    ["Box Cutter"]=true, ["Cleaver"]=true,
    ["Machete"]=true, ["Dagger"]=true,
}
local function toolIsKnife(tool)
    if not tool then return false end
    if KNIFE_NAMES[tool.Name] then return true end
    local lower = tool.Name:lower()
    return lower:find("knife") ~= nil
        or lower:find("blade") ~= nil
        or lower:find("dagger") ~= nil
        or lower:find("machete") ~= nil
        or lower:find("cleaver") ~= nil
        or lower:find("cutter") ~= nil
        or lower:find("fist") ~= nil
        or lower:find("melee") ~= nil
        or lower:find("karambit") ~= nil
        or lower:find("balisong") ~= nil
        or lower:find("stiletto") ~= nil
end

-- Food detection: structural approach instead of name-only.
-- In Da Hood, food tools have NO RemoteEvent (no shoot mechanism)
-- AND have a heal/eat script inside. We look for both.
local function toolIsFood(tool)
    if not tool then return false end
    local lower = tool.Name:lower()

    -- Name-based fast path: covers burger, taco, fries, pizza, hotdog,
    -- ramen, soda, donut, chips, cookie, candy, sandwich, apple, etc.
    if lower:find("burger")   or lower:find("taco")
    or lower:find("fries")    or lower:find("pizza")
    or lower:find("hotdog")   or lower:find("hot dog")
    or lower:find("ramen")    or lower:find("soda")
    or lower:find("donut")    or lower:find("chips")
    or lower:find("cookie")   or lower:find("candy")
    or lower:find("sandwich") or lower:find("apple")
    or lower:find("juice")    or lower:find("water")
    or lower:find("drink")    or lower:find("eat")
    or lower:find("food")     or lower:find("snack")
    or lower:find("meal") then
        return true
    end

    -- Structural: food tools in Da Hood have NO RemoteEvent
    -- (guns/knives have at least one for shoot/stab events)
    -- AND usually have a heal-related NumberValue or Script
    local hasRemote = tool:FindFirstChildOfClass("RemoteEvent") ~= nil
        or tool:FindFirstChildOfClass("RemoteFunction") ~= nil
    if hasRemote then return false end  -- has remote = likely a weapon, not food

    -- No remote + has a heal/health value → food
    local hasHeal = tool:FindFirstChild("Heal")
        or tool:FindFirstChild("HealAmount")
        or tool:FindFirstChild("HealthAmount")
        or tool:FindFirstChild("HealValue")
    if hasHeal then return true end

    return false
end

-- Returns true if triggerbot should be suppressed for current tool
local function isSuppressedByTool()
    local character = lp.Character
    if not character then return false end
    local tool = character:FindFirstChildOfClass("Tool")
    if not tool then return false end
    -- Food: always suppressed (no toggle — food never triggers)
    if toolIsFood(tool) then return true end
    -- Knife: toggleable
    if TriggerBot.knifeCheck and toolIsKnife(tool) then return true end
    return false
end

local function triggerRay()
    local ok, result = pcall(function()
        local center = Vector2.new(cam.ViewportSize.X / 2, cam.ViewportSize.Y / 2)
        local screenRadius = math.max(TriggerBot.hitboxSize * 60, 8)
        for _, e in pairs(getAllEnemyChars()) do
            local c = e.char
            if not c or not c.Parent then continue end
            if TriggerBot.knockCheck and isKnockedOrDead(c) then continue end
            for _, part in ipairs(c:GetChildren()) do
                if part:IsA("BasePart") and BODY_PARTS[part.Name] then
                    local ok2, sp, onScreen = pcall(function()
                        return cam:WorldToViewportPoint(part.Position)
                    end)
                    if ok2 and onScreen and sp.Z > 0 then
                        if (Vector2.new(sp.X, sp.Y) - center).Magnitude <= screenRadius then return true end
                    end
                end
            end
            if e.isNPC then
                for _, part in ipairs(c:GetDescendants()) do
                    if part:IsA("BasePart") then
                        local ok2, sp, onScreen = pcall(function()
                            return cam:WorldToViewportPoint(part.Position)
                        end)
                        if ok2 and onScreen and sp.Z > 0 then
                            if (Vector2.new(sp.X, sp.Y) - center).Magnitude <= screenRadius then return true end
                        end
                    end
                end
            end
        end
        return false
    end)
    if not ok then return false end
    return result == true
end

-- Safe click wrapper — tries executor globals in order of availability
local function doClick()
    if mouse1click then
        pcall(mouse1click)
    elseif mouse1press and mouse1release then
        pcall(mouse1press)
        task.delay(0.01, function() pcall(mouse1release) end)
    elseif cloneref then
        pcall(function()
            local vu = cloneref(game:GetService("VirtualUser"))
            vu:Button1Down(Vector2.new(0,0), workspace.CurrentCamera.CFrame)
            task.delay(0.01, function()
                vu:Button1Up(Vector2.new(0,0), workspace.CurrentCamera.CFrame)
            end)
        end)
    else
        pcall(function()
            local vu = game:GetService("VirtualUser")
            vu:Button1Down(Vector2.new(0,0), workspace.CurrentCamera.CFrame)
            task.delay(0.01, function()
                vu:Button1Up(Vector2.new(0,0), workspace.CurrentCamera.CFrame)
            end)
        end)
    end
end

local _tbLastShot = 0
RunService.Heartbeat:Connect(function()
    if not TriggerBot.enabled then return end

    -- Guard: need a live character
    local myChar = lp.Character
    if not myChar or not myChar.Parent then return end
    local myHum = myChar:FindFirstChildOfClass("Humanoid")
    if not myHum or myHum.Health <= 0 then return end

    -- Tool suppression
    local suppOk, suppResult = pcall(isSuppressedByTool)
    if suppOk and suppResult then return end

    -- Key check
    if TriggerBot.requireKey then
        if TriggerBot.key == nil then return end
        if TriggerBot.toggleMode then
            if not TriggerBot.toggled then return end
        else
            local keyOk, keyDown = pcall(function()
                local tk = TriggerBot.key
                if type(tk) == "string" then
                    if tk == "MB1" then return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
                    elseif tk == "MB2" then return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
                    elseif tk == "MB3" then return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton3)

                    end; return false
                end
                return UserInputService:IsKeyDown(tk)
            end)
            if not keyOk or not keyDown then return end
        end
    end

    -- Interval
    local now = tick()
    if now - _tbLastShot < TriggerBot.interval then return end

    -- Ray check
    if not triggerRay() then return end

    -- Fire
    _tbLastShot = now
    doClick()
end)

local _tbSyncToggle = nil
UserInputService.InputBegan:Connect(function(inp, gp)
    if gp then return end
    if not TriggerBot.enabled then return end
    if not TriggerBot.requireKey then return end
    if not TriggerBot.toggleMode then return end
    if TriggerBot.key == nil then return end
    if not matchesKey(inp, TriggerBot.key) then return end
    local suppOk, suppResult = pcall(isSuppressedByTool)
    if suppOk and suppResult then return end
    TriggerBot.toggled = not TriggerBot.toggled
    if _tbSyncToggle then pcall(_tbSyncToggle, TriggerBot.toggled) end
end)

-- ================================================================
-- HITBOX VISUALIZER
-- ================================================================
local function getClosestTargetToCrosshair()
    local center = Vector2.new(cam.ViewportSize.X/2, cam.ViewportSize.Y/2)
    local best, bestDist = nil, math.huge
    for _, e in pairs(getAllEnemyChars()) do
        local c, hrp = e.char, e.hrp
        if hrp and not isKnockedOrDead(c) then
            local sp, onS = cam:WorldToViewportPoint(hrp.Position)
            if onS then
                local sd = (Vector2.new(sp.X,sp.Y)-center).Magnitude
                if sd < bestDist then bestDist = sd; best = c end
            end
        end
    end
    return best
end

local HitboxVisualizer = { enabled=false, color=Color3.fromRGB(255,30,30) }
local activeBoxes = {}

local function clearHitboxes()
    for _, e in ipairs(activeBoxes) do
        if e.box   then e.box:Destroy()   end
        if e.ghost then e.ghost:Destroy() end
    end
    activeBoxes = {}
end

local function refreshBoxSizes()
    local pad = TriggerBot.hitboxSize
    for _, e in ipairs(activeBoxes) do
        if e.part and e.part.Parent and e.ghost and e.ghost.Parent then
            e.ghost.Size = e.part.Size + Vector3.new(pad,pad,pad)
            e.ghost.CFrame = e.part.CFrame
        end
    end
end

-- Only these key parts get visualized — clean, minimal hitbox outline
local HV_PARTS = {"Head","UpperTorso","LowerTorso","Torso","HumanoidRootPart"}

local function buildHitboxesFor(character)
    clearHitboxes(); if not character then return end
    local pad = TriggerBot.hitboxSize
    for _, partName in ipairs(HV_PARTS) do
        local part = character:FindFirstChild(partName)
        if part and part:IsA("BasePart") then
            local ghost = Instance.new("Part")
            ghost.Size = part.Size + Vector3.new(pad,pad,pad); ghost.CFrame = part.CFrame
            ghost.Anchored = true; ghost.CanCollide = false; ghost.CanQuery = false; ghost.CanTouch = false
            ghost.Massless = true; ghost.CastShadow = false; ghost.Transparency = 1; ghost.Parent = workspace
            local sb = Instance.new("SelectionBox"); sb.Adornee = ghost
            sb.Color3 = HitboxVisualizer.color
            sb.SurfaceTransparency = 1        -- fully transparent fill
            sb.LineThickness = 0.04; sb.Parent = workspace
            table.insert(activeBoxes, {part=part, ghost=ghost, box=sb})
        end
    end
end

local hvCurrentTarget = nil

RunService.RenderStepped:Connect(function()
    if not HitboxVisualizer.enabled then
        if #activeBoxes > 0 then clearHitboxes(); hvCurrentTarget = nil end
        return
    end
    local nearestChar = getClosestTargetToCrosshair()
    if nearestChar ~= hvCurrentTarget then hvCurrentTarget = nearestChar; buildHitboxesFor(nearestChar) end
    local pad = TriggerBot.hitboxSize; local i = 1
    while i <= #activeBoxes do
        local e = activeBoxes[i]
        if e.part and e.part.Parent and e.ghost and e.ghost.Parent then
            e.ghost.Size = e.part.Size + Vector3.new(pad,pad,pad); e.ghost.CFrame = e.part.CFrame; i = i + 1
        else
            if e.box then e.box:Destroy() end; if e.ghost then e.ghost:Destroy() end
            table.remove(activeBoxes, i)
        end
    end
end)

lp.CharacterAdded:Connect(function(c) char = c; clearHitboxes(); hvCurrentTarget = nil end)

-- =================================================================
-- ESP
-- =================================================================
local ESP = {
    enabled     = false,
    boxes       = true,
    names       = true,
    healthBars  = true,
    distance    = true,
    tracers     = false,
    skeleton    = false,
    chams       = false,
    teamCheck   = false,
    maxDist     = 1000,
    boxColor    = Color3.fromRGB(255, 50, 50),
    tracerColor = Color3.fromRGB(255, 255, 255),
    skeletonColor = Color3.fromRGB(255, 255, 255),
    chamColor   = Color3.fromRGB(255, 50, 50),
}

-- ================================================================
-- CONFIG READER
-- ================================================================
local function _loadConfig()
    local CFG = getgenv and getgenv().PROTO
    if not CFG then return end

    local cl = CFG.CamLock
    if cl then
        if cl.Key         ~= nil then settings.key         = cl.Key         end
        if cl.Toggle      ~= nil then settings.toggle      = cl.Toggle      end
        if cl.Range       ~= nil then settings.range       = cl.Range       end
        if cl.Smooth      ~= nil then settings.smooth      = cl.Smooth      end
        if cl.StickyAim   ~= nil then settings.stickyAim   = cl.StickyAim   end
        if cl.KnockCheck  ~= nil then settings.knockCheck  = cl.KnockCheck  end
        if cl.TeamCheck   ~= nil then settings.teamCheck   = cl.TeamCheck   end
        if cl.CrewCheck   ~= nil then settings.crewCheck   = cl.CrewCheck   end
        if cl.WallCheck   ~= nil then settings.wallCheck   = cl.WallCheck   end
        if cl.FovVisible  ~= nil then settings.fovVisible  = cl.FovVisible  end
        if cl.FovSize     ~= nil then settings.fovSize     = cl.FovSize     end
        if cl.PredictionX ~= nil then settings.predictionX = cl.PredictionX end
        if cl.PredictionY ~= nil then settings.predictionY = cl.PredictionY end
        if cl.PredictionZ ~= nil then settings.predictionZ = cl.PredictionZ end
        if cl.AimPart     ~= nil then camlockAimPart       = cl.AimPart     end
        if cl.Shake then
            if cl.Shake.Enabled ~= nil then settings.shakeEnabled = cl.Shake.Enabled end
            if cl.Shake.X       ~= nil then settings.shakeX       = cl.Shake.X       end
            if cl.Shake.Y       ~= nil then settings.shakeY       = cl.Shake.Y       end
        end
        if cl.Easing then
            if cl.Easing.Enabled          ~= nil then EasingSettings.enabled          = cl.Easing.Enabled          end
            if cl.Easing.Style            ~= nil then EasingSettings.style            = cl.Easing.Style            end
            if cl.Easing.Duration         ~= nil then EasingSettings.duration         = cl.Easing.Duration         end
            if cl.Easing.BackAmplitude    ~= nil then EasingSettings.backAmplitude    = cl.Easing.BackAmplitude    end
            if cl.Easing.ElasticAmplitude ~= nil then EasingSettings.elasticAmplitude = cl.Easing.ElasticAmplitude end
            if cl.Easing.ElasticFrequency ~= nil then EasingSettings.elasticFrequency = cl.Easing.ElasticFrequency end
        end
    end

    local sa = CFG.Silent
    if sa then
        if sa.Enabled     ~= nil then SilentAimV2.enabled     = sa.Enabled     end
        if sa.HitChance   ~= nil then SilentAimV2.hitChance   = sa.HitChance   end
        if sa.Prediction  ~= nil then SilentAimV2.prediction  = sa.Prediction  end
        if sa.NearestPart ~= nil then SilentAimV2.nearestPart = sa.NearestPart end
        if sa.CheckFOV    ~= nil then SilentAimV2.checkFOV    = sa.CheckFOV    end
        if sa.CheckRange  ~= nil then SilentAimV2.checkRange  = sa.CheckRange  end
        if sa.CheckKnock  ~= nil then SilentAimV2.checkKnock  = sa.CheckKnock  end
        if sa.TeamCheck   ~= nil then SilentAimV2.teamCheck   = sa.TeamCheck   end
        if sa.CrewCheck   ~= nil then SilentAimV2.crewCheck   = sa.CrewCheck   end
        if sa.WallCheck   ~= nil then SilentAimV2.wallCheck   = sa.WallCheck   end
    end

    local tl = CFG.TargetLock
    if tl then
        if tl.Enabled     ~= nil then TargetLock.masterEnabled = tl.Enabled     end
        if tl.Key         ~= nil then TargetLock.key           = tl.Key         end
        if tl.ShowLine    ~= nil then TargetLock.showLine      = tl.ShowLine    end
        if tl.ShowOutline ~= nil then TargetLock.showOutline   = tl.ShowOutline end
        if tl.ShowToasts  ~= nil then TargetLock.showToasts    = tl.ShowToasts  end
    end

    local ml = CFG.MouseLock
    if ml then
        if ml.Enabled    ~= nil then MouseLock.enabled    = ml.Enabled    end
        if ml.Key        ~= nil then MouseLock.key        = ml.Key        end
        if ml.Toggle     ~= nil then MouseLock.toggle     = ml.Toggle     end
        if ml.AimPart    ~= nil then MouseLock.aimPart    = ml.AimPart    end
        if ml.Smooth     ~= nil then MouseLock.smooth     = ml.Smooth     end
        if ml.FrameSkip  ~= nil then MouseLock.frameSkip  = ml.FrameSkip  end
        if ml.Prediction ~= nil then MouseLock.prediction = ml.Prediction end
        if ml.HitChance  ~= nil then MouseLock.hitChance  = ml.HitChance  end
        if ml.CheckFOV   ~= nil then MouseLock.checkFOV   = ml.CheckFOV   end
        if ml.FovSize    ~= nil then MouseLock.fovSize    = ml.FovSize    end
        if ml.CheckRange ~= nil then MouseLock.checkRange = ml.CheckRange end
        if ml.Range      ~= nil then MouseLock.range      = ml.Range      end
        if ml.CheckKnock ~= nil then MouseLock.checkKnock = ml.CheckKnock end
    end

    local gf = CFG.GunFov
    if gf then
        GunProfiles.enabled  = gf.Enabled == true
        GunProfiles._gfCFG   = gf
        GunProfiles._gunMap  = {
            ["[Double-Barrel SG]"] = gf.DoubleBarrel,
            ["[Revolver]"]         = gf.Revolver,
            ["[TacticalShotgun]"]  = gf.TacticalShotgun,
            ["[Shotgun]"]          = gf.Shotgun,
            ["[Rifle]"]            = gf.Rifle,
            ["[Smg]"]              = gf.Smg,
            ["[AK-47]"]            = gf.AK47,
            ["[AR]"]               = gf.AR,
            ["[Silencer]"]         = gf.Silencer,
            ["[Pistol]"]           = gf.Pistol,
        }
        GunProfiles._useGunFov = true
    end

    local df = CFG.DynamicFOV
    if df then
        if df.Enabled          ~= nil then DynamicFOV.enabled          = df.Enabled          end
        if df.SmoothTransition ~= nil then DynamicFOV.smoothTransition = df.SmoothTransition end
        if df.TransitionSpeed  ~= nil then DynamicFOV.transitionSpeed  = df.TransitionSpeed  end
        if df.ShowZoneLabel    ~= nil then DynamicFOV.showZoneLabel    = df.ShowZoneLabel    end
        if df.Zones then
            if df.Zones.Close  then DynamicFOV.zones.close  = { maxDist=df.Zones.Close.MaxDist,  fovSize=df.Zones.Close.FovSize  } end
            if df.Zones.Medium then DynamicFOV.zones.medium = { maxDist=df.Zones.Medium.MaxDist, fovSize=df.Zones.Medium.FovSize } end
            if df.Zones.Far    then DynamicFOV.zones.far    = { maxDist=df.Zones.Far.MaxDist,    fovSize=df.Zones.Far.FovSize    } end
            if df.Zones.Sniper then DynamicFOV.zones.sniper = { maxDist=df.Zones.Sniper.MaxDist, fovSize=df.Zones.Sniper.FovSize } end
        end
    end

    local tb = CFG.TriggerBot
    if tb then
        if tb.Enabled    ~= nil then TriggerBot.enabled    = tb.Enabled    end
        if tb.Key        ~= nil then TriggerBot.key        = tb.Key        end
        if tb.ToggleMode ~= nil then TriggerBot.toggleMode = tb.ToggleMode end
        if tb.RequireKey ~= nil then TriggerBot.requireKey = tb.RequireKey end
        if tb.Interval   ~= nil then TriggerBot.interval   = tb.Interval   end
        if tb.HitboxSize ~= nil then TriggerBot.hitboxSize = tb.HitboxSize end
        if tb.KnifeCheck ~= nil then TriggerBot.knifeCheck = tb.KnifeCheck end
        if tb.KnockCheck ~= nil then TriggerBot.knockCheck = tb.KnockCheck end
    end

    local db = CFG.DBSniper
    if db then
        if db.Enabled   ~= nil then DBSniper.enabled   = db.Enabled   end
        if db.Intensity ~= nil then DBSniper.intensity = db.Intensity end
    end

    local ts = CFG.TacticalSniper
    if ts then
        if ts.Enabled   ~= nil then TacticalSniper.enabled   = ts.Enabled   end
        if ts.Intensity ~= nil then TacticalSniper.intensity = ts.Intensity end
    end

    local sp = CFG.Speed
    if sp then
        if sp.Enabled ~= nil then SpeedHack.enabled = sp.Enabled end
        if sp.Speed   ~= nil then SpeedHack.speed   = sp.Speed   end
        if sp.Key     ~= nil then SpeedHack.key     = sp.Key     end
    end

    local es = CFG.ESP
    if es then
        if es.Enabled       ~= nil then ESP.enabled       = es.Enabled       end
        if es.Boxes         ~= nil then ESP.boxes         = es.Boxes         end
        if es.Names         ~= nil then ESP.names         = es.Names         end
        if es.HealthBars    ~= nil then ESP.healthBars    = es.HealthBars    end
        if es.Distance      ~= nil then ESP.distance      = es.Distance      end
        if es.Tracers       ~= nil then ESP.tracers       = es.Tracers       end
        if es.Skeleton      ~= nil then ESP.skeleton      = es.Skeleton      end
        if es.Chams         ~= nil then ESP.chams         = es.Chams         end
        if es.TeamCheck     ~= nil then ESP.teamCheck     = es.TeamCheck     end
        if es.MaxDist       ~= nil then ESP.maxDist       = es.MaxDist       end
        if es.BoxColor      ~= nil then ESP.boxColor      = es.BoxColor      end
        if es.TracerColor   ~= nil then ESP.tracerColor   = es.TracerColor   end
        if es.SkeletonColor ~= nil then ESP.skeletonColor = es.SkeletonColor end
        if es.ChamColor     ~= nil then ESP.chamColor     = es.ChamColor     end
    end

    if CFG.Whitelist then
        for _, name in ipairs(CFG.Whitelist) do
            for _, p in pairs(Players:GetPlayers()) do
                if p.Name == name then Whitelist[p.UserId] = true end
            end
            Players.PlayerAdded:Connect(function(p)
                if p.Name == name then Whitelist[p.UserId] = true end
            end)
        end
    end

    if CFG.Blacklist then
        for _, name in ipairs(CFG.Blacklist) do
            for _, p in pairs(Players:GetPlayers()) do
                if p.Name == name then Blacklist[p.UserId] = true end
            end
            Players.PlayerAdded:Connect(function(p)
                if p.Name == name then Blacklist[p.UserId] = true end
            end)
        end
    end
end
_loadConfig()

local espObjects = {}  -- [character] = { box, nameLabel, healthBar, distLabel, tracer, bones[], highlight }

local SKELETON_JOINTS = {
    {"Head",        "UpperTorso"},
    {"UpperTorso",  "LowerTorso"},
    {"LowerTorso",  "HumanoidRootPart"},
    {"UpperTorso",  "RightUpperArm"},
    {"RightUpperArm","RightLowerArm"},
    {"RightLowerArm","RightHand"},
    {"UpperTorso",  "LeftUpperArm"},
    {"LeftUpperArm","LeftLowerArm"},
    {"LeftLowerArm","LeftHand"},
    {"LowerTorso",  "RightUpperLeg"},
    {"RightUpperLeg","RightLowerLeg"},
    {"RightLowerLeg","RightFoot"},
    {"LowerTorso",  "LeftUpperLeg"},
    {"LeftUpperLeg","LeftLowerLeg"},
    {"LeftLowerLeg","LeftFoot"},
}

local espContainer = Instance.new("ScreenGui")
espContainer.Name = "ESPGui"; espContainer.ResetOnSpawn = false
espContainer.IgnoreGuiInset = true; espContainer.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
espContainer.Parent = gui

local function newLine(color, thickness)
    local l = Instance.new("Frame", espContainer)
    l.AnchorPoint = Vector2.new(0.5, 0.5)
    l.BackgroundColor3 = color or Color3.new(1,1,1)
    l.BorderSizePixel = 0
    l.Visible = false
    return l
end

local function drawLine(frame, x1, y1, x2, y2, thickness)
    local dx = x2 - x1; local dy = y2 - y1
    local len = math.sqrt(dx*dx + dy*dy)
    if len < 1 then frame.Visible = false; return end
    local angle = math.atan2(dy, dx)
    frame.Size = UDim2.new(0, len, 0, thickness or 1)
    frame.Position = UDim2.new(0, (x1+x2)/2, 0, (y1+y2)/2)
    frame.Rotation = math.deg(angle)
    frame.Visible = true
end

local function newLabel(text, size, color)
    local l = Instance.new("TextLabel", espContainer)
    l.BackgroundTransparency = 1; l.Text = text
    l.TextSize = size or 11; l.Font = Enum.Font.GothamBold
    l.TextColor3 = color or Color3.new(1,1,1)
    l.TextStrokeTransparency = 0.5; l.TextStrokeColor3 = Color3.new(0,0,0)
    l.Visible = false; l.ZIndex = 5
    return l
end

local function newBox(color)
    -- 4 lines for the box outline
    local lines = {}
    for i = 1,4 do
        local l = newLine(color, 1)
        l.ZIndex = 4
        table.insert(lines, l)
    end
    return lines
end

local function drawBox(lines, x, y, w, h, color)
    -- top, bottom, left, right
    local pts = {
        {x,   y,   x+w, y  },
        {x,   y+h, x+w, y+h},
        {x,   y,   x,   y+h},
        {x+w, y,   x+w, y+h},
    }
    for i, p in ipairs(pts) do
        lines[i].BackgroundColor3 = color
        drawLine(lines[i], p[1], p[2], p[3], p[4], 1)
    end
end

local function newHealthBar()
    local bg = Instance.new("Frame", espContainer)
    bg.BackgroundColor3 = Color3.fromRGB(20,20,20)
    bg.BorderSizePixel = 0; bg.ZIndex = 4; bg.Visible = false
    local fill = Instance.new("Frame", bg)
    fill.BackgroundColor3 = Color3.fromRGB(50,200,50)
    fill.BorderSizePixel = 0; fill.ZIndex = 5
    fill.Size = UDim2.new(1, 0, 1, 0)
    return bg, fill
end

local function getHealthColor(pct)
    if pct > 0.6 then return Color3.fromRGB(50,200,50)
    elseif pct > 0.3 then return Color3.fromRGB(220,180,20)
    else return Color3.fromRGB(200,40,40) end
end

local function createESPFor(c)
    if espObjects[c] then return end
    local obj = {}
    obj.box = newBox(ESP.boxColor)
    obj.nameLbl = newLabel("", 10, Color3.new(1,1,1))
    obj.distLbl = newLabel("", 9, Color3.fromRGB(180,180,180))
    obj.hpBg, obj.hpFill = newHealthBar()
    obj.tracer = newLine(ESP.tracerColor, 1)
    obj.tracer.ZIndex = 3
    obj.bones = {}
    for _ = 1, #SKELETON_JOINTS do
        local l = newLine(ESP.skeletonColor, 1)
        l.ZIndex = 3
        table.insert(obj.bones, l)
    end
    -- Highlight (chams)
    local hl = Instance.new("SelectionBox")
    hl.Color3 = ESP.chamColor
    hl.SurfaceColor3 = ESP.chamColor
    hl.SurfaceTransparency = 0.6
    hl.LineThickness = 0.02
    hl.Adornee = nil
    hl.Parent = workspace
    obj.highlight = hl
    espObjects[c] = obj
end

local function removeESPFor(c)
    local obj = espObjects[c]
    if not obj then return end
    for _, l in ipairs(obj.box) do l:Destroy() end
    obj.nameLbl:Destroy(); obj.distLbl:Destroy()
    obj.hpBg:Destroy(); obj.tracer:Destroy()
    for _, b in ipairs(obj.bones) do b:Destroy() end
    obj.highlight:Destroy()
    espObjects[c] = nil
end

local function hideESPObj(obj)
    for _, l in ipairs(obj.box) do l.Visible = false end
    obj.nameLbl.Visible = false; obj.distLbl.Visible = false
    obj.hpBg.Visible = false; obj.tracer.Visible = false
    for _, b in ipairs(obj.bones) do b.Visible = false end
    obj.highlight.Adornee = nil
end

local function clearAllESP()
    for c in pairs(espObjects) do removeESPFor(c) end
end

RunService.RenderStepped:Connect(function()
    if not ESP.enabled then
        if next(espObjects) then clearAllESP() end
        return
    end

    local myRoot = char and char:FindFirstChild("HumanoidRootPart")
    local vp = cam.ViewportSize
    local screenCenter = Vector2.new(vp.X/2, vp.Y)  -- tracer origin = bottom center

    local activeChars = {}
    for _, e in pairs(getAllEnemyChars()) do
        local c, hrp = e.char, e.hrp
        if not c or not hrp then continue end
        -- Distance check
        if myRoot and (myRoot.Position - hrp.Position).Magnitude > ESP.maxDist then continue end
        activeChars[c] = e
    end

    -- Remove stale ESP objects
    for c in pairs(espObjects) do
        if not activeChars[c] then removeESPFor(c) end
    end

    -- Update each target
    for c, e in pairs(activeChars) do
        local hrp = e.hrp
        local hum = c:FindFirstChild("Humanoid")
        if not hum then continue end

        -- Create if missing
        if not espObjects[c] then createESPFor(c) end
        local obj = espObjects[c]

        -- Get head and feet for box bounds
        local head = c:FindFirstChild("Head") or hrp
        local headSP, headOnS = cam:WorldToViewportPoint(head.Position + Vector3.new(0, head.Size.Y/2 + 0.1, 0))
        local feetSP, feetOnS = cam:WorldToViewportPoint(hrp.Position - Vector3.new(0, 3, 0))

        if not headOnS or not feetOnS or headSP.Z <= 0 then
            hideESPObj(obj); continue
        end

        local hx, hy = headSP.X, headSP.Y
        local fx, fy = feetSP.X, feetSP.Y
        local boxH = math.abs(fy - hy)
        local boxW = boxH * 0.55
        local boxX = hx - boxW/2
        local boxY = hy

        -- BOX
        if ESP.boxes then
            drawBox(obj.box, boxX, boxY, boxW, boxH, ESP.boxColor)
        else
            for _, l in ipairs(obj.box) do l.Visible = false end
        end

        -- NAME
        if ESP.names then
            local name = e.isNPC and c.Name or (function()
                for _, p in pairs(Players:GetPlayers()) do
                    if p.Character == c then return p.DisplayName end
                end
                return c.Name
            end)()
            obj.nameLbl.Text = name
            obj.nameLbl.Size = UDim2.new(0, 120, 0, 14)
            obj.nameLbl.Position = UDim2.new(0, hx - 60, 0, boxY - 16)
            obj.nameLbl.Visible = true
        else
            obj.nameLbl.Visible = false
        end

        -- HEALTH BAR
        if ESP.healthBars then
            local pct = math.clamp(hum.Health / hum.MaxHealth, 0, 1)
            local barW = 4; local barX = boxX - barW - 2
            obj.hpBg.Size = UDim2.new(0, barW, 0, boxH)
            obj.hpBg.Position = UDim2.new(0, barX, 0, boxY)
            obj.hpBg.Visible = true
            obj.hpFill.Size = UDim2.new(1, 0, pct, 0)
            obj.hpFill.Position = UDim2.new(0, 0, 1 - pct, 0)
            obj.hpFill.BackgroundColor3 = getHealthColor(pct)
        else
            obj.hpBg.Visible = false
        end

        -- DISTANCE
        if ESP.distance and myRoot then
            local dist = math.floor((myRoot.Position - hrp.Position).Magnitude)
            obj.distLbl.Text = dist .. "m"
            obj.distLbl.Size = UDim2.new(0, 60, 0, 12)
            obj.distLbl.Position = UDim2.new(0, hx - 30, 0, boxY + boxH + 2)
            obj.distLbl.Visible = true
        else
            obj.distLbl.Visible = false
        end

        -- TRACER
        if ESP.tracers then
            local tx, ty = (hx + (hx - boxX + boxW/2))/2, fy
            drawLine(obj.tracer, screenCenter.X, screenCenter.Y, hx, fy, 1)
            obj.tracer.BackgroundColor3 = ESP.tracerColor
        else
            obj.tracer.Visible = false
        end

        -- SKELETON
        if ESP.skeleton then
            for i, joint in ipairs(SKELETON_JOINTS) do
                local p1 = c:FindFirstChild(joint[1])
                local p2 = c:FindFirstChild(joint[2])
                if p1 and p2 then
                    local sp1, on1 = cam:WorldToViewportPoint(p1.Position)
                    local sp2, on2 = cam:WorldToViewportPoint(p2.Position)
                    if on1 and on2 and sp1.Z > 0 and sp2.Z > 0 then
                        obj.bones[i].BackgroundColor3 = ESP.skeletonColor
                        drawLine(obj.bones[i], sp1.X, sp1.Y, sp2.X, sp2.Y, 1)
                    else
                        obj.bones[i].Visible = false
                    end
                else
                    obj.bones[i].Visible = false
                end
            end
        else
            for _, b in ipairs(obj.bones) do b.Visible = false end
        end

        -- CHAMS (SelectionBox)
        if ESP.chams then
            obj.highlight.Adornee = hrp
            obj.highlight.Color3 = ESP.chamColor
            obj.highlight.SurfaceColor3 = ESP.chamColor
        else
            obj.highlight.Adornee = nil
        end
    end
end)

-- =================================================================
-- UI v3
-- =================================================================
local C = {
    bg        = Color3.fromRGB(12, 12, 14),
    panel     = Color3.fromRGB(17, 17, 19),
    item      = Color3.fromRGB(22, 22, 25),
    accent    = Color3.fromRGB(58, 90, 160),
    accentLit = Color3.fromRGB(80, 115, 190),
    accentDark= Color3.fromRGB(18, 28, 55),
    border    = Color3.fromRGB(35, 35, 40),
    borderAcc = Color3.fromRGB(40, 60, 110),
    text      = Color3.fromRGB(230,230,235),
    textSub   = Color3.fromRGB(230,230,235),
    textDim   = Color3.fromRGB(140,140,150),
    trackBg   = Color3.fromRGB(30, 30, 35),
    green     = Color3.fromRGB(60, 185, 80),
    titleBg   = Color3.fromRGB(9,  9,  11),
    tabBg     = Color3.fromRGB(12, 12, 14),
    tabSel    = Color3.fromRGB(22, 22, 25),
}

local accentRegistry = {}
local function reg(inst, tgt, colorKey)
    table.insert(accentRegistry, {instance=inst, target=tgt, property=colorKey})
end
local function corner(p, r)
    local c = Instance.new("UICorner", p); c.CornerRadius = UDim.new(0, r or 3); return c
end
local function strokeInst(p, col, th)
    local s = Instance.new("UIStroke", p)
    s.Color = col or C.border; s.Thickness = th or 1
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    return s
end
local function label(p, txt, size, col, font, align)
    local l = Instance.new("TextLabel", p)
    l.BackgroundTransparency = 1; l.Text = txt or ""; l.TextSize = size or 11
    l.TextColor3 = col or C.text; l.Font = font or Enum.Font.Gotham
    l.TextXAlignment = align or Enum.TextXAlignment.Left
    l.TextYAlignment = Enum.TextYAlignment.Center
    return l
end

local Screen = Instance.new("ScreenGui")
Screen.Name = "PrototypeUI"; Screen.ResetOnSpawn = false
Screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling; Screen.Parent = gui

local Main = Instance.new("Frame", Screen)
Main.Size = UDim2.new(0, 500, 0, 800)
Main.Position = UDim2.new(0.5, -250, 0.5, -400)
Main.BackgroundColor3 = C.bg; Main.BorderSizePixel = 0
Main.Visible = false  -- hidden until intro finishes
corner(Main, 4); strokeInst(Main, C.border, 1)

local TopBar = Instance.new("Frame", Main)
TopBar.Size = UDim2.new(1, 0, 0, 28)
TopBar.BackgroundColor3 = C.titleBg; TopBar.BorderSizePixel = 0; corner(TopBar, 4)
local tbFix = Instance.new("Frame", TopBar)
tbFix.Size = UDim2.new(1,0,0.5,0); tbFix.Position = UDim2.new(0,0,0.5,0)
tbFix.BackgroundColor3 = C.titleBg; tbFix.BorderSizePixel = 0

local nameLabel = label(TopBar, "prototype", 12, C.text, Enum.Font.Gotham)
nameLabel.Size = UDim2.new(0, 90, 1, 0); nameLabel.Position = UDim2.new(0, 10, 0, 0)
local hotkeyLbl = label(TopBar, "INSERT  F4", 10, C.textSub, Enum.Font.Gotham, Enum.TextXAlignment.Right)
hotkeyLbl.Size = UDim2.new(0, 80, 1, 0); hotkeyLbl.Position = UDim2.new(1, -88, 0, 0)

local topLine = Instance.new("Frame", Main)
topLine.Size = UDim2.new(1,0,0,1); topLine.Position = UDim2.new(0,0,0,28)
topLine.BackgroundColor3 = C.border; topLine.BorderSizePixel = 0

local TabBar = Instance.new("Frame", Main)
TabBar.Size = UDim2.new(1, 0, 0, 28); TabBar.Position = UDim2.new(0, 0, 0, 29)
TabBar.BackgroundColor3 = C.panel; TabBar.BorderSizePixel = 0
local tabBarLayout = Instance.new("UIListLayout", TabBar)
tabBarLayout.FillDirection = Enum.FillDirection.Horizontal
tabBarLayout.SortOrder = Enum.SortOrder.LayoutOrder
tabBarLayout.VerticalAlignment = Enum.VerticalAlignment.Center
tabBarLayout.Padding = UDim.new(0, 0)

local tabLine = Instance.new("Frame", Main)
tabLine.Size = UDim2.new(1,0,0,1); tabLine.Position = UDim2.new(0,0,0,57)
tabLine.BackgroundColor3 = C.border; tabLine.BorderSizePixel = 0

local Content = Instance.new("Frame", Main)
Content.Size = UDim2.new(1, 0, 1, -58); Content.Position = UDim2.new(0, 0, 0, 58)
Content.BackgroundTransparency = 1; Content.ClipsDescendants = true

do
    local dragging, ds, sp2
    TopBar.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 then dragging=true; ds=inp.Position; sp2=Main.Position end
    end)
    UserInputService.InputChanged:Connect(function(inp)
        if dragging and inp.UserInputType == Enum.UserInputType.MouseMovement then
            local d = inp.Position - ds
            Main.Position = UDim2.new(sp2.X.Scale, sp2.X.Offset+d.X, sp2.Y.Scale, sp2.Y.Offset+d.Y)
        end
    end)
    UserInputService.InputEnded:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
    end)
end

-- ===== RESIZE HANDLE (drag bottom-right corner) =====
do
    local MIN_W, MIN_H = 400, 300
    local MAX_W, MAX_H = 1200, 900

    local ResizeHandle = Instance.new("Frame", Main)
    ResizeHandle.Size = UDim2.new(0, 16, 0, 16)
    ResizeHandle.Position = UDim2.new(1, -16, 1, -16)
    ResizeHandle.BackgroundColor3 = C.accentDark
    ResizeHandle.BorderSizePixel = 0
    ResizeHandle.ZIndex = 20
    corner(ResizeHandle, 4)

    -- Draw a small grip icon (3 diagonal dots)
    local function makeDot(ox, oy)
        local d = Instance.new("Frame", ResizeHandle)
        d.Size = UDim2.new(0, 2, 0, 2)
        d.Position = UDim2.new(0, ox, 0, oy)
        d.BackgroundColor3 = C.accent
        d.BorderSizePixel = 0
        d.ZIndex = 11
        corner(d, 1)
    end
    makeDot(4,  10); makeDot(8,  6); makeDot(12, 2)

    local resizing, rs, origSize, origPos
    ResizeHandle.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 then
            resizing = true
            rs = inp.Position
            origSize = Main.Size
            origPos  = Main.AbsolutePosition
        end
    end)
    UserInputService.InputChanged:Connect(function(inp)
        if resizing and inp.UserInputType == Enum.UserInputType.MouseMovement then
            local d = inp.Position - rs
            local newW = math.clamp(origSize.X.Offset + d.X, MIN_W, MAX_W)
            local newH = math.clamp(origSize.Y.Offset + d.Y, MIN_H, MAX_H)
            Main.Size = UDim2.new(0, newW, 0, newH)
        end
    end)
    UserInputService.InputEnded:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 then resizing = false end
    end)

    -- Hover effect
    ResizeHandle.MouseEnter:Connect(function()
        TweenService:Create(ResizeHandle, TweenInfo.new(0.12), {BackgroundColor3 = C.accent}):Play()
    end)
    ResizeHandle.MouseLeave:Connect(function()
        TweenService:Create(ResizeHandle, TweenInfo.new(0.12), {BackgroundColor3 = C.accentDark}):Play()
    end)
end

local Tabs = {"Camlock","Silent","DynFOV","Trigger","Misc","ESP","Visuals","Whitelist","Blacklist","Settings"}
local Pages = {}; local tabBtns = {}; local CurrentTab = ""

for i, name in ipairs(Tabs) do
    local btn = Instance.new("TextButton", TabBar)
    btn.Size = UDim2.new(1/#Tabs, 0, 1, 0)
    btn.BackgroundColor3 = (i==1) and C.tabSel or C.tabBg
    btn.BorderSizePixel = 0; btn.Text = ""; btn.AutoButtonColor = false
    local aLine = Instance.new("Frame", btn)
    aLine.Size = UDim2.new(1, 0, 0, 2); aLine.Position = UDim2.new(0, 0, 1, -2)
    aLine.BackgroundColor3 = C.accent; aLine.BorderSizePixel = 0; aLine.Visible = (i==1)
    reg(aLine, "BackgroundColor3", "accent")
    local bLbl = label(btn, name:lower(), 11, C.text, Enum.Font.Gotham, Enum.TextXAlignment.Center)
    bLbl.Size = UDim2.new(1, 0, 1, 0)
    tabBtns[name] = {btn=btn, line=aLine, lbl=bLbl}
    local page = Instance.new("ScrollingFrame", Content)
    page.Size = UDim2.new(1, 0, 1, 0); page.Visible = (i==1)
    page.BackgroundTransparency = 1; page.BorderSizePixel = 0
    page.ScrollBarThickness = 3; page.ScrollBarImageColor3 = C.accentDark
    page.AutomaticCanvasSize = Enum.AutomaticSize.Y; page.CanvasSize = UDim2.new(0,0,0,0)
    page.ScrollingDirection = Enum.ScrollingDirection.Y
    Pages[name] = page
    local pLayout = Instance.new("UIListLayout", page)
    pLayout.Padding = UDim.new(0,1); pLayout.SortOrder = Enum.SortOrder.LayoutOrder
    pLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    local pPad = Instance.new("UIPadding", page)
    pPad.PaddingTop = UDim.new(0,4); pPad.PaddingLeft = UDim.new(0,4)
    pPad.PaddingRight = UDim.new(0,4); pPad.PaddingBottom = UDim.new(0,8)
    if i == 1 then CurrentTab = name end
    btn.MouseButton1Click:Connect(function()
        CurrentTab = name
        for n, p in pairs(Pages) do p.Visible = (n==name) end
        for n, t in pairs(tabBtns) do
            local sel = (n==name)
            t.btn.BackgroundColor3 = sel and C.tabSel or C.tabBg
            t.line.Visible = sel
            t.lbl.TextColor3 = C.text
            t.lbl.Font = Enum.Font.Gotham
        end
    end)
end

local UI = {}
local applyAccentColor

function UI.Header(parent, txt)
    local f = Instance.new("Frame", parent)
    f.Size = UDim2.new(1,0,0,20); f.BackgroundColor3 = C.panel; f.BorderSizePixel = 0
    local lbl2 = label(f, txt, 11, C.textSub, Enum.Font.Gotham)
    lbl2.Size = UDim2.new(1,-10,1,0); lbl2.Position = UDim2.new(0,8,0,0)
    return f
end

function UI.Toggle(parent, name, default, cb)
    local state = default
    local f = Instance.new("TextButton", parent)
    f.Size = UDim2.new(1,0,0,28); f.BackgroundColor3 = C.item; f.BorderSizePixel = 0
    f.Text = ""; f.AutoButtonColor = false

    local nameLbl = label(f, name, 12, C.text, Enum.Font.Gotham)
    nameLbl.Size = UDim2.new(1,-60,1,0); nameLbl.Position = UDim2.new(0,12,0,0)
    nameLbl.Active = false; nameLbl.Interactable = false

    -- Pill track
    local PILL_W, PILL_H = 34, 18
    local pillTrack = Instance.new("Frame", f)
    pillTrack.Size = UDim2.new(0, PILL_W, 0, PILL_H)
    pillTrack.Position = UDim2.new(1, -(PILL_W+10), 0.5, -(PILL_H/2))
    pillTrack.BackgroundColor3 = state and C.accent or C.trackBg
    pillTrack.BorderSizePixel = 0
    pillTrack.ZIndex = 1; pillTrack.Active = false
    corner(pillTrack, PILL_H/2)
    strokeInst(pillTrack, C.border, 1)

    -- Knob
    local KNOB = PILL_H - 4
    local knob = Instance.new("Frame", pillTrack)
    knob.Size = UDim2.new(0, KNOB, 0, KNOB)
    knob.Position = state and UDim2.new(1, -(KNOB+2), 0.5, -(KNOB/2)) or UDim2.new(0, 2, 0.5, -(KNOB/2))
    knob.BackgroundColor3 = Color3.new(1,1,1)
    knob.BorderSizePixel = 0
    knob.ZIndex = 1; knob.Active = false
    corner(knob, KNOB/2)

    table.insert(accentRegistry, {instance=pillTrack, target="BackgroundColor3", property="accent", isToggle=true, getState=function() return state end})

    local function animateSwitch(on)
        local targetPos = on and UDim2.new(1, -(KNOB+2), 0.5, -(KNOB/2)) or UDim2.new(0, 2, 0.5, -(KNOB/2))
        local targetColor = on and C.accent or C.trackBg
        TweenService:Create(knob, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Position=targetPos}):Play()
        TweenService:Create(pillTrack, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundColor3=targetColor}):Play()
    end

    -- click handled directly on f (TextButton)
    f.MouseButton1Click:Connect(function()
        state = not state
        animateSwitch(state)
        nameLbl.TextColor3 = C.text
        if cb then cb(state) end
    end)
    return f
end

function UI.Slider(parent, name, default, mn, mx, step, cb)
    local val = default
    local f = Instance.new("Frame", parent)
    -- 44px total: 20px top row (name+value), 6px gap, 4px track, 14px bottom padding for thumb overflow
    f.Size = UDim2.new(1,0,0,44); f.BackgroundColor3 = C.item; f.BorderSizePixel = 0
    local nameLbl = label(f, name, 12, C.text, Enum.Font.Gotham)
    nameLbl.Size = UDim2.new(0.6,0,0,20); nameLbl.Position = UDim2.new(0,10,0,4)
    local valLbl = label(f, tostring(val), 12, C.text, Enum.Font.Gotham, Enum.TextXAlignment.Right)
    valLbl.Size = UDim2.new(0.35,0,0,20); valLbl.Position = UDim2.new(0.62,0,0,4)

    -- Manual input TextBox (hidden, shown on click)
    local valInput = Instance.new("TextBox", f)
    valInput.Size = UDim2.new(0.35,0,0,20); valInput.Position = UDim2.new(0.62,0,0,4)
    valInput.BackgroundColor3 = Color3.fromRGB(15,15,15); valInput.BorderSizePixel = 0
    valInput.Text = ""; valInput.Font = Enum.Font.Gotham; valInput.TextSize = 11
    valInput.TextColor3 = C.accent; valInput.PlaceholderText = tostring(val)
    valInput.ClearTextOnFocus = true; valInput.Visible = false; valInput.ZIndex = 10
    local _vis = Instance.new("UIStroke", valInput)
    _vis.Color = C.accent; _vis.Thickness = 1; _vis.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    local _vip = Instance.new("UIPadding", valInput); _vip.PaddingRight = UDim.new(0,4)

    local trackBg = Instance.new("Frame", f)
    -- Track sits at y=30, height=4, giving 10px below for the thumb knob
    trackBg.Size = UDim2.new(1,-20,0,4); trackBg.Position = UDim2.new(0,10,0,30)
    trackBg.BackgroundColor3 = C.trackBg; trackBg.BorderSizePixel = 0; corner(trackBg,2)
    local trackFill = Instance.new("Frame", trackBg)
    trackFill.Size = UDim2.new(math.clamp((val-mn)/(mx-mn),0,1),0,1,0)  -- auto-limited by trackBg clipping
    trackFill.BackgroundColor3 = C.accent; trackFill.BorderSizePixel = 0; corner(trackFill,2)
    reg(trackFill,"BackgroundColor3","accent")
    local thumb = Instance.new("Frame", trackBg)
    thumb.Size = UDim2.new(0,12,0,12); thumb.AnchorPoint = Vector2.new(0.5,0.5)
    local _thumbAlpha = math.clamp((val-mn)/(mx-mn),0,1)
    thumb.Position = UDim2.new(_thumbAlpha, math.round(_thumbAlpha > 0.99 and -4 or (_thumbAlpha < 0.01 and 4 or 0)), 0.5, 0)
    thumb.BackgroundColor3 = C.text; thumb.BorderSizePixel = 0; corner(thumb,4)
    local dragging = false
    local function update(alpha)
        alpha = math.clamp(alpha,0,1)
        local raw = mn + alpha*(mx-mn)
        if step and step > 0 then val = math.floor(raw/step+0.5)*step else val = math.floor(raw*1000+0.5)/1000 end
        val = math.clamp(val,mn,mx)
        trackFill.Size = UDim2.new(alpha,0,1,0)
        local _ta = alpha; thumb.Position = UDim2.new(_ta, math.round(_ta > 0.99 and -4 or (_ta < 0.01 and 4 or 0)), 0.5, 0)
        valLbl.Text = tostring(val); if cb then cb(val) end
    end
    thumb.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 then dragging = true end
    end)
    trackBg.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            update((inp.Position.X - trackBg.AbsolutePosition.X) / trackBg.AbsoluteSize.X)
        end
    end)
    UserInputService.InputChanged:Connect(function(inp)
        if dragging and inp.UserInputType == Enum.UserInputType.MouseMovement then
            update((inp.Position.X - trackBg.AbsolutePosition.X) / trackBg.AbsoluteSize.X)
        end
    end)
    UserInputService.InputEnded:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
    end)

    -- Click on value label -> show TextBox for manual input
    local _valClick = Instance.new("TextButton", f)
    _valClick.Size = valLbl.Size; _valClick.Position = valLbl.Position
    _valClick.BackgroundTransparency = 1; _valClick.Text = ""
    _valClick.ZIndex = valLbl.ZIndex + 2; _valClick.AutoButtonColor = false
    _valClick.MouseButton1Click:Connect(function()
        valInput.Text = tostring(val)
        valInput.Visible = true; valLbl.Visible = false; _valClick.Visible = false
        valInput:CaptureFocus()
    end)
    valInput.FocusLost:Connect(function()
        local n = tonumber(valInput.Text)
        if n then
            n = math.clamp(n, mn, mx)
            if step and step > 0 then n = math.floor(n/step+0.5)*step end
            val = n
            local alpha = math.clamp((val-mn)/(mx-mn),0,1)
            trackFill.Size = UDim2.new(alpha,0,1,0)
            thumb.Position = UDim2.new(alpha,0,0.5,0)
            if cb then cb(val) end
        end
        valLbl.Text = tostring(val)
        valInput.Visible = false; valLbl.Visible = true; _valClick.Visible = true
    end)
    return f
end

function UI.Keybind(parent, name, default, cb)
    local f = Instance.new("Frame", parent)
    f.Size = UDim2.new(1,0,0,28); f.BackgroundColor3 = C.item; f.BorderSizePixel = 0

    local nameLbl = label(f, name, 11, C.text, Enum.Font.Gotham)
    nameLbl.Size = UDim2.new(0.55,0,1,0); nameLbl.Position = UDim2.new(0,8,0,0)

    local btn = Instance.new("TextButton", f)
    btn.Size = UDim2.new(0,80,0,20); btn.Position = UDim2.new(1,-112,0.5,-10)
    btn.BackgroundColor3 = C.border; btn.BorderSizePixel = 0
    btn.Font = Enum.Font.Gotham; btn.TextSize = 11
    btn.TextColor3 = C.textSub; btn.AutoButtonColor = false
    corner(btn, 2)
    local ks = Instance.new("UIStroke", btn)
    ks.Color = Color3.fromRGB(55,55,60); ks.Thickness = 1
    ks.ApplyStrokeMode = Enum.ApplyStrokeMode.Border

    local clearBtn = Instance.new("TextButton", f)
    clearBtn.Size = UDim2.new(0,20,0,20); clearBtn.Position = UDim2.new(1,-26,0.5,-10)
    clearBtn.BackgroundColor3 = Color3.fromRGB(60,20,20); clearBtn.BorderSizePixel = 0
    clearBtn.Text = "X"; clearBtn.Font = Enum.Font.GothamBold; clearBtn.TextSize = 11
    clearBtn.TextColor3 = Color3.fromRGB(200,80,80); clearBtn.AutoButtonColor = false
    corner(clearBtn, 3)
    local cks = Instance.new("UIStroke", clearBtn)
    cks.Color = Color3.fromRGB(100,30,30); cks.Thickness = 1
    cks.ApplyStrokeMode = Enum.ApplyStrokeMode.Border

    local currentKey = default
    local listening = false
    local kbConns = {}  -- store all connections so we can clean up

    local function cleanKey(k)
        if k == nil then return "---" end
        if type(k) == "string" then return k end
        return tostring(k):gsub("Enum%.KeyCode%.",""):gsub("KeyCode%.","")
    end

    local function setKey(k, displayName)
        currentKey = k
        btn.Text = displayName or cleanKey(k)
        btn.BackgroundColor3 = C.border; btn.TextColor3 = C.textSub
        ks.Color = Color3.fromRGB(55,55,60)
        if cb then cb(k) end
    end

    local function clearKey()
        currentKey = nil
        btn.Text = "---"; btn.BackgroundColor3 = C.border
        btn.TextColor3 = C.textDim; ks.Color = Color3.fromRGB(55,55,60)
        if cb then cb(nil) end
    end

    local function stopListening()
        listening = false
        for _, c in ipairs(kbConns) do c:Disconnect() end
        kbConns = {}
        btn.Text = cleanKey(currentKey)
        btn.BackgroundColor3 = C.border
        btn.TextColor3 = currentKey and C.textSub or C.textDim
        ks.Color = Color3.fromRGB(55,55,60)
    end

    btn.Text = cleanKey(default)

    local function startListening()
        if listening then stopListening(); return end
        listening = true
        btn.Text = "..."; btn.BackgroundColor3 = C.item
        btn.TextColor3 = C.accent; ks.Color = C.accent

        -- One connection, no gp filter — catches keyboard AND all mouse buttons
        local c1 = UserInputService.InputBegan:Connect(function(inp)
            if not listening then return end
            local utype = inp.UserInputType
            if utype == Enum.UserInputType.Keyboard then
                local kc = inp.KeyCode
                if kc == Enum.KeyCode.Unknown then return end
                local kname = tostring(kc):gsub("Enum%.KeyCode%.",""):gsub("KeyCode%.","")
                if kname == "Escape" then stopListening(); return end
                setKey(kc, kname); stopListening()
            elseif utype == Enum.UserInputType.MouseButton2 then
                setKey("MB2","MB2"); stopListening()
            elseif utype == Enum.UserInputType.MouseButton3 then
                setKey("MB3","MB3"); stopListening()
            elseif utype == Enum.UserInputType.MouseButton4 then
                setKey("MB4","MB4"); stopListening()
            elseif utype == Enum.UserInputType.MouseButton5 then
                setKey("MB5","MB5"); stopListening()
            end
        end)
        table.insert(kbConns, c1)
    end

    btn.MouseButton1Click:Connect(startListening)

    clearBtn.MouseButton1Click:Connect(function()
        if listening then stopListening() end
        clearKey()
    end)
    clearBtn.MouseEnter:Connect(function()
        TweenService:Create(clearBtn, TweenInfo.new(0.1), {BackgroundColor3=Color3.fromRGB(100,25,25)}):Play()
    end)
    clearBtn.MouseLeave:Connect(function()
        TweenService:Create(clearBtn, TweenInfo.new(0.1), {BackgroundColor3=Color3.fromRGB(60,20,20)}):Play()
    end)
    btn.MouseEnter:Connect(function()
        if not listening then btn.BackgroundColor3=C.item; btn.TextColor3=C.text end
    end)
    btn.MouseLeave:Connect(function()
        if not listening then
            btn.BackgroundColor3=C.border
            btn.TextColor3=currentKey and C.textSub or C.textDim
        end
    end)

    return f
end

local function sep(parent)
    local f = Instance.new("Frame", parent)
    f.Size = UDim2.new(1,0,0,1); f.BackgroundColor3 = C.border; f.BorderSizePixel = 0
    return f
end

function UI.StatusRow(parent, title, getEnabled, onToggle)
    -- Identical to Toggle but drives external state via getEnabled/onToggle
    local PILL_W, PILL_H = 34, 18
    local f = Instance.new("TextButton", parent)
    f.Size = UDim2.new(1,0,0,28); f.BackgroundColor3 = C.item; f.BorderSizePixel = 0
    f.Text = ""; f.AutoButtonColor = false

    local nameLbl = label(f, title, 12, C.text, Enum.Font.Gotham)
    nameLbl.Size = UDim2.new(1,-60,1,0); nameLbl.Position = UDim2.new(0,12,0,0)
    nameLbl.Active = false; nameLbl.Interactable = false

    local pillTrack = Instance.new("Frame", f)
    pillTrack.Size = UDim2.new(0, PILL_W, 0, PILL_H)
    pillTrack.Position = UDim2.new(1, -(PILL_W+10), 0.5, -(PILL_H/2))
    pillTrack.BackgroundColor3 = getEnabled() and C.accent or C.trackBg
    pillTrack.BorderSizePixel = 0; pillTrack.ZIndex = 1; pillTrack.Active = false
    corner(pillTrack, PILL_H/2); strokeInst(pillTrack, C.border, 1)

    local KNOB = PILL_H - 4
    local knob = Instance.new("Frame", pillTrack)
    knob.Size = UDim2.new(0, KNOB, 0, KNOB)
    knob.Position = getEnabled() and UDim2.new(1, -(KNOB+2), 0.5, -(KNOB/2)) or UDim2.new(0, 2, 0.5, -(KNOB/2))
    knob.BackgroundColor3 = Color3.new(1,1,1); knob.BorderSizePixel = 0
    knob.ZIndex = 1; knob.Active = false
    corner(knob, KNOB/2)

    table.insert(accentRegistry, {instance=pillTrack, target="BackgroundColor3", property="accent", isToggle=true, getState=function() return getEnabled() end})

    local function animateSwitch(on)
        local targetPos = on and UDim2.new(1, -(KNOB+2), 0.5, -(KNOB/2)) or UDim2.new(0, 2, 0.5, -(KNOB/2))
        TweenService:Create(knob, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Position=targetPos}):Play()
        TweenService:Create(pillTrack, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {BackgroundColor3=on and C.accent or C.trackBg}):Play()
    end

    f.MouseButton1Click:Connect(function()
        onToggle()
        animateSwitch(getEnabled())
    end)
    return f, function() animateSwitch(getEnabled()) end
end

function UI.StatRow(parent, ltext, vtext)
    local f = Instance.new("Frame", parent)
    f.Size = UDim2.new(1,0,0,22); f.BackgroundColor3 = C.item; f.BorderSizePixel = 0
    local lb = label(f, ltext, 9, C.textSub, Enum.Font.Gotham)
    lb.Size = UDim2.new(0.55,0,1,0); lb.Position = UDim2.new(0,8,0,0)
    local vl = label(f, vtext or "--", 9, C.accent, Enum.Font.GothamBold, Enum.TextXAlignment.Right)
    vl.Size = UDim2.new(0.4,0,1,0); vl.Position = UDim2.new(0.57,0,0,0)
    reg(vl,"TextColor3","accent")
    return f, vl
end

-- ================================================================
-- HSV COLOR PICKER — drag palette, applies in real time
-- ================================================================
function UI.ColorPicker(parent, name, initialColor, cb)
    local pickerOpen = false
    local currentH, currentS, currentV = Color3.toHSV(initialColor or Color3.fromRGB(255,50,50))

    local row = Instance.new("Frame", parent)
    row.Size = UDim2.new(1,0,0,34); row.BackgroundColor3 = C.item; row.BorderSizePixel = 0
    local nameLbl = label(row, name, 11, C.text, Enum.Font.Gotham)
    nameLbl.Size = UDim2.new(0.55,0,1,0); nameLbl.Position = UDim2.new(0,8,0,0)
    local swatch = Instance.new("Frame", row)
    swatch.Size = UDim2.new(0,48,0,18); swatch.Position = UDim2.new(1,-60,0.5,-9)
    swatch.BackgroundColor3 = initialColor or Color3.fromRGB(255,50,50)
    swatch.BorderSizePixel = 0; corner(swatch,4); strokeInst(swatch, C.border, 1)
    local arrowLbl = label(row, "▾", 10, C.textDim, Enum.Font.Gotham, Enum.TextXAlignment.Right)
    arrowLbl.Size = UDim2.new(0,12,1,0); arrowLbl.Position = UDim2.new(1,-14,0,0)
    local toggleBtn = Instance.new("TextButton", row)
    toggleBtn.Size = UDim2.new(1,0,1,0); toggleBtn.BackgroundTransparency=1
    toggleBtn.Text = ""; toggleBtn.AutoButtonColor = false

    local panel = Instance.new("Frame", parent)
    panel.Size = UDim2.new(1,0,0,162); panel.BackgroundColor3 = C.panel
    panel.BorderSizePixel = 0; panel.Visible = false
    strokeInst(panel, C.border, 1)

    local SV_H = 122
    local svOuter = Instance.new("Frame", panel)
    svOuter.Size = UDim2.new(1,-52,0,SV_H); svOuter.Position = UDim2.new(0,6,0,6)
    svOuter.BackgroundColor3 = Color3.fromHSV(currentH,1,1); svOuter.BorderSizePixel=0; corner(svOuter,4)
    svOuter.Active = true
    -- white fade L→R
    local svWhite = Instance.new("Frame", svOuter)
    svWhite.Size = UDim2.new(1,0,1,0); svWhite.BackgroundColor3 = Color3.new(1,1,1); svWhite.BorderSizePixel=0
    svWhite.Active = false
    local wg = Instance.new("UIGradient", svWhite)
    wg.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0,0), NumberSequenceKeypoint.new(1,1)})
    -- black fade T→B
    local svBlack = Instance.new("Frame", svOuter)
    svBlack.Size = UDim2.new(1,0,1,0); svBlack.BackgroundColor3 = Color3.new(0,0,0); svBlack.BorderSizePixel=0
    svBlack.Active = false
    local bg = Instance.new("UIGradient", svBlack)
    bg.Rotation = 90
    bg.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0,1), NumberSequenceKeypoint.new(1,0)})
    -- SV cursor dot
    local svCursor = Instance.new("Frame", svOuter)
    svCursor.Size = UDim2.new(0,10,0,10); svCursor.AnchorPoint = Vector2.new(0.5,0.5)
    svCursor.BackgroundColor3 = Color3.new(1,1,1); svCursor.BorderSizePixel=0; corner(svCursor,6)
    svCursor.Active = false
    strokeInst(svCursor, Color3.new(0,0,0), 1); svCursor.ZIndex = 5

    -- Hue bar right side
    local hueBar = Instance.new("Frame", panel)
    hueBar.Size = UDim2.new(0,18,0,SV_H); hueBar.Position = UDim2.new(1,-28,0,6)
    hueBar.BackgroundColor3 = Color3.new(1,1,1); hueBar.BorderSizePixel=0; corner(hueBar,4)
    hueBar.Active = true
    local hg = Instance.new("UIGradient", hueBar)
    hg.Rotation = 90
    hg.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0,   Color3.fromRGB(255,0,0)),
        ColorSequenceKeypoint.new(1/6, Color3.fromRGB(255,255,0)),
        ColorSequenceKeypoint.new(2/6, Color3.fromRGB(0,255,0)),
        ColorSequenceKeypoint.new(3/6, Color3.fromRGB(0,255,255)),
        ColorSequenceKeypoint.new(4/6, Color3.fromRGB(0,0,255)),
        ColorSequenceKeypoint.new(5/6, Color3.fromRGB(255,0,255)),
        ColorSequenceKeypoint.new(1,   Color3.fromRGB(255,0,0)),
    })
    local hueCursor = Instance.new("Frame", hueBar)
    hueCursor.Size = UDim2.new(1,6,0,4); hueCursor.AnchorPoint = Vector2.new(0.5,0.5)
    hueCursor.BackgroundColor3 = Color3.new(1,1,1); hueCursor.BorderSizePixel=0; corner(hueCursor,2)
    hueCursor.Active = false
    strokeInst(hueCursor, Color3.new(0,0,0), 1); hueCursor.ZIndex=5

    -- Bottom bar: big swatch + hex
    local bottomBar = Instance.new("Frame", panel)
    bottomBar.Size = UDim2.new(1,-12,0,26); bottomBar.Position = UDim2.new(0,6,0,134)
    bottomBar.BackgroundColor3 = C.item; bottomBar.BorderSizePixel=0; corner(bottomBar,4)
    local previewBig = Instance.new("Frame", bottomBar)
    previewBig.Size = UDim2.new(0,32,1,0); previewBig.BackgroundColor3 = swatch.BackgroundColor3
    previewBig.BorderSizePixel=0; corner(previewBig,4)
    local hexLbl = label(bottomBar, "#FFFFFF", 9, C.textDim, Enum.Font.Code)
    hexLbl.Size = UDim2.new(1,-42,1,0); hexLbl.Position = UDim2.new(0,38,0,0)

    local function applyColor()
        local col = Color3.fromHSV(currentH, currentS, currentV)
        swatch.BackgroundColor3      = col
        previewBig.BackgroundColor3  = col
        svOuter.BackgroundColor3     = Color3.fromHSV(currentH,1,1)
        svCursor.Position  = UDim2.new(currentS, 0, 1-currentV, 0)
        hueCursor.Position = UDim2.new(0.5, 0, currentH, 0)
        local r,g,b = math.floor(col.R*255), math.floor(col.G*255), math.floor(col.B*255)
        hexLbl.Text = string.format("#%02X%02X%02X", r, g, b)
        if cb then cb(col) end
    end
    applyColor()

    local draggingSV, draggingHue = false, false
    svOuter.InputBegan:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1 then draggingSV=true
            local p=Vector2.new(i.Position.X,i.Position.Y)
            currentS=math.clamp((p.X-svOuter.AbsolutePosition.X)/svOuter.AbsoluteSize.X,0,1)
            currentV=1-math.clamp((p.Y-svOuter.AbsolutePosition.Y)/svOuter.AbsoluteSize.Y,0,1)
            applyColor()
        end
    end)
    hueBar.InputBegan:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1 then draggingHue=true
            currentH=math.clamp((i.Position.Y-hueBar.AbsolutePosition.Y)/hueBar.AbsoluteSize.Y,0,1)
            applyColor()
        end
    end)
    UserInputService.InputChanged:Connect(function(i)
        if i.UserInputType~=Enum.UserInputType.MouseMovement then return end
        if draggingSV then
            local p=Vector2.new(i.Position.X,i.Position.Y)
            currentS=math.clamp((p.X-svOuter.AbsolutePosition.X)/svOuter.AbsoluteSize.X,0,1)
            currentV=1-math.clamp((p.Y-svOuter.AbsolutePosition.Y)/svOuter.AbsoluteSize.Y,0,1)
            applyColor()
        end
        if draggingHue then
            currentH=math.clamp((i.Position.Y-hueBar.AbsolutePosition.Y)/hueBar.AbsoluteSize.Y,0,1)
            applyColor()
        end
    end)
    UserInputService.InputEnded:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1 then draggingSV=false; draggingHue=false end
    end)
    toggleBtn.MouseButton1Click:Connect(function()
        pickerOpen = not pickerOpen
        panel.Visible = pickerOpen
        arrowLbl.Text = pickerOpen and "▴" or "▾"
    end)
    return row
end

applyAccentColor = function(newColor)
    local r,g,b = newColor.R, newColor.G, newColor.B
    C.accent     = newColor
    C.accentLit  = Color3.new(math.min(r+0.12,1), math.min(g+0.12,1), math.min(b+0.12,1))
    C.accentDark = Color3.new(r*0.38, g*0.38, b*0.38)
    C.borderAcc  = Color3.new(r*0.52, g*0.52, b*0.52)
    for _, entry in ipairs(accentRegistry) do
        if entry.instance and entry.instance.Parent then
            local col
            if entry.property=="accent"     then col=C.accent
            elseif entry.property=="accentLit"  then col=C.accentLit
            elseif entry.property=="accentDark" then col=C.accentDark
            elseif entry.property=="borderAcc"  then col=C.borderAcc end
            if col then
                if entry.isToggle then
                    if entry.getState and entry.getState() then entry.instance[entry.target] = col end
                else
                    entry.instance[entry.target] = col
                end
            end
        end
    end
    silentFovStroke.Color = newColor; uiStroke.Color = newColor
    for _, pg in pairs(Pages) do pg.ScrollBarImageColor3 = C.accentDark end
end

-- =================================================================
-- POPULATE TABS
-- =================================================================

-- ---- CAMLOCK ----
do
    local pg = Pages["Camlock"]
    local _, rfCL = UI.StatusRow(pg, "CamLock", function() return camLockEnabled end, function()
        camLockEnabled = not camLockEnabled
        if not camLockEnabled then isAiming = false; target = nil; resetAimState() end
        updateFOV()
    end)
    sep(pg); UI.Header(pg,"settings"); sep(pg)
    UI.Keybind(pg,"Aim Key",settings.key,function(v) settings.key=v end)
    UI.Toggle(pg,"Toggle Mode",settings.toggle,function(v) settings.toggle=v end)
    UI.Toggle(pg,"Sticky Aim",settings.stickyAim,function(v) settings.stickyAim=v end)
    UI.Toggle(pg,"Knock Check", settings.knockCheck,function(v) settings.knockCheck=v end)
    UI.Toggle(pg,"Team Check",  settings.teamCheck,  function(v) settings.teamCheck=v  end)
    UI.Toggle(pg,"Crew Check",  settings.crewCheck,  function(v) settings.crewCheck=v  end)
    UI.Slider(pg,"Range",settings.range,50,10000,10,function(v) settings.range=v end)
    UI.Slider(pg,"Smoothness",settings.smooth,0.01,1,0.01,function(v) settings.smooth=v end)

    sep(pg); UI.Header(pg,"wall check"); sep(pg)
    UI.Toggle(pg,"Wall Check", settings.wallCheck, function(v)
        settings.wallCheck = v
        pcall(showToast, "Wall Check", v and "enabled — pauses on walls" or "disabled", v and TOAST_GREEN or TOAST_RED, "⬛")
    end)

    sep(pg); UI.Header(pg,"shake"); sep(pg)
    UI.Toggle(pg,"Shake",settings.shakeEnabled,function(v) settings.shakeEnabled=v end)
    UI.Slider(pg,"Shake X",settings.shakeX,0,0.02,0.001,function(v) settings.shakeX=v end)
    UI.Slider(pg,"Shake Y",settings.shakeY,0,0.02,0.001,function(v) settings.shakeY=v end)

    sep(pg); UI.Header(pg,"gun profiles"); sep(pg)
    UI.Toggle(pg,"Gun Profiles",GunProfiles.enabled,function(v)
        GunProfiles.enabled=v
        pcall(showToast,"Gun Profiles", v and "enabled — auto fov/pred per gun" or "disabled", v and TOAST_GREEN or TOAST_RED,"🔫")
    end)

    -- Aim part selector
    sep(pg); UI.Header(pg,"aim part"); sep(pg)
    local clPartNames = {"Head","UpperTorso","LowerTorso","HumanoidRootPart","Torso"}
    local clPartRow = Instance.new("Frame",pg)
    clPartRow.Size = UDim2.new(1,0,0,24); clPartRow.BackgroundColor3 = C.item; clPartRow.BorderSizePixel = 0
    local clPartLbl = label(clPartRow,"Target Part",10,C.textSub,Enum.Font.Gotham)
    clPartLbl.Size = UDim2.new(0.5,0,1,0); clPartLbl.Position = UDim2.new(0,8,0,0)
    local clPartVal = label(clPartRow,camlockAimPart,9,C.text,Enum.Font.GothamBold,Enum.TextXAlignment.Right)
    clPartVal.Size = UDim2.new(0.45,0,1,0); clPartVal.Position = UDim2.new(0.5,-8,0,0)
    local clPartDrop = Instance.new("Frame",pg)
    clPartDrop.Size = UDim2.new(1,0,0,#clPartNames*22)
    clPartDrop.BackgroundColor3 = C.panel; clPartDrop.BorderSizePixel = 0; clPartDrop.Visible = false
    local clPartDropLayout = Instance.new("UIListLayout",clPartDrop)
    clPartDropLayout.SortOrder = Enum.SortOrder.LayoutOrder; clPartDropLayout.Padding = UDim.new(0,1)
    local clPartBtns = {}
    for _, pn in ipairs(clPartNames) do
        local opt = Instance.new("TextButton",clPartDrop)
        opt.Size = UDim2.new(1,0,0,21)
        opt.BackgroundColor3 = (pn==camlockAimPart) and C.accent or C.item
        opt.BorderSizePixel = 0; opt.AutoButtonColor = false; opt.Text = ""
        local ol = label(opt,pn,9,(pn==camlockAimPart) and C.text or C.textSub,Enum.Font.Gotham)
        ol.Size = UDim2.new(1,-8,1,0); ol.Position = UDim2.new(0,8,0,0)
        table.insert(clPartBtns,{btn=opt,lbl=ol})
        opt.MouseButton1Click:Connect(function()
            camlockAimPart = pn
            clPartVal.Text = pn
            clPartDrop.Visible = false
            resetAimState()
            for _, e in ipairs(clPartBtns) do
                local sel = (e.lbl.Text == pn)
                e.btn.BackgroundColor3 = sel and C.accent or C.item
                e.lbl.TextColor3 = sel and C.text or C.textSub
            end
        end)
    end
    local clPClick = Instance.new("TextButton",clPartRow)
    clPClick.Size = UDim2.new(1,0,1,0); clPClick.BackgroundTransparency = 1; clPClick.Text = ""
    clPClick.ZIndex = clPartRow.ZIndex+5; clPClick.AutoButtonColor = false
    clPClick.MouseButton1Click:Connect(function() clPartDrop.Visible = not clPartDrop.Visible end)
end
do
    local pg = Pages["Camlock"]
    sep(pg); UI.Header(pg,"fov"); sep(pg)
    UI.Toggle(pg,"FOV Visible",settings.fovVisible,function(v) settings.fovVisible=v; fovOuter.Visible=v end)
    UI.Slider(pg,"FOV Size",settings.fovSize,10,1000,5,function(v)
        settings.fovSize=v; fovOuter.Size=UDim2.new(0,v,0,v)
    end)
    sep(pg); UI.Header(pg,"prediction"); sep(pg)
    UI.Slider(pg,"Pred X",settings.predictionX,0,1,0.01,function(v) settings.predictionX=v end)
    UI.Slider(pg,"Pred Y",settings.predictionY,0,1,0.01,function(v) settings.predictionY=v end)
    UI.Slider(pg,"Pred Z",settings.predictionZ,0,1,0.01,function(v) settings.predictionZ=v end)
    sep(pg); UI.Header(pg,"easing"); sep(pg)
    UI.StatusRow(pg,"Easing",function() return EasingSettings.enabled end, function()
        EasingSettings.enabled = not EasingSettings.enabled
        resetAimState()
    end)

    -- ── All easing styles grouped by family ──────────────────────
    local easStyleNames = {
        -- Linear
        "Linear",
        -- Sine
        "Sine In","Sine Out","Sine InOut",
        -- Quad
        "Quad In","Quad Out","Quad InOut",
        -- Cubic
        "Cubic In","Cubic Out","Cubic InOut",
        -- Quart
        "Quart In","Quart Out","Quart InOut",
        -- Quint
        "Quint In","Quint Out","Quint InOut",
        -- Exponential
        "Exponential In","Exponential Out","Exponential InOut",
        -- Circular
        "Circular In","Circular Out","Circular InOut",
        -- Back
        "Back In","Back Out","Back InOut",
        -- Elastic
        "Elastic In","Elastic Out","Elastic InOut",
        -- Bounce
        "Bounce In","Bounce Out","Bounce InOut",
    }

    sep(pg)
    -- Style picker row (stays inside the scroll list as normal)
    local easStyleRow = Instance.new("Frame",pg)
    easStyleRow.Size=UDim2.new(1,0,0,24); easStyleRow.BackgroundColor3=C.item; easStyleRow.BorderSizePixel=0
    local easStyleLbl = label(easStyleRow,"Easing Style",10,C.textSub,Enum.Font.Gotham)
    easStyleLbl.Size=UDim2.new(0.5,0,1,0); easStyleLbl.Position=UDim2.new(0,8,0,0)
    local easStyleVal = label(easStyleRow,EasingSettings.style,9,C.text,Enum.Font.GothamBold,Enum.TextXAlignment.Right)
    easStyleVal.Size=UDim2.new(0.45,0,1,0); easStyleVal.Position=UDim2.new(0.5,-8,0,0)
    -- Arrow indicator
    local easArrow = label(easStyleRow,"▸",10,C.textDim,Enum.Font.Gotham,Enum.TextXAlignment.Right)
    easArrow.Size=UDim2.new(0,14,1,0); easArrow.Position=UDim2.new(1,-16,0,0)

    -- Category header colors for visual grouping inside dropdown
    local familyColors = {
        Linear=Color3.fromRGB(150,150,150),
        Sine=Color3.fromRGB(100,180,255), Quad=Color3.fromRGB(100,220,200),
        Cubic=Color3.fromRGB(120,200,120), Quart=Color3.fromRGB(180,220,100),
        Quint=Color3.fromRGB(220,180,80), Exponential=Color3.fromRGB(255,140,60),
        Circular=Color3.fromRGB(200,100,255), Back=Color3.fromRGB(255,80,150),
        Elastic=Color3.fromRGB(255,80,80), Bounce=Color3.fromRGB(255,200,60),
    }
    local function getFamilyColor(name)
        for fam, col in pairs(familyColors) do
            if name:find(fam) then return col end
        end
        return C.textSub
    end

    -- ── FLOATING DROPDOWN — child of Screen (ScreenGui), not the ScrollingFrame ──
    -- This way it renders on top of everything and doesn't push layout elements down.
    local DROP_MAX_H = 320   -- max visible height before it scrolls
    local easDropOuter = Instance.new("Frame", Screen)
    easDropOuter.Size = UDim2.new(0, 200, 0, DROP_MAX_H)
    easDropOuter.BackgroundColor3 = C.panel
    easDropOuter.BorderSizePixel = 0
    easDropOuter.Visible = false
    easDropOuter.ZIndex = 50
    corner(easDropOuter, 4)
    strokeInst(easDropOuter, C.border, 1)

    local easDropScroll = Instance.new("ScrollingFrame", easDropOuter)
    easDropScroll.Size = UDim2.new(1,0,1,0)
    easDropScroll.BackgroundTransparency = 1
    easDropScroll.BorderSizePixel = 0
    easDropScroll.ScrollBarThickness = 3
    easDropScroll.ScrollBarImageColor3 = C.accentDark
    easDropScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    easDropScroll.CanvasSize = UDim2.new(0,0,0,0)
    easDropScroll.ScrollingDirection = Enum.ScrollingDirection.Y
    easDropScroll.ZIndex = 50

    local easDropLayout = Instance.new("UIListLayout", easDropScroll)
    easDropLayout.SortOrder = Enum.SortOrder.LayoutOrder
    easDropLayout.Padding = UDim.new(0,1)

    local easOptBtns = {}
    local lastFamily = nil
    for _, sn in ipairs(easStyleNames) do
        local family = sn:match("^(%a+)")
        if family ~= lastFamily then
            lastFamily = family
            local sep2 = Instance.new("Frame", easDropScroll)
            sep2.Size = UDim2.new(1,0,0,16)
            sep2.BackgroundColor3 = Color3.fromRGB(18,18,22)
            sep2.BorderSizePixel = 0; sep2.ZIndex = 51
            local famLbl = label(sep2, family:upper(), 8, getFamilyColor(sn), Enum.Font.GothamBold)
            famLbl.Size = UDim2.new(1,-8,1,0); famLbl.Position = UDim2.new(0,8,0,0); famLbl.ZIndex = 51
        end

        local opt = Instance.new("TextButton", easDropScroll)
        opt.Size = UDim2.new(1,0,0,22)
        opt.BackgroundColor3 = (sn==EasingSettings.style) and C.accent or C.item
        opt.BorderSizePixel = 0; opt.AutoButtonColor = false; opt.Text = ""
        opt.ZIndex = 51
        local dot = Instance.new("Frame", opt)
        dot.Size = UDim2.new(0,4,0,4); dot.Position = UDim2.new(0,8,0.5,-2)
        dot.BackgroundColor3 = getFamilyColor(sn); dot.BorderSizePixel = 0; dot.ZIndex = 52
        corner(dot, 3)
        local ol = label(opt, sn, 9, (sn==EasingSettings.style) and C.text or C.textSub, Enum.Font.Gotham)
        ol.Size = UDim2.new(1,-20,1,0); ol.Position = UDim2.new(0,18,0,0); ol.ZIndex = 52
        table.insert(easOptBtns, {btn=opt, lbl=ol, dot=dot, name=sn})

        opt.MouseButton1Click:Connect(function()
            EasingSettings.style = sn
            easStyleVal.Text = sn
            easDropOuter.Visible = false
            easArrow.Text = "▸"
            resetAimState()
            for _, e in ipairs(easOptBtns) do
                local s2 = (e.name == sn)
                e.btn.BackgroundColor3 = s2 and C.accent or C.item
                e.lbl.TextColor3 = s2 and C.text or C.textSub
            end
            local isBack    = sn:find("Back")    ~= nil
            local isElastic = sn:find("Elastic") ~= nil
            backPanel.Visible    = isBack    == true
            elasticPanel.Visible = isElastic == true
        end)
    end

    -- Toggle: position the floating dropdown right below the row each time it opens
    local esClick = Instance.new("TextButton", easStyleRow)
    esClick.Size = UDim2.new(1,0,1,0); esClick.BackgroundTransparency = 1; esClick.Text = ""
    esClick.ZIndex = easStyleRow.ZIndex + 5; esClick.AutoButtonColor = false
    esClick.MouseButton1Click:Connect(function()
        local open = not easDropOuter.Visible
        easDropOuter.Visible = open
        easArrow.Text = open and "◂" or "▸"
        if open then
            -- Position the dropdown to the RIGHT of the main panel,
            -- vertically aligned with the row that was clicked.
            local ap  = easStyleRow.AbsolutePosition
            local sz  = easStyleRow.AbsoluteSize
            local mAP = Main.AbsolutePosition
            local mSZ = Main.AbsoluteSize
            local dropW = 200
            -- Prefer right side; fall back to left if off-screen
            local screenW = cam.ViewportSize.X
            local rightOfPanel = mAP.X + mSZ.X + 4
            local leftOfPanel  = mAP.X - dropW - 4
            local posX = rightOfPanel
            if posX + dropW > screenW then posX = leftOfPanel end
            -- Align top with clicked row, clamped to screen height
            local screenH = cam.ViewportSize.Y
            local posY = ap.Y
            if posY + DROP_MAX_H > screenH then posY = screenH - DROP_MAX_H - 4 end
            easDropOuter.Size = UDim2.new(0, dropW, 0, DROP_MAX_H)
            easDropOuter.Position = UDim2.new(0, posX, 0, posY)
        end
    end)

    -- Close dropdown when clicking outside
    UserInputService.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 and easDropOuter.Visible then
            -- Small delay so the row's own click fires first
            task.defer(function()
                local mp = UserInputService:GetMouseLocation()
                local ap = easDropOuter.AbsolutePosition
                local as = easDropOuter.AbsoluteSize
                local inside = mp.X>=ap.X and mp.X<=ap.X+as.X and mp.Y>=ap.Y and mp.Y<=ap.Y+as.Y
                if not inside then
                    easDropOuter.Visible = false
                    easArrow.Text = "▸"
                end
            end)
        end
    end)

    sep(pg)
    -- Global duration slider (applies to all styles)
    UI.Slider(pg,"Duration (s)",EasingSettings.duration,0.01,2,0.01,function(v)
        EasingSettings.duration=v
    end)

    -- ── Jump threshold ───────────────────────────────────────────
    UI.Slider(pg,"Jump Threshold (studs)",_easJumpDist,1,20,0.5,function(v) _easJumpDist=v end)

    -- ── Back config panel (only visible when a Back style is selected) ──
    local backPanel = Instance.new("Frame",pg)
    backPanel.Size=UDim2.new(1,0,0,10); backPanel.BackgroundColor3=C.panel
    backPanel.BorderSizePixel=0; backPanel.AutomaticSize=Enum.AutomaticSize.Y
    backPanel.Visible = EasingSettings.style:find("Back") ~= nil
    local backLayout = Instance.new("UIListLayout",backPanel)
    backLayout.Padding=UDim.new(0,1); backLayout.SortOrder=Enum.SortOrder.LayoutOrder
    do
        local hdr = Instance.new("Frame",backPanel); hdr.Size=UDim2.new(1,0,0,22); hdr.BackgroundColor3=C.item; hdr.BorderSizePixel=0
        local hl = label(hdr,"back settings",9,familyColors.Back,Enum.Font.GothamBold); hl.Size=UDim2.new(1,-8,1,0); hl.Position=UDim2.new(0,8,0,0)
        UI.Slider(backPanel,"Overshoot",EasingSettings.backAmplitude,0.1,5,0.05,function(v)
            EasingSettings.backAmplitude=v
        end)
    end

    -- ── Elastic config panel (only visible when an Elastic style is selected) ──
    local elasticPanel = Instance.new("Frame",pg)
    elasticPanel.Size=UDim2.new(1,0,0,10); elasticPanel.BackgroundColor3=C.panel
    elasticPanel.BorderSizePixel=0; elasticPanel.AutomaticSize=Enum.AutomaticSize.Y
    elasticPanel.Visible = EasingSettings.style:find("Elastic") ~= nil
    local elasticLayout = Instance.new("UIListLayout",elasticPanel)
    elasticLayout.Padding=UDim.new(0,1); elasticLayout.SortOrder=Enum.SortOrder.LayoutOrder
    do
        local hdr = Instance.new("Frame",elasticPanel); hdr.Size=UDim2.new(1,0,0,22); hdr.BackgroundColor3=C.item; hdr.BorderSizePixel=0
        local hl = label(hdr,"elastic settings",9,familyColors.Elastic,Enum.Font.GothamBold); hl.Size=UDim2.new(1,-8,1,0); hl.Position=UDim2.new(0,8,0,0)
        UI.Slider(elasticPanel,"Amplitude",EasingSettings.elasticAmplitude,0.1,5,0.05,function(v)
            EasingSettings.elasticAmplitude=v
        end)
        UI.Slider(elasticPanel,"Frequency",EasingSettings.elasticFrequency,0.1,5,0.1,function(v)
            EasingSettings.elasticFrequency=v
        end)
    end
end
    -- ================================================================
do
    local pg = Pages["Camlock"]
    -- MOUSE LOCK UI
    -- ================================================================
    sep(pg); UI.Header(pg, "mouse lock"); sep(pg)

    -- Master toggle + keybind
    UI.StatusRow(pg, "Mouse Lock", function() return MouseLock.enabled end, function()
        MouseLock.enabled = not MouseLock.enabled
        if not MouseLock.enabled then
            MouseLock.active       = false
            MouseLock.cachedPart   = nil
            MouseLock.cachedCFrame = nil
            MouseLock._smoothCF    = nil
        end
    end)
    UI.Keybind(pg, "Activate Key", MouseLock.key, function(v) MouseLock.key = v end)
    UI.Toggle(pg, "Toggle Mode  (hold vs toggle)", MouseLock.toggle, function(v)
        MouseLock.toggle = v
        if not v then
            MouseLock.active     = false
            MouseLock._smoothCF  = nil
        end
    end)

    -- ── Aim bone ──────────────────────────────────────────────────────────
    sep(pg); UI.Header(pg, "aim bone"); sep(pg)
    local mlBones  = {"Head", "HumanoidRootPart", "Nearest"}
    local mlBoneDots, mlBoneLabels = {}, {}
    for _, bn in ipairs(mlBones) do
        local row = Instance.new("Frame", pg)
        row.Size = UDim2.new(1,0,0,26); row.BackgroundColor3 = C.item; row.BorderSizePixel = 0
        local dot = Instance.new("Frame", row)
        dot.Size = UDim2.new(0,6,0,6); dot.Position = UDim2.new(0,8,0.5,-3)
        local isActive = MouseLock.aimPart == bn
        dot.BackgroundColor3 = isActive and C.accent or C.textDim
        dot.BorderSizePixel = 0; corner(dot, 4)
        local lbl = label(row, bn == "Nearest" and "Nearest Part to cursor" or bn,
                          10, isActive and C.text or C.textSub, Enum.Font.Gotham)
        lbl.Size = UDim2.new(1,-20,1,0); lbl.Position = UDim2.new(0,20,0,0)
        mlBoneDots[bn]   = dot
        mlBoneLabels[bn] = lbl
        local btn = Instance.new("TextButton", row)
        btn.Size = UDim2.new(1,0,1,0); btn.BackgroundTransparency = 1
        btn.Text = ""; btn.AutoButtonColor = false
        btn.MouseButton1Click:Connect(function()
            MouseLock.aimPart = bn
            for _, b in ipairs(mlBones) do
                local on = (b == bn)
                mlBoneDots[b].BackgroundColor3   = on and C.accent   or C.textDim
                mlBoneLabels[b].TextColor3        = on and C.text     or C.textSub
            end
        end)
    end

    -- ── Motion ────────────────────────────────────────────────────────────
    sep(pg); UI.Header(pg, "motion"); sep(pg)
    UI.Slider(pg, "Smoothness", MouseLock.smooth, 0.01, 1, 0.01, function(v)
        MouseLock.smooth = v
    end)
    UI.Slider(pg, "Frame Skip  (0 = off,  1 = instant TP)", MouseLock.frameSkip, 0, 30, 1, function(v)
        MouseLock.frameSkip    = v
        MouseLock._skipCounter = 0
    end)
    UI.Slider(pg, "Prediction", MouseLock.prediction, 0, 0.35, 0.005, function(v)
        MouseLock.prediction = v
    end)
    UI.Slider(pg, "Hit Chance (%)", MouseLock.hitChance, 1, 100, 1, function(v)
        MouseLock.hitChance = v
    end)

    -- ── Filters ───────────────────────────────────────────────────────────
    sep(pg); UI.Header(pg, "filters"); sep(pg)
    UI.Toggle(pg, "Check FOV",   MouseLock.checkFOV,   function(v) MouseLock.checkFOV   = v end)
    UI.Slider(pg, "FOV Size", MouseLock.fovSize, 10, 1500, 10, function(v) MouseLock.fovSize = v end)
    UI.Toggle(pg, "Check Range", MouseLock.checkRange,  function(v) MouseLock.checkRange  = v end)
    UI.Slider(pg, "Range",    MouseLock.range, 50, 3000, 50, function(v) MouseLock.range    = v end)
    UI.Toggle(pg, "Check Knock", MouseLock.checkKnock,  function(v) MouseLock.checkKnock  = v end)

    -- ── Live status ───────────────────────────────────────────────────────
    sep(pg); UI.Header(pg, "status"); sep(pg)
    local _, mlStatusVal  = UI.StatRow(pg, "State",  "inactive")
    local _, mlTargetVal  = UI.StatRow(pg, "Target", "none")
    RunService.RenderStepped:Connect(function()
        if not MouseLock.enabled then
            mlStatusVal.Text = "disabled";  mlStatusVal.TextColor3 = C.textDim
            mlTargetVal.Text = "none";      mlTargetVal.TextColor3 = C.textDim
        elseif MouseLock.active then
            mlStatusVal.Text = "ACTIVE";    mlStatusVal.TextColor3 = Color3.fromRGB(80,255,120)
            if MouseLock.cachedChar then
                local p = Players:GetPlayerFromCharacter(MouseLock.cachedChar)
                mlTargetVal.Text = p and p.Name or (MouseLock.cachedChar.Name or "NPC")
                mlTargetVal.TextColor3 = C.accent
            else
                mlTargetVal.Text = "searching..."; mlTargetVal.TextColor3 = C.textSub
            end
        else
            mlStatusVal.Text = "idle (key not held)"; mlStatusVal.TextColor3 = C.textSub
            mlTargetVal.Text = "none"; mlTargetVal.TextColor3 = C.textDim
        end
    end)

end
-- ---- SILENT ----
do
    local pg = Pages["Silent"]

    -- Main on/off
    UI.StatusRow(pg, "Silent Aim", function() return SilentAimV2.enabled end, function()
        SilentAimV2.enabled = not SilentAimV2.enabled
        if not SilentAimV2.enabled then
            SilentAimV2.cachedPart   = nil
            SilentAimV2.cachedCFrame = nil
            SilentAimV2.cachedChar   = nil
        end
    end)

    sep(pg)
    UI.Slider(pg, "Hit Chance (%)", SilentAimV2.hitChance, 1, 100, 1, function(v)
        SilentAimV2.hitChance = v
    end)
    UI.Slider(pg, "Prediction", SilentAimV2.prediction, 0, 0.35, 0.005, function(v)
        SilentAimV2.prediction = v
    end)

    -- ── Aim point ─────────────────────────────────────────────────────────
    sep(pg); UI.Header(pg, "aim point"); sep(pg)

    local function makeRadioRow(parent, active, txt)
        local row = Instance.new("Frame", parent)
        row.Size = UDim2.new(1,0,0,28); row.BackgroundColor3 = C.item; row.BorderSizePixel = 0
        local dot = Instance.new("Frame", row)
        dot.Size = UDim2.new(0,7,0,7); dot.Position = UDim2.new(0,10,0.5,-3.5)
        dot.BackgroundColor3 = active and C.accent or C.textDim; dot.BorderSizePixel = 0
        corner(dot, 4)
        local lbl = label(row, txt, 11, active and C.text or C.textSub, Enum.Font.Gotham)
        lbl.Size = UDim2.new(1,-26,1,0); lbl.Position = UDim2.new(0,24,0,0)
        local btn = Instance.new("TextButton", row)
        btn.Size = UDim2.new(1,0,1,0); btn.BackgroundTransparency = 1
        btn.Text = ""; btn.AutoButtonColor = false
        return dot, lbl, btn
    end

    local headDot, headLbl, headBtn = makeRadioRow(pg, true,  "Head  (default)")
    local npDot,   npLbl,   npBtn   = makeRadioRow(pg, false, "Nearest Part to cursor")

    headBtn.MouseButton1Click:Connect(function()
        SilentAimV2.nearestPart  = false
        headDot.BackgroundColor3 = C.accent;  headLbl.TextColor3 = C.text
        npDot.BackgroundColor3   = C.textDim; npLbl.TextColor3   = C.textSub
    end)
    npBtn.MouseButton1Click:Connect(function()
        SilentAimV2.nearestPart  = true
        npDot.BackgroundColor3   = C.accent;  npLbl.TextColor3   = C.text
        headDot.BackgroundColor3 = C.textDim; headLbl.TextColor3 = C.textSub
    end)

    -- ── FOV ───────────────────────────────────────────────────────────────
    sep(pg); UI.Header(pg, "fov"); sep(pg)
    UI.Toggle(pg, "Silent FOV Visible", silentFovVisible, function(v)
        silentFovVisible = v; silentFovOuter.Visible = v
    end)
    UI.Slider(pg, "Silent FOV Size", silentFovSize, 10, 1000, 5, function(v)
        silentFovSize = v; silentFovOuter.Size = UDim2.new(0,v,0,v)
    end)
    UI.Toggle(pg, "Use DynFOV", silentUseDynFOV, function(v)
        silentUseDynFOV = v
        if not v then silentFovOuter.Size = UDim2.new(0,silentFovSize,0,silentFovSize) end
    end)

    -- ── Filters ───────────────────────────────────────────────────────────
    sep(pg); UI.Header(pg, "filters"); sep(pg)
    UI.Toggle(pg, "Check FOV",   SilentAimV2.checkFOV,   function(v) SilentAimV2.checkFOV   = v end)
    UI.Toggle(pg, "Check Range", SilentAimV2.checkRange,  function(v) SilentAimV2.checkRange  = v end)
    UI.Toggle(pg, "Check Knock", SilentAimV2.checkKnock,  function(v) SilentAimV2.checkKnock  = v end)
    UI.Toggle(pg, "Team Check",  SilentAimV2.teamCheck,   function(v) SilentAimV2.teamCheck   = v end)
    UI.Toggle(pg, "Crew Check",  SilentAimV2.crewCheck,   function(v) SilentAimV2.crewCheck   = v end)
    UI.Toggle(pg, "Wall Check",  SilentAimV2.wallCheck,   function(v)
        SilentAimV2.wallCheck = v
        pcall(showToast,"Wall Check", v and "enabled — won't redirect thru walls" or "disabled", v and TOAST_GREEN or TOAST_RED,"⬛")
    end)

    -- ── Live status ───────────────────────────────────────────────────────
    sep(pg); UI.Header(pg, "status"); sep(pg)
    local _, statusVal = UI.StatRow(pg, "Target", "none")
    RunService.RenderStepped:Connect(function()
        if not SilentAimV2.enabled then
            statusVal.Text = "disabled"; statusVal.TextColor3 = C.textDim
        elseif SilentAimV2.cachedChar then
            local p = Players:GetPlayerFromCharacter(SilentAimV2.cachedChar)
            statusVal.Text = p and p.Name or (SilentAimV2.cachedChar.Name or "NPC")
            statusVal.TextColor3 = C.accent
        else
            statusVal.Text = "no target"; statusVal.TextColor3 = C.textSub
        end
    end)
end

-- ---- DYNFOV ----
do
    local pg = Pages["DynFOV"]
    UI.StatusRow(pg,"Dynamic FOV",function() return DynamicFOV.enabled end,function()
        DynamicFOV.enabled=not DynamicFOV.enabled
        if not DynamicFOV.enabled then fovOuter.Size=UDim2.new(0,150,0,150); settings.fovSize=150; DynamicFOV.currentFOV=150; uiStroke.Color=Color3.fromRGB(70,70,70) end
    end)
    UI.Toggle(pg,"Show Zone Label",DynamicFOV.showZoneLabel,function(v) DynamicFOV.showZoneLabel=v end)
    sep(pg)
    local zoneCards = {
        {key="close", title="CLOSE", color=zoneColors.CLOSE, defMax=30 },
        {key="medium",title="MEDIUM",color=zoneColors.MEDIUM,defMax=80 },
        {key="far",   title="FAR",   color=zoneColors.FAR,   defMax=150},
        {key="sniper",title="SNIPER",color=zoneColors.SNIPER,defMax=nil},
    }
    local zoneMaxLabels = {}
    for i, z in ipairs(zoneCards) do
        UI.Header(pg,z.title.." zone"); sep(pg)
        if z.defMax ~= nil then
            UI.Slider(pg,"Distance Limit",DynamicFOV.zones[z.key].maxDist,5,999,5,function(v)
                DynamicFOV.zones[z.key].maxDist=v
                for j, zj in ipairs(zoneCards) do
                    if zoneMaxLabels[zj.key] then
                        local p2 = j>1 and DynamicFOV.zones[zoneCards[j-1].key].maxDist or 0
                        local c2 = DynamicFOV.zones[zj.key].maxDist
                        zoneMaxLabels[zj.key].Text = zj.defMax==nil and string.format(">%d studs",p2) or string.format("%d-%d studs",p2,c2)
                    end
                end
            end)
        end
        UI.Slider(pg,"FOV Size",DynamicFOV.zones[z.key].fovSize,1,3000,1,function(v) DynamicFOV.zones[z.key].fovSize=v end)
        sep(pg)
    end

    local dynHUD = Instance.new("Frame",fovScreen)
    dynHUD.Size=UDim2.new(0,140,0,32); dynHUD.BackgroundColor3=Color3.fromRGB(14,14,14)
    dynHUD.BackgroundTransparency=0.2; dynHUD.BorderSizePixel=0; dynHUD.Visible=false; corner(dynHUD,3)
    local dynHudStroke = strokeInst(dynHUD,C.accent,1); reg(dynHudStroke,"Color","accent")
    local zoneHudLbl = label(dynHUD,"ZONE: --",9,C.accentLit,Enum.Font.GothamBold,Enum.TextXAlignment.Center)
    zoneHudLbl.Size=UDim2.new(1,0,0.5,0); reg(zoneHudLbl,"TextColor3","accentLit")
    local distHudLbl = label(dynHUD,"--",8,C.textSub,Enum.Font.Gotham,Enum.TextXAlignment.Center)
    distHudLbl.Size=UDim2.new(1,0,0.5,0); distHudLbl.Position=UDim2.new(0,0,0.5,0)

    RunService.RenderStepped:Connect(function()
        if not DynamicFOV.enabled then return end
        local lr = char and char:FindFirstChild("HumanoidRootPart"); if not lr then return end

        -- DynFOV usa el mismo target que el silent aim.
        -- getSilentTarget() devuelve el char más cercano al cursor dentro del FOV del silent.
        -- Si silent no está activo, cae en el enemy más cercano en distancia 3D.
        local silentChar = getSilentTarget()
        local dynHRP = silentChar and (silentChar:FindFirstChild("HumanoidRootPart") or silentChar:FindFirstChild("Head"))

        -- Si getSilentTarget no encontró nada (silent off o sin enemies en FOV),
        -- buscar cualquier enemy visible frente a la cámara
        if not dynHRP then
            local minDist = math.huge
            for _, e in pairs(getAllEnemyChars()) do
                local c, hrp = e.char, e.hrp
                if not hrp then continue end
                if isKnockedOrDead(c) then continue end
                local sp = cam:WorldToViewportPoint(hrp.Position)
                if sp.Z <= 0 then continue end
                local d = (lr.Position - hrp.Position).Magnitude
                if d < minDist then minDist = d; dynHRP = hrp end
            end
        end

        if not dynHRP then
            -- Sin ningún enemy: resetear al fov manual del silent y ocultar HUD
            local fallback = silentFovSize
            silentFovSize = fallback
            silentFovOuter.Size = UDim2.new(0, fallback, 0, fallback)
            dynHUD.Visible = false
            return
        end

        local dist = (lr.Position - dynHRP.Position).Magnitude
        local zones = DynamicFOV.zones
        local sorted = {
            {name="CLOSE",  d=zones.close},
            {name="MEDIUM", d=zones.medium},
            {name="FAR",    d=zones.far},
            {name="SNIPER", d=zones.sniper},
        }

        -- Selección de zona — cambio instantáneo, sin lerp
        local newFOV, zoneName = sorted[#sorted].d.fovSize, "SNIPER"
        if dist <= sorted[1].d.maxDist then
            newFOV = sorted[1].d.fovSize; zoneName = "CLOSE"
        else
            for i = 1, #sorted-1 do
                local zA, zB = sorted[i], sorted[i+1]
                if dist > zA.d.maxDist and dist <= zB.d.maxDist then
                    newFOV = zB.d.fovSize; zoneName = zB.name; break
                end
            end
        end

        -- Aplicar al silent FOV directamente (sin transición)
        -- silentFovSize es la variable que getSilentTarget usa para el radio del FOV
        silentFovSize = newFOV
        silentFovOuter.Size = UDim2.new(0, newFOV, 0, newFOV)
        -- settings.fovSize también se actualiza para que el camlock lo use si está activo
        settings.fovSize = newFOV

        local zc = zoneColors[zoneName] or C.accent
        silentFovStroke.Color = zc  -- el círculo rojo del silent cambia de color según zona

        if DynamicFOV.showZoneLabel then
            dynHUD.Visible = true
            dynHUD.Position = UDim2.new(0.5,-70,0.5, newFOV/2+6)
            zoneHudLbl.Text = "ZONE: "..zoneName; zoneHudLbl.TextColor3 = zc
            distHudLbl.Text = string.format("dist: %d  fov: %d", math.floor(dist), newFOV)
            dynHudStroke.Color = zc
        else
            dynHUD.Visible = false
        end
    end)
end

-- ---- TRIGGER ----
do
    local pg = Pages["Trigger"]
    UI.Toggle(pg,"Trigger Bot",TriggerBot.enabled,function(v)
        TriggerBot.enabled = v
        if not v then TriggerBot.toggled = false end
    end)
    sep(pg); UI.Header(pg,"settings"); sep(pg)
    UI.Slider(pg,"Fire Interval (s)",TriggerBot.interval,0.0001,1,0.0001,function(v) TriggerBot.interval=v end)
    UI.Slider(pg,"Hitbox Size (px)",TriggerBot.hitboxSize,0.1,30,0.1,function(v) TriggerBot.hitboxSize=v; refreshBoxSizes() end)
    sep(pg); UI.Header(pg,"tool checks"); sep(pg)
    UI.Toggle(pg,"Knife Check (stop on knife)",TriggerBot.knifeCheck,function(v) TriggerBot.knifeCheck=v end)
    UI.Toggle(pg,"Knock Check (ignore downed players)",TriggerBot.knockCheck,function(v) TriggerBot.knockCheck=v end)
    sep(pg); UI.Header(pg,"activation"); sep(pg)
    UI.Keybind(pg,"Key",TriggerBot.key,function(v) TriggerBot.key=v end)
    local tbModeFrames={}; local tbModeOptions={"Hold","Toggle"}; local tbModeSelected=1
    local function applyTBMode(idx)
        tbModeSelected=idx
        if idx==1 then TriggerBot.requireKey=true; TriggerBot.toggleMode=false; TriggerBot.toggled=false
        elseif idx==2 then TriggerBot.requireKey=true; TriggerBot.toggleMode=true; TriggerBot.toggled=false end
        for i, fr in ipairs(tbModeFrames) do
            local l2=fr:FindFirstChildWhichIsA("TextLabel"); if l2 then l2.TextColor3=(i==idx) and C.text or C.textSub end
            local d2=fr:FindFirstChildWhichIsA("Frame"); if d2 then d2.BackgroundColor3=(i==idx) and C.accent or C.trackBg end
        end
    end
    local tbModeOuter=Instance.new("Frame",pg); tbModeOuter.Size=UDim2.new(1,0,0,28); tbModeOuter.BackgroundColor3=C.item; tbModeOuter.BorderSizePixel=0
    local tbModeHint=label(tbModeOuter,"Mode:",9,C.textSub,Enum.Font.Gotham); tbModeHint.Size=UDim2.new(0,45,1,0); tbModeHint.Position=UDim2.new(0,8,0,0)
    local tbModeInner=Instance.new("Frame",tbModeOuter); tbModeInner.Size=UDim2.new(1,-58,1,0); tbModeInner.Position=UDim2.new(0,54,0,0); tbModeInner.BackgroundTransparency=1
    local tbML=Instance.new("UIListLayout",tbModeInner); tbML.FillDirection=Enum.FillDirection.Horizontal; tbML.Padding=UDim.new(0,4); tbML.SortOrder=Enum.SortOrder.LayoutOrder; tbML.VerticalAlignment=Enum.VerticalAlignment.Center
    for i, mn in ipairs(tbModeOptions) do
        local fr=Instance.new("TextButton",tbModeInner); fr.Size=UDim2.new(0,76,0,18); fr.BackgroundColor3=C.item; fr.BorderSizePixel=0; fr.Text=""; fr.AutoButtonColor=false; corner(fr,3); strokeInst(fr,C.border,1)
        local d2=Instance.new("Frame",fr); d2.Size=UDim2.new(0,5,0,5); d2.Position=UDim2.new(0,5,0.5,-2); d2.BackgroundColor3=(i==1) and C.accent or C.trackBg; d2.BorderSizePixel=0; corner(d2,4)
        local l2=label(fr,mn,8,(i==1) and C.text or C.textSub,Enum.Font.Gotham); l2.Size=UDim2.new(1,-13,1,0); l2.Position=UDim2.new(0,13,0,0)
        table.insert(tbModeFrames,fr); fr.MouseButton1Click:Connect(function() applyTBMode(i) end)
    end
    sep(pg); UI.Header(pg,"hitbox visualizer"); sep(pg)
    UI.StatusRow(pg,"Hitbox Visualizer",function() return HitboxVisualizer.enabled end,function()
        HitboxVisualizer.enabled=not HitboxVisualizer.enabled
        if not HitboxVisualizer.enabled then clearHitboxes(); hvCurrentTarget=nil end
    end)
end

-- ---- MISC ----
do
    local pg = Pages["Misc"]
    UI.Header(pg,"speed hack"); sep(pg)
    UI.StatusRow(pg,"Speed Hack",function() return SpeedHack.enabled end,function()
        SpeedHack.enabled=not SpeedHack.enabled
        local hum=char and char:FindFirstChild("Humanoid")
        if not SpeedHack.enabled and hum then hum.WalkSpeed=16 end
    end)
    UI.Slider(pg,"Walk Speed",SpeedHack.speed,16,1000,1,function(v) SpeedHack.speed=v end)
    UI.Keybind(pg,"Toggle Key",SpeedHack.key,function(v) SpeedHack.key=v end)
    sep(pg); UI.Header(pg,"db sniper"); sep(pg)
    local dbIntRow
    UI.Toggle(pg,"DB Sniper Enabled",DBSniper.enabled,function(v) DBSniper.enabled=v; if dbIntRow then dbIntRow.Visible=v end end)
    dbIntRow=UI.Slider(pg,"Accuracy (0=natural  1=no spread)",DBSniper.intensity,0,1,0.01,function(v) DBSniper.intensity=v end)
    dbIntRow.Visible=DBSniper.enabled
    sep(pg); UI.Header(pg,"tactical sniper"); sep(pg)
    local tactIntRow
    UI.Toggle(pg,"Tactical Sniper Enabled",TacticalSniper.enabled,function(v) TacticalSniper.enabled=v; if tactIntRow then tactIntRow.Visible=v end end)
    tactIntRow=UI.Slider(pg,"Accuracy (0=natural  1=no spread)",TacticalSniper.intensity,0,1,0.01,function(v) TacticalSniper.intensity=v end)
    tactIntRow.Visible=TacticalSniper.enabled
    sep(pg); UI.Header(pg,"fly"); sep(pg)
    UI.StatusRow(pg,"Fly",function() return Fly.enabled end,function()
        Fly.enabled=not Fly.enabled; if Fly.enabled then startFly() else stopFly() end
    end)
    UI.Slider(pg,"Fly Speed",Fly.speed,10,500,5,function(v) Fly.speed=v end)
    local fhRow=Instance.new("Frame",pg); fhRow.Size=UDim2.new(1,0,0,22); fhRow.BackgroundColor3=C.item; fhRow.BorderSizePixel=0
    local fhLbl=label(fhRow,"WASD move  |  Space up  |  Ctrl/C down",8,C.textDim,Enum.Font.Gotham)
    fhLbl.Size=UDim2.new(1,-8,1,0); fhLbl.Position=UDim2.new(0,8,0,0); fhLbl.TextWrapped=true
    sep(pg); UI.Header(pg,"noclip"); sep(pg)
    UI.StatusRow(pg,"No Clip",function() return NoClip.enabled end,function()
        NoClip.enabled = not NoClip.enabled
        if NoClip.enabled then
            startNoClip()
        else
            if ncConn then ncConn:Disconnect(); ncConn = nil end
            updateNoClip()  -- restore collision
        end
    end)
    local ncInfoRow = Instance.new("Frame",pg)
    ncInfoRow.Size=UDim2.new(1,0,0,20); ncInfoRow.BackgroundColor3=C.item; ncInfoRow.BorderSizePixel=0
    local ncInfoLbl=label(ncInfoRow,"Atraviesa paredes y suelo — activo durante strafe",8,C.textDim,Enum.Font.Gotham)
    ncInfoLbl.Size=UDim2.new(1,-8,1,0); ncInfoLbl.Position=UDim2.new(0,8,0,0); ncInfoLbl.TextWrapped=true

    -- Target Lock
    sep(pg); UI.Header(pg,"target lock"); sep(pg)
    UI.StatusRow(pg,"Target Lock",function() return TargetLock.masterEnabled end,function()
        TargetLock.masterEnabled = not TargetLock.masterEnabled
        if not TargetLock.masterEnabled then
            TargetLock.enabled = false
            tlLockOn(nil)
            if TargetLock.showToasts then showToast("Target Lock", "disabled", TOAST_PURPLE, "🔓") end
        else
            if TargetLock.showToasts then showToast("Target Lock", "enabled", TOAST_BLUE, "🔒") end
        end
    end)
    -- Keybind
    local _tlKeyRow = Instance.new("Frame",pg)
    _tlKeyRow.Size=UDim2.new(1,0,0,34); _tlKeyRow.BackgroundColor3=C.item; _tlKeyRow.BorderSizePixel=0
    local _tlKeyLbl=label(_tlKeyRow,"Toggle Key",12,C.text,Enum.Font.Gotham)
    _tlKeyLbl.Size=UDim2.new(0.55,0,1,0); _tlKeyLbl.Position=UDim2.new(0,12,0,0)
    local _tlKeyBtn=Instance.new("TextButton",_tlKeyRow)
    _tlKeyBtn.Size=UDim2.new(0,90,0,22); _tlKeyBtn.Position=UDim2.new(1,-98,0.5,-11)
    _tlKeyBtn.BackgroundColor3=C.accentDark; _tlKeyBtn.BorderSizePixel=0; corner(_tlKeyBtn,3)
    _tlKeyBtn.Text=TargetLock.key and TargetLock.key.Name or "NONE"
    _tlKeyBtn.Font=Enum.Font.GothamBold; _tlKeyBtn.TextSize=10; _tlKeyBtn.TextColor3=C.accentLit
    _tlKeyBtn.AutoButtonColor=false
    local _tlWaiting=false
    _tlKeyBtn.MouseButton1Click:Connect(function()
        if _tlWaiting then return end
        _tlWaiting=true; _tlKeyBtn.Text="..."; _tlKeyBtn.TextColor3=C.textSub
        local conn; conn=UserInputService.InputBegan:Connect(function(inp2,gp2)
            if gp2 then return end
            if inp2.UserInputType==Enum.UserInputType.Keyboard then
                TargetLock.key=inp2.KeyCode
                _tlKeyBtn.Text=inp2.KeyCode.Name; _tlKeyBtn.TextColor3=C.accentLit
                _tlWaiting=false; conn:Disconnect()
            end
        end)
    end)
    sep(pg); UI.Header(pg,"target lock visuals"); sep(pg)
    UI.Toggle(pg,"Show Line to Target", TargetLock.showLine, function(v)
        TargetLock.showLine = v
        if not v then tlLine.Visible = false end
    end)
    UI.Toggle(pg,"Show Target Outline", TargetLock.showOutline, function(v)
        TargetLock.showOutline = v
        if not v then tlHighlight.Enabled = false end
    end)
    UI.Toggle(pg,"Show Notifications", TargetLock.showToasts, function(v)
        TargetLock.showToasts = v
    end)
    local _tlInfoRow=Instance.new("Frame",pg)
    _tlInfoRow.Size=UDim2.new(1,0,0,22); _tlInfoRow.BackgroundColor3=C.item; _tlInfoRow.BorderSizePixel=0
    local _tlInfoLbl=label(_tlInfoRow,"Todos los disparos van al target — sin importar donde apuntes",8,C.textDim,Enum.Font.Gotham)
    _tlInfoLbl.Size=UDim2.new(1,-8,1,0); _tlInfoLbl.Position=UDim2.new(0,8,0,0); _tlInfoLbl.TextWrapped=true
end





-- ---- ESP ----
do
    local pg = Pages["ESP"]
    UI.StatusRow(pg,"ESP",function() return ESP.enabled end,function()
        ESP.enabled = not ESP.enabled
        if not ESP.enabled then clearAllESP() end
    end)
    sep(pg); UI.Header(pg,"features"); sep(pg)
    UI.Toggle(pg,"Boxes",           ESP.boxes,       function(v) ESP.boxes=v       end)
    UI.Toggle(pg,"Names",           ESP.names,       function(v) ESP.names=v       end)
    UI.Toggle(pg,"Health Bars",     ESP.healthBars,  function(v) ESP.healthBars=v  end)
    UI.Toggle(pg,"Distance",        ESP.distance,    function(v) ESP.distance=v    end)
    UI.Toggle(pg,"Tracers",         ESP.tracers,     function(v) ESP.tracers=v     end)
    UI.Toggle(pg,"Skeleton",        ESP.skeleton,    function(v) ESP.skeleton=v    end)
    UI.Toggle(pg,"Chams",           ESP.chams,       function(v) ESP.chams=v       end)
    sep(pg); UI.Header(pg,"settings"); sep(pg)
    UI.Slider(pg,"Max Distance",ESP.maxDist,50,2000,50,function(v) ESP.maxDist=v end)
    sep(pg); UI.Header(pg,"colors"); sep(pg)

    -- HSV Color pickers for each ESP element
    UI.ColorPicker(pg, "Box Color",      ESP.boxColor,      function(c)
        ESP.boxColor = c
        for _, obj in pairs(espObjects) do
            for _, l in ipairs(obj.box) do l.BackgroundColor3 = c end
        end
    end)
    UI.ColorPicker(pg, "Tracer Color",   ESP.tracerColor,   function(c)
        ESP.tracerColor = c
        for _, obj in pairs(espObjects) do obj.tracer.BackgroundColor3 = c end
    end)
    UI.ColorPicker(pg, "Skeleton Color", ESP.skeletonColor, function(c)
        ESP.skeletonColor = c
        for _, obj in pairs(espObjects) do
            for _, b in ipairs(obj.bones) do b.BackgroundColor3 = c end
        end
    end)
    UI.ColorPicker(pg, "Chams Color",    ESP.chamColor,     function(c)
        ESP.chamColor = c
        for _, obj in pairs(espObjects) do
            obj.highlight.Color3 = c
            obj.highlight.SurfaceColor3 = c
        end
    end)
end

-- ---- VISUALS ----
do
    local pg = Pages["Visuals"]

    -- Fullbright
    local Fullbright = { enabled = false, brightness = 5 }
    local _fullbrightConn = nil
    local _origLighting = {}

    local function applyFullbright(on)
        local Lighting = game:GetService("Lighting")
        if on then
            _origLighting.Brightness   = Lighting.Brightness
            _origLighting.Ambient      = Lighting.Ambient
            _origLighting.OutdoorAmbient = Lighting.OutdoorAmbient
            _origLighting.FogEnd       = Lighting.FogEnd
            Lighting.Brightness        = Fullbright.brightness
            Lighting.Ambient           = Color3.new(1,1,1)
            Lighting.OutdoorAmbient    = Color3.new(1,1,1)
            Lighting.FogEnd            = 100000
        else
            if _origLighting.Brightness then
                Lighting.Brightness      = _origLighting.Brightness
                Lighting.Ambient         = _origLighting.Ambient
                Lighting.OutdoorAmbient  = _origLighting.OutdoorAmbient
                Lighting.FogEnd          = _origLighting.FogEnd
            end
        end
    end

    UI.Header(pg, "fullbright"); sep(pg)
    UI.StatusRow(pg, "Fullbright", function() return Fullbright.enabled end, function()
        Fullbright.enabled = not Fullbright.enabled
        applyFullbright(Fullbright.enabled)
    end)
    UI.Slider(pg, "Brightness Level", Fullbright.brightness, 1, 10, 0.5, function(v)
        Fullbright.brightness = v
        if Fullbright.enabled then
            game:GetService("Lighting").Brightness = v
        end
    end)

    -- Remove Fog
    local RemoveFog = { enabled = false }
    sep(pg); UI.Header(pg, "fog"); sep(pg)
    UI.StatusRow(pg, "Remove Fog", function() return RemoveFog.enabled end, function()
        RemoveFog.enabled = not RemoveFog.enabled
        local Lighting = game:GetService("Lighting")
        if RemoveFog.enabled then
            Lighting.FogEnd = 100000
            Lighting.FogStart = 100000
        else
            Lighting.FogEnd = 1000
            Lighting.FogStart = 0
        end
    end)

    -- Third Person FOV (Camera zoom)
    local ThirdPersonFOV = { enabled = false, fov = 70 }
    sep(pg); UI.Header(pg, "camera fov"); sep(pg)
    UI.StatusRow(pg, "Custom Camera FOV", function() return ThirdPersonFOV.enabled end, function()
        ThirdPersonFOV.enabled = not ThirdPersonFOV.enabled
        if not ThirdPersonFOV.enabled then cam.FieldOfView = 70 end
    end)
    UI.Slider(pg, "Field of View", ThirdPersonFOV.fov, 40, 120, 1, function(v)
        ThirdPersonFOV.fov = v
        if ThirdPersonFOV.enabled then cam.FieldOfView = v end
    end)
    RunService.RenderStepped:Connect(function()
        if ThirdPersonFOV.enabled then cam.FieldOfView = ThirdPersonFOV.fov end
    end)

    -- Crosshair
    local Crosshair = { enabled = false, color = Color3.fromRGB(255, 50, 50), size = 10, thickness = 1, gap = 4 }
    local crosshairLines = {}
    local crosshairGui = Instance.new("ScreenGui", gui)
    crosshairGui.Name = "CrosshairGui"; crosshairGui.ResetOnSpawn = false; crosshairGui.IgnoreGuiInset = true
    for i = 1, 4 do
        local l = Instance.new("Frame", crosshairGui)
        l.BackgroundColor3 = Crosshair.color; l.BorderSizePixel = 0; l.Visible = false
        table.insert(crosshairLines, l)
    end

    local function updateCrosshair()
        local vp = cam.ViewportSize
        local cx, cy = vp.X/2, vp.Y/2
        local g, s, th = Crosshair.gap, Crosshair.size, Crosshair.thickness
        local positions = {
            {cx - g - s, cy - th/2, s, th},   -- left
            {cx + g,     cy - th/2, s, th},   -- right
            {cx - th/2,  cy - g - s, th, s},  -- top
            {cx - th/2,  cy + g,     th, s},  -- bottom
        }
        for i, l in ipairs(crosshairLines) do
            l.Position = UDim2.new(0, positions[i][1], 0, positions[i][2])
            l.Size = UDim2.new(0, positions[i][3], 0, positions[i][4])
            l.BackgroundColor3 = Crosshair.color
            l.Visible = Crosshair.enabled
        end
    end

    RunService.RenderStepped:Connect(updateCrosshair)

    sep(pg); UI.Header(pg, "crosshair"); sep(pg)
    UI.StatusRow(pg, "Crosshair", function() return Crosshair.enabled end, function()
        Crosshair.enabled = not Crosshair.enabled
        updateCrosshair()
    end)
    UI.Slider(pg, "Size", Crosshair.size, 2, 30, 1, function(v) Crosshair.size = v end)
    UI.Slider(pg, "Gap", Crosshair.gap, 0, 20, 1, function(v) Crosshair.gap = v end)
    UI.Slider(pg, "Thickness", Crosshair.thickness, 1, 6, 1, function(v) Crosshair.thickness = v end)

    -- Crosshair color picker
    UI.ColorPicker(pg, "Crosshair Color", Crosshair.color, function(c) Crosshair.color = c end)
end

-- ---- WHITELIST ----
do
    local pg = Pages["Whitelist"]
    local infoRow = Instance.new("Frame",pg); infoRow.Size=UDim2.new(1,0,0,36); infoRow.BackgroundColor3=C.item; infoRow.BorderSizePixel=0
    local infoLbl = label(infoRow,"Whitelisted players are ignored by all features.",11,C.textSub,Enum.Font.Gotham)
    infoLbl.Size=UDim2.new(1,-8,1,0); infoLbl.Position=UDim2.new(0,8,0,0); infoLbl.TextWrapped=true
    sep(pg); UI.Header(pg,"players in server"); sep(pg)
    local playerListFrame=Instance.new("Frame",pg); playerListFrame.Size=UDim2.new(1,0,0,10); playerListFrame.BackgroundTransparency=1; playerListFrame.BorderSizePixel=0; playerListFrame.AutomaticSize=Enum.AutomaticSize.Y
    local plLayout=Instance.new("UIListLayout",playerListFrame); plLayout.Padding=UDim.new(0,1); plLayout.SortOrder=Enum.SortOrder.LayoutOrder
    local playerRows={}
    local function buildPlayerList()
        for _, r in ipairs(playerRows) do if r and r.Parent then r:Destroy() end end
        playerRows={}
        for _, p in ipairs(Players:GetPlayers()) do
            if p==lp then continue end
            local row=Instance.new("Frame",playerListFrame); row.Size=UDim2.new(1,0,0,34); row.BackgroundColor3=C.item; row.BorderSizePixel=0
            local dot=Instance.new("Frame",row); dot.Size=UDim2.new(0,6,0,6); dot.Position=UDim2.new(0,8,0.5,-3); dot.BackgroundColor3=isWhitelisted(p) and C.green or C.textDim; dot.BorderSizePixel=0; corner(dot,4)
            local nameLbl=label(row,p.DisplayName.." (@"..p.Name..")",11,C.text,Enum.Font.Gotham); nameLbl.Size=UDim2.new(0.55,0,1,0); nameLbl.Position=UDim2.new(0,20,0,0)
            local wlBtn=Instance.new("TextButton",row); wlBtn.Size=UDim2.new(0,84,0,22); wlBtn.Position=UDim2.new(1,-92,0.5,-11); wlBtn.BackgroundColor3=isWhitelisted(p) and C.green or C.accentDark; wlBtn.BorderSizePixel=0; corner(wlBtn,3)
            wlBtn.Text=isWhitelisted(p) and "LISTED" or "ADD"; wlBtn.Font=Enum.Font.GothamBold; wlBtn.TextSize=10; wlBtn.TextColor3=isWhitelisted(p) and C.bg or C.accentLit; wlBtn.AutoButtonColor=false
            wlBtn.MouseButton1Click:Connect(function()
                if isWhitelisted(p) then
                    Whitelist[p.UserId]=nil; wlBtn.BackgroundColor3=C.accentDark; wlBtn.Text="ADD"; wlBtn.TextColor3=C.accentLit; dot.BackgroundColor3=C.textDim; nameLbl.TextColor3=C.text
                else
                    Whitelist[p.UserId]=true; wlBtn.BackgroundColor3=C.green; wlBtn.Text="LISTED"; wlBtn.TextColor3=C.bg; dot.BackgroundColor3=C.green; nameLbl.TextColor3=C.green
                end
                if target and isCharWhitelisted(target) then target=nil; isAiming=false; resetAimState() end
            end)
            table.insert(playerRows,row)
        end
    end
    sep(pg)
    -- Botones: REFRESH + CLEAR ALL
    local btnRow=Instance.new("Frame",pg); btnRow.Size=UDim2.new(1,0,0,34); btnRow.BackgroundColor3=C.item; btnRow.BorderSizePixel=0
    local rfBtn=Instance.new("TextButton",btnRow); rfBtn.Size=UDim2.new(0,110,0,24); rfBtn.Position=UDim2.new(0.5,-118,0.5,-12); rfBtn.BackgroundColor3=C.accentDark; rfBtn.BorderSizePixel=0; corner(rfBtn,3)
    rfBtn.Text="REFRESH"; rfBtn.Font=Enum.Font.GothamBold; rfBtn.TextSize=10; rfBtn.TextColor3=C.accentLit; rfBtn.AutoButtonColor=false
    reg(rfBtn,"BackgroundColor3","accentDark"); reg(rfBtn,"TextColor3","accentLit")
    rfBtn.MouseButton1Click:Connect(function() buildPlayerList() end)
    local clrBtn=Instance.new("TextButton",btnRow); clrBtn.Size=UDim2.new(0,110,0,24); clrBtn.Position=UDim2.new(0.5,8,0.5,-12); clrBtn.BackgroundColor3=Color3.fromRGB(60,20,20); clrBtn.BorderSizePixel=0; corner(clrBtn,3)
    clrBtn.Text="CLEAR ALL"; clrBtn.Font=Enum.Font.GothamBold; clrBtn.TextSize=10; clrBtn.TextColor3=Color3.fromRGB(200,80,80); clrBtn.AutoButtonColor=false
    local clrStroke=Instance.new("UIStroke",clrBtn); clrStroke.Color=Color3.fromRGB(100,30,30); clrStroke.Thickness=1; clrStroke.ApplyStrokeMode=Enum.ApplyStrokeMode.Border
    clrBtn.MouseButton1Click:Connect(function()
        Whitelist={}
        buildPlayerList()
    end)
    sep(pg)
    local countRow=Instance.new("Frame",pg); countRow.Size=UDim2.new(1,0,0,28); countRow.BackgroundColor3=C.item; countRow.BorderSizePixel=0
    local countLbl=label(countRow,"Whitelisted: 0",11,C.text,Enum.Font.Gotham,Enum.TextXAlignment.Center); countLbl.Size=UDim2.new(1,0,1,0)
    task.spawn(function()
        while task.wait(1) do
            local n=0; for _ in pairs(Whitelist) do n=n+1 end
            countLbl.Text="Whitelisted: "..n.." player(s)"
        end
    end)
    buildPlayerList()
    Players.PlayerAdded:Connect(function() task.wait(0.5); buildPlayerList() end)
    Players.PlayerRemoving:Connect(function(p)
        Whitelist[p.UserId]=nil; task.wait(0.1); buildPlayerList()
    end)
end

-- ---- BLACKLIST ----
do
    local pg = Pages["Blacklist"]
    local BL_COLOR = Color3.fromRGB(220, 60, 60)

    local infoRow = Instance.new("Frame",pg); infoRow.Size=UDim2.new(1,0,0,48); infoRow.BackgroundColor3=C.item; infoRow.BorderSizePixel=0
    local infoStroke = Instance.new("UIStroke",infoRow); infoStroke.Color=Color3.fromRGB(100,30,30); infoStroke.Thickness=1; infoStroke.ApplyStrokeMode=Enum.ApplyStrokeMode.Border
    local infoLbl = label(infoRow,"Blacklisted players are the ONLY targets.\nBlacklist overrides Whitelist.",11,C.textSub,Enum.Font.Gotham)
    infoLbl.Size=UDim2.new(1,-8,1,0); infoLbl.Position=UDim2.new(0,8,0,0); infoLbl.TextWrapped=true

    -- Indicator: si blacklist está activa
    local activeRow = Instance.new("Frame",pg); activeRow.Size=UDim2.new(1,0,0,28); activeRow.BackgroundColor3=C.item; activeRow.BorderSizePixel=0
    local activeDot = Instance.new("Frame",activeRow); activeDot.Size=UDim2.new(0,7,0,7); activeDot.Position=UDim2.new(0,10,0.5,-3); activeDot.BackgroundColor3=C.textDim; activeDot.BorderSizePixel=0; corner(activeDot,4)
    local activeLbl = label(activeRow,"Blacklist inactive — targeting all enemies",10,C.textDim,Enum.Font.Gotham)
    activeLbl.Size=UDim2.new(1,-24,1,0); activeLbl.Position=UDim2.new(0,22,0,0)

    local function updateActiveIndicator()
        if blacklistActive() then
            activeDot.BackgroundColor3 = BL_COLOR
            activeLbl.Text = "Blacklist ACTIVE — only targeting listed players"
            activeLbl.TextColor3 = BL_COLOR
        else
            activeDot.BackgroundColor3 = C.textDim
            activeLbl.Text = "Blacklist inactive — targeting all enemies"
            activeLbl.TextColor3 = C.textDim
        end
    end

    sep(pg); UI.Header(pg,"players in server"); sep(pg)
    local playerListFrame=Instance.new("Frame",pg); playerListFrame.Size=UDim2.new(1,0,0,10); playerListFrame.BackgroundTransparency=1; playerListFrame.BorderSizePixel=0; playerListFrame.AutomaticSize=Enum.AutomaticSize.Y
    local plLayout=Instance.new("UIListLayout",playerListFrame); plLayout.Padding=UDim.new(0,1); plLayout.SortOrder=Enum.SortOrder.LayoutOrder
    local blPlayerRows={}

    local function buildBlacklistPlayerList()
        for _, r in ipairs(blPlayerRows) do if r and r.Parent then r:Destroy() end end
        blPlayerRows={}
        for _, p in ipairs(Players:GetPlayers()) do
            if p==lp then continue end
            local listed = isBlacklisted(p)
            local row=Instance.new("Frame",playerListFrame); row.Size=UDim2.new(1,0,0,34); row.BackgroundColor3=C.item; row.BorderSizePixel=0
            local dot=Instance.new("Frame",row); dot.Size=UDim2.new(0,6,0,6); dot.Position=UDim2.new(0,8,0.5,-3); dot.BackgroundColor3=listed and BL_COLOR or C.textDim; dot.BorderSizePixel=0; corner(dot,4)
            local nameLbl=label(row,p.DisplayName.." (@"..p.Name..")",11,listed and Color3.fromRGB(255,160,160) or C.text,Enum.Font.Gotham); nameLbl.Size=UDim2.new(0.55,0,1,0); nameLbl.Position=UDim2.new(0,20,0,0)
            local blBtn=Instance.new("TextButton",row); blBtn.Size=UDim2.new(0,84,0,22); blBtn.Position=UDim2.new(1,-92,0.5,-11); blBtn.BorderSizePixel=0; corner(blBtn,3)
            blBtn.BackgroundColor3=listed and BL_COLOR or C.accentDark
            blBtn.Text=listed and "LISTED" or "ADD"; blBtn.Font=Enum.Font.GothamBold; blBtn.TextSize=10
            blBtn.TextColor3=listed and Color3.new(1,1,1) or C.accentLit; blBtn.AutoButtonColor=false
            local blBtnStroke=Instance.new("UIStroke",blBtn); blBtnStroke.Thickness=1; blBtnStroke.ApplyStrokeMode=Enum.ApplyStrokeMode.Border
            blBtnStroke.Color=listed and Color3.fromRGB(180,40,40) or C.borderAcc
            blBtn.MouseButton1Click:Connect(function()
                if isBlacklisted(p) then
                    Blacklist[p.UserId]=nil
                    blBtn.BackgroundColor3=C.accentDark; blBtn.Text="ADD"; blBtn.TextColor3=C.accentLit
                    blBtnStroke.Color=C.borderAcc
                    dot.BackgroundColor3=C.textDim; nameLbl.TextColor3=C.text
                else
                    Blacklist[p.UserId]=true
                    blBtn.BackgroundColor3=BL_COLOR; blBtn.Text="LISTED"; blBtn.TextColor3=Color3.new(1,1,1)
                    blBtnStroke.Color=Color3.fromRGB(180,40,40)
                    dot.BackgroundColor3=BL_COLOR; nameLbl.TextColor3=Color3.fromRGB(255,160,160)
                end
                updateActiveIndicator()
                -- Resetear target si ya no es valido con la nueva blacklist
                if target then target=nil; isAiming=false; resetAimState() end
            end)
            table.insert(blPlayerRows,row)
        end
        updateActiveIndicator()
    end

    sep(pg)
    -- Botones: REFRESH + CLEAR ALL
    local btnRow=Instance.new("Frame",pg); btnRow.Size=UDim2.new(1,0,0,34); btnRow.BackgroundColor3=C.item; btnRow.BorderSizePixel=0
    local rfBtn=Instance.new("TextButton",btnRow); rfBtn.Size=UDim2.new(0,110,0,24); rfBtn.Position=UDim2.new(0.5,-118,0.5,-12); rfBtn.BackgroundColor3=C.accentDark; rfBtn.BorderSizePixel=0; corner(rfBtn,3)
    rfBtn.Text="REFRESH"; rfBtn.Font=Enum.Font.GothamBold; rfBtn.TextSize=10; rfBtn.TextColor3=C.accentLit; rfBtn.AutoButtonColor=false
    reg(rfBtn,"BackgroundColor3","accentDark"); reg(rfBtn,"TextColor3","accentLit")
    rfBtn.MouseButton1Click:Connect(function() buildBlacklistPlayerList() end)
    local clrBtn=Instance.new("TextButton",btnRow); clrBtn.Size=UDim2.new(0,110,0,24); clrBtn.Position=UDim2.new(0.5,8,0.5,-12); clrBtn.BackgroundColor3=Color3.fromRGB(60,20,20); clrBtn.BorderSizePixel=0; corner(clrBtn,3)
    clrBtn.Text="CLEAR ALL"; clrBtn.Font=Enum.Font.GothamBold; clrBtn.TextSize=10; clrBtn.TextColor3=Color3.fromRGB(200,80,80); clrBtn.AutoButtonColor=false
    local clrStroke=Instance.new("UIStroke",clrBtn); clrStroke.Color=Color3.fromRGB(100,30,30); clrStroke.Thickness=1; clrStroke.ApplyStrokeMode=Enum.ApplyStrokeMode.Border
    clrBtn.MouseButton1Click:Connect(function()
        Blacklist={}
        buildBlacklistPlayerList()
        if target then target=nil; isAiming=false; resetAimState() end
    end)
    sep(pg)
    local countRow=Instance.new("Frame",pg); countRow.Size=UDim2.new(1,0,0,28); countRow.BackgroundColor3=C.item; countRow.BorderSizePixel=0
    local countLbl=label(countRow,"Blacklisted: 0",11,BL_COLOR,Enum.Font.Gotham,Enum.TextXAlignment.Center); countLbl.Size=UDim2.new(1,0,1,0)
    task.spawn(function()
        while task.wait(1) do
            local n=0; for _ in pairs(Blacklist) do n=n+1 end
            countLbl.Text="Blacklisted: "..n.." player(s)"
            updateActiveIndicator()
        end
    end)
    buildBlacklistPlayerList()
    Players.PlayerAdded:Connect(function() task.wait(0.5); buildBlacklistPlayerList() end)
    Players.PlayerRemoving:Connect(function(p)
        Blacklist[p.UserId]=nil; task.wait(0.1); buildBlacklistPlayerList()
    end)
end

-- ---- SETTINGS ----
do
    local pg = Pages["Settings"]
    UI.Header(pg,"accent color"); sep(pg)
    UI.ColorPicker(pg, "Accent Color", C.accent, function(c) applyAccentColor(c) end)
end

-- Window toggle
UserInputService.InputBegan:Connect(function(inp, gp)
    if inp.KeyCode==Enum.KeyCode.Insert or inp.KeyCode==Enum.KeyCode.F4 then
        Main.Visible = not Main.Visible
    end
end)


-- ================================================================
-- INTRO SEQUENCE
-- ================================================================
task.spawn(function()
    local LOGO_ID  = "rbxassetid://76785822191767"
    local SOUND_ID = "rbxassetid://126319073341656"

    local T_GROW     = 2.2
    local T_HOLD     = 0.5
    local T_FADE_OUT = 0.5

    local introGui = Instance.new("ScreenGui")
    introGui.Name           = "ProtoIntro"
    introGui.ResetOnSpawn   = false
    introGui.IgnoreGuiInset = true
    introGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    introGui.DisplayOrder   = 9999
    introGui.Parent         = gui

    -- Blur
    local blurInst = Instance.new("BlurEffect")
    blurInst.Size   = 0
    blurInst.Parent = game:GetService("Lighting")
    TweenService:Create(blurInst, TweenInfo.new(0.4), {Size = 28}):Play()

    local LOGO_START = 150
    local LOGO_END   = 500

    -- Logo
    local logoImg = Instance.new("ImageLabel", introGui)
    logoImg.AnchorPoint            = Vector2.new(0.5, 0.5)
    logoImg.Position               = UDim2.new(0.5, 0, 0.5, 0)
    logoImg.Size                   = UDim2.new(0, LOGO_START, 0, LOGO_START)
    logoImg.BackgroundTransparency = 1
    logoImg.Image                  = LOGO_ID
    logoImg.ImageTransparency      = 0  -- visible de inmediato, sin fade bloqueante
    logoImg.ScaleType              = Enum.ScaleType.Fit
    logoImg.ZIndex                 = 10

    -- Sonido — multiples metodos para garantizar que suene
    task.spawn(function()
        local s = Instance.new("Sound")
        s.SoundId = SOUND_ID
        s.Volume  = 1
        s.Parent  = workspace
        s:Play()
        task.delay(15, function() pcall(function() s:Stop(); s:Destroy() end) end)
    end)

    local function tw(obj, t, props, style, dir)
        style = style or Enum.EasingStyle.Quad
        dir   = dir   or Enum.EasingDirection.Out
        TweenService:Create(obj, TweenInfo.new(t, style, dir), props):Play()
    end

    -- Crecer logo desde el inicio
    local elapsed = 0
    local conn
    conn = RunService.RenderStepped:Connect(function(dt)
        elapsed = elapsed + dt
        local raw = elapsed / T_GROW
        local t   = 1 - (1 - math.min(raw, 1)) ^ 3
        local sz  = LOGO_START + (LOGO_END - LOGO_START) * t
        logoImg.Size = UDim2.new(0, sz, 0, sz)
        if raw >= 1 then conn:Disconnect() end
    end)

    task.wait(T_GROW + T_HOLD)

    -- Fade out
    tw(logoImg, T_FADE_OUT, {ImageTransparency = 1}, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
    TweenService:Create(blurInst, TweenInfo.new(T_FADE_OUT), {Size = 0}):Play()
    task.wait(T_FADE_OUT + 0.1)

    -- Mostrar UI
    introGui:Destroy()
    blurInst:Destroy()
    Main.Visible = true

    Main.Position               = UDim2.new(0.5, -250, 0.5, -420)
    Main.BackgroundTransparency = 1
    TweenService:Create(Main, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Position               = UDim2.new(0.5, -250, 0.5, -400),
        BackgroundTransparency = 0,
    }):Play()
end)

print("Prototype loaded. INSERT / F4 to toggle.")
