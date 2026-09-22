unit hildegard.helper.tui.scroll;
{ Scroll containers and scrollbars for the TUI toolkit.

  TScrollContainer clips a single child and scrolls it within a viewport; it
  fills the space it is given and does not propagate content size upward. A
  vertical scrollbar appears per VertScrollBar (never/auto/always); v1 scrolls
  by keyboard. TScrollBar is display plus geometry. }

{$mode delphi}{$H+}

interface

uses
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget;

type
  TScrollMode = (smNever, smAuto, smAlways);
  TScrollBarOrientation = (soVertical, soHorizontal);

  { A scrollbar. v1 implements the vertical case; orientation is a property so
    horizontal can be added without a contract break. }
  TScrollBar = class(TWidget)
  private
    FOrientation: TScrollBarOrientation;
    FValue, FRange, FPage: Integer;
    procedure ClampValue;
    procedure SetValue(AValue: Integer);
    procedure SetRange(AValue: Integer);
    procedure SetPage(AValue: Integer);
    function TrackLength: Integer;
    function MaxValue: Integer;
  public
    constructor Create(AOrientation: TScrollBarOrientation);
    property Value: Integer read FValue write SetValue;
    property Range: Integer read FRange write SetRange;
    property Page: Integer read FPage write SetPage;
    function ThumbSize: Integer;
    function ThumbStart: Integer;
    procedure Render(const S: ISurface); override;
  end;

  { A container that clips a single child and scrolls it. }
  TScrollContainer = class(TWidget)
  private
    FChild: TWidget;
    FVert, FHorz: TScrollMode;
    FScrollX, FScrollY: Integer;
    FViewport: TRect;
    FContentW, FContentH: Integer;
    FVBar, FHBar: TScrollBar;
    function MaxScrollX: Integer;
    function MaxScrollY: Integer;
    procedure UpdateChildBounds;
    procedure SetScroll(AX, AY: Integer);
    procedure SetScrollX(AValue: Integer);
    procedure SetScrollY(AValue: Integer);
  public
    constructor Create(AChild: TWidget; AVert: TScrollMode = smAuto;
      AHorz: TScrollMode = smNever);
    destructor Destroy; override;
    procedure ScrollTo(AX, AY: Integer);
    procedure ScrollBy(AX, AY: Integer);
    function HandleEvent(const E: TInputEvent): Boolean; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    property ScrollX: Integer read FScrollX write SetScrollX;
    property ScrollY: Integer read FScrollY write SetScrollY;
    property VertScrollBar: TScrollMode read FVert write FVert;
    property HorzScrollBar: TScrollMode read FHorz write FHorz;
  end;

implementation

uses
  SysUtils;

function Rect4(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

{ TScrollBar }

constructor TScrollBar.Create(AOrientation: TScrollBarOrientation);
begin
  inherited Create;
  FOrientation := AOrientation;
  FValue := 0;
  FRange := 0;
  FPage := 0;
end;

function TScrollBar.MaxValue: Integer;
begin
  Result := FRange - FPage;
  if Result < 0 then
    Result := 0;
end;

procedure TScrollBar.ClampValue;
begin
  if FValue < 0 then
    FValue := 0;
  if FValue > MaxValue then
    FValue := MaxValue;
end;

procedure TScrollBar.SetValue(AValue: Integer);
begin
  FValue := AValue;
  ClampValue;
end;

procedure TScrollBar.SetRange(AValue: Integer);
begin
  FRange := AValue;
  ClampValue;
end;

procedure TScrollBar.SetPage(AValue: Integer);
begin
  FPage := AValue;
  ClampValue;
end;

function TScrollBar.TrackLength: Integer;
begin
  if FOrientation = soVertical then
    Result := FBounds.H
  else
    Result := FBounds.W;
  if Result < 0 then
    Result := 0;
end;

function TScrollBar.ThumbSize: Integer;
var
  Track: Integer;
begin
  Track := TrackLength;
  if (FRange <= 0) or (FRange <= FPage) then
    Result := Track
  else
  begin
    Result := Track * FPage div FRange;
    if Result < 1 then
      Result := 1;
  end;
end;

function TScrollBar.ThumbStart: Integer;
var
  Track, Size, Off, Max: Integer;
begin
  Track := TrackLength;
  Size := ThumbSize;
  Max := MaxValue;
  if (Max <= 0) or (Track <= Size) then
    Off := 0
  else
    Off := (FValue * (Track - Size)) div Max;
  if FOrientation = soVertical then
    Result := FBounds.Y + Off
  else
    Result := FBounds.X + Off;
end;

procedure TScrollBar.Render(const S: ISurface);
var
  I, TStart, TSize: Integer;
  TrackCell, ThumbCell: TCell;
begin
  if (FBounds.W <= 0) or (FBounds.H <= 0) then
    Exit;
  TrackCell := Default(TCell);
  TrackCell.Ch := '|';
  TrackCell.Attr := DefaultAttr;
  TrackCell.Attr.Style := [sfDim];
  ThumbCell := Default(TCell);
  ThumbCell.Ch := '#';
  ThumbCell.Attr := DefaultAttr;
  TStart := ThumbStart;
  TSize := ThumbSize;
  S.PushClip(FBounds);
  for I := 0 to TrackLength - 1 do
    if (I >= TStart) and (I < TStart + TSize) then
    begin
      if FOrientation = soVertical then
        S.Put(FBounds.X, FBounds.Y + I, ThumbCell)
      else
        S.Put(FBounds.X + I, FBounds.Y, ThumbCell);
    end
    else if FOrientation = soVertical then
      S.Put(FBounds.X, FBounds.Y + I, TrackCell)
    else
      S.Put(FBounds.X + I, FBounds.Y, TrackCell);
  S.PopClip;
end;

{ TScrollContainer }

constructor TScrollContainer.Create(AChild: TWidget; AVert: TScrollMode;
  AHorz: TScrollMode);
begin
  inherited Create;
  FChild := AChild;
  FVert := AVert;
  FHorz := AHorz;
  FScrollX := 0;
  FScrollY := 0;
  FContentW := 0;
  FContentH := 0;
end;

destructor TScrollContainer.Destroy;
begin
  FChild.Free;
  FVBar.Free;
  FHBar.Free;
  inherited Destroy;
end;

function TScrollContainer.MaxScrollX: Integer;
begin
  Result := FContentW - FViewport.W;
  if Result < 0 then
    Result := 0;
end;

function TScrollContainer.MaxScrollY: Integer;
begin
  Result := FContentH - FViewport.H;
  if Result < 0 then
    Result := 0;
end;

procedure TScrollContainer.UpdateChildBounds;
begin
  if FChild = nil then
    Exit;
  FChild.Arrange(Rect4(FViewport.X - FScrollX, FViewport.Y - FScrollY,
    FContentW, FContentH));
end;

procedure TScrollContainer.SetScroll(AX, AY: Integer);
begin
  if AX < 0 then
    AX := 0
  else if AX > MaxScrollX then
    AX := MaxScrollX;
  if AY < 0 then
    AY := 0
  else if AY > MaxScrollY then
    AY := MaxScrollY;
  FScrollX := AX;
  FScrollY := AY;
  UpdateChildBounds;
end;

procedure TScrollContainer.SetScrollX(AValue: Integer);
begin
  SetScroll(AValue, FScrollY);
end;

procedure TScrollContainer.SetScrollY(AValue: Integer);
begin
  SetScroll(FScrollX, AValue);
end;

procedure TScrollContainer.ScrollTo(AX, AY: Integer);
begin
  SetScroll(AX, AY);
end;

procedure TScrollContainer.ScrollBy(AX, AY: Integer);
begin
  SetScroll(FScrollX + AX, FScrollY + AY);
end;

function TScrollContainer.HandleEvent(const E: TInputEvent): Boolean;
var
  PageStep: Integer;
begin
  Result := False;
  if E.Kind = ikKey then
  begin
    PageStep := FViewport.H;
    if PageStep < 1 then
      PageStep := 1;
    case E.Key.Kind of
      kkUp:
        begin
          ScrollBy(0, -1);
          Result := True;
        end;
      kkDown:
        begin
          ScrollBy(0, 1);
          Result := True;
        end;
      kkPageUp:
        begin
          ScrollBy(0, -PageStep);
          Result := True;
        end;
      kkPageDown:
        begin
          ScrollBy(0, PageStep);
          Result := True;
        end;
      kkHome:
        begin
          ScrollTo(0, 0);
          Result := True;
        end;
      kkEnd:
        begin
          ScrollTo(0, MaxScrollY);
          Result := True;
        end;
    else
      ;
    end;
  end;
  if not Result and (FChild <> nil) then
    Result := FChild.HandleEvent(E);
end;

procedure TScrollContainer.Arrange(const ABounds: TRect);
var
  Avail: TSize;
  VpW, VpH: Integer;
  VertShown, HorzShown: Boolean;
begin
  FBounds := ABounds;
  if FChild = nil then
    Exit;

  Avail := Default(TSize);
  Avail.W := ABounds.W;
  Avail.H := ABounds.H;
  FContentW := FChild.Measure(Avail).W;
  FContentH := FChild.Measure(Avail).H;

  VpW := ABounds.W;
  VpH := ABounds.H;
  VertShown := (FVert = smAlways) or
    ((FVert = smAuto) and (FContentH > VpH));
  if VertShown then
    Dec(VpW);
  HorzShown := (FHorz = smAlways) or
    ((FHorz = smAuto) and (FContentW > VpW));
  if HorzShown then
    Dec(VpH);
  if VpW < 0 then
    VpW := 0;
  if VpH < 0 then
    VpH := 0;
  FViewport := Rect4(ABounds.X, ABounds.Y, VpW, VpH);

  SetScroll(FScrollX, FScrollY);

  if VertShown then
  begin
    if FVBar = nil then
      FVBar := TScrollBar.Create(soVertical);
    FVBar.Arrange(Rect4(ABounds.X + ABounds.W - 1, ABounds.Y, 1, VpH));
    FVBar.Page := VpH;
    FVBar.Range := FContentH;
    FVBar.Value := FScrollY;
  end
  else
    FreeAndNil(FVBar);

  if HorzShown then
  begin
    if FHBar = nil then
      FHBar := TScrollBar.Create(soHorizontal);
    FHBar.Arrange(Rect4(ABounds.X, ABounds.Y + ABounds.H - 1, VpW, 1));
    FHBar.Page := VpW;
    FHBar.Range := FContentW;
    FHBar.Value := FScrollX;
  end
  else
    FreeAndNil(FHBar);
end;

procedure TScrollContainer.Render(const S: ISurface);
begin
  if FChild = nil then
    Exit;
  S.PushClip(FViewport);
  FChild.Render(S);
  S.PopClip;
  if FVBar <> nil then
    FVBar.Render(S);
  if FHBar <> nil then
    FHBar.Render(S);
end;

end.
