unit hildegard.helper.tui.input.fd;
{ Non-blocking reads from an input file descriptor, split out of the terminal
  adapter so the EOF (hang-up) path is unit-testable without a tty.

  A terminal that closes leaves the pty master gone: the fd then reports readable
  forever and read returns 0. A caller that treats that as "no event" never
  blocks, so its event loop spins at 100% CPU. Reporting EOF distinctly is what
  lets the loop stop instead. }

{$mode delphi}{$H+}

interface

type
  { The result of one non-blocking read. irNone: nothing is ready. irData: AData
    holds the bytes read. irEof: the fd is at end of file (the terminal hung up).
    irError: the read failed (e.g. EINTR); treat it as nothing. }
  TInputReadResult = (irNone, irData, irEof, irError);
  TInputBytes = array of Byte;

{ Read whatever is ready from AFd, without blocking. Never waits. }
function ReadInputFd(AFd: Integer; out AData: TInputBytes): TInputReadResult;

implementation

uses
  baseunix;

function ReadInputFd(AFd: Integer; out AData: TInputBytes): TInputReadResult;
var
  Fds: TFDSet;
  TV: TTimeVal;
  Buf: array[0..255] of Byte;
  N, R: Integer;
begin
  AData := nil;
  if AFd < 0 then
    Exit(irError);
  fpFD_ZERO(Fds);
  fpFD_SET(AFd, Fds);
  TV.tv_sec := 0;
  TV.tv_usec := 0;
  R := fpSelect(AFd + 1, @Fds, nil, nil, @TV);
  if R < 0 then
  begin
    { EINTR is transient (nothing to report); anything else - notably EBADF on a
      closed fd - means the fd is unusable, so report end of file and let the
      caller stop rather than spin. }
    if fpGetErrno = ESysEINTR then
      Exit(irNone);
    Exit(irEof);
  end;
  if R = 0 then
    Exit(irNone);
  N := fpRead(AFd, @Buf[0], SizeOf(Buf));
  if N = 0 then
    Exit(irEof);
  if N < 0 then
    Exit(irError);
  SetLength(AData, N);
  Move(Buf[0], AData[0], N);
  Result := irData;
end;

end.
