; installer/utify.iss
; Inno Setup script for Utify Windows installer.
;
; Compiles to a single Setup.exe that:
;   - Silently uninstalls any existing Utify before installing (clean upgrade)
;   - Installs to %LocalAppData%\Utify by default (no admin rights needed)
;   - Creates a Start Menu shortcut
;   - Creates a Desktop shortcut (optional, user can uncheck)
;   - Registers an uninstaller in Add/Remove Programs
;   - Supports silent install: Setup.exe /VERYSILENT /SUPPRESSMSGBOXES

#define MyAppName      "Utify"
#define MyAppPublisher "Rami Chaaben"
#define MyAppURL       "https://github.com/RamiChaaben8/Online_Music_Player"
#define MyAppExeName   "utify.exe"

; Version is injected by the workflow via /DMyAppVersion=x.y.z
#ifndef MyAppVersion
  #define MyAppVersion "1.5.0"
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

; Close the running app before copying files
CloseApplications=yes
CloseApplicationsFilter=*.exe

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
// Silently uninstall the previous version before copying new files.
// This gives a clean upgrade: old DLLs/assets are removed first.
procedure CurStepChanged(CurStep: TSetupStep);
var
  UninstallString: String;
  ResultCode: Integer;
begin
  if CurStep = ssInstall then begin
    // Check HKCU first (user install), then HKLM (machine install)
    if RegQueryStringValue(HKCU,
        'Software\Microsoft\Windows\CurrentVersion\Uninstall\{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}_is1',
        'UninstallString', UninstallString) or
       RegQueryStringValue(HKLM,
        'Software\Microsoft\Windows\CurrentVersion\Uninstall\{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}_is1',
        'UninstallString', UninstallString) or
       RegQueryStringValue(HKLM,
        'Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}_is1',
        'UninstallString', UninstallString) then
    begin
      Exec(RemoveQuotes(UninstallString),
          '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART',
          '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    end;
  end;
end;

[Files]
Source: "{#SourcePath}\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}";           Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{commondesktop}\{#MyAppName}";   Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}"
