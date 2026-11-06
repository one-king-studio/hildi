unit HildiAgentDialogUi;
{ The /agent dialog: a modal list of configured behaviours.

  Mirrors HildiProviderDialogUi in shape - TModal owns the frame, a row widget
  owns the list and its hit-testing, dismissal is a CALLBACK because TModal has
  no close protocol and the host owns the deferred PopPlane.

  The difference is what a row MEANS: a provider is a connection, an agent is a
  behaviour, so the list shows which one is active, what it points at, and whether
  that resolves. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils,
  TUIBase, TUIInput, TUISurface, TUIWidget, TUITheme, TUIGrapheme,
  TUIWidgetsModal,
  HildiAgentDialog;

type
  { 'add' | 'edit' | 'cancel' — the host performs each. }
  TAgentActionEvent = procedure(const AAction: string) of object;

  TAgentRows = class(TWidget)
  private
    FTheme: TTheme;
    FItems: TAgentListItemArray;
    FSel: Integer;
    FScrollTop: Integer;
    function RowAt(AY: Integer): Integer;
    procedure Move(ASteps: Integer);
    procedure ClampScroll;
  public
    constructor Create(const ATheme: TTheme);
    procedure SetItems(const AItems: TAgentListItemArray);
    function SelectedName: string;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    procedure Render(const S: ISurface); override;
    function Measure(const AAvail: TSize): TSize; override;
  end;

  TAgentModal = class(TModal)
  private
    FRows: TAgentRows;
    FOnAction: TAgentActionEvent;
    procedure RequestClose;
  public
    constructor Create(const ATheme: TTheme);
    destructor Destroy; override;
    procedure SetItems(const AItems: TAgentListItemArray);
    function SelectedName: string;
    property OnAction: TAgentActionEvent read FOnAction write FOnAction;
    function HandleEvent(const E: TInputEvent): Boolean; override;
  protected
    procedure FooterClicked(const AKey: string); override;
  end;

implementation

const
  RowHeight = 2;

function ClipCells(const AText: UnicodeString; AMaxCells: Integer): UnicodeString;
var
  Parts: TClusterArray;
  I, Used, W: Integer;
begin
  Result := '';
  if AMaxCells <= 0 then
    Exit;
  Parts := Clusters(AText);
  Used := 0;
  for I := 0 to High(Parts) do
  begin
    W := ClusterWidth(Parts[I]);
    if Used + W > AMaxCells then
      Break;
    Result := Result + Parts[I];
    Inc(Used, W);
  end;
end;

{ --- TAgentRows ---------------------------------------------------------- }

constructor TAgentRows.Create(const ATheme: TTheme);
begin
  inherited Create;
  FTheme := ATheme;
  FSel := 0;
  FScrollTop := 0;
end;

procedure TAgentRows.SetItems(const AItems: TAgentListItemArray);
begin
  FItems := AItems;
  if FSel > High(FItems) then
    FSel := High(FItems);
  if FSel < 0 then
    FSel := 0;
  ClampScroll;
end;

procedure TAgentRows.ClampScroll;
var
  Visible: Integer;
begin
  Visible := (FBounds.H + RowHeight - 1) div RowHeight;
  if Visible < 1 then
    Visible := 1;
  if FScrollTop > High(FItems) - Visible + 1 then
    FScrollTop := High(FItems) - Visible + 1;
  if FScrollTop < 0 then
    FScrollTop := 0;
end;

procedure TAgentRows.Move(ASteps: Integer);
var
  Visible: Integer;
begin
  if Length(FItems) = 0 then
    Exit;
  FSel := FSel + ASteps;
  if FSel < 0 then
    FSel := 0;
  if FSel > High(FItems) then
    FSel := High(FItems);
  Visible := (FBounds.H + RowHeight - 1) div RowHeight;
  if Visible < 1 then
    Visible := 1;
  if FSel < FScrollTop then
    FScrollTop := FSel;
  if FSel >= FScrollTop + Visible then
    FScrollTop := FSel - Visible + 1;
  ClampScroll;
end;

function TAgentRows.SelectedName: string;
begin
  if (FSel >= 0) and (FSel < Length(FItems)) then
    Result := FItems[FSel].Name
  else
    Result := '';
end;

function TAgentRows.RowAt(AY: Integer): Integer;
var
  Rel: Integer;
begin
  Result := -1;
  if not Visible then
    Exit;
  Rel := AY - FBounds.Y;
  if (Rel < 0) or (Rel >= FBounds.H) then
    Exit;
  Rel := FScrollTop + (Rel div RowHeight);
  if (Rel >= 0) and (Rel <= High(FItems)) then
    Result := Rel;
end;

function TAgentRows.HandleEvent(const E: TInputEvent): Boolean;
var
  Idx: Integer;
begin
  Result := True;
  if E.Kind = ikKey then
  begin
    case E.Key.Kind of
      kkUp: Move(-1);
      kkDown: Move(1);
      kkHome: Move(-Length(FItems));
      kkEnd: Move(Length(FItems));
      kkEnter: Exit(False);        // the modal owns activation of a row action
    else
      Exit(False);
    end;
    Exit;
  end;
  { Press only: a motion event must not move the selection as the pointer passes. }
  if (E.Kind = ikMouse) and (E.Mouse.Action = maPress) then
  begin
    Idx := RowAt(E.Mouse.Y);
    if Idx >= 0 then
    begin
      FSel := Idx;
      Exit;
    end;
  end;
  Result := False;
end;

function TAgentRows.Measure(const AAvail: TSize): TSize;
begin
  Result.W := AAvail.W;
  Result.H := Length(FItems) * RowHeight;
  if Result.H > AAvail.H then
    Result.H := AAvail.H;
end;

procedure TAgentRows.Render(const S: ISurface);
var
  I, Y, Visible: Integer;
  Item: TAgentListItem;
  SelAttr, NameAttr, SumAttr, BadAttr, At: TAttr;
  Marker, Name, Summary: UnicodeString;
begin
  if FBounds.W < 8 then
    Exit;
  SelAttr := OnBg(FTheme.Text, FTheme.RaisedBg);
  NameAttr := OnBg(FTheme.Text, FTheme.Bg);
  SumAttr := OnBg(FTheme.Muted, FTheme.Bg);
  { An agent whose provider does not resolve is the one thing here needing
    action, so it is the only row painted as a problem. }
  BadAttr := OnBg(FTheme.Accent, FTheme.Bg);

  if Length(FItems) = 0 then
  begin
    PutText(S, FBounds.X, FBounds.Y, 'no agents configured', SumAttr);
    Exit;
  end;

  Visible := (FBounds.H + RowHeight - 1) div RowHeight;
  for I := 0 to Visible - 1 do
  begin
    if FScrollTop + I > High(FItems) then
      Break;
    Item := FItems[FScrollTop + I];
    Y := FBounds.Y + I * RowHeight;
    if Y >= FBounds.Y + FBounds.H then
      Break;
    { ACTIVE carries the marker; SELECTED carries the cursor. Different facts. }
    if Item.Active then
      Marker := '* '
    else
      Marker := '  ';
    Name := Marker + UnicodeString(Item.Name);
    Summary := UnicodeString(Item.Summary);
    PutText(S, FBounds.X, Y, ClipCells(Name, FBounds.W), NameAttr);
    if I + FScrollTop = FSel then
      PutText(S, FBounds.X, Y, ClipCells(Name, FBounds.W), SelAttr);
    At := SumAttr;
    if not Item.ProviderExists then
      At := BadAttr;
    PutText(S, FBounds.X + 2, Y + 1, ClipCells(Summary, FBounds.W - 2), At);
  end;
end;

{ --- TAgentModal --------------------------------------------------------- }

constructor TAgentModal.Create(const ATheme: TTheme);
begin
  FRows := TAgentRows.Create(ATheme);
  inherited Create(ATheme, FRows, False);
  SetTitle('agents');
  { 'enter edit', not 'enter activate': like /provider, this manages behaviours
    rather than switching them. Choosing which agent runs is /model's job, since
    an agent carries a model. }
  SetFooter('ctrl+a add   enter edit   esc cancel');
end;

destructor TAgentModal.Destroy;
begin
  FRows.Free;
  inherited Destroy;
end;

procedure TAgentModal.SetItems(const AItems: TAgentListItemArray);
begin
  FRows.SetItems(AItems);
end;

function TAgentModal.SelectedName: string;
begin
  Result := FRows.SelectedName;
end;

procedure TAgentModal.RequestClose;
begin
  if Assigned(FOnAction) then
    FOnAction('cancel');
end;

function TAgentModal.HandleEvent(const E: TInputEvent): Boolean;
begin
  if FRows.HandleEvent(E) then
    Exit(True);
  if E.Kind = ikKey then
  begin
    case E.Key.Kind of
      kkEscape:
        begin
          RequestClose;
          Exit(True);
        end;
      kkEnter:
        begin
          if (SelectedName <> '') and Assigned(FOnAction) then
            FOnAction('edit');
          Exit(True);
        end;
      kkChar:
        begin
          if (moCtrl in E.Key.Mods) and ((E.Key.Ch = 'a') or (E.Key.Ch = 'A')) then
          begin
            if Assigned(FOnAction) then
              FOnAction('add');
            Exit(True);
          end;
        end;
    else
      ;
    end;
  end;
  Result := inherited HandleEvent(E);
end;

procedure TAgentModal.FooterClicked(const AKey: string);
begin
  if AKey = 'ctrl+a' then
  begin
    if Assigned(FOnAction) then
      FOnAction('add');
  end
  else if AKey = 'enter' then
  begin
    if (SelectedName <> '') and Assigned(FOnAction) then
      FOnAction('edit');
  end
  else if AKey = 'esc' then
    RequestClose
  else
    inherited FooterClicked(AKey);
end;

end.
