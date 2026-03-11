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
SetupIconFile=E:\Projects\icarus\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"
Name: "registerica"; Description: "Associate .ica strategy files with {#MyAppName}"; Flags: checkedonce

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

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

