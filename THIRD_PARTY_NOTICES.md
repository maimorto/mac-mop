# Third-party notices

Mac Mop reuses small parts of the following open-source projects. Each entry lists what was used and the license under which it was used.


## MacSpace

- Project: MacSpace — https://github.com/1architect/macspace-releases
- License: MIT
- Copyright (c) 2026 1architect
- What was used: the per-user preference keys and their on/off values for the Apple Privacy page (`com.apple.AdLib` / `allowApplePersonalizedAdvertising`, `com.apple.assistant.support` / `Siri Data Sharing Opt-In Status` with 1 = on and 2 = off), the location of `/Library/Application Support/CrashReporter/DiagnosticMessagesHistory` (`AutoSubmit`, `ThirdPartyDataSubmit`), the Apple Intelligence eligibility file (`/private/var/db/os_eligibility/eligibility.plist`, `OS_ELIGIBILITY_DOMAIN_SIRI_MODE`, answer 4 = eligible) and the generative-models asset folder. Used in `Sources/MacCleanerKit/ApplePrivacySettings.swift`. No code was copied; Mac Mop's implementation is its own.

```
MIT License

Copyright (c) 2026 1architect

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```


## ESET malware-ioc (YARA rules)

- Project: ESET malware-ioc — https://github.com/eset/malware-ioc
- License: BSD-2-Clause (repository LICENSE and the header of each rule file)
- Copyright (c) 2014-2018 ESET spol. s r.o.; rule file: Copyright (c) 2016, ESET
- What was used: `keydnap/keydnap.yar` (OSX/Keydnap downloader, packer and backdoor rules, author Marc-Etienne M.Léveillé), bundled unmodified as `Resources/YARA/eset-keydnap.yar` and copied into the app's `Contents/Resources/YARA`. It is the only macOS rule file in the repository; the others target Windows / Linux. Mac Mop's own YARA engine (`Sources/MacCleanerKit/XProtectYara*.swift`) evaluates it; hits are listed for review, never pre-selected. The full licence text ships next to the rules as `Resources/YARA/LICENSE-ESET-malware-ioc.txt`.

```
Copyright (c) 2014-2018 ESET spol. s r.o.
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
this list of conditions and the following disclaimer in the documentation
and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Malware family names (no third-party data)

- `Sources/MacCleanerKit/MalwareFamilies.swift` maps Apple XProtect codenames to common family names. It was written for Mac Mop from public write-ups; the SentinelLabs "XProtect-Malware-Families" list (https://github.com/SentineLabs/XProtect-Malware-Families) has no licence, so nothing from it was copied.
- Ideas only (no code, rules or text reused): Skint / XProCheck by Howard Oakley (closed source, free) for the XProtect activity view; ClickGrab for the ClickFix clipboard guard; Nick (GPL) for quarantine and mail / USB scan coverage; Gargantua (GPL) for the weekly scheduled scan; MacCrab (Apache-2.0) was checked for plain `.yar` rule files and has none.


## MacPersistenceChecker

- Project: MacPersistenceChecker — https://github.com/Pinperepette/MacPersistenceChecker
- License: MIT
- Copyright (c) 2024 pinperepette
- What was used: the list of macOS persistence mechanisms and the folders where each one lives (launch agents/daemons, login items and the Background Task Management database folder, kernel and system extensions, privileged helper tools, cron tabs, periodic scripts, shell startup files, login/logout hooks, authorization plug-ins, Spotlight importers, Quick Look plug-ins, Directory Services plug-ins, Finder Sync extensions via `pluginkit`, configuration profiles) and the snapshot-and-compare ("before/after install") idea. Used in `Sources/MacCleanerKit/PersistenceInventory.swift` and `Sources/MacCleanerKit/PersistenceCollector.swift`. No code was copied; Mac Mop's implementation (parsers, signature checks, risk rules, UI) is its own.

```
MIT License

Copyright (c) 2024 pinperepette

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
