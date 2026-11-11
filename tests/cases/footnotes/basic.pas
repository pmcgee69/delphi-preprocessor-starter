unit Basic;

interface

type
  TPerson = class
  private
    FName: string;
  public
    function Greet(const Other: string; Times: Integer): string;
    property Name: string read FName;
  end;

function Greeting(const Name: string; Times: Integer): string;

implementation

function Twice(A, B: Integer): Integer;
begin
  Result := 2 * (A + B);
end;

function TPerson.Greet(const Other: string; Times: Integer): string;
begin
  Result := Greeting(Other, Times);
end;

function Greeting(const Name: string; Times: Integer): string;
begin
  Result := Name;
end;

end.

[Greeting] Says hello to Name, Times times,
  in the language of the day.
  Name: who to greet.
  Times: how often; at least 1 (and < 10 & > 0).
  Result: the greeting.

[TPerson] Someone who can be greeted.

[TPerson.Greet] Greets another.
  Other: who.
  Times: how often.

[TPerson.Name] The person''s name, '' written as in a string.

[Twice] Twice the sum, a routine of the implementation's own.
  A: one.
  B: the other.
