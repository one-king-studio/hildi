unit hildegard.helper.shell.textcmd;
{ Pure text transforms for the builtin shell tier: cut, tr and printf.

  No filesystem and no OS units — string in, string out, so they behave the
  same on every platform (the Windows target included). The command handlers
  do the file/stdin plumbing. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes;

type
  TPosSet = array of Boolean;

{ cut. AChars selects by character position instead of field; ADelim is the
  field delimiter ('' = TAB); AFields is a list like "1,3-5,7-". ASuppress
  drops lines that contain no delimiter (field mode only). }
function CutText(const AInput, ADelim, AFields: string; AHasDelim, AChars,
  ASuppress: Boolean; out AOutput, AError: string): Boolean;

{ tr. ADelete removes Set1's characters; ASqueeze collapses runs of Set2 (or
  Set1 when Set2 is empty); otherwise Set1 maps to Set2. }
function TrText(const AInput, ASet1, ASet2: string; ADelete, ASqueeze: Boolean;
  out AOutput, AError: string): Boolean;

{ printf. Supports %s, %d, %i, %% and the \n \t \r \\ escapes; the format is
  reused while arguments remain (POSIX). }
function PrintfText(const AFormat: string; const AArgs: TStringArray;
  out AOutput, AError: string): Boolean;

{ The escape/range expansion tr and printf share (e.g. "a-z", "\t"). }
function ExpandSet(const ASet: string): string;

implementation

function LinesOf(const S: string): TStringArray;
var
  I, N, K: Integer;
begin
  Result := nil;
  K := 0;
  I := 1;
  while I <= Length(S) do
  begin
    N := I;
    while (N <= Length(S)) and (S[N] <> #10) do
      Inc(N);
    SetLength(Result, K + 1);
    Result[K] := Copy(S, I, N - I);
    Inc(K);
    I := N + 1;
  end;
end;

function ExpandSet(const ASet: string): string;
var
  I: Integer;
  C, D, X: Char;
begin
  Result := '';
  I := 1;
  while I <= Length(ASet) do
  begin
    if ASet[I] = '\' then
    begin
      Inc(I);
      if I > Length(ASet) then
      begin
        Result := Result + '\';
        Break;
      end;
      case ASet[I] of
        'n': Result := Result + #10;
        't': Result := Result + #9;
        'r': Result := Result + #13;
        '\': Result := Result + '\';
      else
        Result := Result + ASet[I];
      end;
      Inc(I);
    end
    else if (I + 2 <= Length(ASet)) and (ASet[I + 1] = '-') then
    begin
      C := ASet[I];
      D := ASet[I + 2];
      if C <= D then
      begin
        X := C;
        while True do
        begin
          Result := Result + X;
          if X = D then
            Break;
          Inc(X);
        end;
      end;
      Inc(I, 3);
    end
    else
    begin
      Result := Result + ASet[I];
      Inc(I);
    end;
  end;
end;

{ "1,3-5,7-" -> the selected 1-based positions. }
function ParsePositions(const ASpec: string; out ASel: TPosSet;
  out ACount: Integer; out AError: string): Boolean;
var
  I, N, Lo, Hi, MaxHi, K: Integer;
  Part: string;
  Los, His: array of Integer;

  function ToInt(const S: string): Integer;
  begin
    Result := StrToIntDef(Trim(S), -1);
  end;

  procedure Add(ALo, AHi: Integer);
  var
    L: Integer;
  begin
    if ALo < 1 then
      ALo := 1;
    if AHi < ALo then
      Exit;
    L := Length(Los);
    SetLength(Los, L + 1);
    SetLength(His, L + 1);
    Los[L] := ALo;
    His[L] := AHi;
    if AHi > MaxHi then
      MaxHi := AHi;
  end;

  function SplitRange(const APart: string): Boolean;
  var
    Dash, L, H: Integer;
  begin
    Result := False;
    Dash := Pos('-', APart);
    if Dash = 0 then
    begin
      L := ToInt(APart);
      if L < 1 then
      begin
        AError := 'invalid position: ' + APart;
        Exit;
      end;
      Add(L, L);
      Exit(True);
    end;
    if Dash = 1 then
      L := 1
    else
    begin
      L := ToInt(Copy(APart, 1, Dash - 1));
      if L < 1 then
      begin
        AError := 'invalid range: ' + APart;
        Exit;
      end;
    end;
    if Dash = Length(APart) then
      H := 1000000
    else
    begin
      H := ToInt(Copy(APart, Dash + 1, MaxInt));
      if H < L then
      begin
        AError := 'invalid range: ' + APart;
        Exit;
      end;
    end;
    Add(L, H);
    Result := True;
  end;

begin
  AError := '';
  ACount := 0;
  MaxHi := 0;
  Los := nil;
  His := nil;
  I := 1;
  while I <= Length(ASpec) + 1 do
  begin
    N := I;
    while (N <= Length(ASpec)) and (ASpec[N] <> ',') do
      Inc(N);
    Part := Trim(Copy(ASpec, I, N - I));
    if (Part <> '') and (not SplitRange(Part)) then
      Exit(False);
    I := N + 1;
    if N > Length(ASpec) then
      Break;
  end;
  if MaxHi = 0 then
  begin
    AError := 'no positions selected';
    Exit(False);
  end;
  if MaxHi > 1000000 then
    MaxHi := 1000000;
  ACount := MaxHi;
  SetLength(ASel, MaxHi);
  for K := 0 to High(Los) do
    for I := Los[K] to His[K] do
      if I <= MaxHi then
        ASel[I - 1] := True;
  Result := True;
end;

function CutText(const AInput, ADelim, AFields: string; AHasDelim, AChars,
  ASuppress: Boolean; out AOutput, AError: string): Boolean;
var
  Lines, Fields: TStringArray;
  Selected: TPosSet;
  Count, I, J, K, N: Integer;
  Sep, Line, Piece: string;
  HasSep: Boolean;
begin
  AOutput := '';
  AError := '';
  if not ParsePositions(AFields, Selected, Count, AError) then
    Exit(False);
  if AHasDelim then
    Sep := ADelim
  else
    Sep := #9;
  Lines := LinesOf(AInput);
  for I := 0 to High(Lines) do
  begin
    Line := Lines[I];
    if AChars then
    begin
      Piece := '';
      for J := 1 to Length(Line) do
        if (J <= High(Selected) + 1) and Selected[J - 1] then
          Piece := Piece + Line[J];
      AOutput := AOutput + Piece + #10;
      Continue;
    end;
    Fields := nil;
    K := 0;
    N := 1;
    HasSep := False;
    while True do
    begin
      J := N;
      while (J <= Length(Line)) and (Line[J] <> Sep[1]) do
        Inc(J);
      SetLength(Fields, K + 1);
      Fields[K] := Copy(Line, N, J - N);
      Inc(K);
      if J <= Length(Line) then
        HasSep := True;
      if J > Length(Line) then
        Break;
      N := J + 1;
    end;
    if ASuppress and (not HasSep) then
      Continue;
    Piece := '';
    for J := 1 to High(Selected) + 1 do
      if Selected[J - 1] then
      begin
        if Piece <> '' then
          Piece := Piece + Sep;
        if J <= Length(Fields) then
          Piece := Piece + Fields[J - 1];
      end;
    AOutput := AOutput + Piece + #10;
  end;
  Result := True;
end;

function TrText(const AInput, ASet1, ASet2: string; ADelete, ASqueeze: Boolean;
  out AOutput, AError: string): Boolean;
var
  S1, S2, SqueezeSet: string;
  I, Idx: Integer;
  C, Mapped, Last: Char;
  HasLast: Boolean;
begin
  AOutput := '';
  AError := '';
  S1 := ExpandSet(ASet1);
  S2 := ExpandSet(ASet2);
  if ADelete then
  begin
    if S2 <> '' then
      SqueezeSet := S2
    else
      SqueezeSet := S1;
  end
  else
  begin
    if (S1 = '') and (not ASqueeze) then
    begin
      AError := 'missing operand';
      Exit(False);
    end;
    if (S2 = '') and (not ASqueeze) then
    begin
      AError := 'two sets are required without -d/-s';
      Exit(False);
    end;
    { -s with one set squeezes that set; with two, the second. }
    if S2 = '' then
      SqueezeSet := S1
    else
      SqueezeSet := S2;
  end;
  HasLast := False;
  Last := #0;
  for I := 1 to Length(AInput) do
  begin
    C := AInput[I];
    if ADelete then
    begin
      if Pos(C, S1) > 0 then
        Continue;
      Mapped := C;
    end
    else if S2 = '' then
      Mapped := C
    else
    begin
      Idx := Pos(C, S1);
      if Idx = 0 then
        Mapped := C
      else if Idx <= Length(S2) then
        Mapped := S2[Idx]
      else
        Mapped := S2[Length(S2)];
    end;
    if ASqueeze and (SqueezeSet <> '') and (Pos(Mapped, SqueezeSet) > 0) and
      HasLast and (Mapped = Last) then
      Continue;
    AOutput := AOutput + Mapped;
    Last := Mapped;
    HasLast := True;
  end;
  Result := True;
end;

function PrintfText(const AFormat: string; const AArgs: TStringArray;
  out AOutput, AError: string): Boolean;
var
  ArgIndex: Integer;

  function Render(out AUsedConversion: Boolean): Boolean;
  var
    I: Integer;
    C: Char;
    S: string;
  begin
    AUsedConversion := False;
    S := '';
    I := 1;
    while I <= Length(AFormat) do
    begin
      C := AFormat[I];
      if C = '\' then
      begin
        Inc(I);
        if I > Length(AFormat) then
        begin
          S := S + '\';
          Break;
        end;
        case AFormat[I] of
          'n': S := S + #10;
          't': S := S + #9;
          'r': S := S + #13;
          '\': S := S + '\';
        else
          S := S + AFormat[I];
        end;
        Inc(I);
      end
      else if C = '%' then
      begin
        Inc(I);
        if I > Length(AFormat) then
          Break;
        case AFormat[I] of
          '%': S := S + '%';
          's':
            begin
              if ArgIndex < Length(AArgs) then
                S := S + AArgs[ArgIndex];
              Inc(ArgIndex);
              AUsedConversion := True;
            end;
          'd', 'i':
            begin
              if ArgIndex < Length(AArgs) then
                S := S + IntToStr(StrToInt64Def(AArgs[ArgIndex], 0))
              else
                S := S + '0';
              Inc(ArgIndex);
              AUsedConversion := True;
            end;
        else
          AError := 'unsupported format directive: %' + AFormat[I];
          Exit(False);
        end;
        Inc(I);
      end
      else
      begin
        S := S + C;
        Inc(I);
      end;
    end;
    AOutput := AOutput + S;
    Result := True;
  end;

var
  Used: Boolean;
begin
  AOutput := '';
  AError := '';
  ArgIndex := 0;
  Result := Render(Used);
  if not Result then
    Exit;
  while Used and (ArgIndex < Length(AArgs)) do
  begin
    Result := Render(Used);
    if not Result then
      Exit;
  end;
  Result := True;
end;

end.
