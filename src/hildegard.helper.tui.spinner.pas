unit hildegard.helper.tui.spinner;
{ A time-based spinner. The displayed frame is a pure function of the frame
  clock: frame = ((now - origin) div IntervalMs) mod FrameCount, where origin is
  the first Advance. Two spinners advanced together therefore stay in step, and
  the widget keeps no timer of its own. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget;

type
  TSpinnerFrames = array of UnicodeString;

  TSpinner = class(TWidget)
  private
    FFrames: TSpinnerFrames;
    FIntervalMs: Integer;
    FAttr: TAttr;
    FIndex: Integer;
    FOriginMs: Int64;
    FStarted: Boolean;
  public
    constructor Create(const AFrames: array of UnicodeString;
      AIntervalMs: Integer = 90); overload;
    constructor Create(const AFrames: array of UnicodeString;
      AIntervalMs: Integer; const AAttr: TAttr); overload;
    function Advance(const ANowMs: Int64): Boolean; override;
    function Animating: Boolean; override;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
    property Frames: TSpinnerFrames read FFrames;
    property IntervalMs: Integer read FIntervalMs write FIntervalMs;
    property Attr: TAttr read FAttr write FAttr;
    { The current frame index; exposed for tests. }
    property Index: Integer read FIndex;
  end;

const
  { Braille spinner, ten frames. }
  BrailleFrames: array[0..9] of UnicodeString =
    ('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏');
  { Plain ASCII fallback for terminals without braille coverage. }
  LineFrames: array[0..3] of UnicodeString = ('|', '/', '-', '\');

implementation

constructor TSpinner.Create(const AFrames: array of UnicodeString;
  AIntervalMs: Integer);
begin
  Create(AFrames, AIntervalMs, DefaultAttr);
end;

constructor TSpinner.Create(const AFrames: array of UnicodeString;
  AIntervalMs: Integer; const AAttr: TAttr);
var
  I: Integer;
begin
  inherited Create;
  SetLength(FFrames, Length(AFrames));
  for I := 0 to High(AFrames) do
    FFrames[I] := AFrames[I];
  if AIntervalMs < 1 then
    AIntervalMs := 1;
  FIntervalMs := AIntervalMs;
  FAttr := AAttr;
  FIndex := 0;
  FOriginMs := 0;
  FStarted := False;
end;

function TSpinner.Advance(const ANowMs: Int64): Boolean;
var
  NewIndex: Integer;
begin
  if not FStarted then
  begin
    FOriginMs := ANowMs;
    FStarted := True;
  end;
  if Length(FFrames) = 0 then
    NewIndex := 0
  else if ANowMs <= FOriginMs then
    NewIndex := 0
  else
    NewIndex := ((ANowMs - FOriginMs) div FIntervalMs) mod Length(FFrames);
  Result := NewIndex <> FIndex;
  FIndex := NewIndex;
end;

function TSpinner.Animating: Boolean;
begin
  { A spinner with frames is always animating; an empty one draws nothing. }
  Result := Length(FFrames) > 0;
end;

function TSpinner.Measure(const AAvail: TSize): TSize;
var
  I: Integer;
begin
  Result := Default(TSize);
  Result.H := 1;
  for I := 0 to High(FFrames) do
    if Length(FFrames[I]) > Result.W then
      Result.W := Length(FFrames[I]);
end;

procedure TSpinner.Render(const S: ISurface);
var
  C: TCell;
begin
  if (Length(FFrames) = 0) or (FBounds.W <= 0) or (FBounds.H <= 0) then
    Exit;
  C := Default(TCell);
  C.Ch := FFrames[FIndex];
  C.Attr := FAttr;
  S.Put(FBounds.X, FBounds.Y, C);
end;

end.
