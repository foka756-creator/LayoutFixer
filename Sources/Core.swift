import Foundation

enum Lang: Equatable {
    case en, ru
    var other: Lang { self == .en ? .ru : .en }
}

/// Проверка слова по словарю. В приложении — NSSpellChecker, в тестах — фейк.
protocol WordChecker {
    func isValid(_ word: String, _ lang: Lang) -> Bool
    /// Есть ли словарь языка. Без словаря целевого языка исправлять нельзя.
    func hasDictionary(_ lang: Lang) -> Bool
}

extension WordChecker {
    func hasDictionary(_ lang: Lang) -> Bool { true }
}

struct Correction: Equatable {
    let original: String
    let replacement: String
    let target: Lang
}

enum LayoutFix {
    // Клавиши по позициям: ряды QWERTY и ЙЦУКЕН, затем верхний регистр и Shift+цифры.
    private static let enKeys = "qwertyuiop[]asdfghjkl;'zxcvbnm,./`QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>?~@#$^&"
    private static let ruKeys = "йцукенгшщзхъфывапролджэячсмитьбю.ёЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ,Ё\"№;:?"

    private static let toRu: [Character: Character] = Dictionary(uniqueKeysWithValues: zip(enKeys, ruKeys))
    private static let toEn: [Character: Character] = Dictionary(uniqueKeysWithValues: zip(ruKeys, enKeys))

    /// Знаки после слова, которые не дают букв в другой раскладке. Клавиши `, . ; : '` — это
    /// русские буквы б ю ж э, поэтому как хвост они не отрезаются.
    private static let tailPunct: Set<Character> = ["!", "?", "/"]

    /// Перевод каждого символа на ту же физическую клавишу другой раскладки.
    static func convert(_ s: String, to target: Lang) -> String {
        let map = target == .ru ? toRu : toEn
        return String(s.map { map[$0] ?? $0 })
    }

    /// Ключ списка исключений: без регистра и знаков по краям.
    static func ignoreKey(_ token: String) -> String { trimmed(token).lowercased() }

    private static func isCyrillic(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) }
    }

    private static func isAsciiLetter(_ c: Character) -> Bool {
        c.isASCII && c.isLetter
    }

    /// Буква в исходной раскладке: латинская или клавиша, дающая русскую букву.
    private static func isWordKey(_ c: Character, in lang: Lang) -> Bool {
        switch lang {
        case .ru: return isCyrillic(c) && c.isLetter
        case .en:
            if isAsciiLetter(c) { return true }
            guard let r = toRu[c] else { return false }
            return isCyrillic(r) && r.isLetter
        }
    }

    private static func trimmed(_ s: String) -> String {
        String(s.drop { !$0.isLetter }.reversed().drop { !$0.isLetter }.reversed())
    }

    /// Нужно ли заменить `token`. Исправляем, только если слово не найдено в словаре
    /// своего языка, а после смены раскладки найдено в словаре другого.
    static func correction(for token: String, checker: WordChecker, minLength: Int = 2,
                           ignore: Set<String> = []) -> Correction? {
        let chars = Array(token)
        guard chars.count >= minLength, !ignore.contains(ignoreKey(token)) else { return nil }

        let hasCyr = chars.contains(where: isCyrillic)
        let hasLat = chars.contains(where: isAsciiLetter)
        if hasCyr && hasLat { return nil }
        let source: Lang = hasCyr ? .ru : .en
        guard checker.hasDictionary(source), checker.hasDictionary(source.other) else { return nil }
        guard chars.contains(where: { isAsciiLetter($0) || isCyrillic($0) }) else { return nil }

        // Первый вариант — слово целиком, второй — без одного хвостового знака препинания.
        var variants = [token]
        if let last = chars.last, tailPunct.contains(last), chars.count - 1 >= minLength {
            variants.append(String(chars.dropLast()))
        }
        for variant in variants {
            let vc = Array(variant)
            guard vc.filter({ isWordKey($0, in: source) }).count >= minLength,
                  vc.contains(where: { source == .en ? isAsciiLetter($0) : isCyrillic($0) }) else { continue }
            let src = trimmed(variant)
            let converted = convert(variant, to: source.other)
            let dst = trimmed(converted)
            guard !src.isEmpty, !dst.isEmpty else { continue }
            // Знаки внутри слова (кроме ' и -) — не слово: словарь мог бы проверить лишь часть.
            let plain = src.allSatisfy { $0.isLetter || $0 == "'" || $0 == "-" }
            if plain && checker.isValid(src, source) { return nil }
            if checker.isValid(dst, source.other) {
                return Correction(original: token,
                                  replacement: convert(token, to: source.other),
                                  target: source.other)
            }
        }
        return nil
    }
}

/// Символы текущего слова, набранные с момента последнего разделителя.
struct WordBuffer {
    private(set) var text = ""
    mutating func append(_ s: String) { text += s }
    mutating func backspace() { if !text.isEmpty { text.removeLast() } }
    mutating func reset() { text = "" }
}

/// Последняя замена, которую можно откатить. Живёт до следующего действия пользователя.
struct FixHistory {
    private var last: Correction?
    mutating func record(_ c: Correction) { last = c }
    mutating func clear() { last = nil }
    mutating func takeForUndo() -> Correction? { defer { last = nil }; return last }
}
