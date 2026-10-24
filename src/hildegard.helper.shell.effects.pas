unit hildegard.helper.shell.effects;
{ What a builtin command reads and writes, from its expanded arguments.

  The gate asks about effects, not programs: a granted file:read (or
  file:write) scope covers every command whose effect falls inside it, and an
  effect outside the grant is still asked. AKnown = False means the command's
  effects cannot be named (tool/mcp/unknown), so the caller falls back to a
  command-level ask.

  Positional, not heuristic: each command's own syntax says which arguments are
  files (grep's first operand is a pattern, cp's second is the destination).
  Nothing here touches the filesystem. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes;

procedure ComputeEffects(const AName: string; const AArgs: TStringArray;
  out AReads, AWrites: TStringArray; out AKnown: Boolean);

implementation

function IsOption(const AArg: string): Boolean;
begin
  Result := (AArg <> '') and (AArg[1] = '-') and (AArg <> '-');
end;

{ /dev/null is a sink that holds nothing and a source that yields nothing. Asking
  the operator to approve a write to it is pure noise, and naming it as a read
  claims we looked at a file that does not exist. It is dropped from both sides.

  Deliberately ONLY /dev/null: /dev/zero, /dev/random and /dev/std* are not
  equivalents, and a blanket /dev/ exemption would cover block devices. }
function IsNullSink(const AArg: string): Boolean;
begin
  Result := (AArg = '/dev/null') or (AArg = '-/dev/null');
end;

procedure Add(var AList: TStringArray; const AValue: string);
begin
  if AValue = '' then
    Exit;
  if IsNullSink(AValue) then
    Exit;
  SetLength(AList, Length(AList) + 1);
  AList[High(AList)] := AValue;
end;

{ Options whose VALUE is a separate argument, per command. Getting this wrong is
  how a regular expression gets asked about as if it were a directory: with
  `grep -A 1 pat file`, a table that did not know `-A` takes a value consumed
  only `-A`, leaving `1` as the pattern and `pat` as a path.

  Attached forms (`-A1`, `-k2`, `-t:`) need no entry - the value is inside the
  same argument and IsOption still sees an option. }
function OptionTakesValue(const AName, AOpt: string): Boolean;
begin
  Result := False;
  if AName = 'grep' then
    { -A/-B/-C context, -m max-count, -e pattern, -f file-of-patterns. }
    Result := (AOpt = '-A') or (AOpt = '-B') or (AOpt = '-C') or
      (AOpt = '-m') or (AOpt = '-e') or (AOpt = '-f')
  else if AName = 'rg' then
    Result := (AOpt = '-g') or (AOpt = '--glob') or (AOpt = '-e') or
      (AOpt = '-f') or (AOpt = '-A') or (AOpt = '-B') or (AOpt = '-C') or
      (AOpt = '-m') or (AOpt = '-t') or (AOpt = '--type')
  else if AName = 'sort' then
    Result := (AOpt = '-k') or (AOpt = '-t') or (AOpt = '-o') or
      (AOpt = '-S')
  else if AName = 'cut' then
    Result := (AOpt = '-d') or (AOpt = '-f') or (AOpt = '-c') or
      (AOpt = '-b')
  else if AName = 'awk' then
    Result := (AOpt = '-v') or (AOpt = '-F')
  else if AName = 'sed' then
    Result := (AOpt = '-e') or (AOpt = '-f')
  else if AName = 'head' then
    Result := (AOpt = '-n') or (AOpt = '-c')
  else if AName = 'tail' then
    Result := (AOpt = '-n') or (AOpt = '-c')
  else if AName = 'jq' then
    Result := (AOpt = '--arg') or (AOpt = '--argjson') or (AOpt = '--slurpfile')
      or (AOpt = '--rawfile')
  else if AName = 'uniq' then
    Result := (AOpt = '-f') or (AOpt = '-s') or (AOpt = '-w');
end;

{ Skip options from AStart, consuming the value of any that takes one.
  Returns the index of the first non-option argument. }
function SkipOptions(const AName: string; const AArgs: TStringArray;
  AStart: Integer): Integer;
var
  I: Integer;
begin
  I := AStart;
  while (I <= High(AArgs)) and IsOption(AArgs[I]) do
  begin
    if OptionTakesValue(AName, AArgs[I]) then
      Inc(I, 2)
    else
      Inc(I);
  end;
  Result := I;
end;

{ Copy the arguments from AStart on, skipping options (and their values where
  the command takes them) and the lone '-' (stdin). }
procedure AddFiles(var AList: TStringArray; const AName: string;
  const AArgs: TStringArray; AStart: Integer);
var
  I: Integer;
begin
  I := AStart;
  while I <= High(AArgs) do
  begin
    if AArgs[I] = '-' then
      Inc(I)
    else if IsOption(AArgs[I]) then
    begin
      if OptionTakesValue(AName, AArgs[I]) then
        Inc(I, 2)
      else
        Inc(I);
    end
    else
    begin
      Add(AList, AArgs[I]);
      Inc(I);
    end;
  end;
end;

procedure ComputeEffects(const AName: string; const AArgs: TStringArray;
  out AReads, AWrites: TStringArray; out AKnown: Boolean);
var
  I, N: Integer;
  InPlace: Boolean;
  HasPattern: Boolean;

  function NextNonOption(AFrom: Integer): Integer;
  var
    K: Integer;
  begin
    K := AFrom;
    while (K <= High(AArgs)) and IsOption(AArgs[K]) do
      Inc(K);
    Result := K;
  end;

begin
  AReads := nil;
  AWrites := nil;
  AKnown := True;

  if (AName = 'echo') or (AName = 'printf') or (AName = 'true') or
    (AName = 'false') or (AName = 'basename') or (AName = 'dirname') or
    (AName = 'expr') then
    Exit;

  if (AName = 'cat') or (AName = 'wc') or (AName = 'od') or
     (AName = 'sha256sum') or (AName = 'md5sum') or (AName = 'strings') or
     (AName = 'base64') or (AName = 'yq') then
  begin
    AddFiles(AReads, AName, AArgs, 0);
    Exit;
  end;

  if (AName = 'head') or (AName = 'tail') then
  begin
    { -n/-c take a separate value; the bare numeric form (-5) is an option with
      none. SkipOptions knows both from the table, so no local loop is needed. }
    I := SkipOptions(AName, AArgs, 0);
    AddFiles(AReads, AName, AArgs, I);
    Exit;
  end;

  if AName = 'grep' then
  begin
    { Flags, then the pattern, then the files. The option/value table decides
      which flags consume the next argument, so a separate value (-A 1) is never
      mistaken for the pattern and the pattern is never asked as a file. }
    I := SkipOptions(AName, AArgs, 0);
    { With -e or -f the pattern comes from the option, so there is no positional
      pattern to skip - treating the first file as one would drop a real read. }
    HasPattern := False;
    for N := 0 to I - 1 do
      if (AArgs[N] = '-e') or (AArgs[N] = '-f') or
         (Copy(AArgs[N], 1, 2) = '-e') or (Copy(AArgs[N], 1, 2) = '-f') or
         (Copy(AArgs[N], 1, 2) = '--') then
        HasPattern := True;
    if (not HasPattern) and (I <= High(AArgs)) then
      Inc(I);   // the positional pattern
    AddFiles(AReads, AName, AArgs, I);
    Exit;
  end;

  if AName = 'rg' then
  begin
    I := 0;
    while I <= High(AArgs) do
    begin
      if (AArgs[I] = '-g') or (AArgs[I] = '--glob') then
        Inc(I, 2)
      else if (AArgs[I] = '--hidden') or (AArgs[I] = '--no-ignore') then
        Inc(I)
      else if IsOption(AArgs[I]) then
        Inc(I)
      else
        Break;
    end;
    if I <= High(AArgs) then
      Inc(I);   // the pattern
    if I > High(AArgs) then
      Add(AReads, '.')   // no path: the working directory
    else
      AddFiles(AReads, AName, AArgs, I);
    Exit;
  end;

  if AName = 'sed' then
  begin
    I := 0;
    N := 0;   // scripts given with -e
    InPlace := False;
    while I <= High(AArgs) do
    begin
      if AArgs[I] = '-e' then
      begin
        Inc(N);
        Inc(I, 2);
      end
      else if (Length(AArgs[I]) > 2) and (Copy(AArgs[I], 1, 2) = '-e') then
      begin
        Inc(N);
        Inc(I);
      end
      else if AArgs[I] = '-n' then
        Inc(I)
      else if (AArgs[I] = '-E') or (AArgs[I] = '-r') then
        Inc(I)
      else if Copy(AArgs[I], 1, 2) = '-i' then
      begin
        InPlace := True;
        Inc(I);
      end
      else
        Break;
    end;
    if N = 0 then
      Inc(I);   // the script
    if InPlace then
      AddFiles(AWrites, AName, AArgs, I)
    else
      AddFiles(AReads, AName, AArgs, I);
    Exit;
  end;

  if AName = 'awk' then
  begin
    { -F and -v take values; the program follows the options. }
    I := SkipOptions(AName, AArgs, 0);
    if I <= High(AArgs) then
      Inc(I);   // the program
    AddFiles(AReads, AName, AArgs, I);
    Exit;
  end;

  if AName = 'jq' then
  begin
    I := SkipOptions(AName, AArgs, 0);
    if I <= High(AArgs) then
      Inc(I);   // the filter
    AddFiles(AReads, AName, AArgs, I);
    Exit;
  end;

  if AName = 'sort' then
  begin
    { AddFiles skips options AND their separate values, so `sort -k 2 f` reads
      f rather than 2. No pre-loop is needed for the read side.

      But -o names a file to WRITE, and skipping it as "an option with a value"
      swallowed the path entirely: the gate never saw the write. It is scanned
      separately here. }
    for I := 0 to High(AArgs) do
      if AArgs[I] = '-o' then
      begin
        if I < High(AArgs) then
          Add(AWrites, AArgs[I + 1]);
      end
      else if (Length(AArgs[I]) > 2) and (Copy(AArgs[I], 1, 2) = '-o') then
        { The attached form -oout.txt. }
        Add(AWrites, Copy(AArgs[I], 3, MaxInt));
    AddFiles(AReads, AName, AArgs, 0);
    Exit;
  end;

  if AName = 'uniq' then
  begin
    AddFiles(AReads, AName, AArgs, 0);
    Exit;
  end;

  if AName = 'cut' then
  begin
    I := SkipOptions(AName, AArgs, 0);
    AddFiles(AReads, AName, AArgs, I);
    Exit;
  end;

  if AName = 'tr' then
    Exit;   // stdin/stdout only

  if AName = 'ls' then
  begin
    I := SkipOptions(AName, AArgs, 0);
    if I > High(AArgs) then
      Add(AReads, '.')
    else
      AddFiles(AReads, AName, AArgs, I);
    Exit;
  end;

  if AName = 'find' then
  begin
    I := 0;
    while (I <= High(AArgs)) and (not IsOption(AArgs[I])) do
    begin
      Add(AReads, AArgs[I]);
      Inc(I);
    end;
    if Length(AReads) = 0 then
      Add(AReads, '.');
    Exit;
  end;

  if (AName = 'test') or (AName = '[') then
  begin
    { Only file tests name a path; string and numeric tests do not. }
    I := 0;
    while I <= High(AArgs) do
    begin
      if (AArgs[I] = '-e') or (AArgs[I] = '-f') or (AArgs[I] = '-d') or
        (AArgs[I] = '-s') or (AArgs[I] = '-r') or (AArgs[I] = '-w') or
        (AArgs[I] = '-x') then
      begin
        if I < High(AArgs) then
          Add(AReads, AArgs[I + 1]);
        Inc(I, 2);
      end
      else
        Inc(I);
    end;
    Exit;
  end;

  if AName = 'tee' then
  begin
    I := 0;
    if (I <= High(AArgs)) and (AArgs[I] = '-a') then
      Inc(I);
    AddFiles(AWrites, AName, AArgs, I);
    Exit;
  end;

  if AName = 'rm' then
  begin
    I := 0;
    while (I <= High(AArgs)) and IsOption(AArgs[I]) do
      Inc(I);
    AddFiles(AWrites, AName, AArgs, I);
    Exit;
  end;

  if AName = 'mv' then
  begin
    I := 0;
    while (I <= High(AArgs)) and IsOption(AArgs[I]) do
      Inc(I);
    AddFiles(AWrites, AName, AArgs, I);
    Exit;
  end;

  if AName = 'cp' then
  begin
    I := 0;
    while (I <= High(AArgs)) and IsOption(AArgs[I]) do
      Inc(I);
    if I <= High(AArgs) then
      Add(AReads, AArgs[I]);
    Inc(I);
    AddFiles(AWrites, AName, AArgs, I);
    Exit;
  end;

  if (AName = 'mkdir') or (AName = 'touch') or (AName = 'rmdir') then
  begin
    I := 0;
    while (I <= High(AArgs)) and IsOption(AArgs[I]) do
      Inc(I);
    AddFiles(AWrites, AName, AArgs, I);
    Exit;
  end;

  { tool/mcp and anything else: effects are not ours to name. }
  AKnown := False;
end;

end.
