# Go to implementation, in the IDE

In Delphi, Ctrl+click on `x.DoSomething()` goes to the interface's declaration. With the IDE
package (`delphi\ide\DelphiPPIDE.bpl`, see [its README](../../delphi/ide/README.md)) installed,
**Ctrl+Alt+click** goes to the classes that implement it, or right-click the method's name and
choose **Go to Implementation**, just below Find Declaration. With one implementation it goes
straight there; with more, a menu lists them, each with its unit and line.

Open `GoToImpl.dpr` here. In `Shapes.pas`, at the end:

| Where | What it offers |
|---|---|
| `x.DoSomething();` in `Use` | `TOther.Run` (through `procedure IMyInterface.DoSomething = Run`), `TBase.DoSomething`, `TDerived.DoSomething` (an override) |
| `FService.DoSomething;` in `Fields.pas` (a field) | the same three |
| `Service.Value;` (a property) | `TBase.Value`, `TOther.Value` |
| `CreateMyObject.DoSomething;` (a function's result) | the same three as `x.DoSomething()` |
| `FKids.DoSomething;` (an `IChild`, which no class implements) | nothing: the menu says so |

The index is the active project's: the `.pas` files in its folder and below, and in each folder of
its search path. It's read in the background when you first click in an editor, and again when
the project or its search path changes. For something bigger: Spring4D's
`Tests\Spring.Tests.Delphi12.dproj` puts all of `Source` on its search path; there,
`fInspectors.Add(inspector)` in `Spring.Container.Builder.pas` offers three lists' `Add`.

It's a sketch, not the compiler: no overloads, no `as` or `with`, generic constraints unchecked,
and a unit saved after the index was read isn't read again until the project changes or the IDE
restarts.
