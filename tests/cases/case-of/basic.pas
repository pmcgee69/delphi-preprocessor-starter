program CaseBasic;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes;

const
  sWorld = 'world';

function Greet(const s: string): Integer;
begin
  case s of
    'hello', 'hi' : Result := 1;
    sWorld        : begin Result := 3; end;
  else
    Writeln('  (no match for ', s, ')');
    Result := 0;
  end;
end;

function Kind(const x: TObject): string;
begin
  Result := '?';
  case x.ClassType of
    TStringList : Result := 'a string list';
    TList       : Result := 'a list';
  end;
end;

function Day(d: Integer): string;
begin
  case d of            // an ordinal case: left alone
    1 : Result := 'Mon';
  else
    Result := '-';
  end;
end;

begin
  Writeln(Greet('hi'), ' ', Greet('world'), ' ', Greet('bye'));
  var L := TStringList.Create;
  Writeln(Kind(L), ', ', Day(1));
  L.Free;
end.
