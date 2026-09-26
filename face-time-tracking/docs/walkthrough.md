# Как это работает: пример одного рабочего дня

Ниже — реальный прогон на PostgreSQL (схема и все функции настоящие). n8n и CompreFace в этом примере не запускались: для нод *Code* использован их настоящий код из `workflows/02-face-clock-in-out.json`, а ответы CompreFace подставлены такие, какие возвращает его API. Всё воспроизводится одной командой:

```bash
cd face-time-tracking
DATABASE_URL=postgres://user:pass@host:5432/postgres examples/run-demo.sh
# результаты: examples/output/demo-day.txt, simulated-http.txt, report.html, report.csv, report.json, report.png
```

Участники: терминал у проходной (токен роли `device`), сотрудники Иванов (EMP-001, согласие есть), Петрова (EMP-002, согласие есть) и Сидоров (EMP-003, согласия нет — отмечается вручную), HR-портал (токен `hr`).

## 1. Регистрация сотрудника и лица

HR-портал отправляет карточку, факт согласия и фото:

```bash
curl -X POST https://n8n.example.com/webhook/timetrack/employees/enroll \
  -H "X-Api-Token: $HR_TOKEN" \
  -F employee_id=EMP-001 -F "full_name=Иванов Иван Иванович" -F email=ivanov@example.com \
  -F department=Склад -F timezone=Europe/Moscow \
  -F 'work_schedule={"start":"09:00","end":"18:00","days":[1,2,3,4,5],"break_minutes":60}' \
  -F consent_granted=true -F "consent_document_ref=Согласие №2026-001" \
  -F image=@ivanov.jpg
```

Воркфлоу 01 проверяет токен, валидирует поля, требует `consent_granted=true`, затем в одной транзакции создаёт карточку и запись согласия, отправляет фото в CompreFace как `subject=EMP-001` и сохраняет **только ссылку на шаблон и хэш снимка**:

```
 employee_id |      full_name       | department |   timezone    | work_schedule
 EMP-001     | Иванов Иван Иванович | Склад      | Europe/Moscow | {"end": "18:00", "days": [1,2,3,4,5], "start": "09:00", "break_minutes": 60}
 consent_id     e6c4d2cb-e7c5-4297-98a7-fdfc8ff6e902
 enrollment_id  82353557-b0bb-432f-84de-1051a1ebb563
```

Ответ терминалу/порталу: `201 { "ok": true, "code": "enrolled", "employee_id": "EMP-001", "enrollment_id": "…", "face_id": "…", "consent_id": "…" }`.

Токены доступа выпускаются в БД и показываются один раз; хранится только sha256:

```
       client        |   role   |                              token
 Kiosk main entrance | device   | <значение токена показано один раз в терминале>
 EMP-003 mobile      | employee | <значение токена показано один раз в терминале>
 HR portal           | hr       | <значение токена показано один раз в терминале>
--- как это хранится ---
        name         |   role   | employee_id |      token_hash
 Kiosk main entrance | device   | ∅           | 6577e62dd02bdcbe887a…
```

## 2. Утро: отметка по лицу

09:05 — Иванов встаёт перед терминалом. Терминал шлёт фото и свой токен:

```
→ POST /webhook/timetrack/clock   (multipart/form-data, X-Api-Token: <токен терминала>)
   поля: {"device_id":"kiosk-1","location":"Проходная","request_id":"req-0905"}  image: photo.jpg
```

Внутри воркфлоу 02 (вывод настоящего кода нод):

```
n8n Prepare Request       → {"ok":true,"event_type":"auto","request_id":"…","device_id":"kiosk-1","binary":["image"]}
n8n Recognize Face        → CompreFace POST /api/v1/recognition/recognize
                            ⇒ HTTP 200 {"result":[{"box":{"probability":0.99971},"subjects":[{"subject":"EMP-001","similarity":0.987}]}]}
n8n Interpret Recognition → {"matched":true,"code":"matched","similarity":0.987,"http_status":200}
n8n Record Attendance     → timetrack.fn_clock(...)
```

`fn_clock` проверяет, что сотрудник активен и согласие действует, определяет тип отметки чередованием (первая за день — приход), пишет событие, аудит и запись в outbox:

```
 ok |   code   | event_type |    local_time    | duplicate |      full_name
 t  | recorded | check_in   | 2026-09-21 09:05 | f         | Иванов Иван Иванович
```

Ответ терминалу (его показывает экран киоска: «Здравствуйте, Иван Иванович, приход 09:05»):

```json
{ "ok": true, "code": "recorded", "duplicate": false, "employee_id": "EMP-001",
  "full_name": "Иванов Иван Иванович", "event_type": "check_in",
  "occurred_at": "2026-09-21T06:05:00+00:00", "event_id": 1, "similarity": 0.987 }
```

**Сеть моргнула, терминал повторил запрос** с тем же `request_id` — второе событие не создаётся, возвращается то же:

```
 t  | duplicate_request | check_in   | 2026-09-21 09:05 | t
```

**09:06 — сотрудник ещё раз посмотрел в камеру** (новый снимок, новый `request_id`) — антидребезг 120 секунд:

```
 t  | debounced | check_in   | 2026-09-21 09:05 | t
```

## 3. День: обед и уход

Тип события каждый раз определяется автоматически (`event_type=auto`):

```
 step | ok |   code   | event_type |    local_time
    1 | t  | recorded | check_out  | 2026-09-21 13:02     ← ушёл на обед
    2 | t  | recorded | check_in   | 2026-09-21 13:47     ← вернулся
    3 | t  | recorded | check_out  | 2026-09-21 18:34     ← ушёл домой
```

## 4. Что происходит, когда что-то не так

Все случаи ниже прогнаны через настоящий код нод; ответы — те, что получит терминал.

| Ситуация | CompreFace | Ответ терминалу |
|---|---|---|
| Похожее, но чужое лицо: схожесть 0.71 при пороге 0.90 | `200`, `similarity: 0.71044` | `404 {"ok":false,"code":"low_similarity","message":"Недостаточная схожесть лица"}` |
| На снимке нет лица | `400 {"code":28,"message":"No face is found…"}` | `422 {"ok":false,"code":"no_face","message":"На снимке не найдено лицо"}` |
| Терминал передал `employee_id=EMP-001`, а лицо — Петровой | `200`, `subject: EMP-002`, `similarity: 0.97` | `403 {"ok":false,"code":"employee_mismatch"}` |
| Посетитель, не зарегистрированный в системе | `200`, `subjects: []` | `404 {"ok":false,"code":"unknown_face"}` + запись `recognition.failed` в аудите (без фото) |
| Сидоров без согласия, даже если бы лицо совпало | `200`, `similarity: 0.95` | `403 {"ok":false,"code":"consent_missing","employee_id":"EMP-003"}` |

Сидоров вместо этого отмечается личным токеном — без биометрии:

```
→ POST /webhook/timetrack/clock/manual   (X-Api-Token: <личный токен EMP-003>)   {"event_type":"check_in"}
 ok |   code   | event_type |    local_time
 t  | recorded | check_in   | 2026-09-21 08:03          (source = manual)
```

## 5. Что лежит в базе после этого дня

Фото нет нигде; есть хэш снимка, схожесть, источник и ключ идемпотентности:

```
 id | employee_id | event_type |    local_time    | source | device_id | confidence | request_id | status
  1 | EMP-001     | check_in   | 2026-09-21 09:05 | face   | kiosk-1   |     0.9870 | req-0905   | valid
  2 | EMP-001     | check_out  | 2026-09-21 13:02 | face   | kiosk-1   |     0.9700 | req-1302   | valid
  3 | EMP-001     | check_in   | 2026-09-21 13:47 | face   | kiosk-1   |     0.9700 | req-1347   | valid
  4 | EMP-001     | check_out  | 2026-09-21 18:34 | face   | kiosk-1   |     0.9700 | req-1834   | valid
  5 | EMP-003     | check_in   | 2026-09-21 08:03 | manual | ∅         |          ∅ | req-sid-2  | valid
```

## 6. Календарь, отпуска и дневная сводка

Перед расчётом табеля HR-система присылает кадровые данные — иначе отпуск превратится в прогул:

```
→ POST /webhook/timetrack/hr/absences   {"absences":[{"employee_id":"EMP-002","type":"vacation","date_from":"2026-09-21","date_to":"2026-09-25","external_id":"HR-VAC-7781"}]}
 ok | code  |   type   | date_from  |  date_to
 t  | saved | vacation | 2026-09-21 | 2026-09-25

→ POST /webhook/timetrack/hr/calendar   {"calendar_code":"ru","days":[{"day":"2026-09-22","day_type":"holiday","name":"Демонстрационный праздник"}]}
 calendar_code |    day     | day_type |           name
 ru            | 2026-09-22 | holiday  | Демонстрационный праздник
```

`GET /webhook/timetrack/reports?type=standard&from=2026-09-21&to=2026-09-21` (HR-токен):

```
 employee_id | day_type |   status   | absence_type |     first_in     |     last_out     | sessions | worked | break | scheduled | late | overtime | incomplete
 EMP-001     | workday  | late       | ∅            | 2026-09-21 09:05 | 2026-09-21 18:34 |        2 |    509 |    60 |       480 |    5 |       29 | f
 EMP-002     | workday  | vacation   | vacation     | ∅                | ∅                |        0 |      0 |     0 |       480 |    0 |        0 | f
 EMP-003     | workday  | incomplete | ∅            | 2026-09-21 08:03 | ∅                |        1 |      0 |     0 |       480 |    3 |        0 | t
```

Как получились 509 минут у Иванова: 09:05–13:02 и 13:47–18:34 = 524 мин; обед длился 45 мин, а по графику положено 60 → недостающие 15 удержаны автоматически. Опоздание 5 мин, сверхурочно 509 − 480 = 29.

Петрова в отпуске — день получает статус `vacation`, а не `absent`, и еженедельное напоминание ей не уйдёт. Следующий день объявлен праздником: норма 0, работа в такой день целиком считается сверхурочной, а короткий выход (меньше шести часов) обедом не облагается.

Сидоров вечером забыл отметить уход — день `incomplete`. Утром он видит это в `GET /timetrack/me/records` (или получает письмо-напоминание в понедельник) и отправляет запрос:

```
→ POST /webhook/timetrack/me/corrections   (личный токен)
  {"action":"add","requested_type":"check_out","requested_time":"2026-09-21T14:30:00Z","reason":"Забыл отметиться на выходе, ушёл в 17:30"}
```

HR видит его в очереди и одобряет:

```
--- GET /timetrack/hr/corrections?status=pending ---
                  id                  | employee_id | action | requested_type |  requested_time  | status
 a675efc4-c302-4e7b-a19d-0f3263d8d2dd | EMP-003     | add    | check_out      | 2026-09-21 17:30 | pending
--- POST /timetrack/hr/corrections/review {"request_id":"a675efc4-…","decision":"approved","comment":"Подтверждено по видео с проходной"} ---
 ok |   code   | new_event_id |   source   | reviewed_by
 t  | approved | 6            | correction | hr.manager
--- сводка EMP-003 после корректировки ---
 status |     first_in     |     last_out     | worked_minutes | late_minutes | incomplete
 late   | 2026-09-21 08:03 | 2026-09-21 17:30 |            507 |            3 | f
```

Новое событие имеет `source = correction`, история сохранена, Сидоров получает письмо о решении.

Командировка и удалённая работа оформляются так же, но засчитываются по норме: день получает статус `business_trip`, отметок нет, а в колонке «Зачтено» стоит плановое время.

## 7. Табель и отчёт для HR

Итоги дня (`fn_timesheet → totals`, то же самое отдаёт `type=summary`):

```
 EMP-001 | Иванов Иван Иванович   | {"days_present": 1, "late_days": 1, "late_minutes": 5, "worked_minutes": 509, "overtime_minutes": 29, "scheduled_minutes": 480, …}
 EMP-002 | Петрова Анна Сергеевна | {"days_present": 0, "days_absent": 1, "worked_minutes": 0, "scheduled_minutes": 480, …}
 EMP-003 | Сидоров Пётр           | {"days_present": 1, "late_days": 1, "late_minutes": 3, "worked_minutes": 507, "overtime_minutes": 27, …}
```

`format=csv` (открывается в Excel, разделитель `;`):

```
employee_id;full_name;department;date;scheduled;status;first_in;last_out;sessions;worked;worked_minutes;breaks;scheduled_minutes;late_minutes;early_leave_minutes;overtime_minutes
EMP-001;Иванов Иван Иванович;Склад;2026-09-21;да;опоздание;09:05;18:34;2;8:29;509;1:00;480;5;0;29
EMP-001;Иванов Иван Иванович;Склад;2026-09-22;да;отсутствие;;;0;0:00;0;0:00;480;0;0;0
```

`format=html` за неделю (тип `detailed`) — файл `examples/output/report.html`, скриншот `examples/output/report.png`: сводка по сотрудникам, затем по каждому — дни, сессии, отсутствия и корректировки. Тот же HTML уходит HR письмом 1-го числа каждого месяца вместе с CSV.

![Пример HTML-отчёта](../examples/output/report.png)

## 8. Что уходит в HR-систему и в аудит

Outbox (воркфлоу 06 отправит каждую запись `POST` на адрес HR-системы, при ошибке повторит):

```
 id |     event_kind     | entity_id | status  | payload
  1 | employee.upserted  | EMP-001   | pending | {"status": "active", "employee_id": "EMP-001", "hr_external_id": "HR-1001"}
  4 | attendance.created | 1         | pending | {"source": "face", "status": "valid", "event_id": 1, "event_type": "check_in", "employee_id": "EMP-001", "occurred_at": "2026-09-21T06:05:00+00:00", …}
```

Журнал аудита за день — кто, что, когда:

```
       when       |        actor        | actor_role |        action        |    entity_type     | entity_id
 2026-09-22 01:50 | hr.portal           | hr         | employee.upserted    | employee           | EMP-001
 2026-09-22 01:50 | hr.portal           | hr         | consent.granted      | employee           | EMP-001
 2026-09-22 01:50 | hr.portal           | hr         | biometrics.enrolled  | employee           | EMP-001
 2026-09-22 01:50 | Kiosk main entrance | device     | attendance.check_in  | attendance_event   | 1
 2026-09-22 01:50 | Kiosk main entrance | device     | recognition.failed   | device             | kiosk-1
 2026-09-22 01:50 | ∅                   | device     | attendance.rejected  | employee           | EMP-003
 2026-09-22 01:50 | EMP-003 mobile      | employee   | attendance.check_in  | attendance_event   | 5
 2026-09-22 01:50 | EMP-003 mobile      | employee   | correction.requested | correction_request | a675efc4-…
 2026-09-22 01:50 | hr.manager          | hr         | correction.approved  | correction_request | a675efc4-…
```

## 9. Отзыв согласия (право на удаление)

Если Иванов отзывает согласие (`POST /timetrack/biometrics/revoke` своим токеном или через HR), воркфлоу 01 удаляет subject в CompreFace, деактивирует регистрации и согласие; после этого распознавание для него отвечает `consent_missing`, а ручная отметка продолжает работать. Уволенных сотрудников воркфлоу 07 удаляет из CompreFace автоматически через 30 дней.

Полные выводы прогона — `examples/output/demo-day.txt` и `examples/output/simulated-http.txt`.
