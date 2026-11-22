program Probe;

{$APPTYPE CONSOLE}

type
  IShape = interface
    ['{6B1E1D2A-1C1B-4D6E-9F3A-0A1B2C3D4E5F}']
    function Area: Double;
  end;

  TSquare = class(TInterfacedObject, IShape)
    function Area: Double;
  end;

  TCircle = class(TInterfacedObject, IShape)
    function Area: Double;
  end;

  TAnimal = class
    procedure Speak; virtual; abstract;
  end;

  TDog = class(TAnimal)
    procedure Speak; override;
  end;

  TCat = class(TAnimal)
    procedure Speak; override;
  end;

function TSquare.Area: Double;
begin
  Result := 4;
end;

function TCircle.Area: Double;
begin
  Result := 3.14;
end;

procedure TDog.Speak;
begin
  Writeln('woof');
end;

procedure TCat.Speak;
begin
  Writeln('miaow');
end;

var
  S: IShape;
  A: TAnimal;
begin
  S := TSquare.Create;
  Writeln(S.Area);
  A := TDog.Create;
  A.Speak;
  A.Free;
end.
