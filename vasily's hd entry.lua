-- // module to handle the server-side of a game's lobby, wooohoo!

type ConnectionMap = { [string]: RBXScriptConnection }                      -- table mapping string keys to connections
type ServerConnectionMap = { [Configuration]: ConnectionMap }               -- table mapping server configs to their connections

type ServerSystem = {                                                       -- main server system class shape
    _assets: Folder,                                                        -- reference to main assets folder
    _configsFolder: Folder,                                                 -- reference to servers configuration folder
    _globalRemote: RemoteEvent,                                             -- reference to global remote event
    _mainController: any,                                                   -- reference to your main controller module
    _connections: ConnectionMap,                                            -- global connection map
    _serverConnections: ServerConnectionMap,                                -- per-server connection map
    _serverByOwnerId: { [number]: Configuration },                          -- map owner user id to config
    _testEnvironment: boolean,                                              -- flag for test environment mode
    _started: boolean,                                                      -- flag telling if start was called
}

-- // services

local players: Players = game:GetService("Players")                         -- grab players service for player handling
local replicatedStorage: ReplicatedStorage = game:GetService("ReplicatedStorage") -- grab replicatedstorage for shared content
local teleportService: TeleportService = game:GetService("TeleportService") -- get teleport service for private servers

-- // assets and modules

local gameAssets: Folder = replicatedStorage:WaitForChild("Assets")         -- wait for main assets folder
local serverConfigurations: Folder = gameAssets:WaitForChild("Configurations") -- wait for configurations folder
local serversConfigFolder: Folder = serverConfigurations:WaitForChild("ServersConfig") -- folder that holds all server configs
local globalRemote: RemoteEvent = gameAssets.Remotes:WaitForChild("GlobalRemote") -- global remote event shared with clients
local mainController: ModuleScript = require(gameAssets.Modules.Main_Controller) -- require your existing main controller module

-- // class table

local ServerSystemClass = {}                                                -- create table that will act as the class
ServerSystemClass.__index = ServerSystemClass                               -- set metatable index for method lookups

-- // function manager

function ServerSystemClass.new(): ServerSystem                              -- public constructor for new server system instance
    local self: ServerSystem = setmetatable({}, ServerSystemClass)          -- create new table and apply class metatable

    self._assets = gameAssets                                               -- store reference to assets folder
    self._configsFolder = serversConfigFolder                               -- store reference to servers config folder
    self._globalRemote = globalRemote                                      -- store reference to global remote
    self._mainController = mainController                                   -- store reference to main controller
    self._connections = {}                                                  -- initialize global connection map
    self._serverConnections = {}                                            -- initialize per-server connection map
    self._serverByOwnerId = {}                                              -- initialize map from owner id to config
    self._testEnvironment = _G.TestEnvironment == true                      -- read global test environment flag in a safe way
    self._started = false                                                   -- mark the instance as not started yet

    return self                                                             -- return the new server system instance
end

-- // function to track connections under keys

function ServerSystemClass:_trackConnection(key: string, conn: RBXScriptConnection?)
    local existing: RBXScriptConnection? = self._connections[key]           -- get existing connection if any
    if existing then                                                        -- check if there is already a connection stored
        existing:Disconnect()                                               -- disconnect the old one to avoid leaks
        self._connections[key] = nil                                        -- clear it from the table
    end                                                                     -- end if existing connection
    if conn then                                                            -- check if a new connection is passed
        self._connections[key] = conn                                       -- store new connection under provided key
    end                                                                     -- end if new connection
end

-- // internal helper: track connection for a specific server config

function ServerSystemClass:_trackServerConnection(config: Configuration, key: string, conn: RBXScriptConnection?) -- track per-server connection
    if not self._serverConnections[config] then                             -- if we do not have a connection map for this server yet
        self._serverConnections[config] = {}                                -- create a new connection map for this server
    end                                                                     -- end if no server connection map
    local serverMap: ConnectionMap = self._serverConnections[config]        -- get the connection map for this server
    local existing: RBXScriptConnection? = serverMap[key]                   -- check if connection with this key exists
    if existing then                                                        -- if there is an existing connection
        existing:Disconnect()                                               -- disconnect old connection
        serverMap[key] = nil                                                -- clear entry from server map
    end                                                                     -- end if existing
    if conn then                                                            -- if a new connection is provided
        serverMap[key] = conn                                               -- store the new connection in the server map
    end                                                                     -- end if conn
end

-- // function to cleaning connections globally

function ServerSystemClass:_cleanupConnections()                            -- private helper to disconnect all global connections
    for key: string, conn: RBXScriptConnection in pairs(self._connections) do -- iterate all stored connections
        conn:Disconnect()                                                   -- disconnect each connection safely
        self._connections[key] = nil                                        -- clear the entry from the map
    end                                                                     -- end connection loop
end

-- // function to clear connections for a specific server

function ServerSystemClass:_cleanupServerConnections(config: Configuration) -- private helper to clean connections for one server config
    local map: ConnectionMap? = self._serverConnections[config]             -- get connection map for this config
    if not map then                                                         -- if no map exists for this server
        return                                                              -- nothing to clean so early return
    end                                                                     -- end if not map
    for key: string, conn: RBXScriptConnection in pairs(map) do             -- iterate per-server connections
        conn:Disconnect()                                                   -- disconnect each connection
        map[key] = nil                                                      -- clear entry from map
    end                                                                     -- end loop
    self._serverConnections[config] = nil                                   -- remove entire map entry for this server config
end

-- // function to get a player's main menu ui

function ServerSystemClass:_getMainMenuUi(plr: Player): ScreenGui?          -- private helper to get the main menu ui safely
    if not plr or not plr:IsDescendantOf(game) then                         -- check if player is valid and still in game
        return nil                                                          -- return nil if player is invalid
    end                                                                     -- end player validity check

    local playerGui: PlayerGui? = plr:FindFirstChildOfClass("PlayerGui")    -- attempt to get playergui from player
    if not playerGui then                                                   -- if player does not yet have a playergui
        return nil                                                          -- return nil and let caller handle missing ui
    end                                                                     -- end if playerGui missing

    local mainMenuUi: ScreenGui? = playerGui:FindFirstChild("MainMenuUI")   -- try to find main menu ui inside playergui
    return mainMenuUi                                                       -- return the main menu ui (can be nil)
end

-- // function to set up the join hud for the added player

function ServerSystemClass:_setupJoinHud(player: Player)                    -- private helper to set up the join ui for a player
    if self._testEnvironment then                                           -- if running in test environment
        return                                                              -- do not set up join ui to keep tests clean
    end                                                                     -- end test environment check

    local uiFolder: Folder = self._assets:WaitForChild("UI")                -- get ui folder from assets
    local joinTemplate: ScreenGui = uiFolder:WaitForChild("JoinUI")         -- get join ui template screen gui
    local clonedJoin: ScreenGui = joinTemplate:Clone()                      -- clone join ui template
    local playerGui: PlayerGui = player:WaitForChild("PlayerGui")           -- wait until playergui exists for the player
    clonedJoin.Parent = playerGui                                           -- parent cloned join ui to playergui

    player:SetAttribute("Jason_Selected", "New_Blood")                      -- set default jason selected attribute
    player:SetAttribute("Counselor_Selected", "Vanessa Jones")              -- set default counselor selected attribute
end

-- // ifunction to spawn the mian menu

function ServerSystemClass:_spawnMainMenu(player: Player)                   -- private helper to spawn main menu ui for a player
    local uiFolder: Folder = self._assets:WaitForChild("UI")                -- get ui folder from assets
    local mainMenuTemplate: ScreenGui = uiFolder:WaitForChild("MainMenuUI") -- get main menu template
    local clonedMainMenu: ScreenGui = mainMenuTemplate:Clone()              -- clone main menu template
    local playerGui: PlayerGui = player:WaitForChild("PlayerGui")           -- ensure playergui exists
    clonedMainMenu.Parent = playerGui                                       -- parent cloned main menu to playergui

    local holder: Frame = clonedMainMenu:WaitForChild("Holder")             -- get root holder frame
    local menuLogo: ImageLabel = holder:WaitForChild("GameLogo")            -- get game logo image
    local mainOptions: Frame = holder:WaitForChild("MainOptions")           -- get main options frame
    local continueText: TextLabel = mainOptions:WaitForChild("ContinueText") -- get continue text label

    local tweenService = self._mainController.Services.TWS                  -- get tween service reference from main controller

    tweenService:Create(menuLogo, TweenInfo.new(1.55), {                    -- create tween for logo fade in
        ImageTransparency = 0                                               -- set target transparency to fully visible
    }):Play()                                                               -- play tween immediately

    tweenService:Create(continueText, TweenInfo.new(1.55), {                -- create tween for continue text fade in
        TextTransparency = 0                                                -- set target transparency to fully visible
    }):Play()                                                               -- play tween immediately

    for _, serverConfig: Instance in ipairs(self._configsFolder:GetChildren()) do -- iterate existing server configs to sync ui
        if serverConfig:IsA("Configuration") then                           -- ensure instance is a configuration
            local ownerName: string? = serverConfig:GetAttribute("OwnerName") -- read owner name attribute
            if ownerName then                                               -- check if attribute exists
                local ownerPlayer: Player? = self._mainController.Services.Players:FindFirstChild(ownerName) -- get owner player instance
                if ownerPlayer then                                         -- if owner player is still in game
                    self:_createServerUiForPlayer(player, ownerPlayer, serverConfig) -- create server ui entry for this player
                end                                                         -- end if ownerPlayer
            end                                                             -- end if ownerName
        end                                                                 -- end if configuration
    end                                                                     -- end loop through server configs
end

-- // function to get the paths for all servers from the main menu

function ServerSystemClass:_getServersListFrame(mainMenuUi: ScreenGui): Frame? -- private helper to get the servers list frame
    local holder: Frame? = mainMenuUi:FindFirstChild("Holder")              -- find holder frame
    if not holder then                                                      -- if holder missing
        return nil                                                          -- return nil because layout is broken
    end                                                                     -- end if not holder

    local mainOptions: Frame? = holder:FindFirstChild("MainOptions")        -- find main options frame
    if not mainOptions then                                                 -- if main options missing
        return nil                                                          -- return nil for safety
    end                                                                     -- end if

    local menuOptions: Frame? = mainOptions:FindFirstChild("MenuOptions")   -- find menu options frame
    if not menuOptions then                                                 -- if menu options missing
        return nil                                                          -- return nil
    end                                                                     -- end if

    local frames: Frame? = menuOptions:FindFirstChild("Frames")             -- find frames container
    if not frames then                                                      -- if frames missing
        return nil                                                          -- return nil
    end                                                                     -- end if

    local gameplayFrames: Frame? = frames:FindFirstChild("GameplayFrames")  -- find gameplay frames container
    if not gameplayFrames then                                              -- if gameplay frames missing
        return nil                                                          -- return nil
    end                                                                     -- end if

    local joinPublicMatch: Frame? = gameplayFrames:FindFirstChild("JoinPublicMatch") -- find join public match frame
    if not joinPublicMatch then                                             -- if join public match missing
        return nil                                                          -- return nil
    end                                                                     -- end if

    local pmHolder: Frame? = joinPublicMatch:FindFirstChild("PM_Holder")    -- find holder frame inside public match
    if not pmHolder then                                                    -- if holder missing
        return nil                                                          -- return nil
    end                                                                     -- end if

    local serversListFrame: Frame? = pmHolder:FindFirstChild("ServersListFrame") -- get final servers list frame
    return serversListFrame                                                 -- return servers list frame (may be nil)
end

-- // function to create ui for a specific player

function ServerSystemClass:_createServerUiForPlayer(plr: Player, owner: Player, config: Configuration) -- private helper for server ui
    local mainMenuUi: ScreenGui? = self:_getMainMenuUi(plr)                 -- get main menu ui for this player
    if not mainMenuUi then                                                  -- if no main menu ui found
        return                                                              -- do nothing since ui is not ready
    end                                                                     -- end if mainMenuUi

    local serversListFrame: Frame? = self:_getServersListFrame(mainMenuUi)  -- get servers list frame inside ui
    if not serversListFrame then                                            -- if list frame is missing
        return                                                              -- exit silently to avoid runtime errors
    end                                                                     -- end if serversListFrame

    local serversFolder: Folder? = serversListFrame:FindFirstChild("Servers") -- get folder that holds server templates
    if not serversFolder then                                               -- if servers folder missing
        return                                                              -- exit early
    end                                                                     -- end if serversFolder

    local template: Frame? = serversFolder:FindFirstChild("TemplateServer") -- find template server frame
    if not template then                                                    -- if no template available
        return                                                              -- exit early because we cannot build ui row
    end                                                                     -- end if template

    local clonedTemplate: Frame = template:Clone()                          -- clone template frame to use as a server row
    clonedTemplate.Parent = serversListFrame                                -- parent it to servers list frame so it is visible
    clonedTemplate.Visible = true                                           -- make sure cloned frame is visible
    clonedTemplate.Name = tostring(owner.UserId)                            -- name the frame by owner user id for fast lookup

    local lobbyDesc: TextLabel? = clonedTemplate:FindFirstChild("LobbyDesc") -- get lobby description text label
    if lobbyDesc then                                                       -- if label exists
        lobbyDesc.Text = "Owner: " .. owner.Name .. "       Queue: 1/8 Players" -- set initial description text
    end                                                                     -- end if lobbyDesc

    local joinButton: TextButton? = clonedTemplate:FindFirstChild("JoinLobby") -- get join lobby button
    if joinButton then                                                      -- if button exists
        joinButton.MouseButton1Click:Connect(function()                     -- connect click event handler
            self:_onPlayerJoinedServerButton(plr, owner, config)            -- call method to process joining server
        end)                                                                -- end connection
    end                                                                     -- end if joinButton
end

-- // function to update the server size for all players

function ServerSystemClass:_updatePlayerCount(owner: Player, amount: number) -- private helper to refresh queue count ui
    for _, plr: Player in ipairs(self._mainController.Services.Players:GetPlayers()) do -- iterate all players
        if plr ~= owner and plr:IsDescendantOf(game) then                   -- skip owner and ensure player is still in game
            local mainMenuUi: ScreenGui? = self:_getMainMenuUi(plr)         -- get main menu ui for this player
            if mainMenuUi then                                              -- if ui exists
                local serversListFrame: Frame? = self:_getServersListFrame(mainMenuUi) -- get servers list frame
                if serversListFrame then                                    -- if servers list exists
                    local serverFrame: Frame? = serversListFrame:FindFirstChild(tostring(owner.UserId)) -- find frame by owner id
                    if serverFrame then                                     -- if frame exists
                        local lobbyDesc: TextLabel? = serverFrame:FindFirstChild("LobbyDesc") -- get lobby description label
                        if lobbyDesc then                                   -- if label exists
                            lobbyDesc.Text = "Owner: " .. owner.Name .. "       Queue: " .. tostring(amount) .. "/8  Players" -- update text
                        end                                                 -- end if lobbyDesc
                    end                                                     -- end if serverFrame
                end                                                         -- end if serversListFrame
            end                                                             -- end if mainMenuUi
        end                                                                 -- end if plr ~= owner
    end                                                                     -- end players loop
end

-- // function to handle when someone joins the lobby/server

function ServerSystemClass:_onPlayerJoinedServerButton(plr: Player, owner: Player, config: Configuration) -- when a player clicks join
    if not config or not config.Parent then                                 -- ensure config still exists
        return                                                              -- return early if server is gone
    end                                                                     -- end if config invalid

    local newModel: Model = Instance.new("Model")                           -- create model to represent joined player inside config
    newModel.Name = plr.Name                                                -- name model with player's name for lookup
    newModel.Parent = config                                                -- parent model inside configuration

    self._globalRemote:FireClient(plr, "RefreshList", true, config, "Player") -- tell client to refresh its list as a player

    local mainMenuUi: ScreenGui? = self:_getMainMenuUi(plr)                 -- get main menu ui for this player
    if mainMenuUi then                                                      -- if main menu exists
        local holder: Frame? = mainMenuUi:FindFirstChild("Holder")          -- get holder frame
        if holder then                                                      -- if holder exists
            local mainOptions: Frame? = holder:FindFirstChild("MainOptions") -- get main options frame
            if mainOptions then                                             -- if main options exists
                local menuOptions: Frame? = mainOptions:FindFirstChild("MenuOptions") -- get menu options frame
                if menuOptions then                                         -- if menu options exists
                    local buttons: Frame? = menuOptions:FindFirstChild("Buttons") -- get buttons frame
                    if buttons then                                         -- if buttons frame exists
                        self._mainController.FadeManager.Fade("GameplayButtons", buttons, true) -- fade out gameplay buttons for nice transition
                    end                                                     -- end if buttons
                end                                                         -- end if menuOptions
            end                                                             -- end if mainOptions
        end                                                                 -- end if holder
    end                                                                     -- end if mainMenuUi
end

-- // function to destroy the server config and the ui

function ServerSystemClass:_destroyServerConfig(config: Configuration)      -- private helper to fully destroy a server config
    if not config or not config.Parent then                                 -- ensure config is valid and still in data model
        return                                                              -- nothing to destroy if already gone
    end                                                                     -- end if config invalid

    local collectedPlayers: { [string]: number } = {}                       -- create table to store user ids keyed by player name
    local ownerUserId: number? = config:GetAttribute("Owner")               -- get numeric owner user id attribute
    local ownerNameAttribute: string? = config:GetAttribute("OwnerName")    -- get owner name attribute for fallback ui
    if ownerUserId then                                                     -- if owner id attribute exists
        collectedPlayers["Owner"] = ownerUserId                             -- store owner id with special key
    end                                                                     -- end if ownerUserId

    for _, child: Instance in ipairs(config:GetChildren()) do               -- iterate all instances inside server config
        local playerInstance: Player? = self._mainController.Services.Players:FindFirstChild(child.Name) -- try to get player by name
        if playerInstance and playerInstance:IsDescendantOf(game) then      -- ensure player is valid and in game
            self._globalRemote:FireClient(playerInstance, "ResetServer", true) -- ask client to reset its server ui / state
            collectedPlayers[playerInstance.Name] = playerInstance.UserId   -- store player user id keyed by their name
        end                                                                 -- end if playerInstance
    end                                                                     -- end loop through children

    local resolvedOwnerId: number? = nil                                    -- variable to hold final owner id
    for _, userId: number in pairs(collectedPlayers) do                     -- iterate all collected user ids
        if userId == ownerUserId then                                       -- compare with owner attribute id
            resolvedOwnerId = userId                                        -- set resolved owner id
            break                                                           -- break out of loop since we found match
        end                                                                 -- end if userId check
    end                                                                     -- end pairs loop

    self._serverByOwnerId[ownerUserId or -1] = nil                          -- remove config from owner id map if present
    self:_cleanupServerConnections(config)                                  -- clean up per-server connections for this config
    config:Destroy()                                                        -- destroy configuration instance from data model

    task.wait()                                                             -- yield one frame to let ui and replication settle

    for _, properPlayer: Player in ipairs(self._mainController.Services.Players:GetPlayers()) do -- iterate all real players
        if properPlayer and properPlayer:IsDescendantOf(game) then          -- ensure player is valid and in game
            local mainMenuUi: ScreenGui? = self:_getMainMenuUi(properPlayer) -- get main menu ui for this player
            if mainMenuUi then                                              -- if main menu exists
                local serversListFrame: Frame? = self:_getServersListFrame(mainMenuUi) -- get servers list frame
                if serversListFrame then                                    -- if list frame exists
                    local key: string                                       -- variable for frame name to remove
                    if resolvedOwnerId then                                 -- if we know numeric owner id for frame lookup
                        key = tostring(resolvedOwnerId)                     -- use user id as string
                    else                                                    -- otherwise fallback
                        key = ownerNameAttribute or "Owner"                 -- use owner name attribute or generic text
                    end                                                     -- end if resolvedOwnerId
                    local serverFrame: Frame? = serversListFrame:FindFirstChild(key) -- get server frame by name
                    if serverFrame then                                     -- if server frame exists
                        serverFrame:Destroy()                               -- destroy ui frame from this player's view
                    end                                                     -- end if serverFrame
                end                                                         -- end if serversListFrame
            end                                                             -- end if mainMenuUi
        end                                                                 -- end if properPlayer
    end                                                                     -- end players loop
end

-- // function to create a server

function ServerSystemClass:_createServerForOwner(owner: Player, fromClientFlag: boolean) -- private helper to create server config
    local config: Configuration = Instance.new("Configuration")             -- create new configuration instance
    config.Name = owner.Name .. "_Server"                                   -- name config using owner name for clarity
    config.Parent = self._configsFolder                                     -- parent config into servers config folder

    config:SetAttribute("Owner", owner.UserId)                              -- set numeric owner id attribute
    config:SetAttribute("OwnerName", owner.Name)                            -- set owner name attribute

    local ownerModel: Model = Instance.new("Model")                         -- create model representing owner inside server
    ownerModel.Name = owner.Name                                            -- set model name to owner name
    ownerModel.Parent = config                                              -- parent model to configuration

    self._serverByOwnerId[owner.UserId] = config                            -- map owner user id to this configuration

    self._globalRemote:FireClient(owner, "RefreshList", fromClientFlag, config, "Owner") -- notify owner client to refresh list as owner

    local mainMenuUi: ScreenGui? = self:_getMainMenuUi(owner)               -- get main menu ui for owner
    local createMatchFrame: Frame? = nil                                    -- predeclare frame for create match

    if mainMenuUi then                                                      -- if owner has main menu ui
        local holder: Frame? = mainMenuUi:FindFirstChild("Holder")          -- get holder frame
        if holder then                                                      -- if holder exists
            local mainOptions: Frame? = holder:FindFirstChild("MainOptions") -- get main options frame
            if mainOptions then                                             -- if main options exists
                local menuOptions: Frame? = mainOptions:FindFirstChild("MenuOptions") -- get menu options frame
                if menuOptions then                                         -- if menu options exists
                    local frames: Frame? = menuOptions:FindFirstChild("Frames") -- get frames container
                    if frames then                                          -- if frames container exists
                        local gameplayFrames: Frame? = frames:FindFirstChild("GameplayFrames") -- get gameplay frames
                        if gameplayFrames then                              -- if gameplay frames exists
                            createMatchFrame = gameplayFrames:FindFirstChild("CreateMatch") -- get create match frame
                        end                                                 -- end if gameplayFrames
                    end                                                     -- end if frames
                end                                                         -- end if menuOptions
            end                                                             -- end if mainOptions
        end                                                                 -- end if holder
    end                                                                     -- end if mainMenuUi

    if createMatchFrame then                                                -- if we managed to get create match frame
        local lobbyStarter: Frame? = createMatchFrame:FindFirstChild("Lobby_Starter") -- get lobby starter frame
        if lobbyStarter then                                                -- if lobby starter exists
            local startButton: TextButton? = lobbyStarter:FindFirstChild("Start_Button") -- get start button
            if startButton then                                             -- if start button exists
                self:_bindOwnerStartButton(owner, config, startButton)      -- bind logic to owner start button
            end                                                             -- end if startButton
        end                                                                 -- end if lobbyStarter
    end                                                                     -- end if createMatchFrame

    self:_bindServerMembershipListeners(owner, config)                      -- bind listeners for players joining and leaving server

    self:_trackConnection("OwnerLeft_" .. owner.Name,                       -- track connection watching for owner leaving game
        self._mainController.Services.Players.PlayerRemoving:Connect(function(playerLeft: Player) -- callback for player removing
            if playerLeft == owner then                                     -- if the player who left is the owner
                self:_destroyServerConfig(config)                           -- destroy the server config since owner left
            end                                                             -- end if playerLeft == owner
        end)                                                                -- end connect
    )                                                                       -- end trackConnection

    for _, plr: Player in ipairs(self._mainController.Services.Players:GetPlayers()) do -- loop through all players
        if plr ~= owner and plr:IsDescendantOf(game) then                   -- exclude owner and ensure player is in game
            self:_createServerUiForPlayer(plr, owner, config)               -- create server ui row for this player
        end                                                                 -- end if plr ~= owner
    end                                                                     -- end loop players

    return config                                                           -- return newly created server configuration
end

-- // function to handle servers (refreshing servers as an example if a player leaves)

function ServerSystemClass:_bindServerMembershipListeners(owner: Player, config: Configuration) -- private helper to manage membership
    local function refreshServer(model: Model, joined: boolean)             -- inner helper to refresh server state
        local children: { Instance } = config:GetChildren()                 -- get children representing players in server
        local count: number = #children                                     -- get number of players in server
        self:_updatePlayerCount(owner, count)                               -- update ui for all players about queue size

        for _, child: Instance in ipairs(children) do                       -- loop through each child in config
            local plr: Player? = self._mainController.Services.Players:FindFirstChild(child.Name) -- get player by name
            if plr then                                                     -- if player exists
                self._globalRemote:FireClient(plr, "RefreshList", false, config, model.Name) -- ask client to refresh list with new model state
            end                                                             -- end if plr
        end                                                                 -- end loop children
    end                                                                     -- end local function refreshServer

    self:_trackServerConnection(config, "ChildAdded",                       -- track server-specific child added event
        config.ChildAdded:Connect(function(child: Instance)                 -- connection callback when child added
            local model: Model? = child:IsA("Model") and child or nil       -- ensure child is a model instance
            if model then                                                   -- if child is a model
                refreshServer(model, true)                                  -- refresh server as join
            end                                                             -- end if model
        end)                                                                -- end connect
    )                                                                       -- end trackServerConnection

    self:_trackServerConnection(config, "ChildRemoved",                     -- track server-specific child removed event
        config.ChildRemoved:Connect(function(child: Instance)               -- connection callback when child removed
            local model: Model? = child:IsA("Model") and child or nil       -- ensure child is a model
            if model then                                                   -- if it is a model
                refreshServer(model, false)                                 -- refresh server as leave
            end                                                             -- end if model
        end)                                                                -- end connect
    )                                                                       -- end trackServerConnection
end

-- // function to start a match

function ServerSystemClass:_bindOwnerStartButton(owner: Player, config: Configuration, button: TextButton) -- bind start game logic
    local canStart: boolean = true                                          -- flag to prevent spamming match start

    self:_trackConnection(owner.Name .. "_StartMatch",                      -- track connection for this owner's start button
        button.MouseButton1Click:Connect(function()                         -- connect function when start button is clicked
            if not canStart then                                            -- if already starting
                return                                                      -- do nothing to avoid double trigger
            end                                                             -- end if not canStart

            canStart = false                                                -- lock further start attempts

            local playersTable: { Player } = {}                             -- table to hold players to teleport

            for _, serverPlayerInstance: Instance in ipairs(config:GetChildren()) do -- iterate players in config
                local properPlayer: Player? = self._mainController.Services.Players:FindFirstChild(serverPlayerInstance.Name) -- get real player
                if properPlayer then                                        -- if real player exists
                    table.insert(playersTable, properPlayer)                -- add player into table for teleport
                end                                                         -- end if properPlayer
            end                                                             -- end loop over config children

            local placeId: number = 85691538991198                          -- place id used for teleport (from your original code)
            local privateCode: string = teleportService:ReserveServer(placeId) -- reserve private server and get teleport code

            teleportService:TeleportToPrivateServer(placeId, privateCode, playersTable) -- teleport all players to private server

            local connectionKey: string = owner.Name .. "_StartMatch"       -- build key for connection map
            local conn: RBXScriptConnection? = self._connections[connectionKey] -- get stored connection
            if conn then                                                    -- if connection exists
                conn:Disconnect()                                           -- disconnect start button event
                self._connections[connectionKey] = nil                      -- clear from map
            end                                                             -- end if conn

            self:_destroyServerConfig(config)                               -- destroy the server configuration after starting match
        end)                                                                -- end clicked connect
    )                                                                       -- end trackConnection
end

-- // funciton to continue from the intro

function ServerSystemClass:_handleContinueFromIntro(player: Player, auth: string) -- process continue from intro event
    if player.Name ~= auth then                                             -- ensure authenticity by checking names match
        return                                                              -- ignore if data does not match
    end                                                                     -- end auth check

    self:_spawnMainMenu(player)                                             -- create main menu ui and sync servers
end

-- // function to validate a specific server

function ServerSystemClass:_handleServerValidation(player: Player, opm: any) -- handle server validation request
    if not opm then                                                         -- opm in your original code decides whether to create server
        return                                                              -- do nothing if flag is falsy
    end                                                                     -- end if not opm

    local existing: Configuration? = self._serverByOwnerId[player.UserId]   -- check if player already owns a server
    if existing and existing.Parent then                                    -- if server already exists and is active
        return                                                              -- skip creating a new one
    end                                                                     -- end if existing

    self:_createServerForOwner(player, false)                               -- create server config for this owner
end

-- // function to remove a server from the servers config

function ServerSystemClass:_handleRemoveServer(player: Player, opm: any)    -- handle request to remove a server
    local config: Configuration? = opm                                      -- treat opm as configuration instance (following original code)
    if config and config:IsA("Configuration") then                          -- ensure it is really a configuration
        local ownerId: number? = config:GetAttribute("Owner")               -- get owner id attribute
        if ownerId and ownerId == player.UserId then                        -- only allow owner to remove their own server
            self:_destroyServerConfig(config)                               -- destroy the server
        end                                                                 -- end check owner same
    end                                                                     -- end if config valid
end

-- // function to handle the removal of a player from the server

function ServerSystemClass:_handleRemovePlayer(player: Player, opm: any)    -- handle client request to remove player from server config
    local config: Configuration? = opm                                      -- treat opm as configuration instance
    if not config or not config:IsA("Configuration") then                   -- ensure config is valid and of correct type
        return                                                              -- early return if not
    end                                                                     -- end if not config

    local model: Model? = config:FindFirstChild(player.Name)                -- find model representing this player in config
    if model and model:IsA("Model") then                                    -- make sure instance is a model
        model:Destroy()                                                     -- destroy player model from server
        print("destroyed player: " .. player.DisplayName .. " from " .. tostring(config:GetAttribute("OwnerName")) .. "'s server!") -- log removal
    end                                                                     -- end if model
end

-- // function to handle the change of counselor/s 

function ServerSystemClass:_handleChangeCounselor(player: Player, counselorId: string) -- handle request to change counselor
    player:SetAttribute("Counselor_Selected", counselorId)                  -- update attribute for selected counselor
end

-- // remote event dispatcher

function ServerSystemClass:_onRemote(player: Player, action: string, opm: any, playerAuthenticator: string?, opm2: any?) -- main remote dispatcher
    if action == "ContinueFromIntro" then                                   -- check if action is continue from intro
        self:_handleContinueFromIntro(player, playerAuthenticator or "")    -- delegate to intro handler
        return                                                              -- early return because action handled
    end                                                                     -- end if continue from intro

    if action == "ServerValidation" then                                    -- check if client requested server validation
        self:_handleServerValidation(player, opm)                           -- delegate to server validation handler
        return                                                              -- exit after handling
    end                                                                     -- end if server validation

    if action == "Remove_Server" then                                       -- check if client wants to remove a server
        self:_handleRemoveServer(player, opm)                               -- delegate to remove server handler
        return                                                              -- exit after handling
    end                                                                     -- end if remove server

    if action == "Remove_Player" then                                       -- check if client wants to remove player from server
        self:_handleRemovePlayer(player, opm)                               -- delegate to remove player handler
        return                                                              -- exit after handling
    end                                                                     -- end if remove player

    if action == "ChangeCurrent_Counselor" then                             -- check if counselor change is requested
        if typeof(opm) == "string" then                                     -- ensure counselor id is string
            self:_handleChangeCounselor(player, opm)                        -- delegate to handler
        end                                                                 -- end if opm string
        return                                                              -- exit after handling
    end                                                                     -- end if change counselor
end

-- // player added handler

function ServerSystemClass:_onPlayerAdded(player: Player)                   -- private handler called when a new player joins
    self:_setupJoinHud(player)                                              -- set up join ui and attributes for the player
end

-- // public start: binds all listeners and starts system

function ServerSystemClass:Start()                                          -- public method to start server system
    if self._started then                                                   -- check if already started
        return                                                              -- do nothing if start was already called
    end                                                                     -- end if already started

    self._started = true                                                    -- mark system as started

    for _, player: Player in ipairs(players:GetPlayers()) do                -- loop through players already in server
        self:_onPlayerAdded(player)                                         -- manually set up join ui for existing players
    end                                                                     -- end loop over existing players

    self:_trackConnection("PlayerAdded",                                   -- track connection for player added event
        players.PlayerAdded:Connect(function(player: Player)                -- callback when player joins game
            self:_onPlayerAdded(player)                                     -- forward event to instance method
        end)                                                                -- end connect
    )                                                                       -- end trackConnection

    self:_trackConnection("RemoteFiring",                                  -- track connection for global remote
        self._globalRemote.OnServerEvent:Connect(function(player: Player, action: string, opm: any, playerAuthenticator: string?, opm2: any?) -- remote callback
            self:_onRemote(player, action, opm, playerAuthenticator, opm2)  -- delegate to remote dispatcher method
        end)                                                                -- end connect
    )                                                                       -- end trackConnection
end

-- // function to clean everything

function ServerSystemClass:Stop()                                           -- public method to stop server system and clean everything
    self:_cleanupConnections()                                              -- disconnect all global connections

    for config: Configuration, _ in pairs(self._serverConnections) do       -- iterate all alive server configs in map
        self:_cleanupServerConnections(config)                              -- clean per-server connections
    end                                                                     -- end loop configs

    self._started = false                                                   -- mark system as stopped
end

return ServerSystemClass                                                    -- return the class so it can be required and instantiated