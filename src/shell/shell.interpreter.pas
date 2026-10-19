unit shell.interpreter;
{ Execute a shell.ast.TScript.

  The interpreter owns the language: control flow, pipelines, redirection
  wiring, word expansion, the environment, the cwd, functions, and the limits.
  The consumer owns the capabilities: every registered command passes its gate
  first, and every filesystem effect (redirects, glob listing, cd validation)
  goes through IShellFileSystem.

  The library never spawns a process, never evaluates code, and never touches
  the host filesystem. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, shell.types, shell.ast, shell.fs, shell.registry;

type
  TShellTargetKind = (tkOut, tkErr, tkFile);

  TShellTarget = record
    Kind: TShellTargetKind;
    Path: string;
    Append: Boolean;
  end;

  TShell = class
  private
    FRegistry: TShellRegistry;
    FFs: IShellFileSystem;
    FGate: TShellGate;
    FLimits: TShellLimits;
    FEnv: TShellEnv;
    FOwnsEnv: Boolean;
    FCwd: string;
    FPositional: TStringArray;
    FFunctions: TStringList;    // name -> TCommand (references, not owned)
    FLocalNames: TStringList;   // locals recorded by the current function call
    FLocalOld: TStringList;
    FLocalHad: array of Boolean;
    FCommandCount: Integer;
    FStartMs: Int64;
    FDepth: Integer;
    FLastStatus: Integer;
    FExitRequested: Boolean;
    FReturnRequested: Boolean;
    FReturnStatus: Integer;
    FRunStatus: Integer;
    FAbortMessage: string;
    function CheckLimits: Boolean;
    procedure Abort(const AMsg: string);
    function ExecCommandInner(const AC: TCommand;
      const AStdin: string): TShellResult;
    function ExecStatement(const ASt: TStatement): TShellResult;
    function ExecAndOr(const AA: TAndOr): TShellResult;
    function ExecPipeline(const AP: TPipeline): TShellResult;
    function ExecSimple(const AC: TCommand; const AStdin: string): TShellResult;
    function ExecIf(const AC: TCommand): TShellResult;
    function ExecFor(const AC: TCommand): TShellResult;
    function ExecWhile(const AC: TCommand; AUntil: Boolean): TShellResult;
    function ExecCase(const AC: TCommand): TShellResult;
    function ExecSubshell(const ASt: TStatement): TShellResult;
    function ExecFunction(const ABody: TCommand; const AArgs: TStringArray;
      const AStdin: string): TShellResult;
    function ExecBuiltin(const AName: string; const AArgs: TStringArray;
      out AHandled: Boolean): TShellResult;
    function ExpandWordFields(const AW: TWord): TStringArray;
    function ExpandWordSingle(const AW: TWord): string;
    function ExpandGlob(const APattern: string): TStringArray;
    function ExpandHereDoc(const ABody: string): string;
    function SpecialValue(const AName: string): string;
    function LocalMark: Integer;
    procedure RestoreLocals(AMark: Integer);
    procedure SaveLocal(const AName: string);
  public
    constructor Create(ARegistry: TShellRegistry; AFs: IShellFileSystem;
      const AInitialCwd: string; AGate: TShellGate;
      const ALimits: TShellLimits; AEnv: TShellEnv = nil);
    destructor Destroy; override;
    function ExecCommand(const AC: TCommand; const AStdin: string): TShellResult;
    { Execute a parsed script. Output and error are the accumulated streams;
      the result is the script's exit status. }
    function Run(const AScript: TScript; out AOutput, AError: string): Integer;
    { Parse and run; a parse error is status 2 and nothing is executed. }
    function RunSource(const ASource: string;
      out AOutput, AError: string): Integer;
    property ExitStatus: Integer read FRunStatus;
    property Cwd: string read FCwd;
  end;

{ Glob matching for case patterns and FS globs: *, ?, and [...] classes with
  ranges and ! / ^ negation. Case-sensitive; no regex. }
function MatchGlob(const APattern, AName: string): Boolean;

implementation

uses
  shell.parser;

function JoinPath(const ADir, AName: string): string;
begin
  if ADir = '' then
    Result := AName
  else if ADir = '/' then
    Result := '/' + AName
  else
    Result := ADir + '/' + AName;
end;

function HasGlobChars(const S: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to Length(S) do
    if (S[I] = '*') or (S[I] = '?') or (S[I] = '[') then
      Exit(True);
end;

function MatchGlob(const APattern, AName: string): Boolean;
  function MatchAt(const P, N: string; PI, NI: Integer): Boolean;

    function MatchClass(const P: string; var PI: Integer; C: Char): Boolean;
    var
      Neg, Matched: Boolean;
      Lo, Hi: Char;
    begin
      Inc(PI);   // past the opening bracket
      Neg := False;
      if (PI <= Length(P)) and ((P[PI] = '!') or (P[PI] = '^')) then
      begin
        Neg := True;
        Inc(PI);
      end;
      Matched := False;
      if (PI <= Length(P)) and (P[PI] = ']') then
      begin
        Matched := C = ']';
        Inc(PI);
      end;
      while (PI <= Length(P)) and (P[PI] <> ']') do
      begin
        Lo := P[PI];
        if (PI + 2 <= Length(P)) and (P[PI + 1] = '-') and (P[PI + 2] <> ']') then
        begin
          Hi := P[PI + 2];
          if (C >= Lo) and (C <= Hi) then
            Matched := True;
          Inc(PI, 3);
        end
        else
        begin
          if C = Lo then
            Matched := True;
          Inc(PI);
        end;
      end;
      if (PI <= Length(P)) and (P[PI] = ']') then
        Inc(PI);
      if Neg then
        Result := not Matched
      else
        Result := Matched;
    end;

  begin
    while True do
    begin
      if PI > Length(P) then
        Exit(NI > Length(N));
      case P[PI] of
        '*':
          begin
            while (PI <= Length(P)) and (P[PI] = '*') do
              Inc(PI);
            if PI > Length(P) then
              Exit(True);
            while NI <= Length(N) do
            begin
              if MatchAt(P, N, PI, NI) then
                Exit(True);
              Inc(NI);
            end;
            Exit(False);
          end;
        '?':
          begin
            if NI > Length(N) then
              Exit(False);
            Inc(PI);
            Inc(NI);
          end;
        '[':
          begin
            if NI > Length(N) then
              Exit(False);
            if not MatchClass(P, PI, N[NI]) then
              Exit(False);
            Inc(NI);
          end;
        '\':
          begin
            Inc(PI);
            if PI > Length(P) then
              Exit(False);
            if (NI > Length(N)) or (N[NI] <> P[PI]) then
              Exit(False);
            Inc(PI);
            Inc(NI);
          end;
      else
        if (NI > Length(N)) or (N[NI] <> P[PI]) then
          Exit(False);
        Inc(PI);
        Inc(NI);
      end;
    end;
  end;

begin
  Result := MatchAt(APattern, AName, 1, 1);
end;

constructor TShell.Create(ARegistry: TShellRegistry; AFs: IShellFileSystem;
  const AInitialCwd: string; AGate: TShellGate; const ALimits: TShellLimits;
  AEnv: TShellEnv);
var
  D: TShellLimits;
begin
  inherited Create;
  FRegistry := ARegistry;
  FFs := AFs;
  FCwd := AInitialCwd;
  FGate := AGate;
  D := DefaultShellLimits;
  FLimits := ALimits;
  if FLimits.MaxCommands <= 0 then
    FLimits.MaxCommands := D.MaxCommands;
  if FLimits.MaxLoopIterations <= 0 then
    FLimits.MaxLoopIterations := D.MaxLoopIterations;
  if FLimits.MaxCallDepth <= 0 then
    FLimits.MaxCallDepth := D.MaxCallDepth;
  if FLimits.MaxOutputBytes <= 0 then
    FLimits.MaxOutputBytes := D.MaxOutputBytes;
  if FLimits.MaxExecutionTimeMs <= 0 then
    FLimits.MaxExecutionTimeMs := D.MaxExecutionTimeMs;
  if AEnv = nil then
  begin
    FEnv := TShellEnv.Create;
    FOwnsEnv := True;
  end
  else
    FEnv := AEnv;
  FFunctions := TStringList.Create;
  FFunctions.CaseSensitive := True;
  FLocalNames := TStringList.Create;
  FLocalOld := TStringList.Create;
end;

destructor TShell.Destroy;
begin
  FLocalOld.Free;
  FLocalNames.Free;
  FFunctions.Free;
  if FOwnsEnv then
    FEnv.Free;
  inherited Destroy;
end;

procedure TShell.Abort(const AMsg: string);
begin
  if FAbortMessage = '' then
    FAbortMessage := AMsg;
  FExitRequested := True;
end;

function TShell.CheckLimits: Boolean;
begin
  Result := False;
  if FExitRequested or FReturnRequested then
    Exit;
  if (FLimits.MaxExecutionTimeMs > 0) and
    (Int64(GetTickCount64) - FStartMs > FLimits.MaxExecutionTimeMs) then
  begin
    Abort('execution time limit exceeded');
    Exit;
  end;
  Result := True;
end;

function TShell.ExecCommand(const AC: TCommand; const AStdin: string): TShellResult;
begin
  Result := Default(TShellResult);
  Inc(FCommandCount);
  if FCommandCount > FLimits.MaxCommands then
  begin
    Abort('command limit exceeded');
    Result.ExitCode := 2;
    Exit;
  end;
  if not CheckLimits then
  begin
    Result.ExitCode := 2;
    Exit;
  end;
  Result := ExecCommandInner(AC, AStdin);
  FLastStatus := Result.ExitCode;
end;

function TShell.ExecCommandInner(const AC: TCommand;
  const AStdin: string): TShellResult;
begin
  Result := Default(TShellResult);
  case AC.Kind of
    ckSimple: Result := ExecSimple(AC, AStdin);
    ckGroup: Result := ExecStatement(AC.Group);
    ckSubshell: Result := ExecSubshell(AC.Group);
    ckIf: Result := ExecIf(AC);
    ckFor: Result := ExecFor(AC);
    ckWhile: Result := ExecWhile(AC, False);
    ckUntil: Result := ExecWhile(AC, True);
    ckCase: Result := ExecCase(AC);
    ckFunction:
      begin
        FFunctions.AddObject(AC.FuncName, TObject(AC.FuncBody));
        Result := ShellResultOk('');
      end;
  end;
end;

function TShell.ExecStatement(const ASt: TStatement): TShellResult;
var
  I, Status: Integer;
  R: TShellResult;
begin
  Result := Default(TShellResult);
  Status := 0;
  if ASt = nil then
  begin
    Result.ExitCode := 0;
    Exit;
  end;
  for I := 0 to High(ASt.Items) do
  begin
    if FExitRequested or FReturnRequested then
      Break;
    if not CheckLimits then
      Break;
    R := ExecAndOr(ASt.Items[I]);
    Result.Stdout := Result.Stdout + R.Stdout;
    Result.Stderr := Result.Stderr + R.Stderr;
    Status := R.ExitCode;
  end;
  Result.ExitCode := Status;
end;

function TShell.ExecAndOr(const AA: TAndOr): TShellResult;
var
  I: Integer;
  R: TShellResult;
  DoRun: Boolean;
begin
  Result := Default(TShellResult);
  DoRun := True;
  for I := 0 to High(AA.Pipelines) do
  begin
    if I > 0 then
    begin
      if AA.Ops[I - 1] = aoAnd then
        DoRun := Result.ExitCode = 0
      else
        DoRun := Result.ExitCode <> 0;
    end;
    if not DoRun then
      Break;
    if FExitRequested or FReturnRequested then
      Break;
    R := ExecPipeline(AA.Pipelines[I]);
    Result.Stdout := Result.Stdout + R.Stdout;
    Result.Stderr := Result.Stderr + R.Stderr;
    Result.ExitCode := R.ExitCode;
  end;
end;

function TShell.ExecPipeline(const AP: TPipeline): TShellResult;
var
  I: Integer;
  Inp: string;
  R, Last: TShellResult;
  AllErr: string;
begin
  Result := Default(TShellResult);
  Inp := '';
  AllErr := '';
  Last := Default(TShellResult);
  for I := 0 to High(AP.Commands) do
  begin
    if FExitRequested or FReturnRequested then
      Break;
    R := ExecCommand(AP.Commands[I], Inp);
    AllErr := AllErr + R.Stderr;
    Inp := R.Stdout;
    Last := R;
  end;
  Result.Stdout := Last.Stdout;
  Result.Stderr := AllErr;
  Result.ExitCode := Last.ExitCode;
  if AP.Negated then
  begin
    if Result.ExitCode = 0 then
      Result.ExitCode := 1
    else
      Result.ExitCode := 0;
  end;
end;

function TShell.ExpandWordSingle(const AW: TWord): string;
var
  I: Integer;
  P: TWordPart;
begin
  Result := '';
  for I := 0 to High(AW.Parts) do
  begin
    P := AW.Parts[I];
    case P.Kind of
      wpLiteral, wpGlob: Result := Result + P.Text;
      wpVariable: Result := Result + FEnv.Get(P.Text);
      wpSpecial: Result := Result + SpecialValue(P.Text);
      wpTilde: Result := Result + FEnv.Get('HOME');
    end;
  end;
end;

function TShell.SpecialValue(const AName: string): string;
var
  I: Integer;
begin
  if AName = '?' then
    Exit(IntToStr(FLastStatus))
  else if AName = '#' then
    Exit(IntToStr(Length(FPositional)))
  else if (AName = '@') or (AName = '*') then
  begin
    Result := '';
    for I := 0 to High(FPositional) do
    begin
      if Result <> '' then
        Result := Result + ' ';
      Result := Result + FPositional[I];
    end;
    Exit;
  end;
  if (Length(AName) = 1) and (AName[1] >= '0') and (AName[1] <= '9') then
  begin
    I := Ord(AName[1]) - Ord('0');
    if I = 0 then
      Exit(FCwd);
    if I <= Length(FPositional) then
      Exit(FPositional[I - 1]);
    Exit('');
  end;
  Result := '';
end;

function TShell.ExpandHereDoc(const ABody: string): string;
var
  I, J: Integer;
  Name: string;
  C: Char;
begin
  { A simple here-doc expansion: NAME variables, the special parameters, and
    a backslash escape. }
  Result := '';
  I := 1;
  while I <= Length(ABody) do
  begin
    C := ABody[I];
    if C = '\' then
    begin
      if (I < Length(ABody)) and (ABody[I + 1] in ['$', '\', '`']) then
      begin
        Result := Result + ABody[I + 1];
        Inc(I, 2);
      end
      else
      begin
        Result := Result + C;
        Inc(I);
      end;
    end
    else if C = '$' then
    begin
      if (I < Length(ABody)) and (ABody[I + 1] = '{') then
      begin
        J := I + 2;
        while (J <= Length(ABody)) and (ABody[J] <> '}') do
          Inc(J);
        Name := Copy(ABody, I + 2, J - I - 2);
        Result := Result + FEnv.Get(Name);
        I := J + 1;
      end
      else if (I < Length(ABody)) and
        (ABody[I + 1] in ['?', '#', '@', '*']) then
      begin
        Result := Result + SpecialValue(ABody[I + 1]);
        Inc(I, 2);
      end
      else if (I < Length(ABody)) and
        ((ABody[I + 1] = '_') or (ABody[I + 1] in ['A'..'Z', 'a'..'z'])) then
      begin
        J := I + 1;
        while (J <= Length(ABody)) and
          ((ABody[J] = '_') or (ABody[J] in ['A'..'Z', 'a'..'z', '0'..'9'])) do
          Inc(J);
        Name := Copy(ABody, I + 1, J - I - 1);
        Result := Result + FEnv.Get(Name);
        I := J;
      end
      else
      begin
        Result := Result + C;
        Inc(I);
      end;
    end
    else
    begin
      Result := Result + C;
      Inc(I);
    end;
  end;
end;

function TShell.ExpandGlob(const APattern: string): TStringArray;
var
  Segs: TStringArray;
  I, J, K: Integer;
  Base: string;
  IsAbs: Boolean;
  Candidates, Next, Entries: TStringArray;
  Seg, E: string;

  function SplitSegments(const S: string): TStringArray;
  var
    P, Q, N: Integer;
  begin
    Result := nil;
    N := 0;
    P := 1;
    while P <= Length(S) + 1 do
    begin
      Q := P;
      while (Q <= Length(S)) and (S[Q] <> '/') do
        Inc(Q);
      SetLength(Result, N + 1);
      Result[N] := Copy(S, P, Q - P);
      Inc(N);
      P := Q + 1;
    end;
  end;

  procedure AppendCandidate(var AList: TStringArray; const AValue: string);
  var
    N: Integer;
  begin
    N := Length(AList);
    SetLength(AList, N + 1);
    AList[N] := AValue;
  end;

begin
  Result := nil;
  IsAbs := (APattern <> '') and (APattern[1] = '/');
  Segs := SplitSegments(APattern);
  Candidates := nil;
  AppendCandidate(Candidates, '');
  for K := 0 to High(Segs) do
  begin
    Seg := Segs[K];
    if Seg = '' then
    begin
      if (K = 0) and IsAbs then
        for J := 0 to High(Candidates) do
          Candidates[J] := '/';
      Continue;
    end;
    Next := nil;
    if not HasGlobChars(Seg) then
      for J := 0 to High(Candidates) do
        AppendCandidate(Next, JoinPath(Candidates[J], Seg))
    else
      for J := 0 to High(Candidates) do
      begin
        Base := Candidates[J];
        if not FFs.ListDir(FFs.Resolve(FCwd, Base), Entries, E) then
          Continue;
        for I := 0 to High(Entries) do
          if MatchGlob(Seg, Entries[I]) then
            AppendCandidate(Next, JoinPath(Base, Entries[I]));
      end;
    Candidates := Next;
    if Length(Candidates) = 0 then
      Break;
  end;
  if Length(Candidates) = 0 then
  begin
    SetLength(Result, 1);
    Result[0] := APattern;
    Exit;
  end;
  Result := Candidates;
  { Insertion sort, like the shell's default order. }
  for I := 1 to High(Result) do
  begin
    E := Result[I];
    J := I - 1;
    while (J >= 0) and (Result[J] > E) do
    begin
      Result[J + 1] := Result[J];
      Dec(J);
    end;
    Result[J + 1] := E;
  end;
end;

function TShell.ExpandWordFields(const AW: TWord): TStringArray;
var
  P: TWordPart;
  S: string;
  I, N, K: Integer;
  Parts: TStringArray;
  AnyQuoted, HasGlob: Boolean;
begin
  Result := nil;
  if Length(AW.Parts) = 0 then
    Exit;
  { The simple field model: a word that is exactly one unquoted variable or $@
    splits; anything else is one field. }
  if (Length(AW.Parts) = 1) and (AW.Parts[0].Kind = wpVariable) and
    (not AW.Parts[0].Quoted) then
  begin
    S := FEnv.Get(AW.Parts[0].Text);
    K := 0;
    N := 1;
    while N <= Length(S) do
    begin
      while (N <= Length(S)) and (S[N] in [' ', #9, #10]) do
        Inc(N);
      I := N;
      while (I <= Length(S)) and (not (S[I] in [' ', #9, #10])) do
        Inc(I);
      if I > N then
      begin
        SetLength(Result, K + 1);
        Result[K] := Copy(S, N, I - N);
        Inc(K);
      end;
      N := I;
    end;
    Exit;
  end;
  if (Length(AW.Parts) = 1) and (AW.Parts[0].Kind = wpSpecial) and
    (AW.Parts[0].Text = '@') then
  begin
    SetLength(Result, Length(FPositional));
    for I := 0 to High(FPositional) do
      Result[I] := FPositional[I];
    Exit;
  end;
  AnyQuoted := False;
  HasGlob := False;
  for I := 0 to High(AW.Parts) do
  begin
    P := AW.Parts[I];
    if P.Quoted then
      AnyQuoted := True;
    if (P.Kind = wpGlob) and (not P.Quoted) then
      HasGlob := True;
  end;
  if HasGlob and (not AnyQuoted) then
  begin
    Parts := ExpandGlob(ExpandWordSingle(AW));
    Exit(Parts);
  end;
  SetLength(Result, 1);
  Result[0] := ExpandWordSingle(AW);
end;

function TShell.LocalMark: Integer;
begin
  Result := FLocalNames.Count;
end;

procedure TShell.SaveLocal(const AName: string);
var
  I: Integer;
begin
  for I := 0 to FLocalNames.Count - 1 do
    if FLocalNames[I] = AName then
      Exit;   // already saved in this call
  FLocalNames.Add(AName);
  I := Length(FLocalHad);
  SetLength(FLocalHad, I + 1);
  FLocalHad[I] := FEnv.Has(AName);
  FLocalOld.Add(FEnv.Get(AName));
end;

procedure TShell.RestoreLocals(AMark: Integer);
var
  I: Integer;
begin
  for I := FLocalNames.Count - 1 downto AMark do
    if FLocalHad[I] then
      FEnv.SetValue(FLocalNames[I], FLocalOld[I])
    else
      FEnv.Unset(FLocalNames[I]);
  while FLocalNames.Count > AMark do
    FLocalNames.Delete(FLocalNames.Count - 1);
  while FLocalOld.Count > AMark do
    FLocalOld.Delete(FLocalOld.Count - 1);
  SetLength(FLocalHad, AMark);
end;

function TShell.ExecBuiltin(const AName: string; const AArgs: TStringArray;
  out AHandled: Boolean): TShellResult;
var
  I, N, P: Integer;
  S, Name, Value, Target: string;
  Kind: TShellFileKind;
  E: string;
  Parts: TStringArray;
begin
  AHandled := True;
  Result := Default(TShellResult);
  if AName = 'pwd' then
    Exit(ShellResultOk(FCwd + #10));
  if AName = 'cd' then
  begin
    if Length(AArgs) = 0 then
      Target := FEnv.Get('HOME')
    else
      Target := AArgs[0];
    if Target = '' then
      Exit(ShellResultErr('cd: HOME not set' + #10, 1));
    S := FFs.Resolve(FCwd, Target);
    if not FFs.Stat(S, Kind, E) then
      Exit(ShellResultErr('cd: ' + Target + ': ' + E + #10, 1));
    if Kind <> sfkDirectory then
      Exit(ShellResultErr('cd: ' + Target + ': not a directory' + #10, 1));
    FCwd := S;
    Exit(ShellResultOk(''));
  end;
  if AName = 'export' then
  begin
    for I := 0 to High(AArgs) do
    begin
      P := Pos('=', AArgs[I]);
      if P > 1 then
        FEnv.SetValue(Copy(AArgs[I], 1, P - 1), Copy(AArgs[I], P + 1, MaxInt))
      else if AArgs[I] <> '' then
        FEnv.SetValue(AArgs[I], FEnv.Get(AArgs[I]));
    end;
    Exit(ShellResultOk(''));
  end;
  if AName = 'unset' then
  begin
    for I := 0 to High(AArgs) do
      if AArgs[I] <> '' then
        FEnv.Unset(AArgs[I]);
    Exit(ShellResultOk(''));
  end;
  if AName = 'local' then
  begin
    for I := 0 to High(AArgs) do
    begin
      P := Pos('=', AArgs[I]);
      if P > 1 then
      begin
        Name := Copy(AArgs[I], 1, P - 1);
        Value := Copy(AArgs[I], P + 1, MaxInt);
        SaveLocal(Name);
        FEnv.SetValue(Name, Value);
      end
      else if AArgs[I] <> '' then
      begin
        SaveLocal(AArgs[I]);
        FEnv.SetValue(AArgs[I], '');
      end;
    end;
    Exit(ShellResultOk(''));
  end;
  if AName = 'shift' then
  begin
    N := 1;
    if Length(AArgs) > 0 then
      N := StrToIntDef(AArgs[0], 1);
    if N > Length(FPositional) then
      N := Length(FPositional);
    FPositional := Copy(FPositional, N, Length(FPositional) - N);
    Exit(ShellResultOk(''));
  end;
  if AName = 'return' then
  begin
    FReturnStatus := 0;
    if Length(AArgs) > 0 then
      FReturnStatus := StrToIntDef(AArgs[0], 0);
    FReturnRequested := True;
    Exit(ShellResultOk(''));
  end;
  if AName = 'exit' then
  begin
    FRunStatus := 0;
    if Length(AArgs) > 0 then
      FRunStatus := StrToIntDef(AArgs[0], 0);
    FExitRequested := True;
    Exit(ShellResultOk(''));
  end;
  if AName = 'set' then
  begin
    if (Length(AArgs) > 0) and (AArgs[0] = '--') then
    begin
      SetLength(Parts, Length(AArgs) - 1);
      for I := 1 to High(AArgs) do
        Parts[I - 1] := AArgs[I];
      FPositional := Parts;
    end;
    Exit(ShellResultOk(''));
  end;
  AHandled := False;
end;

function TShell.ExecSimple(const AC: TCommand; const AStdin: string): TShellResult;
var
  Fields, Args: TStringArray;
  I, Nb, N: Integer;
  W: TWord;
  EffStdin: string;
  OutT, ErrT, NewT: TShellTarget;
  R: TShellResult;
  Name: string;
  Handled: Boolean;
  Handler: TShellHandler;
  Call: TShellCall;
  CallEnv: TShellEnv;
  FnIdx: Integer;
  Path, Data, E, WErr: string;

  procedure ApplyAssignments(AEnv: TShellEnv);
  var
    K: Integer;
  begin
    for K := 0 to High(AC.Assignments) do
      AEnv.SetValue(AC.Assignments[K].Name,
        ExpandWordSingle(AC.Assignments[K].Value));
  end;

  procedure AddField(var AList: TStringArray; const AValue: string);
  var
    K: Integer;
  begin
    K := Length(AList);
    SetLength(AList, K + 1);
    AList[K] := AValue;
  end;

begin
  Result := Default(TShellResult);
  Fields := nil;
  for I := 0 to High(AC.Words) do
  begin
    W := AC.Words[I];
    Args := ExpandWordFields(W);
    for Nb := 0 to High(Args) do
      AddField(Fields, Args[Nb]);
  end;

  { A bare assignment persists; otherwise the prefix scopes to the command. }
  if (Length(Fields) = 0) and (Length(AC.Assignments) > 0) then
  begin
    ApplyAssignments(FEnv);
    Exit(ShellResultOk(''));
  end;

  { Redirects, left to right. }
  EffStdin := AStdin;
  OutT.Kind := tkOut;
  OutT.Path := '';
  OutT.Append := False;
  ErrT.Kind := tkErr;
  ErrT.Path := '';
  ErrT.Append := False;
  for I := 0 to High(AC.Redirects) do
  begin
    case AC.Redirects[I].Op of
      roRead, roReadWrite:
        begin
          Path := FFs.Resolve(FCwd, ExpandWordSingle(AC.Redirects[I].Target));
          if not FFs.ReadFile(Path, Data, E) then
            Exit(ShellResultErr('cannot read ' +
              ExpandWordSingle(AC.Redirects[I].Target) + ': ' + E + #10, 1));
          EffStdin := Data;
        end;
      roHeredoc, roHeredocStrip:
        if AC.Redirects[I].ExpandBody then
          EffStdin := ExpandHereDoc(AC.Redirects[I].Body)
        else
          EffStdin := AC.Redirects[I].Body;
      roHereString:
        EffStdin := ExpandWordSingle(AC.Redirects[I].Target) + #10;
      roDupOut:
        begin
          N := StrToIntDef(ExpandWordSingle(AC.Redirects[I].Target), 1);
          if (AC.Redirects[I].FD = 2) and (N = 1) then
            ErrT := OutT
          else if ((AC.Redirects[I].FD = 1) or (AC.Redirects[I].FD = -1)) and
            (N = 2) then
            OutT := ErrT;
        end;
      roDupIn:
        ;   // v1: <& is accepted and ignored
      roWrite, roAppend:
        begin
          Path := FFs.Resolve(FCwd, ExpandWordSingle(AC.Redirects[I].Target));
          NewT.Kind := tkFile;
          NewT.Path := Path;
          NewT.Append := AC.Redirects[I].Op = roAppend;
          if AC.Redirects[I].FD = 2 then
            ErrT := NewT
          else
            OutT := NewT;
        end;
    end;
  end;

  if Length(Fields) > 0 then
  begin
    Name := Fields[0];
    SetLength(Args, Length(Fields) - 1);
    for I := 1 to High(Fields) do
      Args[I - 1] := Fields[I];

    { Functions first, then builtins, then the registry. }
    FnIdx := FFunctions.IndexOf(Name);
    if FnIdx >= 0 then
      Result := ExecFunction(TCommand(FFunctions.Objects[FnIdx]), Args, EffStdin)
    else
    begin
      Result := ExecBuiltin(Name, Args, Handled);
      if not Handled then
      begin
        if not FRegistry.Resolve(Name, Handler) then
          Result := ShellResultErr(Name + ': command not found' + #10, 127)
        else
        begin
          CallEnv := FEnv.Clone;
          try
            ApplyAssignments(CallEnv);
            Call := Default(TShellCall);
            Call.Name := Name;
            Call.Args := Args;
            Call.Stdin := EffStdin;
            Call.Cwd := FCwd;
            Call.Env := CallEnv;
            if Assigned(FGate) and (not FGate(Call)) then
              Result := ShellResultErr(Name + ': denied' + #10, 126)
            else
              Result := Handler(Call);
          finally
            CallEnv.Free;
          end;
        end;
      end;
    end;
  end;

  { Apply the output targets. }
  Data := Result.Stdout;
  E := Result.Stderr;
  if OutT.Kind = tkErr then
  begin
    E := E + Data;
    Data := '';
  end;
  if ErrT.Kind = tkOut then
  begin
    Data := Data + E;
    E := '';
  end;
  if (OutT.Kind = tkFile) and (ErrT.Kind = tkFile) and
    (OutT.Path = ErrT.Path) then
  begin
    if not FFs.WriteFile(OutT.Path, Data + E,
      OutT.Append or ErrT.Append, WErr) then
    begin
      E := 'cannot write ' + OutT.Path + ': ' + WErr + #10;
      Result.ExitCode := 1;
      Data := '';
    end
    else
    begin
      Data := '';
      E := '';
    end;
  end
  else
  begin
    if OutT.Kind = tkFile then
    begin
      if not FFs.WriteFile(OutT.Path, Data, OutT.Append, WErr) then
      begin
        E := E + 'cannot write ' + OutT.Path + ': ' + WErr + #10;
        Result.ExitCode := 1;
      end;
      Data := '';
    end;
    if ErrT.Kind = tkFile then
    begin
      if not FFs.WriteFile(ErrT.Path, E, ErrT.Append, WErr) then
      begin
        Data := Data + 'cannot write ' + ErrT.Path + ': ' + WErr + #10;
        Result.ExitCode := 1;
      end;
      E := '';
    end;
  end;
  Result.Stdout := Data;
  Result.Stderr := E;
end;

function TShell.ExecIf(const AC: TCommand): TShellResult;
var
  I: Integer;
begin
  Result := Default(TShellResult);
  for I := 0 to High(AC.Clauses) do
  begin
    Result := ExecStatement(AC.Clauses[I].Condition);
    if FExitRequested or FReturnRequested then
      Exit;
    if Result.ExitCode = 0 then
      Exit(ExecStatement(AC.Clauses[I].Body));
  end;
  if AC.ElseBody <> nil then
    Exit(ExecStatement(AC.ElseBody));
  Result.ExitCode := 0;
end;

function TShell.ExecFor(const AC: TCommand): TShellResult;
var
  Items: TStringArray;
  I, J, Iter: Integer;
  Args: TStringArray;
  R: TShellResult;
begin
  Result := Default(TShellResult);
  Items := nil;
  for I := 0 to High(AC.ForItems) do
  begin
    Args := ExpandWordFields(AC.ForItems[I]);
    for J := 0 to High(Args) do
    begin
      SetLength(Items, Length(Items) + 1);
      Items[High(Items)] := Args[J];
    end;
  end;
  if Length(Items) = 0 then
  begin
    SetLength(Items, Length(FPositional));
    for I := 0 to High(FPositional) do
      Items[I] := FPositional[I];
  end;
  Iter := 0;
  for I := 0 to High(Items) do
  begin
    Inc(Iter);
    if Iter > FLimits.MaxLoopIterations then
    begin
      Abort('loop iteration limit exceeded');
      Result.ExitCode := 2;
      Exit;
    end;
    if not CheckLimits then
      Exit;
    FEnv.SetValue(AC.ForVar, Items[I]);
    R := ExecStatement(AC.LoopBody);
    Result.Stdout := Result.Stdout + R.Stdout;
    Result.Stderr := Result.Stderr + R.Stderr;
    Result.ExitCode := R.ExitCode;
    if FExitRequested or FReturnRequested then
      Break;
  end;
end;

function TShell.ExecWhile(const AC: TCommand; AUntil: Boolean): TShellResult;
var
  R, B: TShellResult;
  Iter: Integer;
  KeepGoing: Boolean;
begin
  Result := Default(TShellResult);
  Iter := 0;
  while True do
  begin
    Inc(Iter);
    if Iter > FLimits.MaxLoopIterations then
    begin
      Abort('loop iteration limit exceeded');
      Result.ExitCode := 2;
      Exit;
    end;
    if not CheckLimits then
      Exit;
    R := ExecStatement(AC.Condition);
    if FExitRequested or FReturnRequested then
      Exit;
    if AUntil then
      KeepGoing := R.ExitCode <> 0
    else
      KeepGoing := R.ExitCode = 0;
    if not KeepGoing then
      Break;
    B := ExecStatement(AC.LoopBody);
    Result.Stdout := Result.Stdout + B.Stdout;
    Result.Stderr := Result.Stderr + B.Stderr;
    Result.ExitCode := B.ExitCode;
    if FExitRequested or FReturnRequested then
      Break;
  end;
end;

function TShell.ExecCase(const AC: TCommand): TShellResult;
var
  Word: string;
  I, J: Integer;
  Pattern: string;
  Matched, AnyQuoted: Boolean;
begin
  Result := Default(TShellResult);
  Word := ExpandWordSingle(AC.CaseWord);
  for I := 0 to High(AC.CaseItems) do
  begin
    for J := 0 to High(AC.CaseItems[I].Patterns) do
    begin
      Pattern := ExpandWordSingle(AC.CaseItems[I].Patterns[J]);
      AnyQuoted := False;
      if Length(AC.CaseItems[I].Patterns[J].Parts) = 1 then
        AnyQuoted := AC.CaseItems[I].Patterns[J].Parts[0].Quoted;
      if AnyQuoted then
        Matched := Pattern = Word
      else
        Matched := MatchGlob(Pattern, Word);
      if Matched then
      begin
        Result := ExecStatement(AC.CaseItems[I].Body);
        Exit;
      end;
    end;
  end;
  Result.ExitCode := 0;
end;

function TShell.ExecSubshell(const ASt: TStatement): TShellResult;
var
  SavedEnv, SubEnv: TShellEnv;
  SavedCwd: string;
  SavedPos: TStringArray;
  SavedFns: Integer;
begin
  Result := Default(TShellResult);
  SavedEnv := FEnv;
  SubEnv := SavedEnv.Clone;
  SavedCwd := FCwd;
  SavedPos := FPositional;
  SavedFns := FFunctions.Count;
  try
    FEnv := SubEnv;
    try
      Result := ExecStatement(ASt);
    finally
      FEnv := SavedEnv;
    end;
  finally
    SubEnv.Free;
    FCwd := SavedCwd;
    FPositional := SavedPos;
    while FFunctions.Count > SavedFns do
      FFunctions.Delete(FFunctions.Count - 1);
  end;
end;

function TShell.ExecFunction(const ABody: TCommand; const AArgs: TStringArray;
  const AStdin: string): TShellResult;
var
  SavedPos: TStringArray;
  Mark: Integer;
begin
  Result := Default(TShellResult);
  Inc(FDepth);
  if FDepth > FLimits.MaxCallDepth then
  begin
    Dec(FDepth);
    Abort('call depth limit exceeded');
    Result.ExitCode := 2;
    Exit;
  end;
  SavedPos := FPositional;
  FPositional := AArgs;
  Mark := LocalMark;
  FReturnRequested := False;
  FReturnStatus := 0;
  try
    Result := ExecCommand(ABody, AStdin);
  finally
    RestoreLocals(Mark);
    FPositional := SavedPos;
    Dec(FDepth);
  end;
  if FReturnRequested then
  begin
    Result.ExitCode := FReturnStatus;
    FReturnRequested := False;
  end;
end;

function TShell.Run(const AScript: TScript; out AOutput, AError: string): Integer;
var
  R: TShellResult;
begin
  AOutput := '';
  AError := '';
  FStartMs := Int64(GetTickCount64);
  FCommandCount := 0;
  FDepth := 0;
  FLastStatus := 0;
  FExitRequested := False;
  FReturnRequested := False;
  FReturnStatus := 0;
  FRunStatus := 0;
  FAbortMessage := '';
  R := ExecStatement(AScript.Root);
  AOutput := R.Stdout;
  AError := R.Stderr;
  if FAbortMessage <> '' then
  begin
    AError := AError + FAbortMessage + #10;
    FRunStatus := 2;
  end
  else if FExitRequested then
    FRunStatus := FRunStatus
  else
    FRunStatus := R.ExitCode;
  Result := FRunStatus;
  if (FLimits.MaxOutputBytes > 0) and (Length(AOutput) > FLimits.MaxOutputBytes) then
    AOutput := Copy(AOutput, 1, FLimits.MaxOutputBytes) +
      #10 + '[output truncated]' + #10;
  if (FLimits.MaxOutputBytes > 0) and (Length(AError) > FLimits.MaxOutputBytes) then
    AError := Copy(AError, 1, FLimits.MaxOutputBytes) +
      #10 + '[output truncated]' + #10;
end;

function TShell.RunSource(const ASource: string;
  out AOutput, AError: string): Integer;
var
  S: TScript;
  E: TShellParseError;
begin
  AOutput := '';
  AError := '';
  if not ParseShellScript(ASource, S, E) then
  begin
    AError := 'parse error at ' + IntToStr(E.Line) + ':' + IntToStr(E.Column) +
      ': ' + E.Message + #10;
    Result := 2;
    Exit;
  end;
  try
    Result := Run(S, AOutput, AError);
  finally
    S.Free;
  end;
end;

end.
