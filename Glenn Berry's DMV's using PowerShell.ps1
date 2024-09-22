<#
.SYNOPSIS
    Exports SQL Server diagnostic data using Glenn Berry's DMV queries.

.DESCRIPTION
    This script runs instance-level diagnostic queries by default.
    It optionally allows the user to run database-specific queries against selected databases.
    It exports the results to CSV files and merges them into a single Excel workbook.

.PARAMETER SqlInstance
    The SQL Server instance to connect to. If not provided, the script will prompt for it.

.PARAMETER ExportRootPath
    The root directory where export files will be saved. If not provided, the script will prompt for it.

.PARAMETER RunDatabaseQueries
    Switch to indicate that database-specific queries should be run.
    If not provided, the script will prompt whether to run database-specific queries.

.PARAMETER DatabaseNames
    An array of database names for database-specific queries. If not provided and database-specific queries are run, the script will prompt for selection.

.EXAMPLE
    .\Export-SQLDiagnosticData.ps1 -SqlInstance "MyServer" -RunDatabaseQueries -DatabaseNames "DB1","DB2"

    Runs the script against "MyServer", runs instance-level queries, and runs database-specific queries against "DB1" and "DB2".

.EXAMPLE
    .\Export-SQLDiagnosticData.ps1

    Runs the script and prompts for any required inputs not provided.
#>

param (
    [string]$SqlInstance,
    [string]$ExportRootPath,
    [string[]]$DatabaseNames,
    [switch]$RunDatabaseQueries
)

# Function to ensure that a module is installed
function Ensure-ModuleInstalled {
    param (
        [string]$ModuleName
    )
    if (-not (Get-Module -ListAvailable -Name $ModuleName)) {
        try {
            Write-Host "Installing module: $ModuleName"
            Install-Module -Name $ModuleName -AllowClobber -Force -ErrorAction Stop
            Write-Host "$ModuleName installed successfully."
        }
        catch {
            Write-Host "Error: Failed to install $ModuleName. Exiting script." -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "$ModuleName is already installed."
    }
}

# Function to ensure that a directory exists
function Ensure-DirectoryExists {
    param (
        [string]$DirectoryPath
    )
    if (-not (Test-Path -Path $DirectoryPath)) {
        try {
            Write-Host "Creating directory: $DirectoryPath"
            New-Item -Path $DirectoryPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Host "Error: Could not create directory $DirectoryPath. Exception: $_" -ForegroundColor Red
            exit 1
        }
    }
}

# Function to select the authentication method
function Get-AuthenticationMethod {
    param ()

    while ($true) {
        Write-Host ""
        Write-Host "Select Authentication Method:"
        Write-Host "1) Windows Authentication"
        Write-Host "2) SQL Login"
        $authMethodInput = Read-Host "Enter the number corresponding to your choice (default: 1)"
    
        if (-not $authMethodInput) { $authMethodInput = "1" }
    
        switch ($authMethodInput) {
            "1" {
                Write-Host "Using Windows Authentication."
                $UseSqlAuthentication = $false
                $SqlCredential = $null
                break
            }
            "2" {
                Write-Host "Using SQL Authentication."
                $UseSqlAuthentication = $true
                $SqlCredential = Get-Credential -Message "Enter SQL Login credentials"
                break
            }
            default {
                Write-Host "Invalid selection. Defaulting to Windows Authentication."
                $UseSqlAuthentication = $false
                $SqlCredential = $null
                break
            }
        }
        break
    }

    return @($SqlCredential, $UseSqlAuthentication)
}

# Function to test the SQL Server connection
function Test-SqlConnection {
    param (
        [string]$SqlInstance,
        [pscredential]$SqlCredential
    )
    try {
        if ($SqlCredential) {
            $null = Connect-DbaInstance -SqlInstance $SqlInstance -SqlCredential $SqlCredential -ErrorAction Stop
        } else {
            $null = Connect-DbaInstance -SqlInstance $SqlInstance -ErrorAction Stop
        }
        return $true
    }
    catch {
        Write-Host "Failed to connect to SQL Server instance '$SqlInstance'. Error: $_" -ForegroundColor Red
        return $false
    }
}

# Function to retrieve the list of databases
function Get-DatabaseList {
    param (
        [string]$SqlInstance,
        [pscredential]$SqlCredential
    )
    try {
        if ($SqlCredential) {
            $Databases = Get-DbaDatabase -SqlInstance $SqlInstance -SqlCredential $SqlCredential -ErrorAction Stop | Select-Object -ExpandProperty Name
        } else {
            $Databases = Get-DbaDatabase -SqlInstance $SqlInstance -ErrorAction Stop | Select-Object -ExpandProperty Name
        }
        return $Databases
    } catch {
        Write-Host "Failed to retrieve databases from the instance. Error: $_" -ForegroundColor Red
        exit 1
    }
}

# Function to select databases
function Select-Databases {
    param (
        [string[]]$Databases
    )
    # Print list of databases with numbers
    Write-Host ""
    Write-Host "Available Databases:"
    for ($i = 0; $i -lt $Databases.Count; $i++) {
        Write-Host "$($i + 1)) $($Databases[$i])"
    }

    # Prompt user to select databases
    $databaseSelection = Read-Host "Enter the numbers corresponding to the databases you want to select, separated by commas (e.g., 1,3,5)"

    # Process user input to get selected databases
    if (-not $databaseSelection) {
        Write-Host "No databases selected for database-specific queries."
        return @()
    }

    $selectedIndexes = $databaseSelection -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }

    $SelectedDatabases = @()

    foreach ($index in $selectedIndexes) {
        if (($index -as [int]) -gt 0 -and ($index -as [int]) -le $Databases.Count) {
            $SelectedDatabases += $Databases[$index - 1]
        } else {
            Write-Host "Invalid selection: $index" -ForegroundColor Yellow
        }
    }

    if (-not $SelectedDatabases) {
        Write-Host "No valid databases selected for database-specific queries."
    }

    return $SelectedDatabases
}

# Function to export diagnostic data
function Export-SQLDiagnosticData {
    param (
        [string]$SqlInstance,
        [string]$ExportRootPath,
        [pscredential]$SqlCredential,
        [string[]]$DatabaseNames
    )
    Write-Host "Starting SQL Diagnostic Data export for instance: $SqlInstance"

    # Set up where to save the data
    $ExportPaths = @{
        SQLDiagnosticData = "$ExportRootPath\"
    }

    # Export instance-level diagnostic data
    try {
        Write-Host "Running instance-level diagnostic queries..."
        if ($SqlCredential) {
            $InstanceResults = Invoke-DbaDiagnosticQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -NoColumnParsing -InstanceOnly -ErrorAction Stop
        } else {
            $InstanceResults = Invoke-DbaDiagnosticQuery -SqlInstance $SqlInstance -NoColumnParsing -InstanceOnly -ErrorAction Stop
        }

        $i = 0
        foreach ($Result in $InstanceResults) {
            $i++
            $InstanceDir = "$($ExportPaths.SQLDiagnosticData)\Instance"
            Ensure-DirectoryExists -DirectoryPath $InstanceDir
            $InstancePath = "$InstanceDir\$i-$($Result.Name).csv"

            # If there's data, save it, otherwise note that no data was found
            if ($Result.Result) {
                $Result.Result | Export-Csv -Path $InstancePath -NoTypeInformation
                Write-Host "Instance diagnostic data saved to $InstancePath"
            } else {
                New-Object PSObject -Property @{ 'NoData' = 'No diagnostic data found for this query.' } |
                Export-Csv -Path $InstancePath -NoTypeInformation
                Write-Host "No data found for query: $($Result.Name)"
            }
        }
    }
    catch {
        Write-Host "Error: Failed to export instance-level diagnostic data. Exception: $_" -ForegroundColor Red
        exit 1
    }

    # Export database-specific diagnostic data if databases are specified
    if ($DatabaseNames -and $DatabaseNames.Count -gt 0) {
        foreach ($DatabaseName in $DatabaseNames) {
            Write-Host "Processing database: $DatabaseName"

            try {
                if ($SqlCredential) {
                    $DatabaseResults = Invoke-DbaDiagnosticQuery -SqlInstance $SqlInstance -SqlCredential $SqlCredential -NoColumnParsing -DatabaseSpecific -DatabaseName $DatabaseName -ErrorAction Stop
                } else {
                    $DatabaseResults = Invoke-DbaDiagnosticQuery -SqlInstance $SqlInstance -NoColumnParsing -DatabaseSpecific -DatabaseName $DatabaseName -ErrorAction Stop
                }

                foreach ($Result in $DatabaseResults) {
                    $i++
                    $DatabaseDir = "$($ExportPaths.SQLDiagnosticData)\DatabaseSpecific\$DatabaseName"
                    Ensure-DirectoryExists -DirectoryPath $DatabaseDir
                    $DatabasePath = "$DatabaseDir\$i-$($Result.Name).csv"

                    # Save data or show a message if there's none
                    if ($Result.Result) {
                        $Result.Result | Export-Csv -Path $DatabasePath -NoTypeInformation
                        Write-Host "Database-specific diagnostic data saved to $DatabasePath"
                    } else {
                        New-Object PSObject -Property @{ 'NoData' = 'No diagnostic data found for this query.' } |
                        Export-Csv -Path $DatabasePath -NoTypeInformation
                        Write-Host "No data found for query: $($Result.Name)"
                    }
                }
            }
            catch {
                Write-Host "Error: Failed to export diagnostic data for database $DatabaseName. Exception: $_" -ForegroundColor Red
                Write-Host "Skipping database $DatabaseName due to errors."
                # Continue to the next database instead of exiting
            }
        }
    } else {
        Write-Host "No databases specified for database-specific queries. Skipping database-specific diagnostics."
    }

    Write-Host "SQL Diagnostic Data export completed."
}

# Function to merge CSV files into an Excel workbook
function Merge-CSVToExcel {
    param (
        [string]$ExportRootPath
    )
    # Now merge all the CSVs into a single Excel file
    $ExcelFilePath = "$ExportRootPath\SQLDiagnostics.xlsx"
    Ensure-DirectoryExists -DirectoryPath $ExportRootPath

    Write-Host "Merging CSV data into Excel file: $ExcelFilePath"

    # Get the list of CSV files and organize them
    $csvFiles = Get-ChildItem -Path "$ExportRootPath\Instance", "$ExportRootPath\DatabaseSpecific" -Filter *.csv -Recurse -ErrorAction SilentlyContinue |
        Sort-Object {
            [int]($_.BaseName -replace '(\d+)-.*','$1')
        }

    if (-not $csvFiles) {
        Write-Host "No CSV files found to merge into Excel."
        return
    }

    # Add each CSV to the Excel file
    foreach ($csv in $csvFiles) {
        $sheetName = [System.IO.Path]::GetFileNameWithoutExtension($csv.Name)
        if ($sheetName.Length -ge 30) {
            $sheetName = $sheetName.Substring(0, 30)
        }
        try {
            Import-Csv -Path $csv.FullName | Export-Excel -Path $ExcelFilePath -WorksheetName $sheetName -Append -AutoSize -ErrorAction Stop
            Write-Host "Added $($csv.Name) to $ExcelFilePath"
        }
        catch {
            Write-Host "Failed to add $($csv.Name) to $ExcelFilePath" -ForegroundColor Yellow
        }
    }

    Write-Host "All CSV files have been merged into $ExcelFilePath"
}

# Prompt for SQL Server instance if not provided
if (-not $SqlInstance) {
    $SqlInstance = Read-Host "Enter SQL Server Name (default: localhost)"
    if (-not $SqlInstance) { $SqlInstance = "localhost" }
}

# Prompt for export root path if not provided
if (-not $ExportRootPath) {
    $ExportRootPath = Read-Host "Enter the export root path (default: $env:USERPROFILE\Documents\SQLDiagnosticData)"
    if (-not $ExportRootPath) { $ExportRootPath = "$env:USERPROFILE\Documents\SQLDiagnosticData" }
}

# Initialize the timestamp and export path
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$ExportRootPath = Join-Path -Path $ExportRootPath -ChildPath $timestamp

# Ensure the root export directory exists
Ensure-DirectoryExists -DirectoryPath $ExportRootPath

# Ensure required modules are installed
Ensure-ModuleInstalled -ModuleName "dbatools"
Ensure-ModuleInstalled -ModuleName "ImportExcel"

Set-DbatoolsInsecureConnection -SessionOnly

# Import modules
Import-Module dbatools
Import-Module ImportExcel

# Authentication loop
$authSuccess = $false
while (-not $authSuccess) {
    # Get authentication method
    $authResult = Get-AuthenticationMethod
    $SqlCredential = $authResult[0]
    $UseSqlAuthentication = $authResult[1]

    # Test the connection
    if (Test-SqlConnection -SqlInstance $SqlInstance -SqlCredential $SqlCredential) {
        $authSuccess = $true
    } else {
        Write-Host "Authentication failed. Please try again."
    }
}

# Prompt whether to run database-specific queries if not specified
if (-not $RunDatabaseQueries.IsPresent) {
    Write-Host ""
    $runDbQueriesInput = Read-Host "Do you want to run database-specific diagnostic queries? (Y/N, default: N)"
    if ($runDbQueriesInput.ToUpper() -eq "Y") {
        $RunDatabaseQueries = $true
    } else {
        $RunDatabaseQueries = $false
    }
}

# If -RunDatabaseQueries is true and -DatabaseNames is not provided, prompt for database selection
if ($RunDatabaseQueries -and (-not $DatabaseNames)) {
    # Get list of databases
    $Databases = Get-DatabaseList -SqlInstance $SqlInstance -SqlCredential $SqlCredential

    # Select databases
    $DatabaseNames = Select-Databases -Databases $Databases
}

# Export diagnostic data
Export-SQLDiagnosticData -SqlInstance $SqlInstance -ExportRootPath $ExportRootPath -SqlCredential $SqlCredential -DatabaseNames $DatabaseNames

# Merge CSV files into Excel
Merge-CSVToExcel -ExportRootPath $ExportRootPath

Write-Host "Script execution completed."
