unit hildegard.helper.tui.encoder;
{ Turns a frame diff into ANSI bytes.

  This replaces FPC video's UpdateScreen diff, which leaves stale cells around
  wide characters and scroll edges. It is pure (no terminal, no video): given the
  previous and current cell buffers it returns exactly the bytes that update the
  terminal, so it is unit-tested at the byte level.

  The encoder keeps cursor and SGR state across frames. It positions absolutely
  before every changed cell (never trusting that the terminal's cursor is where
  we think it is, which drifts when a cluster's rendered width differs from the
  predicted one). A cell whose cluster is wide is emitted as a single unit and
  its trailing cell is skipped; a wide cluster that would straddle the right edge
  is emitted as a space. Cell content is untrusted: C0/C1 controls and DEL are
  replaced with U+FFFD so content cannot inject terminal control sequences. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, hildegard.helper.tui.base;

type
  TCellEncoder = class
  private
    FCurX, FCurY: Integer;
    FFg, FBg: Integer;
    FStyle: TStyle;
    FScreenBg: Byte;
    FBuf: RawByteString;
    procedure Out(const ABytes: RawByteString);
    procedure OutStr(const S: UnicodeString);
    procedure MoveTo(X, Y: Integer);
    procedure ApplyAttr(const A: TAttr);
  public
    constructor Create;
    { Forget cursor/attribute state (call after a mode change or clear). }
    procedure Reset;
    { The palette index painted for cells whose attr has sfScreenBg. The app sets
      this from the theme so text backgrounds match the screen. }
    procedure SetScreenBg(AIndex: Byte);
    { Bytes that turn APrev into ACur. AForce emits every cell. Updates the
      encoder's cursor/attribute state. }
    function Encode(const APrev, ACur: array of TCell;
      AWidth, AHeight: Integer; AForce: Boolean): RawByteString;
  end;

{ Display width of a cluster: 2 for East Asian wide/fullwidth, 1 otherwise
  (an empty cluster counts as one blank column). }
function ClusterDisplayWidth(const ACh: UnicodeString): Integer;

{ Replace C0/C1 control characters and DEL with U+FFFD, so untrusted content
  (model output, command output, file contents) cannot inject terminal control
  sequences. Cell content is the only untrusted part of the byte stream; the
  encoder's own cursor/SGR sequences are emitted separately. }
function SanitizeCluster(const S: UnicodeString): UnicodeString;

function SameCell(const A, B: TCell): Boolean;

implementation

uses
  hildegard.helper.tui.grapheme;

function ClusterDisplayWidth(const ACh: UnicodeString): Integer;
begin
  { An empty cell still advances the terminal cursor by one. }
  if Length(ACh) = 0 then
    Exit(1);
  Result := ClusterWidth(ACh);
end;

function SameCell(const A, B: TCell): Boolean;
begin
  Result := (A.Ch = B.Ch) and (A.Attr.Fg = B.Attr.Fg) and
    (A.Attr.Bg = B.Attr.Bg) and (A.Attr.Style = B.Attr.Style);
end;

function SanitizeCluster(const S: UnicodeString): UnicodeString;
var
  I: Integer;
  U: Word;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    U := Word(S[I]);
    if (U < $20) or ((U >= $7F) and (U <= $9F)) then
      Result := Result + WideChar($FFFD)
    else
      Result := Result + S[I];
  end;
end;

constructor TCellEncoder.Create;
begin
  inherited Create;
  FScreenBg := 0;
  Reset;
end;

procedure TCellEncoder.SetScreenBg(AIndex: Byte);
begin
  FScreenBg := AIndex;
end;

procedure TCellEncoder.Reset;
begin
  FCurX := -1;
  FCurY := -1;
  FFg := -1;
  FBg := -1;
  FStyle := [];
  FBuf := '';
end;

procedure TCellEncoder.Out(const ABytes: RawByteString);
begin
  FBuf := FBuf + ABytes;
end;

procedure TCellEncoder.OutStr(const S: UnicodeString);
begin
  if S = '' then
    Out(' ')
  else
    Out(RawByteString(UTF8Encode(SanitizeCluster(S))));
end;

procedure TCellEncoder.MoveTo(X, Y: Integer);
begin
  { Always position absolutely: never trust that the terminal's cursor is where
    we think it is. A wide/emoji cluster rendered at a different width than we
    assume would otherwise drift every following cell. }
  Out(#27'[' + RawByteString(IntToStr(Y + 1)) + ';' +
    RawByteString(IntToStr(X + 1)) + 'H');
  FCurX := X;
  FCurY := Y;
end;

procedure TCellEncoder.ApplyAttr(const A: TAttr);
var
  Params: string;
  function Flag(AOn: Boolean; ACode: Integer): string;
  begin
    if AOn then
      Result := ';' + IntToStr(ACode)
    else
      Result := '';
  end;
  { sfScreenBg means "paint the app's screen background" rather than this cell's
    Bg index, so text always matches the surface behind it. }
  function BgParams: string;
  begin
    if sfScreenBg in A.Style then
      Result := '48;5;' + IntToStr(FScreenBg)
    else
      Result := '48;5;' + IntToStr(A.Bg);
  end;
begin
  if (A.Fg = FFg) and (A.Bg = FBg) and (A.Style = FStyle) then
    Exit;
  if A.Style <> FStyle then
  begin
    { Reset, then re-state everything (a reset clears colour too). }
    Params := '0';
    Params := Params + Flag(sfBold in A.Style, 1);
    Params := Params + Flag(sfDim in A.Style, 2);
    Params := Params + Flag(sfItalic in A.Style, 3);
    Params := Params + Flag(sfUnderline in A.Style, 4);
    Params := Params + Flag(sfBlink in A.Style, 5);
    Params := Params + Flag(sfReverse in A.Style, 7);
    Params := Params + Flag(sfStrike in A.Style, 9);
    Params := Params + ';38;5;' + IntToStr(A.Fg);
    Params := Params + ';' + BgParams;
  end
  else
  begin
    Params := '';
    if A.Fg <> FFg then
      Params := Params + '38;5;' + IntToStr(A.Fg);
    if A.Bg <> FBg then
    begin
      if Params <> '' then
        Params := Params + ';';
      Params := Params + BgParams;
    end;
  end;
  if Params <> '' then
    Out(#27'[' + RawByteString(Params) + 'm');
  FFg := A.Fg;
  FBg := A.Bg;
  FStyle := A.Style;
end;

function TCellEncoder.Encode(const APrev, ACur: array of TCell;
  AWidth, AHeight: Integer; AForce: Boolean): RawByteString;
var
  I, X, Y, W: Integer;
  Ch: UnicodeString;
  Changed: Boolean;
begin
  FBuf := '';
  if (AWidth <= 0) or (AHeight <= 0) then
    Exit('');
  I := 0;
  while (I <= High(ACur)) and (I < AWidth * AHeight) do
  begin
    X := I mod AWidth;
    Y := I div AWidth;
    Ch := ACur[I].Ch;
    W := ClusterDisplayWidth(Ch);
    if (W = 2) and (X >= AWidth - 1) then
    begin
      { A wide cluster cannot fit in the last column; show a blank instead. }
      Ch := ' ';
      W := 1;
    end;
    Changed := AForce or (not SameCell(ACur[I], APrev[I]));
    if Changed then
    begin
      MoveTo(X, Y);
      ApplyAttr(ACur[I].Attr);
      if W = 2 then
      begin
        OutStr(Ch);
        Inc(FCurX, 2);
        Inc(I, 2);          { the trailing cell is covered by the wide cluster }
      end
      else
      begin
        OutStr(Ch);
        Inc(FCurX);
        Inc(I);
      end;
    end
    else if W = 2 then
      Inc(I, 2)
    else
      Inc(I);
  end;
  Result := FBuf;
end;

end.
