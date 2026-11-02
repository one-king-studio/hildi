program ui_capture;
{ Renders the REAL widgets to a memory surface and dumps the painted rows.

  This exists so the design document shows what the code actually draws rather
  than what someone remembers it drawing. Every row comes out of TSurfaceMemory
  after a genuine Arrange + Render.

  Two traps this program exists to avoid, both found the hard way:
    - RowText concatenates each cell's Ch, and an untouched cell's Ch is
      ErasedChar (EMPTY), not a space - so blank columns vanish and every
      position after them is wrong. Rows are therefore built CELL BY CELL.
    - Writing a UnicodeString with WriteLn depends on the console codepage and
      turns every box-drawing glyph into '?'. Output is UTF-8 bytes instead.

  Run: make ui-capture }

{$mode delphi}{$H+}{$codepage utf8}

uses
  {$ifdef unix}cwstring,{$endif}
  SysUtils,
  TUIBase, TUISurface, TUIWidget, TUITheme,
  TUIWidgetsChat, TUIWidgetsChatPanel;

const
  W = 78;
  H = 22;

var
  Theme: TTheme;

procedure Emit(const AText: UnicodeString);
begin
  Write(UTF8Encode(AText));
end;

{ One row, cell by cell, padded to the full width so columns can be measured.
  '|' marks the true end of the row. }
procedure EmitRow(S: TSurfaceMemory; AY: Integer);
var
  X: Integer;
  Line: UnicodeString;
  C: TCell;
begin
  Line := '';
  for X := 0 to S.Width - 1 do
  begin
    C := S.CellAt(X, AY);
    if C.Ch = '' then
      Line := Line + ' '
    else
      Line := Line + C.Ch;
  end;
  Emit(Line + '|'#10);
end;

procedure EmitRuler(AWidth: Integer);
var
  X: Integer;
  R: UnicodeString;
begin
  R := '';
  for X := 0 to AWidth - 1 do
    if (X mod 10) = 0 then
      R := R + UnicodeString(IntToStr((X div 10) mod 10))
    else
      R := R + ' ';
  Emit(R + '|'#10);
end;

procedure Dump(const ATitle: string; S: TSurfaceMemory);
var
  Y: Integer;
begin
  Emit('=== ' + UnicodeString(ATitle) + ' ==='#10);
  EmitRuler(S.Width);
  for Y := 0 to S.Height - 1 do
    EmitRow(S, Y);
  Emit('=== end ==='#10#10);
end;

{ The panel is painted the way the app paints it: Arrange, one Advance at t=0
  (so the sparkle shows its first frame), then Render. }
procedure Paint(P: TChatPanel; AWidth, AHeight: Integer; const ATitle: string);
var
  S: TSurfaceMemory;
  R: TRect;
begin
  S := TSurfaceMemory.Create(AWidth, AHeight);
  try
    R.X := 0; R.Y := 0; R.W := AWidth; R.H := AHeight;
    P.Arrange(R);
    P.Advance(0);
    P.Render(S);
    Dump(ATitle, S);
  finally
    S.Free;
  end;
end;

procedure CaptureFresh;
var
  P: TChatPanel;
begin
  P := TChatPanel.Create(Theme, 'Hildi', 'shift+enter newline');
  try
    P.SetHeader('agent-1 - Fix the login redirect', '18% ctx');
    P.SetStatus('~/code/hildi');
    P.SetStats('12 turns · 18% ctx');
    P.SetRecentSessions(['Fix the login redirect',
      'A deliberately very long session title that must be truncated',
      'Docs sweep']);
    P.SetState(psReady, 'Idle');
    Paint(P, W, H, 'FRESH SESSION - empty transcript, 3 recent sessions');
  finally
    P.Free;
  end;

  { The same screen with NO recent sessions: the hint stands alone. }
  P := TChatPanel.Create(Theme, 'Hildi', 'shift+enter newline');
  try
    P.SetHeader('agent-1 - Fix the login redirect', '18% ctx');
    P.SetStatus('~/code/hildi');
    P.SetStats('12 turns · 18% ctx');
    P.SetRecentSessions([]);
    P.SetState(psReady, 'Idle');
    Paint(P, W, H, 'FRESH SESSION - no recent sessions');
  finally
    P.Free;
  end;
end;

procedure CaptureConversation;
var
  P: TChatPanel;
  B: TChatItem;
begin
  P := TChatPanel.Create(Theme, 'Hildi',
    'shift+enter newline · ctrl+d subagents');
  try
    P.SetHeader('agent-1 - Fix the login redirect', '18% ctx');
    P.SetStatus('~/code/hildi');
    P.SetStats('12 turns · 18% ctx');

    P.Stream.Add(ckUser, '', 'fix the login redirect, it loops on /callback');
    P.Stream.Add(ckAssistant, '',
      'The loop comes from the missing state check. Two changes:');

    B := P.Stream.Add(ckThought, 'Thinking...', '');
    B.Label_ := 'Thought · 4.2s';
    B.SetText('the redirect fires before the session cookie is set, so the ' +
      'callback cannot validate it');

    B := P.Stream.Add(ckTool, 'Reading src/auth/redirect.pas', '');
    B.SetText('program redirect;');

    B := P.Stream.Add(ckTool, 'Running make check', '');
    B.SetText('Number of run tests: 2090'#10'Number of failures: 0'#10 +
      'all checks passed');

    P.SetState(psTool, 'Editing src/auth/redirect.pas');
    Paint(P, W, H, 'CONVERSATION - thought + two tool blocks - state Tool');
  finally
    P.Free;
  end;
end;

{ Every toolbar state, painted at the same width, showing ONLY the toolbar row -
  the row that carries the hints. Emitted with UTF-8 like everything else. }
procedure CaptureToolbarStates;
var
  P: TChatPanel;
  S: TSurfaceMemory;
  R: TRect;
  Line: UnicodeString;

  procedure One(AKind: TPanelState; const ALabel: string);
  var
    X, Y: Integer;
    C: TCell;
    Found: Boolean;
  begin
    P := TChatPanel.Create(Theme, 'Hildi',
      'shift+enter newline · ctrl+d subagents');
    S := TSurfaceMemory.Create(W, H);
    try
      P.SetState(AKind, ALabel);
      R.X := 0; R.Y := 0; R.W := W; R.H := H;
      P.Arrange(R);
      P.Advance(0);
      P.Render(S);
      { The toolbar is the row directly above the composer's top border, which
        is the heavy '=' line. Find that line, then read the row above it. }
      { The composer's top edge is the HEAVY line '╭═══╮': column 0 is the corner,
        so the heavy run starts at column 1. Checking column 0 for '═' never
        matched. }
      Found := False;
      for Y := 1 to S.Height - 1 do
      begin
        C := S.CellAt(1, Y);
        if (C.Ch <> '') and (Pos('═', UnicodeString(C.Ch)) > 0) then
        begin
          Line := '';
          for X := 0 to S.Width - 1 do
          begin
            C := S.CellAt(X, Y - 1);
            if C.Ch = '' then
              Line := Line + ' '
            else
              Line := Line + C.Ch;
          end;
          Emit(Line + '|'#10);
          Found := True;
          Break;
        end;
      end;
      if not Found then
        Emit('<no composer border found>'#10);
    finally
      S.Free;
      P.Free;
    end;
  end;

begin
  Emit('=== TOOLBAR STATES - the row carrying the hints ==='#10);
  One(psReady, 'Ready');
  One(psThinking, 'Thinking');
  One(psTool, 'Editing src/auth/redirect.pas');
  One(psApproval, 'Approval needed');
  One(psInterrupt, 'Press Esc again to cancel');
  One(psError, 'Error');
  One(psReady, 'Cancelled');
  One(psThinking, 'Checkpointing');
  Emit('=== end ==='#10#10);
end;

{ The narrow case: a long label must not eat the hints. }
procedure CaptureNarrow;
var
  P: TChatPanel;
begin
  P := TChatPanel.Create(Theme, 'Hildi', 'shift+enter newline');
  try
    P.SetState(psTool, 'Editing src/tui/widgets/TUIWidgetsChatPanel.pas');
    Paint(P, 52, 10, 'NARROW 52 cols - long label + hints');
  finally
    P.Free;
  end;
end;

begin
  Theme := DarkTheme;
  CaptureFresh;
  CaptureConversation;
  CaptureToolbarStates;
  CaptureNarrow;
end.
