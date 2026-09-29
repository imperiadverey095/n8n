#!/usr/bin/env node
// Минимальный приёмник SMTP для стенда: принимает письмо и печатает его заголовки.
import { createServer } from 'node:net';
import { writeFileSync, mkdirSync, chmodSync, readdirSync } from 'node:fs';

const PORT = Number(process.env.SMTP_PORT || process.env.PORT || 1025);
// Письма кладём рядом с данными стенда, а не в текущий каталог.
const MAIL_DIR = process.env.STAND_HOME ? `${process.env.STAND_HOME}/mail` : 'mail';
// В письмах имена сотрудников и причины корректировок — читать их может только владелец.
mkdirSync(MAIL_DIR, { recursive: true, mode: 0o700 });
chmodSync(MAIL_DIR, 0o700);
// Письмо больше этого размера отклоняется, а не копится в памяти.
const MAX_MESSAGE = 10 * 1024 * 1024;
// Нумерация продолжается с последнего письма в каталоге: раньше счётчик начинался
// с единицы при каждом запуске и новое письмо затирало старое с тем же номером.
// Заодно ужесточаем права писем, оставшихся от прежних запусков.
let count = 0;
for (const name of readdirSync(MAIL_DIR)) {
  const m = /^(\d+)\.eml$/.exec(name);
  if (!m) continue;
  count = Math.max(count, Number(m[1]));
  chmodSync(`${MAIL_DIR}/${name}`, 0o600);
}

createServer((socket) => {
  let data = false;
  let buffer = '';
  socket.write('220 timetrack-stand ESMTP\r\n');
  socket.on('data', (chunk) => {
    const text = chunk.toString('utf8');
    if (data) {
      buffer += text;
      if (buffer.length > MAX_MESSAGE) {
        data = false;
        buffer = '';
        socket.write('552 Message size exceeds limit\r\n');
        return;
      }
      if (buffer.includes('\r\n.\r\n')) {
        data = false;
        const body = buffer.slice(0, buffer.indexOf('\r\n.\r\n'));
        const header = (name) => (new RegExp('^' + name + ': (.*)$', 'im').exec(body) || [, ''])[1].trim();
        count += 1;
        const file = `${MAIL_DIR}/${String(count).padStart(2, '0')}.eml`;
        buffer = '';
        // flag 'wx' — создать новый файл или упасть, но не затереть существующий.
        // Ошибка записи — отказ по SMTP, а не падение всего приёмника.
        try {
          writeFileSync(file, body, { mode: 0o600, flag: 'wx' });
        } catch (err) {
          console.log(`письмо ${count} не сохранено: ${err.code || err.message}`);
          socket.write('451 Local error in processing\r\n');
          return;
        }
        console.log(`письмо ${count}: «${header('Subject').slice(0, 80)}» → ${header('To')} (${body.length} байт, ${file})`);
        socket.write('250 OK\r\n');
      }
      return;
    }
    for (const line of text.split('\r\n').filter(Boolean)) {
      const cmd = line.slice(0, 4).toUpperCase();
      if (cmd.startsWith('EHLO') || cmd.startsWith('HELO')) socket.write('250-timetrack-stand\r\n250 AUTH PLAIN LOGIN\r\n');
      else if (cmd.startsWith('AUTH')) socket.write('235 Authentication succeeded\r\n');
      else if (cmd.startsWith('MAIL') || cmd.startsWith('RCPT')) socket.write('250 OK\r\n');
      else if (cmd.startsWith('DATA')) { data = true; socket.write('354 End data with <CR><LF>.<CR><LF>\r\n'); }
      else if (cmd.startsWith('QUIT')) { socket.write('221 Bye\r\n'); socket.end(); }
      else if (cmd.startsWith('RSET') || cmd.startsWith('NOOP')) socket.write('250 OK\r\n');
      else socket.write('250 OK\r\n');
    }
  });
  socket.on('error', () => {});
// Только localhost: заглушка без авторизации, наружу её открывать нельзя.
}).listen(PORT, '127.0.0.1', () => console.log(`приёмник SMTP: 127.0.0.1:${PORT}`));
