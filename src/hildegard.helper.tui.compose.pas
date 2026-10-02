unit hildegard.helper.tui.compose;
{ The chat input box: a raised, heavy-topped panel wrapping a TTextEdit, so the
  caret, wrapping, word motion and selection come from the editor.

  A plain Enter submits; Shift+Enter reaches the editor and adds a line. }

{$mode delphi}{$H+}{$codepage utf8}

interface

uses
  Classes, SysUtils,
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget,
  hildegard.helper.tui.text, hildegard.helper.tui.edit,
  hildegard.helper.tui.theme;

type
  TComposeSubmittedEvent = procedure(const AText: string) of object;

  TComposeBox = class(TWidget)
  private
    FTheme: TTheme;
    FInfo: string;
    FEdit: TTextEdit;
    FOnSubmit: TComposeSubmittedEvent;
    FOnChange: TNotifyEvent;
    function GetText: UnicodeString;
    procedure Changed(Sender: TObject);
  public
    constructor Create(const ATheme: TTheme; const AInfo: string);
    destructor Destroy; override;
    procedure Clear;
    { The box height needed to show the text plus its chrome. }
    function NeededHeight(AWidth: Integer): Integer;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Arrange(const ABounds: TRect); override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    function Advance(const ANowMs: Int64): Boolean; override;
    function Animating: Boolean; override;
    property Text: UnicodeString read GetText;
    property Edit: TTextEdit read FEdit;
    property OnSubmit: TComposeSubmittedEvent read FOnSubmit write FOnSubmit;
    { Fired when the text or the caret changes, so the host re-arranges. }
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

implementation

function Rc(AX, AY, AW, AH: Integer): TRect;
begin
  Result := Default(TRect);
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

constructor TComposeBox.Create(const ATheme: TTheme; const AInfo: string);
begin
  inherited Create;
  FTheme := ATheme;
  FInfo := AInfo;
  FEdit := TTextEdit.Create(wmWord);
  FEdit.Attr := OnBg(FTheme.Text, FTheme.RaisedBg);
  FEdit.CaretAttr := OnBg(WithStyle(FTheme.Accent, [sfBold]), FTheme.RaisedBg);
  FEdit.SelAttr := FEdit.CaretOverlay;
  FEdit.OnChange := Changed;
end;

destructor TComposeBox.Destroy;
begin
  FEdit.Free;
  inherited Destroy;
end;

function TComposeBox.GetText: UnicodeString;
begin
  Result := FEdit.Text;
end;

procedure TComposeBox.Changed(Sender: TObject);
begin
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TComposeBox.Clear;
begin
  FEdit.Clear;
end;

function TComposeBox.NeededHeight(AWidth: Integer): Integer;
var
  InnerW: Integer;
begin
  InnerW := AWidth - 4;
  if InnerW < 1 then
    InnerW := 1;
  { Top and bottom borders, the text rows, a blank, and the info line. }
  Result := Length(FEdit.Rows(InnerW)) + 4;
end;

function TComposeBox.Measure(const AAvail: TSize): TSize;
begin
  Result := Default(TSize);
  Result.W := AAvail.W;
  Result.H := NeededHeight(AAvail.W);
end;

procedure TComposeBox.Arrange(const ABounds: TRect);
var
  TextRows: Integer;
begin
  inherited Arrange(ABounds);
  TextRows := ABounds.H - 4;
  if TextRows < 1 then
    TextRows := 1;
  FEdit.Arrange(Rc(ABounds.X + 2, ABounds.Y + 1, ABounds.W - 4, TextRows));
end;

procedure TComposeBox.Render(const S: ISurface);
var
  L, R, T, B, X, I: Integer;
  SurfaceAttr, Border: TAttr;
begin
  if (FBounds.W < 4) or (FBounds.H < 4) then
    Exit;
  L := FBounds.X;
  R := FBounds.X + FBounds.W - 1;
  T := FBounds.Y;
  B := FBounds.Y + FBounds.H - 1;

  SurfaceAttr := OnBg(FTheme.Text, FTheme.RaisedBg);
  Border := OnBg(WithStyle(FTheme.Accent, [sfDim]), FTheme.RaisedBg);

  S.FillRect(FBounds, SurfaceAttr);

  { Heavy top, single bottom, light sides. }
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

  FEdit.Render(S);

  { Info line. }
  PutText(S, L + 2, B - 1, UnicodeString(FInfo),
    OnBg(FTheme.Muted, FTheme.RaisedBg));
end;

function TComposeBox.HandleEvent(const E: TInputEvent): Boolean;
begin
  Result := False;
  if E.Kind <> ikKey then
    Exit;
  { A plain Enter submits; everything else, including Shift+Enter, belongs to
    the editor. }
  if (E.Key.Kind = kkEnter) and (not (moShift in E.Key.Mods)) then
  begin
    if Assigned(FOnSubmit) and (Trim(string(FEdit.Text)) <> '') then
    begin
      FOnSubmit(string(FEdit.Text));
      FEdit.Clear;
    end;
    Exit(True);
  end;
  Result := FEdit.HandleEvent(E);
end;

function TComposeBox.Advance(const ANowMs: Int64): Boolean;
begin
  Result := FEdit.Advance(ANowMs);
end;

function TComposeBox.Animating: Boolean;
begin
  Result := FEdit.Animating;
end;

end.
