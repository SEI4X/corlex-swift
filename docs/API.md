## API

```swift
Corlex.track("purchase", properties: ["plan": "pro", "amount": 12.5])
Corlex.identify("user_42", traits: ["plan": "pro"])   // склеивает анонимного пользователя с вашим id
Corlex.setUserProperties(["locale": "ru"])
Corlex.screen("Paywall")                              // экран вручную
Corlex.reset()                                        // логаут: новый анонимный id
await Corlex.flush()                                  // отправить сейчас

let days = Corlex.flag("free_trial_days", default: 7)          // Remote Config
let title = Corlex.config.get("paywall_title", default: "Pro")
await Corlex.config.ready()                                     // дождаться загрузки (config.timeout, 1,5 с)
if let variant = Corlex.experiment("paywall_test") { … }        // шлёт corlex.exposure один раз за сеанс
```

Имена событий: 1–128 символов `a-z 0-9 _ . : -`; префикс `corlex.` зарезервирован. Свойства: строки, числа, `Bool`, `Date`, массивы и словари из них; длинные строки обрезаются, остальное отбрасывается (лимиты протокола).

`flag` и `config.get` возвращают значение, если параметр есть, rollout/переопределение для `ios` его включает и тип совпадает с типом `default` (`Bool`, `Int`, `Double`, `String`, `[Any]`, `[String: Any]`); иначе `default`. Вычисление на устройстве, запрос не содержит id пользователя. Новая публикация применяется при следующем запуске (значение не меняется посреди сеанса), если приложение уже читало значения; `options.config.live = true` применяет сразу.

### Каждое событие несёт

`platform: ios`, `app_version` (`CFBundleShortVersionString`), свойство `build` (`CFBundleVersion`), `os`, `os_version`, `device_model` (`iPhone16,2`), `locale`, `sdk`. Идентификатор рекламы (IDFA) и IDFV не читаются: анонимный id — случайный UUID, который SDK создаёт сам.


## Semantics

Event names use 1–128 characters from a-z, 0-9, underscore, dot, colon and hyphen. Do not build names/screens from user input. Properties are bounded/sanitized JSON; an individual event is limited to 32 KiB. identify links an internal application ID, not a hardware/advertising identifier. reset creates a fresh anonymous identity without relabeling queued history. Remote Config defaults are returned when a value is absent/inapplicable; listing config is not an experiment exposure.
