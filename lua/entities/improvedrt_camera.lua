AddCSLuaFile()
ENT.Base = "base_wire_entity"
ENT.Type = "anim"
ENT.PrintName = "Improved RT Camera"
ENT.WireDebugName = "Improved RT Camera"


function ENT:Initialize()
    if ( SERVER ) then
		self:PhysicsInit( SOLID_VPHYSICS )
		self:SetMoveType( MOVETYPE_VPHYSICS )
		self:SetSolid( SOLID_VPHYSICS )
		self:DrawShadow( false )

		-- Don't collide with the player
		self:SetCollisionGroup( COLLISION_GROUP_WEAPON )

		--self.health = rtcam.cameraHealth
		self.Inputs = Wire_CreateInputs( self, {"Active", "FOV"} )
	end

    self.IsObserved = false
end

function ENT:Setup(default_fov)--(model, default_fov)
    --self:SetModel(model or "models/maxofs2d/camera.mdl")
    self:SetCamFOV(default_fov or 80)
end

function ENT:SetupDataTables()
	self:NetworkVar("Int", 0, "CamFOV")
    self:NetworkVar("Bool", 0, "Active")

    if CLIENT then
        self:NetworkVarNotify("Active", self.ActiveChanged)
    end
end

function ENT:TriggerInput( name, value )
    if name == "FOV" then
      self:SetCamFOV( math.Clamp( value, 10, 120 ) )
    elseif name == "Active" then
        self:SetActive(value ~= 0)
    end
end


if SERVER then
    hook.Add("SetupPlayerVisibility", "ImprovedRTCamera", function(ply, plyView)
        for _, screen in ipairs(ents.FindByClass("improvedrt_screen")) do
            if not screen:GetActive() then continue end
            if not screen:ShouldDrawCamera(ply) then continue end

            
            local camera = screen:GetCamera()
            if not IsValid(camera) then continue end
            if not camera:GetActive() then continue end

            AddOriginToPVS(camera:GetPos())
        end
    end)
end


if CLIENT then
    --local improvedrt_camera_maxactive = CreateClientConVar("improvedrt_camera_resolution_h", "-1", true, nil, nil, -1)
    local improvedrt_camera_resolution_h = CreateClientConVar("improvedrt_camera_resolution_h", "512", true, nil, nil, 128)
    local improvedrt_camera_resolution_w = CreateClientConVar("improvedrt_camera_resolution_w", "512", true, nil, nil, 128)    
    local improvedrt_camera_filtering = CreateClientConVar("improvedrt_camera_filtering", "2", true, nil, nil, 0, 2) 
    local improvedrt_camera_hdr = CreateClientConVar("improvedrt_camera_hdr", "1", true, nil, nil, 0, 1) 

    local ActiveCameras = {}
    local ObservedCameras = {}

    concommand.Add("improvedrt_camera_recreate", function()
        for _, cam in ipairs(ObservedCameras) do
            cam:InitRTTexture()
        end
    end)

    local function SetCameraActive(camera, isActive)
        if isActive then
            ActiveCameras[camera] = true
        else
            if camera.SetIsObserved then -- undefi
                camera:SetIsObserved(false)
            end
            ActiveCameras[camera] = nil
        end
    end

    function ENT:ActiveChanged(_, _, isActive)
        SetCameraActive(self, isActive)
    end

    function ENT:OnRemove()
        timer.Simple( 0, function()
            if not IsValid(self) then
                SetCameraActive(self, false)
            end
        end)
    end

    function ENT:SetIsObserved(isObserved)
        assert(isbool(isObserved))

        if isObserved == self.IsObserved then
            return
        end

        self.IsObserved = isObserved

        if isObserved then
            local index = #ObservedCameras + 1
            ObservedCameras[index] = self
            self.ObservedCamerasIndex = index
    
            self:InitRTTexture()
        else
            ObservedCameras[self.ObservedCamerasIndex] = nil 
            self.ObservedCamerasIndex = nil 
            self.RenderTarget = nil
        end
    end

    local function CreateRTName(index)
        return "improvedrtcamera_rt_"..tostring(index).."_"..improvedrt_camera_filtering:GetString().."_"
            ..improvedrt_camera_resolution_h:GetString().."x"..improvedrt_camera_resolution_w:GetString()..
            (improvedrt_camera_hdr:GetInt() and "_hdr" or "_ldr")
    end

    function ENT:InitRTTexture()
        local index = self.ObservedCamerasIndex

        local filteringFlag = 1 -- pointsample

        if improvedrt_camera_filtering:GetInt() == 1 then
            filteringFlag = 2 -- trilinear
        elseif improvedrt_camera_filtering:GetInt() == 2 then
            filteringFlag = 16 -- anisotropic
        end

        local isHDR = improvedrt_camera_hdr:GetInt() ~= 0

        local rt = GetRenderTargetEx(CreateRTName(index), 
            improvedrt_camera_resolution_w:GetInt(),
            improvedrt_camera_resolution_h:GetInt(),
            RT_SIZE_LITERAL,
            MATERIAL_RT_DEPTH_SEPARATE,
            filteringFlag + 256 + 32768,
            isHDR and CREATERENDERTARGETFLAGS_HDR or 0,
            isHDR and IMAGE_FORMAT_RGBA16161616 or IMAGE_FORMAT_RGB888
        )
        rt:Download()

        assert(rt)

        self.RenderTarget = rt
    end

    local CameraIsDrawn = false 

    hook.Add("ShouldDrawLocalPlayer", "ImprovedRTCamera", function(ply)
        if CameraIsDrawn then return true end
    end)

    hook.Add("PreRender", "ImprovedRTCamera", function()
        local ply = LocalPlayer()
        local isHDR = improvedrt_camera_hdr:GetInt() ~= 0
        local renderH = improvedrt_camera_resolution_h:GetInt()
        local renderW = improvedrt_camera_resolution_w:GetInt()

        for ent, _ in pairs(ActiveCameras) do
            if not ent.IsObserved then
                continue
            end 

            if not IsValid(ent) then
                Error("Camera ",ent," is invalid!")
                continue 
            end
            
            render.PushRenderTarget(ent.RenderTarget)
                local oldNoDraw = ent:GetNoDraw()
                ent:SetNoDraw(true)
                    CameraIsDrawn = true 
                    cam.Start2D()
                        render.OverrideAlphaWriteEnable(true, true)
                        render.RenderView({
                            origin = ent:GetPos(),
                            angles = ent:GetAngles(),
                            x = 0, y = 0, h = renderH, w = renderW,
                            drawmonitors = true,
                            drawviewmodel = false,
                            fov = ent:GetCamFOV(),
                            bloomtone = isHDR
                        })

                    cam.End2D()
                    CameraIsDrawn = false
                ent:SetNoDraw(oldNoDraw)
            render.PopRenderTarget()
        end
    end)

end

duplicator.RegisterEntityClass("improvedrt_camera", WireLib.MakeWireEnt, "Data", --[["Model",]] "CamFOV")