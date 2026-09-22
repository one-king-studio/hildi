unit hildegard.helper.tui.input.decode;
{ A pure decoder from raw terminal bytes to TInputEvent keys.

  Deliberately terminal-free (no termio/baseunix): bytes are fed in and events
  come out, so the mapping is unit-tested without a pty. The terminal adapter
  reads bytes and calls Feed/Next.

  Supports: printable ASCII, UTF-8 (up to 4 bytes, surrogate pairs for
  non-BMP), enter/tab/backspace/escape, Ctrl+letter, CSI/SS3 arrows, home/end,
  page up/down, delete, and F1-F12, with xterm modifier parameters. Incomplete
  sequences stay buffered until more bytes arrive. }

{$mode delphi}{$H+}

interface

uses
  hildegard.helper.tui.base, hildegard.helper.tui.input;

type
  TKeyDecoder = class
  private
    FBuf: array of Byte;
    procedure Drop(N: Integer);
    function ParseMods(const AParams: string): TModifiers;
    function MapFinal(AFinal: AnsiChar; const AParams: string;
      out AEvent: TInputEvent): Boolean;
    function MapTilde(const AParams: string; out AEvent: TInputEvent): Boolean;
    function MapMouse(const AParams: string; ARelease: Boolean;
      out AEvent: TInputEvent): Boolean;
  public
    procedure Feed(const AData: array of Byte);
    function Next(out AEvent: TInputEvent): Boolean;
    function Buffered: Integer;
  end;

implementation

uses
  SysUtils;

procedure TKeyDecoder.Feed(const AData: array of Byte);
var
  I, N: Integer;
begin
  N := Length(FBuf);
  SetLength(FBuf, N + Length(AData));
  for I := 0 to High(AData) do
    FBuf[N + I] := AData[I];
end;

procedure TKeyDecoder.Drop(N: Integer);
var
  I: Integer;
begin
  for I := 0 to Length(FBuf) - N - 1 do
    FBuf[I] := FBuf[I + N];
  SetLength(FBuf, Length(FBuf) - N);
end;

function TKeyDecoder.Buffered: Integer;
begin
  Result := Length(FBuf);
end;

function TKeyDecoder.ParseMods(const AParams: string): TModifiers;
var
  P, M: Integer;
begin
  Result := [];
  P := Pos(';', AParams);
  if P = 0 then
    Exit;
  M := StrToIntDef(Copy(AParams, P + 1, MaxInt), 1);
  if M < 1 then
    Exit;
  Dec(M);
  if (M and 1) <> 0 then
    Include(Result, moShift);
  if (M and 2) <> 0 then
    Include(Result, moAlt);
  if (M and 4) <> 0 then
    Include(Result, moCtrl);
end;

function TKeyDecoder.MapFinal(AFinal: AnsiChar; const AParams: string;
  out AEvent: TInputEvent): Boolean;
begin
  AEvent := Default(TInputEvent);
  AEvent.Kind := ikKey;
  AEvent.Key.Mods := ParseMods(AParams);
  Result := True;
  case AFinal of
    'A':
      AEvent.Key.Kind := kkUp;
    'B':
      AEvent.Key.Kind := kkDown;
    'C':
      AEvent.Key.Kind := kkRight;
    'D':
      AEvent.Key.Kind := kkLeft;
    'H':
      AEvent.Key.Kind := kkHome;
    'F':
      AEvent.Key.Kind := kkEnd;
    'Z':
      begin
        AEvent.Key.Kind := kkTab;
        Include(AEvent.Key.Mods, moShift);
      end;
    'P':
      begin
        AEvent.Key.Kind := kkFunction;
        AEvent.Key.FuncIndex := 1;
      end;
    'Q':
      begin
        AEvent.Key.Kind := kkFunction;
        AEvent.Key.FuncIndex := 2;
      end;
    'R':
      begin
        AEvent.Key.Kind := kkFunction;
        AEvent.Key.FuncIndex := 3;
      end;
    'S':
      begin
        AEvent.Key.Kind := kkFunction;
        AEvent.Key.FuncIndex := 4;
      end;
    '~':
      Result := MapTilde(AParams, AEvent);
    'M', 'm':
      Result := MapMouse(AParams, AFinal = 'm', AEvent);
  else
    Result := False;
  end;
end;

function TKeyDecoder.MapMouse(const AParams: string; ARelease: Boolean;
  out AEvent: TInputEvent): Boolean;
var
  S, T: string;
  Cb, Cx, Cy, P: Integer;
begin
  AEvent := Default(TInputEvent);
  Result := False;
  S := AParams;
  if (S = '') or (S[1] <> '<') then
    Exit;
  S := Copy(S, 2, MaxInt);
  P := Pos(';', S);
  if P = 0 then
    Exit;
  Cb := StrToIntDef(Copy(S, 1, P - 1), 0);
  T := Copy(S, P + 1, MaxInt);
  P := Pos(';', T);
  if P = 0 then
    Exit;
  Cx := StrToIntDef(Copy(T, 1, P - 1), 0);
  Cy := StrToIntDef(Copy(T, P + 1, MaxInt), 0);
  if (Cx <= 0) or (Cy <= 0) then
    Exit;
  AEvent.Kind := ikMouse;
  AEvent.Mouse.X := Cx - 1;
  AEvent.Mouse.Y := Cy - 1;
  if (Cb and 64) <> 0 then
  begin
    if (Cb and 1) = 0 then
      AEvent.Mouse.Button := mbWheelUp
    else
      AEvent.Mouse.Button := mbWheelDown;
  end
  else
    case Cb and 3 of
      0:
        AEvent.Mouse.Button := mbLeft;
      1:
        AEvent.Mouse.Button := mbMiddle;
      2:
        AEvent.Mouse.Button := mbRight;
    else
      AEvent.Mouse.Button := mbNone;
    end;
  if ARelease then
    AEvent.Mouse.Button := mbNone;
  Result := True;
end;

function TKeyDecoder.MapTilde(const AParams: string;
  out AEvent: TInputEvent): Boolean;
var
  Num: Integer;
  S: string;
  P: Integer;
begin
  Result := True;
  S := AParams;
  P := Pos(';', S);
  if P > 0 then
    S := Copy(S, 1, P - 1);
  Num := StrToIntDef(S, 0);
  case Num of
    1, 7:
      AEvent.Key.Kind := kkHome;
    4, 8:
      AEvent.Key.Kind := kkEnd;
    2:
      AEvent.Key.Kind := kkNone;
    3:
      AEvent.Key.Kind := kkDelete;
    5:
      AEvent.Key.Kind := kkPageUp;
    6:
      AEvent.Key.Kind := kkPageDown;
    11:
      begin
        AEvent.Key.Kind := kkFunction;
        AEvent.Key.FuncIndex := 1;
      end;
    12:
      begin
        AEvent.Key.Kind := kkFunction;
        AEvent.Key.FuncIndex := 2;
      end;
    13:
      begin
        AEvent.Key.Kind := kkFunction;
        AEvent.Key.FuncIndex := 3;
      end;
    14:
      begin
        AEvent.Key.Kind := kkFunction;
        AEvent.Key.FuncIndex := 4;
      end;
    15:
      begin
        AEvent.Key.Kind := kkFunction;
        AEvent.Key.FuncIndex := 5;
      end;
    17:
      begin
        AEvent.Key.Kind := kkFunction;
        AEvent.Key.FuncIndex := 6;
      end;
    18:
      begin
        AEvent.Key.Kind := kkFunction;
        AEvent.Key.FuncIndex := 7;
      end;
    19:
      begin
        AEvent.Key.Kind := kkFunction;
        AEvent.Key.FuncIndex := 8;
      end;
    20:
      begin
        AEvent.Key.Kind := kkFunction;
        AEvent.Key.FuncIndex := 9;
      end;
    21:
      begin
        AEvent.Key.Kind := kkFunction;
        AEvent.Key.FuncIndex := 10;
      end;
    23:
      begin
        AEvent.Key.Kind := kkFunction;
        AEvent.Key.FuncIndex := 11;
      end;
    24:
      begin
        AEvent.Key.Kind := kkFunction;
        AEvent.Key.FuncIndex := 12;
      end;
  else
    Result := False;
  end;
end;

function TKeyDecoder.Next(out AEvent: TInputEvent): Boolean;
var
  B: Byte;
  I, FinalIdx, N, CP, CP2: Integer;
  Params: string;
  Ch: UnicodeString;
begin
  AEvent := Default(TInputEvent);
  Result := False;
  if Length(FBuf) = 0 then
    Exit;

  B := FBuf[0];

  if B = 27 then
  begin
    if Length(FBuf) = 1 then
    begin
      AEvent.Kind := ikKey;
      AEvent.Key.Kind := kkEscape;
      Drop(1);
      Exit(True);
    end;
    if (FBuf[1] = Ord('[')) or (FBuf[1] = Ord('O')) then
    begin
      FinalIdx := -1;
      for I := 2 to High(FBuf) do
        if (FBuf[I] >= $40) and (FBuf[I] <= $7E) then
        begin
          FinalIdx := I;
          Break;
        end;
      if FinalIdx < 0 then
        Exit(False);  { wait for the rest of the sequence }
      Params := '';
      for I := 2 to FinalIdx - 1 do
        Params := Params + AnsiChar(FBuf[I]);
      if MapFinal(AnsiChar(FBuf[FinalIdx]), Params, AEvent) then
      begin
        Drop(FinalIdx + 1);
        Exit(True);
      end;
      { Unknown sequence (terminal reports, focus events, unsupported keys):
        consume the whole thing so its bytes are not decoded as characters, then
        try the next buffered event. }
      Drop(FinalIdx + 1);
      Exit(Next(AEvent));
    end;
    AEvent.Kind := ikKey;
    AEvent.Key.Kind := kkEscape;
    Drop(1);
    Exit(True);
  end;

  if (B = 13) or (B = 10) then
  begin
    AEvent.Kind := ikKey;
    AEvent.Key.Kind := kkEnter;
    Drop(1);
    Exit(True);
  end;
  if B = 9 then
  begin
    AEvent.Kind := ikKey;
    AEvent.Key.Kind := kkTab;
    Drop(1);
    Exit(True);
  end;
  if (B = 8) or (B = 127) then
  begin
    AEvent.Kind := ikKey;
    AEvent.Key.Kind := kkBackspace;
    Drop(1);
    Exit(True);
  end;
  if (B >= 1) and (B <= 26) then
  begin
    AEvent.Kind := ikKey;
    AEvent.Key.Kind := kkChar;
    AEvent.Key.Ch := UnicodeString(AnsiChar(Ord('a') + B - 1));
    AEvent.Key.Mods := [moCtrl];
    Drop(1);
    Exit(True);
  end;
  if B < 32 then
  begin
    Drop(1);  { ignore other control characters }
    Exit(Next(AEvent));
  end;

  if B < 127 then
  begin
    AEvent.Kind := ikKey;
    AEvent.Key.Kind := kkChar;
    AEvent.Key.Ch := UnicodeString(AnsiChar(B));
    Drop(1);
    Exit(True);
  end;

  { UTF-8 }
  if (B and $E0) = $C0 then
    N := 2
  else if (B and $F0) = $E0 then
    N := 3
  else if (B and $F8) = $F0 then
    N := 4
  else
  begin
    Drop(1);  { invalid lead byte }
    Exit(Next(AEvent));
  end;
  if Length(FBuf) < N then
    Exit(False);
  case N of
    2:
      CP := ((B and $1F) shl 6) or (FBuf[1] and $3F);
    3:
      CP := ((B and $0F) shl 12) or ((FBuf[1] and $3F) shl 6) or
        (FBuf[2] and $3F);
  else
    CP := ((B and $07) shl 18) or ((FBuf[1] and $3F) shl 12) or
      ((FBuf[2] and $3F) shl 6) or (FBuf[3] and $3F);
  end;
  if CP > $FFFF then
  begin
    CP2 := CP - $10000;
    Ch := UnicodeString(WideChar($D800 + (CP2 shr 10))) +
      WideChar($DC00 + (CP2 and $3FF));
  end
  else
    Ch := UnicodeString(WideChar(CP));
  AEvent.Kind := ikKey;
  AEvent.Key.Kind := kkChar;
  AEvent.Key.Ch := Ch;
  Drop(N);
  Result := True;
end;

end.
