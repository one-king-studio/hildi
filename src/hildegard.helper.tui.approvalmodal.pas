unit hildegard.helper.tui.approvalmodal;
{ A modal widget for one TApprovalAsk. It mirrors the CLI's choices: pick an
  option (number or arrows + Enter) to allow, Escape to deny. Scope keys g/w/s
  choose where a persisting option is saved (default workspace, as the CLI). }

{$mode delphi}{$H+}

interface

uses
  hildegard.helper.tui.base, hildegard.helper.tui.input,
  hildegard.helper.tui.surface, hildegard.helper.tui.widget,
  hildegard.helper.approval;

type
  TApprovalChoiceEvent = procedure(const AChoice: TApprovalChoice) of object;

  TApprovalModal = class(TWidget)
  private
    FAsk: TApprovalAsk;
    FSelected: Integer;
    FScope: TApprovalScope;
    FAnswered: Boolean;
    FChoice: TApprovalChoice;
    FOnChoose: TApprovalChoiceEvent;
    FAttr: TAttr;
    procedure Choose(AIndex: Integer);
    procedure Deny;
    procedure CycleScope;
    function LineAt(AIndex: Integer): string;
    function LineCount: Integer;
  public
    constructor Create(const AAsk: TApprovalAsk); overload;
    constructor Create(const AAsk: TApprovalAsk; const AAttr: TAttr); overload;
    function Measure(const AAvail: TSize): TSize; override;
    procedure Render(const S: ISurface); override;
    function HandleEvent(const E: TInputEvent): Boolean; override;

    property Ask: TApprovalAsk read FAsk;
    property Answered: Boolean read FAnswered;
    property Choice: TApprovalChoice read FChoice;
    property Attr: TAttr read FAttr write FAttr;
    property OnChoose: TApprovalChoiceEvent read FOnChoose write FOnChoose;
  end;

implementation

uses
  SysUtils,
  hildegard.helper.tui.text;

function ScopeName(AScope: TApprovalScope): string;
begin
  case AScope of
    asGlobal:
      Result := 'global';
    asSession:
      Result := 'session';
  else
    Result := 'workspace';
  end;
end;

constructor TApprovalModal.Create(const AAsk: TApprovalAsk);
begin
  Create(AAsk, DefaultAttr);
end;

constructor TApprovalModal.Create(const AAsk: TApprovalAsk;
  const AAttr: TAttr);
begin
  inherited Create;
  FAsk := AAsk;
  FSelected := 0;
  FScope := asWorkspace;
  FAnswered := False;
  FAttr := AAttr;
end;

function TApprovalModal.LineCount: Integer;
begin
  Result := 3 + Length(FAsk.Options) + 2;
end;

function TApprovalModal.LineAt(AIndex: Integer): string;
var
  I: Integer;
begin
  if AIndex = 0 then
  begin
    Result := 'Approval needed';
    Exit;
  end;
  if AIndex = 1 then
  begin
    Result := '  ' + FAsk.Summary;
    Exit;
  end;
  if AIndex = 2 then
  begin
    Result := '';
    Exit;
  end;
  I := AIndex - 3;
  if I < Length(FAsk.Options) then
  begin
    Result := Format('  %d) %s', [I + 1, FAsk.Options[I].Caption]);
    Exit;
  end;
  if AIndex = 3 + Length(FAsk.Options) then
  begin
    Result := '';
    Exit;
  end;
  Result := Format('  scope: %s  [Tab / g w s]   Up/Down or 1-9   Enter accept   Esc deny',
    [ScopeName(FScope)]);
end;

function TApprovalModal.Measure(const AAvail: TSize): TSize;
var
  I, W: Integer;
  Block: TTextBlock;
begin
  Result := Default(TSize);
  W := 0;
  Block := TTextBlock.Create([], wmNone);
  try
    for I := 0 to LineCount - 1 do
    begin
      Block.SetText(LineAt(I), DefaultAttr);
      if Block.Measure(Default(TSize)).W > W then
        W := Block.Measure(Default(TSize)).W;
    end;
  finally
    Block.Free;
  end;
  Result.W := W + 4;
  if Result.W > AAvail.W then
    Result.W := AAvail.W;
  Result.H := LineCount + 2;
  if Result.H > AAvail.H then
    Result.H := AAvail.H;
end;

procedure TApprovalModal.Render(const S: ISurface);
var
  Bg, Reverse: TAttr;
  I, X: Integer;
  Line: string;
  Cell: TCell;
begin
  if (FBounds.W <= 0) or (FBounds.H <= 0) then
    Exit;
  Bg := FAttr;
  S.FillRect(FBounds, Bg);

  for I := 0 to LineCount - 1 do
  begin
    if I + 1 >= FBounds.H then
      Break;
    Line := LineAt(I);
    Reverse := Bg;
    if (I >= 3) and (I - 3 = FSelected) and (I - 3 < Length(FAsk.Options)) then
      Include(Reverse.Style, sfReverse);
    for X := 1 to Length(Line) do
    begin
      if X - 1 >= FBounds.W then
        Break;
      Cell := Default(TCell);
      Cell.Ch := UnicodeString(Line[X]);
      if (I >= 3) and (I - 3 = FSelected) then
        Cell.Attr := Reverse
      else
        Cell.Attr := Bg;
      S.Put(FBounds.X + X - 1, FBounds.Y + I + 1, Cell);
    end;
  end;
end;

procedure TApprovalModal.Choose(AIndex: Integer);
begin
  if FAnswered then
    Exit;
  FChoice := Default(TApprovalChoice);
  if (AIndex >= 0) and (AIndex < Length(FAsk.Options)) then
  begin
    FChoice.Allowed := True;
    FChoice.OptionKey := FAsk.Options[AIndex].Key;
    FChoice.Scope := FScope;
  end;
  FAnswered := True;
  if Assigned(FOnChoose) then
    FOnChoose(FChoice);
end;

procedure TApprovalModal.Deny;
begin
  Choose(-1);
end;

procedure TApprovalModal.CycleScope;
begin
  case FScope of
    asWorkspace:
      FScope := asSession;
    asSession:
      FScope := asGlobal;
  else
    FScope := asWorkspace;
  end;
end;

function TApprovalModal.HandleEvent(const E: TInputEvent): Boolean;
var
  N: Integer;
begin
  if FAnswered then
    Exit(False);
  if E.Kind <> ikKey then
    Exit(False);
  case E.Key.Kind of
    kkUp, kkLeft:
      begin
        if FSelected > 0 then
          Dec(FSelected);
        Exit(True);
      end;
    kkDown, kkRight:
      begin
        if FSelected < Length(FAsk.Options) - 1 then
          Inc(FSelected);
        Exit(True);
      end;
    kkEnter:
      begin
        if Length(FAsk.Options) = 0 then
          Deny
        else
          Choose(FSelected);
        Exit(True);
      end;
    kkEscape:
      begin
        Deny;
        Exit(True);
      end;
    kkTab:
      begin
        CycleScope;
        Exit(True);
      end;
    kkChar:
      begin
        if E.Key.Ch = 'g' then
        begin
          FScope := asGlobal;
          Exit(True);
        end;
        if E.Key.Ch = 'w' then
        begin
          FScope := asWorkspace;
          Exit(True);
        end;
        if E.Key.Ch = 's' then
        begin
          FScope := asSession;
          Exit(True);
        end;
        N := StrToIntDef(string(E.Key.Ch), 0);
        if (N >= 1) and (N <= Length(FAsk.Options)) then
        begin
          Choose(N - 1);
          Exit(True);
        end;
        Exit(False);
      end;
  else
    ;
  end;
  Result := False;
end;

end.
