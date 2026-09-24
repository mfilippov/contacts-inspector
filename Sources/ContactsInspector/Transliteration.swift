import Foundation

/// «Привычная» транслитерация русских (и украинских) имён в латиницу — так, как люди обычно
/// пишут своё имя по-английски: Дмитрий → Dmitry, Наталья → Natalya, Щукин → Shchukin.
enum Translit {
    private static let map: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e", "ж": "zh", "з": "z",
        "и": "i", "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r",
        "с": "s", "т": "t", "у": "u", "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch",
        "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
        // украинские
        "і": "i", "ї": "yi", "є": "ye", "ґ": "g",
    ]
    /// После ь/ъ эти гласные читаются с «й»: Васильев → Vasilyev, Ильин → Ilyin.
    private static let softened: [Character: String] = ["е": "ye", "ё": "yo", "и": "yi", "ю": "yu", "я": "ya"]

    static func hasCyrillic(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }

    static func latin(_ s: String) -> String {
        // по словам — чтобы правильно обработать окончания -ий/-ый и регистр
        var out = ""
        var word: [Character] = []
        func flush() { out += word.isEmpty ? "" : latinWord(word); word = [] }
        for ch in s {
            if ch.isLetter { word.append(ch) } else { flush(); out.append(ch) }
        }
        flush()
        return out
    }

    private static func latinWord(_ w: [Character]) -> String {
        let lower = w.map { Character($0.lowercased()) }
        let allCaps = w.count > 1 && w.allSatisfy { !$0.isLetter || $0.isUppercase }
        var out = ""
        var i = 0
        while i < w.count {
            let c = lower[i]
            var piece: String
            if i >= 1, lower[i - 1] == "ь" || lower[i - 1] == "ъ", let soft = softened[c] {
                piece = soft
            } else if (c == "и" || c == "ы"), i + 1 == w.count - 1, lower[i + 1] == "й" {
                // окончание -ий/-ый → y: Дмитрий → Dmitry
                piece = "y"
                i += 1
            } else if let m = map[c] {
                piece = m
            } else {
                piece = String(w[i])   // не кириллица — как есть
                out += piece
                i += 1
                continue
            }
            if w[i].isUppercase || (i > 0 && w[i - 1].isUppercase && c == "й" && allCaps) {
                piece = allCaps ? piece.uppercased() : piece.prefix(1).uppercased() + piece.dropFirst()
            }
            out += piece
            i += 1
        }
        return out
    }
}
