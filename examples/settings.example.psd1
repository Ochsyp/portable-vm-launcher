# Copy this file to Launcher\settings.psd1 on the stick and fill in your stick's values. The
# placeholders match no disk, so until then the launcher stops at its identity check.
@{
    # Which program runs the VM:
    #   'Auto'       = resume a saved/suspended VM in the program that saved it; otherwise
    #                  VMware Workstation if it is installed on this PC, else VirtualBox.
    #                  (A VM saved in one program is never started in the other.)
    #   'VMware'     = always VMware Workstation
    #   'VirtualBox' = always VirtualBox
    Hypervisor = 'Auto'

    # VMware only: 'Window' = normal window, 'FullScreen' = start in full screen
    VMwareView = 'Window'

    # A saved state that the launcher did not record (any VirtualBox save, or a VMware suspend from
    # before suspend.disabled was set) holds changes to the stick: 'Ask' asks before it is resumed,
    # with No as the default answer; 'Refuse' stops the launcher instead. Without this line: 'Ask'.
    SavedStatePolicy = 'Ask'

    # VirtualBox only: $true = inside the VM, the stick's Data partition (the NTFS one Windows uses)
    # shows up empty. VMware always works this way, because it has to take the VM's partitions away
    # from Windows and can't take the Data partition, which holds the VM's own files.
    HideDataPartition = $false

    # Identity of the stick. The launcher refuses to start the VM on any disk that does not match.
    # Read the values in PowerShell, with N = the stick's disk number from Get-Disk and P = the
    # partition the launcher lives on (Get-Partition -DiskNumber N):
    #   StickMbrSignature  = '{0:X8}' -f (Get-Disk -Number N).Signature
    #   StickSectors       = (Get-Disk -Number N).Size / 512
    #   DataPartitionStart = P.Offset / 512
    #   VmSectors          = (P.Offset + P.Size) / 512
    StickMbrSignature  = 'REPLACE-ME'
    StickSectors       = 0
    # The VM sees sectors 0 .. VmSectors-1 of the stick (everything up to the end of the Data partition)
    VmSectors          = 0
    # First sector of the Data partition (the one this launcher lives on)
    DataPartitionStart = 0

    # VirtualBox: the VM's UUID (VBoxManage list vms) and its files, relative to the stick's root.
    VirtualBoxVmUuid = '5ca1ab1e-0000-4000-8000-000000000000'
    VirtualBoxHome   = 'VirtualBox'
    VirtualBoxVbox   = 'VirtualBox\Example VM\Example VM.vbox'
    VirtualBoxDisk   = 'VirtualBox\Example VM\example-stick.vmdk'

    # VMware Workstation: the VM's files, relative to the stick's root.
    VMwareVmx  = 'VMware\Example VM.vmx'
    VMwareDisk = 'VMware\example-stick.vmdk'
}
