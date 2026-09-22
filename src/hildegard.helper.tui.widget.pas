unit hildegard.helper.tui.widget;
{ Widget protocol and grid layout for the TUI toolkit.

  A widget measures, arranges, renders, and handles events. TContainer is a grid
  of columns x rows; each track is fixed (exact size), auto (max-content via
  Measure), or fill (shares the leftover by weight), with optional gaps. A
  vertical stack is a one-column grid and a horizontal stack is a one-row grid.

  Because auto is max-content and wrapping text is required to live in
  fixed/fill tracks, track resolution is a single top-down pass - no CSS-style
  width/height fixed-point iteration. }

{$mode delphi}{$H+}

interface

uses
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface;

type
  { Base widget protocol. Bounds are surface-absolute after Arrange. }
  TWidget = class
  protected
    FBounds: TRect;
    FVisible: Boolean;
  public
    constructor Create;
    { Preferred size given an available area. Must not depend on a prior
      Arrange. Used to resolve auto tracks and content extents. }
    function Measure(const AAvail: TSize): TSize; virtual;
    { Assign final bounds; containers recurse into children here. }
    procedure Arrange(const ABounds: TRect); virtual;
    { Draw self into the (already clipped) surface. }
    procedure Render(const S: ISurface); virtual;
    { Consume an event. Return True if handled. }
    function HandleEvent(const E: TInputEvent): Boolean; virtual;
    property Bounds: TRect read FBounds;
    property Visible: Boolean read FVisible write FVisible;
  end;

  { Layout tracks. tkFixed is an exact size; tkAuto is max-content (Measure);
    tkFill shares leftover space by Weight. }
  TTrackKind = (tkFixed, tkAuto, tkFill);
  TTrack = record
    Kind: TTrackKind;
    Size: Integer;    // for tkFixed
    Weight: Integer;  // for tkFill (>= 1)
  end;

function Fixed(ASize: Integer): TTrack;
function Auto: TTrack;
function Fill(AWeight: Integer = 1): TTrack;

type
  TIntArray = array of Integer;

  { A grid container. Columns and Rows describe the tracks; children are placed
    into cells row-major by Add order, or explicitly by (ACol, ARow). Children
    fill their cell and are owned by the container. }
  TContainer = class(TWidget)
  private
    FColumns: array of TTrack;
    FRows: array of TTrack;
    FColGap, FRowGap: Integer;
    FWidgets: array of TWidget;
    FCols: TIntArray;
    FRowsIdx: TIntArray;
    FCount: Integer;
    FNextCell: Integer;
    function ColCount: Integer;
    function RowCount: Integer;
    function AutoWidth(ACol: Integer; const AAvail: TSize): Integer;
    function AutoHeight(ARow: Integer; const AAvail: TSize): Integer;
    function ResolveTracks(const ATracks: array of TTrack; AAvail, AGap: Integer;
      const AAuto: TIntArray): TIntArray;
  public
    constructor Create(const AColumns: array of TTrack;
      const ARows: array of TTrack; AColGap: Integer = 0;
      ARowGap: Integer = 0);
    destructor Destroy; override;
    procedure Add(const AW: TWidget); overload;
    procedure Add(const AW: TWidget; ACol, ARow: Integer); overload;
    function ChildCount: Integer;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
  end;

implementation

function Fixed(ASize: Integer): TTrack;
begin
  Result := Default(TTrack);
  Result.Kind := tkFixed;
  Result.Size := ASize;
  Result.Weight := 0;
end;

function Auto: TTrack;
begin
  Result := Default(TTrack);
  Result.Kind := tkAuto;
end;

function Fill(AWeight: Integer): TTrack;
begin
  Result := Default(TTrack);
  Result.Kind := tkFill;
  Result.Weight := AWeight;
end;

constructor TWidget.Create;
begin
  inherited Create;
  FBounds := Default(TRect);
  FVisible := True;
end;

function TWidget.Measure(const AAvail: TSize): TSize;
begin
  Result := Default(TSize);
end;

procedure TWidget.Arrange(const ABounds: TRect);
begin
  FBounds := ABounds;
end;

procedure TWidget.Render(const S: ISurface);
begin
end;

function TWidget.HandleEvent(const E: TInputEvent): Boolean;
begin
  Result := False;
end;

constructor TContainer.Create(const AColumns: array of TTrack;
  const ARows: array of TTrack; AColGap, ARowGap: Integer);
var
  I: Integer;
begin
  inherited Create;
  SetLength(FColumns, Length(AColumns));
  for I := 0 to High(AColumns) do
    FColumns[I] := AColumns[I];
  SetLength(FRows, Length(ARows));
  for I := 0 to High(ARows) do
    FRows[I] := ARows[I];
  FColGap := AColGap;
  FRowGap := ARowGap;
  FCount := 0;
  FNextCell := 0;
end;

destructor TContainer.Destroy;
var
  I: Integer;
begin
  for I := 0 to FCount - 1 do
    FWidgets[I].Free;
  inherited Destroy;
end;

function TContainer.ColCount: Integer;
begin
  Result := Length(FColumns);
end;

function TContainer.RowCount: Integer;
begin
  Result := Length(FRows);
end;

function TContainer.ChildCount: Integer;
begin
  Result := FCount;
end;

procedure TContainer.Add(const AW: TWidget);
var
  Col, Row, Cells: Integer;
begin
  if (ColCount <= 0) or (RowCount <= 0) then
    Exit;
  Col := FNextCell mod ColCount;
  Row := FNextCell div ColCount;
  Cells := ColCount * RowCount;
  Inc(FNextCell);
  if FNextCell > Cells then
    Exit;
  Add(AW, Col, Row);
end;

procedure TContainer.Add(const AW: TWidget; ACol, ARow: Integer);
begin
  if FCount >= Length(FWidgets) then
  begin
    SetLength(FWidgets, FCount + 8);
    SetLength(FCols, FCount + 8);
    SetLength(FRowsIdx, FCount + 8);
  end;
  FWidgets[FCount] := AW;
  FCols[FCount] := ACol;
  FRowsIdx[FCount] := ARow;
  Inc(FCount);
end;

function TContainer.AutoWidth(ACol: Integer; const AAvail: TSize): Integer;
var
  I, W: Integer;
begin
  Result := 0;
  for I := 0 to FCount - 1 do
    if (FCols[I] = ACol) and FWidgets[I].Visible then
    begin
      W := FWidgets[I].Measure(AAvail).W;
      if W > Result then
        Result := W;
    end;
end;

function TContainer.AutoHeight(ARow: Integer; const AAvail: TSize): Integer;
var
  I, H: Integer;
begin
  Result := 0;
  for I := 0 to FCount - 1 do
    if (FRowsIdx[I] = ARow) and FWidgets[I].Visible then
    begin
      H := FWidgets[I].Measure(AAvail).H;
      if H > Result then
        Result := H;
    end;
end;

function TContainer.ResolveTracks(const ATracks: array of TTrack;
  AAvail, AGap: Integer; const AAuto: TIntArray): TIntArray;
var
  I, N, SumFixed, SumAuto, SumWeight, Gaps, Leftover, Used, S, W, Rem: Integer;
begin
  Result := nil;
  N := Length(ATracks);
  SetLength(Result, N);
  SumFixed := 0;
  SumAuto := 0;
  SumWeight := 0;
  for I := 0 to N - 1 do
    case ATracks[I].Kind of
      tkFixed:
        begin
          S := ATracks[I].Size;
          if S < 0 then
            S := 0;
          Result[I] := S;
          Inc(SumFixed, S);
        end;
      tkAuto:
        begin
          S := AAuto[I];
          if S < 0 then
            S := 0;
          Result[I] := S;
          Inc(SumAuto, S);
        end;
      tkFill:
        begin
          Result[I] := 0;
          W := ATracks[I].Weight;
          if W < 1 then
            W := 1;
          Inc(SumWeight, W);
        end;
    end;
  Gaps := 0;
  if N > 1 then
    Gaps := AGap * (N - 1);
  Leftover := AAvail - SumFixed - SumAuto - Gaps;
  if Leftover < 0 then
    Leftover := 0;
  if SumWeight > 0 then
  begin
    Used := 0;
    for I := 0 to N - 1 do
      if ATracks[I].Kind = tkFill then
      begin
        W := ATracks[I].Weight;
        if W < 1 then
          W := 1;
        S := Leftover * W div SumWeight;
        Result[I] := S;
        Inc(Used, S);
      end;
    Rem := Leftover - Used;
    if Rem > 0 then
      for I := 0 to N - 1 do
        if ATracks[I].Kind = tkFill then
        begin
          Inc(Result[I], Rem);
          Break;
        end;
  end;
end;

function TContainer.Measure(const AAvail: TSize): TSize;
var
  I, Sum: Integer;
begin
  Result := Default(TSize);
  Sum := 0;
  for I := 0 to ColCount - 1 do
    case FColumns[I].Kind of
      tkFixed:
        if FColumns[I].Size > 0 then
          Inc(Sum, FColumns[I].Size);
      tkAuto:
        Inc(Sum, AutoWidth(I, AAvail));
      tkFill:
        ;
    end;
  if ColCount > 1 then
    Inc(Sum, FColGap * (ColCount - 1));
  Result.W := Sum;

  Sum := 0;
  for I := 0 to RowCount - 1 do
    case FRows[I].Kind of
      tkFixed:
        if FRows[I].Size > 0 then
          Inc(Sum, FRows[I].Size);
      tkAuto:
        Inc(Sum, AutoHeight(I, AAvail));
      tkFill:
        ;
    end;
  if RowCount > 1 then
    Inc(Sum, FRowGap * (RowCount - 1));
  Result.H := Sum;
end;

procedure TContainer.Arrange(const ABounds: TRect);
var
  I, C, R, X, Y: Integer;
  Avail: TSize;
  Cell: TRect;
  ColAuto, RowAuto, ColW, RowH, PosX, PosY: TIntArray;
begin
  FBounds := ABounds;
  Avail := Default(TSize);
  Avail.W := ABounds.W;
  Avail.H := ABounds.H;
  SetLength(ColAuto, ColCount);
  for C := 0 to ColCount - 1 do
    ColAuto[C] := AutoWidth(C, Avail);
  SetLength(RowAuto, RowCount);
  for R := 0 to RowCount - 1 do
    RowAuto[R] := AutoHeight(R, Avail);

  ColW := ResolveTracks(FColumns, ABounds.W, FColGap, ColAuto);
  RowH := ResolveTracks(FRows, ABounds.H, FRowGap, RowAuto);

  SetLength(PosX, ColCount);
  X := ABounds.X;
  for C := 0 to ColCount - 1 do
  begin
    PosX[C] := X;
    Inc(X, ColW[C] + FColGap);
  end;
  SetLength(PosY, RowCount);
  Y := ABounds.Y;
  for R := 0 to RowCount - 1 do
  begin
    PosY[R] := Y;
    Inc(Y, RowH[R] + FRowGap);
  end;

  for I := 0 to FCount - 1 do
  begin
    C := FCols[I];
    R := FRowsIdx[I];
    if (C >= 0) and (C < ColCount) and (R >= 0) and (R < RowCount) then
    begin
      Cell := Default(TRect);
      Cell.X := PosX[C];
      Cell.Y := PosY[R];
      Cell.W := ColW[C];
      Cell.H := RowH[R];
      FWidgets[I].Arrange(Cell);
    end;
  end;
end;

procedure TContainer.Render(const S: ISurface);
var
  I: Integer;
begin
  S.PushClip(FBounds);
  for I := 0 to FCount - 1 do
    if FWidgets[I].Visible then
      FWidgets[I].Render(S);
  S.PopClip;
end;

function TContainer.HandleEvent(const E: TInputEvent): Boolean;
var
  I: Integer;
begin
  for I := 0 to FCount - 1 do
    if FWidgets[I].Visible and FWidgets[I].HandleEvent(E) then
      Exit(True);
  Result := False;
end;

end.
