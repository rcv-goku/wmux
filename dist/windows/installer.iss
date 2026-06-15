; =============================================================================
; Ghostty for Windows -- Inno Setup 6 installer script
; =============================================================================
;
; UNOFFICIAL BUILD NOTICE (branding rules):
;   This is an UNOFFICIAL community build of the Ghostty terminal emulator
;   for Windows. It is NOT affiliated with, endorsed by, or supported by
;   the Ghostty project or Mitchell Hashimoto. Do not report issues with
;   this build to the upstream Ghostty project.
;   Publisher string is intentionally "Ghostty Windows Community Build".
;
; ABSOLUTE RULE -- ENVIRONMENT VARIABLES:
;   This installer must NEVER read or modify the PATH environment variable,
;   and must never contain [Registry] entries that touch
;   HKCU\Environment / HKLM\...\Session Manager\Environment (or any other
;   environment values). A prior community installer destroyed users' PATH
;   by writing a truncated value back. Do NOT add an [Registry] section,
;   environment [Code], or ChangesEnvironment-triggered logic to this
;   script. If launch-from-shell convenience is ever wanted, ship a docs
;   note about per-user "App Paths" or manual setup instead -- never PATH.
;
; UNINSTALL / USER DATA:
;   The uninstaller removes ONLY files this installer copied into {app}.
;   User data is intentionally preserved on uninstall:
;     - %LOCALAPPDATA%\ghostty           (config + cache)
;     - WebView2 user-data folders       (created at runtime)
;   Do NOT add [UninstallDelete] entries for those locations.
;
; COMPILING:
;   Normally driven by dist\windows\release.ps1, which stages files and runs:
;     ISCC.exe /DAppVersion=<ver> /DAppVersionNumeric=<a.b.c.d> ^
;              /DStagingDir=<abs path to staged files> installer.iss
;   All /D defines are optional; sane defaults are below. Relative paths in
;   this script (SetupIconFile, OutputDir, default StagingDir) resolve
;   against the directory containing this .iss file.
;
;   Requires Inno Setup 6 (https://jrsoftware.org/isinfo.php).
;     winget install -e --id JRSoftware.InnoSetup
;
; STAGING LAYOUT expected in {#StagingDir}:
;   ghostty.exe                          (required)
;   WebView2Loader.dll                   (required; from Microsoft.Web.WebView2
;                                         NuGet package, build/native/x64 --
;                                         redistributable per the WebView2 SDK
;                                         license)
;   share\terminfo\ghostty.terminfo      (optional; resourcesDir() sentinel)
;   share\ghostty\themes\...             (optional)
;   share\ghostty\shell-integration\...  (optional)
;   LICENSE.txt                          (optional)
; =============================================================================

#ifndef AppVersion
  #define AppVersion "0.0.0-dev"
#endif
; Four-part numeric version for the Windows VERSIONINFO resource
; (AppVersion itself may be a git-describe string like "win-v1.1.0-4-gabc123").
#ifndef AppVersionNumeric
  #define AppVersionNumeric "0.0.0.0"
#endif
#ifndef StagingDir
  #define StagingDir "_staging"
#endif

#define AppName "Ghostty"
#define AppPublisher "Ghostty Windows Community Build"
#define AppURL "https://github.com/InsipidPoint/ghostty-windows"
#define AppExeName "ghostty.exe"

[Setup]
; Unique AppId for this community build's install/uninstall registration.
; Never reuse this GUID for a different product. The doubled '{' escapes
; the literal brace.
AppId={{B5D596AF-6D83-4ABD-A430-F4203FC1239F}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion} (community build)
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}/issues
AppUpdatesURL={#AppURL}/releases
; Shows in Apps & Features; reinforces the unofficial status.
AppComments=Unofficial community build. Not affiliated with the Ghostty project.

; --- Per-user install -------------------------------------------------------
; PrivilegesRequired=lowest => non-administrative install mode: no UAC
; elevation, uninstall info under HKCU, and all {auto*} constants resolve
; to their per-user form.
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\Ghostty
DisableProgramGroupPage=yes

; --- Architecture -----------------------------------------------------------
; x64compatible (Inno 6.3+) also matches Windows 11 ARM64 running x64
; emulation; fall back to the legacy "x64" identifier on older Inno 6.
#if VER >= EncodeVer(6,3,0)
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#else
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
#endif
; Ghostty win32 + WebView2 require Windows 10 or later.
MinVersion=10.0

; --- Output -----------------------------------------------------------------
OutputDir=output
OutputBaseFilename=ghostty-windows-x64-{#AppVersion}-setup
SetupIconFile=ghostty.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

; --- Version resource -------------------------------------------------------
VersionInfoVersion={#AppVersionNumeric}
VersionInfoProductTextVersion={#AppVersion}
VersionInfoDescription=Ghostty terminal emulator (unofficial Windows community build)

; --- Uninstall --------------------------------------------------------------
UninstallDisplayName={#AppName} (community build)
UninstallDisplayIcon={app}\{#AppExeName}

; This installer makes no environment changes whatsoever (see header).
ChangesEnvironment=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#StagingDir}\ghostty.exe"; DestDir: "{app}"; Flags: ignoreversion
; WebView2Loader.dll: from the Microsoft.Web.WebView2 NuGet package
; (build/native/x64). Redistribution is permitted by the WebView2 SDK license.
Source: "{#StagingDir}\WebView2Loader.dll"; DestDir: "{app}"; Flags: ignoreversion
; Resource tree (terminfo sentinel, themes, shell integration). Optional:
; skipifsourcedoesntexist lets a minimal staging (exe + dll only) compile.
Source: "{#StagingDir}\share\*"; DestDir: "{app}\share"; Flags: ignoreversion recursesubdirs createallsubdirs skipifsourcedoesntexist
Source: "{#StagingDir}\LICENSE.txt"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

[Icons]
; {autoprograms}/{autodesktop} resolve to the per-user Start Menu / Desktop
; because of PrivilegesRequired=lowest.
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Comment: "Ghostty terminal emulator (community build)"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

; NOTE: deliberately no [Registry] section (see environment rule in header)
; and no [UninstallDelete] section (user data in %LOCALAPPDATA%\ghostty and
; WebView2 user-data folders must survive uninstall).
