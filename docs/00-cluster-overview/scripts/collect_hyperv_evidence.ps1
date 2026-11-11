$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

Write-Output '===== 0. HOST ====='
hostname
whoami
Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,OSArchitecture,LastBootUpTime,TotalVisibleMemorySize,FreePhysicalMemory,LocalDateTime | Format-List | Out-String -Width 240
Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer,Model,TotalPhysicalMemory,NumberOfProcessors,NumberOfLogicalProcessors,HypervisorPresent | Format-List | Out-String -Width 240
Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors,MaxClockSpeed,SocketDesignation | Format-Table -AutoSize | Out-String -Width 240
Get-CimInstance Win32_PhysicalMemory | Select-Object BankLabel,Capacity,Speed,Manufacturer,PartNumber | Format-Table -AutoSize | Out-String -Width 240
Get-CimInstance Win32_VideoController | Select-Object Name,AdapterRAM,DriverVersion | Format-Table -AutoSize | Out-String -Width 240

Write-Output '===== 1. DISK ====='
Get-Disk | Select-Object Number,FriendlyName,SerialNumber,Size,PartitionStyle,HealthStatus,OperationalStatus | Format-Table -AutoSize | Out-String -Width 240
Get-PhysicalDisk | Select-Object FriendlyName,MediaType,BusType,Size,HealthStatus,OperationalStatus | Format-Table -AutoSize | Out-String -Width 240
Get-Volume | Select-Object DriveLetter,FileSystemLabel,FileSystem,DriveType,Size,SizeRemaining,HealthStatus | Format-Table -AutoSize | Out-String -Width 240
Get-VMHost | Select-Object Name,VirtualMachinePath,VirtualHardDiskPath | Format-List | Out-String -Width 240

Write-Output '===== 2. NETWORK ====='
Get-NetAdapter | Select-Object Name,InterfaceDescription,Status,LinkSpeed,MacAddress | Format-Table -AutoSize | Out-String -Width 240
Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias,IPAddress,PrefixLength,AddressState | Format-Table -AutoSize | Out-String -Width 240
Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Select-Object InterfaceAlias,NextHop,RouteMetric | Format-Table -AutoSize | Out-String -Width 240
Get-DnsClientServerAddress -AddressFamily IPv4 | Select-Object InterfaceAlias,ServerAddresses | Format-Table -AutoSize | Out-String -Width 240
Get-VMSwitch | Select-Object Name,SwitchType,NetAdapterInterfaceDescription,AllowManagementOS,EmbeddedTeam | Format-List | Out-String -Width 240

Write-Output '===== 3. HYPERV VMS ====='
Get-VM | Select-Object Name,State,Generation,Version,ProcessorCount,MemoryStartup,MemoryAssigned,MemoryMinimum,MemoryMaximum,DynamicMemoryEnabled,Path,Uptime,IntegrationServicesState | Format-List | Out-String -Width 240
Get-VMNetworkAdapter -VMName * | Select-Object VMName,Name,SwitchName,MacAddress,IPAddresses,Status,IsLegacy | Format-Table -AutoSize | Out-String -Width 240
Get-VHD -VMName * | Select-Object VMName,Path,VhdFormat,VhdType,FileSize,Size,MinimumSize,Attached | Format-Table -AutoSize | Out-String -Width 240
Get-VMSnapshot -VMName * | Select-Object VMName,Name,SnapshotType,CreationTime,ParentSnapshotName | Format-Table -AutoSize | Out-String -Width 240
Get-VMFirmware -VMName * | Select-Object VMName,SecureBoot,SecureBootTemplate | Format-Table -AutoSize | Out-String -Width 240
Get-VMIntegrationService -VMName * | Select-Object VMName,Name,Enabled,PrimaryStatusDescription | Format-Table -AutoSize | Out-String -Width 240

Write-Output '===== 4. SERVICES ====='
Get-Service vmms,vmcompute,sshd,TermService -ErrorAction SilentlyContinue | Select-Object Name,Status,StartType | Format-Table -AutoSize | Out-String -Width 240
Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue | Select-Object FeatureName,State | Format-Table -AutoSize | Out-String -Width 240
Get-WindowsCapability -Online -Name OpenSSH* -ErrorAction SilentlyContinue | Select-Object Name,State | Format-Table -AutoSize | Out-String -Width 240

Write-Output '===== 5. RECENT ERRORS ====='
Get-WinEvent -FilterHashtable @{LogName='System'; Level=1,2; StartTime=(Get-Date).AddDays(-7)} -MaxEvents 30 -ErrorAction SilentlyContinue | Select-Object TimeCreated,ProviderName,Id,LevelDisplayName,Message | Format-Table -Wrap -AutoSize | Out-String -Width 240

Write-Output '===== 6. END ====='
Get-Date -Format o
