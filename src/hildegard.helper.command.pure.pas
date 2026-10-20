unit hildegard.helper.command.pure;
{ Commands that produce text from their own arguments and nothing else: no
  filesystem, no stdin, no information about the machine. They need no
  approval. Everything else — reads (which extract information into the
  context), writes, and directory operations — is gated. }

{$mode delphi}{$H+}

interface

function IsPureCommand(const AName: string): Boolean;

implementation

function IsPureCommand(const AName: string): Boolean;
begin
  Result := (AName = 'echo') or (AName = 'printf') or (AName = 'true') or
    (AName = 'false') or (AName = 'basename') or (AName = 'dirname');
end;

end.
