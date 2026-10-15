; installer/utify.iss
; Inno Setup script for Utify Windows installer.
;
; Compiles to a single Setup.exe that:
;   - Force-closes any running Utify so its files can be replaced
;   - Installs to %LocalAppData%\Utify by default (no admin rights needed)
;   - Creates a Start Menu shortcut
;   - Creates a Desktop shortcut (optional, user can uncheck)
;   - Registers an uninstaller in Add/Remove Programs
;   - Supports silent install: Setup.exe /SILENT /SUPPRESSMSGBOXES
;   - Relaunches Utify when done, including after a silent (in-app) update

#define MyAppName      "Utify"
#define MyAppPublisher "Rami Chaaben"
#define MyAppURL       "https://github.com/RamiChaaben8/Online_Music_Player"
#define MyAppExeName   "utify.exe"

; Version is injected by the workflow via /DMyAppVersion=x.y.z
#ifndef MyAppVersion
  #define MyAppVersion "1.6.0"
#endif

[Setup]
AppId={{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}/releases

; Install to user's local AppData — no UAC prompt needed
DefaultDirName={localappdata}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest

; AppMutex is deliberately NOT set.
; The in-app updater launches Setup while Utify may still be shutting down.
; With an AppMutex, Setup pops a modal "Utify is currently running" dialog
; that silently blocks an unattended update. Setup force-closes the app
; itself instead (see the taskkill in [Code] and CloseApplications above).

; Close the running app before copying files
CloseApplications=yes
CloseApplicationsFilter=*.exe
RestartApplications=no

; Always write an install log to %TEMP% ("Setup Log <date>.txt").
; Makes failed/silent updates diagnosable after the fact.
SetupLogging=yes

; Output
OutputDir={#SourcePath}\Output
OutputBaseFilename=utify-setup
Compression=lzma2/max
SolidCompression=yes

; Visuals
WizardStyle=modern
SetupIconFile={#SourcePath}\..\windows\runner\resources\app_icon.ico
MinVersion=10.0.17763

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Code]
// Force-close a running Utify so Setup can overwrite utify.exe and its DLLs.
// This runs at ssInstall, i.e. before any files are copied.
//
// NOTE: we deliberately do NOT run the previous version's uninstaller here.
// That used to be done for a "clean upgrade", but Exec(... ewWaitUntilTerminated)
// returns as soon as the uninstaller re-launches itself from %TEMP%, so the
// uninstaller kept deleting {app} *while* the new files were being copied,
// leaving broken installs. [InstallDelete] below already guarantees a clean
// directory, and Setup regenerates the uninstaller + Add/Remove Programs entry.
procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if CurStep = ssInstall then begin
    Exec(
      ExpandConstant('{cmd}'),
      '/C taskkill /F /IM utify.exe',
      '',
      SW_HIDE,
      ewWaitUntilTerminated,
      ResultCode);
  end;
end;

[InstallDelete]
Type: filesandordirs; Name: "{app}\*"

[Files]
Source: "{#SourcePath}\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}";           Filename: "{app}\{#MyAppExeName}"
Name: "{autoprograms}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}";             Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
; Silent / in-app update: always relaunch. There is no Finished page in
; silent mode, so the old "postinstall" entry never ran and the app stayed
; closed after updating.
Filename: "{app}\{#MyAppExeName}"; Flags: nowait skipifnotsilent
; Interactive install: offer a checkbox on the Finished page.
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}"
