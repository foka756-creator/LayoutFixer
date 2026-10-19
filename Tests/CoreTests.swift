import Foundation

var failed = 0
func check(_ ok: Bool, _ name: String) {
    if ok { print("ok   \(name)") } else { print("FAIL \(name)"); failed += 1 }
}

/// Фейковый словарь: только перечисленные слова считаются верными.
struct FakeChecker: WordChecker {
    var en: Set<String> = ["hello", "world", "git"]
    var ru: Set<String> = ["привет", "люблю", "мир", "вы", "Привет"]
    func isValid(_ word: String, _ lang: Lang) -> Bool {
        (lang == .en ? en : ru).contains(word)
    }
}
let fc = FakeChecker()

// Конвертация символов по физическим клавишам
check(LayoutFix.convert("ghbdtn", to: .ru) == "привет", "en->ru lower")
check(LayoutFix.convert("Ghbdtn", to: .ru) == "Привет", "en->ru keeps capital")
check(LayoutFix.convert("руддщ", to: .en) == "hello", "ru->en")
check(LayoutFix.convert("k.,k.", to: .ru) == "люблю", "punct keys are letters")
check(LayoutFix.convert("ghbdtn/", to: .ru) == "привет.", "slash is dot")
check(LayoutFix.convert("1 2", to: .ru) == "1 2", "digits and space unchanged")

// Исправление: слово набрано в латинской раскладке вместо русской
check(LayoutFix.correction(for: "ghbdtn", checker: fc)
      == Correction(original: "ghbdtn", replacement: "привет", target: .ru), "fix en->ru")
check(LayoutFix.correction(for: "Ghbdtn", checker: fc)?.replacement == "Привет", "fix keeps capital")
check(LayoutFix.correction(for: "k.,k.", checker: fc)?.replacement == "люблю", "fix word ending in punct key")
check(LayoutFix.correction(for: "ds", checker: fc)?.replacement == "вы", "fix two letters")
// И наоборот
check(LayoutFix.correction(for: "руддщ", checker: fc)
      == Correction(original: "руддщ", replacement: "hello", target: .en), "fix ru->en")
// Хвостовая пунктуация
check(LayoutFix.correction(for: "ghbdtn/", checker: fc)?.replacement == "привет.", "trailing slash -> dot")
// Реальный словарь видит в "k.,k" слово "k": знаки внутри слова делают его неверным
struct LenientChecker: WordChecker {
    func isValid(_ word: String, _ lang: Lang) -> Bool { lang == .en ? true : word == "люблю" }
}
check(LayoutFix.correction(for: "k.,k.", checker: LenientChecker())?.replacement == "люблю", "punct inside word is not valid en")
// Верное слово не трогаем
check(LayoutFix.correction(for: "hello", checker: fc) == nil, "valid en untouched")
check(LayoutFix.correction(for: "привет", checker: fc) == nil, "valid ru untouched")
check(LayoutFix.correction(for: "hello,", checker: fc) == nil, "valid en with comma untouched")
// Неизвестное слово, у которого и конвертация не слово
check(LayoutFix.correction(for: "xyzzy", checker: fc) == nil, "gibberish untouched")
// Слишком короткое
check(LayoutFix.correction(for: "d", checker: fc) == nil, "single letter untouched")
// Смешанные алфавиты и цифры
check(LayoutFix.correction(for: "ghрdtn", checker: fc) == nil, "mixed alphabets untouched")
check(LayoutFix.correction(for: "123", checker: fc) == nil, "digits untouched")
check(LayoutFix.correction(for: "", checker: fc) == nil, "empty untouched")

// Буфер слова
var buf = WordBuffer()
buf.append("g"); buf.append("h"); buf.append("b")
check(buf.text == "ghb", "buffer appends")
buf.backspace()
check(buf.text == "gh", "buffer backspace")
buf.reset()
check(buf.text.isEmpty, "buffer reset")
buf.backspace()
check(buf.text.isEmpty, "backspace on empty is safe")

// Список исключений: отменённое слово больше не исправляем
check(LayoutFix.correction(for: "ghbdtn", checker: fc, ignore: [LayoutFix.ignoreKey("ghbdtn")]) == nil, "ignored word untouched")
check(LayoutFix.correction(for: "ghbdtn", checker: fc, ignore: ["other"])?.replacement == "привет", "other ignore does not block")

// История замен: откат возможен один раз и только сразу после замены
var hist = FixHistory()
check(hist.takeForUndo() == nil, "no undo without fix")
let c1 = Correction(original: "ghbdtn", replacement: "привет", target: .ru)
hist.record(c1)
check(hist.takeForUndo() == c1, "undo returns last fix")
check(hist.takeForUndo() == nil, "undo is one-shot")
hist.record(c1)
hist.clear()
check(hist.takeForUndo() == nil, "clear drops pending undo")

// Ревью: запятая/точка/двоеточие в хвосте — это буквы б/ю/Ж, слово не трогаем
check(LayoutFix.correction(for: "ghbdtn,", checker: fc) == nil, "trailing comma key is a letter, no fix")
check(LayoutFix.correction(for: "ghbdtn?", checker: fc)?.replacement == "привет,", "trailing ? key -> comma")
// Ревью: нет словаря целевого языка — не исправляем
struct NoRuDict: WordChecker {
    func isValid(_ word: String, _ lang: Lang) -> Bool { true }
    func hasDictionary(_ lang: Lang) -> Bool { lang != .ru }
}
check(LayoutFix.correction(for: "ghbdtn", checker: NoRuDict()) == nil, "missing target dictionary: no fix")
// Ревью: ключ исключения не зависит от регистра и хвостовой пунктуации
check(LayoutFix.ignoreKey("Ghbdtn/") == LayoutFix.ignoreKey("ghbdtn"), "ignore key normalized")
check(LayoutFix.correction(for: "Ghbdtn", checker: fc, ignore: [LayoutFix.ignoreKey("ghbdtn")]) == nil, "ignore by normalized key")

print(failed == 0 ? "ALL PASSED" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
