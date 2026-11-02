program AutoPropertyBasic;

{$APPTYPE CONSOLE}

uses
  System.SysUtils;

type
  TPerson = class
  public
    property Name: string;
    property Age: Integer;
    procedure Show;
  protected
    FNotes: string;
    property Notes: string read FNotes write FNotes;   // has read and write: left alone
  end;

procedure TPerson.Show;
begin
  Writeln(Name, ', ', Age);
end;

begin
  var P := TPerson.Create;
  P.Name := 'Vincent';
  P.Age  := 2016;
  P.Show;
  P.Free;
end.
