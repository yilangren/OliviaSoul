#define AppVersion GetEnv("OLIVIA_SOUL_VERSION")
#define StageDir GetEnv("OLIVIA_SOUL_STAGE")
#define OutputDir GetEnv("OLIVIA_SOUL_OUTPUT")

[Setup]
AppId={{70CB4313-7339-4EF0-87ED-E9D45A67B952}
AppName=Olivia Soul
AppVersion={#AppVersion}
AppPublisher=Olivia Soul
DefaultDirName={autopf}\OliviaSoul
DefaultGroupName=Olivia Soul
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=OliviaSoul-{#AppVersion}-Setup
SetupIconFile={#StageDir}\app-v9.ico
UninstallDisplayIcon={app}\app-v9.ico
Compression=lzma2/max
SolidCompression=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
AppMutex=Local\OliviaSoul.SingleInstance

[InstallDelete]
Type: filesandordirs; Name: "{app}\resources\workspace-template\.cursor\rules"
Type: files; Name: "{app}\resources\workspace-template\harness\00-strict-precheck.md"
Type: files; Name: "{app}\resources\workspace-template\harness\00-脚本算术.md"
Type: files; Name: "{app}\resources\workspace-template\harness\02-读信感.md"
Type: files; Name: "{app}\resources\workspace-template\harness\02-历史检索.md"
Type: files; Name: "{app}\resources\workspace-template\harness\02-账本校正.md"
Type: files; Name: "{app}\resources\workspace-template\harness\06-实时回信.md"
Type: files; Name: "{app}\resources\workspace-template\.cursor\skills\fit-letters\scripts\history-retrieval.ps1"

[Dirs]
Name: "{commonappdata}\OliviaSoul"; Permissions: users-modify

[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Olivia Soul"; Filename: "{app}\OliviaSoul.exe"; IconFilename: "{app}\app-v9.ico"; AppUserModelID: "OliviaSoul.Desktop.9"
Name: "{autodesktop}\Olivia Soul"; Filename: "{app}\OliviaSoul.exe"; IconFilename: "{app}\app-v9.ico"; AppUserModelID: "OliviaSoul.Desktop.9"

[Run]
Filename: "{app}\OliviaSoul.exe"; Description: "启动 Olivia Soul"; Flags: nowait postinstall skipifsilent

[Code]
function IsDriveRoot(Path: String): Boolean;
var
  Drive: String;
  Normalized: String;
begin
  Drive := ExtractFileDrive(Path);
  Normalized := RemoveBackslashUnlessRoot(Path);
  Result := (Drive <> '') and (CompareText(Normalized, AddBackslash(Drive)) = 0);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Selected: String;
begin
  Result := True;
  if CurPageID <> wpSelectDir then
    exit;
  Selected := WizardDirValue;
  if Length(Selected) = 1 then
    Selected := Selected + ':\'
  else if (Length(Selected) = 2) and (Selected[2] = ':') then
    Selected := Selected + '\';
  if IsDriveRoot(Selected) then
    WizardForm.DirEdit.Text := AddBackslash(Selected) + 'OliviaSoul';
end;
