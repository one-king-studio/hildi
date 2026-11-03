unit TUIWidgetsPalette;
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
  Classes, SysUtils, TUIBase, TUIInput,
  TUISurface, TUIWidget,
  TUITheme, HildiFuzzy, TUIWidgetsText;

type
  TCommand = record
    Name: string;          // e.g. 'checkpoint' (no slash)
    Description: string;   // a one-line summary
  end;
  TCommandArray = array of TCommand;

  TCommandRunEvent = procedure(const AName: string) of object;

  { A SECOND way to act on the selected row. The palette is a general list
    surface: the command list has one verb (enter select), the skills list has
    two (ctrl+r review, enter use). A panel declares its verbs and the palette
    renders the hints and dispatches the chords, so a third panel needs no
    palette change. }
  TCommandVerb = record
    Chord: string;    // 'ctrl+r' - matched against the key event
    Caption: string;  // 'review' - what the hint row calls it
    OnAction: TCommandRunEvent;
  end;
  TCommandVerbArray = array of TCommandVerb;

  TCommandPalette = class(TWidget)
  private
    FTheme: TTheme;
    FCommands: TCommandArray;
    FVisibleCommands: TCommandArray;
    FSelected: Integer;
    { The first visible row. Without it a list longer than the panel simply
      clipped at the last row and the selection could move off-screen. }
    FTop: Integer;
    FOnRun: TCommandRunEvent;
    FVerbs: TCommandVerbArray;
    { What the enter key does on this panel: 'select' for commands, 'use' for
      skills. Per-panel because the same key means different things. }
    FDefaultCaption: string;
    { The panel's title. The palette serves two lists (commands and skills), and
      a fixed "commands" title told the operator the wrong thing on the skills
      list. }
    FTitle: string;
    procedure MoveSelection(ADelta: Integer);
    procedure RunSelected;
    procedure EnsureVisible;
    function VisibleRows: Integer;
    function RowAt(AY: Integer): Integer;
    { The hint row: every verb, then the default, right-aligned. }
    function SelectedHints: string;
    function ChordOf(const E: TInputEvent): string;
    function PaletteWidth: Integer;
  public
    constructor Create(const ATheme: TTheme);
    { Replace the command set (the full list; Filter narrows the view). }
    procedure SetCommands(const ACommands: TCommandArray);
    { What the top border calls this list: 'commands' or 'skills'. }
    procedure SetTitle(const ATitle: string);
    { Extra verbs beyond enter. Cleared by setting an empty array, so a panel that
      switches lists cannot leave another panel's chords armed. }
    procedure SetVerbs(const AVerbs: TCommandVerbArray;
      const ADefaultCaption: string);
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
    { One verb, for a host that wants no extras. Kept because the command list
      uses exactly this shape. }
    procedure SetSingleVerb(const AHandler: TCommandRunEvent;
      const ADefaultCaption: string);
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
begin
  Result := nil;
  P := APrefix;
  if (P <> '') and (P[1] = '/') then
    P := Copy(P, 2, MaxInt);
  for I := 0 to High(ACommands) do
  begin
    { Fuzzy (subsequence) match on the command name, so "/cp" finds "checkpoint"
      and a mistyped middle still narrows. An empty prefix shows all. }
    if FuzzyMatches(P, ACommands[I].Name) then
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
  FTop := 0;
  FTitle := 'commands';
  FDefaultCaption := 'select';
  FVerbs := nil;
end;

procedure TCommandPalette.SetVerbs(const AVerbs: TCommandVerbArray;
  const ADefaultCaption: string);
begin
  FVerbs := Copy(AVerbs, 0, Length(AVerbs));
  if ADefaultCaption = '' then
    FDefaultCaption := 'select'
  else
    FDefaultCaption := ADefaultCaption;
end;

procedure TCommandPalette.SetSingleVerb(const AHandler: TCommandRunEvent;
  const ADefaultCaption: string);
begin
  { The command list's shape: enter and nothing else. Setting an empty verb array
    matters - a panel that switches to this must not leave the other panel's
    chords armed. }
  FVerbs := nil;
  SetVerbs(nil, ADefaultCaption);
  FOnRun := AHandler;
end;

function TCommandPalette.VisibleRows: Integer;
begin
  { Rows inside the borders, minus the reserved hint row at the bottom. }
  Result := FBounds.H - 2;
  if Result < 1 then
    Result := 1;
end;

procedure TCommandPalette.EnsureVisible;
var
  Rows: Integer;
begin
  { Keep the selection on screen. Without this a list longer than the panel
    simply clipped and the selection walked off the bottom. }
  Rows := VisibleRows;
  if FSelected < FTop then
    FTop := FSelected;
  if FSelected >= FTop + Rows then
    FTop := FSelected - Rows + 1;
  if FTop < 0 then
    FTop := 0;
end;

function TCommandPalette.ChordOf(const E: TInputEvent): string;
begin
  Result := '';
  if (E.Kind <> ikKey) or (E.Key.Kind <> kkChar) then
    Exit;
  if not (moCtrl in E.Key.Mods) then
    Exit;
  Result := 'ctrl+' + LowerCase(string(E.Key.Ch));
end;

procedure TCommandPalette.SetCommands(const ACommands: TCommandArray);
begin
  FCommands := Copy(ACommands, 0, Length(ACommands));
  Filter('');
end;

procedure TCommandPalette.SetTitle(const ATitle: string);
begin
  if ATitle = '' then
    FTitle := 'commands'
  else
    FTitle := ATitle;
end;

procedure TCommandPalette.Filter(const APrefix: string);
begin
  FVisibleCommands := FilterCommands(FCommands, APrefix);
  { A narrowed list is a different list, so the scroll offset is stale. }
  FTop := 0;
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

function TCommandPalette.SelectedHints: string;
var
  I: Integer;
  { Built at RUN TIME, not written as a literal: assigning a UnicodeString
    literal into an AnsiString result raises a lossy-conversion warning, which
    this project treats as an error. HintSpans builds its separator the same way
    for the same reason - FPC does not apply the source codepage to a typed
    constant. }
  Sep: UnicodeString;
begin
  { Built from the panel's VERBS, so a third list panel needs no palette change:
    it declares its chords and captions and the hint row follows.

    Segments are separated by ' · ', the separator HintSpans recognises. Two
    spaces instead would make the WHOLE line one segment, so only the first key
    got its own tone and the rest was drawn as one action - which is why the
    command panel's "enter select" did not read as two-tone. }
  Sep := ' ' + UnicodeString(WideChar($00B7)) + ' ';
  Result := '';
  if (FSelected < 0) or (FSelected > High(FVisibleCommands)) then
    Exit;
  for I := 0 to High(FVerbs) do
  begin
    if Result <> '' then
      Result := Result + string(Sep);
    Result := Result + FVerbs[I].Chord + ' ' + FVerbs[I].Caption;
  end;
  if Result <> '' then
    Result := Result + string(Sep);
  Result := Result + 'enter ' + FDefaultCaption;
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
  { A top border row, one row per command, and a RESERVED row for the shortcut
    hints. The hint row must be counted here: the render reserves the panel's
    last row for it, so a height of N+1 left only N-1 rows for commands and the
    last one - or, with a single command, the ONLY one - was clipped away. }
  Result.H := N + 2;
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
  { WRAP, do not clamp. A list that stops dead at the last row makes the operator
    press up N times to get back to the top, where one more down gets there. The
    two lists share this slider, so both get the wrapping. }
  if FSelected < 0 then
    FSelected := N - 1;
  if FSelected > N - 1 then
    FSelected := 0;
  EnsureVisible;
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
  L, R, T, X, I, N, RowY, SelBg, HintY, HX: Integer;
  Bg, Border, NameAttr, DetailAttr, SelNameAttr, SelDetailAttr: TAttr;
  Name, Detail, Hint: string;
  Spans: TSpanArray;
begin
  if (FBounds.W < 4) or (FBounds.H < 2) then
    Exit;
  L := FBounds.X;
  R := FBounds.X + FBounds.W - 1;
  T := FBounds.Y;
  N := Length(FVisibleCommands);
  { Reserve the LAST row for the shortcut hints, so a long list cannot push them
    off the panel. }
  if N > FBounds.H - 2 then
    N := FBounds.H - 2;
  if N < 0 then
    N := 0;

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
  PutText(S, L + 2, T, UnicodeString(' ' + FTitle + ' '),
    OnBg(FTheme.Muted, FTheme.RaisedBg));

  for I := 0 to N - 1 do
  begin
    { Offset by FTop: without it a scrolled selection is drawn off-panel and the
      operator moves the highlight invisibly. }
    Name := '/' + FVisibleCommands[FTop + I].Name;
    Detail := FVisibleCommands[FTop + I].Description;
    RowY := T + 1 + I;
    { Side borders. }
    PutCh(S, L, RowY, '│', Border);
    PutCh(S, R, RowY, '│', Border);
    if (FTop + I) = FSelected then
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

  { The shortcut hints, on the LAST row, right-aligned. They describe what the
    selected row can do, so they change with the selection: an unloaded skill can
    be reviewed and used, a loaded one can only be used. A row with nothing to
    offer says so rather than showing a key that would do nothing. }
  if FBounds.H >= 2 then
  begin
    HintY := FBounds.Y + FBounds.H - 1;
    PutCh(S, L, HintY, '│', Border);
    PutCh(S, R, HintY, '│', Border);
    Hint := SelectedHints;
    if Hint <> '' then
    begin
      { Two-tone through the shared splitter: the keybinding dim, the action
        lighter. Both attrs carry the PANEL's background - PaintSpans only sets
        the foreground, so an attr built on a bare colour would leave the row
        with whatever background the fill gave it and read as a stripe. }
      Spans := HintSpans(UnicodeString(Hint),
        OnBg(FTheme.Muted, FTheme.RaisedBg),
        OnBg(FTheme.Text, FTheme.RaisedBg));
      HX := R - 1 - SpansWidth(Spans);
      if HX < L + 1 then
        HX := L + 1;
      PaintSpans(S, HX, HintY, Spans);
    end;
  end;
end;

function TCommandPalette.HandleEvent(const E: TInputEvent): Boolean;
var
  Row, I: Integer;
  Chord: string;
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
      kkChar:
        { A declared VERB. The palette renders each verb's chord in the hint row
          and dispatches it here, so a new list panel declares its chords rather
          than the palette growing a branch per panel. A chord, not a bare key, so
          the letter stays typable while filtering. }
        begin
          Chord := ChordOf(E);
          if (Chord <> '') and (SelectedName <> '') then
            for I := 0 to High(FVerbs) do
              if (FVerbs[I].Chord = Chord) and Assigned(FVerbs[I].OnAction) then
              begin
                FVerbs[I].OnAction(SelectedName);
                Exit(True);
              end;
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
