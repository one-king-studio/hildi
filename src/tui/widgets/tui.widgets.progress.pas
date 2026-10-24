unit tui.widgets.progress;
{ A progress bar. Determinate fills by value (with eighth-block precision);
  indeterminate bounces a single block across the inner width as a pure function
  of the frame clock. Only the indeterminate form animates, so the app only
  schedules frames while it is on screen. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  tui.base, tui.input,
  tui.surface, tui.widget;

const
  { Indeterminate bounce cadence. }
  ProgressIntervalMs = 90;

type
  TProgress = class(TWidget)
  private
    FValue, FMax, FWidth: Integer;
    FIndeterminate: Boolean;
    FAttr: TAttr;
    FPos: Integer;
    FOriginMs: Int64;
    FStarted: Boolean;
    procedure SetValue(AValue: Integer);
    procedure SetMax(AValue: Integer);
    procedure SetWidth(AValue: Integer);
    procedure SetIndeterminate(AValue: Boolean);
  public
    constructor Create(AWidthCells: Integer); overload;
    constructor Create(AWidthCells: Integer; const AAttr: TAttr); overload;
    destructor Destroy; override;
    function Advance(const ANowMs: Int64): Boolean; override;
    function Animating: Boolean; override;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
    property Value: Integer read FValue write SetValue;
    property Max: Integer read FMax write SetMax;
    property Indeterminate: Boolean read FIndeterminate write SetIndeterminate;
    property WidthCells: Integer read FWidth write SetWidth;
    property Attr: TAttr read FAttr write FAttr;
    { The bouncing block's cell (indeterminate); exposed for tests. }
    property Position: Integer read FPos;
  end;

implementation

const
  { EIGHTHS[k] is k/8 of a cell filled. }
  EIGHTHS: array[1..8] of UnicodeString =
    ('▏', '▎', '▍', '▌', '▋', '▊', '▉', '█');
  FullBlock = '█';
  BlankCell = ' ';

constructor TProgress.Create(AWidthCells: Integer);
begin
  Create(AWidthCells, DefaultAttr);
end;

constructor TProgress.Create(AWidthCells: Integer; const AAttr: TAttr);
begin
  inherited Create;
  if AWidthCells < 1 then
    AWidthCells := 1;
  FWidth := AWidthCells;
  FMax := 100;
  FValue := 0;
  FIndeterminate := False;
  FAttr := AAttr;
  FPos := 0;
  FOriginMs := 0;
  FStarted := False;
end;

procedure TProgress.SetIndeterminate(AValue: Boolean);
begin
  if AValue = FIndeterminate then
    Exit;
  FIndeterminate := AValue;
  { The indeterminate bar animates; register it so the app ticks for it (and no
    faster than its own interval). }
  if FIndeterminate then
    SetAnimation(ProgressIntervalMs)
  else
    ClearAnimation;
end;

destructor TProgress.Destroy;
begin
  ClearAnimation;
  inherited Destroy;
end;

procedure TProgress.SetValue(AValue: Integer);
begin
  if AValue < 0 then
    AValue := 0;
  if AValue > FMax then
    AValue := FMax;
  FValue := AValue;
end;

procedure TProgress.SetMax(AValue: Integer);
begin
  if AValue < 1 then
    AValue := 1;
  FMax := AValue;
  SetValue(FValue);
end;

procedure TProgress.SetWidth(AValue: Integer);
begin
  if AValue < 1 then
    AValue := 1;
  FWidth := AValue;
end;

function TProgress.Animating: Boolean;
begin
  Result := FIndeterminate;
end;

function TProgress.Advance(const ANowMs: Int64): Boolean;
var
  Lo, Hi, Span, Period, Step, NewPos: Integer;
begin
  if not FIndeterminate then
    Exit(False);
  if not FStarted then
  begin
    FOriginMs := ANowMs;
    FStarted := True;
  end;
  { One cell of margin at each end so the block never touches a border. }
  Lo := 1;
  Hi := FWidth - 2;
  if Hi < Lo then
  begin
    Lo := 0;
    Hi := FWidth - 1;
  end;
  Span := Hi - Lo;
  if Span <= 0 then
    NewPos := Lo
  else
  begin
    Period := Span * 2;
    if ANowMs <= FOriginMs then
      Step := 0
    else
      Step := Integer(((ANowMs - FOriginMs) div ProgressIntervalMs) mod Period);
    if Step <= Span then
      NewPos := Lo + Step
    else
      NewPos := Hi - (Step - Span);
  end;
  Result := NewPos <> FPos;
  FPos := NewPos;
end;

function TProgress.Measure(const AAvail: TSize): TSize;
begin
  Result := Default(TSize);
  Result.W := FWidth;
  Result.H := 1;
end;

procedure TProgress.Render(const S: ISurface);
var
  I, EighthsTotal, Full, Part: Integer;
  C: TCell;

  procedure PutAt(AX: Integer; const ACh: UnicodeString);
  begin
    C := Default(TCell);
    C.Ch := ACh;
    C.Attr := FAttr;
    S.Put(FBounds.X + AX, FBounds.Y, C);
  end;

begin
  if (FBounds.W <= 0) or (FBounds.H <= 0) then
    Exit;
  if FIndeterminate then
  begin
    for I := 0 to FWidth - 1 do
      if I = FPos then
        PutAt(I, FullBlock)
      else
        PutAt(I, BlankCell);
    Exit;
  end;
  EighthsTotal := Round(FValue / FMax * FWidth * 8);
  Full := EighthsTotal div 8;
  Part := EighthsTotal mod 8;
  for I := 0 to FWidth - 1 do
  begin
    if I < Full then
      PutAt(I, FullBlock)
    else if (I = Full) and (Part > 0) then
      PutAt(I, EIGHTHS[Part])
    else
      PutAt(I, BlankCell);
  end;
end;

end.
