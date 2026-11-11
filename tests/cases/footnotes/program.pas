program Footnoted;

{$APPTYPE CONSOLE}

type
  TCount = 0..9;

function Square(N: TCount): Integer;
begin
  Result := N * N;
end;

begin
  Writeln(Square(3));
end.
[Square] N squared.
  N: a digit.
  Result: from 0 to 81.

[TCount] A digit.
