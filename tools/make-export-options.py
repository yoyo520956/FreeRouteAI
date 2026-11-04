#!/usr/bin/env python3
"""按签名模式生成 ExportOptions.plist"""
import sys

mode = (sys.argv[1] if len(sys.argv) > 1 else "none").strip()

signed = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>method</key><string>development</string>
\t<key>destination</key><string>export</string>
\t<key>signingStyle</key><string>automatic</string>
\t<key>compileBitcode</key><false/>
\t<key>stripSwiftSymbols</key><true/>
\t<key>thinning</key><string>&lt;none&gt;</string>
</dict>
</plist>
"""

unsigned = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>method</key><string>development</string>
\t<key>destination</key><string>export</string>
\t<key>signingStyle</key><string>manual</string>
\t<key>compileBitcode</key><false/>
\t<key>codeSignOnErrors</key><false/>
\t<key>thinning</key><string>&lt;none&gt;</string>
</dict>
</plist>
"""

with open("ExportOptions.plist", "w", encoding="utf-8") as f:
    f.write(signed if mode in ("manual", "automatic") else unsigned)
print(f"ExportOptions.plist 已生成（模式：{mode}）")
