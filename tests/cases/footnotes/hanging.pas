unit Hanging;

interface

{ A parameter's description over several lines, each indented under it: it goes on with the
  parameter, a colon in it or not (`the mood:` isn't a parameter). Back at the parameters'
  indent, `Result:` is the result's. }

function Greeting(const G: string; Times: Integer): string;

implementation

function Greeting(const G: string; Times: Integer): string;
begin
  Result := G;
end;

end.

[Greeting] A greeting.
  G: the name,
     the mood: Calm or Excited,
     and the count.
  Times: how often.
  Result: the greeting.
