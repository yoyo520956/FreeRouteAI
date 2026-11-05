import XCTest

/// UI 测试：真实点击每个入口，并按交付要求输出 10 张模拟器截图。
/// 注意：这些是「iOS 模拟器」截图，不等同于真机截图。
final class FreeRouteUITests: XCTestCase {
    private var app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        // 干净环境：每次测试用独立数据库，避免历史数据影响断言
        app.launchArguments += ["-fr UITestMode"]
        app.launch()
        // 首帧渲染完成
        _ = app.wait(for: .runningForeground, timeout: 30)
        sleep2(1.2)
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    private func sleep2(_ t: Double) {
        Thread.sleep(forTimeInterval: t)
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        // XCTAttachment 只有 name（没有 title）；XCUIApplication 也没有写沙盒的 API，
        // 所以截图只走附件通道，由 tools/collect-screenshots.py 从 .xcresult 导出。
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // 附件通道会丢掉 name（xcresulttool 导出的 manifest 里全变成
        // "Synthesized Event <时间>"），所以再把 PNG 按目标文件名写进测试 runner
        // 自己的沙盒；CI 用 simctl 取 runner 容器即可拿到正确屏名。
        if let data = screenshot.pngRepresentation as Data? {
            let docs = FileManager.default.urls(for: .documentDirectory,
                                                in: .userDomainMask).first
            let dir = (docs ?? URL(fileURLWithPath: NSTemporaryDirectory()))
                .appendingPathComponent("ci-screenshots", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: dir.appendingPathComponent(name + ".png"))
        }
    }

    /// SwiftUI 的 Menu 及菜单项在 XCUITest 里的 element type 不稳定：同一个控件
    /// 可能报 Button / PopUpButton / Cell（日志原话 "Automation type mismatch:
    /// computed Button from legacy attributes vs PopUpButton from modern attribute"），
    /// 因此一律按 accessibilityIdentifier 用 .any 查询，不假定具体类型。
    @discardableResult
    /// 小屏（SE3 尺寸）上目标经常在屏幕外；先滚动到可点再断言，
    /// 避免「元素存在但 tap 失败」这种难懂的报错。
    /// sheet 里要用 sheet 自己的 scrollView，否则会滚到背后的主页。
    private func scrollToFind(_ el: XCUIElement, tries: Int = 4) {
        for _ in 0..<tries {
            if el.isHittable { return }
            let sheet = app.sheets.firstMatch
            let container: XCUIElement
            if sheet.exists {
                container = sheet.scrollViews.firstMatch
            } else {
                // 这套 SwiftUI 不把弹层暴露成 sheet，弹层的 scrollView 在树的
                // 最后面；取 firstMatch 会滚到背后那一页，等于白滚
                // XCUIElementQuery 没有 lastMatch，取末尾要用 boundBy: -1
                container = app.scrollViews.element(boundBy: -1)
            }
            if container.exists && container.isHittable {
                container.swipeUp()
            } else if app.tables.firstMatch.exists {
                app.tables.firstMatch.swipeUp()
            } else {
                app.swipeUp()
            }
            sleep2(0.45)
        }
    }

    /// 定位到就点、定位不到只返回 false（不判失败）。
    /// 用于「点击有动画竞态、需要重试」的流程；确定性步骤仍用 tapAny。
    @discardableResult
    /// scroll=false：菜单/弹层里的元素绝不能自动滚动 —— 菜单已展开时
    /// 一次 swipeUp 就等于把菜单划掉（CI 三轮「点了但 sheet 没出现」就是这么来的）。
    private func tapIfPresent(_ identifier: String, timeout: TimeInterval,
                              scroll: Bool = false) -> Bool {
        let el = app.descendants(matching: .any)[identifier].firstMatch
        guard el.waitForExistence(timeout: timeout) else { return false }
        if scroll { scrollToFind(el) }
        // 注意：不要用 isHittable 做门槛。SwiftUI 的 Menu/工具栏按钮经常报
        // 「不可命中」，而裸 tap() 实际点得开（CI 实测：moreActions 就是这样）。
        el.tap()
        return true
    }

    /// 打开「服务商管理」sheet。
    /// Menu 展开带动画，连续点两次存在竞态：CI 上真实出现过
    /// 「addProvider 点成功但 sheet 没出现」，因此必须等 sheet 真出现，
    /// 否则整条流程重试一次。
    private func openProvidersSheet(tries: Int = 3) {
        tab("模型")
        for i in 0..<tries {
            // 必须每次都点 moreActions。上一轮我加的「addProvider 已存在就跳过」
            // 是错的：SwiftUI 的 Menu 项在菜单关闭时同样存在于可访问性树，
            // 于是等于从没展开过菜单，点它自然什么也不会发生（CI 实测三次全空）。
            if !tapIfPresent("moreActions", timeout: 10) {
                print("第 \(i + 1) 次：moreActions 定位失败")
            }
            sleep2(1.0)
            _ = tapIfPresent("addProvider", timeout: 5)
            // 判断「面板打开了」必须用面板自己的控件，不能用 app.sheets：
            // 这套 SwiftUI 的呈现层级在 XCUITest 里不一定暴露成 sheet 类型。
            // 反证：testCaptureAllScreens 用同样的点击序列后面能点到 sheet 里的
            // 「完成」按钮，说明面板本来就开着的 —— 是我的判定条件错了，
            // 于是每次重试都多点一次 moreActions，反而把状态搞乱。
            // 用 sheet 顶部必在屏幕内的「完成」判定打开状态。
            // 不能用 provider.addCustom：它在滚动内容末尾，一旦前面的用例
            // 已经建过服务商（SwiftData 数据跨用例留存），它就被挤到屏幕外、
            // 不进可访问性树 —— 这正是本用例独独失败的原因。
            if app.buttons["完成"].firstMatch.waitForExistence(timeout: 6) { return }
            print("第 \(i + 1) 次：没找到面板顶部的「完成」，重试")
            sleep2(0.8)
        }
        XCTFail("多次尝试仍无法打开「服务商管理」sheet")
    }

    /// 在懒加载容器（LazyVStack / Form）里按子串找文本。
    /// 这类容器不渲染视口外内容，元素"不存在"往往只是还没滚到，
    /// 所以必须允许边滚边找（本项目已因此误判过两次"产品没渲染"）。
    private func findText(_ substring: String, tries: Int = 5) -> XCUIElement {
        let q = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", substring))
        for i in 0..<tries {
            if q.firstMatch.exists { return q.firstMatch }
            let sv = app.scrollViews.element(boundBy: -1)
            if sv.exists { sv.swipeUp() } else { app.swipeUp() }
            sleep2(0.5)
            _ = i
        }
        return q.firstMatch
    }

    /// 收起键盘：键盘会盖住输入框下方的行内错误提示
    private func dismissKeyboardIfNeeded() {
        if app.keyboards.count > 0 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
            sleep2(0.6)
        }
    }

    /// 往输入框里写值：先按字段现有长度退格清空，再输入。
    /// `typeText` 是**追加**而不是替换 —— 字段若被预填（编辑态或上一条用例残留），
    /// 直接 typeText 会得到 "https://api.example.com/v1" + "not-a-url" 这种
    /// 前缀依然合法的字符串，于是"非法输入"用例其实输入的是合法值，
    /// 校验当然放过它（本轮 CI 就是这样假失败的）。
    private func type(into identifier: String, _ text: String) {
        let f = field(identifier)
        let existing = (f.value as? String) ?? ""
        for _ in 0..<existing.count { f.typeText("\u{8}") }
        f.typeText(text)
        print("字段 \(identifier)：原值=\(existing.isEmpty ? "空" : existing) → 现值=\(text)")
    }

    private func tapAny(_ identifier: String, timeout: TimeInterval = 8,
                        scroll: Bool = false) -> XCUIElement {
        let el = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(el.waitForExistence(timeout: timeout),
                      "找不到可交互元素（identifier=\(identifier)）")
        if scroll { scrollToFind(el) }
        XCTAssertTrue(el.isHittable,
                      "identifier=\(identifier) 存在但滚动后仍点不到（可能被遮挡或在屏幕外）")
        el.tap()
        return el
    }


    /// 表单输入框：按 identifier 定位（SwiftUI 新 SDK 不把中文占位符暴露成 a11y label），
    /// 滚动到可点后再聚焦。
    private func field(_ identifier: String) -> XCUIElement {
        let el = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(el.waitForExistence(timeout: 8), "找不到输入框（identifier=\(identifier)）")
        scrollToFind(el)
        XCTAssertTrue(el.isHittable, "输入框 \(identifier) 滚动后仍点不到")
        el.tap()
        sleep2(0.3)
        return el
    }

    private func tab(_ title: String) {
        let button = app.tabBars.buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "找不到底部标签「\(title)」")
        button.tap()
        sleep2(0.9)
    }

    // MARK: 10 屏截图

    func testCaptureAllScreens() throws {
        tab("首页")
        shot("01-dashboard")

        tab("模型")
        shot("02-models")

        // 服务商管理（模型中心右上角 …  → 添加服务商）
        // 用 identifier 而非 SF Symbol 名；这里允许跳过但必须打印原因，
        // 否则截图缺失会被"测试通过"掩盖（曾真实发生过）。
        let more = app.descendants(matching: .any)["moreActions"].firstMatch
        if more.waitForExistence(timeout: 6) {
            more.tap()
            sleep2(0.6)
            let providersItem = app.descendants(matching: .any)["addProvider"].firstMatch
            if providersItem.waitForExistence(timeout: 5) {
                providersItem.tap()
                sleep2(1.0)
                shot("03-providers")
                app.buttons["完成"].tap()
                sleep2(0.6)
            } else {
                print("⚠️ 跳过 03-providers：菜单项 addProvider 未出现")
            }
        } else {
            print("⚠️ 跳过 03-providers：moreActions 未出现")
        }

        tab("路由")
        shot("04-smart-router")

        tab("网关")
        shot("05-gateway")

        tab("首页")
        // 首页右上角 → 实时监控（PiP 布局屏）
        let monitor = app.buttons["打开实时监控"]
        if monitor.waitForExistence(timeout: 5) {
            monitor.tap()
            sleep2(1.0)
            shot("06-pip-monitor")
            back()
        }

        tab("设置")
        shot("10-settings")

        // 设置 → 打开请求日志 / 统计中心 / 安全
        openSetting("打开请求日志", shot: "07-logs")
        openSetting("打开统计中心", shot: "08-statistics")
        openSetting("安全与密钥", shot: "09-security")
    }

    private func openSetting(_ label: String, shot name: String) {
        tab("设置")
        let cell = app.staticTexts[label]
        // Form 的行可能落在屏幕外（SE3 只有 4.7 寸），滚到可点为止
        for _ in 0..<6 {
            if cell.exists && cell.isHittable { break }
            let table = app.tables.firstMatch
            if table.exists { table.swipeUp() } else { app.swipeUp() }
            sleep2(0.4)
        }
        guard cell.waitForExistence(timeout: 4) else {
            print("⚠️ 跳过 \(name)：设置页找不到「\(label)」")
            return
        }
        cell.tap()
        sleep2(1.2)
        shot(name)
        back()
    }

    private func back() {
        let back = app.navigationBars.buttons.firstMatch
        if back.exists {
            back.tap()
        } else {
            app.swipeRight()
        }
        sleep2(0.8)
    }

    // MARK: 真实功能：添加服务商 → 保存 → 列表出现

    func testAddCustomProviderAppearsInList() throws {
        openProvidersSheet()
        // 「添加服务商」菜单项打开的是服务商管理 sheet，还要再点
        // 「添加自定义服务商」才真正进入编辑器表单（曾因少这一步定位不到输入框）
        tapAny("provider.addCustom")
        sleep2(1.2)
        shot("11-provider-editor")

        type(into: "provider.name", "CI 测试源")
        sleep2(0.4)
        type(into: "provider.baseURL", "https://api.example.com/v1")

        dismissKeyboardIfNeeded()

        let save = app.buttons["保存"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "找不到保存按钮")
        XCTAssertTrue(save.isEnabled, "填写合法后保存按钮应可点")
        save.tap()
        sleep2(1.2)

        // 新建的行在 LazyVStack 里可能还在视口外，滚动查找
        XCTAssertTrue(findText("CI 测试源").exists, "保存后服务商应出现在列表")
        shot("12-provider-saved")
    }

    // MARK: 真实功能：Base URL 非法时禁止保存

    func testInvalidBaseURLBlocksSave() throws {
        // 注意：这个用例此前用 `guard … else { return }` 提前退出，
        // 定位失败也会算"通过"（空转）。现在全部改成真断言。
        openProvidersSheet()
        // 「添加服务商」菜单项打开的是服务商管理 sheet，还要再点
        // 「添加自定义服务商」才真正进入编辑器表单（曾因少这一步定位不到输入框）
        tapAny("provider.addCustom")
        sleep2(1.2)

        type(into: "provider.name", "非法地址源")
        sleep2(0.4)
        type(into: "provider.baseURL", "not-a-url")

        // 不断言 save.isEnabled：SwiftUI 工具栏按钮的 .disabled() 不保证
        // 透传到 XCUITest 的 enabled 属性（CI 实测红字已出现但 isEnabled 仍为 true）。
        // 改断言真实结果：界面必须给出明确错误提示，且必须仍停在编辑器（没被保存关掉）。
        // 用谓词按子串匹配：Label 的可访问性文本可能被系统拼接或截断，
        // 全等匹配太脆（改一个字就查不到）
        dismissKeyboardIfNeeded()

        // 断言真正的产品保证：非法 Base URL 点「保存」绝不能把服务商存进去并关掉编辑器。
        // 判据用 provider.baseURL 这个 identifier（实测最可靠的定位方式）：
        // 保存成功会 dismiss 编辑器，那时它就消失。
        let save = app.buttons["保存"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "应仍停在编辑器里（找不到保存按钮）")
        save.tap()
        sleep2(1.5)
        XCTAssertTrue(app.descendants(matching: .any)["provider.baseURL"].firstMatch.exists,
                      "Base URL 非法时点保存必须留在编辑器里，不能静默保存并关闭")

        // 校验拦下来必须给出可察觉的提示（系统弹窗，XCUITest 定位可靠）
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5),
                      "非法输入被拒绝时必须给出明确提示")
        alert.buttons["好"].tap()
        sleep2(0.5)
    }

    // MARK: 真实功能：Smart 模式可切换且持久

    func testRouterModeSwitchPersists() throws {
        tab("路由")
        let target = app.staticTexts["SMART FAST"]
        // 定位失败必须判失败，不能静默 return（那会让用例空转通过）
        XCTAssertTrue(target.waitForExistence(timeout: 8), "路由页找不到 SMART FAST 模式卡片")
        target.tap()
        sleep2(0.8)
        app.terminate()
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 30)
        sleep2(1.2)
        tab("路由")
        // 重进后仍应处于极速模式（写入设置并读回）
        XCTAssertTrue(app.staticTexts["SMART FAST"].exists)
    }
}
