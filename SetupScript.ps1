#Requires -Version 5.1
<#
.SYNOPSIS
    Automated SQL Server installation and configuration script with YAML configuration.

.DESCRIPTION
    This script provides a comprehensive solution for installing and configuring SQL Server instances
    with optional components like SSMS, Ola Hallengren's Maintenance Solution, and other tools.
    Configuration is loaded from a YAML file for easy customization.

.PARAMETER ConfigFile
    Path to the YAML configuration file. Defaults to 'sql-server-config.yaml' in the script directory.

.EXAMPLE
    .\SetupScript-YAML.ps1
    .\SetupScript-YAML.ps1 -ConfigFile "C:\MyConfig\custom-config.yaml"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile = "sql-server-config.yaml"
)

#-----------------------------
# Configuration Management
#-----------------------------
function Import-YamlConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigFile
    )
    
    # Check if config file exists
    if (-not (Test-Path $ConfigFile)) {
        throw "Configuration file not found: $ConfigFile"
    }
    
    Write-LogMessage "Loading configuration from: $ConfigFile" -Level Info
    
    try {
        # Read YAML content
        $yamlContent = Get-Content -Path $ConfigFile -Raw -Encoding UTF8
        
        # Simple YAML parser (basic implementation)
        $config = @{}
        $lines = $yamlContent -split "`n"
        $currentSection = ""
        $currentSubSection = ""
        
        foreach ($line in $lines) {
            $line = $line.Trim()
            
            # Skip empty lines and comments
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
                continue
            }
            
            # Section headers (no indentation)
            if ($line -match "^(\w+):$" -and -not $line.StartsWith("  ")) {
                $currentSection = $matches[1]
                $config[$currentSection] = @{}
                $currentSubSection = ""
                continue
            }
            
            # Sub-section headers (2 spaces indentation)
            if ($line -match "^  (\w+):$" -and $currentSection) {
                $currentSubSection = $matches[1]
                $config[$currentSection][$currentSubSection] = @{}
                continue
            }
            
            # Key-value pairs (4+ spaces indentation)
            if ($line -match "^    (\w+):\s*(.*)$" -and $currentSection -and $currentSubSection) {
                $key = $matches[1]
                $value = $matches[2].Trim()
                
                # Convert string values to appropriate types
                if ($value -eq "true") { $value = $true }
                elseif ($value -eq "false") { $value = $false }
                elseif ($value -eq "auto") { $value = "auto" }
                elseif ($value -match "^\d+$") { $value = [int]$value }
                
                $config[$currentSection][$currentSubSection][$key] = $value
            }
            # Direct key-value pairs (2 spaces indentation)
            elseif ($line -match "^  (\w+):\s*(.*)$" -and $currentSection) {
                $key = $matches[1]
                $value = $matches[2].Trim()
                
                # Convert string values to appropriate types
                if ($value -eq "true") { $value = $true }
                elseif ($value -eq "false") { $value = $false }
                elseif ($value -eq "auto") { $value = "auto" }
                elseif ($value -match "^\d+$") { $value = [int]$value }
                
                $config[$currentSection][$key] = $value
            }
        }
        
        # Convert to the expected format
        $result = @{
            FtpCredentials = @{
                Url = $config.ftp.url
                Username = $config.ftp.username
                Password = ConvertTo-SecureString $config.ftp.password -AsPlainText -Force
                IsoName = $config.ftp.iso_name
            }
            Paths = @{
                Root = $config.paths.root
                Version = $config.paths.version
                InstanceName = $config.paths.instance_name
            }
            InstallOptions = @{
                InstallSSMS = $config.install_options.install_ssms
                InstallOla = $config.install_options.install_ola
                InstallWhoIsActive = $config.install_options.install_whoisactive
                InstallFRK = $config.install_options.install_frk
            }
            SqlConfig = @{
                PercentMaxMemory = $config.sql_config.percent_max_memory
                TempDbDataFiles = if ($config.sql_config.tempdb_data_files -eq "auto") { [System.Environment]::ProcessorCount } else { $config.sql_config.tempdb_data_files }
                TempDbDataFileSizeMB = $config.sql_config.tempdb_data_file_size_mb
                TempDbLogFileSizeMB = $config.sql_config.tempdb_log_file_size_mb
            }
            OlaSchedules = @{
                UserDatabases = $config.ola_schedules.user_databases
                SystemDatabases = $config.ola_schedules.system_databases
                Cleanup = $config.ola_schedules.cleanup
            }
        }
        
        Write-LogMessage "Configuration loaded successfully" -Level Success
        return $result
    }
    catch {
        throw "Failed to parse YAML configuration: $($_.Exception.Message)"
    }
}

#-----------------------------
# Logging and Progress
#-----------------------------
function Write-LogMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        'Info' { 'White' }
        'Warning' { 'Yellow' }
        'Error' { 'Red' }
        'Success' { 'Green' }
    }
    
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Show-Progress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Activity,
        
        [Parameter(Mandatory = $false)]
        [string]$Status = "Processing...",
        
        [Parameter(Mandatory = $false)]
        [int]$PercentComplete = -1
    )
    
    if ($PercentComplete -ge 0) {
        Write-Progress -Activity $Activity -Status $Status -PercentComplete $PercentComplete
    } else {
        Write-Progress -Activity $Activity -Status $Status
    }
}

#-----------------------------
# Validation
#-----------------------------
function Test-SqlServerPrerequisites {
    [CmdletBinding()]
    param()
    
    Write-LogMessage "Validating prerequisites..." -Level Info
    
    # Check if running as administrator
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run as Administrator"
    }
    
    # Check PowerShell version
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        throw "PowerShell 5.0 or higher is required"
    }
    
    Write-LogMessage "Prerequisites validated successfully" -Level Success
}

#-----------------------------
# Core Functions (same as before)
#-----------------------------
function New-SqlFolderLayout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        
        [Parameter(Mandatory = $true)]
        [string]$Version
    )
    
    Write-LogMessage "Creating SQL Server folder structure..." -Level Info
    
    $folders = @(
        "$Root\ISOs",
        "$Root\SQL$Version",
        "$Root\SQLData",
        "$Root\SQLLogs",
        "$Root\TempDB",
        "$Root\SQLBackups",
        "$Root\SQLConfigs",
        "$Root\SQLScripts"
    )
    
    foreach ($folder in $folders) {
        try {
            if (-not (Test-Path $folder)) {
                New-Item -Path $folder -ItemType Directory -Force | Out-Null
                Write-LogMessage "Created folder: $folder" -Level Success
            } else {
                Write-LogMessage "Folder already exists: $folder" -Level Info
            }
        }
        catch {
            throw "Failed to create folder '$folder': $($_.Exception.Message)"
        }
    }
}

function Get-SqlIsoFromFtp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FtpUrl,
        
        [Parameter(Mandatory = $true)]
        [string]$Username,
        
        [Parameter(Mandatory = $true)]
        [SecureString]$Password,
        
        [Parameter(Mandatory = $true)]
        [string]$IsoDestination
    )
    
    Write-LogMessage "Downloading SQL Server ISO from FTP..." -Level Info
    Show-Progress -Activity "Downloading ISO" -Status "Connecting to FTP server"
    
    try {
        $webClient = New-Object System.Net.WebClient
        $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password))
        $webClient.Credentials = New-Object System.Net.NetworkCredential($Username, $plainPassword)
        
        # Create progress tracking
        Register-ObjectEvent -InputObject $webClient -EventName "DownloadProgressChanged" -Action {
            $percent = $Event.SourceEventArgs.ProgressPercentage
            Write-Progress -Activity "Downloading ISO" -Status "Downloading..." -PercentComplete $percent
        } | Out-Null
        
        $webClient.DownloadFile($FtpUrl, $IsoDestination)
        $webClient.Dispose()
        
        if (-not (Test-Path $IsoDestination)) {
            throw "ISO download failed - file not found at destination"
        }
        
        Write-LogMessage "ISO downloaded successfully to: $IsoDestination" -Level Success
    }
    catch {
        throw "Failed to download ISO: $($_.Exception.Message)"
    }
    finally {
        Get-EventSubscriber | Where-Object { $_.SourceObject -eq $webClient } | Unregister-Event
    }
}

function Mount-IsoImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$IsoPath
    )
    
    Write-LogMessage "Mounting ISO image..." -Level Info
    
    try {
        $mount = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
        $driveLetter = ($mount | Get-Volume).DriveLetter + ":"
        
        if (-not (Test-Path "$driveLetter\setup.exe")) {
            throw "setup.exe not found on mounted drive $driveLetter"
        }
        
        Write-LogMessage "ISO mounted successfully as drive: $driveLetter" -Level Success
        return @{ Mount = $mount; Drive = $driveLetter }
    }
    catch {
        throw "Failed to mount ISO: $($_.Exception.Message)"
    }
}

function Install-SqlInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Drive,
        
        [Parameter(Mandatory = $true)]
        [string]$Computer,
        
        [Parameter(Mandatory = $true)]
        [string]$Root,
        
        [Parameter(Mandatory = $true)]
        [string]$Version,
        
        [Parameter(Mandatory = $true)]
        [string]$InstanceName
    )
    
    Write-LogMessage "Installing SQL Server instance [$InstanceName]..." -Level Info
    Show-Progress -Activity "Installing SQL Server" -Status "Installing instance $InstanceName"
    
    try {
        Install-DbaInstance `
            -ComputerName $Computer `
            -Version $Version `
            -Path $Drive `
            -Feature Engine, Replication, Tools `
            -AuthenticationMode Windows `
            -InstanceName $InstanceName `
            -InstancePath "$Root\SQL$Version" `
            -DataPath "$Root\SQLData" `
            -LogPath "$Root\SQLLogs" `
            -TempPath "$Root\TempDB" `
            -SaveConfiguration "$Root\SQLConfigs\$Computer.ini" `
            -Restart `
            -NoPendingRenameCheck `
            -ErrorAction Stop `
            -WarningAction SilentlyContinue
        
        Write-LogMessage "SQL Server instance [$InstanceName] installed successfully" -Level Success
    }
    catch {
        throw "Failed to install SQL Server instance: $($_.Exception.Message)"
    }
}

function Install-SsmsClient {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )
    
    Write-LogMessage "Installing SQL Server Management Studio using Winget..." -Level Info
    Show-Progress -Activity "Installing SSMS" -Status "Installing SSMS via Winget"
    
    try {
        # Check if Winget is available
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            throw "Winget is not available on this system. Please install Windows Package Manager or use Windows 10/11."
        }
        
        # Install SSMS using Winget
        Write-LogMessage "Installing SSMS using Winget..." -Level Info
        winget install Microsoft.SQLServerManagementStudio --accept-package-agreements --accept-source-agreements --silent | Out-Null
        
        if ($LASTEXITCODE -eq 0) {
            Write-LogMessage "SSMS installed successfully via Winget" -Level Success
        } else {
            throw "Winget installation failed with exit code: $LASTEXITCODE"
        }
    }
    catch {
        throw "Failed to install SSMS via Winget: $($_.Exception.Message)"
    }
}

function Set-SqlInstanceConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SqlInstance,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )
    
    Write-LogMessage "Configuring SQL Server instance [$SqlInstance]..." -Level Info
    Show-Progress -Activity "Configuring SQL Server" -Status "Setting memory and configuration"
    
    try {
        # Memory configuration
        $totalMemory = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1MB
        $maxMemory = [math]::Floor($totalMemory * ($Config.PercentMaxMemory / 100))
        
        Set-DbaMaxMemory -SqlInstance $SqlInstance -Max $maxMemory -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
        Set-DbaSpConfigure -SqlInstance $SqlInstance -Name 'min server memory (MB)' -Value 0 -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
        Set-DbaSpConfigure -SqlInstance $SqlInstance -Name 'optimize for ad hoc workloads' -Value 1 -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
        
        Write-LogMessage "Memory and optimization settings configured" -Level Success
        
        # Default paths - using correct dbatools syntax
        try {
            # Set data path
            Set-DbaDefaultPath -SqlInstance $SqlInstance -Type Data -Path "F:\SQLData" -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
            Write-LogMessage "Data default path set to F:\SQLData" -Level Success
            
            # Set log path
            Set-DbaDefaultPath -SqlInstance $SqlInstance -Type Log -Path "F:\SQLLogs" -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
            Write-LogMessage "Log default path set to F:\SQLLogs" -Level Success
            
            # Set backup path
            Set-DbaDefaultPath -SqlInstance $SqlInstance -Type Backup -Path "F:\SQLBackups" -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
            Write-LogMessage "Backup default path set to F:\SQLBackups" -Level Success
            
            Write-LogMessage "All default paths configured successfully" -Level Success
        }
        catch {
            Write-LogMessage "Default path configuration failed: $($_.Exception.Message)" -Level Warning
        }
        
        # TempDB configuration
        Set-DbaTempDbConfig -SqlInstance $SqlInstance `
            -DataFileCount $Config.TempDbDataFiles `
            -DataFileSize $Config.TempDbDataFileSizeMB `
            -LogFileSize $Config.TempDbLogFileSizeMB `
            -DataPath "F:\TempDB" `
            -LogPath "F:\TempDB" `
            -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
        
        Write-LogMessage "TempDB configured successfully" -Level Success
        Write-LogMessage "SQL Server instance [$SqlInstance] configuration completed" -Level Success
    }
    catch {
        throw "Failed to configure SQL Server instance: $($_.Exception.Message)"
    }
}

function Install-OlaMaintenanceSolution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SqlInstance,
        
        [Parameter(Mandatory = $true)]
        [string]$Root,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Schedules
    )
    
    Write-LogMessage "Installing Ola Hallengren Maintenance Solution..." -Level Info
    Show-Progress -Activity "Installing Ola Solution" -Status "Installing maintenance solution"
    
    try {
        Install-DbaMaintenanceSolution -SqlInstance $SqlInstance -Database master -InstallJobs -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
        Write-LogMessage "Ola Maintenance Solution installed successfully" -Level Success
        
        # Schedule jobs using configuration
        Write-LogMessage "Configuring Ola job schedules..." -Level Info
        Show-Progress -Activity "Configuring Ola Jobs" -Status "Setting up job schedules"
        
        $allSchedules = @{}
        $allSchedules += $Schedules.UserDatabases
        $allSchedules += $Schedules.SystemDatabases
        $allSchedules += $Schedules.Cleanup
        
        $jobCount = 0
        $totalJobs = $allSchedules.Count
        
        foreach ($jobName in $allSchedules.Keys) {
            $jobCount++
            $percentComplete = [math]::Round(($jobCount / $totalJobs) * 100)
            
            Show-Progress -Activity "Configuring Ola Jobs" -Status "Scheduling $jobName" -PercentComplete $percentComplete
            
            if (Get-DbaAgentJob -SqlInstance $SqlInstance -Job $jobName -ErrorAction SilentlyContinue) {
                $schedule = $allSchedules[$jobName]
                $params = @{
                    SqlInstance = $SqlInstance
                    Job = $jobName
                    Schedule = $schedule.Schedule
                    FrequencyType = $schedule.FrequencyType
                    StartTime = $schedule.StartTime
                    Force = $true
                }
                
                # Add optional parameters if they exist
                if ($schedule.FrequencyInterval) { $params.FrequencyInterval = $schedule.FrequencyInterval }
                if ($schedule.FrequencySubDayType) { $params.FrequencySubDayType = $schedule.FrequencySubDayType }
                if ($schedule.FrequencySubDayInterval) { $params.FrequencySubDayInterval = $schedule.FrequencySubDayInterval }
                
                New-DbaAgentSchedule @params | Out-Null
                Write-LogMessage "Scheduled $jobName ($($schedule.Schedule))" -Level Success
            } else {
                Write-LogMessage "Job $jobName not found, skipping schedule" -Level Warning
            }
        }
        
        Write-LogMessage "Ola job schedules configured successfully" -Level Success
    }
    catch {
        throw "Failed to install Ola Maintenance Solution: $($_.Exception.Message)"
    }
}

function Install-WhoIsActive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SqlInstance,
        
        [Parameter(Mandatory = $true)]
        [string]$Root
    )
    
    Write-LogMessage "Installing sp_WhoIsActive..." -Level Info
    Show-Progress -Activity "Installing WhoIsActive" -Status "Installing stored procedure"
    
    try {
        Install-DbaWhoIsActive -SqlInstance $SqlInstance -Database master -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
        Write-LogMessage "sp_WhoIsActive installed successfully" -Level Success
    }
    catch {
        throw "Failed to install sp_WhoIsActive: $($_.Exception.Message)"
    }
}

function Install-FirstResponderKit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SqlInstance,
        
        [Parameter(Mandatory = $true)]
        [string]$Root
    )
    
    Write-LogMessage "Installing First Responder Kit..." -Level Info
    Show-Progress -Activity "Installing FRK" -Status "Installing First Responder Kit"
    
    try {
        Install-DbaFirstResponderKit -SqlInstance $SqlInstance -Database master -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
        Write-LogMessage "First Responder Kit installed successfully" -Level Success
    }
    catch {
        throw "Failed to install First Responder Kit: $($_.Exception.Message)"
    }
}

#-----------------------------
# Main Orchestrator
#-----------------------------
function Install-SqlServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Configuration
    )
    
    $mount = $null
    $computer = $env:COMPUTERNAME
    
    try {
        Write-LogMessage "Starting SQL Server installation and configuration..." -Level Info
        
        # Validate prerequisites
        Test-SqlServerPrerequisites
        
        # Setup execution policy and install dbatools
        Write-LogMessage "Configuring PowerShell execution policy and installing dbatools..." -Level Info
        Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
        Install-Module dbatools -Scope CurrentUser -Force -AllowClobber | Out-Null
        Import-Module dbatools -WarningAction SilentlyContinue
        
        # Create folder structure
        New-SqlFolderLayout -Root $Configuration.Paths.Root -Version $Configuration.Paths.Version
        
        # Download ISO from FTP
        $isoDestination = "$($Configuration.Paths.Root)\ISOs\$($Configuration.FtpCredentials.IsoName)"
        Get-SqlIsoFromFtp -FtpUrl $Configuration.FtpCredentials.Url -Username $Configuration.FtpCredentials.Username -Password $Configuration.FtpCredentials.Password -IsoDestination $isoDestination
        
        $mountResult = Mount-IsoImage -IsoPath $isoDestination
        $mount = $mountResult.Mount
        $drive = $mountResult.Drive
        
        # Install SQL Server
        Install-SqlInstance -Drive $drive -Computer $computer -Root $Configuration.Paths.Root -Version $Configuration.Paths.Version -InstanceName $Configuration.Paths.InstanceName
        
        # Configure SQL Server
        Set-SqlInstanceConfiguration -SqlInstance $computer -Config $Configuration.SqlConfig
        
        # Install optional components
        if ($Configuration.InstallOptions.InstallSSMS) {
            Install-SsmsClient -Config @{}
        }
        
        if ($Configuration.InstallOptions.InstallOla) {
            Install-OlaMaintenanceSolution -SqlInstance $computer -Root $Configuration.Paths.Root -Schedules $Configuration.OlaSchedules
        }
        
        if ($Configuration.InstallOptions.InstallWhoIsActive) {
            Install-WhoIsActive -SqlInstance $computer -Root $Configuration.Paths.Root
        }
        
        if ($Configuration.InstallOptions.InstallFRK) {
            Install-FirstResponderKit -SqlInstance $computer -Root $Configuration.Paths.Root
        }
        
        Write-LogMessage "SQL Server installation and configuration completed successfully!" -Level Success
    }
    catch {
        Write-LogMessage "SQL Server installation failed: $($_.Exception.Message)" -Level Error
        throw
    }
    finally {
        # Cleanup
        if ($mount) {
            try {
                $isoDestination = "$($Configuration.Paths.Root)\ISOs\$($Configuration.FtpCredentials.IsoName)"
                Dismount-DiskImage -ImagePath $isoDestination -ErrorAction Stop | Out-Null
                Write-LogMessage "ISO unmounted successfully" -Level Success
            }
            catch {
                Write-LogMessage "Failed to unmount ISO: $($_.Exception.Message)" -Level Warning
            }
        }
        
        # Clear progress indicators
        Write-Progress -Activity "SQL Server Installation" -Completed
    }
}

#-----------------------------
# Script Execution
#-----------------------------
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $Configuration = Import-YamlConfiguration -ConfigFile $ConfigFile
        Install-SqlServer -Configuration $Configuration
    }
    catch {
        Write-LogMessage "Script execution failed: $($_.Exception.Message)" -Level Error
        exit 1
    }
}
