unit hildegard.helper.tui.conversation;
{ A scrolling, styled transcript for the TUI. It composes TTextBlock inside a
  TScrollContainer and adds append and sticky-to-bottom behaviour: new content
  keeps the view at the bottom unless the user has scrolled up, and following
  resumes when the user returns to the bottom. }

{$mode delphi}{$H+}

interface

uses
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget,
  hildegard.helper.tui.text, hildegard.helper.tui.scroll;

type
  { A transcript view. Append styled spans; the block is re-laid out on Arrange
    (driven by TTuiApp.Invalidate). }
  TConversationView = class(TWidget)
  private
    FBlock: TTextBlock;
    FScroll: TScrollContainer;
    FSpans: array of TSpan;
    FFollow: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Append(const AText: UnicodeString; const AAttr: TAttr);
    procedure AppendSpans(const ASpans: array of TSpan);
    procedure Clear;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    { The full transcript text (all appended spans), for tests and exports. }
    function Text: UnicodeString;
    { The first visible content line. }
    function ScrollY: Integer;
    { True while the view is pinned to the bottom. }
    property Following: Boolean read FFollow;
  end;

implementation

constructor TConversationView.Create;
begin
  inherited Create;
  FSpans := nil;
  FFollow := True;
  { v1 clips rather than wraps; wrapping is a container concern for later. }
  FBlock := TTextBlock.Create([], wmNone);
  FScroll := TScrollContainer.Create(FBlock, smAuto, smNever);
end;

destructor TConversationView.Destroy;
begin
  FScroll.Free;
  inherited Destroy;
end;

procedure TConversationView.Append(const AText: UnicodeString;
  const AAttr: TAttr);
var
  One: TSpan;
begin
  One := Default(TSpan);
  One.Text := AText;
  One.Attr := AAttr;
  AppendSpans([One]);
end;

procedure TConversationView.AppendSpans(const ASpans: array of TSpan);
var
  I, N: Integer;
begin
  N := Length(FSpans);
  SetLength(FSpans, N + Length(ASpans));
  for I := 0 to High(ASpans) do
    FSpans[N + I] := ASpans[I];
  FBlock.SetSpans(FSpans);
end;

function TConversationView.Text: UnicodeString;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(FSpans) do
    Result := Result + FSpans[I].Text;
end;

function TConversationView.ScrollY: Integer;
begin
  Result := FScroll.ScrollY;
end;

procedure TConversationView.Clear;
begin
  FSpans := nil;
  FBlock.SetSpans([]);
  FFollow := True;
  FScroll.ScrollY := 0;
end;

function TConversationView.Measure(const AAvail: TSize): TSize;
begin
  Result := AAvail;
end;

procedure TConversationView.Arrange(const ABounds: TRect);
begin
  inherited Arrange(ABounds);
  FScroll.Arrange(ABounds);
  if FFollow then
    FScroll.ScrollY := High(Integer);
end;

procedure TConversationView.Render(const S: ISurface);
begin
  FScroll.Render(S);
end;

function TConversationView.HandleEvent(const E: TInputEvent): Boolean;
begin
  Result := FScroll.HandleEvent(E);
  if Result then
    FFollow := FScroll.ScrollY >= FScroll.MaxScrollY;
end;

end.
