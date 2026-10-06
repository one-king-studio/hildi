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
    function EventType(const AParams: string): Integer;
    function MapFinal(AFinal: AnsiChar; const AParams: string;
      out AEvent: TInputEvent): Boolean;
    function MapTilde(const AParams: string; out AEvent: TInputEvent): Boolean;
    function MapCSIu(const AParams: string; out AEvent: TInputEvent): Boolean;
    function MapMouse(const AParams: string; ARelease: Boolean;
      out AEvent: TInputEvent): Boolean;
  public
    procedure Feed(const AData: array of Byte);
    function Next(out AEvent: TInputEvent): Boolean;
    function Buffered: Integer;
  end;

  { Parse an OSC 11 background reply such as `]11;rgb:1e1e/1e1e/1e1e` into 8-bit
    channels (each channel is 1-4 hex digits). Returns False when the string is
    not a complete reply. Pure: the terminal adapter feeds it raw bytes. }
  function ParseOsc11Background(const S: string; out ARed, AGreen, ABlue: Byte):
    Boolean;

implementation

uses
  SysUtils;

function HexDigit(ACh: AnsiChar; out AValue: Integer): Boolean;
begin
  case ACh of
    '0'..'9':
      begin
        AValue := Ord(ACh) - Ord('0');
        Result := True;
      end;
    'a'..'f':
      begin
        AValue := Ord(ACh) - Ord('a') + 10;
        Result := True;
      end;
    'A'..'F':
      begin
        AValue := Ord(ACh) - Ord('A') + 10;
        Result := True;
      end;
  else
    AValue := 0;
    Result := False;
  end;
end;

{ Read 1-4 hex digits and scale them to 8 bits. }
function ReadHexChannel(const S: string; var I: Integer; out AValue: Byte): Boolean;
var
  V, D, Digits: Integer;
begin
  V := 0;
  Digits := 0;
  while (I <= Length(S)) and (Digits < 4) and HexDigit(S[I], D) do
  begin
    V := V * 16 + D;
    Inc(Digits);
    Inc(I);
  end;
  if Digits = 0 then
    Exit(False);
  AValue := Byte(V * 255 div ((1 shl (4 * Digits)) - 1));
  Result := True;
end;

function ParseOsc11Background(const S: string; out ARed, AGreen, ABlue: Byte):
  Boolean;
var
  P, I: Integer;
begin
  ARed := 0;
  AGreen := 0;
  ABlue := 0;
  Result := False;
  P := Pos(']11;', S);
  if P = 0 then
    Exit;
  I := P + 4;
  if Copy(S, I, 4) = 'rgb:' then
    Inc(I, 4)
  else
    Exit;
  if not ReadHexChannel(S, I, ARed) then
    Exit;
  if (I > Length(S)) or (S[I] <> '/') then
    Exit;
  Inc(I);
  if not ReadHexChannel(S, I, AGreen) then
    Exit;
  if (I > Length(S)) or (S[I] <> '/') then
    Exit;
  Inc(I);
  if not ReadHexChannel(S, I, ABlue) then
    Exit;
  Result := True;
end;

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
  P, Q, M: Integer;
  Mods: string;
begin
  Result := [];
  P := Pos(';', AParams);
  if P = 0 then
    Exit;
  Q := Pos(':', AParams);
  if Q > P then
    Mods := Copy(AParams, P + 1, Q - P - 1)
  else
    Mods := Copy(AParams, P + 1, MaxInt);
  M := StrToIntDef(Mods, 1);
  if M < 1 then
    Exit;
  Dec(M);
  if (M and 1) <> 0 then
    Include(Result, moShift);
  if (M and 2) <> 0 then
    Include(Result, moAlt);
  if (M and 4) <> 0 then
    Include(Result, moCtrl);
  if (M and 8) <> 0 then
    Include(Result, moSuper);
end;

{ The kitty event type: `mods:event` in the modifier field (1 press, 2 repeat,
  3 release). 0 when absent. }
function TKeyDecoder.EventType(const AParams: string): Integer;
var
  P, Q: Integer;
begin
  Result := 0;
  P := Pos(';', AParams);
  if P = 0 then
    Exit;
  Q := Pos(':', AParams);
  if Q <= P then
    Exit;
  Result := StrToIntDef(Copy(AParams, Q + 1, MaxInt), 0);
end;

function TKeyDecoder.MapFinal(AFinal: AnsiChar; const AParams: string;
  out AEvent: TInputEvent): Boolean;
begin
  AEvent := Default(TInputEvent);
  { Kitty reports event types in the modifier field (`mods:event`). A release
    (3) must not be decoded as another key: `CSI 1;1:3B` is the release of Down,
    and treating it as a press made one arrow tap move the selection twice. }
  if EventType(AParams) = 3 then
    Exit(False);
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
    'u':
      Result := MapCSIu(AParams, AEvent);
    { DECSET 1004 focus reporting: CSI I is focus in, CSI O is focus out. }
    'I':
      begin
        AEvent.Kind := ikFocus;
        AEvent.Focused := True;
      end;
    'O':
      begin
        AEvent.Kind := ikFocus;
        AEvent.Focused := False;
      end;
  else
    Result := False;
  end;
end;

function CodepointToUnicode(ACodepoint: Integer): UnicodeString;
begin
  if ACodepoint <= 0 then
    Exit('');
  if ACodepoint > $FFFF then
  begin
    Dec(ACodepoint, $10000);
    Result := UnicodeString(WideChar($D800 + (ACodepoint shr 10))) +
      WideChar($DC00 + (ACodepoint and $3FF));
  end
  else
    Result := UnicodeString(WideChar(ACodepoint));
end;

{ Associated text: colon-separated codepoints. Emit them all. }
function TextCodepointsToUnicode(const AField: string): UnicodeString;
var
  S, Part: string;
  P: Integer;
begin
  Result := '';
  S := AField;
  while S <> '' do
  begin
    P := Pos(':', S);
    if P > 0 then
    begin
      Part := Copy(S, 1, P - 1);
      S := Copy(S, P + 1, MaxInt);
    end
    else
    begin
      Part := S;
      S := '';
    end;
    Result := Result + CodepointToUnicode(StrToIntDef(Part, 0));
  end;
end;

function TKeyDecoder.MapCSIu(const AParams: string;
  out AEvent: TInputEvent): Boolean;
var
  KeyField, ModField, TextField, Tail, S: string;
  Base, Shifted, Mods, EventType, P, P2: Integer;
  ModsStr, EventStr: string;
  Ch: UnicodeString;
  HasText: Boolean;
begin
  { Kitty keyboard protocol:
      CSI unicode[:shifted[:base]] ; modifiers[:event] ; text u
    The codepoint is always the *unshifted* key (per the spec), so a shifted
    character (e.g. Shift+/ = '?') arrives as an alternate shifted codepoint or,
    when associated-text reporting is on, as the text field. Event 1=press,
    2=repeat, 3=release; releases are ignored. Mods bits are as the legacy forms
    (mods-1: 1=shift, 2=alt, 4=ctrl). }
  AEvent := Default(TInputEvent);
  Result := False;

  S := AParams;
  P := Pos(';', S);
  if P > 0 then
  begin
    KeyField := Copy(S, 1, P - 1);
    S := Copy(S, P + 1, MaxInt);
  end
  else
  begin
    KeyField := S;
    S := '';
  end;
  P := Pos(';', S);
  if P > 0 then
  begin
    ModField := Copy(S, 1, P - 1);
    TextField := Copy(S, P + 1, MaxInt);
  end
  else
  begin
    ModField := S;
    TextField := '';
  end;

  Base := 0;
  Shifted := 0;
  P := Pos(':', KeyField);
  if P > 0 then
  begin
    Base := StrToIntDef(Copy(KeyField, 1, P - 1), 0);
    Tail := Copy(KeyField, P + 1, MaxInt);
    P2 := Pos(':', Tail);
    if P2 > 0 then
      Shifted := StrToIntDef(Copy(Tail, 1, P2 - 1), 0)
    else
      Shifted := StrToIntDef(Tail, 0);
  end
  else
    Base := StrToIntDef(KeyField, 0);

  ModsStr := ModField;
  EventStr := '';
  P := Pos(':', ModField);
  if P > 0 then
  begin
    ModsStr := Copy(ModField, 1, P - 1);
    EventStr := Copy(ModField, P + 1, MaxInt);
  end;
  EventType := StrToIntDef(EventStr, 0);
  if EventType = 3 then
    Exit(False);

  if ModsStr <> '' then
    Mods := StrToIntDef(ModsStr, 1)
  else
    Mods := 1;
  if Mods < 1 then
    Mods := 1;
  Dec(Mods);

  AEvent.Kind := ikKey;
  if (Mods and 1) <> 0 then
    Include(AEvent.Key.Mods, moShift);
  if (Mods and 2) <> 0 then
    Include(AEvent.Key.Mods, moAlt);
  if (Mods and 4) <> 0 then
    Include(AEvent.Key.Mods, moCtrl);
  if (Mods and 8) <> 0 then
    Include(AEvent.Key.Mods, moSuper);

  { Special keys ignore any alternate/text fields. }
  case Base of
    13:
      begin
        AEvent.Key.Kind := kkEnter;
        Exit(True);
      end;
    9:
      begin
        AEvent.Key.Kind := kkTab;
        Exit(True);
      end;
    27:
      begin
        AEvent.Key.Kind := kkEscape;
        Exit(True);
      end;
    8, 127:
      begin
        AEvent.Key.Kind := kkBackspace;
        Exit(True);
      end;
  end;

  { Functional keys live in the Unicode Private Use Area (57344..63743) and have
    no character form. Modifier keys (Left Shift = 57441, ...) arrive here as
    press/repeat events; emitting them as characters produced a stray glyph
    rendered as '?'. Ignore the whole range. }
  if (Base >= 57344) and (Base <= 63743) then
    Exit(False);

  HasText := TextField <> '';
  Ch := '';
  if HasText then
    Ch := TextCodepointsToUnicode(TextField)
  else if ((Mods and 1) <> 0) and (Shifted > 0) then
    Ch := CodepointToUnicode(Shifted)
  else if Base >= 32 then
    Ch := CodepointToUnicode(Base)
  else if (Base >= 1) and (Base <= 26) then
  begin
    Ch := UnicodeString(AnsiChar(Ord('a') + Base - 1));
    Include(AEvent.Key.Mods, moCtrl);
  end;

  if Ch = '' then
    Exit(False);
  AEvent.Key.Kind := kkChar;
  AEvent.Key.Ch := Ch;
  Result := True;
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
  if EventType(AParams) = 3 then
    Exit(False);   { release: not another key }
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
  Raw: RawByteString;
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
    if FBuf[1] = Ord(']') then
    begin
      { OSC, e.g. the OSC 11 background reply (`ESC]11;rgb:...`). Consume it up
        to BEL or ST so its bytes are not decoded as stray characters; a bare
        ESC here is how a late reply used to leak into the UI and the shell. }
      FinalIdx := -1;
      for I := 2 to High(FBuf) do
        if FBuf[I] = 7 then
        begin
          FinalIdx := I;
          Break;
        end
        else if (FBuf[I] = 27) and (I < High(FBuf)) and
          (FBuf[I + 1] = Ord('\')) then
        begin
          FinalIdx := I + 1;
          Break;
        end;
      if FinalIdx < 0 then
        Exit(False);   { wait for the terminator }
      Drop(FinalIdx + 1);
      Exit(Next(AEvent));
    end;
    if (FBuf[1] = Ord('[')) or (FBuf[1] = Ord('O')) then
    begin
      { Bracketed paste: ESC [ 200 ~ <raw text> ESC [ 201 ~. The payload is
        handed over whole, so its newlines never decode as Enter and submit. }
      if (FBuf[1] = Ord('[')) and (Length(FBuf) >= 6) and
        (FBuf[2] = Ord('2')) and (FBuf[3] = Ord('0')) and
        (FBuf[4] = Ord('0')) and (FBuf[5] = Ord('~')) then
      begin
        FinalIdx := -1;
        I := 6;
        while I + 5 <= High(FBuf) do
        begin
          if (FBuf[I] = 27) and (FBuf[I + 1] = Ord('[')) and
            (FBuf[I + 2] = Ord('2')) and (FBuf[I + 3] = Ord('0')) and
            (FBuf[I + 4] = Ord('1')) and (FBuf[I + 5] = Ord('~')) then
          begin
            FinalIdx := I;
            Break;
          end;
          Inc(I);
        end;
        if FinalIdx < 0 then
          Exit(False);   { wait for the paste to finish }
        SetLength(Raw, FinalIdx - 6);
        for I := 0 to FinalIdx - 7 do
          Raw[I + 1] := AnsiChar(FBuf[6 + I]);
        AEvent.Kind := ikPaste;
        AEvent.Text := UTF8Decode(Raw);
        Drop(FinalIdx + 6);
        Exit(True);
      end;
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
    if (FBuf[1] = 8) or (FBuf[1] = 127) then
    begin
      { A terminal without the kitty keyboard protocol reports Alt+Backspace as
        ESC DEL (or ESC BS); map it to the modified key so word deletion works. }
      AEvent.Kind := ikKey;
      AEvent.Key.Kind := kkBackspace;
      Include(AEvent.Key.Mods, moAlt);
      Drop(2);
      Exit(True);
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
