# Copy this file to LauncherData\settings.psd1 on the stick, in the folder that holds the
# Launcher folder, fill in your stick's values and delete the IsExample line. Until then the
# launcher stops and says the file is still the example; its placeholders match no disk either.
# Keep the file ASCII, or save it as UTF-8 with BOM: a file without a byte order mark that holds
# other characters is refused, since Windows PowerShell would read it differently.
@{
    # The format of this file. The launcher reads only settings of schema 2.
    SchemaVersion = 2

    # Marks the untouched example. Delete this line once your values are in.
    IsExample = $true

    # How messages and the dialog title name the VM and the guest system, for example
    # VmDisplayName = 'Work VM' and GuestName = 'Debian'. Up to 40 characters each. With the
    # defaults below, messages say "the VM" and "the guest" and the dialog title is 'Portable VM'.
    VmDisplayName = 'the VM'
    GuestName = 'the guest'

    # Which program runs the VM:
    #   'Auto'       = resume a saved/suspended VM in the program that saved it; otherwise
    #                  VMware Workstation if it is installed on this PC, else VirtualBox.
    #                  (A VM saved in one program is never started in the other.)
    #   'VMware'     = always VMware Workstation
    #   'VirtualBox' = always VirtualBox
    # Without this line: 'Auto'. Any other value is refused.
    Hypervisor = 'Auto'

    # VMware only: 'Window' = normal window, 'FullScreen' = start in full screen. Without this
    # line: 'Window'.
    VMwareView = 'Window'

    # A saved state that the launcher did not record (any VirtualBox save, or a VMware suspend from
    # before suspend.disabled was set) holds changes to the stick: 'Ask' asks before it is resumed,
    # with No as the default answer; 'Refuse' stops the launcher instead. Without this line: 'Ask'.
    SavedStatePolicy = 'Ask'

    # VirtualBox only: $true = inside the VM, the stick's Data partition (the NTFS one Windows uses)
    # shows up empty. VMware always works this way, because it has to take the VM's partitions away
    # from Windows and can't take the Data partition, which holds the VM's own files. Without this
    # line: $false.
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

    # The paths below are relative to the folder that holds Launcher and LauncherData, use \ or /,
    # and have no drive letter, no '.' or '..' part and no part that ends in a dot or a blank.

    # VirtualBox: the VM's UUID (VBoxManage list vms) and its files.
    VirtualBoxVmUuid = '5ca1ab1e-0000-4000-8000-000000000000'
    VirtualBoxHome   = 'VirtualBox'
    VirtualBoxVbox   = 'VirtualBox\Example VM\Example VM.vbox'
    VirtualBoxDisk   = 'VirtualBox\Example VM\example-stick.vmdk'

    # VMware Workstation: the VM's files.
    VMwareVmx  = 'VMware\Example VM.vmx'
    VMwareDisk = 'VMware\example-stick.vmdk'
}
