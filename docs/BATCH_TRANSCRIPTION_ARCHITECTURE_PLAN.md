# VaniScript: архитектурный план подсистемы пакетной транскрибации

> **Статус:** Proposed architecture  
> **Целевая платформа:** macOS 14+, Apple Silicon  
> **Стек:** Swift 6, SwiftUI, AppKit, SwiftPM, AVFoundation, WhisperKit/Core ML, FluidAudio  
> **Репозиторий:** `Pavan-Gopa/VaniScript`  
> **Базовый срез анализа:** `main` @ `8dd230d9fa4eed2d0d2e09fb19ed0d2f25104e9f`  
> **Назначение документа:** самодостаточная спецификация для архитекторов, coding-, review-, test- и security-агентов.

---

## 1. Резюме решения

В VaniScript уже есть почти вся низкоуровневая инфраструктура, необходимая для автоматической транскрибации:

- локальные WhisperKit, Parakeet и Canary;
- облачные ASR-провайдеры;
- нарезка длинного аудио на чанки;
- сегментные и пословные тайминги;
- преобразование относительных таймингов чанка в абсолютные тайминги файла;
- экспорт TXT/SRT/VTT;
- проверка готовности моделей;
- тестовые seams для ASR-движков.

Текущий продуктовый поток, однако, рассчитан на один интерактивный проект:

```text
Upload → Config → Processing → Review → Export
```

Для пакетной обработки нужен отдельный долгоживущий application layer:

```text
Watched folder
    → reconciliation scan
    → file stability gate
    → strict naming validation
    → persistent queue
    → ASR-only transcription
    → timed TXT rendering
    → atomic same-folder commit
```

Главное архитектурное решение:

> **Не добавлять очередь папок непосредственно в `WorkflowStore`.**  
> Создать отдельный actor-based batch runtime, который совместно с ручным workflow использует один ASR scheduler/router, но имеет собственные модели состояния, persistence и UI store.

Итоговая архитектурная формула:

```text
persistent watched folders
+ strict media-name domain
+ file stability gate
+ durable job state machine
+ shared ASR scheduler
+ transcription-only use case
+ exact-stem timed TXT
+ atomic/idempotent writer
```

---

## 2. Цели и нецели

### 2.1. Цели

Подсистема должна обеспечивать следующий сценарий после однократной настройки папки:

1. Пользователь помещает один или несколько аудиофайлов в наблюдаемую папку.
2. Система автоматически замечает новые или изменившиеся файлы.
3. Система дожидается окончания копирования.
4. Имя файла строго проверяется по принятой конвенции.
5. Файл ставится в персистентную очередь без дубликатов.
6. Выполняется транскрибация с абсолютными таймингами.
7. Рядом с аудио атомарно создается одноименный `.txt`.
8. При перезапуске приложения незавершенная работа восстанавливается.
9. Ошибка одного файла не останавливает остальные задания.
10. Существующий ручной workflow продолжает работать без изменения его пользовательской семантики.

### 2.2. Нецели первой версии

В MVP не входят:

- перевод транскрипта;
- автоматическая публикация результатов;
- обязательное создание `ProjectRecord` для каждого batch-файла;
- распознавание WHO/WHAT/WHERE с помощью LLM и запись догадок в архивное имя;
- произвольное количество параллельных локальных inference-задач;
- обязательная работа при полностью завершенном процессе VaniScript;
- модификация существующего интерактивного export naming для ручного workflow.

---

## 3. Что уже переиспользуется из приложения

### 3.1. ASR-модели и общий контракт

В приложении уже есть общий локальный ASR-контракт:

```swift
struct LocalASRRequest
struct LocalASRResult
protocol LocalASREngine
```

`LocalASRResult` возвращает:

```swift
var text: String
var cues: [TranscriptCue]?
```

`TranscriptCue` содержит:

```swift
startSec
endSec
text
words
```

а `TranscriptWord` содержит собственные `startSec` и `endSec`.

Это позволяет строить итоговый timed TXT без повторного выравнивания, когда движок предоставляет реальные timestamps.

### 3.2. `LocalASREngineRouter`

Существующий router:

- является actor;
- поддерживает WhisperKit/Core ML, Parakeet/FluidAudio и Canary/Core ML;
- держит одну resident-модель;
- переиспользует ее для последовательных запросов;
- выгружает старую модель при смене descriptor/path;
- уже описан как общий route для batch, current chunk и dictation.

Его следует сделать общей зависимостью ручного и пакетного потоков, а не создавать независимый router для каждого batch-job.

### 3.3. Тайминги и чанки

`NativeProcessingPipeline` уже умеет:

- определять duration;
- планировать чанки;
- экспортировать M4A-сегменты через AVFoundation;
- направлять сегмент локальному или облачному ASR;
- применять source glossary;
- сохранять `TranscriptCue`;
- прибавлять `chunk.startSec` к относительным таймингам движка.

Эту логику нужно извлечь в ASR-only сервис и использовать из обоих workflow.

### 3.4. Подготовка аудио

`LocalASRAudioPreprocessor` уже приводит произвольное читаемое аудио к:

```text
16 kHz
mono
PCM Int16
WAV
```

и удаляет частичный output при ошибке или отмене.

### 3.5. Импорт и media inspection

Для предварительной проверки можно переиспользовать:

- `SourceMediaInspector`;
- `MediaDurationReader`;
- AVFoundation-проверку наличия audio track;
- список media extensions из `SourceClassifier` как исходную справочную точку.

При этом batch должен иметь собственную политику допустимых типов: задача сформулирована для аудиофайлов, поэтому видео не следует автоматически подхватывать в MVP.

### 3.6. Что нельзя использовать напрямую

`NativeProcessingPipeline.process(...)` нельзя вызывать как batch API, потому что он:

- проверяет готовность переводчика;
- может запускать перевод;
- изменяет `SessionState`;
- ориентирован на Review;
- принимает и мутирует `AppSettings`;
- возвращает интерактивное состояние, а не доменный результат транскрибации.

`TranscriptExportBuilder.defaultFileName(...)` также нельзя использовать для batch без специального режима: он добавляет `_original` или суффикс языка, что нарушает требование одинакового stem.

---

## 4. Внешний контракт именования

## 4.1. Каноническая схема

Каноническое имя медиафайла:

```text
<DATE>_<WHO>_<WHAT>_<WHERE>_<COUNTRY>.<extension>
```

Пример:

```text
2013-11-14_KKS_SB-9-20-20-27_Vrindavan_in.mp4
```

Для batch-аудио:

```text
2023-01-16_KKS_CC-Raghunatha-das-goswami_Amsterdam_nl.mp3
```

Итоговый transcript companion:

```text
2023-01-16_KKS_CC-Raghunatha-das-goswami_Amsterdam_nl.txt
```

Обязательный инвариант:

> **Меняется только расширение. Stem аудио и TXT совпадает побайтно.**

Запрещены автоматические суффиксы:

```text
_original
_transcript
_timed
_ru
_uuid
(2)
```

## 4.2. Допустимые DATE-токены

Поле DATE принимает:

```text
YYYY-MM-DD
YYYY-MM
YYYY
literal YYYY-MM-DD
```

Примеры:

```text
2023-01-16
2023-01
2023
YYYY-MM-DD
```

Полные и частичные цифровые даты должны валидироваться календарно. `2023-13-52` недопустимо.

## 4.3. Правила полей

Рекомендуемая грамматика:

```text
DATE      := YYYY-MM-DD | YYYY-MM | YYYY | literal "YYYY-MM-DD"
WHO       := token ("-" token)*
WHAT      := token (("-" | "_") token)*
WHERE     := token ("-" token)*
COUNTRY   := [a-z]{2}
extension := [a-z0-9]+
token     := [A-Za-z0-9]+
```

Дополнительные правила:

- между смысловыми полями используется `_`;
- внутри смыслового поля используется `-`;
- внутренний `_` допускается в WHAT, потому что исходный пример содержит составную тему;
- пробелы запрещены;
- точки внутри stem запрещены;
- расширение только в lowercase;
- country code — ровно две строчные латинские буквы;
- максимальная длина имени — 128 символов;
- длина больше 25 символов — warning, но не hard error;
- сравнение конфликтов выполняется case-insensitively.

## 4.4. Разбор WHAT с внутренними подчеркиваниями

Парсер нельзя строить как фиксированное число компонентов после `split("_")`.

Надежный алгоритм:

1. Слева распознать DATE.
2. Справа распознать COUNTRY.
3. Предыдущий справа компонент считать WHERE.
4. Первый компонент после DATE считать WHO.
5. Все компоненты между WHO и WHERE объединить в WHAT.

Например:

```text
2020_KKS_SB-8-1-30_Balancing-our-lives_London_gb.mp3
```

разбирается как:

```text
DATE    = 2020
WHO     = KKS
WHAT    = SB-8-1-30_Balancing-our-lives
WHERE   = London
COUNTRY = gb
```

## 4.5. Неоднозначность на исходном скриншоте

В одном примере WHO и WHAT разделены `_`, во втором — `-`:

```text
KKS_SB-...
KKS-CC-Raghunatha-...
```

До начала реализации необходимо зафиксировать ADR:

> **Новая каноническая форма всегда использует `_` между WHO и WHAT.**

То есть:

```text
2023-01-16_KKS_CC-Raghunatha-das-goswami_Amsterdam_nl.mp3
```

Форму `KKS-CC-...` можно принимать только как legacy input с предупреждением и, при разрешенной нормализации, преобразовывать в каноническую форму.

## 4.6. Почему текущий `MetadataExtractor` не является parser

Существующий extractor:

- заменяет `_`, `-` и `.` пробелами;
- эвристически ищет даты;
- знает ограниченный набор локаций;
- знает сокращения некоторых лекторов;
- извлекает scripture titles.

Он полезен для интерактивного prefill, но не может быть источником истины batch-naming, поскольку теряет границы полей и не обеспечивает round trip:

```text
parse → model → render == original canonical name
```

Нужен отдельный домен `CanonicalMediaName`.

---

## 5. Политики неправильных имен

Нужно поддержать три режима.

### 5.1. `strictReject` — default

Некорректно названный файл:

- не переименовывается;
- не транскрибируется;
- получает состояние `blockedInvalidName`;
- показывает набор точных validation errors.

Это безопасный режим для архивов.

### 5.2. `safeNormalize`

Разрешены только механические исправления:

- `.MP3` → `.mp3`;
- внешние пробелы удаляются;
- пробелы внутри компонентов заменяются на `-`;
- повторные `_` и `-` схлопываются;
- Unicode нормализуется;
- запрещенные символы удаляются или заменяются согласно явно описанной политике.

Система не имеет права придумывать WHO, WHAT, WHERE или COUNTRY.

### 5.3. `profileAssistedRename`

Папка имеет профиль с defaults:

```text
WHO: KKS
WHERE: Amsterdam
COUNTRY: nl
Date policy: require in source name
WHAT policy: sanitize remaining stem
```

Автоматическое переименование разрешено только тогда, когда все обязательные поля достоверно получены из имени или профиля.

---

## 6. Пользовательский поток

После однократной настройки профиля:

```text
Пользователь копирует аудио в папку
        ↓
WatchedFolderService помечает папку dirty
        ↓
FolderReconciler выполняет scan
        ↓
FileStabilityProbe дожидается завершения копирования
        ↓
MediaNamePolicy валидирует/нормализует имя
        ↓
JobRepository проверяет дедупликацию и конфликты
        ↓
BatchCoordinator ставит job в очередь
        ↓
TranscriptionScheduler выдает ASR slot
        ↓
FileTranscriptionService транскрибирует чанки
        ↓
BatchTimedTextRenderer создает документ
        ↓
AtomicCompanionWriter записывает .txt рядом с аудио
        ↓
Job переходит в completed
```

Никаких `Config`, `Review`, `Export` или `NSSavePanel` в этом пути нет.

---

## 7. Целевая архитектура компонентов

```text
┌────────────────────────────────────────────────────────────┐
│                        VaniScript App                       │
│                                                            │
│ Existing WorkflowStore         BatchTranscriptionStore     │
│ Manual project workflow        Queue/dashboard snapshots   │
└───────────────┬───────────────────────────┬────────────────┘
                │                           │
                └──────────────┬────────────┘
                               ▼
                    ┌───────────────────────┐
                    │ TranscriptionScheduler│
                    │ manual > background   │
                    └───────────┬───────────┘
                                ▼
                    ┌───────────────────────┐
                    │FileTranscriptionService
                    │ ASR-only, no UI       │
                    └──────┬─────────┬──────┘
                           │         │
                           ▼         ▼
                    Chunk service  Shared ASR router
                           │         │
                           └────┬────┘
                                ▼
                         FileTranscript
                                │
                                ▼
┌────────────────────────────────────────────────────────────┐
│               BatchTranscriptionCoordinator                │
│                                                            │
│ reconcile → stability → naming → fingerprint → queue       │
│ → checkpoint → render → atomic commit                      │
└──────────┬────────────────┬───────────────────┬────────────┘
           │                │                   │
           ▼                ▼                   ▼
 Folder profiles       SQLite job store   Same-folder writer
 + bookmarks           + checkpoints      exact stem + .txt
```

---

## 8. Рекомендуемое разделение Swift targets

### 8.1. `VaniScriptCore`

Чистые доменные типы и алгоритмы без AppKit, AVFoundation и конкретных ML SDK:

```text
Sources/VaniScriptCore/Batch/
    CanonicalMediaName.swift
    MediaNameParser.swift
    MediaNameValidator.swift
    BatchTranscriptionModels.swift
    BatchJobStateMachine.swift
    BatchTimedTextRenderer.swift
    FileFingerprint.swift
    TranscriptionCapabilities.swift
```

Протоколы:

```swift
public protocol AudioTranscribing: Sendable
public protocol BatchJobRepository: Sendable
public protocol BatchOutputWriting: Sendable
public protocol FolderAccessing: Sendable
```

### 8.2. Новый `VaniScriptRuntime`

Общая реализация, работающая с ASR, AVFoundation и файловой системой:

```text
Sources/VaniScriptRuntime/Transcription/
    FileTranscriptionService.swift
    TranscriptionScheduler.swift
    LocalASREngineRouter.swift
    LocalASRAudioPreprocessor.swift
    AudioChunkProcessingService.swift

Sources/VaniScriptRuntime/Batch/
    BatchTranscriptionCoordinator.swift
    WatchedFolderService.swift
    FolderReconciler.swift
    FileStabilityProbe.swift
    SQLiteBatchJobRepository.swift
    SecurityScopedFolderStore.swift
    AtomicCompanionWriter.swift
    BatchWorkDirectory.swift
```

### 8.3. `VaniScript`

Композиция зависимостей и SwiftUI:

```text
Sources/VaniScript/BatchUI/
    BatchTranscriptionStore.swift
    BatchWorkspaceView.swift
    BatchFolderProfileView.swift
    BatchJobRowView.swift
    BatchJobDetailsView.swift
```

При желании первый PR может не создавать новый target физически, но граница `Core / Runtime / UI` должна соблюдаться на уровне API. Конечная цель — вынести повторно используемые ASR-сервисы из executable target.

---

## 9. Доменные модели

## 9.1. `CanonicalMediaName`

```swift
public struct CanonicalMediaName: Codable, Equatable, Sendable {
    public let date: MediaDateToken
    public let who: String
    public let what: String
    public let location: String
    public let countryCode: String
}

public enum MediaDateToken: Codable, Equatable, Sendable {
    case day(year: Int, month: Int, day: Int)
    case month(year: Int, month: Int)
    case year(Int)
    case unknown
}
```

Обязательные операции:

```swift
parse(fileName:) -> Result<CanonicalMediaName, [NamingViolation]>
render(name:extension:) -> String
companionURL(for:extension:) -> URL
```

## 9.2. `BatchFolderProfile`

```swift
public struct BatchFolderProfile: Codable, Identifiable, Sendable {
    public let id: UUID
    public var bookmarkData: Data
    public var displayPath: String
    public var enabled: Bool
    public var recursive: Bool

    public var sourceLanguage: String
    public var transcriptionProviderID: String
    public var timingPolicy: TimingPolicy

    public var namingMode: NamingMode
    public var overwritePolicy: OverwritePolicy
    public var maxAttempts: Int
}
```

Профиль хранит конкретный provider ID. Нельзя незаметно переключаться с local на cloud или между cloud-провайдерами.

## 9.3. `BatchJob`

```swift
public struct BatchJob: Codable, Identifiable, Sendable {
    public let id: UUID
    public let profileID: UUID

    public var relativeSourcePath: String
    public var canonicalStem: String
    public var outputRelativePath: String

    public var sourceFingerprint: FileFingerprint?
    public var configurationFingerprint: String?

    public var state: BatchJobState
    public var attempt: Int
    public var progress: Double

    public var completedChunkIndexes: [Int]
    public var checkpointPath: String?
    public var generatedOutputHash: String?

    public var errorCode: String?
    public var errorMessage: String?

    public var createdAt: Date
    public var updatedAt: Date
}
```

Абсолютный путь не должен быть единственным идентификатором. В job сохраняется относительный путь внутри watched folder, чтобы пережить изменение mount path внешнего диска.

## 9.4. `FileTranscriptionRequest` и result

```swift
public struct FileTranscriptionRequest: Sendable {
    public let sourceURL: URL
    public let sourceLanguage: String
    public let providerID: String
    public let chunking: ChunkingPolicy
    public let metadata: AudioMetadata
    public let timingPolicy: TimingPolicy
}

public struct FileTranscript: Codable, Sendable {
    public var durationSec: Double
    public var text: String
    public var cues: [TranscriptCue]
    public var timingQuality: TimingQuality
    public var engineID: String
}
```

```swift
public protocol AudioTranscribing: Sendable {
    func transcribeFile(
        _ request: FileTranscriptionRequest,
        progress: @Sendable (TranscriptionProgress) async -> Void
    ) async throws -> FileTranscript
}
```

---

## 10. Персистентная очередь

Существующий in-memory job manager не подходит для файлового архива. Нужна отдельная `BatchJobRepository`.

Рекомендуемое хранение:

```text
~/Library/Application Support/VaniScript/Batch/
    batch-profiles.json
    batch-jobs.sqlite
    Work/
        <job-id>/
            checkpoint.json
            transcript.json
            chunks/
```

### 10.1. Почему SQLite

SQLite дает:

- атомарные state transitions;
- crash recovery;
- эффективную очередь для тысяч файлов;
- уникальные индексы для дедупликации;
- историю ошибок и retries;
- фильтрацию по folder/status;
- возможность будущего чтения UI-процессом при отдельном agent.

Рекомендуемые таблицы:

```text
folder_profiles
batch_jobs
batch_chunks
job_events
```

### 10.2. Индексы и дедупликация

Минимальные unique constraints:

```text
(profile_id, relative_source_path, source_fingerprint, config_fingerprint)
(profile_id, lower(output_relative_path), active_generation)
```

Вторая защита предотвращает два одновременных job, претендующих на один `.txt`.

---

## 11. State machine

Основной happy path:

```text
discovered
    ↓
stabilizing
    ↓
validatingName
    ↓
ready
    ↓
preprocessing
    ↓
transcribing
    ↓
rendering
    ↓
committing
    ↓
completed
```

Дополнительные состояния:

```text
skippedAlreadyCurrent
blockedInvalidName
blockedNamingConflict
blockedOutputConflict
blockedOutputModified
blockedModelUnavailable
blockedFolderPermission
failedRetryable
failedPermanent
cancelled
superseded
```

### 11.1. Восстановление после crash

При запуске:

- `preprocessing` → `ready`;
- `transcribing` → продолжить с последнего chunk checkpoint или `ready`;
- `rendering` → повторить рендер из `transcript.json`;
- `committing` → проверить temp/final output и завершить либо повторить commit;
- orphaned workspaces без активного job удалить;
- `completed` перепроверить по source/config/output hash при reconciliation.

Каждый переход state должен сохраняться до выполнения следующего необратимого побочного действия.

---

## 12. Наблюдение за папкой

## 12.1. FSEvents — только сигнал, не источник истины

Filesystem events могут:

- объединяться;
- повторяться;
- приходить до завершения копирования;
- теряться при выключенном приложении.

Поэтому правильная модель:

```text
FSEvent
    → mark profile dirty
    → debounce
    → FolderReconciler scan
    → compare filesystem with durable journal
```

Полный scan выполняется:

- при запуске;
- при восстановлении bookmark;
- после filesystem event;
- периодически как safety net;
- по пользовательской команде Rescan.

## 12.2. Фильтрация

Игнорируются:

- hidden files;
- `.DS_Store`;
- `.txt`;
- `.part`, `.download`, `.tmp`;
- temp-файлы VaniScript;
- directories и packages;
- symlinks по умолчанию;
- неподдерживаемые расширения;
- output, только что записанный самой системой.

Recursive scan является настройкой профиля и по умолчанию выключен.

---

## 13. File stability gate

Нельзя открывать файл сразу после появления.

Файл считается стабильным, если:

1. размер и modification date не изменились в двух последовательных проверках;
2. проверки разделены configurable quiet period;
3. файл можно открыть для чтения;
4. AVFoundation обнаруживает audio track;
5. duration читается либо возвращается структурированная ошибка;
6. файл не имеет temporary extension;
7. после транскрибации fingerprint источника по-прежнему совпадает.

Рекомендуемые defaults:

```text
local folder quiet period: 2–3 sec
network/cloud folder quiet period: 10 sec
max stabilization wait: configurable
```

Если source изменился во время ASR, полученные результаты не коммитятся; job возвращается в `stabilizing` с новой generation.

---

## 14. ASR-only processing service

## 14.1. Обязательный рефакторинг

Нужно отделить транскрибацию от перевода и Review.

Композиция после рефакторинга:

```text
interactive process
    = transcribeFile
    + optional translate
    + SessionState mutation
    + Review/project workflow

batch process
    = transcribeFile
    + timed TXT render
    + atomic companion write
```

### 14.2. Обработка одного файла

```text
resolve duration
    ↓
plan chunks
    ↓
create explicit work directory
    ↓
for each unfinished chunk:
    export/preprocess audio
    acquire ASR scheduler slot
    transcribe
    map relative cues to absolute time
    apply source glossary
    persist chunk checkpoint
    release temporary chunk
    ↓
merge cues
    ↓
normalize and validate timings
    ↓
persist FileTranscript
```

### 14.3. Checkpoints

После каждого чанка сохраняются:

```text
chunk index
chunk time range
engine id
text
absolute cues
usage delta, if any
source fingerprint
configuration fingerprint
```

Checkpoint принимается только при совпадении source и config fingerprints.

### 14.4. Temporary audio lifecycle

Текущий exporter создает UUID-папку, когда отсутствует projectId, но не возвращает owner, гарантирующий cleanup.

Новый API должен быть одним из двух:

```swift
exportChunks(..., workspaceURL: URL)
```

или:

```swift
struct AudioChunkWorkspace {
    let urls: [Int: URL]
    func cleanup()
}
```

Coordinator обязан использовать deterministic job workspace и удалять его при success/failure/cancel. Orphan cleanup выполняется при следующем запуске.

---

## 15. Тайминги

## 15.1. Capabilities

Добавить явный контракт:

```swift
public struct TranscriptionCapabilities: Sendable {
    public let providesSegmentTimestamps: Bool
    public let providesWordTimestamps: Bool
}
```

## 15.2. Timing policy

Default:

```text
requireModelCues
```

Если движок вернул только plain text, job завершается с `timingsUnavailable`, а не выдает неточные тайминги как достоверные.

Дополнительный режим:

```text
allowEstimated
```

может использовать существующий bounded fallback. Результат получает:

```text
Timing-Quality: estimated
```

## 15.3. Валидация cue

Перед рендером:

- cues сортируются по `startSec`;
- отрицательные значения запрещены или clamp-ятся только по явно принятой политике;
- `endSec > startSec`;
- `endSec <= duration + tolerance`;
- порядок не идет назад;
- пустые cue удаляются;
- дубли на границах чанков дедуплицируются детерминированно;
- word timestamps сохраняются в checkpoint/result, даже если TXT выводит только segment cues.

---

## 16. Планировщик ресурсов

Нужен общий `TranscriptionScheduler`, используемый ручным и batch workflow.

Приоритеты:

```text
interactive = high
background  = low
```

Defaults:

```text
local ASR concurrency: 1
cloud ASR concurrency: 1 в MVP
hashing/discovery concurrency: 2–4
render/write concurrency: 2
```

Поведение:

- manual job получает следующий ASR slot первым;
- batch может остановиться между чанками;
- текущий inference не прерывается без необходимости;
- одна и та же локальная модель не загружается двумя router-инстансами;
- перед тяжелой локальной MLX-операцией существующий механизм unload ASR сохраняется;
- облачный batch не включается автоматически без явного профиля.

---

## 17. Итоговый TXT

Рекомендуемый формат MVP:

```text
VaniScript Timed Transcript
Source: 2023-01-16_KKS_CC-Raghunatha-das-goswami_Amsterdam_nl.mp3
Date: 2023-01-16
Who: KKS
What: CC-Raghunatha-das-goswami
Where: Amsterdam, nl
Timing-Quality: model

[00:00:00.000 --> 00:00:04.820]
First recognized segment.

[00:00:04.820 --> 00:00:08.160]
Second recognized segment.
```

Правила:

- UTF-8;
- LF line endings;
- cue-level timestamps;
- часы присутствуют всегда;
- миллисекунды — три цифры;
- текст cue нормализуется, но содержимое не переводится;
- generated timestamp не включается, чтобы output был детерминированным;
- renderer version входит в config fingerprint.

Output URL вычисляется только так:

```swift
let outputURL = audioURL
    .deletingPathExtension()
    .appendingPathExtension("txt")
```

---

## 18. Атомарная запись

`AtomicCompanionWriter` выполняет:

1. финальную проверку destination conflict;
2. создание скрытого temp-файла в той же директории;
3. запись UTF-8;
4. flush/close;
5. повторную проверку source fingerprint;
6. SHA-256 output;
7. атомарный rename/replace;
8. запись output hash в database;
9. перевод job в `completed`.

Пример temp-файла:

```text
.vaniscript-7D04A8E9-tmp
```

Финальное имя появляется только после полной успешной записи.

---

## 19. Идемпотентность и защита пользовательских правок

## 19.1. Source fingerprint

Минимум:

```text
file resource identifier, если доступен
size
modification date
streaming SHA-256
```

## 19.2. Configuration fingerprint

Включает:

```text
provider ID
model ID
model binding/version/path identity
source language
chunking parameters
timing policy
glossary revision
renderer version
naming convention version
```

## 19.3. Output overwrite policy

Default:

```text
replaceGeneratedOnly
```

| Ситуация | Действие |
|---|---|
| TXT отсутствует | Создать |
| Source/config не изменились, hash совпадает | `skippedAlreadyCurrent` |
| Source/config изменились, TXT равен ранее сгенерированному | Атомарно заменить |
| TXT был изменен пользователем | `blockedOutputModified` |
| TXT существовал до появления job | `blockedOutputConflict` |
| Пользователь явно выбрал overwrite once | Создать новую generation и заменить |

Для обнаружения пользовательской правки сохраняется hash generated output. Текущий TXT сравнивается с этим hash перед любой заменой.

## 19.4. Stem collision

Файлы:

```text
lecture.mp3
lecture.wav
```

претендуют на один `lecture.txt`.

Система не добавляет `(2)` или UUID. Создается `blockedNamingConflict`, который требует переименования одного из источников.

---

## 20. Security-scoped folders

Однократное подключение папки:

1. `NSOpenPanel` с `canChooseDirectories = true`;
2. создать security-scoped bookmark;
3. сохранить bookmark в `batch-profiles.json`;
4. при запуске разрешить bookmark;
5. удерживать `startAccessingSecurityScopedResource()` во время наблюдения/обработки;
6. при stale bookmark запросить повторное подключение;
7. операции с iCloud/Dropbox-like folders при необходимости координировать через `NSFileCoordinator`.

При потере доступа задания переходят в `blockedFolderPermission`, а не retry-ятся бесконечно.

Техническое состояние не хранится в пользовательской папке. Там появляются только:

```text
audio.ext
audio.txt
```

---

## 21. UI

Создать отдельное batch workspace/scene, а не новый `UniversalWorkflowScreen`.

Причины:

- текущий router обслуживает одну активную сессию;
- очередь должна жить независимо от Review/Export;
- закрытие окна не должно отменять batch;
- для очереди нужны собственные списки, фильтры и команды.

Предлагаемый экран:

```text
Batch Transcription
────────────────────────────────────────────────────────
Folder: /Archive/KKS                    [Open] [Change]
Status: Watching                        [Pause]

Queued: 4   Running: 1   Completed: 128   Blocked: 2

File                                      State       Progress
2023-..._Amsterdam_nl.mp3                 Transcribing 64%
2022-..._Vrindavan_in.wav                 Ready
bad filename.MP3                          Invalid name
2021-..._Mayapur_in.m4a                   Output edited
```

Для job:

- Retry;
- Cancel;
- Reveal in Finder;
- показать naming violations;
- overwrite once;
- показать provider/model;
- показать timing quality;
- optional `Open as Project` после завершения.

`BatchTranscriptionStore`:

```swift
@MainActor
final class BatchTranscriptionStore: ObservableObject
```

Он получает snapshots/events от coordinator и публикует только UI-friendly state. Сам coordinator не работает на MainActor.

---

## 22. Жизненный цикл приложения

Batch runtime принадлежит `VaniScriptApp` или app container, а не View.

На старте:

```text
load profiles
resolve bookmarks
open database
recover interrupted jobs
clean orphan workspaces
reconcile local model state
start enabled watchers
scan all watched folders
start coordinator
```

При termination:

```text
stop accepting new jobs
cooperatively cancel active task
persist latest checkpoint
close database
stop watchers
release security-scoped access
```

Текущее приложение не завершается при закрытии последнего окна, поэтому MVP может продолжать работу как app-resident service.

### Долгосрочный always-on режим

После стабилизации MVP:

```text
VaniScriptBatchAgent
    owns watcher + queue + ASR
        ↕ XPC / shared SQLite
VaniScript UI
    edits profiles and shows status
```

Только один процесс должен владеть scheduler и local ASR runtime.

---

## 23. Обработка ошибок

| Событие | Реакция |
|---|---|
| Файл еще копируется | `stabilizing` |
| Некорректное имя | `blockedInvalidName` |
| Невалидный media container | `failedPermanent` |
| Нет audio track | `failedPermanent` |
| Модель не установлена | `blockedModelUnavailable` |
| Временная ASR-ошибка | exponential backoff, максимум `maxAttempts` |
| Source изменился во время ASR | discard generation, requeue |
| Source удален | `superseded` |
| Existing unknown TXT | `blockedOutputConflict` |
| Generated TXT отредактирован | `blockedOutputModified` |
| Нет прав записи | `blockedFolderPermission` |
| Crash во время ASR | resume from chunk checkpoint |
| Crash во время commit | reconciliation temp/final files |
| Cloud rate limit | retry того же провайдера |
| Destination collision | `blockedNamingConflict` |

Retryable и permanent errors должны быть разными enum-категориями, а не определяться разбором пользовательской строки.

---

## 24. Изменения по существующим файлам

| Файл | Изменение |
|---|---|
| `Package.swift` | Добавить runtime target и зависимости между слоями |
| `Sources/VaniScript/App/VaniScriptApp.swift` | Создать app-level runtime container и batch store |
| `Sources/VaniScript/Stores/WorkflowStore.swift` | Инъекция общего transcription scheduler/service; не хранить batch queue |
| `Sources/VaniScript/Services/NativeProcessingPipeline.swift` | Выделить ASR-only use case |
| `Sources/VaniScript/Services/LocalASREngineRouter.swift` | Перенести в shared runtime и использовать один instance |
| `Sources/VaniScript/Services/AudioChunkExporter.swift` | Явный workspace ownership и cleanup |
| `Sources/VaniScript/Services/AppStoragePaths.swift` | Batch paths/database/workspaces |
| `Sources/VaniScriptCore/MetadataExtractor.swift` | Не использовать как batch naming parser; optional strict parser first для manual import |
| `Sources/VaniScriptCore/TranscriptExportBuilder.swift` | Legacy export не ломать; общий timestamp formatter можно извлечь |
| `Sources/VaniScript/Views/ContentView.swift` | Кнопка/индикатор Batch |
| `Sources/VaniScript/Views/SettingsView.swift` | Watched folder profiles/settings |

Batch-файлы не должны автоматически создавать `ProjectRecord`. Команда `Open as Project` выполняет это только по запросу пользователя.

---

## 25. План внедрения по PR

## PR 1 — Naming contract

- ADR по каноническому имени;
- `CanonicalMediaName`;
- parser/validator/renderer;
- legacy compatibility mode;
- same-stem companion URL;
- collision detection;
- полный набор unit tests.

**Результат:** система однозначно отвечает, можно ли обрабатывать файл и каким будет имя TXT.

## PR 2 — Timed renderer и atomic writer

- `BatchTimedTextRenderer`;
- cue validation;
- exact-stem output;
- atomic temp/rename;
- output SHA-256;
- overwrite policies;
- tests на partial-write и user modification.

**Результат:** фиктивный `FileTranscript` безопасно превращается в companion TXT.

## PR 3 — ASR-only API

- `FileTranscriptionService`;
- отделение ASR от перевода;
- общий scheduler/router;
- absolute timing mapping;
- deterministic workspaces;
- chunk checkpoints;
- перевод ручного pipeline на новый сервис.

**Результат:** один файл можно транскрибировать программно без UI и Review.

## PR 4 — One-shot batch queue

- `BatchJob`;
- SQLite repository;
- state machine;
- retries/cancel;
- one-shot folder scan;
- processing queue;
- recovery.

**Результат:** `Choose Folder → Scan Once → Process` работает end-to-end.

## PR 5 — Watched folders

- security-scoped bookmarks;
- profile persistence;
- FSEvents signal;
- reconciliation;
- file stability;
- startup scan;
- recursive option.

**Результат:** новый файл автоматически попадает в очередь.

## PR 6 — UI и hardening

- Batch workspace;
- Settings section;
- notifications;
- manual > batch priority;
- model/budget safeguards;
- privacy-safe logging;
- integration/regression tests.

**Результат:** законченная пользовательская функция.

## PR 7 — Login item / agent, опционально

- background launch mode;
- agent ownership;
- XPC/state synchronization;
- single-owner locking.

---

## 26. Тестовый план

## 26.1. Core naming tests

```text
полная дата
год-месяц
только год
literal YYYY-MM-DD
WHAT с внутренним underscore
WHERE с дефисом
uppercase extension
пробелы
дополнительная точка
запрещенные символы
невалидная календарная дата
длина 128/129
legacy KKS-CC form
parse → render round trip
case-insensitive collision
same-stem companion URL
```

## 26.2. State machine tests

- все допустимые transitions;
- отклонение недопустимых transitions;
- cancel;
- retry;
- source changed;
- model unavailable;
- output conflict;
- crash recovery;
- resume from checkpoints;
- superseded generations.

## 26.3. Watcher tests

1. Файл появляется целиком.
2. Файл копируется частями.
3. Файл переименовывается после появления.
4. Несколько одинаковых events создают один job.
5. Startup scan находит пропущенный файл.
6. Source удаляется.
7. Recursive on/off.
8. Symlink не обходится.
9. `.txt` не попадает в очередь.
10. Temp-файлы игнорируются.

## 26.4. Writer tests

- финальный TXT никогда не виден частичным;
- unknown TXT не перезаписывается;
- modified generated TXT не перезаписывается;
- stale untouched generated TXT заменяется;
- permission denied;
- cleanup temp after crash;
- source change before commit отменяет output.

## 26.5. ASR tests

- router переиспользует resident engine;
- batch не вызывает translation;
- cue offset прибавляется ровно один раз;
- chunk checkpoints собираются по порядку;
- word timestamps сохраняются;
- timing policy соблюдается;
- manual job имеет приоритет;
- temporary chunks очищаются.

Существующие factory seams позволяют выполнять эти тесты без загрузки реальных model weights.

## 26.6. End-to-end fixture

Исходная папка:

```text
2013-11-14_KKS_SB-9-20-27_Vrindavan_in.wav
2023-01-16_KKS_CC-Raghunatha-das-goswami_Amsterdam_nl.wav
2020_KKS_SB-8-1-30_Balancing-our-lives_London_gb.wav
```

Ожидаемые outputs:

```text
2013-11-14_KKS_SB-9-20-27_Vrindavan_in.txt
2023-01-16_KKS_CC-Raghunatha-das-goswami_Amsterdam_nl.txt
2020_KKS_SB-8-1-30_Balancing-our-lives_London_gb.txt
```

Повторный запуск не создает дубликаты и не изменяет актуальные TXT.

---

## 27. Acceptance criteria

Функция считается готовой, когда:

1. В watched folder помещен корректно названный аудиофайл.
2. После завершения копирования он автоматически обнаруживается.
3. Пользователь не нажимает Start и не создает проект.
4. Рядом появляется `.txt` с идентичным stem.
5. В имени нет `_original`, `_transcript`, UUID или `(2)`.
6. Каждая текстовая cue имеет тайминг.
7. Тайминги абсолютные, монотонные и не выходят за duration.
8. Повторные filesystem events не создают второй job.
9. Перезапуск приложения восстанавливает обработку.
10. Некорректные имена не получают выдуманные метаданные.
11. Ручная правка `.txt` не перезаписывается.
12. Локально одновременно работает не более одного ASR job.
13. Ручной workflow имеет приоритет над фоновым.
14. Недоступный provider не заменяется скрытым fallback.
15. Временные файлы очищаются.
16. Ошибка одного файла не останавливает папку.
17. Существующий manual Upload/Review/Export остается рабочим.

---

## 28. Рекомендуемые defaults

```text
Canonical separator WHO/WHAT:    underscore
Invalid-name policy:             strictReject
Output name:                     exact same stem + .txt
Existing TXT policy:             replaceGeneratedOnly
Local ASR concurrency:           1
Cloud ASR concurrency in MVP:    1
Timing policy:                   requireModelCues
Recursive scanning:              off
Symlink traversal:               off
Background mode in MVP:          app-resident
Long-term background mode:       login agent
Automatic provider fallback:     disabled
Automatic semantic guessing:     disabled
```

---

## 29. Первое обязательное решение команды

До начала production-кода нужно принять naming ADR, включающий:

1. `_` как канонический разделитель WHO/WHAT;
2. правила `YYYY-MM-DD`, `YYYY-MM`, `YYYY` и literal placeholder;
3. allowed characters;
4. возможность `_` внутри WHAT;
5. strictReject как default;
6. exact-stem TXT;
7. collision behavior;
8. existing output policy.

Без этого watcher и очередь смогут технически работать, но будут создавать неоднозначные или несовместимые архивные имена.

---

## 30. Финальное архитектурное решение

Для VaniScript оптимальна отдельная подсистема `BatchTranscriptionCoordinator`, которая:

- наблюдает за подключенными папками;
- использует reconciliation вместо доверия filesystem events;
- ждет стабильности файлов;
- валидирует имя через строгую доменную модель;
- сохраняет задания в SQLite;
- разделяет ASR runtime с ручным workflow;
- выполняет только транскрибацию;
- сохраняет chunk checkpoints;
- рендерит deterministic timed TXT;
- записывает результат атомарно рядом с аудио;
- защищает пользовательские правки;
- восстанавливается после перезапуска.

Первый технический PR должен реализовать:

```text
MediaNamingConvention
+ BatchTimedTextRenderer
+ AtomicCompanionWriter contracts
+ unit tests
```

Затем следует извлечь `FileTranscriptionService`, и только после этого добавлять durable queue и folder watcher.
