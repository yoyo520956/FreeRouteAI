#!/usr/bin/env python3
"""修 openProvidersSheet 回退：isHittable 对 SwiftUI Menu 按钮不可靠。

CI 实测：`moreActions` 报告「存在但点不到」，但 tapAny 的裸 tap() 一直能点开菜单
（testCaptureAllScreens 12 张截图就是证据）。所以我加的可命中判定反而把
能跑通的路改死了。另外重试时又点一次 moreActions，会把已展开的菜单关掉。
"""
import io, sys

p = 'FreeRouteUITests/FreeRouteUITests.swift'
s = io.open(p, encoding='utf-8').read()


def rep(name, old, new):
    global s
    n = s.count(old)
    if n != 1:
        sys.exit(f"✗ {name} 命中 {n} 处（预期 1）")
    s = s.replace(old, new)
    print(f"  ✓ {name}")


rep("tapIfPresent 不再要求 isHittable",
    '''        guard el.waitForExistence(timeout: timeout) else { return false }
        scrollToFind(el)
        guard el.isHittable else {
            print("identifier=\\(identifier) 存在但点不到，跳过本次尝试")
            return false
        }
        el.tap()
        return true''',
    '''        guard el.waitForExistence(timeout: timeout) else { return false }
        scrollToFind(el)
        // 注意：不要用 isHittable 做门槛。SwiftUI 的 Menu/工具栏按钮经常报
        // 「不可命中」，而裸 tap() 实际点得开（CI 实测：moreActions 就是这样）。
        el.tap()
        return true''')

rep("重试时不要重复点 moreActions",
    '''        for i in 0..<tries {
            tab("模型")
            if tapIfPresent("moreActions", timeout: 10) {
                sleep2(0.9)
                _ = tapIfPresent("addProvider", timeout: 6)
            }
            if app.sheets.firstMatch.waitForExistence(timeout: 5) { return }
            print("第 \\(i + 1) 次未能打开服务商面板，重试")
            sleep2(0.8)
        }''',
    '''        tab("模型")
        for i in 0..<tries {
            let add = app.descendants(matching: .any)["addProvider"].firstMatch
            if !add.exists {
                // 菜单没展开才点 moreActions：已展开时再点一次等于把菜单关掉，
                // 这正是上一轮三次重试全部失败的原因
                if !tapIfPresent("moreActions", timeout: 10) {
                    print("第 \\(i + 1) 次：moreActions 定位失败")
                }
                sleep2(1.0)
            }
            _ = tapIfPresent("addProvider", timeout: 6)
            if app.sheets.firstMatch.waitForExistence(timeout: 5) { return }
            print("第 \\(i + 1) 次：点了添加服务商但 sheet 没出现，重试")
            sleep2(0.8)
        }''')

io.open(p, 'w', encoding='utf-8').write(s)
print("已修")
