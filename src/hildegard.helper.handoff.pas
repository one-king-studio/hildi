unit hildegard.helper.handoff;
{ The handoff wrapper: a checkpoint's summary carried forward into a fresh
  context as the first user message of the new page.

  A checkpoint bridges two pages of one session. On resume its document is
  delivered as *orientation*, not authority: the next agent reads it to
  understand the goal and state, and follows the sources it names to ground
  itself. It is deliberately NOT the system prompt (that slot is for standing
  instructions, not volatile carried context) and NOT an ambient task result
  (whose framing - "act on it, delegate, or tell the user" - is wrong for a
  handoff). It is a peer's handoff, and the operator's own turn follows it.

  Like the ambient wrapper, only the volatile surface carries the wrapper: the
  document stays plain in session_checkpoints. }

{$mode delphi}{$H+}

interface

uses
  SysUtils;

const
  { Delivered inside <instructions>; never rendered to the user. Generic and
    domain-neutral: a code repo, a ticket queue, or a research task alike. }
  HandoffInstructions =
    'This is a handoff document from earlier in this work, written by the agent ' +
    'that came before you. It is not authoritative: treat it as orientation, ' +
    'not as verified fact. Read the sources it names to ground yourself, then ' +
    'continue from its open threads. Do not re-explore the work from scratch - ' +
    'the handoff exists so that you don''t have to.';

{ Wrap a checkpoint summary as the provider-visible opening user message:

    <handoff seq="N">
      <summary>
    SUMMARY
      </summary>

      <instructions>
    ...
      </instructions>
    </handoff>

  ASeq is the checkpoint boundary - the message high-water mark the document
  stands in for. }
function FormatHandoff(const ASummary: string; ASeq: Int64): string;

implementation

uses
  hildegard.helper.ambient;   // EscapeXmlContent

function FormatHandoff(const ASummary: string; ASeq: Int64): string;
begin
  Result :=
    '<handoff seq="' + IntToStr(ASeq) + '">' + LineEnding +
    '  <summary>' + LineEnding +
    EscapeXmlContent(ASummary) + LineEnding +
    '  </summary>' + LineEnding + LineEnding +
    '  <instructions>' + LineEnding +
    HandoffInstructions + LineEnding +
    '  </instructions>' + LineEnding +
    '</handoff>';
end;

end.
