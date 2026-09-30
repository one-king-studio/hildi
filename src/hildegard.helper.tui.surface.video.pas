unit hildegard.helper.tui.surface.video;
{ Terminal surface adapter over FPC's video unit.

  video owns the terminal lifecycle (the alternate screen, the kitty keyboard
  push/pop, the cursor) and the window size. We do NOT use its UpdateScreen diff,
  which leaves stale cells around wide characters and scroll edges: the surface
  keeps its own cell buffer and emits only changed cells through
  hildegard.helper.tui.encoder, which is pure and unit-tested.

  InitEnhancedVideo/DoneEnhancedVideo still enter and leave the alternate screen,
  so the caller must free the surface on every exit path. }

{$mode delphi}{$H+}

interface

uses
  hildegard.helper.tui.base, hildegard.helper.tui.surface,
  hildegard.helper.tui.encoder;

type
  TSurfaceVideo = class(TInterfacedObject, ISurface)
  private
    FWidth, FHeight: Integer;
    FCells: array of TCell;
    FPrev: array of TCell;
    FClips: array of TRect;
    FClipCount: Integer;
    FNeedFullRepaint: Boolean;
    FEncoder: TCellEncoder;
    procedure SyncSize;
    procedure WriteOut(const AData: RawByteString);
    function EffectiveClip: TRect;
    function Intersect(const A, B: TRect): TRect;
    function InClip(X, Y: Integer): Boolean;
    function IndexOf(X, Y: Integer): Integer;
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
    procedure Invalidate;
    procedure Flush;
  end;

implementation

uses
  baseunix, termio, video;

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

constructor TSurfaceVideo.Create;
begin
  inherited Create;
  FClipCount := 0;
  FWidth := 0;
  FHeight := 0;
  FEncoder := TCellEncoder.Create;
  InitEnhancedVideo;
  SetCursorType(crHidden);
  WriteOut(#27'[?7l');          { autowrap off: we always position explicitly }
  FNeedFullRepaint := True;
  SyncSize;
end;

destructor TSurfaceVideo.Destroy;
begin
  WriteOut(#27'[?7h');          { restore autowrap before leaving }
  SetCursorType(crUnderLine);
  DoneEnhancedVideo;
  FEncoder.Free;
  inherited Destroy;
end;

procedure TSurfaceVideo.WriteOut(const AData: RawByteString);
var
  Off, N: Integer;
begin
  if AData = '' then
    Exit;
  Off := 1;
  while Off <= Length(AData) do
  begin
    N := fpWrite(1, AData[Off], Length(AData) - Off + 1);
    if N <= 0 then
      Break;
    Inc(Off, N);
  end;
end;

procedure TSurfaceVideo.SyncSize;
{$ifdef unix}
var
  WS: TWinsize;
{$endif}
begin
  {$ifdef unix}
  FillChar(WS, SizeOf(WS), 0);
  if (fpioctl(0, TIOCGWINSZ, @WS) = 0) and (WS.ws_col > 0) and
    (WS.ws_row > 0) and ((WS.ws_col <> FWidth) or (WS.ws_row <> FHeight)) then
  begin
    FWidth := WS.ws_col;
    FHeight := WS.ws_row;
    SetLength(FCells, FWidth * FHeight);
    SetLength(FPrev, FWidth * FHeight);
    FNeedFullRepaint := True;
  end;
  {$endif}
  if (FWidth <= 0) or (FHeight <= 0) then
  begin
    FWidth := 80;
    FHeight := 25;
    SetLength(FCells, FWidth * FHeight);
    SetLength(FPrev, FWidth * FHeight);
    FNeedFullRepaint := True;
  end;
end;

function TSurfaceVideo.IndexOf(X, Y: Integer): Integer;
begin
  Result := Y * FWidth + X;
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
    Result.W := FWidth;
    Result.H := FHeight;
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
  Result := FWidth;
end;

function TSurfaceVideo.Height: Integer;
begin
  SyncSize;
  Result := FHeight;
end;

procedure TSurfaceVideo.Put(X, Y: Integer; const ACell: TCell);
begin
  if not InClip(X, Y) then
    Exit;
  if (X < 0) or (Y < 0) or (X >= FWidth) or (Y >= FHeight) then
    Exit;
  FCells[IndexOf(X, Y)] := ACell;
end;

procedure TSurfaceVideo.Clear(const AAttr: TAttr);
begin
  FillRect(EffectiveClip, AAttr);
end;

procedure TSurfaceVideo.FillRect(const R: TRect; const AAttr: TAttr);
var
  C: TRect;
  X, Y: Integer;
  Blank: TCell;
begin
  C := Intersect(R, EffectiveClip);
  Blank := Default(TCell);
  Blank.Ch := ErasedChar;
  Blank.Attr := AAttr;
  for Y := C.Y to C.Y + C.H - 1 do
    for X := C.X to C.X + C.W - 1 do
    begin
      if (X < 0) or (Y < 0) or (X >= FWidth) or (Y >= FHeight) then
        Continue;
      FCells[IndexOf(X, Y)] := Blank;
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
      if (X < 0) or (Y < 0) or (X >= FWidth) or (Y >= FHeight) then
        Continue;
      I := IndexOf(X, Y);
      { Darken the palette as well as setting faint: many terminals ignore
        SGR 2, so without the remap the dim would be invisible. }
      FCells[I].Attr.Fg := DimIndex(FCells[I].Attr.Fg);
      FCells[I].Attr.Bg := DimIndex(FCells[I].Attr.Bg);
      Include(FCells[I].Attr.Style, sfDim);
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

procedure TSurfaceVideo.Invalidate;
begin
  FNeedFullRepaint := True;
end;

procedure TSurfaceVideo.Flush;
var
  Data: RawByteString;
  Full: Boolean;
  I: Integer;
begin
  SyncSize;
  Full := FNeedFullRepaint;
  if Full then
    FEncoder.Reset;
  Data := FEncoder.Encode(FPrev, FCells, FWidth, FHeight, Full);
  FNeedFullRepaint := False;
  WriteOut(Data);
  for I := 0 to High(FCells) do
    FPrev[I] := FCells[I];
end;

end.
