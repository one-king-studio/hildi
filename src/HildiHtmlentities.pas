unit HildiHtmlentities;
{ Models often write HTML entities in tool arguments — &lt;, &gt;, &amp; —
  because they assume the text will be rendered as markdown, not handed to a
  shell. The shell then sees the entity as literal text.

  Decode the common set once, before the command is parsed: `echo a &lt; b`
  means `echo a < b`, and `cat f &gt;&gt; log` appends.

  An entity preceded by a backslash is left alone, so the literal search still
  has a spelling: `grep '\&lt;' file` keeps `&lt;` (the shell turns `\&` into
  `&`). Numeric entities (&#65;, &#x41;) decode to UTF-8. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes;

function DecodeHtmlEntities(const S: string): string;

implementation

function Utf8Of(const ACode: LongWord): string;
var
  B: Byte;
begin
  Result := '';
  if ACode < $80 then
    Result := Chr(ACode)
  else if ACode < $800 then
  begin
    B := $C0 or (ACode shr 6);
    Result := Chr(B);
    B := $80 or (ACode and $3F);
    Result := Result + Chr(B);
  end
  else if ACode < $10000 then
  begin
    B := $E0 or (ACode shr 12);
    Result := Chr(B);
    B := $80 or ((ACode shr 6) and $3F);
    Result := Result + Chr(B);
    B := $80 or (ACode and $3F);
    Result := Result + Chr(B);
  end
  else
  begin
    B := $F0 or (ACode shr 18);
    Result := Chr(B);
    B := $80 or ((ACode shr 12) and $3F);
    Result := Result + Chr(B);
    B := $80 or ((ACode shr 6) and $3F);
    Result := Result + Chr(B);
    B := $80 or (ACode and $3F);
    Result := Result + Chr(B);
  end;
end;

function NamedEntity(const AName: string; out AValue: string): Boolean;
begin
  Result := True;
  if AName = 'amp' then
    AValue := '&'
  else if AName = 'lt' then
    AValue := '<'
  else if AName = 'gt' then
    AValue := '>'
  else if AName = 'quot' then
    AValue := '"'
  else if AName = 'apos' then
    AValue := ''''
  else if AName = 'nbsp' then
    AValue := Utf8Of($00A0)
  else
    Result := False;
end;

function NumericEntity(const AName: string; out AValue: string): Boolean;
var
  Code: LongWord;
  I: Integer;
  Digits: string;
  Digit: Integer;
begin
  Result := False;
  AValue := '';
  if (AName = '') or (AName[1] <> '#') then
    Exit;
  if (Length(AName) > 1) and ((AName[2] = 'x') or (AName[2] = 'X')) then
  begin
    Digits := Copy(AName, 3, MaxInt);
    if Digits = '' then
      Exit;
    Code := 0;
    for I := 1 to Length(Digits) do
    begin
      if Digits[I] in ['0'..'9'] then
        Digit := Ord(Digits[I]) - Ord('0')
      else if Digits[I] in ['a'..'f'] then
        Digit := Ord(Digits[I]) - Ord('a') + 10
      else if Digits[I] in ['A'..'F'] then
        Digit := Ord(Digits[I]) - Ord('A') + 10
      else
        Exit;
      Code := Code * 16 + LongWord(Digit);
      if Code > $10FFFF then
        Exit;
    end;
  end
  else
  begin
    Digits := Copy(AName, 2, MaxInt);
    if Digits = '' then
      Exit;
    Code := 0;
    for I := 1 to Length(Digits) do
    begin
      if not (Digits[I] in ['0'..'9']) then
        Exit;
      Code := Code * 10 + LongWord(Ord(Digits[I]) - Ord('0'));
      if Code > $10FFFF then
        Exit;
    end;
  end;
  if (Code = 0) or (Code > $10FFFF) then
    Exit;
  AValue := Utf8Of(Code);
  Result := True;
end;

function DecodeHtmlEntities(const S: string): string;
var
  I, J: Integer;
  Name, Value: string;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if (S[I] = '&') and ((I = 1) or (S[I - 1] <> '\')) then
    begin
      J := I + 1;
      while (J <= Length(S)) and
        (S[J] in ['a'..'z', 'A'..'Z', '0'..'9', '#']) do
        Inc(J);
      if (J <= Length(S)) and (S[J] = ';') and (J > I + 1) then
      begin
        Name := Copy(S, I + 1, J - I - 1);
        if NamedEntity(Name, Value) or NumericEntity(Name, Value) then
        begin
          Result := Result + Value;
          I := J + 1;
          Continue;
        end;
      end;
    end;
    Result := Result + S[I];
    Inc(I);
  end;
end;

end.
