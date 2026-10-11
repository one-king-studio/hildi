unit hildegard.helper.wrap;
{ Wrap a user message for the provider so dynamic context (the skills manifest,
  the current time, ...) can never be mistaken for the user's own words.

  The user's text lives ONLY inside <message>; dynamic context lives in
  <context>, a sibling. The persisted record stays plain - the wrapper is added
  on the way out, exactly as hildegard.helper.ambient does for ambient messages.

  Ported from hildegard/main's message formatter
  (src-backend/lib/main-agent/message-formatter.ts, formatCurrentMessage). }

{$mode delphi}{$H+}

interface

uses
  SysUtils;

const
  { Behavioural guidance delivered with a user turn. }
  UserInstructions =
    'Respond with plain Markdown only. Do not wrap your response in XML tags ' +
    'such as <message>, <context>, or <summary> - those are system-provided ' +
    'metadata, not part of your output format.';

{ The provider-visible form of a user turn:

    <context>
      <now>ISO</now>
    </context>
    <instructions>...</instructions>
    <message>ESCAPED USER TEXT</message>

  ATimestampMs is the turn's time. Dynamic context (e.g. a skills manifest)
  belongs in the <context> block, never in <message>. }
function FormatUserMessage(const AContent: string;
  ATimestampMs: Int64): string;

implementation

uses
  DateUtils,
  hildegard.helper.ambient;

function IsoUtc(AMs: Int64): string;
var
  D: TDateTime;
begin
  { True = UTC: the timestamp claims a 'Z' suffix, so it must be UTC. }
  D := UnixToDateTime(AMs div 1000, True);
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', D);
end;

function FormatUserMessage(const AContent: string;
  ATimestampMs: Int64): string;
begin
  Result :=
    '<context>' + LineEnding +
    '  <now>' + IsoUtc(ATimestampMs) + '</now>' + LineEnding +
    '</context>' + LineEnding +
    '<instructions>' + UserInstructions + '</instructions>' + LineEnding +
    '<message>' + EscapeXmlContent(AContent) + '</message>';
end;

end.
