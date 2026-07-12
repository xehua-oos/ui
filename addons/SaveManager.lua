```lua
local cloneref = (cloneref or clonereference or function(instance: any)
    return instance
end)
local clonefunction = (clonefunction or copyfunction or function(func) 
    return func 
end)

local HttpService: HttpService = cloneref(game:GetService("HttpService"))
local isfolder, isfile, listfiles = isfolder, isfile, listfiles

if typeof(clonefunction) == "function" then
    -- 修复 is_____ 函数以防止某些低质量执行器报错，这些函数应只返回布尔值而不应报错。

    local
        isfolder_copy,
        isfile_copy,
        listfiles_copy = clonefunction(isfolder), clonefunction(isfile), clonefunction(listfiles)

    local isfolder_success, isfolder_error = pcall(function()
        return isfolder_copy("test" .. tostring(math.random(1000000, 9999999)))
    end)

    if isfolder_success == false or typeof(isfolder_error) ~= "boolean" then
        isfolder = function(folder)
            local success, data = pcall(isfolder_copy, folder)
            return (if success then data else false)
        end

        isfile = function(file)
            local success, data = pcall(isfile_copy, file)
            return (if success then data else false)
        end

        listfiles = function(folder)
            local success, data = pcall(listfiles_copy, folder)
            return (if success then data else {})
        end
    end
end

local SaveManager = {
    Library = nil,

    Folder = "ObsidianLibSettings",
    SubFolder = "",

    Ignore = {},
    LoadingOrder = {},
    UseLoadingOrder = false,

    AutoloadConfig = nil
}

function SaveManager:SetLibrary(Library)
    SaveManager.Library = Library
end

--// 元素解析器 \\--
local SpecialValueParser = {
    UDim2 = {
        Encode = function(Value: UDim2)
            return {
                X = { Scale = Value.X.Scale, Offset = Value.X.Offset },
                Y = { Scale = Value.Y.Scale, Offset = Value.Y.Offset }
            }
        end,

        Decode = function(Data: any)
            local DataType = typeof(Data)
            if DataType == "table" then
                return UDim2.new(Data.X.Scale, Data.X.Offset, Data.Y.Scale, Data.Y.Offset)
            elseif DataType == "UDim2" then
                return Data
            end

            return nil
        end
    }
}

local ElementParser = {}; do
    local function CreateParser(
        ElementType: string, 
        LibaryIndex: string, 
        
        Save: (string, any, ...any) -> any, 
        Load: (any?, any) -> any,
        CustomElementFetcher: boolean?
    )
        ElementParser[ElementType] = { 
            Save = function(Index: string, Element: any, ...)
                local Data = Save(Index, Element, ...)
                Data.type = ElementType
                Data.idx = Index

                return Data
            end, 

            Load = function(Index: string?, Data: any)
                if CustomElementFetcher == true then
                    return Load(nil, Data)
                end

                local Elements = SaveManager.Library and SaveManager.Library[LibaryIndex]
                local Element = Elements and Elements[Index]
                return Load(Element, Data)
            end
        }
    end

    CreateParser(
        "Toggle", "Toggles",
        function(Index: string, Toggle: any)
            return { value = Toggle.Value }
        end,
        function(Element: any?, Data: any)
            if not Element then return end
            if Element.Value == Data.value then
                Element:RunChanged()
                return
            end
            
            Element:SetValue(Data.value)
        end
    )

    CreateParser(
        "Slider", "Options",
        function(Index: string, Slider: any)
            return { value = tostring(Slider.Value) }
        end,
        function(Element: any?, Data: any)
            if not Element then return end
            if Element.Value == Data.value then
                Element:RunChanged()
                return
            end

            Element:SetValue(Data.value)
        end
    )

    CreateParser(
        "Dropdown", "Options",
        function(Index: string, Dropdown: any)
            return { value = Dropdown.Value, multi = Dropdown.Multi }
        end,
        function(Element: any?, Data: any)
            if not Element then return end
            if Element.Value == Data.value then
                Element:RunChanged()
                return
            end
            
            Element:SetValue(Data.value)
        end
    )

    CreateParser(
        "ColorPicker", "Options",
        function(Index: string, ColorPicker: any)
            return { value = ColorPicker.Value:ToHex(), transparency = ColorPicker.Transparency }
        end,
        function(Element: any?, Data: any)
            if not Element then return end
            
            Element:SetValueRGB(Color3.fromHex(Data.value), Data.transparency)
        end
    )

    CreateParser(
        "KeyPicker", "Options",
        function(Index: string, KeyPicker: any)
            return { mode = KeyPicker.Mode, key = KeyPicker.Value, modifiers = KeyPicker.Modifiers, toggled = KeyPicker.Toggled }
        end,
        function(Element: any?, Data: any)
            if not Element then return end
            
            Element:SetValue({ Data.key, Data.mode, Data.modifiers })
            if Data.mode == "Toggle" and Data.toggled ~= nil then
                Element.Toggled = Data.toggled
                Element:Update()
            end
        end
    )

    CreateParser(
        "Input", "Options",
        function(Index: string, Input: any)
            return { text = Input.Value }
        end,
        function(Element: any?, Data: any)
            if not Element then return end
            if typeof(Data.text) ~= "string" then return end

            if Element.Value == Data.text then
                Element:RunChanged()
                return
            end

            Element:SetValue(Data.text)
        end
    )

    CreateParser(
        "Groupbox", "Tabs",
        function(Index: string, Groupbox: any, TabIndex: string)
            return { collapsed = Groupbox.Collapsed, tabIdx = TabIndex }
        end,
        function(_, Data: any)
            local TabIndex, Index = Data.tabIdx, Data.idx
            if typeof(TabIndex) ~= "string" or typeof(Index) ~= "string" then return end

            local Tabs = SaveManager.Library and SaveManager.Library.Tabs
            local Tab = Tabs and Tabs[TabIndex]
            if not Tab then return end

            local Groupbox = Tab.Groupboxes[Index]
            if not Groupbox or Groupbox.Collapsed == Data.collapsed then return end

            Groupbox:SetCollapsed(Data.collapsed == true)
        end,
        true
    )
end

--// 帮助函数 \\--
local function Trim(Text: string)
    return Text:match("^%s*(.-)%s*$")
end

local function IsStringEmpty(String: string): boolean
    return if typeof(String) == "string" then Trim(String) == "" else true
end

local function IsValidFolderPath(Name: string): boolean
    return typeof(Name) == "string" and (
        Trim(Name) ~= "" and 
        not Name:match("^%s*$") and 
        not Name:find('[<>:"|%?%*%z]')
    )
end

--// 文件夹辅助函数 \\--
local function SplitPath(Path: string): {string}
	local Result = {}
	local Current = ""

	for Part in string.gmatch(Path, "[^/]+") do
		Current = if Current == "" then Part else (Current .. "/" .. Part)
		table.insert(Result, Current)
	end

	return Result
end

local function GetFolderPath(): false | string
    if IsStringEmpty(SaveManager.Folder) then
        return false
    end

    return string.format("%s/settings", SaveManager.Folder)
end

local function GetSubFolderPath(): false | string
    if IsStringEmpty(SaveManager.Folder) or IsStringEmpty(SaveManager.SubFolder) then
        return false
    end

    return string.format("%s/settings/%s", SaveManager.Folder, SaveManager.SubFolder)
end

local function GetCurrentSettingsPath(): false | string
    local SubFolderPath = GetSubFolderPath()
    return if SubFolderPath == false then GetFolderPath() else SubFolderPath
end

--// 文件辅助函数 \\--
local function GetConfigPath(ConfigName: string): false | string
    local CurrentSettingsPath = GetCurrentSettingsPath()
    return if CurrentSettingsPath == false then false else string.format("%s/%s.json", CurrentSettingsPath, ConfigName)
end

local function DoesConfigExist(ConfigName: string): boolean
    local ConfigPath = GetConfigPath(ConfigName)
    return if ConfigPath == false then false else isfile(ConfigPath)
end

local function GetAutoloadPath(): false | string
    local CurrentSettingsPath = GetCurrentSettingsPath()
    return if CurrentSettingsPath == false then false else string.format("%s/autoload.txt", CurrentSettingsPath)
end

--// 索引忽略 \\--
function SaveManager:SetLoadingOrder(Enabled: boolean, Order: {string}?)
    SaveManager.UseLoadingOrder = Enabled == true
    SaveManager.LoadingOrder = typeof(Order) == "table" and Order or SaveManager.LoadingOrder
end

function SaveManager:SetIgnoreIndexes(Indexes: {string}?)
    assert(typeof(Indexes) == "table", "预期传入 table，实际传入 " .. typeof(Indexes))

    for _, Index in Indexes do
        SaveManager.Ignore[Index] = true
    end
end

function SaveManager:IgnoreThemeSettings()
    SaveManager:SetIgnoreIndexes({
        "BackgroundColor", "MainColor", "AccentColor", "OutlineColor", "FontColor", "FontFace", "BackgroundImage",
        "ThemeManager_ThemeList", "ThemeManager_CustomThemeList", "ThemeManager_CustomThemeName"
    })
end

--// 文件夹管理 \\--
function SaveManager:GetPaths(): {string}
    local SubFolderPath = GetSubFolderPath()
    if SubFolderPath == false then
        local FolderPath = GetFolderPath()
        return if FolderPath == false then {} else SplitPath(FolderPath)
    end

    return SplitPath(SubFolderPath)
end

function SaveManager:BuildFolderTree(SkipWhenCreated: boolean?)
    local Paths = SaveManager:GetPaths()
    if #Paths == 0 then
        return false
    end

    if SkipWhenCreated == true then
        if isfolder(Paths[1]) then
            return true
        end
    end

    for _, Path in Paths do
        if isfolder(Path) then continue end
        
        makefolder(Path)
    end

    return true
end

function SaveManager:CheckFolderTree()
    return SaveManager:BuildFolderTree(true)
end

function SaveManager:CheckSubFolder(CreateFolder: boolean)
    local SubFolderPath = GetSubFolderPath()
    if SubFolderPath == false then
        return false
    end

    local FolderExists = isfolder(SubFolderPath)
    if not CreateFolder then
        return FolderExists
    end

    makefolder(SubFolderPath)
    return true
end

function SaveManager:SetFolder(Folder: string)
    assert(IsValidFolderPath(Folder), "提供的路径无效")

    SaveManager.Folder = Folder
    SaveManager:BuildFolderTree()
end

function SaveManager:SetSubFolder(SubFolder: string)
    assert(IsValidFolderPath(SubFolder), "提供的路径无效")

    SaveManager.SubFolder = SubFolder
    SaveManager:BuildFolderTree()
end

--// 配置管理 \\--
function SaveManager:RefreshConfigList()
    local SettingsPath = GetCurrentSettingsPath()
    if SettingsPath == false then
        return {}
    end

    local SuccessList, Files = pcall(listfiles, SettingsPath)
    if not (SuccessList and typeof(Files) == "table") then
        SaveManager.Library:Notify(string.format("加载配置列表失败: %s", tostring(Files)))
        return {}
    end

    local FileNames = {}
    for _, FilePath in Files do
        local RawFileName = FilePath:match("(.+)%..+$")
        if not RawFileName then continue end

        local Position = RawFileName:gsub("\\", "/"):find("/[^/]*$")
        local FileName = Position and RawFileName:sub(Position + 1) or RawFileName
        if not FileName or FileName == "autoload" then continue end

        table.insert(FileNames, FileName)
    end

    return FileNames
end

function SaveManager:Save(ConfigName: string): (boolean, string?)
    if IsStringEmpty(ConfigName) then
        return false, "配置名称无效"
    end

    if string.lower(ConfigName) == "autoload" then
        return false, "配置名称无效"
    end

    local ConfigPath = GetConfigPath(ConfigName)
    if ConfigPath == false then
        return false, "配置名称无效"
    end

    SaveManager:CheckFolderTree()

    local Library = SaveManager.Library
    local IgnoreIndexes = SaveManager.Ignore
    local CurrentData = {
        timestamp = os.date("%d.%m.%Y %H:%M:%S"),
        name = ConfigName,

        objects = {},
        keybindMenu = if Library.KeybindFrame then {
            visible = Library.KeybindFrame.Visible,
            position = SpecialValueParser.UDim2.Encode(Library.KeybindFrame.Position)
        } else nil
    }

    --// 开关
    for Index, Toggle in Library.Toggles do
        if not Toggle.Type then continue end
        if IgnoreIndexes[Index] then continue end

        local Parser = ElementParser[Toggle.Type]
        if not Parser then continue end

        table.insert(CurrentData.objects, Parser.Save(Index, Toggle))
    end

    --// 选项
    for Index, Option in Library.Options do
        if not Option.Type then continue end
        if IgnoreIndexes[Index] then continue end

        local Parser = ElementParser[Option.Type]
        if not Parser then continue end

        table.insert(CurrentData.objects, Parser.Save(Index, Option))
    end

    --// 分组框
    for TabIndex, Tab in Library.Tabs do
        if not Tab.Groupboxes then continue end

        for Index, Groupbox in Tab.Groupboxes do
            if IgnoreIndexes[Index] then continue end

            local Parser = ElementParser.Groupbox
            if not Parser then continue end

            table.insert(CurrentData.objects, Parser.Save(Index, Groupbox, TabIndex))
        end
    end

    local SuccessEncode, EncodedData = pcall(HttpService.JSONEncode, HttpService, CurrentData)
    if not SuccessEncode then
        return false, "数据编码失败"
    end

    local SuccessWrite, ErrorMessage = pcall(writefile, ConfigPath, EncodedData)
    if not SuccessWrite then
        return false, "写入配置文件失败: " .. tostring(ErrorMessage)
    end

    return true
end

function SaveManager:Load(ConfigName: string): (boolean, string?)
    if IsStringEmpty(ConfigName) then
        return false, "未选择配置"
    end

    local ConfigPath = GetConfigPath(ConfigName)
    if ConfigPath == false or not isfile(ConfigPath) then
        return false, "配置文件不存在"
    end

    local SuccessRead, Content = pcall(readfile, ConfigPath)
    if not SuccessRead then
        return false, "读取配置文件失败"
    end

    local SuccessDecode, Decoded = pcall(HttpService.JSONDecode, HttpService, Content)
    if not SuccessDecode or typeof(Decoded) ~= "table" or typeof(Decoded.objects) ~= "table" then
        return false, "解码配置数据失败"
    end

    local Library = SaveManager.Library
    local LoadingOrder = SaveManager.LoadingOrder
    local IgnoreIndexes = SaveManager.Ignore

    if SaveManager.UseLoadingOrder == true and typeof(LoadingOrder) == "table" then
        table.sort(Decoded.objects, function(a, b)
            local aIndex = table.find(LoadingOrder, a.type) or math.huge
            local bIndex = table.find(LoadingOrder, b.type) or math.huge
            return aIndex < bIndex
        end)
    end

    --// 快捷键菜单
    if Library.KeybindFrame and typeof(Decoded.keybindMenu) == "table" then
        local KeybindFrameData = Decoded.keybindMenu
        local IsVisible = KeybindFrameData.visible == true
        local Position = SpecialValueParser.UDim2.Decode(KeybindFrameData.position)

        Library.KeybindFrame.Visible = IsVisible
        Library.KeybindFrame.Position = Position or Library.KeybindFrame.Position
        
        local KeybindMenuToggle = Library.Options and Library.Options.KeybindMenuOpen
        if KeybindMenuToggle then
            KeybindMenuToggle:SetValue(IsVisible)
        end
    end

    --// 元素
    for _, Option in Decoded.objects do
        if not Option.type then continue end
        if IgnoreIndexes[Option.idx] then continue end

        local Parser = ElementParser[Option.type]
        if not Parser then continue end

        task.defer(Parser.Load, Option.idx, Option)
    end

    return true
end

function SaveManager:Delete(ConfigName: string): (boolean | string?)
    if IsStringEmpty(ConfigName) then
        return false, "未选择配置"
    end

    local ConfigPath = GetConfigPath(ConfigName)
    if ConfigPath == false or not isfile(ConfigPath) then
        return false, "配置文件不存在"
    end

    local SuccessDelete, ErrorMessage = pcall(delfile, ConfigPath)
    if not SuccessDelete then
        return false, "删除配置文件失败: " .. tostring(ErrorMessage)
    end

    if ConfigName == SaveManager.AutoloadConfig then
        SaveManager:DeleteAutoLoadConfig()
    end

    return true
end

--// 自动加载配置 \\--
function SaveManager:GetAutoloadConfig(): (string, boolean, string?)
    SaveManager:CheckFolderTree()

    local AutoloadPath = GetAutoloadPath()
    if AutoloadPath == false then
        return "none", false, "路径无效"
    end

    if not isfile(AutoloadPath) then
        return "none", false, "未设置自动加载配置"
    end

    local SuccessRead, AutoloadConfigName = pcall(readfile, AutoloadPath)
    if not (SuccessRead and typeof(AutoloadConfigName) == "string") then
        return "none", false, AutoloadConfigName
    end

    local ConfigExists = DoesConfigExist(AutoloadConfigName)
    if not ConfigExists then
        return "none", false, "配置文件未找到"
    end

    SaveManager.AutoloadConfig = AutoloadConfigName
    return AutoloadConfigName, true
end

function SaveManager:SaveAutoloadConfig(ConfigName: string): (boolean, string?)
    if IsStringEmpty(ConfigName) then
        return false, "未选择配置"
    end

    SaveManager:CheckFolderTree()

    local AutoloadPath = GetAutoloadPath()
    if AutoloadPath == false then
        return false, "路径无效"
    end

    if not DoesConfigExist(ConfigName) then
        return false, "配置不存在"
    end

    local SuccessWrite, ErrorMessage = pcall(writefile, AutoloadPath, ConfigName)
    if not SuccessWrite then
        return false, ErrorMessage
    end

    SaveManager.AutoloadConfig = ConfigName
    return true
end

function SaveManager:LoadAutoloadConfig()
    local ConfigName, Success, FetchErrorMessage = SaveManager:GetAutoloadConfig()
    if not Success or FetchErrorMessage then
        if FetchErrorMessage ~= "未设置自动加载配置" then
            SaveManager.Library:Notify(string.format("加载自动加载配置失败: %s", FetchErrorMessage))
        end

        return
    end

    local SuccessLoad, LoadErrorMessage = SaveManager:Load(ConfigName)
    if not SuccessLoad then
        SaveManager.Library:Notify(string.format("加载自动加载配置失败: %s", LoadErrorMessage))
        return
    end

    SaveManager.Library:Notify(string.format("成功加载自动加载配置 \"%s\"", ConfigName))
end

function SaveManager:DeleteAutoLoadConfig(): (boolean, string?)
    SaveManager:CheckFolderTree()

    local AutoloadPath = GetAutoloadPath()
    if AutoloadPath == false then
        return false, "路径无效"
    end

    if not isfile(AutoloadPath) then
        return false, "未设置自动加载配置"
    end

    local SuccessDelete, ErrorMessage = pcall(delfile, AutoloadPath)
    if not SuccessDelete then
        return false, ErrorMessage
    end

    SaveManager.AutoloadConfig = nil
    return true
end

--// GUI \\--
local function ShowDialog(
    Condition: () -> boolean,

    Index: string, 
    Title: string, 
    Description: string,

    DestructiveText: string,
    DestructiveAction: () -> nil
)
    if Condition() == false then
        return DestructiveAction()
    end

    return SaveManager.Library.Window:AddDialog(Index, {
        Title = Title,
        Description = Description,
        AutoDismiss = false,

        FooterButtons = {
            Cancel = {
                Title = "取消",
                Variant = "Ghost",
                Order = 1,
                Callback = function(Dialog)
                    Dialog:Dismiss()
                end
            },

            DestructiveAction = {
                Title = DestructiveText,
                Variant = "Destructive",
                Order = 2,
                Callback = function(Dialog)
                    Dialog:Dismiss()
                    DestructiveAction()
                end
            }
        }
    })
end

function SaveManager:BuildConfigSection(Tab: any, IconName: string)
    assert(SaveManager.Library, "未设置 Library，请先调用 SaveManager:SetLibrary(Library)")
    local ConfigurationBox = Tab:AddRightGroupbox("配置管理", IconName or "folder-cog")
    
    local ConfigNameInput, ConfigList, AutoloadConfigLabel
    local function RefreshList()
        ConfigList:SetValues(SaveManager:RefreshConfigList())
        ConfigList:SetValue(nil)
    end

    local function RefreshAutoloadConfigLabel()
        local AutoloadConfigName, _Success, _ErrorMessage = SaveManager:GetAutoloadConfig()

        AutoloadConfigLabel:SetText(string.format("当前自动加载配置: %s", AutoloadConfigName))
        if ConfigList then RefreshList() end
    end

    --// 创建
    ConfigurationBox:AddInput("SaveManager_ConfigName", {
        Text = "配置名称"
    })

    ConfigurationBox:AddButton("创建配置", function()
        local ConfigName = ConfigNameInput.Value
        if IsStringEmpty(ConfigName) then
            SaveManager.Library:Notify("配置名称不能为空。")
            return
        end

        if string.lower(ConfigName) == "autoload" then
            SaveManager.Library:Notify("配置名称无效。")
            return
        end
        
        ShowDialog(
            function(): boolean
                return DoesConfigExist(ConfigName)
            end,

            "SaveManager_CreateConfig",
            "配置已存在",
            string.format("名为 \"%s\" 的配置已存在。覆盖将用当前设置替换它。", ConfigName),

            "覆盖",
            function()
                local Success, ErrorMessage = SaveManager:Save(ConfigName)
                if not Success then
                    SaveManager.Library:Notify(string.format("创建配置 \"%s\" 失败: %s", ConfigName, ErrorMessage))
                    return
                end

                SaveManager.Library:Notify(string.format("成功创建配置 \"%s\"", ConfigName))
                RefreshList()
            end
        )
    end)

    ConfigurationBox:AddDivider()

    --// 管理
    ConfigurationBox:AddDropdown("SaveManager_ConfigList", {
        Text = "配置列表",

        Values = SaveManager:RefreshConfigList(),
        AllowNull = true,
        Multi = false,

        FormatDisplayValue = function(Value: any)
            if Value == SaveManager.AutoloadConfig then
                return string.format("%s (自动加载)", Value)
            end

            return Value
        end,
        FormatListValue = function(Value: any)
            if Value == SaveManager.AutoloadConfig then
                return string.format("%s (自动加载)", Value)
            end

            return Value
        end
    })

    ConfigurationBox:AddButton({
        Text = "加载配置",
        DoubleClick = false,

        Func = function()
            local ConfigName = ConfigList.Value
            if IsStringEmpty(ConfigName) then
                SaveManager.Library:Notify("请先选择一个配置。")
                return
            end

            local Success, ErrorMessage = SaveManager:Load(ConfigName)
            if not Success then
                SaveManager.Library:Notify(string.format("加载配置 \"%s\" 失败: %s", ConfigName, ErrorMessage))
                return
            end

            SaveManager.Library:Notify(string.format("成功加载配置 \"%s\"", ConfigName))
        end
    })
    
    ConfigurationBox:AddButton({
        Text = "覆盖配置",
        DoubleClick = false,

        Func = function()
            local ConfigName = ConfigList.Value
            if IsStringEmpty(ConfigName) then
                SaveManager.Library:Notify("请先选择一个配置。")
                return
            end

            ShowDialog(
                function(): boolean
                    return true --// 总是显示
                end,

                "SaveManager_OverwriteConfig",
                "覆盖配置",
                string.format("确定要用当前设置覆盖 \"%s\" 吗？此操作不可撤销。", ConfigName),

                "覆盖",
                function()
                    local Success, ErrorMessage = SaveManager:Save(ConfigName)
                    if not Success then
                        SaveManager.Library:Notify(string.format("覆盖配置 \"%s\" 失败: %s", ConfigName, ErrorMessage))
                        return
                    end

                    SaveManager.Library:Notify(string.format("成功覆盖配置 \"%s\"", ConfigName))
                end
            )
        end
    })

    ConfigurationBox:AddButton({
        Text = "删除配置",
        DoubleClick = false,

        Func = function()
            local ConfigName = ConfigList.Value
            if IsStringEmpty(ConfigName) then
                SaveManager.Library:Notify("请先选择一个配置。")
                return
            end

            ShowDialog(
                function(): boolean
                    return true --// 总是显示
                end,

                "SaveManager_DeleteConfig",
                "删除配置",
                string.format("确定要删除 \"%s\" 吗？此操作不可撤销。", ConfigName),
                
                "删除",
                function()
                    local Success, ErrorMessage = SaveManager:Delete(ConfigName)
                    if not Success then
                        SaveManager.Library:Notify(string.format("删除配置 \"%s\" 失败: %s", ConfigName, ErrorMessage))
                        return
                    end

                    SaveManager.Library:Notify(string.format("成功删除配置 \"%s\"", ConfigName))
                    RefreshAutoloadConfigLabel()
                end
            )
        end
    })

    ConfigurationBox:AddButton("刷新列表", RefreshList)

    --// 自动加载配置
    ConfigurationBox:AddButton({
        Text = "设为自动加载",
        DoubleClick = false,

        Func = function()
            local ConfigName = ConfigList.Value
            if IsStringEmpty(ConfigName) then
                SaveManager.Library:Notify("请先选择一个配置。")
                return
            end

            local Success, ErrorMessage = SaveManager:SaveAutoloadConfig(ConfigName)
            if not Success then
                SaveManager.Library:Notify(string.format("设置自动加载配置 \"%s\" 失败: %s", ConfigName, ErrorMessage))
                return
            end

            SaveManager.Library:Notify(string.format("成功将自动加载配置设为 \"%s\"", ConfigName))
            RefreshAutoloadConfigLabel()
        end
    })

    ConfigurationBox:AddButton({
        Text = "重置自动加载",
        DoubleClick = false,

        Func = function()
            ShowDialog(
                function(): boolean
                    return true --// 总是显示
                end,

                "SaveManager_ResetAutoload",
                "重置自动加载配置",
                "确定要清除自动加载配置吗？下次启动时将不会自动加载任何配置。",
                
                "重置",
                function()
                    local Success, ErrorMessage = SaveManager:DeleteAutoLoadConfig()
                    if not Success then
                        SaveManager.Library:Notify(string.format("重置自动加载配置失败: %s", ErrorMessage))
                        return
                    end

                    SaveManager.Library:Notify("成功重置自动加载配置。")
                    RefreshAutoloadConfigLabel()
                end
            )
        end
    })

    AutoloadConfigLabel = ConfigurationBox:AddLabel("当前自动加载配置: ...", true);

    --// 设置变量
    ConfigNameInput, ConfigList = 
        SaveManager.Library.Options.SaveManager_ConfigName, 
        SaveManager.Library.Options.SaveManager_ConfigList;

    --// 刷新
    RefreshAutoloadConfigLabel()
    SaveManager:SetIgnoreIndexes({ "SaveManager_ConfigList", "SaveManager_ConfigName" })

    return ConfigurationBox
end

SaveManager:BuildFolderTree()
return SaveManager
```