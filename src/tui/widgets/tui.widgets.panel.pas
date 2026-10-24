unit tui.widgets.panel;
{ A single-child base and a themed panel.

  TSingleChild owns one child and forwards the widget protocol to it, so a
  composite widget only overrides what it adds. TPanel adds a background, an
  optional box-drawing border with a title, and padding around its child. }

{$mode delphi}{$H+}

interface

uses
  tui.base, tui.input,
  tui.surface, tui.widget,
  tui.theme;

type
  TSingleChild = class(TWidget)
  protected
    FChild: TWidget;
    function Child: TWidget;
  public
    constructor Create(AChild: TWidget);
    destructor Destroy; override;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    function Advance(const ANowMs: Int64): Boolean; override;
    function Animating: Boolean; override;
  end;

  TBoxStyle = record
    Border: Boolean;
    Rounded: Boolean;
    Title: string;        // left-aligned on the top border
    TitleRight: string;   // right-aligned on the top border
    Padding: Integer;
  end;

  TPanel = class(TSingleChild)
  private
    FTheme: TTheme;
    FStyle: TBoxStyle;
    function Inset: Integer;
    function InnerRect: TRect;
    procedure PutCh(const S: ISurface; X, Y: Integer; const ACh: UnicodeString;
      const AAttr: TAttr);
  public
    constructor Create(AChild: TWidget; const ATheme: TTheme;
      const AStyle: TBoxStyle);
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    property Theme: TTheme read FTheme write FTheme;
    property Style: TBoxStyle read FStyle write FStyle;
  end;

function DefaultBoxStyle: TBoxStyle;

implementation

function DefaultBoxStyle: TBoxStyle;
begin
  Result := Default(TBoxStyle);
  Result.Border := True;
  Result.Rounded := False;
  Result.Title := '';
  Result.Padding := 1;
end;

{ TSingleChild }

constructor TSingleChild.Create(AChild: TWidget);
begin
  inherited Create;
  FChild := AChild;
end;

destructor TSingleChild.Destroy;
begin
  FChild.Free;
  inherited Destroy;
end;

function TSingleChild.Child: TWidget;
begin
  Result := FChild;
end;

function TSingleChild.Measure(const AAvail: TSize): TSize;
begin
  if FChild = nil then
    Exit(Default(TSize));
  Result := FChild.Measure(AAvail);
end;

procedure TSingleChild.Arrange(const ABounds: TRect);
begin
  inherited Arrange(ABounds);
  if FChild <> nil then
    FChild.Arrange(ABounds);
end;

procedure TSingleChild.Render(const S: ISurface);
begin
  if FChild <> nil then
    FChild.Render(S);
end;

function TSingleChild.HandleEvent(const E: TInputEvent): Boolean;
begin
  if FChild <> nil then
    Result := FChild.HandleEvent(E)
  else
    Result := False;
end;

function TSingleChild.Advance(const ANowMs: Int64): Boolean;
begin
  if FChild <> nil then
    Result := FChild.Advance(ANowMs)
  else
    Result := False;
end;

function TSingleChild.Animating: Boolean;
begin
  if FChild <> nil then
    Result := FChild.Animating
  else
    Result := False;
end;

{ TPanel }

constructor TPanel.Create(AChild: TWidget; const ATheme: TTheme;
  const AStyle: TBoxStyle);
begin
  inherited Create(AChild);
  FTheme := ATheme;
  FStyle := AStyle;
end;

function TPanel.Inset: Integer;
begin
  Result := FStyle.Padding;
  if FStyle.Border then
    Inc(Result);
end;

function TPanel.InnerRect: TRect;
var
  In2: Integer;
begin
  In2 := Inset * 2;
  Result.X := FBounds.X + Inset;
  Result.Y := FBounds.Y + Inset;
  Result.W := FBounds.W - In2;
  Result.H := FBounds.H - In2;
  if Result.W < 0 then
    Result.W := 0;
  if Result.H < 0 then
    Result.H := 0;
end;

function TPanel.Measure(const AAvail: TSize): TSize;
var
  Sz: TSize;
begin
  Sz := Default(TSize);
  if FChild <> nil then
    Sz := FChild.Measure(AAvail);
  Result.W := Sz.W + Inset * 2;
  Result.H := Sz.H + Inset * 2;
end;

procedure TPanel.Arrange(const ABounds: TRect);
begin
  { Set our own bounds, then give the child the inner rect. Do NOT call the
    inherited Arrange first: TSingleChild would arrange the child at the full
    bounds and we would immediately arrange it again at the inner rect, laying
    the child out twice at two widths. A child that memoises its layout per width
    (the chat stack) then re-measures everything every frame. }
  FBounds := ABounds;
  if FChild <> nil then
    FChild.Arrange(InnerRect);
end;

procedure TPanel.PutCh(const S: ISurface; X, Y: Integer;
  const ACh: UnicodeString; const AAttr: TAttr);
var
  C: TCell;
begin
  C := Default(TCell);
  C.Ch := ACh;
  C.Attr := AAttr;
  S.Put(X, Y, C);
end;

procedure TPanel.Render(const S: ISurface);
var
  L, R, T, B: Integer;
  X, I, LeftW, RightW: Integer;
  LeftTitle, RightTitle: UnicodeString;
begin
  if (FBounds.W <= 0) or (FBounds.H <= 0) then
    Exit;
  S.FillRect(FBounds, FTheme.Panel);

  if FStyle.Border and (FBounds.W >= 2) and (FBounds.H >= 2) then
  begin
    L := FBounds.X;
    R := FBounds.X + FBounds.W - 1;
    T := FBounds.Y;
    B := FBounds.Y + FBounds.H - 1;
    if FStyle.Rounded then
    begin
      PutCh(S, L, T, UnicodeString(WideChar($256D)), FTheme.Border);
      PutCh(S, R, T, UnicodeString(WideChar($256E)), FTheme.Border);
      PutCh(S, L, B, UnicodeString(WideChar($2570)), FTheme.Border);
      PutCh(S, R, B, UnicodeString(WideChar($256F)), FTheme.Border);
    end
    else
    begin
      PutCh(S, L, T, UnicodeString(WideChar($250C)), FTheme.Border);
      PutCh(S, R, T, UnicodeString(WideChar($2510)), FTheme.Border);
      PutCh(S, L, B, UnicodeString(WideChar($2514)), FTheme.Border);
      PutCh(S, R, B, UnicodeString(WideChar($2518)), FTheme.Border);
    end;
    for X := L + 1 to R - 1 do
    begin
      PutCh(S, X, T, UnicodeString(WideChar($2500)), FTheme.Border);
      PutCh(S, X, B, UnicodeString(WideChar($2500)), FTheme.Border);
    end;
    for X := T + 1 to B - 1 do
    begin
      PutCh(S, L, X, UnicodeString(WideChar($2502)), FTheme.Border);
      PutCh(S, R, X, UnicodeString(WideChar($2502)), FTheme.Border);
    end;

    { The two border titles: left after the corner, right before it. The right
      one is skipped when it would run into the left. }
    if FStyle.Title <> '' then
      LeftTitle := UnicodeString(' ' + FStyle.Title + ' ')
    else
      LeftTitle := '';
    if FStyle.TitleRight <> '' then
      RightTitle := UnicodeString(' ' + FStyle.TitleRight + ' ')
    else
      RightTitle := '';
    LeftW := Length(LeftTitle);
    RightW := Length(RightTitle);

    if (LeftW > 0) and (FBounds.W > 4) then
    begin
      if LeftW > FBounds.W - 2 then
        LeftW := FBounds.W - 2;
      for I := 1 to LeftW do
        PutCh(S, L + I, T, UnicodeString(LeftTitle[I]), FTheme.Title);
    end;

    if (RightW > 0) and (RightW <= FBounds.W - 2) and
      ((R - RightW) > (L + LeftW)) then
      for I := 1 to RightW do
        PutCh(S, R - RightW + I - 1, T, UnicodeString(RightTitle[I]),
          FTheme.Title);
  end;

  if FChild <> nil then
    FChild.Render(S);
end;

end.
