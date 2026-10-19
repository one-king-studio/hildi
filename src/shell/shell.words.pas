unit shell.words;
{ Parse a raw shell word into parts: literal runs, quoted runs, variables,
  specials ($?, $@, ...), a leading tilde, and unquoted glob characters.

  v1 does not expand: the parts are the contract the interpreter consumes. An
  unsupported construct (command substitution, parameter-expansion operators,
  ANSI-C quoting, process substitution, brace expansion) is a parse error
  naming it. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, shell.types, shell.ast;

{ Parse ARaw (the lexer's word text, quotes kept). Positions in AError are
  computed from the token's base position. }
function ParseWordParts(const ARaw: string;
  ABaseOffset, ABaseLine, ABaseCol: Integer;
  out AParts: TWordPartArray; out AError: TShellParseError): Boolean;

{ True when the raw text starts with an unquoted NAME= (an assignment prefix).
  Returns the name and the raw value (the rest). }
function SplitAssignment(const ARaw: string; out AName, ARawValue: string): Boolean;

implementation

type
  TPartBuilder = record
    Parts: TWordPartArray;
    procedure AddLiteral(const AText: string; AQuoted: Boolean);
    procedure AddPart(AKind: TWordPartKind; const AText: string; AQuoted: Boolean);
  end;

procedure TPartBuilder.AddPart(AKind: TWordPartKind; const AText: string;
  AQuoted: Boolean);
var
  N: Integer;
begin
  N := Length(Parts);
  SetLength(Parts, N + 1);
  Parts[N] := Default(TWordPart);
  Parts[N].Kind := AKind;
  Parts[N].Text := AText;
  Parts[N].Quoted := AQuoted;
end;

procedure TPartBuilder.AddLiteral(const AText: string; AQuoted: Boolean);
var
  N: Integer;
begin
  if AText = '' then
    Exit;
  N := Length(Parts);
  if (N > 0) and (Parts[N - 1].Kind = wpLiteral) and
    (Parts[N - 1].Quoted = AQuoted) then
  begin
    Parts[N - 1].Text := Parts[N - 1].Text + AText;
    Exit;
  end;
  AddPart(wpLiteral, AText, AQuoted);
end;

function IsNameStart(C: Char): Boolean;
begin
  Result := (C = '_') or ((C >= 'A') and (C <= 'Z')) or
    ((C >= 'a') and (C <= 'z'));
end;

function IsNameChar(C: Char): Boolean;
begin
  Result := IsNameStart(C) or ((C >= '0') and (C <= '9'));
end;

function IsIdentifier(const S: string): Boolean;
var
  I: Integer;
begin
  Result := (S <> '') and IsNameStart(S[1]);
  if not Result then
    Exit;
  for I := 2 to Length(S) do
    if not IsNameChar(S[I]) then
      Exit(False);
end;

{ True when the brace at AStart begins an unquoted brace expansion: a matching
  close with a top-level comma inside. }
function IsBraceExpansion(const S: string; AStart: Integer): Boolean;
var
  J, Depth: Integer;
  HasComma: Boolean;
begin
  Result := False;
  HasComma := False;
  Depth := 0;
  J := AStart;
  while J <= Length(S) do
  begin
    if S[J] = '\' then
      Inc(J)
    else if S[J] = '{' then
      Inc(Depth)
    else if S[J] = '}' then
    begin
      Dec(Depth);
      if Depth = 0 then
        Exit(HasComma);
    end
    else if (S[J] = ',') and (Depth = 1) then
      HasComma := True;
    Inc(J);
  end;
end;

function ParseWordParts(const ARaw: string; ABaseOffset, ABaseLine, ABaseCol: Integer;
  out AParts: TWordPartArray; out AError: TShellParseError): Boolean;
var
  B: TPartBuilder;
  I, N: Integer;
  State: (wsNone, wsDouble);
  Literal: string;
  C: Char;

  procedure FailAt(AOffsetInRaw: Integer; const AMsg: string);
  var
    J, L, Col: Integer;
  begin
    L := ABaseLine;
    Col := ABaseCol;
    for J := 1 to AOffsetInRaw - 1 do
    begin
      if ARaw[J] = #10 then
      begin
        Inc(L);
        Col := 1;
      end
      else
        Inc(Col);
    end;
    AError := Default(TShellParseError);
    AError.Offset := ABaseOffset + AOffsetInRaw - 1;
    AError.Line := L;
    AError.Column := Col;
    AError.Message := AMsg;
    Result := False;
  end;

  procedure FlushLiteral;
  begin
    if Literal <> '' then
    begin
      B.AddLiteral(Literal, State <> wsNone);
      Literal := '';
    end;
  end;

  { Parse a parameter expansion: only a plain name is v1. Returns the index
    past the closing brace. }
  function ParseBrace(AStart: Integer; out AName: string; out ANext: Integer): Boolean;
  var
    J, Depth: Integer;
    Inner: string;
  begin
    AName := '';
    J := AStart + 1;
    Depth := 1;
    while (J <= Length(ARaw)) and (Depth > 0) do
    begin
      if ARaw[J] = '{' then
        Inc(Depth)
      else if ARaw[J] = '}' then
        Dec(Depth);
      if Depth > 0 then
        Inc(J);
    end;
    if Depth <> 0 then
    begin
      FailAt(AStart, 'unterminated ${');
      Exit(False);
    end;
    Inner := Copy(ARaw, AStart + 1, J - AStart - 1);
    if not IsIdentifier(Inner) then
    begin
      FailAt(AStart, '${...} operators are not supported');
      Exit(False);
    end;
    AName := Inner;
    ANext := J + 1;
    Result := True;
  end;

  { Parse $NAME / $? / $1 / $( ... (the last errors). Returns past the construct. }
  function ParseDollar(AStart: Integer; AQuoted: Boolean; out ANext: Integer): Boolean;
  var
    J: Integer;
    Name: string;
    Spec: Char;
  begin
    ANext := AStart + 1;
    if AStart >= Length(ARaw) then
    begin
      B.AddLiteral('$', AQuoted);
      Result := True;
      Exit;
    end;
    C := ARaw[AStart + 1];
    if C = '(' then
    begin
      FailAt(AStart, 'command substitution is not supported');
      Exit(False);
    end;
    if C = '{' then
    begin
      if not ParseBrace(AStart + 1, Name, ANext) then
        Exit(False);
      B.AddPart(wpVariable, Name, AQuoted);
      Result := True;
      Exit;
    end;
    if C = '''' then
    begin
      FailAt(AStart, 'ANSI-C quoting is not supported');
      Exit(False);
    end;
    if C = '"' then
    begin
      B.AddLiteral('$', AQuoted);
      Result := True;
      Exit;
    end;
    if (C >= '0') and (C <= '9') then
    begin
      B.AddPart(wpSpecial, C, AQuoted);
      ANext := AStart + 2;
      Result := True;
      Exit;
    end;
    if C = '@' then Spec := '@'
    else if C = '*' then Spec := '*'
    else if C = '#' then Spec := '#'
    else if C = '?' then Spec := '?'
    else if C = '$' then Spec := '$'
    else if C = '!' then Spec := '!'
    else if C = '-' then Spec := '-'
    else Spec := #0;
    if Spec <> #0 then
    begin
      B.AddPart(wpSpecial, Spec, AQuoted);
      ANext := AStart + 2;
      Result := True;
      Exit;
    end;
    if IsNameStart(C) then
    begin
      J := AStart + 1;
      while (J <= Length(ARaw)) and IsNameChar(ARaw[J]) do
        Inc(J);
      B.AddPart(wpVariable, Copy(ARaw, AStart + 1, J - AStart - 1), AQuoted);
      ANext := J;
      Result := True;
      Exit;
    end;
    { A lone '$' is literal. }
    B.AddLiteral('$', AQuoted);
    Result := True;
  end;

begin
  AParts := nil;
  AError := Default(TShellParseError);
  B.Parts := nil;
  Literal := '';
  State := wsNone;
  I := 1;
  while I <= Length(ARaw) do
  begin
    C := ARaw[I];
    if State = wsNone then
    begin
      if C = '''' then
      begin
        FlushLiteral;
        Inc(I);
        N := I;
        while (I <= Length(ARaw)) and (ARaw[I] <> '''') do
          Inc(I);
        if I > Length(ARaw) then
        begin
          FailAt(N - 1, 'unterminated single quote');
          Exit(False);
        end;
        B.AddLiteral(Copy(ARaw, N, I - N), True);
        Inc(I);
      end
      else if C = '"' then
      begin
        FlushLiteral;
        State := wsDouble;
        Inc(I);
      end
      else if C = '\' then
      begin
        Inc(I);
        if I <= Length(ARaw) then
        begin
          B.AddLiteral(ARaw[I], True);
          Inc(I);
        end
        else
          B.AddLiteral('\', True);
      end
      else if C = '$' then
      begin
        FlushLiteral;
        if not ParseDollar(I, False, N) then
          Exit(False);
        I := N;
      end
      else if C = '`' then
      begin
        FailAt(I, 'backquote command substitution is not supported');
        Exit(False);
      end
      else if (C = '~') and (I = 1) and
        ((Length(ARaw) = 1) or (ARaw[2] = '/')) then
      begin
        FlushLiteral;
        B.AddPart(wpTilde, '~', False);
        Inc(I);
      end
      else if (C = '*') or (C = '?') then
      begin
        FlushLiteral;
        B.AddPart(wpGlob, C, False);
        Inc(I);
      end
      else if C = '[' then
      begin
        N := I + 1;
        while (N <= Length(ARaw)) and (ARaw[N] <> ']') do
          Inc(N);
        if N <= Length(ARaw) then
        begin
          FlushLiteral;
          B.AddPart(wpGlob, Copy(ARaw, I, N - I + 1), False);
          I := N + 1;
        end
        else
        begin
          Literal := Literal + C;
          Inc(I);
        end;
      end
      else if (C = '{') and IsBraceExpansion(ARaw, I) then
      begin
        FailAt(I, 'brace expansion is not supported');
        Exit(False);
      end
      else
      begin
        Literal := Literal + C;
        Inc(I);
      end;
    end
    else
    begin
      { Double-quoted. }
      if C = '"' then
      begin
        FlushLiteral;
        State := wsNone;
        Inc(I);
      end
      else if C = '\' then
      begin
        Inc(I);
        if I <= Length(ARaw) then
        begin
          if ARaw[I] in ['$', '`', '"', '\'] then
          begin
            B.AddLiteral(ARaw[I], True);
            Inc(I);
          end
          else
          begin
            Literal := Literal + '\';
            { The next char is handled normally on the next iteration. }
          end;
        end
        else
          Literal := Literal + '\';
      end
      else if C = '$' then
      begin
        FlushLiteral;
        if not ParseDollar(I, True, N) then
          Exit(False);
        I := N;
      end
      else if C = '`' then
      begin
        FailAt(I, 'backquote command substitution is not supported');
        Exit(False);
      end
      else
      begin
        Literal := Literal + C;
        Inc(I);
      end;
    end;
  end;
  FlushLiteral;
  AParts := B.Parts;
  Result := True;
end;

function SplitAssignment(const ARaw: string; out AName, ARawValue: string): Boolean;
var
  P, I: Integer;
begin
  AName := '';
  ARawValue := '';
  Result := False;
  P := Pos('=', ARaw);
  if P < 2 then
    Exit;
  if not IsNameStart(ARaw[1]) then
    Exit;
  for I := 2 to P - 1 do
    if not IsNameChar(ARaw[I]) then
      Exit;
  AName := Copy(ARaw, 1, P - 1);
  ARawValue := Copy(ARaw, P + 1, MaxInt);
  Result := True;
end;

end.
