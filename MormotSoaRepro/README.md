# mORMot 2 — SIGSEGV on Delphi 13 / Linux64: SOA method returning a managed record by function result

## Summary

On **Delphi 13 (RAD Studio 37.0), Linux64 target**, an interface-based service
method that returns a **managed type** (record, string, dynamic array,
variant...) as its **function `Result`** crashes with an access violation when
invoked over SOA.

Declaring the *same* method with an **`out` parameter** instead works correctly.

The identical program compiled for **Win64 runs to completion**, and the same
code built with **FPC for Linux64 also works** — the bug is specific to the
**Delphi LLVM Linux64** compiler.

A proposed fix is on branch
[`fix/delphi-linux-x64-soa-managed-result`](https://github.com/AntoineGS/mORMot2/tree/fix/delphi-linux-x64-soa-managed-result)
(6 small, fully gated Pascal edits to `mormot.core.interfaces.pas`, no change to
the prebuilt `.o`). See **The fix** below.

## Environment

- Delphi 13 / RAD Studio 37.0, **Linux64** platform (Delphi LLVM toolchain)
- mORMot 2, commit `0949ec94a` (2026-05-21) — also reproduced on older revisions
- Server: `TRestServerFullMemory` + `TRestHttpServer` (`useHttpAsync`)
- Client: `TRestHttpClient`

## The two methods

```pascal
TReproResult = record      // a managed record (contains a RawUtf8 field)
  text: RawUtf8;
  number: Integer;
end;

IReproService = interface(IInvokable)
  ['{6B1D8E20-9C44-4F7A-AE3D-2F0B6C5147A9}']
  function  ViaFunctionResult(const input: RawUtf8): TReproResult;          // (A) crashes
  procedure ViaOutParam(const input: RawUtf8; out output: TReproResult);    // (B) works
end;
```

`MormotSoaRepro.dpr` is a single console program: it starts the server, starts
an HTTP client, and calls both methods over SOA in-process. One run reproduces
the whole thing.

## Verified behaviour (unpatched mORMot)

**Win64** — runs to completion (exit code 0): both `(A)` and `(B)` succeed.

**Linux64** — `(B) ViaOutParam` works, then `(A) ViaFunctionResult` crashes:

```
(B) ViaOutParam(...; out output)  -- expected to work everywhere
    OK   text="hello world"  number=42

(A) ViaFunctionResult(...): TReproResult  -- server SIGSEGV on Delphi/Linux64
Exception EAccessViolation in module ... accessing address 0000000000000000
```

gdb backtrace of the crash (Linux64, Debug build) — this repro's client is also
Delphi/Linux64, so the failure surfaces in the **client-side** trampoline:

```
#0  Mormot.Core.Text.VarRecToTempUtf8                        mormot.core.text.pas:9031
#3  Mormot.Core.Text.ESynException.Create                    mormot.core.text.pas:10004
#4  Mormot.Core.Text.ESynException.RaiseUtf8                 mormot.core.text.pas:10031
#5  Mormot.Core.Interfaces.FakeCallRaise                     mormot.core.interfaces.pas:3459
#6  Mormot.Core.Interfaces.TInterfacedObjectFakeRaw.FakeCall mormot.core.interfaces.pas:3477
#7  Mormot.Core.Interfaces.dofakecall                        mormot.core.interfaces.pas:4837
#8  x64fakestub
#9  Mormotsoarepro.Run                                       MormotSoaRepro.dpr:109
```

`FakeCall` at `:3477` reaches `FakeCallRaise` ("MethodIndex out of range")
because the `Self` it received is not the fake interface at all — see below.

The original application this was reduced from has a non-Delphi HTTP client, so
there the crash is **server-side** instead, in `x64callmethod`: the
implementation method is entered with a corrupt `Self` (a scratch buffer), and
the hidden result-pointer slot holds the real interface pointer — the two are
swapped.

## Root cause

mORMot models one ABI for every x64-POSIX target — `ABISYSVX64`, defined for any
`CPUX64 + OSPOSIX` with **no FPC-vs-Delphi distinction**
(`mormot.defines.inc:845-850`).

That model hard-codes the **FPC** convention for a method returning a by-ref
result (`mormot.core.interfaces.pas:1870-1871`):

```pascal
PARAMREG_FIRST  = REGRDI;   // Self    -> RDI (1st integer register)
PARAMREG_RESULT = REGRSI;   // @Result -> RSI (2nd integer register)
```

FPC passes `Self` in the 1st register and the hidden `@Result` in the 2nd.
**Delphi's LLVM Linux64 compiler does the opposite** — for a by-ref result it
follows the Itanium C++ ABI: `@Result` in the 1st register (RDI), `Self` pushed
to the 2nd (RSI). mORMot never accounts for that, so for every SOA method that
returns a by-ref result on Delphi-Linux64, `Self` and `@Result` are swapped.

- **Client side** — `x64fakestub` forwards the 1st integer register to
  `FakeCall` as `Self`. For `function ...: <managed>` that register holds
  `@Result`, so `FakeCall`'s `me := SelfFromInterface` (`:3473`) yields a bogus
  object, the `MethodIndex` bounds check fails, and `FakeCallRaise` faults.
- **Server side** — `RawExecute` fills `ParamRegs[PARAMREG_FIRST]` with `Self`
  (`:7381`) and the result pointer into `ParamRegs[PARAMREG_RESULT]`; the
  Delphi-compiled implementation method then reads them the other way round.
- **Why `out` parameters work:** an `out` parameter is an ordinary by-ref
  pointer argument — there is *no* hidden result pointer, so nothing is
  mis-positioned, and `Self` stays in the 1st register for both compilers.

This affects **every** by-ref result on Delphi-Linux64: records, `RawUtf8` /
`string`, dynamic arrays, variants, interfaces.

## The fix

Branch [`fix/delphi-linux-x64-soa-managed-result`](https://github.com/AntoineGS/mORMot2/tree/fix/delphi-linux-x64-soa-managed-result)
— 6 edits to `src/core/mormot.core.interfaces.pas`, **all pure Pascal, no change
to the prebuilt `delphi-linux-x64.o`**, all gated behind one new symbol so FPC
and Delphi-Win64 compile **byte-for-byte unchanged**:

```pascal
{$ifdef ISDELPHI}
  {$ifdef ABISYSVX64}
    {$define DELPHI_SYSVX64_RESULT_FIRST}
  {$endif}
{$endif}
```

1. Define `DELPHI_SYSVX64_RESULT_FIRST` (the gate above).
2. Move the `_FAKEVMT` declaration earlier so `FakeCall` can use it.
3. **`FakeCall`** — if the trampoline handed us `@Result` instead of the
   interface (detected because a genuine fake interface has
   `fVTable = _FAKEVMT`), recover the real `Self` from the 2nd register saved on
   the stack.
4. **`FakeCallGetParamsFromStack`** — read the hidden result pointer from the
   1st register (RDI) instead of the 2nd.
5. **`RawExecute`** — move the by-ref result pointer into the RDI slot.
6. **`RawExecute`** — place `Self` into the RSI slot for by-ref-result methods.

Net effect on Delphi-Linux64: the hidden result pointer travels in the 1st
integer register and `Self` in the 2nd — matching what the Delphi LLVM compiler
actually emits. The internal `RegisterIdent` layout is left identical to FPC;
only the two physical ABI boundaries are bridged.

### Verified behaviour (patched mORMot)

| Build   | Unpatched                              | Patched                  |
|---------|----------------------------------------|--------------------------|
| Win64   | `SUCCESS`, exit 0                      | `SUCCESS`, exit 0        |
| Linux64 | `EAccessViolation` on `(A)`            | `SUCCESS`, exit 0 (3/3)  |

```
(B) ViaOutParam(...; out output)  -- expected to work everywhere
    OK   text="hello world"  number=42

(A) ViaFunctionResult(...): TReproResult  -- server SIGSEGV on Delphi/Linux64
    OK   text="hello world"  number=42

SUCCESS - both SOA calls returned (this is the Win64 outcome)
```

## Build & run

mORMot 2 must be reachable on the IDE library path.

- `build.bat Win64`   → run `Win64\Debug\MormotSoaRepro.exe`   (prints `SUCCESS`)
- `build.bat Linux64` → run `Linux64/Debug/MormotSoaRepro` on Linux64
  (unpatched: crashes; patched: prints `SUCCESS`)

`build.bat` is a thin wrapper around `rsvars.bat` + `msbuild`; adjust the
RAD Studio path inside it for your install.

## Workaround (without patching mORMot)

Declare SOA methods to return structured results via `out` parameters rather
than as function results when targeting Delphi Linux64.
