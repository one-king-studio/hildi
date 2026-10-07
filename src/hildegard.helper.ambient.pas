unit hildegard.helper.ambient;
{ The ambient notification wrapper: a subagent's result delivered to the parent
  as an ambient message.

  Ambient records are persisted as their own kind (mrAmbient) and rendered
  specially by the UI. When the conversation is composed for the provider, an
  ambient record is *hijacked* into a user message: the result is wrapped in an
  <ambient> tag carrying the child session id and a timestamp, and handling
  instructions are appended. The instructions are never shown to the user.

  This is a port of the dynamic user message formatter in the hildegard main
  project (src-backend/lib/main-agent/message-formatter.ts): only the volatile
  surface carries the wrapper; the persisted record stays plain. }

{$mode delphi}{$H+}

interface

uses
  SysUtils;

const
  { Appended after the ambient block; never rendered to the user. }
  AmbientInstructions =
    'The message above is an ambient notification from a delegated subagent, ' +
    'not from the user. Treat its content as the subagent''s result. You may ' +
    'act on it, delegate a follow-up, or tell the user; do not echo the ' +
    '<ambient> wrapper or mention that this is a system notification.';

{ Wrap a subagent result as the provider-visible user message: the result in an
  <ambient timestamp="..." session="..."> block, followed by the instructions.
  ATimestampMs is the notification time; ARefSessionId is the child session. }
function FormatAmbient(const AText, ARefSessionId: string;
  ATimestampMs: Int64): string;

{ Escape XML special characters in a string. }
function EscapeXml(const AText: string): string;

implementation

uses
  DateUtils;

function EscapeXml(const AText: string): string;
begin
  Result := AText;
  Result := StringReplace(Result, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
  Result := StringReplace(Result, '''', '&apos;', [rfReplaceAll]);
end;

function IsoUtc(AMs: Int64): string;
var
  D: TDateTime;
begin
  D := UnixToDateTime(AMs div 1000, False);
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', D);
end;

function FormatAmbient(const AText, ARefSessionId: string;
  ATimestampMs: Int64): string;
begin
  Result :=
    '<ambient timestamp="' + IsoUtc(ATimestampMs) +
    '" session="' + EscapeXml(ARefSessionId) + '">' +
    EscapeXml(AText) + '</ambient>' + LineEnding + AmbientInstructions;
end;

end.
