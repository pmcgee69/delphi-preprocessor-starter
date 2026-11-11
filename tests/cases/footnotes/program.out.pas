program Footnoted;

{$APPTYPE CONSOLE}

type
  /// <summary>A digit.</summary>
  TCount = 0..9;

/// <summary>N squared.</summary>
/// <param name="N">a digit.</param>
/// <returns>from 0 to 81.</returns>
function Square(N: TCount): Integer;
begin
  Result := N * N;
end;

begin
  Writeln(Square(3));
end.
