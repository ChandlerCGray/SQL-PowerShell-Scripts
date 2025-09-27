Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
Install-Module dbatools -Scope CurrentUser -Force -AllowClobber | Out-Null
Import-Module dbatools -WarningAction SilentlyContinue

#-----------------------------
# Utilities
#-----------------------------
function New-SqlFolderLayout {
    param([string]$Root, [string]$Version)

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
        if (-not (Test-Path $folder)) {
            New-Item -Path $folder -ItemType Directory -ErrorAction Stop | Out-Null
            Write-Host "Created folder: $folder"
        }
    }
}

function Get-SqlIsoFromFtp {
    param([string]$FtpUrl, [string]$User, [string]$Password, [string]$IsoDest)

    Write-Host "Downloading SQL Server ISO..."
    $webclient = New-Object System.Net.WebClient
    $webclient.Credentials = New-Object System.Net.NetworkCredential($User,$Password)
    $webclient.DownloadFile($FtpUrl, $IsoDest)
    if (-not (Test-Path $IsoDest)) { throw "ISO download failed" }
    Write-Host "Downloaded ISO to $IsoDest"
}

function Mount-IsoImage {
    param([string]$IsoPath)

    $mount = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
    $driveLetter = ($mount | Get-Volume).DriveLetter + ":"
    if (-not (Test-Path "$driveLetter\setup.exe")) {
        throw "setup.exe not found on $driveLetter"
    }
    Write-Host "Mounted ISO as drive $driveLetter"
    return @{ Mount=$mount; Drive=$driveLetter }
}

function Install-SqlInstance {
    param(
        [string]$Drive,
        [string]$Computer,
        [string]$Root,
        [string]$Version,
        [string]$InstanceName
    )

    Write-Host "Installing SQL Server instance [$InstanceName]..."
    Install-DbaInstance `
        -ComputerName $Computer `
        -Version $Version `
        -Path $Drive `
        -Feature Engine,Replication,Tools `
        -AuthenticationMode Windows `
        -InstanceName $InstanceName `
        -InstancePath "$Root\SQL$Version" `
        -DataPath "$Root\SQLData" `
        -LogPath "$Root\SQLLogs" `
        -TempPath "$Root\TempDB" `
        -SaveConfiguration "$Root\SQLConfigs\$Computer.ini" `
        -Restart `
        -NoPendingRenameCheck `
        -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
    Write-Host "SQL Server installed."
}

function Install-SsmsClient {
    param(
        [string]$Url        = "https://download.visualstudio.microsoft.com/download/pr/c2e2845d-bdff-44fc-ac00-3d488e9f5675/6f664a1b1ebfce23ed412d9a392b6fc5fcab2f623d6ad8259baa192388565231/vs_SSMS.exe",
        [string]$Installer   = "$env:TEMP\vs_SSMS.exe",
        [string]$ChannelId   = "SSMS.21.SSMS.Release",
        [string]$ChannelUri  = "https://aka.ms/ssms/21/release/channel"
    )

    Write-Host "Downloading SSMS..."
    Invoke-WebRequest -Uri $Url -OutFile $Installer -UseBasicParsing -ErrorAction Stop
    if (-not (Test-Path $Installer)) { throw "SSMS installer download failed" }

    Write-Host "Installing SSMS..."
    $args = @(
        "--productId", "Microsoft.VisualStudio.Product.SSMS",
        "--channelId", $ChannelId,
        "--channelUri", $ChannelUri,
        "--quiet"
    )
    $proc = Start-Process -FilePath $Installer -ArgumentList $args -Wait -PassThru -ErrorAction Stop
    if ($proc.ExitCode -ne 0) { throw "SSMS installer exit code $($proc.ExitCode)" }
    Write-Host "SSMS installed."
    Remove-Item $Installer -Force -ErrorAction SilentlyContinue
}

function Configure-SqlInstance {
    param (
        [string]$SqlInstance = "localhost",
        [int]$PercentMaxMemory = 75,
        [int]$TempDbDataFiles = ([System.Environment]::ProcessorCount),
        [int]$TempDbDataFileSizeMB = 512,
        [int]$TempDbLogFileSizeMB  = 512
    )

    Write-Host "Configuring SQL Server instance [$SqlInstance]..."

    $totalMem = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1MB
    $maxMem   = [math]::Floor($totalMem * ($PercentMaxMemory / 100))
    Set-DbaMaxMemory -SqlInstance $SqlInstance -Max $maxMem -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
    Set-DbaSpConfigure -SqlInstance $SqlInstance -Name 'min server memory (MB)' -Value 0 -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
    Set-DbaSpConfigure -SqlInstance $SqlInstance -Name 'optimize for ad hoc workloads' -Value 1 -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
    Write-Host "Configured memory and optimize for ad hoc workloads."

    try {
        $cmd = Get-Command Set-DbaDefaultPath -ErrorAction Stop
        if ($cmd.Parameters.ContainsKey("DataPath")) {
            Set-DbaDefaultPath -SqlInstance $SqlInstance `
                -DataPath "F:\SQLData" `
                -LogPath "F:\SQLLogs" `
                -BackupPath "F:\SQLBackups" -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
        } else {
            Set-DbaDefaultPath -SqlInstance $SqlInstance `
                -Data "F:\SQLData" `
                -Log "F:\SQLLogs" `
                -Backup "F:\SQLBackups" -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
        }
        Write-Host "Updated default paths (backup dir set to F:\SQLBackups)."
    }
    catch { Write-Host "Default path update skipped." }

    Set-DbaTempDbConfig -SqlInstance $SqlInstance `
        -DataFileCount $TempDbDataFiles `
        -DataFileSize $TempDbDataFileSizeMB `
        -LogFileSize $TempDbLogFileSizeMB `
        -DataPath "F:\TempDB" `
        -LogPath "F:\TempDB" `
        -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
    Write-Host "Configured TempDB."

    Write-Host "SQL Server instance [$SqlInstance] configured."
}

function Install-OlaMaintenanceSolution {
    param([string]$SqlInstance, [string]$Root)

    $scriptPath = "$Root\SQLScripts\MaintenanceSolution.sql"
    Write-Host "Installing Ola Hallengren Maintenance Solution..."
    Invoke-WebRequest -Uri "https://ola.hallengren.com/scripts/MaintenanceSolution.sql" -OutFile $scriptPath -ErrorAction Stop
    Invoke-DbaQuery -SqlInstance $SqlInstance -File $scriptPath -ErrorAction Stop | Out-Null
    Write-Host "Installed Ola stored procedures and jobs."

    Write-Host "Assigning schedules to Ola jobs..."

    # === USER DATABASE JOBS ===
    if (Get-DbaAgentJob -SqlInstance $SqlInstance -Job "DatabaseBackup - USER_DATABASES - FULL" -ErrorAction SilentlyContinue) {
        New-DbaAgentSchedule -SqlInstance $SqlInstance -Job "DatabaseBackup - USER_DATABASES - FULL" `
            -Schedule "Daily 2AM" -FrequencyType Daily -StartTime 020000 -Force | Out-Null
        Write-Host "Scheduled DatabaseBackup - USER_DATABASES - FULL (Daily 2AM)"
    }

    if (Get-DbaAgentJob -SqlInstance $SqlInstance -Job "DatabaseBackup - USER_DATABASES - LOG" -ErrorAction SilentlyContinue) {
        New-DbaAgentSchedule -SqlInstance $SqlInstance -Job "DatabaseBackup - USER_DATABASES - LOG" `
            -Schedule "Every 15 Minutes" -FrequencyType Daily -FrequencySubDayType Minute -FrequencySubDayInterval 15 -StartTime 000000 -Force | Out-Null
        Write-Host "Scheduled DatabaseBackup - USER_DATABASES - LOG (Every 15 Minutes)"
    }

    if (Get-DbaAgentJob -SqlInstance $SqlInstance -Job "DatabaseBackup - USER_DATABASES - DIFF" -ErrorAction SilentlyContinue) {
        New-DbaAgentSchedule -SqlInstance $SqlInstance -Job "DatabaseBackup - USER_DATABASES - DIFF" `
            -Schedule "Daily 6AM" -FrequencyType Daily -StartTime 060000 -Force | Out-Null
        Write-Host "Scheduled DatabaseBackup - USER_DATABASES - DIFF (Daily 6AM)"
    }

    if (Get-DbaAgentJob -SqlInstance $SqlInstance -Job "DatabaseIntegrityCheck - USER_DATABASES" -ErrorAction SilentlyContinue) {
        New-DbaAgentSchedule -SqlInstance $SqlInstance -Job "DatabaseIntegrityCheck - USER_DATABASES" `
            -Schedule "Daily 1AM" -FrequencyType Daily -StartTime 010000 -Force | Out-Null
        Write-Host "Scheduled DatabaseIntegrityCheck - USER_DATABASES (Daily 1AM)"
    }

    if (Get-DbaAgentJob -SqlInstance $SqlInstance -Job "IndexOptimize - USER_DATABASES" -ErrorAction SilentlyContinue) {
        New-DbaAgentSchedule -SqlInstance $SqlInstance -Job "IndexOptimize - USER_DATABASES" `
            -Schedule "Weekly Sunday 3AM" -FrequencyType Weekly -FrequencyInterval Sunday -StartTime 030000 -Force | Out-Null
        Write-Host "Scheduled IndexOptimize - USER_DATABASES (Weekly Sunday 3AM)"
    }

    # === SYSTEM DATABASE JOBS ===
    if (Get-DbaAgentJob -SqlInstance $SqlInstance -Job "DatabaseBackup - SYSTEM_DATABASES - FULL" -ErrorAction SilentlyContinue) {
        New-DbaAgentSchedule -SqlInstance $SqlInstance -Job "DatabaseBackup - SYSTEM_DATABASES - FULL" `
            -Schedule "Daily 2:30AM" -FrequencyType Daily -StartTime 023000 -Force | Out-Null
        Write-Host "Scheduled DatabaseBackup - SYSTEM_DATABASES - FULL (Daily 2:30AM)"
    }

    if (Get-DbaAgentJob -SqlInstance $SqlInstance -Job "DatabaseIntegrityCheck - SYSTEM_DATABASES" -ErrorAction SilentlyContinue) {
        New-DbaAgentSchedule -SqlInstance $SqlInstance -Job "DatabaseIntegrityCheck - SYSTEM_DATABASES" `
            -Schedule "Weekly Sunday 4AM" -FrequencyType Weekly -FrequencyInterval Sunday -StartTime 040000 -Force | Out-Null
        Write-Host "Scheduled DatabaseIntegrityCheck - SYSTEM_DATABASES (Weekly Sunday 4AM)"
    }

    # === CLEANUP JOBS ===
    if (Get-DbaAgentJob -SqlInstance $SqlInstance -Job "CommandLog Cleanup" -ErrorAction SilentlyContinue) {
        New-DbaAgentSchedule -SqlInstance $SqlInstance -Job "CommandLog Cleanup" `
            -Schedule "Daily Midnight" -FrequencyType Daily -StartTime 000000 -Force | Out-Null
        Write-Host "Scheduled CommandLog Cleanup (Daily Midnight)"
    }

    if (Get-DbaAgentJob -SqlInstance $SqlInstance -Job "Output File Cleanup" -ErrorAction SilentlyContinue) {
        New-DbaAgentSchedule -SqlInstance $SqlInstance -Job "Output File Cleanup" `
            -Schedule "Daily Midnight" -FrequencyType Daily -StartTime 000000 -Force | Out-Null
        Write-Host "Scheduled Output File Cleanup (Daily Midnight)"
    }

    if (Get-DbaAgentJob -SqlInstance $SqlInstance -Job "sp_delete_backuphistory" -ErrorAction SilentlyContinue) {
        New-DbaAgentSchedule -SqlInstance $SqlInstance -Job "sp_delete_backuphistory" `
            -Schedule "Weekly Saturday 1AM" -FrequencyType Weekly -FrequencyInterval Saturday -StartTime 010000 -Force | Out-Null
        Write-Host "Scheduled sp_delete_backuphistory (Weekly Saturday 1AM)"
    }

    if (Get-DbaAgentJob -SqlInstance $SqlInstance -Job "sp_purge_jobhistory" -ErrorAction SilentlyContinue) {
        New-DbaAgentSchedule -SqlInstance $SqlInstance -Job "sp_purge_jobhistory" `
            -Schedule "Weekly Saturday 1:30AM" -FrequencyType Weekly -FrequencyInterval Saturday -StartTime 013000 -Force | Out-Null
        Write-Host "Scheduled sp_purge_jobhistory (Weekly Saturday 1:30AM)"
    }

    Write-Host "Ola job schedules assigned."
}

function Install-WhoIsActive {
    param([string]$SqlInstance, [string]$Root)

    $zipPath = "$Root\SQLScripts\WhoIsActive.zip"
    $extractPath = "$Root\SQLScripts\WhoIsActive"

    Write-Host "Installing sp_WhoIsActive..."
    Invoke-WebRequest -Uri "https://codeload.github.com/amachanic/sp_whoisactive/zip/refs/tags/v12.00" -OutFile $zipPath -ErrorAction Stop
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force -ErrorAction Stop
    $script = Get-ChildItem -Path $extractPath -Recurse -Filter "who_is_active.sql" | Select-Object -First 1
    if (-not $script) { throw "who_is_active.sql not found" }
    Invoke-DbaQuery -SqlInstance $SqlInstance -File $script.FullName -ErrorAction Stop | Out-Null
    Write-Host "Installed sp_WhoIsActive."
}

function Install-FirstResponderKit {
    param([string]$SqlInstance, [string]$Root)

    $zipPath = "$Root\SQLScripts\FirstResponderKit.zip"
    $extractPath = "$Root\SQLScripts\FirstResponderKit"

    Write-Host "Installing First Responder Kit..."
    Invoke-WebRequest -Uri "https://downloads.brentozar.com/FirstResponderKit.zip" -OutFile $zipPath -ErrorAction Stop
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force -ErrorAction Stop
    $script = Get-ChildItem -Path $extractPath -Recurse -Filter "Install-All-Scripts.sql" | Select-Object -First 1
    if (-not $script) { throw "Install-All-Scripts.sql not found" }
    Invoke-DbaQuery -SqlInstance $SqlInstance -File $script.FullName -Database master -ErrorAction Stop | Out-Null
    Write-Host "Installed First Responder Kit."
}

#-----------------------------
# Orchestrator
#-----------------------------
function Invoke-SqlServerSetup {
    param(
        [string]$FtpUrl,
        [string]$User,
        [string]$Password,
        [string]$IsoName,
        [string]$Root    = "F:",
        [string]$Version = "2022",
        [string]$InstanceName = "MSSQLSERVER",
        [switch]$InstallSSMS,
        [switch]$InstallOla,
        [switch]$InstallWhoIsActive,
        [switch]$InstallFRK
    )

    $isoDest = "$Root\ISOs\$IsoName"
    $mount   = $null
    $computer = $env:COMPUTERNAME

    try {
        Write-Host "Starting SQL Server setup..."

        New-SqlFolderLayout -Root $Root -Version $Version
        Get-SqlIsoFromFtp -FtpUrl $FtpUrl -User $User -Password $Password -IsoDest $isoDest

        $result = Mount-IsoImage -IsoPath $isoDest
        $mount = $result.Mount
        $drive = $result.Drive

        Install-SqlInstance -Drive $drive -Computer $computer -Root $Root -Version $Version -InstanceName $InstanceName
        Configure-SqlInstance -SqlInstance $computer

        if ($InstallSSMS)       { Install-SsmsClient }
        if ($InstallOla)        { Install-OlaMaintenanceSolution -SqlInstance $computer -Root $Root }
        if ($InstallWhoIsActive){ Install-WhoIsActive -SqlInstance $computer -Root $Root }
        if ($InstallFRK)        { Install-FirstResponderKit -SqlInstance $computer -Root $Root }

        Write-Host "SQL Server setup completed."
    }
    catch { Write-Error "SQL Server setup failed: $_" }
    finally {
        if ($mount) {
            try {
                Dismount-DiskImage -ImagePath $isoDest -ErrorAction Stop | Out-Null
                Write-Host "ISO unmounted."
            }
            catch { Write-Host "ISO unmount failed." }
        }
    }
}

#-----------------------------
# Example usage
#-----------------------------
Invoke-SqlServerSetup `
  -FtpUrl "ftp://<ftp-ip-address>/uploads/SQLServer/SQLServer2022-x64-ENU-Dev.iso" `
  -User "ftpuser" `
  -Password "<SuperStrongPassword>" `
  -IsoName "SQLServer2022-x64-ENU-Dev.iso" `
  -Version "2022" `
  -InstanceName "MSSQLSERVER" `
  -InstallSSMS `
  -InstallOla `
  -InstallWhoIsActive `
  -InstallFRK
