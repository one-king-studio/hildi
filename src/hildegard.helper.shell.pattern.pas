unit hildegard.helper.shell.pattern;
{ Bash pattern languages for the builtin shell: fixed strings, BRE and ERE over
  FPC's regexpr, with the translation that makes bash's spelling mean the same
  thing the engine means. Shared by grep and sed (and any later consumer).

  The engine is harness-side only: the Shell Library itself stays free of it. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, regexpr;

{ Map a POSIX class name to the engine's ranges. }
function PosixClassRange(const AName: string; out ARange: string): Boolean;

{ Translate a bash pattern to the engine's syntax: BRE metacharacters
  (escaped parentheses, braces, alternation, plus and question), GNU word
  boundaries, and POSIX character classes inside brackets. ERE is passed
  through apart from the class and boundary mappings. }
function TranslatePattern(const APattern: string; AExtended: Boolean;
  out AWhy: string): string;

type
  { One compiled pattern matcher: fixed substring, or BRE/ERE via TRegExpr. }
  TPatternMatcher = class
  private
    FRe: TRegExpr;
    FFixed: Boolean;
    FPattern: string;
    FIgnoreCase: Boolean;
    FInvert: Boolean;
    FInvalid: string;
    FMatched: string;
    FMatchStart: Integer;
    FRawMatched: Boolean;
    FWordMode: Boolean;
    FLineMode: Boolean;
  public
    constructor Create(const APattern: string; AFixed, AExtended, AIgnoreCase,
      AInvert: Boolean);
    destructor Destroy; override;
    function Matches(const ALine: string): Boolean;
    { The text of the last raw match, for grep -o. '' when the last call did not
      match, or when the match was inverted (nothing matched, so nothing to
      print). }
    property MatchedText: string read FMatched;
    { The 1-based offset of the last raw match in the line; 0 when none. }
    property MatchStart: Integer read FMatchStart;
    { True when the last call matched BEFORE inversion was applied. }
    property RawMatched: Boolean read FRawMatched;
    { Constrain matching to whole words (-w) or the whole line (-x). Applied
      inside Matches, so every consumer gets the same answer. }
    procedure SetMatchMode(AWord, ALine: Boolean);
    { Every match in the line, in order, honouring the mode. grep -o prints
      these. Empty when nothing matches. }
    function AllMatches(const ALine: string): TStringArray;
    property Invalid: string read FInvalid;
  end;

{ True when the builtin can execute APattern faithfully. False + AWhy when the
  pattern uses a construct the translation cannot express (so `auto` falls
  back to /bin/bash). }
function PatternSupported(const APattern: string; AFixed, AExtended: Boolean;
  out AWhy: string): Boolean;

implementation

{ Map a POSIX class name to the engine's ranges. }
function PosixClassRange(const AName: string; out ARange: string): Boolean;
begin
  ARange := '';
  if AName = 'alpha' then
    ARange := 'a-zA-Z'
  else if AName = 'digit' then
    ARange := '0-9'
  else if AName = 'alnum' then
    ARange := 'a-zA-Z0-9'
  else if AName = 'upper' then
    ARange := 'A-Z'
  else if AName = 'lower' then
    ARange := 'a-z'
  else if AName = 'xdigit' then
    ARange := '0-9A-Fa-f'
  else if AName = 'space' then
    ARange := ' \t\r\n'
  else if AName = 'blank' then
    ARange := ' \t'
  else
    Exit(False);
  Result := True;
end;

{ Translate a bash pattern to the engine's syntax: BRE metacharacters
  (escaped parentheses, braces, alternation, plus and question), GNU word
  boundaries, and POSIX character classes inside brackets. ERE is passed
  through apart from the class and boundary mappings. }
function TranslatePattern(const APattern: string; AExtended: Boolean;
  out AWhy: string): string;
var
  I, J: Integer;
  C: Char;
  Name, Range: string;
begin
  AWhy := '';
  Result := '';
  I := 1;
  while I <= Length(APattern) do
  begin
    C := APattern[I];
    if C = '\' then
    begin
      if I = Length(APattern) then
      begin
        Result := Result + '\\';
        Inc(I);
        Continue;
      end;
      C := APattern[I + 1];
      if (C = '<') or (C = '>') then
      begin
        Result := Result + '\b';
        Inc(I, 2);
        Continue;
      end;
      if (not AExtended) and (Pos(C, '(){}|+?') > 0) then
      begin
        Result := Result + C;
        Inc(I, 2);
        Continue;
      end;
      if Pos(C, 'wWbBsS') > 0 then
      begin
        { GNU extensions with the same meaning in the engine. }
        Result := Result + '\' + C;
        Inc(I, 2);
        Continue;
      end;
      if ((C >= 'a') and (C <= 'z')) or ((C >= 'A') and (C <= 'Z')) or
        ((C >= '0') and (C <= '9')) then
      begin
        { bash leaves an unknown letter escape as the literal character: \d
          is "d", not a digit class. Dropping the backslash keeps parity. }
        Result := Result + C;
        Inc(I, 2);
        Continue;
      end;
      Result := Result + '\' + C;
      Inc(I, 2);
      Continue;
    end;
    if C = '[' then
    begin
      Result := Result + '[';
      Inc(I);
      if (I <= Length(APattern)) and (APattern[I] = '^') then
      begin
        Result := Result + '^';
        Inc(I);
      end;
      if (I <= Length(APattern)) and (APattern[I] = ']') then
      begin
        Result := Result + ']';
        Inc(I);
      end;
      while (I <= Length(APattern)) and (APattern[I] <> ']') do
      begin
        if (APattern[I] = '[') and (I < Length(APattern)) and
          (APattern[I + 1] = ':') then
        begin
          J := I + 2;
          while (J < Length(APattern)) and
            (not ((APattern[J] = ':') and (APattern[J + 1] = ']'))) do
            Inc(J);
          if J < Length(APattern) then
          begin
            Name := Copy(APattern, I + 2, J - I - 2);
            if PosixClassRange(Name, Range) then
            begin
              Result := Result + Range;
              I := J + 2;
              Continue;
            end;
            AWhy := 'unsupported POSIX character class [:' + Name + ':]';
            Exit('');
          end;
        end;
        if APattern[I] = '\' then
        begin
          Result := Result + APattern[I];
          Inc(I);
          if I <= Length(APattern) then
          begin
            Result := Result + APattern[I];
            Inc(I);
          end;
          Continue;
        end;
        Result := Result + APattern[I];
        Inc(I);
      end;
      if I <= Length(APattern) then
      begin
        Result := Result + ']';
        Inc(I);
      end
      else
      begin
        AWhy := 'unterminated character class';
        Exit('');
      end;
      Continue;
    end;
    if (not AExtended) and (Pos(C, '(){}|+?') > 0) then
    begin
      Result := Result + '\' + C;
      Inc(I);
      Continue;
    end;
    Result := Result + C;
    Inc(I);
  end;
end;

constructor TPatternMatcher.Create(const APattern: string; AFixed, AExtended,
  AIgnoreCase, AInvert: Boolean);
var
  Translated: string;
begin
  inherited Create;
  FFixed := AFixed;
  FPattern := APattern;
  FIgnoreCase := AIgnoreCase;
  FInvert := AInvert;
  FInvalid := '';
  FMatched := '';
  FMatchStart := 0;
  FRawMatched := False;
  FWordMode := False;
  FLineMode := False;
  if AFixed then
    Exit;
  Translated := TranslatePattern(APattern, AExtended, FInvalid);
  if FInvalid <> '' then
    Exit;
  FRe := TRegExpr.Create;
  try
    FRe.Expression := Translated;
    FRe.ModifierI := AIgnoreCase;
    FRe.Exec('');   // force compilation so a bad pattern is reported here
  except
    on E: Exception do
    begin
      FInvalid := E.Message;
      FreeAndNil(FRe);
    end;
  end;
end;

destructor TPatternMatcher.Destroy;
begin
  FRe.Free;
  inherited Destroy;
end;

{ A word character for -w: letters, digits and underscore. }
function IsWordChar(C: Char): Boolean;
begin
  Result := C in ['a'..'z', 'A'..'Z', '0'..'9', '_'];
end;

function TPatternMatcher.Matches(const ALine: string): Boolean;
var
  Hay, Needle: string;
  Posn: Integer;
begin
  { Reset per call: a stale match must never leak into grep -o's output. }
  FMatched := '';
  FMatchStart := 0;
  FRawMatched := False;
  if FInvalid <> '' then
    Exit(False);
  if FRe <> nil then
  begin
    Result := FRe.Exec(ALine);
    if Result then
    begin
      FRawMatched := True;
      FMatched := FRe.Match[0];
      FMatchStart := FRe.MatchPos[0];
    end;
  end
  else
  begin
    Hay := ALine;
    Needle := FPattern;
    if FIgnoreCase then
    begin
      Hay := LowerCase(Hay);
      Needle := LowerCase(Needle);
    end;
    Posn := Pos(Needle, Hay);
    Result := Posn > 0;
    if Result then
    begin
      FRawMatched := True;
      { The text comes from the ORIGINAL line, not the folded one, so -o prints
        what the file actually says. }
      FMatched := Copy(ALine, Posn, Length(Needle));
      FMatchStart := Posn;
    end;
  end;
  if FInvert then
    Result := not Result;
  { -w and -x constrain what counts as a match: applied after the raw match and
    before inversion, so `grep -v -x` means "lines that are not exactly this". }
  if Result and (not FInvert) and FRawMatched then
  begin
    if FLineMode and (FMatched <> ALine) then
      Result := False
    else if FWordMode then
    begin
      { The characters either side of the match must not be word characters. }
      if (FMatchStart > 1) and IsWordChar(ALine[FMatchStart - 1]) then
        Result := False
      else if (FMatchStart + Length(FMatched) <= Length(ALine)) and
        IsWordChar(ALine[FMatchStart + Length(FMatched)]) then
        Result := False;
    end;
    if not Result then
    begin
      FRawMatched := False;
      FMatched := '';
      FMatchStart := 0;
    end;
  end;
end;

procedure TPatternMatcher.SetMatchMode(AWord, ALine: Boolean);
begin
  FWordMode := AWord;
  FLineMode := ALine;
end;

function TPatternMatcher.AllMatches(const ALine: string): TStringArray;
var
  Hay, Needle: string;
  Offset, Posn, N: Integer;
begin
  Result := nil;
  if FInvalid <> '' then
    Exit;
  { -x: the whole line is the match, when it is a match at all. }
  if FLineMode then
  begin
    if Matches(ALine) and FRawMatched then
      Result := [ALine];
    Exit;
  end;
  if FRe <> nil then
  begin
    { Regex: walk successive matches, advancing past each so a zero-length match
      cannot loop forever. }
    Offset := 1;
    N := 0;
    while (Offset <= Length(ALine)) and FRe.Exec(Copy(ALine, Offset, MaxInt)) do
    begin
      Posn := Offset + FRe.MatchPos[0] - 1;
      if FRe.MatchLen[0] = 0 then
      begin
        Inc(Offset);
        Continue;
      end;
      if FWordMode then
      begin
        if ((Posn > 1) and IsWordChar(ALine[Posn - 1])) or
           ((Posn + FRe.MatchLen[0] - 1 < Length(ALine)) and
            IsWordChar(ALine[Posn + FRe.MatchLen[0]])) then
        begin
          Inc(Offset, FRe.MatchPos[0] + FRe.MatchLen[0] - 1);
          Continue;
        end;
      end;
      SetLength(Result, N + 1);
      Result[N] := FRe.Match[0];
      Inc(N);
      Inc(Offset, FRe.MatchPos[0] + FRe.MatchLen[0] - 1);
    end;
    Exit;
  end;
  Hay := ALine;
  Needle := FPattern;
  if FIgnoreCase then
  begin
    Hay := LowerCase(Hay);
    Needle := LowerCase(Needle);
  end;
  if Needle = '' then
    Exit;
  Offset := 1;
  N := 0;
  while Offset <= Length(Hay) do
  begin
    Posn := Pos(Needle, Copy(Hay, Offset, MaxInt));
    if Posn = 0 then
      Break;
    Inc(Posn, Offset - 1);
    if FWordMode then
    begin
      if ((Posn > 1) and IsWordChar(ALine[Posn - 1])) or
         ((Posn + Length(Needle) - 1 < Length(ALine)) and
          IsWordChar(ALine[Posn + Length(Needle)])) then
      begin
        Offset := Posn + Length(Needle);
        Continue;
      end;
    end;
    { The text comes from the ORIGINAL line, so -o prints what the file says. }
    SetLength(Result, N + 1);
    Result[N] := Copy(ALine, Posn, Length(Needle));
    Inc(N);
    Offset := Posn + Length(Needle);
  end;
end;

function PatternSupported(const APattern: string; AFixed, AExtended: Boolean;
  out AWhy: string): Boolean;
var
  M: TPatternMatcher;
begin
  M := TPatternMatcher.Create(APattern, AFixed, AExtended, False, False);
  try
    AWhy := M.Invalid;
    Result := AWhy = '';
  finally
    M.Free;
  end;
end;


end.
