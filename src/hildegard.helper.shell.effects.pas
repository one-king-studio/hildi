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

procedure Add(var AList: TStringArray; const AValue: string);
begin
  if AValue = '' then
    Exit;
  SetLength(AList, Length(AList) + 1);
  AList[High(AList)] := AValue;
end;

function IsOption(const AArg: string): Boolean;
begin
  Result := (AArg <> '') and (AArg[1] = '-') and (AArg <> '-');
end;

{ Copy the arguments from AStart on, skipping options (and their values where
  the command takes them) and the lone '-' (stdin). }
procedure AddFiles(var AList: TStringArray; const AArgs: TStringArray;
  AStart: Integer);
var
  I: Integer;
begin
  for I := AStart to High(AArgs) do
    if (AArgs[I] <> '-') and (not IsOption(AArgs[I])) then
      Add(AList, AArgs[I]);
end;

procedure ComputeEffects(const AName: string; const AArgs: TStringArray;
  out AReads, AWrites: TStringArray; out AKnown: Boolean);
var
  I, N: Integer;
  InPlace: Boolean;

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
    (AName = 'false') or (AName = 'basename') or (AName = 'dirname') then
    Exit;

  if (AName = 'cat') or (AName = 'wc') then
  begin
    AddFiles(AReads, AArgs, 0);
    Exit;
  end;

  if (AName = 'head') or (AName = 'tail') then
  begin
    I := 0;
    while I <= High(AArgs) do
    begin
      if AArgs[I] = '-n' then
        Inc(I, 2)
      else if IsOption(AArgs[I]) then
        Inc(I)
      else
        Break;
    end;
    AddFiles(AReads, AArgs, I);
    Exit;
  end;

  if AName = 'grep' then
  begin
    { Flags, then the pattern, then the files. }
    I := NextNonOption(0);
    if I <= High(AArgs) then
      Inc(I);
    AddFiles(AReads, AArgs, I);
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
      AddFiles(AReads, AArgs, I);
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
      AddFiles(AWrites, AArgs, I)
    else
      AddFiles(AReads, AArgs, I);
    Exit;
  end;

  if AName = 'awk' then
  begin
    I := 0;
    while I <= High(AArgs) do
    begin
      if AArgs[I] = '-F' then
        Inc(I, 2)
      else if (Length(AArgs[I]) > 2) and (Copy(AArgs[I], 1, 2) = '-F') then
        Inc(I)
      else
        Break;
    end;
    Inc(I);   // the program
    AddFiles(AReads, AArgs, I);
    Exit;
  end;

  if AName = 'jq' then
  begin
    I := 0;
    while (I <= High(AArgs)) and (IsOption(AArgs[I])) do
      Inc(I);
    Inc(I);   // the filter
    AddFiles(AReads, AArgs, I);
    Exit;
  end;

  if AName = 'sort' then
  begin
    I := 0;
    while (I <= High(AArgs)) and IsOption(AArgs[I]) do
      Inc(I);
    AddFiles(AReads, AArgs, I);
    Exit;
  end;

  if AName = 'uniq' then
  begin
    I := 0;
    while (I <= High(AArgs)) and IsOption(AArgs[I]) do
      Inc(I);
    AddFiles(AReads, AArgs, I);
    Exit;
  end;

  if AName = 'cut' then
  begin
    I := 0;
    while I <= High(AArgs) do
    begin
      if (AArgs[I] = '-d') or (AArgs[I] = '-f') or (AArgs[I] = '-c') then
        Inc(I, 2)
      else if IsOption(AArgs[I]) then
        Inc(I)
      else
        Break;
    end;
    AddFiles(AReads, AArgs, I);
    Exit;
  end;

  if AName = 'tr' then
    Exit;   // stdin/stdout only

  if AName = 'ls' then
  begin
    I := 0;
    while (I <= High(AArgs)) and IsOption(AArgs[I]) do
      Inc(I);
    if I > High(AArgs) then
      Add(AReads, '.')
    else
      AddFiles(AReads, AArgs, I);
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
    AddFiles(AWrites, AArgs, I);
    Exit;
  end;

  if AName = 'rm' then
  begin
    I := 0;
    while (I <= High(AArgs)) and IsOption(AArgs[I]) do
      Inc(I);
    AddFiles(AWrites, AArgs, I);
    Exit;
  end;

  if AName = 'mv' then
  begin
    I := 0;
    while (I <= High(AArgs)) and IsOption(AArgs[I]) do
      Inc(I);
    AddFiles(AWrites, AArgs, I);
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
    AddFiles(AWrites, AArgs, I);
    Exit;
  end;

  if (AName = 'mkdir') or (AName = 'touch') then
  begin
    I := 0;
    while (I <= High(AArgs)) and IsOption(AArgs[I]) do
      Inc(I);
    AddFiles(AWrites, AArgs, I);
    Exit;
  end;

  { tool/mcp and anything else: effects are not ours to name. }
  AKnown := False;
end;

end.
