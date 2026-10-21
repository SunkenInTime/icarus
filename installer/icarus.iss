#ifndef MyAppName
  #define MyAppName "Icarus"
#endif

#ifndef MyAppPublisher
  #define MyAppPublisher "Dara A"
#endif

#ifndef MyAppExeName
  #define MyAppExeName "icarus.exe"
#endif

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

#ifndef MySourceDir
  #define MySourceDir "E:\\Projects\\icarus\\build\\windows\\x64\\runner\\Release"
#endif

#ifndef MyOutputDir
  #define MyOutputDir "E:\\Projects\\icarus\\build\\installer"
#endif

#ifndef MyRepoRoot
  #define MyRepoRoot "E:\\Projects\\icarus"
#endif

[Setup]
AppId={{2B31297D-A96B-4B4B-8899-0098A865B4BA}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\{#MyAppName}
UsePreviousAppDir=yes
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
ChangesAssociations=yes
OutputDir={#MyOutputDir}
OutputBaseFilename=icarus-setup-{#MyAppVersion}
Compression=lzma
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
SetupIconFile={#MyRepoRoot}\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"
Name: "registerica"; Description: "Associate .ica strategy files with {#MyAppName}"; Flags: checkedonce
Name: "registervrf"; Description: "Open Valorant replays (.vrf) with {#MyAppName}"; Flags: checkedonce

[Files]
Source: "{#MySourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
; Per-user file association to keep install and updates non-admin.
Root: HKCU; Subkey: "Software\\Classes\\.ica"; ValueType: string; ValueName: ""; ValueData: "Icarus.Strategy"; Flags: uninsdeletevalue; Tasks: registerica
Root: HKCU; Subkey: "Software\\Classes\\Icarus.Strategy"; ValueType: string; ValueName: ""; ValueData: "Icarus Strategy File"; Flags: uninsdeletekey; Tasks: registerica
Root: HKCU; Subkey: "Software\\Classes\\Icarus.Strategy\\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#MyAppExeName},0"; Tasks: registerica
Root: HKCU; Subkey: "Software\\Classes\\Icarus.Strategy\\shell\\open\\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""; Tasks: registerica
; Valorant registers nothing for its replays, but .vrf is also Ventrilo's
; recording format. Icarus always joins the Open with list, and becomes the
; default only when no other program is. Uninstall clears the default only
; while it is still Icarus's (CurUninstallStepChanged, before the entries
; below are undone), then removes .vrf's keys only if nothing else is left
; in them. Uninstall undoes entries last to first, so OpenWithProgids goes
; before .vrf.
Root: HKCU; Subkey: "Software\\Classes\\.vrf"; Flags: uninsdeletekeyifempty; Tasks: registervrf
Root: HKCU; Subkey: "Software\\Classes\\.vrf\\OpenWithProgids"; ValueType: string; ValueName: "Icarus.Replay"; ValueData: ""; Flags: uninsdeletevalue uninsdeletekeyifempty; Tasks: registervrf
Root: HKCU; Subkey: "Software\\Classes\\.vrf"; ValueType: string; ValueName: ""; ValueData: "Icarus.Replay"; Tasks: registervrf; Check: VrfHasNoOtherDefault
Root: HKCU; Subkey: "Software\\Classes\\Icarus.Replay"; ValueType: string; ValueName: ""; ValueData: "Valorant Replay"; Flags: uninsdeletekey; Tasks: registervrf
Root: HKCU; Subkey: "Software\\Classes\\Icarus.Replay\\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#MyAppExeName},0"; Tasks: registervrf
Root: HKCU; Subkey: "Software\\Classes\\Icarus.Replay\\shell\\open\\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""; Tasks: registervrf

[Run]
; postinstall puts a ticked "Launch Icarus" checkbox on the final page; without
; it, Setup launches the app unasked. skipifsilent keeps silent installs closed.
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

[Code]
// True when .vrf has no default program, or Icarus already is it.
function VrfHasNoOtherDefault: Boolean;
var
  Handler: String;
begin
  Result := (not RegQueryStringValue(HKCR, '.vrf', '', Handler)) or
    (Handler = '') or (Handler = 'Icarus.Replay');
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Handler: String;
begin
  if (CurUninstallStep = usUninstall) and
    RegQueryStringValue(HKCU, 'Software\Classes\.vrf', '', Handler) and
    (Handler = 'Icarus.Replay') then
    RegDeleteValue(HKCU, 'Software\Classes\.vrf', '');
end;

