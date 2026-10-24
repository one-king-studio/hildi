unit tui.widgets.actions;
{ A small CTA panel: a bordered strip of key/action hints that replaces the
  compose box when the panel is showing a read-only view (e.g. spying on a
  session). Each hint fires OnAction by index on its key; Escape is left to the
  host's global handler. Reuses the compose's visual language (heavy top border,
  keys dimmed, actions in the accent). }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils,
  tui.base, tui.input,
  tui.surface, tui.widget,
  tui.theme, tui.grapheme;

type
  { One hint: the key that fires it (a single character; '' for a key the host
    owns, shown dimmed but not handled here) and its label. }
  TActionHint = record
    Key: string;
    Action: string;
  end;
  TActionHintArray = array of TActionHint;

  { Fired when a hint's key is pressed; the index is into the hint array. }
  TActionFiredEvent = procedure(AIndex: Integer) of object;

  TActionsBar = class(TWidget)
  private
    FTheme: TTheme;
    FHints: TActionHintArray;
    FLabel: string;
    FOnAction: TActionFiredEvent;
    function HintsWidth: Integer;
  public
    constructor Create(const ATheme: TTheme);
    { Replace the hints. }
    procedure SetHints(const AHints: TActionHintArray);
    { A left-aligned label (e.g. the mode), '' for none. }
    property Label_: string read FLabel write FLabel;
    property OnAction: TActionFiredEvent read FOnAction write FOnAction;
    { The panel's fixed height (matches the compose box's minimum). }
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
  end;

implementation

const
  { The gap between hints. }
  HintGap = '   ';
  { The panel's fixed height: a heavy top border, a hint row, a blank, and a
    single bottom border (the compose box's shape). }
  ActionsHeight = 4;

function Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

constructor TActionsBar.Create(const ATheme: TTheme);
begin
  inherited Create;
  FTheme := ATheme;
  FHints := nil;
  FLabel := '';
end;

procedure TActionsBar.SetHints(const AHints: TActionHintArray);
begin
  FHints := AHints;
end;

function TActionsBar.HintsWidth: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FHints) do
  begin
    if I > 0 then
      Inc(Result, StringWidth(UnicodeString(HintGap)));
    Inc(Result, StringWidth(UnicodeString(FHints[I].Key)));
    Inc(Result, StringWidth(UnicodeString(FHints[I].Action)));
  end;
end;

function TActionsBar.Measure(const AAvail: TSize): TSize;
begin
  Result := Default(TSize);
  Result.W := AAvail.W;
  Result.H := ActionsHeight;
end;

procedure TActionsBar.Render(const S: ISurface);
var
  L, R, T, B, X, I, Row: Integer;
  SurfaceAttr, Border, KeyAttr, ActAttr, LabelAttr: TAttr;
begin
  if (FBounds.W < 4) or (FBounds.H < 2) then
    Exit;
  L := FBounds.X;
  R := FBounds.X + FBounds.W - 1;
  T := FBounds.Y;
  B := FBounds.Y + FBounds.H - 1;

  SurfaceAttr := OnBg(FTheme.Text, FTheme.RaisedBg);
  Border := OnBg(WithStyle(FTheme.Accent, [sfDim]), FTheme.RaisedBg);
  KeyAttr := OnBg(FTheme.Muted, FTheme.RaisedBg);
  ActAttr := OnBg(FTheme.Accent, FTheme.RaisedBg);
  LabelAttr := OnBg(FTheme.Muted, FTheme.RaisedBg);

  S.FillRect(FBounds, SurfaceAttr);
  { Heavy top, single bottom, light sides (the compose's frame). }
  PutCh(S, L, T, '╭', Border);
  PutCh(S, R, T, '╮', Border);
  PutCh(S, L, B, '╰', Border);
  PutCh(S, R, B, '╯', Border);
  for X := L + 1 to R - 1 do
  begin
    PutCh(S, X, T, '═', Border);
    PutCh(S, X, B, '─', Border);
  end;
  for I := T + 1 to B - 1 do
  begin
    PutCh(S, L, I, '│', Border);
    PutCh(S, R, I, '│', Border);
  end;

  { The label on the content row, left; the hints right-aligned. }
  Row := T + 1;
  if FLabel <> '' then
    PutText(S, L + 2, Row, UnicodeString(FLabel), LabelAttr);
  X := R - 1 - HintsWidth;
  if X < L + 2 then
    X := L + 2;
  for I := 0 to High(FHints) do
  begin
    if I > 0 then
      Inc(X, StringWidth(UnicodeString(HintGap)));
    PutText(S, X, Row, UnicodeString(FHints[I].Key), KeyAttr);
    Inc(X, StringWidth(UnicodeString(FHints[I].Key)));
    PutText(S, X, Row, UnicodeString(FHints[I].Action), ActAttr);
    Inc(X, StringWidth(UnicodeString(FHints[I].Action)));
  end;
end;

function TActionsBar.HandleEvent(const E: TInputEvent): Boolean;
var
  I: Integer;
begin
  Result := False;
  if (E.Kind <> ikKey) or (E.Key.Kind <> kkChar) or (E.Key.Ch = '') then
    Exit;
  { A hint fires on its key; Escape (and any non-character key) falls through to
    the host's global handler. }
  for I := 0 to High(FHints) do
    if (FHints[I].Key <> '') and (E.Key.Ch = UnicodeString(FHints[I].Key)) then
    begin
      if Assigned(FOnAction) then
        FOnAction(I);
      Exit(True);
    end;
end;

end.
