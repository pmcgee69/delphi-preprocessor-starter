unit CaseErrors;

interface

implementation

uses
  System.SysUtils;

procedure P(const s: string; ch: Char);
var
  x: Integer;
begin
  case Trim(s) of
    'apple' : x := 1;
  end;
  case s of
    'apple'  : x := 2;
    'b'..'d' : x := 3;
  end;
  case ch of           // a Char case: left alone
    'a', '''' : x := 4;
    'b'..'d'  : x := 5;
    #10, #$0D : x := 6;
  end;
  case s of            // #13#10 is two characters: a string case
    #13#10 : x := 7;
  end;
end;

end.
