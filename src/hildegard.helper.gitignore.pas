unit hildegard.helper.gitignore;
{ A reusable .gitignore parser and matcher.

  Pure: it takes the *text* of ignore files and answers "is this path
  ignored?", so the same rules serve the shell (`rg`) and, later, the file-diff
  tracker ("do not record edits to ignored files"). The caller reads the files
  and decides where they apply.

  Semantics (git's): the last matching rule wins; `!` re-includes; a leading
  `/` or an inner `/` anchors the pattern to the ignore file's directory; a
  trailing `/` is directory-only; a pattern without a slash matches a basename
  at any depth; `*` and `?` do not cross `/`; `**` does; `[...]` classes and
  backslash escapes work. A file cannot be re-included when a parent directory
  is excluded. `.git` is not a rule (git itself does not report it); a caller
  that wants it skipped passes AIgnoreGit. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes;

type
  TIgnoreRules = class
  private
    type
      TRule = record
        Base: string;
        Pattern: string;
        Anchored: Boolean;
        DirOnly: Boolean;
        Negated: Boolean;
      end;
  private
    FRules: array of TRule;
    FIgnoreGit: Boolean;
    function Evaluate(const APath: string; AIsDir: Boolean): Boolean;
  public
    constructor Create(AIgnoreGit: Boolean = False);
    procedure Clear;
    { Add the rules of one ignore file. ABaseDir is that file's directory,
      relative to the query root ('' for the root), '/'-separated. }
    procedure AddFile(const ABaseDir, AText: string);
    { True when APath (relative to the root, '/'-separated, no leading '/') is
      ignored. AIsDir says whether the path is a directory. }
    function IsIgnored(const APath: string; AIsDir: Boolean): Boolean;
    function RuleCount: Integer;
  end;

{ The gitignore pattern language over one path (no '/'-based anchoring; the
  caller has already chosen the candidate). Exposed for tests. }
function MatchIgnore(const APattern, ACandidate: string): Boolean;

implementation

function FirstComponent(const APath: string): string;
var
  P: Integer;
begin
  P := Pos('/', APath);
  if P = 0 then
    Result := APath
  else
    Result := Copy(APath, 1, P - 1);
end;

function BaseNameOf(const APath: string): string;
var
  P: Integer;
begin
  P := Length(APath);
  while (P >= 1) and (APath[P] <> '/') do
    Dec(P);
  Result := Copy(APath, P + 1, MaxInt);
end;

function IsUnderPrefix(const ABase, APath: string): Boolean;
begin
  if ABase = '' then
    Exit(True);
  Result := (APath = ABase) or
    ((Length(APath) > Length(ABase)) and
     (Copy(APath, 1, Length(ABase) + 1) = ABase + '/'));
end;

function RelTo(const ABase, APath: string): string;
begin
  if ABase = '' then
    Result := APath
  else
    Result := Copy(APath, Length(ABase) + 2, MaxInt);
end;

function MatchAt(const P, S: string; PI, SI: Integer): Boolean; forward;

function MatchClass(const P: string; var PI: Integer; C: Char): Boolean;
var
  Neg, Matched: Boolean;
  Lo, Hi: Char;
begin
  Inc(PI);   // past '['
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

function MatchAt(const P, S: string; PI, SI: Integer): Boolean;
var
  K, J: Integer;
begin
  while True do
  begin
    if PI > Length(P) then
      Exit(SI > Length(S));
    case P[PI] of
      '\':
        begin
          Inc(PI);
          if PI > Length(P) then
            Exit(False);
          if (SI > Length(S)) or (S[SI] <> P[PI]) then
            Exit(False);
          Inc(PI);
          Inc(SI);
        end;
      '*':
        begin
          if (PI < Length(P)) and (P[PI + 1] = '*') then
          begin
            J := PI;
            while (J <= Length(P)) and (P[J] = '*') do
              Inc(J);
            if (J <= Length(P)) and (P[J] = '/') then
            begin
              { `**/` matches zero or more directories. }
              if MatchAt(P, S, J + 1, SI) then
                Exit(True);
              for K := SI to Length(S) do
                if (S[K] = '/') and MatchAt(P, S, J + 1, K + 1) then
                  Exit(True);
              Exit(False);
            end;
            { A trailing or embedded `**` crosses '/'. }
            for K := SI to Length(S) do
              if MatchAt(P, S, J, K) then
                Exit(True);
            Exit(False);
          end;
          Inc(PI);
          K := SI;
          while True do
          begin
            if MatchAt(P, S, PI, K) then
              Exit(True);
            if (K > Length(S)) or (S[K] = '/') then
              Exit(False);
            Inc(K);
          end;
        end;
      '?':
        begin
          if (SI > Length(S)) or (S[SI] = '/') then
            Exit(False);
          Inc(PI);
          Inc(SI);
        end;
      '[':
        begin
          if (SI > Length(S)) or (S[SI] = '/') then
            Exit(False);
          if not MatchClass(P, PI, S[SI]) then
            Exit(False);
          Inc(SI);
        end;
    else
      if (SI > Length(S)) or (S[SI] <> P[PI]) then
        Exit(False);
      Inc(PI);
      Inc(SI);
    end;
  end;
end;

function MatchIgnore(const APattern, ACandidate: string): Boolean;
begin
  Result := MatchAt(APattern, ACandidate, 1, 1);
end;

constructor TIgnoreRules.Create(AIgnoreGit: Boolean);
begin
  inherited Create;
  FIgnoreGit := AIgnoreGit;
  FRules := nil;
end;

procedure TIgnoreRules.Clear;
begin
  FRules := nil;
end;

procedure TIgnoreRules.AddFile(const ABaseDir, AText: string);
var
  Lines: TStringList;
  I: Integer;
  Line, Base: string;
  R: TRule;
begin
  Base := ABaseDir;
  while (Base <> '') and (Base[1] = '/') do
    Delete(Base, 1, 1);
  while (Base <> '') and (Base[Length(Base)] = '/') do
    Delete(Base, Length(Base), 1);
  Lines := TStringList.Create;
  try
    Lines.Text := AText;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Lines[I];
      { Trim unescaped trailing spaces (git's rule). }
      while (Line <> '') and (Line[Length(Line)] = ' ') and
        ((Length(Line) = 1) or (Line[Length(Line) - 1] <> '\')) do
        Delete(Line, Length(Line), 1);
      if (Line = '') or (Line[1] = '#') then
        Continue;
      R := Default(TRule);
      R.Base := Base;
      if Line[1] = '!' then
      begin
        R.Negated := True;
        Delete(Line, 1, 1);
      end
      else if (Length(Line) > 1) and (Line[1] = '\') and
        (Line[2] in ['!', '#']) then
        Delete(Line, 1, 1);
      if Line = '' then
        Continue;
      if Line[Length(Line)] = '/' then
      begin
        R.DirOnly := True;
        Delete(Line, Length(Line), 1);
      end;
      if Line = '' then
        Continue;
      if Line[1] = '/' then
      begin
        R.Anchored := True;
        Delete(Line, 1, 1);
      end
      else if Pos('/', Line) > 0 then
        R.Anchored := True;
      if Line = '' then
        Continue;
      R.Pattern := Line;
      SetLength(FRules, Length(FRules) + 1);
      FRules[High(FRules)] := R;
    end;
  finally
    Lines.Free;
  end;
end;

function TIgnoreRules.Evaluate(const APath: string; AIsDir: Boolean): Boolean;
var
  I: Integer;
  R: TRule;
  Rel, Candidate: string;
begin
  Result := False;
  for I := 0 to High(FRules) do
  begin
    R := FRules[I];
    if R.DirOnly and (not AIsDir) then
      Continue;
    if not IsUnderPrefix(R.Base, APath) then
      Continue;
    Rel := RelTo(R.Base, APath);
    if Rel = '' then
      Continue;
    if R.Anchored then
      Candidate := Rel
    else
      Candidate := BaseNameOf(Rel);
    if MatchIgnore(R.Pattern, Candidate) then
      Result := not R.Negated;
  end;
end;

function TIgnoreRules.IsIgnored(const APath: string; AIsDir: Boolean): Boolean;
var
  I, P, Count: Integer;
  Prefix, Part: string;
  Parts: array of string;
begin
  if APath = '' then
    Exit(False);
  Count := 0;
  Parts := nil;
  P := 1;
  while P <= Length(APath) do
  begin
    I := P;
    while (I <= Length(APath)) and (APath[I] <> '/') do
      Inc(I);
    SetLength(Parts, Count + 1);
    Parts[Count] := Copy(APath, P, I - P);
    Inc(Count);
    P := I + 1;
  end;
  if FIgnoreGit then
    for I := 0 to Count - 1 do
      if Parts[I] = '.git' then
        Exit(True);
  { A file cannot be re-included inside an excluded directory. }
  Prefix := '';
  for I := 0 to Count - 2 do
  begin
    if Prefix = '' then
      Prefix := Parts[I]
    else
      Prefix := Prefix + '/' + Parts[I];
    if Evaluate(Prefix, True) then
      Exit(True);
  end;
  Result := Evaluate(APath, AIsDir);
end;

function TIgnoreRules.RuleCount: Integer;
begin
  Result := Length(FRules);
end;

end.
