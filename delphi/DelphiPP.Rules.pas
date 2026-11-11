unit DelphiPP.Rules;

{ THE LIST OF RULES: the one place a new rule is registered.

  To add a rule:
    1. write its unit, a class of TRule (see DelphiPP.Rule.WithStatement.pas,
       which says how one is made, step by step);
    2. add the unit to the uses below, and the class to AllRules;
    3. build.cmd. delphipp.exe and RunTests.exe both find it from here.

  Give it a test folder too, tests\cases\<its Name>\, shared with the Python
  side. }

interface

uses
  DelphiPP.Engine;

// every rule, made new: the caller frees them
function AllRules: TArray<TRule>;
// the rules named (comma-separated), or all when Names is empty; an unknown
// name raises, naming the rules there are
function RulesNamed(const Names: string): TArray<TRule>;

implementation

uses
  System.SysUtils,
  DelphiPP.Rule.WithStatement,
  DelphiPP.Rule.AssertMessage,
  DelphiPP.Rule.WithAndTry,
  DelphiPP.Rule.UsesMerge,
  DelphiPP.Rule.CaseOf,
  DelphiPP.Rule.AutoProperty,
  DelphiPP.Rule.DoubleQuotes,
  DelphiPP.Rule.Footnotes,
  DelphiPP.Rule.Derive;

function AllRules: TArray<TRule>;
begin
  Result := [TWithStatement.Create,
             TAssertMessage.Create,
             TWithAndTry.Create,
             TUsesMerge.Create,
             TCaseOf.Create,
             TAutoProperty.Create,
             TDoubleQuotes.Create,
             TFootnotes.Create,
             TDerive.Create];
end;

function RulesNamed(const Names: string): TArray<TRule>;
begin
  var All := AllRules;
  if Names.Trim = '' then
    Exit( All );
  var Known: TArray<string>;
  for var R in All do
    Known := Known + [R.Name];
  for var N in Names.Split([',']) do
  begin
    var Found := False;
    for var R in All do
      if R.Name = N.Trim then
      begin
        Result := Result + [R];
        Found  := True;
      end;
    if not Found then
    begin
      for var R in All do R.Free;
      raise Exception.CreateFmt('no rule %s; the rules are %s',
                                [N.Trim, string.Join(', ', Known)]);
    end;
  end;
  // the rules not chosen
  for var R in All do
  begin
    var Chosen := False;
    for var C in Result do
      Chosen := Chosen or (C = R);
    if not Chosen then
      R.Free;
  end;
end;

end.
