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
AppMutex=UtifySingleInstance

; Close the running app before copying files
CloseApplications=yes
CloseApplicationsFilter=*.exe
RestartApplications=no

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
function FindPreviousUninstaller(var UninstallString: String): Boolean;
begin
  Result :=
    RegQueryStringValue(
      HKCU,
      'Software\Microsoft\Windows\CurrentVersion\Uninstall\{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}_is1',
      'UninstallString',
      UninstallString) or
    RegQueryStringValue(
      HKLM,
      'Software\Microsoft\Windows\CurrentVersion\Uninstall\{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}_is1',
      'UninstallString',
      UninstallString) or
    RegQueryStringValue(
      HKLM,
      'Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}_is1',
      'UninstallString',
      UninstallString);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  UninstallString: String;
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

    if FindPreviousUninstaller(UninstallString) then begin
      Exec(
        RemoveQuotes(UninstallString),
        '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART',
        '',
        SW_HIDE,
        ewWaitUntilTerminated,
        ResultCode);
    end;
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
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall

[UninstallDelete]
Type: filesandordirs; Name: "{app}"
