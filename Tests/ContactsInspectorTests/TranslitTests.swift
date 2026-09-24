import XCTest
@testable import ContactsInspector

final class TranslitTests: XCTestCase {
    func testNames() {
        let cases: [(String, String)] = [
            ("Юрий", "Yury"), ("Фёдоров", "Fedorov"), ("Дмитрий", "Dmitry"), ("Анатолий", "Anatoly"),
            ("Наталья", "Natalya"), ("Васильев", "Vasilyev"), ("Ильин", "Ilyin"), ("Щукин", "Shchukin"),
            ("Александр", "Aleksandr"), ("Евгений", "Evgeny"), ("Жанна", "Zhanna"), ("Хабибуллин", "Khabibullin"),
            ("Цой", "Tsoy"), ("Чернышёва", "Chernysheva"), ("Сергеевич", "Sergeevich"), ("Юлия", "Yuliya"),
            ("ЩУКИН", "SHCHUKIN"), ("Анна-Мария", "Anna-Mariya"), ("Олег (work)", "Oleg (work)"),
            ("Олександр", "Oleksandr"), ("Їжак", "Yizhak"), ("Alex", "Alex"),
        ]
        for (ru, en) in cases { XCTAssertEqual(Translit.latin(ru), en, ru) }
    }

    func testDetect() {
        XCTAssertTrue(Translit.hasCyrillic("Иван"))
        XCTAssertTrue(Translit.hasCyrillic("Ivan Петров"))
        XCTAssertFalse(Translit.hasCyrillic("Ivan"))
    }
}
