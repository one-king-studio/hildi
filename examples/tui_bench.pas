program tui_bench;
{ Manual, printable benchmark for the TUI toolkit.

  Headless by default (TSurfaceMemory, deterministic changed-cell counts). With
  --real it drives the actual TSurfaceVideo end-to-end, including
  video.UpdateScreen, so the numbers reflect a real terminal. It makes no
  timing assertions unless --assert is passed; the operator reads the table.

      make bench            headless table
      make bench ARGS=--real
      make perf             --assert, exits non-zero if a budget is missed

  Budgets (80x50, development machine): full repaint <= 10 ms/frame (>= 100 fps),
  one-line append <= 5 ms/frame (>= 200 fps). }

{$mode delphi}{$H+}

uses
  SysUtils, baseunix, unix,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget,
  hildegard.helper.tui.text, hildegard.helper.tui.scroll,
  hildegard.helper.tui.app,
  hildegard.helper.tui.surface.video, hildegard.helper.tui.input.terminal;

const
  DefW = 80;
  DefH = 50;
  Frames = 200;
  Warmup = 5;

type
  TFrameProc = procedure;

var
  MemSurf: TSurfaceMemory;
  Src: TInputSourceScripted;
  App: TTuiApp;
  ChatBlock: TTextBlock;
  ChatScroll: TScrollContainer;
  ChatText: string;
  ModalUp: Boolean;
  ResizeBig: Boolean;
  AssertBudgets: Boolean;
  Failures: Integer;

function Micros: Int64;
var
  TV: TTimeVal;
begin
  fpgettimeofday(@TV, nil);
  Result := Int64(TV.tv_sec) * 1000000 + Int64(TV.tv_usec);
end;

function SpanOf(const AText: UnicodeString): TSpan;
begin
  Result := Default(TSpan);
  Result.Text := AText;
  Result.Attr := DefaultAttr;
end;

function Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

procedure BuildChat;
var
  I: Integer;
begin
  ChatText := '';
  for I := 0 to 199 do
  begin
    if I > 0 then
      ChatText := ChatText + #10;
    ChatText := ChatText + 'assistant: line ' + IntToStr(I);
  end;
  ChatBlock.SetText(ChatText, DefaultAttr);
end;

procedure BuildLayout(const ASurface: ISurface; const AInput: IInputSource);
var
  Root, Panes, Status: TContainer;
  SecondBlock: TTextBlock;
  SecondScroll: TScrollContainer;
begin
  Root := TContainer.Create([Fill(1)], [Fill(1), Fixed(1)]);
  Panes := TContainer.Create([Fill(2), Fill(1)], [Fill(1)]);
  ChatBlock := TTextBlock.Create([SpanOf('')], wmNone);
  ChatScroll := TScrollContainer.Create(ChatBlock, smAuto, smNever);
  SecondBlock := TTextBlock.Create([SpanOf('file viewport')], wmNone);
  SecondScroll := TScrollContainer.Create(SecondBlock, smAuto, smNever);
  Panes.Add(ChatScroll, 0, 0);
  Panes.Add(SecondScroll, 1, 0);
  Status := TContainer.Create([Fill(1)], [Fixed(1)]);
  Status.Add(TTextBlock.Create([SpanOf('status: ready')], wmNone), 0, 0);
  Root.Add(Panes, 0, 0);
  Root.Add(Status, 0, 1);
  BuildChat;
  App := TTuiApp.Create(ASurface, AInput, Root);
end;

procedure FrameFull;
begin
  App.Step;
end;

procedure FrameAppend;
begin
  ChatText := ChatText + #10 + 'assistant: streaming token';
  ChatBlock.SetText(ChatText, DefaultAttr);
  ChatScroll.ScrollBy(0, 1);
  App.Invalidate;
  App.Step;
end;

procedure FrameScroll;
begin
  ChatScroll.ScrollBy(0, 1);
  App.Step;
end;

procedure FrameResize;
var
  E: TInputEvent;
begin
  if ResizeBig then
    MemSurf.Resize(DefW, DefH)
  else
    MemSurf.Resize(DefW - 1, DefH - 1);
  ResizeBig := not ResizeBig;
  E := Default(TInputEvent);
  E.Kind := ikResize;
  E.NewSize.W := DefW;
  E.NewSize.H := DefH;
  Src.Push(E);
  App.Step;
end;

procedure FrameModal;
var
  Root: TContainer;
  Probe: TTextBlock;
begin
  if ModalUp then
    App.PopPlane
  else
  begin
    Root := TContainer.Create([Fill(1), Fixed(30), Fill(1)],
      [Fill(1), Fixed(5), Fill(1)]);
    Probe := TTextBlock.Create([SpanOf('Approve this command? [y/n]')],
      wmNone);
    Root.Add(Probe, 1, 1);
    Root.Arrange(Rc(0, 0, DefW, DefH));
    App.PushPlane(TPlane.Create(Root, True, True));
  end;
  ModalUp := not ModalUp;
  App.Step;
end;

procedure Measure(const AName: string; AProc: TFrameProc; ABudgetMs: Double);
var
  I: Integer;
  T0, T1, Changed: Int64;
  TotalMs, MsPerFrame, Fps: Double;
  Verdict: string;
begin
  for I := 1 to Warmup do
    AProc;
  Changed := 0;
  T0 := Micros;
  for I := 1 to Frames do
  begin
    AProc;
    if MemSurf <> nil then
      Inc(Changed, MemSurf.LastFrameChangedCells);
  end;
  T1 := Micros;
  TotalMs := (T1 - T0) / 1000.0;
  MsPerFrame := TotalMs / Frames;
  if TotalMs > 0 then
    Fps := Frames * 1000.0 / TotalMs
  else
    Fps := 0;
  if (ABudgetMs > 0) and (MsPerFrame > ABudgetMs) then
  begin
    Verdict := 'FAIL';
    Inc(Failures);
  end
  else if ABudgetMs > 0 then
    Verdict := 'ok'
  else
    Verdict := '-';
  if MemSurf <> nil then
    WriteLn(Format('%-8s frames=%d  %8.3f ms/frame  %8.1f fps  changed/frame=%.1f  %s',
      [AName, Frames, MsPerFrame, Fps, Changed / Frames, Verdict]))
  else
    WriteLn(Format('%-8s frames=%d  %8.3f ms/frame  %8.1f fps  %s',
      [AName, Frames, MsPerFrame, Fps, Verdict]));
end;

procedure RunHeadless;
begin
  MemSurf := TSurfaceMemory.Create(DefW, DefH);
  Src := TInputSourceScripted.Create;
  try
    BuildLayout(MemSurf, Src);
    WriteLn('TUI benchmark (headless, memory surface), ', DefW, 'x', DefH,
      ', ', Frames, ' frames/scenario');
    Measure('full', FrameFull, 10.0);
    Measure('scroll', FrameScroll, 0);
    Measure('append', FrameAppend, 5.0);
    Measure('resize', FrameResize, 0);
    Measure('modal', FrameModal, 0);
  finally
    App.Free;
    MemSurf := nil;
  end;
end;

procedure RunReal;
var
  VS: TSurfaceVideo;
  VInput: TInputSourceTerminal;
begin
  VS := TSurfaceVideo.Create;
  VInput := TInputSourceTerminal.Create;
  try
    BuildLayout(VS, VInput);
    WriteLn('TUI benchmark (real terminal via video)');
    Measure('full', FrameFull, 10.0);
    Measure('scroll', FrameScroll, 0);
    Measure('append', FrameAppend, 5.0);
    Measure('modal', FrameModal, 0);
  finally
    App.Free;
  end;
end;

var
  I: Integer;
  UseReal: Boolean;
begin
  UseReal := False;
  AssertBudgets := False;
  for I := 1 to ParamCount do
    if ParamStr(I) = '--real' then
      UseReal := True
    else if ParamStr(I) = '--assert' then
      AssertBudgets := True;

  Failures := 0;
  if UseReal then
    RunReal
  else
    RunHeadless;

  if AssertBudgets and (Failures > 0) then
  begin
    WriteLn('budgets missed: ', Failures);
    Halt(1);
  end;
end.
