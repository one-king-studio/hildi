unit hildi.ambient;
{ The ambient notification wrapper: a subagent's result delivered to the parent
  as an ambient message.

  Ambient records are persisted as their own kind (mrAmbient) and rendered
  specially by the UI. When the conversation is composed for the provider, an
  ambient record is *hijacked* into a user message: the result is wrapped in an
  <ambient> tag carrying the child session id and a timestamp, and handling
  instructions are appended. The instructions are never shown to the user.

  This is a port of the dynamic user message formatter in the hildi main
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

{ Escape XML special characters in an element's *content*: only &, <, >.
  Quotes need not be escaped in content (they only matter inside attribute
  values), so leaving them alone avoids noise like &apos; in code the model
  reads back. }
function EscapeXmlContent(const AText: string): string;

{ Escape XML special characters in an attribute *value*: also the quotes. }
function EscapeXmlAttr(const AText: string): string;

implementation

uses
  DateUtils;

function EscapeXmlContent(const AText: string): string;
begin
  Result := AText;
  Result := StringReplace(Result, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
end;

function EscapeXmlAttr(const AText: string): string;
begin
  Result := EscapeXmlContent(AText);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
  Result := StringReplace(Result, '''', '&apos;', [rfReplaceAll]);
end;

{ Kept as the attribute escaper (the general, safe form) for existing callers
  and tests. }
function EscapeXml(const AText: string): string;
begin
  Result := EscapeXmlAttr(AText);
end;

function IsoUtc(AMs: Int64): string;
var
  D: TDateTime;
begin
  { True = UTC: the timestamp claims a 'Z' suffix, so it must be UTC. }
  D := UnixToDateTime(AMs div 1000, True);
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', D);
end;

function FormatAmbient(const AText, ARefSessionId, ALabel, ASource,
  AStatus: string; ATimestampMs: Int64): string;
begin
  Result :=
    '<ambient timestamp="' + IsoUtc(ATimestampMs) + '">' + LineEnding +
    '  <message source="' + EscapeXmlAttr(ASource) +
    '" id="' + EscapeXmlAttr(ARefSessionId) +
    '" label="' + EscapeXmlAttr(ALabel) +
    '" status="' + EscapeXmlAttr(AStatus) + '">' + LineEnding +
    EscapeXmlContent(AText) + LineEnding +
    '  </message>' + LineEnding + LineEnding +
    '  <instructions>' + LineEnding +
    AmbientInstructions + LineEnding +
    '  </instructions>' + LineEnding +
    '</ambient>';
end;

end.
