; =============================================================================
; wmux for Windows -- Inno Setup 6 installer script
; =============================================================================
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
;     - %LOCALAPPDATA%\wmux              (config + cache)
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
;   wmux.exe                             (required)
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

#define AppName "wmux"
#define AppPublisher "wmux"
#define AppURL "https://github.com/Rey-ColonValero/wmux"
#define AppExeName "wmux.exe"

[Setup]
; Unique AppId for this community build's install/uninstall registration.
; Never reuse this GUID for a different product. The doubled '{' escapes
; the literal brace.
AppId={{B5D596AF-6D83-4ABD-A430-F4203FC1239F}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}/issues
AppUpdatesURL={#AppURL}/releases

; --- Per-user install -------------------------------------------------------
; PrivilegesRequired=lowest => non-administrative install mode: no UAC
; elevation, uninstall info under HKCU, and all {auto*} constants resolve
; to their per-user form.
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\wmux
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
; wmux win32 + WebView2 require Windows 10 or later.
MinVersion=10.0

; --- Output -----------------------------------------------------------------
OutputDir=output
OutputBaseFilename=wmux-windows-x64-{#AppVersion}-setup
SetupIconFile=ghostty.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

; --- Version resource -------------------------------------------------------
VersionInfoVersion={#AppVersionNumeric}
VersionInfoProductTextVersion={#AppVersion}
VersionInfoDescription=wmux terminal multiplexer for Windows

; --- Uninstall --------------------------------------------------------------
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExeName}

; This installer makes no environment changes whatsoever (see header).
ChangesEnvironment=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#StagingDir}\wmux.exe"; DestDir: "{app}"; Flags: ignoreversion
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
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Comment: "wmux terminal multiplexer"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

; NOTE: deliberately no [Registry] section (see environment rule in header)
; and no [UninstallDelete] section (user data in %LOCALAPPDATA%\wmux and
; WebView2 user-data folders must survive uninstall).

; =============================================================================
; WebView2 Runtime auto-install
; =============================================================================
; If the WebView2 Evergreen Runtime is not already installed, download and run
; the bootstrapper silently. The bootstrapper is ~1.8 MB and fetches the full
; runtime from Microsoft's CDN. Detection uses the well-known registry key
; that the runtime writes on install.
;
; Registry key checked (works for both per-machine and per-user installs on
; 64-bit Windows):
;   HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BEE-154A06EE57EE}
;   HKCU\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BEE-154A06EE57EE}
; The "pv" (product version) value is non-empty when installed.
; =============================================================================

[Code]
function IsWebView2Installed: Boolean;
var
  PV: String;
begin
  Result := False;
  { Check per-machine (64-bit registry view) }
  if RegQueryStringValue(HKLM, 'SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BEE-154A06EE57EE}', 'pv', PV) then
  begin
    if PV <> '' then
    begin
      Result := True;
      Exit;
    end;
  end;
  { Check per-machine (native view, covers 32-bit OS edge case) }
  if RegQueryStringValue(HKLM, 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BEE-154A06EE57EE}', 'pv', PV) then
  begin
    if PV <> '' then
    begin
      Result := True;
      Exit;
    end;
  end;
  { Check per-user install }
  if RegQueryStringValue(HKCU, 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BEE-154A06EE57EE}', 'pv', PV) then
  begin
    if PV <> '' then
      Result := True;
  end;
end;

procedure InstallWebView2IfNeeded;
var
  BootstrapperPath: String;
  ResultCode: Integer;
  DownloadOK: Boolean;
begin
  if IsWebView2Installed then
  begin
    Log('WebView2 Runtime is already installed; skipping download.');
    Exit;
  end;

  Log('WebView2 Runtime not detected; downloading bootstrapper...');
  BootstrapperPath := ExpandConstant('{tmp}\MicrosoftEdgeWebview2Setup.exe');

  { Download the Evergreen Bootstrapper from Microsoft's CDN }
  DownloadOK := False;
  try
    DownloadTemporaryFile(
      'https://go.microsoft.com/fwlink/p/?LinkId=2124703',
      'MicrosoftEdgeWebview2Setup.exe',
      '',
      nil);
    DownloadOK := True;
  except
    Log('Failed to download WebView2 bootstrapper: ' + GetExceptionMessage);
  end;

  if not DownloadOK then
  begin
    MsgBox('Could not download the WebView2 Runtime. ' +
           'wmux requires WebView2 to run. Please install it manually from ' +
           'https://developer.microsoft.com/en-us/microsoft-edge/webview2/',
           mbError, MB_OK);
    Exit;
  end;

  { Run the bootstrapper silently. /silent /install runs without UI. }
  if not Exec(BootstrapperPath, '/silent /install', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    Log('Failed to launch WebView2 bootstrapper.');
    MsgBox('Could not run the WebView2 Runtime installer. ' +
           'Please install WebView2 manually from ' +
           'https://developer.microsoft.com/en-us/microsoft-edge/webview2/',
           mbError, MB_OK);
  end
  else
  begin
    if ResultCode <> 0 then
      Log('WebView2 bootstrapper exited with code: ' + IntToStr(ResultCode))
    else
      Log('WebView2 Runtime installed successfully.');
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    InstallWebView2IfNeeded;
end;
