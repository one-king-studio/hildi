unit TUIWidgetsDiffviewer;
{ The diff viewer pane: one file's stored diff, scrolled, read-only.

  The turn-summary block can already show every file's diff at once by expanding,
  which is legible but not reviewable - the operator asked to pick a file and look
  at that file. This is that pane.

  It deliberately knows nothing about the change log or the store. It is handed a
  path and a list of already-parsed lines and does three things: draw them with
  added/removed/hunk distinguished by BOTH colour and a leading glyph, scroll, and
  close. That keeps the parse (TDiffView) and the presentation separate, makes the
  pane testable with no database, and means it can never read a workspace file -
  the diff it renders is the one that was recorded.

  Read-only by construction: there is no edit path, and Escape closes it without
  touching the stream. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils,
  TUIBase, TUIInput,
  TUISurface, TUIWidget,
  TUITheme, TUIGrapheme;

type
  { What a pane line is. Mirrors TDiffLineKind in ChangesSummary, declared here
    so the widget does not depend on the change library: the app maps one to the
    other, and the pane stays testable with no store and no diff parser. }
  TDiffPaneKind = (dpFile, dpHunk, dpAdded, dpRemoved, dpContext);

  { One rendered line of a diff. The kind is what picks the colour and glyph; the
    caveat flag marks a line that is a NOTE rather than diff content (the
    "not captured" and "capped" notices), so it can be drawn dimmed without
    inventing a second kind enum the app has to map. }
  TDiffPaneLine = record
    Kind: TDiffPaneKind;
    Text: string;
    Caveat: Boolean;
  end;
  TDiffPaneLineArray = array of TDiffPaneLine;

  TDiffViewer = class(TWidget)
  private
    FTheme: TTheme;
    FPath: string;
    FLines: TDiffPaneLineArray;
    FTop: Integer;
    FActive: Boolean;
    FOnClose: TNotifyEvent;
    function BodyRows: Integer;
    function MaxTop: Integer;
    procedure ClampTop;
  public
    constructor Create(const ATheme: TTheme);
    { Present a file's parsed diff. Copies the lines, so the caller may free its
      own array immediately. ARows is what was already parsed by TDiffView. }
    procedure Show(const APath: string; const ALines: TDiffPaneLineArray);
    procedure Close;
    property Active: Boolean read FActive;
    property Path: string read FPath;
    property ScrollTop: Integer read FTop;
    { Escape. The host uses it to drop the viewer from the plane. }
    property OnClose: TNotifyEvent read FOnClose write FOnClose;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
  end;

const
  DiffViewerMinWidth = 40;
  { Borders (2) + the path title row (1) + the footer hint row (1). }
  DiffViewerChromeRows = 4;
  { How many lines one PageUp/PageDown moves, as a fraction of the body. }
  DiffViewerPageDivisor = 1;

implementation

function FrameRect(AX, AY, AW, AH: Integer): TRect;
begin
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

constructor TDiffViewer.Create(const ATheme: TTheme);
begin
  inherited Create;
  FTheme := ATheme;
  FTop := 0;
  FActive := False;
end;

procedure TDiffViewer.Show(const APath: string; const ALines: TDiffPaneLineArray);
var
  I: Integer;
begin
  FPath := APath;
  SetLength(FLines, Length(ALines));
  for I := 0 to High(ALines) do
    FLines[I] := ALines[I];
  FTop := 0;
  FActive := True;
end;

procedure TDiffViewer.Close;
begin
  FActive := False;
  SetLength(FLines, 0);
  FPath := '';
  FTop := 0;
end;

function TDiffViewer.BodyRows: Integer;
begin
  { Everything inside the frame, minus the title and footer rows. }
  Result := FBounds.H - DiffViewerChromeRows;
  if Result < 1 then
    Result := 1;
end;

function TDiffViewer.MaxTop: Integer;
begin
  Result := Length(FLines) - BodyRows;
  if Result < 0 then
    Result := 0;
end;

procedure TDiffViewer.ClampTop;
begin
  if FTop > MaxTop then
    FTop := MaxTop;
  if FTop < 0 then
    FTop := 0;
end;

function TDiffViewer.Measure(const AAvail: TSize): TSize;
begin
  { Nearly the whole area: a diff is the thing being read, so it earns the space
    the sessions modal gets. }
  Result.W := AAvail.W - 4;
  if Result.W < DiffViewerMinWidth then
    Result.W := AAvail.W;
  Result.H := AAvail.H - 2;
  if Result.H < DiffViewerChromeRows + 2 then
    Result.H := AAvail.H;
end;

function DynamicGlyph(AKind: TDiffPaneKind): UnicodeString;
begin
  { A glyph AND a colour, always both: the design language requires the cue to
    survive a monochrome terminal or a colour-blind operator. }
  case AKind of
    dpAdded: Result := '+';
    dpRemoved: Result := '-';
    dpHunk: Result := '@';
    dpFile: Result := '=';
  else
    Result := ' ';
  end;
end;

procedure TDiffViewer.Render(const S: ISurface);
var
  L, R, T, B, X, Y, I, Index: Integer;
  Bg, BorderAttr, TitleAttr, MutedAttr, AddedAttr, RemovedAttr, HunkAttr,
    FileAttr, CaveatAttr, Attr: TAttr;
  Line: TDiffPaneLine;
  Text, Glyph: UnicodeString;
begin
  if not FActive then
    Exit;
  if (FBounds.W < 8) or (FBounds.H < DiffViewerChromeRows) then
    Exit;
  L := FBounds.X;
  R := FBounds.X + FBounds.W - 1;
  T := FBounds.Y;
  B := FBounds.Y + FBounds.H - 1;

  Bg := OnBg(FTheme.Text, FTheme.RaisedBg);
  BorderAttr := OnBg(FTheme.Border, FTheme.RaisedBg);
  TitleAttr := OnBg(FTheme.Title, FTheme.RaisedBg);
  MutedAttr := OnBg(FTheme.Muted, FTheme.RaisedBg);
  AddedAttr := OnBg(FTheme.Success, FTheme.RaisedBg);
  RemovedAttr := OnBg(FTheme.Error, FTheme.RaisedBg);
  HunkAttr := OnBg(FTheme.Title, FTheme.RaisedBg);
  FileAttr := OnBg(FTheme.Border, FTheme.RaisedBg);
  CaveatAttr := OnBg(FTheme.Muted, FTheme.RaisedBg);

  S.FillRect(FBounds, Bg);
  PutCh(S, L, T, '╭', BorderAttr);
  PutCh(S, R, T, '╮', BorderAttr);
  PutCh(S, L, B, '╰', BorderAttr);
  PutCh(S, R, B, '╯', BorderAttr);
  for X := L + 1 to R - 1 do
  begin
    PutCh(S, X, T, '─', BorderAttr);
    PutCh(S, X, B, '─', BorderAttr);
  end;
  for Y := T + 1 to B - 1 do
  begin
    PutCh(S, L, Y, '│', BorderAttr);
    PutCh(S, R, Y, '│', BorderAttr);
  end;

  PutText(S, L + 2, T, UnicodeString(' ' + FPath + ' '), TitleAttr);

  ClampTop;
  S.PushClip(FrameRect(L + 1, T + 1, FBounds.W - 2, FBounds.H - 2));
  try
    for I := 0 to BodyRows - 1 do
    begin
      Index := FTop + I;
      if Index > High(FLines) then
        Break;
      Y := T + 1 + I;
      Line := FLines[Index];
      Text := UnicodeString(Line.Text);
      if Line.Caveat then
      begin
        { A notice, not content: no glyph, dimmed, and never coloured as if it
          were a change. }
        PutText(S, L + 2, Y, Text, CaveatAttr);
        Continue;
      end;
      case Line.Kind of
        dpAdded: begin Attr := AddedAttr; Glyph := '+'; end;
        dpRemoved: begin Attr := RemovedAttr; Glyph := '-'; end;
        dpHunk: begin Attr := HunkAttr; Glyph := '@'; end;
        dpFile: begin Attr := FileAttr; Glyph := '='; end;
      else
        begin Attr := Bg; Glyph := ' '; end;
      end;
      PutText(S, L + 2, Y, Glyph, Attr);
      PutText(S, L + 3, Y, Text, Attr);
    end;
  finally
    S.PopClip;
  end;

  { The footer: what the pane is, and how to leave it. }
  PutText(S, L + 2, B - 1, UnicodeString('read-only'), MutedAttr);
  PutText(S, R - 14, B - 1, UnicodeString('esc close'), MutedAttr);
end;

function TDiffViewer.HandleEvent(const E: TInputEvent): Boolean;
var
  Page: Integer;
begin
  Result := False;
  if not FActive then
    Exit;
  if E.Kind <> ikKey then
    Exit;
  Page := BodyRows div DiffViewerPageDivisor;
  if Page < 1 then
    Page := 1;
  case E.Key.Kind of
    kkEscape:
      begin
        if Assigned(FOnClose) then
          FOnClose(Self);
        Close;
        Result := True;
      end;
    kkUp:
      begin
        Dec(FTop);
        ClampTop;
        Result := True;
      end;
    kkDown:
      begin
        Inc(FTop);
        ClampTop;
        Result := True;
      end;
    kkPageUp:
      begin
        Dec(FTop, Page);
        ClampTop;
        Result := True;
      end;
    kkPageDown:
      begin
        Inc(FTop, Page);
        ClampTop;
        Result := True;
      end;
    kkHome:
      begin
        FTop := 0;
        Result := True;
      end;
    kkEnd:
      begin
        FTop := MaxTop;
        Result := True;
      end;
  else
    { Every other key is consumed while the pane is up: the stream underneath is
      not receiving input, and letting a stray key through would act on a
      transcript the operator cannot see past this box. }
    Result := True;
  end;
end;

end.
