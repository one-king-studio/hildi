unit shell.fs;
{ The filesystem seam. The interpreter never touches the host filesystem: every
  redirect, glob listing, here-string and `cd` validation goes through the
  consumer's implementation, which is where the path bound lives. }

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  TShellFileKind = (sfkMissing, sfkFile, sfkDirectory, sfkOther);

  { What a command needs to describe a path (`ls -l`): the permission bits and
    timestamps a platform can supply, 0 where it cannot. }
  TShellFileInfo = record
    Kind: TShellFileKind;
    Size: Int64;
    Mode: LongWord;
    Modified: Int64;
  end;

  IShellFileSystem = interface
    ['{7E2C4B1A-5D3F-4A8B-9C6E-1F0D2A3B4C5D}']
    { Resolve APath against ACwd to an absolute path; it need not exist. }
    function Resolve(const ACwd, APath: string): string;
    function ReadFile(const APath: string; out AData, AError: string): Boolean;
    function WriteFile(const APath, AData: string; AAppend: Boolean;
      out AError: string): Boolean;
    { The entry names of the directory at APath (absolute), sorted. }
    function ListDir(const APath: string; out AEntries: TStringArray;
      out AError: string): Boolean;
    function Stat(const APath: string; out AKind: TShellFileKind;
      out AError: string): Boolean;
    { Kind + size + mode + mtime. A platform without mode bits reports 0. }
    function Info(const APath: string; out AInfo: TShellFileInfo;
      out AError: string): Boolean;
    { Create a symbolic link at ALinkPath whose text is ATarget. The target is
      stored verbatim and need NOT exist or resolve inside the workspace: reading
      the link is what confinement governs, not writing its text.
      False + AError where the platform cannot create links (Windows without
      privilege), rather than silently creating a copy of the target. }
    function Symlink(const ATarget, ALinkPath: string;
      out AError: string): Boolean;
    { The raw text of a symbolic link. False when APath is not a link, so a
      missing link and a broken one are distinguishable. }
    function ReadLink(const APath: string; out ATarget, AError: string): Boolean;
    { Set permission bits. A no-op returning True on a platform without mode
      bits (Windows), because a script that chmods should not fail there. }
    function SetMode(const APath: string; AMode: LongWord;
      out AError: string): Boolean;
  end;

implementation

end.
