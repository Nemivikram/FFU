---
title: Hyper-V Settings
nav_order: 1
prev_url: /ui_overview.html
prev_label: UI Overview
next_url: /windows_settings.html
next_label: Windows Settings
parent: UI Overview
---
# Hyper-V Settings

![1776378277110](image/hyperv_settings/1776378277110.png)

## Enable VM Networking (Experimental)

Controls whether the build VM is connected to a Hyper-V switch during provisioning.

Leave this off for the default offline build path. Turn it on only if you want to test internet-connected builds and understand there may be Sysprep or capture issues.

## VM Switch Name

Drop down of detected VM Switches. There's also an **Other** option which allows you to specify a VM Switch Name. The other option is useful in scenarios where the machine you're running the UI from isn't going to be the machine where you plan to build the FFU from.

This setting is only used when **Enable VM Networking (Experimental)** is turned on. VM-based builds still capture from the host-side VHDX after the VM shuts down, so you only need a switch when the VM requires network connectivity during provisioning.

## Disk Size (GB)

Size of the virtual hard disk for the virtual machine. Default is a 50GB dynamic disk. You may want to increase the size if you're installing many apps.

## Memory (GB)

Amount of memory to allocate for the virtual machine. Recommended to use 8GB if possible, especially for Windows 11. Default is 4GB.

## Processors

Number of virtual processors for the virtual machine. Recommended to use at least 4. Default is 4.

## VM Location

Default is `$FFUDevelopmentPath\VM`. This is the location of the VHDX that gets created where Windows will be installed to.

## VM Name Prefix

Prefix for the generated VM. Default is _FFU.

## System Partition Drive Letter

Drive letter used for the System partition while building the FFU VHDX. Default is `S`.

## Windows Partition Drive Letter

Drive letter used for the Windows partition while building the FFU VHDX. Default is `W`.

## Recovery Partition Drive Letter

Drive letter used for the Recovery partition while building the FFU VHDX. Default is `R`.

These settings only affect FFU creation. The deployment script discovers the Windows and Recovery partitions from the applied disk instead of relying on fixed partition numbers.

## Additional Data Partitions

Creates optional data partitions after the Windows Recovery partition. This keeps Recovery immediately after Windows, which leaves the normal WinRE layout intact while still allowing one or more data volumes in the captured FFU.

Set **Windows Partition Size (GB)** before adding data partitions. Without an explicit Windows partition size, Windows would consume the remaining VHDX space and there would be no room left for Recovery and data partitions.

Use **Recovery Partition Size (GB)** only when you need a fixed Recovery partition size. Leave it blank to let the build calculate the Recovery size from `winre.wim` plus buffer space.

Each data partition has a name, build-time drive letter, and either a size in GB or **Fill Remaining**. Only one data partition can use **Fill Remaining**. Fixed-size data partitions are created before the fill-remaining data partition so the fill-remaining volume does not consume space reserved for later fixed-size volumes.

The Apps ISO drive letter is discovered at runtime. If you create a data partition that uses `D:`, application installs should use `%FFUAppsRoot%` for Apps ISO paths. Legacy `D:\` paths in `UserAppList.json` are still supported when they point to files on the Apps ISO.

## Logical Sector Size

Uint32 value of 512 or 4096. Useful for 4Kn drives or devices shipping with UFS drives. Default is 512.

There is some error-handling in the script that will call out mismatch issues with logical sector size. Unfortunately you will need to create a new FFU with the correct logical sector size as you can't convert a previously created FFU. Most should be fine with 512, but lower-end devices that used to ship with eMMC drives have now shifted to using UFS.

{% include page_nav.html %}
