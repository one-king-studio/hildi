unit hildegard.helper.command.policy;
{ Pure command-line parser and policy classifier for the shell tool.

  A command line is split into simple-command segments at unquoted POSIX
  operators, each segment's executable and literal path-like arguments are
  extracted, and the whole command is classified against a policy as allow,
  ask, or deny.

  This is a guardrail, not a sandbox: only literal tokens are reasoned about.
  Variable expansion, command substitution, globs, `eval`, and nested
  interpreters are NOT resolved; such tokens are reported as unresolved rather
  than assumed safe. The POSIX syntax mode is implemented in v1; `ssCmd` is
  reserved for a future Windows profile. }

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  { Reserved for future profiles; v1 implements ssPosix only. }
  TShellSyntax = (ssPosix, ssCmd);

  { The operator that introduces a segment in the original command line. }
  TCommandOp = (coExec, coPipe, coAnd, coOr, coSeq, coBackground);

  { How a literal path token was written, before any shell expansion. }
  TPathKind = (pkRelative, pkAbsolute, pkHome, pkUnresolved);

  TCommandArgArray = array of string;

  TCommandRedirect = record
    Operator: string;        // '>', '>>', '<', '2>', '&>'
    Target: string;          // literal target token as written
    TargetKind: TPathKind;
  end;

  TCommandPath = record
    Text: string;            // literal token as written
    Kind: TPathKind;
    IsRedirect: Boolean;     // True when the path is a redirection target
  end;

  TCommandRedirectArray = array of TCommandRedirect;
  TCommandPathArray = array of TCommandPath;

  TCommandSegment = record
    Text: string;                  // reconstructed segment text
    Op: TCommandOp;                // operator that introduced the segment
    Executable: string;            // argv[0] token as written, '' if none
    Arguments: TCommandArgArray;   // argv[1..], quotes removed
    Redirects: TCommandRedirectArray;
    Paths: TCommandPathArray;      // path-like args + redirect targets
  end;

  TCommandSegmentArray = array of TCommandSegment;

  TCommandPlan = record
    Raw: string;
    Syntax: TShellSyntax;
    Segments: TCommandSegmentArray;
    ParseError: string;            // '' => fully parsed; else human-readable
  end;

  { Policy rules. A pattern is whitespace-separated words:
      - one word ('cat') matches the executable (token or basename), any args;
      - two or more ('cat /etc/os-release', 'git * main') match the executable
        and then the arguments, '*' matching any number of arguments and '?'/'*'
        matching within one argument.
    '*' and '?' are wildcards (case-sensitive). }
  TCommandPolicy = record
    Allow: TCommandArgArray;         // patterns that may run freely
    Deny: TCommandArgArray;          // patterns that never run
    AllowedRoots: TCommandArgArray;  // absolute directory prefixes for paths
    AllowInterpreters: Boolean;      // acknowledge interpreter indirection
  end;

  TCommandDecision = (cdAllow, cdAsk, cdDeny);

  TPolicyDecision = record
    Decision: TCommandDecision;
    Reason: string;                  // human-readable, safe to show the operator
    SegmentIndex: Integer;           // offending segment, or -1
  end;

  { The decision for a single simple-command segment. }
  TSegmentDecision = record
    SegmentIndex: Integer;
    Decision: TCommandDecision;
    Reason: string;
  end;

  TSegmentDecisionArray = array of TSegmentDecision;

function DefaultCommandPolicy: TCommandPolicy;
function ParseCommand(const ACommand: string;
  ASyntax: TShellSyntax = ssPosix): TCommandPlan;
function ClassifySegment(const APlan: TCommandPlan; AIndex: Integer;
  const APolicy: TCommandPolicy): TSegmentDecision;
function ClassifySegments(const APlan: TCommandPlan;
  const APolicy: TCommandPolicy): TSegmentDecisionArray;
function ClassifyCommand(const APlan: TCommandPlan;
  const APolicy: TCommandPolicy): TPolicyDecision;
function IsInterpreter(const AName: string): Boolean;
{ The executable plus its arguments, joined by spaces; the form an approval
  pattern is persisted as. Redirections are not included. }
function SegmentText(const ASegment: TCommandSegment): string;

implementation

type
  TTokenKind = (tkWord, tkOp, tkRedirect);
  TToken = record
    Kind: TTokenKind;
    Text: string;          // word text for tkWord; operator text otherwise
    Op: TCommandOp;        // for tkOp
    Unresolvable: Boolean; // tkWord had $ or ` outside single quotes
    InlineTarget: string;  // tkRedirect with an inline fd target (e.g. '&1')
  end;
  TTokenArray = array of TToken;

const
  Interpreters: array[0..21] of string = (
    'sh', 'bash', 'zsh', 'dash', 'ksh', 'env', 'xargs', 'sudo', 'eval',
    'command', 'exec', 'nohup', 'time', 'nice', 'find', 'python', 'python3',
    'perl', 'ruby', 'awk', 'node', 'php');

function DefaultCommandPolicy: TCommandPolicy;
begin
  Result := Default(TCommandPolicy);
end;

function IsInterpreter(const AName: string): Boolean;
var
  Base: string;
  I: Integer;
begin
  Base := ExtractFileName(AName);
  for I := Low(Interpreters) to High(Interpreters) do
    if Base = Interpreters[I] then
      Exit(True);
  Result := False;
end;

function LooksLikeAssignment(const AText: string): Boolean;
var
  P, I: Integer;
begin
  P := Pos('=', AText);
  if P <= 1 then
    Exit(False);
  for I := 1 to P - 1 do
    if not (AText[I] in ['A'..'Z', 'a'..'z', '0'..'9', '_']) then
      Exit(False);
  Result := True;
end;

function IsPathLike(const AText: string): Boolean;
begin
  Result := (AText <> '') and
    ((Pos('/', AText) > 0) or (AText[1] = '~') or (AText[1] = '.'));
end;

function PathKindOf(const AText: string; AUnresolvable: Boolean): TPathKind;
begin
  if AUnresolvable then
    Exit(pkUnresolved);
  if (AText <> '') and (AText[1] = '~') then
    Exit(pkHome);
  if (AText <> '') and (AText[1] = '/') then
    Exit(pkAbsolute);
  Result := pkRelative;
end;

function HasDotDotComponent(const APath: string): Boolean;
begin
  { Wrap in slashes so a '..' component is matched at either end too. }
  Result := Pos('/../', '/' + APath + '/') > 0;
end;

{ --- tokenizer ---------------------------------------------------------- }

function ParseCommand(const ACommand: string;
  ASyntax: TShellSyntax): TCommandPlan;
var
  S: string;
  N, I, J, K: Integer;
  C: Char;
  Tokens: TTokenArray;

  procedure Push(const T: TToken);
  begin
    SetLength(Tokens, Length(Tokens) + 1);
    Tokens[High(Tokens)] := T;
  end;

  function FdRedirectAhead(AIndex: Integer): Boolean;
  begin
    Result := False;
    while (AIndex <= N) and (S[AIndex] >= '0') and (S[AIndex] <= '9') do
      Inc(AIndex);
    Result := (AIndex <= N) and ((S[AIndex] = '<') or (S[AIndex] = '>'));
  end;

  { Reads a word respecting quotes and escapes. Sets AErr if a quote is left
    open. Advances I past the word. }
  function ReadWord(out AWord: TToken; out AErr: string): Boolean;
  var
    Buf: string;
    Unres: Boolean;
    Quote: Char;
    Ch: Char;
  begin
    Buf := '';
    Unres := False;
    Quote := #0;
    AErr := '';
    while I <= N do
    begin
      Ch := S[I];
      if Quote = #0 then
      begin
        if (Ch = ' ') or (Ch = #9) then
          Break;
        if (Ch = ';') or (Ch = '&') or (Ch = '|') or (Ch = '<') or
          (Ch = '>') or (Ch = #10) then
          Break;
        if Ch = '''' then
        begin
          Quote := '''';
          Inc(I);
          Continue;
        end;
        if Ch = '"' then
        begin
          Quote := '"';
          Inc(I);
          Continue;
        end;
        if Ch = '\' then
        begin
          Inc(I);
          if I <= N then
            Buf := Buf + S[I];
          Inc(I);
          Continue;
        end;
        if (Ch = '$') or (Ch = '`') then
          Unres := True;
        Buf := Buf + Ch;
        Inc(I);
      end
      else if Quote = '''' then
      begin
        if Ch = '''' then
          Quote := #0
        else
          Buf := Buf + Ch;
        Inc(I);
      end
      else
      begin
        if Ch = '"' then
          Quote := #0
        else if Ch = '\' then
        begin
          Inc(I);
          if I <= N then
            Buf := Buf + S[I];
        end
        else
        begin
          if (Ch = '$') or (Ch = '`') then
            Unres := True;
          Buf := Buf + Ch;
        end;
        Inc(I);
      end;
    end;
    if Quote <> #0 then
    begin
      AErr := 'unterminated quote';
      Exit(False);
    end;
    AWord := Default(TToken);
    AWord.Kind := tkWord;
    AWord.Text := Buf;
    AWord.Unresolvable := Unres;
    Result := True;
  end;

  procedure ParseRedirect(AWithDigits: Boolean; out AErr: string);
  var
    Op, Inline: string;
    T: TToken;
  begin
    AErr := '';
    Op := '';
    if AWithDigits then
      while (I <= N) and (S[I] >= '0') and (S[I] <= '9') do
      begin
        Op := Op + S[I];
        Inc(I);
      end;
    if I > N then
    begin
      AErr := 'redirection without a target';
      Exit;
    end;
    Op := Op + S[I];       // '<' or '>'
    Inc(I);
    if (I <= N) and (S[I] = '>') then
    begin
      Op := Op + '>';
      Inc(I);
    end;
    T := Default(TToken);
    T.Kind := tkRedirect;
    T.Text := Op;
    Inline := '';
    if (I <= N) and (S[I] = '&') and (I < N) and
      (S[I + 1] >= '0') and (S[I + 1] <= '9') then
    begin
      Inline := '&';
      Inc(I);
      while (I <= N) and (S[I] >= '0') and (S[I] <= '9') do
      begin
        Inline := Inline + S[I];
        Inc(I);
      end;
    end;
    T.InlineTarget := Inline;
    Push(T);
  end;

begin
  Result := Default(TCommandPlan);
  Result.Raw := ACommand;
  Result.Syntax := ASyntax;
  if ASyntax <> ssPosix then
  begin
    Result.ParseError := 'unsupported syntax mode';
    Exit;
  end;
  S := ACommand;
  N := Length(S);
  Tokens := nil;
  I := 1;
  while I <= N do
  begin
    C := S[I];
    if (C = ' ') or (C = #9) then
      Inc(I)
    else if (C = #10) or (C = ';') then
    begin
      Push(Default(TToken));
      Tokens[High(Tokens)].Kind := tkOp;
      Tokens[High(Tokens)].Op := coSeq;
      Inc(I);
    end
    else if C = '|' then
    begin
      Push(Default(TToken));
      Tokens[High(Tokens)].Kind := tkOp;
      if (I < N) and (S[I + 1] = '|') then
      begin
        Tokens[High(Tokens)].Op := coOr;
        Inc(I, 2);
      end
      else
      begin
        Tokens[High(Tokens)].Op := coPipe;
        Inc(I);
      end;
    end
    else if C = '&' then
    begin
      Push(Default(TToken));
      Tokens[High(Tokens)].Kind := tkOp;
      if (I < N) and (S[I + 1] = '&') then
      begin
        Tokens[High(Tokens)].Op := coAnd;
        Inc(I, 2);
      end
      else if (I < N) and (S[I + 1] = '>') then
      begin
        Tokens[High(Tokens)].Kind := tkRedirect;
        Tokens[High(Tokens)].Text := '&>';
        Inc(I, 2);
      end
      else
      begin
        Tokens[High(Tokens)].Op := coBackground;
        Inc(I);
      end;
    end
    else if (C = '<') or (C = '>') then
    begin
      ParseRedirect(False, Result.ParseError);
      if Result.ParseError <> '' then
        Exit;
    end
    else if (C >= '0') and (C <= '9') and FdRedirectAhead(I) then
    begin
      ParseRedirect(True, Result.ParseError);
      if Result.ParseError <> '' then
        Exit;
    end
    else
    begin
      Push(Default(TToken));
      if not ReadWord(Tokens[High(Tokens)], Result.ParseError) then
        Exit;
    end;
  end;

  { Build segments. }
  J := 0;   // index into Tokens
  while J <= High(Tokens) do
  begin
    { Start a new segment; its operator is the operator token if one is here. }
    SetLength(Result.Segments, Length(Result.Segments) + 1);
    K := High(Result.Segments);
    Result.Segments[K] := Default(TCommandSegment);
    Result.Segments[K].Op := coExec;
    if (Tokens[J].Kind = tkOp) then
    begin
      Result.Segments[K].Op := Tokens[J].Op;
      Inc(J);
    end;

    { Consume words and redirects until the next operator. }
    while (J <= High(Tokens)) and (Tokens[J].Kind <> tkOp) do
    begin
      if Tokens[J].Kind = tkRedirect then
      begin
        if Tokens[J].InlineTarget <> '' then
        begin
          SetLength(Result.Segments[K].Redirects,
            Length(Result.Segments[K].Redirects) + 1);
          with Result.Segments[K].Redirects[
            High(Result.Segments[K].Redirects)] do
          begin
            Operator := Tokens[J].Text;
            Target := Tokens[J].InlineTarget;
            TargetKind := pkUnresolved;
          end;
        end
        else
        begin
          { The next word is the target. }
          if (J + 1 > High(Tokens)) or (Tokens[J + 1].Kind <> tkWord) then
          begin
            Result.ParseError := 'redirection without a target';
            Exit;
          end;
          Inc(J);
          SetLength(Result.Segments[K].Redirects,
            Length(Result.Segments[K].Redirects) + 1);
          with Result.Segments[K].Redirects[
            High(Result.Segments[K].Redirects)] do
          begin
            Operator := Tokens[J - 1].Text;
            Target := Tokens[J].Text;
            TargetKind := PathKindOf(Tokens[J].Text, Tokens[J].Unresolvable);
          end;
          { A redirect target is always a path, even without a separator. }
          SetLength(Result.Segments[K].Paths,
            Length(Result.Segments[K].Paths) + 1);
          with Result.Segments[K].Paths[High(Result.Segments[K].Paths)] do
          begin
            Text := Tokens[J].Text;
            Kind := PathKindOf(Tokens[J].Text, Tokens[J].Unresolvable);
            IsRedirect := True;
          end;
        end;
      end
      else
      begin
        { A word. Leading VAR=value assignments are not the executable. }
        if Result.Segments[K].Executable = '' then
        begin
          if not LooksLikeAssignment(Tokens[J].Text) then
            Result.Segments[K].Executable := Tokens[J].Text;
        end
        else
        begin
          SetLength(Result.Segments[K].Arguments,
            Length(Result.Segments[K].Arguments) + 1);
          Result.Segments[K].Arguments[High(Result.Segments[K].Arguments)] :=
            Tokens[J].Text;
          if IsPathLike(Tokens[J].Text) then
          begin
            SetLength(Result.Segments[K].Paths,
              Length(Result.Segments[K].Paths) + 1);
            with Result.Segments[K].Paths[High(Result.Segments[K].Paths)] do
            begin
              Text := Tokens[J].Text;
              Kind := PathKindOf(Tokens[J].Text, Tokens[J].Unresolvable);
              IsRedirect := False;
            end;
          end;
        end;
      end;
      Inc(J);
    end;
  end;

  { Drop a trailing empty segment produced by a trailing operator. }
  if (Length(Result.Segments) > 0) then
    with Result.Segments[High(Result.Segments)] do
      if (Executable = '') and (Length(Arguments) = 0) and
        (Length(Redirects) = 0) then
        SetLength(Result.Segments, Length(Result.Segments) - 1);

  for J := 0 to High(Result.Segments) do
    Result.Segments[J].Text := SegmentText(Result.Segments[J]);
end;

{ --- classifier --------------------------------------------------------- }

{ Case-sensitive glob match supporting '*' and '?'. Iterative, no recursion. }
function MatchMask(const AValue, APattern: string): Boolean;
var
  V, P, StarV, StarP: Integer;
begin
  V := 1;
  P := 1;
  StarV := 0;
  StarP := 0;
  while V <= Length(AValue) do
  begin
    if (P <= Length(APattern)) and
      ((APattern[P] = '?') or (APattern[P] = AValue[V])) then
    begin
      Inc(V);
      Inc(P);
    end
    else if (P <= Length(APattern)) and (APattern[P] = '*') then
    begin
      StarP := P;
      StarV := V;
      Inc(P);
    end
    else if StarP > 0 then
    begin
      P := StarP + 1;
      Inc(StarV);
      V := StarV;
    end
    else
      Exit(False);
  end;
  while (P <= Length(APattern)) and (APattern[P] = '*') do
    Inc(P);
  Result := P > Length(APattern);
end;

function SegmentText(const ASegment: TCommandSegment): string;
var
  I: Integer;
begin
  Result := ASegment.Executable;
  for I := 0 to High(ASegment.Arguments) do
    Result := Result + ' ' + ASegment.Arguments[I];
end;

function SplitWords(const AText: string): TCommandArgArray;
var
  I, Start: Integer;
  S: string;
begin
  Result := nil;
  S := AText;
  I := 1;
  while I <= Length(S) do
  begin
    while (I <= Length(S)) and ((S[I] = ' ') or (S[I] = #9)) do
      Inc(I);
    Start := I;
    while (I <= Length(S)) and (S[I] <> ' ') and (S[I] <> #9) do
      Inc(I);
    if I > Start then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Copy(S, Start, I - Start);
    end;
  end;
end;

function ExeMatches(const AExecutable, APattern: string): Boolean;
begin
  Result := MatchMask(AExecutable, APattern) or
    MatchMask(ExtractFileName(AExecutable), APattern);
end;

{ Matches a pattern's argument words against a segment's arguments, where a
  standalone '*' word matches any number of arguments. Backtracking over '*'. }
function ArgsMatch(const APatternArgs, AArguments: TCommandArgArray): Boolean;
var
  Pi, Ai, StarP, StarA: Integer;
begin
  Pi := 0;
  Ai := 0;
  StarP := -1;
  StarA := 0;
  while Ai <= High(AArguments) do
  begin
    if (Pi <= High(APatternArgs)) and (APatternArgs[Pi] = '*') then
    begin
      StarP := Pi;
      StarA := Ai;
      Inc(Pi);
    end
    else if (Pi <= High(APatternArgs)) and
      MatchMask(AArguments[Ai], APatternArgs[Pi]) then
    begin
      Inc(Pi);
      Inc(Ai);
    end
    else if StarP >= 0 then
    begin
      Inc(StarA);
      Ai := StarA;
      Pi := StarP + 1;
    end
    else
      Exit(False);
  end;
  while (Pi <= High(APatternArgs)) and (APatternArgs[Pi] = '*') do
    Inc(Pi);
  Result := Pi > High(APatternArgs);
end;

{ Any pattern form: executable-only, or executable + argument words. }
function SegmentMatchesPattern(const ASegment: TCommandSegment;
  const APattern: string): Boolean;
var
  Words, ArgWords: TCommandArgArray;
  I: Integer;
begin
  Words := SplitWords(Trim(APattern));
  if Length(Words) = 0 then
    Exit(False);
  if not ExeMatches(ASegment.Executable, Words[0]) then
    Exit(False);
  if Length(Words) = 1 then
    Exit(True);
  SetLength(ArgWords, Length(Words) - 1);
  for I := 1 to High(Words) do
    ArgWords[I - 1] := Words[I];
  Result := ArgsMatch(ArgWords, ASegment.Arguments);
end;

function SegmentMatchesAny(const ASegment: TCommandSegment;
  const APatterns: TCommandArgArray): Boolean;
var
  Pattern: string;
begin
  for Pattern in APatterns do
    if SegmentMatchesPattern(ASegment, Pattern) then
      Exit(True);
  Result := False;
end;

{ A pattern that names arguments (more than one word). }
function SegmentMatchesFullArg(const ASegment: TCommandSegment;
  const APatterns: TCommandArgArray): Boolean;
var
  Pattern: string;
begin
  for Pattern in APatterns do
    if (Length(SplitWords(Trim(Pattern))) > 1) and
      SegmentMatchesPattern(ASegment, Pattern) then
      Exit(True);
  Result := False;
end;

{ A pattern that names only the executable (one word). }
function SegmentMatchesExeOnly(const ASegment: TCommandSegment;
  const APatterns: TCommandArgArray): Boolean;
var
  Pattern: string;
begin
  for Pattern in APatterns do
    if (Length(SplitWords(Trim(Pattern))) = 1) and
      SegmentMatchesPattern(ASegment, Pattern) then
      Exit(True);
  Result := False;
end;

function PathAllowed(const APath: TCommandPath;
  const ARoots: TCommandArgArray): Boolean;
var
  Root: string;
begin
  if APath.Kind = pkUnresolved then
    Exit(False);
  if APath.Kind = pkRelative then
  begin
    { A relative path stays within the working directory unless it climbs out. }
    Result := not HasDotDotComponent(APath.Text);
    Exit;
  end;
  if Length(ARoots) = 0 then
    Exit(False);
  for Root in ARoots do
    if Copy(APath.Text, 1, Length(Root)) = Root then
      Exit(True);
  Result := False;
end;

function ClassifySegment(const APlan: TCommandPlan; AIndex: Integer;
  const APolicy: TCommandPolicy): TSegmentDecision;
var
  Seg: TCommandSegment;
  J: Integer;
begin
  Result := Default(TSegmentDecision);
  Result.SegmentIndex := AIndex;
  Result.Decision := cdAsk;
  if (AIndex < 0) or (AIndex > High(APlan.Segments)) then
  begin
    Result.Reason := 'invalid segment index';
    Exit;
  end;
  Seg := APlan.Segments[AIndex];

  { 1. Deny patterns win, in any form. }
  if SegmentMatchesAny(Seg, APolicy.Deny) then
  begin
    Result.Decision := cdDeny;
    Result.Reason := 'command "' + Seg.Text + '" is denied by policy';
    Exit;
  end;

  { 2. Interpreters require explicit acknowledgment. }
  if (not APolicy.AllowInterpreters) and IsInterpreter(Seg.Executable) then
  begin
    Result.Reason := 'interpreter "' + Seg.Executable +
      '" can run arbitrary commands and needs explicit approval';
    Exit;
  end;

  { 3. Redirection targets are always path-checked. }
  for J := 0 to High(Seg.Paths) do
    if Seg.Paths[J].IsRedirect and
      (not PathAllowed(Seg.Paths[J], APolicy.AllowedRoots)) then
    begin
      Result.Reason := 'path "' + Seg.Paths[J].Text +
        '" is outside the allowed roots';
      Exit;
    end;

  { 4. An explicit argument pattern (e.g. 'cat /etc/os-release', 'cat *')
       approves the command as written, including its argument paths. }
  if SegmentMatchesFullArg(Seg, APolicy.Allow) then
  begin
    Result.Decision := cdAllow;
    Result.Reason := 'command "' + Seg.Text + '" matches an explicit allow rule';
    Exit;
  end;

  { 5. Remaining literal paths must stay within the allowed roots. }
  for J := 0 to High(Seg.Paths) do
    if (not Seg.Paths[J].IsRedirect) and
      (not PathAllowed(Seg.Paths[J], APolicy.AllowedRoots)) then
    begin
      Result.Reason := 'path "' + Seg.Paths[J].Text +
        '" is outside the allowed roots';
      Exit;
    end;

  { 6. An executable-only pattern allows the command for any arguments. }
  if SegmentMatchesExeOnly(Seg, APolicy.Allow) then
  begin
    Result.Decision := cdAllow;
    Result.Reason := 'command "' + Seg.Executable + '" is allowed';
    Exit;
  end;

  { 7. Otherwise ask. }
  Result.Reason := 'command "' + Seg.Executable + '" is not in the allow list';
end;

function ClassifySegments(const APlan: TCommandPlan;
  const APolicy: TCommandPolicy): TSegmentDecisionArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(APlan.Segments));
  for I := 0 to High(APlan.Segments) do
    Result[I] := ClassifySegment(APlan, I, APolicy);
end;

function ClassifyCommand(const APlan: TCommandPlan;
  const APolicy: TCommandPolicy): TPolicyDecision;
var
  Segs: TSegmentDecisionArray;
  I: Integer;
begin
  Result := Default(TPolicyDecision);
  Result.Decision := cdAsk;
  Result.SegmentIndex := -1;

  if APlan.ParseError <> '' then
  begin
    Result.Reason := 'could not parse command: ' + APlan.ParseError;
    Exit;
  end;
  if Length(APlan.Segments) = 0 then
  begin
    Result.Reason := 'empty command';
    Exit;
  end;

  Segs := ClassifySegments(APlan, APolicy);

  for I := 0 to High(Segs) do
    if Segs[I].Decision = cdDeny then
    begin
      Result.Decision := cdDeny;
      Result.SegmentIndex := I;
      Result.Reason := Segs[I].Reason;
      Exit;
    end;

  for I := 0 to High(Segs) do
    if Segs[I].Decision = cdAsk then
    begin
      Result.SegmentIndex := I;
      Result.Reason := Segs[I].Reason;
      Exit;
    end;

  Result.Decision := cdAllow;
  Result.Reason := 'all commands match the allow list';
end;

end.
