unit hildegard.helper.command.policy;
{ Pure POSIX command-line parser for the shell tool.

  A command line is split into simple-command segments at unquoted POSIX
  operators; each segment's executable, arguments, redirections, and literal
  path-like tokens are extracted. The approval adapter turns the segments into
  approval subjects/asks.

  This is a guardrail, not a sandbox: only literal tokens are reasoned about.
  Variable expansion, command substitution, globs, and redirections are NOT
  resolved; such tokens are reported as unresolved rather than assumed safe.
  The POSIX syntax mode is implemented in v1; `ssCmd` is reserved for a future
  Windows profile. }

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
    { The segment's span in the raw command: 1-based bytes, Len 0 when the
      tokenizer could not place it. Covers the words and redirects, not the
      operator that introduced it. }
    Start: Integer;
    Len: Integer;
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

function ParseCommand(const ACommand: string;
  ASyntax: TShellSyntax = ssPosix): TCommandPlan;
{ The executable plus its arguments, joined by spaces; the form an approval
  summary uses. Redirections are not included. }
function SegmentText(const ASegment: TCommandSegment): string;

implementation

type
  TTokenKind = (tkWord, tkOp, tkRedirect);
  TToken = record
    Kind: TTokenKind;
    StartPos, EndPos: Integer;   // 1-based byte span in the raw command; 0 = none
    Text: string;          // word text for tkWord; operator text otherwise
    Op: TCommandOp;        // for tkOp
    Unresolvable: Boolean; // tkWord had $ or ` outside single quotes
    InlineTarget: string;  // tkRedirect with an inline fd target (e.g. '&1')
  end;
  TTokenArray = array of TToken;

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

function SegmentText(const ASegment: TCommandSegment): string;
var
  I: Integer;
begin
  Result := ASegment.Executable;
  for I := 0 to High(ASegment.Arguments) do
    Result := Result + ' ' + ASegment.Arguments[I];
end;

{ --- tokenizer ---------------------------------------------------------- }

function ParseCommand(const ACommand: string;
  ASyntax: TShellSyntax): TCommandPlan;
var
  S: string;
  N, I, J, K, TokStart, TokCount: Integer;
  C: Char;
  Tokens: TTokenArray;
  SegStart, SegEnd: Integer;

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
    TokStart := I;
    TokCount := Length(Tokens);
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
    { Every branch above consumes at most one token, so the span is the bytes
      this iteration covered. }
    if Length(Tokens) > TokCount then
    begin
      Tokens[High(Tokens)].StartPos := TokStart;
      Tokens[High(Tokens)].EndPos := I - 1;
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
    SegStart := 0;
    SegEnd := 0;
    while (J <= High(Tokens)) and (Tokens[J].Kind <> tkOp) do
    begin
      if Tokens[J].StartPos > 0 then
      begin
        if SegStart = 0 then
          SegStart := Tokens[J].StartPos;
        SegEnd := Tokens[J].EndPos;
      end;
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
          if Tokens[J].StartPos > 0 then
            SegEnd := Tokens[J].EndPos;
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
    if SegStart > 0 then
    begin
      Result.Segments[K].Start := SegStart;
      Result.Segments[K].Len := SegEnd - SegStart + 1;
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

end.
