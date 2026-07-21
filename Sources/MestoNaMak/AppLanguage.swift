import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case russian = "ru"
    case english = "en"

    var id: String { rawValue }
    var shortTitle: String { self == .russian ? "RU" : "EN" }
    var locale: Locale { Locale(identifier: rawValue) }
}

func tr(_ key: String, language: AppLanguage, _ arguments: CVarArg...) -> String {
    let translations: [AppLanguage: [String: String]] = [
        .russian: [
            "main.disk": "Основной диск", "disk.free": "Свободно %@ из %@",
            "scan": "Сканировать диск", "scanning": "Сканирование…", "stop.scan": "Остановить", "sorting": "Сортировка", "sorting.progress": "Сортировка…",
            "size": "Размер", "growth": "Прирост", "compare": "Сравнить с",
            "no.compare": "Не сравнивать", "delete.snapshot": "Удалить снимок",
            "delete.help": "Удалить выбранный снимок из истории", "optimize.history": "Сжать историю", "optimize.help": "Сжать все сохранённые снимки и освободить место", "counting": "Подсчитываю папки и файлы: %@",
            "scanning.disk": "Сканирование диска", "remaining": "≈ ещё %@", "more.previous": "больше прошлого снимка",
            "folder": "Папка", "change": "Изменение", "empty.title": "Диск ещё не просканирован",
            "empty.description": "Создайте первый снимок всего диска.", "error": "Ошибка", "open.finder": "Открыть в Finder"
        ],
        .english: [
            "main.disk": "Main Disk", "disk.free": "%@ free of %@",
            "scan": "Scan Disk", "scanning": "Scanning…", "stop.scan": "Stop", "sorting": "Sort", "sorting.progress": "Sorting…",
            "size": "Size", "growth": "Growth", "compare": "Compare with",
            "no.compare": "Don't compare", "delete.snapshot": "Delete Snapshot",
            "delete.help": "Delete the selected snapshot from history", "optimize.history": "Compress History", "optimize.help": "Compress saved snapshots to free space", "counting": "Counting folders and files: %@",
            "scanning.disk": "Scanning disk", "remaining": "≈ %@ remaining", "more.previous": "more than previous scan",
            "folder": "Folder", "change": "Change", "empty.title": "Disk hasn't been scanned yet",
            "empty.description": "Create the first snapshot of the whole disk.", "error": "Error", "open.finder": "Open in Finder"
        ]
    ]
    let format = translations[language]?[key] ?? key
    return arguments.isEmpty ? format : String(format: format, locale: language.locale, arguments: arguments)
}
