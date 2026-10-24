unit tui.widgets.list;
{ A focusable, selectable list. Up/Down/Home/End move the selection; Enter fires
  OnActivate. Place it in a TScrollContainer for long lists. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, tui.base, tui.input,
  tui.surface, tui.widget,
  tui.theme, tui.widgets.focus;

type
  TListView = class(TFocusable)
  private
    FItems: TStringList;
    FSelected: Integer;
    FTheme: TTheme;
    FOnActivate: TNotifyEvent;
    procedure SetSelected(AValue: Integer);
    procedure Move(ADelta: Integer);
  public
    constructor Create(const ATheme: TTheme);
    destructor Destroy; override;
    procedure AddItem(const AText: string);
    procedure Clear;
    function Count: Integer;
    function ItemAt(AIndex: Integer): string;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    property Selected: Integer read FSelected write SetSelected;  // -1 = none
    property Theme: TTheme read FTheme write FTheme;
    property OnActivate: TNotifyEvent read FOnActivate write FOnActivate;
  end;

implementation

constructor TListView.Create(const ATheme: TTheme);
begin
  inherited Create;
  FItems := TStringList.Create;
  FTheme := ATheme;
  FSelected := -1;
end;

destructor TListView.Destroy;
begin
  FItems.Free;
  inherited Destroy;
end;

procedure TListView.AddItem(const AText: string);
begin
  FItems.Add(AText);
  if FSelected < 0 then
    FSelected := 0;
end;

procedure TListView.Clear;
begin
  FItems.Clear;
  FSelected := -1;
end;

function TListView.Count: Integer;
begin
  Result := FItems.Count;
end;

function TListView.ItemAt(AIndex: Integer): string;
begin
  if (AIndex >= 0) and (AIndex < FItems.Count) then
    Result := FItems[AIndex]
  else
    Result := '';
end;

procedure TListView.SetSelected(AValue: Integer);
begin
  if AValue < -1 then
    AValue := -1;
  if AValue >= FItems.Count then
    AValue := FItems.Count - 1;
  FSelected := AValue;
end;

procedure TListView.Move(ADelta: Integer);
var
  N: Integer;
begin
  if FItems.Count = 0 then
  begin
    FSelected := -1;
    Exit;
  end;
  if FSelected < 0 then
  begin
    FSelected := 0;
    Exit;
  end;
  N := FSelected + ADelta;
  if N < 0 then
    N := 0;
  if N > FItems.Count - 1 then
    N := FItems.Count - 1;
  FSelected := N;
end;

function TListView.Measure(const AAvail: TSize): TSize;
var
  I: Integer;
begin
  Result := Default(TSize);
  Result.H := FItems.Count;
  for I := 0 to FItems.Count - 1 do
    if Length(FItems[I]) > Result.W then
      Result.W := Length(FItems[I]);
  if Result.W > AAvail.W then
    Result.W := AAvail.W;
end;

procedure TListView.Render(const S: ISurface);
var
  I, J, X: Integer;
  Line: string;
  A: TAttr;
  C: TCell;
begin
  if (FBounds.W <= 0) or (FBounds.H <= 0) then
    Exit;
  S.FillRect(FBounds, FTheme.Panel);
  for I := 0 to FItems.Count - 1 do
  begin
    if I >= FBounds.H then
      Break;
    Line := FItems[I];
    A := FTheme.Text;
    if I = FSelected then
    begin
      A := FTheme.Accent;
      if Focused then
        Include(A.Style, sfReverse);
    end;
    for J := 1 to Length(Line) do
    begin
      X := FBounds.X + J - 1;
      if X >= FBounds.X + FBounds.W then
        Break;
      C := Default(TCell);
      C.Ch := UnicodeString(Line[J]);
      C.Attr := A;
      S.Put(X, FBounds.Y + I, C);
    end;
  end;
end;

function TListView.HandleEvent(const E: TInputEvent): Boolean;
begin
  if E.Kind = ikKey then
  begin
    case E.Key.Kind of
      kkUp:
        begin
          Move(-1);
          Exit(True);
        end;
      kkDown:
        begin
          Move(1);
          Exit(True);
        end;
      kkHome:
        begin
          SetSelected(0);
          Exit(True);
        end;
      kkEnd:
        begin
          SetSelected(FItems.Count - 1);
          Exit(True);
        end;
      kkEnter:
        begin
          if Focused and (FSelected >= 0) then
          begin
            if Assigned(FOnActivate) then
              FOnActivate(Self);
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
      (E.Mouse.X >= FBounds.X) and (E.Mouse.X < FBounds.X + FBounds.W) and
      (E.Mouse.Y >= FBounds.Y) and (E.Mouse.Y < FBounds.Y + FBounds.H) then
    begin
      SetSelected(E.Mouse.Y - FBounds.Y);
      Exit(True);
    end;
  end;
  Result := False;
end;

end.
