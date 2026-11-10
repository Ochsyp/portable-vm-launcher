@echo off
rem Double-click to start the VM from this USB stick.
rem It asks for administrator rights, then starts the VM in VMware Workstation or VirtualBox
rem (whichever this PC has). Details and settings: Launcher\Start-PortableVM.ps1, LauncherData\settings.psd1
start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Launcher\Start-PortableVM.ps1"
