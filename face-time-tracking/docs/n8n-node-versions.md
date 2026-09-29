# Версии нод n8n, используемые в воркфлоу

Версии выбраны так, чтобы JSON импортировался и в этот репозиторий (форк n8n, см. `packages/nodes-base`), и в актуальные релизы n8n. Проверка: `node scripts/validate-workflows.mjs` сверяет тип и версию каждой ноды с исходниками репозитория; на живом инстансе конфигурации нод дополнительно проверялись инструментом `validate_node_config` MCP-сервера n8n.

| Нода | Тип | Версия в JSON | Доступные версии в репозитории |
|---|---|---|---|
| Webhook | `n8n-nodes-base.webhook` | 2 | 1, 1.1, 2, 2.1 |
| Respond to Webhook | `n8n-nodes-base.respondToWebhook` | 1.1 | 1 … 1.5 |
| HTTP Request | `n8n-nodes-base.httpRequest` | 4.2 | 3, 4, 4.1 … 4.4 |
| Postgres | `n8n-nodes-base.postgres` | 2.5 | 1, 2 … 2.6 (в инстансе — 2.7) |
| Code | `n8n-nodes-base.code` | 2 | 1, 2 |
| If | `n8n-nodes-base.if` | 2.2 | 1, 2 … 2.3 |
| Switch | `n8n-nodes-base.switch` | 3.2 | 1, 2, 3 … 3.4 |
| Filter | `n8n-nodes-base.filter` | 2.2 | 1, 2 … 2.3 |
| Edit Fields (Set) | `n8n-nodes-base.set` | 3.4 | 1, 2, 3 … 3.5 |
| Schedule Trigger | `n8n-nodes-base.scheduleTrigger` | 1.2 | 1 … 1.3 |
| Send Email | `n8n-nodes-base.emailSend` | 2.1 | 1, 2, 2.1 |
| Convert to File | `n8n-nodes-base.convertToFile` | 1.1 | 1, 1.1 |
| Crypto | `n8n-nodes-base.crypto` | 1 | 1, 2 |
| Split Out | `n8n-nodes-base.splitOut` | 1 | 1 |
| Error Trigger | `n8n-nodes-base.errorTrigger` | 1 | 1 |
| Sticky Note | `n8n-nodes-base.stickyNote` | 1 | 1 |

## Почему именно так

* **Postgres ≥ 2.5** — начиная с этой версии параметр *Query Parameters* (`options.queryReplacement`) принимает выражение, возвращающее **массив**: `={{ [ a, b, {obj} ] }}`. Объекты сериализуются в JSON автоматически, что нужно для `jsonb`-аргументов функций. В более старых версиях значения разделяются запятыми, и JSON с запятыми ломает разбор.
* **Code v2** — доступны `this.helpers.prepareBinaryData()` (base64 → binary) и `$('Node').first().binary` (передача снимка дальше без копирования в JSON).
* **HTTP Request 4.2** — тело `multipart-form-data` с параметром типа `formBinaryData` отправляет снимок из binary-поля напрямую в CompreFace.
* **If/Filter/Switch с `conditions.options.version: 2`** — формат условий, соответствующий версиям 2.2 / 3.2.

## Что учесть при обновлении версий

* При переходе на If ≥ 2.3 / Switch ≥ 3.4 поле `conditions.options.version` должно стать `3` (см. `packages/nodes-base/nodes/If/V2/IfV2.node.ts`).
* Send Email 2.1: обычные вложения — `options.fileAttachments`; `options.attachments` в новых версиях означает inline-вложения (cid).
* Все версии заданы в одном месте — `scripts/lib/builder.mjs` (`NODE`), после изменения пересоберите JSON: `node scripts/build-workflows.mjs && node scripts/validate-workflows.mjs`.
