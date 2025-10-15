# SQL Server Automated Installation Script

A PowerShell script for automated SQL Server installation and configuration with YAML-based configuration management.

## Features

- 🚀 **Automated SQL Server Installation** - Downloads ISO from FTP and installs SQL Server
- 📋 **YAML Configuration** - Easy-to-edit configuration file
- 🛠️ **Optional Components** - SSMS, Ola Hallengren's Maintenance Solution, sp_WhoIsActive, First Responder Kit
- 📊 **Progress Tracking** - Real-time progress indicators and detailed logging
- 🔧 **SQL Server Optimization** - Memory configuration, TempDB optimization, default paths
- ⏰ **Automated Scheduling** - Pre-configured maintenance job schedules

## Prerequisites

- Windows 10/11 or Windows Server 2016+
- PowerShell 5.1 or higher
- Administrator privileges
- FTP server with SQL Server ISO file
- Internet connection (for dbatools and SSMS installation)

## Quick Start

1. **Clone or download this repository**
2. **Edit the configuration file:**
   ```yaml
   # Edit sql-server-config.yaml
   ftp:
     url: "ftp://your-ftp-server.com/path/to/SQLServer2022-x64-ENU-Dev.iso"
     username: "your-ftp-username"
     password: "your-ftp-password"
   ```

3. **Run the installation:**
   ```powershell
   # Run as Administrator
   .\SetupScript.ps1
   ```

## Configuration

All settings are managed through `sql-server-config.yaml`:

### FTP Settings
```yaml
ftp:
  url: "ftp://your-server/path/to/iso"
  username: "your-username"
  password: "your-password"
  iso_name: "SQLServer2022-x64-ENU-Dev.iso"
```

### Paths
```yaml
paths:
  root: "F:"  # Root drive for SQL Server files
  version: "2022"
  instance_name: "MSSQLSERVER"
```

### Installation Options
```yaml
install_options:
  install_ssms: true          # SQL Server Management Studio
  install_ola: true           # Ola Hallengren's Maintenance Solution
  install_whoisactive: true   # sp_WhoIsActive
  install_frk: true           # First Responder Kit
```

### SQL Server Configuration
```yaml
sql_config:
  percent_max_memory: 75      # Percentage of RAM for SQL Server
  tempdb_data_files: "auto"   # Number of TempDB data files (auto = CPU count)
  tempdb_data_file_size_mb: 512
  tempdb_log_file_size_mb: 512
```

## Usage Examples

### Basic Installation
```powershell
.\SetupScript.ps1
```

### Custom Configuration File
```powershell
.\SetupScript.ps1 -ConfigFile "C:\MyConfig\production.yaml"
```

### Example Script
```powershell
.\SetupScript-Example.ps1
```

## What Gets Installed

### SQL Server Components
- SQL Server 2022 (Engine, Replication, Tools)
- SQL Server Management Studio (via Winget)
- Ola Hallengren's Maintenance Solution
- sp_WhoIsActive stored procedure
- First Responder Kit

### Folder Structure Created
```
F:\
├── ISOs\           # SQL Server ISO files
├── SQL2022\        # SQL Server instance files
├── SQLData\        # Database data files
├── SQLLogs\        # Database log files
├── TempDB\         # TempDB files
├── SQLBackups\     # Backup files
├── SQLConfigs\     # Configuration files
└── SQLScripts\     # Script files
```

### Maintenance Jobs Scheduled
- **Daily 2AM**: Full backup of user databases
- **Every 15 minutes**: Transaction log backups
- **Daily 6AM**: Differential backups
- **Daily 1AM**: Database integrity checks
- **Weekly Sunday 3AM**: Index optimization
- **Daily 2:30AM**: System database backups
- **Weekly Sunday 4AM**: System database integrity checks
- **Daily Midnight**: Cleanup jobs

## Customization

### Custom Job Schedules
Edit the `ola_schedules` section in `sql-server-config.yaml`:

```yaml
ola_schedules:
  user_databases:
    "DatabaseBackup - USER_DATABASES - FULL":
      schedule: "Daily 2AM"
      frequency_type: "Daily"
      start_time: "020000"
```

### Different SQL Server Versions
Change the version in the configuration:

```yaml
paths:
  version: "2019"  # or "2017", "2016"
```

### Custom Paths
```yaml
paths:
  root: "D:"  # Use different drive
  instance_name: "MYINSTANCE"  # Named instance
```

## Troubleshooting

### Common Issues

1. **"This script must be run as Administrator"**
   - Right-click PowerShell → "Run as Administrator"

2. **"Winget is not available"**
   - Install Windows Package Manager or use Windows 10/11

3. **"FTP download failed"**
   - Check FTP credentials and server accessibility
   - Verify ISO file exists on FTP server

4. **"ISO mount failed"**
   - Ensure ISO file downloaded completely
   - Check available drive letters

### Logs and Debugging

The script provides detailed logging with timestamps:
```
[2025-10-15 13:33:19] [Info] Starting SQL Server installation...
[2025-10-15 13:33:19] [Success] Prerequisites validated successfully
[2025-10-15 13:33:53] [Success] Created folder: F:\ISOs
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Support

For issues and questions:
- Create an issue in the GitHub repository
- Check the troubleshooting section above
- Review the configuration file documentation
