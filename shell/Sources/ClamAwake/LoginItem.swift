// ClamAwake 菜单栏壳 — 登录项（SMAppService，产品形态的开机自启）
// GPL-3.0，见仓库 LICENSE
//
// SMAppService.mainApp：把 app 自身注册为登录项（macOS 13+），注册/注销即时生效，
// 用户可在 系统设置 → 通用 → 登录项 里看到并管理。不用旧的 SMLoginItemSetEnabled / LSSharedFileList。

import Foundation
import ServiceManagement

final class LoginItemManager: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var needsApproval: Bool
    @Published private(set) var lastError: String?

    private let service = SMAppService.mainApp

    init() {
        let status = service.status
        isEnabled = (status == .enabled)
        needsApproval = (status == .requiresApproval)
    }

    func refresh() {
        let status = service.status
        isEnabled = (status == .enabled)
        needsApproval = (status == .requiresApproval)
        lastError = nil
    }

    func enable() {
        do {
            try service.register()
        } catch {
            lastError = "注册登录项失败：\(error.localizedDescription)"
        }
        refresh()
    }

    func disable() {
        do {
            try service.unregister()
        } catch {
            lastError = "取消登录项失败：\(error.localizedDescription)"
        }
        refresh()
    }

    /// 系统设置 → 通用 → 登录项（注册后处于 requiresApproval 时引导用户去批准）
    static let loginItemsSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
}
