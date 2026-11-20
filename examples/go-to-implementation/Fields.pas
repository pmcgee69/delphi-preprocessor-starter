unit Fields;

interface

uses Shapes;

type
  IChild = interface(IMyInterface)
    procedure More;
  end;

  TUser = class
  private
    FService: IMyInterface;
    FKids: IChild;
  public
    property Service: IMyInterface read FService;
    procedure Go;
  end;

implementation

procedure TUser.Go;
begin
  FService.DoSomething;
  Service.Value;
  FKids.DoSomething;
  CreateMyObject.DoSomething;
end;

end.
