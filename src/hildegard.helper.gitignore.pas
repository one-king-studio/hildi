unit hildegard.helper.gitignore;
{ The harness's view of the ignore rules. The pattern language and the rule set
  live in the `fileignore` library (src/fileignore), so the same code serves
  `.gitignore`, an `.agentignore`, and the operator's own file.

  This unit exists for two reasons only: the harness's existing callers name it,
  and it records the harness's POLICY - which file layers exist and which wins.
  The policy is the part that belongs to us; the language does not. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes,
  fileignore.rules;

type
  { Re-exported so a caller can name a layer without also importing the library. }
  TIgnoreLayer = fileignore.rules.TIgnoreLayer;

const
  ilGit = fileignore.rules.ilGit;
  ilAgent = fileignore.rules.ilAgent;
  ilOperator = fileignore.rules.ilOperator;
  { The file an operator or an agent writes to exclude paths from the harness.
    Ours, and authoritative over a repository's .gitignore: excluding something
    from the agent is a stronger statement than excluding it from version
    control. }
  AgentIgnoreFileName = fileignore.rules.AgentIgnoreFileName;
  GitIgnoreFileName = fileignore.rules.GitIgnoreFileName;

  { The ignore files a walker should read at each directory, in the order it
    should read them. A later file may override an earlier one within its layer;
    across layers the higher precedence wins. }
  IgnoreFileNames: array[0..1] of string = (
    GitIgnoreFileName,
    AgentIgnoreFileName);

type
  { The rule set. A thin subclass so the harness can add its own defaults
    without changing the library. }
  TIgnoreRules = class(fileignore.rules.TIgnoreRules)
  public
    { A harness rule set: `.git` is skipped (git itself does not report it, and
      a repository's internals are never the agent's work). }
    constructor CreateDefault;
  end;

{ The pattern language, re-exported. }
function MatchIgnore(const APattern, ACandidate: string): Boolean;

implementation

constructor TIgnoreRules.CreateDefault;
begin
  inherited Create(True);
end;

function MatchIgnore(const APattern, ACandidate: string): Boolean;
begin
  Result := fileignore.rules.MatchIgnore(APattern, ACandidate);
end;

end.
