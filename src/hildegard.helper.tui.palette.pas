unit hildegard.helper.tui.palette;
{ A typeahead command palette: a selectable list of commands shown above the
  composer. It is the reusable "choose an action" surface — the checkpoint (and
  future commands) register here rather than each adding a keybinding.

  The host shows it when the composer text begins with '/', feeds the typed
  prefix via Filter, and acts on OnRun. Up/Down move the selection, Enter runs
  it, Escape dismisses. It wraps a TListView, so the list behaviour (selection,
  rendering, mouse) is shared.

  Filtering is pure (Prefix + a command list -> the matching commands), so it is
  unit-tested without a surface. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget,
  hildegard.helper.tui.theme, hildegard.helper.tui.list;
type
  TCommand = record
    Name: string;          // e.g. 'checkpoint' (no slash)
    Description: string;   // a one-line summary
  end;
  TCommandArray = array of TCommand;

  TCommandRunEvent = procedure(const AName: string) of object;

  TCommandPalette = class(TWidget)
  private
    FTheme: TTheme;
    FCommands: TCommandArray;
    FVisibleCommands: TCommandArray;
    FList: TListView;
    FSelected: Integer;
    FOnRun: TCommandRunEvent;
    function CommandIndexAt(AVisible: Integer): Integer;
    procedure Activate(Sender: TObject);
  public
    constructor Create(const ATheme: TTheme);
    destructor Destroy; override;
    { Replace the command set (the full list; Filter narrows the view). }
    procedure SetCommands(const ACommands: TCommandArray);
    { Narrow the visible commands to those whose name starts with APrefix
      (case-insensitive; a leading '/' is ignored). Empty prefix shows all. }
    procedure Filter(const APrefix: string);
    { The currently selected command's name, or '' when none. }
    function SelectedName: string;
    function VisibleCount: Integer;
    function VisibleAt(AIndex: Integer): TCommand;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    property Theme: TTheme read FTheme write FTheme;
    property OnRun: TCommandRunEvent read FOnRun write FOnRun;
  end;

{ The commands whose name starts with APrefix (case-insensitive, leading '/'
  ignored). Pure; exposed for testing. }
function FilterCommands(const ACommands: TCommandArray;
  const APrefix: string): TCommandArray;

const
  { The palette shows at most this many rows (plus its title). }
  PaletteMaxRows = 6;

implementation

function Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

function FilterCommands(const ACommands: TCommandArray;
  const APrefix: string): TCommandArray;
var
  P: string;
  I: Integer;
  Lower: string;
begin
  Result := nil;
  P := APrefix;
  if (P <> '') and (P[1] = '/') then
    P := Copy(P, 2, MaxInt);
  P := LowerCase(P);
  for I := 0 to High(ACommands) do
  begin
    Lower := LowerCase(ACommands[I].Name);
    if (P = '') or (Copy(Lower, 1, Length(P)) = P) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := ACommands[I];
    end;
  end;
end;

constructor TCommandPalette.Create(const ATheme: TTheme);
begin
  inherited Create;
  FTheme := ATheme;
  FList := TListView.Create(ATheme);
  FList.OnActivate := Activate;
  FSelected := -1;
end;

destructor TCommandPalette.Destroy;
begin
  FList.Free;
  inherited Destroy;
end;

procedure TCommandPalette.SetCommands(const ACommands: TCommandArray);
begin
  FCommands := Copy(ACommands, 0, Length(ACommands));
  Filter('');
end;

function TCommandPalette.CommandIndexAt(AVisible: Integer): Integer;
begin
  Result := -1;
  if (AVisible >= 0) and (AVisible <= High(FVisibleCommands)) then
    Result := AVisible;
end;

procedure TCommandPalette.Filter(const APrefix: string);
var
  I: Integer;
begin
  FVisibleCommands := FilterCommands(FCommands, APrefix);
  FList.Clear;
  for I := 0 to High(FVisibleCommands) do
    FList.AddItem('/' + FVisibleCommands[I].Name,
      FVisibleCommands[I].Description);
  FSelected := FList.Selected;
end;

function TCommandPalette.SelectedName: string;
begin
  if (FSelected >= 0) and (FSelected <= High(FVisibleCommands)) then
    Result := FVisibleCommands[FSelected].Name
  else
    Result := '';
end;

function TCommandPalette.VisibleCount: Integer;
begin
  Result := Length(FVisibleCommands);
end;

function TCommandPalette.VisibleAt(AIndex: Integer): TCommand;
begin
  if (AIndex >= 0) and (AIndex <= High(FVisibleCommands)) then
    Result := FVisibleCommands[AIndex]
  else
    Result := Default(TCommand);
end;

function TCommandPalette.Measure(const AAvail: TSize): TSize;
var
  N: Integer;
begin
  Result := Default(TSize);
  Result.W := AAvail.W;
  N := Length(FVisibleCommands);
  if N > PaletteMaxRows then
    N := PaletteMaxRows;
  { A titled box: the top border, one row per visible command, the bottom
    border (when any). }
  if N = 0 then
    Result.H := 0
  else
    Result.H := N + 2;
end;

procedure TCommandPalette.Arrange(const ABounds: TRect);
begin
  inherited Arrange(ABounds);
  { Inset by one for the box border. }
  if ABounds.H > 2 then
    FList.Arrange(Rc(ABounds.X + 1, ABounds.Y + 1, ABounds.W - 2,
      ABounds.H - 2));
end;

procedure TCommandPalette.Render(const S: ISurface);
var
  L, R, T, B, X: Integer;
  Border: TAttr;
begin
  if (FBounds.W < 4) or (FBounds.H < 3) then
    Exit;
  L := FBounds.X;
  R := FBounds.X + FBounds.W - 1;
  T := FBounds.Y;
  B := FBounds.Y + FBounds.H - 1;
  Border := WithStyle(FTheme.Accent, [sfDim]);
  { A rounded box, titled 'commands' on the top border, per the design. }
  PutCh(S, L, T, '╭', Border);
  PutCh(S, R, T, '╮', Border);
  PutCh(S, L, B, '╰', Border);
  PutCh(S, R, B, '╯', Border);
  for X := L + 1 to R - 1 do
  begin
    PutCh(S, X, T, '─', Border);
    PutCh(S, X, B, '─', Border);
  end;
  PutText(S, L + 2, T, ' commands ', FTheme.Muted);
  for X := T + 1 to B - 1 do
  begin
    PutCh(S, L, X, '│', Border);
    PutCh(S, R, X, '│', Border);
  end;
  FList.Render(S);
end;

procedure TCommandPalette.Activate(Sender: TObject);
begin
  FSelected := FList.Selected;
  if (SelectedName <> '') and Assigned(FOnRun) then
    FOnRun(SelectedName);
end;

function TCommandPalette.HandleEvent(const E: TInputEvent): Boolean;
begin
  Result := FList.HandleEvent(E);
  FSelected := FList.Selected;
end;

end.
