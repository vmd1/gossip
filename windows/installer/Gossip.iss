; Gossip for Windows installer (Inno Setup 6).
;
; Build it from the published app folder:
;   iscc /DAppVersion=2.6 /DArch=arm64 /DSourceDir=..\Gossip.Windows\bin\publish /DOutputDir=out Gossip.iss
; Arch is x64 or arm64 and must match the folder (the app and gossip_ffi.dll are architecture specific).
;
; The installer needs administrator rights because it adds a Windows Firewall rule. Without it the first launch shows
; the "allow this app on public and private networks" prompt, and Gossip cannot be found by your phone until you click Allow.

#ifndef AppVersion
  #define AppVersion "0.0"
#endif
#ifndef Arch
  #define Arch "x64"
#endif
#ifndef SourceDir
  #define SourceDir "..\Gossip.Windows\bin\publish"
#endif
#ifndef OutputDir
  #define OutputDir "out"
#endif

[Setup]
AppId={{B3F7C2A1-6D54-4E0B-9C1D-7A5E2F8B4C10}
AppName=Gossip
AppVersion={#AppVersion}
AppPublisher=vmd1
AppPublisherURL=https://gossip.vmd1.dev/
AppSupportURL=https://github.com/vmd1/gossip/issues
DefaultDirName={autopf}\Gossip
DefaultGroupName=Gossip
DisableProgramGroupPage=yes
PrivilegesRequired=admin
OutputDir={#OutputDir}
OutputBaseFilename=Gossip-Windows-{#Arch}-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\Gossip.Windows.exe
CloseApplications=yes
RestartApplications=no
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif

[Tasks]
Name: "startup"; Description: "Start Gossip when I sign in"; GroupDescription: "Options:"
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Options:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Gossip"; Filename: "{app}\Gossip.Windows.exe"
Name: "{autodesktop}\Gossip"; Filename: "{app}\Gossip.Windows.exe"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Gossip"; \
  ValueData: """{app}\Gossip.Windows.exe"" --minimized"; Tasks: startup; Flags: uninsdeletevalue

[Run]
; Allow Gossip through the firewall on every network profile: phones find this PC with mDNS and connect to it over TCP.
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Gossip"" program=""{app}\Gossip.Windows.exe"""; Flags: runhidden; StatusMsg: "Updating the firewall rule..."
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""Gossip"" dir=in action=allow program=""{app}\Gossip.Windows.exe"" enable=yes profile=any"; Flags: runhidden; StatusMsg: "Allowing Gossip through the firewall..."
Filename: "{app}\Gossip.Windows.exe"; Description: "Start Gossip"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Gossip"" program=""{app}\Gossip.Windows.exe"""; Flags: runhidden; RunOnceId: "RemoveGossipFirewallRule"

[UninstallDelete]
Type: filesandordirs; Name: "{localappdata}\Temp\Gossip"
