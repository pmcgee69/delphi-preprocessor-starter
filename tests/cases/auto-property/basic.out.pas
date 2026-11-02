program AutoPropertyBasic;

{$APPTYPE CONSOLE}

uses
  System.SysUtils;

type
  TPerson = class
  private
    FName: string;
    FAge: Integer;
  public
    property Name: string read FName write FName;
    property Age: Integer read FAge write FAge;
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
