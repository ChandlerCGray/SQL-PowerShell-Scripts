# Example usage of the YAML-based SQL Server setup script
# This shows how to use the main script with custom configuration

# Load the main script
. ".\SetupScript.ps1"

Write-Host "SQL Server Installation with YAML Configuration" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Configuration options:" -ForegroundColor Cyan
Write-Host "1. Use default config: .\SetupScript.ps1" -ForegroundColor White
Write-Host "2. Use custom config: .\SetupScript.ps1 -ConfigFile 'C:\MyConfig\custom.yaml'" -ForegroundColor White
Write-Host "3. Edit sql-server-config.yaml to customize settings" -ForegroundColor White
Write-Host ""

# Example: Run with default YAML config
Write-Host "Running with default configuration..." -ForegroundColor Yellow
Write-Host "Edit sql-server-config.yaml to customize your settings" -ForegroundColor Cyan
Write-Host ""

# The main script will automatically load the YAML configuration
# No need to manually call the functions - the script handles everything
