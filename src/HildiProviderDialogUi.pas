unit HildiProviderDialogUi;
{ The /provider dialog: a modal list of stored providers.

  Split from HildiProviderDialog deliberately. That unit is the PURE assembly -
  what the operator must see - and is fully tested. This unit is the widget, and
  a widget cannot be unit-tested without a surface, so keeping the two apart is
  what stops the untestable part from swallowing the testable one.

  The shape follows TMcpModal exactly: TModal owns the frame, a row widget owns
  the list and its per-row hit-testing, and dismissal is a CALLBACK because TModal
  has no close protocol - the HOST owns the close flag and does the PopPlane on a
  later frame. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils,
  TUIBase, TUIInput, TUISurface, TUIWidget, TUITheme, TUIGrapheme,
  TUIWidgetsModal,
  HildiProviderDialog;

type
  { A key was pressed that the host must act on. '' means close. }
  TProviderActionEvent = procedure(const AAction: string) of object;

  { The list rows. A separate widget because TModal owns the frame and this owns
    the list, which keeps hit-testing for a row inside the widget that draws it. }
  TProviderRows = class(TWidget)
  private
    FTheme: TTheme;
    FItems: TProviderListItemArray;
    FSel: Integer;
    FScrollTop: Integer;
    function RowAt(AY: Integer): Integer;
    procedure Move(ASteps: Integer);
    procedure ClampScroll;
  public
    constructor Create(const ATheme: TTheme);
    procedure SetItems(const AItems: TProviderListItemArray);
    procedure MoveSelection(ASteps: Integer);
    function SelectedName: string;
    function SelectedUsable: Boolean;
    function HandleEvent(const E: TInputEvent): Boolean; override;
    procedure Render(const S: ISurface); override;
    function Measure(const AAvail: TSize): TSize; override;
  end;

  TProviderModal = class(TModal)
  private
    FRows: TProviderRows;
    FOnAction: TProviderActionEvent;
    procedure RequestClose;
    procedure RefreshFooter;
  public
    constructor Create(const ATheme: TTheme);
    destructor Destroy; override;
    { Replace the list. The host supplies it; this widget renders what it is
      given and never reads the store itself. }
    procedure SetItems(const AItems: TProviderListItemArray);
    function SelectedName: string;
    { 'add' | 'edit' | 'cancel'. The host performs them. There is deliberately NO
      'activate': this dialog manages providers, it does not switch them -
      switching is /model, which chooses a provider+model pair. Removal is an
      action of the EDIT form, not of the list. }
    property OnAction: TProviderActionEvent read FOnAction write FOnAction;
    function HandleEvent(const E: TInputEvent): Boolean; override;
  protected
    procedure FooterClicked(const AKey: string); override;
  end;

implementation

{ Clip to AMaxCells DISPLAY cells, never mid-cluster. A byte or code-unit cut
  would split a wide grapheme and shear the row. Same shape as HildiMcpModal's
  private helper - that one is not exported, and clipping by display cells really
  belongs in the TUI core beside TUIGrapheme; a local copy unblocks this without
  editing a unit another lane owns. }
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



const
  RowHeight = 2;             // summary line + its detail line

{ --- TProviderRows ------------------------------------------------------- }

constructor TProviderRows.Create(const ATheme: TTheme);
begin
  inherited Create;
  FTheme := ATheme;
  FSel := 0;
  FScrollTop := 0;
end;

procedure TProviderRows.SetItems(const AItems: TProviderListItemArray);
begin
  FItems := AItems;
  { Keep the selection in range: the list can shrink under it after a delete. }
  if FSel > High(FItems) then
    FSel := High(FItems);
  if FSel < 0 then
    FSel := 0;
  ClampScroll;
end;

procedure TProviderRows.ClampScroll;
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

procedure TProviderRows.Move(ASteps: Integer);
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
  { Keep the selection on screen rather than letting it scroll off. }
  if FSel < FScrollTop then
    FScrollTop := FSel;
  if FSel >= FScrollTop + Visible then
    FScrollTop := FSel - Visible + 1;
  ClampScroll;
end;

procedure TProviderRows.MoveSelection(ASteps: Integer);
begin
  Move(ASteps);
end;

function TProviderRows.SelectedName: string;
begin
  if (FSel >= 0) and (FSel < Length(FItems)) then
    Result := FItems[FSel].Name
  else
    Result := '';
end;

function TProviderRows.SelectedUsable: Boolean;
begin
  Result := (FSel >= 0) and (FSel < Length(FItems)) and FItems[FSel].Usable;
end;

function TProviderRows.RowAt(AY: Integer): Integer;
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

function TProviderRows.HandleEvent(const E: TInputEvent): Boolean;
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
      kkEnter: Exit(False);       // the modal owns activation
    else
      Exit(False);
    end;
    Exit;
  end;
  { A click selects the row under the pointer. Press only: a motion event must
    not move the selection as the pointer passes over the list. }
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

function TProviderRows.Measure(const AAvail: TSize): TSize;
begin
  Result.W := AAvail.W;
  Result.H := Length(FItems) * RowHeight;
  if Result.H > AAvail.H then
    Result.H := AAvail.H;
end;

procedure TProviderRows.Render(const S: ISurface);
var
  I, Y, Visible: Integer;
  Item: TProviderListItem;
  SelAttr, NameAttr, SumAttr, BadAttr, At: TAttr;
  Marker, Name, Summary: UnicodeString;
begin
  if FBounds.W < 8 then
    Exit;
  SelAttr := OnBg(FTheme.Text, FTheme.RaisedBg);
  NameAttr := OnBg(FTheme.Text, FTheme.Bg);
  SumAttr := OnBg(FTheme.Muted, FTheme.Bg);
  { An unusable provider is the one thing here that needs action, so it is the
    only row painted as a problem. }
  BadAttr := OnBg(FTheme.Accent, FTheme.Bg);

  if Length(FItems) = 0 then
  begin
    PutText(S, FBounds.X, FBounds.Y, 'no providers configured', SumAttr);
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
    { The ACTIVE provider carries a marker; the SELECTED row carries the cursor.
      They are different facts and must be distinguishable at a glance. }
    if Item.Active then
      Marker := '* '
    else
      Marker := '  ';
    Name := Marker + UnicodeString(Item.Name);
    Summary := UnicodeString(Item.Summary);
    PutText(S, FBounds.X, Y, ClipCells(Name, FBounds.W), NameAttr);
    if I + FScrollTop = FSel then
      PutText(S, FBounds.X, Y, ClipCells(Name, FBounds.W), SelAttr);
    { A plain branch, not IfThen: TAttr has no IfThen overload and the call
      resolved to an unrelated one. }
    At := SumAttr;
    if not Item.Usable then
      At := BadAttr;
    PutText(S, FBounds.X + 2, Y + 1, ClipCells(Summary, FBounds.W - 2), At);
  end;
end;

{ --- TProviderModal ------------------------------------------------------ }

constructor TProviderModal.Create(const ATheme: TTheme);
begin
  FRows := TProviderRows.Create(ATheme);
  { Not scrollable: the row widget lays out whole rows and a scroll container
    would also intercept the arrow keys the rows use. Same as TMcpModal. }
  inherited Create(ATheme, FRows, False);
  SetTitle('providers');
  RefreshFooter;
end;

destructor TProviderModal.Destroy;
begin
  FRows.Free;
  inherited Destroy;
end;

procedure TProviderModal.RefreshFooter;
begin
  { A single string: TModal splits it into CTA pairs with the SAME rule its
    click path uses. Building the pairs by hand is the bug where a caller and the
    splitter disagree and clicking 'esc close' activates instead.

    NO 'enter activate'. This dialog MANAGES providers; it does not switch them.
    Switching is /model, which chooses a provider+model pair, and keeping the two
    separate is what stops a list view from silently changing what a session
    talks to.

    'ctrl+a add' is CHORDED rather than a bare 'a': a lone letter beside a
    destructive action is too easy to hit while reading the list. Removal lives
    in the EDIT form, not here, so the list has no destructive CTA at all. }
  SetFooter('ctrl+a add   enter edit   esc cancel');
end;

procedure TProviderModal.SetItems(const AItems: TProviderListItemArray);
begin
  FRows.SetItems(AItems);
end;

function TProviderModal.SelectedName: string;
begin
  Result := FRows.SelectedName;
end;

procedure TProviderModal.RequestClose;
begin
  if Assigned(FOnAction) then
    FOnAction('cancel');
end;

function TProviderModal.HandleEvent(const E: TInputEvent): Boolean;
begin
  { The rows first, so the arrows move the selection. }
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
          { Edit the selected row. With nothing selected there is nothing to
            edit, and opening an empty form would be a worse answer than doing
            nothing. }
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
      { Every other key falls through to TModal, which owns Escape handling and
        the footer chords. Stating it keeps -Sew honest: an unhandled case here
        would be a key that silently does nothing. }
      ;
    end;
  end;
  Result := inherited HandleEvent(E);
end;

procedure TProviderModal.FooterClicked(const AKey: string);
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
