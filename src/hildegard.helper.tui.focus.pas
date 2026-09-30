unit hildegard.helper.tui.focus;
{ A focus model for the widget kit.

  TFocusable is a widget that can hold focus. TFocusGroup is a container that
  moves focus with Tab/Shift-Tab, focuses on left-click, and routes events to
  the focused control first. }

{$mode delphi}{$H+}

interface

uses
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget;

type
  TFocusable = class(TWidget)
  private
    FFocused: Boolean;
    procedure SetFocused(AValue: Boolean);
  public
    property Focused: Boolean read FFocused write SetFocused;
    { Called whenever Focused changes; subclasses may repaint or scroll. }
    procedure FocusChanged; virtual;
  end;

  TFocusableArray = array of TFocusable;

  { A container that manages focus among its focusable children. }
  TFocusGroup = class(TContainer)
  private
    function IndexOfFocused: Integer;
  public
    { Focusable children in Add order. }
    function Focusables: TFocusableArray;
    { The focused child, or nil. }
    function Focused: TFocusable;
    procedure FocusNext;                 // Tab
    procedure FocusPrev;                 // Shift-Tab
    { Focus the focusable containing (X, Y); True when one was found. }
    function FocusAt(X, Y: Integer): Boolean;
    function HandleEvent(const E: TInputEvent): Boolean; override;
  end;

implementation

procedure TFocusable.SetFocused(AValue: Boolean);
begin
  if FFocused = AValue then
    Exit;
  FFocused := AValue;
  FocusChanged;
end;

procedure TFocusable.FocusChanged;
begin
end;

function TFocusGroup.Focusables: TFocusableArray;
var
  I, N: Integer;
  W: TWidget;
begin
  Result := nil;
  N := 0;
  for I := 0 to ChildCount - 1 do
  begin
    W := ChildAt(I);
    if W is TFocusable then
    begin
      SetLength(Result, N + 1);
      Result[N] := TFocusable(W);
      Inc(N);
    end;
  end;
end;

function TFocusGroup.IndexOfFocused: Integer;
var
  F: TFocusableArray;
  I: Integer;
begin
  Result := -1;
  F := Focusables;
  for I := 0 to High(F) do
    if F[I].Focused then
      Exit(I);
end;

function TFocusGroup.Focused: TFocusable;
var
  Idx: Integer;
  F: TFocusableArray;
begin
  Idx := IndexOfFocused;
  if Idx < 0 then
    Exit(nil);
  F := Focusables;
  Result := F[Idx];
end;

procedure TFocusGroup.FocusNext;
var
  F: TFocusableArray;
  Idx, I: Integer;
begin
  F := Focusables;
  if Length(F) = 0 then
    Exit;
  Idx := IndexOfFocused;
  if Idx < 0 then
    Idx := 0
  else
    Idx := (Idx + 1) mod Length(F);
  for I := 0 to High(F) do
    F[I].Focused := (I = Idx);
end;

procedure TFocusGroup.FocusPrev;
var
  F: TFocusableArray;
  Idx, I: Integer;
begin
  F := Focusables;
  if Length(F) = 0 then
    Exit;
  Idx := IndexOfFocused;
  if Idx < 0 then
    Idx := Length(F) - 1
  else
    Idx := (Idx - 1 + Length(F)) mod Length(F);
  for I := 0 to High(F) do
    F[I].Focused := (I = Idx);
end;

function TFocusGroup.FocusAt(X, Y: Integer): Boolean;
var
  F: TFocusableArray;
  I, Hit: Integer;
  B: TRect;
begin
  F := Focusables;
  Hit := -1;
  for I := 0 to High(F) do
  begin
    B := F[I].Bounds;
    if (X >= B.X) and (Y >= B.Y) and (X < B.X + B.W) and (Y < B.Y + B.H) then
    begin
      Hit := I;
      Break;
    end;
  end;
  if Hit < 0 then
    Exit(False);
  for I := 0 to High(F) do
    F[I].Focused := (I = Hit);
  Result := True;
end;

function TFocusGroup.HandleEvent(const E: TInputEvent): Boolean;
var
  F: TFocusableArray;
  Cur: TFocusable;
  I: Integer;
  W: TWidget;
begin
  if E.Kind = ikKey then
  begin
    if E.Key.Kind = kkTab then
    begin
      if moShift in E.Key.Mods then
        FocusPrev
      else
        FocusNext;
      Exit(True);
    end;
    if Focused = nil then
    begin
      F := Focusables;
      if Length(F) > 0 then
        F[0].Focused := True;
    end;
  end
  else if E.Kind = ikMouse then
  begin
    if E.Mouse.Button = mbLeft then
      FocusAt(E.Mouse.X, E.Mouse.Y);
  end;

  Cur := Focused;
  if (Cur <> nil) and Cur.HandleEvent(E) then
    Exit(True);
  for I := 0 to ChildCount - 1 do
  begin
    W := ChildAt(I);
    if (W <> nil) and (W <> Cur) and W.Visible and W.HandleEvent(E) then
      Exit(True);
  end;
  Result := False;
end;

end.
