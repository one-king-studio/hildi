unit TUIWidgetsButton;
{ A focusable button: [ caption ]. Enter/Space (when focused) or a left click
  fires OnClick. }

{$mode delphi}{$H+}

interface

uses
  Classes, TUIBase, TUIInput,
  TUISurface, TUIWidget,
  TUITheme, TUIWidgetsFocus;

type
  TButton = class(TFocusable)
  private
    FCaption: string;
    FTheme: TTheme;
    FOnClick: TNotifyEvent;
    function LabelText: UnicodeString;
    procedure Fire;
  public
    constructor Create(const ACaption: string; const ATheme: TTheme);
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    property Caption: string read FCaption write FCaption;
    property Theme: TTheme read FTheme write FTheme;
    property OnClick: TNotifyEvent read FOnClick write FOnClick;
  end;

implementation

constructor TButton.Create(const ACaption: string; const ATheme: TTheme);
begin
  inherited Create;
  FCaption := ACaption;
  FTheme := ATheme;
end;

function TButton.LabelText: UnicodeString;
begin
  Result := UnicodeString('[ ' + FCaption + ' ]');
end;

procedure TButton.Fire;
begin
  if Assigned(FOnClick) then
    FOnClick(Self);
end;

function TButton.Measure(const AAvail: TSize): TSize;
begin
  Result := Default(TSize);
  Result.W := Length(LabelText);
  Result.H := 1;
  if Result.W > AAvail.W then
    Result.W := AAvail.W;
end;

procedure TButton.Render(const S: ISurface);
var
  Text: UnicodeString;
  A: TAttr;
  I, X: Integer;
  C: TCell;
begin
  if (FBounds.W <= 0) or (FBounds.H <= 0) then
    Exit;
  Text := LabelText;
  A := FTheme.Text;
  if Focused then
  begin
    A := FTheme.Accent;
    Include(A.Style, sfReverse);
  end;
  for I := 1 to Length(Text) do
  begin
    X := FBounds.X + I - 1;
    if X >= FBounds.X + FBounds.W then
      Break;
    C := Default(TCell);
    C.Ch := UnicodeString(Text[I]);
    C.Attr := A;
    S.Put(X, FBounds.Y, C);
  end;
end;

function TButton.HandleEvent(const E: TInputEvent): Boolean;
begin
  if E.Kind = ikKey then
  begin
    if (E.Key.Kind = kkEnter) or
      ((E.Key.Kind = kkChar) and (E.Key.Ch = ' ')) then
    begin
      if Focused then
      begin
        Fire;
        Exit(True);
      end;
    end;
  end
  else if E.Kind = ikMouse then
  begin
    if (E.Mouse.Button = mbLeft) and
      (E.Mouse.X >= FBounds.X) and (E.Mouse.X < FBounds.X + FBounds.W) and
      (E.Mouse.Y >= FBounds.Y) and (E.Mouse.Y < FBounds.Y + FBounds.H) then
    begin
      Fire;
      Exit(True);
    end;
  end;
  Result := False;
end;

end.
