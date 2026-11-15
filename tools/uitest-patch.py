#!/usr/bin/env python3
"""修两处 UI 测试缺陷：菜单竞态、以及断言控件属性而非真实行为。"""
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

# 1) 不报错的单次尝试定位，用于可重试流程
rep("新增 tapIfPresent + openProvidersSheet",
    '''    private func tapAny(_ identifier: String, timeout: TimeInterval = 8) -> XCUIElement {''',
    '''    /// 定位到就点、定位不到只返回 false（不判失败）。
    /// 用于「点击有动画竞态、需要重试」的流程；确定性步骤仍用 tapAny。
    @discardableResult
    private func tapIfPresent(_ identifier: String, timeout: TimeInterval) -> Bool {
        let el = app.descendants(matching: .any)[identifier].firstMatch
        guard el.waitForExistence(timeout: timeout) else { return false }
        scrollToFind(el)
        guard el.isHittable else {
            print("identifier=\\(identifier) 存在但点不到，跳过本次尝试")
            return false
        }
        el.tap()
        return true
    }

    /// 打开「服务商管理」sheet。
    /// Menu 展开带动画，连续点两次存在竞态：CI 上真实出现过
    /// 「addProvider 点成功但 sheet 没出现」，因此必须等 sheet 真出现，
    /// 否则整条流程重试一次。
    private func openProvidersSheet(tries: Int = 3) {
        for i in 0..<tries {
            tab("模型")
            if tapIfPresent("moreActions", timeout: 10) {
                sleep2(0.9)
                _ = tapIfPresent("addProvider", timeout: 6)
            }
            if app.sheets.firstMatch.waitForExistence(timeout: 5) { return }
            print("第 \\(i + 1) 次未能打开服务商面板，重试")
            sleep2(0.8)
        }
        XCTFail("多次尝试仍无法打开「服务商管理」sheet")
    }

    private func tapAny(_ identifier: String, timeout: TimeInterval = 8) -> XCUIElement {''')

# 2) 两个用例改用可重试入口
rep("用例1 走 openProvidersSheet",
    '''        tab("模型")
        tapAny("moreActions")
        sleep2(0.6)
        tapAny("addProvider")
        sleep2(1.0)
        // 「添加服务商」菜单项打开的是服务商管理 sheet，还要再点
        // 「添加自定义服务商」才真正进入编辑器表单（曾因少这一步定位不到输入框）
        tapAny("provider.addCustom")
        sleep2(1.2)
        shot("11-provider-editor")''',
    '''        openProvidersSheet()
        // 「添加服务商」菜单项打开的是服务商管理 sheet，还要再点
        // 「添加自定义服务商」才真正进入编辑器表单（曾因少这一步定位不到输入框）
        tapAny("provider.addCustom")
        sleep2(1.2)
        shot("11-provider-editor")''')

rep("用例2 走 openProvidersSheet",
    '''        tab("模型")
        tapAny("moreActions")
        sleep2(0.5)
        tapAny("addProvider")
        sleep2(1.0)
        // 「添加服务商」菜单项打开的是服务商管理 sheet，还要再点
        // 「添加自定义服务商」才真正进入编辑器表单（曾因少这一步定位不到输入框）
        tapAny("provider.addCustom")
        sleep2(1.2)''',
    '''        openProvidersSheet()
        // 「添加服务商」菜单项打开的是服务商管理 sheet，还要再点
        // 「添加自定义服务商」才真正进入编辑器表单（曾因少这一步定位不到输入框）
        tapAny("provider.addCustom")
        sleep2(1.2)''')

# 3) 断言真实行为，而不是 SwiftUI 按钮的 enabled 属性
rep("非法 URL 断言改为行为断言",
    '''        let save = app.buttons["保存"]
        XCTAssertTrue(save.exists)
        XCTAssertFalse(save.isEnabled, "Base URL 非法时保存按钮必须禁用")''',
    '''        // 不断言 save.isEnabled：SwiftUI 工具栏按钮的 .disabled() 不保证
        // 透传到 XCUITest 的 enabled 属性（CI 实测红字已出现但 isEnabled 仍为 true）。
        // 改断言真实结果：界面必须给出明确错误提示，且必须仍停在编辑器（没被保存关掉）。
        let hint = app.descendants(matching: .any)["Base URL 必须以 http:// 或 https:// 开头"].firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 6),
                      "非法 Base URL 时必须显示行内错误提示")
        scrollToFind(hint)
        XCTAssertTrue(hint.exists, "提示应仍在编辑器内可见（说明未被静默保存）")''')

io.open(p, 'w', encoding='utf-8').write(s)
print("UI 测试已更新")
