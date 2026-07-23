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
            "scan": "Сканировать диск", "scan.accelerated": "Ускоренное", "scan.full.button": "Полное", "scanning": "Сканирование…", "stop.scan": "Остановить", "sorting": "Сортировка", "sorting.progress": "Сортировка…", "tree.preparing": "Подготавливаю дерево папок…",
            "size": "Размер", "growth": "Прирост", "compare": "Сравнить с", "snapshot.storage": "Снимок: %@",
            "no.compare": "Не сравнивать", "delete.snapshot": "Удалить снимок",
            "delete.help": "Удалить выбранный снимок из истории", "optimize.history": "Сжать историю", "optimize.help": "Сжать все сохранённые снимки и освободить место", "counting": "Подсчитываю папки и файлы: %@",
            "scanning.disk": "Сканирование диска", "scanning.changes": "Обновляю изменённые папки", "scanning.full": "Полное сканирование диска", "scanning.partial": "Частичное сканирование: изменённые папки", "history.loading": "Получаю журнал изменений…", "remaining": "≈ ещё %@", "more.previous": "больше прошлого снимка", "scan.elapsed": "Время сканирования: %@", "scan.last": "Последнее сканирование: %@", "scan.last.full": "Последнее полное сканирование: %@", "scan.last.partial": "Последнее частичное сканирование: %@",
            "folder": "Папка", "change": "Изменение", "empty.title": "Диск ещё не просканирован",
            "empty.description": "Создайте первый снимок всего диска.", "error": "Ошибка", "open.finder": "Открыть в Finder", "copy.path": "Копировать путь",
            "about": "О программе", "about.description": "Анализатор свободного места и изменений размера папок для macOS.",
            "about.author": "Автор", "about.email": "Почта", "about.website": "Сайт", "feedback": "Отправить отзыв / Сообщить об ошибке", "close": "Закрыть",
            "cancel": "Отмена", "stop.confirm.title": "Остановить сканирование?", "stop.confirm.message": "Текущий результат не будет сохранён в истории."
        ],
        .english: [
            "main.disk": "Main Disk", "disk.free": "%@ free of %@",
            "scan": "Scan Disk", "scan.accelerated": "Accelerated", "scan.full.button": "Full Scan", "scanning": "Scanning…", "stop.scan": "Stop", "sorting": "Sort", "sorting.progress": "Sorting…", "tree.preparing": "Preparing folder tree…",
            "size": "Size", "growth": "Growth", "compare": "Compare with", "snapshot.storage": "Snapshot: %@",
            "no.compare": "Don't compare", "delete.snapshot": "Delete Snapshot",
            "delete.help": "Delete the selected snapshot from history", "optimize.history": "Compress History", "optimize.help": "Compress saved snapshots to free space", "counting": "Counting folders and files: %@",
            "scanning.disk": "Scanning disk", "scanning.changes": "Refreshing changed folders", "scanning.full": "Full disk scan", "scanning.partial": "Partial scan: changed folders", "history.loading": "Reading change history…", "remaining": "≈ %@ remaining", "more.previous": "more than previous scan", "scan.elapsed": "Scan time: %@", "scan.last": "Last scan: %@", "scan.last.full": "Last full scan: %@", "scan.last.partial": "Last partial scan: %@",
            "folder": "Folder", "change": "Change", "empty.title": "Disk hasn't been scanned yet",
            "empty.description": "Create the first snapshot of the whole disk.", "error": "Error", "open.finder": "Open in Finder", "copy.path": "Copy Path",
            "about": "About", "about.description": "A macOS utility for tracking free space and folder-size changes.",
            "about.author": "Author", "about.email": "Email", "about.website": "Website", "feedback": "Send Feedback / Report a Bug", "close": "Close",
            "cancel": "Cancel", "stop.confirm.title": "Stop scanning?", "stop.confirm.message": "The current result will not be saved to history."
        ]
    ]
    let format = translations[language]?[key] ?? key
    return arguments.isEmpty ? format : String(format: format, locale: language.locale, arguments: arguments)
}
