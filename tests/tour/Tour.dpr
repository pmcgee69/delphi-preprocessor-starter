program Tour;

// One program with something for every example rule. It doesn't compile as it stands: Delphi
// has no case on strings, no property without read or write, and one uses clause a section.
// Run the rules, and the result does. In Zed: the task "Rules: compile and run this file".

{$APPTYPE CONSOLE}

uses System.SysUtils;

// each need can have its own clause and comment (uses-merge)
uses System.Classes;

type
  TPerson = class
  public
    property Name: string;      // a field, read and write appear (auto-property)
  end;

function Greeting(const S: string): string;
begin
  case S of                     // on strings (case-of)
    'hello', 'hi' : Result := 'a greeting';
    'bye'         : Result := 'a farewell';
  else
    Result := 'something else';
  end;
end;

function KindOf(L: TObject): string;
begin
  case L.ClassType of           // on class types (case-of)
    TStringList : Result := 'strings';
    TList       : Result := 'pointers';
  else
    Result := 'unknown';
  end;
end;

var
  P: TPerson;
  L: TStringList;
begin
  // Oops;                      // take out the // to break it: dcc names this line

  P := TPerson.Create;
  L := TStringList.Create;
  try
    with P do                   // what might each name in here belong to? (with)
      Name := 'Ada';
    Assert(P.Name <> '');       // gains its file, line and text (assert-message)
    WriteLn(P.Name, ': ', Greeting('hi'), ', ', Greeting('bye'), ', ', Greeting('?'));
    WriteLn(KindOf(L));
    WriteLn('and "quoted"');    // each " becomes '' (double-quotes)
    try
      L.Add('x');
    except                      // swallows every exception (with-try)
    end;
  finally
    L.Free;
    P.Free;
  end;
end.
