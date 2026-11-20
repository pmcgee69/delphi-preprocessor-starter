unit Shapes;

interface

type
  IMyInterface = interface
    ['{11111111-2222-3333-4444-555555555555}']
    procedure DoSomething;
    function Value: Integer;
  end;

  TBase = class(TInterfacedObject, IMyInterface)
  public
    procedure DoSomething; virtual;
    function Value: Integer;
  end;

  TDerived = class(TBase)
  public
    procedure DoSomething; override;
  end;

  TOther = class(TInterfacedObject, IMyInterface)
    procedure IMyInterface.DoSomething = Run;
    procedure Run;
    function Value: Integer;
  end;

function CreateMyObject: IMyInterface;

implementation

procedure TBase.DoSomething;
begin
end;

function TBase.Value: Integer;
begin
  Result := 1;
end;

procedure TDerived.DoSomething;
begin
end;

procedure TOther.Run;
begin
end;

function TOther.Value: Integer;
begin
  Result := 2;
end;

function CreateMyObject: IMyInterface;
begin
  Result := TOther.Create;
end;

procedure Use;
var
  x: IMyInterface;
begin
  x := CreateMyObject();
  x.DoSomething();
end;

end.
