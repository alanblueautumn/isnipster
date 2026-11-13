// 阅读路线
// Swift 动作 → ID 注册表 → Carbon C 回调 → 回到 MainActor；窗口未激活时也可触发已注册热键。
// OSStatus 与 EventHotKeyRef 是 C 接口结果/句柄；错误检查和注销资源需要显式完成。
// 官方参考（Carbon 系统接口）：https://developer.apple.com/documentation/carbon

import Carbon
import Foundation
import iSnipsterCore

/// Carbon 会以 C 函数指针的方式回调热键事件。这个对象把业务闭包与 C 回调隔离，
/// 避免 Swift 6 把不可发送的 EventRef 带入 MainActor 任务而触发并发检查器崩溃。
/// `@unchecked Sendable` 是人工线程安全声明：这里的不可变 handler 只被投递、不直接并发调用。
private final class HotKeyCallbackBox: @unchecked Sendable {
    private let handler: @MainActor () -> Void

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    func invokeOnMainActor() {
        // GetApplicationEventTarget 通常就在主事件循环回调，直接处理可以让面板
        // 在热键事件这一帧开始显示；仅在异常的后台回调时再切回主队列。
        if Thread.isMainThread {
            // 这是断言当前已经处于 MainActor 的入口，不会调度到主线程；前面的执行上下文保证不可省略。
            MainActor.assumeIsolated { [self] in
                handler()
            }
        } else {
            // 把闭包排到主队列稍后执行；常用于等待当前布局/焦点切换结束，不会创建后台工作线程。
            DispatchQueue.main.async { [self] in
                handler()
            }
        }
    }
}

/// C 回调不能安全捕获 @MainActor 对象，因此使用一个很小的线程安全注册表，
/// 回调中只传递已经复制出的 UInt32 标识，不跨隔离域传递 EventRef。
/// 维护 Carbon 热键 ID 到 Swift 回调对象的线程安全映射。
private final class HotKeyCallbackRegistry: @unchecked Sendable {
    static let shared = HotKeyCallbackRegistry()

    private let lock = NSLock()
    private var callbacks: [UInt32: HotKeyCallbackBox] = [:]

    private init() {}

    func install(id: UInt32, handler: @escaping @MainActor () -> Void) -> Bool {
        // NSLock 是非递归互斥锁，不能像 Java ReentrantLock 那样由同一线程重复加锁。
        // defer 类似 finally，退出当前作用域时执行，确保各返回路径都 unlock。
        lock.lock()
        defer { lock.unlock() }

        guard callbacks[id] == nil else { return false }
        callbacks[id] = HotKeyCallbackBox(handler: handler)
        return true
    }

    func remove(id: UInt32) {
        lock.lock()
        callbacks[id] = nil
        lock.unlock()
    }

    func invoke(id: UInt32) {
        lock.lock()
        // 锁内只取出强引用，锁外才调用业务闭包；避免回调再次注册/注销热键时重入同一非递归锁。
        let callback = callbacks[id]
        lock.unlock()
        callback?.invokeOnMainActor()
    }
}

/// 文件级回调不捕获 CarbonHotKeyService，也不引用任何 MainActor 状态。
/// Swift 编译器因此只需检查纯 C 数据到 UInt32 的同步转换。
private let isnipsterHotKeyEventHandler: EventHandlerUPP = { _, event, _ in
    // C API 只能接受无捕获函数指针，不能直接传实例方法或捕获 self 的 Swift 闭包。
    guard let event else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        // C API 需要输出结构体的字节大小；&hotKeyID 提供可写地址，调用完成后再读取 Swift 值。
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }

    HotKeyCallbackRegistry.shared.invoke(id: hotKeyID.id)
    return noErr
}

/// RegisterEventHotKey 虽然来自 Carbon，但仍是 macOS 上注册全局组合键最轻量、
/// 且无需辅助功能权限的系统接口。这里把 C 回调完整封装，其他模块不接触 Carbon。
@MainActor
public final class CarbonHotKeyService: GlobalHotKeyRegistering {
    private var eventHandler: EventHandlerRef?
    private var references: [UInt32: EventHotKeyRef] = [:]

    public init() {
        installEventHandler()
    }

    /// 先登记 Swift 回调，再注册系统热键；系统注册失败时撤回回调，避免半注册状态。
    public func register(
        id: UInt32,
        descriptor: HotKeyDescriptor,
        handler: @escaping @MainActor () -> Void
    ) throws {
        guard HotKeyCallbackRegistry.shared.install(id: id, handler: handler) else {
            throw AppFailure.invalidData(AppText.format("快捷键标识重复：%d", Int(id)))
        }

        let signature: OSType = 0x534E_4950 // "SNIP"
        var reference: EventHotKeyRef?
        // Swift 可直接调用 C 函数；返回的 OSStatus 仍需手动检查，0(noErr) 表示成功。
        let status = RegisterEventHotKey(
            descriptor.keyCode,
            carbonModifiers(descriptor.modifiers),
            EventHotKeyID(signature: signature, id: id),
            GetApplicationEventTarget(),
            0,
            &reference
        )

        guard status == noErr, let reference else {
            HotKeyCallbackRegistry.shared.remove(id: id)
            throw AppFailure.operationFailed(AppText.text("全局快捷键注册失败，可能与其他应用冲突"))
        }

        references[id] = reference
    }

    /// 按 ID 同时释放系统热键句柄与 Swift 回调，二者需要对称清理。
    public func unregister(id: UInt32) {
        if let reference = references.removeValue(forKey: id) {
            UnregisterEventHotKey(reference)
        }
        HotKeyCallbackRegistry.shared.remove(id: id)
    }

    /// 遍历并注销所有系统句柄，再清空本实例的引用集合。
    public func unregisterAll() {
        for (id, reference) in references {
            UnregisterEventHotKey(reference)
            HotKeyCallbackRegistry.shared.remove(id: id)
        }
        references.removeAll(keepingCapacity: false)
    }

    /// 安装一份键盘热键事件入口；每次事件再通过 hotKeyID 分发，不是为每个动作装一个 C 入口。
    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            isnipsterHotKeyEventHandler,
            1,
            &eventType,
            nil,
            &eventHandler
        )
    }

    /// 将业务层修饰键 Set 合并成 Carbon 位掩码；按位或表示同时启用多个独立标志。
    private func carbonModifiers(_ modifiers: Set<HotKeyModifier>) -> UInt32 {
        // reduce(into:) 类似 Java stream reduce，但直接修改累加器，适合组装位掩码。
        modifiers.reduce(into: UInt32(0)) { value, modifier in
            switch modifier {
            case .command: value |= UInt32(cmdKey)
            case .option: value |= UInt32(optionKey)
            case .control: value |= UInt32(controlKey)
            case .shift: value |= UInt32(shiftKey)
            }
        }
    }
}
