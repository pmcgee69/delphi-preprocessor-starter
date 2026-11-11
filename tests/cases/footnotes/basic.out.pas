unit Basic;

interface

type
  /// <summary>Someone who can be greeted.</summary>
  TPerson = class
  private
    FName: string;
  public
    /// <summary>Greets another.</summary>
    /// <param name="Other">who.</param>
    /// <param name="Times">how often.</param>
    function Greet(const Other: string; Times: Integer): string;
    /// <summary>The person's name, ' written as in a string.</summary>
    property Name: string read FName;
  end;

/// <summary>Says hello to Name, Times times, in the language of the day.</summary>
/// <param name="Name">who to greet.</param>
/// <param name="Times">how often; at least 1 (and &lt; 10 &amp; &gt; 0).</param>
/// <returns>the greeting.</returns>
function Greeting(const Name: string; Times: Integer): string;

implementation

/// <summary>Twice the sum, a routine of the implementation's own.</summary>
/// <param name="A">one.</param>
/// <param name="B">the other.</param>
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
