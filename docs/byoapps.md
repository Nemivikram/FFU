---
title: Bring Your Own Applications
nav_order: 6
prev_url: /winget.html
prev_label: Install Winget Applications
next_url: /appsscriptvariables.html
next_label: Apps Script Variables
parent: Applications
grand_parent: UI Overview
---
# Bring Your Own Applications

![1776378975827](image/byoapps/1776378975827.png)

Bring Your Own Applications allows you to run any command line you want in the virtual machine to include in your FFU to install an application, run a script, etc. As the name implies, you'll provide the content, command line, arguments, and additional exit codes.

All applications are stored in the `$AppsPath` parent folder which defaults to `C:\FFUDevelopment\Apps`. Winget source applications and BYO Apps that you select Copy Apps are stored in `$AppsPath\Win32`. MSStore source apps from Winget are stored in `$AppsPath\MSStore`.

At build time, an `Apps.iso` file is created from the `$AppsPath` folder and mounted to the VM. Use `%FFUAppsRoot%` in command lines and arguments to reference the mounted Apps ISO, for example `%FFUAppsRoot%\Win32\MyApp\setup.exe`.

Existing `UserAppList.json` files that use `D:\` paths are still supported. If a legacy `D:\` path does not exist in the VM but the same relative path exists on the Apps ISO, FFU Builder remaps it to `%FFUAppsRoot%` at runtime.

## Name

The name of the application. The name is also used when selecting **Copy Apps** to copy apps from a source location to the `$AppsPath\Win32\<Name>` folder (e.g. `C:\FFUDevelopment\Apps\Win32\Google Chrome`)

## Command Line

This is the full path to the command line to install the application, script, or to run a command. If the content was included in the `$AppsPath`, use `%FFUAppsRoot%` (e.g. `%FFUAppsRoot%\Win32\Mozilla Firefox\Mozilla Firefox_136.0.3_Machine_X64_exe_en-US.exe`). Legacy `D:\Win32` paths are still supported.

For MSI applications, this should only include msiexec. The rest of the command line will be specified in arguments.

## Arguments

These are the command line arguments for the application. Using the Mozilla Firefox example above, the arguments would be `/S /PreventRebootRequired=true`.

For MSI applications, this will include `/i` and the full-path to the MSI file plus any additional command line parameters (e.g. `/i "%FFUAppsRoot%\Win32\Google Chrome\Google Chrome_134.0.6998.178_Machine_X64_wix_en-US.msi" /quiet /norestart`)

## Source

This is an optional parameter. This is the local source to the content. It is used by the Copy Apps button to copy from the source location to the `$AppsPath\Win32\<Name>` folder. If you don't use the **Copy Apps** button, then you must put the conent in the `$AppsPath` folder manually.

## Additional Exit Codes

This is an optional parameter. Enter a comma-separated list of additional success exit codes if necessary.

## Ignore all non-zero exit codes

If checked, any non-zero exit code will be considered a success.

## Save UserAppList.json

When you're done adding your apps, you must save the `UserAppList.json` file to your `$AppsPath` folder. If you click **Copy Apps**, the `UserAppList.json` file is also saved. The `UserAppList.json` is used by the FFU Builder Orchestrator in the VM to know what to install and when based on the priority of the application.

Below is the `UserAppList.json` of Chrome and Firefox using the example above.

```json
[
  {
    "Priority": 1,
    "Name": "Google Chrome",
    "CommandLine": "msiexec",
    "Arguments": "/i \"%FFUAppsRoot%\\Win32\\Google Chrome\\Google Chrome_134.0.6998.178_Machine_X64_wix_en-US.msi\" /quiet /norestart",
    "Source": "C:\\temp\\source\\Google Chrome",
    "AdditionalExitCodes": "",
    "IgnoreNonZeroExitCodes": false
  },
  {
    "Priority": 2,
    "Name": "Mozilla Firefox",
    "CommandLine": "%FFUAppsRoot%\\Win32\\Mozilla Firefox\\Mozilla Firefox_136.0.3_Machine_X64_exe_en-US.exe",
    "Arguments": "/S /PreventRebootRequired=true",
    "Source": "C:\\temp\\source\\Mozilla Firefox",
    "AdditionalExitCodes": "",
    "IgnoreNonZeroExitCodes": false
  }
]
```

## Import UserAppList.json

You can import a saved `UserAppList.json`

## Edit Application

When you select a single application you can select the **Edit Application** button. This allows you to edit the application information and update the application.

## Copy Apps

If the application source is provided, click **Copy Apps** to copy the application content to the `$AppsPath\Win32` folder (e.g. `C:\FFUDevelopment\Apps\Win32\<Name>`). Network shares are supported. When clicking **Copy Apps** the `UserAppList.json` file is automatically created.

## Remove Selected

Removes the selected applications from the list view. Click **Save UserAppList.json** to save the application list.

## Clear List

The **Clear List** button will clear the list view of what’s currently in it. It will not clear the `UserAppList.json` file if it exists.

{% include page_nav.html %}
