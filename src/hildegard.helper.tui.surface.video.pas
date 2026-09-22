unit hildegard.helper.tui.surface.video;
{ Terminal surface adapter over FPC's video unit.

  This is the only place the toolkit touches video. It reuses video's enhanced
  Unicode cell buffer and its diffing UpdateScreen: the toolkit never writes an
  escape sequence. video's InitEnhancedVideo enters the alternate screen and
  DoneEnhancedVideo restores it, so the surface owns the terminal lifecycle and
  the caller must free it on every exit path. }

{$mode delphi}{$H+}

interface

uses
  hildegard.helper.tui.base, hildegard.helper.tui.surface;

type
  TSurfaceVideo = class(TInterfacedObject, ISurface)
  private
    FClips: array of TRect;
    FClipCount: Integer;
    FNeedFullRepaint: Boolean;
    procedure SyncSize;
    function EffectiveClip: TRect;
    function Intersect(const A, B: TRect): TRect;
    function InClip(X, Y: Integer): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    function Width: Integer;
    function Height: Integer;
    procedure Clear(const AAttr: TAttr);
    procedure Put(X, Y: Integer; const ACell: TCell);
    procedure FillRect(const R: TRect; const AAttr: TAttr);
    procedure DimRect(const R: TRect);
    procedure PushClip(const R: TRect);
    procedure PopClip;
    procedure Flush;
  end;

implementation

uses
  baseunix, termio, video;

const
  AltOn = #27'[?1049h';
  AltOff = #27'[?1049l';

function DimIndex(AIndex: Byte): Byte;
var
  R, G, B: Integer;
begin
  if AIndex < 8 then
    Result := 0
  else if AIndex < 16 then
    Result := AIndex - 8
  else if AIndex < 232 then
  begin
    { 6x6x6 colour cube: step each channel down one level. }
    R := (AIndex - 16) div 36;
    G := ((AIndex - 16) mod 36) div 6;
    B := (AIndex - 16) mod 6;
    if R > 0 then
      Dec(R);
    if G > 0 then
      Dec(G);
    if B > 0 then
      Dec(B);
    Result := 16 + R * 36 + G * 6 + B;
  end
  else
  begin
    { greyscale ramp: drop ~1/3. }
    if AIndex > 232 + 8 then
      Result := AIndex - 8
    else
      Result := 232;
  end;
end;

function ToVideoAttrs(const AStyle: TStyle): TEnhancedVideoAttributes;
begin
  Result := [];
  if sfBold in AStyle then
    Include(Result, evaBold);
  if sfDim in AStyle then
    Include(Result, evaFaint);
  if sfItalic in AStyle then
    Include(Result, evaItalicized);
  if sfUnderline in AStyle then
    Include(Result, evaUnderlined);
  if sfReverse in AStyle then
    Include(Result, evaInverse);
  if sfBlink in AStyle then
    Include(Result, evaBlinkSlow);
  if sfStrike in AStyle then
    Include(Result, evaCrossedOut);
end;

constructor TSurfaceVideo.Create;
begin
  inherited Create;
  FClipCount := 0;
  { Force a full first paint: video clears to the terminal's own default
    background, so a diffing first flush would render only our changed cells and
    leave the rest with a different background ("islands" of mismatched colour). }
  FNeedFullRepaint := True;
  InitEnhancedVideo;
  { Enter the alternate screen explicitly. video does this from terminfo when it
    recognises the terminal; some (ghostty, VSCode) it does not, in which case
    drawing would share the normal screen and scroll its history. }
  fpWrite(1, AltOn[1], Length(AltOn));
  SetCursorType(crHidden);
end;

destructor TSurfaceVideo.Destroy;
begin
  fpWrite(1, AltOff[1], Length(AltOff));
  SetCursorType(crUnderLine);
  DoneEnhancedVideo;
  inherited Destroy;
end;

procedure TSurfaceVideo.SyncSize;
{$ifdef unix}
var
  WS: TWinsize;
  Mode: TVideoMode;
{$endif}
begin
  {$ifdef unix}
  FillChar(WS, SizeOf(WS), 0);
  if (fpioctl(0, TIOCGWINSZ, @WS) = 0) and (WS.ws_col > 0) and
    (WS.ws_row > 0) and
    ((WS.ws_col <> ScreenWidth) or (WS.ws_row <> ScreenHeight)) then
  begin
    Mode.Col := WS.ws_col;
    Mode.Row := WS.ws_row;
    Mode.Color := True;
    if SetVideoMode(Mode) then
      { The resized buffer's new cells differ from the terminal's actual screen;
        a diffing flush would skip them and leave stale content, so force one
        full repaint. }
      FNeedFullRepaint := True;
  end;
  {$endif}
end;

function TSurfaceVideo.Intersect(const A, B: TRect): TRect;
var
  X1, Y1, X2, Y2: Integer;
begin
  X1 := A.X;
  if B.X > X1 then
    X1 := B.X;
  Y1 := A.Y;
  if B.Y > Y1 then
    Y1 := B.Y;
  X2 := A.X + A.W;
  if B.X + B.W < X2 then
    X2 := B.X + B.W;
  Y2 := A.Y + A.H;
  if B.Y + B.H < Y2 then
    Y2 := B.Y + B.H;
  Result := Default(TRect);
  Result.X := X1;
  Result.Y := Y1;
  if X2 > X1 then
    Result.W := X2 - X1;
  if Y2 > Y1 then
    Result.H := Y2 - Y1;
end;

function TSurfaceVideo.EffectiveClip: TRect;
begin
  if FClipCount = 0 then
  begin
    Result := Default(TRect);
    Result.X := 0;
    Result.Y := 0;
    Result.W := Width;
    Result.H := Height;
  end
  else
    Result := FClips[FClipCount - 1];
end;

function TSurfaceVideo.InClip(X, Y: Integer): Boolean;
var
  C: TRect;
begin
  C := EffectiveClip;
  Result := (X >= C.X) and (Y >= C.Y) and (X < C.X + C.W) and (Y < C.Y + C.H);
end;

function TSurfaceVideo.Width: Integer;
begin
  SyncSize;
  Result := ScreenWidth;
end;

function TSurfaceVideo.Height: Integer;
begin
  SyncSize;
  Result := ScreenHeight;
end;

procedure TSurfaceVideo.Put(X, Y: Integer; const ACell: TCell);
var
  I: Integer;
  S: UnicodeString;
begin
  if not InClip(X, Y) then
    Exit;
  if (X < 0) or (Y < 0) or (X >= ScreenWidth) or (Y >= ScreenHeight) then
    Exit;
  I := Y * Integer(ScreenWidth) + X;
  S := ACell.Ch;
  if S = '' then
    S := ' ';
  EnhancedVideoBuf[I].ExtendedGraphemeCluster := S;
  EnhancedVideoBuf[I].ForegroundColor := ACell.Attr.Fg;
  EnhancedVideoBuf[I].BackgroundColor := ACell.Attr.Bg;
  EnhancedVideoBuf[I].EnhancedVideoAttributes := ToVideoAttrs(ACell.Attr.Style);
end;

procedure TSurfaceVideo.Clear(const AAttr: TAttr);
begin
  FillRect(EffectiveClip, AAttr);
end;

procedure TSurfaceVideo.FillRect(const R: TRect; const AAttr: TAttr);
var
  C: TRect;
  X, Y, I: Integer;
begin
  C := Intersect(R, EffectiveClip);
  for Y := C.Y to C.Y + C.H - 1 do
    for X := C.X to C.X + C.W - 1 do
    begin
      if (X < 0) or (Y < 0) or (X >= ScreenWidth) or (Y >= ScreenHeight) then
        Continue;
      I := Y * Integer(ScreenWidth) + X;
      EnhancedVideoBuf[I].ExtendedGraphemeCluster := ' ';
      EnhancedVideoBuf[I].ForegroundColor := AAttr.Fg;
      EnhancedVideoBuf[I].BackgroundColor := AAttr.Bg;
      EnhancedVideoBuf[I].EnhancedVideoAttributes := ToVideoAttrs(AAttr.Style);
    end;
end;

procedure TSurfaceVideo.DimRect(const R: TRect);
var
  C: TRect;
  X, Y, I: Integer;
begin
  C := Intersect(R, EffectiveClip);
  for Y := C.Y to C.Y + C.H - 1 do
    for X := C.X to C.X + C.W - 1 do
    begin
      if (X < 0) or (Y < 0) or (X >= ScreenWidth) or (Y >= ScreenHeight) then
        Continue;
      I := Y * Integer(ScreenWidth) + X;
      { Darken the palette as well as setting faint: many terminals ignore
        SGR 2, so without the remap the dim would be invisible. }
      EnhancedVideoBuf[I].ForegroundColor :=
        DimIndex(EnhancedVideoBuf[I].ForegroundColor);
      EnhancedVideoBuf[I].BackgroundColor :=
        DimIndex(EnhancedVideoBuf[I].BackgroundColor);
      EnhancedVideoBuf[I].EnhancedVideoAttributes :=
        EnhancedVideoBuf[I].EnhancedVideoAttributes + [evaFaint];
    end;
end;

procedure TSurfaceVideo.PushClip(const R: TRect);
begin
  if FClipCount >= Length(FClips) then
    SetLength(FClips, FClipCount + 8);
  FClips[FClipCount] := Intersect(EffectiveClip, R);
  Inc(FClipCount);
end;

procedure TSurfaceVideo.PopClip;
begin
  if FClipCount > 0 then
    Dec(FClipCount);
end;

procedure TSurfaceVideo.Flush;
begin
  SyncSize;
  if FNeedFullRepaint then
  begin
    UpdateScreen(True);
    FNeedFullRepaint := False;
  end
  else
    UpdateScreen(False);
end;

end.
