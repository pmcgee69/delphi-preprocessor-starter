unit DelphiPP.Rules;

{ The rules there are. A rule is a class of DelphiPP.Engine's TRule: its Name
  (how it is chosen, and named in its messages), the Kinds of node it wants,
  and Visit, called for each such node in source order. Add yours here, each in
  a unit of its own, with a test folder in ..\tests\cases\<name>\, shared with
  the Python side. }

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
  System.SysUtils, DelphiPP.Rule.WithStatement, DelphiPP.Rule.AssertMessage;

function AllRules: TArray<TRule>;
begin
  Result := [TWithStatement.Create, TAssertMessage.Create];
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
