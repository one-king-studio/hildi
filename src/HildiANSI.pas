unit HildiANSI;
{ Zero-dependency ANSI SGR styling. Emits 24-bit colour, bold, and dim, and
  disables itself when stdout is not a terminal, TERM is dumb, or NO_COLOR is
  set. Never buffers, moves the cursor, or reads input. }

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  TAnsiColor = record
    R, G, B: Byte;
  end;

const
  AnsiBlack: TAnsiColor = (R: 0; G: 0; B: 0);
  AnsiRed: TAnsiColor = (R: 220; G: 50; B: 47);
  AnsiGreen: TAnsiColor = (R: 133; G: 153; B: 0);
  AnsiYellow: TAnsiColor = (R: 181; G: 137; B: 0);
  AnsiBlue: TAnsiColor = (R: 38; G: 139; B: 210);
  AnsiMagenta: TAnsiColor = (R: 211; G: 54; B: 130);
  AnsiCyan: TAnsiColor = (R: 42; G: 161; B: 152);
  AnsiWhite: TAnsiColor = (R: 255; G: 255; B: 255);
  AnsiGray: TAnsiColor = (R: 128; G: 128; B: 128);

function Color(AR, AG, AB: Byte): TAnsiColor;
function AnsiEnabled: Boolean;
procedure AnsiSetEnabled(AValue: Boolean);
function AnsiFg(const AColor: TAnsiColor): string;
function AnsiReset: string;
function AnsiBold(const AText: string): string;
function AnsiDim(const AText: string): string;
function AnsiStyled(const AText: string; const AColor: TAnsiColor): string;

implementation

uses
  ctypes;

const
  Esc = #27;

var
  FEnabled: Boolean;

{$ifdef unix}
function c_isatty(Fd: cint): cint; cdecl; external 'c' name 'isatty';
{$endif}

function Detect: Boolean;
begin
  if GetEnvironmentVariable('NO_COLOR') <> '' then
    Exit(False);
  if GetEnvironmentVariable('TERM') = 'dumb' then
    Exit(False);
  {$ifdef unix}
  Result := c_isatty(1) <> 0;
  {$else}
  Result := False;
  {$endif}
end;

function Color(AR, AG, AB: Byte): TAnsiColor;
begin
  Result.R := AR;
  Result.G := AG;
  Result.B := AB;
end;

function AnsiEnabled: Boolean;
begin
  Result := FEnabled;
end;

procedure AnsiSetEnabled(AValue: Boolean);
begin
  FEnabled := AValue;
end;

function AnsiFg(const AColor: TAnsiColor): string;
begin
  if not FEnabled then
    Exit('');
  Result := Esc + '[38;2;' + IntToStr(AColor.R) + ';' + IntToStr(AColor.G) +
    ';' + IntToStr(AColor.B) + 'm';
end;

function AnsiReset: string;
begin
  if not FEnabled then
    Exit('');
  Result := Esc + '[0m';
end;

function AnsiBold(const AText: string): string;
begin
  if not FEnabled then
    Exit(AText);
  Result := Esc + '[1m' + AText + Esc + '[0m';
end;

function AnsiDim(const AText: string): string;
begin
  if not FEnabled then
    Exit(AText);
  Result := Esc + '[2m' + AText + Esc + '[0m';
end;

function AnsiStyled(const AText: string; const AColor: TAnsiColor): string;
begin
  if not FEnabled then
    Exit(AText);
  Result := AnsiFg(AColor) + AText + AnsiReset;
end;

initialization
  FEnabled := Detect;

end.
