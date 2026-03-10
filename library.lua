--!strict
--!native
--!optimize 2

--[[
    @title
        library.lua
    @author
        dev
    @description
        protected ui library base, potassium api compatible
        supports syn, protectgui, and gethui protection layers
--]]

-- services
local input_service  = cloneref( game:GetService( "UserInputService" ) )
local text_service   = cloneref( game:GetService( "TextService" ) )
local core_gui       = cloneref( game:GetService( "CoreGui" ) )
local teams_service  = cloneref( game:GetService( "Teams" ) )
local players        = cloneref( game:GetService( "Players" ) )
local run_service    = cloneref( game:GetService( "RunService" ) )
local tween_service  = cloneref( game:GetService( "TweenService" ) )

-- locals
local render_stepped = run_service.RenderStepped --// main render signal
local local_player   = players.LocalPlayer
local mouse          = local_player:GetMouse()

-- types
type color_map  = { [string]: Color3 | string | (() -> Color3) }
type registry_entry = {
    instance   : Instance;
    properties : color_map;
    idx        : number;
}

-- protection layer
--// tries gethui (potassium/unc), then syn, then fallback to coregui
local function build_screen_gui(): ScreenGui
    local gui = Instance.new( "ScreenGui" )
    gui.ZIndexBehavior   = Enum.ZIndexBehavior.Global
    gui.ResetOnSpawn     = false
    gui.DisplayOrder     = 999
    gui.IgnoreGuiInset   = true

    if gethui then
        -- potassium api: gethui() returns a protected hidden container
        -- gui objects here are invisible to common detection
        gui.Parent = gethui()
    elseif syn and syn.protect_gui then
        syn.protect_gui( gui )
        gui.Parent = core_gui
    elseif protectgui then
        protectgui( gui ) --// unc / other executors
        gui.Parent = core_gui
    else
        gui.Parent = core_gui
    end

    return gui
end

local screen_gui = build_screen_gui()

-- globals
local toggles = {}
local options = {}

getgenv().Toggles = toggles
getgenv().Options = options

-- library table
local library = {
    registry        = {} :: { registry_entry };
    registry_map    = {} :: { [Instance]: registry_entry };
    hud_registry    = {} :: { registry_entry };

    font_color      = Color3.fromRGB( 255, 255, 255 );
    main_color      = Color3.fromRGB( 28, 28, 28 );
    background_color = Color3.fromRGB( 20, 20, 20 );
    accent_color    = Color3.fromRGB( 0, 85, 255 );
    outline_color   = Color3.fromRGB( 50, 50, 50 );
    risk_color      = Color3.fromRGB( 255, 50, 50 );
    black           = Color3.new( 0, 0, 0 );

    font            = Enum.Font.Code;

    opened_frames   = {} :: { [Frame]: boolean };
    dependency_boxes = {} :: { any };

    signals         = {} :: { RBXScriptConnection };
    screen_gui      = screen_gui;

    current_rainbow_hue   = 0;
    current_rainbow_color = Color3.new( 1, 0, 0 );

    save_manager     = nil :: any;
    notify_on_error  = false :: boolean;
    toggle_keybind   = nil :: any;
    color_clipboard  = nil :: Color3?;

    keybind_frame     = nil :: Frame?;
    keybind_container = nil :: Frame?;
    watermark         = nil :: Frame?;
    watermark_text    = nil :: TextLabel?;
}

library.accent_color_dark = Color3.fromHSV(
    Color3.toHSV( library.accent_color )
)

-- rainbow step
local _rainbow_step = 0
local _hue = 0

table.insert( library.signals, render_stepped:Connect( function( dt: number )
    _rainbow_step += dt

    if _rainbow_step < ( 1 / 60 ) then
        return
    end

    _rainbow_step = 0
    _hue += ( 1 / 400 )

    if _hue > 1 then
        _hue = 0
    end

    library.current_rainbow_hue   = _hue
    library.current_rainbow_color = Color3.fromHSV( _hue, 0.8, 1 )
end ) )

-- helper: get sorted player name list
local function get_players_string(): { string }
    local list = players:GetPlayers()
    local names = table.create( #list )

    for i, p in list do
        names[i] = p.Name
    end

    table.sort( names, function( a, b ) return a < b end )
    return names
end

-- helper: get sorted team name list
local function get_teams_string(): { string }
    local list = teams_service:GetTeams()
    local names = table.create( #list )

    for i, t in list do
        names[i] = t.Name
    end

    table.sort( names, function( a, b ) return a < b end )
    return names
end

-- functions

function library:safe_callback( f: ( ...any ) -> any?, ... )
    if not f then
        return
    end

    if not self.notify_on_error then
        return f( ... )
    end

    local ok, err = pcall( f, ... )

    if not ok then
        local _, i = err:find( ":%d+: " )
        self:notify( i and err:sub( i + 1 ) or err, 3 )
    end
end

function library:attempt_save()
    if self.save_manager then
        self.save_manager:Save()
    end
end

function library:give_signal( signal: RBXScriptConnection )
    table.insert( self.signals, signal )
end

function library:create( class: string | Instance, props: { [string]: any } ): Instance
    local inst = if type( class ) == "string" then Instance.new( class :: string ) else class :: Instance

    for prop, val in props do
        ( inst :: any )[prop] = val
    end

    return inst
end

function library:apply_text_stroke( inst: TextLabel | TextBox )
    ( inst :: any ).TextStrokeTransparency = 1

    self:create( "UIStroke", {
        Color         = Color3.new( 0, 0, 0 );
        Thickness     = 1;
        LineJoinMode  = Enum.LineJoinMode.Miter;
        Parent        = inst;
    } )
end

function library:create_label( props: { [string]: any }, is_hud: boolean? ): TextLabel
    local inst = self:create( "TextLabel", {
        BackgroundTransparency = 1;
        Font                   = self.font;
        TextColor3             = self.font_color;
        TextSize               = 16;
        TextStrokeTransparency = 0;
    } ) :: TextLabel

    self:apply_text_stroke( inst )
    self:add_to_registry( inst, { TextColor3 = "font_color" }, is_hud )

    return self:create( inst, props ) :: TextLabel
end

function library:make_draggable( frame: Frame, cutoff: number? )
    ( frame :: any ).Active = true

    frame.InputBegan:Connect( function( input: InputObject )
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
            return
        end

        local obj_pos = Vector2.new(
            mouse.X - frame.AbsolutePosition.X,
            mouse.Y - frame.AbsolutePosition.Y
        )

        if obj_pos.Y > ( cutoff or 40 ) then
            return
        end

        while input_service:IsMouseButtonPressed( Enum.UserInputType.MouseButton1 ) do
            frame.Position = UDim2.new(
                0,
                mouse.X - obj_pos.X + ( frame.Size.X.Offset * frame.AnchorPoint.X ),
                0,
                mouse.Y - obj_pos.Y + ( frame.Size.Y.Offset * frame.AnchorPoint.Y )
            )

            render_stepped:Wait()
        end
    end )
end

function library:add_tooltip( text: string, hover_inst: Instance )
    local x, y = self:get_text_bounds( text, self.font, 14 )

    local tip = self:create( "Frame", {
        BackgroundColor3 = self.main_color;
        BorderColor3     = self.outline_color;
        Size             = UDim2.fromOffset( x + 5, y + 4 );
        ZIndex           = 100;
        Visible          = false;
        Parent           = screen_gui;
    } )

    local label = self:create_label( {
        Position         = UDim2.fromOffset( 3, 1 );
        Size             = UDim2.fromOffset( x, y );
        TextSize         = 14;
        Text             = text;
        TextColor3       = self.font_color;
        TextXAlignment   = Enum.TextXAlignment.Left;
        ZIndex           = 101;
        Parent           = tip;
    } )

    self:add_to_registry( tip, { BackgroundColor3 = "main_color"; BorderColor3 = "outline_color" } )
    self:add_to_registry( label, { TextColor3 = "font_color" } )

    local hovering = false

    ;( hover_inst :: any ).MouseEnter:Connect( function()
        if self:mouse_is_over_opened_frame() then
            return
        end

        hovering = true
        tip.Position = UDim2.fromOffset( mouse.X + 15, mouse.Y + 12 )
        tip.Visible = true

        while hovering do
            run_service.Heartbeat:Wait()
            tip.Position = UDim2.fromOffset( mouse.X + 15, mouse.Y + 12 )
        end
    end )

    ;( hover_inst :: any ).MouseLeave:Connect( function()
        hovering = false
        tip.Visible = false
    end )
end

function library:on_highlight(
    hover_inst : Instance,
    target     : Instance,
    on_props   : color_map,
    off_props  : color_map
)
    local function apply( props: color_map )
        local reg = self.registry_map[target]

        for prop, val in props do
            ;( target :: any )[prop] = if type( val ) == "string" then ( self :: any )[val] else val

            if reg and reg.properties[prop] then
                reg.properties[prop] = val
            end
        end
    end

    ;( hover_inst :: any ).MouseEnter:Connect( function() apply( on_props ) end )
    ;( hover_inst :: any ).MouseLeave:Connect( function() apply( off_props ) end )
end

function library:mouse_is_over_opened_frame(): boolean
    for frame in self.opened_frames do
        local pos  = frame.AbsolutePosition
        local size = frame.AbsoluteSize

        if mouse.X >= pos.X and mouse.X <= pos.X + size.X
        and mouse.Y >= pos.Y and mouse.Y <= pos.Y + size.Y then
            return true
        end
    end

    return false
end

function library:is_mouse_over_frame( frame: Frame ): boolean
    local pos  = frame.AbsolutePosition
    local size = frame.AbsoluteSize

    return mouse.X >= pos.X and mouse.X <= pos.X + size.X
        and mouse.Y >= pos.Y and mouse.Y <= pos.Y + size.Y
end

function library:update_dependency_boxes()
    for _, box in self.dependency_boxes do
        box:update()
    end
end

function library:map_value( v: number, min_a: number, max_a: number, min_b: number, max_b: number ): number
    local t = ( v - min_a ) / ( max_a - min_a )
    return ( 1 - t ) * min_b + t * max_b
end

function library:get_text_bounds( text: string, font: Enum.Font, size: number, res: Vector2? ): ( number, number )
    local b = text_service:GetTextSize( text, size, font, res or Vector2.new( 1920, 1080 ) )
    return b.X, b.Y
end

function library:get_darker_color( color: Color3 ): Color3
    local h, s, v = Color3.toHSV( color )
    return Color3.fromHSV( h, s, v / 1.5 )
end

function library:add_to_registry( inst: Instance, props: color_map, is_hud: boolean? )
    local idx  = #self.registry + 1
    local data: registry_entry = {
        instance   = inst;
        properties = props;
        idx        = idx;
    }

    table.insert( self.registry, data )
    self.registry_map[inst] = data

    if is_hud then
        table.insert( self.hud_registry, data )
    end
end

function library:remove_from_registry( inst: Instance )
    local data = self.registry_map[inst]
    if not data then return end

    for i = #self.registry, 1, -1 do
        if self.registry[i] == data then
            table.remove( self.registry, i )
        end
    end

    for i = #self.hud_registry, 1, -1 do
        if self.hud_registry[i] == data then
            table.remove( self.hud_registry, i )
        end
    end

    self.registry_map[inst] = nil
end

function library:update_colors()
    for _, obj in self.registry do
        for prop, val in obj.properties do
            if type( val ) == "string" then
                ;( obj.instance :: any )[prop] = ( self :: any )[val]
            elseif type( val ) == "function" then
                ;( obj.instance :: any )[prop] = val()
            end
        end
    end
end

function library:unload()
    for i = #self.signals, 1, -1 do
        local conn = table.remove( self.signals, i )
        conn:Disconnect()
    end

    if self._on_unload then
        self._on_unload()
    end

    screen_gui:Destroy()
end

function library:on_unload( callback: () -> () )
    self._on_unload = callback
end

-- clean up registry on instance removal
library:give_signal( screen_gui.DescendantRemoving:Connect( function( inst: Instance )
    if library.registry_map[inst] then
        library:remove_from_registry( inst )
    end
end ) )

-- accent dark precompute
do
    local h, s, v = Color3.toHSV( library.accent_color )
    library.accent_color_dark = Color3.fromHSV( h, s, v / 1.5 )
end

-- player list refresh on join/leave
local function _on_player_change()
    local list = get_players_string()

    for _, val in options do
        if val.type == "dropdown" and val.special_type == "player" then
            val:set_values( list )
        end
    end
end

players.PlayerAdded:Connect( _on_player_change )
players.PlayerRemoving:Connect( _on_player_change )

-- notification area
do
    library.notification_area = library:create( "Frame", {
        BackgroundTransparency = 1;
        Position               = UDim2.new( 0, 0, 0, 40 );
        Size                   = UDim2.new( 0, 300, 0, 200 );
        ZIndex                 = 100;
        Parent                 = screen_gui;
    } )

    library:create( "UIListLayout", {
        Padding          = UDim.new( 0, 4 );
        FillDirection    = Enum.FillDirection.Vertical;
        SortOrder        = Enum.SortOrder.LayoutOrder;
        Parent           = library.notification_area;
    } )
end

-- watermark
do
    local wm_outer = library:create( "Frame", {
        BorderColor3 = Color3.new( 0, 0, 0 );
        Position     = UDim2.new( 0, 100, 0, -25 );
        Size         = UDim2.new( 0, 213, 0, 20 );
        ZIndex       = 200;
        Visible      = false;
        Parent       = screen_gui;
    } )

    local wm_inner = library:create( "Frame", {
        BackgroundColor3 = library.main_color;
        BorderColor3     = library.accent_color;
        BorderMode       = Enum.BorderMode.Inset;
        Size             = UDim2.new( 1, 0, 1, 0 );
        ZIndex           = 201;
        Parent           = wm_outer;
    } )

    library:add_to_registry( wm_inner, { BorderColor3 = "accent_color" } )

    local inner_frame = library:create( "Frame", {
        BackgroundColor3 = Color3.new( 1, 1, 1 );
        BorderSizePixel  = 0;
        Position         = UDim2.new( 0, 1, 0, 1 );
        Size             = UDim2.new( 1, -2, 1, -2 );
        ZIndex           = 202;
        Parent           = wm_inner;
    } )

    local gradient = library:create( "UIGradient", {
        Color    = ColorSequence.new( {
            ColorSequenceKeypoint.new( 0, library:get_darker_color( library.main_color ) ),
            ColorSequenceKeypoint.new( 1, library.main_color ),
        } );
        Rotation = -90;
        Parent   = inner_frame;
    } )

    library:add_to_registry( gradient, {
        Color = function()
            return ColorSequence.new( {
                ColorSequenceKeypoint.new( 0, library:get_darker_color( library.main_color ) ),
                ColorSequenceKeypoint.new( 1, library.main_color ),
            } )
        end;
    } )

    local wm_label = library:create_label( {
        Position       = UDim2.new( 0, 5, 0, 0 );
        Size           = UDim2.new( 1, -4, 1, 0 );
        TextSize       = 14;
        TextXAlignment = Enum.TextXAlignment.Left;
        ZIndex         = 203;
        Parent         = inner_frame;
    } )

    library.watermark      = wm_outer
    library.watermark_text = wm_label
    library:make_draggable( wm_outer )
end

-- keybind frame
do
    local kb_outer = library:create( "Frame", {
        AnchorPoint  = Vector2.new( 0, 0.5 );
        BorderColor3 = Color3.new( 0, 0, 0 );
        Position     = UDim2.new( 0, 10, 0.5, 0 );
        Size         = UDim2.new( 0, 210, 0, 20 );
        Visible      = false;
        ZIndex       = 100;
        Parent       = screen_gui;
    } )

    local kb_inner = library:create( "Frame", {
        BackgroundColor3 = library.main_color;
        BorderColor3     = library.outline_color;
        BorderMode       = Enum.BorderMode.Inset;
        Size             = UDim2.new( 1, 0, 1, 0 );
        ZIndex           = 101;
        Parent           = kb_outer;
    } )

    library:add_to_registry( kb_inner, { BackgroundColor3 = "main_color"; BorderColor3 = "outline_color" }, true )

    local color_bar = library:create( "Frame", {
        BackgroundColor3 = library.accent_color;
        BorderSizePixel  = 0;
        Size             = UDim2.new( 1, 0, 0, 2 );
        ZIndex           = 102;
        Parent           = kb_inner;
    } )

    library:add_to_registry( color_bar, { BackgroundColor3 = "accent_color" }, true )

    library:create_label( {
        Size           = UDim2.new( 1, 0, 0, 20 );
        Position       = UDim2.fromOffset( 5, 2 );
        TextXAlignment = Enum.TextXAlignment.Left;
        Text           = "Keybinds";
        ZIndex         = 104;
        Parent         = kb_inner;
    } )

    local kb_container = library:create( "Frame", {
        BackgroundTransparency = 1;
        Size                   = UDim2.new( 1, 0, 1, -20 );
        Position               = UDim2.new( 0, 0, 0, 20 );
        ZIndex                 = 1;
        Parent                 = kb_inner;
    } )

    library:create( "UIListLayout", {
        FillDirection = Enum.FillDirection.Vertical;
        SortOrder     = Enum.SortOrder.LayoutOrder;
        Parent        = kb_container;
    } )

    library:create( "UIPadding", {
        PaddingLeft = UDim.new( 0, 5 );
        Parent      = kb_container;
    } )

    library.keybind_frame     = kb_outer
    library.keybind_container = kb_container
    library:make_draggable( kb_outer )
end

-- public watermark helpers
function library:set_watermark_visibility( visible: boolean )
    if self.watermark then
        self.watermark.Visible = visible
    end
end

function library:set_watermark( text: string )
    local x, y = self:get_text_bounds( text, self.font, 14 )

    if self.watermark then
        self.watermark.Size = UDim2.new( 0, x + 15, 0, y * 1.5 + 3 )
        self.watermark.Visible = true
    end

    if self.watermark_text then
        self.watermark_text.Text = text
    end
end

-- notification
function library:notify( text: string, duration: number? )
    local x, y = self:get_text_bounds( text, self.font, 14 )
    y = y + 7

    local outer = self:create( "Frame", {
        BorderColor3      = Color3.new( 0, 0, 0 );
        Position          = UDim2.new( 0, 100, 0, 10 );
        Size              = UDim2.new( 0, 0, 0, y );
        ClipsDescendants  = true;
        ZIndex            = 100;
        Parent            = self.notification_area;
    } )

    local inner = self:create( "Frame", {
        BackgroundColor3 = self.main_color;
        BorderColor3     = self.outline_color;
        BorderMode       = Enum.BorderMode.Inset;
        Size             = UDim2.new( 1, 0, 1, 0 );
        ZIndex           = 101;
        Parent           = outer;
    } )

    self:add_to_registry( inner, { BackgroundColor3 = "main_color"; BorderColor3 = "outline_color" }, true )

    local inner_frame = self:create( "Frame", {
        BackgroundColor3 = Color3.new( 1, 1, 1 );
        BorderSizePixel  = 0;
        Position         = UDim2.new( 0, 1, 0, 1 );
        Size             = UDim2.new( 1, -2, 1, -2 );
        ZIndex           = 102;
        Parent           = inner;
    } )

    local gradient = self:create( "UIGradient", {
        Color    = ColorSequence.new( {
            ColorSequenceKeypoint.new( 0, self:get_darker_color( self.main_color ) ),
            ColorSequenceKeypoint.new( 1, self.main_color ),
        } );
        Rotation = -90;
        Parent   = inner_frame;
    } )

    self:add_to_registry( gradient, {
        Color = function()
            return ColorSequence.new( {
                ColorSequenceKeypoint.new( 0, self:get_darker_color( self.main_color ) ),
                ColorSequenceKeypoint.new( 1, self.main_color ),
            } )
        end;
    } )

    self:create_label( {
        Position       = UDim2.new( 0, 4, 0, 0 );
        Size           = UDim2.new( 1, -4, 1, 0 );
        Text           = text;
        TextXAlignment = Enum.TextXAlignment.Left;
        TextSize       = 14;
        ZIndex         = 103;
        Parent         = inner_frame;
    } )

    local accent_bar = self:create( "Frame", {
        BackgroundColor3 = self.accent_color;
        BorderSizePixel  = 0;
        Position         = UDim2.new( 0, -1, 0, -1 );
        Size             = UDim2.new( 0, 3, 1, 2 );
        ZIndex           = 104;
        Parent           = outer;
    } )

    self:add_to_registry( accent_bar, { BackgroundColor3 = "accent_color" }, true )

    pcall( function()
        outer:TweenSize(
            UDim2.new( 0, x + 8 + 4, 0, y ),
            Enum.EasingDirection.Out,
            Enum.EasingStyle.Quad,
            0.4,
            true
        )
    end )

    task.spawn( function()
        task.wait( duration or 5 )

        pcall( function()
            outer:TweenSize(
                UDim2.new( 0, 0, 0, y ),
                Enum.EasingDirection.Out,
                Enum.EasingStyle.Quad,
                0.4,
                true
            )
        end )

        task.wait( 0.4 )
        outer:Destroy()
    end )
end

-- base addon mixin (color picker, key picker)
local base_addons = {}

do
    local funcs = {}

    function funcs:add_color_picker( idx: string, info: { [string]: any } )
        assert( info.Default, "add_color_picker: missing Default value" )

        local toggle_label = self.text_label
        local picker = {
            value        = info.Default :: Color3;
            transparency = info.Transparency or 0;
            type         = "color_picker";
            title        = type( info.Title ) == "string" and info.Title or "Color picker";
            callback     = info.Callback or function() end;
            hue = 0; sat = 0; vib = 0;
        }

        function picker:set_hsv_from_rgb( color: Color3 )
            local h, s, v = Color3.toHSV( color )
            picker.hue = h
            picker.sat = s
            picker.vib = v
        end

        picker:set_hsv_from_rgb( picker.value )

        local display_frame = library:create( "Frame", {
            BackgroundColor3 = picker.value;
            BorderColor3     = library:get_darker_color( picker.value );
            BorderMode       = Enum.BorderMode.Inset;
            Size             = UDim2.new( 0, 28, 0, 14 );
            ZIndex           = 6;
            Parent           = toggle_label;
        } )

        -- transparency checker pattern
        library:create( "ImageLabel", {
            BorderSizePixel = 0;
            Size            = UDim2.new( 0, 27, 0, 13 );
            ZIndex          = 5;
            Image           = "http://www.roblox.com/asset/?id=12977615774";
            Visible         = not not info.Transparency;
            Parent          = display_frame;
        } )

        local picker_outer = library:create( "Frame", {
            Name             = "Color";
            BackgroundColor3 = Color3.new( 1, 1, 1 );
            BorderColor3     = Color3.new( 0, 0, 0 );
            Position         = UDim2.fromOffset( display_frame.AbsolutePosition.X, display_frame.AbsolutePosition.Y + 18 );
            Size             = UDim2.fromOffset( 230, info.Transparency and 271 or 253 );
            Visible          = false;
            ZIndex           = 15;
            Parent           = screen_gui;
        } )

        display_frame:GetPropertyChangedSignal( "AbsolutePosition" ):Connect( function()
            picker_outer.Position = UDim2.fromOffset(
                display_frame.AbsolutePosition.X,
                display_frame.AbsolutePosition.Y + 18
            )
        end )

        local picker_inner = library:create( "Frame", {
            BackgroundColor3 = library.background_color;
            BorderColor3     = library.outline_color;
            BorderMode       = Enum.BorderMode.Inset;
            Size             = UDim2.new( 1, 0, 1, 0 );
            ZIndex           = 16;
            Parent           = picker_outer;
        } )

        local highlight = library:create( "Frame", {
            BackgroundColor3 = library.accent_color;
            BorderSizePixel  = 0;
            Size             = UDim2.new( 1, 0, 0, 2 );
            ZIndex           = 17;
            Parent           = picker_inner;
        } )

        library:add_to_registry( picker_inner, { BackgroundColor3 = "background_color"; BorderColor3 = "outline_color" } )
        library:add_to_registry( highlight, { BackgroundColor3 = "accent_color" } )

        local sv_outer = library:create( "Frame", {
            BorderColor3 = Color3.new( 0, 0, 0 );
            Position     = UDim2.new( 0, 4, 0, 25 );
            Size         = UDim2.new( 0, 200, 0, 200 );
            ZIndex       = 17;
            Parent       = picker_inner;
        } )

        local sv_inner = library:create( "Frame", {
            BackgroundColor3 = library.background_color;
            BorderColor3     = library.outline_color;
            BorderMode       = Enum.BorderMode.Inset;
            Size             = UDim2.new( 1, 0, 1, 0 );
            ZIndex           = 18;
            Parent           = sv_outer;
        } )

        library:add_to_registry( sv_inner, { BackgroundColor3 = "background_color"; BorderColor3 = "outline_color" } )

        local sv_map = library:create( "ImageLabel", {
            BorderSizePixel = 0;
            Size            = UDim2.new( 1, 0, 1, 0 );
            ZIndex          = 18;
            Image           = "rbxassetid://4155801252";
            Parent          = sv_inner;
        } )

        local cursor_outer = library:create( "ImageLabel", {
            AnchorPoint         = Vector2.new( 0.5, 0.5 );
            Size                = UDim2.new( 0, 6, 0, 6 );
            BackgroundTransparency = 1;
            Image               = "http://www.roblox.com/asset/?id=9619665977";
            ImageColor3         = Color3.new( 0, 0, 0 );
            ZIndex              = 19;
            Parent              = sv_map;
        } )

        library:create( "ImageLabel", {
            Size                   = UDim2.new( 0, 4, 0, 4 );
            Position               = UDim2.new( 0, 1, 0, 1 );
            BackgroundTransparency = 1;
            Image                  = "http://www.roblox.com/asset/?id=9619665977";
            ZIndex                 = 20;
            Parent                 = cursor_outer;
        } )

        local hue_outer = library:create( "Frame", {
            BorderColor3 = Color3.new( 0, 0, 0 );
            Position     = UDim2.new( 0, 208, 0, 25 );
            Size         = UDim2.new( 0, 15, 0, 200 );
            ZIndex       = 17;
            Parent       = picker_inner;
        } )

        local hue_inner = library:create( "Frame", {
            BackgroundColor3 = Color3.new( 1, 1, 1 );
            BorderSizePixel  = 0;
            Size             = UDim2.new( 1, 0, 1, 0 );
            ZIndex           = 18;
            Parent           = hue_outer;
        } )

        local hue_cursor = library:create( "Frame", {
            BackgroundColor3 = Color3.new( 1, 1, 1 );
            AnchorPoint      = Vector2.new( 0, 0.5 );
            BorderColor3     = Color3.new( 0, 0, 0 );
            Size             = UDim2.new( 1, 0, 0, 1 );
            ZIndex           = 18;
            Parent           = hue_inner;
        } )

        local seq_table = {}
        for h = 0, 1, 0.1 do
            table.insert( seq_table, ColorSequenceKeypoint.new( h, Color3.fromHSV( h, 1, 1 ) ) )
        end

        library:create( "UIGradient", {
            Color    = ColorSequence.new( seq_table );
            Rotation = 90;
            Parent   = hue_inner;
        } )

        -- hex input
        local hex_box_outer = library:create( "Frame", {
            BorderColor3 = Color3.new( 0, 0, 0 );
            Position     = UDim2.fromOffset( 4, 228 );
            Size         = UDim2.new( 0.5, -6, 0, 20 );
            ZIndex       = 18;
            Parent       = picker_inner;
        } )

        local hex_box_inner = library:create( "Frame", {
            BackgroundColor3 = library.main_color;
            BorderColor3     = library.outline_color;
            BorderMode       = Enum.BorderMode.Inset;
            Size             = UDim2.new( 1, 0, 1, 0 );
            ZIndex           = 18;
            Parent           = hex_box_outer;
        } )

        library:add_to_registry( hex_box_inner, { BackgroundColor3 = "main_color"; BorderColor3 = "outline_color" } )

        library:create( "UIGradient", {
            Color = ColorSequence.new( {
                ColorSequenceKeypoint.new( 0, Color3.new( 1, 1, 1 ) ),
                ColorSequenceKeypoint.new( 1, Color3.fromRGB( 212, 212, 212 ) ),
            } );
            Rotation = 90;
            Parent   = hex_box_inner;
        } )

        local hex_box = library:create( "TextBox", {
            BackgroundTransparency = 1;
            Position               = UDim2.new( 0, 5, 0, 0 );
            Size                   = UDim2.new( 1, -5, 1, 0 );
            Font                   = library.font;
            PlaceholderColor3      = Color3.fromRGB( 190, 190, 190 );
            PlaceholderText        = "Hex color";
            Text                   = "#FFFFFF";
            TextColor3             = library.font_color;
            TextSize               = 14;
            TextStrokeTransparency = 0;
            TextXAlignment         = Enum.TextXAlignment.Left;
            ZIndex                 = 20;
            Parent                 = hex_box_inner;
        } ) :: TextBox

        library:apply_text_stroke( hex_box )
        library:add_to_registry( hex_box, { TextColor3 = "font_color" } )

        -- rgb input (clone hex layout)
        local rgb_box_outer = library:create( "Frame", {
            BorderColor3 = Color3.new( 0, 0, 0 );
            Position     = UDim2.new( 0.5, 2, 0, 228 );
            Size         = UDim2.new( 0.5, -6, 0, 20 );
            ZIndex       = 18;
            Parent       = picker_inner;
        } )

        local rgb_box_inner = library:create( "Frame", {
            BackgroundColor3 = library.main_color;
            BorderColor3     = library.outline_color;
            BorderMode       = Enum.BorderMode.Inset;
            Size             = UDim2.new( 1, 0, 1, 0 );
            ZIndex           = 18;
            Parent           = rgb_box_outer;
        } )

        library:add_to_registry( rgb_box_inner, { BackgroundColor3 = "main_color"; BorderColor3 = "outline_color" } )

        library:create( "UIGradient", {
            Color = ColorSequence.new( {
                ColorSequenceKeypoint.new( 0, Color3.new( 1, 1, 1 ) ),
                ColorSequenceKeypoint.new( 1, Color3.fromRGB( 212, 212, 212 ) ),
            } );
            Rotation = 90;
            Parent   = rgb_box_inner;
        } )

        local rgb_box = library:create( "TextBox", {
            BackgroundTransparency = 1;
            Position               = UDim2.new( 0, 5, 0, 0 );
            Size                   = UDim2.new( 1, -5, 1, 0 );
            Font                   = library.font;
            PlaceholderColor3      = Color3.fromRGB( 190, 190, 190 );
            PlaceholderText        = "RGB color";
            Text                   = "255, 255, 255";
            TextColor3             = library.font_color;
            TextSize               = 14;
            TextStrokeTransparency = 0;
            TextXAlignment         = Enum.TextXAlignment.Left;
            ZIndex                 = 20;
            Parent                 = rgb_box_inner;
        } ) :: TextBox

        library:apply_text_stroke( rgb_box )
        library:add_to_registry( rgb_box, { TextColor3 = "font_color" } )

        -- transparency slider (optional)
        local trans_box_inner: Frame?
        local trans_cursor: Frame?

        if info.Transparency then
            local trans_box_outer = library:create( "Frame", {
                BorderColor3 = Color3.new( 0, 0, 0 );
                Position     = UDim2.fromOffset( 4, 251 );
                Size         = UDim2.new( 1, -8, 0, 15 );
                ZIndex       = 19;
                Parent       = picker_inner;
            } )

            trans_box_inner = library:create( "Frame", {
                BackgroundColor3 = picker.value;
                BorderColor3     = library.outline_color;
                BorderMode       = Enum.BorderMode.Inset;
                Size             = UDim2.new( 1, 0, 1, 0 );
                ZIndex           = 19;
                Parent           = trans_box_outer;
            } ) :: Frame

            library:add_to_registry( trans_box_inner :: Frame, { BorderColor3 = "outline_color" } )

            library:create( "ImageLabel", {
                BackgroundTransparency = 1;
                Size                   = UDim2.new( 1, 0, 1, 0 );
                Image                  = "http://www.roblox.com/asset/?id=12978095818";
                ZIndex                 = 20;
                Parent                 = trans_box_inner;
            } )

            trans_cursor = library:create( "Frame", {
                BackgroundColor3 = Color3.new( 1, 1, 1 );
                AnchorPoint      = Vector2.new( 0.5, 0 );
                BorderColor3     = Color3.new( 0, 0, 0 );
                Size             = UDim2.new( 0, 1, 1, 0 );
                ZIndex           = 21;
                Parent           = trans_box_inner;
            } ) :: Frame
        end

        library:create_label( {
            Size           = UDim2.new( 1, 0, 0, 14 );
            Position       = UDim2.fromOffset( 5, 5 );
            TextXAlignment = Enum.TextXAlignment.Left;
            TextSize       = 14;
            Text           = picker.title;
            TextWrapped    = false;
            ZIndex         = 16;
            Parent         = picker_inner;
        } )

        -- display update
        function picker:display()
            picker.value = Color3.fromHSV( picker.hue, picker.sat, picker.vib )
            ;( sv_map :: any ).BackgroundColor3 = Color3.fromHSV( picker.hue, 1, 1 )

            library:create( display_frame, {
                BackgroundColor3      = picker.value;
                BackgroundTransparency = picker.transparency;
                BorderColor3          = library:get_darker_color( picker.value );
            } )

            if trans_box_inner then
                ;( trans_box_inner :: any ).BackgroundColor3 = picker.value
                ;( trans_cursor :: any ).Position = UDim2.new( 1 - picker.transparency, 0, 0, 0 )
            end

            cursor_outer.Position = UDim2.new( picker.sat, 0, 1 - picker.vib, 0 )
            hue_cursor.Position   = UDim2.new( 0, 0, picker.hue, 0 )

            hex_box.Text = "#" .. picker.value:ToHex()
            rgb_box.Text = table.concat( {
                math.floor( picker.value.R * 255 ),
                math.floor( picker.value.G * 255 ),
                math.floor( picker.value.B * 255 ),
            }, ", " )

            library:safe_callback( picker.callback, picker.value )
            library:safe_callback( picker.changed, picker.value )
        end

        function picker:on_changed( func: ( Color3 ) -> () )
            picker.changed = func
            func( picker.value )
        end

        function picker:show()
            for frame in library.opened_frames do
                if frame.Name == "Color" then
                    frame.Visible = false
                    library.opened_frames[frame] = nil
                end
            end

            picker_outer.Visible = true
            library.opened_frames[picker_outer] = true
        end

        function picker:hide()
            picker_outer.Visible = false
            library.opened_frames[picker_outer] = nil
        end

        function picker:set_value( hsv: { number }, transparency: number? )
            picker.transparency = transparency or 0
            picker:set_hsv_from_rgb( Color3.fromHSV( hsv[1], hsv[2], hsv[3] ) )
            picker:display()
        end

        function picker:set_value_rgb( color: Color3, transparency: number? )
            picker.transparency = transparency or 0
            picker:set_hsv_from_rgb( color )
            picker:display()
        end

        -- sv drag
        sv_map.InputBegan:Connect( function( input: InputObject )
            if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
                return
            end

            while input_service:IsMouseButtonPressed( Enum.UserInputType.MouseButton1 ) do
                local min_x = sv_map.AbsolutePosition.X
                local max_x = min_x + sv_map.AbsoluteSize.X
                local min_y = sv_map.AbsolutePosition.Y
                local max_y = min_y + sv_map.AbsoluteSize.Y

                picker.sat = ( math.clamp( mouse.X, min_x, max_x ) - min_x ) / ( max_x - min_x )
                picker.vib = 1 - ( ( math.clamp( mouse.Y, min_y, max_y ) - min_y ) / ( max_y - min_y ) )
                picker:display()

                render_stepped:Wait()
            end

            library:attempt_save()
        end )

        -- hue drag
        hue_inner.InputBegan:Connect( function( input: InputObject )
            if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
                return
            end

            while input_service:IsMouseButtonPressed( Enum.UserInputType.MouseButton1 ) do
                local min_y = hue_inner.AbsolutePosition.Y
                local max_y = min_y + hue_inner.AbsoluteSize.Y

                picker.hue = ( math.clamp( mouse.Y, min_y, max_y ) - min_y ) / ( max_y - min_y )
                picker:display()

                render_stepped:Wait()
            end

            library:attempt_save()
        end )

        -- transparency drag
        if trans_box_inner then
            trans_box_inner.InputBegan:Connect( function( input: InputObject )
                if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
                    return
                end

                while input_service:IsMouseButtonPressed( Enum.UserInputType.MouseButton1 ) do
                    local min_x = ( trans_box_inner :: Frame ).AbsolutePosition.X
                    local max_x = min_x + ( trans_box_inner :: Frame ).AbsoluteSize.X

                    picker.transparency = 1 - ( ( math.clamp( mouse.X, min_x, max_x ) - min_x ) / ( max_x - min_x ) )
                    picker:display()

                    render_stepped:Wait()
                end

                library:attempt_save()
            end )
        end

        -- hex input
        hex_box.FocusLost:Connect( function( enter: boolean )
            if enter then
                local ok, result = pcall( Color3.fromHex, hex_box.Text )
                if ok and typeof( result ) == "Color3" then
                    picker.hue, picker.sat, picker.vib = Color3.toHSV( result )
                end
            end
            picker:display()
        end )

        -- rgb input
        rgb_box.FocusLost:Connect( function( enter: boolean )
            if enter then
                local r, g, b = rgb_box.Text:match( "(%d+),%s*(%d+),%s*(%d+)" )
                if r and g and b then
                    picker.hue, picker.sat, picker.vib = Color3.toHSV(
                        Color3.fromRGB( tonumber( r ), tonumber( g ), tonumber( b ) )
                    )
                end
            end
            picker:display()
        end )

        -- open/close on click
        display_frame.InputBegan:Connect( function( input: InputObject )
            if input.UserInputType == Enum.UserInputType.MouseButton1
            and not library:mouse_is_over_opened_frame() then
                if picker_outer.Visible then
                    picker:hide()
                else
                    picker:show()
                end
            end
        end )

        -- close on outside click
        library:give_signal( input_service.InputBegan:Connect( function( input: InputObject )
            if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
                return
            end

            local pos  = picker_outer.AbsolutePosition
            local size = picker_outer.AbsoluteSize

            if mouse.X < pos.X or mouse.X > pos.X + size.X
            or mouse.Y < ( pos.Y - 21 ) or mouse.Y > pos.Y + size.Y then
                picker:hide()
            end
        end ) )

        picker:display()
        picker.display_frame = display_frame
        options[idx] = picker

        return self
    end

    function funcs:add_key_picker( idx: string, info: { [string]: any } )
        local parent_obj   = self
        local toggle_label = self.text_label

        assert( info.Default, "add_key_picker: missing Default value" )

        local kp = {
            value         = info.Default :: string;
            toggled       = false;
            mode          = info.Mode or "Toggle"; --// Always, Toggle, Hold
            type          = "key_picker";
            callback      = info.Callback or function() end;
            changed_cb    = info.ChangedCallback or function() end;
            sync_toggle   = info.SyncToggleState or false;
        }

        if kp.sync_toggle then
            info.Modes = { "Toggle" }
            info.Mode  = "Toggle"
        end

        local pick_outer = library:create( "Frame", {
            BackgroundColor3 = Color3.new( 0, 0, 0 );
            BorderColor3     = Color3.new( 0, 0, 0 );
            Size             = UDim2.new( 0, 28, 0, 15 );
            ZIndex           = 6;
            Parent           = toggle_label;
        } )

        local pick_inner = library:create( "Frame", {
            BackgroundColor3 = library.background_color;
            BorderColor3     = library.outline_color;
            BorderMode       = Enum.BorderMode.Inset;
            Size             = UDim2.new( 1, 0, 1, 0 );
            ZIndex           = 7;
            Parent           = pick_outer;
        } )

        library:add_to_registry( pick_inner, { BackgroundColor3 = "background_color"; BorderColor3 = "outline_color" } )

        local display_label = library:create_label( {
            Size        = UDim2.new( 1, 0, 1, 0 );
            TextSize    = 13;
            Text        = info.Default;
            TextWrapped = true;
            ZIndex      = 8;
            Parent      = pick_inner;
        } )

        local mode_outer = library:create( "Frame", {
            BorderColor3 = Color3.new( 0, 0, 0 );
            Position     = UDim2.fromOffset(
                toggle_label.AbsolutePosition.X + toggle_label.AbsoluteSize.X + 4,
                toggle_label.AbsolutePosition.Y + 1
            );
            Size         = UDim2.new( 0, 60, 0, 47 );
            Visible      = false;
            ZIndex       = 14;
            Parent       = screen_gui;
        } )

        toggle_label:GetPropertyChangedSignal( "AbsolutePosition" ):Connect( function()
            mode_outer.Position = UDim2.fromOffset(
                toggle_label.AbsolutePosition.X + toggle_label.AbsoluteSize.X + 4,
                toggle_label.AbsolutePosition.Y + 1
            )
        end )

        local mode_inner = library:create( "Frame", {
            BackgroundColor3 = library.background_color;
            BorderColor3     = library.outline_color;
            BorderMode       = Enum.BorderMode.Inset;
            Size             = UDim2.new( 1, 0, 1, 0 );
            ZIndex           = 15;
            Parent           = mode_outer;
        } )

        library:add_to_registry( mode_inner, { BackgroundColor3 = "background_color"; BorderColor3 = "outline_color" } )

        library:create( "UIListLayout", {
            FillDirection = Enum.FillDirection.Vertical;
            SortOrder     = Enum.SortOrder.LayoutOrder;
            Parent        = mode_inner;
        } )

        local container_label = library:create_label( {
            TextXAlignment = Enum.TextXAlignment.Left;
            Size           = UDim2.new( 1, 0, 0, 18 );
            TextSize       = 13;
            Visible        = false;
            ZIndex         = 110;
            Parent         = library.keybind_container;
        }, true )

        local modes   = info.Modes or { "Always", "Toggle", "Hold" }
        local mode_btns = {}

        for _, mode_name in modes do
            local btn = {}

            local btn_label = library:create_label( {
                Active   = false;
                Size     = UDim2.new( 1, 0, 0, 15 );
                TextSize = 13;
                Text     = mode_name;
                ZIndex   = 16;
                Parent   = mode_inner;
            } )

            function btn:select()
                for _, other in mode_btns do
                    other:deselect()
                end

                kp.mode = mode_name
                btn_label.TextColor3 = library.accent_color
                library.registry_map[btn_label].properties.TextColor3 = "accent_color"
                mode_outer.Visible = false
            end

            function btn:deselect()
                kp.mode = nil
                btn_label.TextColor3 = library.font_color
                library.registry_map[btn_label].properties.TextColor3 = "font_color"
            end

            btn_label.InputBegan:Connect( function( input: InputObject )
                if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
                    return
                end

                btn:select()
                library:attempt_save()
            end )

            if mode_name == kp.mode then
                btn:select()
            end

            mode_btns[mode_name] = btn
        end

        function kp:update()
            if info.NoUI then return end

            local state = kp:get_state()
            container_label.Text = string.format( "[%s] %s (%s)", kp.value, info.Text, kp.mode )
            container_label.Visible = true
            container_label.TextColor3 = state and library.accent_color or library.font_color
            library.registry_map[container_label].properties.TextColor3 = state and "accent_color" or "font_color"

            local y_size = 0
            local x_size = 0

            for _, lbl in library.keybind_container:GetChildren() do
                if lbl:IsA( "TextLabel" ) and lbl.Visible then
                    y_size += 18
                    if lbl.TextBounds.X > x_size then
                        x_size = lbl.TextBounds.X
                    end
                end
            end

            if library.keybind_frame then
                library.keybind_frame.Size = UDim2.new( 0, math.max( x_size + 10, 210 ), 0, y_size + 23 )
            end
        end

        function kp:get_state(): boolean
            if kp.mode == "Always" then
                return true
            elseif kp.mode == "Hold" then
                if kp.value == "None" then return false end

                if kp.value == "MB1" then
                    return input_service:IsMouseButtonPressed( Enum.UserInputType.MouseButton1 )
                elseif kp.value == "MB2" then
                    return input_service:IsMouseButtonPressed( Enum.UserInputType.MouseButton2 )
                else
                    return input_service:IsKeyDown( Enum.KeyCode[kp.value] )
                end
            else
                return kp.toggled
            end
        end

        function kp:set_value( data: { any } )
            local key, mode = data[1], data[2]
            display_label.Text = key
            kp.value = key
            mode_btns[mode]:select()
            kp:update()
        end

        function kp:on_click( cb: () -> () ) kp.clicked = cb end
        function kp:on_changed( cb: ( string ) -> () ) kp.changed_cb = cb; cb( kp.value ) end

        if parent_obj.addons then
            table.insert( parent_obj.addons, kp )
        end

        function kp:do_click()
            if parent_obj.type == "toggle" and kp.sync_toggle then
                parent_obj:set_value( not parent_obj.value )
            end

            library:safe_callback( kp.callback, kp.toggled )
            library:safe_callback( kp.clicked, kp.toggled )
        end

        local picking = false

        pick_outer.InputBegan:Connect( function( input: InputObject )
            if input.UserInputType == Enum.UserInputType.MouseButton1
            and not library:mouse_is_over_opened_frame() then
                picking = true
                display_label.Text = ""

                local broken = false
                local dots   = ""

                task.spawn( function()
                    while not broken do
                        dots = dots == "..." and "" or dots .. "."
                        display_label.Text = dots
                        task.wait( 0.4 )
                    end
                end )

                task.wait( 0.2 )

                local event: RBXScriptConnection
                event = input_service.InputBegan:Connect( function( inp: InputObject )
                    local key: string?

                    if inp.UserInputType == Enum.UserInputType.Keyboard then
                        key = inp.KeyCode.Name
                    elseif inp.UserInputType == Enum.UserInputType.MouseButton1 then
                        key = "MB1"
                    elseif inp.UserInputType == Enum.UserInputType.MouseButton2 then
                        key = "MB2"
                    end

                    broken  = true
                    picking = false

                    if key then
                        display_label.Text = key
                        kp.value = key
                    end

                    library:safe_callback( kp.changed_cb, inp.KeyCode or inp.UserInputType )
                    library:attempt_save()
                    event:Disconnect()
                end )

            elseif input.UserInputType == Enum.UserInputType.MouseButton2
            and not library:mouse_is_over_opened_frame() then
                mode_outer.Visible = true
            end
        end )

        library:give_signal( input_service.InputBegan:Connect( function( input: InputObject )
            if picking then return end

            if kp.mode == "Toggle" then
                local key = kp.value

                if key == "MB1" and input.UserInputType == Enum.UserInputType.MouseButton1
                or key == "MB2" and input.UserInputType == Enum.UserInputType.MouseButton2 then
                    kp.toggled = not kp.toggled
                    kp:do_click()
                elseif input.UserInputType == Enum.UserInputType.Keyboard
                    and input.KeyCode.Name == key then
                    kp.toggled = not kp.toggled
                    kp:do_click()
                end
            end

            kp:update()

            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                local pos  = mode_outer.AbsolutePosition
                local size = mode_outer.AbsoluteSize

                if mouse.X < pos.X or mouse.X > pos.X + size.X
                or mouse.Y < ( pos.Y - 21 ) or mouse.Y > pos.Y + size.Y then
                    mode_outer.Visible = false
                end
            end
        end ) )

        library:give_signal( input_service.InputEnded:Connect( function()
            if not picking then
                kp:update()
            end
        end ) )

        kp:update()
        options[idx] = kp

        return self
    end

    base_addons.__index = funcs
end

-- base groupbox mixin
local base_groupbox = {}

do
    local funcs = {}

    function funcs:add_blank( size: number )
        library:create( "Frame", {
            BackgroundTransparency = 1;
            Size                   = UDim2.new( 1, 0, 0, size );
            ZIndex                 = 1;
            Parent                 = self.container;
        } )
    end

    function funcs:add_label( text: string, wrap: boolean? )
        local label = {}
        local groupbox = self

        local text_label = library:create_label( {
            Size           = UDim2.new( 1, -4, 0, 15 );
            TextSize       = 14;
            Text           = text;
            TextWrapped    = wrap or false;
            TextXAlignment = Enum.TextXAlignment.Left;
            ZIndex         = 5;
            Parent         = self.container;
        } )

        if wrap then
            local _, y = library:get_text_bounds( text, library.font, 14, Vector2.new( text_label.AbsoluteSize.X, math.huge ) )
            text_label.Size = UDim2.new( 1, -4, 0, y )
        else
            library:create( "UIListLayout", {
                Padding              = UDim.new( 0, 4 );
                FillDirection        = Enum.FillDirection.Horizontal;
                HorizontalAlignment  = Enum.HorizontalAlignment.Right;
                SortOrder            = Enum.SortOrder.LayoutOrder;
                Parent               = text_label;
            } )
        end

        label.text_label = text_label
        label.container  = self.container

        function label:set_text( new_text: string )
            text_label.Text = new_text

            if wrap then
                local _, y = library:get_text_bounds( new_text, library.font, 14, Vector2.new( text_label.AbsoluteSize.X, math.huge ) )
                text_label.Size = UDim2.new( 1, -4, 0, y )
            end

            groupbox:resize()
        end

        if not wrap then
            setmetatable( label, base_addons )
        end

        self:add_blank( 5 )
        self:resize()

        return label
    end

    function funcs:add_button( info_or_text: { [string]: any } | string, func: ( () -> () )? )
        local btn = {}

        local function parse( obj: any, arg1: any, arg2: any )
            if type( arg1 ) == "table" then
                obj.text         = arg1.Text
                obj.func         = arg1.Func
                obj.double_click = arg1.DoubleClick
                obj.tooltip      = arg1.Tooltip
            else
                obj.text = arg1
                obj.func = arg2
            end

            assert( type( obj.func ) == "function", "add_button: missing Func callback" )
        end

        parse( btn, info_or_text, func )

        local function build_btn( b: any ): ( Frame, Frame, TextLabel )
            local outer = library:create( "Frame", {
                BackgroundColor3 = Color3.new( 0, 0, 0 );
                BorderColor3     = Color3.new( 0, 0, 0 );
                Size             = UDim2.new( 1, -4, 0, 20 );
                ZIndex           = 5;
            } ) :: Frame

            local inner = library:create( "Frame", {
                BackgroundColor3 = library.main_color;
                BorderColor3     = library.outline_color;
                BorderMode       = Enum.BorderMode.Inset;
                Size             = UDim2.new( 1, 0, 1, 0 );
                ZIndex           = 6;
                Parent           = outer;
            } ) :: Frame

            local lbl = library:create_label( {
                Size     = UDim2.new( 1, 0, 1, 0 );
                TextSize = 14;
                Text     = b.text;
                ZIndex   = 6;
                Parent   = inner;
            } )

            library:create( "UIGradient", {
                Color = ColorSequence.new( {
                    ColorSequenceKeypoint.new( 0, Color3.new( 1, 1, 1 ) ),
                    ColorSequenceKeypoint.new( 1, Color3.fromRGB( 212, 212, 212 ) ),
                } );
                Rotation = 90;
                Parent   = inner;
            } )

            library:add_to_registry( outer, { BorderColor3 = "black" } )
            library:add_to_registry( inner, { BackgroundColor3 = "main_color"; BorderColor3 = "outline_color" } )

            library:on_highlight( outer, outer,
                { BorderColor3 = "accent_color" },
                { BorderColor3 = "black" }
            )

            return outer :: Frame, inner :: Frame, lbl :: TextLabel
        end

        local function bind_events( b: any )
            local function valid_click( input: InputObject ): boolean
                if library:mouse_is_over_opened_frame() then return false end
                return input.UserInputType == Enum.UserInputType.MouseButton1
            end

            b.outer.InputBegan:Connect( function( input: InputObject )
                if not valid_click( input ) or b.locked then return end

                if b.double_click then
                    library:remove_from_registry( b.label )
                    library:add_to_registry( b.label, { TextColor3 = "accent_color" } )
                    b.label.TextColor3 = library.accent_color
                    b.label.Text = "Are you sure?"
                    b.locked = true

                    local clicked = false
                    local bind: RBXScriptConnection
                    bind = b.outer.InputBegan:Connect( function( inp: InputObject )
                        if valid_click( inp ) then
                            clicked = true
                        end
                        bind:Disconnect()
                    end )

                    task.wait( 0.5 )
                    bind:Disconnect()

                    library:remove_from_registry( b.label )
                    library:add_to_registry( b.label, { TextColor3 = "font_color" } )
                    b.label.TextColor3 = library.font_color
                    b.label.Text = b.text
                    task.defer( rawset, b, "locked", false )

                    if clicked then
                        library:safe_callback( b.func )
                    end

                    return
                end

                library:safe_callback( b.func )
            end )
        end

        btn.outer, btn.inner, btn.label = build_btn( btn )
        btn.outer.Parent = self.container

        bind_events( btn )

        function btn:add_tooltip( tip: string )
            if type( tip ) == "string" then
                library:add_tooltip( tip, self.outer )
            end
            return self
        end

        function btn:add_button( ... )
            local sub = {}
            parse( sub, ... )

            self.outer.Size = UDim2.new( 0.5, -2, 0, 20 )
            sub.outer, sub.inner, sub.label = build_btn( sub )
            sub.outer.Position = UDim2.new( 1, 3, 0, 0 )
            sub.outer.Size = UDim2.fromOffset( self.outer.AbsoluteSize.X - 2, self.outer.AbsoluteSize.Y )
            sub.outer.Parent = self.outer

            bind_events( sub )

            function sub:add_tooltip( tip: string )
                if type( tip ) == "string" then library:add_tooltip( tip, self.outer ) end
                return sub
            end

            if type( sub.tooltip ) == "string" then sub:add_tooltip( sub.tooltip ) end
            return sub
        end

        if type( btn.tooltip ) == "string" then btn:add_tooltip( btn.tooltip ) end

        self:add_blank( 5 )
        self:resize()

        return btn
    end

    function funcs:add_divider()
        self:add_blank( 2 )

        local div_outer = library:create( "Frame", {
            BackgroundColor3 = Color3.new( 0, 0, 0 );
            BorderColor3     = Color3.new( 0, 0, 0 );
            Size             = UDim2.new( 1, -4, 0, 5 );
            ZIndex           = 5;
            Parent           = self.container;
        } )

        local div_inner = library:create( "Frame", {
            BackgroundColor3 = library.main_color;
            BorderColor3     = library.outline_color;
            BorderMode       = Enum.BorderMode.Inset;
            Size             = UDim2.new( 1, 0, 1, 0 );
            ZIndex           = 6;
            Parent           = div_outer;
        } )

        library:add_to_registry( div_outer, { BorderColor3 = "black" } )
        library:add_to_registry( div_inner, { BackgroundColor3 = "main_color"; BorderColor3 = "outline_color" } )

        self:add_blank( 9 )
        self:resize()
    end

    function funcs:add_input( idx: string, info: { [string]: any } )
        assert( info.Text, "add_input: missing Text" )

        local textbox = {
            value    = info.Default or "" :: string;
            numeric  = info.Numeric or false;
            finished = info.Finished or false;
            type     = "input";
            callback = info.Callback or function() end;
        }

        local groupbox = self

        library:create_label( {
            Size           = UDim2.new( 1, 0, 0, 15 );
            TextSize       = 14;
            Text           = info.Text;
            TextXAlignment = Enum.TextXAlignment.Left;
            ZIndex         = 5;
            Parent         = self.container;
        } )

        self:add_blank( 1 )

        local box_outer = library:create( "Frame", {
            BackgroundColor3 = Color3.new( 0, 0, 0 );
            BorderColor3     = Color3.new( 0, 0, 0 );
            Size             = UDim2.new( 1, -4, 0, 20 );
            ZIndex           = 5;
            Parent           = self.container;
        } )

        local box_inner = library:create( "Frame", {
            BackgroundColor3 = library.main_color;
            BorderColor3     = library.outline_color;
            BorderMode       = Enum.BorderMode.Inset;
            Size             = UDim2.new( 1, 0, 1, 0 );
            ZIndex           = 6;
            Parent           = box_outer;
        } )

        library:add_to_registry( box_inner, { BackgroundColor3 = "main_color"; BorderColor3 = "outline_color" } )

        library:on_highlight( box_outer, box_outer,
            { BorderColor3 = "accent_color" },
            { BorderColor3 = "black" }
        )

        if type( info.Tooltip ) == "string" then
            library:add_tooltip( info.Tooltip, box_outer )
        end

        library:create( "UIGradient", {
            Color = ColorSequence.new( {
                ColorSequenceKeypoint.new( 0, Color3.new( 1, 1, 1 ) ),
                ColorSequenceKeypoint.new( 1, Color3.fromRGB( 212, 212, 212 ) ),
            } );
            Rotation = 90;
            Parent   = box_inner;
        } )

        local clip_frame = library:create( "Frame", {
            BackgroundTransparency = 1;
            ClipsDescendants       = true;
            Position               = UDim2.new( 0, 5, 0, 0 );
            Size                   = UDim2.new( 1, -5, 1, 0 );
            ZIndex                 = 7;
            Parent                 = box_inner;
        } )

        local box = library:create( "TextBox", {
            BackgroundTransparency = 1;
            Position               = UDim2.fromOffset( 0, 0 );
            Size                   = UDim2.fromScale( 5, 1 );
            Font                   = library.font;
            PlaceholderColor3      = Color3.fromRGB( 190, 190, 190 );
            PlaceholderText        = info.Placeholder or "";
            Text                   = info.Default or "";
            TextColor3             = library.font_color;
            TextSize               = 14;
            TextStrokeTransparency = 0;
            TextXAlignment         = Enum.TextXAlignment.Left;
            ZIndex                 = 7;
            Parent                 = clip_frame;
        } ) :: TextBox

        library:apply_text_stroke( box )
        library:add_to_registry( box, { TextColor3 = "font_color" } )

        function textbox:set_value( text: string )
            if info.MaxLength and #text > info.MaxLength then
                text = text:sub( 1, info.MaxLength )
            end

            if textbox.numeric and not tonumber( text ) and #text > 0 then
                text = textbox.value
            end

            textbox.value = text
            box.Text = text

            library:safe_callback( textbox.callback, textbox.value )
            library:safe_callback( textbox.changed, textbox.value )
        end

        if textbox.finished then
            box.FocusLost:Connect( function( enter: boolean )
                if not enter then return end
                textbox:set_value( box.Text )
                library:attempt_save()
            end )
        else
            box:GetPropertyChangedSignal( "Text" ):Connect( function()
                textbox:set_value( box.Text )
                library:attempt_save()
            end )
        end

        -- cursor scroll
        local function update_cursor()
            local padding = 2
            local reveal  = clip_frame.AbsoluteSize.X

            if not box:IsFocused() or box.TextBounds.X <= reveal - 2 * padding then
                box.Position = UDim2.new( 0, padding, 0, 0 )
                return
            end

            local cursor = box.CursorPosition
            if cursor == -1 then return end

            local sub   = box.Text:sub( 1, cursor - 1 )
            local width = text_service:GetTextSize( sub, box.TextSize, box.Font, Vector2.new( math.huge, math.huge ) ).X
            local cur_x = box.Position.X.Offset + width

            if cur_x < padding then
                box.Position = UDim2.fromOffset( padding - width, 0 )
            elseif cur_x > reveal - padding - 1 then
                box.Position = UDim2.fromOffset( reveal - width - padding - 1, 0 )
            end
        end

        task.spawn( update_cursor )
        box:GetPropertyChangedSignal( "Text" ):Connect( update_cursor )
        box:GetPropertyChangedSignal( "CursorPosition" ):Connect( update_cursor )
        box.FocusLost:Connect( update_cursor )
        box.Focused:Connect( update_cursor )

        function textbox:on_changed( func: ( string ) -> () )
            textbox.changed = func
            func( textbox.value )
        end

        self:add_blank( 5 )
        self:resize()

        options[idx] = textbox
        return textbox
    end

    function funcs:add_toggle( idx: string, info: { [string]: any } )
        assert( info.Text, "add_toggle: missing Text" )

        local toggle = {
            value    = info.Default or false :: boolean;
            type     = "toggle";
            callback = info.Callback or function() end;
            addons   = {} :: { any };
            risky    = info.Risky;
        }

        local groupbox = self

        local tog_outer = library:create( "Frame", {
            BackgroundColor3 = Color3.new( 0, 0, 0 );
            BorderColor3     = Color3.new( 0, 0, 0 );
            Size             = UDim2.new( 0, 13, 0, 13 );
            ZIndex           = 5;
            Parent           = self.container;
        } )

        library:add_to_registry( tog_outer, { BorderColor3 = "black" } )

        local tog_inner = library:create( "Frame", {
            BackgroundColor3 = library.main_color;
            BorderColor3     = library.outline_color;
            BorderMode       = Enum.BorderMode.Inset;
            Size             = UDim2.new( 1, 0, 1, 0 );
            ZIndex           = 6;
            Parent           = tog_outer;
        } )

        library:add_to_registry( tog_inner, { BackgroundColor3 = "main_color"; BorderColor3 = "outline_color" } )

        local tog_label = library:create_label( {
            Size           = UDim2.new( 0, 216, 1, 0 );
            Position       = UDim2.new( 1, 6, 0, 0 );
            TextSize       = 14;
            Text           = info.Text;
            TextXAlignment = Enum.TextXAlignment.Left;
            ZIndex         = 6;
            Parent         = tog_inner;
        } )

        library:create( "UIListLayout", {
            Padding             = UDim.new( 0, 4 );
            FillDirection       = Enum.FillDirection.Horizontal;
            HorizontalAlignment = Enum.HorizontalAlignment.Right;
            SortOrder           = Enum.SortOrder.LayoutOrder;
            Parent              = tog_label;
        } )

        local tog_region = library:create( "Frame", {
            BackgroundTransparency = 1;
            Size                   = UDim2.new( 0, 170, 1, 0 );
            ZIndex                 = 8;
            Parent                 = tog_outer;
        } )

        library:on_highlight( tog_region, tog_outer,
            { BorderColor3 = "accent_color" },
            { BorderColor3 = "black" }
        )

        if type( info.Tooltip ) == "string" then
            library:add_tooltip( info.Tooltip, tog_region )
        end

        function toggle:display()
            tog_inner.BackgroundColor3 = toggle.value and library.accent_color or library.main_color
            tog_inner.BorderColor3     = toggle.value and library.accent_color_dark or library.outline_color

            library.registry_map[tog_inner].properties.BackgroundColor3 = toggle.value and "accent_color" or "main_color"
            library.registry_map[tog_inner].properties.BorderColor3     = toggle.value and "accent_color_dark" or "outline_color"
        end

        function toggle:on_changed( func: ( boolean ) -> () )
            toggle.changed = func
            func( toggle.value )
        end

        function toggle:set_value( val: boolean )
            toggle.value = not not val
            toggle:display()

            for _, addon in toggle.addons do
                if addon.type == "key_picker" and addon.sync_toggle then
                    addon.toggled = val
                    addon:update()
                end
            end

            library:safe_callback( toggle.callback, toggle.value )
            library:safe_callback( toggle.changed, toggle.value )
            library:update_dependency_boxes()
        end

        tog_region.InputBegan:Connect( function( input: InputObject )
            if input.UserInputType == Enum.UserInputType.MouseButton1
            and not library:mouse_is_over_opened_frame() then
                toggle:set_value( not toggle.value )
                library:attempt_save()
            end
        end )

        if toggle.risky then
            library:remove_from_registry( tog_label )
            tog_label.TextColor3 = library.risk_color
            library:add_to_registry( tog_label, { TextColor3 = "risk_color" } )
        end

        toggle:display()
        self:add_blank( info.BlankSize or 7 )
        self:resize()

        toggle.text_label = tog_label
        toggle.container  = self.container
        setmetatable( toggle, base_addons )

        toggles[idx] = toggle
        library:update_dependency_boxes()

        return toggle
    end

    function funcs:add_slider( idx: string, info: { [string]: any } )
        assert( info.Default,  "add_slider: missing Default" )
        assert( info.Text,     "add_slider: missing Text" )
        assert( info.Min,      "add_slider: missing Min" )
        assert( info.Max,      "add_slider: missing Max" )
        assert( info.Rounding ~= nil, "add_slider: missing Rounding" )

        local slider = {
            value    = info.Default :: number;
            min      = info.Min     :: number;
            max      = info.Max     :: number;
            rounding = info.Rounding :: number;
            max_size = 232;
            type     = "slider";
            callback = info.Callback or function() end;
        }

        local groupbox = self

        if not info.Compact then
            library:create_label( {
                Size           = UDim2.new( 1, 0, 0, 10 );
                TextSize       = 14;
                Text           = info.Text;
                TextXAlignment = Enum.TextXAlignment.Left;
                TextYAlignment = Enum.TextYAlignment.Bottom;
                ZIndex         = 5;
                Parent         = self.container;
            } )

            self:add_blank( 3 )
        end

        local sl_outer = library:create( "Frame", {
            BackgroundColor3 = Color3.new( 0, 0, 0 );
            BorderColor3     = Color3.new( 0, 0, 0 );
            Size             = UDim2.new( 1, -4, 0, 13 );
            ZIndex           = 5;
            Parent           = self.container;
        } )

        library:add_to_registry( sl_outer, { BorderColor3 = "black" } )

        local sl_inner = library:create( "Frame", {
            BackgroundColor3 = library.main_color;
            BorderColor3     = library.outline_color;
            BorderMode       = Enum.BorderMode.Inset;
            Size             = UDim2.new( 1, 0, 1, 0 );
            ZIndex           = 6;
            Parent           = sl_outer;
        } )

        library:add_to_registry( sl_inner, { BackgroundColor3 = "main_color"; BorderColor3 = "outline_color" } )

        local fill = library:create( "Frame", {
            BackgroundColor3 = library.accent_color;
            BorderColor3     = library.accent_color_dark;
            Size             = UDim2.new( 0, 0, 1, 0 );
            ZIndex           = 7;
            Parent           = sl_inner;
        } )

        library:add_to_registry( fill, { BackgroundColor3 = "accent_color"; BorderColor3 = "accent_color_dark" } )

        local hide_border = library:create( "Frame", {
            BackgroundColor3 = library.accent_color;
            BorderSizePixel  = 0;
            Position         = UDim2.new( 1, 0, 0, 0 );
            Size             = UDim2.new( 0, 1, 1, 0 );
            ZIndex           = 8;
            Parent           = fill;
        } )

        library:add_to_registry( hide_border, { BackgroundColor3 = "accent_color" } )

        local display_label = library:create_label( {
            Size     = UDim2.new( 1, 0, 1, 0 );
            TextSize = 14;
            Text     = "0";
            ZIndex   = 9;
            Parent   = sl_inner;
        } )

        library:on_highlight( sl_outer, sl_outer,
            { BorderColor3 = "accent_color" },
            { BorderColor3 = "black" }
        )

        if type( info.Tooltip ) == "string" then
            library:add_tooltip( info.Tooltip, sl_outer )
        end

        local function do_round( val: number ): number
            if slider.rounding == 0 then
                return math.floor( val )
            end
            return tonumber( string.format( "%." .. slider.rounding .. "f", val ) ) :: number
        end

        function slider:display()
            local suffix = info.Suffix or ""

            if info.Compact then
                display_label.Text = info.Text .. ": " .. slider.value .. suffix
            elseif info.HideMax then
                display_label.Text = slider.value .. suffix
            else
                display_label.Text = string.format( "%s/%s", slider.value .. suffix, slider.max .. suffix )
            end

            local x = math.ceil( library:map_value( slider.value, slider.min, slider.max, 0, slider.max_size ) )
            fill.Size = UDim2.new( 0, x, 1, 0 )
            hide_border.Visible = x ~= slider.max_size and x ~= 0
        end

        function slider:on_changed( func: ( number ) -> () )
            slider.changed = func
            func( slider.value )
        end

        function slider:get_value_from_x( x: number ): number
            return do_round( library:map_value( x, 0, slider.max_size, slider.min, slider.max ) )
        end

        function slider:set_value( num: number | string )
            local n = tonumber( num )
            if not n then return end

            n = math.clamp( n, slider.min, slider.max )
            slider.value = n
            slider:display()

            library:safe_callback( slider.callback, slider.value )
            library:safe_callback( slider.changed, slider.value )
        end

        sl_inner.InputBegan:Connect( function( input: InputObject )
            if input.UserInputType ~= Enum.UserInputType.MouseButton1
            or library:mouse_is_over_opened_frame() then
                return
            end

            local m_pos = mouse.X
            local g_pos = fill.Size.X.Offset
            local diff  = m_pos - ( fill.AbsolutePosition.X + g_pos )

            while input_service:IsMouseButtonPressed( Enum.UserInputType.MouseButton1 ) do
                local nx     = math.clamp( g_pos + ( mouse.X - m_pos ) + diff, 0, slider.max_size )
                local n_val  = slider:get_value_from_x( nx )
                local old    = slider.value

                slider.value = n_val
                slider:display()

                if n_val ~= old then
                    library:safe_callback( slider.callback, slider.value )
                    library:safe_callback( slider.changed, slider.value )
                end

                render_stepped:Wait()
            end

            library:attempt_save()
        end )

        slider:display()
        self:add_blank( info.BlankSize or 6 )
        self:resize()

        options[idx] = slider
        return slider
    end

    function funcs:add_dropdown( idx: string, info: { [string]: any } )
        if info.SpecialType == "player" then
            info.Values   = get_players_string()
            info.AllowNull = true
        elseif info.SpecialType == "team" then
            info.Values   = get_teams_string()
            info.AllowNull = true
        end

        assert( info.Values, "add_dropdown: missing Values" )
        assert( info.AllowNull or info.Default, "add_dropdown: missing Default (or set AllowNull)" )

        if not info.Text then info.Compact = true end

        local dropdown = {
            values       = info.Values :: { string };
            value        = info.Multi and {} or nil :: any;
            multi        = info.Multi;
            type         = "dropdown";
            special_type = info.SpecialType;
            callback     = info.Callback or function() end;
        }

        if not info.Compact then
            library:create_label( {
                Size           = UDim2.new( 1, 0, 0, 10 );
                TextSize       = 14;
                Text           = info.Text;
                TextXAlignment = Enum.TextXAlignment.Left;
                TextYAlignment = Enum.TextYAlignment.Bottom;
                ZIndex         = 5;
                Parent         = self.container;
            } )

            self:add_blank( 3 )
        end

        local groupbox = self

        local dd_outer = library:create( "Frame", {
            BackgroundColor3 = Color3.new( 0, 0, 0 );
            BorderColor3     = Color3.new( 0, 0, 0 );
            Size             = UDim2.new( 1, -4, 0, 20 );
            ZIndex           = 5;
            Parent           = self.container;
        } )

        library:add_to_registry( dd_outer, { BorderColor3 = "black" } )

        local dd_inner = library:create( "Frame", {
            BackgroundColor3 = library.main_color;
            BorderColor3     = library.outline_color;
            BorderMode       = Enum.BorderMode.Inset;
            Size             = UDim2.new( 1, 0, 1, 0 );
            ZIndex           = 6;
            Parent           = dd_outer;
        } )

        library:add_to_registry( dd_inner, { BackgroundColor3 = "main_color"; BorderColor3 = "outline_color" } )

        library:create( "UIGradient", {
            Color = ColorSequence.new( {
                ColorSequenceKeypoint.new( 0, Color3.new( 1, 1, 1 ) ),
                ColorSequenceKeypoint.new( 1, Color3.fromRGB( 212, 212, 212 ) ),
            } );
            Rotation = 90;
            Parent   = dd_inner;
        } )

        local dd_arrow = library:create( "ImageLabel", {
            AnchorPoint         = Vector2.new( 0, 0.5 );
            BackgroundTransparency = 1;
            Position            = UDim2.new( 1, -16, 0.5, 0 );
            Size                = UDim2.new( 0, 12, 0, 12 );
            Image               = "http://www.roblox.com/asset/?id=6282522798";
            ZIndex              = 8;
            Parent              = dd_inner;
        } )

        local item_list = library:create_label( {
            Position       = UDim2.new( 0, 5, 0, 0 );
            Size           = UDim2.new( 1, -5, 1, 0 );
            TextSize       = 14;
            Text           = "--";
            TextXAlignment = Enum.TextXAlignment.Left;
            TextWrapped    = true;
            ZIndex         = 7;
            Parent         = dd_inner;
        } )

        library:on_highlight( dd_outer, dd_outer,
            { BorderColor3 = "accent_color" },
            { BorderColor3 = "black" }
        )

        if type( info.Tooltip ) == "string" then
            library:add_tooltip( info.Tooltip, dd_outer )
        end

        local max_items = 8

        local list_outer = library:create( "Frame", {
            BackgroundColor3 = Color3.new( 0, 0, 0 );
            BorderColor3     = Color3.new( 0, 0, 0 );
            ZIndex           = 20;
            Visible          = false;
            Parent           = screen_gui;
        } )

        local function recalc_position()
            list_outer.Position = UDim2.fromOffset(
                dd_outer.AbsolutePosition.X,
                dd_outer.AbsolutePosition.Y + dd_outer.Size.Y.Offset + 1
            )
        end

        local function recalc_size( y: number? )
            list_outer.Size = UDim2.fromOffset( dd_outer.AbsoluteSize.X, y or ( max_items * 20 + 2 ) )
        end

        recalc_position()
        recalc_size()

        dd_outer:GetPropertyChangedSignal( "AbsolutePosition" ):Connect( recalc_position )

        local list_inner = library:create( "Frame", {
            BackgroundColor3 = library.main_color;
            BorderColor3     = library.outline_color;
            BorderMode       = Enum.BorderMode.Inset;
            BorderSizePixel  = 0;
            Size             = UDim2.new( 1, 0, 1, 0 );
            ZIndex           = 21;
            Parent           = list_outer;
        } )

        library:add_to_registry( list_inner, { BackgroundColor3 = "main_color"; BorderColor3 = "outline_color" } )

        local scrolling = library:create( "ScrollingFrame", {
            BackgroundTransparency = 1;
            BorderSizePixel        = 0;
            CanvasSize             = UDim2.new( 0, 0, 0, 0 );
            Size                   = UDim2.new( 1, 0, 1, 0 );
            ZIndex                 = 21;
            ScrollBarThickness     = 3;
            ScrollBarImageColor3   = library.accent_color;
            TopImage               = "rbxasset://textures/ui/Scroll/scroll-middle.png";
            BottomImage            = "rbxasset://textures/ui/Scroll/scroll-middle.png";
            Parent                 = list_inner;
        } )

        library:add_to_registry( scrolling, { ScrollBarImageColor3 = "accent_color" } )

        library:create( "UIListLayout", {
            Padding       = UDim.new( 0, 0 );
            FillDirection = Enum.FillDirection.Vertical;
            SortOrder     = Enum.SortOrder.LayoutOrder;
            Parent        = scrolling;
        } )

        function dropdown:display()
            local str = ""

            if info.Multi then
                for _, v in dropdown.values do
                    if dropdown.value[v] then
                        str = str .. v .. ", "
                    end
                end
                str = str:sub( 1, #str - 2 )
            else
                str = dropdown.value or ""
            end

            item_list.Text = str == "" and "--" or str
        end

        function dropdown:get_active_count(): number
            if info.Multi then
                local n = 0
                for _ in dropdown.value do n += 1 end
                return n
            else
                return dropdown.value and 1 or 0
            end
        end

        function dropdown:build_list()
            for _, child in scrolling:GetChildren() do
                if not child:IsA( "UIListLayout" ) then
                    child:Destroy()
                end
            end

            local count = 0
            local btns  = {}

            for _, val in dropdown.values do
                count += 1

                local btn = library:create( "Frame", {
                    BackgroundColor3 = library.main_color;
                    BorderColor3     = library.outline_color;
                    BorderMode       = Enum.BorderMode.Middle;
                    Size             = UDim2.new( 1, -1, 0, 20 );
                    ZIndex           = 23;
                    Active           = true;
                    Parent           = scrolling;
                } )

                library:add_to_registry( btn, { BackgroundColor3 = "main_color"; BorderColor3 = "outline_color" } )

                local btn_label = library:create_label( {
                    Active         = false;
                    Size           = UDim2.new( 1, -6, 1, 0 );
                    Position       = UDim2.new( 0, 6, 0, 0 );
                    TextSize       = 14;
                    Text           = val;
                    TextXAlignment = Enum.TextXAlignment.Left;
                    ZIndex         = 25;
                    Parent         = btn;
                } )

                library:on_highlight( btn, btn,
                    { BorderColor3 = "accent_color"; ZIndex = 24 },
                    { BorderColor3 = "outline_color"; ZIndex = 23 }
                )

                local entry = {}

                function entry:update_btn()
                    local selected = info.Multi and dropdown.value[val] or dropdown.value == val
                    btn_label.TextColor3 = selected and library.accent_color or library.font_color
                    library.registry_map[btn_label].properties.TextColor3 = selected and "accent_color" or "font_color"
                end

                btn_label.InputBegan:Connect( function( input: InputObject )
                    if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
                        return
                    end

                    local selected = info.Multi and dropdown.value[val] or dropdown.value == val
                    local try_val  = not selected

                    if dropdown:get_active_count() == 1 and not try_val and not info.AllowNull then
                        return
                    end

                    if info.Multi then
                        dropdown.value[val] = try_val or nil
                    else
                        dropdown.value = try_val and val or nil

                        for _, other in btns do
                            other:update_btn()
                        end
                    end

                    entry:update_btn()
                    dropdown:display()

                    library:safe_callback( dropdown.callback, dropdown.value )
                    library:safe_callback( dropdown.changed, dropdown.value )
                    library:attempt_save()
                end )

                entry:update_btn()
                btns[btn] = entry
            end

            scrolling.CanvasSize = UDim2.fromOffset( 0, count * 20 + 1 )
            recalc_size( math.clamp( count * 20, 0, max_items * 20 ) + 1 )

            dropdown:display()
        end

        function dropdown:set_values( new_vals: { string }? )
            if new_vals then
                dropdown.values = new_vals
            end
            dropdown:build_list()
        end

        function dropdown:open()
            list_outer.Visible = true
            library.opened_frames[list_outer] = true
            dd_arrow.Rotation = 180
        end

        function dropdown:close()
            list_outer.Visible = false
            library.opened_frames[list_outer] = nil
            dd_arrow.Rotation = 0
        end

        function dropdown:on_changed( func: ( any ) -> () )
            dropdown.changed = func
            func( dropdown.value )
        end

        function dropdown:set_value( val: any )
            if dropdown.multi then
                local new_tbl = {}
                for v in val do
                    if table.find( dropdown.values, v ) then
                        new_tbl[v] = true
                    end
                end
                dropdown.value = new_tbl
            else
                dropdown.value = ( val and table.find( dropdown.values, val ) ) and val or nil
            end

            dropdown:build_list()
            library:safe_callback( dropdown.callback, dropdown.value )
            library:safe_callback( dropdown.changed, dropdown.value )
        end

        dd_outer.InputBegan:Connect( function( input: InputObject )
            if input.UserInputType ~= Enum.UserInputType.MouseButton1
            or library:mouse_is_over_opened_frame() then
                return
            end

            if list_outer.Visible then
                dropdown:close()
            else
                dropdown:open()
            end
        end )

        input_service.InputBegan:Connect( function( input: InputObject )
            if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
                return
            end

            local pos  = list_outer.AbsolutePosition
            local size = list_outer.AbsoluteSize

            if mouse.X < pos.X or mouse.X > pos.X + size.X
            or mouse.Y < ( pos.Y - 21 ) or mouse.Y > pos.Y + size.Y then
                dropdown:close()
            end
        end )

        dropdown:build_list()

        -- apply defaults
        if type( info.Default ) == "string" then
            if info.Multi then
                dropdown.value[info.Default] = table.find( dropdown.values, info.Default ) ~= nil
            else
                dropdown.value = table.find( dropdown.values, info.Default ) and info.Default or nil
            end
        elseif type( info.Default ) == "table" then
            for _, d in info.Default do
                if table.find( dropdown.values, d ) then
                    dropdown.value[d] = true
                end
            end
        end

        dropdown:build_list()
        dropdown:display()

        self:add_blank( info.BlankSize or 5 )
        self:resize()

        options[idx] = dropdown
        return dropdown
    end

    function funcs:add_dependency_box()
        local depbox = {
            dependencies = {} :: { { any } };
        }

        local holder = library:create( "Frame", {
            BackgroundTransparency = 1;
            Size                   = UDim2.new( 1, 0, 0, 0 );
            Visible                = false;
            Parent                 = self.container;
        } )

        local frame = library:create( "Frame", {
            BackgroundTransparency = 1;
            Size                   = UDim2.new( 1, 0, 1, 0 );
            Visible                = true;
            Parent                 = holder;
        } )

        local layout = library:create( "UIListLayout", {
            FillDirection = Enum.FillDirection.Vertical;
            SortOrder     = Enum.SortOrder.LayoutOrder;
            Parent        = frame;
        } )

        local groupbox = self

        function depbox:resize()
            holder.Size = UDim2.new( 1, 0, 0, layout.AbsoluteContentSize.Y )
            groupbox:resize()
        end

        layout:GetPropertyChangedSignal( "AbsoluteContentSize" ):Connect( function()
            depbox:resize()
        end )

        holder:GetPropertyChangedSignal( "Visible" ):Connect( function()
            depbox:resize()
        end )

        function depbox:update()
            for _, dep in depbox.dependencies do
                local elem = dep[1]
                local val  = dep[2]

                if elem.type == "toggle" and elem.value ~= val then
                    holder.Visible = false
                    depbox:resize()
                    return
                end
            end

            holder.Visible = true
            depbox:resize()
        end

        function depbox:setup_dependencies( deps: { { any } } )
            for _, d in deps do
                assert( type( d ) == "table", "setup_dependencies: dep must be a table" )
                assert( d[1], "setup_dependencies: missing element" )
                assert( d[2] ~= nil, "setup_dependencies: missing value" )
            end

            depbox.dependencies = deps
            depbox:update()
        end

        depbox.container = frame
        setmetatable( depbox, base_groupbox )
        table.insert( library.dependency_boxes, depbox )

        return depbox
    end

    base_groupbox.__index = funcs
end

-- window builder
function library:create_window( config: { [string]: any } )
    config = config or {}

    if type( config.Title ) ~= "string" then config.Title = "Window" end
    if type( config.TabPadding ) ~= "number" then config.TabPadding = 0 end
    if type( config.MenuFadeTime ) ~= "number" then config.MenuFadeTime = 0.2 end
    if typeof( config.Position ) ~= "UDim2" then config.Position = UDim2.fromOffset( 175, 50 ) end
    if typeof( config.Size ) ~= "UDim2" then config.Size = UDim2.fromOffset( 550, 600 ) end

    local anchor = Vector2.zero

    if config.Center then
        anchor           = Vector2.new( 0.5, 0.5 )
        config.Position  = UDim2.fromScale( 0.5, 0.5 )
    end

    local window = { tabs = {} :: { any } }

    local outer = self:create( "Frame", {
        AnchorPoint      = anchor;
        BackgroundColor3 = Color3.new( 0, 0, 0 );
        BorderSizePixel  = 0;
        Position         = config.Position;
        Size             = config.Size;
        Visible          = false;
        ZIndex           = 1;
        Parent           = screen_gui;
    } )

    self:make_draggable( outer, 25 )

    local inner = self:create( "Frame", {
        BackgroundColor3 = self.main_color;
        BorderColor3     = self.accent_color;
        BorderMode       = Enum.BorderMode.Inset;
        Position         = UDim2.new( 0, 1, 0, 1 );
        Size             = UDim2.new( 1, -2, 1, -2 );
        ZIndex           = 1;
        Parent           = outer;
    } )

    self:add_to_registry( inner, { BackgroundColor3 = "main_color"; BorderColor3 = "accent_color" } )

    local window_label = self:create_label( {
        Position       = UDim2.new( 0, 7, 0, 0 );
        Size           = UDim2.new( 0, 0, 0, 25 );
        Text           = config.Title;
        TextXAlignment = Enum.TextXAlignment.Left;
        ZIndex         = 1;
        Parent         = inner;
    } )

    local section_outer = self:create( "Frame", {
        BackgroundColor3 = self.background_color;
        BorderColor3     = self.outline_color;
        Position         = UDim2.new( 0, 8, 0, 25 );
        Size             = UDim2.new( 1, -16, 1, -33 );
        ZIndex           = 1;
        Parent           = inner;
    } )

    self:add_to_registry( section_outer, { BackgroundColor3 = "background_color"; BorderColor3 = "outline_color" } )

    local section_inner = self:create( "Frame", {
        BackgroundColor3 = self.background_color;
        BorderColor3     = Color3.new( 0, 0, 0 );
        BorderMode       = Enum.BorderMode.Inset;
        Size             = UDim2.new( 1, 0, 1, 0 );
        ZIndex           = 1;
        Parent           = section_outer;
    } )

    self:add_to_registry( section_inner, { BackgroundColor3 = "background_color" } )

    local tab_area = self:create( "Frame", {
        BackgroundTransparency = 1;
        Position               = UDim2.new( 0, 8, 0, 8 );
        Size                   = UDim2.new( 1, -16, 0, 21 );
        ZIndex                 = 1;
        Parent                 = section_inner;
    } )

    local tab_list = self:create( "UIListLayout", {
        Padding       = UDim.new( 0, config.TabPadding );
        FillDirection = Enum.FillDirection.Horizontal;
        SortOrder     = Enum.SortOrder.LayoutOrder;
        Parent        = tab_area;
    } )

    local tab_container = self:create( "Frame", {
        BackgroundColor3 = self.main_color;
        BorderColor3     = self.outline_color;
        Position         = UDim2.new( 0, 8, 0, 30 );
        Size             = UDim2.new( 1, -16, 1, -38 );
        ZIndex           = 2;
        Parent           = section_inner;
    } )

    self:add_to_registry( tab_container, { BackgroundColor3 = "main_color"; BorderColor3 = "outline_color" } )

    function window:set_title( title: string )
        window_label.Text = title
    end

    function window:add_tab( name: string )
        local tab = { groupboxes = {}; tabboxes = {} }

        local btn_w = library:get_text_bounds( name, library.font, 16 )

        local tab_btn = library:create( "Frame", {
            BackgroundColor3 = library.background_color;
            BorderColor3     = library.outline_color;
            Size             = UDim2.new( 0, btn_w + 12, 1, 0 );
            ZIndex           = 1;
            Parent           = tab_area;
        } )

        library:add_to_registry( tab_btn, { BackgroundColor3 = "background_color"; BorderColor3 = "outline_color" } )

        library:create_label( {
            Position = UDim2.new( 0, 0, 0, 0 );
            Size     = UDim2.new( 1, 0, 1, -1 );
            Text     = name;
            ZIndex   = 1;
            Parent   = tab_btn;
        } )

        local blocker = library:create( "Frame", {
            BackgroundColor3     = library.main_color;
            BackgroundTransparency = 1;
            BorderSizePixel      = 0;
            Position             = UDim2.new( 0, 0, 1, 0 );
            Size                 = UDim2.new( 1, 0, 0, 1 );
            ZIndex               = 3;
            Parent               = tab_btn;
        } )

        library:add_to_registry( blocker, { BackgroundColor3 = "main_color" } )

        local tab_frame = library:create( "Frame", {
            Name                   = "TabFrame";
            BackgroundTransparency = 1;
            Size                   = UDim2.new( 1, 0, 1, 0 );
            Visible                = false;
            ZIndex                 = 2;
            Parent                 = tab_container;
        } )

        local function make_side( pos: UDim2 ): ScrollingFrame
            local side = library:create( "ScrollingFrame", {
                BackgroundTransparency = 1;
                BorderSizePixel        = 0;
                Position               = pos;
                Size                   = UDim2.new( 0.5, -10, 0, 509 );
                CanvasSize             = UDim2.new( 0, 0, 0, 0 );
                ScrollBarThickness     = 0;
                BottomImage            = "";
                TopImage               = "";
                ZIndex                 = 2;
                Parent                 = tab_frame;
            } ) :: ScrollingFrame

            local layout = library:create( "UIListLayout", {
                Padding             = UDim.new( 0, 8 );
                FillDirection       = Enum.FillDirection.Vertical;
                SortOrder           = Enum.SortOrder.LayoutOrder;
                HorizontalAlignment = Enum.HorizontalAlignment.Center;
                Parent              = side;
            } )

            layout:GetPropertyChangedSignal( "AbsoluteContentSize" ):Connect( function()
                side.CanvasSize = UDim2.fromOffset( 0, layout.AbsoluteContentSize.Y )
            end )

            return side
        end

        local left_side  = make_side( UDim2.new( 0, 7, 0, 7 ) )
        local right_side = make_side( UDim2.new( 0.5, 5, 0, 7 ) )

        function tab:show()
            for _, t in window.tabs do
                t:hide()
            end

            blocker.BackgroundTransparency = 0
            tab_btn.BackgroundColor3 = library.main_color
            library.registry_map[tab_btn].properties.BackgroundColor3 = "main_color"
            tab_frame.Visible = true
        end

        function tab:hide()
            blocker.BackgroundTransparency = 1
            tab_btn.BackgroundColor3 = library.background_color
            library.registry_map[tab_btn].properties.BackgroundColor3 = "background_color"
            tab_frame.Visible = false
        end

        function tab:add_groupbox( gb_info: { [string]: any } )
            local gb = {}

            local box_outer = library:create( "Frame", {
                BackgroundColor3 = library.background_color;
                BorderColor3     = library.outline_color;
                BorderMode       = Enum.BorderMode.Inset;
                Size             = UDim2.new( 1, 0, 0, 509 );
                ZIndex           = 2;
                Parent           = gb_info.Side == 1 and left_side or right_side;
            } )

            library:add_to_registry( box_outer, { BackgroundColor3 = "background_color"; BorderColor3 = "outline_color" } )

            local box_inner = library:create( "Frame", {
                BackgroundColor3 = library.background_color;
                BorderColor3     = Color3.new( 0, 0, 0 );
                Size             = UDim2.new( 1, -2, 1, -2 );
                Position         = UDim2.new( 0, 1, 0, 1 );
                ZIndex           = 4;
                Parent           = box_outer;
            } )

            library:add_to_registry( box_inner, { BackgroundColor3 = "background_color" } )

            local gb_highlight = library:create( "Frame", {
                BackgroundColor3 = library.accent_color;
                BorderSizePixel  = 0;
                Size             = UDim2.new( 1, 0, 0, 2 );
                ZIndex           = 5;
                Parent           = box_inner;
            } )

            library:add_to_registry( gb_highlight, { BackgroundColor3 = "accent_color" } )

            library:create_label( {
                Size           = UDim2.new( 1, 0, 0, 18 );
                Position       = UDim2.new( 0, 4, 0, 2 );
                TextSize       = 14;
                Text           = gb_info.Name;
                TextXAlignment = Enum.TextXAlignment.Left;
                ZIndex         = 5;
                Parent         = box_inner;
            } )

            local container = library:create( "Frame", {
                BackgroundTransparency = 1;
                Position               = UDim2.new( 0, 4, 0, 20 );
                Size                   = UDim2.new( 1, -4, 1, -20 );
                ZIndex                 = 1;
                Parent                 = box_inner;
            } )

            library:create( "UIListLayout", {
                FillDirection = Enum.FillDirection.Vertical;
                SortOrder     = Enum.SortOrder.LayoutOrder;
                Parent        = container;
            } )

            function gb:resize()
                local size = 0

                for _, elem in gb.container:GetChildren() do
                    if not elem:IsA( "UIListLayout" ) and elem.Visible then
                        size += elem.Size.Y.Offset
                    end
                end

                box_outer.Size = UDim2.new( 1, 0, 0, 20 + size + 4 )
            end

            gb.container = container
            setmetatable( gb, base_groupbox )

            gb:add_blank( 3 )
            gb:resize()

            tab.groupboxes[gb_info.Name] = gb
            return gb
        end

        function tab:add_left_groupbox( name: string )
            return tab:add_groupbox( { Side = 1; Name = name } )
        end

        function tab:add_right_groupbox( name: string )
            return tab:add_groupbox( { Side = 2; Name = name } )
        end

        function tab:add_tabbox( tb_info: { [string]: any } )
            local tabbox = { tabs = {} :: { any } }

            local tb_outer = library:create( "Frame", {
                BackgroundColor3 = library.background_color;
                BorderColor3     = library.outline_color;
                BorderMode       = Enum.BorderMode.Inset;
                Size             = UDim2.new( 1, 0, 0, 0 );
                ZIndex           = 2;
                Parent           = tb_info.Side == 1 and left_side or right_side;
            } )

            library:add_to_registry( tb_outer, { BackgroundColor3 = "background_color"; BorderColor3 = "outline_color" } )

            local tb_inner = library:create( "Frame", {
                BackgroundColor3 = library.background_color;
                BorderColor3     = Color3.new( 0, 0, 0 );
                Size             = UDim2.new( 1, -2, 1, -2 );
                Position         = UDim2.new( 0, 1, 0, 1 );
                ZIndex           = 4;
                Parent           = tb_outer;
            } )

            library:add_to_registry( tb_inner, { BackgroundColor3 = "background_color" } )

            local tb_highlight = library:create( "Frame", {
                BackgroundColor3 = library.accent_color;
                BorderSizePixel  = 0;
                Size             = UDim2.new( 1, 0, 0, 2 );
                ZIndex           = 10;
                Parent           = tb_inner;
            } )

            library:add_to_registry( tb_highlight, { BackgroundColor3 = "accent_color" } )

            local tb_buttons = library:create( "Frame", {
                BackgroundTransparency = 1;
                Position               = UDim2.new( 0, 0, 0, 1 );
                Size                   = UDim2.new( 1, 0, 0, 18 );
                ZIndex                 = 5;
                Parent                 = tb_inner;
            } )

            library:create( "UIListLayout", {
                FillDirection       = Enum.FillDirection.Horizontal;
                HorizontalAlignment = Enum.HorizontalAlignment.Left;
                SortOrder           = Enum.SortOrder.LayoutOrder;
                Parent              = tb_buttons;
            } )

            function tabbox:add_tab( tb_name: string )
                local tbt = {}

                local btn = library:create( "Frame", {
                    BackgroundColor3 = library.main_color;
                    BorderColor3     = Color3.new( 0, 0, 0 );
                    Size             = UDim2.new( 0.5, 0, 1, 0 );
                    ZIndex           = 6;
                    Parent           = tb_buttons;
                } )

                library:add_to_registry( btn, { BackgroundColor3 = "main_color" } )

                library:create_label( {
                    Size           = UDim2.new( 1, 0, 1, 0 );
                    TextSize       = 14;
                    Text           = tb_name;
                    TextXAlignment = Enum.TextXAlignment.Center;
                    ZIndex         = 7;
                    Parent         = btn;
                } )

                local block = library:create( "Frame", {
                    BackgroundColor3 = library.background_color;
                    BorderSizePixel  = 0;
                    Position         = UDim2.new( 0, 0, 1, 0 );
                    Size             = UDim2.new( 1, 0, 0, 1 );
                    Visible          = false;
                    ZIndex           = 9;
                    Parent           = btn;
                } )

                library:add_to_registry( block, { BackgroundColor3 = "background_color" } )

                local tbt_container = library:create( "Frame", {
                    BackgroundTransparency = 1;
                    Position               = UDim2.new( 0, 4, 0, 20 );
                    Size                   = UDim2.new( 1, -4, 1, -20 );
                    ZIndex                 = 1;
                    Visible                = false;
                    Parent                 = tb_inner;
                } )

                library:create( "UIListLayout", {
                    FillDirection = Enum.FillDirection.Vertical;
                    SortOrder     = Enum.SortOrder.LayoutOrder;
                    Parent        = tbt_container;
                } )

                function tbt:show()
                    for _, t in tabbox.tabs do t:hide() end

                    tbt_container.Visible = true
                    block.Visible = true
                    btn.BackgroundColor3 = library.background_color
                    library.registry_map[btn].properties.BackgroundColor3 = "background_color"
                    tbt:resize()
                end

                function tbt:hide()
                    tbt_container.Visible = false
                    block.Visible = false
                    btn.BackgroundColor3 = library.main_color
                    library.registry_map[btn].properties.BackgroundColor3 = "main_color"
                end

                function tbt:resize()
                    local tab_count = 0
                    for _ in tabbox.tabs do tab_count += 1 end

                    for _, b in tb_buttons:GetChildren() do
                        if not b:IsA( "UIListLayout" ) then
                            b.Size = UDim2.new( 1 / tab_count, 0, 1, 0 )
                        end
                    end

                    if not tbt_container.Visible then return end

                    local size = 0
                    for _, elem in tbt.container:GetChildren() do
                        if not elem:IsA( "UIListLayout" ) and elem.Visible then
                            size += elem.Size.Y.Offset
                        end
                    end

                    tb_outer.Size = UDim2.new( 1, 0, 0, 20 + size + 4 )
                end

                btn.InputBegan:Connect( function( input: InputObject )
                    if input.UserInputType == Enum.UserInputType.MouseButton1
                    and not library:mouse_is_over_opened_frame() then
                        tbt:show()
                    end
                end )

                tbt.container = tbt_container
                tabbox.tabs[tb_name] = tbt
                setmetatable( tbt, base_groupbox )

                tbt:add_blank( 3 )
                tbt:resize()

                -- auto-show first tab
                local child_count = 0
                for _, c in tb_buttons:GetChildren() do
                    if not c:IsA( "UIListLayout" ) then
                        child_count += 1
                    end
                end

                if child_count == 1 then
                    tbt:show()
                end

                return tbt
            end

            tab.tabboxes[tb_info.Name or ""] = tabbox
            return tabbox
        end

        function tab:add_left_tabbox( name: string )
            return tab:add_tabbox( { Name = name; Side = 1 } )
        end

        function tab:add_right_tabbox( name: string )
            return tab:add_tabbox( { Name = name; Side = 2 } )
        end

        tab_btn.InputBegan:Connect( function( input: InputObject )
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                tab:show()
            end
        end )

        -- auto-show first tab
        local frame_count = 0
        for _, c in tab_container:GetChildren() do
            if c:IsA( "Frame" ) then
                frame_count += 1
            end
        end

        if frame_count == 1 then
            tab:show()
        end

        window.tabs[name] = tab
        return tab
    end

    -- toggle visibility with fade
    local transparency_cache = {} :: { [Instance]: { [string]: number } }
    local is_toggled = false
    local is_fading  = false

    function window:toggle()
        if is_fading then return end

        local fade_time = config.MenuFadeTime
        is_fading  = true
        is_toggled = not is_toggled

        if is_toggled then
            outer.Visible = true
        end

        for _, desc in outer:GetDescendants() do
            local props = {}

            if desc:IsA( "ImageLabel" ) then
                props = { "ImageTransparency"; "BackgroundTransparency" }
            elseif desc:IsA( "TextLabel" ) or desc:IsA( "TextBox" ) then
                props = { "TextTransparency" }
            elseif desc:IsA( "Frame" ) or desc:IsA( "ScrollingFrame" ) then
                props = { "BackgroundTransparency" }
            elseif desc:IsA( "UIStroke" ) then
                props = { "Transparency" }
            end

            local cache = transparency_cache[desc]
            if not cache then
                cache = {}
                transparency_cache[desc] = cache
            end

            for _, prop in props do
                if not cache[prop] then
                    cache[prop] = ( desc :: any )[prop]
                end

                if cache[prop] == 1 then
                    continue
                end

                tween_service:Create(
                    desc,
                    TweenInfo.new( fade_time, Enum.EasingStyle.Linear ),
                    { [prop] = is_toggled and cache[prop] or 1 }
                ):Play()
            end
        end

        task.wait( fade_time )

        outer.Visible = is_toggled
        is_fading = false
    end

    -- global toggle keybind
    library:give_signal( input_service.InputBegan:Connect( function( input: InputObject, processed: boolean )
        if type( library.toggle_keybind ) == "table" and library.toggle_keybind.type == "key_picker" then
            if input.UserInputType == Enum.UserInputType.Keyboard
            and input.KeyCode.Name == library.toggle_keybind.value then
                task.spawn( function() window:toggle() end )
            end
        elseif input.KeyCode == Enum.KeyCode.RightControl
        or ( input.KeyCode == Enum.KeyCode.RightShift and not processed ) then
            task.spawn( function() window:toggle() end )
        end
    end ) )

    if config.AutoShow then
        task.spawn( function() window:toggle() end )
    end

    window.holder = outer
    return window
end

getgenv().Library = library
return library
