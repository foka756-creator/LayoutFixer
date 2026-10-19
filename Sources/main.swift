import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Настройки

enum Prefs {
    static let d = UserDefaults.standard
    static var enabled: Bool {
        get { d.object(forKey: "enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "enabled") }
    }
    static var switchLayout: Bool {
        get { d.object(forKey: "switchLayout") as? Bool ?? true }
        set { d.set(newValue, forKey: "switchLayout") }
    }
    /// Слова, замену которых пользователь откатил: больше их не трогаем.
    static var ignored: Set<String> {
        get { Set(d.stringArray(forKey: "ignored") ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: "ignored") }
    }
    static var fixed: Int {
        get { d.integer(forKey: "fixed") }
        set { d.set(newValue, forKey: "fixed") }
    }
}

// MARK: - Словарь

/// Системная проверка орфографии. Если словаря нет, ядро ничего не исправляет (`hasDictionary`).
struct SpellChecker: WordChecker {
    func hasDictionary(_ lang: Lang) -> Bool {
        let code = lang == .ru ? "ru" : "en"
        return NSSpellChecker.shared.availableLanguages.contains { $0.hasPrefix(code) }
    }

    func isValid(_ word: String, _ lang: Lang) -> Bool {
        let code = lang == .ru ? "ru" : "en"
        let checker = NSSpellChecker.shared
        let r = checker.checkSpelling(of: word, startingAt: 0, language: code,
                                      wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return r.location == NSNotFound
    }
}

// MARK: - Раскладки

enum Layouts {
    /// Выбирает клавиатурную раскладку нужного языка ("ru" / "en").
    @discardableResult
    static func select(_ lang: Lang) -> Bool {
        let code = lang == .ru ? "ru" : "en"
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return false }
        for src in list {
            guard let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages) else { continue }
            let langs = Unmanaged<CFArray>.fromOpaque(p).takeUnretainedValue() as? [String] ?? []
            if langs.first == code { return TISSelectInputSource(src) == noErr }
        }
        return false
    }
}

// MARK: - Ввод и замена

enum Typer {
    /// Метка наших событий: слушатель их пропускает.
    static let marker: Int64 = 0x4C46_4958

    private static func post(_ key: CGKeyCode, down: Bool, text: String? = nil) {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { return }
        e.setIntegerValueField(.eventSourceUserData, value: marker)
        if let text {
            let u = Array(text.utf16)
            e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
        }
        e.post(tap: .cghidEventTap)
    }

    static func backspace(_ n: Int) {
        for _ in 0..<n {
            post(CGKeyCode(kVK_Delete), down: true)
            post(CGKeyCode(kVK_Delete), down: false)
        }
    }

    static func type(_ s: String) {
        // Юникод-строка в одном событии ограничена ~20 единицами UTF-16.
        var chunk = ""
        for ch in s {
            if chunk.utf16.count + String(ch).utf16.count > 16 { flush(&chunk) }
            chunk.append(ch)
        }
        flush(&chunk)
    }

    private static func flush(_ chunk: inout String) {
        guard !chunk.isEmpty else { return }
        post(0, down: true, text: chunk)
        post(0, down: false, text: chunk)
        chunk = ""
    }
}

// MARK: - Всплывающее предложение после отката

/// Небольшая панель у курсора ввода: «Добавить «слово» в исключения». Не забирает фокус,
/// закрывается сама через несколько секунд или при следующем нажатии клавиши.
final class ExceptionPopup: NSObject {
    private var panel: NSPanel?
    private var timer: Timer?
    private var onAdd: (() -> Void)?

    func show(word: String, onAdd: @escaping () -> Void) {
        hide()
        self.onAdd = onAdd
        let button = NSButton(title: "Добавить «\(word)» в исключения", target: self, action: #selector(add))
        button.bezelStyle = .rounded
        button.sizeToFit()
        let size = NSSize(width: button.frame.width + 20, height: button.frame.height + 16)
        button.frame.origin = NSPoint(x: 10, y: 8)

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .menu
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 8
        bg.addSubview(button)
        p.contentView = bg
        p.setFrameOrigin(origin(for: size))
        p.orderFrontRegardless()
        panel = p
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in self?.hide() }
    }

    /// Клик по самой панели не должен её закрывать.
    func contains(_ point: NSPoint) -> Bool { panel?.frame.contains(point) ?? false }

    func hide() {
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil); panel = nil
        onAdd = nil
    }

    @objc private func add() {
        let done = onAdd
        hide()
        done?()
    }

    /// Под курсором ввода (через Accessibility); если не получилось — рядом с указателем мыши.
    private func origin(for size: NSSize) -> NSPoint {
        var anchor = NSEvent.mouseLocation
        var below: CGFloat = 24
        if let r = caretRect() { anchor = NSPoint(x: r.minX, y: r.minY); below = 6 }
        var o = NSPoint(x: anchor.x, y: anchor.y - size.height - below)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main {
            o.x = min(max(o.x, screen.visibleFrame.minX), screen.visibleFrame.maxX - size.width)
            o.y = min(max(o.y, screen.visibleFrame.minY), screen.visibleFrame.maxY - size.height)
        }
        return o
    }

    private func caretRect() -> NSRect? {
        let sys = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused else { return nil }
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el as! AXUIElement, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let r = range else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el as! AXUIElement, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         r, &bounds) == .success, let b = bounds else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(b as! AXValue, .cgRect, &rect), rect != .zero else { return nil }
        // AX отдаёт координаты от верхнего левого угла главного экрана, AppKit — от нижнего левого.
        let h = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: h - rect.maxY, width: rect.width, height: rect.height)
    }
}

// MARK: - Слушатель клавиатуры

final class KeyWatcher {
    private var tap: CFMachPort?
    private var buffer = WordBuffer()
    private var generation = 0
    private var history = FixHistory()
    private let checker = SpellChecker()
    private let popup = ExceptionPopup()
    var onFix: (() -> Void)?

    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue
                               | 1 << CGEventType.leftMouseDown.rawValue
                               | 1 << CGEventType.rightMouseDown.rawValue)
        let cb: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<KeyWatcher>.fromOpaque(refcon!).takeUnretainedValue()
            me.handle(type, event)
            return Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .listenOnly, eventsOfInterest: mask, callback: cb,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            buffer.reset(); history.clear() // часть нажатий могла быть пропущена
            return
        }
        guard Prefs.enabled else { buffer.reset(); return }
        if event.getIntegerValueField(.eventSourceUserData) == Typer.marker { return }
        if type != .keyDown, popup.contains(NSEvent.mouseLocation) { return }
        generation += 1
        popup.hide()
        if type != .keyDown { buffer.reset(); history.clear(); return }

        let flags = event.flags
        let hasModifier = !flags.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate])

        // Backspace сразу после замены откатывает её (пробел он уже удалил сам).
        // Option/Cmd+Backspace удаляют больше, чем пробел, поэтому откатом не считаются.
        if !hasModifier, Int(event.getIntegerValueField(.keyboardEventKeycode)) == kVK_Delete,
           let fix = history.takeForUndo() {
            undo(fix)
            return
        }
        history.clear()
        if hasModifier { buffer.reset(); return }

        switch Int(event.getIntegerValueField(.keyboardEventKeycode)) {
        case kVK_Delete:
            buffer.backspace()
        case kVK_Space:
            let word = buffer.text
            buffer.reset()
            fixIfNeeded(word)
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Escape,
             kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete:
            buffer.reset()
        default:
            var len = 0
            var chars = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &len, unicodeString: &chars)
            let s = String(utf16CodeUnits: chars, count: len)
            if s.isEmpty || s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { buffer.reset() }
            else { buffer.append(s) }
        }
    }

    private func undo(_ fix: Correction) {
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self, self.generation == gen else { return }
            Typer.backspace(fix.replacement.count)
            Typer.type(fix.original)
            if Prefs.switchLayout { Layouts.select(fix.target.other) }
            Prefs.fixed = max(0, Prefs.fixed - 1)
            self.buffer.reset()
            self.onFix?()
            // Слово в исключения попадает только по явному согласию.
            self.popup.show(word: fix.original) { [weak self] in
                Prefs.ignored.insert(LayoutFix.ignoreKey(fix.original))
                self?.onFix?()
            }
        }
    }

    private func fixIfNeeded(_ word: String) {
        guard let fix = LayoutFix.correction(for: word, checker: checker, ignore: Prefs.ignored) else { return }
        let gen = generation
        // Даём исходному пробелу дойти до приложения, затем заменяем слово.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self, self.generation == gen else { return } // пользователь уже печатает дальше
            Typer.backspace(word.count + 1)
            Typer.type(fix.replacement + " ")
            if Prefs.switchLayout { Layouts.select(fix.target) }
            Prefs.fixed += 1
            self.history.record(fix)
            self.onFix?()
        }
    }
}

// MARK: - Меню в строке состояния

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let watcher = KeyWatcher()
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        watcher.onFix = { [weak self] in self?.rebuildMenu() }
        item.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "LayoutFixer")
        rebuildMenu()
        startWhenAllowed()
    }

    /// Разрешения «Универсальный доступ» и «Мониторинг ввода» нужны для перехвата и замены текста.
    private func startWhenAllowed() {
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts), watcher.start() { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self, AXIsProcessTrusted(), self.watcher.start() else { return }
            t.invalidate()
            self.permissionTimer = nil
            self.rebuildMenu()
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let m = NSMenu()
        if permissionTimer != nil {
            m.addItem(action("Нужны разрешения: Универсальный доступ и Мониторинг ввода…", #selector(openAccessibility)))
            m.addItem(.separator())
        }
        m.addItem(toggle("Исправлять раскладку", Prefs.enabled, #selector(toggleEnabled)))
        m.addItem(toggle("Переключать раскладку после замены", Prefs.switchLayout, #selector(toggleSwitch)))
        m.addItem(toggle("Запускать при входе", SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))
        m.addItem(exceptionsItem())
        m.addItem(.separator())
        let count = NSMenuItem(title: "Исправлено слов: \(Prefs.fixed)", action: nil, keyEquivalent: "")
        count.isEnabled = false
        m.addItem(count)
        m.addItem(.separator())
        m.addItem(action("Выйти", #selector(quit), key: "q"))
        item.menu = m
        item.button?.alphaValue = Prefs.enabled ? 1 : 0.4
    }

    /// Подменю: клик по слову возвращает его в обработку, «Очистить» убирает все.
    private func exceptionsItem() -> NSMenuItem {
        let words = Prefs.ignored.sorted()
        let item = NSMenuItem(title: "Исключения (\(words.count))", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if words.isEmpty {
            let empty = NSMenuItem(title: "Список пуст", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sub.addItem(empty)
        } else {
            let hint = NSMenuItem(title: "Клик по слову — снова исправлять его", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            sub.addItem(hint)
            sub.addItem(.separator())
            for w in words {
                let i = action(w, #selector(removeException(_:)))
                i.representedObject = w
                sub.addItem(i)
            }
            sub.addItem(.separator())
            sub.addItem(action("Очистить список", #selector(clearExceptions)))
        }
        item.submenu = sub
        return item
    }

    private func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    private func toggle(_ title: String, _ on: Bool, _ sel: Selector) -> NSMenuItem {
        let i = action(title, sel)
        i.state = on ? .on : .off
        return i
    }

    @objc private func removeException(_ sender: NSMenuItem) {
        guard let w = sender.representedObject as? String else { return }
        Prefs.ignored.remove(w)
        rebuildMenu()
    }
    @objc private func clearExceptions() { Prefs.ignored = []; rebuildMenu() }
    @objc private func toggleEnabled() { Prefs.enabled.toggle(); rebuildMenu() }
    @objc private func toggleSwitch() { Prefs.switchLayout.toggle(); rebuildMenu() }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSSound.beep() }
        rebuildMenu()
    }
    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
