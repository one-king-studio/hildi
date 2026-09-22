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
  InitEnhancedVideo;
  SetCursorType(crHidden);
end;

destructor TSurfaceVideo.Destroy;
begin
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
    SetVideoMode(Mode);
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
  UpdateScreen(False);
end;

end.
