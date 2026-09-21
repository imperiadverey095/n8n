# API учёта рабочего времени (вебхуки n8n)

Все запросы идут на `{WEBHOOK_URL}/webhook/timetrack/...`. Аутентификация — заголовок `X-Api-Token: <токен>` (или `Authorization: Bearer <токен>`). Токены выпускаются в БД функцией `timetrack.fn_issue_token(name, role, employee_id, location, expires_at)` и хранятся только в виде sha256-хэша.

| Роль токена | Кому выдаётся | Что может |
|---|---|---|
| `device` | терминал/киоск | отметки по лицу |
| `employee` | сотрудник (привязан к `employee_id`) | ручная отметка, свои записи, запросы корректировок, отзыв своего согласия, свой отчёт |
| `hr` | HR-менеджер / портал | регистрация, отзыв биометрии, отчёты по всем, очередь и решения по корректировкам, синхронизация справочника |
| `system` | интеграции (HR-система) | то же, что `hr`, кроме личных операций сотрудника |

Ответ всегда JSON вида `{ "ok": true|false, "code": "...", ... }`. Коды ошибок HTTP: `400` невалидный запрос, `401` неверный токен, `403` отклонено политикой (нет согласия, сотрудник неактивен, лицо не соответствует `employee_id`), `404` лицо не распознано, `422` на снимке нет лица/несколько лиц, `502` сервис распознавания недоступен.

---

## Отметки

### `POST /timetrack/clock` — отметка по лицу *(device)*

`multipart/form-data` (рекомендуется) или JSON.

| Поле | Обяз. | Описание |
|---|---|---|
| `image` (файл) / `image_base64` | да | снимок лица (JPEG/PNG). В multipart — поле **`image`** |
| `event_type` | нет | `check_in`, `check_out` или `auto` (по умолчанию: чередование) |
| `request_id` | нет | ключ идемпотентности (повтор запроса вернёт то же событие, `duplicate: true`) |
| `device_id`, `location` | нет | идентификатор терминала и место |
| `captured_at` | нет | время снимка ISO 8601 для офлайн-очереди терминала (принимается, если не старше 24 ч) |
| `employee_id` | нет | ожидаемый сотрудник (защита от подмены: несовпадение → `403 employee_mismatch`) |
| `liveness_score` | нет | оценка «живости» от клиентского SDK (0..1), сохраняется в событии |

```bash
curl -X POST "$W/timetrack/clock" -H "X-Api-Token: $DEVICE_TOKEN" \
  -F image=@photo.jpg -F device_id=kiosk-1 -F request_id=$(uuidgen)
```

Успех `200`:
```json
{ "ok": true, "code": "recorded", "duplicate": false, "employee_id": "EMP-001",
  "full_name": "Иванов Иван Иванович", "event_type": "check_in",
  "occurred_at": "2026-09-21T06:05:12.311Z", "event_id": 42, "similarity": 0.987 }
```
`code` также может быть `debounced` (повторная отметка в окне 120 с) или `duplicate_request` (тот же `request_id`).

Ошибки распознавания: `no_face` (422), `multiple_faces` (422), `unknown_face` (404), `low_similarity` (404), `employee_mismatch` (403), `face_service_unavailable` (502). Отклонения политикой (403): `consent_missing`, `employee_inactive`, `employee_not_found`.

### `POST /timetrack/clock/manual` — ручная отметка *(employee; hr/system с `employee_id`)*

JSON: `{ "event_type": "check_in|check_out|auto", "request_id": "...", "location": "...", "note": "..." }`. Не требует биометрии и согласия — альтернатива для сотрудников без согласия и на случай сбоя терминала. Событие получает `source = manual`.

---

## Сотрудники и биометрия

### `POST /timetrack/employees/enroll` — регистрация сотрудника и лица *(hr/system)*

`multipart/form-data` или JSON.

| Поле | Обяз. | Описание |
|---|---|---|
| `employee_id` | да | `[A-Za-z0-9._-]{1,64}` — табельный номер, он же subject в CompreFace |
| `full_name` | да | ФИО |
| `consent_granted` | да | должно быть `true` — факт получения согласия на обработку биометрии |
| `consent_document_ref`, `consent_via` | нет | реквизиты подписанного согласия и способ получения |
| `image` / `image_base64` | да | фронтальный снимок для регистрации |
| `email`, `department`, `position`, `hr_external_id` | нет | атрибуты |
| `timezone` | нет | IANA, например `Europe/Moscow` (по умолчанию `UTC`) |
| `work_schedule` | нет | `{"start":"09:00","end":"18:00","days":[1,2,3,4,5],"break_minutes":60}` (дни — ISO: 1 = пн) |

Ответ `201`: `{ ok, code: "enrolled", employee_id, full_name, enrollment_id, face_id, consent_id }`. Повторный вызов с новым снимком добавляет ещё один пример лица (повышает точность). Если снимок отклонён (`422 no_face`), сотрудник и согласие уже сохранены — повторите загрузку.

### `POST /timetrack/biometrics/revoke` — отзыв согласия и удаление шаблонов *(hr/system или сам сотрудник)*

JSON: `{ "employee_id": "EMP-001", "reason": "employee_request" }`. Удаляет subject в CompreFace, деактивирует регистрации, отзывает согласие, пишет аудит и событие `consent.revoked` в outbox. Ответ: `{ ok, enrollments_deactivated, consents_revoked, face_service_status }`.

### `POST /timetrack/hr/employees` — синхронизация справочника из HR-системы *(hr/system)*

```json
{ "employees": [
  { "employee_id": "EMP-001", "full_name": "…", "email": "…", "department": "…", "position": "…",
    "timezone": "Europe/Moscow", "work_schedule": {…}, "hr_external_id": "…", "status": "active|inactive|terminated" }
] }
```
Ответ: `{ ok, processed, updated, failed, errors[] }`. `status = terminated` запускает удаление биометрии через N дней (воркфлоу 07).

---

## Самообслуживание сотрудника

### `GET /timetrack/me/records?from=YYYY-MM-DD&to=YYYY-MM-DD` *(employee)*

По умолчанию — последние 30 дней. Ответ — табель сотрудника: `employee`, `days[]` (дневная сводка), `sessions[]` (пары приход/уход с `in_event_id`/`out_event_id`), `corrections[]`, `totals`.

### `POST /timetrack/me/corrections` *(employee)*

| `action` | Обязательные поля | Смысл |
|---|---|---|
| `add` | `requested_type`, `requested_time`, `reason` | добавить пропущенную отметку |
| `change` | `event_id`, `requested_type`, `requested_time`, `reason` | изменить своё событие |
| `void` | `event_id`, `reason` | аннулировать ошибочную отметку |

Ограничения: событие принадлежит сотруднику и не старше 45 дней (`maxCorrectionAgeDays` в Config), время не из будущего, по одному событию — один открытый запрос. Ответ `201`: `{ ok, code: "created", request }`. HR получает письмо.

---

## HR: корректировки и отчёты

### `GET /timetrack/hr/corrections?status=pending|approved|rejected` *(hr/system)*

Список запросов с текущими значениями события (`current_type`, `current_occurred_at`).

### `POST /timetrack/hr/corrections/review` *(hr/system)*

`{ "request_id": "<uuid>", "decision": "approved|rejected", "comment": "…" }`. При одобрении создаётся событие `source = correction`, а исходное помечается `corrected`/`voided` (история не удаляется). Сотрудник получает письмо. Ответ: `{ ok, code, request, result_event }`.

### `GET /timetrack/reports` *(hr/system — все; employee — только свой)*

| Параметр | Значения | По умолчанию |
|---|---|---|
| `type` | `standard` (табель по дням), `detailed` (дни + сессии + корректировки), `summary` (итоги) | `standard` |
| `format` | `json`, `csv`, `html` | `json` |
| `from`, `to` | даты `YYYY-MM-DD`, не более 366 дней | текущий месяц |
| `employee_id` | табельный номер | все активные |
| `department` | подразделение | — |
| `include_inactive` | `true` | `false` |

Подробнее о содержимом отчётов — в [reports.md](reports.md).
