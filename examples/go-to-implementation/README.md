# Go to implementation, in the IDE

In Delphi, Ctrl+click on `x.DoSomething()` goes to the interface's declaration. With the IDE
package (`delphi\ide\DelphiPPIDE.bpl`, see [its README](../../delphi/ide/README.md)) installed,
**Ctrl+Shift+click** goes to the classes that implement it, or right-click the method's name and
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
| `procedure TBase.DoSomething;` (a virtual method's heading) | `TBase.DoSomething`, `TDerived.DoSomething` (its override) |
| `procedure DoSomething; virtual;` in `TBase` | the same two |
| `function TBase.Value` (not virtual) | `TBase.Value` alone |

**Find References (delphipp)**, on the same menu, lists every use in the Messages view. Here, on
`DoSomething` in `IMyInterface`: the declaration, `x.DoSomething()` in `Use`, and in `Fields.pas`
`FService.DoSomething`, `FKids.DoSomething` (an `IChild` inherits it) and
`CreateMyObject.DoSomething`. On `IMyInterface` itself: its 10 uses, both units.

The index is the active project's: the `.pas` and `.dpr` files in its folder and below, and in each folder of
its search path. It's read in the background when you first click in an editor, and again when
the project or its search path changes. For something bigger: Spring4D's
`Tests\Spring.Tests.Delphi12.dproj` puts all of `Source` on its search path; there,
`fInspectors.Add(inspector)` in `Spring.Container.Builder.pas` offers three lists' `Add`.

It's a sketch, not the compiler: overloads are told apart by the number of arguments and the
types it can see (literals, enum values, typed variables; where it can't tell, it offers each one
that fits), no `as` or `with`, generic constraints unchecked.
The unit you ask from is read again whenever it has changed, saved or not, and Find References
reads every unit open in the editor as it is; another unit saved meanwhile is read again when
you next ask from it (in Zed, as soon as it's saved).

## Beside DelphiLSP

Delphi 13's own language server, `DelphiLSP.exe`, says it provides implementation
(`implementationProvider: true`), but asked directly (22 Nov 2026, with
[`tools/delphilsp-probe`](../../tools/delphilsp-probe/README.md)) it's the old Ctrl+Shift+Up/Down:

| Asked at | DelphiLSP: definition | DelphiLSP: implementation | delphipp: implementation |
|---|---|---|---|
| `S.Area`, `S` an interface | the interface's `Area` | **nothing** | each class's `Area` |
| `A.Speak`, `Speak` virtual, abstract | `TAnimal.Speak` | **nothing** | each override |
| an interface's or abstract method's declaration | nothing | **nothing** | its implementations |
| a class method's declaration | its body | its body's first statement | |
| a method's body heading | its declaration | its declaration | |

It has no references at all (`textDocument/references`: *Method not found*), and no type
definition. The IDE talks to one DelphiLSP (with two agents it starts, `-Name Agent0` and
`Agent1`), with no setting for another server; delphipp's package works beside it.
