program CaseDangling;

{ An arm whose statement is an if with no else: written as it stands, the next arm's else
  would be that if's, and 'two' would never be tested when Flag is false. The arm goes in
  begin ... end. Prints 1 0 2 3. }

{$APPTYPE CONSOLE}

function Pick(const s: string; Flag: Boolean): Integer;
begin
  Result := 0;
  case s of
    'one' : if Flag then Result := 1;
    'two' : Result := 2;
  else
    Result := 3;
  end;
end;

begin
  Writeln(Pick('one', True), ' ', Pick('one', False), ' ', Pick('two', False), ' ', Pick('six', False));
  Readln;
end.
