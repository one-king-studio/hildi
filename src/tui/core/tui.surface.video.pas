unit tui.surface.video;
{ Terminal surface adapter over FPC's video unit.

  video owns the terminal lifecycle (the alternate screen, the kitty keyboard
  push/pop, the cursor) and the window size. We do NOT use its UpdateScreen diff,
  which leaves stale cells around wide characters and scroll edges: the surface
  keeps its own cell buffer and emits only changed cells through
  tui.encoder, which is pure and unit-tested.

  InitEnhancedVideo/DoneEnhancedVideo still enter and leave the alternate screen,
  so the caller must free the surface on every exit path. }

{$mode delphi}{$H+}

interface

uses
  tui.base, tui.surface,
  tui.encoder;

type
  TSurfaceVideo = class(TInterfacedObject, ISurface)
  private
    FWidth, FHeight: Integer;
    FCells: array of TCell;
    FPrev: array of TCell;
    FClips: array of TRect;
    FClipCount: Integer;
    FNeedFullRepaint: Boolean;
    FSizeChanged: Boolean;
    FScreenBg: Byte;
    FEncoder: TCellEncoder;
    procedure InitSize;
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
    function ClipRect: TRect;
    procedure Invalidate;
    procedure Resize(AWidth, AHeight: Integer);
    procedure SetScreenBg(AIndex: Byte);
    procedure Flush;
  end;

implementation

uses
  baseunix, termio, video;

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
  WriteOut(#27'[?1004h');       { focus reporting on: CSI I / CSI O on focus change }
  FNeedFullRepaint := True;
  FSizeChanged := False;
  InitSize;
end;

destructor TSurfaceVideo.Destroy;
begin
  WriteOut(#27'[?1004l');       { focus reporting off }
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

procedure TSurfaceVideo.InitSize;
{$ifdef unix}
var
  WS: TWinsize;
{$endif}
begin
  { Read the terminal size once, at startup. Later resizes arrive through Resize,
    so the surface never adopts an intermediate size in the middle of a drag. }
  {$ifdef unix}
  FillChar(WS, SizeOf(WS), 0);
  if (fpioctl(0, TIOCGWINSZ, @WS) = 0) and (WS.ws_col > 0) and
    (WS.ws_row > 0) then
  begin
    FWidth := WS.ws_col;
    FHeight := WS.ws_row;
  end;
  {$endif}
  if (FWidth <= 0) or (FHeight <= 0) then
  begin
    FWidth := 80;
    FHeight := 25;
  end;
  SetLength(FCells, FWidth * FHeight);
  SetLength(FPrev, FWidth * FHeight);
  FNeedFullRepaint := True;
end;

procedure TSurfaceVideo.Resize(AWidth, AHeight: Integer);
begin
  if (AWidth <= 0) or (AHeight <= 0) then
    Exit;
  if (AWidth = FWidth) and (AHeight = FHeight) then
    Exit;
  FWidth := AWidth;
  FHeight := AHeight;
  SetLength(FCells, FWidth * FHeight);
  SetLength(FPrev, FWidth * FHeight);
  FNeedFullRepaint := True;
  FSizeChanged := True;
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
  Result := FWidth;
end;

function TSurfaceVideo.Height: Integer;
begin
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
        SGR 2, so without the remap the dim would be invisible. A cell that
        paints the screen background keeps that background in the encoder, so
        swap it for an explicit dimmed index or only the text would dim. }
      if sfScreenBg in FCells[I].Attr.Style then
      begin
        Exclude(FCells[I].Attr.Style, sfScreenBg);
        FCells[I].Attr.Bg := DimPaletteIndex(FScreenBg);
      end
      else
        FCells[I].Attr.Bg := DimPaletteIndex(FCells[I].Attr.Bg);
      FCells[I].Attr.Fg := DimPaletteIndex(FCells[I].Attr.Fg);
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

function TSurfaceVideo.ClipRect: TRect;
begin
  Result := EffectiveClip;
end;

procedure TSurfaceVideo.Invalidate;
begin
  FNeedFullRepaint := True;
end;

procedure TSurfaceVideo.SetScreenBg(AIndex: Byte);
begin
  FScreenBg := AIndex;
  FEncoder.SetScreenBg(AIndex);
end;

procedure TSurfaceVideo.Flush;
var
  Data: RawByteString;
  Full: Boolean;
  I: Integer;
begin
  Full := FNeedFullRepaint;
  if Full then
    FEncoder.Reset;
  { Erase the terminal's own columns just past the width we paint, and the whole
    display, before the repaint, so the encoder's state stays in step. }
  if FSizeChanged then
    Data := FEncoder.ClearDisplay(DefaultAttr) +
      FEncoder.ClearOverflowColumn(FWidth, FHeight, DefaultAttr)
  else
    Data := '';
  Data := Data + FEncoder.Encode(FPrev, FCells, FWidth, FHeight, Full);
  FNeedFullRepaint := False;
  FSizeChanged := False;
  WriteOut(Data);
  for I := 0 to High(FCells) do
    FPrev[I] := FCells[I];
end;

end.
