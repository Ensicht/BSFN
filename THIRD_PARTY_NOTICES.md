# Third-party Notices

BoneSystemForNPC's own source code is licensed under MIT, Copyright (c) 2026 Laz.
The project license does not relicense third-party software or game assets.

## REFramework

`vendor/reframework/API.h` is from praydog/REFramework, commit
`a0e9010fb0449dc9d824b5978ee759eeaf50f7c6`.

Source: https://github.com/praydog/REFramework

Header SHA-256: `f63a424ee8ae162d1086b3baab5fa5a78a8a9aa25f0c82644e5775e523100394`

Its original MIT notice is retained at `vendor/reframework/LICENSE` and reproduced
below for binary distributions that do not include the development tree:

MIT License

Copyright (c) 2019 praydog

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

## BoneSystem

BoneSystem is separately obtained from its author. This source repository and
installation packages do not distribute BoneSystem.dll, its embedded program,
or appearance/skeleton assets. The startup adapter is version-specific and
calls the user's installed original implementation. Original licensing and
redistribution conditions remain with that author; MIT here is not a license
to redistribute BoneSystem.

## ArmorVariantManager

The upstream project is referenced for configuration semantics and coding style:
https://github.com/Monkeysama/ArmorVariantManager/tree/MHWS-Beta

ArmorVariantManager is separately installed; its full application is not bundled.
Material preset compatibility follows its data conventions. The upstream MIT
notice (Copyright (c) 2026 MK) is retained at `docs/licenses/ArmorVariantManager.txt`.

## Build dependencies

Python and LLVM-MinGW are supplied by the developer, not bundled here.
Runtime licenses for the statically linked toolchain remain at
`docs/licenses/LLVM-MinGW.txt`, `docs/licenses/MinGW-w64.txt`,
`docs/licenses/MinGW-w64-runtime.txt` and `docs/licenses/winpthreads.txt`.
