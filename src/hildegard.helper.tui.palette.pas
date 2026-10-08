unit hildegard.helper.tui.palette;
{ A typeahead command palette: a selectable list of commands shown above the
  composer, styled as a slider rising out of it.

  It is the reusable "choose an action" surface — the checkpoint (and future
  commands) register here rather than each adding a keybinding. The host shows
  it when the composer text begins with '/', feeds the typed prefix via Filter,
  and acts on OnRun. Up/Down move the selection, Enter runs it, a click runs it,
  Escape dismisses.

  Styling matches an ambient message (the same raised background and violet
  border), to mark it as system functionality — user input is teal, tool output
  is olive/green. It has no bottom border, so it reads as emerging from the
  composer.

  Filtering is pure (Prefix + a command list -> the matching commands), so it is
  unit-tested without a surface. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils, hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget,
  hildegard.helper.tui.theme;

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
    FSelected: Integer;
    FOnRun: TCommandRunEvent;
    procedure MoveSelection(ADelta: Integer);
    procedure RunSelected;
    function RowAt(AY: Integer): Integer;
    function PaletteWidth: Integer;
  public
    constructor Create(const ATheme: TTheme);
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
  { The palette shows at most this many rows (plus its top border). }
  PaletteMaxRows = 6;
  { The narrowest the palette gets, so a short list still reads as a panel. }
  PaletteMinWidth = 40;
  { The widest, so a long description never stretches it to the panel width. }
  PaletteMaxWidth = 64;
  { The violet used by the ambient border; the palette borrows it to mark
    itself as system functionality. }
  PaletteBorderFg = 135;
  { The selected row's background: one step lighter than the ambient raised
    background (235). }
  PaletteSelBg = 236;

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
  FSelected := -1;
end;

procedure TCommandPalette.SetCommands(const ACommands: TCommandArray);
begin
  FCommands := Copy(ACommands, 0, Length(ACommands));
  Filter('');
end;

procedure TCommandPalette.Filter(const APrefix: string);
begin
  FVisibleCommands := FilterCommands(FCommands, APrefix);
  if Length(FVisibleCommands) = 0 then
    FSelected := -1
  else if (FSelected < 0) or (FSelected > High(FVisibleCommands)) then
    FSelected := 0;
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

function TCommandPalette.PaletteWidth: Integer;
var
  I, W, Longest, DescAllow: Integer;
begin
  { Base the width on the command NAMES (a slider, not a full-width panel); the
    description gets a capped allowance and is hidden when it does not fit. }
  Longest := 0;
  for I := 0 to High(FVisibleCommands) do
  begin
    W := Length(FVisibleCommands[I].Name) + 1;   { the leading '/' }
    if W > Longest then
      Longest := W;
  end;
  DescAllow := 34;
  Result := Longest + 4 + DescAllow + 2;   { '│ /name  desc… │' }
  if Result < PaletteMinWidth then
    Result := PaletteMinWidth;
  if Result > PaletteMaxWidth then
    Result := PaletteMaxWidth;
end;

function TCommandPalette.Measure(const AAvail: TSize): TSize;
var
  N: Integer;
begin
  Result := Default(TSize);
  if Length(FVisibleCommands) = 0 then
    Exit;
  { A full-width tray: it spans the inner width of the messages panel. }
  Result.W := AAvail.W;
  N := Length(FVisibleCommands);
  if N > PaletteMaxRows then
    N := PaletteMaxRows;
  { A top border row, then one row per command. No bottom border: the tray
    slides out from the composer below it. }
  Result.H := N + 1;
end;

procedure TCommandPalette.MoveSelection(ADelta: Integer);
var
  N: Integer;
begin
  N := Length(FVisibleCommands);
  if N = 0 then
  begin
    FSelected := -1;
    Exit;
  end;
  if FSelected < 0 then
  begin
    FSelected := 0;
    Exit;
  end;
  Inc(FSelected, ADelta);
  if FSelected < 0 then
    FSelected := 0;
  if FSelected > N - 1 then
    FSelected := N - 1;
end;

procedure TCommandPalette.RunSelected;
begin
  if (SelectedName <> '') and Assigned(FOnRun) then
    FOnRun(SelectedName);
end;

function TCommandPalette.RowAt(AY: Integer): Integer;
begin
  Result := AY - (FBounds.Y + 1);   { row 0 is the first command, below the top }
  if (Result < 0) or (Result > High(FVisibleCommands)) then
    Result := -1;
end;

procedure TCommandPalette.Render(const S: ISurface);
var
  L, R, T, X, I, N, RowY, SelBg: Integer;
  Bg, Border, NameAttr, DetailAttr, SelNameAttr, SelDetailAttr: TAttr;
  Name, Detail: string;
begin
  if (FBounds.W < 4) or (FBounds.H < 2) then
    Exit;
  L := FBounds.X;
  R := FBounds.X + FBounds.W - 1;
  T := FBounds.Y;
  N := Length(FVisibleCommands);
  if N > FBounds.H - 1 then
    N := FBounds.H - 1;

  { The ambient palette: the raised background and the violet border, so it
    reads as system functionality. }
  Bg := OnBg(FTheme.Text, FTheme.RaisedBg);
  Border := OnBg(FTheme.Text, FTheme.RaisedBg);
  Border.Fg := PaletteBorderFg;
  Border.Style := Border.Style + [sfDim];
  NameAttr := OnBg(FTheme.Text, FTheme.RaisedBg);
  NameAttr.Fg := PaletteBorderFg;
  { The selected row: an even lighter background across the whole row, with a
    bold command. }
  SelBg := PaletteSelBg;
  SelNameAttr := OnBg(FTheme.Text, SelBg);
  SelNameAttr.Fg := PaletteBorderFg;
  SelNameAttr.Style := SelNameAttr.Style + [sfBold];
  SelDetailAttr := OnBg(FTheme.Muted, SelBg);
  DetailAttr := OnBg(FTheme.Muted, FTheme.RaisedBg);

  S.FillRect(FBounds, Bg);

  { Top border with the title; no bottom border. }
  PutCh(S, L, T, '╭', Border);
  PutCh(S, R, T, '╮', Border);
  for X := L + 1 to R - 1 do
    PutCh(S, X, T, '─', Border);
  PutText(S, L + 2, T, ' commands ', OnBg(FTheme.Muted, FTheme.RaisedBg));

  for I := 0 to N - 1 do
  begin
    Name := '/' + FVisibleCommands[I].Name;
    Detail := FVisibleCommands[I].Description;
    RowY := T + 1 + I;
    { Side borders. }
    PutCh(S, L, RowY, '│', Border);
    PutCh(S, R, RowY, '│', Border);
    if I = FSelected then
    begin
      { A lighter background across the whole inner row, the command bold. }
      S.FillRect(Rc(L + 1, RowY, R - L - 1, 1),
        OnBg(FTheme.Text, SelBg));
      PutText(S, L + 2, RowY, UnicodeString(Name), SelNameAttr);
      if Detail <> '' then
        if R - 2 - Length(Detail) > L + 2 + Length(Name) + 2 then
          PutText(S, R - 2 - Length(Detail), RowY, UnicodeString(Detail),
            SelDetailAttr);
    end
    else
    begin
      PutText(S, L + 2, RowY, UnicodeString(Name), NameAttr);
      { The description, right-aligned, muted, when it fits clear of the name. }
      if Detail <> '' then
        if R - 2 - Length(Detail) > L + 2 + Length(Name) + 2 then
          PutText(S, R - 2 - Length(Detail), RowY, UnicodeString(Detail),
            DetailAttr);
    end;
  end;
end;

function TCommandPalette.HandleEvent(const E: TInputEvent): Boolean;
var
  Row: Integer;
begin
  Result := False;
  if Length(FVisibleCommands) = 0 then
    Exit;
  if E.Kind = ikKey then
  begin
    case E.Key.Kind of
      kkUp:
        begin
          MoveSelection(-1);
          Exit(True);
        end;
      kkDown:
        begin
          MoveSelection(1);
          Exit(True);
        end;
      kkHome:
        begin
          FSelected := 0;
          Exit(True);
        end;
      kkEnd:
        begin
          FSelected := High(FVisibleCommands);
          Exit(True);
        end;
      kkEnter:
        begin
          RunSelected;
          Exit(True);
        end;
    else
      ;
    end;
  end
  else if E.Kind = ikMouse then
  begin
    if (E.Mouse.Button = mbLeft) and
      (E.Mouse.X >= FBounds.X) and (E.Mouse.X <= FBounds.X + FBounds.W - 1) then
    begin
      Row := RowAt(E.Mouse.Y);
      if Row >= 0 then
      begin
        FSelected := Row;
        RunSelected;
        Exit(True);
      end;
    end;
  end;
end;

end.
