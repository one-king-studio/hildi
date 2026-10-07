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
  { Canonical statuses carried by an ambient <message>. }
  AmbientStatusCompleted = 'completed';
  AmbientStatusFailed    = 'failed';
  AmbientStatusAborted   = 'aborted';
  AmbientStatusGone      = 'gone';

  { Placed inside <instructions>; never rendered to the user. }
  AmbientInstructions =
    'This is an ambient notification, not a message from the user. The ' +
    '<message> element carries the result of an asynchronous task (its ' +
    'source, id, label, and status identify it). Treat its content as that ' +
    'task''s result. You may act on it, delegate a follow-up, or tell the ' +
    'user; do not echo this wrapper or mention that it is a system ' +
    'notification.';

{ Wrap a task result as the provider-visible user message:

    <ambient timestamp="ISO">
      <message source="..." id="..." label="..." status="...">
    TEXT
      </message>

      <instructions>
    ...
      </instructions>
    </ambient>

  ATimestampMs is the notification time; ARefSessionId, ALabel, ASource, and
  AStatus identify the producing task and its outcome. }
function FormatAmbient(const AText, ARefSessionId, ALabel, ASource,
  AStatus: string; ATimestampMs: Int64): string;

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

function FormatAmbient(const AText, ARefSessionId, ALabel, ASource,
  AStatus: string; ATimestampMs: Int64): string;
begin
  Result :=
    '<ambient timestamp="' + IsoUtc(ATimestampMs) + '">' + LineEnding +
    '  <message source="' + EscapeXml(ASource) +
    '" id="' + EscapeXml(ARefSessionId) +
    '" label="' + EscapeXml(ALabel) +
    '" status="' + EscapeXml(AStatus) + '">' + LineEnding +
    EscapeXml(AText) + LineEnding +
    '  </message>' + LineEnding + LineEnding +
    '  <instructions>' + LineEnding +
    AmbientInstructions + LineEnding +
    '  </instructions>' + LineEnding +
    '</ambient>';
end;

end.
