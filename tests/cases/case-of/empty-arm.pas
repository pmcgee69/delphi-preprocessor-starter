program CaseEmptyArm;

{ An arm with no statement, which Delphi allows: an empty then. Typed half way
  in the IDE (user, 7 Nov), `1 :` before the else crashed the rule on both sides. }

{$APPTYPE CONSOLE}

function Code(const s: string): Integer;
begin
  Result := 0;
  case s of
    'skip' : ;
    'one'  : Result := 1;
    'none' :
  else
    Result := -1;
  end;
end;

begin
  Writeln(Code('skip'), ' ', Code('one'), ' ', Code('none'), ' ', Code('x'));
  Readln;
end.
